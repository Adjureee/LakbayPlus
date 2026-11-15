import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppTheme {
  // Canonical Lakbay+ Brand Palette
  static const Color primaryBlue = Color(0xFF20878E); // Dark Cyan (primary)
  static const Color secondaryGreen = Color(0xFFD66F29); // Cocoa Orange (secondary)
  static const Color accentTeal = Color(0xFF178A90);
  static const Color backgroundLight = Color(0xFFF5F9F9);
  static const Color cardColorLight = Colors.white;
  static const Color textPrimaryLight = Color(0xFF1A2E2E);
  static const Color textSecondaryLight = Color(0xFF4F6B6B);

  static const Color backgroundDark = Color(0xFF0D1F1F);
  static const Color cardColorDark = Color(0xFF163030);
  static const Color textPrimaryDark = Color(0xFFF0F7F7);
  static const Color textSecondaryDark = Color(0xFF8AADAD);

  static const Color primaryDeep = Color(0xFF16696F);
  static const Color primaryWash = Color(0xFFE3F1F2);
  static const Color warning = Color(0xFFB26A00);
  static const Color success = Color(0xFF2E7D4F);
  static const Color outlineLight = Color(0xFFCFDFDF);
  static const Color outlineDark = Color(0xFF2B4848);
  static const Color onPrimary = Colors.white;

  static TextTheme textTheme(Color primary, Color secondary) {
    return GoogleFonts.outfitTextTheme(
      TextTheme(
        displayLarge: TextStyle(
          fontSize: 32,
          height: 1.15,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.6,
          color: primary,
        ),
        displayMedium: TextStyle(
          fontSize: 28,
          height: 1.18,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.5,
          color: primary,
        ),
        headlineMedium: TextStyle(
          fontSize: 22,
          height: 1.25,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.2,
          color: primary,
        ),
        titleLarge: TextStyle(
          fontSize: 18,
          height: 1.3,
          fontWeight: FontWeight.w600,
          color: primary,
        ),
        titleMedium: TextStyle(
          fontSize: 16,
          height: 1.35,
          fontWeight: FontWeight.w600,
          color: primary,
        ),
        bodyLarge: TextStyle(
          fontSize: 15,
          height: 1.45,
          color: primary,
        ),
        bodyMedium: TextStyle(
          fontSize: 14,
          height: 1.45,
          color: secondary,
        ),
      ),
    );
  }
}
