'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const {
  decryptValue,
  encryptValue,
  hashValue,
  valuesMatch,
} = require('../phone_otp/crypto_utils');
const { OtpError, toHttpsError } = require('../phone_otp/errors');
const {
  createMicropayClient,
  parseProviderResponse,
} = require('../phone_otp/micropay_client');
const {
  normalizePhone,
  toProviderPhone,
} = require('../phone_otp/phone_normalization');
const {
  validateRequestPhoneOtp,
  validateVerifyPhoneOtp,
} = require('../phone_otp/validation');
const { createIdentityService } = require('../phone_otp/identity_service');
const { nextPhoneSendGuard } = require('../phone_otp/challenge_store');

function requestPayloadFor(invoke) {
  let payload;
  const requestFactory = (_endpoint, _options, callback) => {
    const response = new (require('node:events').EventEmitter)();
    response.statusCode = 200;
    const request = new (require('node:events').EventEmitter)();
    request.setTimeout = () => {};
    request.destroy = () => {};
    request.end = (body) => {
      payload = JSON.parse(body);
      callback(response);
      response.emit('data', Buffer.from('{"message":"CODE_SENT"}'));
      response.emit('end');
    };
    return request;
  };
  return invoke(createMicropayClient('test-token', { requestFactory }))
    .then(() => payload);
}

test('normalizes supported Israeli phone formats', () => {
  assert.equal(normalizePhone('050-123-4567'), '+972501234567');
  assert.equal(normalizePhone('972501234567'), '+972501234567');
  assert.equal(normalizePhone('+972 50 123 4567'), '+972501234567');
  assert.equal(toProviderPhone('+972501234567'), '0501234567');
});

test('rejects malformed phone input', () => {
  assert.throws(() => normalizePhone('050abc1234'), { code: 'invalid-phone-number' });
  assert.throws(() => normalizePhone('12345'), { code: 'invalid-phone-number' });
});

test('parses only exact allow-listed provider messages', () => {
  assert.deepEqual(
    parseProviderResponse('{"status":1,"message":" code_sent ","data":{"channel":"sms"}}', 200),
    { message: 'CODE_SENT', channel: 'sms' },
  );
  assert.equal(
    parseProviderResponse('{"status":1,"message":"WRONG_CODE"}', 200).message,
    'WRONG_CODE',
  );
  assert.equal(
    parseProviderResponse('{"status":1,"message":"MAX_SENT"}', 200).message,
    'MAX_SENT',
  );
  assert.throws(
    () => parseProviderResponse('{"status":1,"message":"CODE_SENT_LATER"}', 200),
    { code: 'service-unavailable' },
  );
});

test('fails closed for malformed and non-success responses', () => {
  assert.throws(() => parseProviderResponse('not-json', 200), {
    logCategory: 'provider-json',
  });
  assert.throws(() => parseProviderResponse('{"message":"CODE_SENT"}', 503), {
    logCategory: 'provider-http',
  });
});

test('public callable errors do not expose sensitive source text', () => {
  const error = toHttpsError(new OtpError('service-unavailable', {
    logCategory: 'token +972501234567 123456',
  }));
  assert.equal(error.message, 'service-unavailable');
  assert.deepEqual(error.details, { code: 'service-unavailable' });
});

test('client refuses to initialize without a provider token', () => {
  assert.throws(() => createMicropayClient(''), { code: 'service-unavailable' });
});

test('sends the approved MicroPay SMS contract', async () => {
  const payload = await requestPayloadFor(
    (client) => client.sendCode('0501234567'),
  );
  assert.deepEqual(payload, {
    token: 'test-token',
    phone: '0501234567',
    type: 'sms',
    codelen: '6',
    minvalid: '5',
    maxsms: '3',
    lang: 'he',
    smsfrom: 'hundred',
    smstext: 'קוד האימות שלך הוא:',
  });
});

