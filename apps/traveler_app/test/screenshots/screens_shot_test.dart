// Renders the main traveler screens at phone size and saves PNGs, for
// reviewing the redesign without a device. Skipped unless SHOTS_DIR is set:
//
//   SHOTS_DIR=/path/to/out flutter test test/screenshots
@Tags(['screenshots'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lakbay_travel/main.dart';
import 'package:lakbay_travel/models/travel_models.dart';
import 'package:lakbay_travel/screens/auth_screen.dart';
import 'package:lakbay_travel/screens/trip_detail_screen.dart';
import 'package:lakbay_travel/services/lakbay_api_catalog_service.dart';
import 'package:lakbay_travel/services/travel_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _outDir = Platform.environment['SHOTS_DIR'];
const _size = Size(412, 900);
const _ratio = 1.5;

Future<void> _loadIconFont() async {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root == null) return;
  final file = File(
    '$root/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
  );
  if (!file.existsSync()) return;
  final loader = FontLoader('MaterialIcons')
    ..addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
  await loader.load();
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pump(const Duration(milliseconds: 400));
  }
}

Future<void> _shot(WidgetTester tester, GlobalKey key, String name) async {
  await _settle(tester);
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: _ratio);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    File('$_outDir/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
  });
}

Future<TravelRepository> _repo({
  required bool signedIn,
  ChatSession? chat,
}) async {
  SharedPreferences.setMockInitialValues({
    'lakbay_traveler_state_v1': jsonEncode({
      'hasCompletedOnboarding': signedIn,
      if (chat != null) ...{
        'chatSessions': [chat.toJson()],
        'activeChatId': chat.id,
      },
      if (signedIn)
        'authSession': {
          'accessToken': 'shot-token',
          'refreshToken': 'r',
          'userId': 7,
          'fullName': 'Ana Reyes',
          'email': 'ana@example.com',
        },
    }),
  });
  return TravelRepository(
    apiCatalog: LakbayApiCatalogService(baseUrlOverride: ''),
  );
}

void main() {
  final skip = _outDir == null ? 'Set SHOTS_DIR to render screenshots' : null;

  testWidgets('screens', skip: skip != null, (tester) async {
    // flutter_test draws shadows as solid shapes; render them for real.
    debugDisableShadows = false;
    await tester.runAsync(_loadIconFont);
    tester.view
      ..physicalSize = _size * _ratio
      ..devicePixelRatio = _ratio;
    addTearDown(tester.view.reset);
    final key = GlobalKey();

    // Signed-out first launch.
    final fresh = await _repo(signedIn: false);
    await tester.runAsync(fresh.initialize);
    await tester.pumpWidget(
      RepaintBoundary(key: key, child: LakbayTravelApp(repository: fresh)),
    );
    await _shot(tester, key, '00_welcome');
    await tester.tap(find.text('Start planning'));
    await _shot(tester, key, '00b_onboarding_step');
    tester.state<NavigatorState>(find.byType(Navigator).first).push(
      MaterialPageRoute<void>(
        builder: (_) => AuthScreen(repo: fresh, initialRegisterMode: true),
      ),
    );
    await _shot(tester, key, '00c_auth');
    await tester.pumpWidget(const SizedBox());

    // Signed in, with a dated upcoming trip and an undated one.
    final repo = await _repo(signedIn: true);
    await tester.runAsync(repo.initialize);
    final today = DateTime.now();
    final samal = repo.generateCustomTrip(
      title: 'Samal Island Weekend',
      destination: 'Samal Island, Davao del Norte',
      daysCount: 3,
      vibe: 'Beaches & islands',
    );
    repo.saveTripToMyTrips(
      samal.copyWith(startDate: today.add(const Duration(days: 5))),
    );
    repo.saveTripToMyTrips(
      repo.generateCustomTrip(
        title: 'Mt. Apo Highlands',
        destination: 'Kapatagan, Davao del Sur',
        daysCount: 2,
        vibe: 'Mountains & nature',
      ),
    );
    final first = repo.savedTrips.last;
    final samalPlan = repo.savedTrips.first;

    await tester.pumpWidget(
      RepaintBoundary(key: key, child: LakbayTravelApp(repository: repo)),
    );
    const tabs = ['01_trips', '02_discover', '03_chat', '04_memories', '05_profile'];
    for (var i = 0; i < tabs.length; i++) {
      repo.setActiveNavIndex(i);
      await _shot(tester, key, tabs[i]);
    }

    repo.setActiveNavIndex(0);
    await tester.pump();
    final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
    nav.push(
      MaterialPageRoute<void>(
        builder: (_) => TripDetailScreen(repo: repo, trip: first),
      ),
    );
    await _shot(tester, key, '06_trip_detail');

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));

    // A chat thread with a plan.
    final now = DateTime.now();
    final chatRepo = await _repo(
      signedIn: true,
      chat: ChatSession(
        id: 'c1',
        title: 'Samal weekend',
        groupLabel: 'Today',
        isTrip: true,
        createdAt: now,
        messages: [
          ChatMessage(
            id: 'u1',
            isUser: true,
            text: 'Weekend sa Samal for 4 friends, beach and waterfalls, '
                'around ₱2,000 each.',
            timestamp: now,
          ),
          ChatMessage(
            id: 'a1',
            isUser: false,
            text: 'Here is a 3-day plan with ferries included.',
            timestamp: now,
            attachedTrip: samalPlan,
          ),
        ],
      ),
    );
    await tester.runAsync(chatRepo.initialize);
    chatRepo.setActiveNavIndex(2);
    await tester.pumpWidget(
      RepaintBoundary(key: key, child: LakbayTravelApp(repository: chatRepo)),
    );
    await _shot(tester, key, '07_chat_thread');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));    debugDisableShadows = true;
  });
}
