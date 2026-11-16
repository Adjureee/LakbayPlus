import 'package:flutter/material.dart';

/// Timing and curves for every animation in the app, in one place.
///
/// Rules: 150 to 350 ms, never over 400; things entering decelerate, things
/// leaving accelerate; and with Android's "Remove animations" on, nothing
/// animates at all.
class LakbayMotion {
  LakbayMotion._();

  static const Duration quick = Duration(milliseconds: 160);
  static const Duration standard = Duration(milliseconds: 220);
  static const Duration page = Duration(milliseconds: 300);
  static const Duration container = Duration(milliseconds: 350);
  static const Duration stagger = Duration(milliseconds: 60);

  static const Curve enter = Curves.easeOutCubic;
  static const Curve exit = Curves.easeInCubic;

  /// True when the traveler asked the phone to remove animations.
  static bool reduced(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context);

  /// [value], or zero when animations are off.
  static Duration of(BuildContext context, Duration value) =>
      reduced(context) ? Duration.zero : value;
}

/// Fades and rises a freshly added item into place, once, after an optional
/// delay (used to stagger a message, then its cards, in a readable order).
class LakbayEntrance extends StatefulWidget {
  final Widget child;
  final Duration delay;

  const LakbayEntrance({
    super.key,
    required this.child,
    this.delay = Duration.zero,
  });

  @override
  State<LakbayEntrance> createState() => _LakbayEntranceState();
}

class _LakbayEntranceState extends State<LakbayEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: LakbayMotion.standard,
  );
  late final Animation<double> _curve = CurvedAnimation(
    parent: _controller,
    curve: LakbayMotion.enter,
  );
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (LakbayMotion.reduced(context)) {
      _controller.value = 1;
      return;
    }
    if (widget.delay == Duration.zero) {
      _controller.forward();
    } else {
      Future<void>.delayed(widget.delay, () {
        if (mounted) _controller.forward();
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _curve,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.04),
          end: Offset.zero,
        ).animate(_curve),
        child: widget.child,
      ),
    );
  }
}

/// An IndexedStack whose newly shown page fades in (a fade-through
/// between sibling tabs: no direction is implied, because tabs are not
/// parent and child). All pages stay alive, as before.
class FadeThroughIndexedStack extends StatefulWidget {
  final int index;
  final List<Widget> children;

  const FadeThroughIndexedStack({
    super.key,
    required this.index,
    required this.children,
  });

  @override
  State<FadeThroughIndexedStack> createState() =>
      _FadeThroughIndexedStackState();
}

class _FadeThroughIndexedStackState extends State<FadeThroughIndexedStack>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: LakbayMotion.quick + const Duration(milliseconds: 40),
    value: 1,
  );
  late final Animation<double> _curve = CurvedAnimation(
    parent: _controller,
    curve: LakbayMotion.enter,
  );

  @override
  void didUpdateWidget(covariant FadeThroughIndexedStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index && !LakbayMotion.reduced(context)) {
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Opacity only: a scale as well forces a second full-screen layer, which
    // cost frames on the phone while the heavy pages are on screen.
    return FadeTransition(
      opacity: Tween<double>(begin: 0.0, end: 1.0).animate(_curve),
      child: IndexedStack(index: widget.index, children: widget.children),
    );
  }
}
