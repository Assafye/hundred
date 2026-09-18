'use strict';

const { OTP_CONFIG } = require('./config');
const { OtpError } = require('./errors');
const { normalizePhone } = require('./phone_normalization');

function requireObject(data) {
  if (!data || typeof data !== 'object' || Array.isArray(data)) {
    throw new OtpError('invalid-request');
  }
  let size;
  try {
    size = Buffer.byteLength(JSON.stringify(data));
  } catch (_) {
    throw new OtpError('invalid-request');
  }
  if (size > OTP_CONFIG.maxPayloadBytes) throw new OtpError('invalid-request');
}

function requireBoundedString(value, min, max) {
  const normalized = String(value ?? '').trim();
  if (normalized.length < min || normalized.length > max) {
    throw new OtpError('invalid-request');
  }
  return normalized;
}

function validateRequestPhoneOtp(data) {
  requireObject(data);
  const purpose = String(data.purpose ?? '').trim();
  if (!['registration', 'recovery'].includes(purpose)) {
    throw new OtpError('invalid-request');
  }
  if (data.provider !== 'micropay') {
    throw new OtpError('invalid-request');
  }
  return {
    phone: normalizePhone(data.phone),
    purpose,
    provider: 'micropay',
    installationId: requireBoundedString(data.installationId, 16, 256),
    clientVersion: requireBoundedString(data.clientVersion, 1, 64),
  };
}

function validateVerifyPhoneOtp(data) {
  requireObject(data);
  const code = String(data.code ?? '').trim();
  if (!/^\d{6}$/.test(code)) throw new OtpError('invalid-request');
  if (data.provider !== 'micropay') {
    throw new OtpError('invalid-request');
  }
  const challengeId = String(data.challengeId ?? '').trim();
  if (!/^[A-Za-z0-9_-]{20,128}$/.test(challengeId)) {
    throw new OtpError('invalid-request');
  }
  return {
    challengeId,
    code,
    provider: 'micropay',
    installationId: requireBoundedString(data.installationId, 16, 256),
    clientVersion: requireBoundedString(data.clientVersion, 1, 64),
  };
}

function ipPrefix(rawRequest) {
  const forwarded = String(rawRequest?.headers?.['x-forwarded-for'] ?? '').split(',')[0].trim();
  const address = forwarded || String(rawRequest?.ip ?? '').trim();
  if (!address) return 'unknown';
  if (address.includes(':')) return address.split(':').slice(0, 4).join(':');
  return address.split('.').slice(0, 3).join('.');
}

module.exports = { ipPrefix, validateRequestPhoneOtp, validateVerifyPhoneOtp };