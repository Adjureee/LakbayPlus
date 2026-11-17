import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Lakbay+ admin theme, aligned with the traveler app's v8 look: deep teal
/// surfaces in dark mode, mango as the one action color, Bricolage Grotesque
/// for page titles and big numbers, Manrope for everything else.
///
/// The light theme stays for long data sessions. Text links there use a
/// darker teal, because mango text on white fails WCAG AA.
class AppTheme {
  // Brand (shared with the traveler app's LkColors).
  static const Color mango = Color(0xFFFFB547);
  static const Color mangoInk = Color(0xFF2A1900);
  static const Color lagoon = Color(0xFF2CC5BC);

  // Kept for screens that still name them.
  static const Color primaryColor = Color(0xFF20878E);
  static const Color secondaryColor = Color(0xFFD66F29);
  static const Color accentColor = Color(0xFF178A90);

  /// Teal for text links and focus on light surfaces (AA on white).
  static const Color actionPrimary = Color(0xFF19767D);
  static const Color actionSecondary = Color(0xFFA94F18);

  /// Links on dark surfaces.
  static const Color darkAccent = lagoon;
  static const Color mutedOnBackground = Color(0xFF5A7474);

  // Dark: the v8 surfaces.
  static const Color darkBg = Color(0xFF04191C);
  static const Color darkCardBg = Color(0xFF0A2A2F);
  static const Color darkSurface = Color(0xFF0F353B);
  static const Color darkBorder = Color(0xFF1F444A);
  static const Color darkTextPrimary = Color(0xFFEAF4F3);
  static const Color darkTextSecondary = Color(0xFF8FB0AD);

  static const Color lightBg = Color(0xFFF5F9F9);
  static const Color lightCardBg = Colors.white;
  static const Color lightSurface = Color(0xFFEEF5F5);
  static const Color lightBorder = Color(0xFFCFDFDF);
  static const Color lightTextPrimary = Color(0xFF1A2E2E);
  static const Color lightTextSecondary = Color(0xFF5C7878);

  static const Color success = Color(0xFF16734C);
  static const Color warning = Color(0xFF94600D);
  static const Color error = Color(0xFFB83F3F);

