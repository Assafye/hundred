import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'age_restrictions.dart';
import 'app_categories.dart';
import 'category_points.dart';
import 'chat_room_screen.dart';
import 'create_group_screen.dart';
import 'main_bottom_nav.dart';
import 'services/chat_service.dart';
import 'services/block_user_service.dart';
import 'services/group_service.dart';
import 'services/keyboard_dismiss_controller.dart';
import 'user_profile_screen.dart';
import 'widgets/group_avatar.dart';

class _GlobalSearchResult {
  final String id;
  final String name;
  final String subtitle;
  final String imageUrl;
  final bool isGroup;
  final bool isMember;

  const _GlobalSearchResult({
    required this.id,
    required this.name,
    required this.subtitle,
    required this.imageUrl,
    required this.isGroup,
    required this.isMember,
  });
}

class _PublicFilterChoiceOption {
  final String value;
  final String label;
  final int? points;

  const _PublicFilterChoiceOption({
    required this.value,
    required this.label,
    this.points,
  });
}

class ChatsScreen extends StatefulWidget {
  final int initialTabIndex;
  final DateTime? initialPublicFilterFromDate;
  final DateTime? initialPublicFilterToDate;

  const ChatsScreen({
    super.key,
    this.initialTabIndex = 0,
    this.initialPublicFilterFromDate,
    this.initialPublicFilterToDate,
  });

  @override
  State<ChatsScreen> createState() => _ChatsScreenState();
}

class _ChatsScreenState extends State<ChatsScreen> {
  final ChatService _chatService = ChatService();
  final BlockUserService _blockUserService = BlockUserService();
  final GroupService _groupService = GroupService();
  late final TextEditingController _searchController;
  final Map<String, Future<Map<String, Map<String, String>>>>
      _directChatSummariesCache =
      <String, Future<Map<String, Map<String, String>>>>{};
  final Map<String, Map<String, Map<String, String>>>
      _directChatSummariesLastGood =
      <String, Map<String, Map<String, String>>>{};
  final Map<String, Future<DocumentSnapshot<Map<String, dynamic>>>>
      _groupDetailsCache =
      <String, Future<DocumentSnapshot<Map<String, dynamic>>>>{};
  final Map<String, bool> _joinedGroupEligibilityCache = <String, bool>{};
  final Map<String, Future<List<_GlobalSearchResult>>> _globalSearchCache =
      <String, Future<List<_GlobalSearchResult>>>{};
  String _streamsUid = '';
  Stream<List<QueryDocumentSnapshot<Map<String, dynamic>>>>? _userChatsStream;
  Stream<List<QueryDocumentSnapshot<Map<String, dynamic>>>>? _publicChatsStream;
    List<QueryDocumentSnapshot<Map<String, dynamic>>>? _lastUserChatsDocs;
    List<QueryDocumentSnapshot<Map<String, dynamic>>>? _lastPublicChatsDocs;
  StreamSubscription<List<QueryDocumentSnapshot<Map<String, dynamic>>>>?
      _userChatsNotificationsSub;

  Set<String> _myFriendIds = <String>{};
  Map<String, Map<String, String>> _myFriendSummaries =
      <String, Map<String, String>>{};
  bool _friendsLoading = false;

  int _selectedChatsTabIndex = 0;
  bool _hasNewUsersNotification = false;
  bool _hasNewGroupsNotification = false;
  DateTime _usersTabAcknowledgedAt = DateTime.now();
  DateTime _groupsTabAcknowledgedAt = DateTime.now();
  String searchQuery = '';
  RangeValues _publicFilterAgeRange = RangeValues(
    minimumUserAge.toDouble(),
    maximumAgeRange.toDouble(),
  );
  bool _publicFilterOnlyEligibleByScore = false;
  int? _myScoreForPublicFilters;
  DateTime? _publicFilterFromDate;
  DateTime? _publicFilterToDate;
  String? _publicFilterCategory;
  String? _publicFilterSubCategory;

  bool get _hasActivePublicFilters {
    return _publicFilterOnlyEligibleByScore ||
        _publicFilterFromDate != null ||
        _publicFilterToDate != null ||
        _publicFilterCategory != null ||
        _publicFilterSubCategory != null ||
        _publicFilterAgeRange.start != minimumUserAge ||
        _publicFilterAgeRange.end != maximumAgeRange;
  }

