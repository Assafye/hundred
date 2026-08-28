import 'package:flutter_test/flutter_test.dart';
import 'package:hundred_version1/age_restrictions.dart';

void main() {
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
}