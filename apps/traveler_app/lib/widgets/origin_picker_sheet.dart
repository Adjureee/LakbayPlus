import 'package:flutter/material.dart';
import '../services/location_service.dart';
import '../services/mapbox_service.dart';
import '../services/travel_repository.dart';
import 'lakbay_mapbox_widget.dart';

import '../design/lakbay_tokens.dart';
import '../design/lakbay_type.dart';
/// Opens a modal sheet letting the traveler set their starting place via GPS,
/// place search, or map pin without ever assuming Davao City.
Future<bool?> showOriginPickerSheet(
  BuildContext context,
  TravelRepository repo,
) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: LkColors.s1,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
    ),
    builder: (ctx) => _OriginPickerSheetBody(repo: repo),
  );
}

class _OriginPickerSheetBody extends StatefulWidget {
  final TravelRepository repo;

  const _OriginPickerSheetBody({required this.repo});

  @override
  State<_OriginPickerSheetBody> createState() => _OriginPickerSheetBodyState();
}

class _OriginPickerSheetBodyState extends State<_OriginPickerSheetBody> {
  final TextEditingController _searchCtrl = TextEditingController();
  bool _locatingGps = false;
  bool _searching = false;
  bool _showPinMap = false;
  String? _statusNote;
  List<PlaceSuggestion> _results = const [];

  double? _pinnedLat;
  double? _pinnedLng;
  String? _pinnedLabel;
  bool _resolvingPin = false;

