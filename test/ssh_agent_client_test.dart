import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:dartssh2/dartssh2.dart'
    show SSHKeyPair, SSHRawSignature, SSHSignature;
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/ssh_agent_client.dart';
import 'package:secure_shell_go/services/ssh_keygen.dart';
import 'package:secure_shell_go/services/windows_agent_pipe.dart';

/// An SSH `string`: 4-byte big-endian length, then the bytes.
List<int> _string(List<int> bytes) => [
      (bytes.length >> 24) & 0xff,
      (bytes.length >> 16) & 0xff,
      (bytes.length >> 8) & 0xff,
      bytes.length & 0xff,
      ...bytes,
    ];

List<int> _utf8String(String value) => _string(value.codeUnits);

/// A public key blob shaped like a real one: `string algorithm, string key`.
Uint8List _ed25519Blob([int fill = 7]) => Uint8List.fromList([
      ..._utf8String('ssh-ed25519'),
      ..._string(List<int>.filled(32, fill)),
    ]);

/// A fake agent that answers from a script, and records what it was asked.
///
/// The point of testing against this rather than the developer's own agent is
/// repeatability: the golden bytes below are fixed, and the suite must pass on
/// a machine with no agent, no keys, and no `SSH_AUTH_SOCK`.
class _FakeAgent implements SshAgentConnection {
  _FakeAgent(this._reply);

  final Uint8List Function(Uint8List request) _reply;
  final List<Uint8List> requests = [];
  int closes = 0;

  @override
  Future<Uint8List> request(Uint8List payload) async {
    requests.add(payload);
    return _reply(payload);
  }

  @override
  Future<void> close() async => closes++;
}

