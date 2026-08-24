import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

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

  void _trace(String message) {
    final now = DateTime.now().toIso8601String();
    final uid = _auth.currentUser?.uid.trim() ?? '';
    debugPrint('[BLOCK_TRACE][$now][uid=$uid] $message');
  }

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

  String _directChatKey(String uidA, String uidB) {
    final normalized = <String>[uidA.trim(), uidB.trim()]
      ..removeWhere((uid) => uid.isEmpty)
      ..sort();
    return normalized.join('__');
  }

  DocumentReference<Map<String, dynamic>> _directChatRef(
    String uidA,
    String uidB,
  ) {
    return _db.collection('chats').doc(_directChatKey(uidA, uidB));
  }

  bool _directChatBlockedByUid(Map<String, dynamic>? chatData, String uid) {
    if (chatData == null) {
      return false;
    }
    final blockedBy = chatData['blockedBy'];
    if (blockedBy is! Map) {
      return false;
    }
    return blockedBy[uid] == true;
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
    ).get().timeout(const Duration(seconds: 5));
    if (snap.exists) {
      return true;
    }

    // Backward compatibility for legacy schemas where blocked_users doc IDs
    // were not always target UID.
    final legacySnap = await _blockedUsersCol(myUid)
        .where('blockedUid', isEqualTo: normalizedTargetUid)
        .limit(1)
        .get()
        .timeout(const Duration(seconds: 5));
    return legacySnap.docs.isNotEmpty;
  }

  Future<bool> isBlockedByOther(
    String otherUid, {
    bool includeLegacyFallback = true,
  }) async {
    final myUid = _requireUid();
    final normalizedOtherUid = otherUid.trim();
    if (normalizedOtherUid.isEmpty || normalizedOtherUid == myUid) {
      return false;
    }

    try {
      final chatSnap = await _directChatRef(myUid, normalizedOtherUid)
          .get(const GetOptions(source: Source.serverAndCache))
          .timeout(const Duration(seconds: 3));
      if (!chatSnap.exists) {
        return false;
      }
      final blockedByOther =
          _directChatBlockedByUid(chatSnap.data(), normalizedOtherUid);
      _trace(
        'is_blocked_by_other_from_chat other=$normalizedOtherUid blocked=$blockedByOther includeLegacyFallback=$includeLegacyFallback',
      );
      return blockedByOther;
    } catch (error) {
      _trace(
        'is_blocked_by_other_error other=$normalizedOtherUid includeLegacyFallback=$includeLegacyFallback errorType=${error.runtimeType} error=$error',
      );
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
      Set<String>? lastGood;

      final sub = _db
          .collection('chats')
          .where('participants', arrayContains: myUid)
          .snapshots()
          .listen((snapshot) {
        final uids = <String>{};
        for (final doc in snapshot.docs) {
          final data = doc.data();
          final participants =
              ((data['participants'] as List<dynamic>?) ?? const <dynamic>[])
                  .map((value) => value.toString().trim())
                  .where((value) => value.isNotEmpty)
                  .toList(growable: false);
          final isPublic = (data['isPublic'] as bool?) ?? false;
          final isDirect = (data['isDirect'] as bool?) ??
              (!isPublic && participants.length == 2);
          if (!isDirect || participants.length != 2) {
            continue;
          }
          final otherUid = participants.firstWhere(
            (uid) => uid != myUid,
            orElse: () => '',
          );
          if (otherUid.isEmpty) {
            continue;
          }
          if (_directChatBlockedByUid(data, otherUid)) {
            uids.add(otherUid);
          }
        }
        lastGood = uids;
        controller.add(uids);
      }, onError: (error) {
        if (_isRecoverableBlockReadError(error)) {
          if (lastGood != null) {
            controller.add(lastGood!);
          }
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
      Set<String>? lastGood;

      void emit() {
        final merged = <String>{...blockedByMe, ...blockedMe};
        lastGood = merged;
        controller.add(merged);
      }

      final subMine = streamBlockedByMeUids().listen((value) {
        blockedByMe = value;
        emit();
      }, onError: (error) {
        if (_isRecoverableBlockReadError(error)) {
          if (lastGood != null) {
            controller.add(lastGood!);
          }
          return;
        }
        controller.addError(error);
      });

      final subTheirs = streamUsersWhoBlockedMe().listen((value) {
        blockedMe = value;
        emit();
      }, onError: (error) {
        if (_isRecoverableBlockReadError(error)) {
          if (lastGood != null) {
            controller.add(lastGood!);
          }
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

    Set<String> blockedByMe = <String>{};
    try {
      final blockedByMeSnap = await _blockedUsersCol(myUid).get();
      blockedByMe = blockedByMeSnap.docs
          .map((doc) => ((doc.data()['blockedUid'] as String?) ?? doc.id).trim())
          .where((uid) => uid.isNotEmpty)
          .toSet();
    } catch (error) {
      if (!_isRecoverableBlockReadError(error)) {
        rethrow;
      }
      blockedByMe = <String>{};
    }

    Set<String> blockedMe = <String>{};
    try {
      final chatsSnap = await _db
          .collection('chats')
          .where('participants', arrayContains: myUid)
          .get();
      for (final doc in chatsSnap.docs) {
        final data = doc.data();
        final participants =
            ((data['participants'] as List<dynamic>?) ?? const <dynamic>[])
                .map((value) => value.toString().trim())
                .where((value) => value.isNotEmpty)
                .toList(growable: false);
        final isPublic = (data['isPublic'] as bool?) ?? false;
        final isDirect = (data['isDirect'] as bool?) ??
            (!isPublic && participants.length == 2);
        if (!isDirect || participants.length != 2) {
          continue;
        }
        final otherUid = participants.firstWhere(
          (uid) => uid != myUid,
          orElse: () => '',
        );
        if (otherUid.isEmpty) {
          continue;
        }
        if (_directChatBlockedByUid(data, otherUid)) {
          blockedMe.add(otherUid);
        }
      }
    } catch (error) {
      if (!_isRecoverableBlockReadError(error)) {
        rethrow;
      }
      blockedMe = <String>{};
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

      final chatSub =
          _directChatRef(myUid, normalizedOtherUid).snapshots().listen((doc) {
        blockedByOther =
            _directChatBlockedByUid(doc.data(), normalizedOtherUid);
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
        await chatSub.cancel();
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

    final blockedRef = _blockedUserRef(
      ownerUid: myUid,
      targetUid: normalizedTargetUid,
    );
    final myUserRef = _db.collection('users').doc(myUid);
    final directChatRef = _directChatRef(myUid, normalizedTargetUid);
    final sortedParticipants = <String>[myUid, normalizedTargetUid]..sort();

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

      tx.set(
        directChatRef,
        {
          'id': directChatRef.id,
          'directChatKey': directChatRef.id,
          'isDirect': true,
          'isPublic': false,
          'participants': sortedParticipants,
          'blockedBy.$myUid': true,
          'blockedBy.$normalizedTargetUid': false,
          'updatedAt': FieldValue.serverTimestamp(),
          'createdAt': FieldValue.serverTimestamp(),
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
    final legacyDocs = await _blockedUsersCol(myUid)
        .where('blockedUid', isEqualTo: normalizedTargetUid)
        .get();

    // The unblock operation must succeed based on the current user's own
    // block records, regardless of the direct chat document state.
    final batch = _db.batch();
    batch.delete(blockedRef);
    for (final doc in legacyDocs.docs) {
      if (doc.id != blockedRef.id) {
        batch.delete(doc.reference);
      }
    }
    batch.set(
      _db.collection('users').doc(myUid),
      {
        'blockedUsers': FieldValue.arrayRemove(<String>[normalizedTargetUid]),
        'updatedAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );
    await batch.commit();

    // Best-effort cleanup for direct chat block markers. This should not fail
    // the unblock action if chat permissions or shape do not allow the update.
    final directChatRef = _directChatRef(myUid, normalizedTargetUid);
    try {
      final directSnap = await directChatRef.get();
      if (!directSnap.exists) {
        return;
      }

      final data = directSnap.data() ?? const <String, dynamic>{};
      final participants =
          ((data['participants'] as List<dynamic>?) ?? const <dynamic>[])
              .map((item) => item.toString().trim())
              .where((item) => item.isNotEmpty)
              .toSet();

      if (!participants.contains(myUid) ||
          !participants.contains(normalizedTargetUid)) {
        return;
      }

      await directChatRef.set(
        {
          'blockedBy.$myUid': false,
          'blockedBy.$normalizedTargetUid': FieldValue.delete(),
          'updatedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );
    } catch (error) {
      _trace(
        'unblock_chat_cleanup_skipped target=$normalizedTargetUid errorType=${error.runtimeType} error=$error',
      );
    }
  }
}
