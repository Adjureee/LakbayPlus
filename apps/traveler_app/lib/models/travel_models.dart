// Core domain models for Lakbay+ — Davao Region (Region XI) AI Travel Planner.

enum TransportMode { flight, train, car, bus, ferry }

TransportMode _transportModeFromName(String? value) {
  for (final mode in TransportMode.values) {
    if (mode.name == value) return mode;
  }
  return TransportMode.car;
}

class GeoPoint {
  final double lat;
  final double lng;
  final String? label;
  final TransportMode legMode;
  final int? dayNumber;

  const GeoPoint({
    required this.lat,
    required this.lng,
    this.label,
    this.legMode = TransportMode.car,
    this.dayNumber,
  });

  Map<String, dynamic> toJson() => {
        'lat': lat,
        'lng': lng,
        if (label != null) 'label': label,
        'legMode': legMode.name,
        if (dayNumber != null) 'dayNumber': dayNumber,
      };

  factory GeoPoint.fromJson(Map<String, dynamic> json) => GeoPoint(
        lat: (json['lat'] as num?)?.toDouble() ?? 0.0,
        lng: (json['lng'] as num?)?.toDouble() ?? 0.0,
        label: json['label'] as String?,
        legMode: _transportModeFromName(json['legMode'] as String?),
        dayNumber: (json['dayNumber'] as num?)?.toInt(),
      );
}

enum MapboxStylePreset {
  outdoors(
    id: 'outdoors-v12',
    title: 'Outdoors',
    subtitle: 'Topographic terrain & trails',
  ),
  satelliteStreets(
    id: 'satellite-streets-v12',
    title: 'Satellite',
    subtitle: 'Aerial imagery & coral reefs',
  ),
  coastalLight(
    id: 'light-v11',
    title: 'Coastal Light',
    subtitle: 'Minimalist Lakbay+ street map',
  ),
  navigationNight(
    id: 'navigation-night-v1',
    title: 'Night Nav',
    subtitle: 'High-contrast evening transit',
  );

  final String id;
  final String title;
  final String subtitle;

  const MapboxStylePreset({
    required this.id,
    required this.title,
    required this.subtitle,
  });
}

class BackdropItem {
  final String id;
  final String place;
  final String country;
  final String photographer;
  final String unsplashUrl;

  const BackdropItem({
    required this.id,
    required this.place,
    required this.country,
    required this.photographer,
    required this.unsplashUrl,
  });

  String get localAssetPath => 'assets/home_backdrops/$id.jpg';

  factory BackdropItem.fromJson(Map<String, dynamic> json) {
    return BackdropItem(
      id: json['id'] as String? ?? '01-samal-island',
      place: json['place'] as String? ?? 'Samal Island',
      country: json['country'] as String? ?? 'Davao Region',
      photographer: json['photographer'] as String? ?? 'Unsplash',
      unsplashUrl: json['unsplashUrl'] as String? ?? '',
    );
  }
}

class ExploreTrip {
  final String locale;
  final String id;
  final String title;
  final int days;
  final double lat;
  final double lng;
  final String thumbnailUrl;
  final String? tag;

  // Live backend destination metadata (populated when synced with FastAPI).
  final int? apiDestinationId;
  final String? description;
  final String? district;
  final String? activities;
  final double? estimatedCostPhp;
  final String? entranceFee;
  final String? overnightFee;
  final String? operatingHours;
  final String? bestTimeToVisit;
  final String? travelNotes;
  final String? whatToBring;
  final String? islandGroup;
  final String? stayDurationType;

  const ExploreTrip({
    required this.locale,
    required this.id,
    required this.title,
    this.days = 1,
    required this.lat,
    required this.lng,
    required this.thumbnailUrl,
    this.tag,
    this.apiDestinationId,
    this.description,
    this.district,
    this.activities,
    this.estimatedCostPhp,
    this.entranceFee,
    this.overnightFee,
    this.operatingHours,
    this.bestTimeToVisit,
    this.travelNotes,
    this.whatToBring,
    this.islandGroup,
    this.stayDurationType,
  });

  bool get isApiBacked => apiDestinationId != null || id.startsWith('api_');

  bool get hasRemoteThumbnail =>
      thumbnailUrl.startsWith('http://') || thumbnailUrl.startsWith('https://');

  String get localAssetPath => davaoBackdropAssetFor('$title ${district ?? ''}');

  /// Normalizes backend or CSV stay duration types into canonical keys.
  String get normalizedStayDurationType => normalizeStayDurationType(
        stayDurationType,
        category: tag ?? '',
        overnightFee: overnightFee ?? '',
      );

  /// Human-friendly typical visit length label displayed on single-place cards.
  String get stayDurationLabel => switch (normalizedStayDurationType) {
        'short' => '1–2 hrs',
        'half_day' => 'Half day',
        'full_day' => 'Full day',
        'overnight' => 'Overnight',
        'multi_day' => 'Multi-day',
        _ => 'Half day',
      };

  /// Clean municipality/district subtitle for Explore place cards.
  String get municipalityLabel {
    final d = district?.trim() ?? '';
    return d.isNotEmpty ? d : regionName;
  }

  String get regionName {
    final lower = '${title.toLowerCase()} ${(district ?? '').toLowerCase()}';
    final ig = (islandGroup ?? '').toLowerCase();
    if (ig == 'samal' ||
        ig == 'talikud' ||
        lower.contains('samal') ||
        lower.contains('igacos') ||
        lower.contains('talikud') ||
        lower.contains('pearl farm')) {
      return 'Samal (IGaCoS)';
    }
    if (ig == 'balut' || lower.contains('balut') || lower.contains('sarangani')) {
      return 'Davao Occidental';
    }
    if (lower.contains('mati') ||
        lower.contains('dahican') ||
        lower.contains('aliwagwag') ||
        lower.contains('cape san agustin') ||
        lower.contains('oriental') ||
        lower.contains('baganga')) {
      return 'Davao Oriental';
    }
    if (lower.contains('apo') ||
        lower.contains('kapatagan') ||
        lower.contains('digos') ||
        lower.contains('passig') ||
        lower.contains('sta. cruz')) {
      return 'Davao del Sur';
    }
    if (lower.contains('maragusan') ||
        lower.contains('kopiat') ||
        lower.contains('monkayo') ||
        lower.contains('nabunturan')) {
      return 'Davao de Oro';
    }
    if (lower.contains('tagum') ||
        lower.contains('carmen') ||
        lower.contains('kapalong') ||
        lower.contains('panabo')) {
      return 'Davao del Norte';
    }
    if (lower.contains('davao city') ||
        lower.contains('eagle') ||
        lower.contains('malagos') ||
        lower.contains('eden') ||
        lower.contains('calinan') ||
        lower.contains('toril') ||
        lower.contains("people's park") ||
        lower.contains('peoples park') ||
        lower.contains('san pedro') ||
        lower.contains('poblacion') ||
        lower.contains('marilog') ||
        lower.contains('buda')) {
      return 'Davao City';
    }
    final d = district?.trim() ?? '';
    return d.isNotEmpty ? d : 'Region XI';
  }

  /// Base estimate in USD (repository formats into PHP ₱ at 57.0 default or live FX).
  int get estimatedPriceUsd {
    if (estimatedCostPhp != null && estimatedCostPhp! > 0) {
      return (estimatedCostPhp! / 57.0).round().clamp(15, 2500);
    }
    return (days * 72) + (id.hashCode.abs() % 95);
  }

  ExploreTrip copyWith({
    String? tag,
    int? days,
    double? lat,
    double? lng,
    String? thumbnailUrl,
    String? islandGroup,
    String? stayDurationType,
  }) {
    return ExploreTrip(
      locale: locale,
      id: id,
      title: title,
      days: days ?? this.days,
      lat: lat ?? this.lat,
      lng: lng ?? this.lng,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      tag: tag ?? this.tag,
      apiDestinationId: apiDestinationId,
      description: description,
      district: district,
      activities: activities,
      estimatedCostPhp: estimatedCostPhp,
      entranceFee: entranceFee,
      overnightFee: overnightFee,
      operatingHours: operatingHours,
      bestTimeToVisit: bestTimeToVisit,
      travelNotes: travelNotes,
      whatToBring: whatToBring,
      islandGroup: islandGroup ?? this.islandGroup,
      stayDurationType: stayDurationType ?? this.stayDurationType,
    );
  }

  Map<String, dynamic> toJson() => {
        'locale': locale,
        'id': id,
        'title': title,
        'days': days,
        'lat': lat,
        'lng': lng,
        'thumbnailUrl': thumbnailUrl,
        if (tag != null) 'tag': tag,
        if (apiDestinationId != null) 'apiDestinationId': apiDestinationId,
        if (description != null) 'description': description,
        if (district != null) 'district': district,
        if (activities != null) 'activities': activities,
        if (estimatedCostPhp != null) 'estimatedCostPhp': estimatedCostPhp,
        if (entranceFee != null) 'entranceFee': entranceFee,
        if (overnightFee != null) 'overnightFee': overnightFee,
        if (operatingHours != null) 'operatingHours': operatingHours,
        if (bestTimeToVisit != null) 'bestTimeToVisit': bestTimeToVisit,
        if (travelNotes != null) 'travelNotes': travelNotes,
        if (whatToBring != null) 'whatToBring': whatToBring,
        if (islandGroup != null) 'islandGroup': islandGroup,
        if (stayDurationType != null) 'stayDurationType': stayDurationType,
      };

  factory ExploreTrip.fromJson(Map<String, dynamic> json) {
    return ExploreTrip(
      locale: json['locale'] as String? ?? 'en',
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      days: (json['days'] as num?)?.toInt() ?? 1,
      lat: (json['lat'] as num?)?.toDouble() ?? 7.0731,
      lng: (json['lng'] as num?)?.toDouble() ?? 125.6128,
      thumbnailUrl: json['thumbnailUrl'] as String? ?? '',
      tag: json['tag'] as String?,
      apiDestinationId: (json['apiDestinationId'] as num?)?.toInt(),
      description: json['description'] as String?,
      district: json['district'] as String?,
      activities: json['activities'] as String?,
      estimatedCostPhp: (json['estimatedCostPhp'] as num?)?.toDouble(),
      entranceFee: json['entranceFee'] as String?,
      overnightFee: json['overnightFee'] as String?,
      operatingHours: json['operatingHours'] as String?,
      bestTimeToVisit: json['bestTimeToVisit'] as String?,
      travelNotes: json['travelNotes'] as String?,
      whatToBring: json['whatToBring'] as String?,
      islandGroup: json['islandGroup'] as String?,
      stayDurationType: json['stayDurationType'] as String?,
    );
  }
}

