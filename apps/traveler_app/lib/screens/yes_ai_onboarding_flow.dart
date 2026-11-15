import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../models/travel_models.dart';
import '../services/lakbay_ai_service.dart';
import '../services/travel_repository.dart';
import '../theme/lakbay_theme.dart';
import 'trip_detail_screen.dart';

class _OnboardingCarouselSpot {
  final String name;
  final String province;
  final String flagOrBadge;
  final String dateLabel;
  final String tempLabel;
  final String priceLabel;
  final String imageAsset;
  final String blurb;

  const _OnboardingCarouselSpot({
    required this.name,
    required this.province,
    required this.flagOrBadge,
    required this.dateLabel,
    required this.tempLabel,
    required this.priceLabel,
    required this.imageAsset,
    required this.blurb,
  });
}

class _OnboardingChatTurn {
  final bool isUser;
  final String? title;
  final String body;
  final List<_OnboardingCarouselSpot> carousel;
  final List<String> options;
  final bool isGamePlan;

  const _OnboardingChatTurn({
    required this.isUser,
    this.title,
    required this.body,
    this.carousel = const [],
    this.options = const [],
    this.isGamePlan = false,
  });
}

/// Interactive "Yes -> AI" onboarding scenario modeled on the 11-screen flow:
/// 1) Conversational AI trip brief builder ("Where to? I'll plan it.")
/// 2) Rating / social trust pause ("While I set up your trip — Good so far?")
/// 3) Live planning progress timeline ("First plan, done." -> "See your trip")
class YesAiOnboardingFlow extends StatefulWidget {
  final TravelRepository repo;
  final VoidCallback onBackToDecision;

  const YesAiOnboardingFlow({
    super.key,
    required this.repo,
    required this.onBackToDecision,
  });

  @override
  State<YesAiOnboardingFlow> createState() => _YesAiOnboardingFlowState();
}

class _YesAiOnboardingFlowState extends State<YesAiOnboardingFlow> {
  // 0 = Interactive AI chat planner, 1 = "Good so far?" rating step, 2 = "First plan, done."
  int _stage = 0;
  int _chatStep = 0;
  bool _isThinking = false;
  int _planningPercent = 76;
  ItineraryTrip? _generatedTrip;
  AiPlanResult? _lastStructuredPlan;

  String _selectedDestination = 'Samal Island & Davao City';
  String _selectedVibe = 'Just exploring';
  String _selectedOriginAndParty = 'Solo trip';
  String _selectedTiming = 'Next month';
  String? _selectedOptionText;

  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<_OnboardingChatTurn> _turns = [];

  static const List<_OnboardingCarouselSpot> _davaoSpots = [
    _OnboardingCarouselSpot(
      name: 'Samal Island',
      province: 'Davao del Norte',
      flagOrBadge: '🏝️',
      dateLabel: 'Dec 14',
      tempLabel: '29°',
      priceLabel: '₱5,400',
      imageAsset: 'assets/home_backdrops/01-samal-island.jpg',
      blurb:
          'Samal Island (IGaCoS) is pure coral magic—blending giant clams, Taklobo sanctuaries, and white-sand coves just 15 minutes from Davao City.',
    ),
    _OnboardingCarouselSpot(
      name: 'Mati Dahican',
      province: 'Davao Oriental',
      flagOrBadge: '🏄',
      dateLabel: 'Dec 14',
      tempLabel: '30°',
      priceLabel: '₱6,200',
      imageAsset: 'assets/home_backdrops/02-dahican-mati.jpg',
      blurb:
          'Mati & Dahican Beach bring Pacific skimboarding crescent shores, Sleeping Dinosaur vistas, and Aliwagwag Eco Park waterfalls.',
    ),
    _OnboardingCarouselSpot(
      name: 'Buda Highlands',
      province: 'Marilog, Davao',
      flagOrBadge: '🌲',
      dateLabel: 'Dec 14',
      tempLabel: '21°',
      priceLabel: '₱4,800',
      imageAsset: 'assets/home_backdrops/09-marilog-bemwa.jpg',
      blurb:
          'Buda & Marilog serve crisp mountain air, sea-of-clouds sunrise ridges, A-frame pine cabins, and artisan highland coffee.',
    ),
  ];

