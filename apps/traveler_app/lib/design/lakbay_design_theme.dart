import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'lakbay_tokens.dart';
import 'lakbay_type.dart';

/// The v8 Material 3 theme. Screens rebuilt in Phase 4 run under this theme;
/// it becomes the app-wide theme once every screen has moved over.
abstract final class LakbayDesignTheme {
  static ColorScheme get colorScheme => ColorScheme(
    brightness: LkColors.palette.brightness,
    primary: LkColors.mango,
    onPrimary: LkColors.mangoInk,
    primaryContainer: LkColors.mangoSoft,
    onPrimaryContainer: LkColors.mango,
    secondary: LkColors.lagoon,
    onSecondary: LkColors.isDark ? LkColors.bg : Colors.white,
    secondaryContainer: LkColors.lagoonSoft,
    onSecondaryContainer: LkColors.lagoon,
    tertiary: LkColors.budgetRides,
    onTertiary: LkColors.isDark ? LkColors.bg : Colors.white,
    error: LkColors.danger,
    onError: LkColors.isDark ? LkColors.bg : Colors.white,
    surface: LkColors.bg,
    onSurface: LkColors.text,
    onSurfaceVariant: LkColors.muted,
    surfaceContainerLowest: LkColors.bg,
    surfaceContainerLow: LkColors.s1,
    surfaceContainer: LkColors.s1,
    surfaceContainerHigh: LkColors.s2,
    surfaceContainerHighest: LkColors.s3,
    outline: LkColors.strokeStrong,
    outlineVariant: LkColors.stroke,
    inverseSurface: LkColors.text,
    onInverseSurface: LkColors.bg,
    inversePrimary: LkColors.mangoInk,
    shadow: Colors.black,
    scrim: Colors.black,
  );

  /// The dark theme (deep teal).
  static ThemeData get dark => _build(LkPalette.dark);

  /// The light theme (sea glass).
  static ThemeData get light => _build(LkPalette.light);

  static ThemeData of(Brightness b) => b == Brightness.dark ? dark : light;

  // The token getters read the active palette, so make [p] active while the
  // theme is built, then put the previous one back.
  static ThemeData _build(LkPalette p) {
    final previous = LkColors.palette;
    LkColors.use(p);
    try {
      return _theme();
    } finally {
      LkColors.use(previous);
    }
  }

  static ThemeData _theme() {
    final text = LkType.textTheme();
    const roundedSm = RoundedRectangleBorder(borderRadius: LkRadius.smAll);
    const roundedMd = RoundedRectangleBorder(borderRadius: LkRadius.mdAll);
    final buttonShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(18),
    );
    const minButton = Size(64, kLkMinTarget);

