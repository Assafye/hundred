import 'dart:async';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'create_post_screen.dart';
import 'feed_screen.dart';
import 'main_bottom_nav.dart';
import 'post_media_utils.dart';
import 'post_detail_view.dart';
import 'app_categories.dart';
import 'services/app_home_service.dart';
import 'services/block_user_service.dart';
import 'services/social_service.dart';
import 'services/spontaneous_challenge_service.dart';
import 'services/weekly_challenge_service.dart';
import 'widgets/swipe_back_wrapper.dart';

class StarsScreen extends StatefulWidget {
  final String initialPostId;
  final bool openSpontaneousModalOnStart;

  const StarsScreen({
    super.key,
    this.initialPostId = '',
    this.openSpontaneousModalOnStart = false,
  });

  @override
  State<StarsScreen> createState() => _StarsScreenState();
}

Future<void> showSpontaneousLotteryModal(
  BuildContext context, {
  required String userId,
}) async {
  final normalizedUserId = userId.trim();
  if (normalizedUserId.isEmpty || !context.mounted) {
    return;
  }

  await showDialog<bool>(
    context: context,
    useSafeArea: false,
    barrierDismissible: true,
    barrierColor: Colors.black54,
    builder: (_) => _SpontaneousChallengeDialog(userId: normalizedUserId),
  );
}

Future<void> showActiveSpontaneousTaskModal(
  BuildContext context, {
  required SpontaneousChallengeTask task,
}) async {
  if (!context.mounted) {
    return;
  }

  await showDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierColor: Colors.black54,
    builder: (_) => SafeArea(
      child: Center(
        child: _ActiveSpontaneousTaskDialog(initialTask: task),
      ),
    ),
  );
}

class _StarsSectionData {
  final String key;
  final String title;
  final String subtitle;
  final String emptyMessage;
  final List<Map<String, dynamic>> posts;

  const _StarsSectionData({
    required this.key,
    required this.title,
    required this.subtitle,
    required this.emptyMessage,
    required this.posts,
  });
}

List<Map<String, dynamic>> filterBlockedUserPostsForViewer(
  List<Map<String, dynamic>> posts, {
  required Set<String> blockedUserIds,
  required String currentUserId,
}) {
  return posts.where((post) {
    final authorId = ((post['authorId'] as String?) ??
            (post['uid'] as String?) ??
            '')
        .trim();
    if (authorId.isEmpty) {
      return true;
    }
    if (authorId == currentUserId) {
      return true;
    }
    return !blockedUserIds.contains(authorId);
  }).toList(growable: false);
}

List<MeetNowPostEntry> filterBlockedMeetNowEntries(
  List<MeetNowPostEntry> entries, {
  required Set<String> blockedUserIds,
}) {
  return entries
      .where((entry) => !blockedUserIds.contains(entry.authorUid.trim()))
      .toList(growable: false);
}

class _StarsScreenState extends State<StarsScreen> {
  late final WeeklyChallenge _challenge;
  late final BlockUserService _blockUserService = BlockUserService();
  late final StreamSubscription<Set<String>> _blockedUsersSub;
  late final Future<List<_StarsSectionData>> _hotSectionsFuture;
  final Set<String> _expandedSectionKeys = <String>{};
  bool _openedInitialPost = false;
  SpontaneousChallengeTask? _activeSpontaneousTask;
  Duration _activeSpontaneousRemaining = Duration.zero;
  Timer? _spontaneousCountdownTimer;
  final Map<String, Future<String?>> _resolvedMediaUrlByRawUrl =
      <String, Future<String?>>{};

  bool _isHttpUrl(String url) {
    final normalized = url.trim().toLowerCase();
    return normalized.startsWith('http://') ||
        normalized.startsWith('https://');
  }

  Future<String?> _resolveStorageMediaUrl(String rawUrl) async {
    final normalized = rawUrl.trim();
    if (normalized.isEmpty) {
      return null;
    }
    if (_isHttpUrl(normalized)) {
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
      return null;
    }
  }

  Future<String?> _resolvedMediaUrlFuture(String rawUrl) {
    return _resolvedMediaUrlByRawUrl.putIfAbsent(
      rawUrl,
      () => _resolveStorageMediaUrl(rawUrl),
    );
  }

  String _currentUserId() {
    return (FirebaseAuth.instance.currentUser?.uid ?? '').trim();
  }

