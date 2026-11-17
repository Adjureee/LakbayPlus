import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lakbay_travel/design/design.dart';
import 'package:lakbay_travel/design/design_preview_screen.dart';

double _luminance(Color c) {
  double ch(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
}

double contrast(Color a, Color b) {
  final la = _luminance(a), lb = _luminance(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

Widget _host(Widget child, {bool disableAnimations = false}) => MaterialApp(
      theme: LakbayDesignTheme.dark,
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: disableAnimations),
        child: Scaffold(body: Center(child: child)),
      ),
    );

void main() {
  group('v8 color tokens meet WCAG AA for text', () {
    final pairs = <String, (Color, Color)>{
      'text on bg': (LkColors.text, LkColors.bg),
      'text on s3': (LkColors.text, LkColors.s3),
      'muted on bg': (LkColors.muted, LkColors.bg),
      'muted on s1': (LkColors.muted, LkColors.s1),
      'muted on s2': (LkColors.muted, LkColors.s2),
      'muted on s3': (LkColors.muted, LkColors.s3),
      'mangoInk on mango': (LkColors.mangoInk, LkColors.mango),
      'mango on s1': (LkColors.mango, LkColors.s1),
      'lagoon on bg': (LkColors.lagoon, LkColors.bg),
      'lagoon on s1': (LkColors.lagoon, LkColors.s1),
      'danger on s1': (LkColors.danger, LkColors.s1),
    };
    for (final MapEntry(key: name, value: (fg, bg)) in pairs.entries) {
      test(name, () => expect(contrast(fg, bg), greaterThanOrEqualTo(4.5)));
    }
  });

  testWidgets('theme uses mango as the action color on deep teal', (tester) async {
    final theme = LakbayDesignTheme.dark;
    expect(theme.brightness, Brightness.dark);
    expect(theme.colorScheme.primary, LkColors.mango);
    expect(theme.colorScheme.onPrimary, LkColors.mangoInk);
    expect(theme.scaffoldBackgroundColor, LkColors.bg);
  });

  testWidgets('LkIconButton is 48dp and labelled by its tooltip', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_host(
      LkIconButton(icon: Icons.notifications, tooltip: 'Notifications', onPressed: () {}),
    ));
    final size = tester.getSize(find.byType(LkIconButton));
    expect(size.width, greaterThanOrEqualTo(48));
    expect(size.height, greaterThanOrEqualTo(48));
    expect(find.bySemanticsLabel('Notifications'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('LkButton fires only when enabled and not loading', (tester) async {
    var taps = 0;
    await tester.pumpWidget(_host(Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        LkButton(label: 'Save trip', onPressed: () => taps++),
        LkButton(label: 'Busy', loading: true, onPressed: () => taps++),
        const LkButton(label: 'Off', onPressed: null),
      ],
    )));
    await tester.tap(find.text('Save trip'));
    await tester.tap(find.bySemanticsLabel('Busy'));
    await tester.tap(find.text('Off'));
    expect(taps, 1);
    expect(tester.getSize(find.byType(LkButton).first).height, greaterThanOrEqualTo(48));
  });

  testWidgets('LkMotion returns zero durations when animations are off', (tester) async {
    LkMotion.globallyEnabled = true;
    addTearDown(() => LkMotion.globallyEnabled = false);
    late LkMotion on, off;
    await tester.pumpWidget(_host(Builder(builder: (c) {
      on = LkMotion.of(c);
      return const SizedBox();
    })));
    await tester.pumpWidget(_host(disableAnimations: true, Builder(builder: (c) {
      off = LkMotion.of(c);
      return const SizedBox();
    })));
    expect(on.duration(LkMotion.base), LkMotion.base);
    expect(off.duration(LkMotion.base), Duration.zero);
  });

  testWidgets('showLkConfirm resolves true on confirm and false on cancel', (tester) async {
    final results = <bool>[];
    await tester.pumpWidget(_host(Builder(
      builder: (context) => TextButton(
        onPressed: () async => results.add(await showLkConfirm(
          context,
          title: 'Delete trip?',
          message: 'This removes the plan.',
          confirmLabel: 'Delete trip',
        )),
        child: const Text('open'),
      ),
    )));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete trip'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(results, [true, false]);
  });

  testWidgets('showLkUndoSnack calls onUndo when Undo is tapped', (tester) async {
    var undone = false;
    await tester.pumpWidget(_host(Builder(
      builder: (context) => TextButton(
        onPressed: () => showLkUndoSnack(
          context,
          message: 'Trip deleted',
          onUndo: () => undone = true,
        ),
        child: const Text('delete'),
      ),
    )));
    await tester.tap(find.text('delete'));
    await tester.pumpAndSettle();
    expect(find.text('Trip deleted'), findsOneWidget);
    await tester.tap(find.text('Undo'));
    expect(undone, isTrue);
  });

  testWidgets('LkFloatingNavBar announces tabs and reports selection', (tester) async {
    var selected = 0;
    await tester.pumpWidget(_host(StatefulBuilder(
      builder: (context, setState) => LkFloatingNavBar(
        items: const [
          LkNavItem(icon: Icons.luggage_outlined, selectedIcon: Icons.luggage, label: 'Trips'),
          LkNavItem(icon: Icons.forum_outlined, selectedIcon: Icons.forum, label: 'Chat'),
        ],
        currentIndex: selected,
        onSelected: (i) => setState(() => selected = i),
      ),
    )));
    expect(find.bySemanticsLabel('Chat, tab 2 of 2'), findsOneWidget);
    await tester.tap(find.text('Chat'));
    await tester.pump();
    expect(selected, 1);
  });

  testWidgets('undo snackbar sits above the floating tab bar', (tester) async {
    tester.view.physicalSize = const Size(390, 844) * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: LakbayDesignTheme.dark,
      home: Scaffold(
        extendBody: true,
        bottomNavigationBar: LkFloatingNavBar(
          items: const [
            LkNavItem(icon: Icons.luggage_outlined, selectedIcon: Icons.luggage, label: 'Trips'),
            LkNavItem(icon: Icons.forum_outlined, selectedIcon: Icons.forum, label: 'Chat'),
          ],
          currentIndex: 0,
          onSelected: (_) {},
        ),
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => showLkUndoSnack(context, message: 'Trip deleted', onUndo: () {}),
              child: const Text('delete'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('delete'));
    await tester.pumpAndSettle();
    final snackBottom = tester.getRect(find.byType(SnackBar)).bottom;
    final navTop = tester.getRect(find.byType(LkFloatingNavBar)).top;
    expect(snackBottom, lessThanOrEqualTo(navTop));
  });

  for (final scale in [1.0, 1.3]) {
    testWidgets('design preview lays out at ${scale}x text without overflow '
        'and meets tap-target guidelines', (tester) async {
      tester.view.physicalSize = const Size(390, 844) * 3;
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(
            size: const Size(390, 844),
            textScaler: TextScaler.linear(scale),
            disableAnimations: true,
          ),
          child: const DesignPreviewScreen(),
        ),
      ));
      await tester.pump();
      expect(tester.takeException(), isNull);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      handle.dispose();
    });
  }
}
