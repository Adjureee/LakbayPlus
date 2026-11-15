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

  const GeoPoint({
    required this.lat,
    required this.lng,
    this.label,
    this.legMode = TransportMode.car,
  });

  Map<String, dynamic> toJson() => {
        'lat': lat,
        'lng': lng,
        if (label != null) 'label': label,
        'legMode': legMode.name,
      };

  factory GeoPoint.fromJson(Map<String, dynamic> json) => GeoPoint(
        lat: (json['lat'] as num?)?.toDouble() ?? 7.0731,
        lng: (json['lng'] as num?)?.toDouble() ?? 125.6128,
        label: json['label'] as String?,
        legMode: _transportModeFromName(json['legMode'] as String?),
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
      id: json['id'] as String? ?? '01-zakynthos',
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

  const ExploreTrip({
    required this.locale,
    required this.id,
    required this.title,
    required this.days,
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
  });

  bool get isApiBacked => apiDestinationId != null || id.startsWith('api_');

  bool get hasRemoteThumbnail =>
      thumbnailUrl.startsWith('http://') || thumbnailUrl.startsWith('https://');

  String get localAssetPath => 'assets/explore/trip_images/$id.png';

  String get regionName {
    final lower = '${title.toLowerCase()} ${(district ?? '').toLowerCase()}';
    if (lower.contains('samal') ||
        lower.contains('talikud') ||
        lower.contains('pearl farm')) {
      return 'Samal (IGaCoS)';
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
    if (lower.contains('balut') || lower.contains('sarangani')) {
      return 'Davao Occidental';
    }
    if (lower.contains('tagum') ||
        lower.contains('carmen') ||
        lower.contains('kapalong') ||
        lower.contains('panabo')) {
      return 'Davao del Norte';
    }
    return 'Davao City';
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
      };

  factory ExploreTrip.fromJson(Map<String, dynamic> json) {
    return ExploreTrip(
      locale: json['locale'] as String? ?? 'en',
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      days: (json['days'] as num?)?.toInt() ?? 2,
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

  const ItineraryStop({
    required this.time,
    required this.title,
    required this.description,
    required this.category,
    this.costEstimateUsd = 0,
    required this.lat,
    required this.lng,
  });

  Map<String, dynamic> toJson() => {
        'time': time,
        'title': title,
        'description': description,
        'category': category,
        'costEstimateUsd': costEstimateUsd,
        'lat': lat,
        'lng': lng,
      };

  factory ItineraryStop.fromJson(Map<String, dynamic> json) => ItineraryStop(
        time: json['time'] as String? ?? '09:00 AM',
        title: json['title'] as String? ?? '',
        description: json['description'] as String? ?? '',
        category: json['category'] as String? ?? 'sight',
        costEstimateUsd: (json['costEstimateUsd'] as num?)?.toDouble() ?? 0,
        lat: (json['lat'] as num?)?.toDouble() ?? 7.0731,
        lng: (json['lng'] as num?)?.toDouble() ?? 125.6128,
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
            json['imageAsset'] as String? ?? 'assets/home_backdrops/04-thoddoo.jpg',
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
  });

  ItineraryDay copyWith({
    int? dayNumber,
    List<ItineraryStop>? stops,
    int? wmoWeatherCode,
    int? tempCelsius,
  }) {
    return ItineraryDay(
      dayNumber: dayNumber ?? this.dayNumber,
      cityTitle: cityTitle,
      summary: summary,
      lat: lat,
      lng: lng,
      wmoWeatherCode: wmoWeatherCode ?? this.wmoWeatherCode,
      tempCelsius: tempCelsius ?? this.tempCelsius,
      transportFromPrevious: transportFromPrevious,
      transportDuration: transportDuration,
      stops: stops ?? this.stops,
      recommendedHotel: recommendedHotel,
      apiDestinationId: apiDestinationId,
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
        routeFrom: (json['route_from'] ?? 'Davao City').toString(),
        routeTo: (json['route_to'] ?? 'Destination').toString(),
        pricePhp: double.tryParse((json['price'] ?? '0').toString()) ?? 0,
        chargingUnit: json['charging_unit']?.toString(),
        durationMinutes: (json['duration_minutes'] as num?)?.toInt(),
        durationText: json['duration_text']?.toString(),
        notes: json['notes']?.toString(),
      );
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
  });

  int get totalEstimatedCostUsd {
    final flightTotal =
        flights.isNotEmpty ? flights.first.priceRoundtripUsd * adults : 160;
    final hotelTotal = hotels.isNotEmpty
        ? hotels.first.pricePerNightUsd * (daysCount - 1).clamp(1, 30)
        : daysCount * 65;
    return flightTotal + hotelTotal;
  }

  List<GeoPoint> get routeWaypoints => days
      .map(
        (d) => GeoPoint(
          lat: d.lat,
          lng: d.lng,
          label: 'D${d.dayNumber}',
          legMode: d.transportFromPrevious ?? TransportMode.car,
        ),
      )
      .toList();

  List<int> get effectiveBackendDestinationIds {
    final ids = <int>{
      ...backendDestinationIds,
      ?backendDestinationId,
      for (final d in days) ?d.apiDestinationId,
    };
    return ids.toList();
  }

  ItineraryTrip copyWith({
    int? backendTripId,
    List<HotelOffer>? hotels,
    List<FlightOffer>? flights,
    String? avgTemp,
    int? wmoWeatherCode,
    List<ItineraryDay>? days,
  }) {
    return ItineraryTrip(
      id: id,
      title: title,
      destination: destination,
      daysCount: daysCount,
      adults: adults,
      children: children,
      centerLat: centerLat,
      centerLng: centerLng,
      heroAsset: heroAsset,
      remoteImageUrl: remoteImageUrl,
      vibeTag: vibeTag,
      overviewText: overviewText,
      bestMonths: bestMonths,
      avgTemp: avgTemp ?? this.avgTemp,
      wmoWeatherCode: wmoWeatherCode ?? this.wmoWeatherCode,
      expertName: expertName,
      expertAvatarAsset: expertAvatarAsset,
      expertTip: expertTip,
      days: days ?? this.days,
      flights: flights ?? this.flights,
      hotels: hotels ?? this.hotels,
      backendTripId: backendTripId ?? this.backendTripId,
      backendDestinationId: backendDestinationId,
      backendDestinationIds: backendDestinationIds,
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
            'assets/home_backdrops/04-thoddoo.jpg',
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
      );
}

class BasketItem {
  final String id;
  final String title;
  final String subtitle;
  final String category; // 'Flight', 'Hotel', 'Experience', 'Car Rental'
  final int priceUsd;
  final String imageAsset;
  final String? remoteImageUrl;
  final int? backendDestinationId;

  const BasketItem({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.category,
    required this.priceUsd,
    required this.imageAsset,
    this.remoteImageUrl,
    this.backendDestinationId,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'subtitle': subtitle,
        'category': category,
        'priceUsd': priceUsd,
        'imageAsset': imageAsset,
        if (remoteImageUrl != null) 'remoteImageUrl': remoteImageUrl,
        if (backendDestinationId != null)
          'backendDestinationId': backendDestinationId,
      };

  factory BasketItem.fromJson(Map<String, dynamic> json) => BasketItem(
        id: json['id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        subtitle: json['subtitle'] as String? ?? '',
        category: json['category'] as String? ?? 'Experience',
        priceUsd: (json['priceUsd'] as num?)?.toInt() ?? 0,
        imageAsset:
            json['imageAsset'] as String? ?? 'assets/home_backdrops/04-thoddoo.jpg',
        remoteImageUrl: json['remoteImageUrl'] as String?,
        backendDestinationId: (json['backendDestinationId'] as num?)?.toInt(),
      );
}

class BookedReservation {
  final String id;
  final String summaryTitle;
  final String itemsSummary;
  final int totalUsd;
  final String paymentMethod;
  final String bookedAtIso;
  final int? backendTripId;
  final bool syncedToCloud;

  const BookedReservation({
    required this.id,
    required this.summaryTitle,
    required this.itemsSummary,
    required this.totalUsd,
    required this.paymentMethod,
    required this.bookedAtIso,
    this.backendTripId,
    this.syncedToCloud = false,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'summaryTitle': summaryTitle,
        'itemsSummary': itemsSummary,
        'totalUsd': totalUsd,
        'paymentMethod': paymentMethod,
        'bookedAtIso': bookedAtIso,
        if (backendTripId != null) 'backendTripId': backendTripId,
        'syncedToCloud': syncedToCloud,
      };

  factory BookedReservation.fromJson(Map<String, dynamic> json) =>
      BookedReservation(
        id: json['id'] as String? ?? '',
        summaryTitle: json['summaryTitle'] as String? ?? 'Davao Reservation',
        itemsSummary: json['itemsSummary'] as String? ?? '',
        totalUsd: (json['totalUsd'] as num?)?.toInt() ?? 0,
        paymentMethod: json['paymentMethod'] as String? ?? 'shop_pay',
        bookedAtIso:
            json['bookedAtIso'] as String? ?? DateTime.now().toIso8601String(),
        backendTripId: (json['backendTripId'] as num?)?.toInt(),
        syncedToCloud: json['syncedToCloud'] as bool? ?? false,
      );
}

class ChatMessage {
  final String id;
  final bool isUser;
  final String text;
  final DateTime timestamp;
  final ItineraryTrip? attachedTrip;
  final List<String> suggestedReplies;

  const ChatMessage({
    required this.id,
    required this.isUser,
    required this.text,
    required this.timestamp,
    this.attachedTrip,
    this.suggestedReplies = const [],
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'isUser': isUser,
        'text': text,
        'timestamp': timestamp.toIso8601String(),
        if (attachedTrip != null) 'attachedTrip': attachedTrip!.toJson(),
        if (suggestedReplies.isNotEmpty) 'suggestedReplies': suggestedReplies,
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

  const UserProfile({
    this.firstName = 'John',
    this.lastName = 'Lyold Lozada',
    this.headline = '',
    this.location = 'Davao City, Philippines',
    this.email = 'traveler@lakbay.ph',
  });

  String get initials {
    final parts = '$firstName $lastName'
        .trim()
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.isEmpty) return 'LK';
    return parts.take(3).map((p) => p[0].toUpperCase()).join();
  }

  UserProfile copyWith({
    String? firstName,
    String? lastName,
    String? headline,
    String? location,
    String? email,
  }) {
    return UserProfile(
      firstName: firstName ?? this.firstName,
      lastName: lastName ?? this.lastName,
      headline: headline ?? this.headline,
      location: location ?? this.location,
      email: email ?? this.email,
    );
  }

  Map<String, dynamic> toJson() => {
        'firstName': firstName,
        'lastName': lastName,
        'headline': headline,
        'location': location,
        'email': email,
      };

  factory UserProfile.fromJson(Map<String, dynamic> json) => UserProfile(
        firstName: json['firstName'] as String? ?? 'John',
        lastName: json['lastName'] as String? ?? 'Lyold Lozada',
        headline: json['headline'] as String? ?? '',
        location: json['location'] as String? ?? 'Davao City, Philippines',
        email: json['email'] as String? ?? 'traveler@lakbay.ph',
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

  const BackendRouteResult({
    required this.routeProvider,
    required this.isEstimated,
    required this.totalDistanceKm,
    required this.totalDurationMinutes,
    required this.geometryPoints,
    this.warnings = const [],
    this.orderedDestinationIds = const [],
  });
}
