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
}
