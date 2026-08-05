import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../models/public_user_profile.dart';
import '../services/firestore_rule_feedback.dart';
import '../services/post_service.dart';
import '../services/public_user_profile_service.dart';
import '../user_profile_screen.dart';

class PostCommentsSheet extends StatefulWidget {
  final String postId;
  final String postAuthorId;
  final String initialCommentId;
  final VoidCallback? onCommentSubmitted;

  const PostCommentsSheet({
    super.key,
    required this.postId,
    required this.postAuthorId,
    this.initialCommentId = '',
    this.onCommentSubmitted,
  });

  @override
  State<PostCommentsSheet> createState() => _PostCommentsSheetState();
}

class _PostCommentsSheetState extends State<PostCommentsSheet> {
  final TextEditingController _commentController = TextEditingController();
  final FocusNode _commentFocusNode = FocusNode();
  final PostService _postService = PostService();
  final PublicUserProfileService _profileService = PublicUserProfileService();
  final Map<String, Future<PublicUserProfile?>> _profileFutureByUid =
      <String, Future<PublicUserProfile?>>{};
  final Set<String> _expandedCommentIds = <String>{};
  final Set<String> _deletingCommentIds = <String>{};

  String _replyToCommentId = '';
  String _replyToHandle = '';
  bool _isSubmitting = false;
  bool _initialCommentApplied = false;

  bool _isLightMode(BuildContext context) {
    return Theme.of(context).brightness == Brightness.light;
  }

