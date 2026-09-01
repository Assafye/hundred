import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';
import 'post_model.dart';
import 'post_media_utils.dart';
import 'models/public_user_profile.dart';
import 'services/post_service.dart';
import 'services/feed_backend_service.dart';
import 'services/public_user_profile_service.dart';
import 'services/firestore_rule_feedback.dart';
import 'services/post_interaction_overlay_service.dart';
import 'services/report_service.dart';
import 'services/share_flow_log_service.dart';
import 'services/social_service.dart';
import 'services/group_service.dart';
import 'services/spontaneous_challenge_service.dart';
import 'services/block_user_service.dart';
import 'category_screen.dart';
import 'chat_room_screen.dart';
import 'group_details_screen.dart';
import 'user_profile_screen.dart';
import 'main_bottom_nav.dart';
import 'online_screen.dart';
import 'stars_screen.dart'
    show
        StarsScreen,
        showActiveSpontaneousTaskModal,
        showSpontaneousLotteryModal;
import 'app_categories.dart';
import 'widgets/post_media_viewer.dart';
import 'widgets/post_comments_sheet.dart';
import 'widgets/post_share_targets_sheet.dart';
import 'widgets/report_dialogs.dart';
import 'widgets/expandable_post_description.dart';

enum _FeedShareMenuAction { copyLink, sendToFriend, systemShare }

const int _feedSeenHistoryLimit = 400;
const int _feedSeenHistoryRetentionDays = 30;
const String _feedSeenHistoryStorageKeyPrefix = 'feed_seen_history_v1';

// Scoped per signed-in uid so switching accounts on the same device never
// makes a different user inherit another account's "seen everything" state.
String _feedSeenHistoryStorageKeyForCurrentUser() {
  final uid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
  return uid.isEmpty
      ? _feedSeenHistoryStorageKeyPrefix
      : '${_feedSeenHistoryStorageKeyPrefix}_$uid';
}

List<PostModel> filterFeedPostsForFreshnessAndSeen(
  List<PostModel> posts, {
  required Set<String> seenPostIds,
  DateTime? now,
}) {
  final currentTime = now ?? DateTime.now();
  final cutoff = currentTime.subtract(
    const Duration(days: _feedSeenHistoryRetentionDays),
  );

  return posts.where((post) {
    final id = post.id.trim();
    if (id.isEmpty) {
      return false;
    }

    if (seenPostIds.contains(id)) {
      return false;
    }

    final createdAt = post.createdAt;
    if (createdAt != null && createdAt.isBefore(cutoff)) {
      return false;
    }

    return true;
  }).toList(growable: false);
}

String feedDisplayBatchSignature(List<PostModel> posts) {
  return posts
      .map((post) =>
          '${post.id.trim()}:${post.createdAt?.millisecondsSinceEpoch ?? 0}:${post.category}:${post.subCategory}')
      .join('|');
}

bool shouldTriggerExhaustedFeedMessageAfterOverscroll({
  required int activeFeedIndex,
  required int feedPostCount,
  required bool hasMoreUnseenPosts,
  required double overscroll,
}) {
  return overscroll > 0 &&
      feedPostCount > 0 &&
      activeFeedIndex >= feedPostCount - 1 &&
      !hasMoreUnseenPosts;
}

({String signature, Set<String> seenPostIds}) resolveFeedDisplaySeenSnapshot({
  required List<PostModel> posts,
  required Set<String> currentSeenPostIds,
  required String previousBatchSignature,
  required Set<String> previousBatchSeenPostIds,
}) {
  final signature = feedDisplayBatchSignature(posts);
  if (signature.isNotEmpty && signature == previousBatchSignature) {
    return (signature: signature, seenPostIds: previousBatchSeenPostIds);
  }

  return (
    signature: signature,
    seenPostIds: Set<String>.from(currentSeenPostIds),
  );
}

class FeedScreen extends StatefulWidget {
  const FeedScreen({
    super.key,
    this.allowSpontaneousPrompt = false,
    this.initialSpontaneousPromptDelay = Duration.zero,
  });

  final bool allowSpontaneousPrompt;
  final Duration initialSpontaneousPromptDelay;

  @override
  State<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends State<FeedScreen> with TickerProviderStateMixin {
  static const double _postTopOverlayOffset = 144;
  static const double _postOverlayClearanceFromNav = 12;
  static const double _postTextBlockExtraOffset = 16;
  static const bool _experimentalFeedPostLayout = true;
  static const String _spontaneousPromptShownKeyPrefix =
      'feed_spontaneous_prompt_last_shown_at';

  bool isForYouFeed = true;
  int _currentFeedPageIndex = 0;
  bool _isFeedInForeground = true;
  String selectedCategory = kGeneralCategory;
  String selectedSubCategory = _allSubCategoriesLabel;
  bool isCategoryMenuOpen = false;
  bool isSubCategoryMenuOpen = false;
  int _feedRefreshToken = 0;

  static const String _allSubCategoriesLabel = 'כל תתי הקטגוריות';

  final PageController _pageController = PageController();
  final PostService _postService = PostService();
  final FeedBackendService _feedBackendService = FeedBackendService();
  final PublicUserProfileService _publicUserProfileService =
      PublicUserProfileService();
  final SocialService _socialService = SocialService();
  final GroupService _groupService = GroupService();
  final BlockUserService _blockUserService = BlockUserService();
  final ReportService _reportService = ReportService();

  static const Color _themePurple = Color(0xFF8C62FF);
  static const Color _themePurpleDeep = Color(0xFF6C3DFF);
  static const Color _themeCyan = Color(0xFF46D3FF);
  static const Color _themeBlue = Color(0xFF5A8BFF);

  final Map<String, bool> _likedOverrideByPostId = <String, bool>{};
  final Map<String, bool> _savedOverrideByPostId = <String, bool>{};
  final Map<String, int> _commentCountOverrideByPostId = <String, int>{};
  final Map<String, int> _shareCountOverrideByPostId = <String, int>{};
  final Set<String> _likeInFlightPostIds = <String>{};
  final Set<String> _saveInFlightPostIds = <String>{};
  final Set<String> _shareInFlightPostIds = <String>{};
  final Map<String, Future<PublicUserProfile?>> _authorFutureCache = {};
  final Map<String, Future<List<PostModel>>> _audienceFilteredPostsCache =
      <String, Future<List<PostModel>>>{};
  final Map<String, DateTime> _feedSeenHistory = <String, DateTime>{};
  Set<String> _feedSeenIds = <String>{};
  Set<String> _feedDisplayBatchSeenIds = <String>{};
  bool _hasLoadedSeenFeedHistory = false;
  Offset _heartTapPosition = Offset.zero;
  bool _showDoubleTapHeart = false;
  String _activeHeartPostId = '';
  SpontaneousChallengeTask? _activeSpontaneousTask;
  Duration _activeSpontaneousRemaining = Duration.zero;
  Timer? _spontaneousCountdownTimer;
  Timer? _spontaneousPromptTimer;
  Stream<List<Map<String, dynamic>>>? _cachedFeedStream;
  String _cachedFeedStreamKey = '';
  late final List<String> categories;
  String _randomizedFeedSignature = '';
  Map<String, int> _randomizedFeedOrder = <String, int>{};
  String _feedDisplayBatchSignature = '';
  String _lastPrecachedFeedSignature = '';
  bool _didScheduleSpontaneousPrompt = false;
  bool _hasShownExhaustedFeedSheet = false;
  late final List<String> _emptyFeedSuggestionOptions;

  @override
  void initState() {
    super.initState();
    categories = appMainCategories;
    _emptyFeedSuggestionOptions = _buildEmptyFeedSuggestionOptions();
    MainBottomNav.feedPlaybackPausedByComposer
        .addListener(_syncForegroundStateWithComposer);
    _syncForegroundStateWithComposer();
    _loadSeenFeedHistory();
    _scheduleSpontaneousPromptIfNeeded();
    _loadActiveSpontaneousTask();
  }

  Future<void> _loadSeenFeedHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_feedSeenHistoryStorageKeyForCurrentUser());
    if (!mounted) {
      return;
    }