/// Normalizes stay duration strings across DB, CSV, and API payloads.
String normalizeStayDurationType(
  String? raw, {
  String category = '',
  String overnightFee = '',
}) {
  final text = (raw ?? '').trim().toLowerCase().replaceAll('-', '_').replaceAll(' ', '_');
  if (text == 'short' ||
      text == 'half_day' ||
      text == 'full_day' ||
      text == 'overnight' ||
      text == 'multi_day') {
    return text;
  }
  if (text.contains('short') || (raw ?? '').toLowerCase().contains('1-2 hour')) {
    return 'short';
  }
  if (text.contains('half')) return 'half_day';
  if (text.contains('full')) return 'full_day';
  if (text.contains('multi')) return 'multi_day';
  if (text.contains('overnight') || overnightFee.trim().isNotEmpty) {
    return 'overnight';
  }
  final cat = category.toLowerCase();
  if (cat.contains('museum') ||
      cat.contains('church') ||
      cat.contains('park') ||
      cat.contains('plaza') ||
      cat.contains('landmark') ||
      cat.contains('viewpoint') ||
      cat.contains('hot spring')) {
    return 'short';
  }
  if (cat.contains('beach resort') ||
      cat.contains('mountain resort') ||
      cat.contains('waterfall') ||
      cat.contains('cape')) {
    return 'full_day';
  }
  if (cat.contains('island')) return 'multi_day';
  return 'half_day';
}

/// Curated multi-place starter route in Explore that pre-fills the Trip Tray.
class SuggestedRoute {
  final String id;
  final String title;
  final List<String> destinationIds;
  final int suggestedDays;

  const SuggestedRoute({
    required this.id,
    required this.title,
    required this.destinationIds,
    required this.suggestedDays,
  });

  factory SuggestedRoute.fromJson(Map<String, dynamic> json) {
    final idsRaw = json['destination_ids'] as List<dynamic>? ??
        json['destinationIds'] as List<dynamic>? ??
        const [];
    return SuggestedRoute(
      id: (json['id'] ?? '').toString(),
      title: (json['title'] ?? 'Suggested Region XI Route').toString(),
      destinationIds: idsRaw.map((e) => e.toString()).toList(),
      suggestedDays:
          ((json['suggested_days'] ?? json['suggestedDays']) as num?)?.toInt() ??
              3,
    );
  }
}

class DiscoverySectionItem {
  final String tripId;
  final String tag;

  const DiscoverySectionItem({
    required this.tripId,
    required this.tag,
  });

  factory DiscoverySectionItem.fromJson(Map<String, dynamic> json) {
    return DiscoverySectionItem(
      tripId: json['tripId'] as String? ?? '',
      tag: json['tag'] as String? ?? '✨',
    );
  }
}

class DiscoverySection {
  final String id;
  final String title;
  final String subtitle;
  final List<DiscoverySectionItem> items;

  const DiscoverySection({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.items,
  });

  factory DiscoverySection.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'] as List<dynamic>? ?? const [];
    return DiscoverySection(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      subtitle: json['subtitle'] as String? ?? '',
      items: rawItems
          .whereType<Map<String, dynamic>>()
          .map(DiscoverySectionItem.fromJson)
          .toList(),
    );
  }
}

class CityDescription {
  final String city;
  final String country;
  final String description;
  final String? longDescription;
  final int wmoWeatherCode;

  const CityDescription({
    required this.city,
    required this.country,
    required this.description,
    this.longDescription,
    this.wmoWeatherCode = 2,
  });

  factory CityDescription.fromJson(Map<String, dynamic> json) {
    return CityDescription(
      city: json['city'] as String? ?? '',
      country: json['country'] as String? ?? '',
      description: json['description'] as String? ?? '',
    );
  }

  CityDescription copyWith({String? longDescription, int? wmoWeatherCode}) {
    return CityDescription(
      city: city,
      country: country,
      description: description,
      longDescription: longDescription ?? this.longDescription,
      wmoWeatherCode: wmoWeatherCode ?? this.wmoWeatherCode,
    );
  }
}

class OnboardingOption {
  final String id;
  final Map<String, String> labels;

  const OnboardingOption({
    required this.id,
    required this.labels,
  });

  String labelFor(String locale) => labels[locale] ?? labels['en'] ?? id;

  factory OnboardingOption.fromJson(Map<String, dynamic> json) {
    final rawLabel = json['label'] as Map<String, dynamic>? ?? const {};
    return OnboardingOption(
      id: json['id'] as String? ?? '',
      labels: rawLabel.map((k, v) => MapEntry(k, v.toString())),
    );
  }
}

class OnboardingStep {
  final String stepId;
  final String type;
  final String phaseId;
  final Map<String, String> prompts;
  final Map<String, String> ctaLabels;
  final List<OnboardingOption> options;

  const OnboardingStep({
    required this.stepId,
    required this.type,
    required this.phaseId,
    required this.prompts,
    required this.ctaLabels,
    required this.options,
  });

  String promptFor(String locale) => prompts[locale] ?? prompts['en'] ?? '';

  String ctaFor(String locale) =>
      ctaLabels[locale] ?? ctaLabels['en'] ?? 'Continue';

  factory OnboardingStep.fromJson(Map<String, dynamic> json) {
    final rawPrompt = json['prompt'] as Map<String, dynamic>? ?? const {};
    final rawCta = (json['cta'] as Map<String, dynamic>?)?['label']
            as Map<String, dynamic>? ??
        const {};
    final rawOptions = json['options'] as List<dynamic>? ?? const [];

    return OnboardingStep(
      stepId: json['stepId'] as String? ?? '',
      type: json['type'] as String? ?? 'info',
      phaseId: json['phaseId'] as String? ?? 'phase_intro',
      prompts: rawPrompt.map((k, v) => MapEntry(k, v.toString())),
      ctaLabels: rawCta.map((k, v) => MapEntry(k, v.toString())),
      options: rawOptions
          .whereType<Map<String, dynamic>>()
          .map(OnboardingOption.fromJson)
          .toList(),
    );
  }
}

class ItineraryStop {
  final String time;
  final String title;
  final String description;
  final String category; // 'sight', 'food', 'nature', 'stay'
  final double costEstimateUsd;
  final double lat;
  final double lng;
  final int? destinationId;
  final String? stayDurationType;
  final String? islandGroup;
  final int? travelFromPrevMinutes;
  final double? travelFromPrevKm;
  final TransportMode? travelFromPrevMode;
  final bool isSeaCrossingFromPrev;

  const ItineraryStop({
    required this.time,
    required this.title,
    required this.description,
    required this.category,
    this.costEstimateUsd = 0,
    required this.lat,
    required this.lng,
    this.destinationId,
    this.stayDurationType,
    this.islandGroup,
    this.travelFromPrevMinutes,
    this.travelFromPrevKm,
    this.travelFromPrevMode,
    this.isSeaCrossingFromPrev = false,
  });

  ItineraryStop copyWith({
    String? time,
    String? title,
    String? description,
    String? category,
    double? costEstimateUsd,
    double? lat,
    double? lng,
    int? destinationId,
    String? stayDurationType,
    String? islandGroup,
    int? travelFromPrevMinutes,
    double? travelFromPrevKm,
    TransportMode? travelFromPrevMode,
    bool? isSeaCrossingFromPrev,
  }) {
    return ItineraryStop(
      time: time ?? this.time,
      title: title ?? this.title,
      description: description ?? this.description,
      category: category ?? this.category,
      costEstimateUsd: costEstimateUsd ?? this.costEstimateUsd,
      lat: lat ?? this.lat,
      lng: lng ?? this.lng,
      destinationId: destinationId ?? this.destinationId,
      stayDurationType: stayDurationType ?? this.stayDurationType,
      islandGroup: islandGroup ?? this.islandGroup,
      travelFromPrevMinutes:
          travelFromPrevMinutes ?? this.travelFromPrevMinutes,
      travelFromPrevKm: travelFromPrevKm ?? this.travelFromPrevKm,
      travelFromPrevMode: travelFromPrevMode ?? this.travelFromPrevMode,
      isSeaCrossingFromPrev:
          isSeaCrossingFromPrev ?? this.isSeaCrossingFromPrev,
    );
  }

  Map<String, dynamic> toJson() => {
        'time': time,
        'title': title,
        'description': description,
        'category': category,
        'costEstimateUsd': costEstimateUsd,
        'lat': lat,
        'lng': lng,
        if (destinationId != null) 'destinationId': destinationId,
        if (stayDurationType != null) 'stayDurationType': stayDurationType,
        if (islandGroup != null) 'islandGroup': islandGroup,
        if (travelFromPrevMinutes != null)
          'travelFromPrevMinutes': travelFromPrevMinutes,
        if (travelFromPrevKm != null) 'travelFromPrevKm': travelFromPrevKm,
        if (travelFromPrevMode != null)
          'travelFromPrevMode': travelFromPrevMode!.name,
        if (isSeaCrossingFromPrev)
          'isSeaCrossingFromPrev': isSeaCrossingFromPrev,
      };

  factory ItineraryStop.fromJson(Map<String, dynamic> json) => ItineraryStop(
        time: json['time'] as String? ?? '09:00 AM',
        title: json['title'] as String? ?? '',
        description: json['description'] as String? ?? '',
        category: json['category'] as String? ?? 'sight',
        costEstimateUsd: (json['costEstimateUsd'] as num?)?.toDouble() ?? 0,
        lat: (json['lat'] as num?)?.toDouble() ?? 7.0731,
        lng: (json['lng'] as num?)?.toDouble() ?? 125.6128,
        destinationId: (json['destinationId'] as num?)?.toInt(),
        stayDurationType: json['stayDurationType'] as String?,
        islandGroup: json['islandGroup'] as String?,
        travelFromPrevMinutes: (json['travelFromPrevMinutes'] as num?)?.toInt(),
        travelFromPrevKm: (json['travelFromPrevKm'] as num?)?.toDouble(),
        travelFromPrevMode: json['travelFromPrevMode'] != null
            ? _transportModeFromName(json['travelFromPrevMode'] as String?)
            : null,
        isSeaCrossingFromPrev: json['isSeaCrossingFromPrev'] == true,
      );
}

class HotelOffer {
  final String id;
  final String name;
  final String city;
  final double rating;
  final int stars;
  final int pricePerNightUsd;
  final List<String> facilities;
  final String partnerName;
  final String imageAsset;
  final String? remoteImageUrl;
  final double lat;
  final double lng;
  final int? apiAccommodationId;

