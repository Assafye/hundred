import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'weekly_challenge_service.dart';

class NotificationTypes {
  static const String postLike = 'post_like';
  static const String postSave = 'post_save';
  static const String newMessage = 'new_message';
  static const String postComment = 'post_comment';
  static const String commentReply = 'comment_reply';
  static const String popJoin = 'pop_join';
  static const String groupJoin = 'group_join';
  static const String addedToGroup = 'added_to_group';
  static const String weeklyChallengeUpdated = 'weekly_challenge_updated';
  static const String dailyChallengeUpdated = 'daily_challenge_updated';
  static const String spontaneousReminder = 'spontaneous_reminder';
  static const String spontaneousTimeWarning = 'spontaneous_time_warning';
  static const String weeklyStars = 'weekly_stars';
  static const String newFollower = 'new_follower';
  static const String newFriend = 'new_friend';
}

class NotificationSettingKeys {
  static const String postLikes = 'postLikes';
  static const String postSaves = 'postSaves';
  static const String newMessages = 'newMessages';
  static const String postComments = 'postComments';
  static const String commentReplies = 'commentReplies';
  static const String popJoins = 'popJoins';
  static const String groupJoins = 'groupJoins';
  static const String addedToGroups = 'addedToGroups';
  static const String weeklyChallengeUpdates = 'weeklyChallengeUpdates';
  static const String dailyChallengeUpdates = 'dailyChallengeUpdates';
  static const String spontaneousReminders = 'spontaneousReminders';
  static const String spontaneousTimeWarnings = 'spontaneousTimeWarnings';
  static const String weeklyStars = 'weeklyStars';
  static const String newFollowers = 'newFollowers';
  static const String newFriends = 'newFriends';
}

class NotificationSettingOption {
  final String key;
  final String title;
  final String subtitle;

  const NotificationSettingOption({
    required this.key,
    required this.title,
    required this.subtitle,
  });
}

class NotificationService {
  NotificationService({FirebaseFirestore? db, FirebaseAuth? auth})
      : _db = db ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance;

  final FirebaseFirestore _db;
  final FirebaseAuth _auth;
  static bool _notificationWritesSuspendedSessionWide = false;

  static bool get notificationsSuspendedSessionWide =>
      _notificationWritesSuspendedSessionWide;

  static void suspendNotificationsSessionWide() {
    _notificationWritesSuspendedSessionWide = true;
  }

  static const List<NotificationSettingOption> settingOptions =
      <NotificationSettingOption>[
    NotificationSettingOption(
      key: NotificationSettingKeys.postLikes,
      title: 'לייקים לפוסטים שלי',
      subtitle: 'כשמישהו עושה לייק לפוסט שלך',
    ),
    NotificationSettingOption(
      key: NotificationSettingKeys.postSaves,
      title: 'שמירות לפוסטים שלי',
      subtitle: 'כשמישהו שומר את הפוסט שלך',
    ),
    NotificationSettingOption(
      key: NotificationSettingKeys.newMessages,
      title: 'הודעות חדשות',
      subtitle: 'הודעות מקבוצות או צאטים אישיים',
    ),
    NotificationSettingOption(
      key: NotificationSettingKeys.postComments,
      title: 'תגובות על הפוסט שלי',
      subtitle: 'כשמגיבים לפוסט שלך',
    ),
    NotificationSettingOption(
      key: NotificationSettingKeys.commentReplies,
      title: 'תגובות לתגובה שלי',
      subtitle: 'כשמגיבים לתגובה שכתבת',
    ),
    NotificationSettingOption(
      key: NotificationSettingKeys.popJoins,
      title: 'הצטרפות לפופ שיצרתי',
      subtitle: 'כשמשתמש מצטרף לפופ שלך',
    ),
    NotificationSettingOption(
      key: NotificationSettingKeys.groupJoins,
      title: 'הצטרפות לקבוצה שלי',
      subtitle: 'כשמשתמש מצטרף לקבוצה שיצרת',
    ),
    NotificationSettingOption(
      key: NotificationSettingKeys.addedToGroups,
      title: 'הוספה לקבוצה חדשה',
      subtitle: 'כשמוסיפים אותך לקבוצה',
    ),
    NotificationSettingOption(
      key: NotificationSettingKeys.weeklyChallengeUpdates,
      title: 'עדכון אתגר שבועי',
      subtitle: 'התראה כשהאתגר השבועי משתנה',
    ),
    NotificationSettingOption(
      key: NotificationSettingKeys.dailyChallengeUpdates,
      title: 'עדכון משימה יומית',
      subtitle: 'התראה כשהמשימה היומית בכוכבי השבוע משתנה',
    ),
    NotificationSettingOption(
      key: NotificationSettingKeys.spontaneousReminders,
      title: 'תזכורות ספונטניות',
      subtitle: 'התראות להגרלת משימה ספונטנית כשאין משימה פעילה',
    ),
    NotificationSettingOption(
      key: NotificationSettingKeys.spontaneousTimeWarnings,
      title: 'התראות זמן למשימה ספונטנית',
      subtitle: 'התראות על זמן שנותר לביצוע המשימה הספונטנית',
    ),
    NotificationSettingOption(
      key: NotificationSettingKeys.weeklyStars,
      title: 'כוכבי השבוע',
      subtitle: 'כשפוסט שלך נכנס לכוכבי השבוע',
    ),
    NotificationSettingOption(
      key: NotificationSettingKeys.newFollowers,
      title: 'עוקבים חדשים',
      subtitle: 'כשמשתמש מתחיל לעקוב אחריך',
    ),
    NotificationSettingOption(
      key: NotificationSettingKeys.newFriends,
      title: 'חברים חדשים',
      subtitle: 'כשמשתמש הופך לחבר שלך',
    ),
  ];

