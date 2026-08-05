import 'dart:math' as math;

import 'package:flutter/material.dart';

class AnimatedInfinitySplashScreen extends StatefulWidget {
  const AnimatedInfinitySplashScreen({
    super.key,
    this.withScaffold = true,
  });

  final bool withScaffold;

  @override
  State<AnimatedInfinitySplashScreen> createState() =>
      _AnimatedInfinitySplashScreenState();
}

class _AnimatedInfinitySplashScreenState
    extends State<AnimatedInfinitySplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _gradientController;

  @override
  void initState() {
    super.initState();
    _gradientController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 7),
    )..repeat();
  }

  @override
  void dispose() {
    _gradientController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shortestSide = MediaQuery.of(context).size.shortestSide;
    final logoSize = shortestSide.clamp(220.0, 330.0);

    final splashBody = Center(
      child: AnimatedBuilder(
        animation: _gradientController,
        builder: (context, child) {
          return Container(
            width: logoSize,
            height: logoSize,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(46),
              gradient: const LinearGradient(
                colors: [Color(0xFF11111A), Color(0xFF05050B)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            padding: EdgeInsets.all(logoSize * 0.16),
            child: CustomPaint(
              painter: _InfinityPainter(
                phase: _gradientController.value,
              ),
            ),
          );
        },
      ),
    );

    if (!widget.withScaffold) {
      return Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: Color(0xFF000000)),
          splashBody,
        ],
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFF000000),
      body: splashBody,
    );
  }
}

class _InfinityPainter extends CustomPainter {
  const _InfinityPainter({required this.phase});

  final double phase;

  @override
  void paint(Canvas canvas, Size size) {
    final path = _buildInfinityPath(size);
    final angle = phase * math.pi * 2;
    final dx = math.cos(angle);
    final dy = math.sin(angle);
    final center = Offset(size.width / 2, size.height / 2);
    final travel = Offset(dx, dy) * (size.width * 0.22);
    final gradientStart = center - travel;
    final gradientEnd = center + travel;

    final shader = const LinearGradient(
      colors: [
        Color(0xFF1EDCFF),
        Color(0xFF76D1FF),
        Color(0xFFC38CFF),
        Color(0xFF76D1FF),
        Color(0xFF1EDCFF),
      ],
      stops: [0.0, 0.24, 0.5, 0.76, 1.0],
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    ).createShader(Rect.fromPoints(gradientStart, gradientEnd));

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = size.width * 0.068
      ..shader = shader;

    canvas.drawPath(path, paint);
  }

  Path _buildInfinityPath(Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;

    // Balanced lemniscate values to keep both loops circular-looking.
    final a = size.width * 0.42;
    final yScale = a;
    const pointCount = 360;

    final path = Path();
    for (var i = 0; i <= pointCount; i++) {
      final t = (i / pointCount) * math.pi * 2;
      final sinT = math.sin(t);
      final cosT = math.cos(t);
      final d = 1 + sinT * sinT;

      final x = cx + a * cosT / d;
      final y = cy + yScale * sinT * cosT / d;

      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    path.close();

    final centerLineHalf = size.height * 0.27;
    path
      ..moveTo(cx, cy - centerLineHalf)
      ..lineTo(cx, cy + centerLineHalf);

    return path;
  }

  @override
  bool shouldRepaint(covariant _InfinityPainter oldDelegate) {
    return oldDelegate.phase != phase;
  }
}