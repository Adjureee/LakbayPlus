import 'package:flutter/material.dart';

import '../lakbay_tokens.dart';
import '../lakbay_type.dart';
import 'lk_buttons.dart';

/// Nothing here yet: icon, one-line title, short help, one action.
class LkEmptyState extends StatelessWidget {
  const LkEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: LkSpace.xxl,
        vertical: LkSpace.xxxl,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: LkColors.s2,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: LkColors.stroke),
            ),
            child: Icon(icon, color: LkColors.lagoon, size: 30),
          ),
          const SizedBox(height: LkSpace.l),
          Semantics(
            header: true,
            child: Text(title, style: LkType.h3, textAlign: TextAlign.center),
          ),
          const SizedBox(height: LkSpace.s),
          Text(
            message,
            style: LkType.body.copyWith(color: LkColors.muted),
            textAlign: TextAlign.center,
          ),
          if (actionLabel != null) ...[
            const SizedBox(height: LkSpace.xl),
            LkButton(label: actionLabel!, onPressed: onAction),
          ],
        ],
      ),
    );
  }
}

/// Something failed: plain-language message and a retry.
class LkErrorState extends StatelessWidget {
  const LkErrorState({
    super.key,
    required this.message,
    this.title = "Couldn't load this",
    this.onRetry,
    this.offline = false,
  });

  final String title;
  final String message;
  final VoidCallback? onRetry;
  final bool offline;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: LkEmptyState(
        icon: offline ? Icons.wifi_off_rounded : Icons.error_outline_rounded,
        title: offline ? "You're offline" : title,
        message: message,
        actionLabel: onRetry == null ? null : 'Try again',
        onAction: onRetry,
      ),
    );
  }
}

/// Loading placeholder block with a slow shimmer (static when animations
/// are turned off).
class LkSkeleton extends StatefulWidget {
  const LkSkeleton({
    super.key,
    this.width,
    required this.height,
    this.borderRadius = LkRadius.smAll,
  });

  final double? width;
  final double height;
  final BorderRadius borderRadius;

  @override
  State<LkSkeleton> createState() => _LkSkeletonState();
}

class _LkSkeletonState extends State<LkSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (LkMotion.of(context).enabled) {
      if (!_controller.isAnimating) _controller.repeat();
    } else {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final t = _controller.value * 2 - 0.5;
          return Container(
            width: widget.width,
            height: widget.height,
            decoration: BoxDecoration(
              borderRadius: widget.borderRadius,
              gradient: LinearGradient(
                begin: Alignment(-1 + t * 2, 0),
                end: Alignment(t * 2, 0),
                colors: [LkColors.s1, LkColors.s2, LkColors.s1],
              ),
            ),
          );
        },
      ),
    );
  }
}
