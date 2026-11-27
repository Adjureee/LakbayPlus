import 'package:flutter_test/flutter_test.dart';
import 'package:lakbay_admin/core/image_urls.dart';

void main() {
  const original =
      'https://res.cloudinary.com/bh2rda7z/image/upload/v1794350058/lakbay/destinations/1/peoples_park-9d2874c9.jpg';

  test('Cloudinary originals are requested at twice the shown size', () {
    expect(
      cloudinarySized(original, width: 56, height: 56),
      'https://res.cloudinary.com/bh2rda7z/image/upload/'
      'f_auto,q_auto,c_fill,g_auto,w_112,h_112/'
      'v1794350058/lakbay/destinations/1/peoples_park-9d2874c9.jpg',
    );
  });

  test('large requests are capped at 1600 px', () {
    expect(
      cloudinarySized(original, width: 2000, height: 300),
      contains('w_1600,h_600/'),
    );
  });

  test('already-transformed and non-Cloudinary URLs are left alone', () {
    const transformed =
        'https://res.cloudinary.com/demo/image/upload/w_200,c_fill/v1/x.jpg';
    expect(cloudinarySized(transformed, width: 56, height: 56), transformed);
    const other = 'https://example.org/photos/beach.jpg';
    expect(cloudinarySized(other, width: 56, height: 56), other);
    expect(cloudinarySized('not a url', width: 56, height: 56), 'not a url');
  });

  test('GIF URLs preserve animation by omitting f_auto unless staticFrame is set', () {
    const gifUrl =
        'https://res.cloudinary.com/demo/image/upload/v1/lakbay/destinations/1/wave.gif';
    expect(
      cloudinarySized(gifUrl, width: 200, height: 150),
      'https://res.cloudinary.com/demo/image/upload/'
      'q_auto,c_fill,g_auto,w_400,h_300/'
      'v1/lakbay/destinations/1/wave.gif',
    );
    expect(
      cloudinarySized(gifUrl, width: 56, height: 56, staticFrame: true),
      'https://res.cloudinary.com/demo/image/upload/'
      'pg_1,f_jpg,q_auto,c_fill,g_auto,w_112,h_112/'
      'v1/lakbay/destinations/1/wave.gif',
    );
  });

  test('cloudinaryVideoPosterUrl derives frame-0 JPEG poster or returns null', () {
    const videoUrl =
        'https://res.cloudinary.com/demo/video/upload/v1/lakbay/destinations/1/clip.mp4';
    expect(
      cloudinaryVideoPosterUrl(videoUrl, width: 400, height: 225),
      'https://res.cloudinary.com/demo/video/upload/'
      'so_0,f_jpg,q_auto,c_fill,g_auto,w_800,h_450/'
      'v1/lakbay/destinations/1/clip.jpg',
    );
    expect(
      cloudinaryVideoPosterUrl('https://cdn.example.test/clip.mp4'),
      isNull,
    );
  });

  test('destinationPosterUrl prefers image_url and falls back safely', () {
    const poster =
        'https://res.cloudinary.com/demo/image/upload/v1/lakbay/destinations/1/poster.jpg';
    const videoUrl =
        'https://res.cloudinary.com/demo/video/upload/v1/lakbay/destinations/1/clip.mp4';
    const gifUrl =
        'https://res.cloudinary.com/demo/image/upload/v1/lakbay/destinations/1/wave.gif';

    expect(
      destinationPosterUrl(
        {'image_url': poster, 'media_url': videoUrl, 'media_type': 'video'},
        width: 56,
        height: 56,
      ),
      contains('w_112,h_112/v1/lakbay/destinations/1/poster.jpg'),
    );
    expect(
      destinationPosterUrl(
        {'image_url': null, 'media_url': videoUrl, 'media_type': 'video'},
        width: 360,
        height: 150,
      ),
      'https://res.cloudinary.com/demo/video/upload/'
      'so_0,f_jpg,q_auto,c_fill,g_auto,w_720,h_300/'
      'v1/lakbay/destinations/1/clip.jpg',
    );
    // Non-Cloudinary video URL never leaks into Image.network.
    expect(
      destinationPosterUrl(
        {
          'image_url': null,
          'media_url': 'https://cdn.example.test/clip.webm',
          'media_type': 'video',
        },
        width: 360,
        height: 150,
      ),
      isNull,
    );
    // Map pin requests static frame for GIF fallback.
    expect(
      destinationPosterUrl(
        {'image_url': null, 'media_url': gifUrl, 'media_type': 'gif'},
        width: 56,
        height: 56,
        staticGif: true,
      ),
      contains('pg_1,f_jpg,q_auto,c_fill,g_auto,w_112,h_112/'),
    );
  });
}
