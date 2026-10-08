import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';

bool _isVideoSource(String source) {
  final normalized = source.trim().toLowerCase();
  final path = normalized.split('?').first.split('#').first;
  return <String>['.mp4', '.mov', '.m4v', '.webm', '.avi', '.mkv']
      .any(path.endsWith);
}

class PostMediaItem {
  final String url;
  final String storagePath;
  final String thumbnailUrl;
  final String type;
  final double cropScale;
  final double cropAlignmentX;
  final double cropAlignmentY;

  const PostMediaItem({
    required this.url,
    required this.storagePath,
    required this.type,
    this.thumbnailUrl = '',
    this.cropScale = 1,
    this.cropAlignmentX = 0,
    this.cropAlignmentY = 0,
  });

  bool get isVideo => type == 'video';

  Map<String, dynamic> toMap() {
    final result = <String, dynamic>{
      'url': url,
      'storagePath': storagePath,
      'type': type,
      'cropScale': cropScale,
      'cropAlignmentX': cropAlignmentX,
      'cropAlignmentY': cropAlignmentY,
    };
    if (thumbnailUrl.trim().isNotEmpty) {
      result['thumbnailUrl'] = thumbnailUrl;
    }
    return result;
  }

  PostMediaItem copyWith({
    String? url,
    String? storagePath,
    String? thumbnailUrl,
    String? type,
    double? cropScale,
    double? cropAlignmentX,
    double? cropAlignmentY,
  }) {
    return PostMediaItem(
      url: url ?? this.url,
      storagePath: storagePath ?? this.storagePath,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      type: type ?? this.type,
      cropScale: cropScale ?? this.cropScale,
      cropAlignmentX: cropAlignmentX ?? this.cropAlignmentX,
      cropAlignmentY: cropAlignmentY ?? this.cropAlignmentY,
    );
  }

  factory PostMediaItem.fromMap(Map<String, dynamic> map) {
    final cropScaleRaw = map['cropScale'];
    final cropAlignmentXRaw = map['cropAlignmentX'];
    final cropAlignmentYRaw = map['cropAlignmentY'];
    final url = (map['url'] as String? ?? '').trim();
    final storagePath = (map['storagePath'] as String? ?? '').trim();
    final storedType = (map['type'] as String? ?? '').trim();

    return PostMediaItem(
      url: url,
      storagePath: storagePath,
      thumbnailUrl: (map['thumbnailUrl'] as String? ??
              map['videoThumbnailUrl'] as String? ??
              '')
          .trim(),
      type: storedType.isNotEmpty
          ? storedType
          : (_isVideoSource(url.isNotEmpty ? url : storagePath)
              ? 'video'
              : 'image'),
      cropScale: cropScaleRaw is num
          ? cropScaleRaw.toDouble()
          : double.tryParse('$cropScaleRaw') ?? 1,
      cropAlignmentX: cropAlignmentXRaw is num
          ? cropAlignmentXRaw.toDouble()
          : double.tryParse('$cropAlignmentXRaw') ?? 0,
      cropAlignmentY: cropAlignmentYRaw is num
          ? cropAlignmentYRaw.toDouble()
          : double.tryParse('$cropAlignmentYRaw') ?? 0,
    );
  }
}

class PostUploadMediaItem {
  final XFile file;
  final Uint8List? previewBytes;
  final String type;
  final double cropScale;
  final double cropAlignmentX;
  final double cropAlignmentY;

  const PostUploadMediaItem({
    required this.file,
    this.previewBytes,
    required this.type,
    this.cropScale = 1,
    this.cropAlignmentX = 0,
    this.cropAlignmentY = 0,
  });

  bool get isVideo => type == 'video';

  PostUploadMediaItem copyWith({
    XFile? file,
    Uint8List? previewBytes,
    String? type,
    double? cropScale,
    double? cropAlignmentX,
    double? cropAlignmentY,
  }) {
    return PostUploadMediaItem(
      file: file ?? this.file,
      previewBytes: previewBytes ?? this.previewBytes,
      type: type ?? this.type,
      cropScale: cropScale ?? this.cropScale,
      cropAlignmentX: cropAlignmentX ?? this.cropAlignmentX,
      cropAlignmentY: cropAlignmentY ?? this.cropAlignmentY,
    );
  }

  PostMediaItem toUploaded({
    required String url,
    required String storagePath,
    String thumbnailUrl = '',
  }) {
    return PostMediaItem(
      url: url,
      storagePath: storagePath,
      thumbnailUrl: thumbnailUrl,
      type: type,
      cropScale: cropScale,
      cropAlignmentX: cropAlignmentX,
      cropAlignmentY: cropAlignmentY,
    );
  }
}
