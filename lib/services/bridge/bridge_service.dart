import 'dart:async';
import 'dart:io';

import '../../models/app_settings.dart';
import '../../models/host.dart';
import '../settings_store.dart';
import 'bridge_approvals.dart';
import 'bridge_channel.dart';
import 'bridge_client_store.dart';
import 'bridge_connections.dart';
import 'bridge_grants.dart';
import 'bridge_policy.dart';
import 'bridge_terminals.dart';
import 'bridge_tool_module.dart';
import 'bridge_tools.dart';
import 'mcp_server.dart';

/// Where the AI Bridge stands, for the settings screen.
sealed class BridgeStatus {
  const BridgeStatus();

  static const BridgeStatus off = BridgeOff();
  static const BridgeStatus running = BridgeRunning();
  static const BridgeStatus runningElsewhere = BridgeRunningElsewhere();
}

/// Switched off, or not started yet.
final class BridgeOff extends BridgeStatus {
  const BridgeOff();

  @override
  String toString() => 'BridgeStatus.off';
}

/// Listening for assistants.
final class BridgeRunning extends BridgeStatus {
  const BridgeRunning();

  @override
  String toString() => 'BridgeStatus.running';
}

/// Another window of the app already holds the endpoint. Not an error: the
/// bridge works, through that window.
final class BridgeRunningElsewhere extends BridgeStatus {
  const BridgeRunningElsewhere();

  @override
  String toString() => 'BridgeStatus.runningElsewhere';
}

/// Switched on, but the listener could not start.
final class BridgeError extends BridgeStatus {
  const BridgeError(this.message);

  final String message;

  @override
  bool operator ==(Object other) =>
      other is BridgeError && other.message == message;

  @override
  int get hashCode => message.hashCode;

  @override
  String toString() => 'BridgeStatus.error($message)';
}

/// The AI Bridge as the rest of the app sees it: built once in `main.dart`,
/// on every platform, and started with the app.
///
/// Two halves with two names:
///
/// - **AI tools** (everywhere, Android included): the tool host
///   ([tools]), its approvals, grants and activity log, and the reactions
///   that keep them honest (a lock withdraws every card and ends every
///   grant and assistant terminal; a host stepped down, deleted or
///   re-pointed loses its grants, cards and terminals; a revoked client
///   loses everything it held). The built-in assistant
///   (`BridgeClient.builtin`) calls [tools] directly; nothing here needs
///   the local channel for that.
/// - **The local channel** ([localChannel], Linux and Windows only, see
///   [channelSupported]): the listener paired assistants connect to
///   through the launcher, one [McpServer] per connection, driven by
///   `AppSettings.bridgeEnabled`. Pairing, the launcher locator and the CLI
///   connector belong to this half and are not built elsewhere.
///
/// Every call is refused by policy while the app is locked (the tools read
/// the lock state per call). Switching the channel bridge off closes every
/// channel connection and ends what channel clients hold; the built-in
/// assistant's calls, cards, grants and terminals are its own switch's
/// business (`BridgeTools.builtinAssistantEnabled`).
class BridgeService {
  BridgeService({
    required this.settingsStore,
    required this.clients,
    required this.tools,
    required this.connections,
    required this.createListener,
    this.appLockChanges,
    this.hostChanges,
    this.terminals,
    bool? localChannel,
  }) : localChannel = localChannel ?? channelSupported;

  /// Whether this platform has the local channel and the launcher: only
  /// the desktop builds that ship `secureshellgo-mcp`. The AI tools
  /// themselves are available on every platform.
  static bool get channelSupported => Platform.isLinux || Platform.isWindows;

  /// Whether this service runs the local channel. [channelSupported] unless
  /// a test says otherwise; when false, [start] never opens a listener and
  /// [status] stays [BridgeStatus.off], whatever the setting says.
  final bool localChannel;

  final SettingsStore settingsStore;
  final BridgeClientStore clients;
  final BridgeTools tools;
  final BridgeConnections connections;

