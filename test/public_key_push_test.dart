import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
// The concrete SSHChannel/SSHChannelController aren't part of dartssh2's
// public surface (dartssh2.dart never exports ssh_channel.dart) — this test
// reaches in anyway, once, to build an inert channel so a *real* SSHSession
// can be scripted (see _ScriptedSession below). That is the only way to
// satisfy `SessionTransport.execute`'s return type without a live connection;
// production code never does this — see public_key_push.dart, which only
// ever consumes a transport it is handed.
// ignore: implementation_imports
import 'package:dartssh2/src/ssh_channel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/services/known_hosts_service.dart';
import 'package:secure_shell_go/services/public_key_push.dart';
import 'package:secure_shell_go/services/ssh_service.dart';

const _line = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBogus secureshellgo@box';

void main() {
  group('PublicKeyPushCommands — golden strings', () {
    test('prepareDirectory', () {
      expect(
        PublicKeyPushCommands.prepareDirectory,
        'mkdir -p ~/.ssh && chmod 700 ~/.ssh',
      );
    });

    test('securePermissions', () {
      expect(
        PublicKeyPushCommands.securePermissions,
        'chmod 600 ~/.ssh/authorized_keys',
      );
    });

    test('appendIfMissing quotes the line as a single shell literal', () {
      expect(
        PublicKeyPushCommands.appendIfMissing(_line),
        "LINE='$_line'; "
        'grep -qxF "\$LINE" ~/.ssh/authorized_keys 2>/dev/null || '
        'printf \'%s\\n\' "\$LINE" >> ~/.ssh/authorized_keys',
      );
    });

    test('verify quotes the line the same way, unsuppressed', () {
      expect(
        PublicKeyPushCommands.verify(_line),
        "LINE='$_line'; grep -qxF \"\$LINE\" ~/.ssh/authorized_keys",
      );
    });

    test('an embedded single quote is escaped as \'\\\'\'', () {
      const tricky = "ssh-ed25519 AAAA o'brien's key";
      expect(
        PublicKeyPushCommands.appendIfMissing(tricky),
        "LINE='ssh-ed25519 AAAA o'\\''brien'\\''s key'; "
        'grep -qxF "\$LINE" ~/.ssh/authorized_keys 2>/dev/null || '
        'printf \'%s\\n\' "\$LINE" >> ~/.ssh/authorized_keys',
      );
    });
  });

  group('PublicKeyPushCommands — run for real, against a scratch \$HOME', () {
    // Every one of these runs through an *actual* POSIX shell with HOME
    // pointed at a throwaway directory, never the real one — proof the
    // commands do what they claim against a real ~ expansion and a real
    // grep/printf/chmod, without ever touching this machine's own
    // ~/.ssh/authorized_keys.
    late Directory home;

    setUp(() async {
      home = await Directory.systemTemp.createTemp('pkp_home');
    });

    tearDown(() async {
      if (await home.exists()) await home.delete(recursive: true);
    });

    Future<ProcessResult> sh(String command) {
      return Process.run(
        'sh',
        ['-c', command],
        environment: {'HOME': home.path},
      );
    }

    File authorizedKeys() => File('${home.path}/.ssh/authorized_keys');

    test('prepareDirectory creates ~/.ssh with mode 700', () async {
      final result = await sh(PublicKeyPushCommands.prepareDirectory);
      expect(result.exitCode, 0, reason: result.stderr.toString());

      final stat = await Directory('${home.path}/.ssh').stat();
      expect(stat.modeString().substring(0, 9), 'rwx------');
    });

    test('appendIfMissing creates the file and adds the line once', () async {
      await sh(PublicKeyPushCommands.prepareDirectory);

      final first = await sh(PublicKeyPushCommands.appendIfMissing(_line));
      expect(first.exitCode, 0, reason: first.stderr.toString());
      expect((await authorizedKeys().readAsString()).trim(), _line);

      // Running it again must not duplicate the line.
      final second = await sh(PublicKeyPushCommands.appendIfMissing(_line));
      expect(second.exitCode, 0, reason: second.stderr.toString());
      final lines = (await authorizedKeys().readAsString())
          .split('\n')
          .where((l) => l.isNotEmpty)
          .toList();
      expect(lines, [_line]);
    });

    test('appendIfMissing preserves an existing unrelated line', () async {
      await sh(PublicKeyPushCommands.prepareDirectory);
      await authorizedKeys().writeAsString('ssh-rsa AAAAsomeoneElse other@box\n');

      await sh(PublicKeyPushCommands.appendIfMissing(_line));

      final lines = (await authorizedKeys().readAsString())
          .split('\n')
          .where((l) => l.isNotEmpty)
          .toList();
      expect(lines, ['ssh-rsa AAAAsomeoneElse other@box', _line]);
    });

    test('securePermissions sets mode 600 on authorized_keys', () async {
      await sh(PublicKeyPushCommands.prepareDirectory);
      await sh(PublicKeyPushCommands.appendIfMissing(_line));

      final result = await sh(PublicKeyPushCommands.securePermissions);
      expect(result.exitCode, 0, reason: result.stderr.toString());

      final stat = await authorizedKeys().stat();
      expect(stat.modeString().substring(0, 9), 'rw-------');
    });

    test('verify succeeds once the line is present, fails before', () async {
      await sh(PublicKeyPushCommands.prepareDirectory);

      final before = await sh(PublicKeyPushCommands.verify(_line));
      expect(before.exitCode, isNot(0));

      await sh(PublicKeyPushCommands.appendIfMissing(_line));

      final after = await sh(PublicKeyPushCommands.verify(_line));
      expect(after.exitCode, 0);
    });

    test('shell metacharacters in the comment are never executed', () async {
      const payload =
          r'ssh-ed25519 AAAAC3 evil"; touch $HOME/pwned; echo "`id`';
      await sh(PublicKeyPushCommands.prepareDirectory);

      final result = await sh(PublicKeyPushCommands.appendIfMissing(payload));
      expect(result.exitCode, 0, reason: result.stderr.toString());

      // The line landed byte-for-byte, and nothing it contains ran as a
      // command — the whole point of routing it through a single-quoted
      // shell literal instead of raw interpolation.
      expect((await authorizedKeys().readAsString()).trim(), payload);
      expect(await File('${home.path}/pwned').exists(), isFalse);
    });
  });

  group('PublicKeyPushService.installOverTransport', () {
    test('all four steps run in order and succeed', () async {
      final transport = _ScriptedTransport(const [0, 0, 0, 0]);

      await const PublicKeyPushService().installOverTransport(
        transport: transport,
        publicKeyLine: _line,
      );

      expect(transport.commands, [
        PublicKeyPushCommands.prepareDirectory,
        PublicKeyPushCommands.appendIfMissing(_line),
        PublicKeyPushCommands.securePermissions,
        PublicKeyPushCommands.verify(_line),
      ]);
    });

    test('a failed prepareDirectory stops before any later step', () async {
      final transport = _ScriptedTransport(const [1]);

      await expectLater(
        const PublicKeyPushService().installOverTransport(
          transport: transport,
          publicKeyLine: _line,
        ),
        throwsA(
          isA<PublicKeyPushFailure>()
              .having((e) => e.step, 'step', PublicKeyPushStep.prepareDirectory),
        ),
      );
      expect(transport.commands, hasLength(1));
    });

    test('a failed append is reported as appendKey, not a generic error',
        () async {
      final transport = _ScriptedTransport(const [0, 1], stderrText: 'no perm');

      await expectLater(
        const PublicKeyPushService().installOverTransport(
          transport: transport,
          publicKeyLine: _line,
        ),
        throwsA(
          isA<PublicKeyPushFailure>()
              .having((e) => e.step, 'step', PublicKeyPushStep.appendKey)
              .having((e) => e.details, 'details', contains('no perm')),
        ),
      );
      expect(transport.commands, hasLength(2));
    });

    test('a failed chmod is reported as securePermissions', () async {
      final transport = _ScriptedTransport(const [0, 0, 1]);

      await expectLater(
        const PublicKeyPushService().installOverTransport(
          transport: transport,
          publicKeyLine: _line,
        ),
        throwsA(
          isA<PublicKeyPushFailure>().having(
            (e) => e.step,
            'step',
            PublicKeyPushStep.securePermissions,
          ),
        ),
      );
      expect(transport.commands, hasLength(3));
    });

    test('a failed final grep is reported as verify, after all writes ran',
        () async {
      final transport = _ScriptedTransport(const [0, 0, 0, 1]);

      await expectLater(
        const PublicKeyPushService().installOverTransport(
          transport: transport,
          publicKeyLine: _line,
        ),
        throwsA(
          isA<PublicKeyPushFailure>()
              .having((e) => e.step, 'step', PublicKeyPushStep.verify),
        ),
      );
      expect(transport.commands, hasLength(4));
    });
  });

  group('PublicKeyPushService.installWithPassword', () {
    test('a connect failure is reported as step "connect"', () async {
      final tempDir =
          await Directory.systemTemp.createTemp('public_key_push_test');
      addTearDown(() => tempDir.delete(recursive: true));

      final sshService = SshService(
        knownHosts: KnownHostsService(
          file: File('${tempDir.path}/known_hosts.json'),
        ),
      );

      // A host saved for key auth: proves installWithPassword forces
      // password auth itself rather than trusting the stored authMethod —
      // if it did not, SshService.connect would refuse with "Paste a
      // private key to connect." before ever touching the network, which
      // is a different, distinguishable failure from the one asserted
      // below.
      const host = Host(
        id: 'h1',
        label: 'test',
        hostname: '127.0.0.1',
        port: 1, // refused instantly; see ssh_service_test.dart.
        username: 'nobody',
        authMethod: SshAuthMethod.privateKey,
      );

      await expectLater(
        const PublicKeyPushService().installWithPassword(
          sshService: sshService,
          host: host,
          password: 'whatever',
          publicKeyLine: _line,
          verifyHostKey: (_) async => true,
        ),
        throwsA(
          isA<PublicKeyPushFailure>()
              .having((e) => e.step, 'step', PublicKeyPushStep.connect)
              .having(
                (e) => e.message,
                'message',
                isNot(contains('private key')),
              ),
        ),
      );
    });
  });
}

