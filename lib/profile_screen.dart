import 'dart:async';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:share_plus/share_plus.dart';

import 'app_categories.dart';
import 'edit_profile_screen.dart';
import 'main_bottom_nav.dart';
import 'notifications_preview_screen.dart';
import 'post_media_utils.dart';
import 'profile_post_grouping.dart';
import 'post_detail_view.dart';
import 'saved_posts_screen.dart';
import 'services/keyboard_dismiss_controller.dart';
import 'services/social_service.dart';
import 'services/spontaneous_challenge_service.dart';
import 'services/post_interaction_overlay_service.dart';
import 'services/public_user_profile_service.dart';
import 'stars_screen.dart' show showActiveSpontaneousTaskModal;
import 'settings_screen.dart';
import 'user_profile_screen.dart';
import 'widgets/profile_images_viewer_dialog.dart';
import 'widgets/post_media_viewer.dart';
import 'video_preview_utils.dart';

class _ProfileCategoryNavItem {
  final String key;
  final String label;
  final IconData icon;
  final String? firestoreCategory;

  const _ProfileCategoryNavItem({
    required this.key,
    required this.label,
    required this.icon,
    this.firestoreCategory,
  });
}

class _ProfileRelationUser {
  final String uid;
  final String name;
  final String handle;
  final String avatarUrl;

  const _ProfileRelationUser({
    required this.uid,
    required this.name,
    required this.handle,
    required this.avatarUrl,
  });
}

class _TaskCategoryProgress {
  final String category;
  final List<String> availableSubCategories;
  final Set<String> doneSubCategories;

  const _TaskCategoryProgress({
    required this.category,
    required this.availableSubCategories,
    required this.doneSubCategories,
  });

  int get doneCount => doneSubCategories.length;
  int get totalCount => availableSubCategories.length;
  bool get isComplete => totalCount > 0 && doneCount >= totalCount;
}

class MainUserProfileScreen extends StatefulWidget {
  final String initialCategoryKey;

  const MainUserProfileScreen({
    super.key,
    this.initialCategoryKey = 'general',
  });

  @override
  State<MainUserProfileScreen> createState() => _MainUserProfileScreenState();
}

class MyProfileScreen extends MainUserProfileScreen {
  const MyProfileScreen({
    super.key,
    super.initialCategoryKey,
  });
}

class _MainUserProfileScreenState extends State<MainUserProfileScreen> {
  static const int _subCategoryGoal = 100;
  late final String _uid;
  late final ScrollController _sidebarScrollController;
  SpontaneousChallengeTask? _activeSpontaneousTask;
  Duration _activeSpontaneousRemaining = Duration.zero;
  Timer? _spontaneousCountdownTimer;
  String _selectedCategoryKey = 'general';
  final Map<String, Future<String?>> _resolvedMediaFutureByPostKey = {};
  final Map<String, Future<Uint8List?>> _videoPreviewFutureByUrl = {};
  final SocialService _socialService = SocialService();
  final PublicUserProfileService _publicUserProfileService =
      PublicUserProfileService();

  static final List<_ProfileCategoryNavItem> _categoryItems = [
    const _ProfileCategoryNavItem(
        key: 'drafts', label: 'טיוטות', icon: Icons.edit_note_rounded),
    const _ProfileCategoryNavItem(
        key: 'general', label: 'כללי', icon: Icons.dashboard_rounded),
    const _ProfileCategoryNavItem(
        key: 'tagged', label: 'תיוגים', icon: Icons.alternate_email_rounded),
    ...appMainCategories.where((category) => !isGeneralCategory(category)).map(
          (category) => _ProfileCategoryNavItem(
            key: category,
            label: category,
            icon: categoryIconFor(category),
            firestoreCategory: category,
          ),
        ),
  ];

  @override
  void initState() {
    super.initState();
    KeyboardDismissController.suspend();
    _uid = FirebaseAuth.instance.currentUser!.uid;
    _selectedCategoryKey = _categoryItems
            .any((item) => item.key == widget.initialCategoryKey.trim())
        ? widget.initialCategoryKey.trim()
        : 'general';
    _sidebarScrollController = ScrollController();
    _loadActiveSpontaneousTask();
  }

  @override
  void dispose() {
    KeyboardDismissController.resume();
    _spontaneousCountdownTimer?.cancel();
    _sidebarScrollController.dispose();
    super.dispose();
  }

  bool _tapHitsEditable(PointerDownEvent event) {
    final hitTestResult = HitTestResult();
    GestureBinding.instance.hitTest(hitTestResult, event.position);
    for (final entry in hitTestResult.path) {
      if (entry.target is RenderEditable) {
        return true;
      }
    }
    return false;
  }

