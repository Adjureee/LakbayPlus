import 'dart:convert';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/location_service.dart';
import '../services/travel_repository.dart';
import '../theme/lakbay_theme.dart';

class SettingsScreen extends StatelessWidget {
  final TravelRepository repo;
  final bool? showDiagnosticsOverride;

  const SettingsScreen({
    super.key,
    required this.repo,
    this.showDiagnosticsOverride,
  });

  bool get _showDebugDiagnostics => showDiagnosticsOverride ?? kDebugMode;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: repo,
      builder: (context, _) {
        final shortId = repo.travelerId.length > 8
            ? '${repo.travelerId.substring(0, 4)}...${repo.travelerId.substring(repo.travelerId.length - 4)}'
            : repo.travelerId;

        return Scaffold(
          backgroundColor: LakbayColors.canvasBg,
          body: SafeArea(
            child: Column(
              children: [
                // Top Header: Circular < Back + Centered Settings
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
                  child: Row(
                    children: [
                      Material(
                        color: Colors.white,
                        shape: const CircleBorder(),
                        elevation: 1,
                        child: IconButton(
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(
                            Icons.chevron_left_rounded,
                            size: 28,
                            color: LakbayColors.tealDeep,
                          ),
                        ),
                      ),
                      const Expanded(
                        child: Text(
                          'Settings',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontFamily: 'FigGrotesk',
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                            color: LakbayColors.tealDeep,
                          ),
                        ),
                      ),
                      const SizedBox(width: 48),
                    ],
                  ),
                ),

                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 32),
                    children: [
                      const _SectionHeader('PREFERENCES'),
                      _SettingsItemCard(
                        icon: Icons.tune_rounded,
                        title: 'Preferences',
                        trailingText: '${repo.preferencesCompletionPercent}% complete',
                        onTap: () => _showPreferencesSheet(context),
                      ),
                      _SettingsItemCard(
                        icon: Icons.translate_rounded,
                        title: 'Language',
                        trailingText: repo.languageDisplayName,
                        onTap: () => _showLanguageSheet(context),
                      ),
                      _SettingsItemCard(
                        icon: Icons.auto_awesome_outlined,
                        title: 'AI language',
                        trailingText: repo.aiLanguageDisplayName,
                        onTap: () => _showAiLanguageSheet(context),
                      ),
                      _SettingsItemCard(
                        icon: Icons.attach_money_rounded,
                        title: 'Currency',
                        trailingText: repo.currencyDisplayName,
                        onTap: () => _showCurrencySheet(context),
                      ),
                      _SettingsItemCard(
                        icon: Icons.thermostat_outlined,
                        title: 'Temperature',
                        trailingText: repo.temperatureUnit == 'C'
                            ? 'Celsius (°C)'
                            : 'Fahrenheit (°F)',
                        onTap: () => _showTemperatureSheet(context),
                      ),
                      _SettingsToggleCard(
                        icon: Icons.notifications_none_rounded,
                        title: 'Notifications',
                        value: repo.priceDropAlertsEnabled,
                        onChanged: repo.setNotificationsEnabled,
                      ),
                      _SettingsToggleCard(
                        icon: Icons.insights_outlined,
                        title: 'Share anonymous usage and crash reports',
                        subtitle:
                            'Off by default. Turn this on to help us fix '
                            'crashes and see which steps people get stuck on. '
                            'We never send your messages, name, email or GPS '
                            'position.',
                        value: repo.analyticsEnabled,
                        onChanged: repo.setAnalyticsEnabled,
                      ),
                      _SettingsLocationCard(
                        value: repo.locationSharingEnabled,
                        statusText: _locationStatusSummary(repo),
                        showOpenSettings:
                            repo.lastLocationOutcome ==
                                LocationPermissionOutcome.deniedForever ||
                            repo.lastLocationOutcome ==
                                LocationPermissionOutcome.serviceDisabled ||
                            !repo.locationSharingEnabled,
                        onOpenSettings: () => repo.openLocationAppSettings(
                          openLocationMenu:
                              repo.lastLocationOutcome ==
                              LocationPermissionOutcome.serviceDisabled,
                        ),
                        onChanged: (enabled) async {
                          if (!enabled) {
                            repo.setLocationSharingEnabled(false);
                            return;
                          }
                          final result =
                              await repo.requestAndSaveCurrentLocation();
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(result.statusMessage),
                              action: (result.isPermanentlyDenied ||
                                      result.isServiceDisabled)
                                  ? SnackBarAction(
                                      label: 'Open settings',
                                      textColor: LakbayColors.primaryLight,
                                      onPressed: () =>
                                          repo.openLocationAppSettings(
                                        openLocationMenu:
                                            result.isServiceDisabled,
                                      ),
                                    )
                                  : null,
                              backgroundColor: LakbayColors.tealDeep,
                            ),
                          );
                        },
                      ),

                      const SizedBox(height: 16),
                      const _SectionHeader('APP'),
                      if (_showDebugDiagnostics)
                        _SettingsItemCard(
                          icon: Icons.developer_mode_rounded,
                          title: 'Connection diagnostics (Debug)',
                          trailingText: repo.aiService.isConfigured
                              ? 'Online'
                              : 'Offline',
                          onTap: () => _showDebugDiagnosticsSheet(context),
                        ),
                      _SettingsItemCard(
                        icon: Icons.download_rounded,
                        title: 'Download my data',
                        onTap: () => _showDownloadDataDialog(context),
                      ),
                      _SettingsItemCard(
                        icon: Icons.info_outline_rounded,
                        title: 'About',
                        trailingText: 'v1.0.0',
                        onTap: () => _showAboutDialog(context),
                      ),
                      _SettingsItemCard(
                        icon: Icons.photo_library_outlined,
                        title: 'Photo credits',
                        onTap: () => _showPhotoCreditsSheet(context),
                      ),
                      _SettingsItemCard(
                        icon: Icons.description_outlined,
                        title: 'Imprint',
                        onTap: () => _showImprintDialog(context),
                      ),
                      _SettingsItemCard(
                        icon: Icons.logout_rounded,
                        title: 'Log out',
                        showChevron: false,
                        onTap: () => _confirmLogout(context),
                      ),
                      _SettingsItemCard(
                        icon: Icons.delete_outline_rounded,
                        title: 'Delete account',
                        isDestructive: true,
                        showChevron: false,
                        onTap: () => _confirmDeleteAccount(context),
                      ),

                      const SizedBox(height: 24),

                      // Branded Footer + Copyable ID
                      const Center(child: LakbayBrandWordmark(fontSize: 22)),
                      const SizedBox(height: 6),
                      const Center(
                        child: Text(
                          'Version: 1.0.0+1',
                          style: TextStyle(
                            fontSize: 12.5,
                            color: LakbayColors.textSecondary,
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Center(
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () {
                            Clipboard.setData(
                              ClipboardData(text: repo.travelerId),
                            );
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content:
                                    Text('Copied traveler ID: ${repo.travelerId}'),
                                backgroundColor: LakbayColors.tealDeep,
                              ),
                            );
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            child: Text(
                              'ID $shortId • Tap to copy',
                              style: const TextStyle(
                                fontSize: 12.5,
                                color: LakbayColors.textSecondary,
                                fontWeight: FontWeight.w500,
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
    );
  }

  String _locationStatusSummary(TravelRepository repo) {
    if (repo.locationSharingEnabled && repo.hasUserLocation) {
      final place = repo.resolvedOriginLabel?.trim() ?? '';
      return place.isNotEmpty ? 'Allowed · $place' : 'Allowed';
    }
    return switch (repo.lastLocationOutcome) {
      LocationPermissionOutcome.deniedForever => 'Blocked in settings',
      LocationPermissionOutcome.serviceDisabled => 'Device location off',
      LocationPermissionOutcome.granted => 'Allowed',
      LocationPermissionOutcome.denied ||
      LocationPermissionOutcome.error => 'Not shared',
    };
  }

  void _showDebugDiagnosticsSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Connection Diagnostics (Debug)',
              style: TextStyle(
                fontFamily: 'FigGrotesk',
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: LakbayColors.tealDeep,
              ),
            ),
            const SizedBox(height: 12),
            _StatusRow('Lakbay+ Cloud API', repo.apiCatalog.isConfigured),
            _StatusRow('Lakbay+ Cloud Account', repo.isSignedIn),
            _StatusRow('Lakbay AI (server)', repo.aiService.isConfigured),
            _StatusRow('Maps & routes', repo.mapbox.hasValidToken),
            _StatusRow('Photo uploads', repo.cloudinary.isConfigured),
          ],
        ),
      ),
    );
  }

  void _showPreferencesSheet(BuildContext context) {
    final companions = ['Solo', 'Couple', 'Family', 'Friends'];

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Travel Preferences',
                style: TextStyle(
                  fontFamily: 'FigGrotesk',
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: LakbayColors.tealDeep,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'What do you like?',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
              ),
              const SizedBox(height: 8),
              if (repo.preferenceGroups.isEmpty)
                const Text(
                  'Preferences load from Lakbay when you are online.',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: LakbayColors.textSecondary,
                  ),
                )
              else
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final group in repo.preferenceGroups)
                      FilterChip(
                        label: Text('${group.label} · ${group.count}'),
                        tooltip: group.description,
                        selected: repo.selectedVibes.contains(group.key),
                        selectedColor: LakbayColors.primaryLight,
                        onSelected: (_) {
                          repo.toggleVibe(group.key);
                          setSheetState(() {});
                        },
                      ),
                  ],
                ),
              // Narrow a chosen group down (for example Waterfalls within
              // Nature attractions). Choosing none means all of them.
              for (final group in repo.preferenceGroups)
                if (repo.selectedVibes.contains(group.key) &&
                    group.subtypes.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(
                    '${group.label}: narrow it down (optional)',
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 12.5,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      for (final sub in group.subtypes)
                        FilterChip(
                          label: Text('${sub.label} · ${sub.count}'),
                          visualDensity: VisualDensity.compact,
                          selected: repo.selectedVibes.contains(sub.key),
                          selectedColor: LakbayColors.primaryLight,
                          onSelected: (_) {
                            repo.toggleVibe(sub.key);
                            setSheetState(() {});
                          },
                        ),
                    ],
                  ),
                ],
              const SizedBox(height: 14),
              const Text(
                'Travel Companion',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: companions
                    .map(
                      (c) => ChoiceChip(
                        label: Text(c),
                        selected: repo.travelCompanion == c,
                        selectedColor: LakbayColors.primaryLight,
                        onSelected: (_) {
                          repo.setTravelCompanion(c);
                          setSheetState(() {});
                        },
                      ),
                    )
                    .toList(),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    Navigator.of(context).pop();
                    repo.restartOnboarding();
                  },
                  child: const Text('Re-run AI Onboarding Wizard'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showLanguageSheet(BuildContext context) {
    const langs = [
      ('en', 'English'),
      ('fil', 'Filipino'),
      ('ceb', 'Cebuano / Bisaya'),
      ('es', 'Español'),
      ('fr', 'Français'),
    ];
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Language',
              style: TextStyle(
                fontFamily: 'FigGrotesk',
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: LakbayColors.tealDeep,
              ),
            ),
            const SizedBox(height: 8),
            for (final (code, label) in langs)
              ListTile(
                title: Text(label),
                trailing: repo.locale == code
                    ? const Icon(
                        Icons.check_circle,
                        color: LakbayColors.primary,
                      )
                    : null,
                onTap: () {
                  repo.setLocale(code);
                  Navigator.of(ctx).pop();
                },
              ),
          ],
        ),
      ),
    );
  }

  void _showAiLanguageSheet(BuildContext context) {
    const langs = [
      ('auto', 'Auto', 'Match the language of your message'),
      ('english', 'English', 'Replies and itineraries in English'),
      ('filipino', 'Filipino', 'Replies and itineraries in Filipino'),
      ('bisaya', 'Bisaya / Cebuano', 'Replies and itineraries in Bisaya'),
    ];
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'AI language',
              style: TextStyle(
                fontFamily: 'FigGrotesk',
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: LakbayColors.tealDeep,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Choose what language Lakbay AI uses in chat and trip itineraries.',
              style: TextStyle(
                fontSize: 12.5,
                color: LakbayColors.textSecondary,
              ),
            ),
            const SizedBox(height: 8),
            for (final (code, label, subtitle) in langs)
              ListTile(
                title: Text(label),
                subtitle: Text(
                  subtitle,
                  style: const TextStyle(fontSize: 12),
                ),
                trailing: repo.aiLanguage == code
                    ? const Icon(
                        Icons.check_circle,
                        color: LakbayColors.primary,
                      )
                    : null,
                onTap: () {
                  repo.setAiLanguage(code);
                  Navigator.of(ctx).pop();
                },
              ),
          ],
        ),
      ),
    );
  }

  void _showCurrencySheet(BuildContext context) {
    const codes = [
      ('PHP', 'Philippine Peso (PHP)'),
      ('USD', 'United States Dollar (USD)'),
      ('EUR', 'Euro (EUR)'),
      ('GBP', 'British Pound (GBP)'),
      ('AUD', 'Australian Dollar (AUD)'),
      ('JPY', 'Japanese Yen (JPY)'),
    ];
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Currency',
              style: TextStyle(
                fontFamily: 'FigGrotesk',
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: LakbayColors.tealDeep,
              ),
            ),
            const SizedBox(height: 8),
            for (final (code, label) in codes)
              ListTile(
                title: Text(label),
                trailing: repo.currency == code
                    ? const Icon(
                        Icons.check_circle,
                        color: LakbayColors.primary,
                      )
                    : null,
                onTap: () {
                  repo.setCurrency(code);
                  Navigator.of(ctx).pop();
                },
              ),
          ],
        ),
      ),
    );
  }

  void _showTemperatureSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Temperature Unit',
              style: TextStyle(
                fontFamily: 'FigGrotesk',
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: LakbayColors.tealDeep,
              ),
            ),
            const SizedBox(height: 8),
            ListTile(
              title: const Text('Celsius (°C)'),
              trailing: repo.temperatureUnit == 'C'
                  ? const Icon(
                      Icons.check_circle,
                      color: LakbayColors.primary,
                    )
                  : null,
              onTap: () {
                repo.setTemperatureUnit('C');
                Navigator.of(ctx).pop();
              },
            ),
            ListTile(
              title: const Text('Fahrenheit (°F)'),
              trailing: repo.temperatureUnit == 'F'
                  ? const Icon(
                      Icons.check_circle,
                      color: LakbayColors.primary,
                    )
                  : null,
              onTap: () {
                repo.setTemperatureUnit('F');
                Navigator.of(ctx).pop();
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showDownloadDataDialog(BuildContext context) {
    final exportPayload = const JsonEncoder.withIndent('  ').convert({
      'traveler_id': repo.travelerId,
      'name': '${repo.profile.firstName} ${repo.profile.lastName}',
      'email': repo.profile.email,
      'location': repo.profile.location,
      'currency': repo.currency,
      'saved_trips_count': repo.savedTrips.length,
      'saved_trips': repo.savedTrips.map((t) => t.title).toList(),
    });

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Download My Data'),
        content: SingleChildScrollView(
          child: SelectableText(
            exportPayload,
            style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: exportPayload));
              Navigator.of(ctx).pop();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Copied JSON export to clipboard.')),
              );
            },
            child: const Text('Copy JSON'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            style: FilledButton.styleFrom(
              backgroundColor: LakbayColors.tealDeep,
            ),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _showAboutDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('About Lakbay+'),
        content: const Text(
          'Lakbay+ v1.0.0+1\n\nAn AI travel planner and route companion for the Davao Region, Philippines.',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            style: FilledButton.styleFrom(
              backgroundColor: LakbayColors.tealDeep,
            ),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _showPhotoCreditsSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Photo Credits',
              style: TextStyle(
                fontFamily: 'FigGrotesk',
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: LakbayColors.tealDeep,
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 240,
              child: ListView(
                children: repo.backdrops
                    .map(
                      (b) => ListTile(
                        dense: true,
                        title: Text(b.place),
                        subtitle: Text('Photo by ${b.photographer}'),
                      ),
                    )
                    .toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showImprintDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Imprint'),
        content: const Text(
          'Lakbay+ Travel Companion\nDavao City, Philippines\n\nPlaces and routes cover the Davao Region: Davao City, Samal Island, Davao del Norte, Davao Oriental, Davao del Sur, Davao de Oro and Davao Occidental.',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            style: FilledButton.styleFrom(
              backgroundColor: LakbayColors.tealDeep,
            ),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _confirmLogout(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Log out?'),
        content: const Text(
          'You will be returned to the Lakbay+ welcome onboarding screen.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              await repo.signOutBackend();
              if (!context.mounted) return;
              Navigator.of(context).pop();
              repo.restartOnboarding();
            },
            style: FilledButton.styleFrom(
              backgroundColor: LakbayColors.tealDeep,
            ),
            child: const Text('Log out'),
          ),
        ],
      ),
    );
  }

  void _confirmDeleteAccount(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete account?'),
        content: const Text(
          'This clears your local profile, saved trips, and chat history on this device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              Navigator.of(context).pop();
              repo.resetAccountData();
            },
            style: FilledButton.styleFrom(
              backgroundColor: Colors.redAccent,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;

  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.0,
          color: LakbayColors.textSecondary,
        ),
      ),
    );
  }
}

