import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

typedef PhoneVerificationFailed = void Function(
  Object error,
  StackTrace? stackTrace,
);

class PhoneAuthVerificationService {
  PhoneAuthVerificationService._();

  static const MethodChannel _channel =
      MethodChannel('com.hundred.hundred/phone_auth_diagnostics');
  static int _attemptSequence = 0;

  static String createAttemptId() {
    _attemptSequence++;
    return '${DateTime.now().microsecondsSinceEpoch}-$_attemptSequence';
  }

  static Future<void> verifyPhoneNumber({
    required String phoneNumber,
    required String attemptId,
    int? forceResendingToken,
    required PhoneVerificationCompleted verificationCompleted,
    required PhoneVerificationFailed verificationFailed,
    required PhoneCodeSent codeSent,
    required PhoneCodeAutoRetrievalTimeout codeAutoRetrievalTimeout,
  }) async {
    if (!kIsWeb && Platform.isIOS) {
      try {
        final response = await _channel.invokeMapMethod<String, dynamic>(
          'verifyPhoneNumber',
          <String, Object?>{
            'phoneNumber': phoneNumber,
            'attemptId': attemptId,
          },
        );
        final verificationId = response?['verificationId'] as String?;
        if (verificationId == null || verificationId.isEmpty) {
          throw PlatformException(
            code: 'missing-verification-id',
            message: 'Native phone verification returned no verification ID.',
          );
        }
        codeSent(verificationId, null);
      } on PlatformException catch (error, stackTrace) {
        verificationFailed(error, stackTrace);
      } catch (error, stackTrace) {
        verificationFailed(error, stackTrace);
      }
      return;
    }

    await FirebaseAuth.instance.verifyPhoneNumber(
      phoneNumber: phoneNumber,
      forceResendingToken: forceResendingToken,
      verificationCompleted: verificationCompleted,
      verificationFailed: (error) => verificationFailed(
        error,
        error.stackTrace,
      ),
      codeSent: codeSent,
      codeAutoRetrievalTimeout: codeAutoRetrievalTimeout,
    );
  }
}