  static final Map<String, bool> defaultSettings = Map<String, bool>.unmodifiable(
    <String, bool>{
      for (final option in settingOptions) option.key: true,
    },
  );

  static const Map<String, String> _typeToSettingKey = <String, String>{
    NotificationTypes.postLike: NotificationSettingKeys.postLikes,
    NotificationTypes.postSave: NotificationSettingKeys.postSaves,
    NotificationTypes.newMessage: NotificationSettingKeys.newMessages,
    NotificationTypes.postComment: NotificationSettingKeys.postComments,
    NotificationTypes.commentReply: NotificationSettingKeys.commentReplies,
    NotificationTypes.popJoin: NotificationSettingKeys.popJoins,
    NotificationTypes.groupJoin: NotificationSettingKeys.groupJoins,
    NotificationTypes.addedToGroup: NotificationSettingKeys.addedToGroups,
    NotificationTypes.weeklyChallengeUpdated:
        NotificationSettingKeys.weeklyChallengeUpdates,
    NotificationTypes.dailyChallengeUpdated:
      NotificationSettingKeys.dailyChallengeUpdates,
    NotificationTypes.spontaneousReminder:
      NotificationSettingKeys.spontaneousReminders,
    NotificationTypes.spontaneousTimeWarning:
      NotificationSettingKeys.spontaneousTimeWarnings,
    NotificationTypes.weeklyStars: NotificationSettingKeys.weeklyStars,
    NotificationTypes.newFollower: NotificationSettingKeys.newFollowers,
    NotificationTypes.newFriend: NotificationSettingKeys.newFriends,
  };

  String get _currentUid => (_auth.currentUser?.uid ?? '').trim();

  bool get _writesSuspended => _notificationWritesSuspendedSessionWide;

  bool _isPermissionDenied(Object error) {
    return error is FirebaseException && error.code == 'permission-denied';
  }

  static String _rateLimitBucketFor(String type, DateTime now) {
    switch (type) {
      case NotificationTypes.weeklyChallengeUpdated:
        final startOfWeek = DateTime.utc(now.year, now.month, now.day)
            .subtract(Duration(days: now.weekday - 1));
        return 'week-${startOfWeek.year}-${startOfWeek.month.toString().padLeft(2, '0')}-${startOfWeek.day.toString().padLeft(2, '0')}';
      case NotificationTypes.dailyChallengeUpdated:
      case NotificationTypes.spontaneousReminder:
        return 'day-${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      default:
        return '';
    }
  }

  Future<bool> _shouldSkipDuplicateNotification({
    required String recipientUid,
    required String type,
    required DateTime now,
  }) async {
    final bucket = _rateLimitBucketFor(type, now);
    if (bucket.isEmpty) {
      return false;
    }

    try {
      final userDoc = await _db.collection('users').doc(recipientUid).get();
      final notificationDedupe = userDoc.data()?['notificationDedupe'] as Map<String, dynamic>? ?? <String, dynamic>{};
      final typeMap = notificationDedupe[type] as Map<String, dynamic>? ?? <String, dynamic>{};
      if (typeMap[bucket] is Timestamp) {
        return true;
      }
      if (typeMap[bucket] is DateTime) {
        return true;
      }
      if (typeMap[bucket] is String) {
        return true;
      }
    } catch (_) {
      return false;
    }

    return false;
  }

