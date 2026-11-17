import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_theme.dart';

/// The Lakbay+ wordmark, as in the traveler app: "Lakbay" in Bricolage
/// Grotesque with a mango "+". On light surfaces the "+" uses a darker amber,
/// because mango is too faint on white.
class LakbayWordmark extends StatelessWidget {
  const LakbayWordmark({super.key, this.fontSize = 24, this.color});

  final double fontSize;

  /// Color of "Lakbay"; defaults to the theme's text color.
  final Color? color;

  static const Color amberOnLight = Color(0xFFB4690E);

  @override
  Widget build(BuildContext context) {
    final textColor = color ?? Theme.of(context).colorScheme.onSurface;
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
                color: onDark ? AppTheme.mango : amberOnLight,
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
