import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/services/ssh_service.dart';

import '../fake_exec_session.dart';
import 'fake_transport.dart';

// The connection, shell, dialler and hand-driven timers the
// terminal-never-dies suites share: dead links, reconnects, persistent
// shells, and the network coming back.

const testCredentials = SshCredentials(password: 'hunter2');

/// A shell channel with no SSH underneath, that can be ended.
class FakeShell implements SSHSession {
  final _done = Completer<void>();
  final _stdout = StreamController<Uint8List>.broadcast();
  final _stderr = StreamController<Uint8List>.broadcast();

  final List<String> writes = [];

  @override
  Stream<Uint8List> get stdout => _stdout.stream;

  @override
  Stream<Uint8List> get stderr => _stderr.stream;

  @override
  Future<void> get done => _done.future;

  @override
  int? exitCode = 0;

  @override
  void write(Uint8List data) => writes.add(String.fromCharCodes(data));

  @override
  void close() {}

  @override
  void resizeTerminal(int width, int height, [int? pw, int? ph]) {}

  void exit([int status = 0]) {
    exitCode = status;
    if (!_done.isCompleted) _done.complete();
  }

  /// The transport went: the channel ends normally, with no exit status.
  void hangUp() {
    if (_done.isCompleted) return;
    exitCode = null;
    _done.complete();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not faked');
}

/// A connection whose keep-alives the test answers or not, and whose shells
/// and probes it can see.
class LinkTransport extends FakeTransportBase {
  LinkTransport({this.name = 'first', super.host});

  final String name;

  /// Unanswered keep-alives fail at once rather than after the real
  /// timeout; to the keep-alive that is the same miss.
  var answering = true;

  final List<FakeShell> shells = [];

  /// One entry per shell opened: the command it ran instead of the login
  /// shell, or null for the login shell.
  final List<String?> shellCommands = [];

  var commandShells = true;
  var probeAnswer = 'new\n';
  final List<String> executed = [];

  @override
  Future<void> ping() async {
    pingCount++;
    if (!answering) throw TimeoutException('no answer');
  }

  @override
  Future<SSHSession> startShell({
    required int columns,
    required int rows,
    String terminalType = 'xterm-256color',
  }) async {
    shellCommands.add(null);
    return _open();
  }

  @override
  Future<SSHSession> startCommandShell(
    String command, {
    required int columns,
    required int rows,
    String terminalType = 'xterm-256color',
  }) async {
    if (!commandShells) throw UnimplementedError('no exec here');
    shellCommands.add(command);
    return _open();
  }

  FakeShell _open() {
    final shell = FakeShell();
    shells.add(shell);
    return shell;
  }

  @override
  void endChannels() {
    for (final shell in shells) {
      shell.hangUp();
    }
  }

  @override
  Future<SSHSession> execute(String command) async {
    executed.add(command);
    return FakeExecSession(stdout: probeAnswer);
  }
}

/// A connect callback: hands out what [next] says, one call at a time.
class Dialer {
  Dialer(this.next);

  /// A [SessionTransport] to hand back, or anything else to throw.
  Object next;
  var calls = 0;

  Future<SessionTransport> connect({
    required Host host,
    required SshCredentials credentials,
    required HostKeyVerifier verifyHostKey,
  }) async {
    calls++;
    final step = next;
    if (step is SessionTransport) return step;
    throw step;
  }
}

/// A backoff timer the test fires by hand.
class ManualScheduler {
  final List<Duration> delays = [];
  final List<void Function()> _pending = [];

  Timer schedule(Duration delay, void Function() fire) {
    delays.add(delay);
    _pending.add(fire);
    return _InertTimer(() => _pending.remove(fire));
  }

  Future<void> fire() async {
    fireNow();
    await pump();
  }

  /// Runs the pending wait and returns at once — for a widget test, where
  /// the zero-length delays [pump] waits on only pass when the test pumps.
  void fireNow() {
    expect(_pending, isNotEmpty, reason: 'nothing was scheduled to fire');
    _pending.removeAt(0)();
  }
}

class _InertTimer implements Timer {
  _InertTimer(this._onCancel);

  final void Function() _onCancel;
  var _active = true;

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;

  @override
  void cancel() {
    if (!_active) return;
    _active = false;
    _onCancel();
  }
}

/// A keep-alive timer the test fires by hand.
class CrankTimer implements Timer {
  CrankTimer(this.callback);

  final void Function(Timer timer) callback;
  var cancelled = false;

  @override
  bool get isActive => !cancelled;

  @override
  int get tick => 0;

  @override
  void cancel() => cancelled = true;

  void fire() {
    if (!cancelled) callback(this);
  }
}

Future<void> pump() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
