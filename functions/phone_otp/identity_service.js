'use strict';

const { FieldValue, Timestamp } = require('firebase-admin/firestore');
const { OtpError } = require('./errors');
const { normalizePhone } = require('./phone_normalization');

function createIdentityService(db, auth) {
  async function authUserByPhone(phone) {
    try {
      return await auth.getUserByPhoneNumber(phone);
    } catch (error) {
      if (error?.code === 'auth/user-not-found') return null;
      throw error;
    }
  }

  async function authUserByUid(uid) {
    try {
      return await auth.getUser(uid);
    } catch (error) {
      if (error?.code === 'auth/user-not-found') return null;
      throw error;
    }
  }

  async function inspect(phone) {
    const mappingSnapshot = await db.doc(`registered_phones/${phone}`).get();
    const mappingUid = String(mappingSnapshot.get('uid') ?? '').trim();
    const phoneUser = await authUserByPhone(phone);
    if (mappingUid && !phoneUser) {
      throw new OtpError('account-conflict', { logCategory: 'missing-phone-binding' });
    }
    if (mappingUid && phoneUser && mappingUid !== phoneUser.uid) {
      throw new OtpError('account-conflict', { logCategory: 'identity-conflict' });
    }
    const uid = mappingUid || phoneUser?.uid || '';
    const user = uid ? (phoneUser?.uid === uid ? phoneUser : await authUserByUid(uid)) : null;
    if (uid && !user) {
      throw new OtpError('account-conflict', { logCategory: 'missing-auth-user' });
    }
    if (user?.phoneNumber && normalizePhone(user.phoneNumber) !== phone) {
      throw new OtpError('account-conflict', { logCategory: 'phone-mismatch' });
    }
    const profile = uid ? await db.doc(`users/${uid}`).get() : null;
    return { mappingUid, phoneUser, profile, uid, user };
  }

  function assertAccountAllowed(user, profile) {
    if (user.disabled || profile?.get('isDisabled') === true) {
      throw new OtpError('account-disabled');
    }
    if (profile?.get('isDeleted') === true || profile?.get('deletedAt')) {
      throw new OtpError('account-disabled', { logCategory: 'deleted-account' });
    }
    if (profile?.get('isAgeRestricted') === true) {
      throw new OtpError('age-restricted');
    }
  }

  function assertRecoveryAllowed(user, profile) {
    assertAccountAllowed(user, profile);
    const onboardingStep = String(
      profile?.get('onboardingStep') ?? 'pending_verification',
    );
    if (!['active', 'pending_profile', 'expired'].includes(onboardingStep)) {
      throw new OtpError('registration-incomplete');
    }
  }

  async function preflight(phone, purpose) {
    const state = await inspect(phone);
    if (purpose === 'registration') {
      if (state.uid && state.profile?.get('onboardingStep') === 'active') {
        throw new OtpError('phone-already-registered');
      }
      if (state.user) assertAccountAllowed(state.user, state.profile);
      const hasPasswordProvider = state.user?.providerData?.some(
        (provider) => provider.providerId === 'password',
      ) === true;
      if (state.mappingUid && state.user && !hasPasswordProvider) {
        await db.doc(`registered_phones/${phone}`).delete();
      }
      return;
    }
    if (!state.mappingUid || !state.user || !state.profile?.exists) {
      throw new OtpError('phone-not-registered');
    }
    if (!state.phoneUser || state.phoneUser.uid !== state.mappingUid) {
      throw new OtpError('account-conflict', { logCategory: 'recovery-phone-binding' });
    }
    assertRecoveryAllowed(state.user, state.profile);
  }

  async function resolveRegistration(phone, phoneHash, challengeId) {
    const state = await inspect(phone);
    if (state.uid) {
      assertAccountAllowed(state.user, state.profile);
      if (state.profile?.get('onboardingStep') === 'active') {
        throw new OtpError('phone-already-registered');
      }
      await db.doc(`phone_otp_identity_reservations/${phoneHash}`).set({
        uid: state.uid,
        state: 'auth_created',
        updatedAt: FieldValue.serverTimestamp(),
      }, { merge: true });
      return { uid: state.uid, isNewUser: false };
    }

    const reservationRef = db.doc(`phone_otp_identity_reservations/${phoneHash}`);
    const reservationUid = await db.runTransaction(async (transaction) => {
      const snapshot = await transaction.get(reservationRef);
      const uid = String(snapshot.get('uid') ?? '').trim();
      const expiresAt = snapshot.get('leaseExpiresAt')?.toMillis?.() ?? 0;
      if (uid) return uid;
      if (snapshot.exists && expiresAt > Date.now() && snapshot.get('challengeId') !== challengeId) {
        throw new OtpError('account-conflict', { logCategory: 'identity-reserved' });
      }
      transaction.set(reservationRef, {
        challengeId,
        state: 'reserved',
        leaseExpiresAt: Timestamp.fromMillis(Date.now() + 60 * 1000),
        updatedAt: FieldValue.serverTimestamp(),
      }, { merge: true });
      return '';
    });

    let user = reservationUid ? await authUserByUid(reservationUid) : null;
    let isNewUser = false;
    if (reservationUid) {
      if (user && (!user.phoneNumber || normalizePhone(user.phoneNumber) !== phone)) {
        throw new OtpError('account-conflict', { logCategory: 'stale-identity-reservation' });
      }
      if (user) {
        const profile = await db.doc(`users/${user.uid}`).get();
        assertAccountAllowed(user, profile);
        if (profile.get('onboardingStep') === 'active') {
          throw new OtpError('phone-already-registered');
        }
      }
    }
    if (!user) {
      try {
        user = await auth.createUser({ phoneNumber: phone });
        isNewUser = true;
      } catch (error) {
        if (error?.code !== 'auth/phone-number-already-exists') throw error;
        const racedState = await inspect(phone);
        if (!racedState.user || racedState.user.uid !== racedState.phoneUser?.uid) {
          throw new OtpError('account-conflict', { logCategory: 'auth-create-race' });
        }
        assertAccountAllowed(racedState.user, racedState.profile);
        if (racedState.profile?.get('onboardingStep') === 'active') {
          throw new OtpError('phone-already-registered');
        }
        user = racedState.user;
      }
    }
    if (!user) throw new OtpError('account-conflict', { logCategory: 'auth-create' });

    await reservationRef.set({
      uid: user.uid,
      state: 'auth_created',
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });
    return { uid: user.uid, isNewUser };
  }

  async function resolveRecovery(phone) {
    const state = await inspect(phone);
    if (!state.mappingUid || !state.user || !state.phoneUser || !state.profile?.exists) {
      throw new OtpError('phone-not-registered');
    }
    if (state.phoneUser.uid !== state.mappingUid) {
      throw new OtpError('account-conflict', { logCategory: 'recovery-phone-binding' });
    }
    assertRecoveryAllowed(state.user, state.profile);
    return { uid: state.uid, isNewUser: false };
  }

  async function resolve(phone, phoneHash, purpose, challengeId) {
    return purpose === 'registration'
      ? resolveRegistration(phone, phoneHash, challengeId)
      : resolveRecovery(phone);
  }

  return { preflight, resolve };
}

module.exports = { createIdentityService };