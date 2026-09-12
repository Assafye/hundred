import 'package:flutter_test/flutter_test.dart';
import 'package:hundred_version1/age_restrictions.dart';

void main() {
  group('AgePolicy', () {
    test('maps ages to the eight tag ids', () {
      expect(
        [13, 14, 15, 16, 17, 18, 19, 20, 42].map(AgePolicy.getTagId).toList(),
        [1, 2, 3, 4, 5, 6, 7, 8, 8],
      );
    });

    test('uses the configured visibility matrix', () {
      expect(AgePolicy.getAllowedTagsForUser(1), [1, 2, 3]);
      expect(AgePolicy.getAllowedTagsForUser(4), [2, 3, 4, 5, 6]);
      expect(AgePolicy.getAllowedTagsForUser(8), [6, 7, 8]);
      expect(AgePolicy.getAllowedTagsForUser(99), isEmpty);
      expect(AgePolicy.isValidTag(AgePolicy.restrictedUnderageTagId), isFalse);
      expect(
        AgePolicy.getAllowedTagsForUser(AgePolicy.restrictedUnderageTagId),
        isEmpty,
      );
    });

    test('recomputes a tag when the birthday arrives', () {
      expect(
        AgePolicy.tagFromStoredBirthDate(
          '13/09/2010',
          DateTime(2026, 9, 12),
        ),
        3,
      );
      expect(
        AgePolicy.tagFromStoredBirthDate(
          '13/09/2010',
          DateTime(2026, 9, 13),
        ),
        4,
      );
    });

    test('requires symmetric compatibility for private chat', () {
      expect(AgePolicy.canOpenPrivateChatByTags(1, 3), isTrue);
      expect(AgePolicy.canOpenPrivateChatByTags(2, 4), isTrue);
      expect(AgePolicy.canOpenPrivateChatByTags(1, 4), isFalse);
      expect(AgePolicy.canOpenPrivateChatByTags(5, 8), isFalse);
    });

    test('rejects missing, malformed, and underage birth dates', () {
      expect(AgePolicy.tagFromStoredBirthDate(''), isNull);
      expect(AgePolicy.tagFromStoredBirthDate('not-a-date'), isNull);
      expect(
        AgePolicy.tagFromStoredBirthDate(
          '13/09/2014',
          DateTime(2026, 9, 12),
        ),
        isNull,
      );
    });
  });

  group('isAtLeastMinimumAge', () {
    test('accepts a user who turns 13 on the reference date', () {
      expect(
        isAtLeastMinimumAge(
          DateTime(2013, 8, 27),
          DateTime(2026, 8, 27),
        ),
        isTrue,
      );
    });

    test('identifies a user younger than 13 as age restricted', () {
      expect(
        isAtLeastMinimumAge(
          DateTime(2013, 8, 28),
          DateTime(2026, 8, 27),
        ),
        isFalse,
      );
    });
  });

  group('isFutureBirthDate', () {
    test('allows today and rejects tomorrow', () {
      final today = DateTime(2026, 9, 12, 18, 30);

      expect(isFutureBirthDate(DateTime(2026, 9, 12), today), isFalse);
      expect(isFutureBirthDate(DateTime(2026, 9, 13), today), isTrue);
    });
  });
}
