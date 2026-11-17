import 'package:flutter/material.dart';

import '../design/design.dart';
import '../models/travel_models.dart';
import '../services/travel_repository.dart';
import '../widgets/brand/lakbay_wordmark.dart';
import '../widgets/lakbay_image.dart';
import '../widgets/notifications_sheet.dart';
import 'live_day_screen.dart';
import 'trip_detail_screen.dart';

/// Trips home (v8): countdown to the next trip, the next-trip card, a rail
/// of Region XI places, and the traveler's trips with date filters.
class MyTripsScreen extends StatefulWidget {
  final TravelRepository repo;

  const MyTripsScreen({super.key, required this.repo});

  @override
  State<MyTripsScreen> createState() => _MyTripsScreenState();
}

class _MyTripsScreenState extends State<MyTripsScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _selectedFilter = 'All';
  bool _sortAlphabetical = false;

  static const _filters = ['All', 'Upcoming', 'No dates', 'Past'];
  static const _vibes = [
    'Any',
    'Beaches & islands',
    'Mountains & nature',
    'Food & city',
    'Culture & heritage',
  ];

  /// Only offer search once there are enough trips to need it.
  static const _searchThreshold = 5;

  TravelRepository get _repo => widget.repo;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  bool _matchesFilter(ItineraryTrip trip, DateTime now) {
    final timing = trip.timingOn(now);
    switch (_selectedFilter) {
      case 'Upcoming':
        return timing == TripTiming.upcoming || timing == TripTiming.ongoing;
      case 'No dates':
        return timing == TripTiming.undated;
      case 'Past':
        return timing == TripTiming.past;
      default:
        return true;
    }
  }

  /// The trip happening now, else the next one coming up, else the newest.
  ItineraryTrip? _heroTrip(List<ItineraryTrip> trips, DateTime now) {
    if (trips.isEmpty) return null;
    for (final t in trips) {
      if (t.timingOn(now) == TripTiming.ongoing) return t;
    }
    final upcoming =
        trips.where((t) => t.timingOn(now) == TripTiming.upcoming).toList()
          ..sort((a, b) => a.startDate!.compareTo(b.startDate!));
    if (upcoming.isNotEmpty) return upcoming.first;
    return trips.first;
  }

  /// A trip that is happening today opens straight into its live day.
  void _openTrip(ItineraryTrip trip, {String? heroTag}) {
    final live = trip.timingOn(DateTime.now()) == TripTiming.ongoing;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => live
            ? LiveDayScreen(repo: _repo, trip: trip)
            : TripDetailScreen(repo: _repo, trip: trip, heroTag: heroTag),
      ),
    );
  }

  Future<void> _confirmDelete(ItineraryTrip trip) async {
    final ok = await showLkConfirm(
      context,
      title: 'Delete "${trip.title}"?',
      message: trip.backendTripId != null
          ? 'It will be removed from your trips and your Lakbay+ account.'
          : 'It will be removed from your trips.',
      confirmLabel: 'Delete trip',
    );
    if (!ok || !mounted) return;
    final repo = _repo;
    final index = repo.takeSavedTrip(trip.id);
    if (index < 0) return;
    var undone = false;
    showLkUndoSnack(
      context,
      message: 'Trip deleted',
      onUndo: () {
        undone = true;
        repo.restoreSavedTrip(trip, index);
      },
    ).closed.then((_) {
      if (!undone) repo.commitTripRemoval(trip);
    });
  }

  void _showCreateTripSheet() {
    final destController = TextEditingController();
    var days = 3;
    var vibe = _vibes.first;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          return Padding(
            padding: EdgeInsets.fromLTRB(
              LkSpace.gutter,
              LkSpace.xl,
              LkSpace.gutter,
              MediaQuery.viewInsetsOf(ctx).bottom + LkSpace.xl,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Semantics(
                  header: true,
                  child: Text('Plan a new trip', style: LkType.h3),
                ),
                const SizedBox(height: LkSpace.xs),
                Text(
                  'Lakbay AI drafts it in Chat. You save it when you like it.',
                  style: LkType.caption,
                ),
                const SizedBox(height: LkSpace.l),
                TextField(
                  controller: destController,
                  textInputAction: TextInputAction.done,
                  decoration: const InputDecoration(
                    labelText: 'Where in Region XI?',
                    hintText: 'Samal Island, Mati, Mt. Apo…',
                  ),
                ),
                const SizedBox(height: LkSpace.l),
                Row(
                  children: [
                    Expanded(child: Text('Days', style: LkType.label)),
                    LkIconButton(
                      icon: Icons.remove_rounded,
                      tooltip: 'Fewer days',
                      style: LkIconButtonStyle.plain,
                      onPressed: days > 1
                          ? () => setSheetState(() => days--)
                          : null,
                    ),
                    SizedBox(
                      width: 72,
                      child: Text(
                        '$days ${days == 1 ? 'day' : 'days'}',
                        textAlign: TextAlign.center,
                        style: LkType.bodyStrong,
                      ),
                    ),
                    LkIconButton(
                      icon: Icons.add_rounded,
                      tooltip: 'More days',
                      style: LkIconButtonStyle.plain,
                      onPressed: days < 14
                          ? () => setSheetState(() => days++)
                          : null,
                    ),
                  ],
                ),
                const SizedBox(height: LkSpace.s),
                Text('Vibe', style: LkType.label),
                const SizedBox(height: LkSpace.s),
                Wrap(
                  spacing: LkSpace.s,
                  runSpacing: LkSpace.s,
                  children: [
                    for (final v in _vibes)
                      ChoiceChip(
                        label: Text(v == 'Any' ? 'Any vibe' : v),
                        selected: vibe == v,
                        onSelected: (_) => setSheetState(() => vibe = v),
                      ),
                  ],
                ),
                const SizedBox(height: LkSpace.xxl),
                LkButton(
                  label: 'Plan with Lakbay AI',
                  icon: Icons.forum_rounded,
                  expand: true,
                  size: LkButtonSize.large,
                  onPressed: () {
                    final where = destController.text.trim();
                    final vibeWords = vibe == 'Any'
                        ? ''
                        : ' ${vibe.toLowerCase()}';
                    Navigator.of(ctx).pop();
                    _repo.planInChat(
                      'Plan a $days-day$vibeWords trip'
                      '${where.isEmpty ? '' : ' to $where'}.',
                    );
                  },
                ),
              ],
            ),
          );
        },
      ),
    ).whenComplete(destController.dispose);
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final query = _searchController.text.trim().toLowerCase();
    final allTrips = _repo.savedTrips;
    final hero = _heroTrip(allTrips, now);
    final heroTiming = hero?.timingOn(now);
    final counting =
        heroTiming == TripTiming.upcoming || heroTiming == TripTiming.ongoing;
    final greeting = _greeting(now, _repo.profile.firstName);

    final filtered = allTrips.where((t) {
      if (query.isNotEmpty &&
          !t.title.toLowerCase().contains(query) &&
          !t.destination.toLowerCase().contains(query)) {
        return false;
      }
      return _matchesFilter(t, now);
    }).toList();
    if (_sortAlphabetical) {
      filtered.sort((a, b) => a.title.compareTo(b.title));
    }

    final bottomClear = MediaQuery.paddingOf(context).bottom;

    return Scaffold(
      backgroundColor: LkColors.bg,
      body: SafeArea(
        bottom: false,
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(child: _Header(repo: _repo)),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  LkSpace.gutter,
                  LkSpace.xl,
                  LkSpace.gutter,
                  0,
                ),
                child: LkRiseIn(
                  child: counting
                      ? _Countdown(trip: hero!, now: now, greeting: greeting)
                      : _PlanNextCard(
                          greeting: greeting,
                          onPlan: () => _repo.setActiveNavIndex(2),
                          onCreate: _showCreateTripSheet,
                        ),
                ),
              ),
            ),
            if (hero != null)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    LkSpace.gutter,
                    LkSpace.xxl,
                    LkSpace.gutter,
                    0,
                  ),
                  child: LkRiseIn(
                    delay: LkRiseIn.stagger(1),
                    child: _NextTripCard(
                      trip: hero,
                      now: now,
                      stacked: (allTrips.length - 1).clamp(0, 2),
                      priceLabel: _perPersonLabel(hero),
                      onOpen: () =>
                          _openTrip(hero, heroTag: 'trip-card-${hero.id}'),
                      heroTag: 'trip-card-${hero.id}',
                    ),
                  ),
                ),
              ),
            SliverToBoxAdapter(
              child: LkRiseIn(
                delay: LkRiseIn.stagger(2),
                child: _ExploreRail(repo: _repo),
              ),
            ),
            SliverToBoxAdapter(
              child: LkSectionHeader(
                title: 'Your trips',
                actionLabel: 'New trip',
                onAction: _showCreateTripSheet,
                padding: const EdgeInsets.fromLTRB(
                  LkSpace.gutter,
                  LkSpace.xxl,
                  LkSpace.gutter,
                  LkSpace.s,
                ),
              ),
            ),
            if (allTrips.length >= _searchThreshold)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    LkSpace.gutter,
                    0,
                    LkSpace.gutter,
                    LkSpace.m,
                  ),
                  child: TextField(
                    controller: _searchController,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search_rounded),
                      hintText: 'Search your trips',
                    ),
                  ),
                ),
              ),
            SliverToBoxAdapter(
              child: SizedBox(
                height: kLkMinTarget,
                child: Row(
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.only(left: LkSpace.gutter),
                        child: Row(
                          children: [
                            for (final f in _filters)
                              Padding(
                                padding: const EdgeInsets.only(
                                  right: LkSpace.s,
                                ),
                                child: Center(
                                  child: ChoiceChip(
                                    label: Text(f),
                                    selected: _selectedFilter == f,
                                    onSelected: (_) =>
                                        setState(() => _selectedFilter = f),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    LkIconButton(
                      icon: Icons.sort_by_alpha_rounded,
                      tooltip: _sortAlphabetical
                          ? 'Sort: newest first'
                          : 'Sort: A to Z',
                      style: LkIconButtonStyle.plain,
                      color: _sortAlphabetical ? LkColors.mango : null,
                      onPressed: () => setState(
                        () => _sortAlphabetical = !_sortAlphabetical,
                      ),
                    ),
                    const SizedBox(width: LkSpace.s),
                  ],
                ),
              ),
            ),
            if (filtered.isEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    LkSpace.gutter,
                    LkSpace.l,
                    LkSpace.gutter,
                    0,
                  ),
                  child: LkEmptyState(
                    icon: Icons.luggage_outlined,
                    title: switch (_selectedFilter) {
                      'Upcoming' => 'No upcoming trips',
                      'No dates' => 'Every trip has dates',
                      'Past' => 'No past trips yet',
                      _ => 'No trips yet',
                    },
                    message:
                        'Tell Lakbay AI the vibe in Chat and save the '
                        'plan you like.',
                    actionLabel: 'Open Chat',
                    onAction: () => _repo.setActiveNavIndex(2),
                  ),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(
                  LkSpace.gutter,
                  LkSpace.s,
                  LkSpace.gutter,
                  0,
                ),
                sliver: SliverList.separated(
                  itemCount: filtered.length,
                  separatorBuilder: (_, _) => const SizedBox(height: LkSpace.s),
                  itemBuilder: (_, i) => LkRiseIn(
                    key: ValueKey('trip-row-${filtered[i].id}'),
                    delay: LkRiseIn.stagger(3 + i),
                    child: _TripListTile(
                      trip: filtered[i],
                      now: now,
                      heroTag: 'trip-row-${filtered[i].id}',
                      onTap: () => _openTrip(
                        filtered[i],
                        heroTag: 'trip-row-${filtered[i].id}',
                      ),
                      onDelete: () => _confirmDelete(filtered[i]),
                    ),
                  ),
                ),
              ),
            SliverToBoxAdapter(
              child: SizedBox(height: bottomClear + LkSpace.xxl),
            ),
          ],
        ),
      ),
    );
  }

  String? _perPersonLabel(ItineraryTrip trip) {
    final people = (trip.adults + trip.children).clamp(1, 100);
    final php = trip.backendEstimatedCostPhp;
    if (php != null && php > 0) {
      return '₱${_thousands((php / people).round())} each';
    }
    final usd = trip.totalEstimatedCostUsd;
    if (usd <= 0) return null;
    return '${_repo.formatPrice(usd / people)} each';
  }
}

