import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lakbay_travel/models/travel_models.dart';
import 'package:lakbay_travel/widgets/lakbay_destination_media.dart';
import 'package:lakbay_travel/widgets/lakbay_image.dart';

import 'e2e/e2e_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LakbayDestinationMedia (R7) & Visit Duration Labels (R8)', () {
    testWidgets(
      'animated GIF preserves raw URL without Cloudinary f_auto and stops on disableAnimations',
      (tester) async {
        const rawGifUrl =
            'https://res.cloudinary.com/lakbay/image/upload/v1/dahican.gif';

        await tester.pumpWidget(
          const MediaQuery(
            data: MediaQueryData(disableAnimations: false),
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: LakbayDestinationMedia(
                posterUrl:
                    'https://res.cloudinary.com/lakbay/image/upload/v1/dahican.jpg',
                assetPath: '',
                mediaUrl: rawGifUrl,
                mediaType: 'gif',
                category: 'beach',
                width: 240,
                height: 160,
              ),
            ),
          ),
        );

        final netImages = tester
            .widgetList<Image>(find.byType(Image))
            .where((img) => img.image is NetworkImage)
            .map((img) => (img.image as NetworkImage).url)
            .toList();
        expect(netImages, contains(rawGifUrl));
        expect(netImages.any((u) => u.contains('f_auto') && u.endsWith('.gif')), isFalse);

        // Under reduced motion, switch to static poster only (no animated GIF).
        await tester.pumpWidget(
          const MediaQuery(
            data: MediaQueryData(disableAnimations: true),
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: LakbayDestinationMedia(
                posterUrl:
                    'https://res.cloudinary.com/lakbay/image/upload/v1/dahican.jpg',
                assetPath: '',
                mediaUrl: rawGifUrl,
                mediaType: 'gif',
                category: 'beach',
                width: 240,
                height: 160,
              ),
            ),
          ),
        );

        expect(find.byType(LakbayNetworkOrAssetImage), findsOneWidget);
        final reducedUrls = tester
            .widgetList<Image>(find.byType(Image))
            .where((img) => img.image is NetworkImage)
            .map((img) => (img.image as NetworkImage).url)
            .toList();
        expect(reducedUrls, isNot(contains(rawGifUrl)));
      },
    );

    testWidgets(
      'video over 15s and unknown media_type fall back immediately to static poster',
      (tester) async {
        await tester.pumpWidget(
          const MediaQuery(
            data: MediaQueryData(disableAnimations: false),
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: Column(
                children: [
                  SizedBox(
                    width: 200,
                    height: 120,
                    child: LakbayDestinationMedia(
                      posterUrl: 'https://cdn.lakbay.test/p.jpg',
                      assetPath: '',
                      mediaUrl: 'https://cdn.lakbay.test/long.mp4',
                      mediaType: 'video',
                      mediaDurationSeconds: 18.5,
                      category: 'park',
                    ),
                  ),
                  SizedBox(
                    width: 200,
                    height: 120,
                    child: LakbayDestinationMedia(
                      posterUrl: 'https://cdn.lakbay.test/p2.jpg',
                      assetPath: '',
                      mediaUrl: 'https://cdn.lakbay.test/bad.bin',
                      mediaType: 'exe',
                      category: 'park',
                    ),
                  ),
                ],
              ),
            ),
          ),
        );

        expect(find.byType(LakbayNetworkOrAssetImage), findsNWidgets(2));
        expect(tester.takeException(), isNull);
      },
    );

    test('ItineraryTrip round-trips media fields and buildDetailedItineraryFromExplore preserves them', () {
      const explore = ExploreTrip(
        locale: 'en',
        id: 'api_10',
        title: 'Malagos Garden Resort',
        days: 1,
        lat: 7.1892,
        lng: 125.4241,
        thumbnailUrl: 'https://cdn.lakbay.test/malagos.jpg',
        tag: 'Nature Resort',
        apiDestinationId: 10,
        stayDurationType: 'half_day',
        mediaUrl: 'https://cdn.lakbay.test/malagos.mp4',
        mediaType: 'video',
        mediaDurationSeconds: 9.0,
      );
      expect(explore.typicalVisitLabel, 'Typical visit: Half day');

      final router = E2eMockRouter();
      final repo = createE2eRepository(router: router);
      final built = repo.buildDetailedItineraryFromExplore(explore);
      expect(built.mediaUrl, 'https://cdn.lakbay.test/malagos.mp4');
      expect(built.mediaType, 'video');
      expect(built.mediaDurationSeconds, 9.0);

      final decoded = ItineraryTrip.fromJson(built.toJson());
      expect(decoded.mediaUrl, 'https://cdn.lakbay.test/malagos.mp4');
      expect(decoded.mediaType, 'video');
      expect(decoded.mediaDurationSeconds, 9.0);
    });
  });
}
