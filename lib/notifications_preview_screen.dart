import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';

import 'chats_screen.dart';
import 'chat_room_screen.dart';
import 'group_details_screen.dart';
import 'post_media_utils.dart';
import 'post_detail_view.dart';
import 'services/notification_service.dart';
import 'stars_screen.dart' show StarsScreen;
import 'user_profile_screen.dart';
import 'widgets/swipe_back_wrapper.dart';
import 'video_preview_utils.dart';

class _NotificationMediaPreview {
  final String thumbnailUrl;
  final String videoUrl;

  const _NotificationMediaPreview({
    required this.thumbnailUrl,
    required this.videoUrl,
  });

  bool get hasThumbnail => thumbnailUrl.trim().isNotEmpty;
  bool get hasVideo => videoUrl.trim().isNotEmpty;
}

class NotificationsPreviewScreen extends StatefulWidget {
  const NotificationsPreviewScreen({super.key});

  @override
  State<NotificationsPreviewScreen> createState() =>
      _NotificationsPreviewScreenState();
}

class _NotificationsPreviewScreenState
    extends State<NotificationsPreviewScreen> {
  final NotificationService _notificationService = NotificationService();
  final Map<String, Future<Map<String, dynamic>?>> _postFutureCache =
      <String, Future<Map<String, dynamic>?>>{};
  final Map<String, Future<_NotificationMediaPreview>>
      _postPreviewFutureCache = <String, Future<_NotificationMediaPreview>>{};
  final Map<String, Future<String?>> _resolvedMediaUrlFutureCache =
      <String, Future<String?>>{};
  final Map<String, Future<Uint8List?>> _videoPreviewFutureByUrl =
      <String, Future<Uint8List?>>{};
    final Map<String, Future<String>> _profileAvatarFutureByUid =
      <String, Future<String>>{};
  DateTime? _lastVisitedAt;
  bool _visitMarkerLoaded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializeVisitState();
    });
  }

  Future<void> _initializeVisitState() async {
    final uid = _currentUid();
    if (uid.isEmpty) return;

    final userRef = FirebaseFirestore.instance.collection('users').doc(uid);
    final openedAt = DateTime.now();

    try {
      final userSnap = await userRef.get();
      final data = userSnap.data() ?? const <String, dynamic>{};
      final lastVisited = _toDateTime(data['notificationsLastVisitedAt']);
      if (mounted) {
        setState(() {
          _lastVisitedAt = lastVisited;
          _visitMarkerLoaded = true;
        });
      }
    } catch (_) {
      // Best effort: highlighting still works with null last-visited fallback.
      if (mounted) {
        setState(() {
          _visitMarkerLoaded = true;
        });
      }
    }

    try {
      await _notificationService.markAllAsReadForCurrentUser();
    } catch (_) {
      // Best effort.
    }

    try {
      await userRef.set(
        <String, dynamic>{
          'notificationsLastVisitedAt': Timestamp.fromDate(openedAt),
        },
        SetOptions(merge: true),
      );
    } catch (_) {
      // Best effort.
    }
  }

  String _currentUid() {
    return (FirebaseAuth.instance.currentUser?.uid ?? '').trim();
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> _notificationsStream(String uid) {
    return FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('notifications')
        .orderBy('createdAt', descending: true)
        .limit(120)
        .snapshots();
  }

  String _timeLabel(dynamic rawCreatedAt) {
    final createdAt = _toDateTime(rawCreatedAt);
    if (createdAt == null) return '';
    final diff = DateTime.now().difference(createdAt);
    if (diff.inMinutes < 1) return 'עכשיו';
    if (diff.inHours < 1) return 'לפני ${diff.inMinutes} דק\'';
    if (diff.inDays < 1) return 'לפני ${diff.inHours} שעות';
    return 'לפני ${diff.inDays} ימים';
  }

  DateTime? _toDateTime(dynamic rawValue) {
    if (rawValue is Timestamp) {
      return rawValue.toDate();
    }
    if (rawValue is DateTime) {
      return rawValue;
    }
    if (rawValue is String) {
      return DateTime.tryParse(rawValue);
    }
    return null;
  }

  bool _isNewSinceLastVisit(Map<String, dynamic> data) {
    final lastVisited = _lastVisitedAt;
    if (lastVisited == null) return false;
    final createdAt = _toDateTime(data['createdAt']);
    if (createdAt == null) return false;
    return createdAt.isAfter(lastVisited);
  }

  bool _shouldHighlightAsNew(Map<String, dynamic> data) {
    if (_isNewSinceLastVisit(data)) {
      return true;
    }

    // Fallback: when a marker does not exist yet, unread notifications are treated as new.
    if (_lastVisitedAt == null && _visitMarkerLoaded) {
      return _isUnread(data);
    }

    // While loading marker state, keep unread notifications highlighted.
    if (!_visitMarkerLoaded) {
      return _isUnread(data);
    }

    return false;
  }

  Color _dynamicNewBorderColor({
    required bool isLight,
    required String docId,
    required Color accent,
  }) {
    final seed = docId.codeUnits.fold<int>(0, (total, unit) => total + unit);
    final ratio = (seed % 100) / 100;
    final baseCyan =
        isLight ? const Color(0xFF9EEBFF) : const Color(0xFF8EDCFF);
    final basePurple =
        isLight ? const Color(0xFFC8B9FF) : const Color(0xFF9F9CFF);
    final blended = Color.lerp(baseCyan, basePurple, ratio) ?? baseCyan;
    return Color.lerp(blended, accent, 0.18) ?? blended;
  }

  int _intValue(Map<String, dynamic> data, List<String> keys,
      {int fallback = 0}) {
    for (final key in keys) {
      final raw = data[key];
      if (raw is num) return raw.toInt();
      if (raw is String) {
        final parsed = int.tryParse(raw.trim());
        if (parsed != null) return parsed;
      }
    }
    return fallback;
  }

  String _postId(Map<String, dynamic> data) {
    return (data['postId'] as String? ?? '').trim();
  }

  String _commentId(Map<String, dynamic> data) {
    return (data['commentId'] as String? ?? '').trim();
  }

  String _groupId(Map<String, dynamic> data) {
    return (data['groupId'] as String? ?? '').trim();
  }

  String _actorUid(Map<String, dynamic> data) {
    return (data['actorUid'] as String? ?? '').trim();
  }

  String _actorName(Map<String, dynamic> data) {
    final actorName = (data['actorName'] as String? ?? '').trim();
    return actorName.isNotEmpty ? actorName : 'משתמש';
  }

  String _postImageUrl(Map<String, dynamic> data) {
    return (data['postImageUrl'] as String? ?? '').trim();
  }

  bool _isUnread(Map<String, dynamic> data) {
    return (data['isRead'] as bool? ?? false) == false;
  }

  Future<Map<String, dynamic>?> _fetchPost(String postId) async {
    final normalizedPostId = postId.trim();
    if (normalizedPostId.isEmpty) return null;

    final snap = await FirebaseFirestore.instance
        .collection('posts')
        .doc(normalizedPostId)
        .get();
    if (!snap.exists) return null;

    final data = <String, dynamic>{...snap.data() ?? <String, dynamic>{}};
    data['id'] = snap.id;
    data['postId'] = (data['postId'] as String? ?? snap.id).trim();
    return data;
  }

  Future<Map<String, dynamic>?> _cachedPostFuture(String postId) {
    final normalizedPostId = postId.trim();
    if (normalizedPostId.isEmpty) {
      return Future<Map<String, dynamic>?>.value(null);
    }

    return _postFutureCache.putIfAbsent(
      normalizedPostId,
      () => _fetchPost(normalizedPostId),
    );
  }

  Future<String?> _resolveMediaUrl(String source) async {
    final normalized = source.trim();
    if (normalized.isEmpty) {
      return null;
    }

    if (normalized.startsWith('http://') ||
        normalized.startsWith('https://')) {
      return normalized;
    }

    try {
      if (normalized.startsWith('gs://')) {
        return await FirebaseStorage.instance
            .refFromURL(normalized)
            .getDownloadURL();
      }

      return await FirebaseStorage.instance.ref(normalized).getDownloadURL();
    } catch (_) {
      return normalized;
    }
  }

  Future<String?> _resolvedMediaUrlFuture(String source) {
    final normalized = source.trim();
    if (normalized.isEmpty) {
      return Future<String?>.value(null);
    }

    return _resolvedMediaUrlFutureCache.putIfAbsent(
      normalized,
      () => _resolveMediaUrl(normalized),
    );
  }

  Future<String> _profileAvatarFuture(String uid) {
    final normalizedUid = uid.trim();
    if (normalizedUid.isEmpty) {
      return Future<String>.value('');
    }

    return _profileAvatarFutureByUid.putIfAbsent(normalizedUid, () async {
      try {
        final publicSnap = await FirebaseFirestore.instance
            .collection('users_public')
            .doc(normalizedUid)
            .get();
        final publicData = publicSnap.data() ?? const <String, dynamic>{};
        final direct = (publicData['profilePictureUrl'] as String? ??
                publicData['profileImageUrl'] as String? ??
                publicData['avatarUrl'] as String? ??
                '')
            .trim();
        if (direct.isNotEmpty) {
          return direct;
        }
      } catch (_) {}

      try {
        final userSnap = await FirebaseFirestore.instance
            .collection('users')
            .doc(normalizedUid)
            .get();
        final userData = userSnap.data() ?? const <String, dynamic>{};
        final direct = (userData['profilePictureUrl'] as String? ??
                userData['profileImageUrl'] as String? ??
                userData['avatarUrl'] as String? ??
                '')
            .trim();
        if (direct.isNotEmpty) {
          return direct;
        }
      } catch (_) {}

      return '';
    });
  }

  Future<_NotificationMediaPreview> _notificationMediaPreviewFuture(
      Map<String, dynamic> data) {
    final postId = _postId(data);
    if (postId.isEmpty) {
      final fallback = _postImageUrl(data);
      if (fallback.isEmpty) {
        return Future<_NotificationMediaPreview>.value(
          const _NotificationMediaPreview(thumbnailUrl: '', videoUrl: ''),
        );
      }
      return _resolvedMediaUrlFuture(fallback).then(
        (url) => _NotificationMediaPreview(
          thumbnailUrl: url ?? fallback,
          videoUrl: '',
        ),
      );
    }

    return _postPreviewFutureCache.putIfAbsent(
      postId,
      () async {
        final post = await _cachedPostFuture(postId);
        if (post == null) {
          final fallback = _postImageUrl(data);
          if (fallback.isEmpty) {
            return const _NotificationMediaPreview(
              thumbnailUrl: '',
              videoUrl: '',
            );
          }
          final resolved = await _resolvedMediaUrlFuture(fallback) ?? fallback;
          return _NotificationMediaPreview(
            thumbnailUrl: resolved,
            videoUrl: '',
          );
        }

        String? firstVideoUrl;
        final directThumbnailCandidates = <String>[
          (post['thumbnailUrl'] as String? ?? '').trim(),
          (post['videoThumbnailUrl'] as String? ?? '').trim(),
        ];

        for (final candidate in directThumbnailCandidates) {
          final resolved = await _resolvedMediaUrlFuture(candidate) ?? candidate;
          if (resolved.isNotEmpty) {
            return _NotificationMediaPreview(
              thumbnailUrl: resolved,
              videoUrl: '',
            );
          }
        }

        final mediaItems = postMediaItemsFromData(post);
        for (final item in mediaItems) {
          final resolvedUrl =
              await _resolvedMediaUrlFuture(item.url) ?? item.url;
          if (resolvedUrl.isEmpty) {
            continue;
          }

          if (item.isVideo || isVideoMediaUrl(resolvedUrl)) {
            firstVideoUrl ??= resolvedUrl;
            continue;
          }

          return _NotificationMediaPreview(
            thumbnailUrl: resolvedUrl,
            videoUrl: '',
          );
        }

        final fallbackCandidates = <String>[
          (post['imageUrl'] as String? ?? '').trim(),
          (post['mediaUrl'] as String? ?? '').trim(),
          (post['postImageUrl'] as String? ?? '').trim(),
          _postImageUrl(data),
        ];

        for (final candidate in fallbackCandidates) {
          final resolved = await _resolvedMediaUrlFuture(candidate) ?? candidate;
          if (resolved.isEmpty) {
            continue;
          }

          if (!isVideoMediaUrl(resolved)) {
            return _NotificationMediaPreview(
              thumbnailUrl: resolved,
              videoUrl: '',
            );
          }

          firstVideoUrl ??= resolved;
        }

        if (firstVideoUrl != null && firstVideoUrl.isNotEmpty) {
          return _NotificationMediaPreview(
            thumbnailUrl: '',
            videoUrl: firstVideoUrl,
          );
        }

        return const _NotificationMediaPreview(
          thumbnailUrl: '',
          videoUrl: '',
        );
      },
    );
  }

  Future<void> _openPostNotification(
    BuildContext context,
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
    Map<String, dynamic> data, {
    String initialCommentId = '',
  }) async {
    final postId = _postId(data);
    final post = await _fetchPost(postId);
    if (!context.mounted) return;
    if (post == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('הפוסט כבר לא זמין.')),
      );
      return;
    }

    await _notificationService.markNotificationAsRead(notificationId: doc.id);
    if (!context.mounted) return;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PostDetailView(
          posts: [post],
          initialIndex: 0,
          initialCommentId: initialCommentId,
        ),
      ),
    );
  }

  Future<void> _openUserProfile(
    BuildContext context,
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
    Map<String, dynamic> data,
  ) async {
    final uid = _actorUid(data);
    if (uid.isEmpty) return;

    await _notificationService.markNotificationAsRead(notificationId: doc.id);
    if (!context.mounted) return;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => UserProfileScreen(uid: uid, currentBottomIndex: 0),
      ),
    );
  }

  Future<void> _openGroup(
    BuildContext context,
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
    Map<String, dynamic> data,
  ) async {
    final groupId = _groupId(data);
    if (groupId.isEmpty) return;

    await _notificationService.markNotificationAsRead(notificationId: doc.id);
    if (!context.mounted) return;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => GroupDetailsScreen(isAdmin: false, groupId: groupId),
      ),
    );
  }

  Future<void> _openNotification(
    BuildContext context,
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
    Map<String, dynamic> data,
  ) async {
    final type = (data['type'] as String? ?? '').trim();

    switch (type) {
      case NotificationTypes.postLike:
      case NotificationTypes.postSave:
        await _openPostNotification(context, doc, data);
        return;
      case NotificationTypes.postComment:
        await _openPostNotification(
          context,
          doc,
          data,
          initialCommentId: _commentId(data),
        );
        return;
      case NotificationTypes.commentReply:
        await _openPostNotification(
          context,
          doc,
          data,
          initialCommentId: _commentId(data),
        );
        return;
      case NotificationTypes.newFollower:
      case NotificationTypes.newFriend:
        await _openUserProfile(context, doc, data);
        return;
      case NotificationTypes.weeklyChallengeUpdated:
        await _notificationService.markNotificationAsRead(
            notificationId: doc.id);
        if (!context.mounted) return;
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const StarsScreen()),
        );
        return;
      case NotificationTypes.weeklyStars:
        await _notificationService.markNotificationAsRead(
            notificationId: doc.id);
        if (!context.mounted) return;
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => StarsScreen(initialPostId: _postId(data)),
          ),
        );
        return;
      case NotificationTypes.popJoin:
      case NotificationTypes.addedToGroup:
      case NotificationTypes.groupJoin:
        await _openGroup(context, doc, data);
        return;
      case NotificationTypes.newMessage:
        await _openChatNotification(context, doc, data);
        return;
      case NotificationTypes.dailyChallengeUpdated:
        await _notificationService.markNotificationAsRead(
            notificationId: doc.id);
        if (!context.mounted) return;
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const StarsScreen()),
        );
        return;
      case NotificationTypes.spontaneousReminder:
      case NotificationTypes.spontaneousTimeWarning:
        await _notificationService.markNotificationAsRead(
            notificationId: doc.id);
        if (!context.mounted) return;
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => const StarsScreen(openSpontaneousModalOnStart: true),
          ),
        );
        return;
      default:
        await _notificationService.markNotificationAsRead(
            notificationId: doc.id);
        return;
    }
  }

  Future<void> _openChatNotification(
    BuildContext context,
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
    Map<String, dynamic> data,
  ) async {
    final chatId = (data['chatId'] as String? ?? '').trim();
    await _notificationService.markNotificationAsRead(notificationId: doc.id);
    if (!context.mounted) return;

    if (chatId.isEmpty) {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const ChatsScreen()),
      );
      return;
    }

    final chatSnap =
        await FirebaseFirestore.instance.collection('chats').doc(chatId).get();
    if (!context.mounted) return;
    final chatData = chatSnap.data();
    if (chatData == null) {
      Navigator.of(context).push(
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

    Navigator.of(context).push(
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

  String _titleForNotification(Map<String, dynamic> data) {
    final type = (data['type'] as String? ?? '').trim();
    switch (type) {
      case NotificationTypes.postLike:
        return (data['title'] as String? ?? '').trim().isNotEmpty
            ? (data['title'] as String).trim()
            : 'לייק חדש על הפוסט שלך';
      case NotificationTypes.postSave:
        return '${_actorName(data)} שמר את הפוסט שלך';
      case NotificationTypes.postComment:
        return (data['title'] as String? ?? '').trim();
      case NotificationTypes.commentReply:
        return (data['title'] as String? ?? '').trim();
      case NotificationTypes.weeklyChallengeUpdated:
        return 'האתגר השבועי התעדכן';
      case NotificationTypes.dailyChallengeUpdated:
        return 'המשימה היומית התעדכנה';
      case NotificationTypes.weeklyStars:
        return 'הפוסט שלך נכנס לכוכבי השבוע';
      case NotificationTypes.newFollower:
        return 'עוקב חדש';
      case NotificationTypes.newFriend:
        return 'חבר חדש';
      case NotificationTypes.popJoin:
        return 'מישהו הצטרף דרך הפופ';
      case NotificationTypes.groupJoin:
        return 'מישהו הצטרף לקבוצה שלך';
      case NotificationTypes.addedToGroup:
        return 'הוסיפו אותך לקבוצה';
      case NotificationTypes.newMessage:
        return 'הודעה חדשה';
      case NotificationTypes.spontaneousReminder:
        return 'משימה ספונטנית מחכה לך';
      case NotificationTypes.spontaneousTimeWarning:
        return 'תזכורת למשימה הספונטנית';
      default:
        return (data['title'] as String? ?? '').trim().isNotEmpty
            ? (data['title'] as String).trim()
            : 'עדכון חדש';
    }
  }

  String _subtitleForNotification(Map<String, dynamic> data) {
    final type = (data['type'] as String? ?? '').trim();
    final body = (data['body'] as String? ?? '').trim();

    switch (type) {
      case NotificationTypes.postLike:
        return body.isNotEmpty ? body : 'יש עדכון לייקים חדש על הפוסט שלך';
      case NotificationTypes.postSave:
        return '';
      case NotificationTypes.postComment:
        return body.isNotEmpty ? body : '${_actorName(data)} הגיב על הפוסט שלך';
      case NotificationTypes.commentReply:
        return body.isNotEmpty ? body : '${_actorName(data)} הגיב על תגובה שלך';
      case NotificationTypes.weeklyChallengeUpdated:
      case NotificationTypes.dailyChallengeUpdated:
      case NotificationTypes.weeklyStars:
      case NotificationTypes.newFollower:
      case NotificationTypes.newFriend:
      case NotificationTypes.spontaneousReminder:
      case NotificationTypes.spontaneousTimeWarning:
        return body;
      case NotificationTypes.popJoin:
        return body.isNotEmpty ? body : 'הצטרפות דרך פופ';
      case NotificationTypes.groupJoin:
        return body.isNotEmpty ? body : 'הצטרפות לקבוצה';
      case NotificationTypes.addedToGroup:
        return body.isNotEmpty ? body : 'הוספה לקבוצה רגילה';
      case NotificationTypes.newMessage:
        return body.isNotEmpty ? body : 'יש לך הודעה חדשה';
      default:
        return body;
    }
  }

  IconData _iconForNotification(Map<String, dynamic> data) {
    final type = (data['type'] as String? ?? '').trim();
    switch (type) {
      case NotificationTypes.postLike:
        return Icons.favorite_rounded;
      case NotificationTypes.postSave:
        return Icons.bookmark_rounded;
      case NotificationTypes.postComment:
        return Icons.mode_comment_rounded;
      case NotificationTypes.commentReply:
        return Icons.reply_rounded;
      case NotificationTypes.weeklyChallengeUpdated:
        return Icons.bolt_rounded;
      case NotificationTypes.dailyChallengeUpdated:
        return Icons.today_rounded;
      case NotificationTypes.weeklyStars:
        return Icons.star_rounded;
      case NotificationTypes.newFollower:
        return Icons.person_add_alt_rounded;
      case NotificationTypes.newFriend:
        return Icons.group_rounded;
      case NotificationTypes.popJoin:
        return Icons.groups_rounded;
      case NotificationTypes.groupJoin:
        return Icons.group_rounded;
      case NotificationTypes.addedToGroup:
        return Icons.group_add_rounded;
      case NotificationTypes.newMessage:
        return Icons.chat_bubble_rounded;
      case NotificationTypes.spontaneousReminder:
      case NotificationTypes.spontaneousTimeWarning:
        return Icons.flash_on_rounded;
      default:
        return Icons.notifications_rounded;
    }
  }

  Widget _buildNotificationMediaThumbnail(
    BuildContext context,
    Map<String, dynamic> data,
  ) {
    final isLight = Theme.of(context).brightness == Brightness.light;

    return FutureBuilder<_NotificationMediaPreview>(
      future: _notificationMediaPreviewFuture(data),
      builder: (context, snapshot) {
        final preview = snapshot.data ??
            const _NotificationMediaPreview(thumbnailUrl: '', videoUrl: '');

        if (preview.hasThumbnail) {
          return Image.network(
            preview.thumbnailUrl,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) {
              if (preview.hasVideo) {
                return Container(
                  color: isLight ? const Color(0xFFEAF2FF) : const Color(0xFF1A2230),
                  alignment: Alignment.center,
                  child: const Icon(
                    Icons.play_circle_fill_rounded,
                    color: Colors.white,
                    size: 26,
                  ),
                );
              }

              return Container(
                color: isLight ? const Color(0xFFEAF2FF) : const Color(0xFF1A2230),
                alignment: Alignment.center,
                child: Icon(
                  _iconForNotification(data),
                  color: isLight ? const Color(0xFF5A6CFF) : Colors.white54,
                  size: 24,
                ),
              );
            },
          );
        }

        if (preview.hasVideo) {
          return FutureBuilder<Uint8List?>(
            future: _videoPreviewFutureByUrl.putIfAbsent(
              preview.videoUrl,
              () => buildVideoPreviewBytesFromSource(preview.videoUrl),
            ),
            builder: (context, bytesSnapshot) {
              final bytes = bytesSnapshot.data;
              if (bytes != null && bytes.isNotEmpty) {
                return Image.memory(bytes, fit: BoxFit.cover);
              }

              return Container(
                color: isLight ? const Color(0xFFEAF2FF) : const Color(0xFF1A2230),
                alignment: Alignment.center,
                child: const Icon(
                  Icons.play_circle_fill_rounded,
                  color: Colors.white,
                  size: 26,
                ),
              );
            },
          );
        }

        return Container(
          color: isLight ? const Color(0xFFEAF2FF) : const Color(0xFF1A2230),
          alignment: Alignment.center,
          child: Icon(
            _iconForNotification(data),
            color: isLight ? const Color(0xFF5A6CFF) : Colors.white54,
            size: 24,
          ),
        );
      },
    );
  }

  Widget _buildNotificationAvatarStack(
    BuildContext context,
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
    Map<String, dynamic> data,
  ) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final type = (data['type'] as String? ?? '').trim();

    if (type == NotificationTypes.postLike) {
      return FutureBuilder<List<String>>(
        future: _notificationLikeAvatarUrlsFuture(data),
        builder: (context, snapshot) {
          final urls = snapshot.data ?? const <String>[];
          if (urls.isEmpty) {
            return _singleNotificationAvatar(
              initial: '❤',
              backgroundColor: isLight ? const Color(0xFFFFEEF3) : const Color(0xFF273347),
              color: const Color(0xFFFF6D9A),
            );
          }

          if (urls.length == 1) {
            return _networkNotificationAvatar(urls.first, isLight: isLight);
          }

          return _avatarStack(urls.take(3).toList(growable: false), isLight: isLight);
        },
      );
    }

    final avatarUrl = (data['actorAvatarUrl'] as String? ?? '').trim();
    if (avatarUrl.isNotEmpty) {
      return _networkNotificationAvatar(avatarUrl, isLight: isLight);
    }

    final actorName = _actorName(data).trim();
    final fallbackInitial = actorName.isNotEmpty
        ? actorName.substring(0, 1).toUpperCase()
        : '?';
    return _singleNotificationAvatar(
      initial: fallbackInitial,
      backgroundColor: isLight ? const Color(0xFFEAF2FF) : const Color(0xFF273347),
      color: isLight ? const Color(0xFF5A6CFF) : Colors.white,
    );
  }

  Widget _networkNotificationAvatar(String url, {required bool isLight}) {
    return ClipOval(
      child: Image.network(
        url,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => Container(
          color: isLight ? const Color(0xFFEAF2FF) : const Color(0xFF273347),
          alignment: Alignment.center,
          child: const Icon(Icons.person_rounded, color: Colors.white),
        ),
      ),
    );
  }

  Widget _singleNotificationAvatar({
    required String initial,
    required Color backgroundColor,
    required Color color,
  }) {
    return Container(
      color: backgroundColor,
      alignment: Alignment.center,
      child: Text(
        initial,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w900,
          fontSize: 18,
        ),
      ),
    );
  }

  Widget _avatarStack(List<String> urls, {required bool isLight}) {
    final displayUrls =
        urls.where((url) => url.trim().isNotEmpty).toList(growable: false);
    if (displayUrls.isEmpty) {
      return _singleNotificationAvatar(
        initial: '?',
        backgroundColor: isLight ? const Color(0xFFEAF2FF) : const Color(0xFF273347),
        color: isLight ? const Color(0xFF5A6CFF) : Colors.white,
      );
    }

    return Stack(
      clipBehavior: Clip.none,
      children: [
        for (var i = 0; i < displayUrls.length; i++)
          Positioned(
            right: i * 11.0,
            top: i * 1.5,
            child: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: isLight ? Colors.white : const Color(0xFF0B1019),
                  width: 1.8,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha:  0.12),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: ClipOval(
                child: Image.network(
                  displayUrls[i],
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                    color: isLight
                        ? const Color(0xFFEAF2FF)
                        : const Color(0xFF273347),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Future<List<String>> _notificationLikeAvatarUrlsFuture(
      Map<String, dynamic> data) async {
    final result = <String>[];
    final seen = <String>{};

    void addUrl(String url) {
      final normalized = url.trim();
      if (normalized.isEmpty || !seen.add(normalized)) {
        return;
      }
      result.add(normalized);
    }

    final recentLikeActorUids =
        (data['recentLikeActorUids'] as List<dynamic>? ?? const <dynamic>[])
            .map((item) => item.toString().trim())
            .where((uid) => uid.isNotEmpty)
            .toList(growable: false);

    if (recentLikeActorUids.isNotEmpty) {
      for (final uid in recentLikeActorUids) {
        final avatarUrl = await _profileAvatarFuture(uid);
        addUrl(avatarUrl);
        if (result.length >= 3) {
          return result;
        }
      }
    }

    final post = await _cachedPostFuture(_postId(data));
    if (post != null) {
      final likes = (post['likes'] as List<dynamic>? ?? const <dynamic>[])
          .map((item) => item.toString().trim())
          .where((uid) => uid.isNotEmpty)
          .toList(growable: false);

      for (final uid in likes) {
        final avatarUrl = await _profileAvatarFuture(uid);
        addUrl(avatarUrl);
        if (result.length >= 3) {
          return result;
        }
      }
    }

    final actorAvatar = (data['actorAvatarUrl'] as String? ?? '').trim();
    addUrl(actorAvatar);
    return result;
  }

  Color _accentForNotification(Map<String, dynamic> data) {
    final type = (data['type'] as String? ?? '').trim();
    switch (type) {
      case NotificationTypes.postLike:
        return const Color(0xFFFF6D9A);
      case NotificationTypes.postSave:
        return const Color(0xFF8B9CFF);
      case NotificationTypes.postComment:
        return const Color(0xFF53C1F9);
      case NotificationTypes.commentReply:
        return const Color(0xFF9E7CFF);
      case NotificationTypes.weeklyChallengeUpdated:
        return const Color(0xFF7B79FF);
      case NotificationTypes.dailyChallengeUpdated:
        return const Color(0xFF53C1F9);
      case NotificationTypes.weeklyStars:
        return const Color(0xFFFFD166);
      case NotificationTypes.newFollower:
      case NotificationTypes.newFriend:
        return const Color(0xFF53D9FF);
      case NotificationTypes.popJoin:
      case NotificationTypes.addedToGroup:
        return const Color(0xFF7EE0B8);
      case NotificationTypes.newMessage:
        return const Color(0xFF8EDEFF);
      case NotificationTypes.spontaneousReminder:
      case NotificationTypes.spontaneousTimeWarning:
        return const Color(0xFFFFB347);
      default:
        return const Color(0xFF53C1F9);
    }
  }

  Widget _buildNotificationCard(
    BuildContext context,
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
    Map<String, dynamic> data,
  ) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final isUnread = _isUnread(data);
    final isNew = _shouldHighlightAsNew(data);
    final accent = _accentForNotification(data);
    final title = _titleForNotification(data);
    final subtitle = _subtitleForNotification(data);
    final timeLabel = _timeLabel(data['createdAt']);
    final type = (data['type'] as String? ?? '').trim();
    final likeCount = _intValue(data, const ['likeCount']);
    final dynamicNewBorder = _dynamicNewBorderColor(
      isLight: isLight,
      docId: doc.id,
      accent: accent,
    );

    return InkWell(
      borderRadius: BorderRadius.circular(24),
      onTap: () => _openNotification(context, doc, data),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          color: isLight ? Colors.white.withValues(alpha:  0.62) : null,
          gradient: isLight
              ? null
              : LinearGradient(
                  colors: isNew
                      ? [
                          const Color(0xFF18263D).withValues(alpha:  0.98),
                          const Color(0xFF261D44).withValues(alpha:  0.98),
                        ]
                      : [
                          const Color(0xFF111A2A).withValues(alpha:  0.92),
                          const Color(0xFF161D2C).withValues(alpha:  0.92),
                        ],
                  begin: Alignment.topRight,
                  end: Alignment.bottomLeft,
                ),
          border: Border.all(
            color: isNew
                ? dynamicNewBorder
                : (isLight
                    ? const Color(0xFFA9C3FF)
                    : Colors.white.withValues(alpha:  0.06)),
            width: isNew ? 1.45 : 0.9,
          ),
          boxShadow: [
            BoxShadow(
              color: isLight
                  ? const Color(0xFF53C1F9).withValues(alpha:  0.08)
                  : isNew
                      ? dynamicNewBorder.withValues(alpha:  0.22)
                      : Colors.black.withValues(alpha:  0.12),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Row(
          textDirection: TextDirection.ltr,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: SizedBox(
                width: 46,
                height: 46,
                child: _buildNotificationMediaThumbnail(context, data),
              ),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    textDirection: TextDirection.rtl,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          textAlign: TextAlign.right,
                          style: TextStyle(
                            color: isLight ? Colors.black : Colors.white,
                            fontSize: 14,
                            fontWeight:
                                isUnread ? FontWeight.w800 : FontWeight.w700,
                            height: 1.15,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (likeCount > 1 && type == NotificationTypes.postLike)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(999),
                            color: accent.withValues(alpha:  0.18),
                          ),
                          child: Text(
                            likeCount > 9 ? '9+' : likeCount.toString(),
                            style: TextStyle(
                              color: accent,
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  if (subtitle.isNotEmpty)
                    Text(
                      subtitle,
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        color: isLight
                            ? Colors.black87
                            : Colors.white.withValues(alpha:  0.72),
                        fontSize: 12,
                        fontWeight: FontWeight.w400,
                        height: 1.25,
                      ),
                    ),
                  const SizedBox(height: 6),
                  Row(
                    textDirection: TextDirection.rtl,
                    children: [
                      Text(
                        timeLabel,
                        style: TextStyle(
                          color: isLight
                              ? Colors.black54
                              : Colors.white.withValues(alpha:  0.45),
                          fontSize: 11.5,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                      const Spacer(),
                      if (type == NotificationTypes.weeklyChallengeUpdated)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(999),
                            color: const Color(0xFF53C1F9).withValues(alpha:  0.14),
                          ),
                          child: const Text(
                            'אתגר השבוע',
                            style: TextStyle(
                              color: Color(0xFF8EDEFF),
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 46,
              height: 46,
              child: _buildNotificationAvatarStack(context, doc, data),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final uid = _currentUid();
    final isLight = Theme.of(context).brightness == Brightness.light;
    final screenWidth = MediaQuery.of(context).size.width;
    final orbSizeA = (screenWidth * 0.8).clamp(220.0, 300.0);
    final orbSizeB = (screenWidth * 0.86).clamp(240.0, 320.0);

    return Directionality(
      textDirection: TextDirection.rtl,
      child: SwipeBackWrapper(
        child: Scaffold(
        backgroundColor: isLight ? Colors.white : const Color(0xFF0B1019),
        appBar: AppBar(
          backgroundColor:
              isLight ? const Color(0xFFBFD9FF) : const Color(0xFF101A2B),
          elevation: 0,
          title: Text(
            'עדכוני מערכת',
            style: TextStyle(
                color: isLight ? Colors.black : Colors.white,
                fontWeight: FontWeight.w800),
          ),
          centerTitle: true,
        ),
        body: Stack(
          children: [
            if (isLight)
              Positioned(
                top: -120,
                right: -90,
                child: IgnorePointer(
                  child: Container(
                    width: orbSizeA,
                    height: orbSizeA,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: const Color(0xFFB9A9FF).withValues(alpha:  0.12),
                    ),
                  ),
                ),
              ),
            if (isLight)
              Positioned(
                bottom: -130,
                left: -90,
                child: IgnorePointer(
                  child: Container(
                    width: orbSizeB,
                    height: orbSizeB,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: const Color(0xFF9EEBFF).withValues(alpha:  0.12),
                    ),
                  ),
                ),
              ),
            uid.isEmpty
                ? Center(
                    child: Text(
                      'יש להתחבר כדי לראות עדכוני מערכת.',
                      style: TextStyle(
                          color: isLight ? Colors.black87 : Colors.white70),
                    ),
                  )
                : StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                    stream: _notificationsStream(uid),
                    builder: (context, snapshot) {
                      if (snapshot.hasError) {
                        return Center(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 24),
                            child: Text(
                              'לא ניתן לטעון התראות כרגע.\n${snapshot.error}',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color:
                                    isLight ? Colors.black87 : Colors.white70,
                                height: 1.4,
                              ),
                            ),
                          ),
                        );
                      }

                      final docs = (snapshot.data?.docs ??
                              const <QueryDocumentSnapshot<
                                  Map<String, dynamic>>>[])
                          .where((doc) {
                        final type =
                            (doc.data()['type'] as String? ?? '').trim();
                        return type != NotificationTypes.newMessage;
                      }).toList(growable: false);
                      if (snapshot.connectionState == ConnectionState.waiting &&
                          docs.isEmpty) {
                        return const Center(child: CircularProgressIndicator());
                      }

                      if (docs.isEmpty) {
                        return Center(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 28),
                            child: Text(
                              'אין עדכונים חדשים כרגע. ברגע שמישהו יגיב, יאהב או יעקוב אחריך, הם יופיעו כאן.',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  color:
                                      isLight ? Colors.black87 : Colors.white70,
                                  height: 1.5),
                            ),
                          ),
                        );
                      }

                      return ListView.separated(
                        padding: const EdgeInsets.fromLTRB(14, 14, 14, 24),
                        itemCount: docs.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 10),
                        itemBuilder: (context, index) {
                          final doc = docs[index];
                          final data = doc.data();
                          return _buildNotificationCard(context, doc, data);
                        },
                      );
                    },
                  ),
          ],
        ),
        ),
      ),
    );
  }
}