/// A [SessionTransport] whose `execute` hands back a scripted [SSHSession]
/// instead of a live channel — the exit code for the Nth call is
/// `exitCodes[n]` (or 0 once the list runs out), and every command string it
/// was asked to run is recorded for assertion.
class _ScriptedTransport implements SessionTransport {
  _ScriptedTransport(this._exitCodes, {this.stderrText = 'boom'});

  final List<int> _exitCodes;
  final String stderrText;
  final List<String> commands = [];

  @override
  Future<SSHSession> execute(String command) async {
    final index = commands.length;
    commands.add(command);
    final code = index < _exitCodes.length ? _exitCodes[index] : 0;
    return _ScriptedSession(
      exitCode: code,
      stderrText: code == 0 ? '' : stderrText,
    );
  }

  @override
  Host get host => throw UnimplementedError();

  @override
  Future<void> get done => throw UnimplementedError();

  @override
  bool get isClosed => false;

  @override
  Future<SSHSession> startShell({
    required int columns,
    required int rows,
    String terminalType = 'xterm-256color',
  }) =>
      throw UnimplementedError();

  @override
  Future<SftpClient> openSftp() => throw UnimplementedError();

  @override
  MutableSSHAgentHandler get agentSlot => throw UnimplementedError();

  @override
  Future<void> ping() => throw UnimplementedError();

