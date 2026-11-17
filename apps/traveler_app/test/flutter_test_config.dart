import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lakbay_travel/design/lakbay_theme_controller.dart';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:lakbay_travel/design/lakbay_tokens.dart';
import 'package:lakbay_travel/widgets/lakbay_intro.dart';

/// Runs before every test file. Loads the bundled v8 fonts (Manrope,
/// Bricolage Grotesque) once up front, so no test sees a font finish
/// loading mid-test (which schedules a relayout after the test ends).
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Screens render in their final state; motion tests switch this back on.
  LkMotion.globallyEnabled = false;
  LakbayIntro.enabled = false;
  // Dark unless a run asks for light (LK_THEME=light): tests need a fixed look,
  // whatever the machine's own setting is.
  SharedPreferences.setMockInitialValues({
    'lakbay_theme_mode': Platform.environment['LK_THEME'] == 'light'
        ? ThemeMode.light.name
        : ThemeMode.dark.name,
  });
  await LkThemeController.instance.load();
  for (final weight in const [
    FontWeight.w400,
    FontWeight.w500,
    FontWeight.w600,
    FontWeight.w700,
    FontWeight.w800,
  ]) {
    GoogleFonts.manrope(fontWeight: weight);
  }
  GoogleFonts.bricolageGrotesque(fontWeight: FontWeight.w800);
  await GoogleFonts.pendingFonts();
  // LkType.displayFamily is a pubspec font; widget tests only get those when
  // they are loaded by hand.
  final display = FontLoader('LakbayDisplay')
    ..addFont(rootBundle.load(
      'assets/google_fonts/BricolageGrotesque-ExtraBold.ttf',
    ));
  await display.load();
  await testMain();
}