  @override
  void initState() {
    super.initState();
    _pinnedLat = widget.repo.originLat;
    _pinnedLng = widget.repo.originLng;
    _pinnedLabel = widget.repo.resolvedOriginLabel;
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _useCurrentGps() async {
    if (_locatingGps) return;
    setState(() {
      _locatingGps = true;
      _statusNote = null;
    });
    final res = await widget.repo.requestAndSaveCurrentLocation();
    if (!mounted) return;
    setState(() => _locatingGps = false);
    if (res.granted && res.lat != null && res.lng != null) {
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _statusNote =
            '${res.statusMessage} Search for a starting place or pin one on the map below.';
      });
    }
  }

  Future<void> _runSearch() async {
    final query = _searchCtrl.text.trim();
    if (query.isEmpty || _searching) return;
    setState(() {
      _searching = true;
      _statusNote = null;
    });
    final hits = await widget.repo.searchStartingPlaces(query);
    if (!mounted) return;
    setState(() {
      _searching = false;
      _results = hits;
      if (hits.isEmpty) {
        _statusNote =
            'No matching places found for "$query". Try another name or pin it on the map.';
      }
    });
  }

  Future<void> _onMapTap(double lat, double lng) async {
    setState(() {
      _pinnedLat = lat;
      _pinnedLng = lng;
      _pinnedLabel = '${lat.toStringAsFixed(3)}°, ${lng.toStringAsFixed(3)}°';
      _resolvingPin = true;
    });
    final label = await widget.repo.reverseGeocodePoint(lat, lng);
    if (!mounted) return;
    setState(() {
      _pinnedLabel = label;
      _resolvingPin = false;
    });
  }

  void _confirmSuggestion(PlaceSuggestion place) {
    widget.repo.setManualOrigin(
      label: place.label,
      lat: place.lat,
      lng: place.lng,
    );
    Navigator.of(context).pop(true);
  }

  void _confirmPinned() {
    final lat = _pinnedLat;
    final lng = _pinnedLng;
    if (lat == null || lng == null) return;
    widget.repo.setManualOrigin(
      label: _pinnedLabel ??
          '${lat.toStringAsFixed(3)}°, ${lng.toStringAsFixed(3)}°',
      lat: lat,
      lng: lng,
    );
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final currentLabel = widget.repo.resolvedOriginLabel;
    final outsideNote = widget.repo.originRegionNote;
    final pinnedOutside = _pinnedLat != null &&
        _pinnedLng != null &&
        !MapboxService.isInsideDavaoRegion(_pinnedLat!, _pinnedLng!);

    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        16,
        20,
        MediaQuery.of(context).viewInsets.bottom + 22,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Set your starting place',
                    style: TextStyle(
                      fontFamily: LkType.displayFamily,
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: LkColors.text,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            Text(
              currentLabel != null
                  ? 'Current start: $currentLabel'
                  : 'Allow GPS, search any city or landmark, or pin your starting spot on the map.',
              style: const TextStyle(
                fontSize: 13,
                color: LkColors.muted,
                fontWeight: FontWeight.w500,
              ),
            ),
            if (outsideNote != null) ...[
              const SizedBox(height: 8),
              _RegionNoteBanner(text: outsideNote),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _locatingGps ? null : _useCurrentGps,
                    icon: _locatingGps
                        ? const SizedBox(
                            width: 15,
                            height: 15,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.my_location_rounded, size: 18),
                    label: Text(
                      _locatingGps ? 'Locating…' : 'Use GPS',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () =>
                        setState(() => _showPinMap = !_showPinMap),
                    icon: const Icon(Icons.push_pin_outlined, size: 18),
                    label: Text(
                      _showPinMap ? 'Hide map pin' : 'Pin on map',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchCtrl,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _runSearch(),
                    decoration: InputDecoration(
                      labelText: 'Search city, airport, or landmark',
                      hintText: 'e.g. Tagum City, Manila, General Santos',
                      prefixIcon: const Icon(Icons.search_rounded),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _searching ? null : _runSearch,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: LkColors.mango,
                    foregroundColor: LkColors.mangoInk,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 14,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: _searching
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text('Search'),
                ),
              ],
            ),
            if (_statusNote != null) ...[
              const SizedBox(height: 10),
              Text(
                _statusNote!,
                style: const TextStyle(
                  fontSize: 12.5,
                  color: LkColors.muted,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            if (_results.isNotEmpty) ...[
              const SizedBox(height: 10),
              for (final item in _results)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(
                    Icons.place_rounded,
                    color: LkColors.lagoon,
                  ),
                  title: Text(
                    item.label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => _confirmSuggestion(item),
                ),
            ],
            if (_showPinMap) ...[
              const SizedBox(height: 12),
              const Text(
                'Tap anywhere on the map to pin your starting place:',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: LkColors.text,
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 220,
                child: LakbayMapboxMap(
                  repo: widget.repo,
                  // Camera falls back to Region XI center only until a pin exists.
                  initialLat: _pinnedLat ?? MapboxService.davaoCenterLat,
                  initialLng: _pinnedLng ?? MapboxService.davaoCenterLng,
                  initialZoom: _pinnedLat != null ? 10.5 : 8.2,
                  clampToDavao: false,
                  showControls: false,
                  onMapTap: _onMapTap,
                  markers: [
                    if (_pinnedLat != null && _pinnedLng != null)
                      LakbayMapMarker(
                        id: 'pinned_origin',
                        lat: _pinnedLat!,
                        lng: _pinnedLng!,
                        title: _pinnedLabel ?? 'Pinned start',
                        isOrigin: true,
                        isUserLocation: true,
                      ),
                  ],
                ),
              ),
              if (_pinnedLat != null && _pinnedLng != null) ...[
                const SizedBox(height: 8),
                if (pinnedOutside)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 6),
                    child: _RegionNoteBanner(
                      text:
                          'This pinned start is outside Davao Region — road routes are planned inside Region XI.',
                    ),
                  ),
                ElevatedButton.icon(
                  onPressed: _resolvingPin ? null : _confirmPinned,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: LkColors.s3,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  icon: const Icon(Icons.check_circle_outline_rounded, size: 18),
                  label: Text(
                    _resolvingPin
                        ? 'Resolving place name…'
                        : 'Use pinned start (${_pinnedLabel ?? ''})',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _RegionNoteBanner extends StatelessWidget {
  final String text;

  const _RegionNoteBanner({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: LkColors.s2,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: LkColors.strokeStrong.withValues(alpha: 0.2),
        ),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.info_outline_rounded,
            size: 16,
            color: LkColors.text,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: LkColors.text,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
