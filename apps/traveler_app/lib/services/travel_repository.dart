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
import 'notification_routing.dart';
import 'push_notification_service.dart';
import 'route_optimizer.dart';

class TravelRepository extends ChangeNotifier {
  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    _liveSubscription?.cancel();
    _notificationTimer?.cancel();
    pushService.dispose();
    super.dispose();
  }

  TravelRepository({
    LakbayApiCatalogService? apiCatalog,
    LocationService? locationService,
    GoogleAuthService? googleAuthService,
    PushNotificationService? pushService,
  })  : apiCatalog = apiCatalog ?? LakbayApiCatalogService(),
        locationService = locationService ?? LocationService(),
        googleAuthService = googleAuthService ?? GoogleAuthService(),
        pushService = pushService ?? PushNotificationService() {
    this.apiCatalog.onUnauthorizedRefresh = _refreshAuthAccessToken;
  }

  final MapboxService mapbox = MapboxService();
  late final LakbayAiService aiService = LakbayAiService(
    backend: apiCatalog,
    accessToken: () => _authSession?.accessToken,
  );
  final CloudinaryService cloudinary = CloudinaryService();
  final LakbayApiCatalogService apiCatalog;
  final LocationService locationService;
  final GoogleAuthService googleAuthService;
  final PushNotificationService pushService;

  bool _isAiTyping = false;
  bool get isAiTyping => _isAiTyping;
  String? _aiTypingStatus;
  String? get aiTypingStatus => _aiTypingStatus;

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

  static const List<String> supportedAiLanguages = [
    'auto',
    'english',
    'filipino',
    'bisaya',
  ];
  String _aiLanguage = 'auto';
  String get aiLanguage => _aiLanguage;

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

  List<SuggestedRoute> _suggestedRoutes = [];
  List<SuggestedRoute> get suggestedRoutes => List.unmodifiable(_suggestedRoutes);

  List<CityDescription> _cityDescriptions = [];
  List<CityDescription> get cityDescriptions => _cityDescriptions;

  // User Preferences collected during Onboarding
  // Chosen by the traveler from the catalog's preference groups; nothing is
  // pre-selected.
  final Set<String> selectedVibes = <String>{};
  final Set<String> selectedHelpNeeds = {
    'choose_where_to_go',
    'build_itinerary'
  };
  String travelCompanion = 'Couple';
  bool priceDropAlertsEnabled = true;
  bool locationSharingEnabled = true;
  double? _userLat;
  double? _userLng;
  double? _manualOriginLat;
  double? _manualOriginLng;
  String? _manualOriginLabel;

  double? get userLat => _userLat;
  double? get userLng => _userLng;
  bool get hasUserLocation => _userLat != null && _userLng != null;

  double? get originLat => _manualOriginLat ?? _userLat;
  double? get originLng => _manualOriginLng ?? _userLng;
  bool get hasManualOrigin =>
      _manualOriginLat != null && _manualOriginLng != null;
  bool get hasOrigin =>
      hasUserLocation ||
      hasManualOrigin ||
      _profile.location.trim().isNotEmpty;

  bool get isOriginOutsideRegionXi {
    final lat = originLat;
    final lng = originLng;
    if (lat == null || lng == null) return false;
    return !MapboxService.isInsideDavaoRegion(lat, lng);
  }

  String? get originRegionNote => isOriginOutsideRegionXi
      ? 'Your starting point is outside Davao Region (Region XI). Road routes are planned inside Region XI.'
      : null;

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
    // Defer notification so calling stopLiveTracking() from State.dispose()
    // never fires listeners while the widget tree is locked.
    Future<void>.microtask(() {
      if (!_disposed && _liveTrackingClients == 0 && hasListeners) {
        notifyListeners();
      }
    });
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
  LocationPermissionOutcome _lastLocationOutcome =
      LocationPermissionOutcome.denied;
  LocationPermissionOutcome get lastLocationOutcome =>
      (locationSharingEnabled && hasUserLocation)
          ? LocationPermissionOutcome.granted
          : _lastLocationOutcome;
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

  ExploreTrip resolveExploreTripForRecommendation(TopPlaceRecommendation item) {
    final targetApiId = 'api_${item.destinationId}';
    for (final trip in _allTrips) {
      if (trip.apiDestinationId == item.destinationId || trip.id == targetApiId) {
        return trip;
      }
    }
    final normalizedName = item.name.trim().toLowerCase();
    for (final trip in _allTrips) {
      if (trip.title.trim().toLowerCase() == normalizedName) {
        return trip;
      }
    }
    // The server sends each card's own pin. Only an older server omits it; then
    // the place sits at the traveler's start point (or the region center)
    // until the catalog syncs, rather than at an invented spot.
    final fallbackLat =
        item.lat ?? (hasOrigin ? originLat! : MapboxService.davaoCenterLat);
    final fallbackLng =
        item.lng ?? (hasOrigin ? originLng! : MapboxService.davaoCenterLng);
    return ExploreTrip(
      locale: _locale,
      id: targetApiId,
      title: item.name,
      days: 1,
      lat: fallbackLat,
      lng: fallbackLng,
      thumbnailUrl: item.imageUrl ?? '',
      tag: item.category,
      apiDestinationId: item.destinationId,
      district: item.district,
      estimatedCostPhp: item.estimatedCost,
    );
  }

  static const int maxTripBuilderStops = 12;

  final RouteOptimizer _routeOptimizer = RouteOptimizer();
  String? _builderLockedFirstStopId;
  final Set<String> _builderOptionalStopIds = <String>{};
  String _builderStartMode = 'gps'; // 'gps' | 'hotel' | 'first_stop'
  GeoPoint? _builderHotelOrigin;
  bool _builderRoundtrip = false;
  TripPace _builderPace = TripPace.balanced;

  static const List<GeoPoint> davaoHotelPresets = [
    GeoPoint(
      lat: 7.1056,
      lng: 125.6378,
      label: 'Waterfront Insular Hotel Davao',
    ),
    GeoPoint(
      lat: 7.0644,
      lng: 125.5960,
      label: 'Acacia Hotel Davao / SM Lanang',
    ),
    GeoPoint(
      lat: 7.0731,
      lng: 125.6128,
      label: 'Marco Polo / Downtown Davao',
    ),
    GeoPoint(
      lat: 7.0970,
      lng: 125.6275,
      label: 'Dusit D2 Davao (Lanang)',
    ),
  ];

  String? get builderLockedFirstStopId => _builderLockedFirstStopId;
  String get builderStartMode => _builderStartMode;
  GeoPoint get builderHotelOrigin =>
      _builderHotelOrigin ?? davaoHotelPresets.first;
  bool get builderRoundtrip => _builderRoundtrip;
  TripPace get builderPace => _builderPace;

  bool isStopMustVisit(String stopId) =>
      !_builderOptionalStopIds.contains(stopId);

  void toggleTripBuilderStop(ExploreTrip stop) {
    final idx = _tripBuilderStops.indexWhere((s) => s.id == stop.id);
    if (idx >= 0) {
      _tripBuilderStops.removeAt(idx);
      _builderOptionalStopIds.remove(stop.id);
      if (_builderLockedFirstStopId == stop.id) {
        _builderLockedFirstStopId = null;
      }
    } else if (_tripBuilderStops.length < maxTripBuilderStops) {
      _tripBuilderStops.add(stop);
    }
    notifyListeners();
  }

  void removeTripBuilderStop(String stopId) {
    _tripBuilderStops.removeWhere((s) => s.id == stopId);
    _builderOptionalStopIds.remove(stopId);
    if (_builderLockedFirstStopId == stopId) {
      _builderLockedFirstStopId = null;
    }
    notifyListeners();
  }

  void toggleLockedFirstStop(String stopId) {
    if (_builderLockedFirstStopId == stopId) {
      _builderLockedFirstStopId = null;
    } else {
      _builderLockedFirstStopId = stopId;
      // Locking a stop as first requires keeping it in the itinerary.
      _builderOptionalStopIds.remove(stopId);
    }
    notifyListeners();
  }

  void toggleStopMustVisit(String stopId) {
    if (_builderLockedFirstStopId == stopId) return;
    if (_builderOptionalStopIds.contains(stopId)) {
      _builderOptionalStopIds.remove(stopId);
    } else {
      _builderOptionalStopIds.add(stopId);
    }
    notifyListeners();
  }

  void setBuilderStartMode(String mode, {GeoPoint? hotelOrigin}) {
    _builderStartMode = mode;
    if (hotelOrigin != null) {
      _builderHotelOrigin = hotelOrigin;
    }
    if (mode == 'first_stop') {
      _builderRoundtrip = false;
    }
    notifyListeners();
  }

  void setBuilderRoundtrip(bool value) {
    _builderRoundtrip = value;
    notifyListeners();
  }

  void setBuilderPace(TripPace pace) {
    _builderPace = pace;
    notifyListeners();
  }

  /// Pre-fills the Trip Tray with single places from a curated suggested route.
  int applySuggestedRoute(SuggestedRoute route) {
    _tripBuilderStops.clear();
    _builderOptionalStopIds.clear();
    _builderLockedFirstStopId = null;
    for (final destId in route.destinationIds) {
      if (_tripBuilderStops.length >= maxTripBuilderStops) break;
      final place = _tripsById[destId];
      if (place != null && !_tripBuilderStops.any((s) => s.id == place.id)) {
        _tripBuilderStops.add(place);
      }
    }
    notifyListeners();
    return _tripBuilderStops.length;
  }

  void clearTripBuilder() {
    if (_tripBuilderStops.isEmpty &&
        _builderLockedFirstStopId == null &&
        _builderOptionalStopIds.isEmpty) {
      return;
    }
    _tripBuilderStops.clear();
    _builderOptionalStopIds.clear();
    _builderLockedFirstStopId = null;
    notifyListeners();
  }

  /// Pre-fills the Trip Builder from catalog places matching [cityOrQuery].
  /// Used by Davao Region Encyclopedia and Explore offline/instant plans.
  int seedTripBuilderForPlace(String cityOrQuery, {int limit = 5}) {
    final needle = cityOrQuery.trim().toLowerCase();
    if (needle.isEmpty) return 0;

    final ignoreTokens = {'city', 'island', 'region', 'municipality', 'province'};
    final terms = needle
        .split(RegExp(r'[^a-z0-9]+'))
        .where((t) => t.length >= 2 && !ignoreTokens.contains(t))
        .toList();

    final primary = <ExploreTrip>[];
    final secondary = <ExploreTrip>[];
    final seenIds = <String>{};

    bool matchesField(String field) {
      final lower = field.toLowerCase();
      if (lower.contains(needle)) return true;
      return terms.isNotEmpty && terms.every(lower.contains);
    }

    for (final place in _allTrips) {
      if (matchesField('${place.regionName} ${place.district ?? ''} ${place.title}')) {
        if (seenIds.add(place.id)) primary.add(place);
      } else if (matchesField('${place.description} ${place.tag}')) {
        if (seenIds.add(place.id)) secondary.add(place);
      }
    }

    final candidates = [...primary, ...secondary];
    if (candidates.isEmpty && terms.isNotEmpty) {
      for (final place in _allTrips) {
        final hay =
            '${place.regionName} ${place.district ?? ''} ${place.title} ${place.description}'
                .toLowerCase();
        if (terms.any((t) => t != 'davao' && hay.contains(t)) &&
            seenIds.add(place.id)) {
          candidates.add(place);
        }
      }
    }

    _tripBuilderStops.clear();
    _builderOptionalStopIds.clear();
    _builderLockedFirstStopId = null;
    for (final place in candidates.take(limit)) {
      _tripBuilderStops.add(place);
    }
    notifyListeners();
    return _tripBuilderStops.length;
  }

  RouteStopInput _exploreTripToRouteStop(
    ExploreTrip stop, {
    bool mustVisit = true,
  }) {
    final cleanTitle = stop.title.split('—').first.trim();
    return RouteStopInput(
      id: stop.id,
      name: cleanTitle.isEmpty ? stop.title : cleanTitle,
      lat: stop.lat,
      lng: stop.lng,
      islandGroup: stop.islandGroup,
      stayDurationType: normalizeStayDurationKey(
        normalizeStayDurationType(
          stop.stayDurationType,
          category: stop.tag ?? '',
          overnightFee: stop.overnightFee ?? '',
        ),
      ),
      mustVisit: mustVisit,
    );
  }

  GeoPoint? resolveBuilderOriginPoint({
    String? startMode,
    GeoPoint? hotelOrigin,
  }) {
    final effectiveMode = startMode ?? _builderStartMode;
    switch (effectiveMode) {
      case 'hotel':
        return hotelOrigin ?? builderHotelOrigin;
      case 'first_stop':
        return null;
      case 'gps':
      default:
        return _routeOriginFromUserLocation();
    }
  }

  GeoCoord? _resolveBuilderOriginCoord({
    String? startMode,
    GeoPoint? hotelOrigin,
  }) {
    final pt = resolveBuilderOriginPoint(
      startMode: startMode,
      hotelOrigin: hotelOrigin,
    );
    if (pt == null) return null;
    return GeoCoord(
      lat: pt.lat,
      lng: pt.lng,
      islandGroup: _inferIslandGroupFromCoords(pt.lat, pt.lng),
      label: pt.label ?? 'Starting Point',
    );
  }

  int suggestedTripBuilderDays({TripPace? pace}) {
    if (_tripBuilderStops.isEmpty) return 1;
    return previewTripBuilderPlan(days: 1, pace: pace).suggestedDays;
  }

  /// Instant synchronous multi-day route preview computed purely on device.
  RoutePlanResult previewTripBuilderPlan({
    required int days,
    TripPace? pace,
    String? startMode,
    GeoPoint? hotelOrigin,
    bool? roundtrip,
    bool pruneOptionalToFit = false,
  }) {
    final inputs = _tripBuilderStops
        .map((s) => _exploreTripToRouteStop(s, mustVisit: isStopMustVisit(s.id)))
        .toList();
    final effectiveMode = startMode ?? _builderStartMode;
    final originCoord = _resolveBuilderOriginCoord(
      startMode: effectiveMode,
      hotelOrigin: hotelOrigin,
    );
    final effectiveRoundtrip =
        (roundtrip ?? _builderRoundtrip) && originCoord != null;
    return _routeOptimizer.planRoute(
      stops: inputs,
      days: days.clamp(1, 14),
      pace: pace ?? _builderPace,
      origin: originCoord,
      roundtrip: effectiveRoundtrip,
      lockedFirstId: _builderLockedFirstStopId,
      driving: preferredTravelMode == 'driving',
      pruneOptionalToFit: pruneOptionalToFit,
    );
  }

  void resetPlanningState() {
    _planningState = null;
    _planningRevision = 0;
    _prioritySkipped = false;
  }

  /// Prepares a fresh, clean planning session when entering onboarding without
  /// notifying listeners during widget initialization.
  void resetPlanningForOnboarding() {
    _chatMessages.clear();
    _tripBuilderStops.clear();
    _builderOptionalStopIds.clear();
    _builderLockedFirstStopId = null;
    resetPlanningState();
    _ensurePlanningState();
  }

  /// Updates whole-trip budget in the current planning state and bumps revision.
  void updatePlanningBudget(double totalBudgetPhp) {
    final state = _ensurePlanningState();
    state['total_budget'] = totalBudgetPhp.clamp(500, 9999999).toStringAsFixed(2);
    state['budget_scope'] = 'whole_trip';
    _planningRevision++;
    notifyListeners();
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
  bool _placeholderNameMigrated = false;
  bool _legacyFavoritesMigrated = false;
  UserProfile get profile => _profile;

  int _activeNavIndex = 2; // 0: Trips, 1: Discover, 2: Chat (center), 3: Memories, 4: Profile
  int get activeNavIndex => _activeNavIndex;

  /// Takes the traveler to the chat and asks Lakbay AI to plan, instead of
  /// building a ready-made itinerary from a template.
  Future<void> planInChat(String prompt) {
    setActiveNavIndex(2);
    return sendChatMessage(prompt);
  }

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
    final cleanFirst = firstName.trim();
    final cleanLast = lastName.trim();
    final combined = '$cleanFirst $cleanLast'.trim().toLowerCase();
    final rejectPlaceholder = combined == 'lakbay traveler';
    _profile = _profile.copyWith(
      firstName: rejectPlaceholder ? '' : cleanFirst,
      lastName: rejectPlaceholder ? '' : cleanLast,
      headline: headline.trim(),
      location: location.trim(),
      email: email.trim(),
    );
    _scheduleSaveState();
    notifyListeners();
  }

  /// Loads this traveler's username from the server (shown in the profile).
  Future<void> refreshUsername() async {
    if (!isSignedIn || !apiCatalog.isConfigured) return;
    final account = await apiCatalog.fetchMyAccount(_authSession!.accessToken);
    if (account == null) return;
    final username = account.username ?? _profile.username;
    final avatar = account.avatarUrl ?? _profile.avatarUrl;
    // The server is the source of truth: no cover there means the default.
    final cover = account.coverUrl ?? '';
    if (username == _profile.username &&
        avatar == _profile.avatarUrl &&
        cover == _profile.coverUrl) {
      return;
    }
    _profile = _profile.copyWith(
      username: username,
      avatarUrl: avatar,
      coverUrl: cover,
    );
    _scheduleSaveState();
    notifyListeners();
  }

  /// Uploads a new profile photo. Returns null on success, or the reason it
  /// failed, in the server's words, to show to the traveler.
  Future<String?> uploadProfilePhoto({
    Uint8List? bytes,
    String? path,
    String? filename,
  }) async {
    if (!isSignedIn) return 'Sign in to add a profile photo.';
    try {
      final url = await apiCatalog.uploadMyAvatar(
        _authSession!.accessToken,
        fileBytes: bytes,
        filePath: path,
        filename: filename,
      );
      _profile = _profile.copyWith(avatarUrl: url);
      _scheduleSaveState();
      notifyListeners();
      return null;
    } on LakbayApiException catch (e) {
      return e.message;
    } catch (_) {
      return "Couldn't upload the photo. Please try again.";
    }
  }

  /// Uploads a new profile cover photo. Returns null on success, or the reason
  /// it failed, in the server's words.
  Future<String?> uploadCoverPhoto({
    Uint8List? bytes,
    String? path,
    String? filename,
  }) async {
    if (!isSignedIn) return 'Sign in to add a cover photo.';
    try {
      final url = await apiCatalog.uploadMyCover(
        _authSession!.accessToken,
        fileBytes: bytes,
        filePath: path,
        filename: filename,
      );
      _profile = _profile.copyWith(coverUrl: url);
      _scheduleSaveState();
      notifyListeners();
      return null;
    } on LakbayApiException catch (e) {
      return e.message;
    } catch (_) {
      return "Couldn't upload the photo. Please try again.";
    }
  }

  /// Removes the cover photo, back to the default banner. Returns null on
  /// success, or the reason it failed.
  Future<String?> removeCoverPhoto() async {
    if (!isSignedIn) return null;
    try {
      await apiCatalog.removeMyCover(_authSession!.accessToken);
      _profile = _profile.copyWith(coverUrl: '');
      _scheduleSaveState();
      notifyListeners();
      return null;
    } on LakbayApiException catch (e) {
      return e.message;
    } catch (_) {
      return "Couldn't remove the photo. Please try again.";
    }
  }

  /// Saves a new username. Returns null on success, or the reason it was
  /// refused (taken, not allowed, offline) to show to the traveler.
  Future<String?> saveUsername(String input) async {
    final wanted = input.trim().replaceFirst(RegExp(r'^@'), '');
    if (wanted.isEmpty || wanted == _profile.username) return null;
    if (!isSignedIn) return 'Sign in to choose a username.';
    try {
      final saved = await apiCatalog.updateMyUsername(
        _authSession!.accessToken,
        wanted,
      );
      _profile = _profile.copyWith(username: saved);
      _scheduleSaveState();
      notifyListeners();
      return null;
    } on LakbayApiException catch (e) {
      return e.message;
    } catch (_) {
      return "Couldn't save your username. Check your connection and try again.";
    }
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
        'aiLanguage': _aiLanguage,
        'currency': _currency,
        'temperatureUnit': temperatureUnit,
        'priceDropAlertsEnabled': priceDropAlertsEnabled,
        'locationSharingEnabled': locationSharingEnabled,
        'userLat': ?_userLat,
        'userLng': ?_userLng,
        'manualOriginLat': ?_manualOriginLat,
        'manualOriginLng': ?_manualOriginLng,
        if (_manualOriginLabel != null && _manualOriginLabel!.trim().isNotEmpty)
          'manualOriginLabel': _manualOriginLabel,
        'selectedVibes': selectedVibes.toList(),
        'preferenceGroups': _preferenceGroups.map((g) => g.toJson()).toList(),
        'categoryFacets': _categoryFacets.map((c) => c.toJson()).toList(),
        'travelCompanion': travelCompanion,
        'profile': _profile.toJson(),
        'placeholderNameMigrated': _placeholderNameMigrated,
        'legacyFavoritesMigrated': _legacyFavoritesMigrated,
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
      final savedAiLang = map['aiLanguage'] as String?;
      if (savedAiLang != null && supportedAiLanguages.contains(savedAiLang)) {
        _aiLanguage = savedAiLang;
      }
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
      _manualOriginLat = (map['manualOriginLat'] as num?)?.toDouble();
      _manualOriginLng = (map['manualOriginLng'] as num?)?.toDouble();
      final savedManualLabel = (map['manualOriginLabel'] as String?)?.trim();
      _manualOriginLabel =
          (savedManualLabel != null && savedManualLabel.isNotEmpty)
              ? savedManualLabel
              : null;

      final vibes = map['selectedVibes'] as List<dynamic>?;
      if (vibes != null) {
        selectedVibes
          ..clear()
          ..addAll(vibes.map((e) => e.toString()));
      }
      final savedGroups = map['preferenceGroups'] as List<dynamic>?;
      if (savedGroups != null) {
        _preferenceGroups = savedGroups
            .whereType<Map<String, dynamic>>()
            .map(PreferenceGroup.fromJson)
            .toList();
      }
      final savedCategories = map['categoryFacets'] as List<dynamic>?;
      if (savedCategories != null) {
        _categoryFacets = savedCategories
            .whereType<Map<String, dynamic>>()
            .map(CategoryFacet.fromJson)
            .where((c) => c.key.isNotEmpty && c.label.isNotEmpty)
            .toList();
      }
      travelCompanion =
          map['travelCompanion'] as String? ?? travelCompanion;
      _placeholderNameMigrated =
          map['placeholderNameMigrated'] as bool? ?? false;
      _legacyFavoritesMigrated =
          map['legacyFavoritesMigrated'] as bool? ?? false;
      var needsMigrationPersist = false;
      if (map['profile'] is Map<String, dynamic>) {
        var restored = UserProfile.fromJson(
          map['profile'] as Map<String, dynamic>,
        );
        if (!_placeholderNameMigrated) {
          if (restored.fullName.toLowerCase() == 'lakbay traveler') {
            restored = restored.copyWith(firstName: '', lastName: '');
          }
          _placeholderNameMigrated = true;
          needsMigrationPersist = true;
        }
        _profile = restored;
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
      if (needsMigrationPersist) {
        _scheduleSaveState();
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

  /// Removes one chat from this phone. Returns the removed chat and where it
  /// was, so the caller can offer Undo through [restoreChatSession].
  ({ChatSession session, int index})? deleteChatSession(String id) {
    final idx = _chatSessions.indexWhere((s) => s.id == id);
    if (idx < 0) return null;
    final removed = _chatSessions.removeAt(idx);
    if (id == _activeChatId) _openFreshChatAfterDelete();
    notifyListeners();
    return (session: removed, index: idx);
  }

  /// Puts a chat deleted by [deleteChatSession] back where it was.
  void restoreChatSession(ChatSession session, int index) {
    if (_chatSessions.any((s) => s.id == session.id)) return;
    _chatSessions.insert(index.clamp(0, _chatSessions.length), session);
    notifyListeners();
  }

  /// Removes every chat from this phone and starts a blank one.
  void clearChatHistory() {
    _chatSessions.clear();
    _openFreshChatAfterDelete();
    notifyListeners();
  }

  void _openFreshChatAfterDelete() {
    final newId = 'chat_${DateTime.now().millisecondsSinceEpoch}';
    _chatSessions.insert(
      0,
      ChatSession(
        id: newId,
        title: 'New Trip',
        groupLabel: 'Today',
        isTrip: false,
        createdAt: DateTime.now(),
        messages: const [],
      ),
    );
    _activeChatId = newId;
    _chatMessages.clear();
    resetPlanningState();
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
    _migrateLegacyFavoriteComboIds();
    _seedInitialTripsAndChat();
    _isInitialized = true;
    notifyListeners();

    if (apiCatalog.isConfigured) {
      refreshFromApi();
      refreshPreferenceGroups();
      if (isSignedIn) {
        syncTripsFromBackend();
        _syncPushNotifications();
      }
    }
    refreshLiveFxRates();
    if (_hasCompletedOnboarding && locationSharingEnabled) {
      refreshCurrentLocationSilently(requireExistingGrant: true);
    }
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
      } else if (_catalogFingerprint(existing) != _catalogFingerprint(trip)) {
        // Any admin edit (fees, hours, notes, activities, ...) must land.
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

    if (_followMovedCatalogPins()) changed = true;

    _lastCatalogSyncAt = DateTime.now();
    if (changed) {
      notifyListeners();
    }
  }

  /// Every field an admin can edit, so a change to any of them is applied.
  static String _catalogFingerprint(ExploreTrip t) => [
        t.title,
        t.lat,
        t.lng,
        t.thumbnailUrl,
        t.tag,
        t.district,
        t.description,
        t.activities,
        t.estimatedCostPhp,
        t.entranceFee,
        t.overnightFee,
        t.operatingHours,
        t.bestTimeToVisit,
        t.travelNotes,
        t.whatToBring,
        t.islandGroup,
        t.normalizedStayDurationType,
      ].join('\u0001');

  /// Saved trips keep their own copy of each stop's coordinates. When an admin
  /// moves a destination's pin, move matching stops too and drop the cached
  /// road geometry, which ended at the old point. Returns true if any trip
  /// changed.
  bool _followMovedCatalogPins() {
    const movedMeters = 25.0;
    var anyChanged = false;
    for (var i = 0; i < _savedTrips.length; i++) {
      final trip = _savedTrips[i];
      var tripChanged = false;
      ExploreTrip? pinFor(int? destinationId) => destinationId == null
          ? null
          : _tripsById['api_$destinationId'];
      bool moved(ExploreTrip place, double lat, double lng) =>
          MapboxService.calculateRouteDistanceKm([
            GeoPoint(lat: lat, lng: lng),
            GeoPoint(lat: place.lat, lng: place.lng),
          ]) *
              1000 >
          movedMeters;

      final days = [
        for (final day in trip.days)
          () {
            var dayChanged = false;
            final stops = [
              for (final stop in day.stops)
                () {
                  final place = pinFor(stop.destinationId);
                  if (place == null || !moved(place, stop.lat, stop.lng)) {
                    return stop;
                  }
                  dayChanged = true;
                  return stop.copyWith(lat: place.lat, lng: place.lng);
                }(),
            ];
            final dayPlace = pinFor(day.apiDestinationId);
            final dayMoved =
                dayPlace != null && moved(dayPlace, day.lat, day.lng);
            if (!dayChanged && !dayMoved) return day;
            tripChanged = true;
            return day.copyWith(
              stops: stops,
              lat: dayMoved ? dayPlace.lat : null,
              lng: dayMoved ? dayPlace.lng : null,
            );
          }(),
      ];
      if (!tripChanged) continue;
      _savedTrips[i] = trip.copyWith(days: days, routeSegments: const []);
      anyChanged = true;
    }
    if (anyChanged) _scheduleSaveState();
    return anyChanged;
  }

  /// Catalog refresh when the app returns to the foreground, at most every
  /// [maxAge], so admin edits reach a long-open app without a restart.
  Future<void> refreshCatalogIfStale({
    Duration maxAge = const Duration(minutes: 15),
  }) async {
    if (!apiCatalog.isConfigured) return;
    final last = _lastCatalogSyncAt;
    if (last != null && DateTime.now().difference(last) < maxAge) return;
    await refreshFromApi();
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

  /// Signs in with Google. When there is no Lakbay account for that Google
  /// email, this throws [GoogleAccountNotRegistered] (carrying the Google
  /// token) so the screen can ask; call again with `existingIdToken` and
  /// `confirmNewAccount: true` to create it.
  Future<void> signInWithGoogleBackend({
    String? existingIdToken,
    bool confirmNewAccount = false,
  }) async {
    if (!apiCatalog.isConfigured) {
      throw const LakbayApiException(
        'Connect LAKBAY_API_BASE_URL in .env to authenticate with Google against your Lakbay+ account.',
      );
    }
    final idToken =
        existingIdToken ?? await googleAuthService.requestGoogleIdToken();
    if (idToken == null || idToken.isEmpty) {
      throw const LakbayApiException('Google sign-in did not return a token.');
    }
    final LakbayAuthSession session;
    try {
      session = await apiCatalog.googleLogin(
        idToken: idToken,
        confirmNewAccount: confirmNewAccount,
      );
    } on GoogleAccountNotRegistered catch (e) {
      e.idToken = idToken;
      rethrow;
    }
    _applyAuthSession(session);
    await syncTripsFromBackend();
  }

  void _clearUserSessionData() {
    _profile = const UserProfile();
    _manualOriginLat = null;
    _manualOriginLng = null;
    _manualOriginLabel = null;
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
    final cleanFull = session.fullName.trim();
    final isPlaceholder = cleanFull.toLowerCase() == 'lakbay traveler';
    final parts = isPlaceholder
        ? const <String>[]
        : cleanFull
            .split(RegExp(r'\s+'))
            .where((s) => s.isNotEmpty)
            .toList();
    _profile = _profile.copyWith(
      firstName: parts.isNotEmpty ? parts.first : '',
      lastName: parts.length > 1 ? parts.sublist(1).join(' ') : '',
      email: session.email,
    );
    _scheduleSaveState();
    notifyListeners();
    if (apiCatalog.isConfigured && session.accessToken.isNotEmpty) {
      _syncPushNotifications();
    }
  }

  /// True while the traveler scrolls down through a chat: the bottom bar
  /// slides away so the answer has the room. Scrolling up shows it again.
  final ValueNotifier<bool> chatNavHidden = ValueNotifier(false);

  /// Set when the traveler taps a push; cleared once the screen has handled it.
  final ValueNotifier<PushOpenRequest?> pushOpenRequest = ValueNotifier(null);

  Future<void> _syncPushNotifications() async {
    if (!isSignedIn || !apiCatalog.isConfigured) return;
    pushService.listen(
      onToken: (tok) async {
        final session = _authSession;
        if (session == null) return;
        await apiCatalog.registerDevicePushToken(
          session.accessToken,
          deviceToken: tok,
          platform: pushService.resolvePlatform(),
        );
      },
      onForegroundMessage: (_) {
        if (isSignedIn) refreshNotifications();
      },
      // Tapping a push opens what it was about (the trip, its tasks or money
      // sheet, or the invitation). The shell reads this and navigates.
      onOpenedMessage: (data) {
        setActiveNavIndex(0);
        final request = PushOpenRequest.fromPushData(data);
        if (request != null) pushOpenRequest.value = request;
        if (isSignedIn) refreshNotifications();
      },
    );
    final tok = await pushService.fetchToken();
    final session = _authSession;
    if (tok != null && session != null && !_disposed) {
      await apiCatalog.registerDevicePushToken(
        session.accessToken,
        deviceToken: tok,
        platform: pushService.resolvePlatform(),
      );
    }
  }

  Future<String?>? _refreshTokenInFlight;

  Future<String?> _refreshAuthAccessToken() {
    return _refreshTokenInFlight ??= _performAuthTokenRefresh().whenComplete(
      () => _refreshTokenInFlight = null,
    );
  }

  Future<String?> _performAuthTokenRefresh() async {
    final refreshToken = _authSession?.refreshToken.trim() ?? '';
    if (_disposed || refreshToken.isEmpty || !apiCatalog.isConfigured) {
      return null;
    }
    try {
      final refreshed = await apiCatalog.refreshSession(refreshToken);
      if (_disposed || _authSession == null) return null;
      _authSession = refreshed;
      _scheduleSaveState();
      notifyListeners();
      return refreshed.accessToken;
    } catch (_) {
      return null;
    }
  }

  Future<void> signOutBackend() async {
    final accessToken = _authSession?.accessToken ?? '';
    final refreshToken = _authSession?.refreshToken ?? '';
    final lastPushTok = pushService.lastRegisteredToken;
    if (accessToken.isNotEmpty &&
        lastPushTok != null &&
        lastPushTok.isNotEmpty &&
        apiCatalog.isConfigured) {
      await apiCatalog.unregisterDevicePushToken(
        accessToken,
        deviceToken: lastPushTok,
      );
    }
    _invitations.clear();
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
    // Cheap, and keeps the profile's username current after signing in.
    await refreshUsername();
    if (!isSignedIn) return;
    final remoteRows = await apiCatalog.getMyTrips(_authSession!.accessToken);
    if (remoteRows.isEmpty) return;
    var updated = false;
    final phpRate = _currencyRates['PHP'] ?? 57.0;
    for (final row in remoteRows) {
      final tripId = (row['trip_id'] as num?)?.toInt();
      final title = (row['title'] ?? '').toString().trim();
      if (tripId == null || title.isEmpty) continue;
      final existingIdx = _savedTrips.indexWhere(
        (t) => t.backendTripId == tripId || t.id == 'cloud_$tripId',
      );
      final rowStatus = (row['status'] ?? 'planned').toString().trim();
      final rowEndDate = DateTime.tryParse((row['end_date'] ?? '').toString());
      if (existingIdx >= 0) {
        final existingTrip = _savedTrips[existingIdx];
        if (existingTrip.backendStatus != rowStatus ||
            existingTrip.endDate != rowEndDate) {
          _savedTrips[existingIdx] = existingTrip.copyWith(
            backendStatus: rowStatus,
            endDate: rowEndDate,
          );
          updated = true;
        }
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
          adults: (row['traveler_count'] as num?)?.toInt(),
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
          backendStatus: rowStatus,
          endDate: rowEndDate,
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

  /// Sets the day the trip starts (so a forecast can be shown) and reloads the
  /// live details for it.
  Future<ItineraryTrip> setTripStartDate(
    ItineraryTrip trip,
    DateTime date,
  ) async {
    final dated = trip.copyWith(startDate: DateTime(date.year, date.month, date.day));
    final savedIdx = _savedTrips.indexWhere((t) => t.id == trip.id);
    if (savedIdx >= 0) {
      _savedTrips[savedIdx] = dated;
      _scheduleSaveState();
      notifyListeners();
    }
    return loadLiveDetailsForTrip(dated);
  }

  /// Fetches live accommodations, transport rates, and live weather for a trip's
  /// backend destination(s).
  Future<ItineraryTrip> loadLiveDetailsForTrip(ItineraryTrip trip) async {
    final destIds = trip.effectiveBackendDestinationIds;
    if (destIds.isEmpty || !apiCatalog.isConfigured) return trip;
    final destId = destIds.first;
    final phpRate = _currencyRates['PHP'] ?? 57.0;

    final ratesFuture = Future.wait([
      for (final id in destIds.take(5))
        apiCatalog.fetchDestinationMarketRates(
          id,
          city: trip.destination,
          lat: trip.centerLat,
          lng: trip.centerLng,
          phpPerUsd: phpRate,
        ),
    ]);
    final weatherFuture = isSignedIn
        ? apiCatalog.getCurrentWeather(
            _authSession!.accessToken,
            lat: trip.centerLat,
            lng: trip.centerLng,
          )
        : Future.value(null);
    final forecastFuture = isSignedIn
        ? apiCatalog.getWeatherForecast(
            _authSession!.accessToken,
            lat: trip.centerLat,
            lng: trip.centerLng,
          )
        : Future.value(
            const <({DateTime date, int tempC, int wmoCode, String condition})>[],
          );

    final markets = await ratesFuture;
    final weather = await weatherFuture;
    final forecast = await forecastFuture;
    // The stays and transport rates of every place, without repeats.
    final market = (
      hotels: {
        for (final m in markets)
          for (final h in m.hotels) h.id: h,
      }.values.toList(),
      transports: [for (final m in markets) ...m.transports],
    );

    if (market.hotels.isNotEmpty) {
      _hotelRatesByDestId[destId] = market.hotels;
    }
    if (market.transports.isNotEmpty) {
      _transportRatesByDestId[destId] = market.transports;
    }

    final mergedHotels = market.hotels.isNotEmpty ? market.hotels : trip.hotels;

    // A day gets weather only when the trip has a start date and the forecast
    // covers that exact date; otherwise it shows none rather than a guess.
    final updatedDays = trip.days.map((d) {
      final start = trip.startDate;
      if (start == null) return d.copyWith(clearWeather: true);
      final date = DateTime(start.year, start.month, start.day)
          .add(Duration(days: d.dayNumber - 1));
      final match = forecast.where((f) => f.date == date).firstOrNull;
      if (match == null) return d.copyWith(clearWeather: true);
      return d.copyWith(tempCelsius: match.tempC, wmoWeatherCode: match.wmoCode);
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
          'traveler_count': (trip.travelerCount ?? 1).clamp(1, 100),
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
          ? '${weather.tempC}°C${weather.condition.isEmpty ? '' : ' • ${weather.condition}'}'
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
    final first = await _fetchRoadRouteOnce(
      trip,
      optimize: optimize,
      travelMode: travelMode,
      destinationIds: destinationIds,
    );
    if (first != null) return first;
    // One retry: the first request often only wakes a sleeping API server.
    return _fetchRoadRouteOnce(
      trip,
      optimize: optimize,
      travelMode: travelMode,
      destinationIds: destinationIds,
    );
  }

  Future<BackendRouteResult?> _fetchRoadRouteOnce(
    ItineraryTrip trip, {
    required bool optimize,
    String? travelMode,
    List<int>? destinationIds,
  }) async {
    final destIds = destinationIds ?? trip.effectiveBackendDestinationIds;
    if (destIds.isEmpty || !apiCatalog.isConfigured) {
      return null;
    }
    final mode = travelMode ?? preferredTravelMode;
    final origin = _routeOriginFromUserLocation();
    if (isSignedIn) {
      final authed = optimize && destIds.length >= 2
          ? await apiCatalog.optimizeRoute(
              _authSession!.accessToken,
              destinationIds: destIds,
              travelMode: mode,
              origin: origin,
            )
          : await apiCatalog.previewRoute(
              _authSession!.accessToken,
              destinationIds: destIds,
              travelMode: mode,
              origin: origin,
            );
      if (authed != null) return authed;
    }
    final guestPlan = await apiCatalog.planRoute(
      null,
      destinationIds: destIds,
      days: trip.daysCount.clamp(1, 14),
      pace: trip.pace,
      travelMode: mode,
      origin: origin,
      returnToOrigin: trip.roundtrip && origin != null,
      preserveFirstDestination: !optimize,
    );
    return guestPlan?.route;
  }

  /// Where the traveler is starting from (GPS or the place they chose), or null.
  GeoPoint? get routeOrigin => _routeOriginFromUserLocation();

  /// The traveler's GPS or manually chosen starting location. Coordinates
  /// outside Region XI are allowed; route UI notes that road routes are
  /// planned inside Region XI.
  GeoPoint? _routeOriginFromUserLocation() {
    final lat = originLat;
    final lng = originLng;
    if (lat == null || lng == null) return null;
    return GeoPoint(
      lat: lat,
      lng: lng,
      label: resolvedOriginLabel ?? 'Starting Point',
    );
  }

  // ── Notifications ──────────────────────────────────────────────────────────

  Future<void> refreshNotifications() async {
    if (!isSignedIn || !apiCatalog.isConfigured) return;
    final token = _authSession!.accessToken;
    final items = await apiCatalog.fetchNotifications(token);
    final unread = await apiCatalog.getUnreadNotificationCount(token);
    final invitations = await apiCatalog.listTripInvitations(token);
    _notifications
      ..clear()
      ..addAll(items);
    _unreadNotificationCount = unread;
    _invitations
      ..clear()
      ..addAll(invitations);
    notifyListeners();
  }

  /// Trips the traveler was invited to and has not answered yet.
  final List<TripInvitationItem> _invitations = [];
  List<TripInvitationItem> get invitations => List.unmodifiable(_invitations);

  bool hasPendingInvitation(int? tripId) =>
      tripId != null && _invitations.any((i) => i.tripId == tripId);

  /// Accepts or declines an invitation. Accepting brings the trip into the
  /// traveler's trips. Returns true when the server confirmed the answer.
  Future<bool> answerInvitation(int tripId, {required bool accept}) async {
    if (!isSignedIn || !apiCatalog.isConfigured) return false;
    final ok = await apiCatalog.answerTripInvitation(
      _authSession!.accessToken,
      tripId,
      accept: accept,
    );
    if (!ok) return false;
    _invitations.removeWhere((i) => i.tripId == tripId);
    notifyListeners();
    if (accept) await syncTripsFromBackend();
    await refreshNotifications();
    return true;
  }

  Timer? _notificationTimer;

  /// Checks for new notifications and invitations every minute while the app
  /// is open, so an invitation shows up without restarting the app.
  void startNotificationPolling({
    Duration interval = const Duration(seconds: 60),
  }) {
    _notificationTimer?.cancel();
    _notificationTimer = Timer.periodic(interval, (_) {
      if (isSignedIn) refreshNotifications();
    });
  }

  void stopNotificationPolling() {
    _notificationTimer?.cancel();
    _notificationTimer = null;
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

  // ── Memories Album ─────────────────────────────────────────────────────────

  List<TripMemoryItem> memoriesForTrip(ItineraryTrip trip) {
    final bid = trip.backendTripId;
    return _memories.where((m) {
      if (bid != null && m.tripId == bid) return true;
      if (m.destinationName != null &&
          m.destinationName!.trim().toLowerCase() ==
              trip.title.trim().toLowerCase()) {
        return true;
      }
      return false;
    }).toList();
  }

  List<ItineraryTrip> get postTripMemoryPrompts => _savedTrips
      .where(
        (t) =>
            !t.isArchived &&
            t.hasEnded &&
            t.backendTripId != null &&
            memoriesForTrip(t).isEmpty,
      )
      .toList();

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
    final outboxItems = _memories.where((m) => m.isOutbox).toList();
    merged.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    _memories
      ..clear()
      ..addAll(outboxItems)
      ..addAll(merged);
    _scheduleSaveState();
    notifyListeners();
  }

  Future<List<TripMemoryItem>> loadMemoriesForTrip(int backendTripId) async {
    if (!isSignedIn || !apiCatalog.isConfigured) {
      return _memories.where((m) => m.tripId == backendTripId).toList();
    }
    final items = await apiCatalog.listTripMemories(
      _authSession!.accessToken,
      backendTripId,
    );
    _memories.removeWhere((m) => !m.isOutbox && m.tripId == backendTripId);
    _memories.addAll(items);
    _memories.sort((a, b) {
      if (a.isOutbox != b.isOutbox) return a.isOutbox ? -1 : 1;
      return b.createdAt.compareTo(a.createdAt);
    });
    _scheduleSaveState();
    notifyListeners();
    return _memories.where((m) => m.tripId == backendTripId).toList();
  }

  Future<TripMemoryItem?> uploadAndAddMemory({
    required ItineraryTrip trip,
    String? localFilePath,
    Uint8List? imageBytes,
    String? fileName,
    String? caption,
    String? locationTag,
    void Function(String status)? onProgress,
    Duration? uploadTimeoutOverride,
  }) async {
    if (!isSignedIn || !apiCatalog.isConfigured) {
      throw const LakbayApiException(
        'Sign in to upload and share trip memories.',
        code: 'auth_required',
      );
    }
    if (trip.isArchived) {
      throw const LakbayApiException(
        'Archived trips are read-only for new memories.',
        statusCode: 400,
        code: 'trip_archived_read_only',
      );
    }

    var tripId = trip.backendTripId;
    if (tripId == null) {
      final destIds = trip.effectiveBackendDestinationIds;
      if (destIds.isNotEmpty) {
        onProgress?.call('Syncing trip…');
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
    if (tripId == null) {
      throw const LakbayApiException(
        'Save this trip with catalog destinations first before adding memories.',
        code: 'trip_not_synced',
      );
    }

    final safeDestId =
        trip.backendDestinationId != null &&
                trip.effectiveBackendDestinationIds.contains(
                  trip.backendDestinationId,
                )
            ? trip.backendDestinationId
            : null;
    final cleanCaption =
        (caption != null && caption.trim().isNotEmpty) ? caption.trim() : null;
    final cleanTag = (locationTag != null && locationTag.trim().isNotEmpty)
        ? locationTag.trim()
        : trip.destination;

    try {
      final uploaded = await apiCatalog.uploadTripMemoryPhoto(
        _authSession!.accessToken,
        tripId,
        fileBytes: imageBytes,
        filename: fileName,
        filePath: localFilePath,
        onProgress: onProgress,
        timeoutOverride: uploadTimeoutOverride,
      );
      if (uploaded == null || uploaded.imageUrl.isEmpty) {
        throw const LakbayApiException(
          'Photo upload did not return an image URL.',
          code: 'network_error',
        );
      }
      onProgress?.call('Saving memory…');
      final created = await apiCatalog.createTripMemory(
        _authSession!.accessToken,
        tripId,
        imageUrl: uploaded.imageUrl,
        cloudinaryPublicId: uploaded.publicId,
        destinationId: safeDestId,
        caption: cleanCaption,
        locationTag: cleanTag,
      );
      if (created == null) {
        throw const LakbayApiException(
          'Could not save memory on the server.',
          code: 'network_error',
        );
      }
      _memories.insert(0, created);
      _scheduleSaveState();
      notifyListeners();
      return created;
    } on LakbayApiException catch (e) {
      if (e.statusCode == 403 || e.statusCode == 404) {
        throw const LakbayApiException(
          'Only accepted trip members can add memories here. Accept your trip invitation first.',
          statusCode: 403,
          code: 'membership_required',
        );
      }
      if (e.statusCode != null && e.statusCode! >= 400 && e.statusCode! < 500) {
        rethrow;
      }
      return _queueMemoryOutbox(
        tripId: tripId,
        tripTitle: trip.title,
        destinationId: safeDestId,
        localFilePath: localFilePath,
        imageBytes: imageBytes,
        caption: cleanCaption,
        locationTag: cleanTag,
        errorMessage: e.message,
      );
    } catch (e) {
      return _queueMemoryOutbox(
        tripId: tripId,
        tripTitle: trip.title,
        destinationId: safeDestId,
        localFilePath: localFilePath,
        imageBytes: imageBytes,
        caption: cleanCaption,
        locationTag: cleanTag,
        errorMessage: 'Network error while uploading: $e',
      );
    }
  }

  TripMemoryItem _queueMemoryOutbox({
    required int tripId,
    required String tripTitle,
    int? destinationId,
    String? localFilePath,
    Uint8List? imageBytes,
    String? caption,
    String? locationTag,
    required String errorMessage,
  }) {
    final encodedBytes =
        (imageBytes != null && imageBytes.length <= 2 * 1024 * 1024)
            ? base64Encode(imageBytes)
            : null;
    final outboxItem = TripMemoryItem(
      tripMemoryId: -DateTime.now().millisecondsSinceEpoch,
      tripId: tripId,
      uploadedByFullName: _profile.fullName,
      destinationId: destinationId,
      destinationName: tripTitle,
      imageUrl: '',
      localFilePath: localFilePath,
      caption: caption,
      locationTag: locationTag,
      createdAt: DateTime.now(),
      uploadStatus: 'failed',
      uploadError: errorMessage,
      localBytesBase64: encodedBytes,
    );
    _memories.insert(0, outboxItem);
    _scheduleSaveState();
    notifyListeners();
    return outboxItem;
  }

  Future<TripMemoryItem?> retryOutboxMemory(
    TripMemoryItem item, {
    void Function(String status)? onProgress,
    Duration? uploadTimeoutOverride,
  }) async {
    if (!item.isOutbox) return item;
    if (!isSignedIn || !apiCatalog.isConfigured || item.tripId <= 0) {
      throw const LakbayApiException('Sign in to retry this upload.');
    }

    final idx = _memories.indexWhere((m) => m.tripMemoryId == item.tripMemoryId);
    if (idx < 0) return null;

    _memories[idx] = item.copyWith(uploadStatus: 'pending');
    notifyListeners();

    final Uint8List? bytes = item.localBytesBase64 != null
        ? base64Decode(item.localBytesBase64!)
        : null;

    try {
      final uploaded = await apiCatalog.uploadTripMemoryPhoto(
        _authSession!.accessToken,
        item.tripId,
        fileBytes: bytes,
        filePath: item.localFilePath,
        onProgress: onProgress,
        timeoutOverride: uploadTimeoutOverride,
      );
      if (uploaded == null || uploaded.imageUrl.isEmpty) {
        throw const LakbayApiException(
          'Photo upload did not return an image URL.',
          code: 'network_error',
        );
      }
      onProgress?.call('Saving memory…');
      final created = await apiCatalog.createTripMemory(
        _authSession!.accessToken,
        item.tripId,
        imageUrl: uploaded.imageUrl,
        cloudinaryPublicId: uploaded.publicId,
        destinationId: item.destinationId,
        caption: item.caption,
        locationTag: item.locationTag,
      );
      if (created == null) {
        throw const LakbayApiException(
          'Could not save memory on the server.',
          code: 'network_error',
        );
      }
      // Remove outbox item ONLY once the server confirms creation.
      final curIdx =
          _memories.indexWhere((m) => m.tripMemoryId == item.tripMemoryId);
      if (curIdx >= 0) {
        _memories[curIdx] = created;
      } else {
        _memories.insert(0, created);
      }
      _scheduleSaveState();
      notifyListeners();
      return created;
    } on LakbayApiException catch (e) {
      final curIdx =
          _memories.indexWhere((m) => m.tripMemoryId == item.tripMemoryId);
      if (curIdx >= 0) {
        _memories[curIdx] = item.copyWith(
          uploadStatus: 'failed',
          uploadError: e.message,
        );
        _scheduleSaveState();
        notifyListeners();
      }
      rethrow;
    } catch (e) {
      final curIdx =
          _memories.indexWhere((m) => m.tripMemoryId == item.tripMemoryId);
      if (curIdx >= 0) {
        _memories[curIdx] = item.copyWith(
          uploadStatus: 'failed',
          uploadError: 'Retry failed: $e',
        );
        _scheduleSaveState();
        notifyListeners();
      }
      return null;
    }
  }

  Future<bool> likeMemory(TripMemoryItem memory) async {
    if (memory.isOutbox ||
        !isSignedIn ||
        !apiCatalog.isConfigured ||
        memory.tripMemoryId <= 0 ||
        memory.tripId <= 0) {
      return false;
    }
    final idx = _memories.indexWhere(
      (m) => m.tripMemoryId == memory.tripMemoryId,
    );
    if (idx < 0) return false;
    final original = _memories[idx];
    _memories[idx] = original.copyWith(likeCount: original.likeCount + 1);
    notifyListeners();

    final res = await apiCatalog.likeTripMemory(
      _authSession!.accessToken,
      memory.tripId,
      memory.tripMemoryId,
    );
    final curIdx = _memories.indexWhere(
      (m) => m.tripMemoryId == memory.tripMemoryId,
    );
    if (res.confirmed) {
      if (curIdx >= 0 && res.likeCount != null) {
        _memories[curIdx] = _memories[curIdx].copyWith(
          likeCount: res.likeCount!,
        );
      }
      _scheduleSaveState();
      notifyListeners();
      return true;
    }
    // Roll back optimistic increment when server does not confirm.
    if (curIdx >= 0) {
      _memories[curIdx] = original;
    }
    notifyListeners();
    return false;
  }

  Future<void> deleteMemory(TripMemoryItem memory) async {
    _memories.removeWhere((m) => m.tripMemoryId == memory.tripMemoryId);
    _scheduleSaveState();
    notifyListeners();
    if (!memory.isOutbox &&
        isSignedIn &&
        memory.tripMemoryId > 0 &&
        memory.tripId > 0) {
      await apiCatalog.deleteTripMemory(
        _authSession!.accessToken,
        memory.tripId,
        memory.tripMemoryId,
      );
    }
  }

  /// How many pesos one US dollar buys, for converting catalog prices.
  double get phpPerUsd => _currencyRates['PHP'] ?? 57.0;

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

  void setAiLanguage(String language) {
    if (!supportedAiLanguages.contains(language) || _aiLanguage == language) {
      return;
    }
    _aiLanguage = language;
    _scheduleSaveState();
    notifyListeners();
  }

  String get aiLanguageDisplayName => switch (_aiLanguage) {
        'auto' => 'Auto',
        'english' => 'English',
        'filipino' => 'Filipino',
        'bisaya' => 'Bisaya / Cebuano',
        _ => 'Auto',
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
    _lastLocationOutcome = result.effectiveOutcome;
    if (result.granted && result.lat != null && result.lng != null) {
      _userLat = result.lat;
      _userLng = result.lng;
      _manualOriginLat = null;
      _manualOriginLng = null;
      _manualOriginLabel = null;
      locationSharingEnabled = true;
      final label = result.resolvedLabel?.trim() ?? '';
      if (label.isNotEmpty) {
        _profile = _profile.copyWith(location: label);
      }
      if (_planningState != null) {
        _planningState!['origin'] = {
          if (label.isNotEmpty) 'label': label,
          'lat': _userLat,
          'lng': _userLng,
        };
      }
    } else {
      locationSharingEnabled = false;
    }
    _scheduleSaveState();
    notifyListeners();
    return result;
  }

  Future<LocationPermissionOutcome> refreshLocationPermissionOutcome() async {
    final outcome = await locationService.checkPermissionOutcome();
    _lastLocationOutcome = outcome;
    notifyListeners();
    return outcome;
  }

  Future<bool> openLocationAppSettings({bool openLocationMenu = false}) {
    if (openLocationMenu) {
      return locationService.openLocationSettings();
    }
    return locationService.openAppSettings();
  }

  /// Stores a manually searched or map-pinned starting place without assuming Davao.
  void setManualOrigin({
    required String label,
    required double lat,
    required double lng,
  }) {
    final cleanLabel = label.trim().isNotEmpty
        ? label.trim()
        : '${lat.toStringAsFixed(3)}°, ${lng.toStringAsFixed(3)}°';
    _manualOriginLat = lat;
    _manualOriginLng = lng;
    _manualOriginLabel = cleanLabel;
    _profile = _profile.copyWith(location: cleanLabel);
    if (_planningState != null) {
      _planningState!['origin'] = {
        'label': cleanLabel,
        'lat': lat,
        'lng': lng,
      };
    }
    _scheduleSaveState();
    notifyListeners();
  }

  void clearManualOrigin() {
    _manualOriginLat = null;
    _manualOriginLng = null;
    _manualOriginLabel = null;
    _scheduleSaveState();
    notifyListeners();
  }

  Future<List<PlaceSuggestion>> searchStartingPlaces(String query) =>
      locationService.searchPlaces(query);

  Future<String> reverseGeocodePoint(double lat, double lng) =>
      locationService.reverseGeocode(lat, lng);

  /// Preference groups from the server (cached for offline use). Empty until
  /// they have loaded once.
  List<PreferenceGroup> _preferenceGroups = const [];
  List<PreferenceGroup> get preferenceGroups => _preferenceGroups;

  List<CategoryFacet> _categoryFacets = const [];
  List<CategoryFacet> get categoryFacets => List.unmodifiable(_categoryFacets);

  Future<void> refreshPreferenceGroups() async {
    final facets = await apiCatalog.fetchDestinationFacets();
    if (facets.groups.isEmpty && facets.categories.isEmpty) return;
    if (facets.groups.isNotEmpty) {
      _preferenceGroups = facets.groups;
      // Forget preferences the catalog no longer offers.
      final known = {
        for (final g in facets.groups)
          ...[g.key, for (final s in g.subtypes) s.key],
      };
      selectedVibes.removeWhere((key) => !known.contains(key));
    }
    if (facets.categories.isNotEmpty) {
      _categoryFacets = facets.categories;
    }
    _scheduleSaveState();
    notifyListeners();
  }

  /// Browses up to 5 ranked catalog places in [category] without calling AI.
  Future<void> browseCategoryInChat(CategoryFacet category) async {
    _chatMessages.add(
      ChatMessage(
        id: 'user_${DateTime.now().millisecondsSinceEpoch}',
        isUser: true,
        text: 'Browse ${category.label}',
        timestamp: DateTime.now(),
      ),
    );
    _isAiTyping = true;
    _aiTypingStatus = 'Loading ${category.label} spots...';
    notifyListeners();

    var results = await apiCatalog.browsePlacesByCategory(
      category: category.key,
      userLat: originLat,
      userLng: originLng,
      limit: 5,
    );

    // Offline fallback from cached/bundled catalog without inventing places.
    if (results.isEmpty && !apiCatalog.isConfigured) {
      final needle = category.key.toLowerCase();
      var rank = 1;
      results = [
        for (final p in _allTrips)
          if (p.apiDestinationId != null &&
              (p.tag ?? '').toLowerCase().contains(needle))
            TopPlaceRecommendation(
              rank: rank++,
              destinationId: p.apiDestinationId!,
              name: p.title,
              district: p.district ?? p.regionName,
              category: p.tag,
              imageUrl: p.hasRemoteThumbnail ? p.thumbnailUrl : null,
              score: 50.0,
              reasons: ['Matches ${category.label}'],
              routeVerified: false,
              travelMode: 'driving',
              lat: p.lat,
              lng: p.lng,
            ),
      ].take(5).toList();
    }

    _chatMessages.add(
      ChatMessage(
        id: 'cat_${DateTime.now().millisecondsSinceEpoch}',
        isUser: false,
        text: results.isEmpty
            ? 'Lakbay has no active ${category.label} places listed yet.'
            : 'Here are top ${category.label} spots from the catalog (tap + Add to plan from them):',
        timestamp: DateTime.now(),
        recommendedPlaces: results,
      ),
    );
    _aiTypingStatus = null;
    _isAiTyping = false;
    _syncActiveSession(titleHint: category.label);
    _scheduleSaveState();
    notifyListeners();
  }

  /// Chooses or clears a preference group or sub-type. The AI planner is told
  /// right away, so recommendations follow what the traveler picked.
  void toggleVibe(String vibe) {
    if (selectedVibes.contains(vibe)) {
      selectedVibes.remove(vibe);
      // Clearing a group also clears its sub-types.
      for (final group in _preferenceGroups) {
        if (group.key == vibe) {
          selectedVibes.removeAll(group.subtypes.map((s) => s.key));
        }
      }
    } else {
      selectedVibes.add(vibe);
    }
    _planningState?['interests'] = selectedVibes.toList();
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
              travelerCount: trip.travelerCount ?? 1,
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
        travelerCount: updated.travelerCount ?? 1,
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
    return replanTripWithSettings(
      trip,
      daysCount: trip.daysCount,
      pace: trip.pace,
      travelMode: travelMode,
    );
  }

  /// Re-plans an existing multi-day trip (used when adding a day after an
  /// overload warning or tapping "Optimize Order" in TripDetailScreen).
  Future<ItineraryTrip> replanTripWithSettings(
    ItineraryTrip trip, {
    int? daysCount,
    String? pace,
    String? travelMode,
  }) async {
    final extracted = _extractRouteStopsFromTrip(trip);
    final effectivePace = TripPace.fromKey(pace ?? trip.pace);
    final targetDays = (daysCount ?? trip.daysCount).clamp(1, 14);
    if (extracted.stops.isEmpty) {
      return trip;
    }

    final originPt = _routeOriginFromUserLocation();
    final originCoord = originPt == null
        ? null
        : GeoCoord(
            lat: originPt.lat,
            lng: originPt.lng,
            islandGroup:
                _inferIslandGroupFromCoords(originPt.lat, originPt.lng),
            label: originPt.label ?? 'Starting Point',
          );
    final effectiveMode = travelMode ?? preferredTravelMode;
    final localPlan = _routeOptimizer.planRoute(
      stops: extracted.inputs,
      days: targetDays,
      pace: effectivePace,
      origin: originCoord,
      roundtrip: trip.roundtrip && originCoord != null,
      lockedFirstId: trip.lockedFirstDestinationId,
      driving: effectiveMode == 'driving',
    );

    var rebuilt = _tripFromRoutePlan(
      plan: localPlan,
      placeById: extracted.byInputId,
      daysCount: targetDays,
      travelers: trip.travelerCount?.clamp(1, 30),
      existingTrip: trip,
    );

    final backendIds = <int>[
      for (final s in extracted.inputs)
        if (extracted.byInputId[s.id]?.apiDestinationId != null)
          extracted.byInputId[s.id]!.apiDestinationId!,
    ];
    if (backendIds.length == extracted.inputs.length &&
        backendIds.isNotEmpty &&
        apiCatalog.isConfigured) {
      final lockedApiId = trip.lockedFirstDestinationId != null
          ? extracted.byInputId[trip.lockedFirstDestinationId!]?.apiDestinationId
          : null;
      final backendPlan = await apiCatalog.planRoute(
        isSignedIn ? _authSession!.accessToken : null,
        destinationIds: backendIds,
        days: targetDays,
        pace: effectivePace.key,
        travelMode: effectiveMode,
        origin: originPt,
        returnToOrigin: trip.roundtrip && originPt != null,
        preserveFirstDestination: lockedApiId != null && originPt == null,
        lockedFirstDestinationId: lockedApiId,
      );
      if (backendPlan != null) {
        rebuilt = _applyBackendRoutePlanToTrip(
          rebuilt,
          backendPlan,
          placeByApiId: {
            for (final e in extracted.byInputId.values)
              if (e.apiDestinationId != null) e.apiDestinationId!: e,
          },
          roundtrip: trip.roundtrip && originPt != null,
          lockedFirstDestinationId: trip.lockedFirstDestinationId,
        );
      }
    }

    updateTripDetails(rebuilt);
    return rebuilt;
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
        travelerCount: (trip.travelerCount ?? 1).clamp(1, 100),
        dayCount: trip.daysCount.clamp(1, 30),
        destinationIds: destIds,
        specialRequirements: instruction,
        travelStyle: instruction,
        language: _aiLanguage,
      );
      if (generated is AiItinerarySuccess && generated.options.isNotEmpty) {
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
          currentLocation: resolvedOriginLabel,
          userLat: originLat,
          userLng: originLng,
          preferredVibes: selectedVibes,
          strictBudget: strictBudgetFilter,
          language: _aiLanguage,
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
    int? travelers,
    TripPace? pace,
    String? startMode,
    GeoPoint? hotelOrigin,
    bool? roundtrip,
    bool pruneOptionalToFit = false,
    bool refineWithBackend = true,
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

    final effectivePace = pace ?? _builderPace;
    final effectiveMode = startMode ?? _builderStartMode;
    final effectiveOriginPt = resolveBuilderOriginPoint(
      startMode: effectiveMode,
      hotelOrigin: hotelOrigin,
    );
    final effectiveRoundtrip =
        (roundtrip ?? _builderRoundtrip) && effectiveOriginPt != null;

    final suggested = suggestedTripBuilderDays(pace: effectivePace);
    final count = (daysCount ?? suggested).clamp(1, 14);
    final placeById = <String, ExploreTrip>{
      for (final s in stops) s.id: s,
    };

    // Instant on-device plan (Haversine + Region XI sea network + Linear-Partition DP).
    final localPlan = previewTripBuilderPlan(
      days: count,
      pace: effectivePace,
      startMode: effectiveMode,
      hotelOrigin: hotelOrigin,
      roundtrip: effectiveRoundtrip,
      pruneOptionalToFit: pruneOptionalToFit,
    );

    var builtTrip = _tripFromRoutePlan(
      plan: localPlan,
      placeById: placeById,
      daysCount: count,
      travelers: travelers,
      budgetPhp: budgetPhp,
      lockedFirstDestinationId: _builderLockedFirstStopId,
    );

    // Online refinement with real OSRM / Mapbox road matrix & geometries.
    final activeInputs = localPlan.orderedStops;
    final destIds = <int>[
      for (final s in stops)
        if (s.apiDestinationId != null) s.apiDestinationId!,
    ];
    if (refineWithBackend &&
        destIds.length == stops.length &&
        destIds.isNotEmpty &&
        apiCatalog.isConfigured &&
        activeInputs.isNotEmpty) {
      final lockedApiId = _builderLockedFirstStopId != null
          ? placeById[_builderLockedFirstStopId!]?.apiDestinationId
          : null;
      final mustVisitIds = <int>[
        for (final s in stops)
          if (s.apiDestinationId != null && isStopMustVisit(s.id))
            s.apiDestinationId!,
      ];
      final backendPlan = await apiCatalog.planRoute(
        isSignedIn ? _authSession!.accessToken : null,
        destinationIds: destIds,
        days: count,
        pace: effectivePace.key,
        travelMode: preferredTravelMode,
        origin: effectiveOriginPt,
        returnToOrigin: effectiveRoundtrip,
        preserveFirstDestination:
            lockedApiId != null && effectiveOriginPt == null,
        lockedFirstDestinationId: lockedApiId,
        mustVisitDestinationIds:
            mustVisitIds.length == destIds.length ? null : mustVisitIds,
        pruneOptionalToFit: pruneOptionalToFit,
      );
      if (backendPlan != null) {
        builtTrip = _applyBackendRoutePlanToTrip(
          builtTrip,
          backendPlan,
          placeByApiId: {
            for (final s in stops)
              if (s.apiDestinationId != null) s.apiDestinationId!: s,
          },
          roundtrip: effectiveRoundtrip,
          lockedFirstDestinationId: _builderLockedFirstStopId,
        );
      }
    }

    clearTripBuilder();
    return builtTrip;
  }

  String? _inferIslandGroupFromCoords(double lat, double lng) {
    // Samal / Talikud polygon bounds in Davao Gulf.
    if (lat >= 6.87 && lat <= 7.22 && lng >= 125.63 && lng <= 125.81) {
      return lat < 6.96 ? 'talikud' : 'samal';
    }
    if (lat <= 5.65 && lng >= 125.30 && lng <= 125.60) {
      return 'sarangani_islands';
    }
    return 'mainland';
  }

  static String _formatClockMinutes(int totalMinutes) {
    final clamped = totalMinutes.clamp(360, 1320);
    final h24 = clamped ~/ 60;
    final m = clamped % 60;
    final period = h24 >= 12 ? 'PM' : 'AM';
    final h12 = h24 % 12 == 0 ? 12 : h24 % 12;
    return '${h12.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')} $period';
  }

  static String _formatDurationMinutes(int minutes) {
    if (minutes <= 0) return '0 min';
    if (minutes < 60) return '$minutes min';
    final h = minutes ~/ 60;
    final rem = minutes % 60;
    if (rem == 0) return '${h}h';
    return '${h}h ${rem}m';
  }

  ItineraryTrip _tripFromRoutePlan({
    required RoutePlanResult plan,
    required Map<String, ExploreTrip> placeById,
    required int daysCount,
    required int? travelers,
    double? budgetPhp,
    String? lockedFirstDestinationId,
    ItineraryTrip? existingTrip,
  }) {
    final phpRate = _currencyRates['PHP'] ?? 57.0;
    final orderedPlaces = <ExploreTrip>[
      for (final stop in plan.orderedStops) ?placeById[stop.id],
    ];
    final primary = orderedPlaces.isNotEmpty
        ? orderedPlaces.first
        : ExploreTrip(
            locale: _locale,
            id: 'fallback',
            title: existingTrip?.title ?? 'Davao Region',
            days: 1,
            lat: existingTrip?.centerLat ?? 7.0731,
            lng: existingTrip?.centerLng ?? 125.6128,
            thumbnailUrl: existingTrip?.heroAsset ??
                'assets/home_backdrops/01-samal-island.jpg',
          );

    final builtDays = <ItineraryDay>[];
    for (final pDay in plan.days) {
      if (pDay.isContinuationDay) {
        final cont = pDay.continuationOfStop;
        final contPlace = cont != null ? placeById[cont.id] : null;
        final contTitle = cont?.name ??
            contPlace?.title.split('—').first.trim() ??
            'Destination';
        builtDays.add(
          ItineraryDay(
            dayNumber: pDay.dayNumber,
            cityTitle: 'Stay & Explore — $contTitle',
            summary:
                'Continuation / relaxed day at $contTitle (no inter-stop road travel scheduled).',
            lat: cont?.lat ?? primary.lat,
            lng: cont?.lng ?? primary.lng,
            visitHours: pDay.visitHours,
            transitHours: 0,
            totalHours: pDay.totalHours,
            isContinuationDay: true,
            continuationOfTitle: contTitle,
            apiDestinationId: contPlace?.apiDestinationId,
            stops: [
              ItineraryStop(
                time: '09:00 AM',
                title: 'Free / Leisure Time — $contTitle',
                description:
                    'Unscheduled continuation day to enjoy resort, trails, or local food nearby.',
                category: 'stay',
                costEstimateUsd: 0,
                lat: cont?.lat ?? primary.lat,
                lng: cont?.lng ?? primary.lng,
                destinationId: contPlace?.apiDestinationId,
                stayDurationType: cont?.stayDurationType ?? 'half_day',
                islandGroup: cont?.islandGroup,
              ),
            ],
          ),
        );
        continue;
      }

      final dayStops = <ItineraryStop>[];
      var cursorMinutes = 8 * 60; // 08:00 AM start
      for (var idx = 0; idx < pDay.stops.length; idx++) {
        final stop = pDay.stops[idx];
        final place = placeById[stop.id];
        final matchingLeg = idx == 0
            ? (pDay.dayNumber == 1
                ? (pDay.legs.isNotEmpty && pDay.legs.first.toLabel == stop.name
                    ? pDay.legs.first
                    : null)
                : (pDay.legs.isNotEmpty ? pDay.legs.first : null))
            : (pDay.legs.length > idx
                ? pDay.legs[idx]
                : (pDay.legs.length == pDay.stops.length - 1
                    ? pDay.legs[idx - 1]
                    : null));

        final legMinutes = matchingLeg?.transitMinutes.round();
        final legKm = matchingLeg?.distanceKm;
        final isSea = matchingLeg != null && matchingLeg.seaHops.isNotEmpty;
        final legMode = isSea ? TransportMode.ferry : TransportMode.car;

        if (idx > 0 && legMinutes != null && legMinutes > 0) {
          cursorMinutes += legMinutes;
        } else if (idx == 0 && legMinutes != null && legMinutes > 0) {
          cursorMinutes += legMinutes.clamp(15, 90);
        }

        final cleanTitle = stop.name;
        dayStops.add(
          ItineraryStop(
            time: _formatClockMinutes(cursorMinutes),
            title: cleanTitle,
            description: place?.description ??
                place?.activities ??
                'Explore $cleanTitle in ${place?.regionName ?? 'Davao Region'}.',
            category: place?.tag ?? 'Scenic',
            costEstimateUsd: (place?.estimatedCostPhp ?? 600) / phpRate,
            lat: stop.lat,
            lng: stop.lng,
            destinationId: place?.apiDestinationId,
            stayDurationType: stop.stayDurationType,
            islandGroup: stop.islandGroup ?? place?.islandGroup,
            travelFromPrevMinutes: legMinutes,
            travelFromPrevKm: legKm,
            travelFromPrevMode: matchingLeg != null ? legMode : null,
            isSeaCrossingFromPrev: isSea,
          ),
        );
        cursorMinutes += (stop.visitHours * 60).round();
      }

      final firstStop = pDay.stops.isNotEmpty ? pDay.stops.first : null;
      final firstPlace = firstStop != null ? placeById[firstStop.id] : null;
      final incomingLeg = pDay.dayNumber > 1 && pDay.legs.isNotEmpty
          ? pDay.legs.first
          : (pDay.dayNumber == 1 &&
                  pDay.legs.isNotEmpty &&
                  pDay.legs.first.toLabel == firstStop?.name
              ? pDay.legs.first
              : null);
      final dayTransitMins = (pDay.transitHours * 60).round();
      final dayTitle = pDay.stops.map((s) => s.name).join(' • ');
      final hasSeaOnDay = pDay.legs.any((l) => l.seaHops.isNotEmpty);

      builtDays.add(
        ItineraryDay(
          dayNumber: pDay.dayNumber,
          cityTitle: dayTitle.isEmpty ? 'Day ${pDay.dayNumber}' : dayTitle,
          summary:
              '${pDay.stops.length} ${pDay.stops.length == 1 ? 'place' : 'places'} · ~${pDay.visitHours.toStringAsFixed(1)} h exploring${dayTransitMins > 0 ? ' · ${_formatDurationMinutes(dayTransitMins)} transit' : ''}',
          lat: firstStop?.lat ?? primary.lat,
          lng: firstStop?.lng ?? primary.lng,
          transportFromPrevious: incomingLeg != null
              ? (hasSeaOnDay || incomingLeg.seaHops.isNotEmpty
                  ? TransportMode.ferry
                  : TransportMode.car)
              : null,
          transportDuration: incomingLeg != null
              ? '${_formatDurationMinutes(incomingLeg.transitMinutes.round())} · ${incomingLeg.distanceKm.toStringAsFixed(1)} km'
              : null,
          stops: dayStops,
          apiDestinationId: firstPlace?.apiDestinationId,
          visitHours: pDay.visitHours,
          transitHours: pDay.transitHours,
          totalHours: pDay.totalHours,
          overloadWarning: pDay.overloadWarning,
        ),
      );
    }

    final destIds = orderedPlaces
        .map((s) => s.apiDestinationId)
        .whereType<int>()
        .toList();
    final shortNames = orderedPlaces
        .map((s) => s.title.split('—').first.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    final tripTitle = existingTrip != null
        ? '$daysCount-Day ${existingTrip.title.replaceFirst(RegExp(r'^\d+-Day\s+'), '')}'
        : '$daysCount-Day ${shortNames.take(3).join(' + ')}';

    final summary = RoutePlanOptimizationSummary(
      orderMethod: plan.orderMethod,
      costSource: plan.costSource,
      baselineDistanceKm: plan.savingsVsInput.baselineDistanceKm,
      optimizedDistanceKm: plan.savingsVsInput.optimizedDistanceKm,
      distanceSavedKm: plan.savingsVsInput.distanceSavedKm,
      distanceSavedPercent: plan.savingsVsInput.distanceSavedPercent,
      baselineTransitMinutes: plan.savingsVsInput.baselineTransitMinutes,
      optimizedTransitMinutes: plan.savingsVsInput.optimizedTransitMinutes,
      minutesSaved: plan.savingsVsInput.minutesSaved,
      pace: plan.pace.key,
      suggestedDays: plan.suggestedDays,
      roundtrip: plan.roundtrip,
    );

    if (existingTrip != null) {
      return existingTrip.copyWith(
        title: tripTitle,
        daysCount: daysCount,
        days: builtDays,
        backendDestinationIds:
            destIds.isNotEmpty ? destIds : existingTrip.backendDestinationIds,
        optimizationSummary: summary,
        routeWarnings: plan.warnings,
        pace: plan.pace.key,
        roundtrip: plan.roundtrip,
        lockedFirstDestinationId:
            lockedFirstDestinationId ?? existingTrip.lockedFirstDestinationId,
      );
    }

    return ItineraryTrip(
      id: 'multi_${DateTime.now().millisecondsSinceEpoch}',
      title: tripTitle,
      destination: orderedPlaces
          .map((s) => s.regionName)
          .where((r) => r.isNotEmpty)
          .toSet()
          .join(' • '),
      daysCount: daysCount,
      adults: travelers,
      centerLat: primary.lat,
      centerLng: primary.lng,
      heroAsset: primary.localAssetPath,
      remoteImageUrl: primary.hasRemoteThumbnail ? primary.thumbnailUrl : null,
      vibeTag: 'Multi-Stop Route',
      overviewText:
          'Custom $daysCount-day Region XI route connecting ${shortNames.join(', ')}.',
      // No invented climate: weather comes from the forecast service.
      bestMonths: '',
      avgTemp: '',
      expertName: 'Lakbay+ Route Builder',
      expertTip: orderedPlaces
          .map((s) => s.travelNotes)
          .whereType<String>()
          .where((n) => n.isNotEmpty)
          .take(2)
          .join(' '),
      days: builtDays,
      flights: const [],
      hotels: const <HotelOffer>[],
      backendDestinationId: primary.apiDestinationId,
      backendDestinationIds: destIds,
      whatToBring: orderedPlaces
          .map((s) => s.whatToBring)
          .whereType<String>()
          .where((w) => w.isNotEmpty)
          .join(', '),
      isLocalOnly: true,
      backendBudgetPhp: budgetPhp,
      optimizationSummary: summary,
      routeWarnings: plan.warnings,
      pace: plan.pace.key,
      roundtrip: plan.roundtrip,
      lockedFirstDestinationId: lockedFirstDestinationId,
    );
  }

  ItineraryTrip _applyBackendRoutePlanToTrip(
    ItineraryTrip baseTrip,
    BackendRoutePlanResult backendPlan, {
    required Map<int, ExploreTrip> placeByApiId,
    required bool roundtrip,
    String? lockedFirstDestinationId,
  }) {
    if (backendPlan.days.isEmpty) return baseTrip;
    final phpRate = _currencyRates['PHP'] ?? 57.0;
    final existingStopByTitle = <String, ItineraryStop>{};
    for (final d in baseTrip.days) {
      for (final s in d.stops) {
        existingStopByTitle[s.title.trim().toLowerCase()] = s;
      }
    }

    final refinedDays = <ItineraryDay>[];
    for (final bDay in backendPlan.days) {
      if (bDay.isContinuationDay) {
        final contName = bDay.continuationOfName ?? 'Destination';
        final prev = refinedDays.isNotEmpty ? refinedDays.last : null;
        refinedDays.add(
          ItineraryDay(
            dayNumber: bDay.dayNumber,
            cityTitle: 'Stay & Explore — $contName',
            summary:
                'Continuation / relaxed day at $contName (no inter-stop road travel scheduled).',
            lat: prev?.lat ?? baseTrip.centerLat,
            lng: prev?.lng ?? baseTrip.centerLng,
            visitHours: bDay.visitHours,
            transitHours: 0,
            totalHours: bDay.totalHours,
            isContinuationDay: true,
            continuationOfTitle: contName,
            apiDestinationId: prev?.apiDestinationId,
            stops: [
              ItineraryStop(
                time: '09:00 AM',
                title: 'Free / Leisure Time — $contName',
                description:
                    'Unscheduled continuation day to enjoy local sights and rest.',
                category: 'stay',
                costEstimateUsd: 0,
                lat: prev?.lat ?? baseTrip.centerLat,
                lng: prev?.lng ?? baseTrip.centerLng,
              ),
            ],
          ),
        );
        continue;
      }

      final stops = <ItineraryStop>[];
      var cursorMinutes = 8 * 60;
      for (var i = 0; i < bDay.stops.length; i++) {
        final bs = bDay.stops[i];
        final place =
            bs.destinationId != null ? placeByApiId[bs.destinationId!] : null;
        final existingStop =
            existingStopByTitle[bs.name.trim().toLowerCase()];
        stops.add(
          ItineraryStop(
            time: _formatClockMinutes(cursorMinutes),
            title: bs.name,
            description: existingStop?.description ??
                place?.description ??
                place?.activities ??
                'Explore ${bs.name}.',
            category: existingStop?.category ?? place?.tag ?? 'Scenic',
            costEstimateUsd: existingStop?.costEstimateUsd ??
                ((place?.estimatedCostPhp ?? 600) / phpRate),
            lat: bs.lat,
            lng: bs.lng,
            destinationId: bs.destinationId ?? existingStop?.destinationId,
            stayDurationType: bs.stayDurationType,
            islandGroup: bs.islandGroup ?? existingStop?.islandGroup,
            travelFromPrevMinutes: existingStop?.travelFromPrevMinutes,
            travelFromPrevKm: existingStop?.travelFromPrevKm,
            travelFromPrevMode: existingStop?.travelFromPrevMode,
            isSeaCrossingFromPrev: existingStop?.isSeaCrossingFromPrev ?? false,
          ),
        );
        cursorMinutes += (bs.visitHours * 60).round() + 35;
      }

      final first = bDay.stops.isNotEmpty ? bDay.stops.first : null;
      final transitMins = (bDay.transitHours * 60).round();
      final matchingBaseDay = bDay.dayNumber - 1 < baseTrip.days.length
          ? baseTrip.days[bDay.dayNumber - 1]
          : null;
      refinedDays.add(
        ItineraryDay(
          dayNumber: bDay.dayNumber,
          cityTitle: bDay.stops.isNotEmpty
              ? bDay.stops.map((s) => s.name).join(' • ')
              : 'Day ${bDay.dayNumber}',
          summary:
              '${bDay.stops.length} ${bDay.stops.length == 1 ? 'place' : 'places'} · ~${bDay.visitHours.toStringAsFixed(1)} h exploring${transitMins > 0 ? ' · ${_formatDurationMinutes(transitMins)} transit' : ''}',
          lat: first?.lat ?? baseTrip.centerLat,
          lng: first?.lng ?? baseTrip.centerLng,
          transportFromPrevious: matchingBaseDay?.transportFromPrevious ??
              (bDay.dayNumber > 1 ? TransportMode.car : null),
          transportDuration: transitMins > 0
              ? _formatDurationMinutes(transitMins)
              : matchingBaseDay?.transportDuration,
          stops: stops,
          apiDestinationId: first?.destinationId,
          visitHours: bDay.visitHours,
          transitHours: bDay.transitHours,
          totalHours: bDay.totalHours,
          overloadWarning: bDay.overloadWarning,
        ),
      );
    }

    return baseTrip.copyWith(
      days: refinedDays,
      daysCount: refinedDays.length,
      backendDestinationIds: backendPlan.route.orderedDestinationIds.isNotEmpty
          ? backendPlan.route.orderedDestinationIds
          : baseTrip.backendDestinationIds,
      optimizationSummary: backendPlan.summary,
      routeWarnings: backendPlan.warnings,
      pace: backendPlan.summary.pace,
      roundtrip: roundtrip,
      lockedFirstDestinationId:
          lockedFirstDestinationId ?? baseTrip.lockedFirstDestinationId,
      routeSegments: backendPlan.route.segments,
      seaCrossings: backendPlan.route.seaCrossings,
    );
  }

  ({
    List<ExploreTrip> stops,
    List<RouteStopInput> inputs,
    Map<String, ExploreTrip> byInputId,
  }) _extractRouteStopsFromTrip(ItineraryTrip trip) {
    final extracted = <ExploreTrip>[];
    final byId = <String, ExploreTrip>{};
    final seenKeys = <String>{};

    for (final day in trip.days) {
      if (day.isContinuationDay) continue;
      final candidateStops = day.stops.where((s) => s.category != 'stay').toList();
      if (candidateStops.isEmpty) {
        final key = day.apiDestinationId != null
            ? 'api_${day.apiDestinationId}'
            : '${day.cityTitle.trim().toLowerCase()}_${day.lat.toStringAsFixed(3)}';
        if (seenKeys.add(key)) {
          final catalogMatch =
              day.apiDestinationId != null ? _tripsById['api_${day.apiDestinationId}'] : null;
          final item = catalogMatch ??
              ExploreTrip(
                locale: _locale,
                id: key,
                title: day.cityTitle,
                days: 1,
                lat: day.lat,
                lng: day.lng,
                thumbnailUrl: trip.heroAsset,
                apiDestinationId: day.apiDestinationId,
                islandGroup: _inferIslandGroupFromCoords(day.lat, day.lng),
              );
          extracted.add(item);
          byId[item.id] = item;
        }
        continue;
      }

      for (final stop in candidateStops) {
        final apiId = stop.destinationId ??
            (candidateStops.length == 1 ? day.apiDestinationId : null);
        final key = apiId != null
            ? 'api_$apiId'
            : '${stop.title.trim().toLowerCase()}_${stop.lat.toStringAsFixed(3)}_${stop.lng.toStringAsFixed(3)}';
        if (!seenKeys.add(key)) continue;
        final catalogMatch = apiId != null ? _tripsById['api_$apiId'] : null;
        final item = catalogMatch ??
            ExploreTrip(
              locale: _locale,
              id: key,
              title: stop.title,
              days: 1,
              lat: stop.lat,
              lng: stop.lng,
              thumbnailUrl: trip.heroAsset,
              tag: stop.category,
              apiDestinationId: apiId,
              description: stop.description,
              estimatedCostPhp: stop.costEstimateUsd * (_currencyRates['PHP'] ?? 57.0),
              islandGroup: stop.islandGroup ??
                  _inferIslandGroupFromCoords(stop.lat, stop.lng),
              stayDurationType: stop.stayDurationType,
            );
        extracted.add(item);
        byId[item.id] = item;
      }
    }

    final inputs = [
      for (final s in extracted) _exploreTripToRouteStop(s),
    ];
    return (stops: extracted, inputs: inputs, byInputId: byId);
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
        final hasTag = trip.tag != null && trip.tag!.trim().isNotEmpty;
        result.add(hasTag ? trip : trip.copyWith(tag: item.tag));
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

  /// One-time migration moving legacy bundled combo IDs in favorites onto
  /// their lead single-place ID (or dropping dead IDs) while keeping saved trips.
  void _migrateLegacyFavoriteComboIds() {
    if (_legacyFavoritesMigrated || _bucketListTripIds.isEmpty) {
      if (!_legacyFavoritesMigrated) {
        _legacyFavoritesMigrated = true;
      }
      return;
    }

    final routeById = {for (final r in _suggestedRoutes) r.id: r};
    final migrated = <String>{};
    var changed = false;
    for (final id in _bucketListTripIds) {
      if (_tripsById.containsKey(id)) {
        migrated.add(id);
        continue;
      }
      changed = true;
      final legacyRoute = routeById[id];
      if (legacyRoute != null) {
        final lead = legacyRoute.destinationIds
            .where((destId) => _tripsById.containsKey(destId))
            .firstOrNull;
        if (lead != null) {
          migrated.add(lead);
        }
      }
    }
    _bucketListTripIds
      ..clear()
      ..addAll(migrated);
    _legacyFavoritesMigrated = true;
    if (changed || _prefs != null) {
      _scheduleSaveState();
    }
  }

  Future<void> _loadExploreTripsAndSections() async {
    try {
      final csvRaw = await rootBundle.loadString('assets/data/places.csv');
      final lines = const LineSplitter().convert(csvRaw);
      final parsed = <ExploreTrip>[];
      _tripsById.clear();
      for (int i = 1; i < lines.length; i++) {
        final row = _parseCsvRow(lines[i]);
        if (row.length >= 9) {
          final id = row[0].trim();
          final name = row[1].trim();
          final district = row[2].trim();
          final category = row[3].trim();
          final lat = double.tryParse(row[4].trim());
          final lng = double.tryParse(row[5].trim());
          final islandGroup = row[6].trim().toLowerCase();
          final stayDuration = row[7].trim();
          final thumbnail = row[8].trim();
          if (id.isEmpty || name.isEmpty || lat == null || lng == null) {
            continue;
          }
          final destId = id.startsWith('api_')
              ? int.tryParse(id.replaceFirst('api_', ''))
              : int.tryParse(id);
          final place = ExploreTrip(
            locale: 'en',
            id: id,
            title: name,
            days: 1,
            lat: lat,
            lng: lng,
            thumbnailUrl: thumbnail,
            tag: category.isNotEmpty ? category : 'Place',
            apiDestinationId: destId,
            district: district.isNotEmpty ? district : null,
            islandGroup: islandGroup.isNotEmpty ? islandGroup : null,
            stayDurationType: normalizeStayDurationType(
              stayDuration,
              category: category,
            ),
          );
          parsed.add(place);
          _tripsById[place.id] = place;
        }
      }
      _allTrips = parsed;

      final routesRaw =
          await rootBundle.loadString('assets/data/suggested_routes.json');
      final routesList = jsonDecode(routesRaw) as List<dynamic>? ?? const [];
      _suggestedRoutes = routesList
          .whereType<Map<String, dynamic>>()
          .map(SuggestedRoute.fromJson)
          .toList();

      final discRaw =
          await rootBundle.loadString('assets/data/discovery_sections.json');
      _rawDiscoveryData = jsonDecode(discRaw) as Map<String, dynamic>;
      _rebuildLocaleSections();
    } catch (e) {
      debugPrint('Failed to load explore places: $e');
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

      _cityDescriptions = [
        for (int i = 0; i < shortList.length; i++)
          shortList[i].copyWith(
            longDescription:
                longMap[shortList[i].city.toLowerCase()] ?? shortList[i].description,
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
    // A new traveler starts with an empty chat: no sample trips, no sample
    // conversations and no canned welcome. Older installs may still hold the
    // sample chats this method used to create; drop them.
    const legacySampleChatIds = {
      'chat_today_samal',
      'chat_yest_davao',
      'chat_yest_mati',
    };
    final hadSamples =
        _chatSessions.any((chat) => legacySampleChatIds.contains(chat.id));
    _chatSessions.removeWhere((chat) => legacySampleChatIds.contains(chat.id));
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
    } else if (hadSamples ||
        !_chatSessions.any((chat) => chat.id == _activeChatId)) {
      _activeChatId = _chatSessions.first.id;
      _chatMessages
        ..clear()
        ..addAll(_chatSessions.first.messages);
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

  /// The planning state sent with every chat message: only what the traveler
  /// gave or picked. Nothing is assumed (no party size, days or budget).
  Map<String, dynamic> _ensurePlanningState() {
    return _planningState ??= {
      if (hasOrigin)
        'origin': {
          if (resolvedOriginLabel != null) 'label': resolvedOriginLabel,
          if (originLat != null && originLng != null) 'lat': originLat,
          if (originLat != null && originLng != null) 'lng': originLng,
        },
      'destination_ids': <int>[],
      // The traveler's chosen preference groups (from the catalog), if any.
      if (selectedVibes.isNotEmpty) 'interests': selectedVibes.toList(),
    };
  }

  /// A card's "+ Add" in the chat: toggles the place in the trip tray and
  /// tells the AI planner about it, so the itinerary is built from the
  /// traveler's own picks.
  /// Returns false when the pick limit is reached and nothing was added.
  bool toggleChatPick(ExploreTrip place) {
    if (!isInTripBuilder(place.id) && chatPickCount >= maxChatPicks) {
      return false;
    }
    toggleTripBuilderStop(place);
    final state = _ensurePlanningState();
    state['destination_ids'] = [
      for (final stop in _tripBuilderStops)
        if (stop.apiDestinationId != null) stop.apiDestinationId!,
    ];
    _planningRevision++;
    return true;
  }

  /// The planner accepts at most this many places in one plan.
  static const int maxChatPicks = 10;

  /// Places the traveler has picked in the chat (the ones the plan uses).
  int get chatPickCount =>
      _tripBuilderStops.where((s) => s.apiDestinationId != null).length;

  /// Answers one of the AI's detail questions with a button tap. The answer
  /// is saved in the planning state and also sent as a normal message so the
  /// conversation reads naturally.
  Future<void> answerChatDetail(
    String field,
    Object? value,
    String label, {
    bool isOnboarding = false,
  }) async {
    final state = _ensurePlanningState();
    if (value == null) {
      state.remove(field);
    } else {
      state[field] = value;
    }
    _planningRevision++;
    await sendChatMessage(label, isOnboarding: isOnboarding);
  }

  /// Saves the "what matters most" order (up to 3, most important first), or
  /// records that the traveler skipped the question.
  Future<void> answerChatPriorities(
    List<String> order,
    String label, {
    bool isOnboarding = false,
  }) async {
    if (order.isEmpty) {
      _prioritySkipped = true;
      notifyListeners();
      return;
    }
    await answerChatDetail(
      'priority_order',
      order.take(3).toList(),
      label,
      isOnboarding: isOnboarding,
    );
  }

  bool _prioritySkipped = false;

  /// Exposes current stateless planning state (read-only view for UI previews).
  Map<String, dynamic> get planningStateView =>
      Map<String, dynamic>.unmodifiable(_planningState ?? const {});

  /// Refreshes origin coordinates inside [_planningState] (e.g. after onboarding location step).
  void syncOriginIntoPlanningState() {
    final state = _ensurePlanningState();
    if (hasOrigin) {
      state['origin'] = {
        if (resolvedOriginLabel != null) 'label': resolvedOriginLabel,
        if (originLat != null && originLng != null) 'lat': originLat,
        if (originLat != null && originLng != null) 'lng': originLng,
      };
    } else {
      state.remove('origin');
    }
    notifyListeners();
  }

  /// Current whole-trip budget from planning state, if set.
  double? get planningWholeTripBudgetPhp =>
      computeWholeTripBudgetPhp(_planningState);

  /// Converts `total_budget` + `budget_scope` in [state] to whole-trip PHP
  /// so `/ai/itineraries/generate` never sees a per-person amount as total.
  static double? computeWholeTripBudgetPhp(Map<String, dynamic>? state) {
    final raw = double.tryParse((state?['total_budget'] ?? '').toString());
    if (raw == null || raw <= 0) return null;
    if (state?['budget_scope']?.toString() == 'per_person') {
      final travelers = (state?['traveler_count'] as num?)?.toInt();
      if (travelers == null || travelers <= 0) return null;
      return ((raw * travelers) * 100).roundToDouble() / 100;
    }
    return (raw * 100).roundToDouble() / 100;
  }

  /// Raises the planning state budget and immediately retries itinerary planning.
  Future<void> raisePlanningBudgetAndRetry(double newWholeTripBudgetPhp) async {
    final state = _ensurePlanningState();
    state['total_budget'] = newWholeTripBudgetPhp.toStringAsFixed(2);
    state['budget_scope'] = 'whole_trip';
    _planningRevision++;
    _scheduleSaveState();
    notifyListeners();
    await planWithPicks();
  }

  /// Removes a picked stop and retries itinerary planning with remaining picks.
  Future<void> removePickAndRetry(ExploreTrip place) async {
    if (isInTripBuilder(place.id)) {
      toggleChatPick(place);
    }
    notifyListeners();
    if (chatPickCount > 0) {
      await planWithPicks();
    }
  }

  Future<List<AiItineraryOptionDraft>> _buildCatalogDraftOptionsForPicks({
    required List<int> destinationIds,
    required int dayCount,
    required int travelerCount,
    double? budgetPhp,
    String? city,
    String? query,
  }) async {
    if (apiCatalog.isConfigured) {
      final draftRes = await apiCatalog.buildPlanningDraft(
        isSignedIn ? _authSession!.accessToken : null,
        planningState: {
          ...?_planningState,
          if (destinationIds.isNotEmpty) 'destination_ids': destinationIds,
          'day_count': dayCount,
          'traveler_count': travelerCount,
          if (budgetPhp != null && budgetPhp > 0)
            'total_budget': budgetPhp.toStringAsFixed(2),
        },
        inputRevision: _planningRevision,
        city: city,
        query: query,
      );
      if (draftRes != null && draftRes.options.isNotEmpty) {
        return [
          for (final rawOpt in draftRes.options)
            _parseBackendAiOption(
              rawOpt,
              fallbackDestinationIds: destinationIds,
              isCatalogFallback: true,
            ),
        ];
      }
    }

    // Offline / server-down catalog builder from cached or bundled catalog.
    final matched = <ExploreTrip>[];
    final idSet = destinationIds.toSet();
    for (final place in _allTrips) {
      if (place.apiDestinationId != null &&
          idSet.contains(place.apiDestinationId)) {
        matched.add(place);
      }
    }
    if (matched.isEmpty && (city != null || query != null)) {
      final needle = (city ?? query ?? '').trim().toLowerCase();
      if (needle.isNotEmpty) {
        for (final place in _allTrips) {
          final hay =
              '${place.regionName} ${place.title} ${place.tag}'.toLowerCase();
          if (hay.contains(needle)) {
            matched.add(place);
          }
          if (matched.length >= 5) break;
        }
      }
    }
    if (matched.isEmpty) return const [];

    final savedStops = List<ExploreTrip>.from(_tripBuilderStops);
    final savedOptional = Set<String>.from(_builderOptionalStopIds);
    final savedLocked = _builderLockedFirstStopId;
    try {
      _tripBuilderStops
        ..clear()
        ..addAll(matched);
      _builderOptionalStopIds.clear();
      _builderLockedFirstStopId = null;
      final offlineTrip = (await buildMultiStopExploreTrip(
        daysCount: dayCount,
        travelers: travelerCount,
        refineWithBackend: false,
      ))
          .copyWith(
        isCatalogFallback: true,
        expertName: 'Lakbay Catalog Planner (No AI)',
      );
      return [
        AiItineraryOptionDraft(
          optionNumber: 1,
          title: offlineTrip.title,
          summary:
              "Built from Lakbay's catalog, without AI (${matched.length} ${matched.length == 1 ? 'place' : 'places'}).",
          estimatedTotalCostPhp:
              offlineTrip.backendEstimatedCostPhp ?? 0.0,
          isOverBudget: budgetPhp != null &&
              budgetPhp > 0 &&
              (offlineTrip.backendEstimatedCostPhp ?? 0.0) > budgetPhp,
          isCatalogFallback: true,
          sourceLabel: "Built from Lakbay's catalog, without AI",
          trip: offlineTrip,
        ),
      ];
    } finally {
      _tripBuilderStops
        ..clear()
        ..addAll(savedStops);
      _builderOptionalStopIds
        ..clear()
        ..addAll(savedOptional);
      _builderLockedFirstStopId = savedLocked;
    }
  }

  /// Asks Lakbay AI to refine or replace a catalog-built trip with richer guidance.
  Future<ItineraryTrip?> improveCatalogTripWithAi(ItineraryTrip trip) async {
    final destIds = trip.effectiveBackendDestinationIds;
    if (isSignedIn && apiCatalog.isConfigured && destIds.isNotEmpty) {
      final refined = await refineTripWithAi(
        trip,
        'Keep these catalog destinations and improve daily flow, timing, and local tips.',
      );
      if (refined != null) {
        return refined.copyWith(isCatalogFallback: false);
      }
    }
    final stopNames = trip.days
        .expand((d) => d.stops)
        .map((s) => s.title)
        .toSet()
        .take(5)
        .join(', ');
    await planInChat(
      'Improve my ${trip.daysCount}-day ${trip.title} itinerary including $stopNames.',
    );
    return null;
  }

  /// Asks the AI to plan from the traveler's picked places.
  ///
  /// When days, party size, and budget are already set, this skips the extra
  /// chat LLM turn and generates itineraries directly to avoid rate limits.
  Future<void> planWithPicks({bool isOnboarding = false}) async {
    final pickLabel = chatPickCount == 1
        ? 'Plan a trip with my pick.'
        : 'Plan a trip with my $chatPickCount picks.';
    final state = _planningState;
    final targetDestIds = [
      for (final stop in _tripBuilderStops)
        if (stop.apiDestinationId != null) stop.apiDestinationId!,
    ];
    final daysCount = (state?['day_count'] as num?)?.toInt();
    final travelerCount = (state?['traveler_count'] as num?)?.toInt();
    final budgetPhp = computeWholeTripBudgetPhp(state);

    if (!apiCatalog.isConfigured ||
        targetDestIds.isEmpty ||
        daysCount == null ||
        travelerCount == null ||
        budgetPhp == null ||
        budgetPhp <= 0) {
      await sendChatMessage(pickLabel, isOnboarding: isOnboarding);
      return;
    }

    _planningState = {
      ..._ensurePlanningState(),
      'destination_ids': targetDestIds,
    };
    _chatMessages.add(
      ChatMessage(
        id: 'user_${DateTime.now().millisecondsSinceEpoch}',
        isUser: true,
        text: pickLabel,
        timestamp: DateTime.now(),
      ),
    );
    _isAiTyping = true;
    _aiTypingStatus =
        'Building your itinerary from $chatPickCount ${chatPickCount == 1 ? 'pick' : 'picks'}...';
    notifyListeners();

    try {
      final result = await apiCatalog.generateAiItineraries(
        _authSession?.accessToken,
        totalBudgetPhp: budgetPhp,
        travelerCount: travelerCount,
        dayCount: daysCount.clamp(1, 30),
        destinationIds: targetDestIds,
        planningState: _planningState,
        inputRevision: _planningRevision,
        strictBudgetFilter: strictBudgetFilter,
        language: _aiLanguage,
        onRateLimitRetry: (waitSeconds) {
          _aiTypingStatus =
              'The AI is busy. Trying again in ${waitSeconds}s...';
          notifyListeners();
        },
      );
      if (result is AiItinerarySuccess) {
        final aiOptions = [
          for (final rawOpt in result.options)
            _parseBackendAiOption(
              rawOpt,
              generationRunId: result.generationRunId,
              fallbackDestinationIds: targetDestIds,
            ),
        ];
        final attachedTrip = aiOptions.first.trip;
        _chatMessages.add(
          ChatMessage(
            id: 'ai_${DateTime.now().millisecondsSinceEpoch}',
            isUser: false,
            text: aiOptions.length > 1
                ? 'Here are ${aiOptions.length} itinerary options built from your picks.'
                : 'Here is an itinerary built from your picks.',
            timestamp: DateTime.now(),
            attachedTrip: aiOptions.length <= 1 ? attachedTrip : null,
            aiOptions: aiOptions,
          ),
        );
        _aiTypingStatus = null;
        _isAiTyping = false;
        _syncActiveSession(
          titleHint: attachedTrip.title,
          hasTrip: true,
        );
        _scheduleSaveState();
        notifyListeners();
        return;
      }
      final failure = result as AiItineraryFailure;
      const blockingUserCodes = {
        'planning_over_budget',
        'planning_selection_invalid',
        'planning_input_mismatch',
      };
      if (!blockingUserCodes.contains(failure.code)) {
        final fallbackOptions = await _buildCatalogDraftOptionsForPicks(
          destinationIds: targetDestIds,
          dayCount: daysCount.clamp(1, 30),
          travelerCount: travelerCount,
          budgetPhp: budgetPhp,
        );
        if (fallbackOptions.isNotEmpty) {
          final attached = fallbackOptions.first.trip;
          _chatMessages.add(
            ChatMessage(
              id: 'ai_${DateTime.now().millisecondsSinceEpoch}',
              isUser: false,
              text:
                  "The AI is busy, so here's a plan built from Lakbay's catalog, without AI.",
              timestamp: DateTime.now(),
              attachedTrip: fallbackOptions.length <= 1 ? attached : null,
              aiOptions: fallbackOptions,
            ),
          );
          _aiTypingStatus = null;
          _isAiTyping = false;
          _syncActiveSession(titleHint: attached.title, hasTrip: true);
          _scheduleSaveState();
          notifyListeners();
          return;
        }
      }
      _addChatError(
        pickLabel,
        failure.userFacingMessage(),
        errorCode: failure.code,
      );
    } catch (_) {
      _addChatError(
        pickLabel,
        'Something went wrong while building your itinerary. Please try again.',
        errorCode: 'network_error',
      );
    }
  }

  static Map<String, dynamic>? _conversation(Map<String, dynamic>? planning) {
    final value = planning?['conversation'];
    return value is Map<String, dynamic> ? value : null;
  }

  /// The one detail the server wants next, only for the questions the app
  /// can answer with buttons.
  static String? _firstMissingDetail(Map<String, dynamic>? planning) {
    final missing = _conversation(planning)?['missing_details'];
    if (missing is! List || missing.isEmpty) return null;
    const buttonQuestions = {
      'activity_level',
      'travel_start_date',
      'prefers_quiet',
    };
    final first = missing.first.toString();
    return buttonQuestions.contains(first) ? first : null;
  }

  static List<String> _optionalDetails(Map<String, dynamic>? planning) {
    final value = _conversation(planning)?['optional_details'];
    return value is List ? value.map((e) => e.toString()).toList() : const [];
  }

  void _addChatError(
    String retryText,
    String message, {
    String? errorCode,
  }) {
    _aiTypingStatus = null;
    _chatMessages.add(
      ChatMessage(
        id: 'err_${DateTime.now().millisecondsSinceEpoch}',
        isUser: false,
        text: message,
        timestamp: DateTime.now(),
        isError: true,
        retryText: retryText,
        errorCode: errorCode,
      ),
    );
    _isAiTyping = false;
    _syncActiveSession();
    _scheduleSaveState();
    notifyListeners();
  }

  /// Sends a message to Lakbay AI.
  ///
  /// Signed in or not, chat goes through the backend (guests use the
  /// rate-limited guest endpoint), so the app ships no AI provider key. When
  /// the AI cannot be reached the traveler sees an error and can retry; the
  /// app never substitutes an invented itinerary.
  Future<void> sendChatMessage(String text, {bool isOnboarding = false}) async {
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

    if (!apiCatalog.isConfigured) {
      _addChatError(
        trimmed,
        "Lakbay AI isn't connected to the server, so I can't answer right now.",
      );
      return;
    }

    _aiTypingStatus = null;
    _isAiTyping = true;
    notifyListeners();
    try {
      // The most recent turns (not the first ones) before this message.
      final earlier = _chatMessages.take(
          _chatMessages.length > 1 ? _chatMessages.length - 1 : 0);
      final history = earlier
          .where((m) => !m.isError)
          .skip(math.max(0, earlier.length - _serverChatHistoryTurns))
          .map((m) => {
                'role': m.isUser ? 'user' : 'assistant',
                'content': _chatHistoryText(m.text),
              })
          .where((m) => m['content']!.isNotEmpty)
          .toList();
      final serverAi = await apiCatalog.aiChat(
        _authSession?.accessToken,
        message: trimmed,
        history: history,
        planningState: _ensurePlanningState(),
        inputRevision: _planningRevision,
        language: _aiLanguage,
        isOnboarding: isOnboarding,
      );
      if (serverAi == null) {
        _addChatError(
          trimmed,
          "I couldn't reach Lakbay AI just now. Check your connection and try again.",
        );
        return;
      }

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

      // Only places the traveler picked (or named) are planned: never the
      // first few search results.
      final targetDestIds =
          (_planningState?['destination_ids'] as List<dynamic>? ?? const [])
              .whereType<num>()
              .map((n) => n.toInt())
              .toList();

      // The model judges intent; keywords are only a fallback for replies
      // without one (older backends or unparseable output).
      final intent = planning?['intent']?.toString();
      // Cards come from the server's ranking for any planning reply. A plain
      // question, logistics or small-talk reply never shows place cards.
      const textOnlyIntents = {'question', 'logistics', 'smalltalk'};
      final recommendedPlaces = textOnlyIntents.contains(intent)
          ? const <TopPlaceRecommendation>[]
          : (planning?['recommendations'] as List<dynamic>? ?? const [])
              .whereType<Map<String, dynamic>>()
              .map(TopPlaceRecommendation.fromJson)
              .toList();
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

      // Everything below comes from the traveler. A missing detail is not
      // guessed: the AI asks for it in its reply instead.
      final daysCount = (_planningState?['day_count'] as num?)?.toInt() ??
          RegExp(r'(\d+)\s*-?\s*day', caseSensitive: false)
              .firstMatch(trimmed)
              ?.group(1)
              .letOrNull(int.tryParse);
      final travelerCount =
          (_planningState?['traveler_count'] as num?)?.toInt();
      final budgetPhp = computeWholeTripBudgetPhp(_planningState);
      final canGenerateValidatedItinerary = targetDestIds.isNotEmpty &&
          daysCount != null &&
          travelerCount != null &&
          budgetPhp != null &&
          budgetPhp > 0;

      if (wantsItinerary && canGenerateValidatedItinerary) {
        final generated = await apiCatalog.generateAiItineraries(
          _authSession?.accessToken,
          totalBudgetPhp: budgetPhp,
          travelerCount: travelerCount,
          dayCount: daysCount.clamp(1, 14),
          destinationIds: targetDestIds,
          planningState: _planningState,
          inputRevision: _planningRevision,
          specialRequirements: trimmed,
          strictBudgetFilter: strictBudgetFilter,
          language: _aiLanguage,
          onRateLimitRetry: (waitSeconds) {
            _aiTypingStatus =
                'The AI is busy. Trying again in ${waitSeconds}s...';
            notifyListeners();
          },
        );
        if (generated is AiItinerarySuccess) {
          aiOptions = [
            for (final rawOpt in generated.options)
              _parseBackendAiOption(
                rawOpt,
                generationRunId: generated.generationRunId,
                fallbackDestinationIds: targetDestIds,
                includeFlights: _needsFlights(trimmed),
              ),
          ];
          attachedTrip = aiOptions.first.trip;
        } else {
          final failure = generated as AiItineraryFailure;
          const blockingUserCodes = {
            'planning_over_budget',
            'planning_selection_invalid',
            'planning_input_mismatch',
          };
          var recovered = false;
          if (!blockingUserCodes.contains(failure.code)) {
            final fallbackOptions = await _buildCatalogDraftOptionsForPicks(
              destinationIds: targetDestIds,
              dayCount: daysCount.clamp(1, 14),
              travelerCount: travelerCount,
              budgetPhp: budgetPhp,
            );
            if (fallbackOptions.isNotEmpty) {
              aiOptions = fallbackOptions;
              attachedTrip = aiOptions.first.trip;
              recovered = true;
            }
          }
          if (!recovered) {
            _addChatError(
              trimmed,
              failure.userFacingMessage(),
              errorCode: failure.code,
            );
            return;
          }
        }
      } else if (wantsItinerary && !isSignedIn && !isOnboarding) {
        // Signed-out quick free-text prompt without full picks/inputs uses trip-draft.
        try {
          final draft = await aiService.chatOrPlan(
            userPrompt: trimmed,
            history: history,
            currentLocation: resolvedOriginLabel,
            userLat: originLat,
            userLng: originLng,
            preferredVibes: selectedVibes,
            strictBudget: strictBudgetFilter,
            language: _aiLanguage,
          );
          if (draft.hasStructuredItinerary) {
            attachedTrip = _buildItineraryFromAi(draft);
          }
        } catch (_) {
          // The AI's reply still shows; there is just no draft attached.
        }
      }

      final effectiveText = aiOptions.isNotEmpty &&
              aiOptions.every((o) => o.isCatalogFallback)
          ? "The AI is busy, so here's a plan built from Lakbay's catalog, without AI."
          : serverAi.replyText;
      _chatMessages.add(
        ChatMessage(
          id: 'ai_${DateTime.now().millisecondsSinceEpoch}',
          isUser: false,
          text: effectiveText,
          timestamp: DateTime.now(),
          attachedTrip: aiOptions.length <= 1 ? attachedTrip : null,
          aiOptions: aiOptions,
          recommendedPlaces: recommendedPlaces,
          // Only what the AI suggested for this conversation.
          suggestedReplies: modelReplies,
          askNext: _firstMissingDetail(planning),
          offerPriorities: !_prioritySkipped &&
              _optionalDetails(planning).contains('priority_order'),
        ),
      );
      _aiTypingStatus = null;
      _isAiTyping = false;
      _syncActiveSession(
        titleHint: attachedTrip?.title ?? trimmed,
        hasTrip: attachedTrip != null || aiOptions.isNotEmpty,
      );
      _scheduleSaveState();
      notifyListeners();
    } catch (_) {
      _addChatError(
        trimmed,
        'Something went wrong while talking to Lakbay AI. Please try again.',
      );
    }
  }

  /// Generates a Region XI trip via live Groq/Gemini AI (if configured in `.env`)
  /// or falls back to the local Davao Region itinerary builder.
  /// A trip drafted by the AI from the traveler's own words, or null when the
  /// AI is unreachable or did not return a usable plan. Nothing is invented
  /// to stand in for it.
  Future<ItineraryTrip?> createTripFromAiPrompt(String prompt) async {
    if (aiService.isConfigured) {
      try {
        final aiResult = await aiService.chatOrPlan(
          userPrompt: prompt,
          availableDestinations: _allTrips.map((t) => t.title).toList(),
          currentLocation: resolvedOriginLabel,
          userLat: originLat,
          userLng: originLng,
          preferredVibes: selectedVibes,
          strictBudget: strictBudgetFilter,
          language: _aiLanguage,
        );
        if (aiResult.hasStructuredItinerary) {
          return _buildItineraryFromAi(aiResult);
        }
      } catch (_) {
        // The caller tells the traveler and offers to try again.
      }
    }
    return null;
  }

  /// Exposes [_buildItineraryFromAi] when an onboarding/chat turn already produced
  /// a structured multi-day itinerary.
  ItineraryTrip buildTripFromAiResult(AiPlanResult ai) =>
      _buildItineraryFromAi(ai);

  /// Finalizes an itinerary during onboarding from picked destinations or chat context,
  /// using `/ai/itineraries/generate/guest` (or `/ai/trip-draft`) with automatic Phase 2
  /// `/planning/draft` catalog fallback when AI is busy or unavailable.
  Future<ItineraryTrip?> buildOnboardingItinerary({
    String? fallbackPrompt,
  }) async {
    for (final msg in _chatMessages.reversed) {
      if (msg.aiOptions.isNotEmpty) return msg.aiOptions.first.trip;
      if (msg.attachedTrip != null) return msg.attachedTrip;
    }

    final state = _planningState;
    final stateIds = (state?['destination_ids'] as List<dynamic>? ?? const [])
        .whereType<num>()
        .map((n) => n.toInt())
        .toList();
    final stopIds = [
      for (final stop in _tripBuilderStops)
        if (stop.apiDestinationId != null) stop.apiDestinationId!,
    ];
    final targetDestIds =
        {...stateIds, ...stopIds}.take(maxChatPicks).toList();

    final dayCount = ((state?['day_count'] as num?)?.toInt() ?? 2).clamp(1, 14);
    final travelerCount =
        ((state?['traveler_count'] as num?)?.toInt() ?? 2).clamp(1, 50);
    final budgetPhp = computeWholeTripBudgetPhp(state) ?? 6000.0;

    final userNotes = _chatMessages
        .where((m) => m.isUser && m.text.trim().isNotEmpty)
        .map((m) => m.text.trim())
        .join(' • ');
    final originNote = hasOrigin ? 'Origin: $effectiveOriginLabel. ' : '';
    final promptText = fallbackPrompt?.trim().isNotEmpty == true
        ? fallbackPrompt!.trim()
        : '$originNote${userNotes.isNotEmpty ? "Preferences: $userNotes. " : ""}Plan a $dayCount-day Davao Region trip for $travelerCount travelers.';

    if (apiCatalog.isConfigured && targetDestIds.isNotEmpty) {
      final adjustedState = <String, dynamic>{
        ..._ensurePlanningState(),
        'destination_ids': targetDestIds,
        'day_count': dayCount,
        'traveler_count': travelerCount,
        'total_budget': budgetPhp.toStringAsFixed(2),
        'budget_scope': 'whole_trip',
      };
      final generated = await apiCatalog.generateAiItineraries(
        _authSession?.accessToken,
        totalBudgetPhp: budgetPhp,
        travelerCount: travelerCount,
        dayCount: dayCount,
        destinationIds: targetDestIds,
        planningState: adjustedState,
        inputRevision: _planningRevision,
        specialRequirements: userNotes.isNotEmpty ? userNotes : null,
        strictBudgetFilter: strictBudgetFilter,
        language: _aiLanguage,
      );
      if (generated is AiItinerarySuccess && generated.options.isNotEmpty) {
        return _parseBackendAiOption(
          generated.options.first,
          generationRunId: generated.generationRunId,
          fallbackDestinationIds: targetDestIds,
          includeFlights: _needsFlights(promptText),
        ).trip;
      }
      final fallback = await _buildCatalogDraftOptionsForPicks(
        destinationIds: targetDestIds,
        dayCount: dayCount,
        travelerCount: travelerCount,
        budgetPhp: budgetPhp,
        query: promptText,
      );
      if (fallback.isNotEmpty) return fallback.first.trip;
    }

    final aiDraft = await createTripFromAiPrompt(promptText);
    if (aiDraft != null) return aiDraft;

    final catalogDraft = await _buildCatalogDraftOptionsForPicks(
      destinationIds: targetDestIds,
      dayCount: dayCount,
      travelerCount: travelerCount,
      budgetPhp: budgetPhp,
      query: userNotes.isNotEmpty ? userNotes : 'Davao Region getaway',
    );
    if (catalogDraft.isNotEmpty) return catalogDraft.first.trip;

    return null;
  }

  /// Flights are offered when the traveler's start point is outside Region XI,
  /// or they ask for a flight in their own words. No list of cities is kept.
  bool _needsFlights(String prompt) {
    final lat = originLat, lng = originLng;
    final startsOutsideRegion =
        lat != null && lng != null && !MapboxService.isInsideDavaoRegion(lat, lng);
    return startsOutsideRegion ||
        RegExp(r'\b(flights?|fly(?:ing)? in|airfare|airplane)\b',
                caseSensitive: false)
            .hasMatch(prompt);
  }

  AiItineraryOptionDraft _parseBackendAiOption(
    Map<String, dynamic> rawOpt, {
    int? generationRunId,
    ItineraryTrip? fallbackTrip,
    String? preferredRemoteImageUrl,
    String? preferredHeroAsset,
    List<int> fallbackDestinationIds = const [],
    bool includeFlights = false,
    bool isCatalogFallback = false,
  }) {
    final effectiveFallback =
        isCatalogFallback || rawOpt['cost_source'] == 'catalog_deterministic';
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
      adults: fallbackTrip?.adults,
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
          : (fallbackTrip?.overviewText ?? ''),
      bestMonths: firstMatchedCatalog?.bestTimeToVisit ?? '',
      avgTemp: fallbackTrip?.avgTemp ?? '',
      expertName: effectiveFallback
          ? 'Lakbay Catalog Planner (No AI)'
          : 'Lakbay+ AI Planner',
      expertTip:
          firstMatchedCatalog?.travelNotes ?? fallbackTrip?.expertTip ?? '',
      days: parsedDays.isNotEmpty ? parsedDays : (fallbackTrip?.days ?? const []),
      // No airfare is invented: the app has no flight data.
      flights: const [],
      hotels: fallbackTrip?.hotels ?? const <HotelOffer>[],
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
      isCatalogFallback: effectiveFallback,
    );

    return AiItineraryOptionDraft(
      optionNumber: optionNumber,
      title: optTitle,
      summary: summary,
      estimatedTotalCostPhp: totalCostPhp,
      isOverBudget: isOverBudget,
      generationRunId: generationRunId,
      isCatalogFallback: effectiveFallback,
      sourceLabel: effectiveFallback
          ? (rawOpt['source_label']?.toString() ??
              "Built from Lakbay's catalog, without AI")
          : null,
      trip: trip,
    );
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
      bestMonths: '',
      avgTemp: '',
      expertName: 'Lakbay+ AI',
      expertTip: '',
      days: days,
      flights: const [],
      hotels: const <HotelOffer>[],
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
      return base.copyWith(
        days: _anchorDaysOnExplorePlace(base.days, explore, destId),
      );
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
      days: _anchorDaysOnExplorePlace(base.days, explore, destId),
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

  /// Explore trips describe one real place. The generic Davao templates from
  /// [generateCustomTrip] must not leak in (e.g. a "Barangay San Pedro" day
  /// and fake stops in Poblacion for Tagbibinta Falls), so every day is
  /// rebuilt around the explore place: its name, description and coordinates.
  /// Weather, hotel and transport hints from the template days are kept.
  List<ItineraryDay> _anchorDaysOnExplorePlace(
    List<ItineraryDay> templateDays,
    ExploreTrip explore,
    int? destId,
  ) {
    final placeName = explore.title
        .replaceAll(RegExp(r'^\d+-Day\s*', caseSensitive: false), '')
        .trim();
    final description = explore.description?.trim().isNotEmpty == true
        ? explore.description!.trim()
        : 'Explore $placeName in ${explore.regionName}.';
    final details = <String>[
      if (explore.operatingHours?.isNotEmpty == true)
        'Hours: ${explore.operatingHours}',
      if (explore.entranceFee?.isNotEmpty == true)
        'Entrance: ${explore.entranceFee}',
    ].join(' • ');
    final tagLower = (explore.tag ?? '').toLowerCase();
    const natureWords = [
      'fall', 'beach', 'nature', 'park', 'mountain', 'island', 'spring',
      'lake', 'mangrove', 'wildlife', 'farm', 'peak', 'trail', 'forest',
    ];
    final category =
        natureWords.any(tagLower.contains) ? 'nature' : 'sight';

    return [
      for (final day in templateDays)
        ItineraryDay(
          dayNumber: day.dayNumber,
          cityTitle: day.dayNumber == 1
              ? placeName
              : 'Day ${day.dayNumber} • More time at $placeName',
          summary: day.dayNumber == 1
              ? description
              : 'Unhurried second look at $placeName and its surroundings.',
          lat: explore.lat,
          lng: explore.lng,
          wmoWeatherCode: day.wmoWeatherCode,
          tempCelsius: day.tempCelsius,
          transportFromPrevious:
              day.dayNumber == 1 ? day.transportFromPrevious : null,
          transportDuration: day.dayNumber == 1 ? day.transportDuration : null,
          recommendedHotel: day.recommendedHotel,
          apiDestinationId: destId,
          // Later days stay at the same place: mark them as continuation days
          // so the map does not stack duplicate pins or connectors.
          isContinuationDay: day.dayNumber > 1,
          continuationOfTitle: day.dayNumber > 1 ? placeName : null,
          stops: [
            if (day.dayNumber == 1)
            ItineraryStop(
              time: '08:30 AM',
              title: placeName,
              description: details.isEmpty
                  ? description
                  : '$description\n$details',
              category: category,
              costEstimateUsd: 0,
              lat: explore.lat,
              lng: explore.lng,
              destinationId: destId,
              stayDurationType: explore.stayDurationType,
              islandGroup: explore.islandGroup,
            ),
          ],
        ),
    ];
  }


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

    // Only real catalog places, with their real coordinates. There is no typed-in
    // route, schedule, meal stop or cost here: the stops are the catalog's places
    // for this destination, nearest first, and real travel legs come from the
    // route service when the trip is planned.
    final places = _catalogPlacesFor(
      destination,
      clampedLat,
      clampedLng,
      near: centerLat != null && centerLng != null,
      limit: daysCount * 3,
    );
    final perDay = places.isEmpty ? 1 : (places.length / daysCount).ceil().clamp(1, 3);
    final days = <ItineraryDay>[];
    for (var d = 1; d <= daysCount; d++) {
      final dayPlaces = places.skip((d - 1) * perDay).take(perDay).toList();
      final first = dayPlaces.firstOrNull;
      days.add(
        ItineraryDay(
          dayNumber: d,
          cityTitle: first == null ? 'Day $d' : 'Day $d \u2022 ${first.title}',
          summary: dayPlaces.isEmpty
              ? 'No places added to this day yet.'
              : '${dayPlaces.length} ${dayPlaces.length == 1 ? 'place' : 'places'} from the Lakbay catalog.',
          lat: first?.lat ?? clampedLat,
          lng: first?.lng ?? clampedLng,
          stops: [
            for (final place in dayPlaces)
              ItineraryStop(
                time: '',
                title: place.title,
                description: place.description ?? '',
                category: _stopCategoryFor(place),
                lat: place.lat,
                lng: place.lng,
                destinationId: place.apiDestinationId,
                stayDurationType: place.stayDurationType,
                islandGroup: place.islandGroup,
              ),
          ],
        ),
      );
    }

    return ItineraryTrip(
      id: tripId,
      title: cleanTitle,
      destination: destination,
      daysCount: daysCount,
      centerLat: clampedLat,
      centerLng: clampedLng,
      heroAsset: effectiveHero,
      vibeTag: vibe,
      // Nothing is invented here: no climate, no named experts, no schedules,
      // no airfare. Weather, stays and notes arrive from the live services.
      overviewText: '',
      bestMonths: '',
      avgTemp: '',
      expertName: '',
      expertTip: '',
      days: days,
      flights: const [],
      hotels: const <HotelOffer>[],
      remoteImageUrl: remoteImageUrl,
      isLocalOnly: true,
    );
  }

  /// Catalog places that belong to [destination] (matched by name, district or
  /// region), nearest to ([lat], [lng]) first. When nothing matches by name and
  /// [near] is true, the closest places within about 40 km are used instead.
  List<ExploreTrip> _catalogPlacesFor(
    String destination,
    double lat,
    double lng, {
    required bool near,
    required int limit,
  }) {
    const ignored = {
      'davao', 'region', 'island', 'city', 'the', 'and', 'trip', 'day', 'days',
      'tour', 'highlights', 'curated', 'multi', 'stop', 'custom',
    };
    final words = destination
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9]+'))
        .where((w) => w.length > 3 && !ignored.contains(w) && int.tryParse(w) == null)
        .toSet();
    double distance(ExploreTrip t) =>
        MapboxService.haversineKm(lat, lng, t.lat, t.lng);

    var matched = words.isEmpty
        ? <ExploreTrip>[]
        : _allTrips.where((t) {
            final haystack =
                '${t.title} ${t.district ?? ''} ${t.regionName} ${t.tag ?? ''}'.toLowerCase();
            return words.any(haystack.contains);
          }).toList();
    if (matched.isEmpty && near) {
      matched = _allTrips.where((t) => distance(t) <= 40).toList();
    }
    matched.sort((a, b) => distance(a).compareTo(distance(b)));
    return matched.take(limit).toList();
  }

  String _stopCategoryFor(ExploreTrip place) {
    final label = '${place.tag ?? ''} ${place.title}'.toLowerCase();
    const nature = ['falls', 'waterfall', 'mountain', 'park', 'island', 'beach', 'lake', 'spring', 'farm', 'garden'];
    return nature.any(label.contains) ? 'nature' : 'sight';
  }


  /// Resolves the best origin label from manual selection, reverse-geocoded GPS,
  /// or user profile location. Empty when neither GPS nor manual start is set.
  String get effectiveOriginLabel {
    final manual = _manualOriginLabel?.trim() ?? '';
    if (manual.isNotEmpty) return manual;
    final profileCity = _profile.location.trim();
    if (profileCity.isNotEmpty) return profileCity;
    if (hasUserLocation) {
      return '${_userLat!.toStringAsFixed(3)}°, ${_userLng!.toStringAsFixed(3)}°';
    }
    return '';
  }

  /// A short name for the starting place to show in the header: a place
  /// name when there is one, "Pinned location" when only coordinates are
  /// known, and an empty string when no start is set.
  String get originDisplayName {
    final label = effectiveOriginLabel.trim();
    if (label.isEmpty) return '';
    final looksLikeCoordinates =
        RegExp(r'^-?\d+(\.\d+)?°?,\s*-?\d+(\.\d+)?°?$').hasMatch(label);
    return looksLikeCoordinates ? 'Pinned location' : label;
  }

  String? get resolvedOriginLabel {
    final label = effectiveOriginLabel.trim();
    return label.isEmpty ? null : label;
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
  Future<bool> refreshCurrentLocationSilently({
    bool requireExistingGrant = false,
  }) async {
    try {
      final hasPermission = await locationService.hasGrantedPermission();
      if (!hasPermission &&
          (requireExistingGrant || locationService.customFetcher == null)) {
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
