import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../widgets/brand/lakbay_ai_avatar.dart';
import '../widgets/brand/lakbay_wordmark.dart';

/// Legacy light palette. Only the Mapbox widget's markers still use it (they
/// sit on the light map style); screens use `LkColors` from `design/`.
class LakbayColors {
  // Primary Lakbay+ Teal
  static const Color primary = Color(0xFF20878E); // #20878E
  static const Color primaryDark = Color(0xFF16696F); // #16696F
  static const Color primaryLight = Color(0xFFE3F1F2); // #E3F1F2
  static const Color primarySoft = Color(0xFFF1F8F8);

  // Secondary Deep Teal & Cocoa Orange
  static const Color tealDeep = Color(0xFF0D2E32);
  static const Color tealAccent = Color(0xFF178A90); // #178A90
  static const Color tealWash = Color(0xFFE3F1F2); // #E3F1F2

  // Accents & Neutrals
  static const Color cocoaOrange = Color(0xFFD66F29); // #D66F29
  static const Color canvasBg = Color(0xFFF5F9F9); // #F5F9F9
  static const Color surfaceWhite = Color(0xFFFFFFFF); // #FFFFFF
  static const Color cardBorder = Color(0xFFCFDFDF); // #CFDFDF
  static const Color textPrimary = Color(0xFF1A2E2E); // #1A2E2E
  static const Color textSecondary = Color(0xFF4F6B6B); // #4F6B6B
  static const Color textMuted = Color(0xFF6D8787);
  static const Color successGreen = Color(0xFF2E7D4F); // #2E7D4F

  static const LinearGradient brandGradient = LinearGradient(
    colors: [Color(0xFF20878E), Color(0xFF178A90)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient deepTealGradient = LinearGradient(
    colors: [Color(0xFF0D2E32), Color(0xFF16696F)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient darkOverlayGradient = LinearGradient(
    colors: [
      Color(0x880D1F1F),
      Color(0x220D1F1F),
      Color(0xCC0D1F1F),
    ],
    stops: [0.0, 0.45, 1.0],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );
}

/// Lakbay AI's avatar ("L+" tile). [inverted] is kept for older call sites
/// and has no effect: there is one avatar.
class LakbayAvatar extends StatelessWidget {
  final double size;
  final bool inverted;

  const LakbayAvatar({
    super.key,
    this.size = 40,
    this.inverted = false,
  });

  @override
  Widget build(BuildContext context) => LakbayAiAvatar(diameter: size);
}

/// The Lakbay+ wordmark (name only, no symbol), with an optional tagline.
class LakbayBrandWordmark extends StatelessWidget {
  final double fontSize;
  final bool lightText;
  final bool showTagline;

  const LakbayBrandWordmark({
    super.key,
    this.fontSize = 24,
    this.lightText = false,
    this.showTagline = false,
  });

  @override
  Widget build(BuildContext context) {
    final wordmark = LakbayWordmark(
      fontSize: fontSize,
      color: lightText ? Colors.white : LakbayColors.tealDeep,
    );
    if (!showTagline) return wordmark;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        wordmark,
        const SizedBox(height: 4),
        Text(
          'Davao Region AI travel planner',
          style: GoogleFonts.manrope(
            fontSize: fontSize * 0.44,
            fontWeight: FontWeight.w600,
            color: lightText
                ? Colors.white.withValues(alpha: 0.85)
                : LakbayColors.textSecondary,
          ),
        ),
      ],
    );
  }
}
