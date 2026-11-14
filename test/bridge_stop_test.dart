import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/services/bridge/bridge_audit.dart';
import 'package:secure_shell_go/services/bridge/bridge_connections.dart';
import 'package:secure_shell_go/services/bridge/bridge_tools.dart';
import 'package:secure_shell_go/services/credential_store.dart';
import 'package:secure_shell_go/services/secure_storage_backend.dart';
import 'package:secure_shell_go/services/ssh_service.dart' show SessionTransport;

import 'fake_exec_session.dart';
import 'support/bridge_fakes.dart';

// How a bridge call is stopped: at its deadline, when its assistant is
// revoked, when the bridge is switched off — and that stopping it ends the
// work on the server rather than only the wait for it.

const String _probeOutput = '#=ssg=host\nweb1\n#=ssg=cpu\n4\n';

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('bridge_stop');
  });

  tearDown(() async {
    await temp.delete(recursive: true);
  });

  group('the supervised wrapper, against a real sh', () {
    final skip = File('/bin/sh').existsSync() ? null : 'needs /bin/sh';

    test('passes output and exit status through', () async {
      final out = await Process.run('/bin/sh', [
        '-c',
        BridgeCommands.supervised("echo out; echo err >&2; exit 3"),
      ]);
      expect(out.stdout, 'out\n');
      expect(out.stderr, 'err\n');
      expect(out.exitCode, 3);
    }, skip: skip);

    test('closing stdin ends the command and its children', () async {
      final dir = await temp.createTemp('sup');
      final marker = '${dir.path}/finished';
      final process = await Process.start('/bin/sh', [
        '-c',
        BridgeCommands.supervised(
          "sh -c 'sleep 2; touch \"\$0\"' '$marker' & sleep 2; touch '$marker'",
        ),
      ]);
      final exit = process.exitCode;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await process.stdin.close();
      final code = await exit.timeout(const Duration(seconds: 2));
      expect(code, isNot(0));
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      expect(File(marker).existsSync(), false);
    }, skip: skip);

    test('a hostile template argument is still only an argument', () async {
      final dir = await temp.createTemp('hostile');
      for (final h in [
        r'$(touch pwned)',
        '`touch pwned`',
        "'; touch pwned; '",
      ]) {
        await Process.run('/bin/sh', [
          '-c',
          BridgeCommands.supervised(BridgeCommands.tailFile(h, 1)),
        ], workingDirectory: dir.path);
      }
      expect(dir.listSync(), isEmpty);
    }, skip: skip);
  });

  test('every command reaches the server supervised', () async {
    final rig = BridgeToolsRig(temp);
    final web =
        rig.serve('web1', (_) => FakeExecSession(stdout: _probeOutput))
            as SupervisedFakeTransport;
    await rig.call('server_stats', {'host': 'web'});
    expect(web.rawCommands, hasLength(1));
    expect(web.rawCommands.single, startsWith('sh -c '));
    expect(web.sessions.single.stdinClosed, true);
    expect(web.sessions.single.wasClosed, true);
  });

  group('at the deadline', () {
    test(
      'a command still running is ended: stdin closed, channel closed',
      () async {
        final rig = BridgeToolsRig(
          temp,
          callTimeout: const Duration(milliseconds: 150),
        );
        final web = rig.serve(
          'web1',
          (_) => FakeExecSession(
            stdout: _probeOutput,
            exitDelay: const Duration(seconds: 5),
          ),
        );
        final r = await rig.call('server_stats', {'host': 'web'});
        expect(r.isError, true);
        expect(r.text, contains('took longer than'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(web.sessions.single.stdinClosed, true);
        expect(web.sessions.single.wasClosed, true);
        expect(rig.tools.running, 0);
        expect(rig.entries, hasLength(1));
      },
    );

    test('opening the channel is bounded, and a late channel is ended as it '
        'arrives', () async {
      final rig = BridgeToolsRig(
        temp,
        callTimeout: const Duration(milliseconds: 100),
      );
      final web = rig.serve(
        'web1',
        (_) => FakeExecSession(stdout: _probeOutput),
        delay: const Duration(milliseconds: 300),
      );
      final watch = Stopwatch()..start();
      final r = await rig.call('server_stats', {'host': 'web'});
      expect(watch.elapsedMilliseconds, lessThan(280));
      expect(r.isError, true);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(web.sessions.single.stdinClosed, true);
      expect(web.sessions.single.wasClosed, true);
    });
  });

  group('abandoning', () {
    test('a revoked client\'s running call is stopped on the server and '
        'answered with nothing it found', () async {
      final rig = BridgeToolsRig(temp);
      final web = rig.serve(
        'web1',
        (_) => FakeExecSession(
          stdout: 'SECRET OUTPUT',
          exitDelay: const Duration(seconds: 5),
        ),
      );
      final pending = rig.call('server_stats', {'host': 'web'});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(rig.tools.inFlight, 1);
      rig.tools.abandonClient('someone-else');
      expect(rig.tools.inFlight, 1);
      rig.tools.abandonClient(testBridgeClient.id);
      final r = await pending.timeout(const Duration(seconds: 1));
      expect(r.isError, true);
      expect(r.text, BridgeTools.revokedMessage);
      expect(r.text, isNot(contains('SECRET')));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(web.sessions.single.stdinClosed, true);
      expect(web.sessions.single.wasClosed, true);
      expect(rig.entries.single.outcome, BridgeAuditOutcome.error);
      expect(rig.tools.inFlight, 0);
    });

    test('a call waiting on a slow dial gives its slot back at once, and the '
        'connection that lands later is not kept', () async {
      final landing = Completer<SessionTransport>();
      final rig = BridgeToolsRig(
        temp,
        maxRunning: 1,
        dialer: (_, _) => landing.future,
      );
      final pending = rig.call('server_stats', {'host': 'web'});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(rig.tools.running, 1);
      rig.tools.abandonClient(testBridgeClient.id);
      final r = await pending.timeout(const Duration(seconds: 1));
      expect(r.text, BridgeTools.revokedMessage);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(rig.tools.running, 0, reason: 'the slot must not wait on the dial');
      expect(rig.entries, hasLength(1));

      final late = FakeExecTransport(host: rig.hosts.first);
      landing.complete(late);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      // Nobody holds it: it idles in the cache like any dialled connection
      // rather than staying leased for ever.
      expect(rig.connections.cachedCount, 1);
      await rig.connections.closeAll();
      expect(late.closed, true);
      expect(rig.entries, hasLength(1), reason: 'one audit entry per call');
    });

    test('switching off stops queued calls as well as running ones', () async {
      final rig = BridgeToolsRig(temp, maxRunning: 1);
      final web = rig.serve(
        'web1',
        (_) => FakeExecSession(
          stdout: _probeOutput,
          exitDelay: const Duration(seconds: 5),
        ),
      );
      final running = rig.call('server_stats', {'host': 'web'});
      final queued = rig.call('server_stats', {'host': 'web'});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(rig.tools.waiting, 1);
      rig.tools.abandonAll();
      final results = await Future.wait([
        running,
        queued,
      ]).timeout(const Duration(seconds: 1));
      for (final r in results) {
        expect(r.text, BridgeTools.switchedOffMessage);
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
      // The queued call never ran anything.
      expect(web.commands, hasLength(1));
      expect(rig.entries, hasLength(2));
      expect(rig.tools.running, 0);
    });
  });

  group('closeAll racing a dial that has just landed', () {
    test('never hands out a lease on a closed transport, wherever closeAll '
        'lands', () async {
      final web = bridgeHost('web1', 'web');
      for (var hops = 0; hops < 12; hops++) {
        late BridgeConnections connections;
        connections = BridgeConnections(
          openTransport: (_) => null,
          credentialLookup: (_) async => const SshCredentials(password: 'pw'),
          dialer: (host, _) async {
            final t = FakeExecTransport(host: host);
            // closeAll lands [hops] microtasks after the dial returns.
            void after(int n) => n == 0
                ? unawaited(connections.closeAll())
                : scheduleMicrotask(() => after(n - 1));
            after(hops);
            return t;
          },
        );
        try {
          final lease = await connections.acquire(web);
          // Handed out before closeAll ran; closeAll then hangs it up,
          // which is what switching off is meant to do to calls in flight.
          expect(lease.transport.isClosed, false, reason: 'hops $hops');
          await lease.release();
        } on BridgeConnectFailure {
          // Refused: fine.
        }
        await connections.closeAll();
      }
    });

    test('a connection that dropped as the dial landed is refused, not '
        'leased', () async {
      final connections = BridgeConnections(
        openTransport: (_) => null,
        credentialLookup: (_) async => const SshCredentials(password: 'pw'),
        dialer: (host, _) async => FakeExecTransport(host: host)..close(),
      );
      await expectLater(
        connections.acquire(bridgeHost('web1', 'web')),
        throwsA(
          isA<BridgeConnectFailure>().having(
            (e) => e.message,
            'message',
            contains('was closed'),
          ),
        ),
      );
      expect(connections.cachedCount, 0);
    });
  });

  group('credentials that need a person', () {
    test(
      'a sealed store fails the call as needs-a-person, asking nobody',
      () async {
        final store = CredentialStore(backend: _SealedBackend());
        final rig = BridgeToolsRig(temp);
        final connections = BridgeConnections(
          openTransport: (_) => null,
          credentialLookup: store.loadQuiet,
          dialer: (_, _) async => fail('must not dial'),
        );
        final tools = BridgeTools(
          loadHosts: () async => rig.hosts,
          settings: () => rig.settings,
          isAppLocked: () => false,
          connections: connections,
          redactor: rig.tools.redactor,
          audit: rig.audit,
        );
        final r = await tools.call(testBridgeClient, 'server_stats', {
          'host': 'web',
        });
        expect(r.isError, true);
        expect(r.text, contains('credential vault, which is locked'));
        expect(r.text, contains('connect to it once in SecureShell Go'));
        expect(_SealedBackend.prompts, 0);
      },
    );

    test(
      'a jump host whose sign-in is sealed is reported the same way',
      () async {
        final connections = BridgeConnections(
          openTransport: (_) => null,
          credentialLookup: (_) async => const SshCredentials(password: 'pw'),
          dialer: (_, _) async =>
              throw const CredentialsNeedPerson(SecureStorageSealedKind.vault),
        );
        await expectLater(
          connections.acquire(bridgeHost('web1', 'web')),
          throwsA(
            isA<BridgeConnectFailure>().having(
              (e) => e.message,
              'message',
              contains('connect to it once in SecureShell Go'),
            ),
          ),
        );
      },
    );
  });
}

/// A backend that would prompt on an ordinary read and is sealed to a quiet
/// one — what a passphrase vault looks like to the bridge.
class _SealedBackend implements SecureStorageBackend, QuietSecureStorageRead {
  static var prompts = 0;

  @override
  Future<String?> read(String key) async {
    prompts++;
    return null;
  }

  @override
  Future<String?> readQuiet(String key) async =>
      throw const SecureStorageSealed(SecureStorageSealedKind.vault);

  @override
  Future<void> write(String key, String value) async {}

  @override
  Future<void> delete(String key) async {}
}