  /// Builds the listener on each start, given the token check. Async so the
  /// app's data directory can be resolved on first use rather than at
  /// construction.
  final Future<BridgeListener> Function(
    Future<BridgeClient?> Function(String token) verify,
  )
  createListener;

  /// True each time the app locks, false when it unlocks. On a lock every
  /// pending approval is withdrawn and every time-limited approval is gone:
  /// a locked app refuses, it does not queue.
  final Stream<bool>? appLockChanges;

  /// The questions waiting for the user, for the approval card.
  BridgeApprovals get approvals => tools.approvals;

  /// Time-limited approvals, for the list in Settings.
  BridgeGrants get grants => tools.grants;

  /// Every saved host after each change (`HostStore.changes`). A host that
  /// is gone, no longer lets the assistant request changes, or now points
  /// at another server loses its time-limited approvals and its waiting
  /// cards at once, without waiting for the next call.
  final Stream<List<Host>>? hostChanges;

  /// The assistants' terminals, for the session banner and the settings
  /// list ([BridgeTerminals.current], [BridgeTerminals.changes],
  /// [BridgeTerminals.takeOver], [BridgeTerminals.stop]). Those an
  /// assistant drives are closed when the bridge is switched off, the app
  /// locks, their client is revoked, their host changes, and at dispose.
  final BridgeTerminals? terminals;

  StreamSubscription<bool>? _lockWatch;
  StreamSubscription<List<Host>>? _hostsWatch;
  int? _timedMinutes;

  /// The hosts as last seen, by id, to tell a changed server from an
  /// unrelated edit. Null until the first list arrives.
  Map<String, Host>? _lastHosts;

  BridgeListener? _listener;
  StreamSubscription<BridgeConnection>? _accepting;
  StreamSubscription<AppSettings>? _settingsWatch;
  StreamSubscription<List<BridgeClient>>? _clientsWatch;
  final Set<_GuardedConnection> _open = {};

  /// Transitions run one at a time, in order: a quick off-on-off must end
  /// off, not with a start that finished last.
  Future<void> _chain = Future<void>.value();
  bool _disposed = false;

  BridgeStatus _status = BridgeStatus.off;
  final _statusChanges = StreamController<BridgeStatus>.broadcast();
  final _clientChanges = StreamController<List<BridgeClient>>.broadcast();

  BridgeStatus get status => _status;

  /// Every status change, starting from the next one; read [status] first.
  Stream<BridgeStatus> get statusChanges => _statusChanges.stream;

  /// The paired assistants connected right now, one entry per connection.
  List<BridgeClient> get connectedClients => [for (final c in _open) c.client];

  Stream<List<BridgeClient>> get connectedClientsChanges =>
      _clientChanges.stream;

  /// Follows the settings from here on, starting from what is saved.
  Future<void> start() async {
    await settingsStore.ensureLoaded();
    _timedMinutes = settingsStore.current.bridgeTimedApprovalMinutes;
    _settingsWatch = settingsStore.changes.listen((s) {
      _onTimedApprovalSetting(s.bridgeTimedApprovalMinutes);
      _enqueue(() => _apply(s.bridgeEnabled));
    });
    _clientsWatch = clients.changes.listen(_onClientsChanged);
    _lockWatch = appLockChanges?.listen((locked) {
      if (!locked) return;
      approvals.withdrawAll();
      grants.revokeAll();
      unawaited(terminals?.closeAll(AssistantTerminalEnd.appLocked));
      for (final module in tools.modules) {
        unawaited(
          module.ended(BridgeModuleEnd.appLocked).catchError((Object _) {}),
        );
      }
    });
    final hostChanges = this.hostChanges;
    if (hostChanges != null) {
      _hostsWatch = hostChanges.listen(_onHostsChanged);
      try {
        final initial = await tools.loadHosts();
        // A change that arrived meanwhile is newer than this read.
        _lastHosts ??= {for (final h in initial) h.id: h};
      } catch (_) {
        // Without a starting point only an address change on the very first
        // edit goes unseen; the dispatcher re-checks the server at every
        // decision regardless.
      }
    }
    await _enqueue(() => _apply(settingsStore.current.bridgeEnabled));
  }

