import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/services/device_storage.dart';
import 'package:secure_shell_go/services/session_controller.dart';
import 'package:secure_shell_go/services/ssh_service.dart';
import 'package:xterm/core.dart';

/// The seam broadcast input hangs off: `SessionController.onInputSent`.
///
/// What is being pinned down here is not "does a callback fire" but the much
/// narrower claim the broadcast feature rests on — that everything arriving
/// at this tap is *the user typing*, byte for byte as the shell received it,
/// and that nothing else arriving at it ever is.

/// A shell channel with no SSH underneath it.
class FakeShell implements SSHSession {
  final _stdout = StreamController<Uint8List>.broadcast();
  final _stderr = StreamController<Uint8List>.broadcast();
  final _done = Completer<void>();

  /// Everything written towards the remote process, decoded.
  final List<String> writes = [];

  @override
  Stream<Uint8List> get stdout => _stdout.stream;

  @override
  Stream<Uint8List> get stderr => _stderr.stream;

  @override
  Future<void> get done => _done.future;

  @override
  int? get exitCode => null;

  @override
  void write(Uint8List data) => writes.add(utf8.decode(data));

  @override
  void close() {}

  @override
  void resizeTerminal(int width, int height, [int? pw, int? ph]) {}

  /// Bytes arriving from the remote side, as the server would send them.
  void emit(String data) => _stdout.add(Uint8List.fromList(utf8.encode(data)));

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not faked');
}

class FakeTransport implements SessionTransport {
  final FakeShell shell = FakeShell();
  final _done = Completer<void>();

  @override
  Host get host => const Host(
        id: 'h1',
        label: 'Test box',
        hostname: 'example.com',
        port: 22,
        username: 'dev',
        authMethod: SshAuthMethod.password,
      );

  @override
  Future<void> get done => _done.future;

  @override
  bool get isClosed => false;

  @override
  Future<SSHSession> startShell({
    required int columns,
    required int rows,
    String terminalType = 'xterm-256color',
  }) async =>
      shell;

  @override
  Future<SftpClient> openSftp() => throw UnimplementedError();

  @override
  Future<SSHSession> execute(String command) => throw UnimplementedError();

  @override
  MutableSSHAgentHandler get agentSlot => _agentSlot;
  final _agentSlot = MutableSSHAgentHandler();

  @override
  Future<void> ping() async {}

  @override
  void close() {}
}

class UnusedStorage implements DeviceStorage {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('storage is not exercised in these tests');
}

Future<void> pump() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late FakeTransport transport;
  late SessionController controller;
  late List<String> tapped;

  setUp(() async {
    transport = FakeTransport();
    controller = SessionController(
      connection: transport,
      storage: UnusedStorage(),
    );
    tapped = [];
    controller.onInputSent = tapped.add;
    // What a `TerminalPane` does on its first layout.
    controller.terminal.resize(100, 30);
    await controller.ensureShell();
  });

  tearDown(() => controller.dispose());

  group('what reaches the tap', () {
    test('a typed line, exactly once', () async {
      controller.terminal.textInput('ls -al\r');

      expect(tapped, ['ls -al\r']);
      expect(transport.shell.writes, ['ls -al\r']);
    });

    test('a key-bar escape sequence', () async {
      controller.terminal.keyInput(TerminalKey.arrowUp);
      controller.terminal.keyInput(TerminalKey.keyC, ctrl: true);

      expect(tapped, hasLength(2));
      expect(tapped.first, '\x1b[A');
      expect(tapped.last, '\x03');
      expect(transport.shell.writes, tapped);
    });

    test('a paste, as the single write the terminal made of it', () async {
      controller.terminal.paste('echo one\necho two\n');

      expect(tapped, ['echo one\necho two\n']);
      expect(transport.shell.writes, tapped);
    });

    test('the rewritten keystroke, not the original', () async {
      // Standing in for the extra-key bar's sticky Ctrl, which rewrites `c`
      // into ^C on its way past. A broadcast has to carry what was actually
      // sent, or the other panes get a literal "c" while this one gets SIGINT.
      controller.transformInput = (data) => data == 'c' ? '\x03' : data;

      controller.terminal.textInput('c');

      expect(tapped, ['\x03']);
      expect(transport.shell.writes, ['\x03']);
    });
  });

  group('what must never reach the tap', () {
    test('the terminal\'s reply to a device-attributes query', () async {
      // `vim`, `htop` and friends send this on startup. The terminal answers
      // it through the very same callback keystrokes use — and the answer is
      // meaningless in anybody else's shell.
      transport.shell.emit('\x1b[c');
      await pump();

      expect(
        transport.shell.writes,
        isNotEmpty,
        reason: 'the query is still answered, on this session',
      );
      expect(transport.shell.writes.first, startsWith('\x1b['));
      expect(tapped, isEmpty, reason: 'but it is not input');
    });

    test('the terminal\'s reply to a cursor-position query', () async {
      transport.shell.emit('\x1b[6n');
      await pump();

      expect(transport.shell.writes, isNotEmpty);
      expect(tapped, isEmpty);
    });

    test('ordinary remote output, which produces no reply at all', () async {
      transport.shell.emit('total 0\r\n');
      await pump();

      expect(transport.shell.writes, isEmpty);
      expect(tapped, isEmpty);
    });

    test('a reply prompted by output that also contains a keystroke echo',
        () async {
      // The realistic shape: the shell echoes what was typed and the program
      // asks its question in the same chunk. Only the question produces a
      // write, and none of it is input.
      transport.shell.emit('ls -al\r\n\x1b[c');
      await pump();

      expect(tapped, isEmpty);
      expect(transport.shell.writes, hasLength(1));
    });

    test('and the tap works again straight afterwards', () async {
      transport.shell.emit('\x1b[c');
      await pump();
      transport.shell.writes.clear();

      controller.terminal.textInput('w\r');

      expect(tapped, ['w\r'], reason: 'the guard must not latch');
      expect(transport.shell.writes, ['w\r']);
    });
  });

  group('with no tap installed', () {
    test('typing still reaches the shell', () async {
      controller.onInputSent = null;

      controller.terminal.textInput('uptime\r');

      expect(transport.shell.writes, ['uptime\r']);
    });
  });
}