test('rejects a provider call that exceeds the total deadline', async () => {
  const requestFactory = () => {
    const request = new (require('node:events').EventEmitter)();
    request.setTimeout = () => {};
    request.destroy = () => {};
    request.end = () => {};
    return request;
  };
  const client = createMicropayClient('test-token', {
    requestFactory,
    requestTimeoutMs: 5,
  });
  await assert.rejects(client.sendCode('0501234567'), {
    code: 'network-error',
    logCategory: 'provider-total-timeout',
  });
});

test('encrypts recoverable phone data and derives stable keyed hashes', () => {
  const encryptionKey = Buffer.alloc(32, 7).toString('base64');
  const hmacKey = 'a'.repeat(32);
  const encrypted = encryptValue('+972501234567', encryptionKey);
  assert.equal(encrypted.includes('+972501234567'), false);
  assert.equal(decryptValue(encrypted, encryptionKey), '+972501234567');
  assert.equal(hashValue('value', hmacKey), hashValue('value', hmacKey));
  assert.notEqual(hashValue('value', hmacKey), hashValue('other', hmacKey));
  assert.equal(valuesMatch(hashValue('value', hmacKey), hashValue('value', hmacKey)), true);
});

test('requires strong correctly encoded storage secrets', () => {
  assert.throws(() => hashValue('value', 'short'), { logCategory: 'hmac-secret' });
  assert.throws(() => encryptValue('value', 'not-base64'), {
    logCategory: 'encryption-secret',
  });
});

test('validates callable payload contracts', () => {
  assert.deepEqual(validateRequestPhoneOtp({
    phone: '0501234567',
    purpose: 'registration',
    provider: 'micropay',
    installationId: 'installation-id-123',
    clientVersion: '1.0.5+11',
  }), {
    phone: '+972501234567',
    purpose: 'registration',
    provider: 'micropay',
    installationId: 'installation-id-123',
    clientVersion: '1.0.5+11',
  });
  assert.deepEqual(validateVerifyPhoneOtp({
    challengeId: 'abcdefghijklmnopqrstuvwx',
    code: '012345',
    provider: 'micropay',
    installationId: 'installation-id-123',
    clientVersion: '1.0.5+11',
  }).code, '012345');
  assert.throws(() => validateVerifyPhoneOtp({
    challengeId: 'abcdefghijklmnopqrstuvwx',
    code: '12345a',
    provider: 'micropay',
    installationId: 'installation-id-123',
    clientVersion: '1.0.5+11',
  }), { code: 'invalid-request' });
  assert.throws(() => validateRequestPhoneOtp({
    phone: '0501234567',
    purpose: 'registration',
    provider: 'firebase',
    installationId: 'installation-id-123',
    clientVersion: '1.0.5+11',
  }), { code: 'invalid-request' });
});

test('revalidates recovery account state before resolving identity', async () => {
  let onboardingStep = 'active';
  const user = {
    uid: 'existing-uid',
    phoneNumber: '+972501234567',
    disabled: false,
  };
  const snapshot = (data, exists = true) => ({
    exists,
    get: (key) => data[key],
  });
  const db = {
    doc: (path) => ({
      get: async () => {
        if (path === 'registered_phones/+972501234567') {
          return snapshot({ uid: user.uid });
        }
        if (path === `users/${user.uid}`) {
          return snapshot({ onboardingStep });
        }
        throw new Error(`Unexpected document: ${path}`);
      },
    }),
  };
  const auth = {
    getUserByPhoneNumber: async () => user,
    getUser: async () => user,
  };
  const identity = createIdentityService(db, auth);

  await identity.preflight('+972501234567', 'recovery');
  onboardingStep = 'pending_verification';
  await assert.rejects(
    identity.resolve('+972501234567', 'phone-hash', 'recovery', 'challenge-id'),
    { code: 'registration-incomplete' },
  );
});

