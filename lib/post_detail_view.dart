import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import 'app_categories.dart';
import 'category_screen.dart';
import 'chat_room_screen.dart';
import 'models/public_user_profile.dart';
import 'post_media_utils.dart';
import 'post_edit_screen.dart';
import 'post_model.dart';
import 'services/group_service.dart';
import 'services/firestore_rule_feedback.dart';
import 'services/post_interaction_overlay_service.dart';
import 'services/post_service.dart';
import 'services/public_user_profile_service.dart';
import 'services/report_service.dart';
import 'services/share_flow_log_service.dart';
import 'services/social_service.dart';
import 'user_profile_screen.dart';
import 'widgets/post_media_viewer.dart';
import 'widgets/post_comments_sheet.dart';
import 'widgets/report_dialogs.dart';
import 'widgets/post_share_targets_sheet.dart';
import 'widgets/swipe_back_wrapper.dart';

enum _PostDetailShareMenuAction { copyLink, sendToFriend, systemShare }

class PostDetailView extends StatefulWidget {
  final List<Map<String, dynamic>> posts;
  final int initialIndex;
  final bool enableEditAction;
  final bool useDraftPublishEditAction;
  final bool disableOwnAuthorProfileTap;
  final bool showOwnPostWeeklyStarsCelebration;
  final String initialCommentId;

  const PostDetailView({
    super.key,
    required this.posts,
    required this.initialIndex,
    this.enableEditAction = false,
    this.useDraftPublishEditAction = false,
    this.disableOwnAuthorProfileTap = false,
    this.showOwnPostWeeklyStarsCelebration = false,
    this.initialCommentId = '',
  });

  @override
  State<PostDetailView> createState() => _PostDetailViewState();
}

class _PostDetailViewState extends State<PostDetailView> {
  static const bool _experimentalPostHeaderLayout = true;
  late final PageController _pageController;
  late List<Map<String, dynamic>> _posts;
  final Map<String, Future<String?>> _resolvedMediaFutureByPostKey = {};
  final PublicUserProfileService _publicUserProfileService =
      PublicUserProfileService();
  final PostService _postService = PostService();
  final SocialService _socialService = SocialService();
  final GroupService _groupService = GroupService();
  final ReportService _reportService = ReportService();
  final Map<String, PublicUserProfile?> _authorProfilesByUid =
      <String, PublicUserProfile?>{};
  final Map<String, StreamSubscription<PublicUserProfile?>>
      _authorSubscriptionsByUid =
      <String, StreamSubscription<PublicUserProfile?>>{};
  late int _currentIndex;
  final Set<String> _likeInFlightPostIds = <String>{};
  final Set<String> _saveInFlightPostIds = <String>{};
  final Set<String> _shareInFlightPostIds = <String>{};
  bool _shownWeeklyStarsOwnPostCelebration = false;
  bool _openedInitialComments = false;
  bool _isDetailViewInForeground = true;
  StreamSubscription<String>? _postOverlaySubscription;