  Future<void> _markNotificationSent({
    required String recipientUid,
    required String type,
    required DateTime now,
  }) async {
    final bucket = _rateLimitBucketFor(type, now);
    if (bucket.isEmpty) {
      return;
    }

    try {
      await _db.collection('users').doc(recipientUid).set(
        <String, dynamic>{
          'notificationDedupe.$type.$bucket': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );
    } catch (_) {
      // Best effort only.
    }
  }

  void _suspendOnPermissionDenied(Object error) {
    if (_isPermissionDenied(error)) {
      _notificationWritesSuspendedSessionWide = true;
    }
  }

  Future<void> initializeCurrentUserNotificationSettings() async {
    final uid = _currentUid;
    if (uid.isEmpty) return;

    final userRef = _db.collection('users').doc(uid);
    final snapshot = await userRef.get();
    final data = snapshot.data() ?? const <String, dynamic>{};
    final existingSettings =
        (data['notificationSettings'] as Map<String, dynamic>?) ??
            const <String, dynamic>{};

    final updates = <String, dynamic>{};
    for (final entry in defaultSettings.entries) {
      if (existingSettings[entry.key] is! bool) {
        updates['notificationSettings.${entry.key}'] = entry.value;
      }
    }

    if (updates.isEmpty) {
      return;
    }

    updates['updatedAt'] = FieldValue.serverTimestamp();
    await userRef.set(updates, SetOptions(merge: true));
  }

  Future<void> updateCurrentUserSettings(Map<String, bool> updates) async {
    final uid = _currentUid;
    if (uid.isEmpty || updates.isEmpty) return;

    final payload = <String, dynamic>{
      'updatedAt': FieldValue.serverTimestamp(),
    };

    for (final entry in updates.entries) {
      payload['notificationSettings.${entry.key}'] = entry.value;
    }

    await _db.collection('users').doc(uid).set(payload, SetOptions(merge: true));
  }

  Future<void> createNotification({
    required String recipientUid,
    required String type,
    required String title,
    String body = '',
    String actorUid = '',
    String actorName = '',
    String actorAvatarUrl = '',
    String postId = '',
    String postImageUrl = '',
    String chatId = '',
    String groupId = '',
    String groupName = '',
    String commentId = '',
    Map<String, dynamic> extra = const <String, dynamic>{},
  }) async {
    if (_writesSuspended) {
      return;
    }

    final normalizedRecipient = recipientUid.trim();
    if (normalizedRecipient.isEmpty) return;

    final normalizedType = type.trim();
    final settingKey = _typeToSettingKey[normalizedType];
    if (settingKey != null) {
      final enabled = await _isNotificationEnabled(
        uid: normalizedRecipient,
        settingKey: settingKey,
      );
      if (!enabled) return;
    }

    final now = DateTime.now();
    if (normalizedType == NotificationTypes.weeklyChallengeUpdated ||
        normalizedType == NotificationTypes.dailyChallengeUpdated ||
        normalizedType == NotificationTypes.spontaneousReminder) {
      if (await _shouldSkipDuplicateNotification(
        recipientUid: normalizedRecipient,
        type: normalizedType,
        now: now,
      )) {
        return;
      }
    }

    final payload = <String, dynamic>{
      'recipientUid': normalizedRecipient,
      'type': normalizedType,
      'title': title.trim(),
      'body': body.trim(),
      'actorUid': actorUid.trim(),
      'actorName': actorName.trim(),
      'actorAvatarUrl': actorAvatarUrl.trim(),
      'postId': postId.trim(),
      'postImageUrl': postImageUrl.trim(),
      'chatId': chatId.trim(),
      'groupId': groupId.trim(),
      'groupName': groupName.trim(),
      'commentId': commentId.trim(),
      'isRead': false,
      'createdAt': FieldValue.serverTimestamp(),
      ...extra,
    };

    try {
      await _db
          .collection('users')
          .doc(normalizedRecipient)
          .collection('notifications')
          .add(payload);

      await _db.collection('users').doc(normalizedRecipient).set(
        <String, dynamic>{
          'unreadNotificationsCount': FieldValue.increment(1),
        },
        SetOptions(merge: true),
      );

      if (normalizedType == NotificationTypes.weeklyChallengeUpdated ||
          normalizedType == NotificationTypes.dailyChallengeUpdated ||
          normalizedType == NotificationTypes.spontaneousReminder) {
        await _markNotificationSent(
          recipientUid: normalizedRecipient,
          type: normalizedType,
          now: now,
        );
      }
    } catch (error) {
      _suspendOnPermissionDenied(error);
      // Intentionally swallowed: notification dispatch is best effort only.
    }
  }

  Future<void> sendPostLikeNotification({
    required String recipientUid,
    required String postId,
    required int likeCount,
    String postImageUrl = '',
    String? senderUid,
  }) async {
    if (_writesSuspended) {
      return;
    }

    final normalizedRecipient = recipientUid.trim();
    final normalizedPostId = postId.trim();
    if (normalizedRecipient.isEmpty || normalizedPostId.isEmpty) return;

    final actor = await _actorSummary(senderUid: senderUid);
    final enabled = await _isNotificationEnabled(
      uid: normalizedRecipient,
      settingKey: NotificationSettingKeys.postLikes,
    );
    if (!enabled) {
      return;
    }

    final title = '${actor.name} עשה לך לייק על הפוסט';
    final body = 'יש לך עכשיו $likeCount לייקים על הפוסט';
    final notificationsRef =
        _db.collection('users').doc(normalizedRecipient).collection('notifications');
    final canonicalDocId = 'post_like_$normalizedPostId';
    final canonicalDocRef = notificationsRef.doc(canonicalDocId);

    try {
      await _db.runTransaction((transaction) async {
        final recentActorUids = <String>[];
        if (actor.uid.isNotEmpty) {
          recentActorUids.add(actor.uid);
        }

        final recentActorAvatarUrls = <String>[];
        if (actor.avatarUrl.trim().isNotEmpty) {
          recentActorAvatarUrls.add(actor.avatarUrl.trim());
        }

        Map<String, dynamic> existingData = <String, dynamic>{};
        final existingSnapshot = await transaction.get(canonicalDocRef);
        if (existingSnapshot.exists) {
          existingData = existingSnapshot.data() ?? <String, dynamic>{};
          final old = (existingData['recentLikeActorUids'] as List<dynamic>? ?? const [])
              .map((item) => item.toString().trim())
              .where((item) => item.isNotEmpty)
              .where((item) => item != actor.uid)
              .take(2);
          recentActorUids.addAll(old);

          final oldAvatarUrls =
              (existingData['recentLikeActorAvatarUrls'] as List<dynamic>? ??
                      const [])
                  .map((item) => item.toString().trim())
                  .where((item) => item.isNotEmpty)
                  .where((item) => item != actor.avatarUrl.trim())
                  .take(2);
          recentActorAvatarUrls.addAll(oldAvatarUrls);
        }

        final payload = <String, dynamic>{
          'recipientUid': normalizedRecipient,
          'type': NotificationTypes.postLike,
          'title': title,
          'body': body,
          'actorUid': actor.uid,
          'actorName': actor.name,
          'actorAvatarUrl': actor.avatarUrl,
          'postId': normalizedPostId,
          'postImageUrl': postImageUrl.trim(),
          'isRead': false,
          'likeCount': likeCount,
          'recentLikeActorUids': recentActorUids,
          'recentLikeActorAvatarUrls': recentActorAvatarUrls,
          'updatedAt': FieldValue.serverTimestamp(),
          'createdAt': FieldValue.serverTimestamp(),
        };

        if (existingSnapshot.exists) {
          final wasRead = (existingData['isRead'] as bool?) ?? false;
          transaction.set(canonicalDocRef, payload, SetOptions(merge: true));
          if (wasRead) {
            transaction.set(
              _db.collection('users').doc(normalizedRecipient),
              <String, dynamic>{
                'unreadNotificationsCount': FieldValue.increment(1),
              },
              SetOptions(merge: true),
            );
          }
          return;
        }

        transaction.set(canonicalDocRef, payload);
        transaction.set(
          _db.collection('users').doc(normalizedRecipient),
          <String, dynamic>{
            'unreadNotificationsCount': FieldValue.increment(1),
          },
          SetOptions(merge: true),
        );
      });

      // Cleanup old docs that may still exist from legacy behavior.
      final likeDocs = await notificationsRef
          .where('type', isEqualTo: NotificationTypes.postLike)
          .where('postId', isEqualTo: normalizedPostId)
          .get();
      final staleDocs = likeDocs.docs
          .where((doc) => doc.id != canonicalDocId)
          .toList(growable: false);

      if (staleDocs.isNotEmpty) {
        final unreadStaleCount = staleDocs
            .where((doc) => (doc.data()['isRead'] as bool? ?? false) == false)
            .length;

        final batch = _db.batch();
        for (final doc in staleDocs) {
          batch.delete(doc.reference);
        }
        if (unreadStaleCount > 0) {
          batch.set(
            _db.collection('users').doc(normalizedRecipient),
            <String, dynamic>{
              'unreadNotificationsCount':
                  FieldValue.increment(-unreadStaleCount),
            },
            SetOptions(merge: true),
          );
        }
        await batch.commit();
      }
    } catch (error) {
      _suspendOnPermissionDenied(error);
    }
  }

  Future<void> sendPostSaveNotification({
    required String recipientUid,
    required String postId,
    String postImageUrl = '',
    String? senderUid,
  }) async {
    final normalizedRecipient = recipientUid.trim();
    final normalizedPostId = postId.trim();
    if (normalizedRecipient.isEmpty || normalizedPostId.isEmpty) return;

    final actor = await _actorSummary(senderUid: senderUid);
    await createNotification(
      recipientUid: normalizedRecipient,
      type: NotificationTypes.postSave,
      title: '${actor.name} שמר/ה את הפוסט שלך',
      body: 'שמר/ה את הפוסט שלך',
      actorUid: actor.uid,
      actorName: actor.name,
      actorAvatarUrl: actor.avatarUrl,
      postId: normalizedPostId,
      postImageUrl: postImageUrl.trim(),
    );
  }

  Future<void> sendNewMessageNotification({
    required List<String> recipientUids,
    required String chatId,
    required String chatName,
    required String messageText,
    String? senderUid,
  }) async {
    if (_writesSuspended) {
      return;
    }

    final actor = await _actorSummary(senderUid: senderUid);
    final sender = actor.uid;
    final normalizedChatId = chatId.trim();
    final normalizedChatName = chatName.trim();
    final normalizedMessage = messageText.trim();

    var isGroupChat = false;
    var chatAvatarUrl = '';
    if (normalizedChatId.isNotEmpty) {
      try {
        final chatSnap = await _db.collection('chats').doc(normalizedChatId).get();
        final chatData = chatSnap.data() ?? const <String, dynamic>{};
        final participants =
            (chatData['participants'] as List<dynamic>? ?? const <dynamic>[])
                .map((item) => item.toString().trim())
                .where((item) => item.isNotEmpty)
                .toList(growable: false);
        final isPublic = (chatData['isPublic'] as bool?) ?? false;
        isGroupChat = isPublic || participants.length != 2;
        chatAvatarUrl = (chatData['groupImageUrl'] as String? ?? '').trim();
      } catch (_) {
        // Best effort: defaults keep backward compatible rendering.
      }
    }

    for (final uid in recipientUids
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)) {
      if (uid == sender) continue;
      await createNotification(
        recipientUid: uid,
        type: NotificationTypes.newMessage,
        title: normalizedChatName.isEmpty ? actor.name : normalizedChatName,
        body: normalizedMessage,
        actorUid: actor.uid,
        actorName: actor.name,
        actorAvatarUrl: actor.avatarUrl,
        chatId: normalizedChatId,
        extra: <String, dynamic>{
          'isGroupChat': isGroupChat,
          'chatName': normalizedChatName,
          'chatAvatarUrl': chatAvatarUrl,
        },
      );
    }
  }

