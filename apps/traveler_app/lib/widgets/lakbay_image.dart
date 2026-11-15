import 'package:flutter/material.dart';
import '../theme/lakbay_theme.dart';

/// Shared Davao Region image renderer that prefers verified Cloudinary URLs,
/// then falls back smoothly to bundled local Davao Region photography.
class LakbayNetworkOrAssetImage extends StatelessWidget {
  final String? networkUrl;
  final String assetPath;
  final String fallbackAsset;
  final double? width;
  final double? height;
  final BoxFit fit;

  const LakbayNetworkOrAssetImage({
    super.key,
    required this.networkUrl,
    required this.assetPath,
    this.fallbackAsset = 'assets/home_backdrops/01-samal-island.jpg',
    this.width,
    this.height,
    this.fit = BoxFit.cover,
  });

  bool get _hasRemoteUrl {
    final trimmed = networkUrl?.trim() ?? '';
    return trimmed.startsWith('http://') || trimmed.startsWith('https://');
  }

  Widget _buildAssetFallback() {
    return Image.asset(
      assetPath,
      width: width,
      height: height,
      fit: fit,
      errorBuilder: (_, _, _) => Image.asset(
        fallbackAsset,
        width: width,
        height: height,
        fit: fit,
        errorBuilder: (_, _, _) => Container(
          width: width,
          height: height,
          decoration: const BoxDecoration(gradient: LakbayColors.deepTealGradient),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_hasRemoteUrl) {
      return _buildAssetFallback();
    }
    return Image.network(
      networkUrl!.trim(),
      width: width,
      height: height,
      fit: fit,
      loadingBuilder: (context, child, loadingProgress) {
        if (loadingProgress == null) return child;
        return Stack(
          fit: StackFit.passthrough,
          children: [
            _buildAssetFallback(),
            Container(color: Colors.black.withValues(alpha: 0.08)),
          ],
        );
      },
      errorBuilder: (_, _, _) => _buildAssetFallback(),
    );
  }
}
