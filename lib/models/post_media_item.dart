import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';

class PostMediaItem {
  final String url;
  final String storagePath;
  final String type;
  final double cropScale;
  final double cropAlignmentX;
  final double cropAlignmentY;

  const PostMediaItem({
    required this.url,
    required this.storagePath,
    required this.type,
    this.cropScale = 1,
    this.cropAlignmentX = 0,
    this.cropAlignmentY = 0,
  });

  bool get isVideo => type == 'video';

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'url': url,
      'storagePath': storagePath,
      'type': type,
      'cropScale': cropScale,
      'cropAlignmentX': cropAlignmentX,
      'cropAlignmentY': cropAlignmentY,
    };
  }

  PostMediaItem copyWith({
    String? url,
    String? storagePath,
    String? type,
    double? cropScale,
    double? cropAlignmentX,
    double? cropAlignmentY,
  }) {
    return PostMediaItem(
      url: url ?? this.url,
      storagePath: storagePath ?? this.storagePath,
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

    return PostMediaItem(
      url: (map['url'] as String? ?? '').trim(),
      storagePath: (map['storagePath'] as String? ?? '').trim(),
      type: (map['type'] as String? ?? 'image').trim().isEmpty
          ? 'image'
          : (map['type'] as String? ?? 'image').trim(),
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
  }) {
    return PostMediaItem(
      url: url,
      storagePath: storagePath,
      type: type,
      cropScale: cropScale,
      cropAlignmentX: cropAlignmentX,
      cropAlignmentY: cropAlignmentY,
    );
  }
}