  Future<void> sendPostCommentNotification({
    required String recipientUid,
    required String postId,
    required String commentText,
    required String commentId,
    int? commentCount,
    String postImageUrl = '',
    String? senderUid,
  }) async {
    final actor = await _actorSummary(senderUid: senderUid);
    await createNotification(
      recipientUid: recipientUid,
      type: NotificationTypes.postComment,
      title: '"${commentText.trim()}"',
      body: '${actor.name} הגיב על הפוסט שלך',
      actorUid: actor.uid,
      actorName: actor.name,
      actorAvatarUrl: actor.avatarUrl,
      postId: postId,
      postImageUrl: postImageUrl,
      commentId: commentId,
      extra: <String, dynamic>{
        if (commentCount != null) 'commentCount': commentCount,
      },
    );
  }

  Future<void> sendCommentReplyNotification({
    required String recipientUid,
    required String postId,
    required String commentId,
    required String replyText,
    String postOwnerUid = '',
    String postOwnerName = '',
    String postImageUrl = '',
    String? senderUid,
  }) async {
    final actor = await _actorSummary(senderUid: senderUid);
    var normalizedPostOwnerName = postOwnerName.trim();
    final normalizedPostOwnerUid = postOwnerUid.trim();
    if (normalizedPostOwnerName.isEmpty && normalizedPostOwnerUid.isNotEmpty) {
      final postOwner = await _actorSummary(senderUid: normalizedPostOwnerUid);
      normalizedPostOwnerName = postOwner.name.trim();
    }

    await createNotification(
      recipientUid: recipientUid,
      type: NotificationTypes.commentReply,
      title: '"${replyText.trim()}"',
      body: '${actor.name} הגיב על תגובה שלך',
      actorUid: actor.uid,
      actorName: actor.name,
      actorAvatarUrl: actor.avatarUrl,
      postId: postId,
      postImageUrl: postImageUrl,
      commentId: commentId,
      extra: <String, dynamic>{
        if (normalizedPostOwnerName.isNotEmpty)
          'postOwnerName': normalizedPostOwnerName,
      },
    );
  }