test('does not register a phone before password setup', async () => {
  const user = {
    uid: 'temporary-uid',
    phoneNumber: '+972501234567',
    disabled: false,
  };
  const writes = [];
  const snapshot = (data = {}, exists = false) => ({
    exists,
    get: (key) => data[key],
  });
  const db = {
    doc: (path) => ({
      get: async () => {
        if (path === 'registered_phones/+972501234567') return snapshot();
        if (path === `users/${user.uid}`) return snapshot();
        throw new Error(`Unexpected document: ${path}`);
      },
      set: async (data) => writes.push({ path, data }),
    }),
  };
  const auth = {
    getUserByPhoneNumber: async () => user,
    getUser: async () => user,
  };
  const identity = createIdentityService(db, auth);

  const result = await identity.resolve(
    '+972501234567',
    'phone-hash',
    'registration',
    'challenge-id',
  );

  assert.equal(result.uid, user.uid);
  assert.equal(
    writes.some(({ path }) => path.startsWith('registered_phones/')),
    false,
  );
  assert.equal(writes.length, 1);
  assert.equal(writes[0].path, 'phone_otp_identity_reservations/phone-hash');
  assert.equal(writes[0].data.state, 'auth_created');
});

test('removes a legacy phone mapping for an incomplete passwordless registration', async () => {
  let mappingDeleted = false;
  const user = {
    uid: 'temporary-uid',
    phoneNumber: '+972501234567',
    disabled: false,
    providerData: [{ providerId: 'phone' }],
  };
  const snapshot = (data = {}, exists = false) => ({
    exists,
    get: (key) => data[key],
  });
  const db = {
    doc: (path) => ({
      get: async () => {
        if (path === 'registered_phones/+972501234567') {
          return snapshot({ uid: user.uid }, true);
        }
        if (path === `users/${user.uid}`) return snapshot();
        throw new Error(`Unexpected document: ${path}`);
      },
      delete: async () => {
        mappingDeleted = true;
      },
    }),
  };
  const auth = {
    getUserByPhoneNumber: async () => user,
    getUser: async () => user,
  };
  const identity = createIdentityService(db, auth);

  await identity.preflight('+972501234567', 'registration');

  assert.equal(mappingDeleted, true);
});

test('preserves a phone mapping after password setup', async () => {
  let mappingDeleted = false;
  const user = {
    uid: 'pending-profile-uid',
    phoneNumber: '+972501234567',
    disabled: false,
    providerData: [
      { providerId: 'phone' },
      { providerId: 'password' },
    ],
  };
  const snapshot = (data = {}, exists = false) => ({
    exists,
    get: (key) => data[key],
  });
  const db = {
    doc: (path) => ({
      get: async () => {
        if (path === 'registered_phones/+972501234567') {
          return snapshot({ uid: user.uid }, true);
        }
        if (path === `users/${user.uid}`) {
          return snapshot({ onboardingStep: 'pending_profile' }, true);
        }
        throw new Error(`Unexpected document: ${path}`);
      },
      delete: async () => {
        mappingDeleted = true;
      },
    }),
  };
  const auth = {
    getUserByPhoneNumber: async () => user,
    getUser: async () => user,
  };
  const identity = createIdentityService(db, auth);

  await identity.preflight('+972501234567', 'registration');

  assert.equal(mappingDeleted, false);
});

test('locks a phone for one full hour after the third send attempt', () => {
  const firstAt = Date.UTC(2026, 8, 18, 12);
  const timestampValue = (milliseconds) => ({
    toMillis: () => milliseconds,
  });
  const first = nextPhoneSendGuard(null, firstAt);
  const second = nextPhoneSendGuard({
    count: first.count,
    windowStartedAt: timestampValue(firstAt),
    blockedUntil: null,
  }, firstAt + 60 * 1000);
  const thirdAt = firstAt + 2 * 60 * 1000;
  const third = nextPhoneSendGuard({
    count: second.count,
    windowStartedAt: timestampValue(firstAt),
    blockedUntil: null,
  }, thirdAt);

  assert.equal(third.count, 3);
  assert.equal(third.blockedUntil.toMillis(), thirdAt + 60 * 60 * 1000);
  assert.throws(() => nextPhoneSendGuard({
    count: third.count,
    windowStartedAt: timestampValue(firstAt),
    blockedUntil: third.blockedUntil,
  }, thirdAt + 59 * 60 * 1000), {
    code: 'send-limit-reached',
    logCategory: 'phone-hour-lock',
  });
});
