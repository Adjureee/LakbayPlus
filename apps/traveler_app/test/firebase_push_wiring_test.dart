import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lakbay_travel/models/travel_models.dart';
import 'package:lakbay_travel/services/lakbay_api_catalog_service.dart';
import 'package:lakbay_travel/services/location_service.dart';
import 'package:lakbay_travel/services/push_notification_service.dart';
import 'package:lakbay_travel/services/travel_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Calls {
  final registered = <String>[];
  final unregistered = <String>[];
  var notificationFetches = 0;

  MockClient get client => MockClient((request) async {
        final path = request.url.path.replaceFirst('/api/v1', '');
        if (path == '/notifications/device-tokens' && request.method == 'POST') {
          registered.add(
            (jsonDecode(request.body) as Map)['device_token'].toString(),
          );
          return http.Response('{"is_active":true}', 200);
        }
        if (path == '/notifications/device-tokens' && request.method == 'DELETE') {
          unregistered.add(request.url.queryParameters['device_token'] ?? '');
          return http.Response('{"deactivated":1}', 200);
        }
        if (path == '/notifications') {
          notificationFetches++;
          return http.Response('[]', 200);
        }
        if (path == '/notifications/unread-count') {
          return http.Response('{"unread_count":0}', 200);
        }
        return http.Response('[]', 200);
      });
}

Future<TravelRepository> _signedInRepo(
  _Calls calls,
  PushNotificationService push,
) async {
  SharedPreferences.setMockInitialValues({
    'lakbay_traveler_state_v1': jsonEncode({
      'hasCompletedOnboarding': true,
      'authSession': const LakbayAuthSession(
        accessToken: 'token',
        refreshToken: 'refresh',
        userId: 2,
        fullName: 'Push Tester',
        email: 'push@example.com',
        role: 'traveler',
      ).toJson(),
    }),
  });
  final repo = TravelRepository(
    apiCatalog: LakbayApiCatalogService(
      baseUrlOverride: 'https://api.lakbay.test/api/v1',
      client: calls.client,
    ),
    locationService: LocationService(
      customFetcher: () async => const LocationResult(
        granted: false,
        statusMessage: 'Declined',
      ),
    ),
    pushService: push,
  );
  await repo.initialize();
  // Registration runs in the background after sign-in.
  await Future<void>.delayed(const Duration(milliseconds: 50));
  return repo;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test("the device's token is registered with the server after sign-in", () async {
    final calls = _Calls();
    final repo = await _signedInRepo(
      calls,
      PushNotificationService(
        tokenFetcher: () async => 'fcm-device-token-1',
        platformResolver: () => 'android',
      ),
    );

    expect(calls.registered, contains('fcm-device-token-1'));
    repo.dispose();
  });

  test('a refreshed token is registered too', () async {
    final calls = _Calls();
    final refresh = StreamController<String>();
    final repo = await _signedInRepo(
      calls,
      PushNotificationService(
        tokenFetcher: () async => 'first-token',
        tokenRefreshStream: refresh.stream,
        platformResolver: () => 'android',
      ),
    );

    refresh.add('rotated-token');
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(calls.registered, containsAll(['first-token', 'rotated-token']));
    await refresh.close();
    repo.dispose();
  });

  test('tapping a push opens Trips and refreshes the notifications', () async {
    final calls = _Calls();
    final opened = StreamController<Map<String, dynamic>>();
    final repo = await _signedInRepo(
      calls,
      PushNotificationService(
        tokenFetcher: () async => 'tok',
        openedMessageStream: opened.stream,
        platformResolver: () => 'android',
      ),
    );
    repo.setActiveNavIndex(2); // the chat tab
    final before = calls.notificationFetches;

    opened.add({'event_type': 'trip_invitation', 'trip_id': '9'});
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(repo.activeNavIndex, 0);
    expect(calls.notificationFetches, greaterThan(before));
    await opened.close();
    repo.dispose();
  });

  test('a push that arrives while the app is open refreshes the bell', () async {
    final calls = _Calls();
    final foreground = StreamController<Map<String, dynamic>>();
    final repo = await _signedInRepo(
      calls,
      PushNotificationService(
        tokenFetcher: () async => 'tok',
        foregroundMessageStream: foreground.stream,
        platformResolver: () => 'android',
      ),
    );
    final before = calls.notificationFetches;

    foreground.add({'event_type': 'task_assigned'});
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(calls.notificationFetches, greaterThan(before));
    await foreground.close();
    repo.dispose();
  });

  test('signing out switches this device off on the server', () async {
    final calls = _Calls();
    final repo = await _signedInRepo(
      calls,
      PushNotificationService(
        tokenFetcher: () async => 'sign-out-token',
        platformResolver: () => 'android',
      ),
    );

    await repo.signOutBackend();

    expect(calls.unregistered, contains('sign-out-token'));
    repo.dispose();
  });

  test('without Firebase the service is a quiet no-op and nothing is registered', () async {
    final calls = _Calls();
    final repo = await _signedInRepo(calls, PushNotificationService());

    expect(calls.registered, isEmpty);
    expect(await PushNotificationService().fetchToken(), isNull);
    repo.dispose();
  });

  test('a denied notification permission (no token) registers nothing', () async {
    final calls = _Calls();
    final repo = await _signedInRepo(
      calls,
      PushNotificationService(tokenFetcher: () async => null),
    );

    expect(calls.registered, isEmpty);
    repo.dispose();
  });
}