  const HotelOffer({
    required this.id,
    required this.name,
    required this.city,
    required this.rating,
    required this.stars,
    required this.pricePerNightUsd,
    required this.facilities,
    required this.partnerName,
    required this.imageAsset,
    this.remoteImageUrl,
    required this.lat,
    required this.lng,
    this.apiAccommodationId,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'city': city,
        'rating': rating,
        'stars': stars,
        'pricePerNightUsd': pricePerNightUsd,
        'facilities': facilities,
        'partnerName': partnerName,
        'imageAsset': imageAsset,
        if (remoteImageUrl != null) 'remoteImageUrl': remoteImageUrl,
        'lat': lat,
        'lng': lng,
        if (apiAccommodationId != null) 'apiAccommodationId': apiAccommodationId,
      };

  factory HotelOffer.fromJson(Map<String, dynamic> json) => HotelOffer(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        city: json['city'] as String? ?? 'Davao Region',
        rating: (json['rating'] as num?)?.toDouble() ?? 9.0,
        stars: (json['stars'] as num?)?.toInt() ?? 4,
        pricePerNightUsd: (json['pricePerNightUsd'] as num?)?.toInt() ?? 78,
        facilities: (json['facilities'] as List<dynamic>? ?? const [])
            .map((e) => e.toString())
            .toList(),
        partnerName: json['partnerName'] as String? ?? 'Lakbay+ Partner',
        imageAsset:
            json['imageAsset'] as String? ?? 'assets/home_backdrops/01-samal-island.jpg',
        remoteImageUrl: json['remoteImageUrl'] as String?,
        lat: (json['lat'] as num?)?.toDouble() ?? 7.0731,
        lng: (json['lng'] as num?)?.toDouble() ?? 125.6128,
        apiAccommodationId: (json['apiAccommodationId'] as num?)?.toInt(),
      );
}

class FlightOffer {
  final String id;
  final String airline;
  final String originCode;
  final String destinationCode;
  final String duration;
  final bool isDirect;
  final int priceRoundtripUsd;
  final String cabinClass;

  const FlightOffer({
    required this.id,
    required this.airline,
    required this.originCode,
    required this.destinationCode,
    required this.duration,
    required this.isDirect,
    required this.priceRoundtripUsd,
    this.cabinClass = 'Economy',
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'airline': airline,
        'originCode': originCode,
        'destinationCode': destinationCode,
        'duration': duration,
        'isDirect': isDirect,
        'priceRoundtripUsd': priceRoundtripUsd,
        'cabinClass': cabinClass,
      };

  factory FlightOffer.fromJson(Map<String, dynamic> json) => FlightOffer(
        id: json['id'] as String? ?? '',
        airline: json['airline'] as String? ?? 'Cebu Pacific',
        originCode: json['originCode'] as String? ?? 'MNL',
        destinationCode: json['destinationCode'] as String? ?? 'DVO',
        duration: json['duration'] as String? ?? '1h 50m',
        isDirect: json['isDirect'] as bool? ?? true,
        priceRoundtripUsd: (json['priceRoundtripUsd'] as num?)?.toInt() ?? 88,
        cabinClass: json['cabinClass'] as String? ?? 'Economy',
      );
}

class ItineraryDay {
  final int dayNumber;
  final String cityTitle;
  final String summary;
  final double lat;
  final double lng;
  final int wmoWeatherCode;
  final int tempCelsius;
  final TransportMode? transportFromPrevious;
  final String? transportDuration;
  final List<ItineraryStop> stops;
  final HotelOffer? recommendedHotel;
  final int? apiDestinationId;
  final double? visitHours;
  final double? transitHours;
  final double? totalHours;
  final bool isContinuationDay;
  final String? continuationOfTitle;
  final String? overloadWarning;

  const ItineraryDay({
    required this.dayNumber,
    required this.cityTitle,
    required this.summary,
    required this.lat,
    required this.lng,
    this.wmoWeatherCode = 2,
    this.tempCelsius = 29,
    this.transportFromPrevious,
    this.transportDuration,
    required this.stops,
    this.recommendedHotel,
    this.apiDestinationId,
    this.visitHours,
    this.transitHours,
    this.totalHours,
    this.isContinuationDay = false,
    this.continuationOfTitle,
    this.overloadWarning,
  });

  ItineraryDay copyWith({
    int? dayNumber,
    String? cityTitle,
    String? summary,
    double? lat,
    double? lng,
    List<ItineraryStop>? stops,
    int? wmoWeatherCode,
    int? tempCelsius,
    TransportMode? transportFromPrevious,
    String? transportDuration,
    double? visitHours,
    double? transitHours,
    double? totalHours,
    bool? isContinuationDay,
    String? continuationOfTitle,
    String? overloadWarning,
  }) {
    return ItineraryDay(
      dayNumber: dayNumber ?? this.dayNumber,
      cityTitle: cityTitle ?? this.cityTitle,
      summary: summary ?? this.summary,
      lat: lat ?? this.lat,
      lng: lng ?? this.lng,
      wmoWeatherCode: wmoWeatherCode ?? this.wmoWeatherCode,
      tempCelsius: tempCelsius ?? this.tempCelsius,
      transportFromPrevious:
          transportFromPrevious ?? this.transportFromPrevious,
      transportDuration: transportDuration ?? this.transportDuration,
      stops: stops ?? this.stops,
      recommendedHotel: recommendedHotel,
      apiDestinationId: apiDestinationId,
      visitHours: visitHours ?? this.visitHours,
      transitHours: transitHours ?? this.transitHours,
      totalHours: totalHours ?? this.totalHours,
      isContinuationDay: isContinuationDay ?? this.isContinuationDay,
      continuationOfTitle: continuationOfTitle ?? this.continuationOfTitle,
      overloadWarning: overloadWarning ?? this.overloadWarning,
    );
  }

  Map<String, dynamic> toJson() => {
        'dayNumber': dayNumber,
        'cityTitle': cityTitle,
        'summary': summary,
        'lat': lat,
        'lng': lng,
        'wmoWeatherCode': wmoWeatherCode,
        'tempCelsius': tempCelsius,
        if (transportFromPrevious != null)
          'transportFromPrevious': transportFromPrevious!.name,
        if (transportDuration != null) 'transportDuration': transportDuration,
        'stops': stops.map((s) => s.toJson()).toList(),
        if (recommendedHotel != null)
          'recommendedHotel': recommendedHotel!.toJson(),
        if (apiDestinationId != null) 'apiDestinationId': apiDestinationId,
        if (visitHours != null) 'visitHours': visitHours,
        if (transitHours != null) 'transitHours': transitHours,
        if (totalHours != null) 'totalHours': totalHours,
        if (isContinuationDay) 'isContinuationDay': isContinuationDay,
        if (continuationOfTitle != null)
          'continuationOfTitle': continuationOfTitle,
        if (overloadWarning != null) 'overloadWarning': overloadWarning,
      };

