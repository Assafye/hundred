const int minimumUserAge = 13;
const int maximumAgeRange = 60;

class AgePolicy {
  static const int minimumTagId = 1;
  static const int maximumTagId = 8;
  static const int restrictedUnderageTagId = 999;

  static const Map<int, List<int>> _allowedTagsByUserTag = {
    1: [1, 2, 3],
    2: [1, 2, 3, 4],
    3: [1, 2, 3, 4, 5],
    4: [2, 3, 4, 5, 6],
    5: [3, 4, 5, 6, 7],
    6: [4, 5, 6, 7, 8],
    7: [5, 6, 7, 8],
    8: [6, 7, 8],
  };

  static int ageOnDate(DateTime birthDate, [DateTime? referenceDate]) {
    final reference = referenceDate ?? DateTime.now();
    var age = reference.year - birthDate.year;
    final birthdayHasOccurred = reference.month > birthDate.month ||
        (reference.month == birthDate.month && reference.day >= birthDate.day);
    if (!birthdayHasOccurred) {
      age -= 1;
    }
    return age;
  }

  static int getTagId(int age) {
    if (age <= 13) return 1;
    if (age >= 20) return 8;
    return age - 12;
  }

  static int? tagFromStoredBirthDate(
    String value, [
    DateTime? referenceDate,
  ]) {
    final birthDate = parseStoredBirthDate(value);
    if (birthDate == null) return null;
    final age = ageOnDate(birthDate, referenceDate);
    if (age < minimumUserAge) return null;
    return getTagId(age);
  }

  static int? tagFromUserData(
    Map<String, dynamic> data, [
    DateTime? referenceDate,
  ]) {
    final birthDate = (data['birthDate'] as String? ?? '').trim();
    return tagFromStoredBirthDate(birthDate, referenceDate);
  }

  static bool isValidTag(int? tag) {
    return tag != null && tag >= minimumTagId && tag <= maximumTagId;
  }

  static List<int> getAllowedTagsForUser(int userTag) {
    return _allowedTagsByUserTag[userTag] ?? const <int>[];
  }

  static bool canViewCreatorTag(int userTag, int creatorTag) {
    return getAllowedTagsForUser(userTag).contains(creatorTag);
  }

  static bool canOpenPrivateChatByTags(int userTagA, int userTagB) {
    return canViewCreatorTag(userTagA, userTagB) &&
        canViewCreatorTag(userTagB, userTagA);
  }
}

DateTime latestEligibleBirthDate([DateTime? referenceDate]) {
  final reference = referenceDate ?? DateTime.now();
  final eligibleYear = reference.year - minimumUserAge;
  final lastDayOfMonth = DateTime(eligibleYear, reference.month + 1, 0).day;
  final eligibleDay = reference.day.clamp(1, lastDayOfMonth);
  return DateTime(eligibleYear, reference.month, eligibleDay);
}

bool isAtLeastMinimumAge(DateTime birthDate, [DateTime? referenceDate]) {
  final latestBirthDate = latestEligibleBirthDate(referenceDate);
  final normalizedBirthDate = DateTime(
    birthDate.year,
    birthDate.month,
    birthDate.day,
  );
  return !normalizedBirthDate.isAfter(latestBirthDate);
}

bool isFutureBirthDate(DateTime birthDate, [DateTime? referenceDate]) {
  final reference = referenceDate ?? DateTime.now();
  final today = DateTime(reference.year, reference.month, reference.day);
  final normalizedBirthDate = DateTime(
    birthDate.year,
    birthDate.month,
    birthDate.day,
  );
  return normalizedBirthDate.isAfter(today);
}

bool isValidAgeRange(int minAge, int maxAge) {
  return minAge >= minimumUserAge &&
      maxAge <= maximumAgeRange &&
      minAge <= maxAge;
}

DateTime? parseStoredBirthDate(String value) {
  final trimmed = value.trim();
  final ddMmYyyy = RegExp(r'^(\d{2})/(\d{2})/(\d{4})$').firstMatch(trimmed);
  final yyyyMmDd = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(trimmed);
  final match = ddMmYyyy ?? yyyyMmDd;
  if (match == null) return null;

  final year = int.tryParse(match.group(ddMmYyyy == null ? 1 : 3)!);
  final month = int.tryParse(match.group(2)!);
  final day = int.tryParse(match.group(ddMmYyyy == null ? 3 : 1)!);
  if (year == null || month == null || day == null) return null;

  final parsed = DateTime.tryParse(
    '${year.toString().padLeft(4, '0')}-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}',
  );
  if (parsed == null ||
      parsed.year != year ||
      parsed.month != month ||
      parsed.day != day) {
    return null;
  }
  return parsed;
}
