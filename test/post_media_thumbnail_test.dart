import 'package:flutter_test/flutter_test.dart';
import 'package:hundred_version1/post_media_utils.dart';

void main() {
  test(
      'preserves a video thumbnail URL through media parsing and serialization',
      () {
    final mediaItems = postMediaItemsFromData(<String, dynamic>{
      'mediaItems': <Map<String, dynamic>>[
        <String, dynamic>{
          'url': 'posts/user/post/video.mp4',
          'storagePath': 'posts/user/post/video.mp4',
          'type': 'video',
          'thumbnailUrl': 'posts/user/post/video.mp4.thumbnail.jpg',
        },
      ],
    });

    expect(mediaItems, hasLength(1));
    expect(
      mediaItems.single.thumbnailUrl,
      'posts/user/post/video.mp4.thumbnail.jpg',
    );
    expect(
      mediaItems.single.toMap()['thumbnailUrl'],
      'posts/user/post/video.mp4.thumbnail.jpg',
    );
  });

  test('recognizes legacy video media without an explicit type', () {
    final mediaItems = postMediaItemsFromData(<String, dynamic>{
      'mediaItems': <Map<String, dynamic>>[
        <String, dynamic>{
          'url': 'https://storage.example/video.mp4?token=abc',
          'storagePath': 'posts/user/post/video.mp4',
        },
      ],
    });

    expect(mediaItems, hasLength(1));
    expect(mediaItems.single.isVideo, isTrue);
  });

  test('uses a legacy post-level video thumbnail URL', () {
    final mediaItems = postMediaItemsFromData(<String, dynamic>{
      'mediaUrl': 'posts/user/post/video.mp4',
      'videoThumbnailUrl': 'posts/user/post/video-preview.jpg',
    });

    expect(mediaItems.single.isVideo, isTrue);
    expect(
      mediaItems.single.thumbnailUrl,
      'posts/user/post/video-preview.jpg',
    );
  });
}
