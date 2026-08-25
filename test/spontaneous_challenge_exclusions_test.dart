import 'package:flutter_test/flutter_test.dart';
import 'package:hundred_version1/services/spontaneous_challenge_service.dart';

void main() {
  test('random challenge tasks exclude banned health-focused tasks', () {
    final tasks = SpontaneousChallengeService.availableTasks(
      DateTime.utc(2026, 8, 25),
    );

    final banned = <String>{
      'אתגרים::לשתות שבוע רק מים',
      'אתגרים::לאכול צמחוני שבוע',
      'אתגרים::בלי מטוגן שבוע',
      'אתגרים::לא לאכול שוקולד שבוע',
      'אתגרים::שבוע בלי רשתות חברתיות',
    };

    for (final task in tasks) {
      final key = '${task.category}::${task.subCategory}';
      expect(
        banned.contains(key),
        isFalse,
        reason: 'Banned task should never be randomised: $key',
      );
    }
  });
}
