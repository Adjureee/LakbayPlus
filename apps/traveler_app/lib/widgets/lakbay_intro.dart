import 'dart:math' as math;
import 'dart:ui' show PathMetric;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../design/design.dart';

/// The app-open intro, played once per launch on the same deep teal as the
/// native splash, so the hand-off is seamless (about 2.6 s):
///
/// 1. faint map contour lines fade in and drift,
/// 2. a mango pin pulses in the lower left and a glowing route travels from
///    it towards the logo,
/// 3. the letters of "Lakbay" rise in one by one,
/// 4. the route lands where the mango "+" pops, with a ring burst and a
///    light haptic tick,
/// 5. the tagline fades up and a shimmer sweeps across the wordmark.
///
/// [onFinished] fires when the animation ends (or on tap, to skip). If the app
/// is still loading by then, a thin lagoon line sweeps under the tagline.
/// With motion off it shows the final frame and finishes at once.
class LakbayIntro extends StatefulWidget {
  const LakbayIntro({
    super.key,
    required this.onFinished,
    this.loading = false,
  });

  final VoidCallback onFinished;

  /// True while the app is still loading after the animation ends.
  final bool loading;

  /// Turned off in widget tests (`test/flutter_test_config.dart`).
  static bool enabled = true;

  static const Duration length = Duration(milliseconds: 2600);

  @override
  State<LakbayIntro> createState() => _LakbayIntroState();
}

