import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

/// Runs before every test file. Loads the bundled v8 fonts (Manrope,
/// Bricolage Grotesque) once up front, so no test sees a font finish
/// loading mid-test (which schedules a relayout after the test ends).
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();
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
  await testMain();
}
