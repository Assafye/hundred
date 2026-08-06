import 'dart:async';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';

import 'notification_service.dart';
import 'secure_action_queue_service.dart';

class ChatService {
  ChatService({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
    FirebaseStorage? storage,
  })
      : _db = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance,
        _storage = storage ?? FirebaseStorage.instance;

  final FirebaseFirestore _db;
  final FirebaseAuth _auth;
  final FirebaseStorage _storage;
  final NotificationService _notificationService = NotificationService();
  final SecureActionQueueService _secureQueue = SecureActionQueueService();

  bool _isPermissionDenied(Object error) {
    return error is FirebaseException && error.code == 'permission-denied';
  }

  CollectionReference<Map<String, dynamic>> get _chats =>
      _db.collection('chats');
  CollectionReference<Map<String, dynamic>> get _users =>
      _db.collection('users');
  CollectionReference<Map<String, dynamic>> get _publicUsers =>
      _db.collection('users_public');

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

  Future<String> createChat({
    required String name,
    required bool isPublic,
    String? creatorUserId,
  }) async {
    final ownerId = (creatorUserId != null && creatorUserId.isNotEmpty)
        ? creatorUserId
        : _requireUid();
    final chatRef = _chats.doc();

    await chatRef.set({
      'id': chatRef.id,
      'name': name.trim(),
      'isPublic': isPublic,
      'isDirect': false,
      'participants': <String>[ownerId],
      'lastMessage': '',
      'lastMessageSenderName': '',
      'lastMessageSenderId': '',
      'lastMessageAt': FieldValue.serverTimestamp(),
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });

    return chatRef.id;
  }

  Future<String> findOrCreateDirectChat({
    required String otherUserId,
    required String otherDisplayName,
    String? otherAvatarUrl,
  }) async {
    final myUid = _requireUid();
    if (otherUserId.isEmpty) {
      throw ArgumentError('otherUserId cannot be empty');
    }

    final snapshot =
        await _chats.where('participants', arrayContains: myUid).get();
    for (final doc in snapshot.docs) {
      final data = doc.data();
      final participants = List<String>.from(
          (data['participants'] as List<dynamic>?) ?? const <String>[]);
      final isPublic = (data['isPublic'] as bool?) ?? false;
      final isDirect = (data['isDirect'] as bool?) ??
          (!isPublic && participants.length == 2);
      if (isDirect && participants.contains(otherUserId)) {
        return doc.id;
      }
    }

    final chatRef = _chats.doc();
    await chatRef.set({
      'id': chatRef.id,
      'name': otherDisplayName.trim().isNotEmpty
          ? otherDisplayName.trim()
          : otherUserId,
      'groupImageUrl': (otherAvatarUrl ?? '').trim(),
      'isPublic': false,
      'isDirect': true,
      'participants': <String>[myUid, otherUserId],
      'lastMessage': '',
      'lastMessageSenderName': '',
      'lastMessageSenderId': '',
      'lastMessageAt': FieldValue.serverTimestamp(),
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });

    return chatRef.id;
  }

