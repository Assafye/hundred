import 'dart:convert';
import 'dart:math';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum PhoneOtpPurpose {
  registration,
  recovery;

  String get wireValue => name;

  static PhoneOtpPurpose parse(Object? value) {
    return PhoneOtpPurpose.values.firstWhere(
      (purpose) => purpose.wireValue == value,
      orElse: () => throw const PhoneOtpException('service-unavailable'),
    );
  }
}

class PhoneOtpChallenge {
  const PhoneOtpChallenge({
    required this.challengeId,
    required this.purpose,
    required this.expiresAt,
    required this.retryAvailableAt,
    required this.channel,
  });

  static const provider = 'micropay';

  final String challengeId;
  final PhoneOtpPurpose purpose;
  final DateTime expiresAt;
  final DateTime retryAvailableAt;
  final String channel;

  bool isExpired(DateTime now) => !expiresAt.isAfter(now);

  Map<String, Object?> toJson() => <String, Object?>{
        'provider': provider,
        'purpose': purpose.wireValue,
        'challengeId': challengeId,
        'expiresAt': expiresAt.millisecondsSinceEpoch,
        'retryAvailableAt': retryAvailableAt.millisecondsSinceEpoch,
        'channel': channel,
      };

  static PhoneOtpChallenge fromJson(Map<String, Object?> json) {
    if (json['provider'] != provider) {
      throw const PhoneOtpException('service-unavailable');
    }
    final challengeId = json['challengeId'];
    final expiresAt = json['expiresAt'];
    final retryAvailableAt = json['retryAvailableAt'];
    final channel = json['channel'];
    if (challengeId is! String ||
        challengeId.isEmpty ||
        expiresAt is! int ||
        retryAvailableAt is! int ||
        channel is! String ||
        channel.isEmpty) {
      throw const PhoneOtpException('service-unavailable');
    }
    return PhoneOtpChallenge(
      challengeId: challengeId,
      purpose: PhoneOtpPurpose.parse(json['purpose']),
      expiresAt: DateTime.fromMillisecondsSinceEpoch(expiresAt),
      retryAvailableAt: DateTime.fromMillisecondsSinceEpoch(retryAvailableAt),
      channel: channel,
    );
  }
}

class PhoneOtpVerificationResult {
  const PhoneOtpVerificationResult({
    required this.purpose,
    required this.user,
    required this.isNewUser,
  });

  final PhoneOtpPurpose purpose;
  final User user;
  final bool isNewUser;
}

class PhoneOtpException implements Exception {
  const PhoneOtpException(this.code);

  final String code;

  @override
  String toString() => 'PhoneOtpException($code)';
}

typedef PhoneOtpCallable = Future<Object?> Function(
  String name,
  Map<String, Object?> data,
);
typedef PhoneOtpTokenSignIn = Future<User?> Function(String customToken);

class PhoneOtpService {
  PhoneOtpService({
    FirebaseFunctions? functions,
    FirebaseAuth? auth,
    PhoneOtpCallable? callable,
    PhoneOtpTokenSignIn? tokenSignIn,
    Future<SharedPreferences> Function()? preferences,
    Future<String> Function()? clientVersion,
    DateTime Function()? now,
    String Function()? installationId,
  })  : _preferences = preferences ?? SharedPreferences.getInstance,
        _clientVersion = clientVersion ?? _loadClientVersion,
        _now = now ?? DateTime.now,
        _installationId = installationId ?? _createInstallationId {
    if (callable != null) {
      _callable = callable;
    } else {
      final effectiveFunctions =
          functions ?? FirebaseFunctions.instanceFor(region: 'europe-west3');
      _callable = (name, data) async {
        final result = await effectiveFunctions.httpsCallable(name).call(data);
        return result.data;
      };
    }
    if (tokenSignIn != null) {
      _tokenSignIn = tokenSignIn;
    } else {
      final effectiveAuth = auth ?? FirebaseAuth.instance;
      _tokenSignIn = (customToken) async =>
          (await effectiveAuth.signInWithCustomToken(customToken)).user;
    }
  }

  static const _installationIdKey = 'phone_otp_installation_id';
  static const _flowKeyPrefix = 'phone_otp_flow_';
  static const _provider = PhoneOtpChallenge.provider;

  late final PhoneOtpCallable _callable;
  late final PhoneOtpTokenSignIn _tokenSignIn;
  final Future<SharedPreferences> Function() _preferences;
  final Future<String> Function() _clientVersion;
  final DateTime Function() _now;
  final String Function() _installationId;

  Future<PhoneOtpChallenge> requestPhoneOtp({
    required String phone,
    required PhoneOtpPurpose purpose,
  }) async {
    try {
      final response = _responseMap(await _callable(
        'requestPhoneOtp',
        <String, Object?>{
          'phone': phone,
          'purpose': purpose.wireValue,
          'provider': _provider,
          'installationId': await _getInstallationId(),
          'clientVersion': await _clientVersion(),
        },
      ));
      final challengeId = _requiredString(response, 'challengeId');
      final expiresInSeconds = _requiredPositiveInt(
        response,
        'expiresInSeconds',
      );
      final retryAfterSeconds = _requiredPositiveInt(
        response,
        'retryAfterSeconds',
        allowZero: true,
      );
      final requestedAt = _now();
      final challenge = PhoneOtpChallenge(
        challengeId: challengeId,
        purpose: purpose,
        expiresAt: requestedAt.add(Duration(seconds: expiresInSeconds)),
        retryAvailableAt: requestedAt.add(Duration(seconds: retryAfterSeconds)),
        channel: _requiredString(response, 'channel'),
      );
      await _persistChallenge(challenge);
      return challenge;
    } catch (error) {
      throw _safeException(error);
    }
  }

