import 'package:flutter/widgets.dart';

/// One complete set of Lakbay+ colors. There is a dark and a light palette;
/// [LkColors] always reads the active one.
class LkPalette {
  const LkPalette({
    required this.brightness,
    required this.bg,
    required this.s1,
    required this.s2,
    required this.s3,
    required this.stroke,
    required this.strokeStrong,
    required this.text,
    required this.muted,
    required this.faint,
    required this.mango,
    required this.mangoInk,
    required this.mangoText,
    required this.mangoSoft,
    required this.lagoon,
    required this.lagoonSoft,
    required this.danger,
    required this.live,
    required this.budgetRides,
    required this.budgetEntrance,
    required this.shadow,
  });

  final Brightness brightness;
  final Color bg, s1, s2, s3, stroke, strokeStrong;
  final Color text, muted, faint;
  final Color mango, mangoInk, mangoText, mangoSoft;
  final Color lagoon, lagoonSoft;
  final Color danger, live;
  final Color budgetRides, budgetEntrance;

  /// Card shadow color (heavy on dark, soft on light).
  final Color shadow;

  bool get isDark => brightness == Brightness.dark;

  /// Deep teal surfaces, mango actions, lagoon routes.
  static const LkPalette dark = LkPalette(
    brightness: Brightness.dark,
    bg: Color(0xFF04191C),
    s1: Color(0xFF0A2A2F),
    s2: Color(0xFF0F353B),
    s3: Color(0xFF15434A),
    stroke: Color(0x17FFFFFF),
    strokeStrong: Color(0x29FFFFFF),
    text: Color(0xFFEAF4F3),
    muted: Color(0xFF8FB0AD),
    faint: Color(0xFF5F8783),
    mango: Color(0xFFFFB547),
    mangoInk: Color(0xFF2A1900),
    mangoText: Color(0xFFFFB547),
    mangoSoft: Color(0x2EFFB547),
    lagoon: Color(0xFF2CC5BC),
    lagoonSoft: Color(0x262CC5BC),
    danger: Color(0xFFFF6B61),
    live: Color(0xFFFF5A4F),
    budgetRides: Color(0xFF7FA8F0),
    budgetEntrance: Color(0xFFE58FB8),
    shadow: Color(0x80000000),
  );

  /// Soft sea-glass surfaces, deep teal text, the same mango action.
  static const LkPalette light = LkPalette(
    brightness: Brightness.light,
    bg: Color(0xFFF3F8F7),
    s1: Color(0xFFFFFFFF),
    s2: Color(0xFFE8F1F0),
    s3: Color(0xFFD7E6E4),
    stroke: Color(0x1F04191C),
    strokeStrong: Color(0x66042A2F),
    text: Color(0xFF0A2A2F),
    muted: Color(0xFF486B68),
    faint: Color(0xFF8AA3A0),
    mango: Color(0xFFFFB547),
    mangoInk: Color(0xFF2A1900),
    mangoText: Color(0xFF8A5200),
    mangoSoft: Color(0x33FFB547),
    lagoon: Color(0xFF0A726D),
    lagoonSoft: Color(0x1F0A726D),
    danger: Color(0xFFC62F25),
    live: Color(0xFFD6342A),
    budgetRides: Color(0xFF3B6AC9),
    budgetEntrance: Color(0xFFB83E78),
    shadow: Color(0x2204191C),
  );
}

/// Lakbay+ v8 color tokens. Reads the active [LkPalette], so the same code
/// paints both the dark and the light app. Switch with [LkColors.use]; the
/// theme controller (see `lakbay_theme_controller.dart`) does this and
/// rebuilds the tree.
///
/// Reference: `.impeccable/mocks/v4/v8.html`. Every pair used for text is
/// WCAG AA (>= 4.5:1) in both palettes; see `test/design_system_test.dart`.
abstract final class LkColors {
  static LkPalette _p = LkPalette.dark;

  static LkPalette get palette => _p;
  static bool get isDark => _p.isDark;

  /// Make [p] the active palette.
  static void use(LkPalette p) => _p = p;

  // Surfaces, deepest to lightest in dark; page to raised in light.
  static Color get bg => _p.bg;
  static Color get s1 => _p.s1;
  static Color get s2 => _p.s2;
  static Color get s3 => _p.s3;

  /// Hairlines and card borders.
  static Color get stroke => _p.stroke;

  /// Stronger outline for inputs and focused edges.
  static Color get strokeStrong => _p.strokeStrong;

  // Text.
  static Color get text => _p.text;
  static Color get muted => _p.muted;

  /// Decorative only (map labels, disabled). Not for readable body text.
  static Color get faint => _p.faint;

  /// Text that sits on a photo or the dark glass over one. Light in both modes.
  static const Color onPhoto = Color(0xFFEAF4F3);
  static const Color onPhotoMuted = Color(0xFFC3D9D6);

