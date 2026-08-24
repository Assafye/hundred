import 'package:flutter_test/flutter_test.dart';
import 'package:hundred_version1/login_screen.dart';
import 'package:hundred_version1/services/auth_service.dart';

void main() {
  group('LoginScreen login gate', () {
    test('blocks users until email is verified or onboarding is active', () {
      expect(
        shouldBlockLoginForState(
          isEmailVerified: false,
          onboardingStep: OnboardingStep.pendingVerification,
        ),
        isTrue,
      );

      expect(
        shouldBlockLoginForState(
          isEmailVerified: true,
          onboardingStep: OnboardingStep.pendingProfile,
        ),
        isTrue,
      );

      expect(
        shouldBlockLoginForState(
          isEmailVerified: true,
          onboardingStep: OnboardingStep.active,
        ),
        isFalse,
      );
    });
  });
}
