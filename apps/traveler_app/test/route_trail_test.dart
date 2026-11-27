import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lakbay_travel/models/travel_models.dart';
import 'package:lakbay_travel/services/travel_repository.dart';
import 'package:lakbay_travel/widgets/lakbay_mapbox_widget.dart';
import 'package:lakbay_travel/widgets/route_trail.dart';
import 'package:shared_preferences/shared_preferences.dart';

RouteSegmentGeometry _seg({
  required TransportMode mode,
  required List<GeoPoint> points,
  bool isEstimated = false,
  String fromName = 'A',
  String toName = 'B',
}) {
  return RouteSegmentGeometry(
    mode: mode,
    points: points,
    fromName: fromName,
    toName: toName,
    isEstimated: isEstimated,
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('RouteTrail unit tests', () {
    test(
      'separates road/sea into animatedLegs and estimated into estimatedLegs',
      () {
        final trail = RouteTrail.fromRoute(
          segments: [
            _seg(
              mode: TransportMode.car,
              points: const [
                GeoPoint(lat: 7.05, lng: 125.55, label: 'D1 Start'),
                GeoPoint(lat: 7.12, lng: 125.55, label: 'D1 End'),
              ],
            ),
            _seg(
              mode: TransportMode.ferry,
              points: const [
                GeoPoint(lat: 7.12, lng: 125.63, label: 'Pier A'),
                GeoPoint(lat: 7.10, lng: 125.70, label: 'D2 Samal'),
              ],
            ),
            _seg(
              mode: TransportMode.car,
              isEstimated: true,
              points: const [
                GeoPoint(lat: 7.10, lng: 125.70, label: 'D2 Samal'),
                GeoPoint(lat: 6.95, lng: 126.22, label: 'D3 Dahican'),
              ],
            ),
          ],
          waypoints: const [
            GeoPoint(lat: 7.12, lng: 125.55, label: 'D1 End', dayNumber: 1),
            GeoPoint(lat: 7.10, lng: 125.70, label: 'D2 Samal', dayNumber: 2),
            GeoPoint(lat: 6.95, lng: 126.22, label: 'D3 Dahican', dayNumber: 3),
          ],
        );

        expect(trail.hasAnimatedTrail, isTrue);
        expect(trail.animatedLegs.length, 2);
        expect(trail.animatedLegs[0].mode, RouteTrailMode.road);
        expect(trail.animatedLegs[0].dayNumber, 1);
        expect(trail.animatedLegs[1].mode, RouteTrailMode.sea);
        expect(trail.animatedLegs[1].dayNumber, 2);
        expect(trail.estimatedLegs.length, 1);
        expect(trail.estimatedLegs.first.mode, RouteTrailMode.estimated);

        for (final frac in [0.0, 0.25, 0.5, 0.75, 1.0]) {
          final leg = trail.legAt(trail.totalAnimatedMeters * frac);
          expect(leg, isNotNull);
          expect(leg!.mode, isNot(RouteTrailMode.estimated));
        }

        final estimatedOnly = RouteTrail.fromRoute(
          segments: [
            _seg(
              mode: TransportMode.car,
              isEstimated: true,
              points: const [
                GeoPoint(lat: 7.05, lng: 125.55, label: 'A'),
                GeoPoint(lat: 7.15, lng: 125.65, label: 'B'),
              ],
            ),
          ],
        );

        expect(estimatedOnly.hasAnimatedTrail, isFalse);
        expect(estimatedOnly.totalAnimatedMeters, 0.0);
        expect(estimatedOnly.animatedLegs, isEmpty);
        expect(estimatedOnly.estimatedLegs.length, 1);
        expect(estimatedOnly.legAt(0.0), isNull);
        expect(estimatedOnly.pointAt(0.0), isNull);
      },
    );

    test('pointAt and bearingAt interpolate midpoints and cardinal bearings', () {
      final northTrail = RouteTrail.fromRoute(
        segments: [
          _seg(
            mode: TransportMode.car,
            points: const [
              GeoPoint(lat: 7.00, lng: 125.50, label: 'South'),
              GeoPoint(lat: 7.10, lng: 125.50, label: 'North'),
            ],
          ),
        ],
      );

      final midNorth = northTrail.pointAt(northTrail.totalAnimatedMeters * 0.5);
      expect(midNorth, isNotNull);
      expect(midNorth!.lat, closeTo(7.05, 1e-4));
      expect(midNorth.lng, closeTo(125.50, 1e-4));
      expect(
        northTrail.bearingAt(northTrail.totalAnimatedMeters * 0.5).abs(),
        lessThan(0.02),
      );

      final eastTrail = RouteTrail.fromRoute(
        segments: [
          _seg(
            mode: TransportMode.car,
            points: const [
              GeoPoint(lat: 7.00, lng: 125.50, label: 'West'),
              GeoPoint(lat: 7.00, lng: 125.60, label: 'East'),
            ],
          ),
        ],
      );

      expect(
        eastTrail.bearingAt(eastTrail.totalAnimatedMeters * 0.5),
        closeTo(math.pi / 2, 0.02),
      );
    });

    test(
      'douglasPeucker & simplifyScreenPolyline preserve corners and drop collinear vertices',
      () {
        final raw = <Offset>[
          const Offset(0, 0),
          const Offset(20, 0.2),
          const Offset(40, 0),
          const Offset(60, 0),
          const Offset(100, 0),
          const Offset(100, 80), // sharp 90-degree corner
          const Offset(100.3, 120),
          const Offset(100, 160),
        ];

        final simplified = RouteTrail.simplifyScreenPolyline(
          raw,
          tolerancePx: 1.0,
        );

        expect(simplified.first, const Offset(0, 0));
        expect(simplified.last, const Offset(100, 160));
        expect(simplified, contains(const Offset(100, 0)));
        expect(simplified.length, 3);
      },
    );

    test('trimmedPath extracts proportional path length for 0.0, 0.5, 1.0', () {
      final full = Path()
        ..moveTo(0, 0)
        ..lineTo(100, 0)
        ..lineTo(100, 100);

      double lengthOf(Path p) =>
          p.computeMetrics().fold<double>(0.0, (s, m) => s + m.length);

      expect(lengthOf(RouteTrail.trimmedPath(full, 0.0)), 0.0);
      expect(lengthOf(RouteTrail.trimmedPath(full, 0.5)), closeTo(100.0, 0.5));
      expect(lengthOf(RouteTrail.trimmedPath(full, 1.0)), closeTo(200.0, 0.5));
    });
  });

  group('RouteTrailController tests', () {
    testWidgets(
      'plays sequentially with ~300ms day pause, supports pause/play/replay/seekToDay',
      (tester) async {
        final trail = RouteTrail.fromRoute(
          segments: [
            _seg(
              mode: TransportMode.car,
              points: const [
                GeoPoint(lat: 7.00, lng: 125.50, label: 'D1 A'),
                GeoPoint(lat: 7.18, lng: 125.50, label: 'D1 B'), // ~20 km
              ],
            ),
            _seg(
              mode: TransportMode.ferry,
              points: const [
                GeoPoint(lat: 7.18, lng: 125.50, label: 'D1 B'),
                GeoPoint(lat: 7.18, lng: 125.64, label: 'D2 Samal'), // ~15 km
              ],
            ),
          ],
          waypoints: const [
            GeoPoint(lat: 7.18, lng: 125.50, label: 'D1 B', dayNumber: 1),
            GeoPoint(lat: 7.18, lng: 125.64, label: 'D2 Samal', dayNumber: 2),
          ],
        );

        var settledCalls = 0;
        final controller = RouteTrailController(
          vsync: const TestVSync(),
          trail: trail,
          onSettled: () => settledCalls++,
        );
        addTearDown(controller.dispose);

        expect(controller.isPlaying, isTrue);
        expect(controller.isSettled, isFalse);
        expect(controller.progress, 0.0);
        expect(controller.activeDayNumber, 1);

        // ~35 km total => ~4200 ms travel + 300 ms day pause (~4500 ms).
        // Day 1 (~20/35 of travel) finishes around ~2400 ms, then plateaus for 300 ms.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 2450));
        final plateauStart = controller.progress;
        await tester.pump(const Duration(milliseconds: 120));
        final plateauMid = controller.progress;
        expect(plateauMid, closeTo(plateauStart, 0.02));
        expect(plateauStart, greaterThan(0.45));
        expect(plateauStart, lessThan(0.70));

        // After plateau, moves into Day 2 sea leg.
        await tester.pump(const Duration(milliseconds: 800));
        expect(controller.activeDayNumber, 2);
        expect(controller.currentLeg?.mode, RouteTrailMode.sea);

        // Pause & verify progress freezes, then resume with play().
        controller.pause();
        expect(controller.isPlaying, isFalse);
        final pausedProgress = controller.progress;
        await tester.pump(const Duration(milliseconds: 400));
        expect(controller.progress, closeTo(pausedProgress, 1e-6));

        controller.play();
        expect(controller.isPlaying, isTrue);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 3000));
        expect(controller.isSettled, isTrue);
        expect(controller.isPlaying, isFalse);
        expect(controller.progress, closeTo(1.0, 1e-4));
        expect(settledCalls, 1);

        // seekToDay(1) jumps to Day 1 end & pauses cleanly.
        controller.seekToDay(1);
        expect(controller.isPlaying, isFalse);
        expect(controller.activeDayNumber, 1);
        expect(controller.progress, closeTo(trail.animatedLegs.first.endMeters / trail.totalAnimatedMeters, 1e-3));

        // replay() resets back to 0 and animates again.
        controller.replay();
        expect(controller.isPlaying, isTrue);
        expect(controller.progress, closeTo(0.0, 1e-4));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 5000));
        expect(controller.isSettled, isTrue);
      },
    );

    testWidgets(
      'clamps short and very long durations to 2..12s (+ pauses) and respects disableAnimations',
      (tester) async {
        // Very short trail (< 1 km) must still clamp to at least 2000 ms.
        final shortTrail = RouteTrail.fromRoute(
          segments: [
            _seg(
              mode: TransportMode.car,
              points: const [
                GeoPoint(lat: 7.070, lng: 125.610, label: 'A'),
                GeoPoint(lat: 7.075, lng: 125.610, label: 'B'),
              ],
            ),
          ],
        );
        final shortCtrl = RouteTrailController(
          vsync: const TestVSync(),
          trail: shortTrail,
        );
        addTearDown(shortCtrl.dispose);

        await tester.pump();
        await tester.pump(const Duration(milliseconds: 1200));
        expect(shortCtrl.isSettled, isFalse);
        await tester.pump(const Duration(milliseconds: 900));
        expect(shortCtrl.isSettled, isTrue);

        // Very long trail (~220 km single day) must clamp <= 12000 ms.
        final longTrail = RouteTrail.fromRoute(
          segments: [
            _seg(
              mode: TransportMode.car,
              points: const [
                GeoPoint(lat: 7.00, lng: 125.50, label: 'South'),
                GeoPoint(lat: 9.00, lng: 125.50, label: 'Far North'),
              ],
            ),
          ],
        );
        final longCtrl = RouteTrailController(
          vsync: const TestVSync(),
          trail: longTrail,
        );
        addTearDown(longCtrl.dispose);

        await tester.pump();
        await tester.pump(const Duration(milliseconds: 10000));
        expect(longCtrl.isSettled, isFalse);
        await tester.pump(const Duration(milliseconds: 2100));
        expect(longCtrl.isSettled, isTrue);

        // disableAnimations settles immediately.
        final reducedCtrl = RouteTrailController(
          vsync: const TestVSync(),
          trail: longTrail,
          disableAnimations: true,
        );
        addTearDown(reducedCtrl.dispose);
        expect(reducedCtrl.isSettled, isTrue);
        expect(reducedCtrl.isPlaying, isFalse);
        expect(reducedCtrl.progress, 1.0);
      },
    );
  });

  group('LakbayMapboxMap trail integration widget tests', () {
    testWidgets(
      'routed segments show Replay, Fly along, and moving head, settling on completion',
      (tester) async {
        final repo = TravelRepository();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 400,
                height: 400,
                child: LakbayMapboxMap(
                  repo: repo,
                  initialLat: 7.08,
                  initialLng: 125.60,
                  routeSegments: [
                    _seg(
                      mode: TransportMode.car,
                      points: const [
                        GeoPoint(lat: 7.05, lng: 125.55, label: 'Eden'),
                        GeoPoint(lat: 7.12, lng: 125.60, label: 'Pier'),
                      ],
                    ),
                    _seg(
                      mode: TransportMode.ferry,
                      points: const [
                        GeoPoint(lat: 7.12, lng: 125.60, label: 'Pier'),
                        GeoPoint(lat: 7.10, lng: 125.69, label: 'Samal'),
                      ],
                    ),
                  ],
                  routePoints: const [
                    GeoPoint(lat: 7.05, lng: 125.55, label: 'Eden', dayNumber: 1),
                    GeoPoint(lat: 7.10, lng: 125.69, label: 'Samal', dayNumber: 2),
                  ],
                ),
              ),
            ),
          ),
        );

        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(find.byKey(const ValueKey('trail_replay_button')), findsOneWidget);
        expect(
          find.byKey(const ValueKey('trail_fly_along_button')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('trail_vehicle_sprite')),
          findsOneWidget,
        );

        // Wait past full trail duration (clamped ~2s + 300ms pause).
        await tester.pump(const Duration(milliseconds: 2600));
        expect(find.text('Replay'), findsOneWidget);
        expect(find.byKey(const ValueKey('trail_vehicle_sprite')), findsNothing);
      },
    );

    testWidgets(
      'respects MediaQuery.disableAnimations by settling with no moving head or controls',
      (tester) async {
        final repo = TravelRepository();
        await tester.pumpWidget(
          MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: MaterialApp(
              home: Scaffold(
                body: SizedBox(
                  width: 400,
                  height: 400,
                  child: LakbayMapboxMap(
                    repo: repo,
                    initialLat: 7.08,
                    initialLng: 125.60,
                    routeSegments: [
                      _seg(
                        mode: TransportMode.car,
                        points: const [
                          GeoPoint(lat: 7.05, lng: 125.55, label: 'A'),
                          GeoPoint(lat: 7.15, lng: 125.62, label: 'B'),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );

        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));

        expect(find.byKey(const ValueKey('trail_vehicle_sprite')), findsNothing);
        expect(find.byKey(const ValueKey('trail_replay_button')), findsNothing);
        expect(
          find.byKey(const ValueKey('trail_fly_along_button')),
          findsNothing,
        );
      },
    );

    testWidgets(
      'estimated-only segments render no vehicle sprite and no trail controls',
      (tester) async {
        final repo = TravelRepository();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 400,
                height: 400,
                child: LakbayMapboxMap(
                  repo: repo,
                  initialLat: 7.08,
                  initialLng: 125.60,
                  routeSegments: [
                    _seg(
                      mode: TransportMode.car,
                      isEstimated: true,
                      points: const [
                        GeoPoint(lat: 7.05, lng: 125.55, label: 'A'),
                        GeoPoint(lat: 7.15, lng: 125.65, label: 'B'),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );

        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(find.byKey(const ValueKey('trail_vehicle_sprite')), findsNothing);
        expect(find.byKey(const ValueKey('trail_replay_button')), findsNothing);
        expect(
          find.byKey(const ValueKey('trail_fly_along_button')),
          findsNothing,
        );
      },
    );

    testWidgets(
      'Panabo-Sasa-Babak-Samal multimodal segments animate vehicle, render compact piers, and omit lat/lng clutter',
      (tester) async {
        final repo = TravelRepository();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 360,
                height: 600,
                child: LakbayMapboxMap(
                  repo: repo,
                  initialLat: 7.12,
                  initialLng: 125.67,
                  markers: const [
                    LakbayMapMarker(
                      id: 'pier_0',
                      lat: 7.1236,
                      lng: 125.6655,
                      badgeText: '⚓',
                      title: 'Sasa RoRo Wharf',
                      isCompact: true,
                    ),
                  ],
                  routeSegments: [
                    _seg(
                      mode: TransportMode.car,
                      points: const [
                        GeoPoint(lat: 7.299, lng: 125.674, label: 'Panabo'),
                        GeoPoint(lat: 7.1236, lng: 125.6655, label: 'Sasa'),
                      ],
                    ),
                    _seg(
                      mode: TransportMode.ferry,
                      points: const [
                        GeoPoint(lat: 7.1236, lng: 125.6655, label: 'Sasa'),
                        GeoPoint(lat: 7.1180, lng: 125.6880, label: 'Babak'),
                      ],
                    ),
                    _seg(
                      mode: TransportMode.car,
                      points: const [
                        GeoPoint(lat: 7.1180, lng: 125.6880, label: 'Babak'),
                        GeoPoint(lat: 7.08705, lng: 125.66662, label: 'Aqua'),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );

        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(find.byKey(const ValueKey('trail_vehicle_sprite')), findsOneWidget);
        expect(find.byKey(const ValueKey('trail_replay_button')), findsOneWidget);
        expect(
          find.text(repo.mapbox.tileAttribution(repo.activeMapStyle)),
          findsOneWidget,
        );
        expect(find.textContaining('°N'), findsNothing);
      },
    );
  });
}
