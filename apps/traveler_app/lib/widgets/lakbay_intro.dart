import 'dart:math' as math;
import 'dart:ui' show PathMetric;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../design/design.dart';

/// The app-open intro, played once per launch on the same deep teal as the
/// native splash, so the hand-off is seamless:
///
/// 1. a mango route line draws across the screen,
/// 2. the letters of "Lakbay" rise in one by one,
/// 3. the mango "+" pops,
/// 4. the tagline fades in.
///
/// [onFinished] fires when the animation ends (or on tap, to skip). If the app
/// is still loading by then, a thin lagoon line keeps moving under the
/// tagline. With motion off it shows the final frame and finishes at once.
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

  static const Duration length = Duration(milliseconds: 2100);

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
  bool _started = false;
  bool _done = false;

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

  void _finish() {
    if (_done || !mounted) return;
    _done = true;
    widget.onFinished();
  }

  @override
  void didUpdateWidget(covariant LakbayIntro oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncLoader();
  }

  void _syncLoader() {
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

  /// 0→1 progress of [_c] between [start] and [end] (fractions of the intro).
  double _seg(double start, double end, [Curve curve = LkMotion.standard]) {
    final t = ((_c.value - start) / (end - start)).clamp(0.0, 1.0);
    return curve.transform(t);
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncLoader();
    });
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
          child: AnimatedBuilder(
            animation: Listenable.merge([_c, _loader]),
            builder: (context, _) => Stack(
              fit: StackFit.expand,
              children: [
                // Soft lagoon glow that brightens as the logo arrives.
                Opacity(
                  opacity: 0.55 * _seg(0.1, 0.7),
                  child: const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        radius: 0.75,
                        colors: [Color(0x332CC5BC), Color(0x0004191C)],
                      ),
                    ),
                  ),
                ),
                // The route arrives exactly where the "+" pops.
                CustomPaint(
                  painter: _IntroRoutePainter(
                    draw: _seg(0.04, 0.58, Curves.easeInOutCubic),
                    fade: 1 - _seg(0.82, 1) * 0.55,
                    tipFade: 1 - _seg(0.58, 0.68),
                  ),
                ),
                Center(child: _logo()),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _logo() {
    const word = 'Lakbay';
    final style = GoogleFonts.bricolageGrotesque(
      fontSize: 52,
      fontWeight: FontWeight.w800,
      letterSpacing: -1.3,
      height: 1,
      color: Colors.white,
    );
    final plus = _seg(0.58, 0.8, Curves.elasticOut);
    final tagline = _seg(0.72, 0.95);
    return ExcludeSemantics(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              for (var i = 0; i < word.length; i++)
                Builder(
                  builder: (_) {
                    final t = _seg(0.22 + i * 0.045, 0.5 + i * 0.045);
                    return Opacity(
                      opacity: t,
                      child: Transform.translate(
                        offset: Offset(0, 22 * (1 - t)),
                        child: Text(word[i], style: style),
                      ),
                    );
                  },
                ),
              Transform.scale(
                scale: plus,
                child: Text('+', style: style.copyWith(color: LkColors.mango)),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Opacity(
            opacity: tagline,
            child: Transform.translate(
              offset: Offset(0, 8 * (1 - tagline)),
              child: Text(
                'Davao Region AI travel planner',
                style: LkType.label.copyWith(
                  color: LkColors.muted,
                  letterSpacing: 0.4,
                ),
              ),
            ),
          ),
          const SizedBox(height: 22),
          // Still loading after the intro: a lagoon line sweeps underneath.
          SizedBox(
            width: 120,
            height: 3,
            child: widget.loading && _done
                ? CustomPaint(painter: _LoaderPainter(_loader.value))
                : null,
          ),
        ],
      ),
    );
  }
}

class _IntroRoutePainter extends CustomPainter {
  _IntroRoutePainter({
    required this.draw,
    required this.fade,
    required this.tipFade,
  });

  final double draw;
  final double fade;
  final double tipFade;

  @override
  void paint(Canvas canvas, Size size) {
    if (draw <= 0) return;
    final w = size.width, h = size.height;
    // From the lower left, under the word, up to the "+" (the logo is
    // centered; "Lakbay" at 52px is about 170px wide).
    final start = Offset(w * -0.05, h * 0.86);
    final end = Offset(w / 2 + 96, h / 2 - 22);
    final path = Path()
      ..moveTo(start.dx, start.dy)
      ..cubicTo(w * 0.28, h * 0.92, w / 2 + 40, h / 2 + 70, end.dx, end.dy);
    final paint = Paint()
      ..color = LkColors.mango.withValues(alpha: 0.85 * fade)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    for (final PathMetric m in path.computeMetrics()) {
      final drawn = m.extractPath(0, m.length * draw);
      // Dashed, like a planned route.
      for (final dm in drawn.computeMetrics()) {
        for (var d = 0.0; d < dm.length; d += 14) {
          canvas.drawPath(dm.extractPath(d, math.min(d + 8, dm.length)), paint);
        }
      }
      final tip = m.getTangentForOffset(m.length * draw)?.position;
      if (tip != null) {
        canvas.drawCircle(
          tip,
          6,
          Paint()..color = LkColors.mango.withValues(alpha: tipFade),
        );
        canvas.drawCircle(
          tip,
          14,
          Paint()..color = LkColors.mango.withValues(alpha: 0.18 * tipFade),
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _IntroRoutePainter old) =>
      old.draw != draw || old.fade != fade || old.tipFade != tipFade;
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