    final loaded = <String, DateTime>{};
    if (raw != null && raw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          final values = decoded.cast<String, dynamic>();
          for (final entry in values.entries) {
            final key = entry.key.toString().trim();
            if (key.isEmpty) {
              continue;
            }
            final value = int.tryParse(entry.value.toString());
            if (value == null) {
              continue;
            }
            loaded[key] =
                DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
          }
        }
      } catch (_) {
        // Ignore malformed persisted history and start fresh.
      }
    }

    final now = DateTime.now();
    final cutoff = now.subtract(
      const Duration(days: _feedSeenHistoryRetentionDays),
    );

    final pruned = <String, DateTime>{};
    for (final entry in loaded.entries) {
      if (entry.value.isBefore(cutoff)) {
        continue;
      }
      pruned[entry.key] = entry.value;
    }

    final sorted = pruned.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    final limited = <String, DateTime>{};
    for (final entry in sorted.take(_feedSeenHistoryLimit)) {
      limited[entry.key] = entry.value;
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _feedSeenHistory.clear();
      _feedSeenHistory.addAll(limited);
      _feedSeenIds = _feedSeenHistory.keys.toSet();
      _hasLoadedSeenFeedHistory = true;
    });
  }

  Future<void> _persistSeenFeedHistory() async {
    final entries = _feedSeenHistory.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));

    final limitedEntries = entries.take(_feedSeenHistoryLimit).toList();
    final payload = <String, int>{
      for (final entry in limitedEntries)
        entry.key: entry.value.millisecondsSinceEpoch,
    };

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _feedSeenHistoryStorageKeyForCurrentUser(), jsonEncode(payload));
  }

  void _recordSeenFeedPost(PostModel post) {
    final id = post.id.trim();
    if (id.isEmpty || _feedSeenIds.contains(id)) {
      return;
    }

    final seenAt = DateTime.now();
    _feedSeenHistory[id] = seenAt;
    _feedSeenIds.add(id);

    final cutoff = seenAt.subtract(
      const Duration(days: _feedSeenHistoryRetentionDays),
    );
    _feedSeenHistory.removeWhere((postId, timestamp) {
      return timestamp.isBefore(cutoff);
    });

    final sorted = _feedSeenHistory.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    final trimmed = <String, DateTime>{};
    for (final entry in sorted.take(_feedSeenHistoryLimit)) {
      trimmed[entry.key] = entry.value;
    }
    _feedSeenHistory
      ..clear()
      ..addAll(trimmed);
    _feedSeenIds = _feedSeenHistory.keys.toSet();

    unawaited(_persistSeenFeedHistory());
  }

  void _recordActiveFeedPostIfNeeded({
    required List<PostModel> feedPosts,
    required int activeFeedIndex,
    required List<PostModel> baseFeedPosts,
  }) {
    if (feedPosts.isEmpty) {
      return;
    }

    final safeIndex = activeFeedIndex.clamp(0, feedPosts.length - 1);
    final activePost = feedPosts[safeIndex];
    final activePostId = activePost.id.trim();
    if (activePostId.isEmpty || _feedSeenIds.contains(activePostId)) {
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _feedSeenIds.contains(activePostId)) {
        return;
      }

      _recordSeenFeedPost(activePost);
    });
  }

  void _syncForegroundStateWithComposer() {
    if (!mounted) {
      return;
    }

    final shouldPause = MainBottomNav.feedPlaybackPausedByComposer.value;
    final shouldBeForeground = !shouldPause;
    if (_isFeedInForeground == shouldBeForeground) {
      return;
    }

    setState(() {
      _isFeedInForeground = shouldBeForeground;
    });
  }

  Future<void> _showExhaustedFeedMessage() async {
    if (!mounted || _hasShownExhaustedFeedSheet) {
      return;
    }

    _hasShownExhaustedFeedSheet = true;
    BuildContext? dialogRouteContext;
    unawaited(
      Future<void>.delayed(const Duration(seconds: 2), () async {
        final contextToClose = dialogRouteContext;
        if (!mounted || contextToClose == null) {
          return;
        }

        final navigator = Navigator.of(contextToClose);
        if (navigator.canPop()) {
          navigator.pop();
        }
      }),
    );

    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 280),
      pageBuilder: (dialogContext, animation, secondaryAnimation) {
        dialogRouteContext = dialogContext;
        final dialogWidth = MediaQuery.of(dialogContext).size.width;
        final bubbleWidth = (dialogWidth * 0.74).clamp(240.0, 360.0);

        return AnimatedBuilder(
          animation: animation,
          builder: (context, child) {
            final screenHeight = MediaQuery.of(context).size.height;
            final progress = CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
            ).value;
            final offset = Offset(0, screenHeight * 0.42 * (1 - progress));
            final opacity = progress.clamp(0.0, 1.0);

            return Transform.translate(
              offset: offset,
              child: Opacity(
                opacity: opacity,
                child: Center(
                  child: Container(
                    width: bubbleWidth,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 18,
                    ),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: <Color>[
                          Color(0xFF4BA7FF),
                          Color(0xFF2D84E6),
                        ],
                      ),
                      border: Border.all(
                        color: const Color(0xFFD7EEFF),
                        width: 1.8,
                      ),
                      borderRadius: BorderRadius.circular(28),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x55306FB8),
                          blurRadius: 24,
                          spreadRadius: 3,
                          offset: Offset(0, 10),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 54,
                          height: 5,
                          margin: const EdgeInsets.only(bottom: 12),
                          decoration: BoxDecoration(
                            color: Colors.white24,
                            borderRadius: BorderRadius.circular(99),
                          ),
                        ),
                        const Text(
                          'סיימת לראות את כל הפוסטים העדכניים!',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            decoration: TextDecoration.none,
                          ),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'זה הזמן ליצור עוד פוסטים בעצמך!',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Color(0xFFF2F9FF),
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            height: 1.5,
                            decoration: TextDecoration.none,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _loadActiveSpontaneousTask() async {
    final uid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
    if (uid.isEmpty) {
      if (!mounted) return;
      setState(() {
        _activeSpontaneousTask = null;
        _activeSpontaneousRemaining = Duration.zero;
      });
      return;
    }

    final task = await SpontaneousChallengeService.currentTaskForUser(uid);
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

  String _formatSpontaneousCountdown(Duration remaining) {
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

  Future<void> _openActiveSpontaneousTaskModal() async {
    final task = _activeSpontaneousTask;
    if (task == null || !mounted) return;

    await showActiveSpontaneousTaskModal(context, task: task);
    if (!mounted) return;
    await _loadActiveSpontaneousTask();
  }

  Future<void> _openStarsAndRefreshSpontaneous() async {
    await _pushWithFeedPlaybackPaused<void>(
      MaterialPageRoute(builder: (_) => const StarsScreen()),
    );
    if (!mounted) return;
    await _loadActiveSpontaneousTask();
  }

  Future<T?> _pushWithFeedPlaybackPaused<T>(Route<T> route) async {
    if (mounted) {
      setState(() {
        _isFeedInForeground = false;
      });
    }

    try {
      return await Navigator.of(context).push(route);
    } finally {
      if (mounted) {
        setState(() {
          _isFeedInForeground = true;
        });
      }
    }
  }

  Future<void> _openSpontaneousFeedBubble() async {
    final uid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
    if (uid.isEmpty || !mounted) {
      return;
    }

    if (_activeSpontaneousTask != null) {
      await showActiveSpontaneousTaskModal(context,
          task: _activeSpontaneousTask!);
      return;
    }

    await showSpontaneousLotteryModal(context, userId: uid);
    if (!mounted) {
      return;
    }

    await _loadActiveSpontaneousTask();
    if (!mounted || _activeSpontaneousTask == null) {
      return;
    }

    await showActiveSpontaneousTaskModal(context,
        task: _activeSpontaneousTask!);
  }

  void _scheduleSpontaneousPromptIfNeeded() {
    if (!widget.allowSpontaneousPrompt || _didScheduleSpontaneousPrompt) {
      return;
    }

    _didScheduleSpontaneousPrompt = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final delay = widget.initialSpontaneousPromptDelay;
      if (delay <= Duration.zero) {
        _maybeShowSpontaneousPrompt();
        return;
      }

      _spontaneousPromptTimer?.cancel();
      _spontaneousPromptTimer = Timer(delay, () {
        if (!mounted) {
          return;
        }
        _maybeShowSpontaneousPrompt();
      });
    });
  }

  Widget _buildEmptyFeedActionBubble({
    required String label,
    required VoidCallback onTap,
    required Color color,
  }) {
    final isLight = _isLightMode(context);
    const timerTopColor = Color(0xFF8DE8FF);
    const timerBottomColor = Color(0xFFC9B5FF);
    const timerTextColor = Color(0xFF2A2361);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          constraints: const BoxConstraints(minWidth: 126, minHeight: 54),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: isLight
                  ? [timerTopColor, timerBottomColor]
                  : [
                      timerTopColor.withOpacity(0.82),
                      timerBottomColor.withOpacity(0.82)
                    ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: Colors.white.withOpacity(0.8),
              width: 1.4,
            ),
            boxShadow: [
              BoxShadow(
                color: timerTopColor.withOpacity(isLight ? 0.28 : 0.22),
                blurRadius: 18,
                offset: const Offset(0, 7),
              ),
              BoxShadow(
                color: timerBottomColor.withOpacity(isLight ? 0.24 : 0.18),
                blurRadius: 20,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Center(
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: timerTextColor,
                fontSize: 13,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<String> _buildEmptyFeedSuggestionOptions() {
    final tasks = <String>[];
    for (final category in appMainCategories) {
      if (category == kGeneralCategory) {
        continue;
      }
      final subCategories = appSubCategories(category);
      for (final subCategory in subCategories) {
        final normalized = subCategory.trim();
        if (normalized.isEmpty || normalized == 'אחר') {
          continue;
        }
        tasks.add(normalized);
      }
    }

    final deduped = <String>[];
    for (final task in tasks) {
      if (!deduped.contains(task)) {
        deduped.add(task);
      }
    }

    if (deduped.length <= 6) {
      return deduped.toList(growable: false);
    }

    final shuffled = List<String>.from(deduped)..shuffle(Random());
    return shuffled.take(6).toList(growable: false);
  }

  Widget _buildEmptyFeedSuggestionChip(String label) {
    final isLight = _isLightMode(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isLight
              ? [const Color(0xFFEAF8FF), const Color(0xFFF0EBFF)]
              : [const Color(0xFF1C2A3D), const Color(0xFF251E3B)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: const Color(0xFF9AC7FF).withOpacity(isLight ? 0.55 : 0.6),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF8DE8FF).withOpacity(isLight ? 0.12 : 0.16),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: isLight ? const Color(0xFF1E2331) : Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  Widget _buildEmptyFeedState({required bool isForYouFeed}) {
    final isLight = _isLightMode(context);
    final titleText = isForYouFeed
        ? 'סיימת לראות את כל הפוסטים העדכניים בקטגוריה זו!'
        : 'סיימת לראות את כל הפוסטים העדכניים של החברים בקטגוריה זו!';
    final suggestionTitles = _emptyFeedSuggestionOptions;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 28, 20, 24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              titleText,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: isLight ? const Color(0xFF1D2330) : Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 18),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 12,
              runSpacing: 12,
              children: [
                _buildEmptyFeedActionBubble(
                  label: 'המשימה הספונטנית שלי!',
                  onTap: _openSpontaneousFeedBubble,
                  color: const Color(0xFF8CCAFB),
                ),
                _buildEmptyFeedActionBubble(
                  label: 'כוכבי השבוע',
                  onTap: () async {
                    await _pushWithFeedPlaybackPaused<void>(
                      MaterialPageRoute(builder: (_) => const StarsScreen()),
                    );
                  },
                  color: const Color(0xFFC7B9FF),
                ),
                _buildEmptyFeedActionBubble(
                  label: 'לצפייה בפופים',
                  onTap: () async {
                    await _pushWithFeedPlaybackPaused<void>(
                      MaterialPageRoute(builder: (_) => const OnlineScreen()),
                    );
                  },
                  color: const Color(0xFF95D9E5),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Text(
              'רעיונות לדברים לעשות:',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: isLight ? const Color(0xFF3B465D) : Colors.white70,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 14),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 10,
              runSpacing: 10,
              children: suggestionTitles
                  .map((title) => _buildEmptyFeedSuggestionChip(title))
                  .toList(growable: false),
            ),
          ],
        ),
      ),
    );
  }

  List<String> _precacheMediaUrlsForPost(PostModel post) {
    final mediaItems = post.mediaItems.isNotEmpty
        ? post.mediaItems
        : postMediaItemsFromData(<String, dynamic>{
            'mediaUrls': post.mediaUrls,
            'imageUrl': post.imageUrl,
          });

    final urls = <String>[];
    for (final item in mediaItems) {
      if (item.isVideo) {
        continue;
      }
      final url = item.url.trim();
      if (url.isEmpty) {
        continue;
      }
      if (url.startsWith('http://') || url.startsWith('https://')) {
        urls.add(url);
      }
    }

    return urls;
  }

  void _scheduleFeedMediaPrecache(List<PostModel> feedPosts, int activeIndex) {
    if (feedPosts.isEmpty || !mounted) {
      return;
    }

    final normalizedIndex = activeIndex.clamp(0, feedPosts.length - 1);
    final nextPosts =
        feedPosts.skip(normalizedIndex).take(2).toList(growable: false);
    final signature = nextPosts
        .map(
            (post) => '${post.id}:${_precacheMediaUrlsForPost(post).join(',')}')
        .join('|');

    if (signature.isEmpty || signature == _lastPrecachedFeedSignature) {
      return;
    }

    _lastPrecachedFeedSignature = signature;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || signature != _lastPrecachedFeedSignature) {
        return;
      }

      for (final post in nextPosts) {
        for (final url in _precacheMediaUrlsForPost(post)) {
          precacheImage(CachedNetworkImageProvider(url), context);
        }
      }
    });
  }

  Future<void> _maybeShowSpontaneousPrompt() async {
    final uid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
    if (uid.isEmpty || !mounted) {
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final storageKey = '$_spontaneousPromptShownKeyPrefix::$uid';
    final lastShownMillis = prefs.getInt(storageKey);
    final nowUtc = DateTime.now().toUtc();

    if (lastShownMillis != null) {
      final lastShownUtc =
          DateTime.fromMillisecondsSinceEpoch(lastShownMillis, isUtc: true);
      if (nowUtc.difference(lastShownUtc) < const Duration(hours: 24)) {
        return;
      }
    }

    if (!mounted) return;
    final activeTask =
        await SpontaneousChallengeService.currentTaskForUser(uid);
    if (!mounted) return;

    if (activeTask != null) {
      await showActiveSpontaneousTaskModal(context, task: activeTask);
    } else {
      await showSpontaneousLotteryModal(context, userId: uid);
      if (!mounted) return;
      final newlyAssignedTask =
          await SpontaneousChallengeService.currentTaskForUser(uid);
      if (!mounted) return;
      if (newlyAssignedTask != null) {
        await showActiveSpontaneousTaskModal(
          context,
          task: newlyAssignedTask,
        );
      }
    }

    if (!mounted) return;
    await _loadActiveSpontaneousTask();

    if (!mounted) return;
    await prefs.setInt(storageKey, nowUtc.millisecondsSinceEpoch);
  }

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

  Color _feedBackgroundColor(BuildContext context) {
    return _isLightMode(context)
        ? const Color(0xFFF2F7FF)
        : const Color(0xFF0B1019);
  }

  Future<PublicUserProfile?> _authorFuture(String authorId) {
    final normalizedId = authorId.trim();
    if (normalizedId.isEmpty) {
      return Future<PublicUserProfile?>.error(
        StateError('Missing authorId for users lookup'),
      );
    }

    final cached = _authorFutureCache[normalizedId];
    if (cached != null) return cached;

    final future = _publicUserProfileService
        .fetchProfile(normalizedId)
        .catchError((error) {
      _authorFutureCache.remove(normalizedId);
      throw error;
    });

    _authorFutureCache[normalizedId] = future;
    return future;
  }

  void _navigateToScreen(Widget screen) {
    unawaited(
      _pushWithFeedPlaybackPaused<void>(
        PageRouteBuilder(
          pageBuilder: (context, animation, secondaryAnimation) => screen,
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            return FadeTransition(opacity: animation, child: child);
          },
        ),
      ),
    );
  }

  bool _isPostLiked(PostModel post) {
    final postId = post.id.trim();
    final overlayIntent = PostInteractionOverlayService.interactionIntentFor(
      postId: postId,
      intent: 'likedByMe',
    );
    if (overlayIntent != null) {
      return overlayIntent;
    }
    final override = _likedOverrideByPostId[postId];
    return override ?? post.likedByCurrentUser;
  }

  bool _isPostSaved(PostModel post) {
    final postId = post.id.trim();
    final overlayIntent = PostInteractionOverlayService.interactionIntentFor(
      postId: postId,
      intent: 'savedByMe',
    );
    if (overlayIntent != null) {
      return overlayIntent;
    }
    final override = _savedOverrideByPostId[postId];
    return override ?? post.savedByCurrentUser;
  }

  Future<void> _handleDoubleTap(PostModel post, Offset localPosition) async {
    final postId = post.id.trim();
    setState(() {
      _heartTapPosition = localPosition;
      _showDoubleTapHeart = true;
      _activeHeartPostId = postId;
    });

    if (!_likeInFlightPostIds.contains(postId) && postId.isNotEmpty) {
      await _togglePostLike(post);
    }

    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) {
        setState(() {
          _showDoubleTapHeart = false;
        });
      }
    });
  }

  Future<void> _showCommentsBottomSheet(PostModel post) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => PostCommentsSheet(
        postId: post.id,
        postAuthorId: post.authorId,
        onCommentSubmitted: () {
          final postId = post.id.trim();
          if (postId.isEmpty || !mounted) return;
          PostInteractionOverlayService.addDelta(postId: postId, comments: 1);
          setState(() {
            final currentCount =
                _commentCountOverrideByPostId[postId] ?? post.commentsCount;
            _commentCountOverrideByPostId[postId] = currentCount + 1;
          });
        },
      ),
    );
  }

  Future<void> _togglePostLike(PostModel post) async {
    final postId = post.id.trim();
    if (postId.isEmpty || _likeInFlightPostIds.contains(postId)) return;
    final previousLiked = _isPostLiked(post);
    final nextLiked = !previousLiked;

    setState(() {
      _likeInFlightPostIds.add(postId);
      _likedOverrideByPostId[postId] = nextLiked;
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
        postAuthorId: post.authorId,
        currentlyLikedByMe: previousLiked,
      );
    } catch (error) {
      if (!mounted) return;
      final denied = FirestoreRuleFeedback.isPermissionDenied(error);
      if (!denied) {
        PostInteractionOverlayService.addDelta(
          postId: postId,
          likes: previousLiked ? 1 : -1,
        );
        PostInteractionOverlayService.setInteractionIntent(
          postId: postId,
          likedByMe: previousLiked,
        );
        setState(() {
          _likedOverrideByPostId[postId] = previousLiked;
        });
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

  Future<void> _registerPostShare(PostModel post, {bool silent = false}) async {
    final postId = post.id.trim();
    if (postId.isEmpty || _shareInFlightPostIds.contains(postId)) return;

    if (!silent) {
      setState(() {
        _shareInFlightPostIds.add(postId);
        final currentCount =
            _shareCountOverrideByPostId[postId] ?? post.sharesCount;
        _shareCountOverrideByPostId[postId] = currentCount + 1;
      });
      PostInteractionOverlayService.addDelta(postId: postId, shares: 1);
    }
    try {
      await _postService.registerPostShare(
        postId: postId,
        postAuthorId: post.authorId,
      );
      // Optimistic share count already updated before request.
    } catch (error) {
      if (!mounted) return;
      if (silent) {
        return;
      }
      final denied = FirestoreRuleFeedback.isPermissionDenied(error);
      if (error is PostActionLimitException) {
        _showCenteredLimitAlert(error.message);
        return;
      }
      if (!denied) {
        PostInteractionOverlayService.addDelta(postId: postId, shares: -1);
        setState(() {
          final currentCount =
              _shareCountOverrideByPostId[postId] ?? post.sharesCount;
          _shareCountOverrideByPostId[postId] =
              (currentCount - 1).clamp(0, 1 << 30);
        });
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

  Future<void> _togglePostSave(PostModel post) async {
    final postId = post.id.trim();
    if (postId.isEmpty || _saveInFlightPostIds.contains(postId)) return;
    final previousSaved = _isPostSaved(post);
    final nextSaved = !previousSaved;

    setState(() {
      _saveInFlightPostIds.add(postId);
      _savedOverrideByPostId[postId] = nextSaved;
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
        currentlySavedByMe: previousSaved,
      );
    } catch (error) {
      if (!mounted) return;
      final denied = FirestoreRuleFeedback.isPermissionDenied(error);
      if (!denied) {
        PostInteractionOverlayService.addDelta(
          postId: postId,
          saves: previousSaved ? 1 : -1,
        );
        PostInteractionOverlayService.setInteractionIntent(
          postId: postId,
          savedByMe: previousSaved,
        );
        setState(() {
          _savedOverrideByPostId[postId] = previousSaved;
        });
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

  String _postShareLink(PostModel post) {
    final postId = post.id.trim();
    if (postId.isEmpty) {
      return 'https://hundred.app';
    }
    return 'https://hundred.app/post/$postId';
  }

  String _postShareText(PostModel post) {
    final title =
        post.title.trim().isNotEmpty ? post.title.trim() : 'פוסט חדש ב-HUNDRED';
    final description = post.description.trim();
    final category = post.category.trim();
    final link = _postShareLink(post);
    final lines = <String>[title];
    if (description.isNotEmpty) {
      lines.add(description);
    }
    if (category.isNotEmpty) {
      lines.add('קטגוריה: $category');
    }
    lines.add(link);
    return lines.join('\n');
  }

  Map<String, dynamic> _categoryNavigationPostMap(PostModel post) {
    return <String, dynamic>{
      'id': post.id,
      'postId': post.id,
      'authorId': post.authorId,
      'createdAt': post.createdAt,
      'category': post.category,
      'subCategory': post.subCategory,
      'status': post.status,
      'title': post.title,
      'description': post.description,
      'caption': post.description,
      'content': post.content.isNotEmpty ? post.content : post.description,
      'mediaUrl': post.imageUrl,
      'imageUrl': post.imageUrl,
      'mediaUrls': post.mediaUrls,
      'authorName': post.authorName,
      'profilePictureUrl': post.authorProfileImg,
      'location': post.location,
      'scoreAwarded': post.scoreAwarded,
      'likesCount': post.likesCount,
      'commentsCount': post.commentsCount,
      'sharesCount': post.sharesCount,
      'savesCount': post.savesCount,
      'likes': const <String>[],
      'savedBy': (() {
        final currentUid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
        if (!post.savedByCurrentUser || currentUid.isEmpty) {
          return const <String>[];
        }
        return <String>[currentUid];
      })(),
    };
  }

  Map<String, dynamic> _sharePayloadForPost(PostModel post) {
    final firstMedia =
        post.mediaItems.isNotEmpty ? post.mediaItems.first : null;
    final firstMediaUrl = firstMedia?.url.trim() ?? '';
    final imageCandidate =
        post.imageUrl.trim().isNotEmpty ? post.imageUrl.trim() : firstMediaUrl;

    return <String, dynamic>{
      'postId': post.id.trim(),
      'title': post.title.trim(),
      'description': post.description.trim(),
      'imageUrl': imageCandidate,
      'thumbnailUrl': imageCandidate,
      'authorId': post.authorId.trim(),
      'category': post.category.trim(),
      'subCategory': post.subCategory.trim(),
    };
  }

  Future<void> _showShareMenu(PostModel post) async {
    await ShareFlowLogService.log(
      'FEED_SHARE_MENU_OPEN',
      data: <String, Object?>{'postId': post.id},
    );
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final isLight = _isLightMode(context);
    final sheetBg = isLight ? const Color(0xFFF7FAFF) : const Color(0xFF0B1019);
    final titleColor = isLight ? const Color(0xFF1D2742) : Colors.white;
    final subtitleColor = isLight ? const Color(0xFF576581) : Colors.white70;

    final action = await showModalBottomSheet<_FeedShareMenuAction>(
      context: context,
      backgroundColor: sheetBg,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (sheetContext) {
        return SafeArea(
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('שתף פופ זה עם חברים',
                    style: TextStyle(
                        color: titleColor,
                        fontSize: 16,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _buildShareOption(Icons.copy_rounded, 'העתק קישור',
                        subtitleColor, isLight, () {
                      Navigator.of(sheetContext)
                          .pop(_FeedShareMenuAction.copyLink);
                    }),
                    _buildShareOption(
                        Icons.send_rounded, 'שלח לחבר', subtitleColor, isLight,
                        () {
                      Navigator.of(sheetContext)
                          .pop(_FeedShareMenuAction.sendToFriend);
                    }),
                    _buildShareOption(Icons.ios_share_rounded, 'שיתוף מערכת',
                        subtitleColor, isLight, () {
                      Navigator.of(sheetContext)
                          .pop(_FeedShareMenuAction.systemShare);
                    }),
                  ],
                )
              ],
            ),
          ),
        );
      },
    );

    if (!mounted || action == null) {
      await ShareFlowLogService.log(
        'FEED_SHARE_MENU_DISMISSED',
        data: <String, Object?>{'postId': post.id, 'mounted': mounted},
      );
      return;
    }

    await ShareFlowLogService.log(
      'FEED_SHARE_ACTION_SELECTED',
      data: <String, Object?>{
        'postId': post.id,
        'action': action.name,
      },
    );

    if (action == _FeedShareMenuAction.copyLink) {
      final link = _postShareLink(post);
      await Clipboard.setData(ClipboardData(text: link));
      await ShareFlowLogService.log(
        'FEED_SHARE_COPY_LINK_DONE',
        data: <String, Object?>{'postId': post.id, 'link': link},
      );
      _registerPostShare(post, silent: true);
      if (!mounted) return;
      messenger?.showSnackBar(
        const SnackBar(content: Text('הקישור הועתק ללוח! ??')),
      );
      return;
    }

    if (action == _FeedShareMenuAction.systemShare) {
      await ShareFlowLogService.log(
        'FEED_SHARE_SYSTEM_START',
        data: <String, Object?>{'postId': post.id},
      );
      await SharePlus.instance.share(
        ShareParams(text: _postShareText(post)),
      );
      await ShareFlowLogService.log(
        'FEED_SHARE_SYSTEM_DONE',
        data: <String, Object?>{'postId': post.id},
      );
      _registerPostShare(post, silent: true);
      return;
    }

    await ShareFlowLogService.log(
      'FEED_SHARE_TARGETS_SHEET_OPEN',
      data: <String, Object?>{'postId': post.id},
    );
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => PostShareTargetsSheet(
        postPayload: _sharePayloadForPost(post),
        onShareSent: () => _registerPostShare(post, silent: false),
      ),
    );
    await ShareFlowLogService.log(
      'FEED_SHARE_TARGETS_SHEET_CLOSED',
      data: <String, Object?>{'postId': post.id},
    );
  }

  Future<void> _reportPostFromFeed(PostModel post) async {
    final currentUid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
    final authorUid = post.authorId.trim();
    final postId = post.id.trim();

    if (currentUid.isEmpty || authorUid.isEmpty || postId.isEmpty) {
      return;
    }
    if (authorUid == currentUid) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('לא ניתן לדווח על הפוסט של עצמך.')),
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
    if (details == null || details.trim().isEmpty || !mounted) {
      return;
    }

    try {
      await _reportService.submitPostReport(
        targetPostId: postId,
        targetUserUid: authorUid,
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

  Widget _buildShareOption(IconData icon, String label, Color labelColor,
      bool isLight, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          CircleAvatar(
              radius: 25,
              backgroundColor:
                  isLight ? const Color(0xFFE7EEFF) : const Color(0xFF1E2632),
              child: Icon(
                icon,
                color: isLight ? const Color(0xFF45557A) : Colors.white,
              )),
          const SizedBox(height: 8),
          Text(label, style: TextStyle(color: labelColor, fontSize: 12)),
        ],
      ),
    );
  }

  @override
  void dispose() {
    MainBottomNav.feedPlaybackPausedByComposer
        .removeListener(_syncForegroundStateWithComposer);
    _spontaneousPromptTimer?.cancel();
    _spontaneousCountdownTimer?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  List<Color> _colorsForCategory(String category) {
    switch (category) {
      case 'אקסטרים':
        return [const Color(0xFFFF7043), const Color(0xFFFFB74D)];
      case 'טיולים וחופשות':
        return [const Color(0xFF1F9D84), const Color(0xFF53C1F9)];
      case 'משפחה':
        return [const Color(0xFFE573B6), const Color(0xFFFFC1D9)];
      case 'חברים':
        return [const Color(0xFF845EC2), const Color(0xFFB388FF)];
      case 'אטרקציות':
        return [const Color(0xFF3D7EFF), const Color(0xFF8FD3FF)];
      case 'אוכל':
        return [const Color(0xFFFFD166), const Color(0xFFFFFCBB)];
      case 'אתגרים':
        return [const Color(0xFFE53935), const Color(0xFFFF7043)];
      case 'מעשים טובים':
        return [const Color(0xFF2BBBAD), const Color(0xFF8FE9D5)];
      case 'בשביל עצמי':
        return [const Color(0xFF6C63FF), const Color(0xFF8BB6FF)];
      case 'ספורט':
        return [const Color(0xFF00B8D4), const Color(0xFF64FFDA)];
      case 'דברים חדשים':
        return [const Color(0xFF8E24AA), const Color(0xFFFF80AB)];
      default:
        return [const Color(0xFF2A2F3A), const Color(0xFF1E2632)];
    }
  }

  PostModel _postFromMap(
    Map<String, dynamic> data, {
    Set<String> blockedUids = const <String>{},
  }) {
    final rawLikes = (data['likes'] as List<dynamic>? ?? const []);
    final likes = rawLikes
        .map((item) => item.toString().trim())
        .where((uid) => uid.isNotEmpty && !blockedUids.contains(uid))
        .toList(growable: false);
    final rawComments = (data['comments'] as List<dynamic>? ?? const []);
    final filteredComments = rawComments.where((comment) {
      if (comment is! Map) {
        return true;
      }
      final map = Map<String, dynamic>.from(comment);
      final authorId = ((map['authorId'] as String?) ??
              (map['authorUid'] as String?) ??
              (map['userId'] as String?) ??
              (map['uid'] as String?) ??
              '')
          .trim();
      return authorId.isEmpty || !blockedUids.contains(authorId);
    }).toList(growable: false);
    final savedBy = (data['savedBy'] as List<dynamic>? ?? const []);
    final currentUid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
    final likedByCurrentUser =
        currentUid.isNotEmpty && likes.contains(currentUid);
    final savedByCurrentUser = currentUid.isNotEmpty &&
        savedBy.map((item) => item.toString().trim()).contains(currentUid);
    final createdAtRaw = data['createdAt'];
    final authorMap =
        (data['author'] as Map<String, dynamic>?) ?? <String, dynamic>{};
    final uid = _authorIdFromPostData(data);
    final rawUsername = ((data['username'] as String?) ??
            (data['authorName'] as String?) ??
            (data['authorDisplayName'] as String?) ??
            (data['displayName'] as String?) ??
            (authorMap['username'] as String?) ??
            (authorMap['displayName'] as String?) ??
            '')
        .trim();
    final category = (data['category'] as String? ?? kGeneralCategory).trim();
    final subCategory = (data['subCategory'] as String? ?? '').trim();
    final audience = _postAudience(data);
    final authorIsPrivate = (data['isPrivate'] as bool?) ??
        (authorMap['isPrivate'] as bool?) ??
        true;
    final title = (data['title'] as String? ?? '').trim();
    final description =
        ((data['description'] as String?) ?? (data['caption'] as String?) ?? '')
            .trim();
    final profilePictureUrl = (data['profilePictureUrl'] as String? ??
            data['profileImageUrl'] as String? ??
            data['avatarUrl'] as String? ??
            data['authorProfileImg'] as String? ??
            authorMap['profilePictureUrl'] as String? ??
            authorMap['profileImageUrl'] as String? ??
            authorMap['avatarUrl'] as String? ??
            '')
        .trim();
    final mediaItems = postMediaItemsFromData(data);
    final mediaUrls = mediaItems
        .map((item) => item.url.trim())
        .where((url) => url.isNotEmpty)
        .toList(growable: false);
    final participantUids = (data['members'] as List<dynamic>? ??
            data['participants'] as List<dynamic>? ??
            const <dynamic>[])
        .map((e) => e.toString().trim())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList(growable: false);
    final fallbackImageUrl =
        ((data['imageUrl'] as String?) ?? (data['mediaUrl'] as String?) ?? '')
            .trim();
    final primaryMedia =
        mediaUrls.isNotEmpty ? mediaUrls.first : fallbackImageUrl;
    final location = _extractLocation(data);
    final scoreAwardedRaw = data['scoreAwarded'];
    final scoreAwarded = scoreAwardedRaw is num
        ? scoreAwardedRaw.toInt()
        : int.tryParse(scoreAwardedRaw?.toString() ?? '') ?? 0;

    return PostModel(
      id: (data['id'] as String? ?? data['postId'] as String? ?? '').trim(),
      authorId: uid,
      createdAt: createdAtRaw is Timestamp ? createdAtRaw.toDate() : null,
      category: category,
      subCategory: subCategory,
      audience: audience,
      status: (data['status'] as String? ?? 'published').trim(),
      colors: _colorsForCategory(category),
      content: description,
      description: description,
      title: title,
      location: location,
      scoreAwarded: scoreAwarded,
      participantUids: participantUids,
      likesCount: likes.length,
      commentsCount:
          (data['commentsCount'] as num?)?.toInt() ?? filteredComments.length,
      sharesCount: (data['sharesCount'] as num?)?.toInt() ?? 0,
      savesCount: (data['savesCount'] as num?)?.toInt() ?? savedBy.length,
      likedByCurrentUser: likedByCurrentUser,
      savedByCurrentUser: savedByCurrentUser,
      authorIsPrivate: authorIsPrivate,
      isFollowingFeed: true,
      authorName: rawUsername.isNotEmpty
          ? rawUsername
          : (uid.isEmpty
              ? 'user'
              : uid.substring(0, uid.length > 6 ? 6 : uid.length)),
      authorProfileImg: profilePictureUrl,
      imageUrl: primaryMedia,
      mediaUrls: mediaUrls,
      mediaItems: mediaItems,
      eventGroupId: (data['eventGroupId'] as String? ?? '').trim(),
      linkedGroupId: (data['linkedGroupId'] as String? ?? '').trim(),
    );
  }

  bool _isDeletedAuthorPost(Map<String, dynamic> data) {
    final directDeleted = (data['isDeleted'] as bool?) ?? false;
    if (directDeleted) {
      return true;
    }

    final authorMap = data['author'];
    if (authorMap is Map && (authorMap['isDeleted'] as bool? ?? false)) {
      return true;
    }

    return false;
  }

  List<PostModel> _randomizePostsOnce(List<PostModel> posts) {
    final signature = posts
        .map((post) =>
            '${post.id}:${post.createdAt?.millisecondsSinceEpoch ?? 0}:${post.category}:${post.subCategory}')
        .join('|');

    if (_randomizedFeedSignature != signature) {
      final shuffledIds = posts.map((post) => post.id).toList()
        ..shuffle(Random());
      _randomizedFeedOrder = <String, int>{
        for (int index = 0; index < shuffledIds.length; index++)
          shuffledIds[index]: index,
      };
      _randomizedFeedSignature = signature;
    }

    final randomizedPosts = List<PostModel>.from(posts);
    randomizedPosts.sort((a, b) {
      final orderA = _randomizedFeedOrder[a.id] ?? randomizedPosts.length;
      final orderB = _randomizedFeedOrder[b.id] ?? randomizedPosts.length;
      return orderA.compareTo(orderB);
    });
    return randomizedPosts;
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

  String _authorIdFromPostData(Map<String, dynamic> data) {
    final authorMap =
        (data['author'] as Map<String, dynamic>?) ?? <String, dynamic>{};
    return ((data['authorId'] as String?) ??
            (data['authorUid'] as String?) ??
            (data['userId'] as String?) ??
            (data['uid'] as String?) ??
            (authorMap['authorId'] as String?) ??
            (authorMap['authorUid'] as String?) ??
            (authorMap['userId'] as String?) ??
            (authorMap['uid'] as String?) ??
            '')
        .trim();
  }

  String _formatCompactCount(int value) {
    if (value < 10000) {
      return value.toString();
    }

    if (value < 1000000) {
      final scaled = value / 1000;
      final formatted =
          scaled >= 100 ? scaled.toStringAsFixed(0) : scaled.toStringAsFixed(1);
      return '${formatted.replaceAll(RegExp(r'\\.0$'), '')}K';
    }

    final scaled = value / 1000000;
    final formatted =
        scaled >= 100 ? scaled.toStringAsFixed(0) : scaled.toStringAsFixed(1);
    return '${formatted.replaceAll(RegExp(r'\\.0$'), '')}M';
  }

  String _extractLocation(Map<String, dynamic> data) {
    String textFrom(String key) => (data[key] as String? ?? '').trim();

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

    final nestedLocation = data['location'];
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

  int _displayedCommentCount(PostModel post) {
    return (_commentCountOverrideByPostId[post.id.trim()] ?? post.commentsCount)
        .clamp(0, 1 << 30)
        .toInt();
  }

  int _displayedShareCount(PostModel post) {
    return (_shareCountOverrideByPostId[post.id.trim()] ?? post.sharesCount)
        .clamp(0, 1 << 30)
        .toInt();
  }

  int _displayedContributionScore(
    PostModel post, {
    required int displayedLikes,
    required int displayedSaves,
    required int displayedComments,
    required int displayedShares,
  }) {
    final base = post.scoreAwarded;
    return _postContributionScore(
      scoreAwarded: base,
      likesCount: displayedLikes,
      commentsCount: displayedComments,
      sharesCount: displayedShares,
      savesCount: displayedSaves,
    );
  }

  List<String> _participantUidsForPost(PostModel post,
      {bool includeAuthor = false}) {
    final authorId = post.authorId.trim();
    return post.participantUids
        .map((uid) => uid.trim())
        .where((uid) => uid.isNotEmpty)
        .where((uid) => includeAuthor || uid != authorId)
        .toSet()
        .toList(growable: false);
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
        final isLight = _isLightMode(context);
        final shouldUnfollow = await showDialog<bool>(
          context: context,
          builder: (dialogContext) {
            return Directionality(
              textDirection: TextDirection.rtl,
              child: AlertDialog(
                backgroundColor:
                    isLight ? const Color(0xFFF8FBFF) : const Color(0xFF121C2C),
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
                    color: isLight ? const Color(0xFF1E2A45) : Colors.white,
                  ),
                ),
                content: Text(
                  'האם אתה בטוח שברצונך להסיר מעקב מהמשתמש הזה?',
                  style: TextStyle(
                    color: isLight ? const Color(0xFF586784) : Colors.white70,
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
            final isLight = _isLightMode(dialogContext);
            return Directionality(
              textDirection: TextDirection.rtl,
              child: AlertDialog(
                backgroundColor:
                    isLight ? const Color(0xFFF8FBFF) : const Color(0xFF121C2C),
                title: Text(
                  'ביטול בקשת מעקב?',
                  style: TextStyle(
                    color: isLight ? const Color(0xFF1E2A45) : Colors.white,
                  ),
                ),
                content: Text(
                  'לבטל את בקשת המעקב למשתמש הזה?',
                  style: TextStyle(
                    color: isLight ? const Color(0xFF586784) : Colors.white70,
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

  Future<void> _openParticipantsSheet(PostModel post) async {
    final linkedGroupId = post.linkedGroupId.trim();
    final hasLinkedGroup = linkedGroupId.isNotEmpty;
    final participantUids = _participantUidsForPost(post, includeAuthor: false);
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
        final isLight = _isLightMode(sheetContext);
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
                  color: isLight
                      ? const Color(0xFFF7FAFF)
                      : const Color(0xFF101826),
                  borderRadius: BorderRadius.circular(22),
                ),
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
                child: FutureBuilder<List<PublicUserProfile>>(
                  future: _participantProfilesFor(participantUids),
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: CircularProgressIndicator(),
                        ),
                      );
                    }

                    final profiles =
                        snapshot.data ?? const <PublicUserProfile>[];
                    final hasParticipants = profiles.isNotEmpty;
                    if (profiles.isEmpty && !hasLinkedGroup) {
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            'אין משתתפים להצגה',
                            style: TextStyle(
                              color: isLight
                                  ? const Color(0xFF586784)
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
                            color: isLight
                                ? const Color(0xFF1E2A45)
                                : Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        if (hasLinkedGroup) ...[
                          const SizedBox(height: 8),
                          FutureBuilder<_LinkedGroupMeta?>(
                            future: _fetchLinkedGroupMeta(linkedGroupId),
                            builder: (context, groupSnapshot) {
                              final groupMeta = groupSnapshot.data;
                              if (groupSnapshot.connectionState ==
                                      ConnectionState.waiting &&
                                  groupMeta == null) {
                                return Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 12,
                                  ),
                                  decoration: BoxDecoration(
                                    color: isLight
                                        ? const Color(0xFFEAF2FF)
                                        : const Color(0xFF1A2435),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: const Center(
                                    child: SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    ),
                                  ),
                                );
                              }

                              if (groupMeta == null) {
                                return Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 7,
                                  ),
                                  decoration: BoxDecoration(
                                    color: isLight
                                        ? const Color(0xFFEAF2FF)
                                        : const Color(0xFF1A2435),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: isLight
                                          ? const Color(0xFFA9C3FF)
                                          : const Color(0xFF53C1F9)
                                              .withValues(alpha: 0.22),
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(
                                        Icons.link_rounded,
                                        size: 16,
                                        color: isLight
                                            ? const Color(0xFF5A6CFF)
                                            : const Color(0xFF9EDBFF),
                                      ),
                                      const SizedBox(width: 6),
                                      Expanded(
                                        child: Text(
                                          'קבוצה מקושרת',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: isLight
                                                ? const Color(0xFF33466D)
                                                : const Color(0xFFEAF4FF),
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              }

                              return Container(
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
                                              horizontal: 8,
                                              vertical: 6,
                                            ),
                                            tapTargetSize: MaterialTapTargetSize
                                                .shrinkWrap,
                                            visualDensity: const VisualDensity(
                                              horizontal: -2,
                                              vertical: -2,
                                            ),
                                          ),
                                          onPressed: () {
                                            _showLinkedGroupDetailsDialog(
                                              groupMeta,
                                            );
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
                                                onPressed: () {
                                                  Navigator.of(sheetContext)
                                                      .pop();
                                                  _navigateToScreen(
                                                    ChatRoomScreen(
                                                      chatName: groupMeta.name,
                                                      avatarUrl: groupMeta
                                                              .imageUrl.isEmpty
                                                          ? null
                                                          : groupMeta.imageUrl,
                                                      chatId: groupMeta.groupId,
                                                      isDirectChat: false,
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
                                                      groupMeta.groupId,
                                                    );
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
                                                          'בקשת ההצטרפות נשלחה',
                                                        ),
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
                                                          'לא ניתן להצטרף לקבוצה: $error',
                                                        ),
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
                              );
                            },
                          ),
                        ],
                        const SizedBox(height: 12),
                        if (hasParticipants)
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
                                        ? const Color(0xFFEFF4FF)
                                        : const Color(0xFF1A2435),
                                    borderRadius: BorderRadius.circular(14),
                                    border: Border.all(
                                        color: const Color(0xFF53C1F9)
                                            .withValues(alpha: 0.22)),
                                  ),
                                  child: Row(
                                    children: [
                                      CircleAvatar(
                                        radius: 18,
                                        backgroundColor: isLight
                                            ? const Color(0xFFC8B5FF)
                                            : const Color(0xFF9E7CFF),
                                        backgroundImage:
                                            profile.profilePictureUrl.isNotEmpty
                                                ? NetworkImage(
                                                    profile.profilePictureUrl)
                                                : null,
                                        child: profile.profilePictureUrl.isEmpty
                                            ? Text(
                                                name.isNotEmpty
                                                    ? name.characters.first
                                                    : '?',
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              )
                                            : null,
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: InkWell(
                                          onTap: () {
                                            Navigator.of(sheetContext).pop();
                                            _navigateToScreen(UserDetailScreen(
                                                uid: profile.userId));
                                          },
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                name,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  color: isLight
                                                      ? const Color(0xFF273A5D)
                                                      : Colors.white,
                                                  fontWeight: FontWeight.w700,
                                                ),
                                              ),
                                              const SizedBox(height: 2),
                                              Text(
                                                profile.handle,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  color: isLight
                                                      ? const Color(0xFF6C7A95)
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
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 8, vertical: 6),
                                          decoration: BoxDecoration(
                                            color: isLight
                                                ? const Color(0xFFDDE7FF)
                                                : Colors.white10,
                                            borderRadius:
                                                BorderRadius.circular(10),
                                          ),
                                          child: Text(
                                            'אתה',
                                            style: TextStyle(
                                              color: isLight
                                                  ? const Color(0xFF546382)
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
                                          builder: (context, followSnapshot) {
                                            final relationship =
                                                followSnapshot.data ??
                                                    const FollowRelationship();
                                            final isFollowing =
                                                relationship.isFollowing;
                                            final isRequestPending =
                                                relationship.isRequestPending;
                                            return ElevatedButton(
                                              onPressed: () =>
                                                  _toggleFollowFromParticipantRow(
                                                targetUid: profile.userId,
                                                relationship: relationship,
                                              ),
                                              style: ElevatedButton.styleFrom(
                                                elevation: 0,
                                                minimumSize: const Size(68, 34),
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
                                                            0xFFD5E2FF)
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
                                                foregroundColor: isFollowing
                                                    ? (isLight
                                                        ? const Color(
                                                            0xFF2E3E63)
                                                        : Colors.white)
                                                    : Colors.white,
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                        horizontal: 10,
                                                        vertical: 6),
                                                shape: RoundedRectangleBorder(
                                                  borderRadius:
                                                      BorderRadius.circular(10),
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
                                                  fontWeight: FontWeight.w700,
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
                          )
                        else
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 18),
                            child: Text(
                              'אין משתתפים מסומנים בפוסט זה',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: isLight
                                    ? const Color(0xFF586784)
                                    : Colors.white70,
                              ),
                            ),
                          ),
                      ],
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
                    groupData,
                    'subCategory',
                    fallback: 'ללא',
                  );
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
                                : Colors.white24,
                          ),
                        ),
                        child: Row(
                          children: [
                            CircleAvatar(
                              radius: 30,
                              backgroundColor: const Color(0xFF9E7CFF),
                              backgroundImage: groupMeta.imageUrl.isNotEmpty
                                  ? NetworkImage(groupMeta.imageUrl)
                                  : null,
                              child: groupMeta.imageUrl.isEmpty
                                  ? const Icon(
                                      Icons.groups_rounded,
                                      color: Colors.white,
                                      size: 28,
                                    )
                                  : null,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    groupMeta.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color:
                                          isLight ? Colors.black : Colors.white,
                                      fontSize: 18,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    groupMeta.isPublic
                                        ? 'קבוצה ציבורית'
                                        : 'קבוצה פרטית',
                                    style: TextStyle(
                                      color: isLight
                                          ? const Color(0xFF3D517A)
                                          : const Color(0xFF9EDBFF),
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),
                      Expanded(
                        child: SingleChildScrollView(
                          child: Column(
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: _detailCard(
                                      icon: Icons.people_alt_rounded,
                                      title: 'חברים',
                                      value: '$membersCount',
                                      accent: const Color(0xFF53C1F9),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: _detailCard(
                                      icon: Icons.verified_user_rounded,
                                      title: 'אישור מנהל',
                                      value: approvalRequired
                                          ? 'נדרש אישור'
                                          : 'הצטרפות פתוחה',
                                      accent: const Color(0xFF9E7CFF),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              Row(
                                children: [
                                  Expanded(
                                    child: _detailCard(
                                      icon: Icons.category_rounded,
                                      title: 'קטגוריה',
                                      value: '$category • $subCategory',
                                      accent: const Color(0xFF5A8BFF),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: _detailCard(
                                      icon: Icons.cake_rounded,
                                      title: 'טווח גילאים',
                                      value: ageRangeText,
                                      accent: const Color(0xFFEC7F5A),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              _detailCard(
                                icon: Icons.place_rounded,
                                title: 'מיקום',
                                value: location,
                                accent: const Color(0xFF46D3FF),
                              ),
                              const SizedBox(height: 10),
                              _detailCard(
                                icon: Icons.event_rounded,
                                title: 'תאריך מפגש',
                                value: _formatDateTime(date),
                                accent: const Color(0xFF9E7CFF),
                              ),
                              const SizedBox(height: 10),
                              _detailCard(
                                icon: Icons.access_time_rounded,
                                title: 'נוצר בתאריך',
                                value: _formatDateTime(createdAt),
                                accent: const Color(0xFF53C1F9),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      ElevatedButton.icon(
                        onPressed: () {
                          Navigator.of(dialogContext).pop();
                          _navigateToScreen(
                            GroupDetailsScreen(
                              groupId: groupMeta.groupId,
                              isAdmin: false,
                            ),
                          );
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF5A8BFF),
                          foregroundColor: Colors.white,
                          minimumSize: const Size.fromHeight(42),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        icon: const Icon(Icons.open_in_new_rounded, size: 18),
                        label: const Text('פתח מסך קבוצה מלא'),
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

    final currentUid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
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

  Stream<Set<String>> _followingIdsStream() {
    final currentUid = FirebaseAuth.instance.currentUser?.uid;
    if (currentUid == null || currentUid.isEmpty) {
      return Stream<Set<String>>.value(<String>{});
    }

    return Stream.multi((controller) {
      Set<String>? lastGood;

      final sub = FirebaseFirestore.instance
          .collection('users')
          .doc(currentUid)
          .snapshots()
          .listen(
        (snapshot) {
          final data = snapshot.data() ?? <String, dynamic>{};
          final following = data['following'];
          if (following is! List) {
            final fallback = lastGood ?? <String>{};
            lastGood = fallback;
            controller.add(fallback);
            return;
          }
          final value = following
              .map((uid) => uid.toString().trim())
              .where((uid) => uid.isNotEmpty)
              .toSet();
          lastGood = value;
          controller.add(value);
        },
        onError: (Object error, StackTrace stackTrace) {
          if (_isRecoverableFeedStreamError(error)) {
            debugPrint('Following stream recoverable error: $error');
            if (lastGood != null) {
              controller.add(lastGood!);
            }
            return;
          }
          controller.addError(error, stackTrace);
        },
      );

      controller.onCancel = () async {
        await sub.cancel();
      };
    });
  }

  List<PostModel> _postsForFeedScope(
    List<PostModel> posts,
    Set<String> followingIds, {
    bool alreadyScopedByBackend = false,
  }) {
    if (isForYouFeed || alreadyScopedByBackend) {
      return posts;
    }

    return posts
        .where((post) => followingIds.contains(post.authorId.trim()))
        .toList(growable: false);
  }

  String _postAudience(Map<String, dynamic> data) {
    return (data['audience'] as String? ?? 'public').trim().toLowerCase();
  }

  Future<Set<String>> _resolveBlockedAuthorsForFeed(
    Set<String> authorIds,
    Set<String> blockedUids,
  ) async {
    final effectiveBlocked = <String>{...blockedUids};
    if (authorIds.isEmpty) {
      return effectiveBlocked;
    }

    final currentUid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
    final toCheck = authorIds
        .where((authorId) =>
            authorId.isNotEmpty &&
            authorId != currentUid &&
            !effectiveBlocked.contains(authorId))
        .toSet();
    if (toCheck.isEmpty) {
      return effectiveBlocked;
    }

    final results = await Future.wait(
      toCheck.map((authorId) async {
        try {
          final isBlocked =
              await _blockUserService.isEitherUserBlocked(authorId);
          return MapEntry(authorId, isBlocked);
        } catch (_) {
          return MapEntry(authorId, false);
        }
      }),
    );

    for (final result in results) {
      if (result.value) {
        effectiveBlocked.add(result.key);
      }
    }

    return effectiveBlocked;
  }

  Future<List<PostModel>> _applyAudienceFilter(
    List<PostModel> posts, {
    Set<String> blockedUids = const <String>{},
  }) async {
    final authorIds = posts
        .map((post) => post.authorId.trim())
        .where((authorId) => authorId.isNotEmpty)
        .toSet();

    final effectiveBlockedAuthorIds =
        await _resolveBlockedAuthorsForFeed(authorIds, blockedUids);

    final visiblePosts = posts.where((post) {
      final authorId = post.authorId.trim();
      if (authorId.isEmpty) {
        return false;
      }
      return !effectiveBlockedAuthorIds.contains(authorId);
    }).toList(growable: false);

    if (visiblePosts.isEmpty) {
      return const <PostModel>[];
    }

    final profilesByAuthorId = <String, PublicUserProfile?>{
      for (final entry in await Future.wait(
        visiblePosts
            .map((post) => post.authorId.trim())
            .where((authorId) => authorId.isNotEmpty)
            .toSet()
            .map(
              (authorId) async => MapEntry(
                authorId,
                await _publicUserProfileService.fetchProfile(authorId),
              ),
            ),
      ))
        entry.key: entry.value,
    };

    final friendsOnlyAuthors = visiblePosts
        .where((post) {
          final audience = post.audience.trim().toLowerCase();
          return audience == 'friends';
        })
        .map((post) => post.authorId.trim())
        .where((authorId) => authorId.isNotEmpty)
        .toSet();

    final privateAuthors = visiblePosts
        .where((post) {
          final authorId = post.authorId.trim();
          if (authorId.isEmpty) {
            return true;
          }
          final profile = profilesByAuthorId[authorId];
          if (profile == null) {
            return true;
          }
          if (!profile.exists) {
            return true;
          }
          return profile.isPrivate;
        })
        .map((post) => post.authorId.trim())
        .where((authorId) => authorId.isNotEmpty)
        .toSet();

    if (friendsOnlyAuthors.isEmpty && privateAuthors.isEmpty) {
      return visiblePosts;
    }

    final mutualChecks = await Future.wait(
      friendsOnlyAuthors.map(
        (authorId) async => MapEntry(
          authorId,
          await _socialService.isMutualFollow(authorId),
        ),
      ),
    );

    final followingChecks = await Future.wait(
      privateAuthors.map(
        (authorId) async => MapEntry(
          authorId,
          await _socialService.isFollowingUser(authorId),
        ),
      ),
    );

    final mutualAllowedAuthors = mutualChecks
        .where((entry) => entry.value)
        .map((entry) => entry.key)
        .toSet();
    final followingAllowedAuthors = followingChecks
        .where((entry) => entry.value)
        .map((entry) => entry.key)
        .toSet();

    return visiblePosts.where((post) {
      final audience = post.audience.trim().toLowerCase();
      final authorId = post.authorId.trim();
      if (audience == 'friends') {
        return mutualAllowedAuthors.contains(authorId);
      }
      if (post.authorIsPrivate) {
        return followingAllowedAuthors.contains(authorId);
      }
      return true;
    }).toList(growable: false);
  }

  Future<List<PostModel>> _resolveAudienceFilteredPosts(
    List<PostModel> posts, {
    Set<String> blockedUids = const <String>{},
  }) {
    if (posts.isEmpty) {
      return Future<List<PostModel>>.value(const <PostModel>[]);
    }

    final postSignature = posts
        .map((post) => post.id.trim())
        .where((id) => id.isNotEmpty)
        .join('|');
    final blockedSignature = blockedUids.toList(growable: false)..sort();
    final signature = '$postSignature::${blockedSignature.join(',')}';

    if (signature.isEmpty) {
      return Future<List<PostModel>>.value(const <PostModel>[]);
    }

    return _audienceFilteredPostsCache.putIfAbsent(
      signature,
      () => _applyAudienceFilter(
        posts,
        blockedUids: blockedUids,
      ).catchError((Object error, StackTrace stackTrace) {
        // Never let a transient read failure (e.g. permission/App Check
        // hiccup) cache a broken Future forever and blank out the feed —
        // evict it so the next rebuild retries, and fail open with the
        // already blocked/scoped posts instead of showing nothing.
        _audienceFilteredPostsCache.remove(signature);
        if (kDebugMode) {
          debugPrint('Audience filter failed, showing posts unfiltered: $error');
        }
        return posts;
      }),
    );
  }

  List<PostModel> _excludeCurrentUserPosts(List<PostModel> posts) {
    final currentUid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
    if (currentUid.isEmpty) {
      return posts;
    }

    return posts
        .where((post) => post.authorId.trim() != currentUid)
        .toList(growable: false);
  }

  Set<String> _seenIdsForFeedDisplayBatch(List<PostModel> baseFeedPosts) {
    final snapshot = resolveFeedDisplaySeenSnapshot(
      posts: baseFeedPosts,
      currentSeenPostIds: _feedSeenIds,
      previousBatchSignature: _feedDisplayBatchSignature,
      previousBatchSeenPostIds: _feedDisplayBatchSeenIds,
    );

    _feedDisplayBatchSignature = snapshot.signature;
    _feedDisplayBatchSeenIds = snapshot.seenPostIds;
    return _feedDisplayBatchSeenIds;
  }

  void _resetFeedDisplayBatchSnapshot() {
    _feedDisplayBatchSignature = '';
    _feedDisplayBatchSeenIds = <String>{};
  }

  bool _hasMoreUnseenPosts(List<PostModel> baseFeedPosts) {
    return filterFeedPostsForFreshnessAndSeen(
      baseFeedPosts,
      seenPostIds: _feedSeenIds,
    ).isNotEmpty;
  }

  void _refreshFeedOnScopeSwitch(bool forYouFeed) {
    _hasShownExhaustedFeedSheet = false;
    _resetFeedDisplayBatchSnapshot();
    setState(() {
      isForYouFeed = forYouFeed;
      _currentFeedPageIndex = 0;
      _feedRefreshToken++;
      _randomizedFeedSignature = '';
      _randomizedFeedOrder = <String, int>{};
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_pageController.hasClients) return;
      _pageController.jumpToPage(0);
    });
  }

  Widget _buildFeedState({
    required Widget child,
    String? activePostSubCategory,
    bool showLoader = false,
  }) {
    return Stack(
      children: [
        child,
        if (isCategoryMenuOpen || isSubCategoryMenuOpen)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                if (!mounted) return;
                setState(() {
                  isCategoryMenuOpen = false;
                  isSubCategoryMenuOpen = false;
                });
              },
              child: const SizedBox.expand(),
            ),
          ),
        _buildTopNavigation(activePostSubCategory: activePostSubCategory),
        if (showLoader)
          const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(color: Color(0xFF9E7CFF)),
                SizedBox(height: 12),
                Text(
                  'Loading...',
                  style: TextStyle(color: Colors.white70, fontSize: 16),
                ),
              ],
            ),
          ),
      ],
    );
  }

  String _buildFeedErrorMessage(Object? error) {
    if (error is FirebaseException) {
      final code = error.code.trim();
      if (code == 'permission-denied') {
        return 'אין הרשאה לטעון את הפיד כרגע';
      }
      if (code == 'failed-precondition') {
        return 'נדרשת הגדרת אינדקס עבור הפיד';
      }
      final message = (error.message ?? '').trim();
      if (message.isNotEmpty) {
        return 'שגיאת פיד: $message';
      }
    }
    return 'אירעה שגיאה בטעינת הפיד';
  }

  bool _isRecoverableFeedStreamError(Object error) {
    if (error is TimeoutException) {
      return true;
    }
    if (error is! FirebaseException) {
      return false;
    }
    return error.code == 'permission-denied' ||
        error.code == 'failed-precondition' ||
        error.code == 'unavailable' ||
        error.code == 'deadline-exceeded' ||
        error.code == 'resource-exhausted' ||
        error.code == 'aborted';
  }

  Stream<List<Map<String, dynamic>>> _safeFeedListStream(
    Stream<List<Map<String, dynamic>>> source,
  ) {
    return Stream.multi((controller) {
      List<Map<String, dynamic>>? lastGood;

      final sub = source.listen(
        (data) {
          lastGood = data;
          controller.add(data);
        },
        onError: (Object error, StackTrace stackTrace) {
          if (_isRecoverableFeedStreamError(error)) {
            debugPrint('Feed stream recoverable error: $error');
            if (lastGood != null) {
              controller.add(lastGood!);
            }
            return;
          }
          controller.addError(error, stackTrace);
        },
      );

      controller.onCancel = () async {
        await sub.cancel();
      };
    });
  }

  Widget? _buildScrollControls(int itemCount) {
    return null;
  }

  Widget _buildPostMediaCarousel(PostModel post, {required bool isActive}) {
    if (post.mediaItems.isEmpty && post.imageUrl.isEmpty) {
      return Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: post.colors,
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
      );
    }

    return PostMediaViewer(
      mediaItems: post.mediaItems.isNotEmpty
          ? post.mediaItems
          : postMediaItemsFromData(<String, dynamic>{
              'mediaUrls': post.mediaUrls,
              'imageUrl': post.imageUrl,
            }),
      aspectRatio: null,
      showDesktopNavigationArrows: false,
      isActive: isActive,
    );
  }

  Widget _buildBlankFeedScaffold() {
    return Scaffold(
      extendBody: true,
      backgroundColor: _feedBackgroundColor(context),
      body: _buildFeedState(child: const SizedBox.expand()),
      bottomNavigationBar: const MainBottomNav(currentIndex: 0),
    );
  }

  Stream<List<Map<String, dynamic>>> _resolveFeedStream({
    required bool usingBackendFeed,
    required String? categoryFilter,
    required String? subCategoryFilter,
  }) {
    final streamKey = [
      usingBackendFeed ? 'backend' : 'firestore',
      isForYouFeed ? 'for_you' : 'friends',
      categoryFilter ?? '',
      subCategoryFilter ?? '',
      _feedRefreshToken.toString(),
    ].join('|');

    if (_cachedFeedStream != null && _cachedFeedStreamKey == streamKey) {
      return _cachedFeedStream!;
    }

    _cachedFeedStreamKey = streamKey;
    final source = usingBackendFeed
        ? _feedBackendService.watchRecommendedFeedWithAuthors(
            isForYouFeed: isForYouFeed,
            category: categoryFilter,
            subCategory: subCategoryFilter,
            pageSize: 60,
          )
        : _postService.watchPublishedPostsWithAuthors(
            category: categoryFilter,
            subCategory: subCategoryFilter,
          );
    _cachedFeedStream = _safeFeedListStream(source);

    return _cachedFeedStream!;
  }

  @override
  Widget build(BuildContext context) {
    if (!_hasLoadedSeenFeedHistory) {
      return _buildBlankFeedScaffold();
    }

    final shouldFilterByCategory = !isGeneralCategory(selectedCategory);
    final shouldFilterBySubCategory = shouldFilterByCategory &&
        selectedSubCategory.isNotEmpty &&
        selectedSubCategory != _allSubCategoriesLabel;

    final usingBackendFeed = _feedBackendService.isConfigured;
    final categoryFilter = shouldFilterByCategory ? selectedCategory : null;
    final subCategoryFilter =
        shouldFilterBySubCategory ? selectedSubCategory : null;
    final feedStream = _resolveFeedStream(
      usingBackendFeed: usingBackendFeed,
      categoryFilter: categoryFilter,
      subCategoryFilter: subCategoryFilter,
    );

    return StreamBuilder<List<Map<String, dynamic>>>(
      key: ValueKey<String>(
        '${isForYouFeed ? 'for_you' : 'friends'}-$selectedCategory-$selectedSubCategory-$_feedRefreshToken',
      ),
      stream: feedStream,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          debugPrint('Home feed error: ${snapshot.error}');
          return Scaffold(
            extendBody: true,
            backgroundColor: _feedBackgroundColor(context),
            body: _buildFeedState(
              child: Center(
                child: Text(
                  _buildFeedErrorMessage(snapshot.error),
                  style: TextStyle(
                    color: _isLightMode(context)
                        ? const Color(0xFF5A6783)
                        : Colors.white70,
                    fontSize: 18,
                  ),
                ),
              ),
            ),
            bottomNavigationBar: const MainBottomNav(currentIndex: 0),
          );
        }

        if (!snapshot.hasData &&
            snapshot.connectionState != ConnectionState.done) {
          return _buildBlankFeedScaffold();
        }

        final rawPosts = snapshot.data ?? const <Map<String, dynamic>>[];
        if (kDebugMode) {
          debugPrint(
              '[FEED_PIPELINE] rawPosts=${rawPosts.length} usingBackendFeed=$usingBackendFeed category=$categoryFilter subCategory=$subCategoryFilter');
        }

        return StreamBuilder<Set<String>>(
          stream: _blockUserService.streamBlockedConnections(),
          builder: (context, blockedSnapshot) {
            if (blockedSnapshot.hasError) {
              debugPrint(
                  'Blocked connections stream error: ${blockedSnapshot.error}');
            }
            final blockedUids = blockedSnapshot.data ?? const <String>{};
            final postsFromDb = rawPosts
                .where((post) => !_isDeletedAuthorPost(post))
                .map((post) => _postFromMap(post, blockedUids: blockedUids))
                .where((post) {
              final authorId = post.authorId.trim();
              if (authorId.isEmpty) {
                // Avoid showing posts when author identity cannot be resolved.
                return false;
              }
              return !blockedUids.contains(authorId);
            }).toList(growable: false);
            final randomizedPosts = _randomizePostsOnce(postsFromDb);
            final postsWithoutCurrentUser =
                _excludeCurrentUserPosts(randomizedPosts);
            if (kDebugMode) {
              debugPrint(
                  '[FEED_PIPELINE] blockedUids=${blockedUids.length} postsFromDb=${postsFromDb.length} postsWithoutCurrentUser=${postsWithoutCurrentUser.length}');
            }

            return StreamBuilder<Set<String>>(
              stream: _followingIdsStream(),
              builder: (context, followingSnapshot) {
                if (followingSnapshot.hasError) {
                  debugPrint(
                      'Following IDs stream error: ${followingSnapshot.error}');
                }
                final followingIds = followingSnapshot.data ?? <String>{};
                final visibleFollowingIds =
                    followingIds.difference(blockedUids);
                final scopedPosts = _postsForFeedScope(
                  postsWithoutCurrentUser,
                  visibleFollowingIds,
                  alreadyScopedByBackend: usingBackendFeed,
                );
                if (kDebugMode) {
                  debugPrint(
                      '[FEED_PIPELINE] followingIds=${followingIds.length} isForYouFeed=$isForYouFeed scopedPosts=${scopedPosts.length}');
                }

                if (scopedPosts.isEmpty) {
                  return Scaffold(
                    extendBody: true,
                    backgroundColor: _feedBackgroundColor(context),
                    body: _buildFeedState(
                      activePostSubCategory: null,
                      child: _buildEmptyFeedState(isForYouFeed: isForYouFeed),
                    ),
                    bottomNavigationBar: const MainBottomNav(currentIndex: 0),
                  );
                }

                return FutureBuilder<List<PostModel>>(
                  future: _resolveAudienceFilteredPosts(
                    scopedPosts,
                    blockedUids: blockedUids,
                  ),
                  builder: (context, audienceSnapshot) {
                    if (audienceSnapshot.hasError && kDebugMode) {
                      debugPrint(
                          '[FEED_PIPELINE] audience filter future errored: ${audienceSnapshot.error}');
                    }
                    if (!audienceSnapshot.hasData &&
                        audienceSnapshot.connectionState !=
                            ConnectionState.done) {
                      return _buildBlankFeedScaffold();
                    }

                    final baseFeedPosts =
                        audienceSnapshot.data ?? const <PostModel>[];
                    final displaySeenIds =
                        _seenIdsForFeedDisplayBatch(baseFeedPosts);
                    final feedPosts = filterFeedPostsForFreshnessAndSeen(
                      baseFeedPosts,
                      seenPostIds: displaySeenIds,
                    );
                    if (kDebugMode) {
                      debugPrint(
                          '[FEED_PIPELINE] baseFeedPosts=${baseFeedPosts.length} seenIds=${displaySeenIds.length} feedPosts=${feedPosts.length}');
                    }
                    final activeFeedIndex = feedPosts.isEmpty
                        ? 0
                        : _currentFeedPageIndex.clamp(0, feedPosts.length - 1);

                    _recordActiveFeedPostIfNeeded(
                      feedPosts: feedPosts,
                      activeFeedIndex: activeFeedIndex,
                      baseFeedPosts: baseFeedPosts,
                    );

                    _scheduleFeedMediaPrecache(feedPosts, activeFeedIndex);
                    final scrollControls =
                        _buildScrollControls(feedPosts.length);

                    final isFeedStillLoading =
                        audienceSnapshot.connectionState ==
                                ConnectionState.waiting &&
                            !audienceSnapshot.hasData &&
                            !feedPosts.isEmpty;

                    return Scaffold(
                      extendBody: true,
                      backgroundColor: _feedBackgroundColor(context),
                      body: _buildFeedState(
                        activePostSubCategory: feedPosts.isEmpty
                            ? null
                            : feedPosts[activeFeedIndex].subCategory,
                        showLoader: isFeedStillLoading,
                        child: feedPosts.isEmpty
                            ? _buildEmptyFeedState(
                                isForYouFeed: isForYouFeed,
                              )
                            : NotificationListener<OverscrollNotification>(
                                onNotification: (notification) {
                                  if (notification.metrics.axis !=
                                      Axis.vertical) {
                                    return false;
                                  }

                                  final safeIndex = activeFeedIndex.clamp(
                                      0, feedPosts.length - 1);
                                  _recordSeenFeedPost(feedPosts[safeIndex]);
                                  final shouldShow =
                                      shouldTriggerExhaustedFeedMessageAfterOverscroll(
                                    activeFeedIndex: safeIndex,
                                    feedPostCount: feedPosts.length,
                                    hasMoreUnseenPosts:
                                        _hasMoreUnseenPosts(baseFeedPosts),
                                    overscroll: notification.overscroll,
                                  );
                                  if (shouldShow) {
                                    unawaited(_showExhaustedFeedMessage());
                                  }
                                  return false;
                                },
                                child: PageView.builder(
                                  controller: _pageController,
                                  scrollDirection: Axis.vertical,
                                  allowImplicitScrolling: true,
                                  itemCount: feedPosts.length,
                                  onPageChanged: (index) {
                                    if (_currentFeedPageIndex == index) return;

                                    final visiblePost = feedPosts[index];
                                    _recordSeenFeedPost(visiblePost);

                                    setState(() {
                                      _currentFeedPageIndex = index;
                                    });
                                  },
                                  itemBuilder: (context, index) {
                                    final visiblePost = feedPosts[index];
                                    return _buildPostBlock(
                                      visiblePost,
                                      isActive: _isFeedInForeground &&
                                          index == activeFeedIndex,
                                    );
                                  },
                                ),
                              ),
                      ),
                      floatingActionButton:
                          isFeedStillLoading ? null : scrollControls,
                      floatingActionButtonLocation:
                          FloatingActionButtonLocation.startFloat,
                      bottomNavigationBar: const MainBottomNav(currentIndex: 0),
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildPostBlock(PostModel post, {required bool isActive}) {
    final isLight = _isLightMode(context);
    final currentUid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
    final canReportPost =
        currentUid.isNotEmpty && post.authorId.trim() != currentUid;
    final isLiked = _isPostLiked(post);
    final isSaved = _isPostSaved(post);
    final likesDelta = (isLiked ? 1 : 0) - (post.likedByCurrentUser ? 1 : 0);
    final savesDelta = (isSaved ? 1 : 0) - (post.savedByCurrentUser ? 1 : 0);
    final displayLikes =
        (post.likesCount + likesDelta).clamp(0, 1 << 30).toInt();
    final displaySaves =
        (post.savesCount + savesDelta).clamp(0, 1 << 30).toInt();
    final displayComments = _displayedCommentCount(post);
    final displayShares = _displayedShareCount(post);
    final postTimestamp = _formatPostTimestamp(post.createdAt);
    final locationText = post.location.trim();
    final contributionScore = _displayedContributionScore(
      post,
      displayedLikes: displayLikes,
      displayedSaves: displaySaves,
      displayedComments: displayComments,
      displayedShares: displayShares,
    );
    final linkedGroupId = post.linkedGroupId.trim();
    final hasLinkedGroup = linkedGroupId.isNotEmpty;
    final participantsCount =
        _participantUidsForPost(post, includeAuthor: false).length;
    const overlayTop = _postTopOverlayOffset;
    final overlayBottomOffset =
        MainBottomNav.occupiedHeight(context) + _postOverlayClearanceFromNav;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onDoubleTapDown: (details) =>
          _handleDoubleTap(post, details.localPosition),
      onDoubleTap: () {},
      child: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: BoxDecoration(
          color: isLight ? const Color(0xFFEFF5FF) : Colors.black,
        ),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Stack(
            children: [
              Positioned.fill(
                child: _buildPostMediaCarousel(post, isActive: isActive),
              ),
              if (!_experimentalFeedPostLayout)
                Positioned(
                  top: overlayTop,
                  right: 20,
                  child: GestureDetector(
                    onTap: () {
                      final authorId = post.authorId.trim();
                      if (authorId.isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('לא ניתן לטעון פרופיל משתמש'),
                          ),
                        );
                        return;
                      }
                      debugPrint('Navigating to user: $authorId');
                      _navigateToScreen(UserDetailScreen(uid: authorId));
                    },
                    child: AuthorInfoWidget(
                      authorId: post.authorId,
                      userFuture: _authorFuture(post.authorId),
                    ),
                  ),
                ),
              if (!_experimentalFeedPostLayout)
                Positioned(
                  top: overlayTop,
                  left: 20,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 15, vertical: 8),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(999),
                          gradient: LinearGradient(
                            colors: [
                              (isLight
                                      ? const Color(0xFFFDFEFF)
                                      : const Color(0xFF15263F))
                                  .withValues(alpha: isLight ? 0.96 : 0.94),
                              (isLight
                                      ? const Color(0xFFE9F1FF)
                                      : const Color(0xFF2F1F54))
                                  .withValues(alpha: isLight ? 0.96 : 0.94),
                            ],
                          ),
                          border: Border.all(
                            color: (isLight
                                    ? const Color(0xFF7D8DFF)
                                    : const Color(0xFF46D3FF))
                                .withValues(alpha: isLight ? 0.26 : 0.34),
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: (isLight
                                      ? const Color(0xFF91BCFF)
                                      : const Color(0xFF46D3FF))
                                  .withValues(alpha: isLight ? 0.24 : 0.24),
                              blurRadius: 12,
                              spreadRadius: 0.5,
                            ),
                          ],
                        ),
                        child: Text(
                          '+$contributionScore',
                          style: TextStyle(
                            color: isLight
                                ? const Color(0xFF5A6CFF)
                                : const Color(0xFF9EDBFF),
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      if (post.audience.trim().toLowerCase() == 'friends') ...[
                        const SizedBox(height: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              colors: [Color(0xFFFFF7EF), Color(0xFFFFB36B)],
                              begin: Alignment.centerLeft,
                              end: Alignment.centerRight,
                            ),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(
                              color: const Color(0xFFFF8A2A)
                                  .withValues(alpha: 0.72),
                            ),
                          ),
                          child: const Text(
                            'חברים',
                            style: TextStyle(
                              color: Color(0xFF9A4B00),
                              fontWeight: FontWeight.w800,
                              fontSize: 11,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              Positioned(
                left: 20,
                bottom: overlayBottomOffset,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_experimentalFeedPostLayout) ...[
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
                                gradient: LinearGradient(
                                  colors: [
                                    (isLight
                                            ? const Color(0xFFFDFEFF)
                                            : const Color(0xFF15263F))
                                        .withValues(
                                            alpha: isLight ? 0.96 : 0.94),
                                    (isLight
                                            ? const Color(0xFFE9F1FF)
                                            : const Color(0xFF2F1F54))
                                        .withValues(
                                            alpha: isLight ? 0.96 : 0.94),
                                  ],
                                ),
                                border: Border.all(
                                  color: (isLight
                                          ? const Color(0xFF7D8DFF)
                                          : const Color(0xFF46D3FF))
                                      .withValues(alpha: isLight ? 0.26 : 0.34),
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: (isLight
                                            ? const Color(0xFF91BCFF)
                                            : const Color(0xFF46D3FF))
                                        .withValues(
                                            alpha: isLight ? 0.24 : 0.24),
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
                                        ? const Color(0xFF5A6CFF)
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
                      const SizedBox(height: 14),
                    ],
                    _buildActionButton(
                      icon: isLiked
                          ? Icons.favorite_rounded
                          : Icons.favorite_border_rounded,
                      iconColor: isLiked
                          ? const Color(0xFF8C62FF)
                          : const Color(0xFF9EDBFF),
                      label: _formatCompactCount(displayLikes),
                      onTap: () => _togglePostLike(post),
                      isActive: isLiked,
                      isBusy: _likeInFlightPostIds.contains(post.id),
                      labelSpacing: 0,
                      isLight: isLight,
                    ),
                    const SizedBox(height: 14),
                    _buildActionButton(
                      icon: Icons.chat_bubble_outline_rounded,
                      iconColor: const Color(0xFF9EDBFF),
                      label: _formatCompactCount(displayComments),
                      onTap: () => _showCommentsBottomSheet(post),
                      labelSpacing: 0,
                      isLight: isLight,
                    ),
                    const SizedBox(height: 14),
                    _buildActionButton(
                      icon: isSaved
                          ? Icons.bookmark_rounded
                          : Icons.bookmark_border_rounded,
                      iconColor: isSaved
                          ? const Color(0xFF8C62FF)
                          : const Color(0xFF9EDBFF),
                      label: _formatCompactCount(displaySaves),
                      onTap: () => _togglePostSave(post),
                      isActive: isSaved,
                      isBusy: _saveInFlightPostIds.contains(post.id),
                      isLight: isLight,
                    ),
                    const SizedBox(height: 8),
                    if (post.taggedFriends.isNotEmpty) ...[
                      _buildHorizontalFriends(post.taggedFriends),
                      const SizedBox(height: 14),
                    ],
                    Row(
                      children: [
                        GestureDetector(
                          onTap: () => _navigateToScreen(
                            CategoryScreen(
                              categoryName: post.category,
                              initialPost: _categoryNavigationPostMap(post),
                            ),
                          ),
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
                                    ? const Color(0xFFF6FAFF)
                                    : const Color(0xFF172235),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                _getCategoryIcon(post.category),
                                color: isLight
                                    ? const Color(0xFF33466D)
                                    : const Color(0xFFEAF4FF),
                                size: 22,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
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
                                    ? const Color(0xFFF6FAFF)
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
                                              ? const Color(0xFF33466D)
                                              : const Color(0xFFEAF4FF),
                                          size: 16,
                                        ),
                                        Text(
                                          participantsCount.toString(),
                                          style: TextStyle(
                                            color: isLight
                                                ? const Color(0xFF33466D)
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
                        const SizedBox(width: 6),
                        GestureDetector(
                          onTap: () => _showShareMenu(post),
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
                                    ? const Color(0xFFF6FAFF)
                                    : const Color(0xFF172235),
                                shape: BoxShape.circle,
                              ),
                              child: _shareInFlightPostIds.contains(post.id)
                                  ? const Padding(
                                      padding: EdgeInsets.all(14),
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        Icon(
                                          Icons.send_rounded,
                                          color: isLight
                                              ? const Color(0xFF33466D)
                                              : const Color(0xFFEAF4FF),
                                          size: 16,
                                        ),
                                        Text(
                                          _formatCompactCount(displayShares),
                                          style: TextStyle(
                                            color: isLight
                                                ? const Color(0xFF33466D)
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
                        if (canReportPost) const SizedBox(width: 10),
                        if (canReportPost)
                          GestureDetector(
                            onTap: () => _reportPostFromFeed(post),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 2,
                              ),
                              child: Icon(
                                Icons.flag_outlined,
                                size: 19,
                                color: isLight
                                    ? const Color(0xFF6B7891)
                                    : Colors.white70,
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
                bottom: overlayBottomOffset + _postTextBlockExtraOffset,
                left: 120,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (_experimentalFeedPostLayout) ...[
                      GestureDetector(
                        onTap: () {
                          final authorId = post.authorId.trim();
                          if (authorId.isEmpty) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('לא ניתן לטעון פרופיל משתמש'),
                              ),
                            );
                            return;
                          }
                          debugPrint('Navigating to user: $authorId');
                          _navigateToScreen(UserDetailScreen(uid: authorId));
                        },
                        child: AuthorInfoWidget(
                          authorId: post.authorId,
                          userFuture: _authorFuture(post.authorId),
                          compact: true,
                        ),
                      ),
                      const SizedBox(height: 6),
                    ],
                    if (post.title.isNotEmpty)
                      Text(
                        post.title,
                        textAlign: TextAlign.right,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          fontSize: 21,
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
                    if (post.description.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      ExpandablePostDescription(
                        text: post.description,
                        maxLines: 2,
                        textAlign: TextAlign.right,
                        textDirection: TextDirection.rtl,
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
                        toggleStyle: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          height: 1.2,
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
              if (_showDoubleTapHeart && _activeHeartPostId == post.id)
                Positioned(
                  left: _heartTapPosition.dx - 40,
                  top: _heartTapPosition.dy - 40,
                  child: const AnimatedOpacity(
                    opacity: 1.0,
                    duration: Duration(milliseconds: 200),
                    child: Icon(
                      Icons.favorite,
                      color: Colors.redAccent,
                      size: 80,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildActionButton(
      {required IconData icon,
      required Color iconColor,
      required String label,
      required VoidCallback onTap,
      bool isActive = false,
      bool isBusy = false,
      double labelSpacing = 2,
      bool isLight = false}) {
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
                          ? const Color(0xFFF8FBFF)
                          : const Color(0xFF121D2E))
                      .withValues(alpha: isLight ? 0.92 : 0.84),
              border: Border.all(
                color: isActiveLight
                    ? Colors.transparent
                    : (isLight
                            ? const Color(0xFF8A96FF)
                            : const Color(0xFF46D3FF))
                        .withValues(alpha: isLight ? 0.26 : 0.35),
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
                    : Icon(icon,
                        color: isActive
                            ? Colors.white
                            : (isLight ? const Color(0xFF5A6CFF) : iconColor),
                        size: 25),
          ),
          SizedBox(height: labelSpacing),
          Text(
            label,
            style: TextStyle(
              color: isLight ? Colors.black : const Color(0xFFEAF4FF),
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMetaChip({required IconData icon, required String text}) {
    final isLight = _isLightMode(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        gradient: LinearGradient(
          colors: [
            (isLight ? const Color(0xFFFFFFFF) : const Color(0xFF15263F))
                .withValues(alpha: isLight ? 0.9 : 0.9),
            (isLight ? const Color(0xFFE8EEFF) : const Color(0xFF2F1F54))
                .withValues(alpha: isLight ? 0.9 : 0.9),
          ],
        ),
        border: Border.all(
            color: (isLight ? const Color(0xFF8A96FF) : const Color(0xFF46D3FF))
                .withValues(alpha: isLight ? 0.24 : 0.26)),
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
              color:
                  isLight ? const Color(0xFF5A6CFF) : const Color(0xFF9EDBFF),
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHorizontalFriends(List<UserModel> friends) {
    final isLight = _isLightMode(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: friends.map((user) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2.0),
          child: Container(
            padding: const EdgeInsets.all(1.5),
            decoration: BoxDecoration(
              color:
                  isLight ? const Color(0xFFE8EEFF) : const Color(0xFF1E2632),
              shape: BoxShape.circle,
            ),
            child: CircleAvatar(
              radius: 13,
              backgroundImage: NetworkImage(user.profileImageUrl),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildTopNavigation({String? activePostSubCategory}) {
    final isLight = _isLightMode(context);
    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;
    final isCompact = screenWidth < 390;
    final isGeneralSelected = isGeneralCategory(selectedCategory);
    final categoryMenuHeight = min(
      screenHeight * 0.5,
      categories.length * 44.0 + 12,
    );
    final subCategoryOptions = [
      _allSubCategoriesLabel,
      ...appSubCategories(selectedCategory),
    ];
    final subCategoryMenuHeight = min(
      screenHeight * 0.5,
      subCategoryOptions.length * 44.0 + 12,
    );
    const topRowHeight = 34.0;
    const subCategoryMenuTop = 76.0;
    const categoryMenuTop = topRowHeight;
    final openMenuExtent = isCategoryMenuOpen
        ? categoryMenuTop + categoryMenuHeight
        : (isSubCategoryMenuOpen && !isGeneralSelected)
            ? subCategoryMenuTop + subCategoryMenuHeight
            : 0.0;
    const timerTopColor = Color(0xFF8DE8FF);
    const timerBottomColor = Color(0xFFC9B5FF);
    const timerTextColor = Color(0xFF2A2361);
    final currentGeneralSubCategoryLabel =
        (activePostSubCategory ?? '').trim().isNotEmpty
            ? activePostSubCategory!.trim()
            : 'ללא תת קטגוריה';
    Widget futuristicCategoryChip(
      String label, {
      required bool selected,
      IconData? icon,
      bool emphasize = false,
      bool iconOnRight = false,
      bool fullWidth = false,
    }) {
      return Container(
        width: fullWidth ? double.infinity : null,
        padding: EdgeInsets.symmetric(
          horizontal: emphasize ? 18 : 14,
          vertical: emphasize ? 11 : 8,
        ),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: selected
                ? const [timerTopColor, timerBottomColor]
                : const [Color(0xFFDFF7FF), Color(0xFFECDDFF)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected
                ? Colors.white.withValues(alpha: 0.8)
                : const Color(0xFFB6EFFF),
            width: selected ? 1.55 : 1.1,
          ),
          boxShadow: [
            BoxShadow(
              color: timerTopColor.withValues(alpha: selected ? 0.28 : 0.16),
              blurRadius: selected ? 16 : 10,
              offset: const Offset(0, 4),
            ),
            if (selected)
              BoxShadow(
                color: timerBottomColor.withValues(alpha: 0.28),
                blurRadius: 18,
                spreadRadius: 0.3,
                offset: const Offset(0, 7),
              ),
          ],
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isTight = constraints.maxWidth < 110;
            final showIcon = icon != null && (!isTight || emphasize);
            final rowChildren = <Widget>[];

            if (showIcon && !iconOnRight) {
              rowChildren.addAll([
                Icon(
                  icon,
                  size: emphasize ? 18 : 16,
                  color: selected ? timerTextColor : const Color(0xFF4A5B83),
                ),
                SizedBox(width: isTight ? 6 : 8),
              ]);
            }

            if (showIcon && iconOnRight) {
              rowChildren.addAll([
                Icon(
                  icon,
                  size: emphasize ? 18 : 16,
                  color: selected ? timerTextColor : const Color(0xFF4A5B83),
                ),
                SizedBox(width: isTight ? 6 : 8),
              ]);
            }

            rowChildren.add(
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  textDirection: TextDirection.rtl,
                  style: TextStyle(
                    color: selected ? timerTextColor : const Color(0xFF425070),
                    fontSize: emphasize ? 14 : 12,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w700,
                    letterSpacing: selected ? 0.2 : 0,
                  ),
                ),
              ),
            );

            return Row(
              mainAxisSize: fullWidth ? MainAxisSize.max : MainAxisSize.min,
              textDirection: TextDirection.rtl,
              children: rowChildren,
            );
          },
        ),
      );
    }

    BoxDecoration futuristicDropdownFrameDecoration({required double radius}) {
      return BoxDecoration(
        gradient: const LinearGradient(
          colors: [
            timerTopColor,
            timerBottomColor,
            Color(0xFFBEEFFF),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(radius),
        boxShadow: [
          BoxShadow(
            color: timerTopColor.withValues(alpha: 0.3),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
          BoxShadow(
            color: timerBottomColor.withValues(alpha: 0.3),
            blurRadius: 22,
            offset: const Offset(0, 8),
          ),
        ],
      );
    }

    BoxDecoration futuristicDropdownInnerDecoration({required double radius}) {
      return BoxDecoration(
        gradient: const LinearGradient(
          colors: [
            Color(0xFFDDF5FF),
            Color(0xFFE9DEFF),
          ],
          stops: [0.1, 1],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(radius),
      );
    }

    return Positioned(
      top: 18,
      left: isCompact ? 12 : 20,
      right: isCompact ? 12 : 20,
      child: SafeArea(
        child: Container(
          padding: EdgeInsets.fromLTRB(
            isCompact ? 8 : 10,
            isCompact ? 8 : 10,
            isCompact ? 8 : 10,
            8,
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Column(
                    children: [
                      SizedBox(
                        height: 34,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            IgnorePointer(
                              child: ShaderMask(
                                blendMode: BlendMode.srcIn,
                                shaderCallback: (bounds) {
                                  return const LinearGradient(
                                    colors: [
                                      _themeBlue,
                                      _themeCyan,
                                      _themePurple
                                    ],
                                    begin: Alignment.centerLeft,
                                    end: Alignment.centerRight,
                                  ).createShader(bounds);
                                },
                                child: Text(
                                  'HUNDRED',
                                  style: TextStyle(
                                    color: (isLight
                                            ? const Color(0xFF364565)
                                            : Colors.white)
                                        .withValues(alpha: 0.96),
                                    fontSize: 19,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 3.2,
                                    fontFamily: 'Segoe UI',
                                    shadows: [
                                      Shadow(
                                        color:
                                            _themeCyan.withValues(alpha: 0.35),
                                        blurRadius: 16,
                                      ),
                                      Shadow(
                                        color: _themePurpleDeep.withValues(
                                            alpha: 0.35),
                                        blurRadius: 20,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            if (_activeSpontaneousTask != null)
                              Align(
                                alignment: Alignment.centerLeft,
                                child: Directionality(
                                  textDirection: TextDirection.rtl,
                                  child: Material(
                                    color: Colors.transparent,
                                    child: InkWell(
                                      onTap: _openActiveSpontaneousTaskModal,
                                      borderRadius: BorderRadius.circular(14),
                                      child: Container(
                                        width: isCompact ? 92 : 98,
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 4,
                                          vertical: 7,
                                        ),
                                        decoration: BoxDecoration(
                                          borderRadius:
                                              BorderRadius.circular(14),
                                          gradient: const LinearGradient(
                                            colors: [
                                              Color(0xFF8DE8FF),
                                              Color(0xFFC9B5FF)
                                            ],
                                            begin: Alignment.topLeft,
                                            end: Alignment.bottomRight,
                                          ),
                                          border: Border.all(
                                            color: Colors.white
                                                .withValues(alpha: 0.65),
                                            width: 1.1,
                                          ),
                                        ),
                                        child: Directionality(
                                          textDirection: TextDirection.ltr,
                                          child: Row(
                                            children: [
                                              const Icon(
                                                Icons.schedule_rounded,
                                                size: 13,
                                                color: Color(0xFF2A2361),
                                              ),
                                              const SizedBox(width: 4),
                                              Expanded(
                                                child: Center(
                                                  child: FittedBox(
                                                    fit: BoxFit.scaleDown,
                                                    child: Text(
                                                      _formatSpontaneousCountdown(
                                                        _activeSpontaneousRemaining,
                                                      ),
                                                      textDirection:
                                                          TextDirection.rtl,
                                                      textAlign:
                                                          TextAlign.center,
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: const TextStyle(
                                                        color:
                                                            Color(0xFF2A2361),
                                                        fontSize: 18,
                                                        fontWeight:
                                                            FontWeight.w900,
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
                                  ),
                                ),
                              ),
                            Align(
                              alignment: Alignment.centerRight,
                              child: GestureDetector(
                                onTap: () => setState(() {
                                  isCategoryMenuOpen = !isCategoryMenuOpen;
                                  isSubCategoryMenuOpen = false;
                                }),
                                child: ConstrainedBox(
                                  constraints: BoxConstraints(
                                    maxWidth: isCompact ? 108 : 132,
                                  ),
                                  child: FittedBox(
                                    fit: BoxFit.scaleDown,
                                    alignment: Alignment.centerRight,
                                    child: futuristicCategoryChip(
                                      selectedCategory,
                                      selected: true,
                                      icon: _getCategoryIcon(selectedCategory),
                                      emphasize: true,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 4),
                      Directionality(
                        textDirection: TextDirection.ltr,
                        child: Row(
                          children: [
                            Flexible(
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: Alignment.centerLeft,
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      GestureDetector(
                                        onTap: _openStarsAndRefreshSpontaneous,
                                        child: Container(
                                          padding: const EdgeInsets.all(5),
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            color: isLight
                                                ? const Color(0xFFEFF4FF)
                                                : Colors.white
                                                    .withValues(alpha: 0.1),
                                          ),
                                          child: const Icon(
                                            Icons.star_rounded,
                                            color: Color(0xFFFFD166),
                                            size: 18,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      GestureDetector(
                                        onTap: () =>
                                            _refreshFeedOnScopeSwitch(true),
                                        child: AnimatedContainer(
                                          duration:
                                              const Duration(milliseconds: 180),
                                          curve: Curves.easeOut,
                                          padding: const EdgeInsets.all(5),
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            gradient: isForYouFeed
                                                ? (isLight
                                                    ? const LinearGradient(
                                                        colors: [
                                                          _themePurple,
                                                          _themeCyan,
                                                        ],
                                                        begin:
                                                            Alignment.topLeft,
                                                        end: Alignment
                                                            .bottomRight,
                                                      )
                                                    : const LinearGradient(
                                                        colors: [
                                                          _themePurple,
                                                          _themeCyan
                                                        ],
                                                        begin:
                                                            Alignment.topLeft,
                                                        end: Alignment
                                                            .bottomRight,
                                                      ))
                                                : null,
                                            color: isForYouFeed
                                                ? (isLight ? null : null)
                                                : (isLight
                                                    ? const Color(0xFFF4F7FF)
                                                    : Colors.white.withValues(
                                                        alpha: 0.08)),
                                            border: Border.all(
                                              color: isLight
                                                  ? (isForYouFeed
                                                      ? const Color(0xFFFFFFFF)
                                                      : const Color(0xFFA9C3FF))
                                                  : Colors.transparent,
                                              width: isLight && isForYouFeed
                                                  ? 1.3
                                                  : 1,
                                            ),
                                            boxShadow: isLight && isForYouFeed
                                                ? [
                                                    BoxShadow(
                                                      color: const Color(
                                                        0xFF8C62FF,
                                                      ).withValues(alpha: 0.34),
                                                      blurRadius: 12,
                                                      spreadRadius: 0.4,
                                                      offset:
                                                          const Offset(0, 4),
                                                    ),
                                                  ]
                                                : null,
                                          ),
                                          child: Icon(
                                            Icons.widgets_rounded,
                                            color: isForYouFeed
                                                ? (isLight
                                                    ? Colors.white
                                                    : Colors.white)
                                                : (isLight
                                                    ? const Color(0xFF5A6CFF)
                                                    : Colors.white54),
                                            size: 18,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      GestureDetector(
                                        onTap: () =>
                                            _refreshFeedOnScopeSwitch(false),
                                        child: AnimatedContainer(
                                          duration:
                                              const Duration(milliseconds: 180),
                                          curve: Curves.easeOut,
                                          padding: const EdgeInsets.all(5),
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            gradient: !isForYouFeed
                                                ? (isLight
                                                    ? const LinearGradient(
                                                        colors: [
                                                          _themePurple,
                                                          _themeCyan,
                                                        ],
                                                        begin:
                                                            Alignment.topLeft,
                                                        end: Alignment
                                                            .bottomRight,
                                                      )
                                                    : const LinearGradient(
                                                        colors: [
                                                          _themePurple,
                                                          _themeCyan
                                                        ],
                                                        begin:
                                                            Alignment.topLeft,
                                                        end: Alignment
                                                            .bottomRight,
                                                      ))
                                                : null,
                                            color: !isForYouFeed
                                                ? (isLight ? null : null)
                                                : (isLight
                                                    ? const Color(0xFFF4F7FF)
                                                    : Colors.white.withValues(
                                                        alpha: 0.08)),
                                            border: Border.all(
                                              color: isLight
                                                  ? (!isForYouFeed
                                                      ? const Color(0xFFFFFFFF)
                                                      : const Color(0xFFA9C3FF))
                                                  : Colors.transparent,
                                              width: isLight && !isForYouFeed
                                                  ? 1.3
                                                  : 1,
                                            ),
                                            boxShadow: isLight && !isForYouFeed
                                                ? [
                                                    BoxShadow(
                                                      color: const Color(
                                                        0xFF8C62FF,
                                                      ).withValues(alpha: 0.34),
                                                      blurRadius: 12,
                                                      spreadRadius: 0.4,
                                                      offset:
                                                          const Offset(0, 4),
                                                    ),
                                                  ]
                                                : null,
                                          ),
                                          child: Icon(
                                            Icons.groups_rounded,
                                            color: !isForYouFeed
                                                ? (isLight
                                                    ? Colors.white
                                                    : Colors.white)
                                                : (isLight
                                                    ? const Color(0xFF5A6CFF)
                                                    : Colors.white54),
                                            size: 18,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            if (!isCategoryMenuOpen)
                              ConstrainedBox(
                                constraints: BoxConstraints(
                                  minWidth: isCompact ? 178 : 228,
                                  maxWidth: isCompact ? 198 : 250,
                                ),
                                child: GestureDetector(
                                  onTap: isGeneralSelected
                                      ? null
                                      : () => setState(() {
                                            isSubCategoryMenuOpen =
                                                !isSubCategoryMenuOpen;
                                          }),
                                  child: Container(
                                    margin: const EdgeInsets.only(right: 2),
                                    padding: const EdgeInsets.all(1.2),
                                    decoration:
                                        futuristicDropdownFrameDecoration(
                                      radius: 20,
                                    ),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 3,
                                      ),
                                      decoration:
                                          futuristicDropdownInnerDecoration(
                                        radius: 18.8,
                                      ),
                                      child: Row(
                                        textDirection: TextDirection.ltr,
                                        children: [
                                          Icon(
                                            isSubCategoryMenuOpen
                                                ? Icons
                                                    .keyboard_arrow_up_rounded
                                                : Icons
                                                    .keyboard_arrow_down_rounded,
                                            color: timerTextColor,
                                            size: 18,
                                          ),
                                          const SizedBox(width: 6),
                                          Expanded(
                                            child: Align(
                                              alignment: Alignment.centerRight,
                                              child: Text(
                                                selectedSubCategory ==
                                                        _allSubCategoriesLabel
                                                    ? (isGeneralSelected
                                                        ? currentGeneralSubCategoryLabel
                                                        : _allSubCategoriesLabel)
                                                    : selectedSubCategory,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  color: timerTextColor,
                                                  fontSize: 13,
                                                  fontWeight: FontWeight.w800,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ],
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
                  if (openMenuExtent > 0)
                    SizedBox(
                      height: openMenuExtent,
                    ),
                ],
              ),
              if (isCategoryMenuOpen)
                Positioned(
                  top: categoryMenuTop,
                  right: 0,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: EdgeInsets.zero,
                    width: isCompact ? 124 : 140,
                    height: categoryMenuHeight,
                    padding: const EdgeInsets.all(1.2),
                    decoration: futuristicDropdownFrameDecoration(
                      radius: 14,
                    ),
                    child: Container(
                      decoration: futuristicDropdownInnerDecoration(
                        radius: 12.8,
                      ),
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: categories.length,
                        itemBuilder: (context, index) {
                          final category = categories[index];
                          final isSelected = selectedCategory == category;
                          return InkWell(
                            onTap: () {
                              _resetFeedDisplayBatchSnapshot();
                              setState(() {
                                selectedCategory = category;
                                selectedSubCategory = _allSubCategoriesLabel;
                                isCategoryMenuOpen = false;
                              });
                              if (_pageController.hasClients) {
                                _pageController.jumpToPage(0);
                              }
                            },
                            child: Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 6,
                              ),
                              child: futuristicCategoryChip(
                                category,
                                selected: isSelected,
                                icon: _getCategoryIcon(
                                  category,
                                ),
                                fullWidth: true,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              if (isSubCategoryMenuOpen && !isGeneralSelected)
                Positioned(
                  top: subCategoryMenuTop,
                  right: 0,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: EdgeInsets.zero,
                    width: isCompact ? 198 : 250,
                    height: subCategoryMenuHeight,
                    padding: const EdgeInsets.all(1.2),
                    decoration: futuristicDropdownFrameDecoration(radius: 20),
                    child: Container(
                      decoration:
                          futuristicDropdownInnerDecoration(radius: 18.8),
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: subCategoryOptions.length,
                        itemBuilder: (context, index) {
                          final subCategory = subCategoryOptions[index];
                          final isSelected = selectedSubCategory == subCategory;
                          return InkWell(
                            onTap: () {
                              _resetFeedDisplayBatchSnapshot();
                              setState(() {
                                selectedSubCategory = subCategory;
                                isSubCategoryMenuOpen = false;
                              });
                              if (_pageController.hasClients) {
                                _pageController.jumpToPage(0);
                              }
                            },
                            child: Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 6,
                              ),
                              child: futuristicCategoryChip(
                                subCategory,
                                selected: isSelected,
                                icon: Icons.radio_button_checked_rounded,
                                iconOnRight: true,
                                fullWidth: true,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  IconData _getCategoryIcon(String category) {
    return categoryIconFor(category);
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

class AuthorInfoWidget extends StatelessWidget {
  final String authorId;
  final Future<PublicUserProfile?> userFuture;
  final bool compact;

  const AuthorInfoWidget({
    super.key,
    required this.authorId,
    required this.userFuture,
    this.compact = false,
  });

  String _fallbackHandle() {
    final trimmed = authorId.trim();
    if (trimmed.isEmpty) return 'משתמש לא נמצא';
    final short = trimmed.substring(0, trimmed.length > 6 ? 6 : trimmed.length);
    return '@$short';
  }

  bool _containsHebrew(String value) {
    return RegExp(r'[\u0590-\u05FF]').hasMatch(value);
  }

  Widget _avatar(String imageUrl) {
    if (imageUrl.isEmpty) {
      return const Center(
        child: Icon(Icons.person_rounded, color: Colors.white, size: 18),
      );
    }

    return Image.network(
      imageUrl,
      fit: BoxFit.cover,
      width: double.infinity,
      height: double.infinity,
      errorBuilder: (context, error, stackTrace) {
        return const Center(
          child: Icon(Icons.person_rounded, color: Colors.white, size: 18),
        );
      },
    );
  }

  String _errorLabel(Object? error) {
    if (error is FirebaseException) {
      if (error.code == 'unavailable') {
        return 'אין חיבור';
      }
    }
    return 'שגיאת טעינה';
  }

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final fallbackHandle = _fallbackHandle();

    return FutureBuilder<PublicUserProfile?>(
      future: userFuture,
      builder: (context, snapshot) {
        String username = fallbackHandle;
        String profileImageUrl = '';
        String? errorLabel;

        if (snapshot.hasError) {
          errorLabel = _errorLabel(snapshot.error);
        }

        final profile = snapshot.data;
        if (!snapshot.hasError && profile != null && profile.exists) {
          if (profile.isDeleted) {
            username = 'משתמש מחוק';
            profileImageUrl = '';
          } else {
            username = profile.handle.trim().isNotEmpty
                ? profile.handle
                : fallbackHandle;
            profileImageUrl = profile.profilePictureUrl.trim();
          }
        }

        final usernameCore = username.replaceAll('@', '').trim();
        final usernameTextDirection = _containsHebrew(usernameCore)
            ? TextDirection.rtl
            : TextDirection.ltr;

        return Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: compact ? 8 : 10,
                        vertical: compact ? 4 : 5,
                      ),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(999),
                        color: isLight
                            ? Colors.white.withValues(alpha: 0.92)
                            : null,
                        gradient: isLight
                            ? null
                            : LinearGradient(
                                colors: [
                                  const Color(0xFF14233A)
                                      .withValues(alpha: 0.9),
                                  const Color(0xFF281D49)
                                      .withValues(alpha: 0.9),
                                ],
                                begin: Alignment.centerLeft,
                                end: Alignment.centerRight,
                              ),
                        border: Border.all(
                          color: isLight
                              ? const Color(0xFFA9C3FF)
                              : const Color(0xFF46D3FF).withValues(alpha: 0.35),
                        ),
                      ),
                      child: Text(
                        username,
                        textDirection: usernameTextDirection,
                        style: TextStyle(
                          color:
                              isLight ? Colors.black : const Color(0xFFEAF4FF),
                          fontWeight: FontWeight.w800,
                          fontSize: compact ? 12.5 : 14,
                          fontFamily: 'Segoe UI',
                        ),
                      ),
                    ),
                  ],
                ),
                if (errorLabel != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    errorLabel,
                    style: const TextStyle(
                      color: Color(0xFFFFB4B4),
                      fontWeight: FontWeight.w700,
                      fontSize: 11,
                    ),
                  ),
                ],
              ],
            ),
            SizedBox(width: compact ? 6 : 10),
            Container(
              width: compact ? 38 : 44,
              height: compact ? 38 : 44,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  colors: [Color(0xFF8C62FF), Color(0xFF46D3FF)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: Container(
                margin: EdgeInsets.all(compact ? 1.1 : 1.3),
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color(0xFF122034),
                ),
                child: ClipOval(
                  child: SizedBox(
                    width: compact ? 34 : 40,
                    height: compact ? 34 : 40,
                    child: _avatar(profileImageUrl),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

// --- ??? מסכי תשתית זמניים לצורך מניעת שגיאות קומפילציה וניווט תקין ---

class UserDetailScreen extends StatefulWidget {
  final String uid;

  const UserDetailScreen({super.key, required this.uid});

  @override
  State<UserDetailScreen> createState() => _UserDetailScreenState();
}

class _UserDetailScreenState extends State<UserDetailScreen> {
  @override
  void initState() {
    super.initState();
    debugPrint('UserDetailScreen uid: ${widget.uid}');
  }

  @override
  Widget build(BuildContext context) {
    return UserProfileScreen(
      uid: widget.uid,
      currentBottomIndex: 0,
    );
  }
}

class _AutoPlayVideoItem extends StatefulWidget {
  final String url;

  const _AutoPlayVideoItem({required this.url});

  @override
  State<_AutoPlayVideoItem> createState() => _AutoPlayVideoItemState();
}

class _AutoPlayVideoItemState extends State<_AutoPlayVideoItem> {
  VideoPlayerController? _controller;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.networkUrl(Uri.parse(widget.url))
      ..setLooping(true)
      ..initialize().then((_) {
        if (!mounted) return;
        _controller?.play();
        setState(() {});
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
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFF9E7CFF)),
      );
    }

    return FittedBox(
      fit: BoxFit.cover,
      child: SizedBox(
        width: controller.value.size.width,
        height: controller.value.size.height,
        child: VideoPlayer(controller),
      ),
    );
  }
}
