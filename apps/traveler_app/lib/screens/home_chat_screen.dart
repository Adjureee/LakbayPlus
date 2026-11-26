import 'dart:async';
import '../core/day_labels.dart';
import '../core/lakbay_motion.dart';
import 'package:animations/animations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import '../services/voice_input_service.dart';
import '../models/travel_models.dart';
import '../services/travel_repository.dart';
import '../theme/lakbay_theme.dart';
import '../widgets/lakbay_image.dart';
import '../widgets/notifications_sheet.dart';
import '../widgets/origin_picker_sheet.dart';
import '../widgets/timeline_widgets.dart';
import '../widgets/user_avatar.dart';
import 'trip_detail_screen.dart';

class HomeChatScreen extends StatefulWidget {
  final TravelRepository repo;

  const HomeChatScreen({super.key, required this.repo});

  @override
  State<HomeChatScreen> createState() => _HomeChatScreenState();
}

class _HomeChatScreenState extends State<HomeChatScreen> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final TextEditingController _inputController = TextEditingController();
  final TextEditingController _drawerSearchController = TextEditingController();
  final VoiceInputService _voiceInput = const VoiceInputService();
  bool _isListeningVoice = false;
  final ScrollController _scrollController = ScrollController();

  /// Messages already on screen when the chat was opened (or already
  /// animated). Only a message that is not in here fades in.
  Set<String>? _knownMessageIds;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onChatScroll);
  }

  /// Scrolling down through the answer hides the bottom bar; scrolling up, or
  /// being back at the top, brings it back.
  void _onChatScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    final hidden = widget.repo.chatNavHidden;
    switch (position.userScrollDirection) {
      case ScrollDirection.reverse:
        if (position.pixels > 48 && !hidden.value) hidden.value = true;
      case ScrollDirection.forward:
        if (hidden.value) hidden.value = false;
      case ScrollDirection.idle:
        break;
    }
    if (position.pixels <= 0 && hidden.value) hidden.value = false;
  }

  void _handleSend([String? presetPrompt]) {
    final text = presetPrompt ?? _inputController.text;
    if (text.trim().isEmpty) return;
    if (presetPrompt == null) {
      _inputController.clear();
    }
    widget.repo.sendChatMessage(text);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  void _retryChatError(ChatMessage msg) {
    final retryText = msg.retryText;
    if (retryText == null) return;
    if (retryText.startsWith('Plan a trip with my ') &&
        widget.repo.chatPickCount > 0) {
      widget.repo.planWithPicks();
      return;
    }
    _handleSend(retryText);
  }

  Future<void> _showRaiseBudgetDialog(BuildContext context) async {
    final current = widget.repo.planningWholeTripBudgetPhp ?? 5000;
    final suggested = ((current * 1.5) / 500).ceil() * 500;
    final controller = TextEditingController(text: suggested.toStringAsFixed(0));
    final updated = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Raise trip budget'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Whole-trip budget (₱ PHP)',
            prefixText: '₱ ',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final parsed = double.tryParse(controller.text.trim());
              if (parsed != null && parsed >= 500) {
                Navigator.of(ctx).pop(parsed);
              }
            },
            child: const Text('Update & retry'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (updated != null) {
      await widget.repo.raisePlanningBudgetAndRetry(updated);
    }
  }

  Future<void> _showRemovePickSheet(BuildContext context) async {
    final picks = widget.repo.tripBuilderStops
        .where((s) => s.apiDestinationId != null)
        .toList();
    if (picks.isEmpty) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 18, 20, 6),
              child: Text(
                'Remove a place to fit your budget',
                style: TextStyle(
                  fontFamily: 'FigGrotesk',
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  color: LakbayColors.tealDeep,
                ),
              ),
            ),
            for (final stop in picks)
              ListTile(
                title: Text(stop.title),
                subtitle: Text(stop.regionName),
                trailing: const Icon(
                  Icons.remove_circle_outline_rounded,
                  color: LakbayColors.primary,
                ),
                onTap: () {
                  Navigator.of(ctx).pop();
                  widget.repo.removePickAndRetry(stop);
                },
              ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onChatScroll);
    widget.repo.chatNavHidden.value = false;
    _inputController.dispose();
    _drawerSearchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.repo,
      builder: (context, _) {
        final backdrop = widget.repo.currentBackdrop;
        final messages = widget.repo.chatMessages;
        final isLanding = messages.isEmpty && !widget.repo.isAiTyping;

        return Scaffold(
      key: _scaffoldKey,
      drawer: _buildChatHistoryDrawer(context),
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Dynamic scenic backdrop
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 500),
            child: Image.asset(
              backdrop.localAssetPath,
              key: ValueKey(backdrop.id),
              fit: BoxFit.cover,
              width: double.infinity,
              height: double.infinity,
              errorBuilder: (_, _, _) => Container(
                decoration:
                    const BoxDecoration(gradient: LakbayColors.deepTealGradient),
              ),
            ),
          ),
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: isLanding
                    ? const [
                        Color(0x66071E26),
                        Color(0x45071E26),
                        Color(0xCC071E26),
                      ]
                    : const [
                        Color(0xB8071E26),
                        Color(0x75071E26),
                        Color(0xEB071E26),
                      ],
                stops: const [0.0, 0.35, 0.92],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
            ),
          ),
          // Soft dark fade behind the header so plain icons stay readable.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: 170,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(
                        alpha: LakbayContrast.headerFadeAlpha,
                      ),
                      Colors.black.withValues(alpha: 0.0),
                    ],
                  ),
                ),
              ),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                // Top Bar: Hamburger Menu (Drawer) + Today's View Backdrop Pill
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 48,
                        height: 48,
                        child: IconButton(
                          tooltip: 'Chat History',
                          onPressed: () =>
                              _scaffoldKey.currentState?.openDrawer(),
                          icon: const Icon(
                            Icons.menu_rounded,
                            size: 26,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Center(
                          child: InkWell(
                            key: const ValueKey('start-place-pill'),
                            // Tap sets the starting place; press and hold
                            // still changes the background photo.
                            onTap: () =>
                                showOriginPickerSheet(context, widget.repo),
                            onLongPress: widget.repo.nextBackdrop,
                            borderRadius: BorderRadius.circular(24),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 9,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(
                                  alpha: LakbayContrast.startPillAlpha,
                                ),
                                borderRadius: BorderRadius.circular(24),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(
                                    Icons.place_outlined,
                                    size: 15,
                                    color: Colors.white,
                                  ),
                                  const SizedBox(width: 6),
                                  Flexible(
                                    child: Text(
                                      widget.repo.hasOrigin
                                          ? 'Start: ${widget.repo.originDisplayName}'
                                          : 'Set starting place',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      NotificationBellButton(
                        repo: widget.repo,
                        iconColor: Colors.white,
                      ),
                    ],
                  ),
                ),

                // Main Content: Hero Landing (Image 6) or Active Chat Thread
                Expanded(
                  child: AnimatedSwitcher(
                    duration:
                        LakbayMotion.of(context, LakbayMotion.standard),
                    switchInCurve: LakbayMotion.enter,
                    switchOutCurve: LakbayMotion.exit,
                    child: KeyedSubtree(
                      key: ValueKey(isLanding ? 'landing' : 'thread'),
                      child: isLanding
                          ? _buildHeroLanding(context, backdrop)
                          : _buildActiveChatThread(context, messages),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
        );
      },
    );
  }

  void _showVoicePromptFallbackSheet(BuildContext context) {
    final promptCtrl = TextEditingController();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 20,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Tell Lakbay+ your Davao plans',
              style: TextStyle(
                fontFamily: 'FigGrotesk',
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: LakbayColors.tealDeep,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Voice dictation is unavailable in this browser session. Type or pick a quick Davao prompt below:',
              style: TextStyle(fontSize: 13, color: LakbayColors.textSecondary),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: promptCtrl,
              autofocus: true,
              decoration: InputDecoration(
                hintText: 'Tell Lakbay AI what you like',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              onSubmitted: (val) {
                if (val.trim().isNotEmpty) {
                  Navigator.of(ctx).pop();
                  _handleSend(val.trim());
                }
              },
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                // Quick starts come from the catalog's preference groups.
                for (final group in widget.repo.preferenceGroups)
                  ActionChip(
                    label: Text(group.label),
                    onPressed: () {
                      Navigator.of(ctx).pop();
                      _handleSend('I like ${group.label.toLowerCase()}');
                    },
                  ),
              ],
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: () {
                final text = promptCtrl.text.trim();
                if (text.isEmpty) return;
                Navigator.of(ctx).pop();
                _handleSend(text);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: LakbayColors.primary,
                foregroundColor: Colors.white,
              ),
              child: const Text('Plan my trip'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeroLanding(BuildContext context, BackdropItem backdrop) {
    final firstName = widget.repo.profile.firstName;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 110),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 12),
          // One calm headline; the composer below is the main thing on screen.
          Text(
            '${firstName.trim().isEmpty ? 'Hi there' : 'Hi ${firstName.trim()}'},\nwhere to next?',
            style: const TextStyle(
              fontFamily: 'FigGrotesk',
              fontSize: 28,
              fontWeight: FontWeight.w800,
              color: Colors.white,
              height: 1.15,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 18),

          // Rounded Prompt Card with `+` and `Plan it ->`
          Container(
            padding: const EdgeInsets.fromLTRB(18, 16, 14, 14),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.96),
              borderRadius: BorderRadius.circular(26),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.22),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Column(
              children: [
                TextField(
                  controller: _inputController,
                  minLines: 2,
                  maxLines: 4,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _handleSend(),
                  decoration: const InputDecoration(
                    hintText:
                        'Where to in Davao Region? tell Lakbay+ your dates, budget and style...',
                    hintStyle: TextStyle(
                      color: LakbayColors.textSecondary,
                      fontSize: 15,
                      height: 1.35,
                    ),
                    border: InputBorder.none,
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    PopupMenuButton<String>(
                      key: const ValueKey('composer-plus-menu'),
                      tooltip: 'More options',
                      style: IconButton.styleFrom(
                        minimumSize: const Size(48, 48),
                        padding: EdgeInsets.zero,
                      ),
                      icon: const Icon(
                        Icons.add_rounded,
                        color: LakbayColors.tealDeep,
                      ),
                      onSelected: (value) {
                        switch (value) {
                          case 'new_chat':
                            widget.repo.startNewChat();
                          case 'budget':
                            widget.repo.setStrictBudgetFilter(
                              !widget.repo.strictBudgetFilter,
                            );
                          case 'origin':
                            showOriginPickerSheet(context, widget.repo);
                        }
                      },
                      itemBuilder: (_) => [
                        const PopupMenuItem(
                          value: 'new_chat',
                          child: Text('New chat'),
                        ),
                        CheckedPopupMenuItem(
                          value: 'budget',
                          checked: widget.repo.strictBudgetFilter,
                          child: const Text('Within budget'),
                        ),
                        const PopupMenuItem(
                          value: 'origin',
                          child: Text('Set starting place'),
                        ),
                      ],
                    ),
                    // A filter that is on stays visible; one that is off does not
                    // take up room.
                    if (widget.repo.strictBudgetFilter)
                      Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: InputChip(
                          key: const ValueKey('budget-chip'),
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          label: const Text(
                            'Within budget',
                            style: TextStyle(fontSize: 12),
                          ),
                          onDeleted: () =>
                              widget.repo.setStrictBudgetFilter(false),
                        ),
                      ),
                    const Spacer(),
                    IconButton(
                      key: const ValueKey('composer-mic'),
                      tooltip: _isListeningVoice ? 'Listening…' : 'Speak',
                      onPressed: () => _startVoice(context),
                      icon: Icon(
                        _isListeningVoice
                            ? Icons.graphic_eq_rounded
                            : Icons.mic_none_rounded,
                        color: _isListeningVoice
                            ? LakbayColors.primary
                            : LakbayColors.tealDeep,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: ElevatedButton(
                      onPressed: _handleSend,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: LakbayColors.primary,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 11,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(24),
                        ),
                      ),
                      // Shrinks to fit when the phone's text is very large.
                      child: const FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'Plan it',
                              maxLines: 1,
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 14,
                              ),
                            ),
                            SizedBox(width: 5),
                            Icon(Icons.arrow_forward_rounded, size: 16),
                          ],
                        ),
                      ),
                    ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(height: 14),

          // Quick Suggestion Pills
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _HeroChip(
                label: 'Things to do in ${backdrop.place}',
                onTap: () => _handleSend(
                  'Show me places to visit around ${backdrop.place}',
                ),
              ),
              _HeroChip(
                label: 'Surprise me',
                onTap: () => _handleSend(
                  widget.repo.hasOrigin
                      ? 'Surprise me with places to visit near ${widget.repo.effectiveOriginLabel}'
                      : 'Surprise me with places to visit in the Davao Region',
                ),
              ),
            ],
          ),
          if (widget.repo.categoryFacets.isNotEmpty) ...[
            const SizedBox(height: 16),
            _buildBrowseCategoriesStrip(context),
          ],
          if (widget.repo.originRegionNote != null) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.9),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                widget.repo.originRegionNote!,
                style: const TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: LakbayColors.tealDeep,
                ),
              ),
            ),
          ],

        ],
      ),
    );
  }

  /// Speaks a request: listens once, sends what was heard, or falls back to a
  /// typed prompt when the phone cannot listen.
  Future<void> _startVoice(BuildContext context) async {
    if (_isListeningVoice) return;
    if (_voiceInput.isSupported) {
      setState(() => _isListeningVoice = true);
      final transcript = await _voiceInput.listenOnce();
      if (!mounted) return;
      setState(() => _isListeningVoice = false);
      if (transcript != null && transcript.isNotEmpty) {
        _inputController.text = transcript;
        _handleSend(transcript);
        return;
      }
    }
    if (!context.mounted) return;
    _showVoicePromptFallbackSheet(context);
  }

  Widget _buildActiveChatThread(
    BuildContext context,
    List<ChatMessage> messages,
  ) {
    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
            itemCount: messages.length + (widget.repo.isAiTyping ? 1 : 0),
            itemBuilder: (context, index) {
              if (index == messages.length && widget.repo.isAiTyping) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.94),
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: LakbayColors.primary,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Flexible(
                              child: Text(
                                widget.repo.aiTypingStatus ??
                                    'Lakbay+ AI is planning your Davao route...',
                                style: const TextStyle(
                                  color: LakbayColors.tealAccent,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              }
              final message = messages[index];
              _knownMessageIds ??= {for (final m in messages) m.id};
              final bubble = _buildMessageBubble(context, message);
              if (_knownMessageIds!.contains(message.id)) return bubble;
              // New this build: enter after the messages before it, a beat apart.
              _knownMessageIds!.add(message.id);
              return LakbayEntrance(
                key: ValueKey('enter-${message.id}'),
                delay: message.isUser ? Duration.zero : LakbayMotion.stagger,
                child: bubble,
              );
            },
          ),
        ),
        if (widget.repo.chatPickCount > 0 && !widget.repo.isAiTyping)
          _buildPlanWithPicksBar(context),
        // Bottom Chat Input Bar (above floating nav bar). It drops down to
        // take the bar's place while the bar is hidden.
        ValueListenableBuilder<bool>(
          valueListenable: widget.repo.chatNavHidden,
          builder: (context, navHidden, child) => AnimatedContainer(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            margin: EdgeInsets.fromLTRB(16, 4, 16, navHidden ? 16 : 90),
            child: child,
          ),
          child: Container(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.96),
            borderRadius: BorderRadius.circular(28),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.2),
                blurRadius: 16,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            children: [
              PopupMenuButton<String>(
                key: const ValueKey('chat-plus-menu'),
                tooltip: 'More options',
                style: IconButton.styleFrom(
                  minimumSize: const Size(48, 48),
                  padding: EdgeInsets.zero,
                ),
                icon: const Icon(
                  Icons.add_rounded,
                  color: LakbayColors.tealDeep,
                ),
                onSelected: (value) {
                  switch (value) {
                    case 'categories':
                      _showCategoriesSheet(context);
                    case 'new_chat':
                      widget.repo.startNewChat();
                    case 'budget':
                      widget.repo.setStrictBudgetFilter(
                        !widget.repo.strictBudgetFilter,
                      );
                    case 'origin':
                      showOriginPickerSheet(context, widget.repo);
                  }
                },
                itemBuilder: (_) => [
                  if (widget.repo.categoryFacets.isNotEmpty)
                    const PopupMenuItem(
                      value: 'categories',
                      child: Text('Browse categories'),
                    ),
                  const PopupMenuItem(
                    value: 'new_chat',
                    child: Text('New chat'),
                  ),
                  CheckedPopupMenuItem(
                    value: 'budget',
                    checked: widget.repo.strictBudgetFilter,
                    child: const Text('Within budget'),
                  ),
                  const PopupMenuItem(
                    value: 'origin',
                    child: Text('Set starting place'),
                  ),
                ],
              ),
              Expanded(
                child: TextField(
                  controller: _inputController,
                  onSubmitted: (_) => _handleSend(),
                  decoration: const InputDecoration(
                    hintText:
                        'Plan a trip or ask about a place',
                    hintStyle: TextStyle(
                      fontSize: 13.5,
                      color: LakbayColors.textMuted,
                    ),
                    border: InputBorder.none,
                    isDense: true,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Send',
                onPressed: _handleSend,
                style: IconButton.styleFrom(
                  backgroundColor: LakbayColors.primary,
                  foregroundColor: Colors.white,
                  // A round 44 dp button: roomy enough to tap, and it sits
                  // inside the composer instead of touching its edge.
                  fixedSize: const Size(44, 44),
                  shape: const CircleBorder(),
                ),
                icon: const Icon(Icons.arrow_upward_rounded, size: 20),
              ),
            ],
          ),
          ),
        ),
      ],
    );
  }

  /// The category chips, for the chat's + menu (they no longer sit above
  /// the composer while a reply is being read).
  void _showCategoriesSheet(BuildContext context) {
    final categories = widget.repo.categoryFacets;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Browse by category',
              style: TextStyle(
                fontFamily: 'FigGrotesk',
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: LakbayColors.tealDeep,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final cat in categories)
                  ActionChip(
                    label: Text(cat.label),
                    onPressed: () {
                      Navigator.of(sheetContext).pop();
                      widget.repo.browseCategoryInChat(cat);
                    },
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChatHistoryDrawer(BuildContext context) {
    final query = _drawerSearchController.text.trim().toLowerCase();
    final sessions = widget.repo.chatSessions.where((s) {
      if (query.isEmpty) return true;
      return s.title.toLowerCase().contains(query);
    }).toList();

    final today = sessions.where((s) => s.groupLabel == 'Today').toList();
    final yesterday =
        sessions.where((s) => s.groupLabel != 'Today').toList();

    return Drawer(
      backgroundColor: LakbayColors.canvasBg,
      width: MediaQuery.of(context).size.width * 0.80,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 12),
              child: LakbayBrandWordmark(fontSize: 24),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(color: LakbayColors.cardBorder),
                ),
                child: TextField(
                  controller: _drawerSearchController,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    icon: Icon(Icons.search_rounded,
                        color: LakbayColors.textSecondary),
                    hintText: 'Search chats',
                    border: InputBorder.none,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SizedBox(
                width: double.infinity,
                height: 48,
                child: FilledButton.icon(
                  key: const ValueKey('drawer-new-chat'),
                  onPressed: () {
                    widget.repo.startNewChat();
                    Navigator.of(context).pop();
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: LakbayColors.tealDeep,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(24),
                    ),
                  ),
                  icon: const Icon(Icons.add_rounded, size: 20),
                  label: const Text(
                    'New chat',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  if (today.isNotEmpty) ...[
                    const Padding(
                      padding: EdgeInsets.fromLTRB(10, 6, 10, 6),
                      child: Text(
                        'Today',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: LakbayColors.textSecondary,
                        ),
                      ),
                    ),
                    for (final s in today) _buildDrawerSessionTile(context, s),
                  ],
                  if (yesterday.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    const Padding(
                      padding: EdgeInsets.fromLTRB(10, 6, 10, 6),
                      child: Text(
                        'Yesterday',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: LakbayColors.textSecondary,
                        ),
                      ),
                    ),
                    for (final s in yesterday)
                      _buildDrawerSessionTile(context, s),
                  ],
                ],
              ),
            ),
            if (_lastDeleted != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Material(
                  color: LakbayColors.tealDeep,
                  borderRadius: BorderRadius.circular(14),
                  child: Padding(
                    padding: const EdgeInsets.only(left: 14),
                    child: Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Chat deleted',
                            style: TextStyle(color: Colors.white),
                          ),
                        ),
                        TextButton(
                          key: const ValueKey('undo-delete'),
                          onPressed: _undoDelete,
                          child: const Text(
                            'Undo',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            const Divider(height: 1, color: LakbayColors.cardBorder),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: InkWell(
                      key: const ValueKey('drawer-profile'),
                      borderRadius: BorderRadius.circular(16),
                      onTap: () {
                        Navigator.of(context).pop();
                        widget.repo.setActiveNavIndex(4);
                      },
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Row(
                          children: [
                            UserAvatar(
                              imageUrl: widget.repo.profile.avatarUrl,
                              initials: widget.repo.profile.initials,
                              size: 44,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    widget.repo.profile.fullName.isEmpty
                                        ? 'Your profile'
                                        : widget.repo.profile.fullName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                      fontSize: 14.5,
                                      color: LakbayColors.tealDeep,
                                    ),
                                  ),
                                  if (widget.repo.profile.username.isNotEmpty)
                                    Text(
                                      '@${widget.repo.profile.username}',
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
                      ),
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('drawer-clear-all'),
                    tooltip: 'Clear all chats',
                    onPressed: () => _confirmClearAllChats(context),
                    icon: const Icon(
                      Icons.delete_sweep_outlined,
                      color: LakbayColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // The last deleted chat, offered back inside the drawer (a snackbar would sit
  // under the drawer's dark overlay, where its Undo cannot be tapped).
  ({ChatSession session, int index})? _lastDeleted;
  Timer? _undoTimer;

  void _deleteChat(BuildContext context, ChatSession session) {
    final removed = widget.repo.deleteChatSession(session.id);
    if (removed == null) return;
    _undoTimer?.cancel();
    setState(() => _lastDeleted = removed);
    _undoTimer = Timer(const Duration(seconds: 6), () {
      if (mounted) setState(() => _lastDeleted = null);
    });
  }

  void _undoDelete() {
    final removed = _lastDeleted;
    if (removed == null) return;
    _undoTimer?.cancel();
    setState(() => _lastDeleted = null);
    widget.repo.restoreChatSession(removed.session, removed.index);
  }

  Future<void> _confirmClearAllChats(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear all chats?'),
        content: const Text(
          'This removes every chat from this phone. It cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const ValueKey('confirm-clear-all'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Clear all'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    widget.repo.clearChatHistory();
    if (context.mounted) Navigator.of(context).pop();
  }

  Widget _buildDrawerSessionTile(BuildContext context, ChatSession session) {
    final isSelected = session.id == widget.repo.activeChatId;
    return Dismissible(
      key: ValueKey('chat-tile-${session.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        decoration: BoxDecoration(
          color: Colors.red.shade600,
          borderRadius: BorderRadius.circular(14),
        ),
        child: const Icon(Icons.delete_outline_rounded, color: Colors.white),
      ),
      onDismissed: (_) => _deleteChat(context, session),
      child: _drawerTile(context, session, isSelected),
    );
  }

  Widget _drawerTile(
    BuildContext context,
    ChatSession session,
    bool isSelected,
  ) {
    return ListTile(
      selected: isSelected,
      selectedTileColor: LakbayColors.primaryLight.withValues(alpha: 0.45),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      leading: Icon(
        session.isTrip ? Icons.map_outlined : Icons.chat_bubble_outline_rounded,
        color: LakbayColors.tealDeep,
        size: 20,
      ),
      title: Text(
        session.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
          color: LakbayColors.tealDeep,
          fontSize: 14.5,
        ),
      ),
      onTap: () {
        widget.repo.selectChatSession(session.id);
        Navigator.of(context).pop();
      },
    );
  }

  Widget _buildMessageBubble(BuildContext context, ChatMessage msg) {
    if (msg.isUser) {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.only(bottom: 14, left: 48),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: const BoxDecoration(
            gradient: LakbayColors.brandGradient,
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(20),
              topRight: Radius.circular(20),
              bottomLeft: Radius.circular(20),
              bottomRight: Radius.circular(4),
            ),
          ),
          child: Text(
            msg.text,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14.5,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 16, right: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: LakbayAvatar(size: 34),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(15),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.94),
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(6),
                      topRight: Radius.circular(20),
                      bottomLeft: Radius.circular(20),
                      bottomRight: Radius.circular(20),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        msg.text.replaceAll('**', ''),
                        style: const TextStyle(
                          color: LakbayColors.textPrimary,
                          fontSize: 14,
                          height: 1.45,
                        ),
                      ),
                      if (msg.recommendedPlaces.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        _buildRecommendedPlacesPicker(
                          context,
                          msg.recommendedPlaces,
                        ),
                      ],
                      if (msg.timeline != null) ...[
                        const SizedBox(height: 12),
                        TimelineCard(
                          timeline: msg.timeline!,
                          repo: widget.repo,
                          trip: msg.attachedTrip,
                          onOpenTrip: msg.attachedTrip == null
                              ? null
                              : () => Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => TripDetailScreen(
                                      trip: msg.attachedTrip!,
                                      repo: widget.repo,
                                    ),
                                  ),
                                ),
                        ),
                      ] else if (msg.aiOptions.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        _buildAiOptionsPicker(context, msg.aiOptions),
                      ] else if (msg.attachedTrip != null) ...[
                        const SizedBox(height: 12),
                        _buildAttachedTripCard(context, msg.attachedTrip!),
                      ],
                      if (msg.isError) ...[
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          children: [
                            if (msg.errorCode == 'planning_over_budget') ...[
                              ActionChip(
                                avatar: const Icon(
                                  Icons.trending_up_rounded,
                                  size: 16,
                                ),
                                label: const Text('Raise budget'),
                                onPressed: () =>
                                    _showRaiseBudgetDialog(context),
                              ),
                              if (widget.repo.chatPickCount > 1)
                                ActionChip(
                                  avatar: const Icon(
                                    Icons.remove_circle_outline_rounded,
                                    size: 16,
                                  ),
                                  label: const Text('Remove a place'),
                                  onPressed: () =>
                                      _showRemovePickSheet(context),
                                ),
                            ],
                            if (msg.retryText != null)
                              ActionChip(
                                avatar: const Icon(
                                  Icons.refresh_rounded,
                                  size: 16,
                                ),
                                label: const Text('Try again'),
                                onPressed: () => _retryChatError(msg),
                              )
                            else if (widget.repo.canRetryUpdate(msg.id))
                              ActionChip(
                                avatar: const Icon(
                                  Icons.refresh_rounded,
                                  size: 16,
                                ),
                                label: const Text('Try again'),
                                onPressed: () =>
                                    widget.repo.retryUpdate(msg.id),
                              ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
          if ((msg.askNext != null || msg.offerPriorities) &&
              !widget.repo.isAiTyping &&
              widget.repo.chatMessages.isNotEmpty &&
              widget.repo.chatMessages.last.id == msg.id) ...[
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(left: 30),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: _buildAnswerChips(context, msg),
              ),
            ),
          ],
          if (msg.suggestedReplies.isNotEmpty) ...[
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(left: 30),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: msg.suggestedReplies
                    .map(
                      (reply) => ActionChip(
                        onPressed: () => _handleSend(reply),
                        backgroundColor: Colors.black.withValues(alpha: 0.45),
                        side: BorderSide(
                            color: Colors.white.withValues(alpha: 0.3)),
                        label: Text(
                          reply,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Horizontal row of live category chips that browse the catalog with no AI.
  Widget _buildBrowseCategoriesStrip(
    BuildContext context, {
    bool compact = false,
  }) {
    final categories = widget.repo.categoryFacets;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.symmetric(horizontal: compact ? 16 : 2),
          child: const Text(
            'Browse by category',
            style: TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.2,
            ),
          ),
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: 36,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(horizontal: compact ? 16 : 0),
            itemCount: categories.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              final cat = categories[index];
              return ActionChip(
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                backgroundColor: Colors.white.withValues(alpha: 0.92),
                side: const BorderSide(color: Color(0x330B3C49)),
                label: Text(
                  cat.label,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: LakbayColors.tealDeep,
                  ),
                ),
                onPressed: () => widget.repo.browseCategoryInChat(cat),
              );
            },
          ),
        ),
      ],
    );
  }

  /// The places picked so far, and the one action that plans from them.
  Widget _buildPlanWithPicksBar(BuildContext context) {
    final count = widget.repo.chatPickCount;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: LakbayColors.primary),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '$count of ${TravelRepository.maxChatPicks} places picked',
              style: const TextStyle(
                color: LakbayColors.tealDeep,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ),
          ElevatedButton(
            onPressed: widget.repo.planWithPicks,
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

  /// Answer buttons for the detail the AI asked about, under its latest reply.
  List<Widget> _buildAnswerChips(BuildContext context, ChatMessage msg) {
    final repo = widget.repo;
    final chips = <(String, VoidCallback)>[];
    switch (msg.askNext) {
      case 'activity_level':
        for (final (value, label) in const [
          ('easy', 'Easy'),
          ('moderate', 'Moderate'),
          ('challenging', 'Challenging'),
        ]) {
          chips.add((label, () => repo.answerChatDetail('activity_level', value, label)));
        }
      case 'prefers_quiet':
        chips.add(('Quiet places', () => repo.answerChatDetail('prefers_quiet', true, 'Quiet places')));
        chips.add(('Popular is fine', () => repo.answerChatDetail('prefers_quiet', false, 'Popular is fine')));
      case 'travel_start_date':
        final today = DateTime.now();
        for (var i = 0; i < 3; i++) {
          final month = DateTime(today.year, today.month + i);
          // This month starts today; later months start on the 1st.
          final start = i == 0 ? today : month;
          const names = [
            'January', 'February', 'March', 'April', 'May', 'June', 'July',
            'August', 'September', 'October', 'November', 'December',
          ];
          final label = i == 0 ? 'This month' : names[month.month - 1];
          final iso =
              '${start.year.toString().padLeft(4, '0')}-${start.month.toString().padLeft(2, '0')}-${start.day.toString().padLeft(2, '0')}';
          chips.add((label, () => repo.answerChatDetail('travel_start_date', iso, label)));
        }
    }
    if (msg.offerPriorities) {
      chips.add(('What matters most?', () => _askPriorities(context)));
    }
    return [
      for (final (label, onTap) in chips)
        ActionChip(
          onPressed: onTap,
          backgroundColor: LakbayColors.primary.withValues(alpha: 0.9),
          side: BorderSide.none,
          label: Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
    ];
  }

  static const _priorityLabels = {
    'scenery': 'Scenery',
    'short_travel': 'Short travel',
    'low_cost': 'Low cost',
    'easy_trail': 'Easy trail',
    'good_weather': 'Good weather',
    'quiet': 'Quiet',
  };

  /// Pick up to three priorities; the order you tap them is their rank.
  Future<void> _askPriorities(BuildContext context) async {
    final order = <String>[];
    final result = await showModalBottomSheet<List<String>>(
      context: context,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheet) => Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'What matters most?',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
              ),
              const SizedBox(height: 4),
              const Text(
                'Tap up to 3, most important first.',
                style: TextStyle(color: LakbayColors.textSecondary),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final entry in _priorityLabels.entries)
                    FilterChip(
                      selected: order.contains(entry.key),
                      label: Text(
                        order.contains(entry.key)
                            ? '${order.indexOf(entry.key) + 1}. ${entry.value}'
                            : entry.value,
                      ),
                      onSelected: (on) => setSheet(() {
                        if (!on) {
                          order.remove(entry.key);
                        } else if (order.length < 3) {
                          order.add(entry.key);
                        }
                      }),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(sheetContext).pop(const []),
                    child: const Text('Skip'),
                  ),
                  const Spacer(),
                  ElevatedButton(
                    onPressed: order.isEmpty
                        ? null
                        : () => Navigator.of(sheetContext).pop(List.of(order)),
                    child: const Text('Apply'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (result == null) return;
    final label = result.isEmpty
        ? 'Skip'
        : 'What matters most to me: ${result.map((k) => _priorityLabels[k]).join(', ')}';
    await widget.repo.answerChatPriorities(result, label);
  }

  Widget _buildRecommendedPlacesPicker(
    BuildContext context,
    List<TopPlaceRecommendation> places,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Recommended places',
          style: TextStyle(
            fontFamily: 'FigGrotesk',
            fontWeight: FontWeight.w700,
            fontSize: 13.5,
            color: LakbayColors.tealDeep,
          ),
        ),
        const SizedBox(height: 8),
        LayoutBuilder(
          builder: (context, constraints) {
            // About four fifths of the answer, so the next card peeks in.
            final cardWidth = (constraints.maxWidth * 0.82).clamp(210.0, 300.0);
            // Larger text needs a taller card, or the buttons would be cut.
            final textScale =
                MediaQuery.textScalerOf(context).scale(1.0).clamp(1.0, 2.0);
            return SizedBox(
              height: 256 + (textScale - 1.0) * 150,
              child: ListView.separated(
                key: const ValueKey('place-carousel'),
                scrollDirection: Axis.horizontal,
                itemCount: places.length,
                separatorBuilder: (_, _) => const SizedBox(width: 10),
                itemBuilder: (context, index) =>
                    _buildPlaceCard(context, places[index], cardWidth),
              ),
            );
          },
        ),
      ],
    );
  }

  /// The one line about cost: the server's own "Cost not listed" or price
  /// wording, never a number made up here.
  static String? _priceLine(List<String> reasons) {
    for (final reason in reasons) {
      final lower = reason.toLowerCase();
      if (lower.startsWith('cost') ||
          lower.contains('₱') ||
          lower.contains('budget') ||
          lower.contains('price')) {
        return reason.trim();
      }
    }
    return null;
  }

  Widget _buildPlaceCard(
    BuildContext context,
    TopPlaceRecommendation place,
    double width,
  ) {
    final resolved = widget.repo.resolveExploreTripForRecommendation(place);
    final isAdded = widget.repo.isInTripBuilder(resolved.id);
    // Set by the container each time the card is drawn; the View button uses
    // it so the card itself grows into the place screen.
    VoidCallback? openCard;
    final infoLine = [
      if (place.district != null && place.district!.trim().isNotEmpty)
        place.district!.trim(),
      if (place.travelMinutes != null) '~${place.travelMinutes} min',
    ].join(' • ');
    final price = _priceLine(place.reasons);
    final networkImg =
        (place.imageUrl != null && place.imageUrl!.startsWith('http'))
            ? place.imageUrl
            : (resolved.hasRemoteThumbnail ? resolved.thumbnailUrl : null);

    return OpenContainer<void>(
      key: ValueKey('place-open-${place.name}'),
      transitionType: ContainerTransitionType.fadeThrough,
      transitionDuration: LakbayMotion.of(context, LakbayMotion.container),
      tappable: false,
      closedElevation: 0,
      openElevation: 0,
      closedColor: Colors.transparent,
      middleColor: LakbayColors.canvasBg,
      closedShape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(16)),
      ),
      openBuilder: (context, _) => TripDetailScreen(
        trip: widget.repo.buildDetailedItineraryFromExplore(resolved),
        repo: widget.repo,
      ),
      closedBuilder: (context, openContainer) {
        openCard = openContainer;
        return Container(
      key: ValueKey('place-card-${place.name}'),
      width: width,
      decoration: BoxDecoration(
        color: LakbayColors.canvasBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isAdded ? LakbayColors.primary : LakbayColors.cardBorder,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 92,
            width: double.infinity,
            child: Stack(
              fit: StackFit.expand,
              children: [
                LakbayNetworkOrAssetImage(
                  networkUrl: networkImg,
                  assetPath: resolved.localAssetPath,
                ),
                if (place.category != null && place.category!.trim().isNotEmpty)
                  Positioned(
                    top: 8,
                    left: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: LakbayColors.tealDeep,
                        borderRadius: BorderRadius.circular(12),
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
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
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
                      fontSize: 15,
                      color: LakbayColors.tealDeep,
                    ),
                  ),
                  if (infoLine.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      infoLine,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: LakbayColors.textSecondary,
                      ),
                    ),
                  ],
                  if (price != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      price,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: place.matchTier > 1
                            ? const Color(0xFFB45309)
                            : LakbayColors.tealDeep,
                      ),
                    ),
                  ],
                  if (place.reasons.isNotEmpty)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        key: ValueKey('why-${place.name}'),
                        onPressed: () => _showWhyThisSheet(context, place),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          minimumSize: const Size(0, 28),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: const Text(
                          'Why this?',
                          style: TextStyle(fontSize: 12.5),
                        ),
                      ),
                    ),
                  const Spacer(),
                  Row(
                    children: [
                      OutlinedButton(
                        onPressed: () => openCard?.call(),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          minimumSize: const Size(0, 36),
                        ),
                        child: const Text(
                          'View',
                          style: TextStyle(fontSize: 12.5),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: () {
                            if (!widget.repo.toggleChatPick(resolved)) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    'You can pick up to ${TravelRepository.maxChatPicks} places for one plan.',
                                  ),
                                ),
                              );
                            }
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: isAdded
                                ? LakbayColors.primaryLight
                                : LakbayColors.primary,
                            foregroundColor: isAdded
                                ? LakbayColors.tealDeep
                                : Colors.white,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            minimumSize: const Size(0, 36),
                          ),
                          child: Text(
                            isAdded ? 'Added' : '+ Add',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12.5),
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
    );
  }

  /// All the reasons a place matched, in the server's words.
  void _showWhyThisSheet(BuildContext context, TopPlaceRecommendation place) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Why ${place.name}?',
              style: const TextStyle(
                fontFamily: 'FigGrotesk',
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: LakbayColors.tealDeep,
              ),
            ),
            const SizedBox(height: 10),
            for (final reason in place.reasons)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 2, right: 8),
                      child: Icon(
                        Icons.check_circle_outline_rounded,
                        size: 16,
                        color: LakbayColors.primary,
                      ),
                    ),
                    Expanded(child: Text(reason)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildAiOptionsPicker(
    BuildContext context,
    List<AiItineraryOptionDraft> options,
  ) {
    final isCatalogBuilt =
        options.any((o) => o.isCatalogFallback || o.trip.isCatalogFallback);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                isCatalogBuilt
                    ? "Built from Lakbay's catalog, without AI"
                    : 'Compare AI Itinerary Options',
                style: const TextStyle(
                  fontFamily: 'FigGrotesk',
                  fontWeight: FontWeight.w700,
                  fontSize: 13.5,
                  color: LakbayColors.tealDeep,
                ),
              ),
            ),
            if (isCatalogBuilt && options.isNotEmpty)
              ActionChip(
                visualDensity: VisualDensity.compact,
                avatar: const Icon(Icons.auto_awesome_rounded, size: 15),
                label: const Text(
                  'Improve with AI',
                  style: TextStyle(fontSize: 11.5),
                ),
                onPressed: () =>
                    widget.repo.improveCatalogTripWithAi(options.first.trip),
              ),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 238,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: options.length,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (context, index) {
              final opt = options[index];
              final trip = opt.trip;
              return Container(
                width: 245,
                decoration: BoxDecoration(
                  color: LakbayColors.canvasBg,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: index == 0
                        ? LakbayColors.primary
                        : LakbayColors.cardBorder,
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      height: 88,
                      width: double.infinity,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          LakbayNetworkOrAssetImage(
                            networkUrl: trip.remoteImageUrl,
                            assetPath: trip.heroAsset,
                          ),
                          Positioned(
                            top: 8,
                            left: 8,
                            right: 8,
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: opt.isOverBudget
                                      ? Colors.red.shade700
                                      : LakbayColors.tealDeep,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  'Option ${opt.optionNumber} • ${trip.vibeTag}',
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
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.all(10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              opt.title,
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
                              opt.summary,
                              maxLines: 2,
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
                                Expanded(
                                  child: Text(
                                    opt.estimatedTotalCostPhp > 0
                                        ? 'Est. ₱${opt.estimatedTotalCostPhp.toStringAsFixed(0)}'
                                        : (trip.hasCostEstimate
                                            ? 'Est. ${widget.repo.formatPrice(trip.totalEstimatedCostUsd)}'
                                            : 'Cost not listed'),
                                    style: TextStyle(
                                      fontFamily: 'FigGrotesk',
                                      fontWeight: FontWeight.w700,
                                      fontSize: 12.5,
                                      color: opt.isOverBudget
                                          ? Colors.red.shade700
                                          : LakbayColors.primary,
                                    ),
                                  ),
                                ),
                                OutlinedButton(
                                  onPressed: () {
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
                                    'Open',
                                    style: TextStyle(fontSize: 11.5),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                ElevatedButton(
                                  onPressed: () {
                                    widget.repo.saveTripToMyTrips(trip);
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(
                                          'Saved "${trip.title}" to My Trips!',
                                        ),
                                        backgroundColor: LakbayColors.tealDeep,
                                      ),
                                    );
                                  },
                                  style: ElevatedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 4,
                                    ),
                                    minimumSize: Size.zero,
                                  ),
                                  child: const Text(
                                    'Save',
                                    style: TextStyle(fontSize: 11.5),
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
        ),
      ],
    );
  }

  Widget _buildAttachedTripCard(BuildContext context, ItineraryTrip trip) {
    return InkWell(
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => TripDetailScreen(trip: trip, repo: widget.repo),
          ),
        );
      },
      borderRadius: BorderRadius.circular(16),
      child: Container(
        decoration: BoxDecoration(
          color: LakbayColors.canvasBg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: LakbayColors.cardBorder),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: 135,
              width: double.infinity,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  LakbayNetworkOrAssetImage(
                    networkUrl: trip.remoteImageUrl,
                    assetPath: trip.heroAsset,
                  ),
                  Positioned(
                    top: 10,
                    left: 10,
                    right: 10,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: LakbayColors.primary,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          DayLabels.badge(trip.daysCount, trip.vibeTag),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    trip.title,
                    style: const TextStyle(
                      fontFamily: 'FigGrotesk',
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                      color: LakbayColors.textPrimary,
                    ),
                  ),
                  if (trip.isCatalogFallback) ...[
                    const SizedBox(height: 4),
                    const Text(
                      "Built from Lakbay's catalog, without AI",
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: LakbayColors.tealDeep,
                      ),
                    ),
                  ],
                  const SizedBox(height: 4),
                  Text(
                    '${trip.hasCostEstimate ? 'Est. ${widget.repo.formatPrice(trip.totalEstimatedCostUsd)}' : 'Cost not listed'} • ${trip.hotels.isNotEmpty ? '${trip.hotels.first.name} & ' : ''}Daily Route',
                    style: const TextStyle(
                      fontSize: 12,
                      color: LakbayColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => TripDetailScreen(
                                    trip: trip, repo: widget.repo),
                              ),
                            );
                          },
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 10),
                          ),
                          icon: const Icon(Icons.map_rounded, size: 16),
                          label: const Text('Inspect Itinerary',
                              style: TextStyle(fontSize: 13)),
                        ),
                      ),
                      if (trip.isCatalogFallback) ...[
                        const SizedBox(width: 8),
                        OutlinedButton.icon(
                          onPressed: () =>
                              widget.repo.improveCatalogTripWithAi(trip),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 10,
                            ),
                          ),
                          icon: const Icon(Icons.auto_awesome_rounded, size: 15),
                          label: const Text(
                            'Improve with AI',
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                      ],
                      const SizedBox(width: 8),
                      IconButton.filledTonal(
                        tooltip: 'Save to My Trips',
                        onPressed: () {
                          widget.repo.saveTripToMyTrips(trip);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content:
                                  Text('Saved "${trip.title}" to My Trips!'),
                              backgroundColor: LakbayColors.tealDeep,
                            ),
                          );
                        },
                        icon: const Icon(Icons.bookmark_add_rounded,
                            color: LakbayColors.tealDeep),
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
  }
}

class _HeroChip extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _HeroChip({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.94),
      borderRadius: BorderRadius.circular(24),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
            child: Text(
              label,
              style: const TextStyle(
                color: LakbayColors.tealDeep,
                fontWeight: FontWeight.w700,
                fontSize: 13,
              ),
            ),
          ),
        ),
      );
  }
}
