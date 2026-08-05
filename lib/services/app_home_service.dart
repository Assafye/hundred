import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../age_restrictions.dart';
import '../models/public_user_profile.dart';
import 'location_service.dart';
import 'public_user_profile_service.dart';

class HomeFriendEntry {
  final String uid;
  final String name;
  final String handle;
  final String avatarUrl;
  final bool isLikelyOnline;

  const HomeFriendEntry({
    required this.uid,
    required this.name,
    required this.handle,
    required this.avatarUrl,
    required this.isLikelyOnline,
  });
}

class HomePublicGroupEntry {
  final String groupId;
  final String name;
  final String description;
  final String imageUrl;
  final String category;
  final String subCategory;
  final String location;
  final GeoPoint? geo;
  final DateTime? date;
  final int minScore;
  final bool isMinScoreRequired;
  final int membersCount;
  final List<dynamic> participants;

  const HomePublicGroupEntry({
    required this.groupId,
    required this.name,
    required this.description,
    required this.imageUrl,
    required this.category,
    required this.subCategory,
    required this.location,
    required this.geo,
    required this.date,
    required this.minScore,
    required this.isMinScoreRequired,
    required this.membersCount,
    required this.participants,
  });
}

class MeetNowPostEntry {
  final String id;
  final String authorUid;
  final String authorName;
  final String authorHandle;
  final String authorAvatarUrl;
  final List<String> authorProfileImageUrls;
  final int authorScore;
  final String authorLocation;
  final GeoPoint? authorGeo;
  final String title;
  final String details;
  final String category;
  final String subCategory;
  final String meetingLocation;
  final GeoPoint? meetingGeo;
  final int? desiredParticipants;
  final String timePreference;
  final int? minAge;
  final int? maxAge;
  final DateTime createdAt;
  final String linkedGroupId;
  final int linkedGroupMembersCount;
  final bool linkedGroupIsPublic;
  final List<String> participantProfileImageUrls;

  const MeetNowPostEntry({
    required this.id,
    required this.authorUid,
    required this.authorName,
    required this.authorHandle,
    required this.authorAvatarUrl,
    required this.authorProfileImageUrls,
    required this.authorScore,
    required this.authorLocation,
    required this.authorGeo,
    required this.title,
    required this.details,
    required this.category,
    required this.subCategory,
    required this.meetingLocation,
    required this.meetingGeo,
    required this.desiredParticipants,
    required this.timePreference,
    required this.minAge,
    required this.maxAge,
    required this.createdAt,
    required this.linkedGroupId,
    required this.linkedGroupMembersCount,
    required this.linkedGroupIsPublic,
    required this.participantProfileImageUrls,
  });
}

class HomeGroupMemberEntry {
  final String uid;
  final String name;
  final String handle;
  final String avatarUrl;

  const HomeGroupMemberEntry({
    required this.uid,
    required this.name,
    required this.handle,
    required this.avatarUrl,
  });
}

class MeetNowPublishLimitException implements Exception {
  const MeetNowPublishLimitException();
}

class AppHomeService {
  AppHomeService({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
    PublicUserProfileService? publicUserProfileService,
    LocationService? locationService,
  })  : _db = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance,
        _publicUserProfileService =
            publicUserProfileService ?? PublicUserProfileService(),
        _locationService = locationService ?? LocationService();

  final FirebaseFirestore _db;
  final FirebaseAuth _auth;
  final PublicUserProfileService _publicUserProfileService;
  final LocationService _locationService;

  String? get currentUid => _auth.currentUser?.uid;

  CollectionReference<Map<String, dynamic>> get _users =>
      _db.collection('users');
  CollectionReference<Map<String, dynamic>> get _groups =>
      _db.collection('groups');
  CollectionReference<Map<String, dynamic>> get _meetNowPosts =>
      _db.collection('meet_now_posts');