  Future<void> sendPopJoinNotification({
    required String recipientUid,
    required String groupId,
    required String groupName,
    String? joiningUid,
  }) async {
    final actor = await _actorSummary(senderUid: joiningUid);
    await createNotification(
      recipientUid: recipientUid,
      type: NotificationTypes.popJoin,
      title: '${actor.name} הצטרף לפופ שלך',
        body: groupName.trim().isEmpty
          ? '${actor.name} הצטרף לפופ שלך'
          : '${actor.name} הצטרף לפופ "$groupName"',
      actorUid: actor.uid,
      actorName: actor.name,
      actorAvatarUrl: actor.avatarUrl,
      groupId: groupId,
      groupName: groupName,
    );
  }

  Future<void> sendGroupJoinNotification({
    required String recipientUid,
    required String groupId,
    required String groupName,
    String? joiningUid,
  }) async {
    final actor = await _actorSummary(senderUid: joiningUid);
    await createNotification(
      recipientUid: recipientUid,
      type: NotificationTypes.groupJoin,
      title: groupName.trim().isEmpty
          ? '${actor.name} הצטרף לקבוצה'
          : '${actor.name} הצטרף לקבוצה "$groupName"',
      body: groupName.trim().isEmpty
          ? '${actor.name} הצטרף לקבוצה'
          : '${actor.name} הצטרף לקבוצה "$groupName"',
      actorUid: actor.uid,
      actorName: actor.name,
      actorAvatarUrl: actor.avatarUrl,
      groupId: groupId,
      groupName: groupName,
    );
  }

