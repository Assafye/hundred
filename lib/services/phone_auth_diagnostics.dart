import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const _sensitiveKeys = <String>{
  'appcredential',
  'credential',
  'phone',
  'phonenumber',
  'receipt',
  'secret',
  'token',
};

String _sanitizeDiagnosticText(String value) => value
    .replaceAll(RegExp(r'\+?\d{8,15}'), '<redacted-phone>')
    .replaceAll(RegExp(r'[A-Za-z0-9_\-./+=]{40,}'), '<redacted-secret>');

Object? _sanitizeDiagnosticValue(Object? value, {String? key}) {
  final normalizedKey = key?.replaceAll(RegExp(r'[^a-zA-Z]'), '').toLowerCase();
  if (normalizedKey != null && _sensitiveKeys.any(normalizedKey.contains)) {
    return '<redacted>';
  }
  if (value is Map) {
    return <String, Object?>{
      for (final entry in value.entries)
        entry.key.toString(): _sanitizeDiagnosticValue(
          entry.value,
          key: entry.key.toString(),
        ),
    };
  }
  if (value is Iterable) {
    return value
        .map((item) => _sanitizeDiagnosticValue(item))
        .toList(growable: false);
  }
  if (value is String) {
    return _sanitizeDiagnosticText(value);
  }
  return value;
}

String phoneAuthExceptionDiagnostics(Object error) {
  if (error is PlatformException) {
    return 'type=PlatformException | code=${error.code} | '
        'message=${_sanitizeDiagnosticText(error.message ?? '')} | '
        'details=${_sanitizeDiagnosticValue(error.details)}';
  }
  if (error is FirebaseAuthException) {
    return 'type=FirebaseAuthException | code=${error.code} | '
        'message=${_sanitizeDiagnosticText(error.message ?? '')}';
  }
  return 'type=${error.runtimeType} | '
      'error=${_sanitizeDiagnosticText(error.toString())}';
}

void debugPrintPhoneAuthException(Object error) {
  debugPrint('Auth Error Details: ${phoneAuthExceptionDiagnostics(error)}');
}
