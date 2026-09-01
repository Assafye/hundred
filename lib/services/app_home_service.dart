import 'dart:async';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../age_restrictions.dart';
import '../models/public_user_profile.dart';
import 'block_user_service.dart';
import 'geohash_utils.dart';
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
  final List<String> participantAvatarUrls;

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
    required this.participantAvatarUrls,
  });
}

bool isUpcomingPublicGroupDateWithinWindow({
  required DateTime groupDate,
  required DateTime now,
  required DateTime windowStart,
  required DateTime windowEndExclusive,
}) {
  if (groupDate.isBefore(windowStart) || !groupDate.isBefore(windowEndExclusive)) {
    return false;
  }
  return !groupDate.isBefore(now);
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
  final double? distanceMetersFromCurrentUser;
  final int distanceSortOrder;

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
    required this.distanceMetersFromCurrentUser,
    this.distanceSortOrder = 1 << 30,
  });
}

class _MeetNowDistanceRank {
  const _MeetNowDistanceRank({
    required this.displayDistanceMeters,
    required this.sortOrder,
  });

  final double displayDistanceMeters;
  final int sortOrder;
}

// Approximate client-side distance (meters) between two geo points, used as
// a fallback ranking when the rankMeetNowPosts Cloud Function (App Check
// gated) is unavailable, so posts are never hidden solely because that
// backend call failed.
double _approximateDistanceMeters(GeoPoint a, GeoPoint b) {
  const double earthRadiusMeters = 6371000.0;
  final radians = math.pi / 180;
  final latDelta = (b.latitude - a.latitude) * radians;
  final lngDelta = (b.longitude - a.longitude) * radians;
  final sinLat = math.sin(latDelta / 2);
  final sinLng = math.sin(lngDelta / 2);
  final h = sinLat * sinLat +
      math.cos(a.latitude * radians) *
          math.cos(b.latitude * radians) *
          sinLng *
          sinLng;
  return earthRadiusMeters * 2 * math.atan2(math.sqrt(h), math.sqrt(1 - h));
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

class MeetNowStreamTelemetry {
  final int rawDocCount;
  final int emittedEntryCount;
  final int candidateLimit;
  final int activeGeoQueryCount;
  final int activePrecision;
  final int sortDurationMs;

  const MeetNowStreamTelemetry({
    required this.rawDocCount,
    required this.emittedEntryCount,
    required this.candidateLimit,
    required this.activeGeoQueryCount,
    required this.activePrecision,
    required this.sortDurationMs,
  });
}

class AppHomeService {
  static const int meetNowGeoHashPrecision = 5;
  static const List<int> _meetNowQueryPrecisions = <int>[5, 4, 3];
  static const int _minimumMeetNowCandidateLimit = 60;
  static const int _maximumMeetNowCandidateLimit = 360;
  static const String _functionsRegion = 'europe-west3';

  AppHomeService({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
    PublicUserProfileService? publicUserProfileService,
  })  : _db = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance,
      _publicUserProfileService =
        publicUserProfileService ?? PublicUserProfileService();

  final FirebaseFirestore _db;
  final FirebaseAuth _auth;
  final PublicUserProfileService _publicUserProfileService;
  final BlockUserService _blockUserService = BlockUserService();

  Future<Map<String, _MeetNowDistanceRank>> _fetchExactMeetNowDistances({
    required int candidateLimit,
  }) async {
    final response = await FirebaseFunctions.instanceFor(
      region: _functionsRegion,
    ).httpsCallable('rankMeetNowPosts').call(<String, dynamic>{
      'limit': candidateLimit,
    });
    final payload = response.data;
    if (payload is! Map) return const <String, _MeetNowDistanceRank>{};
    final rawPosts = payload['posts'];
    if (rawPosts is! List) return const <String, _MeetNowDistanceRank>{};

    final distances = <String, _MeetNowDistanceRank>{};
    for (final rawPost in rawPosts) {
      if (rawPost is! Map) continue;
      final postId = (rawPost['id'] ?? '').toString().trim();
      final distance = rawPost['distanceMeters'];
      final sortOrder = rawPost['sortOrder'];
      if (postId.isEmpty ||
          distance is! num ||
          distance < 0 ||
          sortOrder is! num ||
          sortOrder < 0) {
        continue;
      }
      distances[postId] = _MeetNowDistanceRank(
        displayDistanceMeters: distance.toDouble(),
        sortOrder: sortOrder.toInt(),
      );
    }
    return distances;
  }

  String? get currentUid => _auth.currentUser?.uid;

  CollectionReference<Map<String, dynamic>> get _users =>
      _db.collection('users');
  CollectionReference<Map<String, dynamic>> get _publicUsers =>
      _db.collection('users_public');
  CollectionReference<Map<String, dynamic>> get _userPresence =>
      _db.collection('user_presence');
  CollectionReference<Map<String, dynamic>> get _groups =>
      _db.collection('groups');
  CollectionReference<Map<String, dynamic>> get _meetNowPosts =>
      _db.collection('meet_now_posts');

    DocumentReference<Map<String, dynamic>> _privateLocationRef(String uid) =>
      _users.doc(uid).collection('private').doc('location');

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

  bool _isLikelyOnline(Map<String, dynamic> presenceData) {
    final merged = <String, dynamic>{...presenceData};
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
    Map<String, DocumentSnapshot<Map<String, dynamic>>> presenceSnapshots,
    Map<String, DocumentSnapshot<Map<String, dynamic>>> privateSnapshots,
    Map<String, DocumentSnapshot<Map<String, dynamic>>> publicSnapshots,
    List<String> orderedFriendIds,
  ) {
    final entries = <HomeFriendEntry>[];

    for (final friendUid in orderedFriendIds) {
      final presenceData =
          presenceSnapshots[friendUid]?.data() ?? <String, dynamic>{};
      final privateData =
          privateSnapshots[friendUid]?.data() ?? <String, dynamic>{};
      final publicData =
          publicSnapshots[friendUid]?.data() ?? <String, dynamic>{};
      final fallbackName = _textValue(
        publicData,
        const ['displayName', 'username'],
      ).isNotEmpty
          ? _textValue(publicData, const ['displayName', 'username'])
          : _textValue(privateData, const ['displayName', 'username']);
      final profile = publicData.isNotEmpty
          ? PublicUserProfile.fromMap(friendUid, publicData)
          : PublicUserProfile.fallback(userId: friendUid, exists: false);
      final mergedPresenceData = <String, dynamic>{
        ...privateData,
        ...presenceData,
      };
      final isOnline = _isLikelyOnline(mergedPresenceData);
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

  Stream<List<HomeFriendEntry>> streamConnectedFriends() {
    final uid = currentUid;
    if (uid == null || uid.isEmpty) {
      return Stream.value(const <HomeFriendEntry>[]);
    }

    return Stream.multi((controller) {
      StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? userSub;
      final friendPresenceSubs = <String,
          StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>>{};
      final friendProfileSubs = <String,
          StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>>{};
        final friendPrivateSubs = <String,
          StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>>{};
      final friendPresenceSnapshots =
          <String, DocumentSnapshot<Map<String, dynamic>>>{};
        final friendPrivateSnapshots =
          <String, DocumentSnapshot<Map<String, dynamic>>>{};
      final friendPublicSnapshots =
          <String, DocumentSnapshot<Map<String, dynamic>>>{};
      List<String> currentFriendIds = const <String>[];

      void emit() {
        controller.add(_friendEntriesFromSnapshots(
          friendPresenceSnapshots,
          friendPrivateSnapshots,
          friendPublicSnapshots,
          currentFriendIds,
        ));
      }

      Future<void> resetFriendSubscriptions(List<String> friendIds) async {
        final nextIds = friendIds.toSet();
        final staleIds = friendPresenceSubs.keys
            .where((id) => !nextIds.contains(id))
            .toList(growable: false);
        for (final staleId in staleIds) {
          await friendPresenceSubs.remove(staleId)?.cancel();
          await friendPrivateSubs.remove(staleId)?.cancel();
          await friendProfileSubs.remove(staleId)?.cancel();
          friendPresenceSnapshots.remove(staleId);
          friendPrivateSnapshots.remove(staleId);
          friendPublicSnapshots.remove(staleId);
        }

        for (final friendUid in friendIds) {
          if (!friendPresenceSubs.containsKey(friendUid)) {
            friendPresenceSubs[friendUid] =
                _userPresence.doc(friendUid).snapshots().listen(
              (snapshot) {
                friendPresenceSnapshots[friendUid] = snapshot;
                emit();
              },
              onError: controller.addError,
            );
          }

          if (!friendProfileSubs.containsKey(friendUid)) {
            friendProfileSubs[friendUid] =
                _publicUsers.doc(friendUid).snapshots().listen(
              (snapshot) {
                friendPublicSnapshots[friendUid] = snapshot;
                emit();
              },
              onError: controller.addError,
            );
          }

          if (!friendPrivateSubs.containsKey(friendUid)) {
            friendPrivateSubs[friendUid] = _users.doc(friendUid).snapshots().listen(
              (snapshot) {
                friendPrivateSnapshots[friendUid] = snapshot;
                emit();
              },
              onError: controller.addError,
            );
          }
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

        final mutualConnections = following.intersection(followers);
        final resolvedFriendIds = explicitFriends.isNotEmpty
          ? explicitFriends
          : (mutualConnections.isNotEmpty ? mutualConnections : following);

        currentFriendIds = resolvedFriendIds.toList(growable: false);

        await resetFriendSubscriptions(currentFriendIds);
      }, onError: controller.addError);

      controller.onCancel = () async {
        await userSub?.cancel();
        for (final sub in friendPresenceSubs.values) {
          await sub.cancel();
        }
        for (final sub in friendPrivateSubs.values) {
          await sub.cancel();
        }
        for (final sub in friendProfileSubs.values) {
          await sub.cancel();
        }
      };
    });
  }

  Stream<List<HomePublicGroupEntry>> streamUpcomingPublicGroups(
      {int withinDays = 7}) {
    // Query by public + near-date on server side to avoid applying `limit`
    // before date filtering (which can hide all relevant groups).
    return Stream.multi((controller) {
      final now = DateTime.now();
      final start = DateTime(now.year, now.month, now.day);
      final endExclusive = start.add(Duration(days: withinDays + 1));

      QuerySnapshot<Map<String, dynamic>>? dateSnapshot;
      QuerySnapshot<Map<String, dynamic>>? executionDateSnapshot;
      QuerySnapshot<Map<String, dynamic>>? fallbackSnapshot;

      StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? dateSub;
      StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? executionDateSub;
      StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? fallbackSub;

      HomePublicGroupEntry toEntry(
        QueryDocumentSnapshot<Map<String, dynamic>> doc,
      ) {
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
          participantAvatarUrls: const <String>[],
        );
      }

      bool isInRange(HomePublicGroupEntry entry) {
        final date = entry.date;
        if (date == null) {
          return false;
        }
        return isUpcomingPublicGroupDateWithinWindow(
          groupDate: date,
          now: now,
          windowStart: start,
          windowEndExclusive: endExclusive,
        );
      }

      void emitMerged() {
        final mergedById = <String, HomePublicGroupEntry>{};

        void mergeSnapshot(QuerySnapshot<Map<String, dynamic>>? snapshot) {
          if (snapshot == null) {
            return;
          }
          for (final doc in snapshot.docs) {
            final entry = toEntry(doc);
            if (!isInRange(entry)) {
              continue;
            }
            mergedById[entry.groupId] = entry;
          }
        }

        mergeSnapshot(dateSnapshot);
        mergeSnapshot(executionDateSnapshot);
        mergeSnapshot(fallbackSnapshot);

        final entries = mergedById.values.toList(growable: false)
          ..sort((a, b) {
            final aDate = a.date ?? DateTime.fromMillisecondsSinceEpoch(0);
            final bDate = b.date ?? DateTime.fromMillisecondsSinceEpoch(0);
            return aDate.compareTo(bDate);
          });

        controller.add(entries);
      }

      fallbackSub = _groups
          .where('isPublic', isEqualTo: true)
          .limit(600)
          .snapshots()
          .listen((snapshot) {
        fallbackSnapshot = snapshot;
        emitMerged();
      }, onError: (error, stackTrace) {
        debugPrint(
          '[AppHomeService][streamUpcomingPublicGroups] fallback stream failed: $error',
        );
      });

      dateSub = _groups
          .where('isPublic', isEqualTo: true)
          .where('date', isGreaterThanOrEqualTo: Timestamp.fromDate(start))
          .where('date', isLessThan: Timestamp.fromDate(endExclusive))
          .limit(200)
          .snapshots()
          .listen((snapshot) {
        dateSnapshot = snapshot;
        emitMerged();
      }, onError: (error, stackTrace) {
        if (error is FirebaseException && error.code == 'failed-precondition') {
          dateSnapshot = null;
          emitMerged();
          return;
        }
        debugPrint(
          '[AppHomeService][streamUpcomingPublicGroups] date stream failed: $error',
        );
        dateSnapshot = null;
        emitMerged();
      });

      executionDateSub = _groups
          .where('isPublic', isEqualTo: true)
          .where('executionDate',
              isGreaterThanOrEqualTo: Timestamp.fromDate(start))
          .where('executionDate', isLessThan: Timestamp.fromDate(endExclusive))
          .limit(200)
          .snapshots()
          .listen((snapshot) {
        executionDateSnapshot = snapshot;
        emitMerged();
      }, onError: (error, stackTrace) {
        if (error is FirebaseException && error.code == 'failed-precondition') {
          executionDateSnapshot = null;
          emitMerged();
          return;
        }
        debugPrint(
          '[AppHomeService][streamUpcomingPublicGroups] executionDate stream failed: $error',
        );
        executionDateSnapshot = null;
        emitMerged();
      });

      controller.onCancel = () async {
        await dateSub?.cancel();
        await executionDateSub?.cancel();
        await fallbackSub?.cancel();
      };
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

    final locationDoc = await _privateLocationRef(uid).get();
    return _geoPointFromData(locationDoc.data() ?? <String, dynamic>{});
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

  Stream<List<MeetNowPostEntry>> streamMeetNowPosts({
    int candidateLimit = _minimumMeetNowCandidateLimit,
    ValueChanged<MeetNowStreamTelemetry>? onTelemetry,
    ValueChanged<bool>? onExactDistanceRefreshStateChanged,
  }) {
    final uid = currentUid;
    if (uid == null || uid.isEmpty) {
      return Stream.value(const <MeetNowPostEntry>[]);
    }

    final effectiveCandidateLimit = candidateLimit
      .clamp(_minimumMeetNowCandidateLimit, _maximumMeetNowCandidateLimit)
      .toInt();

    return Stream.multi((controller) {
      DocumentSnapshot<Map<String, dynamic>>? currentUserSnapshot;
      GeoPoint? currentUserGeo;
      StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? userSub;
      StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? locationSub;
      StreamSubscription<Set<String>>? blockedUsersSub;
      final loggedPermissionDeniedPostIds = <String>{};
      final profileFutureByUid = <String, Future<PublicUserProfile?>>{};
      final userImageUrlsFutureByUid = <String, Future<List<String>>>{};
      final groupDocFutureById =
          <String, Future<DocumentSnapshot<Map<String, dynamic>>?>>{};
      final postDocsByQueryKey =
          <String, Map<String, QueryDocumentSnapshot<Map<String, dynamic>>>>{};
      final initializedQueryKeys = <String>{};
      final activeQueryKeys = <String>{};
      final postSubs =
          <StreamSubscription<QuerySnapshot<Map<String, dynamic>>>>[];
      String? lastMeetUserSortKey;
      var activeGeoQueryPrecisionIndex = 0;
      var activeGeoPrecision = -1;
      var emitInProgress = false;
      var emitQueued = false;
      var blockedUserIds = <String>{};
      var exactDistanceMetersByPostId = <String, _MeetNowDistanceRank>{};
      var isExactDistanceRefreshInFlight = false;
      DateTime? lastExactDistanceRefreshAt;

      List<QueryDocumentSnapshot<Map<String, dynamic>>> nearbyPostDocs() {
        final merged = <String, QueryDocumentSnapshot<Map<String, dynamic>>>{};
        for (final docs in postDocsByQueryKey.values) {
          merged.addAll(docs);
        }
        return merged.values.toList(growable: false);
      }

      Future<PublicUserProfile?> resolveProfile(String rawUid) {
        final uid = rawUid.trim();
        if (uid.isEmpty) {
          return Future<PublicUserProfile?>.value(null);
        }
        return profileFutureByUid.putIfAbsent(
          uid,
          () => _publicUserProfileService.fetchProfile(uid),
        );
      }

      Future<List<String>> resolveUserImageUrls(String rawUid) {
        final uid = rawUid.trim();
        if (uid.isEmpty) {
          return Future<List<String>>.value(const <String>[]);
        }

        return userImageUrlsFutureByUid.putIfAbsent(uid, () async {
          final profile = await resolveProfile(uid);
          final profileMap = profile?.toMap() ?? <String, dynamic>{};
          final urls = <String>{
            ..._stringListValue(profileMap, const ['profileImageUrls', 'images']),
            (profile?.profilePictureUrl ?? '').trim(),
          }..remove('');
          return urls.toList(growable: false);
        });
      }

      Future<DocumentSnapshot<Map<String, dynamic>>?> resolveGroupDoc(
        String rawGroupId,
      ) {
        final groupId = rawGroupId.trim();
        if (groupId.isEmpty) {
          return Future<DocumentSnapshot<Map<String, dynamic>>?>.value(null);
        }

        return groupDocFutureById.putIfAbsent(groupId, () async {
          try {
            return await _groups.doc(groupId).get();
          } on FirebaseException catch (error) {
            if (error.code == 'permission-denied') {
              return null;
            }
            rethrow;
          }
        });
      }

      Future<void> emitMerged() async {
        if (currentUserSnapshot == null) {
          return;
        }

        final userData = currentUserSnapshot!.data() ?? <String, dynamic>{};
        final userLocation = _userLocationFromData(userData);
        final docs = nearbyPostDocs();
        final entries = <MeetNowPostEntry>[];
        final buildFutures = docs.map((doc) async {
          try {
            final data = doc.data();
            // Prefer the exact server-ranked distance (rankMeetNowPosts), but
            // never hide a post just because that App Check-gated call
            // failed/hasn't completed yet — fall back to an approximate
            // client-side distance computed from the stored discovery geo.
            var distanceRank = exactDistanceMetersByPostId[doc.id];
            if (distanceRank == null) {
              final postGeo = data['discoveryGeo'];
              if (currentUserGeo != null && postGeo is GeoPoint) {
                final meters =
                    _approximateDistanceMeters(currentUserGeo!, postGeo);
                distanceRank = _MeetNowDistanceRank(
                  displayDistanceMeters: meters,
                  sortOrder: meters.round(),
                );
              } else {
                // No exact ranking and no geo to approximate from; still show
                // the post rather than hiding it, just without a distance.
                distanceRank = const _MeetNowDistanceRank(
                  displayDistanceMeters: -1,
                  sortOrder: 1 << 30,
                );
              }
            }
            final status =
                (data['status'] as String? ?? 'active').trim().toLowerCase();
            if (status != 'active') {
              return null;
            }

            final authorUid = _textValue(data, const ['authorUid', 'uid']);
            if (authorUid.isEmpty || blockedUserIds.contains(authorUid)) {
              return null;
            }

            final profile = await resolveProfile(authorUid);
            final profileMap = profile?.toMap() ?? <String, dynamic>{};
            final profileImageUrls = <String>{
              ..._stringListValue(
                profileMap,
                const ['profileImageUrls', 'images'],
              ),
            };
            final avatarUrl = _avatar(profile);
            if (avatarUrl.isNotEmpty) {
              profileImageUrls.add(avatarUrl);
            }
            final linkedGroupId = _textValue(data, const ['linkedGroupId']);
            var linkedGroupMembersCount = 0;
            var linkedGroupIsPublic = true;
            final participantImageUrls = <String>{};

            if (linkedGroupId.isNotEmpty) {
              final groupDoc = await resolveGroupDoc(linkedGroupId);
              final groupData = groupDoc?.data() ?? const <String, dynamic>{};
              if (groupData.isNotEmpty) {
              final membersCountField =
                _intValue(groupData, const ['membersCount']);
              final memberUids = <String>{
                ...((groupData['membersList'] as List<dynamic>?) ?? const <dynamic>[])
                  .map((item) => item.toString().trim())
                  .where((item) => item.isNotEmpty),
                ...((groupData['members'] as List<dynamic>?) ?? const <dynamic>[])
                  .map((item) => item.toString().trim())
                  .where((item) => item.isNotEmpty),
                ...((groupData['participants'] as List<dynamic>?) ?? const <dynamic>[])
                  .map((item) => item.toString().trim())
                  .where((item) => item.isNotEmpty),
                (groupData['adminUid'] as String? ?? '').trim(),
              }..remove('');

              linkedGroupMembersCount = membersCountField > 0
                ? membersCountField
                : memberUids.length;
              linkedGroupIsPublic =
                (groupData['isPublic'] as bool?) ?? linkedGroupIsPublic;

              final topUids = memberUids
                .where((uid) => uid != authorUid)
                .take(10)
                .toList(growable: false);
              final imageLists =
                await Future.wait(topUids.map(resolveUserImageUrls));
              for (final urls in imageLists) {
                participantImageUrls.addAll(urls);
              }
              }
            }
            return MeetNowPostEntry(
                id: doc.id,
                authorUid: authorUid,
                authorName: _displayName(profile, fallback: 'משתמש'),
                authorHandle: _handle(profile, fallbackUid: authorUid),
                authorAvatarUrl: avatarUrl,
                authorProfileImageUrls:
                    profileImageUrls.toList(growable: false),
                authorScore: profile?.score ?? 0,
                authorLocation: _userLocationFromData(profileMap),
                authorGeo: null,
                title: _textValue(data, const ['title']),
                details: _textValue(data, const ['details', 'description']),
                category: _textValue(data, const ['category', 'mainCategory']),
                subCategory: _textValue(data, const ['subCategory']),
                meetingLocation: _textValue(data,
                    const ['meetingLocation', 'location', 'meetingRegion']),
                meetingGeo: null,
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
                linkedGroupMembersCount: linkedGroupMembersCount,
                linkedGroupIsPublic: linkedGroupIsPublic,
                participantProfileImageUrls:
                  participantImageUrls.toList(growable: false),
                distanceMetersFromCurrentUser:
                  distanceRank.displayDistanceMeters,
                distanceSortOrder: distanceRank.sortOrder,
            );
          } catch (error) {
            if (error is FirebaseException && error.code == 'permission-denied') {
              if (loggedPermissionDeniedPostIds.add(doc.id)) {
                debugPrint(
                  '[AppHomeService][streamMeetNowPosts] permission denied for meet post ${doc.id}; showing post without restricted group data.',
                );
              }
              return null;
            }
            debugPrint(
              '[AppHomeService][streamMeetNowPosts] skipping malformed meet post ${doc.id}: $error',
            );
            return null;
          }
        }).toList(growable: false);

        final builtEntries = await Future.wait(buildFutures);
        entries.addAll(builtEntries.whereType<MeetNowPostEntry>());

        final sortStopwatch = Stopwatch()..start();
        entries.sort((a, b) {
          final distanceOrderCompare =
              a.distanceSortOrder.compareTo(b.distanceSortOrder);
          if (distanceOrderCompare != 0) {
            return distanceOrderCompare;
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
        sortStopwatch.stop();

        final emittedEntries =
            entries.take(effectiveCandidateLimit).toList(growable: false);
        onTelemetry?.call(
          MeetNowStreamTelemetry(
            rawDocCount: docs.length,
            emittedEntryCount: emittedEntries.length,
            candidateLimit: effectiveCandidateLimit,
            activeGeoQueryCount: activeQueryKeys.length,
            activePrecision: activeGeoPrecision,
            sortDurationMs: sortStopwatch.elapsedMilliseconds,
          ),
        );

        controller.add(emittedEntries);
      }

      Future<void> scheduleEmit() async {
        if (emitInProgress) {
          emitQueued = true;
          return;
        }

        emitInProgress = true;
        try {
          do {
            emitQueued = false;
            await emitMerged();
          } while (emitQueued);
        } finally {
          emitInProgress = false;
        }
      }

      Future<void> refreshExactDistanceRanking() async {
        if (isExactDistanceRefreshInFlight) {
          return;
        }
        final lastRefreshAt = lastExactDistanceRefreshAt;
        if (lastRefreshAt != null &&
            DateTime.now().difference(lastRefreshAt) <
                const Duration(seconds: 10)) {
          return;
        }

        isExactDistanceRefreshInFlight = true;
        onExactDistanceRefreshStateChanged?.call(true);
        try {
          final distances = await _fetchExactMeetNowDistances(
            candidateLimit: effectiveCandidateLimit,
          );
          exactDistanceMetersByPostId = distances;
          lastExactDistanceRefreshAt = DateTime.now();
          await scheduleEmit();
        } catch (error) {
          debugPrint(
            '[AppHomeService][streamMeetNowPosts] exact distance ranking failed: $error',
          );
        } finally {
          isExactDistanceRefreshInFlight = false;
          onExactDistanceRefreshStateChanged?.call(false);
        }
      }

      Future<void> resubscribeNearbyPosts() async {
        final existingSubs = postSubs.toList(growable: false);
        postSubs.clear();
        for (final sub in existingSubs) {
          await sub.cancel();
        }

        postDocsByQueryKey.clear();
        initializedQueryKeys.clear();
        activeQueryKeys.clear();

        final userGeo = currentUserGeo;
        if (userGeo == null) {
          activeGeoPrecision = -1;
          const fallbackKey = 'fallback';
          activeQueryKeys.add(fallbackKey);
          final fallbackSub = _meetNowPosts
              .where('status', isEqualTo: 'active')
              .orderBy('createdAt', descending: true)
              .snapshots()
              .listen((snapshot) {
            postDocsByQueryKey[fallbackKey] = {
              for (final doc in snapshot.docs) doc.id: doc,
            };
            initializedQueryKeys.add(fallbackKey);
            unawaited(scheduleEmit());
          }, onError: controller.addError);
          postSubs.add(fallbackSub);
          return;
        }

        final precision = _meetNowQueryPrecisions[activeGeoQueryPrecisionIndex];
        activeGeoPrecision = precision;
        final prefixes = GeoHashUtils.nearbyPrefixes(
          center: userGeo,
          precision: precision,
        ).toList(growable: false)
          ..sort();

        for (final prefix in prefixes) {
          activeQueryKeys.add(prefix);
          final sub = _meetNowPosts
              .where('status', isEqualTo: 'active')
              .orderBy('geohash')
              .startAt([prefix])
              .endAt(['$prefix\uf8ff'])
              .snapshots()
              .listen((snapshot) {
            postDocsByQueryKey[prefix] = {
              for (final doc in snapshot.docs) doc.id: doc,
            };
            initializedQueryKeys.add(prefix);

            if (initializedQueryKeys.length == activeQueryKeys.length &&
                nearbyPostDocs().length < effectiveCandidateLimit &&
                activeGeoQueryPrecisionIndex <
                    _meetNowQueryPrecisions.length - 1) {
              activeGeoQueryPrecisionIndex += 1;
              unawaited(resubscribeNearbyPosts());
              return;
            }

            unawaited(scheduleEmit());
          }, onError: controller.addError);
          postSubs.add(sub);
        }
      }

      void refreshMeetNowQueries() {
        final data = currentUserSnapshot?.data() ?? <String, dynamic>{};
        final location = _userLocationFromData(data).trim().toLowerCase();
        final latKey = currentUserGeo?.latitude.toStringAsFixed(5) ?? '';
        final lngKey = currentUserGeo?.longitude.toStringAsFixed(5) ?? '';
        final nextSortKey = '$latKey|$lngKey|$location';

        // Presence/status writes can update the user doc frequently; only
        // recompute meet-now ordering when location/sort inputs changed.
        if (nextSortKey == lastMeetUserSortKey) {
          return;
        }

        lastMeetUserSortKey = nextSortKey;
        activeGeoQueryPrecisionIndex = 0;
        unawaited(resubscribeNearbyPosts());
        if (currentUserGeo != null) {
          unawaited(refreshExactDistanceRanking());
        }
        unawaited(scheduleEmit());
      }

      userSub = _users.doc(uid).snapshots().listen((snapshot) {
        currentUserSnapshot = snapshot;
        refreshMeetNowQueries();
      }, onError: controller.addError);

      locationSub = _privateLocationRef(uid).snapshots().listen((snapshot) {
        currentUserGeo = _geoPointFromData(snapshot.data() ?? <String, dynamic>{});
        if (currentUserGeo == null) {
          onExactDistanceRefreshStateChanged?.call(false);
        }
        refreshMeetNowQueries();
      }, onError: (error, stackTrace) {
        onExactDistanceRefreshStateChanged?.call(false);
        controller.addError(error, stackTrace);
      });

      blockedUsersSub = _blockUserService.streamBlockedConnections().listen(
        (ids) {
          blockedUserIds = ids;
          unawaited(scheduleEmit());
        },
        onError: (_) {
          blockedUserIds = const <String>{};
          unawaited(scheduleEmit());
        },
      );

      controller.onCancel = () async {
        await userSub?.cancel();
        for (final sub in postSubs) {
          await sub.cancel();
        }
        await locationSub?.cancel();
        await blockedUsersSub?.cancel();
      };
    });
  }

  Stream<Set<String>> streamJoinedMeetNowPostIds() {
    final uid = currentUid;
    if (uid == null || uid.isEmpty) {
      return Stream.value(const <String>{});
    }

    return _db
        .collection('users')
        .doc(uid)
        .collection('activity')
        .where('type', isEqualTo: 'pop_join')
        .snapshots()
        .map((snapshot) {
      final ids = <String>{};
      for (final doc in snapshot.docs) {
        final postId = (doc.data()['postId'] as String? ?? '').trim();
        if (postId.isNotEmpty) {
          ids.add(postId);
        }
      }
      return ids;
    });
  }

  Future<void> registerMeetNowJoin({
    required MeetNowPostEntry entry,
    required String groupId,
  }) async {
    final uid = currentUid;
    if (uid == null || uid.trim().isEmpty) {
      throw FirebaseAuthException(
        code: 'not-authenticated',
        message: 'User must be logged in to join.',
      );
    }

    final normalizedUid = uid.trim();
    final normalizedPostId = entry.id.trim();
    final normalizedGroupId = groupId.trim();
    if (normalizedPostId.isEmpty || normalizedGroupId.isEmpty) {
      return;
    }

    final activityRef = _db
        .collection('users')
        .doc(normalizedUid)
        .collection('activity')
        .doc('pop_join_${normalizedPostId}_$normalizedGroupId');
    final joinedAtNow = Timestamp.now();

    await activityRef.set(<String, dynamic>{
      'type': 'pop_join',
      'uid': normalizedUid,
      'postId': normalizedPostId,
      'linkedGroupId': normalizedGroupId,
      'authorUid': entry.authorUid,
      'title': entry.title.trim(),
      'description': entry.details.trim(),
      'meetingLocation': entry.meetingLocation.trim(),
      'timePreference': entry.timePreference.trim(),
      'category': entry.category.trim(),
      'subCategory': entry.subCategory.trim(),
      'desiredParticipants': entry.desiredParticipants,
      'minAge': entry.minAge,
      'maxAge': entry.maxAge,
      'createdAt': joinedAtNow,
      'joinedAt': joinedAtNow,
      'serverCreatedAt': FieldValue.serverTimestamp(),
      'serverJoinedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    if (entry.linkedGroupId.trim().isEmpty) {
      try {
        await _meetNowPosts.doc(normalizedPostId).set(
          <String, dynamic>{
            'linkedGroupId': normalizedGroupId,
            'updatedAt': FieldValue.serverTimestamp(),
          },
          SetOptions(merge: true),
        );
      } catch (_) {
        // Best effort: history + hiding still rely on local join activity.
      }
    }
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

    final locationDoc = await _privateLocationRef(uid).get();
    final userGeo = _geoPointFromData(
      locationDoc.data() ?? <String, dynamic>{},
    );
    final normalizedDetails = details.trim();

    final payload = <String, dynamic>{
      'authorUid': uid,
      'title': normalizedTitle,
      'details': normalizedDetails,
      'category': category.trim(),
      'subCategory': subCategory.trim(),
      'meetingLocation': meetingLocation.trim(),
      'desiredParticipants': desiredParticipants,
      'timePreference': timePreference.trim(),
      'minAge': minAge,
      'maxAge': maxAge,
      'linkedGroupId': '',
      'status': 'active',
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    };
    if (userGeo != null) {
      final discoveryGeo = GeoHashUtils.snapToCellCenter(
        userGeo,
        precision: meetNowGeoHashPrecision,
      );
      payload['discoveryGeo'] = discoveryGeo;
      payload['geohash'] = GeoHashUtils.encodeGeoPoint(
        discoveryGeo,
        precision: meetNowGeoHashPrecision,
      );
    }

    await _meetNowPosts.add(payload);
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

    try {
      final existingGroup = await _groups
          .where('originMeetPostId', isEqualTo: postId)
          .limit(1)
          .get();
      if (existingGroup.docs.isNotEmpty) {
        return existingGroup.docs.first.id;
      }
    } catch (_) {}

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
      final effectiveAdminUid = authorUid;
      final initialMembers = <String>[effectiveAdminUid];
      final initialChatParticipants = <String>{
        effectiveAdminUid,
        normalizedRequesterUid,
      }.toList(growable: false);

      tx.set(groupRef, {
        'groupName': groupName,
        'description': description,
        'category': category,
        'subCategory': subCategory,
        'location': location,
        'date': Timestamp.fromDate(
          DateTime.now().add(const Duration(hours: 24)),
        ),
        'ageRange': {
          'min': 13,
          'max': 99,
        },
        'minScore': 0,
        'isMinScoreRequired': false,
        'isPublic': true,
        'isAdminApprovalRequired': false,
        'adminUid': effectiveAdminUid,
        'originAuthorUid': authorUid,
        'originMeetPostId': postId,
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
        'isDirect': false,
        'originType': 'pop',
        'participants': initialChatParticipants,
        'sourceGroupId': groupId,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      if (normalizedRequesterUid == effectiveAdminUid) {
        tx.set(groupRef.collection('members').doc(effectiveAdminUid), {
          'uid': effectiveAdminUid,
          'status': 'approved',
          'role': 'admin',
          'joinedAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        });
      }

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
