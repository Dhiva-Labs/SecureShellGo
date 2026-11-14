import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart' show SSHSocket;

import '../tunnel_carrier.dart';
import 'agent_failure.dart';
import 'agent_manifest.dart';

/// The agent's `host.json`: `{"v":1,"port":N,"token":"<64 hex>","pid":N,"ver":"…"}`.
class AgentHostInfo {
  const AgentHostInfo({
    required this.port,
    required this.token,
    required this.pid,
    required this.version,
  });

  final int port;

  /// 32 bytes as 64 lowercase hex digits. What keeps every other account on
  /// the server off the agent's loopback port.
  final String token;
  final int pid;

  /// The engine version the agent reports, `0.2.0`.
  final String version;

  Uint8List get tokenBytes => Uint8List.fromList([
        for (var i = 0; i < token.length; i += 2)
          int.parse(token.substring(i, i + 2), radix: 16),
      ]);

  static final RegExp _token = RegExp(r'^[0-9a-f]{64}$');
  static final RegExp _version = RegExp(r'^[0-9A-Za-z.+_-]{1,64}$');

  /// Parses and checks `host.json`, or throws [AgentFailure] with
  /// [AgentFailureKind.badHostInfo].
  ///
  /// Strict about every field this app uses — the type, the range, the
  /// token's exact shape — because the file comes from the server and the
  /// port goes straight into a forward request. Fields it does not use are
  /// tolerated, so a later engine can add some without breaking older apps;
  /// `v` is what says the meaning of the known ones changed.
  ///
  /// The failure never quotes the file: it holds the token.
  static AgentHostInfo parse(String text) {
    Never bad(String why) => throw AgentFailure(
          AgentFailureKind.badHostInfo,
          'The remote-desktop agent started, but what it published could not '
          'be trusted.',
          details: 'host.json: $why',
        );

    if (text.length > 4096) bad('larger than 4 KiB');
    final Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException {
      bad('not JSON');
    }
    if (json is! Map<String, Object?>) bad('not a JSON object');
    if (json['v'] != 1) bad('version ${json['v']} is not 1');
    final port = json['port'];
    if (port is! int || port < 1 || port > 65535) bad('bad port');
    final token = json['token'];
    if (token is! String || !_token.hasMatch(token)) bad('bad token');
    final pid = json['pid'];
    if (pid is! int || pid < 1 || pid > 0xFFFFFFFF) bad('bad pid');
    final ver = json['ver'];
    if (ver is! String || !_version.hasMatch(ver)) bad('bad ver');
    return AgentHostInfo(port: port, token: token, pid: pid, version: ver);
  }
}

/// A running agent: where to reach it, the token to present, and how to
/// stop it.
class AgentEndpoint {
  AgentEndpoint({
    required this.info,
    required this.os,
    required this.runtimeDir,
    this.unitName,
    required Future<void> Function() stop,
  }) : _stop = stop; // ignore: prefer_initializing_formals

  final AgentHostInfo info;
  final AgentOs os;

  /// The agent's private runtime directory on the server, in the server's
  /// own path syntax.
  final String runtimeDir;

  /// The systemd user unit it runs in, or null when it runs as a bare
  /// process (no user systemd, or Windows).
  final String? unitName;

  final Future<void> Function() _stop;
  Future<void>? _stopping;

  int get port => info.port;
  String get token => info.token;
  Uint8List get tokenBytes => info.tokenBytes;
  int get pid => info.pid;
  String get version => info.version;

  bool get isStopped => _stopping != null;

  /// Stops the agent and removes its runtime directory. Idempotent: the
  /// second call returns the first call's future, so a viewer that closes
  /// and a session that tears down at the same moment cannot race.
  ///
  /// Not needed for safety — `--exit-when-idle` stops an agent whose viewer
  /// went away — but it stops it now rather than 15 + N seconds from now.
  Future<void> stop() => _stopping ??= _stop();
}

/// Opens the forward channel to [endpoint]'s port on the server's loopback.
///
/// A `direct-tcpip` channel straight from the SSH connection: no listening
/// socket on this device, nothing exposed on the server beyond 127.0.0.1.
/// The channel open only succeeds once sshd has connected to the port, so a
/// returned socket means the agent is listening.
Future<SSHSocket> openAgentChannel(
  TunnelCarrier carrier,
  AgentEndpoint endpoint, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  try {
    return await carrier
        .forwardLocal('127.0.0.1', endpoint.port)
        .timeout(timeout);
  } catch (e) {
    throw AgentFailure(
      AgentFailureKind.channelFailed,
      'Could not connect to the remote-desktop agent on the server. The '
      'server may not allow port forwarding (AllowTcpForwarding).',
      details: e.toString(),
    );
  }
}
