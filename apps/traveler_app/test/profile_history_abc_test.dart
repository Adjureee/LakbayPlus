import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:lakbay_travel/models/travel_models.dart';
import 'package:lakbay_travel/screens/home_chat_screen.dart';
import 'package:lakbay_travel/screens/profile_screen.dart';
import 'package:lakbay_travel/services/lakbay_api_catalog_service.dart';
import 'package:lakbay_travel/services/travel_repository.dart';
import 'package:lakbay_travel/widgets/user_avatar.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<TravelRepository> _repo(
  WidgetTester tester, {
  int chats = 2,
  Map<String, dynamic>? auth,
}) async {
  final sessions = [
    for (var i = 0; i < chats; i++)
      ChatSession(
        id: 'c$i',
        title: 'Chat number $i',
        groupLabel: 'Today',
        isTrip: false,
        createdAt: DateTime(2026, 11, 17),
        messages: [
          ChatMessage(
            id: 'm$i',
            isUser: true,
            text: 'hello $i',
            timestamp: DateTime(2026, 11, 17),
          ),
        ],
      ).toJson(),
  ];
  SharedPreferences.setMockInitialValues({
    'lakbay_traveler_state_v1': jsonEncode({
      'hasCompletedOnboarding': true,
      'profile': {'firstName': 'Maria', 'lastName': 'Santos'},
      'chatSessions': sessions,
      'activeChatId': 'c0',
    }),
  });
  final repo = TravelRepository(
    apiCatalog: LakbayApiCatalogService(baseUrlOverride: ''),
  );
  await tester.runAsync(() => repo.initialize());
  return repo;
}

void main() {
  setUp(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  group('repository history', () {
    testWidgets('delete one chat, undo puts it back', (tester) async {
      final repo = await _repo(tester);
      expect(repo.chatSessions.map((s) => s.id), ['c0', 'c1']);
      final removed = repo.deleteChatSession('c1')!;
      expect(repo.chatSessions.map((s) => s.id), ['c0']);
      repo.restoreChatSession(removed.session, removed.index);
      expect(repo.chatSessions.map((s) => s.id), ['c0', 'c1']);
    });

    testWidgets('deleting the open chat opens a blank one', (tester) async {
      final repo = await _repo(tester);
      repo.deleteChatSession('c0');
      expect(repo.chatMessages, isEmpty);
      expect(repo.activeChatId, isNot('c0'));
      expect(repo.chatSessions.any((s) => s.id == repo.activeChatId), isTrue);
    });

    testWidgets('clear all leaves one blank chat', (tester) async {
      final repo = await _repo(tester);
      repo.clearChatHistory();
      expect(repo.chatSessions.length, 1);
      expect(repo.chatSessions.single.messages, isEmpty);
      expect(repo.chatMessages, isEmpty);
    });
  });

  group('history drawer', () {
    Future<void> openDrawer(WidgetTester tester, TravelRepository repo) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(400, 800);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(home: HomeChatScreen(repo: repo)));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byTooltip('Chat History'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('New chat sits on top and the profile at the bottom', (
      tester,
    ) async {
      final repo = await _repo(tester);
      await openDrawer(tester, repo);
      final newChat = tester.getTopLeft(find.byKey(const ValueKey('drawer-new-chat')));
      final profile = tester.getTopLeft(find.byKey(const ValueKey('drawer-profile')));
      expect(newChat.dy, lessThan(profile.dy));
      expect(find.text('Maria Santos'), findsOneWidget);
      expect(find.byType(UserAvatar), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('swipe deletes a chat and Undo brings it back', (tester) async {
      final repo = await _repo(tester);
      await openDrawer(tester, repo);
      await tester.drag(
        find.byKey(const ValueKey('chat-tile-c1')),
        const Offset(-400, 0),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(repo.chatSessions.any((s) => s.id == 'c1'), isFalse);
      expect(find.text('Chat deleted'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('undo-delete')));
      await tester.pump();
      expect(repo.chatSessions.any((s) => s.id == 'c1'), isTrue);
    });

    testWidgets('Clear all asks first, then clears', (tester) async {
      final repo = await _repo(tester);
      await openDrawer(tester, repo);
      await tester.tap(find.byKey(const ValueKey('drawer-clear-all')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Clear all chats?'), findsOneWidget);
      expect(repo.chatSessions.length, 2);
      await tester.tap(find.byKey(const ValueKey('confirm-clear-all')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(repo.chatSessions.length, 1);
      expect(repo.chatSessions.single.messages, isEmpty);
    });
  });

  group('profile screen', () {
    Future<void> pumpProfile(WidgetTester tester, TravelRepository repo) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(400, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(home: ProfileScreen(repo: repo)));
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('no ACCOUNT section and no currency beside Settings', (
      tester,
    ) async {
      final repo = await _repo(tester);
      await pumpProfile(tester, repo);
      expect(find.text('ACCOUNT'), findsNothing);
      expect(find.text('PHP'), findsNothing);
      expect(find.text('Settings'), findsOneWidget);
    });

    testWidgets('a guest still has a way to sign in', (tester) async {
      final repo = await _repo(tester);
      expect(repo.isSignedIn, isFalse);
      await pumpProfile(tester, repo);
      expect(find.text('Create account / Sign in'), findsOneWidget);
    });
  });

  group('UserAvatar', () {
    testWidgets('is clipped to a circle, with the ring on top', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Center(
            child: UserAvatar(
              imageUrl: '',
              initials: 'MS',
              size: 66,
              ringWidth: 3,
            ),
          ),
        ),
      );
      expect(find.byType(ClipOval), findsOneWidget);
      expect(tester.getSize(find.byType(UserAvatar)), const Size(66, 66));
      expect(find.text('MS'), findsOneWidget);
    });
  });
}
