/// Image URLs sized for where they are shown.
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
/// URLs that are not Cloudinary uploads, or that already carry a
/// transformation, are returned unchanged.
String cloudinarySized(String url, {required int width, required int height}) {
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
  final sized = [
    ...segments.take(upload + 1),
    'f_auto,q_auto,c_fill,g_auto,w_$w,h_$h',
    ...segments.skip(upload + 1),
  ];
  return uri.replace(pathSegments: sized).toString();
}
