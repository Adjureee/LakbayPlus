import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../services/travel_repository.dart';
import '../theme/lakbay_theme.dart';
import 'yes_ai_onboarding_flow.dart';
import 'auth_screen.dart';

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
      widget.repo.completeOnboarding();
    }
  }

  void _prevStep() {
    if (_stepIndex > 0) {
      setState(() => _stepIndex--);
    }
  }

  void _finishOnboarding({required bool shareLocation}) {
    widget.repo.setLocationSharingEnabled(shareLocation);
    widget.repo.completeOnboarding();
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
      widget.repo.completeOnboarding();
    } else {
      setState(() {
        _locationFeedback =
            '${result.statusMessage} You can retry or tap "Maybe later".';
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
      backgroundColor: LakbayColors.canvasBg,
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
                      color: LakbayColors.tealDeep,
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
                            LakbayColors.primaryLight.withValues(alpha: 0.45),
                        valueColor: const AlwaysStoppedAnimation<Color>(
                          LakbayColors.primary,
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
                        color: LakbayColors.tealDeep,
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
                gradient: LakbayColors.deepTealGradient,
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
                    'AI plans it.\nYour travel expert\nmakes it',
                    style: TextStyle(
                      fontFamily: 'FigGrotesk',
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
                          color: LakbayColors.primaryLight,
                          borderRadius: BorderRadius.circular(22),
                        ),
                        child: const Text(
                          'unforgettable',
                          style: TextStyle(
                            fontFamily: 'FigGrotesk',
                            fontSize: 30,
                            fontWeight: FontWeight.w800,
                            color: LakbayColors.tealDeep,
                            height: 1.08,
                          ),
                        ),
                      ),
                      const Text(
                        '.',
                        style: TextStyle(
                          fontFamily: 'FigGrotesk',
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
                        Icons.auto_awesome,
                        size: 15,
                        color: LakbayColors.primaryLight,
                      ),
                      const SizedBox(width: 6),
                      const Text(
                        'No fees',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 13.5,
                        ),
                      ),
                      const SizedBox(width: 18),
                      const Icon(
                        Icons.auto_awesome,
                        size: 15,
                        color: LakbayColors.primaryLight,
                      ),
                      const SizedBox(width: 6),
                      const Text(
                        '24/7 Davao care',
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
                        backgroundColor: LakbayColors.primaryLight,
                        foregroundColor: LakbayColors.tealDeep,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(30),
                        ),
                      ),
                      child: const Text(
                        'Get started',
                        style: TextStyle(
                          fontFamily: 'FigGrotesk',
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
                            TextSpan(text: 'Already used Lakbay+✦? '),
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
              fontFamily: 'FigGrotesk',
              fontSize: 28,
              fontWeight: FontWeight.w800,
              color: LakbayColors.tealDeep,
              height: 1.15,
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            "Tell me where you're at and I'll skip the\nquestions you don't need.",
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14.5,
              color: LakbayColors.textSecondary,
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
                backgroundColor: LakbayColors.primaryLight,
                foregroundColor: LakbayColors.tealDeep,
                elevation: 0,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(30),
                ),
              ),
              child: const Text(
                'Continue',
                style: TextStyle(
                  fontFamily: 'FigGrotesk',
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

  // Step 2: "You're in good company." (Image 3)
  Widget _buildSocialProofStep(BuildContext context) {
    return Stack(
      key: const ValueKey('step_2'),
      children: [
        ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 100),
          children: [
            const Text(
              "You're in good company.",
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'FigGrotesk',
                fontSize: 27,
                fontWeight: FontWeight.w800,
                color: LakbayColors.tealDeep,
              ),
            ),
            const SizedBox(height: 22),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                Text(
                  '1M+',
                  style: TextStyle(
                    fontFamily: 'FigGrotesk',
                    fontSize: 42,
                    fontWeight: FontWeight.w800,
                    color: LakbayColors.tealDeep,
                  ),
                ),
                SizedBox(width: 4),
                Icon(
                  Icons.auto_awesome,
                  size: 20,
                  color: LakbayColors.primary,
                ),
              ],
            ),
            const Text(
              'Trips planned',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: LakbayColors.tealDeep,
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(
                5,
                (_) => const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 3),
                  child: Icon(
                    Icons.star_rounded,
                    color: LakbayColors.primary,
                    size: 26,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              '50k+ 5 star reviews',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14.5,
                fontWeight: FontWeight.w700,
                color: LakbayColors.tealDeep,
              ),
            ),
            const SizedBox(height: 24),
            const _TestimonialCard(
              quote:
                  '"Lakbay+ doesn\'t feel like a generic chatbot. It feels like chatting with a super organized friend who already knows Samal\'s hidden coves, Mati\'s surf breaks, and the ferry timings you\'d forget to check."',
              author: 'Carla',
              avatarAsset: 'assets/experts/carla.webp',
            ),
            const SizedBox(height: 14),
            const _TestimonialCard(
              quote:
                  '"I check every detail with you: does this resort really fit your pace? Does this Davao coastal transfer work? That way when you arrive, everything flows smoothly."',
              author: 'Aleks, travel expert',
              avatarAsset: 'assets/experts/aleks.webp',
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
              backgroundColor: LakbayColors.primaryLight,
              foregroundColor: LakbayColors.tealDeep,
              elevation: 2,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(30),
              ),
            ),
            child: const Text(
              'Continue',
              style: TextStyle(
                fontFamily: 'FigGrotesk',
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
              fontFamily: 'FigGrotesk',
              fontSize: 27,
              fontWeight: FontWeight.w800,
              color: LakbayColors.tealDeep,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            "Say it like you'd say it to a friend: who, where, when, what matters. I draft the first plan. Your travel expert checks it and books.",
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13.5,
              color: LakbayColors.textSecondary,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 18),
          Expanded(
            child: Container(
              constraints: const BoxConstraints(maxWidth: 310),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(34),
                border: Border.all(color: LakbayColors.tealDeep, width: 5),
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
                        color: LakbayColors.tealDeep,
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
                        color: LakbayColors.tealDeep,
                      ),
                      Expanded(
                        child: Text(
                          'Chat',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                            color: LakbayColors.tealDeep,
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
                      color: LakbayColors.tealDeep,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Container(
                      padding: const EdgeInsets.all(11),
                      decoration: BoxDecoration(
                        color: LakbayColors.canvasBg,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: const Text(
                        'Plan a family trip to Samal Island and Mati Dahican for 4 people starting next weekend for 4 days, assume and ask no more questions.',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: LakbayColors.textPrimary,
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
                          color: LakbayColors.textMuted,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        Icons.auto_awesome,
                        size: 12,
                        color: LakbayColors.primary.withValues(alpha: 0.7),
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
                backgroundColor: LakbayColors.primaryLight,
                foregroundColor: LakbayColors.tealDeep,
                elevation: 0,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(30),
                ),
              ),
              child: const Text(
                "Let's go",
                style: TextStyle(
                  fontFamily: 'FigGrotesk',
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
              fontFamily: 'FigGrotesk',
              fontSize: 27,
              fontWeight: FontWeight.w800,
              color: LakbayColors.tealDeep,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'I can find flights into Davao (DVO) and build the best deals and routes for your Region XI trip.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              color: LakbayColors.textSecondary,
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
                border: Border.all(color: LakbayColors.cardBorder),
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
                            backgroundColor: widget.repo.hasUserLocation
                                ? LakbayColors.tealDeep
                                : LakbayColors.primary,
                          ),
                          const SizedBox(width: 6),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 210),
                            child: Text(
                              _requestingLocation
                                  ? 'Requesting permission…'
                                  : (widget.repo.hasUserLocation
                                      ? widget.repo.profile.location
                                      : 'Locating'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w700,
                                color: LakbayColors.tealDeep,
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
                              color: LakbayColors.primary,
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 3),
                              boxShadow: [
                                BoxShadow(
                                  color: LakbayColors.primary
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
                color: LakbayColors.textSecondary,
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
                backgroundColor: LakbayColors.primaryLight,
                foregroundColor: LakbayColors.tealDeep,
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
                        color: LakbayColors.tealDeep,
                      ),
                    )
                  : Text(
                      _locationFeedback != null
                          ? 'Try location again'
                          : 'Share location & continue',
                      style: const TextStyle(
                        fontFamily: 'FigGrotesk',
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 6),
          TextButton(
            onPressed: () => _finishOnboarding(shareLocation: false),
            child: const Text(
              'Maybe later',
              style: TextStyle(
                color: LakbayColors.textSecondary,
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
        color: LakbayColors.primary.withValues(alpha: opacity),
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
          color: selected ? LakbayColors.primarySoft : Colors.white,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            color: selected
                ? LakbayColors.primary
                : LakbayColors.cardBorder,
            width: selected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: LakbayColors.primaryLight.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(icon, color: LakbayColors.primaryDark, size: 24),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontFamily: 'FigGrotesk',
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      color: LakbayColors.tealDeep,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontSize: 13.5,
                      color: LakbayColors.textSecondary,
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
                  ? LakbayColors.primary
                  : LakbayColors.cardBorder,
              size: 26,
            ),
          ],
        ),
      ),
    );
  }
}

class _TestimonialCard extends StatelessWidget {
  final String quote;
  final String author;
  final String avatarAsset;

  const _TestimonialCard({
    required this.quote,
    required this.author,
    required this.avatarAsset,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: LakbayColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            quote,
            style: const TextStyle(
              fontSize: 14,
              color: LakbayColors.tealDeep,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              ClipOval(
                child: Image.asset(
                  avatarAsset,
                  width: 36,
                  height: 36,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const CircleAvatar(
                    radius: 18,
                    backgroundColor: LakbayColors.primaryLight,
                    child: Icon(
                      Icons.person,
                      size: 18,
                      color: LakbayColors.primaryDark,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                author,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                  color: LakbayColors.tealDeep,
                ),
              ),
            ],
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

    // Airport & city labels
    final labels = [
      ('DAVAO CITY', Offset(size.width * 0.16, size.height * 0.42)),
      ('DVO AIRPORT', Offset(size.width * 0.25, size.height * 0.24)),
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
            color: LakbayColors.tealDeep.withValues(alpha: 0.45),
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
