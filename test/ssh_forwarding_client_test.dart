import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/ssh_certificate.dart';
import 'package:secure_shell_go/services/ssh_forwarding_client.dart';
import 'package:secure_shell_go/services/x11_forwarding.dart';

import 'support/certificate_fixture.dart';
import 'support/scripted_ssh_peer.dart';

/// Per-host forwarding rides on the shell channel only.
///
/// The constraint, from `SessionTransport.execute`: dartssh2 puts
/// `auth-agent-req@openssh.com` on every session channel of a client built
/// with an agent handler and throws when it is refused, and OpenSSH grants
/// it once per connection — so a session that simply carried a handler lost
/// every exec after its first. These run a real dartssh2 client (the
/// [ForwardingSSHClient] the app builds) against [ScriptedSshPeer], which
/// grants the agent once as OpenSSH does and records which channel asked
/// for what.
void main() {
  late ScriptedSshPeer peer;
  late _RecordingAgent agent;

  ForwardingSSHClient connect({
    SSHAgentHandler? agentHandler,
    ShellForwarding? forwarding,
  }) {
    peer = ScriptedSshPeer();
    final client = ForwardingSSHClient(
      peer.socket,
      username: 'dev',
      agentHandler: agentHandler,
      forwarding: forwarding,
      keepAliveInterval: null,
      printTrace: peer.trace,
    );
    peer.client = client;
    addTearDown(() => closeQuietly(client.close));
    peer.authenticate();
    return client;
  }

  setUp(() => agent = _RecordingAgent());

  group('agent forwarding on the shell', () {
    test('the shell asks for the agent, and five execs after it do not',
        () async {
      final client = connect(forwarding: ShellForwarding(agent: agent));

      await client.shell();
      for (var i = 0; i < 5; i++) {
        await client.execute('echo $i');
      }

      final channels = peer.sessionRequests;
      expect(channels.first, ['auth-agent-req@openssh.com', 'pty-req', 'shell']);
      for (final exec in channels.skip(1)) {
        expect(exec, ['exec'], reason: 'an exec must carry no agent request');
      }
      expect(channels, hasLength(6));
    });

    test('the old shape — a handler on the client — loses the second exec',
        () async {
      // Proof the peer is honest: OpenSSH's once-per-connection grant
      // reproduces the original failure exactly.
      final client = connect(agentHandler: agent);
      await client.shell();
      await expectLater(
        client.execute('echo'),
        throwsA(isA<SSHChannelRequestError>()),
      );
    });

    test('an exec opened while the shell opens still asks for nothing',
        () async {
      final client = connect(forwarding: ShellForwarding(agent: agent));

      // Both channel opens are in flight at once; dartssh2 reads the agent
      // handler for each only after its open is confirmed.
      await Future.wait([
        client.execute('uptime'),
        client.shell(),
        client.execute('df'),
      ]);

      final withAgent = peer.sessionRequests
          .where((r) => r.contains('auth-agent-req@openssh.com'))
          .toList();
      expect(withAgent, [
        ['auth-agent-req@openssh.com', 'pty-req', 'shell'],
      ]);
    });

    test('the server opening an agent channel reaches the forwarded agent',
        () async {
      final client = connect(forwarding: ShellForwarding(agent: agent));
      await client.shell();

      final channel = peer.openChannel('auth-agent@openssh.com');
      expect(
        peer.sentContaining(
            'SSH_Message_Channel_Confirmation(recipientChannel: $channel,'),
        hasLength(1),
      );
      // `ssh-add -l` on the server: a framed REQUEST_IDENTITIES.
      peer.sendData(channel, [0, 0, 0, 1, 11]);
      await pumpEventQueue();
      expect(agent.requests.single, [11]);
    });

    test('a refusal still opens the shell, and says so first', () async {
      final client = connect(forwarding: ShellForwarding(agent: agent));
      peer.refuseAgent = true;

      final shell = await client.shell();

      // The refused channel, then the shell without the request.
      expect(peer.sessionRequests, [
        ['auth-agent-req@openssh.com'],
        ['pty-req', 'shell'],
      ]);
      final first = await shell.stderr.first;
      expect(utf8.decode(first), contains('refused agent forwarding'));
    });

    test('refused for a certificate that does not permit it, says so',
        () async {
      final client = connect(
        forwarding: ShellForwarding(
          agent: agent,
          certificate: _certificate(extensions: const ['permit-pty']),
        ),
      );
      peer.refuseAgent = true;
      final shell = await client.shell();
      final notice = utf8.decode(await shell.stderr.first);
      expect(notice, contains('refused agent forwarding'));
      expect(notice, contains('no permit-agent-forwarding'));
      expect(notice, isNot(contains('AllowAgentForwarding')));
    });

    test('a certificate that does permit it is not blamed', () async {
      final client = connect(
        forwarding: ShellForwarding(agent: agent, certificate: _certificate()),
      );
      peer.refuseAgent = true;
      final shell = await client.shell();
      final notice = utf8.decode(await shell.stderr.first);
      expect(notice, contains('AllowAgentForwarding no'));
      expect(notice, isNot(contains('certificate')));
    });

    test('refusedAgentRequest matches what dartssh2 throws', () async {
      // Without this, a reworded dartssh2 error would not be recognised as
      // a refusal, and every shell on such a server would fail to open.
      final client = connect(agentHandler: agent);
      peer.refuseAgent = true;
      await expectLater(
        client.shell(),
        throwsA(isA<SSHChannelRequestError>().having(
          (e) => e.message.toLowerCase(),
          'message',
          contains(refusedAgentRequest),
        )),
      );
    });

    test('with nothing to forward the client is a plain one', () async {
      final client = connect();
      expect(client.agentHandler, isNull);
      await client.shell();
      await client.execute('echo');
      expect(peer.sessionRequests, [
        ['pty-req', 'shell'],
        ['exec'],
      ]);
    });

    test('a handler passed in is offered on every channel, as before',
        () async {
      // The direct copy's own connection: its one exec needs the agent.
      final slot = _RecordingAgent();
      final client = connect(agentHandler: slot);
      await client.execute('sftp');
      expect(peer.sessionRequests.single.first, 'auth-agent-req@openssh.com');
      expect(withoutAgentRequest(() async => client.agentHandler),
          completion(same(slot)));
    });
  });

  group('X11 forwarding on the shell', () {
    X11Forwarder forwarder({
      Future<Socket> Function()? connect,
      XauthEntry? real,
    }) =>
        X11Forwarder(
          display: const X11Display(number: 0, screen: 1),
          fakeCookie: Uint8List.fromList(List.filled(16, 0x11)),
          connect: connect ?? () => throw StateError('no X server'),
          realCookie: () async => real,
          untrustedCookie: () async =>
              throw const X11UntrustedUnavailable(null),
        );

    test('the shell asks for x11 with the fake cookie', () async {
      final client = connect(forwarding: ShellForwarding(x11: forwarder()));
      await client.shell();
      await client.execute('echo');

      expect(peer.sessionRequests.first, ['pty-req', 'x11-req', 'shell']);
      expect(peer.sessionRequests.last, ['exec']);
      final request = peer.sentContaining('requestType: x11-req').single;
      expect(request, contains('x11AuthenticationCookie: ${'11' * 16}'));
      expect(request, contains('x11ScreenNumber: 1'));
    });

    test('a refusal still opens the shell, and says so', () async {
      final client = connect(
        forwarding: ShellForwarding(agent: agent, x11: forwarder()),
      );
      peer.refuseX11 = true;
      final shell = await client.shell();
      expect(peer.sessionRequests, [
        // Granted the agent, then turned down for X11.
        ['auth-agent-req@openssh.com', 'pty-req', 'x11-req'],
        // OpenSSH's once-per-connection grant is spent.
        ['auth-agent-req@openssh.com'],
        ['pty-req', 'shell'],
      ]);
      final notice = utf8.decode(await shell.stderr.first);
      expect(notice, contains('refused X11 forwarding'));
      // The connection has the agent from the first channel, and so does
      // this shell: that second refusal is not the server disallowing it.
      expect(notice, isNot(contains('agent')));
    });

    test('refused for a certificate without permit-X11-forwarding, says so',
        () async {
      final client = connect(
        forwarding: ShellForwarding(
          x11: forwarder(),
          certificate: _certificate(extensions: const ['permit-pty']),
        ),
      );
      peer.refuseX11 = true;
      final shell = await client.shell();
      final notice = utf8.decode(await shell.stderr.first);
      expect(notice, contains('refused X11 forwarding'));
      expect(notice, contains('no permit-X11-forwarding'));
    });

    test('a Dropbear-style per-channel grant keeps the agent on the retry',
        () async {
      final client = connect(
        forwarding: ShellForwarding(agent: agent, x11: forwarder()),
      );
      peer
        ..refuseX11 = true
        ..grantAgentPerChannel = true;
      await client.shell();
      expect(peer.sessionRequests.last, [
        'auth-agent-req@openssh.com',
        'pty-req',
        'shell',
      ]);
    });

    test('an x11 channel is piped to the X server with the real cookie',
        () async {
      final xServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(xServer.close);
      final received = BytesBuilder();
      final gotSetup = Completer<void>();
      xServer.listen((socket) {
        socket.listen((chunk) {
          received.add(chunk);
          if (received.length >= 52 && !gotSetup.isCompleted) {
            gotSetup.complete();
            socket.add(utf8.encode('hello-from-x'));
          }
        });
      });
      final real = Uint8List.fromList(List.filled(16, 0xee));
      final client = connect(
        forwarding: ShellForwarding(
          x11: forwarder(
            connect: () =>
                Socket.connect(InternetAddress.loopbackIPv4, xServer.port),
            real: XauthEntry(
              family: XauthEntry.familyWild,
              address: Uint8List(0),
              number: '',
              name: x11CookieProtocol,
              data: real,
            ),
          ),
        ),
      );
      await client.shell();

      final channel = peer.openChannel('x11');
      final setup = _setup(List.filled(16, 0x11), extra: utf8.encode('more'));
      // In two pieces, as a network may deliver it.
      peer.sendData(channel, setup.sublist(0, 7));
      peer.sendData(channel, setup.sublist(7));
      await gotSetup.future.timeout(const Duration(seconds: 5));

      expect(received.toBytes(), _setup(real, extra: utf8.encode('more')));

      // And the X server's answer goes back down the channel.
      await _eventually(() => peer
          .sentContaining('SSH_Message_Channel_Data(recipientChannel: '
              '$channel, data.length=12)')
          .isNotEmpty);
    });

    test('an x11 channel with the wrong cookie never reaches the X server',
        () async {
      var dialled = false;
      final client = connect(
        forwarding: ShellForwarding(
          x11: forwarder(connect: () async {
            dialled = true;
            throw StateError('must not be dialled');
          }),
        ),
      );
      await client.shell();

      final channel = peer.openChannel('x11');
      peer.sendData(channel, _setup(List.filled(16, 0x99)));
      await _eventually(() => peer
          .sentContaining('SSH_Message_Channel_Close(recipientChannel: $channel')
          .isNotEmpty);
      expect(dialled, isFalse);
    });

    test('a display that can only be forwarded with full access says so',
        () async {
      final client = connect(
        forwarding: ShellForwarding(
          x11: X11Forwarder(
            display: const X11Display(number: 0),
            fakeCookie: Uint8List.fromList(List.filled(16, 0x11)),
            connect: () => throw StateError('no X server'),
            realCookie: () async => null,
            untrustedCookie: () async => throw const X11UntrustedUnavailable(
                'xauth: couldn\'t query Security extension'),
          ),
        ),
      );
      final shell = await client.shell();
      final notice = utf8.decode(await shell.stderr.first);
      expect(notice, contains('Security extension'));
      expect(notice, contains('see and control every window'));
    });

    test('an X server that does not answer is said in the terminal',
        () async {
      final client = connect(forwarding: ShellForwarding(x11: forwarder()));
      final shell = await client.shell();
      final lines = <String>[];
      shell.stderr.listen((chunk) => lines.add(utf8.decode(chunk)));

      final channel = peer.openChannel('x11');
      peer.sendData(channel, _setup(List.filled(16, 0x11)));
      await _eventually(() => lines.isNotEmpty);
      expect(lines.single, contains('Could not reach the X server at :0.1'));
      expect(lines.single, startsWith('\x1b[33m'));
    });

    test('without x11 forwarding an x11 channel is refused', () async {
      final client = connect(forwarding: ShellForwarding(agent: agent));
      await client.shell();
      final channel = peer.openChannel('x11');
      expect(
        peer.sentContaining(
            'SSH_Message_Channel_Open_Failure(recipientChannel: $channel'),
        hasLength(1),
      );
    });
  });

  group('X11 kept off the shell: the host switch off', () {
    X11Forwarder forwarder({Future<Socket> Function()? connect}) =>
        X11Forwarder(
          display: const X11Display(number: 0),
          fakeCookie: Uint8List.fromList(List.filled(16, 0x22)),
          connect: connect ?? () => throw StateError('no X server'),
          realCookie: () async => null,
          untrustedCookie: () async =>
              throw const X11UntrustedUnavailable(null),
        );

    test('the shell asks for nothing; an app channel asks for x11', () async {
      final f = forwarder();
      final client = connect(
        forwarding: ShellForwarding(x11: f, x11OnShell: false),
      );
      final shell = await client.shell();
      expect(shell, isNot(isA<ShellSessionWithNotices>()),
          reason: 'nothing to say: the person did not ask for X11 here');
      await client.execute('xeyes', x11: f.config);

      expect(peer.sessionRequests.first, ['pty-req', 'shell']);
      expect(peer.sessionRequests.last, ['x11-req', 'exec']);
      expect(peer.sentContaining('requestType: x11-req').single,
          contains('x11AuthenticationCookie: ${'22' * 16}'));
    });

    test('nor does a shell kept in tmux', () async {
      final client = connect(
        forwarding: ShellForwarding(x11: forwarder(), x11OnShell: false),
      );
      await client.commandShell('tmux new -A -s main',
          pty: const SSHPtyConfig());
      expect(peer.sessionRequests.single, ['pty-req', 'exec']);
    });

    test('an x11 channel before any app asked is turned away unread',
        () async {
      var dialled = false;
      final f = forwarder(connect: () async {
        dialled = true;
        throw StateError('must not be dialled');
      });
      final client = connect(
        forwarding: ShellForwarding(x11: f, x11OnShell: false),
      );
      await client.shell();

      final channel = peer.openChannel('x11');
      peer.sendData(channel, _setup(List.filled(16, 0x22)));
      await _eventually(() => peer
          .sentContaining('SSH_Message_Channel_Close(recipientChannel: $channel')
          .isNotEmpty);
      expect(dialled, isFalse);
      expect(f.requested, isFalse);
    });

    test('once an app asked, its windows reach the X server', () async {
      final dialled = Completer<void>();
      final f = forwarder(connect: () async {
        if (!dialled.isCompleted) dialled.complete();
        throw const SocketException('no X server here');
      });
      final client = connect(
        forwarding: ShellForwarding(x11: f, x11OnShell: false),
      );
      await client.shell();
      await client.execute('xeyes', x11: f.config);
      expect(f.requested, isTrue);

      final channel = peer.openChannel('x11');
      peer.sendData(channel, _setup(List.filled(16, 0x22)));
      await dialled.future.timeout(const Duration(seconds: 5));
    });
  });

  group('a shell kept in tmux or screen', () {
    // `SessionTransport.startCommandShell` opens the terminal as an exec
    // channel running tmux or screen. It is still the terminal, so it has
    // to forward what the shell would; a plain exec forwards nothing.
    test('asks for the agent and x11 like the shell, and execs still do not',
        () async {
      final client = connect(
        forwarding: ShellForwarding(
          agent: agent,
          x11: X11Forwarder(
            display: const X11Display(number: 0, screen: 0),
            fakeCookie: Uint8List.fromList(List.filled(16, 0x22)),
            connect: () => throw StateError('no X server'),
            realCookie: () async => null,
            untrustedCookie: () async =>
                throw const X11UntrustedUnavailable(null),
          ),
        ),
      );

      await client.commandShell(
        "tmux new -A -s 'ssg-build-1'",
        pty: const SSHPtyConfig(),
      );
      await client.execute('uptime');

      expect(peer.sessionRequests.first,
          ['auth-agent-req@openssh.com', 'pty-req', 'x11-req', 'exec']);
      expect(peer.sessionRequests.last, ['exec']);
    });

    test('a refusal still opens it, and says so', () async {
      final client = connect(forwarding: ShellForwarding(agent: agent));
      peer.refuseAgent = true;

      final shell = await client.commandShell(
        'screen -dRR ssg-build-1',
        pty: const SSHPtyConfig(),
      );
      final first = await shell.stderr.first;
      expect(utf8.decode(first), contains('refused agent forwarding'));
    });

    test('with nothing to forward it is a plain exec with a pty', () async {
      final client = connect();
      await client.commandShell('tmux', pty: const SSHPtyConfig());
      expect(peer.sessionRequests.single, ['pty-req', 'exec']);
    });
  });

  test('notices decided before the shell open are written first', () async {
    final client = connect(
      forwarding: const ShellForwarding(notices: ['No X display here.']),
    );
    final shell = await client.shell();
    expect(utf8.decode(await shell.stderr.first), contains('No X display here.'));
  });
}

