import 'dart:async';

import 'package:flutter/material.dart';

/// Admin motion, matching the traveler app: content rises in, numbers count
/// up. Off under the system "remove animations" setting and in widget tests.
abstract final class AdminMotion {
  static bool enabled = true;

  static bool of(BuildContext context) =>
      enabled && !(MediaQuery.maybeDisableAnimationsOf(context) ?? false);

  static Duration stagger(int index) =>
      Duration(milliseconds: 60 * (index < 6 ? index : 6));
}

class AdminRiseIn extends StatefulWidget {
  const AdminRiseIn({
    super.key,
    required this.child,
    this.delay = Duration.zero,
  });

  final Widget child;
  final Duration delay;

  @override
  State<AdminRiseIn> createState() => _AdminRiseInState();
}

class _AdminRiseInState extends State<AdminRiseIn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );
  late final Animation<double> _t = CurvedAnimation(
    parent: _c,
    curve: Curves.easeOutCubic,
  );
  Timer? _timer;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (!AdminMotion.of(context)) {
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
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _t,
    builder: (context, child) => Opacity(
      opacity: _t.value,
      child: Transform.translate(
        offset: Offset(0, 16 * (1 - _t.value)),
        child: child,
      ),
    ),
    child: widget.child,
  );
}

/// Counts up to [value] the first time it shows.
class AdminCountUp extends StatelessWidget {
  const AdminCountUp({super.key, required this.value, required this.style});

  final int value;
  final TextStyle style;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: value.toDouble()),
    duration: AdminMotion.of(context)
        ? const Duration(milliseconds: 900)
        : Duration.zero,
    curve: Curves.easeOutCubic,
    builder: (_, v, _) => Text('${v.round()}', style: style),
  );
}
