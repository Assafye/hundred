import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hundred_version1/features/verification/camera_frame_jpeg.dart';
import 'package:image/image.dart' as img;

void main() {
  test('NV21 frame is converted, rotated and encoded as JPEG', () async {
    const width = 8;
    const height = 4;
    final bytes = Uint8List(width * height * 3 ~/ 2);
    bytes.fillRange(0, width * height, 200);
    bytes.fillRange(width * height, bytes.length, 128);

    final jpeg = await encodeCameraFrameAsJpeg(
      CameraFrameJpegRequest(
        width: width,
        height: height,
        bytes: bytes,
        bytesPerRow: width,
        isNv21: true,
        rotationDegrees: 90,
      ),
    );

    final decoded = img.decodeJpg(jpeg)!;
    expect(decoded.width, height);
    expect(decoded.height, width);
    final pixel = decoded.getPixel(1, 1);
    expect(pixel.r, closeTo(200, 6));
    expect(pixel.g, closeTo(200, 6));
    expect(pixel.b, closeTo(200, 6));
  });

  test('BGRA frame keeps channel order', () async {
    const width = 4;
    const height = 4;
    final bytes = Uint8List(width * height * 4);
    for (var i = 0; i < bytes.length; i += 4) {
      bytes[i] = 0; // B
      bytes[i + 1] = 0; // G
      bytes[i + 2] = 255; // R
      bytes[i + 3] = 255; // A
    }

    final jpeg = await encodeCameraFrameAsJpeg(
      CameraFrameJpegRequest(
        width: width,
        height: height,
        bytes: bytes,
        bytesPerRow: width * 4,
        isNv21: false,
        rotationDegrees: 0,
      ),
    );

    final pixel = img.decodeJpg(jpeg)!.getPixel(1, 1);
    expect(pixel.r, greaterThan(200));
    expect(pixel.b, lessThan(60));
  });
}
