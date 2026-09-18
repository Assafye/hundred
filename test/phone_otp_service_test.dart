import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hundred_version1/services/phone_otp_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeUser extends Fake implements User {
  @override
  String get uid => 'verified-uid';
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('request pins provider and persists only non-secret flow metadata',
      () async {
    late Map<String, Object?> request;
    final service = PhoneOtpService(
      callable: (name, data) async {
        expect(name, 'requestPhoneOtp');
        request = data;
        return <String, Object?>{
          'challengeId': 'abcdefghijklmnopqrstuvwx',
          'expiresInSeconds': 300,
          'retryAfterSeconds': 60,
          'channel': 'sms',
        };
      },
      tokenSignIn: (_) async => null,
      clientVersion: () async => '1.0.4+10',
      installationId: () => 'fixed-installation-id',
      now: () => DateTime.utc(2026, 9, 18, 12),
    );

    final challenge = await service.requestPhoneOtp(
      phone: '+972501234567',
      purpose: PhoneOtpPurpose.registration,
    );

    expect(request['provider'], 'micropay');
    expect(request['installationId'], 'fixed-installation-id');
    expect(request['clientVersion'], '1.0.4+10');
    expect(challenge.expiresAt, DateTime.utc(2026, 9, 18, 12, 5));
    final preferences = await SharedPreferences.getInstance();
    final persisted = preferences.getString('phone_otp_flow_registration')!;
    expect(persisted, isNot(contains('+972501234567')));
    expect(persisted, isNot(contains('firebaseCustomToken')));
    expect(jsonDecode(persisted)['provider'], 'micropay');
  });

  test('expired persisted challenge is cleared', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'phone_otp_flow_recovery': jsonEncode(<String, Object?>{
        'provider': 'micropay',
        'purpose': 'recovery',
        'challengeId': 'abcdefghijklmnopqrstuvwx',
        'expiresAt': DateTime.utc(2026, 9, 18, 11).millisecondsSinceEpoch,
        'retryAvailableAt':
            DateTime.utc(2026, 9, 18, 10, 59).millisecondsSinceEpoch,
        'channel': 'sms',
      }),
    });
    final service = PhoneOtpService(
      callable: (_, __) async => null,
      tokenSignIn: (_) async => null,
      clientVersion: () async => '1.0.4+10',
      now: () => DateTime.utc(2026, 9, 18, 12),
    );

    expect(await service.restoreChallenge(PhoneOtpPurpose.recovery), isNull);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.containsKey('phone_otp_flow_recovery'), isFalse);
  });

  test('malformed callable response fails with a stable safe code', () async {
    final service = PhoneOtpService(
      callable: (_, __) async => <String, Object?>{'unexpected': 'secret'},
      tokenSignIn: (_) async => null,
      clientVersion: () async => '1.0.4+10',
      installationId: () => 'fixed-installation-id',
    );

    await expectLater(
      service.requestPhoneOtp(
        phone: '+972501234567',
        purpose: PhoneOtpPurpose.registration,
      ),
      throwsA(
        isA<PhoneOtpException>().having(
          (error) => error.code,
          'code',
          'service-unavailable',
        ),
      ),
    );
  });

  test('verification signs in with the custom token and clears the flow',
      () async {
    const challengeId = 'abcdefghijklmnopqrstuvwx';
    final expiresAt = DateTime.utc(2026, 9, 18, 12, 5);
    final challenge = PhoneOtpChallenge(
      challengeId: challengeId,
      purpose: PhoneOtpPurpose.recovery,
      expiresAt: expiresAt,
      retryAvailableAt: DateTime.utc(2026, 9, 18, 12, 1),
      channel: 'sms',
    );
    SharedPreferences.setMockInitialValues(<String, Object>{
      'phone_otp_installation_id': 'fixed-installation-id',
      'phone_otp_flow_recovery': jsonEncode(challenge.toJson()),
    });
    String? receivedToken;
    final service = PhoneOtpService(
      callable: (name, data) async {
        expect(name, 'verifyPhoneOtp');
        expect(data['provider'], 'micropay');
        expect(data['challengeId'], challengeId);
        return <String, Object?>{
          'firebaseCustomToken': 'custom-token',
          'purpose': 'recovery',
          'isNewUser': false,
        };
      },
      tokenSignIn: (token) async {
        receivedToken = token;
        return _FakeUser();
      },
      clientVersion: () async => '1.0.4+10',
      now: () => DateTime.utc(2026, 9, 18, 12),
    );

    final result = await service.verifyPhoneOtp(
      challenge: challenge,
      code: '123456',
    );
    expect(receivedToken, 'custom-token');
    expect(result.user.uid, 'verified-uid');
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.containsKey('phone_otp_flow_recovery'), isFalse);
  });

  test('purpose mismatch is rejected before custom-token sign-in', () async {
    final challenge = PhoneOtpChallenge(
      challengeId: 'abcdefghijklmnopqrstuvwx',
      purpose: PhoneOtpPurpose.registration,
      expiresAt: DateTime.utc(2026, 9, 18, 12, 5),
      retryAvailableAt: DateTime.utc(2026, 9, 18, 12, 1),
      channel: 'sms',
    );
    SharedPreferences.setMockInitialValues(<String, Object>{
      'phone_otp_installation_id': 'fixed-installation-id',
      'phone_otp_flow_registration': jsonEncode(challenge.toJson()),
    });
    var signInCalled = false;
    final service = PhoneOtpService(
      callable: (_, __) async => <String, Object?>{
        'firebaseCustomToken': 'custom-token',
        'purpose': 'recovery',
        'isNewUser': false,
      },
      tokenSignIn: (_) async {
        signInCalled = true;
        return null;
      },
      clientVersion: () async => '1.0.4+10',
      now: () => DateTime.utc(2026, 9, 18, 12),
    );

    await expectLater(
      service.verifyPhoneOtp(challenge: challenge, code: '123456'),
      throwsA(
        isA<PhoneOtpException>().having(
          (error) => error.code,
          'code',
          'service-unavailable',
        ),
      ),
    );
    expect(signInCalled, isFalse);
  });
}
