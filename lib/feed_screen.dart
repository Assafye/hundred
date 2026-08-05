import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'services/share_flow_log_service.dart';
import 'services/social_service.dart';
import 'services/spontaneous_challenge_service.dart';
import 'category_screen.dart';
import 'user_profile_screen.dart';
import 'main_bottom_nav.dart';
import 'stars_screen.dart'
    show
        StarsScreen,
        showActiveSpontaneousTaskModal,
        showSpontaneousLotteryModal;
import 'app_categories.dart';
import 'widgets/post_media_viewer.dart';
import 'widgets/post_comments_sheet.dart';
import 'widgets/post_share_targets_sheet.dart';

enum _FeedShareMenuAction { copyLink, sendToFriend, systemShare }

class FeedScreen extends StatefulWidget {
  const FeedScreen({
    super.key,
    this.initialSpontaneousPromptDelay = Duration.zero,
  });

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
  final Map<String, Future<DocumentSnapshot<Map<String, dynamic>>>>
      _authorFutureCache = {};
  Offset _heartTapPosition = Offset.zero;
  bool _showDoubleTapHeart = false;
  String _activeHeartPostId = '';
  SpontaneousChallengeTask? _activeSpontaneousTask;
  Duration _activeSpontaneousRemaining = Duration.zero;
  Timer? _spontaneousCountdownTimer;
  Timer? _spontaneousPromptTimer;
  Stream<List<Map<String, dynamic>>>? _cachedFeedStream;
  String _cachedFeedStreamKey = '';
  Future<List<PostModel>>? _cachedAudienceFilterFuture;
  String _cachedAudienceFilterKey = '';

  late final List<String> categories;
  String _randomizedFeedSignature = '';
  Map<String, int> _randomizedFeedOrder = <String, int>{};
  bool _didScheduleSpontaneousPrompt = false;

