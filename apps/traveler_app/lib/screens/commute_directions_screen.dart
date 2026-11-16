import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/commute.dart';
import '../models/travel_models.dart';
import '../services/route_summary.dart';
import '../services/travel_repository.dart';
import '../theme/lakbay_theme.dart';

/// A place the traveler can ask directions to.
class CommuteStopRef {
  final int destinationId;
  final String name;
  const CommuteStopRef(this.destinationId, this.name);
}

/// Drive time next to verified public-transport directions for a place.
///
/// Commute routes come only from admin-verified data. When there are none the
/// screen says so instead of estimating a jeepney ride.
class CommuteDirectionsScreen extends StatefulWidget {
  final TravelRepository repo;
  final ItineraryTrip trip;
  final List<CommuteStopRef> stops;

  const CommuteDirectionsScreen({
    super.key,
    required this.repo,
    required this.trip,
    required this.stops,
  });

  @override
  State<CommuteDirectionsScreen> createState() =>
      _CommuteDirectionsScreenState();
}

class _CommuteDirectionsScreenState extends State<CommuteDirectionsScreen> {
  late CommuteStopRef _stop = widget.stops.first;
  bool _loading = true;
  bool _failed = false;
  List<CommuteRoute> _routes = const [];
  BackendRouteResult? _drive;
  bool _driveLoaded = false;
  bool _noOrigin = false;
  int _selected = 0;
  bool _started = false;
  final Set<int> _done = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
      _driveLoaded = false;
      _drive = null;
      _selected = 0;
      _started = false;
      _done.clear();
    });
    final stop = _stop;
    final routes = await widget.repo.apiCatalog.fetchCommuteRoutes(
      stop.destinationId,
    );
    if (!mounted || stop != _stop) return;
    setState(() {
      _loading = false;
      _failed = routes == null;
      _routes = routes ?? const [];
    });
    // A drive time needs a place to start from. Without one the route service
    // has only a single point and no distance, so say that instead of asking.
    final origin = widget.repo.routeOrigin;
    final drive = origin == null
        ? null
        : await widget.repo.fetchRoadRouteForTrip(
            widget.trip,
            travelMode: 'driving',
            destinationIds: [stop.destinationId],
          );
    if (!mounted || stop != _stop) return;
    setState(() {
      _drive = drive;
      _noOrigin = origin == null;
      _driveLoaded = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Getting to ${_stop.name}')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (widget.stops.length > 1) ...[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final stop in widget.stops)
                  ChoiceChip(
                    label: Text(stop.name),
                    selected: stop == _stop,
                    onSelected: (_) {
                      _stop = stop;
                      _load();
                    },
                  ),
              ],
            ),
            const SizedBox(height: 16),
          ],
          _driveCard(),
          const SizedBox(height: 12),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_failed)
            _note(
              'Could not check commute routes right now. Check your '
              'connection and try again.',
              retry: true,
            )
          else if (_routes.isEmpty)
            _note(
              'No verified public-transport directions for this place yet. '
              'Lakbay only shows routes a person has checked, so ask a local '
              'or the nearest terminal before you go.',
            )
          else ...[
            for (var i = 0; i < _routes.length; i++) _routeCard(i),
            const SizedBox(height: 12),
            _directions(_routes[_selected]),
          ],
        ],
      ),
    );
  }

  Widget _driveCard() {
    final drive = _drive;
    String value;
    String? qualifier;
    if (!_driveLoaded) {
      value = 'Checking…';
    } else if (_noOrigin) {
      value = 'Set your starting place to see the drive';
    } else if (drive == null || drive.totalDistanceKm <= 0) {
      value = 'Not available right now';
    } else {
      value =
          '${drive.totalDistanceKm.toStringAsFixed(1)} km • '
          '${RouteSummaryText.durationText(drive.totalDurationMinutes)}';
      qualifier = drive.isEstimated ? 'estimate' : 'road route';
    }
    return _card(
      icon: Icons.directions_car_rounded,
      title: 'Drive',
      lines: [value, ?qualifier],
    );
  }

  Widget _routeCard(int index) {
    final route = _routes[index];
    final selected = index == _selected;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: _card(
        icon: Icons.directions_bus_rounded,
        title: _routes.length > 1 ? 'Commute ${index + 1}' : 'Commute',
        selected: selected,
        onTap: () => setState(() {
          _selected = index;
          _started = false;
          _done.clear();
        }),
        lines: [
          route.timeLabel ?? 'Time not listed',
          route.fareLabel ?? 'Cost not listed',
          if (route.summary.isNotEmpty) route.summary,
          if (route.transfers > 0)
            '${route.transfers} transfer${route.transfers == 1 ? '' : 's'}',
        ],
      ),
    );
  }

  Widget _directions(CommuteRoute route) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Directions', style: theme.textTheme.titleMedium),
        if (route.startArea != null) Text('Starting from ${route.startArea}'),
        const SizedBox(height: 8),
        for (var i = 0; i < route.steps.length; i++)
          _stepTile(i, route.steps[i]),
        if (route.sourceUrl != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Source: ${route.sourceUrl}',
              style: theme.textTheme.bodySmall,
            ),
          ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                key: const ValueKey('commute-start'),
                onPressed: () => setState(() {
                  _started = !_started;
                  if (!_started) _done.clear();
                }),
                icon: Icon(_started ? Icons.stop_rounded : Icons.navigation),
                label: Text(_started ? 'Stop' : 'Start'),
              ),
            ),
            const SizedBox(width: 12),
            OutlinedButton.icon(
              key: const ValueKey('commute-copy'),
              onPressed: () async {
                await Clipboard.setData(
                  ClipboardData(text: route.toPlainText(_stop.name)),
                );
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Directions copied')),
                );
              },
              icon: const Icon(Icons.copy_rounded),
              label: const Text('Copy'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _stepTile(int index, CommuteStep step) {
    final details = [
      if (step.getOffAt != null) 'Get off at ${step.getOffAt}',
      if (step.minutes != null) RouteSummaryText.durationText(step.minutes!),
      ?step.fareLabel,
      if (step.notes != null && step.vehicle != 'fee') step.notes!,
    ];
    final done = _done.contains(index);
    // While travelling, the first step not yet done is the one to do now.
    final current =
        _started && !done && List.generate(index, (i) => i).every(_done.contains);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: current ? LakbayColors.primary.withValues(alpha: 0.08) : null,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: current ? LakbayColors.primary : Colors.black12,
        ),
      ),
      child: ListTile(
        leading: _started
            ? Checkbox(
                value: done,
                onChanged: (v) => setState(() {
                  v == true ? _done.add(index) : _done.remove(index);
                }),
              )
            : CircleAvatar(radius: 14, child: Text('${index + 1}')),
        title: Text(step.instruction),
        subtitle: details.isEmpty ? null : Text(details.join(' • ')),
      ),
    );
  }

  Widget _note(String text, {bool retry = false}) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: Colors.amber.shade50,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: Colors.amber.shade300),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(text),
        if (retry) TextButton(onPressed: _load, child: const Text('Try again')),
      ],
    ),
  );

  Widget _card({
    required IconData icon,
    required String title,
    required List<String> lines,
    bool selected = false,
    VoidCallback? onTap,
  }) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected ? LakbayColors.primary : Colors.black12,
            width: selected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(icon, color: LakbayColors.primary),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.titleMedium),
                  for (final line in lines)
                    Text(line, style: theme.textTheme.bodyMedium),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
