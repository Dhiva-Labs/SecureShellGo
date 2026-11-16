import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/l10n.dart';
import '../models/host.dart';
import '../services/bridge/bridge_connections.dart';
import '../services/bridge_remote/remote_bridge_controller.dart';
import '../services/bridge_remote/remote_controller_token_store.dart';
import '../services/credential_store.dart';
import '../services/headless_dialer.dart';
import '../services/ssh_service.dart';
import '../theme.dart';
import '../widgets/bridge_approval_card.dart' show bridgeApprovalArmDelay;
import '../widgets/remote_approval_card.dart';
import 'bridge_audit_screen.dart' show bridgeDateTime;

/// What the Remote approvals screen needs from a session with the
/// computer's bridge: [RemoteBridgeController] without the SSH behind it, so
/// the screen can be driven by a fake in tests.
abstract interface class RemoteControlLink {
  RemoteBridgeState get state;
  Stream<RemoteBridgeState> get states;

  Future<RemoteActionResult> answer(String approvalId, ControlAnswer answer);
  Future<RemoteActionResult> stopGrant(String grantId);
  Future<RemoteActionResult> stopItem(ControlItemKind kind, String id);

  /// Ends the session and anything under it (the SSH connection).
  Future<void> close();
}

/// The real [RemoteControlLink]: a connected [RemoteBridgeController], and
/// what to hang up when it is closed.
class ControllerLink implements RemoteControlLink {
  ControllerLink(this._controller, {this.onClose});

  final RemoteBridgeController _controller;
  final void Function()? onClose;

  @override
  RemoteBridgeState get state => _controller.state;

  @override
  Stream<RemoteBridgeState> get states => _controller.states;

  @override
  Future<RemoteActionResult> answer(String approvalId, ControlAnswer answer) =>
      _controller.answer(approvalId, answer);

  @override
  Future<RemoteActionResult> stopGrant(String grantId) =>
      _controller.stopGrant(grantId);

  @override
  Future<RemoteActionResult> stopItem(ControlItemKind kind, String id) =>
      _controller.stopItem(kind, id);

  @override
  Future<void> close() async {
    try {
      await _controller.close();
    } finally {
      try {
        onClose?.call();
      } catch (_) {
        // Already closed.
      }
    }
  }
}

/// Why the phone could not even reach the computer's launcher: signing in to
/// the host failed. [needsPerson] is the kind that only a normal connection
/// from the host list can fix (a question at login, an unchecked host key, a
/// sealed credential store).
class RemoteConnectFailure implements Exception {
  const RemoteConnectFailure(this.message, {this.needsPerson = false});

  final String message;
  final bool needsPerson;

  @override
  String toString() => message;
}

/// Opens a connected session with [host]'s bridge using [token], or throws
/// [RemoteBridgeError] / [RemoteConnectFailure].
typedef RemoteLinkOpener =
    Future<RemoteControlLink> Function(Host host, String token);

/// The app's [RemoteLinkOpener]: signs in to the saved host the way the AI
/// Bridge does (what is saved, nobody to ask, no agent or X11 forwarding, a
/// new host key never trusted) and runs the control command over it, without
/// opening a terminal. The connection is closed with the session.
RemoteLinkOpener headlessRemoteLinkOpener({
  required BridgeCredentialLookup credentials,
  required BridgeDialer dialer,
}) =>
    (host, token) async {
      final SshCredentials? saved;
      try {
        saved = await credentials(host.id);
      } on CredentialsNeedPerson catch (e) {
        throw RemoteConnectFailure('$e', needsPerson: true);
      } catch (_) {
        throw const RemoteConnectFailure(
          'The saved sign-in for this host could not be read.',
          needsPerson: true,
        );
      }
      final problem = HeadlessDialer.signInProblem(host, saved);
      if (problem != null) {
        throw RemoteConnectFailure(problem, needsPerson: true);
      }
      final SessionTransport transport;
      try {
        transport = await dialer(
          BridgeConnections.withoutForwarding(host),
          saved ?? const SshCredentials(),
        );
      } on SignInNeedsPerson catch (e) {
        throw RemoteConnectFailure(e.reason, needsPerson: true);
      } on CredentialsNeedPerson catch (e) {
        throw RemoteConnectFailure('$e', needsPerson: true);
      } on SshConnectionException catch (e) {
        throw RemoteConnectFailure(e.message);
      } catch (_) {
        // Not the exception's text: it can carry the address.
        throw const RemoteConnectFailure('Could not connect to this host.');
      }
      void hangUp() {
        try {
          transport.close();
        } catch (_) {
          // Already gone.
        }
      }

      final controller = RemoteBridgeController(
        exec: remoteExecOver(transport),
        token: token,
      );
      try {
        await controller.connect();
      } catch (_) {
        hangUp();
        rethrow;
      }
      return ControllerLink(controller, onClose: hangUp);
    };

