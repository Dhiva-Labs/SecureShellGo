import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/services/device_storage.dart';
import 'package:secure_shell_go/services/session_controller.dart';
import 'package:secure_shell_go/services/session_reconnect.dart';
import 'package:secure_shell_go/services/ssh_service.dart';

const testHost = Host(
  id: 'h1',
  label: 'Test box',
  hostname: 'example.com',
  port: 22,
  username: 'dev',
  authMethod: SshAuthMethod.password,
);

const testCredentials = SshCredentials(password: 'hunter2');

/// Stands in for a live [SshConnection]. dartssh2's `SSHClient` cannot be
/// faked usefully, which is exactly why [SessionTransport] exists.
class FakeTransport implements SessionTransport {
  FakeTransport({this.name = 'first'});

  final String name;
  final _done = Completer<void>();

  var closeCount = 0;
  var pingCount = 0;

  @override
  Host get host => testHost;

  @override
  Future<void> get done => _done.future;

  @override
  bool get isClosed => closeCount > 0;

  @override
  Future<SSHSession> startShell({
    required int columns,
    required int rows,
    String terminalType = 'xterm-256color',
  }) =>
      throw UnimplementedError('the shell needs a real SSH channel');

  @override
  Future<SftpClient> openSftp() => throw UnimplementedError();

  @override
  Future<SSHSession> execute(String command) => throw UnimplementedError();

  @override
  MutableSSHAgentHandler get agentSlot => _agentSlot;
  final _agentSlot = MutableSSHAgentHandler();

  @override
  Future<void> ping() async => pingCount++;

  @override
  void close() => closeCount++;

  /// The transport going away underneath the session. With an error it is a
  /// break; without one it is an orderly goodbye.
  void drop([Object? error]) {
    if (_done.isCompleted) return;
    if (error == null) {
      _done.complete();
    } else {
      _done.completeError(error);
    }
  }
}

/// A shell channel with no SSH underneath it.
///
/// Only exists to be *ended*: the one thing these tests need from a real shell
/// is the difference between a channel that closed properly — which is what
/// `exit` looks like from the client — and one that fell over.
class FakeShell implements SSHSession {
  final _done = Completer<void>();
  final _stdout = StreamController<Uint8List>.broadcast();
  final _stderr = StreamController<Uint8List>.broadcast();

  final List<Uint8List> writes = [];

  @override
  Stream<Uint8List> get stdout => _stdout.stream;

  @override
  Stream<Uint8List> get stderr => _stderr.stream;

  @override
  Future<void> get done => _done.future;

  @override
  int? exitCode = 0;

  @override
  void write(Uint8List data) => writes.add(data);

  @override
  void close() {}

  @override
  void resizeTerminal(int width, int height, [int? pw, int? ph]) {}

  /// The user typed `exit`: the channel closes in an orderly way and reports
  /// a status.
  void exit([int status = 0]) {
    exitCode = status;
    if (!_done.isCompleted) _done.complete();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not faked');
}

/// A transport whose shell actually opens.
class ShellTransport extends FakeTransport {
  ShellTransport() : super(name: 'with a shell');

  final FakeShell shell = FakeShell();

  @override
  Future<SSHSession> startShell({
    required int columns,
    required int rows,
    String terminalType = 'xterm-256color',
  }) async =>
      shell;
}

/// Nothing here downloads anything; the session merely insists on having
/// somewhere to save to.
class UnusedStorage implements DeviceStorage {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('storage is not exercised in these tests');
}

/// A backoff timer the test fires by hand, so a two-minute ladder runs in no
/// time at all.
class ManualScheduler {
  final List<Duration> delays = [];
  final List<void Function()> _pending = [];

  int get pendingCount => _pending.length;

  Timer schedule(Duration delay, void Function() fire) {
    delays.add(delay);
    _pending.add(fire);
    // A real, already-elapsed timer: the reconnector cancels whatever it is
    // handed, and a no-op is the cheapest thing that can be cancelled.
    return Timer(Duration.zero, () {});
  }

