import 'dart:async';

import 'package:flutter/material.dart';

import '../lakbay_tokens.dart';

/// Content that fades in and rises a few pixels, as v8's "cards rise in".
/// Use [delay] to stagger a column of cards. With motion off it simply
/// shows the child.
class LkRiseIn extends StatefulWidget {
  const LkRiseIn({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.offset = 18,
    this.duration = LkMotion.slow,
    this.animate = true,
  });

  /// Delay for the [index]th item of a list: 60ms apart, capped so long lists
  /// never keep the reader waiting.
  static Duration stagger(int index, {int max = 6}) =>
      Duration(milliseconds: 60 * (index < max ? index : max));

  final Widget child;
  final Duration delay;
  final double offset;
  final Duration duration;

  /// False shows the child at once (e.g. a chat message the reader has
  /// already seen, rebuilt after scrolling back).
  final bool animate;

  @override
  State<LkRiseIn> createState() => _LkRiseInState();
}

class _LkRiseInState extends State<LkRiseIn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: widget.duration,
  );
  late final Animation<double> _t = CurvedAnimation(
    parent: _c,
    curve: LkMotion.standard,
  );
  Timer? _timer;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (!widget.animate || !LkMotion.of(context).enabled) {
      _c.value = 1;
    } else if (widget.delay == Duration.zero) {
      _c.forward();
    } else {
      _timer = Timer(widget.delay, () {
        if (mounted) _c.forward();
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _t,
      builder: (context, child) => Opacity(
        opacity: _t.value,
        child: Transform.translate(
          offset: Offset(0, widget.offset * (1 - _t.value)),
          child: child,
        ),
      ),
      child: widget.child,
    );
  }
}

/// A number that counts up to [value] when it first appears (the Trips
/// countdown, admin totals). Screen readers get the final value only.
class LkCountUp extends StatelessWidget {
  const LkCountUp({
    super.key,
    required this.value,
    required this.style,
    this.duration = const Duration(milliseconds: 900),
  });

  final int value;
  final TextStyle style;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    final motion = LkMotion.of(context);
    return Semantics(
      label: '$value',
      excludeSemantics: true,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: value.toDouble()),
        duration: motion.duration(duration),
        curve: LkMotion.standard,
        builder: (_, v, _) => Text('${v.round()}', style: style),
      ),
    );
  }
}

/// Shrinks its child slightly while pressed, for a tactile tap.
class LkPressScale extends StatefulWidget {
  const LkPressScale({super.key, required this.child, this.enabled = true});

  final Widget child;
  final bool enabled;

  @override
  State<LkPressScale> createState() => _LkPressScaleState();
}

class _LkPressScaleState extends State<LkPressScale> {
  bool _down = false;

  void _set(bool v) {
    if (_down != v && mounted) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    final motion = LkMotion.of(context);
    return Listener(
      onPointerDown: widget.enabled ? (_) => _set(true) : null,
      onPointerUp: (_) => _set(false),
      onPointerCancel: (_) => _set(false),
      child: AnimatedScale(
        scale: _down && motion.enabled ? 0.97 : 1,
        duration: motion.duration(LkMotion.fast),
        curve: LkMotion.standard,
        child: widget.child,
      ),
    );
  }
}
