import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../models/public_user_profile.dart';
import 'public_user_profile_service.dart';

enum BlockRelationship {
  none,
  blockedByMe,
  blockedByOther,
  both,
}

class BlockedUserEntry {
  const BlockedUserEntry({
    required this.uid,
    required this.name,
    required this.avatarUrl,
    required this.blockedAt,
  });

  final String uid;
  final String name;
  final String avatarUrl;
  final DateTime? blockedAt;
}

class BlockUserService {
  BlockUserService({
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

  bool _isRecoverableBlockReadError(Object error) {
    if (error is! FirebaseException) {
      return false;
    }

    return error.code == 'permission-denied' ||
        error.code == 'failed-precondition' ||
        error.code == 'unavailable' ||
        error.code == 'deadline-exceeded' ||
        error.code == 'resource-exhausted' ||
        error.code == 'aborted';
  }

  String _requireUid() {
    final uid = _auth.currentUser?.uid.trim() ?? '';
    if (uid.isEmpty) {
      throw FirebaseAuthException(
        code: 'not-authenticated',
        message: 'User must be logged in.',
      );
    }
    return uid;
  }

  DocumentReference<Map<String, dynamic>> _blockedUserRef({
    required String ownerUid,
    required String targetUid,
  }) {
    return _db
        .collection('users')
        .doc(ownerUid)
        .collection('blocked_users')
        .doc(targetUid);
  }

  CollectionReference<Map<String, dynamic>> _blockedUsersCol(String ownerUid) {
    return _db.collection('users').doc(ownerUid).collection('blocked_users');
  }

  Future<bool> isBlockedByMe(String targetUid) async {
    final myUid = _requireUid();
    final normalizedTargetUid = targetUid.trim();
    if (normalizedTargetUid.isEmpty || normalizedTargetUid == myUid) {
      return false;
    }

    final snap = await _blockedUserRef(
      ownerUid: myUid,
      targetUid: normalizedTargetUid,
    ).get();
    return snap.exists;
  }

  Future<bool> isBlockedByOther(String otherUid) async {
    final myUid = _requireUid();
    final normalizedOtherUid = otherUid.trim();
    if (normalizedOtherUid.isEmpty || normalizedOtherUid == myUid) {
      return false;
    }

    try {
      final snap = await _blockedUserRef(
        ownerUid: normalizedOtherUid,
        targetUid: myUid,
      ).get();
      return snap.exists;
    } catch (error) {
      if (_isRecoverableBlockReadError(error)) {
        return false;
      }
      rethrow;
    }
  }

  Future<bool> isEitherUserBlocked(String otherUid) async {
    final byMe = await isBlockedByMe(otherUid);
    if (byMe) {
      return true;
    }
    try {
      return await isBlockedByOther(otherUid);
    } catch (error) {
      if (_isRecoverableBlockReadError(error)) {
        return false;
      }
      rethrow;
    }
  }

  Stream<bool> streamIsBlockedByMe(String targetUid) {
    final myUid = _auth.currentUser?.uid.trim() ?? '';
    final normalizedTargetUid = targetUid.trim();
    if (myUid.isEmpty ||
        normalizedTargetUid.isEmpty ||
        myUid == normalizedTargetUid) {
      return Stream<bool>.value(false);
    }

    return _blockedUserRef(ownerUid: myUid, targetUid: normalizedTargetUid)
        .snapshots()
        .map((doc) => doc.exists);
  }

  Stream<Set<String>> streamBlockedByMeUids() {
    final myUid = _auth.currentUser?.uid.trim() ?? '';
    if (myUid.isEmpty) {
      return Stream<Set<String>>.value(const <String>{});
    }

    return _blockedUsersCol(myUid).snapshots().map((snapshot) {
      return snapshot.docs
          .map(
              (doc) => ((doc.data()['blockedUid'] as String?) ?? doc.id).trim())
          .where((uid) => uid.isNotEmpty)
          .toSet();
    });
  }

  Stream<Set<String>> streamUsersWhoBlockedMe() {
    final myUid = _auth.currentUser?.uid.trim() ?? '';
    if (myUid.isEmpty) {
      return Stream<Set<String>>.value(const <String>{});
    }

    return Stream<Set<String>>.multi((controller) {
      final sub = _db
          .collectionGroup('blocked_users')
          .where('blockedUid', isEqualTo: myUid)
          .snapshots()
          .listen((snapshot) {
        final uids = snapshot.docs
            .map((doc) => (doc.data()['blockedByUid'] as String? ?? '').trim())
            .where((uid) => uid.isNotEmpty)
            .toSet();
        controller.add(uids);
      }, onError: (error) {
        if (_isRecoverableBlockReadError(error)) {
          controller.add(const <String>{});
          return;
        }
        controller.addError(error);
      });

      controller.onCancel = () async {
        await sub.cancel();
      };
    });
  }

  Stream<Set<String>> streamBlockedConnections() {
    final myUid = _auth.currentUser?.uid.trim() ?? '';
    if (myUid.isEmpty) {
      return Stream<Set<String>>.value(const <String>{});
    }

    return Stream<Set<String>>.multi((controller) {
      var blockedByMe = <String>{};
      var blockedMe = <String>{};

      void emit() {
        controller.add(<String>{...blockedByMe, ...blockedMe});
      }

      final subMine = streamBlockedByMeUids().listen((value) {
        blockedByMe = value;
        emit();
      }, onError: (error) {
        if (_isRecoverableBlockReadError(error)) {
          blockedByMe = <String>{};
          emit();
          return;
        }
        controller.addError(error);
      });

      final subTheirs = streamUsersWhoBlockedMe().listen((value) {
        blockedMe = value;
        emit();
      }, onError: (error) {
        if (_isRecoverableBlockReadError(error)) {
          blockedMe = <String>{};
          emit();
          return;
        }
        controller.addError(error);
      });

      controller.onCancel = () async {
        await subMine.cancel();
        await subTheirs.cancel();
      };
    });
  }

  Future<Set<String>> fetchBlockedConnections() async {
    final myUid = _auth.currentUser?.uid.trim() ?? '';
    if (myUid.isEmpty) {
      return const <String>{};
    }

    final blockedByMeSnap = await _blockedUsersCol(myUid).get();
    final blockedByMe = blockedByMeSnap.docs
        .map((doc) => ((doc.data()['blockedUid'] as String?) ?? doc.id).trim())
        .where((uid) => uid.isNotEmpty)
        .toSet();

    Set<String> blockedMe = <String>{};
    try {
      final blockedMeSnap = await _db
          .collectionGroup('blocked_users')
          .where('blockedUid', isEqualTo: myUid)
          .get();
      blockedMe = blockedMeSnap.docs
          .map((doc) => (doc.data()['blockedByUid'] as String? ?? '').trim())
          .where((uid) => uid.isNotEmpty)
          .toSet();
    } catch (error) {
      if (!_isRecoverableBlockReadError(error)) {
        rethrow;
      }
    }

    return <String>{...blockedByMe, ...blockedMe};
  }

  Stream<BlockRelationship> streamRelationship(String otherUid) {
    final myUid = _auth.currentUser?.uid.trim() ?? '';
    final normalizedOtherUid = otherUid.trim();
    if (myUid.isEmpty ||
        normalizedOtherUid.isEmpty ||
        myUid == normalizedOtherUid) {
      return Stream<BlockRelationship>.value(BlockRelationship.none);
    }

    return Stream<BlockRelationship>.multi((controller) {
      var blockedByMe = false;
      var blockedByOther = false;

      void emit() {
        if (blockedByMe && blockedByOther) {
          controller.add(BlockRelationship.both);
          return;
        }
        if (blockedByMe) {
          controller.add(BlockRelationship.blockedByMe);
          return;
        }
        if (blockedByOther) {
          controller.add(BlockRelationship.blockedByOther);
          return;
        }
        controller.add(BlockRelationship.none);
      }

      final mineSub = _blockedUserRef(
        ownerUid: myUid,
        targetUid: normalizedOtherUid,
      ).snapshots().listen((doc) {
        blockedByMe = doc.exists;
        emit();
      }, onError: (error) {
        if (_isRecoverableBlockReadError(error)) {
          blockedByMe = false;
          emit();
          return;
        }
        controller.addError(error);
      });

      final theirsSub = _blockedUserRef(
        ownerUid: normalizedOtherUid,
        targetUid: myUid,
      ).snapshots().listen((doc) {
        blockedByOther = doc.exists;
        emit();
      }, onError: (error) {
        if (_isRecoverableBlockReadError(error)) {
          blockedByOther = false;
          emit();
          return;
        }
        controller.addError(error);
      });

      controller.onCancel = () async {
        await mineSub.cancel();
        await theirsSub.cancel();
      };
    });
  }

  Stream<List<BlockedUserEntry>> streamBlockedUsers() {
    final myUid = _auth.currentUser?.uid.trim() ?? '';
    if (myUid.isEmpty) {
      return Stream<List<BlockedUserEntry>>.value(const <BlockedUserEntry>[]);
    }

    return _blockedUsersCol(myUid)
        .orderBy('blockedAt', descending: true)
        .snapshots()
        .asyncMap((snapshot) async {
      final entries = <BlockedUserEntry>[];
      for (final doc in snapshot.docs) {
        final data = doc.data();
        final blockedUid = (data['blockedUid'] as String? ?? doc.id).trim();
        if (blockedUid.isEmpty) {
          continue;
        }

        final blockedAt = (data['blockedAt'] as Timestamp?)?.toDate();
        PublicUserProfile? profile;
        try {
          profile = await _publicUserProfileService.fetchProfile(blockedUid);
        } catch (_) {
          profile = null;
        }

        final displayName = (profile?.displayName ?? '').trim();
        final username = (profile?.username ?? '').trim();

        entries.add(
          BlockedUserEntry(
            uid: blockedUid,
            name: displayName.isNotEmpty
                ? displayName
                : (username.isNotEmpty ? username : blockedUid),
            avatarUrl: (profile?.profilePictureUrl ?? '').trim(),
            blockedAt: blockedAt,
          ),
        );
      }
      return entries;
    });
  }

  Future<void> blockUser(String targetUid) async {
    final myUid = _requireUid();
    final normalizedTargetUid = targetUid.trim();
    if (normalizedTargetUid.isEmpty || normalizedTargetUid == myUid) {
      return;
    }

    await _deleteDirectChatWithUser(normalizedTargetUid);

    final blockedRef = _blockedUserRef(
      ownerUid: myUid,
      targetUid: normalizedTargetUid,
    );
    final myUserRef = _db.collection('users').doc(myUid);

    await _db.runTransaction((tx) async {
      tx.set(blockedRef, {
        'blockedUid': normalizedTargetUid,
        'blockedByUid': myUid,
        'blockedAt': FieldValue.serverTimestamp(),
      });

      tx.set(
        myUserRef,
        {
          'blockedUsers': FieldValue.arrayUnion(<String>[normalizedTargetUid]),
          'directChatResetAt.$normalizedTargetUid':
              FieldValue.serverTimestamp(),
          // Best-effort local cleanup for relationship collections.
          'following': FieldValue.arrayRemove(<String>[normalizedTargetUid]),
          'followers': FieldValue.arrayRemove(<String>[normalizedTargetUid]),
          'followRequests':
              FieldValue.arrayRemove(<String>[normalizedTargetUid]),
          'sentFollowRequests':
              FieldValue.arrayRemove(<String>[normalizedTargetUid]),
          'friends': FieldValue.arrayRemove(<String>[normalizedTargetUid]),
          'updatedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );
    });
  }

  Future<void> unblockUser(String targetUid) async {
    final myUid = _requireUid();
    final normalizedTargetUid = targetUid.trim();
    if (normalizedTargetUid.isEmpty || normalizedTargetUid == myUid) {
      return;
    }

    final blockedRef = _blockedUserRef(
      ownerUid: myUid,
      targetUid: normalizedTargetUid,
    );

    try {
      await _deleteDirectChatWithUser(normalizedTargetUid);
    } catch (_) {
      // Best effort: if cleanup fails, reset marker still forces new chat lifecycle.
    }

    await blockedRef.delete();
    await _db.collection('users').doc(myUid).set(
      {
        'blockedUsers': FieldValue.arrayRemove(<String>[normalizedTargetUid]),
        'directChatResetAt.$normalizedTargetUid': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );
  }

  Future<void> _deleteDirectChatWithUser(String otherUid) async {
    final myUid = _requireUid();

    final directKey = <String>[myUid, otherUid]..sort();
    final stableDocId = 'direct_v2_${directKey.join('__')}';
    final legacyDocId = 'direct_${directKey.join('__')}';

    Future<void> deleteChatById(String chatId) async {
      final chatRef = _db.collection('chats').doc(chatId);
      final chatSnap = await chatRef.get();
      if (!chatSnap.exists) {
        return;
      }
      await _deleteSubcollectionInChunks(chatRef.collection('messages'));
      await _deleteSubcollectionInChunks(chatRef.collection('readReceipts'));
      await chatRef.delete();
    }

    try {
      await deleteChatById(stableDocId);
    } catch (_) {}

    try {
      await deleteChatById(legacyDocId);
    } catch (_) {}

    final chatsSnap = await _db
        .collection('chats')
        .where('participants', arrayContains: myUid)
        .get();

    for (final chatDoc in chatsSnap.docs) {
      final data = chatDoc.data();
      final participants =
          ((data['participants'] as List<dynamic>?) ?? const <dynamic>[])
              .map((value) => value.toString().trim())
              .where((value) => value.isNotEmpty)
              .toList(growable: false);
      final isPublic = (data['isPublic'] as bool?) ?? false;
      final isDirect = (data['isDirect'] as bool?) ??
          (!isPublic && participants.length == 2);
      if (!isDirect || !participants.contains(otherUid)) {
        continue;
      }

      await _deleteSubcollectionInChunks(
        chatDoc.reference.collection('messages'),
      );
      await _deleteSubcollectionInChunks(
        chatDoc.reference.collection('readReceipts'),
      );
      await chatDoc.reference.delete();
    }
  }

  Future<void> _deleteSubcollectionInChunks(
    CollectionReference<Map<String, dynamic>> col,
  ) async {
    while (true) {
      final chunk = await col.limit(250).get();
      if (chunk.docs.isEmpty) {
        return;
      }

      final batch = _db.batch();
      for (final doc in chunk.docs) {
        batch.delete(doc.reference);
      }
      await batch.commit();

      if (chunk.docs.length < 250) {
        return;
      }
    }
  }
}
