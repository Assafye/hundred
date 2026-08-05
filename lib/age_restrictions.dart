const int minimumUserAge = 13;
const int maximumAgeRange = 60;

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