String _thousands(int n) => n.toString().replaceAllMapped(
  RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
  (m) => '${m[1]},',
);

/// Bisaya greeting by time of day ("Maayong buntag, Ana").
String _greeting(DateTime now, String firstName) {
  final h = now.hour;
  final part = h < 12
      ? 'Maayong buntag'
      : (h < 18 ? 'Maayong hapon' : 'Maayong gabii');
  final name = firstName.trim();
  return name.isEmpty ? part : '$part, $name';
}

/// The trip photo flies into Trip detail's header when [tag] is set.
Widget _maybeHero(String? tag, Widget child) =>
    tag == null ? child : Hero(tag: tag, child: child);

String _placeName(ItineraryTrip trip) {
  final d = trip.destination.split(',').first.trim();
  return d.isEmpty ? trip.title : d;
}

class _Header extends StatelessWidget {
  const _Header({required this.repo});

  final TravelRepository repo;

  @override
  Widget build(BuildContext context) {
    final initials = repo.profile.initials;
    final unread = repo.unreadNotificationCount;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        LkSpace.gutter,
        LkSpace.m,
        LkSpace.gutter,
        0,
      ),
      child: Row(
        children: [
          const LakbayWordmark(fontSize: 26),
          const Spacer(),
          LkIconButton(
            icon: Icons.notifications_none_rounded,
            tooltip: unread > 0
                ? 'Notifications, $unread unread'
                : 'Notifications',
            showBadge: unread > 0,
            onPressed: () => showNotificationsSheet(context, repo),
          ),
          const SizedBox(width: LkSpace.s),
          Semantics(
            button: true,
            label: 'Profile',
            excludeSemantics: true,
            child: Material(
              color: LkColors.mango,
              borderRadius: BorderRadius.circular(LkRadius.sm),
              child: InkWell(
                borderRadius: BorderRadius.circular(LkRadius.sm),
                onTap: () => repo.setActiveNavIndex(4),
                child: SizedBox.square(
                  dimension: kLkMinTarget,
                  child: Center(
                    child: initials.isEmpty
                        ? Icon(
                            Icons.person_rounded,
                            color: LkColors.mangoInk,
                          )
                        : Text(
                            initials.length > 2
                                ? initials.substring(0, 2)
                                : initials,
                            style: LkType.label.copyWith(
                              color: LkColors.mangoInk,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// "5 days to Samal Island", or "Day 2 of 3" while the trip is on.
class _Countdown extends StatelessWidget {
  const _Countdown({
    required this.trip,
    required this.now,
    required this.greeting,
  });

  final ItineraryTrip trip;
  final DateTime now;
  final String greeting;

  @override
  Widget build(BuildContext context) {
    final today = DateTime(now.year, now.month, now.day);
    final start = trip.startDate!;
    final place = _placeName(trip);
    final ongoing = trip.timingOn(now) == TripTiming.ongoing;

    final String big;
    final String lead;
    final String spoken;
    if (ongoing) {
      final total = trip.lastDay!.difference(start).inDays + 1;
      final dayNo = today.difference(start).inDays + 1;
      big = '$dayNo';
      lead = total == 1 ? 'Today in' : 'Day $dayNo of $total in';
      spoken = total == 1
          ? 'Your trip to $place is today'
          : 'Day $dayNo of $total of your trip to $place';
    } else {
      final daysLeft = start.difference(today).inDays;
      big = '$daysLeft';
      lead = daysLeft == 1 ? 'day to' : 'days to';
      spoken = '$daysLeft ${daysLeft == 1 ? 'day' : 'days'} to $place';
    }

    return Semantics(
      label: spoken,
      excludeSemantics: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          LkCountUp(value: int.parse(big), style: LkType.countdown),
          const SizedBox(width: LkSpace.m),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: LkSpace.l),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    greeting,
                    style: LkType.caption,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: LkSpace.xxs),
                  Text(
                    '$lead\n$place',
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: LkType.h2,
                  ),
                  // Weather only when real data has been loaded for the trip.
                  if (trip.avgTemp.trim().isNotEmpty) ...[
                    const SizedBox(height: LkSpace.s),
                    LkGlassChip(
                      icon: Icons.wb_sunny_outlined,
                      label: trip.avgTemp,
                      dark: true,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Shown when no trip is coming up: a nudge to plan in Chat.
class _PlanNextCard extends StatelessWidget {
  const _PlanNextCard({
    required this.greeting,
    required this.onPlan,
    required this.onCreate,
  });

  final String greeting;
  final VoidCallback onPlan;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(greeting, style: LkType.caption),
        const SizedBox(height: LkSpace.xs),
        Text.rich(
          TextSpan(
            text: 'Where to ',
            children: [
              TextSpan(
                text: 'next?',
                style: LkType.h1.copyWith(color: LkColors.mangoText),
              ),
            ],
          ),
          style: LkType.h1,
        ),
        const SizedBox(height: LkSpace.s),
        Text(
          'Tell Lakbay AI the vibe, your budget and who’s coming. You get a '
          'day-by-day plan with real Region XI places.',
          style: LkType.body.copyWith(color: LkColors.muted),
        ),
        const SizedBox(height: LkSpace.l),
        Row(
          children: [
            Expanded(
              child: LkButton(
                label: 'Plan in Chat',
                icon: Icons.forum_rounded,
                onPressed: onPlan,
              ),
            ),
            const SizedBox(width: LkSpace.s),
            LkButton(
              label: 'Quick start',
              variant: LkButtonVariant.secondary,
              onPressed: onCreate,
            ),
          ],
        ),
      ],
    );
  }
}

class _NextTripCard extends StatelessWidget {
  const _NextTripCard({
    required this.trip,
    required this.now,
    required this.stacked,
    required this.priceLabel,
    required this.onOpen,
    this.heroTag,
  });

  final ItineraryTrip trip;
  final DateTime now;
  final String? heroTag;

  /// How many darker cards peek out above it (other saved trips), 0–2.
  final int stacked;
  final String? priceLabel;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final tag = switch (trip.timingOn(now)) {
      TripTiming.ongoing => 'Happening now',
      TripTiming.upcoming => 'Next trip',
      TripTiming.past => 'Last trip',
      TripTiming.undated => 'Draft',
    };
    final people = trip.adults + trip.children;
    final hasFerry =
        trip.seaCrossings.isNotEmpty ||
        trip.days.any((d) => d.transportFromPrevious == TransportMode.ferry);

    final card = Semantics(
      button: true,
      label: '$tag: ${trip.title}. Open trip',
      excludeSemantics: true,
      child: Material(
        color: LkColors.s1,
        borderRadius: BorderRadius.circular(LkRadius.lg),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onOpen,
          child: SizedBox(
            height: 240,
            child: Stack(
              fit: StackFit.expand,
              children: [
                _maybeHero(
                  heroTag,
                  LakbayNetworkOrAssetImage(
                    networkUrl: trip.remoteImageUrl,
                    assetPath: trip.heroAsset,
                  ),
                ),
                const DecoratedBox(
                  decoration: BoxDecoration(gradient: LkColors.photoScrim),
                ),
                Positioned(top: LkSpace.m, left: LkSpace.m, child: LkTag(tag)),
                Positioned(
                  top: LkSpace.s,
                  right: LkSpace.s,
                  child: LkGlass(
                    borderRadius: BorderRadius.all(Radius.circular(14)),
                    child: SizedBox.square(
                      dimension: 40,
                      child: Icon(
                        Icons.north_east_rounded,
                        color: LkColors.lagoon,
                        size: 22,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: LkSpace.l,
                  right: LkSpace.l,
                  bottom: LkSpace.l,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        trip.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: LkType.h3.copyWith(color: Colors.white),
                      ),
                      const SizedBox(height: LkSpace.s),
                      _RouteLine(
                        from: 'Davao City',
                        to: _placeName(trip),
                        ferry: hasFerry,
                      ),
                      const SizedBox(height: LkSpace.m),
                      Wrap(
                        spacing: LkSpace.xs,
                        runSpacing: LkSpace.xs,
                        children: [
                          if (trip.dateRangeLabel != null)
                            LkGlassChip(
                              label: trip.dateRangeLabel!,
                              dark: true,
                            ),
                          LkGlassChip(
                            label:
                                '${trip.daysCount} '
                                '${trip.daysCount == 1 ? 'day' : 'days'}',
                            dark: true,
                          ),
                          LkGlassChip(
                            label:
                                '$people '
                                '${people == 1 ? 'person' : 'people'}',
                            dark: true,
                          ),
                          if (priceLabel != null)
                            LkGlassChip(label: priceLabel!, dark: true),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (stacked == 0) return card;
    // Darker cards peek out above it, as in v8, when there are more trips.
    const peek = 9.0;
    return Padding(
      padding: EdgeInsets.only(top: stacked * peek),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (var i = stacked; i >= 1; i--)
            Positioned(
              left: 14.0 * i,
              right: 14.0 * i,
              top: -peek * i,
              height: 40,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: i == 1 ? LkColors.s3 : LkColors.s2,
                  borderRadius: BorderRadius.circular(LkRadius.lg),
                  border: Border.all(color: LkColors.stroke),
                ),
              ),
            ),
          card,
        ],
      ),
    );
  }
}

/// "Davao City - - - ⛴ - - - Samal": the trip's start and end, with the main
/// way of getting there.
class _RouteLine extends StatelessWidget {
  const _RouteLine({required this.from, required this.to, required this.ferry});

  final String from;
  final String to;
  final bool ferry;

  @override
  Widget build(BuildContext context) {
    final style = LkType.label.copyWith(color: Colors.white);
    return Row(
      children: [
        Text(from, style: style),
        const SizedBox(width: LkSpace.s),
        const Expanded(child: _Dashes()),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: LkSpace.xs),
          child: Icon(
            ferry
                ? Icons.directions_boat_filled_rounded
                : Icons.directions_car_rounded,
            size: 18,
            color: LkColors.lagoon,
          ),
        ),
        const Expanded(child: _Dashes()),
        const SizedBox(width: LkSpace.s),
        Flexible(
          flex: 2,
          child: Text(
            to,
            style: style,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

class _Dashes extends StatelessWidget {
  const _Dashes();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      height: 2,
      child: CustomPaint(painter: _DashPainter()),
    );
  }
}

class _DashPainter extends CustomPainter {
  const _DashPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = LkColors.lagoon
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    for (var x = 0.0; x < size.width; x += 7) {
      canvas.drawLine(
        Offset(x, size.height / 2),
        Offset((x + 3).clamp(0, size.width), size.height / 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Photo rail of catalog places; tapping one opens Discover.
class _ExploreRail extends StatelessWidget {
  const _ExploreRail({required this.repo});

  final TravelRepository repo;

  @override
  Widget build(BuildContext context) {
    final places = repo.allTrips.take(10).toList();
    if (places.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LkSectionHeader(
          title: 'Explore Region XI',
          actionLabel: 'See all',
          onAction: () => repo.setActiveNavIndex(1),
          padding: const EdgeInsets.fromLTRB(
            LkSpace.gutter,
            LkSpace.xxl,
            LkSpace.gutter,
            LkSpace.m,
          ),
        ),
        SizedBox(
          height: 150,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: LkSpace.gutter),
            itemCount: places.length,
            separatorBuilder: (_, _) => const SizedBox(width: LkSpace.s),
            itemBuilder: (_, i) {
              final p = places[i];
              final ImageProvider image = p.hasRemoteThumbnail
                  ? NetworkImage(p.thumbnailUrl)
                  : AssetImage(p.localAssetPath);
              final kind = (p.tag ?? '').trim();
              final area = p.municipalityLabel.trim();
              return LkPhotoCard(
                image: image,
                fallbackImage: AssetImage(p.localAssetPath),
                width: 128,
                height: 150,
                title: p.title.split('—').first.split(' - ').first.trim(),
                subtitle: [
                  if (kind.isNotEmpty) kind,
                  if (area.isNotEmpty) area,
                ].join(', '),
                onTap: () => repo.setActiveNavIndex(1),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _TripListTile extends StatelessWidget {
  const _TripListTile({
    required this.trip,
    required this.now,
    required this.onTap,
    required this.onDelete,
    this.heroTag,
  });

  final ItineraryTrip trip;
  final DateTime now;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final String? heroTag;

  @override
  Widget build(BuildContext context) {
    final when = trip.whenLabel(now) ?? 'No dates yet';
    final live = trip.timingOn(now) == TripTiming.ongoing;
    return Material(
      color: LkColors.s1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(LkRadius.md),
        side: BorderSide(color: LkColors.stroke),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(LkSpace.s),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(LkRadius.sm),
                child: _maybeHero(
                  heroTag,
                  LakbayNetworkOrAssetImage(
                    networkUrl: trip.remoteImageUrl,
                    assetPath: trip.heroAsset,
                    width: 60,
                    height: 60,
                  ),
                ),
              ),
              const SizedBox(width: LkSpace.m),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      trip.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: LkType.itemTitle,
                    ),
                    const SizedBox(height: LkSpace.xxs),
                    Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: when,
                            style: TextStyle(
                              color: live ? LkColors.mango : LkColors.lagoon,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          TextSpan(
                            text:
                                ' · ${trip.daysCount} days · '
                                '${_placeName(trip)}',
                          ),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: LkType.caption,
                    ),
                  ],
                ),
              ),
              LkIconButton(
                icon: Icons.delete_outline_rounded,
                tooltip: 'Delete trip',
                style: LkIconButtonStyle.plain,
                onPressed: onDelete,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
