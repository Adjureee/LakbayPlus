import 'package:flutter/material.dart';

import '../services/voice_input_service.dart';
import '../models/travel_models.dart';
import '../services/travel_repository.dart';
import '../theme/lakbay_theme.dart';
import '../widgets/brand/lakbay_ai_avatar.dart';
import '../widgets/chat_plan_card.dart';
import '../widgets/lakbay_image.dart';
import '../widgets/origin_picker_sheet.dart';
import 'trip_detail_screen.dart';

import '../design/design.dart';

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

  @override
  void dispose() {
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
        final messages = widget.repo.chatMessages;
        final isLanding = messages.isEmpty && !widget.repo.isAiTyping;
        // Clear the floating tab bar, or sit right on the keyboard.
        final keyboard = MediaQuery.viewInsetsOf(context).bottom;
        final bottom = keyboard > 0
            ? LkSpace.s
            : MediaQuery.paddingOf(context).bottom + LkSpace.s;

        return Scaffold(
          key: _scaffoldKey,
          backgroundColor: LkColors.bg,
          drawer: _buildChatHistoryDrawer(context),
          body: SafeArea(
            bottom: false,
            child: Column(
              children: [
                _buildHeader(context),
                Expanded(
                  child: isLanding
                      ? _buildHeroLanding(context, widget.repo.currentBackdrop)
                      : _buildActiveChatThread(context, messages),
                ),
                if (!isLanding &&
                    widget.repo.chatPickCount > 0 &&
                    !widget.repo.isAiTyping)
                  _buildPlanWithPicksBar(context),
                if (!isLanding && _showQuickChips(messages)) _buildQuickChips(),
                _buildComposer(context, bottom: bottom),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(
        LkSpace.l,
        LkSpace.s,
        LkSpace.l,
        LkSpace.m,
      ),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: LkColors.stroke)),
      ),
      child: Row(
        children: [
          LkIconButton(
            icon: Icons.menu_rounded,
            tooltip: 'Chat History',
            onPressed: () => _scaffoldKey.currentState?.openDrawer(),
          ),
          const SizedBox(width: LkSpace.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  header: true,
                  child: Text('Lakbay AI', style: LkType.title),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: const BoxDecoration(
                        color: LkColors.lagoon,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: LkSpace.xs),
                    Flexible(
                      child: Text(
                        'Plans from real Region XI places',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: LkType.micro.copyWith(color: LkColors.lagoon),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          LkIconButton(
            icon: Icons.add_comment_outlined,
            tooltip: 'New chat',
            onPressed: widget.repo.startNewChat,
          ),
        ],
      ),
    );
  }

  Future<void> _startVoice(BuildContext context) async {
    if (_isListeningVoice) return;
    if (_voiceInput.isSupported) {
      setState(() => _isListeningVoice = true);
      final transcript = await _voiceInput.listenOnce();
      if (!mounted) return;
      setState(() => _isListeningVoice = false);
      if (transcript != null && transcript.isNotEmpty) {
        _handleSend(transcript);
        return;
      }
    }
    if (!context.mounted) return;
    _showVoicePromptFallbackSheet(context);
  }

  /// Follow-ups that only make sense once there is a plan on screen.
  bool _showQuickChips(List<ChatMessage> messages) {
    if (widget.repo.isAiTyping || messages.isEmpty) return false;
    final last = messages.last;
    return !last.isUser &&
        (last.aiOptions.isNotEmpty || last.attachedTrip != null);
  }

  Widget _buildQuickChips() {
    const chips = [
      ('Cheaper', Icons.savings_outlined, 'Make the plan cheaper.'),
      ('Food stop', Icons.restaurant_rounded, 'Add a local food stop.'),
      ('Kid-friendly', Icons.family_restroom_rounded, 'Make it kid-friendly.'),
    ];
    return SizedBox(
      height: kLkMinTarget,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: LkSpace.l),
        children: [
          for (final (label, icon, prompt) in chips)
            Padding(
              padding: const EdgeInsets.only(right: LkSpace.s),
              child: Center(
                child: ActionChip(
                  avatar: Icon(icon, size: 16, color: LkColors.lagoon),
                  label: Text(label),
                  onPressed: () => _handleSend(prompt),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildComposer(BuildContext context, {required double bottom}) {
    return Padding(
      padding: EdgeInsets.fromLTRB(LkSpace.l, LkSpace.s, LkSpace.l, bottom),
      child: Container(
        padding: const EdgeInsets.all(LkSpace.xxs),
        decoration: BoxDecoration(
          color: LkColors.s1,
          borderRadius: BorderRadius.circular(LkRadius.md),
          border: Border.all(color: LkColors.strokeStrong),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            LkIconButton(
              icon: Icons.add_rounded,
              tooltip: 'Trip options',
              style: LkIconButtonStyle.plain,
              onPressed: () => _showComposerOptions(context),
            ),
            Expanded(
              child: TextField(
                controller: _inputController,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _handleSend(),
                style: LkType.body,
                decoration: const InputDecoration(
                  hintText: 'Ask Lakbay AI',
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
            LkIconButton(
              icon: _isListeningVoice
                  ? Icons.graphic_eq_rounded
                  : Icons.mic_none_rounded,
              tooltip: _isListeningVoice ? 'Listening' : 'Speak your trip',
              style: LkIconButtonStyle.plain,
              color: _isListeningVoice ? LkColors.mango : null,
              onPressed: () => _startVoice(context),
            ),
            const SizedBox(width: LkSpace.xxs),
            Semantics(
              button: true,
              label: 'Send',
              excludeSemantics: true,
              child: Material(
                color: LkColors.mango,
                borderRadius: BorderRadius.circular(LkRadius.sm),
                child: InkWell(
                  borderRadius: BorderRadius.circular(LkRadius.sm),
                  onTap: _handleSend,
                  child: const SizedBox.square(
                    dimension: kLkMinTarget,
                    child: Icon(
                      Icons.arrow_upward_rounded,
                      color: LkColors.mangoInk,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showComposerOptions(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      builder: (ctx) => ListenableBuilder(
        listenable: widget.repo,
        builder: (ctx, _) => Padding(
          padding: const EdgeInsets.fromLTRB(0, LkSpace.xl, 0, LkSpace.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: LkSpace.gutter),
                child: Text('Trip options', style: LkType.h3),
              ),
              const SizedBox(height: LkSpace.s),
              ListTile(
                leading: const Icon(Icons.trip_origin_rounded),
                title: const Text('Starting place'),
                subtitle: Text(
                  widget.repo.hasOrigin
                      ? widget.repo.effectiveOriginLabel
                      : 'Not set. Search or drop a pin.',
                ),
                onTap: () {
                  Navigator.of(ctx).pop();
                  showOriginPickerSheet(context, widget.repo);
                },
              ),
              SwitchListTile(
                secondary: const Icon(Icons.savings_outlined),
                title: const Text('Keep within my budget'),
                subtitle: const Text('Only suggest places that fit it.'),
                value: widget.repo.strictBudgetFilter,
                onChanged: widget.repo.setStrictBudgetFilter,
              ),
              ListTile(
                leading: const Icon(Icons.add_comment_outlined),
                title: const Text('New chat'),
                onTap: () {
                  Navigator.of(ctx).pop();
                  widget.repo.startNewChat();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showVoicePromptFallbackSheet(BuildContext context) {
    final promptCtrl = TextEditingController();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: LkColors.s1,
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
                fontFamily: LkType.displayFamily,
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: LkColors.text,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Voice dictation is unavailable in this browser session. Type or pick a quick Davao prompt below:',
              style: TextStyle(fontSize: 13, color: LkColors.muted),
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
                backgroundColor: LkColors.mango,
                foregroundColor: LkColors.mangoInk,
              ),
              child: const Text('Plan my trip'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeroLanding(BuildContext context, BackdropItem backdrop) {
    final firstName = widget.repo.profile.firstName.trim();
    // Short and fixed, so build it all at once (the starting-place note
    // must exist even below the fold).
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        LkSpace.gutter,
        LkSpace.xxl,
        LkSpace.gutter,
        LkSpace.l,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Align(
            alignment: Alignment.centerLeft,
            child: LakbayAiAvatar(diameter: 44),
          ),
          const SizedBox(height: LkSpace.l),
          Text(
            firstName.isEmpty
                ? 'Where do you want to'
                : 'Hi $firstName, where do you want to',
            style: LkType.h1,
          ),
          Text(
            'wake up next?',
            style: LkType.h1.copyWith(color: LkColors.mango),
          ),
          const SizedBox(height: LkSpace.s),
          Text(
            'Tell Lakbay AI the vibe, your dates, budget and who’s coming. '
            'Plans use real Region XI places, ferries and local rates.',
            style: LkType.body.copyWith(color: LkColors.muted),
          ),
          const SizedBox(height: LkSpace.xl),
          LkPhotoCard(
            image: AssetImage(backdrop.localAssetPath),
            height: 156,
            borderRadius: LkRadius.lgAll,
            title: 'Things to do in ${backdrop.place}',
            subtitle: 'Ask Lakbay AI',
            titleStyle: LkType.section.copyWith(color: Colors.white),
            onTap: () =>
                _handleSend('Show me places to visit around ${backdrop.place}'),
            topRight: LkIconButton(
              icon: Icons.refresh_rounded,
              tooltip: 'Show another place',
              style: LkIconButtonStyle.glass,
              onPressed: widget.repo.nextBackdrop,
            ),
          ),
          const SizedBox(height: LkSpace.xl),
          Text(
            'Try asking',
            style: LkType.label.copyWith(color: LkColors.muted),
          ),
          const SizedBox(height: LkSpace.s),
          Wrap(
            spacing: LkSpace.s,
            runSpacing: LkSpace.s,
            children: [
              _HeroChip(
                icon: Icons.trip_origin_rounded,
                label: widget.repo.hasOrigin
                    ? 'Start: ${widget.repo.effectiveOriginLabel}'
                    : 'Set starting place (search or pin)',
                onTap: () => showOriginPickerSheet(context, widget.repo),
              ),
              _HeroChip(
                label: 'Weekend in Samal for 4 friends',
                onTap: () => _handleSend(
                  'Weekend in Samal for 4 friends, beach and waterfalls.',
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
          if (widget.repo.originRegionNote != null) ...[
            const SizedBox(height: LkSpace.m),
            LkWarningRow(
              title: 'Starting place',
              message: widget.repo.originRegionNote!,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildActiveChatThread(
    BuildContext context,
    List<ChatMessage> messages,
  ) {
    final typing = widget.repo.isAiTyping;
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(
        LkSpace.l,
        LkSpace.l,
        LkSpace.l,
        LkSpace.m,
      ),
      itemCount: messages.length + (typing ? 1 : 0),
      itemBuilder: (context, index) {
        if (typing && index == messages.length) return const _TypingRow();
        return _buildMessageBubble(context, messages[index]);
      },
    );
  }

  Widget _buildChatHistoryDrawer(BuildContext context) {
    final query = _drawerSearchController.text.trim().toLowerCase();
    final sessions = widget.repo.chatSessions.where((s) {
      if (query.isEmpty) return true;
      return s.title.toLowerCase().contains(query);
    }).toList();

    final today = sessions.where((s) => s.groupLabel == 'Today').toList();
    final yesterday = sessions.where((s) => s.groupLabel != 'Today').toList();

    return Drawer(
      backgroundColor: LkColors.bg,
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
                  color: LkColors.s1,
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(color: LkColors.stroke),
                ),
                child: TextField(
                  controller: _drawerSearchController,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    icon: Icon(Icons.search_rounded, color: LkColors.muted),
                    hintText: 'Search chats',
                    border: InputBorder.none,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
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
                          color: LkColors.muted,
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
                          color: LkColors.muted,
                        ),
                      ),
                    ),
                    for (final s in yesterday)
                      _buildDrawerSessionTile(context, s),
                  ],
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: () {
                      Navigator.of(context).pop();
                      widget.repo.setActiveNavIndex(4);
                    },
                    child: CircleAvatar(
                      radius: 22,
                      backgroundColor: LkColors.s2,
                      child: Text(
                        widget.repo.profile.initials,
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 13,
                          color: LkColors.lagoon,
                        ),
                      ),
                    ),
                  ),
                  const Spacer(),
                  ElevatedButton.icon(
                    onPressed: () {
                      widget.repo.startNewChat();
                      Navigator.of(context).pop();
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: LkColors.s3,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 13,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(28),
                      ),
                    ),
                    icon: const Icon(Icons.add_rounded, size: 20),
                    label: const Text(
                      'New Chat',
                      style: TextStyle(fontWeight: FontWeight.w700),
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

  Widget _buildDrawerSessionTile(BuildContext context, ChatSession session) {
    final isSelected = session.id == widget.repo.activeChatId;
    return ListTile(
      selected: isSelected,
      selectedTileColor: LkColors.s2.withValues(alpha: 0.45),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      leading: Icon(
        session.isTrip ? Icons.map_outlined : Icons.chat_bubble_outline_rounded,
        color: LkColors.text,
        size: 20,
      ),
      title: Text(
        session.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
          color: LkColors.text,
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
          margin: const EdgeInsets.only(bottom: LkSpace.l, left: 48),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: const BoxDecoration(
            color: LkColors.mango,
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(20),
              topRight: Radius.circular(20),
              bottomLeft: Radius.circular(20),
              bottomRight: Radius.circular(6),
            ),
          ),
          child: Text(
            msg.text,
            style: LkType.body.copyWith(
              color: LkColors.mangoInk,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );
    }

    final isLast =
        widget.repo.chatMessages.isNotEmpty &&
        widget.repo.chatMessages.last.id == msg.id;
    final body = msg.text.replaceAll('**', '');

    return Padding(
      padding: const EdgeInsets.only(bottom: LkSpace.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const LakbayAiAvatar(diameter: 24),
              const SizedBox(width: LkSpace.s),
              Text('Lakbay AI', style: LkType.label),
              Text(' · ${_timeLabel(msg.timestamp)}', style: LkType.caption),
            ],
          ),
          const SizedBox(height: LkSpace.s),
          if (msg.isError)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(LkSpace.m),
              decoration: BoxDecoration(
                color: LkColors.danger.withValues(alpha: 0.12),
                borderRadius: LkRadius.smAll,
                border: Border.all(
                  color: LkColors.danger.withValues(alpha: 0.4),
                ),
              ),
              child: Text(body, style: LkType.body),
            )
          else
            Text(body, style: LkType.bodyLarge),
          if (msg.recommendedPlaces.isNotEmpty) ...[
            const SizedBox(height: LkSpace.m),
            _buildRecommendedPlacesPicker(context, msg.recommendedPlaces),
          ],
          if (msg.aiOptions.isNotEmpty) ...[
            const SizedBox(height: LkSpace.m),
            _buildAiOptionsPicker(context, msg.aiOptions),
          ] else if (msg.attachedTrip != null) ...[
            const SizedBox(height: LkSpace.m),
            _buildAttachedTripCard(context, msg.attachedTrip!),
          ],
          if (msg.isError && msg.retryText != null) ...[
            const SizedBox(height: LkSpace.s),
            ActionChip(
              avatar: const Icon(Icons.refresh_rounded, size: 16),
              label: const Text('Try again'),
              onPressed: () => _handleSend(msg.retryText!),
            ),
          ],
          if ((msg.askNext != null || msg.offerPriorities) &&
              !widget.repo.isAiTyping &&
              isLast) ...[
            const SizedBox(height: LkSpace.s),
            Wrap(
              spacing: LkSpace.xs,
              runSpacing: LkSpace.xs,
              children: _buildAnswerChips(context, msg),
            ),
          ],
          if (msg.suggestedReplies.isNotEmpty) ...[
            const SizedBox(height: LkSpace.s),
            Wrap(
              spacing: LkSpace.xs,
              runSpacing: LkSpace.xs,
              children: [
                for (final reply in msg.suggestedReplies)
                  ActionChip(
                    label: Text(reply),
                    onPressed: () => _handleSend(reply),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  static String _timeLabel(DateTime t) {
    final age = DateTime.now().difference(t);
    if (age.inMinutes < 1) return 'just now';
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m ${t.hour < 12 ? 'AM' : 'PM'}';
  }

  /// The places picked so far, and the one action that plans from them.
  Widget _buildPlanWithPicksBar(BuildContext context) {
    final count = widget.repo.chatPickCount;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
      decoration: BoxDecoration(
        color: LkColors.s1,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: LkColors.lagoon),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '$count of ${TravelRepository.maxChatPicks} places picked',
              style: const TextStyle(
                color: LkColors.text,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ),
          ElevatedButton(
            onPressed: widget.repo.planWithPicks,
            style: ElevatedButton.styleFrom(
              backgroundColor: LkColors.mango,
              foregroundColor: LkColors.mangoInk,
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
          chips.add((
            label,
            () => repo.answerChatDetail('activity_level', value, label),
          ));
        }
      case 'prefers_quiet':
        chips.add((
          'Quiet places',
          () => repo.answerChatDetail('prefers_quiet', true, 'Quiet places'),
        ));
        chips.add((
          'Popular is fine',
          () =>
              repo.answerChatDetail('prefers_quiet', false, 'Popular is fine'),
        ));
      case 'travel_start_date':
        final today = DateTime.now();
        for (var i = 0; i < 3; i++) {
          final month = DateTime(today.year, today.month + i);
          // This month starts today; later months start on the 1st.
          final start = i == 0 ? today : month;
          const names = [
            'January',
            'February',
            'March',
            'April',
            'May',
            'June',
            'July',
            'August',
            'September',
            'October',
            'November',
            'December',
          ];
          final label = i == 0 ? 'This month' : names[month.month - 1];
          final iso =
              '${start.year.toString().padLeft(4, '0')}-${start.month.toString().padLeft(2, '0')}-${start.day.toString().padLeft(2, '0')}';
          chips.add((
            label,
            () => repo.answerChatDetail('travel_start_date', iso, label),
          ));
        }
    }
    if (msg.offerPriorities) {
      chips.add(('What matters most?', () => _askPriorities(context)));
    }
    return [
      for (final (label, onTap) in chips)
        ActionChip(
          onPressed: onTap,
          backgroundColor: LkColors.s3.withValues(alpha: 0.9),
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
                style: TextStyle(color: LkColors.muted),
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
          'Recommended Destinations',
          style: TextStyle(
            fontFamily: LkType.displayFamily,
            fontWeight: FontWeight.w700,
            fontSize: 13.5,
            color: LkColors.text,
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 262,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: places.length,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (context, index) {
              final place = places[index];
              final resolved = widget.repo.resolveExploreTripForRecommendation(
                place,
              );
              final isAdded = widget.repo.isInTripBuilder(resolved.id);
              final locationLine = [
                if (place.district != null && place.district!.trim().isNotEmpty)
                  place.district!.trim(),
                if (place.travelMinutes != null) '~${place.travelMinutes} min',
              ].join(' • ');
              // Why this place fits, in the server's words. A near match leads
              // with the limit it relaxes (for example "About ₱200 over budget").
              final subtitle = [
                if (locationLine.isNotEmpty) locationLine,
                ...place.reasons.take(3),
              ].join('\n');
              final networkImg =
                  (place.imageUrl != null && place.imageUrl!.startsWith('http'))
                  ? place.imageUrl
                  : (resolved.hasRemoteThumbnail
                        ? resolved.thumbnailUrl
                        : null);

              return Container(
                width: 230,
                decoration: BoxDecoration(
                  color: LkColors.bg,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: isAdded ? LkColors.lagoon : LkColors.stroke,
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      height: 86,
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
                                    color: LkColors.s3,
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
                              place.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontFamily: LkType.displayFamily,
                                fontWeight: FontWeight.w700,
                                fontSize: 13.5,
                                color: LkColors.text,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              subtitle,
                              maxLines: 5,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11.5,
                                color: place.matchTier > 1
                                    ? const Color(0xFFB45309)
                                    : LkColors.muted,
                                height: 1.3,
                              ),
                            ),
                            const Spacer(),
                            Row(
                              children: [
                                OutlinedButton(
                                  onPressed: () {
                                    final trip = widget.repo
                                        .buildDetailedItineraryFromExplore(
                                          resolved,
                                        );
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
                                Expanded(
                                  child: ElevatedButton(
                                    onPressed: () {
                                      if (!widget.repo.toggleChatPick(
                                        resolved,
                                      )) {
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
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
                                          ? LkColors.s2
                                          : LkColors.mango,
                                      foregroundColor: isAdded
                                          ? LkColors.mangoInk
                                          : LkColors.mangoInk,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 10,
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
        ),
      ],
    );
  }

  void _openTrip(ItineraryTrip trip) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TripDetailScreen(trip: trip, repo: widget.repo),
      ),
    );
  }

  void _saveTrip(ItineraryTrip trip) {
    widget.repo.saveTripToMyTrips(trip);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Saved "${trip.title}" to your trips')),
    );
  }

  Widget _buildAiOptionsPicker(
    BuildContext context,
    List<AiItineraryOptionDraft> options,
  ) {
    final split = widget.repo.chatBudgetSplit;
    ChatPlanCard card(AiItineraryOptionDraft opt, int i, double? width) =>
        ChatPlanCard(
          width: width,
          trip: opt.trip,
          title: opt.title,
          label: options.length > 1
              ? 'Option ${opt.optionNumber} · ${opt.trip.vibeTag}'
              : null,
          totalPhp: opt.estimatedTotalCostPhp > 0
              ? opt.estimatedTotalCostPhp
              : null,
          isOverBudget: opt.isOverBudget,
          budgetSplit: split,
          highlighted: options.length > 1 && i == 0,
          onSave: () => _saveTrip(opt.trip),
          onOpen: () => _openTrip(opt.trip),
        );

    if (options.length == 1) return card(options.first, 0, null);
    final width = (MediaQuery.sizeOf(context).width - 72).clamp(240.0, 340.0);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      clipBehavior: Clip.none,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < options.length; i++) ...[
            if (i > 0) const SizedBox(width: LkSpace.s),
            card(options[i], i, width),
          ],
        ],
      ),
    );
  }

  Widget _buildAttachedTripCard(BuildContext context, ItineraryTrip trip) {
    final phpRate = widget.repo.phpPerUsd;
    return ChatPlanCard(
      trip: trip,
      title: trip.title,
      totalPhp:
          trip.backendEstimatedCostPhp ??
          (trip.totalEstimatedCostUsd > 0
              ? trip.totalEstimatedCostUsd * phpRate
              : null),
      onSave: () => _saveTrip(trip),
      onOpen: () => _openTrip(trip),
    );
  }

  /// The message, plus Accept / Decline while an invitation is still open.
}

class _HeroChip extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback onTap;

  const _HeroChip({required this.label, required this.onTap, this.icon});

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      avatar: icon == null
          ? null
          : Icon(icon, size: 16, color: LkColors.lagoon),
      label: Text(label),
      onPressed: onTap,
    );
  }
}

/// "Lakbay AI is planning…" with skeleton lines, announced once.
class _TypingRow extends StatelessWidget {
  const _TypingRow();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: LkSpace.xl),
      child: Semantics(
        liveRegion: true,
        label: 'Lakbay AI is planning your trip',
        excludeSemantics: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const LakbayAiAvatar(diameter: 24),
                const SizedBox(width: LkSpace.s),
                Text('Lakbay AI', style: LkType.label),
                Text(' · planning your route…', style: LkType.caption),
              ],
            ),
            const SizedBox(height: LkSpace.m),
            const LkSkeleton(width: 260, height: 14),
            const SizedBox(height: LkSpace.s),
            const LkSkeleton(width: 200, height: 14),
            const SizedBox(height: LkSpace.m),
            const LkSkeleton(height: 120, borderRadius: LkRadius.mdAll),
          ],
        ),
      ),
    );
  }
}
