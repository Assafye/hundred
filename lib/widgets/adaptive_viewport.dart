import 'package:flutter/material.dart';

/// Normalizes app-level media query behavior.
///
/// We keep text scaling fixed to preserve the designed layout.
class AdaptiveViewport extends StatelessWidget {
  const AdaptiveViewport({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final adjustedMediaQuery = mediaQuery.copyWith(
      textScaler: const TextScaler.linear(1.0),
    );

    return MediaQuery(data: adjustedMediaQuery, child: child);
  }
}
