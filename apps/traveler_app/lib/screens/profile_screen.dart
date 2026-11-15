import 'package:flutter/material.dart';
import '../models/travel_models.dart';
import '../services/travel_repository.dart';
import '../theme/lakbay_theme.dart';
import '../widgets/lakbay_image.dart';
import 'auth_screen.dart';
import 'settings_screen.dart';
import 'trip_detail_screen.dart';

class ProfileScreen extends StatelessWidget {
  final TravelRepository repo;

  const ProfileScreen({super.key, required this.repo});

  @override
  Widget build(BuildContext context) {
    final profile = repo.profile;
    final trips = repo.savedTrips;
    final previewTrips = trips.take(2).toList();
    final coverAsset = trips.isNotEmpty
        ? trips.first.heroAsset
        : 'assets/home_backdrops/01-samal-island.jpg';

    return Scaffold(
      backgroundColor: LakbayColors.canvasBg,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 110),
          children: [
            const Text(
              'Profile',
              style: TextStyle(
                fontSize: 30,
                fontWeight: FontWeight.w800,
                color: LakbayColors.tealDeep,
                letterSpacing: -0.6,
              ),
            ),
            const SizedBox(height: 14),

            // Cover banner + Avatar + Edit button
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: LakbayColors.cardBorder),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      SizedBox(
                        height: 120,
                        width: double.infinity,
                        child: Image.asset(
                          coverAsset,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => Container(
                            decoration: const BoxDecoration(
                              gradient: LakbayColors.deepTealGradient,
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        top: 12,
                        right: 12,
                        child: Material(
                          color: Colors.white.withValues(alpha: 0.94),
                          borderRadius: BorderRadius.circular(24),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(24),
                            onTap: () => _showEditProfileSheet(context),
                            child: const Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 7,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.edit_outlined,
                                    size: 16,
                                    color: LakbayColors.tealDeep,
                                  ),
                                  SizedBox(width: 6),
                                  Text(
                                    'Edit',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w700,
                                      fontSize: 13,
                                      color: LakbayColors.tealDeep,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        left: 18,
                        bottom: -26,
                        child: Container(
                          width: 62,
                          height: 62,
                          decoration: BoxDecoration(
                            color: LakbayColors.primaryLight,
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 3),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            profile.initials,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                              color: LakbayColors.primaryDark,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 34),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${profile.firstName} ${profile.lastName}',
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                            color: LakbayColors.tealDeep,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          profile.headline.isNotEmpty
                              ? profile.headline
                              : '${profile.location.trim().isNotEmpty ? profile.location.trim() : "Detecting location…"} • ${repo.travelCompanion} Traveler',
                          style: const TextStyle(
                            fontSize: 13,
                            color: LakbayColors.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: LakbayColors.canvasBg,
                            borderRadius: BorderRadius.circular(18),
                          ),
                          child: Row(
                            children: [
                              const Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Your Davao travel advisor',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w700,
                                        fontSize: 14,
                                        color: LakbayColors.tealDeep,
                                      ),
                                    ),
                                    SizedBox(height: 2),
                                    Text(
                                      'Plans with you, maps routes & stays on call.',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: LakbayColors.textSecondary,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 10),
                              ElevatedButton.icon(
                                onPressed: () => repo.setActiveNavIndex(2),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: LakbayColors.primaryLight,
                                  foregroundColor: LakbayColors.primaryDark,
                                  elevation: 0,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 10,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(24),
                                  ),
                                ),
                                icon: const Icon(Icons.auto_awesome, size: 16),
                                label: const Text(
                                  'Ask AI',
                                  style: TextStyle(fontWeight: FontWeight.w700),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 22),

            // Your trips section
            Row(
              children: [
                Text(
                  'Your trips • ${trips.length}',
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: LakbayColors.tealDeep,
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => repo.setActiveNavIndex(0),
                  child: const Text(
                    'See all',
                    style: TextStyle(
                      color: LakbayColors.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            for (final trip in previewTrips)
              _ProfileTripTile(
                trip: trip,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => TripDetailScreen(repo: repo, trip: trip),
                  ),
                ),
              ),

            const SizedBox(height: 18),
            const Text(
              'ACCOUNT',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.0,
                color: LakbayColors.textSecondary,
              ),
            ),
            const SizedBox(height: 8),
            _SettingsRowCard(
              icon: repo.isSignedIn
                  ? Icons.verified_user_outlined
                  : Icons.person_add_alt_1_outlined,
              title: repo.isSignedIn
                  ? 'Account (${repo.authSession!.email})'
                  : 'Create account / Sign in',
              trailingText: repo.isSignedIn ? 'Sign out' : 'Sync & save',
              onTap: () {
                if (repo.isSignedIn) {
                  repo.signOutBackend();
                } else {
                  Navigator.of(context).push(
                    MaterialPageRoute<bool>(
                      builder: (_) => AuthScreen(
                        repo: repo,
                        initialRegisterMode: true,
                      ),
                    ),
                  );
                }
              },
            ),
            const SizedBox(height: 10),
            _SettingsRowCard(
              icon: Icons.link_rounded,
              title: 'Connected apps',
              trailingText: repo.isSignedIn
                  ? 'Lakbay+ Cloud (${repo.authSession!.email})'
                  : (repo.apiCatalog.isConfigured
                      ? 'Tap to sign in'
                      : (repo.aiService.isConfigured
                          ? 'Lakbay AI + Mapbox'
                          : 'Offline mode')),
              onTap: () => _showConnectedAppsSheet(context),
            ),

            const SizedBox(height: 18),
            const Text(
              'APP',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.0,
                color: LakbayColors.textSecondary,
              ),
            ),
            const SizedBox(height: 8),
            _SettingsRowCard(
              icon: Icons.help_outline_rounded,
              title: 'Support',
              onTap: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Lakbay+ Davao Region XI Concierge • Region XI travel support active.',
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 10),
            _SettingsRowCard(
              icon: Icons.settings_outlined,
              title: 'Settings',
              trailingText: repo.currency,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => SettingsScreen(repo: repo),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showEditProfileSheet(BuildContext context) {
    final p = repo.profile;
    final firstCtrl = TextEditingController(text: p.firstName);
    final lastCtrl = TextEditingController(text: p.lastName);
    final headlineCtrl = TextEditingController(text: p.headline);
    final locationCtrl = TextEditingController(text: p.location);
    final emailCtrl = TextEditingController(text: p.email);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) {
        var isLocating = false;
        String? gpsNotice;
        return StatefulBuilder(
          builder: (ctx, setSheetState) => Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              14,
              20,
              MediaQuery.of(ctx).viewInsets.bottom + 24,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: LakbayColors.cardBorder,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Edit profile',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      color: LakbayColors.tealDeep,
                    ),
                  ),
                  const SizedBox(height: 18),
                  Center(
                    child: Stack(
                      children: [
                        CircleAvatar(
                          radius: 42,
                          backgroundColor: LakbayColors.primaryLight,
                          child: Text(
                            p.initials,
                            style: const TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.w800,
                              color: LakbayColors.primaryDark,
                            ),
                          ),
                        ),
                        Positioned(
                          right: 0,
                          bottom: 0,
                          child: Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              shape: BoxShape.circle,
                              border:
                                  Border.all(color: LakbayColors.primaryLight),
                            ),
                            child: const Icon(
                              Icons.camera_alt_outlined,
                              size: 16,
                              color: LakbayColors.tealDeep,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  _ProfileField(label: 'First name', controller: firstCtrl),
                  const SizedBox(height: 10),
                  _ProfileField(label: 'Last name', controller: lastCtrl),
                  const SizedBox(height: 10),
                  _ProfileField(
                    label: 'Headline',
                    controller: headlineCtrl,
                    hint: 'Add a line about how you travel...',
                  ),
                  const SizedBox(height: 10),
                  _ProfileField(
                    label: 'Location',
                    controller: locationCtrl,
                    hint: 'Where do you live?',
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: isLocating
                          ? null
                          : () async {
                              setSheetState(() {
                                isLocating = true;
                                gpsNotice = null;
                              });
                              final result =
                                  await repo.requestAndSaveCurrentLocation();
                              if (!ctx.mounted) return;
                              setSheetState(() {
                                isLocating = false;
                                if (result.granted) {
                                  locationCtrl.text = repo.profile.location;
                                }
                                gpsNotice = result.statusMessage;
                              });
                            },
                      icon: isLocating
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.my_location_rounded, size: 16),
                      label: Text(
                        isLocating ? 'Detecting GPS…' : 'Use current GPS',
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                  if (gpsNotice != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        gpsNotice!,
                        style: const TextStyle(
                          fontSize: 12,
                          color: LakbayColors.textSecondary,
                        ),
                      ),
                    ),
                  _ProfileField(label: 'Email', controller: emailCtrl),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () {
                        repo.updateProfile(
                          firstName: firstCtrl.text,
                          lastName: lastCtrl.text,
                          headline: headlineCtrl.text,
                          location: locationCtrl.text,
                          email: emailCtrl.text,
                        );
                        Navigator.of(ctx).pop();
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: LakbayColors.tealDeep,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 15),
                        shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(28),
                      ),
                    ),
                    child: const Text(
                      'Save',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        );
      },
    );
  }

  void _showConnectedAppsSheet(BuildContext context) {
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
              'Connected Services & Cloud Sync',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: LakbayColors.tealDeep,
              ),
            ),
            const SizedBox(height: 12),
            _StatusTile(
              'Lakbay+ Cloud API',
              repo.apiCatalog.isConfigured,
            ),
            _StatusTile('Lakbay+ Cloud Account', repo.isSignedIn),
            _StatusTile('Lakbay AI (server)', repo.aiService.isConfigured),
            _StatusTile('Mapbox Maps', repo.mapbox.hasValidToken),
            _StatusTile('Cloudinary Media', repo.cloudinary.isConfigured),
            if (repo.apiCatalog.isConfigured) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        final count = await repo.syncCatalogWithApi();
                        if (!ctx.mounted) return;
                        Navigator.of(ctx).pop();
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              'Synced $count destination(s) from Lakbay+ Admin.',
                            ),
                            backgroundColor: LakbayColors.tealDeep,
                          ),
                        );
                      },
                      icon: const Icon(Icons.sync_rounded, size: 18),
                      label: const Text('Sync Now'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () {
                        Navigator.of(ctx).pop();
                        if (repo.isSignedIn) {
                          repo.signOutBackend();
                        } else {
                          _showCloudAuthSheet(context);
                        }
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: LakbayColors.primary,
                        foregroundColor: Colors.white,
                      ),
                      icon: Icon(
                        repo.isSignedIn
                            ? Icons.logout_rounded
                            : Icons.login_rounded,
                        size: 18,
                      ),
                      label: Text(repo.isSignedIn ? 'Sign out' : 'Sign in'),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _showCloudAuthSheet(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<bool>(
        builder: (_) => AuthScreen(
          repo: repo,
          initialRegisterMode: true,
        ),
      ),
    );
  }
}