/// An X11 connection setup, little-endian, presenting [cookie].
Uint8List _setup(List<int> cookie, {List<int> extra = const []}) {
  const name = x11CookieProtocol;
  final out = BytesBuilder()
    ..add([0x6c, 0, 11, 0, 0, 0])
    ..add([name.length, 0, cookie.length, 0, 0, 0])
    ..add(name.codeUnits)
    ..add(List.filled((4 - name.length % 4) % 4, 0))
    ..add(cookie)
    ..add(List.filled((4 - cookie.length % 4) % 4, 0))
    ..add(extra);
  return out.toBytes();
}

Future<void> _eventually(bool Function() condition) async {
  for (var i = 0; i < 200; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('condition never became true');
}

class _RecordingAgent implements SSHAgentHandler {
  final List<Uint8List> requests = [];

  @override
  Future<Uint8List> handleRequest(Uint8List request) async {
    requests.add(request);
    return Uint8List.fromList([12, 0, 0, 0, 0]);
  }
}

void closeQuietly(Future<void> Function() close) {
  try {
    unawaited(close().catchError((Object _) {}));
  } catch (_) {}
}

/// A user certificate permitting [extensions] (all of ssh-keygen's
/// defaults unless told otherwise), for a made-up ed25519 key.
SshCertificate _certificate({List<String>? extensions}) {
  final key = BytesBuilder();
  for (final part in [utf8.encode('ssh-ed25519'), List.filled(32, 9)]) {
    key
      ..add((ByteData(4)..setUint32(0, part.length)).buffer.asUint8List())
      ..add(part);
  }
  return SshCertificate.parse(extensions == null
      ? certificateLineFor(key.toBytes())
      : certificateLineFor(key.toBytes(), extensions: extensions));
}
