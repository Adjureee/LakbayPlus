import 'package:flutter/material.dart';

import '../core/place_kinds.dart';

/// What a place shows when the app has no photo of it: a plain illustration
/// tinted for the kind of place. It never shows a photo of another place, so a
/// traveler is not led to think a waterfall looks like a beach. Big cards say
/// "Photo coming soon"; small thumbnails show only the icon.
class PlacePhotoPlaceholder extends StatelessWidget {
  final String? category;
  final double? width;
  final double? height;

  const PlacePhotoPlaceholder({
    super.key,
    this.category,
    this.width,
    this.height,
  });

  static (IconData, Color, Color) _look(PlaceKind kind) => switch (kind) {
        PlaceKind.beach => (
            Icons.beach_access_rounded,
            const Color(0xFF2A9D8F),
            const Color(0xFF1B6F8A),
          ),
        PlaceKind.water => (
            Icons.water_rounded,
            const Color(0xFF3A86A8),
            const Color(0xFF1D4E6B),
          ),
        PlaceKind.mountain => (
            Icons.landscape_rounded,
            const Color(0xFF5B7F6B),
            const Color(0xFF2F4F4F),
          ),
        PlaceKind.nature => (
            Icons.park_rounded,
            const Color(0xFF4C9A6A),
            const Color(0xFF2D6A4F),
          ),
        PlaceKind.culture => (
            Icons.account_balance_rounded,
            const Color(0xFFC08A5B),
            const Color(0xFF8A5A3C),
          ),
        PlaceKind.stay => (
            Icons.hotel_rounded,
            const Color(0xFFD98C6A),
            const Color(0xFFA85C4A),
          ),
        PlaceKind.other => (
            Icons.place_rounded,
            const Color(0xFF3D8C8C),
            const Color(0xFF1F5F66),
          ),
      };

  @override
  Widget build(BuildContext context) {
    final (icon, from, to) = _look(placeKindFor(category));
    return SizedBox(
      width: width,
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [from, to],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final side = constraints.hasBoundedHeight
                ? constraints.maxHeight
                : (constraints.hasBoundedWidth ? constraints.maxWidth : 120.0);
            final big = side >= 140;
            return ExcludeSemantics(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      icon,
                      color: Colors.white.withValues(alpha: 0.85),
                      size: (side * 0.34).clamp(18.0, 64.0),
                    ),
                    if (big) ...[
                      const SizedBox(height: 6),
                      Text(
                        'Photo coming soon',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.8),
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
