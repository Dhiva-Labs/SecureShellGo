import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../remote_exec.dart';
import '../ssh_service.dart';
import 'mosh_bootstrap.dart';
import 'mosh_client.dart';
import 'mosh_connection.dart';
import 'mosh_overlay.dart';

export 'mosh_client.dart' show MoshExit, MoshUnreachableException;
export 'mosh_bootstrap.dart'
    show MoshServerInfo, MoshStartException, MoshStartFailure;

/// A session's terminal carried by Mosh instead of an SSH shell channel —
/// what `SessionController` holds when the host's terminal connection is
/// set to Mosh.
///
/// Sign-in, files, tunnels and commands stay on the SSH connection; Mosh
/// only needs it once, to start `mosh-server`, and again only to check on it.
/// The terminal itself then lives on UDP and survives what kills TCP: a
/// change of network, a long sleep, an address that moved. It needs no
/// reconnecting — after a gap it just catches up, with Mosh's own bar across
/// the top saying how long the server has been out of touch.
class MoshShell {
  /// Wraps a client already connected to [server]; [start] is the usual way
  /// to get one.
  MoshShell.attach(this._client, this.server);

  final MoshClient _client;

  /// What `mosh-server` reported when it started.
  final MoshServerInfo server;

  /// Starts `mosh-server` over [ssh] and connects to it.
  ///
  /// [command] runs instead of the login shell (a persistent tmux or screen
  /// session). [server] overrides how `mosh-server` is found, as
  /// `mosh --server=` does. Throws [MoshStartException] when the server
  /// would not start and [MoshUnreachableException] when it started but
  /// nothing came back over UDP — and in that case stops it again.
  static Future<MoshShell> start(
    SessionTransport ssh, {
    required int columns,
    required int rows,
    String? command,
    String? server,
    Duration connectTimeout = const Duration(seconds: 10),
    MoshUdpBinder bind = bindRawMoshSocket,
    MoshPredictionMode prediction = MoshPredictionMode.adaptive,
    Future<InternetAddress> Function(MoshServerInfo info)? resolve,
  }) async {
    final info = await startMoshServer(ssh, command: command, server: server);
    MoshClient? client;
    try {
      final InternetAddress address;
      try {
        address = resolve != null
            ? await resolve(info)
            : await moshServerAddress(
                ssh.host.hostname,
                sshConnection: info.sshConnection,
              );
      } on SocketException {
        throw MoshUnreachableException(
          'Could not find an address for ${ssh.host.hostname} to reach '
          'mosh-server on.',
        );
      }
      client = MoshClient(
        key: parseMoshKey(info.key),
        address: address,
        port: info.port,
        columns: columns,
        rows: rows,
        bind: bind,
        prediction: prediction,
      );
      try {
        await client.connect(timeout: connectTimeout);
      } on SocketException catch (e) {
        throw MoshUnreachableException(
          'Could not open a UDP socket: ${e.osError?.message ?? e.message}',
        );
      }
      return MoshShell.attach(client, info);
    } catch (_) {
      client?.abandon();
      final pid = info.pid;
      if (pid != null) unawaited(stopMoshServer(ssh, pid));
      rethrow;
    }
  }

  /// Escape sequences for the session's terminal.
  Stream<String> get output => _client.output;

  /// Completes when the session ends: the shell exited, or Mosh gave up.
  Future<MoshExit> get done => _client.done;

  bool get isClosed => _client.isClosed;

  /// True while the server has been out of touch for a while.
  bool get isLate => _client.isLate;

  /// The underlying client, for diagnostics and tests.
  MoshClient get client => _client;

  void write(String data) => _client.sendInput(utf8.encode(data));

  void resize(int columns, int rows) => _client.resize(columns, rows);

  /// The device's network changed; see [MoshClient.networkChanged].
  void networkChanged() => _client.networkChanged();

  /// Redraws the whole screen; needed after anything else wrote into the
  /// terminal.
  void repaint() => _client.repaint();

  /// Ends the session, shell and all, as Mosh's Ctrl-^ . does.
  ///
  /// When the server never answers the goodbye — UDP that no longer gets
  /// through — it would keep running, and the shell under it, for ever: it
  /// only gives up on its own before a client has ever connected. Given
  /// [ssh], it is then stopped by its pid over that instead.
  Future<MoshExit> close({SessionTransport? ssh}) async {
    final exit = await _client.close();
    final pid = server.pid;
    if (!exit.clean && ssh != null && pid != null && !ssh.isClosed) {
      await stopMoshServer(ssh, pid);
    }
    return exit;
  }

  /// After the SSH connection came back from a drop: if Mosh has heard
  /// nothing either, checks whether `mosh-server` is still running at all —
  /// a host that rebooted took it with it, and no amount of waiting will
  /// bring that session back. Ends this one then, so a new one can start.
  ///
  /// A pid the host has since given to another process reads as running,
  /// so a server that is gone can still look alive here; that only means
  /// waiting on, as before. Stopping one is more careful — see
  /// [stopMoshServer].
  Future<void> checkServer(SessionTransport ssh) async {
    final pid = server.pid;
    if (pid == null || isClosed || !isLate) return;
    try {
      final result = await RemoteExec.run(
        ssh,
        'kill -0 $pid 2>/dev/null && echo alive || echo gone',
        timeout: const Duration(seconds: 8),
      );
      if (result.stdout.trim() == 'gone') {
        _client.endBecause('mosh-server is no longer running on the host.');
      }
    } catch (_) {
      // Could not tell; keep waiting.
    }
  }
}

/// How a session starts its Mosh terminal: [MoshShell.start], or a stand-in
/// in tests.
typedef MoshStarter =
    Future<MoshShell> Function(
      SessionTransport ssh, {
      required int columns,
      required int rows,
      String? command,
    });

/// The one line said in the terminal when a Mosh host gets an SSH terminal
/// instead, and why.
String moshFallbackNotice(Object error) {
  final why = switch (error) {
    MoshStartException(:final message) => message,
    MoshUnreachableException(:final message) => message,
    _ => 'Mosh could not start: $error',
  };
  final reason = why.endsWith('.') ? why : '$why.';
  return '$reason Using SSH for this terminal.';
}