  Future<void> sendAddedToGroupNotification({
    required String recipientUid,
    required String groupId,
    required String groupName,
    String? addedByUid,
    String? addedUserUid,
    bool requiresApproval = false,
  }) async {
    final actor = await _actorSummary(senderUid: addedByUid);
    final addedUser = await _actorSummary(senderUid: addedUserUid);
    final normalizedAddedUserName = addedUser.name.trim();
    final normalizedAddedUserAvatarUrl = addedUser.avatarUrl.trim();
    final groupLabel = groupName.trim().isEmpty ? 'קבוצה' : '"$groupName"';
    final body = requiresApproval
        ? '${actor.name} הוסיף את ${addedUser.name} ל$groupLabel. יש בקשת אישור ממתינה.'
        : '${actor.name} הוסיף את ${addedUser.name} ל$groupLabel';
    await createNotification(
      recipientUid: recipientUid,
      type: NotificationTypes.addedToGroup,
      title: 'הוספת משתמש לקבוצה',
      body: body,
      actorUid: actor.uid,
      actorName: actor.name,
      actorAvatarUrl: actor.avatarUrl,
      groupId: groupId,
      groupName: groupName,
      extra: <String, dynamic>{
        'addedUserUid': addedUser.uid,
        'addedUserName': normalizedAddedUserName,
        'addedUserAvatarUrl': normalizedAddedUserAvatarUrl,
        'addedUserUids': <String>[addedUser.uid],
        'addedUserNames': <String>[normalizedAddedUserName],
        'addedUserAvatarUrls': normalizedAddedUserAvatarUrl.isEmpty
            ? const <String>[]
            : <String>[normalizedAddedUserAvatarUrl],
        'addedUsersCount': 1,
        'requiresApproval': requiresApproval,
      },
    );
  }

  Future<void> sendWeeklyChallengeUpdatedToAll({
    required String challengeLabel,
  }) async {
    final allUserIds = await _fetchAllUserIds();
    final normalizedLabel = challengeLabel.trim();
    for (final uid in allUserIds) {
      await createNotification(
        recipientUid: uid,
        type: NotificationTypes.weeklyChallengeUpdated,
        title: 'האתגר השבועי התעדכן',
        body: 'אתגר חדש: $normalizedLabel | ניקוד כפול',
        extra: <String, dynamic>{
          'challengeCategory': normalizedLabel,
        },
      );
    }
  }

  Future<void> sendDailyChallengeUpdatedToAll({
    required String challengeLabel,
  }) async {
    final allUserIds = await _fetchAllUserIds();
    final challenge = WeeklyChallengeService.currentChallenge();
    final normalizedLabel = challengeLabel.trim();
    for (final uid in allUserIds) {
      await createNotification(
        recipientUid: uid,
        type: NotificationTypes.dailyChallengeUpdated,
        title: 'המשימה היומית התעדכנה',
        body: 'משימה יומית חדשה: $normalizedLabel',
        extra: <String, dynamic>{
          'challengeCategory': challenge.mainCategory,
          'challengeSubCategory': normalizedLabel,
        },
      );
    }
  }

