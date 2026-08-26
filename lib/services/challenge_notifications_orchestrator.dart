import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'notification_service.dart';
import 'spontaneous_challenge_service.dart';
import 'weekly_challenge_service.dart';

class ChallengeNotificationsOrchestrator {
  ChallengeNotificationsOrchestrator._();

  static final ChallengeNotificationsOrchestrator instance =
      ChallengeNotificationsOrchestrator._();

  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final NotificationService _notificationService = NotificationService();

  Timer? _timer;
  bool _isRunning = false;

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(minutes: 20), (_) {
      _runSafely();
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _runSafely() async {
    if (_isRunning) {
      return;
    }
    _isRunning = true;
    try {
      await _run();
    } finally {
      _isRunning = false;
    }
  }

  Future<void> _run() async {
    final uid = (_auth.currentUser?.uid ?? '').trim();
    if (uid.isEmpty) {
      return;
    }

    final userRef = _db.collection('users').doc(uid);
    final userSnap = await userRef.get();
    final userData = userSnap.data() ?? <String, dynamic>{};

    await _maybeSendWeeklyChallengeNotification(
      uid: uid,
      userRef: userRef,
      userData: userData,
    );

    await _maybeSendDailyChallengeNotification(
      uid: uid,
      userRef: userRef,
      userData: userData,
    );

    await _maybeSendSpontaneousNotifications(
      uid: uid,
      userRef: userRef,
      userData: userData,
    );
  }

  Future<void> _maybeSendWeeklyChallengeNotification({
    required String uid,
    required DocumentReference<Map<String, dynamic>> userRef,
    required Map<String, dynamic> userData,
  }) async {
    final now = DateTime.now();
    if (now.hour < 12) {
      return;
    }

    final nowUtc = now.toUtc();
    final weekIndex = _weekIndexFor(nowUtc);
    final lastWeekIndex = _intValue(
      userData,
      'notificationMeta.weeklyChallenge.lastWeekIndex',
      fallback: -1,
    );

    if (lastWeekIndex == weekIndex) {
      return;
    }

    final challenge = WeeklyChallengeService.currentChallenge(now: nowUtc);
    await _notificationService.createNotification(
      recipientUid: uid,
      type: NotificationTypes.weeklyChallengeUpdated,
      title: 'האתגר השבועי התעדכן',
      body: 'אתגר חדש: ${challenge.mainCategory} | ניקוד כפול',
      extra: <String, dynamic>{
        'challengeCategory': challenge.mainCategory,
        'challengeSubCategory': challenge.subCategory,
      },
    );

    await userRef.set(
      <String, dynamic>{
        'notificationMeta.weeklyChallenge.lastWeekIndex': weekIndex,
        'notificationMeta.weeklyChallenge.lastSentAt':
            FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );
  }

  Future<void> _maybeSendDailyChallengeNotification({
    required String uid,
    required DocumentReference<Map<String, dynamic>> userRef,
    required Map<String, dynamic> userData,
  }) async {
    final now = DateTime.now();
    if (now.hour < 14) {
      return;
    }

    final dayKey = _dayKey(now);
    final lastDayKey = _stringValue(
      userData,
      'notificationMeta.dailyChallenge.lastDayKey',
    );

    if (lastDayKey == dayKey) {
      return;
    }

    final challenge = WeeklyChallengeService.currentChallenge(now: now.toUtc());
    await _notificationService.createNotification(
      recipientUid: uid,
      type: NotificationTypes.dailyChallengeUpdated,
      title: 'המשימה היומית התעדכנה',
      body: 'המשימה היומית: ${challenge.subCategory}',
      extra: <String, dynamic>{
        'challengeCategory': challenge.mainCategory,
        'challengeSubCategory': challenge.subCategory,
      },
    );

    await userRef.set(
      <String, dynamic>{
        'notificationMeta.dailyChallenge.lastDayKey': dayKey,
        'notificationMeta.dailyChallenge.lastSentAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );
  }

  Future<void> _maybeSendSpontaneousNotifications({
    required String uid,
    required DocumentReference<Map<String, dynamic>> userRef,
    required Map<String, dynamic> userData,
  }) async {
    final now = DateTime.now().toUtc();
    final task = await SpontaneousChallengeService.currentTaskForUser(
      uid,
      now: now,
      clearExpired: true,
    );

    if (task == null) {
      final lastReminderRaw = _timestampValue(
        userData,
        'notificationMeta.spontaneous.lastNoTaskReminderAt',
      );
      final hoursSince =
          lastReminderRaw == null ? 9999 : now.difference(lastReminderRaw).inHours;
      if (hoursSince >= 24) {
        await _notificationService.sendSpontaneousReminderNotification(
          recipientUid: uid,
        );
        await userRef.set(
          <String, dynamic>{
            'notificationMeta.spontaneous.lastNoTaskReminderAt':
                FieldValue.serverTimestamp(),
          },
          SetOptions(merge: true),
        );
      }
      return;
    }

    final taskKey = '${task.category}::${task.subCategory}::${task.expiresAtUtc.toIso8601String()}';
    final trackedTaskKey =
        _stringValue(userData, 'notificationMeta.spontaneous.activeTaskKey');

    if (trackedTaskKey != taskKey) {
      await userRef.set(
        <String, dynamic>{
          'notificationMeta.spontaneous.activeTaskKey': taskKey,
          'notificationMeta.spontaneous.sentTenXEnd': false,
          'notificationMeta.spontaneous.sent24h': false,
          'notificationMeta.spontaneous.sent1h': false,
          'notificationMeta.spontaneous.lastCadenceReminderAt': null,
          'notificationMeta.spontaneous.lastAnyWarningAt': null,
        },
        SetOptions(merge: true),
      );
      userData['notificationMeta'] = <String, dynamic>{};
    }

    final total = task.totalDuration;
    final remaining = task.remainingAt(now);
    final elapsed = total - remaining;

    final sentTenXEnd =
        _boolValue(userData, 'notificationMeta.spontaneous.sentTenXEnd');
    final sent24h = _boolValue(userData, 'notificationMeta.spontaneous.sent24h');
    final sent1h = _boolValue(userData, 'notificationMeta.spontaneous.sent1h');
    var lastCadenceReminderAt = _timestampValue(
      userData,
      'notificationMeta.spontaneous.lastCadenceReminderAt',
    );
    var lastAnyWarningAt = _timestampValue(
      userData,
      'notificationMeta.spontaneous.lastAnyWarningAt',
    );

    Future<void> sendWarning({
      required String warningText,
      required Map<String, dynamic> meta,
      bool cadence = false,
    }) async {
      final sinceLastAny = lastAnyWarningAt == null
          ? 9999
          : now.difference(lastAnyWarningAt!).inHours;
      if (sinceLastAny < 2) {
        return;
      }

      await _notificationService.sendSpontaneousTimeWarningNotification(
        recipientUid: uid,
        warningText: warningText,
      );

      final payload = <String, dynamic>{
        ...meta,
        'notificationMeta.spontaneous.lastAnyWarningAt':
            FieldValue.serverTimestamp(),
      };
      if (cadence) {
        payload['notificationMeta.spontaneous.lastCadenceReminderAt'] =
            FieldValue.serverTimestamp();
      }
      await userRef.set(payload, SetOptions(merge: true));
      lastAnyWarningAt = now;
      if (cadence) {
        lastCadenceReminderAt = now;
      }
    }

    final halfway = Duration(milliseconds: total.inMilliseconds ~/ 2);
    if (!sentTenXEnd && elapsed >= halfway) {
      await sendWarning(
        warningText: 'הבונוס X10 נגמר. עדיין אפשר להשלים את המשימה בזמן.',
        meta: <String, dynamic>{
          'notificationMeta.spontaneous.sentTenXEnd': true,
        },
      );
    }

    if (!sent24h && remaining <= const Duration(hours: 24)) {
      await sendWarning(
        warningText: 'נשארו לך 24 שעות לבצע את המשימה הספונטנית.',
        meta: <String, dynamic>{
          'notificationMeta.spontaneous.sent24h': true,
        },
      );
    }

    if (!sent1h && remaining <= const Duration(hours: 1)) {
      await sendWarning(
        warningText: 'נשארה פחות משעה לסיום המשימה הספונטנית.',
        meta: <String, dynamic>{
          'notificationMeta.spontaneous.sent1h': true,
        },
      );
    }

    final sinceCadence = lastCadenceReminderAt == null
        ? 9999
      : now.difference(lastCadenceReminderAt!).inHours;
    if (sinceCadence >= 17 && remaining > const Duration(hours: 1)) {
      await sendWarning(
        warningText: 'עדיין יש לך זמן למשימה הספונטנית: ${_formatRemaining(remaining)}',
        meta: const <String, dynamic>{},
        cadence: true,
      );
    }
  }

  static String _formatRemaining(Duration duration) {
    if (duration.inHours >= 24) {
      final days = duration.inDays;
      final hours = duration.inHours % 24;
      return '$days ימים ו-$hours שעות';
    }
    if (duration.inHours >= 1) {
      return '${duration.inHours} שעות';
    }
    return '${duration.inMinutes} דקות';
  }

  static int _weekIndexFor(DateTime utcDate) {
    final anchor = DateTime.utc(2024, 1, 1);
    return utcDate.difference(anchor).inDays ~/ 7;
  }

  static String _dayKey(DateTime date) {
    return '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
  }

  static dynamic _valueAtPath(Map<String, dynamic> data, String path) {
    dynamic current = data;
    for (final part in path.split('.')) {
      if (current is! Map<String, dynamic>) {
        return null;
      }
      current = current[part];
    }
    return current;
  }

  static String _stringValue(Map<String, dynamic> data, String path) {
    final value = _valueAtPath(data, path);
    return value is String ? value.trim() : '';
  }

  static int _intValue(
    Map<String, dynamic> data,
    String path, {
    int fallback = 0,
  }) {
    final value = _valueAtPath(data, path);
    if (value is num) {
      return value.toInt();
    }
    return fallback;
  }

  static bool _boolValue(Map<String, dynamic> data, String path) {
    final value = _valueAtPath(data, path);
    return value is bool ? value : false;
  }

  static DateTime? _timestampValue(Map<String, dynamic> data, String path) {
    final value = _valueAtPath(data, path);
    if (value is Timestamp) {
      return value.toDate().toUtc();
    }
    if (value is DateTime) {
      return value.toUtc();
    }
    if (value is String) {
      return DateTime.tryParse(value)?.toUtc();
    }
    return null;
  }
}
