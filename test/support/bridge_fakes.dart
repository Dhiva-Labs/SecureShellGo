import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart' show SSHSession;
import 'package:secure_shell_go/models/app_settings.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/models/host_ai_access.dart';
import 'package:secure_shell_go/models/remote_entry.dart';
import 'package:secure_shell_go/services/bridge/bridge_audit.dart';
import 'package:secure_shell_go/services/bridge/bridge_client_store.dart';
import 'package:secure_shell_go/services/bridge/bridge_connections.dart';
import 'package:secure_shell_go/services/bridge/bridge_redactor.dart';
import 'package:secure_shell_go/services/bridge/bridge_tools.dart';
import 'package:secure_shell_go/services/ssh_service.dart';

import '../fake_exec_session.dart';

/// A server's files as SFTP would show them to the bridge: [links] are what
/// realpath resolves (a symlink, in effect), everything else resolves to
/// itself when it exists and fails when it does not.
class FakeBridgeFiles implements BridgeFiles {
  final Map<String, String> links = {};
  final Map<String, Uint8List> files = {};
  final Map<String, List<RemoteEntry>> dirs = {};

  /// `path@offset+length` for every read, so a test can prove only the
  /// window was asked for.
  final List<String> reads = [];
  final List<String> realpaths = [];
  var closed = 0;

  static const String home = '/home/dev';

  void addFile(String path, String text) =>
      files[path] = Uint8List.fromList(utf8.encode(text));

  void addDir(String path, List<String> names) {
    dirs[path] = [
      for (final n in names)
        RemoteEntry(
          name: n,
          path: path == '/' ? '/$n' : '$path/$n',
          kind: RemoteEntryKind.file,
          size: 1,
        ),
    ];
  }

  @override
  Future<String> realpath(String path) async {
    realpaths.add(path);
    var abs = path == '.'
        ? home
        : path.startsWith('/')
        ? path
        : '$home/$path';
    abs = links[abs] ?? abs;
    if (files.containsKey(abs) || dirs.containsKey(abs)) return abs;
    throw Exception('No such file');
  }

  @override
  Future<BridgeFileStat> stat(String path) async {
    if (dirs.containsKey(path)) {
      return const BridgeFileStat(type: BridgeFileType.directory);
    }
    final bytes = files[path];
    if (bytes == null) throw Exception('No such file');
    return BridgeFileStat(type: BridgeFileType.file, size: bytes.length);
  }

  @override
  Future<List<RemoteEntry>> list(String path) async {
    final entries = dirs[path];
    if (entries == null) throw Exception('Not a directory');
    return entries;
  }

  @override
  Future<Uint8List> read(
    String path, {
    required int offset,
    required int length,
  }) async {
    reads.add('$path@$offset+$length');
    final bytes = files[path]!;
    final start = offset > bytes.length ? bytes.length : offset;
    final end = start + length > bytes.length ? bytes.length : start + length;
    return Uint8List.sublistView(bytes, start, end);
  }

  @override
  Future<void> close() async => closed++;
}

Host bridgeHost(
  String id,
  String label, {
  HostAiAccess access = HostAiAccess.readOnly,
}) => Host(
  id: id,
  label: label,
  hostname: '$id.example.test',
  port: 22,
  username: 'dev',
  authMethod: SshAuthMethod.password,
  aiAccess: access,
);

final BridgeClient testBridgeClient = BridgeClient(
  id: 'c1',
  name: 'Test assistant',
  tokenHash: 'x',
  createdAt: DateTime.utc(2026),
);

/// Everything a [BridgeTools] needs, faked, with knobs for each test.
class BridgeToolsRig {
  BridgeToolsRig(
    this.auditDir, {
    String Function(String)? scrub,
    Duration callTimeout = const Duration(seconds: 30),
    int maxRunning = 4,
    int maxWaiting = 32,
    BridgeDialer? dialer,
    Duration idleTimeout = const Duration(seconds: 60),
  }) {
    connections = BridgeConnections(
      openTransport: (id) => transports[id],
      credentialLookup: (_) async => const SshCredentials(password: 'pw'),
      dialer:
          dialer ??
          (host, _) async =>
              throw const SshConnectionException('no dialling in this test'),
      openFiles: (_) async => fs,
      idleTimeout: idleTimeout,
    );
    audit = BridgeAuditLog(scrub: (s) => s, directory: auditDir);
    audit.entries.listen(entries.add);
    tools = BridgeTools(
      loadHosts: () async => hosts,
      settings: () => settings,
      isAppLocked: () => locked,
      connections: connections,
      redactor: BridgeRedactor(scrub: scrub ?? (s) => s),
      audit: audit,
      callTimeout: callTimeout,
      maxRunning: maxRunning,
      maxWaiting: maxWaiting,
    );
  }

  final Directory auditDir;
  List<Host> hosts = [
    bridgeHost('web1', 'web'),
    bridgeHost('db01', 'db'),
    bridgeHost('sec1', 'secret', access: HostAiAccess.off),
  ];
  AppSettings settings = const AppSettings(bridgeEnabled: true);
  bool locked = false;
  final FakeBridgeFiles fs = FakeBridgeFiles();
  final Map<String, FakeExecTransport> transports = {};
  final List<BridgeAuditEntry> entries = [];
  late final BridgeConnections connections;
  late final BridgeAuditLog audit;
  late final BridgeTools tools;

  /// A session open on [hostId] answering commands with [respond].
  FakeExecTransport serve(
    String hostId,
    FakeExecSession Function(String command) respond, {
    Duration? delay,
  }) => transports[hostId] = SupervisedFakeTransport(
    host: hosts.firstWhere((h) => h.id == hostId),
    respond: respond,
    delay: delay,
  );

  /// Every command run on any host.
  List<String> get commands => [
    for (final t in transports.values) ...t.commands,
  ];

  Future<({String text, bool isError})> call(
    String name, [
    Map<String, Object?> args = const {},
  ]) async {
    final r = await tools.call(testBridgeClient, name, args);
    // The audit log publishes each entry on its broadcast `entries` stream
    // once the write has been attempted, and a broadcast stream delivers on
    // a later microtask — after `call` has already returned. A zero timer
    // runs only once every pending microtask has, so [entries] is complete
    // when this returns.
    await Future<void>.delayed(Duration.zero);
    return (text: r.text, isError: r.isError);
  }
}

/// The fixed command inside [BridgeCommands.supervised], or null when
/// [command] is not one.
String? unsupervise(String command) {
  const marker = "'X'";
  final shape = BridgeCommands.supervised('X');
  final prefix = shape.substring(0, shape.length - marker.length);
  if (!command.startsWith(prefix)) return null;
  final quoted = command.substring(prefix.length);
  if (quoted.length < 2 || !quoted.startsWith("'") || !quoted.endsWith("'")) {
    return null;
  }
  return quoted.substring(1, quoted.length - 1).replaceAll("'\\''", "'");
}

/// A [FakeExecTransport] for the bridge tools: it insists every command
/// arrives under [BridgeCommands.supervised], keeps the wrapped text in
/// [rawCommands], and records and answers the fixed command inside, so
/// tests read the templates as they are.
class SupervisedFakeTransport extends FakeExecTransport {
  SupervisedFakeTransport({super.host, super.respond, super.delay});

  final List<String> rawCommands = [];

  @override
  Future<SSHSession> execute(String command) {
    rawCommands.add(command);
    final inner = unsupervise(command);
    if (inner == null) {
      throw StateError('not run under BridgeCommands.supervised: $command');
    }
    return super.execute(inner);
  }
}