/// "AI approvals on this computer": the phone's remote control of the
/// computer's AI Bridge.
///
/// First use asks for the token paired on the computer and saves it
/// (secure storage, never shown again). After that the screen connects over
/// SSH without opening a terminal and shows what is waiting for a yes, what
/// assistants have open, the approvals in force and the recent activity.
/// Leaving the screen ends the session; nothing keeps running behind it.
class RemoteApprovalsScreen extends StatefulWidget {
  const RemoteApprovalsScreen({
    super.key,
    required this.host,
    required this.tokens,
    required this.open,
    this.clock = DateTime.now,
    this.armDelay = bridgeApprovalArmDelay,
  });

  final Host host;
  final RemoteControllerTokenStore tokens;
  final RemoteLinkOpener open;
  final DateTime Function() clock;
  final Duration armDelay;

  @override
  State<RemoteApprovalsScreen> createState() => _RemoteApprovalsScreenState();
}

class _RemoteApprovalsScreenState extends State<RemoteApprovalsScreen> {
  /// Null until the saved token (or its absence) has been read.
  bool? _hasToken;
  bool _connecting = false;
  Object? _error;
  RemoteControlLink? _link;
  StreamSubscription<RemoteBridgeState>? _watch;
  Timer? _ticker;
  RemoteBridgeState _state = RemoteBridgeState();

  /// Which connect attempt is current, so a slow one that finishes after the
  /// screen moved on hangs up instead of resurrecting a session.
  var _attempt = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  @override
  void dispose() {
    _attempt++;
    _ticker?.cancel();
    unawaited(_watch?.cancel());
    unawaited(_link?.close());
    super.dispose();
  }

  Future<void> _start() async {
    String? token;
    try {
      token = await widget.tokens.load(widget.host.id);
    } catch (_) {
      token = null;
    }
    if (!mounted) return;
    setState(() => _hasToken = token != null);
    if (token != null) unawaited(_connect(token));
  }

  Future<void> _connect(String token) async {
    final attempt = ++_attempt;
    _drop();
    if (!mounted) return;
    setState(() {
      _connecting = true;
      _error = null;
      _state = RemoteBridgeState();
    });
    final RemoteControlLink link;
    try {
      link = await widget.open(widget.host, token);
    } catch (e) {
      if (!mounted || attempt != _attempt) return;
      setState(() {
        _connecting = false;
        _error = e;
      });
      return;
    }
    if (!mounted || attempt != _attempt) {
      unawaited(link.close());
      return;
    }
    _link = link;
    _watch = link.states.listen(_onState);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    setState(() => _connecting = false);
    _onState(link.state);
  }

  void _onState(RemoteBridgeState state) {
    if (!mounted) return;
    setState(() => _state = state);
    if (state.phase == RemoteBridgePhase.closed && state.error != null) {
      _error = state.error;
      _drop();
    }
  }

  /// Lets go of the current session, if any.
  void _drop() {
    _ticker?.cancel();
    _ticker = null;
    final watch = _watch;
    final link = _link;
    _watch = null;
    _link = null;
    if (watch != null) unawaited(watch.cancel());
    if (link != null) unawaited(link.close());
  }

  Future<void> _reconnect() async {
    final token = await widget.tokens.load(widget.host.id);
    if (!mounted) return;
    if (token == null) {
      setState(() => _hasToken = false);
      return;
    }
    unawaited(_connect(token));
  }

  Future<void> _saveToken(String token) async {
    await widget.tokens.save(widget.host.id, token);
    if (!mounted) return;
    setState(() => _hasToken = true);
    unawaited(_connect(token.trim()));
  }