  Future<void> sendSpontaneousReminderNotification({
    required String recipientUid,
  }) async {
    await createNotification(
      recipientUid: recipientUid,
      type: NotificationTypes.spontaneousReminder,
      title: 'בוא נבדוק את הספונטניות שלך',
      body: 'הגיע הזמן להגריל משימה ולעשות אותה בזמן קצוב.',
    );
  }

  Future<void> sendSpontaneousTimeWarningNotification({
    required String recipientUid,
    required String warningText,
    int? warningHoursRemaining,
    String spontaneousCategory = '',
    String spontaneousSubCategory = '',
  }) async {
    final normalizedHours = warningHoursRemaining ?? -1;
    final normalizedCategory = spontaneousCategory.trim();
    final normalizedSubCategory = spontaneousSubCategory.trim();

    await createNotification(
      recipientUid: recipientUid,
      type: NotificationTypes.spontaneousTimeWarning,
      title: 'תזכורת למשימה הספונטנית',
      body: warningText.trim(),
      extra: <String, dynamic>{
        if (normalizedHours > 0) 'warningHoursRemaining': normalizedHours,
        if (normalizedCategory.isNotEmpty)
          'spontaneousCategory': normalizedCategory,
        if (normalizedSubCategory.isNotEmpty)
          'spontaneousSubCategory': normalizedSubCategory,
      },
    );
  }

  Future<void> sendWeeklyStarsNotification({
    required String recipientUid,
    required String postId,
    String postImageUrl = '',
  }) async {
    if (_writesSuspended) {
      return;
    }

    final normalizedRecipient = recipientUid.trim();
    final normalizedPostId = postId.trim();
    if (normalizedRecipient.isEmpty || normalizedPostId.isEmpty) {
      return;
    }

    final enabled = await _isNotificationEnabled(
      uid: normalizedRecipient,
      settingKey: NotificationSettingKeys.weeklyStars,
    );
    if (!enabled) {
      return;
    }

    final notificationsRef =
        _db.collection('users').doc(normalizedRecipient).collection('notifications');
    final canonicalDocId = 'weekly_stars_$normalizedPostId';
    final canonicalDocRef = notificationsRef.doc(canonicalDocId);

    try {
      await _db.runTransaction((transaction) async {
        final existingSnapshot = await transaction.get(canonicalDocRef);
        if (existingSnapshot.exists) {
          return;
        }

        final payload = <String, dynamic>{
          'recipientUid': normalizedRecipient,
          'type': NotificationTypes.weeklyStars,
          'title': 'הפוסט שלך נכנס לכוכבי השבוע',
          'body': 'כל הכבוד, הפוסט שלך בלט השבוע.',
          'postId': normalizedPostId,
          'postImageUrl': postImageUrl.trim(),
          'isRead': false,
          'createdAt': FieldValue.serverTimestamp(),
        };

        transaction.set(canonicalDocRef, payload);
        transaction.set(
          _db.collection('users').doc(normalizedRecipient),
          <String, dynamic>{
            'unreadNotificationsCount': FieldValue.increment(1),
          },
          SetOptions(merge: true),
        );
      });
    } catch (error) {
      _suspendOnPermissionDenied(error);
    }
  }

  Future<void> sendFollowNotification({
    required String recipientUid,
    String? followerUid,
  }) async {
    final actor = await _actorSummary(senderUid: followerUid);
    await createNotification(
      recipientUid: recipientUid,
      type: NotificationTypes.newFollower,
      title: 'עוקב חדש',
      body: '${actor.name} התחיל לעקוב אחריך',
      actorUid: actor.uid,
      actorName: actor.name,
      actorAvatarUrl: actor.avatarUrl,
    );
  }

  Future<void> sendFriendshipNotification({
    required String recipientUid,
    String? friendUid,
  }) async {
    final actor = await _actorSummary(senderUid: friendUid);
    await createNotification(
      recipientUid: recipientUid,
      type: NotificationTypes.newFriend,
      title: 'חבר חדש',
      body: '${actor.name} עכשיו חבר שלך',
      actorUid: actor.uid,
      actorName: actor.name,
      actorAvatarUrl: actor.avatarUrl,
    );
  }

  Future<void> markAllAsReadForCurrentUser() async {
    final uid = _currentUid;
    if (uid.isEmpty) return;

    final snapshot = await _db
        .collection('users')
        .doc(uid)
        .collection('notifications')
        .where('isRead', isEqualTo: false)
        .get();

    if (snapshot.docs.isEmpty) {
      return;
    }

    final batch = _db.batch();
    for (final doc in snapshot.docs) {
      batch.update(doc.reference, <String, dynamic>{'isRead': true});
    }
    batch.set(
      _db.collection('users').doc(uid),
      <String, dynamic>{'unreadNotificationsCount': 0},
      SetOptions(merge: true),
    );
    await batch.commit();
  }