  /// Status colors that stay AA as text on either theme's cards.
  static Color positive(BuildContext context) =>
      _isDark(context) ? const Color(0xFF5FD39A) : success;
  static Color negative(BuildContext context) =>
      _isDark(context) ? const Color(0xFFFF8A82) : error;
  static Color caution(BuildContext context) =>
      _isDark(context) ? mango : warning;
  static bool _isDark(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark;

  static ThemeData get lightTheme => _build(Brightness.light);
  static ThemeData get darkTheme => _build(Brightness.dark);

  /// Bricolage Grotesque ExtraBold, for page titles and stat numbers.
  static TextStyle display({double size = 32, Color? color}) =>
      GoogleFonts.bricolageGrotesque(
        fontSize: size,
        fontWeight: FontWeight.w800,
        letterSpacing: -size * 0.025,
        height: 1.1,
        color: color,
      );

  static ThemeData _build(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final text = isDark ? darkTextPrimary : lightTextPrimary;
    final muted = isDark ? darkTextSecondary : mutedOnBackground;
    final surface = isDark ? darkCardBg : lightCardBg;
    final border = isDark ? darkBorder : lightBorder;
    final link = isDark ? darkAccent : actionPrimary;
    final scheme =
        ColorScheme.fromSeed(
          seedColor: primaryColor,
          brightness: brightness,
        ).copyWith(
          // Selection, focus and progress follow the action color in dark
          // mode and the AA-safe teal on white.
          primary: isDark ? mango : actionPrimary,
          onPrimary: isDark ? mangoInk : Colors.white,
          secondary: isDark ? lagoon : actionSecondary,
          onSecondary: isDark ? darkBg : Colors.white,
          tertiary: mango,
          onTertiary: mangoInk,
          surface: surface,
          onSurface: text,
          onSurfaceVariant: muted,
          outline: isDark ? const Color(0xFF5F8783) : const Color(0xFF789292),
          outlineVariant: border,
          error: isDark ? const Color(0xFFFF8A82) : error,
          surfaceContainerHighest: isDark ? darkSurface : lightSurface,
        );

    TextStyle ui(double size, FontWeight weight, {Color? color, double? h}) =>
        GoogleFonts.manrope(
          fontSize: size,
          fontWeight: weight,
          color: color ?? text,
          height: h,
        );

    final textTheme = TextTheme(
      displaySmall: display(size: 40, color: text),
      headlineLarge: display(size: 32, color: text),
      headlineMedium: display(size: 28, color: text),
      headlineSmall: display(size: 24, color: text),
      titleLarge: ui(18, FontWeight.w800, h: 1.4),
      titleMedium: ui(16, FontWeight.w700, h: 1.4),
      titleSmall: ui(14, FontWeight.w700, h: 1.4),
      bodyLarge: ui(16, FontWeight.w500, h: 1.5),
      bodyMedium: ui(14, FontWeight.w500, h: 1.55),
      bodySmall: ui(12, FontWeight.w500, color: muted, h: 1.5),
      labelLarge: ui(14, FontWeight.w700),
      labelMedium: ui(12, FontWeight.w700),
      labelSmall: ui(11, FontWeight.w700, color: muted),
    );
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
    );
    final actionButton = (
      bg: mango,
      fg: mangoInk,
    );
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      primaryColor: primaryColor,
      colorScheme: scheme,
      scaffoldBackgroundColor: isDark ? darkBg : lightBg,
      cardColor: surface,
      dividerColor: border,
      textTheme: textTheme,
      fontFamily: GoogleFonts.manrope().fontFamily,
      visualDensity: VisualDensity.standard,
      focusColor: mango.withValues(alpha: 0.28),
      hoverColor: (isDark ? Colors.white : Colors.black).withValues(
        alpha: 0.05,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: actionButton.bg,
          foregroundColor: actionButton.fg,
          minimumSize: const Size(44, 44),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          elevation: 0,
          shape: shape,
          textStyle: textTheme.labelLarge,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: actionButton.bg,
          foregroundColor: actionButton.fg,
          disabledBackgroundColor: actionButton.bg.withValues(alpha: 0.4),
          disabledForegroundColor: actionButton.fg.withValues(alpha: 0.6),
          minimumSize: const Size(44, 44),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          shape: shape,
          textStyle: textTheme.labelLarge,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: link,
          minimumSize: const Size(44, 44),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          side: BorderSide(color: scheme.outline),
          shape: shape,
          textStyle: textTheme.labelLarge,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: link,
          minimumSize: const Size(44, 44),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          shape: shape,
          textStyle: textTheme.labelLarge,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: const Size(44, 44),
          foregroundColor: muted,
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: isDark ? darkSurface : lightSurface,
        selectedColor: mango,
        labelStyle: textTheme.labelMedium,
        secondaryLabelStyle: textTheme.labelMedium?.copyWith(color: mangoInk),
        checkmarkColor: mangoInk,
        side: BorderSide(color: border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark ? darkSurface : const Color(0xFFF0F6F6),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        labelStyle: TextStyle(color: muted, fontSize: 14),
        hintStyle: TextStyle(color: muted, fontSize: 14),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: isDark ? mango : actionPrimary, width: 2),
        ),
      ),
      dataTableTheme: DataTableThemeData(
        headingRowHeight: 48,
        dataRowMinHeight: 56,
        dataRowMaxHeight: 88,
        headingRowColor: WidgetStatePropertyAll(
          isDark ? darkSurface : lightSurface,
        ),
        headingTextStyle: textTheme.titleSmall,
        dataTextStyle: textTheme.bodyMedium,
        dividerThickness: 1,
        horizontalMargin: 20,
        columnSpacing: 28,
      ),
      dividerTheme: DividerThemeData(color: border, space: 1, thickness: 1),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        titleTextStyle: textTheme.titleLarge,
        contentTextStyle: textTheme.bodyMedium,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: surface,
        surfaceTintColor: Colors.transparent,
        shape: shape,
        textStyle: textTheme.bodyMedium,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: isDark ? lagoon : actionPrimary,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: isDark ? darkSurface : lightTextPrimary,
        contentTextStyle: textTheme.bodyMedium?.copyWith(
          color: isDark ? darkTextPrimary : Colors.white,
        ),
        actionTextColor: mango,
      ),
    );
  }
}