  Future<void> _enqueue(Future<void> Function() step) {
    final next = _chain.then((_) => step());
    _chain = next.catchError((Object _) {});
    return next;
  }

  Future<void> _apply(bool enabled) async {
    if (_disposed || !localChannel) enabled = false;
    if (enabled) {
      if (_listener != null) return;
      await _startListener();
    } else {
      await _stopEverything();
      _setStatus(BridgeStatus.off);
    }
  }

  Future<void> _startListener() async {
    final BridgeListener listener;
    try {
      listener = await createListener(_verifyAssistant);
      _accepting = listener.connections.listen(_onConnection);
      await listener.start();
    } on BridgeAlreadyRunning {
      await _accepting?.cancel();
      _accepting = null;
      _setStatus(BridgeStatus.runningElsewhere);
      return;
    } catch (e) {
      await _accepting?.cancel();
      _accepting = null;
      _setStatus(BridgeError('$e'));
      return;
    }
    _listener = listener;
    _setStatus(BridgeStatus.running);
  }

  /// The token check the MCP channel uses: a paired assistant, never a
  /// controller. A controller's token reads exactly like an unknown one
  /// here, so it cannot be used to call a tool.
  Future<BridgeClient?> _verifyAssistant(String token) async {
    final client = await clients.verify(token);
    if (client == null || !bridgeClientMayCallTools(client)) return null;
    return client;
  }

  /// The client ids whose belongings survive a change to the paired list or
  /// the channel switch: the built-in assistant's, which is never paired.
  static const Set<String> _notChannel = {BridgeClient.builtinId};

  void _onConnection(BridgeConnection raw) {
    if (_accepting == null || !bridgeClientMayCallTools(raw.client)) {
      unawaited(raw.close());
      return;
    }
    final connection = _GuardedConnection(raw);
    _open.add(connection);
    _publishClients();
    final server = McpServer(tools: tools);
    unawaited(
      server.serve(connection).catchError((Object _) {}).whenComplete(() {
        _open.remove(connection);
        _publishClients();
      }),
    );
  }

  /// A client revoked in Settings loses its open connections now, not when
  /// it next reconnects, and its calls in flight are stopped on the server
  /// with nothing sent back.
  void _onClientsChanged(List<BridgeClient> paired) {
    final ids = {for (final c in paired) c.id, ..._notChannel};
    // Whether or not the client is connected right now.
    approvals.withdrawClientsExcept(ids);
    grants.revokeClientsExcept(ids);
    unawaited(terminals?.closeClientsExcept(ids));
    for (final module in tools.modules) {
      unawaited(module.clientsChanged(ids).catchError((Object _) {}));
    }
    for (final connection in _open.toList()) {
      final id = connection.client.id;
      if (!ids.contains(id)) {
        _open.remove(connection);
        connection.cut();
        tools.abandonClient(id);
        unawaited(connection.close());
      }
    }
    _publishClients();
  }

  Future<void> _stopEverything() async {
    final listener = _listener;
    _listener = null;
    await _accepting?.cancel();
    _accepting = null;
    final open = _open.toList();
    _open.clear();
    for (final connection in open) {
      connection.cut();
    }
    // Only what channel clients hold: the built-in assistant has its own
    // switch.
    tools.abandonAll(except: _notChannel);
    approvals.withdrawClientsExcept(_notChannel);
    grants.revokeClientsExcept(_notChannel);
    // First, before the slower teardown below: the assistant's shells end
    // now (their drives end synchronously in here), not after the listener
    // and the connections.
    final terminalsClosed = terminals?.closeAll(
      AssistantTerminalEnd.bridgeOff,
      except: _notChannel,
    );
    final modulesEnded = [
      for (final module in tools.modules)
        module.ended(BridgeModuleEnd.bridgeOff).catchError((Object _) {}),
    ];
    for (final connection in open) {
      await connection.close();
    }
    _publishClients();
    try {
      await listener?.stop();
    } catch (_) {
      // Already stopped, or the endpoint is gone; nothing left to undo.
    }
    await terminalsClosed;
    await Future.wait(modulesEnded);
    // The cached connections are shared with the built-in assistant: kept
    // while it is on (they close on their own when idle), so switching the
    // channel off does not cut its calls.
    if (!tools.builtinAssistantEnabled()) await connections.closeAll();
  }

