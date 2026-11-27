import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lakbay_travel/models/travel_models.dart';
import 'package:lakbay_travel/screens/home_chat_screen.dart';
import 'package:lakbay_travel/services/ai_chat_chip_helper.dart';
import 'package:lakbay_travel/services/lakbay_api_catalog_service.dart';
import 'package:lakbay_travel/services/location_service.dart';
import 'package:lakbay_travel/services/travel_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _ChatServer {
  _ChatServer(this.handler);

  final FutureOr<Map<String, dynamic>> Function(
    String path,
    Map<String, dynamic> body,
  ) handler;

  final requests = <({String path, Map<String, dynamic> body})>[];

  MockClient get client => MockClient((request) async {
        final path = request.url.path.replaceFirst('/api/v1', '');
        final body = request.body.isEmpty
            ? <String, dynamic>{}
            : jsonDecode(request.body) as Map<String, dynamic>;
        requests.add((path: path, body: body));
        if (path == '/destinations/facets') {
          return http.Response(
            jsonEncode({'total_places': 0, 'groups': []}),
            200,
          );
        }
        if (path == '/destinations') {
          return http.Response('[]', 200);
        }
        final reply = await handler(path, body);
        return http.Response(jsonEncode(reply), 200);
      });

  List<Map<String, dynamic>> get chatRequests => [
        for (final r in requests)
          if (r.path == '/ai/chat/guest') r.body,
      ];
}

TravelRepository _makeRepo(_ChatServer server) => TravelRepository(
      apiCatalog: LakbayApiCatalogService(
        baseUrlOverride: 'https://api.lakbay.test/api/v1',
        client: server.client,
      ),
      locationService: LocationService(
        customFetcher: () async => const LocationResult(
          granted: false,
          statusMessage: 'Declined',
        ),
      ),
    );

Map<String, dynamic> _chatResponse(
  Map<String, dynamic> body, {
  required String text,
  String intent = 'plan_trip',
  List<String> suggestedReplies = const [],
  List<String> missingDetails = const [],
  String? askNext,
  List<String> optionalDetails = const [],
}) =>
    {
      'chat_response': text,
      'model_id': 'mock',
      'ai_generation_run_id': 1,
      'planning': {
        'input_revision': 1,
        'intent': intent,
        'suggested_replies': suggestedReplies,
        'state_updates': {},
        'update_status': 'no_changes',
        'preview': {'state': body['planning_state']},
        'recommendations': [],
        if (missingDetails.isNotEmpty ||
            askNext != null ||
            optionalDetails.isNotEmpty)
          'conversation': {
            'stage': 'recommend',
            'missing_details': missingDetails,
            'ask_next': askNext,
            'optional_details': optionalDetails,
          },
      },
    };