  @override
  void initState() {
    super.initState();
    _challenge = WeeklyChallengeService.currentChallenge();
    _hotSectionsFuture = _buildHotSections();
    _blockedUsersSub = _blockUserService.streamBlockedConnections().listen((ids) {
      if (!mounted) {
        return;
      }
      setState(() {
        _hotSectionsFuture = _buildHotSections(blockedUserIds: ids);
      });
    });
    _loadActiveSpontaneousTask().then((_) {
      if (!mounted || !widget.openSpontaneousModalOnStart) {
        return;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) {
          return;
        }
        if (_activeSpontaneousTask != null) {
          await _openActiveSpontaneousTaskModal();
        } else {
          await _openSpontaneousChallengeModal();
        }
      });
    });
  }

  @override
  void dispose() {
    _spontaneousCountdownTimer?.cancel();
    _blockedUsersSub.cancel();
    super.dispose();
  }

  Future<void> _loadActiveSpontaneousTask() async {
    final userId = _currentUserId();
    if (userId.isEmpty) {
      if (!mounted) return;
      setState(() {
        _activeSpontaneousTask = null;
        _activeSpontaneousRemaining = Duration.zero;
      });
      return;
    }

    final task = await SpontaneousChallengeService.currentTaskForUser(userId);
    if (!mounted) return;

    _spontaneousCountdownTimer?.cancel();
    setState(() {
      _activeSpontaneousTask = task;
      _activeSpontaneousRemaining =
          task?.remainingAt(DateTime.now().toUtc()) ?? Duration.zero;
    });
    _startSpontaneousCountdownIfNeeded();
  }

  void _startSpontaneousCountdownIfNeeded() {
    _spontaneousCountdownTimer?.cancel();
    final task = _activeSpontaneousTask;
    if (task == null) return;

    _spontaneousCountdownTimer =
        Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }

      final remaining = task.remainingAt(DateTime.now().toUtc());
      if (remaining == Duration.zero) {
        timer.cancel();
        setState(() {
          _activeSpontaneousTask = null;
          _activeSpontaneousRemaining = Duration.zero;
        });
        return;
      }

      setState(() {
        _activeSpontaneousRemaining = remaining;
      });
    });
  }

  String _formatCountdownWithSeconds(Duration remaining) {
    final totalSeconds = max(0, remaining.inSeconds);
    final days = totalSeconds ~/ Duration.secondsPerDay;
    final remainingAfterDays = totalSeconds % Duration.secondsPerDay;
    final hours = remainingAfterDays ~/ Duration.secondsPerHour;
    final minutes = (remainingAfterDays % Duration.secondsPerHour) ~/
        Duration.secondsPerMinute;
    final seconds = remainingAfterDays % Duration.secondsPerMinute;

    final hhmmss =
        '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';

    if (totalSeconds > (48 * Duration.secondsPerHour)) {
      return '$days ימים $hhmmss';
    }

    return hhmmss;
  }

  int _scoreOf(Map<String, dynamic> post) {
    int intFrom(List<String> keys, {int fallback = 0}) {
      for (final key in keys) {
        final raw = post[key];
        if (raw is num) return raw.toInt();
        if (raw is String) {
          final parsed = int.tryParse(raw.trim());
          if (parsed != null) return parsed;
        }
      }
      return fallback;
    }

    final scoreAwarded = intFrom(const ['scoreAwarded']);
    final likesCount = intFrom(
      const ['likesCount', 'likes_count'],
      fallback: ((post['likes'] as List<dynamic>?) ?? const <dynamic>[]).length,
    );
    final commentsCount = intFrom(
      const ['commentsCount', 'comments_count'],
      fallback:
          ((post['comments'] as List<dynamic>?) ?? const <dynamic>[]).length,
    );
    final sharesCount = intFrom(const ['sharesCount', 'shares_count']);
    final savesCount = intFrom(
      const ['savesCount', 'saves_count'],
      fallback:
          ((post['savedBy'] as List<dynamic>?) ?? const <dynamic>[]).length,
    );
    return scoreAwarded +
        likesCount +
        (commentsCount * 2) +
        (sharesCount * 3) +
        savesCount;
  }

  DateTime _createdAt(Map<String, dynamic> post) {
    final raw = post['createdAt'];
    if (raw is Timestamp) return raw.toDate();
    if (raw is DateTime) return raw;
    if (raw is String) {
      return DateTime.tryParse(raw) ?? DateTime.fromMillisecondsSinceEpoch(0);
    }
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  Map<String, dynamic> _toPostMap(
      QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    final data = Map<String, dynamic>.from(doc.data());
    data['id'] = doc.id;
    data['postId'] = (data['postId'] as String? ?? doc.id).trim();
    return data;
  }

  bool _isInLastWeek(DateTime date, DateTime nowUtc) {
    return !date.isBefore(nowUtc.subtract(const Duration(days: 7)));
  }

  String _postAudience(Map<String, dynamic> post) {
    return (post['audience'] as String? ?? 'public').trim().toLowerCase();
  }

  Future<List<Map<String, dynamic>>> _filterVisiblePostsForViewer(
    List<Map<String, dynamic>> posts, {
    Set<String> blockedUserIds = const <String>{},
  }) async {
    final currentUid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
    final baseVisible = posts.where((post) {
      final audience = _postAudience(post);
      if (audience != 'friends') {
        return true;
      }

      final authorId = ((post['authorId'] as String?) ??
              (post['uid'] as String?) ??
              '')
          .trim();
      if (authorId.isEmpty || authorId == currentUid) {
        return true;
      }

      return !blockedUserIds.contains(authorId);
    }).toList(growable: false);

    if (currentUid.isEmpty) {
      return filterBlockedUserPostsForViewer(
        baseVisible,
        blockedUserIds: blockedUserIds,
        currentUserId: currentUid,
      ).where((post) => _postAudience(post) != 'friends').toList(growable: false);
    }

    final socialService = SocialService();
    final visible = <Map<String, dynamic>>[];
    for (final post in baseVisible) {
      final audience = _postAudience(post);
      if (audience != 'friends') {
        visible.add(post);
        continue;
      }

      final authorId = ((post['authorId'] as String?) ??
              (post['uid'] as String?) ??
              '')
          .trim();
      if (authorId.isEmpty || authorId == currentUid) {
        visible.add(post);
        continue;
      }

      final isMutual = await socialService.isMutualFollow(authorId);
      if (isMutual) {
        visible.add(post);
      }
    }
    return filterBlockedUserPostsForViewer(
      visible,
      blockedUserIds: blockedUserIds,
      currentUserId: currentUid,
    );
  }

  List<Map<String, dynamic>> _topPosts(
    Iterable<Map<String, dynamic>> source, {
    int limit = 10,
  }) {
    final sorted = source.toList(growable: false)
      ..sort((a, b) {
        final byScore = _scoreOf(b).compareTo(_scoreOf(a));
        if (byScore != 0) return byScore;
        return _createdAt(b).compareTo(_createdAt(a));
      });

    if (sorted.length <= limit) {
      return sorted;
    }
    return sorted.take(limit).toList(growable: false);
  }

  Future<List<_StarsSectionData>> _buildHotSections({
    Set<String> blockedUserIds = const <String>{},
  }) async {
    final now = DateTime.now().toUtc();

    final weeklyCategoryDocsFuture = FirebaseFirestore.instance
        .collection('posts')
        .where('status', isEqualTo: 'published')
        .where('category', isEqualTo: _challenge.mainCategory)
        .orderBy('createdAt', descending: true)
        .limit(800)
        .get();

    final weeklyAllDocsFuture = FirebaseFirestore.instance
        .collection('posts')
        .where('status', isEqualTo: 'published')
        .orderBy('createdAt', descending: true)
        .limit(1200)
        .get();

    final results =
        await Future.wait([weeklyCategoryDocsFuture, weeklyAllDocsFuture]);

    final weeklyCategoryPosts =
        results[0].docs.map(_toPostMap).toList(growable: false);

    final allRecentPosts =
        results[1].docs.map(_toPostMap).toList(growable: false);

    final visibleWeeklyCategoryPosts = await _filterVisiblePostsForViewer(
      weeklyCategoryPosts,
      blockedUserIds: blockedUserIds,
    );
    final visibleAllRecentPosts = await _filterVisiblePostsForViewer(
      allRecentPosts,
      blockedUserIds: blockedUserIds,
    );

    final weeklySubCategoryPosts = _topPosts(
      visibleWeeklyCategoryPosts.where((post) {
        final subCategory = (post['subCategory'] as String? ?? '').trim();
        return subCategory == _challenge.subCategory &&
            _isInLastWeek(_createdAt(post).toUtc(), now);
      }),
    );

    final weeklyCategoryTopPosts = _topPosts(
      visibleWeeklyCategoryPosts.where(
        (post) => _isInLastWeek(_createdAt(post).toUtc(), now),
      ),
    );

    final weeklyGlobalTopPosts = _topPosts(
      visibleAllRecentPosts.where(
        (post) => _isInLastWeek(_createdAt(post).toUtc(), now),
      ),
    );

    return <_StarsSectionData>[
      _StarsSectionData(
        key: 'subcategory',
        title: 'תת הקטגוריה של היום',
        subtitle: '${_challenge.mainCategory} • ${_challenge.subCategory}',
        emptyMessage: 'עדיין אין פוסטים מדורגים בתת הקטגוריה של היום',
        posts: weeklySubCategoryPosts,
      ),
      _StarsSectionData(
        key: 'weekly-category',
        title: 'קטגוריית כוכבי השבוע',
        subtitle: _challenge.mainCategory,
        emptyMessage: 'עדיין אין מספיק פוסטים מדורגים בקטגוריית השבוע',
        posts: weeklyCategoryTopPosts,
      ),
      _StarsSectionData(
        key: 'weekly-global',
        title: 'כוכבי השבוע הכלליים',
        subtitle: 'כל הקטגוריות של השבוע האחרון',
        emptyMessage: 'עדיין אין מספיק פוסטים מדורגים בכלל הקטגוריות השבוע',
        posts: weeklyGlobalTopPosts,
      ),
    ];
  }

  Future<List<Map<String, dynamic>>> _loadCategoryFeed(String category) async {
    final docs = await FirebaseFirestore.instance
        .collection('posts')
        .where('status', isEqualTo: 'published')
        .where('category', isEqualTo: category)
        .orderBy('createdAt', descending: true)
        .limit(600)
        .get();

    final posts = docs.docs.map(_toPostMap).toList(growable: false);
    return _filterVisiblePostsForViewer(
      posts,
      blockedUserIds: await BlockUserService().fetchBlockedConnections(),
    );
  }

  Future<void> _openPostInCategoryFeed(
      Map<String, dynamic> selectedPost) async {
    final category = (selectedPost['category'] as String? ?? '').trim();
    if (category.isEmpty) return;

    final posts = await _loadCategoryFeed(category);
    if (!mounted || posts.isEmpty) return;

    final selectedPostId = (selectedPost['postId'] as String? ??
            selectedPost['id'] as String? ??
            '')
        .trim();

    int initialIndex = posts.indexWhere((post) {
      final id =
          (post['postId'] as String? ?? post['id'] as String? ?? '').trim();
      return id == selectedPostId;
    });

    if (initialIndex < 0) {
      posts.insert(0, selectedPost);
      initialIndex = 0;
    }

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PostDetailView(
          posts: posts,
          initialIndex: initialIndex,
          disableOwnAuthorProfileTap: true,
          showOwnPostWeeklyStarsCelebration: true,
        ),
      ),
    );
  }

  void _maybeOpenInitialPost(List<_StarsSectionData> sections) {
    final initialPostId = widget.initialPostId.trim();
    if (_openedInitialPost || initialPostId.isEmpty || sections.isEmpty) {
      return;
    }

    final allPosts =
        sections.expand((section) => section.posts).toList(growable: false);

    final targetPost = allPosts.firstWhere(
      (post) {
        final id =
            (post['postId'] as String? ?? post['id'] as String? ?? '').trim();
        return id == initialPostId;
      },
      orElse: () => <String, dynamic>{},
    );

    if (targetPost.isEmpty) return;
    _openedInitialPost = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _openPostInCategoryFeed(targetPost);
    });
  }

  Widget _buildChallengeCard() {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(28),
          gradient: const LinearGradient(
            colors: [Color(0xFF9E7CFF), Color(0xFF53C1F9)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha:  0.25),
              blurRadius: 18,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(
              'אתגר השבוע',
              textAlign: TextAlign.center,
              textDirection: TextDirection.rtl,
              style: TextStyle(
                color: Colors.white.withValues(alpha:  0.95),
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '${_challenge.mainCategory} - ניקוד כפול X2',
              textAlign: TextAlign.center,
              textDirection: TextDirection.rtl,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 19,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 5),
            Text(
              '${_challenge.subCategory} - ניקוד משולש X3',
              textAlign: TextAlign.center,
              textDirection: TextDirection.rtl,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const CreatePostScreen()),
                  );
                },
                icon: const Icon(Icons.add_rounded, color: Colors.white),
                label: const Text(
                  'העלה פוסט לאתגר',
                  textDirection: TextDirection.rtl,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF9E7CFF),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(24.0),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Color _rankColor(int rank) {
    switch (rank) {
      case 0:
        return const Color(0xFFFFD166);
      case 1:
        return const Color(0xFFC7D3E6);
      case 2:
        return const Color(0xFFD8A47F);
      default:
        return const Color(0xFF9AB0FF);
    }
  }

  String _rankLabel(int rank) {
    switch (rank) {
      case 0:
        return '1';
      case 1:
        return '2';
      case 2:
        return '3';
      default:
        return '${rank + 1}';
    }
  }

  Widget _buildRankBadge(int rank, {required bool isLight}) {
    final color = _rankColor(rank);
    return Container(
      width: 34,
      height: 34,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withValues(alpha:  isLight ? 0.2 : 0.22),
        border: Border.all(color: color.withValues(alpha:  0.95)),
      ),
      child: Text(
        _rankLabel(rank),
        style: TextStyle(
          color: isLight ? const Color(0xFF1A2435) : Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }

  Widget _buildHotRow(Map<String, dynamic> post, int rank) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final title = (post['title'] as String? ?? '').trim().isNotEmpty
        ? (post['title'] as String).trim()
        : 'פוסט ללא כותרת';
    final category = (post['category'] as String? ?? '').trim();
    final subCategory = (post['subCategory'] as String? ?? '').trim();
    final score = _scoreOf(post);
    final mediaItems = postMediaItemsFromData(post);
    final primaryMediaRawUrl = mediaItems.isNotEmpty
        ? mediaItems.first.url.trim()
        : ((post['mediaUrl'] as String?) ??
                (post['imageUrl'] as String?) ??
                (((post['mediaUrls'] as List<dynamic>?) ?? const <dynamic>[])
                        .isNotEmpty
                    ? (post['mediaUrls'] as List<dynamic>).first.toString()
                    : ''))
            .trim();
    final isVideoMedia = mediaItems.isNotEmpty
        ? mediaItems.first.isVideo
        : isVideoMediaUrl(primaryMediaRawUrl);

    return InkWell(
      onTap: () => _openPostInCategoryFeed(post),
      borderRadius: BorderRadius.circular(18),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isLight ? Colors.white.withValues(alpha:  0.76) : null,
          gradient: isLight
              ? null
              : LinearGradient(
                  colors: [
                    const Color(0xFF18263D).withValues(alpha:  0.96),
                    const Color(0xFF2A2144).withValues(alpha:  0.96),
                  ],
                  begin: Alignment.topRight,
                  end: Alignment.bottomLeft,
                ),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: isLight
                ? const Color(0xFFA9C3FF)
                : const Color(0xFF53C1F9).withValues(alpha:  0.22),
          ),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF53C1F9).withValues(alpha:  0.08),
              blurRadius: 12,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: Row(
          textDirection: TextDirection.rtl,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Align(
                    alignment: Alignment.centerRight,
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      textDirection: TextDirection.rtl,
                      style: TextStyle(
                        color: isLight ? Colors.black : Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Text(
                      subCategory.isNotEmpty ? subCategory : 'ללא תת קטגוריה',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      textDirection: TextDirection.rtl,
                      style: TextStyle(
                        color: isLight ? Colors.black54 : Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      textDirection: TextDirection.rtl,
                      children: [
                        Text(
                          category,
                          textAlign: TextAlign.right,
                          textDirection: TextDirection.rtl,
                          style: TextStyle(
                            color: isLight ? Colors.black54 : Colors.white54,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: isLight
                                ? const Color(0xFFEAF2FF)
                                : const Color(0xFF101A2C),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(
                              color: const Color(0xFF53C1F9)
                                  .withValues(alpha:  0.32),
                            ),
                          ),
                          child: Text(
                            '+$score',
                            textDirection: TextDirection.rtl,
                            style: TextStyle(
                              color: isLight
                                  ? const Color(0xFF6B4BB6)
                                  : const Color(0xFF9EDBFF),
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            _buildRankBadge(rank, isLight: isLight),
            const SizedBox(width: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Container(
                width: 72,
                height: 72,
                color:
                    isLight ? const Color(0xFFEFF5FF) : const Color(0xFF222E45),
                child: primaryMediaRawUrl.isEmpty
                    ? const Icon(
                        Icons.image_not_supported_rounded,
                        color: Colors.white38,
                      )
                    : FutureBuilder<String?>(
                        future: _resolvedMediaUrlFuture(primaryMediaRawUrl),
                        builder: (context, snapshot) {
                          final resolvedUrl = (snapshot.data ?? '').trim();
                          if (resolvedUrl.isEmpty) {
                            if (snapshot.connectionState ==
                                ConnectionState.waiting) {
                              return const Center(
                                child: SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white70,
                                  ),
                                ),
                              );
                            }
                            return const Icon(
                              Icons.broken_image_outlined,
                              color: Colors.white38,
                            );
                          }

                          if (isVideoMedia) {
                            return _VideoCoverNetworkTile(url: resolvedUrl);
                          }

                          return Image.network(
                            resolvedUrl,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) {
                              return _VideoCoverNetworkTile(url: resolvedUrl);
                            },
                          );
                        },
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionCard(_StarsSectionData section) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final topThree = section.posts.take(3).toList(growable: false);
    final expandedPosts = section.posts.skip(3).take(7).toList(growable: false);
    final isExpanded = _expandedSectionKeys.contains(section.key);

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Container(
        margin: const EdgeInsets.fromLTRB(20, 0, 20, 14),
        padding: const EdgeInsets.fromLTRB(0, 18, 0, 14),
        decoration: BoxDecoration(
          color: isLight ? Colors.white.withValues(alpha:  0.74) : null,
          gradient: isLight
              ? null
              : LinearGradient(
                  colors: [
                    const Color(0xFF18263D).withValues(alpha:  0.97),
                    const Color(0xFF261F41).withValues(alpha:  0.97),
                  ],
                  begin: Alignment.topRight,
                  end: Alignment.bottomLeft,
                ),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: isLight
                ? const Color(0xFFA9C3FF)
                : const Color(0xFF53C1F9).withValues(alpha:  0.24),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Align(
                    alignment: Alignment.centerRight,
                    child: Text(
                      section.title,
                      textAlign: TextAlign.right,
                      textDirection: TextDirection.rtl,
                      style: TextStyle(
                        color: isLight ? Colors.black : Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Text(
                      section.subtitle,
                      textAlign: TextAlign.right,
                      textDirection: TextDirection.rtl,
                      style: TextStyle(
                        color:
                            isLight ? const Color(0xFF5F6D87) : Colors.white70,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            if (topThree.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 14, 18, 10),
                child: Text(
                  section.emptyMessage,
                  textAlign: TextAlign.center,
                  textDirection: TextDirection.rtl,
                  style: TextStyle(
                    color: isLight ? Colors.black54 : Colors.white70,
                  ),
                ),
              )
            else ...[
              for (int index = 0; index < topThree.length; index++)
                _buildHotRow(topThree[index], index),
              if (section.posts.length > 3)
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 0, 18, 4),
                  child: Align(
                    alignment: Alignment.center,
                    child: TextButton.icon(
                      onPressed: () {
                        setState(() {
                          if (isExpanded) {
                            _expandedSectionKeys.remove(section.key);
                          } else {
                            _expandedSectionKeys.add(section.key);
                          }
                        });
                      },
                      icon: Icon(
                        isExpanded
                            ? Icons.keyboard_arrow_up_rounded
                            : Icons.keyboard_arrow_down_rounded,
                        color: isLight
                            ? const Color(0xFF6B4BB6)
                            : const Color(0xFF9EDBFF),
                      ),
                      label: Text(
                        isExpanded ? 'סגור' : 'הראה עוד',
                        textDirection: TextDirection.rtl,
                        style: TextStyle(
                          color: isLight
                              ? const Color(0xFF6B4BB6)
                              : const Color(0xFF9EDBFF),
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                ),
              if (isExpanded)
                for (int index = 0; index < expandedPosts.length; index++)
                  _buildHotRow(expandedPosts[index], index + 3),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildTitle() {
    return ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (bounds) {
        return const LinearGradient(
          colors: [Color(0xFF53C1F9), Color(0xFF9E7CFF)],
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
        ).createShader(bounds);
      },
      child: const Text(
        'WEEKLY STARS',
        textAlign: TextAlign.center,
        style: TextStyle(
          color: Colors.white,
          fontSize: 28,
          fontWeight: FontWeight.w900,
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  Widget _buildBackButton() {
    final isLight = Theme.of(context).brightness == Brightness.light;
    return Align(
      alignment: Alignment.centerRight,
      child: IconButton(
        onPressed: () {
          Navigator.of(context).maybePop();
        },
        icon: Icon(
          Icons.arrow_back_rounded,
          color: isLight ? Colors.black : const Color(0xFF9EDBFF),
          size: 22,
        ),
        style: IconButton.styleFrom(
          padding: const EdgeInsets.all(8),
          backgroundColor: isLight
              ? Colors.white.withValues(alpha:  0.82)
              : const Color(0x221D2D46),
          side: BorderSide(
            color: isLight
                ? const Color(0xFFA9C3FF)
                : const Color(0xFF53C1F9).withValues(alpha:  0.28),
          ),
        ),
      ),
    );
  }

  Widget _buildSpontaneousBoostButton() {
    final width = MediaQuery.of(context).size.width < 390 ? 122.0 : 138.0;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _activeSpontaneousTask != null
              ? _openActiveSpontaneousTaskModal
              : _openSpontaneousChallengeModal,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            width: width,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              gradient: const LinearGradient(
                colors: [Color(0xFF8DE8FF), Color(0xFFC9B5FF)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF76CFFF).withValues(alpha:  0.4),
                  blurRadius: 14,
                  offset: const Offset(0, 7),
                ),
              ],
              border: Border.all(
                color: Colors.white.withValues(alpha:  0.65),
                width: 1.1,
              ),
            ),
            child: const Text(
              'ניקוד X5 לספונטניים',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Color(0xFF2A2361),
                fontSize: 12,
                fontWeight: FontWeight.w900,
                height: 1.15,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildActiveSubCategoryBubble() {
    final task = _activeSpontaneousTask;
    if (task == null) {
      return const SizedBox.shrink();
    }

    final width = MediaQuery.of(context).size.width < 390 ? 122.0 : 138.0;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _openActiveSpontaneousTaskModal,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            width: width,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              gradient: const LinearGradient(
                colors: [Color(0xFF8DE8FF), Color(0xFFC9B5FF)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF76CFFF).withValues(alpha:  0.4),
                  blurRadius: 14,
                  offset: const Offset(0, 7),
                ),
              ],
              border: Border.all(
                color: Colors.white.withValues(alpha:  0.65),
                width: 1.1,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  task.subCategory,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF2A2361),
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                    height: 1.15,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildActiveCountdownBubble() {
    if (_activeSpontaneousTask == null) {
      return const SizedBox.shrink();
    }

    final width = MediaQuery.of(context).size.width < 390 ? 118.0 : 134.0;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _openActiveSpontaneousTaskModal,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            width: width,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              gradient: const LinearGradient(
                colors: [Color(0xFF8DE8FF), Color(0xFFC9B5FF)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF76CFFF).withValues(alpha:  0.4),
                  blurRadius: 14,
                  offset: const Offset(0, 7),
                ),
              ],
              border: Border.all(
                color: Colors.white.withValues(alpha:  0.65),
                width: 1.1,
              ),
            ),
            child: Column(
              children: [
                Directionality(
                  textDirection: TextDirection.ltr,
                  child: Row(
                    children: [
                      const Icon(
                        Icons.schedule_rounded,
                        size: 14,
                        color: Color(0xFF2A2361),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Center(
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              _formatCountdownWithSeconds(
                                  _activeSpontaneousRemaining),
                              textDirection: TextDirection.rtl,
                              textAlign: TextAlign.center,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Color(0xFF2A2361),
                                fontSize: 18.5,
                                fontWeight: FontWeight.w900,
                                height: 1.0,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openActiveSpontaneousTaskModal() async {
    final task = _activeSpontaneousTask;
    if (task == null || !mounted) {
      return;
    }

    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierColor: Colors.black54,
      builder: (_) => SafeArea(
        child: Center(
          child: _ActiveSpontaneousTaskDialog(initialTask: task),
        ),
      ),
    );

    if (!mounted) return;
    await _loadActiveSpontaneousTask();
  }

  Future<void> _openSpontaneousChallengeModal() async {
    final userId = _currentUserId();
    if (!mounted) return;

    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;

    final shouldOpenActiveTask = await showDialog<bool>(
      context: context,
      useSafeArea: false,
      barrierDismissible: true,
      barrierColor: Colors.black54,
      builder: (dialogContext) {
        return _SpontaneousChallengeDialog(userId: userId);
      },
    );

    if (!mounted) return;
    await _loadActiveSpontaneousTask();
    if (!mounted) return;

    if ((shouldOpenActiveTask ?? false) && _activeSpontaneousTask != null) {
      await _openActiveSpontaneousTaskModal();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    return SwipeBackWrapper(
      child: Scaffold(
        backgroundColor: isLight ? Colors.white : const Color(0xFF0B1019),
        body: SafeArea(
          child: Stack(
            children: [
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    gradient: isLight
                        ? const LinearGradient(
                            colors: [
                              Colors.white,
                              Color(0xFFF8FBFF),
                              Colors.white,
                            ],
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                          )
                        : const LinearGradient(
                            colors: [
                              Color(0xFF0B1019),
                              Color(0xFF121A2E),
                              Color(0xFF15152B),
                            ],
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                          ),
                  ),
                ),
              ),
              Positioned(
                top: -70,
                right: -45,
                child: Container(
                  width: 220,
                  height: 220,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFF53C1F9).withValues(alpha:  0.08),
                  ),
                ),
              ),
              FutureBuilder<List<_StarsSectionData>>(
                future: _hotSectionsFuture,
                builder: (context, snapshot) {
                  final sections = snapshot.data ?? const <_StarsSectionData>[];
                  if (!_openedInitialPost && sections.isNotEmpty) {
                    _maybeOpenInitialPost(sections);
                  }

                  return CustomScrollView(
                    physics: const BouncingScrollPhysics(),
                    slivers: [
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 20, vertical: 12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _buildBackButton(),
                              const SizedBox(height: 6),
                              _buildTitle(),
                              const SizedBox(height: 6),
                              Text(
                                'השתתפו באתגר השבועי והגדילו את הניקוד שלכם במהירות.\nפוסטים בקטגוריה השבועית מקבלים בונוס מיוחד.',
                                textAlign: TextAlign.center,
                                textDirection: TextDirection.rtl,
                                style: TextStyle(
                                  color:
                                      isLight ? Colors.black54 : Colors.white70,
                                  fontSize: 14,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      SliverToBoxAdapter(child: _buildChallengeCard()),
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 20, vertical: 8),
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: Text(
                              'הדירוגים החמים של השבוע',
                              textAlign: TextAlign.right,
                              style: TextStyle(
                                color: isLight
                                    ? Colors.black
                                    : Colors.white.withValues(alpha:  0.95),
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (snapshot.connectionState == ConnectionState.waiting)
                        const SliverToBoxAdapter(
                          child: Padding(
                            padding: EdgeInsets.only(top: 24),
                            child: Center(child: CircularProgressIndicator()),
                          ),
                        )
                      else if (sections
                          .every((section) => section.posts.isEmpty))
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 24, vertical: 26),
                            child: Center(
                              child: Text(
                                'עדיין אין מספיק פוסטים להצגה השבוע',
                                style: TextStyle(
                                  color:
                                      isLight ? Colors.black54 : Colors.white70,
                                ),
                              ),
                            ),
                          ),
                        )
                      else
                        SliverList(
                          delegate: SliverChildBuilderDelegate(
                            (context, index) =>
                                _buildSectionCard(sections[index]),
                            childCount: sections.length,
                          ),
                        ),
                      const SliverToBoxAdapter(child: SizedBox(height: 120)),
                    ],
                  );
                },
              ),
              Positioned(
                top: 14,
                left: 4,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  textDirection: TextDirection.ltr,
                  children: [
                    if (_activeSpontaneousTask == null)
                      _buildSpontaneousBoostButton()
                    else ...[
                      _buildActiveSubCategoryBubble(),
                      const SizedBox(width: 6),
                      _buildActiveCountdownBubble(),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
        bottomNavigationBar: MainBottomNav(
          currentIndex: 0,
          onReselectCurrentTab: () {
            Navigator.of(context).pushAndRemoveUntil(
              MaterialPageRoute(builder: (_) => const FeedScreen()),
              (route) => false,
            );
          },
        ),
      ),
    );
  }
}

class _VideoCoverNetworkTile extends StatefulWidget {
  final String url;

  const _VideoCoverNetworkTile({required this.url});

  @override
  State<_VideoCoverNetworkTile> createState() => _VideoCoverNetworkTileState();
}

class _VideoCoverNetworkTileState extends State<_VideoCoverNetworkTile> {
  VideoPlayerController? _controller;

  @override
  void initState() {
    super.initState();
    final normalized = widget.url.trim();
    if (normalized.isEmpty) {
      return;
    }

    final controller = VideoPlayerController.networkUrl(Uri.parse(normalized));
    _controller = controller;
    controller.initialize().then((_) async {
      if (!mounted) {
        return;
      }
      try {
        await controller.seekTo(const Duration(milliseconds: 700));
      } catch (_) {
        // Keep first frame if seeking fails.
      }
      if (!mounted) {
        return;
      }
      setState(() {});
    }).catchError((_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: Color(0xFF111927)),
          Center(
            child: Icon(
              Icons.play_circle_fill_rounded,
              color: Colors.white70,
              size: 28,
            ),
          ),
        ],
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: controller.value.size.width,
            height: controller.value.size.height,
            child: VideoPlayer(controller),
          ),
        ),
        const Align(
          alignment: Alignment.bottomRight,
          child: Padding(
            padding: EdgeInsets.all(4),
            child: Icon(
              Icons.videocam_rounded,
              color: Colors.white,
              size: 16,
            ),
          ),
        ),
      ],
    );
  }
}

class _SpontaneousChallengeDialog extends StatefulWidget {
  final String userId;

  const _SpontaneousChallengeDialog({required this.userId});

  @override
  State<_SpontaneousChallengeDialog> createState() =>
      _SpontaneousChallengeDialogState();
}

class _ActiveSpontaneousTaskDialog extends StatefulWidget {
  final SpontaneousChallengeTask initialTask;

  const _ActiveSpontaneousTaskDialog({required this.initialTask});

  @override
  State<_ActiveSpontaneousTaskDialog> createState() =>
      _ActiveSpontaneousTaskDialogState();
}

class _ActiveSpontaneousTaskDialogState
    extends State<_ActiveSpontaneousTaskDialog> {
  late SpontaneousChallengeTask _task;
  Duration _x10Remaining = Duration.zero;
  Duration _x5Remaining = Duration.zero;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _task = widget.initialTask;
    _tick();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _tick() {
    final now = DateTime.now().toUtc();
    final remaining = _task.remainingAt(now);
    final elapsed = now.difference(_task.assignedAtUtc);
    final halfSeconds = _task.totalDuration.inSeconds ~/ 2;
    final x10Seconds = max(0, halfSeconds - elapsed.inSeconds);
    final x5Seconds = max(0, remaining.inSeconds);

    if (!mounted) return;
    setState(() {
      _x10Remaining = Duration(seconds: x10Seconds);
      _x5Remaining = Duration(seconds: x5Seconds);
    });

    if (remaining == Duration.zero) {
      _timer?.cancel();
    }
  }

  String _formatClock(Duration duration) {
    final totalSeconds = duration.inSeconds;
    final hours = duration.inHours >= 48
        ? duration.inHours.remainder(24)
        : totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  String? _daysLabel(Duration duration) {
    if (duration.inHours < 48) {
      return null;
    }
    return '${duration.inDays} ימים';
  }

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final categoryIcon = categoryIconFor(_task.category);
    final hasX10Window = _x10Remaining > Duration.zero;

    return Material(
      color: Colors.transparent,
      child: Container(
        width: 356,
        margin: const EdgeInsets.symmetric(horizontal: 18),
        padding: const EdgeInsets.all(1.8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(26),
          gradient: const LinearGradient(
            colors: [
              Color(0xFF67E5FF),
              Color(0xFF9D5FFF),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF75DAFF).withValues(alpha: 0.35),
              blurRadius: 24,
              spreadRadius: 1,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            gradient: LinearGradient(
              colors: isLight
                  ? const [
                      Color(0xFFEAFBFF),
                      Color(0xFFF3EFFF),
                      Color(0xFFE8FFF7)
                    ]
                  : const [
                      Color(0xFF10204B),
                      Color(0xFF311B60),
                      Color(0xFF13476D)
                    ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            border: Border.all(
              color: const Color(0xFF9BE2FF).withValues(alpha: 0.65),
            ),
          ),
          child: Directionality(
            textDirection: TextDirection.rtl,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  textDirection: TextDirection.ltr,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    IconButton(
                      onPressed: () => Navigator.of(context).maybePop(),
                      icon: const Icon(Icons.close_rounded),
                      color: isLight ? const Color(0xFF34405A) : Colors.white70,
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints(minWidth: 36, minHeight: 36),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'המשימה שלך:',
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          color: isLight ? const Color(0xFF243355) : Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(1.8),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(21),
                    gradient: const LinearGradient(
                      colors: [
                        Color(0xFF7DE3FF),
                        Color(0xFFBDA2FF),
                        Color(0xFF6FE2FF),
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                  ),
                  child: Container(
                    width: double.infinity,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 18, vertical: 20),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(19),
                      gradient: const LinearGradient(
                        colors: [Color(0xFF8DE8FF), Color(0xFFC9B5FF)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF76CFFF).withValues(alpha: 0.35),
                          blurRadius: 12,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(categoryIcon,
                            color: const Color(0xFF2A2361), size: 30),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Text(
                                _task.category,
                                textAlign: TextAlign.center,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Color(0xFF2A2361),
                                  fontWeight: FontWeight.w900,
                                  fontSize: 19,
                                  height: 1.15,
                                ),
                              ),
                              const SizedBox(height: 5),
                              Text(
                                _task.subCategory,
                                textAlign: TextAlign.center,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Color(0xFF2A2361),
                                  fontWeight: FontWeight.w800,
                                  fontSize: 17,
                                  height: 1.2,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                _buildTimerRow(
                  title: hasX10Window ? 'זמן שנשאר ל-X10:' : 'X10 הסתיים:',
                  clockValue: _formatClock(_x10Remaining),
                  daysLabel: _daysLabel(_x10Remaining),
                  statusText: hasX10Window ? null : 'עדיין אפשר להשיג ניקוד X5',
                  isLight: isLight,
                ),
                const SizedBox(height: 10),
                _buildTimerRow(
                  title: 'זמן שנשאר ל-X5:',
                  clockValue: _formatClock(_x5Remaining),
                  daysLabel: _daysLabel(_x5Remaining),
                  isLight: isLight,
                ),
                const SizedBox(height: 12),
                Text(
                  'עשיתם את המשימה? למה אתם מחכים?\nתעלו את הפוסט!',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: isLight ? const Color(0xFF324061) : Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                    height: 1.25,
                  ),
                ),
                const SizedBox(height: 16),
                Center(
                  child: SizedBox(
                    width: 238,
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () {
                          final navigator = Navigator.of(context);
                          navigator.pop();
                          navigator.push(
                            MaterialPageRoute(
                              builder: (_) => CreatePostScreen(
                                initialCategory: _task.category,
                                initialSubCategory: _task.subCategory,
                              ),
                            ),
                          );
                        },
                        borderRadius: BorderRadius.circular(18),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 12),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(18),
                            gradient: const LinearGradient(
                              colors: [Color(0xFF6F8CFF), Color(0xFF78E0FF)],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                          ),
                          child: const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.add_rounded,
                                  color: Colors.white, size: 20),
                              SizedBox(width: 8),
                              Text(
                                'העלאת פוסט',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTimerRow({
    required String title,
    required String clockValue,
    required String? daysLabel,
    String? statusText,
    required bool isLight,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: isLight
            ? Colors.white.withValues(alpha:  0.82)
            : const Color(0xFF0F1728),
        border:
            Border.all(color: const Color(0xFF9E7CFF).withValues(alpha:  0.24)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            title,
            style: TextStyle(
              color: isLight ? const Color(0xFF36435E) : Colors.white70,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (statusText != null)
            Flexible(
              child: Text(
                statusText,
                textAlign: TextAlign.left,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFF53C1F9),
                  fontWeight: FontWeight.w900,
                  fontSize: 13,
                ),
              ),
            )
          else
            Row(
              textDirection: TextDirection.ltr,
              children: [
                if (daysLabel != null) ...[
                  Text(
                    daysLabel,
                    style: const TextStyle(
                      color: Color(0xFF53C1F9),
                      fontWeight: FontWeight.w900,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                const Icon(
                  Icons.schedule_rounded,
                  size: 16,
                  color: Color(0xFF53C1F9),
                ),
                const SizedBox(width: 5),
                Text(
                  clockValue,
                  textAlign: TextAlign.left,
                  style: const TextStyle(
                    color: Color(0xFF53C1F9),
                    fontWeight: FontWeight.w900,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _SpontaneousChallengeDialogState
    extends State<_SpontaneousChallengeDialog>
    with SingleTickerProviderStateMixin {
  static const Duration _runDuration = Duration(seconds: 5);

  late final AnimationController _controller;
  final Random _random = Random();
  final List<_BubbleParticle> _particles = <_BubbleParticle>[];
  Timer? _timer;
  SpontaneousChallengeTask? _activeTask;
  SpontaneousChallengeTask? _revealedTask;
  Duration _remaining = Duration.zero;
  bool _isLoading = true;
  bool _isRunning = false;
  bool _showExplosion = false;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: _runDuration,
    )..addStatusListener(_handleAnimationStatus);
    _loadActiveTask();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _handleAnimationStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || !mounted) {
      return;
    }

    setState(() {
      _showExplosion = true;
      _isRunning = false;
    });

    Future<void>.delayed(const Duration(milliseconds: 420), () {
      if (!mounted) return;

      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop(true);
      }
    });
  }

  Future<void> _loadActiveTask() async {
    final userId = widget.userId.trim();
    if (userId.isEmpty) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorText = 'יש להתחבר כדי לקבל משימה ספונטנית.';
      });
      return;
    }

    try {
      final task = await SpontaneousChallengeService.currentTaskForUser(userId);
      if (!mounted) return;
      setState(() {
        _activeTask = task;
        _revealedTask = task;
        _remaining = task?.remainingAt(DateTime.now().toUtc()) ?? Duration.zero;
        _isLoading = false;
        _errorText = null;
      });
      _startCountdownIfNeeded();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorText = 'לא הצלחנו לטעון את המשימה כרגע.';
      });
    }
  }

  void _startCountdownIfNeeded() {
    _timer?.cancel();
    final task = _activeTask;
    if (task == null) return;

    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }

      final remaining = task.remainingAt(DateTime.now().toUtc());
      if (remaining == Duration.zero) {
        timer.cancel();
        setState(() {
          _activeTask = null;
          _revealedTask = null;
          _remaining = Duration.zero;
        });
        return;
      }

      setState(() {
        _remaining = remaining;
      });
    });
  }

  List<_BubbleParticle> _buildParticles() {
    final subCategories = appCategories.values
        .expand((items) => items)
        .where((item) => item.trim().isNotEmpty && item.trim() != 'אחר')
        .toList(growable: false);

    return List<_BubbleParticle>.generate(18, (index) {
      final label = subCategories.isEmpty
          ? 'אתגר'
          : subCategories[_random.nextInt(subCategories.length)];
      return _BubbleParticle(
        startX: _random.nextDouble(),
        startY: _random.nextDouble(),
        targetX: _random.nextDouble(),
        targetY: _random.nextDouble(),
        size: 84 + _random.nextDouble() * 54,
        label: label,
        hue: 0.52 + _random.nextDouble() * 0.27,
        drift: 14 + _random.nextDouble() * 26,
        phase: _random.nextDouble() * pi * 2,
      );
    });
  }

  Future<void> _startRun() async {
    if (_isRunning || _activeTask != null) {
      return;
    }

    final userId = widget.userId.trim();
    if (userId.isEmpty) {
      setState(() {
        _errorText = 'יש להתחבר כדי להתחיל את האתגר.';
      });
      return;
    }

    setState(() {
      _errorText = null;
      _isRunning = true;
      _revealedTask = null;
      _showExplosion = false;
      _particles
        ..clear()
        ..addAll(_buildParticles());
    });

    try {
      final task = await SpontaneousChallengeService.assignTaskForUser(userId);
      if (!mounted) return;
      setState(() {
        _activeTask = task;
        _remaining = task.totalDuration;
      });
      _startCountdownIfNeeded();
      await _controller.forward(from: 0);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isRunning = false;
        _activeTask = null;
        _revealedTask = null;
        _remaining = Duration.zero;
        _errorText = 'לא הצלחנו להפעיל את המשימה.';
      });
    }
  }

  String _formatRemaining(Duration remaining) {
    final totalSeconds = remaining.inSeconds;
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final revealedTask = _revealedTask;
    final showFullscreenRun = _isRunning || _showExplosion;

    return Material(
      color: Colors.transparent,
      child: Stack(
        children: [
          Center(
            child: Container(
              width: 360,
              margin: const EdgeInsets.symmetric(horizontal: 18),
              padding: const EdgeInsets.all(1.8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(32),
                gradient: const LinearGradient(
                  colors: [
                    Color(0xFF70E0FF),
                    Color(0xFFB8A5FF),
                    Color(0xFF8AD7FF),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF7ED7FF).withValues(alpha: 0.42),
                    blurRadius: 24,
                    spreadRadius: 1,
                    offset: const Offset(0, 12),
                  ),
                ],
              ),
              child: Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(30),
                  gradient: LinearGradient(
                    colors: isLight
                        ? const [Color(0xFFF8FBFF), Color(0xFFEAF1FF)]
                        : const [Color(0xFF121A2E), Color(0xFF1B1632)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  border: Border.all(
                    color: const Color(0xFF79D8FF).withValues(alpha: 0.52),
                    width: 1.5,
                  ),
                ),
                child: Directionality(
                  textDirection: TextDirection.rtl,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: IconButton(
                          onPressed: () => Navigator.of(context).maybePop(),
                          icon: const Icon(Icons.close_rounded),
                          color: isLight
                              ? const Color(0xFF34405A)
                              : Colors.white70,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'חושבים שאתם ספונטניים?\nבואו נבדוק עד כמה',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w900,
                          height: 1.15,
                          color: isLight
                              ? const Color(0xFF243355)
                              : Colors.white,
                        ),
                      ),
                      const SizedBox(height: 14),
                      if (_isLoading)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 28),
                          child: CircularProgressIndicator(),
                        )
                      else if (_errorText != null)
                        Text(
                          _errorText!,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: isLight
                                ? const Color(0xFF8A2C5B)
                                : Colors.white70,
                          ),
                        )
                      else ...[
                        Text(
                          'תעלו פוסט בזמן שיוגדר ותקבלו X5 נקודות.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: isLight
                                ? const Color(0xFF36435E)
                                : Colors.white70,
                            fontSize: 13,
                            height: 1.3,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'נשאר יותר מחצי מהזמן? קיבלתם X10!',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: isLight
                                ? const Color(0xFF36435E)
                                : Colors.white70,
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                            height: 1.3,
                          ),
                        ),
                        const SizedBox(height: 14),
                        _buildCenterActionCard(revealedTask),
                        const SizedBox(height: 8),
                        if (revealedTask != null) ...[
                          Text(
                            'המשימה שלכם חיה עכשיו. פרסמו בזמן כדי לקבל את ההכפלה המקסימלית.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: isLight
                                  ? const Color(0xFF36435E)
                                  : Colors.white70,
                              fontSize: 13,
                              height: 1.3,
                            ),
                          ),
                          const SizedBox(height: 10),
                          _buildTaskChip(
                            label: revealedTask.category,
                            isLight: isLight,
                          ),
                          const SizedBox(height: 8),
                          _buildTaskChip(
                            label: revealedTask.subCategory,
                            isLight: isLight,
                            filled: true,
                          ),
                          const SizedBox(height: 10),
                          _buildCooldownRow(isLight),
                        ],
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (showFullscreenRun)
            Positioned.fill(
              child: IgnorePointer(
                ignoring: true,
                child: AnimatedBuilder(
                  animation: _controller,
                  builder: (context, child) {
                    final progress = _controller.value;
                    return DecoratedBox(
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            Color(0xEE0E1730),
                            Color(0xDD19143A),
                            Color(0xEE122640),
                          ],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                      ),
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final width = constraints.maxWidth;
                          final height = constraints.maxHeight;
                          return Stack(
                            children: [
                              for (final particle in _particles)
                                Positioned(
                                  left: (particle.startX +
                                              ((particle.targetX -
                                                      particle.startX) *
                                                  progress) +
                                              sin((progress * 10) +
                                                      particle.phase) *
                                                  (particle.drift / width))
                                          .clamp(0.03, 0.92) *
                                      width,
                                  top: (particle.startY +
                                              ((particle.targetY -
                                                      particle.startY) *
                                                  progress) +
                                              (sin((progress * 13) +
                                                      particle.phase) *
                                                  (particle.drift / height)) -
                                              ((1 -
                                                      (0.5 -
                                                              (progress - 0.5)
                                                                  .abs()) *
                                                          2) *
                                                  0.03))
                                          .clamp(0.04, 0.88) *
                                      height,
                                  child: Opacity(
                                    opacity: _showExplosion
                                        ? 0
                                        : (0.42 + progress).clamp(0.0, 1.0),
                                    child: Transform.scale(
                                      scale: 0.72 + (progress * 0.52),
                                      child: Container(
                                        width: particle.size,
                                        height: particle.size,
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 8,
                                        ),
                                        alignment: Alignment.center,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: HSVColor.fromAHSV(
                                            0.88,
                                            particle.hue * 360,
                                            0.42,
                                            0.98,
                                          ).toColor(),
                                          border: Border.all(
                                            color: Colors.white
                                                .withValues(alpha:  0.68),
                                            width: 1.2,
                                          ),
                                          boxShadow: [
                                            BoxShadow(
                                              color: Colors.black
                                                  .withValues(alpha:  0.2),
                                              blurRadius: 10,
                                              offset: const Offset(0, 5),
                                            ),
                                          ],
                                        ),
                                        child: Text(
                                          particle.label,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          textAlign: TextAlign.center,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 12,
                                            fontWeight: FontWeight.w900,
                                            height: 1.1,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              if (_showExplosion)
                                Center(
                                  child: Container(
                                    width: 260,
                                    height: 260,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      gradient: RadialGradient(
                                        colors: [
                                          const Color(0xFFFFE08A)
                                              .withValues(alpha:  0.96),
                                          const Color(0xFFFF8DA1)
                                              .withValues(alpha:  0.35),
                                          Colors.transparent,
                                        ],
                                      ),
                                    ),
                                    child: const Icon(
                                      Icons.rocket_launch_rounded,
                                      color: Colors.white,
                                      size: 72,
                                    ),
                                  ),
                                ),
                            ],
                          );
                        },
                      ),
                    );
                  },
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCenterActionCard(SpontaneousChallengeTask? revealedTask) {
    final width = MediaQuery.of(context).size.width < 390 ? 150.0 : 168.0;
    final activeTitle = revealedTask == null
        ? 'ספונטניות זה שם המשחק'
        : '${revealedTask.category} · ${revealedTask.subCategory}';

    final card = Container(
      width: width,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(26),
        gradient: const LinearGradient(
          colors: [
            Color(0xFF53C1F9),
            Color(0xFF9E7CFF),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF53C1F9).withValues(alpha:  0.3),
            blurRadius: 16,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            revealedTask == null
                ? Icons.touch_app_rounded
                : Icons.sailing_rounded,
            color: Colors.white,
            size: 34,
          ),
          const SizedBox(height: 8),
          Text(
            activeTitle,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );

    if (revealedTask != null) {
      return AnimatedScale(
        scale: 1.04,
        duration: const Duration(milliseconds: 260),
        child: card,
      );
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: _isRunning ? null : _startRun,
        borderRadius: BorderRadius.circular(26),
        child: AnimatedScale(
          scale: _isRunning ? 0.98 : 1,
          duration: const Duration(milliseconds: 220),
          child: card,
        ),
      ),
    );
  }

  Widget _buildTaskChip({
    required String label,
    required bool isLight,
    bool filled = false,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: filled
            ? const Color(0xFF53C1F9).withValues(alpha:  isLight ? 0.16 : 0.24)
            : Colors.transparent,
        border: Border.all(
          color: const Color(0xFF53C1F9).withValues(alpha:  0.3),
        ),
      ),
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: isLight ? const Color(0xFF2A3560) : Colors.white,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  Widget _buildCooldownRow(bool isLight) {
    final remaining = _remaining;
    final rewardMultiplier =
        _activeTask?.rewardMultiplierAt(DateTime.now().toUtc()) ?? 0;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: isLight
            ? Colors.white.withValues(alpha:  0.8)
            : const Color(0xFF0F1728),
        border: Border.all(
          color: const Color(0xFF9E7CFF).withValues(alpha:  0.25),
        ),
      ),
      child: Column(
        children: [
          Text(
            'נשאר: ${_formatRemaining(remaining)}',
            style: TextStyle(
              color: isLight ? const Color(0xFF36435E) : Colors.white70,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            rewardMultiplier >= 10 ? 'העלאה ראשונית X10' : 'העלאה פעילה X5',
            style: const TextStyle(
              color: Color(0xFF53C1F9),
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

class _BubbleParticle {
  final double startX;
  final double startY;
  final double targetX;
  final double targetY;
  final double size;
  final String label;
  final double hue;
  final double drift;
  final double phase;

  const _BubbleParticle({
    required this.startX,
    required this.startY,
    required this.targetX,
    required this.targetY,
    required this.size,
    required this.label,
    required this.hue,
    required this.drift,
    required this.phase,
  });
}
