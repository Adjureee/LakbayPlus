import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lakbay_travel/models/timeline_models.dart';
import 'package:lakbay_travel/models/travel_models.dart';
import 'package:lakbay_travel/services/lakbay_api_catalog_service.dart';
import 'package:lakbay_travel/services/location_service.dart';
import 'package:lakbay_travel/services/travel_repository.dart';
import 'package:lakbay_travel/widgets/timeline_widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _place = {
  'destination_id': 77,
  'name': 'Hagimit Falls',
  'category': 'waterfall',
  'district': 'Davao del Norte',
  'location': 'Samal Island',
  'lat': 7.071,
  'lng': 125.735,
  'estimated_cost': '250.00',
  'stay_duration_type': 'half_day',
};

Map<String, dynamic> _item(
  String kind,
  String label, {
  String? start = '08:00:00',
  String? end = '09:00:00',
  int? minutes = 60,
  String basis = 'estimated',
  int? destinationId,
  Map<String, dynamic>? travel,
  List<Map<String, dynamic>> costs = const [],
  List<String> notes = const [],
}) => {
  'kind': kind,
  'day': 1,
  'starts_at': start,
  'ends_at': end,
  'duration_minutes': minutes,
  'time_basis': basis,
  'duration_basis': 'recorded',
  'label': label,
  'destination_id': destinationId,
  'travel': travel,
  'costs': costs,
  'booking': null,
  'notes': notes,
};

Map<String, dynamic> _timeline({bool conflict = false}) => {
  'days': [
    {
      'day': 1,
      'date': '2026-11-20',
      'items': [
        _item('travel', 'Travel to Hagimit Falls',
            start: '08:00:00', end: null, minutes: null, basis: 'provisional',
            travel: {
              'from_label': 'Davao City',
              'to_label': 'Hagimit Falls',
              'minutes': null,
              'basis': 'unknown',
              'mode': null,
              'route_verified': false,
            },
            notes: ['No travel time is available for this leg.']),
        _item('visit', 'Hagimit Falls',
            start: '08:00:00', end: '11:30:00', minutes: 210,
            destinationId: 77,
            costs: [
              {'label': 'Entrance', 'amount': '100.00', 'status': 'known',
               'scope': 'per_person', 'included_in': null},
              {'label': 'Zipline', 'amount': null, 'status': 'unknown',
               'scope': 'shared', 'included_in': null},
            ]),
        _item('visit', 'Museo Davao',
            start: '12:30:00', end: '13:30:00', destinationId: 88),
      ],
    },
  ],
  'conflicts': conflict
      ? [
          {
            'code': 'does_not_fit_hours',
            'destination_id': 88,
            'day': 1,
            'message': 'A 60-minute visit to Museo Davao does not fit its opening hours that day.',
            'choices': [
              'prioritise_places',
              'change_time_window',
              'relax_another_constraint',
            ],
          },
        ]
      : [],
  'checks': [
    {'id': 'chronological_order', 'status': 'passed', 'message': 'Items are in order.', 'destination_ids': []},
    {'id': 'travel_times', 'status': 'cannot_verify', 'message': '1 travel leg has no travel time.', 'destination_ids': []},
    {'id': 'opening_hours', 'status': conflict ? 'failed' : 'cannot_verify', 'message': 'Hours not confirmed.', 'destination_ids': [88]},
  ],
  'budget': {
    'known_total': '200.00',
    'estimated_total': '0.00',
    'unknown': ['Zipline (Hagimit Falls)'],
    'unbased': ['Catalog estimate (Museo Davao): about PHP 600'],
    'to_complete': ['Provide night_count before completing the estimate.'],
    'subtotal': '200.00',
    'complete': false,
    'total_budget': '5000.00',
    'remaining': null,
    'fit': 'undetermined',
    'notes': ['This is not the full trip cost: 1 cost(s) are unknown.'],
  },
  'feasible': !conflict,
  'unverified': ['1 travel leg has no travel time.'],
  'assumptions': ['The day starts at 8:00 (a planning default).'],
};

TravelRepository _repo(MockClient client) => TravelRepository(
  apiCatalog: LakbayApiCatalogService(
    baseUrlOverride: 'https://api.lakbay.test/api/v1',
    client: client,
  ),
  locationService: LocationService(
    customFetcher: () async =>
        const LocationResult(granted: false, statusMessage: 'Declined'),
  ),
);

