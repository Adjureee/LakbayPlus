import 'package:flutter/material.dart';
import 'screens/auth_screen.dart';
import 'screens/explore_screen.dart';
import 'screens/home_chat_screen.dart';
import 'screens/memories_screen.dart';
import 'screens/my_trips_screen.dart';
import 'screens/onboarding_screen.dart';
import 'screens/profile_screen.dart';
import 'services/env_config.dart';
import 'services/travel_repository.dart';
import 'theme/lakbay_theme.dart';
import 'widgets/brand/lakbay_compass_mark.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await EnvConfig.load();
  runApp(const LakbayTravelApp());
}

class LakbayTravelApp extends StatefulWidget {
  final TravelRepository? repository;

  const LakbayTravelApp({super.key, this.repository});

  @override
  State<LakbayTravelApp> createState() => _LakbayTravelAppState();
}

class _LakbayTravelAppState extends State<LakbayTravelApp>
    with WidgetsBindingObserver {
  late TravelRepository _repo = widget.repository ?? TravelRepository();
  late bool _ownsRepo = widget.repository == null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (!_repo.isInitialized) {
      _repo.initialize();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Pick up admin edits made while the app sat in the background.
    if (state == AppLifecycleState.resumed && _repo.isInitialized) {
      _repo.refreshCatalogIfStale();
      // An invitation may have arrived while the app was in the background.
      _repo.refreshNotifications();
    }
  }

  @override
  void didUpdateWidget(covariant LakbayTravelApp oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.repository != oldWidget.repository) {
      if (_ownsRepo) {
        _repo.dispose();
      }
      _repo = widget.repository ?? TravelRepository();
      _ownsRepo = widget.repository == null;
      if (!_repo.isInitialized) {
        _repo.initialize();
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_ownsRepo) {
      _repo.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _repo,
      builder: (context, _) {
        return MaterialApp(
          title: 'Lakbay+ — AI Travel Planner',
          debugShowCheckedModeBanner: false,
          theme: LakbayTheme.lightTheme,
          home: !_repo.isInitialized
              ? const _SplashLoadingScreen()
              : (!_repo.hasCompletedOnboarding
                  ? OnboardingScreen(repo: _repo)
                  : (!_repo.isSignedIn
                      ? AuthScreen(repo: _repo, initialRegisterMode: false)
                      : MainNavigationShell(repo: _repo))),
        );
      },
    );
  }
}

class _SplashLoadingScreen extends StatelessWidget {
  const _SplashLoadingScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: LakbayColors.tealDeep,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LakbayBrandWordmark(fontSize: 32, lightText: true, showTagline: true),
            SizedBox(height: 24),
            CircularProgressIndicator(color: LakbayColors.primary),
          ],
        ),
      ),
    );
  }
}

class MainNavigationShell extends StatefulWidget {
  final TravelRepository repo;

  const MainNavigationShell({super.key, required this.repo});

  @override
  State<MainNavigationShell> createState() => _MainNavigationShellState();
}

class _MainNavigationShellState extends State<MainNavigationShell> {
  @override
  void initState() {
    super.initState();
    widget.repo.startNotificationPolling();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.repo.autoDetectLocationOnShellEntry();
    });
  }

  @override
  void dispose() {
    widget.repo.stopNotificationPolling();
    super.dispose();
  }
  @override
  Widget build(BuildContext context) {
    final pages = [
      MyTripsScreen(repo: widget.repo),
      ExploreScreen(repo: widget.repo),
      HomeChatScreen(repo: widget.repo),
      MemoriesScreen(repo: widget.repo),
      ProfileScreen(repo: widget.repo),
    ];

    final selectedIndex = widget.repo.activeNavIndex;
    final memoriesCount = widget.repo.memories.length;
    final initials = widget.repo.profile.initials;

    return Scaffold(
      extendBody: true,
      body: IndexedStack(
        index: selectedIndex,
        children: pages,
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(14, 0, 14, 10),
        child: SizedBox(
          height: 76,
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.bottomCenter,
            children: [
              Container(
                height: 64,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.96),
                  borderRadius: BorderRadius.circular(32),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.12),
                      blurRadius: 18,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _NavItem(
                      icon: Icons.map_outlined,
                      label: 'Trips',
                      selected: selectedIndex == 0,
                      onTap: () => widget.repo.setActiveNavIndex(0),
                    ),
                    _NavItem(
                      icon: Icons.ondemand_video_outlined,
                      label: 'Discover',
                      selected: selectedIndex == 1,
                      onTap: () => widget.repo.setActiveNavIndex(1),
                    ),
                    // Spacer for center elevated S✦ Chat button
                    const SizedBox(width: 62),
                    _NavItem(
                      icon: Icons.photo_library_outlined,
                      label: 'Memories',
                      badgeCount: memoriesCount,
                      selected: selectedIndex == 3,
                      onTap: () => widget.repo.setActiveNavIndex(3),
                    ),
                    _ProfileNavItem(
                      initials: initials,
                      selected: selectedIndex == 4,
                      onTap: () => widget.repo.setActiveNavIndex(4),
                    ),
                  ],
                ),
              ),
              Positioned(
                top: 0,
                child: GestureDetector(
                  onTap: () => widget.repo.setActiveNavIndex(2),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 54,
                        height: 54,
                        decoration: BoxDecoration(
                          color: selectedIndex == 2
                              ? LakbayColors.tealDeep
                              : LakbayColors.primary,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 3),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.2),
                              blurRadius: 12,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        alignment: Alignment.center,
                        child: const LakbayCompassMark(
                          size: 28,
                          primaryColor: Colors.white,
                          secondaryColor: Colors.white70,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Chat',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: selectedIndex == 2
                              ? FontWeight.w800
                              : FontWeight.w600,
                          color: selectedIndex == 2
                              ? LakbayColors.tealDeep
                              : LakbayColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final int badgeCount;
  final VoidCallback onTap;

  const _NavItem({
    required this.icon,
    required this.label,
    required this.selected,
    this.badgeCount = 0,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? LakbayColors.primaryLight : Colors.transparent,
          borderRadius: BorderRadius.circular(22),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Badge(
              isLabelVisible: badgeCount > 0,
              label: Text('$badgeCount'),
              backgroundColor: LakbayColors.primary,
              child: Icon(
                icon,
                size: 21,
                color: selected
                    ? LakbayColors.primaryDark
                    : LakbayColors.tealDeep,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                color: selected
                    ? LakbayColors.primaryDark
                    : LakbayColors.tealDeep,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProfileNavItem extends StatelessWidget {
  final String initials;
  final bool selected;
  final VoidCallback onTap;

  const _ProfileNavItem({
    required this.initials,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? LakbayColors.primaryLight : Colors.transparent,
          borderRadius: BorderRadius.circular(22),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 11,
              backgroundColor: selected
                  ? LakbayColors.primary
                  : LakbayColors.canvasBg,
              child: Text(
                initials.length > 3 ? initials.substring(0, 3) : initials,
                style: TextStyle(
                  fontSize: 8.5,
                  fontWeight: FontWeight.w800,
                  color: selected ? Colors.white : LakbayColors.tealDeep,
                ),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              'Profile',
              style: TextStyle(
                fontSize: 11,
                fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                color: selected
                    ? LakbayColors.primaryDark
                    : LakbayColors.tealDeep,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