  @override
  void initState() {
    super.initState();
    final origin = widget.repo.effectiveOriginLabel;
    if (widget.repo.hasUserLocation) {
      _selectedOriginAndParty = 'From $origin';
    }
    final rng = math.Random();
    final greetings = [
      'Hey there, Lakbay+ here! Where are we heading across the Davao Region from $origin? Tell me your vibe, crew, or favorite coastline.',
      'Mabuhay from Lakbay+! Starting from $origin, would you rather island-hop Samal, surf Dahican, or climb misty Buda peaks?',
      'Ready when you are! Share a mood, destination, or budget starting from $origin and we will build your route together.',
    ];
    final discoveryIdeas = [
      if (widget.repo.hasUserLocation) 'Surprise getaway near $origin',
      'What to do in Samal Island?',
      '3-day Dahican surf & Aliwagwag Falls',
      'Cool pine coffee route in Buda & Marilog',
      'Wildcard Davao highlands & food trip',
    ]..shuffle(rng);

    _turns.add(
      _OnboardingChatTurn(
        isUser: false,
        body: greetings[rng.nextInt(greetings.length)],
        options: [
          'Inspire me!',
          discoveryIdeas[0],
          discoveryIdeas[1],
        ],
      ),
    );
  }

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  Future<void> _handleUserSelectionOrInput(
    String input, {
    bool isFreeText = false,
  }) async {
    final text = input.trim();
    if (text.isEmpty || _isThinking) return;
    _inputController.clear();

    setState(() {
      _selectedOptionText = text;
      _turns.add(_OnboardingChatTurn(isUser: true, body: text));
      _isThinking = true;
    });
    _scrollToBottom();

    final lower = text.toLowerCase();

    // Move forward to card finalization when traveler confirms the plan.
    if (lower.contains('looks perfect') || lower.contains('build trip card')) {
      await Future.delayed(const Duration(milliseconds: 300));
      if (!mounted) return;
      setState(() {
        _isThinking = false;
        _stage = 1;
      });
      return;
    }

    // Route BOTH starter chip taps and free-text prompts through live multi-turn AI.
    if (widget.repo.aiService.isConfigured) {
      try {
        final historyTurns = _turns
            .where((t) => t.body.trim().isNotEmpty)
            .take(_turns.length > 1 ? _turns.length - 1 : 0)
            .map(
              (t) => {
                'role': t.isUser ? 'user' : 'assistant',
                'content': t.body,
              },
            )
            .toList();

        final aiResult = await widget.repo.aiService.chatOrPlan(
          userPrompt: text,
          availableDestinations:
              widget.repo.allTrips.map((t) => t.title).toList(),
          history: historyTurns,
          currentLocation: widget.repo.effectiveOriginLabel,
          userLat: widget.repo.userLat,
          userLng: widget.repo.userLng,
          preferredVibes: widget.repo.selectedVibes,
          strictBudget: widget.repo.strictBudgetFilter,
        );
        if (!mounted) return;

        if (aiResult.destination != null &&
            aiResult.destination!.trim().isNotEmpty) {
          _selectedDestination = aiResult.destination!.trim();
        } else if (!lower.contains('inspire') &&
            !lower.contains('wandering')) {
          _selectedDestination = text;
        }
        if (aiResult.daysCount != null) {
          _selectedTiming = '${aiResult.daysCount} days';
        }
        if (aiResult.vibe != null && aiResult.vibe!.trim().isNotEmpty) {
          _selectedVibe = aiResult.vibe!.trim();
        }

        final isReadyPlan = aiResult.hasStructuredItinerary;
        if (isReadyPlan) {
          _lastStructuredPlan = aiResult;
          _chatStep = 5;
        } else {
          _chatStep = math.min(4, _chatStep + 1);
        }

        final dynamicCarousel = (!isReadyPlan && lower.contains('inspire'))
            ? (List<_OnboardingCarouselSpot>.from(_davaoSpots)
              ..shuffle(math.Random()))
            : const <_OnboardingCarouselSpot>[];

        final nextOptions = aiResult.suggestedReplies.isNotEmpty
            ? [
                if (isReadyPlan) 'Looks perfect — build trip card ✨',
                ...aiResult.suggestedReplies,
              ]
            : (isReadyPlan
                ? const [
                    'Looks perfect — build trip card ✨',
                    'Swap destinations or pace',
                    'Tighten budget',
                  ]
                : const [
                    'Build a full multi-day plan ✨',
                    'Show hidden local food & nature stops',
                    'Keep it slow and coastal',
                  ]);

        setState(() {
          _isThinking = false;
          _turns.add(
            _OnboardingChatTurn(
              isUser: false,
              title: isReadyPlan
                  ? (aiResult.title?.isNotEmpty == true
                      ? aiResult.title!
                      : 'Custom Route Ready')
                  : null,
              isGamePlan: isReadyPlan,
              carousel: dynamicCarousel,
              body: aiResult.replyText,
              options: nextOptions,
            ),
          );
        });
        _scrollToBottom();
        return;
      } catch (_) {
        // Fall back to guided offline concierge turns below if network/AI fails.
      }
    }

    await Future.delayed(const Duration(milliseconds: 550));
    if (!mounted) return;

    // If user typed a custom detailed brief directly, check live AI or advance to Game Plan
    if (_chatStep == 0 && lower.contains('inspire me')) {
      _chatStep = 1;
      setState(() {
        _isThinking = false;
        _turns.add(
          const _OnboardingChatTurn(
            isUser: false,
            title: 'Davao Region awaits',
            body:
                'Here are dreamy getaways right in Region XI, from Samal coral reefs to Mati surf beaches and cool Buda pine ridges.\n\nWhich of these spots catches your eye?',
            carousel: _davaoSpots,
            options: [
              'Samal Island',
              'Mati Dahican',
              'Buda Highlands',
            ],
          ),
        );
      });
    } else if (_chatStep <= 1) {
      if (lower.contains('mati') || lower.contains('dahican')) {
        _selectedDestination = 'Mati Dahican & Aliwagwag Falls';
      } else if (lower.contains('buda') || lower.contains('marilog')) {
        _selectedDestination = 'Buda & Marilog Pine Highlands';
      } else if (lower.contains('apo') || lower.contains('kapatagan')) {
        _selectedDestination = 'Kapatagan Highlands & Mt. Apo';
      } else if (lower.contains('samal')) {
        _selectedDestination = 'Samal Island & Talikud Reefs';
      } else if (text.length > 20 && !lower.contains('plan a 4-day')) {
        _selectedDestination = text;
      }

      final matchedSpot = _davaoSpots.firstWhere(
        (s) => _selectedDestination.toLowerCase().contains(s.name.split(' ').first.toLowerCase()),
        orElse: () => _davaoSpots.first,
      );

      _chatStep = 2;
      setState(() {
        _isThinking = false;
        _turns.add(
          _OnboardingChatTurn(
            isUser: false,
            title: 'Maayong Pag-abot: ${matchedSpot.name}',
            body:
                '${matchedSpot.blurb}\n\nWhat kind of vibes are you craving for this trip?',
            carousel: [matchedSpot],
            options: const [
              'Just exploring',
              'Island & beach chill',
              'Food & nature trail',
            ],
          ),
        );
      });
    } else if (_chatStep == 2) {
      _selectedVibe = text;
      _chatStep = 3;
      setState(() {
        _isThinking = false;
        _turns.add(
          _OnboardingChatTurn(
            isUser: false,
            title: 'Wandering mode on',
            body:
                'Wandering without a strict agenda is the best way to uncover Davao\'s hidden coves, local durian stalls, and highland cafes.\n\nWhere will you be setting off from, and who is joining you?',
            options: [
              'Flying to Davao (DVO)',
              'From ${widget.repo.effectiveOriginLabel}',
              'Solo trip',
            ],
          ),
        );
      });
    } else if (_chatStep == 3) {
      _selectedOriginAndParty = text;
      _chatStep = 4;
      setState(() {
        _isThinking = false;
        _turns.add(
          _OnboardingChatTurn(
            isUser: false,
            title: '$_selectedOriginAndParty adventures',
            body:
                'Traveling through Davao Region is super welcoming, scenic, and easy to customize.\n\nWhen are you thinking of going and for how many days?',
            options: const [
              '3 days • Next weekend',
              '4 days • Next month',
              '5 days • Dec 2026',
            ],
          ),
        );
      });
    } else {
      if (!lower.contains('change dates') && !lower.contains('tweak it')) {
        _selectedTiming = text;
      } else {
        _selectedTiming = '4 days • Flexible Region XI dates';
      }
      _chatStep = 5;
      setState(() {
        _isThinking = false;
        _turns.add(
          _OnboardingChatTurn(
            isUser: false,
            title: 'Ready to roll',
            isGamePlan: true,
            body:
                'Here is our game plan for your Davao Region escape:\n\n• Starting Point: ${widget.repo.effectiveOriginLabel} → $_selectedDestination\n• Dates & Duration: $_selectedTiming\n• Travel Style & Party: $_selectedOriginAndParty ($_selectedVibe)\n\nDoes this look good to you, or should we adjust anything before I build your trip card?',
            options: const [
              'Looks perfect',
              'Change dates',
              'Tweak it',
            ],
          ),
        );
      });
    }

    _scrollToBottom();
  }

