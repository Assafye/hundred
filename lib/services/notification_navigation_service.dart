import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../chat_room_screen.dart';
import '../chats_screen.dart';
import '../group_details_screen.dart';
import '../notifications_preview_screen.dart';
import '../post_detail_view.dart';
import '../services/notification_service.dart';
import '../stars_screen.dart';
import '../user_profile_screen.dart';
import 'app_navigator.dart';

class NotificationNavigationService {
  NotificationNavigationService._();

  static Future<void> openFromData(Map<String, dynamic> data) async {
    final navigator = appNavigatorKey.currentState;
    final context = appNavigatorKey.currentContext;
    if (navigator == null || context == null) {
      return;
    }

    final type = (data['type'] as String? ?? '').trim();
    switch (type) {
      case NotificationTypes.postLike:
      case NotificationTypes.postSave:
        await _openPost(navigator, data: data);
        return;
      case NotificationTypes.postComment:
      case NotificationTypes.commentReply:
        await _openPost(
          navigator,
          data: data,
          initialCommentId: (data['commentId'] as String? ?? '').trim(),
        );
        return;
      case NotificationTypes.newFollower:
      case NotificationTypes.newFriend:
        _openUserProfile(navigator, data);
        return;
      case NotificationTypes.popJoin:
      case NotificationTypes.groupJoin:
      case NotificationTypes.addedToGroup:
        _openGroup(navigator, data);
        return;
      case NotificationTypes.newMessage:
        await _openChat(navigator, data);
        return;
      case NotificationTypes.weeklyChallengeUpdated:
      case NotificationTypes.dailyChallengeUpdated:
      case NotificationTypes.spontaneousReminder:
      case NotificationTypes.spontaneousTimeWarning:
        navigator.push(
          MaterialPageRoute(
            builder: (_) => const StarsScreen(openSpontaneousModalOnStart: true),
          ),
        );
        return;
      case NotificationTypes.weeklyStars:
        navigator.push(
          MaterialPageRoute(
            builder: (_) => StarsScreen(
              initialPostId: (data['postId'] as String? ?? '').trim(),
            ),
          ),
        );
        return;
      default:
        navigator.push(
          MaterialPageRoute(builder: (_) => const NotificationsPreviewScreen()),
        );
        return;
    }
  }

  static Future<void> _openPost(
    NavigatorState navigator, {
    required Map<String, dynamic> data,
    String initialCommentId = '',
  }) async {
    final postId = (data['postId'] as String? ?? '').trim();
    if (postId.isEmpty) {
      navigator.push(
        MaterialPageRoute(builder: (_) => const NotificationsPreviewScreen()),
      );
      return;
    }

    final postSnapshot =
        await FirebaseFirestore.instance.collection('posts').doc(postId).get();
    final postData = postSnapshot.data();
    if (postData == null) {
      return;
    }

    navigator.push(
      MaterialPageRoute(
        builder: (_) => PostDetailView(
          posts: [<String, dynamic>{'id': postSnapshot.id, ...postData}],
          initialIndex: 0,
          initialCommentId: initialCommentId,
        ),
      ),
    );
  }

  static void _openUserProfile(
    NavigatorState navigator,
    Map<String, dynamic> data,
  ) {
    final uid = (data['actorUid'] as String? ?? '').trim();
    if (uid.isEmpty) {
      return;
    }

    navigator.push(
      MaterialPageRoute(
        builder: (_) => UserProfileScreen(uid: uid, currentBottomIndex: 0),
      ),
    );
  }

  static void _openGroup(
    NavigatorState navigator,
    Map<String, dynamic> data,
  ) {
    final groupId = (data['groupId'] as String? ?? '').trim();
    if (groupId.isEmpty) {
      return;
    }

    navigator.push(
      MaterialPageRoute(
        builder: (_) => GroupDetailsScreen(isAdmin: false, groupId: groupId),
      ),
    );
  }

  static Future<void> _openChat(
    NavigatorState navigator,
    Map<String, dynamic> data,
  ) async {
    final chatId = (data['chatId'] as String? ?? '').trim();
    if (chatId.isEmpty) {
      navigator.push(
        MaterialPageRoute(builder: (_) => const ChatsScreen()),
      );
      return;
    }

    final chatSnap =
        await FirebaseFirestore.instance.collection('chats').doc(chatId).get();
    final chatData = chatSnap.data();
    if (chatData == null) {
      navigator.push(
        MaterialPageRoute(builder: (_) => const ChatsScreen()),
      );
      return;
    }

    final chatName = (chatData['name'] as String? ?? '').trim();
    final avatarUrl = (chatData['groupImageUrl'] as String? ?? '').trim();
    final isPublic = (chatData['isPublic'] as bool?) ?? false;
    final participants = (chatData['participants'] as List<dynamic>? ?? const [])
        .map((item) => item.toString().trim())
        .where((item) => item.isNotEmpty)
        .toList(growable: false);

    navigator.push(
      MaterialPageRoute(
        builder: (_) => ChatRoomScreen(
          chatName: chatName.isEmpty ? 'צ׳אט' : chatName,
          avatarUrl: avatarUrl,
          chatId: chatId,
          isDirectChat: !isPublic && participants.length == 2,
          directOtherUserId: (data['actorUid'] as String? ?? '').trim(),
        ),
      ),
    );
  }
}
