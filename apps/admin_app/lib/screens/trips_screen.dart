import 'dart:async';
import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../widgets/admin_widgets.dart';

class TripsScreen extends StatefulWidget {
  final ApiService? api;
  const TripsScreen({super.key, this.api});

  @override
  State<TripsScreen> createState() => _TripsScreenState();
}

class _TripsScreenState extends State<TripsScreen> {
  late final _api = widget.api ?? ApiService();
  final _searchController = TextEditingController();
  Timer? _debounce;
  String _query = '';
  String _status = 'all';
  int _offset = 0;
  static const int _pageSize = 25;
  late Future<Map<String, dynamic>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<Map<String, dynamic>> _load() => _api.getAdminTrips(
    query: _query,
    status: _status == 'all' ? null : _status,
    limit: _pageSize,
    offset: _offset,
  );

  void _reload() => setState(() => _future = _load());

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      setState(() {
        _query = value.trim();
        _offset = 0;
        _future = _load();
      });
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    _api.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AdminPage(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AdminPageHeader(
            title: 'Trip Information',
            description:
                'Inspect saved traveler trips, owners, destinations, dates, and budgets across Lakbay+.',
            action: OutlinedButton.icon(
              onPressed: _reload,
              icon: const Icon(Icons.refresh),
              label: const Text('Refresh'),
            ),
          ),
          const SizedBox(height: 24),
          AdminPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SizedBox(
                      width: 340,
                      child: TextField(
                        controller: _searchController,
                        onChanged: _onSearchChanged,
                        decoration: InputDecoration(
                          labelText: 'Search trips',
                          hintText: 'Trip title, traveler name, or email',
                          prefixIcon: const Icon(Icons.search),
                          suffixIcon: _query.isEmpty
                              ? null
                              : IconButton(
                                  tooltip: 'Clear search',
                                  onPressed: () {
                                    _searchController.clear();
                                    setState(() {
                                      _query = '';
                                      _offset = 0;
                                      _future = _load();
                                    });
                                  },
                                  icon: const Icon(Icons.clear),
                                ),
                        ),
                      ),
                    ),
                    DropdownButton<String>(
                      value: _status,
                      items: const [
                        DropdownMenuItem(value: 'all', child: Text('All statuses')),
                        DropdownMenuItem(value: 'planned', child: Text('Planned')),
                        DropdownMenuItem(value: 'ongoing', child: Text('Ongoing')),
                        DropdownMenuItem(value: 'completed', child: Text('Completed')),
                        DropdownMenuItem(value: 'archived', child: Text('Archived')),
                      ],
                      onChanged: (value) {
                        if (value == null) return;
                        setState(() {
                          _status = value;
                          _offset = 0;
                          _future = _load();
                        });
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                FutureBuilder<Map<String, dynamic>>(
                  future: _future,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return const Padding(
                        padding: EdgeInsets.symmetric(vertical: 32),
                        child: Center(child: CircularProgressIndicator()),
                      );
                    }
                    if (snapshot.hasError) {
                      return AdminMessage(
                        icon: Icons.error_outline,
                        title: 'Could not load trips',
                        message: snapshot.error.toString(),
                        isError: true,
                        action: OutlinedButton(
                          onPressed: _reload,
                          child: const Text('Retry'),
                        ),
                      );
                    }
                    final data = snapshot.data!;
                    final total = data['total_trips'] ?? 0;
                    final matching = (data['matching_trips'] as num?)?.toInt() ?? 0;
                    final items = (data['items'] as List?) ?? const [];

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          spacing: 12,
                          runSpacing: 8,
                          children: [
                            AdminBadge(label: 'Total trips: $total'),
                            AdminBadge(label: 'Showing: ${items.length} of $matching'),
                          ],
                        ),
                        const SizedBox(height: 16),
                        if (items.isEmpty)
                          const AdminMessage(
                            icon: Icons.route_outlined,
                            title: 'No trips found',
                            message:
                                'No traveler trips match the selected filters yet.',
                          )
                        else
                          for (final raw in items)
                            if (raw is Map<String, dynamic>) ...[
                              Padding(
                                padding: const EdgeInsets.symmetric(vertical: 8),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Wrap(
                                      spacing: 10,
                                      runSpacing: 6,
                                      crossAxisAlignment:
                                          WrapCrossAlignment.center,
                                      children: [
                                        Text(
                                          (raw['title'] ?? '').toString(),
                                          style: theme.textTheme.titleMedium,
                                        ),
                                        AdminBadge(
                                          label: (raw['status'] ?? 'planned')
                                              .toString(),
                                        ),
                                        AdminBadge(
                                          label:
                                              '${raw['traveler_count'] ?? 1} traveler(s)',
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      'Owner: ${raw['owner_name']} (${raw['owner_email']})',
                                      style: theme.textTheme.bodySmall,
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      'Budget: PHP ${raw['total_budget']} • Est. Cost: PHP ${raw['estimated_total_cost']}'
                                      '${raw['start_date'] != null ? ' • ${raw['start_date']} to ${raw['end_date'] ?? raw['start_date']}' : ''}',
                                      style: theme.textTheme.bodySmall,
                                    ),
                                    if (raw['destination_names'] is List &&
                                        (raw['destination_names'] as List)
                                            .isNotEmpty) ...[
                                      const SizedBox(height: 6),
                                      Text(
                                        'Stops: ${(raw['destination_names'] as List).join(' → ')}',
                                        style: theme.textTheme.bodyMedium,
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              const Divider(height: 20),
                            ],
                        if (matching > _pageSize) ...[
                          const SizedBox(height: 8),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              OutlinedButton(
                                onPressed: _offset == 0
                                    ? null
                                    : () => setState(() {
                                        _offset =
                                            (_offset - _pageSize).clamp(0, matching);
                                        _future = _load();
                                      }),
                                child: const Text('Previous'),
                              ),
                              const SizedBox(width: 12),
                              OutlinedButton(
                                onPressed: _offset + _pageSize >= matching
                                    ? null
                                    : () => setState(() {
                                        _offset += _pageSize;
                                        _future = _load();
                                      }),
                                child: const Text('Next'),
                              ),
                            ],
                          ),
                        ],
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