  Future<void> _enterStageThreeAndGenerate() async {
    setState(() {
      _stage = 2;
      _planningPercent = 76;
    });

    if (_lastStructuredPlan != null &&
        _lastStructuredPlan!.hasStructuredItinerary) {
      await Future.delayed(const Duration(milliseconds: 350));
      if (mounted) setState(() => _planningPercent = 94);
      final built = widget.repo.buildTripFromAiResult(_lastStructuredPlan!);
      await Future.delayed(const Duration(milliseconds: 220));
      if (!mounted) return;
      setState(() {
        _generatedTrip = built;
        _planningPercent = 100;
      });
      return;
    }

    final userNotes = _turns
        .where((t) => t.isUser && t.body.trim().isNotEmpty)
        .map((t) => t.body.trim())
        .join(' • ');
    final briefPrompt =
        'Origin: ${widget.repo.effectiveOriginLabel}. Preferences: $userNotes. Plan a $_selectedTiming trip to $_selectedDestination in Davao Region for $_selectedOriginAndParty, vibe: $_selectedVibe.';

    final tripFuture = widget.repo.createTripFromAiPrompt(briefPrompt);

    await Future.delayed(const Duration(milliseconds: 500));
    if (mounted) setState(() => _planningPercent = 88);

    final trip = await tripFuture;
    if (!mounted) return;
    setState(() {
      _generatedTrip = trip;
      _planningPercent = 100;
    });
  }