  @override
  void initState() {
    super.initState();
    categories = appMainCategories;
    MainBottomNav.feedPlaybackPausedByComposer
        .addListener(_syncForegroundStateWithComposer);
    _syncForegroundStateWithComposer();
    _scheduleSpontaneousPromptIfNeeded();
    _loadActiveSpontaneousTask();
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

  void _scheduleSpontaneousPromptIfNeeded() {
    if (_didScheduleSpontaneousPrompt) {
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

  Future<DocumentSnapshot<Map<String, dynamic>>> _authorFuture(
      String authorId) {
    final normalizedId = authorId.trim();
    if (normalizedId.isEmpty) {
      return Future<DocumentSnapshot<Map<String, dynamic>>>.error(
        StateError('Missing authorId for users lookup'),
      );
    }

    final cached = _authorFutureCache[normalizedId];
    if (cached != null) return cached;

    final future = FirebaseFirestore.instance
        .collection('users')
        .doc(normalizedId)
        .get()
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
      ),
    );
    await ShareFlowLogService.log(
      'FEED_SHARE_TARGETS_SHEET_CLOSED',
      data: <String, Object?>{'postId': post.id},
    );
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

  PostModel _postFromMap(Map<String, dynamic> data) {
    final likes = (data['likes'] as List<dynamic>? ?? const []);
    final savedBy = (data['savedBy'] as List<dynamic>? ?? const []);
    final currentUid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
    final likedByCurrentUser = currentUid.isNotEmpty &&
        likes.map((item) => item.toString().trim()).contains(currentUid);
    final savedByCurrentUser = currentUid.isNotEmpty &&
        savedBy.map((item) => item.toString().trim()).contains(currentUid);
    final createdAtRaw = data['createdAt'];
    final authorMap =
        (data['author'] as Map<String, dynamic>?) ?? <String, dynamic>{};
    final uid = ((data['authorId'] as String?) ??
            (data['userId'] as String?) ??
            (data['uid'] as String?) ??
            (authorMap['authorId'] as String?) ??
            (authorMap['userId'] as String?) ??
            (authorMap['uid'] as String?) ??
            '')
        .trim();
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
        false;
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
      id: (data['postId'] as String? ?? data['id'] as String? ?? '').trim(),
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
      likesCount: (data['likesCount'] as num?)?.toInt() ?? likes.length,
      commentsCount: (data['commentsCount'] as num?)?.toInt() ??
          (data['comments'] as List<dynamic>?)?.length ??
          0,
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
    final participantUids = _participantUidsForPost(post, includeAuthor: false);
    if (participantUids.isEmpty) {
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
                    if (profiles.isEmpty) {
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
                                                      ? const Color(0xFFD5E2FF)
                                                      : const Color(0xFF26354D))
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
                                                      ? const Color(0xFF2E3E63)
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

  Stream<Set<String>> _followingIdsStream() {
    final currentUid = FirebaseAuth.instance.currentUser?.uid;
    if (currentUid == null || currentUid.isEmpty) {
      return Stream<Set<String>>.value(<String>{});
    }

    return FirebaseFirestore.instance
        .collection('users')
        .doc(currentUid)
        .snapshots()
        .map((snapshot) {
      final data = snapshot.data() ?? <String, dynamic>{};
      final following = data['following'];
      if (following is! List) {
        return <String>{};
      }
      return following
          .map((uid) => uid.toString().trim())
          .where((uid) => uid.isNotEmpty)
          .toSet();
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

  Future<List<PostModel>> _applyAudienceFilter(List<PostModel> posts) async {
    final friendsOnlyAuthors = posts
        .where((post) {
          final audience = post.audience.trim().toLowerCase();
          return audience == 'friends';
        })
        .map((post) => post.authorId.trim())
        .where((authorId) => authorId.isNotEmpty)
        .toSet();

    final privateAuthors = posts
        .where((post) {
          return post.authorIsPrivate;
        })
        .map((post) => post.authorId.trim())
        .where((authorId) => authorId.isNotEmpty)
        .toSet();

    if (friendsOnlyAuthors.isEmpty && privateAuthors.isEmpty) {
      return posts;
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

    return posts.where((post) {
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

  Future<List<PostModel>> _resolveAudienceFilteredPosts(List<PostModel> posts) {
    final key = posts
        .map((post) =>
            '${post.id}:${post.authorId}:${post.audience}:${post.authorIsPrivate}')
        .join('|');

    if (_cachedAudienceFilterFuture != null &&
        _cachedAudienceFilterKey == key) {
      return _cachedAudienceFilterFuture!;
    }

    _cachedAudienceFilterKey = key;
    _cachedAudienceFilterFuture = _applyAudienceFilter(posts);
    return _cachedAudienceFilterFuture!;
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

  void _refreshFeedOnScopeSwitch(bool forYouFeed) {
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
    _cachedFeedStream = usingBackendFeed
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

    return _cachedFeedStream!;
  }

  @override
  Widget build(BuildContext context) {
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

        if (snapshot.connectionState == ConnectionState.waiting &&
            !snapshot.hasData) {
          return Scaffold(
            extendBody: true,
            backgroundColor: _feedBackgroundColor(context),
            body: _buildFeedState(
                child: const SizedBox.expand(), showLoader: true),
            bottomNavigationBar: const MainBottomNav(currentIndex: 0),
          );
        }

        final rawPosts = snapshot.data ?? const <Map<String, dynamic>>[];
        final postsFromDb = rawPosts
            .where((post) => !_isDeletedAuthorPost(post))
            .map(_postFromMap)
            .toList(growable: false);
        final randomizedPosts = _randomizePostsOnce(postsFromDb);
        final postsWithoutCurrentUser =
            _excludeCurrentUserPosts(randomizedPosts);

        return StreamBuilder<Set<String>>(
          stream: _followingIdsStream(),
          builder: (context, followingSnapshot) {
            final followingIds = followingSnapshot.data ?? <String>{};
            final scopedPosts = _postsForFeedScope(
              postsWithoutCurrentUser,
              followingIds,
              alreadyScopedByBackend: usingBackendFeed,
            );

            return FutureBuilder<List<PostModel>>(
              future: _resolveAudienceFilteredPosts(scopedPosts),
              builder: (context, audienceSnapshot) {
                final feedPosts = audienceSnapshot.data ?? const <PostModel>[];
                final scrollControls = _buildScrollControls(feedPosts.length);
                final activeFeedIndex = feedPosts.isEmpty
                    ? 0
                    : _currentFeedPageIndex.clamp(0, feedPosts.length - 1);
                final emptyMessage = isForYouFeed
                    ? 'אין פוסטים להצגה בקטגוריה/תת-קטגוריה זו'
                    : 'אין פוסטים של חברים להצגה';

                return Scaffold(
                  extendBody: true,
                  backgroundColor: _feedBackgroundColor(context),
                  body: _buildFeedState(
                    activePostSubCategory: feedPosts.isEmpty
                        ? null
                        : feedPosts[activeFeedIndex].subCategory,
                    child: feedPosts.isEmpty
                        ? Center(
                            child: Text(
                              emptyMessage,
                              style: TextStyle(
                                color: _isLightMode(context)
                                    ? const Color(0xFF5A6783)
                                    : Colors.white70,
                                fontSize: 18,
                              ),
                            ),
                          )
                        : PageView.builder(
                            controller: _pageController,
                            scrollDirection: Axis.vertical,
                            allowImplicitScrolling: true,
                            itemCount: feedPosts.length,
                            onPageChanged: (index) {
                              if (_currentFeedPageIndex == index) return;
                              setState(() {
                                _currentFeedPageIndex = index;
                              });
                            },
                            itemBuilder: (context, index) {
                              return _buildPostBlock(
                                feedPosts[index],
                                isActive: _isFeedInForeground &&
                                    index == activeFeedIndex,
                              );
                            },
                          ),
                  ),
                  floatingActionButton: scrollControls,
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
  }

  Widget _buildPostBlock(PostModel post, {required bool isActive}) {
    final isLight = _isLightMode(context);
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
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
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
                      Text(
                        post.description,
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
    }) {
      return Container(
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
            return Row(
              mainAxisSize: MainAxisSize.min,
              textDirection: TextDirection.ltr,
              children: [
                if (showIcon) ...[
                  Icon(
                    icon,
                    size: emphasize ? 18 : 16,
                    color: selected ? timerTextColor : const Color(0xFF4A5B83),
                  ),
                  SizedBox(width: isTight ? 6 : 8),
                ],
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color:
                          selected ? timerTextColor : const Color(0xFF425070),
                      fontSize: emphasize ? 14 : 12,
                      fontWeight: selected ? FontWeight.w800 : FontWeight.w700,
                      letterSpacing: selected ? 0.2 : 0,
                    ),
                  ),
                ),
              ],
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
                ],
              ),
              if (isCategoryMenuOpen)
                Positioned(
                  top: 76,
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
                              child: Align(
                                alignment: Alignment.centerRight,
                                child: futuristicCategoryChip(
                                  category,
                                  selected: isSelected,
                                  icon: _getCategoryIcon(
                                    category,
                                  ),
                                ),
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
                  top: 76,
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
                              child: Align(
                                alignment: Alignment.centerRight,
                                child: futuristicCategoryChip(
                                  subCategory,
                                  selected: isSelected,
                                  icon: Icons.radio_button_checked_rounded,
                                ),
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

class AuthorInfoWidget extends StatelessWidget {
  final String authorId;
  final Future<DocumentSnapshot<Map<String, dynamic>>> userFuture;
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

  String _formatHandleLabel(String rawUsername) {
    final normalized = rawUsername.trim();
    if (normalized.isEmpty) return normalized;

    final core = normalized.replaceAll('@', '').trim();
    if (core.isEmpty) return normalized;

    if (_containsHebrew(core)) {
      return '$core@';
    }
    return '@$core';
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
      if (error.code == 'permission-denied') {
        return 'אין הרשאה';
      }
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

    return FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      future: userFuture,
      builder: (context, snapshot) {
        String username = fallbackHandle;
        String profileImageUrl = '';
        String? errorLabel;

        if (snapshot.hasError) {
          errorLabel = _errorLabel(snapshot.error);
        }

        if (!snapshot.hasError && snapshot.hasData && snapshot.data!.exists) {
          final userData = snapshot.data!.data() ?? <String, dynamic>{};
          final isDeleted = (userData['isDeleted'] as bool?) ?? false;
          final rawUsername = ((userData['username'] as String?) ??
                  (userData['displayName'] as String?) ??
                  '')
              .trim();
          final rawImageUrl = ((userData['profileImageUrl'] as String?) ??
                  (userData['profilePictureUrl'] as String?) ??
                  '')
              .trim();

          if (isDeleted) {
            username = 'משתמש מחוק';
            profileImageUrl = '';
          } else if (rawUsername.isNotEmpty) {
            username = _formatHandleLabel(rawUsername);
            profileImageUrl = rawImageUrl;
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
