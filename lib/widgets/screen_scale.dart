import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Lays the child out at an iPhone-sized virtual width and scales it to fit.
/// Android only; iOS and other platforms are returned untouched.
class ScreenScale extends StatelessWidget {
  const ScreenScale({super.key, required this.child});

  static const double _referenceWidth = 430;
  static const double _minScale = 0.8;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return child;
    }

    final mq = MediaQuery.of(context);
    final scale =
        (mq.size.shortestSide / _referenceWidth).clamp(_minScale, 1.0);
    if (scale >= 0.999) {
      return child;
    }

    final inv = 1 / scale;
    final virtualMq = mq.copyWith(
      size: mq.size * inv,
      devicePixelRatio: mq.devicePixelRatio * scale,
      padding: mq.padding * inv,
      viewPadding: mq.viewPadding * inv,
      viewInsets: mq.viewInsets * inv,
      systemGestureInsets: mq.systemGestureInsets * inv,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.biggest;
        return MediaQuery(
          data: virtualMq,
          child: FittedBox(
            fit: BoxFit.fill,
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: available.width * inv,
              height: available.height * inv,
              child: child,
            ),
          ),
        );
      },
    );
  }
}