  void _openGeneratedTrip() {
    final trip = _generatedTrip ??
        widget.repo.generateCustomTrip(
          destination: _selectedDestination,
          daysCount: 4,
          vibe: _selectedVibe,
        );
    widget.repo.saveTripToMyTrips(trip);
    widget.repo.completeOnboarding();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TripDetailScreen(repo: widget.repo, trip: trip),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final double progress = switch (_stage) {
      0 => (0.35 + (_chatStep * 0.08)).clamp(0.35, 0.72),
      1 => 0.82,
      _ => 0.96,
    };

    return Scaffold(
      backgroundColor: LakbayColors.canvasBg,
      body: SafeArea(
        child: Column(
          children: [
            // Shared Progress Header
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 16, 8),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () {
                      if (_stage > 0) {
                        setState(() => _stage--);
                      } else {
                        widget.onBackToDecision();
                      }
                    },
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
                        value: progress,
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
                  if (_stage != 2)
                    TextButton(
                      onPressed: () {
                        if (_stage == 0) {
                          setState(() => _stage = 1);
                        } else if (_stage == 1) {
                          _enterStageThreeAndGenerate();
                        }
                      },
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
              child: switch (_stage) {
                0 => _buildAiChatPlannerStage(context),
                1 => _buildGoodSoFarRatingStage(context),
                _ => _buildFirstPlanDoneStage(context),
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAiChatPlannerStage(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
            itemCount: _turns.length + (_isThinking ? 2 : 1),
            itemBuilder: (context, idx) {
              if (idx == 0) {
                if (_turns.length == 1) {
                  return const Padding(
                    padding: EdgeInsets.only(top: 20, bottom: 18),
                    child: Text(
                      "Where to? I'll plan it.",
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontFamily: 'FigGrotesk',
                        fontSize: 27,
                        fontWeight: FontWeight.w800,
                        color: LakbayColors.tealDeep,
                      ),
                    ),
                  );
                }
                return const SizedBox(height: 4);
              }

              final turnIndex = idx - 1;
              if (turnIndex == _turns.length && _isThinking) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Row(
                    children: [
                      Container(
                        width: 30,
                        height: 30,
                        decoration: const BoxDecoration(
                          color: LakbayColors.tealDeep,
                          shape: BoxShape.circle,
                        ),
                        alignment: Alignment.center,
                        child: const Text(
                          'S✦',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      const Text(
                        'Lakbay+ is thinking...',
                        style: TextStyle(
                          color: LakbayColors.textSecondary,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                );
              }

              final turn = _turns[turnIndex];
              final isLatestAiCard =
                  !turn.isUser && turnIndex == _turns.length - 1;
              return _buildTurnWidget(turn, isLatestAiCard: isLatestAiCard);
            },
          ),
        ),

        // Bottom Prompt Input Bar ("Tell me where you'd like to travel")
        Container(
          margin: const EdgeInsets.fromLTRB(16, 4, 16, 14),
          padding: const EdgeInsets.fromLTRB(18, 8, 8, 8),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(30),
            border: Border.all(color: LakbayColors.cardBorder),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.06),
                blurRadius: 12,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _inputController,
                  onSubmitted: (val) =>
                      _handleUserSelectionOrInput(val, isFreeText: true),
                  decoration: const InputDecoration(
                    hintText: "Tell me where you'd like to travel",
                    hintStyle: TextStyle(
                      color: LakbayColors.textSecondary,
                      fontSize: 14.5,
                    ),
                    border: InputBorder.none,
                    isDense: true,
                  ),
                ),
              ),
              Material(
                color: LakbayColors.primaryLight,
                shape: const CircleBorder(),
                child: IconButton(
                  onPressed: () => _handleUserSelectionOrInput(
                    _inputController.text,
                    isFreeText: true,
                  ),
                  icon: const Icon(
                    Icons.arrow_upward_rounded,
                    color: LakbayColors.primaryDark,
                    size: 20,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTurnWidget(
    _OnboardingChatTurn turn, {
    required bool isLatestAiCard,
  }) {
    if (turn.isUser) {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.only(bottom: 14, left: 60),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
          decoration: BoxDecoration(
            color: LakbayColors.primaryLight.withValues(alpha: 0.72),
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(18),
              topRight: Radius.circular(18),
              bottomLeft: Radius.circular(18),
              bottomRight: Radius.circular(6),
            ),
          ),
          child: Text(
            turn.body,
            style: const TextStyle(
              color: LakbayColors.tealDeep,
              fontSize: 14.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (turn.carousel.isNotEmpty) ...[
            SizedBox(
              height: 255,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: turn.carousel.length,
                separatorBuilder: (_, _) => const SizedBox(width: 12),
                itemBuilder: (context, i) {
                  final spot = turn.carousel[i];
                  return GestureDetector(
                    onTap: isLatestAiCard
                        ? () => _handleUserSelectionOrInput(spot.name)
                        : null,
                    child: Container(
                      width: 245,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(22),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.12),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Image.asset(
                            spot.imageAsset,
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
                                  Color(0x11000000),
                                  Color(0xCC071E26),
                                ],
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                              ),
                            ),
                          ),
                          Positioned(
                            left: 14,
                            right: 14,
                            bottom: 14,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${spot.flagOrBadge} ${spot.name}',
                                  style: const TextStyle(
                                    fontFamily: 'FigGrotesk',
                                    color: Colors.white,
                                    fontWeight: FontWeight.w800,
                                    fontSize: 18,
                                  ),
                                ),
                                Text(
                                  spot.province,
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.85),
                                    fontSize: 12.5,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Wrap(
                                  spacing: 6,
                                  children: [
                                    _CarouselStatChip(
                                      icon: Icons.calendar_today_outlined,
                                      label: spot.dateLabel,
                                    ),
                                    _CarouselStatChip(
                                      icon: Icons.wb_sunny_outlined,
                                      label: spot.tempLabel,
                                    ),
                                    _CarouselStatChip(
                                      icon: Icons.flight_outlined,
                                      label: spot.priceLabel,
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 12),
          ],
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 28,
                height: 28,
                margin: const EdgeInsets.only(top: 4),
                decoration: const BoxDecoration(
                  color: LakbayColors.primaryLight,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.auto_awesome,
                  size: 15,
                  color: LakbayColors.primaryDark,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(color: LakbayColors.cardBorder),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (turn.title != null) ...[
                        Text(
                          turn.title!,
                          style: const TextStyle(
                            fontFamily: 'FigGrotesk',
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                            color: LakbayColors.tealDeep,
                          ),
                        ),
                        const SizedBox(height: 8),
                      ],
                      Text(
                        turn.body,
                        style: const TextStyle(
                          fontSize: 14.5,
                          color: LakbayColors.tealDeep,
                          height: 1.45,
                        ),
                      ),
                      if (turn.options.isNotEmpty && isLatestAiCard) ...[
                        const SizedBox(height: 14),
                        for (final opt in turn.options)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(14),
                              onTap: () => _handleUserSelectionOrInput(opt),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 12,
                                ),
                                decoration: BoxDecoration(
                                  color: LakbayColors.canvasBg,
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(
                                    color: _selectedOptionText == opt
                                        ? LakbayColors.primary
                                        : LakbayColors.cardBorder,
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        opt,
                                        style: const TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600,
                                          color: LakbayColors.tealDeep,
                                        ),
                                      ),
                                    ),
                                    Icon(
                                      _selectedOptionText == opt
                                          ? Icons.radio_button_checked_rounded
                                          : Icons.radio_button_off_rounded,
                                      size: 20,
                                      color: _selectedOptionText == opt
                                          ? LakbayColors.primary
                                          : LakbayColors.textMuted,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // Stage 1: "While I set up your trip — Good so far?" (Image 2)
  Widget _buildGoodSoFarRatingStage(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 16, 22, 24),
      child: Column(
        children: [
          const Text(
            'While I set up your trip',
            style: TextStyle(
              fontSize: 14,
              color: LakbayColors.textSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Good so far?',
            style: TextStyle(
              fontFamily: 'FigGrotesk',
              fontSize: 28,
              fontWeight: FontWeight.w800,
              color: LakbayColors.tealDeep,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'A rating helps more people find Lakbay+.',
            style: TextStyle(
              fontSize: 14,
              color: LakbayColors.textSecondary,
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            'Lakbay+✦ was made for people like you',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: LakbayColors.textSecondary,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (final asset in const [
                'assets/experts/carla.webp',
                'assets/experts/aleks.webp',
                'assets/experts/rob.webp',
              ])
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 2),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2.5),
                  ),
                  child: ClipOval(
                    child: Image.asset(
                      asset,
                      width: 56,
                      height: 56,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => const CircleAvatar(
                        radius: 28,
                        backgroundColor: LakbayColors.primaryLight,
                        child: Icon(Icons.person, color: LakbayColors.primaryDark),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: LakbayColors.cardBorder),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '"Lakbay+ doesn\'t feel like a generic bot. It feels like chatting with a super organized friend who already knows Samal\'s hidden coves, Mati\'s surf spots, and the ferry logistics you\'d forget to check."',
                  style: TextStyle(
                    fontSize: 14.5,
                    color: LakbayColors.tealDeep,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    ClipOval(
                      child: Image.asset(
                        'assets/experts/carla.webp',
                        width: 34,
                        height: 34,
                        fit: BoxFit.cover,
                      ),
                    ),
                    const SizedBox(width: 10),
                    const Text(
                      'Carla G',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                        color: LakbayColors.tealDeep,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const Spacer(),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _enterStageThreeAndGenerate,
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
                'Rate Lakbay+✦',
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

  // Stage 2: "First plan, done." Timeline (Image 11)
  Widget _buildFirstPlanDoneStage(BuildContext context) {
    final isReady = _planningPercent >= 100;

    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 16, 22, 20),
      child: Column(
        children: [
          const Text(
            'First plan, done.',
            style: TextStyle(
              fontFamily: 'FigGrotesk',
              fontSize: 28,
              fontWeight: FontWeight.w800,
              color: LakbayColors.tealDeep,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Your travel expert checks it next.',
            style: TextStyle(
              fontSize: 14.5,
              color: LakbayColors.textSecondary,
            ),
          ),
          const SizedBox(height: 22),
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: LakbayColors.cardBorder),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.05),
                  blurRadius: 14,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: const BoxDecoration(
                        color: LakbayColors.primaryLight,
                        shape: BoxShape.circle,
                      ),
                      alignment: Alignment.center,
                      child: const Text(
                        'S✦',
                        style: TextStyle(
                          fontFamily: 'FigGrotesk',
                          fontWeight: FontWeight.w800,
                          fontSize: 17,
                          color: LakbayColors.primaryDark,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            isReady
                                ? 'Lakbay+ itinerary ready!'
                                : 'Lakbay+ is planning...',
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 15.5,
                              color: LakbayColors.tealDeep,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '$_selectedDestination • Davao Region',
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
                  ],
                ),
                const SizedBox(height: 20),
                const _TimelineRow(
                  icon: Icons.check_rounded,
                  filled: true,
                  title: 'You',
                  subtitle: 'Said the word',
                ),
                const _TimelineRow(
                  icon: Icons.check_rounded,
                  filled: true,
                  title: 'Lakbay+✦',
                  subtitle: 'Shortlisted Davao stays, ferry & route',
                ),
                _TimelineRow(
                  icon: Icons.auto_awesome,
                  filled: isReady,
                  title: 'Your expert',
                  subtitle: 'Checks and books',
                ),
                _TimelineRow(
                  icon: Icons.location_on_outlined,
                  filled: isReady,
                  isLast: true,
                  title: _selectedDestination,
                  subtitle: isReady ? 'Ready to view!' : 'Almost ready',
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    const Icon(
                      Icons.bolt_rounded,
                      size: 16,
                      color: LakbayColors.textSecondary,
                    ),
                    const SizedBox(width: 4),
                    const Text(
                      'Planning progress',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: LakbayColors.textSecondary,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '$_planningPercent%',
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w800,
                        color: LakbayColors.primary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    value: _planningPercent / 100,
                    minHeight: 7,
                    backgroundColor: LakbayColors.canvasBg,
                    valueColor: const AlwaysStoppedAnimation<Color>(
                      LakbayColors.primary,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Spacer(),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _openGeneratedTrip,
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
                'See your trip',
                style: TextStyle(
                  fontFamily: 'FigGrotesk',
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            'Every trip checked by a person.',
            style: TextStyle(
              fontSize: 12.5,
              color: LakbayColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _CarouselStatChip extends StatelessWidget {
  final IconData icon;
  final String label;

  const _CarouselStatChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: Colors.white),
          const SizedBox(width: 4),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _TimelineRow extends StatelessWidget {
  final IconData icon;
  final bool filled;
  final bool isLast;
  final String title;
  final String subtitle;

  const _TimelineRow({
    required this.icon,
    required this.filled,
    this.isLast = false,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(
          children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: filled ? LakbayColors.primary : Colors.white,
                shape: BoxShape.circle,
                border: Border.all(
                  color: filled
                      ? LakbayColors.primary
                      : LakbayColors.primaryLight,
                  width: 1.5,
                ),
              ),
              child: Icon(
                icon,
                size: 16,
                color: filled ? Colors.white : LakbayColors.primaryDark,
              ),
            ),
            if (!isLast)
              Container(
                width: 2,
                height: 22,
                color: LakbayColors.primaryLight,
              ),
          ],
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 2, bottom: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                    color: LakbayColors.tealDeep,
                  ),
                ),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: LakbayColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
