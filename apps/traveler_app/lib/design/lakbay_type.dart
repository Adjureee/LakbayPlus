import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'lakbay_tokens.dart';

/// Lakbay+ v8 type: Bricolage Grotesque for display and big numbers,
/// Manrope for everything people read and tap.
abstract final class LkType {
  static const List<FontFeature> _tabular = [FontFeature.tabularFigures()];

  /// Bricolage Grotesque ExtraBold, declared in pubspec so it can be used in
  /// `const TextStyle(fontFamily: LkType.displayFamily)`.
  static const String displayFamily = 'LakbayDisplay';

  static TextStyle _display(double size, double height, double tracking) =>
      GoogleFonts.bricolageGrotesque(
        fontSize: size,
        height: height,
        letterSpacing: tracking,
        fontWeight: FontWeight.w800,
        color: LkColors.text,
      );

  static TextStyle _ui(
    double size,
    FontWeight weight, {
    double height = 1.35,
    Color color = LkColors.text,
  }) => GoogleFonts.manrope(
    fontSize: size,
    height: height,
    fontWeight: weight,
    color: color,
  );

  /// Countdown number on Trips home ("5").
  static TextStyle get countdown => _display(
    128,
    0.8,
    -6,
  ).copyWith(color: LkColors.mango, fontFeatures: _tabular);

  /// Welcome headline.
  static TextStyle get hero => _display(50, 0.98, -1.4);

  /// Screen titles.
  static TextStyle get h1 => _display(32, 1.05, -1);

  /// Card titles on photos, trip names.
  static TextStyle get h2 => _display(25, 1.05, -0.7);

  /// Next-stop name, plan card title.
  static TextStyle get h3 => _display(22, 1.05, -0.5);

  /// Section headers ("Explore Region XI").
  static TextStyle get section => _display(18, 1.2, -0.3);

  /// Big tabular numbers (ETA, price totals).
  static TextStyle get metric =>
      _display(30, 1, -1).copyWith(fontFeatures: _tabular);

  static TextStyle get bodyLarge => _ui(15.5, FontWeight.w500, height: 1.5);
  static TextStyle get body => _ui(14.5, FontWeight.w500, height: 1.5);
  static TextStyle get bodyStrong => _ui(14.5, FontWeight.w700, height: 1.45);
  static TextStyle get title => _ui(17, FontWeight.w800, height: 1.25);
  static TextStyle get itemTitle => _ui(15, FontWeight.w800, height: 1.3);
  static TextStyle get button => _ui(16, FontWeight.w800, height: 1.2);
  static TextStyle get label => _ui(13, FontWeight.w700, height: 1.3);
  static TextStyle get caption =>
      _ui(12.5, FontWeight.w600, height: 1.35, color: LkColors.muted);
  static TextStyle get micro =>
      _ui(11, FontWeight.w700, height: 1.3, color: LkColors.muted);

  /// Prices and times in lists.
  static TextStyle get numeric =>
      _ui(14, FontWeight.w800).copyWith(fontFeatures: _tabular);

  static TextTheme textTheme() {
    return TextTheme(
      displayLarge: hero,
      displayMedium: _display(40, 1, -1.2),
      displaySmall: h1,
      headlineLarge: h1,
      headlineMedium: h2,
      headlineSmall: h3,
      titleLarge: section,
      titleMedium: title,
      titleSmall: itemTitle,
      bodyLarge: bodyLarge,
      bodyMedium: body,
      bodySmall: caption,
      labelLarge: button,
      labelMedium: label,
      labelSmall: micro,
    );
  }
}
