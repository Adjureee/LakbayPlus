/// Image and media poster URLs sized for where they are shown.
///
/// Destination photos are Cloudinary originals of several megabytes each.
/// Loading 41 of them for 38 px map pins made the admin hang, so every admin
/// image goes through [cloudinarySized], which asks Cloudinary for a small
/// cropped rendition (a few kilobytes for a pin).
library;

final _transformSegment = RegExp(r'^[a-z]{1,3}_[^/]+(,[a-z]{1,3}_[^/]+)*$');

/// Returns [url] resized by Cloudinary to [width]×[height] logical pixels
/// (doubled for sharpness on high-density screens, capped at 1600).
///
/// For `.gif` URLs or when [preserveAnimation] is true, `f_auto` is omitted
/// so Cloudinary does not strip animation frames. When [staticFrame] is true,
/// `pg_1,f_jpg` is used to extract a static poster frame.
///
/// URLs that are not Cloudinary uploads, or that already carry a
/// transformation, are returned unchanged.
String cloudinarySized(
  String url, {
  required int width,
  required int height,
  bool preserveAnimation = false,
  bool staticFrame = false,
}) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.host != 'res.cloudinary.com') return url;
  final segments = uri.pathSegments;
  final upload = segments.indexOf('upload');
  if (upload < 1 || segments[upload - 1] != 'image') return url;
  if (upload + 1 < segments.length &&
      _transformSegment.hasMatch(segments[upload + 1])) {
    return url; // Already transformed; do not stack another one.
  }
  final w = (width * 2).clamp(1, 1600), h = (height * 2).clamp(1, 1600);
  final isGif = uri.path.toLowerCase().endsWith('.gif');
  final transform = staticFrame
      ? 'pg_1,f_jpg,q_auto,c_fill,g_auto,w_$w,h_$h'
      : (preserveAnimation || isGif)
      ? 'q_auto,c_fill,g_auto,w_$w,h_$h'
      : 'f_auto,q_auto,c_fill,g_auto,w_$w,h_$h';
  final sized = [
    ...segments.take(upload + 1),
    transform,
    ...segments.skip(upload + 1),
  ];
  return uri.replace(pathSegments: sized).toString();
}

/// Converts a Cloudinary `/video/upload/...` URL into a static frame-0 JPEG
/// poster sized for [width]×[height] logical pixels. Returns `null` when [url]
/// is not a Cloudinary video upload URL.
String? cloudinaryVideoPosterUrl(
  String url, {
  int width = 800,
  int height = 450,
}) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.host != 'res.cloudinary.com') return null;
  final segments = uri.pathSegments;
  final upload = segments.indexOf('upload');
  if (upload < 1 ||
      segments[upload - 1] != 'video' ||
      upload + 1 >= segments.length) {
    return null;
  }
  final w = (width * 2).clamp(1, 1600), h = (height * 2).clamp(1, 1600);
  final rest = segments.skip(upload + 1).toList();
  final hasTransform = _transformSegment.hasMatch(rest.first);
  final last = rest.last;
  final dot = last.lastIndexOf('.');
  rest[rest.length - 1] = '${dot > 0 ? last.substring(0, dot) : last}.jpg';
  final posterSegments = [
    ...segments.take(upload + 1),
    if (!hasTransform) 'so_0,f_jpg,q_auto,c_fill,g_auto,w_$w,h_$h',
    ...rest,
  ];
  return uri.replace(pathSegments: posterSegments).toString();
}

/// Returns a safe, `Image.network`-compatible poster URL for [record].
///
/// Prefers `image_url`, falling back to `media_url` (converting Cloudinary
/// videos via [cloudinaryVideoPosterUrl] and avoiding raw `.mp4`/`.webm` URLs).
String? destinationPosterUrl(
  Map<String, dynamic> record, {
  required int width,
  required int height,
  bool staticGif = false,
}) {
  final imageUrl = _validHttpUrl(record['image_url']);
  if (imageUrl != null && !_looksLikeVideoUrl(imageUrl)) {
    return cloudinarySized(
      imageUrl,
      width: width,
      height: height,
      staticFrame: staticGif,
    );
  }
  final mediaUrl = _validHttpUrl(record['media_url']);
  if (mediaUrl == null) return null;
  final mediaType = record['media_type']?.toString().toLowerCase() ?? '';
  if (mediaType == 'video' || _looksLikeVideoUrl(mediaUrl)) {
    return cloudinaryVideoPosterUrl(mediaUrl, width: width, height: height);
  }
  return cloudinarySized(
    mediaUrl,
    width: width,
    height: height,
    preserveAnimation: mediaType == 'gif' && !staticGif,
    staticFrame: staticGif,
  );
}

String? _validHttpUrl(Object? raw) {
  final text = raw?.toString().trim() ?? '';
  if (text.isEmpty) return null;
  final uri = Uri.tryParse(text);
  if (uri == null ||
      !uri.hasAuthority ||
      uri.host.isEmpty ||
      (uri.scheme != 'http' && uri.scheme != 'https')) {
    return null;
  }
  return uri.toString();
}

bool _looksLikeVideoUrl(String url) {
  final path = Uri.tryParse(url)?.path.toLowerCase() ?? url.toLowerCase();
  return path.endsWith('.mp4') ||
      path.endsWith('.webm') ||
      path.contains('/video/upload/');
}
