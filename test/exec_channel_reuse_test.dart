import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/models/remote_entry.dart';
import 'package:secure_shell_go/services/device_storage.dart';
import 'package:secure_shell_go/services/direct_remote_copy.dart';
import 'package:secure_shell_go/services/known_hosts_service.dart';
import 'package:secure_shell_go/services/log_tail.dart';
import 'package:secure_shell_go/services/public_key_push.dart';
import 'package:secure_shell_go/services/remote_exec.dart';
import 'package:secure_shell_go/services/server_probe.dart';
import 'package:secure_shell_go/services/session_controller.dart';
import 'package:secure_shell_go/services/sftp_service.dart';
import 'package:secure_shell_go/services/ssh_keygen.dart';
import 'package:secure_shell_go/services/ssh_service.dart';

import 'fake_exec_session.dart';

/// Every exec-channel feature has to survive past the *first* command on a
/// connection.
///
/// The bug this guards against: `SSHClient.execute` sends
/// `auth-agent-req@openssh.com` on every session channel whenever the client
/// was built with an agent handler, and throws `SSHChannelRequestError` when
/// the server refuses. OpenSSH grants that request once per connection, so a
/// session client born with a handler ran exactly one exec and then failed
/// every stats poll, log tail, service action and public-key push after it —
/// against a real server, while every fake in the suite was perfectly happy.
///
/// So the fix is a shape, and this file asserts the shape: session
/// connections carry no agent handler, and the one feature that needs
/// forwarding — the direct server-to-server copy — dials a connection of its
/// own for its single exec. [FakeExecTransport] now models the server's
/// once-per-connection grant, which is what lets the first group below be an
/// honest test rather than a restatement of the production code.
void main() {
  group('a session connection has no agent slot, so its execs repeat', () {
    test('five sequential probes on one transport all succeed', () async {
      final transport = FakeExecTransport(stdout: 'ok\n');
      expect(transport.agentSlot, isNull);

      for (var i = 0; i < 5; i++) {
        final result = await RemoteExec.run(transport, 'echo ok');
        expect(result.exitCode, 0, reason: 'exec #${i + 1} should succeed');
      }
      expect(transport.commands, hasLength(5));
    });

    test('the four-step public key push completes', () async {
      final transport = FakeExecTransport();
      await const PublicKeyPushService().installOverTransport(
        transport: transport,
        publicKeyLine: 'ssh-ed25519 AAAA test@example',
      );
      expect(transport.commands, hasLength(4));
    });

    test('a log tail opens after a probe has already run', () async {
      // The tail exec is the *second* channel on the connection — the probe
      // for readability comes first — which is why tailing never once worked
      // against a real server.
      final transport = FakeExecTransport();
      final tail = await LogTailSession.open(transport, '/var/log/syslog');
      addTearDown(tail.dispose);
      expect(transport.commands, hasLength(2));
      expect(transport.commands.last, contains('tail -n'));
    });
  });

  group('a connection that does carry one loses every exec after the first',
      () {
    // Proof that the group above is testing something: the same fake, with a
    // slot, reproduces the reported failure exactly.
    test('exec #1 succeeds and exec #2 is refused', () async {
      final transport = FakeExecTransport(agentForwarding: true);
      expect(transport.agentSlot, isNotNull);

      await transport.execute('first');
      expect(
        transport.execute('second'),
        throwsA(
          isA<SSHChannelRequestError>().having(
            (e) => e.message,
            'message',
            contains('agent forwarding'),
          ),
        ),
      );
    });

    test('a stats poll on such a connection fails on the second read',
        () async {
      final transport = FakeExecTransport(
        agentForwarding: true,
        stdout: '#=ssg=host\nbox\n',
      );
      await const ServerProbe().read(transport);
      expect(
        const ServerProbe().read(transport),
        throwsA(isA<MonitorFailure>()),
      );
    });
  });

  group('the direct copy path dials its own connection for its one exec', () {
    late Host destHost;
    late SshCredentials destCredentials;

    // B's host key as this device verified it, and the line `ssh-keyscan`
    // on A prints for the same key. The session transport answers every
    // exec with [keyscan]; the only exec it is asked for is the scan.
    final destKey = _verifiedKey('ssh-ed25519', 'b host key');
    final keyscan = 'b.example ssh-ed25519 ${_blob('b host key')}\n';

    setUp(() {
      final generated = SshKeygen.generateEd25519(comment: 'test@example');
      destCredentials = SshCredentials(privateKeyPem: generated.privateKeyPem);
      destHost = const Host(
        id: 'dest',
        label: 'B',
        hostname: 'b.example',
        port: 22,
        username: 'root',
        authMethod: SshAuthMethod.privateKey,
      );
    });

    test('the exec runs on the dialled transport, never on the session', ()
        async {
      final session = FakeExecTransport(stdout: keyscan);
      final dialled = FakeExecTransport(
        agentForwarding: true,
        // The direct copy path waits on `done`, not `waitForExit`.
        respond: (_) => FakeExecSession(exits: true),
      );
      final controller = SessionController(
        connection: session,
        storage: _NoStorage(),
        openFileSystem: () async => _StubFs({'/src/file.bin': 12}),
        resolveDestinationCredentials: (_) async => destCredentials,
        connectWithAgentForwarding: (_, _) async => dialled,
      );
      addTearDown(controller.dispose);

      final outcome = await copyRemoteFileDirect(
        source: controller,
        destHost: destHost,
        destCredentials: destCredentials,
        destinationFs: _StubFs({'/dst/file.bin': 12}),
        sourcePath: '/src/file.bin',
        destinationPath: '/dst/file.bin',
        destinationHostKey: destKey,
      );

      expect(outcome.bytesCopied, 12);
      // The whole point: the session's own connection ran only the host-key
      // scan, which needs no agent, so nothing it does later is spent on a
      // one-shot channel. The forwarded exec ran on the dialled connection.
      expect(session.commands.single, startsWith('ssh-keyscan'));
      expect(dialled.commands, hasLength(1));
      expect(dialled.commands.single, contains('sftp'));
    });

    test('the key is installed only for that exec, and hung up after', ()
        async {
      final session = FakeExecTransport(stdout: keyscan);
      final dialled = FakeExecTransport(
        agentForwarding: true,
        // The direct copy path waits on `done`, not `waitForExit`.
        respond: (_) => FakeExecSession(exits: true),
      );
      final controller = SessionController(
        connection: session,
        storage: _NoStorage(),
        openFileSystem: () async => _StubFs({'/src/file.bin': 12}),
        resolveDestinationCredentials: (_) async => destCredentials,
        connectWithAgentForwarding: (_, _) async => dialled,
      );
      addTearDown(controller.dispose);

      await copyRemoteFileDirect(
        source: controller,
        destHost: destHost,
        destCredentials: destCredentials,
        destinationFs: _StubFs({'/dst/file.bin': 12}),
        sourcePath: '/src/file.bin',
        destinationPath: '/dst/file.bin',
        destinationHostKey: destKey,
      );

      expect(dialled.agentInstalledAtExec, [true],
          reason: 'the destination key must be in the slot for the exec');
      expect(dialled.agentSlot!.isInstalled, isFalse,
          reason: 'and out of it afterwards');
      expect(dialled.closed, isTrue,
          reason: 'the transfer owns that connection and must hang it up');
      expect(session.isClosed, isFalse,
          reason: 'the session connection is not the transfer\'s to close');
    });

    test('a second transfer on the same session gets a second connection',
        () async {
      // Under the old shape this was impossible even in principle: the
      // session's single client had already spent its one agent grant.
      final session = FakeExecTransport(stdout: keyscan);
      final dialled = <FakeExecTransport>[];
      final controller = SessionController(
        connection: session,
        storage: _NoStorage(),
        openFileSystem: () async => _StubFs({'/src/file.bin': 12}),
        resolveDestinationCredentials: (_) async => destCredentials,
        connectWithAgentForwarding: (_, _) async {
          final transport = FakeExecTransport(
            agentForwarding: true,
            respond: (_) => FakeExecSession(exits: true),
          );
          dialled.add(transport);
          return transport;
        },
      );
      addTearDown(controller.dispose);

      for (var i = 0; i < 2; i++) {
        await copyRemoteFileDirect(
          source: controller,
          destHost: destHost,
          destCredentials: destCredentials,
          destinationFs: _StubFs({'/dst/file.bin': 12}),
          sourcePath: '/src/file.bin',
          destinationPath: '/dst/file.bin',
          destinationHostKey: destKey,
        );
      }

      expect(dialled, hasLength(2));
      expect(dialled.every((t) => t.commands.length == 1), isTrue);
      expect(dialled.every((t) => t.closed), isTrue);
    });

    test('no connector means a relay fallback, not a failed transfer',
        () async {
      final session = FakeExecTransport(stdout: keyscan);
      final controller = SessionController(
        connection: session,
        storage: _NoStorage(),
        openFileSystem: () async => _StubFs({'/src/file.bin': 12}),
        resolveDestinationCredentials: (_) async => destCredentials,
      );
      addTearDown(controller.dispose);

      await expectLater(
        copyRemoteFileDirect(
          source: controller,
          destHost: destHost,
          destCredentials: destCredentials,
          destinationFs: _StubFs({'/dst/file.bin': 12}),
          sourcePath: '/src/file.bin',
          destinationPath: '/dst/file.bin',
          destinationHostKey: destKey,
        ),
        throwsA(
          isA<SSHDirectCopyUnavailable>().having(
            (e) => e.reason,
            'reason',
            // A fallback trigger, not the security-event one — the executor
            // is expected to take the relay path from here.
            DirectCopyUnavailableReason.noForwardingConnection,
          ),
        ),
      );
      expect(session.commands.single, startsWith('ssh-keyscan'));
    });

    group('the destination host key', () {
      late FakeExecTransport dialled;
      late SessionController controller;

      SessionController controllerAnsweringScan(String scanOutput) {
        dialled = FakeExecTransport(
          agentForwarding: true,
          respond: (_) => FakeExecSession(exits: true),
        );
        controller = SessionController(
          connection: FakeExecTransport(stdout: scanOutput),
          storage: _NoStorage(),
          openFileSystem: () async => _StubFs({'/src/file.bin': 12}),
          resolveDestinationCredentials: (_) async => destCredentials,
          connectWithAgentForwarding: (_, _) async => dialled,
        );
        addTearDown(controller.dispose);
        return controller;
      }

      Future<void> copy({VerifiedHostKey? key}) => copyRemoteFileDirect(
            source: controller,
            destHost: destHost,
            destCredentials: destCredentials,
            destinationFs: _StubFs({'/dst/file.bin': 12}),
            sourcePath: '/src/file.bin',
            destinationPath: '/dst/file.bin',
            destinationHostKey: key,
          );

      Matcher unavailable(DirectCopyUnavailableReason reason) => throwsA(
            isA<SSHDirectCopyUnavailable>()
                .having((e) => e.reason, 'reason', reason),
          );

      test('pins the source\'s sftp to the verified key and nothing else',
          () async {
        // A second, unrelated key type in the scan must not be pinned.
        controllerAnsweringScan(
          '# b.example:22 SSH-2.0-OpenSSH_9.6\n'
          '$keyscan'
          'b.example ssh-rsa ${_blob('some other key')}\n',
        );
        await copy(key: destKey);

        final command = dialled.commands.single;
        expect(command, contains('StrictHostKeyChecking=yes'));
        expect(command, contains('GlobalKnownHostsFile=/dev/null'));
        expect(command, contains('mktemp'));
        expect(command, contains(keyscan.trim()));
        expect(command, isNot(contains(_blob('some other key'))));
        expect(command, isNot(contains('accept-new')));
        expect(command, isNot(contains('ForwardAgent')));
      });

      test('a different key seen from the source is refused, not relayed',
          () async {
        controllerAnsweringScan(
          'b.example ssh-ed25519 ${_blob('an interceptor')}\n',
        );
        await expectLater(
          copy(key: destKey),
          unavailable(DirectCopyUnavailableReason.hostKeyMismatch),
        );
        expect(dialled.commands, isEmpty,
            reason: 'nothing may be sent towards the impostor');
      });

      test('no verified key on this device falls back to relay', () async {
        controllerAnsweringScan(keyscan);
        await expectLater(
          copy(key: null),
          unavailable(DirectCopyUnavailableReason.hostKeyUnverifiable),
        );
        expect(dialled.commands, isEmpty);
      });

      test('a scan that shows no key of that type falls back to relay',
          () async {
        controllerAnsweringScan('');
        await expectLater(
          copy(key: destKey),
          unavailable(DirectCopyUnavailableReason.hostKeyUnverifiable),
        );
        expect(dialled.commands, isEmpty);
      });

      test('a refused folder copy leaves the destination untouched',
          () async {
        controllerAnsweringScan(
          'b.example ssh-ed25519 ${_blob('an interceptor')}\n',
        );
        final destination = _RecordingFs();
        await expectLater(
          copyRemoteDirectoryDirect(
            source: controller,
            destHost: destHost,
            destCredentials: destCredentials,
            destinationFs: destination,
            sourceDirectory: '/src/folder',
            destinationDirectory: '/dst/folder',
            destinationHostKey: destKey,
            // Overwrite clears the destination tree first; the refusal has
            // to land before that.
            overwrite: true,
          ),
          unavailable(DirectCopyUnavailableReason.hostKeyMismatch),
        );
        expect(destination.calls, isEmpty);
      });
    });
  });

  // The shape only holds if `SshService` really builds the two kinds of
  // client differently, and no fake can prove that. These run against the
  // demo pair and skip cleanly when it is not up.
  group('against the demo server', () {
    final demo = _probeDemoA();

    Future<SshConnection> connect({bool agentForwarding = false}) {
      final temp = Directory.systemTemp.createTempSync('exec_reuse');
      addTearDown(() => temp.deleteSync(recursive: true));
      return SshService(
        knownHosts:
            KnownHostsService(file: File('${temp.path}/known_hosts.json')),
      ).connect(
        host: demo!.host,
        credentials: SshCredentials(privateKeyPem: demo.keyPem),
        verifyHostKey: (_) async => true,
        agentForwarding: agentForwarding,
      );
    }

    test('an ordinary connect builds a client with no agent handler',
        () async {
      final connection = await connect();
      addTearDown(connection.close);
      expect(connection.agentSlot, isNull);
      expect(connection.client.agentHandler, isNull);
    },
        skip: demo == null
            ? 'demo servers not running (see ~/ssgo-demo/start-demo.sh)'
            : null,
        timeout: const Timeout(Duration(seconds: 60)));

    test('agentForwarding: true is the one that gets a handler', () async {
      final connection = await connect(agentForwarding: true);
      addTearDown(connection.close);
      expect(connection.agentSlot, isNotNull);
      expect(connection.client.agentHandler, same(connection.agentSlot));
    },
        skip: demo == null
            ? 'demo servers not running (see ~/ssgo-demo/start-demo.sh)'
            : null,
        timeout: const Timeout(Duration(seconds: 60)));

    test('five sequential execs on one real connection all succeed', () async {
      final connection = await connect();
      addTearDown(connection.close);
      for (var i = 1; i <= 5; i++) {
        final result = await RemoteExec.run(connection, 'echo exec-$i');
        expect(result.exitCode, 0, reason: 'exec #$i');
        expect(result.stdout.trim(), 'exec-$i');
      }
    },
        skip: demo == null
            ? 'demo servers not running (see ~/ssgo-demo/start-demo.sh)'
            : null,
        timeout: const Timeout(Duration(seconds: 60)));

    test('and a real stats probe answers on every one of five polls',
        () async {
      // Covers the other half of what the live verification caught: the
      // probe's section markers begin with `#`, so unquoted they turned the
      // whole command line into a comment and every poll came back empty.
      final connection = await connect();
      addTearDown(connection.close);
      for (var i = 1; i <= 5; i++) {
        final stats = await const ServerProbe().read(connection);
        expect(stats.isEmpty, isFalse, reason: 'poll #$i');
        expect(stats.kernel, isNotNull, reason: 'poll #$i');
      }
    },
        skip: demo == null
            ? 'demo servers not running (see ~/ssgo-demo/start-demo.sh)'
            : null,
        timeout: const Timeout(Duration(seconds: 60)));
  });
}