class _LakbayIntroState extends State<LakbayIntro>
    with TickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: LakbayIntro.length,
  );
  late final AnimationController _loader = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );
  late final TextStyle _wordStyle = GoogleFonts.bricolageGrotesque(
    fontSize: 54,
    fontWeight: FontWeight.w800,
    letterSpacing: -1.4,
    height: 1,
    color: Colors.white,
  );
  bool _started = false;
  bool _done = false;
  bool _ticked = false;

  @override
  void initState() {
    super.initState();
    _c.addListener(_maybeTick);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (!LkMotion.of(context).enabled) {
      _c.value = 1;
      WidgetsBinding.instance.addPostFrameCallback((_) => _finish());
      return;
    }
    _c.forward().whenComplete(_finish);
  }

  /// One light tick as the "+" lands.
  void _maybeTick() {
    if (!_ticked && _c.value >= 0.6) {
      _ticked = true;
      HapticFeedback.lightImpact();
    }
  }

  void _finish() {
    if (_done || !mounted) return;
    _done = true;
    _syncLoader();
    widget.onFinished();
  }

  @override
  void didUpdateWidget(covariant LakbayIntro oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncLoader();
  }

  void _syncLoader() {
    if (!mounted) return;
    final show = widget.loading && _done && LkMotion.of(context).enabled;
    if (show && !_loader.isAnimating) {
      _loader.repeat();
    } else if (!show && _loader.isAnimating) {
      _loader.stop();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    _loader.dispose();
    super.dispose();
  }

  /// 0→1 progress of the intro between [start] and [end] (fractions).
  double _seg(double start, double end, [Curve curve = LkMotion.standard]) {
    final t = ((_c.value - start) / (end - start)).clamp(0.0, 1.0);
    return curve.transform(t);
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Lakbay+, Davao Region AI travel planner',
      liveRegion: true,
      button: true,
      onTapHint: 'Skip intro',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          _c.value = 1;
          _finish();
        },
        child: Material(
          color: LkColors.bg,
          child: LayoutBuilder(
            builder: (context, box) {
              final size = box.biggest;
              // The logo sits a little above center, like the native splash.
              final logoCenter = Offset(size.width / 2, size.height * 0.46);
              final plusAt = logoCenter + const Offset(98, -22);
              return AnimatedBuilder(
                animation: _c,
                builder: (context, _) => Stack(
                  fit: StackFit.expand,
                  children: [
                    RepaintBoundary(
                      child: CustomPaint(
                        painter: _ContoursPainter(
                          reveal: _seg(0, 0.3),
                          drift: _c.value,
                          center: logoCenter,
                        ),
                      ),
                    ),
                    // Soft lagoon glow that brightens as the logo arrives.
                    Positioned.fromRect(
                      rect: Rect.fromCenter(
                        center: logoCenter,
                        width: size.width * 1.6,
                        height: size.width * 1.6,
                      ),
                      child: Opacity(
                        opacity: 0.6 * _seg(0.2, 0.75),
                        child: const DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: RadialGradient(
                              radius: 0.5,
                              colors: [Color(0x402CC5BC), Color(0x0004191C)],
                            ),
                          ),
                        ),
                      ),
                    ),
                    RepaintBoundary(
                      child: CustomPaint(
                        painter: _RoutePainter(
                          start: Offset(size.width * 0.12, size.height * 0.8),
                          end: plusAt,
                          pin: _seg(0, 0.14, Curves.easeOutBack),
                          draw: _seg(0.08, 0.58, Curves.easeInOutCubic),
                          tip: 1 - _seg(0.58, 0.66),
                          fade: 1 - _seg(0.8, 1) * 0.5,
                          burst: _seg(0.58, 0.82, Curves.easeOutCubic),
                        ),
                      ),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      top: logoCenter.dy - 34,
                      child: _logo(),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _logo() {
    const word = 'Lakbay';
    final plus = _seg(0.58, 0.8, Curves.elasticOut);
    final tagline = _seg(0.7, 0.9);
    final shimmer = _seg(0.78, 1, Curves.easeInOut);
    final letters = Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        for (var i = 0; i < word.length; i++)
          Builder(
            builder: (_) {
              final t = _seg(0.22 + i * 0.04, 0.48 + i * 0.04);
              return Opacity(
                opacity: t,
                child: Transform.translate(
                  offset: Offset(0, 26 * (1 - t)),
                  child: Transform.scale(
                    scale: 0.9 + 0.1 * t,
                    child: Text(word[i], style: _wordStyle),
                  ),
                ),
              );
            },
          ),
        Transform.scale(
          scale: plus,
          child: Text('+', style: _wordStyle.copyWith(color: LkColors.mango)),
        ),
      ],
    );
    return ExcludeSemantics(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // A light band sweeps across the finished wordmark.
          shimmer <= 0 || shimmer >= 1
              ? letters
              : ShaderMask(
                  blendMode: BlendMode.srcATop,
                  shaderCallback: (rect) => LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: const [
                      Color(0x00FFFFFF),
                      Color(0x8CFFFFFF),
                      Color(0x00FFFFFF),
                    ],
                    stops: [
                      (shimmer * 1.4 - 0.35).clamp(0.0, 1.0),
                      (shimmer * 1.4 - 0.2).clamp(0.0, 1.0),
                      (shimmer * 1.4 - 0.05).clamp(0.0, 1.0),
                    ],
                  ).createShader(rect),
                  child: letters,
                ),
          const SizedBox(height: 16),
          Opacity(
            opacity: tagline,
            child: Transform.translate(
              offset: Offset(0, 10 * (1 - tagline)),
              child: Text(
                'Davao Region AI travel planner',
                style: LkType.label.copyWith(
                  color: LkColors.muted,
                  letterSpacing: 0.6,
                ),
              ),
            ),
          ),
          const SizedBox(height: 24),
          // Still loading after the intro: a lagoon line sweeps underneath.
          SizedBox(
            width: 120,
            height: 3,
            child: widget.loading && _done
                ? AnimatedBuilder(
                    animation: _loader,
                    builder: (_, _) =>
                        CustomPaint(painter: _LoaderPainter(_loader.value)),
                  )
                : null,
          ),
        ],
      ),
    );
  }
}

/// Faint contour lines, like a topographic map of the region, that fade in
/// and drift slowly.
class _ContoursPainter extends CustomPainter {
  _ContoursPainter({
    required this.reveal,
    required this.drift,
    required this.center,
  });

  final double reveal;
  final double drift;
  final Offset center;

