import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import 'block_user_service.dart';
import 'notification_service.dart';
import 'public_user_profile_service.dart';
import 'secure_action_queue_service.dart';

enum FollowActionResult {
  followed,
  requestSent,
  alreadyFollowing,
  alreadyRequested,
}

class FollowRelationship {
  final bool isFollowing;
  final bool isRequestPending;

  const FollowRelationship({
    this.isFollowing = false,
    this.isRequestPending = false,
  });
}

class SocialService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final NotificationService _notificationService = NotificationService();
  final BlockUserService _blockUserService = BlockUserService();
  final SecureActionQueueService _secureQueue = SecureActionQueueService();

  String get _currentUid {
    final uid = _auth.currentUser?.uid;
    if (uid == null || uid.isEmpty) {
      throw FirebaseAuthException(
        code: 'not-authenticated',
        message: 'User must be logged in to perform this action.',
      );
    }
    return uid;
  }

  Set<String> _readUidSet(Map<String, dynamic>? data, String key) {
    final raw = data?[key];
    if (raw is! List) {
      return <String>{};
    }
    return raw
        .map((e) => e.toString())
        .where((value) => value.trim().isNotEmpty)
        .toSet();
  }

  Map<String, dynamic> _publicCountersPayload({
    required int followersCount,
    required int followingCount,
    Set<String>? followers,
    Set<String>? following,
  }) {
    List<String>? sortedFollowers;
    if (followers != null) {
      sortedFollowers = followers.toList(growable: false)..sort();
    }

    List<String>? sortedFollowing;
    if (following != null) {
      sortedFollowing = following.toList(growable: false)..sort();
    }

    return <String, dynamic>{
      'followersCount': followersCount,
      'followingCount': followingCount,
      if (sortedFollowers != null) 'followers': sortedFollowers,
      if (sortedFollowing != null) 'following': sortedFollowing,
    };
  }

  bool _isPrivateUser(
      Map<String, dynamic>? privateData, Map<String, dynamic>? publicData) {
    return (privateData?['isPrivate'] as bool?) ??
        (publicData?['isPrivate'] as bool?) ??
        false;
  }

  int _uidCount(Set<String> values) => values.length;

  static int followerScoreDelta({required bool isAdding}) {
    return isAdding ? 50 : -50;
  }

  void _applyFollowerOptimisticScoreDelta({
    required String targetUid,
    required bool isAdding,
  }) {
    if (targetUid.trim().isEmpty) {
      return;
    }

    PublicUserProfileService.addOptimisticScoreDelta(
      uid: targetUid,
      delta: followerScoreDelta(isAdding: isAdding),
    );
  }

  bool _isPermissionDenied(Object error) {
    return error is FirebaseException && error.code == 'permission-denied';
  }

  Future<FollowActionResult> _followUserSelfOnlyFallback({
    required String myUid,
    required String targetUid,
  }) async {
    final myUserRef = _db.collection('users').doc(myUid);
    final myPublicUserRef = _db.collection('users_public').doc(myUid);
    final targetUserRef = _db.collection('users').doc(targetUid);
    final targetPublicUserRef = _db.collection('users_public').doc(targetUid);
    final targetPublicSnap = await targetPublicUserRef.get();

    final targetPublicData = targetPublicSnap.data() ?? <String, dynamic>{};
    final isPrivateTarget = _isPrivateUser(null, targetPublicData);

    final mySnap = await myUserRef.get();
    final myData = mySnap.data() ?? <String, dynamic>{};
    final myFollowing = _readUidSet(myData, 'following');
    final mySentRequests = _readUidSet(myData, 'sentFollowRequests');
    final myFollowers = _readUidSet(myData, 'followers');

    if (isPrivateTarget) {
      if (mySentRequests.contains(targetUid)) {
        return FollowActionResult.alreadyRequested;
      }
      await myUserRef.set(
        {
          'sentFollowRequests': FieldValue.arrayUnion(<String>[targetUid]),
        },
        SetOptions(merge: true),
      );
      return FollowActionResult.requestSent;
    }

    if (myFollowing.contains(targetUid)) {
      return FollowActionResult.alreadyFollowing;
    }

    final nextFollowing = <String>{...myFollowing, targetUid};
    final targetSnap = await targetUserRef.get();
    final targetData = targetSnap.data() ?? <String, dynamic>{};
    final nextTargetFollowers = _readUidSet(targetData, 'followers')..add(myUid);
    final targetCurrentScore = (targetData['score'] as num?)?.toInt() ?? 0;
    final nextTargetScore = targetCurrentScore + followerScoreDelta(isAdding: true);

    await myUserRef.set(
      {
        'following': FieldValue.arrayUnion(<String>[targetUid]),
        'followingCount': nextFollowing.length,
      },
      SetOptions(merge: true),
    );
    await myPublicUserRef.set(
      _publicCountersPayload(
        followersCount: myFollowers.length,
        followingCount: nextFollowing.length,
        followers: myFollowers,
        following: nextFollowing,
      ),
      SetOptions(merge: true),
    );

    await targetUserRef.set(
      {
        'followers': FieldValue.arrayUnion(<String>[myUid]),
        'followersCount': nextTargetFollowers.length,
        'score': nextTargetScore,
      },
      SetOptions(merge: true),
    );
    await targetPublicUserRef.set(
      {
        'followers': nextTargetFollowers.toList(growable: false)..sort(),
        'followersCount': nextTargetFollowers.length,
        'score': nextTargetScore,
      },
      SetOptions(merge: true),
    );

    return FollowActionResult.followed;
  }

  Future<void> _unfollowSelfOnlyFallback({
    required String myUid,
    required String targetUid,
  }) async {
    final myUserRef = _db.collection('users').doc(myUid);
    final myPublicUserRef = _db.collection('users_public').doc(myUid);

    final mySnap = await myUserRef.get();
    final myData = mySnap.data() ?? <String, dynamic>{};
    final myFollowing = _readUidSet(myData, 'following')..remove(targetUid);
    final myFollowers = _readUidSet(myData, 'followers');

    await myUserRef.set(
      {
        'following': FieldValue.arrayRemove(<String>[targetUid]),
        'sentFollowRequests': FieldValue.arrayRemove(<String>[targetUid]),
        'followingCount': myFollowing.length,
      },
      SetOptions(merge: true),
    );
    await myPublicUserRef.set(
      _publicCountersPayload(
        followersCount: myFollowers.length,
        followingCount: myFollowing.length,
        followers: myFollowers,
        following: myFollowing,
      ),
      SetOptions(merge: true),
    );

    _applyFollowerOptimisticScoreDelta(
      targetUid: targetUid,
      isAdding: false,
    );
  }

  Future<void> _removeFollowerSelfOnlyFallback({
    required String myUid,
    required String followerUid,
  }) async {
    final myUserRef = _db.collection('users').doc(myUid);
    final myPublicUserRef = _db.collection('users_public').doc(myUid);

    final mySnap = await myUserRef.get();
    final myData = mySnap.data() ?? <String, dynamic>{};
    final myFollowers = _readUidSet(myData, 'followers')..remove(followerUid);
    final myFollowing = _readUidSet(myData, 'following');

    await myUserRef.set(
      {
        'followers': FieldValue.arrayRemove(<String>[followerUid]),
        'followersCount': myFollowers.length,
      },
      SetOptions(merge: true),
    );

    await myPublicUserRef.set(
      _publicCountersPayload(
        followersCount: myFollowers.length,
        followingCount: myFollowing.length,
        followers: myFollowers,
        following: myFollowing,
      ),
      SetOptions(merge: true),
    );
  }

  Future<FollowActionResult> followUser(String targetUid) async {
    final myUid = _currentUid;
    if (targetUid.isEmpty) {
      throw ArgumentError('targetUid cannot be empty');
    }
    if (targetUid == myUid) {
      throw FirebaseAuthException(
        code: 'invalid-action',
        message: 'You cannot follow yourself.',
      );
    }

    final isBlocked = await _blockUserService.isEitherUserBlocked(targetUid);
    if (isBlocked) {
      throw FirebaseAuthException(
        code: 'blocked-user',
        message: 'חסימה פעילה בין המשתמשים. לא ניתן לעקוב.',
      );
    }

    final myUserRef = _db.collection('users').doc(myUid);
    final targetUserRef = _db.collection('users').doc(targetUid);
    final myPublicUserRef = _db.collection('users_public').doc(myUid);
    final targetPublicUserRef = _db.collection('users_public').doc(targetUid);

    debugPrint(
      '[Follow Debug] currentUid=$myUid, targetUid=$targetUid, '
      'paths=[${myUserRef.path}, ${targetUserRef.path}, ${myPublicUserRef.path}, ${targetPublicUserRef.path}]',
    );

    var didCreateFollow = false;
    var becameFriends = false;
    var didCreateRequest = false;
    var result = FollowActionResult.followed;

    try {
      await _db.runTransaction((tx) async {
        final myUserSnap = await tx.get(myUserRef);
        final targetUserSnap = await tx.get(targetUserRef);
        final targetPublicUserSnap = await tx.get(targetPublicUserRef);

        final myData = myUserSnap.data() ?? <String, dynamic>{};
        final targetData = targetUserSnap.data() ?? <String, dynamic>{};

        final myFollowing = _readUidSet(myData, 'following');
        final myPendingRequests = _readUidSet(myData, 'sentFollowRequests');
        final targetRequests = _readUidSet(targetData, 'followRequests');
        final targetPublicData =
            targetPublicUserSnap.data() ?? <String, dynamic>{};
        final isPrivateTarget = _isPrivateUser(targetData, targetPublicData);

        final alreadyFollowing = myFollowing.contains(targetUid);
        final alreadyRequested = myPendingRequests.contains(targetUid) ||
            targetRequests.contains(myUid);

        if (alreadyFollowing) {
          result = FollowActionResult.alreadyFollowing;
          didCreateFollow = false;
          becameFriends = false;
          return;
        }

        if (isPrivateTarget) {
          if (alreadyRequested) {
            result = FollowActionResult.alreadyRequested;
            didCreateRequest = false;
            return;
          }

          didCreateRequest = true;
          result = FollowActionResult.requestSent;

          tx.set(
            myUserRef,
            {
              'sentFollowRequests': FieldValue.arrayUnion(<String>[targetUid]),
            },
            SetOptions(merge: true),
          );
          return;
        }

        didCreateFollow = true;
        becameFriends = _readUidSet(targetData, 'following').contains(myUid);
        result = FollowActionResult.followed;

        myFollowing.add(targetUid);

        final myUserUpdate = <String, dynamic>{
          'following': FieldValue.arrayUnion(<String>[targetUid]),
          'followingCount': myFollowing.length,
        };
        final myPublicUpdate = _publicCountersPayload(
          followersCount: _readUidSet(myData, 'followers').length,
          followingCount: myFollowing.length,
          followers: _readUidSet(myData, 'followers'),
          following: myFollowing,
        );

        debugPrint('[Follow Debug] update ${myUserRef.path}: $myUserUpdate');
        debugPrint(
            '[Follow Debug] update ${myPublicUserRef.path}: $myPublicUpdate');

        tx.set(
          myUserRef,
          myUserUpdate,
          SetOptions(merge: true),
        );

        tx.set(
          myPublicUserRef,
          myPublicUpdate,
          SetOptions(merge: true),
        );
      });
    } catch (e) {
      if (_isPermissionDenied(e)) {
        debugPrint(
            '[Follow Debug] permission-denied while writing own follow state; queueing secure action');
      }
      debugPrint('[Follow Debug] Firestore follow failed: ${e.toString()}');
    }

    await _secureQueue.enqueue(
      type: SecureActionTypes.followUser,
      payload: <String, dynamic>{
        'targetUid': targetUid,
      },
      dedupeKey: 'follow:$myUid:$targetUid',
    );

    if (didCreateFollow) {
      _applyFollowerOptimisticScoreDelta(
        targetUid: targetUid,
        isAdding: true,
      );
    }

    if (didCreateFollow) {
      try {
        await _notificationService.sendFollowNotification(
          recipientUid: targetUid,
          followerUid: myUid,
        );
      } catch (error) {
        debugPrint(
          '[Follow Debug] follow notification failed (non-blocking): '
          '${error.toString()}',
        );
      }
    }

    if (becameFriends) {
      try {
        await _notificationService.sendFriendshipNotification(
          recipientUid: targetUid,
          friendUid: myUid,
        );
      } catch (error) {
        debugPrint(
          '[Follow Debug] friendship notification(to target) failed '
          '(non-blocking): ${error.toString()}',
        );
      }

      try {
        await _notificationService.sendFriendshipNotification(
          recipientUid: myUid,
          friendUid: targetUid,
        );
      } catch (error) {
        debugPrint(
          '[Follow Debug] friendship notification(to current user) failed '
          '(non-blocking): ${error.toString()}',
        );
      }
    }

    if (didCreateRequest) {
      // Intentionally not emitting a new-follower notification for private
      // accounts until the request is approved.
    }

    return result;
  }

  Future<void> unfollowUser(String targetUid) async {
    final myUid = _currentUid;
    if (targetUid.isEmpty) {
      throw ArgumentError('targetUid cannot be empty');
    }
    if (targetUid == myUid) {
      return;
    }

    final myUserRef = _db.collection('users').doc(myUid);
    final targetUserRef = _db.collection('users').doc(targetUid);
    final myPublicUserRef = _db.collection('users_public').doc(myUid);
    final targetPublicUserRef = _db.collection('users_public').doc(targetUid);

    try {
      await _db.runTransaction((tx) async {
        final myUserSnap = await tx.get(myUserRef);
        final targetUserSnap = await tx.get(targetUserRef);
        final targetPublicUserSnap = await tx.get(targetPublicUserRef);

        final myData = myUserSnap.data() ?? <String, dynamic>{};
        final targetData = targetUserSnap.data() ?? <String, dynamic>{};

        final myFollowing = _readUidSet(myData, 'following')..remove(targetUid);
        final myPendingRequests = _readUidSet(myData, 'sentFollowRequests');
        final targetFollowers = _readUidSet(targetData, 'followers')
          ..remove(myUid);
        final targetRequests = _readUidSet(targetData, 'followRequests');
        final myFollowers = _readUidSet(myData, 'followers');
        final targetFollowing = _readUidSet(targetData, 'following');

        tx.set(
          myUserRef,
          {
            'following': FieldValue.arrayRemove(<String>[targetUid]),
            'followingCount': myFollowing.length,
            if (myPendingRequests.contains(targetUid))
              'sentFollowRequests': FieldValue.arrayRemove(<String>[targetUid]),
          },
          SetOptions(merge: true),
        );

        tx.update(
          targetUserRef,
          {
            'followers': FieldValue.arrayRemove(<String>[myUid]),
            'followersCount': targetFollowers.length,
            if (targetRequests.contains(myUid))
              'followRequests': FieldValue.arrayRemove(<String>[myUid]),
          },
        );

        tx.set(
          myPublicUserRef,
          _publicCountersPayload(
            followersCount: myFollowers.length,
            followingCount: myFollowing.length,
            followers: myFollowers,
            following: myFollowing,
          ),
          SetOptions(merge: true),
        );

        if (targetPublicUserSnap.exists) {
          tx.update(
            targetPublicUserRef,
            _publicCountersPayload(
              followersCount: targetFollowers.length,
              followingCount: targetFollowing.length,
              followers: targetFollowers,
              following: targetFollowing,
            ),
          );
        }
      });
    } catch (e) {
      if (_isPermissionDenied(e)) {
        debugPrint(
            '[Follow Debug] permission-denied on unfollow; applying self-only fallback');
        await _unfollowSelfOnlyFallback(myUid: myUid, targetUid: targetUid);
        await _secureQueue.enqueue(
          type: SecureActionTypes.unfollowUser,
          payload: <String, dynamic>{
            'targetUid': targetUid,
          },
          dedupeKey: 'unfollow:$myUid:$targetUid',
        );
        return;
      }
      rethrow;
    }

    try {
      final penalty = followerScoreDelta(isAdding: false);
      await _db.collection('users').doc(targetUid).set(
        {'score': FieldValue.increment(penalty)},
        SetOptions(merge: true),
      );
      await _db.collection('users_public').doc(targetUid).set(
        {'score': FieldValue.increment(penalty)},
        SetOptions(merge: true),
      );
      _applyFollowerOptimisticScoreDelta(
        targetUid: targetUid,
        isAdding: false,
      );
    } catch (error) {
      debugPrint(
        '[Follow Debug] score deduction for unfollow failed: ${error.toString()}',
      );
      _applyFollowerOptimisticScoreDelta(
        targetUid: targetUid,
        isAdding: false,
      );
    }
  }

  Stream<bool> isFollowing(String targetUid) {
    final uid = _auth.currentUser?.uid;
    if (uid == null || uid.isEmpty || targetUid.isEmpty || targetUid == uid) {
      return Stream<bool>.value(false);
    }

    return _db.collection('users').doc(uid).snapshots().map((doc) {
      final following = _readUidSet(doc.data(), 'following');
      return following.contains(targetUid);
    });
  }

  Stream<FollowRelationship> watchFollowRelationship(String targetUid) {
    final uid = _auth.currentUser?.uid;
    final normalizedTargetUid = targetUid.trim();
    if (uid == null ||
        uid.isEmpty ||
        normalizedTargetUid.isEmpty ||
        normalizedTargetUid == uid) {
      return Stream<FollowRelationship>.value(const FollowRelationship());
    }

    return _db.collection('users').doc(uid).snapshots().map((doc) {
      final following = _readUidSet(doc.data(), 'following');
      final sentRequests = _readUidSet(doc.data(), 'sentFollowRequests');
      return FollowRelationship(
        isFollowing: following.contains(normalizedTargetUid),
        isRequestPending: sentRequests.contains(normalizedTargetUid),
      );
    });
  }

  Stream<List<String>> incomingFollowRequestsStream() {
    final uid = _auth.currentUser?.uid;
    if (uid == null || uid.isEmpty) {
      return Stream<List<String>>.value(const <String>[]);
    }

    return _db.collection('users').doc(uid).snapshots().map((doc) {
      final requests =
          _readUidSet(doc.data(), 'followRequests').toList(growable: false);
      requests.sort();
      return requests;
    });
  }

  Future<bool> isFollowingUser(String targetUid) async {
    final myUid = _auth.currentUser?.uid;
    final normalizedTargetUid = targetUid.trim();
    if (myUid == null ||
        myUid.isEmpty ||
        normalizedTargetUid.isEmpty ||
        normalizedTargetUid == myUid) {
      return true;
    }

    final mySnapshot = await _db.collection('users').doc(myUid).get();
    final myFollowingIds = _readUidSet(mySnapshot.data(), 'following');
    return myFollowingIds.contains(normalizedTargetUid);
  }

  Future<bool> canViewPrivateProfileContent(String targetUid) async {
    final myUid = _auth.currentUser?.uid;
    final normalizedTargetUid = targetUid.trim();
    if (myUid == null ||
        myUid.isEmpty ||
        normalizedTargetUid.isEmpty ||
        normalizedTargetUid == myUid) {
      return true;
    }

    final isBlocked =
        await _blockUserService.isEitherUserBlocked(normalizedTargetUid);
    if (isBlocked) {
      return false;
    }

    final targetPublicSnapshot =
        await _db.collection('users_public').doc(normalizedTargetUid).get();
    final targetPublicData = targetPublicSnapshot.data() ?? <String, dynamic>{};
    final isPrivateTarget = _isPrivateUser(null, targetPublicData);
    if (!isPrivateTarget) {
      return true;
    }

    final mySnapshot = await _db.collection('users').doc(myUid).get();
    final myFollowing = _readUidSet(mySnapshot.data(), 'following');
    return myFollowing.contains(normalizedTargetUid);
  }

  Future<void> cancelFollowRequest(String targetUid) async {
    final myUid = _currentUid;
    final normalizedTargetUid = targetUid.trim();
    if (normalizedTargetUid.isEmpty || normalizedTargetUid == myUid) {
      return;
    }

    final myUserRef = _db.collection('users').doc(myUid);
    final targetUserRef = _db.collection('users').doc(normalizedTargetUid);

    try {
      await _db.runTransaction((tx) async {
        tx.set(
          myUserRef,
          {
            'sentFollowRequests':
                FieldValue.arrayRemove(<String>[normalizedTargetUid]),
          },
          SetOptions(merge: true),
        );

        tx.set(
          targetUserRef,
          {
            'followRequests': FieldValue.arrayRemove(<String>[myUid]),
          },
          SetOptions(merge: true),
        );
      });
    } catch (e) {
      if (_isPermissionDenied(e)) {
        await myUserRef.set(
          {
            'sentFollowRequests':
                FieldValue.arrayRemove(<String>[normalizedTargetUid]),
          },
          SetOptions(merge: true),
        );
        await _secureQueue.enqueue(
          type: SecureActionTypes.cancelFollowRequest,
          payload: <String, dynamic>{
            'targetUid': normalizedTargetUid,
          },
          dedupeKey: 'cancel_request:$myUid:$normalizedTargetUid',
        );
        return;
      }
      rethrow;
    }
  }

  Future<void> approveFollowRequest(String requesterUid) async {
    final myUid = _currentUid;
    final normalizedRequesterUid = requesterUid.trim();
    if (normalizedRequesterUid.isEmpty || normalizedRequesterUid == myUid) {
      return;
    }

    final myUserRef = _db.collection('users').doc(myUid);
    final requesterUserRef =
        _db.collection('users').doc(normalizedRequesterUid);
    final myPublicUserRef = _db.collection('users_public').doc(myUid);
    final requesterPublicUserRef =
        _db.collection('users_public').doc(normalizedRequesterUid);

    var becameFriends = false;

    await _db.runTransaction((tx) async {
      final myUserSnap = await tx.get(myUserRef);
      final requesterUserSnap = await tx.get(requesterUserRef);
      final myPublicSnap = await tx.get(myPublicUserRef);
      final requesterPublicSnap = await tx.get(requesterPublicUserRef);

      final myData = myUserSnap.data() ?? <String, dynamic>{};
      final requesterData = requesterUserSnap.data() ?? <String, dynamic>{};

      final myFollowers = _readUidSet(myData, 'followers');
      final myFollowing = _readUidSet(myData, 'following');
      final myRequests = _readUidSet(myData, 'followRequests');
      final requesterFollowing = _readUidSet(requesterData, 'following');
      final requesterFollowers = _readUidSet(requesterData, 'followers');
      final requesterSentRequests =
          _readUidSet(requesterData, 'sentFollowRequests');

      final alreadyFollowing = requesterFollowing.contains(myUid);
      if (!alreadyFollowing) {
        requesterFollowing.add(myUid);
        myFollowers.add(normalizedRequesterUid);
      }
      myRequests.remove(normalizedRequesterUid);
      requesterSentRequests.remove(myUid);

      becameFriends = myFollowing.contains(normalizedRequesterUid);

      tx.set(
        myUserRef,
        {
          'followers': FieldValue.arrayUnion(<String>[normalizedRequesterUid]),
          'followersCount': _uidCount(myFollowers),
          'followRequests':
              FieldValue.arrayRemove(<String>[normalizedRequesterUid]),
        },
        SetOptions(merge: true),
      );

      tx.set(
        requesterUserRef,
        {
          'following': FieldValue.arrayUnion(<String>[myUid]),
          'followingCount': _uidCount(requesterFollowing),
          'sentFollowRequests': FieldValue.arrayRemove(<String>[myUid]),
        },
        SetOptions(merge: true),
      );

      tx.set(
        myPublicUserRef,
        _publicCountersPayload(
          followersCount: _uidCount(myFollowers),
          followingCount: _uidCount(myFollowing),
          followers: myFollowers,
          following: myFollowing,
        ),
        SetOptions(merge: true),
      );

      tx.set(
        requesterPublicUserRef,
        _publicCountersPayload(
          followersCount: _uidCount(requesterFollowers),
          followingCount: _uidCount(requesterFollowing),
          followers: requesterFollowers,
          following: requesterFollowing,
        ),
        SetOptions(merge: true),
      );

      if (!myPublicSnap.exists) {
        tx.set(
          myPublicUserRef,
          _publicCountersPayload(
            followersCount: _uidCount(myFollowers),
            followingCount: _uidCount(myFollowing),
            followers: myFollowers,
            following: myFollowing,
          ),
          SetOptions(merge: true),
        );
      }

      if (!requesterPublicSnap.exists) {
        tx.set(
          requesterPublicUserRef,
          _publicCountersPayload(
            followersCount: _uidCount(requesterFollowers),
            followingCount: _uidCount(requesterFollowing),
            followers: requesterFollowers,
            following: requesterFollowing,
          ),
          SetOptions(merge: true),
        );
      }
    });

    await _notificationService.sendFollowNotification(
      recipientUid: myUid,
      followerUid: normalizedRequesterUid,
    );

    if (becameFriends) {
      await _notificationService.sendFriendshipNotification(
        recipientUid: myUid,
        friendUid: normalizedRequesterUid,
      );
      await _notificationService.sendFriendshipNotification(
        recipientUid: normalizedRequesterUid,
        friendUid: myUid,
      );
    }
  }

  Future<void> rejectFollowRequest(String requesterUid) async {
    final myUid = _currentUid;
    final normalizedRequesterUid = requesterUid.trim();
    if (normalizedRequesterUid.isEmpty || normalizedRequesterUid == myUid) {
      return;
    }

    final myUserRef = _db.collection('users').doc(myUid);
    final requesterUserRef =
        _db.collection('users').doc(normalizedRequesterUid);

    await _db.runTransaction((tx) async {
      tx.set(
        myUserRef,
        {
          'followRequests':
              FieldValue.arrayRemove(<String>[normalizedRequesterUid]),
        },
        SetOptions(merge: true),
      );

      tx.set(
        requesterUserRef,
        {
          'sentFollowRequests': FieldValue.arrayRemove(<String>[myUid]),
        },
        SetOptions(merge: true),
      );
    });
  }

  Future<void> removeFollower(String followerUid) async {
    final myUid = _currentUid;
    final normalizedFollowerUid = followerUid.trim();
    if (normalizedFollowerUid.isEmpty || normalizedFollowerUid == myUid) {
      return;
    }

    final myUserRef = _db.collection('users').doc(myUid);
    final followerUserRef = _db.collection('users').doc(normalizedFollowerUid);
    final myPublicUserRef = _db.collection('users_public').doc(myUid);
    final followerPublicUserRef =
        _db.collection('users_public').doc(normalizedFollowerUid);

    try {
      await _db.runTransaction((tx) async {
        final myUserSnap = await tx.get(myUserRef);
        final followerUserSnap = await tx.get(followerUserRef);

        final myData = myUserSnap.data() ?? <String, dynamic>{};
        final followerData = followerUserSnap.data() ?? <String, dynamic>{};

        final myFollowers = _readUidSet(myData, 'followers')
          ..remove(normalizedFollowerUid);
        final myFollowing = _readUidSet(myData, 'following');
        final followerFollowing = _readUidSet(followerData, 'following')
          ..remove(myUid);
        final followerFollowers = _readUidSet(followerData, 'followers');

        tx.set(
          myUserRef,
          {
            'followers':
                FieldValue.arrayRemove(<String>[normalizedFollowerUid]),
            'followersCount': _uidCount(myFollowers),
          },
          SetOptions(merge: true),
        );

        tx.set(
          followerUserRef,
          {
            'following': FieldValue.arrayRemove(<String>[myUid]),
            'followingCount': _uidCount(followerFollowing),
          },
          SetOptions(merge: true),
        );

        tx.set(
          myPublicUserRef,
          _publicCountersPayload(
            followersCount: _uidCount(myFollowers),
            followingCount: _uidCount(myFollowing),
            followers: myFollowers,
            following: myFollowing,
          ),
          SetOptions(merge: true),
        );

        tx.set(
          followerPublicUserRef,
          _publicCountersPayload(
            followersCount: _uidCount(followerFollowers),
            followingCount: _uidCount(followerFollowing),
            followers: followerFollowers,
            following: followerFollowing,
          ),
          SetOptions(merge: true),
        );
      });
    } catch (e) {
      if (_isPermissionDenied(e)) {
        debugPrint(
          '[Follow Debug] permission-denied on removeFollower; '
          'applying self-only fallback',
        );
        await _removeFollowerSelfOnlyFallback(
          myUid: myUid,
          followerUid: normalizedFollowerUid,
        );
        await _secureQueue.enqueue(
          type: SecureActionTypes.removeFollower,
          payload: <String, dynamic>{
            'followerUid': normalizedFollowerUid,
          },
          dedupeKey: 'remove_follower:$myUid:$normalizedFollowerUid',
        );
        return;
      }
      rethrow;
    }
  }

  Stream<Map<String, int>> watchUserCounters(String uid) {
    return _db.collection('users_public').doc(uid).snapshots().map((snapshot) {
      final data = snapshot.data();
      final followersCount = (data?['followersCount'] as num?)?.toInt() ?? 0;
      final followingCount = (data?['followingCount'] as num?)?.toInt() ?? 0;
      return {
        'followersCount': followersCount,
        'followingCount': followingCount,
      };
    });
  }

  Future<List<String>> mutualFriendIds(String targetUid) async {
    final myUid = _currentUid;
    if (targetUid.isEmpty || targetUid == myUid) {
      return const <String>[];
    }

    final mySnapshot = await _db.collection('users').doc(myUid).get();
    final myFollowingIds = _readUidSet(mySnapshot.data(), 'following');
    final myFollowerIds = _readUidSet(mySnapshot.data(), 'followers');
    final myFriends = myFollowingIds.intersection(myFollowerIds);

    Set<String> targetFollowingIds = <String>{};
    Set<String> targetFollowerIds = <String>{};
    try {
      final targetPublicSnapshot =
          await _db.collection('users_public').doc(targetUid).get();
      targetFollowingIds =
          _readUidSet(targetPublicSnapshot.data(), 'following');
      targetFollowerIds = _readUidSet(targetPublicSnapshot.data(), 'followers');
    } catch (_) {
      return const <String>[];
    }

    Set<String> targetFriends = <String>{};
    if (targetFollowingIds.isNotEmpty && targetFollowerIds.isNotEmpty) {
      targetFriends = targetFollowingIds.intersection(targetFollowerIds);
    }

    if (targetFriends.isEmpty) {
      try {
        final followersOfTargetSnap = await _db
            .collection('users_public')
            .where('following', arrayContains: targetUid)
            .get();
        final followingOfTargetSnap = await _db
            .collection('users_public')
            .where('followers', arrayContains: targetUid)
            .get();

        final followersOfTarget = followersOfTargetSnap.docs
            .map((doc) => doc.id.trim())
            .where((id) => id.isNotEmpty)
            .toSet();
        final followingOfTarget = followingOfTargetSnap.docs
            .map((doc) => doc.id.trim())
            .where((id) => id.isNotEmpty)
            .toSet();

        targetFriends = followersOfTarget.intersection(followingOfTarget);
      } catch (_) {
        targetFriends = <String>{};
      }
    }

    if (myFriends.isEmpty || targetFriends.isEmpty) {
      return const <String>[];
    }

    final mutual = myFriends.intersection(targetFriends).toList(growable: false)
      ..sort();
    return mutual;
  }

  Future<bool> isMutualFollow(String otherUid) async {
    final myUid = _auth.currentUser?.uid;
    final targetUid = otherUid.trim();
    if (myUid == null ||
        myUid.isEmpty ||
        targetUid.isEmpty ||
        targetUid == myUid) {
      return true;
    }

    final isBlocked = await _blockUserService.isEitherUserBlocked(targetUid);
    if (isBlocked) {
      return false;
    }

    final mySnapshot = await _db.collection('users').doc(myUid).get();
    final myFollowingIds = _readUidSet(mySnapshot.data(), 'following');
    final myFollowerIds = _readUidSet(mySnapshot.data(), 'followers');
    return myFollowingIds.contains(targetUid) &&
        myFollowerIds.contains(targetUid);
  }
}
