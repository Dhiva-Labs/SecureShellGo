import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/services/bridge/bridge_connections.dart';
import 'package:secure_shell_go/services/headless_dialer.dart';
import 'package:secure_shell_go/services/ssh_service.dart';

import 'fake_exec_session.dart';
import 'support/bridge_fakes.dart';

void main() {
  final web = bridgeHost('web1', 'web');

  late Map<String, FakeExecTransport> open;
  late List<FakeExecTransport> dialled;
  late SshCredentials? saved;
  late Future<SessionTransport> Function(Host, SshCredentials)? dialOverride;
  late FakeBridgeFiles files;
  late BridgeConnections connections;
  Completer<void>? lookupGate;

  BridgeConnections build({Duration idle = const Duration(seconds: 60)}) =>
      BridgeConnections(
        openTransport: (id) => open[id],
        credentialLookup: (_) async {
          await lookupGate?.future;
          return saved;
        },
        dialer: (host, creds) {
          final override = dialOverride;
          if (override != null) return override(host, creds);
          final t = FakeExecTransport(host: host);
          dialled.add(t);
          return Future.value(t);
        },
        openFiles: (_) async => files,
        idleTimeout: idle,
      );

  setUp(() {
    open = {};
    dialled = [];
    saved = const SshCredentials(password: 'pw');
    dialOverride = null;
    lookupGate = null;
    files = FakeBridgeFiles();
    connections = build();
  });

  tearDown(() => connections.closeAll());

  test('an open session is used as it is, and never closed', () async {
    final session = open['web1'] = FakeExecTransport(host: web);
    final lease = await connections.acquire(web);
    expect(lease.transport, same(session));
    await lease.files();
    await lease.release();
    expect(dialled, isEmpty);
    expect(session.closed, false);
    expect(files.closed, 1, reason: 'the call\'s own SFTP channel is closed');
    await connections.closeAll();
    expect(session.closed, false);
  });

  test('a dialled connection is reused, then closed once idle', () async {
    connections = build(idle: const Duration(milliseconds: 80));
    final a = await connections.acquire(web);
    final b = await connections.acquire(web);
    expect(dialled, hasLength(1));
    expect(b.transport, same(a.transport));
    await a.release();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(dialled.single.closed, false, reason: 'still leased by b');
    await b.release();
    expect(connections.cachedCount, 1);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(dialled.single.closed, false, reason: 'not idle long enough yet');
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(dialled.single.closed, true);
    expect(connections.cachedCount, 0);
    // The next call dials again.
    final c = await connections.acquire(web);
    expect(dialled, hasLength(2));
    await c.release();
  });

  test('concurrent calls share one dial', () async {
    final gate = Completer<void>();
    dialOverride = (host, _) async {
      await gate.future;
      final t = FakeExecTransport(host: host);
      dialled.add(t);
      return t;
    };
    final both = Future.wait([
      connections.acquire(web),
      connections.acquire(web),
    ]);
    gate.complete();
    final leases = await both;
    expect(dialled, hasLength(1));
    for (final l in leases) {
      await l.release();
    }
  });

  test('a dropped or edited host is dialled afresh', () async {
    final first = await connections.acquire(web);
    await first.release();
    dialled.single.close();
    final second = await connections.acquire(web);
    expect(dialled, hasLength(2));
    await second.release();

    final moved = Host(
      id: web.id,
      label: web.label,
      hostname: 'elsewhere.test',
      port: 22,
      username: 'dev',
      authMethod: SshAuthMethod.password,
      aiAccess: web.aiAccess,
    );
    final third = await connections.acquire(moved);
    expect(dialled, hasLength(3));
    expect(dialled[1].closed, true);
    await third.release();
  });

  group('sign-ins that need a person fail with a plain message', () {
    Future<String> failure() async {
      try {
        await connections.acquire(web);
      } on BridgeConnectFailure catch (e) {
        return e.message;
      }
      fail('acquire should have failed');
    }

    test('no saved password', () async {
      saved = null;
      final m = await failure();
      expect(m, contains('No saved password'));
      expect(m, contains('connect to it once in SecureShell Go'));
      expect(dialled, isEmpty);
    });

    test('an unchecked host key or a question at login', () async {
      dialOverride = (_, _) async =>
          throw const SignInNeedsPerson('The host key has not been checked.');
      final m = await failure();
      expect(m, contains('not been checked'));
      expect(m, contains('connect to it once in SecureShell Go'));
    });

    test('a changed host key is an alarm, not a chore', () async {
      dialOverride = (_, _) async =>
          throw const SshConnectionException('The host key has CHANGED.');
      expect(await failure(), 'The host key has CHANGED.');
    });

    test('an encrypted key without its passphrase', () {
      expect(
        HeadlessDialer.signInProblem(
          Host(
            id: 'k',
            label: 'k',
            hostname: 'k',
            port: 22,
            username: 'u',
            authMethod: SshAuthMethod.privateKey,
          ),
          const SshCredentials(privateKeyPem: ''),
        ),
        contains('No saved private key'),
      );
    });
  });

  test('closeAll hangs up at once, and a dial in flight is not kept', () async {
    final lease = await connections.acquire(web);
    await connections.closeAll();
    expect(dialled.single.closed, true);
    expect(connections.cachedCount, 0);
    await lease.release();

    final gate = Completer<void>();
    dialOverride = (host, _) async {
      await gate.future;
      final t = FakeExecTransport(host: host);
      dialled.add(t);
      return t;
    };
    final pending = connections.acquire(web);
    // Let the dial start: it is the one *in flight* that must not be kept.
    await Future<void>.delayed(Duration.zero);
    await connections.closeAll();
    gate.complete();
    await expectLater(pending, throwsA(isA<BridgeConnectFailure>()));
    expect(dialled.last.closed, true);
    expect(connections.cachedCount, 0);
  });

  test('closeAll while the saved sign-in is still being read dials nothing',
      () async {
    final gate = lookupGate = Completer<void>();
    final pending = connections.acquire(web);
    await Future<void>.delayed(Duration.zero);
    await connections.closeAll();
    gate.complete();
    await expectLater(pending, throwsA(isA<BridgeConnectFailure>()));
    expect(dialled, isEmpty);
    expect(connections.cachedCount, 0);
  });

  test('an unexpected dial error is not passed on with its own text', () async {
    dialOverride = (_, _) async => throw StateError('10.9.8.7:22 refused');
    await expectLater(
      connections.acquire(web),
      throwsA(
        isA<BridgeConnectFailure>().having(
          (e) => e.message,
          'message',
          allOf(isNot(contains('10.9.8.7')), contains('Could not connect')),
        ),
      ),
    );
    expect(connections.cachedCount, 0);
  });

  group('no bridge connection carries the user\'s agent or X11', () {
    final forwarding = web.copyWith(agentForwarding: true, x11Forwarding: true);

    test('a cached dial hands the dialer the host with forwarding off, and '
        'still caches it under the host as saved', () async {
      final asked = <Host>[];
      dialOverride = (host, _) async {
        asked.add(host);
        final t = FakeExecTransport(host: host);
        dialled.add(t);
        return t;
      };
      final a = await connections.acquire(forwarding);
      final b = await connections.acquire(forwarding);
      expect(asked, hasLength(1), reason: 'reused, not re-dialled');
      expect(asked.single.agentForwarding, false);
      expect(asked.single.x11Forwarding, false);
      expect(asked.single.hostname, forwarding.hostname);
      expect(b.transport, same(a.transport));
      await a.release();
      await b.release();
    });

    test('dialOwned strips it too', () async {
      final asked = <Host>[];
      dialOverride = (host, _) async {
        asked.add(host);
        return FakeExecTransport(host: host);
      };
      final t = await connections.dialOwned(forwarding);
      expect(asked.single.agentForwarding, false);
      expect(asked.single.x11Forwarding, false);
      t.close();
    });

    for (final (name, host) in [
      ('agent', web.copyWith(agentForwarding: true)),
      ('X11', web.copyWith(x11Forwarding: true)),
    ]) {
      test('a session whose host forwards $name is not borrowed: the bridge '
          'dials its own, without it', () async {
        final session = open['web1'] = FakeExecTransport(host: host);
        final lease = await connections.acquire(host);
        expect(lease.transport, isNot(same(session)));
        expect(dialled.single.host.agentForwarding, false);
        expect(dialled.single.host.x11Forwarding, false);
        await lease.release();
        expect(session.closed, false);
      });
    }

    test('nor one dialled while forwarding was on, after it was switched off '
        'in the saved host', () async {
      final session = open['web1'] = FakeExecTransport(
        host: web.copyWith(agentForwarding: true),
      );
      final lease = await connections.acquire(web);
      expect(lease.transport, isNot(same(session)));
      await lease.release();
    });

    test('a session without forwarding is still borrowed', () async {
      final session = open['web1'] = FakeExecTransport(host: web);
      expect(BridgeConnections.mayBorrow(session, web), true);
      expect(
        BridgeConnections.withoutForwarding(web),
        same(web),
        reason: 'nothing to strip, nothing copied',
      );
    });
  });
}
