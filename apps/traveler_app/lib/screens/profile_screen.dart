import '../core/day_labels.dart';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../models/travel_models.dart';
import '../services/travel_repository.dart';
import '../theme/lakbay_theme.dart';
import '../widgets/lakbay_image.dart';
import '../widgets/user_avatar.dart';
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
    final coverAsset = trips.isNotEmpty && trips.first.heroAsset.isNotEmpty
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
                        child: profile.coverUrl.isEmpty
                            ? Image.asset(
                          coverAsset,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => Container(
                            decoration: const BoxDecoration(
                              gradient: LakbayColors.deepTealGradient,
                            ),
                          ),
                        )
                            : Image.network(
                                profile.coverUrl,
                                key: const ValueKey('profile-cover-image'),
                                fit: BoxFit.cover,
                                // A cover that cannot load shows the default.
                                errorBuilder: (_, _, _) => Image.asset(
                          coverAsset,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => Container(
                            decoration: const BoxDecoration(
                              gradient: LakbayColors.deepTealGradient,
                            ),
                          ),
                        ),
                              ),
                      ),
                      Positioned(
                        top: 8,
                        right: 12,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Material(
                              color: Colors.white.withValues(alpha: 0.94),
                              shape: const CircleBorder(),
                              child: IconButton(
                                key: const ValueKey('change-cover-photo'),
                                tooltip: 'Change cover photo',
                                constraints: const BoxConstraints(
                                  minWidth: 48,
                                  minHeight: 48,
                                ),
                                onPressed: () => _showCoverSheet(context),
                                icon: const Icon(
                                  Icons.photo_camera_outlined,
                                  size: 20,
                                  color: LakbayColors.tealDeep,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Material(
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
                          ],
                        ),
                      ),
                      Positioned(
                        left: 18,
                        bottom: -26,
                        child: UserAvatar(
                          imageUrl: profile.avatarUrl,
                          initials: profile.initials,
                          size: 66,
                          ringWidth: 3,
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
                        InkWell(
                          onTap: () => _showEditProfileSheet(context),
                          borderRadius: BorderRadius.circular(8),
                          child: Text(
                            profile.fullName.isEmpty
                                ? 'Add your name'
                                : profile.fullName,
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                              color: profile.fullName.isEmpty
                                  ? LakbayColors.primaryDark
                                  : LakbayColors.tealDeep,
                            ),
                          ),
                        ),
                        if (profile.username.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            '@${profile.username}',
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: LakbayColors.primaryDark,
                            ),
                          ),
                        ],
                        const SizedBox(height: 4),
                        Text(
                          profile.headline.isNotEmpty
                              ? profile.headline
                              : '${profile.location.trim().isNotEmpty ? profile.location.trim() : "Location not set"} • ${repo.travelCompanion} Traveler',
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
                Flexible(
                  child: Text(
                    'Your trips • ${trips.length}',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: LakbayColors.tealDeep,
                    ),
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

            // Signed-in travelers log out from Settings. Guests keep one way in.
            if (!repo.isSignedIn) ...[
              const SizedBox(height: 18),
              _SettingsRowCard(
                icon: Icons.person_add_alt_1_outlined,
                title: 'Create account / Sign in',
                trailingText: 'Sync & save',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<bool>(
                    builder: (_) =>
                        AuthScreen(repo: repo, initialRegisterMode: true),
                  ),
                ),
              ),
            ],

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
                      'Lakbay+ travel support for the Davao Region is active.',
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 10),
            _SettingsRowCard(
              icon: Icons.settings_outlined,
              title: 'Settings',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => SettingsScreen(repo: repo)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showCoverSheet(BuildContext context) {
    final messenger = ScaffoldMessenger.of(context);
    if (!repo.isSignedIn) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Sign in to add a cover photo.')),
      );
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 12, 8, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                key: const ValueKey('cover-choose'),
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('Choose a cover photo'),
                onTap: () async {
                  Navigator.of(sheetContext).pop();
                  final picked = await ImagePicker().pickImage(
                    source: ImageSource.gallery,
                    maxWidth: 1600,
                    maxHeight: 1600,
                    imageQuality: 85,
                  );
                  if (picked == null) return;
                  messenger
                    ..clearSnackBars()
                    ..showSnackBar(
                      const SnackBar(content: Text('Uploading cover photo…')),
                    );
                  final problem = await repo.uploadCoverPhoto(
                    bytes: await picked.readAsBytes(),
                    filename: picked.name,
                  );
                  messenger
                    ..clearSnackBars()
                    ..showSnackBar(
                      SnackBar(
                        content: Text(problem ?? 'Cover photo updated.'),
                      ),
                    );
                },
              ),
              if (repo.profile.coverUrl.isNotEmpty)
                ListTile(
                  key: const ValueKey('cover-remove'),
                  leading: const Icon(Icons.delete_outline_rounded),
                  title: const Text('Remove cover photo'),
                  onTap: () async {
                    Navigator.of(sheetContext).pop();
                    final problem = await repo.removeCoverPhoto();
                    if (problem != null) {
                      messenger.showSnackBar(SnackBar(content: Text(problem)));
                    }
                  },
                ),
            ],
          ),
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
    final usernameCtrl = TextEditingController(text: p.username);
    // Make sure the field shows the server's current username.
    repo.refreshUsername().then((_) {
      if (usernameCtrl.text.isEmpty && repo.profile.username.isNotEmpty) {
        usernameCtrl.text = repo.profile.username;
      }
    });

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
        String? usernameError;
        var isSaving = false;
        var isUploadingPhoto = false;
        String? photoError;
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
                        UserAvatar(
                          imageUrl: repo.profile.avatarUrl,
                          initials: p.initials,
                          size: 84,
                        ),
                        Positioned(
                          right: 0,
                          bottom: 0,
                          child: InkWell(
                            key: const ValueKey('change-profile-photo'),
                            customBorder: const CircleBorder(),
                            onTap: isUploadingPhoto
                                ? null
                                : () async {
                                    if (!repo.isSignedIn) {
                                      setSheetState(
                                        () => photoError =
                                            'Sign in to add a profile photo.',
                                      );
                                      return;
                                    }
                                    final picked = await ImagePicker()
                                        .pickImage(
                                          source: ImageSource.gallery,
                                          maxWidth: 1280,
                                          maxHeight: 1280,
                                          imageQuality: 85,
                                        );
                                    if (picked == null || !ctx.mounted) return;
                                    setSheetState(() {
                                      isUploadingPhoto = true;
                                      photoError = null;
                                    });
                                    final problem = await repo
                                        .uploadProfilePhoto(
                                          bytes: await picked.readAsBytes(),
                                          filename: picked.name,
                                        );
                                    if (!ctx.mounted) return;
                                    setSheetState(() {
                                      isUploadingPhoto = false;
                                      photoError = problem;
                                    });
                                  },
                            child: Container(
                              padding: const EdgeInsets.all(6),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: LakbayColors.primaryLight,
                                ),
                              ),
                              child: isUploadingPhoto
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(
                                      Icons.camera_alt_outlined,
                                      size: 16,
                                      color: LakbayColors.tealDeep,
                                    ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (photoError != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Center(
                        child: Text(
                          photoError!,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.red.shade700,
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(height: 20),
                  _ProfileField(label: 'First name', controller: firstCtrl),
                  const SizedBox(height: 10),
                  _ProfileField(label: 'Last name', controller: lastCtrl),
                  if (repo.isSignedIn) ...[
                    const SizedBox(height: 10),
                    _ProfileField(
                      label: 'Username',
                      controller: usernameCtrl,
                      hint: 'e.g. maria_santos',
                      prefix: '@',
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(6, 4, 6, 0),
                      child: Text(
                        usernameError ?? 'Friends use this to find and invite you. 3 to 30 letters, numbers, dots or underscores.',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: usernameError != null
                              ? Colors.red.shade700
                              : LakbayColors.textSecondary,
                        ),
                      ),
                    ),
                  ],
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
                              final result = await repo
                                  .requestAndSaveCurrentLocation();
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
                      onPressed: isSaving
                          ? null
                          : () async {
                              // The username lives on the server, so it is saved
                              // first; a refusal keeps the sheet open with the reason.
                              setSheetState(() {
                                isSaving = true;
                                usernameError = null;
                              });
                              final problem = repo.isSignedIn
                                  ? await repo.saveUsername(usernameCtrl.text)
                                  : null;
                              if (!ctx.mounted) return;
                              if (problem != null) {
                                setSheetState(() {
                                  isSaving = false;
                                  usernameError = problem;
                                });
                                return;
                              }
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
}

class _ProfileField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final String? hint;
  final String? prefix;

  const _ProfileField({
    required this.label,
    required this.controller,
    this.hint,
    this.prefix,
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
                prefixText: prefix,
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
 category: trip.vibeTag,
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
                    '${DayLabels.countTitle(trip.daysCount)} • ${trip.destination}',
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
                color: (trip.isArchived
                        ? LakbayColors.textSecondary
                        : LakbayColors.successGreen)
                    .withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Text(
                trip.isCompleted
                    ? '✓ Completed'
                    : trip.isArchived
                        ? 'Archived'
                        : trip.backendStatus == 'ongoing'
                            ? 'Ongoing'
                            : '✓ Upcoming',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: trip.isArchived
                      ? LakbayColors.textSecondary
                      : LakbayColors.successGreen,
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
