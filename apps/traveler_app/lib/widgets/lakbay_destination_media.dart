import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'lakbay_image.dart';

/// Displays rich destination media (poster image, animated GIF, or muted
/// <=15s looping MP4/WebM clip) with automatic fallback to [posterUrl] /
/// [assetPath] / [category] placeholder when offline, over 15s, unsupported,
/// unknown `media_type`, or when the user prefers reduced motion.
class LakbayDestinationMedia extends StatelessWidget {
  final String? posterUrl;
  final String assetPath;
  final String? mediaUrl;
  final String? mediaType;
  final double? mediaDurationSeconds;
  final String? category;
  final bool allowAnimatedClip;
  final double? width;
  final double? height;
  final BoxFit fit;

  const LakbayDestinationMedia({
    super.key,
    required this.posterUrl,
    required this.assetPath,
    this.mediaUrl,
    this.mediaType,
    this.mediaDurationSeconds,
    this.category,
    this.allowAnimatedClip = true,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
  });

  static bool _isHttpUrl(String? raw) {
    final trimmed = raw?.trim() ?? '';
    return trimmed.startsWith('http://') || trimmed.startsWith('https://');
  }

  static bool _isDurationAllowed(double? seconds) {
    if (seconds == null) return true;
    return seconds.isFinite && seconds > 0 && seconds <= 15.0;
  }

  Widget _buildPoster() {
    return LakbayNetworkOrAssetImage(
      networkUrl: _isHttpUrl(posterUrl) ? posterUrl!.trim() : null,
      assetPath: assetPath,
      category: category,
      width: width,
      height: height,
      fit: fit,
    );
  }

  @override
  Widget build(BuildContext context) {
    final poster = _buildPoster();
    if (!allowAnimatedClip) return poster;

    // Accessibility / Reduced-motion guard: never auto-play GIFs or video clips.
    final disableAnimations = MediaQuery.disableAnimationsOf(context) ||
        MediaQuery.accessibleNavigationOf(context);
    if (disableAnimations) return poster;

    final cleanUrl = mediaUrl?.trim() ?? '';
    final cleanType = mediaType?.trim().toLowerCase() ?? '';
    if (!_isHttpUrl(cleanUrl)) return poster;

    if (cleanType == 'gif') {
      // Do NOT rewrite through Cloudinary f_auto, which can strip GIF animation.
      return Image.network(
        cleanUrl,
        width: width,
        height: height,
        fit: fit,
        gaplessPlayback: true,
        loadingBuilder: (_, child, progress) =>
            progress == null ? child : poster,
        errorBuilder: (_, _, _) => poster,
      );
    }

    if (cleanType == 'video') {
      if (!_isDurationAllowed(mediaDurationSeconds)) {
        return poster;
      }
      return _MutedLoopVideoClip(
        videoUrl: cleanUrl,
        poster: poster,
        width: width,
        height: height,
        fit: fit,
      );
    }

    // Unknown / unplayable media types ('image', 'exe', null, etc.) show poster.
    return poster;
  }
}

class _MutedLoopVideoClip extends StatefulWidget {
  final String videoUrl;
  final Widget poster;
  final double? width;
  final double? height;
  final BoxFit fit;

  const _MutedLoopVideoClip({
    required this.videoUrl,
    required this.poster,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
  });

  @override
  State<_MutedLoopVideoClip> createState() => _MutedLoopVideoClipState();
}

class _MutedLoopVideoClipState extends State<_MutedLoopVideoClip> {
  VideoPlayerController? _controller;
  bool _ready = false;
  bool _failed = false;

  static bool get _isTestBinding =>
      WidgetsBinding.instance.runtimeType.toString().contains('TestWidgets');

  @override
  void initState() {
    super.initState();
    _initVideo();
  }

  @override
  void didUpdateWidget(covariant _MutedLoopVideoClip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoUrl != widget.videoUrl) {
      _disposeController();
      _ready = false;
      _failed = false;
      _initVideo();
    }
  }

  Future<void> _initVideo() async {
    // Automated widget-test harnesses do not provide a native video codec/platform view.
    if (_isTestBinding || kIsWeb && widget.videoUrl.isEmpty) {
      return;
    }
    final uri = Uri.tryParse(widget.videoUrl);
    if (uri == null || !uri.hasScheme) return;
    try {
      final controller = VideoPlayerController.networkUrl(uri);
      _controller = controller;
      await controller.initialize();
      if (!mounted || _controller != controller) {
        await controller.dispose();
        return;
      }
      await controller.setLooping(true);
      await controller.setVolume(0.0);
      await controller.play();
      if (!mounted || _controller != controller) return;
      setState(() => _ready = true);
    } catch (_) {
      _disposeController();
      if (mounted) {
        setState(() => _failed = true);
      }
    }
  }

  void _disposeController() {
    final c = _controller;
    _controller = null;
    c?.dispose();
  }

  @override
  void dispose() {
    _disposeController();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (_failed ||
        !_ready ||
        controller == null ||
        !controller.value.isInitialized) {
      return widget.poster;
    }
    final size = controller.value.size;
    if (size.width <= 0 || size.height <= 0) {
      return widget.poster;
    }
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: Stack(
        fit: StackFit.expand,
        children: [
          FittedBox(
            fit: widget.fit,
            clipBehavior: Clip.hardEdge,
            child: SizedBox(
              width: size.width,
              height: size.height,
              child: VideoPlayer(controller),
            ),
          ),
          Positioned(
            right: 8,
            bottom: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(
                Icons.play_arrow_rounded,
                size: 13,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