  /// Runs the wait that is currently pending.
  Future<void> fire() async {
    expect(_pending, isNotEmpty, reason: 'nothing was scheduled to fire');
    final next = _pending.removeAt(0);
    next();
    await pump();
  }

  /// Lets the attempt's futures settle.
  static Future<void> pump() async {
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }
}

/// A connect callback with a script: each entry is either a transport to hand
/// back or an error to throw.
class ScriptedConnector {
  ScriptedConnector(this.script);

  /// Each element is a `FakeTransport`, an `Object` to throw, or a
  /// [HostKeyPromptKind] meaning "offer the user this prompt, then fail the
  /// way `SshService` fails when the prompt is refused".
  final List<Object> script;

  var calls = 0;
  final List<HostKeyPrompt> promptsOffered = [];

  Future<SessionTransport> connect({
    required Host host,
    required SshCredentials credentials,
    required HostKeyVerifier verifyHostKey,
  }) async {
    final step = script[calls < script.length ? calls : script.length - 1];
    calls++;

    if (step is HostKeyPromptKind) {
      final prompt = HostKeyPrompt(
        kind: step,
        hostname: host.hostname,
        port: host.port,
        keyType: 'ssh-ed25519',
        fingerprint: 'SHA256:new',
      );
      promptsOffered.add(prompt);
      final accepted = await verifyHostKey(prompt);
      // Exactly what `SshService.connect` does when the verifier says no.
      if (!accepted) {
        throw const HostKeyRejectedException(
          'Connection cancelled: the server\'s host key was not trusted.',
        );
      }
      throw StateError('the verifier accepted a key it must have refused');
    }

    if (step is FakeTransport) return step;
    throw step;
  }
}

/// Builds a reconnector over a script, recording what it adopts.
({
  SessionReconnector reconnector,
  ManualScheduler scheduler,
  ScriptedConnector connector,
  List<SessionTransport> adopted,
}) buildReconnector(
  List<Object> script, {
  SshCredentials? credentials = testCredentials,
  ReconnectPolicy? policy,
  Future<void> Function(SessionTransport)? adopt,
}) {
  final scheduler = ManualScheduler();
  final connector = ScriptedConnector(script);
  final adopted = <SessionTransport>[];
  final reconnector = SessionReconnector(
    host: testHost,
    support: ReconnectSupport(
      loadCredentials: (_) async => credentials,
      connect: connector.connect,
    ),
    adopt: adopt ??
        (transport) async {
          adopted.add(transport);
        },
    policy: policy,
    scheduler: scheduler.schedule,
  );
  return (
    reconnector: reconnector,
    scheduler: scheduler,
    connector: connector,
    adopted: adopted,
  );
}

void main() {
  group('the reconnector', () {
    test('waits before its first attempt rather than dialling instantly', () {
      final harness = buildReconnector([FakeTransport()]);
      addTearDown(harness.reconnector.dispose);

      harness.reconnector.begin();

      expect(harness.scheduler.delays, const [Duration(seconds: 2)]);
      expect(harness.connector.calls, 0);
      expect(harness.reconnector.phase, ReconnectPhase.waiting);
      expect(harness.reconnector.isActive, isTrue);
    });

    test('adopts the transport it gets, in the session it already had',
        () async {
      final replacement = FakeTransport(name: 'second');
      final harness = buildReconnector([replacement]);
      addTearDown(harness.reconnector.dispose);

      harness.reconnector.begin();
      await harness.scheduler.fire();

      expect(harness.adopted, [replacement]);
      expect(harness.reconnector.phase, ReconnectPhase.connected);
      expect(harness.reconnector.isActive, isFalse);
      expect(harness.reconnector.attempts, 1);
    });

    test('climbs the ladder past transient failures', () async {
      final replacement = FakeTransport(name: 'third');
      final harness = buildReconnector([
        const SshConnectionException('No route to host.'),
        const SshConnectionException('No route to host.'),
        replacement,
      ]);
      addTearDown(harness.reconnector.dispose);

      harness.reconnector.begin();
      await harness.scheduler.fire();
      await harness.scheduler.fire();
      await harness.scheduler.fire();

      expect(harness.scheduler.delays, const [
        Duration(seconds: 2),
        Duration(seconds: 4),
        Duration(seconds: 8),
      ]);
      expect(harness.adopted, [replacement]);
    });

    test('gives up when the budget runs out, and says so', () async {
      final harness = buildReconnector(
        [const SshConnectionException('No route to host.')],
        policy: ReconnectPolicy(
          backoff: const [Duration(seconds: 1)],
          budget: const Duration(seconds: 2),
        ),
      );
      addTearDown(harness.reconnector.dispose);

      harness.reconnector.begin();
      await harness.scheduler.fire();
      await harness.scheduler.fire();

      expect(harness.connector.calls, 2);
      expect(harness.reconnector.hasGivenUp, isTrue);
      expect(harness.reconnector.isActive, isFalse);
      expect(harness.reconnector.message, contains('Could not reconnect'));
    });

    test('is not restarted by a second begin()', () {
      final harness = buildReconnector([FakeTransport()]);
      addTearDown(harness.reconnector.dispose);

      harness.reconnector.begin();
      harness.reconnector.begin();
      harness.reconnector.begin();

      expect(harness.scheduler.delays, const [Duration(seconds: 2)]);
    });

    test('publishes each phase change', () async {
      final harness = buildReconnector([FakeTransport()]);
      addTearDown(harness.reconnector.dispose);
      var notifications = 0;
      harness.reconnector.changes.listen((_) => notifications++);

      harness.reconnector.begin();
      await harness.scheduler.fire();

      // Scheduled, attempting, connected.
      expect(notifications, greaterThanOrEqualTo(3));
    });

    test('names the host and the attempt while it works', () async {
      final harness = buildReconnector([
        const SshConnectionException('No route to host.'),
        FakeTransport(),
      ]);
      addTearDown(harness.reconnector.dispose);

      harness.reconnector.begin();
      expect(harness.reconnector.message, contains('Connection lost'));
      expect(harness.reconnector.message, contains('Test box'));

      await harness.scheduler.fire();
      expect(harness.reconnector.message, contains('attempt 2'));
    });
  });

  group('an auth failure', () {
    test('stops after exactly one attempt', () async {
      final harness = buildReconnector([
        const SshAuthenticationException('Authentication failed for "dev".'),
      ]);
      addTearDown(harness.reconnector.dispose);

      harness.reconnector.begin();
      await harness.scheduler.fire();

      expect(harness.connector.calls, 1);
      expect(harness.scheduler.pendingCount, 0,
          reason: 'nothing may be queued to try again');
      expect(harness.reconnector.hasGivenUp, isTrue);
      expect(harness.reconnector.attempts, 1);
    });

    test('never retries however long the budget would allow', () async {
      final harness = buildReconnector([
        const SshAuthenticationException('Authentication failed for "dev".'),
      ]);
      addTearDown(harness.reconnector.dispose);

      harness.reconnector.begin();
      await harness.scheduler.fire();
      // Whatever else happens, nothing puts this back on the ladder.
      harness.reconnector.begin();
      await ManualScheduler.pump();

      expect(harness.connector.calls, 1);
      expect(harness.scheduler.delays.length, 1);
    });

    test('repeats the server\'s own explanation', () async {
      final harness = buildReconnector([
        const SshAuthenticationException('Authentication failed for "dev".'),
      ]);
      addTearDown(harness.reconnector.dispose);

      harness.reconnector.begin();
      await harness.scheduler.fire();

      expect(harness.reconnector.message, 'Authentication failed for "dev".');
    });
  });

  group('host keys', () {
    test('a changed key aborts, loudly, and is never accepted', () async {
      final harness = buildReconnector([HostKeyPromptKind.changed]);
      addTearDown(harness.reconnector.dispose);

      harness.reconnector.begin();
      await harness.scheduler.fire();

      // The prompt was offered — the TOFU flow ran — and refused.
      expect(harness.connector.promptsOffered, hasLength(1));
      expect(harness.reconnector.hasGivenUp, isTrue);
      expect(harness.reconnector.message, contains('CHANGED'));
      expect(harness.reconnector.message, contains('intercepting'));
      expect(harness.connector.calls, 1, reason: 'and is never retried');
      expect(harness.adopted, isEmpty);
    });

    test('an unknown key aborts and sends the user to the host list', () async {
      final harness = buildReconnector([HostKeyPromptKind.unknown]);
      addTearDown(harness.reconnector.dispose);

      harness.reconnector.begin();
      await harness.scheduler.fire();

      expect(harness.reconnector.hasGivenUp, isTrue);
      expect(harness.reconnector.message, contains('no longer in known hosts'));
      expect(harness.adopted, isEmpty);
    });

    test('a matching key never reaches a prompt at all', () async {
      // What an ordinary reconnect looks like: `HostKeyPolicy` finds the key
      // it already trusts and the verifier is never consulted.
      final harness = buildReconnector([FakeTransport()]);
      addTearDown(harness.reconnector.dispose);

      harness.reconnector.begin();
      await harness.scheduler.fire();

      expect(harness.connector.promptsOffered, isEmpty);
      expect(harness.adopted, hasLength(1));
    });
  });

  group('missing credentials', () {
    test('stop the schedule without a connect attempt', () async {
      final harness = buildReconnector([FakeTransport()], credentials: null);
      addTearDown(harness.reconnector.dispose);

      harness.reconnector.begin();
      await harness.scheduler.fire();

      expect(harness.connector.calls, 0);
      expect(harness.reconnector.hasGivenUp, isTrue);
      expect(harness.reconnector.message, contains('No saved credentials'));
    });
  });

  group('the user stopping it', () {
    test('cancels a wait before anything is dialled', () async {
      final harness = buildReconnector([FakeTransport()]);
      addTearDown(harness.reconnector.dispose);

      harness.reconnector.begin();
      harness.reconnector.cancel();
      await ManualScheduler.pump();

      expect(harness.reconnector.phase, ReconnectPhase.stopped);
      expect(harness.reconnector.isActive, isFalse);
      expect(harness.reconnector.message, isNull);
      expect(harness.connector.calls, 0);
    });

    test('closes a transport that arrived after the cancel', () async {
      final orphan = FakeTransport(name: 'orphan');
      final scheduler = ManualScheduler();
      final gate = Completer<SessionTransport>();
      final adopted = <SessionTransport>[];
      final reconnector = SessionReconnector(
        host: testHost,
        support: ReconnectSupport(
          loadCredentials: (_) async => testCredentials,
          // Hangs until the test lets it through, so the cancel lands while
          // the handshake is genuinely in flight.
          connect: ({
            required host,
            required credentials,
            required verifyHostKey,
          }) =>
              gate.future,
        ),
        adopt: (transport) async => adopted.add(transport),
        scheduler: scheduler.schedule,
      );
      addTearDown(reconnector.dispose);

      reconnector.begin();
      await scheduler.fire();
      reconnector.cancel();
      gate.complete(orphan);
      await ManualScheduler.pump();

      expect(adopted, isEmpty, reason: 'nobody is left to adopt it');
      expect(orphan.closeCount, 1, reason: 'and it must not be left open');
    });

    test('cannot be resumed', () async {
      final harness = buildReconnector([FakeTransport()]);
      addTearDown(harness.reconnector.dispose);

      harness.reconnector.begin();
      harness.reconnector.cancel();
      harness.reconnector.begin();
      await ManualScheduler.pump();

      expect(harness.scheduler.delays, hasLength(1));
      expect(harness.connector.calls, 0);
    });
  });

  group('a session whose transport dies', () {
    /// A controller wired to a reconnector over a scripted connector, the way
    /// `SessionManager` wires one in production.
    ({
      SessionController controller,
      FakeTransport transport,
      ManualScheduler scheduler,
      ScriptedConnector connector,
    }) buildSession(List<Object> script) {
      final transport = FakeTransport();
      final scheduler = ManualScheduler();
      final connector = ScriptedConnector(script);
      final controller = SessionController(
        connection: transport,
        storage: UnusedStorage(),
        reconnect: ReconnectSupport(
          loadCredentials: (_) async => testCredentials,
          connect: connector.connect,
        ),
        reconnectScheduler: scheduler.schedule,
      );
      // What a `TerminalPane` does on its first layout. Without it the session
      // waits its full 1.5 s fallback for a size before opening any shell,
      // including the one a reconnect opens.
      controller.terminal.resize(100, 30);
      return (
        controller: controller,
        transport: transport,
        scheduler: scheduler,
        connector: connector,
      );
    }

    test('reconnects after the transport breaks', () async {
      final session = buildSession([FakeTransport(name: 'second')]);
      addTearDown(session.controller.dispose);

      session.transport.drop(const SocketException('Connection reset'));
      await ManualScheduler.pump();

      expect(session.controller.isClosed, isTrue);
      expect(session.controller.isReconnecting, isTrue);
      expect(session.controller.reconnectMessage, contains('Reconnecting'));
    });

    test('does not reconnect after an orderly close', () async {
      final session = buildSession([FakeTransport(name: 'second')]);
      addTearDown(session.controller.dispose);

      // No error: the far end said goodbye. An idle timeout, an administrator,
      // or the user's own `exit` — none of them want dialling back.
      session.transport.drop();
      await ManualScheduler.pump();

      expect(session.controller.isClosed, isTrue);
      expect(session.controller.isReconnecting, isFalse);
      expect(session.scheduler.delays, isEmpty);
    });

    test('puts the new transport in the same session', () async {
      final replacement = FakeTransport(name: 'second');
      final session = buildSession([replacement]);
      addTearDown(session.controller.dispose);
      final terminal = session.controller.terminal;
      session.controller.terminal.write('build finished\r\n');

      session.transport.drop(const SocketException('Connection reset'));
      await ManualScheduler.pump();
      await session.scheduler.fire();

      expect(identical(session.controller.connection, replacement), isTrue);
      expect(session.controller.isClosed, isFalse);
      expect(session.controller.isReconnecting, isFalse);
      expect(session.controller.closeReason, isNull);
      // Same buffer object, and the output the user was reading is still in
      // it — the scrollback is deliberately kept across a reconnect.
      expect(identical(session.controller.terminal, terminal), isTrue);
      expect(terminal.buffer.getText(), contains('build finished'));
      expect(terminal.buffer.getText(), contains('reconnected to Test box'));
    });

    test('keeps pinging, on the new transport', () async {
      final replacement = FakeTransport(name: 'second');
      final session = buildSession([replacement]);
      addTearDown(session.controller.dispose);

      session.transport.drop(const SocketException('Connection reset'));
      await ManualScheduler.pump();
      await session.scheduler.fire();

      expect(session.controller.isKeepaliveRunning, isTrue);
    });

    test('closes the dead transport it is replacing', () async {
      final session = buildSession([FakeTransport(name: 'second')]);
      addTearDown(session.controller.dispose);

      session.transport.drop(const SocketException('Connection reset'));
      await ManualScheduler.pump();
      await session.scheduler.fire();

      expect(session.transport.closeCount, greaterThan(0));
    });

    test('ignores the old transport dying again afterwards', () async {
      final replacement = FakeTransport(name: 'second');
      final session = buildSession([replacement]);
      addTearDown(session.controller.dispose);

      session.transport.drop(const SocketException('Connection reset'));
      await ManualScheduler.pump();
      await session.scheduler.fire();
      // The replacement is live; now the *old* socket finishes falling over.
      // A generation behind, and so nobody's business.
      replacement.drop(const SocketException('late error from the old socket'));
      await ManualScheduler.pump();

      // The new transport's own death is of course still honoured — this is
      // the replacement dropping, so the session really is closed again.
      expect(session.controller.isClosed, isTrue);
      expect(session.controller.reconnectAttempts, 1,
          reason: 'the schedule ended when it succeeded');
    });

    test('holds back the disconnect announcement while it is trying',
        () async {
      final session = buildSession([
        const SshAuthenticationException('Authentication failed for "dev".'),
      ]);
      addTearDown(session.controller.dispose);

      session.transport.drop(const SocketException('Connection reset'));
      await ManualScheduler.pump();

      // Mid-reconnect: a red "connection lost" toast would be a second,
      // contradictory account of what the banner is already saying.
      expect(session.controller.takeDisconnectAnnouncement(), isNull);

      await session.scheduler.fire();

      // Given up: now there is something to say, and it has not been lost.
      expect(session.controller.isReconnecting, isFalse);
      expect(
        session.controller.takeDisconnectAnnouncement(),
        contains('Connection lost'),
      );
    });

    test('closing the session stops any reconnect in flight', () async {
      final session = buildSession([FakeTransport(name: 'second')]);

      session.transport.drop(const SocketException('Connection reset'));
      await ManualScheduler.pump();
      expect(session.controller.isReconnecting, isTrue);

      // Closing the tab is the user saying they are done with this server.
      await session.controller.dispose();
      await ManualScheduler.pump();

      expect(session.controller.isReconnecting, isFalse);
      expect(session.connector.calls, 0);
    });

    test('a session with no reconnect support simply stays dropped', () async {
      final transport = FakeTransport();
      final controller = SessionController(
        connection: transport,
        storage: UnusedStorage(),
      );
      addTearDown(controller.dispose);

      transport.drop(const SocketException('Connection reset'));
      await ManualScheduler.pump();

      expect(controller.isClosed, isTrue);
      expect(controller.isReconnecting, isFalse);
      expect(controller.reconnectMessage, isNull);
    });

    test('does not reconnect after the user typed exit', () async {
      // The requirement in full: a session the *user* ended must never be
      // dialled back, and some servers follow a clean `exit` by dropping the
      // TCP connection rudely — which on its own is indistinguishable from a
      // network fault.
      final transport = ShellTransport();
      final scheduler = ManualScheduler();
      final connector = ScriptedConnector([FakeTransport(name: 'second')]);
      final controller = SessionController(
        connection: transport,
        storage: UnusedStorage(),
        reconnect: ReconnectSupport(
          loadCredentials: (_) async => testCredentials,
          connect: connector.connect,
        ),
        reconnectScheduler: scheduler.schedule,
      );
      addTearDown(controller.dispose);
      controller.terminal.resize(100, 30);
      await controller.ensureShell();

      transport.shell.exit();
      await ManualScheduler.pump();
      // ...and only then does the transport fall over.
      transport.drop(const SocketException('Connection reset'));
      await ManualScheduler.pump();

      expect(controller.isClosed, isTrue);
      expect(controller.isReconnecting, isFalse);
      expect(scheduler.delays, isEmpty);
      expect(connector.calls, 0);
    });

    test('does reconnect when the shell dies with the transport', () async {
      // The contrast case: the shell channel never ended on its own, so this
      // is the network going away underneath a session nobody closed.
      final transport = ShellTransport();
      final scheduler = ManualScheduler();
      final connector = ScriptedConnector([FakeTransport(name: 'second')]);
      final controller = SessionController(
        connection: transport,
        storage: UnusedStorage(),
        reconnect: ReconnectSupport(
          loadCredentials: (_) async => testCredentials,
          connect: connector.connect,
        ),
        reconnectScheduler: scheduler.schedule,
      );
      addTearDown(controller.dispose);
      controller.terminal.resize(100, 30);
      await controller.ensureShell();

      transport.drop(const SocketException('Connection reset'));
      await ManualScheduler.pump();

      expect(controller.isReconnecting, isTrue);
      expect(scheduler.delays, const [Duration(seconds: 2)]);
    });

    test('the Stop button ends it', () async {
      final session = buildSession([FakeTransport(name: 'second')]);
      addTearDown(session.controller.dispose);

      session.transport.drop(const SocketException('Connection reset'));
      await ManualScheduler.pump();
      session.controller.stopReconnecting();
      await ManualScheduler.pump();

      expect(session.controller.isReconnecting, isFalse);
      expect(session.controller.reconnectGaveUp, isFalse);
      expect(session.connector.calls, 0);
    });
  });
}
