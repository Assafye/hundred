import 'package:flutter_test/flutter_test.dart';
import 'package:hundred_version1/services/phone_otp_provider_policy.dart';
import 'package:hundred_version1/services/phone_otp_service.dart';

void main() {
  test('defaults new OTP flows to MicroPay', () {
    const policy = PhoneOtpProviderPolicy();
    expect(policy.select(), PhoneOtpProvider.micropay);
  });

  test('allows an explicit Firebase rollback build', () {
    const policy = PhoneOtpProviderPolicy(microPayEnabled: false);
    expect(policy.select(), PhoneOtpProvider.firebase);
  });

  test('keeps an in-progress MicroPay challenge pinned after rollback', () {
    final challenge = PhoneOtpChallenge(
      challengeId: 'abcdefghijklmnopqrstuvwx',
      purpose: PhoneOtpPurpose.recovery,
      expiresAt: DateTime.utc(2026, 9, 18, 12, 5),
      retryAvailableAt: DateTime.utc(2026, 9, 18, 12, 1),
      channel: 'sms',
    );
    const policy = PhoneOtpProviderPolicy(microPayEnabled: false);
    expect(
      policy.select(restoredChallenge: challenge),
      PhoneOtpProvider.micropay,
    );
  });
}
