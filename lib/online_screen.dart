import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'age_restrictions.dart';
import 'app_categories.dart';
import 'chat_room_screen.dart';
import 'chats_screen.dart';
import 'create_group_screen.dart';
import 'main_bottom_nav.dart';
import 'services/app_home_service.dart';
import 'services/block_user_service.dart';
import 'services/chat_service.dart';
import 'services/group_service.dart';
import 'services/keyboard_dismiss_controller.dart';
import 'services/weekly_challenge_service.dart';
import 'stars_screen.dart' show StarsScreen;
import 'user_profile_screen.dart';

class OnlineScreen extends StatefulWidget {
  const OnlineScreen({super.key});

  @override
  State<OnlineScreen> createState() => _OnlineScreenState();
}

class _OnlineScreenState extends State<OnlineScreen>
    with SingleTickerProviderStateMixin {
  static const Color _bg = Color(0xFF0B1019);
  static const Color _purple = Color(0xFFA487FF);
  static const Color _cyan = Color(0xFF6EADE8);
  static const Color _cyanSoft = Color(0xFF8BE7FF);
  static const Color _surfaceSoft = Color(0xFF1B2433);
  static const Duration _meetNowPostLifetime = Duration(hours: 24);
  static const Duration _meetNowRefreshInterval = Duration(seconds: 15);
  static const double _friendItemExtent = 88;

  final AppHomeService _homeService = AppHomeService();
  final GroupService _groupService = GroupService();
  final ChatService _chatService = ChatService();
  final BlockUserService _blockUserService = BlockUserService();

  late final AnimationController _spaceUsersController;
  late final ScrollController _friendsLoopController;
  late final ScrollController _upcomingGroupsScrollController;
  late final ValueNotifier<int> _sectionRefreshTick;
  late final TextEditingController _meetTitleController;
  late final TextEditingController _meetDetailsController;
  late final Stream<List<HomeFriendEntry>> _connectedFriendsStream;
  late final Stream<DateTime?> _forcedOnlineUntilStream;
  late final Stream<List<HomePublicGroupEntry>> _upcomingGroupsStream;
  late final Stream<List<MeetNowPostEntry>> _meetNowPostsStream;

  Timer? _meetNowRefreshTimer;
  StreamSubscription<Set<String>>? _joinedMeetPostsSub;
  Set<String> _joinedMeetPostIds = <String>{};
  final Set<String> _locallyHiddenMeetPostIds = <String>{};
  final Map<String, String> _groupMemberAvatarByUid = <String, String>{};
  final Set<String> _groupMemberAvatarLoadInFlight = <String>{};
  final Map<String, Stream<DocumentSnapshot<Map<String, dynamic>>>>
      _groupPrivacyStreamCache =
          <String, Stream<DocumentSnapshot<Map<String, dynamic>>>>{};
  String _lastUpcomingPrefetchKey = '';

  int? _meetFilterMinScore;
  String? _meetFilterCategory;
  String? _meetFilterSubCategory;
  RangeValues _meetFilterAgeRange = RangeValues(
    minimumUserAge.toDouble(),
    maximumAgeRange.toDouble(),
  );

  bool get _hasActiveMeetFilters {
    return _meetFilterMinScore != null ||
        _meetFilterCategory != null ||
        _meetFilterSubCategory != null ||
        _meetFilterAgeRange.start != minimumUserAge ||
        _meetFilterAgeRange.end != maximumAgeRange;
  }

  @override
  void initState() {
    super.initState();
    KeyboardDismissController.suspend();
    _sectionRefreshTick = ValueNotifier<int>(0);
    _spaceUsersController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 14),
    )..repeat();
    _friendsLoopController = ScrollController(
      initialScrollOffset: _friendItemExtent * 40,
    );
    _upcomingGroupsScrollController = ScrollController();
    _meetTitleController = TextEditingController();
    _meetDetailsController = TextEditingController();
    _connectedFriendsStream = _homeService.streamConnectedFriends();
    _forcedOnlineUntilStream = _homeService.streamMyForcedOnlineUntil();
    _upcomingGroupsStream =
        _homeService.streamUpcomingPublicGroups(withinDays: 7);
    _meetNowPostsStream = _homeService.streamMeetNowPosts();
    _meetNowRefreshTimer = Timer.periodic(_meetNowRefreshInterval, (_) {
      if (!mounted) {
        return;
      }
      _sectionRefreshTick.value = _sectionRefreshTick.value + 1;
    });
    _joinedMeetPostsSub = _homeService.streamJoinedMeetNowPostIds().listen(
      (ids) {
        if (!mounted) {
          return;
        }
        setState(() {
          _joinedMeetPostIds = ids;
        });
      },
    );
  }

  @override
  void dispose() {
    KeyboardDismissController.resume();
    _meetNowRefreshTimer?.cancel();
    _joinedMeetPostsSub?.cancel();
    _friendsLoopController.dispose();
    _upcomingGroupsScrollController.dispose();
    _spaceUsersController.dispose();
    _sectionRefreshTick.dispose();
    _meetTitleController.dispose();
    _meetDetailsController.dispose();
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

  Future<void> _scrollUpcomingGroupsForward() async {
    if (!_upcomingGroupsScrollController.hasClients) {
      return;
    }
    final currentOffset = _upcomingGroupsScrollController.offset;
    final maxOffset = _upcomingGroupsScrollController.position.maxScrollExtent;
    final targetOffset = (currentOffset + 190).clamp(0, maxOffset);
    await _upcomingGroupsScrollController.animateTo(
      targetOffset.toDouble(),
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _openProfile(String uid) async {
    final normalizedUid = uid.trim();
    if (normalizedUid.isEmpty || !mounted) {
      return;
    }

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => UserProfileScreen(
          uid: normalizedUid,
          currentBottomIndex: 1,
        ),
      ),
    );
  }

  Future<void> _openDirectChat(HomeFriendEntry friend) async {
    try {
      final chatId = await _chatService.findOrCreateDirectChat(
        otherUserId: friend.uid,
        otherDisplayName: friend.name,
        otherAvatarUrl: friend.avatarUrl,
      );
      if (!mounted) {
        return;
      }
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ChatRoomScreen(
            chatName: friend.name,
            avatarUrl: friend.avatarUrl.isEmpty ? null : friend.avatarUrl,
            chatId: chatId,
            isDirectChat: true,
            directOtherUserId: friend.uid,
          ),
        ),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('פתיחת הצאט נכשלה: $error')),
      );
    }
  }

  Future<void> _openUpcomingGroupsPage() async {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day);
    final end = DateTime(now.year, now.month, now.day + 7, 23, 59, 59);

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatsScreen(
          initialTabIndex: 2,
          initialPublicFilterFromDate: start,
          initialPublicFilterToDate: end,
        ),
      ),
    );
  }

  Stream<DocumentSnapshot<Map<String, dynamic>>> _groupPrivacyStream(
    String groupId,
  ) {
    final normalizedGroupId = groupId.trim();
    if (normalizedGroupId.isEmpty) {
      return const Stream<DocumentSnapshot<Map<String, dynamic>>>.empty();
    }

    return _groupPrivacyStreamCache.putIfAbsent(
      normalizedGroupId,
      () => FirebaseFirestore.instance
          .collection('groups')
          .doc(normalizedGroupId)
          .snapshots(),
    );
  }

  bool _isMeetJoinClosed(Map<String, dynamic> groupData) {
    final isPublic = (groupData['isPublic'] as bool?) ?? true;
    return !isPublic;
  }

  void _prefetchUpcomingGroupMemberAvatars(
    List<HomePublicGroupEntry> groups,
  ) {
    final missingUids = <String>{};
    for (final group in groups.take(10)) {
      for (final raw in group.participants) {
        final uid = raw.toString().trim();
        if (uid.isEmpty) {
          continue;
        }
        if (_groupMemberAvatarByUid.containsKey(uid) ||
            _groupMemberAvatarLoadInFlight.contains(uid)) {
          continue;
        }
        missingUids.add(uid);
        if (missingUids.length >= 70) {
          break;
        }
      }
      if (missingUids.length >= 70) {
        break;
      }
    }

    if (missingUids.isEmpty) {
      return;
    }

    _groupMemberAvatarLoadInFlight.addAll(missingUids);
    _chatService
        .fetchUserSummaries(missingUids.toList(growable: false))
        .then((summaries) {
      if (!mounted || summaries.isEmpty) {
        return;
      }

      var hasChanges = false;
      for (final uid in missingUids) {
        final avatar = (summaries[uid]?['avatarUrl'] ?? '').trim();
        if (avatar.isEmpty) {
          continue;
        }
        if (_groupMemberAvatarByUid[uid] == avatar) {
          continue;
        }
        _groupMemberAvatarByUid[uid] = avatar;
        hasChanges = true;
      }

      if (hasChanges && mounted) {
        setState(() {});
      }
    }).whenComplete(() {
      _groupMemberAvatarLoadInFlight.removeAll(missingUids);
    });
  }

  Future<void> _openForceOnlineSheet() async {
    double selectedMinutes = 30;
    final isLight = Theme.of(context).brightness == Brightness.light;

    await showDialog<void>(
      context: context,
      barrierColor: Colors.black54,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final minutes = selectedMinutes.round().clamp(1, 120);
            final thumbColor = Color.lerp(
              _purple,
              const Color(0xFF8BE7FF),
              (selectedMinutes - 1) / 119,
            )!;
            return Dialog(
              backgroundColor: Colors.transparent,
              insetPadding:
                  const EdgeInsets.symmetric(horizontal: 22, vertical: 24),
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(28),
                  gradient: const LinearGradient(
                    colors: [
                      Color(0xFF3B2C62),
                      Color(0xFF5A3D88),
                      Color(0xFF6B4FA5)
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                padding: const EdgeInsets.all(1.8),
                child: Container(
                  decoration: BoxDecoration(
                    color: isLight ? Colors.white : const Color(0xFF2F244A),
                    borderRadius: BorderRadius.circular(26),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'כדאי להיראות מחוברים כדי שחברים יוכלו להציע לך דברים',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: isLight
                                ? Colors.black87
                                : const Color(0xFFEDE4FF),
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            height: 1.35,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'לכמה זמן להראות שאת/ה מחובר/ת?',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: isLight
                                ? Colors.black
                                : const Color(0xFFF8F3FF),
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          minutes >= 60
                              ? 'משך: ${minutes ~/ 60}ש ${minutes % 60}ד'
                              : 'משך: $minutes דקות',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: isLight
                                ? Colors.black54
                                : const Color(0xFFDCD0F7),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Directionality(
                          textDirection: TextDirection.ltr,
                          child: SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              trackHeight: 4,
                              trackShape: const _ForceOnlineSliderTrackShape(),
                              activeTrackColor: Colors.transparent,
                              inactiveTrackColor: Colors.transparent,
                              thumbColor: thumbColor,
                              overlayColor: thumbColor.withValues(alpha: 0.18),
                              valueIndicatorColor: thumbColor,
                            ),
                            child: Slider(
                              value: selectedMinutes,
                              min: 1,
                              max: 120,
                              divisions: 119,
                              label: '${selectedMinutes.round()} דק',
                              onChanged: (value) {
                                setSheetState(() {
                                  selectedMinutes = value;
                                });
                              },
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        ElevatedButton(
                          onPressed: () async {
                            final duration = Duration(
                                minutes: selectedMinutes.round().clamp(1, 120));
                            try {
                              await _homeService
                                  .setForcedOnlineDuration(duration);
                              if (!mounted) {
                                return;
                              }
                              if (!sheetContext.mounted) {
                                return;
                              }
                              Navigator.of(sheetContext).pop();
                              ScaffoldMessenger.of(this.context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                      'סטטוס מחובר הופעל ל-${duration.inMinutes} דקות'),
                                ),
                              );
                            } catch (error) {
                              if (!mounted) {
                                return;
                              }
                              ScaffoldMessenger.of(this.context).showSnackBar(
                                SnackBar(
                                    content: Text('עדכון סטטוס נכשל: $error')),
                              );
                            }
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF8BE7FF),
                            foregroundColor: isLight
                                ? Colors.black
                                : const Color(0xFF2C1F4A),
                            padding: const EdgeInsets.symmetric(vertical: 13),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          child: const Text(
                            'online',
                            style: TextStyle(fontWeight: FontWeight.w800),
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

  String _formatRemainingForcedOnline(Duration remaining) {
    final safe = remaining.isNegative ? Duration.zero : remaining;
    final hours = safe.inHours;
    final minutes = safe.inMinutes.remainder(60);
    final seconds = safe.inSeconds.remainder(60);

    if (hours > 0) {
      return '$hours שעות ו-$minutes דקות';
    }
    if (minutes > 0) {
      return '$minutes דקות ו-$seconds שניות';
    }
    return '$seconds שניות';
  }

  void _showForcedOnlineRemainingBubble(DateTime forcedOnlineUntil) {
    final remaining = forcedOnlineUntil.difference(DateTime.now());
    final text = _formatRemainingForcedOnline(remaining);
    if (!mounted) {
      return;
    }

    final navigator = Navigator.of(context, rootNavigator: true);
    var isDialogOpen = true;

    showGeneralDialog<void>(
      context: context,
      barrierLabel: 'online_remaining',
      barrierDismissible: true,
      barrierColor: Colors.black26,
      transitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (dialogContext, _, __) {
        void closeDialog() {
          if (!isDialogOpen) {
            return;
          }
          if (Navigator.of(dialogContext).canPop()) {
            Navigator.of(dialogContext).pop();
          }
        }

        return SafeArea(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: closeDialog,
            child: Center(
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 28),
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(22),
                  gradient: const LinearGradient(
                    colors: [
                      Color(0xFF1F8D4A),
                      Color(0xFF37B46A),
                      Color(0xFF68D08E)
                    ],
                    begin: Alignment.topRight,
                    end: Alignment.bottomLeft,
                  ),
                  border:
                      Border.all(color: const Color(0xFFB9FFD2), width: 1.2),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF4FD17F).withValues(alpha: 0.28),
                      blurRadius: 18,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: DefaultTextStyle.merge(
                  style: const TextStyle(
                    decoration: TextDecoration.none,
                    decorationColor: Colors.transparent,
                  ),
                  child: Text(
                    'נשארו עוד $text למצב online',
                    textAlign: TextAlign.center,
                    softWrap: true,
                    overflow: TextOverflow.visible,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      height: 1.3,
                      decoration: TextDecoration.none,
                      decorationColor: Colors.transparent,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
      transitionBuilder: (context, animation, _, child) {
        final fade =
            CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
        return FadeTransition(
          opacity: fade,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.94, end: 1).animate(fade),
            child: child,
          ),
        );
      },
    ).then((_) {
      isDialogOpen = false;
    });

    Future<void>.delayed(const Duration(seconds: 3), () {
      if (!mounted) {
        return;
      }
      if (isDialogOpen && navigator.canPop()) {
        navigator.pop();
      }
    });
  }

  List<MeetNowPostEntry> _applyMeetFilters(List<MeetNowPostEntry> entries) {
    final now = DateTime.now();
    final currentUid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';

    return entries.where((entry) {
      if (currentUid.isNotEmpty && entry.authorUid.trim() == currentUid) {
        return false;
      }

      final postId = entry.id.trim();
      if (postId.isNotEmpty &&
          (_joinedMeetPostIds.contains(postId) ||
              _locallyHiddenMeetPostIds.contains(postId))) {
        return false;
      }

      final age = now.difference(entry.createdAt);
      if (age >= _meetNowPostLifetime) {
        return false;
      }

      final minAge = (entry.minAge ?? minimumUserAge).toDouble();
      final maxAge = (entry.maxAge ?? maximumAgeRange).toDouble();
      final overlap = maxAge >= _meetFilterAgeRange.start &&
          minAge <= _meetFilterAgeRange.end;
      if (!overlap) {
        return false;
      }

      if (_meetFilterMinScore != null &&
          entry.authorScore < _meetFilterMinScore!) {
        return false;
      }

      if (_meetFilterCategory != null && _meetFilterCategory!.isNotEmpty) {
        if (entry.category != _meetFilterCategory) {
          return false;
        }
      }

      if (_meetFilterSubCategory != null &&
          _meetFilterSubCategory!.isNotEmpty) {
        if (entry.subCategory != _meetFilterSubCategory) {
          return false;
        }
      }

      return true;
    }).toList(growable: false);
  }

  Future<void> _openMeetFiltersSheet() async {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final scoreController = TextEditingController(
      text: _meetFilterMinScore?.toString() ?? '',
    );
    RangeValues draftAgeRange = _meetFilterAgeRange;
    String? draftCategory = _meetFilterCategory;
    String? draftSubCategory = _meetFilterSubCategory;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: isLight ? Colors.white : const Color(0xFF111A28),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final subCategoryOptions = appSubCategories(draftCategory)
                .where((item) => item.trim().isNotEmpty)
                .toList(growable: false);

            return SafeArea(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  16,
                  14,
                  16,
                  MediaQuery.of(sheetContext).viewInsets.bottom + 16,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'סינון מחפשים להיפגש',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: isLight ? Colors.black : Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        controller: scoreController,
                        onTapOutside: (_) {},
                        keyboardType: TextInputType.number,
                        style: TextStyle(
                            color: isLight ? Colors.black : Colors.white),
                        decoration: InputDecoration(
                          labelText: 'ניקוד מינימלי של המפרסם',
                          labelStyle: TextStyle(
                            color: isLight ? Colors.black54 : Colors.white70,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      _buildMeetFilterPickerTile(
                        icon: Icons.category_rounded,
                        title: 'קטגוריה',
                        value: draftCategory ?? '',
                        hint: 'כל הקטגוריות',
                        onTap: () async {
                          final selected = await _showMeetFilterChoiceSheet(
                            title: 'בחירת קטגוריה',
                            options: appMainCategories,
                            selectedValue: draftCategory,
                            includeEmptyOption: true,
                            emptyOptionLabel: 'כל הקטגוריות',
                            useCategoryIcons: true,
                          );
                          if (!context.mounted) return;
                          setSheetState(() {
                            draftCategory = selected;
                            final subCategories = appSubCategories(selected);
                            if (!subCategories.contains(draftSubCategory)) {
                              draftSubCategory = null;
                            }
                          });
                        },
                      ),
                      const SizedBox(height: 12),
                      _buildMeetFilterPickerTile(
                        icon: Icons.grid_view_rounded,
                        title: 'תת קטגוריה',
                        value: draftSubCategory ?? '',
                        hint: draftCategory == null
                            ? 'בחר קטגוריה קודם'
                            : 'כל תתי הקטגוריות',
                        onTap: () async {
                          if (draftCategory == null ||
                              draftCategory!.trim().isEmpty) {
                            if (!mounted) return;
                            ScaffoldMessenger.of(this.context).showSnackBar(
                              const SnackBar(
                                content: Text('בחר קטגוריה לפני תת קטגוריה'),
                              ),
                            );
                            return;
                          }

                          final selected = await _showMeetFilterChoiceSheet(
                            title: 'בחירת תת קטגוריה',
                            options: subCategoryOptions,
                            selectedValue: draftSubCategory,
                            includeEmptyOption: true,
                            emptyOptionLabel: 'כל תתי הקטגוריות',
                            useCategoryIcons: false,
                          );
                          if (!context.mounted) return;
                          setSheetState(() {
                            draftSubCategory = selected;
                          });
                        },
                      ),
                      const SizedBox(height: 14),
                      Container(
                        padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
                        decoration: BoxDecoration(
                          color: isLight
                              ? const Color(0xFFEFF5FF)
                              : const Color(0xFF1A2438),
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(
                            color: (isLight
                                    ? const Color(0xFF8FB7FF)
                                    : const Color(0xFF46D3FF))
                                .withValues(alpha: 0.28),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              'טווח גילאים: ${draftAgeRange.start.round()}-${draftAgeRange.end.round()}',
                              textAlign: TextAlign.right,
                              style: TextStyle(
                                color: isLight
                                    ? const Color(0xFF2A3A5A)
                                    : Colors.white70,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 8),
                            RangeSlider(
                              values: draftAgeRange,
                              min: minimumUserAge.toDouble(),
                              max: maximumAgeRange.toDouble(),
                              divisions: maximumAgeRange - minimumUserAge,
                              activeColor: _purple,
                              inactiveColor: isLight
                                  ? const Color(0xFFD8E6FF)
                                  : Colors.white12,
                              labels: RangeLabels(
                                '${draftAgeRange.start.round()}',
                                '${draftAgeRange.end.round()}',
                              ),
                              onChanged: (value) {
                                setSheetState(() {
                                  draftAgeRange = value;
                                });
                              },
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: TextButton(
                              onPressed: () {
                                setSheetState(() {
                                  scoreController.clear();
                                  draftAgeRange = RangeValues(
                                    minimumUserAge.toDouble(),
                                    maximumAgeRange.toDouble(),
                                  );
                                  draftCategory = null;
                                  draftSubCategory = null;
                                });
                              },
                              child: const Text('נקה הכל'),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: ElevatedButton(
                              onPressed: () {
                                setState(() {
                                  _meetFilterMinScore =
                                      int.tryParse(scoreController.text.trim());
                                  _meetFilterAgeRange = draftAgeRange;
                                  _meetFilterCategory = draftCategory;
                                  _meetFilterSubCategory = draftSubCategory;
                                });
                                Navigator.of(sheetContext).pop();
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: _purple,
                                foregroundColor:
                                    isLight ? Colors.black : Colors.white,
                              ),
                              child: const Text('החל סינון'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );

    scoreController.dispose();
  }

  Future<String?> _showMeetFilterChoiceSheet({
    required String title,
    required List<String> options,
    required String? selectedValue,
    required bool includeEmptyOption,
    required String emptyOptionLabel,
    required bool useCategoryIcons,
  }) async {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final trimmedOptions = options
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
    final resolvedOptions = includeEmptyOption
        ? <String>[emptyOptionLabel, ...trimmedOptions]
        : trimmedOptions;

    return showGeneralDialog<String>(
      context: context,
      barrierDismissible: true,
      barrierLabel: title,
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (sheetContext, _, __) {
        return Material(
          color: Colors.transparent,
          child: SafeArea(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: MediaQuery.of(sheetContext).size.width * 0.94,
                    maxHeight: MediaQuery.of(sheetContext).size.height * 0.82,
                  ),
                  child: Container(
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
                        color: isLight
                            ? const Color(0xFFF8FBFF)
                            : const Color(0xFF101826),
                        borderRadius: BorderRadius.circular(28),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
                        child: Column(
                          children: [
                            Row(
                              children: [
                                IconButton(
                                  onPressed: () =>
                                      Navigator.of(sheetContext).pop(),
                                  icon: Icon(
                                    Icons.close_rounded,
                                    color: isLight
                                        ? const Color(0xFF33405B)
                                        : Colors.white70,
                                  ),
                                ),
                                Expanded(
                                  child: Text(
                                    title,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: isLight
                                          ? const Color(0xFF1E2A45)
                                          : Colors.white,
                                      fontSize: 22,
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 46),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Expanded(
                              child: SingleChildScrollView(
                                physics: const BouncingScrollPhysics(),
                                child: Wrap(
                                  alignment: WrapAlignment.center,
                                  spacing: 16,
                                  runSpacing: 16,
                                  children: resolvedOptions.map((option) {
                                    final isEmptyOption = includeEmptyOption &&
                                        option == emptyOptionLabel;
                                    final isSelected = isEmptyOption
                                        ? (selectedValue == null ||
                                            selectedValue.trim().isEmpty)
                                        : option == selectedValue;
                                    return Material(
                                      color: Colors.transparent,
                                      child: InkWell(
                                        onTap: () => Navigator.of(sheetContext)
                                            .pop(isEmptyOption ? null : option),
                                        borderRadius:
                                            BorderRadius.circular(999),
                                        child: AnimatedContainer(
                                          duration:
                                              const Duration(milliseconds: 160),
                                          curve: Curves.easeOut,
                                          width: 118,
                                          height: 118,
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            gradient: const LinearGradient(
                                              colors: [
                                                Color(0xFF8DE8FF),
                                                Color(0xFFC9B5FF),
                                              ],
                                              begin: Alignment.topLeft,
                                              end: Alignment.bottomRight,
                                            ),
                                            border: Border.all(
                                              color: isSelected
                                                  ? const Color(0xFF8D78FF)
                                                  : Colors.white
                                                      .withValues(alpha: 0.72),
                                              width: isSelected ? 1.8 : 1.2,
                                            ),
                                          ),
                                          child: Padding(
                                            padding: const EdgeInsets.all(10),
                                            child: Column(
                                              mainAxisAlignment:
                                                  MainAxisAlignment.center,
                                              children: [
                                                Icon(
                                                  useCategoryIcons &&
                                                          !isEmptyOption
                                                      ? categoryIconFor(option)
                                                      : Icons.category_rounded,
                                                  color:
                                                      const Color(0xFF2A2361),
                                                  size: 29,
                                                ),
                                                const SizedBox(height: 7),
                                                Text(
                                                  option,
                                                  maxLines: 2,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  textAlign: TextAlign.center,
                                                  style: TextStyle(
                                                    color:
                                                        const Color(0xFF2A2361),
                                                    fontSize:
                                                        isLight ? 12.2 : 12,
                                                    fontWeight: FontWeight.w900,
                                                    height: 1.1,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
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
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<String?> _showMeetTimePreferenceClockSheet({
    required String selectedValue,
  }) async {
    final isLight = Theme.of(context).brightness == Brightness.light;
    const options = <String>[
      'עכשיו',
      'עוד מעט',
      'בערב',
      'מחר',
      'שבוע הבא',
      'לא אכפת לי מתי',
    ];

    final initialIndex = options.indexOf(selectedValue);
    final fallbackIndex = initialIndex >= 0 ? initialIndex : 0;

    return showGeneralDialog<String>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'בחירת זמן למפגש',
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 190),
      pageBuilder: (sheetContext, _, __) {
        var draftIndex = fallbackIndex;
        var handAngle =
            (-math.pi / 2) + (2 * math.pi * (fallbackIndex / options.length));
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final size = MediaQuery.of(sheetContext).size;
            final dialSize = math.min(size.width * 0.78, 330.0);
            final center = dialSize / 2;
            final ringRadius = dialSize * 0.39;
            final cellWidth = math.max(84.0, dialSize * 0.3);
            const cellHeight = 40.0;
            final handLength = ringRadius;
            final handRotationAngle = handAngle + (math.pi / 2);

            return Material(
              color: Colors.transparent,
              child: SafeArea(
                child: Directionality(
                  textDirection: TextDirection.rtl,
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: math.min(size.width - 18, 430),
                        ),
                        child: Container(
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
                              color: isLight
                                  ? const Color(0xFFF8FBFF)
                                  : const Color(0xFF101826),
                              borderRadius: BorderRadius.circular(28),
                            ),
                            child: Padding(
                              padding:
                                  const EdgeInsets.fromLTRB(16, 12, 16, 14),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Row(
                                    children: [
                                      IconButton(
                                        onPressed: () =>
                                            Navigator.of(sheetContext).pop(),
                                        icon: Icon(
                                          Icons.close_rounded,
                                          color: isLight
                                              ? const Color(0xFF33405B)
                                              : Colors.white70,
                                        ),
                                      ),
                                      Expanded(
                                        child: Text(
                                          'בחירת זמן למפגש',
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                            color: isLight
                                                ? const Color(0xFF1E2A45)
                                                : Colors.white,
                                            fontSize: 22,
                                            fontWeight: FontWeight.w900,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 46),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  SizedBox(
                                    width: dialSize,
                                    height: dialSize,
                                    child: Stack(
                                      clipBehavior: Clip.none,
                                      children: [
                                        Positioned(
                                          left: center - 2,
                                          top: center - handLength,
                                          child: AnimatedRotation(
                                            turns: handRotationAngle /
                                                (2 * math.pi),
                                            duration: const Duration(
                                                milliseconds: 230),
                                            curve: Curves.easeOutCubic,
                                            alignment: Alignment.bottomCenter,
                                            child: Container(
                                              width: 4,
                                              height: handLength,
                                              decoration: BoxDecoration(
                                                gradient: const LinearGradient(
                                                  colors: [
                                                    Color(0xFFC9B5FF),
                                                    Color(0xFF8DE8FF),
                                                  ],
                                                  begin: Alignment.bottomCenter,
                                                  end: Alignment.topCenter,
                                                ),
                                                borderRadius:
                                                    BorderRadius.circular(999),
                                              ),
                                            ),
                                          ),
                                        ),
                                        ...List<Widget>.generate(options.length,
                                            (index) {
                                          final angle = (-math.pi / 2) +
                                              (2 *
                                                  math.pi *
                                                  (index / options.length));
                                          final cx = center +
                                              (ringRadius * math.cos(angle));
                                          final cy = center +
                                              (ringRadius * math.sin(angle));
                                          final isSelected =
                                              draftIndex == index;
                                          return Positioned(
                                            left: cx - (cellWidth / 2),
                                            top: cy - (cellHeight / 2),
                                            child: GestureDetector(
                                              onTap: () {
                                                setSheetState(() {
                                                  draftIndex = index;
                                                  final targetAngle =
                                                      (-math.pi / 2) +
                                                          (2 *
                                                              math.pi *
                                                              (index /
                                                                  options
                                                                      .length));
                                                  var nextClockwise =
                                                      targetAngle;
                                                  while (nextClockwise <=
                                                      handAngle) {
                                                    nextClockwise +=
                                                        2 * math.pi;
                                                  }
                                                  handAngle = nextClockwise;
                                                });
                                              },
                                              child: Container(
                                                width: cellWidth,
                                                height: cellHeight,
                                                alignment: Alignment.center,
                                                decoration: BoxDecoration(
                                                  borderRadius:
                                                      BorderRadius.circular(
                                                          999),
                                                  gradient: isSelected
                                                      ? const LinearGradient(
                                                          colors: [
                                                            Color(0xFF8DE8FF),
                                                            Color(0xFFC9B5FF),
                                                          ],
                                                          begin:
                                                              Alignment.topLeft,
                                                          end: Alignment
                                                              .bottomRight,
                                                        )
                                                      : null,
                                                  color: isSelected
                                                      ? null
                                                      : (isLight
                                                          ? Colors.white
                                                          : const Color(
                                                              0xFF1F2B42)),
                                                  border: Border.all(
                                                    color: isSelected
                                                        ? Colors.white
                                                            .withValues(
                                                                alpha: 0.84)
                                                        : (isLight
                                                            ? const Color(
                                                                    0xFFCAD8F3)
                                                                .withValues(
                                                                    alpha: 0.92)
                                                            : Colors.white
                                                                .withValues(
                                                                    alpha:
                                                                        0.18)),
                                                    width:
                                                        isSelected ? 1.6 : 1.0,
                                                  ),
                                                ),
                                                child: Text(
                                                  options[index],
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    color: isSelected
                                                        ? const Color(
                                                            0xFF2A2361)
                                                        : (isLight
                                                            ? const Color(
                                                                0xFF2B3758)
                                                            : Colors.white70),
                                                    fontWeight: isSelected
                                                        ? FontWeight.w900
                                                        : FontWeight.w700,
                                                    fontSize: 12.3,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          );
                                        }),
                                        Align(
                                          alignment: Alignment.center,
                                          child: Container(
                                            width: 74,
                                            height: 74,
                                            decoration: BoxDecoration(
                                              shape: BoxShape.circle,
                                              gradient: const LinearGradient(
                                                colors: [
                                                  Color(0xFF8DE8FF),
                                                  Color(0xFFC9B5FF),
                                                ],
                                                begin: Alignment.topLeft,
                                                end: Alignment.bottomRight,
                                              ),
                                              border: Border.all(
                                                color: Colors.white
                                                    .withValues(alpha: 0.9),
                                              ),
                                            ),
                                            child: Center(
                                              child: Text(
                                                options[draftIndex],
                                                textAlign: TextAlign.center,
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  color: Color(0xFF2A2361),
                                                  fontWeight: FontWeight.w900,
                                                  fontSize: 11,
                                                  height: 1.1,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                  SizedBox(
                                    width: double.infinity,
                                    child: ElevatedButton(
                                      onPressed: () =>
                                          Navigator.of(sheetContext)
                                              .pop(options[draftIndex]),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: _purple,
                                        foregroundColor: isLight
                                            ? Colors.black
                                            : Colors.white,
                                        padding: const EdgeInsets.symmetric(
                                            vertical: 13),
                                        shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(16),
                                        ),
                                      ),
                                      child: const Text(
                                        'אישור',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w800,
                                          fontSize: 15,
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
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildMeetFilterPickerTile({
    required IconData icon,
    required String title,
    required String value,
    required String hint,
    required VoidCallback onTap,
  }) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final hasValue = value.trim().isNotEmpty;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          padding: const EdgeInsets.all(1.4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            gradient: const LinearGradient(
              colors: [Color(0xFF8DE8FF), Color(0xFFC9B5FF)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            decoration: BoxDecoration(
              color:
                  isLight ? const Color(0xFFF8FCFF) : const Color(0xFF1E2632),
              borderRadius: BorderRadius.circular(17),
            ),
            child: Row(
              textDirection: TextDirection.rtl,
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const LinearGradient(
                      colors: [Color(0xFF8DE8FF), Color(0xFFC9B5FF)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.82),
                    ),
                  ),
                  child: Icon(
                    icon,
                    size: 20,
                    color: const Color(0xFF2A2361),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          color:
                              isLight ? const Color(0xFF223A5C) : Colors.white,
                          fontWeight: FontWeight.w900,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        hasValue ? value : hint,
                        textAlign: TextAlign.right,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: hasValue
                              ? (isLight
                                  ? const Color(0xFF2A3563)
                                  : const Color(0xFFEAF4FF))
                              : (isLight ? Colors.black54 : Colors.white54),
                          fontSize: hasValue ? 14 : 12,
                          fontWeight:
                              hasValue ? FontWeight.w800 : FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  Icons.touch_app_rounded,
                  color: isLight
                      ? const Color(0xFF7B6BE0)
                      : const Color(0xFF9EDBFF),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMeetParticipantsSelector({
    required bool isLight,
    required int? selected,
    required ValueChanged<int> onSelect,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'כמות משתתפים רצויה',
          textAlign: TextAlign.right,
          style: TextStyle(
            color: isLight ? Colors.black : Colors.white,
            fontWeight: FontWeight.w800,
            fontSize: 15,
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: 8,
          runSpacing: 8,
          children: List<Widget>.generate(8, (index) {
            final value = index + 2;
            final isSelected = selected == value;
            return Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(999),
                onTap: () => onSelect(value),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  curve: Curves.easeOut,
                  width: 38,
                  height: 38,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: isSelected
                        ? const LinearGradient(
                            colors: [Color(0xFF8DE8FF), Color(0xFFC9B5FF)],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          )
                        : null,
                    color: isSelected
                        ? null
                        : (isLight
                            ? const Color(0xFFE7EEFB)
                            : const Color(0xFF253042)),
                    border: Border.all(
                      color: isSelected
                          ? Colors.white.withValues(alpha: 0.82)
                          : (isLight
                              ? const Color(0xFFCCD9EE)
                              : Colors.white.withValues(alpha: 0.16)),
                    ),
                  ),
                  child: Text(
                    value == 9 ? '9+' : '$value',
                    style: TextStyle(
                      color: isSelected
                          ? const Color(0xFF2A2361)
                          : (isLight ? const Color(0xFF34425E) : Colors.white),
                      fontWeight:
                          isSelected ? FontWeight.w900 : FontWeight.w700,
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            );
          }),
        ),
      ],
    );
  }

  Widget _buildMeetComposerAgeRange({
    required bool isLight,
    required RangeValues ageRange,
    required ValueChanged<RangeValues> onChanged,
  }) {
    return Row(
      children: [
        Text(
          'טווח גילאים',
          style: TextStyle(color: isLight ? Colors.black : Colors.white),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final minAge = ageRange.start.round();
              final maxAge = ageRange.end.round();
              final isRtl = Directionality.of(context) == TextDirection.rtl;
              const bubbleWidth = 42.0;
              const thumbRadius = 10.0;
              final trackWidth = constraints.maxWidth > thumbRadius * 2
                  ? constraints.maxWidth - thumbRadius * 2
                  : 0.0;
              final maxBubbleLeft = (constraints.maxWidth - bubbleWidth)
                  .clamp(0.0, double.infinity);

              double thumbOffsetFor(int value) {
                final normalized = (value - minimumUserAge) /
                    (maximumAgeRange - minimumUserAge);
                final adjusted = isRtl ? 1 - normalized : normalized;
                final thumbCenter =
                    thumbRadius + trackWidth * adjusted.clamp(0.0, 1.0);
                return thumbCenter - (bubbleWidth / 2);
              }

              double bubbleLeftFor(int value) {
                return thumbOffsetFor(value).clamp(0.0, maxBubbleLeft);
              }

              Widget valueBubble(int value) {
                return Container(
                  width: bubbleWidth,
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF8DE8FF), Color(0xFFC6B2FF)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.7),
                    ),
                  ),
                  child: Text(
                    value.toString(),
                    style: const TextStyle(
                      color: Color(0xFF2A2C5A),
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                );
              }

              return Column(
                children: [
                  SizedBox(
                    height: 32,
                    child: Stack(
                      children: [
                        Positioned(
                          left: bubbleLeftFor(minAge),
                          child: valueBubble(minAge),
                        ),
                        Positioned(
                          left: bubbleLeftFor(maxAge),
                          child: valueBubble(maxAge),
                        ),
                      ],
                    ),
                  ),
                  RangeSlider(
                    values: ageRange,
                    min: minimumUserAge.toDouble(),
                    max: maximumAgeRange.toDouble(),
                    divisions: maximumAgeRange - minimumUserAge,
                    activeColor: _purple,
                    inactiveColor:
                        isLight ? const Color(0xFFD8E6FF) : Colors.white12,
                    onChanged: onChanged,
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _openMeetComposerSheet() async {
    final canPublish = await _homeService.canPublishMeetNowPost();
    if (!mounted) {
      return;
    }
    if (!canPublish) {
      _showMeetPublishLimitNotice();
      return;
    }

    final isLight = Theme.of(context).brightness == Brightness.light;
    _meetTitleController.clear();
    _meetDetailsController.clear();
    bool useAgeRange = false;
    RangeValues ageRange = RangeValues(
      minimumUserAge.toDouble(),
      maximumAgeRange.toDouble(),
    );
    String? category;
    String? subCategory;
    String timePreference = 'עכשיו';
    int? desiredParticipants = 2;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final subCategoryOptions = appSubCategories(category)
                .where((item) => item.trim().isNotEmpty)
                .toList(growable: false);

            return SafeArea(
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: _dismissKeyboardOnBackgroundTap,
                child: Container(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(sheetContext).size.height * 0.75,
                ),
                margin: const EdgeInsets.fromLTRB(14, 6, 14, 14),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(28),
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
                    borderRadius: BorderRadius.circular(26),
                  ),
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      16,
                      16,
                      16,
                      MediaQuery.of(sheetContext).viewInsets.bottom + 16,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: SingleChildScrollView(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text(
                                  'בואו נעשה משהו!',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color:
                                        isLight ? Colors.black : Colors.white,
                                    fontSize: 21,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const SizedBox(height: 14),
                                TextField(
                                  controller: _meetTitleController,
                                  onTapOutside: (_) {},
                                  maxLength: 36,
                                  textAlign: TextAlign.right,
                                  style: TextStyle(
                                    color:
                                        isLight ? Colors.black : Colors.white,
                                  ),
                                  decoration: InputDecoration(
                                    hintText: 'מה בא לך לעשות? (עד 36 תווים)',
                                    hintStyle: TextStyle(
                                      color: isLight
                                          ? Colors.black54
                                          : Colors.white70,
                                    ),
                                    counterStyle: TextStyle(
                                      color: isLight
                                          ? Colors.black45
                                          : Colors.white54,
                                    ),
                                    filled: true,
                                    fillColor: Colors.transparent,
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 14,
                                      vertical: 13,
                                    ),
                                    enabledBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(18),
                                      borderSide: BorderSide(
                                        color: (isLight
                                                ? const Color(0xFF8FB7FF)
                                                : const Color(0xFF46D3FF))
                                            .withValues(alpha: 0.55),
                                        width: 1.1,
                                      ),
                                    ),
                                    focusedBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(18),
                                      borderSide: BorderSide(
                                        color: (isLight
                                                ? const Color(0xFF7A9BFF)
                                                : const Color(0xFF8DE8FF))
                                            .withValues(alpha: 0.95),
                                        width: 1.35,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 10),
                                TextField(
                                  controller: _meetDetailsController,
                                  onTapOutside: (_) {},
                                  maxLines: 3,
                                  textAlign: TextAlign.right,
                                  style: TextStyle(
                                    color:
                                        isLight ? Colors.black : Colors.white,
                                  ),
                                  decoration: InputDecoration(
                                    hintText: 'הוסף פרטים שיעזרו לאחרים להצטרף',
                                    hintStyle: TextStyle(
                                      color: isLight
                                          ? Colors.black54
                                          : Colors.white70,
                                    ),
                                    filled: true,
                                    fillColor: Colors.transparent,
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 14,
                                      vertical: 13,
                                    ),
                                    enabledBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(18),
                                      borderSide: BorderSide(
                                        color: (isLight
                                                ? const Color(0xFF8FB7FF)
                                                : const Color(0xFF46D3FF))
                                            .withValues(alpha: 0.55),
                                        width: 1.1,
                                      ),
                                    ),
                                    focusedBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(18),
                                      borderSide: BorderSide(
                                        color: (isLight
                                                ? const Color(0xFF7A9BFF)
                                                : const Color(0xFF8DE8FF))
                                            .withValues(alpha: 0.95),
                                        width: 1.35,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 10),
                                _buildMeetParticipantsSelector(
                                  isLight: isLight,
                                  selected: desiredParticipants,
                                  onSelect: (value) {
                                    setSheetState(() {
                                      desiredParticipants = value;
                                    });
                                  },
                                ),
                                const SizedBox(height: 12),
                                _buildMeetFilterPickerTile(
                                  icon: Icons.category_rounded,
                                  title: 'קטגוריה',
                                  value: category ?? '',
                                  hint: 'ללא קטגוריה',
                                  onTap: () async {
                                    final selected =
                                        await _showMeetFilterChoiceSheet(
                                      title: 'בחירת קטגוריה',
                                      options: appMainCategories,
                                      selectedValue: category,
                                      includeEmptyOption: true,
                                      emptyOptionLabel: 'ללא קטגוריה',
                                      useCategoryIcons: true,
                                    );
                                    if (!context.mounted) return;
                                    setSheetState(() {
                                      category = selected;
                                      final subCategories =
                                          appSubCategories(selected);
                                      if (!subCategories
                                          .contains(subCategory)) {
                                        subCategory = null;
                                      }
                                    });
                                  },
                                ),
                                const SizedBox(height: 12),
                                _buildMeetFilterPickerTile(
                                  icon: Icons.grid_view_rounded,
                                  title: 'תת קטגוריה',
                                  value: subCategory ?? '',
                                  hint: category == null
                                      ? 'בחר קטגוריה קודם'
                                      : 'ללא תת קטגוריה',
                                  onTap: () async {
                                    if (category == null ||
                                        category!.trim().isEmpty) {
                                      if (!mounted) return;
                                      ScaffoldMessenger.of(this.context)
                                          .showSnackBar(
                                        const SnackBar(
                                          content: Text(
                                              'בחר קטגוריה לפני תת קטגוריה'),
                                        ),
                                      );
                                      return;
                                    }

                                    final selected =
                                        await _showMeetFilterChoiceSheet(
                                      title: 'בחירת תת קטגוריה',
                                      options: subCategoryOptions,
                                      selectedValue: subCategory,
                                      includeEmptyOption: true,
                                      emptyOptionLabel: 'ללא תת קטגוריה',
                                      useCategoryIcons: false,
                                    );
                                    if (!context.mounted) return;
                                    setSheetState(() {
                                      subCategory = selected;
                                    });
                                  },
                                ),
                                const SizedBox(height: 12),
                                _buildMeetFilterPickerTile(
                                  icon: Icons.schedule_rounded,
                                  title: 'זמן למפגש',
                                  value: timePreference,
                                  hint: 'בחר זמן',
                                  onTap: () async {
                                    final selected =
                                        await _showMeetTimePreferenceClockSheet(
                                      selectedValue: timePreference,
                                    );
                                    if (!context.mounted || selected == null) {
                                      return;
                                    }
                                    setSheetState(() {
                                      timePreference = selected;
                                    });
                                  },
                                ),
                                const SizedBox(height: 10),
                                SwitchListTile.adaptive(
                                  value: useAgeRange,
                                  activeThumbColor: _purple,
                                  contentPadding: EdgeInsets.zero,
                                  title: Text(
                                    'להוסיף טווח גילאים',
                                    style: TextStyle(
                                      color:
                                          isLight ? Colors.black : Colors.white,
                                    ),
                                  ),
                                  onChanged: (value) {
                                    setSheetState(() {
                                      useAgeRange = value;
                                    });
                                  },
                                ),
                                if (useAgeRange) ...[
                                  _buildMeetComposerAgeRange(
                                    isLight: isLight,
                                    ageRange: ageRange,
                                    onChanged: (value) {
                                      setSheetState(() {
                                        ageRange = value;
                                      });
                                    },
                                  ),
                                ],
                                const SizedBox(height: 10),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        ElevatedButton(
                          onPressed: () async {
                            final messenger =
                                ScaffoldMessenger.of(this.context);
                            final title = _meetTitleController.text.trim();
                            if (title.isEmpty) {
                              _showMeetComposerCenterNotice(
                                'חייבים כותרת לפופ',
                              );
                              return;
                            }
                            FocusScope.of(sheetContext).unfocus();
                            try {
                              await _homeService.createMeetNowPost(
                                title: title,
                                details: _meetDetailsController.text.trim(),
                                category: category ?? '',
                                subCategory: subCategory ?? '',
                                meetingLocation: '',
                                desiredParticipants: desiredParticipants,
                                timePreference: timePreference,
                                minAge:
                                    useAgeRange ? ageRange.start.round() : null,
                                maxAge:
                                    useAgeRange ? ageRange.end.round() : null,
                              );
                              if (!mounted) {
                                return;
                              }
                              if (!sheetContext.mounted) {
                                return;
                              }
                              Navigator.of(sheetContext).pop();
                              messenger.showSnackBar(
                                const SnackBar(
                                    content: Text('הפרסום עלה בהצלחה')),
                              );
                            } catch (error) {
                              if (!mounted) {
                                return;
                              }
                              messenger.showSnackBar(
                                SnackBar(
                                    content: Text(
                                        _friendlyPublishErrorMessage(error))),
                              );
                            }
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _purple,
                            foregroundColor:
                                isLight ? Colors.black : Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                          child: const Text('פרסם עכשיו'),
                        ),
                      ],
                    ),
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

  void _showMeetComposerCenterNotice(String message) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) {
      return;
    }

    late final OverlayEntry entry;
    var removed = false;

    void dismissNotice() {
      if (removed) {
        return;
      }
      removed = true;
      entry.remove();
    }

    entry = OverlayEntry(
      builder: (_) => Positioned.fill(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: dismissNotice,
          child: Center(
            child: Container(
              constraints: const BoxConstraints(maxWidth: 330),
              margin: const EdgeInsets.symmetric(horizontal: 24),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                gradient: const LinearGradient(
                  colors: [Color(0xFF8DE8FF), Color(0xFFC9B5FF)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                border: isLight
                    ? null
                    : Border.all(
                        color: Colors.black,
                        width: 1.2,
                      ),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF8E7DFF).withValues(alpha: 0.26),
                    blurRadius: 18,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Directionality(
                textDirection: TextDirection.rtl,
                child: Text(
                  message,
                  textAlign: TextAlign.center,
                  softWrap: true,
                  style: const TextStyle(
                    color: Colors.black,
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                    height: 1.3,
                    decoration: TextDecoration.none,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    overlay.insert(entry);
    Future<void>.delayed(const Duration(seconds: 2), () {
      dismissNotice();
    });
  }

  void _showMeetPublishLimitNotice() {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) {
      return;
    }

    late final OverlayEntry entry;
    var removed = false;

    void dismissNotice() {
      if (removed) {
        return;
      }
      removed = true;
      entry.remove();
    }

    entry = OverlayEntry(
      builder: (_) => Positioned.fill(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: dismissNotice,
          child: Center(
            child: Container(
              constraints: const BoxConstraints(maxWidth: 330),
              margin: const EdgeInsets.symmetric(horizontal: 24),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                gradient: const LinearGradient(
                  colors: [Color(0xFF8DE8FF), Color(0xFFC9B5FF)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                border: isLight
                    ? null
                    : Border.all(
                        color: Colors.black,
                        width: 1.2,
                      ),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF8E7DFF).withValues(alpha: 0.28),
                    blurRadius: 18,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: const Directionality(
                textDirection: TextDirection.rtl,
                child: Text(
                  'ניתן להעלות עד 2 פופים בשעה!',
                  textAlign: TextAlign.center,
                  softWrap: true,
                  style: TextStyle(
                    color: Colors.black,
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                    height: 1.3,
                    decoration: TextDecoration.none,
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
      dismissNotice();
    });
  }

  String _formatDate(DateTime? dateTime) {
    if (dateTime == null) {
      return 'לא צוין';
    }
    final day = dateTime.day.toString().padLeft(2, '0');
    final month = dateTime.month.toString().padLeft(2, '0');
    final hour = dateTime.hour.toString().padLeft(2, '0');
    final minute = dateTime.minute.toString().padLeft(2, '0');
    return '$day/$month $hour:$minute';
  }

  String _formatRelativeTime(DateTime dateTime) {
    final diff = DateTime.now().difference(dateTime);
    if (diff.inMinutes < 1) {
      return 'פורסם עכשיו';
    }
    if (diff.inHours < 1) {
      return 'פורסם לפני ${diff.inMinutes} דקות';
    }
    if (diff.inDays < 1) {
      return 'פורסם לפני ${diff.inHours} שעות';
    }
    if (diff.inDays < 7) {
      return 'פורסם לפני ${diff.inDays} ימים';
    }
    return 'פורסם ב-${_formatDate(dateTime)}';
  }

  String _friendlyJoinErrorMessage(Object error) {
    if (error is GroupJoinException) {
      if (error.code == 'insufficient-score' && error.minScore != null) {
        final current = error.userScore ?? 0;
        return 'נדרש מינימום ${error.minScore} נקודות. הניקוד שלך: $current.';
      }
      return error.message;
    }
    if (error is FirebaseException) {
      return error.message ?? 'ההצטרפות נכשלה.';
    }
    return 'ההצטרפות נכשלה. נסה שוב בעוד רגע.';
  }

  String _friendlyPublishErrorMessage(Object error) {
    if (error is MeetNowPublishLimitException) {
      return 'אפשר לפרסם עד 2 פופים בשעה. בינתיים שווה להציץ בפופים של משתמשים אחרים.';
    }
    if (error is FirebaseException && error.code == 'permission-denied') {
      return 'אין הרשאה לפרסם כרגע. אם הבעיה ממשיכה, נסה שוב אחרי התחברות מחדש.';
    }
    if (error is FirebaseException) {
      return error.message ?? 'הפרסום נכשל. נסה שוב בעוד רגע.';
    }
    return 'הפרסום נכשל. נסה שוב בעוד רגע.';
  }

  String _distanceBucketText(double? meters) {
    if (meters == null || meters.isNaN || meters.isInfinite || meters < 0) {
      return 'מרחק לא זמין';
    }
    final km = meters / 1000;
    if (km < 1) return 'פחות מ-1 ק"מ ממך';
    if (km < 3) return '1-3 ק"מ ממך';
    if (km < 5) return '3-5 ק"מ ממך';
    if (km < 10) return '5-10 ק"מ ממך';
    if (km < 20) return '10-20 ק"מ ממך';
    if (km < 30) return '20-30 ק"מ ממך';
    if (km < 40) return '30-40 ק"מ ממך';
    if (km < 50) return '40-50 ק"מ ממך';
    if (km < 60) return '50-60 ק"מ ממך';
    if (km < 70) return '60-70 ק"מ ממך';
    if (km < 80) return '70-80 ק"מ ממך';
    if (km < 90) return '80-90 ק"מ ממך';
    return 'מעל 90 ק"מ ממך';
  }

  Future<void> _openMeetPostsViewer({
    required List<MeetNowPostEntry> entries,
    required int initialIndex,
  }) async {
    if (entries.isEmpty) {
      return;
    }

    await Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _MeetNowPostsViewer(
          entries: entries,
          initialIndex: initialIndex,
          onJoinPressed: _handleMeetJoinTap,
          onOpenProfilePressed: _openProfile,
          relativeTimeBuilder: _formatRelativeTime,
        ),
      ),
    );
  }

  Future<bool> _handleMeetJoinTap(MeetNowPostEntry entry) async {
    try {
      late final String targetGroupId;
      if (entry.linkedGroupId.trim().isEmpty) {
        targetGroupId = await _homeService.createGroupForMeetNowPost(entry);
        await _groupService.joinGroup(targetGroupId);
      } else {
        targetGroupId = entry.linkedGroupId.trim();
        await _groupService.joinGroup(targetGroupId);
      }

      await _homeService.registerMeetNowJoin(
        entry: entry,
        groupId: targetGroupId,
      );

      if (!mounted) {
        return true;
      }
      setState(() {
        final postId = entry.id.trim();
        if (postId.isNotEmpty) {
          _locallyHiddenMeetPostIds.add(postId);
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('הצטרפת בהצלחה לפופ')),
      );
      return true;
    } catch (error) {
      if (!mounted) {
        return false;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_friendlyJoinErrorMessage(error))),
      );
      return false;
    }
  }

  Future<void> _openGroupChatById({
    required String groupId,
    String fallbackName = 'קבוצה',
    String fallbackImageUrl = '',
  }) async {
    if (groupId.trim().isEmpty || !mounted) {
      return;
    }

    try {
      final chatDoc = await FirebaseFirestore.instance
          .collection('chats')
          .doc(groupId)
          .get();
      final groupDoc = await FirebaseFirestore.instance
          .collection('groups')
          .doc(groupId)
          .get();

      final chatData = chatDoc.data() ?? <String, dynamic>{};
      final groupData = groupDoc.data() ?? <String, dynamic>{};

      String pickText(Map<String, dynamic> data, List<String> keys) {
        for (final key in keys) {
          final raw = data[key];
          if (raw == null) {
            continue;
          }
          final value = raw.toString().trim();
          if (value.isNotEmpty) {
            return value;
          }
        }
        return '';
      }

      final chatName = pickText(chatData, const ['name']).isNotEmpty
          ? pickText(chatData, const ['name'])
          : pickText(groupData, const ['groupName', 'name']).isNotEmpty
              ? pickText(groupData, const ['groupName', 'name'])
              : fallbackName;

      final imageUrl = pickText(chatData, const ['groupImageUrl']).isNotEmpty
          ? pickText(chatData, const ['groupImageUrl'])
          : pickText(groupData, const ['groupImageUrl']).isNotEmpty
              ? pickText(groupData, const ['groupImageUrl'])
              : fallbackImageUrl;

      if (!mounted) {
        return;
      }

      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ChatRoomScreen(
            chatName: chatName,
            avatarUrl: imageUrl.isEmpty ? null : imageUrl,
            chatId: groupId,
            isDirectChat: false,
          ),
        ),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('פתיחת הקבוצה נכשלה: $error')),
      );
    }
  }

  Future<void> _showUpcomingGroupDialog(HomePublicGroupEntry entry) async {
    final isLight = Theme.of(context).brightness == Brightness.light;
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black54,
      builder: (dialogContext) {
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 18, vertical: 24),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(26),
              gradient: isLight
                  ? const LinearGradient(
                      colors: [Color(0xFFE7EEFF), Color(0xFFDCCEFF)],
                    )
                  : const LinearGradient(
                      colors: [Color(0xFF53C1F9), Color(0xFF9E7CFF)],
                    ),
            ),
            padding: const EdgeInsets.all(1.8),
            child: Container(
              decoration: BoxDecoration(
                color: isLight ? Colors.white : const Color(0xFF101826),
                borderRadius: BorderRadius.circular(24),
              ),
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
              child: FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                future: FirebaseFirestore.instance
                    .collection('groups')
                    .doc(entry.groupId)
                    .get(),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting &&
                      !snapshot.hasData) {
                    return const SizedBox(
                      height: 280,
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }

                  final groupData =
                      snapshot.data?.data() ?? <String, dynamic>{};
                  final ageRange =
                      (groupData['ageRange'] as Map<String, dynamic>?) ??
                          const <String, dynamic>{};
                  final minAge = (ageRange['min'] as num?)?.toInt();
                  final maxAge = (ageRange['max'] as num?)?.toInt();
                  final approvalRequired =
                      (groupData['isAdminApprovalRequired'] as bool?) ?? false;

                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        entry.name,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: isLight ? Colors.black : Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _infoPill(
                              Icons.event_rounded, _formatDate(entry.date)),
                          _infoPill(
                              Icons.place_rounded,
                              entry.location.isEmpty
                                  ? 'לא צוין'
                                  : entry.location),
                          _infoPill(
                            categoryIconFor(entry.category.isEmpty
                                ? kGeneralCategory
                                : entry.category),
                            entry.subCategory.isEmpty
                                ? (entry.category.isEmpty
                                    ? kGeneralCategory
                                    : entry.category)
                                : '${entry.category.isEmpty ? kGeneralCategory : entry.category} • ${entry.subCategory}',
                          ),
                          _infoPill(
                            Icons.people_alt_rounded,
                            '${entry.membersCount} משתתפים',
                          ),
                          _infoPill(
                            Icons.local_fire_department_rounded,
                            entry.isMinScoreRequired && entry.minScore > 0
                                ? 'מינימום ${entry.minScore} נקודות'
                                : 'ללא מינימום ניקוד',
                          ),
                          _infoPill(
                            Icons.cake_rounded,
                            (minAge != null && maxAge != null)
                                ? '$minAge-$maxAge'
                                : 'ללא הגבלת גיל',
                          ),
                          _infoPill(
                            approvalRequired
                                ? Icons.verified_user_rounded
                                : Icons.verified_rounded,
                            approvalRequired
                                ? 'דורש אישור מנהל'
                                : 'הצטרפות חופשית',
                          ),
                        ],
                      ),
                      if (entry.description.isNotEmpty) ...[
                        const SizedBox(height: 14),
                        Text(
                          entry.description,
                          textAlign: TextAlign.right,
                          style: TextStyle(
                            color: isLight
                                ? Colors.black87
                                : const Color(0xFFD8E3F8),
                            fontSize: 14,
                            height: 1.45,
                          ),
                        ),
                      ],
                      const SizedBox(height: 16),
                      StreamBuilder<String?>(
                        stream: _groupService.myMembershipStatus(entry.groupId),
                        builder: (context, statusSnapshot) {
                          final status = statusSnapshot.data;
                          final isPending = status == 'pending';
                          final isApproved = status == 'approved';

                          return ElevatedButton(
                            onPressed: () async {
                              if (isApproved) {
                                Navigator.of(dialogContext).pop();
                                await _openGroupChatById(
                                  groupId: entry.groupId,
                                  fallbackName: entry.name,
                                  fallbackImageUrl: entry.imageUrl,
                                );
                                return;
                              }

                              if (isPending) {
                                Navigator.of(dialogContext).pop();
                                return;
                              }

                              try {
                                await _groupService.joinGroup(entry.groupId);
                                if (!mounted) {
                                  return;
                                }
                                ScaffoldMessenger.of(this.context).showSnackBar(
                                  const SnackBar(
                                      content:
                                          Text('ההצטרפות נשלחה/בוצעה בהצלחה')),
                                );
                              } catch (error) {
                                if (!mounted) {
                                  return;
                                }
                                ScaffoldMessenger.of(this.context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      _friendlyJoinErrorMessage(error),
                                    ),
                                  ),
                                );
                              }
                            },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: isLight
                                  ? (isApproved
                                      ? const Color(0xFFE8EEFF)
                                      : (isPending
                                          ? const Color(0xFFE8EEFF)
                                          : const Color(0xFF9E7CFF)))
                                  : (isApproved
                                      ? _cyan
                                      : (isPending ? _cyan : _purple)),
                              foregroundColor: isLight
                                  ? (isApproved || isPending
                                      ? const Color(0xFF1E2A45)
                                      : Colors.black)
                                  : Colors.white,
                              side: isLight && !isApproved && !isPending
                                  ? BorderSide.none
                                  : (isLight
                                      ? const BorderSide(
                                          color: Color(0xFFA9C3FF),
                                        )
                                      : BorderSide.none),
                              padding: const EdgeInsets.symmetric(vertical: 13),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                            child: Text(
                              isApproved
                                  ? 'צפייה בקבוצה'
                                  : (isPending
                                      ? 'בקשתך נשלחה'
                                      : 'הצטרפות לקבוצה'),
                            ),
                          );
                        },
                      ),
                      const SizedBox(height: 10),
                      OutlinedButton(
                        onPressed: () => Navigator.of(dialogContext).pop(),
                        child: const Text('סגור'),
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

  Future<void> _showGroupMembersSheet(String groupId) async {
    final members = await _homeService.fetchApprovedGroupMembers(groupId);
    if (!mounted) {
      return;
    }

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF101826),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'חברי הקבוצה',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 18,
                  ),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: members.isEmpty
                      ? const Center(
                          child: Text(
                            'אין חברים להצגה כרגע',
                            style: TextStyle(color: Colors.white70),
                          ),
                        )
                      : ListView.builder(
                          itemCount: members.length,
                          itemBuilder: (context, index) {
                            final member = members[index];
                            return ListTile(
                              dense: true,
                              visualDensity: const VisualDensity(
                                horizontal: -1,
                                vertical: -2,
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 1,
                              ),
                              onTap: () => _openProfile(member.uid),
                              leading: CircleAvatar(
                                radius: 17,
                                backgroundColor: _purple,
                                backgroundImage: member.avatarUrl.isNotEmpty
                                    ? NetworkImage(member.avatarUrl)
                                    : null,
                                child: member.avatarUrl.isEmpty
                                    ? Text(
                                        member.name.characters.first,
                                        style: const TextStyle(
                                            color: Colors.white),
                                      )
                                    : null,
                              ),
                              title: Text(
                                member.name,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                ),
                              ),
                              subtitle: Text(
                                member.handle,
                                style: const TextStyle(
                                  color: Colors.white54,
                                  fontSize: 11,
                                ),
                              ),
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

  // ignore: unused_element
  Future<void> _showMeetPostDialog(MeetNowPostEntry entry) async {
    final isLight = Theme.of(context).brightness == Brightness.light;
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black54,
      builder: (dialogContext) {
        final isLinkedGroup = entry.linkedGroupId.trim().isNotEmpty;

        Widget buildDialogBody(bool isJoinClosed) {
          return Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(26),
              gradient: const LinearGradient(
                colors: [Color(0xFF53C1F9), Color(0xFF9E7CFF)],
              ),
            ),
            padding: const EdgeInsets.all(1.8),
            child: Container(
              decoration: BoxDecoration(
                color: isLight ? Colors.white : const Color(0xFF101826),
                borderRadius: BorderRadius.circular(24),
              ),
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      CircleAvatar(
                        radius: 26,
                        backgroundColor: _purple,
                        backgroundImage: entry.authorAvatarUrl.isNotEmpty
                            ? NetworkImage(entry.authorAvatarUrl)
                            : null,
                        child: entry.authorAvatarUrl.isEmpty
                            ? Text(
                                entry.authorName.characters.first,
                                style: TextStyle(
                                  color: isLight ? Colors.black : Colors.white,
                                ),
                              )
                            : null,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              entry.title,
                              style: TextStyle(
                                color: isLight ? Colors.black : Colors.white,
                                fontWeight: FontWeight.w800,
                                fontSize: 18,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${entry.authorName} • ${entry.authorHandle}',
                              style: TextStyle(
                                color:
                                    isLight ? Colors.black54 : Colors.white70,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _distanceBucketText(entry.distanceMetersFromCurrentUser),
                      style: TextStyle(
                        color: isLight ? const Color(0xFF23385A) : Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _infoPill(
                        Icons.place_rounded,
                        entry.meetingLocation.isEmpty
                            ? 'מיקום לא צוין'
                            : entry.meetingLocation,
                      ),
                      _infoPill(
                        Icons.schedule_rounded,
                        entry.timePreference.isEmpty
                            ? 'לא צוין זמן'
                            : entry.timePreference,
                      ),
                      _infoPill(
                        Icons.access_time_rounded,
                        _formatRelativeTime(entry.createdAt),
                      ),
                      _infoPill(Icons.stars_rounded, '${entry.authorScore} נקודות'),
                      if (entry.linkedGroupMembersCount > 0)
                        _infoPill(Icons.people_alt_rounded,
                            '${entry.linkedGroupMembersCount} חברים'),
                      if (entry.category.isNotEmpty ||
                          entry.subCategory.isNotEmpty)
                        _infoPill(
                          categoryIconFor(entry.category.isEmpty
                              ? kGeneralCategory
                              : entry.category),
                          entry.subCategory.isEmpty
                              ? entry.category
                              : '${entry.category} • ${entry.subCategory}',
                        ),
                      if (entry.minAge != null && entry.maxAge != null)
                        _infoPill(Icons.cake_rounded,
                            '${entry.minAge}-${entry.maxAge}'),
                      if (entry.desiredParticipants != null)
                        _infoPill(Icons.groups_rounded,
                            '${entry.desiredParticipants} משתתפים רצויים'),
                    ],
                  ),
                  if (isJoinClosed) ...[
                    const SizedBox(height: 12),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFEBEB),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: const Color(0xFFFF5B5B)),
                      ),
                      child: const Text(
                        'המנהל סגר את האפשרות להצטרף לקבוצה זו.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Color(0xFFB32727),
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                  if (entry.details.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    Text(
                      entry.details,
                      style: TextStyle(
                        color:
                            isLight ? Colors.black87 : const Color(0xFFD8E3F8),
                        fontSize: 14,
                        height: 1.45,
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  if (!isLinkedGroup) ...[
                    ElevatedButton(
                      onPressed: () async {
                        final messenger = ScaffoldMessenger.of(dialogContext);
                        try {
                          final targetGroupId = await _homeService
                              .createGroupForMeetNowPost(entry);
                          await _groupService.joinGroup(targetGroupId);
                          await _homeService.registerMeetNowJoin(
                            entry: entry,
                            groupId: targetGroupId,
                          );
                          if (!mounted) {
                            return;
                          }
                          setState(() {
                            final postId = entry.id.trim();
                            if (postId.isNotEmpty) {
                              _locallyHiddenMeetPostIds.add(postId);
                            }
                          });
                          if (!dialogContext.mounted) {
                            return;
                          }
                          Navigator.of(dialogContext).pop();
                          messenger.showSnackBar(
                            const SnackBar(content: Text('הצטרפת להצעה בהצלחה')),
                          );
                        } catch (error) {
                          if (!mounted) {
                            return;
                          }
                          messenger.showSnackBar(
                            SnackBar(
                                content: Text('ההצטרפות להצעה נכשלה: $error')),
                          );
                        }
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _purple,
                        foregroundColor: isLight ? Colors.black : Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 13),
                      ),
                      child: const Text('הצטרפות להצעה'),
                    ),
                    const SizedBox(height: 10),
                    OutlinedButton(
                      onPressed: () => _openProfile(entry.authorUid),
                      child: const Text('הצגת הפרופיל של המשתמש'),
                    ),
                  ] else ...[
                    ElevatedButton(
                      onPressed: () =>
                          _showGroupMembersSheet(entry.linkedGroupId),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _surfaceSoft,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 13),
                      ),
                      child: const Text('רשימת חברים'),
                    ),
                    const SizedBox(height: 10),
                    StreamBuilder<String?>(
                      stream:
                          _groupService.myMembershipStatus(entry.linkedGroupId),
                      builder: (context, statusSnapshot) {
                        final status = statusSnapshot.data;
                        final isPending = status == 'pending';
                        final isApproved = status == 'approved';
                        final canJoinNow = !isJoinClosed && !isPending && !isApproved;

                        return ElevatedButton(
                          onPressed: isApproved
                              ? () async {
                                  Navigator.of(dialogContext).pop();
                                  await _openGroupChatById(
                                    groupId: entry.linkedGroupId,
                                    fallbackName: entry.title,
                                  );
                                }
                              : (isPending
                                  ? null
                                  : (canJoinNow
                                      ? () async {
                                          final messenger =
                                            ScaffoldMessenger.of(dialogContext);
                                          try {
                                            await _groupService
                                                .joinGroup(entry.linkedGroupId);
                                            await _homeService.registerMeetNowJoin(
                                              entry: entry,
                                              groupId: entry.linkedGroupId,
                                            );
                                            if (!mounted) {
                                              return;
                                            }
                                            setState(() {
                                              final postId = entry.id.trim();
                                              if (postId.isNotEmpty) {
                                                _locallyHiddenMeetPostIds
                                                    .add(postId);
                                              }
                                            });
                                            messenger.showSnackBar(
                                              const SnackBar(
                                                content: Text(
                                                    'בקשת ההצטרפות נשלחה/בוצעה'),
                                              ),
                                            );
                                          } catch (error) {
                                            if (!mounted) {
                                              return;
                                            }
                                            messenger.showSnackBar(
                                              SnackBar(
                                                content: Text(
                                                  _friendlyJoinErrorMessage(
                                                      error),
                                                ),
                                              ),
                                            );
                                          }
                                        }
                                      : null)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: isApproved
                                ? _cyan
                                : (isJoinClosed
                                    ? const Color(0xFF8A3940)
                                    : (isPending ? _cyan : _purple)),
                            foregroundColor:
                                isLight ? Colors.black : Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 13),
                          ),
                          child: Text(
                            isApproved
                                ? 'צפייה בקבוצה'
                                : (isJoinClosed
                                    ? 'אי אפשר להצטרף כרגע'
                                    : (isPending
                                        ? 'בקשתך נשלחה'
                                        : 'הצטרפות לקבוצה')),
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 10),
                    OutlinedButton(
                      onPressed: () => _openProfile(entry.authorUid),
                      child: const Text('הצגת הפרופיל של המשתמש'),
                    ),
                  ],
                ],
              ),
            ),
          );
        }

        if (!isLinkedGroup) {
          return Dialog(
            backgroundColor: Colors.transparent,
            insetPadding:
                const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
            child: buildDialogBody(false),
          );
        }

        return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: _groupPrivacyStream(entry.linkedGroupId),
          builder: (context, groupSnapshot) {
            final groupData = groupSnapshot.data?.data() ?? <String, dynamic>{};
            final isJoinClosed = _isMeetJoinClosed(groupData);

            return Dialog(
              backgroundColor: Colors.transparent,
              insetPadding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
              child: buildDialogBody(isJoinClosed),
            );
          },
        );
      },
    );
  }

  Widget _infoPill(IconData icon, String text) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: isLight ? const Color(0xFFF1F5FF) : const Color(0xFF17263C),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color:
              isLight ? const Color(0xFFA9C3FF) : _cyan.withValues(alpha: 0.28),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 14,
            color: isLight ? const Color(0xFF5A6CFF) : _cyanSoft,
          ),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(
              color: isLight ? const Color(0xFF22314F) : Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFriendsSection() {
    final isLight = Theme.of(context).brightness == Brightness.light;
    return StreamBuilder<List<HomeFriendEntry>>(
      stream: _connectedFriendsStream,
      builder: (context, snapshot) {
        final friends = snapshot.data ?? const <HomeFriendEntry>[];

        return Container(
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 14),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
              child: Container(
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(24),
                  color: isLight ? Colors.white : const Color(0x99202A44),
                  border: Border.all(
                    color: isLight
                        ? const Color(0xFFA9C3FF)
                        : Colors.white.withValues(alpha: 0.14),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: (isLight
                              ? const Color(0xFF7DB2FF)
                              : const Color(0xFF56C7FF))
                          .withValues(alpha: 0.16),
                      blurRadius: 18,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Stack(
                      alignment: Alignment.center,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(14, 16, 14, 0),
                          child: Text(
                            'היי!\nנתחיל משהו כיפי?',
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: isLight ? Colors.black : Colors.white,
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                              height: 1.12,
                            ),
                          ),
                        ),
                        Positioned(
                          top: 7,
                          right: 6,
                          child: _buildForceOnlineButton(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Center(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(999),
                          gradient: const LinearGradient(
                            colors: [Color(0xFFAA71FF), Color(0xFFFF5DAF)],
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFFA971FF)
                                  .withValues(alpha: 0.35),
                              blurRadius: 14,
                              offset: const Offset(0, 6),
                            ),
                          ],
                        ),
                        child: TextButton(
                          onPressed: _openMeetComposerSheet,
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 8,
                            ),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          child: const Text(
                            'בואו נתחיל',
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (snapshot.connectionState == ConnectionState.waiting &&
                        !snapshot.hasData)
                      const SizedBox(
                        height: 36,
                        child: Center(
                            child: CircularProgressIndicator(strokeWidth: 2)),
                      )
                    else if (friends.isEmpty)
                      Text(
                        'אין כרגע חברים מחוברים',
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          color: isLight ? Colors.black54 : Colors.white70,
                          fontSize: 12,
                        ),
                      )
                    else
                      SizedBox(
                        height: 92,
                        child: Directionality(
                          textDirection: TextDirection.rtl,
                          child: ListView.separated(
                            reverse: false,
                            scrollDirection: Axis.horizontal,
                            itemCount: friends.take(10).length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(width: 10),
                            itemBuilder: (context, index) {
                              final friend = friends[index];
                              return GestureDetector(
                                onTap: () => _openDirectChat(friend),
                                child: SizedBox(
                                  width: 64,
                                  child: Column(
                                    children: [
                                      CircleAvatar(
                                        radius: 28,
                                        backgroundColor: isLight
                                            ? const Color(0xFFE8EEFF)
                                            : const Color(0xFF4D3A79),
                                        backgroundImage:
                                            friend.avatarUrl.isNotEmpty
                                                ? NetworkImage(friend.avatarUrl)
                                                : null,
                                        child: friend.avatarUrl.isEmpty
                                            ? Text(
                                                friend.name.characters.first,
                                                style: TextStyle(
                                                  color: isLight
                                                      ? Colors.black
                                                      : Colors.white,
                                                  fontWeight: FontWeight.w700,
                                                ),
                                              )
                                            : null,
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        friend.name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          color: isLight
                                              ? Colors.black
                                              : Colors.white,
                                          fontSize: 11,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
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

  Widget _buildForceOnlineButton() {
    final isLight = Theme.of(context).brightness == Brightness.light;
    return ValueListenableBuilder<int>(
      valueListenable: _sectionRefreshTick,
      builder: (context, _, __) {
        return StreamBuilder<DateTime?>(
          stream: _forcedOnlineUntilStream,
          builder: (context, onlineSnapshot) {
            final forcedUntil = onlineSnapshot.data;
            final isForcedOnline =
                forcedUntil != null && forcedUntil.isAfter(DateTime.now());

            final borderColor = isLight
                ? (isForcedOnline
                    ? const Color(0xFF3FAF63)
                    : const Color(0xFFA9C3FF))
                : (isForcedOnline
                    ? const Color(0xFF7BFF9E)
                    : _cyan.withValues(alpha: 0.9));
            final backgroundColor = isLight
                ? Colors.white
                : (isForcedOnline
                    ? const Color(0xFF1F7A3A)
                    : _purple.withValues(alpha: 0.2));
            final foregroundColor = isLight
                ? (isForcedOnline ? const Color(0xFF2E8B57) : Colors.black)
                : (isForcedOnline ? Colors.white : _cyanSoft);

            return DecoratedBox(
              decoration: BoxDecoration(
                color: backgroundColor,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: borderColor, width: 1.2),
              ),
              child: TextButton.icon(
                onPressed: () {
                  if (isForcedOnline) {
                    _showForcedOnlineRemainingBubble(forcedUntil);
                    return;
                  }
                  _openForceOnlineSheet();
                },
                style: TextButton.styleFrom(
                  foregroundColor: foregroundColor,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 5),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  minimumSize: Size.zero,
                ),
                icon: Icon(
                  isForcedOnline
                      ? Icons.check_circle_rounded
                      : Icons.toggle_on_rounded,
                  size: 14,
                ),
                label: Text(
                  isForcedOnline ? 'online' : 'הראה שאני מחובר',
                  style: const TextStyle(
                      fontSize: 10.5, fontWeight: FontWeight.w800),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildWeeklyChallengeSection() {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final challenge = WeeklyChallengeService.currentChallenge();
    final challengeIcon = categoryIconFor(
      challenge.mainCategory.isEmpty
          ? kGeneralCategory
          : challenge.mainCategory,
    );

    return GestureDetector(
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const StarsScreen()),
        );
      },
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(26),
          color: isLight ? Colors.white.withValues(alpha: 0.72) : null,
          gradient: isLight
              ? null
              : const LinearGradient(
                  colors: [
                    Color(0xFF131A2B),
                    Color(0xFF25243D),
                    Color(0xFF2E2A4D)
                  ],
                  begin: Alignment.topRight,
                  end: Alignment.bottomLeft,
                ),
          border: Border.all(
            color: isLight
                ? const Color(0xFFA9C3FF)
                : Colors.white.withValues(alpha: 0.08),
          ),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF7A6BFF).withValues(alpha: 0.24),
              blurRadius: 22,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Stack(
          children: [
            Positioned(
              left: 0,
              top: 8,
              child: Column(
                children: [
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: const LinearGradient(
                        colors: [Color(0xFF53C1F9), Color(0xFF9E7CFF)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color:
                              const Color(0xFF8B78FF).withValues(alpha: 0.35),
                          blurRadius: 16,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: Icon(
                      challengeIcon,
                      color: Colors.white,
                      size: 29,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Icon(
                    Icons.location_city_rounded,
                    color: Color(0xFF8BA3C8),
                    size: 26,
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 76, right: 8, bottom: 8),
              child: Directionality(
                textDirection: TextDirection.rtl,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'אתגר השבועי',
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        color: isLight
                            ? Colors.black87
                            : Colors.white.withValues(alpha: 0.96),
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      challenge.mainCategory.isEmpty
                          ? 'אויל'
                          : challenge.mainCategory,
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        color: isLight ? Colors.black : Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'השתתפו באתגר השבועי וקבלו ניקוד מוכפל ומשולש',
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        color:
                            isLight ? Colors.black54 : const Color(0xFFC4CBE1),
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildUpcomingGroupsSection() {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final isDesktopWide = MediaQuery.of(context).size.width >= 1000;
    return StreamBuilder<List<HomePublicGroupEntry>>(
      stream: _upcomingGroupsStream,
      builder: (context, snapshot) {
        final groups = snapshot.data ?? const <HomePublicGroupEntry>[];
        final visibleGroups = groups.take(7).toList(growable: false);
        final prefetchKey = visibleGroups
            .map((group) => '${group.groupId}:${group.participants.length}')
            .join('|');
        if (prefetchKey != _lastUpcomingPrefetchKey) {
          _lastUpcomingPrefetchKey = prefetchKey;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) {
              return;
            }
            _prefetchUpcomingGroupMemberAvatars(visibleGroups);
          });
        }

        return _sectionShell(
          title: 'עושים משהו בקרוב',
          trailing: TextButton(
            onPressed: _openUpcomingGroupsPage,
            child: const Text('הצג עוד'),
          ),
          child: SizedBox(
            height: 236,
            child: snapshot.connectionState == ConnectionState.waiting &&
                    !snapshot.hasData
                ? const Center(child: CircularProgressIndicator())
                : groups.isNotEmpty
                    ? Column(
                        children: [
                          SizedBox(
                            height: 170,
                            child: Stack(
                              children: [
                                ListView.builder(
                                  controller: _upcomingGroupsScrollController,
                                  scrollDirection: Axis.horizontal,
                                  itemCount: visibleGroups.length,
                                  itemBuilder: (context, index) {
                                    final group = visibleGroups[index];
                                    return Padding(
                                      padding: const EdgeInsets.only(left: 10),
                                      child: GestureDetector(
                                        onTap: () =>
                                            _showUpcomingGroupDialog(group),
                                        child: Container(
                                          width: 150,
                                          padding: const EdgeInsets.all(12),
                                          decoration: BoxDecoration(
                                            borderRadius:
                                                BorderRadius.circular(20),
                                            color:
                                                isLight ? Colors.white : null,
                                            gradient: isLight
                                                ? null
                                                : const LinearGradient(
                                                    colors: [
                                                      Color(0xFF18243D),
                                                      Color(0xFF302455)
                                                    ],
                                                    begin: Alignment.topRight,
                                                    end: Alignment.bottomLeft,
                                                  ),
                                            border: Border.all(
                                              color: isLight
                                                  ? const Color(0xFFA9C3FF)
                                                  : const Color(0xFF69A4EA)
                                                      .withValues(alpha: 0.45),
                                            ),
                                            boxShadow: [
                                              BoxShadow(
                                                color: const Color(0xFF8A74FF)
                                                    .withValues(alpha: 0.22),
                                                blurRadius: 14,
                                                offset: const Offset(0, 6),
                                              ),
                                            ],
                                          ),
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              _buildGroupParticipantsAvatars(
                                                  group),
                                              const SizedBox(height: 10),
                                              Text(
                                                group.name,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  color: isLight
                                                      ? Colors.black
                                                      : Colors.white,
                                                  fontSize: 14,
                                                  fontWeight: FontWeight.w800,
                                                ),
                                              ),
                                              const SizedBox(height: 3),
                                              Text(
                                                group.category.isNotEmpty
                                                    ? group.category
                                                    : 'ללא קטגוריה',
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  color: isLight
                                                      ? Colors.black54
                                                      : const Color(0xFFD0DAF0),
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                              const Spacer(),
                                              Text(
                                                _formatGroupDateTime(
                                                    group.date),
                                                style: TextStyle(
                                                  color: isLight
                                                      ? Colors.black54
                                                      : const Color(0xFFBDD2F3),
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    );
                                  },
                                ),
                                if (isDesktopWide && visibleGroups.length > 1)
                                  Positioned(
                                    left: 2,
                                    top: 60,
                                    child: Material(
                                      color: Colors.transparent,
                                      child: InkWell(
                                        borderRadius: BorderRadius.circular(12),
                                        onTap: _scrollUpcomingGroupsForward,
                                        child: Container(
                                          width: 26,
                                          height: 50,
                                          decoration: BoxDecoration(
                                            color: isLight
                                                ? Colors.white
                                                    .withValues(alpha: 0.92)
                                                : const Color(0xFF0D1727)
                                                    .withValues(alpha: 0.86),
                                            borderRadius:
                                                BorderRadius.circular(12),
                                            border: Border.all(
                                              color: isLight
                                                  ? const Color(0xFF9EBBFF)
                                                  : const Color(0xFF7A95C9)
                                                      .withValues(alpha: 0.7),
                                            ),
                                          ),
                                          child: Icon(
                                            Icons.chevron_left_rounded,
                                            size: 20,
                                            color: isLight
                                                ? const Color(0xFF3560C9)
                                                : const Color(0xFFE3EBFF),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                          DecoratedBox(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(14),
                              gradient: const LinearGradient(
                                colors: [Color(0xFF4F75FF), Color(0xFF985DFF)],
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(0xFF805CFF)
                                      .withValues(alpha: 0.34),
                                  blurRadius: 14,
                                  offset: const Offset(0, 6),
                                ),
                              ],
                            ),
                            child: ElevatedButton.icon(
                              onPressed: () {
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => const CreateGroupScreen(),
                                  ),
                                );
                              },
                              icon: const Icon(Icons.add_circle_rounded,
                                  size: 18),
                              label: const Text('יצירת קבוצה חדשה'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.transparent,
                                shadowColor: Colors.transparent,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 14, vertical: 10),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                            ),
                          ),
                        ],
                      )
                    : snapshot.hasError
                        ? _emptyCard(
                            'טעינת הקבוצות נכשלה כרגע. נסה שוב עוד רגע')
                        : groups.isEmpty
                            ? _emptyCard('אין קבוצות להצגה כרגע')
                            : _emptyCard('אין קבוצות להצגה כרגע'),
          ),
        );
      },
    );
  }

  String _formatGroupDateTime(DateTime? dateTime) {
    if (dateTime == null) {
      return 'לא צוין תאריך';
    }
    final day = dateTime.day.toString().padLeft(2, '0');
    final month = dateTime.month.toString().padLeft(2, '0');
    final hour = dateTime.hour.toString().padLeft(2, '0');
    final minute = dateTime.minute.toString().padLeft(2, '0');
    return '$hour:$minute $day/$month';
  }

  List<String> _groupParticipantAvatarUrls(HomePublicGroupEntry group) {
    final resolvedUrls = group.participantAvatarUrls
        .map((url) => url.trim())
        .where((url) => url.isNotEmpty)
        .toList(growable: false);
    if (resolvedUrls.isNotEmpty) {
      return resolvedUrls.take(7).toList(growable: false);
    }

    final byUid = <String>[];
    for (final raw in group.participants) {
      final uid = raw.toString().trim();
      if (uid.isEmpty) {
        continue;
      }
      final avatar = (_groupMemberAvatarByUid[uid] ?? '').trim();
      if (avatar.isEmpty || byUid.contains(avatar)) {
        continue;
      }
      byUid.add(avatar);
      if (byUid.length >= 7) {
        break;
      }
    }
    if (byUid.isNotEmpty) {
      return byUid;
    }

    final urls = <String>[];
    for (final participant in group.participants) {
      if (participant is Map) {
        final url = (participant['profilePictureUrl'] ??
                participant['avatarUrl'] ??
                participant['photoUrl'] ??
                '')
            .toString()
            .trim();
        if (url.isNotEmpty) {
          urls.add(url);
        }
      }
      if (urls.length >= 7) {
        break;
      }
    }
    return urls;
  }

  Widget _buildGroupParticipantsAvatars(HomePublicGroupEntry group) {
    final avatarUrls = _groupParticipantAvatarUrls(group);
    final participantCount = group.participants.length.clamp(1, 7);
    final count = avatarUrls.isNotEmpty
        ? avatarUrls.length.clamp(1, 7)
        : participantCount;
    final width = (count - 1) * 18 + 28;

    return SizedBox(
      width: width.toDouble(),
      height: 28,
      child: Stack(
        children: List.generate(count, (index) {
          final shades = <Color>[
            const Color(0xFF6EADE8),
            const Color(0xFF9E7CFF),
            const Color(0xFFFF73B8),
            const Color(0xFF59D0C6),
            const Color(0xFF8299FF),
            const Color(0xFFFF8FB3),
            const Color(0xFF6FA8FF),
          ];
          final label = group.name.trim();
          return Positioned(
            right: index * 16,
            child: CircleAvatar(
              radius: 14,
              backgroundColor: shades[index],
              backgroundImage: avatarUrls.isNotEmpty
                  ? NetworkImage(avatarUrls[index])
                  : null,
              child: avatarUrls.isEmpty
                  ? Text(
                      label.isNotEmpty ? label.characters.first : '•',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 10,
                      ),
                    )
                  : null,
            ),
          );
        }),
      ),
    );
  }

  Widget _buildDiscoverNowSection() {
    final isLight = Theme.of(context).brightness == Brightness.light;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      padding: const EdgeInsets.fromLTRB(0, 0, 0, 0),
      child: Directionality(
        textDirection: TextDirection.rtl,
        child: Row(
          children: [
            Text(
              'גלו עכשיו',
              textAlign: TextAlign.right,
              style: TextStyle(
                color: isLight
                    ? Colors.black
                    : Colors.white.withValues(alpha: 0.95),
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
            const Spacer(),
            DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                gradient: const LinearGradient(
                  colors: [Color(0xFF53C1F9), Color(0xFF9E7CFF)],
                ),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF8A74FF).withValues(alpha: 0.3),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: OutlinedButton.icon(
                onPressed: _openMeetFiltersSheet,
                icon: const Icon(Icons.tune_rounded, size: 16),
                label: const Text('סינון'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: BorderSide.none,
                  backgroundColor: Colors.transparent,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ignore: unused_element
  Widget _buildMeetNowSectionHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Row(
          children: [
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: ElevatedButton(
                  onPressed: _openMeetComposerSheet,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _purple,
                    foregroundColor: Colors.white,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    minimumSize: const Size(0, 36),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text(
                    '!בואו נעשה משהו',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: Align(
                alignment: Alignment.centerRight,
                child: Text(
                  ':מחפשים להיפגש עכשיו',
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.96),
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ignore: unused_element
  Widget _buildMeetNowFiltersBar() {
    final isLight = Theme.of(context).brightness == Brightness.light;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _hasActiveMeetFilters ? 'התוצאות מסוננות' : 'סינון פרסומים',
              style: TextStyle(
                color: isLight ? Colors.black54 : Colors.grey[300],
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          OutlinedButton.icon(
            onPressed: _openMeetFiltersSheet,
            icon: const Icon(Icons.tune_rounded, size: 16),
            label: const Text('סינון'),
            style: OutlinedButton.styleFrom(
              foregroundColor: isLight ? Colors.black : _cyanSoft,
              side: BorderSide(
                color: isLight
                    ? const Color(0xFFA9C3FF)
                    : _cyan.withValues(alpha: 0.7),
              ),
              backgroundColor: isLight ? Colors.white : null,
            ),
          ),
          if (_hasActiveMeetFilters) ...[
            const SizedBox(width: 8),
            TextButton(
              onPressed: () {
                setState(() {
                  _meetFilterAgeRange = RangeValues(
                    minimumUserAge.toDouble(),
                    maximumAgeRange.toDouble(),
                  );
                  _meetFilterMinScore = null;
                  _meetFilterCategory = null;
                  _meetFilterSubCategory = null;
                });
              },
              child: const Text('נקה'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildMeetNowGrid() {
    final isLight = Theme.of(context).brightness == Brightness.light;
    return StreamBuilder<List<MeetNowPostEntry>>(
      stream: _meetNowPostsStream,
      builder: (context, snapshot) {
        final allEntries = snapshot.data ?? const <MeetNowPostEntry>[];

        if (snapshot.connectionState == ConnectionState.waiting &&
            !snapshot.hasData) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 30),
            child: Center(child: CircularProgressIndicator()),
          );
        }

        return StreamBuilder<Set<String>>(
          stream: _blockUserService.streamBlockedConnections(),
          builder: (context, blockedSnapshot) {
            final blockedUserIds = blockedSnapshot.data ?? const <String>{};
            final visibleEntries = allEntries
                .where((entry) => !blockedUserIds.contains(entry.authorUid.trim()))
                .toList(growable: false);

            return ValueListenableBuilder<int>(
              valueListenable: _sectionRefreshTick,
              builder: (context, _, __) {
                final entries = _applyMeetFilters(visibleEntries);
                return Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
                  child: Directionality(
                    textDirection: TextDirection.rtl,
                    child: GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: entries.length + 1,
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 3,
                        crossAxisSpacing: 10,
                        mainAxisSpacing: 10,
                        childAspectRatio: 0.58,
                      ),
                      itemBuilder: (context, index) {
                        if (index == 0) {
                          return _buildStaticDiscoverPopCard();
                        }

                        final entry = entries[index - 1];
                        final card = Container(
                          decoration: BoxDecoration(
                            color: isLight ? Colors.white : null,
                            gradient: isLight
                                ? null
                                : LinearGradient(
                                    colors: [
                                      const Color(0xFF14233A)
                                          .withValues(alpha: 0.96),
                                      const Color(0xFF312357)
                                          .withValues(alpha: 0.96),
                                    ],
                                    begin: Alignment.topRight,
                                    end: Alignment.bottomLeft,
                                  ),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: isLight
                                  ? const Color(0xFFA9C3FF)
                                  : _cyan.withValues(alpha: 0.18),
                            ),
                          ),
                          padding: const EdgeInsets.all(10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(
                                child: Stack(
                                  children: [
                                    Positioned.fill(
                                      child: ClipRRect(
                                        borderRadius: BorderRadius.circular(16),
                                        child: Container(
                                          color: isLight
                                              ? const Color(0xFFEFF5FF)
                                              : const Color(0xFF0D1524),
                                          child: entry.authorAvatarUrl.isNotEmpty
                                              ? Image.network(
                                                  entry.authorAvatarUrl,
                                                  fit: BoxFit.cover,
                                                  errorBuilder: (_, __, ___) => Icon(
                                                    Icons.person_outline_rounded,
                                                    color: isLight
                                                        ? Colors.black45
                                                        : Colors.white54,
                                                    size: 30,
                                                  ),
                                                )
                                              : Icon(
                                                  Icons.person_outline_rounded,
                                                  color: isLight
                                                      ? Colors.black45
                                                      : Colors.white54,
                                                  size: 30,
                                                ),
                                        ),
                                      ),
                                    ),
                                    Positioned(
                                      top: 8,
                                      right: 8,
                                      child: () {
                                        final count = math.max(
                                          1,
                                          entry.linkedGroupMembersCount,
                                        );
                                        final countLabel =
                                            count == 1 ? '1 חבר' : '$count חברים';
                                        return Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 5,
                                          ),
                                          decoration: BoxDecoration(
                                            color: isLight
                                                ? Colors.white.withValues(alpha: 0.9)
                                                : const Color(0xCC111A28),
                                            borderRadius:
                                                BorderRadius.circular(999),
                                            border: Border.all(
                                              color: _cyan.withValues(alpha: 0.45),
                                            ),
                                          ),
                                          child: Text(
                                            countLabel,
                                            style: TextStyle(
                                              color: isLight
                                                  ? Colors.black
                                                  : Colors.white,
                                              fontSize: 10,
                                              fontWeight: FontWeight.w800,
                                            ),
                                          ),
                                        );
                                      }(),
                                    ),
                                    if (entry.linkedGroupId.trim().isNotEmpty)
                                      StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                                        stream: _groupPrivacyStream(
                                          entry.linkedGroupId,
                                        ),
                                        builder: (context, groupSnapshot) {
                                          final groupData =
                                              groupSnapshot.data?.data() ??
                                                  <String, dynamic>{};
                                          final isJoinClosed =
                                              _isMeetJoinClosed(groupData);
                                          if (!isJoinClosed) {
                                            return const SizedBox.shrink();
                                          }
                                          return Positioned(
                                            left: 8,
                                            top: 8,
                                            child: Container(
                                              width: 22,
                                              height: 22,
                                              decoration: const BoxDecoration(
                                                color: Color(0xFFE93E4E),
                                                shape: BoxShape.circle,
                                              ),
                                              child: const Icon(
                                                Icons.lock_rounded,
                                                size: 13,
                                                color: Colors.white,
                                              ),
                                            ),
                                          );
                                        },
                                      ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 10),
                              Text(
                                entry.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: isLight ? Colors.black : Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w800,
                                  height: 1.2,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                entry.authorName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: isLight ? Colors.black54 : Colors.grey[300],
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        );

                        return GestureDetector(
                          onTap: () => _openMeetPostsViewer(
                            entries: entries,
                            initialIndex: index - 1,
                          ),
                          child: card,
                        );
                      },
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildStaticDiscoverPopCard() {
    final isLight = Theme.of(context).brightness == Brightness.light;
    return Container(
      decoration: BoxDecoration(
        color: isLight ? Colors.white : null,
        gradient: isLight
            ? null
            : LinearGradient(
                colors: [
                  const Color(0xFF14233A).withValues(alpha: 0.96),
                  const Color(0xFF312357).withValues(alpha: 0.96),
                ],
                begin: Alignment.topRight,
                end: Alignment.bottomLeft,
              ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color:
              isLight ? const Color(0xFF9FAFFF) : _cyan.withValues(alpha: 0.18),
        ),
      ),
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: GestureDetector(
              onTap: _openMeetComposerSheet,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Container(
                  color: isLight ? Colors.white : const Color(0xFF0D1524),
                  child: Stack(
                    children: [
                      const Positioned.fill(
                        child: CustomPaint(
                          painter: _HoloEarthPainter(),
                        ),
                      ),
                      Positioned.fill(
                        child: AnimatedBuilder(
                          animation: _spaceUsersController,
                          builder: (context, _) {
                            return _buildOrbitingUserIcons(
                              _spaceUsersController.value,
                            );
                          },
                        ),
                      ),
                      Center(
                        child: Container(
                          width: 62,
                          height: 62,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: const RadialGradient(
                              colors: [
                                Color(0xAA63C7FF),
                                Color(0x665F88FF),
                                Colors.transparent,
                              ],
                            ),
                            border: Border.all(
                                color: const Color(0xFF6CD4FF), width: 1.2),
                          ),
                          child: Icon(
                            Icons.public_rounded,
                            color: isLight
                                ? const Color(0xFF5A6CFF)
                                : Colors.white,
                            size: 30,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              gradient: const LinearGradient(
                colors: [
                  Color(0xFF9D6AFF),
                  Color(0xFFEE5BFF),
                  Color(0xFF53C1F9)
                ],
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFFB05FFF).withValues(alpha: 0.34),
                  blurRadius: 12,
                  offset: const Offset(0, 5),
                ),
              ],
            ),
            child: ElevatedButton(
              onPressed: _openMeetComposerSheet,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.transparent,
                shadowColor: Colors.transparent,
                foregroundColor: Colors.white,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                minimumSize: const Size(0, 42),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              child: const Text(
                'הוסף פופ',
                maxLines: 1,
                overflow: TextOverflow.visible,
                style: TextStyle(fontSize: 12.2, fontWeight: FontWeight.w800),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOrbitingUserIcons(double progress) {
    const iconCount = 9;

    return LayoutBuilder(
      builder: (context, constraints) {
        final center =
            Offset(constraints.maxWidth / 2, constraints.maxHeight / 2);
        final minSide = math.min(constraints.maxWidth, constraints.maxHeight);
        final orbitX = <double>[
          0.46,
          0.64,
          0.53,
          0.71,
          0.58,
          0.67,
          0.74,
          0.49,
          0.62
        ];
        final orbitY = <double>[
          0.63,
          0.41,
          0.72,
          0.38,
          0.55,
          0.47,
          0.68,
          0.33,
          0.76
        ];
        final phaseShift = <double>[
          0.0,
          1.4,
          2.9,
          4.8,
          3.7,
          5.9,
          0.65,
          2.15,
          4.35
        ];

        return Stack(
          children: List.generate(iconCount, (index) {
            final baseAngle =
                (2 * math.pi / iconCount) * index + phaseShift[index];
            final speed = 0.42 + (index * 0.23);
            final direction = index.isEven ? 1.0 : -1.0;
            final orbitAngle =
                baseAngle + direction * (2 * math.pi * progress * speed);
            final radiusX = minSide * orbitX[index];
            final radiusY = minSide * orbitY[index];
            final wobbleX = math.sin((orbitAngle * 2.8) + index) * 7.0;
            final wobbleY = math.cos((orbitAngle * 2.2) - index) * 9.0;

            final x = center.dx + math.cos(orbitAngle) * radiusX + wobbleX;
            final y = center.dy + math.sin(orbitAngle) * radiusY + wobbleY;
            final alphaWave = (math.sin(orbitAngle * 1.7) + 1) / 2;
            final opacity = (0.25 + (alphaWave * 0.75)).clamp(0.0, 1.0);

            return Positioned(
              left: x - 9,
              top: y - 9,
              child: Opacity(
                opacity: opacity,
                child: Container(
                  width: 18,
                  height: 18,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xD0202A44),
                    border:
                        Border.all(color: const Color(0xFF8BE7FF), width: 0.9),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF8BE7FF).withValues(alpha: 0.28),
                        blurRadius: 8,
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.person,
                    size: 11,
                    color: Color(0xFFE3FBFF),
                  ),
                ),
              ),
            );
          }),
        );
      },
    );
  }

  Widget _sectionShell({
    required String title,
    required Widget child,
    Widget? trailing,
    bool trailingOnLeft = false,
  }) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      decoration: BoxDecoration(
        color: isLight ? Colors.white.withValues(alpha: 0.9) : null,
        gradient: isLight
            ? null
            : LinearGradient(
                colors: [
                  const Color(0xFF111E35).withValues(alpha: 0.96),
                  const Color(0xFF2A1E4C).withValues(alpha: 0.96),
                ],
                begin: Alignment.topRight,
                end: Alignment.bottomLeft,
              ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color:
              isLight ? const Color(0xFFA9C3FF) : _cyan.withValues(alpha: 0.22),
        ),
        boxShadow: [
          BoxShadow(
            color: _cyan.withValues(alpha: 0.08),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (trailingOnLeft) ...[
                Expanded(
                  child: Text(
                    title,
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      color: isLight ? Colors.black : Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                if (trailing != null) trailing,
              ] else ...[
                if (trailing != null) trailing,
                Expanded(
                  child: Text(
                    title,
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      color: isLight ? Colors.black : Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }

  Widget _emptyCard(String text) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: isLight
            ? Colors.white.withValues(alpha: 0.78)
            : const Color(0xFF0E1726),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
            color: isLight ? const Color(0xFFA9C3FF) : Colors.white10),
      ),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: isLight ? Colors.black54 : Colors.white70,
              height: 1.35,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAllTasksButton() {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _openAllTasksDialog,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              gradient: const LinearGradient(
                colors: [Color(0xFF8DE8FF), Color(0xFFC9B5FF)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF76CFFF).withValues(alpha: 0.4),
                  blurRadius: 14,
                  offset: const Offset(0, 7),
                ),
              ],
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.65),
                width: 1.1,
              ),
            ),
            child: const Text(
              'כל המשימות',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Color(0xFF2A2361),
                fontSize: 12.8,
                fontWeight: FontWeight.w900,
                height: 1.15,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openAllTasksDialog() async {
    final isLight = Theme.of(context).brightness == Brightness.light;
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black54,
      builder: (dialogContext) {
        String? selectedCategory;
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
              child: StatefulBuilder(
                builder: (context, setModalState) {
                  final activeCategory = selectedCategory?.trim() ?? '';
                  final hasSelectedCategory = activeCategory.isNotEmpty;
                  final subCategories = hasSelectedCategory
                      ? appSubCategories(activeCategory)
                          .where((item) => item.trim().isNotEmpty)
                          .toList(growable: false)
                      : const <String>[];

                  return Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsetsDirectional.only(start: 2),
                          child: Row(
                            children: [
                              IconButton(
                                onPressed: () {
                                  if (hasSelectedCategory) {
                                    setModalState(() {
                                      selectedCategory = null;
                                    });
                                    return;
                                  }
                                  Navigator.of(dialogContext).pop();
                                },
                                icon: Icon(
                                  hasSelectedCategory
                                      ? Icons.arrow_back_rounded
                                      : Icons.close_rounded,
                                  color: isLight
                                      ? const Color(0xFF33405B)
                                      : Colors.white70,
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  hasSelectedCategory
                                      ? activeCategory
                                      : 'כל המשימות',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: isLight
                                        ? const Color(0xFF1E2A45)
                                        : Colors.white,
                                    fontSize: 22,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 46),
                            ],
                          ),
                        ),
                        const SizedBox(height: 6),
                        Expanded(
                          child: hasSelectedCategory
                              ? LayoutBuilder(
                                  builder: (context, constraints) {
                                    return SingleChildScrollView(
                                      physics: const BouncingScrollPhysics(),
                                      child: ConstrainedBox(
                                        constraints: BoxConstraints(
                                          minHeight: constraints.maxHeight,
                                        ),
                                        child: Center(
                                          child: Padding(
                                            padding: const EdgeInsets.symmetric(
                                                vertical: 8),
                                            child: Wrap(
                                              alignment: WrapAlignment.center,
                                              spacing: 17,
                                              runSpacing: 17,
                                              children: subCategories
                                                  .map(
                                                    (subCategory) =>
                                                        _buildTaskSubCategoryBubble(
                                                      subCategory: subCategory,
                                                      isLight: isLight,
                                                    ),
                                                  )
                                                  .toList(growable: false),
                                            ),
                                          ),
                                        ),
                                      ),
                                    );
                                  },
                                )
                              : SingleChildScrollView(
                                  physics: const BouncingScrollPhysics(),
                                  child: Wrap(
                                    alignment: WrapAlignment.center,
                                    spacing: 17,
                                    runSpacing: 17,
                                    children: appMainCategories
                                        .where((category) =>
                                            category.trim().isNotEmpty)
                                        .map((category) =>
                                            _buildTaskCategoryBubble(
                                              category: category,
                                              isLight: isLight,
                                              onTap: () {
                                                setModalState(() {
                                                  selectedCategory = category;
                                                });
                                              },
                                            ))
                                        .toList(growable: false),
                                  ),
                                ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  // ignore: unused_element
  Future<void> _openSubCategoriesDialog(String category) async {
    final normalizedCategory = category.trim();
    if (normalizedCategory.isEmpty) {
      return;
    }

    final isLight = Theme.of(context).brightness == Brightness.light;
    final subCategories = appSubCategories(normalizedCategory)
        .where((item) => item.trim().isNotEmpty)
        .toList(growable: false);

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
              maxWidth: MediaQuery.of(dialogContext).size.width * 0.97,
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
                padding: const EdgeInsets.fromLTRB(10, 14, 10, 12),
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
                                normalizedCategory,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: isLight
                                      ? const Color(0xFF1E2A45)
                                      : Colors.white,
                                  fontSize: 21,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                              Text(
                                'תתי קטגוריות',
                                style: TextStyle(
                                  color: isLight
                                      ? const Color(0xFF596682)
                                      : Colors.white70,
                                  fontSize: 12,
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
                      child: subCategories.isEmpty
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
                                spacing: 17,
                                runSpacing: 17,
                                children: subCategories
                                    .map((subCategory) =>
                                        _buildTaskSubCategoryBubble(
                                          subCategory: subCategory,
                                          isLight: isLight,
                                        ))
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

  Widget _buildTaskCategoryBubble({
    required String category,
    required bool isLight,
    required VoidCallback onTap,
  }) {
    final icon = categoryIconFor(category);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          width: 128,
          height: 128,
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
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, color: const Color(0xFF2A2361), size: 33),
                const SizedBox(height: 7),
                Text(
                  category,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: const Color(0xFF2A2361),
                    fontSize: isLight ? 13 : 12.8,
                    fontWeight: FontWeight.w900,
                    height: 1.1,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTaskSubCategoryBubble({
    required String subCategory,
    required bool isLight,
  }) {
    final label = subCategory.trim();
    double fontSizeForLength(String text) {
      final length = text.characters.length;
      if (length <= 16) return isLight ? 13 : 12.8;
      if (length <= 22) return 11.6;
      if (length <= 30) return 10.5;
      return 9.7;
    }

    return Material(
      color: Colors.transparent,
      child: Container(
        width: 128,
        height: 128,
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
              color: const Color(0xFF76CFFF).withValues(alpha: 0.3),
              blurRadius: 14,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 11, 10, 11),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.category_rounded,
                  color: Color(0xFF2A2361), size: 28),
              const SizedBox(height: 6),
              Text(
                label,
                maxLines: 4,
                textAlign: TextAlign.center,
                softWrap: true,
                style: TextStyle(
                  color: const Color(0xFF2A2361),
                  fontSize: fontSizeForLength(label),
                  fontWeight: FontWeight.w900,
                  height: 1.06,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    return Scaffold(
      backgroundColor: isLight ? Colors.white : _bg,
      body: Stack(
        children: [
          Positioned(
            top: -90,
            right: -70,
            child: Container(
              width: 230,
              height: 230,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [Color(0x4453C1F9), Color(0x0053C1F9)],
                ),
              ),
            ),
          ),
          Positioned(
            top: 120,
            left: -90,
            child: Container(
              width: 260,
              height: 260,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [Color(0x229E7CFF), Color(0x009E7CFF)],
                ),
              ),
            ),
          ),
          SafeArea(
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: _dismissKeyboardOnBackgroundTap,
              child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 12),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: SizedBox(
                      height: 52,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Center(
                            child: ShaderMask(
                              shaderCallback: (bounds) => const LinearGradient(
                                colors: [Color(0xFF53C1F9), Color(0xFF9E7CFF)],
                                begin: Alignment.centerLeft,
                                end: Alignment.centerRight,
                              ).createShader(bounds),
                              child: const FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  'hundred',
                                  textAlign: TextAlign.center,
                                  maxLines: 1,
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 30,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 1.1,
                                    shadows: [
                                      Shadow(
                                        color: Color(0x6653C1F9),
                                        blurRadius: 18,
                                        offset: Offset(0, 4),
                                      ),
                                      Shadow(
                                        color: Color(0x669E7CFF),
                                        blurRadius: 24,
                                        offset: Offset(0, 6),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                          Align(
                            alignment: Alignment.centerRight,
                            child: _buildAllTasksButton(),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  _buildFriendsSection(),
                  _buildWeeklyChallengeSection(),
                  const SizedBox(height: 14),
                  _buildUpcomingGroupsSection(),
                  _buildDiscoverNowSection(),
                  _buildMeetNowGrid(),
                ],
              ),
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: const MainBottomNav(currentIndex: 1),
    );
  }
}

class _HoloEarthPainter extends CustomPainter {
  const _HoloEarthPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width * 0.5, size.height * 0.48);
    const radius = 78.0;

    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..shader = const LinearGradient(
        colors: [Color(0x8853C1F9), Color(0x889E7CFF)],
      ).createShader(Rect.fromCircle(center: center, radius: radius));

    canvas.drawCircle(center, radius, ringPaint);
    canvas.drawCircle(center, radius * 0.72, ringPaint..strokeWidth = 0.9);

    final linePaint = Paint()
      ..color = const Color(0x665ED8FF)
      ..strokeWidth = 0.7;

    final points = <Offset>[
      Offset(center.dx - 96, center.dy - 46),
      Offset(center.dx - 74, center.dy + 12),
      Offset(center.dx - 48, center.dy + 52),
      Offset(center.dx + 20, center.dy + 66),
      Offset(center.dx + 78, center.dy + 26),
      Offset(center.dx + 100, center.dy - 20),
      Offset(center.dx + 32, center.dy - 58),
      Offset(center.dx - 22, center.dy - 66),
    ];

    for (var i = 0; i < points.length - 1; i++) {
      canvas.drawLine(points[i], points[i + 1], linePaint);
    }
    canvas.drawLine(points.first, points.last, linePaint);

    final glowPaint = Paint()
      ..shader = const RadialGradient(
        colors: [Color(0xCC8BE7FF), Color(0x009E7CFF)],
      ).createShader(Rect.fromCircle(center: center, radius: 12));
    for (final point in points) {
      canvas.drawCircle(point, 4.2, glowPaint);
      canvas.drawCircle(
        point,
        1.7,
        Paint()..color = const Color(0xFFE3FBFF),
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _ForceOnlineSliderTrackShape extends SliderTrackShape {
  const _ForceOnlineSliderTrackShape();

  @override
  Rect getPreferredRect({
    required RenderBox parentBox,
    Offset offset = Offset.zero,
    required SliderThemeData sliderTheme,
    bool isEnabled = false,
    bool isDiscrete = false,
  }) {
    final trackHeight = sliderTheme.trackHeight ?? 4;
    final trackLeft = offset.dx + 12;
    final trackTop = offset.dy + (parentBox.size.height - trackHeight) / 2;
    final trackWidth = parentBox.size.width - 24;
    return Rect.fromLTWH(trackLeft, trackTop, trackWidth, trackHeight);
  }

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required Offset thumbCenter,
    bool isEnabled = false,
    bool isDiscrete = false,
    required TextDirection textDirection,
    Offset? secondaryOffset,
  }) {
    final canvas = context.canvas;
    final trackRect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );

    final radius = Radius.circular(trackRect.height / 2);

    final inactivePaint = Paint()..color = const Color(0xFF151515);
    canvas.drawRRect(
      RRect.fromRectAndRadius(trackRect, radius),
      inactivePaint,
    );

    final activeRight = thumbCenter.dx.clamp(trackRect.left, trackRect.right);
    if (activeRight <= trackRect.left) {
      return;
    }

    final activeRect = Rect.fromLTRB(
      trackRect.left,
      trackRect.top,
      activeRight,
      trackRect.bottom,
    );

    final gradientPaint = Paint()
      ..shader = const LinearGradient(
        colors: [Color(0xFFA487FF), Color(0xFF8BE7FF)],
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
      ).createShader(trackRect);

    canvas.drawRRect(
      RRect.fromRectAndRadius(activeRect, radius),
      gradientPaint,
    );
  }
}

class _MeetNowPostsViewer extends StatefulWidget {
  const _MeetNowPostsViewer({
    required this.entries,
    required this.initialIndex,
    required this.onJoinPressed,
    required this.onOpenProfilePressed,
    required this.relativeTimeBuilder,
  });

  final List<MeetNowPostEntry> entries;
  final int initialIndex;
  final Future<bool> Function(MeetNowPostEntry entry) onJoinPressed;
  final Future<void> Function(String uid) onOpenProfilePressed;
  final String Function(DateTime createdAt) relativeTimeBuilder;

  @override
  State<_MeetNowPostsViewer> createState() => _MeetNowPostsViewerState();
}

class _MeetNowPostsViewerState extends State<_MeetNowPostsViewer> {
  static const Color _bg = Color(0xFF0B1019);
  static const Color _cyan = Color(0xFF6EADE8);
  static const Duration _imageScrollHintStep = Duration(milliseconds: 320);

  late final PageController _postsController;
  final Map<String, PageController> _imageControllers =
      <String, PageController>{};
  final Map<String, int> _imageIndexes = <String, int>{};
  final Set<String> _hintShownPostIds = <String>{};
  int _activePostIndex = 0;
  String _joiningPostId = '';
  String? _hintPostId;
  bool _hintShiftUp = false;
  Timer? _hintReturnTimer;

  String _distanceBucketText(double? meters) {
    if (meters == null || meters.isNaN || meters.isInfinite || meters < 0) {
      return 'מרחק לא זמין';
    }
    final km = meters / 1000;
    if (km < 1) return 'פחות מ-1 ק"מ ממך';
    if (km < 3) return '1-3 ק"מ ממך';
    if (km < 5) return '3-5 ק"מ ממך';
    if (km < 10) return '5-10 ק"מ ממך';
    if (km < 20) return '10-20 ק"מ ממך';
    if (km < 30) return '20-30 ק"מ ממך';
    if (km < 40) return '30-40 ק"מ ממך';
    if (km < 50) return '40-50 ק"מ ממך';
    if (km < 60) return '50-60 ק"מ ממך';
    if (km < 70) return '60-70 ק"מ ממך';
    if (km < 80) return '70-80 ק"מ ממך';
    if (km < 90) return '80-90 ק"מ ממך';
    return 'מעל 90 ק"מ ממך';
  }

  @override
  void initState() {
    super.initState();
    final safeInitial = widget.initialIndex.clamp(0, widget.entries.length - 1);
    _activePostIndex = safeInitial;
    _postsController = PageController(initialPage: safeInitial);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _playImageScrollHintForPost(_activePostIndex);
    });
  }

  @override
  void dispose() {
    _hintReturnTimer?.cancel();
    for (final controller in _imageControllers.values) {
      controller.dispose();
    }
    _postsController.dispose();
    super.dispose();
  }

  PageController _imageControllerFor(MeetNowPostEntry entry) {
    return _imageControllers.putIfAbsent(
      entry.id,
      () => PageController(initialPage: _imageIndexes[entry.id] ?? 0),
    );
  }

  void _playImageScrollHintForPost(int postIndex) {
    if (!mounted || postIndex < 0 || postIndex >= widget.entries.length) {
      return;
    }

    final entry = widget.entries[postIndex];
    final postId = entry.id.trim();
    if (postId.isEmpty || _hintShownPostIds.contains(postId)) {
      return;
    }

    if (_imagesFor(entry).length <= 1) {
      return;
    }

    _hintShownPostIds.add(postId);
    _hintReturnTimer?.cancel();
    setState(() {
      _hintPostId = postId;
      _hintShiftUp = true;
    });

    _hintReturnTimer = Timer(_imageScrollHintStep, () {
      if (!mounted || _hintPostId != postId) {
        return;
      }
      setState(() {
        _hintShiftUp = false;
      });
    });
  }

  List<String> _imagesFor(MeetNowPostEntry entry) {
    final unique = <String>{
      ...entry.authorProfileImageUrls
          .map((item) => item.trim())
          .where((item) => item.isNotEmpty),
      ...entry.participantProfileImageUrls
          .map((item) => item.trim())
          .where((item) => item.isNotEmpty),
      entry.authorAvatarUrl.trim(),
    }..remove('');

    if (unique.isEmpty) {
      return const <String>[];
    }
    return unique.toList(growable: false);
  }

  Widget _metaPill(IconData icon, String text, {required bool isLight}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: isLight
            ? Colors.white.withValues(alpha: 0.92)
            : const Color(0xFF17263C),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color:
              isLight ? const Color(0xFFA9C3FF) : _cyan.withValues(alpha: 0.28),
        ),
      ),
      child: Row(
        textDirection: TextDirection.rtl,
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 14,
            color: isLight ? const Color(0xFF5A6CFF) : const Color(0xFFC4E1FF),
          ),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(
              color: isLight ? Colors.black87 : Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    return Scaffold(
      backgroundColor: isLight ? Colors.white : _bg,
      body: Directionality(
        textDirection: TextDirection.rtl,
        child: SafeArea(
          child: PageView.builder(
            controller: _postsController,
            itemCount: widget.entries.length,
            onPageChanged: (index) {
              setState(() {
                _activePostIndex = index;
              });
              _playImageScrollHintForPost(index);
            },
            itemBuilder: (context, index) {
              final entry = widget.entries[index];
              final imageUrls = _imagesFor(entry);
              final imageController = _imageControllerFor(entry);
              final isJoining = _joiningPostId == entry.id;
              final shouldAnimateImageHint =
                  _hintPostId == entry.id && _hintShiftUp;

              return Column(
                children: [
                  Expanded(
                    flex: 7,
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: AnimatedSlide(
                            duration: _imageScrollHintStep,
                            curve: Curves.easeInOut,
                            offset: shouldAnimateImageHint
                                ? const Offset(0, -0.035)
                                : Offset.zero,
                            child: imageUrls.isEmpty
                                ? Container(
                                    color: isLight
                                        ? Colors.white
                                        : const Color(0xFF111A28),
                                    alignment: Alignment.center,
                                    child: Icon(
                                      Icons.person_outline_rounded,
                                      color: isLight
                                          ? Colors.black45
                                          : Colors.white54,
                                      size: 68,
                                    ),
                                  )
                                : PageView.builder(
                                    controller: imageController,
                                    scrollDirection: Axis.vertical,
                                    itemCount: imageUrls.length,
                                    onPageChanged: (imageIndex) {
                                      setState(() {
                                        _imageIndexes[entry.id] = imageIndex;
                                      });
                                    },
                                    itemBuilder: (context, imageIndex) {
                                      return Image.network(
                                        imageUrls[imageIndex],
                                        fit: BoxFit.cover,
                                        errorBuilder: (_, __, ___) => Container(
                                          color: isLight
                                              ? Colors.white
                                              : const Color(0xFF111A28),
                                          alignment: Alignment.center,
                                          child: Icon(
                                            Icons.broken_image_rounded,
                                            color: isLight
                                                ? Colors.black45
                                                : Colors.white54,
                                            size: 54,
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                          ),
                        ),
                        Positioned.fill(
                          child: IgnorePointer(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    Colors.black.withValues(
                                      alpha: isLight ? 0.18 : 0.34,
                                    ),
                                    Colors.transparent,
                                    Colors.black.withValues(
                                      alpha: isLight ? 0.36 : 0.58,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          top: 10,
                          right: 12,
                          left: 12,
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      _distanceBucketText(
                                        entry.distanceMetersFromCurrentUser,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w900,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      '${imageUrls.length} תמונות פרופיל',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: isLight
                                            ? const Color(0xFFF2F6FF)
                                            : const Color(0xFFD8E3F8),
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              IconButton(
                                onPressed: () => Navigator.of(context).pop(),
                                icon: const Icon(
                                  Icons.close_rounded,
                                  color: Colors.white,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Positioned(
                          right: 16,
                          bottom: 16,
                          child: Directionality(
                            textDirection: TextDirection.rtl,
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                maxWidth:
                                    MediaQuery.of(context).size.width * 0.58,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  SizedBox(
                                    width: double.infinity,
                                    child: Text(
                                      entry.title,
                                      textDirection: TextDirection.rtl,
                                      textAlign: TextAlign.start,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 26,
                                        fontWeight: FontWeight.w900,
                                        height: 1.08,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  SizedBox(
                                    width: double.infinity,
                                    child: Text(
                                      '${entry.authorName} • ${entry.authorHandle}',
                                      textDirection: TextDirection.rtl,
                                      textAlign: TextAlign.start,
                                      style: TextStyle(
                                        color: isLight
                                            ? const Color(0xFFEFF5FF)
                                            : const Color(0xFFD8E3F8),
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    flex: 3,
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            if (isLight)
                              const Color(0xFFF8FBFF)
                            else
                              const Color(0xFF101826).withValues(alpha: 0.98),
                            if (isLight)
                              const Color(0xFFEFF5FF)
                            else
                              const Color(0xFF1E1A38).withValues(alpha: 0.98),
                          ],
                          begin: Alignment.topRight,
                          end: Alignment.bottomLeft,
                        ),
                        border: Border(
                          top: BorderSide(
                            color: isLight
                                ? const Color(0xFFA9C3FF)
                                : _cyan.withValues(alpha: 0.28),
                          ),
                        ),
                      ),
                      child: Directionality(
                        textDirection: TextDirection.rtl,
                        child: Align(
                          alignment: Alignment.topRight,
                          child: SizedBox(
                            width: MediaQuery.of(context)
                                .size
                                .width
                                .clamp(280.0, 520.0),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: SingleChildScrollView(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Align(
                                          alignment: Alignment.topRight,
                                          child: _metaPill(
                                            Icons.access_time_rounded,
                                            widget.relativeTimeBuilder(
                                                entry.createdAt),
                                            isLight: isLight,
                                          ),
                                        ),
                                        if (entry.details
                                            .trim()
                                            .isNotEmpty) ...[
                                          const SizedBox(height: 8),
                                          Container(
                                            width: double.infinity,
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 10,
                                              vertical: 8,
                                            ),
                                            decoration: BoxDecoration(
                                              color: isLight
                                                  ? Colors.white
                                                      .withValues(alpha: 0.9)
                                                  : const Color(0xFF17263C),
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                              border: Border.all(
                                                color: isLight
                                                    ? const Color(0xFFA9C3FF)
                                                    : _cyan.withValues(
                                                        alpha: 0.22),
                                              ),
                                            ),
                                            child: Text(
                                              entry.details.trim(),
                                              textDirection: TextDirection.rtl,
                                              textAlign: TextAlign.right,
                                              style: TextStyle(
                                                color: isLight
                                                    ? Colors.black87
                                                    : const Color(0xFFD8E3F8),
                                                fontSize: 13,
                                                fontWeight: FontWeight.w600,
                                                height: 1.35,
                                              ),
                                            ),
                                          ),
                                        ],
                                        const SizedBox(height: 8),
                                        Align(
                                          alignment: Alignment.topRight,
                                          child: Wrap(
                                            alignment: WrapAlignment.start,
                                            runAlignment: WrapAlignment.start,
                                            textDirection: TextDirection.rtl,
                                            spacing: 8,
                                            runSpacing: 8,
                                            children: [
                                              _metaPill(
                                                Icons.stars_rounded,
                                                '${entry.authorScore} נקודות',
                                                isLight: isLight,
                                              ),
                                              _metaPill(
                                                Icons.place_rounded,
                                                entry.meetingLocation.isEmpty
                                                    ? 'מיקום לא צוין'
                                                    : entry.meetingLocation,
                                                isLight: isLight,
                                              ),
                                              _metaPill(
                                                Icons.schedule_rounded,
                                                entry.timePreference.isEmpty
                                                    ? 'לא צוין זמן'
                                                    : entry.timePreference,
                                                isLight: isLight,
                                              ),
                                              if (entry
                                                      .linkedGroupMembersCount >
                                                  0)
                                                _metaPill(
                                                  Icons.people_alt_rounded,
                                                  '${entry.linkedGroupMembersCount} חברים',
                                                  isLight: isLight,
                                                ),
                                              if (entry.category.isNotEmpty ||
                                                  entry.subCategory.isNotEmpty)
                                                _metaPill(
                                                  categoryIconFor(
                                                    entry.category.isEmpty
                                                        ? kGeneralCategory
                                                        : entry.category,
                                                  ),
                                                  entry.subCategory.isEmpty
                                                      ? entry.category
                                                      : '${entry.category} • ${entry.subCategory}',
                                                  isLight: isLight,
                                                ),
                                              if (entry.minAge != null &&
                                                  entry.maxAge != null)
                                                _metaPill(
                                                  Icons.cake_rounded,
                                                  'גילאים ${entry.minAge}-${entry.maxAge}',
                                                  isLight: isLight,
                                                ),
                                              if (entry.desiredParticipants !=
                                                  null)
                                                _metaPill(
                                                  Icons.groups_rounded,
                                                  '${entry.desiredParticipants} משתתפים רצויים',
                                                  isLight: isLight,
                                                ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 10),
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: SizedBox(
                                    width: MediaQuery.of(context)
                                        .size
                                        .width
                                        .clamp(280.0, 560.0),
                                    child: Row(
                                      textDirection: TextDirection.rtl,
                                      children: [
                                        Expanded(
                                          child: ElevatedButton(
                                            onPressed: isJoining
                                                ? null
                                                : () async {
                                                    setState(() {
                                                      _joiningPostId = entry.id;
                                                    });
                                                    try {
                                                      final joined =
                                                          await widget
                                                              .onJoinPressed(
                                                                  entry);
                                                      if (joined && mounted) {
                                                        Navigator.of(context)
                                                            .pop();
                                                      }
                                                    } finally {
                                                      if (mounted) {
                                                        setState(() {
                                                          _joiningPostId = '';
                                                        });
                                                      }
                                                    }
                                                  },
                                            style: ElevatedButton.styleFrom(
                                              backgroundColor: isLight
                                                  ? Colors.white
                                                  : const Color(0xFF9E7CFF),
                                              foregroundColor: isLight
                                                  ? const Color(0xFF9E7CFF)
                                                  : Colors.white,
                                              side: isLight
                                                  ? const BorderSide(
                                                      color: Color(0xFFA9C3FF),
                                                    )
                                                  : BorderSide.none,
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                vertical: 13,
                                              ),
                                            ),
                                            child: isJoining
                                                ? SizedBox(
                                                    width: 18,
                                                    child:
                                                        CircularProgressIndicator(
                                                      strokeWidth: 2,
                                                      color: isLight
                                                          ? const Color(
                                                              0xFF9E7CFF)
                                                          : Colors.white,
                                                    ),
                                                  )
                                                : const Text(
                                                    'הצטרפות',
                                                    style: TextStyle(
                                                      fontSize: 15,
                                                      fontWeight:
                                                          FontWeight.w800,
                                                    ),
                                                  ),
                                          ),
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: OutlinedButton(
                                            onPressed: () =>
                                                widget.onOpenProfilePressed(
                                              entry.authorUid,
                                            ),
                                            style: OutlinedButton.styleFrom(
                                              foregroundColor: isLight
                                                  ? const Color(0xFF5A6CFF)
                                                  : Colors.white,
                                              backgroundColor: isLight
                                                  ? Colors.white
                                                  : Colors.transparent,
                                              side: BorderSide(
                                                color: isLight
                                                    ? const Color(0xFFA9C3FF)
                                                    : _cyan.withValues(
                                                        alpha: 0.62),
                                              ),
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                vertical: 13,
                                              ),
                                            ),
                                            child:
                                                const Text('הצגת פרופיל משתמש'),
                                          ),
                                        ),
                                      ],
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
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
