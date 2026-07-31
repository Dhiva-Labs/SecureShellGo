import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/services/ssh_service.dart';
// The concrete SSHChannel/SSHChannelController aren't part of dartssh2's
// public surface (dartssh2.dart never exports ssh_channel.dart) — the test
// suite reaches in anyway, in this one file, so that a *real* SSHSession can
// be scripted without a live connection. That is the only way to satisfy
// `SessionTransport.execute`'s return type. Production code never does this;
// see `remote_exec.dart`, which only ever consumes a session it is handed.
//
// Shared rather than copied per test file: `public_key_push_test.dart` had
// the original, and the monitoring features need the same thing four more
// times. One inert channel, one place to fix if dartssh2's internals move.
// ignore: implementation_imports
import 'package:dartssh2/src/ssh_channel.dart';

/// A real [SSHSession] wired to a channel connected to nothing, with every
/// member the monitoring services read overridden to scripted values.
///
/// Both output pipes are delivered as a single chunk by default. Tests that
/// care about chunk boundaries — the log tailer's line assembly, above all —
/// pass [stdoutChunks] instead and control the split exactly.
class FakeExecSession extends SSHSession {
  FakeExecSession({
    String stdout = '',
    this.stderrText = '',
    this.exitCode = 0,
    List<String>? stdoutChunks,
    Stream<String>? stdoutStream,
    this.exitDelay,
    this.exits = false,
  })  : stdoutChunks = stdoutChunks ?? (stdout.isEmpty ? const [] : [stdout]),
        _stdoutStream = stdoutStream, // ignore: prefer_initializing_formals
        super(_inertChannel());

  final List<String> stdoutChunks;

  /// Named `stderrText`, not `stderr`: [SSHSession] already declares a
  /// `stderr` getter, and a field of that name cannot coexist with it.
  final String stderrText;

  @override
  final int? exitCode;

  /// How long `waitForExit` takes to answer. Used to hold a probe in flight
  /// while a test asserts what happens to the tick that lands on top of it.
  final Duration? exitDelay;

  /// Whether the remote command should be treated as having ended.
  ///
  /// The inert channel underneath never closes, so [SSHSession.done] never
  /// completes — the right shape for a `tail -F` that runs until something
  /// kills it, and the wrong one for a command that exits. Callers that wait
  /// on `done` rather than `waitForExit` (the direct copy path does, because
  /// it has to race the exit against a cancel poll) opt in with this. Off by
  /// default so the tail tests keep the session they need.
  final bool exits;

  /// A caller-driven stdout stream, for the tail tests: they push lines in
  /// over time rather than replaying a fixed script.
  final Stream<String>? _stdoutStream;

  /// True once [close] has run — the no-orphan assertions read this.
  var wasClosed = false;

  /// True once stdin has been closed, which is what triggers the tail
  /// watchdog's `kill` on the server.
  var stdinClosed = false;

  late final StreamController<Uint8List> _stdin =
      StreamController<Uint8List>()..stream.drain<void>();

  @override
  StreamSink<Uint8List> get stdin => _StdinSink(_stdin.sink, () {
        stdinClosed = true;
      });

  @override
  Stream<Uint8List> get stdout {
    final live = _stdoutStream;
    if (live != null) {
      return live.map((text) => Uint8List.fromList(utf8.encode(text)));
    }
    return Stream.fromIterable(
      stdoutChunks.map((chunk) => Uint8List.fromList(utf8.encode(chunk))),
    );
  }

  @override
  Stream<Uint8List> get stderr => stderrText.isEmpty
      ? const Stream.empty()
      : Stream.value(Uint8List.fromList(utf8.encode(stderrText)));

  @override
  Future<void> get done => exits
      ? Future<void>.delayed(exitDelay ?? Duration.zero)
      : super.done;

  @override
  Future<int?> waitForExit({Duration? timeout}) async {
    final delay = exitDelay;
    if (delay != null) await Future<void>.delayed(delay);
    return exitCode;
  }

  @override
  void close() {
    wasClosed = true;
  }

  static SSHChannel _inertChannel() {
    final controller = SSHChannelController(
      localId: 0,
      localMaximumPacketSize: 1 << 15,
      localInitialWindowSize: 1 << 20,
      remoteId: 0,
      // Zero keeps the controller's upload loop from ever activating —
      // there is no real peer on the other end to send anything to.
      remoteInitialWindowSize: 0,
      remoteMaximumPacketSize: 1 << 15,
      sendMessage: (_) {},
    );
    return controller.channel;
  }
}