  Future<void> markNotificationAsRead({required String notificationId}) async {
    final uid = _currentUid;
    final normalizedNotificationId = notificationId.trim();
    if (uid.isEmpty || normalizedNotificationId.isEmpty) return;

    final userRef = _db.collection('users').doc(uid);
    final notificationRef = userRef.collection('notifications').doc(normalizedNotificationId);

    await _db.runTransaction((transaction) async {
      final notificationSnap = await transaction.get(notificationRef);
      if (!notificationSnap.exists) return;

      final notificationData = notificationSnap.data() ?? <String, dynamic>{};
      final isRead = notificationData['isRead'] as bool? ?? false;
      if (isRead) return;

      transaction.update(notificationRef, <String, dynamic>{
        'isRead': true,
        'readAt': FieldValue.serverTimestamp(),
      });

      final userSnap = await transaction.get(userRef);
      final currentUnread =
          (userSnap.data()?['unreadNotificationsCount'] as num?)?.toInt() ?? 0;
      if (currentUnread > 0) {
        transaction.set(
          userRef,
          <String, dynamic>{
            'unreadNotificationsCount': FieldValue.increment(-1),
          },
          SetOptions(merge: true),
        );
      }
    });
  }

  Future<List<String>> _fetchAllUserIds() async {
    final snapshot = await _db.collection('users_public').get();
    return snapshot.docs
        .map((doc) => doc.id.trim())
        .where((uid) => uid.isNotEmpty)
        .toList(growable: false);
  }

  Future<bool> _isNotificationEnabled({
    required String uid,
    required String settingKey,
  }) async {
    DocumentSnapshot<Map<String, dynamic>>? userDoc;
    try {
      userDoc = await _db.collection('users').doc(uid).get();
    } catch (_) {
      // Fail closed: if we cannot read recipient preferences, do not send.
      return false;
    }
    final data = userDoc.data() ?? <String, dynamic>{};
    final settings =
        (data['notificationSettings'] as Map<String, dynamic>?) ??
            const <String, dynamic>{};

    final dynamic value = settings[settingKey];
    if (value is bool) {
      return value;
    }
    return defaultSettings[settingKey] ?? true;
  }

  Future<_ActorSummary> _actorSummary({String? senderUid}) async {
    final uid = (senderUid ?? _currentUid).trim();
    if (uid.isEmpty) {
      return const _ActorSummary(uid: '', name: 'משתמש', avatarUrl: '');
    }

    try {
      final publicSnap = await _db.collection('users_public').doc(uid).get();
      final publicData = publicSnap.data() ?? <String, dynamic>{};
      final publicName = _displayNameFromData(publicData);
      final publicAvatar = (publicData['profilePictureUrl'] as String? ?? '').trim();
      if (publicName.isNotEmpty || publicAvatar.isNotEmpty) {
        return _ActorSummary(
          uid: uid,
          name: publicName.isNotEmpty ? publicName : 'משתמש',
          avatarUrl: publicAvatar,
        );
      }
    } catch (_) {
      // Keep fallback below.
    }

    try {
      final privateSnap = await _db.collection('users').doc(uid).get();
      final privateData = privateSnap.data() ?? <String, dynamic>{};
      final privateName = _displayNameFromData(privateData);
      final privateAvatar =
          (privateData['profilePictureUrl'] as String? ?? '').trim();
      return _ActorSummary(
        uid: uid,
        name: privateName.isNotEmpty ? privateName : 'משתמש',
        avatarUrl: privateAvatar,
      );
    } catch (_) {
      return _ActorSummary(uid: uid, name: 'משתמש', avatarUrl: '');
    }
  }

  String _displayNameFromData(Map<String, dynamic> data) {
    final displayName = (data['displayName'] as String? ?? '').trim();
    if (displayName.isNotEmpty) return displayName;

    final firstName = (data['firstName'] as String? ?? '').trim();
    final lastName = (data['lastName'] as String? ?? '').trim();
    final joined = [firstName, lastName]
        .where((part) => part.isNotEmpty)
        .join(' ')
        .trim();
    if (joined.isNotEmpty) return joined;

    final username = (data['username'] as String? ?? '').trim();
    if (username.isNotEmpty) return username;

    return '';
  }
}

class _ActorSummary {
  final String uid;
  final String name;
  final String avatarUrl;

  const _ActorSummary({
    required this.uid,
    required this.name,
    required this.avatarUrl,
  });
}