Future<void> _show(WidgetTester tester, Widget child) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(900, 2400);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child))));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  // --- the models ---------------------------------------------------------------------

  test('times and durations read as the traveler would say them', () {
    expect(clockLabel('08:45:00'), '8:45 AM');
    expect(clockLabel('00:05:00'), '12:05 AM');
    expect(clockLabel('13:30:00'), '1:30 PM');
    expect(clockLabel(null), isNull);
    expect(durationLabel(45), '45 min');
    expect(durationLabel(80), '1 h 20 min');
    expect(durationLabel(120), '2 h');
    expect(durationLabel(null), isNull);
  });

  test('a timeline keeps unknowns unknown and round-trips the server JSON', () {
    final data = TimelineData.fromJson(_timeline());
    final travel = data.days.first.items.first;
    expect(travel.durationMinutes, isNull);
    expect(travel.travel!.minutes, isNull);
    expect(travel.timeRange, '8:00 AM');
    final visit = data.days.first.items[1];
    expect(visit.timeRange, '8:00 AM to 11:30 AM');
    expect(visit.costs[1].amount, isNull);
    expect(data.count('cannot_verify'), 2);
    expect(data.places.map((p) => p.id), [77, 88]);
    expect(data.budget.remaining, isNull);
    expect(data.toJson(), _timeline());
  });

  test('a chat message with a timeline survives saving and loading', () {
    final message = ChatMessage(
      id: 'm1',
      isUser: false,
      text: 'Here is your itinerary.',
      timestamp: DateTime(2026, 11, 18),
      timeline: TimelineData.fromJson(_timeline()),
    );
    final restored = ChatMessage.fromJson(
      jsonDecode(jsonEncode(message.toJson())) as Map<String, dynamic>,
    );
    expect(restored.timeline!.places.length, 2);
    expect(restored.timeline!.budget.unknown, ['Zipline (Hagimit Falls)']);
  });

  // --- the card and the screen --------------------------------------------------------

  testWidgets('the card shows status, check counts and an honest cost line', (tester) async {
    final repo = _repo(MockClient((_) async => http.Response('{}', 200)));
    await _show(
      tester,
      TimelineCard(timeline: TimelineData.fromJson(_timeline()), repo: repo),
    );
    expect(find.text('Works'), findsOneWidget);
    expect(find.text('1 day · 2 places'), findsOneWidget);
    expect(find.text('1 passed'), findsOneWidget);
    expect(find.text("2 can't verify"), findsOneWidget);
    final line = tester.widget<Text>(find.byKey(const ValueKey('timeline-budget-line')));
    expect(line.data, contains('Costs we know: ₱200'));
    expect(line.data, contains('Not the full cost: 1 cost is unknown'));
    expect(find.byKey(const ValueKey('timeline-open-trip')), findsNothing);
  });

  testWidgets('the timeline screen labels trust, unknown legs and unverifiable checks', (
    tester,
  ) async {
    final repo = _repo(MockClient((_) async => http.Response('{}', 200)));
    await _show(
      tester,
      TimelineCard(timeline: TimelineData.fromJson(_timeline()), repo: repo),
    );
    await tester.tap(find.byKey(const ValueKey('timeline-view')));
    await tester.pumpAndSettle();

    expect(find.text('Day 1 · 2026-11-20'), findsOneWidget);
    expect(find.textContaining('travel time unknown'), findsOneWidget);
    expect(find.text('Provisional'), findsOneWidget);
    // Expand the visit: the costs show unknown as unknown, never as free.
    await tester.tap(find.text('Hagimit Falls').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('Zipline: unknown'), findsOneWidget);
    expect(find.textContaining('Entrance: ₱100 per person'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('timeline-check-travel_times')), 400,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text("Can't verify: 1 travel leg has no travel time."), findsOneWidget);
    expect(find.textContaining('never counted as passed'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('timeline-budget')), 400,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Unknown costs (not in the subtotal):'), findsOneWidget);
    expect(find.textContaining('Zipline (Hagimit Falls)'), findsWidgets);
    expect(find.textContaining('no recorded basis'), findsOneWidget);
    expect(find.textContaining('Catalog estimate (Museo Davao)'), findsOneWidget);
    expect(find.text('To complete the estimate:'), findsOneWidget);
    expect(find.textContaining('Provide night_count'), findsOneWidget);
  });

  testWidgets('a conflict keeps the pick and offers the three choices', (tester) async {
    final repo = _repo(MockClient((_) async => http.Response('{}', 200)));
    await _show(
      tester,
      TimelineCard(timeline: TimelineData.fromJson(_timeline(conflict: true)), repo: repo),
    );
    expect(find.text('Has problems'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('timeline-view')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('timeline-conflict-card')), findsOneWidget);
    expect(find.textContaining('does not fit its opening hours'), findsOneWidget);
    expect(find.textContaining('Nothing has been removed'), findsOneWidget);
    for (final choice in const [
      'prioritise_places', 'change_time_window', 'relax_another_constraint',
    ]) {
      expect(find.byKey(ValueKey('timeline-choice-$choice')), findsOneWidget);
    }
    expect(find.text('Museo Davao'), findsWidgets);  // the pick is still listed
  });

  // --- revising -----------------------------------------------------------------------

  testWidgets('the revise sheet removes a place only when it is unticked', (tester) async {
    final calls = <Map<String, dynamic>>[];
    final repo = _repo(MockClient((request) async {
      final path = request.url.path.replaceFirst('/api/v1', '');
      if (path == '/planning/timeline') {
        calls.add(jsonDecode(request.body) as Map<String, dynamic>);
        return http.Response(
          jsonEncode({'timeline': _timeline(), 'changes': ['Museo Davao was removed.']}),
          200,
        );
      }
      if (path == '/destinations/facets') return http.Response('{"groups":[]}', 200);
      return http.Response('[]', 200);
    }));
    await tester.runAsync(repo.initialize);
    await _show(
      tester,
      TimelineCard(timeline: TimelineData.fromJson(_timeline()), repo: repo),
    );
    await tester.tap(find.byKey(const ValueKey('timeline-revise')));
    await tester.pumpAndSettle();

    expect(tester.widget<CheckboxListTile>(find.byKey(const ValueKey('revise-place-88'))).value, isTrue);
    await tester.tap(find.byKey(const ValueKey('revise-place-88')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('revise-days-plus')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('revise-apply')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pumpAndSettle();

    expect(calls, hasLength(1));
    final state = calls.single['state'] as Map<String, dynamic>;
    expect(state['day_count'], 2);
    expect(calls.single.containsKey('previous'), isFalse);  // nothing was revised before
  });

  // --- the planning flow --------------------------------------------------------------

  test('planWithPicks builds one timeline, keeps the trip and falls back when it cannot', () async {
    var timelineUp = true;
    final recorded = <({String path, Map<String, dynamic> body})>[];
    final client = MockClient((req) async {
      final path = req.url.path.replaceFirst('/api/v1', '');
      final body = req.body.isEmpty ? <String, dynamic>{} : jsonDecode(req.body) as Map<String, dynamic>;
      recorded.add((path: path, body: body));
      if (path == '/destinations/facets') return http.Response('{"groups":[]}', 200);
      if (path == '/destinations') return http.Response('[]', 200);
      if (path == '/ai/chat') {
        return http.Response(jsonEncode({
          'chat_response': 'Picked up details.', 'model_id': 'mock', 'ai_generation_run_id': 1,
          'planning': {
            'input_revision': 1, 'intent': 'show_places', 'suggested_replies': [],
            'state_updates': {}, 'update_status': 'applied',
            'preview': {'state': {
              ...(body['planning_state'] as Map<String, dynamic>),
              'day_count': 2, 'traveler_count': 3, 'total_budget': '2500.00',
              'budget_scope': 'per_person',
            }},
            'recommendations': [_place],
          },
        }), 200);
      }
      if (path == '/planning/timeline') {
        return timelineUp
            ? http.Response(jsonEncode({'timeline': _timeline(), 'changes': []}), 200)
            : http.Response('{"error":"down"}', 503);
      }
      return http.Response('{}', 200);
    });
    SharedPreferences.setMockInitialValues({
      'lakbay_traveler_state_v1': jsonEncode({
        'hasCompletedOnboarding': true,
        'authSession': const LakbayAuthSession(
          accessToken: 'token', refreshToken: 'refresh', userId: 1,
          fullName: 'Test Traveler', email: 't@example.com', role: 'traveler',
        ).toJson(),
      }),
    });
    final repo = _repo(client);
    await repo.initialize();
    await repo.sendChatMessage('3 travelers, 2 days, 2500 each');
    repo.toggleChatPick(
      repo.resolveExploreTripForRecommendation(TopPlaceRecommendation.fromJson(_place)),
    );

    await repo.planWithPicks();
    final message = repo.chatMessages.last;
    expect(message.timeline, isNotNull);
    expect(message.aiOptions, isEmpty);  // one itinerary, not five options
    expect(message.attachedTrip, isNotNull);  // opening and saving the trip still work
    expect(message.text, contains("2 details could not be confirmed"));
    expect(repo.lastTimeline, same(message.timeline));
    expect(recorded.any((r) => r.path == '/ai/itineraries/generate'), isFalse);
    final sent = recorded.lastWhere((r) => r.path == '/planning/timeline').body;
    expect((sent['state'] as Map)['destination_ids'], [77]);

    // The server cannot build it: the earlier flow still answers.
    timelineUp = false;
    await repo.planWithPicks();
    expect(recorded.any((r) => r.path == '/ai/itineraries/generate'), isTrue);

    // Revising sends the previous timeline back and names what moved.
    timelineUp = true;
    await repo.planWithPicks();
    final before = repo.lastTimeline!;
    await repo.reviseTimeline(const TimelineRevision(departureTime: '09:00:00', pace: 'relaxed'));
    final revised = recorded.lastWhere((r) => r.path == '/planning/timeline').body;
    expect((revised['state'] as Map)['departure_time'], '09:00:00');
    expect((revised['state'] as Map)['pace'], 'relaxed');
    expect(revised['previous'], before.toJson());
    expect(repo.chatMessages.last.text, startsWith('Nothing moved.'));
  });

  test('a failed revision says nothing changed and keeps the timeline', () async {
    var up = true;
    final client = MockClient((req) async {
      final path = req.url.path.replaceFirst('/api/v1', '');
      if (path == '/destinations/facets') return http.Response('{"groups":[]}', 200);
      if (path == '/destinations') return http.Response('[]', 200);
      if (path == '/planning/timeline') {
        return up
            ? http.Response(jsonEncode({'timeline': _timeline(), 'changes': []}), 200)
            : http.Response('{}', 503);
      }
      return http.Response('{}', 200);
    });
    final repo = _repo(client);
    await repo.initialize();
    final first = await repo.apiCatalog.fetchTimeline(null, planningState: {'destination_ids': [77]});
    expect(first, isNotNull);
    up = false;
    await repo.reviseTimeline(const TimelineRevision(dayCount: 3));
    final last = repo.chatMessages.last;
    expect(last.isError, isTrue);
    expect(last.text, contains('unchanged'));
    expect(last.timeline, isNull);
  });

  // --- saving the itinerary and its history ---------------------------------------------

  group('saving', () {
    late List<({String method, String path, Map<String, dynamic> body})> calls;
    late TravelRepository repo;
    var restoreDenied = false;

    Future<void> setUpSignedInRepo() async {
      calls = [];
      restoreDenied = false;
      final client = MockClient((req) async {
        final path = req.url.path.replaceFirst('/api/v1', '');
        final body = req.body.isEmpty
            ? <String, dynamic>{}
            : jsonDecode(req.body) as Map<String, dynamic>;
        calls.add((method: req.method, path: path, body: body));
        if (path == '/destinations/facets') return http.Response('{"groups":[]}', 200);
        if (path == '/destinations') return http.Response('[]', 200);
        if (path == '/ai/chat') {
          return http.Response(jsonEncode({
            'chat_response': 'Picked up details.', 'model_id': 'mock', 'ai_generation_run_id': 1,
            'planning': {
              'input_revision': 1, 'intent': 'show_places', 'suggested_replies': [],
              'state_updates': {}, 'update_status': 'applied',
              'preview': {'state': {
                ...(body['planning_state'] as Map<String, dynamic>),
                'day_count': 2, 'traveler_count': 3, 'total_budget': '2500.00',
                'budget_scope': 'per_person',
              }},
              'recommendations': [_place],
            },
          }), 200);
        }
        if (path == '/planning/timeline') {
          return http.Response(jsonEncode({'timeline': _timeline(), 'changes': []}), 200);
        }
        if (path == '/trips' && req.method == 'POST') {
          return http.Response(jsonEncode({'trip_id': 501}), 201);
        }
        if (path == '/trips/501/timeline' && req.method == 'POST') {
          final n = calls.where((c) => c.path == '/trips/501/timeline' && c.method == 'POST').length;
          return http.Response(jsonEncode({'revision': n}), 201);
        }
        if (path == '/trips/501/timeline/revisions/1/restore' && req.method == 'POST') {
          return restoreDenied
              ? http.Response(
                  jsonEncode({'error': {'code': 'trip_permission_denied', 'message': 'no'}}),
                  403,
                )
              : http.Response(jsonEncode({
                  'revision': 3,
                  'created_at': '2026-11-20T02:00:00Z',
                  'created_by_user_id': 1,
                  'changes': ['Restored revision 1.', 'Museo Davao now starts at 12:30 PM, not 1:00 PM.'],
                  'state': {
                    'destination_ids': [77, 88],
                    'departure_time': '08:00:00',
                    'day_count': 1,
                    'traveler_count': 3,
                    'pace': null,
                    'special_needs': [],
                    'origin': {'label': 'Davao City'},
                  },
                  'timeline': _timeline(),
                }), 201);
        }
        if (path == '/trips/501/timeline' && req.method == 'GET') {
          return http.Response(jsonEncode({
            'latest': null,
            'revisions': [
              {'revision': 2, 'created_at': '2026-11-19T02:00:00Z',
               'created_by_user_id': 1, 'changes': ['Museo Davao now starts at 1:00 PM, not 12:30 PM.']},
              {'revision': 1, 'created_at': '2026-11-18T02:00:00Z',
               'created_by_user_id': 1, 'changes': []},
            ],
          }), 200);
        }
        return http.Response('{}', 200);
      });
      SharedPreferences.setMockInitialValues({
        'lakbay_traveler_state_v1': jsonEncode({
          'hasCompletedOnboarding': true,
          'authSession': const LakbayAuthSession(
            accessToken: 'token', refreshToken: 'refresh', userId: 1,
            fullName: 'Test Traveler', email: 't@example.com', role: 'traveler',
          ).toJson(),
        }),
      });
      repo = _repo(client);
      await repo.initialize();
      await repo.sendChatMessage('3 travelers, 2 days, 2500 each');
      repo.toggleChatPick(
        repo.resolveExploreTripForRecommendation(TopPlaceRecommendation.fromJson(_place)),
      );
      await repo.planWithPicks();
    }

    Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 50));

    test('saving the trip also saves its timeline, and revising saves another revision', () async {
      await setUpSignedInRepo();
      expect(repo.timelineBackendTripId, isNull);  // not saved yet
      repo.saveTripToMyTrips(repo.chatMessages.last.attachedTrip!);
      await settle();

      Iterable<({String method, String path, Map<String, dynamic> body})> saves() =>
          calls.where((c) => c.path == '/trips/501/timeline' && c.method == 'POST');
      expect(repo.timelineBackendTripId, 501);
      expect(saves(), hasLength(1));
      // Only the planning state goes up: the server builds the timeline itself.
      expect(saves().first.body.keys, ['state']);
      expect((saves().first.body['state'] as Map)['destination_ids'], [77]);

      await repo.reviseTimeline(const TimelineRevision(departureTime: '09:00:00'));
      expect(saves(), hasLength(2));
      expect(((saves().last.body['state']) as Map)['departure_time'], '09:00:00');
    });

    test('a timeline that was never saved with a trip is not sent anywhere', () async {
      await setUpSignedInRepo();
      await repo.reviseTimeline(const TimelineRevision(pace: 'relaxed'));
      expect(calls.where((c) => c.path.startsWith('/trips/')), isEmpty);
      expect(await repo.loadTimelineHistory(), isNull);
    });

    test('a new plan from the picks starts a new, unsaved timeline', () async {
      await setUpSignedInRepo();
      repo.saveTripToMyTrips(repo.chatMessages.last.attachedTrip!);
      await settle();
      expect(repo.timelineBackendTripId, 501);
      await repo.planWithPicks();
      expect(repo.timelineBackendTripId, isNull);
    });

    testWidgets('the card offers History once the trip is saved and lists the revisions', (
      tester,
    ) async {
      await tester.runAsync(setUpSignedInRepo);
      final message = repo.chatMessages.last;
      await _show(tester, TimelineCard(timeline: message.timeline!, repo: repo));
      expect(find.byKey(const ValueKey('timeline-history')), findsNothing);

      await tester.runAsync(() async {
        repo.saveTripToMyTrips(message.attachedTrip!);
        await settle();
      });
      await _show(tester, TimelineCard(timeline: message.timeline!, repo: repo));
      await tester.tap(find.byKey(const ValueKey('timeline-history')));
      await tester.runAsync(settle);
      await tester.pumpAndSettle();

      expect(find.text('Itinerary history'), findsOneWidget);
      expect(find.textContaining('Revision 2'), findsOneWidget);
      expect(find.textContaining('Museo Davao now starts at 1:00 PM'), findsOneWidget);
      expect(find.text('First saved version'), findsOneWidget);
    });

    test('restoring an older revision puts the plan back and starts from it', () async {
      await setUpSignedInRepo();
      repo.saveTripToMyTrips(repo.chatMessages.last.attachedTrip!);
      await settle();
      // The plan has moved on since revision 1.
      await repo.reviseTimeline(const TimelineRevision(departureTime: '11:00:00', pace: 'relaxed'));
      final before = repo.chatMessages.length;

      expect(await repo.restoreTimelineRevision(1), isTrue);
      expect(calls.where((c) => c.path.endsWith('/restore')), hasLength(1));
      final message = repo.chatMessages.last;
      expect(repo.chatMessages.length, before + 1);  // announced, nothing removed
      expect(message.text, startsWith('Restored revision 1.'));
      expect(message.timeline, isNotNull);
      expect(repo.lastTimeline, same(message.timeline));
      expect(repo.timelineBackendTripId, 501);

      // The next revise starts from the restored plan, not the one that moved on.
      await repo.reviseTimeline(const TimelineRevision(dayCount: 2));
      final sent = calls.lastWhere((c) => c.path == '/planning/timeline').body['state'] as Map;
      expect(sent['departure_time'], '08:00:00');  // not 11:00:00
      expect(sent.containsKey('pace'), isFalse);  // dropped: it was null in revision 1
      expect(sent['destination_ids'], [77, 88]);
    });

    test('a refused restore says so and changes nothing', () async {
      await setUpSignedInRepo();
      repo.saveTripToMyTrips(repo.chatMessages.last.attachedTrip!);
      await settle();
      restoreDenied = true;
      final before = repo.lastTimeline;

      expect(await repo.restoreTimelineRevision(1), isFalse);
      final last = repo.chatMessages.last;
      expect(last.isError, isTrue);
      expect(last.text, contains('owner or an organizer'));
      expect(last.text, contains('unchanged'));
      expect(repo.lastTimeline, same(before));
    });

    test('there is nothing to restore for a timeline that was never saved', () async {
      await setUpSignedInRepo();
      expect(await repo.restoreTimelineRevision(1), isFalse);
      expect(calls.where((c) => c.path.endsWith('/restore')), isEmpty);
    });

    testWidgets('History offers Restore on older revisions only', (tester) async {
      await tester.runAsync(setUpSignedInRepo);
      final message = repo.chatMessages.last;
      await tester.runAsync(() async {
        repo.saveTripToMyTrips(message.attachedTrip!);
        await settle();
      });
      await _show(tester, TimelineCard(timeline: message.timeline!, repo: repo));
      await tester.tap(find.byKey(const ValueKey('timeline-history')));
      await tester.runAsync(settle);
      await tester.pumpAndSettle();

      expect(find.text('Current'), findsOneWidget);  // revision 2, the newest
      expect(find.byKey(const ValueKey('timeline-restore-2')), findsNothing);
      expect(find.byKey(const ValueKey('timeline-restore-1')), findsOneWidget);

      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('timeline-restore-1')));
        await settle();
      });
      await tester.pumpAndSettle();
      expect(calls.where((c) => c.path.endsWith('/revisions/1/restore')), hasLength(1));
      expect(repo.chatMessages.last.text, startsWith('Restored revision 1.'));
    });
  });
}