  // Brand.
  /// The single action color: primary buttons, active tab, user bubbles.
  static Color get mango => _p.mango;

  /// Text and icons on mango.
  static Color get mangoInk => _p.mangoInk;

  /// Mango as text or an icon on a page surface (darker amber in light mode).
  static Color get mangoText => _p.mangoText;

  /// Mango tint for warning rows and soft highlights.
  static Color get mangoSoft => _p.mangoSoft;

  /// Routes, progress, links.
  static Color get lagoon => _p.lagoon;
  static Color get lagoonSoft => _p.lagoonSoft;

  // Status.
  static Color get danger => _p.danger;
  static Color get live => _p.live;

  // Budget categories (chat plan card, trip budget).
  static Color get budgetStay => _p.lagoon;
  static Color get budgetFood => _p.mango;
  static Color get budgetRides => _p.budgetRides;
  static Color get budgetEntrance => _p.budgetEntrance;

  // Glass over photos (the same in both modes: photos are always photos).
  static const Color glassLight = Color(0x1AFFFFFF);
  static const Color glassLightBorder = Color(0x29FFFFFF);
  static const Color glassDark = Color(0x9E04191C);
  static const Color glassDarkBorder = Color(0x1FFFFFFF);

  /// Raised panel (profile header, image placeholders).
  static LinearGradient get surfaceGradient => LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [_p.s2, _p.s1],
  );

  /// Bottom scrim that keeps white text readable on any photo.
  static const LinearGradient photoScrim = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0x00021114), Color(0x00021114), Color(0xEB021114)],
    stops: [0, 0.3, 1],
  );

  /// Full-screen hero scrim (welcome, trip header): dark top for the status
  /// bar, clear middle, solid bottom for copy.
  static const LinearGradient heroScrim = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [
      Color(0x8C021114),
      Color(0x00021114),
      Color(0x00021114),
      Color(0xD9021114),
      Color(0xFF021114),
    ],
    stops: [0, 0.2, 0.4, 0.63, 0.82],
  );
}

/// 4-pt spacing scale.
abstract final class LkSpace {
  static const double xxs = 4;
  static const double xs = 6;
  static const double s = 8;
  static const double m = 12;
  static const double l = 16;
  static const double xl = 20;
  static const double xxl = 24;
  static const double xxxl = 32;

  /// Side gutter for phone screens.
  static const double gutter = 20;
}

abstract final class LkRadius {
  static const double chip = 10;
  static const double sm = 14;
  static const double md = 20;
  static const double lg = 26;
  static const double sheet = 30;
  static const double pill = 999;

  static const BorderRadius chipAll = BorderRadius.all(Radius.circular(chip));
  static const BorderRadius smAll = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius mdAll = BorderRadius.all(Radius.circular(md));
  static const BorderRadius lgAll = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius sheetTop = BorderRadius.vertical(
    top: Radius.circular(sheet),
  );
}

abstract final class LkShadow {
  static List<BoxShadow> get card => [
    BoxShadow(
      color: LkColors.palette.shadow,
      blurRadius: 50,
      offset: const Offset(0, 26),
    ),
  ];
  static List<BoxShadow> get floating => [
    BoxShadow(
      color: LkColors.palette.shadow.withValues(
        alpha: LkColors.isDark ? 0.45 : 0.14,
      ),
      blurRadius: 40,
      offset: const Offset(0, 18),
    ),
  ];

  static List<BoxShadow> get mangoGlow => [
    BoxShadow(
      color: LkColors.mango.withValues(alpha: 0.3),
      blurRadius: 34,
      offset: const Offset(0, 14),
    ),
  ];
}

/// Minimum interactive size on Android (Material and WCAG 2.2 target size).
const double kLkMinTarget = 48;

/// Motion tokens. Always resolve durations through [LkMotion.of] so the
/// system "remove animations" setting turns motion off.
class LkMotion {
  const LkMotion._(this.enabled);

  final bool enabled;

  static const Duration fast = Duration(milliseconds: 150);
  static const Duration base = Duration(milliseconds: 240);
  static const Duration slow = Duration(milliseconds: 420);
  static const Duration rise = Duration(milliseconds: 700);
  static const Duration routeDraw = Duration(milliseconds: 2400);
  static const Duration pulse = Duration(milliseconds: 1800);

  static const Curve standard = Curves.easeOutCubic;
  static const Curve emphasized = Cubic(0.6, 0, 0.2, 1);

  /// App-wide switch. Widget tests turn it off (see
  /// `test/flutter_test_config.dart`) so screens render in their final state;
  /// motion tests turn it back on.
  static bool globallyEnabled = true;

  static LkMotion of(BuildContext context) => LkMotion._(
    globallyEnabled &&
        !(MediaQuery.maybeDisableAnimationsOf(context) ?? false),
  );

  /// [d] when motion is allowed, otherwise [Duration.zero].
  Duration duration(Duration d) => enabled ? d : Duration.zero;
}