  /// A host's approvals end when the host is gone, stops allowing changes,
  /// or now points at another server (hostname, port, user name, transport
  /// or jump host — see [bridgeSameServer]): a time-limited approval was
  /// given for that server, and a card shown for it no longer describes what would happen. An unrelated
  /// edit (label, group, colour) keeps them. Stepping a host back up never
  /// brings a grant back.
  void _onHostsChanged(List<Host> hosts) {
    // Assistant terminals end on their own rule: the host gone, no longer
    // allowing a terminal, or pointing at another server. Modules (desktops,
    // jobs) apply their own.
    unawaited(terminals?.hostsChanged(hosts));
    for (final module in tools.modules) {
      unawaited(module.hostsChanged(hosts).catchError((Object _) {}));
    }
    final now = {for (final h in hosts) h.id: h};
    final before = _lastHosts ?? const <String, Host>{};
    _lastHosts = now;
    final ids = <String>{
      ...before.keys,
      for (final g in grants.current) g.hostId,
      for (final r in approvals.current) r.hostId,
    };
    for (final id in ids) {
      final host = now[id];
      final previous = before[id];
      final ended =
          host == null ||
          !host.aiMayRequestChanges ||
          (previous != null && !_sameServer(previous, host));
      if (!ended) continue;
      grants.revokeHost(id);
      approvals.withdrawHost(id);
    }
  }

  static bool _sameServer(Host a, Host b) => bridgeSameServer(a, b);

  /// Switching "allow for a while" off ends the approvals it gave; a new
  /// length leaves running ones as they were granted.
  void _onTimedApprovalSetting(int minutes) {
    final before = _timedMinutes;
    _timedMinutes = minutes;
    if (minutes == 0 && before != 0) grants.revokeAll();
  }

  void _setStatus(BridgeStatus next) {
    if (next == _status) return;
    _status = next;
    if (!_statusChanges.isClosed) _statusChanges.add(next);
  }

  void _publishClients() {
    if (!_clientChanges.isClosed) _clientChanges.add(connectedClients);
  }

  Future<void> dispose() async {
    _disposed = true;
    await _settingsWatch?.cancel();
    await _clientsWatch?.cancel();
    await _lockWatch?.cancel();
    await _hostsWatch?.cancel();
    await _enqueue(() => _apply(false));
    await terminals?.dispose();
    for (final module in tools.modules) {
      try {
        await module.ended(BridgeModuleEnd.disposed);
      } catch (_) {}
    }
    await approvals.dispose();
    await grants.dispose();
    await _statusChanges.close();
    await _clientChanges.close();
  }
}

/// A connection that can be cut: once [cut], nothing more is sent on it,
/// whatever the MCP server still has in hand. A revoked assistant, or one
/// connected when the bridge was switched off, gets no answer to a call
/// that was running at the time — not even one that finished in the gap
/// before the socket closed.
class _GuardedConnection implements BridgeConnection {
  _GuardedConnection(this._inner);

  final BridgeConnection _inner;
  var _cut = false;

  void cut() => _cut = true;

  @override
  BridgeClient get client => _inner.client;

  @override
  Stream<String> get lines => _inner.lines;

  @override
  void send(String line) {
    if (_cut) return;
    _inner.send(line);
  }

  @override
  Future<void> close() => _inner.close();
}
