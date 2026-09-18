'use strict';

const { OtpError } = require('./errors');

function normalizePhone(rawPhone) {
  const input = String(rawPhone ?? '').trim();
  if (!input || input.length > 40 || /[^\d+\s().-]/.test(input)) {
    throw new OtpError('invalid-phone-number');
  }

  let canonical;
  const digits = input.replace(/\D/g, '');
  if (input.startsWith('+')) {
    canonical = `+${digits}`;
  } else if (digits.startsWith('00')) {
    canonical = `+${digits.slice(2)}`;
  } else if (digits.startsWith('0')) {
    canonical = `+972${digits.slice(1)}`;
  } else if (digits.startsWith('972')) {
    canonical = `+${digits}`;
  } else {
    throw new OtpError('invalid-phone-number');
  }

  if (!/^\+[1-9]\d{7,14}$/.test(canonical)) {
    throw new OtpError('invalid-phone-number');
  }
  return canonical;
}

function toProviderPhone(canonicalPhone) {
  const canonical = normalizePhone(canonicalPhone);
  return canonical.startsWith('+972')
    ? `0${canonical.slice(4)}`
    : canonical.slice(1);
}

module.exports = { normalizePhone, toProviderPhone };