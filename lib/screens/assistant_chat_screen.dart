import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/l10n.dart';
import '../models/host_ai_access.dart';
import '../services/assistant/assistant_conversation.dart';
import '../services/assistant/assistant_service.dart';
import '../services/assistant/assistant_types.dart';
import '../services/host_store.dart';
import '../widgets/assistant_transcript.dart';

/// The chat with the built-in assistant.
///
/// One conversation lives for as long as this screen does and is kept in
/// memory only; leaving the screen ends it (and stops anything it was
/// running), so a turn never carries on out of sight. Approval cards are not
/// drawn here: the app-wide approval host shows them over whatever screen is
/// on top, this one included.
class AssistantChatScreen extends StatefulWidget {
  const AssistantChatScreen({
    super.key,
    required this.service,
    this.hostStore,
    this.onOpenSettings,
    this.onOpenSharedHosts,
  });

  final AssistantService service;

  /// Read to tell whether any server has AI access yet; without it the hint
  /// is never shown.
  final HostStore? hostStore;

  /// Opens Settings, where the assistant is switched on and set up.
  final VoidCallback? onOpenSettings;

  /// Opens the list of servers and their AI access. The chat looks again at
  /// the servers when it returns.
  final Future<void> Function()? onOpenSharedHosts;

  @override
  State<AssistantChatScreen> createState() => _AssistantChatScreenState();
}

