import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';

import '../models/post.dart';
import '../models/post_media_item.dart';
import '../models/public_user_profile.dart';
import '../app_categories.dart';
import '../category_points.dart';
import 'notification_service.dart';
import 'public_user_profile_service.dart';
import 'secure_action_queue_service.dart';
import 'spontaneous_challenge_service.dart';
import 'weekly_challenge_service.dart';

class PostService {
  static const int _hourlyPostActionLimit = 3;

  final FirebaseAuth _auth;
  final FirebaseFirestore _db;
  final FirebaseStorage _storage;
  late final PublicUserProfileService _publicUserProfileService;
  late final NotificationService _notificationService;
  late final SecureActionQueueService _secureQueue;

  PostService({
    FirebaseAuth? auth,
    FirebaseFirestore? db,
    FirebaseStorage? storage,
  })  : _auth = auth ?? FirebaseAuth.instance,
        _db = db ?? FirebaseFirestore.instance,
        _storage = storage ?? FirebaseStorage.instance {
    _publicUserProfileService = PublicUserProfileService(db: _db);
    _notificationService = NotificationService(db: _db, auth: _auth);
    _secureQueue = SecureActionQueueService(db: _db, auth: _auth);
  }

  bool _isPermissionDenied(Object error) {
    return error is FirebaseException && error.code == 'permission-denied';
  }

  String _requireUid() {
    final uid = _auth.currentUser?.uid;
    if (uid == null || uid.isEmpty) {
      throw FirebaseAuthException(
        code: 'not-authenticated',
        message: 'User must be logged in to create or fetch posts.',
      );
    }
    return uid;
  }

  void _logCommentFlow(
    String traceId,
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    if (!kDebugMode) return;
    final prefix = '[COMMENT_FLOW][$traceId]';
    debugPrint('$prefix $message');
    if (error != null) {
      debugPrint('$prefix error=$error');
    }
    if (stackTrace != null) {
      debugPrint('$prefix stack=$stackTrace');
    }
  }

  Future<void> _runNotificationBestEffort(Future<void> Function() action) async {
    try {
      await action();
    } on FirebaseException catch (error) {
      // Notifications are best-effort and must never fail the main post action.
      if (kDebugMode) {
        debugPrint('Notification side-effect failed: ${error.code} ${error.message ?? ''}');
      }
    } catch (error, stackTrace) {
      if (kDebugMode) {
        debugPrint('Notification side-effect failed: $error');
        debugPrint('$stackTrace');
      }
    }
  }

  String _authorIdFromPostData(Map<String, dynamic> data) {
    return (data['authorId'] as String? ?? '').trim();
  }

  DateTime _utcNow() => DateTime.now().toUtc();

  DateTime? _utcTimestampValue(dynamic value) {
    if (value is Timestamp) {
      return value.toDate().toUtc();
    }
    if (value is DateTime) {
      return value.toUtc();
    }
    if (value is String && value.trim().isNotEmpty) {
      return DateTime.tryParse(value.trim())?.toUtc();
    }
    return null;
  }

