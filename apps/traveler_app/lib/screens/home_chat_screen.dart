import 'package:flutter/material.dart';
import '../services/voice_input_service.dart';
import '../models/travel_models.dart';
import '../services/travel_repository.dart';
import '../theme/lakbay_theme.dart';
import '../widgets/lakbay_image.dart';
import '../widgets/origin_picker_sheet.dart';
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
          SafeArea(
            child: Column(
              children: [
                // Top Bar: Hamburger Menu (Drawer) + Today's View Backdrop Pill
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Row(
                    children: [
                      Material(
                        color: Colors.white.withValues(alpha: 0.94),
                        shape: const CircleBorder(),
                        elevation: 2,
                        child: IconButton(
                          tooltip: 'Chat History',
                          onPressed: () =>
                              _scaffoldKey.currentState?.openDrawer(),
                          icon: const Icon(
                            Icons.menu_rounded,
                            color: LakbayColors.tealDeep,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Center(
                          child: InkWell(
                            onTap: widget.repo.nextBackdrop,
                            borderRadius: BorderRadius.circular(24),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.94),
                                borderRadius: BorderRadius.circular(24),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.12),
                                    blurRadius: 8,
                                  ),
                                ],
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Flexible(
                                    child: Text(
                                      widget.repo.hasOrigin
                                          ? 'Start: ${widget.repo.effectiveOriginLabel} • ${backdrop.place}'
                                          : "Today's view • ${backdrop.place}",
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: LakbayColors.tealDeep,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
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
                      Material(
                        color: Colors.white.withValues(alpha: 0.94),
                        shape: const CircleBorder(),
                        elevation: 2,
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            IconButton(
                              tooltip: 'Notifications',
                              onPressed: () => _openNotificationsSheet(context),
                              icon: const Icon(
                                Icons.notifications_none_rounded,
                                color: LakbayColors.tealDeep,
                              ),
                            ),
                            if (widget.repo.unreadNotificationCount > 0)
                              Positioned(
                                right: 6,
                                top: 6,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 5,
                                    vertical: 1,
                                  ),
                                  decoration: BoxDecoration(
                                    color: LakbayColors.primary,
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Text(
                                    '${widget.repo.unreadNotificationCount}',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

                // Main Content: Hero Landing (Image 6) or Active Chat Thread
                Expanded(
                  child: isLanding
                      ? _buildHeroLanding(context, backdrop)
                      : _buildActiveChatThread(context, messages),
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
          // Personalized Headline with Coral Highlight Pill
          Text(
            'Hi $firstName,\nwhere do you want to',
            style: const TextStyle(
              fontFamily: 'FigGrotesk',
              fontSize: 30,
              fontWeight: FontWeight.w800,
              color: Colors.white,
              height: 1.15,
              letterSpacing: -0.6,
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(
                  color: LakbayColors.primary,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: const Text(
                  'wake up',
                  style: TextStyle(
                    fontFamily: 'FigGrotesk',
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                    height: 1.1,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              const Text(
                'next?',
                style: TextStyle(
                  fontFamily: 'FigGrotesk',
                  fontSize: 30,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                  height: 1.15,
                ),
              ),
            ],
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
                    Material(
                      color: LakbayColors.canvasBg,
                      shape: const CircleBorder(),
                      child: IconButton(
                        tooltip: 'New chat',
                        visualDensity: VisualDensity.compact,
                        onPressed: widget.repo.startNewChat,
                        icon: const Icon(
                          Icons.add_rounded,
                          color: LakbayColors.tealDeep,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: FilterChip(
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          label: const Text(
                            'Within budget',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12),
                          ),
                          selected: widget.repo.strictBudgetFilter,
                          onSelected: (val) =>
                              widget.repo.setStrictBudgetFilter(val),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
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
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Plan it',
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
                label: widget.repo.hasOrigin
                    ? 'Start: ${widget.repo.effectiveOriginLabel}'
                    : 'Set starting place (search or pin)',
                onTap: () => showOriginPickerSheet(context, widget.repo),
              ),
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

          const SizedBox(height: 36),

          // Central Glowing Voice Mic Button ("Tap and tell Lakbay+")
          Center(
            child: Column(
              children: [
                GestureDetector(
                  onTap: () async {
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
                  },
                  child: Container(
                    width: 78,
                    height: 78,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LakbayColors.brandGradient,
                      boxShadow: [
                        BoxShadow(
                          color: (_isListeningVoice
                                  ? LakbayColors.tealAccent
                                  : LakbayColors.primary)
                              .withValues(alpha: _isListeningVoice ? 0.72 : 0.45),
                          blurRadius: _isListeningVoice ? 32 : 24,
                          spreadRadius: _isListeningVoice ? 8 : 4,
                        ),
                      ],
                    ),
                    child: Icon(
                      _isListeningVoice
                          ? Icons.graphic_eq_rounded
                          : Icons.mic_none_rounded,
                      color: Colors.white,
                      size: 34,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  _isListeningVoice
                      ? 'Listening… speak your Davao trip'
                      : 'Tap and tell Lakbay+',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
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
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: LakbayColors.primary,
                              ),
                            ),
                            SizedBox(width: 10),
                            Text(
                              'Lakbay+ AI is planning your Davao route...',
                              style: TextStyle(
                                color: LakbayColors.tealAccent,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              }
              return _buildMessageBubble(context, messages[index]);
            },
          ),
        ),
        if (widget.repo.chatPickCount > 0 && !widget.repo.isAiTyping)
          _buildPlanWithPicksBar(context),
        // Bottom Chat Input Bar (above floating nav bar)
        Container(
          margin: const EdgeInsets.fromLTRB(16, 4, 16, 98),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
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
              const LakbayAvatar(size: 32),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _inputController,
                  onSubmitted: (_) => _handleSend(),
                  decoration: const InputDecoration(
                    hintText:
                        'Ask Lakbay+ to plan a trip, find hotels, or routes...',
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
                onPressed: _handleSend,
                style: IconButton.styleFrom(
                  backgroundColor: LakbayColors.primary,
                  foregroundColor: Colors.white,
                ),
                icon: const Icon(Icons.arrow_upward_rounded, size: 20),
              ),
            ],
          ),
        ),
      ],
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
                      backgroundColor: LakbayColors.primaryLight,
                      child: Text(
                        widget.repo.profile.initials,
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 13,
                          color: LakbayColors.primaryDark,
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
                      backgroundColor: LakbayColors.tealDeep,
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
      padding: const EdgeInsets.only(bottom: 16, right: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const LakbayAvatar(size: 34),
              const SizedBox(width: 10),
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
                      if (msg.aiOptions.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        _buildAiOptionsPicker(context, msg.aiOptions),
                      ] else if (msg.attachedTrip != null) ...[
                        const SizedBox(height: 12),
                        _buildAttachedTripCard(context, msg.attachedTrip!),
                      ],
                      if (msg.isError && msg.retryText != null) ...[
                        const SizedBox(height: 10),
                        ActionChip(
                          avatar: const Icon(Icons.refresh_rounded, size: 16),
                          label: const Text('Try again'),
                          onPressed: () => _handleSend(msg.retryText!),
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
              padding: const EdgeInsets.only(left: 44),
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
              padding: const EdgeInsets.only(left: 44),
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
          'Recommended Destinations',
          style: TextStyle(
            fontFamily: 'FigGrotesk',
            fontWeight: FontWeight.w700,
            fontSize: 13.5,
            color: LakbayColors.tealDeep,
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
              final resolved =
                  widget.repo.resolveExploreTripForRecommendation(place);
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
              final networkImg = (place.imageUrl != null &&
                      place.imageUrl!.startsWith('http'))
                  ? place.imageUrl
                  : (resolved.hasRemoteThumbnail ? resolved.thumbnailUrl : null);

              return Container(
                width: 230,
                decoration: BoxDecoration(
                  color: LakbayColors.canvasBg,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: isAdded
                        ? LakbayColors.primary
                        : LakbayColors.cardBorder,
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
                                fontFamily: 'FigGrotesk',
                                fontWeight: FontWeight.w700,
                                fontSize: 13.5,
                                color: LakbayColors.tealDeep,
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
                                    : LakbayColors.textSecondary,
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
                                      if (!widget.repo
                                          .toggleChatPick(resolved)) {
                                        ScaffoldMessenger.of(context)
                                            .showSnackBar(
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

  Widget _buildAiOptionsPicker(
    BuildContext context,
    List<AiItineraryOptionDraft> options,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Compare AI Itinerary Options',
          style: TextStyle(
            fontFamily: 'FigGrotesk',
            fontWeight: FontWeight.w700,
            fontSize: 13.5,
            color: LakbayColors.tealDeep,
          ),
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
                                        : 'Est. ${widget.repo.formatPrice(trip.totalEstimatedCostUsd)}',
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
                          '${trip.daysCount} DAYS • ${trip.vibeTag.toUpperCase()}',
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
                  const SizedBox(height: 4),
                  Text(
                    'Est. ${widget.repo.formatPrice(trip.totalEstimatedCostUsd)} • ${trip.flights.isNotEmpty ? 'Flights, ' : ''}${trip.hotels.isNotEmpty ? '${trip.hotels.first.name} & ' : ''}Daily Route',
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

  void _openNotificationsSheet(BuildContext context) {
    widget.repo.refreshNotifications();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return ListenableBuilder(
          listenable: widget.repo,
          builder: (_, _) {
            final items = widget.repo.notifications;
            return DraggableScrollableSheet(
              expand: false,
              initialChildSize: 0.65,
              maxChildSize: 0.9,
              builder: (_, scrollCtrl) => ListView(
                controller: scrollCtrl,
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Notifications',
                          style: TextStyle(
                            fontFamily: 'FigGrotesk',
                            fontSize: 21,
                            fontWeight: FontWeight.w800,
                            color: LakbayColors.tealDeep,
                          ),
                        ),
                      ),
                      if (widget.repo.unreadNotificationCount > 0)
                        TextButton(
                          onPressed: widget.repo.markAllNotificationsRead,
                          child: const Text('Mark all read'),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (items.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 28),
                      child: Center(
                        child: Text(
                          widget.repo.isSignedIn
                              ? 'No notifications yet. Group updates and 80% budget alerts appear here.'
                              : 'Sign in to receive group invites, task updates, and 80% budget alerts.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey.shade600),
                        ),
                      ),
                    )
                  else
                    for (final n in items)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: CircleAvatar(
                          backgroundColor: n.isRead
                              ? Colors.grey.shade200
                              : LakbayColors.primary.withValues(alpha: 0.16),
                          child: Icon(
                            n.eventType == 'trip_updated'
                                ? Icons.warning_amber_rounded
                                : Icons.notifications_active_outlined,
                            color: n.isRead
                                ? Colors.grey.shade600
                                : LakbayColors.primary,
                            size: 20,
                          ),
                        ),
                        title: Text(
                          n.title,
                          style: TextStyle(
                            fontWeight:
                                n.isRead ? FontWeight.w500 : FontWeight.w700,
                          ),
                        ),
                        subtitle: Text(n.message),
                        trailing: n.isRead
                            ? null
                            : const Icon(
                                Icons.circle,
                                size: 9,
                                color: LakbayColors.primary,
                              ),
                        onTap: () =>
                            widget.repo.markNotificationRead(n.notificationId),
                      ),
                ],
              ),
            );
          },
        );
      },
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
