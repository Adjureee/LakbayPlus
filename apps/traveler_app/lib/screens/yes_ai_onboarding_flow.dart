import 'package:flutter/material.dart';
import '../models/travel_models.dart';
import '../services/travel_repository.dart';
import '../theme/lakbay_theme.dart';
import '../widgets/lakbay_image.dart';
import '../widgets/origin_picker_sheet.dart';
import 'auth_screen.dart';
import 'trip_detail_screen.dart';

/// Interactive "Yes -> AI" onboarding planner powered by Lakbay's live backend:
/// 1) Stateful Layla-style AI trip concierge (`POST /ai/chat/guest` with `is_onboarding: true`,
///    live DB category cards, live trip preview, `/ai/itineraries/generate/guest`, and Phase 2
///    `/planning/draft` catalog fallback)
/// 2) Rating trust pause ("While I set up your trip — Good so far?")
/// 3) Final plan confirmation ("First plan, done." -> "Sign in or create account to save trip")
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
  // 0 = Interactive AI trip planner, 1 = "Good so far?", 2 = "First plan, done."
  int _stage = 0;
  int _planningPercent = 76;
  ItineraryTrip? _selectedOnboardingTrip;
  ItineraryTrip? _generatedTrip;
  bool _planFailed = false;

  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    widget.repo.resetPlanningForOnboarding();
    if (widget.repo.categoryFacets.isEmpty &&
        widget.repo.apiCatalog.isConfigured) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.repo.refreshPreferenceGroups();
      });
    }
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
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  Future<void> _sendOnboardingMessage(String raw) async {
    final text = raw.trim();
    if (text.isEmpty || widget.repo.isAiTyping) return;
    _inputController.clear();

    if (text.toLowerCase() == 'set starting place') {
      await _openOriginPicker();
      return;
    }

    _scrollToBottom();
    await widget.repo.sendChatMessage(text, isOnboarding: true);
    if (!mounted) return;
    _scrollToBottom();
  }

  Future<void> _openOriginPicker() async {
    final picked = await showOriginPickerSheet(context, widget.repo);
    if (!mounted || picked != true) return;
    widget.repo.syncOriginIntoPlanningState();
    _scrollToBottom();
  }

  Future<void> _buildFromPicks() async {
    _scrollToBottom();
    await widget.repo.planWithPicks(isOnboarding: true);
    if (!mounted) return;
    _scrollToBottom();
  }

  void _confirmOnboardingTrip(ItineraryTrip trip) {
    setState(() {
      _selectedOnboardingTrip = trip;
      _stage = 1;
    });
  }

  Future<void> _enterStageThreeAndGenerate() async {
    setState(() {
      _stage = 2;
      _planningPercent = 76;
      _planFailed = false;
      _generatedTrip = null;
    });

    final alreadyBuilt = _selectedOnboardingTrip;
    if (alreadyBuilt != null) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (!mounted) return;
      setState(() => _planningPercent = 94);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      if (!mounted) return;
      setState(() {
        _generatedTrip = alreadyBuilt;
        _planningPercent = 100;
      });
      return;
    }

    final tripFuture = widget.repo.buildOnboardingItinerary();
    await Future<void>.delayed(const Duration(milliseconds: 450));
    if (mounted) setState(() => _planningPercent = 88);

    final trip = await tripFuture;
    if (!mounted) return;
    setState(() {
      _generatedTrip = trip;
      _planFailed = trip == null;
      _planningPercent = trip == null ? 76 : 100;
    });
  }

  void _openGeneratedTrip() {
    final trip = _generatedTrip;
    if (trip == null) return;
    if (widget.repo.isSignedIn) {
      widget.repo.saveTripToMyTrips(trip);
      widget.repo.completeOnboarding();
      Navigator.of(context).popUntil((route) => route.isFirst);
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<bool>(
        builder: (navCtx) => AuthScreen(
          repo: widget.repo,
          initialRegisterMode: true,
          onAuthenticated: () {
            widget.repo.saveTripToMyTrips(trip);
            widget.repo.completeOnboarding();
            Navigator.of(navCtx).popUntil((route) => route.isFirst);
          },
        ),
      ),
    );
  }

  Future<void> _showRaiseBudgetDialog(
    BuildContext context,
    ChatMessage failedMsg,
  ) async {
    final currentBudget =
        widget.repo.planningWholeTripBudgetPhp?.toInt() ?? 5000;
    final ctrl = TextEditingController(
      text: (currentBudget + 3000).toString(),
    );
    final updated = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Raise trip budget'),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Whole-trip budget (₱ PHP)',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final parsed = double.tryParse(ctrl.text.trim());
              Navigator.of(ctx).pop(parsed);
            },
            child: const Text('Update & retry'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (updated == null || updated <= 0 || !mounted) return;
    widget.repo.updatePlanningBudget(updated);
    if (failedMsg.retryText != null) {
      await _sendOnboardingMessage(failedMsg.retryText!);
    }
  }

  String _stageDestinationSummary() {
    final trip = _generatedTrip ?? _selectedOnboardingTrip;
    if (trip != null && trip.destination.trim().isNotEmpty) {
      return '${trip.destination} • ${trip.daysCount} ${trip.daysCount == 1 ? 'day' : 'days'}';
    }
    if (widget.repo.tripBuilderStops.isNotEmpty) {
      return widget.repo.tripBuilderStops.map((s) => s.title).take(2).join(', ');
    }
    if (widget.repo.hasOrigin) {
      return 'From ${widget.repo.effectiveOriginLabel} • Davao Region';
    }
    return 'Davao Region Route';
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.repo,
      builder: (context, _) {
        final turnsCount = widget.repo.chatMessages.length;
        final double progress = switch (_stage) {
          0 => (0.35 + (turnsCount * 0.08)).clamp(0.35, 0.72),
          1 => 0.82,
          _ => 0.96,
        };

        return Scaffold(
          backgroundColor: LakbayColors.canvasBg,
          body: SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 16, 4),
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
                            backgroundColor: LakbayColors.primaryLight
                                .withValues(alpha: 0.45),
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
      },
    );
  }

  Widget _buildAiChatPlannerStage(BuildContext context) {
    final messages = widget.repo.chatMessages;
    final isTyping = widget.repo.isAiTyping;

    return Column(
      children: [
        _buildLiveTripPreviewStrip(context),
        Expanded(
          child: ListView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            itemCount: 1 + messages.length + (isTyping ? 1 : 0),
            itemBuilder: (context, idx) {
              if (idx == 0) {
                return _buildOnboardingIntroSection(
                  context,
                  hasConversation: messages.isNotEmpty,
                );
              }
              final msgIdx = idx - 1;
              if (msgIdx == messages.length && isTyping) {
                return _buildThinkingRow();
              }
              final msg = messages[msgIdx];
              final isLatestAi = !msg.isUser && msgIdx == messages.length - 1;
              return _buildChatMessageItem(context, msg, isLatestAi: isLatestAi);
            },
          ),
        ),
        if (widget.repo.chatPickCount > 0) _buildOnboardingPicksBar(),
        Container(
          margin: const EdgeInsets.fromLTRB(16, 6, 16, 14),
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
                  onSubmitted: _sendOnboardingMessage,
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
                  onPressed: () =>
                      _sendOnboardingMessage(_inputController.text),
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

  Widget _buildLiveTripPreviewStrip(BuildContext context) {
    final state = widget.repo.planningStateView;
    final days = (state['day_count'] as num?)?.toInt();
    final travelers = (state['traveler_count'] as num?)?.toInt();
    final budgetPhp = widget.repo.planningWholeTripBudgetPhp;
    final picksCount = widget.repo.chatPickCount;
    final originText = widget.repo.hasOrigin
        ? 'From ${widget.repo.effectiveOriginLabel}'
        : 'Set starting place';

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: LakbayColors.cardBorder),
        ),
        child: Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            InkWell(
              onTap: _openOriginPicker,
              borderRadius: BorderRadius.circular(10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.my_location_rounded,
                    size: 14,
                    color: LakbayColors.primary,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    originText,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: LakbayColors.tealDeep,
                    ),
                  ),
                ],
              ),
            ),
            if (picksCount > 0)
              _PreviewTag(label: '$picksCount ${picksCount == 1 ? 'stop' : 'stops'}'),
            if (days != null) _PreviewTag(label: '${days}d'),
            if (travelers != null) _PreviewTag(label: '$travelers pax'),
            if (budgetPhp != null && budgetPhp > 0)
              _PreviewTag(label: '₱${budgetPhp.toStringAsFixed(0)}'),
          ],
        ),
      ),
    );
  }

  Widget _buildOnboardingIntroSection(
    BuildContext context, {
    required bool hasConversation,
  }) {
    if (hasConversation) return const SizedBox(height: 4);

    final origin = widget.repo.hasOrigin
        ? 'from ${widget.repo.effectiveOriginLabel}'
        : 'across the Davao Region';
    final categories = widget.repo.categoryFacets.take(6).toList();
    final starters = [
      if (!widget.repo.hasOrigin) 'Set starting place',
      'Inspire me!',
      '3-day beach getaway for 2 on ₱8,000',
      'Waterfalls & mountain escape',
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 12, bottom: 14),
          child: Center(
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
          ),
        ),
        _buildAssistantShell(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Tell me what kind of Davao Region trip you are craving $origin — beaches, waterfalls, highland cafes, or just "Inspire me!" — and we will shape your first route together.',
                style: const TextStyle(
                  fontSize: 14.5,
                  height: 1.45,
                  color: LakbayColors.tealDeep,
                ),
              ),
              if (categories.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text(
                  'Browse catalog categories',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: LakbayColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final cat in categories)
                      ActionChip(
                        visualDensity: VisualDensity.compact,
                        backgroundColor: LakbayColors.canvasBg,
                        side: const BorderSide(color: LakbayColors.cardBorder),
                        label: Text(
                          '${cat.label} (${cat.count})',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: LakbayColors.tealDeep,
                          ),
                        ),
                        onPressed: () {
                          widget.repo.browseCategoryInChat(cat);
                          _scrollToBottom();
                        },
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.only(left: 38),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final opt in starters)
                _SuggestionPill(
                  label: opt,
                  onTap: () => _sendOnboardingMessage(opt),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildThinkingRow() {
    final statusText = widget.repo.aiTypingStatus ?? 'Lakbay+ is planning...';
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
              'L✦',
              style: TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              statusText,
              style: const TextStyle(
                color: LakbayColors.textSecondary,
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAssistantShell(Widget child) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
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
              'L✦',
              style: TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: LakbayColors.cardBorder),
              ),
              child: child,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChatMessageItem(
    BuildContext context,
    ChatMessage msg, {
    required bool isLatestAi,
  }) {
    if (msg.isUser) {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.only(top: 6, bottom: 10, left: 48),
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
          decoration: const BoxDecoration(
            gradient: LakbayColors.brandGradient,
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(18),
              topRight: Radius.circular(18),
              bottomLeft: Radius.circular(18),
              bottomRight: Radius.circular(4),
            ),
          ),
          child: Text(
            msg.text,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildAssistantShell(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  msg.text.replaceAll('**', ''),
                  style: TextStyle(
                    fontSize: 14.5,
                    height: 1.45,
                    color: msg.isError
                        ? const Color(0xFF991B1B)
                        : LakbayColors.tealDeep,
                  ),
                ),
                if (msg.recommendedPlaces.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _buildPlaceCardsStrip(context, msg.recommendedPlaces),
                ],
                if (msg.aiOptions.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _buildOptionCards(context, msg.aiOptions),
                ] else if (msg.attachedTrip != null) ...[
                  const SizedBox(height: 12),
                  _buildSingleTripPreviewCard(context, msg.attachedTrip!),
                ],
                if (msg.isError) ...[
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      if (msg.errorCode == 'planning_over_budget')
                        ActionChip(
                          label: const Text('Raise budget'),
                          onPressed: () => _showRaiseBudgetDialog(context, msg),
                        ),
                      if (msg.retryText != null)
                        ActionChip(
                          avatar: const Icon(Icons.refresh_rounded, size: 16),
                          label: const Text('Try again'),
                          onPressed: () =>
                              _sendOnboardingMessage(msg.retryText!),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          if (isLatestAi && !widget.repo.isAiTyping && msg.askNext != null)
            Padding(
              padding: const EdgeInsets.only(left: 38, bottom: 6),
              child: Wrap(
                spacing: 8,
                runSpacing: 6,
                children: _buildAskNextChips(msg.askNext!),
              ),
            ),
          if (msg.suggestedReplies.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 38),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final reply in msg.suggestedReplies)
                    _SuggestionPill(
                      label: reply,
                      onTap: () => _sendOnboardingMessage(reply),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _buildAskNextChips(String field) {
    final options = switch (field) {
      'activity_level' => const [
          ('easy', 'Easy pace'),
          ('moderate', 'Moderate'),
          ('challenging', 'Challenging'),
        ],
      'prefers_quiet' => const [
          (true, 'Quiet spots'),
          (false, 'Popular icons'),
        ],
      _ => const <(Object, String)>[],
    };
    return [
      for (final (value, label) in options)
        _SuggestionPill(
          label: label,
          onTap: () async {
            await widget.repo.answerChatDetail(
              field,
              value,
              label,
              isOnboarding: true,
            );
            _scrollToBottom();
          },
        ),
    ];
  }

  Widget _buildPlaceCardsStrip(
    BuildContext context,
    List<TopPlaceRecommendation> places,
  ) {
    return SizedBox(
      height: 246,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: places.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          final place = places[index];
          final resolved = widget.repo.resolveExploreTripForRecommendation(place);
          final isAdded = widget.repo.isInTripBuilder(resolved.id);
          final networkImg = (place.imageUrl != null &&
                  place.imageUrl!.startsWith('http'))
              ? place.imageUrl
              : (resolved.hasRemoteThumbnail ? resolved.thumbnailUrl : null);

          return Container(
            width: 215,
            decoration: BoxDecoration(
              color: LakbayColors.canvasBg,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: isAdded ? LakbayColors.primary : LakbayColors.cardBorder,
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  height: 82,
                  width: double.infinity,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      LakbayNetworkOrAssetImage(
                        networkUrl: networkImg,
                        assetPath: resolved.localAssetPath,
                      ),
                      if (place.category != null &&
                          place.category!.trim().isNotEmpty)
                        Positioned(
                          top: 6,
                          left: 6,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: LakbayColors.tealDeep,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              place.category!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(9),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          place.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: 'FigGrotesk',
                            fontWeight: FontWeight.w700,
                            fontSize: 13.5,
                            color: LakbayColors.tealDeep,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          [
                            if (place.district != null &&
                                place.district!.trim().isNotEmpty)
                              place.district!.trim(),
                            if (place.travelMinutes != null)
                              '~${place.travelMinutes} min',
                            ...place.reasons.take(2),
                          ].join(' • '),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 11.5,
                            color: LakbayColors.textSecondary,
                            height: 1.3,
                          ),
                        ),
                        const Spacer(),
                        Row(
                          children: [
                            OutlinedButton(
                              onPressed: () {
                                final trip = widget.repo
                                    .buildDetailedItineraryFromExplore(resolved);
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => TripDetailScreen(
                                      trip: trip,
                                      repo: widget.repo,
                                    ),
                                  ),
                                );
                              },
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 4,
                                ),
                                minimumSize: Size.zero,
                              ),
                              child: const Text(
                                'Inspect',
                                style: TextStyle(fontSize: 11.5),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: ElevatedButton(
                                onPressed: () =>
                                    widget.repo.toggleChatPick(resolved),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: isAdded
                                      ? LakbayColors.primaryLight
                                      : LakbayColors.primary,
                                  foregroundColor: isAdded
                                      ? LakbayColors.tealDeep
                                      : Colors.white,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  minimumSize: Size.zero,
                                ),
                                child: Text(
                                  isAdded ? 'Added' : '+ Add',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 11.5),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildOptionCards(
    BuildContext context,
    List<AiItineraryOptionDraft> options,
  ) {
    return SizedBox(
      height: 206,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: options.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          final opt = options[index];
          return _buildSingleTripPreviewCard(
            context,
            opt.trip,
            summaryOverride: opt.summary,
            isCatalogFallback: opt.isCatalogFallback || opt.trip.isCatalogFallback,
          );
        },
      ),
    );
  }

  Widget _buildSingleTripPreviewCard(
    BuildContext context,
    ItineraryTrip trip, {
    String? summaryOverride,
    bool? isCatalogFallback,
  }) {
    final catalogBuilt = isCatalogFallback ?? trip.isCatalogFallback;
    return Container(
      width: 248,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: LakbayColors.canvasBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: LakbayColors.primary),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (catalogBuilt)
            const Padding(
              padding: EdgeInsets.only(bottom: 4),
              child: Text(
                "Built from Lakbay's catalog, without AI",
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  color: LakbayColors.tealDeep,
                ),
              ),
            ),
          Text(
            trip.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontFamily: 'FigGrotesk',
              fontWeight: FontWeight.w700,
              fontSize: 14.5,
              color: LakbayColors.tealDeep,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            summaryOverride ??
                '${trip.daysCount} ${trip.daysCount == 1 ? 'day' : 'days'} • ${trip.destination}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 12,
              color: LakbayColors.textSecondary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Est. ${widget.repo.formatPrice(trip.totalEstimatedCostUsd)}',
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: LakbayColors.primaryDark,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              OutlinedButton(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) =>
                          TripDetailScreen(trip: trip, repo: widget.repo),
                    ),
                  );
                },
                style: OutlinedButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  minimumSize: Size.zero,
                ),
                child: const Text('Inspect', style: TextStyle(fontSize: 11.5)),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: ElevatedButton(
                  onPressed: () => _confirmOnboardingTrip(trip),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: LakbayColors.primary,
                    foregroundColor: Colors.white,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    minimumSize: Size.zero,
                  ),
                  child: const Text(
                    'Use plan ✨',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11.5),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildOnboardingPicksBar() {
    final count = widget.repo.chatPickCount;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 2, 16, 2),
      padding: const EdgeInsets.fromLTRB(14, 7, 8, 7),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: LakbayColors.primary),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '$count of ${TravelRepository.maxChatPicks} stops picked',
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: LakbayColors.tealDeep,
              ),
            ),
          ),
          ElevatedButton(
            onPressed: widget.repo.isAiTyping ? null : _buildFromPicks,
            style: ElevatedButton.styleFrom(
              backgroundColor: LakbayColors.primary,
              foregroundColor: Colors.white,
              minimumSize: Size.zero,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            ),
            child: Text(
              count == 1 ? 'Plan with 1 pick' : 'Plan with $count picks',
              style: const TextStyle(fontSize: 12.5),
            ),
          ),
        ],
      ),
    );
  }

  // Stage 1: "While I set up your trip — Good so far?"
  Widget _buildGoodSoFarRatingStage(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(22, 16, 22, 24),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight:
                (constraints.maxHeight - 40).clamp(0.0, double.infinity),
          ),
          child: IntrinsicHeight(
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
                              child: Icon(
                                Icons.person,
                                color: LakbayColors.primaryDark,
                              ),
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
                        '"Lakbay+ feels like planning with a local Dabawenyo friend who already knows Samal piers, Mati surf spots, and cool highland cabins."',
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
                              errorBuilder: (_, _, _) => const CircleAvatar(
                                radius: 17,
                                backgroundColor: LakbayColors.primaryLight,
                                child: Icon(Icons.person, size: 18),
                              ),
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
                const SizedBox(height: 16),
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
          ),
        ),
      ),
    );
  }

  // Stage 2: "First plan, done." Timeline
  Widget _buildFirstPlanDoneStage(BuildContext context) {
    final isReady = _planningPercent >= 100 && _generatedTrip != null;
    final routeSummary = _stageDestinationSummary();

    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(22, 16, 22, 20),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight:
                (constraints.maxHeight - 36).clamp(0.0, double.infinity),
          ),
          child: IntrinsicHeight(
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
                Text(
                  isReady && _generatedTrip!.isCatalogFallback
                      ? "Prepared from Lakbay's catalog — review & save it."
                      : 'Review it, then save it to your trips.',
                  style: const TextStyle(
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
                              'L✦',
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
                                      ? (_generatedTrip!.isCatalogFallback
                                          ? 'Catalog itinerary ready!'
                                          : 'Lakbay+ itinerary ready!')
                                      : _planFailed
                                          ? "Couldn't plan your trip"
                                          : 'Lakbay+ is planning...',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 15.5,
                                    color: LakbayColors.tealDeep,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  routeSummary,
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
                        subtitle: 'Shared your trip preferences',
                      ),
                      const _TimelineRow(
                        icon: Icons.check_rounded,
                        filled: true,
                        title: 'Lakbay+✦',
                        subtitle: 'Matched catalog places & logistics',
                      ),
                      _TimelineRow(
                        icon: Icons.auto_awesome,
                        filled: isReady,
                        title: 'Save to your account',
                        subtitle: 'Keep & edit this itinerary anytime',
                      ),
                      _TimelineRow(
                        icon: Icons.location_on_outlined,
                        filled: isReady,
                        isLast: true,
                        title: _generatedTrip?.title ?? routeSummary,
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
                const SizedBox(height: 16),
                const Spacer(),
                if (_planFailed) ...[
                  const Text(
                    "I couldn't reach Lakbay right now to draft your trip. Check your connection and try again.",
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13.5,
                      color: LakbayColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _enterStageThreeAndGenerate,
                      child: const Text('Try again'),
                    ),
                  ),
                ] else
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: isReady ? _openGeneratedTrip : null,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: LakbayColors.primaryLight,
                        foregroundColor: LakbayColors.tealDeep,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(30),
                        ),
                      ),
                      child: Text(
                        widget.repo.isSignedIn
                            ? 'Save to your account'
                            : 'Sign in or create account to save trip',
                        style: const TextStyle(
                          fontFamily: 'FigGrotesk',
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PreviewTag extends StatelessWidget {
  final String label;

  const _PreviewTag({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: LakbayColors.canvasBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: LakbayColors.cardBorder),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
          color: LakbayColors.tealDeep,
        ),
      ),
    );
  }
}

class _SuggestionPill extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _SuggestionPill({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      onPressed: onTap,
      backgroundColor: Colors.white,
      side: const BorderSide(color: LakbayColors.primary),
      label: Text(
        label,
        style: const TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
          color: LakbayColors.tealDeep,
        ),
      ),
    );
  }
}

class _TimelineRow extends StatelessWidget {
  final IconData icon;
  final bool filled;
  final String title;
  final String subtitle;
  final bool isLast;

  const _TimelineRow({
    required this.icon,
    required this.filled,
    required this.title,
    required this.subtitle,
    this.isLast = false,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(
          children: [
            Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: filled
                    ? LakbayColors.primary
                    : LakbayColors.primaryLight.withValues(alpha: 0.45),
                shape: BoxShape.circle,
              ),
              child: Icon(
                icon,
                size: 14,
                color: filled ? Colors.white : LakbayColors.primaryDark,
              ),
            ),
            if (!isLast)
              Container(
                width: 2,
                height: 28,
                color: filled
                    ? LakbayColors.primary.withValues(alpha: 0.4)
                    : LakbayColors.cardBorder,
              ),
          ],
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 12),
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
                const SizedBox(height: 1),
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
