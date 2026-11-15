import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import 'lakbay_compass_mark.dart';

/// The Lakbay AI planner's avatar: the original compass mark in white on a
/// teal circle. Used beside assistant chat messages so the planner has a
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
      decoration: const BoxDecoration(
        color: AppTheme.primaryDeep,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: LakbayCompassMark(
        size: diameter * 0.6,
        primaryColor: Colors.white,
        secondaryColor: Colors.white70,
      ),
    );
  }
}
