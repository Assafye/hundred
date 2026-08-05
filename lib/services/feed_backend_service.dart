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

    const int chunkSize = 10;
    for (int i = 0; i < postIds.length; i += chunkSize) {
      final end = (i + chunkSize < postIds.length)
          ? i + chunkSize
          : postIds.length;
      final chunk = postIds.sublist(i, end);
      final snapshot = await _db
          .collection('posts')
          .where(FieldPath.documentId, whereIn: chunk)
          .where('status', isEqualTo: 'published')
          .get();

      for (final doc in snapshot.docs) {
        final map = Map<String, dynamic>.from(doc.data());
        map['id'] = doc.id;
        map['postId'] = (map['postId'] as String? ?? doc.id).trim();
        result[doc.id] = map;
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
