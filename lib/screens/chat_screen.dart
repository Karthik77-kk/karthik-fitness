import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import 'package:skeletonizer/skeletonizer.dart';
import '../providers/fitness_provider.dart';
import '../services/on_device_ai_service.dart';
import '../services/gemini_text_service.dart';
import '../services/chat_session_service.dart';
import '../services/food_api_service.dart';
import '../widgets/kit/kit.dart';
import '../widgets/markdown_text.dart';
import 'chat_sessions_screen.dart';

// ── Palette ───────────────────────────────────────────────────────────────────
const _kGreen  = Color(0xFF30D158);
const _kCard   = Color(0xFF1E1E22);
const _kSecond = Color(0xFF8E8E93);

// ── Entry point — opens sessions list ────────────────────────────────────────

void openChat(BuildContext context) {
  Navigator.push(context, sharedAxisRoute(const ChatSessionsScreen()));
}

// ── Chat screen ───────────────────────────────────────────────────────────────

class ChatScreen extends StatefulWidget {
  /// Pass an existing session to continue it, or null to start a new one.
  final ChatSession? session;
  const ChatScreen({super.key, this.session});
  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _messages   = <_ChatMessage>[];
  final _controller = TextEditingController();
  final _scroll     = ScrollController();
  bool  _thinking   = false;
  bool  _cancelled  = false;
  Timer? _scrollTimer;
  late  ChatSession _session;

