import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../app_categories.dart';

class SpontaneousChallengeTask {
  final String category;
  final String subCategory;
  final DateTime assignedAtUtc;
  final DateTime expiresAtUtc;

  const SpontaneousChallengeTask({
    required this.category,
    required this.subCategory,
    required this.assignedAtUtc,
    required this.expiresAtUtc,
  });

  Duration get totalDuration => expiresAtUtc.difference(assignedAtUtc);

  Duration remainingAt(DateTime nowUtc) {
    final remaining = expiresAtUtc.difference(nowUtc.toUtc());
    if (remaining.isNegative) {
      return Duration.zero;
    }
    return remaining;
  }

  bool isExpiredAt(DateTime nowUtc) {
    return !nowUtc.toUtc().isBefore(expiresAtUtc);
  }

  bool matchesPost({required String category, required String subCategory}) {
    final normalizedCategory = category.trim();
    final normalizedSubCategory = subCategory.trim();
    return normalizedCategory == this.category &&
        normalizedSubCategory == this.subCategory;
  }

  int rewardMultiplierAt(DateTime nowUtc) {
    if (isExpiredAt(nowUtc)) {
      return 0;
    }

    final duration = totalDuration;
    if (duration.inSeconds <= 0) {
      return 5;
    }

    final elapsed = nowUtc.toUtc().difference(assignedAtUtc);
    final halfwayPoint = duration.inMilliseconds ~/ 2;
    return elapsed.inMilliseconds <= halfwayPoint ? 10 : 5;
  }

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'category': category,
      'subCategory': subCategory,
      'assignedAt': Timestamp.fromDate(assignedAtUtc),
      'expiresAt': Timestamp.fromDate(expiresAtUtc),
    };
  }

  static SpontaneousChallengeTask? fromMap(
    Map<String, dynamic>? data, {
    DateTime? now,
  }) {
    if (data == null || data.isEmpty) {
      return null;
    }

    final category = (data['category'] as String? ?? '').trim();
    final subCategory = (data['subCategory'] as String? ?? '').trim();
    if (category.isEmpty || subCategory.isEmpty) {
      return null;
    }

    final assignedAt = _dateTimeFrom(data['assignedAt']);
    final expiresAt = _dateTimeFrom(data['expiresAt']);
    if (assignedAt == null || expiresAt == null) {
      return null;
    }

    final task = SpontaneousChallengeTask(
      category: category,
      subCategory: subCategory,
      assignedAtUtc: assignedAt.toUtc(),
      expiresAtUtc: expiresAt.toUtc(),
    );

    if (task.isExpiredAt(now ?? DateTime.now())) {
      return null;
    }

    return task;
  }

  static DateTime? _dateTimeFrom(dynamic raw) {
    if (raw is Timestamp) {
      return raw.toDate();
    }
    if (raw is DateTime) {
      return raw;
    }
    if (raw is String) {
      return DateTime.tryParse(raw);
    }
    return null;
  }
}

class SpontaneousBoostResolution {
  final int spontaneousMultiplier;
  final SpontaneousChallengeTask? task;
  final bool matched;

  const SpontaneousBoostResolution({
    required this.spontaneousMultiplier,
    required this.task,
    required this.matched,
  });
}

class SpontaneousChallengeService {
  SpontaneousChallengeService._();

  static const String _fieldKey = 'weeklySpontaneousChallenge';

  static final Set<String> _bannedTaskKeys = <String>{
    _taskKey('אתגרים', 'לשתות שבוע רק מים'),
    _taskKey('אתגרים', 'לאכול צמחוני שבוע'),
    _taskKey('אתגרים', 'בלי מטוגן שבוע'),
    _taskKey('אתגרים', 'לא לאכול שוקולד שבוע'),
    _taskKey('אתגרים', 'שבוע בלי רשתות חברתיות'),
  };

