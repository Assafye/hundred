'use strict';

const OTP_CONFIG = Object.freeze({
  endpoint: 'https://www.micropay.co.il/extApi/sendOtp.php',
  codeLength: 6,
  validityMinutes: 5,
  maxProviderSends: 3,
  channel: 'sms',
  language: 'he',
  smsFrom: 'hundred',
  smsText: 'קוד האימות שלך הוא:',
  challengeTtlMs: 5 * 60 * 1000,
  resendCooldownMs: 60 * 1000,
  sendLeaseMs: 20 * 1000,
  verifyLeaseMs: 20 * 1000,
  maxVerifyAttempts: 5,
  connectTimeoutMs: 3 * 1000,
  requestTimeoutMs: 8 * 1000,
  maxResponseBytes: 32 * 1024,
  maxPayloadBytes: 2 * 1024,
  maxPhoneSendsPerHour: 3,
  maxPhoneSendsPerDay: 10,
  maxInstallationSendsPerHour: 10,
  maxIpPrefixSendsPerHour: 20,
  maxGlobalSendsPerHour: 1000,
  schemaVersion: 1,
});

module.exports = { OTP_CONFIG };