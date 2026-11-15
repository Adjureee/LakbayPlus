import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../core/theme/app_theme.dart';
import '../widgets/brand/lakbay_ai_avatar.dart';
import '../widgets/brand/lakbay_compass_mark.dart';

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

/// Lakbay+ Compass Avatar — renders the official eight-point compass rose.
class LakbayAvatar extends StatelessWidget {
  final double size;
  final bool inverted;

  const LakbayAvatar({
    super.key,
    this.size = 40,
    this.inverted = false,
  });

  @override
  Widget build(BuildContext context) {
    if (!inverted) {
      return LakbayAiAvatar(diameter: size);
    }
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white,
        border: Border.all(color: LakbayColors.cardBorder),
      ),
      alignment: Alignment.center,
      child: LakbayCompassMark(
        size: size * 0.62,
        primaryColor: LakbayColors.primary,
        secondaryColor: LakbayColors.primary.withValues(alpha: 0.45),
      ),
    );
  }
}

/// Official Lakbay+ Wordmark pairing the eight-point compass mark with Outfit typography.
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
    final textColor = lightText ? Colors.white : LakbayColors.primaryDark;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        LakbayCompassMark(
          size: fontSize * 1.15,
          primaryColor: lightText ? Colors.white : LakbayColors.primary,
          secondaryColor: lightText
              ? Colors.white70
              : LakbayColors.primary.withValues(alpha: 0.45),
        ),
        const SizedBox(width: 10),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text.rich(
              TextSpan(
                style: GoogleFonts.outfit(
                  fontWeight: FontWeight.w800,
                  fontSize: fontSize,
                  letterSpacing: -0.5,
                  color: textColor,
                ),
                children: [
                  const TextSpan(text: 'Lakbay'),
                  TextSpan(
                    text: '+',
                    style: TextStyle(color: LakbayColors.cocoaOrange),
                  ),
                ],
              ),
            ),
            if (showTagline)
              Text(
                'Davao Region AI Travel Planner',
                style: GoogleFonts.outfit(
                  fontSize: fontSize * 0.46,
                  color: lightText
                      ? Colors.white.withValues(alpha: 0.85)
                      : LakbayColors.textSecondary,
                ),
              ),
          ],
        ),
      ],
    );
  }
}
