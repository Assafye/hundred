import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/public_user_profile.dart';

class PublicUserProfileService {
  static final Map<String, int> _optimisticScoreDeltaByUid =
      <String, int>{};
  static final StreamController<String> _scoreDeltaChangesController =
      StreamController<String>.broadcast();

  static void addOptimisticScoreDelta({
    required String uid,
    required int delta,
  }) {
    final normalizedUid = uid.trim();
    if (normalizedUid.isEmpty || delta == 0) {
      return;
    }

    final current = _optimisticScoreDeltaByUid[normalizedUid] ?? 0;
    final next = current + delta;
    if (next == 0) {
      _optimisticScoreDeltaByUid.remove(normalizedUid);
    } else {
      _optimisticScoreDeltaByUid[normalizedUid] = next;
    }
    _scoreDeltaChangesController.add(normalizedUid);
  }

  static int optimisticScoreDeltaFor(String uid) {
    return _optimisticScoreDeltaByUid[uid.trim()] ?? 0;
  }

  final FirebaseFirestore _db;

  bool _isPermissionDenied(Object error) {
    return error is FirebaseException && error.code == 'permission-denied';
  }

  PublicUserProfileService({FirebaseFirestore? db})
      : _db = db ?? FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> get _publicUsers =>
      _db.collection('users_public');
  CollectionReference<Map<String, dynamic>> get _users =>
      _db.collection('users');

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

  int? _intValue(Map<String, dynamic> data, List<String> keys) {
    for (final key in keys) {
      if (!data.containsKey(key)) continue;
      final raw = data[key];
      if (raw is num) return raw.toInt();
      if (raw is String) {
        final parsed = int.tryParse(raw.trim());
        if (parsed != null) return parsed;
      }
    }
    return null;
  }

