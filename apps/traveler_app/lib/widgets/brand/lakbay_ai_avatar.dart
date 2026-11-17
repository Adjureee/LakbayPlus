import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../design/lakbay_tokens.dart';

/// Lakbay AI's avatar: "L+" in mango on a deep teal rounded square. Shown
/// beside assistant messages so the planner has one consistent, honest
/// identity. It is not a person and never uses a face or a sparkle.
class LakbayAiAvatar extends StatelessWidget {
  const LakbayAiAvatar({super.key, this.diameter = 32});

  final double diameter;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Lakbay AI',
      excludeSemantics: true,
      child: Container(
        key: const ValueKey('lakbay-ai-avatar'),
        width: diameter,
        height: diameter,
        decoration: BoxDecoration(
          color: LkColors.s3,
          borderRadius: BorderRadius.circular(diameter * 0.32),
        ),
        alignment: Alignment.center,
        child: Text(
          'L+',
          style: GoogleFonts.manrope(
            fontSize: diameter * 0.4,
            fontWeight: FontWeight.w800,
            height: 1,
            color: LkColors.mango,
          ),
        ),
      ),
    );
  }
}
