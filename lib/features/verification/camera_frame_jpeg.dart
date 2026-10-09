import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

class CameraFrameJpegRequest {
  const CameraFrameJpegRequest({
    required this.width,
    required this.height,
    required this.bytes,
    required this.bytesPerRow,
    required this.isNv21,
    required this.rotationDegrees,
  });

  final int width;
  final int height;
  final Uint8List bytes;
  final int bytesPerRow;
  final bool isNv21;
  final int rotationDegrees;
}

/// Encodes a single-plane camera frame (NV21 or BGRA8888) as an upright JPEG.
Future<Uint8List> encodeCameraFrameAsJpeg(CameraFrameJpegRequest request) {
  return compute(_encode, request);
}

Uint8List _encode(CameraFrameJpegRequest request) {
  final image = request.isNv21 ? _fromNv21(request) : _fromBgra(request);
  final rotated = request.rotationDegrees % 360 == 0
      ? image
      : img.copyRotate(image, angle: request.rotationDegrees);
  return Uint8List.fromList(img.encodeJpg(rotated, quality: 92));
}

img.Image _fromBgra(CameraFrameJpegRequest r) {
  return img.Image.fromBytes(
    width: r.width,
    height: r.height,
    bytes: r.bytes.buffer,
    bytesOffset: r.bytes.offsetInBytes,
    rowStride: r.bytesPerRow,
    numChannels: 4,
    order: img.ChannelOrder.bgra,
  );
}

img.Image _fromNv21(CameraFrameJpegRequest r) {
  final width = r.width;
  final height = r.height;
  final stride = r.bytesPerRow;
  final uvOffset = stride * height;
  if (r.bytes.length < uvOffset + stride * (height ~/ 2)) {
    throw StateError('Unexpected NV21 frame size.');
  }

  final out = img.Image(width: width, height: height, numChannels: 3);
  for (var y = 0; y < height; y++) {
    final uvRow = uvOffset + (y >> 1) * stride;
    for (var x = 0; x < width; x++) {
      final luma = r.bytes[y * stride + x];
      final uvIndex = uvRow + (x & ~1);
      final v = r.bytes[uvIndex] - 128;
      final u = r.bytes[uvIndex + 1] - 128;
      out.setPixelRgb(
        x,
        y,
        (luma + 1.402 * v).round().clamp(0, 255),
        (luma - 0.344136 * u - 0.714136 * v).round().clamp(0, 255),
        (luma + 1.772 * u).round().clamp(0, 255),
      );
    }
  }
  return out;
}