/// Wraps the scripted stdin sink so the test can observe the close that the
/// tail watchdog depends on.
class _StdinSink implements StreamSink<Uint8List> {
  _StdinSink(this._inner, this._onClose);

  final StreamSink<Uint8List> _inner;
  final void Function() _onClose;

  @override
  void add(Uint8List data) => _inner.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _inner.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<Uint8List> stream) => _inner.addStream(stream);

  @override
  Future<void> close() async {
    _onClose();
    await _inner.close();
  }

  @override
  Future<void> get done => _inner.done;
}

/// A [SessionTransport] whose `execute` hands back a [FakeExecSession]
/// instead of a live channel.
///
/// Every command string it was asked to run is recorded in [commands], and
/// every session it handed out is kept in [sessions] — which is how the
/// no-orphan assertions check that a channel was actually closed.
///
/// [respond] is the whole scripting mechanism: a test that only needs one
/// canned answer passes `stdout:`, and a test that needs different answers
/// per command (a `ps` that refuses its flags and falls back, a `systemctl`
/// probe followed by a list) supplies a function.
class FakeExecTransport implements SessionTransport {
  FakeExecTransport({
    this.stdout = '',
    this.stderrText = '',
    this.exitCode = 0,
    this.delay,
    bool agentForwarding = false,
    FakeExecSession Function(String command)? respond,
  })  : agentSlot = agentForwarding ? MutableSSHAgentHandler() : null,
        _respond = respond; // ignore: prefer_initializing_formals

  String stdout;
  String stderrText;
  int exitCode;

  /// Held open for this long before `waitForExit` answers, so a test can
  /// assert what happens to work that lands while a command is in flight.
  final Duration? delay;

  final FakeExecSession Function(String command)? _respond;

  final List<String> commands = [];
  final List<FakeExecSession> sessions = [];

  /// Set to make `execute` throw, standing in for a transport that cannot
  /// open a channel at all.
  Object? failWith;

  /// Whether the agent slot held a delegate at the moment of each `execute`.
  /// The scoping claim the direct copy path makes is that it is true for its
  /// one exec and false either side of it.
  final List<bool> agentInstalledAtExec = [];

  /// Whether the agent-forwarding request has already been granted on this
  /// connection. See [execute].
  var _agentGranted = false;

  @override
  Future<SSHSession> execute(String command) async {
    // Models what a real OpenSSH server does to a dartssh2 client that holds
    // an agent handler: dartssh2 puts an `auth-agent-req@openssh.com` on
    // *every* session channel such a client opens and throws when it is
    // refused, and sshd grants it once per connection. So a transport with a
    // slot runs one exec and fails every later one — which is exactly what
    // took out the stats poll, the log tail, the service actions and the key
    // push. A transport without a slot (the default, and the shape of every
    // session connection) is reusable for the life of the session.
    if (agentSlot != null) {
      if (_agentGranted) {
        throw SSHChannelRequestError('Failed to request agent forwarding');
      }
      _agentGranted = true;
    }
    agentInstalledAtExec.add(agentSlot?.isInstalled ?? false);
    commands.add(command);
    final failure = failWith;
    if (failure != null) throw failure;
    if (delay != null) await Future<void>.delayed(delay!);

    final session = _respond?.call(command) ??
        FakeExecSession(
          stdout: stdout,
          stderrText: stderrText,
          exitCode: exitCode,
        );
    sessions.add(session);
    return session;
  }

  @override
  Host get host => const Host(
        id: 'h1',
        label: 'test',
        hostname: 'example.test',
        port: 22,
        username: 'root',
        authMethod: SshAuthMethod.password,
      );

  @override
  Future<void> get done => Completer<void>().future;

  @override
  bool get isClosed => closed;

  /// Set by [close]. The direct copy path owns the connection it dials, so
  /// "was it hung up afterwards" is an assertion worth being able to make.
  var closed = false;

  @override
  Future<SSHSession> startShell({
    required int columns,
    required int rows,
    String terminalType = 'xterm-256color',
  }) =>
      throw UnimplementedError();

  @override
  Future<SftpClient> openSftp() => throw UnimplementedError();

  /// Null unless built with `agentForwarding: true` — the production shape
  /// of a session connection, and the reason its execs are repeatable.
  @override
  final MutableSSHAgentHandler? agentSlot;

  @override
  Future<void> ping() async {}

  @override
  void close() => closed = true;
}
