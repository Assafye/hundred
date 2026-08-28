import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

class CameraPermissionService {
  static const _cameraDeniedKey = 'camera_permission_was_denied';

  static Future<bool> ensureCameraAccess(BuildContext context) async {
    final preferences = await SharedPreferences.getInstance();
    var status = await Permission.camera.status;
    if (status.isGranted) {
      await preferences.remove(_cameraDeniedKey);
      return true;
    }

    final wasDeniedBefore = preferences.getBool(_cameraDeniedKey) ?? false;
    if (!wasDeniedBefore) {
      status = await Permission.camera.request();
      if (status.isGranted) {
        return true;
      }
      await preferences.setBool(_cameraDeniedKey, true);
      return false;
    }

    if (!context.mounted) return false;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('נדרשת גישה למצלמה'),
        content: const Text(
          'כדי לצלם תמונה או סרטון, אפשר לאפשר גישה למצלמה בהגדרות המכשיר.',
          textAlign: TextAlign.right,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('ביטול'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.of(dialogContext).pop();
              await openAppSettings();
            },
            child: const Text('פתיחת הגדרות'),
          ),
        ],
      ),
    );
    return false;
  }
}