import 'package:flutter/material.dart';
import '../services/chat_session_service.dart';
import '../services/on_device_ai_service.dart';
import '../widgets/app_empty_state.dart';
import '../widgets/kit/kit.dart';
import 'package:provider/provider.dart';
import 'chat_screen.dart';

// ── Palette ───────────────────────────────────────────────────────────────────
const _kGreen  = Color(0xFF30D158);
const _kCard   = Color(0xFF1E1E22);
const _kSecond = Color(0xFF8E8E93);
const _kBg     = Color(0xFF000000);

/// Root AI screen: shows list of past sessions + button to start a new one.
class ChatSessionsScreen extends StatefulWidget {
  const ChatSessionsScreen({super.key});
  @override
  State<ChatSessionsScreen> createState() => _ChatSessionsScreenState();
}

class _ChatSessionsScreenState extends State<ChatSessionsScreen> {
  List<ChatSession> _sessions = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final s = await ChatSessionService.loadSessions();
    if (mounted) setState(() { _sessions = s; _loading = false; });
  }

  Future<void> _openSession(ChatSession? session) async {
    await Navigator.push(context, sharedAxisRoute(ChatScreen(session: session)));
    _load(); // refresh after returning
  }

  /// Called by swipe-to-dismiss. Removes from UI immediately and shows an Undo
  /// SnackBar. Only writes to storage after the SnackBar times out (4s).
  void _deleteSession(ChatSession session) {
    // Remove from in-memory list right away for instant UI response
    setState(() => _sessions.removeWhere((s) => s.id == session.id));

    bool undone = false;

    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(
          content: Text('Chat "${session.title}" deleted'),
          duration: const Duration(seconds: 4),
          action: SnackBarAction(
            label: 'Undo',
            textColor: _kGreen,
            onPressed: () {
              undone = true;
              // Re-insert the session and re-sort by updatedAt
              setState(() {
                _sessions.add(session);
                _sessions.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
              });
            },
          ),
        ))
        .closed
        .then((_) {
          // SnackBar dismissed (timeout or tapped outside) — permanently delete
          // only if the user did NOT tap Undo
          if (!undone) {
            ChatSessionService.deleteSession(session.id);
          }
        });
  }

  @override
  Widget build(BuildContext context) {
    final ai = context.watch<OnDeviceAiService>();

    return Scaffold(
      backgroundColor: _kBg,
      appBar: AppBar(
        backgroundColor: _kBg,
        title: const Text('Coach',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18)),
        actions: [
          // Model status chip
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(child: _ModelChip(ai.state)),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: _kGreen, strokeWidth: 2))
          : CustomScrollView(
              slivers: [
                // New chat button
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: () => _openSession(null),
                        icon: const Icon(Icons.add_rounded),
                        label: const Text('New Chat',
                            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                        style: FilledButton.styleFrom(
                          backgroundColor: _kGreen,
                          foregroundColor: Colors.black,
                          minimumSize: const Size.fromHeight(52),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14)),
                        ),
                      ),
                    ),
                  ),
                ),

                // Model status card if not ready
                if (!ai.isReady)
                  SliverToBoxAdapter(
                    child: _AiStatusBanner(ai),
                  ),

                // Session list or empty state
                if (_sessions.isEmpty)
                  const SliverFillRemaining(
                    child: AppEmptyState(
                      icon: '💬',
                      title: 'No conversations yet',
                      subtitle: 'Tap "New Chat" to ask your fitness coach anything.',
                    ),
                  )
                else ...[
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                    sliver: SliverToBoxAdapter(
                      child: Text(
                        '${_sessions.length} conversation${_sessions.length == 1 ? '' : 's'}',
                        style: const TextStyle(color: _kSecond, fontSize: 12,
                            fontWeight: FontWeight.w500),
                      ),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                    sliver: SliverList(
                      delegate: SliverChildBuilderDelegate(
                        (ctx, i) => _SessionTile(
                          session: _sessions[i],
                          onTap:   () => _openSession(_sessions[i]),
                          onDelete: () => _deleteSession(_sessions[i]),
                        ),
                        childCount: _sessions.length,
                      ),
                    ),
                  ),
                ],
              ],
            ),
    );
  }
}

// ── Session tile ──────────────────────────────────────────────────────────────