void main() {
  setUp(() {
    GoogleFonts.config.allowRuntimeFetching = false;
    SharedPreferences.setMockInitialValues({});
  });

  group('AiChatChipHelper unit tests', () {
    test('buildStartDateChips produces Today, Tomorrow, This weekend with exact ISO dates', () {
      // Wednesday 2026-12-02 -> Saturday 2026-12-05
      final wed = DateTime(2026, 12, 2, 14, 30);
      final chips = AiChatChipHelper.buildStartDateChips(now: wed);
      expect(
        chips.map((c) => c.label).toList(),
        ['Today', 'Tomorrow', 'This weekend'],
      );
      expect(chips.any((c) => c.label == 'This month'), isFalse);
      expect(chips[0].value, '2026-12-02');
      expect(chips[1].value, '2026-12-03');
      expect(chips[2].value, '2026-12-05');
      expect(chips.every((c) => c.field == 'travel_start_date'), isTrue);

      // Sunday 2026-12-06 -> This weekend stays 2026-12-06
      final sun = DateTime(2026, 12, 6);
      final sunChips = AiChatChipHelper.buildStartDateChips(now: sun);
      expect(sunChips[2].value, '2026-12-06');
    });

    test('formatIsoDate and formatReadableDate format consistently', () {
      final date = DateTime(2026, 12, 5);
      expect(AiChatChipHelper.formatIsoDate(date), '2026-12-05');
      expect(AiChatChipHelper.formatReadableDate(date), 'Dec 5, 2026');
    });

    test('inferMissingDetailFromState mirrors conversation_stage.missing_details order', () {
      expect(AiChatChipHelper.inferMissingDetailFromState({}), 'interests');
      expect(
        AiChatChipHelper.inferMissingDetailFromState({
          'destination_ids': [1],
        }),
        'traveler_count',
      );
      expect(
        AiChatChipHelper.inferMissingDetailFromState({
          'interests': ['beaches'],
          'traveler_count': 2,
        }),
        'day_count',
      );
      expect(
        AiChatChipHelper.inferMissingDetailFromState({
          'interests': ['beaches'],
          'traveler_count': 2,
          'day_count': 3,
        }),
        'total_budget',
      );
      expect(
        AiChatChipHelper.inferMissingDetailFromState({
          'interests': ['beaches'],
          'traveler_count': 2,
          'day_count': 3,
          'total_budget': 5000,
        }),
        isNull,
      );
      expect(
        AiChatChipHelper.inferMissingDetailFromState(
          {
            'interests': ['nature_attractions'],
            'traveler_count': 2,
            'day_count': 3,
            'total_budget': 5000,
          },
          hasNatureInterest: true,
        ),
        'activity_level',
      );
      expect(
        AiChatChipHelper.inferMissingDetailFromState(
          {
            'interests': ['nature_attractions'],
            'traveler_count': 2,
            'day_count': 3,
            'total_budget': 5000,
            'activity_level': 'easy',
          },
          hasNatureInterest: true,
        ),
        'travel_start_date',
      );
      expect(
        AiChatChipHelper.inferMissingDetailFromState(
          {
            'interests': ['nature_attractions'],
            'traveler_count': 2,
            'day_count': 3,
            'total_budget': 5000,
            'activity_level': 'easy',
            'travel_start_date': '2026-12-05',
          },
          hasNatureInterest: true,
        ),
        'prefers_quiet',
      );
    });

    test('buildFreeQuestionQuickChips offers structured chips only for missing free details', () {
      expect(
        AiChatChipHelper.buildFreeQuestionQuickChips('traveler_count', {})
            .map((c) => (c.label, c.value))
            .toList(),
        [('Just me', 1), ('2 travelers', 2), ('4 travelers', 4)],
      );
      expect(
        AiChatChipHelper.buildFreeQuestionQuickChips('day_count', {})
            .map((c) => (c.label, c.value))
            .toList(),
        [('Day trip', 1), ('2 days', 2), ('3 days', 3)],
      );
      expect(
        AiChatChipHelper.buildFreeQuestionQuickChips('total_budget', {})
            .map((c) => (c.label, c.value))
            .toList(),
        [('₱1,500', 1500), ('₱3,000', 3000), ('₱5,000', 5000)],
      );
      expect(
        AiChatChipHelper.buildFreeQuestionQuickChips(
          'day_count',
          {'day_count': 2},
        ),
        isEmpty,
      );
    });

    test('isSafeUpdateFallbackMessage matches safe-update fallback copy', () {
      expect(
        AiChatChipHelper.isSafeUpdateFallbackMessage(
          "I couldn't safely update your plan from that response. Your current preview is shown below; try restating the change.",
        ),
        isTrue,
      );
      expect(
        AiChatChipHelper.isSafeUpdateFallbackMessage(
          'I couldn\u2019t safely update your plan from that response.',
        ),
        isTrue,
      );
      expect(
        AiChatChipHelper.isSafeUpdateFallbackMessage(
          'Here are 3 great waterfalls near Davao City.',
        ),
        isFalse,
      );
    });

    test('resolveSuggestedReplyDetail maps deterministic replies and preserves free text', () {
      final dayChip = AiChatChipHelper.resolveSuggestedReplyDetail(
        'Just a day trip',
        'day_count',
        {},
      );
      expect(dayChip?.field, 'day_count');
      expect(dayChip?.value, 1);

      final soloChip = AiChatChipHelper.resolveSuggestedReplyDetail(
        'Just me',
        'traveler_count',
        {},
      );
      expect(soloChip?.field, 'traveler_count');
      expect(soloChip?.value, 1);

      final budgetChip = AiChatChipHelper.resolveSuggestedReplyDetail(
        '₱3,000',
        'total_budget',
        {},
      );
      expect(budgetChip?.field, 'total_budget');
      expect(budgetChip?.value, 3000);

      expect(
        AiChatChipHelper.resolveSuggestedReplyDetail(
          'Check Samal beaches',
          'day_count',
          {},
        ),
        isNull,
      );
      expect(
        AiChatChipHelper.resolveSuggestedReplyDetail(
          'Just a day trip',
          'day_count',
          {'day_count': 2},
        ),
        isNull,
      );
    });
  });

  group('HomeChatScreen widget tests', () {
    testWidgets(
      'gates suggestedReplies to latest message and guards double-tap while isAiTyping',
      (tester) async {
        final session = ChatSession(
          id: 'c1',
          title: 'Trip',
          groupLabel: 'Today',
          isTrip: false,
          createdAt: DateTime(2026, 11, 27),
          messages: [
            ChatMessage(
              id: 'u1',
              isUser: true,
              text: 'Show me waterfalls',
              timestamp: DateTime(2026, 11, 27),
            ),
            ChatMessage(
              id: 'a1',
              isUser: false,
              text: 'First reply',
              timestamp: DateTime(2026, 11, 27),
              suggestedReplies: const ['Old chip'],
            ),
            ChatMessage(
              id: 'u2',
              isUser: true,
              text: 'Okay',
              timestamp: DateTime(2026, 11, 27),
            ),
            ChatMessage(
              id: 'a2',
              isUser: false,
              text: 'Second reply',
              timestamp: DateTime(2026, 11, 27),
              suggestedReplies: const ['New chip'],
            ),
          ],
        );
        SharedPreferences.setMockInitialValues({
          'lakbay_traveler_state_v1': jsonEncode({
            'hasCompletedOnboarding': true,
            'chatSessions': [session.toJson()],
            'activeChatId': 'c1',
          }),
        });

        final gate = Completer<void>();
        final server = _ChatServer((path, body) async {
          await gate.future;
          return _chatResponse(body, text: 'Got it!');
        });
        final repo = _makeRepo(server);
        await tester.runAsync(() => repo.initialize());

        await tester.pumpWidget(MaterialApp(home: HomeChatScreen(repo: repo)));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        expect(find.widgetWithText(ActionChip, 'Old chip'), findsNothing);
        expect(find.widgetWithText(ActionChip, 'New chip'), findsOneWidget);

        // First tap puts repo into isAiTyping == true while waiting on `gate`.
        await tester.tap(find.widgetWithText(ActionChip, 'New chip'));
        await tester.pump();

        expect(repo.isAiTyping, isTrue);
        expect(find.widgetWithText(ActionChip, 'New chip'), findsNothing);

        // Attempting to submit via keyboard/Send while typing is ignored.
        await tester.enterText(find.byType(TextField).first, 'Extra tap');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.tap(find.byTooltip('Send'));
        await tester.pump();

        expect(server.chatRequests, hasLength(1));

        await tester.runAsync(() async {
          gate.complete();
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));

        expect(repo.isAiTyping, isFalse);
        expect(find.text('Got it!'), findsOneWidget);
        expect(server.chatRequests, hasLength(1));
      },
    );

    testWidgets(
      'travel_start_date renders Today, Tomorrow, This weekend, Pick a date (never This month) and syncs planningStateView',
      (tester) async {
        final server = _ChatServer((path, body) {
          final msg = (body['message'] ?? '').toString();
          if (msg == 'I like waterfalls') {
            return _chatResponse(
              body,
              text: 'When are you travelling?',
              missingDetails: ['travel_start_date'],
              askNext: 'When are you travelling?',
            );
          }
          return _chatResponse(
            body,
            text: 'Noted for $msg!',
            missingDetails: ['travel_start_date'],
            askNext: 'When are you travelling?',
          );
        });
        final repo = _makeRepo(server);
        await tester.runAsync(() => repo.initialize());

        await tester.pumpWidget(MaterialApp(home: HomeChatScreen(repo: repo)));
        await tester.pump();

        await tester.enterText(find.byType(TextField).first, 'I like waterfalls');
        await tester.tap(find.text('Plan it'));
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        expect(find.text('Today'), findsOneWidget);
        expect(find.text('Tomorrow'), findsOneWidget);
        expect(find.text('This weekend'), findsOneWidget);
        expect(find.text('Pick a date'), findsOneWidget);
        expect(find.text('This month'), findsNothing);

        final now = DateTime.now();
        final today = DateTime(now.year, now.month, now.day);
        final tomorrow = today.add(const Duration(days: 1));
        final tomorrowIso = AiChatChipHelper.formatIsoDate(tomorrow);

        await tester.tap(find.text('Tomorrow'));
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(repo.planningStateView['travel_start_date'], tomorrowIso);
        expect(server.chatRequests.last['message'], 'Tomorrow');
        expect(
          (server.chatRequests.last['planning_state'] as Map)['travel_start_date'],
          tomorrowIso,
        );

        // Test Pick a date dialog flow.
        await tester.tap(find.text('Pick a date'));
        await tester.pumpAndSettle();

        expect(find.text('OK'), findsOneWidget);
        await tester.tap(find.text('OK'));
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        final todayIso = AiChatChipHelper.formatIsoDate(today);
        final todayReadable = AiChatChipHelper.formatReadableDate(today);
        expect(repo.planningStateView['travel_start_date'], todayIso);
        expect(server.chatRequests.last['message'], todayReadable);
      },
    );

    testWidgets(
      'activity_level and prefers_quiet structured chips update planningStateView cleanly',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(412, 915);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        var step = 0;
        final server = _ChatServer((path, body) {
          if (path != '/ai/chat/guest') return {};
          step++;
          if (step == 1) {
            return _chatResponse(
              body,
              text: 'How active do you want to be?',
              missingDetails: ['activity_level'],
              askNext: 'How active do you want to be?',
            );
          }
          if (step == 2) {
            return _chatResponse(
              body,
              text: 'Do you prefer quiet places or popular ones?',
              missingDetails: ['prefers_quiet'],
              askNext: 'Do you prefer quiet places or popular ones?',
            );
          }
          return _chatResponse(body, text: 'Great choices!');
        });
        final repo = _makeRepo(server);
        await tester.runAsync(() => repo.initialize());

        await tester.pumpWidget(MaterialApp(home: HomeChatScreen(repo: repo)));
        await tester.pump();

        await tester.enterText(find.byType(TextField).first, 'Nature trip');
        await tester.tap(find.text('Plan it'));
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        expect(find.text('Easy'), findsOneWidget);
        expect(find.text('Moderate'), findsOneWidget);
        expect(find.text('Challenging'), findsOneWidget);

        await tester.tap(find.text('Easy'));
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        expect(repo.planningStateView['activity_level'], 'easy');
        expect(server.chatRequests.last['message'], 'Easy');

        await tester.drag(find.byType(ListView), const Offset(0, -300));
        await tester.pumpAndSettle();

        expect(find.text('Quiet places'), findsOneWidget);
        expect(find.text('Popular is fine'), findsOneWidget);

        await tester.tap(find.text('Quiet places'));
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        expect(repo.planningStateView['prefers_quiet'], isTrue);
        expect(server.chatRequests.last['message'], 'Quiet places');
      },
    );

    testWidgets(
      'tapping Skip on What matters most hides the priority chip immediately',
      (tester) async {
        final server = _ChatServer((path, body) => _chatResponse(
              body,
              text: 'Here are some nature spots.',
              optionalDetails: ['priority_order'],
            ));
        final repo = _makeRepo(server);
        await tester.runAsync(() => repo.initialize());

        await tester.pumpWidget(MaterialApp(home: HomeChatScreen(repo: repo)));
        await tester.pump();

        await tester.enterText(find.byType(TextField).first, 'Waterfalls');
        await tester.tap(find.text('Plan it'));
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        expect(find.text('What matters most?'), findsOneWidget);

        await tester.tap(find.text('What matters most?'));
        await tester.pumpAndSettle();

        expect(find.text('Skip'), findsOneWidget);
        await tester.tap(find.text('Skip'));
        await tester.pumpAndSettle();

        // Chip vanishes immediately with no extra network turn.
        expect(find.text('What matters most?'), findsNothing);
        expect(server.chatRequests, hasLength(1));
      },
    );

    testWidgets(
      'safe-update fallback message renders Try again chip and resends prior user message',
      (tester) async {
        var calls = 0;
        final server = _ChatServer((path, body) {
          calls++;
          if (calls == 1) {
            return {
              'chat_response':
                  "I couldn't safely update your plan from that response. Your current preview is shown below; try restating the change.",
              'model_id': 'mock',
              'ai_generation_run_id': 1,
              'planning': {
                'input_revision': 1,
                'intent': 'plan_trip',
                'suggested_replies': [],
                'state_updates': {},
                'update_status': 'invalid_output',
                'preview': {'state': body['planning_state']},
                'recommendations': [],
              },
            };
          }
          return _chatResponse(body, text: 'Updated for 3 days!');
        });
        final repo = _makeRepo(server);
        await tester.runAsync(() => repo.initialize());

        await tester.pumpWidget(MaterialApp(home: HomeChatScreen(repo: repo)));
        await tester.pump();

        await tester.enterText(find.byType(TextField).first, 'Make it 3 days');
        await tester.tap(find.text('Plan it'));
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        expect(repo.chatMessages.last.isError, isFalse);
        expect(find.text('Try again'), findsOneWidget);

        await tester.tap(find.text('Try again'));
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        expect(server.chatRequests, hasLength(2));
        expect(server.chatRequests.last['message'], 'Make it 3 days');
        expect(find.text('Updated for 3 days!'), findsOneWidget);
      },
    );
  });
}
