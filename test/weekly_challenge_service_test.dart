import 'package:flutter_test/flutter_test.dart';
import 'package:hundred_version1/app_categories.dart';
import 'package:hundred_version1/services/weekly_challenge_service.dart';

void main() {
  test('daily challenge is stable for the same day', () {
    final first = WeeklyChallengeService.currentChallenge(
      now: DateTime.utc(2026, 9, 11, 8),
    );
    final second = WeeklyChallengeService.currentChallenge(
      now: DateTime.utc(2026, 9, 11, 20),
    );

    expect(second.mainCategory, first.mainCategory);
    expect(second.subCategory, first.subCategory);
  });

  test('daily subcategory changes on adjacent days when alternatives exist',
      () {
    final anchor = DateTime.utc(2024, 1, 1, 12);

    for (var weekIndex = 0; weekIndex < 24; weekIndex++) {
      WeeklyChallenge? previous;
      for (var dayIndex = 0; dayIndex < 7; dayIndex++) {
        final challenge = WeeklyChallengeService.currentChallenge(
          now: anchor.add(Duration(days: weekIndex * 7 + dayIndex)),
        );
        final alternatives = appSubCategories(challenge.mainCategory)
            .map((value) => value.trim())
            .where((value) => value.isNotEmpty)
            .where((value) => value != 'אחר')
            .toList(growable: false);

        if (previous != null && alternatives.length > 1) {
          expect(
            challenge.subCategory,
            isNot(previous.subCategory),
            reason:
                'Daily subcategory repeated in ${challenge.mainCategory} on week $weekIndex day $dayIndex',
          );
        }
        previous = challenge;
      }
    }
  });
}