  Future<void> joinChatAtomically({
    required String chatId,
    String? userId,
  }) async {
    final uid = (userId != null && userId.isNotEmpty) ? userId : _requireUid();
    final chatRef = _chats.doc(chatId);

    try {
      await _db.runTransaction((tx) async {
        final snapshot = await tx.get(chatRef);
        if (!snapshot.exists) {
          throw FirebaseException(
            plugin: 'cloud_firestore',
            message: 'Chat not found',
          );
        }

        final data = snapshot.data() ?? <String, dynamic>{};
        final rawParticipants = data['participants'];
        final participants = rawParticipants is List
          ? rawParticipants.map((e) => e.toString()).toList()
          : <String>[];

        if (participants.contains(uid)) {
          return;
        }

        tx.update(chatRef, {
          'participants': FieldValue.arrayUnion(<String>[uid]),
          'updatedAt': FieldValue.serverTimestamp(),
        });
      });
    } catch (error) {
      if (_isPermissionDenied(error)) {
        await _secureQueue.enqueue(
          type: SecureActionTypes.joinPublicChat,
          payload: <String, dynamic>{
            'chatId': chatId,
          },
          dedupeKey: 'join_public_chat:$uid:$chatId',
        );
        return;
      }
      rethrow;
    }
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> streamUserChats(String userId) {
    return _chats.where('participants', arrayContains: userId).snapshots();
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> streamPublicChats() {
    return _chats.where('isPublic', isEqualTo: true).snapshots();
  }

  Stream<List<QueryDocumentSnapshot<Map<String, dynamic>>>>
      streamPublicChatsExcludingUser(String userId) {
    return streamPublicChats().map((snapshot) {
      return snapshot.docs.where((doc) {
        final rawParticipants = doc.data()['participants'];
        final participants = rawParticipants is List
            ? rawParticipants.map((e) => e.toString()).toList(growable: false)
            : const <String>[];
        return !participants.contains(userId);
      }).toList(growable: false);
    });
  }

  Stream<List<QueryDocumentSnapshot<Map<String, dynamic>>>> streamRelevantChats(
      String userId) {
    return Stream.multi((controller) {
      QuerySnapshot<Map<String, dynamic>>? myChatsSnapshot;
      QuerySnapshot<Map<String, dynamic>>? publicChatsSnapshot;

      void emitMerged() {
        if (myChatsSnapshot == null || publicChatsSnapshot == null) {
          return;
        }

        final merged = <String, QueryDocumentSnapshot<Map<String, dynamic>>>{};

        for (final doc in myChatsSnapshot!.docs) {
          merged[doc.id] = doc;
        }

        for (final doc in publicChatsSnapshot!.docs) {
          final rawParticipants = doc.data()['participants'];
          final participants = rawParticipants is List
              ? rawParticipants.map((e) => e.toString()).toList(growable: false)
              : const <String>[];
          if (participants.contains(userId)) {
            continue;
          }
          merged[doc.id] = doc;
        }

        final chats = merged.values.toList(growable: false);
        chats.sort((a, b) {
          final aTimestamp = (a.data()['lastMessageAt'] as Timestamp?) ??
              (a.data()['updatedAt'] as Timestamp?) ??
              (a.data()['createdAt'] as Timestamp?);
          final bTimestamp = (b.data()['lastMessageAt'] as Timestamp?) ??
              (b.data()['updatedAt'] as Timestamp?) ??
              (b.data()['createdAt'] as Timestamp?);
          final aDate =
              aTimestamp?.toDate() ?? DateTime.fromMillisecondsSinceEpoch(0);
          final bDate =
              bTimestamp?.toDate() ?? DateTime.fromMillisecondsSinceEpoch(0);
          return bDate.compareTo(aDate);
        });
        controller.add(chats);
      }

      final myChatsSub = streamUserChats(userId).listen(
        (snapshot) {
          myChatsSnapshot = snapshot;
          emitMerged();
        },
        onError: controller.addError,
      );

      final publicChatsSub = streamPublicChats().listen(
        (snapshot) {
          publicChatsSnapshot = snapshot;
          emitMerged();
        },
        onError: controller.addError,
      );

      controller.onCancel = () async {
        await myChatsSub.cancel();
        await publicChatsSub.cancel();
      };
    });
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> streamChatMessages(
      String chatId) {
    return _chats
        .doc(chatId)
        .collection('messages')
        .orderBy('createdAt', descending: true)
        .snapshots();
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> streamChatReadReceipts(
      String chatId) {
    return _chats.doc(chatId).collection('readReceipts').snapshots();
  }

  Stream<Map<String, DateTime?>> streamMyReadReceipts({
    required String userId,
    required List<String> chatIds,
  }) {
    if (chatIds.isEmpty) {
      return Stream.value(const <String, DateTime?>{});
    }

    final sortedChatIds = chatIds.toList(growable: false)..sort();

    return Stream.multi((controller) {
      final values = <String, DateTime?>{};
      final subscriptions =
          <StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>>[];

      void emit() {
        controller.add(Map<String, DateTime?>.unmodifiable(values));
      }

      for (final chatId in sortedChatIds) {
        final sub = _chats
            .doc(chatId)
            .collection('readReceipts')
            .doc(userId)
            .snapshots()
            .listen(
          (snapshot) {
            final lastReadAt =
                (snapshot.data()?['lastReadAt'] as Timestamp?)?.toDate();
            values[chatId] = lastReadAt;
            emit();
          },
          onError: controller.addError,
        );
        subscriptions.add(sub);
      }

      emit();

      controller.onCancel = () async {
        for (final sub in subscriptions) {
          await sub.cancel();
        }
      };
    });
  }

  Future<void> sendMessage({
    required String chatId,
    required String text,
    Map<String, dynamic>? replyTo,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return;
    }

    final currentUser = _auth.currentUser;
    final uid = currentUser?.uid;
    if (uid == null || uid.isEmpty) {
      throw FirebaseAuthException(
        code: 'not-authenticated',
        message: 'User must be logged in to send a message.',
      );
    }

    final chatRef = _chats.doc(chatId);
    final chatContext = await _loadChatContext(chatRef);
    final participants = chatContext['participants'] as List<String>;
    final chatName = chatContext['chatName'] as String;
    final senderIdentity = await _resolveSenderIdentity(uid, currentUser);
    final senderName = senderIdentity['name'] as String;
    final senderAvatarUrl = senderIdentity['avatarUrl'] as String;

    Map<String, dynamic>? normalizedReplyTo;
    if (replyTo != null) {
      normalizedReplyTo = Map<String, dynamic>.from(replyTo);
      normalizedReplyTo.removeWhere((key, value) => value == null);
    }

    await chatRef.collection('messages').add({
      'senderId': uid,
      'senderName': senderName,
      'senderAvatarUrl': senderAvatarUrl,
      'text': trimmed,
      if (normalizedReplyTo != null) 'replyTo': normalizedReplyTo,
      'timestamp': FieldValue.serverTimestamp(),
      'createdAt': FieldValue.serverTimestamp(),
    });

    await chatRef.set({
      'lastMessage': trimmed,
      'lastMessageSenderName': senderName,
      'lastMessageSenderId': uid,
      'lastMessageAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    await _notificationService.sendNewMessageNotification(
      recipientUids: participants,
      chatId: chatId,
      chatName: chatName,
      messageText: trimmed,
      senderUid: uid,
    );
  }

  Future<void> sendMediaMessage({
    required String chatId,
    required List<Map<String, dynamic>> mediaDrafts,
  }) async {
    if (mediaDrafts.isEmpty) {
      return;
    }

    final currentUser = _auth.currentUser;
    final uid = currentUser?.uid;
    if (uid == null || uid.isEmpty) {
      throw FirebaseAuthException(
        code: 'not-authenticated',
        message: 'User must be logged in to send media messages.',
      );
    }

    final chatRef = _chats.doc(chatId.trim());
    final chatContext = await _loadChatContext(chatRef);
    final participants = chatContext['participants'] as List<String>;
    final chatName = chatContext['chatName'] as String;
    final senderIdentity = await _resolveSenderIdentity(uid, currentUser);
    final senderName = senderIdentity['name'] as String;
    final senderAvatarUrl = senderIdentity['avatarUrl'] as String;

    final uploadedItems = <Map<String, dynamic>>[];
    for (var i = 0; i < mediaDrafts.length; i++) {
      final draft = mediaDrafts[i];
      final bytes = draft['bytes'] as Uint8List?;
      final extension = (draft['extension'] as String? ?? '').trim();
      final caption = (draft['caption'] as String? ?? '').trim();
      final isVideo = (draft['isVideo'] as bool?) ?? false;

      if (bytes == null || bytes.isEmpty || extension.isEmpty) {
        continue;
      }

      final uploadedUrl = await _uploadChatAsset(
        chatId: chatRef.id,
        senderUid: uid,
        data: bytes,
        extension: extension,
        folder: isVideo ? 'videos' : 'images',
      );

      uploadedItems.add(<String, dynamic>{
        'url': uploadedUrl,
        'isVideo': isVideo,
        'caption': caption,
        'order': i,
      });
    }

    if (uploadedItems.isEmpty) {
      return;
    }

    await chatRef.collection('messages').add({
      'senderId': uid,
      'senderName': senderName,
      'senderAvatarUrl': senderAvatarUrl,
      'text': '',
      'messageType': 'media',
      'mediaItems': uploadedItems,
      'timestamp': FieldValue.serverTimestamp(),
      'createdAt': FieldValue.serverTimestamp(),
    });

    final preview = uploadedItems.length == 1 ? 'שלח מדיה' : 'שלח ${uploadedItems.length} פריטי מדיה';
    try {
      await chatRef.set({
        'lastMessage': preview,
        'lastMessageType': 'media',
        'lastMessageSenderName': senderName,
        'lastMessageSenderId': uid,
        'lastMessageAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (_) {
      // Best effort only. The media message already exists even if metadata writes are blocked.
    }

    try {
      await _notificationService.sendNewMessageNotification(
        recipientUids: participants,
        chatId: chatRef.id,
        chatName: chatName,
        messageText: preview,
        senderUid: uid,
      );
    } catch (_) {
      // Best effort only. Do not fail the media send if notification writes are blocked.
    }
  }

  Future<void> sendAudioMessage({
    required String chatId,
    required Uint8List audioBytes,
    required String extension,
    required int durationMs,
  }) async {
    if (audioBytes.isEmpty || extension.trim().isEmpty) {
      return;
    }

    final currentUser = _auth.currentUser;
    final uid = currentUser?.uid;
    if (uid == null || uid.isEmpty) {
      throw FirebaseAuthException(
        code: 'not-authenticated',
        message: 'User must be logged in to send audio messages.',
      );
    }

    final chatRef = _chats.doc(chatId.trim());
    final chatContext = await _loadChatContext(chatRef);
    final participants = chatContext['participants'] as List<String>;
    final chatName = chatContext['chatName'] as String;
    final senderIdentity = await _resolveSenderIdentity(uid, currentUser);
    final senderName = senderIdentity['name'] as String;
    final senderAvatarUrl = senderIdentity['avatarUrl'] as String;

    final audioUrl = await _uploadChatAsset(
      chatId: chatRef.id,
      senderUid: uid,
      data: audioBytes,
      extension: extension,
      folder: 'audio',
    );

    await chatRef.collection('messages').add({
      'senderId': uid,
      'senderName': senderName,
      'senderAvatarUrl': senderAvatarUrl,
      'text': '',
      'messageType': 'audio',
      'audioUrl': audioUrl,
      'audioDurationMs': durationMs,
      'timestamp': FieldValue.serverTimestamp(),
      'createdAt': FieldValue.serverTimestamp(),
    });

    const preview = 'הודעת קול';
    await chatRef.set({
      'lastMessage': preview,
      'lastMessageType': 'audio',
      'lastMessageSenderName': senderName,
      'lastMessageSenderId': uid,
      'lastMessageAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    await _notificationService.sendNewMessageNotification(
      recipientUids: participants,
      chatId: chatRef.id,
      chatName: chatName,
      messageText: preview,
      senderUid: uid,
    );
  }

  Future<void> sendPostMessage({
    required String chatId,
    required Map<String, dynamic> postPayload,
    String note = '',
  }) async {
    final currentUser = _auth.currentUser;
    final uid = currentUser?.uid;
    if (uid == null || uid.isEmpty) {
      throw FirebaseAuthException(
        code: 'not-authenticated',
        message: 'User must be logged in to send a message.',
      );
    }

    final normalizedChatId = chatId.trim();
    if (normalizedChatId.isEmpty) {
      throw ArgumentError('chatId cannot be empty');
    }

    final postId = (postPayload['postId'] as String? ?? '').trim();
    if (postId.isEmpty) {
      throw ArgumentError('postPayload.postId is required');
    }

    final chatRef = _chats.doc(normalizedChatId);
    final senderProfile = await _bestEffortSenderProfile(uid);
    final senderNameFromDb =
        _displayNameForProfile(senderProfile, fallback: '');
    final senderNameFromAuth = (currentUser?.displayName ?? '').trim();
    final senderAvatarUrlFromDb = _avatarUrlForProfile(senderProfile);
    final senderAvatarUrlFromAuth = (currentUser?.photoURL ?? '').trim();
    final senderName = senderNameFromDb.isNotEmpty
        ? senderNameFromDb
        : (senderNameFromAuth.isNotEmpty ? senderNameFromAuth : 'משתמש');
    final senderAvatarUrl = senderAvatarUrlFromDb.isNotEmpty
        ? senderAvatarUrlFromDb
        : senderAvatarUrlFromAuth;

    final normalizedNote = note.trim();
    final normalizedPostPayload = <String, dynamic>{
      'postId': postId,
      'title': (postPayload['title'] as String? ?? '').trim(),
      'description': (postPayload['description'] as String? ?? '').trim(),
      'imageUrl': (postPayload['imageUrl'] as String? ?? '').trim(),
      'mediaUrl': (postPayload['mediaUrl'] as String? ?? '').trim(),
      'thumbnailUrl': (postPayload['thumbnailUrl'] as String? ?? '').trim(),
      'videoThumbnailUrl':
          (postPayload['videoThumbnailUrl'] as String? ?? '').trim(),
      'mediaUrls': (postPayload['mediaUrls'] as List<dynamic>? ??
              const <dynamic>[])
          .map((item) => item.toString().trim())
          .where((item) => item.isNotEmpty)
          .toList(growable: false),
      'mediaItems': (postPayload['mediaItems'] as List<dynamic>? ??
          const <dynamic>[])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList(growable: false),
      'authorId': (postPayload['authorId'] as String? ?? '').trim(),
      'category': (postPayload['category'] as String? ?? '').trim(),
      'subCategory': (postPayload['subCategory'] as String? ?? '').trim(),
    };

    await chatRef.collection('messages').add({
      'senderId': uid,
      'senderName': senderName,
      'senderAvatarUrl': senderAvatarUrl,
      'text': normalizedNote,
      'messageType': 'post',
      'post': normalizedPostPayload,
      'timestamp': FieldValue.serverTimestamp(),
      'createdAt': FieldValue.serverTimestamp(),
    });

    final preview =
        normalizedNote.isEmpty ? 'שיתף פוסט' : 'שיתף פוסט: $normalizedNote';
    await chatRef.set({
      'lastMessage': preview,
      'lastMessageSenderName': senderName,
      'lastMessageSenderId': uid,
      'lastMessageType': 'post',
      'lastMessageAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<Map<String, List<Map<String, dynamic>>>>
      fetchPostShareTargets() async {
    final uid = _requireUid();

    final userDoc = await _users.doc(uid).get();
    final userData = userDoc.data() ?? <String, dynamic>{};
    final friendsRaw =
        (userData['friends'] as List<dynamic>?) ?? const <dynamic>[];
    final followingRaw =
        (userData['following'] as List<dynamic>?) ?? const <dynamic>[];

    final friendIds = (friendsRaw.isNotEmpty ? friendsRaw : followingRaw)
        .map((value) => value.toString().trim())
        .where((value) => value.isNotEmpty && value != uid)
        .toSet()
        .toList(growable: false)
      ..sort();

    final friendSummaries = await fetchUserSummaries(friendIds);
    final friends = friendIds.map((friendId) {
      final summary = friendSummaries[friendId] ?? const <String, String>{};
      return <String, dynamic>{
        'type': 'friend',
        'userId': friendId,
        'name': (summary['name'] ?? '').trim().isNotEmpty
            ? (summary['name'] ?? '').trim()
            : friendId,
        'avatarUrl': (summary['avatarUrl'] ?? '').trim(),
      };
    }).toList(growable: false);

    final chatsSnapshot =
        await _chats.where('participants', arrayContains: uid).get();
    final groups = chatsSnapshot.docs.where((doc) {
      final data = doc.data();
      final isDirect = (data['isDirect'] as bool?) ?? false;
      return !isDirect;
    }).map((doc) {
      final data = doc.data();
      final name = (data['name'] as String? ?? '').trim();
      final avatarUrl = (data['groupImageUrl'] as String? ?? '').trim();
      return <String, dynamic>{
        'type': 'group',
        'chatId': doc.id,
        'name': name.isNotEmpty ? name : 'קבוצה',
        'avatarUrl': avatarUrl,
      };
    }).toList(growable: false)
      ..sort((a, b) => (a['name'] as String)
          .toLowerCase()
          .compareTo((b['name'] as String).toLowerCase()));

    return <String, List<Map<String, dynamic>>>{
      'friends': friends,
      'groups': groups,
    };
  }

  Future<void> markChatAsRead({
    required String chatId,
    required String lastReadMessageId,
    required DateTime lastReadAt,
  }) async {
    final uid = _requireUid();
    final profile = await _bestEffortSenderProfile(uid);

    await _chats.doc(chatId).collection('readReceipts').doc(uid).set({
      'uid': uid,
      'chatId': chatId,
      'displayName': _displayNameForProfile(profile, fallback: 'משתמש'),
      'profilePictureUrl':
          (profile['profilePictureUrl'] as String? ?? '').trim(),
      'lastReadMessageId': lastReadMessageId,
      'lastReadAt': Timestamp.fromDate(lastReadAt),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> markChatAsReadToLatestMessage({required String chatId}) async {
    final messagesRef = _chats.doc(chatId).collection('messages');

    QueryDocumentSnapshot<Map<String, dynamic>>? latestMessage;

    final byTimestamp =
        await messagesRef.orderBy('timestamp', descending: true).limit(1).get();
    if (byTimestamp.docs.isNotEmpty) {
      latestMessage = byTimestamp.docs.first;
    }

    if (latestMessage == null) {
      final byCreatedAt = await messagesRef
          .orderBy('createdAt', descending: true)
          .limit(1)
          .get();
      if (byCreatedAt.docs.isNotEmpty) {
        latestMessage = byCreatedAt.docs.first;
      }
    }

    if (latestMessage == null) {
      return;
    }

    final data = latestMessage.data();
    final latestAt = (data['timestamp'] as Timestamp?)?.toDate() ??
        (data['createdAt'] as Timestamp?)?.toDate() ??
        DateTime.now();

    await markChatAsRead(
      chatId: chatId,
      lastReadMessageId: latestMessage.id,
      lastReadAt: latestAt,
    );
  }

  Future<Map<String, Map<String, String>>> fetchUserSummaries(
      List<String> userIds) async {
    final uniqueIds = userIds
      .map((id) => id.trim())
      .where((id) => id.isNotEmpty)
      .toSet()
      .toList(growable: false);
    if (uniqueIds.isEmpty) {
      return const <String, Map<String, String>>{};
    }

    final summaries = <String, Map<String, String>>{};
    const batchSize = 10;

    try {
      for (var start = 0; start < uniqueIds.length; start += batchSize) {
        final end = (start + batchSize < uniqueIds.length)
            ? start + batchSize
            : uniqueIds.length;
        final chunk = uniqueIds.sublist(start, end);
        final snapshot = await _publicUsers
            .where(FieldPath.documentId, whereIn: chunk)
            .get();

        for (final doc in snapshot.docs) {
          final data = doc.data();
          final isDeleted = (data['isDeleted'] as bool?) ?? false;
          if (isDeleted) {
            summaries[doc.id] = const <String, String>{
              'name': 'פרופיל מחוק',
              'avatarUrl': '',
            };
            continue;
          }
          summaries[doc.id] = {
            'name': _displayNameForProfile(data, fallback: ''),
            'avatarUrl': _avatarUrlForProfile(data),
          };
        }
      }

      final idsNeedingFallback = uniqueIds.where((uid) {
        final summary = summaries[uid];
        if (summary == null) {
          return true;
        }
        final name = (summary['name'] ?? '').trim();
        final avatarUrl = (summary['avatarUrl'] ?? '').trim();
        return name.isEmpty || avatarUrl.isEmpty;
      }).toList(growable: false);

      for (var start = 0;
          start < idsNeedingFallback.length;
          start += batchSize) {
        final end = (start + batchSize < idsNeedingFallback.length)
            ? start + batchSize
            : idsNeedingFallback.length;
        final chunk = idsNeedingFallback.sublist(start, end);
        QuerySnapshot<Map<String, dynamic>>? snapshot;
        try {
          snapshot = await _users.where(FieldPath.documentId, whereIn: chunk).get();
        } catch (error) {
          if (!_isPermissionDenied(error)) {
            rethrow;
          }
          continue;
        }

        for (final doc in snapshot.docs) {
          final data = doc.data();
          final isDeleted = (data['isDeleted'] as bool?) ?? false;
          if (isDeleted) {
            summaries[doc.id] = const <String, String>{
              'name': 'פרופיל מחוק',
              'avatarUrl': '',
            };
            continue;
          }
          final existing = summaries[doc.id] ?? const <String, String>{};
          final existingName = (existing['name'] ?? '').trim();
          final existingAvatarUrl = (existing['avatarUrl'] ?? '').trim();

          final fallbackName = _displayNameForProfile(data, fallback: '');
            final fallbackAvatarUrl = _avatarUrlForProfile(data);

          summaries[doc.id] = {
            'name': existingName.isNotEmpty ? existingName : fallbackName,
            'avatarUrl': existingAvatarUrl.isNotEmpty
                ? existingAvatarUrl
                : fallbackAvatarUrl,
          };
        }
      }

      final keysStillNeedingFallback = uniqueIds.where((key) {
        final summary = summaries[key];
        if (summary == null) {
          return true;
        }
        final name = (summary['name'] ?? '').trim();
        final avatarUrl = (summary['avatarUrl'] ?? '').trim();
        return name.isEmpty || avatarUrl.isEmpty;
      }).toList(growable: false);

      final keysByUsername = <String, List<String>>{};
      for (final key in keysStillNeedingFallback) {
        final normalizedUsername = _normalizeUsernameLookupKey(key);
        if (normalizedUsername.isEmpty) {
          continue;
        }
        keysByUsername.putIfAbsent(normalizedUsername, () => <String>[]).add(key);
      }

      Future<void> enrichByUsername(
        CollectionReference<Map<String, dynamic>> source,
      ) async {
        Future<void> queryByField(String fieldName) async {
          final usernames = keysByUsername.keys.toList(growable: false);
          for (var start = 0; start < usernames.length; start += batchSize) {
            final end = (start + batchSize < usernames.length)
                ? start + batchSize
                : usernames.length;
            final chunk = usernames.sublist(start, end);
            final snapshot = await source.where(fieldName, whereIn: chunk).get();

            for (final doc in snapshot.docs) {
              final data = doc.data();
              final isDeleted = (data['isDeleted'] as bool?) ?? false;
              final usernameKey = _normalizeUsernameLookupKey(
                (fieldName == 'usernameLowercase'
                        ? data['usernameLowercase']
                        : data['username'])
                    .toString(),
              );
              if (usernameKey.isEmpty) {
                continue;
              }

              final matchingKeys =
                  keysByUsername[usernameKey] ?? const <String>[];
              if (matchingKeys.isEmpty) {
                continue;
              }

              for (final key in matchingKeys) {
                if (isDeleted) {
                  summaries[key] = const <String, String>{
                    'name': 'פרופיל מחוק',
                    'avatarUrl': '',
                  };
                  continue;
                }

                final existing = summaries[key] ?? const <String, String>{};
                final existingName = (existing['name'] ?? '').trim();
                final existingAvatarUrl = (existing['avatarUrl'] ?? '').trim();
                final fallbackName = _displayNameForProfile(data, fallback: '');
                final fallbackAvatarUrl = _avatarUrlForProfile(data);

                summaries[key] = {
                  'name': existingName.isNotEmpty ? existingName : fallbackName,
                  'avatarUrl': existingAvatarUrl.isNotEmpty
                      ? existingAvatarUrl
                      : fallbackAvatarUrl,
                };
              }
            }
          }
        }

        await queryByField('usernameLowercase');
        await queryByField('username');
      }

      if (keysByUsername.isNotEmpty) {
        await enrichByUsername(_publicUsers);
        await enrichByUsername(_users);
      }

      // Add alias keys for username-like sender IDs so UI lookup can match
      // either `danafen` or `@danafen` forms used in legacy messages.
      final aliasAdds = <String, Map<String, String>>{};
      for (final entry in summaries.entries) {
        final key = entry.key.trim();
        if (key.isEmpty) {
          continue;
        }
        final normalizedUsername = _normalizeUsernameLookupKey(key);
        if (normalizedUsername.isEmpty) {
          continue;
        }
        aliasAdds.putIfAbsent(normalizedUsername, () => entry.value);
        aliasAdds.putIfAbsent('@$normalizedUsername', () => entry.value);
      }
      summaries.addAll(aliasAdds);
    } catch (_) {
      for (final uid in uniqueIds) {
        summaries.putIfAbsent(
            uid, () => <String, String>{'name': '', 'avatarUrl': ''});
      }
    }

    return summaries;
  }

  Future<Map<String, dynamic>> _loadCurrentUserProfile(String uid) async {
    final snapshot = await _users.doc(uid).get();
    return snapshot.data() ?? <String, dynamic>{};
  }

  Future<Map<String, dynamic>> _loadPublicUserProfile(String uid) async {
    final snapshot = await _publicUsers.doc(uid).get();
    return snapshot.data() ?? <String, dynamic>{};
  }

  Future<Map<String, dynamic>> _bestEffortSenderProfile(String uid) async {
    try {
      final publicProfile = await _loadPublicUserProfile(uid);
      if (publicProfile.isNotEmpty) {
        return publicProfile;
      }
    } catch (_) {
      // Ignore profile lookup failures so message writes remain functional.
    }

    try {
      final privateProfile = await _loadCurrentUserProfile(uid);
      if (privateProfile.isNotEmpty) {
        return privateProfile;
      }
    } catch (_) {
      // Ignore profile lookup failures so message writes remain functional.
    }

    return const <String, dynamic>{};
  }

  Future<Map<String, String>> _resolveSenderIdentity(
    String uid,
    User? currentUser,
  ) async {
    final senderProfile = await _bestEffortSenderProfile(uid);
    final senderNameFromDb = _displayNameForProfile(senderProfile, fallback: '');
    final senderNameFromAuth = (currentUser?.displayName ?? '').trim();
    final senderAvatarUrlFromDb = _avatarUrlForProfile(senderProfile);
    final senderAvatarUrlFromAuth = (currentUser?.photoURL ?? '').trim();
    final senderName = senderNameFromDb.isNotEmpty
        ? senderNameFromDb
        : (senderNameFromAuth.isNotEmpty ? senderNameFromAuth : 'משתמש');
    final senderAvatarUrl = senderAvatarUrlFromDb.isNotEmpty
        ? senderAvatarUrlFromDb
        : senderAvatarUrlFromAuth;

    return <String, String>{
      'name': senderName,
      'avatarUrl': senderAvatarUrl,
    };
  }

  Future<Map<String, dynamic>> _loadChatContext(
    DocumentReference<Map<String, dynamic>> chatRef,
  ) async {
    final chatSnap = await chatRef.get();
    final chatData = chatSnap.data() ?? <String, dynamic>{};
    final participants =
        (chatData['participants'] as List<dynamic>? ?? const <dynamic>[])
            .map((item) => item.toString().trim())
            .where((value) => value.isNotEmpty)
            .toList(growable: false);
    final chatName = (chatData['name'] as String? ?? '').trim();
    return <String, dynamic>{
      'participants': participants,
      'chatName': chatName,
    };
  }

  Future<String> _uploadChatAsset({
    required String chatId,
    required String senderUid,
    required Uint8List data,
    required String extension,
    required String folder,
  }) async {
    final safeExt = extension.trim().toLowerCase();
    final fileRef = _storage.ref().child(
      'chats/$senderUid/$chatId/$folder/${DateTime.now().millisecondsSinceEpoch}.$safeExt',
    );
    await fileRef.putData(data);
    return fileRef.getDownloadURL();
  }

  String _displayNameForProfile(Map<String, dynamic> profile,
      {required String fallback}) {
    String readString(List<String> keys) {
      for (final key in keys) {
        final raw = profile[key];
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

    final displayName = readString(const <String>[
      'displayName',
      'fullName',
      'name',
      'nickname',
    ]);
    if (displayName.isNotEmpty) {
      return displayName;
    }

    final firstName = readString(const <String>['firstName']);
    final lastName = readString(const <String>['lastName']);
    final combinedName =
        [firstName, lastName].where((part) => part.isNotEmpty).join(' ').trim();
    if (combinedName.isNotEmpty) {
      return combinedName;
    }

    final username = readString(const <String>[
      'username',
      'userName',
      'handle',
    ]);
    if (username.isNotEmpty) {
      return username;
    }

    final email = readString(const <String>['email']);
    if (email.contains('@')) {
      final localPart = email.split('@').first.trim();
      if (localPart.isNotEmpty) {
        return localPart;
      }
    }

    return fallback;
  }

  String _avatarUrlForProfile(Map<String, dynamic> profile) {
    String readString(List<String> keys) {
      for (final key in keys) {
        final raw = profile[key];
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

    final direct = readString(const <String>[
      'profilePictureUrl',
      'profileImageUrl',
      'profilePhotoUrl',
      'photoURL',
      'photoUrl',
      'avatarUrl',
    ]);
    if (direct.isNotEmpty) {
      return direct;
    }

    final profileImages =
        (profile['profileImageUrls'] as List<dynamic>? ?? const <dynamic>[])
            .map((item) => item.toString().trim())
            .where((item) => item.isNotEmpty)
            .toList(growable: false);
    if (profileImages.isNotEmpty) {
      return profileImages.first;
    }

    final legacyImages =
        (profile['images'] as List<dynamic>? ?? const <dynamic>[])
            .map((item) => item.toString().trim())
            .where((item) => item.isNotEmpty)
            .toList(growable: false);
    if (legacyImages.isNotEmpty) {
      return legacyImages.first;
    }

    return '';
  }

  String _normalizeUsernameLookupKey(String raw) {
    var value = raw.trim().toLowerCase();
    if (value.isEmpty) {
      return '';
    }
    if (value.startsWith('@')) {
      value = value.substring(1);
    }
    return value;
  }
}