/// The demo server A, or null when the scaffolding is not running. Same
/// probe `direct_remote_copy_test.dart` uses, narrowed to the one host.
_DemoA? _probeDemoA() {
  final home = Platform.environment['HOME'];
  final username = Platform.environment['USER'];
  if (home == null || username == null) return null;
  final keyFile = File('$home/ssgo-demo/servers/keys/demo-key');
  if (!keyFile.existsSync()) return null;
  try {
    final probe = Process.runSync('bash', [
      '-c',
      'exec 3<>/dev/tcp/127.0.0.1/22301 && exec 3<&- 3>&-',
    ]);
    if (probe.exitCode != 0) return null;
  } catch (_) {
    return null;
  }
  return _DemoA(username: username, keyPem: keyFile.readAsStringSync());
}

class _DemoA {
  _DemoA({required this.username, required this.keyPem});

  final String username;
  final String keyPem;

  Host get host => Host(
        id: 'demo-a',
        label: 'demo-A',
        hostname: '127.0.0.1',
        port: 22301,
        username: username,
        authMethod: SshAuthMethod.privateKey,
      );
}

/// Answers `sizeOf` from a map and nothing else. The direct copy path's
/// verification is a size comparison on both sides; every other filesystem
/// call here would be a bug.
class _StubFs implements RemoteFileSystem {
  _StubFs(this._sizes);

  final Map<String, int> _sizes;

  @override
  Future<int?> sizeOf(String path) async => _sizes[path];

  @override
  Future<void> remove(String path) async {}

  @override
  Future<List<RemoteEntry>> list(String path) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// A destination filesystem that must not be touched: records every call.
class _RecordingFs implements RemoteFileSystem {
  final List<Symbol> calls = [];

  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls.add(invocation.memberName);
    return super.noSuchMethod(invocation);
  }
}

/// A stand-in host key blob, base64 as `ssh-keyscan` prints it.
String _blob(String seed) => base64.encode(utf8.encode(seed));

/// What this device would have recorded after verifying [_blob] of [seed].
VerifiedHostKey _verifiedKey(String type, String seed) {
  final digest = sha256.convert(utf8.encode(seed)).bytes;
  return VerifiedHostKey(
    keyType: type,
    fingerprint: 'SHA256:${base64.encode(digest).replaceAll('=', '')}',
  );
}

/// `SessionController` reaches for platform storage in its constructor; none
/// of these tests download anything.
class _NoStorage implements DeviceStorage {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
