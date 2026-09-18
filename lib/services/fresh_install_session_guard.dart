import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

typedef CurrentUserIdReader = String? Function();
typedef SessionSignOut = Future<void> Function();

class FreshInstallSessionGuard {
  FreshInstallSessionGuard({
    Future<SharedPreferences> Function()? preferences,
    CurrentUserIdReader? currentUserId,
    SessionSignOut? signOut,
  })  : _preferences = preferences ?? SharedPreferences.getInstance,
        _currentUserId = currentUserId ??
            (() => FirebaseAuth.instance.currentUser?.uid),
        _signOut = signOut ?? (() => FirebaseAuth.instance.signOut());

  static const String installationMarkerKey =
      'fresh_install_session_guard_initialized';

  final Future<SharedPreferences> Function() _preferences;
  final CurrentUserIdReader _currentUserId;
  final SessionSignOut _signOut;

  Future<bool> enforce() async {
    final preferences = await _preferences();
    if (preferences.getBool(installationMarkerKey) == true) {
      return false;
    }

    final hadRestoredSession = (_currentUserId() ?? '').trim().isNotEmpty;
    if (hadRestoredSession) {
      await _signOut();
    }

    final didPersistMarker =
        await preferences.setBool(installationMarkerKey, true);
    if (!didPersistMarker) {
      throw StateError('Could not persist the installation session marker.');
    }
    return hadRestoredSession;
  }
}