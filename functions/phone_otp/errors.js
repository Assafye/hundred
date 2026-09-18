'use strict';

const { HttpsError } = require('firebase-functions/v2/https');

class OtpError extends Error {
  constructor(code, options = {}) {
    super(code);
    this.name = 'OtpError';
    this.code = code;
    this.logCategory = options.logCategory || code;
  }
}

const HTTPS_CODE_BY_OTP_CODE = Object.freeze({
  'invalid-request': 'invalid-argument',
  'invalid-phone-number': 'invalid-argument',
  'phone-already-registered': 'already-exists',
  'phone-not-registered': 'not-found',
  'wrong-code': 'invalid-argument',
  'code-expired': 'deadline-exceeded',
  'too-many-attempts': 'resource-exhausted',
  'send-limit-reached': 'resource-exhausted',
  'network-error': 'unavailable',
  'service-unavailable': 'unavailable',
  'account-disabled': 'permission-denied',
  'age-restricted': 'permission-denied',
  'account-conflict': 'failed-precondition',
  'registration-incomplete': 'failed-precondition',
});

function toHttpsError(error) {
  const otpError = error instanceof OtpError
    ? error
    : new OtpError('service-unavailable', { logCategory: 'unexpected' });
  const httpsCode = HTTPS_CODE_BY_OTP_CODE[otpError.code] || 'internal';
  return new HttpsError(httpsCode, otpError.code, { code: otpError.code });
}

module.exports = { OtpError, toHttpsError };