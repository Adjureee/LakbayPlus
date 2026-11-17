import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../core/theme/app_theme.dart';
import '../widgets/brand/lakbay_ai_avatar.dart';
import '../widgets/brand/lakbay_wordmark.dart';

/// Lakbay+ Brand Theme — Dark Cyan Teal & Cocoa Orange (from lakbay_monorepo).
class LakbayColors {
  // Primary Lakbay+ Teal
  static const Color primary = AppTheme.primaryBlue; // #20878E
  static const Color primaryDark = AppTheme.primaryDeep; // #16696F
  static const Color primaryLight = AppTheme.primaryWash; // #E3F1F2
  static const Color primarySoft = Color(0xFFF1F8F8);

  // Secondary Deep Teal & Cocoa Orange
  static const Color tealDeep = Color(0xFF0D2E32);
  static const Color tealAccent = AppTheme.accentTeal; // #178A90
  static const Color tealWash = AppTheme.primaryWash; // #E3F1F2

  // Accents & Neutrals
  static const Color cocoaOrange = AppTheme.secondaryGreen; // #D66F29
  static const Color canvasBg = AppTheme.backgroundLight; // #F5F9F9
  static const Color surfaceWhite = AppTheme.cardColorLight; // #FFFFFF
  static const Color cardBorder = AppTheme.outlineLight; // #CFDFDF
  static const Color textPrimary = AppTheme.textPrimaryLight; // #1A2E2E
  static const Color textSecondary = AppTheme.textSecondaryLight; // #4F6B6B
  static const Color textMuted = Color(0xFF6D8787);
  static const Color successGreen = AppTheme.success; // #2E7D4F

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

class LakbayTheme {
  static ThemeData get lightTheme {
    final textTheme = AppTheme.textTheme(
      LakbayColors.textPrimary,
      LakbayColors.textSecondary,
    );
    return ThemeData(
      useMaterial3: true,
      fontFamily: GoogleFonts.outfit().fontFamily,
      scaffoldBackgroundColor: LakbayColors.canvasBg,
      colorScheme: ColorScheme.fromSeed(
        seedColor: LakbayColors.primary,
        primary: LakbayColors.primary,
        secondary: LakbayColors.cocoaOrange,
        surface: LakbayColors.surfaceWhite,
      ),
      textTheme: textTheme,
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: LakbayColors.primaryDark,
          foregroundColor: Colors.white,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
          ),
          textStyle: GoogleFonts.outfit(
            fontWeight: FontWeight.w600,
            fontSize: 16,
          ),
        ),
      ),
    );
  }
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
