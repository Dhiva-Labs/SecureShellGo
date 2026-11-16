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
/// started with the app, and driven entirely by `AppSettings.bridgeEnabled`.
///
/// It owns the listener, one [McpServer] per assistant connection, and
/// nothing else of its own: the tools, the cached SSH connections and the
/// paired clients are handed in, so each can be tested on its own. Every
/// call is refused by policy while the app is locked (the tools read the
/// lock state per call); switching the bridge off closes every assistant
/// connection and every SSH connection the bridge dialled, at once.
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
  });

  /// Only the desktop builds that ship the launcher run the bridge in 1.6.0.
  static bool get supported => Platform.isLinux || Platform.isWindows;

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
    if (_disposed) enabled = false;
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
      listener = await createListener(clients.verify);
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

  void _onConnection(BridgeConnection raw) {
    if (_accepting == null) {
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
    final ids = {for (final c in paired) c.id};
    // Whether or not the client is connected right now.
    approvals.withdrawClientsExcept(ids);
    grants.revokeClientsExcept(ids);
    unawaited(terminals?.closeClientsExcept(ids));
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
    tools.abandonAll();
    approvals.withdrawAll();
    grants.revokeAll();
    // First, before the slower teardown below: the assistant's shells end
    // now (their drives end synchronously in here), not after the listener
    // and the connections.
    final terminalsClosed = terminals?.closeAll(AssistantTerminalEnd.bridgeOff);
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
    await connections.closeAll();
  }

  /// A host's approvals end when the host is gone, stops allowing changes,
  /// or now points at another server (hostname, port, user name, transport
  /// or jump host — see [bridgeSameServer]): a time-limited approval was
  /// given for that server, and a card shown for it no longer describes what would happen. An unrelated
  /// edit (label, group, colour) keeps them. Stepping a host back up never
  /// brings a grant back.
  void _onHostsChanged(List<Host> hosts) {
    // Assistant terminals end on their own rule: the host gone, no longer
    // allowing a terminal, or pointing at another server.
    unawaited(terminals?.hostsChanged(hosts));
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