  @override
  void initState() {
    super.initState();
    // Initialise or restore session
    if (widget.session != null) {
      _session = widget.session!;
      // Restore messages from persisted session, preserving original timestamps
      for (final m in _session.messages) {
        _messages.add(_ChatMessage(text: m.text, isUser: m.isUser, timestamp: m.timestamp));
      }
    } else {
      _session = ChatSession(
        id: const Uuid().v4(),
        title: 'New Chat',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        messages: [],
      );
    }
    // On open: if auto-load was off, model is installed but not in memory — load now.
    // If not installed at all, start download.
    // Guards in initForChat() and downloadAndLoad() prevent double-loading.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Cloud mode needs no local model — skip the download/load entirely.
      final cloud = context.read<FitnessProvider>().aiCoachMode ==
              AiCoachMode.cloud &&
          GeminiTextService.isConfigured;
      if (cloud) return;
      final ai = context.read<OnDeviceAiService>();
      if (ai.isInstalled &&
          !ai.isReady &&
          ai.state != AiModelState.loading &&
          ai.state != AiModelState.downloading) {
        ai.initForChat();
      } else if (!ai.isInstalled) {
        ai.downloadAndLoad();
      }
    });
  }

  @override
  void dispose() {
    _scrollTimer?.cancel();
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // ── Persist session ─────────────────────────────────────────────────────────

  Future<void> _persistSession() async {
    _session.updatedAt = DateTime.now();
    _session.messages
      ..clear()
      ..addAll(_messages.map((m) => ChatSessionMessage(
        text: m.text, isUser: m.isUser, timestamp: m.timestamp)));
    await ChatSessionService.saveSession(_session);
  }

  // ── Send ────────────────────────────────────────────────────────────────────

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _thinking) return;

    final ai       = context.read<OnDeviceAiService>();
    final provider = context.read<FitnessProvider>();
    final cloud = provider.aiCoachMode == AiCoachMode.cloud &&
        GeminiTextService.isConfigured;
    if (!cloud && !ai.isReady) return;

    // Auto-title session from first user message
    if (_session.messages.isEmpty) {
      _session.title = ChatSessionService.titleFromFirstMessage(text);
    }

    _cancelled = false;
    setState(() {
      _messages.add(_ChatMessage(text: text, isUser: true));
      _controller.clear();
      _thinking = true;
    });

    // Persist user message IMMEDIATELY — don't lose it if the app crashes
    // or if the user navigates away before the AI finishes responding.
    await _persistSession();
    _scrollBottom();

    // Placeholder bubble for streaming AI response
    final aiMsg = _ChatMessage(text: '', isUser: false);
    setState(() => _messages.add(aiMsg));

    await for (final token in ai.sendMessage(text, provider)) {
      if (!mounted || _cancelled) break;
      setState(() => aiMsg.text += token);
      _scrollBottom();
    }

    if (mounted) {
      // If user cancelled with an empty AI bubble, remove it cleanly
      if (_cancelled && aiMsg.text.isEmpty) {
        setState(() => _messages.removeLast());
      }
      setState(() { _thinking = false; _cancelled = false; });
      _persistSession(); // persist final (complete or partial) AI response
    }
  }

  /// Debounced scroll-to-bottom — fires at most once per 80ms.
  /// Scheduling one postFrameCallback per token (200+ callbacks for a long
  /// response) was causing jank; this throttles to ~12 scrolls per second max.
  void _scrollBottom() {
    _scrollTimer?.cancel();
    _scrollTimer = Timer(const Duration(milliseconds: 80), () {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
      );
    });
  }

  // ── Build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final ai = context.watch<OnDeviceAiService>();
    // Cloud mode shows the chat immediately — no local model required.
    final cloud =
        context.watch<FitnessProvider>().aiCoachMode == AiCoachMode.cloud &&
            GeminiTextService.isConfigured;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(
          _session.title == 'New Chat' ? 'Coach' : _session.title,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: _ModelChip(ai.state),
          ),
          // Stop button — shown only while AI is generating
          if (_thinking)
            IconButton(
              icon: const Icon(Icons.stop_circle_outlined,
                  color: Color(0xFFFF9F0A), size: 22),
              tooltip: 'Stop generation',
              onPressed: () => setState(() => _cancelled = true),
            ),
          if (ai.isReady && !_thinking)
            IconButton(
              icon: const Icon(Icons.refresh_rounded, size: 20),
              tooltip: 'New conversation',
              onPressed: () {
                ai.resetConversation();
                setState(() {
                  _messages.clear();
                  _session = ChatSession(
                    id: const Uuid().v4(),
                    title: 'New Chat',
                    createdAt: DateTime.now(),
                    updatedAt: DateTime.now(),
                    messages: [],
                  );
                });
              },
            ),
          if (!_thinking)
            IconButton(
              icon: const Icon(Icons.delete_outline_rounded, size: 20),
              tooltip: 'Delete this chat',
              onPressed: () async {
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (_) => AlertDialog(
                    backgroundColor: const Color(0xFF1E1E22),
                    title: const Text('Delete chat?'),
                    content: const Text(
                      'This conversation will be permanently removed.',
                      style: TextStyle(color: Color(0xFF8E8E93)),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Cancel',
                            style: TextStyle(color: Color(0xFF8E8E93))),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('Delete',
                            style: TextStyle(color: Color(0xFFFF453A))),
                      ),
                    ],
                  ),
                );
                if (confirm == true && mounted) {
                  await ChatSessionService.deleteSession(_session.id);
                  if (mounted) Navigator.pop(context);
                }
              },
            ),
        ],
      ),
      body: cloud
          ? _ChatView(
              messages:        _messages,
              thinking:        _thinking,
              scroll:          _scroll,
              controller:      _controller,
              onSend:          _send,
              showMemoryNote:  widget.session != null && _messages.isNotEmpty,
            )
          : switch (ai.state) {
              AiModelState.notInstalled => _SetupView(ai: ai),
              AiModelState.downloading  => _DownloadingView(progress: ai.dlProgress),
              AiModelState.loading      => _LoadingView(),
              AiModelState.error        => _ErrorView(errorMessage: ai.errorMessage, ai: ai),
              AiModelState.ready        => _ChatView(
                  messages:        _messages,
                  thinking:        _thinking,
                  scroll:          _scroll,
                  controller:      _controller,
                  onSend:          _send,
                  // Show memory indicator when we restored an existing session
                  showMemoryNote:  widget.session != null && _messages.isNotEmpty,
                ),
            },
    );
  }
}

// ── Setup (not installed) ─────────────────────────────────────────────────────

// _SetupView is shown only briefly — initState auto-triggers download immediately.
class _SetupView extends StatelessWidget {
  final OnDeviceAiService ai;
  const _SetupView({required this.ai});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 32),
      child: Column(children: [
        const Icon(Icons.auto_awesome_rounded, size: 52, color: _kGreen),
        const SizedBox(height: 16),
        const Text('On-Device Coach',
            style: TextStyle(color: Colors.white, fontSize: 20,
                fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        const Text(
          'Gemma 3 1B · ~600 MB · runs 100% offline\n'
          'Starting download automatically…',
          textAlign: TextAlign.center,
          style: TextStyle(color: _kSecond, fontSize: 13, height: 1.5),
        ),
        const SizedBox(height: 40),
        const CircularProgressIndicator(color: _kGreen, strokeWidth: 2),
        const SizedBox(height: 28),

        // Fallback manual button in case auto-download stalls
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: ai.downloadAndLoad,
            icon: const Icon(Icons.download_rounded),
            label: const Text('Download & Enable Chat'),
            style: FilledButton.styleFrom(
              backgroundColor: _kGreen,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
            ),
          ),
        ),
      ]),
    );
  }
}