  @override
  void initState() {
    super.initState();
    _posts = widget.posts
        .map((post) => Map<String, dynamic>.from(post))
        .toList(growable: true);
    final safeInitialIndex = widget.posts.isEmpty
        ? 0
        : widget.initialIndex.clamp(0, widget.posts.length - 1);
    _pageController = PageController(initialPage: safeInitialIndex);
    _currentIndex = safeInitialIndex;
    _postOverlaySubscription =
        PostInteractionOverlayService.changes.listen((_) {
      if (!mounted) return;
      setState(() {});
    });
    _syncAuthorSubscriptions();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _showWeeklyStarsCelebrationIfNeeded();
      _openInitialCommentsIfNeeded();
    });
  }

  Future<void> _openInitialCommentsIfNeeded() async {
    final initialCommentId = widget.initialCommentId.trim();
    if (_openedInitialComments || initialCommentId.isEmpty || _posts.isEmpty) {
      return;
    }

    _openedInitialComments = true;
    await _openCommentsForCurrentPost(
      _posts[_currentIndex],
      initialCommentId: initialCommentId,
    );
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
              constraints: BoxConstraints(
                maxWidth: (MediaQuery.of(context).size.width * 0.9)
                    .clamp(240.0, 320.0),
              ),
              margin: const EdgeInsets.symmetric(horizontal: 24),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFFE57A1F), Color(0xFFD46200)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(18),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x33000000),
                    blurRadius: 18,
                    offset: Offset(0, 8),
                  ),
                ],
              ),
              child: Directionality(
                textDirection: TextDirection.rtl,
                child: Text(
                  message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                    decoration: TextDecoration.none,
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

  String _currentUserId() {
    return (FirebaseAuth.instance.currentUser?.uid ?? '').trim();
  }

  bool _isOwnedByCurrentUser(Map<String, dynamic> post) {
    final currentUid = _currentUserId();
    if (currentUid.isEmpty) {
      return false;
    }
    return _postAuthorId(post) == currentUid;
  }

  void _showWeeklyStarsCelebrationIfNeeded() {
    if (!mounted ||
        _shownWeeklyStarsOwnPostCelebration ||
        !widget.showOwnPostWeeklyStarsCelebration ||
        _posts.isEmpty ||
        _currentIndex < 0 ||
        _currentIndex >= _posts.length) {
      return;
    }

    final currentPost = _posts[_currentIndex];
    if (!_isOwnedByCurrentUser(currentPost)) {
      return;
    }

    _shownWeeklyStarsOwnPostCelebration = true;
    _showWeeklyStarsCelebrationOverlay();
  }

  void _showWeeklyStarsCelebrationOverlay() {
    if (!mounted) {
      return;
    }

    var dismissed = false;
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'weekly-stars-celebration',
      barrierColor: Colors.black45,
      transitionDuration: const Duration(milliseconds: 320),
      pageBuilder: (dialogContext, animation, secondaryAnimation) {
        Future<void>.delayed(const Duration(seconds: 3), () {
          if (!mounted || !dialogContext.mounted || dismissed) {
            return;
          }
          dismissed = true;
          Navigator.of(dialogContext).pop();
        });

        return SafeArea(
          child: Center(
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: (MediaQuery.of(dialogContext).size.width * 0.88)
                      .clamp(240.0, 320.0),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(24),
                    gradient: const LinearGradient(
                      colors: [Color(0xFF53C1F9), Color(0xFF9E7CFF)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF53C1F9).withValues(alpha: 0.36),
                        blurRadius: 22,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 16),
                    decoration: BoxDecoration(
                      color: const Color(0xFF141E31),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.celebration_rounded,
                          color: Color(0xFFFFD166),
                          size: 36,
                        ),
                        SizedBox(height: 10),
                        Text(
                          'הפופ שלך בכוכבי השבוע!!',
                          textDirection: TextDirection.rtl,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 21,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        SizedBox(height: 8),
                        Text(
                          'you are a star',
                          textDirection: TextDirection.rtl,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Color(0xFFD4E9FF),
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const Positioned(
                  top: -18,
                  left: 20,
                  child: Icon(Icons.auto_awesome,
                      color: Color(0xFFFFD166), size: 24),
                ),
                const Positioned(
                  top: -12,
                  right: 24,
                  child: Icon(Icons.stars_rounded,
                      color: Color(0xFF9EDBFF), size: 22),
                ),
                const Positioned(
                  bottom: -12,
                  left: 34,
                  child: Icon(Icons.circle, color: Color(0xFF53C1F9), size: 10),
                ),
                const Positioned(
                  bottom: -14,
                  right: 34,
                  child: Icon(Icons.circle, color: Color(0xFF9E7CFF), size: 10),
                ),
              ],
            ),
          ),
        );
      },
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutBack,
          reverseCurve: Curves.easeIn,
        );

        return FadeTransition(
          opacity: animation,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.88, end: 1.0).animate(curved),
            child: child,
          ),
        );
      },
    ).then((_) {
      dismissed = true;
    });
  }

  @override
  void didUpdateWidget(covariant PostDetailView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.posts != widget.posts) {
      _posts = widget.posts
          .map((post) => Map<String, dynamic>.from(post))
          .toList(growable: true);
      if (_posts.isNotEmpty && _currentIndex >= _posts.length) {
        _currentIndex = _posts.length - 1;
      }
      _syncAuthorSubscriptions();
    }
  }

  @override
  void dispose() {
    _postOverlaySubscription?.cancel();
    for (final subscription in _authorSubscriptionsByUid.values) {
      subscription.cancel();
    }
    _pageController.dispose();
    super.dispose();
  }

  void _syncAuthorSubscriptions() {
    final desiredUids = _posts
        .map((post) =>
            (post['authorId'] as String? ?? post['uid'] as String? ?? '')
                .trim())
        .where((uid) => uid.isNotEmpty)
        .toSet();

    final staleUids = _authorSubscriptionsByUid.keys
        .where((uid) => !desiredUids.contains(uid))
        .toList(growable: false);

    for (final uid in staleUids) {
      _authorSubscriptionsByUid.remove(uid)?.cancel();
      _authorProfilesByUid.remove(uid);
    }

    for (final uid in desiredUids) {
      _authorSubscriptionsByUid.putIfAbsent(
        uid,
        () => _publicUserProfileService.streamProfile(uid).listen((profile) {
          if (!mounted) {
            return;
          }
          setState(() {
            _authorProfilesByUid[uid] = profile;
          });
        }),
      );
    }
  }

  String _rawMediaField(Map<String, dynamic> data) {
    final mediaUrl = (data['mediaUrl'] as String? ?? '').trim();
    if (mediaUrl.isNotEmpty) return mediaUrl;

    final imageUrl = (data['imageUrl'] as String? ?? '').trim();
    if (imageUrl.isNotEmpty) return imageUrl;

    final mediaUrls = (data['mediaUrls'] as List<dynamic>? ?? const []);
    if (mediaUrls.isNotEmpty) {
      final first = mediaUrls.first.toString().trim();
      if (first.isNotEmpty) return first;
    }

    return '';
  }

  Future<String?> _resolveMediaUrl(Map<String, dynamic> data) async {
    final postId =
        (data['postId'] as String? ?? data['id'] as String? ?? 'unknown')
            .trim();
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      debugPrint(
          '[PostDetailView][$postId] No authenticated user for storage read.');
      return null;
    }

    final rawMedia = _rawMediaField(data);
    final storagePath = (data['storagePath'] as String? ?? '').trim();

    if (rawMedia.isNotEmpty) {
      if (rawMedia.startsWith('http://') || rawMedia.startsWith('https://')) {
        return rawMedia;
      }

      try {
        if (rawMedia.startsWith('gs://')) {
          return await FirebaseStorage.instance
              .refFromURL(rawMedia)
              .getDownloadURL();
        }
        return await FirebaseStorage.instance.ref(rawMedia).getDownloadURL();
      } catch (_) {
        // Try storagePath fallback below.
      }
    }

    if (storagePath.isEmpty) {
      return null;
    }

    try {
      return await FirebaseStorage.instance.ref(storagePath).getDownloadURL();
    } catch (e) {
      debugPrint('[PostDetailView][$postId] Failed to resolve media URL: $e');
      return null;
    }
  }

  // ignore: unused_element
  Future<String?> _mediaFutureForPost(Map<String, dynamic> data) {
    final postKey =
        (data['postId'] as String? ?? data['id'] as String? ?? '').trim();
    final rawMedia = _rawMediaField(data);
    final storagePath = (data['storagePath'] as String? ?? '').trim();
    final cacheKey = [postKey, rawMedia, storagePath].join('|');

    return _resolvedMediaFutureByPostKey.putIfAbsent(
      cacheKey,
      () => _resolveMediaUrl(data),
    );
  }

  int _countFromData(Map<String, dynamic> post, String key, {String? listKey}) {
    final raw = post[key];
    if (raw is num) {
      return raw.toInt();
    }
    if (raw is String) {
      return int.tryParse(raw) ?? 0;
    }
    if (listKey != null) {
      final listRaw = post[listKey];
      if (listRaw is List) {
        return listRaw.length;
      }
    }
    return 0;
  }

  int _countFromAny(Map<String, dynamic> post, List<String> keys,
      {String? listKey}) {
    final postId = _postId(post);
    String metric = '';
    if (keys.any((key) => key.toLowerCase().contains('likes'))) {
      metric = 'likes';
    } else if (keys.any((key) => key.toLowerCase().contains('comments'))) {
      metric = 'comments';
    } else if (keys.any((key) => key.toLowerCase().contains('shares'))) {
      metric = 'shares';
    } else if (keys.any((key) => key.toLowerCase().contains('saves'))) {
      metric = 'saves';
    }

    for (final key in keys) {
      final value = _countFromData(post, key, listKey: listKey);
      if (value > 0) {
        if (metric == 'comments') {
          return value.clamp(0, 1 << 30).toInt();
        }
        final delta = metric.isEmpty
            ? 0
            : PostInteractionOverlayService.deltaFor(
                postId: postId,
                metric: metric,
              );
        return (value + delta).clamp(0, 1 << 30).toInt();
      }
    }
    if (metric == 'comments') {
      return 0;
    }
    final delta = metric.isEmpty
        ? 0
        : PostInteractionOverlayService.deltaFor(
            postId: postId,
            metric: metric,
          );
    return delta.clamp(0, 1 << 30).toInt();
  }

  String _formatCount(int value) {
    if (value >= 1000000) {
      final short = value / 1000000;
      final formatted =
          short >= 100 ? short.toStringAsFixed(0) : short.toStringAsFixed(1);
      return '${formatted.replaceAll(RegExp(r'\\.0$'), '')}M';
    }
    if (value >= 10000) {
      final short = value / 1000;
      final formatted =
          short >= 100 ? short.toStringAsFixed(0) : short.toStringAsFixed(1);
      return '${formatted.replaceAll(RegExp(r'\\.0$'), '')}K';
    }
    return value.toString();
  }

  IconData _categoryIcon(String category) {
    return categoryIconFor(category);
  }

  String _derivedTitle(Map<String, dynamic> post) {
    final title = (post['title'] as String? ?? '').trim();
    if (title.isNotEmpty) {
      return title;
    }

    final fallbackText = ((post['caption'] as String?) ??
            (post['description'] as String?) ??
            (post['content'] as String?) ??
            '')
        .trim();
    if (fallbackText.isEmpty) {
      return '';
    }

    return fallbackText.length > 42
        ? '${fallbackText.substring(0, 42).trim()}...'
        : fallbackText;
  }

  // ignore: unused_element
  String _topicText(Map<String, dynamic> post) {
    final topic = (post['topic'] as String? ?? '').trim();
    if (topic.isNotEmpty) return topic;

    final category = (post['category'] as String? ?? '').trim();
    if (category.isNotEmpty) return category;

    final subCategory = (post['subCategory'] as String? ?? '').trim();
    if (subCategory.isNotEmpty) return subCategory;

    return '';
  }

  String _locationText(Map<String, dynamic> post) {
    String textFrom(String key) => (post[key] as String? ?? '').trim();

    final direct = <String>[
      textFrom('location'),
      textFrom('locationName'),
      textFrom('postLocation'),
      textFrom('region'),
      textFrom('meetingRegion'),
      textFrom('city'),
      textFrom('address'),
    ].firstWhere((value) => value.isNotEmpty, orElse: () => '');
    if (direct.isNotEmpty) return direct;

    final nestedLocation = post['location'];
    if (nestedLocation is Map<String, dynamic>) {
      final city = (nestedLocation['city'] as String? ?? '').trim();
      final address = (nestedLocation['address'] as String? ?? '').trim();
      if (city.isNotEmpty && address.isNotEmpty) {
        return '$city, $address';
      }
      if (city.isNotEmpty) return city;
      if (address.isNotEmpty) return address;
    }

    if (nestedLocation is Map) {
      final city = (nestedLocation['city'] as String? ?? '').trim();
      final address = (nestedLocation['address'] as String? ?? '').trim();
      if (city.isNotEmpty && address.isNotEmpty) {
        return '$city, $address';
      }
      if (city.isNotEmpty) return city;
      if (address.isNotEmpty) return address;
    }

    return '';
  }

  DateTime? _createdAt(Map<String, dynamic> post) {
    final raw = post['createdAt'] ??
        post['created_at'] ??
        post['timestamp'] ??
        post['date'];

    if (raw is Timestamp) return raw.toDate();
    if (raw is DateTime) return raw;
    if (raw is int) {
      // Accept both seconds and milliseconds epoch values.
      final isMillis = raw > 100000000000;
      return DateTime.fromMillisecondsSinceEpoch(isMillis ? raw : raw * 1000);
    }
    if (raw is String && raw.trim().isNotEmpty) {
      return DateTime.tryParse(raw.trim());
    }
    return null;
  }

  String _formatPostTimestamp(DateTime? createdAt) {
    if (createdAt == null) return '';

    final now = DateTime.now();
    final difference = now.difference(createdAt);
    if (difference.inMinutes < 1) return 'עכשיו';
    if (difference.inHours < 1) return 'לפני ${difference.inMinutes} דקות';
    if (difference.inDays < 1) return 'לפני ${difference.inHours} שעות';
    if (difference.inDays < 7) return 'לפני ${difference.inDays} ימים';

    final dd = createdAt.day.toString().padLeft(2, '0');
    final mm = createdAt.month.toString().padLeft(2, '0');
    final yyyy = createdAt.year.toString();
    final hh = createdAt.hour.toString().padLeft(2, '0');
    final min = createdAt.minute.toString().padLeft(2, '0');
    return '$dd.$mm.$yyyy • $hh:$min';
  }

  int _scoreAwarded(Map<String, dynamic> post) {
    final raw = post['scoreAwarded'];
    if (raw is num) return raw.toInt();
    return int.tryParse(raw?.toString() ?? '') ?? 0;
  }

  String _postAudience(Map<String, dynamic> post) {
    return (post['audience'] as String? ?? 'public').trim().toLowerCase();
  }

  int _postContributionScore({
    required int scoreAwarded,
    required int likesCount,
    required int commentsCount,
    required int sharesCount,
    required int savesCount,
  }) {
    return scoreAwarded +
        likesCount +
        (commentsCount * 2) +
        (sharesCount * 3) +
        savesCount;
  }

  List<String> _participantUids(Map<String, dynamic> post,
      {bool includeAuthor = false}) {
    final authorId = _postAuthorId(post);
    final rawMembers = (post['members'] as List<dynamic>? ??
        post['participants'] as List<dynamic>? ??
        const <dynamic>[]);

    final unique = <String>{};
    for (final item in rawMembers) {
      final uid = item.toString().trim();
      if (uid.isEmpty) continue;
      if (!includeAuthor && uid == authorId) continue;
      unique.add(uid);
    }
    return unique.toList(growable: false);
  }

  Future<List<PublicUserProfile>> _participantProfilesFor(
      List<String> uids) async {
    final profiles = await Future.wait(
      uids.map((uid) async {
        final profile = await _publicUserProfileService.fetchProfile(uid);
        return profile ?? PublicUserProfile.fallback(userId: uid);
      }),
    );
    return profiles;
  }

  Future<void> _toggleFollowFromParticipantRow({
    required String targetUid,
    required FollowRelationship relationship,
  }) async {
    try {
      if (relationship.isFollowing) {
        final shouldUnfollow = await showDialog<bool>(
          context: context,
          builder: (dialogContext) {
            final isLight =
                Theme.of(dialogContext).brightness == Brightness.light;
            return Directionality(
              textDirection: TextDirection.rtl,
              child: AlertDialog(
                backgroundColor:
                    isLight ? Colors.white : const Color(0xFF121C2C),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(
                    color:
                        isLight ? const Color(0xFFA9C3FF) : Colors.transparent,
                  ),
                ),
                title: Text(
                  'להפסיק לעקוב?',
                  style: TextStyle(
                    color: isLight ? Colors.black : Colors.white,
                  ),
                ),
                content: Text(
                  'האם אתה בטוח שברצונך להסיר מעקב מהמשתמש הזה?',
                  style: TextStyle(
                    color: isLight ? Colors.black87 : Colors.white70,
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(dialogContext).pop(false),
                    child: const Text('ביטול'),
                  ),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor:
                          isLight ? Colors.white : const Color(0xFF9E7CFF),
                      foregroundColor:
                          isLight ? const Color(0xFF9E7CFF) : Colors.black,
                      side: isLight
                          ? const BorderSide(color: Color(0xFF9E7CFF))
                          : BorderSide.none,
                    ),
                    onPressed: () => Navigator.of(dialogContext).pop(true),
                    child: const Text('כן, להסיר'),
                  ),
                ],
              ),
            );
          },
        );

        if (shouldUnfollow != true) {
          return;
        }

        await _socialService.unfollowUser(targetUid);
      } else if (relationship.isRequestPending) {
        final shouldCancel = await showDialog<bool>(
          context: context,
          builder: (dialogContext) {
            final isLight =
                Theme.of(dialogContext).brightness == Brightness.light;
            return Directionality(
              textDirection: TextDirection.rtl,
              child: AlertDialog(
                backgroundColor:
                    isLight ? Colors.white : const Color(0xFF121C2C),
                title: Text(
                  'ביטול בקשת מעקב?',
                  style: TextStyle(
                    color: isLight ? Colors.black : Colors.white,
                  ),
                ),
                content: Text(
                  'לבטל את בקשת המעקב למשתמש הזה?',
                  style: TextStyle(
                    color: isLight ? Colors.black87 : Colors.white70,
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(dialogContext).pop(false),
                    child: const Text('ביטול'),
                  ),
                  ElevatedButton(
                    onPressed: () => Navigator.of(dialogContext).pop(true),
                    child: const Text('כן, לבטל'),
                  ),
                ],
              ),
            );
          },
        );

        if (shouldCancel != true) {
          return;
        }

        await _socialService.cancelFollowRequest(targetUid);
      } else {
        await _socialService.followUser(targetUid);
      }
    } catch (error) {
      if (!mounted) return;
      final message = FirestoreRuleFeedback.actionMessage(
        error,
        'עדכון מעקב נכשל. נסה שוב בעוד רגע.',
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    }
  }

  String _groupFieldString(
    Map<String, dynamic> groupData,
    String key, {
    String fallback = 'לא צוין',
  }) {
    final value = (groupData[key] as String?)?.trim() ?? '';
    return value.isEmpty ? fallback : value;
  }

  DateTime? _extractDateField(Map<String, dynamic> data, String fieldName) {
    final raw = data[fieldName];
    if (raw is Timestamp) {
      return raw.toDate();
    }
    if (raw is DateTime) {
      return raw;
    }
    if (raw is String && raw.trim().isNotEmpty) {
      return DateTime.tryParse(raw.trim());
    }
    return null;
  }

  String _formatDateTime(DateTime? dateTime) {
    if (dateTime == null) {
      return 'לא צוין';
    }
    final day = dateTime.day.toString().padLeft(2, '0');
    final month = dateTime.month.toString().padLeft(2, '0');
    final year = dateTime.year.toString();
    final hour = dateTime.hour.toString().padLeft(2, '0');
    final minute = dateTime.minute.toString().padLeft(2, '0');
    return '$day/$month/$year, $hour:$minute';
  }

  String _formatOpenedAt(DateTime? dateTime) {
    if (dateTime == null) {
      return 'לא ידוע';
    }
    return _formatPostTimestamp(dateTime);
  }

  Widget _detailsChip({
    required IconData icon,
    required String text,
    required Color color,
  }) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final maxChipWidth = MediaQuery.of(context).size.width * 0.62;
    return Container(
      constraints: BoxConstraints(maxWidth: maxChipWidth),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: isLight ? Colors.white : color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.55)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              softWrap: false,
              style: TextStyle(
                color: isLight ? Colors.black : Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _detailCard({
    required IconData icon,
    required String title,
    required String value,
    required Color accent,
  }) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    return Container(
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: isLight ? Colors.white : const Color(0xFF1A2435),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accent.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: accent),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    color: isLight ? Colors.black87 : const Color(0xFFB6C0D0),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: TextStyle(
              color: isLight ? Colors.black : Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showLinkedGroupDetailsDialog(_LinkedGroupMeta groupMeta) async {
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black54,
      builder: (dialogContext) {
        final isLight = Theme.of(dialogContext).brightness == Brightness.light;
        final dialogSize = MediaQuery.of(dialogContext).size;
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          child: Container(
            constraints: BoxConstraints(
              maxWidth: dialogSize.width * 0.92,
              maxHeight: dialogSize.height * 0.82,
            ),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              color: isLight ? Colors.white : null,
              gradient: isLight
                  ? null
                  : const LinearGradient(
                      colors: [Color(0xFF53C1F9), Color(0xFF9E7CFF)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
              border:
                  isLight ? Border.all(color: const Color(0xFFA9C3FF)) : null,
            ),
            padding: const EdgeInsets.all(1.8),
            child: Container(
              decoration: BoxDecoration(
                color: isLight ? Colors.white : const Color(0xFF111A28),
                borderRadius: BorderRadius.circular(22),
              ),
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
              child: FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                future: FirebaseFirestore.instance
                    .collection('groups')
                    .doc(groupMeta.groupId)
                    .get(),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }

                  final groupData =
                      snapshot.data?.data() ?? <String, dynamic>{};
                  final category = _groupFieldString(groupData, 'category');
                  final subCategory = _groupFieldString(
                      groupData, 'subCategory',
                      fallback: 'ללא');
                  final location = _groupFieldString(groupData, 'location');
                  final date = _extractDateField(groupData, 'date');
                  final createdAt = _extractDateField(groupData, 'createdAt');
                  final approvalRequired =
                      (groupData['isAdminApprovalRequired'] as bool?) ?? false;
                  final ageRange =
                      (groupData['ageRange'] as Map<String, dynamic>?) ??
                          const <String, dynamic>{};
                  final minAge = (ageRange['min'] as num?)?.toInt();
                  final maxAge = (ageRange['max'] as num?)?.toInt();
                  final ageRangeText = (minAge == null || maxAge == null)
                      ? 'לא הוגדר'
                      : '$minAge-$maxAge';
                  final membersList =
                      (groupData['membersList'] as List<dynamic>? ??
                              groupData['members'] as List<dynamic>? ??
                              const <dynamic>[])
                          .map((id) => id.toString().trim())
                          .where((id) => id.isNotEmpty)
                          .toSet();
                  final membersCount =
                      (groupData['membersCount'] as num?)?.toInt() ??
                          membersList.length;

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(18),
                          color: isLight ? Colors.white : null,
                          gradient: isLight
                              ? null
                              : const LinearGradient(
                                  colors: [
                                    Color(0xFF223852),
                                    Color(0xFF35254A)
                                  ],
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                ),
                          border: Border.all(
                            color: isLight
                                ? const Color(0xFFA9C3FF)
                                : const Color(0xFF53C1F9)
                                    .withValues(alpha: 0.35),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              groupMeta.name,
                              style: TextStyle(
                                color: isLight ? Colors.black : Colors.white,
                                fontSize: 17,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 10),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                _detailsChip(
                                  icon: Icons.event_outlined,
                                  text: _formatDateTime(date),
                                  color: const Color(0xFF53C1F9),
                                ),
                                _detailsChip(
                                  icon: Icons.place_outlined,
                                  text: location,
                                  color: const Color(0xFF9E7CFF),
                                ),
                                _detailsChip(
                                  icon: Icons.sell_outlined,
                                  text: '$category • $subCategory',
                                  color: const Color(0xFF5BE2C3),
                                ),
                                _detailsChip(
                                  icon: Icons.verified_user_outlined,
                                  text: approvalRequired
                                      ? 'אישור מנהל נדרש'
                                      : 'ללא אישור מנהל',
                                  color: approvalRequired
                                      ? const Color(0xFFF7B955)
                                      : const Color(0xFF53C1F9),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),
                      Expanded(
                        child: SingleChildScrollView(
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              final isNarrow = constraints.maxWidth < 350;
                              final cardWidth = isNarrow
                                  ? constraints.maxWidth
                                  : (constraints.maxWidth - 8) / 2;

                              return Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  SizedBox(
                                    width: cardWidth,
                                    child: _detailCard(
                                      icon: Icons.group_outlined,
                                      title: 'מספר חברים',
                                      value: '$membersCount משתתפים',
                                      accent: const Color(0xFF53C1F9),
                                    ),
                                  ),
                                  SizedBox(
                                    width: cardWidth,
                                    child: _detailCard(
                                      icon: Icons.lock_clock_outlined,
                                      title: 'נפתחה',
                                      value: _formatOpenedAt(createdAt),
                                      accent: const Color(0xFF9E7CFF),
                                    ),
                                  ),
                                  SizedBox(
                                    width: cardWidth,
                                    child: _detailCard(
                                      icon: Icons.cake_outlined,
                                      title: 'טווח גילאים',
                                      value: ageRangeText,
                                      accent: const Color(0xFF5BE2C3),
                                    ),
                                  ),
                                  SizedBox(
                                    width: cardWidth,
                                    child: _detailCard(
                                      icon: Icons
                                          .subdirectory_arrow_right_rounded,
                                      title: 'תת קטגוריה',
                                      value: subCategory,
                                      accent: const Color(0xFFF7B955),
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        height: 42,
                        child: ElevatedButton(
                          onPressed: () => Navigator.of(dialogContext).pop(),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: isLight
                                ? Colors.white
                                : const Color(0xFF9E7CFF),
                            foregroundColor: isLight
                                ? const Color(0xFF9E7CFF)
                                : Colors.white,
                            side: isLight
                                ? const BorderSide(color: Color(0xFF9E7CFF))
                                : BorderSide.none,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          child: const Text(
                            'סגור',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _openParticipantsSheet(Map<String, dynamic> post) async {
    final participantUids = _participantUids(post, includeAuthor: false);
    final linkedGroupId = (post['linkedGroupId'] as String? ?? '').trim();
    final hasLinkedGroup = linkedGroupId.isNotEmpty;
    final groupMetaFuture = hasLinkedGroup
        ? _fetchLinkedGroupMeta(linkedGroupId)
        : Future<_LinkedGroupMeta?>.value(null);

    if (participantUids.isEmpty && !hasLinkedGroup) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('לא נבחרו חברים משתתפים לפופ הזה')),
      );
      return;
    }

    final currentUid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        final isLight = Theme.of(sheetContext).brightness == Brightness.light;
        return Directionality(
          textDirection: TextDirection.rtl,
          child: SafeArea(
            child: Container(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(sheetContext).size.height * 0.74,
              ),
              margin: const EdgeInsets.fromLTRB(14, 8, 14, 16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(24),
                gradient: const LinearGradient(
                  colors: [Color(0xFF53C1F9), Color(0xFF9E7CFF)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              padding: const EdgeInsets.all(1.5),
              child: Container(
                decoration: BoxDecoration(
                  color: isLight ? Colors.white : const Color(0xFF101826),
                  borderRadius: BorderRadius.circular(22),
                ),
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
                child: FutureBuilder<_LinkedGroupMeta?>(
                  future: groupMetaFuture,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting &&
                        hasLinkedGroup) {
                      return const Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: CircularProgressIndicator(),
                        ),
                      );
                    }

                    final groupMeta = snapshot.data;

                    return FutureBuilder<List<PublicUserProfile>>(
                      future: _participantProfilesFor(participantUids),
                      builder: (context, participantsSnapshot) {
                        if (participantsSnapshot.connectionState ==
                                ConnectionState.waiting &&
                            participantUids.isNotEmpty) {
                          return const Center(
                            child: Padding(
                              padding: EdgeInsets.all(24),
                              child: CircularProgressIndicator(),
                            ),
                          );
                        }

                        final profiles = participantsSnapshot.data ??
                            const <PublicUserProfile>[];
                        final hasParticipants = profiles.isNotEmpty;

                        if (!hasParticipants && groupMeta == null) {
                          return Center(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Text(
                                'אין משתתפים להצגה',
                                style: TextStyle(
                                  color: isLight
                                      ? const Color(0xFF46536D)
                                      : Colors.white70,
                                ),
                              ),
                            ),
                          );
                        }

                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              'חברים משתתפים',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: isLight ? Colors.black : Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            if (groupMeta != null) ...[
                              const SizedBox(height: 12),
                              Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  gradient: isLight
                                      ? const LinearGradient(
                                          colors: [
                                            Color(0xFFEFF5FF),
                                            Color(0xFFF6F1FF)
                                          ],
                                          begin: Alignment.topLeft,
                                          end: Alignment.bottomRight,
                                        )
                                      : const LinearGradient(
                                          colors: [
                                            Color(0xFF1A2435),
                                            Color(0xFF202B43)
                                          ],
                                          begin: Alignment.topLeft,
                                          end: Alignment.bottomRight,
                                        ),
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(
                                    color: isLight
                                        ? const Color(0xFFB4C5FF)
                                        : const Color(0xFF53C1F9)
                                            .withValues(alpha: 0.28),
                                  ),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        CircleAvatar(
                                          radius: 20,
                                          backgroundColor:
                                              const Color(0xFF9E7CFF),
                                          backgroundImage:
                                              groupMeta.imageUrl.isNotEmpty
                                                  ? NetworkImage(
                                                      groupMeta.imageUrl,
                                                    )
                                                  : null,
                                          child: groupMeta.imageUrl.isEmpty
                                              ? const Icon(
                                                  Icons.groups_rounded,
                                                  color: Colors.white,
                                                  size: 20,
                                                )
                                              : null,
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                groupMeta.name,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  color: isLight
                                                      ? const Color(0xFF1E2A45)
                                                      : Colors.white,
                                                  fontWeight: FontWeight.w800,
                                                ),
                                              ),
                                              const SizedBox(height: 2),
                                              Text(
                                                'קבוצה מקושרת לפוסט',
                                                style: TextStyle(
                                                  color: isLight
                                                      ? const Color(0xFF5A6CFF)
                                                      : const Color(0xFF9EDBFF),
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.w700,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 4,
                                          ),
                                          decoration: BoxDecoration(
                                            color: isLight
                                                ? Colors.white
                                                : Colors.white10,
                                            borderRadius:
                                                BorderRadius.circular(999),
                                            border: Border.all(
                                              color: isLight
                                                  ? const Color(0xFFA9C3FF)
                                                  : Colors.white24,
                                            ),
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(
                                                groupMeta.isPublic
                                                    ? Icons.public_rounded
                                                    : Icons
                                                        .lock_outline_rounded,
                                                size: 14,
                                                color: isLight
                                                    ? const Color(0xFF41557C)
                                                    : Colors.white70,
                                              ),
                                              const SizedBox(width: 4),
                                              Text(
                                                groupMeta.isPublic
                                                    ? 'ציבורית'
                                                    : 'פרטית',
                                                style: TextStyle(
                                                  color: isLight
                                                      ? const Color(0xFF41557C)
                                                      : Colors.white70,
                                                  fontSize: 12,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 10),
                                    LayoutBuilder(
                                      builder: (context, constraints) {
                                        final isNarrowActions =
                                            constraints.maxWidth < 350;

                                        final detailsButton = OutlinedButton(
                                          style: OutlinedButton.styleFrom(
                                            minimumSize:
                                                const Size.fromHeight(34),
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 8, vertical: 6),
                                            tapTargetSize: MaterialTapTargetSize
                                                .shrinkWrap,
                                            visualDensity: const VisualDensity(
                                              horizontal: -2,
                                              vertical: -2,
                                            ),
                                          ),
                                          onPressed: () {
                                            _showLinkedGroupDetailsDialog(
                                                groupMeta);
                                          },
                                          child: const Text(
                                            'פרטים',
                                            style: TextStyle(fontSize: 12),
                                          ),
                                        );

                                        final groupActionButton = Builder(
                                          builder: (_) {
                                            if (groupMeta.isCurrentUserMember) {
                                              return ElevatedButton(
                                                style: ElevatedButton.styleFrom(
                                                  minimumSize:
                                                      const Size(72, 34),
                                                  padding: const EdgeInsets
                                                      .symmetric(
                                                    horizontal: 10,
                                                    vertical: 6,
                                                  ),
                                                  tapTargetSize:
                                                      MaterialTapTargetSize
                                                          .shrinkWrap,
                                                  visualDensity:
                                                      const VisualDensity(
                                                    horizontal: -2,
                                                    vertical: -2,
                                                  ),
                                                  backgroundColor: isLight
                                                      ? Colors.white
                                                      : const Color(0xFF26354D),
                                                  foregroundColor: isLight
                                                      ? const Color(0xFF2E3E63)
                                                      : Colors.white,
                                                  side: isLight
                                                      ? const BorderSide(
                                                          color:
                                                              Color(0xFFA9C3FF),
                                                        )
                                                      : BorderSide.none,
                                                ),
                                                onPressed: () async {
                                                  Navigator.of(sheetContext)
                                                      .pop();
                                                  await _pushWithDetailPlaybackPaused(
                                                    MaterialPageRoute(
                                                      builder: (_) =>
                                                          ChatRoomScreen(
                                                        chatName:
                                                            groupMeta.name,
                                                        avatarUrl: groupMeta
                                                                .imageUrl
                                                                .isEmpty
                                                            ? null
                                                            : groupMeta
                                                                .imageUrl,
                                                        chatId:
                                                            groupMeta.groupId,
                                                        isDirectChat: false,
                                                      ),
                                                    ),
                                                  );
                                                },
                                                child: const Text(
                                                  'צפה בקבוצה',
                                                  style:
                                                      TextStyle(fontSize: 12),
                                                ),
                                              );
                                            }

                                            if (groupMeta
                                                .isCurrentUserPending) {
                                              return ElevatedButton(
                                                style: ElevatedButton.styleFrom(
                                                  minimumSize:
                                                      const Size(72, 34),
                                                  tapTargetSize:
                                                      MaterialTapTargetSize
                                                          .shrinkWrap,
                                                  visualDensity:
                                                      const VisualDensity(
                                                    horizontal: -2,
                                                    vertical: -2,
                                                  ),
                                                  backgroundColor: isLight
                                                      ? const Color(0xFFE8EEFF)
                                                      : Colors.white10,
                                                  foregroundColor: isLight
                                                      ? const Color(0xFF4A5F8A)
                                                      : Colors.white70,
                                                  side: isLight
                                                      ? const BorderSide(
                                                          color:
                                                              Color(0xFFA9C3FF),
                                                        )
                                                      : BorderSide.none,
                                                ),
                                                onPressed: null,
                                                child: const Text(
                                                  'בקשתך נשלחה',
                                                  style:
                                                      TextStyle(fontSize: 12),
                                                ),
                                              );
                                            }

                                            if (groupMeta.isPublic) {
                                              return ElevatedButton(
                                                style: ElevatedButton.styleFrom(
                                                  minimumSize:
                                                      const Size(72, 34),
                                                  tapTargetSize:
                                                      MaterialTapTargetSize
                                                          .shrinkWrap,
                                                  visualDensity:
                                                      const VisualDensity(
                                                    horizontal: -2,
                                                    vertical: -2,
                                                  ),
                                                  backgroundColor: Colors.white,
                                                  foregroundColor:
                                                      const Color(0xFF9E7CFF),
                                                  side: const BorderSide(
                                                    color: Color(0xFF9E7CFF),
                                                  ),
                                                ),
                                                onPressed: () async {
                                                  try {
                                                    await _groupService
                                                        .joinGroup(
                                                            groupMeta.groupId);
                                                    if (sheetContext.mounted) {
                                                      Navigator.of(sheetContext)
                                                          .pop();
                                                    }
                                                    if (!mounted) {
                                                      return;
                                                    }
                                                    ScaffoldMessenger.of(
                                                            this.context)
                                                        .showSnackBar(
                                                      const SnackBar(
                                                        content: Text(
                                                            'בקשת ההצטרפות נשלחה'),
                                                      ),
                                                    );
                                                  } catch (error) {
                                                    if (sheetContext.mounted) {
                                                      Navigator.of(sheetContext)
                                                          .pop();
                                                    }
                                                    if (!mounted) {
                                                      return;
                                                    }
                                                    ScaffoldMessenger.of(
                                                            this.context)
                                                        .showSnackBar(
                                                      SnackBar(
                                                        content: Text(
                                                            'לא ניתן להצטרף לקבוצה: $error'),
                                                      ),
                                                    );
                                                  }
                                                },
                                                child: const Text(
                                                  'הצטרף',
                                                  style:
                                                      TextStyle(fontSize: 12),
                                                ),
                                              );
                                            }

                                            return ElevatedButton(
                                              style: ElevatedButton.styleFrom(
                                                backgroundColor: Colors.white12,
                                                foregroundColor: Colors.white70,
                                              ),
                                              onPressed: null,
                                              child: const Text('קבוצה פרטית'),
                                            );
                                          },
                                        );

                                        if (isNarrowActions) {
                                          return Column(
                                            children: [
                                              SizedBox(
                                                width: double.infinity,
                                                child: detailsButton,
                                              ),
                                              const SizedBox(height: 8),
                                              SizedBox(
                                                width: double.infinity,
                                                child: groupActionButton,
                                              ),
                                            ],
                                          );
                                        }

                                        return Row(
                                          children: [
                                            Expanded(child: detailsButton),
                                            const SizedBox(width: 8),
                                            Expanded(child: groupActionButton),
                                          ],
                                        );
                                      },
                                    ),
                                  ],
                                ),
                              ),
                            ],
                            if (hasParticipants) ...[
                              const SizedBox(height: 12),
                              Expanded(
                                child: ListView.builder(
                                  itemCount: profiles.length,
                                  itemBuilder: (context, index) {
                                    final profile = profiles[index];
                                    final isMe = currentUid.isNotEmpty &&
                                        profile.userId == currentUid;
                                    final name = profile.displayName.isNotEmpty
                                        ? profile.displayName
                                        : profile.handle;

                                    return Container(
                                      margin: const EdgeInsets.only(bottom: 8),
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 10, vertical: 8),
                                      decoration: BoxDecoration(
                                        color: isLight
                                            ? const Color(0xFFF2F7FF)
                                            : const Color(0xFF1A2435),
                                        borderRadius: BorderRadius.circular(14),
                                        border: Border.all(
                                          color: isLight
                                              ? const Color(0xFFA9C3FF)
                                              : const Color(0xFF53C1F9)
                                                  .withValues(alpha: 0.22),
                                        ),
                                      ),
                                      child: Row(
                                        children: [
                                          CircleAvatar(
                                            radius: 18,
                                            backgroundColor:
                                                const Color(0xFF9E7CFF),
                                            backgroundImage: profile
                                                    .profilePictureUrl
                                                    .isNotEmpty
                                                ? NetworkImage(
                                                    profile.profilePictureUrl)
                                                : null,
                                            child: profile
                                                    .profilePictureUrl.isEmpty
                                                ? Text(
                                                    name.isNotEmpty
                                                        ? name.characters.first
                                                        : '?',
                                                    style: const TextStyle(
                                                      color: Colors.white,
                                                      fontWeight:
                                                          FontWeight.bold,
                                                    ),
                                                  )
                                                : null,
                                          ),
                                          const SizedBox(width: 10),
                                          Expanded(
                                            child: InkWell(
                                              onTap: () async {
                                                Navigator.of(sheetContext)
                                                    .pop();
                                                await _pushWithDetailPlaybackPaused(
                                                  MaterialPageRoute(
                                                    builder: (_) =>
                                                        UserProfileScreen(
                                                      uid: profile.userId,
                                                      currentBottomIndex: 0,
                                                    ),
                                                  ),
                                                );
                                              },
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Text(
                                                    name,
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: TextStyle(
                                                      color: isLight
                                                          ? Colors.black
                                                          : Colors.white,
                                                      fontWeight:
                                                          FontWeight.w700,
                                                    ),
                                                  ),
                                                  const SizedBox(height: 2),
                                                  Text(
                                                    profile.handle,
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: TextStyle(
                                                      color: isLight
                                                          ? const Color(
                                                              0xFF5C6C88)
                                                          : Colors.grey[400],
                                                      fontSize: 12,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          if (isMe)
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                      horizontal: 8,
                                                      vertical: 6),
                                              decoration: BoxDecoration(
                                                color: isLight
                                                    ? const Color(0xFFE8EEFF)
                                                    : Colors.white10,
                                                borderRadius:
                                                    BorderRadius.circular(10),
                                              ),
                                              child: Text(
                                                'אתה',
                                                style: TextStyle(
                                                  color: isLight
                                                      ? const Color(0xFF2E3E63)
                                                      : Colors.white70,
                                                  fontWeight: FontWeight.w700,
                                                  fontSize: 12,
                                                ),
                                              ),
                                            )
                                          else
                                            StreamBuilder<FollowRelationship>(
                                              stream: _socialService
                                                  .watchFollowRelationship(
                                                      profile.userId),
                                              builder:
                                                  (context, followSnapshot) {
                                                final relationship =
                                                    followSnapshot.data ??
                                                        const FollowRelationship();
                                                final isFollowing =
                                                    relationship.isFollowing;
                                                final isRequestPending =
                                                    relationship
                                                        .isRequestPending;
                                                return ElevatedButton(
                                                  onPressed: () =>
                                                      _toggleFollowFromParticipantRow(
                                                    targetUid: profile.userId,
                                                    relationship: relationship,
                                                  ),
                                                  style:
                                                      ElevatedButton.styleFrom(
                                                    elevation: 0,
                                                    minimumSize:
                                                        const Size(68, 34),
                                                    tapTargetSize:
                                                        MaterialTapTargetSize
                                                            .shrinkWrap,
                                                    visualDensity:
                                                        const VisualDensity(
                                                      horizontal: -2,
                                                      vertical: -2,
                                                    ),
                                                    backgroundColor: isFollowing
                                                        ? (isLight
                                                            ? const Color(
                                                                0xFFE8EEFF)
                                                            : const Color(
                                                                0xFF26354D))
                                                        : (isRequestPending
                                                            ? (isLight
                                                                ? const Color(
                                                                    0xFFE3ECF2)
                                                                : const Color(
                                                                    0xFF3A4B57))
                                                            : const Color(
                                                                0xFF9E7CFF)),
                                                    foregroundColor: isLight
                                                        ? (isFollowing
                                                            ? const Color(
                                                                0xFF2E3E63)
                                                            : Colors.white)
                                                        : Colors.white,
                                                    side: isLight
                                                        ? BorderSide(
                                                            color: isFollowing
                                                                ? const Color(
                                                                    0xFFA9C3FF)
                                                                : const Color(
                                                                    0xFF9E7CFF),
                                                          )
                                                        : BorderSide.none,
                                                    padding: const EdgeInsets
                                                        .symmetric(
                                                        horizontal: 10,
                                                        vertical: 6),
                                                    shape:
                                                        RoundedRectangleBorder(
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                              10),
                                                    ),
                                                  ),
                                                  child: Text(
                                                    isFollowing
                                                        ? 'עוקב'
                                                        : (isRequestPending
                                                            ? 'בקשה נשלחה'
                                                            : 'עקוב'),
                                                    style: const TextStyle(
                                                      fontSize: 11,
                                                      fontWeight:
                                                          FontWeight.w700,
                                                    ),
                                                  ),
                                                );
                                              },
                                            ),
                                        ],
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ],
                          ],
                        );
                      },
                    );
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<_LinkedGroupMeta?> _fetchLinkedGroupMeta(String groupId) async {
    final normalizedGroupId = groupId.trim();
    if (normalizedGroupId.isEmpty) {
      return null;
    }

    final doc = await FirebaseFirestore.instance
        .collection('groups')
        .doc(normalizedGroupId)
        .get();
    if (!doc.exists) {
      return null;
    }

    final data = doc.data() ?? <String, dynamic>{};

    Set<String> stringSetFromDynamic(dynamic raw) {
      if (raw is List) {
        return raw
            .map((item) => item.toString().trim())
            .where((item) => item.isNotEmpty)
            .toSet();
      }
      if (raw is Map) {
        return raw.entries
            .where((entry) {
              final value = entry.value;
              if (value is bool) {
                return value;
              }
              final asText = value?.toString().trim().toLowerCase() ?? '';
              return asText == 'approved' || asText == 'member';
            })
            .map((entry) => entry.key.toString().trim())
            .where((item) => item.isNotEmpty)
            .toSet();
      }
      return <String>{};
    }

    final membersRaw = stringSetFromDynamic(data['members']);
    final membersListRaw = stringSetFromDynamic(data['membersList']);
    final approvedMembersRaw = stringSetFromDynamic(data['approvedMembers']);
    final memberUidsRaw = stringSetFromDynamic(data['memberUids']);
    final participantsRaw = stringSetFromDynamic(data['participants']);

    final currentUid = _currentUserId();
    String membershipStatus = '';
    if (currentUid.isNotEmpty) {
      final memberDoc =
          await doc.reference.collection('members').doc(currentUid).get();
      membershipStatus =
          ((memberDoc.data() ?? <String, dynamic>{})['status'] as String? ?? '')
              .trim()
              .toLowerCase();
    }

    Set<String> chatParticipants = <String>{};
    final groupChatDoc =
        await FirebaseFirestore.instance.collection('chats').doc(doc.id).get();
    if (groupChatDoc.exists) {
      chatParticipants = stringSetFromDynamic(
        (groupChatDoc.data() ?? const <String, dynamic>{})['participants'],
      );
    }

    final isMemberByStatus = membershipStatus == 'approved' ||
        membershipStatus == 'member' ||
        membershipStatus == 'admin' ||
        membershipStatus == 'owner';

    final isCurrentUserMember = isMemberByStatus ||
        (currentUid.isNotEmpty &&
            (membersRaw.contains(currentUid) ||
                membersListRaw.contains(currentUid) ||
                approvedMembersRaw.contains(currentUid) ||
                memberUidsRaw.contains(currentUid) ||
                participantsRaw.contains(currentUid) ||
                chatParticipants.contains(currentUid)));
    final isCurrentUserPending = membershipStatus == 'pending';

    final name =
        ((data['groupName'] as String?) ?? (data['name'] as String?) ?? '')
            .trim();
    final imageUrl = (data['groupImageUrl'] as String? ?? '').trim();

    return _LinkedGroupMeta(
      groupId: doc.id,
      name: name.isNotEmpty ? name : 'קבוצה',
      imageUrl: imageUrl,
      isPublic: (data['isPublic'] as bool?) ?? false,
      isCurrentUserMember: isCurrentUserMember,
      isCurrentUserPending: isCurrentUserPending,
    );
  }

  PublicUserProfile _authorProfileForPost(Map<String, dynamic> post) {
    final uid =
        (post['authorId'] as String? ?? post['uid'] as String? ?? '').trim();
    final liveProfile = uid.isNotEmpty ? _authorProfilesByUid[uid] : null;
    if (liveProfile != null) {
      return liveProfile;
    }

    final injectedAuthor = post['author'];
    if (injectedAuthor is Map<String, dynamic>) {
      return PublicUserProfile.fromMap(uid, injectedAuthor);
    }
    if (injectedAuthor is Map) {
      return PublicUserProfile.fromMap(
          uid, Map<String, dynamic>.from(injectedAuthor));
    }

    return _publicUserProfileService.fallbackProfileForPost(post);
  }

  Widget _buildProfileAvatar(String profileUrl, {double size = 40}) {
    if (profileUrl.isEmpty) {
      return Container(
        width: size,
        height: size,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            colors: [Color(0xFF8C62FF), Color(0xFF46D3FF)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Container(
          margin: const EdgeInsets.all(1.2),
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: Color(0xFF122034),
          ),
          child: Icon(Icons.person_outline_rounded,
              color: Colors.white, size: size * 0.58),
        ),
      );
    }

    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: [Color(0xFF8C62FF), Color(0xFF46D3FF)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Container(
        margin: const EdgeInsets.all(1.2),
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: Color(0xFF122034),
        ),
        child: ClipOval(
          child: CachedNetworkImage(
            imageUrl: profileUrl,
            fit: BoxFit.cover,
            errorWidget: (context, url, error) {
              return Icon(Icons.person_outline_rounded,
                  color: Colors.white, size: size * 0.58);
            },
          ),
        ),
      ),
    );
  }

  Widget _buildMedia(Map<String, dynamic> post, {required bool isActive}) {
    final mediaItems = postMediaItemsFromData(post);
    if (mediaItems.isEmpty) {
      return Container(
        color: const Color(0xFF111927),
        alignment: Alignment.center,
        child: const Icon(
          Icons.image_not_supported_rounded,
          color: Colors.white38,
          size: 38,
        ),
      );
    }

    return PostMediaViewer(
      mediaItems: mediaItems,
      aspectRatio: null,
      showDesktopNavigationArrows: false,
      isActive: isActive,
    );
  }

  String _postId(Map<String, dynamic> post) {
    return (post['postId'] as String? ?? post['id'] as String? ?? '').trim();
  }

  String _postAuthorId(Map<String, dynamic> post) {
    return (post['authorId'] as String? ?? post['uid'] as String? ?? '').trim();
  }

  Future<void> _reportCurrentPost() async {
    if (_posts.isEmpty || _currentIndex < 0 || _currentIndex >= _posts.length) {
      return;
    }

    final post = _posts[_currentIndex];
    final postId = _postId(post);
    final authorId = _postAuthorId(post);
    final currentUid = _currentUserId();
    if (postId.isEmpty || authorId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('לא ניתן לדווח על הפוסט כרגע.')),
      );
      return;
    }
    if (currentUid.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('יש להתחבר כדי לדווח.')),
      );
      return;
    }
    if (authorId == currentUid) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('לא ניתן לדווח על פוסט שלך.')),
      );
      return;
    }

    final shouldReport = await showReportConfirmationDialog(
      context,
      targetLabel: 'פוסט',
    );
    if (!shouldReport || !mounted) {
      return;
    }

    final reason = await showReportReasonPicker(
      context,
      targetLabel: 'פוסט',
    );
    if (reason == null || !mounted) {
      return;
    }

    final details = await showReportDetailsDialog(
      context,
      reason: reason,
      targetLabel: 'פוסט',
    );
    if (details == null || !mounted) {
      return;
    }

    try {
      await _reportService.submitPostReport(
        targetPostId: postId,
        targetUserUid: authorId,
        reason: reason,
        details: details,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('הדיווח נשלח. תודה שעזרת לשמור על הקהילה.')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('שליחת הדיווח נכשלה: $error')),
      );
    }
  }

  bool _isLikedByMe(Map<String, dynamic> post) {
    final postId = _postId(post);
    final overlayIntent = PostInteractionOverlayService.interactionIntentFor(
      postId: postId,
      intent: 'likedByMe',
    );
    if (overlayIntent != null) {
      return overlayIntent;
    }
    final likedByCurrentUser = post['likedByCurrentUser'];
    if (likedByCurrentUser is bool) {
      return likedByCurrentUser;
    }
    final uid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
    if (uid.isEmpty) return false;
    final likesRaw = post['likes'];
    if (likesRaw is! List) return false;
    return likesRaw.map((item) => item.toString().trim()).contains(uid);
  }

  bool _isSavedByMe(Map<String, dynamic> post) {
    final postId = _postId(post);
    final overlayIntent = PostInteractionOverlayService.interactionIntentFor(
      postId: postId,
      intent: 'savedByMe',
    );
    if (overlayIntent != null) {
      return overlayIntent;
    }
    final savedByCurrentUser = post['savedByCurrentUser'];
    if (savedByCurrentUser is bool) {
      return savedByCurrentUser;
    }
    final uid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
    if (uid.isEmpty) return false;
    final savedByRaw = post['savedBy'];
    if (savedByRaw is! List) return false;
    return savedByRaw.map((item) => item.toString().trim()).contains(uid);
  }

  Future<void> _refreshPostAtIndex(int index) async {
    if (index < 0 || index >= _posts.length) return;
    final postId = _postId(_posts[index]);
    if (postId.isEmpty) return;

    final doc =
        await FirebaseFirestore.instance.collection('posts').doc(postId).get();
    if (!mounted || !doc.exists) return;
    final data = doc.data() ?? <String, dynamic>{};
    setState(() {
      _posts[index] = <String, dynamic>{
        ..._posts[index],
        ...data,
        'id': doc.id,
        'postId': (data['postId'] as String? ?? doc.id).trim(),
      };
    });
  }

  Future<void> _toggleLikeForCurrentPost(Map<String, dynamic> post) async {
    final postId = _postId(post);
    final authorId = _postAuthorId(post);
    if (postId.isEmpty || _likeInFlightPostIds.contains(postId)) return;

    final index = _currentIndex;
    final previousLiked = _isLikedByMe(post);
    final nextLiked = !previousLiked;
    final hasLiked = previousLiked;

    setState(() {
      _likeInFlightPostIds.add(postId);
      _posts[index] = <String, dynamic>{
        ..._posts[index],
        // Keep only intent flag local; counts are driven by overlay delta + backend.
        'likedByCurrentUser': nextLiked,
      };
    });
    PostInteractionOverlayService.setInteractionIntent(
      postId: postId,
      likedByMe: nextLiked,
    );
    PostInteractionOverlayService.addDelta(
      postId: postId,
      likes: previousLiked ? -1 : 1,
    );

    try {
      await _postService.togglePostLike(
        postId: postId,
        postAuthorId: authorId,
        currentlyLikedByMe: hasLiked,
      );
    } catch (error) {
      if (!mounted) return;
      final denied = FirestoreRuleFeedback.isPermissionDenied(error);
      if (!denied) {
        PostInteractionOverlayService.setInteractionIntent(
          postId: postId,
          likedByMe: previousLiked,
        );
        PostInteractionOverlayService.addDelta(
          postId: postId,
          likes: previousLiked ? 1 : -1,
        );
        await _refreshPostAtIndex(index);
        if (!mounted) return;
      }
      final message = FirestoreRuleFeedback.actionMessage(
        error,
        'עדכון לייק נכשל. נסה שוב בעוד רגע.',
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    } finally {
      if (mounted) {
        setState(() {
          _likeInFlightPostIds.remove(postId);
        });
      }
    }
  }

  Future<void> _toggleSaveForCurrentPost(Map<String, dynamic> post) async {
    final postId = _postId(post);
    if (postId.isEmpty || _saveInFlightPostIds.contains(postId)) return;

    final index = _currentIndex;
    final previousSaved = _isSavedByMe(post);
    final nextSaved = !previousSaved;
    final hasSaved = previousSaved;

    setState(() {
      _saveInFlightPostIds.add(postId);
      _posts[index] = <String, dynamic>{
        ..._posts[index],
        // Keep only intent flag local; counts are driven by overlay delta + backend.
        'savedByCurrentUser': nextSaved,
      };
    });
    PostInteractionOverlayService.setInteractionIntent(
      postId: postId,
      savedByMe: nextSaved,
    );
    PostInteractionOverlayService.addDelta(
      postId: postId,
      saves: previousSaved ? -1 : 1,
    );

    try {
      await _postService.togglePostSave(
        postId: postId,
        currentlySavedByMe: hasSaved,
      );
    } catch (error) {
      if (!mounted) return;
      final denied = FirestoreRuleFeedback.isPermissionDenied(error);
      if (!denied) {
        PostInteractionOverlayService.setInteractionIntent(
          postId: postId,
          savedByMe: previousSaved,
        );
        PostInteractionOverlayService.addDelta(
          postId: postId,
          saves: previousSaved ? 1 : -1,
        );
        await _refreshPostAtIndex(index);
        if (!mounted) return;
      }
      final message = FirestoreRuleFeedback.actionMessage(
        error,
        'עדכון שמירה נכשל. נסה שוב בעוד רגע.',
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    } finally {
      if (mounted) {
        setState(() {
          _saveInFlightPostIds.remove(postId);
        });
      }
    }
  }

  String _shareLinkFromPost(Map<String, dynamic> post) {
    final postId = _postId(post);
    if (postId.isEmpty) {
      return 'https://hundred.app';
    }
    return 'https://hundred.app/post/$postId';
  }

  String _shareTextFromPost(Map<String, dynamic> post) {
    final title = _derivedTitle(post).trim().isNotEmpty
        ? _derivedTitle(post).trim()
        : 'פופ חדש ב-HUNDRED';
    final description = ((post['description'] as String?) ??
            (post['caption'] as String?) ??
            (post['content'] as String?) ??
            '')
        .trim();
    final category = (post['category'] as String? ?? '').trim();
    final lines = <String>[title];
    if (description.isNotEmpty) {
      lines.add(description);
    }
    if (category.isNotEmpty) {
      lines.add('קטגוריה: $category');
    }
    lines.add(_shareLinkFromPost(post));
    return lines.join('\n');
  }

  Map<String, dynamic> _sharePayloadFromPost(Map<String, dynamic> post) {
    final title = _derivedTitle(post).trim();
    final description = ((post['description'] as String?) ??
            (post['caption'] as String?) ??
            (post['content'] as String?) ??
            '')
        .trim();
    final imageUrl = postPrimaryMediaUrl(post);
    final thumbnailUrl = (post['thumbnailUrl'] as String? ??
            post['videoThumbnailUrl'] as String? ??
            imageUrl)
        .trim();
    final mediaUrls = (post['mediaUrls'] as List<dynamic>? ?? const <dynamic>[])
        .map((value) => value.toString().trim())
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
    final mediaItems =
        (post['mediaItems'] as List<dynamic>? ?? const <dynamic>[])
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList(growable: false);

    return <String, dynamic>{
      'postId': _postId(post),
      'title': title,
      'description': description,
      'imageUrl': imageUrl,
      'thumbnailUrl': thumbnailUrl,
      'videoThumbnailUrl': thumbnailUrl,
      'mediaUrls': mediaUrls,
      'mediaItems': mediaItems,
      'authorId': _postAuthorId(post),
      'category': (post['category'] as String? ?? '').trim(),
      'subCategory': (post['subCategory'] as String? ?? '').trim(),
    };
  }

  Future<void> _shareCurrentPost(Map<String, dynamic> post,
      {bool silent = false}) async {
    final postId = _postId(post);
    final authorId = _postAuthorId(post);
    if (postId.isEmpty || _shareInFlightPostIds.contains(postId)) return;

    if (!silent) {
      setState(() {
        _shareInFlightPostIds.add(postId);
        final currentShares = _countFromAny(
            _posts[_currentIndex], ['sharesCount', 'shares_count']);
        _posts[_currentIndex] = <String, dynamic>{
          ..._posts[_currentIndex],
          'sharesCount': currentShares + 1,
        };
      });
    }

    try {
      await _postService.registerPostShare(
          postId: postId, postAuthorId: authorId);
      if (!silent) {
        await _refreshPostAtIndex(_currentIndex);
      }
    } catch (error) {
      if (!mounted) return;
      if (silent) {
        return;
      }
      final denied = FirestoreRuleFeedback.isPermissionDenied(error);
      if (!denied) {
        await _refreshPostAtIndex(_currentIndex);
        if (!mounted) return;
      }
      if (error is PostActionLimitException) {
        _showCenteredLimitAlert(error.message);
        return;
      }
      final message = FirestoreRuleFeedback.actionMessage(
        error,
        'שיתוף נכשל. נסה שוב בעוד רגע.',
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    } finally {
      if (mounted && !silent) {
        setState(() {
          _shareInFlightPostIds.remove(postId);
        });
      }
    }
  }

  Future<void> _openShareMenuForCurrentPost(Map<String, dynamic> post) async {
    final postId = _postId(post);
    await ShareFlowLogService.log(
      'DETAIL_SHARE_MENU_OPEN',
      data: <String, Object?>{'postId': postId},
    );
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final isLight = Theme.of(context).brightness == Brightness.light;
    final action = await showModalBottomSheet<_PostDetailShareMenuAction>(
      context: context,
      backgroundColor: isLight ? Colors.white : const Color(0xFF0B1019),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        Widget option({
          required IconData icon,
          required String label,
          required VoidCallback onTap,
          bool flipIconHorizontally = false,
        }) {
          return GestureDetector(
            onTap: onTap,
            child: Column(
              children: [
                CircleAvatar(
                  radius: 25,
                  backgroundColor: isLight
                      ? const Color(0xFFEFF5FF)
                      : const Color(0xFF1E2632),
                  child: Transform(
                    alignment: Alignment.center,
                    transform: Matrix4.identity()
                      ..scaleByDouble(
                        flipIconHorizontally ? -1.0 : 1.0,
                        1.0,
                        1.0,
                        1,
                      ),
                    child: Icon(
                      icon,
                      color: isLight ? Colors.black : Colors.white,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  label,
                  style: TextStyle(
                    color: isLight ? Colors.black54 : Colors.white70,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          );
        }

        return SafeArea(
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'שתף פופ זה עם חברים',
                  style: TextStyle(
                    color: isLight ? Colors.black : Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    option(
                      icon: Icons.copy_rounded,
                      label: 'העתק קישור',
                      onTap: () {
                        Navigator.pop(
                          sheetContext,
                          _PostDetailShareMenuAction.copyLink,
                        );
                      },
                    ),
                    option(
                      icon: Icons.send_rounded,
                      label: 'שלח לחבר',
                      onTap: () {
                        Navigator.pop(
                          sheetContext,
                          _PostDetailShareMenuAction.sendToFriend,
                        );
                      },
                    ),
                    option(
                      icon: Icons.ios_share_rounded,
                      label: 'שיתוף מערכת',
                      flipIconHorizontally: true,
                      onTap: () {
                        Navigator.pop(
                          sheetContext,
                          _PostDetailShareMenuAction.systemShare,
                        );
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );

    if (!mounted || action == null) {
      await ShareFlowLogService.log(
        'DETAIL_SHARE_MENU_DISMISSED',
        data: <String, Object?>{'postId': postId, 'mounted': mounted},
      );
      return;
    }

    await ShareFlowLogService.log(
      'DETAIL_SHARE_ACTION_SELECTED',
      data: <String, Object?>{'postId': postId, 'action': action.name},
    );

    if (action == _PostDetailShareMenuAction.copyLink) {
      final link = _shareLinkFromPost(post);
      await Clipboard.setData(
        ClipboardData(text: link),
      );
      await ShareFlowLogService.log(
        'DETAIL_SHARE_COPY_LINK_DONE',
        data: <String, Object?>{'postId': postId, 'link': link},
      );
      await _shareCurrentPost(post, silent: true);
      if (!mounted) return;
      messenger?.showSnackBar(
        const SnackBar(content: Text('הקישור הועתק ללוח! 🔗')),
      );
      return;
    }

    if (action == _PostDetailShareMenuAction.systemShare) {
      await ShareFlowLogService.log(
        'DETAIL_SHARE_SYSTEM_START',
        data: <String, Object?>{'postId': postId},
      );
      await SharePlus.instance.share(
        ShareParams(text: _shareTextFromPost(post)),
      );
      await ShareFlowLogService.log(
        'DETAIL_SHARE_SYSTEM_DONE',
        data: <String, Object?>{'postId': postId},
      );
      await _shareCurrentPost(post, silent: true);
      return;
    }

    await ShareFlowLogService.log(
      'DETAIL_SHARE_TARGETS_SHEET_OPEN',
      data: <String, Object?>{'postId': postId},
    );
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => PostShareTargetsSheet(
        postPayload: _sharePayloadFromPost(post),
        onShareSent: () => _shareCurrentPost(post, silent: false),
      ),
    );
    await ShareFlowLogService.log(
      'DETAIL_SHARE_TARGETS_SHEET_CLOSED',
      data: <String, Object?>{'postId': postId},
    );
  }

  Future<void> _openCommentsForCurrentPost(
    Map<String, dynamic> post, {
    String initialCommentId = '',
  }) async {
    final postId = _postId(post);
    final authorId = _postAuthorId(post);
    if (postId.isEmpty) return;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => PostCommentsSheet(
        postId: postId,
        postAuthorId: authorId,
        initialCommentId: initialCommentId,
        onCommentSubmitted: () {
          final current =
              _countFromData(_posts[_currentIndex], 'commentsCount');
          if (!mounted) return;
          setState(() {
            _posts[_currentIndex] = <String, dynamic>{
              ..._posts[_currentIndex],
              'commentsCount': current + 1,
            };
          });
          _refreshPostAtIndex(_currentIndex);
        },
      ),
    );

    await _refreshPostAtIndex(_currentIndex);
  }

  Widget _buildPostPage(Map<String, dynamic> post, {required bool isActive}) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final title = _derivedTitle(post);
    final description = ((post['description'] as String?) ??
            (post['caption'] as String?) ??
            (post['content'] as String?) ??
            '')
        .trim();
    final effectiveDescription = description;
    final category = (post['category'] as String? ?? '').trim();
    final likesCount =
        _countFromAny(post, ['likesCount', 'likes_count'], listKey: 'likes');
    final commentsCount = _countFromAny(
        post, ['commentsCount', 'comments_count'],
        listKey: 'comments');
    final sharesCount = _countFromAny(post, ['sharesCount', 'shares_count']);
    final savesCount =
        _countFromAny(post, ['savesCount', 'saves_count'], listKey: 'savedBy');
    final createdAt = _createdAt(post);
    final postTimestamp = _formatPostTimestamp(createdAt);
    final locationText = _locationText(post);
    final scoreAwarded = _scoreAwarded(post);
    final participantUids = _participantUids(post, includeAuthor: false);
    final participantsCount = participantUids.length;
    final linkedGroupId = (post['linkedGroupId'] as String? ?? '').trim();
    final hasLinkedGroup = linkedGroupId.isNotEmpty;
    final contributionScore = _postContributionScore(
      scoreAwarded: scoreAwarded,
      likesCount: likesCount,
      commentsCount: commentsCount,
      sharesCount: sharesCount,
      savesCount: savesCount,
    );
    final categoryIcon = _categoryIcon(category);
    final likedByMe = _isLikedByMe(post);
    final savedByMe = _isSavedByMe(post);
    final postId = _postId(post);

    final authorProfile = _authorProfileForPost(post);
    final canOpenProfile = authorProfile.userId.isNotEmpty &&
        !(widget.disableOwnAuthorProfileTap && _isOwnedByCurrentUser(post));
    final openAuthorProfileTap = canOpenProfile
        ? () async {
            await _pushWithDetailPlaybackPaused(
              MaterialPageRoute(
                builder: (_) => UserProfileScreen(
                  uid: authorProfile.userId,
                  currentBottomIndex: 0,
                ),
              ),
            );
          }
        : null;

    Widget buildAuthorIdentity({required bool compact}) {
      return Align(
        alignment: Alignment.centerRight,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: compact ? 8 : 10,
                    vertical: compact ? 4 : 5,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(999),
                    color: isLight ? Colors.white.withValues(alpha: 0.9) : null,
                    gradient: isLight
                        ? null
                        : LinearGradient(
                            colors: [
                              const Color(0xFF132238).withValues(alpha: 0.9),
                              const Color(0xFF261A46).withValues(alpha: 0.9),
                            ],
                            begin: Alignment.centerLeft,
                            end: Alignment.centerRight,
                          ),
                    border: Border.all(
                      color: isLight
                          ? const Color(0xFFA9C3FF)
                          : const Color(0xFF46D3FF).withValues(alpha: 0.35),
                      width: isLight ? 1.8 : 1,
                    ),
                  ),
                  child: Text(
                    authorProfile.exists
                        ? authorProfile.handle
                        : 'משתמש לא נמצא',
                    style: TextStyle(
                      color: isLight ? Colors.black : const Color(0xFFEAF4FF),
                      fontSize: compact ? 12.5 : 14,
                      fontWeight: FontWeight.w800,
                      fontFamily: 'Segoe UI',
                    ),
                  ),
                ),
              ],
            ),
            SizedBox(width: compact ? 6 : 10),
            _buildProfileAvatar(
              authorProfile.profilePictureUrl,
              size: compact ? 38 : 44,
            ),
          ],
        ),
      );
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onDoubleTapDown: (_) {
        unawaited(_toggleLikeForCurrentPost(post));
      },
      onDoubleTap: () {},
      child: Container(
        color: isLight ? const Color(0xFFF2F7FF) : const Color(0xFF0B1019),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Stack(
            children: [
              Positioned.fill(child: _buildMedia(post, isActive: isActive)),
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.black.withValues(alpha: 0.12),
                          Colors.transparent,
                          Colors.black.withValues(alpha: 0.55),
                        ],
                        stops: const [0.0, 0.45, 1.0],
                      ),
                    ),
                  ),
                ),
              ),
              if (!_experimentalPostHeaderLayout)
                Positioned(
                  top: 76,
                  right: 20,
                  child: GestureDetector(
                    onTap: openAuthorProfileTap,
                    child: buildAuthorIdentity(compact: false),
                  ),
                ),
              if (!_experimentalPostHeaderLayout)
                Positioned(
                  top: 78,
                  left: 20,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 15, vertical: 8),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(999),
                      color:
                          isLight ? Colors.white.withValues(alpha: 0.92) : null,
                      gradient: isLight
                          ? null
                          : LinearGradient(
                              colors: [
                                const Color(0xFF15263F).withValues(alpha: 0.94),
                                const Color(0xFF2F1F54).withValues(alpha: 0.94),
                              ],
                            ),
                      border: Border.all(
                        color: isLight
                            ? const Color(0xFFA9C3FF)
                            : const Color(0xFF46D3FF).withValues(alpha: 0.34),
                        width: isLight ? 2.0 : 1,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color:
                              const Color(0xFF46D3FF).withValues(alpha: 0.24),
                          blurRadius: 12,
                          spreadRadius: 0.5,
                        ),
                      ],
                    ),
                    child: Text(
                      '+$contributionScore',
                      style: TextStyle(
                        color: isLight
                            ? const Color(0xFF6A5BFF)
                            : const Color(0xFF9EDBFF),
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              if (_postAudience(post) == 'friends')
                Positioned(
                  top: 78,
                  left: _experimentalPostHeaderLayout ? 20 : 96,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(999),
                      gradient: const LinearGradient(
                        colors: [Color(0xFFFFF7EF), Color(0xFFFFB36B)],
                        begin: Alignment.centerLeft,
                        end: Alignment.centerRight,
                      ),
                      border: Border.all(
                        color: const Color(0xFFFF8A2A).withValues(alpha: 0.72),
                      ),
                    ),
                    child: const Text(
                      'חברים',
                      style: TextStyle(
                        color: Color(0xFF9A4B00),
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              Positioned(
                left: 20,
                bottom: 24,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_experimentalPostHeaderLayout) ...[
                      SizedBox(
                        width: 52,
                        height: 52,
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Container(
                              width: 52,
                              height: 52,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: isLight
                                    ? Colors.white.withValues(alpha: 0.92)
                                    : null,
                                gradient: isLight
                                    ? null
                                    : LinearGradient(
                                        colors: [
                                          const Color(0xFF15263F)
                                              .withValues(alpha: 0.94),
                                          const Color(0xFF2F1F54)
                                              .withValues(alpha: 0.94),
                                        ],
                                      ),
                                border: Border.all(
                                  color: isLight
                                      ? const Color(0xFFA9C3FF)
                                      : const Color(0xFF46D3FF)
                                          .withValues(alpha: 0.34),
                                  width: isLight ? 2.0 : 1,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: const Color(0xFF46D3FF)
                                        .withValues(alpha: 0.24),
                                    blurRadius: 12,
                                    spreadRadius: 0.5,
                                  ),
                                ],
                              ),
                              child: Center(
                                child: Text(
                                  '$contributionScore',
                                  style: TextStyle(
                                    color: isLight
                                        ? const Color(0xFF6A5BFF)
                                        : const Color(0xFF9EDBFF),
                                    fontSize: 14,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                            ),
                            Positioned(
                              bottom: -5,
                              right: 9,
                              child: Container(
                                width: 34,
                                height: 14,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(999),
                                  color: isLight
                                      ? const Color(0xFF5A6CFF)
                                      : const Color(0xFF9EDBFF),
                                ),
                                child: Center(
                                  child: Text(
                                    'ניקוד',
                                    style: TextStyle(
                                      color: isLight
                                          ? Colors.white
                                          : const Color(0xFF0F1D31),
                                      fontWeight: FontWeight.w900,
                                      fontSize: 8.5,
                                      height: 1,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),
                    ],
                    _buildActionIcon(
                      icon: likedByMe
                          ? Icons.favorite_rounded
                          : Icons.favorite_border_rounded,
                      iconColor: likedByMe
                          ? const Color(0xFF8C62FF)
                          : const Color(0xFF9EDBFF),
                      label: _formatCount(likesCount),
                      onTap: () => _toggleLikeForCurrentPost(post),
                      isActive: likedByMe,
                      isBusy: _likeInFlightPostIds.contains(postId),
                      labelSpacing: 0,
                      isLight: isLight,
                    ),
                    const SizedBox(height: 20),
                    _buildActionIcon(
                      icon: Icons.chat_bubble_outline_rounded,
                      iconColor: const Color(0xFF9EDBFF),
                      label: _formatCount(commentsCount),
                      onTap: () => _openCommentsForCurrentPost(post),
                      labelSpacing: 0,
                      isLight: isLight,
                    ),
                    const SizedBox(height: 20),
                    _buildActionIcon(
                      icon: savedByMe
                          ? Icons.bookmark_rounded
                          : Icons.bookmark_border_rounded,
                      iconColor: savedByMe
                          ? const Color(0xFF8C62FF)
                          : const Color(0xFF9EDBFF),
                      label: _formatCount(savesCount),
                      onTap: () => _toggleSaveForCurrentPost(post),
                      isActive: savedByMe,
                      isBusy: _saveInFlightPostIds.contains(postId),
                      isLight: isLight,
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        GestureDetector(
                          onTap: () async {
                            await _pushWithDetailPlaybackPaused(
                              MaterialPageRoute(
                                builder: (_) => CategoryScreen(
                                  categoryName: category,
                                  initialPost: Map<String, dynamic>.from(post),
                                ),
                              ),
                            );
                          },
                          child: Container(
                            width: 50,
                            height: 50,
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(
                                colors: [Color(0xFF8C62FF), Color(0xFF46D3FF)],
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                              ),
                              shape: BoxShape.circle,
                              border:
                                  Border.all(color: const Color(0xFFA9C3FF)),
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(0xFF46D3FF)
                                      .withValues(alpha: 0.35),
                                  blurRadius: 16,
                                  spreadRadius: 1,
                                ),
                              ],
                            ),
                            child: Container(
                              margin: const EdgeInsets.all(1.4),
                              decoration: BoxDecoration(
                                color: isLight
                                    ? Colors.white
                                    : const Color(0xFF172235),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                categoryIcon,
                                color: isLight
                                    ? const Color(0xFF5A6CFF)
                                    : const Color(0xFFEAF4FF),
                                size: 22,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        GestureDetector(
                          onTap: () => _openParticipantsSheet(post),
                          child: Container(
                            width: hasLinkedGroup ? 56 : 50,
                            height: hasLinkedGroup ? 56 : 50,
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(
                                colors: [Color(0xFF8C62FF), Color(0xFF46D3FF)],
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                              ),
                              shape: BoxShape.circle,
                              border:
                                  Border.all(color: const Color(0xFFA9C3FF)),
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(0xFF46D3FF)
                                      .withValues(alpha: 0.35),
                                  blurRadius: hasLinkedGroup ? 20 : 16,
                                  spreadRadius: hasLinkedGroup ? 1.8 : 1,
                                ),
                              ],
                            ),
                            child: Container(
                              margin:
                                  EdgeInsets.all(hasLinkedGroup ? 3.0 : 1.4),
                              decoration: BoxDecoration(
                                color: isLight
                                    ? Colors.white
                                    : const Color(0xFF172235),
                                shape: BoxShape.circle,
                              ),
                              child: hasLinkedGroup
                                  ? Stack(
                                      alignment: Alignment.center,
                                      children: [
                                        const Positioned(
                                          top: 8,
                                          left: 8,
                                          child: Icon(
                                            Icons.person_rounded,
                                            size: 10,
                                            color: Color(0xFF5A6CFF),
                                          ),
                                        ),
                                        const Positioned(
                                          top: 8,
                                          right: 8,
                                          child: Icon(
                                            Icons.person_rounded,
                                            size: 10,
                                            color: Color(0xFF5A6CFF),
                                          ),
                                        ),
                                        const Positioned(
                                          bottom: 8,
                                          left: 8,
                                          child: Icon(
                                            Icons.person_rounded,
                                            size: 10,
                                            color: Color(0xFF5A6CFF),
                                          ),
                                        ),
                                        const Positioned(
                                          bottom: 8,
                                          right: 8,
                                          child: Icon(
                                            Icons.person_rounded,
                                            size: 10,
                                            color: Color(0xFF5A6CFF),
                                          ),
                                        ),
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 4,
                                            vertical: 2,
                                          ),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFFEFF4FF),
                                            borderRadius:
                                                BorderRadius.circular(999),
                                            border: Border.all(
                                              color: const Color(0xFFA9C3FF),
                                            ),
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              if (participantsCount > 0)
                                                Text(
                                                  participantsCount.toString(),
                                                  style: const TextStyle(
                                                    color: Color(0xFF5A6CFF),
                                                    fontSize: 9,
                                                    fontWeight: FontWeight.w800,
                                                  ),
                                                )
                                              else
                                                const Icon(
                                                  Icons.link_rounded,
                                                  size: 10,
                                                  color: Color(0xFF5A6CFF),
                                                ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    )
                                  : Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        Icon(
                                          Icons.group_rounded,
                                          color: isLight
                                              ? const Color(0xFF5A6CFF)
                                              : const Color(0xFFEAF4FF),
                                          size: 16,
                                        ),
                                        Text(
                                          participantsCount.toString(),
                                          style: TextStyle(
                                            color: isLight
                                                ? const Color(0xFF5A6CFF)
                                                : const Color(0xFFEAF4FF),
                                            fontSize: 11,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ],
                                    ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        GestureDetector(
                          onTap: () => _openShareMenuForCurrentPost(post),
                          child: Container(
                            width: 50,
                            height: 50,
                            decoration: BoxDecoration(
                              color: isLight ? Colors.white : null,
                              gradient: isLight
                                  ? const LinearGradient(
                                      colors: [
                                        Color(0xFF8C62FF),
                                        Color(0xFF46D3FF),
                                      ],
                                      begin: Alignment.topLeft,
                                      end: Alignment.bottomRight,
                                    )
                                  : const LinearGradient(
                                      colors: [
                                        Color(0xFF8C62FF),
                                        Color(0xFF46D3FF),
                                      ],
                                      begin: Alignment.topLeft,
                                      end: Alignment.bottomRight,
                                    ),
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: const Color(0xFFA9C3FF),
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(0xFF46D3FF)
                                      .withValues(alpha: 0.24),
                                  blurRadius: 14,
                                  spreadRadius: 0.4,
                                ),
                              ],
                            ),
                            child: Container(
                              margin: const EdgeInsets.all(1.4),
                              decoration: BoxDecoration(
                                color: isLight
                                    ? Colors.white
                                    : const Color(0xFF172235),
                                shape: BoxShape.circle,
                              ),
                              child: _shareInFlightPostIds.contains(postId)
                                  ? const Padding(
                                      padding: EdgeInsets.all(14),
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Color(0xFF46D3FF),
                                      ),
                                    )
                                  : Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        Icon(
                                          Icons.send_rounded,
                                          color: isLight
                                              ? const Color(0xFF5A6CFF)
                                              : const Color(0xFFEAF4FF),
                                          size: 16,
                                        ),
                                        Text(
                                          _formatCount(sharesCount),
                                          style: TextStyle(
                                            color: isLight
                                                ? const Color(0xFF5A6CFF)
                                                : const Color(0xFFEAF4FF),
                                            fontSize: 11,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ],
                                    ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Positioned(
                right: 20,
                bottom: 46,
                left: 120,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (_experimentalPostHeaderLayout) ...[
                      GestureDetector(
                        onTap: openAuthorProfileTap,
                        child: buildAuthorIdentity(compact: true),
                      ),
                      const SizedBox(height: 6),
                    ],
                    if (title.isNotEmpty)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        child: Text(
                          title,
                          textAlign: TextAlign.right,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 21,
                            fontWeight: FontWeight.w800,
                            fontFamily: 'Avenir Next',
                            fontFamilyFallback: [
                              'SF Pro Rounded',
                              'Rubik',
                              'Assistant',
                              'Noto Sans Hebrew',
                              'Segoe UI',
                              'sans-serif',
                            ],
                            height: 1.12,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    if (effectiveDescription.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 7),
                        child: Text(
                          effectiveDescription,
                          textAlign: TextAlign.right,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            fontFamily: 'Avenir Next',
                            fontFamilyFallback: [
                              'SF Pro Rounded',
                              'Rubik',
                              'Assistant',
                              'Noto Sans Hebrew',
                              'Segoe UI',
                              'sans-serif',
                            ],
                            height: 1.28,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                    if (postTimestamp.isNotEmpty ||
                        locationText.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Wrap(
                        alignment: WrapAlignment.end,
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          if (postTimestamp.isNotEmpty)
                            _buildMetaChip(
                              icon: Icons.schedule_rounded,
                              text: postTimestamp,
                            ),
                          if (locationText.isNotEmpty)
                            _buildMetaChip(
                              icon: Icons.location_on_rounded,
                              text: locationText,
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildActionIcon({
    required IconData icon,
    required Color iconColor,
    required String label,
    required VoidCallback onTap,
    bool isActive = false,
    bool isBusy = false,
    double labelSpacing = 2,
    bool isLight = false,
  }) {
    final isActiveLight = isActive && isLight;

    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            width: 50,
            height: 50,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: isActive
                  ? const LinearGradient(
                      colors: [Color(0xFF8C62FF), Color(0xFF46D3FF)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    )
                  : null,
              color: isActive
                  ? null
                  : (isLight
                      ? Colors.white.withValues(alpha: 0.92)
                      : const Color(0xFF121D2E).withValues(alpha: 0.84)),
              border: Border.all(
                color: isActiveLight
                    ? Colors.transparent
                    : isLight
                        ? const Color(0xFFA9C3FF)
                        : const Color(0xFF46D3FF).withValues(alpha: 0.35),
              ),
              boxShadow: isActiveLight
                  ? [
                      BoxShadow(
                        color: const Color(0xFF6CCBFF).withValues(alpha: 0.36),
                        blurRadius: 14,
                        spreadRadius: 0.6,
                      ),
                    ]
                  : null,
            ),
            child: isBusy
                ? const Padding(
                    padding: EdgeInsets.all(13),
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : isActiveLight
                    ? Container(
                        margin: const EdgeInsets.all(2.0),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white.withValues(alpha: 0.96),
                        ),
                        child: Center(
                          child: ShaderMask(
                            shaderCallback: (bounds) {
                              return const LinearGradient(
                                colors: [
                                  Color(0xFF8B7CFF),
                                  Color(0xFF54CCFF),
                                ],
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                              ).createShader(bounds);
                            },
                            blendMode: BlendMode.srcIn,
                            child: Icon(
                              icon,
                              color: Colors.white,
                              size: 25,
                            ),
                          ),
                        ),
                      )
                    : Icon(
                        icon,
                        color: isActive
                            ? Colors.white
                            : (isLight ? const Color(0xFF5A6CFF) : iconColor),
                        size: 25,
                      ),
          ),
          SizedBox(height: labelSpacing),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMetaChip({required IconData icon, required String text}) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: isLight ? Colors.white.withValues(alpha: 0.9) : null,
        gradient: isLight
            ? null
            : LinearGradient(
                colors: [
                  const Color(0xFF15263F).withValues(alpha: 0.9),
                  const Color(0xFF2F1F54).withValues(alpha: 0.9),
                ],
              ),
        border: Border.all(
          color: isLight
              ? const Color(0xFFA9C3FF)
              : const Color(0xFF46D3FF).withValues(alpha: 0.26),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            color: isLight ? const Color(0xFF5A6CFF) : const Color(0xFF9EDBFF),
            size: 13,
          ),
          const SizedBox(width: 5),
          Text(
            text,
            style: TextStyle(
              color: isLight ? Colors.black : const Color(0xFF9EDBFF),
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  PostModel _editablePostModelFromMap(Map<String, dynamic> post) {
    final postId =
        (post['postId'] as String? ?? post['id'] as String? ?? '').trim();
    final authorId =
        (post['authorId'] as String? ?? post['uid'] as String? ?? '').trim();
    final category = (post['category'] as String? ?? 'כללי').trim().isNotEmpty
        ? (post['category'] as String? ?? 'כללי').trim()
        : 'כללי';
    final subCategory = (post['subCategory'] as String? ?? '').trim();
    final title = (post['title'] as String? ?? '').trim();
    final description = ((post['description'] as String?) ??
            (post['caption'] as String?) ??
            (post['content'] as String?) ??
            '')
        .trim();
    final profileImage = (post['profilePictureUrl'] as String? ??
            post['profileImageUrl'] as String? ??
            post['avatarUrl'] as String? ??
            '')
        .trim();
    final participantUids = (post['members'] as List<dynamic>? ??
            post['participants'] as List<dynamic>? ??
            const <dynamic>[])
        .map((e) => e.toString().trim())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList(growable: false);
    final mediaItems = postMediaItemsFromData(post);
    final mediaUrls = mediaItems
        .map((item) => item.url.trim())
        .where((url) => url.isNotEmpty)
        .toList(growable: false);
    final primaryMedia = mediaUrls.isNotEmpty
        ? mediaUrls.first
        : ((post['imageUrl'] as String?) ?? (post['mediaUrl'] as String?) ?? '')
            .trim();

    return PostModel(
      id: postId,
      authorId: authorId,
      category: category,
      subCategory: subCategory,
      colors: const <Color>[Color(0xFF2A2F3A), Color(0xFF1E2632)],
      title: title,
      description: description,
      content: description,
      authorProfileImg: profileImage,
      participantUids: participantUids,
      linkedGroupId: (post['linkedGroupId'] as String? ?? '').trim(),
      isDraft:
          ((post['status'] as String? ?? '').trim().toLowerCase() == 'draft'),
      imageUrl: primaryMedia,
      mediaUrls: mediaUrls,
      mediaItems: mediaItems,
      eventGroupId: (post['eventGroupId'] as String? ?? '').trim(),
    );
  }

  Future<T?> _pushWithDetailPlaybackPaused<T>(Route<T> route) async {
    if (mounted) {
      setState(() {
        _isDetailViewInForeground = false;
      });
    }

    try {
      return await Navigator.of(context).push(route);
    } finally {
      if (mounted) {
        setState(() {
          _isDetailViewInForeground = true;
        });
      }
    }
  }

  Future<void> _openEditForCurrentPost() async {
    if (_currentIndex < 0 || _currentIndex >= _posts.length) {
      return;
    }
    final currentPost = _posts[_currentIndex];
    final editablePost = _editablePostModelFromMap(currentPost);

    if (mounted) {
      setState(() {
        _isDetailViewInForeground = false;
      });
    }

    final updated = await Navigator.of(context)
        .push(
      MaterialPageRoute(
        builder: (_) => PostEditScreen(
          isEdit: true,
          post: editablePost,
          initialCategory: editablePost.category,
          initialSubCategory: editablePost.subCategory,
          initialLocation: _locationText(currentPost),
          initialParticipantUids:
              _participantUids(currentPost, includeAuthor: false),
        ),
      ),
    )
        .whenComplete(() {
      if (mounted) {
        setState(() {
          _isDetailViewInForeground = true;
        });
      }
    });

    if (!mounted || updated is! Map) {
      return;
    }

    final updatedMap = Map<String, dynamic>.from(updated);
    final current = Map<String, dynamic>.from(_posts[_currentIndex]);
    final merged = <String, dynamic>{...current, ...updatedMap};
    setState(() {
      _posts[_currentIndex] = merged;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    if (_posts.isEmpty) {
      return Scaffold(
        backgroundColor: isLight ? Colors.white : const Color(0xFF0B1019),
        appBar: AppBar(
          backgroundColor: isLight ? Colors.white : const Color(0xFF1E2632),
          elevation: 0,
          iconTheme:
              IconThemeData(color: isLight ? Colors.black : Colors.white),
          title: const SizedBox.shrink(),
          leading: IconButton(
            onPressed: () => Navigator.of(context).maybePop(),
            icon: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: isLight ? Colors.white : const Color(0xFF1E2632),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFF53C1F9)),
              ),
              child: const Icon(
                Icons.arrow_left_rounded,
                color: Color(0xFF6A5BFF),
              ),
            ),
          ),
        ),
        body: Center(
          child: Text(
            'אין פופים להצגה',
            style: TextStyle(
              color: isLight ? Colors.black54 : Colors.white70,
            ),
          ),
        ),
      );
    }

    return SwipeBackWrapper(
      child: Scaffold(
        backgroundColor: isLight ? Colors.white : const Color(0xFF0B1019),
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          iconTheme:
              IconThemeData(color: isLight ? Colors.black : Colors.white),
          title: const SizedBox.shrink(),
          leading: IconButton(
            onPressed: () => Navigator.of(context).maybePop(),
            icon: ShaderMask(
              shaderCallback: (bounds) => const LinearGradient(
                colors: [Color(0xFF53C1F9), Color(0xFF9E7CFF)],
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
              ).createShader(bounds),
              child: const Icon(
                Icons.arrow_back_rounded,
                color: Colors.white,
                size: 32,
              ),
            ),
          ),
          actions: [
            if (_posts.isNotEmpty &&
                _currentIndex >= 0 &&
                _currentIndex < _posts.length &&
                !_isOwnedByCurrentUser(_posts[_currentIndex]))
              IconButton(
                tooltip: 'דיווח על פוסט',
                onPressed: _reportCurrentPost,
                icon: const Icon(
                  Icons.flag_outlined,
                  color: Colors.white70,
                  size: 24,
                ),
              ),
            if (widget.enableEditAction)
              widget.useDraftPublishEditAction
                  ? Padding(
                      padding: const EdgeInsetsDirectional.only(end: 8),
                      child: TextButton(
                        onPressed: _openEditForCurrentPost,
                        style: TextButton.styleFrom(
                          foregroundColor:
                              isLight ? const Color(0xFF9E7CFF) : Colors.white,
                          backgroundColor:
                              isLight ? Colors.white : const Color(0xFF9E7CFF),
                          side: isLight
                              ? const BorderSide(color: Color(0xFF9E7CFF))
                              : BorderSide.none,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        child: Text(
                          'ערוך ופרסם',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: isLight
                                ? const Color(0xFF9E7CFF)
                                : Colors.black,
                          ),
                        ),
                      ),
                    )
                  : IconButton(
                      tooltip: 'ערוך פופ',
                      onPressed: _openEditForCurrentPost,
                      icon: ShaderMask(
                        shaderCallback: (bounds) => const LinearGradient(
                          colors: [Color(0xFF53C1F9), Color(0xFF9E7CFF)],
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                        ).createShader(bounds),
                        child: const Icon(
                          Icons.edit_rounded,
                          color: Colors.white,
                          size: 30,
                        ),
                      ),
                    ),
          ],
        ),
        body: Stack(
          children: [
            Positioned.fill(
              child: PageView.builder(
                controller: _pageController,
                scrollDirection: Axis.vertical,
                physics: const ClampingScrollPhysics(),
                itemCount: _posts.length,
                onPageChanged: (value) {
                  if (_currentIndex == value) return;
                  setState(() {
                    _currentIndex = value;
                  });
                },
                itemBuilder: (context, index) {
                  return _buildPostPage(
                    _posts[index],
                    isActive:
                        _isDetailViewInForeground && index == _currentIndex,
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LinkedGroupMeta {
  final String groupId;
  final String name;
  final String imageUrl;
  final bool isPublic;
  final bool isCurrentUserMember;
  final bool isCurrentUserPending;

  const _LinkedGroupMeta({
    required this.groupId,
    required this.name,
    required this.imageUrl,
    required this.isPublic,
    required this.isCurrentUserMember,
    required this.isCurrentUserPending,
  });
}
