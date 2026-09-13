import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:hundred_version1/features/verification/face_verification_pose.dart';

void main() {
  const imageSize = Size(400, 600);
  const centeredFace = Rect.fromLTWH(100, 150, 200, 300);

  test('accepts each required pose inside its yaw range', () {
    expect(
      isFaceVerificationPoseValid(
        pose: FaceVerificationPose.front,
        boundingBox: centeredFace,
        imageSize: imageSize,
        yaw: 2,
        roll: 1,
      ),
      isTrue,
    );
    expect(
      isFaceVerificationPoseValid(
        pose: FaceVerificationPose.right,
        boundingBox: centeredFace,
        imageSize: imageSize,
        yaw: 25,
        roll: 0,
      ),
      isTrue,
    );
    expect(
      isFaceVerificationPoseValid(
        pose: FaceVerificationPose.left,
        boundingBox: centeredFace,
        imageSize: imageSize,
        yaw: -25,
        roll: 0,
      ),
      isTrue,
    );
  });

  test('rejects an incorrect pose or excessive roll', () {
    expect(
      isFaceVerificationPoseValid(
        pose: FaceVerificationPose.front,
        boundingBox: centeredFace,
        imageSize: imageSize,
        yaw: 25,
        roll: 0,
      ),
      isFalse,
    );
    expect(
      isFaceVerificationPoseValid(
        pose: FaceVerificationPose.right,
        boundingBox: centeredFace,
        imageSize: imageSize,
        yaw: 25,
        roll: 20,
      ),
      isFalse,
    );
  });

  test('rejects a face outside the centered guide area', () {
    expect(
      isFaceVerificationPoseValid(
        pose: FaceVerificationPose.front,
        boundingBox: const Rect.fromLTWH(0, 0, 80, 100),
        imageSize: imageSize,
        yaw: 0,
        roll: 0,
      ),
      isFalse,
    );
  });
}
