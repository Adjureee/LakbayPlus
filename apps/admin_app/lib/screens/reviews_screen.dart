import 'dart:async';
import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../widgets/admin_widgets.dart';

class ReviewsScreen extends StatefulWidget {
  final ApiService? api;
  const ReviewsScreen({super.key, this.api});

  @override
  State<ReviewsScreen> createState() => _ReviewsScreenState();
}

class _ReviewsScreenState extends State<ReviewsScreen> {
  late final _api = widget.api ?? ApiService();
  final _searchController = TextEditingController();
  Timer? _debounce;
  String _query = '';
  String _status = 'active';
  int _offset = 0;
  static const int _pageSize = 25;
  int? _archivingId;
  String? _actionError;

  late Future<Map<String, dynamic>> _reviewsFuture;
  late Future<Map<String, dynamic>> _summaryFuture;

  @override
  void initState() {
    super.initState();
    _reviewsFuture = _loadReviews();
    _summaryFuture = _loadSummary();
  }

  Future<Map<String, dynamic>> _loadReviews() => _api.getAdminReviews(
    query: _query,
    status: _status,
    limit: _pageSize,
    offset: _offset,
  );

  Future<Map<String, dynamic>> _loadSummary() async {
    try {
      return await _api.getAppAssessmentSummary(windowDays: 30);
    } catch (_) {
      return const <String, dynamic>{};
    }
  }

  void _reload() {
    setState(() {
      _actionError = null;
      _reviewsFuture = _loadReviews();
      _summaryFuture = _loadSummary();
    });
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      setState(() {
        _query = value.trim();
        _offset = 0;
        _reviewsFuture = _loadReviews();
      });
    });
  }

  Future<void> _archiveReview(int reviewId) async {
    if (_archivingId != null) return;
    setState(() {
      _archivingId = reviewId;
      _actionError = null;
    });
    try {
      await _api.archiveAdminReview(reviewId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Review archived.')),
      );
      setState(() {
        _archivingId = null;
        _reviewsFuture = _loadReviews();
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _archivingId = null;
        _actionError = error.toString();
      });
    }
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
            title: 'Reviews & Feedback',
            description:
                'Inspect traveler ratings, comments, and app evaluation summaries across trips and destinations.',
            action: OutlinedButton.icon(
              onPressed: _reload,
              icon: const Icon(Icons.refresh),
              label: const Text('Refresh'),
            ),
          ),
          const SizedBox(height: 20),
          FutureBuilder<Map<String, dynamic>>(
            future: _summaryFuture,
            builder: (context, snapshot) {
              final data = snapshot.data;
              if (data == null || data.isEmpty) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(bottom: 20),
                child: AdminPanel(
                  child: Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        '30-day app evaluation:',
                        style: theme.textTheme.titleSmall,
                      ),
                      AdminBadge(
                        label: 'Assessments: ${data['assessment_count'] ?? 0}',
                      ),
                      if (data['average_overall_score'] != null)
                        AdminBadge(
                          label:
                              'Avg score: ${data['average_overall_score']} / 5',
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
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
                          labelText: 'Search feedback',
                          hintText: 'Comment, destination, trip, or traveler',
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
                                      _reviewsFuture = _loadReviews();
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
                        DropdownMenuItem(value: 'active', child: Text('Active')),
                        DropdownMenuItem(value: 'deleted', child: Text('Archived')),
                        DropdownMenuItem(value: 'all', child: Text('All')),
                      ],
                      onChanged: (value) {
                        if (value == null) return;
                        setState(() {
                          _status = value;
                          _offset = 0;
                          _reviewsFuture = _loadReviews();
                        });
                      },
                    ),
                  ],
                ),
                if (_actionError != null) ...[
                  const SizedBox(height: 16),
                  AdminMessage(
                    icon: Icons.error_outline,
                    title: 'Moderation update failed',
                    message: _actionError!,
                    isError: true,
                  ),
                ],
                const SizedBox(height: 20),
                FutureBuilder<Map<String, dynamic>>(
                  future: _reviewsFuture,
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
                        title: 'Could not load reviews',
                        message: snapshot.error.toString(),
                        isError: true,
                        action: OutlinedButton(
                          onPressed: _reload,
                          child: const Text('Retry'),
                        ),
                      );
                    }
                    final data = snapshot.data!;
                    final total = data['total_reviews'] ?? 0;
                    final matching = (data['matching_reviews'] as num?)?.toInt() ?? 0;
                    final items = (data['items'] as List?) ?? const [];

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          spacing: 12,
                          runSpacing: 8,
                          children: [
                            AdminBadge(label: 'Total reviews: $total'),
                            AdminBadge(label: 'Showing: ${items.length} of $matching'),
                          ],
                        ),
                        const SizedBox(height: 16),
                        if (items.isEmpty)
                          const AdminMessage(
                            icon: Icons.rate_review_outlined,
                            title: 'No reviews found',
                            message:
                                'No traveler feedback matched the selected filter yet.',
                          )
                        else
                          for (final raw in items)
                            if (raw is Map<String, dynamic>) ...[
                              _ReviewRow(
                                item: raw,
                                busy: _archivingId == raw['trip_review_id'],
                                onArchive: raw['status'] == 'active'
                                    ? () => _archiveReview(
                                        raw['trip_review_id'] as int,
                                      )
                                    : null,
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
                                        _reviewsFuture = _loadReviews();
                                      }),
                                child: const Text('Previous'),
                              ),
                              const SizedBox(width: 12),
                              OutlinedButton(
                                onPressed: _offset + _pageSize >= matching
                                    ? null
                                    : () => setState(() {
                                        _offset += _pageSize;
                                        _reviewsFuture = _loadReviews();
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

class _ReviewRow extends StatelessWidget {
  const _ReviewRow({
    required this.item,
    required this.busy,
    this.onArchive,
  });

  final Map<String, dynamic> item;
  final bool busy;
  final VoidCallback? onArchive;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dest = item['destination_name']?.toString();
    final comment = item['comments']?.toString();

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    (item['trip_title'] ?? '').toString(),
                    style: theme.textTheme.titleMedium,
                  ),
                  if (dest != null && dest.isNotEmpty)
                    AdminBadge(label: dest),
                  AdminBadge(
                    label:
                        'Overall ${item['overall_experience_rating'] ?? '-'} / 5',
                  ),
                  AdminBadge(
                    label: (item['status'] ?? 'active').toString(),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'By ${item['full_name']} (${item['email']}) • '
                'Accuracy ${item['accuracy_rating']}/5 • '
                'Route ${item['route_efficiency_rating']}/5 • '
                'Budget ${item['budget_adherence_rating']}/5',
                style: theme.textTheme.bodySmall,
              ),
              if (comment != null && comment.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(comment, style: theme.textTheme.bodyMedium),
              ],
            ],
          ),
        ),
        if (onArchive != null) ...[
          const SizedBox(width: 12),
          OutlinedButton(
            onPressed: busy ? null : onArchive,
            child: Text(busy ? 'Archiving…' : 'Archive'),
          ),
        ],
      ],
    );
  }
}
