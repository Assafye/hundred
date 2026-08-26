import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'chats_screen.dart';
import 'chat_room_screen.dart';
import 'group_details_screen.dart';
import 'post_detail_view.dart';
import 'services/notification_service.dart';
import 'stars_screen.dart' show StarsScreen;
import 'user_profile_screen.dart';
import 'widgets/swipe_back_wrapper.dart';

class NotificationsPreviewScreen extends StatefulWidget {
  const NotificationsPreviewScreen({super.key});

  @override
  State<NotificationsPreviewScreen> createState() =>
      _NotificationsPreviewScreenState();
}

class _NotificationsPreviewScreenState
    extends State<NotificationsPreviewScreen> {
  final NotificationService _notificationService = NotificationService();
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

  Widget _buildNotificationAvatarStack(
    BuildContext context,
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
    Map<String, dynamic> data,
    Color accent,
  ) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: [
            accent.withValues(alpha: 0.9),
            const Color(0xFF9E7CFF).withValues(alpha: 0.8),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Icon(
        _iconForNotification(data),
        color: Colors.white,
        size: 20,
      ),
    );
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

  String _actorAvatarUrl(Map<String, dynamic> data) {
    return (data['actorAvatarUrl'] as String? ?? '').trim();
  }

  Widget _buildAvatarBadge({
    required String avatarUrl,
    required double size,
    required Alignment alignment,
  }) {
    if (avatarUrl.isEmpty) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: const Color(0xFFBFD9FF),
          border: Border.all(color: Colors.white, width: 1.5),
        ),
        child: const Icon(Icons.person_rounded, size: 14, color: Colors.white),
      );
    }

    return ClipOval(
      child: SizedBox(
        width: size,
        height: size,
        child: Image.network(
          avatarUrl,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => Container(
            width: size,
            height: size,
            color: const Color(0xFFBFD9FF),
            child: const Icon(Icons.person_rounded, size: 14, color: Colors.white),
          ),
        ),
      ),
    );
  }

  Widget _buildPostLikeNotificationCard(
    BuildContext context,
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
    Map<String, dynamic> data,
  ) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final isUnread = _isUnread(data);
    final isNew = _shouldHighlightAsNew(data);
    final accent = _accentForNotification(data);
    final actorName = _actorName(data);
    final likeCount = _intValue(data, const ['likeCount']);
    final postImageUrl = (data['postImageUrl'] as String? ?? '').trim();
    final actorAvatarUrl = _actorAvatarUrl(data);
    final dynamicNewBorder = _dynamicNewBorderColor(
      isLight: isLight,
      docId: doc.id,
      accent: accent,
    );

    final avatarStack = <Widget>[];
    final avatarUrls = <String>[];
    if (actorAvatarUrl.isNotEmpty) {
      avatarUrls.add(actorAvatarUrl);
    }
    for (final avatar in avatarUrls) {
      avatarStack.add(
        Positioned(
          right: avatarStack.length * 12.0,
          child: _buildAvatarBadge(
            avatarUrl: avatar,
            size: 22,
            alignment: Alignment.centerRight,
          ),
        ),
      );
    }

    final stackWidth = avatarUrls.isEmpty ? 0.0 : avatarUrls.length * 12.0 + 22.0;

    return InkWell(
      borderRadius: BorderRadius.circular(24),
      onTap: () => _openNotification(context, doc, data),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          gradient: isLight
              ? null
              : LinearGradient(
                  colors: isNew
                      ? [
                          const Color(0xFF18263D).withValues(alpha: 0.98),
                          const Color(0xFF261D44).withValues(alpha: 0.98),
                        ]
                      : [
                          const Color(0xFF111A2A).withValues(alpha: 0.92),
                          const Color(0xFF161D2C).withValues(alpha: 0.92),
                        ],
                  begin: Alignment.topRight,
                  end: Alignment.bottomLeft,
                ),
          color: isLight ? Colors.white.withValues(alpha: 0.62) : null,
          border: Border.all(
            color: isNew
                ? dynamicNewBorder
                : (isLight
                    ? const Color(0xFFA9C3FF)
                    : Colors.white.withValues(alpha: 0.06)),
            width: isNew ? 1.45 : 0.9,
          ),
          boxShadow: [
            BoxShadow(
              color: isLight
                  ? const Color(0xFF53C1F9).withValues(alpha: 0.08)
                  : isNew
                      ? dynamicNewBorder.withValues(alpha: 0.22)
                      : Colors.black.withValues(alpha: 0.12),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Row(
          textDirection: TextDirection.rtl,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(
              width: 64,
              height: 64,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: postImageUrl.isNotEmpty
                    ? Image.network(
                        postImageUrl,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(
                          color: const Color(0xFFBFD9FF),
                          child: const Icon(Icons.image_rounded, color: Colors.white),
                        ),
                      )
                    : Container(
                        color: const Color(0xFFE9EBFF),
                        child: const Icon(Icons.image_rounded, color: Color(0xFF7C7CEF)),
                      ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    likeCount > 1 ? '$actorName +${likeCount - 1}' : actorName,
                    textAlign: TextAlign.right,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isLight ? Colors.black : Colors.white,
                      fontSize: 15,
                      fontWeight: isUnread ? FontWeight.w800 : FontWeight.w700,
                      height: 1.2,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    likeCount > 1
                        ? 'יש לך עכשיו $likeCount לייקים על הפוסט'
                        : 'עשה לך לייק על הפוסט',
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      color: isLight ? Colors.black87 : Colors.white70,
                      fontSize: 12.5,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    textDirection: TextDirection.rtl,
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      SizedBox(
                        width: stackWidth,
                        height: 22,
                        child: Stack(
                          children: avatarStack,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: accent.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(999),
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
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNotificationCard(
    BuildContext context,
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
    Map<String, dynamic> data,
  ) {
    final type = (data['type'] as String? ?? '').trim();
    if (type == NotificationTypes.postLike) {
      return _buildPostLikeNotificationCard(context, doc, data);
    }

    final isLight = Theme.of(context).brightness == Brightness.light;
    final isUnread = _isUnread(data);
    final isNew = _shouldHighlightAsNew(data);
    final accent = _accentForNotification(data);
    final title = _titleForNotification(data);
    final subtitle = _subtitleForNotification(data);
    final timeLabel = _timeLabel(data['createdAt']);
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
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          color: isLight ? Colors.white.withValues(alpha: 0.62) : null,
          gradient: isLight
              ? null
              : LinearGradient(
                  colors: isNew
                      ? [
                          const Color(0xFF18263D).withValues(alpha: 0.98),
                          const Color(0xFF261D44).withValues(alpha: 0.98),
                        ]
                      : [
                          const Color(0xFF111A2A).withValues(alpha: 0.92),
                          const Color(0xFF161D2C).withValues(alpha: 0.92),
                        ],
                  begin: Alignment.topRight,
                  end: Alignment.bottomLeft,
                ),
          border: Border.all(
            color: isNew
                ? dynamicNewBorder
                : (isLight
                    ? const Color(0xFFA9C3FF)
                    : Colors.white.withValues(alpha: 0.06)),
            width: isNew ? 1.45 : 0.9,
          ),
          boxShadow: [
            BoxShadow(
              color: isLight
                  ? const Color(0xFF53C1F9).withValues(alpha: 0.08)
                  : isNew
                      ? dynamicNewBorder.withValues(alpha: 0.22)
                      : Colors.black.withValues(alpha: 0.12),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Row(
          textDirection: TextDirection.rtl,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
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
                            fontSize: 16,
                            fontWeight:
                                isUnread ? FontWeight.w800 : FontWeight.w700,
                            height: 1.18,
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
                            color: accent.withValues(alpha: 0.18),
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
                  const SizedBox(height: 4),
                  if (subtitle.isNotEmpty)
                    Text(
                      subtitle,
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        color: isLight
                            ? Colors.black87
                            : Colors.white.withValues(alpha: 0.72),
                        fontSize: 13,
                        fontWeight: FontWeight.w400,
                        height: 1.3,
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
                              : Colors.white.withValues(alpha: 0.45),
                          fontSize: 11.5,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                      const Spacer(),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            _buildNotificationAvatarStack(context, doc, data, accent),
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