  Future<void> _removeToken() async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.remoteRemoveTokenTitle),
        content: Text(l10n.remoteRemoveTokenBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.remoteRemoveToken),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await widget.tokens.delete(widget.host.id);
    } catch (_) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.remoteRemoveTokenFailed)),
      );
      return;
    }
    _attempt++;
    _drop();
    if (!mounted) return;
    setState(() {
      _hasToken = false;
      _connecting = false;
      _error = null;
      _state = RemoteBridgeState();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final hasToken = _hasToken;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.remoteScreenTitle),
        actions: [
          if (hasToken == true)
            PopupMenuButton<String>(
              key: const ValueKey('remote-menu'),
              onSelected: (value) {
                if (value == 'remove') unawaited(_removeToken());
                if (value == 'reconnect') unawaited(_reconnect());
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'reconnect',
                  child: Text(l10n.remoteReconnect),
                ),
                PopupMenuItem(
                  value: 'remove',
                  child: Text(l10n.remoteRemoveToken),
                ),
              ],
            ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: hasToken == null
                ? const Center(child: CircularProgressIndicator())
                : hasToken == false
                ? RemoteControlSetup(
                    hostName: widget.host.displayName,
                    onSave: _saveToken,
                  )
                : _body(context),
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final l10n = context.l10n;
    if (_connecting) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(
                l10n.remoteConnecting(widget.host.displayName),
                key: const ValueKey('remote-connecting'),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }
    final error = _error;
    if (error != null) return _ErrorView(error: error, onRetry: _reconnect);
    if (_link == null) return const SizedBox.shrink();
    return _Live(
      state: _state,
      link: _link!,
      hostName: widget.host.displayName,
      clock: widget.clock,
      armDelay: widget.armDelay,
    );
  }
}

// ----------------------------------------------------------------- setup

/// First use: what this does, and a field for the token paired on the
/// computer. The token is saved and never shown again.
class RemoteControlSetup extends StatefulWidget {
  const RemoteControlSetup({
    super.key,
    required this.hostName,
    required this.onSave,
  });

  final String hostName;

  /// Saves the token. May throw; the field says so.
  final Future<void> Function(String token) onSave;

  @override
  State<RemoteControlSetup> createState() => _RemoteControlSetupState();
}

class _RemoteControlSetupState extends State<RemoteControlSetup> {
  final _token = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _token.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text != null && text.isNotEmpty && mounted) {
      setState(() => _token.text = text);
    }
  }

  Future<void> _save() async {
    final l10n = context.l10n;
    final text = _token.text.trim();
    if (text.isEmpty) {
      setState(() => _error = l10n.remoteSetupTokenEmpty);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onSave(text);
    } on ArgumentError {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = l10n.remoteSetupTokenInvalid;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = l10n.remoteSetupSaveFailed;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          l10n.remoteSetupIntro(widget.hostName),
          style: theme.textTheme.bodyLarge,
        ),
        const SizedBox(height: 12),
        Text(l10n.remoteSetupSteps),
        const SizedBox(height: 16),
        TextField(
          key: const ValueKey('remote-token-field'),
          controller: _token,
          enabled: !_busy,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(
            labelText: l10n.remoteSetupTokenLabel,
            prefixIcon: const Icon(Icons.key_outlined),
            suffixIcon: IconButton(
              tooltip: l10n.remoteSetupPaste,
              icon: const Icon(Icons.content_paste),
              onPressed: _busy ? null : () => unawaited(_paste()),
            ),
          ),
          onSubmitted: (_) {
            if (!_busy) unawaited(_save());
          },
        ),
        const SizedBox(height: 8),
        Text(
          l10n.remoteSetupStoredNote,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(
            _error!,
            key: const ValueKey('remote-setup-error'),
            style: TextStyle(color: theme.colorScheme.error),
          ),
        ],
        const SizedBox(height: 16),
        FilledButton(
          key: const ValueKey('remote-token-save'),
          onPressed: _busy ? null : () => unawaited(_save()),
          child: Text(l10n.remoteSetupSave),
        ),
      ],
    );
  }
}

