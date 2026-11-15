import 'package:flutter/material.dart';
import '../models/travel_models.dart';
import '../services/mapbox_service.dart';
import '../services/travel_repository.dart';
import '../theme/lakbay_theme.dart';
import '../widgets/lakbay_mapbox_widget.dart';
import 'trip_route_map_screen.dart';

class TripDetailScreen extends StatefulWidget {
  final ItineraryTrip trip;
  final TravelRepository repo;

  const TripDetailScreen({
    super.key,
    required this.trip,
    required this.repo,
  });

  @override
  State<TripDetailScreen> createState() => _TripDetailScreenState();
}

class _TripDetailScreenState extends State<TripDetailScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  ItineraryTrip? _liveTrip;
  bool _loadingLive = false;

  ItineraryTrip get _activeTrip => _liveTrip ?? widget.trip;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _loadLiveDetails();
  }

  Future<void> _loadLiveDetails() async {
    if (_loadingLive) return;
    _loadingLive = true;
    try {
      final enriched = await widget.repo.loadLiveDetailsForTrip(widget.trip);
      if (!mounted) return;
      setState(() {
        _liveTrip = enriched;
        _loadingLive = false;
      });
    } catch (_) {
      _loadingLive = false;
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  String _transitSprite(TransportMode mode) {
    switch (mode) {
      case TransportMode.flight:
        return 'assets/map_sprites/means-plane.png';
      case TransportMode.ferry:
        return 'assets/map_sprites/means-boat.png';
      case TransportMode.bus:
        return 'assets/map_sprites/means-bus.png';
      case TransportMode.train:
        return 'assets/map_sprites/means-train.png';
      case TransportMode.car:
        return 'assets/map_sprites/means-car.png';
    }
  }

  void _openFullRouteMap() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            TripRouteMapScreen(trip: widget.trip, repo: widget.repo),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final trip = widget.trip;
    final isSaved = widget.repo.savedTrips.any((t) => t.id == trip.id);
    final isBucketed = widget.repo.isTripInBucketList(trip.id);

    return Scaffold(
      backgroundColor: LakbayColors.canvasBg,
      body: NestedScrollView(
        headerSliverBuilder: (context, innerBoxIsScrolled) => [
          SliverAppBar(
            expandedHeight: 280,
            pinned: true,
            backgroundColor: LakbayColors.tealDeep,
            foregroundColor: Colors.white,
            actions: [
              IconButton(
                tooltip: 'Play Animated Mapbox Route',
                onPressed: _openFullRouteMap,
                icon: const Icon(Icons.map_rounded, color: Colors.white),
              ),
              IconButton(
                tooltip: 'Save to Bucket List',
                onPressed: () {
                  widget.repo.toggleBucketListTrip(trip.id);
                  setState(() {});
                },
                icon: Icon(
                  isBucketed
                      ? Icons.favorite_rounded
                      : Icons.favorite_border_rounded,
                  color: isBucketed ? LakbayColors.primary : Colors.white,
                ),
              ),
              IconButton(
                tooltip: 'Save to My Trips',
                onPressed: () {
                  widget.repo.saveTripToMyTrips(trip);
                  setState(() {});
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Saved "${trip.title}" to My Trips!'),
                      backgroundColor: LakbayColors.tealDeep,
                    ),
                  );
                },
                icon: Icon(
                  isSaved
                      ? Icons.bookmark_added_rounded
                      : Icons.bookmark_add_outlined,
                ),
              ),
            ],
            flexibleSpace: FlexibleSpaceBar(
              background: Stack(
                fit: StackFit.expand,
                children: [
                  _activeTrip.remoteImageUrl != null &&
                          _activeTrip.remoteImageUrl!.isNotEmpty
                      ? Image.network(
                          _activeTrip.remoteImageUrl!,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => Image.asset(
                            _activeTrip.heroAsset,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => Container(
                              decoration: const BoxDecoration(
                                  gradient: LakbayColors.deepTealGradient),
                            ),
                          ),
                        )
                      : Image.asset(
                          _activeTrip.heroAsset,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => Container(
                            decoration: const BoxDecoration(
                                gradient: LakbayColors.deepTealGradient),
                          ),
                        ),
                  Container(
                    decoration: const BoxDecoration(
                      gradient: LakbayColors.darkOverlayGradient,
                    ),
                  ),
                  Positioned(
                    left: 20,
                    right: 20,
                    bottom: 58,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: LakbayColors.primary,
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                '${trip.daysCount} DAYS • ${trip.vibeTag.toUpperCase()}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.45),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                'Est. ${widget.repo.formatPrice(trip.totalEstimatedCostUsd)}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          trip.title,
                          style: const TextStyle(
                            fontFamily: 'FigGrotesk',
                            fontSize: 25,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                            height: 1.15,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            bottom: TabBar(
              controller: _tabController,
              indicatorColor: LakbayColors.primary,
              indicatorWeight: 3,
              labelColor: Colors.white,
              unselectedLabelColor: Colors.white70,
              labelStyle: const TextStyle(
                fontFamily: 'FigGrotesk',
                fontWeight: FontWeight.w700,
                fontSize: 14,
              ),
              tabs: const [
                Tab(text: 'Overview & Map'),
                Tab(text: 'Day-by-Day'),
                Tab(text: 'Stays & Flights'),
              ],
            ),
          ),
        ],
        body: TabBarView(
          controller: _tabController,
          children: [
            _buildOverviewTab(_activeTrip),
            _buildDayByDayTab(_activeTrip),
            _buildStaysAndFlightsTab(_activeTrip),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.white,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.06),
                blurRadius: 12,
                offset: const Offset(0, -4),
              ),
            ],
          ),
          child: Row(
            children: [
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Total Package Estimate',
                    style: TextStyle(
                      fontSize: 12,
                      color: LakbayColors.textSecondary,
                    ),
                  ),
                  Text(
                    '${widget.repo.formatPrice(trip.totalEstimatedCostUsd)} (${trip.adults} Adults)',
                    style: const TextStyle(
                      fontFamily: 'FigGrotesk',
                      fontWeight: FontWeight.w700,
                      fontSize: 17.5,
                      color: LakbayColors.tealDeep,
                    ),
                  ),
                ],
              ),
              const Spacer(),
              ElevatedButton.icon(
                onPressed: () {
                  widget.repo.saveTripToMyTrips(trip);
                  if (_activeTrip.flights.isNotEmpty) {
                    widget.repo.addToBasket(
                      BasketItem(
                        id: 'flight_${_activeTrip.id}',
                        title:
                            '${_activeTrip.flights.first.originCode} → ${_activeTrip.flights.first.destinationCode} Roundtrip',
                        subtitle:
                            '${_activeTrip.flights.first.airline} • ${_activeTrip.flights.first.duration}',
                        category: 'Flight',
                        priceUsd: _activeTrip.flights.first.priceRoundtripUsd *
                            _activeTrip.adults,
                        imageAsset: _activeTrip.heroAsset,
                        remoteImageUrl: _activeTrip.remoteImageUrl,
                        backendDestinationId: _activeTrip.backendDestinationId,
                      ),
                    );
                  }
                  if (_activeTrip.hotels.isNotEmpty) {
                    widget.repo.addToBasket(
                      BasketItem(
                        id: 'hotel_${_activeTrip.id}',
                        title: _activeTrip.hotels.first.name,
                        subtitle:
                            '${_activeTrip.daysCount - 1} nights • ${_activeTrip.hotels.first.stars}★ Davao Stay',
                        category: 'Hotel',
                        priceUsd: _activeTrip.hotels.first.pricePerNightUsd *
                            (_activeTrip.daysCount - 1).clamp(1, 30),
                        imageAsset: _activeTrip.heroAsset,
                        remoteImageUrl: _activeTrip.hotels.first.remoteImageUrl ??
                            _activeTrip.remoteImageUrl,
                        backendDestinationId: _activeTrip.backendDestinationId,
                      ),
                    );
                  }
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content:
                          Text('Added flights & stays to your Booking Basket!'),
                      backgroundColor: LakbayColors.primary,
                    ),
                  );
                },
                icon: const Icon(Icons.shopping_bag_outlined, size: 18),
                label: const Text('Add All to Basket'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildOverviewTab(ItineraryTrip trip) {
    final waypoints = trip.routeWaypoints;
    final totalKm = MapboxService.calculateRouteDistanceKm(waypoints);
    final markers = [
      for (int i = 0; i < trip.days.length; i++)
        LakbayMapMarker(
          id: 'day_${trip.days[i].dayNumber}',
          lat: trip.days[i].lat,
          lng: trip.days[i].lng,
          badgeText: 'D${trip.days[i].dayNumber}',
          title: trip.days[i].cityTitle,
          isPrimary: i == 0,
          isOrigin: i == 0,
          isDestination: i == trip.days.length - 1,
        ),
    ];

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Row(
          children: [
            _buildInfoChip(
              iconWidget: Image.asset(
                'assets/png/weather/${trip.wmoWeatherCode}.png',
                width: 22,
                height: 22,
                errorBuilder: (_, _, _) => const Icon(Icons.wb_sunny_rounded,
                    color: LakbayColors.primary, size: 20),
              ),
              label: 'Davao Weather',
              value: trip.avgTemp,
            ),
            const SizedBox(width: 10),
            _buildInfoChip(
              iconWidget: const Icon(Icons.calendar_month_rounded,
                  color: LakbayColors.primary, size: 20),
              label: 'Best Months',
              value: trip.bestMonths,
            ),
            const SizedBox(width: 10),
            _buildInfoChip(
              iconWidget: const Icon(Icons.route_rounded,
                  color: LakbayColors.primary, size: 20),
              label: 'Region XI Route',
              value: '${totalKm.toStringAsFixed(0)} km',
            ),
          ],
        ),
        const SizedBox(height: 20),

        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Animated Mapbox Route',
              style: TextStyle(
                fontFamily: 'FigGrotesk',
                fontWeight: FontWeight.w700,
                fontSize: 20,
              ),
            ),
            FilledButton.tonalIcon(
              onPressed: _openFullRouteMap,
              style: FilledButton.styleFrom(
                backgroundColor: LakbayColors.primaryLight,
                foregroundColor: LakbayColors.primaryDark,
              ),
              icon: const Icon(Icons.play_arrow_rounded, size: 18),
              label: const Text('Play Tour'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          height: 240,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: LakbayColors.cardBorder),
          ),
          child: LakbayMapboxMap(
            repo: widget.repo,
            initialLat: trip.centerLat,
            initialLng: trip.centerLng,
            initialZoom: 8.4,
            routePoints: waypoints,
            markers: markers,
            onMarkerTap: (_) => _openFullRouteMap(),
          ),
        ),
        const SizedBox(height: 22),

        const Text(
          'Why You’ll Love This Davao Route',
          style: TextStyle(
            fontFamily: 'FigGrotesk',
            fontWeight: FontWeight.w700,
            fontSize: 20,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          trip.overviewText,
          style: const TextStyle(
            fontSize: 15,
            height: 1.5,
            color: LakbayColors.textSecondary,
          ),
        ),
        const SizedBox(height: 20),

        // Expert Curator Card with APK .webp avatar
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: LakbayColors.primarySoft,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
                color: LakbayColors.primary.withValues(alpha: 0.25)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipOval(
                child: Image.asset(
                  trip.expertAvatarAsset,
                  width: 46,
                  height: 46,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const LakbayAvatar(size: 46),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      trip.expertName,
                      style: const TextStyle(
                        fontFamily: 'FigGrotesk',
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                        color: LakbayColors.primaryDark,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '"${trip.expertTip}"',
                      style: const TextStyle(
                        fontSize: 13.5,
                        height: 1.4,
                        color: LakbayColors.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 22),

        const Text(
          'Route Highlights Snapshot',
          style: TextStyle(
            fontFamily: 'FigGrotesk',
            fontWeight: FontWeight.w700,
            fontSize: 18,
          ),
        ),
        const SizedBox(height: 12),
        ...trip.days.map(
          (day) => Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: LakbayColors.cardBorder),
            ),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: LakbayColors.tealDeep,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    'D${day.dayNumber}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        day.cityTitle,
                        style: const TextStyle(
                          fontFamily: 'FigGrotesk',
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        day.summary,
                        style: const TextStyle(
                          fontSize: 12.5,
                          color: LakbayColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                Image.asset(
                  'assets/png/weather/${day.wmoWeatherCode}.png',
                  width: 22,
                  height: 22,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
                IconButton(
                  tooltip: 'View on Mapbox',
                  onPressed: _openFullRouteMap,
                  icon: const Icon(Icons.location_on_outlined,
                      color: LakbayColors.primary, size: 20),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDayByDayTab(ItineraryTrip trip) {
    return ListView.builder(
      padding: const EdgeInsets.all(20),
      itemCount: trip.days.length,
      itemBuilder: (context, index) {
        final day = trip.days[index];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (day.transportFromPrevious != null)
              Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: LakbayColors.tealWash.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Image.asset(
                      _transitSprite(day.transportFromPrevious!),
                      width: 18,
                      height: 18,
                      errorBuilder: (_, _, _) => const Icon(
                        Icons.directions_car_rounded,
                        size: 16,
                        color: LakbayColors.tealDeep,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      day.transportDuration ?? 'Transit leg included',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: LakbayColors.tealDeep,
                      ),
                    ),
                  ],
                ),
              ),
            Container(
              margin: const EdgeInsets.only(bottom: 18),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: LakbayColors.cardBorder),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: LakbayColors.primary,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          'DAY ${day.dayNumber}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: 11,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          day.cityTitle
                              .replaceFirst(RegExp(r'^Day \d+ • '), ''),
                          style: const TextStyle(
                            fontFamily: 'FigGrotesk',
                            fontWeight: FontWeight.w700,
                            fontSize: 17,
                          ),
                        ),
                      ),
                      Image.asset(
                        'assets/png/weather/${day.wmoWeatherCode}.png',
                        width: 22,
                        height: 22,
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '${day.tempCelsius}°C',
                        style: const TextStyle(
                          fontFamily: 'FigGrotesk',
                          fontWeight: FontWeight.w700,
                          fontSize: 12.5,
                          color: LakbayColors.tealDeep,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Inspect Day on Mapbox',
                        onPressed: _openFullRouteMap,
                        icon: const Icon(Icons.map_outlined,
                            color: LakbayColors.tealAccent, size: 20),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    day.summary,
                    style: const TextStyle(
                      fontSize: 13,
                      color: LakbayColors.textSecondary,
                    ),
                  ),
                  const Divider(height: 22),
                  ...day.stops.map(
                    (stop) => Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 68,
                            child: Text(
                              stop.time,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 12,
                                color: LakbayColors.tealAccent,
                              ),
                            ),
                          ),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  stop.title,
                                  style: const TextStyle(
                                    fontFamily: 'FigGrotesk',
                                    fontWeight: FontWeight.w600,
                                    fontSize: 14.5,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  stop.description,
                                  style: const TextStyle(
                                    fontSize: 12.5,
                                    color: LakbayColors.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildStaysAndFlightsTab(ItineraryTrip trip) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text(
          'Flights to Davao International (DVO)',
          style: TextStyle(
            fontFamily: 'FigGrotesk',
            fontWeight: FontWeight.w700,
            fontSize: 19,
          ),
        ),
        const SizedBox(height: 12),
        ...trip.flights.map(
          (f) => Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: LakbayColors.cardBorder),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: LakbayColors.primaryLight,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.flight_takeoff_rounded,
                      color: LakbayColors.primary),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${f.originCode} ↔ ${f.destinationCode} • ${f.duration}',
                        style: const TextStyle(
                          fontFamily: 'FigGrotesk',
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                        ),
                      ),
                      Text(
                        '${f.airline} (${f.isDirect ? "Direct" : "1 Stop"})',
                        style: const TextStyle(
                          fontSize: 12.5,
                          color: LakbayColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      widget.repo.formatPrice(f.priceRoundtripUsd),
                      style: const TextStyle(
                        fontFamily: 'FigGrotesk',
                        fontWeight: FontWeight.w700,
                        fontSize: 17,
                        color: LakbayColors.tealDeep,
                      ),
                    ),
                    const Text(
                      'per traveler',
                      style:
                          TextStyle(fontSize: 11, color: LakbayColors.textMuted),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 18),
        const Text(
          'Handpicked Davao Region Stays',
          style: TextStyle(
            fontFamily: 'FigGrotesk',
            fontWeight: FontWeight.w700,
            fontSize: 19,
          ),
        ),
        const SizedBox(height: 12),
        ...trip.hotels.map(
          (h) => Container(
            margin: const EdgeInsets.only(bottom: 14),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: LakbayColors.cardBorder),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        h.name,
                        style: const TextStyle(
                          fontFamily: 'FigGrotesk',
                          fontWeight: FontWeight.w700,
                          fontSize: 17,
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: LakbayColors.tealDeep,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '${h.rating} ★',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '${"★" * h.stars} • ${h.partnerName}',
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: LakbayColors.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: h.facilities
                      .map(
                        (fac) => Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: LakbayColors.canvasBg,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            fac,
                            style: const TextStyle(
                              fontSize: 11.5,
                              color: LakbayColors.textSecondary,
                            ),
                          ),
                        ),
                      )
                      .toList(),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '${widget.repo.formatPrice(h.pricePerNightUsd)} / night',
                      style: const TextStyle(
                        fontFamily: 'FigGrotesk',
                        fontWeight: FontWeight.w700,
                        fontSize: 17,
                        color: LakbayColors.tealDeep,
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: () {
                        widget.repo.addToBasket(
                          BasketItem(
                            id: h.id,
                            title: h.name,
                            subtitle:
                                '${trip.daysCount - 1} nights • ${h.city}',
                            category: 'Hotel',
                            priceUsd: h.pricePerNightUsd *
                                (trip.daysCount - 1).clamp(1, 30),
                            imageAsset: h.imageAsset,
                            remoteImageUrl: h.remoteImageUrl,
                            backendDestinationId: trip.backendDestinationId,
                          ),
                        );
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('Added ${h.name} to Basket!'),
                            backgroundColor: LakbayColors.tealAccent,
                          ),
                        );
                      },
                      icon: const Icon(Icons.add_shopping_cart_rounded,
                          size: 16),
                      label: const Text('Select Stay'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        for (final destId in trip.effectiveBackendDestinationIds)
          ...widget.repo.transportRatesForDestination(destId).map(
                (tr) => Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: LakbayColors.cardBorder),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.directions_bus_rounded,
                          color: LakbayColors.tealDeep),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${tr.vehicleType} (${tr.transportMode})',
                              style: const TextStyle(
                                fontFamily: 'FigGrotesk',
                                fontWeight: FontWeight.w700,
                                fontSize: 15,
                              ),
                            ),
                            Text(
                              '${tr.routeFrom} → ${tr.routeTo}${tr.durationText != null ? ' • ${tr.durationText}' : ''}',
                              style: const TextStyle(
                                fontSize: 12,
                                color: LakbayColors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Text(
                        '₱${tr.pricePhp.toStringAsFixed(0)}',
                        style: const TextStyle(
                          fontFamily: 'FigGrotesk',
                          fontWeight: FontWeight.w700,
                          fontSize: 15.5,
                          color: LakbayColors.primary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
      ],
    );
  }

  Widget _buildInfoChip({
    required Widget iconWidget,
    required String label,
    required String value,
  }) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: LakbayColors.cardBorder),
        ),
        child: Column(
          children: [
            iconWidget,
            const SizedBox(height: 4),
            Text(
              label,
              style: const TextStyle(
                fontSize: 11,
                color: LakbayColors.textMuted,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              value,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: 'FigGrotesk',
                fontWeight: FontWeight.w700,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
