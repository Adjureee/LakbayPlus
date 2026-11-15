import 'dart:convert';
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
  TravelRepository({
    LakbayApiCatalogService? apiCatalog,
    LocationService? locationService,
    GoogleAuthService? googleAuthService,
  })  : apiCatalog = apiCatalog ?? LakbayApiCatalogService(),
        locationService = locationService ?? LocationService(),
        googleAuthService = googleAuthService ?? GoogleAuthService();

  final MapboxService mapbox = MapboxService();
  final LakbayAiService aiService = LakbayAiService();
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
          id: '04-thoddoo',
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
  String temperatureUnit = 'C'; // 'C' or 'F'
  String preferredPaymentMethod = 'Set at checkout';
  final String travelerId = 'lkb9K2mP7x0r12';

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

  // Booking Basket
  final List<BasketItem> _basket = [];
  List<BasketItem> get basket => List.unmodifiable(_basket);

  // User Profile & Navigation State
  UserProfile _profile = const UserProfile();
  UserProfile get profile => _profile;

  int _activeNavIndex = 2; // 0: Trips, 1: Discover, 2: Chat (center), 3: Bookings, 4: Profile
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

  final List<BookedReservation> _bookings = [];
  List<BookedReservation> get bookings => List.unmodifiable(_bookings);

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
        'basket': _basket.map((b) => b.toJson()).toList(),
        'bookings': _bookings.map((r) => r.toJson()).toList(),
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
      final basketList = map['basket'] as List<dynamic>?;
      if (basketList != null) {
        _basket
          ..clear()
          ..addAll(
            basketList
                .whereType<Map<String, dynamic>>()
                .map(BasketItem.fromJson),
          );
      }
      final bookingsList = map['bookings'] as List<dynamic>?;
      if (bookingsList != null) {
        _bookings
          ..clear()
          ..addAll(
            bookingsList
                .whereType<Map<String, dynamic>>()
                .map(BookedReservation.fromJson),
          );
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
    notifyListeners();
  }

  void selectChatSession(String id) {
    final idx = _chatSessions.indexWhere((s) => s.id == id);
    if (idx < 0) return;
    _activeChatId = id;
    _chatMessages
      ..clear()
      ..addAll(_chatSessions[idx].messages);
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

  void _applyAuthSession(LakbayAuthSession session) {
    _authSession = session;
    final parts = session.fullName
        .trim()
        .split(RegExp(r'\s+'))
        .where((s) => s.isNotEmpty)
        .toList();
    _profile = _profile.copyWith(
      firstName: parts.isNotEmpty ? parts.first : _profile.firstName,
      lastName: parts.length > 1 ? parts.sublist(1).join(' ') : '',
      email: session.email,
    );
    _scheduleSaveState();
    notifyListeners();
  }

  Future<void> signOutBackend() async {
    final refreshToken = _authSession?.refreshToken ?? '';
    _authSession = null;
    if (refreshToken.isNotEmpty) {
      await apiCatalog.logout(refreshToken);
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
      final base = generateCustomTrip(
        id: 'cloud_$tripId',
        title: title,
        destination: title,
        daysCount: 3,
        vibe: 'Cloud Synced Trip',
      );
      _savedTrips.add(
        ItineraryTrip(
          id: base.id,
          title: base.title,
          destination: row['description']?.toString() ?? base.destination,
          daysCount: base.daysCount,
          adults: (row['traveler_count'] as num?)?.toInt() ?? 2,
          centerLat: base.centerLat,
          centerLng: base.centerLng,
          heroAsset: base.heroAsset,
          vibeTag: base.vibeTag,
          overviewText: row['notes']?.toString() ??
              'Synced from your Lakbay+ cloud account (est. ₱${estCostPhp.toStringAsFixed(0)}, ~${(estCostPhp / phpRate).round()} USD).',
          bestMonths: base.bestMonths,
          avgTemp: base.avgTemp,
          expertName: base.expertName,
          expertTip: base.expertTip,
          days: base.days,
          flights: base.flights,
          hotels: base.hotels,
          backendTripId: tripId,
          backendDestinationIds: destIds,
        ),
      );
      updated = true;
    }
    if (updated) {
      _scheduleSaveState();
      notifyListeners();
    }
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

    final mergedHotels = <HotelOffer>[
      ...market.hotels,
      ...trip.hotels.where((h) => !h.id.startsWith('acc_')),
    ];

    final updatedDays = trip.days.map((d) {
      if (weather == null || d.dayNumber != 1) return d;
      return d.copyWith(
        tempCelsius: weather.tempC,
        wmoWeatherCode: weather.wmoCode,
      );
    }).toList();

    final enriched = trip.copyWith(
      hotels: mergedHotels,
      avgTemp: weather != null
          ? '${weather.tempC}°C • ${weather.condition}'
          : null,
      wmoWeatherCode: weather?.wmoCode,
      days: updatedDays,
    );

    final savedIdx = _savedTrips.indexWhere((t) => t.id == trip.id);
    if (savedIdx >= 0) {
      _savedTrips[savedIdx] = enriched;
      _scheduleSaveState();
      notifyListeners();
    }
    return enriched;
  }

  Future<BackendRouteResult?> fetchRoadRouteForTrip(
    ItineraryTrip trip, {
    bool optimize = false,
  }) async {
    final destIds = trip.effectiveBackendDestinationIds;
    if (!isSignedIn || destIds.isEmpty || !apiCatalog.isConfigured) {
      return null;
    }
    if (optimize && destIds.length >= 2) {
      return apiCatalog.optimizeRoute(
        _authSession!.accessToken,
        destinationIds: destIds,
      );
    }
    return apiCatalog.previewRoute(
      _authSession!.accessToken,
      destinationIds: destIds,
    );
  }

  Future<BookedReservation> recordReservationCheckout({
    required String paymentMethod,
  }) async {
    final items = List<BasketItem>.from(_basket);
    final totalUsd = basketTotalUsd;
    final phpRate = _currencyRates['PHP'] ?? 57.0;
    final destIds = items
        .map((i) => i.backendDestinationId)
        .whereType<int>()
        .toSet()
        .toList();
    if (destIds.isEmpty) {
      for (final saved in _savedTrips) {
        destIds.addAll(saved.effectiveBackendDestinationIds);
      }
    }

    int? cloudTripId;
    var synced = false;
    final summaryTitle = items.isNotEmpty
        ? '${items.first.title}${items.length > 1 ? ' + ${items.length - 1} more' : ''}'
        : 'Davao Region Reservation';

    if (isSignedIn && destIds.isNotEmpty && apiCatalog.isConfigured) {
      cloudTripId = await apiCatalog.createTrip(
        _authSession!.accessToken,
        title: summaryTitle,
        totalBudgetPhp: (totalUsd * phpRate).clamp(500, 9999999),
        estimatedTotalCostPhp: (totalUsd * phpRate).clamp(0, 9999999),
        destinationIds: destIds.toSet().toList(),
        notes: 'Reserved in Lakbay+ ($paymentMethod): '
            '${items.map((i) => i.title).join(', ')}',
      );
      synced = cloudTripId != null;
    }

    final record = BookedReservation(
      id: 'res_${DateTime.now().millisecondsSinceEpoch}',
      summaryTitle: summaryTitle,
      itemsSummary: items.map((i) => '${i.category}: ${i.title}').join(' • '),
      totalUsd: totalUsd,
      paymentMethod: paymentMethod,
      bookedAtIso: DateTime.now().toIso8601String(),
      backendTripId: cloudTripId,
      syncedToCloud: synced,
    );

    preferredPaymentMethod = paymentMethod;
    _bookings.insert(0, record);
    _basket.clear();
    _scheduleSaveState();
    notifyListeners();
    return record;
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
    _profile = const UserProfile();
    _savedTrips.clear();
    _basket.clear();
    _bookings.clear();
    _chatMessages.clear();
    _authSession = null;
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

    if (isSignedIn &&
        trip.backendTripId == null &&
        trip.effectiveBackendDestinationIds.isNotEmpty) {
      final phpRate = _currencyRates['PHP'] ?? 57.0;
      final totalPhp = (trip.totalEstimatedCostUsd * phpRate).clamp(100, 9999999).toDouble();
      apiCatalog
          .createTrip(
            _authSession!.accessToken,
            title: trip.title,
            description: trip.destination,
            travelerCount: trip.adults + trip.children,
            totalBudgetPhp: totalPhp,
            estimatedTotalCostPhp: totalPhp,
            destinationIds: trip.effectiveBackendDestinationIds,
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
    }
  }

  void removeSavedTrip(String tripId) {
    _savedTrips.removeWhere((t) => t.id == tripId);
    _scheduleSaveState();
    notifyListeners();
  }

  void addToBasket(BasketItem item) {
    if (!_basket.any((b) => b.id == item.id)) {
      _basket.add(item);
      _scheduleSaveState();
      notifyListeners();
    }
  }

  void removeFromBasket(String id) {
    _basket.removeWhere((b) => b.id == id);
    _scheduleSaveState();
    notifyListeners();
  }

  void clearBasket() {
    _basket.clear();
    _scheduleSaveState();
    notifyListeners();
  }

  int get basketTotalUsd =>
      _basket.fold(0, (sum, item) => sum + item.priceUsd);

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
    final sampleExplore = _allTrips.take(3).toList();
    if (sampleExplore.isNotEmpty) {
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
          messages: [samalWelcomeMsg],
        ),
      ]);
      _activeChatId = 'chat_new';
    }

    if (_basket.isEmpty &&
        firstTrip.hotels.isNotEmpty &&
        firstTrip.flights.isNotEmpty) {
      _basket.add(
        BasketItem(
          id: 'flight_${firstTrip.id}',
          title:
              '${firstTrip.flights.first.originCode} → ${firstTrip.flights.first.destinationCode} Roundtrip',
          subtitle:
              '${firstTrip.flights.first.airline} • Direct (${firstTrip.flights.first.duration})',
          category: 'Flight',
          priceUsd:
              firstTrip.flights.first.priceRoundtripUsd * firstTrip.adults,
          imageAsset: firstTrip.heroAsset,
        ),
      );
      _basket.add(
        BasketItem(
          id: 'hotel_${firstTrip.id}',
          title: firstTrip.hotels.first.name,
          subtitle:
              '${firstTrip.daysCount - 1} nights • ${firstTrip.hotels.first.stars}★ Davao Stay',
          category: 'Hotel',
          priceUsd: firstTrip.hotels.first.pricePerNightUsd *
              (firstTrip.daysCount - 1),
          imageAsset: firstTrip.heroAsset,
        ),
      );
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

    if (isSignedIn && apiCatalog.isConfigured) {
      _isAiTyping = true;
      notifyListeners();
      try {
        final history = _chatMessages
            .take(_chatMessages.length > 1 ? _chatMessages.length - 1 : 0)
            .take(6)
            .map((m) => {'role': m.isUser ? 'user' : 'assistant', 'content': m.text})
            .toList();
        final serverAi = await apiCatalog.aiChat(
          _authSession!.accessToken,
          message: trimmed,
          history: history,
        );
        if (serverAi != null) {
          final attachPlan = RegExp(
            r'\b(plan|itinerary|trip|route|days|samal|mati|buda|apo|maragusan|tagum|davao)\b',
            caseSensitive: false,
          ).hasMatch(trimmed);
          final attachedTrip =
              attachPlan ? _generateLocalFallbackTrip(trimmed) : null;
          _chatMessages.add(
            ChatMessage(
              id: 'ai_${DateTime.now().millisecondsSinceEpoch}',
              isUser: false,
              text:
                  '${serverAi.replyText}\n\n_Powered by Lakbay+ Server AI (${serverAi.modelId})_',
              timestamp: DateTime.now(),
              attachedTrip: attachedTrip,
              suggestedReplies: const [
                'Show 2-day weekend version 🗓️',
                'Add Samal ferry & boat transfers ⛴️',
                'Include Malagos & Roxas Night Market 🍢',
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
            suggestedReplies: const [
              'Show 2-day weekend version 🗓️',
              'Add Samal ferry & boat transfers ⛴️',
              'Include Malagos & Roxas Night Market 🍢',
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

  ItineraryTrip _generateLocalFallbackTrip(String prompt) {
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

    if (lower.contains('samal') ||
        lower.contains('talikud') ||
        lower.contains('pearl farm') ||
        lower.contains('island')) {
      return generateCustomTrip(
        destination: 'Samal Island (IGaCoS) & Talikud Reefs',
        daysCount: requestedDays,
        vibe: 'Island Hopping & Coral Coves',
        heroAsset: 'assets/home_backdrops/04-thoddoo.jpg',
        centerLat: 7.0742,
        centerLng: 125.7089,
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
        heroAsset: 'assets/home_backdrops/09-whitehaven-beach.jpg',
        centerLat: 6.9551,
        centerLng: 126.2185,
      );
    } else if (lower.contains('buda') ||
        lower.contains('marilog') ||
        lower.contains('pine') ||
        lower.contains('cabin')) {
      return generateCustomTrip(
        destination: 'Buda & Marilog Pine Highlands, Davao City',
        daysCount: requestedDays,
        vibe: 'Misty Pine Cabins & Cafes',
        heroAsset: 'assets/home_backdrops/02-seceda.jpg',
        centerLat: 7.4561,
        centerLng: 125.2498,
      );
    } else if (lower.contains('apo') ||
        lower.contains('kapatagan') ||
        lower.contains('digos') ||
        lower.contains('sta. cruz')) {
      return generateCustomTrip(
        destination: 'Kapatagan Highlands & Mt. Apo, Davao del Sur',
        daysCount: requestedDays,
        vibe: 'Volcanic Peaks & Coffee Ridges',
        heroAsset: 'assets/home_backdrops/10-lago-di-braies.jpg',
        centerLat: 6.9292,
        centerLng: 125.3315,
      );
    } else if (lower.contains('maragusan') ||
        lower.contains('kopiat') ||
        lower.contains('de oro') ||
        lower.contains('tagum')) {
      return generateCustomTrip(
        destination: 'Tagum, Kopiat Island & Maragusan Highlands',
        daysCount: requestedDays,
        vibe: 'Sea of Clouds & Gulf Islands',
        heroAsset: 'assets/home_backdrops/03-lake-louise.jpg',
        centerLat: 7.3508,
        centerLng: 126.1536,
      );
    } else {
      return buildDetailedItineraryFromExplore(
        matchedExplore,
        overrideDays: requestedDays,
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
      flights: const [
        FlightOffer(
          id: 'fl_dvo_ai',
          airline: 'Philippine Airlines / Cebu Pacific',
          originCode: 'MNL',
          destinationCode: 'DVO',
          duration: '1h 50m',
          isDirect: true,
          priceRoundtripUsd: 145,
        ),
      ],
      hotels: [
        HotelOffer(
          id: 'ht_dvo_ai',
          name: 'Davao Coastal & Highland Stay',
          city: dest,
          rating: 4.7,
          stars: 4,
          pricePerNightUsd: 78,
          facilities: const ['Wi-Fi', 'Breakfast', 'Airport Transfer'],
          partnerName: 'Lakbay+ Partner',
          imageAsset: currentBackdrop.localAssetPath,
          lat: fallbackCenter.$1,
          lng: fallbackCenter.$2,
        ),
      ],
    );
  }

  ItineraryTrip buildDetailedItineraryFromExplore(
    ExploreTrip explore, {
    int? overrideDays,
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
      centerLat: explore.lat,
      centerLng: explore.lng,
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

    final cachedHotels =
        destId != null ? (_hotelRatesByDestId[destId] ?? const []) : const [];

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
      hotels: cachedHotels.isNotEmpty
          ? [...cachedHotels, ...base.hotels]
          : base.hotels,
      backendDestinationId: destId,
      backendDestinationIds: destId != null ? [destId] : const [],
    );
  }

  ItineraryTrip generateCustomTrip({
    String? id,
    String? title,
    required String destination,
    required int daysCount,
    required String vibe,
    String? heroAsset,
    double? centerLat,
    double? centerLng,
  }) {
    final tripId = id ?? 'davao_${DateTime.now().millisecondsSinceEpoch}';
    final effectiveHero = heroAsset ?? currentBackdrop.localAssetPath;
    final cleanTitle = title ?? '$daysCount-Day $destination';

    final (clampedLat, clampedLng) = MapboxService.clampToDavaoRegion(
      centerLat ?? MapboxService.davaoCenterLat,
      centerLng ?? MapboxService.davaoCenterLng,
    );

    final lower = destination.toLowerCase();
    final hotels = _buildDavaoHotels(tripId, destination, effectiveHero, clampedLat, clampedLng);
    final flights = <FlightOffer>[
      const FlightOffer(
        id: 'fl_mnl_dvo',
        airline: 'Philippine Airlines / Cebu Pacific',
        originCode: 'MNL',
        destinationCode: 'DVO',
        duration: '1h 55m',
        isDirect: true,
        priceRoundtripUsd: 88,
      ),
      const FlightOffer(
        id: 'fl_ceb_dvo',
        airline: 'Cebu Pacific • Visayas–Mindanao',
        originCode: 'CEB',
        destinationCode: 'DVO',
        duration: '1h 10m',
        isDirect: true,
        priceRoundtripUsd: 54,
      ),
    ];

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
    );
  }

  List<HotelOffer> _buildDavaoHotels(
    String tripId,
    String destination,
    String effectiveHero,
    double lat,
    double lng,
  ) {
    final city = destination.split(',').first;
    return [
      HotelOffer(
        id: 'ht_${tripId}_1',
        name: 'Pearl Farm & Coastal Suites',
        city: city,
        rating: 9.5,
        stars: 5,
        pricePerNightUsd: 145,
        facilities: const [
          'Private Cove',
          'Breakfast Included',
          'Infinity Pool',
          'Boat Transfer',
        ],
        partnerName: 'Davao Direct Rate',
        imageAsset: effectiveHero,
        lat: lat + 0.02,
        lng: lng - 0.01,
      ),
      HotelOffer(
        id: 'ht_${tripId}_2',
        name: 'Discovery Samal / Mati Beachfront Villa',
        city: city,
        rating: 9.2,
        stars: 4,
        pricePerNightUsd: 95,
        facilities: const [
          'Ocean View',
          'Air Conditioning',
          'Free Wi-Fi',
          'Kayak Rental',
        ],
        partnerName: 'Lakbay+ Partner',
        imageAsset: 'assets/home_backdrops/04-thoddoo.jpg',
        lat: lat - 0.03,
        lng: lng + 0.03,
      ),
      HotelOffer(
        id: 'ht_${tripId}_3',
        name: 'DusitD2 / Buda Highland Pine Lodge',
        city: city,
        rating: 9.0,
        stars: 4,
        pricePerNightUsd: 78,
        facilities: const [
          'Mountain / City View',
          'Local Coffee Bar',
          'Airport Shuttle',
        ],
        partnerName: 'Eco Verified',
        imageAsset: 'assets/home_backdrops/02-seceda.jpg',
        lat: lat + 0.04,
        lng: lng + 0.02,
      ),
    ];
  }
}
