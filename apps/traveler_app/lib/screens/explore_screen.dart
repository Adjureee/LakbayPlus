import 'package:flutter/material.dart';
import '../models/travel_models.dart';
import '../services/mapbox_service.dart';
import '../services/travel_repository.dart';
import '../theme/lakbay_theme.dart';
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
                final trip = widget.repo.generateCustomTrip(
                  destination: '${cityObj.city}, ${cityObj.country}',
                  daysCount: 4,
                  vibe: 'Davao Region Explorer',
                );
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) =>
                        TripDetailScreen(trip: trip, repo: widget.repo),
                  ),
                );
              },
              icon: const Icon(Icons.auto_awesome_rounded),
              label: Text('Build 4-Day ${cityObj.city} Itinerary'),
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
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Discover',
                              style: TextStyle(
                                fontFamily: 'FigGrotesk',
                                fontWeight: FontWeight.w800,
                                fontSize: 28,
                                color: LakbayColors.tealDeep,
                              ),
                            ),
                            SizedBox(height: 2),
                            Text(
                              'Region XI routes, Mapbox pins & local destination guides',
                              style: TextStyle(
                                fontSize: 12.5,
                                color: LakbayColors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: 'Sync Live Catalog',
                        onPressed: widget.repo.isSyncingCatalog
                            ? null
                            : () async {
                                final count =
                                    await widget.repo.syncCatalogWithApi();
                                if (!context.mounted) return;
                                setState(() {});
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      count > 0
                                          ? 'Synced $count live Region XI destination(s) from Lakbay+ Admin.'
                                          : 'Catalog refreshed (offline curated mode active).',
                                    ),
                                    backgroundColor: LakbayColors.tealDeep,
                                  ),
                                );
                              },
                        icon: widget.repo.isSyncingCatalog
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.sync_rounded),
                      ),
                      const SizedBox(width: 4),
                      FilledButton.tonalIcon(
                        onPressed: () {
                          setState(() {
                            _isMapView = !_isMapView;
                            if (_isMapView && _selectedMapTrip == null) {
                              final list = _filteredMapTrips();
                              if (list.isNotEmpty) {
                                _selectedMapTrip = list.first;
                              }
                            }
                          });
                        },
                        style: FilledButton.styleFrom(
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
                          size: 17,
                        ),
                        label: Text(
                          _isMapView ? 'List View' : 'Mapbox',
                          style: const TextStyle(
                            fontFamily: 'FigGrotesk',
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      PopupMenuButton<String>(
                        onSelected: (curr) {
                          widget.repo.setCurrency(curr);
                          setState(() {});
                        },
                        itemBuilder: (_) =>
                            const ['PHP', 'USD', 'EUR', 'GBP', 'AUD', 'JPY']
                                .map(
                                  (c) => PopupMenuItem(
                                    value: c,
                                    child: Text(c),
                                  ),
                                )
                                .toList(),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 8),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: LakbayColors.cardBorder),
                          ),
                          child: Text(
                            widget.repo.currency,
                            style: const TextStyle(
                              fontFamily: 'FigGrotesk',
                              fontWeight: FontWeight.w700,
                              fontSize: 12.5,
                            ),
                          ),
                        ),
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
                  : CustomScrollView(
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
                                childAspectRatio: 0.78,
                              ),
                              delegate: SliverChildBuilderDelegate(
                                (context, idx) {
                                  final trip = _filteredMapTrips()[idx];
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
                                          Image.asset(
                                            trip.localAssetPath,
                                            fit: BoxFit.cover,
                                            errorBuilder: (_, _, _) =>
                                                Container(
                                              decoration: const BoxDecoration(
                                                gradient:
                                                    LakbayColors.deepTealGradient,
                                              ),
                                            ),
                                          ),
                                          Container(
                                            decoration: const BoxDecoration(
                                              gradient: LinearGradient(
                                                colors: [
                                                  Color(0x11000000),
                                                  Color(0xCC071E26),
                                                ],
                                                begin: Alignment.topCenter,
                                                end: Alignment.bottomCenter,
                                              ),
                                            ),
                                          ),
                                          Positioned(
                                            top: 10,
                                            left: 10,
                                            child: Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                horizontal: 10,
                                                vertical: 4,
                                              ),
                                              decoration: BoxDecoration(
                                                color: LakbayColors.primaryLight,
                                                borderRadius:
                                                    BorderRadius.circular(14),
                                              ),
                                              child: Text(
                                                '${trip.days} days',
                                                style: const TextStyle(
                                                  fontSize: 11.5,
                                                  fontWeight: FontWeight.w800,
                                                  color: LakbayColors.primaryDark,
                                                ),
                                              ),
                                            ),
                                          ),
                                          Positioned(
                                            left: 12,
                                            right: 12,
                                            bottom: 12,
                                            child: Text(
                                              trip.title,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontFamily: 'FigGrotesk',
                                                fontSize: 14.5,
                                                fontWeight: FontWeight.w700,
                                                color: Colors.white,
                                                height: 1.2,
                                              ),
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
          ],
        ),
      ),
    );
  }

  Widget _buildInteractiveMapboxExplorer() {
    final trips = _filteredMapTrips();
    final activeTrip =
        _selectedMapTrip ?? (trips.isNotEmpty ? trips.first : null);
    final markers = trips
        .map(
          (t) => LakbayMapMarker(
            id: t.id,
            lat: t.lat,
            lng: t.lng,
            badgeText: '${t.days}d • ${widget.repo.formatPrice(t.estimatedPriceUsd)}',
            title: t.title,
            subtitle: t.regionName,
            isPrimary: activeTrip?.id == t.id,
          ),
        )
        .toList();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Stack(
        children: [
          LakbayMapboxMap(
            repo: widget.repo,
            initialLat: activeTrip?.lat ?? MapboxService.davaoCenterLat,
            initialLng: activeTrip?.lng ?? MapboxService.davaoCenterLng,
            initialZoom: 8.3,
            markers: markers,
            selectedMarkerId: activeTrip?.id,
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
              bottom: 34,
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
                        child: Image.asset(
                          activeTrip.localAssetPath,
                          width: 72,
                          height: 72,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => Container(
                            width: 72,
                            height: 72,
                            color: LakbayColors.tealAccent,
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
                              '${activeTrip.days} Days • ${activeTrip.regionName} • Est. ${widget.repo.formatPrice(activeTrip.estimatedPriceUsd)}',
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

  Widget _buildHeroCard(ExploreTrip trip) {
    final isBucketed = widget.repo.isTripInBucketList(trip.id);
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
            trip.hasRemoteThumbnail
                ? Image.network(
                    trip.thumbnailUrl,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => Image.asset(
                      trip.localAssetPath,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => Image.asset(
                        widget.repo.currentBackdrop.localAssetPath,
                        fit: BoxFit.cover,
                      ),
                    ),
                  )
                : Image.asset(
                    trip.localAssetPath,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => Image.asset(
                      widget.repo.currentBackdrop.localAssetPath,
                      fit: BoxFit.cover,
                    ),
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
                      Text(
                        '${trip.days} Days • Region XI • Est. ${widget.repo.formatPrice(trip.estimatedPriceUsd)}',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.9),
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Text(
                          'View Route →',
                          style: TextStyle(
                            fontFamily: 'FigGrotesk',
                            fontWeight: FontWeight.w700,
                            fontSize: 12,
                            color: LakbayColors.tealDeep,
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
                              trip.hasRemoteThumbnail
                                  ? Image.network(
                                      trip.thumbnailUrl,
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, _, _) => Image.asset(
                                        trip.localAssetPath,
                                        fit: BoxFit.cover,
                                        errorBuilder: (_, _, _) => Image.asset(
                                          'assets/home_backdrops/04-thoddoo.jpg',
                                          fit: BoxFit.cover,
                                        ),
                                      ),
                                    )
                                  : Image.asset(
                                      trip.localAssetPath,
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, _, _) => Image.asset(
                                        'assets/home_backdrops/04-thoddoo.jpg',
                                        fit: BoxFit.cover,
                                      ),
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
                                    '${trip.tag ?? "✨"} ${trip.days} Days',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ),
                              Positioned(
                                top: 4,
                                right: 4,
                                child: IconButton(
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
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    trip.regionName,
                                    style: const TextStyle(
                                      fontSize: 11.5,
                                      color: LakbayColors.textSecondary,
                                    ),
                                  ),
                                  Text(
                                    widget.repo
                                        .formatPrice(trip.estimatedPriceUsd),
                                    style: const TextStyle(
                                      fontFamily: 'FigGrotesk',
                                      fontWeight: FontWeight.w700,
                                      fontSize: 13.5,
                                      color: LakbayColors.primary,
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
                onPressed: () {
                  final custom = widget.repo.generateCustomTrip(
                    destination: '$_searchQuery, Davao Region',
                    daysCount: 4,
                    vibe: 'Davao Custom AI Route',
                  );
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) =>
                          TripDetailScreen(trip: custom, repo: widget.repo),
                    ),
                  );
                },
                icon: const Icon(Icons.auto_awesome_rounded),
                label: Text('Build 4-Day $_searchQuery Itinerary'),
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
                child: Image.asset(
                  trip.localAssetPath,
                  width: 64,
                  height: 64,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => Container(
                    width: 64,
                    height: 64,
                    color: LakbayColors.tealAccent,
                  ),
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
                '${trip.days} Days • ${trip.regionName} • Est. ${widget.repo.formatPrice(trip.estimatedPriceUsd)}',
                style: const TextStyle(fontSize: 12.5),
              ),
              trailing: const Icon(Icons.chevron_right_rounded,
                  color: LakbayColors.primary),
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
                        onPressed: () {
                          final trip = widget.repo.generateCustomTrip(
                            destination: '${cityObj.city}, ${cityObj.country}',
                            daysCount: 4,
                            vibe: 'Davao Region Explorer',
                          );
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => TripDetailScreen(
                                  trip: trip, repo: widget.repo),
                            ),
                          );
                        },
                        icon: const Icon(Icons.auto_awesome_rounded, size: 16),
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
}
