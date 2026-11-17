import 'dart:ui' show PathMetric;

import 'package:flutter/material.dart';

import '../design/design.dart';
import 'brand/lakbay_wordmark.dart';

/// First-launch screen (v8 Welcome): a full-bleed Region XI photo that
/// drifts slowly, a mango route that draws from Davao City to Samal Island,
/// the headline, and the two ways in. Motion stops under reduced motion.
class WelcomeHero extends StatefulWidget {
  const WelcomeHero({
    super.key,
    required this.photoAsset,
    required this.onStart,
    required this.onSignIn,
  });

  final String photoAsset;
  final VoidCallback onStart;
  final VoidCallback onSignIn;

  @override
  State<WelcomeHero> createState() => _WelcomeHeroState();
}

class _WelcomeHeroState extends State<WelcomeHero>
    with TickerProviderStateMixin {
  late final AnimationController _drift = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 24),
  );
  late final AnimationController _route = AnimationController(
    vsync: this,
    duration: LkMotion.routeDraw,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = !LkMotion.of(context).enabled;
    if (reduced) {
      _drift.stop();
      _route.value = 1;
    } else {
      if (!_drift.isAnimating) _drift.repeat(reverse: true);
      if (_route.value == 0) _route.forward();
    }
  }

  @override
  void dispose() {
    _drift.dispose();
    _route.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: LkColors.bg,
      body: Stack(
        fit: StackFit.expand,
        children: [
          AnimatedBuilder(
            animation: _drift,
            builder: (_, child) => Transform.scale(
              scale: 1.02 + 0.08 * Curves.easeInOut.transform(_drift.value),
              alignment: const Alignment(0.3, -0.3),
              child: child,
            ),
            child: Image.asset(
              widget.photoAsset,
              fit: BoxFit.cover,
              excludeFromSemantics: true,
              errorBuilder: (_, _, _) => DecoratedBox(
                decoration: BoxDecoration(gradient: LkColors.surfaceGradient),
              ),
            ),
          ),
          const DecoratedBox(
            decoration: BoxDecoration(gradient: LkColors.heroScrim),
          ),
          // Extra shade behind the wordmark so it reads on bright skies.
          const Positioned(
            left: 0,
            right: 0,
            top: 0,
            height: 220,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xF5021114), Color(0x00021114)],
                ),
              ),
            ),
          ),
          // Route and pins sit in the photo area, above the copy.
          Positioned(
            left: 0,
            right: 0,
            top: MediaQuery.paddingOf(context).top + 64,
            // The copy block needs about 520dp at the bottom.
            height:
                (MediaQuery.sizeOf(context).height -
                        MediaQuery.paddingOf(context).top -
                        64 -
                        540)
                    .clamp(0.0, double.infinity),
            child: ExcludeSemantics(
              child: LayoutBuilder(
                builder: (context, box) =>
                    _RouteLayer(progress: _route, size: box.biggest),
              ),
            ),
          ),
          SafeArea(
            // Scrolls only when it can't fit (short screens, large text).
            child: LayoutBuilder(
              builder: (context, box) => SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: box.maxHeight),
                  child: IntrinsicHeight(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(
                        LkSpace.xxl,
                        LkSpace.l,
                        LkSpace.xxl,
                        LkSpace.l,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const LakbayWordmark(fontSize: 28, color: Colors.white),
                          const Spacer(),
                          Row(
                            children: [
                              Container(
                                width: 20,
                                height: 2,
                                color: LkColors.mango,
                              ),
                              const SizedBox(width: LkSpace.s),
                              Text(
                                'Davao Region travel planner',
                                style: LkType.label.copyWith(
                                  color: LkColors.mango,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: LkSpace.m),
                          Semantics(
                            header: true,
                            label: 'Tell it the vibe. Get the whole trip.',
                            excludeSemantics: true,
                            child: Text.rich(
                              TextSpan(
                                text: 'Tell it the vibe.\nGet the ',
                                children: [
                                  TextSpan(
                                    text: 'whole',
                                    style: LkType.hero.copyWith(
                                      color: LkColors.mango,
                                      fontSize: _heroSize(context),
                                    ),
                                  ),
                                  const TextSpan(text: '\ntrip.'),
                                ],
                              ),
                              style: LkType.hero.copyWith(
                                color: Colors.white,
                                fontSize: _heroSize(context),
                              ),
                            ),
                          ),
                          const SizedBox(height: LkSpace.l),
                          Text(
                            'Real places, ferries and fare estimates across Region '
                            'XI, planned day by day in one chat.',
                            style: LkType.bodyLarge.copyWith(
                              color: Colors.white.withValues(alpha: 0.86),
                            ),
                          ),
                          const SizedBox(height: LkSpace.xxl),
                          LkButton(
                            label: 'Start planning',
                            size: LkButtonSize.large,
                            trailingArrow: true,
                            expand: true,
                            onPressed: widget.onStart,
                          ),
                          const SizedBox(height: LkSpace.s),
                          Center(
                            child: TextButton(
                              onPressed: widget.onSignIn,
                              style: TextButton.styleFrom(
                                minimumSize: const Size(
                                  kLkMinTarget,
                                  kLkMinTarget,
                                ),
                              ),
                              child: Text.rich(
                                TextSpan(
                                  text: 'Have an account? ',
                                  style: LkType.body.copyWith(
                                    color: Colors.white.withValues(alpha: 0.85),
                                  ),
                                  children: [
                                    TextSpan(
                                      text: 'Sign in',
                                      style: LkType.bodyStrong.copyWith(
                                        color: Colors.white,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 50dp on regular phones; smaller on narrow ones (360dp) so each line of
/// the headline stays whole.
double _heroSize(BuildContext context) {
  final w = MediaQuery.sizeOf(context).width;
  return w < 380 ? 42 : 50;
}

class _RouteLayer extends StatelessWidget {
  const _RouteLayer({required this.progress, required this.size});

  final Animation<double> progress;
  final Size size;

  @override
  Widget build(BuildContext context) {
    final from = Offset(size.width * 0.12, size.height * 0.78);
    final to = Offset(size.width * 0.8, size.height * 0.3);
    // Too little room for labels: draw the route only.
    final showPins = size.height >= 200;
    return AnimatedBuilder(
      animation: progress,
      builder: (context, _) {
        final t = Curves.easeInOutCubic.transform(progress.value);
        final pinsIn = ((progress.value - 0.7) / 0.3).clamp(0.0, 1.0);
        return Stack(
          children: [
            Positioned.fill(
              child: CustomPaint(painter: _RoutePainter(from, to, t)),
            ),
            if (showPins)
              Positioned(
                left: from.dx - 6,
                top: from.dy + 16,
                child: Opacity(
                  opacity: pinsIn,
                  child: const _Pin(title: 'Davao City', detail: 'Sasa Wharf'),
                ),
              ),
            if (showPins)
              Positioned(
                right: size.width * 0.05,
                top: (to.dy - 62).clamp(0.0, double.infinity),
                child: Opacity(
                  opacity: pinsIn,
                  child: const _Pin(
                    title: 'Samal Island',
                    detail: 'by ferry',
                    icon: Icons.directions_boat_filled_rounded,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _RoutePainter extends CustomPainter {
  _RoutePainter(this.from, this.to, this.t);

  final Offset from;
  final Offset to;
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(from.dx, from.dy)
      ..cubicTo(
        from.dx + (to.dx - from.dx) * 0.35,
        from.dy - 10,
        to.dx - (to.dx - from.dx) * 0.45,
        to.dy + 70,
        to.dx,
        to.dy,
      );
    final paint = Paint()
      ..color = LkColors.mango
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    for (final PathMetric m in path.computeMetrics()) {
      canvas.drawPath(m.extractPath(0, m.length * t), paint);
    }
    // Start: hollow ring. End: mango dot once the line arrives.
    canvas.drawCircle(
      from,
      7,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
    if (t > 0.98) {
      canvas.drawCircle(to, 8, Paint()..color = LkColors.mango);
      canvas.drawCircle(to, 3.5, Paint()..color = LkColors.mangoInk);
    }
  }

  @override
  bool shouldRepaint(covariant _RoutePainter old) => old.t != t;
}

class _Pin extends StatelessWidget {
  const _Pin({required this.title, required this.detail, this.icon});

  final String title;
  final String detail;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return LkGlass(
      dark: true,
      borderRadius: LkRadius.smAll,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 15, color: LkColors.mango),
            const SizedBox(width: 6),
          ],
          Text(title, style: LkType.label.copyWith(color: Colors.white)),
          const SizedBox(width: 6),
          Text(detail, style: LkType.micro.copyWith(color: LkColors.onPhotoMuted)),
        ],
      ),
    );
  }
}
