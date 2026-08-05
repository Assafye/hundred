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
        .toList(growable: false);

    if (subCategories.isEmpty) {
      return 'אחר';
    }

    final weekStart = DateTime.utc(2024, 1, 1).add(Duration(days: weekIndex * 7));
    final daysIntoWeek = nowUtc.difference(weekStart).inDays.clamp(0, 6);
    final twoDaySlot = daysIntoWeek ~/ 2;
    final random = Random((weekIndex + 1) * 3571 + (twoDaySlot + 1) * 101);
    return subCategories[random.nextInt(subCategories.length)];
  }

  static List<String> _eligibleMainCategories() {
    final categories = appMainCategories
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .where((value) => !isGeneralCategory(value))
        .where((value) => appSubCategories(value).isNotEmpty)
        .toList(growable: false);

    if (categories.isNotEmpty) {
      return categories;
    }

    return appMainCategories
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
  }
}