// ------------------------------------------------------------------ error

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  /// The plain-language headline and the detail the other side gave.
  (String, String?) _text(BuildContext context) {
    final l10n = context.l10n;
    final e = error;
    if (e is RemoteBridgeError) {
      final headline = switch (e.kind) {
        RemoteBridgeErrorKind.notRunning => l10n.remoteErrorNotRunning,
        RemoteBridgeErrorKind.refused => l10n.remoteErrorRefused,
        RemoteBridgeErrorKind.launcherNotFound =>
          l10n.remoteErrorLauncherNotFound,
        RemoteBridgeErrorKind.tooManySessions =>
          l10n.remoteErrorTooManySessions,
        RemoteBridgeErrorKind.connectionLost => l10n.remoteErrorConnectionLost,
        RemoteBridgeErrorKind.protocol => l10n.remoteErrorProtocol,
        RemoteBridgeErrorKind.failed => l10n.remoteErrorFailed,
      };
      return (headline, e.message.isEmpty ? null : e.message);
    }
    if (e is RemoteConnectFailure) {
      return (
        e.needsPerson ? l10n.remoteErrorNeedsPerson : l10n.remoteErrorConnect,
        e.message.isEmpty ? null : e.message,
      );
    }
    return (l10n.remoteErrorFailed, null);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final (headline, detail) = _text(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          color: theme.colorScheme.errorContainer,
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.error_outline,
                  color: theme.colorScheme.onErrorContainer,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        headline,
                        key: const ValueKey('remote-error'),
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: theme.colorScheme.onErrorContainer,
                        ),
                      ),
                      if (detail != null) ...[
                        const SizedBox(height: 6),
                        Text(
                          detail,
                          key: const ValueKey('remote-error-detail'),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onErrorContainer,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: FilledButton.icon(
            key: const ValueKey('remote-reconnect'),
            icon: const Icon(Icons.refresh),
            label: Text(l10n.remoteReconnect),
            onPressed: onRetry,
          ),
        ),
      ],
    );
  }
}

// ------------------------------------------------------------------- live

class _Live extends StatefulWidget {
  const _Live({
    required this.state,
    required this.link,
    required this.hostName,
    required this.clock,
    required this.armDelay,
  });

  final RemoteBridgeState state;
  final RemoteControlLink link;
  final String hostName;
  final DateTime Function() clock;
  final Duration armDelay;

  @override
  State<_Live> createState() => _LiveState();
}

class _LiveState extends State<_Live> {
  /// Items and grants with a Stop on its way, so a second tap does nothing.
  final Set<String> _stopping = {};

  static const int _activityShown = 20;

