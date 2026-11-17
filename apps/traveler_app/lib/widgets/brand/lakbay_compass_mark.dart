import 'package:flutter/material.dart';

/// Lakbay+'s logo: the teal jeepney-style bus with the traveler inside.
///
/// This widget used to draw an eight-point compass star; its name is kept so
/// every place that showed the star (the chat avatar, the Chat tab button and
/// the wordmark) now shows the logo without further changes.
///
/// [size] is the height of the box; the logo is wider than it is tall, so the
/// box is [size] * [aspect] wide. The logo keeps its own colours. On a dark
/// background (a light [primaryColor], as the old white star used) it sits on
/// a white rounded badge so the teal bus stays readable.
class LakbayCompassMark extends StatelessWidget {
  const LakbayCompassMark({
    super.key,
    this.size = 28,
    this.primaryColor,
    this.secondaryColor,
  });

  /// Height of the box, in logical pixels.
  final double size;

  /// Kept for existing callers. Only its brightness is used: a light color
  /// means the mark sits on a dark background.
  final Color? primaryColor;

  /// Unused; kept so existing callers still compile.
  final Color? secondaryColor;

  /// Width over height of the logo artwork.
  static const double aspect = 640 / 332;

  static const String asset = 'assets/brand/lakbay_logo.png';

  @override
  Widget build(BuildContext context) {
    final onDark = (primaryColor?.computeLuminance() ?? 0) > 0.8;
    final logo = Image.asset(
      asset,
      key: const ValueKey('lakbay-logo'),
      width: size * aspect,
      height: size,
      fit: BoxFit.contain,
      semanticLabel: 'Lakbay+',
      filterQuality: FilterQuality.medium,
    );
    if (!onDark) return logo;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(size * 0.28),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: size * 0.14,
          vertical: size * 0.08,
        ),
        child: logo,
      ),
    );
  }
}
