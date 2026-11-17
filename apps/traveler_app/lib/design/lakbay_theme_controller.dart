import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'lakbay_tokens.dart';

/// Which look the app uses: follow the phone, or force light or dark.
/// The choice is saved on the device.
class LkThemeController extends ChangeNotifier with WidgetsBindingObserver {
  LkThemeController._() {
    WidgetsBinding.instance.addObserver(this);
  }

  static final LkThemeController instance = LkThemeController._();

  static const _key = 'lakbay_theme_mode';

  ThemeMode _mode = ThemeMode.system;
  ThemeMode get mode => _mode;

  /// The brightness actually in use right now.
  Brightness get brightness => switch (_mode) {
    ThemeMode.light => Brightness.light,
    ThemeMode.dark => Brightness.dark,
    ThemeMode.system =>
      WidgetsBinding.instance.platformDispatcher.platformBrightness,
  };

  /// Reads the saved choice. Call once before `runApp`.
  Future<void> load() async {
    try {
      final saved = (await SharedPreferences.getInstance()).getString(_key);
      _mode = ThemeMode.values.firstWhere(
        (m) => m.name == saved,
        orElse: () => ThemeMode.system,
      );
    } catch (_) {
      _mode = ThemeMode.system;
    }
    _apply();
  }

  Future<void> setMode(ThemeMode mode) async {
    if (mode == _mode) return;
    _mode = mode;
    _apply();
    _rebuildEverything();
    notifyListeners();
    try {
      (await SharedPreferences.getInstance()).setString(_key, mode.name);
    } catch (_) {
      // Not saved: the choice still works until the app closes.
    }
  }

  @override
  void didChangePlatformBrightness() {
    if (_mode != ThemeMode.system) return;
    _apply();
    _rebuildEverything();
    notifyListeners();
  }

  void _apply() => LkColors.use(
    brightness == Brightness.dark ? LkPalette.dark : LkPalette.light,
  );

  /// Many widgets are `const` and read the colors directly, so a theme
  /// change must rebuild every element once (state is kept).
  void _rebuildEverything() {
    void visit(Element e) {
      e.markNeedsBuild();
      e.visitChildren(visit);
    }

    WidgetsBinding.instance.rootElement?.visitChildren(visit);
  }
}
