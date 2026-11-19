import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import 'lakbay_compass_mark.dart';

/// The Lakbay AI planner's avatar: the Lakbay+ logo on a white circle. Used beside assistant chat messages so the planner has a
/// consistent, truthful identity — no real or implied human advisor.
class LakbayAiAvatar extends StatelessWidget {
  const LakbayAiAvatar({super.key, this.diameter = 32});

  final double diameter;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('lakbay-ai-avatar'),
      width: diameter,
      height: diameter,
      decoration: BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        border: Border.all(color: AppTheme.primaryDeep.withValues(alpha: 0.25)),
      ),
      alignment: Alignment.center,
      // The logo is wider than tall, so its height is about a third of the circle.
      child: LakbayCompassMark(size: diameter * 0.42),
    );
  }
}
