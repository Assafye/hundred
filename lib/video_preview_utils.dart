import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

Future<Uint8List?> buildVideoPreviewBytesFromSource(String source) async {
  if (kIsWeb) {
    return null;
  }

  final normalized = source.trim();
  if (normalized.isEmpty) {
    return null;
  }

  try {
    return VideoThumbnail.thumbnailData(
      video: normalized,
      imageFormat: ImageFormat.JPEG,
      maxWidth: 360,
      quality: 70,
      // Use first frame deterministically to avoid random black previews.
      timeMs: 0,
    );
  } on MissingPluginException {
    return null;
  }
}

Future<Uint8List?> buildVideoPreviewBytes(XFile file) async {
  final source = file.path.trim().isNotEmpty ? file.path : file.name.trim();
  return buildVideoPreviewBytesFromSource(source);
}
