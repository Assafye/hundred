import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Bridges to native iOS code (AppDelegate.swift) to check whether the APNs
/// device token has been registered yet, which Firebase Phone Auth needs for
/// silent-push verification before falling back to reCAPTCHA.
class ApnsTokenStatusService {
  ApnsTokenStatusService._();

  static const MethodChannel _channel =
      MethodChannel('com.hundred.hundred/apns_status');

  /// Non-iOS platforms have no equivalent concept, so treat them as ready.
  static bool get _isApplicable => !kIsWeb && Platform.isIOS;

  static Future<bool> isReady() async {
    if (!_isApplicable) return true;
    try {
      final ready = await _channel.invokeMethod<bool>('isApnsTokenReady');
      return ready ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Waits up to [timeout] for the APNs token to arrive. Returns true
  /// immediately if it is already available, and resolves to false if the
  /// timeout elapses first (callers should proceed regardless either way —
  /// this is only used for diagnostics/best-effort readiness, never to block
  /// the user indefinitely).
  static Future<bool> waitForToken({
    Duration timeout = const Duration(milliseconds: 2500),
  }) async {
    if (!_isApplicable) return true;
    try {
      final ready = await _channel.invokeMethod<bool>(
        'waitForApnsToken',
        <String, dynamic>{'timeoutMs': timeout.inMilliseconds},
      );
      return ready ?? false;
    } catch (_) {
      return false;
    }
  }
}
