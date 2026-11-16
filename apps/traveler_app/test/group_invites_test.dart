import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lakbay_travel/models/travel_models.dart';
import 'package:lakbay_travel/services/lakbay_api_catalog_service.dart';
import 'package:lakbay_travel/services/location_service.dart';
import 'package:lakbay_travel/services/travel_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

typedef _Handler = http.Response Function(http.Request request, String path);

class _Api {
  _Api(this.handler);

  final _Handler handler;
  final calls = <({String method, String path, Map<String, dynamic> body})>[];

  MockClient get client => MockClient((request) async {
        final path = request.url.path.replaceFirst('/api/v1', '');
        final body = request.body.isEmpty
            ? <String, dynamic>{}
            : jsonDecode(request.body) as Map<String, dynamic>;
        calls.add((method: request.method, path: path, body: body));
        return handler(request, path);
      });

  int count(String method, String path) =>
      calls.where((c) => c.method == method && c.path == path).length;
}

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status);

const _invitation = {
  'trip_member_id': 5,
  'trip_id': 9,
  'trip_title': 'Samal Weekend',
  'role': 'member',
  'invited_by_name': 'Maria Santos',
  'invited_at': '2026-11-17T01:00:00Z',
};

Future<TravelRepository> _signedInRepo(_Api api) async {
  SharedPreferences.setMockInitialValues({
    'lakbay_traveler_state_v1': jsonEncode({
      'hasCompletedOnboarding': true,
      'authSession': const LakbayAuthSession(
        accessToken: 'token',
        refreshToken: 'refresh',
        userId: 2,
        fullName: 'Invited Friend',
        email: 'friend@example.com',
        role: 'traveler',
      ).toJson(),
    }),
  });
  final repo = TravelRepository(
    apiCatalog: LakbayApiCatalogService(
      baseUrlOverride: 'https://api.lakbay.test/api/v1',
      client: api.client,
    ),
    locationService: LocationService(
      customFetcher: () async => const LocationResult(
        granted: false,
        statusMessage: 'Declined',
      ),
    ),
  );
  await repo.initialize();
  return repo;
}

