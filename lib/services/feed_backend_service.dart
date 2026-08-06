import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../app_categories.dart';
import '../models/public_user_profile.dart';
import 'public_user_profile_service.dart';

class FeedBackendService {
  static const String _baseUrl =
      String.fromEnvironment('FEED_API_BASE_URL', defaultValue: '');
  static const String _stableExperimentId =
      String.fromEnvironment('FEED_STABLE_EXPERIMENT_ID', defaultValue: 'feed-stable-v1');
  static const String _canaryExperimentId =
      String.fromEnvironment('FEED_CANARY_EXPERIMENT_ID', defaultValue: 'feed-canary-v1');
    static const String _canaryRatioRaw =
      String.fromEnvironment('FEED_CANARY_RATIO', defaultValue: '0.10');
    static final double _canaryRatio = double.tryParse(_canaryRatioRaw) ?? 0.10;

  final FirebaseAuth _auth;
  final FirebaseFirestore _db;
  final PublicUserProfileService _publicUserProfileService;
  final http.Client _client;

  FeedBackendService({
    FirebaseAuth? auth,
    FirebaseFirestore? db,
    http.Client? client,
  })  : _auth = auth ?? FirebaseAuth.instance,
        _db = db ?? FirebaseFirestore.instance,
        _client = client ?? http.Client(),
        _publicUserProfileService =
            PublicUserProfileService(db: db ?? FirebaseFirestore.instance);

  bool get isConfigured => _baseUrl.trim().isNotEmpty;

  Future<({Set<String> followingIds, Set<String> followerIds})>
      _viewerRelations(String viewerUid) async {
    final normalizedViewerUid = viewerUid.trim();
    if (normalizedViewerUid.isEmpty) {
      return (followingIds: <String>{}, followerIds: <String>{});
    }

    final viewerDoc =
        await _db.collection('users').doc(normalizedViewerUid).get();
    final viewerData = viewerDoc.data() ?? <String, dynamic>{};

    Set<String> readSet(String key) {
      final raw = viewerData[key];
      if (raw is! List) {
        return <String>{};
      }
      return raw
          .map((item) => item.toString().trim())
          .where((item) => item.isNotEmpty)
          .toSet();
    }

    return (
      followingIds: readSet('following'),
      followerIds: readSet('followers'),
    );
  }

  String _postAudience(Map<String, dynamic> post) {
    return (post['audience'] as String? ?? 'public').trim().toLowerCase();
  }

  bool _canViewerSeePost({
    required String viewerUid,
    required Map<String, dynamic> post,
    required PublicUserProfile? authorProfile,
    required Set<String> viewerFollowingIds,
    required Set<String> viewerFollowerIds,
  }) {
    final authorId =
        (post['authorId'] as String? ?? post['uid'] as String? ?? '').trim();
    if (authorId.isEmpty) {
      return false;
    }
    if (authorId == viewerUid) {
      return true;
    }

    final audience = _postAudience(post);
    if (audience == 'friends') {
      return viewerFollowingIds.contains(authorId) &&
          viewerFollowerIds.contains(authorId);
    }

    final isPrivateAuthor = authorProfile?.exists == true
        ? authorProfile!.isPrivate
      : false;
    if (isPrivateAuthor) {
      return viewerFollowingIds.contains(authorId);
    }

    return true;
  }

  Stream<List<Map<String, dynamic>>> watchRecommendedFeedWithAuthors({
    required bool isForYouFeed,
    String? category,
    String? subCategory,
    int pageSize = 40,
  }) {
    return Stream.fromFuture(
      fetchRecommendedFeedWithAuthors(
        isForYouFeed: isForYouFeed,
        category: category,
        subCategory: subCategory,
        pageSize: pageSize,
      ),
    );
  }

