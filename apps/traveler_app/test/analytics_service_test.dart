import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lakbay_travel/models/travel_models.dart';
import 'package:lakbay_travel/services/analytics_service.dart';
import 'package:lakbay_travel/services/lakbay_api_catalog_service.dart';
import 'package:lakbay_travel/services/travel_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Collects what would have been sent, instead of sending it.
class _Recorder {
  final events = <(String, Map<String, Object>)>[];
  final collection = <bool>[];

  Future<void> send(String name, Map<String, Object> parameters) async {
    events.add((name, parameters));
  }

  Future<void> switchTo(bool enabled) async => collection.add(enabled);

  List<String> get names => [for (final e in events) e.$1];
}

const _mountApo = ExploreTrip(
  locale: 'en',
  id: 'api_5',
  apiDestinationId: 5,
  title: 'Mount Apo Trail Area',
  lat: 6.9875,
  lng: 125.2708,
  thumbnailUrl: '',
  tag: 'Mountain',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<(AnalyticsService, _Recorder, DateTime Function())> started({
    Map<String, Object> saved = const {},
    DateTime? now,
  }) async {
    SharedPreferences.setMockInitialValues(saved);
    final recorder = _Recorder();
    var clock = now ?? DateTime(2026, 11, 27, 9);
    final service = AnalyticsService(
      sender: recorder.send,
      collectionSwitch: recorder.switchTo,
      prefs: await SharedPreferences.getInstance(),
      clock: () => clock,
    );
    await service.start();
    return (service, recorder, () => clock = clock.add(const Duration(seconds: 42)));
  }

  group('AnalyticsService', () {
    test('without a sender every call does nothing and nothing throws',
        () async {
      final service = AnalyticsService();
      service
        ..onboardingDone()
        ..placeAdded()
        ..tripSaved(days: 3)
        ..chatReply(cards: 2);
      await service.setEnabled(false);
      expect(service.enabled, isFalse);
    });

    test('start applies the saved choice to the collection and defaults to off',
        () async {
      final (service, recorder, _) = await started();
      expect(service.enabled, isFalse);
      expect(recorder.collection, [false]);

      final (on, onRecorder, _) =
          await started(saved: {AnalyticsService.enabledKey: true});
      expect(on.enabled, isTrue);
      expect(onRecorder.collection, [true]);
    });

    test('off by default sends nothing and opt-in/opt-out survive a restart',
        () async {
      final (service, recorder, _) = await started();
      service
        ..onboardingDone()
        ..placeAdded()
        ..tripSaved(days: 2)
        ..chatReply(cards: 3);
      expect(recorder.events, isEmpty);
      expect(recorder.collection.last, isFalse);

      await service.setEnabled(true);
      expect(service.enabled, isTrue);
      expect(recorder.collection.last, isTrue);

      final optedInRestart = AnalyticsService(
        prefs: await SharedPreferences.getInstance(),
      );
      await optedInRestart.start();
      expect(optedInRestart.enabled, isTrue);

      await optedInRestart.setEnabled(false);
      optedInRestart.placeAdded();
      expect(recorder.events, isEmpty);

      final optedOutRestart = AnalyticsService(
        prefs: await SharedPreferences.getInstance(),
      );
      await optedOutRestart.start();
      expect(optedOutRestart.enabled, isFalse);
    });

    test('only the allowed event names with number parameters are sent',
        () async {
      final (service, recorder, _) =
          await started(saved: {AnalyticsService.enabledKey: true});
      service
        ..onboardingDone()
        ..placeAdded()
        ..tripSaved(days: 3)
        ..chatReply(cards: 2);
      expect(
        recorder.names,
        everyElement(isIn(AnalyticsService.allowedEvents)),
      );
      for (final (_, parameters) in recorder.events) {
        expect(parameters.values, everyElement(isA<int>()));
      }
    });

    test('the first result is recorded once, with seconds since first launch',
        () async {
      final (service, recorder, tick) =
          await started(saved: {AnalyticsService.enabledKey: true});
      service.chatReply(cards: 0); // an answer with no cards is not a result
      expect(recorder.names, ['chat_reply']);

      tick();
      service.chatReply(cards: 2);
      final first = recorder.events.where((e) => e.$1 == 'first_result');
      expect(first, hasLength(1));
      expect(first.single.$2, {'seconds': 42});

      tick();
      service.chatReply(cards: 4);
      expect(recorder.names.where((n) => n == 'first_result'), hasLength(1));
    });

    test('a sender that fails never reaches the traveler', () async {
      SharedPreferences.setMockInitialValues(
        {AnalyticsService.enabledKey: true},
      );
      final service = AnalyticsService(
        sender: (_, _) async => throw StateError('no network'),
        prefs: await SharedPreferences.getInstance(),
      );
      await service.start();
      service.placeAdded();
      await Future<void>.delayed(Duration.zero);
    });
  });

  group('TravelRepository events', () {
    Future<TravelRepository> repoWith(
      _Recorder recorder, {
      http.Client? client,
    }) async {
      final analytics = AnalyticsService(sender: recorder.send);
      await analytics.setEnabled(true);
      return TravelRepository(
        apiCatalog: client == null
            ? null
            : LakbayApiCatalogService(
                client: client,
                baseUrlOverride: 'https://api.test/api/v1',
              ),
        analytics: analytics,
      );
    }

    test('adding a place counts once; removing it counts nothing', () async {
      SharedPreferences.setMockInitialValues({});
      final recorder = _Recorder();
      final repo = await repoWith(recorder);
      repo.toggleTripBuilderStop(_mountApo);
      repo.toggleTripBuilderStop(_mountApo);
      expect(recorder.names, ['place_added']);
    });

    test('a new trip counts; saving the same trip again does not', () async {
      SharedPreferences.setMockInitialValues({});
      final recorder = _Recorder();
      final repo = await repoWith(recorder);
      final trip = repo.generateCustomTrip(
        destination: 'Dahican Surf Sanctuary',
        daysCount: 3,
        vibe: 'Beach',
      );
      repo.saveTripToMyTrips(trip);
      repo.saveTripToMyTrips(trip);
      expect(recorder.events, hasLength(1));
      expect(recorder.events.single.$1, 'trip_saved');
      expect(recorder.events.single.$2, {'days': 3});
    });

    test('finishing onboarding counts once', () async {
      SharedPreferences.setMockInitialValues({});
      final recorder = _Recorder();
      final repo = await repoWith(recorder);
      repo.completeOnboarding();
      repo.completeOnboarding();
      expect(recorder.names, ['onboarding_done']);
    });

    test('a chat answer counts its cards, never its text', () async {
      SharedPreferences.setMockInitialValues({});
      final recorder = _Recorder();
      final client = MockClient((request) async {
        if (request.url.path == '/api/v1/ai/chat/guest') {
          return http.Response(
            jsonEncode({
              'chat_response': 'Samal is a short barge ride away.',
              'model_id': 'test-model',
              'retrieved_context': [],
              'planning': {'input_revision': 1, 'intent': 'question'},
            }),
            200,
          );
        }
        return http.Response('[]', 200);
      });
      final repo = await repoWith(recorder, client: client);
      await repo.initialize();
      await repo.sendChatMessage('Is Samal far?');
      await repo.sendChatMessage('   '); // blank: no message, no event

      expect(recorder.events.where((e) => e.$1 == 'chat_reply'), hasLength(1));
      expect(
        recorder.events.singleWhere((e) => e.$1 == 'chat_reply').$2,
        {'cards': 0},
      );
      expect(jsonEncode(recorder.events.map((e) => e.$2).toList()),
          isNot(contains('Samal')));
    });
  });
}