  Future<int> meetNowPostsPublishedInLastHour() async {
    final uid = currentUid;
    if (uid == null || uid.isEmpty) {
      throw FirebaseAuthException(
        code: 'not-authenticated',
        message: 'User must be logged in to publish.',
      );
    }

    final now = DateTime.now();
    const recentWindow = Duration(hours: 1);
    final recentPosts =
        await _meetNowPosts.where('authorUid', isEqualTo: uid).get();
    var publishedInLastHour = 0;
    for (final doc in recentPosts.docs) {
      final data = doc.data();
      final status =
          (data['status'] as String? ?? 'active').trim().toLowerCase();
      if (status == 'deleted') {
        continue;
      }

      final createdAt = _dateValue(data, const ['createdAt']);
      if (createdAt == null || now.difference(createdAt) <= recentWindow) {
        publishedInLastHour++;
      }
    }

    return publishedInLastHour;
  }

  Future<bool> canPublishMeetNowPost() async {
    final published = await meetNowPostsPublishedInLastHour();
    return published < 2;
  }

  String _displayName(PublicUserProfile? profile, {required String fallback}) {
    if (profile != null && profile.displayName.trim().isNotEmpty) {
      return profile.displayName.trim();
    }
    if (profile != null && profile.handle.trim().isNotEmpty) {
      return profile.handle.replaceFirst('@', '').trim();
    }
    return fallback;
  }

  String _handle(PublicUserProfile? profile, {required String fallbackUid}) {
    if (profile != null && profile.handle.trim().isNotEmpty) {
      return profile.handle.trim();
    }
    final shortUid = fallbackUid.substring(
        0, fallbackUid.length > 6 ? 6 : fallbackUid.length);
    return '@$shortUid';
  }

  String _avatar(PublicUserProfile? profile) {
    return (profile?.profilePictureUrl ?? '').trim();
  }

  List<String> _stringListValue(Map<String, dynamic> data, List<String> keys) {
    for (final key in keys) {
      final raw = data[key];
      if (raw is! List) {
        continue;
      }
      final values = raw
          .map((item) => item.toString().trim())
          .where((item) => item.isNotEmpty)
          .toList(growable: false);
      if (values.isNotEmpty) {
        return values;
      }
    }
    return const <String>[];
  }

