import 'dart:math';

import '../app_categories.dart';

class WeeklyChallenge {
  final String mainCategory;
  final String subCategory;

  const WeeklyChallenge({
    required this.mainCategory,
    required this.subCategory,
  });
}

class WeeklyChallengeService {
  WeeklyChallengeService._();

  static final Map<int, String> _weeklyCategoryCache = <int, String>{};

  static WeeklyChallenge currentChallenge({DateTime? now}) {
    final current = (now ?? DateTime.now()).toUtc();
    final weekIndex = _weekIndexFor(current);
    final mainCategory = _categoryForWeek(weekIndex);
    final subCategory = _subCategoryForWeek(
      weekIndex: weekIndex,
      mainCategory: mainCategory,
      nowUtc: current,
    );

    return WeeklyChallenge(
      mainCategory: mainCategory,
      subCategory: subCategory,
    );
  }

  static int publishMultiplier({
    required String category,
    required String subCategory,
    DateTime? now,
  }) {
    final normalizedCategory = category.trim();
    final normalizedSubCategory = subCategory.trim();
    final challenge = currentChallenge(now: now);

    if (normalizedCategory != challenge.mainCategory) {
      return 1;
    }
    if (normalizedSubCategory.isNotEmpty &&
        normalizedSubCategory == challenge.subCategory) {
      return 3;
    }
    return 2;
  }

  static int _weekIndexFor(DateTime utcDate) {
    final anchor = DateTime.utc(2024, 1, 1);
    return utcDate.difference(anchor).inDays ~/ 7;
  }

  static String _categoryForWeek(int weekIndex) {
    if (_weeklyCategoryCache.containsKey(weekIndex)) {
      return _weeklyCategoryCache[weekIndex]!;
    }

    final categories = _eligibleMainCategories();
    if (categories.isEmpty) {
      return kGeneralCategory;
    }

    for (int i = 0; i <= weekIndex; i++) {
      if (_weeklyCategoryCache.containsKey(i)) {
        continue;
      }

      final previous1 = i > 0 ? _weeklyCategoryCache[i - 1] : null;
      final previous2 = i > 1 ? _weeklyCategoryCache[i - 2] : null;

      final filtered = categories
          .where((category) => category != previous1 && category != previous2)
          .toList(growable: false);
      final pool = filtered.isNotEmpty ? filtered : categories;

      final random = Random((i + 1) * 7919 + 17);
      _weeklyCategoryCache[i] = pool[random.nextInt(pool.length)];
    }

    return _weeklyCategoryCache[weekIndex] ?? categories.first;
  }

  static String _subCategoryForWeek({
    required int weekIndex,
    required String mainCategory,
    required DateTime nowUtc,
  }) {
    final subCategories = appSubCategories(mainCategory)
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .where((value) => value != 'אחר')
        .toList(growable: false);

    if (subCategories.isEmpty) {
      return 'אחר';
    }

    final weekStart =
        DateTime.utc(2024, 1, 1).add(Duration(days: weekIndex * 7));
    final daysIntoWeek = nowUtc.difference(weekStart).inDays.clamp(0, 6);
    final shuffled = subCategories.toList(growable: false);
    final seeded =
        Random((weekIndex + 1) * 3571 + _stableTextSeed(mainCategory));
    for (int i = shuffled.length - 1; i > 0; i--) {
      final j = seeded.nextInt(i + 1);
      final temp = shuffled[i];
      shuffled[i] = shuffled[j];
      shuffled[j] = temp;
    }
    return shuffled[daysIntoWeek % shuffled.length];
  }

  static int _stableTextSeed(String value) {
    var hash = 0;
    for (final codeUnit in value.codeUnits) {
      hash = 0x1fffffff & ((hash * 31) + codeUnit);
    }
    return hash;
  }

  static List<String> _eligibleMainCategories() {
    final categories = appMainCategories
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .where((value) => !isGeneralCategory(value))
        .where((value) => value != 'אחר')
        .where((value) => appSubCategories(value)
            .map((subCategory) => subCategory.trim())
            .where((subCategory) => subCategory.isNotEmpty)
            .where((subCategory) => subCategory != 'אחר')
            .isNotEmpty)
        .toList(growable: false);

    if (categories.isNotEmpty) {
      return categories;
    }

    return appMainCategories
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .where((value) => !isGeneralCategory(value))
        .where((value) => value != 'אחר')
        .toList(growable: false);
  }
}
