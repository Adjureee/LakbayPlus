import 'dart:async';
import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../widgets/admin_widgets.dart';

class UsersScreen extends StatefulWidget {
  final ApiService? api;
  const UsersScreen({super.key, this.api});

  @override
  State<UsersScreen> createState() => _UsersScreenState();
}

class _UsersScreenState extends State<UsersScreen> {
  late final _api = widget.api ?? ApiService();
  final _searchController = TextEditingController();
  Timer? _debounce;
  String _query = '';
  int _offset = 0;
  static const int _pageSize = 20;
  int? _updatingUserId;
  String? _actionError;

  late Future<Map<String, dynamic>> _profileFuture;
  late Future<Map<String, dynamic>> _directoryFuture;

  @override
  void initState() {
    super.initState();
    _profileFuture = _api.getCurrentUser();
    _directoryFuture = _loadDirectory();
  }

  Future<Map<String, dynamic>> _loadDirectory() => _api.getAdminUsers(
    query: _query,
    limit: _pageSize,
    offset: _offset,
  );

  void _reload() {
    setState(() {
      _actionError = null;
      _profileFuture = _api.getCurrentUser();
      _directoryFuture = _loadDirectory();
    });
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      setState(() {
        _query = value.trim();
        _offset = 0;
        _directoryFuture = _loadDirectory();
      });
    });
  }

  Future<void> _toggleActive(Map<String, dynamic> item) async {
    final userId = item['user_id'] as int?;
    final current = item['is_active'] == true;
    if (userId == null || _updatingUserId != null) return;
    setState(() {
      _updatingUserId = userId;
      _actionError = null;
    });
    try {
      await _api.updateAdminUserStatus(userId, isActive: !current);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            !current
                ? 'Account reactivated.'
                : 'Account deactivated and active sessions revoked.',
          ),
        ),
      );
      setState(() {
        _updatingUserId = null;
        _directoryFuture = _loadDirectory();
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _updatingUserId = null;
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
            title: 'User Accounts',
            description:
                'Search registered traveler and administrator accounts, monitor active sessions, and manage account status.',
            action: OutlinedButton.icon(
              onPressed: _reload,
              icon: const Icon(Icons.refresh),
              label: const Text('Refresh'),
            ),
          ),
          const SizedBox(height: 24),
          FutureBuilder<Map<String, dynamic>>(
            future: _profileFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const AdminPanel(
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              if (snapshot.hasError) {
                return AdminMessage(
                  icon: Icons.error_outline,
                  title: 'Could not load your account',
                  message: snapshot.error.toString(),
                  isError: true,
                  action: OutlinedButton(
                    onPressed: _reload,
                    child: const Text('Retry'),
                  ),
                );
              }
              final user = snapshot.data!;
              return AdminPanel(
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Signed-in administrator',
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 10,
                            runSpacing: 8,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text(
                                (user['full_name'] ?? '').toString(),
                                style: theme.textTheme.titleLarge,
                              ),
                              AdminBadge(
                                label: (user['role'] ?? '').toString(),
                              ),
                              AdminBadge(
                                label: user['is_active'] == true
                                    ? 'Active'
                                    : 'Inactive',
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text((user['email'] ?? '').toString()),
                        ],
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: () =>
                          Navigator.pushReplacementNamed(context, '/profile'),
                      icon: const Icon(Icons.manage_accounts_outlined),
                      label: const Text('Manage profile'),
                    ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 24),
          AdminPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _searchController,
                  onChanged: _onSearchChanged,
                  decoration: InputDecoration(
                    labelText: 'Search accounts',
                    hintText: 'Name or email address',
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
                                _directoryFuture = _loadDirectory();
                              });
                            },
                            icon: const Icon(Icons.clear),
                          ),
                  ),
                ),
                if (_actionError != null) ...[
                  const SizedBox(height: 16),
                  AdminMessage(
                    icon: Icons.error_outline,
                    title: 'Account update failed',
                    message: _actionError!,
                    isError: true,
                  ),
                ],
                const SizedBox(height: 20),
                FutureBuilder<Map<String, dynamic>>(
                  future: _directoryFuture,
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
                        title: 'Could not load account directory',
                        message: snapshot.error.toString(),
                        isError: true,
                        action: OutlinedButton(
                          onPressed: _reload,
                          child: const Text('Retry'),
                        ),
                      );
                    }
                    final data = snapshot.data!;
                    final total = data['total_users'] ?? 0;
                    final signedIn = data['signed_in_users'] ?? 0;
                    final matching = (data['matching_users'] as num?)?.toInt() ?? 0;
                    final items = (data['items'] as List?) ?? const [];

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          spacing: 12,
                          runSpacing: 8,
                          children: [
                            AdminBadge(label: 'Total accounts: $total'),
                            AdminBadge(label: 'Signed in: $signedIn'),
                            AdminBadge(label: 'Showing: ${items.length} of $matching'),
                          ],
                        ),
                        const SizedBox(height: 16),
                        if (items.isEmpty)
                          const AdminMessage(
                            icon: Icons.people_outline,
                            title: 'No matching accounts',
                            message:
                                'No accounts matched your current search query.',
                          )
                        else
                          for (final raw in items)
                            if (raw is Map<String, dynamic>) ...[
                              _AccountRow(
                                item: raw,
                                busy: _updatingUserId == raw['user_id'],
                                onToggleActive: () => _toggleActive(raw),
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
                                        _directoryFuture = _loadDirectory();
                                      }),
                                child: const Text('Previous'),
                              ),
                              const SizedBox(width: 12),
                              OutlinedButton(
                                onPressed: _offset + _pageSize >= matching
                                    ? null
                                    : () => setState(() {
                                        _offset += _pageSize;
                                        _directoryFuture = _loadDirectory();
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

class _AccountRow extends StatelessWidget {
  const _AccountRow({
    required this.item,
    required this.busy,
    required this.onToggleActive,
  });

  final Map<String, dynamic> item;
  final bool busy;
  final VoidCallback onToggleActive;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isActive = item['is_active'] == true;
    final hasSession = item['has_active_session'] == true;
    final role = (item['role'] ?? 'traveler').toString();

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
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
                    (item['full_name'] ?? '').toString(),
                    style: theme.textTheme.titleMedium,
                  ),
                  AdminBadge(label: role),
                  AdminBadge(
                    label: isActive ? 'Active' : 'Inactive',
                    color: isActive ? Colors.teal : Colors.redAccent,
                  ),
                  if (hasSession)
                    const AdminBadge(
                      label: 'Signed in',
                      color: Colors.green,
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                (item['email'] ?? '').toString(),
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        OutlinedButton(
          onPressed: busy ? null : onToggleActive,
          child: Text(
            busy
                ? 'Updating…'
                : (isActive ? 'Deactivate' : 'Reactivate'),
          ),
        ),
      ],
    );
  }
}
