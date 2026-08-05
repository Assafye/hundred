import 'package:flutter/material.dart';

class SwipeBackWrapper extends StatefulWidget {
  const SwipeBackWrapper({
    super.key,
    required this.child,
    this.enabled = true,
    this.minDistance = 84,
  });

  final Widget child;
  final bool enabled;
  final double minDistance;

  @override
  State<SwipeBackWrapper> createState() => _SwipeBackWrapperState();
}

class _SwipeBackWrapperState extends State<SwipeBackWrapper> {
  int? _activePointer;
  double _dx = 0;
  double _dy = 0;

  void _reset() {
    _activePointer = null;
    _dx = 0;
    _dy = 0;
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) {
      return widget.child;
    }

    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) {
        if (_activePointer != null) {
          return;
        }
        _activePointer = event.pointer;
        _dx = 0;
        _dy = 0;
      },
      onPointerMove: (event) {
        if (_activePointer != event.pointer) {
          return;
        }
        _dx += event.delta.dx;
        _dy += event.delta.dy.abs();
      },
      onPointerCancel: (event) {
        if (_activePointer != event.pointer) {
          return;
        }
        _reset();
      },
      onPointerUp: (event) {
        if (_activePointer != event.pointer) {
          return;
        }

        final didSwipeRightToLeft = _dx <= -widget.minDistance;
        final isMostlyHorizontal = _dx.abs() > (_dy * 1.2);
        if (didSwipeRightToLeft && isMostlyHorizontal) {
          Navigator.of(context).maybePop();
        }
        _reset();
      },
      child: widget.child,
    );
  }
}
