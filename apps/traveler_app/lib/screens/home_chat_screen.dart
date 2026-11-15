import 'package:flutter/material.dart';
import '../services/voice_input_service.dart';
import '../models/travel_models.dart';
import '../services/travel_repository.dart';
import '../theme/lakbay_theme.dart';
import '../widgets/lakbay_image.dart';
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
                                      widget.repo.hasUserLocation
                                          ? 'Near ${widget.repo.effectiveOriginLabel} • ${backdrop.place}'
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
                hintText: 'e.g., 3-day Samal & Talikud family getaway',
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
                ActionChip(
                  label: const Text('Samal & Talikud 3d'),
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    _handleSend('Plan a 3-day Samal Island & Talikud reef trip');
                  },
                ),
                ActionChip(
                  label: const Text('Mati & Aliwagwag 4d'),
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    _handleSend(
                      'Plan a 4-day Mati Dahican surf & Aliwagwag Falls trip',
                    );
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
                        tooltip: 'Quick Davao Ideas',
                        visualDensity: VisualDensity.compact,
                        onPressed: () => _handleSend(
                          'Plan a 3-day Samal Island and Davao City trip',
                        ),
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
                label: 'A few days in ${backdrop.place}',
                onTap: () => _handleSend(
                  'Plan a 3-day trip to ${backdrop.place} in Davao Region',
                ),
              ),
              _HeroChip(
                label: 'Surprise me',
                onTap: () => _handleSend(
                  widget.repo.hasUserLocation
                      ? 'Surprise me with a fresh 4-day Davao Region route starting from ${widget.repo.effectiveOriginLabel}'
                      : 'Surprise me with a 4-day Davao Region adventure route',
                ),
              ),
            ],
          ),

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
                      if (msg.aiOptions.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        _buildAiOptionsPicker(context, msg.aiOptions),
                      ] else if (msg.attachedTrip != null) ...[
                        const SizedBox(height: 12),
                        _buildAttachedTripCard(context, msg.attachedTrip!),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
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