  void _dismissKeyboardOnBackgroundTap(PointerDownEvent event) {
    if (_tapHitsEditable(event)) {
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
  }

  Future<void> _loadActiveSpontaneousTask() async {
    if (_uid.trim().isEmpty) {
      if (!mounted) return;
      setState(() {
        _activeSpontaneousTask = null;
        _activeSpontaneousRemaining = Duration.zero;
      });
      return;
    }

    final task = await SpontaneousChallengeService.currentTaskForUser(_uid);
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
    final totalSeconds = remaining.inSeconds < 0 ? 0 : remaining.inSeconds;
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

  Stream<DocumentSnapshot<Map<String, dynamic>>> _profileStream() {
    return FirebaseFirestore.instance.collection('users').doc(_uid).snapshots();
  }

  Stream<DocumentSnapshot<Map<String, dynamic>>> _publicProfileStream() {
    return FirebaseFirestore.instance
        .collection('users_public')
        .doc(_uid)
        .snapshots();
  }

  Future<bool> _confirmRelationAction({
    required String title,
    required String message,
  }) async {
    final isLight = Theme.of(context).brightness == Brightness.light;
    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            backgroundColor: isLight ? Colors.white : const Color(0xFF161F2E),
            title: Text(
              title,
              textAlign: TextAlign.right,
              style: TextStyle(color: isLight ? Colors.black : Colors.white),
            ),
            content: Text(
              message,
              textAlign: TextAlign.right,
              style:
                  TextStyle(color: isLight ? Colors.black87 : Colors.white70),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('ביטול'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('אישור'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _openFollowRequestsPage() async {
    if (!mounted) return;

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: Theme.of(context).brightness == Brightness.light
              ? const Color(0xFFF4F8FF)
              : const Color(0xFF0B1019),
          appBar: AppBar(title: const Text('בקשות מעקב')),
          body: StreamBuilder<List<String>>(
            stream: _socialService.incomingFollowRequestsStream(),
            builder: (context, snapshot) {
              final requestUids = snapshot.data ?? const <String>[];
              if (requestUids.isEmpty) {
                return const Center(child: Text('אין בקשות מעקב כרגע'));
              }

              return FutureBuilder<List<_ProfileRelationUser>>(
                future: _relationUsersForIds(requestUids),
                builder: (context, usersSnapshot) {
                  if (usersSnapshot.connectionState ==
                      ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }

                  final users =
                      usersSnapshot.data ?? const <_ProfileRelationUser>[];
                  if (users.isEmpty) {
                    return const Center(child: Text('אין בקשות מעקב כרגע'));
                  }

                  return ListView.builder(
                    padding: const EdgeInsets.fromLTRB(14, 14, 14, 18),
                    itemCount: users.length,
                    itemBuilder: (context, index) {
                      final user = users[index];
                      return Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color:
                              Theme.of(context).brightness == Brightness.light
                                  ? Colors.white
                                  : const Color(0xFF1A2435),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Row(
                          children: [
                            CircleAvatar(
                              radius: 20,
                              backgroundImage: user.avatarUrl.isNotEmpty
                                  ? NetworkImage(user.avatarUrl)
                                  : null,
                              child: user.avatarUrl.isEmpty
                                  ? Text(
                                      user.name.isNotEmpty
                                          ? user.name.characters.first
                                          : '?',
                                    )
                                  : null,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    user.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  Text(
                                    user.handle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            TextButton(
                              onPressed: () async {
                                await _socialService
                                    .rejectFollowRequest(user.uid);
                              },
                              child: const Text('סרב'),
                            ),
                            ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                minimumSize: const Size(0, 34),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 6,
                                ),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                textStyle: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              onPressed: () async {
                                await _socialService
                                    .approveFollowRequest(user.uid);
                              },
                              child: const Text('אשר'),
                            ),
                          ],
                        ),
                      );
                    },
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildFollowRequestsButton(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    return StreamBuilder<List<String>>(
      stream: _socialService.incomingFollowRequestsStream(),
      builder: (context, snapshot) {
        final requestCount = snapshot.data?.length ?? 0;
        return GestureDetector(
          onTap: _openFollowRequestsPage,
          child: Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              gradient: isLight
                  ? null
                  : const LinearGradient(
                      colors: [Color(0xFF182336), Color(0xFF111B2B)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
              color: isLight ? Colors.white : null,
              border: Border.all(
                color: isLight
                    ? const Color(0xFFA7BFFF)
                    : const Color(0xFF53C1F9).withValues(alpha: 0.14),
                width: 0.9,
              ),
            ),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Center(
                  child: Icon(
                    Icons.person_add_alt_1_rounded,
                    color: isLight
                        ? const Color(0xFF9AB0FF)
                        : const Color(0xFF8EDEFF),
                    size: 22,
                  ),
                ),
                if (requestCount > 0)
                  Positioned(
                    top: -3,
                    left: -3,
                    child: Container(
                      constraints:
                          const BoxConstraints(minWidth: 22, minHeight: 22),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFF5C8A),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: Colors.white, width: 1.1),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        requestCount > 99 ? '99+' : '$requestCount',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          height: 1,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Stream<List<QueryDocumentSnapshot<Map<String, dynamic>>>> _allPostsStream() {
    final authoredStream = FirebaseFirestore.instance
        .collection('posts')
        .where('authorId', isEqualTo: _uid)
        .snapshots();
    final taggedStream = FirebaseFirestore.instance
        .collection('posts')
        .where('members', arrayContains: _uid)
        .snapshots();

    return Stream.multi((controller) {
      QuerySnapshot<Map<String, dynamic>>? authoredSnapshot;
      QuerySnapshot<Map<String, dynamic>>? taggedSnapshot;

      void emitMerged() {
        if (authoredSnapshot == null || taggedSnapshot == null) {
          return;
        }

        final mergedById =
            <String, QueryDocumentSnapshot<Map<String, dynamic>>>{};
        for (final doc in authoredSnapshot!.docs) {
          mergedById[doc.id] = doc;
        }
        for (final doc in taggedSnapshot!.docs) {
          mergedById[doc.id] = doc;
        }

        final merged = mergedById.values.toList(growable: false)
          ..sort((a, b) =>
              _createdAtFrom(b.data()).compareTo(_createdAtFrom(a.data())));

        controller.add(merged);
      }

      final authoredSub = authoredStream.listen(
        (snapshot) {
          authoredSnapshot = snapshot;
          emitMerged();
        },
        onError: controller.addError,
      );
      final taggedSub = taggedStream.listen(
        (snapshot) {
          taggedSnapshot = snapshot;
          emitMerged();
        },
        onError: controller.addError,
      );

      controller.onCancel = () async {
        await authoredSub.cancel();
        await taggedSub.cancel();
      };
    });
  }

  Map<String, dynamic> _placeholderProfile() {
    return <String, dynamic>{
      'firstName': 'הפרופיל שלי',
      'lastName': '',
      'username': '@my_profile',
      'bio': 'זהו פרופיל לדוגמה עד שהנתונים נטענים.',
      'profilePictureUrl': '',
      'score': 0,
      'allowGroupInvite': true,
    };
  }

  String _postStatus(Map<String, dynamic> data) {
    final status =
        (data['status'] as String? ?? 'published').trim().toLowerCase();
    return status.isEmpty ? 'published' : status;
  }

  String _postCategory(Map<String, dynamic> data) {
    return (data['category'] as String? ?? '').trim();
  }

  String _postSubCategory(Map<String, dynamic> data) {
    return (data['subCategory'] as String? ?? '').trim();
  }

  String? _postedSubCategoryKey({
    required String category,
    required String subCategory,
  }) {
    final normalizedCategory = category.trim();
    final normalizedSubCategory = subCategory.trim();
    if (normalizedCategory.isEmpty ||
        normalizedSubCategory.isEmpty ||
        normalizedSubCategory == 'אחר' ||
        isGeneralCategory(normalizedCategory)) {
      return null;
    }

    final availableSubCategories = appSubCategories(normalizedCategory);
    if (!availableSubCategories.contains(normalizedSubCategory)) {
      return null;
    }

    return '$normalizedCategory::$normalizedSubCategory';
  }

  int _livePostedSubCategoryCount(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> allDocs,
  ) {
    final uniqueKeys = <String>{};
    for (final doc in allDocs) {
      final data = doc.data();
      if (_postAuthorId(data) != _uid || _postStatus(data) != 'published') {
        continue;
      }
      final key = _postedSubCategoryKey(
        category: _postCategory(data),
        subCategory: _postSubCategory(data),
      );
      if (key != null) {
        uniqueKeys.add(key);
      }
    }
    return uniqueKeys.length;
  }

  List<String> _validTaskSubCategories(String category) {
    return appSubCategories(category)
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty && item != 'אחר')
        .toList(growable: false);
  }

  List<String> _taskCategoriesForDialog() {
    return appMainCategories
        .where((category) => !isGeneralCategory(category))
        .where((category) => _validTaskSubCategories(category).isNotEmpty)
        .toList(growable: false);
  }

  Map<String, _TaskCategoryProgress> _taskProgressByCategory(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> allDocs,
  ) {
    final categories = _taskCategoriesForDialog();
    final doneByCategory = <String, Set<String>>{};
    final availableByCategory = <String, List<String>>{};

    for (final category in categories) {
      availableByCategory[category] = _validTaskSubCategories(category);
      doneByCategory[category] = <String>{};
    }

    for (final doc in allDocs) {
      final data = doc.data();
      if (_postAuthorId(data) != _uid || _postStatus(data) != 'published') {
        continue;
      }

      final category = _postCategory(data);
      final subCategory = _postSubCategory(data);
      final available = availableByCategory[category];
      if (available == null || subCategory.isEmpty || subCategory == 'אחר') {
        continue;
      }
      if (available.contains(subCategory)) {
        doneByCategory[category]!.add(subCategory);
      }
    }

    return {
      for (final category in categories)
        category: _TaskCategoryProgress(
          category: category,
          availableSubCategories: availableByCategory[category]!,
          doneSubCategories: doneByCategory[category]!,
        ),
    };
  }

  Future<void> _openTaskProgressCategoriesDialog({
    required List<QueryDocumentSnapshot<Map<String, dynamic>>> allDocs,
  }) async {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final categories = _taskCategoriesForDialog();
    final progressByCategory = _taskProgressByCategory(allDocs);

    await showGeneralDialog<void>(
      context: context,
      transitionDuration: Duration.zero,
      barrierDismissible: true,
      barrierLabel: 'task-progress-categories',
      barrierColor: Colors.transparent,
      pageBuilder: (dialogContext, __, ___) {
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 20,
          ),
          child: Container(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(dialogContext).size.width * 0.94,
              maxHeight: MediaQuery.of(dialogContext).size.height * 0.84,
            ),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(30),
              gradient: const LinearGradient(
                colors: [Color(0xFF53C1F9), Color(0xFF9E7CFF)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            padding: const EdgeInsets.all(1.8),
            child: Container(
              decoration: BoxDecoration(
                color:
                    isLight ? const Color(0xFFF8FBFF) : const Color(0xFF101826),
                borderRadius: BorderRadius.circular(28),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        IconButton(
                          onPressed: () => Navigator.of(dialogContext).pop(),
                          icon: Icon(
                            Icons.arrow_back_rounded,
                            color: isLight
                                ? const Color(0xFF33405B)
                                : Colors.white70,
                          ),
                        ),
                        const Expanded(
                          child: Column(
                            children: [
                              Text(
                                'התקדמות לפי קטגוריה',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: Color(0xFF22314F),
                                  fontSize: 19,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                              Text(
                                'בחרו קטגוריה כדי לראות את תתי הקטגוריות שלה',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: Color(0xFF596682),
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 46),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: categories.isEmpty
                          ? Center(
                              child: Text(
                                'אין קטגוריות להצגה כרגע',
                                style: TextStyle(
                                  color: isLight
                                      ? const Color(0xFF596682)
                                      : Colors.white70,
                                ),
                              ),
                            )
                          : SingleChildScrollView(
                              physics: const BouncingScrollPhysics(),
                              child: Wrap(
                                alignment: WrapAlignment.center,
                                spacing: 14,
                                runSpacing: 14,
                                children: categories.map((category) {
                                  final progress =
                                      progressByCategory[category]!;
                                  return _buildTaskCategoryProgressBubble(
                                    category: category,
                                    progress: progress,
                                    isLight: isLight,
                                    onTap: () {
                                      _openTaskProgressSubCategoriesDialog(
                                        category: category,
                                        progress: progress,
                                        allDocs: allDocs,
                                      );
                                    },
                                  );
                                }).toList(growable: false),
                              ),
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
  }

  Future<void> _openTaskProgressSubCategoriesDialog({
    required String category,
    required _TaskCategoryProgress progress,
    required List<QueryDocumentSnapshot<Map<String, dynamic>>> allDocs,
  }) async {
    final isLight = Theme.of(context).brightness == Brightness.light;

    await showGeneralDialog<void>(
      context: context,
      transitionDuration: Duration.zero,
      barrierDismissible: true,
      barrierLabel: 'task-sub-categories',
      barrierColor: Colors.transparent,
      pageBuilder: (dialogContext, __, ___) {
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 20),
          child: Container(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(dialogContext).size.width * 0.94,
              maxHeight: MediaQuery.of(dialogContext).size.height * 0.84,
            ),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(30),
              gradient: const LinearGradient(
                colors: [Color(0xFF53C1F9), Color(0xFF9E7CFF)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            padding: const EdgeInsets.all(1.8),
            child: Container(
              decoration: BoxDecoration(
                color:
                    isLight ? const Color(0xFFF8FBFF) : const Color(0xFF101826),
                borderRadius: BorderRadius.circular(28),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        IconButton(
                          onPressed: () => Navigator.of(dialogContext).pop(),
                          icon: Icon(
                            Icons.arrow_back_rounded,
                            color: isLight
                                ? const Color(0xFF33405B)
                                : Colors.white70,
                          ),
                        ),
                        Expanded(
                          child: Column(
                            children: [
                              Text(
                                category,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: isLight
                                      ? const Color(0xFF22314F)
                                      : Colors.white,
                                  fontSize: 19,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                              Text(
                                'תתי קטגוריות שהושלמו: ${progress.doneCount}/${progress.totalCount}',
                                style: TextStyle(
                                  color: isLight
                                      ? const Color(0xFF596682)
                                      : Colors.white70,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 46),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: progress.availableSubCategories.isEmpty
                          ? Center(
                              child: Text(
                                'אין תתי קטגוריות להצגה',
                                style: TextStyle(
                                  color: isLight
                                      ? const Color(0xFF596682)
                                      : Colors.white70,
                                ),
                              ),
                            )
                          : SingleChildScrollView(
                              physics: const BouncingScrollPhysics(),
                              child: Wrap(
                                alignment: WrapAlignment.center,
                                spacing: 12,
                                runSpacing: 12,
                                children: progress.availableSubCategories
                                    .map(
                                      (subCategory) =>
                                          _buildTaskSubCategoryProgressBubble(
                                        subCategory: subCategory,
                                        isDone: progress.doneSubCategories
                                            .contains(subCategory),
                                        isLight: isLight,
                                        onTap: () =>
                                            _showTopPostsForTaskSubCategory(
                                          allDocs: allDocs,
                                          category: category,
                                          subCategory: subCategory,
                                        ),
                                      ),
                                    )
                                    .toList(growable: false),
                              ),
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
  }

  Widget _buildTaskCategoryProgressBubble({
    required String category,
    required _TaskCategoryProgress progress,
    required bool isLight,
    required VoidCallback onTap,
  }) {
    final icon = categoryIconFor(category);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: SizedBox(
          width: 136,
          height: 136,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                width: 136,
                height: 136,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: const LinearGradient(
                    colors: [Color(0xFF8DE8FF), Color(0xFFC9B5FF)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  border: Border.all(
                      color: Colors.white.withValues(alpha: 0.72), width: 1.2),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF76CFFF).withValues(alpha: 0.35),
                      blurRadius: 15,
                      offset: const Offset(0, 7),
                    ),
                  ],
                ),
                child: Padding(
                  padding: const EdgeInsets.all(13),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(icon, color: const Color(0xFF2A2361), size: 32),
                        const SizedBox(height: 7),
                        SizedBox(
                          width: 106,
                          child: Text(
                            category.trim(),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            textDirection: TextDirection.rtl,
                            style: TextStyle(
                              color: const Color(0xFF2A2361),
                              fontSize: isLight ? 13.1 : 12.9,
                              fontWeight: FontWeight.w900,
                              height: 1.1,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 2,
                left: 2,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(999),
                    gradient: progress.isComplete
                        ? const LinearGradient(
                            colors: [Color(0xFFDBFFE6), Color(0xFF7EE3A2)],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          )
                        : const LinearGradient(
                            colors: [Color(0xFFFFE9C9), Color(0xFFFFA94D)],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                    border:
                        Border.all(color: Colors.white.withValues(alpha: 0.8)),
                  ),
                  child: Text(
                    progress.isComplete
                        ? 'עשית הכל!'
                        : '${progress.doneCount}/${progress.totalCount}',
                    style: TextStyle(
                      color: progress.isComplete
                          ? const Color(0xFF1A7C43)
                          : const Color(0xFF7A3D00),
                      fontSize: 10.5,
                      fontWeight: FontWeight.w900,
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

  Widget _buildTaskSubCategoryProgressBubble({
    required String subCategory,
    required bool isDone,
    required bool isLight,
    VoidCallback? onTap,
  }) {
    final normalizedSubCategory = subCategory.trim();
    final textLength = normalizedSubCategory.length;
    const double diameter = 136.0;
    const double textWidth = 112.0;
    final fontSize = textLength > 38
        ? 9.6
        : textLength > 30
            ? 10.1
            : textLength > 22
                ? 10.8
                : (isLight ? 11.6 : 11.4);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          width: diameter,
          height: diameter,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: isDone
                ? const LinearGradient(
                    colors: [Color(0xFFE2E6ED), Color(0xFFB9C2CF)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  )
                : const LinearGradient(
                    colors: [Color(0xFF8DE8FF), Color(0xFFC9B5FF)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
            border: Border.all(
                color: Colors.white.withValues(alpha: 0.72), width: 1.2),
            boxShadow: [
              BoxShadow(
                color:
                    (isDone ? const Color(0xFF8EA0B8) : const Color(0xFF76CFFF))
                        .withValues(alpha: 0.3),
                blurRadius: 14,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.category_rounded,
                        color: isDone
                            ? const Color(0xFF5F6E85)
                            : const Color(0xFF2A2361),
                        size: 28,
                      ),
                      const SizedBox(height: 6),
                      SizedBox(
                        width: textWidth,
                        child: Text(
                          normalizedSubCategory,
                          maxLines: 4,
                          textAlign: TextAlign.center,
                          textDirection: TextDirection.rtl,
                          style: TextStyle(
                            color: isDone
                                ? const Color(0xFF54657F)
                                : const Color(0xFF2A2361),
                            fontSize: fontSize,
                            fontWeight: FontWeight.w900,
                            height: 1.08,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (isDone)
                Positioned(
                  right: 2,
                  top: -10,
                  child: Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      color: const Color(0xFF53C98D),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 1.2),
                    ),
                    child: const Icon(
                      Icons.check_rounded,
                      color: Colors.white,
                      size: 13,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showTopPostsForTaskSubCategory({
    required List<QueryDocumentSnapshot<Map<String, dynamic>>> allDocs,
    required String category,
    required String subCategory,
  }) async {
    final rankedPosts = allDocs.where((doc) {
      final data = doc.data();
      return _postAuthorId(data) == _uid &&
          _postStatus(data) == 'published' &&
          _postCategory(data) == category &&
          _postSubCategory(data) == subCategory;
    }).map((doc) {
      final data = Map<String, dynamic>.from(doc.data());
      data['id'] = doc.id;
      data['postId'] = (data['postId'] as String? ?? doc.id).trim();
      return data;
    }).toList(growable: true)
      ..sort((a, b) {
        final scoreCmp = _postScore(b).compareTo(_postScore(a));
        if (scoreCmp != 0) return scoreCmp;
        return _createdAtFrom(b).compareTo(_createdAtFrom(a));
      });

    final topPosts = rankedPosts.take(5).toList(growable: false);
    if (!mounted) return;

    final isLight = Theme.of(context).brightness == Brightness.light;
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black54,
      builder: (sheetContext) {
        return Directionality(
          textDirection: TextDirection.rtl,
          child: Dialog(
            backgroundColor: Colors.transparent,
            insetPadding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 24),
            child: Container(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(sheetContext).size.height * 0.5,
              ),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(24),
                gradient: const LinearGradient(
                  colors: [Color(0xFF53C1F9), Color(0xFF9E7CFF)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              padding: const EdgeInsets.all(1.6),
              child: Container(
                decoration: BoxDecoration(
                  color: isLight ? Colors.white : const Color(0xFF101826),
                  borderRadius: BorderRadius.circular(22),
                ),
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
                child: topPosts.isEmpty
                    ? Center(
                        child: Text(
                          'אין פוסטים להצגה בתת קטגוריה הזו',
                          style: TextStyle(
                            color: isLight ? Colors.black54 : Colors.white70,
                          ),
                        ),
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            '$category • $subCategory',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: isLight ? Colors.black : Colors.white,
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Expanded(
                            child: ListView.builder(
                              itemCount: topPosts.length,
                              itemBuilder: (context, index) {
                                final post = topPosts[index];
                                final title = ((post['title'] as String?) ?? '')
                                        .trim()
                                        .isNotEmpty
                                    ? (post['title'] as String).trim()
                                    : 'פוסט ללא כותרת';
                                final score = _postScore(post);
                                return ListTile(
                                  onTap: () {
                                    Navigator.of(sheetContext).pop();
                                    Navigator.of(context).push(
                                      MaterialPageRoute(
                                        builder: (_) => PostDetailView(
                                          posts: topPosts,
                                          initialIndex: index,
                                          enableEditAction: true,
                                          disableOwnAuthorProfileTap: true,
                                        ),
                                      ),
                                    );
                                  },
                                  title: Text(
                                    title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color:
                                          isLight ? Colors.black : Colors.white,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  leading: _buildScoreSheetThumbnail(post),
                                  trailing: Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 10, vertical: 5),
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(999),
                                      gradient: const LinearGradient(
                                        colors: [
                                          Color(0xFF83E4FF),
                                          Color(0xFF9E7CFF)
                                        ],
                                      ),
                                    ),
                                    child: Text(
                                      '+${_formatCompactCount(score)}',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ),
                                );
                              },
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
  }

  String _displayName(Map<String, dynamic> data) {
    final firstName = _stringValue(data, const ['firstName']);
    final lastName = _stringValue(data, const ['lastName']);
    final username = _stringValue(data, const ['username']);
    final displayName = _stringValue(data, const ['displayName', 'fullName']);
    if (displayName.isNotEmpty) return displayName;
    final parts =
        [firstName, lastName].where((part) => part.isNotEmpty).toList();
    if (parts.isNotEmpty) return parts.join(' ');
    if (username.isNotEmpty) return username;
    return _uid;
  }

  String _username(Map<String, dynamic> data) {
    final username = _stringValue(data, const ['username']);
    if (username.isNotEmpty) {
      return username.startsWith('@') ? username : '@$username';
    }
    return '@${_uid.substring(0, _uid.length > 6 ? 6 : _uid.length)}';
  }

  String _bio(Map<String, dynamic> data) {
    final bio = _stringValue(data, const ['bio']);
    return bio.isNotEmpty ? bio : 'אין תיאור פרופיל עדיין.';
  }

  String _profileImageUrl(Map<String, dynamic> data) {
    return _stringValue(
      data,
      const ['profilePictureUrl', 'profileImageUrl', 'avatarUrl'],
    );
  }

  List<String> _profileImageUrls(Map<String, dynamic> data) {
    final urls = <String>[];
    final seen = <String>{};

    final primary = _profileImageUrl(data);
    if (primary.isNotEmpty && seen.add(primary)) {
      urls.add(primary);
    }

    final list = data['profileImageUrls'];
    if (list is List) {
      for (final item in list) {
        final url = item.toString().trim();
        if (url.isEmpty) continue;
        if (!(url.startsWith('http://') || url.startsWith('https://'))) {
          continue;
        }
        if (!seen.add(url)) continue;
        urls.add(url);
        if (urls.length >= 6) break;
      }
    }

    return urls;
  }

  String _stringValue(Map<String, dynamic> data, List<String> keys) {
    for (final key in keys) {
      if (!data.containsKey(key)) continue;
      final raw = data[key];
      if (raw == null) continue;
      final value = raw.toString().trim();
      if (value.isNotEmpty) return value;
    }
    return '';
  }

  int _intValue(Map<String, dynamic> data, List<String> keys,
      {int fallback = 0}) {
    for (final key in keys) {
      if (!data.containsKey(key)) continue;
      final raw = data[key];
      if (raw is num) return raw.toInt();
      if (raw is String) {
        final parsed = int.tryParse(raw.trim());
        if (parsed != null) return parsed;
      }
    }
    return fallback;
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

  DateTime _createdAtFrom(Map<String, dynamic> data) {
    final raw = data['createdAt'];
    if (raw is Timestamp) {
      return raw.toDate();
    }
    if (raw is DateTime) {
      return raw;
    }
    if (raw is String) {
      return DateTime.tryParse(raw) ?? DateTime.fromMillisecondsSinceEpoch(0);
    }
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  int _postScore(Map<String, dynamic> data) {
    final postId =
        (data['postId'] as String? ?? data['id'] as String? ?? '').trim();
    final scoreAwarded = _intValue(data, const ['scoreAwarded']);
    final likesCount = _intValue(
      data,
      const ['likesCount', 'likes_count'],
      fallback: ((data['likes'] as List<dynamic>?) ?? const <dynamic>[]).length,
    );
    final commentsCount = _intValue(
      data,
      const ['commentsCount', 'comments_count'],
      fallback:
          ((data['comments'] as List<dynamic>?) ?? const <dynamic>[]).length,
    );
    final sharesCount = _intValue(data, const ['sharesCount', 'shares_count']);
    final savesCount = _intValue(
      data,
      const ['savesCount', 'saves_count'],
      fallback:
          ((data['savedBy'] as List<dynamic>?) ?? const <dynamic>[]).length,
    );

    final likes = likesCount +
        PostInteractionOverlayService.deltaFor(
          postId: postId,
          metric: 'likes',
        );
    final comments = commentsCount +
        PostInteractionOverlayService.deltaFor(
          postId: postId,
          metric: 'comments',
        );
    final shares = sharesCount +
        PostInteractionOverlayService.deltaFor(
          postId: postId,
          metric: 'shares',
        );
    final saves = savesCount +
        PostInteractionOverlayService.deltaFor(
          postId: postId,
          metric: 'saves',
        );

    return scoreAwarded +
        likes.clamp(0, 1 << 30) +
        (comments.clamp(0, 1 << 30) * 2) +
        (shares.clamp(0, 1 << 30) * 3) +
        saves.clamp(0, 1 << 30);
  }

  String _postAuthorId(Map<String, dynamic> data) {
    return (data['authorId'] as String? ?? data['uid'] as String? ?? '').trim();
  }

  String _postAudience(Map<String, dynamic> data) {
    return (data['audience'] as String? ?? 'public').trim().toLowerCase();
  }

  Set<String> _participantUids(Map<String, dynamic> data) {
    final raw = (data['members'] as List<dynamic>? ??
        data['participants'] as List<dynamic>? ??
        const <dynamic>[]);
    return raw
        .map((item) => item.toString().trim())
        .where((uid) => uid.isNotEmpty)
        .toSet();
  }

  bool _isTaggedPostForUser(Map<String, dynamic> data, String uid) {
    final normalizedUid = uid.trim();
    if (normalizedUid.isEmpty) {
      return false;
    }

    final status = _postStatus(data);
    if (status != 'published') {
      return false;
    }

    final authorId = _postAuthorId(data);
    if (authorId == normalizedUid) {
      return false;
    }

    return _participantUids(data).contains(normalizedUid);
  }

  int _taggedPointsForUserFromPost(Map<String, dynamic> data, String uid) {
    if (!_isTaggedPostForUser(data, uid)) {
      return 0;
    }
    return _postScore(data) ~/ 5;
  }

  Widget _buildScoreSheetThumbnail(Map<String, dynamic> post) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final mediaItems = postMediaItemsFromData(post);
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: 46,
        height: 46,
        color: isLight
            ? Colors.white.withValues(alpha: 0.62)
            : const Color(0xFF1A2230),
        child: mediaItems.isNotEmpty
            ? PostMediaViewer(
                mediaItems: mediaItems,
                aspectRatio: null,
                showIndicators: false,
                isActive: false,
              )
            : FutureBuilder<String?>(
                future: _mediaFutureForPost(post),
                builder: (context, snapshot) {
                  final url = (snapshot.data ?? '').trim();
                  if (url.isEmpty) {
                    return Icon(
                      Icons.image_not_supported_rounded,
                      color: isLight ? Colors.black38 : Colors.white38,
                      size: 18,
                    );
                  }
                  return Image.network(
                    url,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Icon(
                      Icons.broken_image_outlined,
                      color: isLight ? Colors.black38 : Colors.white38,
                      size: 18,
                    ),
                  );
                },
              ),
      ),
    );
  }

  Future<void> _showScorePostsSheet(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> allDocs,
  ) async {
    final publishedDocs = allDocs
        .where((doc) =>
            _postStatus(doc.data()) == 'published' &&
            _postAuthorId(doc.data()) == _uid)
        .toList(growable: false);

    final rankedPosts = publishedDocs.map((doc) {
      final data = Map<String, dynamic>.from(doc.data());
      data['id'] = doc.id;
      data['postId'] = (data['postId'] as String? ?? doc.id).trim();
      return data;
    }).toList(growable: true)
      ..sort((a, b) {
        final scoreCmp = _postScore(b).compareTo(_postScore(a));
        if (scoreCmp != 0) return scoreCmp;
        return _createdAtFrom(b).compareTo(_createdAtFrom(a));
      });

    if (!mounted) return;
    final isLight = Theme.of(context).brightness == Brightness.light;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return Directionality(
          textDirection: TextDirection.rtl,
          child: SafeArea(
            child: Container(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(sheetContext).size.height * 0.78,
              ),
              margin: const EdgeInsets.fromLTRB(14, 8, 14, 16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(26),
                gradient: isLight
                    ? null
                    : const LinearGradient(
                        colors: [Color(0xFF53C1F9), Color(0xFF9E7CFF)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                color: isLight ? Colors.white : null,
              ),
              padding: const EdgeInsets.all(1.6),
              child: Stack(
                children: [
                  if (isLight)
                    Positioned(
                      top: -90,
                      right: -70,
                      child: IgnorePointer(
                        child: Container(
                          width: 260,
                          height: 260,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color:
                                const Color(0xFF9EEBFF).withValues(alpha: 0.14),
                          ),
                        ),
                      ),
                    ),
                  if (isLight)
                    Positioned(
                      bottom: -110,
                      left: -70,
                      child: IgnorePointer(
                        child: Container(
                          width: 280,
                          height: 280,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color:
                                const Color(0xFFB9A9FF).withValues(alpha: 0.14),
                          ),
                        ),
                      ),
                    ),
                  Container(
                    decoration: BoxDecoration(
                      color: isLight
                          ? Colors.white.withValues(alpha: 0.78)
                          : const Color(0xFF101826),
                      borderRadius: BorderRadius.circular(24),
                    ),
                    padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
                    child: rankedPosts.isEmpty
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Text(
                                'אין פוסטים מפורסמים להצגה',
                                style: TextStyle(
                                  color:
                                      isLight ? Colors.black87 : Colors.white70,
                                ),
                              ),
                            ),
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                'דירוג פוסטים לפי ניקוד',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: isLight ? Colors.black : Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(height: 12),
                              Expanded(
                                child: ListView.builder(
                                  itemCount: rankedPosts.length,
                                  itemBuilder: (context, index) {
                                    final post = rankedPosts[index];
                                    final title =
                                        (post['title'] as String? ?? '')
                                                .trim()
                                                .isNotEmpty
                                            ? (post['title'] as String).trim()
                                            : 'פוסט ללא כותרת';
                                    final subCategory =
                                        (post['subCategory'] as String? ?? '')
                                            .trim();
                                    final score = _postScore(post);

                                    return InkWell(
                                      borderRadius: BorderRadius.circular(14),
                                      onTap: () {
                                        Navigator.of(sheetContext).pop();
                                        Navigator.of(context).push(
                                          MaterialPageRoute(
                                            builder: (_) => PostDetailView(
                                              posts: rankedPosts,
                                              initialIndex: index,
                                              enableEditAction: true,
                                              disableOwnAuthorProfileTap: true,
                                            ),
                                          ),
                                        );
                                      },
                                      child: Container(
                                        margin:
                                            const EdgeInsets.only(bottom: 10),
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 12, vertical: 10),
                                        decoration: BoxDecoration(
                                          color: isLight
                                              ? Colors.white
                                                  .withValues(alpha: 0.62)
                                              : const Color(0xFF1A2435),
                                          borderRadius:
                                              BorderRadius.circular(14),
                                          border: Border.all(
                                            color: isLight
                                                ? const Color(0xFFA9C3FF)
                                                : const Color(0xFF53C1F9)
                                                    .withValues(alpha: 0.22),
                                          ),
                                        ),
                                        child: Row(
                                          children: [
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                      horizontal: 10,
                                                      vertical: 6),
                                              decoration: BoxDecoration(
                                                gradient: const LinearGradient(
                                                  colors: [
                                                    Color(0xFFC9B7FF),
                                                    Color(0xFF9EEBFF)
                                                  ],
                                                  begin: Alignment.topRight,
                                                  end: Alignment.bottomLeft,
                                                ),
                                                borderRadius:
                                                    BorderRadius.circular(999),
                                              ),
                                              child: Text(
                                                '+${_formatCompactCount(score)}',
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontWeight: FontWeight.w800,
                                                  fontSize: 12,
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 10),
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Text(
                                                    title,
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: TextStyle(
                                                      color: isLight
                                                          ? Colors.black
                                                          : Colors.white,
                                                      fontWeight:
                                                          FontWeight.w700,
                                                      fontSize: 13,
                                                    ),
                                                  ),
                                                  const SizedBox(height: 2),
                                                  Text(
                                                    subCategory.isNotEmpty
                                                        ? subCategory
                                                        : 'ללא תת קטגוריה',
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: TextStyle(
                                                      color: isLight
                                                          ? Colors.black87
                                                          : Colors.grey[400],
                                                      fontSize: 12,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                            const SizedBox(width: 10),
                                            _buildScoreSheetThumbnail(post),
                                          ],
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ],
                          ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Map<String, dynamic> _mergeProfileData({
    required Map<String, dynamic> privateData,
    required Map<String, dynamic> publicData,
  }) {
    final merged = <String, dynamic>{...privateData, ...publicData};
    merged['firstName'] = _stringValue(
      <String, dynamic>{...publicData, ...privateData},
      const ['firstName'],
    );
    merged['lastName'] = _stringValue(
      <String, dynamic>{...publicData, ...privateData},
      const ['lastName'],
    );
    merged['username'] = _stringValue(
      <String, dynamic>{...publicData, ...privateData},
      const ['username'],
    );
    merged['displayName'] = _stringValue(
      <String, dynamic>{...publicData, ...privateData},
      const ['displayName', 'fullName'],
    );
    merged['bio'] = _stringValue(
      <String, dynamic>{...publicData, ...privateData},
      const ['bio'],
    );
    merged['profilePictureUrl'] = _stringValue(
      <String, dynamic>{...publicData, ...privateData},
      const ['profilePictureUrl', 'profileImageUrl', 'avatarUrl'],
    );
    merged['profileImageUrls'] = _mergeProfileImageUrls(
      privateData: privateData,
      publicData: publicData,
      primaryUrl: merged['profilePictureUrl'] as String? ?? '',
    );

    final followersCount = _intValue(
      publicData,
      const ['followersCount', 'followerCount'],
      fallback:
          _intValue(privateData, const ['followersCount', 'followerCount']),
    );
    final privateScore = _intValue(privateData, const ['score']);
    final publicScore = _intValue(publicData, const ['score']);
    final score = privateScore > publicScore ? privateScore : publicScore;
    merged['followersCount'] = followersCount;
    merged['followerCount'] = followersCount;
    merged['score'] = score;
    return merged;
  }

  List<String> _mergeProfileImageUrls({
    required Map<String, dynamic> privateData,
    required Map<String, dynamic> publicData,
    required String primaryUrl,
  }) {
    final urls = <String>[];
    final seen = <String>{};

    void addCandidate(String raw) {
      final url = raw.trim();
      if (url.isEmpty) return;
      if (!(url.startsWith('http://') || url.startsWith('https://'))) {
        return;
      }
      if (!seen.add(url)) return;
      urls.add(url);
      if (urls.length >= 6) return;
    }

    addCandidate(primaryUrl);

    void addFromList(dynamic rawList) {
      if (rawList is! List) return;
      for (final item in rawList) {
        addCandidate(item.toString());
        if (urls.length >= 6) return;
      }
    }

    addFromList(privateData['profileImageUrls']);
    addFromList(publicData['profileImageUrls']);
    addFromList(privateData['images']);
    addFromList(publicData['images']);

    return urls;
  }

  Future<void> _openEditProfile(Map<String, dynamic> profileData) async {
    final currentImageUrl = _profileImageUrl(profileData);
    final currentImageUrls = _profileImageUrls(profileData);
    await Navigator.of(context).push(
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) =>
            EditProfileScreen(
          currentName: _displayName(profileData),
          currentHandle: _username(profileData),
          currentBio: _bio(profileData),
          currentAllowGroupInvite:
              (profileData['allowGroupInvite'] as bool?) ?? true,
          currentImageUrl: currentImageUrl,
          currentImageUrls: currentImageUrls,
        ),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(opacity: animation, child: child);
        },
      ),
    );
  }

  void _shareProfile(String username) {
    final normalized =
        username.startsWith('@') ? username.substring(1) : username;
    SharePlus.instance.share(
      ShareParams(
          text:
              'Check out my profile on Hundred: https://hundred.app/$normalized'),
    );
  }

  Widget _buildSystemUpdatesButton(BuildContext context, int unreadCount) {
    final hasUnread = unreadCount > 0;
    final displayCount = unreadCount > 9 ? '9+' : unreadCount.toString();
    final isLight = Theme.of(context).brightness == Brightness.light;
    const lightIconColor = Color(0xFF9AB0FF);

    return Padding(
      padding: const EdgeInsetsDirectional.only(end: 12),
      child: GestureDetector(
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => const NotificationsPreviewScreen(),
            ),
          );
        },
        child: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            gradient: isLight
                ? null
                : hasUnread
                    ? const LinearGradient(
                        colors: [Color(0xFF9E7CFF), Color(0xFF53C1F9)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      )
                    : const LinearGradient(
                        colors: [Color(0xFF182336), Color(0xFF111B2B)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
            color: isLight ? Colors.white : null,
            boxShadow: [
              BoxShadow(
                color: (isLight
                        ? const Color(0xFF53C1F9)
                        : hasUnread
                            ? const Color(0xFF53C1F9)
                            : Colors.black)
                    .withValues(
                        alpha: isLight ? 0.12 : (hasUnread ? 0.26 : 0.18)),
                blurRadius: isLight ? 10 : (hasUnread ? 18 : 12),
                offset: const Offset(0, 6),
              ),
              if (isLight)
                BoxShadow(
                  color: const Color(0xFFB79BFF).withValues(alpha: 0.09),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
            ],
            border: Border.all(
              color: isLight
                  ? const Color(0xFFA7BFFF)
                  : hasUnread
                      ? Colors.white.withValues(alpha: 0.22)
                      : const Color(0xFF53C1F9).withValues(alpha: 0.14),
              width: 0.9,
            ),
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Center(
                child: Icon(
                  Icons.notifications_rounded,
                  color: isLight
                      ? lightIconColor
                      : (hasUnread ? Colors.white : const Color(0xFF8EDEFF)),
                  size: 22,
                ),
              ),
              if (hasUnread)
                Positioned(
                  top: -3,
                  left: -3,
                  child: Container(
                    constraints:
                        const BoxConstraints(minWidth: 22, minHeight: 22),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFF5C8A),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: Colors.white, width: 1.1),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      displayCount,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        height: 1,
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

  List<String> _uidListFromData(Map<String, dynamic> data, String key) {
    final raw = data[key];
    if (raw is! List) return const <String>[];

    final seen = <String>{};
    final result = <String>[];
    for (final item in raw) {
      final uid = item.toString().trim();
      if (uid.isEmpty || seen.contains(uid)) continue;
      seen.add(uid);
      result.add(uid);
    }
    return result;
  }

  Future<List<_ProfileRelationUser>> _relationUsersForIds(
      List<String> ids) async {
    if (ids.isEmpty) return const <_ProfileRelationUser>[];

    final users = <_ProfileRelationUser>[];
    for (final uid in ids) {
      final trimmedUid = uid.trim();
      if (trimmedUid.isEmpty) continue;

      final profile = await _publicUserProfileService.fetchProfile(trimmedUid);
      final name = (profile?.displayName ?? '').trim().isNotEmpty
          ? profile!.displayName
          : ((profile?.username ?? '').trim().isNotEmpty
              ? profile!.username
              : trimmedUid);
      final handle = profile != null
          ? profile.handle
          : '@${trimmedUid.substring(0, trimmedUid.length > 6 ? 6 : trimmedUid.length)}';
      final avatar = (profile?.profilePictureUrl ?? '').trim();

      users.add(
        _ProfileRelationUser(
          uid: trimmedUid,
          name: name,
          handle: handle,
          avatarUrl: avatar,
        ),
      );
    }

    return users;
  }

  Future<void> _showRelationSheet({
    required String title,
    required List<String> userIds,
    required String emptyMessage,
  }) async {
    if (!mounted) return;

    String query = '';
    final isLight = Theme.of(context).brightness == Brightness.light;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return Directionality(
          textDirection: TextDirection.rtl,
          child: SafeArea(
            child: Container(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(sheetContext).size.height * 0.78,
              ),
              margin: const EdgeInsets.fromLTRB(14, 8, 14, 16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(26),
                gradient: isLight
                    ? null
                    : const LinearGradient(
                        colors: [Color(0xFF53C1F9), Color(0xFF9E7CFF)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                color: isLight ? Colors.white : null,
              ),
              padding: const EdgeInsets.all(1.6),
              child: Container(
                decoration: BoxDecoration(
                  color: isLight ? Colors.white : const Color(0xFF101826),
                  borderRadius: BorderRadius.circular(24),
                ),
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
                child: FutureBuilder<List<_ProfileRelationUser>>(
                  future: _relationUsersForIds(userIds),
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: CircularProgressIndicator(),
                        ),
                      );
                    }

                    final users =
                        snapshot.data ?? const <_ProfileRelationUser>[];
                    if (users.isEmpty) {
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            emptyMessage,
                            style: TextStyle(
                              color: isLight ? Colors.black87 : Colors.white70,
                            ),
                          ),
                        ),
                      );
                    }

                    final removedUserIds = <String>{};

                    return StatefulBuilder(
                      builder: (context, setSheetState) {
                        final normalizedQuery = query.trim().toLowerCase();
                        final filtered = users.where((user) {
                          if (removedUserIds.contains(user.uid)) {
                            return false;
                          }
                          if (normalizedQuery.isEmpty) return true;
                          return user.name
                                  .toLowerCase()
                                  .contains(normalizedQuery) ||
                              user.handle
                                  .toLowerCase()
                                  .contains(normalizedQuery);
                        }).toList(growable: false);

                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              title,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: isLight ? Colors.black : Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 10),
                            TextField(
                              onTapOutside: (_) {},
                              onChanged: (value) => setSheetState(() {
                                query = value;
                              }),
                              style: TextStyle(
                                color: isLight ? Colors.black : Colors.white,
                              ),
                              textDirection: TextDirection.rtl,
                              decoration: InputDecoration(
                                hintText: 'חפש משתמש',
                                hintStyle: TextStyle(
                                  color:
                                      isLight ? Colors.black54 : Colors.white54,
                                ),
                                prefixIcon: Icon(
                                  Icons.search_rounded,
                                  color: isLight
                                      ? const Color(0xFF9AB0FF)
                                      : Colors.white54,
                                ),
                                filled: true,
                                fillColor: isLight
                                    ? Colors.white.withValues(alpha: 0.62)
                                    : const Color(0xFF1A2435),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide(
                                    color: isLight
                                        ? const Color(0xFFA9C3FF)
                                        : const Color(0xFF53C1F9)
                                            .withValues(alpha: 0.22),
                                  ),
                                ),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide(
                                    color: isLight
                                        ? const Color(0xFFA9C3FF)
                                        : const Color(0xFF53C1F9)
                                            .withValues(alpha: 0.22),
                                  ),
                                ),
                                focusedBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide(
                                    color: isLight
                                        ? const Color(0xFFB79BFF)
                                        : const Color(0xFF9E7CFF),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            Expanded(
                              child: filtered.isEmpty
                                  ? Center(
                                      child: Text(
                                        'לא נמצאו משתמשים',
                                        style: TextStyle(
                                          color: isLight
                                              ? Colors.black87
                                              : Colors.white70,
                                        ),
                                      ),
                                    )
                                  : ListView.builder(
                                      itemCount: filtered.length,
                                      itemBuilder: (context, index) {
                                        final user = filtered[index];
                                        return InkWell(
                                          borderRadius:
                                              BorderRadius.circular(14),
                                          onTap: () {
                                            Navigator.of(sheetContext).pop();
                                            Navigator.of(context).push(
                                              MaterialPageRoute(
                                                builder: (_) =>
                                                    UserProfileScreen(
                                                  uid: user.uid,
                                                  currentBottomIndex: 4,
                                                ),
                                              ),
                                            );
                                          },
                                          child: Container(
                                            margin: const EdgeInsets.only(
                                                bottom: 10),
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 10, vertical: 10),
                                            decoration: BoxDecoration(
                                              color: isLight
                                                  ? Colors.white
                                                      .withValues(alpha: 0.62)
                                                  : const Color(0xFF1A2435),
                                              borderRadius:
                                                  BorderRadius.circular(14),
                                              border: Border.all(
                                                color: isLight
                                                    ? const Color(0xFFA9C3FF)
                                                    : const Color(0xFF53C1F9)
                                                        .withValues(
                                                            alpha: 0.22),
                                              ),
                                            ),
                                            child: Row(
                                              children: [
                                                CircleAvatar(
                                                  radius: 20,
                                                  backgroundColor:
                                                      const Color(0xFF9E7CFF),
                                                  backgroundImage:
                                                      user.avatarUrl.isNotEmpty
                                                          ? NetworkImage(
                                                              user.avatarUrl)
                                                          : null,
                                                  child: user.avatarUrl.isEmpty
                                                      ? Text(
                                                          user.name.isNotEmpty
                                                              ? user
                                                                  .name
                                                                  .characters
                                                                  .first
                                                              : '?',
                                                          style:
                                                              const TextStyle(
                                                            color: Colors.white,
                                                            fontWeight:
                                                                FontWeight.bold,
                                                          ),
                                                        )
                                                      : null,
                                                ),
                                                const SizedBox(width: 10),
                                                Expanded(
                                                  child: Column(
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment
                                                            .start,
                                                    children: [
                                                      Text(
                                                        user.name,
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
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
                                                        user.handle,
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                        style: TextStyle(
                                                          color: isLight
                                                              ? Colors.black87
                                                              : Colors
                                                                  .grey[400],
                                                          fontSize: 12,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                                const SizedBox(width: 8),
                                                if (title == 'עוקבים')
                                                  OutlinedButton(
                                                    onPressed: () async {
                                                      final shouldRemove =
                                                          await _confirmRelationAction(
                                                        title: 'הסרת עוקב',
                                                        message:
                                                            'להסיר את המשתמש הזה מרשימת העוקבים?',
                                                      );
                                                      if (!shouldRemove) {
                                                        return;
                                                      }
                                                      await _socialService
                                                          .removeFollower(
                                                              user.uid);
                                                      if (!mounted) {
                                                        return;
                                                      }
                                                      setSheetState(() {
                                                        removedUserIds
                                                            .add(user.uid);
                                                      });
                                                    },
                                                    child: const Text('הסר'),
                                                  )
                                                else if (title == 'נעקבים')
                                                  OutlinedButton(
                                                    onPressed: () async {
                                                      final shouldUnfollow =
                                                          await _confirmRelationAction(
                                                        title: 'ביטול מעקב',
                                                        message:
                                                            'להפסיק לעקוב אחרי המשתמש הזה?',
                                                      );
                                                      if (!shouldUnfollow) {
                                                        return;
                                                      }
                                                      await _socialService
                                                          .unfollowUser(
                                                              user.uid);
                                                      if (!mounted) {
                                                        return;
                                                      }
                                                      setSheetState(() {
                                                        removedUserIds
                                                            .add(user.uid);
                                                      });
                                                    },
                                                    child:
                                                        const Text('בטל מעקב'),
                                                  ),
                                              ],
                                            ),
                                          ),
                                        );
                                      },
                                    ),
                            ),
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

  Widget _buildPrimaryProfileStatBubble({
    required String label,
    required String value,
    required IconData icon,
    required bool isLight,
    VoidCallback? onTap,
  }) {
    const lightIconColor = Color(0xFF9AB0FF);
    final bubble = Container(
      height: 108,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: isLight ? Colors.white : null,
        gradient: isLight
            ? null
            : LinearGradient(
                colors: [
                  const Color(0xFF1A2E45).withValues(alpha: 0.98),
                  const Color(0xFF30244A).withValues(alpha: 0.98),
                ],
                begin: Alignment.topRight,
                end: Alignment.bottomLeft,
              ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: isLight
              ? const Color(0xFFA7BFFF)
              : const Color(0xFF53C1F9).withValues(alpha: 0.42),
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF53C1F9)
                .withValues(alpha: isLight ? 0.08 : 0.12),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
          if (isLight)
            BoxShadow(
              color: const Color(0xFFB79BFF).withValues(alpha: 0.08),
              blurRadius: 14,
              offset: const Offset(0, 5),
            ),
        ],
      ),
      child: Stack(
        children: [
          Align(
            alignment: Alignment.topRight,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon,
                    color: isLight ? lightIconColor : const Color(0xFF9EDBFF),
                    size: 15),
                const SizedBox(width: 5),
                Text(
                  label,
                  style: TextStyle(
                    color: isLight ? Colors.black : Colors.grey[300],
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          Center(
            child: Text(
              value,
              style: TextStyle(
                color: isLight ? Colors.black : Colors.white,
                fontSize: 23,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );

    if (onTap == null) return bubble;
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: bubble,
    );
  }

  Widget _buildSocialRectTile({
    required String label,
    required int value,
    required IconData icon,
    required bool isLight,
    bool showLabel = true,
    VoidCallback? onTap,
  }) {
    const lightIconColor = Color(0xFF9AB0FF);
    final tile = Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: isLight ? Colors.white : const Color(0xFF162233),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(
          color: isLight
              ? const Color(0xFFA7BFFF)
              : const Color(0xFF53C1F9).withValues(alpha: 0.26),
        ),
        boxShadow: isLight
            ? [
                BoxShadow(
                  color: const Color(0xFF53C1F9).withValues(alpha: 0.08),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
                BoxShadow(
                  color: const Color(0xFFB79BFF).withValues(alpha: 0.07),
                  blurRadius: 12,
                  offset: const Offset(0, 5),
                ),
              ]
            : null,
      ),
      child: Row(
        children: [
          Expanded(
            child: Center(
              child: Text(
                _formatCompactCount(value),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: isLight ? Colors.black : Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showLabel) ...[
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      color: isLight ? Colors.black : Colors.grey[300],
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
              ],
              Icon(
                icon,
                color: isLight ? lightIconColor : const Color(0xFF9EDBFF),
                size: 13,
              ),
            ],
          ),
        ],
      ),
    );

    if (onTap == null) return tile;
    return InkWell(
      borderRadius: BorderRadius.circular(11),
      onTap: onTap,
      child: tile,
    );
  }

  Widget _buildPostFallback() {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF1A2230),
      ),
      child: const Center(
        child: Icon(Icons.image_not_supported_rounded,
            color: Colors.white38, size: 34),
      ),
    );
  }

  String _rawMediaField(Map<String, dynamic> data) {
    final thumbnailUrl = (data['thumbnailUrl'] as String? ?? '').trim();
    if (thumbnailUrl.isNotEmpty) return thumbnailUrl;

    final videoThumbnailUrl =
        (data['videoThumbnailUrl'] as String? ?? '').trim();
    if (videoThumbnailUrl.isNotEmpty) return videoThumbnailUrl;

    final rawMediaItems =
        (data['mediaItems'] as List<dynamic>? ?? const <dynamic>[]);
    for (final raw in rawMediaItems.whereType<Map>()) {
      final item = raw.map(
        (key, value) => MapEntry(key.toString(), value),
      );
      final thumbnail = (item['thumbnailUrl'] as String? ??
              item['videoThumbnailUrl'] as String? ??
              '')
          .trim();
      if (thumbnail.isNotEmpty) return thumbnail;
    }

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
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return null;
    }

    final rawMedia = _rawMediaField(data);
    final storagePathField = (data['storagePath'] as String? ?? '').trim();

    if (rawMedia.isNotEmpty) {
      if (rawMedia.startsWith('http://') || rawMedia.startsWith('https://')) {
        return rawMedia;
      }

      try {
        if (rawMedia.startsWith('gs://')) {
          final resolved = await FirebaseStorage.instance
              .refFromURL(rawMedia)
              .getDownloadURL();
          return resolved;
        }

        final resolved =
            await FirebaseStorage.instance.ref(rawMedia).getDownloadURL();
        return resolved;
      } catch (_) {
        // Fall through to storagePath fallback.
      }
    }

    if (storagePathField.isEmpty) {
      return null;
    }

    try {
      final resolved =
          await FirebaseStorage.instance.ref(storagePathField).getDownloadURL();
      return resolved;
    } catch (_) {
      return null;
    }
  }

  Future<String?> _mediaFutureForPost(Map<String, dynamic> data) {
    final postKey =
        (data['postId'] as String? ?? data['id'] as String? ?? '').trim();
    final thumbnailUrl = (data['thumbnailUrl'] as String? ?? '').trim();
    final videoThumbnailUrl =
        (data['videoThumbnailUrl'] as String? ?? '').trim();
    final mediaUrl = (data['mediaUrl'] as String? ?? '').trim();
    final imageUrl = (data['imageUrl'] as String? ?? '').trim();
    final mediaUrlsKey =
        ((data['mediaUrls'] as List<dynamic>?) ?? const []).join(',');
    final mediaItemsKey =
        ((data['mediaItems'] as List<dynamic>?) ?? const <dynamic>[]).join(',');
    final storagePath = (data['storagePath'] as String? ?? '').trim();
    final cacheKey = [
      postKey,
      thumbnailUrl,
      videoThumbnailUrl,
      mediaUrl,
      imageUrl,
      mediaUrlsKey,
      mediaItemsKey,
      storagePath,
    ].join('|');

    return _resolvedMediaFutureByPostKey.putIfAbsent(
      cacheKey,
      () => _resolveMediaUrl(data),
    );
  }

  Widget _buildPostMedia(Map<String, dynamic> data) {
    final mediaItems = postMediaItemsFromData(data);
    if (mediaItems.isEmpty) {
      return _buildPostFallback();
    }
    return IgnorePointer(
      child: PostMediaViewer(
        mediaItems: mediaItems,
        aspectRatio: null,
        showIndicators: false,
        isActive: false,
      ),
    );
  }

  Widget _buildPostCard(Map<String, dynamic> data) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final isCompactCard = MediaQuery.of(context).size.width < 390;
    final subCategory = (data['subCategory'] as String? ?? '').trim();
    final postTitle = (data['title'] as String? ?? '').trim();
    final subCategoryLabel =
        subCategory.isNotEmpty ? subCategory : 'ללא קטגוריה';
    final score = _postScore(data);
    final taggedScore = _taggedPointsForUserFromPost(data, _uid);
    final isTaggedCategoryView = _selectedCategoryKey == 'tagged';

    return Container(
      decoration: BoxDecoration(
        color: isLight ? Colors.white : const Color(0xFF171F2D),
        borderRadius: BorderRadius.circular(18),
        border: isLight
            ? null
            : Border.all(
                color: const Color(0xFF53C1F9).withValues(alpha: 0.12)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(child: _buildPostMedia(data)),
                  Positioned(
                    top: 10,
                    right: 10,
                    left: 10,
                    child: isCompactCard
                        ? Align(
                            alignment: Alignment.topRight,
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 128),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                textDirection: TextDirection.rtl,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 5,
                                    ),
                                    decoration: BoxDecoration(
                                      color: isLight
                                          ? const Color(0xFFF2F7FF)
                                          : const Color(0xFF153454),
                                      borderRadius: BorderRadius.circular(999),
                                      border: Border.all(
                                        color: isLight
                                            ? const Color(0xFFA9C3FF)
                                            : const Color(0xFF53C1F9),
                                      ),
                                    ),
                                    child: Text(
                                      subCategoryLabel,
                                      textAlign: TextAlign.right,
                                      textDirection: TextDirection.rtl,
                                      maxLines: 1,
                                      softWrap: false,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: isLight
                                            ? const Color(0xFF2F3F5E)
                                            : const Color(0xFFD8F1FF),
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.w700,
                                        height: 1.12,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  if (!isTaggedCategoryView)
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 5,
                                      ),
                                      decoration: BoxDecoration(
                                        color: isLight
                                            ? const Color(0xFFEAF1FF)
                                            : const Color(0xFF141925)
                                                .withValues(alpha: 0.92),
                                        borderRadius:
                                            BorderRadius.circular(999),
                                        border: Border.all(
                                          color: isLight
                                              ? const Color(0xFFA9C3FF)
                                              : const Color(0xFF53C1F9)
                                                  .withValues(alpha: 0.4),
                                        ),
                                      ),
                                      child: Text(
                                        '+${_formatCompactCount(score)}',
                                        style: TextStyle(
                                          color: isLight
                                              ? const Color(0xFF4E5ED6)
                                              : const Color(0xFFBFE7FF),
                                          fontWeight: FontWeight.w800,
                                          fontSize: 11,
                                        ),
                                      ),
                                    ),
                                  if (isTaggedCategoryView && taggedScore > 0)
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 5,
                                      ),
                                      decoration: BoxDecoration(
                                        color: isLight
                                            ? Colors.white
                                                .withValues(alpha: 0.92)
                                            : const Color(0xFF2A2248)
                                                .withValues(alpha: 0.94),
                                        borderRadius:
                                            BorderRadius.circular(999),
                                        border: Border.all(
                                          color: const Color(0xFF9E7CFF)
                                              .withValues(alpha: 0.55),
                                        ),
                                      ),
                                      child: Text(
                                        '+$taggedScore',
                                        style: TextStyle(
                                          color: isLight
                                              ? Colors.black
                                              : const Color(0xFFE6D9FF),
                                          fontWeight: FontWeight.w800,
                                          fontSize: 11,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          )
                        : Row(
                            textDirection: TextDirection.rtl,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Column(
                                mainAxisSize: MainAxisSize.min,
                                textDirection: TextDirection.rtl,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  ConstrainedBox(
                                    constraints:
                                        const BoxConstraints(maxWidth: 118),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 5,
                                      ),
                                      decoration: BoxDecoration(
                                        color: isLight
                                            ? const Color(0xFFF2F7FF)
                                            : const Color(0xFF153454),
                                        borderRadius:
                                            BorderRadius.circular(999),
                                        border: Border.all(
                                          color: isLight
                                              ? const Color(0xFFA9C3FF)
                                              : const Color(0xFF53C1F9),
                                        ),
                                      ),
                                      child: Text(
                                        subCategoryLabel,
                                        textAlign: TextAlign.right,
                                        textDirection: TextDirection.rtl,
                                        maxLines: 1,
                                        softWrap: false,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: isLight
                                              ? const Color(0xFF2F3F5E)
                                              : const Color(0xFFD8F1FF),
                                          fontSize: 10.5,
                                          fontWeight: FontWeight.w700,
                                          height: 1.12,
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  if (!isTaggedCategoryView)
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 9, vertical: 5),
                                      decoration: BoxDecoration(
                                        color: isLight
                                            ? const Color(0xFFEAF1FF)
                                            : const Color(0xFF141925)
                                                .withValues(alpha: 0.92),
                                        borderRadius:
                                            BorderRadius.circular(999),
                                        border: Border.all(
                                          color: isLight
                                              ? const Color(0xFFA9C3FF)
                                              : const Color(0xFF53C1F9)
                                                  .withValues(alpha: 0.4),
                                        ),
                                      ),
                                      child: Text(
                                        '+${_formatCompactCount(score)}',
                                        style: TextStyle(
                                          color: isLight
                                              ? const Color(0xFF4E5ED6)
                                              : const Color(0xFFBFE7FF),
                                          fontWeight: FontWeight.w800,
                                          fontSize: 11,
                                        ),
                                      ),
                                    ),
                                  if (isTaggedCategoryView &&
                                      taggedScore > 0) ...[
                                    const SizedBox(height: 6),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 5,
                                      ),
                                      decoration: BoxDecoration(
                                        color: isLight
                                            ? Colors.white
                                                .withValues(alpha: 0.92)
                                            : const Color(0xFF2A2248)
                                                .withValues(alpha: 0.94),
                                        borderRadius:
                                            BorderRadius.circular(999),
                                        border: Border.all(
                                          color: const Color(0xFF9E7CFF)
                                              .withValues(alpha: 0.55),
                                        ),
                                      ),
                                      child: Text(
                                        '+$taggedScore',
                                        style: TextStyle(
                                          color: isLight
                                              ? Colors.black
                                              : const Color(0xFFE6D9FF),
                                          fontWeight: FontWeight.w800,
                                          fontSize: 10,
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                              const Spacer(),
                              if (_postAudience(data) == 'friends')
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 5),
                                  decoration: BoxDecoration(
                                    gradient: const LinearGradient(
                                      colors: [
                                        Color(0xFFFFF7EF),
                                        Color(0xFFFFB36B)
                                      ],
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
                                      fontSize: 10,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                  ),
                  if (postTitle.isNotEmpty)
                    Positioned(
                      right: 10,
                      left: 10,
                      bottom: 10,
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 170),
                          child: Text(
                            postTitle,
                            textAlign: TextAlign.right,
                            textDirection: TextDirection.rtl,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12.8,
                              fontWeight: FontWeight.w800,
                              height: 1.15,
                              shadows: [
                                Shadow(
                                  color: Color(0xB3000000),
                                  blurRadius: 8,
                                  offset: Offset(0, 1),
                                ),
                              ],
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
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
    );
  }

  Widget _buildEventFolderCard(ProfilePostGridEntry entry) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final folderSubCategory = _eventFolderSubCategory(entry);
    final folderScore = _eventFolderScore(entry);

    return Container(
      decoration: BoxDecoration(
        color: isLight ? Colors.white : const Color(0xFF141D2C),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: isLight
              ? const Color(0xFFA9C3FF)
              : const Color(0xFF53C1F9).withValues(alpha: 0.18),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 24,
              child: Align(
                alignment: Alignment.centerRight,
                child: folderSubCategory.isEmpty
                    ? const SizedBox.shrink()
                    : Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color:
                              isLight ? Colors.white : const Color(0xFF153454),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: const Color(0xFF53C1F9),
                          ),
                        ),
                        child: Text(
                          folderSubCategory,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.right,
                          style: TextStyle(
                            color: isLight ? Colors.black : Colors.white,
                            fontSize: 10.8,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  color: isLight ? Colors.white : const Color(0xFF0F1522),
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: _buildEventFolderPreviewGrid(entry),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              textDirection: TextDirection.rtl,
              children: [
                Text(
                  '+${_formatCompactCount(folderScore)}',
                  style: TextStyle(
                    color: isLight
                        ? const Color(0xFF5A6CFF)
                        : const Color(0xFFBFE7FF),
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${entry.docs.length} פוסטים',
                    textAlign: TextAlign.left,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isLight ? Colors.black : Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _eventFolderSubCategory(ProfilePostGridEntry entry) {
    for (final doc in entry.docs) {
      final subCategory = (doc.data()['subCategory'] as String? ?? '').trim();
      if (subCategory.isNotEmpty) {
        return subCategory;
      }
    }
    return '';
  }

  int _eventFolderScore(ProfilePostGridEntry entry) {
    if (_selectedCategoryKey == 'tagged') {
      return entry.docs.fold<int>(
        0,
        (total, doc) => total + _taggedPointsForUserFromPost(doc.data(), _uid),
      );
    }

    return entry.docs.fold<int>(
      0,
      (total, doc) => total + _postScore(doc.data()),
    );
  }

  Widget _buildEventFolderPreviewGrid(ProfilePostGridEntry entry) {
    final previewDocs = entry.docs.toList(growable: false)
      ..sort((a, b) {
        final aCreated = _createdAtFrom(a.data());
        final bCreated = _createdAtFrom(b.data());
        final byDate = bCreated.compareTo(aCreated);
        if (byDate != 0) {
          return byDate;
        }
        return a.id.compareTo(b.id);
      });
    final visiblePreviewDocs = previewDocs.take(4).toList(growable: false);
    return GridView.builder(
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      itemCount: visiblePreviewDocs.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 6,
        mainAxisSpacing: 6,
      ),
      itemBuilder: (context, index) {
        final data = visiblePreviewDocs[index].data();
        return ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: _buildFolderPreviewTile(data),
        );
      },
    );
  }

  Widget _buildFolderPreviewTile(Map<String, dynamic> data) {
    final rawMedia = _rawMediaField(data);
    final isVideo = isVideoMediaUrl(rawMedia);

    return FutureBuilder<String?>(
      future: _resolveMediaUrl(data),
      builder: (context, snapshot) {
        final url = (snapshot.data ?? '').trim();
        if (url.isEmpty) {
          return Stack(
            fit: StackFit.expand,
            children: [
              Container(color: const Color(0xFF0F1522)),
              const Center(
                child: Icon(
                  Icons.image_not_supported_rounded,
                  color: Colors.white38,
                  size: 30,
                ),
              ),
            ],
          );
        }

        if (!isVideo) {
          return Image.network(
            url,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => Container(
              color: const Color(0xFF0F1522),
              child: const Center(
                child: Icon(
                  Icons.broken_image_outlined,
                  color: Colors.white38,
                  size: 30,
                ),
              ),
            ),
          );
        }

        final previewFuture = _videoPreviewFutureByUrl.putIfAbsent(
          url,
          () => buildVideoPreviewBytesFromSource(url),
        );

        return FutureBuilder<Uint8List?>(
          future: previewFuture,
          builder: (context, bytesSnapshot) {
            final bytes = bytesSnapshot.data;
            if (bytes != null && bytes.isNotEmpty) {
              return Image.memory(bytes, fit: BoxFit.cover);
            }

            return Stack(
              fit: StackFit.expand,
              children: [
                Container(color: const Color(0xFF0F1522)),
                const Center(
                  child: Icon(
                    Icons.play_circle_fill_rounded,
                    color: Colors.white,
                    size: 30,
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  List<Map<String, dynamic>> _entryPostsData(ProfilePostGridEntry entry) {
    return entry.docs.map((doc) {
      final post = Map<String, dynamic>.from(doc.data());
      post['id'] = doc.id;
      post['postId'] = (post['postId'] as String? ?? doc.id).trim();
      return post;
    }).toList(growable: false);
  }

  Future<List<Map<String, dynamic>>> _eventPostsDataForDialog(
    ProfilePostGridEntry entry,
  ) async {
    final fallback = _entryPostsData(entry);
    if (_selectedCategoryKey == 'tagged') {
      return fallback;
    }

    final eventGroupId = entry.eventGroupId.trim();
    if (eventGroupId.isEmpty) {
      return fallback;
    }

    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('posts')
          .where('eventGroupId', isEqualTo: eventGroupId)
          .orderBy('createdAt', descending: true)
          .get();

      if (snapshot.docs.isEmpty) {
        return fallback;
      }

      final eventPosts = <Map<String, dynamic>>[];
      for (final doc in snapshot.docs) {
        final data = doc.data();
        final status =
            (data['status'] as String? ?? 'published').trim().toLowerCase();
        if (status != 'published') {
          continue;
        }

        final post = Map<String, dynamic>.from(data);
        post['id'] = doc.id;
        post['postId'] = (post['postId'] as String? ?? doc.id).trim();
        eventPosts.add(post);
      }

      if (eventPosts.isEmpty) {
        return fallback;
      }

      final mergedById = <String, Map<String, dynamic>>{};
      for (final post in fallback) {
        final id =
            (post['id'] as String? ?? post['postId'] as String? ?? '').trim();
        if (id.isNotEmpty) {
          mergedById[id] = post;
        }
      }
      for (final post in eventPosts) {
        final id =
            (post['id'] as String? ?? post['postId'] as String? ?? '').trim();
        if (id.isNotEmpty) {
          mergedById[id] = post;
        }
      }

      return mergedById.values.toList(growable: false);
    } catch (_) {
      return fallback;
    }
  }

  Future<void> _openEventFolderDialog(ProfilePostGridEntry entry) async {
    final entryPostsData = await _eventPostsDataForDialog(entry);
    if (!mounted) {
      return;
    }
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.78),
      builder: (dialogContext) {
        final isLight = Theme.of(dialogContext).brightness == Brightness.light;
        final size = MediaQuery.of(dialogContext).size;

        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 20),
          child: Container(
            width: size.width,
            height: size.height * 0.84,
            decoration: BoxDecoration(
              color: isLight ? Colors.white : const Color(0xFF0F1725),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                color: isLight ? const Color(0xFFA9C3FF) : Colors.white24,
              ),
            ),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'פוסטים מהאירוע',
                          textAlign: TextAlign.right,
                          style: TextStyle(
                            color: isLight ? Colors.black : Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.of(dialogContext).pop(),
                        icon: const Icon(Icons.close_rounded),
                        color: isLight ? Colors.black : Colors.white,
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: GridView.builder(
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(14, 4, 14, 16),
                    itemCount: entryPostsData.length,
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 12,
                      mainAxisExtent: 230,
                    ),
                    itemBuilder: (context, index) {
                      final postData = entryPostsData[index];
                      return GestureDetector(
                        onTap: () {
                          Navigator.of(dialogContext).push(
                            MaterialPageRoute(
                              builder: (_) => PostDetailView(
                                posts: entryPostsData,
                                initialIndex: index,
                                enableEditAction: true,
                                useDraftPublishEditAction:
                                    _selectedCategoryKey == 'drafts',
                                disableOwnAuthorProfileTap: true,
                              ),
                            ),
                          );
                        },
                        child: _buildPostCard(postData),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  List<QueryDocumentSnapshot<Map<String, dynamic>>> _filteredPosts(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> allDocs,
  ) {
    final selected = _categoryItems.firstWhere(
      (item) => item.key == _selectedCategoryKey,
      orElse: () => _categoryItems[1],
    );

    return allDocs.where((doc) {
      final data = doc.data();
      final status = _postStatus(data);
      final category = _postCategory(data);
      final authorId = _postAuthorId(data);
      final isMine = authorId == _uid;

      if (selected.key == 'drafts') {
        return isMine && status == 'draft';
      }

      if (selected.key == 'general') {
        return isMine && status == 'published';
      }

      if (selected.key == 'tagged') {
        return _isTaggedPostForUser(data, _uid);
      }

      if (selected.firestoreCategory == null) {
        return false;
      }

      return isMine &&
          status == 'published' &&
          category == selected.firestoreCategory;
    }).toList(growable: false);
  }

  Widget _buildCategorySidebarItem(_ProfileCategoryNavItem item,
      {required bool isSelected, required bool isLight}) {
    final isCompact = MediaQuery.of(context).size.width < 390;
    final baseColor = isLight
        ? (isSelected ? const Color(0xFFE8EEFF) : Colors.white)
        : (isSelected ? const Color(0xFF9E7CFF) : const Color(0xFF1E2632));
    final borderColor = isLight
        ? const Color(0xFFA7BFFF)
        : (isSelected ? const Color(0xFF53C1F9) : Colors.white10);
    final iconColor = isLight
        ? const Color(0xFF9AB0FF)
        : (isSelected ? Colors.white : Colors.grey[300]!);

    return Tooltip(
      message: item.label,
      child: GestureDetector(
        onTap: () {
          if (_selectedCategoryKey == item.key) return;

          final double sidebarOffsetBeforeSelection =
              _sidebarScrollController.hasClients
                  ? _sidebarScrollController.offset
                  : 0;

          setState(() {
            _selectedCategoryKey = item.key;
          });

          if (_sidebarScrollController.hasClients) {
            final maxOffset = _sidebarScrollController.position.maxScrollExtent;
            final targetOffset =
                sidebarOffsetBeforeSelection.clamp(0.0, maxOffset);
            if ((_sidebarScrollController.offset - targetOffset).abs() > 0.5) {
              _sidebarScrollController.jumpTo(targetOffset);
            }
          }
        },
        child: Container(
          margin: EdgeInsets.symmetric(
            horizontal: isCompact ? 4 : 6,
            vertical: isCompact ? 5 : 6,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: isSelected
                ? const LinearGradient(
                    colors: [
                      Color(0xFF9DEBFF),
                      Color(0xFFC7B2FF),
                      Color(0xFF84E1FF),
                    ],
                    begin: Alignment.topRight,
                    end: Alignment.bottomLeft,
                  )
                : null,
            border: isSelected ? null : Border.all(color: borderColor),
            boxShadow: isSelected
                ? [
                    BoxShadow(
                      color: const Color(0xFF7FE4FF).withValues(alpha: 0.24),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                    BoxShadow(
                      color: const Color(0xFFA993FF).withValues(alpha: 0.2),
                      blurRadius: 12,
                      offset: const Offset(0, 5),
                    ),
                  ]
                : null,
          ),
          padding: isSelected ? const EdgeInsets.all(1.15) : EdgeInsets.zero,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            padding: EdgeInsets.symmetric(
              horizontal: isCompact ? 3 : 5,
              vertical: isCompact ? 6 : 8,
            ),
            decoration: BoxDecoration(
              color: baseColor,
              borderRadius: BorderRadius.circular(isSelected ? 14.85 : 16),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(item.icon, color: iconColor, size: isCompact ? 19 : 21),
                SizedBox(height: isCompact ? 3 : 4),
                SizedBox(
                  width: double.infinity,
                  child: Text(
                    item.label,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    softWrap: true,
                    overflow: TextOverflow.clip,
                    style: TextStyle(
                      color: isLight
                          ? Colors.black
                          : (isSelected ? Colors.white : Colors.grey[400]),
                      fontSize: isCompact ? 9 : 10,
                      fontWeight:
                          isSelected ? FontWeight.w700 : FontWeight.w500,
                      height: 1.1,
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

  Widget _buildSidebarWithLock(
      {required double viewportHeight, required bool isLight}) {
    final isCompact = MediaQuery.of(context).size.width < 390;
    return Container(
      margin:
          EdgeInsets.fromLTRB(isCompact ? 10 : 16, 0, isCompact ? 4 : 8, 16),
      decoration: BoxDecoration(
        color: isLight ? Colors.white : const Color(0xFF151D2A),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isLight ? const Color(0xFFA7BFFF) : Colors.white10,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: ListView.builder(
          controller: null,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: _categoryItems.length,
          padding: EdgeInsets.fromLTRB(
              0, isCompact ? 8 : 10, 0, isCompact ? 12 : 16),
          itemExtent: isCompact ? 86 : 94,
          itemBuilder: (context, index) {
            final item = _categoryItems[index];
            return _buildCategorySidebarItem(
              item,
              isSelected: item.key == _selectedCategoryKey,
              isLight: isLight,
            );
          },
        ),
      ),
    );
  }

  Widget _buildPostsGrid(
      List<QueryDocumentSnapshot<Map<String, dynamic>>> docs) {
    if (docs.isEmpty) {
      final isDraftFilter = _selectedCategoryKey == 'drafts';
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Text(
            isDraftFilter
                ? 'אין טיוטות שמורות להצגה'
                : 'אין פוסטים להצגה בקטגוריה הזו',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey[400], fontSize: 14),
          ),
        ),
      );
    }

    final entries = groupProfilePostsByEvent(
      docs,
      enableFolders: _selectedCategoryKey != 'drafts',
      minPostsPerFolder: _selectedCategoryKey == 'tagged' ? 2 : 1,
    );
    final visiblePostsData = docs.map((doc) {
      final post = Map<String, dynamic>.from(doc.data());
      post['id'] = doc.id;
      post['postId'] = (post['postId'] as String? ?? doc.id).trim();
      return post;
    }).toList(growable: false);
    final visiblePostIndexById = <String, int>{
      for (var index = 0; index < visiblePostsData.length; index++)
        (visiblePostsData[index]['id'] as String? ??
                visiblePostsData[index]['postId'] as String? ??
                '')
            .trim(): index,
    };

    final isWideLayout = MediaQuery.of(context).size.width >= 700;

    return GridView.builder(
      primary: true,
      physics: const ClampingScrollPhysics(),
      padding: EdgeInsets.fromLTRB(
        isWideLayout ? 10 : 6,
        0,
        isWideLayout ? 10 : 2,
        24,
      ),
      itemCount: entries.length,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: isWideLayout ? 3 : 2,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
        childAspectRatio: 3 / 4,
      ),
      itemBuilder: (context, index) {
        try {
          final entry = entries[index];
          final entryPostId = (entry.primaryDoc.data()['postId'] as String? ??
                  entry.primaryDoc.id)
              .trim();
          final detailIndex = visiblePostIndexById[entryPostId] ?? 0;

          return GestureDetector(
            onTap: () {
              if (entry.isFolder) {
                _openEventFolderDialog(entry);
                return;
              }

              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => PostDetailView(
                    posts: visiblePostsData,
                    initialIndex: detailIndex,
                    enableEditAction: true,
                    useDraftPublishEditAction: _selectedCategoryKey == 'drafts',
                    disableOwnAuthorProfileTap: true,
                  ),
                ),
              );
            },
            child: entry.isFolder
                ? _buildEventFolderCard(entry)
                : _buildPostCard(entry.primaryDoc.data()),
          );
        } catch (e, stackTrace) {
          debugPrint('Error building profile post card: $e');
          debugPrintStack(stackTrace: stackTrace);
          return _buildPostCard(<String, dynamic>{});
        }
      },
    );
  }

  Widget _buildHeader(
      Map<String, dynamic> profileData,
      int publishedCount,
      int postedSubCategoryCount,
      List<QueryDocumentSnapshot<Map<String, dynamic>>> allDocs,
      {required bool isLight,
      required int unreadCount}) {
    final displayName = _displayName(profileData);
    final username = _username(profileData);
    final bio = _bio(profileData);
    final profileImageUrl = _profileImageUrl(profileData);
    final profileImageUrls = _profileImageUrls(profileData);
    final storedScore = _intValue(profileData, const ['score']);
    final livePublishedScore = allDocs
        .where((doc) =>
            _postAuthorId(doc.data()) == _uid &&
            _postStatus(doc.data()) == 'published')
        .fold<int>(0, (total, doc) => total + _postScore(doc.data()));
    final score =
        livePublishedScore > storedScore ? livePublishedScore : storedScore;
    final followers = _uidListFromData(profileData, 'followers').toSet();
    final following = _uidListFromData(profileData, 'following').toSet();
    final isPrivateProfile = (profileData['isPrivate'] as bool?) ?? false;
    final friends = followers.intersection(following).toList(growable: false);
    final followersCount = followers.isNotEmpty
        ? followers.length
        : _intValue(profileData, const ['followerCount', 'followersCount']);
    final followingCount = following.isNotEmpty
        ? following.length
        : _intValue(profileData, const ['followingCount']);
    final friendsCount = friends.length;
    const lightIconColor = Color(0xFF9AB0FF);
    const borderColor = Color(0xFFA7BFFF);
    final clampedPostedSubCategoryCount =
        postedSubCategoryCount.clamp(0, _subCategoryGoal);
    final screenWidth = MediaQuery.of(context).size.width;
    final isWideLayout = screenWidth >= 700;
    final avatarSize = isWideLayout ? 148.0 : 116.0;
    final avatarStackHeight = isWideLayout ? 184.0 : 126.0;
    final badgeRightInset = (screenWidth * 0.055).clamp(12.0, 22.0);
    final leftThirdBadgeWidth = (screenWidth * 0.28).clamp(170.0, 240.0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 150,
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFFE899DC), Color(0xFF53C1F9)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.only(
              bottomLeft: Radius.circular(40),
              bottomRight: Radius.circular(40),
            ),
          ),
          child: SafeArea(
            bottom: false,
            child: Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: const EdgeInsets.only(top: 8, left: 10),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildSystemUpdatesButton(context, unreadCount),
                    if (isPrivateProfile) ...[
                      const SizedBox(width: 8),
                      _buildFollowRequestsButton(context),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
        Transform.translate(
          offset: const Offset(0, -58),
          child: Column(
            children: [
              SizedBox(
                width: double.infinity,
                height: avatarStackHeight,
                child: Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.topCenter,
                  children: [
                    GestureDetector(
                      onTap: profileImageUrls.isEmpty
                          ? null
                          : () {
                              showProfileImagesViewerDialog(
                                context,
                                imageUrls: profileImageUrls,
                              );
                            },
                      child: Container(
                        width: avatarSize,
                        height: avatarSize,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: Colors.black.withValues(alpha: 0.7),
                            width: 2.4,
                          ),
                        ),
                        child: ClipOval(
                          child: profileImageUrl.isNotEmpty
                              ? Image.network(
                                  profileImageUrl,
                                  fit: BoxFit.cover,
                                  errorBuilder: (context, error, stackTrace) {
                                    return Container(
                                      color: isLight
                                          ? const Color(0xFFF1F4FA)
                                          : const Color(0xFF1E2632),
                                      child: Center(
                                        child: Icon(
                                            Icons.person_outline_rounded,
                                            size: 54,
                                            color: isLight
                                                ? lightIconColor
                                                : Colors.white),
                                      ),
                                    );
                                  },
                                )
                              : Container(
                                  color: isLight
                                      ? const Color(0xFFF1F4FA)
                                      : const Color(0xFF1E2632),
                                  child: Center(
                                    child: Icon(Icons.person_outline_rounded,
                                        size: 54,
                                        color: isLight
                                            ? lightIconColor
                                            : Colors.white),
                                  ),
                                ),
                        ),
                      ),
                    ),
                    if (_activeSpontaneousTask != null)
                      _buildProfileSpontaneousTaskBubbles(
                        badgeRightInset: badgeRightInset,
                        isWideLayout: isWideLayout,
                        screenWidth: screenWidth,
                      ),
                    if (isWideLayout)
                      Positioned(
                        top: 86,
                        left: (screenWidth * 0.04).clamp(16.0, 48.0),
                        child: SizedBox(
                          width: leftThirdBadgeWidth,
                          child: GestureDetector(
                            onTap: () => _openTaskProgressCategoriesDialog(
                              allDocs: allDocs,
                            ),
                            child: _buildSubCategoryProgressBadge(
                              count: clampedPostedSubCategoryCount,
                              isLight: isLight,
                              isWideLayout: true,
                            ),
                          ),
                        ),
                      )
                    else
                      Positioned(
                        top: 92,
                        left: badgeRightInset,
                        child: SizedBox(
                          width: 112,
                          child: GestureDetector(
                            onTap: () => _openTaskProgressCategoriesDialog(
                              allDocs: allDocs,
                            ),
                            child: _buildSubCategoryProgressBadge(
                              count: clampedPostedSubCategoryCount,
                              isLight: isLight,
                              isWideLayout: false,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 34),
              Text(
                displayName,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: isLight ? Colors.black : Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                username,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: isLight ? Colors.black87 : Colors.grey[400],
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  bio,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: isLight ? Colors.black87 : Colors.grey[400],
                      fontSize: 14,
                      height: 1.4),
                ),
              ),
              const SizedBox(height: 14),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Directionality(
                  textDirection: TextDirection.ltr,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        flex: 5,
                        child: _buildPrimaryProfileStatBubble(
                          label: 'פוסטים',
                          value: _formatCompactCount(publishedCount),
                          icon: Icons.grid_view_rounded,
                          isLight: isLight,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        flex: 5,
                        child: _buildPrimaryProfileStatBubble(
                          label: 'ניקוד',
                          value: _formatCompactCount(score),
                          icon: Icons.stars_rounded,
                          isLight: isLight,
                          onTap: () => _showScorePostsSheet(allDocs),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        flex: 4,
                        child: Column(
                          children: [
                            _buildSocialRectTile(
                              label: 'עוקבים',
                              value: followersCount,
                              icon: Icons.people_alt_rounded,
                              isLight: isLight,
                              showLabel: false,
                              onTap: () => _showRelationSheet(
                                title: 'עוקבים',
                                userIds: followers.toList(growable: false),
                                emptyMessage: 'אין עוקבים להצגה כרגע',
                              ),
                            ),
                            const SizedBox(height: 4),
                            _buildSocialRectTile(
                              label: 'נעקבים',
                              value: followingCount,
                              icon: Icons.person_add_alt_1_rounded,
                              isLight: isLight,
                              showLabel: false,
                              onTap: () => _showRelationSheet(
                                title: 'נעקבים',
                                userIds: following.toList(growable: false),
                                emptyMessage: 'אין נעקבים להצגה כרגע',
                              ),
                            ),
                            const SizedBox(height: 4),
                            _buildSocialRectTile(
                              label: 'חברים',
                              value: friendsCount,
                              icon: Icons.handshake_rounded,
                              isLight: isLight,
                              showLabel: false,
                              onTap: () => _showRelationSheet(
                                title: 'חברים',
                                userIds: friends,
                                emptyMessage: 'אין חברים להצגה כרגע',
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: () => _openEditProfile(profileData),
                        icon: Icon(
                          Icons.edit_rounded,
                          size: 18,
                          color: isLight ? Colors.black : Colors.white,
                        ),
                        label: Text('ערוך פרופיל',
                            style: TextStyle(
                                color: isLight ? Colors.black : Colors.white)),
                        style: ElevatedButton.styleFrom(
                          elevation: isLight ? 2 : 0,
                          shadowColor: isLight
                              ? const Color(0xFFB79BFF).withValues(alpha: 0.22)
                              : Colors.transparent,
                          backgroundColor:
                              isLight ? Colors.white : const Color(0xFF1B2D45),
                          foregroundColor:
                              isLight ? Colors.black : Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16)),
                        ).copyWith(
                          side: WidgetStatePropertyAll(
                            BorderSide(
                              color: isLight
                                  ? borderColor
                                  : const Color(0xFF53C1F9)
                                      .withValues(alpha: 0.34),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Container(
                      height: 50,
                      width: 50,
                      decoration: BoxDecoration(
                        gradient: isLight
                            ? null
                            : const LinearGradient(
                                colors: [Color(0xFF1A2E45), Color(0xFF2A2246)],
                                begin: Alignment.topRight,
                                end: Alignment.bottomLeft,
                              ),
                        color: isLight ? Colors.white : null,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: isLight
                              ? borderColor
                              : const Color(0xFF53C1F9).withValues(alpha: 0.3),
                        ),
                        boxShadow: isLight
                            ? [
                                BoxShadow(
                                  color: const Color(0xFF53C1F9)
                                      .withValues(alpha: 0.09),
                                  blurRadius: 10,
                                  offset: const Offset(0, 4),
                                ),
                                BoxShadow(
                                  color: const Color(0xFFB79BFF)
                                      .withValues(alpha: 0.08),
                                  blurRadius: 12,
                                  offset: const Offset(0, 5),
                                ),
                              ]
                            : null,
                      ),
                      child: IconButton(
                        icon: Icon(Icons.share_rounded,
                            color: isLight ? lightIconColor : Colors.white,
                            size: 20),
                        onPressed: () => _shareProfile(username),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Container(
                      height: 50,
                      width: 50,
                      decoration: BoxDecoration(
                        gradient: isLight
                            ? null
                            : const LinearGradient(
                                colors: [Color(0xFF1A2E45), Color(0xFF2A2246)],
                                begin: Alignment.topRight,
                                end: Alignment.bottomLeft,
                              ),
                        color: isLight ? Colors.white : null,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: isLight
                              ? borderColor
                              : const Color(0xFF53C1F9).withValues(alpha: 0.3),
                        ),
                        boxShadow: isLight
                            ? [
                                BoxShadow(
                                  color: const Color(0xFF53C1F9)
                                      .withValues(alpha: 0.09),
                                  blurRadius: 10,
                                  offset: const Offset(0, 4),
                                ),
                                BoxShadow(
                                  color: const Color(0xFFB79BFF)
                                      .withValues(alpha: 0.08),
                                  blurRadius: 12,
                                  offset: const Offset(0, 5),
                                ),
                              ]
                            : null,
                      ),
                      child: IconButton(
                        icon: Icon(Icons.settings_rounded,
                            color: isLight ? lightIconColor : Colors.white,
                            size: 20),
                        onPressed: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => const SettingsScreen())),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Container(
                      height: 50,
                      width: 50,
                      decoration: BoxDecoration(
                        gradient: isLight
                            ? null
                            : const LinearGradient(
                                colors: [Color(0xFF1A2E45), Color(0xFF2A2246)],
                                begin: Alignment.topRight,
                                end: Alignment.bottomLeft,
                              ),
                        color: isLight ? Colors.white : null,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: isLight
                              ? borderColor
                              : const Color(0xFF53C1F9).withValues(alpha: 0.3),
                        ),
                        boxShadow: isLight
                            ? [
                                BoxShadow(
                                  color: const Color(0xFF53C1F9)
                                      .withValues(alpha: 0.09),
                                  blurRadius: 10,
                                  offset: const Offset(0, 4),
                                ),
                                BoxShadow(
                                  color: const Color(0xFFB79BFF)
                                      .withValues(alpha: 0.08),
                                  blurRadius: 12,
                                  offset: const Offset(0, 5),
                                ),
                              ]
                            : null,
                      ),
                      child: IconButton(
                        icon: Icon(Icons.bookmark_rounded,
                            color: isLight ? lightIconColor : Colors.white,
                            size: 20),
                        onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const SavedPostsScreen(),
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
      ],
    );
  }

  Widget _buildProfileSpontaneousTaskBubbles({
    required double badgeRightInset,
    required bool isWideLayout,
    required double screenWidth,
  }) {
    final task = _activeSpontaneousTask;
    if (task == null) {
      return const SizedBox.shrink();
    }

    final rightInset = isWideLayout
        ? (screenWidth * 0.04).clamp(16.0, 48.0)
        : (badgeRightInset - 14).clamp(0.0, 80.0);
    final bubbleWidth = isWideLayout
        ? (screenWidth * 0.28).clamp(170.0, 240.0)
        : 118.0;
    final verticalOffset = isWideLayout ? 86.0 : 92.0;
    final timerGap = isWideLayout ? 10.0 : 10.0;
    return Positioned(
      top: verticalOffset,
      right: rightInset,
      child: SizedBox(
        width: bubbleWidth,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Directionality(
              textDirection: TextDirection.rtl,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: _openActiveSpontaneousTaskModal,
                  borderRadius: BorderRadius.circular(16),
                  child: Container(
                    width: bubbleWidth,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 7, vertical: 6),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      gradient: const LinearGradient(
                        colors: [
                          Color(0xFF46E1FF),
                          Color(0xFF6797FF),
                          Color(0xFF9D5FFF)
                        ],
                        begin: Alignment.topRight,
                        end: Alignment.bottomLeft,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color:
                              const Color(0xFF7D72FF).withValues(alpha: 0.32),
                          blurRadius: 14,
                          offset: const Offset(0, 7),
                        ),
                      ],
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.65),
                        width: 1.1,
                      ),
                    ),
                    child: Text(
                      task.subCategory,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10.4,
                        fontWeight: FontWeight.w900,
                        height: 1.15,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            SizedBox(height: timerGap),
            Directionality(
              textDirection: TextDirection.rtl,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: _openActiveSpontaneousTaskModal,
                  borderRadius: BorderRadius.circular(16),
                  child: Container(
                    width: bubbleWidth * 0.95,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 7, vertical: 6),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      gradient: const LinearGradient(
                        colors: [
                          Color(0xFF46E1FF),
                          Color(0xFF6797FF),
                          Color(0xFF9D5FFF)
                        ],
                        begin: Alignment.topRight,
                        end: Alignment.bottomLeft,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color:
                              const Color(0xFF7D72FF).withValues(alpha: 0.32),
                          blurRadius: 14,
                          offset: const Offset(0, 7),
                        ),
                      ],
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.65),
                        width: 1.1,
                      ),
                    ),
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        const Align(
                          alignment: Alignment.centerLeft,
                          child: Icon(
                            Icons.schedule_rounded,
                            size: 13,
                            color: Colors.white,
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              _formatSpontaneousCountdown(
                                _activeSpontaneousRemaining,
                              ),
                              textAlign: TextAlign.center,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10.4,
                                fontWeight: FontWeight.w900,
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
    );
  }

  Widget _buildSubCategoryProgressBadge({
    required int count,
    required bool isLight,
    required bool isWideLayout,
  }) {
    final clampedCount = count.clamp(0, _subCategoryGoal);
    final isComplete = clampedCount >= _subCategoryGoal;
    final topText = isComplete ? 'הושלם!' : '$clampedCount/$_subCategoryGoal';
    final bottomText = isComplete ? 'כל המשימות' : 'הושלמו';
    final fillDecoration = BoxDecoration(
      borderRadius: BorderRadius.circular(17),
      gradient: isComplete
          ? const LinearGradient(
              colors: [Color(0x66FFFFFF), Color(0x44FFFFFF)],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            )
          : (isLight
              ? const LinearGradient(
                  colors: [Color(0xFFF4F8FF), Color(0xFFE8EEFF)],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                )
              : const LinearGradient(
                  colors: [
                    Color(0xFF1A2140),
                    Color(0xFF202A4D),
                    Color(0xFF1A2B45)
                  ],
                  begin: Alignment.topRight,
                  end: Alignment.bottomLeft,
                )),
    );

    final badgeHeight = isWideLayout ? 88.0 : 64.0;
    final topFontSize = isWideLayout ? 17.5 : 15.0;
    final bottomFontSize = isWideLayout ? 10.8 : 9.2;

    return Container(
      height: badgeHeight,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: const LinearGradient(
          colors: [Color(0xFF46E1FF), Color(0xFF6797FF), Color(0xFF9D5FFF)],
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
        ),
        boxShadow: [
          BoxShadow(
            color:
                const Color(0xFF7D72FF).withValues(alpha: isLight ? 0.26 : 0.5),
            blurRadius: 22,
            spreadRadius: 1.2,
            offset: const Offset(0, 9),
          ),
          BoxShadow(
            color:
                const Color(0xFF4CD9FF).withValues(alpha: isLight ? 0.2 : 0.35),
            blurRadius: 18,
            spreadRadius: 0.8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      padding: const EdgeInsets.all(3.2),
      child: Container(
        decoration: fillDecoration.copyWith(
          gradient: isComplete
              ? const LinearGradient(
                  colors: [Color(0x22FFFFFF), Color(0x10FFFFFF)],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                )
              : (isLight
                  ? const LinearGradient(
                      colors: [Color(0x50FFFFFF), Color(0x20FFFFFF)],
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                    )
                  : const LinearGradient(
                      colors: [Color(0x28A489FF), Color(0x1648D9FF)],
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                    )),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              topText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: isComplete
                    ? Colors.white
                    : (isLight ? Colors.black : Colors.white),
                fontSize: topFontSize,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.35,
                shadows: isComplete
                    ? [
                        Shadow(
                          color:
                              const Color(0xFF4725A8).withValues(alpha: 0.35),
                          blurRadius: 10,
                          offset: const Offset(0, 2),
                        ),
                      ]
                    : null,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              bottomText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: isComplete
                    ? Colors.white.withValues(alpha: 0.98)
                    : (isLight
                        ? const Color(0xFF2A355A)
                        : const Color(0xFFD6CDFF)),
                fontSize: bottomFontSize,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.2,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final fallbackProfile = _placeholderProfile();
    final isLight = Theme.of(context).brightness == Brightness.light;
    final screenWidth = MediaQuery.of(context).size.width;
    final orbSizeA = (screenWidth * 0.82).clamp(230.0, 320.0);
    final orbSizeB = (screenWidth * 0.9).clamp(260.0, 350.0);
    return Scaffold(
      backgroundColor: isLight ? Colors.white : const Color(0xFF0B1019),
      body: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: _dismissKeyboardOnBackgroundTap,
        child: Stack(
          children: [
          if (isLight)
            Positioned(
              top: -120,
              right: -100,
              child: IgnorePointer(
                child: Container(
                  width: orbSizeA,
                  height: orbSizeA,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFFB9A9FF).withValues(alpha: 0.12),
                  ),
                ),
              ),
            ),
          if (isLight)
            Positioned(
              bottom: -140,
              left: -100,
              child: IgnorePointer(
                child: Container(
                  width: orbSizeB,
                  height: orbSizeB,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFF9EEBFF).withValues(alpha: 0.12),
                  ),
                ),
              ),
            ),
          Positioned.fill(
            child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
              stream: _profileStream(),
              builder: (context, profileSnapshot) {
                if (profileSnapshot.hasError) {
                  debugPrint('Profile stream error: ${profileSnapshot.error}');
                }

                return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                  stream: _publicProfileStream(),
                  builder: (context, publicProfileSnapshot) {
                    final privateData =
                        profileSnapshot.data?.data() ?? <String, dynamic>{};
                    final publicData = publicProfileSnapshot.data?.data() ??
                        <String, dynamic>{};
                    final mergedProfileData = _mergeProfileData(
                      privateData: privateData,
                      publicData: publicData,
                    );
                    final profileData = mergedProfileData.isEmpty
                        ? fallbackProfile
                        : mergedProfileData;
                    final unreadCount = _intValue(
                      privateData,
                      const ['unreadNotificationsCount'],
                    );

                    if ((profileData['isDeleted'] as bool?) ?? false) {
                      return Center(
                        child: Container(
                          margin: const EdgeInsets.symmetric(horizontal: 24),
                          padding: const EdgeInsets.all(18),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1A2435),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: const Color(0xFF53C1F9)
                                  .withValues(alpha: 0.22),
                            ),
                          ),
                          child: const Text(
                            'משתמש מחוק',
                            textAlign: TextAlign.center,
                            style:
                                TextStyle(color: Colors.white70, fontSize: 16),
                          ),
                        ),
                      );
                    }

                    return StreamBuilder<
                        List<QueryDocumentSnapshot<Map<String, dynamic>>>>(
                      stream: _allPostsStream(),
                      builder: (context, postsSnapshot) {
                        if (postsSnapshot.hasError) {
                          debugPrint(
                              'Error loading posts stream: ${postsSnapshot.error}');
                        }

                        final allDocs = postsSnapshot.data ??
                            const <QueryDocumentSnapshot<
                                Map<String, dynamic>>>[];

                        int publishedCount = 0;
                        for (final doc in allDocs) {
                          final isMine = _postAuthorId(doc.data()) == _uid;
                          if (!isMine) {
                            continue;
                          }
                          final status = _postStatus(doc.data());
                          if (status != 'draft') {
                            publishedCount += 1;
                          }
                        }

                        final postedSubCategoryCount =
                            _livePostedSubCategoryCount(allDocs);

                        final filteredDocs = _filteredPosts(allDocs);

                        return NestedScrollView(
                          physics: const BouncingScrollPhysics(),
                          headerSliverBuilder: (context, innerBoxIsScrolled) {
                            return [
                              SliverToBoxAdapter(
                                child: _buildHeader(
                                  profileData,
                                  publishedCount,
                                  postedSubCategoryCount,
                                  allDocs,
                                  isLight: isLight,
                                  unreadCount: unreadCount,
                                ),
                              ),
                            ];
                          },
                          body: LayoutBuilder(
                            builder: (context, constraints) {
                              final isNarrow = constraints.maxWidth < 700;
                              final sidebarWidth = constraints.maxWidth < 390
                                  ? 102.0
                                  : (isNarrow ? 108.0 : 120.0);

                              return Transform.translate(
                                offset: const Offset(0, -18),
                                child: Row(
                                  children: [
                                    SizedBox(
                                      width: sidebarWidth,
                                      child: _buildSidebarWithLock(
                                        viewportHeight: constraints.maxHeight,
                                        isLight: isLight,
                                      ),
                                    ),
                                    Expanded(
                                        child: _buildPostsGrid(filteredDocs)),
                                  ],
                                ),
                              );
                            },
                          ),
                        );
                      },
                    );
                  },
                );
              },
            ),
          ),
          ],
        ),
      ),
      bottomNavigationBar: const MainBottomNav(currentIndex: 4),
    );
  }
}