  Future<PhoneOtpVerificationResult> verifyPhoneOtp({
    required PhoneOtpChallenge challenge,
    required String code,
  }) async {
    try {
      final stored = await restoreChallenge(challenge.purpose);
      if (challenge.isExpired(_now()) ||
          stored == null ||
          stored.challengeId != challenge.challengeId) {
        throw const PhoneOtpException('code-expired');
      }
      final response = _responseMap(await _callable(
        'verifyPhoneOtp',
        <String, Object?>{
          'challengeId': challenge.challengeId,
          'code': code,
          'provider': _provider,
          'installationId': await _getInstallationId(),
          'clientVersion': await _clientVersion(),
        },
      ));
      final purpose = PhoneOtpPurpose.parse(response['purpose']);
      if (purpose != challenge.purpose) {
        throw const PhoneOtpException('service-unavailable');
      }
      final user = await _tokenSignIn(
        _requiredString(response, 'firebaseCustomToken'),
      );
      if (user == null) {
        throw const PhoneOtpException('service-unavailable');
      }
      await clearChallenge(challenge.purpose);
      return PhoneOtpVerificationResult(
        purpose: purpose,
        user: user,
        isNewUser: response['isNewUser'] == true,
      );
    } catch (error) {
      throw _safeException(error);
    }
  }

  Future<PhoneOtpChallenge?> restoreChallenge(
    PhoneOtpPurpose purpose,
  ) async {
    final preferences = await _preferences();
    final encoded = preferences.getString(_flowKey(purpose));
    if (encoded == null) return null;
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! Map) throw const FormatException();
      final challenge = PhoneOtpChallenge.fromJson(
        decoded.map((key, value) => MapEntry(key.toString(), value)),
      );
      if (challenge.purpose != purpose || challenge.isExpired(_now())) {
        await clearChallenge(purpose);
        return null;
      }
      return challenge;
    } catch (_) {
      await clearChallenge(purpose);
      return null;
    }
  }

  Future<void> clearChallenge(PhoneOtpPurpose purpose) async {
    final preferences = await _preferences();
    await preferences.remove(_flowKey(purpose));
  }

  Future<void> _persistChallenge(PhoneOtpChallenge challenge) async {
    final preferences = await _preferences();
    await preferences.setString(
      _flowKey(challenge.purpose),
      jsonEncode(challenge.toJson()),
    );
  }

  Future<String> _getInstallationId() async {
    final preferences = await _preferences();
    final existing = preferences.getString(_installationIdKey);
    if (existing != null && existing.length >= 16) return existing;
    final created = _installationId();
    await preferences.setString(_installationIdKey, created);
    return created;
  }

  static Future<String> _loadClientVersion() async {
    final package = await PackageInfo.fromPlatform();
    return '${package.version}+${package.buildNumber}';
  }

  static String _createInstallationId() {
    final random = Random.secure();
    final bytes = List<int>.generate(24, (_) => random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  static String _flowKey(PhoneOtpPurpose purpose) =>
      '$_flowKeyPrefix${purpose.wireValue}';

  static Map<String, Object?> _responseMap(Object? value) {
    if (value is! Map) {
      throw const PhoneOtpException('service-unavailable');
    }
    return value.map((key, item) => MapEntry(key.toString(), item));
  }

  static String _requiredString(Map<String, Object?> data, String key) {
    final value = data[key];
    if (value is! String || value.trim().isEmpty) {
      throw const PhoneOtpException('service-unavailable');
    }
    return value.trim();
  }

  static int _requiredPositiveInt(
    Map<String, Object?> data,
    String key, {
    bool allowZero = false,
  }) {
    final value = data[key];
    if (value is! num ||
        value % 1 != 0 ||
        (allowZero ? value < 0 : value <= 0)) {
      throw const PhoneOtpException('service-unavailable');
    }
    return value.toInt();
  }

  static PhoneOtpException _safeException(Object error) {
    if (error is PhoneOtpException) return error;
    if (error is FirebaseFunctionsException) {
      final details = error.details;
      if (details is Map) {
        final applicationCode = details['code'];
        if (applicationCode is String &&
            _publicCodes.contains(applicationCode)) {
          return PhoneOtpException(applicationCode);
        }
      }
      return PhoneOtpException(
          _transportCodes[error.code] ?? 'service-unavailable');
    }
    if (error is FirebaseAuthException) {
      return PhoneOtpException(
        error.code == 'network-request-failed'
            ? 'network-error'
            : error.code == 'user-disabled'
                ? 'account-disabled'
                : 'service-unavailable',
      );
    }
    return const PhoneOtpException('service-unavailable');
  }

  static const _publicCodes = <String>{
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

  static const _transportCodes = <String, String>{
    'deadline-exceeded': 'network-error',
    'unavailable': 'network-error',
    'resource-exhausted': 'send-limit-reached',
  };
}
