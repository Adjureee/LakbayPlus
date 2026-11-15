import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import '../models/travel_models.dart';
import 'cloudinary_service.dart';
import 'google_auth_service.dart';
import 'lakbay_ai_service.dart';
import 'mapbox_service.dart';
import 'lakbay_api_catalog_service.dart';
import 'location_service.dart';

class TravelRepository extends ChangeNotifier {
  @override
  void dispose() {
    _liveSubscription?.cancel();
    super.dispose();
  }

  TravelRepository({
    LakbayApiCatalogService? apiCatalog,
    LocationService? locationService,
    GoogleAuthService? googleAuthService,
  })  : apiCatalog = apiCatalog ?? LakbayApiCatalogService(),
        locationService = locationService ?? LocationService(),
        googleAuthService = googleAuthService ?? GoogleAuthService();

  final MapboxService mapbox = MapboxService();
  late final LakbayAiService aiService = LakbayAiService(
    backend: apiCatalog,
    accessToken: () => _authSession?.accessToken,
  );
  final CloudinaryService cloudinary = CloudinaryService();
  final LakbayApiCatalogService apiCatalog;
  final LocationService locationService;
  final GoogleAuthService googleAuthService;

  bool _isAiTyping = false;
  bool get isAiTyping => _isAiTyping;

  MapboxStylePreset _activeMapStyle = MapboxStylePreset.outdoors;
  MapboxStylePreset get activeMapStyle => _activeMapStyle;

  void setMapboxStyle(MapboxStylePreset style) {
    if (_activeMapStyle == style) return;
    _activeMapStyle = style;
    notifyListeners();
  }

  void setMapboxToken(String token) {
    mapbox.setCustomToken(token);
    notifyListeners();
  }

  bool _isInitialized = false;
  bool get isInitialized => _isInitialized;

  bool _hasCompletedOnboarding = false;
  bool get hasCompletedOnboarding => _hasCompletedOnboarding;

  String _locale = 'en';
  String get locale => _locale;

  String _currency = 'PHP';
  String get currency => _currency;

  final Map<String, double> _currencyRates = {
    'PHP': 57.0,
    'USD': 1.0,
    'EUR': 0.92,
    'GBP': 0.79,
    'AUD': 1.52,
    'JPY': 153.0,
  };

  static const Map<String, String> _currencySymbols = {
    'PHP': '₱',
    'USD': '\$',
    'EUR': '€',
    'GBP': '£',
    'AUD': 'A\$',
    'JPY': '¥',
  };

  List<BackdropItem> _backdrops = [];
  List<BackdropItem> get backdrops => _backdrops;
  int _activeBackdropIndex = 0;
  int get activeBackdropIndex => _activeBackdropIndex;

  BackdropItem get currentBackdrop => _backdrops.isNotEmpty
      ? _backdrops[_activeBackdropIndex % _backdrops.length]
      : const BackdropItem(
          id: '01-samal-island',
          place: 'Samal Island',
          country: 'Davao Region',
          photographer: 'Lakbay+ Curated',
          unsplashUrl: '',
        );

  List<OnboardingStep> _onboardingSteps = [];
  List<OnboardingStep> get onboardingSteps => _onboardingSteps;

  final Map<String, ExploreTrip> _tripsById = {};
  List<ExploreTrip> _allTrips = [];
  List<ExploreTrip> get allTrips => _allTrips;

  ExploreTrip? _heroTrip;
  ExploreTrip? get heroTrip => _heroTrip;

  List<DiscoverySection> _discoverySections = [];
  List<DiscoverySection> get discoverySections => _discoverySections;

  List<CityDescription> _cityDescriptions = [];
  List<CityDescription> get cityDescriptions => _cityDescriptions;

  // User Preferences collected during Onboarding
  final Set<String> selectedVibes = {'beach', 'adventure', 'foodie'};
  final Set<String> selectedHelpNeeds = {
    'choose_where_to_go',
    'build_itinerary'
  };
  String travelCompanion = 'Couple';
  bool priceDropAlertsEnabled = true;
  bool locationSharingEnabled = true;
  double? _userLat;
  double? _userLng;
  double? get userLat => _userLat;
  double? get userLng => _userLng;
  bool get hasUserLocation => _userLat != null && _userLng != null;

  // ── Live location tracking ────────────────────────────────────────────────
  LivePosition? _livePosition;
  StreamSubscription<LivePosition>? _liveSubscription;
  int _liveTrackingClients = 0;

  /// Latest GPS fix while live tracking runs; null otherwise.
  LivePosition? get livePosition => _livePosition;
  bool get isLiveTracking => _liveSubscription != null;

  /// Starts following the device position. Reference counted, so each screen
  /// that calls this must call [stopLiveTracking] when it goes away. Returns
  /// false when location sharing is off or permission is not granted.
  Future<bool> startLiveTracking({bool navigation = false}) async {
    if (!locationSharingEnabled) return false;
    _liveTrackingClients++;
    if (_liveSubscription != null) return true;
    final allowed = await locationService.ensurePermission();
    if (!allowed || _liveTrackingClients == 0) {
      if (!allowed) _liveTrackingClients = math.max(0, _liveTrackingClients - 1);
      return false;
    }
    _liveSubscription = locationService
        .watchPosition(navigation: navigation)
        .listen(_onLivePosition, onError: (_) {});
    return true;
  }

  void stopLiveTracking() {
    if (_liveTrackingClients > 0) _liveTrackingClients--;
    if (_liveTrackingClients > 0) return;
    _liveSubscription?.cancel();
    _liveSubscription = null;
    _livePosition = null;
    notifyListeners();
  }

  void _onLivePosition(LivePosition position) {
    if (!locationSharingEnabled) return;
    _livePosition = position;
    // Routing uses the freshest position as its origin. Not persisted per fix;
    // the next regular save stores the last one.
    _userLat = position.lat;
    _userLng = position.lng;
    notifyListeners();
  }
  String temperatureUnit = 'C'; // 'C' or 'F'
  String preferredPaymentMethod = 'Set at checkout';
  String get travelerId =>
      _authSession != null ? 'usr_${_authSession!.userId}' : 'guest';

  // Saved Trips & Bucket List
  final List<ItineraryTrip> _savedTrips = [];
  List<ItineraryTrip> get savedTrips => List.unmodifiable(_savedTrips);

  final Set<String> _bucketListTripIds = {};
  Set<String> get bucketListTripIds => _bucketListTripIds;

  final Set<String> _bucketListCities = {
    'Island Garden City of Samal (IGaCoS)',
    'Mati City & Dahican Beach',
    'Buda (Marilog Pine Highlands)',
    'Tagum',
  };
  Set<String> get bucketListCities => _bucketListCities;

  // Explore Multi-Stop Trip Builder & Stateful AI Planning
  final List<ExploreTrip> _tripBuilderStops = [];
  List<ExploreTrip> get tripBuilderStops => List.unmodifiable(_tripBuilderStops);
  Map<String, dynamic>? _planningState;
  int _planningRevision = 0;

  bool isInTripBuilder(String exploreTripId) =>
      _tripBuilderStops.any((s) => s.id == exploreTripId);

  void toggleTripBuilderStop(ExploreTrip stop) {
    final idx = _tripBuilderStops.indexWhere((s) => s.id == stop.id);
    if (idx >= 0) {
      _tripBuilderStops.removeAt(idx);
    } else if (_tripBuilderStops.length < 8) {
      _tripBuilderStops.add(stop);
    }
    notifyListeners();
  }

  void clearTripBuilder() {
    if (_tripBuilderStops.isEmpty) return;
    _tripBuilderStops.clear();
    notifyListeners();
  }

  void resetPlanningState() {
    _planningState = null;
    _planningRevision = 0;
  }

  // AI Strict Budget & Route Mode Preferences
  bool strictBudgetFilter = false;
  String preferredTravelMode = 'driving'; // driving | public_transport | walking

  void setStrictBudgetFilter(bool value) {
    if (strictBudgetFilter == value) return;
    strictBudgetFilter = value;
    _scheduleSaveState();
    notifyListeners();
  }

  void setPreferredTravelMode(String mode) {
    if (preferredTravelMode == mode) return;
    preferredTravelMode = mode;
    _scheduleSaveState();
    notifyListeners();
  }

  // Trip Memories & Notifications (replacing deprecated Booking Basket)
  final List<TripMemoryItem> _memories = [];
  List<TripMemoryItem> get memories => List.unmodifiable(_memories);

  final List<AppNotificationItem> _notifications = [];
  List<AppNotificationItem> get notifications => List.unmodifiable(_notifications);
  int _unreadNotificationCount = 0;
  int get unreadNotificationCount => _unreadNotificationCount;

  // User Profile & Navigation State
  UserProfile _profile = const UserProfile();
  UserProfile get profile => _profile;

  int _activeNavIndex = 2; // 0: Trips, 1: Discover, 2: Chat (center), 3: Memories, 4: Profile
  int get activeNavIndex => _activeNavIndex;

  void setActiveNavIndex(int index) {
    if (_activeNavIndex == index) return;
    _activeNavIndex = index;
    notifyListeners();
  }

  void updateProfile({
    required String firstName,
    required String lastName,
    required String headline,
    required String location,
    required String email,
  }) {
    _profile = _profile.copyWith(
      firstName: firstName.trim().isEmpty ? _profile.firstName : firstName.trim(),
      lastName: lastName.trim().isEmpty ? _profile.lastName : lastName.trim(),
      headline: headline.trim(),
      location: location.trim(),
      email: email.trim(),
    );
    _scheduleSaveState();
    notifyListeners();
  }

  // Conversational AI Chat Sessions & Active Messages
  final List<ChatSession> _chatSessions = [];
  List<ChatSession> get chatSessions => List.unmodifiable(_chatSessions);
  String _activeChatId = 'chat_new';
  String get activeChatId => _activeChatId;

  final List<ChatMessage> _chatMessages = [];
  List<ChatMessage> get chatMessages => List.unmodifiable(_chatMessages);

  // Local persistence & optional cloud sync state
  SharedPreferences? _prefs;
  static const String _storageKey = 'lakbay_traveler_state_v1';
  LakbayAuthSession? _authSession;
  LakbayAuthSession? get authSession => _authSession;
  bool get isSignedIn =>
      _authSession != null && _authSession!.accessToken.isNotEmpty;

  bool _isSyncingCatalog = false;
  bool get isSyncingCatalog => _isSyncingCatalog;
  DateTime? _lastCatalogSyncAt;
  DateTime? get lastCatalogSyncAt => _lastCatalogSyncAt;

  final Map<int, List<HotelOffer>> _hotelRatesByDestId = {};
  final Map<int, List<AdminTransportRate>> _transportRatesByDestId = {};

  List<AdminTransportRate> transportRatesForDestination(int destId) =>
      List.unmodifiable(_transportRatesByDestId[destId] ?? const []);

  void _scheduleSaveState() {
    final prefs = _prefs;
    if (prefs == null) return;
    try {
      final payload = <String, dynamic>{
        'hasCompletedOnboarding': _hasCompletedOnboarding,
        'locale': _locale,
        'currency': _currency,
        'temperatureUnit': temperatureUnit,
        'priceDropAlertsEnabled': priceDropAlertsEnabled,
        'locationSharingEnabled': locationSharingEnabled,
        'userLat': ?_userLat,
        'userLng': ?_userLng,
        'preferredPaymentMethod': preferredPaymentMethod,
        'selectedVibes': selectedVibes.toList(),
        'travelCompanion': travelCompanion,
        'profile': _profile.toJson(),
        'bucketListTripIds': _bucketListTripIds.toList(),
        'bucketListCities': _bucketListCities.toList(),
        'savedTrips': _savedTrips.map((t) => t.toJson()).toList(),
        'memories': _memories.take(60).map((m) => m.toJson()).toList(),
        'strictBudgetFilter': strictBudgetFilter,
        'preferredTravelMode': preferredTravelMode,
        'chatSessions': _chatSessions.take(12).map((s) => s.toJson()).toList(),
        'activeChatId': _activeChatId,
        if (_authSession != null) 'authSession': _authSession!.toJson(),
      };
      prefs.setString(_storageKey, jsonEncode(payload));
    } catch (e) {
      debugPrint('Failed to persist Lakbay+ state: $e');
    }
  }

  void _restorePersistedState() {
    final raw = _prefs?.getString(_storageKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      _hasCompletedOnboarding =
          map['hasCompletedOnboarding'] as bool? ?? _hasCompletedOnboarding;
      final savedLocale = map['locale'] as String?;
      if (savedLocale != null && savedLocale.isNotEmpty) _locale = savedLocale;
      final savedCurrency = map['currency'] as String?;
      if (savedCurrency != null && _currencyRates.containsKey(savedCurrency)) {
        _currency = savedCurrency;
      }
      final savedTemp = map['temperatureUnit'] as String?;
      if (savedTemp == 'C' || savedTemp == 'F') temperatureUnit = savedTemp!;
      priceDropAlertsEnabled =
          map['priceDropAlertsEnabled'] as bool? ?? priceDropAlertsEnabled;
      locationSharingEnabled =
          map['locationSharingEnabled'] as bool? ?? locationSharingEnabled;
      _userLat = (map['userLat'] as num?)?.toDouble();
      _userLng = (map['userLng'] as num?)?.toDouble();
      preferredPaymentMethod =
          map['preferredPaymentMethod'] as String? ?? preferredPaymentMethod;

      final vibes = map['selectedVibes'] as List<dynamic>?;
      if (vibes != null) {
        selectedVibes
          ..clear()
          ..addAll(vibes.map((e) => e.toString()));
      }
      travelCompanion =
          map['travelCompanion'] as String? ?? travelCompanion;
      if (map['profile'] is Map<String, dynamic>) {
        _profile = UserProfile.fromJson(map['profile'] as Map<String, dynamic>);
      }
      final bucketTrips = map['bucketListTripIds'] as List<dynamic>?;
      if (bucketTrips != null) {
        _bucketListTripIds
          ..clear()
          ..addAll(bucketTrips.map((e) => e.toString()));
      }
      final bucketCities = map['bucketListCities'] as List<dynamic>?;
      if (bucketCities != null) {
        _bucketListCities
          ..clear()
          ..addAll(bucketCities.map((e) => e.toString()));
      }
      final savedTripsList = map['savedTrips'] as List<dynamic>?;
      if (savedTripsList != null) {
        _savedTrips
          ..clear()
          ..addAll(
            savedTripsList
                .whereType<Map<String, dynamic>>()
                .map(ItineraryTrip.fromJson),
          );
      }
      final memoriesList = map['memories'] as List<dynamic>?;
      if (memoriesList != null) {
        _memories
          ..clear()
          ..addAll(
            memoriesList
                .whereType<Map<String, dynamic>>()
                .map(TripMemoryItem.fromJson),
          );
      }
      strictBudgetFilter = map['strictBudgetFilter'] as bool? ?? false;
      final savedMode = map['preferredTravelMode'] as String?;
      if (savedMode == 'driving' ||
          savedMode == 'public_transport' ||
          savedMode == 'walking') {
        preferredTravelMode = savedMode!;
      }
      final sessionsList = map['chatSessions'] as List<dynamic>?;
      if (sessionsList != null && sessionsList.isNotEmpty) {
        _chatSessions
          ..clear()
          ..addAll(
            sessionsList
                .whereType<Map<String, dynamic>>()
                .map(ChatSession.fromJson),
          );
        final activeId = map['activeChatId'] as String?;
        if (activeId != null &&
            _chatSessions.any((s) => s.id == activeId)) {
          _activeChatId = activeId;
          _chatMessages
            ..clear()
            ..addAll(
              _chatSessions.firstWhere((s) => s.id == activeId).messages,
            );
        }
      }
      if (map['authSession'] is Map<String, dynamic>) {
        _authSession = LakbayAuthSession.fromJson(
          map['authSession'] as Map<String, dynamic>,
        );
      }
    } catch (e) {
      debugPrint('Failed to restore Lakbay+ persisted state: $e');
    }
  }

