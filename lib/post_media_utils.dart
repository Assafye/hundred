import 'models/post_media_item.dart';

bool isVideoMediaUrl(String url) {
  final normalized = url.trim().toLowerCase();
  if (normalized.isEmpty) {
    return false;
  }

  final withoutQuery = normalized.split('?').first.split('#').first;
  return withoutQuery.endsWith('.mp4') ||
      withoutQuery.endsWith('.mov') ||
      withoutQuery.endsWith('.m4v') ||
      withoutQuery.endsWith('.webm') ||
      withoutQuery.endsWith('.avi') ||
      withoutQuery.endsWith('.mkv');
}

List<PostMediaItem> postMediaItemsFromData(Map<String, dynamic> data) {
  List<PostMediaItem> withRootThumbnail(List<PostMediaItem> items) {
    final thumbnailUrl = (data['thumbnailUrl'] as String? ??
            data['videoThumbnailUrl'] as String? ??
            '')
        .trim();
    if (thumbnailUrl.isEmpty || items.isEmpty) return items;
    final first = items.first;
    if (!first.isVideo || first.thumbnailUrl.trim().isNotEmpty) return items;
    return <PostMediaItem>[
      first.copyWith(thumbnailUrl: thumbnailUrl),
      ...items.skip(1),
    ];
  }

  final rawMediaItems =
      (data['mediaItems'] as List<dynamic>? ?? const <dynamic>[]);
  final parsedMediaItems = rawMediaItems
      .whereType<Map>()
      .map(
        (item) {
          final normalized = item.map(
            (key, value) => MapEntry(key.toString(), value),
          );

          final normalizedUrl = (normalized['url'] as String? ?? '').trim();
          final normalizedStoragePath =
              (normalized['storagePath'] as String? ?? '').trim();

          // Some older posts saved only storagePath in mediaItems.
          // Reuse it as url so the viewer can resolve a download URL.
          if (normalizedUrl.isEmpty && normalizedStoragePath.isNotEmpty) {
            normalized['url'] = normalizedStoragePath;
          }

          return normalized;
        },
      )
      .map(PostMediaItem.fromMap)
      .where((item) => item.url.trim().isNotEmpty)
      .toList(growable: false);
  if (parsedMediaItems.isNotEmpty) {
    return withRootThumbnail(parsedMediaItems);
  }

  final mediaUrls = (data['mediaUrls'] as List<dynamic>? ?? const <dynamic>[])
      .map((item) => item.toString().trim())
      .where((item) => item.isNotEmpty)
      .map(
        (url) => PostMediaItem(
          url: url,
          storagePath: '',
          type: isVideoMediaUrl(url) ? 'video' : 'image',
        ),
      )
      .toList(growable: false);
  if (mediaUrls.isNotEmpty) {
    return withRootThumbnail(mediaUrls);
  }

  final singleUrl =
      ((data['mediaUrl'] as String?) ?? (data['imageUrl'] as String?) ?? '')
          .trim();
  if (singleUrl.isEmpty) {
    return const <PostMediaItem>[];
  }

  return withRootThumbnail(<PostMediaItem>[
    PostMediaItem(
      url: singleUrl,
      storagePath: (data['storagePath'] as String? ?? '').trim(),
      type: isVideoMediaUrl(singleUrl) ? 'video' : 'image',
    ),
  ]);
}

String postPrimaryMediaUrl(Map<String, dynamic> data) {
  final mediaItems = postMediaItemsFromData(data);
  if (mediaItems.isNotEmpty) {
    return mediaItems.first.url.trim();
  }
  return '';
}

String postEventGroupId(Map<String, dynamic> data) {
  return (data['eventGroupId'] as String? ?? '').trim();
}