// ── Downloading ───────────────────────────────────────────────────────────────

class _DownloadingView extends StatelessWidget {
  final double progress;
  const _DownloadingView({required this.progress});

  @override
  Widget build(BuildContext context) {
    final pct = (progress * 100).round();
    final mb  = (progress * 600).round(); // approx MB downloaded

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('⬇️', style: TextStyle(fontSize: 52)),
          const SizedBox(height: 20),
          const Text('Downloading Gemma 3 1B',
              style: TextStyle(color: Colors.white, fontSize: 17,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text('$mb MB / ~600 MB  ($pct%)',
              style: const TextStyle(color: _kSecond, fontSize: 13)),
          const SizedBox(height: 20),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 8,
              backgroundColor: _kCard,
              valueColor: const AlwaysStoppedAnimation(_kGreen),
            ),
          ),
          const SizedBox(height: 16),
          const Text('Keep the screen on · WiFi recommended',
              style: TextStyle(color: _kSecond, fontSize: 12)),
        ]),
      ),
    );
  }
}

// ── Loading ───────────────────────────────────────────────────────────────────

class _LoadingView extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Column(
        children: [
          // Shimmer chat bubbles read as "a conversation is loading" rather than
          // a bare spinner.
          Expanded(
            child: Skeletonizer(
              enabled: true,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                children: const [
                  _SkeletonBubble(isUser: false, width: 230),
                  SizedBox(height: 12),
                  _SkeletonBubble(isUser: true, width: 150),
                  SizedBox(height: 12),
                  _SkeletonBubble(isUser: false, width: 270),
                ],
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.only(bottom: 16, top: 4),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text('Loading model into GPU memory…',
                  style: TextStyle(color: _kSecond, fontSize: 13)),
              SizedBox(height: 4),
              Text('First load takes ~5 seconds',
                  style: TextStyle(color: _kSecond, fontSize: 11)),
            ]),
          ),
        ],
      );
}

class _SkeletonBubble extends StatelessWidget {
  final bool isUser;
  final double width;
  const _SkeletonBubble({required this.isUser, required this.width});

  @override
  Widget build(BuildContext context) => Row(
        mainAxisAlignment:
            isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          Container(
            width: width,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
                color: _kCard, borderRadius: BorderRadius.circular(14)),
            child: const Text(
              'Loading a line of the reply so the shape reads as a message',
              maxLines: 2,
              style: TextStyle(fontSize: 14, height: 1.4),
            ),
          ),
        ],
      );
}

// ── Error ─────────────────────────────────────────────────────────────────────

class _ErrorView extends StatelessWidget {
  final String errorMessage;
  final OnDeviceAiService ai;
  const _ErrorView({required this.errorMessage, required this.ai});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('⚠️', style: TextStyle(fontSize: 48)),
            const SizedBox(height: 16),
            const Text('Something went wrong',
                style: TextStyle(color: Colors.white, fontSize: 16,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _kCard,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text(errorMessage,
                  style: const TextStyle(
                      color: _kSecond, fontSize: 12, height: 1.5)),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: ai.downloadAndLoad,
              style: FilledButton.styleFrom(
                backgroundColor: _kGreen,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
              child: const Text('Retry'),
            ),
          ]),
        ),
      );
}

// ── Main chat view ────────────────────────────────────────────────────────────

class _ChatView extends StatelessWidget {
  final List<_ChatMessage> messages;
  final bool               thinking;
  final bool               showMemoryNote; // true when restored existing session
  final ScrollController   scroll;
  final TextEditingController controller;
  final VoidCallback       onSend;

  const _ChatView({
    required this.messages,
    required this.thinking,
    required this.scroll,
    required this.controller,
    required this.onSend,
    this.showMemoryNote = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      // Session memory indicator — shown when resuming an existing session
      // so the user understands the AI starts fresh, not resuming the prior context
      if (showMemoryNote)
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          color: const Color(0xFF1E1E22),
          child: const Text(
            '📝 History shown above. The coach starts fresh — it does not remember prior turns.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Color(0xFF8E8E93), fontSize: 11),
          ),
        ),

      // Message list
      Expanded(
        child: messages.isEmpty
            ? _WelcomePrompts(onTap: (q) {
                controller.text = q;
                onSend();
              })
            : ListView.builder(
                controller: scroll,
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                itemCount: messages.length + (thinking && messages.last.isUser ? 1 : 0),
                itemBuilder: (_, i) {
                  if (i == messages.length) return const _ThinkingBubble();
                  return _BubbleTile(msg: messages[i]);
                },
              ),
      ),

      // Input bar
      _InputBar(controller: controller, thinking: thinking, onSend: onSend),
    ]);
  }
}