    OutlineInputBorder inputBorder(Color color, [double width = 1]) =>
        OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: color, width: width),
        );

    return ThemeData(
      useMaterial3: true,
      brightness: LkColors.palette.brightness,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: LkColors.bg,
      canvasColor: LkColors.bg,
      textTheme: text,
      primaryTextTheme: text,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      visualDensity: VisualDensity.standard,
      splashFactory: InkSparkle.splashFactory,
      // Visible keyboard focus and hover in Chrome (WCAG 2.4.7).
      focusColor: LkColors.mango.withValues(alpha: 0.28),
      hoverColor: LkColors.text.withValues(alpha: 0.06),
      dividerTheme: DividerThemeData(
        color: LkColors.stroke,
        thickness: 1,
        space: 1,
      ),
      iconTheme: IconThemeData(color: LkColors.text, size: 22),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        foregroundColor: LkColors.text,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: LkType.title,
        systemOverlayStyle: LkColors.isDark
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: LkColors.mango,
          foregroundColor: LkColors.mangoInk,
          disabledBackgroundColor: LkColors.s2,
          disabledForegroundColor: LkColors.faint,
          minimumSize: minButton,
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
          shape: buttonShape,
          textStyle: LkType.button,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: LkColors.mango,
          foregroundColor: LkColors.mangoInk,
          elevation: 0,
          minimumSize: minButton,
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
          shape: buttonShape,
          textStyle: LkType.button,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: LkColors.text,
          backgroundColor: LkColors.s2,
          side: BorderSide(color: LkColors.stroke),
          minimumSize: minButton,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          shape: buttonShape,
          textStyle: LkType.button,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: LkColors.lagoon,
          minimumSize: minButton,
          textStyle: LkType.label,
          shape: roundedSm,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: LkColors.text,
          minimumSize: const Size.square(kLkMinTarget),
          shape: roundedSm,
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: LkColors.mango,
        foregroundColor: LkColors.mangoInk,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: LkRadius.mdAll),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: LkColors.s1,
        hintStyle: LkType.body.copyWith(color: LkColors.muted),
        labelStyle: LkType.label.copyWith(color: LkColors.muted),
        floatingLabelStyle: LkType.label.copyWith(color: LkColors.mangoText),
        helperStyle: LkType.caption,
        errorStyle: LkType.caption.copyWith(color: LkColors.danger),
        prefixIconColor: LkColors.muted,
        suffixIconColor: LkColors.muted,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 16,
        ),
        border: inputBorder(LkColors.stroke),
        enabledBorder: inputBorder(LkColors.stroke),
        focusedBorder: inputBorder(LkColors.mango, 1.5),
        errorBorder: inputBorder(LkColors.danger),
        focusedErrorBorder: inputBorder(LkColors.danger, 1.5),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: LkColors.s1,
        selectedColor: LkColors.mango,
        disabledColor: LkColors.s1,
        labelStyle: LkType.label,
        secondaryLabelStyle: LkType.label.copyWith(color: LkColors.mangoInk),
        side: BorderSide(color: LkColors.stroke),
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        checkmarkColor: LkColors.mangoInk,
        iconTheme: IconThemeData(color: LkColors.lagoon, size: 16),
      ),
      cardTheme: CardThemeData(
        color: LkColors.s1,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: LkRadius.mdAll,
          side: BorderSide(color: LkColors.stroke),
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: LkColors.muted,
        textColor: LkColors.text,
        titleTextStyle: LkType.itemTitle,
        subtitleTextStyle: LkType.caption,
        minVerticalPadding: 12,
        shape: roundedMd,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: LkColors.s1,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: LkColors.s1,
        showDragHandle: true,
        dragHandleColor: LkColors.s3,
        shape: RoundedRectangleBorder(borderRadius: LkRadius.sheetTop),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: LkColors.s1,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(borderRadius: LkRadius.lgAll),
        titleTextStyle: LkType.h3,
        contentTextStyle: LkType.body.copyWith(color: LkColors.muted),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: LkColors.s3,
        contentTextStyle: LkType.bodyStrong,
        actionTextColor: LkColors.mango,
        shape: const RoundedRectangleBorder(borderRadius: LkRadius.smAll),
        insetPadding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: LkColors.lagoon,
        linearTrackColor: LkColors.s3,
        circularTrackColor: LkColors.s3,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? LkColors.mangoInk
              : LkColors.muted,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) =>
              s.contains(WidgetState.selected) ? LkColors.mango : LkColors.s3,
        ),
        trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? LkColors.lagoon
              : Colors.transparent,
        ),
        checkColor: WidgetStatePropertyAll(LkColors.bg),
        side: BorderSide(color: LkColors.muted, width: 1.5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: LkColors.s3,
          borderRadius: BorderRadius.circular(10),
        ),
        textStyle: LkType.label,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: Colors.transparent,
        indicatorColor: LkColors.mango,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (s) => LkType.micro.copyWith(
            color: s.contains(WidgetState.selected)
                ? LkColors.text
                : LkColors.muted,
          ),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (s) => IconThemeData(
            color: s.contains(WidgetState.selected)
                ? LkColors.mangoInk
                : LkColors.muted,
          ),
        ),
      ),
      pageTransitionsTheme: PageTransitionsTheme(
        builders: {
          for (final platform in TargetPlatform.values)
            platform: const FadeForwardsPageTransitionsBuilder(),
        },
      ),
    );
  }
}
