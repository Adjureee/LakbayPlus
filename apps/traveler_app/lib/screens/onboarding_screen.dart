import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../services/travel_repository.dart';
import '../theme/lakbay_theme.dart';
import '../widgets/origin_picker_sheet.dart';
import 'yes_ai_onboarding_flow.dart';
import 'auth_screen.dart';

import '../design/lakbay_tokens.dart';
import '../design/lakbay_type.dart';
class OnboardingScreen extends StatefulWidget {
  final TravelRepository repo;

  const OnboardingScreen({super.key, required this.repo});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen>
    with SingleTickerProviderStateMixin {
  int _stepIndex = 0; // 0: Welcome, 1: Trip Decision, 2: Social Proof, 3: Brief, 4: Location
  bool _hasUpcomingTrip = true;
  bool _inYesAiFlow = false;
  bool _requestingLocation = false;
  String? _locationFeedback;
  late final AnimationController _pulseController;

  static const int _totalSteps = 5;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    )..repeat();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  void _nextStep() {
    if (_stepIndex == 1 && _hasUpcomingTrip) {
      setState(() => _inYesAiFlow = true);
      return;
    }
    if (_stepIndex < _totalSteps - 1) {
      setState(() => _stepIndex++);
    } else {
      _proceedToAuthOrComplete();
    }
  }

  void _prevStep() {
    if (_stepIndex > 0) {
      setState(() => _stepIndex--);
    }
  }

  void _finishOnboarding({required bool shareLocation}) {
    widget.repo.setLocationSharingEnabled(shareLocation);
    _proceedToAuthOrComplete();
  }

  void _proceedToAuthOrComplete() {
    if (widget.repo.isSignedIn) {
      widget.repo.completeOnboarding();
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<bool>(
        builder: (navCtx) => AuthScreen(
          repo: widget.repo,
          initialRegisterMode: true,
          onAuthenticated: () {
            widget.repo.completeOnboarding();
            Navigator.of(navCtx).popUntil((route) => route.isFirst);
          },
        ),
      ),
    );
  }

  Future<void> _handleShareLocationAndContinue() async {
    if (_requestingLocation) return;
    setState(() {
      _requestingLocation = true;
      _locationFeedback = null;
    });
    final result = await widget.repo.requestAndSaveCurrentLocation();
    if (!mounted) return;
    setState(() => _requestingLocation = false);
    if (result.granted) {
      _proceedToAuthOrComplete();
    } else {
      setState(() {
        _locationFeedback =
            '${result.statusMessage} Search for or pin your starting place below, or tap "Maybe later".';
      });
    }
  }