// ── Welcome prompts (shown when chat is empty) ────────────────────────────────

class _WelcomePrompts extends StatelessWidget {
  final void Function(String) onTap;
  const _WelcomePrompts({required this.onTap});

  static const _prompts = [
    ('🏋️', 'Why am I not losing weight?'),
    ('🍽️', 'What should I eat for dinner tonight?'),
    ('💪', 'Am I on track to hit my goal?'),
    ('📊', 'What\'s my biggest weak spot right now?'),
    ('🚶', 'How many steps should I aim for today?'),
    ('🥩', 'How do I hit my protein goal on Indian food?'),
  ];

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
      children: [
        const Center(
            child: Icon(Icons.auto_awesome_rounded, size: 44, color: _kGreen)),
        const SizedBox(height: 10),
        const Text('Ask anything about your fitness data',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white, fontSize: 16,
                fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        const Text('Runs 100% on your phone — no internet needed',
            textAlign: TextAlign.center,
            style: TextStyle(color: _kSecond, fontSize: 12)),
        const SizedBox(height: 24),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _prompts
              .map((p) => GestureDetector(
                    onTap: () => onTap(p.$2),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 9),
                      decoration: BoxDecoration(
                        color: _kCard,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                            color: _kSecond.withValues(alpha: 0.2)),
                      ),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Text(p.$1,
                            style: const TextStyle(fontSize: 14)),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(p.$2,
                              style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12)),
                        ),
                      ]),
                    ),
                  ))
              .toList(),
        ),
      ],
    );
  }
}

// ── Chat bubble ───────────────────────────────────────────────────────────────

class _BubbleTile extends StatelessWidget {
  final _ChatMessage msg;
  const _BubbleTile({required this.msg});

  @override
  Widget build(BuildContext context) {
    final isUser  = msg.isUser;
    final isEmpty = msg.text.isEmpty;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment:
            isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          if (!isUser) ...[
            Container(
              width: 28, height: 28,
              decoration: BoxDecoration(
                color: _kGreen.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: const Center(
                child: Icon(Icons.auto_awesome, size: 15, color: _kGreen),
              ),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: isUser
                    ? _kGreen.withValues(alpha: 0.18)
                    : _kCard,
                borderRadius: BorderRadius.only(
                  topLeft:     Radius.circular(isUser ? 16 : 4),
                  topRight:    Radius.circular(isUser ? 4 : 16),
                  bottomLeft:  const Radius.circular(14),
                  bottomRight: const Radius.circular(14),
                ),
                border: Border.all(
                  color: isUser
                      ? _kGreen.withValues(alpha: 0.3)
                      : _kSecond.withValues(alpha: 0.15),
                ),
              ),
              child: isEmpty
                  ? const _TypingDots()
                  : isUser
                      ? Text(
                          msg.text,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 14, height: 1.55),
                        )
                      : MarkdownText(
                          msg.text,
                          baseStyle: const TextStyle(
                              color: Colors.white, fontSize: 14, height: 1.55),
                        ),
            ),
          ),
          if (isUser) const SizedBox(width: 36),
        ],
      ),
    );
  }
}

// ── Thinking bubble (shown while waiting for first token) ─────────────────────

class _ThinkingBubble extends StatelessWidget {
  const _ThinkingBubble();
  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.only(bottom: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _TypingDots(),
          ],
        ),
      );
}

class _TypingDots extends StatefulWidget {
  const _TypingDots();
  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double>   _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900))
      ..repeat();
    _anim = CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _anim,
        builder: (_, __) {
          return Row(mainAxisSize: MainAxisSize.min, children: [
            for (int i = 0; i < 3; i++) ...[
              if (i > 0) const SizedBox(width: 4),
              _Dot(opacity: _dotOpacity(i)),
            ],
          ]);
        },
      );

  double _dotOpacity(int i) {
    final v = (_anim.value * 3 - i).clamp(0.0, 1.0);
    return 0.3 + 0.7 * (v <= 0.5 ? v * 2 : (1 - v) * 2);
  }
}