  void startNewChat() {
    final newId = 'chat_${DateTime.now().millisecondsSinceEpoch}';
    final session = ChatSession(
      id: newId,
      title: 'New Trip',
      groupLabel: 'Today',
      isTrip: false,
      createdAt: DateTime.now(),
      messages: const [],
    );
    _chatSessions.insert(0, session);
    _activeChatId = newId;
    _chatMessages.clear();
    resetPlanningState();
    notifyListeners();
  }

  void selectChatSession(String id) {
    final idx = _chatSessions.indexWhere((s) => s.id == id);
    if (idx < 0) return;
    _activeChatId = id;
    _chatMessages
      ..clear()
      ..addAll(_chatSessions[idx].messages);
    resetPlanningState();
    notifyListeners();
  }

  Future<void> initialize() async {
    if (_isInitialized) return;

    await Future.wait([
      _loadBackdrops(),
      _loadOnboarding(),
      _loadExploreTripsAndSections(),
      _loadDavaoEncyclopedia(),
    ]);

    try {
      _prefs ??= await SharedPreferences.getInstance();
      _restorePersistedState();
    } catch (_) {
      // Pure Dart / headless tests can skip SharedPreferences gracefully.
    }
    _seedInitialTripsAndChat();
    _isInitialized = true;
    notifyListeners();

    if (apiCatalog.isConfigured) {
      refreshFromApi();
      if (isSignedIn) {
        syncTripsFromBackend();
      }
    }
    refreshLiveFxRates();
    refreshCurrentLocationSilently();
  }

  /// Syncs live active destinations from `/api/v1/destinations`: upserts active
  /// records, updates details/images/prices, and removes deactivated `api_*` items.
  Future<void> refreshFromApi() async {
    final remoteTrips = await apiCatalog.fetchAllActiveDestinations();
    var changed = false;

    final remoteIds = remoteTrips.map((t) => t.id).toSet();
    final staleApiIds = _allTrips
        .where((t) => t.id.startsWith('api_') && !remoteIds.contains(t.id))
        .map((t) => t.id)
        .toList();
    if (staleApiIds.isNotEmpty) {
      _allTrips.removeWhere((t) => staleApiIds.contains(t.id));
      for (final staleId in staleApiIds) {
        _tripsById.remove(staleId);
      }
      changed = true;
    }

    for (final trip in remoteTrips) {
      final existing = _tripsById[trip.id];
      if (existing == null) {
        _tripsById[trip.id] = trip;
        _allTrips.insert(0, trip);
        changed = true;
      } else if (existing.title != trip.title ||
          existing.lat != trip.lat ||
          existing.lng != trip.lng ||
          existing.thumbnailUrl != trip.thumbnailUrl ||
          existing.estimatedCostPhp != trip.estimatedCostPhp ||
          existing.description != trip.description) {
        _tripsById[trip.id] = trip;
        final idx = _allTrips.indexWhere((t) => t.id == trip.id);
        if (idx >= 0) {
          _allTrips[idx] = trip;
        }
        changed = true;
      }
    }

    if (_heroTrip != null && _heroTrip!.id.startsWith('api_')) {
      final updatedHero = _tripsById[_heroTrip!.id];
      if (updatedHero != null) {
        _heroTrip = updatedHero.copyWith(tag: _heroTrip!.tag);
      }
    }

    _lastCatalogSyncAt = DateTime.now();
    if (changed) {
      notifyListeners();
    }
  }

  Future<int> syncCatalogWithApi() async {
    _isSyncingCatalog = true;
    notifyListeners();
    try {
      await Future.wait([
        refreshFromApi(),
        refreshLiveFxRates(),
        if (isSignedIn) syncTripsFromBackend(),
      ]);
      return _allTrips.where((t) => t.id.startsWith('api_')).length;
    } finally {
      _isSyncingCatalog = false;
      notifyListeners();
    }
  }

  Future<void> refreshLiveFxRates() async {
    final rates = await apiCatalog.fetchLiveUsdRates();
    if (rates == null || rates.isEmpty) return;
    _currencyRates.addAll(rates);
    notifyListeners();
  }

  Future<void> signInWithBackend({
    required String email,
    required String password,
  }) async {
    final session = await apiCatalog.login(email: email, password: password);
    _applyAuthSession(session);
    await syncTripsFromBackend();
  }

  Future<void> registerWithBackend({
    required String fullName,
    required String email,
    required String password,
    String? confirmPassword,
  }) async {
    final session = await apiCatalog.register(
      fullName: fullName,
      email: email,
      password: password,
      confirmPassword: confirmPassword,
    );
    _applyAuthSession(session);
  }

  Future<void> signInWithGoogleBackend() async {
    if (!apiCatalog.isConfigured) {
      throw const LakbayApiException(
        'Connect LAKBAY_API_BASE_URL in .env to authenticate with Google against your Lakbay+ account.',
      );
    }
    final idToken = await googleAuthService.requestGoogleIdToken();
    if (idToken == null || idToken.isEmpty) {
      throw const LakbayApiException('Google sign-in did not return a token.');
    }
    final session = await apiCatalog.googleLogin(idToken: idToken);
    _applyAuthSession(session);
    await syncTripsFromBackend();
  }

  void _clearUserSessionData() {
    _profile = const UserProfile();
    _savedTrips.clear();
    _bucketListTripIds.clear();
    _memories.clear();
    _notifications.clear();
    _unreadNotificationCount = 0;
    _chatMessages.clear();
    _chatSessions
      ..clear()
      ..add(
        ChatSession(
          id: 'chat_new',
          title: 'New Trip',
          groupLabel: 'Today',
          isTrip: false,
          createdAt: DateTime.now(),
          messages: const [],
        ),
      );
    _activeChatId = 'chat_new';
  }

  void _applyAuthSession(LakbayAuthSession session) {
    final switchingAccount =
        _authSession == null || _authSession!.userId != session.userId;
    if (switchingAccount) {
      _clearUserSessionData();
    }
    _authSession = session;
    final parts = session.fullName
        .trim()
        .split(RegExp(r'\s+'))
        .where((s) => s.isNotEmpty)
        .toList();
    _profile = _profile.copyWith(
      firstName: parts.isNotEmpty ? parts.first : 'Lakbay',
      lastName: parts.length > 1 ? parts.sublist(1).join(' ') : '',
      email: session.email,
    );
    _scheduleSaveState();
    notifyListeners();
  }

  Future<void> signOutBackend() async {
    final refreshToken = _authSession?.refreshToken ?? '';
    _authSession = null;
    _clearUserSessionData();
    await googleAuthService.signOut();
    if (refreshToken.isNotEmpty) {
      try {
        await apiCatalog.logout(refreshToken);
      } catch (_) {
        // Local sign-out still completes if the network request fails.
      }
    }
    _scheduleSaveState();
    notifyListeners();
  }

  Future<void> syncTripsFromBackend() async {
    if (!isSignedIn) return;
    final remoteRows = await apiCatalog.getMyTrips(_authSession!.accessToken);
    if (remoteRows.isEmpty) return;
    var updated = false;
    final phpRate = _currencyRates['PHP'] ?? 57.0;
    for (final row in remoteRows) {
      final tripId = (row['trip_id'] as num?)?.toInt();
      final title = (row['title'] ?? '').toString().trim();
      if (tripId == null || title.isEmpty) continue;
      if (_savedTrips.any((t) => t.backendTripId == tripId || t.id == 'cloud_$tripId')) {
        continue;
      }
      final estCostPhp =
          double.tryParse((row['estimated_total_cost'] ?? '0').toString()) ?? 0;
      final destIds = (row['destination_ids'] as List<dynamic>? ?? const [])
          .whereType<num>()
          .map((n) => n.toInt())
          .toList();
      ExploreTrip? matchedCatalog;
      if (destIds.isNotEmpty) {
        final primaryId = destIds.first;
        for (final exp in _allTrips) {
          if (exp.apiDestinationId == primaryId) {
            matchedCatalog = exp;
            break;
          }
        }
      }
      final detail = await apiCatalog.getTripDetail(
        _authSession!.accessToken,
        tripId,
      );
      final parsedDays = detail != null
          ? _parseCloudItineraryDays(detail['itinerary_days'], phpRate)
          : <ItineraryDay>[];
      final base = generateCustomTrip(
        id: 'cloud_$tripId',
        title: title,
        destination: row['description']?.toString() ?? title,
        daysCount: parsedDays.isNotEmpty ? parsedDays.length : 3,
        vibe: 'Cloud Synced Trip',
        heroAsset: matchedCatalog?.localAssetPath,
        centerLat: matchedCatalog?.lat,
        centerLng: matchedCatalog?.lng,
      );
      _savedTrips.add(
        ItineraryTrip(
          id: base.id,
          title: base.title,
          destination: row['description']?.toString() ?? base.destination,
          daysCount: parsedDays.isNotEmpty ? parsedDays.length : base.daysCount,
          adults: (row['traveler_count'] as num?)?.toInt() ?? 2,
          centerLat: base.centerLat,
          centerLng: base.centerLng,
          heroAsset: base.heroAsset,
          remoteImageUrl: matchedCatalog?.hasRemoteThumbnail == true
              ? matchedCatalog!.thumbnailUrl
              : null,
          vibeTag: base.vibeTag,
          overviewText: row['notes']?.toString() ??
              matchedCatalog?.description ??
              'Synced from your Lakbay+ cloud account (est. ₱${estCostPhp.toStringAsFixed(0)}, ~${(estCostPhp / phpRate).round()} USD).',
          bestMonths: matchedCatalog?.bestTimeToVisit ?? base.bestMonths,
          avgTemp: base.avgTemp,
          expertName: base.expertName,
          expertTip: matchedCatalog?.travelNotes ?? base.expertTip,
          days: parsedDays.isNotEmpty ? parsedDays : base.days,
          flights: const [],
          hotels: base.hotels,
          backendTripId: tripId,
          backendDestinationId: destIds.isNotEmpty ? destIds.first : null,
          backendDestinationIds: destIds,
          whatToBring: matchedCatalog?.whatToBring,
          entranceFee: matchedCatalog?.entranceFee,
          operatingHours: matchedCatalog?.operatingHours,
          isLocalOnly: true,
          backendEstimatedCostPhp: estCostPhp > 0 ? estCostPhp : null,
          backendBudgetPhp:
              double.tryParse((row['total_budget'] ?? '0').toString()),
        ),
      );
      updated = true;
    }
    if (updated) {
      _scheduleSaveState();
      notifyListeners();
    }
    await refreshNotifications();
    await refreshMemoriesForSavedTrips();
  }

  /// Fetches live accommodations, transport rates, and live weather for a trip's
  /// backend destination(s).
  Future<ItineraryTrip> loadLiveDetailsForTrip(ItineraryTrip trip) async {
    final destIds = trip.effectiveBackendDestinationIds;
    if (destIds.isEmpty || !apiCatalog.isConfigured) return trip;
    final destId = destIds.first;
    final phpRate = _currencyRates['PHP'] ?? 57.0;

    final ratesFuture = apiCatalog.fetchDestinationMarketRates(
      destId,
      city: trip.destination,
      fallbackImageAsset: trip.heroAsset,
      remoteImageUrl: trip.remoteImageUrl,
      lat: trip.centerLat,
      lng: trip.centerLng,
      phpPerUsd: phpRate,
    );
    final weatherFuture = isSignedIn
        ? apiCatalog.getCurrentWeather(
            _authSession!.accessToken,
            lat: trip.centerLat,
            lng: trip.centerLng,
          )
        : Future.value(null);

    final market = await ratesFuture;
    final weather = await weatherFuture;

    if (market.hotels.isNotEmpty) {
      _hotelRatesByDestId[destId] = market.hotels;
    }
    if (market.transports.isNotEmpty) {
      _transportRatesByDestId[destId] = market.transports;
    }

    final mergedHotels = market.hotels.isNotEmpty ? market.hotels : trip.hotels;

    final updatedDays = trip.days.map((d) {
      if (weather == null || d.dayNumber != 1) return d;
      return d.copyWith(
        tempCelsius: weather.tempC,
        wmoWeatherCode: weather.wmoCode,
      );
    }).toList();

    ExploreTrip? matchedCatalog;
    for (final exp in _allTrips) {
      if (exp.apiDestinationId == destId) {
        matchedCatalog = exp;
        break;
      }
    }

    final advisories = <String>[];
    if (isSignedIn) {
      final fb = await apiCatalog.evaluatePlanningFeedback(
        _authSession!.accessToken,
        state: {
          'destination_ids': destIds.take(10).toList(),
          'day_count': trip.daysCount.clamp(1, 30),
          'traveler_count': (trip.adults + trip.children).clamp(1, 100),
          if (trip.backendBudgetPhp != null && trip.backendBudgetPhp! > 0)
            'total_budget': trip.backendBudgetPhp!.toStringAsFixed(2),
          if (market.hotels.isNotEmpty &&
              market.hotels.first.apiAccommodationId != null)
            'selected_accommodation_ids': [
              market.hotels.first.apiAccommodationId!,
            ],
        },
        travelingWithChildren: trip.children > 0,
      );
      if (fb != null) {
        advisories.addAll(
          fb.findings
              .map((f) => f.message.trim())
              .where((m) => m.isNotEmpty),
        );
      }
    }

    final enriched = trip.copyWith(
      hotels: mergedHotels,
      avgTemp: weather != null
          ? '${weather.tempC}°C • ${weather.condition}'
          : null,
      wmoWeatherCode: weather?.wmoCode,
      days: updatedDays,
      whatToBring: trip.whatToBring ?? matchedCatalog?.whatToBring,
      advisories: advisories.isNotEmpty ? advisories : trip.advisories,
    );

    final savedIdx = _savedTrips.indexWhere((t) => t.id == trip.id);
    if (savedIdx >= 0) {
      _savedTrips[savedIdx] = enriched;
      _scheduleSaveState();
      notifyListeners();
    }
    return enriched;
  }