  static final Set<String> _sevenDayTaskKeys = <String>{
    _taskKey('אקסטרים', 'בנג\'י'),
    _taskKey('אקסטרים', 'צניחה חופשית'),
    _taskKey('אקסטרים', 'לצלול עם חיות'),
    _taskKey('טיולים וחופשות', 'לרדת לאילת'),
    _taskKey('טיולים וחופשות', 'לטוס לחוץ'),
    _taskKey('טיולים וחופשות', 'לנסוע לחרמון'),
    _taskKey('טיולים וחופשות', 'לעשות חלק משביל ישראל'),
    _taskKey('טיולים וחופשות', 'להיות בפלא תבל'),
    _taskKey('טיולים וחופשות', 'לנסוע לים המלח'),
    _taskKey('משפחה', 'לבשל ארוחת שישי לכל המשפחה'),
    _taskKey('משפחה', 'לצאת לטיול משפחתי'),
    _taskKey('חברים', 'לארגן לחבר יום הולדת'),
    _taskKey('חברים', 'להרכיב פאזל עם מעל 1000 חלקים'),
    _taskKey('אוכל', 'לגדל ירק/פרי'),
    _taskKey('אתגרים', 'להשתתף במרתון (לא חייב שלם)'),
    _taskKey('אתגרים', 'יום בלי טלפון'),
    _taskKey('אתגרים', 'להתגבר על פחד'),
    _taskKey('מעשים טובים', 'לעזור לבן אדם אקראי ברחוב'),
    _taskKey('מעשים טובים', 'ללכת להתנדב'),
    _taskKey('מעשים טובים', 'לתרום משהו מוחשי'),
    _taskKey('בשביל עצמי', 'לקרוא ספר שלם'),
    _taskKey('בשביל עצמי', 'להגשים חלום'),
    _taskKey('ספורט', 'לרוץ'),
    _taskKey('ספורט', 'ללכת לחדכ'),
    _taskKey('ספורט', 'לרכב על אופניים'),
    _taskKey('ספורט', 'לעשות יוגה'),
    _taskKey('ספורט', 'לשחק פאדל'),
    _taskKey('ספורט', 'לגלוש'),
    _taskKey('דברים חדשים', 'לעצב מחדש את החדר'),
    _taskKey('דברים חדשים', 'לנסות תחביב חדש'),
    _taskKey('דברים חדשים', 'לנסות תספורת חדשה'),
    _taskKey('דברים חדשים', 'להכיר חברים חדשים'),
    _taskKey('דברים חדשים', 'לעשות קעקוע (לא חייב אמיתי)'),
    _taskKey('דברים חדשים', 'ללמוד לנגן משהו על כלי נגינה'),
    _taskKey('דברים חדשים', 'להרוויח כסף לא מהעבודה הקבועה'),
    _taskKey('דברים חדשים', 'לנסות סטייל חדש'),
    _taskKey('דברים חדשים', 'לפגוש מפורסם'),
  };

  static SpontaneousChallengeTask pickRandomTask({DateTime? now}) {
    final current = (now ?? DateTime.now()).toUtc();
    final options = _availableTasks(current);
    if (options.isEmpty) {
      final fallbackCategory = appMainCategories
          .where((category) => !isGeneralCategory(category))
          .first;
      return SpontaneousChallengeTask(
        category: fallbackCategory,
        subCategory: appSubCategories(fallbackCategory).first,
        assignedAtUtc: current,
        expiresAtUtc: current.add(const Duration(hours: 48)),
      );
    }

    final random = Random(current.millisecondsSinceEpoch ^ options.length);
    return options[random.nextInt(options.length)];
  }

  static Future<SpontaneousChallengeTask> pickRandomTaskForUser(
    String uid, {
    DateTime? now,
  }) async {
    final normalizedUid = uid.trim();
    if (normalizedUid.isEmpty) {
      return pickRandomTask(now: now);
    }

    final current = (now ?? DateTime.now()).toUtc();
    final options = _availableTasks(current);
    if (options.isEmpty) {
      return pickRandomTask(now: current);
    }

    final postsSnapshot = await FirebaseFirestore.instance
        .collection('posts')
        .where('authorId', isEqualTo: normalizedUid)
        .where('status', isEqualTo: 'published')
        .get();

    final completedKeys = <String>{};
    for (final postDoc in postsSnapshot.docs) {
      final data = postDoc.data();
      final category = (data['category'] as String? ?? '').trim();
      final subCategory = (data['subCategory'] as String? ?? '').trim();
      if (category.isEmpty || subCategory.isEmpty || subCategory == 'אחר') {
        continue;
      }
      final key = _taskKey(category, subCategory);
      if (key.isNotEmpty) {
        completedKeys.add(key);
      }
    }

    final remainingOptions = options
        .where(
          (task) => !completedKeys.contains(_taskKey(task.category, task.subCategory)),
        )
        .toList(growable: false);

    final pool = remainingOptions.isNotEmpty ? remainingOptions : options;
    final random = Random(current.millisecondsSinceEpoch ^ pool.length);
    return pool[random.nextInt(pool.length)];
  }

