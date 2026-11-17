import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/travel_repository.dart';
import '../theme/lakbay_theme.dart';

import '../design/lakbay_theme_controller.dart';
import '../design/lakbay_tokens.dart';
import '../design/lakbay_type.dart';
class SettingsScreen extends StatelessWidget {
  final TravelRepository repo;

  const SettingsScreen({super.key, required this.repo});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: repo,
      builder: (context, _) {
        final shortId = repo.travelerId.length > 8
            ? '${repo.travelerId.substring(0, 4)}...${repo.travelerId.substring(repo.travelerId.length - 4)}'
            : repo.travelerId;

        return Scaffold(
          backgroundColor: LkColors.bg,
          body: SafeArea(
            child: Column(
              children: [
                // Top Header: Circular < Back + Centered Settings
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
                  child: Row(
                    children: [
                      Material(
                        color: LkColors.s1,
                        shape: const CircleBorder(),
                        elevation: 1,
                        child: IconButton(
                          tooltip: 'Back',
                          onPressed: () => Navigator.of(context).pop(),
                          icon: Icon(
                            Icons.chevron_left_rounded,
                            size: 28,
                            color: LkColors.text,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          'Settings',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontFamily: LkType.displayFamily,
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                            color: LkColors.text,
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
                      const _SectionHeader('ACCOUNT'),
                      _SettingsItemCard(
                        icon: Icons.credit_card_outlined,
                        title: 'Payment',
                        trailingText: repo.preferredPaymentMethod,
                        showChevron: false,
                        onTap: () => _showPaymentSheet(context),
                      ),
                      _SettingsItemCard(
                        icon: Icons.link_rounded,
                        title: 'Connected apps',
                        trailingText: repo.aiService.isConfigured
                            ? 'Lakbay AI + Mapbox'
                            : 'Not connected',
                        onTap: () => _showConnectedAppsSheet(context),
                      ),
                      _SettingsItemCard(
                        icon: Icons.tune_rounded,
                        title: 'Preferences',
                        trailingText: '${repo.preferencesCompletionPercent}% complete',
                        onTap: () => _showPreferencesSheet(context),
                      ),

                      const SizedBox(height: 16),
                      const _SectionHeader('PREFERENCES'),
                      _SettingsItemCard(
                        icon: Icons.translate_rounded,
                        title: 'Language',
                        trailingText: repo.languageDisplayName,
                        onTap: () => _showLanguageSheet(context),
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
                      const _AppearanceCard(),
                      _SettingsToggleCard(
                        icon: Icons.notifications_none_rounded,
                        title: 'Notifications',
                        value: repo.priceDropAlertsEnabled,
                        onChanged: repo.setNotificationsEnabled,
                      ),
                      _SettingsToggleCard(
                        icon: Icons.my_location_rounded,
                        title: 'Location sharing',
                        value: repo.locationSharingEnabled,
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
                              backgroundColor: LkColors.s3,
                            ),
                          );
                        },
                      ),

                      const SizedBox(height: 16),
                      const _SectionHeader('APP'),
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
                      Center(
                        child: Text(
                          'Version: 1.0.0+1',
                          style: TextStyle(
                            fontSize: 12.5,
                            color: LkColors.muted,
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
                                backgroundColor: LkColors.s3,
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
                              style: TextStyle(
                                fontSize: 12.5,
                                color: LkColors.muted,
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

  void _showPaymentSheet(BuildContext context) {
    final options = [
      'Set at checkout',
      'GCash / Maya',
      'Credit / Debit Card',
      'Apple Pay / Google Pay',
    ];
    showModalBottomSheet(
      context: context,
      backgroundColor: LkColors.s1,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Default Payment Method',
              style: TextStyle(
                fontFamily: LkType.displayFamily,
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: LkColors.text,
              ),
            ),
            const SizedBox(height: 10),
            for (final opt in options)
              ListTile(
                title: Text(opt),
                trailing: repo.preferredPaymentMethod == opt
                    ? Icon(
                        Icons.check_circle,
                        color: LkColors.lagoon,
                      )
                    : null,
                onTap: () {
                  repo.setPreferredPaymentMethod(opt);
                  Navigator.of(ctx).pop();
                },
              ),
          ],
        ),
      ),
    );
  }

  void _showConnectedAppsSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: LkColors.s1,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Connected Apps & APIs',
              style: TextStyle(
                fontFamily: LkType.displayFamily,
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: LkColors.text,
              ),
            ),
            const SizedBox(height: 12),
            _StatusRow('Lakbay AI (server)', repo.aiService.isConfigured),
            _StatusRow('Mapbox Maps & Routes', repo.mapbox.hasValidToken),
            _StatusRow('Cloudinary Media', repo.cloudinary.isConfigured),
          ],
        ),
      ),
    );
  }

  void _showPreferencesSheet(BuildContext context) {
    final companions = ['Solo', 'Couple', 'Family', 'Friends'];

    showModalBottomSheet(
      context: context,
      backgroundColor: LkColors.s1,
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
              Text(
                'Travel Preferences',
                style: TextStyle(
                  fontFamily: LkType.displayFamily,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: LkColors.text,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'What do you like?',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
              ),
              const SizedBox(height: 8),
              if (repo.preferenceGroups.isEmpty)
                Text(
                  'Preferences load from Lakbay when you are online.',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: LkColors.muted,
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
                        selectedColor: LkColors.s2,
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
                          selected: repo.selectedVibes.contains(sub.key),
                          selectedColor: LkColors.s2,
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
                        selectedColor: LkColors.s2,
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
      backgroundColor: LkColors.s1,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Language',
              style: TextStyle(
                fontFamily: LkType.displayFamily,
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: LkColors.text,
              ),
            ),
            const SizedBox(height: 8),
            for (final (code, label) in langs)
              ListTile(
                title: Text(label),
                trailing: repo.locale == code
                    ? Icon(
                        Icons.check_circle,
                        color: LkColors.lagoon,
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
      backgroundColor: LkColors.s1,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Currency',
              style: TextStyle(
                fontFamily: LkType.displayFamily,
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: LkColors.text,
              ),
            ),
            const SizedBox(height: 8),
            for (final (code, label) in codes)
              ListTile(
                title: Text(label),
                trailing: repo.currency == code
                    ? Icon(
                        Icons.check_circle,
                        color: LkColors.lagoon,
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
      backgroundColor: LkColors.s1,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Temperature Unit',
              style: TextStyle(
                fontFamily: LkType.displayFamily,
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: LkColors.text,
              ),
            ),
            const SizedBox(height: 8),
            ListTile(
              title: const Text('Celsius (°C)'),
              trailing: repo.temperatureUnit == 'C'
                  ? Icon(
                      Icons.check_circle,
                      color: LkColors.lagoon,
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
                  ? Icon(
                      Icons.check_circle,
                      color: LkColors.lagoon,
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
              backgroundColor: LkColors.s3,
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
          'Lakbay+ v1.0.0+1\n\nHigh-grade AI travel planner & Mapbox route companion scoped for Davao Region (Region XI, Philippines), powered by Groq, Gemini Fallback, Mapbox & Cloudinary.',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            style: FilledButton.styleFrom(
              backgroundColor: LkColors.s3,
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
      backgroundColor: LkColors.s1,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Photo Credits',
              style: TextStyle(
                fontFamily: LkType.displayFamily,
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: LkColors.text,
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
          'Lakbay+ Travel Companion\nDavao Region XI Explorer Edition\nDavao City, Philippines\n\nAll coordinates & routes are scoped within Region XI (Davao City, Samal IGaCoS, Davao del Norte, Davao Oriental, Davao del Sur, Davao de Oro, and Davao Occidental).',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            style: FilledButton.styleFrom(
              backgroundColor: LkColors.s3,
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
              backgroundColor: LkColors.s3,
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
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.0,
          color: LkColors.muted,
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
    final fgColor = isDestructive ? Colors.redAccent : LkColors.text;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: LkColors.s1,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: LkColors.stroke),
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
                          style: TextStyle(
                            fontSize: 13.5,
                            color: LkColors.muted,
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
                if (showChevron) ...[
                  const SizedBox(width: 6),
                  Icon(
                    Icons.chevron_right_rounded,
                    color: LkColors.muted,
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

/// Light, dark, or follow the phone.
class _AppearanceCard extends StatelessWidget {
  const _AppearanceCard();

  @override
  Widget build(BuildContext context) {
    final controller = LkThemeController.instance;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        decoration: BoxDecoration(
          color: LkColors.s1,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: LkColors.stroke),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.brightness_6_outlined, color: LkColors.text, size: 22),
                const SizedBox(width: 14),
                Text(
                  'Appearance',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                    color: LkColors.text,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<ThemeMode>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(
                    value: ThemeMode.system,
                    label: Text('Auto'),
                    icon: Icon(Icons.phone_android_rounded, size: 18),
                  ),
                  ButtonSegment(
                    value: ThemeMode.light,
                    label: Text('Light'),
                    icon: Icon(Icons.light_mode_outlined, size: 18),
                  ),
                  ButtonSegment(
                    value: ThemeMode.dark,
                    label: Text('Dark'),
                    icon: Icon(Icons.dark_mode_outlined, size: 18),
                  ),
                ],
                selected: {controller.mode},
                onSelectionChanged: (s) => controller.setMode(s.first),
                style: SegmentedButton.styleFrom(
                  backgroundColor: LkColors.s2,
                  foregroundColor: LkColors.text,
                  selectedBackgroundColor: LkColors.mango,
                  selectedForegroundColor: LkColors.mangoInk,
                  side: BorderSide(color: LkColors.stroke),
                ),
              ),
            ),
          ],
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

  const _SettingsToggleCard({
    required this.icon,
    required this.title,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: LkColors.s1,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: LkColors.stroke),
      ),
      child: Row(
        children: [
          Icon(icon, color: LkColors.text, size: 22),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 15,
                color: LkColors.text,
              ),
            ),
          ),
          Switch(
            value: value,
            activeTrackColor: LkColors.mango,
            activeThumbColor: Colors.white,
            onChanged: onChanged,
          ),
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
            color: active ? LkColors.lagoon : LkColors.muted,
          ),
        ),
        backgroundColor: active
            ? LkColors.s3.withValues(alpha: 0.12)
            : LkColors.bg,
      ),
    );
  }
}