  /// [destinationIds] overrides the trip's stops, e.g. only the stops not yet
  /// reached when rerouting from the traveler's live position.
  Future<BackendRouteResult?> fetchRoadRouteForTrip(
    ItineraryTrip trip, {
    bool optimize = false,
    String? travelMode,
    List<int>? destinationIds,
  }) async {
    final destIds = destinationIds ?? trip.effectiveBackendDestinationIds;
    if (!isSignedIn || destIds.isEmpty || !apiCatalog.isConfigured) {
      return null;
    }
    final mode = travelMode ?? preferredTravelMode;
    final origin = _routeOriginFromUserLocation();
    if (optimize && destIds.length >= 2) {
      return apiCatalog.optimizeRoute(
        _authSession!.accessToken,
        destinationIds: destIds,
        travelMode: mode,
        origin: origin,
      );
    }
    return apiCatalog.previewRoute(
      _authSession!.accessToken,
      destinationIds: destIds,
      travelMode: mode,
      origin: origin,
    );
  }

  /// The traveler's GPS position as the route start, only when it is inside
  /// Region XI; a far-away origin cannot produce a meaningful Davao road route.
  GeoPoint? _routeOriginFromUserLocation() {
    final lat = _userLat;
    final lng = _userLng;
    if (lat == null || lng == null) return null;
    final insideRegion = lat >= MapboxService.davaoMinLat &&
        lat <= MapboxService.davaoMaxLat &&
        lng >= MapboxService.davaoMinLng &&
        lng <= MapboxService.davaoMaxLng;
    if (!insideRegion) return null;
    return GeoPoint(lat: lat, lng: lng, label: effectiveOriginLabel);
  }

  // ── Notifications ──────────────────────────────────────────────────────────

  Future<void> refreshNotifications() async {
    if (!isSignedIn || !apiCatalog.isConfigured) return;
    final items = await apiCatalog.fetchNotifications(_authSession!.accessToken);
    final unread = await apiCatalog.getUnreadNotificationCount(
      _authSession!.accessToken,
    );
    _notifications
      ..clear()
      ..addAll(items);
    _unreadNotificationCount = unread;
    notifyListeners();
  }

  Future<void> markNotificationRead(int notificationId) async {
    if (!isSignedIn || !apiCatalog.isConfigured) return;
    final ok = await apiCatalog.markNotificationRead(
      _authSession!.accessToken,
      notificationId,
    );
    if (!ok) return;
    for (int i = 0; i < _notifications.length; i++) {
      if (_notifications[i].notificationId == notificationId &&
          !_notifications[i].isRead) {
        _notifications[i] = _notifications[i].copyWith(isRead: true);
        if (_unreadNotificationCount > 0) _unreadNotificationCount--;
        break;
      }
    }
    notifyListeners();
  }

  Future<void> markAllNotificationsRead() async {
    if (!isSignedIn || !apiCatalog.isConfigured) return;
    final ok = await apiCatalog.markAllNotificationsRead(
      _authSession!.accessToken,
    );
    if (!ok) return;
    for (int i = 0; i < _notifications.length; i++) {
      _notifications[i] = _notifications[i].copyWith(isRead: true);
    }
    _unreadNotificationCount = 0;
    notifyListeners();
  }

  // ── Memories Album (Replaces Bookings) ─────────────────────────────────────

  Future<void> refreshMemoriesForSavedTrips() async {
    if (!isSignedIn || !apiCatalog.isConfigured) return;
    final merged = <TripMemoryItem>[];
    final seenIds = <int>{};
    for (final trip in _savedTrips) {
      final tid = trip.backendTripId;
      if (tid == null) continue;
      final list = await apiCatalog.listTripMemories(
        _authSession!.accessToken,
        tid,
      );
      for (final item in list) {
        if (seenIds.add(item.tripMemoryId)) {
          merged.add(item);
        }
      }
    }
    if (merged.isNotEmpty) {
      merged.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      _memories
        ..clear()
        ..addAll(merged);
      _scheduleSaveState();
      notifyListeners();
    }
  }

  Future<List<TripMemoryItem>> loadMemoriesForTrip(int backendTripId) async {
    if (!isSignedIn || !apiCatalog.isConfigured) {
      return _memories.where((m) => m.tripId == backendTripId).toList();
    }
    final items = await apiCatalog.listTripMemories(
      _authSession!.accessToken,
      backendTripId,
    );
    _memories.removeWhere((m) => m.tripId == backendTripId);
    _memories.insertAll(0, items);
    _memories.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    _scheduleSaveState();
    notifyListeners();
    return items;
  }

  Future<TripMemoryItem?> uploadAndAddMemory({
    required ItineraryTrip trip,
    required String localFilePath,
    String? caption,
    String? locationTag,
  }) async {
    var tripId = trip.backendTripId;
    if (isSignedIn && tripId == null && apiCatalog.isConfigured) {
      final destIds = trip.effectiveBackendDestinationIds;
      if (destIds.isNotEmpty) {
        final phpRate = _currencyRates['PHP'] ?? 57.0;
        tripId = await apiCatalog.createTrip(
          _authSession!.accessToken,
          title: trip.title,
          totalBudgetPhp:
              (trip.totalEstimatedCostUsd * phpRate).clamp(500, 9999999),
          estimatedTotalCostPhp:
              (trip.totalEstimatedCostUsd * phpRate).clamp(0, 9999999),
          destinationIds: destIds,
        );
        if (tripId != null) {
          updateTripDetails(trip.copyWith(backendTripId: tripId));
        }
      }
    }

    if (isSignedIn && tripId != null && apiCatalog.isConfigured) {
      final uploaded = await apiCatalog.uploadTripMemoryPhoto(
        _authSession!.accessToken,
        tripId,
        filePath: localFilePath,
      );
      if (uploaded != null && uploaded.imageUrl.isNotEmpty) {
        final created = await apiCatalog.createTripMemory(
          _authSession!.accessToken,
          tripId,
          imageUrl: uploaded.imageUrl,
          cloudinaryPublicId: uploaded.publicId,
          destinationId: trip.backendDestinationId,
          caption: caption,
          locationTag: locationTag ?? trip.destination,
        );
        if (created != null) {
          _memories.insert(0, created);
          _scheduleSaveState();
          notifyListeners();
          return created;
        }
      }
    }

    // Local device fallback when offline or guest
    final localMemory = TripMemoryItem(
      tripMemoryId: -DateTime.now().millisecondsSinceEpoch,
      tripId: tripId ?? 0,
      uploadedByFullName: _profile.fullName,
      destinationId: trip.backendDestinationId,
      destinationName: trip.title,
      imageUrl: trip.remoteImageUrl ?? '',
      localFilePath: localFilePath,
      caption: caption,
      locationTag: locationTag ?? trip.destination,
      createdAt: DateTime.now(),
    );
    _memories.insert(0, localMemory);
    _scheduleSaveState();
    notifyListeners();
    return localMemory;
  }

  Future<void> likeMemory(TripMemoryItem memory) async {
    final idx = _memories.indexWhere(
      (m) => m.tripMemoryId == memory.tripMemoryId,
    );
    if (idx < 0) return;
    _memories[idx] = TripMemoryItem(
      tripMemoryId: memory.tripMemoryId,
      tripId: memory.tripId,
      uploadedByFullName: memory.uploadedByFullName,
      destinationId: memory.destinationId,
      destinationName: memory.destinationName,
      imageUrl: memory.imageUrl,
      localFilePath: memory.localFilePath,
      caption: memory.caption,
      locationTag: memory.locationTag,
      likeCount: memory.likeCount + 1,
      commentCount: memory.commentCount,
      createdAt: memory.createdAt,
    );
    notifyListeners();
    if (isSignedIn && memory.tripMemoryId > 0 && memory.tripId > 0) {
      await apiCatalog.likeTripMemory(
        _authSession!.accessToken,
        memory.tripId,
        memory.tripMemoryId,
      );
    }
  }

  Future<void> deleteMemory(TripMemoryItem memory) async {
    _memories.removeWhere((m) => m.tripMemoryId == memory.tripMemoryId);
    _scheduleSaveState();
    notifyListeners();
    if (isSignedIn && memory.tripMemoryId > 0 && memory.tripId > 0) {
      await apiCatalog.deleteTripMemory(
        _authSession!.accessToken,
        memory.tripId,
        memory.tripMemoryId,
      );
    }
  }

  String formatPrice(num usdAmount) {
    final rate = _currencyRates[_currency] ?? 57.0;
    final symbol = _currencySymbols[_currency] ?? '₱';
    final converted = (usdAmount * rate).round();
    final formatted = converted.toString().replaceAllMapped(
          RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
          (Match m) => '${m[1]},',
        );
    return '$symbol$formatted';
  }

  void setLocale(String newLocale) {
    if (_locale == newLocale) return;
    _locale = newLocale;
    _rebuildLocaleSections();
    notifyListeners();
  }

  void setCurrency(String newCurrency) {
    if (!_currencyRates.containsKey(newCurrency)) return;
    _currency = newCurrency;
    _scheduleSaveState();
    notifyListeners();
  }

  String get currencyDisplayName => switch (_currency) {
        'PHP' => 'Philippine Peso (PHP)',
        'USD' => 'United States Dollar (USD)',
        'EUR' => 'Euro (EUR)',
        'GBP' => 'British Pound (GBP)',
        'AUD' => 'Australian Dollar (AUD)',
        'JPY' => 'Japanese Yen (JPY)',
        _ => _currency,
      };

  String get languageDisplayName => switch (_locale) {
        'en' => 'English',
        'fil' => 'Filipino',
        'ceb' => 'Cebuano / Bisaya',
        'es' => 'Español',
        'fr' => 'Français',
        _ => 'English',
      };

  int get preferencesCompletionPercent {
    var score = 0;
    if (selectedVibes.isNotEmpty) score += 40;
    if (travelCompanion.isNotEmpty) score += 30;
    if (_profile.location.isNotEmpty) score += 30;
    return score;
  }

  void setTemperatureUnit(String unit) {
    if (unit != 'C' && unit != 'F') return;
    temperatureUnit = unit;
    _scheduleSaveState();
    notifyListeners();
  }

  void setNotificationsEnabled(bool enabled) {
    priceDropAlertsEnabled = enabled;
    _scheduleSaveState();
    notifyListeners();
  }

  void setLocationSharingEnabled(bool enabled) {
    locationSharingEnabled = enabled;
    if (!enabled) {
      _userLat = null;
      _userLng = null;
      _liveSubscription?.cancel();
      _liveSubscription = null;
      _liveTrackingClients = 0;
      _livePosition = null;
    }
    _scheduleSaveState();
    notifyListeners();
  }

  Future<LocationResult> requestAndSaveCurrentLocation() async {
    final result = await locationService.captureCurrentLocation();
    if (result.granted && result.lat != null && result.lng != null) {
      _userLat = result.lat;
      _userLng = result.lng;
      locationSharingEnabled = true;
      final label = result.resolvedLabel?.trim() ?? '';
      if (label.isNotEmpty) {
        _profile = _profile.copyWith(location: label);
      }
    } else {
      locationSharingEnabled = false;
    }
    _scheduleSaveState();
    notifyListeners();
    return result;
  }

  void setPreferredPaymentMethod(String method) {
    preferredPaymentMethod = method;
    _scheduleSaveState();
    notifyListeners();
  }

  void toggleVibe(String vibe) {
    if (selectedVibes.contains(vibe)) {
      selectedVibes.remove(vibe);
    } else {
      selectedVibes.add(vibe);
    }
    _scheduleSaveState();
    notifyListeners();
  }

  void setTravelCompanion(String companion) {
    travelCompanion = companion;
    _scheduleSaveState();
    notifyListeners();
  }

  void resetAccountData() {
    _authSession = null;
    _clearUserSessionData();
    googleAuthService.signOut();
    _hasCompletedOnboarding = false;
    _activeNavIndex = 2;
    _prefs?.remove(_storageKey);
    notifyListeners();
  }

  void nextBackdrop() {
    if (_backdrops.isEmpty) return;
    _activeBackdropIndex = (_activeBackdropIndex + 1) % _backdrops.length;
    notifyListeners();
  }

  void selectBackdrop(int index) {
    if (index < 0 || index >= _backdrops.length) return;
    _activeBackdropIndex = index;
    notifyListeners();
  }

  void completeOnboarding() {
    _hasCompletedOnboarding = true;
    _scheduleSaveState();
    notifyListeners();
  }

  void restartOnboarding() {
    _hasCompletedOnboarding = false;
    _scheduleSaveState();
    notifyListeners();
  }

  bool isTripInBucketList(String tripId) => _bucketListTripIds.contains(tripId);

  void toggleBucketListTrip(String tripId) {
    if (_bucketListTripIds.contains(tripId)) {
      _bucketListTripIds.remove(tripId);
    } else {
      _bucketListTripIds.add(tripId);
    }
    _scheduleSaveState();
    notifyListeners();
  }

  bool isCityInBucketList(String city) => _bucketListCities.contains(city);

  void toggleBucketListCity(String city) {
    if (_bucketListCities.contains(city)) {
      _bucketListCities.remove(city);
    } else {
      _bucketListCities.add(city);
    }
    _scheduleSaveState();
    notifyListeners();
  }