class _Dot extends StatelessWidget {
  final double opacity;
  const _Dot({required this.opacity});
  @override
  Widget build(BuildContext context) => Opacity(
        opacity: opacity,
        child: Container(
          width: 7, height: 7,
          decoration: const BoxDecoration(
              color: _kSecond, shape: BoxShape.circle),
        ),
      );
}

// ── Input bar ─────────────────────────────────────────────────────────────────

class _InputBar extends StatelessWidget {
  final TextEditingController controller;
  final bool                  thinking;
  final VoidCallback          onSend;
  const _InputBar(
      {required this.controller, required this.thinking, required this.onSend});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.only(
        left: 12, right: 8, top: 10,
        bottom: MediaQuery.of(context).viewInsets.bottom + 12,
      ),
      decoration: BoxDecoration(
        color: _kCard,
        border: Border(top: BorderSide(color: _kSecond.withValues(alpha: 0.15))),
      ),
      child: Row(children: [
        Expanded(
          child: TextField(
            controller: controller,
            enabled:    !thinking,
            minLines:   1,
            maxLines:   4,
            textCapitalization: TextCapitalization.sentences,
            style: const TextStyle(color: Colors.white, fontSize: 14),
            decoration: InputDecoration(
              hintText:  thinking ? 'Thinking…' : 'Ask about your fitness data…',
              hintStyle: const TextStyle(color: _kSecond, fontSize: 14),
              border:     InputBorder.none,
              isDense:    true,
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: 4, vertical: 8),
            ),
            onSubmitted: (_) => onSend(),
          ),
        ),
        // Nutrition lookup button
        IconButton(
          icon: const Icon(Icons.restaurant_rounded, size: 18, color: Color(0xFF40C8E0)),
          tooltip: 'Look up nutrition',
          onPressed: thinking ? null : () => _showNutritionLookup(context, controller),
          style: IconButton.styleFrom(
            minimumSize: const Size(36, 36),
            foregroundColor: _kSecond,
          ),
        ),
        AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          child: thinking
              ? const Padding(
                  padding: EdgeInsets.all(10),
                  child: SizedBox(
                    width: 20, height: 20,
                    child: CircularProgressIndicator(
                        color: _kGreen, strokeWidth: 2),
                  ),
                )
              : IconButton(
                  onPressed: onSend,
                  icon: const Icon(Icons.arrow_upward_rounded),
                  style: IconButton.styleFrom(
                    backgroundColor: _kGreen,
                    foregroundColor: Colors.black,
                    minimumSize:     const Size(40, 40),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                ),
        ),
      ]),
    );
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

class _ChatMessage {
  String text;
  final bool isUser;
  final DateTime timestamp;
  _ChatMessage({required this.text, required this.isUser, DateTime? timestamp})
      : timestamp = timestamp ?? DateTime.now();
}


class _ModelChip extends StatelessWidget {
  final AiModelState state;
  const _ModelChip(this.state);

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (state) {
      AiModelState.ready       => ('Gemma 1B ●', _kGreen),
      AiModelState.downloading => ('Downloading', Colors.orange),
      AiModelState.loading     => ('Loading…', Colors.orange),
      AiModelState.error       => ('Error', const Color(0xFFFF453A)),
      AiModelState.notInstalled=> ('Not installed', _kSecond),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(label,
          style: TextStyle(color: color, fontSize: 10,
              fontWeight: FontWeight.w600)),
    );
  }
}

// ── Nutrition lookup ──────────────────────────────────────────────────────────

void _showNutritionLookup(
    BuildContext context, TextEditingController chatCtrl) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => GlassSheet(
      child: _NutritionLookupSheet(chatController: chatCtrl),
    ),
  );
}

class _NutritionLookupSheet extends StatefulWidget {
  final TextEditingController chatController;
  const _NutritionLookupSheet({required this.chatController});

  @override
  State<_NutritionLookupSheet> createState() => _NutritionLookupSheetState();
}

class _NutritionLookupSheetState extends State<_NutritionLookupSheet> {
  final _ctrl    = TextEditingController();
  List<FoodApiResult> _results  = [];
  bool                _loading  = false;
  String?             _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final q = _ctrl.text.trim();
    if (q.isEmpty) return;

    setState(() { _loading = true; _error = null; _results = []; });

