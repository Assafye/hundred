'use strict';

const { logger } = require('firebase-functions');
const { OTP_CONFIG } = require('./config');
const { decryptValue, encryptValue, hashValue } = require('./crypto_utils');
const { OtpError, toHttpsError } = require('./errors');
const { createChallengeStore } = require('./challenge_store');
const { createIdentityService } = require('./identity_service');
const { createMicropayClient } = require('./micropay_client');
const { toProviderPhone } = require('./phone_normalization');
const {
  ipPrefix,
  validateRequestPhoneOtp,
  validateVerifyPhoneOtp,
} = require('./validation');

function createPhoneOtpHandlers(dependencies) {
  const store = createChallengeStore(dependencies.db);
  const identity = createIdentityService(dependencies.db, dependencies.auth);

  function logEvent(event, fields = {}) {
    logger.info('phone_otp_event', { event, ...fields });
  }

  function assertRolloutEligibility(runtime, phoneHash, installationHash) {
    if (runtime.mode === 'micropay_internal' &&
        !runtime.allowedPhoneHashes.includes(phoneHash)) {
      throw new OtpError('service-unavailable', { logCategory: 'internal-allowlist' });
    }
    if (runtime.mode === 'micropay_canary') {
      const bucket = Number.parseInt(installationHash.slice(0, 8), 16) % 10000;
      if (bucket >= Math.floor(runtime.canaryPercent * 100)) {
        throw new OtpError('service-unavailable', { logCategory: 'canary-ineligible' });
      }
    }
  }

  async function requestPhoneOtp(request) {
    const correlationId = dependencies.randomId();
    try {
      const input = validateRequestPhoneOtp(request.data);
      const runtime = await store.runtimeConfig();
      const hmacSecret = dependencies.hmacSecret.value();
      const encryptionSecret = dependencies.encryptionSecret.value();
      const phoneHash = hashValue(input.phone, hmacSecret);
      const installationHash = hashValue(input.installationId, hmacSecret);
      const ipHash = hashValue(ipPrefix(request.rawRequest), hmacSecret);
      assertRolloutEligibility(runtime, phoneHash, installationHash);
      await identity.preflight(input.phone, input.purpose);
      const lease = await store.acquireSend({
        ...input,
        migrationMode: runtime.mode,
        phoneHash,
        installationHash,
        ipHash,
        phoneCiphertext: encryptValue(input.phone, encryptionSecret),
      });
      const client = createMicropayClient(dependencies.micropayToken.value());
      let result;
      try {
        result = await client.sendCode(toProviderPhone(input.phone));
      } catch (error) {
        await store.finalizeSend(lease.challengeId, lease.leaseId, { message: 'ERROR' });
        throw error;
      }
      await store.finalizeSend(lease.challengeId, lease.leaseId, result);
      logEvent('send_result', {
        correlationId,
        purpose: input.purpose,
        clientVersion: input.clientVersion,
        appCheck: request.app ? 'valid' : 'missing',
        mode: runtime.mode,
        result: result.message,
        channel: result.channel || OTP_CONFIG.channel,
      });
      if (result.message === 'MAX_SENT') throw new OtpError('send-limit-reached');
      if (result.message !== 'CODE_SENT') {
        throw new OtpError('service-unavailable', { logCategory: 'provider-error' });
      }
      return {
        challengeId: lease.challengeId,
        expiresInSeconds: OTP_CONFIG.challengeTtlMs / 1000,
        retryAfterSeconds: OTP_CONFIG.resendCooldownMs / 1000,
        channel: result.channel || OTP_CONFIG.channel,
      };
    } catch (error) {
      const safeError = error instanceof OtpError
        ? error
        : new OtpError('service-unavailable', { logCategory: 'unexpected' });
      logger.warn('phone_otp_event', {
        event: 'request_rejected',
        correlationId,
        category: safeError.logCategory,
        appCheck: request.app ? 'valid' : 'missing',
      });
      throw toHttpsError(safeError);
    }
  }

  async function verifyPhoneOtp(request) {
    const correlationId = dependencies.randomId();
    try {
      const input = validateVerifyPhoneOtp(request.data);
      const hmacSecret = dependencies.hmacSecret.value();
      const installationHash = hashValue(input.installationId, hmacSecret);
      const acquired = await store.acquireVerify({
        challengeId: input.challengeId,
        provider: input.provider,
        installationHash,
      });
      const challenge = acquired.challenge;
      const phone = decryptValue(
        challenge.phoneCiphertext,
        dependencies.encryptionSecret.value(),
      );
      const client = createMicropayClient(dependencies.micropayToken.value());
      let result;
      try {
        result = await client.verifyCode(toProviderPhone(phone), input.code);
      } catch (error) {
        await store.finalizeVerify(input.challengeId, acquired.leaseId, { message: 'ERROR' });
        throw error;
      }
      if (result.message === 'WRONG_CODE') {
        const status = await store.finalizeVerify(input.challengeId, acquired.leaseId, result);
        throw new OtpError(status === 'locked' ? 'too-many-attempts' : 'wrong-code');
      }
      if (result.message !== 'CODE_VALID') {
        await store.finalizeVerify(input.challengeId, acquired.leaseId, result);
        throw new OtpError('service-unavailable', { logCategory: 'provider-error' });
      }

      const resolved = await identity.resolve(
        phone,
        challenge.phoneHash,
        challenge.purpose,
        input.challengeId,
      );
      const firebaseCustomToken = await dependencies.auth.createCustomToken(resolved.uid);
      await store.finalizeVerify(
        input.challengeId,
        acquired.leaseId,
        result,
        resolved.uid,
      );
      logEvent('verify_result', {
        correlationId,
        purpose: challenge.purpose,
        clientVersion: input.clientVersion,
        appCheck: request.app ? 'valid' : 'missing',
        mode: challenge.migrationMode || 'unknown',
        result: result.message,
      });
      return {
        firebaseCustomToken,
        purpose: challenge.purpose,
        isNewUser: resolved.isNewUser,
      };
    } catch (error) {
      const safeError = error instanceof OtpError
        ? error
        : new OtpError('service-unavailable', { logCategory: 'unexpected' });
      logger.warn('phone_otp_event', {
        event: 'verify_rejected',
        correlationId,
        category: safeError.logCategory,
        appCheck: request.app ? 'valid' : 'missing',
      });
      throw toHttpsError(safeError);
    }
  }

  return { requestPhoneOtp, verifyPhoneOtp };
}

module.exports = { createPhoneOtpHandlers };