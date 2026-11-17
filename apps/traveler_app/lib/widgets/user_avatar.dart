import 'package:flutter/material.dart';

import '../theme/lakbay_theme.dart';

/// The traveler's profile picture as a clean circle.
///
/// The photo is cut to the circle and the ring is drawn on top of it, so no
/// corner of a square photo can show at the edge. With no photo (or when it
/// cannot load) the initials are shown instead.
class UserAvatar extends StatelessWidget {
  final String imageUrl;
  final String initials;
  final double size;
  final double ringWidth;
  final Color ringColor;

  const UserAvatar({
    super.key,
    required this.imageUrl,
    required this.initials,
    this.size = 44,
    this.ringWidth = 0,
    this.ringColor = Colors.white,
  });

  @override
  Widget build(BuildContext context) {
    final fallback = Center(
      child: Text(
        initials,
        style: TextStyle(
          fontSize: size * 0.32,
          fontWeight: FontWeight.w800,
          color: LakbayColors.primaryDark,
        ),
      ),
    );
    return SizedBox(
      width: size,
      height: size,
      child: ClipOval(
        child: Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(color: LakbayColors.primaryLight),
            if (imageUrl.isEmpty)
              fallback
            else
              Image.network(
                imageUrl,
                fit: BoxFit.cover,
                alignment: Alignment.center,
                errorBuilder: (_, _, _) => fallback,
              ),
            if (ringWidth > 0)
              IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: ringColor, width: ringWidth),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
