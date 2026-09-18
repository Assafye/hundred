'use strict';

const crypto = require('node:crypto');
const { Timestamp } = require('firebase-admin/firestore');
const { OTP_CONFIG } = require('./config');
const { OtpError } = require('./errors');
const { valuesMatch } = require('./crypto_utils');

const ACTIVE_STATUSES = new Set(['sending', 'sent', 'failed', 'verifying']);

function timestamp(milliseconds) {
  return Timestamp.fromMillis(milliseconds);
}

function windowKey(milliseconds, windowMs) {
  return Math.floor(milliseconds / windowMs);
}

function nextPhoneSendGuard(current, now) {
  const hourMs = 60 * 60 * 1000;
  const blockedUntil = Number(current?.blockedUntil?.toMillis?.() ?? 0);
  if (blockedUntil > now) {
    throw new OtpError('send-limit-reached', { logCategory: 'phone-hour-lock' });
  }
  const windowStartedAt = Number(current?.windowStartedAt?.toMillis?.() ?? 0);
  const withinWindow = windowStartedAt > 0 && now - windowStartedAt < hourMs;
  const count = (withinWindow ? Number(current?.count ?? 0) : 0) + 1;
  return {
    count,
    windowStartedAt: timestamp(withinWindow ? windowStartedAt : now),
    blockedUntil: count >= OTP_CONFIG.maxPhoneSendsPerHour
      ? timestamp(now + hourMs)
      : null,
    expiresAt: timestamp(now + 2 * hourMs),
  };
}

