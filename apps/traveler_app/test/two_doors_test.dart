import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:lakbay_travel/screens/my_trips_screen.dart';
import 'package:lakbay_travel/services/travel_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// F2 (docs/FLAGSHIP_UX_PLAN.md): a trip starts in one of two clearly named
/// ways, "Plan with Lakbay AI" (chat) or "Build my trip (no AI)" (from the
/// Discover picks). The My Trips "+" is the first; the Discover tray names both
/// in `trip_builder_flow_test.dart`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  testWidgets('the My Trips plus asks for the plan and hands it to the chat',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final repo = TravelRepository();
    repo.setActiveNavIndex(0);

    await tester.pumpWidget(MaterialApp(home: MyTripsScreen(repo: repo)));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.byTooltip('Plan a trip'));
    await tester.pumpAndSettle();

    expect(find.text('Plan a trip with Lakbay AI'), findsOneWidget);
    expect(find.text('Create Davao Region Trip'), findsNothing);

    await tester.enterText(
        find.widgetWithText(TextField, 'Where in the Davao Region?'), 'Samal');
    await tester.tap(find.text('Plan with Lakbay AI'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // The traveler lands in the chat with their request sent.
    expect(repo.activeNavIndex, 2);
    expect(
      repo.chatMessages.where((m) => m.isUser).map((m) => m.text),
      contains('Plan a 3-day Island Hopping & Highlands trip to Samal.'),
    );
  });
}
