'use strict';

const https = require('node:https');
const { OTP_CONFIG } = require('./config');
const { OtpError } = require('./errors');

const KNOWN_MESSAGES = new Set([
  'CODE_SENT',
  'CODE_VALID',
  'WRONG_CODE',
  'MAX_SENT',
  'ERROR',
]);

function parseProviderResponse(rawBody, statusCode) {
  if (!Number.isInteger(statusCode) || statusCode < 200 || statusCode >= 300) {
    throw new OtpError('service-unavailable', { logCategory: 'provider-http' });
  }

  let payload;
  try {
    payload = JSON.parse(rawBody);
  } catch (_) {
    throw new OtpError('service-unavailable', { logCategory: 'provider-json' });
  }
  const message = String(payload?.message ?? '').trim().toUpperCase();
  if (!KNOWN_MESSAGES.has(message)) {
    throw new OtpError('service-unavailable', { logCategory: 'provider-contract' });
  }

  const channel = String(payload?.data?.channel ?? '').trim().toLowerCase();
  return {
    message,
    channel: ['sms', 'vms', 'wa'].includes(channel) ? channel : '',
  };
}

function postJson(payload, options = {}) {
  const requestFactory = options.requestFactory || https.request;
  const endpoint = options.endpoint || OTP_CONFIG.endpoint;
  const requestTimeoutMs = options.requestTimeoutMs || OTP_CONFIG.requestTimeoutMs;
  const body = JSON.stringify(payload);

  return new Promise((resolve, reject) => {
    let settled = false;
    let connectTimer;
    const totalTimer = setTimeout(() => {
      request.destroy();
      fail('provider-total-timeout');
    }, requestTimeoutMs);
    const finish = (callback, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(connectTimer);
      clearTimeout(totalTimer);
      callback(value);
    };
    const fail = (category) => finish(
      reject,
      new OtpError('network-error', { logCategory: category }),
    );

    const request = requestFactory(endpoint, {
      method: 'POST',
      headers: {
        'content-type': 'application/json; charset=utf-8',
        'content-length': Buffer.byteLength(body),
      },
    }, (response) => {
      let size = 0;
      const chunks = [];
      response.on('data', (chunk) => {
        size += chunk.length;
        if (size > OTP_CONFIG.maxResponseBytes) {
          request.destroy();
          fail('provider-response-too-large');
          return;
        }
        chunks.push(chunk);
      });
      response.on('end', () => {
        try {
          finish(
            resolve,
            parseProviderResponse(Buffer.concat(chunks).toString('utf8'), response.statusCode),
          );
        } catch (error) {
          finish(reject, error);
        }
      });
    });

    request.on('socket', (socket) => {
      if (!socket.connecting) return;
      connectTimer = setTimeout(() => {
        request.destroy();
        fail('provider-connect-timeout');
      }, OTP_CONFIG.connectTimeoutMs);
      socket.once('connect', () => clearTimeout(connectTimer));
      socket.once('secureConnect', () => clearTimeout(connectTimer));
    });
    request.setTimeout(requestTimeoutMs, () => {
      request.destroy();
      fail('provider-inactivity-timeout');
    });
    request.on('error', () => fail('provider-network'));
    request.end(body);
  });
}

function createMicropayClient(token, options = {}) {
  const normalizedToken = String(token ?? '').trim();
  if (!normalizedToken) {
    throw new OtpError('service-unavailable', { logCategory: 'provider-secret' });
  }

  return {
    sendCode: (phone) => postJson({
      token: normalizedToken,
      phone,
      type: OTP_CONFIG.channel,
      codelen: String(OTP_CONFIG.codeLength),
      minvalid: String(OTP_CONFIG.validityMinutes),
      maxsms: String(OTP_CONFIG.maxProviderSends),
      lang: OTP_CONFIG.language,
      smsfrom: OTP_CONFIG.smsFrom,
      smstext: OTP_CONFIG.smsText,
    }, options),
    verifyCode: (phone, code) => postJson({
      token: normalizedToken,
      phone,
      code,
      codelen: String(OTP_CONFIG.codeLength),
      minvalid: String(OTP_CONFIG.validityMinutes),
    }, options),
  };
}

module.exports = { createMicropayClient, parseProviderResponse };