void main() {
  group('wire format golden bytes', () {
    test('REQUEST_IDENTITIES is a bare message number', () {
      expect(SshAgentProtocol.encodeRequestIdentities(), [11]);
    });

    test('framing prepends a 4-byte big-endian length', () {
      expect(
        SshAgentProtocol.frame(SshAgentProtocol.encodeRequestIdentities()),
        [0, 0, 0, 1, 11],
      );
    });

    test('framing a longer payload gets the length right', () {
      final payload = Uint8List.fromList(List<int>.filled(300, 0xab));
      final framed = SshAgentProtocol.frame(payload);
      expect(framed.sublist(0, 4), [0, 0, 1, 44]); // 300 == 0x012c
      expect(framed.length, 304);
    });

    test('SIGN_REQUEST lays out key, data and flags in order', () {
      final encoded = SshAgentProtocol.encodeSignRequest(
        keyBlob: Uint8List.fromList([1, 2, 3]),
        data: Uint8List.fromList([4, 5]),
        flags: SshAgentProtocol.flagRsaSha2_256,
      );
      expect(encoded, [
        13, // SSH_AGENTC_SIGN_REQUEST
        0, 0, 0, 3, 1, 2, 3, // string key blob
        0, 0, 0, 2, 4, 5, // string data
        0, 0, 0, 2, // uint32 flags == rsa-sha2-256
      ]);
    });

    test('SIGN_REQUEST with no flags ends in four zero bytes', () {
      final encoded = SshAgentProtocol.encodeSignRequest(
        keyBlob: Uint8List.fromList([9]),
        data: Uint8List.fromList([8]),
      );
      expect(encoded.sublist(encoded.length - 4), [0, 0, 0, 0]);
    });

    test('the RSA SHA-2 flag values are the ones from the spec', () {
      expect(SshAgentProtocol.flagRsaSha2_256, 2);
      expect(SshAgentProtocol.flagRsaSha2_512, 4);
    });

    // An RSA key in an agent signs with SHA-1 unless asked otherwise, and
    // modern OpenSSH rejects that; everything else has exactly one signature
    // algorithm and must not be sent flags.
    test('flags are requested for RSA only', () {
      expect(SshAgentProtocol.flagsForKeyType('ssh-rsa'), 2);
      expect(SshAgentProtocol.flagsForKeyType('ssh-ed25519'), 0);
      expect(SshAgentProtocol.flagsForKeyType('ecdsa-sha2-nistp256'), 0);
    });
  });

  group('decoding replies', () {
    test('IDENTITIES_ANSWER yields each key blob and comment', () {
      final payload = Uint8List.fromList([
        12, // SSH_AGENT_IDENTITIES_ANSWER
        0, 0, 0, 2, // two identities
        ..._string(_ed25519Blob(1)),
        ..._utf8String('me@laptop'),
        ..._string(_ed25519Blob(2)),
        ..._utf8String('backup'),
      ]);

      final identities = SshAgentProtocol.decodeIdentitiesAnswer(payload);
      expect(identities, hasLength(2));
      expect(identities[0].comment, 'me@laptop');
      expect(identities[0].keyType, 'ssh-ed25519');
      expect(identities[0].keyBlob, _ed25519Blob(1));
      expect(identities[1].comment, 'backup');
      expect(identities[1].keyBlob, _ed25519Blob(2));
    });

    test('an empty agent decodes to an empty list, not an error', () {
      final payload = Uint8List.fromList([12, 0, 0, 0, 0]);
      expect(SshAgentProtocol.decodeIdentitiesAnswer(payload), isEmpty);
    });

    test('SIGN_RESPONSE yields the signature blob', () {
      final signature = [..._utf8String('ssh-ed25519'), ..._string([1, 2, 3])];
      final payload = Uint8List.fromList([14, ..._string(signature)]);
      expect(SshAgentProtocol.decodeSignResponse(payload), signature);
    });

    test('SSH_AGENT_FAILURE to a list request reads as a refusal', () {
      expect(
        () => SshAgentProtocol.decodeIdentitiesAnswer(Uint8List.fromList([5])),
        throwsA(isA<SshAgentException>()
            .having((e) => e.kind, 'kind', SshAgentErrorKind.refused)),
      );
    });

    test('SSH_AGENT_FAILURE to a sign request reads as a refusal', () {
      expect(
        () => SshAgentProtocol.decodeSignResponse(Uint8List.fromList([5])),
        throwsA(isA<SshAgentException>()
            .having((e) => e.kind, 'kind', SshAgentErrorKind.refused)
            .having((e) => e.message, 'message', contains('refused to sign'))),
      );
    });

    test('an unexpected message number is a protocol error', () {
      expect(
        () => SshAgentProtocol.decodeSignResponse(Uint8List.fromList([99])),
        throwsA(isA<SshAgentException>()
            .having((e) => e.kind, 'kind', SshAgentErrorKind.protocol)),
      );
    });

    test('an implausible identity count is refused before allocating', () {
      final payload = Uint8List.fromList([12, 0xff, 0xff, 0xff, 0xff]);
      expect(
        () => SshAgentProtocol.decodeIdentitiesAnswer(payload),
        throwsA(isA<SshAgentException>()
            .having((e) => e.kind, 'kind', SshAgentErrorKind.protocol)),
      );
    });

    test('a truncated reply is rejected rather than read past', () {
      // Claims one identity, then stops mid-string.
      final payload = Uint8List.fromList([12, 0, 0, 0, 1, 0, 0, 0, 8, 1, 2]);
      expect(
        () => SshAgentProtocol.decodeIdentitiesAnswer(payload),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('SshAgentClient against a fake agent', () {
    test('lists identities and closes the connection', () async {
      final agent = _FakeAgent((_) => Uint8List.fromList([
            12,
            0, 0, 0, 1,
            ..._string(_ed25519Blob()),
            ..._utf8String('me@laptop'),
          ]));

      final identities =
          await SshAgentClient(connector: () async => agent).listIdentities();

      expect(identities, hasLength(1));
      expect(identities.single.comment, 'me@laptop');
      expect(agent.requests.single, [11]);
      expect(agent.closes, 1);
    });

    test('an agent holding no keys is its own error, not "no agent"', () async {
      final agent = _FakeAgent((_) => Uint8List.fromList([12, 0, 0, 0, 0]));
      await expectLater(
        SshAgentClient(connector: () async => agent).listIdentities(),
        throwsA(
          isA<SshAgentException>()
              .having((e) => e.kind, 'kind', SshAgentErrorKind.noIdentities)
              .having((e) => e.message, 'message', contains('ssh-add')),
        ),
      );
      expect(agent.closes, 1);
    });

    // The signer seam: this is the exchange an SSH client authentication
    // would make — hand the agent a challenge, get a signature back, and
    // never see the private key.
    test('signs a challenge and returns the signature blob', () async {
      final expected = Uint8List.fromList(
        [..._utf8String('ssh-ed25519'), ..._string(List<int>.filled(64, 3))],
      );
      final agent = _FakeAgent(
        (_) => Uint8List.fromList([14, ..._string(expected)]),
      );

      final challenge = Uint8List.fromList('session-id-and-request'.codeUnits);
      final signature = await SshAgentClient(connector: () async => agent).sign(
        keyBlob: _ed25519Blob(),
        data: challenge,
        flags: SshAgentProtocol.flagsForKeyType('ssh-ed25519'),
      );

      expect(signature, expected);

      // The request carried exactly the key and challenge we handed in, and
      // no flags for an ed25519 key.
      final sent = agent.requests.single;
      expect(
        sent,
        SshAgentProtocol.encodeSignRequest(
          keyBlob: _ed25519Blob(),
          data: challenge,
        ),
      );
    });

    test('an RSA signature request carries the sha256 flag', () async {
      final agent = _FakeAgent(
        (_) => Uint8List.fromList([14, ..._string([1])]),
      );
      final rsaBlob = Uint8List.fromList(_utf8String('ssh-rsa'));

      await SshAgentClient(connector: () async => agent).sign(
        keyBlob: rsaBlob,
        data: Uint8List.fromList([0]),
        flags: SshAgentProtocol.flagsForKeyType('ssh-rsa'),
      );

      final sent = agent.requests.single;
      expect(sent.sublist(sent.length - 4), [0, 0, 0, 2]);
    });

    test('a refused signature surfaces as a refusal and still closes',
        () async {
      final agent = _FakeAgent((_) => Uint8List.fromList([5]));
      await expectLater(
        SshAgentClient(connector: () async => agent).sign(
          keyBlob: _ed25519Blob(),
          data: Uint8List.fromList([1]),
        ),
        throwsA(isA<SshAgentException>()
            .having((e) => e.kind, 'kind', SshAgentErrorKind.refused)),
      );
      expect(agent.closes, 1);
    });

    test('a truncated reply becomes a protocol error, not a parse error',
        () async {
      final agent = _FakeAgent(
        (_) => Uint8List.fromList([14, 0, 0, 0, 8, 1, 2]),
      );
      await expectLater(
        SshAgentClient(connector: () async => agent).sign(
          keyBlob: _ed25519Blob(),
          data: Uint8List.fromList([1]),
        ),
        throwsA(isA<SshAgentException>()
            .having((e) => e.kind, 'kind', SshAgentErrorKind.protocol)),
      );
    });
  });

  group('absent agent', () {
    test('a missing socket surfaces as "No SSH agent found"', () async {
      await expectLater(
        SshAgentClient(
          connector: () async => throw const SshAgentException(
            SshAgentErrorKind.noAgent,
            'No SSH agent found. SSH_AUTH_SOCK is not set — start an agent '
            'with `ssh-agent` and add a key with `ssh-add`.',
          ),
        ).listIdentities(),
        throwsA(
          isA<SshAgentException>()
              .having((e) => e.kind, 'kind', SshAgentErrorKind.noAgent)
              .having((e) => e.message, 'message',
                  startsWith('No SSH agent found')),
        ),
      );
    });

    // The real connector, pointed at a path with nothing listening on it.
    test('a stale SSH_AUTH_SOCK path fails clearly rather than hanging',
        () async {
      final dir = await Directory.systemTemp.createTemp('agent_absent');
      addTearDown(() => dir.delete(recursive: true));

      await expectLater(
        SshAgentClient(
          connector: () async {
            try {
              final socket = await Socket.connect(
                InternetAddress(
                  '${dir.path}/nope',
                  type: InternetAddressType.unix,
                ),
                0,
              );
              return StreamAgentConnection(socket, socket);
            } on SocketException {
              throw const SshAgentException(
                SshAgentErrorKind.noAgent,
                'No SSH agent found.',
              );
            }
          },
        ).listIdentities(),
        throwsA(isA<SshAgentException>()
            .having((e) => e.kind, 'kind', SshAgentErrorKind.noAgent)),
      );
    });
  });

  // Not on Windows. Serving a Unix-domain socket there took the whole
  // GitHub-hosted runner off the network within seconds, x64 and arm64
  // alike: the job ended as "the hosted runner lost communication with the
  // server", with no log, after every timeout had passed. The app never
  // opens one on Windows, where the agent is a named pipe, so this group
  // tests nothing Windows runs.
  group('framing over a real socket', () {
    /// Serves [reply] over a unix socket, optionally split into chunks with a
    /// gap between them, and hands back a connector pointing at it.
    Future<SshAgentClient> serve(
      List<Uint8List> chunks, {
      required void Function(Uint8List) onRequest,
    }) async {
      final dir = await Directory.systemTemp.createTemp('agent_socket');
      addTearDown(() => dir.delete(recursive: true));
      final address = InternetAddress('${dir.path}/sock',
          type: InternetAddressType.unix);

      final server = await ServerSocket.bind(address, 0);
      addTearDown(server.close);

      server.listen((client) {
        client.listen((data) async {
          onRequest(Uint8List.fromList(data));
          for (final chunk in chunks) {
            client.add(chunk);
            await client.flush();
            // Force the next chunk into a separate read.
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
        });
      });

      return SshAgentClient(connector: () async {
        final socket = await Socket.connect(address, 0);
        return StreamAgentConnection(socket, socket);
      });
    }

    test('a reply arriving in one piece is read', () async {
      Uint8List? seen;
      final payload = [
        12,
        0, 0, 0, 1,
        ..._string(_ed25519Blob()),
        ..._utf8String('whole'),
      ];
      final client = await serve(
        [SshAgentProtocol.frame(Uint8List.fromList(payload))],
        onRequest: (r) => seen = r,
      );

      final identities = await client.listIdentities();
      expect(identities.single.comment, 'whole');
      // The request went out framed, exactly as the golden bytes say.
      expect(seen, [0, 0, 0, 1, 11]);
    });

    // A reply split across reads is the case a naive "one read, one frame"
    // implementation gets wrong, and a local agent almost never produces.
    test('a reply split across three reads is reassembled', () async {
      final payload = Uint8List.fromList([
        12,
        0, 0, 0, 1,
        ..._string(_ed25519Blob()),
        ..._utf8String('split across reads'),
      ]);
      final framed = SshAgentProtocol.frame(payload);

      final client = await serve(
        [
          // Length prefix arrives on its own, then the body in two pieces.
          Uint8List.sublistView(framed, 0, 2),
          Uint8List.sublistView(framed, 2, 12),
          Uint8List.sublistView(framed, 12),
        ],
        onRequest: (_) {},
      );

      final identities = await client.listIdentities();
      expect(identities.single.comment, 'split across reads');
      expect(identities.single.keyType, 'ssh-ed25519');
    });

    test('an oversized frame length is refused, not allocated', () async {
      final client = await serve(
        [Uint8List.fromList([0xff, 0xff, 0xff, 0xff, 12])],
        onRequest: (_) {},
      );

      await expectLater(
        client.listIdentities(),
        throwsA(isA<SshAgentException>()
            .having((e) => e.kind, 'kind', SshAgentErrorKind.protocol)),
      );
    });

    test('an agent that hangs up mid-request is reported, not awaited forever',
        () async {
      final dir = await Directory.systemTemp.createTemp('agent_hangup');
      addTearDown(() => dir.delete(recursive: true));
      final address = InternetAddress('${dir.path}/sock',
          type: InternetAddressType.unix);
      final server = await ServerSocket.bind(address, 0);
      addTearDown(server.close);
      server.listen((client) => client.listen((_) => client.destroy()));

      final client = SshAgentClient(connector: () async {
        final socket = await Socket.connect(address, 0);
        return StreamAgentConnection(socket, socket);
      });

      await expectLater(
        client.listIdentities(),
        throwsA(isA<SshAgentException>()
            .having((e) => e.kind, 'kind', SshAgentErrorKind.protocol)),
      );
    });
  },
      skip: Platform.isWindows && !const bool.fromEnvironment('PROBE_AF_UNIX')
          ? 'Unix-domain sockets take a Windows runner down'
          : null);

  group('SshAgentKeyIdentity, the sign-in adapter', () {
    Uint8List signature(String type, [int length = 64]) => Uint8List.fromList(
        [..._utf8String(type), ..._string(List<int>.filled(length, 9))]);

    _FakeAgent signingWith(Uint8List signatureBlob) =>
        _FakeAgent((_) => Uint8List.fromList([14, ..._string(signatureBlob)]));

    SshAgentKeyIdentity identity(
      _FakeAgent agent,
      Uint8List blob, {
      Uint8List? presentedBlob,
      String? presentedType,
    }) =>
        SshAgentKeyIdentity(
          SshAgentClient(connector: () async => agent),
          SshAgentIdentity(keyBlob: blob, comment: 'me@laptop'),
          presentedBlob: presentedBlob,
          presentedType: presentedType,
        );

    test('an ed25519 key is probed first, shown as itself, signed by the agent',
        () async {
      final expected = signature('ssh-ed25519');
      final agent = signingWith(expected);
      final key = identity(agent, _ed25519Blob());

      expect(key.type, 'ssh-ed25519');
      expect(key.comment, 'me@laptop');
      // A touch or a confirmation is not spent on a key the server refuses.
      expect(key.shouldProbe, isTrue);
      expect(key.toPublicKey().encode(), _ed25519Blob());

      final challenge = Uint8List.fromList('session-and-request'.codeUnits);
      final signed = await key.sign(challenge);
      expect(signed.encode(), expected);
      expect(
        agent.requests.single,
        SshAgentProtocol.encodeSignRequest(
          keyBlob: _ed25519Blob(),
          data: challenge,
        ),
      );
    });

    test('an RSA key is offered as rsa-sha2-256 and asks the agent for it',
        () async {
      final rsaBlob = Uint8List.fromList(
          [..._utf8String('ssh-rsa'), ..._string([1, 0, 1]), ..._string([7])]);
      final agent = signingWith(signature('rsa-sha2-256', 256));
      final key = identity(agent, rsaBlob);

      expect(key.type, 'rsa-sha2-256');
      await key.sign(Uint8List.fromList([1]));
      final sent = agent.requests.single;
      expect(sent.sublist(sent.length - 4), [0, 0, 0, 2]);
    });

    test('an agent that still signs RSA with SHA-1 is refused with a reason',
        () async {
      final rsaBlob = Uint8List.fromList(_utf8String('ssh-rsa'));
      final key = identity(signingWith(signature('ssh-rsa', 256)), rsaBlob);
      await expectLater(
        key.sign(Uint8List.fromList([1])),
        throwsA(isA<SshAgentException>()
            .having((e) => e.message, 'message', contains('SHA-1'))),
      );
    });

    test('a FIDO2 sk-ed25519 key passes through untouched', () async {
      final skBlob = Uint8List.fromList([
        ..._utf8String('sk-ssh-ed25519@openssh.com'),
        ..._string(List<int>.filled(32, 5)),
        ..._utf8String('ssh:'),
      ]);
      // A security key's signature carries its flags and counter after the
      // signature itself; none of that is this app's to touch.
      final skSignature = Uint8List.fromList([
        ..._utf8String('sk-ssh-ed25519@openssh.com'),
        ..._string(List<int>.filled(64, 4)),
        0x01,
        0, 0, 0, 42,
      ]);
      final agent = signingWith(skSignature);
      final key = identity(agent, skBlob);

      expect(key.type, 'sk-ssh-ed25519@openssh.com');
      expect((await key.sign(Uint8List.fromList([3]))).encode(), skSignature);
      final sent = agent.requests.single;
      expect(sent.sublist(sent.length - 4), [0, 0, 0, 0]);
    });

    test('an ECDSA security key keeps its own algorithm name', () {
      final skBlob = Uint8List.fromList(
          _utf8String('sk-ecdsa-sha2-nistp256@openssh.com'));
      expect(identity(_FakeAgent((_) => Uint8List(0)), skBlob).type,
          'sk-ecdsa-sha2-nistp256@openssh.com');
    });

    test('with a certificate, the certificate is shown and the key signs',
        () async {
      final certBlob = Uint8List.fromList(
          [..._utf8String('ssh-ed25519-cert-v01@openssh.com'), 1, 2, 3]);
      final agent = signingWith(signature('ssh-ed25519'));
      final key = identity(
        agent,
        _ed25519Blob(),
        presentedBlob: certBlob,
        presentedType: 'ssh-ed25519-cert-v01@openssh.com',
      );

      expect(key.type, 'ssh-ed25519-cert-v01@openssh.com');
      expect(key.toPublicKey().encode(), certBlob);
      await key.sign(Uint8List.fromList([1]));
      expect(
        agent.requests.single,
        SshAgentProtocol.encodeSignRequest(
          keyBlob: _ed25519Blob(),
          data: Uint8List.fromList([1]),
        ),
      );
    });

    test('an RSA certificate is offered as rsa-sha2-256-cert', () {
      expect(agentPublicKeyAlgorithm('ssh-rsa-cert-v01@openssh.com'),
          'rsa-sha2-256-cert-v01@openssh.com');
      expect(SshAgentProtocol.flagsForKeyType('ssh-rsa-cert-v01@openssh.com'),
          SshAgentProtocol.flagRsaSha2_256);
      expect(agentPublicKeyAlgorithm('ecdsa-sha2-nistp256'),
          'ecdsa-sha2-nistp256');
    });

    test('a declined signature is the agent\'s refusal, touch included',
        () async {
      final key = identity(
        _FakeAgent((_) => Uint8List.fromList([5])),
        _ed25519Blob(),
      );
      await expectLater(
        key.sign(Uint8List.fromList([1])),
        throwsA(isA<SshAgentException>()
            .having((e) => e.kind, 'kind', SshAgentErrorKind.refused)
            .having((e) => e.message, 'message', contains('not touched'))),
      );
    });
  });

  group('ForwardedAgent, the agent a shell gets', () {
    late SSHKeyPair hostKey;
    late Uint8List hostBlob;
    final osBlob = _ed25519Blob(1);
    final osSignature = Uint8List.fromList(
        [..._utf8String('ssh-ed25519'), ..._string(List<int>.filled(64, 8))]);

    setUpAll(() {
      hostKey = SSHKeyPair.fromPem(
        SshKeygen.generateEd25519(comment: 'host').privateKeyPem,
      ).single;
      hostBlob = hostKey.toPublicKey().encode();
    });

    _FakeAgent osAgent({List<Uint8List>? blobs}) => _FakeAgent((request) {
          if (request[0] == SshAgentProtocol.requestIdentities) {
            return SshAgentProtocol.encodeIdentitiesAnswer([
              for (final blob in blobs ?? [osBlob])
                SshAgentIdentity(keyBlob: blob, comment: 'laptop'),
            ]);
          }
          return SshAgentProtocol.encodeSignResponse(osSignature);
        });

    ForwardedAgent forwarded(_FakeAgent? os, {bool withHostKey = true}) =>
        ForwardedAgent(
          osAgent: os == null ? null : SshAgentClient(connector: () async => os),
          keys: withHostKey ? [hostKey] : const [],
          comment: 'ssgo:Box',
        );

    Future<List<SshAgentIdentity>> list(ForwardedAgent agent) async =>
        SshAgentProtocol.decodeIdentitiesAnswer(await agent.handleRequest(
            SshAgentProtocol.encodeRequestIdentities()));

    test('lists this computer\'s agent and the host\'s own key', () async {
      final identities = await list(forwarded(osAgent()));
      expect(identities.map((i) => i.keyBlob), [osBlob, hostBlob]);
      expect(identities.map((i) => i.comment), ['laptop', 'ssgo:Box']);
    });

    test('a key held in both is listed once', () async {
      final identities = await list(forwarded(osAgent(blobs: [hostBlob])));
      expect(identities, hasLength(1));
    });

    test('signs with the host\'s own key here, without the OS agent',
        () async {
      final os = osAgent();
      final reply = await forwarded(os).handleRequest(
        SshAgentProtocol.encodeSignRequest(
          keyBlob: hostBlob,
          data: Uint8List.fromList([1, 2, 3]),
        ),
      );
      final signature = SshAgentProtocol.decodeSignResponse(reply);
      expect(SSHSignature.getType(signature), 'ssh-ed25519');
      expect(os.requests, isEmpty);
    });

    test('passes any other signature to the OS agent, flags and all',
        () async {
      final os = osAgent();
      final request = SshAgentProtocol.encodeSignRequest(
        keyBlob: osBlob,
        data: Uint8List.fromList([4, 5]),
        flags: SshAgentProtocol.flagRsaSha2_512,
      );
      final reply = await forwarded(os).handleRequest(request);
      expect(os.requests.single, request);
      expect(SshAgentProtocol.decodeSignResponse(reply), osSignature);
    });

    test('refuses everything but listing and signing', () async {
      final os = osAgent();
      final agent = forwarded(os);
      // add identity, remove, remove all, lock, unlock, extension
      // (session-bind@openssh.com among them).
      for (final type in [17, 18, 19, 22, 23, 25, 27]) {
        expect(await agent.handleRequest(Uint8List.fromList([type, 0, 0, 0, 0])),
            [5], reason: 'message $type');
      }
      expect(os.requests, isEmpty,
          reason: 'none of those may reach this computer\'s agent');
    });

    test('with no agent running, only the host\'s key is there', () async {
      final agent = ForwardedAgent(
        osAgent: SshAgentClient(
          connector: () async => throw const SshAgentException(
            SshAgentErrorKind.noAgent,
            'No SSH agent found.',
          ),
        ),
        keys: [hostKey],
      );
      expect((await list(agent)).single.keyBlob, hostBlob);
      expect(
        await agent.handleRequest(SshAgentProtocol.encodeSignRequest(
          keyBlob: osBlob,
          data: Uint8List.fromList([1]),
        )),
        [5],
      );
    });

    test('with no keys at all it is an empty agent, not a broken one',
        () async {
      expect(await list(forwarded(null, withHostKey: false)), isEmpty);
    });

    test('a malformed or refused sign request is a plain failure', () async {
      expect(await forwarded(osAgent()).handleRequest(Uint8List.fromList([13, 0])),
          [5]);
      final refusing = _FakeAgent((request) =>
          request[0] == SshAgentProtocol.signRequest
              ? Uint8List.fromList([5])
              : SshAgentProtocol.encodeIdentitiesAnswer(const []));
      expect(
        await forwarded(refusing).handleRequest(SshAgentProtocol.encodeSignRequest(
          keyBlob: osBlob,
          data: Uint8List.fromList([1]),
        )),
        [5],
      );
      expect(await forwarded(osAgent()).handleRequest(Uint8List(0)), [5]);
    });

    test('an identities answer reads back as written', () {
      final written = SshAgentProtocol.encodeIdentitiesAnswer([
        SshAgentIdentity(keyBlob: osBlob, comment: 'a'),
        SshAgentIdentity(keyBlob: hostBlob, comment: 'b'),
      ]);
      final read = SshAgentProtocol.decodeIdentitiesAnswer(written);
      expect(read.map((i) => i.comment), ['a', 'b']);
      expect(SSHRawSignature(osSignature).encode(), osSignature);
    });
  });

  group('finding the agent on Windows', () {
    late List<String> opened;
    late bool askedPageant;

    Future<SshAgentConnection> open(
      Map<String, String> environment, {
      Set<String> present = const {},
      SshAgentConnection? pageant,
    }) {
      opened = [];
      askedPageant = false;
      return SshAgentClient.openWindowsAgent(
        environment: environment,
        openPipe: (path) async {
          opened.add(path);
          if (!present.contains(path)) {
            throw const FileSystemException('The system cannot find the file');
          }
          return _NullConnection(path);
        },
        findPageant: () async {
          askedPageant = true;
          return pageant;
        },
      );
    }

    test('an SSH_AUTH_SOCK that is a file is never opened, and the search '
        'goes on', () async {
      final connection = await open(
        {'SSH_AUTH_SOCK': r'C:\Users\me\.ssh\agent.sock'},
        present: {SshAgentClient.openSshAgentPipe},
      );
      expect(opened, [SshAgentClient.openSshAgentPipe]);
      expect((connection as _NullConnection).path,
          SshAgentClient.openSshAgentPipe);
    });

    test('nor is a Cygwin-style socket path; Pageant is still found',
        () async {
      final pageant = _NullConnection('pageant');
      final connection = await open(
        {'SSH_AUTH_SOCK': '/tmp/ssh-XXXX/agent.1234'},
        pageant: pageant,
      );
      expect(opened, [SshAgentClient.openSshAgentPipe]);
      expect(connection, same(pageant));
    });

    test('an SSH_AUTH_SOCK that names a pipe comes first', () async {
      const pipe = r'\\.\pipe\my-agent';
      final connection =
          await open({'SSH_AUTH_SOCK': pipe}, present: {pipe});
      expect(opened, [pipe]);
      expect((connection as _NullConnection).path, pipe);
      expect(askedPageant, isFalse);
    });

    test('with none, says so, and why SSH_AUTH_SOCK was passed over',
        () async {
      await expectLater(
        open({'SSH_AUTH_SOCK': r'C:\agent.sock'}),
        throwsA(isA<SshAgentException>()
            .having((e) => e.kind, 'kind', SshAgentErrorKind.noAgent)
            .having((e) => e.details, 'details', contains('not a named pipe'))),
      );
      expect(askedPageant, isTrue);
    });

    test('pipe paths', () {
      expect(SshAgentClient.isWindowsPipePath(r'\\.\pipe\openssh-ssh-agent'),
          isTrue);
      expect(SshAgentClient.isWindowsPipePath(r'\\.\PIPE\x'), isTrue);
      expect(SshAgentClient.isWindowsPipePath(r'\\.\pipe\'), isFalse);
      expect(SshAgentClient.isWindowsPipePath(r'\\.\pipe\a\b'), isFalse);
      expect(SshAgentClient.isWindowsPipePath(r'C:\agent'), isFalse);
      expect(SshAgentClient.isWindowsPipePath(r'\\server\pipe\x'), isFalse);
    });
  });

  group("Pageant's pipe name, as PuTTY makes it", () {
    test('"Pageant", NUL, zero-padded to a block of sixteen', () {
      expect(pageantSuffixBlock(),
          [...ascii.encode('Pageant'), ...List.filled(9, 0)]);
    });

    test('the user and a SHA-256 of the protected block as an SSH string',
        () {
      final block = Uint8List.fromList(List.generate(16, (i) => i * 7));
      final digest = sha256OfSshString(block);
      expect(
        latin1.decode(pageantPipeName(
          userName: ascii.encode('alice'),
          protectedBlock: block,
        )),
        '\\\\.\\pipe\\pageant.alice.$digest',
      );
      expect(digest, hasLength(64));
    });

    test('the principal name is cut at its @, as PuTTY does', () {
      expect(pageantUserName(ascii.encode('alice@corp.example')),
          ascii.encode('alice'));
      expect(pageantUserName(ascii.encode('bob')), ascii.encode('bob'));
    });
  });
}

/// SHA-256 of [bytes] behind a big-endian uint32 length, in hex — written
/// out longhand here so the test does not just repeat the code.
String sha256OfSshString(Uint8List bytes) {
  final message = [
    (bytes.length >> 24) & 0xff,
    (bytes.length >> 16) & 0xff,
    (bytes.length >> 8) & 0xff,
    bytes.length & 0xff,
    ...bytes,
  ];
  return sha256.convert(message).toString();
}

class _NullConnection implements SshAgentConnection {
  _NullConnection(this.path);
  final String path;
  @override
  Future<Uint8List> request(Uint8List payload) async => Uint8List(0);
  @override
  Future<void> close() async {}
}
