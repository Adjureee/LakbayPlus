import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'design/design_preview_screen.dart';
import 'design/design.dart';
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

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _registerFontLicenses();
  await EnvConfig.load();
  runApp(const LakbayTravelApp());
}

/// Bundled fonts are SIL Open Font License; list them on the licenses page.
void _registerFontLicenses() {
  LicenseRegistry.addLicense(() async* {
    for (final (family, file) in const [
      ('Manrope', 'OFL-Manrope.txt'),
      ('Bricolage Grotesque', 'OFL-BricolageGrotesque.txt'),
    ]) {
      final text = await rootBundle.loadString('assets/google_fonts/$file');
      yield LicenseEntryWithLineBreaks([family], text);
    }
  });
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
          theme: LakbayDesignTheme.dark,
          darkTheme: LakbayDesignTheme.dark,
          themeMode: ThemeMode.dark,
          // Debug-only gallery of the v8 design system (open /#/design-preview).
          onGenerateRoute: (settings) =>
              kDebugMode && settings.name == '/design-preview'
                  ? MaterialPageRoute<void>(
                      settings: settings,
                      builder: (_) => const DesignPreviewScreen(),
                    )
                  : null,
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
      backgroundColor: LkColors.bg,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LakbayBrandWordmark(fontSize: 32, lightText: true, showTagline: true),
            SizedBox(height: 24),
            CircularProgressIndicator(color: LkColors.lagoon),
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

    return Scaffold(
      extendBody: true,
      body: IndexedStack(
        index: widget.repo.activeNavIndex,
        children: pages,
      ),
      bottomNavigationBar: LkFloatingNavBar(
        currentIndex: widget.repo.activeNavIndex,
        onSelected: widget.repo.setActiveNavIndex,
        items: const [
          LkNavItem(
            icon: Icons.luggage_outlined,
            selectedIcon: Icons.luggage_rounded,
            label: 'Trips',
          ),
          LkNavItem(
            icon: Icons.explore_outlined,
            selectedIcon: Icons.explore_rounded,
            label: 'Discover',
          ),
          LkNavItem(
            icon: Icons.forum_outlined,
            selectedIcon: Icons.forum_rounded,
            label: 'Chat',
          ),
          LkNavItem(
            icon: Icons.photo_library_outlined,
            selectedIcon: Icons.photo_library_rounded,
            label: 'Memories',
          ),
          LkNavItem(
            icon: Icons.person_outline_rounded,
            selectedIcon: Icons.person_rounded,
            label: 'Profile',
          ),
        ],
      ),
    );
  }
}
