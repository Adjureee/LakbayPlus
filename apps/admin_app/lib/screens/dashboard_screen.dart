import 'package:flutter/material.dart';
import '../core/theme/app_theme.dart';
import '../services/api_service.dart';
import '../widgets/admin_widgets.dart';

class DashboardScreen extends StatefulWidget {
  final ApiService? api;
  const DashboardScreen({super.key, this.api});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  late final ApiService _api = widget.api ?? ApiService();
  late Future<List<dynamic>> _destinations;
  late Future<int?> _users;
  late Future<int?> _trips;
  late Future<int?> _reviews;
  late Future<List<dynamic>> _pending;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Every number on this page comes from an API count; a failed request
  /// shows a dash, never a guess.
  void _load() {
    _destinations = _api.getDestinations();
    _users = _count(_api.getAdminUsers(limit: 1), 'total_users');
    _trips = _count(_api.getAdminTrips(limit: 1), 'total_trips');
    _reviews = _count(_api.getAdminReviews(limit: 1), 'total_reviews');
    _pending = _api
        .getDestinationCandidates(limit: 6)
        .catchError((Object _) => <dynamic>[]);
  }

  static Future<int?> _count(
    Future<Map<String, dynamic>> request,
    String key,
  ) async {
    try {
      return ((await request)[key] as num?)?.toInt();
    } catch (_) {
      return null;
    }
  }

  void _refresh() => setState(_load);

  @override
  void dispose() {
    _api.close();
    super.dispose();
  }