  Future<void> _stop(String key, Future<RemoteActionResult> Function() run) async {
    if (!_stopping.add(key)) return;
    setState(() {});
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    RemoteActionResult result;
    try {
      result = await run();
    } catch (_) {
      result = const RemoteActionResult.failed(ControlErrorCode.failed, '');
    }
    if (!mounted) return;
    setState(() => _stopping.remove(key));
    if (!result.ok) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            (result.message ?? '').isEmpty
                ? l10n.remoteActionFailedNoDetail
                : l10n.remoteActionFailed(result.message!),
          ),
        ),
      );
    }
  }

  Widget _heading(BuildContext context, String text, {Key? key}) {
    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 8),
      child: Text(
        text,
        key: key,
        style: Theme.of(context).textTheme.titleMedium,
      ),
    );
  }

  Widget _muted(BuildContext context, String text, {Key? key}) {
    final theme = Theme.of(context);
    return Text(
      text,
      key: key,
      style: theme.textTheme.bodyMedium?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final state = widget.state;
    final now = widget.clock();
    final grants = [
      for (final g in state.grants)
        if (g.expiresAt.isAfter(now)) g,
    ];
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        Text(
          l10n.remoteStatusConnected(
            widget.hostName,
            state.controllerName.isEmpty ? '-' : state.controllerName,
          ),
          key: const ValueKey('remote-status'),
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 4),
        _muted(context, l10n.remoteHelp),
        if (state.locked) ...[
          const SizedBox(height: 12),
          Card(
            key: const ValueKey('remote-locked'),
            color: theme.colorScheme.errorContainer,
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.lock_outline,
                    color: theme.colorScheme.onErrorContainer,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      l10n.remoteLocked,
                      style: TextStyle(
                        color: theme.colorScheme.onErrorContainer,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
        _heading(
          context,
          l10n.remoteSectionWaiting,
          key: const ValueKey('remote-waiting-heading'),
        ),
        if (state.approvals.isEmpty)
          _muted(
            context,
            l10n.remoteNothingWaiting,
            key: const ValueKey('remote-nothing-waiting'),
          )
        else
          for (final a in state.approvals)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: RemoteApprovalCard(
                key: ValueKey('remote-card-${a.id}'),
                approval: a,
                timedMinutes: state.timedMinutes,
                clock: widget.clock,
                armDelay: widget.armDelay,
                onAnswer: (answer) => widget.link.answer(a.id, answer),
              ),
            ),
        if (state.items.isNotEmpty) ...[
          _heading(context, l10n.remoteSectionOpen),
          for (final item in state.items) _itemTile(context, item),
        ],
        if (grants.isNotEmpty) ...[
          _heading(context, l10n.remoteSectionGrants),
          for (final g in grants) _grantTile(context, g, now),
        ],
        _heading(context, l10n.remoteSectionActivity),
        if (state.activity.isEmpty)
          _muted(context, l10n.remoteNoActivity)
        else
          for (final e in state.activity.take(_activityShown))
            _activityTile(context, e),
      ],
    );
  }

  Widget _itemTile(BuildContext context, ControlItem item) {
    final l10n = context.l10n;
    final kind = switch (item.kind) {
      ControlItemKind.terminal => l10n.remoteItemTerminal,
      ControlItemKind.desktop => l10n.remoteItemDesktop,
      ControlItemKind.job => l10n.remoteItemJob,
    };
    final icon = switch (item.kind) {
      ControlItemKind.terminal => Icons.terminal,
      ControlItemKind.desktop => Icons.desktop_windows_outlined,
      ControlItemKind.job => Icons.play_circle_outline,
    };
    final key = 'item-${item.kind.name}-${item.id}';
    final label = item.label;
    return ListTile(
      key: ValueKey(key),
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon),
      title: Text(label == null || label.isEmpty ? kind : '$kind: $label'),
      subtitle: Text(
        l10n.remoteItemSubtitle(item.assistant, item.host, item.state),
      ),
      trailing: TextButton(
        key: ValueKey('stop-$key'),
        onPressed: _stopping.contains(key)
            ? null
            : () => unawaited(
                _stop(key, () => widget.link.stopItem(item.kind, item.id)),
              ),
        child: Text(l10n.remoteStop),
      ),
    );
  }

  Widget _grantTile(BuildContext context, ControlGrant g, DateTime now) {
    final l10n = context.l10n;
    final left = g.expiresAt.difference(now);
    final key = 'grant-${g.id}';
    return ListTile(
      key: ValueKey(key),
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.timer_outlined),
      title: Text(l10n.settingsBridgeGrantTitle(g.assistant, g.host)),
      subtitle: Text(
        left < const Duration(minutes: 1)
            ? l10n.settingsBridgeGrantLessThanMinute
            : l10n.settingsBridgeGrantLeft((left.inSeconds / 60).ceil()),
      ),
      trailing: TextButton(
        key: ValueKey('stop-$key'),
        onPressed: _stopping.contains(key)
            ? null
            : () => unawaited(_stop(key, () => widget.link.stopGrant(g.id))),
        child: Text(l10n.settingsBridgeGrantStop),
      ),
    );
  }

  Widget _activityTile(BuildContext context, ControlActivity e) {
    final l10n = context.l10n;
    final host = e.host;
    final via = e.via;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text(
        host == null ? e.tool : l10n.remoteActivityOnHost(e.tool, host),
        style: TextStyle(
          fontFamily: AppTheme.monoFontFamily,
          fontFamilyFallback: AppTheme.monoFontFamilyFallback,
          fontSize: 13,
        ),
      ),
      subtitle: Text(
        [
          e.assistant,
          e.outcome,
          if (via != null) l10n.remoteActivityVia(via),
          bridgeDateTime(context, e.ts),
        ].join(' · '),
      ),
    );
  }
}