    try {
      final r = await FoodApiService.search(q);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _results = r;
        if (r.isEmpty) _error = 'No results for "$q". Try a different term.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error   = 'No internet connection.';
      });
    }
  }

  void _inject(FoodApiResult item) {
    final text =
        '[Nutrition lookup: ${item.name} — '
        '${item.calories100g.round()} kcal, '
        '${item.protein100g.toStringAsFixed(1)}g protein, '
        '${item.carbs100g.toStringAsFixed(1)}g carbs per 100g] ';
    widget.chatController.text = text;
    widget.chatController.selection = TextSelection.fromPosition(
      TextPosition(offset: widget.chatController.text.length),
    );
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        minChildSize: 0.4,
        maxChildSize: 0.9,
        builder: (_, scrollCtrl) => Column(children: [
          // Handle
          Container(
            margin: const EdgeInsets.only(top: 10, bottom: 8),
            width: 40, height: 4,
            decoration: BoxDecoration(
              color: _kSecond.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Icon(Icons.restaurant_rounded, size: 18, color: _kGreen),
                SizedBox(width: 8),
                Text(
                  'Nutrition Lookup',
                  style: TextStyle(color: Colors.white, fontSize: 16,
                      fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 10),
            child: Text(
              'Search any food · tap a result to inject into your question',
              style: TextStyle(color: _kSecond, fontSize: 12),
            ),
          ),

          // Search bar
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _ctrl,
                  autofocus: true,
                  textInputAction: TextInputAction.search,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  decoration: InputDecoration(
                    hintText: 'e.g. chicken breast, Maggi noodles…',
                    hintStyle: const TextStyle(color: _kSecond, fontSize: 13),
                    filled: true,
                    fillColor: Colors.black.withValues(alpha: 0.4),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                  ),
                  onSubmitted: (_) => _search(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _loading ? null : _search,
                style: FilledButton.styleFrom(
                  backgroundColor: _kGreen,
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 14),
                ),
                child: _loading
                    ? const SizedBox(
                        width: 18, height: 18,
                        child: CircularProgressIndicator(
                            color: Colors.black, strokeWidth: 2))
                    : const Icon(Icons.search_rounded, size: 20),
              ),
            ]),
          ),

          // Results / states
          Expanded(
            child: _loading
                ? const Center(
                    child: CircularProgressIndicator(
                        color: _kGreen, strokeWidth: 2))
                : _error != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text('😕', style: TextStyle(fontSize: 32)),
                              const SizedBox(height: 12),
                              Text(_error!,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                      color: _kSecond, fontSize: 13,
                                      height: 1.5)),
                            ],
                          ),
                        ),
                      )
                    : _results.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.restaurant_rounded, size: 36, color: Color(0xFF40C8E0)),
                                const SizedBox(height: 10),
                                const Text(
                                    'Search for any food item above',
                                    style: TextStyle(
                                        color: _kSecond, fontSize: 13)),
                                const SizedBox(height: 6),
                                Text(
                                    'Results include calories, protein & carbs per 100g',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                        color: _kSecond.withValues(alpha: 0.6),
                                        fontSize: 11)),
                              ],
                            ),
                          )
                        : ListView.separated(
                            controller: scrollCtrl,
                            padding: const EdgeInsets.fromLTRB(12, 0, 12, 20),
                            itemCount: _results.length,
                            separatorBuilder: (_, __) =>
                                const Divider(color: Color(0xFF2C2C2E), height: 1),
                            itemBuilder: (_, i) {
                              final r = _results[i];
                              return ListTile(
                                contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 4),
                                title: Text(r.name,
                                    style: const TextStyle(
                                        color: Colors.white, fontSize: 13),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis),
                                subtitle: Text(
                                  '${r.calories100g.round()} kcal · '
                                  '${r.protein100g.toStringAsFixed(1)}g prot · '
                                  '${r.carbs100g.toStringAsFixed(1)}g carbs '
                                  '· ${r.fat100g.toStringAsFixed(1)}g fat per 100g',
                                  style: const TextStyle(
                                      color: _kSecond, fontSize: 11),
                                ),
                                trailing: FilledButton(
                                  onPressed: () => _inject(r),
                                  style: FilledButton.styleFrom(
                                    backgroundColor:
                                        _kGreen.withValues(alpha: 0.15),
                                    foregroundColor: _kGreen,
                                    shape: RoundedRectangleBorder(
                                        borderRadius:
                                            BorderRadius.circular(14)),
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 12, vertical: 6),
                                    minimumSize: Size.zero,
                                    tapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                  ),
                                  child: const Text('Inject',
                                      style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w700)),
                                ),
                              );
                            },
                          ),
          ),
        ]),
      ),
    );
  }
}