function createChallengeStore(db) {
  async function runtimeConfig() {
    const snapshot = await db.doc('system_config/phone_otp').get();
    const mode = String(snapshot.get('mode') ?? 'firebase').trim();
    if (!['micropay_internal', 'micropay_canary', 'micropay'].includes(mode)) {
      throw new OtpError('service-unavailable', { logCategory: 'migration-mode' });
    }
    if (snapshot.get('killSwitch') === true) {
      throw new OtpError('service-unavailable', { logCategory: 'kill-switch' });
    }
    return {
      mode,
      allowedPhoneHashes: Array.isArray(snapshot.get('allowedPhoneHashes'))
        ? snapshot.get('allowedPhoneHashes').map(String)
        : [],
      canaryPercent: Math.max(0, Math.min(100, Number(snapshot.get('canaryPercent') ?? 0))),
    };
  }

  async function acquireSend(input) {
    const now = input.now ?? Date.now();
    const challengeId = crypto.randomBytes(24).toString('base64url');
    const leaseId = crypto.randomUUID();
    const activeRef = db.doc(`phone_otp_active/${input.purpose}_${input.phoneHash}`);
    const challengeRef = db.doc(`phone_otp_challenges/${challengeId}`);
    const phoneGuardRef = db.doc(`phone_otp_rate_limits/phone_guard_${input.phoneHash}`);
    const hour = windowKey(now, 60 * 60 * 1000);
    const day = windowKey(now, 24 * 60 * 60 * 1000);
    const rateRefs = [
      [db.doc(`phone_otp_rate_limits/phone_hour_${input.phoneHash}_${hour}`), OTP_CONFIG.maxPhoneSendsPerHour],
      [db.doc(`phone_otp_rate_limits/phone_day_${input.phoneHash}_${day}`), OTP_CONFIG.maxPhoneSendsPerDay],
      [db.doc(`phone_otp_rate_limits/install_hour_${input.installationHash}_${hour}`), OTP_CONFIG.maxInstallationSendsPerHour],
      [db.doc(`phone_otp_rate_limits/ip_hour_${input.ipHash}_${hour}`), OTP_CONFIG.maxIpPrefixSendsPerHour],
      [db.doc(`phone_otp_rate_limits/global_hour_${hour}`), OTP_CONFIG.maxGlobalSendsPerHour],
    ];

    return db.runTransaction(async (transaction) => {
      const activeSnapshot = await transaction.get(activeRef);
      const phoneGuardSnapshot = await transaction.get(phoneGuardRef);
      const phoneGuard = nextPhoneSendGuard(phoneGuardSnapshot.data(), now);
      let currentRef = challengeRef;
      let currentSnapshot = null;
      if (activeSnapshot.exists) {
        const activeChallengeId = String(activeSnapshot.get('challengeId') ?? '');
        if (activeChallengeId) {
          currentRef = db.doc(`phone_otp_challenges/${activeChallengeId}`);
          currentSnapshot = await transaction.get(currentRef);
        }
      }
      const rateSnapshots = await Promise.all(rateRefs.map(([ref]) => transaction.get(ref)));
      for (let index = 0; index < rateRefs.length; index += 1) {
        if (Number(rateSnapshots[index].get('count') ?? 0) >= rateRefs[index][1]) {
          throw new OtpError('send-limit-reached', { logCategory: 'local-rate-limit' });
        }
      }

      let sendCount = 1;
      const current = currentSnapshot?.data() ?? null;
      const currentExpiresAt = current?.expiresAt?.toMillis?.() ?? 0;
      if (current && ACTIVE_STATUSES.has(current.status) && currentExpiresAt > now) {
        const retryAt = current.retryAvailableAt?.toMillis?.() ?? 0;
        const leaseExpiresAt = current.sendLeaseExpiresAt?.toMillis?.() ?? 0;
        if (retryAt > now || (current.status === 'sending' && leaseExpiresAt > now)) {
          throw new OtpError('send-limit-reached', { logCategory: 'send-cooldown' });
        }
        sendCount = Number(current.sendCount ?? 0) + 1;
        if (sendCount > OTP_CONFIG.maxProviderSends) {
          throw new OtpError('send-limit-reached', { logCategory: 'challenge-send-limit' });
        }
      } else {
        currentRef = challengeRef;
      }

      for (let index = 0; index < rateRefs.length; index += 1) {
        const [ref] = rateRefs[index];
        transaction.set(ref, {
          count: Number(rateSnapshots[index].get('count') ?? 0) + 1,
          expiresAt: timestamp(index === 1 ? now + 2 * 24 * 60 * 60 * 1000 : now + 2 * 60 * 60 * 1000),
        }, { merge: true });
      }
      transaction.set(phoneGuardRef, phoneGuard);
      transaction.set(currentRef, {
        phoneCiphertext: input.phoneCiphertext,
        phoneHash: input.phoneHash,
        purpose: input.purpose,
        provider: input.provider,
        migrationMode: input.migrationMode,
        installationHash: input.installationHash,
        clientVersion: input.clientVersion,
        status: 'sending',
        channel: OTP_CONFIG.channel,
        createdAt: current?.createdAt ?? timestamp(now),
        expiresAt: timestamp(now + OTP_CONFIG.challengeTtlMs),
        retryAvailableAt: timestamp(now + OTP_CONFIG.resendCooldownMs),
        sendCount,
        verifyAttemptCount: Number(current?.verifyAttemptCount ?? 0),
        sendLeaseId: leaseId,
        sendLeaseExpiresAt: timestamp(now + OTP_CONFIG.sendLeaseMs),
        schemaVersion: OTP_CONFIG.schemaVersion,
      }, { merge: true });
      transaction.set(activeRef, {
        challengeId: currentRef.id,
        expiresAt: timestamp(now + OTP_CONFIG.challengeTtlMs),
      });
      return { challengeId: currentRef.id, leaseId };
    });
  }

  async function finalizeSend(challengeId, leaseId, result) {
    const ref = db.doc(`phone_otp_challenges/${challengeId}`);
    await db.runTransaction(async (transaction) => {
      const snapshot = await transaction.get(ref);
      if (!snapshot.exists || snapshot.get('sendLeaseId') !== leaseId) return;
      const now = Date.now();
      const wasSent = result.message === 'CODE_SENT';
      transaction.set(ref, {
        status: wasSent ? 'sent' : 'failed',
        channel: result.channel || OTP_CONFIG.channel,
        providerResultCode: result.message,
        sentAt: wasSent ? timestamp(now) : null,
        ...(wasSent ? {
          expiresAt: timestamp(now + OTP_CONFIG.challengeTtlMs),
          retryAvailableAt: timestamp(now + OTP_CONFIG.resendCooldownMs),
        } : {}),
        sendLeaseId: null,
        sendLeaseExpiresAt: null,
      }, { merge: true });
    });
  }

  async function acquireVerify(input) {
    const now = input.now ?? Date.now();
    const leaseId = crypto.randomUUID();
    const ref = db.doc(`phone_otp_challenges/${input.challengeId}`);
    const outcome = await db.runTransaction(async (transaction) => {
      const snapshot = await transaction.get(ref);
      if (!snapshot.exists) throw new OtpError('code-expired');
      const challenge = snapshot.data();
      if (challenge.provider !== input.provider) {
        throw new OtpError('code-expired', { logCategory: 'provider-mismatch' });
      }
      if (!valuesMatch(challenge.installationHash, input.installationHash)) {
        throw new OtpError('code-expired', { logCategory: 'installation-mismatch' });
      }
      if ((challenge.expiresAt?.toMillis?.() ?? 0) <= now) {
        transaction.set(ref, { status: 'expired' }, { merge: true });
        return { errorCode: 'code-expired' };
      }
      if (challenge.status === 'consumed' || challenge.status === 'locked') {
        throw new OtpError(
          challenge.status === 'locked' ? 'too-many-attempts' : 'code-expired',
        );
      }
      const leaseExpiresAt = challenge.verifyLeaseExpiresAt?.toMillis?.() ?? 0;
      if (challenge.status === 'verifying' && leaseExpiresAt > now) {
        throw new OtpError('too-many-attempts', { logCategory: 'verify-in-progress' });
      }
      if (!['sent', 'verifying'].includes(challenge.status)) {
        throw new OtpError('code-expired');
      }
      const attempts = Number(challenge.verifyAttemptCount ?? 0) + 1;
      if (attempts > OTP_CONFIG.maxVerifyAttempts) {
        transaction.set(ref, { status: 'locked' }, { merge: true });
        return { errorCode: 'too-many-attempts' };
      }
      transaction.set(ref, {
        status: 'verifying',
        verifyAttemptCount: attempts,
        verifyLeaseId: leaseId,
        verifyLeaseExpiresAt: timestamp(now + OTP_CONFIG.verifyLeaseMs),
      }, { merge: true });
      return { challenge, leaseId, attempts };
    });
    if (outcome.errorCode) throw new OtpError(outcome.errorCode);
    return outcome;
  }

  async function finalizeVerify(challengeId, leaseId, result, resolvedUid = '') {
    const ref = db.doc(`phone_otp_challenges/${challengeId}`);
    return db.runTransaction(async (transaction) => {
      const snapshot = await transaction.get(ref);
      if (!snapshot.exists || snapshot.get('verifyLeaseId') !== leaseId) {
        throw new OtpError('code-expired', { logCategory: 'verify-lease-lost' });
      }
      const attempts = Number(snapshot.get('verifyAttemptCount') ?? 0);
      let status = 'sent';
      if (result.message === 'CODE_VALID') status = 'consumed';
      if (result.message === 'WRONG_CODE' && attempts >= OTP_CONFIG.maxVerifyAttempts) {
        status = 'locked';
      }
      transaction.set(ref, {
        status,
        providerResultCode: result.message,
        verifyLeaseId: null,
        verifyLeaseExpiresAt: null,
        ...(status === 'consumed' ? {
          consumedAt: Timestamp.now(),
          resolvedUid,
        } : {}),
      }, { merge: true });
      return status;
    });
  }

  return { acquireSend, acquireVerify, finalizeSend, finalizeVerify, runtimeConfig };
}

module.exports = { createChallengeStore, nextPhoneSendGuard };