import 'package:cloud_firestore/cloud_firestore.dart';

import 'post_media_item.dart';

class Post {
  final String postId;
  final String authorId;
  final String mediaUrl;
  final List<String> mediaUrls;
  final List<PostMediaItem> mediaItems;
  final String title;
  final String caption;
  final DateTime? createdAt;
  final int likesCount;
  final List<String> likes;
  final List<String> members;
  final String category;
  final String subCategory;
  final String status;
  final String audience;
  final String eventGroupId;
  final String linkedGroupId;

  const Post({
    required this.postId,
    required this.authorId,
    required this.mediaUrl,
    this.mediaUrls = const <String>[],
    this.mediaItems = const <PostMediaItem>[],
    required this.title,
    required this.caption,
    required this.createdAt,
    required this.likesCount,
    required this.likes,
    required this.members,
    required this.category,
    required this.subCategory,
    required this.status,
    this.audience = 'public',
    this.eventGroupId = '',
    this.linkedGroupId = '',
  });

  Map<String, dynamic> toMap() {
    final normalizedMediaUrls = mediaUrls
        .map((url) => url.trim())
        .where((url) => url.isNotEmpty)
        .toList(growable: false);
    final normalizedMediaItems = mediaItems
        .where((item) => item.url.trim().isNotEmpty)
        .map((item) => item.toMap())
        .toList(growable: false);
    final primaryMediaUrl = mediaUrl.trim().isNotEmpty
        ? mediaUrl.trim()
        : (normalizedMediaUrls.isNotEmpty ? normalizedMediaUrls.first : '');

    return {
      'postId': postId,
      'authorId': authorId,
      'mediaUrl': primaryMediaUrl,
      'mediaUrls': normalizedMediaUrls,
      'mediaItems': normalizedMediaItems,
      'primaryMediaUrl': primaryMediaUrl,
      'primaryMediaType': normalizedMediaItems.isNotEmpty
          ? (normalizedMediaItems.first['type'] ?? 'image')
          : 'image',
      'imageUrl': primaryMediaUrl,
      'title': title,
      'caption': caption,
      'createdAt': createdAt != null
          ? Timestamp.fromDate(createdAt!)
          : FieldValue.serverTimestamp(),
      'likesCount': likesCount,
      'likes': likes,
      'savesCount': 0,
      'savedBy': const <String>[],
      'members': members,
      'category': category,
      'subCategory': subCategory,
      'status': status,
      'audience': audience.trim().isNotEmpty ? audience.trim() : 'public',
      'eventGroupId': eventGroupId,
      'linkedGroupId': linkedGroupId,
    };
  }

  factory Post.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? <String, dynamic>{};
    final createdAtRaw = data['createdAt'];
    final createdAt = createdAtRaw is Timestamp ? createdAtRaw.toDate() : null;
    final mediaItemsRaw =
        (data['mediaItems'] as List<dynamic>? ?? const <dynamic>[]);
    final parsedMediaItems = mediaItemsRaw
        .whereType<Map<String, dynamic>>()
        .map(PostMediaItem.fromMap)
        .where((item) => item.url.isNotEmpty)
        .toList(growable: false);
    final mediaUrls = (data['mediaUrls'] as List<dynamic>? ?? const <dynamic>[])
        .map((item) => item.toString().trim())
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
    final primaryMediaUrl =
        (data['mediaUrl'] as String? ?? data['imageUrl'] as String? ?? '')
            .trim();

    return Post(
      postId: (data['postId'] as String?) ?? doc.id,
      authorId: (data['authorId'] as String?) ?? '',
      mediaUrl: primaryMediaUrl,
      mediaUrls: mediaUrls,
      mediaItems: parsedMediaItems,
      title: (data['title'] as String? ?? '').trim(),
      caption: (data['caption'] as String?) ?? '',
      createdAt: createdAt,
      likesCount: (data['likesCount'] as num?)?.toInt() ?? 0,
      likes: List<String>.from(
          (data['likes'] as List<dynamic>?) ?? const <String>[]),
      members: List<String>.from(
          (data['members'] as List<dynamic>?) ?? const <String>[]),
      category: (data['category'] as String?) ?? '',
      subCategory: (data['subCategory'] as String?) ?? '',
      status: (data['status'] as String?) ?? 'published',
      audience: (data['audience'] as String?) ?? 'public',
      eventGroupId: (data['eventGroupId'] as String? ?? '').trim(),
      linkedGroupId: (data['linkedGroupId'] as String? ?? '').trim(),
    );
  }
}