  factory ItineraryDay.fromJson(Map<String, dynamic> json) => ItineraryDay(
        dayNumber: (json['dayNumber'] as num?)?.toInt() ?? 1,
        cityTitle: json['cityTitle'] as String? ?? 'Day 1',
        summary: json['summary'] as String? ?? '',
        lat: (json['lat'] as num?)?.toDouble() ?? 7.0731,
        lng: (json['lng'] as num?)?.toDouble() ?? 125.6128,
        wmoWeatherCode: (json['wmoWeatherCode'] as num?)?.toInt() ?? 2,
        tempCelsius: (json['tempCelsius'] as num?)?.toInt() ?? 29,
        transportFromPrevious: json['transportFromPrevious'] != null
            ? _transportModeFromName(json['transportFromPrevious'] as String?)
            : null,
        transportDuration: json['transportDuration'] as String?,
        stops: (json['stops'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(ItineraryStop.fromJson)
            .toList(),
        recommendedHotel: json['recommendedHotel'] is Map<String, dynamic>
            ? HotelOffer.fromJson(
                json['recommendedHotel'] as Map<String, dynamic>,
              )
            : null,
        apiDestinationId: (json['apiDestinationId'] as num?)?.toInt(),
        visitHours: (json['visitHours'] as num?)?.toDouble(),
        transitHours: (json['transitHours'] as num?)?.toDouble(),
        totalHours: (json['totalHours'] as num?)?.toDouble(),
        isContinuationDay: json['isContinuationDay'] == true,
        continuationOfTitle: json['continuationOfTitle'] as String?,
        overloadWarning: json['overloadWarning'] as String?,
      );
}

class AdminTransportRate {
  final int transportationId;
  final int destinationId;
  final String vehicleType;
  final String transportMode;
  final String routeFrom;
  final String routeTo;
  final double pricePhp;
  final String? chargingUnit;
  final int? durationMinutes;
  final String? durationText;
  final String? notes;

  const AdminTransportRate({
    required this.transportationId,
    required this.destinationId,
    required this.vehicleType,
    required this.transportMode,
    required this.routeFrom,
    required this.routeTo,
    required this.pricePhp,
    this.chargingUnit,
    this.durationMinutes,
    this.durationText,
    this.notes,
  });

  factory AdminTransportRate.fromApi(Map<String, dynamic> json) =>
      AdminTransportRate(
        transportationId:
            (json['transportation_id'] as num?)?.toInt() ?? 0,
        destinationId: (json['destination_id'] as num?)?.toInt() ?? 0,
        vehicleType: (json['vehicle_type'] ?? 'Van / Shuttle').toString(),
        transportMode: (json['transport_mode'] ?? 'road').toString(),
        routeFrom: (json['route_from'] ?? 'Origin').toString(),
        routeTo: (json['route_to'] ?? 'Destination').toString(),
        pricePhp: double.tryParse((json['price'] ?? '0').toString()) ?? 0,
        chargingUnit: json['charging_unit']?.toString(),
        durationMinutes: (json['duration_minutes'] as num?)?.toInt(),
        durationText: json['duration_text']?.toString(),
        notes: json['notes']?.toString(),
      );
}

class RoutePlanOptimizationSummary {
  final String orderMethod;
  final String costSource;
  final double baselineDistanceKm;
  final double optimizedDistanceKm;
  final double distanceSavedKm;
  final double distanceSavedPercent;
  final double baselineTransitMinutes;
  final double optimizedTransitMinutes;
  final double minutesSaved;
  final String pace;
  final int suggestedDays;
  final bool roundtrip;

  const RoutePlanOptimizationSummary({
    required this.orderMethod,
    required this.costSource,
    required this.baselineDistanceKm,
    required this.optimizedDistanceKm,
    required this.distanceSavedKm,
    required this.distanceSavedPercent,
    required this.baselineTransitMinutes,
    required this.optimizedTransitMinutes,
    required this.minutesSaved,
    this.pace = 'balanced',
    this.suggestedDays = 3,
    this.roundtrip = false,
  });

  String get methodLabel => switch (orderMethod) {
        'exact_held_karp' => 'Exact Held-Karp',
        'two_opt' => 'Adaptive NN + 2-opt',
        'nearest_neighbor' => 'Nearest-Neighbor',
        _ => 'Input order',
      };

  String get sourceLabel => switch (costSource) {
        'osrm' => 'OSRM roads',
        'mapbox' => 'Mapbox roads',
        'google_routes' => 'Google roads',
        _ => 'On-device Haversine',
      };

  String get savingsHeadline {
    final base = baselineDistanceKm.toStringAsFixed(0);
    final opt = optimizedDistanceKm.toStringAsFixed(0);
    final pct = distanceSavedPercent.toStringAsFixed(0);
    if (distanceSavedKm >= 0.5 && distanceSavedPercent >= 1.0) {
      return 'Visit order optimized: $base km \u2192 $opt km (\u2212$pct%)';
    }
    return 'Route optimized: $opt km total';
  }

  Map<String, dynamic> toJson() => {
        'orderMethod': orderMethod,
        'costSource': costSource,
        'baselineDistanceKm': baselineDistanceKm,
        'optimizedDistanceKm': optimizedDistanceKm,
        'distanceSavedKm': distanceSavedKm,
        'distanceSavedPercent': distanceSavedPercent,
        'baselineTransitMinutes': baselineTransitMinutes,
        'optimizedTransitMinutes': optimizedTransitMinutes,
        'minutesSaved': minutesSaved,
        'pace': pace,
        'suggestedDays': suggestedDays,
        'roundtrip': roundtrip,
      };

  factory RoutePlanOptimizationSummary.fromJson(Map<String, dynamic> json) {
    return RoutePlanOptimizationSummary(
      orderMethod: json['orderMethod'] as String? ?? 'requested',
      costSource: json['costSource'] as String? ?? 'haversine',
      baselineDistanceKm:
          (json['baselineDistanceKm'] as num?)?.toDouble() ?? 0.0,
      optimizedDistanceKm:
          (json['optimizedDistanceKm'] as num?)?.toDouble() ?? 0.0,
      distanceSavedKm: (json['distanceSavedKm'] as num?)?.toDouble() ?? 0.0,
      distanceSavedPercent:
          (json['distanceSavedPercent'] as num?)?.toDouble() ?? 0.0,
      baselineTransitMinutes:
          (json['baselineTransitMinutes'] as num?)?.toDouble() ?? 0.0,
      optimizedTransitMinutes:
          (json['optimizedTransitMinutes'] as num?)?.toDouble() ?? 0.0,
      minutesSaved: (json['minutesSaved'] as num?)?.toDouble() ?? 0.0,
      pace: json['pace'] as String? ?? 'balanced',
      suggestedDays: (json['suggestedDays'] as num?)?.toInt() ?? 3,
      roundtrip: json['roundtrip'] == true,
    );
  }
}

class ItineraryTrip {
  final String id;
  final String title;
  final String destination;
  final int daysCount;
  final int adults;
  final int children;
  final double centerLat;
  final double centerLng;
  final String heroAsset;
  final String? remoteImageUrl;
  final String vibeTag;
  final String overviewText;
  final String bestMonths;
  final String avgTemp;
  final int wmoWeatherCode;
  final String expertName;
  final String expertAvatarAsset;
  final String expertTip;
  final List<ItineraryDay> days;
  final List<FlightOffer> flights;
  final List<HotelOffer> hotels;
  final int? backendTripId;
  final int? backendDestinationId;
  final List<int> backendDestinationIds;
  final String? whatToBring;
  final String? entranceFee;
  final String? operatingHours;
  final bool isLocalOnly;
  final List<String> advisories;
  final double? backendEstimatedCostPhp;
  final double? backendBudgetPhp;
  final int? aiGenerationRunId;
  final int? aiOptionNumber;
  final RoutePlanOptimizationSummary? optimizationSummary;
  final List<String> routeWarnings;
  final String pace;
  final bool roundtrip;
  final String? lockedFirstDestinationId;
  final List<RouteSegmentGeometry> routeSegments;
  final List<SeaCrossingInfo> seaCrossings;
  final bool isCatalogFallback;

  const ItineraryTrip({
    required this.id,
    required this.title,
    required this.destination,
    required this.daysCount,
    this.adults = 2,
    this.children = 0,
    required this.centerLat,
    required this.centerLng,
    required this.heroAsset,
    this.remoteImageUrl,
    required this.vibeTag,
    required this.overviewText,
    required this.bestMonths,
    required this.avgTemp,
    this.wmoWeatherCode = 2,
    required this.expertName,
    this.expertAvatarAsset = 'assets/experts/carla.webp',
    required this.expertTip,
    required this.days,
    required this.flights,
    required this.hotels,
    this.backendTripId,
    this.backendDestinationId,
    this.backendDestinationIds = const [],
    this.whatToBring,
    this.entranceFee,
    this.operatingHours,
    this.isLocalOnly = true,
    this.advisories = const [],
    this.backendEstimatedCostPhp,
    this.backendBudgetPhp,
    this.aiGenerationRunId,
    this.aiOptionNumber,
    this.optimizationSummary,
    this.routeWarnings = const [],
    this.pace = 'balanced',
    this.roundtrip = false,
    this.lockedFirstDestinationId,
    this.routeSegments = const [],
    this.seaCrossings = const [],
    this.isCatalogFallback = false,
  });

  int get totalEstimatedCostUsd {
    if (backendEstimatedCostPhp != null && backendEstimatedCostPhp! > 0) {
      return (backendEstimatedCostPhp! / 57.0).round().clamp(1, 999999);
    }
    final flightTotal =
        flights.isNotEmpty ? flights.first.priceRoundtripUsd * adults : 0;
    final hotelTotal = hotels.isNotEmpty && daysCount > 1
        ? hotels.first.pricePerNightUsd * (daysCount - 1).clamp(1, 30)
        : 0;
    final activityTotal = days
        .expand((d) => d.stops)
        .fold<double>(0.0, (sum, s) => sum + s.costEstimateUsd)
        .round();
    final combined = flightTotal + hotelTotal + activityTotal;
    return combined > 0 ? combined : (daysCount * 45);
  }

  List<GeoPoint> get routeWaypoints {
    final waypoints = <GeoPoint>[];
    for (final d in days) {
      if (d.isContinuationDay && d.stops.isEmpty) {
        continue;
      }
      final dayStops = d.stops.where((s) {
        if (!d.isContinuationDay) return true;
        return s.category != 'stay';
      }).toList();
      if (dayStops.isNotEmpty) {
        for (var idx = 0; idx < dayStops.length; idx++) {
          final stop = dayStops[idx];
          if (waypoints.isNotEmpty) {
            final prev = waypoints.last;
            final sameCoords = (prev.lat - stop.lat).abs() < 1e-5 &&
                (prev.lng - stop.lng).abs() < 1e-5;
            if (sameCoords && d.isContinuationDay) continue;
          }
          final label = dayStops.length == 1
              ? 'D${d.dayNumber}'
              : 'D${d.dayNumber}.${idx + 1}';
          final mode = stop.travelFromPrevMode ??
              (idx == 0
                  ? (d.transportFromPrevious ?? TransportMode.car)
                  : TransportMode.car);
          waypoints.add(
            GeoPoint(
              lat: stop.lat,
              lng: stop.lng,
              label: label,
              legMode: mode,
              dayNumber: d.dayNumber,
            ),
          );
        }
      } else if (!d.isContinuationDay) {
        waypoints.add(
          GeoPoint(
            lat: d.lat,
            lng: d.lng,
            label: 'D${d.dayNumber}',
            legMode: d.transportFromPrevious ?? TransportMode.car,
            dayNumber: d.dayNumber,
          ),
        );
      }
    }
    return waypoints;
  }

  List<int> get effectiveBackendDestinationIds {
    final ids = <int>{
      ...backendDestinationIds,
      ?backendDestinationId,
      for (final d in days) ?d.apiDestinationId,
      for (final d in days)
        for (final s in d.stops) ?s.destinationId,
    };
    return ids.toList();
  }

  ItineraryTrip copyWith({
    String? title,
    String? destination,
    int? daysCount,
    int? adults,
    int? children,
    int? backendTripId,
    List<int>? backendDestinationIds,
    List<HotelOffer>? hotels,
    List<FlightOffer>? flights,
    String? avgTemp,
    int? wmoWeatherCode,
    List<ItineraryDay>? days,
    String? whatToBring,
    bool? isLocalOnly,
    List<String>? advisories,
    double? backendEstimatedCostPhp,
    double? backendBudgetPhp,
    RoutePlanOptimizationSummary? optimizationSummary,
    List<String>? routeWarnings,
    String? pace,
    bool? roundtrip,
    String? lockedFirstDestinationId,
    List<RouteSegmentGeometry>? routeSegments,
    List<SeaCrossingInfo>? seaCrossings,
    String? expertName,
    bool? isCatalogFallback,
  }) {
    return ItineraryTrip(
      id: id,
      title: title ?? this.title,
      destination: destination ?? this.destination,
      daysCount: daysCount ?? this.daysCount,
      adults: adults ?? this.adults,
      children: children ?? this.children,
      centerLat: centerLat,
      centerLng: centerLng,
      heroAsset: heroAsset,
      remoteImageUrl: remoteImageUrl,
      vibeTag: vibeTag,
      overviewText: overviewText,
      bestMonths: bestMonths,
      avgTemp: avgTemp ?? this.avgTemp,
      wmoWeatherCode: wmoWeatherCode ?? this.wmoWeatherCode,
      expertName: expertName ?? this.expertName,
      expertAvatarAsset: expertAvatarAsset,
      expertTip: expertTip,
      days: days ?? this.days,
      flights: flights ?? this.flights,
      hotels: hotels ?? this.hotels,
      backendTripId: backendTripId ?? this.backendTripId,
      backendDestinationId: backendDestinationId,
      backendDestinationIds:
          backendDestinationIds ?? this.backendDestinationIds,
      whatToBring: whatToBring ?? this.whatToBring,
      entranceFee: entranceFee,
      operatingHours: operatingHours,
      isLocalOnly: isLocalOnly ?? this.isLocalOnly,
      advisories: advisories ?? this.advisories,
      backendEstimatedCostPhp:
          backendEstimatedCostPhp ?? this.backendEstimatedCostPhp,
      backendBudgetPhp: backendBudgetPhp ?? this.backendBudgetPhp,
      aiGenerationRunId: aiGenerationRunId,
      aiOptionNumber: aiOptionNumber,
      optimizationSummary: optimizationSummary ?? this.optimizationSummary,
      routeWarnings: routeWarnings ?? this.routeWarnings,
      pace: pace ?? this.pace,
      roundtrip: roundtrip ?? this.roundtrip,
      lockedFirstDestinationId:
          lockedFirstDestinationId ?? this.lockedFirstDestinationId,
      routeSegments: routeSegments ?? this.routeSegments,
      seaCrossings: seaCrossings ?? this.seaCrossings,
      isCatalogFallback: isCatalogFallback ?? this.isCatalogFallback,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'destination': destination,
        'daysCount': daysCount,
        'adults': adults,
        'children': children,
        'centerLat': centerLat,
        'centerLng': centerLng,
        'heroAsset': heroAsset,
        if (remoteImageUrl != null) 'remoteImageUrl': remoteImageUrl,
        'vibeTag': vibeTag,
        'overviewText': overviewText,
        'bestMonths': bestMonths,
        'avgTemp': avgTemp,
        'wmoWeatherCode': wmoWeatherCode,
        'expertName': expertName,
        'expertAvatarAsset': expertAvatarAsset,
        'expertTip': expertTip,
        'days': days.map((d) => d.toJson()).toList(),
        'flights': flights.map((f) => f.toJson()).toList(),
        'hotels': hotels.map((h) => h.toJson()).toList(),
        if (backendTripId != null) 'backendTripId': backendTripId,
        if (backendDestinationId != null)
          'backendDestinationId': backendDestinationId,
        if (backendDestinationIds.isNotEmpty)
          'backendDestinationIds': backendDestinationIds,
        if (whatToBring != null) 'whatToBring': whatToBring,
        if (entranceFee != null) 'entranceFee': entranceFee,
        if (operatingHours != null) 'operatingHours': operatingHours,
        'isLocalOnly': isLocalOnly,
        if (advisories.isNotEmpty) 'advisories': advisories,
        if (backendEstimatedCostPhp != null)
          'backendEstimatedCostPhp': backendEstimatedCostPhp,
        if (backendBudgetPhp != null) 'backendBudgetPhp': backendBudgetPhp,
        if (aiGenerationRunId != null) 'aiGenerationRunId': aiGenerationRunId,
        if (aiOptionNumber != null) 'aiOptionNumber': aiOptionNumber,
        if (optimizationSummary != null)
          'optimizationSummary': optimizationSummary!.toJson(),
        if (routeWarnings.isNotEmpty) 'routeWarnings': routeWarnings,
        if (pace != 'balanced') 'pace': pace,
        if (roundtrip) 'roundtrip': roundtrip,
        if (lockedFirstDestinationId != null)
          'lockedFirstDestinationId': lockedFirstDestinationId,
        if (routeSegments.isNotEmpty)
          'routeSegments': routeSegments.map((s) => s.toJson()).toList(),
        if (seaCrossings.isNotEmpty)
          'seaCrossings': seaCrossings.map((c) => c.toJson()).toList(),
        if (isCatalogFallback) 'isCatalogFallback': true,
      };

  factory ItineraryTrip.fromJson(Map<String, dynamic> json) => ItineraryTrip(
        id: json['id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        destination: json['destination'] as String? ?? '',
        daysCount: (json['daysCount'] as num?)?.toInt() ?? 3,
        adults: (json['adults'] as num?)?.toInt() ?? 2,
        children: (json['children'] as num?)?.toInt() ?? 0,
        centerLat: (json['centerLat'] as num?)?.toDouble() ?? 7.0731,
        centerLng: (json['centerLng'] as num?)?.toDouble() ?? 125.6128,
        heroAsset: json['heroAsset'] as String? ??
            'assets/home_backdrops/01-samal-island.jpg',
        remoteImageUrl: json['remoteImageUrl'] as String?,
        vibeTag: json['vibeTag'] as String? ?? 'Davao Region',
        overviewText: json['overviewText'] as String? ?? '',
        bestMonths: json['bestMonths'] as String? ?? 'Dec – May (Dry)',
        avgTemp: json['avgTemp'] as String? ?? '29°C / 84°F',
        wmoWeatherCode: (json['wmoWeatherCode'] as num?)?.toInt() ?? 2,
        expertName: json['expertName'] as String? ?? 'Lakbay+ AI',
        expertAvatarAsset:
            json['expertAvatarAsset'] as String? ?? 'assets/experts/carla.webp',
        expertTip: json['expertTip'] as String? ?? '',
        days: (json['days'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(ItineraryDay.fromJson)
            .toList(),
        flights: (json['flights'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(FlightOffer.fromJson)
            .toList(),
        hotels: (json['hotels'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(HotelOffer.fromJson)
            .toList(),
        backendTripId: (json['backendTripId'] as num?)?.toInt(),
        backendDestinationId: (json['backendDestinationId'] as num?)?.toInt(),
        backendDestinationIds:
            (json['backendDestinationIds'] as List<dynamic>? ?? const [])
                .whereType<num>()
                .map((n) => n.toInt())
                .toList(),
        whatToBring: json['whatToBring'] as String?,
        entranceFee: json['entranceFee'] as String?,
        operatingHours: json['operatingHours'] as String?,
        isLocalOnly: json['isLocalOnly'] as bool? ?? true,
        advisories: (json['advisories'] as List<dynamic>? ?? const [])
            .map((e) => e.toString())
            .toList(),
        backendEstimatedCostPhp:
            (json['backendEstimatedCostPhp'] as num?)?.toDouble(),
        backendBudgetPhp: (json['backendBudgetPhp'] as num?)?.toDouble(),
        aiGenerationRunId: (json['aiGenerationRunId'] as num?)?.toInt(),
        aiOptionNumber: (json['aiOptionNumber'] as num?)?.toInt(),
        optimizationSummary:
            json['optimizationSummary'] is Map<String, dynamic>
                ? RoutePlanOptimizationSummary.fromJson(
                    json['optimizationSummary'] as Map<String, dynamic>,
                  )
                : null,
        routeWarnings: (json['routeWarnings'] as List<dynamic>? ?? const [])
            .map((e) => e.toString())
            .toList(),
        pace: json['pace'] as String? ?? 'balanced',
        roundtrip: json['roundtrip'] == true,
        lockedFirstDestinationId: json['lockedFirstDestinationId'] as String?,
        routeSegments: (json['routeSegments'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(RouteSegmentGeometry.fromJson)
            .toList(),
        seaCrossings: (json['seaCrossings'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(SeaCrossingInfo.fromJson)
            .toList(),
        isCatalogFallback: json['isCatalogFallback'] == true,
      );
}

class AiItineraryOptionDraft {
  final int optionNumber;
  final String title;
  final String summary;
  final double estimatedTotalCostPhp;
  final bool isOverBudget;
  final int? generationRunId;
  final bool isCatalogFallback;
  final String? sourceLabel;
  final ItineraryTrip trip;

  const AiItineraryOptionDraft({
    required this.optionNumber,
    required this.title,
    required this.summary,
    required this.estimatedTotalCostPhp,
    required this.isOverBudget,
    this.generationRunId,
    this.isCatalogFallback = false,
    this.sourceLabel,
    required this.trip,
  });

  Map<String, dynamic> toJson() => {
        'optionNumber': optionNumber,
        'title': title,
        'summary': summary,
        'estimatedTotalCostPhp': estimatedTotalCostPhp,
        'isOverBudget': isOverBudget,
        if (generationRunId != null) 'generationRunId': generationRunId,
        if (isCatalogFallback) 'isCatalogFallback': true,
        if (sourceLabel != null) 'sourceLabel': sourceLabel,
        'trip': trip.toJson(),
      };

  factory AiItineraryOptionDraft.fromJson(Map<String, dynamic> json) =>
      AiItineraryOptionDraft(
        optionNumber: (json['optionNumber'] as num?)?.toInt() ?? 1,
        title: json['title'] as String? ?? 'Davao Option',
        summary: json['summary'] as String? ?? '',
        estimatedTotalCostPhp:
            (json['estimatedTotalCostPhp'] as num?)?.toDouble() ?? 0.0,
        isOverBudget: json['isOverBudget'] as bool? ?? false,
        generationRunId: (json['generationRunId'] as num?)?.toInt(),
        isCatalogFallback: json['isCatalogFallback'] == true,
        sourceLabel: json['sourceLabel'] as String?,
        trip: ItineraryTrip.fromJson(
          (json['trip'] as Map<String, dynamic>? ?? const {}),
        ),
      );
}

class PlanningFeedbackFinding {
  final String code;
  final String category;
  final String severity;
  final String message;

  const PlanningFeedbackFinding({
    required this.code,
    required this.category,
    required this.severity,
    required this.message,
  });

  factory PlanningFeedbackFinding.fromJson(Map<String, dynamic> json) =>
      PlanningFeedbackFinding(
        code: (json['code'] ?? '').toString(),
        category: (json['category'] ?? 'info').toString(),
        severity: (json['severity'] ?? 'info').toString(),
        message: (json['message'] ?? '').toString(),
      );
}

class ChatMessage {
  final String id;
  final bool isUser;
  final String text;
  final DateTime timestamp;
  final ItineraryTrip? attachedTrip;
  final List<AiItineraryOptionDraft> aiOptions;
  final List<TopPlaceRecommendation> recommendedPlaces;
  final List<String> suggestedReplies;

  /// A failed request shown as an error, with the message to send again.
  /// Nothing is invented to cover for a failure.
  final bool isError;
  final String? retryText;
  final String? errorCode;

  /// The detail the AI is asking for next (for example `activity_level`), so
  /// the answer buttons can show under the reply. Not saved: only the latest
  /// reply offers them.
  final String? askNext;

  /// Offer the optional "what matters most?" choice under this reply.
  final bool offerPriorities;

  const ChatMessage({
    required this.id,
    required this.isUser,
    required this.text,
    required this.timestamp,
    this.attachedTrip,
    this.aiOptions = const [],
    this.recommendedPlaces = const [],
    this.suggestedReplies = const [],
    this.isError = false,
    this.retryText,
    this.errorCode,
    this.askNext,
    this.offerPriorities = false,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'isUser': isUser,
        'text': text,
        'timestamp': timestamp.toIso8601String(),
        if (attachedTrip != null) 'attachedTrip': attachedTrip!.toJson(),
        if (aiOptions.isNotEmpty)
          'aiOptions': aiOptions.map((o) => o.toJson()).toList(),
        if (recommendedPlaces.isNotEmpty)
          'recommendedPlaces':
              recommendedPlaces.map((p) => p.toJson()).toList(),
        if (suggestedReplies.isNotEmpty) 'suggestedReplies': suggestedReplies,
        if (isError) 'isError': true,
        if (retryText != null) 'retryText': retryText,
        if (errorCode != null) 'errorCode': errorCode,
      };

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
        id: json['id'] as String? ?? '',
        isUser: json['isUser'] as bool? ?? false,
        text: json['text'] as String? ?? '',
        timestamp: DateTime.tryParse(json['timestamp'] as String? ?? '') ??
            DateTime.now(),
        attachedTrip: json['attachedTrip'] is Map<String, dynamic>
            ? ItineraryTrip.fromJson(
                json['attachedTrip'] as Map<String, dynamic>,
              )
            : null,
        aiOptions: (json['aiOptions'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(AiItineraryOptionDraft.fromJson)
            .toList(),
        recommendedPlaces:
            (json['recommendedPlaces'] as List<dynamic>? ?? const [])
                .whereType<Map<String, dynamic>>()
                .map(TopPlaceRecommendation.fromJson)
                .toList(),
        suggestedReplies:
            (json['suggestedReplies'] as List<dynamic>? ?? const [])
                .map((e) => e.toString())
                .toList(),
      );
}

class UserProfile {
  final String firstName;
  final String lastName;
  final String headline;
  final String location;
  final String email;

  /// The name other travelers use to find and invite this traveler. It is
  /// kept by the server; empty until it has been loaded or the traveler signs in.
  final String username;

  const UserProfile({
    this.firstName = '',
    this.lastName = '',
    this.headline = '',
    this.location = '',
    this.email = '',
    this.username = '',
  });

  String get fullName => '$firstName $lastName'.trim();

  String get initials {
    final parts = '$firstName $lastName'
        .trim()
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.isEmpty) return 'ME';
    return parts.take(3).map((p) => p[0].toUpperCase()).join();
  }

  UserProfile copyWith({
    String? firstName,
    String? lastName,
    String? headline,
    String? location,
    String? email,
    String? username,
  }) {
    return UserProfile(
      firstName: firstName ?? this.firstName,
      lastName: lastName ?? this.lastName,
      headline: headline ?? this.headline,
      location: location ?? this.location,
      email: email ?? this.email,
      username: username ?? this.username,
    );
  }

  Map<String, dynamic> toJson() => {
        'firstName': firstName,
        'lastName': lastName,
        'headline': headline,
        'location': location,
        'email': email,
        'username': username,
      };

  factory UserProfile.fromJson(Map<String, dynamic> json) => UserProfile(
        firstName: json['firstName'] as String? ?? '',
        lastName: json['lastName'] as String? ?? '',
        headline: json['headline'] as String? ?? '',
        location: json['location'] as String? ?? '',
        email: json['email'] as String? ?? '',
        username: json['username'] as String? ?? '',
      );
}

class ChatSession {
  final String id;
  final String title;
  final String groupLabel; // 'Today', 'Yesterday'
  final bool isTrip;
  final DateTime createdAt;
  final List<ChatMessage> messages;

  const ChatSession({
    required this.id,
    required this.title,
    required this.groupLabel,
    required this.isTrip,
    required this.createdAt,
    required this.messages,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'groupLabel': groupLabel,
        'isTrip': isTrip,
        'createdAt': createdAt.toIso8601String(),
        'messages': messages.map((m) => m.toJson()).toList(),
      };

  factory ChatSession.fromJson(Map<String, dynamic> json) => ChatSession(
        id: json['id'] as String? ?? '',
        title: json['title'] as String? ?? 'New Trip',
        groupLabel: json['groupLabel'] as String? ?? 'Today',
        isTrip: json['isTrip'] as bool? ?? false,
        createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
            DateTime.now(),
        messages: (json['messages'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(ChatMessage.fromJson)
            .toList(),
      );
}

class LakbayAuthSession {
  final String accessToken;
  final String refreshToken;
  final int userId;
  final String fullName;
  final String email;
  final String role;

  const LakbayAuthSession({
    required this.accessToken,
    required this.refreshToken,
    required this.userId,
    required this.fullName,
    required this.email,
    required this.role,
  });

  Map<String, dynamic> toJson() => {
        'accessToken': accessToken,
        'refreshToken': refreshToken,
        'userId': userId,
        'fullName': fullName,
        'email': email,
        'role': role,
      };

  factory LakbayAuthSession.fromJson(Map<String, dynamic> json) =>
      LakbayAuthSession(
        accessToken: json['accessToken'] as String? ?? '',
        refreshToken: json['refreshToken'] as String? ?? '',
        userId: (json['userId'] as num?)?.toInt() ?? 0,
        fullName: json['fullName'] as String? ?? '',
        email: json['email'] as String? ?? '',
        role: json['role'] as String? ?? 'traveler',
      );
}

class BackendRouteResult {
  final String routeProvider;
  final bool isEstimated;
  final double totalDistanceKm;
  final int totalDurationMinutes;
  final List<GeoPoint> geometryPoints;
  final List<String> warnings;
  final List<int> orderedDestinationIds;

  /// Road and sea parts in travel order (present when the trip crosses water).
  final List<RouteSegmentGeometry> segments;
  final List<SeaCrossingInfo> seaCrossings;

  const BackendRouteResult({
    required this.routeProvider,
    required this.isEstimated,
    required this.totalDistanceKm,
    required this.totalDurationMinutes,
    required this.geometryPoints,
    this.warnings = const [],
    this.orderedDestinationIds = const [],
    this.segments = const [],
    this.seaCrossings = const [],
  });
}

class BackendRoutePlanStop {
  final int? destinationId;
  final String name;
  final double lat;
  final double lng;
  final String? islandGroup;
  final String stayDurationType;
  final double visitHours;

  const BackendRoutePlanStop({
    this.destinationId,
    required this.name,
    required this.lat,
    required this.lng,
    this.islandGroup,
    required this.stayDurationType,
    required this.visitHours,
  });
}

class BackendRoutePlanDay {
  final int dayNumber;
  final List<BackendRoutePlanStop> stops;
  final double visitHours;
  final double transitHours;
  final double totalHours;
  final bool isContinuationDay;
  final String? continuationOfName;
  final bool isOverloaded;
  final String? overloadWarning;

  const BackendRoutePlanDay({
    required this.dayNumber,
    required this.stops,
    required this.visitHours,
    required this.transitHours,
    required this.totalHours,
    this.isContinuationDay = false,
    this.continuationOfName,
    this.isOverloaded = false,
    this.overloadWarning,
  });
}

class BackendRoutePlanResult {
  final RoutePlanOptimizationSummary summary;
  final List<String> warnings;
  final List<int> skippedDestinationIds;
  final List<BackendRoutePlanDay> days;
  final BackendRouteResult route;

  const BackendRoutePlanResult({
    required this.summary,
    required this.warnings,
    required this.skippedDestinationIds,
    required this.days,
    required this.route,
  });
}

/// A drawable part of a route. Road parts follow real roads unless
/// [isEstimated]; estimated parts are straight connectors drawn dashed.
class RouteSegmentGeometry {
  final TransportMode mode;
  final List<GeoPoint> points;
  final String fromName;
  final String toName;
  final bool isEstimated;

  const RouteSegmentGeometry({
    required this.mode,
    required this.points,
    required this.fromName,
    required this.toName,
    this.isEstimated = false,
  });

  bool get isSea => mode == TransportMode.ferry;

  Map<String, dynamic> toJson() => {
        'mode': mode.name,
        'points': points.map((p) => p.toJson()).toList(),
        'fromName': fromName,
        'toName': toName,
        if (isEstimated) 'isEstimated': isEstimated,
      };

  factory RouteSegmentGeometry.fromJson(Map<String, dynamic> json) =>
      RouteSegmentGeometry(
        mode: _transportModeFromName(json['mode'] as String?),
        points: (json['points'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(GeoPoint.fromJson)
            .toList(),
        fromName: json['fromName'] as String? ?? '',
        toName: json['toName'] as String? ?? '',
        isEstimated: json['isEstimated'] == true,
      );
}

/// A pier-to-pier boat ride (RoRo barge, passenger ferry or pump boat).
class SeaCrossingInfo {
  final String vesselType;
  final String boardPort;
  final String landPort;
  final double boardLat;
  final double boardLng;
  final double landLat;
  final double landLng;
  final int crossingMinutes;
  final int typicalWaitMinutes;
  final bool allowsPrivateVehicle;
  final String? scheduleText;
  final double? farePassenger;
  final double? fareVehicle;
  final bool verified;

  const SeaCrossingInfo({
    required this.vesselType,
    required this.boardPort,
    required this.landPort,
    required this.boardLat,
    required this.boardLng,
    required this.landLat,
    required this.landLng,
    required this.crossingMinutes,
    required this.typicalWaitMinutes,
    required this.allowsPrivateVehicle,
    this.scheduleText,
    this.farePassenger,
    this.fareVehicle,
    this.verified = false,
  });

  String get vesselLabel => switch (vesselType) {
        'roro_barge' => 'RoRo barge',
        'passenger_ferry' => 'Passenger ferry',
        'pump_boat' => 'Pump boat',
        _ => 'Boat',
      };

  Map<String, dynamic> toJson() => {
        'vesselType': vesselType,
        'boardPort': boardPort,
        'landPort': landPort,
        'boardLat': boardLat,
        'boardLng': boardLng,
        'landLat': landLat,
        'landLng': landLng,
        'crossingMinutes': crossingMinutes,
        'typicalWaitMinutes': typicalWaitMinutes,
        'allowsPrivateVehicle': allowsPrivateVehicle,
        if (scheduleText != null) 'scheduleText': scheduleText,
        if (farePassenger != null) 'farePassenger': farePassenger,
        if (fareVehicle != null) 'fareVehicle': fareVehicle,
        if (verified) 'verified': verified,
      };

  factory SeaCrossingInfo.fromJson(Map<String, dynamic> json) => SeaCrossingInfo(
        vesselType: json['vesselType'] as String? ?? '',
        boardPort: json['boardPort'] as String? ?? 'Pier',
        landPort: json['landPort'] as String? ?? 'Pier',
        boardLat: (json['boardLat'] as num?)?.toDouble() ?? 0,
        boardLng: (json['boardLng'] as num?)?.toDouble() ?? 0,
        landLat: (json['landLat'] as num?)?.toDouble() ?? 0,
        landLng: (json['landLng'] as num?)?.toDouble() ?? 0,
        crossingMinutes: (json['crossingMinutes'] as num?)?.toInt() ?? 0,
        typicalWaitMinutes: (json['typicalWaitMinutes'] as num?)?.toInt() ?? 0,
        allowsPrivateVehicle: json['allowsPrivateVehicle'] == true,
        scheduleText: json['scheduleText'] as String?,
        farePassenger: (json['farePassenger'] as num?)?.toDouble(),
        fareVehicle: (json['fareVehicle'] as num?)?.toDouble(),
        verified: json['verified'] == true,
      );
}

class TripMemberItem {
  final int tripMemberId;
  final int tripId;
  final int userId;
  final String fullName;
  final String? username;
  final String email;
  final String role;
  final String status;

  const TripMemberItem({
    required this.tripMemberId,
    required this.tripId,
    required this.userId,
    required this.fullName,
    this.username,
    required this.email,
    required this.role,
    required this.status,
  });

  /// Invited but has not accepted yet. Their email is hidden by the server.
  bool get isPending => status == 'invited';

  factory TripMemberItem.fromJson(Map<String, dynamic> json) => TripMemberItem(
        tripMemberId: (json['trip_member_id'] as num?)?.toInt() ?? 0,
        tripId: (json['trip_id'] as num?)?.toInt() ?? 0,
        userId: (json['user_id'] as num?)?.toInt() ?? 0,
        fullName: (json['full_name'] ?? '').toString(),
        username: json['username']?.toString(),
        email: (json['email'] ?? '').toString(),
        role: (json['role'] ?? 'member').toString(),
        status: (json['status'] ?? 'active').toString(),
      );
}

/// A trip the signed-in traveler has been invited to and has not answered.
class TripInvitationItem {
  final int tripMemberId;
  final int tripId;
  final String tripTitle;
  final String invitedByName;
  final String role;

  const TripInvitationItem({
    required this.tripMemberId,
    required this.tripId,
    required this.tripTitle,
    required this.invitedByName,
    required this.role,
  });

  factory TripInvitationItem.fromJson(Map<String, dynamic> json) =>
      TripInvitationItem(
        tripMemberId: (json['trip_member_id'] as num?)?.toInt() ?? 0,
        tripId: (json['trip_id'] as num?)?.toInt() ?? 0,
        tripTitle: (json['trip_title'] ?? '').toString(),
        invitedByName: (json['invited_by_name'] ?? '').toString(),
        role: (json['role'] ?? 'member').toString(),
      );
}

/// Another traveler found while inviting (never includes an email).
class UserSearchItem {
  final int userId;
  final String username;
  final String fullName;

  const UserSearchItem({
    required this.userId,
    required this.username,
    required this.fullName,
  });

  factory UserSearchItem.fromJson(Map<String, dynamic> json) => UserSearchItem(
        userId: (json['user_id'] as num?)?.toInt() ?? 0,
        username: (json['username'] ?? '').toString(),
        fullName: (json['full_name'] ?? '').toString(),
      );
}

class TripTaskItem {
  final int tripTaskId;
  final int tripId;
  final int? assignedTripMemberId;
  final String title;
  final String? description;
  final String status; // pending | in_progress | completed
  final DateTime? dueDate;

  const TripTaskItem({
    required this.tripTaskId,
    required this.tripId,
    this.assignedTripMemberId,
    required this.title,
    this.description,
    required this.status,
    this.dueDate,
  });

  factory TripTaskItem.fromJson(Map<String, dynamic> json) => TripTaskItem(
        tripTaskId: (json['trip_task_id'] as num?)?.toInt() ?? 0,
        tripId: (json['trip_id'] as num?)?.toInt() ?? 0,
        assignedTripMemberId: (json['assigned_trip_member_id'] as num?)?.toInt(),
        title: (json['title'] ?? '').toString(),
        description: json['description']?.toString(),
        status: (json['status'] ?? 'pending').toString(),
        dueDate: DateTime.tryParse(json['due_date']?.toString() ?? ''),
      );
}

class TripExpenseItem {
  final int tripExpenseId;
  final int tripId;
  final int paidByTripMemberId;
  final String paidByFullName;
  final String category;
  final String title;
  final double amount;
  final DateTime expenseDate;
  final String? notes;
  final String status;

  const TripExpenseItem({
    required this.tripExpenseId,
    required this.tripId,
    required this.paidByTripMemberId,
    required this.paidByFullName,
    required this.category,
    required this.title,
    required this.amount,
    required this.expenseDate,
    this.notes,
    required this.status,
  });

  factory TripExpenseItem.fromJson(Map<String, dynamic> json) =>
      TripExpenseItem(
        tripExpenseId: (json['trip_expense_id'] as num?)?.toInt() ?? 0,
        tripId: (json['trip_id'] as num?)?.toInt() ?? 0,
        paidByTripMemberId:
            (json['paid_by_trip_member_id'] as num?)?.toInt() ?? 0,
        paidByFullName: (json['paid_by_full_name'] ?? 'Traveler').toString(),
        category: (json['category'] ?? 'other').toString(),
        title: (json['title'] ?? '').toString(),
        amount: _parseDoubleModel(json['amount']),
        expenseDate:
            DateTime.tryParse(json['expense_date']?.toString() ?? '') ??
                DateTime.now(),
        notes: json['notes']?.toString(),
        status: (json['status'] ?? 'active').toString(),
      );
}

class TripExpenseCategoryTotal {
  final String category;
  final double total;

  const TripExpenseCategoryTotal({
    required this.category,
    required this.total,
  });

  factory TripExpenseCategoryTotal.fromJson(Map<String, dynamic> json) =>
      TripExpenseCategoryTotal(
        category: (json['category'] ?? 'other').toString(),
        total: _parseDoubleModel(json['total']),
      );
}

class TripExpenseMemberBalance {
  final int tripMemberId;
  final int userId;
  final String fullName;
  final double paidTotal;
  final double shareTotal;
  final double netBalance;

  const TripExpenseMemberBalance({
    required this.tripMemberId,
    required this.userId,
    required this.fullName,
    required this.paidTotal,
    required this.shareTotal,
    required this.netBalance,
  });

  factory TripExpenseMemberBalance.fromJson(Map<String, dynamic> json) =>
      TripExpenseMemberBalance(
        tripMemberId: (json['trip_member_id'] as num?)?.toInt() ?? 0,
        userId: (json['user_id'] as num?)?.toInt() ?? 0,
        fullName: (json['full_name'] ?? '').toString(),
        paidTotal: _parseDoubleModel(json['paid_total']),
        shareTotal: _parseDoubleModel(json['share_total']),
        netBalance: _parseDoubleModel(json['net_balance']),
      );
}

class TripExpenseSummary {
  final int tripId;
  final double totalBudget;
  final double totalSpent;
  final double remainingBudget;
  final double overBudgetAmount;
  final bool isOverBudget;
  final double percentUsed;
  final String budgetAlertLevel; // ok | warning_80 | exceeded
  final int adultCount;
  final int childCount;
  final double adultShare;
  final double childShare;
  final List<TripExpenseCategoryTotal> categoryBreakdown;
  final List<TripExpenseMemberBalance> memberBalances;

  const TripExpenseSummary({
    required this.tripId,
    required this.totalBudget,
    required this.totalSpent,
    required this.remainingBudget,
    required this.overBudgetAmount,
    required this.isOverBudget,
    required this.percentUsed,
    required this.budgetAlertLevel,
    required this.adultCount,
    required this.childCount,
    required this.adultShare,
    required this.childShare,
    required this.categoryBreakdown,
    required this.memberBalances,
  });

  factory TripExpenseSummary.fromJson(Map<String, dynamic> json) =>
      TripExpenseSummary(
        tripId: (json['trip_id'] as num?)?.toInt() ?? 0,
        totalBudget: _parseDoubleModel(json['total_budget']),
        totalSpent: _parseDoubleModel(json['total_spent']),
        remainingBudget: _parseDoubleModel(json['remaining_budget']),
        overBudgetAmount: _parseDoubleModel(json['over_budget_amount']),
        isOverBudget: json['is_over_budget'] == true,
        percentUsed: _parseDoubleModel(json['percent_used']),
        budgetAlertLevel: (json['budget_alert_level'] ?? 'ok').toString(),
        adultCount: (json['adult_count'] as num?)?.toInt() ?? 1,
        childCount: (json['child_count'] as num?)?.toInt() ?? 0,
        adultShare: _parseDoubleModel(json['adult_share']),
        childShare: _parseDoubleModel(json['child_share']),
        categoryBreakdown:
            (json['category_breakdown'] as List<dynamic>? ?? const [])
                .whereType<Map<String, dynamic>>()
                .map(TripExpenseCategoryTotal.fromJson)
                .toList(),
        memberBalances:
            (json['member_balances'] as List<dynamic>? ?? const [])
                .whereType<Map<String, dynamic>>()
                .map(TripExpenseMemberBalance.fromJson)
                .toList(),
      );
}

class TripMemoryItem {
  final int tripMemoryId;
  final int tripId;
  final String uploadedByFullName;
  final int? destinationId;
  final String? destinationName;
  final String imageUrl;
  final String? localFilePath;
  final String? caption;
  final String? locationTag;
  final int likeCount;
  final int commentCount;
  final DateTime createdAt;

  const TripMemoryItem({
    required this.tripMemoryId,
    required this.tripId,
    required this.uploadedByFullName,
    this.destinationId,
    this.destinationName,
    required this.imageUrl,
    this.localFilePath,
    this.caption,
    this.locationTag,
    this.likeCount = 0,
    this.commentCount = 0,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
        'trip_memory_id': tripMemoryId,
        'trip_id': tripId,
        'uploaded_by_full_name': uploadedByFullName,
        if (destinationId != null) 'destination_id': destinationId,
        if (destinationName != null) 'destination_name': destinationName,
        'image_url': imageUrl,
        if (localFilePath != null) 'local_file_path': localFilePath,
        if (caption != null) 'caption': caption,
        if (locationTag != null) 'location_tag': locationTag,
        'like_count': likeCount,
        'comment_count': commentCount,
        'created_at': createdAt.toIso8601String(),
      };

  factory TripMemoryItem.fromJson(Map<String, dynamic> json) => TripMemoryItem(
        tripMemoryId: (json['trip_memory_id'] as num?)?.toInt() ?? 0,
        tripId: (json['trip_id'] as num?)?.toInt() ?? 0,
        uploadedByFullName:
            (json['uploaded_by_full_name'] ?? 'Traveler').toString(),
        destinationId: (json['destination_id'] as num?)?.toInt(),
        destinationName: json['destination_name']?.toString(),
        imageUrl: (json['image_url'] ?? '').toString(),
        localFilePath: json['local_file_path']?.toString(),
        caption: json['caption']?.toString(),
        locationTag: json['location_tag']?.toString(),
        likeCount: (json['like_count'] as num?)?.toInt() ?? 0,
        commentCount: (json['comment_count'] as num?)?.toInt() ?? 0,
        createdAt: DateTime.tryParse(json['created_at']?.toString() ?? '') ??
            DateTime.now(),
      );
}

class AppNotificationItem {
  final int notificationId;
  final int? tripId;
  final String? tripTitle;
  final String eventType;
  final String title;
  final String message;
  final bool isRead;
  final DateTime createdAt;

  const AppNotificationItem({
    required this.notificationId,
    this.tripId,
    this.tripTitle,
    required this.eventType,
    required this.title,
    required this.message,
    required this.isRead,
    required this.createdAt,
  });

  AppNotificationItem copyWith({bool? isRead}) => AppNotificationItem(
        notificationId: notificationId,
        tripId: tripId,
        tripTitle: tripTitle,
        eventType: eventType,
        title: title,
        message: message,
        isRead: isRead ?? this.isRead,
        createdAt: createdAt,
      );

  factory AppNotificationItem.fromJson(Map<String, dynamic> json) =>
      AppNotificationItem(
        notificationId: (json['notification_id'] as num?)?.toInt() ?? 0,
        tripId: (json['trip_id'] as num?)?.toInt(),
        tripTitle: json['trip_title']?.toString(),
        eventType: (json['event_type'] ?? '').toString(),
        title: (json['title'] ?? '').toString(),
        message: (json['message'] ?? '').toString(),
        isRead: json['is_read'] == true,
        createdAt: DateTime.tryParse(json['created_at']?.toString() ?? '') ??
            DateTime.now(),
      );
}

class TripReviewItem {
  final int tripReviewId;
  final int tripId;
  final String fullName;
  final int postTripRating;
  final int accuracyRating;
  final int routeEfficiencyRating;
  final int budgetAdherenceRating;
  final int overallExperienceRating;
  final String? comments;
  final DateTime createdAt;

  const TripReviewItem({
    required this.tripReviewId,
    required this.tripId,
    required this.fullName,
    required this.postTripRating,
    required this.accuracyRating,
    required this.routeEfficiencyRating,
    required this.budgetAdherenceRating,
    required this.overallExperienceRating,
    this.comments,
    required this.createdAt,
  });

  factory TripReviewItem.fromJson(Map<String, dynamic> json) => TripReviewItem(
        tripReviewId: (json['trip_review_id'] as num?)?.toInt() ?? 0,
        tripId: (json['trip_id'] as num?)?.toInt() ?? 0,
        fullName: (json['full_name'] ?? 'Traveler').toString(),
        postTripRating: (json['post_trip_rating'] as num?)?.toInt() ?? 5,
        accuracyRating: (json['accuracy_rating'] as num?)?.toInt() ?? 5,
        routeEfficiencyRating:
            (json['route_efficiency_rating'] as num?)?.toInt() ?? 5,
        budgetAdherenceRating:
            (json['budget_adherence_rating'] as num?)?.toInt() ?? 5,
        overallExperienceRating:
            (json['overall_experience_rating'] as num?)?.toInt() ?? 5,
        comments: json['comments']?.toString(),
        createdAt: DateTime.tryParse(json['created_at']?.toString() ?? '') ??
            DateTime.now(),
      );
}

class AppAssessmentData {
  final int? functionalSuitabilityRating;
  final int? informationAccuracyRating;
  final int? performanceRating;
  final int? interactionRating;
  final int? reliabilityRating;
  final int? sharingClarityRating;
  final String? comment;

  const AppAssessmentData({
    this.functionalSuitabilityRating,
    this.informationAccuracyRating,
    this.performanceRating,
    this.interactionRating,
    this.reliabilityRating,
    this.sharingClarityRating,
    this.comment,
  });

  factory AppAssessmentData.fromJson(Map<String, dynamic> json) =>
      AppAssessmentData(
        functionalSuitabilityRating:
            (json['functional_suitability_rating'] as num?)?.toInt(),
        informationAccuracyRating:
            (json['information_accuracy_rating'] as num?)?.toInt(),
        performanceRating: (json['performance_rating'] as num?)?.toInt(),
        interactionRating: (json['interaction_rating'] as num?)?.toInt(),
        reliabilityRating: (json['reliability_rating'] as num?)?.toInt(),
        sharingClarityRating:
            (json['sharing_clarity_rating'] as num?)?.toInt(),
        comment: json['comment']?.toString(),
      );
}

/// A preference the traveler can choose (for example "Nature attractions"),
/// served by the API from `GET /destinations/facets`. Nothing about which
/// preferences exist is typed into the app.
class PreferenceGroup {
  final String key;
  final String label;
  final String description;
  final int count;
  final List<PreferenceSubtype> subtypes;

  const PreferenceGroup({
    required this.key,
    required this.label,
    this.description = '',
    this.count = 0,
    this.subtypes = const [],
  });

  factory PreferenceGroup.fromJson(Map<String, dynamic> json) =>
      PreferenceGroup(
        key: (json['key'] ?? '').toString(),
        label: (json['label'] ?? '').toString(),
        description: (json['description'] ?? '').toString(),
        count: (json['count'] as num?)?.toInt() ?? 0,
        subtypes: (json['subtypes'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(PreferenceSubtype.fromJson)
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        'key': key,
        'label': label,
        'description': description,
        'count': count,
        'subtypes': subtypes.map((s) => s.toJson()).toList(),
      };
}

class PreferenceSubtype {
  final String key;
  final String label;
  final int count;

  const PreferenceSubtype({
    required this.key,
    required this.label,
    this.count = 0,
  });

  factory PreferenceSubtype.fromJson(Map<String, dynamic> json) =>
      PreferenceSubtype(
        key: (json['key'] ?? '').toString(),
        label: (json['label'] ?? '').toString(),
        count: (json['count'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => {'key': key, 'label': label, 'count': count};
}

class CategoryFacet {
  final String key;
  final String label;
  final int count;
  final String group;
  final List<String> groups;
  final List<String> examples;

  const CategoryFacet({
    required this.key,
    required this.label,
    this.count = 0,
    this.group = 'other',
    this.groups = const [],
    this.examples = const [],
  });

  factory CategoryFacet.fromJson(Map<String, dynamic> json) => CategoryFacet(
        key: (json['key'] ?? '').toString(),
        label: (json['label'] ?? '').toString(),
        count: (json['count'] as num?)?.toInt() ?? 0,
        group: (json['group'] ?? 'other').toString(),
        groups: (json['groups'] as List<dynamic>? ?? const [])
            .map((e) => e.toString())
            .toList(),
        examples: (json['examples'] as List<dynamic>? ?? const [])
            .map((e) => e.toString())
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        'key': key,
        'label': label,
        'count': count,
        'group': group,
        if (groups.isNotEmpty) 'groups': groups,
        if (examples.isNotEmpty) 'examples': examples,
      };
}

class TopPlaceRecommendation {
  final int rank;
  final int destinationId;
  final String name;
  final String? district;
  final String? category;
  final String? imageUrl;
  final double? estimatedCost;
  final double score;
  final List<String> reasons;
  final bool routeVerified;
  final String travelMode;
  final int? travelMinutes;
  final double? travelDistanceKm;

  /// The place's pin, from the server, so a card never needs a guessed location.
  final double? lat;
  final double? lng;

  /// 1 fits every limit; 2 or 3 relax a limit (the first reasons say which).
  final int matchTier;

  const TopPlaceRecommendation({
    required this.rank,
    required this.destinationId,
    required this.name,
    this.district,
    this.category,
    this.imageUrl,
    this.estimatedCost,
    required this.score,
    this.reasons = const [],
    required this.routeVerified,
    required this.travelMode,
    this.travelMinutes,
    this.travelDistanceKm,
    this.lat,
    this.lng,
    this.matchTier = 1,
  });

  String get fallbackAssetPath =>
      davaoBackdropAssetFor('$name ${district ?? ''} ${category ?? ''}');

  Map<String, dynamic> toJson() => {
        'rank': rank,
        'destination_id': destinationId,
        'name': name,
        if (district != null) 'district': district,
        if (category != null) 'category': category,
        if (imageUrl != null) 'image_url': imageUrl,
        if (estimatedCost != null) 'estimated_cost': estimatedCost,
        'score': score,
        'reasons': reasons,
        'route_verified': routeVerified,
        'travel_mode': travelMode,
        if (travelMinutes != null) 'travel_minutes': travelMinutes,
        if (travelDistanceKm != null) 'travel_distance_km': travelDistanceKm,
        if (lat != null) 'lat': lat,
        if (lng != null) 'lng': lng,
        if (matchTier != 1) 'match_tier': matchTier,
      };

  factory TopPlaceRecommendation.fromJson(Map<String, dynamic> json) {
    final minutes = json['travel_minutes'] ?? json['route_duration_minutes'];
    final distanceKm = json['travel_distance_km'] ?? json['route_distance_km'];
    return TopPlaceRecommendation(
      rank: (json['rank'] as num?)?.toInt() ?? 0,
      destinationId: (json['destination_id'] as num?)?.toInt() ?? 0,
      name: (json['name'] ?? '').toString(),
      district: json['district']?.toString(),
      category: json['category']?.toString(),
      imageUrl: json['image_url']?.toString(),
      estimatedCost: json['estimated_cost'] == null
          ? null
          : _parseDoubleModel(json['estimated_cost']),
      score: _parseDoubleModel(json['score']),
      reasons: (json['reasons'] as List<dynamic>? ?? const [])
          .map((e) => e.toString())
          .toList(),
      routeVerified: json['route_verified'] == true,
      travelMode: (json['travel_mode'] ?? 'driving').toString(),
      travelMinutes: (minutes as num?)?.toInt(),
      travelDistanceKm:
          distanceKm == null ? null : _parseDoubleModel(distanceKm),
      lat: (json['lat'] as num?)?.toDouble(),
      lng: (json['lng'] as num?)?.toDouble(),
      matchTier: (json['match_tier'] as num?)?.toInt() ?? 1,
    );
  }
}

class TopPlacesResult {
  final String method;
  final List<TopPlaceRecommendation> items;
  final List<String> warnings;

  const TopPlacesResult({
    required this.method,
    required this.items,
    this.warnings = const [],
  });

  factory TopPlacesResult.fromJson(Map<String, dynamic> json) =>
      TopPlacesResult(
        method: (json['method'] ?? 'simple_additive_weighting').toString(),
        items: (json['items'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(TopPlaceRecommendation.fromJson)
            .toList(),
        warnings: (json['warnings'] as List<dynamic>? ?? const [])
            .map((e) => e.toString())
            .toList(),
      );
}

String davaoBackdropAssetFor(String seed) {
  final lower = seed.toLowerCase();
  if (lower.contains('samal') ||
      lower.contains('talikud') ||
      lower.contains('vanishing') ||
      lower.contains('coral')) {
    return 'assets/home_backdrops/01-samal-island.jpg';
  }
  if (lower.contains('mati') ||
      lower.contains('dahican') ||
      lower.contains('pujada') ||
      lower.contains('sleeping dinosaur')) {
    return 'assets/home_backdrops/02-dahican-mati.jpg';
  }
  if (lower.contains('apo') ||
      lower.contains('kapatagan') ||
      lower.contains('digos') ||
      lower.contains('bansalan')) {
    return 'assets/home_backdrops/03-mount-apo.jpg';
  }
  if (lower.contains('eden') ||
      lower.contains('toril') ||
      lower.contains('nature park')) {
    return 'assets/home_backdrops/04-eden-toril.jpg';
  }
  if (lower.contains('aliwagwag') ||
      lower.contains('falls') ||
      lower.contains('cateel') ||
      lower.contains('hagimit')) {
    return 'assets/home_backdrops/05-aliwagwag-falls.jpg';
  }
  if (lower.contains('cape san agustin') ||
      lower.contains('gov. generoso') ||
      lower.contains('san victor')) {
    return 'assets/home_backdrops/06-cape-san-agustin.jpg';
  }
  if (lower.contains('eagle') ||
      lower.contains('malagos') ||
      lower.contains('calinan')) {
    return 'assets/home_backdrops/07-malagos-eagle.jpg';
  }
  if (lower.contains('maragusan') ||
      lower.contains('sea of clouds') ||
      lower.contains('davao de oro') ||
      lower.contains('monkayo')) {
    return 'assets/home_backdrops/10-calamba-clouds.jpg';
  }
  if (lower.contains('marilog') ||
      lower.contains('buda') ||
      lower.contains('bemwa') ||
      lower.contains('hills')) {
    return 'assets/home_backdrops/09-marilog-bemwa.jpg';
  }
  return 'assets/home_backdrops/08-peoples-park.jpg';
}

double _parseDoubleModel(dynamic value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? 0.0;
  return 0.0;
}
