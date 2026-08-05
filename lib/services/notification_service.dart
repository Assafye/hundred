import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

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
  static const String discoveryReminder = 'discovery_reminder';
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
  static const String discoveryReminders = 'discoveryReminders';
  static const String weeklyStars = 'weeklyStars';
  static const String newFollowers = 'newFollowers';
  static const String newFriends = 'newFriends';
}

class NotificationService {
  NotificationService({FirebaseFirestore? db, FirebaseAuth? auth})
      : _db = db ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance;

  final FirebaseFirestore _db;
  final FirebaseAuth _auth;

  static const Map<String, bool> defaultSettings = <String, bool>{
    NotificationSettingKeys.postLikes: true,
    NotificationSettingKeys.postSaves: true,
    NotificationSettingKeys.newMessages: true,
    NotificationSettingKeys.postComments: true,
    NotificationSettingKeys.commentReplies: true,
    NotificationSettingKeys.popJoins: true,
    NotificationSettingKeys.groupJoins: true,
    NotificationSettingKeys.addedToGroups: true,
    NotificationSettingKeys.weeklyChallengeUpdates: true,
    NotificationSettingKeys.discoveryReminders: true,
    NotificationSettingKeys.weeklyStars: true,
    NotificationSettingKeys.newFollowers: true,
    NotificationSettingKeys.newFriends: true,
  };

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
    NotificationTypes.discoveryReminder: NotificationSettingKeys.discoveryReminders,
    NotificationTypes.weeklyStars: NotificationSettingKeys.weeklyStars,
    NotificationTypes.newFollower: NotificationSettingKeys.newFollowers,
    NotificationTypes.newFriend: NotificationSettingKeys.newFriends,
  };

  String get _currentUid => (_auth.currentUser?.uid ?? '').trim();

  Future<void> initializeCurrentUserNotificationSettings() async {
    final uid = _currentUid;
    if (uid.isEmpty) return;

    await _db.collection('users').doc(uid).set(
      <String, dynamic>{
        'notificationSettings': defaultSettings,
        'updatedAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );
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
  }

  Future<void> sendPostLikeNotification({
    required String recipientUid,
    required String postId,
    required int likeCount,
    String postImageUrl = '',
    String? senderUid,
  }) async {
    final normalizedRecipient = recipientUid.trim();
    final normalizedPostId = postId.trim();
    if (normalizedRecipient.isEmpty || normalizedPostId.isEmpty) return;

    final actor = await _actorSummary(senderUid: senderUid);
    final notificationRef = _db
        .collection('users')
        .doc(normalizedRecipient)
        .collection('notifications')
        .doc('post_like_$normalizedPostId');
    final userRef = _db.collection('users').doc(normalizedRecipient);

    final title = likeCount > 1
        ? '$likeCount לייקים על הפוסט שלך'
        : '${actor.name} עשה לך לייק';
    final body = likeCount > 1
        ? 'הפוסט שלך צבר $likeCount לייקים'
        : 'אהבו את הפוסט שלך';

    try {
      await _db.runTransaction((transaction) async {
        final existingSnap = await transaction.get(notificationRef);
        final wasRead = existingSnap.exists
            ? (existingSnap.data()?['isRead'] as bool? ?? false)
            : true;

        transaction.set(
          notificationRef,
          <String, dynamic>{
            'recipientUid': normalizedRecipient,
            'type': NotificationTypes.postLike,
            'title': title,
            'body': body,
            'actorUid': actor.uid,
            'actorName': actor.name,
            'actorAvatarUrl': actor.avatarUrl,
            'postId': normalizedPostId,
            'postImageUrl': postImageUrl.trim(),
            'likeCount': likeCount,
            'isRead': false,
            'createdAt': FieldValue.serverTimestamp(),
            'updatedAt': FieldValue.serverTimestamp(),
          },
          SetOptions(merge: true),
        );

        if (!existingSnap.exists || wasRead) {
          transaction.set(
            userRef,
            <String, dynamic>{
              'unreadNotificationsCount': FieldValue.increment(1),
            },
            SetOptions(merge: true),
          );
        }
      });
    } catch (_) {
      // Best effort fallback: if transaction/update is blocked, create a new notification.
      try {
        await createNotification(
          recipientUid: normalizedRecipient,
          type: NotificationTypes.postLike,
          title: title,
          body: body,
          actorUid: actor.uid,
          actorName: actor.name,
          actorAvatarUrl: actor.avatarUrl,
          postId: normalizedPostId,
          postImageUrl: postImageUrl.trim(),
          extra: <String, dynamic>{
            'likeCount': likeCount,
            'updatedAt': FieldValue.serverTimestamp(),
          },
        );
        return;
      } catch (_) {
        // Final fallback below bypasses settings-read path to avoid dropping like alerts.
      }

      try {
        await _db
            .collection('users')
            .doc(normalizedRecipient)
            .collection('notifications')
            .add(<String, dynamic>{
          'recipientUid': normalizedRecipient,
          'type': NotificationTypes.postLike,
          'title': title,
          'body': body,
          'actorUid': actor.uid,
          'actorName': actor.name,
          'actorAvatarUrl': actor.avatarUrl,
          'postId': normalizedPostId,
          'postImageUrl': postImageUrl.trim(),
          'likeCount': likeCount,
          'isRead': false,
          'createdAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        });

        await userRef.set(
          <String, dynamic>{
            'unreadNotificationsCount': FieldValue.increment(1),
          },
          SetOptions(merge: true),
        );
      } catch (_) {
        // Intentionally swallow: notification dispatch is best effort.
      }
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
      title: '${actor.name} שמר את הפוסט שלך',
      body: 'שמרו את הפוסט שלך',
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
    final actor = await _actorSummary(senderUid: senderUid);
    final sender = actor.uid;

    for (final uid in recipientUids
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)) {
      if (uid == sender) continue;
      await createNotification(
        recipientUid: uid,
        type: NotificationTypes.newMessage,
        title: chatName.trim().isEmpty
            ? 'הודעות חדשות - ${actor.name}'
            : 'הודעות חדשות - ${chatName.trim()}',
        body: messageText.trim(),
        actorUid: actor.uid,
        actorName: actor.name,
        actorAvatarUrl: actor.avatarUrl,
        chatId: chatId,
      );
    }
  }

  Future<void> sendPostCommentNotification({
    required String recipientUid,
    required String postId,
    required String commentText,
    required String commentId,
    String postImageUrl = '',
    String? senderUid,
  }) async {
    final actor = await _actorSummary(senderUid: senderUid);
    await createNotification(
      recipientUid: recipientUid,
      type: NotificationTypes.postComment,
      title: '${actor.name} הגיב על הפוסט שלך',
      body: commentText,
      actorUid: actor.uid,
      actorName: actor.name,
      actorAvatarUrl: actor.avatarUrl,
      postId: postId,
      postImageUrl: postImageUrl,
      commentId: commentId,
    );
  }

  Future<void> sendCommentReplyNotification({
    required String recipientUid,
    required String postId,
    required String commentId,
    required String replyText,
    String postImageUrl = '',
    String? senderUid,
  }) async {
    final actor = await _actorSummary(senderUid: senderUid);
    await createNotification(
      recipientUid: recipientUid,
      type: NotificationTypes.commentReply,
      title: '${actor.name} הגיב לתגובה שלך',
      body: replyText,
      actorUid: actor.uid,
      actorName: actor.name,
      actorAvatarUrl: actor.avatarUrl,
      postId: postId,
      postImageUrl: postImageUrl,
      commentId: commentId,
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
          ? 'מישהו הצטרף לפופ שיצרת'
          : '${actor.name} הצטרף דרך הפופ "$groupName"',
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
          ? '${actor.name} הצטרף לקבוצה שלך'
          : '${actor.name} הצטרף לקבוצה "$groupName"',
      body: groupName.trim().isEmpty
          ? 'משתמש הצטרף לקבוצה שלך'
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
  }) async {
    final actor = await _actorSummary(senderUid: addedByUid);
    await createNotification(
      recipientUid: recipientUid,
      type: NotificationTypes.addedToGroup,
      title: groupName.trim().isEmpty
          ? '${actor.name} הוסיף אותך לקבוצה'
          : '${actor.name} הוסיף אותך לקבוצה "$groupName"',
      body: groupName.trim().isEmpty
          ? 'הצטרפת לקבוצה חדשה'
          : 'הצטרפת לקבוצה "$groupName"',
      actorUid: actor.uid,
      actorName: actor.name,
      actorAvatarUrl: actor.avatarUrl,
      groupId: groupId,
      groupName: groupName,
    );
  }

  Future<void> sendWeeklyChallengeUpdatedToAll({
    required String challengeLabel,
  }) async {
    final allUserIds = await _fetchAllUserIds();
    for (final uid in allUserIds) {
      await createNotification(
        recipientUid: uid,
        type: NotificationTypes.weeklyChallengeUpdated,
        title: 'האתגר השבועי התעדכן',
        body: challengeLabel.trim(),
      );
    }
  }

  Future<void> sendBiDailyDiscoveryReminderToAll() async {
    final allUserIds = await _fetchAllUserIds();
    for (final uid in allUserIds) {
      await createNotification(
        recipientUid: uid,
        type: NotificationTypes.discoveryReminder,
        title: 'בא לך לעשות משהו?',
        body: 'היכנס לראות מה אנשים סביבך מחפשים לעשות.',
      );
    }
  }

  Future<void> sendWeeklyStarsNotification({
    required String recipientUid,
    required String postId,
    String postImageUrl = '',
  }) async {
    await createNotification(
      recipientUid: recipientUid,
      type: NotificationTypes.weeklyStars,
      title: 'הפוסט שלך נכנס לכוכבי השבוע',
      body: 'כל הכבוד, הפוסט שלך בלט השבוע.',
      postId: postId,
      postImageUrl: postImageUrl,
    );
  }

  Future<void> sendFollowNotification({
    required String recipientUid,
    String? followerUid,
  }) async {
    final actor = await _actorSummary(senderUid: followerUid);
    await createNotification(
      recipientUid: recipientUid,
      type: NotificationTypes.newFollower,
      title: '${actor.name} התחיל לעקוב אחריך',
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
      title: '${actor.name} עכשיו חבר שלך',
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
    final snapshot = await _db.collection('users').get();
    return snapshot.docs
        .map((doc) => doc.id.trim())
        .where((uid) => uid.isNotEmpty)
        .toList(growable: false);
  }

  Future<bool> _isNotificationEnabled({
    required String uid,
    required String settingKey,
  }) async {
    final userDoc = await _db.collection('users').doc(uid).get();
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
