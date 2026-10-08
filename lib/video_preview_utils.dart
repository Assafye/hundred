import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

final Map<String, Future<Uint8List?>> _videoPreviewCache =
    <String, Future<Uint8List?>>{};
Future<void> _videoPreviewQueue = Future<void>.value();

Future<Uint8List?> buildVideoPreviewBytesFromSource(String source) {
  if (kIsWeb) {
    return Future<Uint8List?>.value();
  }

  final normalized = source.trim();
  if (normalized.isEmpty) {
    return Future<Uint8List?>.value();
  }

  final cached = _videoPreviewCache[normalized];
  if (cached != null) return cached;

  final completer = Completer<Uint8List?>();
  _videoPreviewCache[normalized] = completer.future;
  while (_videoPreviewCache.length > 96) {
    _videoPreviewCache.remove(_videoPreviewCache.keys.first);
  }

  _videoPreviewQueue = _videoPreviewQueue.then((_) async {
    try {
      final bytes = await VideoThumbnail.thumbnailData(
        video: normalized,
        imageFormat: ImageFormat.JPEG,
        maxWidth: 360,
        quality: 70,
        timeMs: 0,
      );
      completer.complete(bytes);
    } on MissingPluginException {
      completer.complete(null);
    } catch (_) {
      completer.complete(null);
    }
  });

  return completer.future;
}

Future<String?> resolveVideoPreviewSource(String source) async {
  final normalized = source.trim();
  if (normalized.isEmpty) return null;
  if (normalized.startsWith('http://') || normalized.startsWith('https://')) {
    return normalized;
  }

  try {
    if (normalized.startsWith('gs://')) {
      return await FirebaseStorage.instance
          .refFromURL(normalized)
          .getDownloadURL();
    }
    return await FirebaseStorage.instance.ref(normalized).getDownloadURL();
  } catch (_) {
    return null;
  }
}

Future<Uint8List?> buildVideoPreviewBytes(XFile file) async {
  final source = file.path.trim().isNotEmpty ? file.path : file.name.trim();
  return buildVideoPreviewBytesFromSource(source);
}