class _SettingsItemCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? trailingText;
  final bool showChevron;
  final bool isDestructive;
  final VoidCallback onTap;

  const _SettingsItemCard({
    required this.icon,
    required this.title,
    this.trailingText,
    this.showChevron = true,
    this.isDestructive = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final fgColor = isDestructive ? Colors.redAccent : LakbayColors.tealDeep;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: LakbayColors.cardBorder),
            ),
            child: Row(
              children: [
                Icon(icon, color: fgColor, size: 22),
                const SizedBox(width: 14),
                Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                    color: fgColor,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: trailingText != null
                      ? Text(
                          trailingText!,
                          textAlign: TextAlign.end,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13.5,
                            color: LakbayColors.textSecondary,
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
                if (showChevron) ...[
                  const SizedBox(width: 6),
                  const Icon(
                    Icons.chevron_right_rounded,
                    color: LakbayColors.textSecondary,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SettingsToggleCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final bool value;
  final ValueChanged<bool> onChanged;
  final String? subtitle;

  const _SettingsToggleCard({
    required this.icon,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: LakbayColors.cardBorder),
      ),
      child: Row(
        children: [
          Icon(icon, color: LakbayColors.tealDeep, size: 22),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                    color: LakbayColors.tealDeep,
                  ),
                ),
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      subtitle!,
                      style: const TextStyle(
                        fontSize: 12.5,
                        height: 1.3,
                        color: LakbayColors.textMuted,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Switch(
            value: value,
            activeTrackColor: LakbayColors.tealDeep,
            activeThumbColor: Colors.white,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

class _SettingsLocationCard extends StatelessWidget {
  final bool value;
  final String statusText;
  final bool showOpenSettings;
  final VoidCallback onOpenSettings;
  final ValueChanged<bool> onChanged;

  const _SettingsLocationCard({
    required this.value,
    required this.statusText,
    required this.showOpenSettings,
    required this.onOpenSettings,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
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
              const Icon(
                Icons.my_location_rounded,
                color: LakbayColors.tealDeep,
                size: 22,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Location sharing',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                        color: LakbayColors.tealDeep,
                      ),
                    ),
                    Text(
                      statusText,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: LakbayColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              Switch(
                value: value,
                activeTrackColor: LakbayColors.tealDeep,
                activeThumbColor: Colors.white,
                onChanged: onChanged,
              ),
            ],
          ),
          if (showOpenSettings) ...[
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: onOpenSettings,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                icon: const Icon(Icons.settings_applications_outlined, size: 16),
                label: const Text(
                  'Open app settings',
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  final String label;
  final bool active;

  const _StatusRow(this.label, this.active);

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
      trailing: Chip(
        label: Text(
          active ? 'Connected' : 'Pending .env',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: active ? LakbayColors.successGreen : LakbayColors.textSecondary,
          ),
        ),
        backgroundColor: active
            ? LakbayColors.successGreen.withValues(alpha: 0.12)
            : LakbayColors.canvasBg,
      ),
    );
  }
}
