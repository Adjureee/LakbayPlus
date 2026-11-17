import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Lakbay+'s original mark: an eight-point compass rose standing for
/// wayfinding across the Davao Region. It is wholly original vector artwork —
/// drawn here with [CustomPainter] math, not copied from any logo, icon pack
/// or font — and is used both in the wordmark and as the AI planner's avatar
/// glyph (see [LakbayAiAvatar]).
class LakbayCompassMark extends StatelessWidget {
  const LakbayCompassMark({
    super.key,
    this.size = 28,
    this.primaryColor,
    this.secondaryColor,
  });

  final double size;

  /// Fill for the four cardinal (N/E/S/W) points. Defaults to the current
  /// theme's primary color.
  final Color? primaryColor;

  /// Fill for the four diagonal points. Defaults to a lighter tint of
  /// [primaryColor].
  final Color? secondaryColor;

  @override
  Widget build(BuildContext context) {
    final primary = primaryColor ?? Theme.of(context).colorScheme.primary;
    return CustomPaint(
      size: Size.square(size),
      painter: _CompassMarkPainter(
        primary: primary,
        secondary: secondaryColor ?? primary.withValues(alpha: 0.45),
      ),
    );
  }
}

class _CompassMarkPainter extends CustomPainter {
  _CompassMarkPainter({required this.primary, required this.secondary});

  final Color primary;
  final Color secondary;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final outer = size.shortestSide / 2;
    final flankRadius = outer * 0.30;
    const flankAngle = math.pi / 10; // half-width of each point, in radians

    final majorPaint = Paint()..color = primary;
    final minorPaint = Paint()..color = secondary;

    for (var i = 0; i < 8; i++) {
      final isMajor = i.isEven;
      final angle = i * math.pi / 4 - math.pi / 2; // 0 points straight up
      final tipRadius = isMajor ? outer : outer * 0.62;

      Offset vertex(double a, double r) =>
          center + Offset(math.cos(a), math.sin(a)) * r;

      final path = Path()
        ..moveTo(center.dx, center.dy)
        ..lineTo(
          vertex(angle - flankAngle, flankRadius).dx,
          vertex(angle - flankAngle, flankRadius).dy,
        )
        ..lineTo(vertex(angle, tipRadius).dx, vertex(angle, tipRadius).dy)
        ..lineTo(
          vertex(angle + flankAngle, flankRadius).dx,
          vertex(angle + flankAngle, flankRadius).dy,
        )
        ..close();

      canvas.drawPath(path, isMajor ? majorPaint : minorPaint);
    }

    canvas.drawCircle(center, outer * 0.16, majorPaint);
  }

  @override
  bool shouldRepaint(covariant _CompassMarkPainter oldDelegate) =>
      oldDelegate.primary != primary || oldDelegate.secondary != secondary;
}
