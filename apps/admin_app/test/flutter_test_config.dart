import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:lakbay_admin/widgets/admin_motion.dart';

/// Loads the bundled fonts (Manrope, Bricolage Grotesque) before any test,
/// so no test sees a font finish loading mid-test.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Screens render in their final state in tests.
  AdminMotion.enabled = false;
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