class _AssistantChatScreenState extends State<AssistantChatScreen> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final FocusNode _inputFocus = FocusNode();

  AssistantConversation? _conversation;
  StreamSubscription<AssistantConversationState>? _conversationWatch;
  StreamSubscription<void>? _serviceWatch;
  AssistantConversationState _state = const AssistantConversationState(
    [],
    isRunning: false,
  );

  /// Why a conversation could not be started, in the service's own words.
  String? _startProblem;
  bool _starting = false;
  bool _disposed = false;

  /// False until the servers were looked at, and while there is no store.
  bool _noSharedHosts = false;

  @override
  void initState() {
    super.initState();
    _serviceWatch = widget.service.changes.listen((_) {
      if (!mounted) return;
      setState(() {});
      unawaited(_ensureConversation());
    });
    unawaited(_ensureConversation());
    unawaited(_checkHosts());
  }

  bool get _usable => widget.service.isEnabled && widget.service.isConfigured;

  Future<void> _checkHosts() async {
    final hosts = await widget.hostStore?.all();
    if (hosts == null || !mounted) return;
    setState(() {
      _noSharedHosts = hosts.every((h) => h.aiAccess == HostAiAccess.off);
    });
  }

  Future<void> _ensureConversation() async {
    if (_conversation != null || _starting || _disposed || !_usable) return;
    _starting = true;
    try {
      final conversation = await widget.service.createConversation();
      if (_disposed) {
        conversation.dispose();
        return;
      }
      _attach(conversation);
    } on AssistantFailure catch (e) {
      if (mounted) setState(() => _startProblem = e.message);
    } catch (_) {
      if (mounted) {
        setState(() => _startProblem = context.l10n.assistantStartFailed);
      }
    } finally {
      _starting = false;
    }
  }

  void _attach(AssistantConversation conversation) {
    _conversation = conversation;
    _conversationWatch = conversation.changes.listen(_onState);
    setState(() {
      _startProblem = null;
      _state = conversation.state;
    });
  }

  void _onState(AssistantConversationState next) {
    if (!mounted) return;
    // Decided before the list grows: following the newest item only while
    // the user has not scrolled up to read something older.
    final follow = !_scroll.hasClients || _scroll.position.extentAfter < 80;
    setState(() => _state = next);
    if (follow) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients) return;
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });
    }
  }

  void _detach() {
    unawaited(_conversationWatch?.cancel());
    _conversationWatch = null;
    _conversation?.dispose();
    _conversation = null;
  }

  Future<void> _newChat() async {
    _detach();
    if (!mounted) return;
    setState(() {
      _state = const AssistantConversationState([], isRunning: false);
      _startProblem = null;
    });
    await _ensureConversation();
  }

  void _send() {
    final conversation = _conversation;
    final text = _input.text.trim();
    if (conversation == null || text.isEmpty || _state.isRunning) return;
    _input.clear();
    unawaited(conversation.send(text));
    // The turn is "running" from the first line of send(), but the change
    // arrives on the stream; show it now so Stop is there at once.
    setState(() => _state = conversation.state);
    _inputFocus.requestFocus();
  }

  Future<void> _openShared() async {
    await widget.onOpenSharedHosts?.call();
    if (mounted) await _checkHosts();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_serviceWatch?.cancel());
    unawaited(_conversationWatch?.cancel());
    _conversation?.dispose();
    _input.dispose();
    _scroll.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final canReset = _conversation != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.assistantChatTitle),
        actions: [
          IconButton(
            tooltip: l10n.assistantNewChat,
            icon: const Icon(Icons.add_comment_outlined),
            onPressed: canReset ? () => unawaited(_newChat()) : null,
          ),
        ],
      ),
      body: SafeArea(
        child: _usable ? _chat(context) : _unavailable(context),
      ),
    );
  }

  /// Off or not set up: the reason, and the way to fix it. No composer.
  Widget _unavailable(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final problem = !widget.service.isEnabled
        ? l10n.assistantOffMessage
        : (widget.service.configurationProblem ?? _startProblem ?? '');
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.smart_toy_outlined,
                size: 40,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 12),
              Text(
                problem,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge,
              ),
              if (widget.onOpenSettings != null) ...[
                const SizedBox(height: 16),
                FilledButton.icon(
                  icon: const Icon(Icons.settings_outlined),
                  label: Text(l10n.assistantOpenSettings),
                  onPressed: widget.onOpenSettings,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _chat(BuildContext context) {
    return Column(
      children: [
        if (_noSharedHosts) _noHostsHint(context),
        Expanded(
          child: _state.items.isEmpty
              ? _empty(context)
              : AssistantTranscriptView(
                  items: _state.items,
                  controller: _scroll,
                ),
        ),
        const Divider(height: 1),
        _composer(context),
      ],
    );
  }

  Widget _noHostsHint(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          children: [
            Text(
              l10n.assistantNoSharedHosts,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onTertiaryContainer,
              ),
            ),
            if (widget.onOpenSharedHosts != null)
              TextButton(
                onPressed: () => unawaited(_openShared()),
                child: Text(l10n.assistantOpenSharedHosts),
              ),
          ],
        ),
      ),
    );
  }

  Widget _empty(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.smart_toy_outlined,
                size: 40,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 12),
              Text(
                l10n.assistantEmptyTitle,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                l10n.assistantEmptyBody,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _composer(BuildContext context) {
    final l10n = context.l10n;
    final running = _state.isRunning;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: assistantChatMaxWidth),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: CallbackShortcuts(
                  bindings: {
                    const SingleActivator(
                      LogicalKeyboardKey.enter,
                      control: true,
                    ): _send,
                    const SingleActivator(LogicalKeyboardKey.enter, meta: true):
                        _send,
                  },
                  child: TextField(
                    controller: _input,
                    focusNode: _inputFocus,
                    minLines: 1,
                    maxLines: 5,
                    keyboardType: TextInputType.multiline,
                    textInputAction: TextInputAction.newline,
                    decoration: InputDecoration(
                      hintText: l10n.assistantComposerHint,
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              if (running)
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.error,
                    foregroundColor: Theme.of(context).colorScheme.onError,
                  ),
                  icon: const Icon(Icons.stop),
                  label: Text(l10n.assistantStop),
                  onPressed: () => _conversation?.stop(),
                )
              else
                FilledButton.icon(
                  icon: const Icon(Icons.send),
                  label: Text(l10n.assistantSend),
                  onPressed: _conversation == null ? null : _send,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