class _StatusTile extends StatelessWidget {
  final String label;
  final bool active;

  const _StatusTile(this.label, this.active);

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

class _ProfileField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final String? hint;

  const _ProfileField({
    required this.label,
    required this.controller,
    this.hint,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: LakbayColors.canvasBg,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 88,
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: LakbayColors.textSecondary,
              ),
            ),
          ),
          Expanded(
            child: TextField(
              controller: controller,
              decoration: InputDecoration(
                border: InputBorder.none,
                hintText: hint,
                isDense: true,
              ),
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                color: LakbayColors.tealDeep,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProfileTripTile extends StatelessWidget {
  final ItineraryTrip trip;
  final VoidCallback onTap;

  const _ProfileTripTile({required this.trip, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: LakbayColors.cardBorder),
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: LakbayNetworkOrAssetImage(
                networkUrl: trip.remoteImageUrl,
                assetPath: trip.heroAsset,
                width: 52,
                height: 52,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    trip.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                      color: LakbayColors.tealDeep,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${trip.daysCount} Days • ${trip.destination}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      color: LakbayColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: LakbayColors.successGreen.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Text(
                '✓ Upcoming',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: LakbayColors.successGreen,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingsRowCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? trailingText;
  final VoidCallback onTap;

  const _SettingsRowCard({
    required this.icon,
    required this.title,
    this.trailingText,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
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
              Icon(icon, color: LakbayColors.tealDeep, size: 22),
              const SizedBox(width: 14),
              Expanded(
                flex: 3,
                child: Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                    color: LakbayColors.tealDeep,
                  ),
                ),
              ),
              if (trailingText != null)
                Flexible(
                  flex: 2,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 8, right: 6),
                    child: Text(
                      trailingText!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.end,
                      style: const TextStyle(
                        fontSize: 13,
                        color: LakbayColors.textSecondary,
                      ),
                    ),
                  ),
                ),
              const Icon(
                Icons.chevron_right_rounded,
                color: LakbayColors.textSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
