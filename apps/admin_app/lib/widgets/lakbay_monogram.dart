import 'package:flutter/material.dart';

/// Lakbay+ admin brand tile: "L+" in mango on deep teal, matching the
/// traveler app's v8 identity. Used where only a small square fits (login
/// header, sidebar, collapsed sidebar). The brand has no symbol mark.
class LakbayMonogram extends StatelessWidget {
  const LakbayMonogram({super.key, this.size = 40});

  final double size;

  static const Color _tile = Color(0xFF0A2A2F);
  static const Color _mango = Color(0xFFFFB547);

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Lakbay+',
      excludeSemantics: true,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: _tile,
          borderRadius: BorderRadius.circular(size * 0.28),
        ),
        alignment: Alignment.center,
        child: Text(
          'L+',
          style: TextStyle(
            fontSize: size * 0.4,
            fontWeight: FontWeight.w800,
            height: 1,
            color: _mango,
          ),
        ),
      ),
    );
  }
}
