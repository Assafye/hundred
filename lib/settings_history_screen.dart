import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'app_categories.dart';
import 'chat_room_screen.dart';
import 'post_media_utils.dart';
import 'post_detail_view.dart';
import 'services/app_home_service.dart';
import 'services/geohash_utils.dart';
import 'services/keyboard_dismiss_controller.dart';
import 'widgets/post_media_viewer.dart';
import 'widgets/swipe_back_wrapper.dart';

class _MeetHistoryPopItem {
  const _MeetHistoryPopItem({
    required this.id,
    required this.data,
  });

  final String id;
  final Map<String, dynamic> data;

  DateTime? get createdAt {
    final raw = data['createdAt'];
    if (raw is Timestamp) return raw.toDate();
    if (raw is DateTime) return raw;
    return null;
  }

  bool get isActive {
    final status = (data['status'] as String? ?? '').trim().toLowerCase();
    return status != 'deleted';
  }
}

class SettingsHistoryScreen extends StatefulWidget {
  const SettingsHistoryScreen({super.key});

  @override
  State<SettingsHistoryScreen> createState() => _SettingsHistoryScreenState();
}

class _SettingsHistoryScreenState extends State<SettingsHistoryScreen>
    with SingleTickerProviderStateMixin {
  static const Color _bgTop = Color(0xFF10162A);
  static const Color _bgBottom = Color(0xFF0B1019);
  static const Color _card = Color(0xFF162238);
  static const Color _accentCyan = Color(0xFF53C1F9);
  static const Color _accentPurple = Color(0xFF9E7CFF);

  late final TabController _tabController;
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final Map<String, Future<Map<String, dynamic>>> _activityPreviewFutureByKey =
      <String, Future<Map<String, dynamic>>>{};
  final Map<String, Future<String>> _authorLabelFutureByUid =
      <String, Future<String>>{};
  bool _showAllCreatedPops = false;
  bool _showAllJoinedPops = false;

  String get _uid => FirebaseAuth.instance.currentUser?.uid.trim() ?? '';

  @override
  void initState() {
    super.initState();
    KeyboardDismissController.suspend();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    KeyboardDismissController.resume();
    _tabController.dispose();
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

  Stream<List<QueryDocumentSnapshot<Map<String, dynamic>>>> _activityStream() {
    if (_uid.isEmpty) {
      return const Stream<
          List<QueryDocumentSnapshot<Map<String, dynamic>>>>.empty();
    }

    return _db
        .collection('users')
        .doc(_uid)
        .collection('activity')
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) => snapshot.docs.toList(growable: false));
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> _meetNowHistoryStream() {
    if (_uid.isEmpty) {
      return const Stream<QuerySnapshot<Map<String, dynamic>>>.empty();
    }

    return _db
        .collection('meet_now_posts')
        .where('authorUid', isEqualTo: _uid)
        .snapshots();
  }

  Stream<Set<String>> _joinedGroupIdsStream() {
    if (_uid.isEmpty) {
      return Stream.value(const <String>{});
    }

    return _db
        .collectionGroup('members')
        .where('uid', isEqualTo: _uid)
        .where('status', isEqualTo: 'approved')
        .snapshots()
        .map((snapshot) {
      final ids = <String>{};
      for (final doc in snapshot.docs) {
        final groupId = doc.reference.parent.parent?.id ?? '';
        if (groupId.trim().isNotEmpty) {
          ids.add(groupId.trim());
        }
      }
      return ids;
    });
  }

  Stream<List<_MeetHistoryPopItem>> _joinedMeetNowHistoryStream() {
    if (_uid.isEmpty) {
      return Stream.value(const <_MeetHistoryPopItem>[]);
    }

    return Stream.multi((controller) {
      Set<String> joinedGroupIds = <String>{};
      Map<String, String> joinedPopGroupIdByPostId = <String, String>{};
      QuerySnapshot<Map<String, dynamic>>? postsSnapshot;
      QuerySnapshot<Map<String, dynamic>>? joinedActivitySnapshot;
      StreamSubscription<Set<String>>? groupsSub;
      StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? postsSub;
      StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? activitySub;

      void emitJoined() {
        if (postsSnapshot == null && joinedActivitySnapshot == null) {
          return;
        }

        final itemsByPostId = <String, _MeetHistoryPopItem>{};
        final postsById = <String, Map<String, dynamic>>{};

        for (final doc in postsSnapshot?.docs ??
            const <QueryDocumentSnapshot<Map<String, dynamic>>>[]) {
          final data = doc.data();
          postsById[doc.id] = data;

          final linkedGroupId = (data['linkedGroupId'] as String? ?? '').trim();
          final joinedByLinkedGroup = linkedGroupId.isNotEmpty &&
              joinedGroupIds.contains(linkedGroupId);
          final joinedByOriginGroup =
              joinedPopGroupIdByPostId.containsKey(doc.id);
          if (!joinedByLinkedGroup && !joinedByOriginGroup) {
            continue;
          }

          final effectiveLinkedGroupId = linkedGroupId.isNotEmpty
              ? linkedGroupId
              : (joinedPopGroupIdByPostId[doc.id] ?? '');
          final effectiveData =
              effectiveLinkedGroupId.isNotEmpty && linkedGroupId.isEmpty
                  ? <String, dynamic>{
                      ...data,
                      'linkedGroupId': effectiveLinkedGroupId,
                    }
                  : data;

          final authorUid =
              (effectiveData['authorUid'] as String? ?? '').trim();
          if (authorUid == _uid) {
            continue;
          }

          final status =
              (effectiveData['status'] as String? ?? '').trim().toLowerCase();
          if (status == 'deleted') {
            continue;
          }

          final item = _MeetHistoryPopItem(id: doc.id, data: effectiveData);
          if (!_withinHistoryWindow(item.createdAt)) {
            continue;
          }

          itemsByPostId[doc.id] = item;
        }

        for (final activityDoc in joinedActivitySnapshot?.docs ??
            const <QueryDocumentSnapshot<Map<String, dynamic>>>[]) {
          final activityData = activityDoc.data();
          final postId = (activityData['postId'] as String? ?? '').trim();
          if (postId.isEmpty) {
            continue;
          }

          final postData = postsById[postId];
          final fallbackGroupId = joinedPopGroupIdByPostId[postId] ?? '';
          final activityTime = activityData['joinedAt'] ??
              activityData['createdAt'] ??
              activityData['serverJoinedAt'] ??
              activityData['serverCreatedAt'];
          final effectiveData = postData ??
              <String, dynamic>{
                'authorUid':
                    (activityData['authorUid'] as String? ?? '').trim(),
                'title': (activityData['title'] as String? ?? '').trim(),
                'details':
                    (activityData['description'] as String? ?? '').trim(),
                'category': (activityData['category'] as String? ?? '').trim(),
                'subCategory':
                    (activityData['subCategory'] as String? ?? '').trim(),
                'meetingLocation':
                    (activityData['meetingLocation'] as String? ?? '').trim(),
                'timePreference':
                    (activityData['timePreference'] as String? ?? '').trim(),
                'desiredParticipants': activityData['desiredParticipants'],
                'minAge': activityData['minAge'],
                'maxAge': activityData['maxAge'],
                'linkedGroupId':
                    (activityData['linkedGroupId'] as String? ?? '').trim(),
                'status': 'active',
                'createdAt': activityTime,
              };
          final activityLinkedGroupId =
              (effectiveData['linkedGroupId'] as String? ?? '').trim();
          final normalizedData =
              activityLinkedGroupId.isNotEmpty || fallbackGroupId.isEmpty
                  ? effectiveData
                  : <String, dynamic>{
                      ...effectiveData,
                      'linkedGroupId': fallbackGroupId,
                    };

          final authorUid =
              (normalizedData['authorUid'] as String? ?? '').trim();
          if (authorUid == _uid) {
            continue;
          }

          final item = _MeetHistoryPopItem(id: postId, data: normalizedData);
          if (!_withinHistoryWindow(item.createdAt)) {
            continue;
          }

          itemsByPostId[postId] = item;
        }

        final items = itemsByPostId.values.toList(growable: false);
        items.sort((a, b) {
          final aTime = a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
          final bTime = b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
          return bTime.compareTo(aTime);
        });

        controller.add(items);
      }

      Future<void> refreshJoinedPopPostIdsFromGroups() async {
        if (joinedGroupIds.isEmpty) {
          joinedPopGroupIdByPostId = <String, String>{};
          emitJoined();
          return;
        }

        final groupDocFutures = joinedGroupIds
            .map((groupId) => _db.collection('groups').doc(groupId).get())
            .toList(growable: false);
        final groupDocs = await Future.wait(groupDocFutures);

        final postIdToGroupId = <String, String>{};
        for (final groupDoc in groupDocs) {
          final data = groupDoc.data() ?? <String, dynamic>{};
          final originType =
              (data['originType'] as String? ?? '').trim().toLowerCase();
          final originMeetPostId =
              (data['originMeetPostId'] as String? ?? '').trim();
          if (originType == 'pop' && originMeetPostId.isNotEmpty) {
            postIdToGroupId[originMeetPostId] = groupDoc.id;
          }
        }

        joinedPopGroupIdByPostId = postIdToGroupId;
        emitJoined();
      }

      groupsSub = _joinedGroupIdsStream().listen((ids) {
        joinedGroupIds = ids;
        unawaited(refreshJoinedPopPostIdsFromGroups());
        emitJoined();
      }, onError: controller.addError);

      postsSub = _db
          .collection('meet_now_posts')
          .orderBy('createdAt', descending: true)
          .limit(350)
          .snapshots()
          .listen((snapshot) {
        postsSnapshot = snapshot;
        emitJoined();
      }, onError: controller.addError);

      activitySub = _db
          .collection('users')
          .doc(_uid)
          .collection('activity')
          .where('type', isEqualTo: 'pop_join')
          .snapshots()
          .listen((snapshot) {
        joinedActivitySnapshot = snapshot;
        emitJoined();
      }, onError: controller.addError);

      controller.onCancel = () async {
        await groupsSub?.cancel();
        await postsSub?.cancel();
        await activitySub?.cancel();
      };
    });
  }

  List<String> _extractImageUrlsFromUserData(Map<String, dynamic> data) {
    final urls = <String>[];
    final seen = <String>{};

    void addUrl(String raw) {
      final url = raw.trim();
      if (url.isEmpty) return;
      if (!(url.startsWith('http://') || url.startsWith('https://'))) return;
      if (!seen.add(url)) return;
      urls.add(url);
    }

    for (final key in const [
      'profilePictureUrl',
      'profileImageUrl',
      'avatarUrl'
    ]) {
      addUrl((data[key] as String? ?? ''));
    }

    for (final key in const ['profileImageUrls', 'images']) {
      final list = data[key];
      if (list is! List) continue;
      for (final item in list) {
        addUrl(item.toString());
      }
    }

    return urls;
  }

  Future<Map<String, dynamic>> _mergedUserData(String uid) async {
    final publicDoc = await _db.collection('users_public').doc(uid).get();
    DocumentSnapshot<Map<String, dynamic>>? privateDoc;
    try {
      privateDoc = await _db.collection('users').doc(uid).get();
    } catch (_) {
      privateDoc = null;
    }
    return <String, dynamic>{
      ...?(privateDoc?.data()),
      ...?publicDoc.data(),
    };
  }

  Future<List<String>> _meetNowImageUrls(Map<String, dynamic> data) async {
    final urls = <String>[];
    final seen = <String>{};

    void addAll(List<String> list) {
      for (final url in list) {
        if (seen.add(url)) {
          urls.add(url);
        }
      }
    }

    final authorUid = (data['authorUid'] as String? ?? '').trim();
    if (authorUid.isNotEmpty) {
      final authorData = await _mergedUserData(authorUid);
      addAll(_extractImageUrlsFromUserData(authorData));
    }

    final linkedGroupId = (data['linkedGroupId'] as String? ?? '').trim();
    if (linkedGroupId.isNotEmpty) {
      final members = await _db
          .collection('groups')
          .doc(linkedGroupId)
          .collection('members')
          .where('status', isEqualTo: 'approved')
          .limit(12)
          .get();

      final memberUids = members.docs
          .map((doc) => (doc.data()['uid'] as String? ?? doc.id).trim())
          .where((uid) => uid.isNotEmpty && uid != authorUid)
          .toList(growable: false);

      final memberDataList = await Future.wait(
        memberUids.map(_mergedUserData),
      );

      for (final userData in memberDataList) {
        addAll(_extractImageUrlsFromUserData(userData));
      }
    }

    return urls;
  }

  bool _withinEditWindow(DateTime? createdAt) {
    if (createdAt == null) return false;
    return DateTime.now().difference(createdAt) < const Duration(hours: 24);
  }

  bool _withinHistoryWindow(DateTime? createdAt) {
    if (createdAt == null) return false;
    return DateTime.now().difference(createdAt) <= const Duration(days: 30);
  }

  Future<void> _editMeetNowPost(
      DocumentSnapshot<Map<String, dynamic>> doc) async {
    final data = doc.data() ?? <String, dynamic>{};
    final titleController =
        TextEditingController(text: (data['title'] as String? ?? '').trim());
    final detailsController = TextEditingController(
        text:
            (data['details'] as String? ?? data['description'] as String? ?? '')
                .trim());
    final participantsController = TextEditingController(
      text: (data['desiredParticipants'] as num?)?.toInt().toString() ?? '',
    );

    final existingCategory = (data['category'] as String? ?? '').trim();
    final existingSubCategory = (data['subCategory'] as String? ?? '').trim();
    String? selectedCategory =
        existingCategory.isEmpty ? null : existingCategory;
    String? selectedSubCategory =
        existingSubCategory.isEmpty ? null : existingSubCategory;
    String timePreference =
        (data['timePreference'] as String? ?? 'עכשיו').trim().isEmpty
            ? 'עכשיו'
            : (data['timePreference'] as String? ?? 'עכשיו').trim();
    bool useAgeRange = data['minAge'] is num && data['maxAge'] is num;
    RangeValues ageRange = RangeValues(
      ((data['minAge'] as num?)?.toDouble() ?? 13).clamp(13, 99).toDouble(),
      ((data['maxAge'] as num?)?.toDouble() ?? 99).clamp(13, 99).toDouble(),
    );

    final shouldSave = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final subCategoryOptions = appSubCategories(selectedCategory)
                .where((item) => item.trim().isNotEmpty)
                .toList(growable: false);

            return Directionality(
              textDirection: TextDirection.rtl,
              child: AlertDialog(
                backgroundColor: const Color(0xFF1A2435),
                title: const Text(
                  'עריכת פופ אונליין',
                  style: TextStyle(color: Colors.white),
                ),
                content: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextField(
                        controller: titleController,
                        onTapOutside: (_) {},
                        textAlign: TextAlign.right,
                        decoration: const InputDecoration(hintText: 'כותרת'),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: detailsController,
                        onTapOutside: (_) {},
                        textAlign: TextAlign.right,
                        maxLines: 3,
                        decoration: const InputDecoration(hintText: 'תיאור'),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: participantsController,
                        onTapOutside: (_) {},
                        keyboardType: TextInputType.number,
                        textAlign: TextAlign.right,
                        decoration: const InputDecoration(
                            hintText: 'כמות משתתפים רצויה'),
                      ),
                      const SizedBox(height: 10),
                      DropdownButtonFormField<String>(
                        initialValue: selectedCategory,
                        decoration: const InputDecoration(labelText: 'קטגוריה'),
                        items: [
                          const DropdownMenuItem<String>(
                            value: null,
                            child: Text('ללא קטגוריה'),
                          ),
                          ...appMainCategories.map(
                            (item) => DropdownMenuItem<String>(
                              value: item,
                              child: Text(item),
                            ),
                          ),
                        ],
                        onChanged: (value) {
                          setDialogState(() {
                            selectedCategory = value;
                            if (!appSubCategories(value)
                                .contains(selectedSubCategory)) {
                              selectedSubCategory = null;
                            }
                          });
                        },
                      ),
                      const SizedBox(height: 10),
                      DropdownButtonFormField<String>(
                        initialValue: selectedSubCategory,
                        decoration:
                            const InputDecoration(labelText: 'תת קטגוריה'),
                        items: [
                          const DropdownMenuItem<String>(
                            value: null,
                            child: Text('ללא תת קטגוריה'),
                          ),
                          ...subCategoryOptions.map(
                            (item) => DropdownMenuItem<String>(
                              value: item,
                              child: Text(item),
                            ),
                          ),
                        ],
                        onChanged: (value) {
                          setDialogState(() {
                            selectedSubCategory = value;
                          });
                        },
                      ),
                      const SizedBox(height: 10),
                      DropdownButtonFormField<String>(
                        initialValue: timePreference,
                        decoration:
                            const InputDecoration(labelText: 'זמן למפגש'),
                        items: const [
                          DropdownMenuItem(
                              value: 'עכשיו', child: Text('עכשיו')),
                          DropdownMenuItem(
                              value: 'עוד מעט', child: Text('עוד מעט')),
                          DropdownMenuItem(value: 'בערב', child: Text('בערב')),
                          DropdownMenuItem(value: 'מחר', child: Text('מחר')),
                          DropdownMenuItem(
                              value: 'שבוע הבא', child: Text('שבוע הבא')),
                          DropdownMenuItem(
                              value: 'לא אכפת לי מתי',
                              child: Text('לא אכפת לי מתי')),
                        ],
                        onChanged: (value) {
                          setDialogState(() {
                            timePreference = value ?? 'עכשיו';
                          });
                        },
                      ),
                      const SizedBox(height: 10),
                      SwitchListTile.adaptive(
                        value: useAgeRange,
                        contentPadding: EdgeInsets.zero,
                        title: const Text('להוסיף טווח גילאים'),
                        onChanged: (value) {
                          setDialogState(() {
                            useAgeRange = value;
                          });
                        },
                      ),
                      if (useAgeRange) ...[
                        Text(
                          'גילאים: ${ageRange.start.round()}-${ageRange.end.round()}',
                        ),
                        RangeSlider(
                          values: ageRange,
                          min: 13,
                          max: 99,
                          divisions: 86,
                          labels: RangeLabels(
                            '${ageRange.start.round()}',
                            '${ageRange.end.round()}',
                          ),
                          onChanged: (value) {
                            setDialogState(() {
                              ageRange = value;
                            });
                          },
                        ),
                      ],
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () async {
                      final shouldDelete = await showDialog<bool>(
                            context: dialogContext,
                            builder: (confirmContext) {
                              return Directionality(
                                textDirection: TextDirection.rtl,
                                child: AlertDialog(
                                  backgroundColor: const Color(0xFF1A2435),
                                  title: const Text(
                                    'מחיקת פופ',
                                    style: TextStyle(color: Colors.white),
                                  ),
                                  content: const Text(
                                    'הפופ יימחק לצמיתות ולא יוצג יותר לך ולמשתמשים אחרים. להמשיך?',
                                    style: TextStyle(color: Colors.white70),
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.of(
                                              confirmContext)
                                          .pop(false),
                                      child: const Text('ביטול'),
                                    ),
                                    ElevatedButton(
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: Colors.redAccent,
                                      ),
                                      onPressed: () => Navigator.of(
                                              confirmContext)
                                          .pop(true),
                                      child: const Text('מחק'),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ) ??
                          false;

                      if (!shouldDelete) {
                        return;
                      }

                      // Soft-delete: flips status away from 'active' so every
                      // status=='active' query (this viewer's and everyone
                      // else's) stops returning the post immediately.
                      await _db.collection('meet_now_posts').doc(doc.id).set(
                        {
                          'status': 'deleted',
                          'updatedAt': FieldValue.serverTimestamp(),
                        },
                        SetOptions(merge: true),
                      );

                      if (dialogContext.mounted) {
                        Navigator.of(dialogContext).pop(false);
                      }
                    },
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.redAccent,
                    ),
                    child: const Text('מחק פופ'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(dialogContext).pop(false),
                    child: const Text('ביטול'),
                  ),
                  ElevatedButton(
                    onPressed: () => Navigator.of(dialogContext).pop(true),
                    child: const Text('שמור'),
                  ),
                ],
              ),
            );
          },
        );
      },
    );

    if (shouldSave == true) {
      final desiredParticipants =
          int.tryParse(participantsController.text.trim());
      final payload = <String, dynamic>{
        'title': titleController.text.trim(),
        'details': detailsController.text.trim(),
        'meetingLocation': FieldValue.delete(),
        'category': (selectedCategory ?? '').trim(),
        'subCategory': (selectedSubCategory ?? '').trim(),
        'desiredParticipants': desiredParticipants,
        'timePreference': timePreference.trim(),
        'minAge': useAgeRange ? ageRange.start.round() : null,
        'maxAge': useAgeRange ? ageRange.end.round() : null,
        'updatedAt': FieldValue.serverTimestamp(),
      };
      final existingGeo = data['discoveryGeo'];
      if (existingGeo is GeoPoint) {
        payload['geohash'] = GeoHashUtils.encodeGeoPoint(
          existingGeo,
          precision: AppHomeService.meetNowGeoHashPrecision,
        );
      }
      await _db.collection('meet_now_posts').doc(doc.id).set(
            payload,
            SetOptions(merge: true),
          );
    }

    titleController.dispose();
    detailsController.dispose();
    participantsController.dispose();
  }

  String _relativeTimeFrom(dynamic raw) {
    DateTime? createdAt;
    if (raw is Timestamp) {
      createdAt = raw.toDate();
    } else if (raw is DateTime) {
      createdAt = raw;
    }
    if (createdAt == null) {
      return '';
    }

    final difference = DateTime.now().difference(createdAt);
    if (difference.inMinutes < 1) return 'עכשיו';
    if (difference.inHours < 1) return 'לפני ${difference.inMinutes} דקות';
    if (difference.inDays < 1) return 'לפני ${difference.inHours} שעות';
    return 'לפני ${difference.inDays} ימים';
  }

  Map<String, dynamic> _postMapFromDoc(
    DocumentSnapshot<Map<String, dynamic>> doc,
    Map<String, dynamic> fallback,
  ) {
    final data = <String, dynamic>{...fallback, ...?doc.data()};
    data['id'] = doc.id;
    data['postId'] = (data['postId'] as String? ?? doc.id).trim();
    return data;
  }

  Future<List<Map<String, dynamic>>> _loadPostsForActivities(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> activities,
  ) async {
    final posts = <Map<String, dynamic>>[];

    for (final activity in activities) {
      final data = activity.data();
      final postId = (data['postId'] as String? ?? '').trim();
      if (postId.isEmpty) continue;

      final postDoc = await _db.collection('posts').doc(postId).get();
      final fallback = <String, dynamic>{
        'id': postId,
        'postId': postId,
        'authorId': (data['uid'] as String? ?? '').trim(),
        'title': (data['title'] as String? ?? '').trim(),
        'description': (data['description'] as String? ??
                data['commentText'] as String? ??
                '')
            .trim(),
        'caption': (data['description'] as String? ??
                data['commentText'] as String? ??
                '')
            .trim(),
        'content': (data['description'] as String? ??
                data['commentText'] as String? ??
                '')
            .trim(),
        'imageUrl': (data['imageUrl'] as String? ?? '').trim(),
        'mediaUrl': (data['imageUrl'] as String? ?? '').trim(),
        'createdAt': data['createdAt'],
      };
      posts.add(_postMapFromDoc(postDoc, fallback));
    }

    return posts;
  }

  Future<bool> _isActivePostForActivity(
      QueryDocumentSnapshot<Map<String, dynamic>> activity) async {
    final data = activity.data();
    final postId = (data['postId'] as String? ?? '').trim();
    if (postId.isEmpty) {
      return true;
    }

    try {
      final doc = await _db.collection('posts').doc(postId).get();
      if (!doc.exists) {
        return false;
      }

      final post = doc.data() ?? <String, dynamic>{};
      final isDeleted = (post['isDeleted'] as bool?) ?? false;
      final status = (post['status'] as String? ?? '').trim().toLowerCase();
      return !isDeleted && status != 'deleted';
    } catch (_) {
      // If lookup fails (permissions/network), keep history item visible.
      return true;
    }
  }

  Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>>
      _filterVisibleActivities(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> activities,
  ) async {
    final visibility = await Future.wait(
      activities.map(_isActivePostForActivity),
    );

    final result = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
    for (var index = 0; index < activities.length; index++) {
      if (visibility[index]) {
        result.add(activities[index]);
      }
    }
    return result;
  }

  List<QueryDocumentSnapshot<Map<String, dynamic>>> _uniqueActivitiesByPost(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> activities,
  ) {
    final seenKeys = <String>{};
    final result = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
    for (final activity in activities) {
      final postId = (activity.data()['postId'] as String? ?? '').trim();
      final key = postId.isNotEmpty ? postId : activity.id;
      if (seenKeys.add(key)) {
        result.add(activity);
      }
    }
    return result;
  }

  String _historyPreviewUrl(Map<String, dynamic> data) {
    String read(Map<String, dynamic> source, String key) {
      return (source[key] as String? ?? '').trim();
    }

    for (final candidate in <String>[
      read(data, 'thumbnailUrl'),
      read(data, 'videoThumbnailUrl'),
      read(data, 'imageUrl'),
      read(data, 'mediaUrl'),
    ]) {
      if (candidate.isNotEmpty) {
        return candidate;
      }
    }

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
      if (thumbnail.isNotEmpty) {
        return thumbnail;
      }
    }

    final mediaItems = postMediaItemsFromData(data);
    for (final item in mediaItems) {
      if (!item.isVideo && item.url.trim().isNotEmpty) {
        return item.url.trim();
      }
    }

    if (mediaItems.isNotEmpty) {
      return mediaItems.first.url.trim();
    }

    return '';
  }

  Future<Map<String, dynamic>> _resolvedActivityPreviewData(
    QueryDocumentSnapshot<Map<String, dynamic>> activity,
  ) {
    final activityData = Map<String, dynamic>.from(activity.data());
    final postId = (activityData['postId'] as String? ?? '').trim();
    final cacheKey = postId.isNotEmpty ? postId : activity.id;

    return _activityPreviewFutureByKey.putIfAbsent(cacheKey, () async {
      if (postId.isEmpty) {
        return activityData;
      }

      try {
        final postDoc = await _db.collection('posts').doc(postId).get();
        if (!postDoc.exists) {
          return activityData;
        }

        return <String, dynamic>{
          ...activityData,
          ...postDoc.data() ?? <String, dynamic>{},
        };
      } catch (_) {
        return activityData;
      }
    });
  }

  String _authorLabelFromData(Map<String, dynamic> data) {
    String read(Map<String, dynamic> source, String key) {
      return (source[key] as String? ?? '').trim();
    }

    final directCandidates = <String>[
      read(data, 'authorDisplayName'),
      read(data, 'authorName'),
      read(data, 'displayName'),
      read(data, 'username'),
      read(data, 'authorUsername'),
    ];

    for (final value in directCandidates) {
      if (value.isNotEmpty) return value;
    }

    final rawAuthor = data['author'];
    if (rawAuthor is Map) {
      final author = rawAuthor.map(
        (key, value) => MapEntry(key.toString(), value),
      );
      final nestedCandidates = <String>[
        (author['displayName'] as String? ?? '').trim(),
        (author['name'] as String? ?? '').trim(),
        (author['username'] as String? ?? '').trim(),
      ];
      for (final value in nestedCandidates) {
        if (value.isNotEmpty) return value;
      }
    }

    return '';
  }

  Future<String> _resolvedPostAuthorLabel(Map<String, dynamic> data) async {
    final direct = _authorLabelFromData(data);
    if (direct.isNotEmpty) {
      return direct;
    }

    final authorId =
        (data['authorId'] as String? ?? data['uid'] as String? ?? '').trim();
    if (authorId.isEmpty) {
      return 'משתמש';
    }

    final loader = _authorLabelFutureByUid.putIfAbsent(authorId, () async {
      try {
        final merged = await _mergedUserData(authorId);
        final displayName = (merged['displayName'] as String? ?? '').trim();
        if (displayName.isNotEmpty) return displayName;
        final username = (merged['username'] as String? ?? '').trim();
        if (username.isNotEmpty) return username;
        final name = (merged['name'] as String? ?? '').trim();
        if (name.isNotEmpty) return name;
      } catch (_) {
        // Best effort fallback.
      }
      return 'משתמש';
    });

    return loader;
  }

  Future<void> _openActivityPost(
    QueryDocumentSnapshot<Map<String, dynamic>> activity,
    List<QueryDocumentSnapshot<Map<String, dynamic>>> activities,
  ) async {
    final data = activity.data();
    final postId = (data['postId'] as String? ?? '').trim();
    if (postId.isEmpty) return;

    final posts = await _loadPostsForActivities(activities);
    if (!mounted || posts.isEmpty) return;

    final tappedIndex = activities.indexWhere((doc) => doc.id == activity.id);
    final initialIndex = tappedIndex >= 0 ? tappedIndex : 0;

    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PostDetailView(
          posts: posts,
          initialIndex: initialIndex.clamp(0, posts.length - 1),
          enableEditAction: false,
        ),
      ),
    );
  }

  Widget _buildEmptyState(String message) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    return Center(
      child: Container(
        margin: const EdgeInsets.all(20),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: isLight ? Colors.white : _card,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: isLight
                ? const Color(0xFFA9C3FF)
                : _accentCyan.withValues(alpha: 0.18),
          ),
        ),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: isLight ? const Color(0xFF5B6D85) : Colors.white70,
            fontSize: 16,
          ),
        ),
      ),
    );
  }

  Widget _buildLikeTile(
    QueryDocumentSnapshot<Map<String, dynamic>> activity,
    List<QueryDocumentSnapshot<Map<String, dynamic>>> allActivities,
  ) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    return InkWell(
      onTap: () => _openActivityPost(activity, allActivities),
      borderRadius: BorderRadius.circular(16),
      child: FutureBuilder<Map<String, dynamic>>(
        future: _resolvedActivityPreviewData(activity),
        builder: (context, snapshot) {
          final data = snapshot.data ?? activity.data();
          final title = (data['title'] as String? ?? 'פופ ללא כותרת').trim();
          final imageUrl = _historyPreviewUrl(data);
          final mediaItems = postMediaItemsFromData(data);
          final time = _relativeTimeFrom(activity.data()['createdAt']);

          return Container(
            decoration: BoxDecoration(
              color: isLight ? Colors.white : const Color(0xFF1A2435),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isLight
                    ? const Color(0xFFA9C3FF)
                    : _accentCyan.withValues(alpha: 0.16),
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (mediaItems.isNotEmpty)
                    PostMediaViewer(
                      mediaItems: mediaItems,
                      aspectRatio: null,
                      showIndicators: false,
                      isActive: false,
                    )
                  else if (imageUrl.isNotEmpty)
                    Image.network(imageUrl, fit: BoxFit.cover)
                  else
                    Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: isLight
                              ? const [Color(0xFFEAF2FF), Color(0xFFF5F9FF)]
                              : const [Color(0xFF24344E), Color(0xFF1A2340)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                      ),
                    ),
                  Container(color: Colors.black.withValues(alpha: 0.28)),
                  Positioned(
                    left: 10,
                    right: 10,
                    bottom: 10,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        if (time.isNotEmpty)
                          Text(
                            time,
                            style: TextStyle(
                              color: isLight
                                  ? const Color(0xFF5B6D85)
                                  : const Color(0xFFEAF4FF),
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildCommentTile(
    QueryDocumentSnapshot<Map<String, dynamic>> activity,
    List<QueryDocumentSnapshot<Map<String, dynamic>>> allActivities,
  ) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final activityData = activity.data();
    final commentText = (activityData['commentText'] as String? ??
            activityData['description'] as String? ??
            '')
        .trim();
    final time = _relativeTimeFrom(activityData['createdAt']);

    return InkWell(
      onTap: () => _openActivityPost(activity, allActivities),
      borderRadius: BorderRadius.circular(18),
      child: FutureBuilder<Map<String, dynamic>>(
        future: _resolvedActivityPreviewData(activity),
        builder: (context, snapshot) {
          final resolvedData = snapshot.data ?? activityData;
          final mediaItems = postMediaItemsFromData(resolvedData);
          final previewUrl = _historyPreviewUrl(resolvedData);
          final hasVideo = mediaItems.any((item) => item.isVideo) ||
              (resolvedData['videoUrl'] as String? ?? '').trim().isNotEmpty;

          return FutureBuilder<String>(
            future: _resolvedPostAuthorLabel(resolvedData),
            builder: (context, authorSnapshot) {
              final postAuthorLabel =
                  (authorSnapshot.data ?? 'משתמש').trim().isNotEmpty
                      ? (authorSnapshot.data ?? 'משתמש').trim()
                      : 'משתמש';

              return Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: isLight ? Colors.white : _card,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: isLight
                        ? const Color(0xFFCFBEFF)
                        : _accentPurple.withValues(alpha: 0.16),
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            commentText.isNotEmpty
                                ? commentText
                                : 'תגובה שנשמרה בהיסטוריה',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                              height: 1.2,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'הגבת על פוסט של $postAuthorLabel',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (time.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            Text(
                              time,
                              style: TextStyle(
                                color: isLight
                                    ? const Color(0xFF5B6D85)
                                    : const Color(0xFFEAF4FF),
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Container(
                      width: 74,
                      height: 74,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                            color: _accentCyan.withValues(alpha: 0.35)),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(11),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            if (mediaItems.isNotEmpty)
                              IgnorePointer(
                                child: PostMediaViewer(
                                  mediaItems: mediaItems,
                                  aspectRatio: 1,
                                  showIndicators: false,
                                  isActive: false,
                                ),
                              )
                            else if (previewUrl.isNotEmpty)
                              Image.network(
                                previewUrl,
                                fit: BoxFit.cover,
                                errorBuilder: (context, _, __) => Container(
                                  color: isLight
                                      ? const Color(0xFFEAF2FF)
                                      : const Color(0xFF24344E),
                                  alignment: Alignment.center,
                                  child: const Icon(
                                    Icons.image_not_supported_outlined,
                                    color: Colors.white70,
                                    size: 18,
                                  ),
                                ),
                              )
                            else
                              Container(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    colors: isLight
                                        ? const [
                                            Color(0xFFEAF2FF),
                                            Color(0xFFF5F9FF),
                                          ]
                                        : const [
                                            Color(0xFF24344E),
                                            Color(0xFF1A2340),
                                          ],
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                  ),
                                ),
                                alignment: Alignment.center,
                                child: const Icon(
                                  Icons.image_outlined,
                                  color: Colors.white70,
                                  size: 18,
                                ),
                              ),
                            if (hasVideo)
                              Container(
                                color: Colors.black.withValues(alpha: 0.18),
                                alignment: Alignment.center,
                                child: const Icon(
                                  Icons.play_circle_fill_rounded,
                                  color: Colors.white,
                                  size: 24,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  List<_MeetHistoryPopItem> _createdMeetItems(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) {
    final items = docs
        .map((doc) => _MeetHistoryPopItem(id: doc.id, data: doc.data()))
        .where((item) => item.isActive && _withinHistoryWindow(item.createdAt))
        .toList(growable: false);

    items.sort((a, b) {
      final aTime = a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bTime = b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      return bTime.compareTo(aTime);
    });

    return items;
  }

  Widget _buildMeetNowGridCard(
    _MeetHistoryPopItem item, {
    required bool canEdit,
    required VoidCallback onTap,
  }) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final title = (item.data['title'] as String? ??
            item.data['groupName'] as String? ??
            'פופ')
        .trim();
    final description = (item.data['details'] as String? ??
            item.data['description'] as String? ??
            '')
        .trim();
    final category = (item.data['category'] as String? ?? '').trim();
    final categoryIcon = categoryIconFor(
      category.isEmpty ? kGeneralCategory : category,
    );
    final time = _relativeTimeFrom(item.createdAt);
    final isRecent = _withinEditWindow(item.createdAt);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        decoration: BoxDecoration(
          gradient: isRecent
              ? LinearGradient(
                  colors: isLight
                      ? const [Color(0x3394C6FF), Color(0x33CFAFFF)]
                      : const [Color(0x3325D9FF), Color(0x33B78EFF)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                )
              : null,
          color: isRecent ? null : (isLight ? Colors.white : _card),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isRecent
                ? (isLight
                    ? const Color(0xFFA9C3FF).withValues(alpha: 0.9)
                    : const Color(0xFF7FD8FF).withValues(alpha: 0.68))
                : (isLight
                    ? const Color(0xFFA9C3FF)
                    : _accentCyan.withValues(alpha: 0.16)),
          ),
        ),
        padding: const EdgeInsets.all(10),
        child: Stack(
          children: [
            Positioned(
              top: 3,
              left: 3,
              child: Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: const LinearGradient(
                    colors: [Color(0xFF8C62FF), Color(0xFF46D3FF)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  border: Border.all(
                    color: const Color(0xFFA9C3FF).withValues(alpha: 0.45),
                  ),
                ),
                child: Icon(
                  categoryIcon,
                  size: 13,
                  color: Colors.white,
                ),
              ),
            ),
            Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 30),
                  child: Text(
                    title.isEmpty ? 'פופ' : title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isLight ? const Color(0xFF101826) : Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (description.isNotEmpty)
                      Text(
                        description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: isLight
                              ? const Color(0xFF5B6D85)
                              : Colors.white70,
                          fontSize: 10.5,
                        ),
                      ),
                    if (time.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        time,
                        style: TextStyle(
                          color: isLight
                              ? const Color(0xFF4D607A)
                              : const Color(0xFFEAF4FF),
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                    if (canEdit)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Icon(
                          Icons.edit_rounded,
                          size: 12,
                          color: isLight
                              ? const Color(0xFF5B6D85)
                              : const Color(0xFFCCE8FF),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openMeetNowPopDetails(
    _MeetHistoryPopItem item, {
    required bool canEdit,
  }) async {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final data = item.data;
    final imageUrls = await _meetNowImageUrls(data);
    if (!mounted) return;

    final title = (data['title'] as String? ?? 'פופ').trim();
    final details =
        (data['details'] as String? ?? data['description'] as String? ?? '')
            .trim();
    final location = (data['meetingLocation'] as String? ?? '').trim();
    final category = (data['category'] as String? ?? '').trim();
    final subCategory = (data['subCategory'] as String? ?? '').trim();
    final timePreference = (data['timePreference'] as String? ?? '').trim();
    final linkedGroupId = (data['linkedGroupId'] as String? ?? '').trim();
    final desiredParticipants = (data['desiredParticipants'] as num?)?.toInt();
    final minAge = (data['minAge'] as num?)?.toInt();
    final maxAge = (data['maxAge'] as num?)?.toInt();

    var activeIndex = 0;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor:
          isLight ? const Color(0xFFF5F8FF) : const Color(0xFF0F1727),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        final imageController = PageController();
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return Directionality(
              textDirection: TextDirection.rtl,
              child: SafeArea(
                child: SizedBox(
                  height: MediaQuery.of(sheetContext).size.height * 0.88,
                  child: Column(
                    children: [
                      Expanded(
                        flex: 6,
                        child: Stack(
                          children: [
                            Positioned.fill(
                              child: imageUrls.isEmpty
                                  ? Container(
                                      color: isLight
                                          ? const Color(0xFFEAF2FF)
                                          : const Color(0xFF111A28),
                                      alignment: Alignment.center,
                                      child: Icon(
                                        Icons.person_outline_rounded,
                                        color: isLight
                                            ? const Color(0xFF7E8FA8)
                                            : Colors.white54,
                                        size: 58,
                                      ),
                                    )
                                  : PageView.builder(
                                      controller: imageController,
                                      scrollDirection: Axis.vertical,
                                      onPageChanged: (index) {
                                        setSheetState(() {
                                          activeIndex = index;
                                        });
                                      },
                                      itemCount: imageUrls.length,
                                      itemBuilder: (_, index) => Image.network(
                                        imageUrls[index],
                                        fit: BoxFit.cover,
                                      ),
                                    ),
                            ),
                            Positioned(
                              top: 10,
                              right: 12,
                              left: 12,
                              child: Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 10, vertical: 6),
                                    decoration: BoxDecoration(
                                      color:
                                          Colors.black.withValues(alpha: 0.42),
                                      borderRadius: BorderRadius.circular(999),
                                    ),
                                    child: Text(
                                      imageUrls.isEmpty
                                          ? '0 תמונות'
                                          : '${activeIndex + 1}/${imageUrls.length}',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                  const Spacer(),
                                  IconButton(
                                    onPressed: () =>
                                        Navigator.of(sheetContext).pop(),
                                    icon: const Icon(
                                      Icons.close_rounded,
                                      color: Colors.white,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        flex: 4,
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: SingleChildScrollView(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        title.isEmpty ? 'פופ' : title,
                                        style: TextStyle(
                                          color: isLight
                                              ? const Color(0xFF101826)
                                              : Colors.white,
                                          fontSize: 22,
                                          fontWeight: FontWeight.w900,
                                        ),
                                      ),
                                      if (details.isNotEmpty) ...[
                                        const SizedBox(height: 8),
                                        Text(
                                          details,
                                          style: TextStyle(
                                            color: isLight
                                                ? const Color(0xFF4D607A)
                                                : const Color(0xFFD8E3F8),
                                            fontSize: 13,
                                            height: 1.32,
                                          ),
                                        ),
                                      ],
                                      const SizedBox(height: 10),
                                      Wrap(
                                        spacing: 8,
                                        runSpacing: 8,
                                        children: [
                                          if (location.isNotEmpty)
                                            _metaPill(
                                                Icons.place_rounded, location),
                                          if (timePreference.isNotEmpty)
                                            _metaPill(Icons.schedule_rounded,
                                                timePreference),
                                          if (category.isNotEmpty ||
                                              subCategory.isNotEmpty)
                                            _metaPill(
                                              categoryIconFor(
                                                category.isEmpty
                                                    ? kGeneralCategory
                                                    : category,
                                              ),
                                              subCategory.isEmpty
                                                  ? (category.isEmpty
                                                      ? kGeneralCategory
                                                      : category)
                                                  : '${category.isEmpty ? kGeneralCategory : category} • $subCategory',
                                            ),
                                          if (minAge != null && maxAge != null)
                                            _metaPill(
                                              Icons.cake_rounded,
                                              'גילאים $minAge-$maxAge',
                                            ),
                                          if (desiredParticipants != null)
                                            _metaPill(
                                              Icons.groups_rounded,
                                              '$desiredParticipants משתתפים רצויים',
                                            ),
                                        ],
                                      ),
                                      const SizedBox(height: 8),
                                    ],
                                  ),
                                ),
                              ),
                              if (canEdit)
                                Row(
                                  children: [
                                    Expanded(
                                      child: ElevatedButton.icon(
                                        onPressed: () async {
                                          Navigator.of(sheetContext).pop();
                                          final snapshot = await _db
                                              .collection('meet_now_posts')
                                              .doc(item.id)
                                              .get();
                                          if (!snapshot.exists || !mounted) {
                                            return;
                                          }
                                          await _editMeetNowPost(snapshot);
                                        },
                                        icon: const Icon(Icons.edit_rounded),
                                        label: const Text('עריכת פופ'),
                                      ),
                                    ),
                                  ],
                                ),
                              if (linkedGroupId.isNotEmpty) ...[
                                if (canEdit) const SizedBox(height: 8),
                                Row(
                                  children: [
                                    Expanded(
                                      child: OutlinedButton.icon(
                                        onPressed: () async {
                                          Navigator.of(sheetContext).pop();
                                          await _openGroupChatById(
                                            groupId: linkedGroupId,
                                            fallbackName:
                                                title.isEmpty ? 'פופ' : title,
                                          );
                                        },
                                        icon: const Icon(Icons.forum_rounded),
                                        label: const Text('צפייה בקבוצה'),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ],
                          ),
                        ),
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

  Future<void> _openGroupChatById({
    required String groupId,
    required String fallbackName,
  }) async {
    final normalizedGroupId = groupId.trim();
    if (normalizedGroupId.isEmpty || !mounted) {
      return;
    }

    try {
      final chatDoc =
          await _db.collection('chats').doc(normalizedGroupId).get();
      final groupDoc =
          await _db.collection('groups').doc(normalizedGroupId).get();
      final chatData = chatDoc.data() ?? <String, dynamic>{};
      final groupData = groupDoc.data() ?? <String, dynamic>{};

      String firstNonEmpty(List<String> values) {
        for (final value in values) {
          final trimmed = value.trim();
          if (trimmed.isNotEmpty) return trimmed;
        }
        return '';
      }

      final chatName = firstNonEmpty([
        (chatData['name'] as String? ?? ''),
        (groupData['groupName'] as String? ?? ''),
        (groupData['name'] as String? ?? ''),
        fallbackName,
      ]);
      final avatarUrl = firstNonEmpty([
        (chatData['groupImageUrl'] as String? ?? ''),
        (groupData['groupImageUrl'] as String? ?? ''),
      ]);

      if (!mounted) {
        return;
      }

      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ChatRoomScreen(
            chatName: chatName.isEmpty ? fallbackName : chatName,
            avatarUrl: avatarUrl.isEmpty ? null : avatarUrl,
            chatId: normalizedGroupId,
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

  Widget _metaPill(IconData icon, String text) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: isLight ? Colors.white : const Color(0xFF17263C),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: isLight
              ? const Color(0xFFA9C3FF)
              : _accentCyan.withValues(alpha: 0.28),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 14,
            color: isLight ? const Color(0xFF4A6A93) : const Color(0xFFC4E1FF),
          ),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(
              color: isLight ? const Color(0xFF101826) : Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMeetNowSection(
    String title,
    List<_MeetHistoryPopItem> items, {
    required bool editableSection,
    required bool showAll,
    required VoidCallback onToggleShowAll,
  }) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final previewItems =
        showAll ? items : items.take(10).toList(growable: false);
    final hasMore = items.length > 10;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
          child: Text(
            title,
            style: TextStyle(
              color: isLight ? const Color(0xFF101826) : Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        if (items.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: _buildEmptyState(
              editableSection
                  ? 'עדיין לא יצרת פופים'
                  : 'עדיין לא הצטרפת לפופים',
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: previewItems.length,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
                childAspectRatio: 0.8,
              ),
              itemBuilder: (context, index) {
                final item = previewItems[index];
                final canEdit =
                    editableSection && _withinEditWindow(item.createdAt);
                return _buildMeetNowGridCard(
                  item,
                  canEdit: canEdit,
                  onTap: () => _openMeetNowPopDetails(item, canEdit: canEdit),
                );
              },
            ),
          ),
        if (hasMore)
          Padding(
            padding: const EdgeInsets.only(top: 10, right: 14, left: 14),
            child: OutlinedButton(
              onPressed: onToggleShowAll,
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: _accentCyan.withValues(alpha: 0.45)),
              ),
              child: Text(showAll ? 'הצג פחות' : 'הצג עוד'),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: SwipeBackWrapper(
        child: Scaffold(
          backgroundColor: isLight ? const Color(0xFFF5F8FF) : _bgBottom,
          appBar: AppBar(
            backgroundColor: isLight ? Colors.white : const Color(0xFF131E31),
            elevation: 0,
            centerTitle: true,
            title: Text(
              'היסטוריה',
              style: TextStyle(
                color: isLight ? const Color(0xFF101826) : Colors.white,
                fontWeight: FontWeight.w800,
              ),
            ),
            bottom: TabBar(
              controller: _tabController,
              indicatorColor: _accentCyan,
              labelColor: isLight ? const Color(0xFF101826) : Colors.white,
              unselectedLabelColor:
                  isLight ? const Color(0xFF7A8DA8) : Colors.white54,
              tabs: const [
                Tab(text: 'לייקים'),
                Tab(text: 'תגובות'),
                Tab(text: 'פופים'),
              ],
            ),
          ),
          body: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: _dismissKeyboardOnBackgroundTap,
            child: Container(
              decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: isLight
                    ? const [Color(0xFFF7FAFF), Color(0xFFEFF5FF)]
                    : const [_bgTop, Color(0xFF131B33), _bgBottom],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
            ),
              child: StreamBuilder<
                List<QueryDocumentSnapshot<Map<String, dynamic>>>>(
              stream: _activityStream(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting &&
                    !snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }

                if (snapshot.hasError) {
                  return Center(
                    child: Text(
                      'שגיאה בטעינת היסטוריה',
                      style: TextStyle(
                        color:
                            isLight ? const Color(0xFF5B6D85) : Colors.white70,
                      ),
                    ),
                  );
                }

                final activities = snapshot.data ??
                    const <QueryDocumentSnapshot<Map<String, dynamic>>>[];
                return FutureBuilder<
                    List<QueryDocumentSnapshot<Map<String, dynamic>>>>(
                  future: _filterVisibleActivities(activities),
                  builder: (context, filteredSnapshot) {
                    if (filteredSnapshot.connectionState ==
                            ConnectionState.waiting &&
                        !filteredSnapshot.hasData) {
                      return const Center(child: CircularProgressIndicator());
                    }

                    final visibleActivities = filteredSnapshot.data ??
                        const <QueryDocumentSnapshot<Map<String, dynamic>>>[];
                    final likes = _uniqueActivitiesByPost(visibleActivities
                        .where((doc) =>
                            (doc.data()['type'] as String? ?? '') == 'like')
                        .toList(growable: false));
                    final comments = visibleActivities
                        .where((doc) =>
                            (doc.data()['type'] as String? ?? '') == 'comment')
                        .toList(growable: false);
                    return TabBarView(
                      controller: _tabController,
                      children: [
                        likes.isEmpty
                            ? _buildEmptyState('אין לייקים להצגה עדיין')
                            : Padding(
                                padding: const EdgeInsets.all(14),
                                child: GridView.builder(
                                  itemCount: likes.length,
                                  gridDelegate:
                                      const SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: 3,
                                    crossAxisSpacing: 10,
                                    mainAxisSpacing: 10,
                                    childAspectRatio: 0.78,
                                  ),
                                  itemBuilder: (context, index) {
                                    return _buildLikeTile(likes[index], likes);
                                  },
                                ),
                              ),
                        comments.isEmpty
                            ? _buildEmptyState('אין תגובות להצגה עדיין')
                            : ListView.separated(
                                padding: const EdgeInsets.all(14),
                                itemCount: comments.length,
                                separatorBuilder: (_, __) =>
                                    const SizedBox(height: 10),
                                itemBuilder: (context, index) {
                                  return _buildCommentTile(
                                      comments[index], comments);
                                },
                              ),
                        StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                          stream: _meetNowHistoryStream(),
                          builder: (context, createdSnapshot) {
                            final createdItems = _createdMeetItems(
                              createdSnapshot.data?.docs ??
                                  const <QueryDocumentSnapshot<
                                      Map<String, dynamic>>>[],
                            );

                            return StreamBuilder<List<_MeetHistoryPopItem>>(
                              stream: _joinedMeetNowHistoryStream(),
                              builder: (context, joinedSnapshot) {
                                final joinedItems = joinedSnapshot.data ??
                                    const <_MeetHistoryPopItem>[];

                                if (createdItems.isEmpty &&
                                    joinedItems.isEmpty) {
                                  return _buildEmptyState(
                                      'אין פופים להצגה עדיין');
                                }

                                return ListView(
                                  padding: const EdgeInsets.only(bottom: 18),
                                  children: [
                                    _buildMeetNowSection(
                                      'פופים שיצרתי',
                                      createdItems,
                                      editableSection: true,
                                      showAll: _showAllCreatedPops,
                                      onToggleShowAll: () {
                                        setState(() {
                                          _showAllCreatedPops =
                                              !_showAllCreatedPops;
                                        });
                                      },
                                    ),
                                    const SizedBox(height: 14),
                                    _buildMeetNowSection(
                                      'פופים שהצטרפתי אליהם',
                                      joinedItems,
                                      editableSection: false,
                                      showAll: _showAllJoinedPops,
                                      onToggleShowAll: () {
                                        setState(() {
                                          _showAllJoinedPops =
                                              !_showAllJoinedPops;
                                        });
                                      },
                                    ),
                                  ],
                                );
                              },
                            );
                          },
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
      ),
    );
  }
}
