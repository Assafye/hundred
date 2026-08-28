import 'package:flutter_test/flutter_test.dart';
import 'package:hundred_version1/login_screen.dart';
import 'package:hundred_version1/services/auth_service.dart';

void main() {
  group('LoginScreen login gate', () {
    test('blocks users until onboarding is active, regardless of email flag', () {
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

      expect(
        shouldBlockLoginForState(
          isEmailVerified: false,
          onboardingStep: OnboardingStep.active,
        ),
        isFalse,
      );
    });
  });
}