  @override
  void paint(Canvas canvas, Size size) {
    if (reveal <= 0) return;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final origin = center + Offset(size.width * 0.35, size.height * 0.28);
    for (var ring = 0; ring < 7; ring++) {
      final base = 90.0 + ring * 62;
      final path = Path();
      for (var a = 0; a <= 72; a++) {
        final angle = a / 72 * math.pi * 2;
        final wobble =
            1 +
            0.08 * math.sin(angle * 3 + ring * 0.9 + drift * 1.2) +
            0.05 * math.cos(angle * 5 - ring * 0.4);
        final r = base * wobble * (0.94 + 0.06 * reveal);
        final p = origin + Offset(math.cos(angle) * r, math.sin(angle) * r);
        if (a == 0) {
          path.moveTo(p.dx, p.dy);
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      path.close();
      paint.color = LkColors.lagoon.withValues(
        alpha: (0.10 - ring * 0.01) * reveal,
      );
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _ContoursPainter old) =>
      old.reveal != reveal || old.drift != drift;
}

class _RoutePainter extends CustomPainter {
  _RoutePainter({
    required this.start,
    required this.end,
    required this.pin,
    required this.draw,
    required this.tip,
    required this.fade,
    required this.burst,
  });

  final Offset start;
  final Offset end;
  final double pin;
  final double draw;
  final double tip;
  final double fade;
  final double burst;

  @override
  void paint(Canvas canvas, Size size) {
    // Start pin: a mango dot with a soft ring.
    if (pin > 0) {
      canvas.drawCircle(
        start,
        16 * pin,
        Paint()..color = LkColors.mango.withValues(alpha: 0.16 * fade),
      );
      canvas.drawCircle(
        start,
        6 * pin,
        Paint()..color = LkColors.mango.withValues(alpha: fade),
      );
    }
    if (draw <= 0) return;

    final path = Path()
      ..moveTo(start.dx, start.dy)
      ..cubicTo(
        start.dx + (end.dx - start.dx) * 0.2,
        start.dy + 40,
        end.dx - 30,
        end.dy + 150,
        end.dx,
        end.dy,
      );
    final dash = Paint()
      ..color = LkColors.mango.withValues(alpha: 0.9 * fade)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    for (final PathMetric m in path.computeMetrics()) {
      final drawnLength = m.length * draw;
      for (var d = 0.0; d < drawnLength; d += 14) {
        canvas.drawPath(m.extractPath(d, math.min(d + 8, drawnLength)), dash);
      }
      // Glowing head: layered soft circles (cheaper than a blur).
      final head = m.getTangentForOffset(drawnLength)?.position;
      if (head != null && tip > 0) {
        for (final (r, a) in const [(22.0, 0.08), (13.0, 0.18), (6.0, 1.0)]) {
          canvas.drawCircle(
            head,
            r,
            Paint()..color = LkColors.mango.withValues(alpha: a * tip),
          );
        }
      }
    }

    // Ring burst where the route lands on the "+".
    if (burst > 0 && burst < 1) {
      canvas.drawCircle(
        end,
        10 + 54 * burst,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5 * (1 - burst) + 0.5
          ..color = LkColors.mango.withValues(alpha: 0.7 * (1 - burst)),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _RoutePainter old) =>
      old.draw != draw ||
      old.pin != pin ||
      old.tip != tip ||
      old.fade != fade ||
      old.burst != burst;
}

class _LoaderPainter extends CustomPainter {
  _LoaderPainter(this.t);

  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final track = Paint()
      ..color = LkColors.s3
      ..strokeWidth = size.height
      ..strokeCap = StrokeCap.round;
    final y = size.height / 2;
    canvas.drawLine(Offset(0, y), Offset(size.width, y), track);
    final seg = size.width * 0.35;
    final x = (size.width + seg) * t - seg;
    canvas.drawLine(
      Offset(x.clamp(0, size.width), y),
      Offset((x + seg).clamp(0, size.width), y),
      track..color = LkColors.lagoon,
    );
  }

  @override
  bool shouldRepaint(covariant _LoaderPainter old) => old.t != t;
}
