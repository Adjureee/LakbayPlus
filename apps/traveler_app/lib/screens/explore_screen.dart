import 'dart:async';
import 'package:flutter/material.dart';
import '../models/travel_models.dart';
import '../services/mapbox_service.dart';
import '../services/route_optimizer.dart';
import '../services/travel_repository.dart';
import '../theme/lakbay_theme.dart';
import '../widgets/lakbay_image.dart';
import '../widgets/lakbay_mapbox_widget.dart';
import 'trip_detail_screen.dart';

class ExploreScreen extends StatefulWidget {
  final TravelRepository repo;

  const ExploreScreen({super.key, required this.repo});

  @override
  State<ExploreScreen> createState() => _ExploreScreenState();
}

class _ExploreScreenState extends State<ExploreScreen> {
  String _searchQuery = '';
  String _selectedFilter = 'All';
  bool _isMapView = false;
  ExploreTrip? _selectedMapTrip;

  static const List<String> _filters = [
    'All',
    'Davao City',
    'Samal',
    'Davao Oriental',
    'Davao del Norte',
    'Davao del Sur',
    'Davao de Oro',
    'Davao Occidental',
    'City Guides',
  ];

  void _openExploreTrip(ExploreTrip explore) {
    final detailedTrip = widget.repo.buildDetailedItineraryFromExplore(explore);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TripDetailScreen(trip: detailedTrip, repo: widget.repo),
      ),
    );
  }

  void _openCityPlanSheet(String cityOrQuery) {
    final added = widget.repo.seedTripBuilderForPlace(cityOrQuery);
    if (added > 0) {
      setState(() {});
      _openMultiStopBuilderSheet(
        aiFallbackPrompt: 'Help me plan a trip to $cityOrQuery.',
      );
      return;
    }
    widget.repo.planInChat('Help me plan a trip to $cityOrQuery.');
  }

  void _openMultiStopBuilderSheet({String? aiFallbackPrompt}) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      builder: (ctx) => _MultiStopPlanSheet(
        repo: widget.repo,
        aiFallbackPrompt: aiFallbackPrompt,
        onStopsChanged: () {
          if (mounted) setState(() {});
        },
        onTripBuilt: (built) {
          if (!mounted) return;
          setState(() {});
          final headline = built.optimizationSummary?.savingsHeadline;
          if (headline != null && headline.isNotEmpty) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  '$headline · ${built.optimizationSummary!.methodLabel}',
                ),
                backgroundColor: LakbayColors.tealDeep,
              ),
            );
          }
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => TripDetailScreen(
                trip: built,
                repo: widget.repo,
              ),
            ),
          );
        },
      ),
    );
  }

  /// Pull-to-refresh: reload the live catalog (and rates) in one smooth gesture.
  Future<void> _refreshCatalog() async {
    try {
      await widget.repo.syncCatalogWithApi();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Couldn't refresh. Showing the places already on your phone."),
        ),
      );
      return;
    }
    if (mounted) setState(() {});
  }

  void _openCityEncyclopediaSheet(CityDescription cityObj) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.72,
        maxChildSize: 0.92,
        minChildSize: 0.45,
        builder: (_, scrollCtrl) => ListView(
          controller: scrollCtrl,
          padding: const EdgeInsets.all(22),
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: LakbayColors.primaryLight,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(Icons.place_rounded,
                      color: LakbayColors.primary, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        cityObj.city,
                        style: const TextStyle(
                          fontFamily: 'FigGrotesk',
                          fontWeight: FontWeight.w700,
                          fontSize: 21,
                        ),
                      ),
                      Text(
                        cityObj.country,
                        style: const TextStyle(
                          fontSize: 13,
                          color: LakbayColors.tealAccent,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                Image.asset(
                  'assets/png/weather/${cityObj.wmoWeatherCode}.png',
                  width: 32,
                  height: 32,
                  errorBuilder: (_, _, _) => const Icon(
                    Icons.wb_sunny_rounded,
                    color: LakbayColors.cocoaOrange,
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            const Divider(height: 24),
            Text(
              cityObj.longDescription ?? cityObj.description,
              style: const TextStyle(
                fontSize: 14.5,
                height: 1.55,
                color: LakbayColors.textPrimary,
              ),
            ),
            const SizedBox(height: 22),
            ElevatedButton.icon(
              onPressed: () {
                Navigator.of(ctx).pop();
                _openCityPlanSheet(cityObj.city);
              },
              icon: const Icon(Icons.route_rounded),
              label: Text('Plan Trip · ${cityObj.city}'),
            ),
          ],
        ),
      ),
    );
  }

  List<ExploreTrip> _filteredMapTrips() {
    final filtered = widget.repo.allTrips.where((t) {
      if (_searchQuery.isNotEmpty &&
          !t.title.toLowerCase().contains(_searchQuery.toLowerCase()) &&
          !t.regionName.toLowerCase().contains(_searchQuery.toLowerCase())) {
        return false;
      }
      if (_selectedFilter != 'All' && _selectedFilter != 'City Guides') {
        return t.regionName
                .toLowerCase()
                .contains(_selectedFilter.toLowerCase()) ||
            t.title.toLowerCase().contains(_selectedFilter.toLowerCase());
      }
      return true;
    }).toList();
    if (widget.repo.hasUserLocation) {
      filtered.sort(
        (a, b) => widget.repo
            .distanceKmFromUser(a.lat, a.lng)
            .compareTo(widget.repo.distanceKmFromUser(b.lat, b.lng)),
      );
    }
    return filtered;
  }

  @override
  Widget build(BuildContext context) {
    final heroTrip = widget.repo.heroTrip;
    final sections = widget.repo.discoverySections;

    return Scaffold(
      backgroundColor: LakbayColors.canvasBg,
      body: SafeArea(
        child: Column(
          children: [
            // Header + Search Bar + Region Pills + Mapbox Toggle
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Discover',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: 'FigGrotesk',
                            fontWeight: FontWeight.w800,
                            fontSize: 28,
                            color: LakbayColors.tealDeep,
                          ),
                        ),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: () {
                          setState(() {
                            _isMapView = !_isMapView;
                            if (_isMapView &&
                                _selectedMapTrip == null &&
                                !widget.repo.hasUserLocation) {
                              final list = _filteredMapTrips();
                              if (list.isNotEmpty) {
                                _selectedMapTrip = list.first;
                              }
                            }
                          });
                        },
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          visualDensity: VisualDensity.compact,
                          backgroundColor: _isMapView
                              ? LakbayColors.tealDeep
                              : LakbayColors.primaryLight,
                          foregroundColor: _isMapView
                              ? Colors.white
                              : LakbayColors.primaryDark,
                        ),
                        icon: Icon(
                          _isMapView
                              ? Icons.view_agenda_rounded
                              : Icons.map_rounded,
                          size: 16,
                        ),
                        label: Text(
                          _isMapView ? 'List View' : 'Mapbox',
                          style: const TextStyle(
                            fontFamily: 'FigGrotesk',
                            fontWeight: FontWeight.w700,
                            fontSize: 12.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Single Region XI places, Mapbox pins & local guides',
                          style: TextStyle(
                            fontSize: 12.5,
                            color: LakbayColors.textSecondary,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ActionChip(
                        avatar: const Icon(
                          Icons.auto_graph_rounded,
                          size: 15,
                          color: LakbayColors.primary,
                        ),
                        visualDensity: VisualDensity.compact,
                        label: const Text(
                          'Top-5 Match',
                          style: TextStyle(
                            fontFamily: 'FigGrotesk',
                            fontWeight: FontWeight.w700,
                            fontSize: 12,
                          ),
                        ),
                        onPressed: _openTopPlacesSheet,
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    onChanged: (v) => setState(() => _searchQuery = v.trim()),
                    decoration: InputDecoration(
                      hintText:
                          'Search Samal, Mati, Buda, Tagum, Mt. Apo, or falls...',
                      prefixIcon: const Icon(Icons.search_rounded,
                          color: LakbayColors.primary),
                      filled: true,
                      fillColor: Colors.white,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 11),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide:
                            const BorderSide(color: LakbayColors.cardBorder),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide:
                            const BorderSide(color: LakbayColors.cardBorder),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 36,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: _filters.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 8),
                      itemBuilder: (context, index) {
                        final f = _filters[index];
                        final selected = _selectedFilter == f;
                        return ChoiceChip(
                          label: Text(f),
                          selected: selected,
                          selectedColor: LakbayColors.primary,
                          backgroundColor: Colors.white,
                          labelStyle: TextStyle(
                            color: selected
                                ? Colors.white
                                : LakbayColors.textPrimary,
                            fontWeight: FontWeight.w600,
                            fontSize: 12.5,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(20),
                          ),
                          onSelected: (_) =>
                              setState(() => _selectedFilter = f),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),

            Expanded(
              child: _isMapView
                  ? _buildInteractiveMapboxExplorer()
                  : RefreshIndicator(
                      onRefresh: _refreshCatalog,
                      color: LakbayColors.primary,
                      backgroundColor: Colors.white,
                      displacement: 48,
                      child: CustomScrollView(
                      // Always scrollable, so a short list can still be pulled down to refresh.
                      physics: const AlwaysScrollableScrollPhysics(
                        parent: BouncingScrollPhysics(),
                      ),
                      slivers: [
                        if (_searchQuery.isEmpty &&
                            _selectedFilter == 'All' &&
                            heroTrip != null)
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 20, vertical: 10),
                              child: _buildHeroCard(heroTrip),
                            ),
                          ),
                        if (_searchQuery.isEmpty &&
                            _selectedFilter == 'All' &&
                            widget.repo.suggestedRoutes.isNotEmpty)
                          SliverToBoxAdapter(
                            child: _buildSuggestedRoutesShelf(),
                          ),
                        if (_searchQuery.isNotEmpty)
                          _buildSearchResultsSliver()
                        else if (_selectedFilter == 'City Guides')
                          _buildCityGuidesSliver()
                        else ...[
                          SliverPadding(
                            padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
                            sliver: SliverGrid(
                              gridDelegate:
                                  const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 2,
                                mainAxisSpacing: 12,
                                crossAxisSpacing: 12,
                                childAspectRatio: 0.74,
                              ),
                              delegate: SliverChildBuilderDelegate(
                                (context, idx) {
                                  final trip = _filteredMapTrips()[idx];
                                  final inTray =
                                      widget.repo.isInTripBuilder(trip.id);
                                  return GestureDetector(
                                    onTap: () => _openExploreTrip(trip),
                                    child: Container(
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(20),
                                        boxShadow: [
                                          BoxShadow(
                                            color: Colors.black
                                                .withValues(alpha: 0.08),
                                            blurRadius: 10,
                                            offset: const Offset(0, 4),
                                          ),
                                        ],
                                      ),
                                      clipBehavior: Clip.antiAlias,
                                      child: Stack(
                                        fit: StackFit.expand,
                                        children: [
                                          LakbayNetworkOrAssetImage(
                                            networkUrl: trip.hasRemoteThumbnail
                                                ? trip.thumbnailUrl
                                                : null,
                                            assetPath: trip.localAssetPath,
                                            fallbackAsset: widget
                                                .repo.currentBackdrop.localAssetPath,
                                          ),
                                          Container(
                                            decoration: const BoxDecoration(
                                              gradient: LinearGradient(
                                                colors: [
                                                  Color(0x11000000),
                                                  Color(0xD9071E26),
                                                ],
                                                begin: Alignment.topCenter,
                                                end: Alignment.bottomCenter,
                                              ),
                                            ),
                                          ),
                                          Positioned(
                                            top: 10,
                                            left: 10,
                                            right: 10,
                                            child: Align(
                                              alignment: Alignment.centerLeft,
                                              child: Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                  horizontal: 9,
                                                  vertical: 4,
                                                ),
                                                decoration: BoxDecoration(
                                                  color: LakbayColors.primaryLight,
                                                  borderRadius:
                                                      BorderRadius.circular(14),
                                                ),
                                                child: Text(
                                                  '${trip.tag ?? "Place"} • ${trip.stayDurationLabel}',
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                    fontSize: 10.5,
                                                    fontWeight: FontWeight.w800,
                                                    color: LakbayColors
                                                        .primaryDark,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                          Positioned(
                                            left: 10,
                                            right: 10,
                                            bottom: 10,
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Text(
                                                  trip.title,
                                                  maxLines: 2,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                    fontFamily: 'FigGrotesk',
                                                    fontSize: 14,
                                                    fontWeight: FontWeight.w700,
                                                    color: Colors.white,
                                                    height: 1.15,
                                                  ),
                                                ),
                                                const SizedBox(height: 2),
                                                Text(
                                                  trip.municipalityLabel,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                    fontSize: 11,
                                                    color: Colors.white70,
                                                  ),
                                                ),
                                                const SizedBox(height: 6),
                                                SizedBox(
                                                  width: double.infinity,
                                                  child: InkWell(
                                                    onTap: () => setState(
                                                      () => widget.repo
                                                          .toggleTripBuilderStop(
                                                              trip),
                                                    ),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                            12),
                                                    child: Container(
                                                      padding: const EdgeInsets
                                                          .symmetric(
                                                        horizontal: 8,
                                                        vertical: 5,
                                                      ),
                                                      decoration: BoxDecoration(
                                                        color: inTray
                                                            ? LakbayColors
                                                                .primary
                                                            : Colors.white
                                                                .withValues(
                                                                    alpha: 0.92),
                                                        borderRadius:
                                                            BorderRadius
                                                                .circular(12),
                                                      ),
                                                      child: Text(
                                                        inTray
                                                            ? '✓ In trip'
                                                            : '＋ Add to trip',
                                                        textAlign:
                                                            TextAlign.center,
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                        style: TextStyle(
                                                          fontSize: 11.5,
                                                          fontWeight:
                                                              FontWeight.w700,
                                                          color: inTray
                                                              ? Colors.white
                                                              : LakbayColors
                                                                  .tealDeep,
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                                childCount: _filteredMapTrips().take(6).length,
                              ),
                            ),
                          ),
                          for (final section in sections)
                            if (_matchesSectionFilter(section))
                              SliverToBoxAdapter(
                                child: _buildDiscoverySectionCarousel(section),
                              ),
                          SliverToBoxAdapter(
                            child: Padding(
                              padding:
                                  const EdgeInsets.fromLTRB(20, 18, 20, 8),
                              child: Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  const Text(
                                    'Davao Region Encyclopedia',
                                    style: TextStyle(
                                      fontFamily: 'FigGrotesk',
                                      fontWeight: FontWeight.w700,
                                      fontSize: 21,
                                      color: LakbayColors.tealDeep,
                                    ),
                                  ),
                                  TextButton(
                                    onPressed: () => setState(
                                        () => _selectedFilter = 'City Guides'),
                                    child: const Text('See All 24 →'),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          _buildCityGuidesSliver(limit: 8),
                        ],
                      ],
                    ),
                    ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: widget.repo.tripBuilderStops.isEmpty
          ? null
          : SafeArea(
              child: Container(
                margin: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: LakbayColors.tealDeep,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: LakbayColors.tealDeep.withValues(alpha: 0.28),
                      blurRadius: 14,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: LakbayColors.primary,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Text(
                        '${widget.repo.tripBuilderStops.length}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '${widget.repo.tripBuilderStops.length} ${widget.repo.tripBuilderStops.length == 1 ? 'place' : 'places'} selected · Plan trip',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 13.5,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () => setState(() => widget.repo.clearTripBuilder()),
                      child: const Text(
                        'Clear',
                        style: TextStyle(color: Colors.white70),
                      ),
                    ),
                    ElevatedButton(
                      onPressed: _openMultiStopBuilderSheet,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: LakbayColors.primary,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 8,
                        ),
                      ),
                      child: const Text('Plan trip'),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildInteractiveMapboxExplorer() {
    final trips = _filteredMapTrips();
    final activeTrip =
        _selectedMapTrip ?? (trips.isNotEmpty ? trips.first : null);
    final markers = [
      ...trips.map(
        (t) => LakbayMapMarker(
          id: t.id,
          lat: t.lat,
          lng: t.lng,
          badgeText: t.stayDurationLabel,
          title: t.title,
          subtitle: '${t.municipalityLabel} • ${t.tag ?? "Place"}',
          imageUrl: t.hasRemoteThumbnail ? t.thumbnailUrl : null,
          imageAsset: t.localAssetPath,
          isPrimary: activeTrip?.id == t.id,
          isCompact: activeTrip?.id != t.id,
        ),
      ),
      if (widget.repo.originLat != null && widget.repo.originLng != null)
        LakbayMapMarker(
          id: 'user_gps',
          lat: widget.repo.originLat!,
          lng: widget.repo.originLng!,
          title: 'You (${widget.repo.effectiveOriginLabel})',
          subtitle: widget.repo.hasManualOrigin
              ? 'Chosen starting place'
              : 'Current GPS location',
          isUserLocation: true,
        ),
    ];

    final startLat = _selectedMapTrip?.lat ??
        (widget.repo.originLat ??
            (activeTrip?.lat ?? MapboxService.davaoCenterLat));
    final startLng = _selectedMapTrip?.lng ??
        (widget.repo.originLng ??
            (activeTrip?.lng ?? MapboxService.davaoCenterLng));
    final startZoom =
        _selectedMapTrip == null && widget.repo.originLat != null ? 10.5 : 8.3;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Stack(
        children: [
          LakbayMapboxMap(
            repo: widget.repo,
            initialLat: startLat,
            initialLng: startLng,
            initialZoom: startZoom,
            markers: markers,
            selectedMarkerId: activeTrip?.id,
            controlsBottomOffset: activeTrip != null ? 116 : 24,
            animateRoute: false,
            onMarkerTap: (m) {
              final found = trips.where((t) => t.id == m.id).firstOrNull;
              if (found != null) {
                setState(() => _selectedMapTrip = found);
              }
            },
          ),
          if (activeTrip != null)
            Positioned(
              left: 14,
              right: 14,
              bottom: 16,
              child: InkWell(
                onTap: () => _openExploreTrip(activeTrip),
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.96),
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.18),
                        blurRadius: 16,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child: SizedBox(
                          width: 72,
                          height: 72,
                          child: LakbayNetworkOrAssetImage(
                            networkUrl: activeTrip.hasRemoteThumbnail
                                ? activeTrip.thumbnailUrl
                                : null,
                            assetPath: activeTrip.localAssetPath,
                            fallbackAsset:
                                widget.repo.currentBackdrop.localAssetPath,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              activeTrip.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontFamily: 'FigGrotesk',
                                fontWeight: FontWeight.w700,
                                fontSize: 15,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${activeTrip.municipalityLabel} • ${activeTrip.tag ?? "Place"} • ${activeTrip.stayDurationLabel}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12,
                                color: LakbayColors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: () => _openExploreTrip(activeTrip),
                        style: FilledButton.styleFrom(
                          backgroundColor: LakbayColors.primary,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 10),
                        ),
                        child: const Text('Open'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  bool _matchesSectionFilter(DiscoverySection section) {
    if (_selectedFilter == 'All') return true;
    final lowerFilter = _selectedFilter.toLowerCase();
    return section.id.toLowerCase().contains(lowerFilter) ||
        section.title.toLowerCase().contains(lowerFilter);
  }

  Widget _buildSuggestedRoutesShelf() {
    // Only routes whose places are in the catalog right now; a route that
    // loads nothing would be a dead card.
    final routes = widget.repo.suggestedRoutes
        .where(
          (r) => r.destinationIds.any((id) => widget.repo.getTripById(id) != null),
        )
        .toList();
    if (routes.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Suggested routes',
                  style: TextStyle(
                    fontFamily: 'FigGrotesk',
                    fontWeight: FontWeight.w700,
                    fontSize: 20,
                    color: LakbayColors.tealDeep,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  'Curated starter combinations — tap one to fill your trip tray',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: LakbayColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 124,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              scrollDirection: Axis.horizontal,
              itemCount: routes.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (context, index) {
                final route = routes[index];
                final places = route.destinationIds
                    .map(widget.repo.getTripById)
                    .whereType<ExploreTrip>()
                    .toList();
                final firstPlace = places.firstOrNull;
                // Straight-line distance from where the traveler is starting;
                // road distances come with the real routing work.
                final awayKm = (firstPlace != null &&
                        widget.repo.originLat != null &&
                        widget.repo.originLng != null)
                    ? MapboxService.haversineKm(
                        widget.repo.originLat!,
                        widget.repo.originLng!,
                        firstPlace.lat,
                        firstPlace.lng,
                      )
                    : null;
                return InkWell(
                  onTap: () {
                    final loaded = widget.repo.applySuggestedRoute(route);
                    setState(() {});
                    final missing = route.destinationIds.length - loaded;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          missing > 0
                              ? 'Loaded $loaded of ${route.destinationIds.length} places from "${route.title}" ($missing not in the catalog right now). Tap Plan trip below to set your days.'
                              : 'Loaded $loaded places from "${route.title}". Tap Plan trip below to set your days.',
                        ),
                        backgroundColor: LakbayColors.tealDeep,
                      ),
                    );
                  },
                  borderRadius: BorderRadius.circular(18),
                  child: Container(
                    width: 248,
                    padding: const EdgeInsets.all(14),
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
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: LakbayColors.primaryLight,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                route.suggestedDays == null
                                    ? '${places.length} places'
                                    : '${places.length} places • ~${route.suggestedDays}d',
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                  color: LakbayColors.primaryDark,
                                ),
                              ),
                            ),
                            const Spacer(),
                            const Icon(
                              Icons.route_rounded,
                              size: 16,
                              color: LakbayColors.primary,
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          route.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: 'FigGrotesk',
                            fontWeight: FontWeight.w700,
                            fontSize: 13.5,
                            color: LakbayColors.tealDeep,
                            height: 1.2,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          firstPlace == null
                              ? 'Tap to load stops →'
                              : awayKm == null
                                  ? 'Starts at ${firstPlace.title} · Use stops →'
                                  : 'First stop ~${awayKm.round()} km from you · Use stops →',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: LakbayColors.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeroCard(ExploreTrip trip) {
    final isBucketed = widget.repo.isTripInBucketList(trip.id);
    final inTray = widget.repo.isInTripBuilder(trip.id);
    return InkWell(
      onTap: () => _openExploreTrip(trip),
      borderRadius: BorderRadius.circular(24),
      child: Container(
        height: 235,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color: LakbayColors.tealDeep.withValues(alpha: 0.16),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            LakbayNetworkOrAssetImage(
              networkUrl: trip.hasRemoteThumbnail ? trip.thumbnailUrl : null,
              assetPath: trip.localAssetPath,
              fallbackAsset: widget.repo.currentBackdrop.localAssetPath,
            ),
            Container(
              decoration: const BoxDecoration(
                gradient: LakbayColors.darkOverlayGradient,
              ),
            ),
            Positioned(
              top: 14,
              left: 14,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                decoration: BoxDecoration(
                  gradient: LakbayColors.brandGradient,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '★ ${trip.tag ?? "DAVAO SIGNATURE"}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 11,
                    letterSpacing: 0.6,
                  ),
                ),
              ),
            ),
            Positioned(
              top: 10,
              right: 10,
              child: IconButton.filled(
                style: IconButton.styleFrom(
                  backgroundColor: Colors.black.withValues(alpha: 0.35),
                ),
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
            ),
            Positioned(
              left: 18,
              right: 18,
              bottom: 18,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    trip.title,
                    style: const TextStyle(
                      fontFamily: 'FigGrotesk',
                      fontWeight: FontWeight.w700,
                      fontSize: 22,
                      color: Colors.white,
                      height: 1.15,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${trip.municipalityLabel} • ${trip.tag ?? "Place"} • ${trip.stayDurationLabel}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.9),
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      InkWell(
                        onTap: () => setState(
                          () => widget.repo.toggleTripBuilderStop(trip),
                        ),
                        borderRadius: BorderRadius.circular(20),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color: inTray ? LakbayColors.primary : Colors.white,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            inTray ? '✓ In trip' : '＋ Add to trip',
                            style: TextStyle(
                              fontFamily: 'FigGrotesk',
                              fontWeight: FontWeight.w700,
                              fontSize: 12,
                              color:
                                  inTray ? Colors.white : LakbayColors.tealDeep,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDiscoverySectionCarousel(DiscoverySection section) {
    final trips = widget.repo.tripsForSection(section);
    if (trips.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  section.title,
                  style: const TextStyle(
                    fontFamily: 'FigGrotesk',
                    fontWeight: FontWeight.w700,
                    fontSize: 21,
                    color: LakbayColors.tealDeep,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  section.subtitle,
                  style: const TextStyle(
                    fontSize: 13,
                    color: LakbayColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 245,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              scrollDirection: Axis.horizontal,
              itemCount: trips.length,
              separatorBuilder: (_, _) => const SizedBox(width: 14),
              itemBuilder: (context, index) {
                final trip = trips[index];
                final isBucketed = widget.repo.isTripInBucketList(trip.id);
                return InkWell(
                  onTap: () => _openExploreTrip(trip),
                  borderRadius: BorderRadius.circular(20),
                  child: Container(
                    width: 210,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: LakbayColors.cardBorder),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              LakbayNetworkOrAssetImage(
                                networkUrl: trip.hasRemoteThumbnail
                                    ? trip.thumbnailUrl
                                    : null,
                                assetPath: trip.localAssetPath,
                              ),
                              Positioned(
                                top: 8,
                                left: 8,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: Colors.black.withValues(alpha: 0.6),
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  child: Text(
                                    '${trip.tag ?? "Place"} • ${trip.stayDurationLabel}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ),
                              Positioned(
                                top: 4,
                                right: 4,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      tooltip: widget.repo.isInTripBuilder(trip.id)
                                          ? 'Remove from Trip Builder'
                                          : 'Add to Multi-Stop Route',
                                      style: IconButton.styleFrom(
                                        backgroundColor: widget.repo
                                                .isInTripBuilder(trip.id)
                                            ? LakbayColors.primary
                                            : Colors.black.withValues(alpha: 0.45),
                                        padding: EdgeInsets.zero,
                                        minimumSize: const Size(30, 30),
                                      ),
                                      onPressed: () {
                                        widget.repo.toggleTripBuilderStop(trip);
                                        setState(() {});
                                      },
                                      icon: Icon(
                                        widget.repo.isInTripBuilder(trip.id)
                                            ? Icons.check_rounded
                                            : Icons.add_rounded,
                                        color: Colors.white,
                                        size: 18,
                                      ),
                                    ),
                                    const SizedBox(width: 2),
                                    IconButton(
                                      onPressed: () {
                                        widget.repo.toggleBucketListTrip(trip.id);
                                        setState(() {});
                                      },
                                      icon: Icon(
                                        isBucketed
                                            ? Icons.favorite_rounded
                                            : Icons.favorite_border_rounded,
                                        color: isBucketed
                                            ? LakbayColors.primary
                                            : Colors.white,
                                        size: 20,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                trip.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontFamily: 'FigGrotesk',
                                  fontWeight: FontWeight.w700,
                                  fontSize: 14.5,
                                  height: 1.2,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      trip.municipalityLabel,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 11.5,
                                        color: LakbayColors.textSecondary,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  InkWell(
                                    onTap: () => setState(
                                      () => widget.repo
                                          .toggleTripBuilderStop(trip),
                                    ),
                                    borderRadius: BorderRadius.circular(12),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 4,
                                      ),
                                      decoration: BoxDecoration(
                                        color: widget.repo
                                                .isInTripBuilder(trip.id)
                                            ? LakbayColors.primary
                                            : LakbayColors.primaryLight,
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: Text(
                                        widget.repo.isInTripBuilder(trip.id)
                                            ? '✓ Added'
                                            : '＋ Add',
                                        style: TextStyle(
                                          fontFamily: 'FigGrotesk',
                                          fontWeight: FontWeight.w700,
                                          fontSize: 11.5,
                                          color: widget.repo
                                                  .isInTripBuilder(trip.id)
                                              ? Colors.white
                                              : LakbayColors.primaryDark,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchResultsSliver() {
    final lower = _searchQuery.toLowerCase();
    final matchedTrips = widget.repo.allTrips
        .where((t) =>
            t.title.toLowerCase().contains(lower) ||
            t.regionName.toLowerCase().contains(lower))
        .toList();

    final matchedCities = widget.repo.cityDescriptions
        .where((c) =>
            c.city.toLowerCase().contains(lower) ||
            c.country.toLowerCase().contains(lower))
        .toList();

    if (matchedTrips.isEmpty && matchedCities.isEmpty) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            children: [
              const Icon(Icons.travel_explore_rounded,
                  size: 48, color: LakbayColors.primary),
              const SizedBox(height: 12),
              Text(
                'Generate a custom "$_searchQuery" Davao trip?',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontFamily: 'FigGrotesk',
                  fontWeight: FontWeight.w700,
                  fontSize: 18,
                ),
              ),
              const SizedBox(height: 12),
              ElevatedButton.icon(
                onPressed: () => _openCityPlanSheet(_searchQuery),
                icon: const Icon(Icons.route_rounded),
                label: Text('Plan a trip to $_searchQuery'),
              ),
            ],
          ),
        ),
      );
    }

    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      sliver: SliverList.separated(
        itemCount: matchedTrips.length + matchedCities.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          if (index < matchedTrips.length) {
            final trip = matchedTrips[index];
            return ListTile(
              onTap: () => _openExploreTrip(trip),
              tileColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: const BorderSide(color: LakbayColors.cardBorder),
              ),
              contentPadding: const EdgeInsets.all(10),
              leading: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: LakbayNetworkOrAssetImage(
                  networkUrl: trip.hasRemoteThumbnail ? trip.thumbnailUrl : null,
                  assetPath: trip.localAssetPath,
                  width: 64,
                  height: 64,
                ),
              ),
              title: Text(
                trip.title,
                style: const TextStyle(
                  fontFamily: 'FigGrotesk',
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                ),
              ),
              subtitle: Text(
                '${trip.municipalityLabel} • ${trip.tag ?? "Place"} • ${trip.stayDurationLabel}',
                style: const TextStyle(fontSize: 12.5),
              ),
              trailing: TextButton(
                onPressed: () =>
                    setState(() => widget.repo.toggleTripBuilderStop(trip)),
                child: Text(
                  widget.repo.isInTripBuilder(trip.id)
                      ? '✓ Added'
                      : '＋ Add to trip',
                ),
              ),
            );
          } else {
            final city = matchedCities[index - matchedTrips.length];
            return ListTile(
              onTap: () => _openCityEncyclopediaSheet(city),
              tileColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: const BorderSide(color: LakbayColors.cardBorder),
              ),
              leading: const CircleAvatar(
                backgroundColor: LakbayColors.primaryLight,
                child: Icon(Icons.place_rounded,
                    color: LakbayColors.primary),
              ),
              title: Text(
                city.city,
                style: const TextStyle(
                  fontFamily: 'FigGrotesk',
                  fontWeight: FontWeight.w700,
                ),
              ),
              subtitle: Text(city.country),
              trailing: const Text(
                'Guide →',
                style: TextStyle(
                  color: LakbayColors.tealAccent,
                  fontWeight: FontWeight.w700,
                ),
              ),
            );
          }
        },
      ),
    );
  }

  Widget _buildCityGuidesSliver({int? limit}) {
    final list = limit != null
        ? widget.repo.cityDescriptions.take(limit).toList()
        : widget.repo.cityDescriptions;

    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      sliver: SliverList.separated(
        itemCount: list.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          final cityObj = list[index];
          final inBucket = widget.repo.isCityInBucketList(cityObj.city);
          return InkWell(
            onTap: () => _openCityEncyclopediaSheet(cityObj),
            borderRadius: BorderRadius.circular(18),
            child: Container(
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
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: LakbayColors.primaryLight,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(Icons.place_rounded,
                            color: LakbayColors.primary, size: 18),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              cityObj.city,
                              style: const TextStyle(
                                fontFamily: 'FigGrotesk',
                                fontWeight: FontWeight.w700,
                                fontSize: 16.5,
                              ),
                            ),
                            Text(
                              cityObj.country,
                              style: const TextStyle(
                                fontSize: 12,
                                color: LakbayColors.tealAccent,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Image.asset(
                        'assets/png/weather/${cityObj.wmoWeatherCode}.png',
                        width: 24,
                        height: 24,
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      ),
                      IconButton(
                        tooltip: 'Save to Bucket List',
                        onPressed: () {
                          widget.repo.toggleBucketListCity(cityObj.city);
                          setState(() {});
                        },
                        icon: Icon(
                          inBucket
                              ? Icons.favorite_rounded
                              : Icons.favorite_border_rounded,
                          color: inBucket
                              ? LakbayColors.primary
                              : LakbayColors.textMuted,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    cityObj.description,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      height: 1.45,
                      color: LakbayColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Tap for full Davao guide',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: LakbayColors.textMuted,
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () => _openCityPlanSheet(cityObj.city),
                        icon: const Icon(Icons.route_rounded, size: 16),
                        label: const Text('Plan Trip'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _openTopPlacesSheet() {
    final repo = widget.repo;
    // Start from the traveler's saved preferences; nothing is pre-selected.
    final selected = <String>{...repo.selectedVibes};
    final budgetCtrl = TextEditingController();
    bool loading = false;
    String? message;
    TopPlacesResult? result;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (sheetCtx, setSheetState) {
            Future<void> runMatch() async {
              if (!repo.isSignedIn || repo.authSession == null) {
                setSheetState(() => message =
                    'Sign in to get matches ranked for you.');
                return;
              }
              setSheetState(() {
                loading = true;
                message = null;
              });
              final live = await repo.apiCatalog.fetchTopPlaces(
                repo.authSession!.accessToken,
                interests: selected.toList(),
                travelMode: repo.preferredTravelMode,
                // Empty means no budget limit; no amount is assumed.
                totalBudgetPhp: double.tryParse(budgetCtrl.text.trim()),
                originLat: repo.userLat,
                originLng: repo.userLng,
              );
              if (!sheetCtx.mounted) return;
              setSheetState(() {
                result = live;
                message = live == null
                    ? "Lakbay couldn't rank places right now. Please try again."
                    : null;
                loading = false;
              });
            }

            return DraggableScrollableSheet(
              expand: false,
              initialChildSize: 0.82,
              maxChildSize: 0.94,
              builder: (_, scrollCtrl) => ListView(
                controller: scrollCtrl,
                padding: EdgeInsets.fromLTRB(
                  20,
                  16,
                  20,
                  MediaQuery.of(sheetCtx).viewInsets.bottom + 24,
                ),
                children: [
                  const Text(
                    'Personalized Top 5',
                    style: TextStyle(
                      fontFamily: 'FigGrotesk',
                      fontSize: 21,
                      fontWeight: FontWeight.w800,
                      color: LakbayColors.tealDeep,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'The places that best fit what you like, your budget and where you start.',
                    style: TextStyle(fontSize: 13, color: LakbayColors.textSecondary),
                  ),
                  const SizedBox(height: 10),
                  if (repo.preferenceGroups.isEmpty)
                    const Text(
                      'Preferences load from Lakbay when you are online.',
                      style: TextStyle(
                        fontSize: 12.5,
                        color: LakbayColors.textSecondary,
                      ),
                    )
                  else ...[
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final group in repo.preferenceGroups)
                          FilterChip(
                            label: Text(group.label),
                            selected: selected.contains(group.key),
                            onSelected: (sel) => setSheetState(() {
                              if (sel) {
                                selected.add(group.key);
                              } else {
                                selected.remove(group.key);
                                selected.removeAll(
                                  group.subtypes.map((s) => s.key),
                                );
                              }
                            }),
                          ),
                      ],
                    ),
                    for (final group in repo.preferenceGroups)
                      if (selected.contains(group.key) &&
                          group.subtypes.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final sub in group.subtypes)
                              FilterChip(
                                label: Text(sub.label),
                                visualDensity: VisualDensity.compact,
                                selected: selected.contains(sub.key),
                                onSelected: (sel) => setSheetState(() {
                                  if (sel) {
                                    selected.add(sub.key);
                                  } else {
                                    selected.remove(sub.key);
                                  }
                                }),
                              ),
                          ],
                        ),
                      ],
                  ],
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: budgetCtrl,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            labelText: 'Budget per trip, ₱ (optional)',
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      ElevatedButton.icon(
                        onPressed: loading ? null : runMatch,
                        icon: const Icon(Icons.auto_awesome_rounded, size: 18),
                        label: const Text('Rank Top 5'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  if (loading)
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.all(20),
                        child: CircularProgressIndicator(),
                      ),
                    )
                  else ...[
                    if (message != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          message!,
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: LakbayColors.textSecondary,
                          ),
                        ),
                      ),
                    if (result != null) ...[
                      if (result!.items.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 12),
                          child: Text(
                            'No places match yet. Try another preference.',
                            style: TextStyle(color: LakbayColors.textSecondary),
                          ),
                        ),
                      for (final item in result!.items)
                        Card(
                          margin: const EdgeInsets.only(bottom: 10),
                          child: ListTile(
                            leading: CircleAvatar(
                              backgroundColor: LakbayColors.tealDeep,
                              foregroundColor: Colors.white,
                              child: Text('#${item.rank}'),
                            ),
                            title: Text(item.name),
                            subtitle: Text(
                              [
                                [
                                  if (item.district != null) item.district!,
                                  'Match ${item.score.toStringAsFixed(1)}/100',
                                ].join(' • '),
                                ...item.reasons.take(2),
                              ].join('\n'),
                              style: TextStyle(
                                color: item.matchTier > 1
                                    ? const Color(0xFFB45309)
                                    : null,
                              ),
                            ),
                            isThreeLine: true,
                            trailing: const Icon(Icons.chevron_right_rounded),
                            onTap: () {
                              Navigator.of(ctx).pop();
                              // The real place, not a generated template trip.
                              final place =
                                  repo.resolveExploreTripForRecommendation(item);
                              Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => TripDetailScreen(
                                    trip: repo.buildDetailedItineraryFromExplore(
                                      place,
                                    ),
                                    repo: repo,
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                    ],
                  ],
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _MultiStopPlanSheet extends StatefulWidget {
  final TravelRepository repo;
  final VoidCallback onStopsChanged;
  final ValueChanged<ItineraryTrip> onTripBuilt;
  final String? aiFallbackPrompt;

  const _MultiStopPlanSheet({
    required this.repo,
    required this.onStopsChanged,
    required this.onTripBuilt,
    this.aiFallbackPrompt,
  });

  @override
  State<_MultiStopPlanSheet> createState() => _MultiStopPlanSheetState();
}

class _MultiStopPlanSheetState extends State<_MultiStopPlanSheet> {
  late int _days;
  bool _daysManuallyEdited = false;
  int? _travelers;
  bool _pruneOptionalToFit = false;
  bool _isGenerating = false;
  late GeoPoint _selectedHotel;
  late RoutePlanResult _preview;
  Timer? _debounceTimer;

  @override
  void initState() {
    super.initState();
    _selectedHotel = widget.repo.builderHotelOrigin;
    _days = widget.repo.suggestedTripBuilderDays().clamp(1, 14);
    _preview = _computePreview();
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    super.dispose();
  }

  RoutePlanResult _computePreview() {
    return widget.repo.previewTripBuilderPlan(
      days: _days,
      hotelOrigin: _selectedHotel,
      pruneOptionalToFit: _pruneOptionalToFit,
    );
  }

  void _scheduleRecalc({bool snapDaysToSuggested = false}) {
    if (snapDaysToSuggested && !_daysManuallyEdited) {
      _days = widget.repo.suggestedTripBuilderDays().clamp(1, 14);
    }
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      setState(() {
        _preview = _computePreview();
      });
    });
    // Also update preview synchronously when few stops (microseconds) so
    // immediate UI feedback stays responsive for both touch and widget tests.
    setState(() {
      _preview = _computePreview();
    });
  }

  String _formatHours(double hours) {
    final totalMin = (hours * 60).round();
    if (totalMin < 60) return '${totalMin}m';
    final h = totalMin ~/ 60;
    final m = totalMin % 60;
    return m == 0 ? '${h}h' : '${h}h ${m}m';
  }

  @override
  Widget build(BuildContext context) {
    final stops = widget.repo.tripBuilderStops;
    final startMode = widget.repo.builderStartMode;
    final pace = widget.repo.builderPace;
    final roundtrip = widget.repo.builderRoundtrip;
    final lockedId = widget.repo.builderLockedFirstStopId;
    final suggestedDays = _preview.suggestedDays.clamp(1, 14);
    final hasOptionalStops =
        stops.any((s) => !widget.repo.isStopMustVisit(s.id));
    final overloadedDays =
        _preview.days.where((d) => d.isOverloaded).toList();
    final totalBudgetHrs = _preview.days.fold<double>(
      0.0,
      (sum, d) => sum + (d.isContinuationDay ? 0.0 : d.totalHours),
    );
    final savedKm = _preview.savingsVsInput.distanceSavedKm;
    final savedPct = _preview.savingsVsInput.distanceSavedPercent;

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.88,
        ),
        child: SingleChildScrollView(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 18,
            bottom: MediaQuery.of(context).viewInsets.bottom + 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.route_rounded, color: LakbayColors.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Plan Your Route',
                          style: TextStyle(
                            fontFamily: 'FigGrotesk',
                            fontWeight: FontWeight.w800,
                            fontSize: 20,
                            color: LakbayColors.tealDeep,
                          ),
                        ),
                        Text(
                          '${stops.length} ${stops.length == 1 ? 'place' : 'places'} · You choose the days & pace',
                          style: const TextStyle(
                            fontSize: 12,
                            color: LakbayColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: () {
                      widget.repo.clearTripBuilder();
                      Navigator.of(context).pop();
                      widget.onStopsChanged();
                    },
                    child: const Text('Clear'),
                  ),
                ],
              ),
              const SizedBox(height: 10),

              // Picked places list with Remove, Lock as First, Must-Visit toggle.
              for (var i = 0; i < stops.length; i++) ...[
                () {
                  final stop = stops[i];
                  final isLocked = lockedId == stop.id;
                  final isMustVisit = widget.repo.isStopMustVisit(stop.id);
                  final cleanName = stop.title.split('—').first.trim();
                  return Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: isLocked
                          ? LakbayColors.tealWash.withValues(alpha: 0.45)
                          : LakbayColors.canvasBg,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: isLocked
                            ? LakbayColors.primary
                            : LakbayColors.cardBorder,
                      ),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 24,
                          height: 24,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: isLocked
                                ? LakbayColors.primary
                                : LakbayColors.tealDeep,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            isLocked ? '1' : '${i + 1}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                              fontSize: 11,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                cleanName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 13.5,
                                  color: LakbayColors.tealDeep,
                                ),
                              ),
                              Text(
                                '${stop.regionName} · ${stop.stayDurationLabel}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 11.5,
                                  color: LakbayColors.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: isLocked
                              ? 'Unlock start stop'
                              : 'Lock as first stop',
                          visualDensity: VisualDensity.compact,
                          onPressed: () {
                            widget.repo.toggleLockedFirstStop(stop.id);
                            _scheduleRecalc();
                          },
                          icon: Icon(
                            isLocked
                                ? Icons.push_pin_rounded
                                : Icons.push_pin_outlined,
                            size: 18,
                            color: isLocked
                                ? LakbayColors.primary
                                : LakbayColors.textMuted,
                          ),
                        ),
                        InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: isLocked
                              ? null
                              : () {
                                  widget.repo.toggleStopMustVisit(stop.id);
                                  _scheduleRecalc();
                                },
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: isMustVisit
                                  ? LakbayColors.tealDeep
                                  : Colors.white,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: isMustVisit
                                    ? LakbayColors.tealDeep
                                    : LakbayColors.cardBorder,
                              ),
                            ),
                            child: Text(
                              isMustVisit ? 'Must-visit' : 'Optional',
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w700,
                                color: isMustVisit
                                    ? Colors.white
                                    : LakbayColors.textSecondary,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 2),
                        IconButton(
                          tooltip: 'Remove place',
                          visualDensity: VisualDensity.compact,
                          onPressed: () {
                            widget.repo.removeTripBuilderStop(stop.id);
                            widget.onStopsChanged();
                            if (widget.repo.tripBuilderStops.isEmpty) {
                              Navigator.of(context).pop();
                              return;
                            }
                            _scheduleRecalc(snapDaysToSuggested: true);
                          },
                          icon: const Icon(
                            Icons.close_rounded,
                            size: 18,
                            color: LakbayColors.textMuted,
                          ),
                        ),
                      ],
                    ),
                  );
                }(),
              ],
              const SizedBox(height: 8),

              // Start from / End roundtrip selector.
              const Text(
                'Start from',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                  color: LakbayColors.tealDeep,
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  ChoiceChip(
                    avatar: const Icon(Icons.my_location_rounded, size: 15),
                    label: const Text('My location'),
                    selected: startMode == 'gps',
                    onSelected: (_) {
                      widget.repo.setBuilderStartMode('gps');
                      _scheduleRecalc();
                    },
                  ),
                  ChoiceChip(
                    avatar: const Icon(Icons.hotel_rounded, size: 15),
                    label: const Text('Hotel'),
                    selected: startMode == 'hotel',
                    onSelected: (_) {
                      widget.repo.setBuilderStartMode(
                        'hotel',
                        hotelOrigin: _selectedHotel,
                      );
                      _scheduleRecalc();
                    },
                  ),
                  ChoiceChip(
                    avatar: const Icon(Icons.place_rounded, size: 15),
                    label: const Text('First place'),
                    selected: startMode == 'first_stop',
                    onSelected: (_) {
                      widget.repo.setBuilderStartMode('first_stop');
                      _scheduleRecalc();
                    },
                  ),
                ],
              ),
              if (startMode == 'gps' && widget.repo.originLat == null)
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text(
                    'GPS location not locked yet — ordering will begin at your first stop.',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: LakbayColors.textSecondary,
                    ),
                  ),
                ),
              if (startMode == 'hotel')
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: DropdownButtonFormField<GeoPoint>(
                    initialValue: _selectedHotel,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Departure / Return Hotel',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    items: TravelRepository.davaoHotelPresets
                        .map(
                          (h) => DropdownMenuItem<GeoPoint>(
                            value: h,
                            child: Text(
                              h.label ?? 'Davao Hotel',
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value == null) return;
                      _selectedHotel = value;
                      widget.repo.setBuilderStartMode(
                        'hotel',
                        hotelOrigin: value,
                      );
                      _scheduleRecalc();
                    },
                  ),
                ),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text(
                  'Return to start (roundtrip)',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  startMode == 'first_stop'
                      ? 'Pick My location or Hotel above to return to origin'
                      : (roundtrip
                          ? 'Route ends back at your starting point'
                          : 'End at the final destination'),
                  style: const TextStyle(fontSize: 11.5),
                ),
                value: startMode != 'first_stop' && roundtrip,
                onChanged: startMode == 'first_stop'
                    ? null
                    : (v) {
                        widget.repo.setBuilderRoundtrip(v);
                        _scheduleRecalc();
                      },
              ),
              const Divider(height: 16),

              // Days stepper (1-14) with Suggested badge.
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Days: $_days',
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 15,
                            color: LakbayColors.tealDeep,
                          ),
                        ),
                        const SizedBox(height: 2),
                        GestureDetector(
                          onTap: () {
                            _daysManuallyEdited = false;
                            _days = suggestedDays;
                            _scheduleRecalc();
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: LakbayColors.tealWash,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              'Suggested: $suggestedDays ${suggestedDays == 1 ? 'day' : 'days'}',
                              style: const TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w700,
                                color: LakbayColors.tealDeep,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Fewer days',
                    onPressed: _days > 1
                        ? () {
                            _daysManuallyEdited = true;
                            _days--;
                            _scheduleRecalc();
                          }
                        : null,
                    icon: const Icon(Icons.remove_circle_outline),
                  ),
                  IconButton(
                    tooltip: 'More days',
                    onPressed: _days < 14
                        ? () {
                            _daysManuallyEdited = true;
                            _days++;
                            _scheduleRecalc();
                          }
                        : null,
                    icon: const Icon(Icons.add_circle_outline),
                  ),
                ],
              ),
              const SizedBox(height: 8),

              // Pace segmented selector.
              const Text(
                'Pace',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                  color: LakbayColors.tealDeep,
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: TripPace.values
                    .map(
                      (p) => ChoiceChip(
                        label: Text(
                          '${p.label} (~${p.hoursPerDay.toStringAsFixed(0)}h)',
                        ),
                        selected: pace == p,
                        onSelected: (_) {
                          widget.repo.setBuilderPace(p);
                          _scheduleRecalc(snapDaysToSuggested: true);
                        },
                      ),
                    )
                    .toList(),
              ),
              if (hasOptionalStops)
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text(
                    'Skip optional stops if over pace',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  value: _pruneOptionalToFit,
                  onChanged: (v) {
                    _pruneOptionalToFit = v;
                    _scheduleRecalc();
                  },
                ),

              // Travelers compact row.
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _travelers == null ? 'Travelers: not set' : 'Travelers: $_travelers',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  IconButton(
                    onPressed: _travelers != null
                        ? () => setState(
                            () => _travelers = _travelers! > 1 ? _travelers! - 1 : null)
                        : null,
                    icon: const Icon(Icons.remove_circle_outline),
                  ),
                  IconButton(
                    onPressed: (_travelers ?? 0) < 15
                        ? () => setState(() => _travelers = (_travelers ?? 0) + 1)
                        : null,
                    icon: const Icon(Icons.add_circle_outline),
                  ),
                ],
              ),
              const SizedBox(height: 8),

              // Live route summary & overload/savings feedback.
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: overloadedDays.isNotEmpty
                      ? Colors.amber.shade50
                      : LakbayColors.tealWash.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: overloadedDays.isNotEmpty
                        ? Colors.amber.shade300
                        : LakbayColors.cardBorder,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${_preview.totalDistanceKm.toStringAsFixed(0)} km · ${_formatHours(totalBudgetHrs)} active · Suggested: $suggestedDays ${suggestedDays == 1 ? 'day' : 'days'}',
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 13,
                        color: LakbayColors.tealDeep,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      savedKm >= 0.5 && savedPct >= 1.0
                          ? 'Visit order optimized: ${_preview.savingsVsInput.baselineDistanceKm.toStringAsFixed(0)} km → ${_preview.savingsVsInput.optimizedDistanceKm.toStringAsFixed(0)} km (−${savedPct.toStringAsFixed(0)}%) · ${_preview.orderMethod == 'exact_held_karp' ? 'Exact Held-Karp' : 'NN + 2-opt'}'
                          : 'Order method: ${_preview.orderMethod == 'exact_held_karp' ? 'Exact Held-Karp' : 'Adaptive NN + 2-opt'}',
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: LakbayColors.textSecondary,
                      ),
                    ),
                    if (_preview.warnings.isNotEmpty) ...[
                      const SizedBox(height: 5),
                      Text(
                        _preview.warnings.first,
                        style: const TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: Colors.deepOrange,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 12),
              ElevatedButton.icon(
                onPressed: _isGenerating || stops.isEmpty
                    ? null
                    : () async {
                        setState(() => _isGenerating = true);
                        final built =
                            (await widget.repo.buildMultiStopExploreTrip(
                          daysCount: _days,
                          travelers: _travelers,
                          pace: pace,
                          startMode: startMode,
                          hotelOrigin: _selectedHotel,
                          roundtrip: startMode != 'first_stop' && roundtrip,
                          pruneOptionalToFit: _pruneOptionalToFit,
                        ))
                                .copyWith(
                          isCatalogFallback: true,
                          expertName: 'Lakbay Catalog Planner (No AI)',
                        );
                        if (!context.mounted) return;
                        Navigator.of(context).pop();
                        widget.onTripBuilt(built);
                      },
                icon: _isGenerating
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.alt_route_rounded),
                label: Text(
                  _isGenerating
                      ? 'Optimizing & Refining Route...'
                      : 'Optimize & Create $_days-Day Trip',
                ),
              ),
              if (stops.isNotEmpty) ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _isGenerating
                      ? null
                      : () {
                          final names = stops
                              .take(5)
                              .map((s) => s.title.split('—').first.trim())
                              .join(', ');
                          final prompt = widget.aiFallbackPrompt ??
                              'Plan a $_days-day trip${_travelers == null ? '' : ' for $_travelers travelers'} visiting $names.';
                          Navigator.of(context).pop();
                          widget.repo.planInChat(prompt);
                        },
                  icon: const Icon(Icons.auto_awesome_rounded, size: 17),
                  label: const Text('Improve with AI'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
