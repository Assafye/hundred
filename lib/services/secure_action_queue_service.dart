import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class SecureActionTypes {
  static const String followUser = 'follow_user';
  static const String unfollowUser = 'unfollow_user';
  static const String cancelFollowRequest = 'cancel_follow_request';

  static const String togglePostLike = 'toggle_post_like';
  static const String togglePostSave = 'toggle_post_save';
  static const String registerPostShare = 'register_post_share';
  static const String syncPostCommentSideEffects =
      'sync_post_comment_side_effects';

  static const String joinGroup = 'join_group';
  static const String cancelGroupJoinRequest = 'cancel_group_join_request';
  static const String inviteUserToGroup = 'invite_user_to_group';
  static const String removeGroupMember = 'remove_group_member';
  static const String leaveGroup = 'leave_group';
  static const String updateGroupImage = 'update_group_image';

  static const String joinPublicChat = 'join_public_chat';
}

class SecureActionQueueService {
  SecureActionQueueService({FirebaseFirestore? db, FirebaseAuth? auth})
      : _db = db ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance;

  final FirebaseFirestore _db;
  final FirebaseAuth _auth;

  String _requireUid() {
    final uid = _auth.currentUser?.uid.trim() ?? '';
    if (uid.isEmpty) {
      throw FirebaseException(
        plugin: 'auth',
        code: 'not-authenticated',
        message: 'User must be logged in to enqueue secure actions.',
      );
    }
    return uid;
  }

  Future<void> enqueue({
    required String type,
    required Map<String, dynamic> payload,
    String dedupeKey = '',
  }) async {
    final uid = _requireUid();
    final normalizedType = type.trim();
    if (normalizedType.isEmpty) {
      throw ArgumentError('type is required');
    }

    final actionRef = _db
        .collection('users')
        .doc(uid)
        .collection('secure_actions')
        .doc();

    await actionRef.set(<String, dynamic>{
      'id': actionRef.id,
      'actorUid': uid,
      'type': normalizedType,
      'payload': payload,
      'status': 'pending',
      'dedupeKey': dedupeKey.trim(),
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
      'attempts': 0,
      'lastError': '',
    });
  }
}