  void _showSignInSheet() {
    Navigator.of(context).push(
      MaterialPageRoute<bool>(
        builder: (navCtx) => AuthScreen(
          repo: widget.repo,
          initialRegisterMode: false,
          onAuthenticated: () {
            Navigator.of(navCtx).pop(true);
            widget.repo.completeOnboarding();
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_inYesAiFlow) {
      return YesAiOnboardingFlow(
        repo: widget.repo,
        onBackToDecision: () => setState(() => _inYesAiFlow = false),
      );
    }
    if (_stepIndex == 0) {
      return _buildWelcomeSplash(context);
    }

    return Scaffold(
      backgroundColor: LkColors.bg,
      body: SafeArea(
        child: Column(
          children: [
            // Header: Back arrow + progress bar + Skip
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 16, 8),
              child: Row(
                children: [
                  IconButton(
                    onPressed: _prevStep,
                    icon: const Icon(
                      Icons.chevron_left_rounded,
                      size: 28,
                      color: LkColors.text,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: LinearProgressIndicator(
                        value: _stepIndex / (_totalSteps - 1),
                        minHeight: 6,
                        backgroundColor:
                            LkColors.s2.withValues(alpha: 0.45),
                        valueColor: const AlwaysStoppedAnimation<Color>(
                          LkColors.lagoon,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  TextButton(
                    onPressed: () => _finishOnboarding(shareLocation: false),
                    child: const Text(
                      'Skip',
                      style: TextStyle(
                        color: LkColors.text,
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 260),
                child: switch (_stepIndex) {
                  1 => _buildTripDecisionStep(context),
                  2 => _buildSocialProofStep(context),
                  3 => _buildBriefMockupStep(context),
                  _ => _buildLocationShareStep(context),
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Step 0: Hero Welcome Splash (Image 4)
  Widget _buildWelcomeSplash(BuildContext context) {
    final backdrop = widget.repo.currentBackdrop;

    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          Image.asset(
            backdrop.localAssetPath,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => Container(
              decoration: const BoxDecoration(
                gradient: LkColors.surfaceGradient,
              ),
            ),
          ),
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Color(0x99071E26),
                  Color(0x33071E26),
                  Color(0xE6071E26),
                ],
                stops: [0.0, 0.42, 0.92],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 20, 22, 22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Center(
                    child: LakbayBrandWordmark(fontSize: 32, lightText: true),
                  ),
                  const Spacer(),
                  const Text(
                    'Tell it the vibe.\nGet the whole',
                    style: TextStyle(
                      fontFamily: LkType.displayFamily,
                      fontSize: 34,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                      height: 1.12,
                      letterSpacing: -0.7,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: LkColors.s2,
                          borderRadius: BorderRadius.circular(22),
                        ),
                        child: const Text(
                          'trip',
                          style: TextStyle(
                            fontFamily: LkType.displayFamily,
                            fontSize: 30,
                            fontWeight: FontWeight.w800,
                            color: LkColors.text,
                            height: 1.08,
                          ),
                        ),
                      ),
                      const Text(
                        '.',
                        style: TextStyle(
                          fontFamily: LkType.displayFamily,
                          fontSize: 34,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      const Icon(
                        Icons.place_outlined,
                        size: 15,
                        color: LkColors.text,
                      ),
                      const SizedBox(width: 6),
                      const Text(
                        'Real Region XI places',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 13.5,
                        ),
                      ),
                      const SizedBox(width: 18),
                      const Icon(
                        Icons.route_outlined,
                        size: 15,
                        color: LkColors.text,
                      ),
                      const SizedBox(width: 6),
                      const Text(
                        'Day-by-day plans',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 13.5,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 22),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _nextStep,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: LkColors.s2,
                        foregroundColor: LkColors.text,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(30),
                        ),
                      ),
                      child: const Text(
                        'Get started',
                        style: TextStyle(
                          fontFamily: LkType.displayFamily,
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Center(
                    child: TextButton(
                      onPressed: _showSignInSheet,
                      child: RichText(
                        text: TextSpan(
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.85),
                            fontSize: 13.5,
                          ),
                          children: const [
                            TextSpan(text: 'Already used Lakbay+? '),
                            TextSpan(
                              text: 'Sign in',
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w800,
                                decoration: TextDecoration.underline,
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
          ),
        ],
      ),
    );
  }

  // Step 1: "Do you have a trip coming up?" (Image 2)
  Widget _buildTripDecisionStep(BuildContext context) {
    return Padding(
      key: const ValueKey('step_1'),
      padding: const EdgeInsets.fromLTRB(22, 18, 22, 24),
      child: Column(
        children: [
          const Text(
            'Do you have a trip\ncoming up?',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: LkType.displayFamily,
              fontSize: 28,
              fontWeight: FontWeight.w800,
              color: LkColors.text,
              height: 1.15,
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            "Tell me where you're at and I'll skip the\nquestions you don't need.",
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14.5,
              color: LkColors.muted,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 28),
          _DecisionOptionCard(
            icon: Icons.beach_access_rounded,
            title: 'Yes',
            subtitle: "I'm ready to plan",
            selected: _hasUpcomingTrip,
            onTap: () {
              setState(() => _hasUpcomingTrip = true);
            },
          ),
          const SizedBox(height: 14),
          _DecisionOptionCard(
            icon: Icons.explore_outlined,
            title: 'No',
            subtitle: 'Just looking for now',
            selected: !_hasUpcomingTrip,
            onTap: () {
              setState(() => _hasUpcomingTrip = false);
            },
          ),
          const Spacer(),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _nextStep,
              style: ElevatedButton.styleFrom(
                backgroundColor: LkColors.s2,
                foregroundColor: LkColors.text,
                elevation: 0,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(30),
                ),
              ),
              child: const Text(
                'Continue',
                style: TextStyle(
                  fontFamily: LkType.displayFamily,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Step 2: what Lakbay+ actually does (no invented stats or testimonials).
  Widget _buildSocialProofStep(BuildContext context) {
    return Stack(
      key: const ValueKey('step_2'),
      children: [
        ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 100),
          children: [
            const Text(
              'Plans built from real places.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: LkType.displayFamily,
                fontSize: 27,
                fontWeight: FontWeight.w800,
                color: LkColors.text,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Lakbay AI plans from a catalog of Davao Region places that our team keeps up to date.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14.5,
                height: 1.45,
                color: LkColors.muted,
              ),
            ),
            const SizedBox(height: 24),
            const _ProductPoint(
              icon: Icons.place_outlined,
              title: 'Real Region XI destinations',
              body:
                  'Beaches, falls, parks and islands with their real locations, from Samal to Mati.',
            ),
            const SizedBox(height: 12),
            const _ProductPoint(
              icon: Icons.directions_boat_outlined,
              title: 'Ferries, rides and fares',
              body:
                  'Each day shows how to get from stop to stop and roughly what it costs. Fares are estimates.',
            ),
            const SizedBox(height: 12),
            const _ProductPoint(
              icon: Icons.groups_outlined,
              title: 'Plan with your barkada',
              body: 'Invite friends to a trip, share tasks and split the budget.',
            ),
          ],
        ),
        Positioned(
          left: 20,
          right: 20,
          bottom: 20,
          child: ElevatedButton(
            onPressed: _nextStep,
            style: ElevatedButton.styleFrom(
              backgroundColor: LkColors.s2,
              foregroundColor: LkColors.text,
              elevation: 2,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(30),
              ),
            ),
            child: const Text(
              'Continue',
              style: TextStyle(
                fontFamily: LkType.displayFamily,
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ),
      ],
    );
  }

  // Step 3: "Good. Tell me the brief." Phone Mockup (Image 1)
  Widget _buildBriefMockupStep(BuildContext context) {
    return Padding(
      key: const ValueKey('step_3'),
      padding: const EdgeInsets.fromLTRB(22, 12, 22, 22),
      child: Column(
        children: [
          const Text(
            'Good. Tell me the brief.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: LkType.displayFamily,
              fontSize: 27,
              fontWeight: FontWeight.w800,
              color: LkColors.text,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            "Say it like you'd say it to a friend: who, where, when, what matters. I draft the first plan for you to review.",
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13.5,
              color: LkColors.muted,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 18),
          Expanded(
            child: Container(
              constraints: const BoxConstraints(maxWidth: 310),
              decoration: BoxDecoration(
                color: LkColors.s1,
                borderRadius: BorderRadius.circular(34),
                border: Border.all(color: LkColors.strokeStrong, width: 5),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.12),
                    blurRadius: 18,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Dynamic Island / Status Bar Mock
                  Center(
                    child: Container(
                      width: 74,
                      height: 18,
                      decoration: BoxDecoration(
                        color: LkColors.s3,
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Row(
                    children: [
                      Icon(
                        Icons.home_outlined,
                        size: 18,
                        color: LkColors.text,
                      ),
                      Expanded(
                        child: Text(
                          'Chat',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                            color: LkColors.text,
                          ),
                        ),
                      ),
                      SizedBox(width: 18),
                    ],
                  ),
                  const Divider(height: 16),
                  const Spacer(),
                  const Text(
                    "Hey there, Lakbay+ here! Excited to help you create your next Davao Region trip. Just tell me what you're thinking and let's do this together.",
                    style: TextStyle(
                      fontSize: 12,
                      color: LkColors.text,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Container(
                      padding: const EdgeInsets.all(11),
                      decoration: BoxDecoration(
                        color: LkColors.bg,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: const Text(
                        'Plan a family trip to Samal Island and Mati Dahican for 4 people starting next weekend for 4 days, assume and ask no more questions.',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: LkColors.text,
                          height: 1.35,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Text(
                        'Generating your trip... 78%',
                        style: TextStyle(
                          fontSize: 11,
                          color: LkColors.muted,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        Icons.hourglass_top_rounded,
                        size: 12,
                        color: LkColors.lagoon.withValues(alpha: 0.7),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _nextStep,
              style: ElevatedButton.styleFrom(
                backgroundColor: LkColors.s2,
                foregroundColor: LkColors.text,
                elevation: 0,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(30),
                ),
              ),
              child: const Text(
                "Let's go",
                style: TextStyle(
                  fontFamily: LkType.displayFamily,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Step 4: "First, share your location" (Image 5)
  Widget _buildLocationShareStep(BuildContext context) {
    return Padding(
      key: const ValueKey('step_4'),
      padding: const EdgeInsets.fromLTRB(22, 12, 22, 18),
      child: Column(
        children: [
          const Text(
            'First, share your location',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: LkType.displayFamily,
              fontSize: 27,
              fontWeight: FontWeight.w800,
              color: LkColors.text,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Share your current GPS location—or search or pin where you are starting from—for tailored Region XI routes.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              color: LkColors.muted,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 18),
          Expanded(
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: const Color(0xFFE9F2EE),
                borderRadius: BorderRadius.circular(26),
                border: Border.all(color: LkColors.stroke),
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  CustomPaint(
                    painter: _DavaoRadarMapPainter(),
                  ),
                  // Locating pill at top-left
                  Positioned(
                    top: 14,
                    left: 14,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.94),
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.08),
                            blurRadius: 8,
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircleAvatar(
                            radius: 4,
                            backgroundColor: widget.repo.hasOrigin
                                ? LkColors.s3
                                : LkColors.s3,
                          ),
                          const SizedBox(width: 6),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 210),
                            child: Text(
                              _requestingLocation
                                  ? 'Requesting permission…'
                                  : (widget.repo.hasOrigin
                                      ? widget.repo.effectiveOriginLabel
                                      : 'Starting place not set'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w700,
                                color: LkColors.text,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  // Pulsing Radar Rings + Center Pin
                  AnimatedBuilder(
                    animation: _pulseController,
                    builder: (context, _) {
                      final t = _pulseController.value;
                      return Stack(
                        alignment: Alignment.center,
                        children: [
                          for (final phase in [0.0, 0.33, 0.66])
                            _buildRadarRing((t + phase) % 1.0),
                          Container(
                            width: 46,
                            height: 46,
                            decoration: BoxDecoration(
                              color: LkColors.s3,
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 3),
                              boxShadow: [
                                BoxShadow(
                                  color: LkColors.lagoon
                                      .withValues(alpha: 0.35),
                                  blurRadius: 12,
                                ),
                              ],
                            ),
                            child: const Icon(
                              Icons.location_on_outlined,
                              color: Colors.white,
                              size: 24,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
          if (_locationFeedback != null) ...[
            const SizedBox(height: 12),
            Text(
              _locationFeedback!,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 12.5,
                color: LkColors.muted,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed:
                  _requestingLocation ? null : _handleShareLocationAndContinue,
              style: ElevatedButton.styleFrom(
                backgroundColor: LkColors.s2,
                foregroundColor: LkColors.text,
                elevation: 0,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(30),
                ),
              ),
              child: _requestingLocation
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.4,
                        color: LkColors.text,
                      ),
                    )
                  : Text(
                      _locationFeedback != null
                          ? 'Try location again'
                          : 'Share location & continue',
                      style: const TextStyle(
                        fontFamily: LkType.displayFamily,
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () async {
              final picked = await showOriginPickerSheet(context, widget.repo);
              if (picked == true && mounted) {
                _proceedToAuthOrComplete();
              }
            },
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(44),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
            ),
            icon: const Icon(Icons.search_rounded, size: 18),
            label: const Text(
              'Search or pin a starting place',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(height: 4),
          TextButton(
            onPressed: () => _finishOnboarding(shareLocation: false),
            child: const Text(
              'Maybe later',
              style: TextStyle(
                color: LkColors.muted,
                fontWeight: FontWeight.w600,
                fontSize: 14,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRadarRing(double progress) {
    final size = 56 + (progress * 190);
    final opacity = (1.0 - progress).clamp(0.0, 1.0) * 0.28;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: LkColors.s3.withValues(alpha: opacity),
      ),
    );
  }
}

class _DecisionOptionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  const _DecisionOptionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: selected ? LkColors.s2 : LkColors.s1,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            color: selected
                ? LkColors.lagoon
                : LkColors.stroke,
            width: selected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: LkColors.s2.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(icon, color: LkColors.lagoon, size: 24),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontFamily: LkType.displayFamily,
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      color: LkColors.text,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontSize: 13.5,
                      color: LkColors.muted,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              selected
                  ? Icons.check_circle_rounded
                  : Icons.radio_button_unchecked_rounded,
              color: selected
                  ? LkColors.lagoon
                  : LkColors.faint,
              size: 26,
            ),
          ],
        ),
      ),
    );
  }
}

class _ProductPoint extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;

  const _ProductPoint({
    required this.icon,
    required this.title,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: LkColors.s1,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: LkColors.stroke),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: LkColors.s2,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: LkColors.lagoon, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                    color: LkColors.text,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  body,
                  style: const TextStyle(
                    fontSize: 13.5,
                    height: 1.4,
                    color: LkColors.muted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DavaoRadarMapPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    // Soft Davao Gulf coastline + road grid
    final gulfPaint = Paint()..color = const Color(0xFFD5EAF2);
    final roadPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.75)
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;
    final minorRoadPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.45)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    // Gulf water on right/bottom
    final gulfPath = Path()
      ..moveTo(size.width * 0.58, 0)
      ..quadraticBezierTo(
        size.width * 0.48,
        size.height * 0.45,
        size.width * 0.72,
        size.height,
      )
      ..lineTo(size.width, size.height)
      ..lineTo(size.width, 0)
      ..close();
    canvas.drawPath(gulfPath, gulfPaint);

    // Subtle map street grid
    for (var i = 1; i < 9; i++) {
      final y = size.height * (i / 9);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), minorRoadPaint);
      final x = size.width * (i / 9);
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), minorRoadPaint);
    }

    // Coastal Davao highway curve
    final highway = Path()
      ..moveTo(size.width * 0.1, size.height * 0.85)
      ..quadraticBezierTo(
        size.width * 0.45,
        size.height * 0.52,
        size.width * 0.55,
        size.height * 0.08,
      );
    canvas.drawPath(highway, roadPaint);

    // Destination region landmarks
    final labels = [
      ('REGION XI', Offset(size.width * 0.18, size.height * 0.42)),
      ('PACIFIC COAST', Offset(size.width * 0.72, size.height * 0.24)),
      ('SAMAL', Offset(size.width * 0.76, size.height * 0.36)),
      ('DAVAO GULF', Offset(size.width * 0.70, size.height * 0.78)),
    ];

    for (final (text, pos) in labels) {
      final tp = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
            color: LkColors.text.withValues(alpha: 0.45),
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, pos - Offset(tp.width / 2, math.max(0, tp.height / 2)));
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