  void _showCenteredLimitAlert(String message) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) {
      return;
    }

    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => Positioned.fill(
        child: IgnorePointer(
          child: Center(
            child: Container(
              constraints: const BoxConstraints(maxWidth: 320),
              margin: const EdgeInsets.symmetric(horizontal: 24),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha:  0.86),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: const Color(0xFFE25454),
                  width: 0.9,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha:  0.1),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Directionality(
                textDirection: TextDirection.rtl,
                child: Text(
                  message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.black,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    height: 1.25,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    overlay.insert(entry);
    Future<void>.delayed(const Duration(seconds: 3), () {
      entry.remove();
    });
  }

  @override
  void dispose() {
    _commentController.dispose();
    _commentFocusNode.dispose();
    super.dispose();
  }

  void _openUserProfile(String uid) {
    final normalizedUid = uid.trim();
    if (normalizedUid.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => UserProfileScreen(
          uid: normalizedUid,
          currentBottomIndex: 0,
        ),
      ),
    );
  }

  String _fallbackHandleForAuthor(String authorId) {
    final normalized = authorId.trim();
    if (normalized.isEmpty) return '@user';
    return '@${normalized.substring(0, normalized.length > 6 ? 6 : normalized.length)}';
  }

  Future<PublicUserProfile?> _profileForUid(String uid) {
    final normalized = uid.trim();
    if (normalized.isEmpty) {
      return Future<PublicUserProfile?>.value(null);
    }
    return _profileFutureByUid.putIfAbsent(
      normalized,
      () => _profileService.fetchProfile(normalized),
    );
  }

  String _timeLabel(DateTime? createdAt) {
    if (createdAt == null) return '';
    final diff = DateTime.now().difference(createdAt);
    if (diff.inMinutes < 1) return 'עכשיו';
    if (diff.inHours < 1) return 'לפני ${diff.inMinutes} דק\'';
    if (diff.inDays < 1) return 'לפני ${diff.inHours} שעות';
    return 'לפני ${diff.inDays} ימים';
  }

  DateTime? _toDateTime(dynamic raw) {
    if (raw == null) return null;
    if (raw is DateTime) return raw;
    if (raw is String) return DateTime.tryParse(raw);
    try {
      return raw.toDate() as DateTime?;
    } catch (_) {
      return null;
    }
  }

  String _commentText(Map<String, dynamic> comment) {
    return ((comment['text'] as String?) ??
            (comment['content'] as String?) ??
            '')
        .trim();
  }

  bool _isLikedByMe(Map<String, dynamic> comment) {
    final uid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
    if (uid.isEmpty) return false;
    final likesRaw = comment['likes'];
    if (likesRaw is! List) return false;
    return likesRaw.map((item) => item.toString().trim()).contains(uid);
  }

  int _likesCount(Map<String, dynamic> comment) {
    final raw = comment['likesCount'];
    if (raw is num) return raw.toInt();
    final likesRaw = comment['likes'];
    if (likesRaw is List) return likesRaw.length;
    return 0;
  }

  int _replyCount(Map<String, dynamic> comment) {
    final raw = comment['replyCount'];
    if (raw is num) return raw.toInt();
    return 0;
  }

  Future<void> _applyInitialCommentReplyTarget(
    Map<String, dynamic> targetComment,
    String normalizedInitialCommentId,
  ) async {
    final targetAuthorId = (targetComment['authorId'] as String? ?? '').trim();
    final targetProfile = await _profileForUid(targetAuthorId);
    if (!mounted || _initialCommentApplied) return;

    setState(() {
      _replyToCommentId = normalizedInitialCommentId;
      _replyToHandle =
          targetProfile?.handle ?? _fallbackHandleForAuthor(targetAuthorId);
      _expandedCommentIds.add(normalizedInitialCommentId);
      _initialCommentApplied = true;
    });
    _commentFocusNode.requestFocus();
  }

  Future<void> _submitComment() async {
    final text = _commentController.text.trim();
    if (text.isEmpty || _isSubmitting) return;

    if (kDebugMode) {
      debugPrint(
        '[COMMENT_UI] submit start postId=${widget.postId} parentId=${_replyToCommentId.isEmpty ? '-' : _replyToCommentId} textLength=${text.length}',
      );
    }

    setState(() => _isSubmitting = true);
    try {
      await _postService.addPostComment(
        postId: widget.postId,
        postAuthorId: widget.postAuthorId,
        text: text,
        parentCommentId: _replyToCommentId.isEmpty ? null : _replyToCommentId,
      );

      if (!mounted) return;
      _commentController.clear();
      if (kDebugMode) {
        debugPrint('[COMMENT_UI] submit success postId=${widget.postId}');
      }
      widget.onCommentSubmitted?.call();
      setState(() {
        _replyToCommentId = '';
        _replyToHandle = '';
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _commentFocusNode.requestFocus();
      });
    } catch (error, stackTrace) {
      if (kDebugMode) {
        debugPrint(
            '[COMMENT_UI] submit failed postId=${widget.postId} error=$error');
        debugPrint('[COMMENT_UI] stack=$stackTrace');
      }
      if (!mounted) return;
      if (error is PostActionLimitException) {
        _showCenteredLimitAlert(error.message);
        return;
      }
      final message = FirestoreRuleFeedback.actionMessage(
        error,
        error is FirebaseException
            ? 'פרסום תגובה נכשל (${error.code})'
            : 'פרסום תגובה נכשל. נסה שוב בעוד רגע.',
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  Future<void> _confirmAndDeleteComment(String commentId) async {
    final normalizedId = commentId.trim();
    if (normalizedId.isEmpty || _deletingCommentIds.contains(normalizedId)) {
      return;
    }

    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final isLight = _isLightMode(dialogContext);
        return Directionality(
          textDirection: TextDirection.rtl,
          child: AlertDialog(
            backgroundColor:
                isLight ? const Color(0xFFF8FBFF) : const Color(0xFF121C2C),
            title: Text(
              'מחיקת תגובה',
              style: TextStyle(
                  color: isLight ? const Color(0xFF1E2A45) : Colors.white),
            ),
            content: Text(
              'האם אתה בטוח שברצונך למחוק את התגובה?',
              style: TextStyle(
                color: isLight ? const Color(0xFF5D6B87) : Colors.white70,
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('ביטול'),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF9E7CFF),
                  foregroundColor:
                      isLight ? const Color(0xFF1E2A45) : Colors.black,
                ),
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('מחק'),
              ),
            ],
          ),
        );
      },
    );

    if (shouldDelete != true) return;

    setState(() {
      _deletingCommentIds.add(normalizedId);
    });

    try {
      await _postService.deletePostComment(
        postId: widget.postId,
        postAuthorId: widget.postAuthorId,
        commentId: normalizedId,
      );
      if (!mounted) return;
      if (_replyToCommentId == normalizedId) {
        setState(() {
          _replyToCommentId = '';
          _replyToHandle = '';
        });
      }
    } catch (error) {
      if (!mounted) return;
      final message = FirestoreRuleFeedback.actionMessage(
        error,
        'מחיקת תגובה נכשלה. נסה שוב בעוד רגע.',
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    } finally {
      if (mounted) {
        setState(() {
          _deletingCommentIds.remove(normalizedId);
        });
      }
    }
  }

  Widget _buildAvatar(String imageUrl) {
    if (imageUrl.isEmpty) {
      return Container(
        width: 40,
        height: 40,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            colors: [Color(0xFF8C62FF), Color(0xFF46D3FF)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Container(
          margin: const EdgeInsets.all(1.4),
          decoration: const BoxDecoration(
            color: Color(0xFF162033),
            shape: BoxShape.circle,
          ),
          child:
              const Icon(Icons.person_rounded, color: Colors.white, size: 20),
        ),
      );
    }

    return Container(
      width: 40,
      height: 40,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: [Color(0xFF8C62FF), Color(0xFF46D3FF)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Container(
        margin: const EdgeInsets.all(1.4),
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: Color(0xFF162033),
        ),
        child: ClipOval(
          child: Image.network(
            imageUrl,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) {
              return const Icon(Icons.person_rounded,
                  color: Colors.white, size: 20);
            },
          ),
        ),
      ),
    );
  }

  Widget _buildCommentRow({
    required Map<String, dynamic> comment,
    required bool isReply,
    required List<Map<String, dynamic>> replies,
  }) {
    final isLight = _isLightMode(context);
    final authorId = (comment['authorId'] as String? ?? '').trim();
    final createdAt = _toDateTime(comment['createdAt']);
    final text = _commentText(comment);
    final commentId = (comment['id'] as String? ?? '').trim();
    final likedByMe = _isLikedByMe(comment);
    final likesCount = _likesCount(comment);
    final currentUid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
    final canDelete = currentUid.isNotEmpty &&
        (authorId == currentUid || widget.postAuthorId.trim() == currentUid);
    final isDeleting = _deletingCommentIds.contains(commentId);
    final shouldShowRepliesToggle =
        replies.isNotEmpty || _replyCount(comment) > 0;
    final isExpanded = _expandedCommentIds.contains(commentId);

    return Padding(
      padding: EdgeInsets.only(
        right: isReply ? 42 : 0,
        left: isReply ? 4 : 0,
        top: isReply ? 8 : 8,
        bottom: isReply ? 4 : 8,
      ),
      child: FutureBuilder<PublicUserProfile?>(
        future: _profileForUid(authorId),
        builder: (context, snapshot) {
          final profile = snapshot.data;
          final handle = profile?.handle ?? _fallbackHandleForAuthor(authorId);
          final imageUrl = profile?.profilePictureUrl ?? '';

          return Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 11),
                      decoration: BoxDecoration(
                        color: (isLight
                                ? const Color(0xFFF5F9FF)
                                : const Color(0xFF182336))
                            .withValues(alpha:  isLight ? 0.95 : 0.92),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                            color: (isLight
                                    ? const Color(0xFF6F7ED8)
                                    : const Color(0xFF46D3FF))
                                .withValues(alpha:  isLight ? 0.44 : 0.24)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              Text(
                                _timeLabel(createdAt),
                                style: TextStyle(
                                  color: isLight
                                      ? const Color(0xFF7684A1)
                                      : Colors.white54,
                                  fontSize: 12,
                                ),
                              ),
                              const SizedBox(width: 8),
                              GestureDetector(
                                onTap: () => _openUserProfile(authorId),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 3),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(999),
                                    gradient: LinearGradient(
                                      colors: [
                                        isLight
                                            ? const Color(0xFFE4EDFF)
                                            : const Color(0xFF2A3D63),
                                        isLight
                                            ? const Color(0xFFF3EFFF)
                                            : const Color(0xFF36295A)
                                      ],
                                      begin: Alignment.centerLeft,
                                      end: Alignment.centerRight,
                                    ),
                                  ),
                                  child: Text(
                                    handle,
                                    style: TextStyle(
                                      color: isLight
                                          ? const Color(0xFF3C4D70)
                                          : const Color(0xFFEAF4FF),
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            text,
                            textAlign: TextAlign.right,
                            style: TextStyle(
                              color: isLight
                                  ? const Color(0xFF2A3A5A)
                                  : const Color(0xFFF3F8FF),
                              fontSize: 16,
                              height: 1.35,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.start,
                            children: [
                              GestureDetector(
                                onTap: () async {
                                  if (commentId.isEmpty) return;
                                  await _postService.toggleCommentLike(
                                    postId: widget.postId,
                                    commentId: commentId,
                                  );
                                },
                                child: Row(
                                  children: [
                                    Text(
                                      likesCount.toString(),
                                      style: TextStyle(
                                        color: isLight
                                            ? const Color(0xFF5D6B87)
                                            : Colors.white70,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                    Icon(
                                      likedByMe
                                          ? Icons.favorite_rounded
                                          : Icons.favorite_border_rounded,
                                      color: likedByMe
                                          ? const Color(0xFF8C62FF)
                                          : const Color(0xFF9EDBFF),
                                      size: 18,
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 16),
                              GestureDetector(
                                onTap: () {
                                  setState(() {
                                    _replyToCommentId = commentId;
                                    _replyToHandle = handle;
                                  });
                                  _commentFocusNode.requestFocus();
                                },
                                child: const Text(
                                  'הגב',
                                  style: TextStyle(
                                    color: Color(0xFF9EDBFF),
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              if (canDelete) ...[
                                const SizedBox(width: 14),
                                GestureDetector(
                                  onTap: isDeleting
                                      ? null
                                      : () =>
                                          _confirmAndDeleteComment(commentId),
                                  child: Text(
                                    isDeleting ? 'מוחק...' : 'מחק',
                                    style: TextStyle(
                                      color: isDeleting
                                          ? Colors.white38
                                          : const Color(0xFFFF8AA6),
                                      fontSize: 13,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          if (shouldShowRepliesToggle && !isReply) ...[
                            const SizedBox(height: 8),
                            Align(
                              alignment: Alignment.centerRight,
                              child: GestureDetector(
                                onTap: () {
                                  if (commentId.isEmpty) return;
                                  setState(() {
                                    if (isExpanded) {
                                      _expandedCommentIds.remove(commentId);
                                    } else {
                                      _expandedCommentIds.add(commentId);
                                    }
                                  });
                                },
                                child: Text(
                                  isExpanded
                                      ? 'הסתר תגובות'
                                      : 'הצג תגובות נוספות (${replies.length})',
                                  textAlign: TextAlign.right,
                                  style: const TextStyle(
                                    color: Color(0xFF9EDBFF),
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  GestureDetector(
                    onTap: () => _openUserProfile(authorId),
                    child: _buildAvatar(imageUrl),
                  ),
                ],
              ),
              if (!isReply && isExpanded)
                ...replies.map(
                  (reply) => _buildCommentRow(
                    comment: reply,
                    isReply: true,
                    replies: const <Map<String, dynamic>>[],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isLight = _isLightMode(context);
    final mediaQuery = MediaQuery.of(context);
    final keyboardInset = mediaQuery.viewInsets.bottom;
    const sheetHeightFactor = 0.75;
    const composerBottomGap = 24.0;
    final bottomSpacerHeight = keyboardInset > 0 ? 0.0 : composerBottomGap;
    final composerContainerColor =
        (isLight ? const Color(0xFFF7FAFF) : const Color(0xFF121C2D))
            .withValues(alpha:  0.95);
    return SafeArea(
      top: false,
      bottom: false,
      child: Container(
        height: mediaQuery.size.height * sheetHeightFactor,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: isLight
                ? const [Color(0xFFFAFCFF), Color(0xFFEFF4FF)]
                : const [Color(0xFF0E1625), Color(0xFF151B31)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 48,
              height: 5,
              decoration: BoxDecoration(
                color: (isLight
                        ? const Color(0xFF8EA3FF)
                        : const Color(0xFF9EDBFF))
                    .withValues(alpha:  0.5),
                borderRadius: BorderRadius.circular(99),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'תגובות',
              style: TextStyle(
                color: isLight ? const Color(0xFF1E2A45) : Colors.white,
                fontSize: 19,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: StreamBuilder<List<Map<String, dynamic>>>(
                stream: _postService.watchPostComments(widget.postId),
                builder: (context, snapshot) {
                  final comments =
                      snapshot.data ?? const <Map<String, dynamic>>[];
                  final normalizedInitialCommentId =
                      widget.initialCommentId.trim();

                  if (!_initialCommentApplied &&
                      normalizedInitialCommentId.isNotEmpty) {
                    final targetComment =
                        comments.cast<Map<String, dynamic>?>().firstWhere(
                              (comment) =>
                                  ((comment?['id'] as String? ?? '').trim()) ==
                                  normalizedInitialCommentId,
                              orElse: () => null,
                            );
                    if (targetComment != null) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (!mounted || _initialCommentApplied) return;
                        _applyInitialCommentReplyTarget(
                          targetComment,
                          normalizedInitialCommentId,
                        );
                      });
                    }
                  }

                  final rootComments = comments
                      .where((comment) =>
                          ((comment['parentId'] as String?) ?? '')
                              .trim()
                              .isEmpty)
                      .toList(growable: false);

                  final Map<String, List<Map<String, dynamic>>>
                      repliesByParent = <String, List<Map<String, dynamic>>>{};
                  for (final comment in comments) {
                    final parentId =
                        ((comment['parentId'] as String?) ?? '').trim();
                    if (parentId.isEmpty) continue;
                    repliesByParent
                        .putIfAbsent(parentId, () => <Map<String, dynamic>>[])
                        .add(comment);
                  }

                  if (snapshot.connectionState == ConnectionState.waiting &&
                      comments.isEmpty) {
                    return const Center(
                      child:
                          CircularProgressIndicator(color: Color(0xFF8C62FF)),
                    );
                  }

                  if (rootComments.isEmpty) {
                    return const Center(
                      child: Text(
                        'אין תגובות עדיין, תהיו הראשונים להגיב',
                        style: TextStyle(color: Colors.white70, fontSize: 15),
                      ),
                    );
                  }

                  return ListView.builder(
                    reverse: false,
                    padding: const EdgeInsets.fromLTRB(16, 6, 16, 14),
                    itemCount: rootComments.length,
                    itemBuilder: (context, index) {
                      final comment = rootComments[index];
                      final commentId = (comment['id'] as String? ?? '').trim();
                      return _buildCommentRow(
                        comment: comment,
                        isReply: false,
                        replies: repliesByParent[commentId] ??
                            const <Map<String, dynamic>>[],
                      );
                    },
                  );
                },
              ),
            ),
            Padding(
              padding: EdgeInsets.only(bottom: keyboardInset),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
                    decoration: BoxDecoration(
                      color: composerContainerColor,
                      border: Border(
                        top: BorderSide(
                            color: (isLight
                                    ? const Color(0xFF8D9AFF)
                                    : const Color(0xFF46D3FF))
                                .withValues(alpha:  0.2)),
                      ),
                    ),
                    child: Column(
                      children: [
                        if (_replyToCommentId.isNotEmpty)
                          Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(999),
                              color: isLight
                                  ? const Color(0xFFE7EEFF)
                                  : const Color(0xFF1F2D46),
                            ),
                            child: Row(
                              children: [
                                GestureDetector(
                                  onTap: () {
                                    setState(() {
                                      _replyToCommentId = '';
                                      _replyToHandle = '';
                                    });
                                  },
                                  child: const Icon(Icons.close_rounded,
                                      color: Colors.white70, size: 18),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'תגובה ל$_replyToHandle',
                                    textAlign: TextAlign.right,
                                    style: TextStyle(
                                      color: isLight
                                          ? const Color(0xFF2A3A5A)
                                          : const Color(0xFFEAF4FF),
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _commentController,
                                focusNode: _commentFocusNode,
                                textAlign: TextAlign.right,
                                minLines: 1,
                                maxLines: 3,
                                style: TextStyle(
                                  color: isLight
                                      ? const Color(0xFF2A3A5A)
                                      : Colors.white,
                                  fontSize: 15,
                                ),
                                decoration: InputDecoration(
                                  hintText: 'כתוב תגובה...',
                                  hintStyle: TextStyle(
                                      color: isLight
                                          ? const Color(0xFF7A89A5)
                                          : Colors.white54,
                                      fontSize: 15),
                                  filled: true,
                                  fillColor: isLight
                                      ? const Color(0xFFEAF1FF)
                                      : const Color(0xFF1A2740),
                                  contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 14, vertical: 12),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(14),
                                    borderSide: BorderSide(
                                      color: const Color(0xFF46D3FF)
                                          .withValues(alpha:  0.26),
                                    ),
                                  ),
                                  enabledBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(14),
                                    borderSide: BorderSide(
                                      color: const Color(0xFF46D3FF)
                                          .withValues(alpha:  0.26),
                                    ),
                                  ),
                                  focusedBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(14),
                                    borderSide: const BorderSide(
                                        color: Color(0xFF8C62FF)),
                                  ),
                                ),
                                onSubmitted: (_) => _submitComment(),
                              ),
                            ),
                            const SizedBox(width: 10),
                            GestureDetector(
                              onTap: _isSubmitting ? null : _submitComment,
                              child: Container(
                                width: 46,
                                height: 46,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  gradient: _isSubmitting
                                      ? const LinearGradient(
                                          colors: [
                                            Color(0xFF3A4963),
                                            Color(0xFF3A4963)
                                          ],
                                        )
                                      : const LinearGradient(
                                          colors: [
                                            Color(0xFF8C62FF),
                                            Color(0xFF46D3FF)
                                          ],
                                          begin: Alignment.topLeft,
                                          end: Alignment.bottomRight,
                                        ),
                                ),
                                child: _isSubmitting
                                    ? const Padding(
                                        padding: EdgeInsets.all(11),
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: Colors.white,
                                        ),
                                      )
                                    : const Icon(Icons.send_rounded,
                                        color: Colors.white, size: 22),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  Container(
                    height: bottomSpacerHeight,
                    color: composerContainerColor,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
