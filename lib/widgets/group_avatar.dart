import 'dart:typed_data';

import 'package:flutter/material.dart';

class GroupAvatar extends StatelessWidget {
  final String imageUrl;
  final Uint8List? memoryBytes;
  final double radius;
  final Color? borderColor;
  final double borderWidth;

  const GroupAvatar({
    super.key,
    this.imageUrl = '',
    this.memoryBytes,
    this.radius = 24,
    this.borderColor,
    this.borderWidth = 0,
  });

  @override
  Widget build(BuildContext context) {
    final normalizedImageUrl = imageUrl.trim();
    final hasImage = memoryBytes != null || normalizedImageUrl.isNotEmpty;
    final diameter = radius * 2;

    return Container(
      width: diameter,
      height: diameter,
      padding: EdgeInsets.all(borderWidth > 0 ? borderWidth : 0),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: borderWidth > 0 && borderColor != null
            ? Border.all(color: borderColor!, width: borderWidth)
            : null,
      ),
      child: ClipOval(
        child: hasImage
            ? Image(
                image: memoryBytes != null
                    ? MemoryImage(memoryBytes!) as ImageProvider
                    : NetworkImage(normalizedImageUrl),
                fit: BoxFit.cover,
                gaplessPlayback: true,
                filterQuality: FilterQuality.low,
                errorBuilder: (context, error, stackTrace) =>
                    _GroupAvatarPlaceholder(radius: radius),
              )
            : _GroupAvatarPlaceholder(radius: radius),
      ),
    );
  }
}

class _GroupAvatarPlaceholder extends StatelessWidget {
  final double radius;

  const _GroupAvatarPlaceholder({required this.radius});

  @override
  Widget build(BuildContext context) {
    final iconSize = radius * 0.76;
    final sideIconSize = radius * 0.48;

    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFFEAF8FF), Color(0xFFECE4FF), Color(0xFFD8F0FF)],
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
        ),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned(
            top: radius * 0.22,
            left: radius * 0.18,
            child: Container(
              width: radius * 0.42,
              height: radius * 0.42,
              decoration: BoxDecoration(
                color: const Color(0xFFBFEAFF).withValues(alpha: 0.7),
                shape: BoxShape.circle,
              ),
            ),
          ),
          Positioned(
            bottom: radius * 0.18,
            right: radius * 0.18,
            child: Container(
              width: radius * 0.52,
              height: radius * 0.52,
              decoration: BoxDecoration(
                color: const Color(0xFFDCCBFF).withValues(alpha: 0.8),
                shape: BoxShape.circle,
              ),
            ),
          ),
          Icon(
            Icons.groups_2_rounded,
            size: iconSize,
            color: const Color(0xFF7C6DDA),
          ),
          Positioned(
            top: radius * 0.62,
            left: radius * 0.28,
            child: Icon(
              Icons.person_rounded,
              size: sideIconSize,
              color: const Color(0xFF63C9F7),
            ),
          ),
          Positioned(
            top: radius * 0.58,
            right: radius * 0.28,
            child: Icon(
              Icons.person_rounded,
              size: sideIconSize,
              color: const Color(0xFFB192FF),
            ),
          ),
        ],
      ),
    );
  }
}
