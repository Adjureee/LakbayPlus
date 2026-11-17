import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../design/lakbay_tokens.dart';

/// The Lakbay+ wordmark: the name alone, set in Bricolage Grotesque, with the
/// "+" in mango. There is no symbol or mark; the old compass/star mark was
/// retired because it read as a generic AI sparkle.
class LakbayWordmark extends StatelessWidget {
  const LakbayWordmark({
    super.key,
    this.fontSize = 24,
    this.color,
    this.plusColor,
  });

  final double fontSize;

  /// Color of "Lakbay". Defaults to white: every Lakbay+ surface is dark
  /// (v8). Pass a dark color to place it on a light surface.
  final Color? color;

  /// Color of "+". Defaults to mango, or a darker amber on light backgrounds
  /// where mango would be too faint.
  final Color? plusColor;

  /// Darker amber for the "+" on light surfaces (mango fails contrast there).
  static const Color amberOnLight = Color(0xFFB4690E);

  @override
  Widget build(BuildContext context) {
    final textColor = color ?? Colors.white;
    final onDark = textColor.computeLuminance() > 0.5;
    return Semantics(
      label: 'Lakbay+',
      excludeSemantics: true,
      child: Text.rich(
        TextSpan(
          style: GoogleFonts.bricolageGrotesque(
            fontSize: fontSize,
            fontWeight: FontWeight.w800,
            letterSpacing: -fontSize * 0.025,
            height: 1.1,
            color: textColor,
          ),
          children: [
            const TextSpan(text: 'Lakbay'),
            TextSpan(
              text: '+',
              style: TextStyle(
                color: plusColor ?? (onDark ? LkColors.mango : amberOnLight),
              ),
            ),
          ],
        ),
        maxLines: 1,
        softWrap: false,
      ),
    );
  }
}