  void saveTripToMyTrips(ItineraryTrip trip) {
    final existingIdx = _savedTrips.indexWhere((t) => t.id == trip.id);
    if (existingIdx >= 0) {
      _savedTrips[existingIdx] = trip;
    } else {
      _savedTrips.insert(0, trip);
    }
    _scheduleSaveState();
    notifyListeners();

    if (isSignedIn && trip.backendTripId == null) {
      if (trip.aiGenerationRunId != null && trip.aiOptionNumber != null) {
        apiCatalog
            .createTripFromAiOption(
              _authSession!.accessToken,
              generationRunId: trip.aiGenerationRunId!,
              optionNumber: trip.aiOptionNumber!,
              notes: trip.overviewText,
            )
            .then((cloudId) {
          if (cloudId == null) return;
          final idx = _savedTrips.indexWhere((t) => t.id == trip.id);
          if (idx >= 0) {
            _savedTrips[idx] = _savedTrips[idx].copyWith(backendTripId: cloudId);
            _scheduleSaveState();
            notifyListeners();
          }
        });
      } else if (trip.effectiveBackendDestinationIds.isNotEmpty) {
        final phpRate = _currencyRates['PHP'] ?? 57.0;
        final totalPhp =
            trip.backendEstimatedCostPhp ??
            (trip.totalEstimatedCostUsd * phpRate).clamp(100, 9999999).toDouble();
        apiCatalog
            .createTrip(
              _authSession!.accessToken,
              title: trip.title,
              description: trip.destination,
              travelerCount: trip.adults + trip.children,
              totalBudgetPhp: trip.backendBudgetPhp ?? totalPhp,
              estimatedTotalCostPhp: totalPhp,
              destinationIds: trip.effectiveBackendDestinationIds,
              notes: trip.overviewText,
              itineraryDays: _serializeItineraryDays(trip.days, phpRate),
            )
            .then((cloudId) {
          if (cloudId == null) return;
          final idx = _savedTrips.indexWhere((t) => t.id == trip.id);
          if (idx >= 0) {
            _savedTrips[idx] = _savedTrips[idx].copyWith(backendTripId: cloudId);
            _scheduleSaveState();
            notifyListeners();
          }
        });
      }
    }
  }

  void updateTripDetails(ItineraryTrip updated) {
    final idx = _savedTrips.indexWhere((t) => t.id == updated.id);
    if (idx >= 0) {
      _savedTrips[idx] = updated;
      _scheduleSaveState();
      notifyListeners();
    }
    if (isSignedIn && updated.backendTripId != null) {
      final phpRate = _currencyRates['PHP'] ?? 57.0;
      apiCatalog.updateTrip(
        _authSession!.accessToken,
        updated.backendTripId!,
        title: updated.title,
        travelerCount: updated.adults + updated.children,
        totalBudgetPhp:
            updated.backendBudgetPhp ?? (updated.totalEstimatedCostUsd * phpRate),
        estimatedTotalCostPhp:
            updated.backendEstimatedCostPhp ??
            (updated.totalEstimatedCostUsd * phpRate),
        notes: updated.overviewText,
      );
    }
  }

  void removeSavedTrip(String tripId) {
    final idx = _savedTrips.indexWhere((t) => t.id == tripId);
    final cloudId = idx >= 0 ? _savedTrips[idx].backendTripId : null;
    _savedTrips.removeWhere((t) => t.id == tripId);
    _scheduleSaveState();
    notifyListeners();
    if (isSignedIn && cloudId != null) {
      apiCatalog.deleteTrip(_authSession!.accessToken, cloudId);
    }
  }

  Future<ItineraryTrip> optimizeStopsForTrip(
    ItineraryTrip trip, {
    String? travelMode,
  }) async {
    if (trip.days.length <= 2) return trip;
    var reorderedDays = List<ItineraryDay>.from(trip.days);
    final destIds = trip.effectiveBackendDestinationIds;
    if (isSignedIn && destIds.length >= 2) {
      final optimized = await fetchRoadRouteForTrip(
        trip,
        optimize: true,
        travelMode: travelMode,
      );
      if (optimized != null && optimized.orderedDestinationIds.length >= 2) {
        final orderIndex = <int, int>{
          for (int i = 0; i < optimized.orderedDestinationIds.length; i++)
            optimized.orderedDestinationIds[i]: i,
        };
        reorderedDays.sort((a, b) {
          final ia = orderIndex[a.apiDestinationId] ?? a.dayNumber;
          final ib = orderIndex[b.apiDestinationId] ?? b.dayNumber;
          return ia.compareTo(ib);
        });
      }
    } else {
      // Nearest-neighbor Haversine route ordering from Day 1
      final remaining = List<ItineraryDay>.from(reorderedDays);
      final ordered = <ItineraryDay>[remaining.removeAt(0)];
      while (remaining.isNotEmpty) {
        final last = ordered.last;
        var bestIdx = 0;
        var bestDist = double.infinity;
        for (int i = 0; i < remaining.length; i++) {
          final d = _haversineKm(
            last.lat,
            last.lng,
            remaining[i].lat,
            remaining[i].lng,
          );
          if (d < bestDist) {
            bestDist = d;
            bestIdx = i;
          }
        }
        ordered.add(remaining.removeAt(bestIdx));
      }
      reorderedDays = ordered;
    }
    final normalized = [
      for (int i = 0; i < reorderedDays.length; i++)
        reorderedDays[i].copyWith(dayNumber: i + 1),
    ];
    final nextTrip = trip.copyWith(days: normalized, daysCount: normalized.length);
    updateTripDetails(nextTrip);
    return nextTrip;
  }

  Future<ItineraryTrip?> refineTripWithAi(
    ItineraryTrip trip,
    String instruction,
  ) async {
    final destIds = trip.effectiveBackendDestinationIds;
    final phpRate = _currencyRates['PHP'] ?? 57.0;
    if (isSignedIn && destIds.isNotEmpty && apiCatalog.isConfigured) {
      final generated = await apiCatalog.generateAiItineraries(
        _authSession!.accessToken,
        totalBudgetPhp:
            trip.backendBudgetPhp ??
            (trip.totalEstimatedCostUsd * phpRate).clamp(1500, 500000),
        travelerCount: (trip.adults + trip.children).clamp(1, 100),
        dayCount: trip.daysCount.clamp(1, 30),
        destinationIds: destIds,
        specialRequirements: instruction,
        travelStyle: instruction,
      );
      if (generated != null && generated.options.isNotEmpty) {
        final opt = _parseBackendAiOption(
          generated.options.first,
          generationRunId: generated.generationRunId,
          fallbackTrip: trip,
        );
        updateTripDetails(opt.trip);
        return opt.trip;
      }
    }
    if (aiService.isConfigured) {
      try {
        final aiRes = await aiService.chatOrPlan(
          userPrompt:
              'Refine my ${trip.daysCount}-day ${trip.destination} trip: $instruction',
          availableDestinations: _allTrips.map((e) => e.title).toList(),
          currentLocation: effectiveOriginLabel,
          userLat: _userLat,
          userLng: _userLng,
          preferredVibes: selectedVibes,
          strictBudget: strictBudgetFilter,
        );
        if (aiRes.hasStructuredItinerary) {
          final refined = _buildItineraryFromAi(aiRes).copyWith(
            backendTripId: trip.backendTripId,
            backendDestinationIds: trip.backendDestinationIds,
          );
          updateTripDetails(refined);
          return refined;
        }
      } catch (_) {}
    }
    return null;
  }

  Future<ItineraryTrip> buildMultiStopExploreTrip({
    int? daysCount,
    double? budgetPhp,
    int travelers = 2,
  }) async {
    final stops = List<ExploreTrip>.from(_tripBuilderStops);
    if (stops.isEmpty) {
      return generateCustomTrip(
        destination: 'Davao Region Highlights',
        daysCount: daysCount ?? 3,
        vibe: 'Curated Multi-Stop',
        includeFlights: false,
      );
    }
    final count = (daysCount ?? stops.length.clamp(2, 7)).clamp(1, 14);
    final destIds = stops
        .map((s) => s.apiDestinationId)
        .whereType<int>()
        .toList();
    final primary = stops.first;
    final avgBudgetPhp = budgetPhp ?? (count * 3800.0 * travelers);

    if (isSignedIn && destIds.isNotEmpty && apiCatalog.isConfigured) {
      final generated = await apiCatalog.generateAiItineraries(
        _authSession!.accessToken,
        totalBudgetPhp: avgBudgetPhp,
        travelerCount: travelers,
        dayCount: count,
        destinationIds: destIds,
      );
      if (generated != null && generated.options.isNotEmpty) {
        final opt = _parseBackendAiOption(
          generated.options.first,
          generationRunId: generated.generationRunId,
          preferredRemoteImageUrl:
              primary.hasRemoteThumbnail ? primary.thumbnailUrl : null,
          preferredHeroAsset: primary.localAssetPath,
          fallbackDestinationIds: destIds,
        );
        clearTripBuilder();
        return opt.trip;
      }
    }

    // Offline / guest multi-stop nearest-neighbor builder
    final ordered = <ExploreTrip>[stops.first];
    final pool = stops.skip(1).toList();
    while (pool.isNotEmpty) {
      final last = ordered.last;
      var bestIdx = 0;
      var bestDist = double.infinity;
      for (int i = 0; i < pool.length; i++) {
        final d = _haversineKm(last.lat, last.lng, pool[i].lat, pool[i].lng);
        if (d < bestDist) {
          bestDist = d;
          bestIdx = i;
        }
      }
      ordered.add(pool.removeAt(bestIdx));
    }

    final builtDays = <ItineraryDay>[];
    for (int i = 0; i < count; i++) {
      final stop = ordered[i % ordered.length];
      final cleanTitle = stop.title.split('—').first.trim();
      builtDays.add(
        ItineraryDay(
          dayNumber: i + 1,
          cityTitle: cleanTitle,
          summary: stop.description ??
              'Explore $cleanTitle in ${stop.regionName} and local scenic stops.',
          lat: stop.lat,
          lng: stop.lng,
          transportFromPrevious: i > 0 ? TransportMode.car : null,
          transportDuration: i > 0 ? '45m - 1h 30m scenic drive' : null,
          apiDestinationId: stop.apiDestinationId,
          stops: [
            ItineraryStop(
              time: '08:00 AM',
              title: 'Arrive & Explore $cleanTitle',
              description: stop.activities ??
                  stop.description ??
                  'Guided sightseeing and nature exploration.',
              category: stop.tag ?? 'Scenic',
              costEstimateUsd: (stop.estimatedCostPhp ?? 600) / 57.0,
              lat: stop.lat,
              lng: stop.lng,
            ),
            ItineraryStop(
              time: '12:30 PM',
              title: 'Local Davao Lunch & Rest',
              description:
                  'Enjoy regional Mindanao flavors and midday shade before afternoon activities.',
              category: 'Dining',
              costEstimateUsd: 12,
              lat: stop.lat + 0.004,
              lng: stop.lng - 0.004,
            ),
            ItineraryStop(
              time: '03:00 PM',
              title: 'Golden Hour Photo & Leisure',
              description:
                  stop.bestTimeToVisit ??
                  'Catch afternoon breeze before heading back or checking in nearby.',
              category: 'Experience',
              costEstimateUsd: 8,
              lat: stop.lat - 0.003,
              lng: stop.lng + 0.003,
            ),
          ],
        ),
      );
    }

    final tripTitle =
        '$count-Day ${ordered.map((s) => s.title.split('—').first.trim()).take(3).join(' + ')}';
    final result = ItineraryTrip(
      id: 'multi_${DateTime.now().millisecondsSinceEpoch}',
      title: tripTitle,
      destination: ordered.map((s) => s.regionName).toSet().join(' • '),
      daysCount: count,
      adults: travelers,
      centerLat: primary.lat,
      centerLng: primary.lng,
      heroAsset: primary.localAssetPath,
      remoteImageUrl: primary.hasRemoteThumbnail ? primary.thumbnailUrl : null,
      vibeTag: 'Multi-Stop Route',
      overviewText:
          'Custom $count-day Region XI route connecting ${ordered.map((s) => s.title.split('—').first.trim()).join(', ')}.',
      bestMonths: 'Dec – May (Dry Season)',
      avgTemp: '29°C',
      expertName: 'Lakbay+ Route Builder',
      expertTip: ordered
          .map((s) => s.travelNotes)
          .whereType<String>()
          .where((n) => n.isNotEmpty)
          .take(2)
          .join(' '),
      days: builtDays,
      flights: const [],
      hotels: _buildDavaoHotels(
        'multi',
        primary.regionName,
        primary.localAssetPath,
        primary.lat,
        primary.lng,
        remoteUrl: primary.hasRemoteThumbnail ? primary.thumbnailUrl : null,
      ),
      backendDestinationId: primary.apiDestinationId,
      backendDestinationIds: destIds,
      whatToBring: ordered
          .map((s) => s.whatToBring)
          .whereType<String>()
          .where((w) => w.isNotEmpty)
          .join(', '),
      isLocalOnly: true,
      backendBudgetPhp: avgBudgetPhp,
    );
    clearTripBuilder();
    return result;
  }

