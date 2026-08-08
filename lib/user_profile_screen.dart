import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import 'app_categories.dart';
import 'chat_room_screen.dart';
import 'main_bottom_nav.dart';
import 'post_media_utils.dart';
import 'profile_post_grouping.dart';
import 'models/public_user_profile.dart';
import 'post_detail_view.dart';
import 'services/chat_service.dart';
import 'services/block_user_service.dart';
import 'services/group_service.dart';
import 'services/post_interaction_overlay_service.dart';
import 'services/public_user_profile_service.dart';
import 'services/report_service.dart';
import 'services/spontaneous_challenge_service.dart';
import 'services/social_service.dart';
import 'widgets/profile_images_viewer_dialog.dart';
import 'widgets/post_media_viewer.dart';
import 'widgets/report_dialogs.dart';
import 'widgets/swipe_back_wrapper.dart';
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
  final String subtitle;
  final String avatarUrl;

  const _ProfileRelationUser({
    required this.uid,
    required this.name,
    required this.subtitle,
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

class UserProfileScreen extends StatefulWidget {
  final String uid;
  final String? username;
  final int currentBottomIndex;

  const UserProfileScreen({
    super.key,
    required this.uid,
    this.username,
    this.currentBottomIndex = 4,
  });

  @override
  State<UserProfileScreen> createState() => _UserProfileScreenState();
}

class _UserProfileScreenState extends State<UserProfileScreen> {
  static const int _subCategoryGoal = 100;
  static final List<_ProfileCategoryNavItem> _categoryItems = [
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

  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final SocialService _socialService = SocialService();
  final BlockUserService _blockUserService = BlockUserService();
  final ChatService _chatService = ChatService();
  final GroupService _groupService = GroupService();
  final PublicUserProfileService _publicUserProfileService =
      PublicUserProfileService();
  final ReportService _reportService = ReportService();
  final Map<String, Future<String?>> _resolvedMediaFutureByPostKey = {};
  final Map<String, Future<Uint8List?>> _videoPreviewFutureByUrl = {};

  String _selectedCategoryKey = 'general';
  bool _isFollowActionInFlight = false;
  bool _isQuickMessageSending = false;
  int _optimisticFollowersAdjustment = 0;
  int? _lastServerFollowersCount;
  DateTime _spontaneousCountdownNowUtc = DateTime.now().toUtc();
  Timer? _spontaneousCountdownTimer;
  final TextEditingController _quickMessageController = TextEditingController();
  final FocusNode _quickMessageFocusNode = FocusNode();
  Timer? _quickMessageTypingDebounce;
  int _quickMessageChangeSeq = 0;
  bool _blockedBackNavigationScheduled = false;
  late final Stream<PublicUserProfile?> _profileStreamRef;
  late final Stream<BlockRelationship> _blockRelationshipStream;
  late final Stream<FollowRelationship> _followRelationshipStream;
  late final Stream<List<QueryDocumentSnapshot<Map<String, dynamic>>>>
      _postsStreamRef;
  late final Future<int> _friendCountFuture;
  late final Future<bool> _canViewProfileContentFuture;
  late final Future<bool> _canViewFriendsOnlyPostsFuture;

  @override
  void initState() {
    super.initState();
    _profileStreamRef = _publicUserProfileService.streamProfile(widget.uid);
    _blockRelationshipStream = _blockUserService.streamRelationship(widget.uid);
    _followRelationshipStream =
        _socialService.watchFollowRelationship(widget.uid);
    _postsStreamRef = _postsStream();
    _friendCountFuture =
        _friendIdsForProfile(widget.uid).then((ids) => ids.length);
    _canViewProfileContentFuture = _canViewProfileContent(widget.uid);
    _canViewFriendsOnlyPostsFuture = _canViewFriendsOnlyPosts(widget.uid);

    _quickMessageFocusNode.addListener(() {
      _logQuickMessage(
        'focus_changed hasFocus=${_quickMessageFocusNode.hasFocus}',
      );
    });

    _spontaneousCountdownTimer = Timer.periodic(
      const Duration(seconds: 1),
      (timer) {
        if (!mounted) {
          timer.cancel();
          return;
        }
        setState(() {
          _spontaneousCountdownNowUtc = DateTime.now().toUtc();
        });
      },
    );
  }

  @override
  void dispose() {
    _spontaneousCountdownTimer?.cancel();
    _quickMessageTypingDebounce?.cancel();
    _quickMessageFocusNode.dispose();
    _quickMessageController.dispose();
    super.dispose();
  }

  void _logQuickMessage(String message) {
    final now = DateTime.now().toIso8601String();
    final currentUid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
    debugPrint(
      '[QM_TRACE][$now][viewer=$currentUid][target=${widget.uid}] $message',
    );
  }

  Future<bool> _canViewProfileContent(String targetUid) {
    return _socialService.canViewPrivateProfileContent(targetUid);
  }

  Future<bool> _canViewFriendsOnlyPosts(String targetUid) {
    return _socialService.isMutualFollow(targetUid);
  }

  Widget _buildProfileContent(
      Map<String, dynamic> profileData, PublicUserProfile profile,
      {bool showPosts = true, bool canViewFriendsOnlyPosts = true}) {
    return StreamBuilder<List<QueryDocumentSnapshot<Map<String, dynamic>>>>(
      stream: _postsStreamRef,
      builder: (context, postsSnapshot) {
        if (postsSnapshot.hasError) {
          return Center(
            child: Text(
              'שגיאה בטעינת הפוסטים',
              style: TextStyle(color: Colors.grey[300]),
            ),
          );
        }

        final allDocs = postsSnapshot.data ??
            const <QueryDocumentSnapshot<Map<String, dynamic>>>[];
        final publishedCount = allDocs
            .where((doc) =>
                _postStatus(doc.data()) == 'published' &&
                _postAuthorId(doc.data()) == widget.uid &&
                _isVisiblePostForViewer(
                  doc.data(),
                  canViewFriendsOnlyPosts: canViewFriendsOnlyPosts,
                ))
            .length;
        final livePostedSubCategoryCount = _livePostedSubCategoryCount(allDocs);
        final storedPostedSubCategoryCount =
            _storedPostedSubCategoryCount(profileData);
        final postedSubCategoryCount =
            livePostedSubCategoryCount > storedPostedSubCategoryCount
                ? livePostedSubCategoryCount
                : storedPostedSubCategoryCount;
        final visibleCategoryItems = _visibleCategoryItems(
          allDocs,
          canViewFriendsOnlyPosts: canViewFriendsOnlyPosts,
        );
        final selectedCategoryKey =
            _effectiveSelectedCategoryKey(visibleCategoryItems);
        final filteredDocs = _filteredPosts(
          allDocs,
          visibleCategoryItems,
          selectedCategoryKey,
          canViewFriendsOnlyPosts: canViewFriendsOnlyPosts,
        );

        return LayoutBuilder(
          builder: (context, constraints) {
            final isNarrow = constraints.maxWidth < 700;
            final sidebarWidth =
                constraints.maxWidth < 390 ? 98.0 : (isNarrow ? 92.0 : 106.0);

            Widget bodyContent;
            if (postsSnapshot.connectionState == ConnectionState.waiting &&
                !postsSnapshot.hasData) {
              bodyContent = const Padding(
                padding: EdgeInsets.symmetric(vertical: 28),
                child: Center(child: CircularProgressIndicator()),
              );
            } else if (!showPosts) {
              bodyContent = Center(
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 24),
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A2435),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: const Color(0xFF53C1F9).withValues(alpha: 0.22),
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.lock_outline_rounded,
                        color: Colors.white70,
                        size: 34,
                      ),
                      const SizedBox(height: 10),
                      const Text(
                        'רק לאחר שתהיו חברים תוכלו לצפות בפוסטים',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white70, fontSize: 16),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'שלחו עוקב, וכאשר תהיו חברים התוכן ייפתח לצפייה.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey[400], fontSize: 13),
                      ),
                    ],
                  ),
                ),
              );
            } else {
              bodyContent = Transform.translate(
                offset: const Offset(0, -18),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: sidebarWidth,
                      child: _buildSidebarWithLock(
                        visibleCategoryItems,
                        selectedCategoryKey,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(child: _buildPostsGrid(filteredDocs, profile)),
                  ],
                ),
              );
            }

            return SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildHeader(
                    profileData,
                    publishedCount,
                    postedSubCategoryCount,
                    allDocs,
                    profile,
                    canViewFriendsOnlyPosts: canViewFriendsOnlyPosts,
                  ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 18),
                    child: bodyContent,
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  String _postAudience(Map<String, dynamic> data) {
    return (data['audience'] as String? ?? 'public').trim().toLowerCase();
  }

  bool _isVisiblePostForViewer(
    Map<String, dynamic> data, {
    required bool canViewFriendsOnlyPosts,
  }) {
    final audience = _postAudience(data);
    return audience != 'friends' || canViewFriendsOnlyPosts;
  }

  Stream<List<QueryDocumentSnapshot<Map<String, dynamic>>>> _postsStream() {
    final authoredByAuthorIdStream = _db
        .collection('posts')
        .where('authorId', isEqualTo: widget.uid)
        .snapshots();
    final authoredByUidStream =
        _db.collection('posts').where('uid', isEqualTo: widget.uid).snapshots();
    final authoredByUserIdStream = _db
        .collection('posts')
        .where('userId', isEqualTo: widget.uid)
        .snapshots();
    final taggedByMembersStream = _db
        .collection('posts')
        .where('members', arrayContains: widget.uid)
        .snapshots();
    final taggedByParticipantsStream = _db
        .collection('posts')
        .where('participants', arrayContains: widget.uid)
        .snapshots();

    return Stream.multi((controller) {
      QuerySnapshot<Map<String, dynamic>>? authoredByAuthorIdSnapshot;
      QuerySnapshot<Map<String, dynamic>>? authoredByUidSnapshot;
      QuerySnapshot<Map<String, dynamic>>? authoredByUserIdSnapshot;
      QuerySnapshot<Map<String, dynamic>>? taggedByMembersSnapshot;
      QuerySnapshot<Map<String, dynamic>>? taggedByParticipantsSnapshot;

      void emitMerged() {
        if (authoredByAuthorIdSnapshot == null ||
            authoredByUidSnapshot == null ||
            authoredByUserIdSnapshot == null) {
          return;
        }

        final mergedById =
            <String, QueryDocumentSnapshot<Map<String, dynamic>>>{};
        for (final doc in authoredByAuthorIdSnapshot!.docs) {
          mergedById[doc.id] = doc;
        }
        for (final doc in authoredByUidSnapshot!.docs) {
          mergedById[doc.id] = doc;
        }
        for (final doc in authoredByUserIdSnapshot!.docs) {
          mergedById[doc.id] = doc;
        }
        if (taggedByMembersSnapshot != null) {
          for (final doc in taggedByMembersSnapshot!.docs) {
            if (_isTaggedPostForViewedUser(doc.data())) {
              mergedById[doc.id] = doc;
            }
          }
        }
        if (taggedByParticipantsSnapshot != null) {
          for (final doc in taggedByParticipantsSnapshot!.docs) {
            if (_isTaggedPostForViewedUser(doc.data())) {
              mergedById[doc.id] = doc;
            }
          }
        }

        final merged = mergedById.values.toList(growable: false)
          ..sort((a, b) =>
              _createdAtFrom(b.data()).compareTo(_createdAtFrom(a.data())));

        controller.add(merged);
      }

      final authoredByAuthorIdSub = authoredByAuthorIdStream.listen(
        (snapshot) {
          authoredByAuthorIdSnapshot = snapshot;
          emitMerged();
        },
        onError: controller.addError,
      );

      final authoredByUidSub = authoredByUidStream.listen(
        (snapshot) {
          authoredByUidSnapshot = snapshot;
          emitMerged();
        },
        onError: controller.addError,
      );

      final authoredByUserIdSub = authoredByUserIdStream.listen(
        (snapshot) {
          authoredByUserIdSnapshot = snapshot;
          emitMerged();
        },
        onError: controller.addError,
      );

      final taggedByMembersSub = taggedByMembersStream.listen(
        (snapshot) {
          taggedByMembersSnapshot = snapshot;
          emitMerged();
        },
        onError: (error, stackTrace) {
          debugPrint(
            '[UserProfileScreen][taggedByMembers] stream error: $error',
          );
        },
      );

      final taggedByParticipantsSub = taggedByParticipantsStream.listen(
        (snapshot) {
          taggedByParticipantsSnapshot = snapshot;
          emitMerged();
        },
        onError: (error, stackTrace) {
          debugPrint(
            '[UserProfileScreen][taggedByParticipants] stream error: $error',
          );
        },
      );

      controller.onCancel = () async {
        await authoredByAuthorIdSub.cancel();
        await authoredByUidSub.cancel();
        await authoredByUserIdSub.cancel();
        await taggedByMembersSub.cancel();
        await taggedByParticipantsSub.cancel();
      };
    });
  }

  String _displayName(Map<String, dynamic> data) {
    final explicitDisplayName = (data['displayName'] as String? ?? '').trim();
    if (explicitDisplayName.isNotEmpty) {
      return explicitDisplayName;
    }

    final firstName = (data['firstName'] as String? ?? '').trim();
    final lastName = (data['lastName'] as String? ?? '').trim();
    final username = (data['username'] as String? ?? '').trim();
    final parts = [firstName, lastName]
        .where((part) => part.isNotEmpty)
        .toList(growable: false);
    if (parts.isNotEmpty) {
      return parts.join(' ');
    }
    if (username.isNotEmpty) {
      return username.startsWith('@') ? username.substring(1) : username;
    }
    return widget.uid;
  }

  String _username(Map<String, dynamic> data) {
    final explicit = widget.username?.trim() ?? '';
    if (explicit.isNotEmpty) {
      return explicit.startsWith('@') ? explicit : '@$explicit';
    }

    final username = (data['username'] as String? ?? '').trim();
    if (username.isNotEmpty) {
      return username.startsWith('@') ? username : '@$username';
    }

    return '@${widget.uid.substring(0, widget.uid.length > 6 ? 6 : widget.uid.length)}';
  }

  String _bio(Map<String, dynamic> data) {
    final bio = (data['bio'] as String? ?? '').trim();
    return bio.isNotEmpty ? bio : 'אין תיאור פרופיל עדיין.';
  }

  String _profileImageUrl(Map<String, dynamic> data) {
    final explicit = (data['profilePictureUrl'] as String? ??
            data['profileImageUrl'] as String? ??
            data['avatarUrl'] as String? ??
            '')
        .trim();
    if (explicit.isNotEmpty) {
      return explicit;
    }

    final list = data['profileImageUrls'];
    if (list is List) {
      for (final item in list) {
        final url = item.toString().trim();
        if (url.isNotEmpty) {
          return url;
        }
      }
    }

    return '';
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
      if (_postAuthorId(data) != widget.uid ||
          _postStatus(data) != 'published') {
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

  int _storedPostedSubCategoryCount(Map<String, dynamic> profileData) {
    final rawKeys = profileData['postedSubCategoryKeys'];
    if (rawKeys is List<dynamic>) {
      return rawKeys
          .map((item) => item.toString().trim())
          .where((item) => item.isNotEmpty)
          .toSet()
          .length;
    }

    return _intFromAny(profileData, const ['postedSubCategoriesCount']);
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
    List<QueryDocumentSnapshot<Map<String, dynamic>>> allDocs, {
    required bool canViewFriendsOnlyPosts,
  }) {
    final categories = _taskCategoriesForDialog();
    final doneByCategory = <String, Set<String>>{};
    final availableByCategory = <String, List<String>>{};

    for (final category in categories) {
      availableByCategory[category] = _validTaskSubCategories(category);
      doneByCategory[category] = <String>{};
    }

    for (final doc in allDocs) {
      final data = doc.data();
      if (_postAuthorId(data) != widget.uid ||
          _postStatus(data) != 'published') {
        continue;
      }
      if (!_isVisiblePostForViewer(
        data,
        canViewFriendsOnlyPosts: canViewFriendsOnlyPosts,
      )) {
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
    required bool canViewFriendsOnlyPosts,
  }) async {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final progressByCategory = _taskProgressByCategory(
      allDocs,
      canViewFriendsOnlyPosts: canViewFriendsOnlyPosts,
    );
    final categories = progressByCategory.keys.toList(growable: false);

    await showDialog<void>(
      context: context,
      barrierColor: Colors.black54,
      builder: (dialogContext) {
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
                            Icons.close_rounded,
                            color: isLight
                                ? const Color(0xFF33405B)
                                : Colors.white70,
                          ),
                        ),
                        Expanded(
                          child: Text(
                            'משימות לפי קטגוריה',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: isLight
                                  ? const Color(0xFF22314F)
                                  : Colors.white,
                              fontSize: 20,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                        const SizedBox(width: 46),
                      ],
                    ),
                    const SizedBox(height: 6),
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
                                        canViewFriendsOnlyPosts:
                                            canViewFriendsOnlyPosts,
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
    required bool canViewFriendsOnlyPosts,
  }) async {
    final isLight = Theme.of(context).brightness == Brightness.light;

    await showDialog<void>(
      context: context,
      barrierColor: Colors.black54,
      builder: (dialogContext) {
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
                                          canViewFriendsOnlyPosts:
                                              canViewFriendsOnlyPosts,
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
          width: 124,
          height: 124,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                width: 116,
                height: 116,
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
                  padding: const EdgeInsets.all(12),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(icon, color: const Color(0xFF2A2361), size: 28),
                        const SizedBox(height: 6),
                        SizedBox(
                          width: 82,
                          child: Text(
                            category.trim(),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            textDirection: TextDirection.rtl,
                            style: TextStyle(
                              color: const Color(0xFF2A2361),
                              fontSize: isLight ? 12 : 11.8,
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
    const double textWidth = diameter - 30;
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
                  top: 5,
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
    required bool canViewFriendsOnlyPosts,
  }) async {
    final rankedPosts = allDocs.where((doc) {
      final data = doc.data();
      return _postAuthorId(data) == widget.uid &&
          _postStatus(data) == 'published' &&
          _postCategory(data) == category &&
          _postSubCategory(data) == subCategory &&
          _isVisiblePostForViewer(
            data,
            canViewFriendsOnlyPosts: canViewFriendsOnlyPosts,
          );
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

  int _intFromAny(Map<String, dynamic> data, List<String> keys,
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

  Widget _buildViewedUserSpontaneousTaskBubbles(SpontaneousChallengeTask task) {
    final remaining = task.remainingAt(_spontaneousCountdownNowUtc);
    if (remaining == Duration.zero) {
      return const SizedBox.shrink();
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 132,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: const LinearGradient(
              colors: [Color(0xFF46E1FF), Color(0xFF6797FF), Color(0xFF9D5FFF)],
              begin: Alignment.topRight,
              end: Alignment.bottomLeft,
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF7D72FF).withValues(alpha: 0.32),
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
              fontSize: 12.5,
              fontWeight: FontWeight.w900,
              height: 1.15,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Container(
          width: 132,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: const LinearGradient(
              colors: [Color(0xFF46E1FF), Color(0xFF6797FF), Color(0xFF9D5FFF)],
              begin: Alignment.topRight,
              end: Alignment.bottomLeft,
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF7D72FF).withValues(alpha: 0.32),
                blurRadius: 14,
                offset: const Offset(0, 7),
              ),
            ],
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.65),
              width: 1.1,
            ),
          ),
          child: Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.schedule_rounded,
                    size: 16,
                    color: Colors.white,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _formatSpontaneousCountdown(remaining),
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
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
    final scoreAwarded = _intFromAny(data, const ['scoreAwarded']);
    final likesCount = _intFromAny(
      data,
      const ['likesCount', 'likes_count'],
      fallback: ((data['likes'] as List<dynamic>?) ?? const <dynamic>[]).length,
    );
    final commentsCount = _intFromAny(
      data,
      const ['commentsCount', 'comments_count'],
      fallback:
          ((data['comments'] as List<dynamic>?) ?? const <dynamic>[]).length,
    );
    final sharesCount =
        _intFromAny(data, const ['sharesCount', 'shares_count']);
    final savesCount = _intFromAny(
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

  Set<String> _participantUids(Map<String, dynamic> data) {
    final raw = (data['members'] as List<dynamic>? ??
        data['participants'] as List<dynamic>? ??
        const <dynamic>[]);
    return raw
        .map((item) => item.toString().trim())
        .where((uid) => uid.isNotEmpty)
        .toSet();
  }

  bool _isTaggedPostForViewedUser(Map<String, dynamic> data) {
    final normalizedUid = widget.uid.trim();
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

  int _taggedPointsForViewedUserFromPost(Map<String, dynamic> data) {
    if (!_isTaggedPostForViewedUser(data)) {
      return 0;
    }
    return _postScore(data) ~/ 5;
  }

  Widget _buildScoreSheetThumbnail(Map<String, dynamic> post) {
    final mediaItems = postMediaItemsFromData(post);
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: 46,
        height: 46,
        color: const Color(0xFF1A2230),
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
                    return const Icon(
                      Icons.image_not_supported_rounded,
                      color: Colors.white38,
                      size: 18,
                    );
                  }
                  return Image.network(
                    url,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const Icon(
                      Icons.broken_image_outlined,
                      color: Colors.white38,
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
      PublicUserProfile profile,
      {required bool canViewFriendsOnlyPosts}) async {
    final publishedDocs = allDocs
        .where((doc) =>
            _postStatus(doc.data()) == 'published' &&
            _postAuthorId(doc.data()) == widget.uid &&
            _isVisiblePostForViewer(
              doc.data(),
              canViewFriendsOnlyPosts: canViewFriendsOnlyPosts,
            ))
        .toList(growable: false);

    final rankedPosts = publishedDocs.map((doc) {
      final raw = Map<String, dynamic>.from(doc.data())
        ..['id'] = doc.id
        ..['postId'] = ((doc.data()['postId'] as String?) ?? doc.id).trim();
      return _publicUserProfileService.injectProfileIntoPost(raw, profile);
    }).toList(growable: true)
      ..sort((a, b) {
        final scoreCmp = _postScore(b).compareTo(_postScore(a));
        if (scoreCmp != 0) return scoreCmp;
        return _createdAtFrom(b).compareTo(_createdAtFrom(a));
      });

    if (!mounted) return;
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
                maxHeight: MediaQuery.of(sheetContext).size.height * 0.78,
              ),
              margin: const EdgeInsets.fromLTRB(14, 8, 14, 16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(26),
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
                              color: isLight ? Colors.black54 : Colors.white70,
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
                                final title = (post['title'] as String? ?? '')
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
                                        ),
                                      ),
                                    );
                                  },
                                  child: Container(
                                    margin: const EdgeInsets.only(bottom: 10),
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 12, vertical: 10),
                                    decoration: BoxDecoration(
                                      color: isLight
                                          ? Colors.white.withValues(alpha: 0.72)
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
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 10, vertical: 6),
                                          decoration: BoxDecoration(
                                            gradient: LinearGradient(
                                              colors: index.isEven
                                                  ? const [
                                                      Color(0xFF83E4FF),
                                                      Color(0xFF9E7CFF),
                                                    ]
                                                  : const [
                                                      Color(0xFF68D5FF),
                                                      Color(0xFF7E8FFF),
                                                    ],
                                              begin: Alignment.topLeft,
                                              end: Alignment.bottomRight,
                                            ),
                                            borderRadius:
                                                BorderRadius.circular(999),
                                            border: Border.all(
                                              color: Colors.white.withValues(
                                                alpha: isLight ? 0.78 : 0.3,
                                              ),
                                            ),
                                            boxShadow: [
                                              BoxShadow(
                                                color: const Color(0xFF7BD6FF)
                                                    .withValues(alpha: 0.24),
                                                blurRadius: 12,
                                                offset: const Offset(0, 4),
                                              ),
                                            ],
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
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  color: isLight
                                                      ? Colors.black
                                                      : Colors.white,
                                                  fontWeight: FontWeight.w700,
                                                  fontSize: 13,
                                                ),
                                              ),
                                              const SizedBox(height: 2),
                                              Text(
                                                subCategory.isNotEmpty
                                                    ? subCategory
                                                    : 'ללא תת קטגוריה',
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  color: isLight
                                                      ? Colors.black54
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
            ),
          ),
        );
      },
    );
  }

  List<_ProfileCategoryNavItem> _visibleCategoryItems(
      List<QueryDocumentSnapshot<Map<String, dynamic>>> allDocs,
      {required bool canViewFriendsOnlyPosts}) {
    final availableCategories = allDocs
        .map((doc) => doc.data())
        .where((data) =>
            _postStatus(data) == 'published' &&
            _postAuthorId(data) == widget.uid &&
            _isVisiblePostForViewer(
              data,
              canViewFriendsOnlyPosts: canViewFriendsOnlyPosts,
            ))
        .map(_postCategory)
        .where((category) => category.isNotEmpty)
        .toSet();

    return _categoryItems.where((item) {
      if (item.key == 'general' || item.key == 'tagged') {
        return true;
      }
      final firestoreCategory = item.firestoreCategory;
      if (firestoreCategory == null) {
        return false;
      }
      return availableCategories.contains(firestoreCategory);
    }).toList(growable: false);
  }

  String _effectiveSelectedCategoryKey(
      List<_ProfileCategoryNavItem> visibleItems) {
    final hasSelected =
        visibleItems.any((item) => item.key == _selectedCategoryKey);
    return hasSelected ? _selectedCategoryKey : 'general';
  }

  List<QueryDocumentSnapshot<Map<String, dynamic>>> _filteredPosts(
      List<QueryDocumentSnapshot<Map<String, dynamic>>> allDocs,
      List<_ProfileCategoryNavItem> visibleItems,
      String selectedCategoryKey,
      {required bool canViewFriendsOnlyPosts}) {
    final selected = visibleItems.firstWhere(
      (item) => item.key == selectedCategoryKey,
      orElse: () => visibleItems.first,
    );

    return allDocs.where((doc) {
      final data = doc.data();
      final status = _postStatus(data);
      final category = _postCategory(data);
      final isMine = _postAuthorId(data) == widget.uid;
      final canSeeAudience = _isVisiblePostForViewer(
        data,
        canViewFriendsOnlyPosts: canViewFriendsOnlyPosts,
      );

      if (selected.key == 'general') {
        return isMine && status == 'published' && canSeeAudience;
      }

      if (selected.key == 'tagged') {
        return _isTaggedPostForViewedUser(data) && canSeeAudience;
      }

      if (selected.firestoreCategory == null) {
        return false;
      }

      return isMine &&
          status == 'published' &&
          category == selected.firestoreCategory &&
          canSeeAudience;
    }).toList(growable: false);
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
    final rawMedia = _rawMediaField(data);
    final storagePathField = (data['storagePath'] as String? ?? '').trim();

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
      } catch (_) {}
    }

    if (storagePathField.isEmpty) {
      return null;
    }

    try {
      return await FirebaseStorage.instance
          .ref(storagePathField)
          .getDownloadURL();
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
        cacheKey, () => _resolveMediaUrl(data));
  }

  Widget _buildPostFallback() {
    return Container(
      color: const Color(0xFF1A2230),
      child: const Center(
        child: Icon(Icons.image_not_supported_rounded,
            color: Colors.white38, size: 34),
      ),
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
    final subCategory = (data['subCategory'] as String? ?? '').trim();
    final postTitle = (data['title'] as String? ?? '').trim();
    final subCategoryLabel =
        subCategory.isNotEmpty ? subCategory : 'ללא קטגוריה';
    final score = _postScore(data);
    final taggedScore = _taggedPointsForViewedUserFromPost(data);
    final isTaggedCategoryView = _selectedCategoryKey == 'tagged';

    return Container(
      decoration: BoxDecoration(
        color: isLight ? Colors.white : const Color(0xFF171F2D),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: isLight
              ? const Color(0xFFA9C3FF)
              : const Color(0xFF53C1F9).withValues(alpha: 0.12),
        ),
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
                    left: 10,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (_postAudience(data) == 'friends') ...[
                          const SizedBox(height: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 5),
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
                                fontSize: 10,
                              ),
                            ),
                          ),
                        ],
                        if (taggedScore > 0) ...[
                          if (!isTaggedCategoryView) const SizedBox(height: 6),
                          if (!isTaggedCategoryView)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 5),
                              decoration: BoxDecoration(
                                color: isLight
                                    ? Colors.white.withValues(alpha: 0.92)
                                    : const Color(0xFF2A2248)
                                        .withValues(alpha: 0.94),
                                borderRadius: BorderRadius.circular(999),
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
                  ),
                  Positioned(
                    top: 10,
                    right: 10,
                    left: 10,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 112),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: isLight
                                ? Colors.white
                                : const Color(0xFF153454),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(
                              color: const Color(0xFF53C1F9),
                            ),
                          ),
                          child: Text(
                            subCategoryLabel,
                            textAlign: TextAlign.right,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: isLight
                                  ? Colors.black
                                  : const Color(0xFFD8F1FF),
                              fontSize: 10.8,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    top: 40,
                    right: 10,
                    child: Builder(
                      builder: (_) {
                        if (isTaggedCategoryView && taggedScore <= 0) {
                          return const SizedBox.shrink();
                        }

                        final label = isTaggedCategoryView
                            ? '+$taggedScore'
                            : '+${_formatCompactCount(score)}';

                        return Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 9, vertical: 5),
                          decoration: BoxDecoration(
                            color: isTaggedCategoryView
                                ? (isLight
                                    ? Colors.white.withValues(alpha: 0.92)
                                    : const Color(0xFF2A2248)
                                        .withValues(alpha: 0.94))
                                : (isLight
                                    ? Colors.white.withValues(alpha: 0.92)
                                    : const Color(0xFF141925)
                                        .withValues(alpha: 0.92)),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(
                              color: isTaggedCategoryView
                                  ? const Color(0xFF9E7CFF)
                                      .withValues(alpha: 0.55)
                                  : const Color(0xFF53C1F9)
                                      .withValues(alpha: 0.4),
                            ),
                          ),
                          child: Text(
                            label,
                            style: TextStyle(
                              color: isTaggedCategoryView
                                  ? (isLight
                                      ? Colors.black
                                      : const Color(0xFFE6D9FF))
                                  : (isLight
                                      ? Colors.black
                                      : const Color(0xFFBFE7FF)),
                              fontWeight: FontWeight.w800,
                              fontSize: 11,
                            ),
                          ),
                        );
                      },
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
                            color: isLight
                                ? Colors.black
                                : const Color(0xFFD8F1FF),
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
              children: [
                Expanded(
                  child: Text(
                    '${entry.docs.length} פוסטים',
                    textAlign: TextAlign.right,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isLight ? Colors.black : Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
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
        (total, doc) => total + _taggedPointsForViewedUserFromPost(doc.data()),
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

  Widget _buildCategorySidebarItem(_ProfileCategoryNavItem item,
      {required bool isSelected}) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final isCompact = MediaQuery.of(context).size.width < 390;
    final baseColor = isLight
        ? (isSelected ? const Color(0xFFE6EEFF) : Colors.white)
        : (isSelected ? const Color(0xFF9E7CFF) : const Color(0xFF1E2632));
    final borderColor = isLight
        ? const Color(0xFFA9C3FF)
        : (isSelected ? const Color(0xFF53C1F9) : Colors.white10);
    final iconColor = isLight
        ? Colors.black
        : (isSelected ? Colors.white : Colors.grey[300]!);

    return Tooltip(
      message: item.label,
      child: GestureDetector(
        onTap: () {
          if (_selectedCategoryKey == item.key) return;
          setState(() {
            _selectedCategoryKey = item.key;
          });
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          margin: EdgeInsets.symmetric(
            horizontal: isCompact ? 5 : 8,
            vertical: isCompact ? 5 : 6,
          ),
          padding: EdgeInsets.symmetric(
            horizontal: isCompact ? 4 : 6,
            vertical: isCompact ? 8 : 10,
          ),
          decoration: BoxDecoration(
            color: baseColor,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: borderColor),
            boxShadow: isSelected
                ? const [
                    BoxShadow(
                      color: Color(0x3A9E7CFF),
                      blurRadius: 14,
                      offset: Offset(0, 6),
                    ),
                  ]
                : null,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(item.icon, color: iconColor, size: isCompact ? 20 : 22),
              SizedBox(height: isCompact ? 4 : 6),
              Text(
                item.label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: isLight
                      ? Colors.black
                      : (isSelected ? Colors.white : Colors.grey[400]),
                  fontSize: isCompact ? 9 : 10,
                  fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                  height: 1.1,
                ),
                maxLines: isCompact ? 1 : 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSidebarWithLock(
    List<_ProfileCategoryNavItem> visibleItems,
    String selectedCategoryKey,
  ) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final isCompact = MediaQuery.of(context).size.width < 390;
    return Container(
      margin:
          EdgeInsets.fromLTRB(isCompact ? 10 : 16, 0, isCompact ? 4 : 8, 16),
      decoration: BoxDecoration(
        color: isLight ? Colors.white : const Color(0xFF151D2A),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isLight ? const Color(0xFFA9C3FF) : Colors.white10,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: ListView.builder(
          physics: const NeverScrollableScrollPhysics(),
          shrinkWrap: true,
          itemCount: visibleItems.length,
          padding: EdgeInsets.fromLTRB(
              0, isCompact ? 8 : 10, 0, isCompact ? 12 : 16),
          itemExtent: isCompact ? 78 : 86,
          itemBuilder: (context, index) {
            final item = visibleItems[index];
            return _buildCategorySidebarItem(
              item,
              isSelected: item.key == selectedCategoryKey,
            );
          },
        ),
      ),
    );
  }

  Widget _buildPostsGrid(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
    PublicUserProfile profile,
  ) {
    if (docs.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Text(
            'אין פוסטים להצגה',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey[400], fontSize: 14),
          ),
        ),
      );
    }

    final entries = groupProfilePostsByEvent(
      docs,
      enableFolders: true,
      minPostsPerFolder: _selectedCategoryKey == 'tagged' ? 2 : 1,
    );
    final visiblePostsData = docs.map((doc) {
      final post = Map<String, dynamic>.from(doc.data());
      post['id'] = doc.id;
      post['postId'] = (post['postId'] as String? ?? doc.id).trim();
      return post;
    }).toList(growable: false);
    final visiblePostIndexById = <String, int>{
      for (var i = 0; i < visiblePostsData.length; i++)
        (visiblePostsData[i]['id'] as String? ??
                visiblePostsData[i]['postId'] as String? ??
                '')
            .trim(): i,
    };

    return GridView.builder(
      physics: const NeverScrollableScrollPhysics(),
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(6, 0, 2, 24),
      itemCount: entries.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
        childAspectRatio: 3 / 4,
      ),
      itemBuilder: (context, index) {
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
                ),
              ),
            );
          },
          child: entry.isFolder
              ? _buildEventFolderCard(entry)
              : _buildPostCard(entry.primaryDoc.data()),
        );
      },
    );
  }

  // ignore: unused_element
  Widget _buildStatItem(String label, String value) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(value,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        Text(label, style: TextStyle(color: Colors.grey[400], fontSize: 12)),
      ],
    );
  }

  List<String> _uidListFromData(Map<String, dynamic>? data, String key) {
    final raw = data?[key];
    if (raw is! List) {
      return const <String>[];
    }

    final seen = <String>{};
    final result = <String>[];
    for (final item in raw) {
      final uid = item.toString().trim();
      if (uid.isEmpty || seen.contains(uid)) {
        continue;
      }
      seen.add(uid);
      result.add(uid);
    }
    return result;
  }

  Future<List<_ProfileRelationUser>> _relationUsersForIds(
      List<String> ids) async {
    if (ids.isEmpty) {
      return const <_ProfileRelationUser>[];
    }

    final users = <_ProfileRelationUser>[];
    for (final uid in ids) {
      final profile = await _publicUserProfileService.fetchProfile(uid);
      if (profile == null) {
        users.add(
          _ProfileRelationUser(
            uid: uid,
            name: uid,
            subtitle: '@${uid.substring(0, uid.length > 6 ? 6 : uid.length)}',
            avatarUrl: '',
          ),
        );
        continue;
      }

      final displayName = profile.displayName.isNotEmpty
          ? profile.displayName
          : (profile.username.isNotEmpty ? profile.username : uid);

      users.add(
        _ProfileRelationUser(
          uid: uid,
          name: displayName,
          subtitle: profile.handle,
          avatarUrl: profile.profilePictureUrl,
        ),
      );
    }

    return users;
  }

  Future<bool> _toggleFollowFromSheet({
    required String targetUid,
    required FollowRelationship relationship,
  }) async {
    try {
      if (relationship.isFollowing) {
        final shouldUnfollow = await showDialog<bool>(
              context: context,
              builder: (dialogContext) {
                return AlertDialog(
                  backgroundColor: const Color(0xFF161F2E),
                  title: const Text(
                    'אישור הסרת מעקב',
                    style: TextStyle(color: Colors.white),
                    textAlign: TextAlign.right,
                  ),
                  content: const Text(
                    'האם אתה בטוח שאתה רוצה להוריד למשתמש עוקב?',
                    style: TextStyle(color: Colors.white70),
                    textAlign: TextAlign.right,
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(dialogContext).pop(false),
                      child: const Text('ביטול'),
                    ),
                    ElevatedButton(
                      onPressed: () => Navigator.of(dialogContext).pop(true),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF9E7CFF),
                        foregroundColor: Colors.white,
                      ),
                      child: const Text('אישור'),
                    ),
                  ],
                );
              },
            ) ??
            false;

        if (!shouldUnfollow) {
          return false;
        }

        await _socialService.unfollowUser(targetUid);
        return true;
      } else if (relationship.isRequestPending) {
        final shouldCancel = await showDialog<bool>(
              context: context,
              builder: (dialogContext) {
                return AlertDialog(
                  backgroundColor: const Color(0xFF161F2E),
                  title: const Text(
                    'ביטול בקשת מעקב',
                    style: TextStyle(color: Colors.white),
                    textAlign: TextAlign.right,
                  ),
                  content: const Text(
                    'לבטל את בקשת המעקב שנשלחה?',
                    style: TextStyle(color: Colors.white70),
                    textAlign: TextAlign.right,
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(dialogContext).pop(false),
                      child: const Text('לא'),
                    ),
                    ElevatedButton(
                      onPressed: () => Navigator.of(dialogContext).pop(true),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF9E7CFF),
                        foregroundColor: Colors.white,
                      ),
                      child: const Text('כן'),
                    ),
                  ],
                );
              },
            ) ??
            false;

        if (!shouldCancel) {
          return false;
        }

        await _socialService.cancelFollowRequest(targetUid);
      } else {
        await _socialService.followUser(targetUid);
      }
      return false;
    } catch (error) {
      if (!mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('עדכון מעקב נכשל: $error')),
      );
      return false;
    }
  }

  Future<void> _openProfileFromSheet(String uid) async {
    if (!mounted || uid.trim().isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => UserProfileScreen(
          uid: uid,
          currentBottomIndex: widget.currentBottomIndex,
        ),
      ),
    );
  }

  Future<void> _showRelationSheet({
    required String title,
    required List<String> userIds,
    required String emptyMessage,
  }) async {
    if (!mounted) return;

    final initialUsers = await _relationUsersForIds(userIds);
    if (!mounted) return;
    if (initialUsers.isEmpty) {
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
                  maxHeight: MediaQuery.of(sheetContext).size.height * 0.78,
                ),
                margin: const EdgeInsets.fromLTRB(14, 8, 14, 16),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(26),
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
                    borderRadius: BorderRadius.circular(24),
                  ),
                  padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
                  child: _buildSheetEmptyState(emptyMessage),
                ),
              ),
            ),
          );
        },
      );
      return;
    }

    final users = List<_ProfileRelationUser>.from(initialUsers);

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
                maxHeight: MediaQuery.of(sheetContext).size.height * 0.78,
              ),
              margin: const EdgeInsets.fromLTRB(14, 8, 14, 16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(26),
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
                  borderRadius: BorderRadius.circular(24),
                ),
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
                child: StatefulBuilder(
                  builder: (context, setModalState) {
                    if (users.isEmpty) {
                      return _buildSheetEmptyState(emptyMessage);
                    }

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
                        const SizedBox(height: 12),
                        Expanded(
                          child: ListView.builder(
                            itemCount: users.length,
                            itemBuilder: (context, index) {
                              final user = users[index];
                              final currentUid =
                                  FirebaseAuth.instance.currentUser?.uid ?? '';
                              final isMe = currentUid.isNotEmpty &&
                                  user.uid == currentUid;

                              return Container(
                                margin: const EdgeInsets.only(bottom: 10),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 10),
                                decoration: BoxDecoration(
                                  color: isLight
                                      ? Colors.white.withValues(alpha: 0.72)
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
                                      radius: 20,
                                      backgroundColor: const Color(0xFF9E7CFF),
                                      backgroundImage: user.avatarUrl.isNotEmpty
                                          ? NetworkImage(user.avatarUrl)
                                          : null,
                                      child: user.avatarUrl.isEmpty
                                          ? Text(
                                              user.name.isNotEmpty
                                                  ? user.name.characters.first
                                                  : '?',
                                              style: const TextStyle(
                                                color: Color(0xFFEAF7FF),
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
                                          _openProfileFromSheet(user.uid);
                                        },
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              user.name,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                color: isLight
                                                    ? Colors.black
                                                    : Colors.white,
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              user.subtitle,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                color: isLight
                                                    ? Colors.black54
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
                                            horizontal: 10, vertical: 8),
                                        decoration: BoxDecoration(
                                          color: isLight
                                              ? const Color(0xFFEFF5FF)
                                              : Colors.white10,
                                          borderRadius:
                                              BorderRadius.circular(10),
                                        ),
                                        child: Text(
                                          'אתה',
                                          style: TextStyle(
                                            color: isLight
                                                ? Colors.black87
                                                : Colors.white70,
                                            fontWeight: FontWeight.w700,
                                            fontSize: 12,
                                          ),
                                        ),
                                      )
                                    else
                                      StreamBuilder<FollowRelationship>(
                                        stream: _socialService
                                            .watchFollowRelationship(user.uid),
                                        builder: (context, followSnapshot) {
                                          final relationship =
                                              followSnapshot.data ??
                                                  const FollowRelationship();
                                          final isFollowing =
                                              relationship.isFollowing;
                                          final isRequestPending =
                                              relationship.isRequestPending;
                                          final isFollowCta =
                                              !isFollowing && !isRequestPending;
                                          final gradientColors = isFollowing
                                              ? const [
                                                  Color(0xFF62D9FF),
                                                  Color(0xFF5E8FFF),
                                                ]
                                              : isRequestPending
                                                  ? const [
                                                      Color(0xFF607D8B),
                                                      Color(0xFF455A64),
                                                    ]
                                                  : const [
                                                      Color(0xFF7D52F4),
                                                      Color(0xFFB06CFF),
                                                    ];
                                          return Container(
                                            decoration: BoxDecoration(
                                              gradient: LinearGradient(
                                                colors: gradientColors,
                                                begin: Alignment.topLeft,
                                                end: Alignment.bottomRight,
                                              ),
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                              border: Border.all(
                                                color: isFollowCta
                                                    ? const Color(0xFFE6D9FF)
                                                    : Colors.white.withValues(
                                                        alpha: isLight
                                                            ? 0.9
                                                            : 0.22,
                                                      ),
                                                width: isFollowCta ? 1.5 : 1,
                                              ),
                                              boxShadow: isFollowCta
                                                  ? [
                                                      BoxShadow(
                                                        color: const Color(
                                                          0xFF9E7CFF,
                                                        ).withValues(
                                                            alpha: 0.3),
                                                        blurRadius: 10,
                                                        offset:
                                                            const Offset(0, 3),
                                                      ),
                                                    ]
                                                  : null,
                                            ),
                                            child: Material(
                                              color: Colors.transparent,
                                              child: InkWell(
                                                borderRadius:
                                                    BorderRadius.circular(12),
                                                onTap: () =>
                                                    _toggleFollowFromSheet(
                                                  targetUid: user.uid,
                                                  relationship: relationship,
                                                ).then((didUnfollow) {
                                                  if (!didUnfollow) {
                                                    return;
                                                  }
                                                  final isFollowingSheet =
                                                      title == 'נעקבים';
                                                  if (!isFollowingSheet) {
                                                    return;
                                                  }
                                                  setModalState(() {
                                                    users.removeWhere(
                                                      (item) =>
                                                          item.uid == user.uid,
                                                    );
                                                  });
                                                }),
                                                child: Padding(
                                                  padding: const EdgeInsets
                                                      .symmetric(
                                                    horizontal: 14,
                                                    vertical: 9,
                                                  ),
                                                  child: Text(
                                                    isFollowing
                                                        ? 'עוקב'
                                                        : (isRequestPending
                                                            ? 'בקשה נשלחה'
                                                            : 'עקוב'),
                                                    style: const TextStyle(
                                                      color: Colors.white,
                                                      fontSize: 12,
                                                      fontWeight:
                                                          FontWeight.w800,
                                                    ),
                                                  ),
                                                ),
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

  Future<void> _showFollowersSheet() async {
    final followers = await _followersForProfile(widget.uid);
    await _showRelationSheet(
      title: 'עוקבים',
      userIds: followers,
      emptyMessage: 'אין עוקבים להצגה כרגע',
    );
  }

  Future<void> _showFollowingSheet() async {
    final following = await _followingForProfile(widget.uid);
    await _showRelationSheet(
      title: 'נעקבים',
      userIds: following,
      emptyMessage: 'המשתמש עדיין לא עוקב אחרי אחרים',
    );
  }

  Future<void> _showFriendsOfUserSheet() async {
    final friends = await _friendIdsForProfile(widget.uid);

    await _showRelationSheet(
      title: 'חברים',
      userIds: friends,
      emptyMessage: 'אין חברים להצגה כרגע',
    );
  }

  Future<Map<String, dynamic>> _relationSourceDataForProfile(String uid) async {
    final normalizedUid = uid.trim();
    if (normalizedUid.isEmpty) {
      return <String, dynamic>{};
    }

    final currentUid = FirebaseAuth.instance.currentUser?.uid;
    if (currentUid != null && currentUid == normalizedUid) {
      final privateDoc = await _db.collection('users').doc(normalizedUid).get();
      return privateDoc.data() ?? <String, dynamic>{};
    }

    final publicDoc =
        await _db.collection('users_public').doc(normalizedUid).get();
    final publicData = publicDoc.data() ?? <String, dynamic>{};

    final hasPublicRelations =
        _uidListFromData(publicData, 'followers').isNotEmpty ||
            _uidListFromData(publicData, 'following').isNotEmpty ||
            ((publicData['followersCount'] as num?)?.toInt() ?? 0) > 0 ||
            ((publicData['followingCount'] as num?)?.toInt() ?? 0) > 0;
    if (hasPublicRelations) {
      return publicData;
    }

    try {
      final privateDoc = await _db.collection('users').doc(normalizedUid).get();
      return privateDoc.data() ?? publicData;
    } catch (_) {
      return publicData;
    }
  }

  Future<List<String>> _followersForProfile(String uid) async {
    final data = await _relationSourceDataForProfile(uid);
    final directFollowers = _uidListFromData(data, 'followers');
    if (directFollowers.isNotEmpty) {
      return directFollowers;
    }

    final normalizedUid = uid.trim();
    if (normalizedUid.isEmpty) {
      return const <String>[];
    }

    try {
      final reverseSnapshot = await _db
          .collection('users_public')
          .where('following', arrayContains: normalizedUid)
          .get();
      final ids = reverseSnapshot.docs
          .map((doc) => doc.id.trim())
          .where((value) => value.isNotEmpty)
          .toSet()
          .toList(growable: false)
        ..sort();
      if (ids.isNotEmpty) {
        return ids;
      }

      final privateReverseSnapshot = await _db
          .collection('users')
          .where('following', arrayContains: normalizedUid)
          .get();
      final privateIds = privateReverseSnapshot.docs
          .map((doc) => doc.id.trim())
          .where((value) => value.isNotEmpty)
          .toSet()
          .toList(growable: false)
        ..sort();
      return privateIds;
    } catch (error) {
      debugPrint(
        '[UserProfileScreen][followersForProfile] reverse query failed for $normalizedUid: $error',
      );
      return const <String>[];
    }
  }

  Future<List<String>> _followingForProfile(String uid) async {
    final data = await _relationSourceDataForProfile(uid);
    final directFollowing = _uidListFromData(data, 'following');
    if (directFollowing.isNotEmpty) {
      return directFollowing;
    }

    final normalizedUid = uid.trim();
    if (normalizedUid.isEmpty) {
      return const <String>[];
    }

    try {
      final reverseSnapshot = await _db
          .collection('users_public')
          .where('followers', arrayContains: normalizedUid)
          .get();
      final ids = reverseSnapshot.docs
          .map((doc) => doc.id.trim())
          .where((value) => value.isNotEmpty)
          .toSet()
          .toList(growable: false)
        ..sort();
      if (ids.isNotEmpty) {
        return ids;
      }

      final privateReverseSnapshot = await _db
          .collection('users')
          .where('followers', arrayContains: normalizedUid)
          .get();
      final privateIds = privateReverseSnapshot.docs
          .map((doc) => doc.id.trim())
          .where((value) => value.isNotEmpty)
          .toSet()
          .toList(growable: false)
        ..sort();
      return privateIds;
    } catch (error) {
      debugPrint(
        '[UserProfileScreen][followingForProfile] reverse query failed for $normalizedUid: $error',
      );
      return const <String>[];
    }
  }

  Future<List<String>> _friendIdsForProfile(
    String uid, {
    Map<String, dynamic>? preferredData,
  }) async {
    final normalizedUid = uid.trim();
    if (normalizedUid.isEmpty) {
      return const <String>[];
    }

    final relationData =
        preferredData ?? await _relationSourceDataForProfile(uid);
    final explicitFriends = _uidListFromData(relationData, 'friends').toSet();
    if (explicitFriends.isNotEmpty) {
      final ids = explicitFriends.toList(growable: false)..sort();
      return ids;
    }

    final followers = (await _followersForProfile(normalizedUid)).toSet();
    final following = (await _followingForProfile(normalizedUid)).toSet();
    final ids = followers.intersection(following).toList(growable: false)
      ..sort();
    return ids;
  }

  Future<Set<String>> _groupIdsFromRootGroupQueriesForUser(String uid) async {
    final normalizedUid = uid.trim();
    if (normalizedUid.isEmpty) {
      return const <String>{};
    }

    final ids = <String>{};

    Future<void> collect(
      Future<QuerySnapshot<Map<String, dynamic>>> future,
    ) async {
      try {
        final snapshot = await future;
        for (final doc in snapshot.docs) {
          ids.add(doc.id);
        }
      } catch (_) {}
    }

    await collect(
      _db
          .collection('groups')
          .where('members', arrayContains: normalizedUid)
          .get(),
    );
    await collect(
      _db
          .collection('groups')
          .where('membersList', arrayContains: normalizedUid)
          .get(),
    );
    await collect(
      _db
          .collection('groups')
          .where('participants', arrayContains: normalizedUid)
          .get(),
    );
    await collect(
      _db
          .collection('groups')
          .where('adminUid', isEqualTo: normalizedUid)
          .get(),
    );

    return ids;
  }

  Future<void> _openDirectChat(Map<String, dynamic> profileData) async {
    final sw = Stopwatch()..start();
    _logQuickMessage('open_direct_chat_start');
    try {
      final chatId = await _chatService.findOrCreateDirectChat(
        otherUserId: widget.uid,
        otherDisplayName: _displayName(profileData),
        otherAvatarUrl: _profileImageUrl(profileData),
      );
      _logQuickMessage(
        'open_direct_chat_ready chatId=$chatId elapsedMs=${sw.elapsedMilliseconds}',
      );
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ChatRoomScreen(
            chatName: _displayName(profileData),
            avatarUrl: _profileImageUrl(profileData).isEmpty
                ? null
                : _profileImageUrl(profileData),
            chatId: chatId,
            isDirectChat: true,
            directOtherUserId: widget.uid,
          ),
        ),
      );
    } catch (error) {
      _logQuickMessage(
        'open_direct_chat_error type=${error.runtimeType} elapsedMs=${sw.elapsedMilliseconds} error=$error',
      );
      if (!mounted) return;
      String message;
      if (error is TimeoutException) {
        message = 'פתיחת הצ\'אט אורכת יותר מדי זמן. נסה שוב.';
      } else if (error is FirebaseAuthException &&
          error.code == 'blocked-user') {
        message = 'לא ניתן לפתוח צ\'אט: קיימת חסימה בין המשתמשים.';
      } else if (error is FirebaseException &&
          error.code == 'permission-denied') {
        message = 'אין הרשאה לפתוח צ\'אט כרגע. נסה שוב בעוד רגע.';
      } else {
        message = 'פתיחת צ\'אט נכשלה: $error';
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    } finally {
      _logQuickMessage(
        'open_direct_chat_end elapsedMs=${sw.elapsedMilliseconds}',
      );
    }
  }

  Future<void> _sendQuickMessageToProfileChat(
      Map<String, dynamic> profileData) async {
    final text = _quickMessageController.text.trim();
    _logQuickMessage(
      'send_attempt textLen=${text.length} inFlight=$_isQuickMessageSending',
    );
    if (text.isEmpty || _isQuickMessageSending) {
      _logQuickMessage(
          'send_skipped reason=${text.isEmpty ? 'empty' : 'in_flight'}');
      return;
    }

    final sw = Stopwatch()..start();

    setState(() {
      _isQuickMessageSending = true;
    });
    _logQuickMessage('send_state_changed sending=true');

    try {
      final chatId = await _chatService.findOrCreateDirectChat(
        otherUserId: widget.uid,
        otherDisplayName: _displayName(profileData),
        otherAvatarUrl: _profileImageUrl(profileData),
      );
      _logQuickMessage(
        'send_chat_ready chatId=$chatId elapsedMs=${sw.elapsedMilliseconds}',
      );

      final effectiveChatId = await _chatService.sendMessage(
        chatId: chatId,
        text: text,
        directOtherUserIdHint: widget.uid,
        directOtherDisplayNameHint: _displayName(profileData),
        directOtherAvatarUrlHint: _profileImageUrl(profileData),
      );
      _logQuickMessage(
        'send_message_success chatId=$effectiveChatId elapsedMs=${sw.elapsedMilliseconds}',
      );
      _quickMessageController.clear();
      _logQuickMessage('send_input_cleared');

      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ChatRoomScreen(
            chatName: _displayName(profileData),
            avatarUrl: _profileImageUrl(profileData).isEmpty
                ? null
                : _profileImageUrl(profileData),
            chatId: effectiveChatId,
            isDirectChat: true,
            directOtherUserId: widget.uid,
          ),
        ),
      );
    } catch (error) {
      final effectiveError = error;

      _logQuickMessage(
        'send_error type=${effectiveError.runtimeType} elapsedMs=${sw.elapsedMilliseconds} error=$effectiveError',
      );
      if (!mounted) return;
      String message;
      if (effectiveError is TimeoutException) {
        message = 'שליחת ההודעה אורכת יותר מדי זמן. נסה שוב.';
      } else if (effectiveError is FirebaseAuthException &&
          effectiveError.code == 'blocked-user') {
        message = 'לא ניתן לשלוח הודעה: קיימת חסימה בין המשתמשים.';
      } else if (effectiveError is FirebaseException &&
          effectiveError.code == 'permission-denied') {
        message = 'לא ניתן לשלוח הודעה למשתמש זה.';
      } else {
        message = 'שליחת הודעה נכשלה: $effectiveError';
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    } finally {
      _logQuickMessage('send_finally elapsedMs=${sw.elapsedMilliseconds}');
      if (mounted) {
        setState(() {
          _isQuickMessageSending = false;
        });
        _logQuickMessage('send_state_changed sending=false');
      }
    }
  }

  Future<List<DocumentSnapshot<Map<String, dynamic>>>> _mutualGroups() async {
    final currentUid = FirebaseAuth.instance.currentUser?.uid;
    if (currentUid == null || currentUid.isEmpty || currentUid == widget.uid) {
      return const <DocumentSnapshot<Map<String, dynamic>>>[];
    }

    final normalizedCurrentUid = currentUid.trim();
    final targetUid = widget.uid.trim();

    final currentRootIds =
        await _groupIdsFromRootGroupQueriesForUser(normalizedCurrentUid);
    final currentMemberIds =
        await _groupIdsFromMembershipSubcollection(normalizedCurrentUid);
    final currentChatIds = await _groupIdsFromMyChatParticipation();
    final currentGroupIds = <String>{
      ...currentRootIds,
      ...currentMemberIds,
      ...currentChatIds,
    };
    if (currentGroupIds.isEmpty) {
      return const <DocumentSnapshot<Map<String, dynamic>>>[];
    }

    final resolved = <DocumentSnapshot<Map<String, dynamic>>>[];
    for (final groupId in currentGroupIds) {
      try {
        final groupDoc = await _db.collection('groups').doc(groupId).get();
        if (!groupDoc.exists) {
          continue;
        }
        final containsTarget = await _groupHasUserMembership(
          groupDoc,
          targetUid,
        );
        if (containsTarget) {
          resolved.add(groupDoc);
        }
      } catch (error) {
        debugPrint(
          '[UserProfileScreen][mutualGroups] failed to resolve groupId=$groupId targetUid=$targetUid error=$error',
        );
      }
    }

    resolved.sort((a, b) {
      final aData = a.data() ?? const <String, dynamic>{};
      final bData = b.data() ?? const <String, dynamic>{};
      final aCreated = (aData['createdAt'] as Timestamp?)?.toDate() ??
          DateTime.fromMillisecondsSinceEpoch(0);
      final bCreated = (bData['createdAt'] as Timestamp?)?.toDate() ??
          DateTime.fromMillisecondsSinceEpoch(0);
      return bCreated.compareTo(aCreated);
    });

    debugPrint(
      '[UserProfileScreen][mutualGroups] currentRoot=${currentRootIds.length} currentMembers=${currentMemberIds.length} currentChats=${currentChatIds.length} resolved=${resolved.length}',
    );

    return resolved;
  }

  Future<List<Map<String, String>>> _mutualFriends() async {
    final ids = <String>{};

    try {
      final currentUid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
      if (currentUid.isNotEmpty && currentUid != widget.uid.trim()) {
        final currentData = await _relationSourceDataForProfile(currentUid);
        final targetData = await _relationSourceDataForProfile(widget.uid);
        final currentFriends = _uidListFromData(currentData, 'friends').toSet();
        final targetFriends = _uidListFromData(targetData, 'friends').toSet();
        if (currentFriends.isNotEmpty && targetFriends.isNotEmpty) {
          ids.addAll(currentFriends.intersection(targetFriends));
        }
      }
    } catch (_) {}

    ids.addAll(await _socialService.mutualFriendIds(widget.uid));

    if (ids.isEmpty) {
      try {
        final currentUid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
        if (currentUid.isNotEmpty && currentUid != widget.uid.trim()) {
          final currentData = await _relationSourceDataForProfile(currentUid);
          final currentFollowing =
              _uidListFromData(currentData, 'following').toSet();
          final currentFollowers =
              _uidListFromData(currentData, 'followers').toSet();
          final currentFriends =
              currentFollowing.intersection(currentFollowers);

          final targetFollowers =
              (await _followersForProfile(widget.uid)).toSet();
          final targetFollowing =
              (await _followingForProfile(widget.uid)).toSet();
          final targetFriends = targetFollowers.intersection(targetFollowing);

          ids.addAll(currentFriends.intersection(targetFriends));
        }
      } catch (_) {}
    }

    if (ids.isEmpty) {
      return const <Map<String, String>>[];
    }

    final profiles = <Map<String, String>>[];
    for (final uid in ids) {
      final profile = await _publicUserProfileService.fetchProfile(uid);
      if (profile == null) {
        profiles.add({
          'uid': uid,
          'name': uid,
          'avatarUrl': '',
        });
        continue;
      }

      profiles.add({
        'uid': uid,
        'name': profile.displayName.isNotEmpty
            ? profile.displayName
            : (profile.username.isNotEmpty ? profile.username : uid),
        'avatarUrl': profile.profilePictureUrl,
      });
    }

    return profiles;
  }

  Future<void> _showMutualGroupsSheet() async {
    List<DocumentSnapshot<Map<String, dynamic>>> groups;
    try {
      groups = await _mutualGroups();
    } catch (error) {
      debugPrint('[UserProfileScreen][mutualGroups] failed: $error');
      groups = const <DocumentSnapshot<Map<String, dynamic>>>[];
    }
    if (!mounted) return;

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Theme.of(context).brightness == Brightness.light
          ? Colors.white
          : const Color(0xFF151D2A),
      builder: (context) {
        final isLight = Theme.of(context).brightness == Brightness.light;
        if (groups.isEmpty) {
          return _buildSheetEmptyState('אין קבוצות משותפות כרגע');
        }

        return _buildSheetList(
          title: 'קבוצות משותפות',
          children: groups.map((doc) {
            final data = doc.data() ?? const <String, dynamic>{};
            final name = (data['groupName'] as String? ?? 'קבוצה').trim();
            final description = (data['description'] as String? ?? '').trim();
            final imageUrl = (data['groupImageUrl'] as String? ?? '').trim();
            return ListTile(
              onTap: () {
                Navigator.of(context).pop();
                _openGroupChatFromProfile(
                  groupId: doc.id,
                  groupName: name,
                  imageUrl: imageUrl,
                );
              },
              leading: const CircleAvatar(
                  backgroundColor: Color(0xFF9E7CFF),
                  child: Icon(Icons.groups_rounded, color: Colors.black)),
              title: Text(name,
                  style: TextStyle(
                      color: isLight ? Colors.black : Colors.white,
                      fontWeight: FontWeight.w600)),
              subtitle: description.isNotEmpty
                  ? Text(
                      description,
                      style: TextStyle(
                        color: isLight ? Colors.black54 : Colors.grey[400],
                      ),
                    )
                  : null,
            );
          }).toList(growable: false),
        );
      },
    );
  }

  Future<List<DocumentSnapshot<Map<String, dynamic>>>>
      _publicGroupsOfUser() async {
    final targetUid = widget.uid.trim();

    final byId = <String, DocumentSnapshot<Map<String, dynamic>>>{};

    List<QueryDocumentSnapshot<Map<String, dynamic>>> chatDocs =
        const <QueryDocumentSnapshot<Map<String, dynamic>>>[];
    try {
      final snapshot = await _db
          .collection('chats')
          .where('isPublic', isEqualTo: true)
          .where('participants', arrayContains: targetUid)
          .get();
      chatDocs = snapshot.docs;
    } catch (_) {
      try {
        final allPublicChats = await _db
            .collection('chats')
            .where('isPublic', isEqualTo: true)
            .get();
        chatDocs = allPublicChats.docs.where((doc) {
          final participants = (doc.data()['participants'] as List<dynamic>? ??
                  const <dynamic>[])
              .map((value) => value.toString().trim())
              .where((value) => value.isNotEmpty)
              .toSet();
          return participants.contains(targetUid);
        }).toList(growable: false);
      } catch (error) {
        debugPrint(
          '[UserProfileScreen][publicGroups] failed to read chats for targetUid=$targetUid error=$error',
        );
      }
    }

    for (final chatDoc in chatDocs) {
      final chatData = chatDoc.data();
      final sourceGroupId = (chatData['sourceGroupId'] as String? ?? '').trim();
      final targetGroupId =
          sourceGroupId.isNotEmpty ? sourceGroupId : chatDoc.id;

      try {
        final groupDoc =
            await _db.collection('groups').doc(targetGroupId).get();
        if (groupDoc.exists) {
          byId[targetGroupId] = groupDoc;
          continue;
        }
      } catch (_) {}

      byId[targetGroupId] = chatDoc;
    }

    if (byId.isEmpty) {
      try {
        final groupsSnapshot = await _db
            .collection('groups')
            .where('isPublic', isEqualTo: true)
            .get();
        for (final doc in groupsSnapshot.docs) {
          if (await _groupHasUserMembership(doc, targetUid)) {
            byId[doc.id] = doc;
          }
        }
      } catch (error) {
        debugPrint(
          '[UserProfileScreen][publicGroups] groups fallback failed for targetUid=$targetUid error=$error',
        );
      }
    }

    final docs = byId.values.toList(growable: false);
    docs.sort((a, b) {
      final aData = a.data() ?? const <String, dynamic>{};
      final bData = b.data() ?? const <String, dynamic>{};
      final aCreated = (aData['createdAt'] as Timestamp?)?.toDate() ??
          DateTime.fromMillisecondsSinceEpoch(0);
      final bCreated = (bData['createdAt'] as Timestamp?)?.toDate() ??
          DateTime.fromMillisecondsSinceEpoch(0);
      return bCreated.compareTo(aCreated);
    });
    debugPrint(
      '[UserProfileScreen][publicGroups] chatCandidates=${chatDocs.length} resolved=${docs.length}',
    );
    return docs;
  }

  Future<Set<String>> _groupIdsFromMyChatParticipation() async {
    final currentUid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
    if (currentUid.isEmpty) {
      return const <String>{};
    }

    final ids = <String>{};
    try {
      final chats = await _db
          .collection('chats')
          .where('participants', arrayContains: currentUid)
          .get();
      for (final doc in chats.docs) {
        final data = doc.data();
        final sourceGroupId = (data['sourceGroupId'] as String? ?? '').trim();
        if (sourceGroupId.isNotEmpty) {
          ids.add(sourceGroupId);
        }
        final originType = (data['originType'] as String? ?? '').trim();
        if (originType == 'regular' || originType.isEmpty) {
          ids.add(doc.id);
        }
      }
    } catch (_) {}

    return ids;
  }

  Future<bool> _groupHasUserMembership(
    DocumentSnapshot<Map<String, dynamic>> groupDoc,
    String uid,
  ) async {
    final normalizedUid = uid.trim();
    if (normalizedUid.isEmpty) {
      return false;
    }

    final groupData = groupDoc.data() ?? const <String, dynamic>{};
    final adminUid = (groupData['adminUid'] as String? ?? '').trim();
    if (adminUid == normalizedUid) {
      return true;
    }

    final memberIds = _memberIdsFromGroupData(groupData).toSet();
    if (memberIds.contains(normalizedUid)) {
      return true;
    }

    bool isApprovedStatus(Map<String, dynamic> data) {
      final status = (data['status'] as String? ?? '').trim().toLowerCase();
      if (status.isEmpty) return true;
      const denied = <String>{
        'pending',
        'requested',
        'invited',
        'declined',
        'denied',
        'rejected',
        'blocked',
        'removed',
        'left',
      };
      return !denied.contains(status);
    }

    try {
      final memberDoc = await _db
          .collection('groups')
          .doc(groupDoc.id)
          .collection('members')
          .doc(normalizedUid)
          .get();
      if (!memberDoc.exists) {
        return false;
      }

      final memberData = memberDoc.data() ?? const <String, dynamic>{};
      if (isApprovedStatus(memberData)) {
        return true;
      }
    } catch (_) {}

    Future<bool> existsByMemberField(String fieldName) async {
      try {
        final snapshot = await _db
            .collection('groups')
            .doc(groupDoc.id)
            .collection('members')
            .where(fieldName, isEqualTo: normalizedUid)
            .limit(5)
            .get();
        for (final doc in snapshot.docs) {
          if (isApprovedStatus(doc.data())) {
            return true;
          }
        }
      } catch (_) {}
      return false;
    }

    if (await existsByMemberField('uid')) {
      return true;
    }
    if (await existsByMemberField('userId')) {
      return true;
    }
    if (await existsByMemberField('memberUid')) {
      return true;
    }

    try {
      final allMembers = await _db
          .collection('groups')
          .doc(groupDoc.id)
          .collection('members')
          .limit(500)
          .get();

      for (final member in allMembers.docs) {
        final data = member.data();
        final candidateIds = <String>{
          member.id.trim(),
          (data['uid'] as String? ?? '').trim(),
          (data['userId'] as String? ?? '').trim(),
          (data['memberUid'] as String? ?? '').trim(),
        }..removeWhere((value) => value.isEmpty);

        if (candidateIds.contains(normalizedUid) && isApprovedStatus(data)) {
          return true;
        }
      }
    } catch (_) {}

    try {
      final chatDoc = await _db.collection('chats').doc(groupDoc.id).get();
      final chatData = chatDoc.data() ?? const <String, dynamic>{};
      final participants =
          ((chatData['participants'] as List<dynamic>?) ?? const <dynamic>[])
              .map((value) => value.toString().trim())
              .where((value) => value.isNotEmpty)
              .toSet();
      if (participants.contains(normalizedUid)) {
        return true;
      }
    } catch (_) {}

    return false;
  }

  Future<Set<String>> _groupIdsFromMembershipSubcollection(String uid) async {
    final normalizedUid = uid.trim();
    if (normalizedUid.isEmpty) {
      return const <String>{};
    }

    final groupIds = <String>{};

    void collectApprovedGroupIds(
      QuerySnapshot<Map<String, dynamic>> snapshot,
    ) {
      for (final doc in snapshot.docs) {
        final data = doc.data();
        final status = (data['status'] as String? ?? '').trim();
        if (status.isNotEmpty && status != 'approved') {
          continue;
        }
        final groupId = doc.reference.parent.parent?.id.trim() ?? '';
        if (groupId.isNotEmpty) {
          groupIds.add(groupId);
        }
      }
    }

    try {
      final byUidField = await _db
          .collectionGroup('members')
          .where('uid', isEqualTo: normalizedUid)
          .get();
      collectApprovedGroupIds(byUidField);
    } catch (_) {}

    try {
      final byUserIdField = await _db
          .collectionGroup('members')
          .where('userId', isEqualTo: normalizedUid)
          .get();
      collectApprovedGroupIds(byUserIdField);
    } catch (_) {}

    try {
      final byDocId = await _db
          .collectionGroup('members')
          .where(FieldPath.documentId, isEqualTo: normalizedUid)
          .get();
      collectApprovedGroupIds(byDocId);
    } catch (_) {}

    return groupIds;
  }

  List<String> _memberIdsFromGroupData(Map<String, dynamic> groupData) {
    final memberValues = <dynamic>[
      ...((groupData['membersList'] as List<dynamic>?) ?? const <dynamic>[]),
      ...((groupData['members'] as List<dynamic>?) ?? const <dynamic>[]),
      ...((groupData['participants'] as List<dynamic>?) ?? const <dynamic>[]),
    ];

    return memberValues
        .map((id) => id.toString().trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
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

    final now = DateTime.now();
    final diff = now.difference(dateTime);
    if (diff.inMinutes < 60) {
      return 'לפני ${diff.inMinutes} דקות';
    }
    if (diff.inHours < 24) {
      return 'לפני ${diff.inHours} שעות';
    }
    if (diff.inDays < 7) {
      return 'לפני ${diff.inDays} ימים';
    }

    final day = dateTime.day.toString().padLeft(2, '0');
    final month = dateTime.month.toString().padLeft(2, '0');
    final year = dateTime.year.toString();
    return '$day/$month/$year';
  }

  Future<void> _openGroupChatFromProfile({
    required String groupId,
    required String groupName,
    required String imageUrl,
  }) async {
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatRoomScreen(
          chatName: groupName,
          avatarUrl: imageUrl.isEmpty ? null : imageUrl,
          chatId: groupId,
          isDirectChat: false,
        ),
      ),
    );
  }

  Future<List<Map<String, String>>> _friendsInGroup(
      Map<String, dynamic> groupData) async {
    final currentUid = FirebaseAuth.instance.currentUser?.uid;
    if (currentUid == null || currentUid.isEmpty) {
      return const <Map<String, String>>[];
    }

    final userDoc = await _db.collection('users').doc(currentUid).get();
    final userData = userDoc.data() ?? <String, dynamic>{};
    final friendsRaw =
        (userData['friends'] as List<dynamic>?) ?? const <dynamic>[];
    final followingRaw =
        (userData['following'] as List<dynamic>?) ?? const <dynamic>[];
    final myFriendIds = (friendsRaw.isNotEmpty ? friendsRaw : followingRaw)
        .map((value) => value.toString().trim())
        .where((value) => value.isNotEmpty)
        .toSet();

    if (myFriendIds.isEmpty) {
      return const <Map<String, String>>[];
    }

    final memberIds = _memberIdsFromGroupData(groupData).toSet();
    final mutualIds =
        memberIds.where((uid) => myFriendIds.contains(uid)).toList();
    if (mutualIds.isEmpty) {
      return const <Map<String, String>>[];
    }

    final items = <Map<String, String>>[];
    for (final uid in mutualIds) {
      final profile = await _publicUserProfileService.fetchProfile(uid);
      final name = (profile?.displayName ?? '').trim().isNotEmpty
          ? profile!.displayName
          : ((profile?.username ?? '').trim().isNotEmpty
              ? profile!.username
              : uid);
      items.add({
        'uid': uid,
        'name': name,
        'avatarUrl': (profile?.profilePictureUrl ?? '').trim(),
      });
    }

    return items;
  }

  Future<void> _showPublicGroupDetailsDialog(
      Map<String, dynamic> groupData) async {
    final groupName = (groupData['groupName'] as String? ?? 'קבוצה').trim();
    final category =
        ((groupData['category'] as String?) ?? kGeneralCategory).trim();
    final subCategory = (groupData['subCategory'] as String? ?? '').trim();
    final location = (groupData['location'] as String? ?? '').trim();
    final date = (groupData['date'] as Timestamp?)?.toDate();
    final createdAt = (groupData['createdAt'] as Timestamp?)?.toDate();
    final ageRange = (groupData['ageRange'] as Map<String, dynamic>?) ??
        const <String, dynamic>{};
    final minAge = (ageRange['min'] as num?)?.toInt();
    final maxAge = (ageRange['max'] as num?)?.toInt();
    final membersCount = (groupData['membersCount'] as num?)?.toInt() ??
        _memberIdsFromGroupData(groupData).length;
    final approvalRequired =
        (groupData['isAdminApprovalRequired'] as bool?) ?? false;

    await showDialog<void>(
      context: context,
      barrierColor: Colors.black54,
      builder: (dialogContext) {
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
              gradient: const LinearGradient(
                colors: [Color(0xFF53C1F9), Color(0xFF9E7CFF)],
              ),
            ),
            padding: const EdgeInsets.all(1.8),
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFF111A28),
                borderRadius: BorderRadius.circular(22),
              ),
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.info_outline_rounded,
                          color: Color(0xFF53C1F9)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'פרטים נוספים • $groupName',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Expanded(
                    child: SingleChildScrollView(
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _profileGroupInfoCard(
                            icon: Icons.event_outlined,
                            title: 'תאריך',
                            value: _formatDateTime(date),
                            accent: const Color(0xFF53C1F9),
                          ),
                          _profileGroupInfoCard(
                            icon: Icons.location_on_outlined,
                            title: 'מיקום מפגש',
                            value: location.isEmpty ? 'לא צוין' : location,
                            accent: const Color(0xFF9E7CFF),
                          ),
                          _profileGroupInfoCard(
                            icon: categoryIconFor(
                                category.isEmpty ? kGeneralCategory : category),
                            title: 'קטגוריה',
                            value:
                                category.isEmpty ? kGeneralCategory : category,
                            accent: const Color(0xFF5BE2C3),
                          ),
                          _profileGroupInfoCard(
                            icon: Icons.subdirectory_arrow_right_rounded,
                            title: 'תת קטגוריה',
                            value: subCategory.isEmpty ? 'ללא' : subCategory,
                            accent: const Color(0xFFF7B955),
                          ),
                          _profileGroupInfoCard(
                            icon: Icons.group_outlined,
                            title: 'מספר חברים',
                            value: '$membersCount',
                            accent: const Color(0xFF53C1F9),
                          ),
                          _profileGroupInfoCard(
                            icon: Icons.lock_clock_outlined,
                            title: 'מתי נפתחה',
                            value: _formatOpenedAt(createdAt),
                            accent: const Color(0xFF9E7CFF),
                          ),
                          _profileGroupInfoCard(
                            icon: Icons.cake_outlined,
                            title: 'טווח גילאים',
                            value: (minAge == null || maxAge == null)
                                ? 'לא הוגדר'
                                : '$minAge-$maxAge',
                            accent: const Color(0xFF5BE2C3),
                          ),
                          _profileGroupInfoCard(
                            icon: Icons.verified_user_outlined,
                            title: 'אישור מנהל',
                            value: approvalRequired
                                ? 'נדרש אישור מנהל'
                                : 'אין צורך באישור',
                            accent: const Color(0xFFF7B955),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 42,
                    child: ElevatedButton(
                      onPressed: () => Navigator.of(dialogContext).pop(),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF9E7CFF),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: const Text('סגור',
                          style: TextStyle(fontWeight: FontWeight.w700)),
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

  Widget _profileGroupInfoCard({
    required IconData icon,
    required String title,
    required String value,
    required Color accent,
  }) {
    return SizedBox(
      width: 190,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: const Color(0xFF1A2435),
          borderRadius: BorderRadius.circular(12),
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
                    style: const TextStyle(
                      color: Color(0xFFB6C0D0),
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
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showParticipantFriendsInGroupDialog(
      Map<String, dynamic> groupData) async {
    final friends = await _friendsInGroup(groupData);
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      barrierColor: Colors.black54,
      builder: (dialogContext) {
        final dialogSize = MediaQuery.of(dialogContext).size;
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 22, vertical: 28),
          child: Container(
            constraints: BoxConstraints(
              maxWidth: dialogSize.width * 0.9,
              maxHeight: dialogSize.height * 0.78,
            ),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              gradient: const LinearGradient(
                colors: [Color(0xFF53C1F9), Color(0xFF9E7CFF)],
              ),
            ),
            padding: const EdgeInsets.all(1.6),
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFF111A28),
                borderRadius: BorderRadius.circular(20),
              ),
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'חברים שלך שמשתתפים',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                    ),
                    textAlign: TextAlign.right,
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: friends.isEmpty
                        ? const Center(
                            child: Text(
                              'אין חברים שלך שמשתתפים בקבוצה הזו כרגע',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 14,
                              ),
                            ),
                          )
                        : ListView.builder(
                            itemCount: friends.length,
                            itemBuilder: (context, index) {
                              final friend = friends[index];
                              final friendName = friend['name'] ?? 'חבר';
                              final avatarUrl = friend['avatarUrl'] ?? '';
                              return Container(
                                margin: const EdgeInsets.only(bottom: 8),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 8),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF1E2632),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: const Color(0xFF53C1F9)
                                        .withValues(alpha: 0.25),
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    CircleAvatar(
                                      radius: 16,
                                      backgroundColor: const Color(0xFF9E7CFF),
                                      backgroundImage: avatarUrl.isNotEmpty
                                          ? NetworkImage(avatarUrl)
                                          : null,
                                      child: avatarUrl.isEmpty
                                          ? Text(
                                              friendName.characters.first,
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontWeight: FontWeight.w700,
                                              ),
                                            )
                                          : null,
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(
                                        friendName,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 40,
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(dialogContext).pop(),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Color(0xFF53C1F9)),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text('סגור'),
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

  Future<void> _joinPublicGroupFromProfile(String groupId) async {
    try {
      final groupSnapshot = await _db.collection('groups').doc(groupId).get();
      final groupData = groupSnapshot.data() ?? <String, dynamic>{};
      final approvalRequired =
          (groupData['isAdminApprovalRequired'] as bool?) ?? false;

      await _groupService.joinGroup(groupId);
      if (!mounted) return;

      if (approvalRequired) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('בקשת ההצטרפות נשלחה למנהל הקבוצה')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('הצטרפת לקבוצה בהצלחה!')),
        );
      }
    } catch (error, stackTrace) {
      if (error is FirebaseException) {
        debugPrint(
          '[UserProfileScreen][joinPublicGroup] FirebaseException code=${error.code} plugin=${error.plugin} message=${error.message} groupId=$groupId',
        );
      } else {
        debugPrint(
          '[UserProfileScreen][joinPublicGroup] error=${error.runtimeType} value=$error groupId=$groupId',
        );
      }
      debugPrint('[UserProfileScreen][joinPublicGroup] stackTrace=$stackTrace');

      if (!mounted) return;
      final joinErrorMessage = _friendlyJoinErrorMessage(error);
      final isRequirementError = error is GroupJoinException;

      if (isRequirementError) {
        _showJoinRequirementMessageOverlay(joinErrorMessage);
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: Colors.transparent,
          elevation: 0,
          content: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xFF2A1622),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                  color: const Color(0xFFFF6B9E).withValues(alpha: 0.55)),
            ),
            child: Text(
              joinErrorMessage,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      );
    }
  }

  void _showJoinRequirementMessageOverlay(String message) {
    if (!mounted) return;

    showDialog<void>(
      context: context,
      useRootNavigator: true,
      barrierDismissible: true,
      barrierColor: Colors.black38,
      builder: (dialogContext) {
        Future<void>.delayed(const Duration(seconds: 3), () {
          if (!mounted || !dialogContext.mounted) {
            return;
          }
          final navigator = Navigator.of(dialogContext, rootNavigator: true);
          if (navigator.canPop()) {
            navigator.pop();
          }
        });

        return Dialog(
          backgroundColor: Colors.transparent,
          elevation: 0,
          insetPadding: const EdgeInsets.symmetric(horizontal: 22),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: const Color(0xFF2A1622),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: const Color(0xFFFF6B9E).withValues(alpha: 0.62),
              ),
            ),
            child: Text(
              message,
              textDirection: TextDirection.rtl,
              textAlign: TextAlign.right,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 14,
              ),
            ),
          ),
        );
      },
    );
  }

  String _friendlyJoinErrorMessage(Object error) {
    if (error is GroupJoinException) {
      if (error.code == 'insufficient-score' && error.minScore != null) {
        final current = error.userScore ?? 0;
        return 'לא ניתן להצטרף לקבוצה. נדרש מינימום ${error.minScore} נקודות (הניקוד שלך: $current).';
      }
      return error.message;
    }

    if (error is FirebaseException) {
      if (error.code == 'permission-denied') {
        return 'אין הרשאה להצטרף לקבוצה זו כרגע.';
      }
      if (error.code == 'not-found') {
        return 'הקבוצה לא נמצאה.';
      }
      return 'ההצטרפות נכשלה. נסה שוב בעוד רגע.';
    }

    final raw = error.toString();
    if (raw.contains('insufficient-score')) {
      return 'לא ניתן להצטרף לקבוצה כי הניקוד שלך נמוך מהמינימום הנדרש.';
    }
    return 'ההצטרפות נכשלה. נסה שוב בעוד רגע.';
  }

  Widget _buildPublicGroupCardInProfile(
      DocumentSnapshot<Map<String, dynamic>> doc) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final data = doc.data() ?? const <String, dynamic>{};
    final groupName =
        (data['groupName'] as String? ?? data['name'] as String? ?? 'קבוצה')
            .trim();
    final description = (data['description'] as String? ?? '').trim();
    final imageUrl = (data['groupImageUrl'] as String? ?? '').trim();
    final mainCategory = ((data['category'] as String?) ??
            (data['mainCategory'] as String?) ??
            kGeneralCategory)
        .trim();
    final subCategory = ((data['subCategory'] as String?) ?? '').trim();
    final categoryLabel =
        mainCategory.isEmpty ? kGeneralCategory : mainCategory;
    final sourceGroupId = (data['sourceGroupId'] as String? ?? '').trim();
    final targetGroupId = sourceGroupId.isNotEmpty ? sourceGroupId : doc.id;
    final memberIds = _memberIdsFromGroupData(data);
    final memberCount = (data['membersCount'] as num?)?.toInt() ??
        (memberIds.isNotEmpty
            ? memberIds.length
            : ((data['participants'] as List<dynamic>?) ?? const <dynamic>[])
                .length);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isLight
            ? Colors.white.withValues(alpha: 0.82)
            : const Color(0xFF1E2632),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isLight
              ? const Color(0xFFA9C3FF)
              : const Color(0xFF53C1F9).withValues(alpha: 0.2),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: const Color(0xFF9E7CFF),
                backgroundImage:
                    imageUrl.isNotEmpty ? NetworkImage(imageUrl) : null,
                child: imageUrl.isEmpty
                    ? Text(
                        groupName.isNotEmpty ? groupName.characters.first : 'G',
                        style: const TextStyle(
                            color: Colors.black, fontWeight: FontWeight.w700),
                      )
                    : null,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      groupName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: isLight ? Colors.black : Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                    ),
                    if (description.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        description,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: isLight ? Colors.black54 : Colors.grey[400],
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 9),
          Row(
            children: [
              Container(
                width: 22,
                height: 22,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: [Color(0xFF53C1F9), Color(0xFF9E7CFF)],
                  ),
                ),
                child: Icon(
                  categoryIconFor(categoryLabel),
                  size: 14,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  subCategory.isEmpty
                      ? '$categoryLabel • ללא תת קטגוריה'
                      : '$categoryLabel • $subCategory',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: isLight ? Colors.black87 : const Color(0xFFD1D7E4),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: isLight
                      ? const Color(0xFFEFF5FF)
                      : const Color(0xFF0F1522),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: isLight
                        ? const Color(0xFFA9C3FF)
                        : const Color(0xFF53C1F9).withValues(alpha: 0.28),
                  ),
                ),
                child: Text(
                  '$memberCount חברים',
                  style: TextStyle(
                    color: isLight ? Colors.black87 : Colors.grey[300],
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              OutlinedButton.icon(
                onPressed: () => _showPublicGroupDetailsDialog(data),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF53C1F9),
                  side: BorderSide(
                      color: const Color(0xFF53C1F9).withValues(alpha: 0.7)),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                icon: const Icon(Icons.info_outline_rounded, size: 16),
                label: const Text(
                  'פרטים נוספים',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                ),
              ),
              OutlinedButton.icon(
                onPressed: () => _showParticipantFriendsInGroupDialog(data),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFFB6A3FF),
                  side: BorderSide(
                      color: const Color(0xFF9E7CFF).withValues(alpha: 0.7)),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                icon: const Icon(Icons.people_alt_outlined, size: 16),
                label: const Text(
                  'חברים משתתפים',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                ),
              ),
              StreamBuilder<String?>(
                stream: _groupService.myMembershipStatus(targetGroupId),
                builder: (context, statusSnapshot) {
                  final status = statusSnapshot.data;
                  final isPending = status == 'pending';
                  final isApproved = status == 'approved';

                  final currentUid = FirebaseAuth.instance.currentUser?.uid;
                  final isAlreadyMember = currentUid != null &&
                      currentUid.isNotEmpty &&
                      memberIds.contains(currentUid);
                  final canViewGroup = isApproved || isAlreadyMember;

                  String label = 'הצטרף';
                  Color backgroundColor = const Color(0xFF9E7CFF);
                  VoidCallback? onPressed =
                      () => _joinPublicGroupFromProfile(targetGroupId);

                  if (isPending) {
                    label = 'בקשתך נשלחה';
                    backgroundColor = Colors.orange;
                    onPressed = null;
                  } else if (canViewGroup) {
                    label = 'צפה בקבוצה';
                    backgroundColor = const Color(0xFF53C1F9);
                    onPressed = () => _openGroupChatFromProfile(
                          groupId: targetGroupId,
                          groupName: groupName,
                          imageUrl: imageUrl,
                        );
                  }

                  return ElevatedButton(
                    onPressed: onPressed,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: backgroundColor,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: Text(
                      label,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _showPublicGroupsSheet() async {
    List<DocumentSnapshot<Map<String, dynamic>>> groups;
    try {
      groups = await _publicGroupsOfUser();
    } catch (_) {
      groups = const <DocumentSnapshot<Map<String, dynamic>>>[];
    }
    if (!mounted) return;

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Theme.of(context).brightness == Brightness.light
          ? Colors.white
          : const Color(0xFF151D2A),
      isScrollControlled: true,
      builder: (context) {
        if (groups.isEmpty) {
          return _buildSheetEmptyState('המשתמש עדיין לא חבר בקבוצות ציבוריות');
        }

        return Directionality(
          textDirection: TextDirection.rtl,
          child: FractionallySizedBox(
            heightFactor: 0.75,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        IconButton(
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(Icons.close_rounded),
                        ),
                        const Expanded(
                          child: Text(
                            'קבוצות ציבוריות',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        const SizedBox(width: 48),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: ListView.builder(
                        itemCount: groups.length,
                        itemBuilder: (context, index) {
                          return _buildPublicGroupCardInProfile(groups[index]);
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

  Future<void> _showMutualFriendsSheet() async {
    List<Map<String, String>> friends;
    try {
      friends = await _mutualFriends();
    } catch (_) {
      friends = const <Map<String, String>>[];
    }
    if (!mounted) return;

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Theme.of(context).brightness == Brightness.light
          ? Colors.white
          : const Color(0xFF151D2A),
      builder: (context) {
        if (friends.isEmpty) {
          return _buildSheetEmptyState('אין חברים משותפים כרגע');
        }

        return Directionality(
          textDirection: TextDirection.rtl,
          child: _buildSheetList(
            title: 'חברים משותפים',
            children: friends.map((friend) {
              final avatarUrl = friend['avatarUrl'] ?? '';
              final name = friend['name'] ?? friend['uid'] ?? 'משתמש';
              final uid = friend['uid'] ?? '';
              return ListTile(
                onTap: uid.trim().isEmpty
                    ? null
                    : () {
                        Navigator.of(context).pop();
                        _openProfileFromSheet(uid);
                      },
                leading: CircleAvatar(
                  backgroundColor: const Color(0xFF9E7CFF),
                  backgroundImage:
                      avatarUrl.isNotEmpty ? NetworkImage(avatarUrl) : null,
                  child: avatarUrl.isEmpty
                      ? Text(name.characters.first,
                          style: const TextStyle(color: Colors.black))
                      : null,
                ),
                title: Text(
                  name,
                  textAlign: TextAlign.right,
                  style: TextStyle(
                      color: Theme.of(context).brightness == Brightness.light
                          ? Colors.black
                          : Colors.white,
                      fontWeight: FontWeight.w600),
                ),
              );
            }).toList(growable: false),
          ),
        );
      },
    );
  }

  Widget _buildSheetList(
      {required String title, required List<Widget> children}) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title,
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: isLight ? Colors.black : Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: children,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSheetEmptyState(String message) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: isLight ? Colors.black54 : Colors.grey[300],
            fontSize: 15,
          ),
        ),
      ),
    );
  }

  Future<void> _reportUserProfile() async {
    final currentUid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
    final targetUid = widget.uid.trim();
    if (currentUid.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('יש להתחבר כדי לדווח.')),
      );
      return;
    }
    if (targetUid.isEmpty || targetUid == currentUid) {
      return;
    }

    final shouldReport = await showReportConfirmationDialog(
      context,
      targetLabel: 'משתמש',
    );
    if (!shouldReport || !mounted) {
      return;
    }

    final reason = await showReportReasonPicker(
      context,
      targetLabel: 'משתמש',
    );
    if (reason == null || !mounted) {
      return;
    }

    final details = await showReportDetailsDialog(
      context,
      reason: reason,
      targetLabel: 'משתמש',
    );
    if (details == null || !mounted) {
      return;
    }

    try {
      await _reportService.submitUserReport(
        targetUserUid: targetUid,
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

  Future<void> _toggleUserBlock(bool isBlockedByMe) async {
    final targetUid = widget.uid.trim();
    if (targetUid.isEmpty) {
      return;
    }

    final shouldProceed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) {
            return Directionality(
              textDirection: TextDirection.rtl,
              child: AlertDialog(
                title: Text(isBlockedByMe ? 'ביטול חסימה' : 'חסימת משתמש'),
                content: Text(
                  isBlockedByMe
                      ? 'לבטל את החסימה למשתמש הזה?'
                      : 'המשתמש ייחסם, הצ\'אט הישיר ביניכם יוסר ולא תוכלו לתקשר בפרטי. להמשיך?',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(dialogContext).pop(false),
                    child: const Text('ביטול'),
                  ),
                  ElevatedButton(
                    onPressed: () => Navigator.of(dialogContext).pop(true),
                    child: Text(isBlockedByMe ? 'בטל חסימה' : 'חסום'),
                  ),
                ],
              ),
            );
          },
        ) ??
        false;

    if (!shouldProceed) {
      return;
    }

    try {
      if (isBlockedByMe) {
        await _blockUserService.unblockUser(targetUid);
      } else {
        await _blockUserService.blockUser(targetUid);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isBlockedByMe ? 'החסימה בוטלה בהצלחה.' : 'המשתמש נחסם בהצלחה.',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('הפעולה נכשלה: $error')),
      );
    }
  }

  Future<void> _showSafetyActionsMenu() async {
    final currentUid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
    final targetUid = widget.uid.trim();
    if (currentUid.isEmpty || targetUid.isEmpty || currentUid == targetUid) {
      return;
    }

    final isBlockedByMe = await _blockUserService.isBlockedByMe(targetUid);
    if (!mounted) {
      return;
    }

    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Theme.of(context).brightness == Brightness.light
          ? Colors.white
          : const Color(0xFF161F2E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (sheetContext) {
        return Directionality(
          textDirection: TextDirection.rtl,
          child: SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(Icons.flag_outlined),
                  title: const Text('דיווח על משתמש'),
                  onTap: () => Navigator.of(sheetContext).pop('report'),
                ),
                ListTile(
                  leading: Icon(
                    isBlockedByMe
                        ? Icons.lock_open_rounded
                        : Icons.block_rounded,
                    color: isBlockedByMe
                        ? const Color(0xFF53C1F9)
                        : Colors.redAccent,
                  ),
                  title: Text(isBlockedByMe ? 'בטל חסימה' : 'חסום משתמש'),
                  onTap: () => Navigator.of(sheetContext).pop('block'),
                ),
              ],
            ),
          ),
        );
      },
    );

    if (!mounted || action == null) {
      return;
    }

    if (action == 'report') {
      await _reportUserProfile();
      return;
    }

    if (action == 'block') {
      await _toggleUserBlock(isBlockedByMe);
    }
  }

  Widget _buildActionButtons(Map<String, dynamic> profileData) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    const quickMessageSurface = Color(0xFF0F1522);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Row(
                children: [
                  InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => _openDirectChat(profileData),
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: isLight ? Colors.white : quickMessageSurface,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color:
                              const Color(0xFF53C1F9).withValues(alpha: 0.55),
                        ),
                      ),
                      child: const Icon(
                        Icons.chat_bubble_outline_rounded,
                        color: Color(0xFF53C1F9),
                        size: 18,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Container(
                      height: 44,
                      alignment: Alignment.center,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: isLight ? Colors.white : quickMessageSurface,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color:
                              const Color(0xFF53C1F9).withValues(alpha: 0.55),
                        ),
                      ),
                      child: TextField(
                        controller: _quickMessageController,
                        focusNode: _quickMessageFocusNode,
                        enabled: !_isQuickMessageSending,
                        textDirection: TextDirection.rtl,
                        textAlign: TextAlign.right,
                        textAlignVertical: TextAlignVertical.center,
                        textInputAction: TextInputAction.send,
                        onTap: () {
                          _logQuickMessage('input_tap');
                        },
                        onChanged: (value) {
                          _quickMessageChangeSeq += 1;
                          _quickMessageTypingDebounce?.cancel();
                          _quickMessageTypingDebounce =
                              Timer(const Duration(milliseconds: 250), () {
                            _logQuickMessage(
                              'input_changed seq=$_quickMessageChangeSeq textLen=${value.length}',
                            );
                          });
                        },
                        onSubmitted: (_) =>
                            _sendQuickMessageToProfileChat(profileData),
                        style: TextStyle(
                          color: isLight ? Colors.black : Colors.white,
                        ),
                        decoration: InputDecoration(
                          border: InputBorder.none,
                          contentPadding:
                              const EdgeInsets.symmetric(vertical: 11),
                          hintText: 'שלח/י הודעה',
                          hintStyle: TextStyle(
                            color: isLight ? Colors.black54 : Colors.white54,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: _isQuickMessageSending
                        ? null
                        : () => _sendQuickMessageToProfileChat(profileData),
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: isLight ? Colors.white : quickMessageSurface,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color:
                              const Color(0xFF53C1F9).withValues(alpha: 0.55),
                        ),
                      ),
                      child: Center(
                        child: _isQuickMessageSending
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Color(0xFF9E7CFF),
                                ),
                              )
                            : const Icon(Icons.send_rounded,
                                color: Color(0xFF9E7CFF)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        StreamBuilder<FollowRelationship>(
          stream: _followRelationshipStream,
          builder: (context, snapshot) {
            final relationship = snapshot.data ?? const FollowRelationship();
            final isFollowing = relationship.isFollowing;
            final isRequestPending = relationship.isRequestPending;
            return SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _isFollowActionInFlight
                    ? null
                    : () async {
                        if (isFollowing) {
                          final shouldUnfollow = await showDialog<bool>(
                                context: context,
                                builder: (dialogContext) {
                                  final isDialogLight =
                                      Theme.of(dialogContext).brightness ==
                                          Brightness.light;
                                  return AlertDialog(
                                    backgroundColor: isDialogLight
                                        ? Colors.white
                                        : const Color(0xFF161F2E),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(16),
                                      side: BorderSide(
                                        color: isDialogLight
                                            ? const Color(0xFFA9C3FF)
                                            : Colors.transparent,
                                      ),
                                    ),
                                    title: Text(
                                      'אישור הסרת מעקב',
                                      style: TextStyle(
                                        color: isDialogLight
                                            ? Colors.black
                                            : Colors.white,
                                      ),
                                      textAlign: TextAlign.right,
                                    ),
                                    content: Text(
                                      'האם אתה בטוח שאתה רוצה להוריד עוקב?',
                                      style: TextStyle(
                                        color: isDialogLight
                                            ? Colors.black87
                                            : Colors.white70,
                                      ),
                                      textAlign: TextAlign.right,
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.of(dialogContext)
                                                .pop(false),
                                        child: const Text('ביטול'),
                                      ),
                                      ElevatedButton(
                                        onPressed: () =>
                                            Navigator.of(dialogContext)
                                                .pop(true),
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: isDialogLight
                                              ? Colors.white
                                              : const Color(0xFF9E7CFF),
                                          foregroundColor: isDialogLight
                                              ? const Color(0xFF9E7CFF)
                                              : Colors.white,
                                          side: isDialogLight
                                              ? const BorderSide(
                                                  color: Color(0xFF9E7CFF),
                                                )
                                              : BorderSide.none,
                                        ),
                                        child: const Text('אישור'),
                                      ),
                                    ],
                                  );
                                },
                              ) ??
                              false;

                          if (!shouldUnfollow) {
                            return;
                          }
                        } else if (isRequestPending) {
                          final shouldCancel = await showDialog<bool>(
                                context: context,
                                builder: (dialogContext) {
                                  final isDialogLight =
                                      Theme.of(dialogContext).brightness ==
                                          Brightness.light;
                                  return AlertDialog(
                                    backgroundColor: isDialogLight
                                        ? Colors.white
                                        : const Color(0xFF161F2E),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(16),
                                    ),
                                    title: Text(
                                      'ביטול בקשת מעקב',
                                      style: TextStyle(
                                        color: isDialogLight
                                            ? Colors.black
                                            : Colors.white,
                                      ),
                                      textAlign: TextAlign.right,
                                    ),
                                    content: Text(
                                      'לבטל את בקשת המעקב שנשלחה?',
                                      style: TextStyle(
                                        color: isDialogLight
                                            ? Colors.black87
                                            : Colors.white70,
                                      ),
                                      textAlign: TextAlign.right,
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.of(dialogContext)
                                                .pop(false),
                                        child: const Text('ביטול'),
                                      ),
                                      ElevatedButton(
                                        onPressed: () =>
                                            Navigator.of(dialogContext)
                                                .pop(true),
                                        child: const Text('אישור'),
                                      ),
                                    ],
                                  );
                                },
                              ) ??
                              false;
                          if (!shouldCancel) {
                            return;
                          }
                        }

                        var followersDelta = 0;
                        if (isFollowing) {
                          followersDelta = -1;
                        }
                        setState(() {
                          _isFollowActionInFlight = true;
                          _optimisticFollowersAdjustment += followersDelta;
                        });

                        try {
                          if (isFollowing) {
                            await _socialService.unfollowUser(widget.uid);
                          } else if (isRequestPending) {
                            await _socialService
                                .cancelFollowRequest(widget.uid);
                          } else {
                            final result =
                                await _socialService.followUser(widget.uid);
                            if (result == FollowActionResult.followed) {
                              if (!mounted) return;
                              setState(() {
                                _optimisticFollowersAdjustment += 1;
                              });
                            }
                          }
                        } catch (error) {
                          if (!mounted) return;
                          setState(() {
                            _optimisticFollowersAdjustment -= followersDelta;
                          });
                          ScaffoldMessenger.of(this.context).showSnackBar(
                            SnackBar(content: Text('עדכון מעקב נכשל: $error')),
                          );
                        } finally {
                          if (mounted) {
                            setState(() {
                              _isFollowActionInFlight = false;
                            });
                          }
                        }
                      },
                icon: Icon(
                  isFollowing
                      ? Icons.check_circle_outline_rounded
                      : (isRequestPending
                          ? Icons.schedule_rounded
                          : Icons.person_add_alt_1_rounded),
                  size: 18,
                ),
                label: Text(
                  isFollowing
                      ? 'עוקב'
                      : (isRequestPending ? 'בקשה נשלחה' : 'עקוב'),
                ),
                style: ElevatedButton.styleFrom(
                  elevation: 0,
                  backgroundColor: isFollowing
                      ? (isLight ? Colors.white : const Color(0xFF2A3A52))
                      : (isRequestPending
                          ? (isLight
                              ? const Color(0xFFE3ECF2)
                              : const Color(0xFF3A4B57))
                          : (isLight ? Colors.white : const Color(0xFF9E7CFF))),
                  foregroundColor:
                      isLight ? const Color(0xFF9E7CFF) : Colors.white,
                  side: isLight
                      ? const BorderSide(color: Color(0xFF9E7CFF))
                      : BorderSide.none,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _buildEdgeIconRelationButton(
                label: 'קבוצות ציבוריות',
                icon: Icons.public_rounded,
                onPressed: _showPublicGroupsSheet,
                borderColor: const Color(0xFF53C1F9).withValues(alpha: 0.75),
                isLight: isLight,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _buildEdgeIconRelationButton(
                label: 'קבוצות משותפות',
                icon: Icons.groups_2_rounded,
                onPressed: _showMutualGroupsSheet,
                borderColor: const Color(0xFF9E7CFF).withValues(alpha: 0.75),
                isLight: isLight,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _buildEdgeIconRelationButton(
                label: 'חברים משותפים',
                icon: Icons.people_alt_rounded,
                onPressed: _showMutualFriendsSheet,
                borderColor: const Color(0xFF53C1F9).withValues(alpha: 0.75),
                isLight: isLight,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildEdgeIconRelationButton({
    required String label,
    required IconData icon,
    required VoidCallback onPressed,
    required Color borderColor,
    required bool isLight,
  }) {
    return SizedBox(
      height: 52,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          Positioned.fill(
            child: OutlinedButton(
              onPressed: onPressed,
              style: OutlinedButton.styleFrom(
                alignment: Alignment.center,
                foregroundColor: isLight ? Colors.black : Colors.white,
                side: BorderSide(color: borderColor),
                backgroundColor:
                    isLight ? Colors.white : const Color(0xFF0F1522),
                padding:
                    const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              child: Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          Positioned(
            right: -6,
            top: -6,
            child: Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isLight ? Colors.white : const Color(0xFF0F1522),
                border: Border.all(color: borderColor, width: 1.2),
              ),
              child: Icon(
                icon,
                size: 13.5,
                color: isLight ? const Color(0xFF344055) : Colors.white70,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInteractiveRelationStat({
    required String label,
    required int value,
    required IconData icon,
    required VoidCallback onTap,
    required Color accent,
  }) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          height: 64,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: isLight ? Colors.white : const Color(0xFF162233),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isLight
                  ? const Color(0xFFA9C3FF)
                  : accent.withValues(alpha: 0.34),
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, color: accent, size: 14.5),
                  const SizedBox(width: 5),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: isLight ? Colors.black87 : Colors.grey[350],
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        height: 1.0,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 5),
              Text(
                _formatCompactCount(value),
                style: TextStyle(
                  color: isLight ? Colors.black : Colors.white,
                  fontSize: 15.5,
                  fontWeight: FontWeight.w800,
                  height: 1.0,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSoftProfileStatBubble({
    required String label,
    required String value,
    required IconData icon,
    VoidCallback? onTap,
  }) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final bubble = Container(
      height: 82,
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
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isLight
              ? const Color(0xFFA9C3FF)
              : const Color(0xFF53C1F9).withValues(alpha: 0.42),
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF53C1F9)
                .withValues(alpha: isLight ? 0.08 : 0.14),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
          if (isLight)
            BoxShadow(
              color: const Color(0xFF9E7CFF).withValues(alpha: 0.08),
              blurRadius: 12,
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
                Icon(
                  icon,
                  color: isLight
                      ? const Color(0xFF9AB0FF)
                      : const Color(0xFF9EDBFF),
                  size: 15,
                ),
                const SizedBox(width: 5),
                Text(
                  label,
                  style: TextStyle(
                    color: isLight ? Colors.black : Colors.grey[350],
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
                fontSize: 20,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );

    if (onTap == null) {
      return bubble;
    }

    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: bubble,
    );
  }

  Widget _buildHeader(
      Map<String, dynamic> profileData,
      int publishedCount,
      int postedSubCategoryCount,
      List<QueryDocumentSnapshot<Map<String, dynamic>>> allDocs,
      PublicUserProfile profile,
      {required bool canViewFriendsOnlyPosts}) {
    final displayName = _displayName(profileData);
    final username = _username(profileData);
    final bio = _bio(profileData);
    final profileImageUrl = _profileImageUrl(profileData);
    final profileImageUrls = _profileImageUrls(profileData);
    final serverFollowersCount =
        (profileData['followersCount'] as num?)?.toInt() ?? 0;
    final serverFollowingCount =
        (profileData['followingCount'] as num?)?.toInt() ?? 0;
    if (_lastServerFollowersCount != serverFollowersCount) {
      _lastServerFollowersCount = serverFollowersCount;
      if (_optimisticFollowersAdjustment != 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          setState(() {
            _optimisticFollowersAdjustment = 0;
          });
        });
      }
    }
    final storedScore = (profileData['score'] as num?)?.toInt() ?? 0;
    final livePublishedScore = allDocs
        .where((doc) =>
            _postAuthorId(doc.data()) == widget.uid &&
            _postStatus(doc.data()) == 'published')
        .fold<int>(0, (total, doc) => total + _postScore(doc.data()));
    final score =
        livePublishedScore > storedScore ? livePublishedScore : storedScore;
    final isLight = Theme.of(context).brightness == Brightness.light;
    final clampedPostedSubCategoryCount =
        postedSubCategoryCount.clamp(0, _subCategoryGoal);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 148,
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF53C1F9), Color(0xFF9E7CFF)],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
            borderRadius: BorderRadius.only(
              bottomLeft: Radius.circular(34),
              bottomRight: Radius.circular(34),
            ),
          ),
        ),
        Transform.translate(
          offset: const Offset(0, -58),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(26),
                    gradient: const LinearGradient(
                      colors: [Color(0xFF53C1F9), Color(0xFF9E7CFF)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x40204574),
                        blurRadius: 22,
                        offset: Offset(0, 12),
                      ),
                    ],
                  ),
                  padding: const EdgeInsets.all(1.6),
                  child: Container(
                    decoration: BoxDecoration(
                      color: isLight
                          ? Colors.white.withValues(alpha: 0.94)
                          : const Color(0xFF111A28),
                      borderRadius: BorderRadius.circular(24),
                    ),
                    padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
                    child: Column(
                      children: [
                        const SizedBox(height: 10),
                        LayoutBuilder(
                          builder: (context, constraints) {
                            final isCompact = constraints.maxWidth < 392;

                            final progressBadge = GestureDetector(
                              onTap: () => _openTaskProgressCategoriesDialog(
                                allDocs: allDocs,
                                canViewFriendsOnlyPosts:
                                    canViewFriendsOnlyPosts,
                              ),
                              child: _buildSubCategoryProgressBadge(
                                count: clampedPostedSubCategoryCount,
                                isLight: isLight,
                              ),
                            );

                            final profileAvatar = GestureDetector(
                              onTap: profileImageUrls.isEmpty
                                  ? null
                                  : () {
                                      showProfileImagesViewerDialog(
                                        context,
                                        imageUrls: profileImageUrls,
                                      );
                                    },
                              child: Container(
                                width: isCompact ? 102 : 114,
                                height: isCompact ? 102 : 114,
                                padding: const EdgeInsets.all(3),
                                decoration: const BoxDecoration(
                                  shape: BoxShape.circle,
                                  gradient: LinearGradient(
                                    colors: [
                                      Color(0xFF53C1F9),
                                      Color(0xFF9E7CFF)
                                    ],
                                  ),
                                ),
                                child: Container(
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: isLight
                                        ? Colors.white
                                        : const Color(0xFF1E2632),
                                  ),
                                  child: ClipOval(
                                    child: profileImageUrl.isNotEmpty
                                        ? Image.network(
                                            profileImageUrl,
                                            fit: BoxFit.cover,
                                            errorBuilder:
                                                (context, error, stackTrace) {
                                              return Center(
                                                child: Icon(
                                                  Icons.person_outline_rounded,
                                                  size: isCompact ? 46 : 54,
                                                  color: isLight
                                                      ? Colors.black
                                                      : Colors.white,
                                                ),
                                              );
                                            },
                                          )
                                        : Center(
                                            child: Icon(
                                              Icons.person_outline_rounded,
                                              size: isCompact ? 46 : 54,
                                              color: isLight
                                                  ? Colors.black
                                                  : Colors.white,
                                            ),
                                          ),
                                  ),
                                ),
                              ),
                            );

                            final viewedUserTaskWidget = ((FirebaseAuth
                                            .instance.currentUser?.uid
                                            .trim() ??
                                        '') !=
                                    widget.uid.trim())
                                ? StreamBuilder<
                                    DocumentSnapshot<Map<String, dynamic>>>(
                                    stream: _db
                                        .collection('users')
                                        .doc(widget.uid)
                                        .snapshots(),
                                    builder: (context, taskSnapshot) {
                                      final userData =
                                          taskSnapshot.data?.data() ??
                                              const <String, dynamic>{};
                                      final task =
                                          SpontaneousChallengeTask.fromMap(
                                        userData['weeklySpontaneousChallenge']
                                            as Map<String, dynamic>?,
                                        now: _spontaneousCountdownNowUtc,
                                      );
                                      if (task == null) {
                                        return const SizedBox.shrink();
                                      }
                                      return _buildViewedUserSpontaneousTaskBubbles(
                                          task);
                                    },
                                  )
                                : const SizedBox.shrink();

                            final hasTaskFromProfile =
                                SpontaneousChallengeTask.fromMap(
                                      profileData['weeklySpontaneousChallenge']
                                          as Map<String, dynamic>?,
                                      now: _spontaneousCountdownNowUtc,
                                    ) !=
                                    null;

                            if (isCompact) {
                              if (!hasTaskFromProfile) {
                                return Row(
                                  textDirection: TextDirection.ltr,
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Expanded(child: progressBadge),
                                    const SizedBox(width: 10),
                                    profileAvatar,
                                  ],
                                );
                              }

                              return Column(
                                children: [
                                  profileAvatar,
                                  const SizedBox(height: 10),
                                  Row(
                                    textDirection: TextDirection.ltr,
                                    children: [
                                      Expanded(child: progressBadge),
                                      const SizedBox(width: 10),
                                      Expanded(child: viewedUserTaskWidget),
                                    ],
                                  ),
                                ],
                              );
                            }

                            if (!hasTaskFromProfile) {
                              return Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                textDirection: TextDirection.ltr,
                                children: [
                                  SizedBox(width: 132, child: progressBadge),
                                  const SizedBox(width: 10),
                                  profileAvatar,
                                ],
                              );
                            }

                            return Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              textDirection: TextDirection.ltr,
                              children: [
                                SizedBox(width: 132, child: progressBadge),
                                const SizedBox(width: 10),
                                profileAvatar,
                                const SizedBox(width: 10),
                                SizedBox(
                                    width: 132, child: viewedUserTaskWidget),
                              ],
                            );
                          },
                        ),
                        const SizedBox(height: 14),
                        Text(
                          displayName,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: isLight ? Colors.black : Colors.white,
                            fontSize: 24,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          username,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: isLight ? Colors.black54 : Colors.grey[400],
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          bio,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: isLight ? Colors.black87 : Colors.grey[300],
                            fontSize: 14,
                            height: 1.4,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: _buildSoftProfileStatBubble(
                                label: 'ניקוד',
                                value: _formatCompactCount(score),
                                icon: Icons.stars_rounded,
                                onTap: () => _showScorePostsSheet(
                                  allDocs,
                                  profile,
                                  canViewFriendsOnlyPosts:
                                      canViewFriendsOnlyPosts,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _buildSoftProfileStatBubble(
                                label: 'פוסטים',
                                value: _formatCompactCount(publishedCount),
                                icon: Icons.grid_view_rounded,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                          stream: (() {
                            final currentUid =
                                FirebaseAuth.instance.currentUser?.uid.trim() ??
                                    '';
                            final isSelf = currentUid.isNotEmpty &&
                                currentUid == widget.uid;
                            final sourceCollection =
                                isSelf ? 'users' : 'users_public';
                            return _db
                                .collection(sourceCollection)
                                .doc(widget.uid)
                                .snapshots();
                          })(),
                          builder: (context, relationSnapshot) {
                            final relationData =
                                relationSnapshot.data?.data() ??
                                    <String, dynamic>{};
                            final followersSet =
                                _uidListFromData(relationData, 'followers')
                                    .toSet();
                            final profileFollowersSet =
                                _uidListFromData(profileData, 'followers')
                                    .toSet();
                            final followingSet =
                                _uidListFromData(relationData, 'following')
                                    .toSet();
                            final profileFollowingSet =
                                _uidListFromData(profileData, 'following')
                                    .toSet();
                            final relationFriendsSet =
                                _uidListFromData(relationData, 'friends')
                                    .toSet();
                            final profileFriendsSet =
                                _uidListFromData(profileData, 'friends')
                                    .toSet();
                            final explicitFriends = {
                              ...relationFriendsSet,
                              ...profileFriendsSet,
                            };
                            final fallbackFriendsCount =
                                (relationData['friendsCount'] as num?)
                                        ?.toInt() ??
                                    (profileData['friendsCount'] as num?)
                                        ?.toInt() ??
                                    0;

                            final syncFriendsCount = explicitFriends.isNotEmpty
                                ? explicitFriends.length
                                : (followersSet
                                        .intersection(followingSet)
                                        .isNotEmpty
                                    ? followersSet
                                        .intersection(followingSet)
                                        .length
                                    : fallbackFriendsCount);

                            final baseFollowersCount = followersSet.isNotEmpty
                                ? followersSet.length
                                : (profileFollowersSet.isNotEmpty
                                    ? profileFollowersSet.length
                                    : serverFollowersCount);
                            final followersCount = (baseFollowersCount +
                                    _optimisticFollowersAdjustment)
                                .clamp(0, 1 << 30);
                            final followingCount = followingSet.isNotEmpty
                                ? followingSet.length
                                : (profileFollowingSet.isNotEmpty
                                    ? profileFollowingSet.length
                                    : (serverFollowingCount > 0
                                        ? serverFollowingCount
                                        : profile.followingCount));

                            return FutureBuilder<int>(
                              future: _friendCountFuture,
                              initialData: syncFriendsCount,
                              builder: (context, friendsSnapshot) {
                                final friendsCount =
                                    friendsSnapshot.data ?? syncFriendsCount;
                                return Container(
                                  padding: const EdgeInsets.all(10),
                                  decoration: BoxDecoration(
                                    color: isLight
                                        ? Colors.white.withValues(alpha: 0.82)
                                        : const Color(0xFF0F1522),
                                    borderRadius: BorderRadius.circular(18),
                                    border: Border.all(
                                      color: isLight
                                          ? const Color(0xFFA9C3FF)
                                          : const Color(0xFF53C1F9)
                                              .withValues(alpha: 0.2),
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      _buildInteractiveRelationStat(
                                        label: 'עוקבים',
                                        value: followersCount,
                                        icon: Icons.people_alt_rounded,
                                        onTap: _showFollowersSheet,
                                        accent: const Color(0xFF53C1F9),
                                      ),
                                      const SizedBox(width: 8),
                                      _buildInteractiveRelationStat(
                                        label: 'נעקבים',
                                        value: followingCount,
                                        icon: Icons.person_add_alt_1_rounded,
                                        onTap: _showFollowingSheet,
                                        accent: const Color(0xFF9E7CFF),
                                      ),
                                      const SizedBox(width: 8),
                                      _buildInteractiveRelationStat(
                                        label: 'חברים',
                                        value: friendsCount,
                                        icon: Icons.handshake_rounded,
                                        onTap: _showFriendsOfUserSheet,
                                        accent: const Color(0xFF75A8FF),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            );
                          },
                        ),
                        const SizedBox(height: 8),
                        _buildActionButtons(profileData),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSubCategoryProgressBadge({
    required int count,
    required bool isLight,
  }) {
    final clampedCount = count.clamp(0, _subCategoryGoal);
    final isComplete = clampedCount >= _subCategoryGoal;
    final topText = isComplete
        ? '$_subCategoryGoal/$_subCategoryGoal'
        : '$clampedCount/$_subCategoryGoal';
    final bottomText = isComplete ? 'hundred' : 'משימות';

    final BoxDecoration fillDecoration;
    if (isComplete) {
      fillDecoration = BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: const LinearGradient(
          colors: [Color(0xFF48E1FF), Color(0xFF5F9BFF), Color(0xFF965EFF)],
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
        ),
      );
    } else {
      fillDecoration = BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: isLight
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
              ),
      );
    }

    return Container(
      width: double.infinity,
      height: 76,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
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
                fontSize: 19,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.2,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              bottomText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: isComplete
                    ? Colors.white.withValues(alpha: 0.95)
                    : (isLight ? Colors.black87 : Colors.white70),
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final currentUid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
    final canShowSafetyActions =
        currentUid.isNotEmpty && widget.uid.trim() != currentUid;
    return SwipeBackWrapper(
      child: Scaffold(
        backgroundColor: isLight ? Colors.white : const Color(0xFF0B1019),
        appBar: AppBar(
          backgroundColor:
              isLight ? const Color(0xFFCFEFFF) : const Color(0xFF1E2632),
          elevation: 0,
          title: const SizedBox.shrink(),
          centerTitle: false,
          leading: IconButton(
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.arrow_back_rounded),
          ),
          actions: [
            if (canShowSafetyActions)
              Padding(
                padding: const EdgeInsetsDirectional.only(end: 4),
                child: IconButton(
                  tooltip: 'אפשרויות משתמש',
                  onPressed: _showSafetyActionsMenu,
                  icon: Icon(
                    Icons.flag_outlined,
                    size: 18,
                    color: isLight ? const Color(0xFF6E7A90) : Colors.white70,
                  ),
                ),
              ),
          ],
          iconTheme:
              IconThemeData(color: isLight ? Colors.black : Colors.white),
        ),
        body: StreamBuilder<PublicUserProfile?>(
          stream: _profileStreamRef,
          builder: (context, profileSnapshot) {
            return StreamBuilder<BlockRelationship>(
              stream: _blockRelationshipStream,
              builder: (context, blockSnapshot) {
                final relation = blockSnapshot.data ?? BlockRelationship.none;
                final blockedByMe = relation == BlockRelationship.blockedByMe ||
                    relation == BlockRelationship.both;
                final blockedByOther =
                    relation == BlockRelationship.blockedByOther ||
                        relation == BlockRelationship.both;

                if (blockedByMe || blockedByOther) {
                  if (!_blockedBackNavigationScheduled) {
                    _blockedBackNavigationScheduled = true;
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (!mounted) return;
                      final navigator = Navigator.of(context);
                      if (navigator.canPop()) {
                        navigator.pop();
                        return;
                      }

                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('הפרופיל לא זמין עקב חסימה.'),
                        ),
                      );
                    });
                  }

                  return const Center(
                    child: CircularProgressIndicator(),
                  );
                } else {
                  _blockedBackNavigationScheduled = false;
                }

                if (profileSnapshot.connectionState ==
                        ConnectionState.waiting &&
                    !profileSnapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }

                if (profileSnapshot.hasError) {
                  return Center(
                    child: Text(
                      'שגיאה בטעינת פרטי המשתמש',
                      style: TextStyle(
                          color: isLight ? Colors.black54 : Colors.grey[300]),
                    ),
                  );
                }

                final profile = profileSnapshot.data;
                if (profile == null || !profile.exists) {
                  return Center(
                    child: Text(
                      'המשתמש לא נמצא',
                      style: TextStyle(
                          color: isLight ? Colors.black54 : Colors.grey[300]),
                    ),
                  );
                }

                final profileData = profile.toMap();
                final currentUid =
                    FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
                if (profile.isDeleted) {
                  return Center(
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 24),
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                        color: isLight
                            ? Colors.white.withValues(alpha: 0.84)
                            : const Color(0xFF1A2435),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: isLight
                              ? const Color(0xFFA9C3FF)
                              : const Color(0xFF53C1F9).withValues(alpha: 0.22),
                        ),
                      ),
                      child: Text(
                        'משתמש מחוק',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: isLight ? Colors.black87 : Colors.white70,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  );
                }

                final isPrivateProfile =
                    profile.isPrivate && currentUid != widget.uid;

                if (isPrivateProfile) {
                  return FutureBuilder<bool>(
                    future: _canViewProfileContentFuture,
                    builder: (context, privacySnapshot) {
                      final canView = privacySnapshot.data ?? false;
                      return _buildProfileContent(
                        profileData,
                        profile,
                        showPosts: canView,
                        canViewFriendsOnlyPosts: canView,
                      );
                    },
                  );
                }

                return FutureBuilder<bool>(
                  future: _canViewFriendsOnlyPostsFuture,
                  builder: (context, audienceSnapshot) {
                    final canViewFriendsOnly = audienceSnapshot.data ?? false;
                    return _buildProfileContent(
                      profileData,
                      profile,
                      canViewFriendsOnlyPosts: canViewFriendsOnly,
                    );
                  },
                );
              },
            );
          },
        ),
        bottomNavigationBar: MainBottomNav(
          currentIndex: widget.currentBottomIndex,
          onReselectCurrentTab: widget.currentBottomIndex == 0
              ? () {
                  if (Navigator.of(context).canPop()) {
                    Navigator.of(context).pop();
                  }
                }
              : null,
        ),
      ),
    );
  }
}
