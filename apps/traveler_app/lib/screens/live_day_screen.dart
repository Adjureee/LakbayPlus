import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design/design.dart';
import '../models/travel_models.dart';
import '../services/live_day.dart';
import '../services/location_service.dart';
import '../services/route_progress.dart';
import '../services/travel_repository.dart';
import '../widgets/lakbay_image.dart';
import '../widgets/lakbay_mapbox_widget.dart';

/// The trip "on the ground" (v8 Trip · live day): today's stops on a dark
/// map, the next stop with how far it is, progress through the day, and
/// warnings when the plan arrives after a place closes.
///
/// While the trip is happening it shows today; otherwise it previews
/// [previewDay] (day 1 by default) and says so.
class LiveDayScreen extends StatefulWidget {
  const LiveDayScreen({
    super.key,
    required this.repo,
    required this.trip,
    this.previewDay,
  });

  final TravelRepository repo;
  final ItineraryTrip trip;
  final int? previewDay;

  @override
  State<LiveDayScreen> createState() => _LiveDayScreenState();
}

class _LiveDayScreenState extends State<LiveDayScreen>
    with SingleTickerProviderStateMixin {
  final _mapKey = GlobalKey<LakbayMapboxMapState>();
  late ItineraryTrip _trip = widget.trip;
  int _reached = 0;
  bool _tracking = false;
  bool _follow = false;
  bool _routing = false;
  BackendRouteResult? _route;
  LivePosition? _lastFix;

  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: LkMotion.pulse,
  );

  TravelRepository get _repo => widget.repo;

  LiveDayPlan? get _plan => LiveDayPlan.forTrip(
    _trip,
    now: DateTime.now(),
    previewDay: widget.previewDay,
    hoursFor: _hoursFor,
  );

  ExploreTrip? _catalogPlace(ItineraryStop stop) {
    final id = stop.destinationId;
    if (id == null) return null;
    for (final p in _repo.allTrips) {
      if (p.apiDestinationId == id) return p;
    }
    return null;
  }

  ({int open, int close})? _hoursFor(ItineraryStop stop) =>
      parseOpeningHours(_catalogPlace(stop)?.operatingHours);

  @override
  void initState() {
    super.initState();
    _repo.addListener(_onRepoChanged);
    _repo.startLiveTracking().then((started) {
      if (!started) return;
      if (!mounted) {
        _repo.stopLiveTracking();
        return;
      }
      setState(() => _tracking = true);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = !LkMotion.of(context).enabled;
    if (reduced) {
      _pulse.stop();
    } else if (!_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _repo.removeListener(_onRepoChanged);
    if (_tracking) _repo.stopLiveTracking();
    _pulse.dispose();
    super.dispose();
  }

  void _onRepoChanged() {
    final fix = _repo.livePosition;
    if (!mounted || fix == null || identical(fix, _lastFix)) return;
    _lastFix = fix;
    final plan = _plan;
    if (plan == null) return;
    final arrived = plan.arrivalAt(fix.lat, fix.lng, _reached);
    if (arrived != null) {
      HapticFeedback.lightImpact();
      _reached = arrived + 1;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text('You arrived at ${plan.stops[arrived].stop.title}.'),
        ),
      );
    }
    setState(() {});
  }

  void _markHere(LiveDayPlan plan) {
    if (_reached >= plan.stops.length) return;
    HapticFeedback.lightImpact();
    setState(() {
      _reached++;
      _route = null;
    });
  }

  Future<void> _routeTo(LiveDayStop next) async {
    final id = next.stop.destinationId;
    setState(() {
      _routing = true;
      _follow = true;
    });
    final result = id == null
        ? null
        : await _repo.fetchRoadRouteForTrip(_trip, destinationIds: [id]);
    if (!mounted) return;
    setState(() {
      _routing = false;
      if (result != null) _route = result;
    });
    if (result == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "Couldn't get a road route right now. The map still shows "
            'your stops in order.',
          ),
        ),
      );
    }
  }

  void _moveEarlier(LiveDayPlan plan, int index) {
    final moved = plan.stops[index].stop.title;
    final newDay = plan.dayWithStopMovedEarlier(index);
    final days = [
      for (final d in _trip.days) d.dayNumber == newDay.dayNumber ? newDay : d,
    ];
    final updated = _trip.copyWith(days: days);
    setState(() => _trip = updated);
    if (_repo.savedTrips.any((t) => t.id == updated.id)) {
      _repo.updateTripDetails(updated);
    }
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('Moved $moved one stop earlier')));
  }

  void _pickMapStyle() {
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.symmetric(vertical: LkSpace.l),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: LkSpace.gutter),
              child: Text('Map style', style: LkType.h3),
            ),
            const SizedBox(height: LkSpace.s),
            for (final style in MapboxStylePreset.values)
              ListTile(
                title: Text(style.title),
                subtitle: Text(style.subtitle),
                trailing: _repo.activeMapStyle == style
                    ? Icon(Icons.check_rounded, color: LkColors.lagoon)
                    : null,
                onTap: () {
                  _repo.setMapboxStyle(style);
                  Navigator.of(ctx).pop();
                },
              ),
          ],
        ),
      ),
    );
  }

  void _openChat() {
    Navigator.of(context).popUntil((r) => r.isFirst);
    _repo.setActiveNavIndex(2);
  }

  ({String? url, String asset}) _imageFor(ItineraryStop stop) {
    final place = _catalogPlace(stop);
    if (place != null) {
      return (
        url: place.hasRemoteThumbnail ? place.thumbnailUrl : null,
        asset: place.localAssetPath,
      );
    }
    return (url: _trip.remoteImageUrl, asset: _trip.heroAsset);
  }

  @override
  Widget build(BuildContext context) {
    final plan = _plan;
    if (plan == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Live day')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(LkSpace.gutter),
            child: LkEmptyState(
              icon: Icons.route_outlined,
              title: 'No stops for this day',
              message: 'Add stops in the trip plan, then come back here.',
            ),
          ),
        ),
      );
    }

    final stops = plan.stops;
    final nextIndex = _reached < stops.length ? _reached : null;
    final next = nextIndex == null ? null : stops[nextIndex];
    final fix = _repo.livePosition;
    final focus = next ?? stops.last;

    return Scaffold(
      backgroundColor: LkColors.bg,
      body: Stack(
        children: [
          Positioned.fill(
            child: LakbayMapboxMap(
              key: _mapKey,
              repo: _repo,
              // Shift the camera so the next stop sits in the open map
              // above the sheet, not under it (zoom 12: ~0.00034° per px).
              initialLat:
                  focus.stop.lat -
                  MediaQuery.sizeOf(context).height * 0.2 * 360 / (256 * 4096),
              initialLng: focus.stop.lng,
              initialZoom: 12,
              routePoints: [for (final s in stops) s.point],
              roadGeometry: _route?.geometryPoints ?? const [],
              routeSegments: _route?.segments ?? const [],
              markers: [
                for (var i = 0; i < stops.length; i++)
                  LakbayMapMarker(
                    id: 'live_$i',
                    lat: stops[i].stop.lat,
                    lng: stops[i].stop.lng,
                    badgeText: i < _reached ? '✓' : '${i + 1}',
                    title: stops[i].stop.title,
                    subtitle: stops[i].stop.time,
                    isPrimary: i == nextIndex,
                    isCompact: i != nextIndex,
                  ),
              ],
              livePosition: fix,
              followUser: _follow,
              onFollowUserChanged: (v) => setState(() => _follow = v),
              selectedMarkerId: nextIndex == null ? null : 'live_$nextIndex',
              borderRadius: 0,
              showControls: false,
              overlayTopInset: MediaQuery.paddingOf(context).top + 64,
              overlayRightInset: 60,
            ),
          ),
          // Pinned to the top; the map's own controls are off so nothing
          // sits under these buttons.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  LkSpace.l,
                  LkSpace.s,
                  LkSpace.l,
                  0,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    LkIconButton(
                      icon: Icons.arrow_back_rounded,
                      tooltip: 'Back',
                      style: LkIconButtonStyle.glass,
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                    const SizedBox(width: LkSpace.s),
                    Expanded(
                      child: Align(
                        alignment: Alignment.topCenter,
                        heightFactor: 1,
                        child: _DayPill(
                          label: plan.headline,
                          live: plan.isLive,
                          pulse: _pulse,
                        ),
                      ),
                    ),
                    const SizedBox(width: LkSpace.s),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        LkIconButton(
                          icon: Icons.layers_outlined,
                          tooltip: 'Map style',
                          style: LkIconButtonStyle.glass,
                          onPressed: _pickMapStyle,
                        ),
                        const SizedBox(height: LkSpace.s),
                        LkIconButton(
                          icon: Icons.fit_screen_rounded,
                          tooltip: 'Show the whole day',
                          style: LkIconButtonStyle.glass,
                          onPressed: () {
                            setState(() => _follow = false);
                            _mapKey.currentState?.fitBounds();
                          },
                        ),
                        if (fix != null) ...[
                          const SizedBox(height: LkSpace.s),
                          LkIconButton(
                            icon: _follow
                                ? Icons.my_location_rounded
                                : Icons.location_searching_rounded,
                            tooltip: _follow
                                ? 'Stop following me'
                                : 'Follow my location',
                            style: LkIconButtonStyle.glass,
                            color: _follow ? LkColors.mango : null,
                            onPressed: () => setState(() => _follow = !_follow),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          DraggableScrollableSheet(
            initialChildSize: 0.5,
            minChildSize: 0.24,
            maxChildSize: 0.9,
            snap: true,
            builder: (context, scroll) => DecoratedBox(
              decoration: BoxDecoration(
                color: LkColors.bg,
                borderRadius: LkRadius.sheetTop,
                border: Border(top: BorderSide(color: LkColors.stroke)),
              ),
              child: ListView(
                controller: scroll,
                padding: const EdgeInsets.fromLTRB(
                  LkSpace.l,
                  LkSpace.s,
                  LkSpace.l,
                  LkSpace.xl,
                ),
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: LkSpace.m),
                      decoration: BoxDecoration(
                        color: LkColors.strokeStrong,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  AnimatedSwitcher(
                    duration: LkMotion.of(context).duration(LkMotion.slow),
                    switchInCurve: LkMotion.standard,
                    transitionBuilder: (child, a) => FadeTransition(
                      opacity: a,
                      child: SlideTransition(
                        position: Tween<Offset>(
                          begin: const Offset(0.08, 0),
                          end: Offset.zero,
                        ).animate(a),
                        child: child,
                      ),
                    ),
                    child: next != null
                        ? _NextStopCard(
                            key: ValueKey('next-$nextIndex'),
                            stop: next,
                            image: _imageFor(next.stop),
                            metersAway: fix == null
                                ? null
                                : plan.distanceTo(nextIndex!, fix.lat, fix.lng),
                            onHere: () => _markHere(plan),
                          )
                        : const _DayDoneCard(key: ValueKey('done')),
                  ),
                  const SizedBox(height: LkSpace.l),
                  _Progress(
                    total: stops.length,
                    reached: _reached,
                    costLabel: plan.estimatedCostUsd > 0
                        ? 'Est. ${_repo.formatPrice(plan.estimatedCostUsd)} today'
                        : null,
                  ),
                  const SizedBox(height: LkSpace.l),
                  for (var i = 0; i < stops.length; i++)
                    _StopRow(
                      number: i + 1,
                      stop: stops[i],
                      done: i < _reached,
                      isNext: i == nextIndex,
                      onMoveEarlier: i > _reached && i > 0
                          ? () => _moveEarlier(plan, i)
                          : null,
                    ),
                  if (!_tracking)
                    Padding(
                      padding: const EdgeInsets.only(top: LkSpace.s),
                      child: Text(
                        'Location is off, so stops are not ticked off '
                        'automatically. Tap "I’m here" when you arrive.',
                        style: LkType.caption,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: DecoratedBox(
        decoration: BoxDecoration(
          color: LkColors.bg,
          border: Border(top: BorderSide(color: LkColors.stroke)),
        ),
        child: SafeArea(
          top: false,
          minimum: const EdgeInsets.fromLTRB(
            LkSpace.l,
            LkSpace.s,
            LkSpace.l,
            LkSpace.m,
          ),
          // Fixed height: a bottom bar gets the full screen height to grow
          // into otherwise.
          child: SizedBox(
            height: 58,
            child: Row(
              children: [
                LkIconButton(
                  icon: Icons.forum_outlined,
                  tooltip: 'Ask Lakbay AI',
                  onPressed: _openChat,
                ),
                const SizedBox(width: LkSpace.s),
                Expanded(
                  child: LkButton(
                    label: next == null
                        ? 'Day done'
                        : 'Route to ${next.stop.title}',
                    icon: Icons.near_me_rounded,
                    size: LkButtonSize.large,
                    loading: _routing,
                    onPressed: next == null || _routing
                        ? null
                        : () => _routeTo(next),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DayPill extends StatelessWidget {
  const _DayPill({
    required this.label,
    required this.live,
    required this.pulse,
  });

  final String label;
  final bool live;
  final Animation<double> pulse;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: label,
      excludeSemantics: true,
      child: LkGlass(
        dark: true,
        borderRadius: BorderRadius.circular(LkRadius.sm),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (live)
              FadeTransition(
                opacity: Tween<double>(begin: 0.35, end: 1).animate(pulse),
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: LkColors.live,
                    shape: BoxShape.circle,
                  ),
                ),
              )
            else
              Icon(
                Icons.visibility_outlined,
                size: 14,
                color: LkColors.onPhotoMuted,
              ),
            const SizedBox(width: LkSpace.s),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: LkType.label.copyWith(color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _legLabel(ItineraryStop s) {
  final minutes = s.travelFromPrevMinutes;
  final boat =
      s.isSeaCrossingFromPrev || s.travelFromPrevMode == TransportMode.ferry;
  if (minutes == null || minutes <= 0) return s.description;
  return '${boat ? 'Ferry + ride' : 'Ride'}, ~$minutes min';
}

class _NextStopCard extends StatelessWidget {
  const _NextStopCard({
    super.key,
    required this.stop,
    required this.image,
    required this.metersAway,
    required this.onHere,
  });

  final LiveDayStop stop;
  final ({String? url, String asset}) image;
  final double? metersAway;
  final VoidCallback onHere;

  @override
  Widget build(BuildContext context) {
    final planned = stop.plannedMinutes == null
        ? stop.stop.time
        : formatClockMinutes(stop.plannedMinutes!);
    final away = metersAway == null ? null : formatDistanceMeters(metersAway!);
    final awayNumber = away?.split(' ').first;
    final awayUnit = away?.split(' ').last;

    return Container(
      padding: const EdgeInsets.all(LkSpace.m),
      decoration: BoxDecoration(
        color: LkColors.s1,
        borderRadius: LkRadius.lgAll,
        border: Border.all(color: LkColors.lagoon.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              ClipRRect(
                borderRadius: LkRadius.smAll,
                child: LakbayNetworkOrAssetImage(
                  networkUrl: image.url,
                  assetPath: image.asset,
                  width: 64,
                  height: 64,
                ),
              ),
              const SizedBox(width: LkSpace.m),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Next stop · planned $planned',
                      style: LkType.micro.copyWith(color: LkColors.mangoText),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      stop.stop.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: LkType.section,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _legLabel(stop.stop),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: LkType.caption,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: LkSpace.s),
              // Distance only from a real GPS fix; otherwise the plan's time.
              Semantics(
                label: away == null ? 'Planned $planned' : '$away away',
                excludeSemantics: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      awayNumber ?? planned.split(' ').first,
                      style: LkType.metric,
                    ),
                    Text(
                      away == null ? planned.split(' ').last : '$awayUnit away',
                      style: LkType.micro.copyWith(color: LkColors.muted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (stop.closingWarning != null) ...[
            const SizedBox(height: LkSpace.m),
            LkWarningRow(
              title: stop.closingWarning!,
              message: 'Go here sooner, or move it earlier in the list.',
            ),
          ],
          const SizedBox(height: LkSpace.m),
          LkButton(
            label: 'I’m here',
            icon: Icons.check_rounded,
            variant: LkButtonVariant.secondary,
            expand: true,
            onPressed: onHere,
          ),
        ],
      ),
    );
  }
}

class _DayDoneCard extends StatelessWidget {
  const _DayDoneCard({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(LkSpace.l),
      decoration: BoxDecoration(
        color: LkColors.s1,
        borderRadius: LkRadius.lgAll,
        border: Border.all(color: LkColors.stroke),
      ),
      child: Row(
        children: [
          Icon(Icons.task_alt_rounded, color: LkColors.lagoon, size: 32),
          const SizedBox(width: LkSpace.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Day done', style: LkType.section),
                Text('That was every stop for today.', style: LkType.caption),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Progress extends StatelessWidget {
  const _Progress({
    required this.total,
    required this.reached,
    required this.costLabel,
  });

  final int total;
  final int reached;
  final String? costLabel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '$reached of $total stops done',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              for (var i = 0; i < total; i++) ...[
                if (i > 0) const SizedBox(width: 4),
                Expanded(
                  child: AnimatedContainer(
                    duration: LkMotion.of(context).duration(LkMotion.slow),
                    curve: LkMotion.standard,
                    height: 6,
                    decoration: BoxDecoration(
                      color: i < reached
                          ? LkColors.lagoon
                          : (i == reached
                                ? LkColors.lagoon.withValues(alpha: 0.35)
                                : LkColors.s3),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: LkSpace.s),
          Row(
            children: [
              Text('$reached of $total done', style: LkType.caption),
              const Spacer(),
              if (costLabel != null) Text(costLabel!, style: LkType.caption),
            ],
          ),
        ],
      ),
    );
  }
}

class _StopRow extends StatelessWidget {
  const _StopRow({
    required this.number,
    required this.stop,
    required this.done,
    required this.isNext,
    required this.onMoveEarlier,
  });

  final int number;
  final LiveDayStop stop;
  final bool done;
  final bool isNext;
  final VoidCallback? onMoveEarlier;

  @override
  Widget build(BuildContext context) {
    final warning = done ? null : stop.closingWarning;
    final note = done ? null : stop.openingNote;
    return Padding(
      padding: const EdgeInsets.only(bottom: LkSpace.m),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            label:
                '${done ? 'Done' : (isNext ? 'Next' : 'Stop $number')}: '
                '${stop.stop.title}, planned ${stop.stop.time}',
            excludeSemantics: true,
            child: Row(
              children: [
                Container(
                  width: 30,
                  height: 30,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: done
                        ? LkColors.lagoonSoft
                        : (isNext ? LkColors.mango : LkColors.s2),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: done
                      ? Icon(
                          Icons.check_rounded,
                          size: 18,
                          color: LkColors.lagoon,
                        )
                      : Text(
                          '$number',
                          style: LkType.label.copyWith(
                            color: isNext ? LkColors.mangoInk : LkColors.text,
                          ),
                        ),
                ),
                const SizedBox(width: LkSpace.m),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        stop.stop.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: LkType.itemTitle.copyWith(
                          color: done ? LkColors.muted : LkColors.text,
                        ),
                      ),
                      Text(
                        note ?? _legLabel(stop.stop),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: LkType.caption,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: LkSpace.s),
                Text(
                  stop.stop.time,
                  style: LkType.bodyStrong.copyWith(
                    color: done ? LkColors.muted : LkColors.text,
                  ),
                ),
              ],
            ),
          ),
          if (warning != null) ...[
            const SizedBox(height: LkSpace.s),
            LkWarningRow(
              title: warning,
              message: onMoveEarlier == null
                  ? 'Go here sooner to find it open.'
                  : 'Swap it with the stop before to arrive in time.',
              actionLabel: onMoveEarlier == null ? null : 'Move earlier',
              onAction: onMoveEarlier,
            ),
          ],
        ],
      ),
    );
  }
}