  double _haversineKm(double lat1, double lng1, double lat2, double lng2) {
    const r = 6371.0;
    final dLat = (lat2 - lat1) * math.pi / 180.0;
    final dLng = (lng2 - lng1) * math.pi / 180.0;
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1 * math.pi / 180.0) *
            math.cos(lat2 * math.pi / 180.0) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    return 2 * r * math.asin(math.sqrt(a));
  }

  List<Map<String, dynamic>> _serializeItineraryDays(
    List<ItineraryDay> days,
    double phpRate,
  ) {
    return [
      for (final d in days)
        {
          'day_number': d.dayNumber,
          'title': d.cityTitle,
          'summary': d.summary,
          'activities': [
            for (int i = 0; i < d.stops.length; i++)
              {
                'activity_order': i + 1,
                'time': d.stops[i].time,
                'title': d.stops[i].title,
                'description': d.stops[i].description,
                if (d.apiDestinationId != null)
                  'destination_id': d.apiDestinationId,
                'estimated_cost':
                    (d.stops[i].costEstimateUsd * phpRate).toStringAsFixed(2),
              },
          ],
        },
    ];
  }

  List<ItineraryDay> _parseCloudItineraryDays(dynamic raw, double phpRate) {
    if (raw is! List) return const [];
    final days = <ItineraryDay>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final dayNum = (item['day_number'] as num?)?.toInt() ?? (days.length + 1);
      final title = (item['title'] ?? 'Day $dayNum').toString();
      final summary = (item['summary'] ?? '').toString();
      final rawActs = item['activities'] as List<dynamic>? ?? const [];
      final stops = <ItineraryStop>[];
      int? dayDestId;
      double? dayLat;
      double? dayLng;
      for (final act in rawActs) {
        if (act is! Map) continue;
        final dId = (act['destination_id'] as num?)?.toInt();
        dayDestId ??= dId;
        ExploreTrip? match;
        if (dId != null) {
          for (final exp in _allTrips) {
            if (exp.apiDestinationId == dId) {
              match = exp;
              break;
            }
          }
        }
        dayLat ??= match?.lat;
        dayLng ??= match?.lng;
        final costPhp =
            double.tryParse((act['estimated_cost'] ?? '0').toString()) ?? 0.0;
        stops.add(
          ItineraryStop(
            time: (act['time'] ?? '09:00 AM').toString(),
            title: (act['title'] ?? 'Activity').toString(),
            description: (act['description'] ?? '').toString(),
            category: match?.tag ?? 'Activity',
            costEstimateUsd: costPhp / phpRate,
            lat: match?.lat ?? MapboxService.davaoCenterLat,
            lng: match?.lng ?? MapboxService.davaoCenterLng,
          ),
        );
      }
      days.add(
        ItineraryDay(
          dayNumber: dayNum,
          cityTitle: title,
          summary: summary,
          lat: dayLat ?? MapboxService.davaoCenterLat,
          lng: dayLng ?? MapboxService.davaoCenterLng,
          transportFromPrevious: dayNum > 1 ? TransportMode.car : null,
          transportDuration: dayNum > 1 ? 'Scenic transfer' : null,
          apiDestinationId: dayDestId,
          stops: stops,
        ),
      );
    }
    return days;
  }

  ExploreTrip? getTripById(String id) => _tripsById[id];

  List<ExploreTrip> tripsForSection(DiscoverySection section) {
    final result = <ExploreTrip>[];
    for (final item in section.items) {
      final trip = _tripsById[item.tripId];
      if (trip != null) {
        result.add(trip.copyWith(tag: item.tag));
      }
    }
    return result;
  }

  Future<void> _loadBackdrops() async {
    try {
      final raw =
          await rootBundle.loadString('assets/home_backdrops/manifest.json');
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final items = data['items'] as List<dynamic>? ?? const [];
      _backdrops = items
          .whereType<Map<String, dynamic>>()
          .map(BackdropItem.fromJson)
          .toList();
    } catch (e) {
      debugPrint('Failed to load backdrops: $e');
    }
  }

  Future<void> _loadOnboarding() async {
    try {
      final raw = await rootBundle
          .loadString('assets/onboarding/onboarding_config_fallback.json');
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final steps = data['steps'] as List<dynamic>? ?? const [];
      _onboardingSteps = steps
          .whereType<Map<String, dynamic>>()
          .map(OnboardingStep.fromJson)
          .toList();
    } catch (e) {
      debugPrint('Failed to load onboarding: $e');
    }
  }

  Map<String, dynamic>? _rawDiscoveryData;

  Future<void> _loadExploreTripsAndSections() async {
    try {
      final csvRaw =
          await rootBundle.loadString('assets/data/explore_trips.csv');
      final lines = const LineSplitter().convert(csvRaw);
      final parsed = <ExploreTrip>[];
      for (int i = 1; i < lines.length; i++) {
        final row = _parseCsvRow(lines[i]);
        if (row.length >= 7) {
          final trip = ExploreTrip(
            locale: row[0],
            id: row[1],
            title: row[2],
            days: int.tryParse(row[3]) ?? 4,
            lat: double.tryParse(row[4]) ?? MapboxService.davaoCenterLat,
            lng: double.tryParse(row[5]) ?? MapboxService.davaoCenterLng,
            thumbnailUrl: row[6],
          );
          parsed.add(trip);
          _tripsById[trip.id] = trip;
        }
      }
      _allTrips = parsed;

      final discRaw =
          await rootBundle.loadString('assets/data/discovery_sections.json');
      _rawDiscoveryData = jsonDecode(discRaw) as Map<String, dynamic>;
      _rebuildLocaleSections();
    } catch (e) {
      debugPrint('Failed to load explore trips: $e');
    }
  }

  void _rebuildLocaleSections() {
    if (_rawDiscoveryData == null) return;
    final localesMap =
        _rawDiscoveryData!['locales'] as Map<String, dynamic>? ?? const {};
    final activeLocaleKey = localesMap.containsKey(_locale) ? _locale : 'en';
    final localeObj =
        localesMap[activeLocaleKey] as Map<String, dynamic>? ?? const {};

    final heroObj = localeObj['hero'] as Map<String, dynamic>?;
    if (heroObj != null) {
      final heroId = heroObj['tripId'] as String? ?? '';
      final heroTag = heroObj['tag'] as String? ?? 'DAVAO SIGNATURE';
      final found = _tripsById[heroId];
      if (found != null) {
        _heroTrip = found.copyWith(tag: heroTag);
      }
    }
    if (_heroTrip == null && _allTrips.isNotEmpty) {
      _heroTrip = _allTrips.first.copyWith(tag: 'DAVAO SIGNATURE');
    }

    final rawSections = localeObj['sections'] as List<dynamic>? ?? const [];
    _discoverySections = rawSections
        .whereType<Map<String, dynamic>>()
        .map(DiscoverySection.fromJson)
        .toList();
  }

  Future<void> _loadDavaoEncyclopedia() async {
    try {
      final shortRaw =
          await rootBundle.loadString('assets/data/short_descriptions.json');
      final longRaw =
          await rootBundle.loadString('assets/data/descriptions.json');

      final shortList = (jsonDecode(shortRaw) as List<dynamic>)
          .whereType<Map<String, dynamic>>()
          .map(CityDescription.fromJson)
          .toList();

      final longMap = <String, String>{};
      for (final item in (jsonDecode(longRaw) as List<dynamic>)
          .whereType<Map<String, dynamic>>()) {
        final city = item['city'] as String? ?? '';
        final desc = item['description'] as String? ?? '';
        if (city.isNotEmpty) {
          longMap[city.toLowerCase()] = desc;
        }
      }

      const wmoCycle = [1, 2, 0, 2, 3, 80, 1, 2];
      _cityDescriptions = [
        for (int i = 0; i < shortList.length; i++)
          shortList[i].copyWith(
            longDescription:
                longMap[shortList[i].city.toLowerCase()] ?? shortList[i].description,
            wmoWeatherCode: wmoCycle[i % wmoCycle.length],
          ),
      ];
    } catch (e) {
      debugPrint('Failed to load Davao encyclopedia: $e');
    }
  }

  List<String> _parseCsvRow(String line) {
    final result = <String>[];
    final buffer = StringBuffer();
    bool inQuotes = false;
    for (int i = 0; i < line.length; i++) {
      final char = line[i];
      if (char == '"') {
        inQuotes = !inQuotes;
      } else if (char == ',' && !inQuotes) {
        result.add(buffer.toString());
        buffer.clear();
      } else {
        buffer.write(char);
      }
    }
    result.add(buffer.toString());
    return result;
  }

  void _seedInitialTripsAndChat() {
    if (isSignedIn) {
      if (_chatSessions.isEmpty) {
        _chatSessions.add(
          ChatSession(
            id: 'chat_new',
            title: 'New Trip',
            groupLabel: 'Today',
            isTrip: false,
            createdAt: DateTime.now(),
            messages: const [],
          ),
        );
        _activeChatId = 'chat_new';
      }
      return;
    }

    final sampleExplore = _allTrips.take(3).toList();
    if (_savedTrips.isEmpty && sampleExplore.isNotEmpty) {
      for (final exp in sampleExplore.take(2)) {
        _savedTrips.add(buildDetailedItineraryFromExplore(exp));
      }
      _bucketListTripIds.add(sampleExplore.first.id);
    }

    final firstTrip = _savedTrips.isNotEmpty
        ? _savedTrips.first
        : generateCustomTrip(
            destination: 'Samal Island & Talikud Coral Garden',
            daysCount: 4,
            vibe: 'Island Hopping & Reefs',
            centerLat: 7.0742,
            centerLng: 125.7089,
          );

    final samalWelcomeMsg = ChatMessage(
      id: 'welcome_1',
      isUser: false,
      text:
          "Maayong adlaw! I'm Lakbay+, your Davao Region (Region XI) AI travel planner. Tell me which province or spot you'd like to explore—from Samal & Talikud reefs to Mati's Dahican surf, Buda pine cabins, or Mt. Apo—and I'll animate your Mapbox route and day-by-day itinerary!",
      timestamp: DateTime.now().subtract(const Duration(minutes: 5)),
      attachedTrip: firstTrip,
      suggestedReplies: const [
        '4-day Samal & Talikud Island hopping 🏝️',
        '5-day Mati Dahican surf & Aliwagwag Falls 🏄',
        '3-day Buda pine cabins & Marilog highlands 🌲',
        '3-day Davao City, Malagos & Eden Nature Park 🦅',
      ],
    );

    if (_chatSessions.isEmpty) {
      _chatSessions.addAll([
        ChatSession(
          id: 'chat_today_samal',
          title: '3-Day Samal and Davao City Escape',
          groupLabel: 'Today',
          isTrip: true,
          createdAt: DateTime.now().subtract(const Duration(hours: 2)),
          messages: [samalWelcomeMsg],
        ),
        ChatSession(
          id: 'chat_new',
          title: 'New Trip',
          groupLabel: 'Today',
          isTrip: false,
          createdAt: DateTime.now(),
          messages: const [],
        ),
        ChatSession(
          id: 'chat_yest_davao',
          title: '7-Day Davao & Samal Island Loop',
          groupLabel: 'Yesterday',
          isTrip: true,
          createdAt: DateTime.now().subtract(const Duration(days: 1)),
          messages: [samalWelcomeMsg],
        ),
        ChatSession(
          id: 'chat_yest_mati',
          title: '5-Day Mati Dahican & Aliwagwag Falls',
          groupLabel: 'Yesterday',
          isTrip: true,
          createdAt: DateTime.now().subtract(const Duration(days: 1, hours: 3)),
          messages: [
            ChatMessage(
              id: 'welcome_mati',
              isUser: false,
              text:
                  'Pacific surf & waterfall mode ready! Explore **Dahican Beach**, **Sleeping Dinosaur Viewdeck**, and **Aliwagwag Falls** across Davao Oriental.',
              timestamp: DateTime.now().subtract(const Duration(days: 1, hours: 3)),
              suggestedReplies: const [
                'Plan sunrise surf at Dahican 🏄',
                'Add Sleeping Dinosaur ridge stop 🌄',
                'Suggest coastal resorts in Mati 🌴',
              ],
            ),
          ],
        ),
      ]);
      _activeChatId = 'chat_new';
    }
  }

  void _syncActiveSession({String? titleHint, bool hasTrip = false}) {
    final idx = _chatSessions.indexWhere((s) => s.id == _activeChatId);
    if (idx < 0) return;
    final current = _chatSessions[idx];
    final nextTitle = (current.title == 'New Trip' && titleHint != null && titleHint.trim().isNotEmpty)
        ? titleHint.trim()
        : current.title;
    _chatSessions[idx] = ChatSession(
      id: current.id,
      title: nextTitle,
      groupLabel: current.groupLabel,
      isTrip: current.isTrip || hasTrip,
      createdAt: current.createdAt,
      messages: List<ChatMessage>.from(_chatMessages),
    );
  }

  /// Turns of history sent to the server chat (its limit is 12).
  static const int _serverChatHistoryTurns = 12;

  /// History text without UI footers, within the server's 2000-char limit.
  static String _chatHistoryText(String text) {
    final cleaned = text
        .replaceAll(RegExp(r'\n*_Powered by Lakbay\+[^_]*_\s*$'), '')
        .trim();
    return cleaned.length > 2000 ? cleaned.substring(0, 2000) : cleaned;
  }

  /// Sends a prompt to the Lakbay+ Davao AI Travel Planner and generates a contextual Region XI route.
  Future<void> sendChatMessage(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    _chatMessages.add(
      ChatMessage(
        id: 'user_${DateTime.now().millisecondsSinceEpoch}',
        isUser: true,
        text: trimmed,
        timestamp: DateTime.now(),
      ),
    );

    // Signed in or not, chat goes through the backend: guests use the
    // rate-limited guest endpoint, so the app ships no AI provider key.
    if (apiCatalog.isConfigured) {
      _isAiTyping = true;
      notifyListeners();
      try {
        // The most recent turns (not the first ones) before this message.
        final earlier = _chatMessages.take(
            _chatMessages.length > 1 ? _chatMessages.length - 1 : 0);
        final history = earlier
            .skip(math.max(0, earlier.length - _serverChatHistoryTurns))
            .map((m) => {
                  'role': m.isUser ? 'user' : 'assistant',
                  'content': _chatHistoryText(m.text),
                })
            .where((m) => m['content']!.isNotEmpty)
            .toList();
        // The backend planning schema names the coordinates lat/lng and rejects
        // unknown keys, so "latitude"/"longitude" made every request fail.
        _planningState ??= {
          'origin': {
          'label': effectiveOriginLabel,
          if (_userLat != null && _userLng != null) 'lat': _userLat,
          if (_userLat != null && _userLng != null) 'lng': _userLng,
        },
          'destination_ids': <int>[],
          'traveler_count': 2,
        };
        final serverAi = await apiCatalog.aiChat(
          _authSession?.accessToken,
          message: trimmed,
          history: history,
          planningState: _planningState,
          inputRevision: _planningRevision,
        );
        if (serverAi != null) {
          final planning = serverAi.planning;
          if (planning != null) {
            _planningRevision =
                (planning['input_revision'] as num?)?.toInt() ??
                (_planningRevision + 1);
            final preview = planning['preview'];
            if (preview is Map<String, dynamic> &&
                preview['state'] is Map<String, dynamic>) {
              _planningState = Map<String, dynamic>.from(
                preview['state'] as Map<String, dynamic>,
              );
            }
          }

          final stateDestIds =
              (_planningState?['destination_ids'] as List<dynamic>? ?? const [])
                  .whereType<num>()
                  .map((n) => n.toInt())
                  .toList();
          final ragDestIds = serverAi.retrievedContext
              .where((r) => r['source'] == 'destination')
              .map((r) => (r['source_id'] as num?)?.toInt())
              .whereType<int>()
              .toList();
          final targetDestIds = stateDestIds.isNotEmpty
              ? stateDestIds
              : ragDestIds.take(4).toList();

          // The model judges intent; keywords are only a fallback for replies
          // without one (older backends or unparseable output).
          final intent = planning?['intent']?.toString();
          final wantsItinerary = intent != null
              ? intent == 'plan_trip' || intent == 'modify_trip'
              : RegExp(
                  r'\b(plan|itinerary|trip|route|days?|generate|options?|weekend)\b',
                  caseSensitive: false,
                ).hasMatch(trimmed);
          final modelReplies =
              (planning?['suggested_replies'] as List<dynamic>? ?? const [])
                  .map((e) => e.toString())
                  .where((e) => e.trim().isNotEmpty)
                  .toList();

          var aiOptions = <AiItineraryOptionDraft>[];
          ItineraryTrip? attachedTrip;

          if (wantsItinerary && !isSignedIn) {
            // Guests get a quick backend trip draft; validated catalog
            // itineraries need an account.
            try {
              final draft = await aiService.chatOrPlan(
                userPrompt: trimmed,
                history: history,
                currentLocation: effectiveOriginLabel,
                userLat: _userLat,
                userLng: _userLng,
                preferredVibes: selectedVibes,
                strictBudget: strictBudgetFilter,
              );
              if (draft.hasStructuredItinerary) {
                attachedTrip = _buildItineraryFromAi(draft);
              }
            } catch (_) {}
          } else if (wantsItinerary && targetDestIds.isNotEmpty) {
            final daysCount =
                (_planningState?['day_count'] as num?)?.toInt() ??
                RegExp(r'(\d+)\s*-?\s*day', caseSensitive: false)
                    .firstMatch(trimmed)
                    ?.group(1)
                    .letOrNull(int.tryParse) ??
                3;
            final travelerCount =
                (_planningState?['traveler_count'] as num?)?.toInt() ?? 2;
            final budgetRaw = _planningState?['total_budget'];
            final budgetPhp =
                double.tryParse((budgetRaw ?? '').toString()) ??
                (daysCount.clamp(1, 14) * 3500.0 * travelerCount);

            final generated = await apiCatalog.generateAiItineraries(
              _authSession!.accessToken,
              totalBudgetPhp: budgetPhp,
              travelerCount: travelerCount,
              dayCount: daysCount.clamp(1, 14),
              destinationIds: targetDestIds,
              planningState: _planningState,
              inputRevision: _planningRevision,
              specialRequirements: trimmed,
              strictBudgetFilter: strictBudgetFilter,
            );

            if (generated != null && generated.options.isNotEmpty) {
              aiOptions = [
                for (final rawOpt in generated.options)
                  _parseBackendAiOption(
                    rawOpt,
                    generationRunId: generated.generationRunId,
                    fallbackDestinationIds: targetDestIds,
                    includeFlights: _mentionsFlightOrigin(trimmed),
                  ),
              ];
              attachedTrip = aiOptions.first.trip;
            }
          }

          attachedTrip ??= wantsItinerary
              ? _generateLocalFallbackTrip(
                  trimmed,
                  includeFlights: _mentionsFlightOrigin(trimmed),
                )
              : null;

          _chatMessages.add(
            ChatMessage(
              id: 'ai_${DateTime.now().millisecondsSinceEpoch}',
              isUser: false,
              text: serverAi.replyText,
              timestamp: DateTime.now(),
              attachedTrip: aiOptions.length <= 1 ? attachedTrip : null,
              aiOptions: aiOptions,
              suggestedReplies: modelReplies.isNotEmpty
                  ? modelReplies
                  : const [
                      'Make it 3 days within ₱8,000 budget 💸',
                      'Compare Budget vs. Comfort options ✨',
                      'Suggest family-friendly Davao stops 🌿',
                    ],
            ),
          );
          _isAiTyping = false;
          _syncActiveSession(
            titleHint: attachedTrip?.title ?? trimmed,
            hasTrip: attachedTrip != null || aiOptions.isNotEmpty,
          );
          _scheduleSaveState();
          notifyListeners();
          return;
        }
      } catch (_) {
        // Fall through to client AI or local Region XI engine
      }
      _isAiTyping = false;
    }

    if (aiService.isConfigured) {
      _isAiTyping = true;
      notifyListeners();

      try {
        final aiResult = await aiService.chatOrPlan(
          userPrompt: trimmed,
          availableDestinations: _allTrips.map((t) => t.title).toList(),
          history: _chatMessages
              .map(
                (m) => {
                  'role': m.isUser ? 'user' : 'assistant',
                  'content': m.text,
                },
              )
              .toList(),
          currentLocation: effectiveOriginLabel,
          userLat: _userLat,
          userLng: _userLng,
          preferredVibes: selectedVibes,
          strictBudget: strictBudgetFilter,
        );

        ItineraryTrip? attachedTrip;
        if (aiResult.hasStructuredItinerary) {
          attachedTrip = _buildItineraryFromAi(aiResult);
        }

        _chatMessages.add(
          ChatMessage(
            id: 'ai_${DateTime.now().millisecondsSinceEpoch}',
            isUser: false,
            text:
                '${aiResult.replyText}\n\n_Powered by ${aiResult.providerUsed} (${aiResult.modelUsed})_',
            timestamp: DateTime.now(),
            attachedTrip: attachedTrip,
            suggestedReplies: aiResult.suggestedReplies.isNotEmpty
                ? aiResult.suggestedReplies
                : const [
                    'Show 2-day weekend version 🗓️',
                    'Adjust pacing or coastal stops 🌊',
                    'Suggest food & night market gems 🍢',
                  ],
          ),
        );
        _isAiTyping = false;
        _syncActiveSession(
          titleHint: attachedTrip?.title ?? trimmed,
          hasTrip: attachedTrip != null,
        );
        _scheduleSaveState();
        notifyListeners();
        return;
      } catch (_) {
        _isAiTyping = false;
      }
    }

    final generatedTrip = _generateLocalFallbackTrip(trimmed);

    _chatMessages.add(
      ChatMessage(
        id: 'ai_${DateTime.now().millisecondsSinceEpoch}',
        isUser: false,
        text:
            "I've mapped out a custom **${generatedTrip.daysCount}-day ${generatedTrip.destination}** itinerary in Region XI! It includes animated Mapbox waypoints, ferry/coastal highway transit legs, and handpicked Davao stays.\n\nTap the card below to launch the **Play Route Tour** animation or edit your daily stops.",
        timestamp: DateTime.now(),
        attachedTrip: generatedTrip,
        suggestedReplies: const [
          'Show 2-day weekend version 🗓️',
          'Add Samal ferry & boat transfers ⛴️',
          'Include Malagos & Roxas Night Market 🍢',
        ],
      ),
    );

    _syncActiveSession(
      titleHint: generatedTrip.title,
      hasTrip: true,
    );
    _scheduleSaveState();
    notifyListeners();
  }

  /// Generates a Region XI trip via live Groq/Gemini AI (if configured in `.env`)
  /// or falls back to the local Davao Region itinerary builder.
  Future<ItineraryTrip> createTripFromAiPrompt(String prompt) async {
    if (aiService.isConfigured) {
      try {
        final aiResult = await aiService.chatOrPlan(
          userPrompt: prompt,
          availableDestinations: _allTrips.map((t) => t.title).toList(),
          currentLocation: effectiveOriginLabel,
          userLat: _userLat,
          userLng: _userLng,
          preferredVibes: selectedVibes,
          strictBudget: strictBudgetFilter,
        );
        if (aiResult.hasStructuredItinerary) {
          return _buildItineraryFromAi(aiResult);
        }
      } catch (_) {
        // Fallback below
      }
    }
    return _generateLocalFallbackTrip(prompt);
  }

  /// Exposes [_buildItineraryFromAi] when an onboarding/chat turn already produced
  /// a structured multi-day itinerary.
  ItineraryTrip buildTripFromAiResult(AiPlanResult ai) =>
      _buildItineraryFromAi(ai);

  bool _mentionsFlightOrigin(String prompt) => RegExp(
        r'\b(from manila|from cebu|from clark|from iloilo|flight|fly in|airfare|mnl|ceb)\b',
        caseSensitive: false,
      ).hasMatch(prompt);

  AiItineraryOptionDraft _parseBackendAiOption(
    Map<String, dynamic> rawOpt, {
    int? generationRunId,
    ItineraryTrip? fallbackTrip,
    String? preferredRemoteImageUrl,
    String? preferredHeroAsset,
    List<int> fallbackDestinationIds = const [],
    bool includeFlights = false,
  }) {
    final optionNumber = (rawOpt['option_number'] as num?)?.toInt() ?? 1;
    final optTitle =
        (rawOpt['title'] ?? fallbackTrip?.title ?? 'Davao Region Option $optionNumber')
            .toString()
            .trim();
    final summary = (rawOpt['summary'] ?? '').toString().trim();
    final totalCostPhp =
        double.tryParse((rawOpt['estimated_total_cost'] ?? '0').toString()) ??
        0.0;
    final isOverBudget = rawOpt['is_over_budget'] as bool? ?? false;
    final phpRate = _currencyRates['PHP'] ?? 57.0;

    final rawDays = rawOpt['days'] as List<dynamic>? ?? const [];
    final parsedDays = <ItineraryDay>[];
    final discoveredDestIds = <int>{...fallbackDestinationIds};
    ExploreTrip? firstMatchedCatalog;

    for (final dRaw in rawDays) {
      if (dRaw is! Map) continue;
      final dayNum = (dRaw['day'] as num?)?.toInt() ?? (parsedDays.length + 1);
      final dayTitle = (dRaw['title'] ?? 'Day $dayNum').toString();
      final daySummary = (dRaw['summary'] ?? '').toString();
      final rawActs = dRaw['activities'] as List<dynamic>? ?? const [];

      final stops = <ItineraryStop>[];
      int? dayDestId;
      double? dayLat;
      double? dayLng;

      for (final aRaw in rawActs) {
        if (aRaw is! Map) continue;
        final dId = (aRaw['destination_id'] as num?)?.toInt();
        if (dId != null) {
          discoveredDestIds.add(dId);
          dayDestId ??= dId;
          for (final exp in _allTrips) {
            if (exp.apiDestinationId == dId) {
              firstMatchedCatalog ??= exp;
              dayLat ??= exp.lat;
              dayLng ??= exp.lng;
              break;
            }
          }
        }
        final actCostPhp =
            double.tryParse((aRaw['estimated_cost'] ?? '0').toString()) ?? 0.0;
        stops.add(
          ItineraryStop(
            time: (aRaw['time'] ?? '09:00').toString(),
            title: (aRaw['title'] ?? 'Activity').toString(),
            description: (aRaw['description'] ?? '').toString(),
            category: firstMatchedCatalog?.tag ?? 'Scenic',
            costEstimateUsd: actCostPhp / phpRate,
            lat: dayLat ?? fallbackTrip?.centerLat ?? MapboxService.davaoCenterLat,
            lng: dayLng ?? fallbackTrip?.centerLng ?? MapboxService.davaoCenterLng,
          ),
        );
      }

      parsedDays.add(
        ItineraryDay(
          dayNumber: dayNum,
          cityTitle: dayTitle,
          summary: daySummary,
          lat: dayLat ?? fallbackTrip?.centerLat ?? MapboxService.davaoCenterLat,
          lng: dayLng ?? fallbackTrip?.centerLng ?? MapboxService.davaoCenterLng,
          transportFromPrevious: dayNum > 1 ? TransportMode.car : null,
          transportDuration: dayNum > 1 ? '45m - 1h 30m scenic route' : null,
          apiDestinationId: dayDestId,
          stops: stops,
        ),
      );
    }

    final heroRemote = preferredRemoteImageUrl ??
        fallbackTrip?.remoteImageUrl ??
        (firstMatchedCatalog?.hasRemoteThumbnail == true
            ? firstMatchedCatalog!.thumbnailUrl
            : null);
    final heroLocal = preferredHeroAsset ??
        fallbackTrip?.heroAsset ??
        firstMatchedCatalog?.localAssetPath ??
        currentBackdrop.localAssetPath;
    final destLabel = fallbackTrip?.destination ??
        firstMatchedCatalog?.regionName ??
        'Davao Region, Philippines';

    final trip = ItineraryTrip(
      id: fallbackTrip?.id ??
          'ai_opt_${generationRunId ?? DateTime.now().millisecondsSinceEpoch}_$optionNumber',
      title: optTitle,
      destination: destLabel,
      daysCount: parsedDays.isNotEmpty
          ? parsedDays.length
          : (fallbackTrip?.daysCount ?? 3),
      adults: fallbackTrip?.adults ?? 2,
      children: fallbackTrip?.children ?? 0,
      centerLat:
          firstMatchedCatalog?.lat ??
          fallbackTrip?.centerLat ??
          MapboxService.davaoCenterLat,
      centerLng:
          firstMatchedCatalog?.lng ??
          fallbackTrip?.centerLng ??
          MapboxService.davaoCenterLng,
      heroAsset: heroLocal,
      remoteImageUrl: heroRemote,
      vibeTag: optionNumber == 1
          ? 'Best Value'
          : (optionNumber == 2 ? 'Balanced Pace' : 'Curated'),
      overviewText: summary.isNotEmpty
          ? summary
          : (fallbackTrip?.overviewText ?? 'AI-curated Davao Region route.'),
      bestMonths:
          firstMatchedCatalog?.bestTimeToVisit ?? 'Dec - May (Dry Season)',
      avgTemp: fallbackTrip?.avgTemp ?? '29°C',
      expertName: 'Lakbay+ AI Planner',
      expertTip: firstMatchedCatalog?.travelNotes ??
          fallbackTrip?.expertTip ??
          'Cluster nearby stops by corridor and depart early for falls or mountain ridges.',
      days: parsedDays.isNotEmpty ? parsedDays : (fallbackTrip?.days ?? const []),
      flights: includeFlights ? _defaultDavaoFlights() : const [],
      hotels: fallbackTrip?.hotels ??
          _buildDavaoHotels(
            'ai_$optionNumber',
            destLabel,
            heroLocal,
            firstMatchedCatalog?.lat ?? MapboxService.davaoCenterLat,
            firstMatchedCatalog?.lng ?? MapboxService.davaoCenterLng,
            remoteUrl: heroRemote,
          ),
      backendTripId: fallbackTrip?.backendTripId,
      backendDestinationId:
          discoveredDestIds.isNotEmpty ? discoveredDestIds.first : null,
      backendDestinationIds: discoveredDestIds.toList(),
      whatToBring:
          firstMatchedCatalog?.whatToBring ?? fallbackTrip?.whatToBring,
      entranceFee: firstMatchedCatalog?.entranceFee,
      operatingHours: firstMatchedCatalog?.operatingHours,
      isLocalOnly: !includeFlights,
      backendEstimatedCostPhp: totalCostPhp > 0 ? totalCostPhp : null,
      aiGenerationRunId: generationRunId,
      aiOptionNumber: optionNumber,
    );

    return AiItineraryOptionDraft(
      optionNumber: optionNumber,
      title: optTitle,
      summary: summary,
      estimatedTotalCostPhp: totalCostPhp,
      isOverBudget: isOverBudget,
      generationRunId: generationRunId,
      trip: trip,
    );
  }

  ItineraryTrip _generateLocalFallbackTrip(
    String prompt, {
    bool includeFlights = false,
  }) {
    final trimmed = prompt.trim();
    final lower = trimmed.toLowerCase();
    final matchedExplore = _allTrips.firstWhere(
      (t) =>
          t.title.toLowerCase().contains(lower) ||
          lower.split(' ').any(
              (word) => word.length > 3 && t.title.toLowerCase().contains(word)),
      orElse: () => _allTrips.isNotEmpty
          ? _allTrips.first
          : const ExploreTrip(
              locale: 'en',
              id: '01KJKDPNA1XT4W2RHRA6GQVNVX',
              title: '4-Day Samal & Talikud Island Hopping Escape',
              days: 4,
              lat: 7.0742,
              lng: 125.7089,
              thumbnailUrl: '',
            ),
    );

    final daysMatch =
        RegExp(r'(\d+)\s*-?\s*day', caseSensitive: false).firstMatch(trimmed);
    final requestedDays = daysMatch != null
        ? (int.tryParse(daysMatch.group(1)!) ?? matchedExplore.days)
            .clamp(2, 14)
        : matchedExplore.days;

    final remoteThumb = matchedExplore.hasRemoteThumbnail
        ? matchedExplore.thumbnailUrl
        : null;
    if (lower.contains('samal') ||
        lower.contains('talikud') ||
        lower.contains('island')) {
      return generateCustomTrip(
        destination: 'Samal Island (IGaCoS) & Talikud Reefs',
        daysCount: requestedDays,
        vibe: 'Island Hopping & Coral Coves',
        heroAsset: 'assets/home_backdrops/01-samal-island.jpg',
        remoteImageUrl: remoteThumb,
        centerLat: 7.0742,
        centerLng: 125.7089,
        includeFlights: includeFlights,
      );
    } else if (lower.contains('mati') ||
        lower.contains('dahican') ||
        lower.contains('aliwagwag') ||
        lower.contains('pujada') ||
        lower.contains('oriental')) {
      return generateCustomTrip(
        destination: 'Mati Dahican, Pujada Bay & Aliwagwag Falls',
        daysCount: requestedDays,
        vibe: 'Pacific Surf & Waterfalls Loop',
        heroAsset: 'assets/home_backdrops/02-dahican-mati.jpg',
        remoteImageUrl: remoteThumb,
        centerLat: 6.9551,
        centerLng: 126.2185,
        includeFlights: includeFlights,
      );
    } else if (lower.contains('buda') ||
        lower.contains('marilog') ||
        lower.contains('pine') ||
        lower.contains('cabin')) {
      return generateCustomTrip(
        destination: 'Buda & Marilog Pine Highlands, Davao City',
        daysCount: requestedDays,
        vibe: 'Misty Pine Cabins & Cafes',
        heroAsset: 'assets/home_backdrops/09-marilog-bemwa.jpg',
        remoteImageUrl: remoteThumb,
        centerLat: 7.4561,
        centerLng: 125.2498,
        includeFlights: includeFlights,
      );
    } else if (lower.contains('apo') ||
        lower.contains('kapatagan') ||
        lower.contains('digos') ||
        lower.contains('sta. cruz')) {
      return generateCustomTrip(
        destination: 'Kapatagan Highlands & Mt. Apo, Davao del Sur',
        daysCount: requestedDays,
        vibe: 'Volcanic Peaks & Coffee Ridges',
        heroAsset: 'assets/home_backdrops/03-mount-apo.jpg',
        remoteImageUrl: remoteThumb,
        centerLat: 6.9292,
        centerLng: 125.3315,
        includeFlights: includeFlights,
      );
    } else if (lower.contains('maragusan') ||
        lower.contains('kopiat') ||
        lower.contains('de oro') ||
        lower.contains('tagum')) {
      return generateCustomTrip(
        destination: 'Tagum, Kopiat Island & Maragusan Highlands',
        daysCount: requestedDays,
        vibe: 'Sea of Clouds & Gulf Islands',
        heroAsset: 'assets/home_backdrops/10-calamba-clouds.jpg',
        remoteImageUrl: remoteThumb,
        centerLat: 7.3508,
        centerLng: 126.1536,
        includeFlights: includeFlights,
      );
    } else {
      return buildDetailedItineraryFromExplore(
        matchedExplore,
        overrideDays: requestedDays,
        includeFlights: includeFlights,
      );
    }
  }

  ItineraryTrip _buildItineraryFromAi(AiPlanResult ai) {
    final fallbackCenter = MapboxService.clampToDavaoRegion(
      ai.centerLat ?? MapboxService.davaoCenterLat,
      ai.centerLng ?? MapboxService.davaoCenterLng,
    );
    final usdRate = _currencyRates['PHP'] ?? 57.0;

    final days = ai.days.map((d) {
      final stops = d.activities.map((a) {
        final pos = MapboxService.clampToDavaoRegion(
          a.lat ?? fallbackCenter.$1,
          a.lng ?? fallbackCenter.$2,
        );
        return ItineraryStop(
          time: a.time,
          title: a.title,
          description: a.description,
          category: a.category,
          costEstimateUsd: a.estimatedCostPhp / usdRate,
          lat: pos.$1,
          lng: pos.$2,
        );
      }).toList();

      final dayLat = stops.isNotEmpty ? stops.first.lat : fallbackCenter.$1;
      final dayLng = stops.isNotEmpty ? stops.first.lng : fallbackCenter.$2;

      return ItineraryDay(
        dayNumber: d.day,
        cityTitle: d.title,
        summary: d.summary,
        lat: dayLat,
        lng: dayLng,
        transportFromPrevious:
            d.day > 1 ? TransportMode.car : null,
        transportDuration: d.day > 1 ? '45m - 1h 30m' : null,
        stops: stops,
      );
    }).toList();

    final dest = ai.destination?.isNotEmpty == true
        ? ai.destination!
        : 'Davao Region, Philippines';
    final title = ai.title?.isNotEmpty == true
        ? ai.title!
        : '${days.length}-Day $dest';

    return ItineraryTrip(
      id: 'ai_trip_${DateTime.now().millisecondsSinceEpoch}',
      title: title,
      destination: dest,
      daysCount: ai.daysCount ?? days.length,
      centerLat: fallbackCenter.$1,
      centerLng: fallbackCenter.$2,
      heroAsset: currentBackdrop.localAssetPath,
      vibeTag: ai.vibe?.isNotEmpty == true ? ai.vibe! : 'Davao AI Route',
      overviewText: ai.replyText,
      bestMonths: 'Dec - May (Dry Season)',
      avgTemp: '29°C',
      expertName: 'Lakbay+ AI • Davao Region',
      expertTip:
          'Generated via ${ai.providerUsed} (${ai.modelUsed}) with Region XI coordinates.',
      days: days,
      flights: const [],
      hotels: _buildDavaoHotels(
        'ai_dvo',
        dest,
        currentBackdrop.localAssetPath,
        fallbackCenter.$1,
        fallbackCenter.$2,
      ),
      isLocalOnly: true,
    );
  }

  ItineraryTrip buildDetailedItineraryFromExplore(
    ExploreTrip explore, {
    int? overrideDays,
    bool includeFlights = false,
  }) {
    final count = overrideDays ?? explore.days;
    final base = generateCustomTrip(
      id: explore.id,
      title: explore.title,
      destination:
          '${explore.title.replaceAll(RegExp(r'^\d+-Day\s*', caseSensitive: false), '')} (${explore.regionName})',
      daysCount: count,
      vibe: explore.tag?.isNotEmpty == true
          ? '${explore.tag} • ${explore.regionName}'
          : '${explore.regionName} • Region XI',
      heroAsset: explore.localAssetPath,
      remoteImageUrl: explore.hasRemoteThumbnail ? explore.thumbnailUrl : null,
      centerLat: explore.lat,
      centerLng: explore.lng,
      includeFlights: includeFlights,
    );
    final destId = explore.apiDestinationId ??
        (explore.id.startsWith('api_')
            ? int.tryParse(explore.id.replaceFirst('api_', ''))
            : null);

    if (destId == null &&
        !explore.hasRemoteThumbnail &&
        explore.description == null) {
      return base;
    }

    final notesParts = <String>[
      if (explore.description != null && explore.description!.isNotEmpty)
        explore.description!,
      if (explore.entranceFee != null && explore.entranceFee!.isNotEmpty)
        'Entrance fee: ${explore.entranceFee}',
      if (explore.overnightFee != null && explore.overnightFee!.isNotEmpty)
        'Overnight fee: ${explore.overnightFee}',
      if (explore.operatingHours != null && explore.operatingHours!.isNotEmpty)
        'Hours: ${explore.operatingHours}',
      if (explore.travelNotes != null && explore.travelNotes!.isNotEmpty)
        explore.travelNotes!,
    ];

    final cachedHotels = destId != null
        ? (_hotelRatesByDestId[destId] ?? const <HotelOffer>[])
        : const <HotelOffer>[];

    return ItineraryTrip(
      id: base.id,
      title: base.title,
      destination: base.destination,
      daysCount: base.daysCount,
      adults: base.adults,
      children: base.children,
      centerLat: base.centerLat,
      centerLng: base.centerLng,
      heroAsset: base.heroAsset,
      remoteImageUrl: explore.hasRemoteThumbnail ? explore.thumbnailUrl : null,
      vibeTag: base.vibeTag,
      overviewText:
          notesParts.isNotEmpty ? notesParts.join('\n\n') : base.overviewText,
      bestMonths: explore.bestTimeToVisit ?? base.bestMonths,
      avgTemp: base.avgTemp,
      wmoWeatherCode: base.wmoWeatherCode,
      expertName: base.expertName,
      expertAvatarAsset: base.expertAvatarAsset,
      expertTip: base.expertTip,
      days: [
        for (final day in base.days)
          ItineraryDay(
            dayNumber: day.dayNumber,
            cityTitle: day.cityTitle,
            summary: day.summary,
            lat: day.lat,
            lng: day.lng,
            wmoWeatherCode: day.wmoWeatherCode,
            tempCelsius: day.tempCelsius,
            transportFromPrevious: day.transportFromPrevious,
            transportDuration: day.transportDuration,
            stops: day.stops,
            recommendedHotel: day.recommendedHotel,
            apiDestinationId: destId,
          ),
      ],
      flights: base.flights,
      hotels: cachedHotels.isNotEmpty ? cachedHotels : base.hotels,
      backendDestinationId: destId,
      backendDestinationIds: destId != null ? [destId] : const [],
      whatToBring: explore.whatToBring,
      entranceFee: explore.entranceFee,
      operatingHours: explore.operatingHours,
      isLocalOnly: !includeFlights,
      backendEstimatedCostPhp: explore.estimatedCostPhp,
    );
  }

  List<FlightOffer> _defaultDavaoFlights() => const [
        FlightOffer(
          id: 'fl_mnl_dvo',
          airline: 'Philippine Airlines / Cebu Pacific',
          originCode: 'MNL',
          destinationCode: 'DVO',
          duration: '1h 55m',
          isDirect: true,
          priceRoundtripUsd: 88,
        ),
        FlightOffer(
          id: 'fl_ceb_dvo',
          airline: 'Cebu Pacific • Visayas–Mindanao',
          originCode: 'CEB',
          destinationCode: 'DVO',
          duration: '1h 10m',
          isDirect: true,
          priceRoundtripUsd: 54,
        ),
      ];

  ItineraryTrip generateCustomTrip({
    String? id,
    String? title,
    required String destination,
    required int daysCount,
    required String vibe,
    String? heroAsset,
    String? remoteImageUrl,
    double? centerLat,
    double? centerLng,
    bool includeFlights = false,
  }) {
    final tripId = id ?? 'davao_${DateTime.now().millisecondsSinceEpoch}';
    final effectiveHero = heroAsset ?? currentBackdrop.localAssetPath;
    final cleanTitle = title ?? '$daysCount-Day $destination';

    final (clampedLat, clampedLng) = MapboxService.clampToDavaoRegion(
      centerLat ?? MapboxService.davaoCenterLat,
      centerLng ?? MapboxService.davaoCenterLng,
    );

    final lower = destination.toLowerCase();
    final hotels = _buildDavaoHotels(
      tripId,
      destination,
      effectiveHero,
      clampedLat,
      clampedLng,
      remoteUrl: remoteImageUrl,
    );
    final flights = includeFlights ? _defaultDavaoFlights() : const <FlightOffer>[];

    // Authentic Davao Region waypoint library
    final List<({String name, String summary, double lat, double lng, TransportMode mode, String transit, int wmo, int temp})> waypoints;
    if (lower.contains('samal') || lower.contains('talikud') || lower.contains('pearl')) {
      waypoints = [
        (
          name: 'Davao City (DVO) & Sasa Wharf',
          summary: 'Arrive at Francisco Bangoy Airport, grab durian coffee, and board the barge across Pakiputan Strait.',
          lat: 7.1255,
          lng: 125.6458,
          mode: TransportMode.flight,
          transit: 'Flight to DVO Airport • 1h 55m',
          wmo: 1,
          temp: 31,
        ),
        (
          name: 'Babak & Monfort Bat Sanctuary',
          summary: 'Explore the 2-million fruit bat cave sanctuary and cool jungle cascades at Hagimit Falls.',
          lat: 7.1197,
          lng: 125.7024,
          mode: TransportMode.ferry,
          transit: 'Sasa Wharf Ferry to Samal • 15m',
          wmo: 2,
          temp: 30,
        ),
        (
          name: 'Kaputian & Pearl Farm Cove',
          summary: 'Relax on powdery white-sand beaches, kayak over coral flats, and catch golden sunset over Davao Gulf.',
          lat: 6.9794,
          lng: 125.7136,
          mode: TransportMode.car,
          transit: 'Samal Coastal Drive • 40m',
          wmo: 0,
          temp: 32,
        ),
        (
          name: 'Talikud Island & Coral Garden',
          summary: 'Outrigger boat hopping to Isla Reta, Babu Santa Lagoon, and vibrant giant-clam snorkeling walls.',
          lat: 6.9389,
          lng: 125.6978,
          mode: TransportMode.ferry,
          transit: 'Outrigger Boat to Talikud • 25m',
          wmo: 0,
          temp: 31,
        ),
      ];
    } else if (lower.contains('mati') || lower.contains('dahican') || lower.contains('aliwagwag') || lower.contains('oriental')) {
      waypoints = [
        (
          name: 'Davao City → Sleeping Dinosaur Overlook',
          summary: 'Scenic coastal drive east along Davao Gulf to Badas Point for panoramic views of Pujada Bay.',
          lat: 6.9394,
          lng: 126.1539,
          mode: TransportMode.car,
          transit: 'Coastal Van/Car via Tagum–Mati Hwy • 3h 15m',
          wmo: 1,
          temp: 30,
        ),
        (
          name: 'Dahican Beach & Pawikan Sanctuary',
          summary: 'Sunrise skimboarding and surfing on 7 km of Pacific swells plus sea turtle conservation walk.',
          lat: 6.9255,
          lng: 126.2772,
          mode: TransportMode.car,
          transit: 'Mati Coastal Road • 20m',
          wmo: 0,
          temp: 31,
        ),
        (
          name: 'Pujada Bay & Waniban Island',
          summary: 'Hop across jewel-toned waters to Waniban Island and Oak Sandbar with fresh grilled seafood.',
          lat: 6.8906,
          lng: 126.2297,
          mode: TransportMode.ferry,
          transit: 'Pujada Bay Pumpboat • 25m',
          wmo: 1,
          temp: 31,
        ),
        (
          name: 'Baganga Carolina Lake & Sunrise Blvd',
          summary: 'Drive north along the Pacific cliffs to kayak on emerald Carolina Lake and see Curtain Falls.',
          lat: 7.5750,
          lng: 126.5597,
          mode: TransportMode.car,
          transit: 'Pacific Highway North • 2h 10m',
          wmo: 2,
          temp: 29,
        ),
        (
          name: 'Cateel & Aliwagwag Falls Eco-Park',
          summary: 'Marvel at the 84-tier natural staircase of Aliwagwag Falls and ride the canopy zipline.',
          lat: 7.7819,
          lng: 126.3511,
          mode: TransportMode.car,
          transit: 'Cateel Mountain Road • 45m',
          wmo: 80,
          temp: 27,
        ),
      ];
    } else if (lower.contains('buda') || lower.contains('marilog') || lower.contains('apo') || lower.contains('kapatagan')) {
      waypoints = [
        (
          name: 'Davao City & San Pedro Heritage',
          summary: 'Visit San Pedro Cathedral, Museo Dabawenyo, and feast on tuna panga at Roxas Night Market.',
          lat: 7.0644,
          lng: 125.6088,
          mode: TransportMode.flight,
          transit: 'Arrive DVO Airport • 20m to Poblacion',
          wmo: 2,
          temp: 30,
        ),
        (
          name: 'Malagos Eagle Center & Eden Nature Park',
          summary: 'Meet the Philippine Eagle, taste single-origin Malagos chocolate, and ride the Skycycle in Toril.',
          lat: 7.1856,
          lng: 125.4175,
          mode: TransportMode.car,
          transit: 'Baguio–Toril Highland Drive • 45m',
          wmo: 2,
          temp: 24,
        ),
        (
          name: 'Buda Pine Highlands (Marilog)',
          summary: 'Cozy A-frame cabins, morning sea of clouds, strawberry farms, and cliffside coffee along Buda Highway.',
          lat: 7.4561,
          lng: 125.2498,
          mode: TransportMode.car,
          transit: 'Buda Scenic Highway • 1h 20m',
          wmo: 3,
          temp: 19,
        ),
        (
          name: 'Kapatagan & Mt. Apo Basecamp (Digos)',
          summary: 'Sip Mt. Apo Arabica coffee overlooking Lake Mirror with unobstructed views of the Philippines’ highest peak.',
          lat: 6.9292,
          lng: 125.3315,
          mode: TransportMode.car,
          transit: 'South Highland Ridge • 1h 45m',
          wmo: 1,
          temp: 20,
        ),
      ];
    } else {
      waypoints = [
        (
          name: 'Barangay San Pedro & Poblacion, Davao City',
          summary: 'Historic San Pedro Cathedral, Jack’s Ridge sunset dining, and Roxas Avenue Night Market.',
          lat: 7.0644,
          lng: 125.6088,
          mode: TransportMode.flight,
          transit: 'Arrive DVO Airport • 20m transfer',
          wmo: 1,
          temp: 31,
        ),
        (
          name: 'Samal Island (IGaCoS) & Talikud Reefs',
          summary: 'Quick ferry across Pakiputan Strait for Hagimit Falls, Monfort Bats, and Talikud Coral Garden.',
          lat: 7.0742,
          lng: 125.7089,
          mode: TransportMode.ferry,
          transit: 'Sta. Ana Wharf Boat • 20m',
          wmo: 0,
          temp: 32,
        ),
        (
          name: 'Tagum Palm City & Kopiat Island',
          summary: 'Explore Christ the King Cathedral in Tagum before crossing to Mabini’s Kopiat Island sanctuary.',
          lat: 7.4479,
          lng: 125.8078,
          mode: TransportMode.car,
          transit: 'Pan-Philippine Hwy North • 1h 10m',
          wmo: 2,
          temp: 30,
        ),
        (
          name: 'Maragusan Sea of Clouds (Davao de Oro)',
          summary: 'Wake up above misty mountain valleys at Haven’s Peak and dip in Mainit Hot Springs.',
          lat: 7.3508,
          lng: 126.1536,
          mode: TransportMode.car,
          transit: 'Nabunturan–Maragusan Pass • 1h 30m',
          wmo: 3,
          temp: 22,
        ),
        (
          name: 'Mati Dahican Beach & Pujada Bay',
          summary: 'Catch Pacific waves at Dahican, visit Sleeping Dinosaur, and island-hop in Pujada Bay.',
          lat: 6.9255,
          lng: 126.2772,
          mode: TransportMode.car,
          transit: 'Davao Oriental Coastal Hwy • 2h 15m',
          wmo: 0,
          temp: 31,
        ),
        (
          name: 'Eden Nature Park & Kapatagan (Mt. Apo)',
          summary: 'Cool pine forests in Toril followed by Mt. Apo Arabica coffee overlooking Lake Mirror.',
          lat: 6.9950,
          lng: 125.4100,
          mode: TransportMode.car,
          transit: 'Davao Bypass to Toril–Digos • 2h 00m',
          wmo: 2,
          temp: 21,
        ),
      ];
    }

    final days = <ItineraryDay>[];
    for (int d = 1; d <= daysCount; d++) {
      final wp = waypoints[(d - 1) % waypoints.length];
      days.add(
        ItineraryDay(
          dayNumber: d,
          cityTitle: 'Day $d • ${wp.name}',
          summary: wp.summary,
          lat: wp.lat,
          lng: wp.lng,
          wmoWeatherCode: wp.wmo,
          tempCelsius: wp.temp,
          transportFromPrevious: wp.mode,
          transportDuration: wp.transit,
          recommendedHotel: hotels[(d - 1) % hotels.length],
          stops: [
            ItineraryStop(
              time: '08:30 AM',
              title: 'Morning Highlight: ${wp.name.split('&').first.trim()}',
              description: wp.summary,
              category: 'sight',
              costEstimateUsd: 12,
              lat: wp.lat + 0.008,
              lng: wp.lng - 0.006,
            ),
            ItineraryStop(
              time: '12:30 PM',
              title: 'Mindanaoan Culinary Stop & Local Durian/Coffee',
              description:
                  'Savor grilled tuna panga, kinilaw, chicken inasal, or single-origin Mt. Apo coffee.',
              category: 'food',
              costEstimateUsd: 16,
              lat: wp.lat - 0.006,
              lng: wp.lng + 0.008,
            ),
            ItineraryStop(
              time: '04:30 PM',
              title: 'Golden Hour Viewpoint & Coastal/Highland Chill',
              description:
                  'Catch late-afternoon tropical light across the Davao Gulf, reefs, or pine ridges.',
              category: 'nature',
              costEstimateUsd: 14,
              lat: wp.lat + 0.011,
              lng: wp.lng + 0.009,
            ),
          ],
        ),
      );
    }

    const experts = [
      ('Carla Fernandez • Davao Coastal Curator', 'assets/experts/carla-fernandez.webp'),
      ('Ricardo Santos • Mindanao Trail Guide', 'assets/experts/ricardo.webp'),
      ('Robin Reyes • Samal & Mati Diver', 'assets/experts/robin.webp'),
    ];
    final expert = experts[tripId.hashCode.abs() % experts.length];

    return ItineraryTrip(
      id: tripId,
      title: cleanTitle,
      destination: destination,
      daysCount: daysCount,
      centerLat: clampedLat,
      centerLng: clampedLng,
      heroAsset: effectiveHero,
      vibeTag: vibe,
      overviewText:
          'Curated by Lakbay+ AI for Davao Region (Region XI). This $daysCount-day route connects authentic Mindanao islands, Pacific surf beaches, cool pine highlands, and vibrant Davao City culinary stops with seamless ferry and road legs.',
      bestMonths: 'Dec – May (Dry)',
      avgTemp: '29°C / 84°F',
      wmoWeatherCode: 1,
      expertName: expert.$1,
      expertAvatarAsset: expert.$2,
      expertTip:
          'Catch the 7:30 AM ferry from Sta. Ana Wharf or Sasa Barge before midday heat, and save Roxas Night Market for grilled tuna panga after sunset.',
      days: days,
      flights: flights,
      hotels: hotels,
      remoteImageUrl: remoteImageUrl,
      isLocalOnly: !includeFlights,
    );
  }

  List<HotelOffer> _buildDavaoHotels(
    String tripId,
    String destination,
    String effectiveHero,
    double lat,
    double lng, {
    String? remoteUrl,
  }) {
    final city = destination.split(',').first.split('(').first.trim();
    return [
      HotelOffer(
        id: 'ht_${tripId}_1',
        name: '$city Eco Lodge & Resort Stay',
        city: city,
        rating: 9.2,
        stars: 4,
        pricePerNightUsd: 65,
        facilities: const [
          'Breakfast Option',
          'Air Conditioning',
          'Wi-Fi',
          'Near Attraction',
        ],
        partnerName: 'Region XI Estimate',
        imageAsset: effectiveHero,
        remoteImageUrl: remoteUrl,
        lat: lat + 0.015,
        lng: lng - 0.01,
      ),
      HotelOffer(
        id: 'ht_${tripId}_2',
        name: '$city Budget Traveler Inn',
        city: city,
        rating: 8.7,
        stars: 3,
        pricePerNightUsd: 35,
        facilities: const [
          'Fan / AC Rooms',
          'Local Transport Access',
          'Free Wi-Fi',
        ],
        partnerName: 'Value Estimate',
        imageAsset: 'assets/home_backdrops/08-peoples-park.jpg',
        remoteImageUrl: remoteUrl,
        lat: lat - 0.018,
        lng: lng + 0.012,
      ),
    ];
  }

  /// Resolves the best origin label from the live GPS city or user profile.
  String get effectiveOriginLabel {
    final profileCity = _profile.location.trim();
    if (profileCity.isNotEmpty) return profileCity;
    if (hasUserLocation) return 'Current GPS Location';
    return 'Current Location';
  }

  /// Great-circle distance in kilometers between the user GPS fix and `(lat, lng)`.
  double distanceKmFromUser(double lat, double lng) {
    if (!hasUserLocation) return 0;
    const earthRadiusKm = 6371.0;
    final dLat = (lat - _userLat!) * math.pi / 180.0;
    final dLng = (lng - _userLng!) * math.pi / 180.0;
    final lat1 = _userLat! * math.pi / 180.0;
    final lat2 = lat * math.pi / 180.0;
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1) *
            math.cos(lat2) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    return 2 * earthRadiusKm * math.asin(math.min(1.0, math.sqrt(a)));
  }

  /// Resolves a destination photo thumbnail (`imageUrl` / `imageAsset`) for a day marker.
  ({String? imageUrl, String imageAsset}) resolveDayMarkerMedia(
    ItineraryTrip trip,
    ItineraryDay day,
  ) {
    final candidates = allTrips;
    final titleLower = day.cityTitle.toLowerCase();
    ExploreTrip? matched;
    if (day.apiDestinationId != null) {
      for (final candidate in candidates) {
        if (candidate.apiDestinationId == day.apiDestinationId) {
          matched = candidate;
          break;
        }
      }
    }
    matched ??= () {
      ExploreTrip? best;
      double bestDist = double.infinity;
      for (final candidate in candidates) {
        final candidateLower = candidate.title.toLowerCase();
        if (titleLower.contains(candidateLower) ||
            candidateLower.contains(titleLower.split('—').first.trim())) {
          return candidate;
        }
        final dLat = candidate.lat - day.lat;
        final dLng = candidate.lng - day.lng;
        final distSq = dLat * dLat + dLng * dLng;
        if (distSq < bestDist) {
          bestDist = distSq;
          best = candidate;
        }
      }
      return bestDist < 0.08 ? best : null;
    }();

    final remote = (matched != null && matched.hasRemoteThumbnail)
        ? matched.thumbnailUrl
        : (trip.remoteImageUrl != null &&
                (trip.remoteImageUrl!.startsWith('http://') ||
                    trip.remoteImageUrl!.startsWith('https://'))
            ? trip.remoteImageUrl
            : null);
    final asset = matched?.localAssetPath ??
        (trip.heroAsset.isNotEmpty
            ? trip.heroAsset
            : currentBackdrop.localAssetPath);
    return (imageUrl: remote, imageAsset: asset);
  }

  bool _didAutoDetectOnShellEntry = false;

  /// Refreshes current GPS location silently on startup when permission is already granted.
  Future<bool> refreshCurrentLocationSilently() async {
    try {
      final hasPermission = await locationService.hasGrantedPermission();
      if (!hasPermission && locationService.customFetcher == null) {
        return false;
      }
      if (!locationSharingEnabled) return false;
      final res = await locationService.captureCurrentLocation();
      if (!res.granted || res.lat == null || res.lng == null) {
        return false;
      }
      _userLat = res.lat;
      _userLng = res.lng;
      if (res.resolvedLabel != null && res.resolvedLabel!.trim().isNotEmpty) {
        _profile = _profile.copyWith(location: res.resolvedLabel!.trim());
      }
      _scheduleSaveState();
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Auto-detects GPS location once upon entering the main app shell when missing.
  Future<void> autoDetectLocationOnShellEntry() async {
    if (_didAutoDetectOnShellEntry) return;
    _didAutoDetectOnShellEntry = true;
    if (!locationSharingEnabled || hasUserLocation) return;
    try {
      final res = await locationService.captureCurrentLocation();
      if (!res.granted || res.lat == null || res.lng == null) {
        return;
      }
      _userLat = res.lat;
      _userLng = res.lng;
      if (res.resolvedLabel != null && res.resolvedLabel!.trim().isNotEmpty) {
        _profile = _profile.copyWith(location: res.resolvedLabel!.trim());
      }
      _scheduleSaveState();
      notifyListeners();
    } catch (_) {
      // Never block shell startup or clobber settings if platform GPS is unavailable.
    }
  }
}

extension _NullableLet<T> on T? {
  R? letOrNull<R>(R? Function(T) fn) => this == null ? null : fn(this as T);
}
