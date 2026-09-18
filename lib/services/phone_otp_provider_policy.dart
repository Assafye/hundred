import 'phone_otp_service.dart';

enum PhoneOtpProvider { firebase, micropay }

class PhoneOtpProviderPolicy {
  const PhoneOtpProviderPolicy({
    this.microPayEnabled = const bool.fromEnvironment(
      'ENABLE_MICROPAY_PHONE_OTP',
      defaultValue: true,
    ),
  });

  final bool microPayEnabled;

  PhoneOtpProvider select({PhoneOtpChallenge? restoredChallenge}) {
    if (restoredChallenge != null) return PhoneOtpProvider.micropay;
    return microPayEnabled
        ? PhoneOtpProvider.micropay
        : PhoneOtpProvider.firebase;
  }
}
