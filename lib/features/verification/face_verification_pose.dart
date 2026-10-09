import 'dart:ui';

enum FaceVerificationPose { front, right, left }

bool isFaceVerificationPoseValid({
  required FaceVerificationPose pose,
  required Rect boundingBox,
  required Size imageSize,
  required double? yaw,
  required double? roll,
  double? firstTurnYaw,
}) {
  if (yaw == null || roll == null || roll.abs() > 15) return false;
  if (imageSize.width <= 0 || imageSize.height <= 0) return false;

  final widthRatio = boundingBox.width / imageSize.width;
  final heightRatio = boundingBox.height / imageSize.height;
  final horizontalOffset =
      (boundingBox.center.dx - imageSize.width / 2).abs() / imageSize.width;
  final verticalOffset =
      (boundingBox.center.dy - imageSize.height / 2).abs() / imageSize.height;
  final isPositioned = widthRatio >= 0.25 &&
      widthRatio <= 0.82 &&
      heightRatio >= 0.25 &&
      heightRatio <= 0.9 &&
      horizontalOffset <= 0.2 &&
      verticalOffset <= 0.22;
  if (!isPositioned) return false;

  switch (pose) {
    case FaceVerificationPose.front:
      return yaw.abs() <= 10;
    case FaceVerificationPose.right:
      // First turn: either direction is accepted.
      return yaw.abs() >= 18 && yaw.abs() <= 50;
    case FaceVerificationPose.left:
      // Second turn: must be the opposite direction of the first one.
      if (yaw.abs() < 18 || yaw.abs() > 50) return false;
      return firstTurnYaw == null || yaw.sign != firstTurnYaw.sign;
  }
}
