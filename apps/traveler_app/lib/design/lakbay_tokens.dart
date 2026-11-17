import 'package:flutter/widgets.dart';

/// Lakbay+ v8 color tokens: deep teal surfaces, mango actions, lagoon routes.
///
/// Reference: `.impeccable/mocks/v4/v8.html`. Every pair used for text is
/// WCAG AA (>= 4.5:1); see `test/design_system_test.dart`.
abstract final class LkColors {
  // Surfaces, darkest to lightest.
  static const Color bg = Color(0xFF04191C);
  static const Color s1 = Color(0xFF0A2A2F);
  static const Color s2 = Color(0xFF0F353B);
  static const Color s3 = Color(0xFF15434A);

  /// Hairlines and card borders (white at 9%).
  static const Color stroke = Color(0x17FFFFFF);

  /// Stronger outline for inputs and focused edges (white at 16%).
  static const Color strokeStrong = Color(0x29FFFFFF);

  // Text.
  static const Color text = Color(0xFFEAF4F3);
  static const Color muted = Color(0xFF8FB0AD);

  /// Decorative only (map labels, disabled). Not for readable body text.
  static const Color faint = Color(0xFF5F8783);

  // Brand.
  /// The single action color: primary buttons, active tab, user bubbles.
  static const Color mango = Color(0xFFFFB547);

  /// Text and icons on mango.
  static const Color mangoInk = Color(0xFF2A1900);

  /// Mango tint for warning rows and soft highlights.
  static const Color mangoSoft = Color(0x2EFFB547);

  /// Routes, progress, links.
  static const Color lagoon = Color(0xFF2CC5BC);
  static const Color lagoonSoft = Color(0x262CC5BC);

  // Status.
  static const Color danger = Color(0xFFFF6B61);
  static const Color live = Color(0xFFFF5A4F);

  // Budget categories (chat plan card, trip budget).
  static const Color budgetStay = lagoon;
  static const Color budgetFood = mango;
  static const Color budgetRides = Color(0xFF7FA8F0);
  static const Color budgetEntrance = Color(0xFFE58FB8);

  // Glass over photos.
  static const Color glassLight = Color(0x1AFFFFFF);
  static const Color glassLightBorder = Color(0x29FFFFFF);
  static const Color glassDark = Color(0x9E04191C);
  static const Color glassDarkBorder = Color(0x1FFFFFFF);

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
  static const List<BoxShadow> card = [
    BoxShadow(color: Color(0x80000000), blurRadius: 50, offset: Offset(0, 26)),
  ];
  static const List<BoxShadow> floating = [
    BoxShadow(color: Color(0x73000000), blurRadius: 40, offset: Offset(0, 18)),
  ];

  static List<BoxShadow> mangoGlow = [
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

  static LkMotion of(BuildContext context) =>
      LkMotion._(!(MediaQuery.maybeDisableAnimationsOf(context) ?? false));

  /// [d] when motion is allowed, otherwise [Duration.zero].
  Duration duration(Duration d) => enabled ? d : Duration.zero;
}