  int _intValue(dynamic value) {
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  _PostActionLimitDecision _evaluateHourlyPostActionLimit({
    required Map<String, dynamic> data,
    required String actionPrefix,
  }) {
    final now = _utcNow();
    final countKey = '${actionPrefix}Count';
    final windowStartKey = '${actionPrefix}WindowStart';

    final windowStart = _utcTimestampValue(data[windowStartKey]);
    final withinWindow = windowStart != null &&
        now.difference(windowStart) < const Duration(hours: 1);
    final currentCount = withinWindow ? _intValue(data[countKey]) : 0;

    if (withinWindow && currentCount >= _hourlyPostActionLimit) {
      return const _PostActionLimitDecision(
        allowed: false,
        nextPayload: null,
      );
    }

    return _PostActionLimitDecision(
      allowed: true,
      nextPayload: <String, dynamic>{
        windowStartKey: Timestamp.fromDate(withinWindow ? windowStart : now),
        countKey: withinWindow ? currentCount + 1 : 1,
      },
    );
  }

  Set<String> _taggedParticipantUidsFromPostData(Map<String, dynamic> data) {
    final authorId = _authorIdFromPostData(data);
    final rawParticipants = (data['members'] as List<dynamic>? ??
        data['participants'] as List<dynamic>? ??
        const <dynamic>[]);

    return rawParticipants
        .map((item) => item.toString().trim())
        .where((uid) => uid.isNotEmpty && uid != authorId)
        .toSet();
  }

  int _postScoreFromData(Map<String, dynamic> data) {
    final scoreAwarded = (data['scoreAwarded'] as num?)?.toInt() ??
        int.tryParse('${data['scoreAwarded'] ?? ''}') ??
        0;
    final likesCount = (data['likesCount'] as num?)?.toInt() ??
        int.tryParse('${data['likesCount'] ?? ''}') ??
        ((data['likes'] as List<dynamic>?) ?? const <dynamic>[]).length;
    final commentsCount = (data['commentsCount'] as num?)?.toInt() ??
        int.tryParse('${data['commentsCount'] ?? ''}') ??
        ((data['comments'] as List<dynamic>?) ?? const <dynamic>[]).length;
    final sharesCount = (data['sharesCount'] as num?)?.toInt() ??
        int.tryParse('${data['sharesCount'] ?? ''}') ??
        0;
    final savesCount = (data['savesCount'] as num?)?.toInt() ??
      int.tryParse('${data['savesCount'] ?? ''}') ??
      ((data['savedBy'] as List<dynamic>?) ?? const <dynamic>[]).length;

    return scoreAwarded + likesCount + (commentsCount * 2) + (sharesCount * 3) + savesCount;
  }

  int _taggedBonusForPostScore(int postScore) {
    if (postScore <= 0) {
      return 0;
    }
    return postScore ~/ 5;
  }

  Future<_PublishScoreAwardResult> _publishScoreAward({
    required String category,
    required String subCategory,
    required String authorId,
    required String eventGroupId,
  }) async {
    final normalizedCategory = category.trim();
    if (normalizedCategory == kGeneralCategory) {
      return const _PublishScoreAwardResult(score: 200);
    }

    final weeklyMultiplier = WeeklyChallengeService.publishMultiplier(
      category: category,
      subCategory: subCategory,
    );
    final spontaneousResolution =
        await SpontaneousChallengeService.resolveBoostForPost(
      uid: authorId,
      category: category,
      subCategory: subCategory,
    );
    final effectiveMultiplier = weeklyMultiplier >
            spontaneousResolution.spontaneousMultiplier
        ? weeklyMultiplier
        : spontaneousResolution.spontaneousMultiplier;

    final baseScore = pointsForCategory(
          category: category,
          subCategory: subCategory,
        ) *
        effectiveMultiplier;

    if (baseScore <= 0) {
      return const _PublishScoreAwardResult(score: 0);
    }

    final normalizedEventGroupId = eventGroupId.trim();
    if (normalizedEventGroupId.isEmpty) {
      return _PublishScoreAwardResult(
        score: baseScore,
        consumedSpontaneousTask: spontaneousResolution.matched &&
            spontaneousResolution.spontaneousMultiplier > 1,
      );
    }

    return _PublishScoreAwardResult(
      score: (baseScore * 0.25).round(),
      consumedSpontaneousTask: spontaneousResolution.matched &&
          spontaneousResolution.spontaneousMultiplier > 1,
    );
  }

  String? _postedSubCategoryKey({
    required String category,
    required String subCategory,
  }) {
    final normalizedCategory = category.trim();
    final normalizedSubCategory = subCategory.trim();
    if (normalizedCategory.isEmpty ||
        normalizedSubCategory.isEmpty ||
        normalizedSubCategory == 'אחר' ||
        isGeneralCategory(normalizedCategory)) {
      return null;
    }

    final availableSubCategories = appSubCategories(normalizedCategory);
    if (!availableSubCategories.contains(normalizedSubCategory)) {
      return null;
    }

    return '$normalizedCategory::$normalizedSubCategory';
  }

  Future<void> _trackPostedSubCategoryForExistingUserDocs({
    required String authorId,
    required String uid,
    required String category,
    required String subCategory,
  }) async {
    final normalizedUid = uid.trim();
    if (normalizedUid.isEmpty) {
      return;
    }

    final key = _postedSubCategoryKey(
      category: category,
      subCategory: subCategory,
    );
    if (key == null) {
      return;
    }

    final userRef = _db.collection('users').doc(normalizedUid);
    final publicRef = _db.collection('users_public').doc(normalizedUid);
    final snapshots = await Future.wait([userRef.get(), publicRef.get()]);

    final batch = _db.batch();
    var hasWrites = false;

    if (snapshots[0].exists) {
      batch.update(userRef, <String, dynamic>{
        'postedSubCategoryKeys': FieldValue.arrayUnion(<String>[key]),
      });
      hasWrites = true;
    }

    if (snapshots[1].exists) {
      batch.update(publicRef, <String, dynamic>{
        'postedSubCategoryKeys': FieldValue.arrayUnion(<String>[key]),
      });
      hasWrites = true;
    }

    if (hasWrites) {
      await batch.commit();
    }
  }

  Future<void> _safeTrackPostedSubCategoryForUser({
    required String uid,
    required String category,
    required String subCategory,
  }) async {
    try {
      await _trackPostedSubCategoryForExistingUserDocs(
        authorId: uid,
        uid: uid,
        category: category,
        subCategory: subCategory,
      );
    } catch (error) {
      if (kDebugMode) {
        debugPrint('Posted sub-category sync skipped: $error');
      }
    }
  }

  // ignore: unused_element
  void _addScoreIncrementForUsers({
    required WriteBatch batch,
    required Iterable<String> userIds,
    required int delta,
  }) {
    if (delta == 0) {
      return;
    }

    final uniqueIds =
        userIds.map((uid) => uid.trim()).where((uid) => uid.isNotEmpty).toSet();

    if (uniqueIds.isEmpty) {
      return;
    }

    final scoreUpdate = <String, dynamic>{
      'score': FieldValue.increment(delta),
    };

    for (final uid in uniqueIds) {
      batch.set(
        _db.collection('users').doc(uid),
        scoreUpdate,
        SetOptions(merge: true),
      );
      batch.set(
        _db.collection('users_public').doc(uid),
        scoreUpdate,
        SetOptions(merge: true),
      );
    }
  }

  Future<void> _incrementScoreForExistingUsers({
    required Iterable<String> userIds,
    required int delta,
  }) async {
    if (delta == 0) {
      return;
    }

    final uniqueIds = userIds
        .map((uid) => uid.trim())
        .where((uid) => uid.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (uniqueIds.isEmpty) {
      return;
    }

    final batch = _db.batch();
    var hasWrites = false;

    for (final uid in uniqueIds) {
      final userRef = _db.collection('users').doc(uid);
      final publicRef = _db.collection('users_public').doc(uid);
      final snapshots = await Future.wait([userRef.get(), publicRef.get()]);

      if (snapshots[0].exists) {
        batch.update(userRef, <String, dynamic>{
          'score': FieldValue.increment(delta),
        });
        hasWrites = true;
      }

      if (snapshots[1].exists) {
        batch.update(publicRef, <String, dynamic>{
          'score': FieldValue.increment(delta),
        });
        hasWrites = true;
      }
    }

    if (hasWrites) {
      await batch.commit();
    }
  }

  Future<void> _safeIncrementScoreForExistingUsers({
    required Iterable<String> userIds,
    required int delta,
  }) async {
    try {
      await _incrementScoreForExistingUsers(userIds: userIds, delta: delta);
    } catch (error) {
      if (kDebugMode) {
        debugPrint('Score sync skipped: $error');
      }
    }
  }

  void _addScoreIncrementForUsersInTransaction({
    required Transaction transaction,
    required Iterable<String> userIds,
    required int delta,
  }) {
    if (delta == 0) {
      return;
    }

    final uniqueIds =
        userIds.map((uid) => uid.trim()).where((uid) => uid.isNotEmpty).toSet();

    if (uniqueIds.isEmpty) {
      return;
    }

    final scoreUpdate = <String, dynamic>{
      'score': FieldValue.increment(delta),
    };

    for (final uid in uniqueIds) {
      transaction.set(
        _db.collection('users').doc(uid),
        scoreUpdate,
        SetOptions(merge: true),
      );
      transaction.set(
        _db.collection('users_public').doc(uid),
        scoreUpdate,
        SetOptions(merge: true),
      );
    }
  }

  Map<String, dynamic> _activityPayload({
    required String type,
    required String postId,
    required String uid,
    String title = '',
    String description = '',
    String imageUrl = '',
    String commentId = '',
    String commentText = '',
  }) {
    return <String, dynamic>{
      'type': type,
      'postId': postId,
      'uid': uid,
      'title': title,
      'description': description,
      'imageUrl': imageUrl,
      'commentId': commentId,
      'commentText': commentText,
      'createdAt': FieldValue.serverTimestamp(),
    };
  }

  Future<String> _resolvePublisherName(String authorId) async {
    final normalizedAuthorId = authorId.trim();
    if (normalizedAuthorId.isEmpty) {
      return 'משתמש';
    }

    try {
      final profile =
          await _publicUserProfileService.fetchProfile(normalizedAuthorId);
      if (profile != null) {
        final displayName = profile.displayName.trim();
        if (displayName.isNotEmpty) {
          return displayName;
        }
        final username = profile.username.trim();
        if (username.isNotEmpty) {
          return username;
        }
      }
    } catch (_) {
      // Best effort: keep falling back.
    }

    try {
      final snapshots = await Future.wait([
        _db.collection('users').doc(normalizedAuthorId).get(),
        _db.collection('users_public').doc(normalizedAuthorId).get(),
      ]);

      for (final snapshot in snapshots) {
        final data = snapshot.data() ?? <String, dynamic>{};
        final displayName =
            (data['displayName'] as String? ?? data['name'] as String? ?? '')
                .trim();
        if (displayName.isNotEmpty) {
          return displayName;
        }

        final username = (data['username'] as String? ?? '').trim();
        if (username.isNotEmpty) {
          return username;
        }
      }
    } catch (_) {
      // Ignore and fallback to auth display name.
    }

    final authName = (_auth.currentUser?.displayName ?? '').trim();
    if (authName.isNotEmpty) {
      return authName;
    }

    return 'משתמש';
  }

  Future<void> _announceGroupPostPublished({
    required String groupId,
    required String authorId,
    required String postId,
  }) async {
    final normalizedGroupId = groupId.trim();
    final normalizedAuthorId = authorId.trim();
    final normalizedPostId = postId.trim();
    if (normalizedGroupId.isEmpty ||
        normalizedAuthorId.isEmpty ||
        normalizedPostId.isEmpty) {
      return;
    }

    try {
      final publisherName = await _resolvePublisherName(normalizedAuthorId);
      final messageText = '$publisherName פרסם פוסט קבוצתי';
      final chatRef = _db.collection('chats').doc(normalizedGroupId);

      await chatRef.collection('messages').add({
        'senderId': '',
        'senderName': 'מערכת',
        'senderAvatarUrl': '',
        'text': messageText,
        'messageType': 'system',
        'relatedPostId': normalizedPostId,
        'timestamp': FieldValue.serverTimestamp(),
        'createdAt': FieldValue.serverTimestamp(),
      });

      await chatRef.set({
        'lastMessage': messageText,
        'lastMessageSenderName': 'מערכת',
        'lastMessageType': 'system',
        'lastMessageAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (error) {
      if (kDebugMode) {
        debugPrint('Group post announcement skipped: $error');
      }
    }
  }

  bool _isVideoPath(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.mp4') ||
        lower.endsWith('.mov') ||
        lower.endsWith('.m4v') ||
        lower.endsWith('.webm') ||
        lower.endsWith('.avi') ||
        lower.endsWith('.mkv');
  }

  String _fileExtension(String path) {
    final dotIndex = path.lastIndexOf('.');
    if (dotIndex == -1 || dotIndex >= path.length - 1) {
      return 'jpg';
    }
    return path.substring(dotIndex + 1).toLowerCase();
  }

  Future<List<PostMediaItem>> _uploadMediaItems({
    required String authorId,
    required String postId,
    required List<PostUploadMediaItem> selectedMediaItems,
  }) async {
    final uploaded = <PostMediaItem>[];

    for (var index = 0; index < selectedMediaItems.length; index++) {
      final media = selectedMediaItems[index];
      final mediaBytes = await media.file.readAsBytes();
      if (mediaBytes.isEmpty) {
        throw StateError('Selected media item is empty');
      }

      final extension = _fileExtension(
          media.file.name.isNotEmpty ? media.file.name : media.file.path);
        final storagePath =
          'posts/$authorId/$postId/${DateTime.now().millisecondsSinceEpoch}_$index.$extension';
      final mediaRef = _storage.ref().child(storagePath);
      await mediaRef.putData(mediaBytes);
      final mediaUrl = await mediaRef.getDownloadURL();
      uploaded.add(media.toUploaded(url: mediaUrl, storagePath: storagePath));
    }

    return uploaded;
  }

  List<PostMediaItem> mediaItemsFromData(Map<String, dynamic> data) {
    final rawMediaItems =
        (data['mediaItems'] as List<dynamic>? ?? const <dynamic>[]);
    final parsedMediaItems = rawMediaItems
        .whereType<Map>()
        .map(
          (item) {
            final normalized = item.map(
              (key, value) => MapEntry(key.toString(), value),
            );

            final normalizedUrl =
                (normalized['url'] as String? ?? '').trim();
            final normalizedStoragePath =
                (normalized['storagePath'] as String? ?? '').trim();

            if (normalizedUrl.isEmpty && normalizedStoragePath.isNotEmpty) {
              normalized['url'] = normalizedStoragePath;
            }

            return normalized;
          },
        )
        .map(PostMediaItem.fromMap)
        .where((item) => item.url.isNotEmpty)
        .toList(growable: false);
    if (parsedMediaItems.isNotEmpty) {
      return parsedMediaItems;
    }

    final rawMediaUrls =
        (data['mediaUrls'] as List<dynamic>? ?? const <dynamic>[])
            .map((item) => item.toString().trim())
            .where((item) => item.isNotEmpty)
            .toList(growable: false);
    if (rawMediaUrls.isNotEmpty) {
      return rawMediaUrls
          .map(
            (url) => PostMediaItem(
              url: url,
              storagePath: '',
              type: _isVideoPath(url) ? 'video' : 'image',
            ),
          )
          .toList(growable: false);
    }

    final singleUrl =
        ((data['mediaUrl'] as String?) ?? (data['imageUrl'] as String?) ?? '')
            .trim();
    if (singleUrl.isEmpty) {
      return const <PostMediaItem>[];
    }

    return <PostMediaItem>[
      PostMediaItem(
        url: singleUrl,
        storagePath: (data['storagePath'] as String? ?? '').trim(),
        type: _isVideoPath(singleUrl) ? 'video' : 'image',
      ),
    ];
  }

  Future<String> createPost({
    XFile? selectedMedia,
    List<XFile>? selectedMediaItems,
    List<PostUploadMediaItem>? uploadMediaItems,
    required String title,
    required String caption,
    required String category,
    required String subCategory,
    required String audience,
    required String authorId,
    required List<String> members,
    String status = 'published',
    String? eventGroupId,
    String? linkedGroupId,
  }) async {
    try {
      final normalizedAuthorId =
          authorId.trim().isNotEmpty ? authorId.trim() : _requireUid();
      final normalizedSelectedMedia = <PostUploadMediaItem>[
        ...?uploadMediaItems,
        if (selectedMedia != null)
          PostUploadMediaItem(
            file: selectedMedia,
            type: _isVideoPath(
              selectedMedia.name.isNotEmpty
                  ? selectedMedia.name
                  : selectedMedia.path,
            )
                ? 'video'
                : 'image',
          ),
        ...?(selectedMediaItems?.map(
          (media) => PostUploadMediaItem(
            file: media,
            type: _isVideoPath(media.name.isNotEmpty ? media.name : media.path)
                ? 'video'
                : 'image',
          ),
        )),
      ];

      final normalizedStatus = status.trim().toLowerCase();
      if (normalizedStatus != 'published' && normalizedStatus != 'draft') {
        throw ArgumentError('status must be either published or draft');
      }
      final isPublishingFlow = normalizedStatus == 'published';

      if (isPublishingFlow && title.trim().isEmpty) {
        throw ArgumentError('title is required');
      }
      if (isPublishingFlow && category.trim().isEmpty) {
        throw ArgumentError('category is required');
      }
      if (normalizedAuthorId.isEmpty) {
        throw ArgumentError('authorId is required');
      }

      if (normalizedSelectedMedia.isEmpty) {
        throw ArgumentError('At least one media item is required');
      }
      if (normalizedSelectedMedia.length > 10) {
        throw ArgumentError('A post can contain up to 10 media items');
      }
      if (normalizedSelectedMedia.any(
        (media) =>
            media.file.path.trim().isEmpty && media.file.name.trim().isEmpty,
      )) {
        throw ArgumentError('Every selected media item must be valid');
      }

      final postRef = _db.collection('posts').doc();
      if (postRef.id.isEmpty) {
        throw StateError('Could not allocate post document id');
      }

      final uploadedMediaItems = await _uploadMediaItems(
        authorId: normalizedAuthorId,
        postId: postRef.id,
        selectedMediaItems: normalizedSelectedMedia,
      );
      if (uploadedMediaItems.isEmpty) {
        throw StateError('No media items were uploaded');
      }
      final mediaUrls = uploadedMediaItems
          .map((item) => item.url)
          .where((url) => url.trim().isNotEmpty)
          .toList(growable: false);
      final mediaUrl = mediaUrls.first;

      final memberSet = <String>{
        normalizedAuthorId,
        ...members
            .where((uid) => uid.trim().isNotEmpty)
            .map((uid) => uid.trim()),
      };

      final post = Post(
        postId: postRef.id,
        authorId: normalizedAuthorId,
        mediaUrl: mediaUrl,
        mediaUrls: mediaUrls,
        mediaItems: uploadedMediaItems,
        title: title.trim(),
        caption: caption.trim(),
        createdAt: null,
        likesCount: 0,
        likes: const <String>[],
        members: memberSet.toList(),
        category: category.trim(),
        subCategory: subCategory.trim(),
        audience: audience.trim().isNotEmpty ? audience.trim() : 'public',
        status: normalizedStatus,
        eventGroupId: (eventGroupId ?? '').trim(),
        linkedGroupId: (linkedGroupId ?? '').trim(),
      );

      final publishResult = normalizedStatus == 'published'
          ? await _publishScoreAward(
              category: post.category,
              subCategory: post.subCategory,
              authorId: normalizedAuthorId,
              eventGroupId: post.eventGroupId,
            )
          : const _PublishScoreAwardResult(score: 0);
      final scoreToAdd = publishResult.score;
      final postData = post.toMap();
      postData['scoreAwarded'] = scoreToAdd;

      // ignore: avoid_print
      print('Step 3: Saving to Firestore...');
      final batch = _db.batch();
      batch.set(postRef, postData);
      if (normalizedStatus == 'published') {
        batch.set(
          _db
              .collection('users')
              .doc(normalizedAuthorId)
              .collection('activity')
              .doc(),
          _activityPayload(
            type: 'pop',
            postId: postRef.id,
            uid: normalizedAuthorId,
            title: post.title,
            description: post.caption,
            imageUrl: post.mediaUrl,
          ),
        );
      }

      await batch.commit();

      if (normalizedStatus == 'published' && post.linkedGroupId.isNotEmpty) {
        await _announceGroupPostPublished(
          groupId: post.linkedGroupId,
          authorId: normalizedAuthorId,
          postId: postRef.id,
        );
      }

      if (scoreToAdd != 0) {
        await _safeIncrementScoreForExistingUsers(
          userIds: <String>[normalizedAuthorId],
          delta: scoreToAdd,
        );

        final taggedUids = memberSet.where((uid) => uid != normalizedAuthorId);
        final taggedBonus = _taggedBonusForPostScore(scoreToAdd);
        if (taggedBonus != 0) {
          await _safeIncrementScoreForExistingUsers(
            userIds: taggedUids,
            delta: taggedBonus,
          );
        }
      }

      if (normalizedStatus == 'published') {
        await _safeTrackPostedSubCategoryForUser(
          uid: normalizedAuthorId,
          category: post.category,
          subCategory: post.subCategory,
        );
        if (publishResult.consumedSpontaneousTask) {
          await SpontaneousChallengeService.clearTaskForUser(normalizedAuthorId);
        }
      }

      return postRef.id;
    } catch (e, stackTrace) {
      // ignore: avoid_print
      print('CRITICAL ERROR: $e');
      // ignore: avoid_print
      print(stackTrace);
      rethrow;
    }
  }

  Future<void> updatePostDetails({
    required String postId,
    required String title,
    required String caption,
    required String category,
    required String subCategory,
    required String audience,
    required String location,
    required String status,
    List<String>? participantUids,
    String? linkedGroupId,
  }) async {
    final uid = _requireUid();
    final normalizedPostId = postId.trim();
    if (normalizedPostId.isEmpty) {
      throw ArgumentError('postId is required');
    }

    final normalizedTitle = title.trim();
    final normalizedCaption = caption.trim();
    final normalizedCategory = category.trim();
    final normalizedSubCategory = subCategory.trim();
    final normalizedLocation = location.trim();
    final normalizedStatus = status.trim().toLowerCase();
    final isPublishingFlow = normalizedStatus == 'published';

    if (isPublishingFlow && normalizedTitle.isEmpty) {
      throw ArgumentError('title is required');
    }
    if (isPublishingFlow && normalizedCategory.isEmpty) {
      throw ArgumentError('category is required');
    }
    if (normalizedStatus != 'published' && normalizedStatus != 'draft') {
      throw ArgumentError('status must be either published or draft');
    }

    final postRef = _db.collection('posts').doc(normalizedPostId);
    final snapshot = await postRef.get();
    if (!snapshot.exists) {
      throw StateError('post does not exist');
    }

    final data = snapshot.data() ?? <String, dynamic>{};
    final authorId = (data['authorId'] as String? ?? '').trim();
    final previousStatus =
        (data['status'] as String? ?? 'published').trim().toLowerCase();
    if (authorId.isNotEmpty && authorId != uid) {
      throw FirebaseAuthException(
        code: 'permission-denied',
        message: 'You can only edit your own posts.',
      );
    }

    final updatePayload = <String, dynamic>{
      'title': normalizedTitle,
      'caption': normalizedCaption,
      'description': normalizedCaption,
      'content': normalizedCaption,
      'category': normalizedCategory,
      'subCategory': normalizedSubCategory,
      'audience': audience.trim().isNotEmpty ? audience.trim() : 'public',
      'location': normalizedLocation,
      'status': normalizedStatus,
      'linkedGroupId': (linkedGroupId ?? '').trim(),
      'updatedAt': FieldValue.serverTimestamp(),
    };

    if (participantUids != null) {
      final members = <String>{
        if (authorId.isNotEmpty) authorId,
        ...participantUids
            .map((uid) => uid.trim())
            .where((uid) => uid.isNotEmpty && uid != authorId),
      };
      updatePayload['members'] = members.toList(growable: false);
    }

    final isDraftToPublished =
        previousStatus == 'draft' && normalizedStatus == 'published';
    final eventGroupId = (updatePayload['eventGroupId'] as String? ??
            data['eventGroupId'] as String? ??
            '')
        .trim();
    final publishResult = isDraftToPublished
        ? await _publishScoreAward(
            category: normalizedCategory,
            subCategory: normalizedSubCategory,
            authorId: uid,
            eventGroupId: eventGroupId,
          )
        : const _PublishScoreAwardResult(score: 0);
    final scoreToAdd = publishResult.score;
    if (scoreToAdd != 0) {
      updatePayload['scoreAwarded'] = scoreToAdd;
    }

    final oldPostScore = _postScoreFromData(data);
    final newScoreAwarded = scoreToAdd != 0
        ? scoreToAdd
        : ((data['scoreAwarded'] as num?)?.toInt() ??
            int.tryParse('${data['scoreAwarded'] ?? ''}') ??
            0);
    final nextComments = (data['commentsCount'] as num?)?.toInt() ??
        int.tryParse('${data['commentsCount'] ?? ''}') ??
        ((data['comments'] as List<dynamic>?) ?? const <dynamic>[]).length;
    final nextLikes = (data['likesCount'] as num?)?.toInt() ??
        int.tryParse('${data['likesCount'] ?? ''}') ??
        ((data['likes'] as List<dynamic>?) ?? const <dynamic>[]).length;
    final nextShares = (data['sharesCount'] as num?)?.toInt() ??
        int.tryParse('${data['sharesCount'] ?? ''}') ??
        0;
    final newPostScore =
        newScoreAwarded + nextLikes + (nextComments * 2) + (nextShares * 3);

    final oldTaggedUids = _taggedParticipantUidsFromPostData(data);
    final newTaggedUids = participantUids != null
        ? <String>{
            ...participantUids
                .map((value) => value.trim())
                .where((value) => value.isNotEmpty && value != authorId),
          }
        : oldTaggedUids;

    final oldTaggedBonus = _taggedBonusForPostScore(oldPostScore);
    final newTaggedBonus = _taggedBonusForPostScore(newPostScore);

    final batch = _db.batch();
    batch.update(postRef, updatePayload);

    await batch.commit();

    final effectiveLinkedGroupId =
        (linkedGroupId ?? data['linkedGroupId'] as String? ?? '').trim();
    if (isDraftToPublished && effectiveLinkedGroupId.isNotEmpty) {
      await _announceGroupPostPublished(
        groupId: effectiveLinkedGroupId,
        authorId: authorId.isNotEmpty ? authorId : uid,
        postId: normalizedPostId,
      );
    }

    if (scoreToAdd != 0) {
      final scoreOwnerId = authorId.isNotEmpty ? authorId : uid;
      await _safeIncrementScoreForExistingUsers(
        userIds: <String>[scoreOwnerId],
        delta: scoreToAdd,
      );
    }

    final effectiveAuthorId = authorId.isNotEmpty ? authorId : uid;
    if (normalizedStatus == 'published') {
      await _safeTrackPostedSubCategoryForUser(
        uid: effectiveAuthorId,
        category: normalizedCategory,
        subCategory: normalizedSubCategory,
      );
      if (publishResult.consumedSpontaneousTask) {
        await SpontaneousChallengeService.clearTaskForUser(effectiveAuthorId);
      }
    }

    final commonTagged = oldTaggedUids.intersection(newTaggedUids);
    final removedTagged = oldTaggedUids.difference(newTaggedUids);
    final addedTagged = newTaggedUids.difference(oldTaggedUids);

    await _safeIncrementScoreForExistingUsers(
      userIds: commonTagged,
      delta: newTaggedBonus - oldTaggedBonus,
    );
    await _safeIncrementScoreForExistingUsers(
      userIds: removedTagged,
      delta: -oldTaggedBonus,
    );
    await _safeIncrementScoreForExistingUsers(
      userIds: addedTagged,
      delta: newTaggedBonus,
    );
  }

  Future<void> deletePost({
    required String postId,
  }) async {
    final uid = _requireUid();
    final normalizedPostId = postId.trim();
    if (normalizedPostId.isEmpty) {
      throw ArgumentError('postId is required');
    }

    final postRef = _db.collection('posts').doc(normalizedPostId);
    final postSnap = await postRef.get();
    if (!postSnap.exists) {
      return;
    }

    final postData = postSnap.data() ?? <String, dynamic>{};
    final authorId = (postData['authorId'] as String? ?? '').trim();
    if (authorId.isNotEmpty && authorId != uid) {
      throw FirebaseAuthException(
        code: 'permission-denied',
        message: 'You can only delete your own posts.',
      );
    }

    final savedBy = ((postData['savedBy'] as List<dynamic>?) ?? const <dynamic>[])
        .map((item) => item.toString().trim())
        .where((item) => item.isNotEmpty)
        .toSet()
        .toList(growable: false);

    final saverUids = <String>{
      ...savedBy,
      uid,
    }.where((value) => value.trim().isNotEmpty).toList(growable: false);

    final postScoreToRemove = _postScoreFromData(postData);
    final taggedBonusToRemove = _taggedBonusForPostScore(postScoreToRemove);
    final taggedParticipantUids =
        _taggedParticipantUidsFromPostData(postData).toList(growable: false);

    const int batchChunk = 350;
    for (var index = 0; index < saverUids.length; index += batchChunk) {
      final end = (index + batchChunk < saverUids.length)
          ? index + batchChunk
          : saverUids.length;
      final chunk = saverUids.sublist(index, end);
      final batch = _db.batch();
      for (final saverUid in chunk) {
        batch.delete(
          _db
              .collection('users')
              .doc(saverUid)
              .collection('saved_posts')
              .doc(normalizedPostId),
        );
      }
      await batch.commit();
    }

    while (true) {
      final commentsSnapshot =
          await postRef.collection('comments').limit(batchChunk).get();
      if (commentsSnapshot.docs.isEmpty) {
        break;
      }
      final batch = _db.batch();
      for (final commentDoc in commentsSnapshot.docs) {
        batch.delete(commentDoc.reference);
      }
      await batch.commit();
    }

    await postRef.delete();

    final scoreOwnerId = authorId.isNotEmpty ? authorId : uid;
    if (postScoreToRemove > 0) {
      await _safeIncrementScoreForExistingUsers(
        userIds: <String>[scoreOwnerId],
        delta: -postScoreToRemove,
      );
    }

    if (taggedBonusToRemove > 0 && taggedParticipantUids.isNotEmpty) {
      await _safeIncrementScoreForExistingUsers(
        userIds: taggedParticipantUids,
        delta: -taggedBonusToRemove,
      );
    }

    final mediaItems = mediaItemsFromData(postData);
    final storageTargets = <String>{
      (postData['storagePath'] as String? ?? '').trim(),
      ...mediaItems.map((item) => item.storagePath.trim()),
      ...mediaItems.map((item) => item.url.trim()),
    }.where((value) => value.isNotEmpty).toList(growable: false);

    for (final target in storageTargets) {
      final lower = target.toLowerCase();
      if (lower.startsWith('http://') || lower.startsWith('https://')) {
        continue;
      }

      try {
        if (target.startsWith('gs://')) {
          await _storage.refFromURL(target).delete();
        } else {
          await _storage.ref(target).delete();
        }
      } catch (_) {
        // Best effort: Firestore state is the source of truth.
      }
    }
  }

  Stream<List<Post>> getPostsForUser() {
    final uid = _requireUid();

    return _db
        .collection('posts')
        .where('members', arrayContains: uid)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) => snapshot.docs.map(Post.fromDoc).toList());
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> watchPublishedPosts({
    String? category,
    String? subCategory,
  }) {
    Query<Map<String, dynamic>> query =
        _db.collection('posts').where('status', isEqualTo: 'published');

    final normalizedCategory = category?.trim() ?? '';
    if (normalizedCategory.isNotEmpty) {
      query = query.where('category', isEqualTo: normalizedCategory);
    }

    final normalizedSubCategory = subCategory?.trim() ?? '';
    if (normalizedSubCategory.isNotEmpty) {
      query = query.where('subCategory', isEqualTo: normalizedSubCategory);
    }

    return query.orderBy('createdAt', descending: true).snapshots();
  }

  Stream<List<Map<String, dynamic>>> watchPublishedPostsWithAuthors({
    String? category,
    String? subCategory,
  }) {
    late final StreamController<List<Map<String, dynamic>>> controller;
    StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? postsSubscription;
    final Map<String, StreamSubscription<PublicUserProfile?>>
        profileSubscriptions =
        <String, StreamSubscription<PublicUserProfile?>>{};
    final Map<String, PublicUserProfile?> profilesByUid =
        <String, PublicUserProfile?>{};
    List<QueryDocumentSnapshot<Map<String, dynamic>>> currentPosts =
        const <QueryDocumentSnapshot<Map<String, dynamic>>>[];

    void emitCurrentFeed() {
      if (controller.isClosed) {
        return;
      }

      final enrichedPosts = currentPosts.map((doc) {
        final rawPost = Map<String, dynamic>.from(doc.data());
        rawPost['id'] = doc.id;
        rawPost['postId'] = (rawPost['postId'] as String? ?? doc.id).trim();

        final authorId =
            (rawPost['authorId'] as String? ?? rawPost['uid'] as String? ?? '')
                .trim();
        final profile = profilesByUid[authorId] ??
            _publicUserProfileService.fallbackProfileForPost(rawPost);

        return _publicUserProfileService.injectProfileIntoPost(
            rawPost, profile);
      }).toList(growable: false);

      controller.add(enrichedPosts);
    }

    Future<void> syncProfileSubscriptions() async {
      final desiredUids = currentPosts
          .map((doc) {
            final data = doc.data();
            return (data['authorId'] as String? ?? data['uid'] as String? ?? '')
                .trim();
          })
          .where((uid) => uid.isNotEmpty)
          .toSet();

      final staleUids = profileSubscriptions.keys
          .where((uid) => !desiredUids.contains(uid))
          .toList(growable: false);
      for (final uid in staleUids) {
        await profileSubscriptions.remove(uid)?.cancel();
        profilesByUid.remove(uid);
      }

      for (final uid in desiredUids) {
        profileSubscriptions.putIfAbsent(
          uid,
          () => _publicUserProfileService.streamProfile(uid).listen(
            (profile) {
              profilesByUid[uid] = profile;
              emitCurrentFeed();
            },
            onError: (Object error, StackTrace stackTrace) {
              if (!controller.isClosed) {
                controller.addError(error, stackTrace);
              }
            },
          ),
        );
      }
    }

    controller = StreamController<List<Map<String, dynamic>>>.broadcast(
      onListen: () {
        postsSubscription ??= watchPublishedPosts(
          category: category,
          subCategory: subCategory,
        ).listen(
          (snapshot) {
            currentPosts = snapshot.docs.toList(growable: false);
            syncProfileSubscriptions();
            emitCurrentFeed();
          },
          onError: (Object error, StackTrace stackTrace) {
            if (!controller.isClosed) {
              controller.addError(error, stackTrace);
            }
          },
        );
      },
      onCancel: () async {
        if (controller.hasListener) {
          return;
        }

        await postsSubscription?.cancel();
        postsSubscription = null;
        for (final subscription in profileSubscriptions.values) {
          await subscription.cancel();
        }
        profileSubscriptions.clear();
        profilesByUid.clear();
      },
    );

    return controller.stream;
  }

  Stream<List<Post>> getDraftsForCurrentUser() {
    final uid = _requireUid();

    return _db
        .collection('posts')
        .where('authorId', isEqualTo: uid)
        .where('status', isEqualTo: 'draft')
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) => snapshot.docs.map(Post.fromDoc).toList());
  }

  Future<void> togglePostLike({
    required String postId,
    required String postAuthorId,
    bool? currentlyLikedByMe,
  }) async {
    final uid = _requireUid();
    final normalizedPostId = postId.trim();
    var normalizedAuthorId = postAuthorId.trim();
    if (normalizedPostId.isEmpty) {
      throw ArgumentError('postId is required');
    }

    final postRef = _db.collection('posts').doc(normalizedPostId);
    bool didAddLike = false;
    int likesCountAfterToggle = 0;
    String postImageUrl = '';
    try {
      await _db.runTransaction((transaction) async {
        final postSnap = await transaction.get(postRef);
        if (!postSnap.exists) {
          throw StateError('post does not exist');
        }

        final postData = postSnap.data() ?? <String, dynamic>{};
        if (normalizedAuthorId.isEmpty) {
          normalizedAuthorId = ((postData['authorId'] as String?) ??
                  (postData['userId'] as String?) ??
                  (postData['uid'] as String?) ??
                  '')
              .trim();
        }
        final likesRaw = (postData['likes'] as List<dynamic>? ?? const []);
        final likes = likesRaw
            .map((item) => item.toString().trim())
            .where((item) => item.isNotEmpty)
            .toSet();

        final hasLiked = likes.contains(uid);
        didAddLike = !hasLiked;
        final oldPostScore = _postScoreFromData(postData);
        if (hasLiked) {
          likes.remove(uid);
        } else {
          likes.add(uid);
        }
        postImageUrl = (postData['imageUrl'] as String? ??
                postData['mediaUrl'] as String? ??
                '')
            .trim();

        transaction.update(postRef, <String, dynamic>{
          'likes': likes.toList(growable: false),
          'likesCount': likes.length,
          'updatedAt': FieldValue.serverTimestamp(),
        });
        likesCountAfterToggle = likes.length;

        if (!hasLiked) {
          transaction.set(
            _db.collection('users').doc(uid).collection('activity').doc(),
            _activityPayload(
              type: 'like',
              postId: normalizedPostId,
              uid: uid,
              title: (postData['title'] as String? ?? '').trim(),
              description: (postData['caption'] as String? ??
                      postData['description'] as String? ??
                      '')
                  .trim(),
              imageUrl: (postData['imageUrl'] as String? ??
                      postData['mediaUrl'] as String? ??
                      '')
                  .trim(),
            ),
          );
        }

        final nextPostData = Map<String, dynamic>.from(postData)
          ..['likesCount'] = likes.length
          ..['likes'] = likes.toList(growable: false);
        final newPostScore = _postScoreFromData(nextPostData);
        final taggedScoreDelta = _taggedBonusForPostScore(newPostScore) -
            _taggedBonusForPostScore(oldPostScore);
        _addScoreIncrementForUsersInTransaction(
          transaction: transaction,
          userIds: _taggedParticipantUidsFromPostData(postData),
          delta: taggedScoreDelta,
        );

        if (normalizedAuthorId.isNotEmpty) {
          final scoreDelta = hasLiked ? -1 : 1;
          final scoreUpdate = <String, dynamic>{
            'score': FieldValue.increment(scoreDelta),
          };
          transaction.set(
            _db.collection('users').doc(normalizedAuthorId),
            scoreUpdate,
            SetOptions(merge: true),
          );
          transaction.set(
            _db.collection('users_public').doc(normalizedAuthorId),
            scoreUpdate,
            SetOptions(merge: true),
          );
        }
      });
    } catch (error) {
      if (_isPermissionDenied(error)) {
        if (normalizedAuthorId.isEmpty) {
          final postSnap = await postRef.get();
          final postData = postSnap.data() ?? <String, dynamic>{};
          normalizedAuthorId = ((postData['authorId'] as String?) ??
                  (postData['userId'] as String?) ??
                  (postData['uid'] as String?) ??
                  '')
              .trim();
        }
        await _secureQueue.enqueue(
          type: SecureActionTypes.togglePostLike,
          payload: <String, dynamic>{
            'postId': normalizedPostId,
            'postAuthorId': normalizedAuthorId,
          },
          dedupeKey: 'like:$uid:$normalizedPostId',
        );
        if (normalizedAuthorId.isNotEmpty && normalizedAuthorId != uid) {
          final intendedAddLike =
              currentlyLikedByMe == null ? didAddLike : !currentlyLikedByMe;
          final scoreDelta = intendedAddLike ? 1 : -1;
          PublicUserProfileService.addOptimisticScoreDelta(
            uid: normalizedAuthorId,
            delta: scoreDelta,
          );
        }
        return;
      }
      rethrow;
    }

    if (didAddLike &&
        normalizedAuthorId.isNotEmpty &&
        normalizedAuthorId != uid) {
      unawaited(
        _runNotificationBestEffort(() {
          return _notificationService.sendPostLikeNotification(
            recipientUid: normalizedAuthorId,
            postId: normalizedPostId,
            likeCount: likesCountAfterToggle,
            postImageUrl: postImageUrl,
            senderUid: uid,
          );
        }),
      );
    }
  }

  Future<void> registerPostShare({
    required String postId,
    required String postAuthorId,
  }) async {
    final uid = _requireUid();
    final normalizedPostId = postId.trim();
    var normalizedAuthorId = postAuthorId.trim();
    if (normalizedPostId.isEmpty) {
      throw ArgumentError('postId is required');
    }

    final postRef = _db.collection('posts').doc(normalizedPostId);
    final userRateLimitRef = _db
        .collection('users')
        .doc(uid)
        .collection('activity_limits')
        .doc(normalizedPostId);
    var allowed = false;
    try {
      await _db.runTransaction((transaction) async {
        final rateLimitSnap = await transaction.get(userRateLimitRef);
        final rateLimitDecision = _evaluateHourlyPostActionLimit(
          data: rateLimitSnap.data() ?? <String, dynamic>{},
          actionPrefix: 'share',
        );
        allowed = rateLimitDecision.allowed;
        if (!allowed) {
          return;
        }

        final postSnap = await transaction.get(postRef);
        if (!postSnap.exists) {
          throw StateError('post does not exist');
        }

        final postData = postSnap.data() ?? <String, dynamic>{};
        if (normalizedAuthorId.isEmpty) {
          normalizedAuthorId =
              (postData['authorId'] as String? ??
                      postData['uid'] as String? ??
                      postData['userId'] as String? ??
                      '')
                  .trim();
        }
        final currentShares = (postData['sharesCount'] as num?)?.toInt() ?? 0;
        final oldPostScore = _postScoreFromData(postData);
        transaction.update(postRef, <String, dynamic>{
          'sharesCount': currentShares + 1,
          'updatedAt': FieldValue.serverTimestamp(),
        });

        final nextPostData = Map<String, dynamic>.from(postData)
          ..['sharesCount'] = currentShares + 1;
        final newPostScore = _postScoreFromData(nextPostData);
        final taggedScoreDelta = _taggedBonusForPostScore(newPostScore) -
            _taggedBonusForPostScore(oldPostScore);
        _addScoreIncrementForUsersInTransaction(
          transaction: transaction,
          userIds: _taggedParticipantUidsFromPostData(postData),
          delta: taggedScoreDelta,
        );

        if (rateLimitDecision.nextPayload != null) {
          transaction.set(
            userRateLimitRef,
            rateLimitDecision.nextPayload!,
            SetOptions(merge: true),
          );
        }

        if (normalizedAuthorId.isNotEmpty && normalizedAuthorId != uid) {
          final scoreUpdate = <String, dynamic>{
            'score': FieldValue.increment(3),
          };
          transaction.set(
            _db.collection('users').doc(normalizedAuthorId),
            scoreUpdate,
            SetOptions(merge: true),
          );
          transaction.set(
            _db.collection('users_public').doc(normalizedAuthorId),
            scoreUpdate,
            SetOptions(merge: true),
          );
        }
      });
    } catch (error) {
      if (_isPermissionDenied(error)) {
        if (normalizedAuthorId.isEmpty) {
          final postSnap = await postRef.get();
          final postData = postSnap.data() ?? <String, dynamic>{};
          normalizedAuthorId =
              (postData['authorId'] as String? ??
                      postData['uid'] as String? ??
                      postData['userId'] as String? ??
                      '')
                  .trim();
        }
        await _secureQueue.enqueue(
          type: SecureActionTypes.registerPostShare,
          payload: <String, dynamic>{
            'postId': normalizedPostId,
            'postAuthorId': normalizedAuthorId,
          },
          dedupeKey: 'share:$uid:$normalizedPostId',
        );
        if (normalizedAuthorId.isNotEmpty && normalizedAuthorId != uid) {
          PublicUserProfileService.addOptimisticScoreDelta(
            uid: normalizedAuthorId,
            delta: 3,
          );
        }
        return;
      }
      rethrow;
    }

    if (!allowed) {
      throw const PostActionLimitException(
        'הגעת למכסת השיתופים שלך לפוסט זה, נסה שוב מאוחר יותר',
      );
    }
  }

  Future<void> togglePostSave({
    required String postId,
    bool? currentlySavedByMe,
  }) async {
    final uid = _requireUid();
    final normalizedPostId = postId.trim();
    if (normalizedPostId.isEmpty) {
      throw ArgumentError('postId is required');
    }

    final postRef = _db.collection('posts').doc(normalizedPostId);
    final savedPostRef =
        _db.collection('users').doc(uid).collection('saved_posts').doc(normalizedPostId);
    var didAddSave = false;
    var normalizedAuthorId = '';
    var postImageUrl = '';

    try {
      await _db.runTransaction((transaction) async {
        final postSnap = await transaction.get(postRef);
        if (!postSnap.exists) {
          throw StateError('post does not exist');
        }

        final postData = postSnap.data() ?? <String, dynamic>{};
        normalizedAuthorId =
          (postData['authorId'] as String? ?? '').trim();
        postImageUrl =
          (postData['mediaUrl'] as String? ?? postData['imageUrl'] as String? ?? '')
            .trim();
        final savedByRaw = (postData['savedBy'] as List<dynamic>? ?? const []);
        final savedBy = savedByRaw
          .map((item) => item.toString().trim())
          .where((item) => item.isNotEmpty)
          .toSet();

        final oldPostScore = _postScoreFromData(postData);
        final alreadySaved = savedBy.contains(uid);
        if (alreadySaved) {
          savedBy.remove(uid);
        } else {
          savedBy.add(uid);
          didAddSave = true;
        }

        transaction.update(postRef, <String, dynamic>{
          'savedBy': savedBy.toList(growable: false),
          'savesCount': savedBy.length,
          'updatedAt': FieldValue.serverTimestamp(),
        });

        final nextPostData = Map<String, dynamic>.from(postData)
          ..['savedBy'] = savedBy.toList(growable: false)
          ..['savesCount'] = savedBy.length;
        final newPostScore = _postScoreFromData(nextPostData);
        final taggedScoreDelta = _taggedBonusForPostScore(newPostScore) -
            _taggedBonusForPostScore(oldPostScore);
        _addScoreIncrementForUsersInTransaction(
          transaction: transaction,
          userIds: _taggedParticipantUidsFromPostData(postData),
          delta: taggedScoreDelta,
        );

        if (normalizedAuthorId.isNotEmpty) {
          final scoreDelta = alreadySaved ? -1 : 1;
          final scoreUpdate = <String, dynamic>{
            'score': FieldValue.increment(scoreDelta),
          };
          transaction.set(
            _db.collection('users').doc(normalizedAuthorId),
            scoreUpdate,
            SetOptions(merge: true),
          );
          transaction.set(
            _db.collection('users_public').doc(normalizedAuthorId),
            scoreUpdate,
            SetOptions(merge: true),
          );
        }

        if (alreadySaved) {
          transaction.delete(savedPostRef);
        } else {
          final title = (postData['title'] as String? ?? '').trim();
          final description =
              (postData['caption'] as String? ?? postData['description'] as String? ?? '')
                  .trim();
          final mediaUrl =
              (postData['mediaUrl'] as String? ?? postData['imageUrl'] as String? ?? '').trim();

          transaction.set(savedPostRef, <String, dynamic>{
            'postId': normalizedPostId,
            'authorId': (postData['authorId'] as String? ?? '').trim(),
            'title': title,
            'description': description,
            'imageUrl': mediaUrl,
            'mediaUrl': mediaUrl,
            'category': (postData['category'] as String? ?? '').trim(),
            'subCategory': (postData['subCategory'] as String? ?? '').trim(),
            'createdAt': postData['createdAt'],
            'savedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
        }
      });
    } catch (error) {
      if (_isPermissionDenied(error)) {
        if (normalizedAuthorId.isEmpty) {
          final postSnap = await postRef.get();
          final postData = postSnap.data() ?? <String, dynamic>{};
          normalizedAuthorId =
              (postData['authorId'] as String? ?? '').trim();
        }
        await _secureQueue.enqueue(
          type: SecureActionTypes.togglePostSave,
          payload: <String, dynamic>{
            'postId': normalizedPostId,
          },
          dedupeKey: 'save:$uid:$normalizedPostId',
        );
        if (normalizedAuthorId.isNotEmpty && normalizedAuthorId != uid) {
          final intendedAddSave =
              currentlySavedByMe == null ? didAddSave : !currentlySavedByMe;
          final scoreDelta = intendedAddSave ? 1 : -1;
          PublicUserProfileService.addOptimisticScoreDelta(
            uid: normalizedAuthorId,
            delta: scoreDelta,
          );
        }
        return;
      }
      rethrow;
    }

    if (didAddSave && normalizedAuthorId.isNotEmpty && normalizedAuthorId != uid) {
      unawaited(
        _runNotificationBestEffort(() {
          return _notificationService.sendPostSaveNotification(
            recipientUid: normalizedAuthorId,
            postId: normalizedPostId,
            postImageUrl: postImageUrl,
            senderUid: uid,
          );
        }),
      );
    }
  }

  Stream<List<Map<String, dynamic>>> watchPostComments(String postId) {
    final normalizedPostId = postId.trim();
    if (normalizedPostId.isEmpty) {
      return const Stream<List<Map<String, dynamic>>>.empty();
    }

    return _db
        .collection('posts')
        .doc(normalizedPostId)
        .collection('comments')
        .orderBy('createdAt', descending: false)
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => <String, dynamic>{'id': doc.id, ...doc.data()})
            .toList(growable: false));
  }

  Future<void> addPostComment({
    required String postId,
    required String postAuthorId,
    required String text,
    String? parentCommentId,
  }) async {
    final uid = _requireUid();
    final normalizedPostId = postId.trim();
    var normalizedAuthorId = postAuthorId.trim();
    final normalizedText = text.trim();
    final normalizedParentId = (parentCommentId ?? '').trim();
    final uidShort = uid.length > 6 ? uid.substring(0, 6) : uid;
    final traceId = 'comment_${DateTime.now().millisecondsSinceEpoch}_$uidShort';

    _logCommentFlow(
      traceId,
      'start postId=$normalizedPostId authorId=$normalizedAuthorId parentId=$normalizedParentId textLength=${normalizedText.length}',
    );

    if (normalizedPostId.isEmpty) {
      _logCommentFlow(traceId, 'validation failed: postId is empty');
      throw ArgumentError('postId is required');
    }
    if (normalizedText.isEmpty) {
      _logCommentFlow(traceId, 'validation failed: text is empty');
      throw ArgumentError('text is required');
    }

    try {
      final postRef = _db.collection('posts').doc(normalizedPostId);
      final commentsRef = postRef.collection('comments');
      final newCommentRef = commentsRef.doc();
      final userRateLimitRef = _db
          .collection('users')
          .doc(uid)
          .collection('activity_limits')
          .doc(normalizedPostId);
      String parentCommentAuthorId = '';
      String postImageUrl = '';
      var taggedScoreDelta = 0;
      var allowed = false;

      _logCommentFlow(traceId, 'running transaction');
      await _db.runTransaction((transaction) async {
        final rateLimitSnap = await transaction.get(userRateLimitRef);
        final rateLimitDecision = _evaluateHourlyPostActionLimit(
          data: rateLimitSnap.data() ?? <String, dynamic>{},
          actionPrefix: 'comment',
        );
        allowed = rateLimitDecision.allowed;
        _logCommentFlow(traceId, 'rate limit allowed=$allowed');
        if (!allowed) {
          return;
        }

        final postSnap = await transaction.get(postRef);
        if (!postSnap.exists) {
          _logCommentFlow(traceId, 'post does not exist inside transaction');
          throw StateError('post does not exist');
        }
        if (normalizedAuthorId.isEmpty) {
          normalizedAuthorId = (postSnap.data()?['authorId'] as String? ??
                  postSnap.data()?['uid'] as String? ??
                  postSnap.data()?['userId'] as String? ??
                  '')
              .trim();
        }
        postImageUrl = (postSnap.data()?['imageUrl'] as String? ??
                postSnap.data()?['mediaUrl'] as String? ??
                '')
            .trim();

        if (normalizedParentId.isNotEmpty) {
          final parentRef = commentsRef.doc(normalizedParentId);
          final parentSnap = await transaction.get(parentRef);
          if (parentSnap.exists) {
            final parentData = parentSnap.data() ?? <String, dynamic>{};
            parentCommentAuthorId =
                (parentData['authorId'] as String? ?? '').trim();
            final currentReplies =
                (parentData['replyCount'] as num?)?.toInt() ?? 0;
            transaction.update(parentRef, <String, dynamic>{
              'replyCount': currentReplies + 1,
              'updatedAt': FieldValue.serverTimestamp(),
            });
          }
        }

        if (rateLimitDecision.nextPayload != null) {
          transaction.set(
            userRateLimitRef,
            rateLimitDecision.nextPayload!,
            SetOptions(merge: true),
          );
        }

        transaction.set(newCommentRef, <String, dynamic>{
          'id': newCommentRef.id,
          'postId': normalizedPostId,
          'postAuthorId': normalizedAuthorId,
          'authorId': uid,
          'text': normalizedText,
          'parentId': normalizedParentId,
          'likes': <String>[],
          'likesCount': 0,
          'replyCount': 0,
          'createdAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        });

        transaction.set(
          _db.collection('users').doc(uid).collection('activity').doc(),
          _activityPayload(
            type: 'comment',
            postId: normalizedPostId,
            uid: uid,
            title: (postSnap.data()?['title'] as String? ?? '').trim(),
            description: normalizedText,
            commentId: newCommentRef.id,
            commentText: normalizedText,
            imageUrl: (postSnap.data()?['imageUrl'] as String? ??
                    postSnap.data()?['mediaUrl'] as String? ??
                    '')
                .trim(),
          ),
        );

        final postData = postSnap.data() ?? <String, dynamic>{};
        final currentComments =
            (postData['commentsCount'] as num?)?.toInt() ?? 0;
        final oldPostScore = _postScoreFromData(postData);
        transaction.update(postRef, <String, dynamic>{
          'commentsCount': currentComments + 1,
          'updatedAt': FieldValue.serverTimestamp(),
        });

        final nextPostData = Map<String, dynamic>.from(postData)
          ..['commentsCount'] = currentComments + 1;
        final newPostScore = _postScoreFromData(nextPostData);
        taggedScoreDelta = _taggedBonusForPostScore(newPostScore) -
            _taggedBonusForPostScore(oldPostScore);
      });

      if (!allowed) {
        _logCommentFlow(traceId, 'blocked by hourly comment limit');
        throw const PostActionLimitException(
          'הגעת למכסת התגובות שלך לפוסט זה, נסה שוב מאוחר יותר',
        );
      }

      _logCommentFlow(traceId, 'transaction committed, syncing score');

      // Score sync is best-effort and should never block comment publishing.
      if (taggedScoreDelta != 0) {
        final postSnap = await postRef.get();
        final postData = postSnap.data() ?? <String, dynamic>{};
        await _safeIncrementScoreForExistingUsers(
          userIds: _taggedParticipantUidsFromPostData(postData),
          delta: taggedScoreDelta,
        );
      }

      if (normalizedAuthorId.isNotEmpty) {
        await _safeIncrementScoreForExistingUsers(
          userIds: <String>[normalizedAuthorId],
          delta: 2,
        );
      }

      _logCommentFlow(traceId, 'score sync done, sending notifications');
      if (normalizedAuthorId.isNotEmpty && normalizedAuthorId != uid) {
        await _runNotificationBestEffort(() {
          return _notificationService.sendPostCommentNotification(
            recipientUid: normalizedAuthorId,
            postId: normalizedPostId,
            commentText: normalizedText,
            commentId: newCommentRef.id,
            postImageUrl: postImageUrl,
            senderUid: uid,
          );
        });
      }

      if (normalizedParentId.isNotEmpty &&
          parentCommentAuthorId.isNotEmpty &&
          parentCommentAuthorId != uid &&
          parentCommentAuthorId != normalizedAuthorId) {
        await _runNotificationBestEffort(() {
          return _notificationService.sendCommentReplyNotification(
            recipientUid: parentCommentAuthorId,
            postId: normalizedPostId,
            commentId: normalizedParentId,
            replyText: normalizedText,
            postImageUrl: postImageUrl,
            senderUid: uid,
          );
        });
      }

      _logCommentFlow(traceId, 'completed successfully');
    } catch (error, stackTrace) {
      if (_isPermissionDenied(error)) {
        _logCommentFlow(traceId, 'permission-denied, creating comment self-only and queueing side-effects');

        final userRateLimitRef = _db
            .collection('users')
            .doc(uid)
            .collection('activity_limits')
            .doc(normalizedPostId);
        final rateLimitSnap = await userRateLimitRef.get();
        final rateLimitDecision = _evaluateHourlyPostActionLimit(
          data: rateLimitSnap.data() ?? <String, dynamic>{},
          actionPrefix: 'comment',
        );
        if (!rateLimitDecision.allowed) {
          throw const PostActionLimitException(
            'הגעת למכסת התגובות שלך לפוסט זה, נסה שוב מאוחר יותר',
          );
        }

        final postRef = _db.collection('posts').doc(normalizedPostId);
        final postSnap = await postRef.get();
        if (!postSnap.exists) {
          throw StateError('post does not exist');
        }
        if (normalizedAuthorId.isEmpty) {
          normalizedAuthorId = (postSnap.data()?['authorId'] as String? ??
                  postSnap.data()?['uid'] as String? ??
                  postSnap.data()?['userId'] as String? ??
                  '')
              .trim();
        }

        if (rateLimitDecision.nextPayload != null) {
          await userRateLimitRef.set(
            rateLimitDecision.nextPayload!,
            SetOptions(merge: true),
          );
        }

        final commentRef = postRef.collection('comments').doc();
        await commentRef.set(<String, dynamic>{
          'id': commentRef.id,
          'postId': normalizedPostId,
          'postAuthorId': normalizedAuthorId,
          'authorId': uid,
          'text': normalizedText,
          'parentId': normalizedParentId,
          'likes': <String>[],
          'likesCount': 0,
          'replyCount': 0,
          'sideEffectsApplied': false,
          'createdAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        });

        await _db.collection('users').doc(uid).collection('activity').doc().set(
              _activityPayload(
                type: 'comment',
                postId: normalizedPostId,
                uid: uid,
                title: (postSnap.data()?['title'] as String? ?? '').trim(),
                description: normalizedText,
                commentId: commentRef.id,
                commentText: normalizedText,
                imageUrl: (postSnap.data()?['imageUrl'] as String? ??
                        postSnap.data()?['mediaUrl'] as String? ??
                        '')
                    .trim(),
              ),
            );

        await _secureQueue.enqueue(
          type: SecureActionTypes.syncPostCommentSideEffects,
          payload: <String, dynamic>{
            'postId': normalizedPostId,
            'postAuthorId': normalizedAuthorId,
            'commentId': commentRef.id,
            'parentCommentId': normalizedParentId,
            'commentText': normalizedText,
          },
          dedupeKey: 'comment_sync:$uid:$normalizedPostId:${commentRef.id}',
        );

        if (normalizedAuthorId.isNotEmpty) {
          PublicUserProfileService.addOptimisticScoreDelta(
            uid: normalizedAuthorId,
            delta: 2,
          );
        }

        return;
      }
      _logCommentFlow(
        traceId,
        'failed',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<void> toggleCommentLike({
    required String postId,
    required String commentId,
  }) async {
    final uid = _requireUid();
    final normalizedPostId = postId.trim();
    final normalizedCommentId = commentId.trim();
    if (normalizedPostId.isEmpty || normalizedCommentId.isEmpty) {
      throw ArgumentError('postId and commentId are required');
    }

    final commentRef = _db
        .collection('posts')
        .doc(normalizedPostId)
        .collection('comments')
        .doc(normalizedCommentId);

    await _db.runTransaction((transaction) async {
      final commentSnap = await transaction.get(commentRef);
      if (!commentSnap.exists) {
        throw StateError('comment does not exist');
      }

      final data = commentSnap.data() ?? <String, dynamic>{};
      final likesRaw = (data['likes'] as List<dynamic>? ?? const []);
      final likes = likesRaw
          .map((item) => item.toString().trim())
          .where((item) => item.isNotEmpty)
          .toSet();

      if (likes.contains(uid)) {
        likes.remove(uid);
      } else {
        likes.add(uid);
      }

      transaction.update(commentRef, <String, dynamic>{
        'likes': likes.toList(growable: false),
        'likesCount': likes.length,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    });
  }

  Future<void> deletePostComment({
    required String postId,
    required String postAuthorId,
    required String commentId,
  }) async {
    final uid = _requireUid();
    final normalizedPostId = postId.trim();
    final normalizedPostAuthorId = postAuthorId.trim();
    final normalizedCommentId = commentId.trim();

    if (normalizedPostId.isEmpty || normalizedCommentId.isEmpty) {
      throw ArgumentError('postId and commentId are required');
    }

    final postRef = _db.collection('posts').doc(normalizedPostId);
    final commentsRef = postRef.collection('comments');
    final targetCommentRef = commentsRef.doc(normalizedCommentId);
    final allCommentsSnap = await commentsRef.get();
    final allDocs = allCommentsSnap.docs;

    await _db.runTransaction((transaction) async {
      final postSnap = await transaction.get(postRef);
      if (!postSnap.exists) {
        throw StateError('post does not exist');
      }

      final postData = postSnap.data() ?? <String, dynamic>{};
      final resolvedPostAuthorId =
          (postData['authorId'] as String? ?? normalizedPostAuthorId).trim();

      final targetCommentSnap = await transaction.get(targetCommentRef);
      if (!targetCommentSnap.exists) {
        throw StateError('comment does not exist');
      }

      final targetCommentData = targetCommentSnap.data() ?? <String, dynamic>{};
      final targetCommentAuthorId =
          (targetCommentData['authorId'] as String? ?? '').trim();
      final canDelete =
          targetCommentAuthorId == uid || resolvedPostAuthorId == uid;
      if (!canDelete) {
        throw FirebaseAuthException(
          code: 'permission-denied',
          message:
              'You can only delete your own comments or comments on your post.',
        );
      }

      final byId = <String, QueryDocumentSnapshot<Map<String, dynamic>>>{
        for (final doc in allDocs) doc.id: doc,
      };

      final childrenByParent = <String, List<String>>{};
      for (final doc in allDocs) {
        final data = doc.data();
        final parentId = (data['parentId'] as String? ?? '').trim();
        if (parentId.isEmpty) continue;
        childrenByParent.putIfAbsent(parentId, () => <String>[]).add(doc.id);
      }

      final toDelete = <String>{};
      final stack = <String>[normalizedCommentId];
      while (stack.isNotEmpty) {
        final currentId = stack.removeLast();
        if (!toDelete.add(currentId)) continue;
        final children = childrenByParent[currentId] ?? const <String>[];
        stack.addAll(children);
      }

      for (final id in toDelete) {
        final doc = byId[id];
        if (doc != null) {
          transaction.delete(doc.reference);
        }
      }

      final removedCount = toDelete.length;
      final currentComments = (postData['commentsCount'] as num?)?.toInt() ?? 0;
      final nextComments = (currentComments - removedCount).clamp(0, 1 << 30);
      final oldPostScore = _postScoreFromData(postData);
      transaction.update(postRef, <String, dynamic>{
        'commentsCount': nextComments,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      final nextPostData = Map<String, dynamic>.from(postData)
        ..['commentsCount'] = nextComments;
      final newPostScore = _postScoreFromData(nextPostData);
      final taggedScoreDelta = _taggedBonusForPostScore(newPostScore) -
          _taggedBonusForPostScore(oldPostScore);
      _addScoreIncrementForUsersInTransaction(
        transaction: transaction,
        userIds: _taggedParticipantUidsFromPostData(postData),
        delta: taggedScoreDelta,
      );

      final parentId = (targetCommentData['parentId'] as String? ?? '').trim();
      if (parentId.isNotEmpty && !toDelete.contains(parentId)) {
        final parentRef = commentsRef.doc(parentId);
        final parentSnap = await transaction.get(parentRef);
        if (parentSnap.exists) {
          final parentData = parentSnap.data() ?? <String, dynamic>{};
          final currentReplies =
              (parentData['replyCount'] as num?)?.toInt() ?? 0;
          final directRepliesRemoved = toDelete
              .map((id) => byId[id])
              .whereType<QueryDocumentSnapshot<Map<String, dynamic>>>()
              .map((doc) => (doc.data()['parentId'] as String? ?? '').trim())
              .where((p) => p == parentId)
              .length;
          final nextReplies =
              (currentReplies - directRepliesRemoved).clamp(0, 1 << 30);
          transaction.update(parentRef, <String, dynamic>{
            'replyCount': nextReplies,
            'updatedAt': FieldValue.serverTimestamp(),
          });
        }
      }

      if (resolvedPostAuthorId.isNotEmpty) {
        final commentsByOthersRemoved = toDelete
            .map((id) => byId[id])
            .whereType<QueryDocumentSnapshot<Map<String, dynamic>>>()
            .map((doc) => (doc.data()['authorId'] as String? ?? '').trim())
            .where((authorId) =>
                authorId.isNotEmpty && authorId != resolvedPostAuthorId)
            .length;

        if (commentsByOthersRemoved > 0) {
          final scoreDelta = -2 * commentsByOthersRemoved;
          final scoreUpdate = <String, dynamic>{
            'score': FieldValue.increment(scoreDelta),
          };
          transaction.set(
            _db.collection('users').doc(resolvedPostAuthorId),
            scoreUpdate,
            SetOptions(merge: true),
          );
          transaction.set(
            _db.collection('users_public').doc(resolvedPostAuthorId),
            scoreUpdate,
            SetOptions(merge: true),
          );
        }
      }
    });
  }
}

class _PublishScoreAwardResult {
  final int score;
  final bool consumedSpontaneousTask;

  const _PublishScoreAwardResult({
    required this.score,
    this.consumedSpontaneousTask = false,
  });
}

class PostActionLimitException implements Exception {
  final String message;

  const PostActionLimitException(this.message);

  @override
  String toString() => message;
}

class _PostActionLimitDecision {
  final bool allowed;
  final Map<String, dynamic>? nextPayload;

  const _PostActionLimitDecision({
    required this.allowed,
    required this.nextPayload,
  });
}

