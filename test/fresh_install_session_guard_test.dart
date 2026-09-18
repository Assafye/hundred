import 'package:flutter_test/flutter_test.dart';
import 'package:hundred_version1/services/fresh_install_session_guard.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('signs out a restored session on first launch', () async {
    var signOutCount = 0;
    final guard = FreshInstallSessionGuard(
      currentUserId: () => 'persisted-user',
      signOut: () async => signOutCount += 1,
    );

    final didSignOut = await guard.enforce();

    final preferences = await SharedPreferences.getInstance();
    expect(didSignOut, isTrue);
    expect(signOutCount, 1);
    expect(
      preferences.getBool(FreshInstallSessionGuard.installationMarkerKey),
      isTrue,
    );
  });

  test('does not sign out again after the installation is marked', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      FreshInstallSessionGuard.installationMarkerKey: true,
    });
    var signOutCount = 0;
    final guard = FreshInstallSessionGuard(
      currentUserId: () => 'signed-in-user',
      signOut: () async => signOutCount += 1,
    );

    final didSignOut = await guard.enforce();

    expect(didSignOut, isFalse);
    expect(signOutCount, 0);
  });

  test('does not mark installation when sign out fails', () async {
    final guard = FreshInstallSessionGuard(
      currentUserId: () => 'persisted-user',
      signOut: () async => throw StateError('sign out failed'),
    );

    await expectLater(guard.enforce(), throwsStateError);

    final preferences = await SharedPreferences.getInstance();
    expect(
      preferences.containsKey(FreshInstallSessionGuard.installationMarkerKey),
      isFalse,
    );
  });
}