  String _textValue(Map<String, dynamic> data, List<String> keys) {
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

  int _intValue(Map<String, dynamic> data, List<String> keys,
      {int fallback = 0}) {
    for (final key in keys) {
      final raw = data[key];
      if (raw is num) {
        return raw.toInt();
      }
      if (raw is String) {
        final parsed = int.tryParse(raw.trim());
        if (parsed != null) {
          return parsed;
        }
      }
    }
    return fallback;
  }

  DateTime? _dateValue(Map<String, dynamic> data, List<String> keys) {
    for (final key in keys) {
      final raw = data[key];
      if (raw is Timestamp) {
        return raw.toDate();
      }
      if (raw is DateTime) {
        return raw;
      }
      if (raw is String) {
        final parsed = DateTime.tryParse(raw.trim());
        if (parsed != null) {
          return parsed;
        }
      }
    }
    return null;
  }

  bool _isLikelyOnline(
      Map<String, dynamic> privateData, Map<String, dynamic> publicData) {
    final merged = <String, dynamic>{...privateData, ...publicData};
    final forcedOnlineUntil =
        _dateValue(merged, const ['forcedOnlineUntil', 'forceOnlineUntil']);
    if (forcedOnlineUntil != null &&
        forcedOnlineUntil.isAfter(DateTime.now())) {
      return true;
    }

    final onlineBool =
        merged['isOnline'] ?? merged['online'] ?? merged['activeNow'];
    if (onlineBool is bool) {
      return onlineBool;
    }

    final status = (merged['status'] as String? ?? '').trim().toLowerCase();
    if (status == 'online' || status == 'active') {
      return true;
    }

    final lastSeen = _dateValue(merged, const ['lastSeen', 'updatedAt']);
    if (lastSeen == null) {
      return false;
    }

    return DateTime.now().difference(lastSeen).inMinutes <= 10;
  }

  Future<void> setForcedOnlineDuration(Duration duration) async {
    final uid = currentUid;
    if (uid == null || uid.isEmpty) {
      throw FirebaseAuthException(
        code: 'not-authenticated',
        message: 'User must be logged in to update online status.',
      );
    }

    final safeMinutes = duration.inMinutes.clamp(1, 120);
    final until = DateTime.now().add(Duration(minutes: safeMinutes));
    await _users.doc(uid).set({
      'forcedOnlineUntil': Timestamp.fromDate(until),
      'status': 'online',
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Stream<DateTime?> streamMyForcedOnlineUntil() {
    final uid = currentUid;
    if (uid == null || uid.isEmpty) {
      return Stream.value(null);
    }

    return _users.doc(uid).snapshots().map((snapshot) {
      final data = snapshot.data() ?? <String, dynamic>{};
      return _dateValue(data, const ['forcedOnlineUntil', 'forceOnlineUntil']);
    });
  }

  String _userLocationFromData(Map<String, dynamic> data) {
    return _textValue(
      data,
      const ['location', 'city', 'address', 'meetingRegion'],
    );
  }

  List<HomeFriendEntry> _friendEntriesFromSnapshots(
    Map<String, DocumentSnapshot<Map<String, dynamic>>> privateSnapshots,
    List<String> orderedFriendIds,
  ) {
    final entries = <HomeFriendEntry>[];

    for (final friendUid in orderedFriendIds) {
      final privateData =
          privateSnapshots[friendUid]?.data() ?? <String, dynamic>{};
      final fallbackName =
          _textValue(privateData, const ['displayName', 'username']);
      final profile = PublicUserProfile.fallback(
        userId: friendUid,
        username: _textValue(privateData, const ['username']),
        displayName:
            _textValue(privateData, const ['displayName', 'firstName']),
        profilePictureUrl: _textValue(
          privateData,
          const ['profilePictureUrl', 'profileImageUrl', 'avatarUrl'],
        ),
        score: _intValue(privateData, const ['score']),
        exists: privateSnapshots[friendUid]?.exists ?? false,
      );
      final isOnline = _isLikelyOnline(privateData, privateData);
      if (!isOnline) {
        continue;
      }

      entries.add(
        HomeFriendEntry(
          uid: friendUid,
          name: _displayName(
            profile,
            fallback: fallbackName.isEmpty ? 'חבר' : fallbackName,
          ),
          handle: _handle(profile, fallbackUid: friendUid),
          avatarUrl: _avatar(profile),
          isLikelyOnline: true,
        ),
      );
    }

    entries.sort((a, b) => a.name.compareTo(b.name));
    return entries;
  }

  GeoPoint? _geoPointFromData(Map<String, dynamic> data) {
    final rawGeo = data['geo'];
    if (rawGeo is GeoPoint) {
      return rawGeo;
    }

    final latitude = data['latitude'];
    final longitude = data['longitude'];
    if (latitude is num && longitude is num) {
      return GeoPoint(latitude.toDouble(), longitude.toDouble());
    }

    final nestedLocation = data['location'];
    if (nestedLocation is Map<String, dynamic>) {
      final nestedGeo = nestedLocation['geo'];
      if (nestedGeo is GeoPoint) {
        return nestedGeo;
      }
      final nestedLat = nestedLocation['latitude'];
      final nestedLng = nestedLocation['longitude'];
      if (nestedLat is num && nestedLng is num) {
        return GeoPoint(nestedLat.toDouble(), nestedLng.toDouble());
      }
    }

    return null;
  }

  Set<String> _groupMemberUids(Map<String, dynamic> groupData) {
    final uids = <String>{};

    void addList(String key) {
      final raw = (groupData[key] as List<dynamic>?) ?? const <dynamic>[];
      for (final value in raw) {
        final uid = value.toString().trim();
        if (uid.isNotEmpty) {
          uids.add(uid);
        }
      }
    }

    addList('members');
    addList('membersList');
    addList('participants');

    final adminUid = (groupData['adminUid'] as String? ?? '').trim();
    if (adminUid.isNotEmpty) {
      uids.add(adminUid);
    }

    return uids;
  }

  Stream<List<HomeFriendEntry>> streamConnectedFriends() {
    final uid = currentUid;
    if (uid == null || uid.isEmpty) {
      return Stream.value(const <HomeFriendEntry>[]);
    }

    return Stream.multi((controller) {
      StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? userSub;
      final friendSubs = <String,
          StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>>{};
      final friendSnapshots =
          <String, DocumentSnapshot<Map<String, dynamic>>>{};
      List<String> currentFriendIds = const <String>[];

      void emit() {
        controller.add(
            _friendEntriesFromSnapshots(friendSnapshots, currentFriendIds));
      }

      Future<void> resetFriendSubscriptions(List<String> friendIds) async {
        final nextIds = friendIds.toSet();
        final staleIds = friendSubs.keys
            .where((id) => !nextIds.contains(id))
            .toList(growable: false);
        for (final staleId in staleIds) {
          await friendSubs.remove(staleId)?.cancel();
          friendSnapshots.remove(staleId);
        }

        for (final friendUid in friendIds) {
          if (friendSubs.containsKey(friendUid)) {
            continue;
          }
          friendSubs[friendUid] = _users.doc(friendUid).snapshots().listen(
            (snapshot) {
              friendSnapshots[friendUid] = snapshot;
              emit();
            },
            onError: controller.addError,
          );
        }

        emit();
      }

      userSub = _users.doc(uid).snapshots().listen((userSnapshot) async {
        final userData = userSnapshot.data() ?? <String, dynamic>{};
        final explicitFriends =
            ((userData['friends'] as List<dynamic>?) ?? const <dynamic>[])
                .map((value) => value.toString().trim())
                .where((value) => value.isNotEmpty && value != uid)
                .toSet();

        final following =
            ((userData['following'] as List<dynamic>?) ?? const <dynamic>[])
                .map((value) => value.toString().trim())
                .where((value) => value.isNotEmpty && value != uid)
                .toSet();

        final followers =
            ((userData['followers'] as List<dynamic>?) ?? const <dynamic>[])
                .map((value) => value.toString().trim())
                .where((value) => value.isNotEmpty && value != uid)
                .toSet();

        final resolvedFriendIds = explicitFriends.isNotEmpty
            ? explicitFriends
            : following.intersection(followers);

        currentFriendIds = resolvedFriendIds.toList(growable: false);

        await resetFriendSubscriptions(currentFriendIds);
      }, onError: controller.addError);

      controller.onCancel = () async {
        await userSub?.cancel();
        for (final sub in friendSubs.values) {
          await sub.cancel();
        }
      };
    });
  }

  Stream<List<HomePublicGroupEntry>> streamUpcomingPublicGroups(
      {int withinDays = 7}) {
    return _groups.snapshots().map((snapshot) {
      final now = DateTime.now();
      final start = DateTime(now.year, now.month, now.day);
      final end = start.add(Duration(days: withinDays));

      final entries = snapshot.docs.where((doc) {
        final data = doc.data();
        final isPublic = (data['isPublic'] as bool?) ?? false;
        if (!isPublic) {
          return false;
        }

        final date = _dateValue(data, const ['date', 'executionDate']);
        if (date == null) {
          return false;
        }

        final normalized = DateTime(date.year, date.month, date.day);
        return !normalized.isBefore(start) && !normalized.isAfter(end);
      }).map((doc) {
        final data = doc.data();
        return HomePublicGroupEntry(
          groupId: doc.id,
          name: _textValue(data, const ['groupName', 'name']),
          description: _textValue(data, const ['description']),
          imageUrl: _textValue(data, const ['groupImageUrl']),
          category: _textValue(data, const ['category', 'mainCategory']),
          subCategory: _textValue(data, const ['subCategory']),
          location: _textValue(data, const ['location', 'meetingRegion']),
          geo: _geoPointFromData(data),
          date: _dateValue(data, const ['date', 'executionDate']),
          minScore: _intValue(data, const ['minScore']),
          isMinScoreRequired: (data['isMinScoreRequired'] as bool?) ??
              _intValue(data, const ['minScore']) > 0,
          membersCount: _intValue(data, const ['membersCount'], fallback: 0),
          participants: (data['membersList'] as List<dynamic>?) ??
              (data['members'] as List<dynamic>?) ??
              const <dynamic>[],
        );
      }).toList(growable: false)
        ..sort((a, b) {
          final aDate = a.date ?? DateTime.fromMillisecondsSinceEpoch(0);
          final bDate = b.date ?? DateTime.fromMillisecondsSinceEpoch(0);
          return aDate.compareTo(bDate);
        });

      return entries;
    });
  }

  Future<String> currentUserLocation() async {
    final uid = currentUid;
    if (uid == null || uid.isEmpty) {
      return '';
    }
    final userDoc = await _users.doc(uid).get();
    return _userLocationFromData(userDoc.data() ?? <String, dynamic>{});
  }

  Future<GeoPoint?> currentUserGeoPoint() async {
    final uid = currentUid;
    if (uid == null || uid.isEmpty) {
      return null;
    }

    final userDoc = await _users.doc(uid).get();
    return _geoPointFromData(userDoc.data() ?? <String, dynamic>{});
  }

  int locationRank(
      {required String currentUserLocation,
      required String candidateLocation}) {
    final normalizedCurrent = currentUserLocation.trim().toLowerCase();
    final normalizedCandidate = candidateLocation.trim().toLowerCase();
    if (normalizedCurrent.isEmpty || normalizedCandidate.isEmpty) {
      return 2;
    }
    if (normalizedCurrent == normalizedCandidate) {
      return 0;
    }
    if (normalizedCurrent.contains(normalizedCandidate) ||
        normalizedCandidate.contains(normalizedCurrent)) {
      return 1;
    }
    final currentParts = normalizedCurrent
        .split(RegExp(r'[,\-]'))
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toSet();
    final candidateParts = normalizedCandidate
        .split(RegExp(r'[,\-]'))
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toSet();
    if (currentParts.intersection(candidateParts).isNotEmpty) {
      return 1;
    }
    return 2;
  }

  Stream<List<MeetNowPostEntry>> streamMeetNowPosts() {
    final uid = currentUid;
    if (uid == null || uid.isEmpty) {
      return Stream.value(const <MeetNowPostEntry>[]);
    }

    return Stream.multi((controller) {
      DocumentSnapshot<Map<String, dynamic>>? currentUserSnapshot;
      QuerySnapshot<Map<String, dynamic>>? postsSnapshot;
      StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? userSub;
      StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? postsSub;

      Future<void> emitMerged() async {
        if (currentUserSnapshot == null || postsSnapshot == null) {
          return;
        }

        final userData = currentUserSnapshot!.data() ?? <String, dynamic>{};
        final userLocation = _userLocationFromData(userData);
        final userGeo = _geoPointFromData(userData);
        final entries = <MeetNowPostEntry>[];
        final userImageUrlsCache = <String, List<String>>{};

        Future<List<String>> resolveUserImageUrls(String uid) async {
          final normalizedUid = uid.trim();
          if (normalizedUid.isEmpty) {
            return const <String>[];
          }
          final cached = userImageUrlsCache[normalizedUid];
          if (cached != null) {
            return cached;
          }

          final profile =
              await _publicUserProfileService.fetchProfile(normalizedUid);
          final profileMap = profile?.toMap() ?? <String, dynamic>{};
          final urls = <String>{
            ..._stringListValue(
                profileMap, const ['profileImageUrls', 'images']),
            (profile?.profilePictureUrl ?? '').trim(),
          }..remove('');

          final resolved = urls.toList(growable: false);
          userImageUrlsCache[normalizedUid] = resolved;
          return resolved;
        }

        for (final doc in postsSnapshot!.docs) {
          try {
            final data = doc.data();
            final status =
                (data['status'] as String? ?? 'active').trim().toLowerCase();
            if (status != 'active') {
              continue;
            }

            final authorUid = _textValue(data, const ['authorUid', 'uid']);
            if (authorUid.isEmpty) {
              continue;
            }

            final profile =
                await _publicUserProfileService.fetchProfile(authorUid);
            final profileMap = profile?.toMap() ?? <String, dynamic>{};
            final privateProfileSnap = await _users.doc(authorUid).get();
            final privateProfileData =
                privateProfileSnap.data() ?? <String, dynamic>{};
            final profileImageUrls = <String>{
              ..._stringListValue(
                profileMap,
                const ['profileImageUrls', 'images'],
              ),
              ..._stringListValue(
                privateProfileData,
                const ['profileImageUrls', 'images'],
              ),
            };
            final avatarUrl = _avatar(profile);
            if (avatarUrl.isNotEmpty) {
              profileImageUrls.add(avatarUrl);
            }
            final linkedGroupId = _textValue(data, const ['linkedGroupId']);
            int linkedMembersCount = 0;
            bool linkedGroupIsPublic = false;
            final participantImageUrls = <String>{};
            if (linkedGroupId.isNotEmpty) {
              final groupDoc = await _groups.doc(linkedGroupId).get();
              final groupData = groupDoc.data() ?? <String, dynamic>{};
              linkedMembersCount = _intValue(groupData, const ['membersCount']);
              linkedGroupIsPublic = (groupData['isPublic'] as bool?) ?? true;

              final memberUids = _groupMemberUids(groupData)
                  .where((uid) => uid != authorUid)
                  .take(10)
                  .toList(growable: false);
              for (final memberUid in memberUids) {
                final images = await resolveUserImageUrls(memberUid);
                participantImageUrls.addAll(images);
              }
            }

            entries.add(
              MeetNowPostEntry(
                id: doc.id,
                authorUid: authorUid,
                authorName: _displayName(profile, fallback: 'משתמש'),
                authorHandle: _handle(profile, fallbackUid: authorUid),
                authorAvatarUrl: avatarUrl,
                authorProfileImageUrls:
                    profileImageUrls.toList(growable: false),
                authorScore: profile?.score ?? 0,
                authorLocation: _userLocationFromData(profileMap),
                authorGeo: _geoPointFromData(profileMap),
                title: _textValue(data, const ['title']),
                details: _textValue(data, const ['details', 'description']),
                category: _textValue(data, const ['category', 'mainCategory']),
                subCategory: _textValue(data, const ['subCategory']),
                meetingLocation: _textValue(data,
                    const ['meetingLocation', 'location', 'meetingRegion']),
                meetingGeo: _geoPointFromData(data),
                desiredParticipants: data['desiredParticipants'] is num
                    ? (data['desiredParticipants'] as num).toInt()
                    : int.tryParse(
                        (data['desiredParticipants'] as String? ?? '').trim()),
                timePreference: _textValue(data, const ['timePreference']),
                minAge: data['minAge'] is num
                    ? (data['minAge'] as num).toInt()
                    : null,
                maxAge: data['maxAge'] is num
                    ? (data['maxAge'] as num).toInt()
                    : null,
                createdAt:
                    _dateValue(data, const ['createdAt']) ?? DateTime.now(),
                linkedGroupId: linkedGroupId,
                linkedGroupMembersCount: linkedMembersCount,
                linkedGroupIsPublic: linkedGroupIsPublic,
                participantProfileImageUrls:
                    participantImageUrls.toList(growable: false),
              ),
            );
          } catch (error) {
            debugPrint(
              '[AppHomeService][streamMeetNowPosts] skipping malformed meet post ${doc.id}: $error',
            );
          }
        }

        entries.sort((a, b) {
          final geoA = a.meetingGeo ?? a.authorGeo;
          final geoB = b.meetingGeo ?? b.authorGeo;
          final distanceA =
              _locationService.distanceInMeters(from: userGeo, to: geoA);
          final distanceB =
              _locationService.distanceInMeters(from: userGeo, to: geoB);

          if (distanceA != null && distanceB != null) {
            final compare = distanceA.compareTo(distanceB);
            if (compare != 0) {
              return compare;
            }
          } else if (distanceA != null) {
            return -1;
          } else if (distanceB != null) {
            return 1;
          }

          final rankA = locationRank(
            currentUserLocation: userLocation,
            candidateLocation: a.meetingLocation.isNotEmpty
                ? a.meetingLocation
                : a.authorLocation,
          );
          final rankB = locationRank(
            currentUserLocation: userLocation,
            candidateLocation: b.meetingLocation.isNotEmpty
                ? b.meetingLocation
                : b.authorLocation,
          );
          final rankCompare = rankA.compareTo(rankB);
          if (rankCompare != 0) {
            return rankCompare;
          }
          return b.createdAt.compareTo(a.createdAt);
        });

        controller.add(entries);
      }

      userSub = _users.doc(uid).snapshots().listen((snapshot) {
        currentUserSnapshot = snapshot;
        unawaited(emitMerged());
      }, onError: controller.addError);

      postsSub = _meetNowPosts.snapshots().listen((snapshot) {
        postsSnapshot = snapshot;
        unawaited(emitMerged());
      }, onError: controller.addError);

      controller.onCancel = () async {
        await userSub?.cancel();
        await postsSub?.cancel();
      };
    });
  }

  Future<void> createMeetNowPost({
    required String title,
    required String details,
    required String category,
    required String subCategory,
    required String meetingLocation,
    required int? desiredParticipants,
    required String timePreference,
    required int? minAge,
    required int? maxAge,
  }) async {
    final uid = currentUid;
    if (uid == null || uid.isEmpty) {
      throw FirebaseAuthException(
        code: 'not-authenticated',
        message: 'User must be logged in to publish.',
      );
    }

    final publishedInLastHour = await meetNowPostsPublishedInLastHour();
    if (publishedInLastHour >= 2) {
      throw const MeetNowPublishLimitException();
    }

    final normalizedTitle = title.trim();
    if (normalizedTitle.isEmpty) {
      throw ArgumentError('title is required');
    }

    final hasCompleteAgeRange = minAge != null && maxAge != null;
    if ((minAge == null) != (maxAge == null) ||
        (hasCompleteAgeRange && !isValidAgeRange(minAge, maxAge))) {
      throw ArgumentError(
        'Age range must be between $minimumUserAge and $maximumAgeRange.',
      );
    }

    final userDoc = await _users.doc(uid).get();
    final userData = userDoc.data() ?? <String, dynamic>{};
    final userGeo = _geoPointFromData(userData);
    final normalizedDetails = details.trim();

    await _meetNowPosts.add({
      'authorUid': uid,
      'title': normalizedTitle,
      'details': normalizedDetails,
      'category': category.trim(),
      'subCategory': subCategory.trim(),
      'meetingLocation': meetingLocation.trim(),
      'geo': userGeo,
      'desiredParticipants': desiredParticipants,
      'timePreference': timePreference.trim(),
      'minAge': minAge,
      'maxAge': maxAge,
      'linkedGroupId': '',
      'status': 'active',
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<String> createGroupForMeetNowPost(MeetNowPostEntry entry) async {
    final requesterUid = currentUid;
    if (requesterUid == null || requesterUid.trim().isEmpty) {
      throw FirebaseAuthException(
        code: 'not-authenticated',
        message: 'User must be logged in to join.',
      );
    }

    final normalizedRequesterUid = requesterUid.trim();
    final fallbackLinkedGroupId = entry.linkedGroupId.trim();
    if (fallbackLinkedGroupId.isNotEmpty) {
      return fallbackLinkedGroupId;
    }

    final postId = entry.id.trim();
    if (postId.isEmpty) {
      throw FirebaseException(
        plugin: 'cloud_firestore',
        code: 'invalid-argument',
        message: 'Meet-now post id is required.',
      );
    }

    final postRef = _meetNowPosts.doc(postId);

    return _db.runTransaction<String>((tx) async {
      final postSnap = await tx.get(postRef);
      if (!postSnap.exists) {
        throw FirebaseException(
          plugin: 'cloud_firestore',
          code: 'not-found',
          message: 'Meet-now post not found.',
        );
      }

      final postData = postSnap.data() ?? <String, dynamic>{};
      final currentLinkedGroupId =
          _textValue(postData, const ['linkedGroupId']);
      if (currentLinkedGroupId.isNotEmpty) {
        return currentLinkedGroupId;
      }

      final authorUid = _textValue(postData, const ['authorUid', 'uid']);
      if (authorUid.isEmpty) {
        throw FirebaseException(
          plugin: 'cloud_firestore',
          code: 'failed-precondition',
          message: 'Meet-now post is missing author uid.',
        );
      }

      final groupName = _textValue(postData, const ['title']).isNotEmpty
          ? _textValue(postData, const ['title'])
          : (entry.title.trim().isNotEmpty ? entry.title.trim() : 'פופ');
      final description =
          _textValue(postData, const ['details', 'description']).isNotEmpty
              ? _textValue(postData, const ['details', 'description'])
              : entry.details.trim();
      final category = _textValue(postData, const ['category', 'mainCategory'])
              .isNotEmpty
          ? _textValue(postData, const ['category', 'mainCategory'])
          : (entry.category.trim().isNotEmpty ? entry.category.trim() : 'כללי');
      final subCategory = _textValue(postData, const ['subCategory']).isNotEmpty
          ? _textValue(postData, const ['subCategory'])
          : entry.subCategory.trim();
      final location = _textValue(postData, const [
        'meetingLocation',
        'location',
        'meetingRegion',
      ]).isNotEmpty
          ? _textValue(postData, const [
              'meetingLocation',
              'location',
              'meetingRegion',
            ])
          : entry.meetingLocation.trim();

      final groupRef = _groups.doc();
      final groupId = groupRef.id;
      final initialMembers = <String>[authorUid];
      final initialChatParticipants = <String>{
        authorUid,
        normalizedRequesterUid,
      }.toList(growable: false);

      tx.set(groupRef, {
        'groupName': groupName,
        'description': description,
        'category': category,
        'subCategory': subCategory,
        'location': location,
        'date': Timestamp.fromDate(DateTime.now()),
        'ageRange': {
          'min': 13,
          'max': 99,
        },
        'minScore': 0,
        'isMinScoreRequired': false,
        'isPublic': true,
        'isAdminApprovalRequired': false,
        'adminUid': authorUid,
        'originType': 'pop',
        'members': initialMembers,
        'membersList': initialMembers,
        'groupImageUrl': '',
        'createdAt': FieldValue.serverTimestamp(),
        'membersCount': 1,
        'pendingCount': 0,
        'invitedFriendUids': const <String>[],
      });

      tx.set(_db.collection('chats').doc(groupId), {
        'id': groupId,
        'name': groupName,
        'description': description,
        'groupImageUrl': '',
        'isPublic': true,
        'originType': 'pop',
        'participants': initialChatParticipants,
        'sourceGroupId': groupId,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      tx.set(groupRef.collection('members').doc(authorUid), {
        'uid': authorUid,
        'status': 'approved',
        'role': 'admin',
        'joinedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      tx.set(
          postRef,
          {
            'linkedGroupId': groupId,
            'updatedAt': FieldValue.serverTimestamp(),
          },
          SetOptions(merge: true));

      return groupId;
    });
  }

  Future<List<HomeGroupMemberEntry>> fetchApprovedGroupMembers(
      String groupId) async {
    final snapshot = await _groups
        .doc(groupId)
        .collection('members')
        .where('status', isEqualTo: 'approved')
        .get();

    final entries = <HomeGroupMemberEntry>[];
    for (final doc in snapshot.docs) {
      final uid = (doc.data()['uid'] as String? ?? doc.id).trim();
      if (uid.isEmpty) {
        continue;
      }
      final profile = await _publicUserProfileService.fetchProfile(uid);
      entries.add(
        HomeGroupMemberEntry(
          uid: uid,
          name: _displayName(profile, fallback: 'משתמש'),
          handle: _handle(profile, fallbackUid: uid),
          avatarUrl: _avatar(profile),
        ),
      );
    }

    return entries;
  }
}