  static Future<SpontaneousChallengeTask?> currentTaskForUser(
    String uid, {
    DateTime? now,
    bool clearExpired = true,
  }) async {
    final normalizedUid = uid.trim();
    if (normalizedUid.isEmpty) {
      return null;
    }

    final current = now ?? DateTime.now();
    final ref = FirebaseFirestore.instance.collection('users').doc(normalizedUid);
    final snapshot = await ref.get();
    final task = SpontaneousChallengeTask.fromMap(
      snapshot.data()?[_fieldKey] as Map<String, dynamic>?,
      now: current,
    );

    if (task == null && clearExpired && snapshot.exists) {
      final raw = snapshot.data()?[_fieldKey];
      if (raw is Map<String, dynamic>) {
        final expiresAt = SpontaneousChallengeTask.fromMap(raw, now: DateTime.now());
        if (expiresAt == null) {
          await ref.set(
            <String, dynamic>{_fieldKey: FieldValue.delete()},
            SetOptions(merge: true),
          );
        }
      }
    }

    return task;
  }

  static Future<void> clearTaskForUser(String uid) async {
    final normalizedUid = uid.trim();
    if (normalizedUid.isEmpty) {
      return;
    }

    await FirebaseFirestore.instance.collection('users').doc(normalizedUid).set(
      <String, dynamic>{_fieldKey: FieldValue.delete()},
      SetOptions(merge: true),
    );
  }

  static Future<SpontaneousChallengeTask> assignTaskForUser(
    String uid, {
    SpontaneousChallengeTask? task,
    DateTime? now,
  }) async {
    final normalizedUid = uid.trim();
    if (normalizedUid.isEmpty) {
      throw ArgumentError('uid is required');
    }

    final current = (now ?? DateTime.now()).toUtc();
    final resolvedTask =
      task ?? await pickRandomTaskForUser(normalizedUid, now: current);

    await FirebaseFirestore.instance.collection('users').doc(normalizedUid).set(
      <String, dynamic>{
        _fieldKey: resolvedTask.toMap(),
      },
      SetOptions(merge: true),
    );

    return resolvedTask;
  }

  static Future<SpontaneousBoostResolution> resolveBoostForPost({
    required String uid,
    required String category,
    required String subCategory,
    DateTime? now,
  }) async {
    final normalizedUid = uid.trim();
    if (normalizedUid.isEmpty) {
      return const SpontaneousBoostResolution(
        spontaneousMultiplier: 1,
        task: null,
        matched: false,
      );
    }

    final current = (now ?? DateTime.now()).toUtc();
    final task = await currentTaskForUser(
      normalizedUid,
      now: current,
      clearExpired: true,
    );

    if (task == null || !task.matchesPost(category: category, subCategory: subCategory)) {
      return SpontaneousBoostResolution(
        spontaneousMultiplier: 1,
        task: task,
        matched: false,
      );
    }

    final multiplier = task.rewardMultiplierAt(current);
    if (multiplier <= 1) {
      return SpontaneousBoostResolution(
        spontaneousMultiplier: 1,
        task: task,
        matched: true,
      );
    }

    return SpontaneousBoostResolution(
      spontaneousMultiplier: multiplier,
      task: task,
      matched: true,
    );
  }

  static List<SpontaneousChallengeTask> availableTasks([DateTime? now]) {
    return _availableTasks((now ?? DateTime.now()).toUtc());
  }

  static List<SpontaneousChallengeTask> _availableTasks(DateTime nowUtc) {
    final options = <SpontaneousChallengeTask>[];
    final uniquePairs = <String>{};

    for (final category in appMainCategories) {
      final normalizedCategory = category.trim();
      if (normalizedCategory.isEmpty || isGeneralCategory(normalizedCategory)) {
        continue;
      }

      final subCategories = appSubCategories(normalizedCategory)
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty)
          .where((value) => value != 'אחר')
          .toList(growable: false);

      for (final subCategory in subCategories) {
        final key = _taskKey(normalizedCategory, subCategory);
        if (!uniquePairs.add(key)) {
          continue;
        }
        if (_bannedTaskKeys.contains(key)) {
          continue;
        }

        options.add(
          SpontaneousChallengeTask(
            category: normalizedCategory,
            subCategory: subCategory,
            assignedAtUtc: nowUtc,
            expiresAtUtc: nowUtc.add(_durationForTaskKey(key)),
          ),
        );
      }
    }

    return options;
  }

  static Duration _durationForTaskKey(String key) {
    return _sevenDayTaskKeys.contains(key)
        ? const Duration(days: 7)
        : const Duration(hours: 48);
  }

  static String _taskKey(String category, String subCategory) {
    return '${category.trim()}::${subCategory.trim()}';
  }
}