class _SessionTile extends StatelessWidget {
  final ChatSession session;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  const _SessionTile({required this.session, required this.onTap, required this.onDelete});

  String _timeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1)  return 'just now';
    if (diff.inHours   < 1)  return '${diff.inMinutes}m ago';
    if (diff.inDays    < 1)  return '${diff.inHours}h ago';
    if (diff.inDays    < 7)  return '${diff.inDays}d ago';
    final mo = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${dt.day} ${mo[dt.month - 1]}';
  }

  @override
  Widget build(BuildContext context) {
    final lastMsg = session.messages.isNotEmpty ? session.messages.last : null;
    final preview = lastMsg != null
        ? (lastMsg.isUser ? 'You: ${lastMsg.text}' : lastMsg.text)
        : 'No messages yet';

    return Dismissible(
      key: Key(session.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        color: const Color(0xFFFF453A),
        child: const Icon(Icons.delete_rounded, color: Colors.white),
      ),
      onDismissed: (_) => onDelete(),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: _kCard,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(children: [
            const Text('💬', style: TextStyle(fontSize: 22)),
            const SizedBox(width: 12),
            Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Expanded(
                    child: Text(session.title,
                        style: const TextStyle(color: Colors.white, fontSize: 14,
                            fontWeight: FontWeight.w600),
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                  Text(_timeAgo(session.updatedAt),
                      style: const TextStyle(color: _kSecond, fontSize: 11)),
                ]),
                const SizedBox(height: 3),
                Text(preview,
                    style: const TextStyle(color: _kSecond, fontSize: 12),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Text('${session.messages.length} messages',
                    style: const TextStyle(color: Color(0xFF555558), fontSize: 11)),
              ],
            )),
            const SizedBox(width: 8),
            const Icon(Icons.chevron_right_rounded, color: _kSecond, size: 20),
          ]),
        ),
      ),
    );
  }
}

// ── Model status banner ───────────────────────────────────────────────────────

class _AiStatusBanner extends StatelessWidget {
  final OnDeviceAiService ai;
  const _AiStatusBanner(this.ai);

  @override
  Widget build(BuildContext context) {
    final isDownloading = ai.state == AiModelState.downloading;
    final isLoading     = ai.state == AiModelState.loading;
    final msg = isDownloading
        ? 'Downloading coach… ${(ai.dlProgress * 100).round()}% (${(ai.dlProgress * 600).round()} / ~600 MB)'
        : isLoading
          ? 'Loading coach into memory…'
          : ai.state == AiModelState.error
            ? 'Coach error: ${ai.errorMessage}'
            : 'Coach not installed — tap New Chat to download.';

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _kCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: ai.state == AiModelState.error
              ? const Color(0xFFFF453A).withValues(alpha: 0.4)
              : _kSecond.withValues(alpha: 0.2),
        ),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          if (isDownloading || isLoading)
            const SizedBox(width: 14, height: 14,
                child: CircularProgressIndicator(color: _kGreen, strokeWidth: 2)),
          if (!(isDownloading || isLoading))
            Icon(
              ai.state == AiModelState.error
                  ? Icons.error_outline_rounded
                  : Icons.info_outline_rounded,
              color: ai.state == AiModelState.error
                  ? const Color(0xFFFF453A)
                  : _kSecond,
              size: 16,
            ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(msg,
                style: TextStyle(
                    color: ai.state == AiModelState.error
                        ? const Color(0xFFFF453A) : _kSecond,
                    fontSize: 12)),
          ),
        ]),
        if (isDownloading) ...[
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: ai.dlProgress,
              minHeight: 4,
              backgroundColor: const Color(0xFF2C2C2E),
              valueColor: const AlwaysStoppedAnimation(_kGreen),
            ),
          ),
        ],
      ]),
    );
  }
}

// ── Model chip ────────────────────────────────────────────────────────────────

class _ModelChip extends StatelessWidget {
  final AiModelState state;
  const _ModelChip(this.state);

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (state) {
      AiModelState.ready        => ('● Ready',     const Color(0xFF30D158)),
      AiModelState.downloading  => ('↓ …',         Colors.orange),
      AiModelState.loading      => ('⟳ …',         Colors.orange),
      AiModelState.error        => ('✕ Error',      const Color(0xFFFF453A)),
      AiModelState.notInstalled => ('Not installed', const Color(0xFF8E8E93)),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(label,
          style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w600)),
    );
  }
}