  bool get _hasSearchQuery => searchQuery.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    KeyboardDismissController.suspend();
    final now = DateTime.now();
    _usersTabAcknowledgedAt = now;
    _groupsTabAcknowledgedAt = now;
    _searchController = TextEditingController();
    _selectedChatsTabIndex = widget.initialTabIndex.clamp(0, 2);
    _publicFilterFromDate = widget.initialPublicFilterFromDate;
    _publicFilterToDate = widget.initialPublicFilterToDate;
    _loadMyFriendsForPublicGroups();
    _loadMyScoreForPublicFilters();
    final currentUid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
    _ensureStableChatStreams(currentUid);
    _attachUserChatsNotificationsStream(currentUid);
  }

  @override
  void dispose() {
    KeyboardDismissController.resume();
    _userChatsNotificationsSub?.cancel();
    _searchController.dispose();
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

  void _ensureStableChatStreams(String uid) {
    final normalizedUid = uid.trim();
    if (normalizedUid.isEmpty) {
      _streamsUid = '';
      _userChatsStream = null;
      _publicChatsStream = null;
      return;
    }

    if (_streamsUid == normalizedUid &&
        _userChatsStream != null &&
        _publicChatsStream != null) {
      return;
    }

    _streamsUid = normalizedUid;
    _userChatsStream = _chatService.streamUserChatsSafeDocs(normalizedUid);
    _publicChatsStream =
        _chatService.streamPublicChatsExcludingUserSafe(normalizedUid);
  }

  void _attachUserChatsNotificationsStream(String uid) {
    final normalizedUid = uid.trim();
    _userChatsNotificationsSub?.cancel();
    _userChatsNotificationsSub = null;
    if (normalizedUid.isEmpty) {
      return;
    }

    final notificationsStream = _chatService.streamUserChatsSafeDocs(
      normalizedUid,
    );

    _userChatsNotificationsSub = notificationsStream.listen((docs) {
      _lastUserChatsDocs = docs;
      unawaited(
        _refreshTabNotificationsFromChatsDocs(docs, normalizedUid),
      );
    }, onError: (Object error, StackTrace stackTrace) {
      debugPrint('Chats notifications stream error: $error');
      if (!mounted) {
        return;
      }
      _processTabNotificationsFromChats(
        const <QueryDocumentSnapshot<Map<String, dynamic>>>[],
        normalizedUid,
      );
    });
  }

  Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>>
      _resolveVisibleDirectChats(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> directDocs,
    String currentUid,
  ) async {
    Set<String> blockedUids = const <String>{};
    try {
      blockedUids = await _blockUserService.fetchBlockedConnections();
    } catch (_) {
      blockedUids = const <String>{};
    }

    return _chatService.filterVisibleDirectChatsForUser(
      chats: directDocs,
      currentUid: currentUid,
      blockedUids: blockedUids,
    );
  }

  Future<void> _refreshTabNotificationsFromChatsDocs(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
    String currentUid,
  ) async {
    final directDocs = docs.where((doc) => _isDirectChat(doc.data())).toList(
          growable: false,
        );
    final groupDocs = docs.where((doc) => !_isDirectChat(doc.data())).toList(
          growable: false,
        );

    final visibleDirectDocs = await _resolveVisibleDirectChats(
      directDocs,
      currentUid,
    );

    if (!mounted) {
      return;
    }

    _processTabNotificationsFromChats(
      <QueryDocumentSnapshot<Map<String, dynamic>>>[
        ...visibleDirectDocs,
        ...groupDocs,
      ],
      currentUid,
    );
  }

  String _directChatOtherUserId(
    Map<String, dynamic> chatData,
    String currentUserId,
  ) {
    final participants = List<String>.from(
      (chatData['participants'] as List<dynamic>?) ?? const <String>[],
    );
    for (final participantId in participants) {
      final trimmed = participantId.trim();
      if (trimmed.isNotEmpty && trimmed != currentUserId) {
        return trimmed;
      }
    }
    return '';
  }

  Future<Map<String, Map<String, String>>> _directChatSummaries(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
    String currentUserId,
  ) {
    final otherUserIds = docs
        .map((doc) => doc.data())
        .where((data) {
          final isPublic = (data['isPublic'] as bool?) ?? false;
          final participants = List<String>.from(
            (data['participants'] as List<dynamic>?) ?? const <String>[],
          );
          return ((data['isDirect'] as bool?) ??
                  (!isPublic && participants.length == 2)) &&
              participants.isNotEmpty;
        })
        .map((data) => _directChatOtherUserId(data, currentUserId))
        .where((uid) => uid.isNotEmpty)
        .toSet()
        .toList(growable: false)
      ..sort();

    if (otherUserIds.isEmpty) {
      return Future.value(const <String, Map<String, String>>{});
    }

    final cacheKey = otherUserIds.join('|');
    return _directChatSummariesCache.putIfAbsent(
      cacheKey,
      () async {
        try {
          final summaries = await _chatService.fetchUserSummaries(otherUserIds);
          _directChatSummariesLastGood[cacheKey] = summaries;
          return summaries;
        } catch (_) {
          final lastGood = _directChatSummariesLastGood[cacheKey];
          if (lastGood != null) {
            return lastGood;
          }
          return const <String, Map<String, String>>{};
        } finally {
          _directChatSummariesCache.remove(cacheKey);
        }
      },
    );
  }

  String _targetGroupIdFromChatData(
      QueryDocumentSnapshot<Map<String, dynamic>> groupDoc) {
    final groupData = groupDoc.data();
    final sourceGroupId =
        ((groupData['sourceGroupId'] as String?) ?? '').trim();
    return sourceGroupId.isNotEmpty ? sourceGroupId : groupDoc.id;
  }

  Future<void> _loadMyFriendsForPublicGroups() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || uid.isEmpty) {
      return;
    }

    if (mounted) {
      setState(() {
        _friendsLoading = true;
      });
    }

    try {
      final userDoc =
          await FirebaseFirestore.instance.collection('users').doc(uid).get();
      final userData = userDoc.data() ?? <String, dynamic>{};
      final friendsRaw =
          (userData['friends'] as List<dynamic>?) ?? const <dynamic>[];
      final followingRaw =
          (userData['following'] as List<dynamic>?) ?? const <dynamic>[];

      final ids = (friendsRaw.isNotEmpty ? friendsRaw : followingRaw)
          .map((value) => value.toString().trim())
          .where((value) => value.isNotEmpty)
          .toSet();

      final summaries = await _chatService.fetchUserSummaries(ids.toList());

      if (!mounted) {
        return;
      }
      setState(() {
        _myFriendIds = ids;
        _myFriendSummaries = summaries;
        _friendsLoading = false;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _myFriendIds = <String>{};
        _myFriendSummaries = <String, Map<String, String>>{};
        _friendsLoading = false;
      });
    }
  }

  Future<void> _loadMyScoreForPublicFilters() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || uid.isEmpty) {
      return;
    }

    try {
      final userDoc =
          await FirebaseFirestore.instance.collection('users').doc(uid).get();
      final score = (userDoc.data()?['score'] as num?)?.toInt() ?? 0;

      if (!mounted) {
        return;
      }
      setState(() {
        _myScoreForPublicFilters = score;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _myScoreForPublicFilters = 0;
      });
    }
  }

  void _processTabNotificationsFromChats(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> chats,
    String currentUid,
  ) {
    DateTime? latestDirectFromOthers;
    DateTime? latestGroupFromOthers;

    for (final chatDoc in chats) {
      final data = chatDoc.data();
      final lastSenderId =
          ((data['lastMessageSenderId'] as String?) ?? '').trim();
      if (lastSenderId.isEmpty || lastSenderId == currentUid) {
        continue;
      }

      final lastMessageAt =
          _timestampToDate(data['lastMessageAt'] as Timestamp?);
      if (lastMessageAt == null) {
        continue;
      }

      if (_isDirectChat(data)) {
        if (latestDirectFromOthers == null ||
            lastMessageAt.isAfter(latestDirectFromOthers)) {
          latestDirectFromOthers = lastMessageAt;
        }
      } else {
        if (latestGroupFromOthers == null ||
            lastMessageAt.isAfter(latestGroupFromOthers)) {
          latestGroupFromOthers = lastMessageAt;
        }
      }
    }

    final shouldShowUsers = latestDirectFromOthers != null &&
        latestDirectFromOthers.isAfter(_usersTabAcknowledgedAt);
    final shouldShowGroups = latestGroupFromOthers != null &&
        latestGroupFromOthers.isAfter(_groupsTabAcknowledgedAt);

    final nextUsers = _hasNewUsersNotification || shouldShowUsers;
    final nextGroups = _hasNewGroupsNotification || shouldShowGroups;

    if (_hasNewUsersNotification == nextUsers &&
        _hasNewGroupsNotification == nextGroups) {
      return;
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _hasNewUsersNotification = nextUsers;
      _hasNewGroupsNotification = nextGroups;
    });
  }

  Future<DocumentSnapshot<Map<String, dynamic>>> _groupDetails(String groupId) {
    return _groupDetailsCache.putIfAbsent(
      groupId,
      () => FirebaseFirestore.instance.collection('groups').doc(groupId).get(),
    );
  }

  bool _uidInDynamicList(dynamic raw, String uid) {
    if (raw is! List) {
      return false;
    }
    return raw
        .map((value) => value.toString().trim())
        .where((value) => value.isNotEmpty)
        .contains(uid);
  }

  Future<bool> _isApprovedMemberOfGroup({
    required String groupId,
    required String uid,
  }) async {
    final normalizedGroupId = groupId.trim();
    final normalizedUid = uid.trim();
    if (normalizedGroupId.isEmpty || normalizedUid.isEmpty) {
      return false;
    }

    final cacheKey = '$normalizedUid::$normalizedGroupId';
    final cached = _joinedGroupEligibilityCache[cacheKey];
    if (cached != null) {
      return cached;
    }

    bool approved = false;

    try {
      final groupDoc = await FirebaseFirestore.instance
          .collection('groups')
          .doc(normalizedGroupId)
          .get();
      final data = groupDoc.data() ?? const <String, dynamic>{};
      approved = _uidInDynamicList(data['membersList'], normalizedUid) ||
          _uidInDynamicList(data['members'], normalizedUid) ||
          _uidInDynamicList(data['participants'], normalizedUid);
    } catch (_) {
      approved = false;
    }

    if (!approved) {
      try {
        final memberDoc = await FirebaseFirestore.instance
            .collection('groups')
            .doc(normalizedGroupId)
            .collection('members')
            .doc(normalizedUid)
            .get();
        final status =
            (memberDoc.data()?['status'] as String? ?? '').trim().toLowerCase();
        approved = memberDoc.exists && status == 'approved';
      } catch (_) {
        approved = false;
      }
    }

    _joinedGroupEligibilityCache[cacheKey] = approved;
    return approved;
  }

  Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>>
      _filterApprovedGroupChats({
    required List<QueryDocumentSnapshot<Map<String, dynamic>>> groupDocs,
    required String currentUid,
  }) async {
    final result = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
    final normalizedUid = currentUid.trim();
    if (normalizedUid.isEmpty) {
      return result;
    }

    for (final groupDoc in groupDocs) {
      final chatData = groupDoc.data();
      final chatParticipants = (chatData['participants'] as List<dynamic>? ??
              const <dynamic>[])
          .map((value) => value.toString().trim())
          .where((value) => value.isNotEmpty)
          .toSet();

      // Hard guard: only show chats where current user is explicitly a
      // participant in the chat document itself.
      if (!chatParticipants.contains(normalizedUid)) {
        continue;
      }

      final targetGroupId = _targetGroupIdFromChatData(groupDoc);
      var approved = await _isApprovedMemberOfGroup(
        groupId: targetGroupId,
        uid: normalizedUid,
      );

      // Some legacy/public chat docs may use chatId != groupId; if the mapped
      // sourceGroupId is unreadable/missing, retry with the chat doc id.
      if (!approved && targetGroupId != groupDoc.id) {
        approved = await _isApprovedMemberOfGroup(
          groupId: groupDoc.id,
          uid: normalizedUid,
        );
      }

      // Fallback: if membership docs are temporarily unreadable but chat
      // participants already include the user, keep the joined group visible.
      if (!approved && chatParticipants.contains(normalizedUid)) {
        approved = true;
      }

      if (approved) {
        result.add(groupDoc);
      }
    }
    return result;
  }

  DateTime? _extractDateField(Map<String, dynamic> data, String fieldName) {
    return (data[fieldName] as Timestamp?)?.toDate();
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
    return _formatRelativeTime(dateTime);
  }

  String _groupFieldString(Map<String, dynamic> groupData, String key,
      {String fallback = 'לא צוין'}) {
    final value = (groupData[key] as String?)?.trim() ?? '';
    return value.isEmpty ? fallback : value;
  }

  List<String> _groupMemberIds(
      Map<String, dynamic> groupData, List<dynamic> chatParticipants) {
    final membersList = (groupData['membersList'] as List<dynamic>?) ??
        (groupData['members'] as List<dynamic>?) ??
        chatParticipants;
    return membersList
        .map((id) => id.toString().trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
  }

  Widget _detailsChip({
    required IconData icon,
    required String text,
    required Color color,
  }) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: isLight
            ? Colors.white.withValues(alpha: 0.62)
            : color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color:
              isLight ? const Color(0xFFA9C3FF) : color.withValues(alpha: 0.55),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(
              color: isLight ? Colors.black : Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w700,
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
        color: isLight
            ? Colors.white.withValues(alpha: 0.66)
            : const Color(0xFF1A2435),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isLight
              ? const Color(0xFFA9C3FF)
              : accent.withValues(alpha: 0.35),
        ),
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

  Future<void> _showGroupDetailsDialog({
    required String targetGroupId,
    required String groupName,
    required List<dynamic> chatParticipants,
  }) async {
    final isLight = Theme.of(context).brightness == Brightness.light;
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
              gradient: isLight
                  ? null
                  : const LinearGradient(
                      colors: [Color(0xFF53C1F9), Color(0xFF9E7CFF)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
              color: isLight ? Colors.white : null,
            ),
            padding: const EdgeInsets.all(1.8),
            child: Container(
              decoration: BoxDecoration(
                color: isLight
                    ? Colors.white.withValues(alpha: 0.78)
                    : const Color(0xFF111A28),
                borderRadius: BorderRadius.circular(22),
              ),
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
              child: FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                future: _groupDetails(targetGroupId),
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
                  final ageRange =
                      (groupData['ageRange'] as Map<String, dynamic>?) ??
                          const <String, dynamic>{};
                  final minAge = (ageRange['min'] as num?)?.toInt();
                  final maxAge = (ageRange['max'] as num?)?.toInt();
                  final approvalRequired =
                      (groupData['isAdminApprovalRequired'] as bool?) ?? false;
                  final memberIds =
                      _groupMemberIds(groupData, chatParticipants);
                  final membersCount =
                      (groupData['membersCount'] as num?)?.toInt() ??
                          memberIds.length;
                  final ageRangeText = (minAge == null || maxAge == null)
                      ? 'לא הוגדר'
                      : '$minAge-$maxAge';

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(18),
                          color: isLight
                              ? Colors.white.withValues(alpha: 0.62)
                              : null,
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
                                      .withValues(alpha: 0.35)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  width: 32,
                                  height: 32,
                                  decoration: const BoxDecoration(
                                    shape: BoxShape.circle,
                                    gradient: LinearGradient(
                                      colors: [
                                        Color(0xFF53C1F9),
                                        Color(0xFF9E7CFF)
                                      ],
                                    ),
                                  ),
                                  child: Icon(
                                    categoryIconFor(category),
                                    color: Colors.white,
                                    size: 18,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    groupName,
                                    style: TextStyle(
                                      color:
                                          isLight ? Colors.black : Colors.white,
                                      fontSize: 17,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                              ],
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
                                ? const BorderSide(color: Color(0xFFB79BFF))
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

  Future<void> _showParticipantFriendsDialog({
    required String targetGroupId,
    required List<dynamic> chatParticipants,
  }) async {
    final isLight = Theme.of(context).brightness == Brightness.light;
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black54,
      builder: (dialogContext) {
        final dialogSize = MediaQuery.of(dialogContext).size;
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          child: Container(
            constraints: BoxConstraints(
              maxWidth: dialogSize.width * 0.9,
              maxHeight: dialogSize.height * 0.5,
            ),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              gradient: isLight
                  ? null
                  : const LinearGradient(
                      colors: [Color(0xFF53C1F9), Color(0xFF9E7CFF)],
                    ),
              color: isLight ? Colors.white : null,
            ),
            padding: const EdgeInsets.all(1.6),
            child: Container(
              decoration: BoxDecoration(
                color: isLight
                    ? Colors.white.withValues(alpha: 0.78)
                    : const Color(0xFF111A28),
                borderRadius: BorderRadius.circular(20),
              ),
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
              child: FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                future: _groupDetails(targetGroupId),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }

                  final groupData =
                      snapshot.data?.data() ?? <String, dynamic>{};
                  final memberIds =
                      _groupMemberIds(groupData, chatParticipants);
                  final friendMembers = memberIds
                      .where((memberId) => _myFriendIds.contains(memberId))
                      .toList(growable: false);

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'חברים שלך שמשתתפים',
                        style: TextStyle(
                          color: isLight ? Colors.black : Colors.white,
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                        ),
                        textAlign: TextAlign.right,
                      ),
                      const SizedBox(height: 10),
                      Expanded(
                        child: _friendsLoading
                            ? const Center(child: CircularProgressIndicator())
                            : friendMembers.isEmpty
                                ? Center(
                                    child: Text(
                                      'אין לך חברים שמשתתפים בקבוצה זו כרגע',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        color: isLight
                                            ? Colors.black87
                                            : Colors.white,
                                        fontSize: 14,
                                      ),
                                    ),
                                  )
                                : ListView.builder(
                                    itemCount: friendMembers.length,
                                    itemBuilder: (context, index) {
                                      final friendUid = friendMembers[index];
                                      final summary =
                                          _myFriendSummaries[friendUid] ??
                                              const <String, String>{};
                                      final friendName =
                                          (summary['name'] ?? '').trim().isEmpty
                                              ? 'חבר'
                                              : (summary['name'] ?? '').trim();
                                      final avatarUrl =
                                          (summary['avatarUrl'] ?? '').trim();

                                      return Container(
                                        margin:
                                            const EdgeInsets.only(bottom: 6),
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 9, vertical: 6),
                                        decoration: BoxDecoration(
                                          color: isLight
                                              ? Colors.white
                                                  .withValues(alpha: 0.62)
                                              : const Color(0xFF1E2632),
                                          borderRadius:
                                              BorderRadius.circular(12),
                                          border: Border.all(
                                              color: isLight
                                                  ? const Color(0xFFA9C3FF)
                                                  : const Color(0xFF53C1F9)
                                                      .withValues(alpha: 0.25)),
                                        ),
                                        child: Row(
                                          children: [
                                            CircleAvatar(
                                              radius: 14,
                                              backgroundColor:
                                                  const Color(0xFF9E7CFF),
                                              backgroundImage:
                                                  avatarUrl.isNotEmpty
                                                      ? NetworkImage(avatarUrl)
                                                      : null,
                                              child: avatarUrl.isEmpty
                                                  ? Text(
                                                      friendName
                                                          .characters.first,
                                                      style: const TextStyle(
                                                          color: Colors.white,
                                                          fontWeight:
                                                              FontWeight.w700),
                                                    )
                                                  : null,
                                            ),
                                            const SizedBox(width: 10),
                                            Expanded(
                                              child: Text(
                                                friendName,
                                                style: TextStyle(
                                                  color: isLight
                                                      ? Colors.black
                                                      : Colors.white,
                                                  fontWeight: FontWeight.w600,
                                                  fontSize: 13,
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
                            foregroundColor: isLight
                                ? const Color(0xFF9AB0FF)
                                : Colors.white,
                            side: BorderSide(
                                color: isLight
                                    ? const Color(0xFFA9C3FF)
                                    : const Color(0xFF53C1F9)),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: const Text('סגור'),
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

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final screenWidth = MediaQuery.of(context).size.width;
    final orbSizeA = (screenWidth * 0.82).clamp(230.0, 320.0);
    final orbSizeB = (screenWidth * 0.88).clamp(250.0, 340.0);
    final baseTextStyle = TextStyle(
      fontFamily: 'Segoe UI',
      color: isLight ? Colors.black : Colors.white,
    );

    return Scaffold(
      extendBody: true,
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: isLight
                ? const [Colors.white, Color(0xFFF8FBFF), Colors.white]
                : const [Color(0xFF0B1019), Color(0xFF0B1019)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (isLight)
              Positioned(
                top: -130,
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
            Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: _dismissKeyboardOnBackgroundTap,
              child: SafeArea(
                child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          Expanded(
                            child: Container(
                              clipBehavior: Clip.antiAlias,
                              decoration: BoxDecoration(
                                color: isLight
                                    ? Colors.white.withValues(alpha: 0.62)
                                    : const Color(0xFF1E2632),
                                borderRadius: BorderRadius.circular(24),
                              ),
                              child: TextField(
                                controller: _searchController,
                                onTapOutside: (_) {},
                                onChanged: (value) {
                                  setState(() {
                                    searchQuery = value;
                                  });
                                },
                                style: baseTextStyle,
                                decoration: InputDecoration(
                                  hintText: 'lets be hundred',
                                  hintStyle: baseTextStyle.copyWith(
                                    color: isLight
                                        ? Colors.black54
                                        : Colors.grey[600],
                                  ),
                                  filled: true,
                                  fillColor: Colors.transparent,
                                  prefixIcon: Icon(
                                    Icons.search_rounded,
                                    color: isLight
                                        ? const Color(0xFF9AB0FF)
                                        : Colors.grey[500],
                                    size: 20,
                                  ),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(24),
                                    borderSide: BorderSide(
                                      color: isLight
                                          ? const Color(0xFFA9C3FF)
                                          : const Color(0xFF3F5877),
                                      width: 1.3,
                                    ),
                                  ),
                                  enabledBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(24),
                                    borderSide: BorderSide(
                                      color: isLight
                                          ? const Color(0xFFA9C3FF)
                                          : const Color(0xFF3F5877),
                                      width: 1.3,
                                    ),
                                  ),
                                  focusedBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(24),
                                    borderSide: BorderSide(
                                      color: isLight
                                          ? const Color(0xFFA9C3FF)
                                          : const Color(0xFF3F5877),
                                      width: 1.3,
                                    ),
                                  ),
                                  contentPadding: const EdgeInsets.symmetric(
                                    vertical: 12,
                                    horizontal: 16,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Container(
                            width: 48,
                            height: 48,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: isLight
                                  ? const LinearGradient(
                                      colors: [
                                        Color(0xFF9EEBFF),
                                        Color(0xFFC9B7FF)
                                      ],
                                      begin: Alignment.topLeft,
                                      end: Alignment.bottomRight,
                                    )
                                  : const LinearGradient(
                                      colors: [
                                        Color(0xFF9E7CFF),
                                        Color(0xFF53C1F9)
                                      ],
                                    ),
                              color: isLight ? null : null,
                              border: Border.all(
                                color: isLight
                                    ? const Color(0xFFB79BFF)
                                    : Colors.transparent,
                              ),
                              boxShadow: isLight
                                  ? [
                                      BoxShadow(
                                        color: const Color(0xFF53C1F9)
                                            .withValues(alpha: 0.25),
                                        blurRadius: 14,
                                        offset: const Offset(0, 5),
                                      ),
                                      BoxShadow(
                                        color: const Color(0xFFB79BFF)
                                            .withValues(alpha: 0.22),
                                        blurRadius: 14,
                                        offset: const Offset(0, 6),
                                      ),
                                    ]
                                  : null,
                            ),
                            child: Material(
                              color: Colors.transparent,
                              child: InkWell(
                                borderRadius: BorderRadius.circular(24),
                                onTap: () async {
                                  final newGroup = await Navigator.push<
                                      Map<String, dynamic>>(
                                    context,
                                    PageRouteBuilder(
                                      pageBuilder: (context, animation,
                                              secondaryAnimation) =>
                                          const CreateGroupScreen(),
                                      transitionsBuilder: (context, animation,
                                          secondaryAnimation, child) {
                                        return FadeTransition(
                                            opacity: animation, child: child);
                                      },
                                    ),
                                  );

                                  if (!mounted) {
                                    return;
                                  }

                                  if (newGroup != null) {
                                    setState(() {
                                      _selectedChatsTabIndex = 1;
                                    });
                                  }
                                },
                                child: const Icon(
                                  Icons.add_rounded,
                                  color: Colors.white,
                                  size: 25,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (_hasSearchQuery) _buildGlobalSearchResultsPanel(),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Container(
                        decoration: BoxDecoration(
                          color: isLight
                              ? Colors.white.withValues(alpha: 0.62)
                              : const Color(0xFF1E2632),
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(
                            color: isLight
                                ? const Color(0xFFA9C3FF)
                                : Colors.transparent,
                          ),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: GestureDetector(
                                onTap: () {
                                  setState(() {
                                    _selectedChatsTabIndex = 0;
                                    _hasNewUsersNotification = false;
                                    _usersTabAcknowledgedAt = DateTime.now();
                                    _searchController.clear();
                                    searchQuery = '';
                                  });
                                },
                                child: Container(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 12),
                                  decoration: BoxDecoration(
                                    color: _selectedChatsTabIndex == 0
                                        ? (isLight
                                            ? const Color(0xFFE8EEFF)
                                            : const Color(0xFF9E7CFF))
                                        : Colors.transparent,
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  alignment: Alignment.center,
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Flexible(
                                        child: FittedBox(
                                          fit: BoxFit.scaleDown,
                                          child: Text(
                                            'משתמשים',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: baseTextStyle.copyWith(
                                                color: isLight
                                                    ? Colors.black
                                                    : Colors.white,
                                                fontWeight: FontWeight.w600),
                                          ),
                                        ),
                                      ),
                                      if (_hasNewUsersNotification) ...[
                                        const SizedBox(width: 6),
                                        _buildGroupsTabNotificationDot(
                                          isLight: isLight,
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            Expanded(
                              child: GestureDetector(
                                onTap: () {
                                  setState(() {
                                    _selectedChatsTabIndex = 1;
                                    _hasNewGroupsNotification = false;
                                    _groupsTabAcknowledgedAt = DateTime.now();
                                    _searchController.clear();
                                    searchQuery = '';
                                  });
                                },
                                child: Container(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 12),
                                  decoration: BoxDecoration(
                                    color: _selectedChatsTabIndex == 1
                                        ? (isLight
                                            ? const Color(0xFFE8EEFF)
                                            : const Color(0xFF9E7CFF))
                                        : Colors.transparent,
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  alignment: Alignment.center,
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Flexible(
                                        child: FittedBox(
                                          fit: BoxFit.scaleDown,
                                          child: Text(
                                            'קבוצות',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: baseTextStyle.copyWith(
                                                color: isLight
                                                    ? Colors.black
                                                    : Colors.white,
                                                fontWeight: FontWeight.w600),
                                          ),
                                        ),
                                      ),
                                      if (_hasNewGroupsNotification) ...[
                                        const SizedBox(width: 6),
                                        _buildGroupsTabNotificationDot(
                                          isLight: isLight,
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            Expanded(
                              child: GestureDetector(
                                onTap: () {
                                  setState(() {
                                    _selectedChatsTabIndex = 2;
                                    _searchController.clear();
                                    searchQuery = '';
                                  });
                                },
                                child: Container(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 12),
                                  decoration: BoxDecoration(
                                    color: _selectedChatsTabIndex == 2
                                        ? (isLight
                                            ? const Color(0xFFE8EEFF)
                                            : const Color(0xFF9E7CFF))
                                        : Colors.transparent,
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  alignment: Alignment.center,
                                  child: FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: Text(
                                      'קבוצות ציבוריות',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: baseTextStyle.copyWith(
                                          color: isLight
                                              ? Colors.black
                                              : Colors.white,
                                          fontWeight: FontWeight.w600),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    _buildActiveChatsTab(),
                    const SizedBox(height: 120),
                  ],
                ),
              ),
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: const MainBottomNav(currentIndex: 3),
    );
  }

  Widget _buildExistingChatsList() {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) {
      return _buildCenteredMessage('אין עדיין צאטים!');
    }
    _ensureStableChatStreams(currentUser.uid);

    return StreamBuilder<List<QueryDocumentSnapshot<Map<String, dynamic>>>>(
      stream: _userChatsStream,
      initialData: _lastUserChatsDocs ?? const <QueryDocumentSnapshot<Map<String, dynamic>>>[],
      builder: (context, chatSnapshot) {
        if (chatSnapshot.connectionState == ConnectionState.waiting &&
            !chatSnapshot.hasData) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 40),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        if (chatSnapshot.hasError) {
          return _buildCenteredMessage('אין עדיין צאטים עם משתמשים');
        }

        final docs = chatSnapshot.data ??
            const <QueryDocumentSnapshot<Map<String, dynamic>>>[];
        _lastUserChatsDocs = docs;
        final directDocs = docs
            .where((doc) => _isDirectChat(doc.data()))
            .toList(growable: false);
        final filteredDocs = _filterAndSortChats(directDocs);

        return FutureBuilder<List<QueryDocumentSnapshot<Map<String, dynamic>>>>(
          future: _resolveVisibleDirectChats(filteredDocs, currentUser.uid),
          builder: (context, visibleSnapshot) {
            if (visibleSnapshot.connectionState != ConnectionState.done &&
                !visibleSnapshot.hasData) {
              return _buildChatsLoadingSkeleton();
            }

            if (visibleSnapshot.hasError) {
              return _buildErrorState(
                'שגיאה בסינון שיחות: ${visibleSnapshot.error}',
              );
            }

            final visibleDocs = visibleSnapshot.data ??
                const <QueryDocumentSnapshot<Map<String, dynamic>>>[];
            if (visibleDocs.isEmpty) {
              return _buildCenteredMessage('אין עדיין צאטים עם משתמשים');
            }

            return FutureBuilder<Map<String, Map<String, String>>>(
              future: _directChatSummaries(visibleDocs, currentUser.uid),
              builder: (context, summarySnapshot) {
                if (summarySnapshot.connectionState != ConnectionState.done &&
                    !summarySnapshot.hasData) {
                  return _buildChatsLoadingSkeleton();
                }

                if (summarySnapshot.hasError) {
                  return _buildErrorState(
                    'שגיאה בטעינת פרטי הצאטים: ${summarySnapshot.error}',
                  );
                }

                final summaries = summarySnapshot.data ??
                    const <String, Map<String, String>>{};

                return ListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: visibleDocs.length,
                  itemBuilder: (context, index) {
                    final chatDoc = visibleDocs[index];
                    final chatData = chatDoc.data();
                    final description =
                        (chatData['description'] as String?) ?? '';
                    final lastMessage =
                        (chatData['lastMessage'] as String?) ?? '';
                    final isPublic = (chatData['isPublic'] as bool?) ?? false;
                    final participants = List<String>.from(
                      (chatData['participants'] as List<dynamic>?) ??
                          const <String>[],
                    );
                    final isDirectChat = (chatData['isDirect'] as bool?) ??
                        (!isPublic && participants.length == 2);
                    final otherUserId =
                        _directChatOtherUserId(chatData, currentUser.uid);

                    if (isDirectChat && !summaries.containsKey(otherUserId)) {
                      return const Padding(
                        padding:
                            EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        child: _ChatLoadingTile(),
                      );
                    }

                    final otherUserSummary =
                        summaries[otherUserId] ?? const <String, String>{};
                    final chatName = isDirectChat
                        ? ((otherUserSummary['name'] ?? '').trim().isNotEmpty
                            ? (otherUserSummary['name'] ?? '').trim()
                            : 'טוען...')
                        : ((chatData['name'] as String?) ?? 'Chat');
                    final imageUrl = isDirectChat
                        ? ((otherUserSummary['avatarUrl'] ?? '').trim())
                        : ((chatData['groupImageUrl'] as String?) ?? '').trim();
                    final activityDate = _chatActivityDate(chatData);

                    final subtitleText = lastMessage.isNotEmpty
                        ? lastMessage
                        : (description.isEmpty ? 'צאט פעיל' : description);

                    final tile = Container(
                      decoration: BoxDecoration(
                        color: isLight
                            ? Colors.white.withValues(alpha: 0.62)
                            : const Color(0xFF1E2632),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Material(
                        type: MaterialType.transparency,
                        child: ListTile(
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) => ChatRoomScreen(
                                  chatName: chatName,
                                  avatarUrl: imageUrl.isEmpty ? null : imageUrl,
                                  chatId: chatDoc.id,
                                  isDirectChat: isDirectChat,
                                  directOtherUserId:
                                      isDirectChat ? otherUserId : null,
                                ),
                              ),
                            );
                          },
                          leading: isDirectChat
                              ? _buildChatAvatar(
                                  name: chatName,
                                  imageUrl: imageUrl,
                                )
                              : _buildLiveGroupAvatar(
                                  groupId: chatDoc.id,
                                  fallbackImageUrl: imageUrl,
                                ),
                          title: Text(
                            chatName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: 'Segoe UI',
                              color: isLight ? Colors.black : Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          subtitle: Text(
                            subtitleText,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color:
                                  isLight ? Colors.black87 : Colors.grey[400],
                            ),
                          ),
                          trailing: SizedBox(
                            width: 92,
                            child: Text(
                              _formatRelativeTime(activityDate),
                              textAlign: TextAlign.end,
                              style: TextStyle(
                                color:
                                    isLight ? Colors.black54 : Colors.grey[500],
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ),
                      ),
                    );

                    return Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                      child: _buildChatFrame(
                        child: tile,
                        hasUnread: false,
                      ),
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

  Widget _buildActiveChatsTab() {
    switch (_selectedChatsTabIndex) {
      case 0:
        return KeyedSubtree(
          key: const ValueKey<String>('chats_users_tab'),
          child: _buildExistingChatsList(),
        );
      case 1:
        return KeyedSubtree(
          key: const ValueKey<String>('chats_groups_tab'),
          child: _buildRequestsList(),
        );
      case 2:
      default:
        return KeyedSubtree(
          key: const ValueKey<String>('chats_public_groups_tab'),
          child: _buildPublicGroupsList(),
        );
    }
  }

  Widget _buildPublicGroupsList() {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final currentUid = FirebaseAuth.instance.currentUser?.uid;
    if (currentUid == null || currentUid.isEmpty) {
      return _buildCenteredMessage('יש להתחבר כדי לצפות בקבוצות ציבוריות');
    }
    _ensureStableChatStreams(currentUid);

    return StreamBuilder<List<QueryDocumentSnapshot<Map<String, dynamic>>>>(
      stream: _publicChatsStream,
      initialData: _lastPublicChatsDocs ?? const <QueryDocumentSnapshot<Map<String, dynamic>>>[],
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting &&
            !snapshot.hasData) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 40),
            child: Center(child: CircularProgressIndicator()),
          );
        }

        if (snapshot.hasError) {
          return Column(
            children: [
              _buildPublicGroupsFiltersBar(),
              _buildPublicGroupsEmptyState(context),
            ],
          );
        }

        final docs = snapshot.data ??
            const <QueryDocumentSnapshot<Map<String, dynamic>>>[];
        _lastPublicChatsDocs = docs;
        final filteredDocs = _filterPublicChats(docs);
        if (filteredDocs.isEmpty) {
          return Column(
            children: [
              _buildPublicGroupsFiltersBar(),
              _buildPublicGroupsEmptyState(context),
            ],
          );
        }

        return FutureBuilder<List<Map<String, dynamic>>>(
          future: _resolvePublicGroupEntries(filteredDocs),
          builder: (context, resolvedSnapshot) {
            if (resolvedSnapshot.connectionState != ConnectionState.done &&
                !resolvedSnapshot.hasData) {
              return Column(
                children: [
                  _buildPublicGroupsFiltersBar(),
                  _buildChatsLoadingSkeleton(),
                ],
              );
            }

            if (resolvedSnapshot.hasError) {
              return _buildErrorState(
                'שגיאה בטעינת קבוצות ציבוריות: ${resolvedSnapshot.error}',
              );
            }

            final resolvedEntries =
                resolvedSnapshot.data ?? const <Map<String, dynamic>>[];
            final visibleEntries = _applyPublicGroupsFilters(resolvedEntries);

            return Column(
              children: [
                _buildPublicGroupsFiltersBar(),
                if (visibleEntries.isEmpty)
                  _buildCenteredMessage('לא נמצאו קבוצות לפי הסינון שבחרת')
                else
                  ListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: visibleEntries.length,
                    itemBuilder: (context, index) {
                      final entry = visibleEntries[index];
                      final groupName = ((entry['groupName'] as String?) ??
                              (entry['name'] as String?) ??
                              'Chat')
                          .trim();
                      final groupDescription =
                          ((entry['description'] as String?) ?? '').trim();
                      final groupImageUrl =
                          ((entry['groupImageUrl'] as String?) ?? '').trim();
                      final participants =
                          (entry['_participants'] as List<dynamic>? ??
                              const <dynamic>[]);
                      final membersCountRaw = entry['membersCount'];
                      final memberCount = membersCountRaw is num
                          ? membersCountRaw.toInt()
                          : participants.length;
                      final targetGroupId =
                          (entry['_targetGroupId'] as String?) ?? '';
                      final minScore = _publicGroupMinScore(entry);
                      final mainCategory = _publicGroupCategory(entry);
                      final subCategory = _publicGroupSubCategory(entry);
                      final categoryLabel = mainCategory.isEmpty
                          ? kGeneralCategory
                          : mainCategory;
                      final categoryAndSubCategory = subCategory.isEmpty
                          ? '$categoryLabel • ללא תת קטגוריה'
                          : '$categoryLabel • $subCategory';

                      return Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                        child: Container(
                          decoration: BoxDecoration(
                            color: isLight
                                ? Colors.white.withValues(alpha: 0.62)
                                : const Color(0xFF1E2632),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: isLight
                                  ? const Color(0xFFA9C3FF)
                                  : const Color(0xFF53C1F9)
                                      .withValues(alpha: 0.22),
                            ),
                          ),
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  _buildLiveGroupAvatar(
                                    groupId: targetGroupId,
                                    fallbackImageUrl: groupImageUrl,
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Expanded(
                                              child: Text(
                                                groupName,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  fontFamily: 'Segoe UI',
                                                  color: isLight
                                                      ? Colors.black
                                                      : Colors.white,
                                                  fontWeight: FontWeight.bold,
                                                  fontSize: 16,
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.end,
                                              children: [
                                                _buildPublicGroupBadge(),
                                                const SizedBox(height: 6),
                                                _buildMinScoreBadge(minScore),
                                              ],
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          groupDescription,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontFamily: 'Segoe UI',
                                            color: isLight
                                                ? Colors.black87
                                                : Colors.grey[400],
                                            fontSize: 12,
                                          ),
                                        ),
                                        const SizedBox(height: 7),
                                        Row(
                                          children: [
                                            Container(
                                              width: 22,
                                              height: 22,
                                              decoration: const BoxDecoration(
                                                shape: BoxShape.circle,
                                                gradient: LinearGradient(
                                                  colors: [
                                                    Color(0xFF53C1F9),
                                                    Color(0xFF9E7CFF)
                                                  ],
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
                                                categoryAndSubCategory,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  color: isLight
                                                      ? Colors.black87
                                                      : const Color(0xFFD1D7E4),
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.w600,
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
                              const SizedBox(height: 12),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Align(
                                    alignment: Alignment.centerRight,
                                    child: Wrap(
                                      spacing: 8,
                                      runSpacing: 8,
                                      crossAxisAlignment:
                                          WrapCrossAlignment.center,
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 10, vertical: 6),
                                          decoration: BoxDecoration(
                                            color: isLight
                                                ? Colors.white
                                                    .withValues(alpha: 0.72)
                                                : const Color(0xFF0F1522),
                                            borderRadius:
                                                BorderRadius.circular(999),
                                            border: Border.all(
                                              color: isLight
                                                  ? const Color(0xFFA9C3FF)
                                                  : const Color(0xFF53C1F9)
                                                      .withValues(alpha: 0.28),
                                            ),
                                          ),
                                          child: Text(
                                            '$memberCount חברים',
                                            style: TextStyle(
                                              fontFamily: 'Segoe UI',
                                              color: isLight
                                                  ? Colors.black87
                                                  : Colors.grey[300],
                                              fontSize: 12,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ),
                                        OutlinedButton.icon(
                                          onPressed: () =>
                                              _showGroupDetailsDialog(
                                            targetGroupId: targetGroupId,
                                            groupName: groupName,
                                            chatParticipants: participants,
                                          ),
                                          style: OutlinedButton.styleFrom(
                                            foregroundColor:
                                                const Color(0xFF53C1F9),
                                            side: BorderSide(
                                              color: const Color(0xFF53C1F9)
                                                  .withValues(alpha: 0.7),
                                            ),
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 10, vertical: 10),
                                            shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                            ),
                                          ),
                                          icon: const Icon(
                                              Icons.info_outline_rounded,
                                              size: 16),
                                          label: const Text(
                                            'פרטים',
                                            style: TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.w700),
                                          ),
                                        ),
                                        OutlinedButton.icon(
                                          onPressed: () =>
                                              _showParticipantFriendsDialog(
                                            targetGroupId: targetGroupId,
                                            chatParticipants: participants,
                                          ),
                                          style: OutlinedButton.styleFrom(
                                            foregroundColor:
                                                const Color(0xFFB6A3FF),
                                            side: BorderSide(
                                              color: const Color(0xFF9E7CFF)
                                                  .withValues(alpha: 0.7),
                                            ),
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 10, vertical: 10),
                                            shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                            ),
                                          ),
                                          icon: const Icon(
                                              Icons.people_alt_outlined,
                                              size: 16),
                                          label: const Text(
                                            'חברים משתתפים',
                                            style: TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.w700),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  StreamBuilder<String?>(
                                    stream: _groupService
                                        .myMembershipStatus(targetGroupId),
                                    builder: (context, statusSnapshot) {
                                      final status = statusSnapshot.data;
                                      final isPending = status == 'pending';
                                      final isApproved = status == 'approved';

                                      Color backgroundColor =
                                          const Color(0xFF9E7CFF);
                                      String label = 'הצטרף';
                                      VoidCallback? onPressed =
                                          () => _joinPublicGroup(targetGroupId);

                                      if (isPending) {
                                        backgroundColor =
                                            const Color(0xFF3F97D6);
                                        label = 'בקשתך נשלחה';
                                        onPressed = () =>
                                            _confirmCancelJoinRequest(
                                                targetGroupId);
                                      } else if (isApproved) {
                                        backgroundColor = Colors.grey;
                                        label = 'כבר חבר';
                                        onPressed = null;
                                      }

                                      return ElevatedButton(
                                        onPressed: onPressed,
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: backgroundColor,
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 23,
                                            vertical: 10,
                                          ),
                                          minimumSize:
                                              const Size(double.infinity, 40),
                                          tapTargetSize:
                                              MaterialTapTargetSize.shrinkWrap,
                                          shape: RoundedRectangleBorder(
                                            borderRadius:
                                                BorderRadius.circular(12),
                                          ),
                                        ),
                                        child: Text(
                                          label,
                                          maxLines: 1,
                                          softWrap: false,
                                          overflow: TextOverflow.fade,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 13,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
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
                  ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _joinPublicGroup(String groupId) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || uid.isEmpty) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please log in to join chats.')),
      );
      return;
    }

    try {
      final groupSnapshot = await FirebaseFirestore.instance
          .collection('groups')
          .doc(groupId)
          .get();
      final groupData = groupSnapshot.data() ?? <String, dynamic>{};
      final approvalRequired =
          (groupData['isAdminApprovalRequired'] as bool?) ?? false;

      await _groupService.joinGroup(groupId);

      if (!mounted) {
        return;
      }

      if (approvalRequired) {
        _joinedGroupEligibilityCache.remove('$uid::${groupId.trim()}');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('בקשת ההצטרפות נשלחה למנהל הקבוצה')),
        );
        return;
      }

      _joinedGroupEligibilityCache.remove('$uid::${groupId.trim()}');
      setState(() {
        _hasNewGroupsNotification = true;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('הצטרפת לקבוצה בהצלחה!')),
      );
    } catch (error, stackTrace) {
      if (error is FirebaseException) {
        debugPrint(
          '[ChatsScreen][joinPublicGroup] FirebaseException code=${error.code} plugin=${error.plugin} message=${error.message} groupId=$groupId',
        );
      } else {
        debugPrint(
          '[ChatsScreen][joinPublicGroup] error=${error.runtimeType} value=$error groupId=$groupId',
        );
      }
      debugPrint('[ChatsScreen][joinPublicGroup] stackTrace=$stackTrace');

      if (!mounted) {
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
              _friendlyJoinErrorMessage(error),
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

  Future<void> _confirmCancelJoinRequest(String groupId) async {
    final shouldCancel = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: const Color(0xFF121B2D),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: BorderSide(
              color: const Color(0xFF53C1F9).withValues(alpha: 0.45),
              width: 1.2,
            ),
          ),
          title: const Text(
            'ביטול בקשת הצטרפות',
            style: TextStyle(
              color: Color(0xFFEAF4FF),
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.right,
          ),
          content: const Text(
            'האם לבטל את בקשת ההצטרפות לקבוצה?',
            style: TextStyle(color: Color(0xFFBFD2EA)),
            textAlign: TextAlign.right,
          ),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF9EDBFF),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              ),
              child: const Text('לא'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF9E7CFF),
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              ),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('כן, בטל'),
            ),
          ],
        );
      },
    );

    if (shouldCancel != true) {
      return;
    }

    try {
      final uid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
      await _groupService.cancelMyPendingJoinRequest(groupId);
      if (!mounted) {
        return;
      }
      if (uid.isNotEmpty) {
        _joinedGroupEligibilityCache.remove('$uid::${groupId.trim()}');
      }
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('בקשת ההצטרפות בוטלה')),
      );
    } catch (error, stackTrace) {
      if (error is FirebaseException) {
        debugPrint(
          '[ChatsScreen][cancelJoinRequest] FirebaseException code=${error.code} plugin=${error.plugin} message=${error.message} groupId=$groupId',
        );
      } else {
        debugPrint(
          '[ChatsScreen][cancelJoinRequest] error=${error.runtimeType} value=$error groupId=$groupId',
        );
      }
      debugPrint('[ChatsScreen][cancelJoinRequest] stackTrace=$stackTrace');

      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('ביטול בקשת ההצטרפות נכשל')),
      );
    }
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

  List<QueryDocumentSnapshot<Map<String, dynamic>>> _filterAndSortChats(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) {
    final query = searchQuery.trim().toLowerCase();
    final filtered = query.isEmpty
        ? docs.toList(growable: false)
        : docs.where((doc) {
            final data = doc.data();
            final name = ((data['name'] as String?) ?? '').toLowerCase();
            final description =
                ((data['description'] as String?) ?? '').toLowerCase();
            final lastMessage =
                ((data['lastMessage'] as String?) ?? '').toLowerCase();
            return name.contains(query) ||
                description.contains(query) ||
                lastMessage.contains(query);
          }).toList(growable: false);

    filtered.sort((a, b) {
      final aDate = _chatActivityDate(a.data());
      final bDate = _chatActivityDate(b.data());
      final aComparable = aDate ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bComparable = bDate ?? DateTime.fromMillisecondsSinceEpoch(0);
      return bComparable.compareTo(aComparable);
    });
    return filtered;
  }

  List<QueryDocumentSnapshot<Map<String, dynamic>>> _filterPublicChats(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) {
    final query = searchQuery.trim().toLowerCase();
    if (query.isEmpty) {
      return docs.toList(growable: false);
    }

    return docs.where((doc) {
      final data = doc.data();
      final name = ((data['name'] as String?) ?? '').toLowerCase();
      final description =
          ((data['description'] as String?) ?? '').toLowerCase();
      return name.contains(query) || description.contains(query);
    }).toList(growable: false);
  }

  Future<List<Map<String, dynamic>>> _resolvePublicGroupEntries(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) async {
    final resolved = <Map<String, dynamic>>[];

    for (final doc in docs) {
      final chatData = doc.data();
      final targetGroupId = _targetGroupIdFromChatData(doc);
      final detailsDoc = await _groupDetails(targetGroupId);
      final detailsData = detailsDoc.data() ?? <String, dynamic>{};

      resolved.add(<String, dynamic>{
        ...chatData,
        ...detailsData,
        '_targetGroupId': targetGroupId,
        '_participants':
            (chatData['participants'] as List<dynamic>?) ?? const <dynamic>[],
      });
    }

    return resolved;
  }

  DateTime? _publicGroupDate(Map<String, dynamic> data) {
    final raw = data['date'] ?? data['executionDate'];
    if (raw is Timestamp) return raw.toDate();
    if (raw is DateTime) return raw;
    if (raw is String) return DateTime.tryParse(raw.trim());
    return null;
  }

  int _publicGroupMinAge(Map<String, dynamic> data) {
    final ageRange = data['ageRange'];
    if (ageRange is Map<String, dynamic>) {
      final minRaw = ageRange['min'];
      if (minRaw is num) return minRaw.toInt();
    }
    return 0;
  }

  int _publicGroupMaxAge(Map<String, dynamic> data) {
    final ageRange = data['ageRange'];
    if (ageRange is Map<String, dynamic>) {
      final maxRaw = ageRange['max'];
      if (maxRaw is num) return maxRaw.toInt();
    }
    return 60;
  }

  int _publicGroupMinScore(Map<String, dynamic> data) {
    final raw = data['minScore'];
    if (raw is num) return raw.toInt();
    if (raw is String) {
      return int.tryParse(raw.trim()) ?? 0;
    }
    return 0;
  }

  bool _publicGroupRequiresMinScore(Map<String, dynamic> data) {
    final explicit = data['isMinScoreRequired'];
    if (explicit is bool) {
      return explicit;
    }
    return _publicGroupMinScore(data) > 0;
  }

  String _publicGroupCategory(Map<String, dynamic> data) {
    return ((data['category'] as String?) ??
            (data['mainCategory'] as String?) ??
            '')
        .trim();
  }

  String _publicGroupSubCategory(Map<String, dynamic> data) {
    return (data['subCategory'] as String? ?? '').trim();
  }

  List<Map<String, dynamic>> _applyPublicGroupsFilters(
    List<Map<String, dynamic>> entries,
  ) {
    return entries.where((entry) {
      final minAge = _publicGroupMinAge(entry).toDouble();
      final maxAge = _publicGroupMaxAge(entry).toDouble();
      final overlap = maxAge >= _publicFilterAgeRange.start &&
          minAge <= _publicFilterAgeRange.end;
      if (!overlap) {
        return false;
      }

      if (_publicFilterOnlyEligibleByScore) {
        final myScore = _myScoreForPublicFilters ?? 0;
        final minScore = _publicGroupMinScore(entry);
        final requiresScore = _publicGroupRequiresMinScore(entry);
        if (requiresScore && myScore < minScore) {
          return false;
        }
      }

      final groupDate = _publicGroupDate(entry);
      if (_publicFilterFromDate != null) {
        if (groupDate == null || groupDate.isBefore(_publicFilterFromDate!)) {
          return false;
        }
      }
      if (_publicFilterToDate != null) {
        if (groupDate == null || groupDate.isAfter(_publicFilterToDate!)) {
          return false;
        }
      }

      if (_publicFilterCategory != null && _publicFilterCategory!.isNotEmpty) {
        if (_publicGroupCategory(entry) != _publicFilterCategory) {
          return false;
        }
      }

      if (_publicFilterSubCategory != null &&
          _publicFilterSubCategory!.isNotEmpty) {
        if (_publicGroupSubCategory(entry) != _publicFilterSubCategory) {
          return false;
        }
      }

      return true;
    }).toList(growable: false);
  }

  Widget _buildChatAvatar({required String name, required String imageUrl}) {
    return GroupAvatar(
      radius: 28,
      imageUrl: imageUrl,
    );
  }

  Widget _buildLiveGroupAvatar({
    required String groupId,
    required String fallbackImageUrl,
  }) {
    final normalizedFallback = fallbackImageUrl.trim();
    if (normalizedFallback.isNotEmpty) {
      return GroupAvatar(
        radius: 28,
        imageUrl: normalizedFallback,
      );
    }

    final normalizedGroupId = groupId.trim();
    if (normalizedGroupId.isEmpty) {
      return _buildChatAvatar(name: '', imageUrl: '');
    }

    return FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      future: _groupDetails(normalizedGroupId),
      builder: (context, snapshot) {
        final groupData = snapshot.data?.data() ?? const <String, dynamic>{};
        final resolvedImageUrl =
            ((groupData['groupImageUrl'] as String?) ?? '').trim();
        return GroupAvatar(
          radius: 28,
          imageUrl: resolvedImageUrl,
        );
      },
    );
  }

  Widget _buildPublicGroupsFiltersBar() {
    final isLight = Theme.of(context).brightness == Brightness.light;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _hasActivePublicFilters
                  ? 'מסונן לפי ההעדפות שבחרת'
                  : 'סינון קבוצות ציבוריות',
              style: TextStyle(
                color: isLight ? Colors.black87 : Colors.grey[300],
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          OutlinedButton.icon(
            onPressed: _openPublicGroupsFiltersSheet,
            icon: const Icon(Icons.filter_alt_rounded, size: 16),
            label: const Text('סינון'),
            style: OutlinedButton.styleFrom(
              foregroundColor:
                  isLight ? const Color(0xFF9AB0FF) : const Color(0xFF9EDBFF),
              side: BorderSide(
                color: isLight
                    ? const Color(0xFFA9C3FF)
                    : const Color(0xFF53C1F9).withValues(alpha: 0.7),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
          if (_hasActivePublicFilters) ...[
            const SizedBox(width: 8),
            TextButton(
              onPressed: () {
                setState(() {
                  _publicFilterAgeRange = RangeValues(
                    minimumUserAge.toDouble(),
                    maximumAgeRange.toDouble(),
                  );
                  _publicFilterOnlyEligibleByScore = false;
                  _publicFilterFromDate = null;
                  _publicFilterToDate = null;
                  _publicFilterCategory = null;
                  _publicFilterSubCategory = null;
                });
              },
              child: const Text('נקה'),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _openPublicGroupsFiltersSheet() async {
    final isLight = Theme.of(context).brightness == Brightness.light;
    RangeValues draftAgeRange = _publicFilterAgeRange;
    bool draftOnlyEligibleByScore = _publicFilterOnlyEligibleByScore;
    DateTime? draftFromDate = _publicFilterFromDate;
    DateTime? draftToDate = _publicFilterToDate;
    String? draftCategory = _publicFilterCategory;
    String? draftSubCategory = _publicFilterSubCategory;

    Future<DateTime?> pickDate(DateTime? initial) {
      return showDatePicker(
        context: context,
        initialDate: initial ?? DateTime.now(),
        firstDate: DateTime.now().subtract(const Duration(days: 3650)),
        lastDate: DateTime.now().add(const Duration(days: 3650)),
      );
    }

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: isLight
          ? Colors.white.withValues(alpha: 0.96)
          : const Color(0xFF101826),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
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
                        'סינון קבוצות ציבוריות',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: isLight ? Colors.black : Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 14),
                      _buildPublicFilterCategorySelectionCard(
                        title: 'קטגוריה',
                        valueText: draftCategory ?? '',
                        hintText: 'בחר קטגוריה',
                        icon: Icons.category_rounded,
                        isLight: isLight,
                        onTap: () async {
                          final selected = await _showPublicFilterChoiceDialog(
                            title: 'בחר קטגוריה',
                            subtitle: 'הקטגוריה תקבע את תת-הקטגוריה של הקבוצה',
                            options: _mainCategoryFilterOptions(),
                            selectedValue: draftCategory,
                            showPoints: false,
                            showLeadingIcon: true,
                          );

                          if (!context.mounted || selected == null) {
                            return;
                          }

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
                      _buildPublicFilterCategorySelectionCard(
                        title: 'תת קטגוריה',
                        valueText: draftSubCategory ?? '',
                        hintText: 'בחר תת קטגוריה',
                        icon: Icons.subdirectory_arrow_right_rounded,
                        isLight: isLight,
                        onTap: () async {
                          if (draftCategory == null ||
                              draftCategory!.trim().isEmpty) {
                            ScaffoldMessenger.of(this.context).showSnackBar(
                              const SnackBar(
                                content: Text('יש לבחור קטגוריה קודם'),
                              ),
                            );
                            return;
                          }

                          final selected = await _showPublicFilterChoiceDialog(
                            title: draftCategory!,
                            subtitle: 'בחר תת קטגוריה',
                            options:
                                _subCategoryFilterOptionsFor(draftCategory!),
                            selectedValue: draftSubCategory,
                            showPoints: true,
                            showLeadingIcon: false,
                          );

                          if (!context.mounted || selected == null) {
                            return;
                          }

                          setSheetState(() {
                            draftSubCategory = selected;
                          });
                        },
                      ),
                      const SizedBox(height: 12),
                      SwitchListTile.adaptive(
                        value: draftOnlyEligibleByScore,
                        activeThumbColor: const Color(0xFF9E7CFF),
                        title: Text(
                          'רק קבוצות שאני עומד בניקוד שלהן',
                          style: TextStyle(
                              color: isLight ? Colors.black : Colors.white),
                        ),
                        subtitle: Text(
                          'הניקוד שלי: ${_myScoreForPublicFilters ?? 0}',
                          style: TextStyle(
                              color: isLight ? Colors.black87 : Colors.white70),
                        ),
                        onChanged: (value) {
                          setSheetState(() {
                            draftOnlyEligibleByScore = value;
                          });
                        },
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'טווח גילאים: ${draftAgeRange.start.round()}-${draftAgeRange.end.round()}',
                        style: TextStyle(
                          color: isLight ? Colors.black87 : Colors.white70,
                          fontSize: 13,
                        ),
                      ),
                      RangeSlider(
                        values: draftAgeRange,
                        min: minimumUserAge.toDouble(),
                        max: maximumAgeRange.toDouble(),
                        divisions: maximumAgeRange - minimumUserAge,
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
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () async {
                                final picked = await pickDate(draftFromDate);
                                if (picked == null) return;
                                setSheetState(() {
                                  draftFromDate = DateTime(
                                    picked.year,
                                    picked.month,
                                    picked.day,
                                  );
                                });
                              },
                              icon: const Icon(Icons.event_available_rounded,
                                  size: 16),
                              label: Text(
                                draftFromDate == null
                                    ? 'מתאריך'
                                    : '${draftFromDate!.day}/${draftFromDate!.month}/${draftFromDate!.year}',
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () async {
                                final picked = await pickDate(draftToDate);
                                if (picked == null) return;
                                setSheetState(() {
                                  draftToDate = DateTime(
                                    picked.year,
                                    picked.month,
                                    picked.day,
                                    23,
                                    59,
                                    59,
                                  );
                                });
                              },
                              icon: const Icon(Icons.event_rounded, size: 16),
                              label: Text(
                                draftToDate == null
                                    ? 'עד תאריך'
                                    : '${draftToDate!.day}/${draftToDate!.month}/${draftToDate!.year}',
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: TextButton(
                              onPressed: () {
                                setSheetState(() {
                                  draftAgeRange = RangeValues(
                                    minimumUserAge.toDouble(),
                                    maximumAgeRange.toDouble(),
                                  );
                                  draftOnlyEligibleByScore = false;
                                  draftFromDate = null;
                                  draftToDate = null;
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
                                  _publicFilterAgeRange = draftAgeRange;
                                  _publicFilterOnlyEligibleByScore =
                                      draftOnlyEligibleByScore;
                                  _publicFilterFromDate = draftFromDate;
                                  _publicFilterToDate = draftToDate;
                                  _publicFilterCategory = draftCategory;
                                  _publicFilterSubCategory = draftSubCategory;
                                });
                                Navigator.of(sheetContext).pop();
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: isLight
                                    ? Colors.white
                                    : const Color(0xFF9E7CFF),
                                foregroundColor: isLight
                                    ? const Color(0xFF9E7CFF)
                                    : Colors.white,
                                side: isLight
                                    ? const BorderSide(color: Color(0xFFB79BFF))
                                    : BorderSide.none,
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
  }

  List<_PublicFilterChoiceOption> _mainCategoryFilterOptions() {
    return appMainCategories
        .map((category) => category.trim())
        .where((category) => category.isNotEmpty)
        .map(
          (category) => _PublicFilterChoiceOption(
            value: category,
            label: category,
          ),
        )
        .toList(growable: false);
  }

  List<_PublicFilterChoiceOption> _subCategoryFilterOptionsFor(
    String category,
  ) {
    final normalizedCategory = category.trim();
    if (normalizedCategory.isEmpty) {
      return const <_PublicFilterChoiceOption>[];
    }

    return appSubCategories(normalizedCategory)
        .map((subCategory) => subCategory.trim())
        .where((subCategory) => subCategory.isNotEmpty)
        .map(
          (subCategory) => _PublicFilterChoiceOption(
            value: subCategory,
            label: subCategory,
            points: pointsForCategory(
              category: normalizedCategory,
              subCategory: subCategory,
            ),
          ),
        )
        .toList(growable: false);
  }

  Future<String?> _showPublicFilterChoiceDialog({
    required String title,
    required String subtitle,
    required List<_PublicFilterChoiceOption> options,
    String? selectedValue,
    required bool showPoints,
    required bool showLeadingIcon,
  }) {
    final isLight = Theme.of(context).brightness == Brightness.light;

    return showGeneralDialog<String>(
      context: context,
      barrierDismissible: true,
      barrierLabel: title,
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (dialogContext, _, __) {
        final mediaSize = MediaQuery.of(dialogContext).size;
        final dialogWidth =
            mediaSize.width > 680 ? 620.0 : mediaSize.width - 24;

        return Material(
          color: Colors.transparent,
          child: SafeArea(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: dialogWidth,
                    maxHeight: mediaSize.height * 0.82,
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
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                IconButton(
                                  onPressed: () =>
                                      Navigator.of(dialogContext).pop(),
                                  icon: Icon(
                                    Icons.close_rounded,
                                    color: isLight
                                        ? const Color(0xFF33405B)
                                        : Colors.white70,
                                  ),
                                ),
                                Expanded(
                                  child: Column(
                                    children: [
                                      Text(
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
                                      const SizedBox(height: 2),
                                      Text(
                                        subtitle,
                                        textAlign: TextAlign.center,
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
                              child: SingleChildScrollView(
                                physics: const BouncingScrollPhysics(),
                                child: Wrap(
                                  alignment: WrapAlignment.center,
                                  spacing: 14,
                                  runSpacing: 14,
                                  children: options.map((option) {
                                    final isSelected =
                                        option.value == selectedValue;
                                    return Material(
                                      color: Colors.transparent,
                                      child: InkWell(
                                        onTap: () => Navigator.of(dialogContext)
                                            .pop(option.value),
                                        borderRadius:
                                            BorderRadius.circular(999),
                                        child: AnimatedContainer(
                                          duration:
                                              const Duration(milliseconds: 160),
                                          curve: Curves.easeOut,
                                          width: 116,
                                          height: 116,
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
                                            boxShadow: [
                                              BoxShadow(
                                                color: const Color(0xFF76CFFF)
                                                    .withValues(
                                                  alpha:
                                                      isSelected ? 0.42 : 0.32,
                                                ),
                                                blurRadius:
                                                    isSelected ? 18 : 14,
                                                offset: const Offset(0, 7),
                                              ),
                                            ],
                                          ),
                                          child: Stack(
                                            children: [
                                              if (showLeadingIcon)
                                                Positioned(
                                                  top: 16,
                                                  left: 0,
                                                  right: 0,
                                                  child: Icon(
                                                    categoryIconFor(
                                                        option.value),
                                                    color:
                                                        const Color(0xFF2A2361),
                                                    size: 28,
                                                  ),
                                                )
                                              else
                                                const Positioned(
                                                  top: 16,
                                                  left: 0,
                                                  right: 0,
                                                  child: Icon(
                                                    Icons.category_rounded,
                                                    color: Color(0xFF2A2361),
                                                    size: 28,
                                                  ),
                                                ),
                                              if (showPoints &&
                                                  option.points != null)
                                                Positioned(
                                                  top: 10,
                                                  right: 6,
                                                  child: Container(
                                                    padding: const EdgeInsets
                                                        .symmetric(
                                                      horizontal: 8,
                                                      vertical: 4,
                                                    ),
                                                    decoration: BoxDecoration(
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                              999),
                                                      gradient:
                                                          const LinearGradient(
                                                        colors: [
                                                          Color(0xFFFFA24D),
                                                          Color(0xFFFFF6EA),
                                                        ],
                                                        begin:
                                                            Alignment.topLeft,
                                                        end: Alignment
                                                            .bottomRight,
                                                      ),
                                                      border: Border.all(
                                                        color: Colors.white
                                                            .withValues(
                                                                alpha: 0.78),
                                                      ),
                                                      boxShadow: [
                                                        BoxShadow(
                                                          color: const Color(
                                                                  0xFFFFB76A)
                                                              .withValues(
                                                                  alpha: 0.28),
                                                          blurRadius: 10,
                                                          offset: const Offset(
                                                              0, 4),
                                                        ),
                                                      ],
                                                    ),
                                                    child: Text(
                                                      '${option.points}',
                                                      style: const TextStyle(
                                                        color:
                                                            Color(0xFF8C4300),
                                                        fontSize: 10,
                                                        fontWeight:
                                                            FontWeight.w900,
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              Center(
                                                child: Padding(
                                                  padding:
                                                      const EdgeInsets.fromLTRB(
                                                    10,
                                                    52,
                                                    10,
                                                    12,
                                                  ),
                                                  child: Text(
                                                    option.label,
                                                    maxLines: 2,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    textAlign: TextAlign.center,
                                                    style: TextStyle(
                                                      color: const Color(
                                                          0xFF2A2361),
                                                      fontSize:
                                                          isLight ? 12 : 11.8,
                                                      fontWeight:
                                                          FontWeight.w900,
                                                      height: 1.1,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ],
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

  Widget _buildPublicFilterCategorySelectionCard({
    required String title,
    required String valueText,
    required String hintText,
    required IconData icon,
    required bool isLight,
    required VoidCallback onTap,
  }) {
    final hasValue = valueText.trim().isNotEmpty;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(24),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            gradient: const LinearGradient(
              colors: [Color(0xFF8DE8FF), Color(0xFFC9B5FF)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF76CFFF).withValues(alpha: 0.18),
                blurRadius: 16,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          padding: const EdgeInsets.all(1.4),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            decoration: BoxDecoration(
              color:
                  isLight ? const Color(0xFFF8FBFF) : const Color(0xFF101826),
              borderRadius: BorderRadius.circular(22),
            ),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const LinearGradient(
                      colors: [Color(0xFF8DE8FF), Color(0xFFC9B5FF)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.74),
                    ),
                  ),
                  child: Icon(icon, color: const Color(0xFF2A2361), size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          color: isLight ? Colors.black54 : Colors.white70,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        hasValue ? valueText : hintText,
                        style: TextStyle(
                          color: hasValue
                              ? (isLight ? Colors.black : Colors.white)
                              : (isLight ? Colors.black54 : Colors.white70),
                          fontSize: 15,
                          fontWeight:
                              hasValue ? FontWeight.w900 : FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  Icons.chevron_left_rounded,
                  color: isLight ? Colors.black54 : Colors.white70,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRequestsList() {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) {
      return _buildCenteredMessage('יש להתחבר כדי לצפות בקבוצות');
    }
    _ensureStableChatStreams(currentUser.uid);

    return StreamBuilder<List<QueryDocumentSnapshot<Map<String, dynamic>>>>(
      stream: _userChatsStream,
      initialData: _lastUserChatsDocs ?? const <QueryDocumentSnapshot<Map<String, dynamic>>>[],
      builder: (context, chatSnapshot) {
        if (chatSnapshot.connectionState == ConnectionState.waiting &&
            !chatSnapshot.hasData) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 40),
            child: Center(child: CircularProgressIndicator()),
          );
        }

        if (chatSnapshot.hasError) {
          return _buildCenteredMessage('אין עדיין קבוצות');
        }

        final docs = chatSnapshot.data ??
            const <QueryDocumentSnapshot<Map<String, dynamic>>>[];
    _lastUserChatsDocs = docs;
        final groupDocs = docs
            .where((doc) => !_isDirectChat(doc.data()))
            .toList(growable: false);
        final filteredDocs = _filterAndSortChats(groupDocs);
        return FutureBuilder<List<QueryDocumentSnapshot<Map<String, dynamic>>>>(
          future: _filterApprovedGroupChats(
            groupDocs: filteredDocs,
            currentUid: currentUser.uid,
          ),
          builder: (context, approvedSnapshot) {
            if (approvedSnapshot.connectionState != ConnectionState.done &&
                !approvedSnapshot.hasData) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(child: CircularProgressIndicator()),
              );
            }

            if (approvedSnapshot.hasError) {
              return _buildCenteredMessage('אין עדיין קבוצות');
            }

            final approvedDocs = approvedSnapshot.data ??
                const <QueryDocumentSnapshot<Map<String, dynamic>>>[];
            if (approvedDocs.isEmpty) {
              return _buildCenteredMessage('אין עדיין קבוצות');
            }

            final chatIds =
                approvedDocs.map((doc) => doc.id).toList(growable: false);

            return StreamBuilder<Map<String, DateTime?>>(
              stream: _chatService.streamMyReadReceipts(
                userId: currentUser.uid,
                chatIds: chatIds,
              ),
              builder: (context, readSnapshot) {
                if (readSnapshot.hasError) {
                  return _buildCenteredMessage('אין עדיין קבוצות');
                }
                final readReceipts =
                    readSnapshot.data ?? const <String, DateTime?>{};

                return ListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: approvedDocs.length,
                  itemBuilder: (context, index) {
                    final chatDoc = approvedDocs[index];
                final chatData = chatDoc.data();
                final chatName =
                    ((chatData['name'] as String?) ?? 'קבוצה').trim();
                final imageUrl =
                    ((chatData['groupImageUrl'] as String?) ?? '').trim();
                final description =
                    ((chatData['description'] as String?) ?? '').trim();
                final lastMessage =
                    ((chatData['lastMessage'] as String?) ?? '').trim();
                final lastMessageSenderName =
                    ((chatData['lastMessageSenderName'] as String?) ?? '')
                        .trim();
                final activityDate = _chatActivityDate(chatData);
                final lastReadAt = readReceipts[chatDoc.id];
                final hasUnread = _hasUnreadMessages(
                  lastMessageAt:
                      _timestampToDate(chatData['lastMessageAt'] as Timestamp?),
                  lastReadAt: lastReadAt,
                );

                final subtitleText = lastMessage.isNotEmpty
                    ? (lastMessageSenderName.isNotEmpty
                        ? '$lastMessageSenderName: $lastMessage'
                        : lastMessage)
                    : (description.isEmpty ? 'קבוצה פעילה' : description);

                final tile = Container(
                  decoration: BoxDecoration(
                    color: isLight
                        ? Colors.white.withValues(alpha: 0.62)
                        : const Color(0xFF1E2632),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Material(
                    type: MaterialType.transparency,
                    child: ListTile(
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => ChatRoomScreen(
                              chatName: chatName,
                              avatarUrl: imageUrl.isEmpty ? null : imageUrl,
                              chatId: chatDoc.id,
                              isDirectChat: false,
                            ),
                          ),
                        );
                      },
                      leading: _buildLiveGroupAvatar(
                        groupId: chatDoc.id,
                        fallbackImageUrl: imageUrl,
                      ),
                      title: Text(
                        chatName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: 'Segoe UI',
                          color: isLight ? Colors.black : Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      subtitle: Text(
                        subtitleText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: isLight ? Colors.black87 : Colors.grey[400],
                        ),
                      ),
                      trailing: SizedBox(
                        height: double.infinity,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.start,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            SizedBox(
                              width: 92,
                              child: Text(
                                _formatRelativeTime(activityDate),
                                textAlign: TextAlign.end,
                                style: TextStyle(
                                  color: isLight
                                      ? Colors.black54
                                      : Colors.grey[500],
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );

                return Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: _buildChatFrame(
                    child: tile,
                    hasUnread: hasUnread,
                  ),
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

  Widget _buildPublicGroupBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF1D3150), Color(0xFF2A5B8F)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(999),
        border:
            Border.all(color: const Color(0xFF53C1F9).withValues(alpha: 0.7)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x3346D3FF),
            blurRadius: 10,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.public_rounded, size: 12, color: Color(0xFFDDF4FF)),
          SizedBox(width: 4),
          Text(
            'ציבורית',
            style: TextStyle(
              fontFamily: 'Segoe UI',
              color: Color(0xFFDDF4FF),
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGroupsTabNotificationDot({required bool isLight}) {
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: isLight
              ? const [Color(0xFF9EEBFF), Color(0xFFC9B7FF)]
              : const [Color(0xFF53C1F9), Color(0xFF9E7CFF)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [
          BoxShadow(
            color: (isLight ? const Color(0xFF53C1F9) : const Color(0xFF9E7CFF))
                .withValues(alpha: 0.5),
            blurRadius: 8,
            spreadRadius: 0.6,
          ),
        ],
      ),
    );
  }

  Widget _buildMinScoreBadge(int minScore) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF3A1218),
        borderRadius: BorderRadius.circular(999),
        border:
            Border.all(color: const Color(0xFFFF6A8F).withValues(alpha: 0.8)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.local_fire_department_rounded,
              size: 12, color: Color(0xFFFFA1B8)),
          const SizedBox(width: 4),
          Text(
            'מינימום $minScore',
            style: const TextStyle(
              fontFamily: 'Segoe UI',
              color: Color(0xFFFFD6E1),
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChatFrame({
    required Widget child,
    required bool hasUnread,
  }) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final frameThickness = hasUnread ? 2.8 : 1.4;

    return Container(
      padding: EdgeInsets.all(frameThickness),
      decoration: BoxDecoration(
        gradient: isLight
            ? null
            : const LinearGradient(
                colors: [Color(0xFF4FC3F7), Color(0xFF9E7CFF)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
        color: isLight ? const Color(0xFFA9C3FF).withValues(alpha: 0.8) : null,
        borderRadius: BorderRadius.circular(17),
      ),
      child: child,
    );
  }

  Widget _buildChatsLoadingSkeleton() {
    return ListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: 5,
      itemBuilder: (context, index) {
        return const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: _ChatLoadingTile(),
        );
      },
    );
  }

  bool _hasUnreadMessages(
      {required DateTime? lastMessageAt, required DateTime? lastReadAt}) {
    if (lastMessageAt == null) {
      return false;
    }
    if (lastReadAt == null) {
      return true;
    }
    return lastMessageAt.isAfter(lastReadAt);
  }

  DateTime? _chatActivityDate(Map<String, dynamic> data) {
    return _timestampToDate(data['lastMessageAt'] as Timestamp?) ??
        _timestampToDate(data['updatedAt'] as Timestamp?) ??
        _timestampToDate(data['createdAt'] as Timestamp?);
  }

  DateTime? _timestampToDate(Timestamp? timestamp) {
    return timestamp?.toDate();
  }

  bool _isDirectChat(Map<String, dynamic> data) {
    final isPublic = (data['isPublic'] as bool?) ?? false;
    final participants = List<String>.from(
      (data['participants'] as List<dynamic>?) ?? const <String>[],
    );
    return (data['isDirect'] as bool?) ??
        (!isPublic && participants.length == 2);
  }

  Future<List<_GlobalSearchResult>> _globalSearchResults(String query) {
    final normalizedQuery = query.trim().toLowerCase();
    if (normalizedQuery.isEmpty) {
      return Future.value(const <_GlobalSearchResult>[]);
    }

    return _globalSearchCache.putIfAbsent(normalizedQuery, () async {
      final currentUid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
      final blockedUids = await _blockUserService.fetchBlockedConnections();
      final usersFuture = FirebaseFirestore.instance
          .collection('users_public')
          .limit(250)
          .get();
      final groupsFuture = FirebaseFirestore.instance
          .collection('groups')
          .where('isPublic', isEqualTo: true)
          .limit(250)
          .get();

      final results = await Future.wait<dynamic>([usersFuture, groupsFuture]);
      final usersSnapshot = results[0] as QuerySnapshot<Map<String, dynamic>>;
      final groupsSnapshot = results[1] as QuerySnapshot<Map<String, dynamic>>;

      final userResults = <_GlobalSearchResult>[];
      for (final doc in usersSnapshot.docs) {
        final data = doc.data();
        final uid = doc.id.trim();
        if (uid.isEmpty || uid == currentUid) {
          continue;
        }
        if (blockedUids.contains(uid)) {
          continue;
        }

        final displayName = ((data['displayName'] as String?) ?? '').trim();
        final username = ((data['username'] as String?) ?? '').trim();
        final searchHaystack =
            '$displayName $username ${uid.toLowerCase()}'.toLowerCase();
        if (!searchHaystack.contains(normalizedQuery)) {
          continue;
        }

        userResults.add(
          _GlobalSearchResult(
            id: uid,
            name: displayName.isNotEmpty
                ? displayName
                : (username.isNotEmpty ? username : uid),
            subtitle: username.isNotEmpty
                ? (username.startsWith('@') ? username : '@$username')
                : uid,
            imageUrl: ((data['profilePictureUrl'] as String?) ?? '').trim(),
            isGroup: false,
            isMember: false,
          ),
        );
      }

      final groupResults = <_GlobalSearchResult>[];
      for (final doc in groupsSnapshot.docs) {
        final data = doc.data();
        final isPublic = (data['isPublic'] as bool?) ?? false;
        final isDeleted = (data['isDeleted'] as bool?) ?? false;
        final deletedAt = data['deletedAt'];
        final isArchived = (data['isArchived'] as bool?) ?? false;
        final status = ((data['status'] as String?) ?? '').trim().toLowerCase();
        final isActive = (data['isActive'] as bool?) ?? true;
        final isVisible = (data['isVisible'] as bool?) ?? true;

        final hiddenByStatus = status == 'deleted' ||
            status == 'removed' ||
            status == 'archived' ||
            status == 'inactive';

        if (!isPublic ||
            isDeleted ||
            isArchived ||
            !isActive ||
            !isVisible ||
            hiddenByStatus ||
            deletedAt != null) {
          continue;
        }

        final groupName = ((data['groupName'] as String?) ?? '').trim();
        final description = ((data['description'] as String?) ?? '').trim();
        final category = ((data['category'] as String?) ?? '').trim();
        final subCategory = ((data['subCategory'] as String?) ?? '').trim();
        final membersRaw = (data['members'] as List<dynamic>?) ??
            (data['membersList'] as List<dynamic>?) ??
            const <dynamic>[];
        final memberIds = membersRaw
            .map((item) => item.toString().trim())
            .where((value) => value.isNotEmpty)
            .toSet();

        final searchHaystack =
            '$groupName $description $category $subCategory'.toLowerCase();
        if (!searchHaystack.contains(normalizedQuery)) {
          continue;
        }

        final subtitle = subCategory.isEmpty
            ? (category.isEmpty ? 'קבוצה' : category)
            : '$category • $subCategory';

        groupResults.add(
          _GlobalSearchResult(
            id: doc.id,
            name: groupName.isEmpty ? 'קבוצה' : groupName,
            subtitle: subtitle,
            imageUrl: ((data['groupImageUrl'] as String?) ?? '').trim(),
            isGroup: true,
            isMember: currentUid.isNotEmpty && memberIds.contains(currentUid),
          ),
        );
      }

      int scoreName(_GlobalSearchResult result) {
        return result.name.toLowerCase().startsWith(normalizedQuery) ? 0 : 1;
      }

      userResults.sort((a, b) {
        final cmp = scoreName(a).compareTo(scoreName(b));
        if (cmp != 0) return cmp;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      groupResults.sort((a, b) {
        final cmp = scoreName(a).compareTo(scoreName(b));
        if (cmp != 0) return cmp;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });

      return <_GlobalSearchResult>[
        ...userResults.take(12),
        ...groupResults.take(12),
      ];
    });
  }

  Widget _buildGlobalSearchResultsPanel() {
    final isLight = Theme.of(context).brightness == Brightness.light;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Container(
        decoration: BoxDecoration(
          color: isLight
              ? Colors.white.withValues(alpha: 0.62)
              : const Color(0xFF1E2632),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: isLight
                ? const Color(0xFFA9C3FF)
                : const Color(0xFF53C1F9).withValues(alpha: 0.25),
          ),
        ),
        child: FutureBuilder<List<_GlobalSearchResult>>(
          future: _globalSearchResults(searchQuery),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting &&
                !snapshot.hasData) {
              return const Padding(
                padding: EdgeInsets.all(14),
                child: Center(child: CircularProgressIndicator()),
              );
            }

            final results = snapshot.data ?? const <_GlobalSearchResult>[];
            if (results.isEmpty) {
              return Padding(
                padding: const EdgeInsets.all(14),
                child: Text(
                  'לא נמצאו משתמשים או קבוצות לחיפוש',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: isLight ? Colors.black87 : Colors.grey[400],
                    fontSize: 13,
                  ),
                ),
              );
            }

            return ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: results.length,
              separatorBuilder: (_, __) => Divider(
                color: isLight ? Colors.black12 : Colors.white10,
                height: 1,
                indent: 14,
                endIndent: 14,
              ),
              itemBuilder: (context, index) {
                final result = results[index];
                return ListTile(
                  onTap: () {
                    if (result.isGroup) {
                      if (result.isMember) {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => ChatRoomScreen(
                              chatName: result.name,
                              avatarUrl: result.imageUrl.isEmpty
                                  ? null
                                  : result.imageUrl,
                              chatId: result.id,
                              isDirectChat: false,
                            ),
                          ),
                        );
                        return;
                      }

                      setState(() {
                        _selectedChatsTabIndex = 2;
                        _searchController.text = result.name;
                        searchQuery = result.name;
                      });
                      return;
                    }

                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => UserProfileScreen(
                          uid: result.id,
                          currentBottomIndex: 3,
                        ),
                      ),
                    );
                  },
                  leading: CircleAvatar(
                    backgroundColor: result.isGroup
                        ? const Color(0xFF53C1F9)
                        : const Color(0xFF9E7CFF),
                    backgroundImage: result.imageUrl.isNotEmpty
                        ? NetworkImage(result.imageUrl)
                        : null,
                    child: result.imageUrl.isEmpty
                        ? Icon(
                            result.isGroup
                                ? Icons.groups_rounded
                                : Icons.person_rounded,
                            color: Colors.white,
                          )
                        : null,
                  ),
                  title: Text(
                    result.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isLight ? Colors.black : Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  subtitle: Text(
                    result.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Colors.grey[400]),
                  ),
                  trailing: Text(
                    result.isGroup ? 'קבוצה' : 'משתמש',
                    style: TextStyle(
                      color: isLight
                          ? const Color(0xFF9AB0FF)
                          : const Color(0xFF9EDBFF),
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }

  String _formatRelativeTime(DateTime? dateTime) {
    if (dateTime == null) {
      return '';
    }

    final now = DateTime.now();
    final difference = now.difference(dateTime);

    if (difference.isNegative) {
      return 'כרגע';
    }

    if (difference.inSeconds < 60) {
      return 'כרגע';
    }
    if (difference.inMinutes < 60) {
      return 'לפני ${difference.inMinutes} דקות';
    }
    if (difference.inHours < 24) {
      return 'לפני ${difference.inHours} שעות';
    }
    if (difference.inDays < 7) {
      return 'לפני ${difference.inDays} ימים';
    }

    final day = dateTime.day.toString().padLeft(2, '0');
    final month = dateTime.month.toString().padLeft(2, '0');
    final year = dateTime.year.toString();
    return '$day/$month/$year';
  }

  Widget _buildCenteredMessage(String message) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Center(
        child: Text(
          message,
          style: TextStyle(
            color: isLight ? Colors.black54 : Colors.grey[500],
            fontSize: 16,
          ),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }

  Widget _buildErrorState(String message) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Center(
        child: Text(
          message,
          style: TextStyle(
            color: isLight ? Colors.black54 : Colors.grey[500],
            fontSize: 14,
          ),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }

  Widget _buildPublicGroupsEmptyState(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.groups_rounded,
              size: 40,
              color:
                  isLight ? const Color(0xFF9AB0FF) : const Color(0xFF9E7CFF),
            ),
            const SizedBox(height: 12),
            Text(
              'אין קבוצות ציבוריות - צור אחת!',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: isLight ? Colors.black87 : Colors.grey[300],
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: () {
                final navigator = Navigator.of(context);
                try {
                  navigator.pushNamed('/create-group');
                } catch (_) {
                  navigator.push(
                    MaterialPageRoute(
                        builder: (_) => const CreateGroupScreen()),
                  );
                }
              },
              icon: const Icon(Icons.add_rounded),
              label: const Text('צור קבוצה'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF9E7CFF),
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChatLoadingTile extends StatelessWidget {
  const _ChatLoadingTile();

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final baseColor =
        isLight ? const Color(0xFFE8EEF8) : const Color(0xFF1E2632);
    final lineColor =
        isLight ? const Color(0xFFD7E1F1) : const Color(0xFF2B3545);

    return Container(
      decoration: BoxDecoration(
        color: baseColor,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: ListTile(
          leading: CircleAvatar(
            radius: 28,
            backgroundColor: lineColor,
          ),
          title: Align(
            alignment: Alignment.centerLeft,
            child: Container(
              width: 132,
              height: 12,
              decoration: BoxDecoration(
                color: lineColor,
                borderRadius: BorderRadius.circular(6),
              ),
            ),
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Container(
                width: 188,
                height: 10,
                decoration: BoxDecoration(
                  color: lineColor,
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