  @override
  void close() {}
}

/// A real [SSHSession] wired to a channel that is never actually connected to
/// anything, with every member the push service reads (`stdin`, `stdout`,
/// `stderr`, `waitForExit`) overridden to scripted values. Exists only so a
/// test can drive [PublicKeyPushService] without a live SSH server — see the
/// `implementation_imports` note at the top of this file for why an inert
/// channel is needed at all.
class _ScriptedSession extends SSHSession {
  _ScriptedSession({required this.exitCode, this.stderrText = ''})
      : super(_inertChannel());

  @override
  final int? exitCode;
  final String stderrText;

  // A fresh sink that is actually listened to (drained), so closing it
  // completes instead of waiting forever for a subscriber that never comes —
  // the real SSHSession's stdin is listened to by its own constructor
  // (piped to the channel); this stands in for that here.
  final StreamController<Uint8List> _stdin = StreamController<Uint8List>()
    ..stream.drain<void>();

  @override
  StreamSink<Uint8List> get stdin => _stdin.sink;

  @override
  Stream<Uint8List> get stdout => const Stream.empty();

  @override
  Stream<Uint8List> get stderr =>
      Stream.value(Uint8List.fromList(utf8.encode(stderrText)));

  @override
  Future<int?> waitForExit({Duration? timeout}) async => exitCode;

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