  Map<String, dynamic> _mergeProfileData({
    required Map<String, dynamic> publicData,
    required Map<String, dynamic> privateData,
  }) {
    final merged = <String, dynamic>{...privateData, ...publicData};

    // Prefer non-empty values from either document instead of letting empty
    // legacy public fields wipe valid private profile values.
    merged['username'] = _stringValue(
      <String, dynamic>{...publicData, ...privateData},
      const ['username'],
    );
    merged['firstName'] = _stringValue(
      <String, dynamic>{...publicData, ...privateData},
      const ['firstName'],
    );
    merged['lastName'] = _stringValue(
      <String, dynamic>{...publicData, ...privateData},
      const ['lastName'],
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
    merged['isPrivate'] = (publicData['isPrivate'] as bool?) ??
        (privateData['isPrivate'] as bool?) ??
        false;
    merged['isDeleted'] = (publicData['isDeleted'] as bool?) ??
        (privateData['isDeleted'] as bool?) ??
        false;

    final followersCount = _intValue(
      publicData,
      const ['followersCount', 'followerCount'],
    ) ??
        _intValue(privateData, const ['followersCount', 'followerCount']);
    if (followersCount != null) {
      merged['followersCount'] = followersCount;
      merged['followerCount'] = followersCount;
    }

    final followingCount = _intValue(
      publicData,
      const ['followingCount'],
    ) ??
        _intValue(privateData, const ['followingCount']);
    if (followingCount != null) {
      merged['followingCount'] = followingCount;
    }

    final publicScore = _intValue(publicData, const ['score']);
    final privateScore = _intValue(privateData, const ['score']);
    final score = publicScore == null && privateScore == null
        ? null
        : (publicScore ?? 0) > (privateScore ?? 0)
            ? publicScore
            : privateScore;
    if (score != null) {
      merged['score'] = score;
    }

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
      if (!(url.startsWith('http://') || url.startsWith('https://'))) return;
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

  Future<PublicUserProfile> _resolveProfileWithFallback(
    String uid,
    DocumentSnapshot<Map<String, dynamic>> publicSnapshot,
  ) async {
    if (publicSnapshot.exists) {
      final publicData = publicSnapshot.data() ?? <String, dynamic>{};
      DocumentSnapshot<Map<String, dynamic>>? privateSnapshot;
      try {
        privateSnapshot = await _users.doc(uid).get();
      } catch (error) {
        if (!_isPermissionDenied(error)) {
          rethrow;
        }
      }
      if (privateSnapshot == null) {
        final resolved = PublicUserProfile.fromMap(
          publicSnapshot.id,
          publicData,
        );
        return _withOptimisticScore(uid, resolved);
      }
      if (!privateSnapshot.exists) {
        final resolved = PublicUserProfile.fromMap(
          publicSnapshot.id,
          publicData,
        );
        return _withOptimisticScore(uid, resolved);
      }

      final privateData = privateSnapshot.data() ?? <String, dynamic>{};
      final merged = _mergeProfileData(
        publicData: publicData,
        privateData: privateData,
      );
      final resolved = PublicUserProfile.fromMap(
        publicSnapshot.id,
        merged,
      );
      return _withOptimisticScore(uid, resolved);
    }

    DocumentSnapshot<Map<String, dynamic>>? privateSnapshot;
    try {
      privateSnapshot = await _users.doc(uid).get();
    } catch (error) {
      if (!_isPermissionDenied(error)) {
        rethrow;
      }
    }
    if (privateSnapshot == null) {
      final fallback = PublicUserProfile.fallback(userId: uid, exists: false);
      return _withOptimisticScore(uid, fallback);
    }
    if (privateSnapshot.exists) {
      final resolved = PublicUserProfile.fromMap(
        privateSnapshot.id,
        privateSnapshot.data() ?? <String, dynamic>{},
      );
      return _withOptimisticScore(uid, resolved);
    }

    final fallback = PublicUserProfile.fallback(userId: uid, exists: false);
    return _withOptimisticScore(uid, fallback);
  }

  PublicUserProfile _withOptimisticScore(
    String uid,
    PublicUserProfile profile,
  ) {
    final delta = optimisticScoreDeltaFor(uid);
    if (delta == 0) {
      return profile;
    }

    final nextScore = (profile.score + delta).clamp(0, 1 << 30).toInt();
    return PublicUserProfile(
      userId: profile.userId,
      username: profile.username,
      displayName: profile.displayName,
      profilePictureUrl: profile.profilePictureUrl,
      profileImageUrls: profile.profileImageUrls,
      bio: profile.bio,
      isPrivate: profile.isPrivate,
      isDeleted: profile.isDeleted,
      followerCount: profile.followerCount,
      followingCount: profile.followingCount,
      score: nextScore,
      exists: profile.exists,
    );
  }

  Stream<PublicUserProfile?> streamProfile(String userId) {
    final normalizedUserId = userId.trim();
    if (normalizedUserId.isEmpty) {
      return Stream<PublicUserProfile?>.value(null);
    }

    // Return a fresh stream so new listeners always receive an immediate event
    // (cached broadcast streams do not replay the last value).
    return Stream<PublicUserProfile?>.multi((controller) {
      PublicUserProfile? latestProfile;

      Future<void> emitFromSnapshot(
        DocumentSnapshot<Map<String, dynamic>> snapshot,
      ) async {
        final resolved =
            await _resolveProfileWithFallback(normalizedUserId, snapshot);
        latestProfile = resolved;
        controller.add(resolved);
      }

      final profileSub = _publicUsers
          .doc(normalizedUserId)
          .snapshots()
          .listen((snapshot) {
        emitFromSnapshot(snapshot).catchError((error, stackTrace) {
          controller.addError(error, stackTrace);
        });
      }, onError: controller.addError);

      final deltaSub = _scoreDeltaChangesController.stream.listen((uid) {
        if (uid != normalizedUserId) {
          return;
        }

        final resolved = latestProfile;
        if (resolved != null) {
          controller.add(_withOptimisticScore(normalizedUserId, resolved));
          return;
        }

        fetchProfile(normalizedUserId).then(controller.add).catchError((
          Object error,
          StackTrace stackTrace,
        ) {
          controller.addError(error, stackTrace);
        });
      });

      controller.onCancel = () async {
        await profileSub.cancel();
        await deltaSub.cancel();
      };
    });
  }

  Future<PublicUserProfile?> fetchProfile(String userId) async {
    final normalizedUserId = userId.trim();
    if (normalizedUserId.isEmpty) {
      return null;
    }

    final snapshot = await _publicUsers.doc(normalizedUserId).get();
    return _resolveProfileWithFallback(normalizedUserId, snapshot);
  }

  PublicUserProfile fallbackProfileForPost(Map<String, dynamic> post) {
    final authorMap =
        (post['author'] as Map<String, dynamic>?) ?? <String, dynamic>{};
    final authorId = (post['authorId'] as String? ??
            post['uid'] as String? ??
            authorMap['uid'] as String? ??
            authorMap['userId'] as String? ??
            '')
        .trim();
    final username = (post['username'] as String? ??
            post['authorName'] as String? ??
            authorMap['username'] as String? ??
            '')
        .trim();
    final displayName = (post['displayName'] as String? ??
            post['authorDisplayName'] as String? ??
            authorMap['displayName'] as String? ??
            '')
        .trim();
    final profilePictureUrl = (post['profilePictureUrl'] as String? ??
            post['profileImageUrl'] as String? ??
            post['avatarUrl'] as String? ??
            post['authorProfileImg'] as String? ??
            authorMap['profilePictureUrl'] as String? ??
            authorMap['profileImageUrl'] as String? ??
            authorMap['avatarUrl'] as String? ??
            '')
        .trim();
    final bio = (post['bio'] as String? ?? '').trim();
    final isDeleted = (post['isDeleted'] as bool?) ?? false;

    return PublicUserProfile.fallback(
      userId: authorId,
      username: username,
      displayName: isDeleted ? 'משתמש מחוק' : displayName,
      profilePictureUrl: isDeleted ? '' : profilePictureUrl,
      bio: bio,
      isDeleted: isDeleted,
      followerCount: (post['followerCount'] as num?)?.toInt() ??
          (post['followersCount'] as num?)?.toInt() ??
          0,
      followingCount: (post['followingCount'] as num?)?.toInt() ?? 0,
      score: (post['score'] as num?)?.toInt() ?? 0,
      exists: false,
    );
  }

  Map<String, dynamic> injectProfileIntoPost(
    Map<String, dynamic> post,
    PublicUserProfile? profile,
  ) {
    final enriched = Map<String, dynamic>.from(post);
    if (profile == null) {
      return enriched;
    }

    enriched['author'] = profile.toMap();
    enriched['authorId'] = profile.userId.isNotEmpty
        ? profile.userId
        : (enriched['authorId'] as String? ?? enriched['uid'] as String? ?? '')
            .trim();
    enriched['uid'] = enriched['authorId'];
    enriched['username'] = profile.isDeleted ? '' : profile.username;
    enriched['authorName'] = profile.isDeleted ? 'משתמש מחוק' : profile.username;
    enriched['authorDisplayName'] = profile.displayName;
    enriched['profilePictureUrl'] = profile.profilePictureUrl;
    enriched['profileImageUrl'] = profile.profilePictureUrl;
    enriched['avatarUrl'] = profile.profilePictureUrl;
    enriched['authorProfileImg'] = profile.profilePictureUrl;
    enriched['bio'] = profile.bio;
    enriched['isPrivate'] = profile.isPrivate;
    enriched['isDeleted'] = profile.isDeleted;
    enriched['followerCount'] = profile.followerCount;
    enriched['followersCount'] = profile.followerCount;
    enriched['followingCount'] = profile.followingCount;
    enriched['score'] = profile.score;
    return enriched;
  }
}
