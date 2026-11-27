import 'package:shared_preferences/shared_preferences.dart';

/// Sends one named event with simple number or short-text parameters.
typedef AnalyticsSender = Future<void> Function(
  String name,
  Map<String, Object> parameters,
);

/// Turns the underlying collection (analytics and crash reports) on or off.
typedef CollectionSwitch = Future<void> Function(bool enabled);

/// The few anonymous events the product team needs to see whether travelers
/// finish what they start (docs/FLAGSHIP_UX_PLAN.md, gates G2 and G3).
///
/// Privacy by construction: there is one method per event and each takes only
/// counts. Nothing here accepts free text, a name, an email, a place or a
/// position, so none of that can be sent by mistake. With no sender (tests, or
/// Firebase not set up) every call does nothing, and a failure to send never
/// reaches the traveler.
class AnalyticsService {
  AnalyticsService({
    this.sender,
    this.collectionSwitch,
    this.prefs,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  static const enabledKey = 'lakbay_analytics_enabled';
  static const firstLaunchKey = 'lakbay_first_launch_ms';
  static const firstResultKey = 'lakbay_first_result_sent';

  /// Every event name that may leave the phone.
  static const allowedEvents = {
    'onboarding_done',
    'place_added',
    'trip_saved',
    'chat_reply',
    'first_result',
  };

  final AnalyticsSender? sender;
  final CollectionSwitch? collectionSwitch;
  final SharedPreferences? prefs;
  final DateTime Function() _clock;

  bool _enabled = false;

  /// Off by default (opt-in) and switchable in Settings. Kept apart from the
  /// saved trips, so signing out or resetting the app does not change it.
  bool get enabled => _enabled;

  /// Reads the saved choice, remembers the first launch, and applies the choice
  /// to the underlying collection before anything is sent.
  Future<void> start() async {
    final store = prefs;
    _enabled = store?.getBool(enabledKey) ?? false;
    if (store != null && store.getInt(firstLaunchKey) == null) {
      await store.setInt(firstLaunchKey, _clock().millisecondsSinceEpoch);
    }
    await _applyCollection();
  }

  Future<void> setEnabled(bool value) async {
    _enabled = value;
    await prefs?.setBool(enabledKey, value);
    await _applyCollection();
  }

  Future<void> _applyCollection() async {
    try {
      await collectionSwitch?.call(_enabled);
    } catch (_) {
      // Reporting must never stop the app.
    }
  }

  // --- The events -------------------------------------------------------

  void onboardingDone() => _send('onboarding_done', const {});

  /// A traveler added a place to the trip they are building.
  void placeAdded() => _send('place_added', const {});

  /// A new trip was saved (not an edit of a saved one).
  void tripSaved({required int days}) =>
      _send('trip_saved', {'days': days.clamp(0, 60)});

  /// The assistant answered. [cards] counts the place cards and itinerary
  /// options in the answer. The first answer with cards also records how long
  /// after the first launch it came.
  void chatReply({required int cards}) {
    _send('chat_reply', {'cards': cards.clamp(0, 50)});
    if (cards > 0) _recordFirstResult();
  }

  void _recordFirstResult() {
    final store = prefs;
    if (!_enabled || store == null || store.getBool(firstResultKey) == true) {
      return;
    }
    final launched = store.getInt(firstLaunchKey);
    if (launched == null) return;
    final seconds =
        ((_clock().millisecondsSinceEpoch - launched) / 1000).round();
    _send('first_result', {'seconds': seconds < 0 ? 0 : seconds});
    store.setBool(firstResultKey, true);
  }

  void _send(String name, Map<String, Object> parameters) {
    final send = sender;
    if (!_enabled || send == null || !allowedEvents.contains(name)) return;
    send(name, parameters).catchError((Object _) {});
  }
}
