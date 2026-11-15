import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/theme/app_theme.dart';
import 'lakbay_compass_mark.dart';

/// The Lakbay+ wordmark: the original compass mark beside the name, with the
/// "+" picked out in the brand's secondary color. Original type treatment —
/// no copied logo file or third-party font.
class LakbayWordmark extends StatelessWidget {
  const LakbayWordmark({
    super.key,
    this.markSize = 26,
    this.fontSize = 20,
    this.color,
    this.compact = false,
  });

  final double markSize;
  final double fontSize;
  final Color? color;

  /// When true, shows only the mark — for tight spaces such as a collapsed
  /// nav rail or a favicon-sized slot.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = color ?? (isDark ? Colors.white : AppTheme.primaryDeep);
    final mark = LakbayCompassMark(size: markSize, primaryColor: textColor);
    if (compact) return mark;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        mark,
        const SizedBox(width: 8),
        Text.rich(
          TextSpan(
            style: GoogleFonts.outfit(
              fontSize: fontSize,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.3,
              color: textColor,
            ),
            children: [
              const TextSpan(text: 'Lakbay'),
              TextSpan(
                text: '+',
                style: TextStyle(color: AppTheme.secondaryGreen),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