  Future<List<Map<String, dynamic>>> fetchRecommendedFeedWithAuthors({
    required bool isForYouFeed,
    String? category,
    String? subCategory,
    int pageSize = 40,
  }) async {
    if (!isConfigured) {
      return const <Map<String, dynamic>>[];
    }

    final uid = _auth.currentUser?.uid.trim() ?? '';
    if (uid.isEmpty) {
      return const <Map<String, dynamic>>[];
    }

    final topicAllowlist = _buildTopicAllowlist(
      category: category,
      subCategory: subCategory,
    );

    final requestBody = <String, dynamic>{
      'user_id': uid,
      'mode': isForYouFeed ? 'discovery' : 'following',
      'page_size': pageSize.clamp(1, 100),
      'topic_allowlist': topicAllowlist.isEmpty ? null : topicAllowlist,
      'experiment_id': _experimentIdForUser(uid),
    };

    final headers = <String, String>{'Content-Type': 'application/json'};
    final token = await _auth.currentUser?.getIdToken();
    if (token != null && token.trim().isNotEmpty) {
      headers['Authorization'] = 'Bearer ${token.trim()}';
    }

    final endpoint = Uri.parse('${_baseUrl.replaceAll(RegExp(r'/$'), '')}/v1/feed/query');
    final response = await _client.post(
      endpoint,
      headers: headers,
      body: jsonEncode(requestBody),
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(
        'feed-api error status=${response.statusCode} body=${response.body}',
      );
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('feed-api response is not an object');
    }

    final items = (decoded['items'] as List<dynamic>? ?? const <dynamic>[])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList(growable: false);

    final orderedPostIds = items
        .map((item) => (item['post_id'] as String? ?? '').trim())
        .where((id) => id.isNotEmpty)
        .toList(growable: false);

    if (orderedPostIds.isEmpty) {
      return const <Map<String, dynamic>>[];
    }

    final postsById = await _fetchPostsByIds(orderedPostIds);

    final orderedPosts = <Map<String, dynamic>>[];
    for (final postId in orderedPostIds) {
      final post = postsById[postId];
      if (post != null) {
        orderedPosts.add(post);
      }
    }

    if (orderedPosts.isEmpty) {
      return const <Map<String, dynamic>>[];
    }

    final authorIds = orderedPosts
        .map((post) =>
            (post['authorId'] as String? ?? post['uid'] as String? ?? '').trim())
        .where((uid) => uid.isNotEmpty)
        .toSet();

    final profilesByUid = <String, PublicUserProfile?>{
      for (final entry in await Future.wait(
        authorIds.map(
          (authorId) async => MapEntry(
            authorId,
            await _publicUserProfileService.fetchProfile(authorId),
          ),
        ),
      ))
        entry.key: entry.value,
    };

    final relations = await _viewerRelations(uid);
    final viewerFollowingIds = relations.followingIds;
    final viewerFollowerIds = relations.followerIds;

    final visiblePosts = <Map<String, dynamic>>[];
    for (final rawPost in orderedPosts) {
      final authorId =
          (rawPost['authorId'] as String? ?? rawPost['uid'] as String? ?? '')
              .trim();
      final profile = profilesByUid[authorId] ??
          _publicUserProfileService.fallbackProfileForPost(rawPost);

      if (profile.isDeleted) {
        continue;
      }

      if (!_canViewerSeePost(
        viewerUid: uid,
        post: rawPost,
        authorProfile: profile,
        viewerFollowingIds: viewerFollowingIds,
        viewerFollowerIds: viewerFollowerIds,
      )) {
        continue;
      }

      visiblePosts
          .add(_publicUserProfileService.injectProfileIntoPost(rawPost, profile));
    }

    return visiblePosts;
  }

  Future<Map<String, Map<String, dynamic>>> _fetchPostsByIds(
    List<String> postIds,
  ) async {
    final result = <String, Map<String, dynamic>>{};
    if (postIds.isEmpty) {
      return result;
    }

    for (final postId in postIds) {
      final normalizedPostId = postId.trim();
      if (normalizedPostId.isEmpty) {
        continue;
      }

      try {
        final doc =
            await _db.collection('posts').doc(normalizedPostId).get();
        if (!doc.exists) {
          continue;
        }

        final map = Map<String, dynamic>.from(doc.data() ?? <String, dynamic>{});
        final status = (map['status'] as String? ?? 'published')
            .trim()
            .toLowerCase();
        if (status != 'published') {
          continue;
        }

        map['id'] = doc.id;
        map['postId'] = (map['postId'] as String? ?? doc.id).trim();
        result[doc.id] = map;
      } on FirebaseException catch (error) {
        if (error.code == 'permission-denied') {
          continue;
        }
        rethrow;
      }
    }

    return result;
  }

  List<String> _buildTopicAllowlist({
    String? category,
    String? subCategory,
  }) {
    final normalizedCategory = (category ?? '').trim();
    final normalizedSubCategory = (subCategory ?? '').trim();

    if (normalizedSubCategory.isNotEmpty) {
      return <String>[normalizedSubCategory];
    }

    if (normalizedCategory.isNotEmpty && !isGeneralCategory(normalizedCategory)) {
      return <String>[normalizedCategory];
    }

    return const <String>[];
  }

  String _experimentIdForUser(String userId) {
    final canaryRatio = _canaryRatio.clamp(0.0, 1.0);
    if (canaryRatio <= 0.0) {
      return _stableExperimentId;
    }
    if (canaryRatio >= 1.0) {
      return _canaryExperimentId;
    }

    final bucket = _stableUserBucket(userId);
    final threshold = (canaryRatio * 1000).round();
    return bucket < threshold ? _canaryExperimentId : _stableExperimentId;
  }

  int _stableUserBucket(String input) {
    int hash = 2166136261;
    for (final unit in input.codeUnits) {
      hash ^= unit;
      hash = (hash * 16777619) & 0x7fffffff;
    }
    return hash % 1000;
  }

  @visibleForTesting
  String debugExperimentForUser(String userId) => _experimentIdForUser(userId);
}
