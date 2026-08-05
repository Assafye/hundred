import 'package:flutter/foundation.dart';

import 'share_flow_log_storage_stub.dart'
  if (dart.library.io) 'share_flow_log_storage_io.dart' as share_log_storage;

class ShareFlowLogService {
  static bool _isGlobalHandlersInstalled = false;
  static Future<void> _writeQueue = Future<void>.value();

  static String _sanitize(Object? value) {
    return value?.toString().replaceAll('\n', ' | ') ?? 'null';
  }

  static String _formatData(Map<String, Object?> data) {
    if (data.isEmpty) {
      return '';
    }
    final pairs = data.entries
        .map((entry) => '${entry.key}=${_sanitize(entry.value)}')
        .join(', ');
    return ' | $pairs';
  }

  static Future<void> log(
    String event, {
    Map<String, Object?> data = const <String, Object?>{},
  }) async {
    final timestamp = DateTime.now().toIso8601String();
    final line = '[$timestamp] $event${_formatData(data)}';

    debugPrint(line);

    _writeQueue = _writeQueue.then((_) async {
      try {
        await share_log_storage.appendLine(line);
      } catch (error) {
        debugPrint('[ShareFlowLogService] write failed: $error');
      }
    });

    await _writeQueue;
  }

  static Future<String> logPath() async {
    return share_log_storage.logPath();
  }

  static Future<void> installGlobalHandlers() async {
    if (_isGlobalHandlersInstalled) {
      return;
    }
    _isGlobalHandlersInstalled = true;

    final previousFlutterOnError = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      log(
        'FLUTTER_ERROR',
        data: <String, Object?>{
          'exception': details.exceptionAsString(),
          'library': details.library,
          'context': details.context,
          'silent': details.silent,
          'stack': details.stack,
        },
      );
      if (previousFlutterOnError != null) {
        previousFlutterOnError(details);
      } else {
        FlutterError.presentError(details);
      }
    };

    final previousPlatformOnError = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
      log(
        'PLATFORM_ERROR',
        data: <String, Object?>{
          'error': error,
          'stack': stack,
        },
      );
      if (previousPlatformOnError != null) {
        return previousPlatformOnError(error, stack);
      }
      return false;
    };

    await log(
      'LOGGING_INITIALIZED',
      data: <String, Object?>{
        'file': await logPath(),
      },
    );
  }
}