  Future<void> _open(String route) async {
    if (!await confirmAdminNavigation(context) || !mounted) return;
    if (!context.mounted) return;
    Navigator.pushReplacementNamed(context, route);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AdminPage(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AdminPageHeader(
            title: 'Overview',
            description:
                'Maintain destination information and travel costs from one workspace.',
            action: OutlinedButton.icon(
              onPressed: _refresh,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Refresh catalog'),
            ),
          ),
          const SizedBox(height: 24),
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = constraints.maxWidth >= 1100
                  ? 4
                  : constraints.maxWidth >= 620
                  ? 2
                  : 1;
              final width =
                  (constraints.maxWidth - (columns - 1) * 16) / columns;
              Widget card(Widget child) => SizedBox(width: width, child: child);
              return Wrap(
                spacing: 16,
                runSpacing: 16,
                children: [
                  card(
                    FutureBuilder<List<dynamic>>(
                      future: _destinations,
                      builder: (context, snapshot) {
                        final done =
                            snapshot.connectionState == ConnectionState.done;
                        final active = snapshot.hasData
                            ? snapshot.data!
                                  .where(
                                    (d) => d is Map && d['is_active'] != false,
                                  )
                                  .length
                            : null;
                        return _StatCard(
                          icon: Icons.place_outlined,
                          label: 'Active destinations',
                          value: active,
                          loading: !done,
                          caption: snapshot.hasError
                              ? 'Catalog unavailable. Try Refresh.'
                              : 'From the public catalog',
                          onOpen: () => _open('/destinations'),
                        );
                      },
                    ),
                  ),
                  card(
                    _CountCard(
                      future: _users,
                      icon: Icons.people_outline,
                      label: 'Traveler accounts',
                      onOpen: () => _open('/users'),
                    ),
                  ),
                  card(
                    _CountCard(
                      future: _trips,
                      icon: Icons.route_outlined,
                      label: 'Saved trips',
                      onOpen: () => _open('/trips'),
                    ),
                  ),
                  card(
                    _CountCard(
                      future: _reviews,
                      icon: Icons.rate_review_outlined,
                      label: 'Trip reviews',
                      onOpen: () => _open('/reviews'),
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 24),
          FutureBuilder<List<dynamic>>(
            future: _pending,
            builder: (context, snapshot) => _PendingReviews(
              loading: snapshot.connectionState != ConnectionState.done,
              items: snapshot.data ?? const [],
              onOpen: () => _open('/destination-candidates'),
            ),
          ),
          const SizedBox(height: 32),
          Semantics(
            header: true,
            child: Text('Manage Lakbay+', style: theme.textTheme.titleLarge),
          ),
          const SizedBox(height: 6),
          Text(
            'Choose the information you want to maintain or inspect.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = constraints.maxWidth >= 960
                  ? 3
                  : constraints.maxWidth >= 620
                  ? 2
                  : 1;
              final cardWidth =
                  (constraints.maxWidth - (columns - 1) * 16) / columns;
              return Wrap(
                spacing: 16,
                runSpacing: 16,
                children: [
                  for (final area in _workAreas)
                    SizedBox(
                      width: cardWidth,
                      child: _WorkspaceCard(
                        area: area,
                        onOpen: () => _open(area.route),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _WorkArea {
  final String title;
  final String description;
  final String route;
  final IconData icon;

  const _WorkArea(this.title, this.description, this.route, this.icon);
}

const _workAreas = [
  _WorkArea(
    'Destinations',
    'Maintain places, descriptions, location details, images, and traveler information.',
    '/destinations',
    Icons.place_outlined,
  ),
  _WorkArea(
    'Market Rates',
    'View and maintain accommodation and transportation costs for a selected destination.',
    '/market-rates',
    Icons.payments_outlined,
  ),
  _WorkArea(
    'User Accounts',
    'Look up traveler accounts and turn access on or off.',
    '/users',
    Icons.people_outline,
  ),
  _WorkArea(
    'Reviews & Feedback',
    'Read traveler comments and ratings with their original trip context.',
    '/reviews',
    Icons.rate_review_outlined,
  ),
  _WorkArea(
    'Trip Information',
    'Inspect itineraries and their destinations (read-only).',
    '/trips',
    Icons.route_outlined,
  ),
];

class _WorkspaceCard extends StatelessWidget {
  final _WorkArea area;
  final VoidCallback onOpen;

  const _WorkspaceCard({required this.area, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AdminPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  area.icon,
                  color: theme.colorScheme.primary,
                  size: 22,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(area.title, style: theme.textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(
            area.description,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          TextButton.icon(
            onPressed: onOpen,
            icon: const Icon(Icons.arrow_forward, size: 18),
            label: const Text('Open workspace'),
          ),
        ],
      ),
    );
  }
}

class _CountCard extends StatelessWidget {
  const _CountCard({
    required this.future,
    required this.icon,
    required this.label,
    required this.onOpen,
  });

  final Future<int?> future;
  final IconData icon;
  final String label;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) => FutureBuilder<int?>(
    future: future,
    builder: (context, snapshot) {
      final done = snapshot.connectionState == ConnectionState.done;
      return _StatCard(
        icon: icon,
        label: label,
        value: snapshot.data,
        loading: !done,
        caption: done && snapshot.data == null
            ? 'Unavailable right now'
            : 'Across all accounts',
        onOpen: onOpen,
      );
    },
  );
}

/// A big Bricolage number with its label. Shows a dash when the count could
/// not be loaded, never an estimate.
class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.loading,
    required this.caption,
    required this.onOpen,
  });

  final IconData icon;
  final String label;
  final int? value;
  final bool loading;
  final String caption;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shown = loading ? '…' : (value == null ? '—' : '$value');
    return Semantics(
      button: true,
      label: loading
          ? '$label, loading'
          : (value == null ? '$label, unavailable' : '$label: $value'),
      excludeSemantics: true,
      child: Material(
        color: theme.cardColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: theme.dividerColor),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(icon, size: 20, color: theme.colorScheme.secondary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(label, style: theme.textTheme.titleSmall),
                    ),
                    Icon(
                      Icons.arrow_forward_rounded,
                      size: 18,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Text(
                  shown,
                  style: AppTheme.display(
                    size: 44,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 6),
                Text(caption, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Places staged for review, newest first, with a way into the queue.
class _PendingReviews extends StatelessWidget {
  const _PendingReviews({
    required this.loading,
    required this.items,
    required this.onOpen,
  });

  final bool loading;
  final List<dynamic> items;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final places = items.whereType<Map>().take(5).toList();
    return AdminPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    'Waiting for review',
                    style: theme.textTheme.titleLarge,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: onOpen,
                icon: const Icon(Icons.fact_check_outlined, size: 18),
                label: const Text('Open place review'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: LinearProgressIndicator(),
            )
          else if (places.isEmpty)
            Text(
              'No staged places right now.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          else
            for (final place in places)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  Icons.add_location_alt_outlined,
                  color: theme.colorScheme.secondary,
                ),
                title: Text((place['name'] ?? 'Unnamed place').toString()),
                subtitle: Text(
                  [
                    place['district'],
                    place['category'],
                  ].where((v) => v != null && '$v'.isNotEmpty).join(' · '),
                ),
                onTap: onOpen,
              ),
        ],
      ),
    );
  }
}
