import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';

import '../age_restrictions.dart';
import 'notification_service.dart';
import 'secure_action_queue_service.dart';

class GroupJoinException implements Exception {
  final String code;
  final String message;
  final int? minScore;
  final int? userScore;

  const GroupJoinException({
    required this.code,
    required this.message,
    this.minScore,
    this.userScore,
  });

  @override
  String toString() => message;
}

class GroupService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final FirebaseStorage _storage = FirebaseStorage.instance;
  final NotificationService _notificationService = NotificationService();
  final SecureActionQueueService _secureQueue = SecureActionQueueService();

  bool _isPermissionDenied(Object error) {
    return error is FirebaseException && error.code == 'permission-denied';
  }

  String _requireUid() {
    final uid = _auth.currentUser?.uid;
    if (uid == null || uid.isEmpty) {
      throw FirebaseAuthException(
        code: 'not-authenticated',
        message: 'User must be logged in to perform this action.',
      );
    }
    return uid;
  }

  Future<bool> _isApprovedOrPendingMemberByAnySchema({
    required String groupId,
    required String uid,
  }) async {
    final normalizedGroupId = groupId.trim();
    final normalizedUid = uid.trim();
    if (normalizedGroupId.isEmpty || normalizedUid.isEmpty) {
      return false;
    }

    try {
      final groupSnap =
          await _db.collection('groups').doc(normalizedGroupId).get();
      if (!groupSnap.exists) {
        return false;
      }

      final groupData = groupSnap.data() ?? <String, dynamic>{};
      final adminUid = (groupData['adminUid'] as String? ?? '').trim();
      if (adminUid == normalizedUid) {
        return true;
      }

      final rootIds = <String>{
        ...((groupData['members'] as List<dynamic>?) ?? const <dynamic>[])
            .map((value) => value.toString().trim())
            .where((value) => value.isNotEmpty),
        ...((groupData['membersList'] as List<dynamic>?) ?? const <dynamic>[])
            .map((value) => value.toString().trim())
            .where((value) => value.isNotEmpty),
        ...((groupData['participants'] as List<dynamic>?) ?? const <dynamic>[])
            .map((value) => value.toString().trim())
            .where((value) => value.isNotEmpty),
      };
      if (rootIds.contains(normalizedUid)) {
        return true;
      }

      final directMember = await _db
          .collection('groups')
          .doc(normalizedGroupId)
          .collection('members')
          .doc(normalizedUid)
          .get();
      if (directMember.exists) {
        final status = (directMember.data()?['status'] as String? ?? '')
            .trim()
            .toLowerCase();
        if (status.isEmpty || status == 'approved' || status == 'pending') {
          return true;
        }
      }

      Future<bool> probeByField(String field) async {
        try {
          final snapshot = await _db
              .collection('groups')
              .doc(normalizedGroupId)
              .collection('members')
              .where(field, isEqualTo: normalizedUid)
              .limit(5)
              .get();
          for (final doc in snapshot.docs) {
            final status =
                (doc.data()['status'] as String? ?? '').trim().toLowerCase();
            if (status.isEmpty || status == 'approved' || status == 'pending') {
              return true;
            }
          }
        } catch (_) {}
        return false;
      }

      if (await probeByField('uid')) {
        return true;
      }
      if (await probeByField('userId')) {
        return true;
      }
      if (await probeByField('memberUid')) {
        return true;
      }
    } catch (_) {
      return false;
    }

    return false;
  }

  Future<void> _requireAdmin(String groupId) async {
    final myUid = _requireUid();
    final groupSnap = await _db.collection('groups').doc(groupId).get();
    final adminUid = (groupSnap.data()?['adminUid'] as String?) ?? '';
    if (adminUid != myUid) {
      throw FirebaseAuthException(
        code: 'permission-denied',
        message: 'Only group admin can edit advanced settings.',
      );
    }
  }

  Future<String> createGroup({
    required String groupName,
    required String description,
    required String category,
    required String subCategory,
    required String location,
    required DateTime date,
    required int minAge,
    required int maxAge,
    required int minScore,
    bool isMinScoreRequired = false,
    required bool isPublic,
    required bool isAdminApprovalRequired,
    Uint8List? groupImageBytes,
    String? imageFileName,
    List<String> invitedFriendUids = const <String>[],
  }) async {
    final adminUid = _requireUid();
    if (!isValidAgeRange(minAge, maxAge)) {
      throw ArgumentError(
        'Age range must be between $minimumUserAge and $maximumAgeRange.',
      );
    }
    final normalizedInvitedUids = invitedFriendUids
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty && e != adminUid)
        .toSet()
        .toList(growable: false);

    String groupImageUrl = '';
    if (groupImageBytes != null && groupImageBytes.isNotEmpty) {
      final ext = _fileExtension(imageFileName ?? 'group.jpg');
      final imageRef = _storage.ref().child(
          'groups/$adminUid/${DateTime.now().millisecondsSinceEpoch}.$ext');
      await imageRef.putData(groupImageBytes);
      groupImageUrl = await imageRef.getDownloadURL();
    }

    final groupRef = _db.collection('groups').doc();
    final initialMembers = <String>[adminUid];
    final chatParticipants = <String>[adminUid, ...normalizedInvitedUids];

    await _db.runTransaction((tx) async {
      tx.set(groupRef, {
        'groupName': groupName.trim(),
        'description': description.trim(),
        'category': category.trim(),
        'subCategory': subCategory.trim(),
        'location': location.trim(),
        'date': Timestamp.fromDate(date),
        'ageRange': {
          'min': minAge,
          'max': maxAge,
        },
        'minScore': minScore,
        'isMinScoreRequired': isMinScoreRequired || minScore > 0,
        'isPublic': isPublic,
        'isAdminApprovalRequired': isAdminApprovalRequired,
        'adminUid': adminUid,
        'originType': 'regular',
        'members': initialMembers,
        'membersList': initialMembers,
        'groupImageUrl': groupImageUrl,
        'createdAt': FieldValue.serverTimestamp(),
        'membersCount': 1,
        'pendingCount': 0,
        'invitedFriendUids': normalizedInvitedUids,
      });

      // Keep chat directory in sync with group creation for chat discovery screens.
      tx.set(_db.collection('chats').doc(groupRef.id), {
        'id': groupRef.id,
        'name': groupName.trim(),
        'description': description.trim(),
        'groupImageUrl': groupImageUrl,
        'isPublic': isPublic,
        'originType': 'regular',
        'participants': chatParticipants,
        'sourceGroupId': groupRef.id,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      tx.set(groupRef.collection('members').doc(adminUid), {
        'uid': adminUid,
        'status': 'approved',
        'role': 'admin',
        'joinedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    });

    final createdGroup = await groupRef.get();
    final createdData = createdGroup.data() ?? <String, dynamic>{};
    debugPrint(
        '[GroupService] Created group ${groupRef.id} adminUid=$adminUid members=${createdData['members']} membersCount=${createdData['membersCount']}');

    return groupRef.id;
  }

  Future<void> joinGroup(String groupId) async {
    final uid = _requireUid();
    final groupRef = _db.collection('groups').doc(groupId);
    final memberRef = groupRef.collection('members').doc(uid);
    debugPrint('[GroupService][joinGroup] start uid=$uid groupId=$groupId');

    final groupSnap = await groupRef.get();
    if (!groupSnap.exists) {
      throw const GroupJoinException(
        code: 'group-not-found',
        message: 'הקבוצה לא נמצאה.',
      );
    }

    final groupData = groupSnap.data() ?? <String, dynamic>{};
    final groupName = (groupData['groupName'] as String? ?? '').trim();
    final originType = (groupData['originType'] as String? ?? '').trim();
    final groupAdminUid = (groupData['adminUid'] as String? ?? '').trim();
    final minScoreRequired =
        (groupData['isMinScoreRequired'] as bool?) ?? false;
    final minScore = (groupData['minScore'] as num?)?.toInt() ?? 0;
    if (minScoreRequired && minScore > 0) {
      final userSnap = await _db.collection('users').doc(uid).get();
      final userScore = (userSnap.data()?['score'] as num?)?.toInt() ?? 0;
      if (userScore < minScore) {
        throw GroupJoinException(
          code: 'insufficient-score',
          message: 'לא ניתן להצטרף: נדרש מינימום $minScore נקודות.',
          minScore: minScore,
          userScore: userScore,
        );
      }
    }

    var shouldNotifyAdminAboutJoin = false;
    try {
      await _db.runTransaction((tx) async {
        final groupSnap = await tx.get(groupRef);
        if (!groupSnap.exists) {
          throw const GroupJoinException(
            code: 'group-not-found',
            message: 'הקבוצה לא נמצאה.',
          );
        }

        final groupData = groupSnap.data() ?? <String, dynamic>{};
        final approvalRequired =
            (groupData['isAdminApprovalRequired'] as bool?) ?? false;
        final minScoreRequired =
            (groupData['isMinScoreRequired'] as bool?) ?? false;
        final minScore = (groupData['minScore'] as num?)?.toInt() ?? 0;
        debugPrint(
          '[GroupService][joinGroup] group flags approvalRequired=$approvalRequired minScoreRequired=$minScoreRequired minScore=$minScore',
        );

        if (minScoreRequired && minScore > 0) {
          final userSnap = await tx.get(_db.collection('users').doc(uid));
          final userScore = (userSnap.data()?['score'] as num?)?.toInt() ?? 0;
          debugPrint('[GroupService][joinGroup] userScore=$userScore');
          if (userScore < minScore) {
            throw GroupJoinException(
              code: 'insufficient-score',
              message: 'לא ניתן להצטרף: נדרש מינימום $minScore נקודות.',
              minScore: minScore,
              userScore: userScore,
            );
          }
        }

        final memberSnap = await tx.get(memberRef);
        if (memberSnap.exists) {
          final existingStatus =
              (memberSnap.data()?['status'] as String?) ?? 'unknown';
          debugPrint(
              '[GroupService][joinGroup] member already exists status=$existingStatus');
          return;
        }

        final status = approvalRequired ? 'pending' : 'approved';
        debugPrint(
            '[GroupService][joinGroup] creating member with status=$status');

        tx.set(memberRef, {
          'uid': uid,
          'status': status,
          'role': 'member',
          'joinedAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        });

        if (approvalRequired) {
          tx.update(groupRef, {'pendingCount': FieldValue.increment(1)});
        } else {
          shouldNotifyAdminAboutJoin = true;
          tx.update(groupRef, {
            'membersCount': FieldValue.increment(1),
            'members': FieldValue.arrayUnion([uid]),
            'membersList': FieldValue.arrayUnion([uid]),
          });
          tx.update(_db.collection('chats').doc(groupId), {
            'participants': FieldValue.arrayUnion([uid]),
            'updatedAt': FieldValue.serverTimestamp(),
          });
        }
      });
      debugPrint('[GroupService][joinGroup] success uid=$uid groupId=$groupId');

      if (shouldNotifyAdminAboutJoin &&
          groupAdminUid.isNotEmpty &&
          groupAdminUid != uid) {
        if (originType == 'pop') {
          await _notificationService.sendPopJoinNotification(
            recipientUid: groupAdminUid,
            groupId: groupId,
            groupName: groupName,
            joiningUid: uid,
          );
        } else {
          await _notificationService.sendGroupJoinNotification(
            recipientUid: groupAdminUid,
            groupId: groupId,
            groupName: groupName,
            joiningUid: uid,
          );
        }
      }
    } catch (error, stackTrace) {
      if (_isPermissionDenied(error)) {
        final alreadyJoined = await _isApprovedOrPendingMemberByAnySchema(
          groupId: groupId,
          uid: uid,
        );
        if (alreadyJoined) {
          return;
        }
        throw const GroupJoinException(
          code: 'permission-denied',
          message: 'אין הרשאה להצטרף לקבוצה כרגע. נסה שוב בעוד רגע.',
        );
      }
      if (error is FirebaseException) {
        debugPrint(
          '[GroupService][joinGroup] FirebaseException code=${error.code} plugin=${error.plugin} message=${error.message}',
        );
      } else {
        debugPrint(
            '[GroupService][joinGroup] error=${error.runtimeType} $error');
      }
      debugPrint('[GroupService][joinGroup] stackTrace=$stackTrace');
      rethrow;
    }
  }

  Future<void> cancelMyPendingJoinRequest(String groupId) async {
    final uid = _requireUid();
    final groupRef = _db.collection('groups').doc(groupId);
    final memberRef = groupRef.collection('members').doc(uid);

    debugPrint(
        '[GroupService][cancelJoinRequest] start uid=$uid groupId=$groupId');

    try {
      await _db.runTransaction((tx) async {
        final groupSnap = await tx.get(groupRef);
        if (!groupSnap.exists) {
          throw const GroupJoinException(
            code: 'group-not-found',
            message: 'הקבוצה לא נמצאה.',
          );
        }

        final memberSnap = await tx.get(memberRef);
        if (!memberSnap.exists) {
          debugPrint(
              '[GroupService][cancelJoinRequest] no membership doc for uid=$uid');
          return;
        }

        final status = (memberSnap.data()?['status'] as String?) ?? '';
        if (status != 'pending') {
          throw const GroupJoinException(
            code: 'no-pending-request',
            message: 'לא נמצאה בקשת הצטרפות פעילה לביטול.',
          );
        }

        tx.delete(memberRef);
        tx.update(groupRef, {
          'pendingCount': FieldValue.increment(-1),
          'invitedFriendUids': FieldValue.arrayRemove([uid]),
        });
      });

      debugPrint(
          '[GroupService][cancelJoinRequest] success uid=$uid groupId=$groupId');
    } catch (error, stackTrace) {
      if (_isPermissionDenied(error)) {
        await _secureQueue.enqueue(
          type: SecureActionTypes.cancelGroupJoinRequest,
          payload: <String, dynamic>{
            'groupId': groupId,
          },
          dedupeKey: 'cancel_join_group:$uid:$groupId',
        );
        return;
      }
      if (error is FirebaseException) {
        debugPrint(
          '[GroupService][cancelJoinRequest] FirebaseException code=${error.code} plugin=${error.plugin} message=${error.message}',
        );
      } else {
        debugPrint(
            '[GroupService][cancelJoinRequest] error=${error.runtimeType} $error');
      }
      debugPrint('[GroupService][cancelJoinRequest] stackTrace=$stackTrace');
      rethrow;
    }
  }

  Future<void> approveMember(String groupId, String uid) async {
    final myUid = _requireUid();
    final groupRef = _db.collection('groups').doc(groupId);
    final memberRef = groupRef.collection('members').doc(uid);
    var groupName = '';
    var adminUid = '';
    var originType = '';

    await _db.runTransaction((tx) async {
      final groupSnap = await tx.get(groupRef);
      if (!groupSnap.exists) {
        throw FirebaseException(
            plugin: 'cloud_firestore', message: 'Group not found');
      }
      adminUid = (groupSnap.data()?['adminUid'] as String?) ?? '';
      groupName = (groupSnap.data()?['groupName'] as String? ?? '').trim();
      originType = (groupSnap.data()?['originType'] as String?) ?? '';
      if (adminUid != myUid) {
        throw FirebaseAuthException(
          code: 'permission-denied',
          message: 'Only group admin can approve members.',
        );
      }

      final memberSnap = await tx.get(memberRef);
      if (!memberSnap.exists) {
        return;
      }

      final currentStatus = (memberSnap.data()?['status'] as String?) ?? '';
      if (currentStatus == 'approved') {
        return;
      }

      tx.update(memberRef, {
        'status': 'approved',
        'updatedAt': FieldValue.serverTimestamp(),
      });
      tx.update(groupRef, {
        'pendingCount': FieldValue.increment(-1),
        'membersCount': FieldValue.increment(1),
        'members': FieldValue.arrayUnion([uid]),
        'membersList': FieldValue.arrayUnion([uid]),
      });
      tx.update(_db.collection('chats').doc(groupId), {
        'participants': FieldValue.arrayUnion([uid]),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    });

    if (adminUid.isNotEmpty && uid.isNotEmpty && adminUid != uid) {
      if (originType.trim() == 'pop') {
        await _notificationService.sendPopJoinNotification(
          recipientUid: adminUid,
          groupId: groupId,
          groupName: groupName,
          joiningUid: uid,
        );
      } else {
        await _notificationService.sendGroupJoinNotification(
          recipientUid: adminUid,
          groupId: groupId,
          groupName: groupName,
          joiningUid: uid,
        );
      }
    }
  }

  Future<void> denyMember(String groupId, String uid) async {
    final myUid = _requireUid();
    final groupRef = _db.collection('groups').doc(groupId);
    final memberRef = groupRef.collection('members').doc(uid);

    await _db.runTransaction((tx) async {
      final groupSnap = await tx.get(groupRef);
      if (!groupSnap.exists) {
        throw FirebaseException(
            plugin: 'cloud_firestore', message: 'Group not found');
      }
      final adminUid = (groupSnap.data()?['adminUid'] as String?) ?? '';
      if (adminUid != myUid) {
        throw FirebaseAuthException(
          code: 'permission-denied',
          message: 'Only group admin can deny members.',
        );
      }

      final memberSnap = await tx.get(memberRef);
      if (!memberSnap.exists) {
        return;
      }

      final currentStatus = (memberSnap.data()?['status'] as String?) ?? '';
      tx.delete(memberRef);
      if (currentStatus == 'pending') {
        tx.update(groupRef, {'pendingCount': FieldValue.increment(-1)});
      }
    });
  }

  Future<Set<String>> fetchMembershipUids(String groupId) async {
    final groupRef = _db.collection('groups').doc(groupId);
    final chatRef = _db.collection('chats').doc(groupId);
    final groupSnap = await groupRef.get();
    final chatSnap = await chatRef.get();
    final groupData = groupSnap.data() ?? <String, dynamic>{};
    final chatData = chatSnap.data() ?? <String, dynamic>{};

    final memberDocsSnapshot = await groupRef.collection('members').get();

    final uids = <String>{};
    for (final doc in memberDocsSnapshot.docs) {
      final uid = doc.id.trim();
      if (uid.isNotEmpty) {
        uids.add(uid);
      }
    }

    final membersRaw =
        (groupData['members'] as List<dynamic>?) ?? const <dynamic>[];
    for (final value in membersRaw) {
      final uid = value.toString().trim();
      if (uid.isNotEmpty) {
        uids.add(uid);
      }
    }

    final membersListRaw =
        (groupData['membersList'] as List<dynamic>?) ?? const <dynamic>[];
    for (final value in membersListRaw) {
      final uid = value.toString().trim();
      if (uid.isNotEmpty) {
        uids.add(uid);
      }
    }

    final participantsRaw =
        (groupData['participants'] as List<dynamic>?) ?? const <dynamic>[];
    for (final value in participantsRaw) {
      final uid = value.toString().trim();
      if (uid.isNotEmpty) {
        uids.add(uid);
      }
    }

    final chatParticipantsRaw =
        (chatData['participants'] as List<dynamic>?) ?? const <dynamic>[];
    for (final value in chatParticipantsRaw) {
      final uid = value.toString().trim();
      if (uid.isNotEmpty) {
        uids.add(uid);
      }
    }

    final adminUid = (groupData['adminUid'] as String? ?? '').trim();
    if (adminUid.isNotEmpty) {
      uids.add(adminUid);
    }

    return uids;
  }

  Future<String> inviteUserToGroup({
    required String groupId,
    required String targetUid,
  }) async {
    final inviterUid = _requireUid();
    final normalizedTargetUid = targetUid.trim();

    if (normalizedTargetUid.isEmpty) {
      throw FirebaseAuthException(
        code: 'invalid-argument',
        message: 'Target uid cannot be empty.',
      );
    }

    if (normalizedTargetUid == inviterUid) {
      throw FirebaseAuthException(
        code: 'invalid-action',
        message: 'Cannot invite yourself to the same group.',
      );
    }

    final groupRef = _db.collection('groups').doc(groupId);
    final chatRef = _db.collection('chats').doc(groupId);
    final targetMemberRef =
        groupRef.collection('members').doc(normalizedTargetUid);
    final inviterMemberRef = groupRef.collection('members').doc(inviterUid);

    final status = await _db.runTransaction((tx) async {
      final groupSnap = await tx.get(groupRef);
      if (!groupSnap.exists) {
        throw FirebaseException(
            plugin: 'cloud_firestore', message: 'Group not found');
      }

      final groupData = groupSnap.data() ?? <String, dynamic>{};
      final chatSnap = await tx.get(chatRef);
      final chatData = chatSnap.data() ?? <String, dynamic>{};
      final adminUid = (groupData['adminUid'] as String?) ?? '';
      final isPublic = (groupData['isPublic'] as bool?) ?? true;
      final approvalRequired =
          (groupData['isAdminApprovalRequired'] as bool?) ?? false;
      final legacyMembers =
          (groupData['members'] as List<dynamic>? ?? const <dynamic>[])
              .map((e) => e.toString().trim())
              .where((uid) => uid.isNotEmpty)
              .toSet();
      final legacyMembersList =
          (groupData['membersList'] as List<dynamic>? ?? const <dynamic>[])
              .map((e) => e.toString().trim())
              .where((uid) => uid.isNotEmpty)
              .toSet();
      final inviterInLegacyMemberArrays = legacyMembers.contains(inviterUid) ||
          legacyMembersList.contains(inviterUid);
      final chatParticipants =
          (chatData['participants'] as List<dynamic>? ?? const <dynamic>[])
              .map((e) => e.toString().trim())
              .where((uid) => uid.isNotEmpty)
              .toSet();
      final inviterInChatParticipants = chatParticipants.contains(inviterUid);

      if (inviterUid != adminUid) {
        final inviterSnap = await tx.get(inviterMemberRef);
        final inviterCanInvite = inviterSnap.exists ||
            inviterInLegacyMemberArrays ||
            inviterInChatParticipants;
        if (!inviterCanInvite) {
          throw FirebaseAuthException(
            code: 'permission-denied',
            message: 'Only approved members can invite friends to this group.',
          );
        }
      }

      final targetMemberSnap = await tx.get(targetMemberRef);
      if (targetMemberSnap.exists) {
        final currentStatus =
            (targetMemberSnap.data()?['status'] as String?) ?? 'approved';
        return currentStatus;
      }

      final shouldCreatePending = !isPublic || approvalRequired;
      final status = shouldCreatePending ? 'pending' : 'approved';

      tx.set(targetMemberRef, {
        'uid': normalizedTargetUid,
        'status': status,
        'role': 'member',
        'invitedBy': inviterUid,
        'joinedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      if (shouldCreatePending) {
        tx.update(groupRef, {
          'pendingCount': FieldValue.increment(1),
          'invitedFriendUids': FieldValue.arrayUnion([normalizedTargetUid]),
        });
      } else {
        tx.update(groupRef, {
          'membersCount': FieldValue.increment(1),
          'members': FieldValue.arrayUnion([normalizedTargetUid]),
          'membersList': FieldValue.arrayUnion([normalizedTargetUid]),
          'invitedFriendUids': FieldValue.arrayUnion([normalizedTargetUid]),
        });
        tx.update(_db.collection('chats').doc(groupId), {
          'participants': FieldValue.arrayUnion([normalizedTargetUid]),
          'updatedAt': FieldValue.serverTimestamp(),
        });
      }

      return status;
    }).catchError((error) async {
      if (_isPermissionDenied(error)) {
        await _secureQueue.enqueue(
          type: SecureActionTypes.inviteUserToGroup,
          payload: <String, dynamic>{
            'groupId': groupId,
            'targetUid': normalizedTargetUid,
          },
          dedupeKey: 'invite_group:$inviterUid:$groupId:$normalizedTargetUid',
        );
        return 'queued';
      }
      throw error;
    });

    final groupData = (await groupRef.get()).data() ?? <String, dynamic>{};
    final groupName = (groupData['groupName'] as String? ?? '').trim();
    try {
      await _notificationService.sendAddedToGroupNotification(
        recipientUid: normalizedTargetUid,
        groupId: groupId,
        groupName: groupName,
        addedByUid: inviterUid,
      );
    } catch (_) {
      // Invitation itself succeeded; notification dispatch is best-effort.
    }

    return status;
  }

  Stream<String?> myMembershipStatus(String groupId) {
    final uid = _auth.currentUser?.uid;
    if (uid == null || uid.isEmpty) {
      return Stream<String?>.value(null);
    }

    return _db
        .collection('groups')
        .doc(groupId)
        .collection('members')
        .doc(uid)
        .snapshots()
        .map((doc) => doc.data()?['status'] as String?);
  }

  Stream<int> approvedMembersCount(String groupId) {
    return _db.collection('groups').doc(groupId).snapshots().map((doc) {
      final data = doc.data() ?? const <String, dynamic>{};
      final membersCountRaw = data['membersCount'];
      final membersCountFromField = membersCountRaw is num
          ? membersCountRaw.toInt()
          : int.tryParse((membersCountRaw ?? '').toString().trim()) ?? 0;

      final membersLength = (data['members'] as List<dynamic>? ?? const [])
          .map((item) => item.toString().trim())
          .where((item) => item.isNotEmpty)
          .toSet()
          .length;
      final membersListLength =
          (data['membersList'] as List<dynamic>? ?? const [])
              .map((item) => item.toString().trim())
              .where((item) => item.isNotEmpty)
              .toSet()
              .length;

      return math.max(
        1,
        math.max(
          membersCountFromField,
          math.max(membersLength, membersListLength),
        ),
      );
    });
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> pendingMembersStream(
      String groupId) {
    return _db
        .collection('groups')
        .doc(groupId)
        .collection('members')
        .where('status', isEqualTo: 'pending')
        .snapshots();
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> streamMyGroupsByParticipation() {
    final uid = _requireUid();
    debugPrint('[GroupService] Fetching groups for uid=$uid');

    return _db
        .collection('groups')
        .where(
          Filter.or(
            Filter('adminUid', isEqualTo: uid),
            Filter('members', arrayContains: uid),
          ),
        )
        .orderBy('createdAt', descending: true)
        .snapshots();
  }

  Future<void> debugLogMyGroupsIntegrity() async {
    final uid = _auth.currentUser?.uid;
    debugPrint('[GroupService] Integrity check requested. uid=$uid');
    if (uid == null || uid.isEmpty) {
      debugPrint('[GroupService] Integrity check aborted: no logged-in user.');
      return;
    }

    final adminGroups =
        await _db.collection('groups').where('adminUid', isEqualTo: uid).get();
    final memberListGroups = await _db
        .collection('groups')
        .where('members', arrayContains: uid)
        .get();
    final membershipDocs =
        await _db.collectionGroup('members').where('uid', isEqualTo: uid).get();

    final memberSubGroupIds = <String>{};
    for (final doc in membershipDocs.docs) {
      final groupId = doc.reference.parent.parent?.id;
      if (groupId != null && groupId.isNotEmpty) {
        memberSubGroupIds.add(groupId);
      }
    }

    debugPrint(
        '[GroupService] adminUid groups=${adminGroups.docs.length}, members[] groups=${memberListGroups.docs.length}, members subcollection groups=${memberSubGroupIds.length}');

    final seen = <String>{};
    for (final doc in [...adminGroups.docs, ...memberListGroups.docs]) {
      if (!seen.add(doc.id)) continue;
      final data = doc.data();
      final adminUid = (data['adminUid'] as String?) ?? '';
      final members = List<String>.from(
          (data['members'] as List<dynamic>?) ?? const <String>[]);
      final hasMemberSubDoc = memberSubGroupIds.contains(doc.id);
      debugPrint(
          '[GroupService] group=${doc.id} adminUid=$adminUid membersContainsUid=${members.contains(uid)} hasMemberSubDoc=$hasMemberSubDoc');
    }
  }

  Future<void> sendGroupMessage({
    required String groupId,
    required String text,
    String? imageUrl,
  }) async {
    final senderId = _requireUid();
    await _db.collection('groups').doc(groupId).collection('messages').add({
      'senderId': senderId,
      'text': text.trim(),
      'timestamp': FieldValue.serverTimestamp(),
      'imageUrl': (imageUrl ?? '').trim(),
    });
  }

  Future<String> uploadGroupImage({
    required String groupId,
    required Uint8List imageBytes,
    String? imageFileName,
  }) async {
    final uid = _requireUid();
    final ext = _fileExtension(imageFileName ?? 'group.jpg');
    final imageRef = _storage.ref().child(
        'groups/$uid/$groupId/${DateTime.now().millisecondsSinceEpoch}.$ext');
    await imageRef.putData(imageBytes);
    return imageRef.getDownloadURL();
  }

  Future<void> updateGroupCoreDetails({
    required String groupId,
    required String groupName,
    required String description,
    required String location,
    required DateTime date,
    String? groupImageUrl,
  }) async {
    final payload = <String, dynamic>{
      'groupName': groupName.trim(),
      'description': description.trim(),
      'location': location.trim(),
      'date': Timestamp.fromDate(date),
      'updatedAt': FieldValue.serverTimestamp(),
    };
    if (groupImageUrl != null) {
      payload['groupImageUrl'] = groupImageUrl.trim();
    }

    await _db
        .collection('groups')
        .doc(groupId)
        .set(payload, SetOptions(merge: true));

    final chatPayload = <String, dynamic>{
      'name': groupName.trim(),
      'description': description.trim(),
      'updatedAt': FieldValue.serverTimestamp(),
    };
    if (groupImageUrl != null) {
      chatPayload['groupImageUrl'] = groupImageUrl.trim();
    }
    await _db
        .collection('chats')
        .doc(groupId)
        .set(chatPayload, SetOptions(merge: true));
  }

  Future<String> updateGroupImageAsMember({
    required String groupId,
    required String groupImageUrl,
  }) async {
    _requireUid();
    final normalizedGroupId = groupId.trim();
    final normalizedImageUrl = groupImageUrl.trim();
    if (normalizedGroupId.isEmpty || normalizedImageUrl.isEmpty) {
      throw ArgumentError('groupId and groupImageUrl are required');
    }

    try {
      final batch = _db.batch();
      final groupRef = _db.collection('groups').doc(normalizedGroupId);
      final chatRef = _db.collection('chats').doc(normalizedGroupId);
      final payload = <String, dynamic>{
        'groupImageUrl': normalizedImageUrl,
        'updatedAt': FieldValue.serverTimestamp(),
      };

      batch.set(groupRef, payload, SetOptions(merge: true));
      batch.set(chatRef, payload, SetOptions(merge: true));
      await batch.commit();
      return 'updated';
    } catch (error) {
      if (_isPermissionDenied(error)) {
        throw const GroupJoinException(
          code: 'permission-denied',
          message: 'אין הרשאה לעדכן תמונת קבוצה כרגע. נסה שוב בעוד רגע.',
        );
      }
      rethrow;
    }
  }

  Future<void> updateGroupAdvancedSettings({
    required String groupId,
    required String category,
    required String subCategory,
    required bool isPublic,
    required bool isAdminApprovalRequired,
    required int minScore,
    required bool isMinScoreRequired,
    required int minAge,
    required int maxAge,
  }) async {
    await _requireAdmin(groupId);
    if (!isValidAgeRange(minAge, maxAge)) {
      throw ArgumentError(
        'Age range must be between $minimumUserAge and $maximumAgeRange.',
      );
    }

    await _db.collection('groups').doc(groupId).set({
      'category': category.trim(),
      'subCategory': subCategory.trim(),
      'isPublic': isPublic,
      'isAdminApprovalRequired': isAdminApprovalRequired,
      'minScore': minScore,
      'isMinScoreRequired': isMinScoreRequired,
      'ageRange': {
        'min': minAge,
        'max': maxAge,
      },
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    await _db.collection('chats').doc(groupId).set({
      'isPublic': isPublic,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> removeMember(String groupId, String uid) async {
    final myUid = _requireUid();
    final groupRef = _db.collection('groups').doc(groupId);
    final memberRef = groupRef.collection('members').doc(uid);

    try {
      await _db.runTransaction((tx) async {
        final groupSnap = await tx.get(groupRef);
        if (!groupSnap.exists) {
          throw FirebaseException(
              plugin: 'cloud_firestore', message: 'Group not found');
        }

        final groupData = groupSnap.data() ?? <String, dynamic>{};
        final adminUid = (groupData['adminUid'] as String?) ?? '';
        if (adminUid != myUid) {
          throw FirebaseAuthException(
            code: 'permission-denied',
            message: 'Only group admin can remove members.',
          );
        }
        if (uid == adminUid) {
          throw FirebaseAuthException(
            code: 'invalid-action',
            message: 'Admin cannot remove themselves from group settings.',
          );
        }

        final memberSnap = await tx.get(memberRef);
        final status = (memberSnap.data()?['status'] as String?) ?? '';
        if (memberSnap.exists) {
          tx.delete(memberRef);
        }

        final updates = <String, dynamic>{
          'members': FieldValue.arrayRemove([uid]),
          'membersList': FieldValue.arrayRemove([uid]),
          'invitedFriendUids': FieldValue.arrayRemove([uid]),
        };
        if (status == 'approved') {
          updates['membersCount'] = FieldValue.increment(-1);
        } else if (status == 'pending') {
          updates['pendingCount'] = FieldValue.increment(-1);
        }
        tx.update(groupRef, updates);

        tx.update(_db.collection('chats').doc(groupId), {
          'participants': FieldValue.arrayRemove([uid]),
          'updatedAt': FieldValue.serverTimestamp(),
        });
      });
    } catch (error) {
      if (_isPermissionDenied(error)) {
        await _secureQueue.enqueue(
          type: SecureActionTypes.removeGroupMember,
          payload: <String, dynamic>{
            'groupId': groupId,
            'targetUid': uid,
          },
          dedupeKey: 'remove_group_member:$myUid:$groupId:$uid',
        );
        return;
      }
      rethrow;
    }
  }

  Future<void> leaveGroup(String groupId) async {
    final uid = _requireUid();
    final groupRef = _db.collection('groups').doc(groupId);
    final memberRef = groupRef.collection('members').doc(uid);

    var groupExists = false;
    var wasApprovedMember = false;
    var wasPendingMember = false;

    try {
      await _db.runTransaction((tx) async {
        final groupSnap = await tx.get(groupRef);
        if (!groupSnap.exists) {
          throw FirebaseException(
            plugin: 'cloud_firestore',
            message: 'Group not found',
          );
        }

        groupExists = true;

        final memberSnap = await tx.get(memberRef);
        final memberStatus =
            (memberSnap.data()?['status'] as String? ?? '').trim();
        wasApprovedMember = memberStatus == 'approved';
        wasPendingMember = memberStatus == 'pending';

        if (memberSnap.exists) {
          tx.delete(memberRef);
        }

        final updates = <String, dynamic>{
          'members': FieldValue.arrayRemove([uid]),
          'membersList': FieldValue.arrayRemove([uid]),
          'invitedFriendUids': FieldValue.arrayRemove([uid]),
          'updatedAt': FieldValue.serverTimestamp(),
        };

        if (wasApprovedMember) {
          updates['membersCount'] = FieldValue.increment(-1);
        } else if (wasPendingMember) {
          updates['pendingCount'] = FieldValue.increment(-1);
        }

        tx.update(groupRef, updates);
        tx.update(_db.collection('chats').doc(groupId), {
          'participants': FieldValue.arrayRemove([uid]),
          'updatedAt': FieldValue.serverTimestamp(),
        });
      });
    } catch (error) {
      if (_isPermissionDenied(error)) {
        throw const GroupJoinException(
          code: 'permission-denied',
          message: 'אין הרשאה לצאת מהקבוצה כרגע. נסה שוב בעוד רגע.',
        );
      }
      rethrow;
    }

    if (!groupExists || (!wasApprovedMember && !wasPendingMember)) {
      return;
    }

    try {
      final profileSnap = await _db.collection('users_public').doc(uid).get();
      final profileData = profileSnap.data() ?? <String, dynamic>{};
      final displayName = ((profileData['displayName'] as String?) ??
              (profileData['username'] as String?) ??
              '')
          .trim();
      final actorName = displayName.isNotEmpty ? displayName : 'חבר/ת קבוצה';

      await groupRef.collection('messages').add({
        'senderId': '',
        'text': '$actorName עזב/ה את הקבוצה',
        'timestamp': FieldValue.serverTimestamp(),
        'messageType': 'text',
        'senderName': 'מערכת',
      });
    } catch (_) {
      // System leave message is best-effort only.
    }
  }

  Future<void> _deleteCollectionInBatches(
    CollectionReference<Map<String, dynamic>> collectionRef,
  ) async {
    while (true) {
      final snapshot = await collectionRef.limit(200).get();
      if (snapshot.docs.isEmpty) {
        break;
      }

      final batch = _db.batch();
      for (final doc in snapshot.docs) {
        batch.delete(doc.reference);
      }
      await batch.commit();

      if (snapshot.docs.length < 200) {
        break;
      }
    }
  }

  Future<void> closeGroup(String groupId) async {
    await _requireAdmin(groupId);

    final groupRef = _db.collection('groups').doc(groupId);
    final chatRef = _db.collection('chats').doc(groupId);

    final groupSnap = await groupRef.get();
    if (!groupSnap.exists) {
      return;
    }

    final groupImageUrl =
        (groupSnap.data()?['groupImageUrl'] as String? ?? '').trim();

    await _deleteCollectionInBatches(groupRef.collection('messages'));
    await _deleteCollectionInBatches(groupRef.collection('attendance'));
    await _deleteCollectionInBatches(groupRef.collection('members'));

    await chatRef.delete();
    await groupRef.delete();

    if (groupImageUrl.isNotEmpty) {
      try {
        final storageRef = _storage.refFromURL(groupImageUrl);
        await storageRef.delete();
      } catch (_) {
        // Ignore storage cleanup failures so group closure always completes.
      }
    }
  }

  Future<void> confirmAttendance(String groupId) async {
    final uid = _requireUid();
    await _db
        .collection('groups')
        .doc(groupId)
        .collection('attendance')
        .doc(uid)
        .set({
      'uid': uid,
      'respondedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> attendanceStream(String groupId) {
    return _db
        .collection('groups')
        .doc(groupId)
        .collection('attendance')
        .orderBy('respondedAt', descending: false)
        .snapshots();
  }

  Stream<bool> myAttendanceStream(String groupId) {
    final uid = _auth.currentUser?.uid;
    if (uid == null || uid.isEmpty) {
      return Stream<bool>.value(false);
    }

    return _db
        .collection('groups')
        .doc(groupId)
        .collection('attendance')
        .doc(uid)
        .snapshots()
        .map((doc) => doc.exists);
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> messagesStream(String groupId) {
    return _db
        .collection('groups')
        .doc(groupId)
        .collection('messages')
        .orderBy('timestamp', descending: false)
        .snapshots();
  }

  Future<void> backfillChatsFromGroups() async {
    final groupsSnapshot = await _db.collection('groups').get();
    final batch = _db.batch();

    for (final groupDoc in groupsSnapshot.docs) {
      final data = groupDoc.data();
      final rawMembers = data['membersList'] ?? data['members'];
      final invitedFriendUids =
          (data['invitedFriendUids'] as List<dynamic>? ?? const <dynamic>[])
              .map((e) => e.toString().trim())
              .where((e) => e.isNotEmpty)
              .toSet();
      final participantsSet = rawMembers is List
          ? rawMembers.map((e) => e.toString()).toList(growable: false)
          : const <String>[];
      final participants = <String>{...participantsSet, ...invitedFriendUids}
          .toList(growable: false);

      batch.set(
        _db.collection('chats').doc(groupDoc.id),
        {
          'id': groupDoc.id,
          'name': (data['groupName'] as String?) ?? 'Group',
          'description': (data['description'] as String?) ?? '',
          'groupImageUrl': (data['groupImageUrl'] as String?) ?? '',
          'isPublic': (data['isPublic'] as bool?) ?? false,
          'participants': participants,
          'sourceGroupId': groupDoc.id,
          'createdAt': data['createdAt'] ?? FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );
    }

    await batch.commit();
  }

  String _fileExtension(String path) {
    final dotIndex = path.lastIndexOf('.');
    if (dotIndex == -1 || dotIndex == path.length - 1) {
      return 'jpg';
    }
    return path.substring(dotIndex + 1).toLowerCase();
  }
}