_Api _server({List<Map<String, dynamic>> invitations = const [_invitation]}) {
  late _Api api;
  api = _Api((request, path) {
    switch ((request.method, path)) {
      case ('GET', '/trips/invitations'):
        return _json(invitations);
      case ('GET', '/notifications'):
        return _json([
          {
            'notification_id': 1,
            'trip_id': 9,
            'trip_title': 'Samal Weekend',
            'event_type': 'trip_invitation',
            'title': 'Trip invitation',
            'message': 'Maria Santos invited you to join Samal Weekend.',
            'is_read': false,
            'created_at': '2026-11-17T01:00:00Z',
          },
        ]);
      case ('GET', '/notifications/unread-count'):
        return _json({'unread_count': 1});
      case ('POST', '/trips/9/invitation/accept'):
      case ('POST', '/trips/9/invitation/decline'):
        invitations = const [];
        return _json({'status': 'ok'});
      case ('GET', '/trips'):
        return _json([]);
    }
    return http.Response('{}', 404);
  });
  return api;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('invitations load with notifications, and the unread badge counts them', () async {
    final repo = await _signedInRepo(_server());

    await repo.refreshNotifications();

    expect(repo.invitations.single.tripTitle, 'Samal Weekend');
    expect(repo.invitations.single.invitedByName, 'Maria Santos');
    expect(repo.hasPendingInvitation(9), isTrue);
    expect(repo.hasPendingInvitation(10), isFalse);
    expect(repo.unreadNotificationCount, 1);
    expect(repo.notifications.single.eventType, 'trip_invitation');
  });

  test('accepting tells the server, clears the invitation, and refreshes trips', () async {
    final api = _server();
    final repo = await _signedInRepo(api);
    await repo.refreshNotifications();

    final ok = await repo.answerInvitation(9, accept: true);

    expect(ok, isTrue);
    expect(api.count('POST', '/trips/9/invitation/accept'), 1);
    expect(repo.hasPendingInvitation(9), isFalse);
    expect(api.count('GET', '/trips'), greaterThan(0)); // the trip is brought in
  });

  test('declining tells the server and does not bring the trip in', () async {
    final api = _server();
    final repo = await _signedInRepo(api);
    await repo.refreshNotifications();
    final tripFetchesBefore = api.count('GET', '/trips');

    final ok = await repo.answerInvitation(9, accept: false);

    expect(ok, isTrue);
    expect(api.count('POST', '/trips/9/invitation/decline'), 1);
    expect(repo.hasPendingInvitation(9), isFalse);
    expect(api.count('GET', '/trips'), tripFetchesBefore);
  });

  test('an invitation stays when the server cannot confirm the answer', () async {
    final api = _Api((request, path) {
      if (path == '/trips/invitations') return _json([_invitation]);
      if (path == '/notifications') return _json([]);
      if (path == '/notifications/unread-count') return _json({'unread_count': 0});
      return http.Response('{"error":{"message":"down"}}', 503);
    });
    final repo = await _signedInRepo(api);
    await repo.refreshNotifications();

    expect(await repo.answerInvitation(9, accept: true), isFalse);
    expect(repo.hasPendingInvitation(9), isTrue);
  });

  test('notifications are checked again on a timer, and stop when told to', () async {
    final api = _server();
    final repo = await _signedInRepo(api);

    repo.startNotificationPolling(interval: const Duration(milliseconds: 20));
    await Future<void>.delayed(const Duration(milliseconds: 110));
    repo.stopNotificationPolling();
    final polled = api.count('GET', '/trips/invitations');
    expect(polled, greaterThanOrEqualTo(2));

    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(api.count('GET', '/trips/invitations'), polled);
  });

  test('signing out forgets pending invitations', () async {
    final repo = await _signedInRepo(_server());
    await repo.refreshNotifications();
    expect(repo.invitations, isNotEmpty);

    await repo.signOutBackend();

    expect(repo.invitations, isEmpty);
  });

  group('username', () {
    _Api usernameApi({
      String current = 'friend',
      int patchStatus = 200,
      Object? patchBody,
    }) =>
        _Api((request, path) {
          if (path == '/users/me' && request.method == 'GET') {
            return _json({'user_id': 2, 'username': current});
          }
          if (path == '/users/me' && request.method == 'PATCH') {
            final wanted = (jsonDecode(request.body) as Map)['username'];
            return _json(patchBody ?? {'user_id': 2, 'username': wanted}, patchStatus);
          }
          return _json([]);
        });

    test('is loaded from the server and kept on the profile', () async {
      final repo = await _signedInRepo(usernameApi(current: 'trail_walker'));

      await repo.refreshUsername();

      expect(repo.profile.username, 'trail_walker');
      expect(repo.profile.toJson()['username'], 'trail_walker');
      expect(UserProfile.fromJson(repo.profile.toJson()).username, 'trail_walker');
    });

    test('saving sends it without the @ and stores what the server kept', () async {
      final api = usernameApi();
      final repo = await _signedInRepo(api);
      await repo.refreshUsername();

      final problem = await repo.saveUsername('@Trail_Walker');

      expect(problem, isNull);
      final patch = api.calls.lastWhere((c) => c.method == 'PATCH');
      expect(patch.body['username'], 'Trail_Walker');
      expect(repo.profile.username, 'Trail_Walker');
    });

    test('a taken username is refused with the server message and not saved', () async {
      final repo = await _signedInRepo(usernameApi(
        patchStatus: 409,
        patchBody: {
          'error': {'code': 'username_taken', 'message': 'That username is already taken.'},
        },
      ));
      await repo.refreshUsername();

      final problem = await repo.saveUsername('someone_else');

      expect(problem, 'That username is already taken.');
      expect(repo.profile.username, 'friend');
    });

    test('an invalid username explains the rule', () async {
      final repo = await _signedInRepo(usernameApi(patchStatus: 422, patchBody: {}));

      final problem = await repo.saveUsername('no');

      expect(problem, contains('3 to 30'));
    });

    test('an unchanged or empty username makes no request', () async {
      final api = usernameApi();
      final repo = await _signedInRepo(api);
      await repo.refreshUsername();
      final before = api.calls.length;

      expect(await repo.saveUsername('  '), isNull);
      expect(await repo.saveUsername('@friend'), isNull);

      expect(api.calls.length, before);
    });

    test('signed-out travelers are told to sign in', () async {
      SharedPreferences.setMockInitialValues({});
      final repo = TravelRepository(
        apiCatalog: LakbayApiCatalogService(baseUrlOverride: ''),
      );
      await repo.initialize();

      expect(await repo.saveUsername('someone'), 'Sign in to choose a username.');
    });

    test('losing the connection gives a retry message', () async {
      final api = _Api((request, path) {
        if (request.method == 'PATCH') throw http.ClientException('offline');
        return _json({'username': 'friend'});
      });
      final repo = await _signedInRepo(api);

      final problem = await repo.saveUsername('new_name');

      expect(problem, contains('try again'));
    });
  });

  group('inviting', () {
    LakbayApiCatalogService service(_Api api) => LakbayApiCatalogService(
          baseUrlOverride: 'https://api.lakbay.test/api/v1',
          client: api.client,
        );

    test('by username sends the username, and a pending member hides the email', () async {
      final api = _Api((request, path) => _json({
            'trip_member_id': 7,
            'trip_id': 9,
            'user_id': 3,
            'full_name': 'Trail Friend',
            'username': 'trailfriend',
            'email': null,
            'role': 'member',
            'status': 'invited',
          }, 201));

      final member = await service(api)
          .addTripMember('token', 9, username: '@trailfriend');

      final body = api.calls.single.body;
      expect(body['username'], '@trailfriend');
      expect(body.containsKey('email'), isFalse);
      expect(member!.isPending, isTrue);
      expect(member.username, 'trailfriend');
      expect(member.email, isEmpty);
    });

    test('by email sends the email only', () async {
      final api = _Api((request, path) => _json({
            'trip_member_id': 7, 'trip_id': 9, 'user_id': 3, 'full_name': 'A B',
            'email': null, 'role': 'member', 'status': 'invited',
          }, 201));

      await service(api).addTripMember('token', 9, email: 'a@example.com');

      final body = api.calls.single.body;
      expect(body['email'], 'a@example.com');
      expect(body.containsKey('username'), isFalse);
    });

    test("an unknown person gets the server's neutral message", () async {
      final api = _Api((request, path) => _json({
            'error': {
              'code': 'invitee_not_found',
              'message': "We couldn't find that person.",
            },
          }, 404));

      expect(
        () => service(api).addTripMember('token', 9, username: 'nobody'),
        throwsA(isA<LakbayApiException>().having(
          (e) => e.message, 'message', "We couldn't find that person.",
        )),
      );
    });

    test('search needs two characters and shows no emails', () async {
      final api = _Api((request, path) => _json([
            {'user_id': 3, 'username': 'trailfriend', 'full_name': 'Trail Friend'},
          ]));
      final catalog = service(api);

      expect(await catalog.searchUsers('token', 't'), isEmpty);
      expect(api.calls, isEmpty); // no request for a one-letter query

      final found = await catalog.searchUsers('token', 'trail');
      expect(found.single.username, 'trailfriend');
      expect(api.calls.single.path, '/users/search');
    });
  });
}
