import 'package:flutter/material.dart';
import 'place_photo_placeholder.dart';

/// Sizes remote photos to what is shown.
///
/// Admin photos live on Cloudinary at full camera size. A list of them decoded
/// at full size is slow and heavy, so the address is asked for a smaller copy
/// (`w_<px>,q_auto,f_auto`), and the decoder is told the size too.
class LakbayImageSizing {
  LakbayImageSizing._();

  /// Widths are rounded up to these steps so one copy serves many sizes and
  /// stays cached.
  static const _steps = [240, 360, 480, 720, 1080, 1440];

  static int stepFor(double logicalWidth, double devicePixelRatio) {
    final wanted = logicalWidth * devicePixelRatio;
    for (final step in _steps) {
      if (wanted <= step) return step;
    }
    return _steps.last;
  }

  /// A smaller copy of a Cloudinary photo, or [url] unchanged when it is not a
  /// Cloudinary upload or already has a transformation.
  static String sized(String url, int width) {
    const marker = '/image/upload/';
    final at = url.indexOf(marker);
    if (!url.contains('res.cloudinary.com') || at < 0) return url;
    final rest = url.substring(at + marker.length);
    // Already transformed (for example `w_400,c_fill/...`): leave it alone.
    if (RegExp(r'^[a-z]{1,3}_[^/]+/').hasMatch(rest) && !rest.startsWith('v')) {
      return url;
    }
    return '${url.substring(0, at + marker.length)}w_$width,q_auto,f_auto/$rest';
  }
}

/// Shows a place's photo: the admin's Cloudinary photo when there is one, else
/// the bundled photo of that exact place, else a plain illustration for the kind
/// of place ([PlacePhotoPlaceholder]). It never falls back to a photo of a
/// different place, so a card cannot show a beach for a waterfall.
class LakbayNetworkOrAssetImage extends StatelessWidget {
  final String? networkUrl;

  /// A bundled photo of this exact place, or empty when the app has none.
  final String assetPath;

  /// The place's category, to pick the placeholder's illustration.
  final String? category;
  final double? width;
  final double? height;
  final BoxFit fit;

  const LakbayNetworkOrAssetImage({
    super.key,
    required this.networkUrl,
    required this.assetPath,
    this.category,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
  });

  bool get _hasRemoteUrl {
    final trimmed = networkUrl?.trim() ?? '';
    return trimmed.startsWith('http://') || trimmed.startsWith('https://');
  }

  Widget _placeholder() =>
      PlacePhotoPlaceholder(category: category, width: width, height: height);

  Widget _buildAsset() {
    if (assetPath.trim().isEmpty) return _placeholder();
    return Image.asset(
      assetPath,
      width: width,
      height: height,
      fit: fit,
      errorBuilder: (_, _, _) => _placeholder(),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_hasRemoteUrl) {
      return _buildAsset();
    }
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final target = LakbayImageSizing.stepFor(
      (width != null && width!.isFinite) ? width! : 480,
      dpr,
    );
    return Image.network(
      LakbayImageSizing.sized(networkUrl!.trim(), target),
      width: width,
      height: height,
      fit: fit,
      cacheWidth: target,
      gaplessPlayback: true,
      loadingBuilder: (context, child, loadingProgress) {
        if (loadingProgress == null) return child;
        return _buildAsset();
      },
      errorBuilder: (_, _, _) => _buildAsset(),
    );
  }
}
