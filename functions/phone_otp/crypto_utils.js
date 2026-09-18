'use strict';

const crypto = require('node:crypto');
const { OtpError } = require('./errors');

function requireHmacKey(value) {
  const key = Buffer.from(String(value ?? ''), 'utf8');
  if (key.length < 32) {
    throw new OtpError('service-unavailable', { logCategory: 'hmac-secret' });
  }
  return key;
}

function requireEncryptionKey(value) {
  const encoded = String(value ?? '').trim();
  let key;
  try {
    key = Buffer.from(encoded, 'base64');
  } catch (_) {
    key = Buffer.alloc(0);
  }
  if (key.length !== 32 || key.toString('base64').replace(/=+$/, '') !== encoded.replace(/=+$/, '')) {
    throw new OtpError('service-unavailable', { logCategory: 'encryption-secret' });
  }
  return key;
}

function hashValue(value, secret) {
  return crypto.createHmac('sha256', requireHmacKey(secret))
    .update(String(value), 'utf8')
    .digest('hex');
}

function encryptValue(value, secret) {
  const key = requireEncryptionKey(secret);
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', key, iv);
  const ciphertext = Buffer.concat([
    cipher.update(String(value), 'utf8'),
    cipher.final(),
  ]);
  const tag = cipher.getAuthTag();
  return ['v1', iv, tag, ciphertext]
    .map((part) => Buffer.isBuffer(part) ? part.toString('base64url') : part)
    .join('.');
}

function decryptValue(value, secret) {
  const [version, ivText, tagText, ciphertextText, extra] = String(value ?? '').split('.');
  if (version !== 'v1' || !ivText || !tagText || !ciphertextText || extra) {
    throw new OtpError('service-unavailable', { logCategory: 'encrypted-value' });
  }
  try {
    const decipher = crypto.createDecipheriv(
      'aes-256-gcm',
      requireEncryptionKey(secret),
      Buffer.from(ivText, 'base64url'),
    );
    decipher.setAuthTag(Buffer.from(tagText, 'base64url'));
    return Buffer.concat([
      decipher.update(Buffer.from(ciphertextText, 'base64url')),
      decipher.final(),
    ]).toString('utf8');
  } catch (error) {
    if (error instanceof OtpError) throw error;
    throw new OtpError('service-unavailable', { logCategory: 'decrypt-failed' });
  }
}

function valuesMatch(left, right) {
  const leftBuffer = Buffer.from(String(left ?? ''), 'utf8');
  const rightBuffer = Buffer.from(String(right ?? ''), 'utf8');
  return leftBuffer.length === rightBuffer.length &&
    crypto.timingSafeEqual(leftBuffer, rightBuffer);
}

module.exports = { decryptValue, encryptValue, hashValue, valuesMatch };