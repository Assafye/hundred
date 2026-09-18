import 'package:flutter_test/flutter_test.dart';
import 'package:hundred_version1/services/phone_otp_error_messages.dart';
import 'package:hundred_version1/services/phone_otp_service.dart';

void main() {
  test('maps stable OTP application codes without exposing provider text', () {
    const expectedCodes = <String>{
      'invalid-request',
      'invalid-phone-number',
      'phone-already-registered',
      'phone-not-registered',
      'wrong-code',
      'code-expired',
      'too-many-attempts',
      'send-limit-reached',
      'network-error',
      'service-unavailable',
      'account-disabled',
      'age-restricted',
      'account-conflict',
      'registration-incomplete',
    };

    for (final code in expectedCodes) {
      final message = friendlyPhoneOtpErrorMessage(PhoneOtpException(code));
      expect(message, isNotEmpty, reason: code);
      expect(message, isNot(contains(code)), reason: code);
    }
  });

  test('uses the caller fallback for unknown failures', () {
    expect(
      friendlyPhoneOtpErrorMessage(
        const PhoneOtpException('unknown-provider-message'),
        fallback: 'fallback',
      ),
      'fallback',
    );
  });
}
