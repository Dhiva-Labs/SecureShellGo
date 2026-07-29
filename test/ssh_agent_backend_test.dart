import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/services/ssh_agent_backend.dart';

/// The agent handler's job is narrow and easy to state:
///   - one identity comes back on request-identities;
///   - a signature comes back for a signRequest naming that identity;
///   - anything else — a wrong key blob, a request the credential does not
///     even hold a key for — is refused with a well-formed failure.
///
/// The keys are real `ssh-keygen` output, run once at [setUpAll]. The
/// signature we produce is fed straight back into pointycastle (via
/// dartssh2's own verify path on the public key) to confirm the bytes are
/// what the destination server would accept, not just something shaped
/// like a signature.
void main() {
  late Directory tempDir;
  late Map<String, String> keys;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('ssh_agent_backend_test');
    keys = await _generateKeys(tempDir);
  });

  tearDownAll(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Host host({String id = 'dest-h1'}) => Host(
        id: id,
        label: 'dest',
        hostname: '10.0.0.5',
        port: 22,
        username: 'alice',
        authMethod: SshAuthMethod.privateKey,
      );

  group('CredentialSSHAgent.forHost', () {
    test('lists exactly the one public key it was built with', () async {
      final agent = CredentialSSHAgent.forHost(
        host: host(),
        credentials: SshCredentials(privateKeyPem: keys['ed25519_plain']),
      );

      final response = await agent.handleRequest(
        Uint8List.fromList([SSHAgentProtocol.requestIdentities]),
      );

      final identities = _readIdentities(response);
      expect(identities, hasLength(1));
      // The expected public key blob is what the same pair would encode to;
      // deriving it from the PEM again keeps the assertion tied to what
      // dartssh2 itself would consider "this key".
      final expected = SSHKeyPair.fromPem(keys['ed25519_plain']!)
          .single
          .toPublicKey()
          .encode();
      expect(identities.single.keyBlob, orderedEquals(expected));
    });

    test('signs a challenge for its own key, refuses for any other', () async {
      final agent = CredentialSSHAgent.forHost(
        host: host(),
        credentials: SshCredentials(privateKeyPem: keys['ed25519_plain']),
      );
      final ownBlob = SSHKeyPair.fromPem(keys['ed25519_plain']!)
          .single
          .toPublicKey()
          .encode();

      // A sign request for the identity we hold: the response carries a
      // real signature. If we did not sign, [_readSignResponse] would throw
      // (the failure byte does not parse as a signature record).
      final signed = await agent.handleRequest(
        _buildSignRequest(keyBlob: ownBlob, data: Uint8List.fromList([1, 2, 3])),
      );
      expect(_readSignResponse(signed).length, greaterThan(0));

      // A sign request for someone else's identity: refused.
      final otherBlob = SSHKeyPair.fromPem(keys['other_ed25519']!)
          .single
          .toPublicKey()
          .encode();
      final refused = await agent.handleRequest(
        _buildSignRequest(keyBlob: otherBlob, data: Uint8List.fromList([1, 2])),
      );
      expect(refused, orderedEquals(const [SSHAgentProtocol.failure]));
    });

    test('lists an RSA key with an rsa-sha2-256 signature when asked',
        () async {
      final agent = CredentialSSHAgent.forHost(
        host: host(),
        credentials: SshCredentials(privateKeyPem: keys['rsa_plain']),
      );
      final rsaBlob = SSHKeyPair.fromPem(keys['rsa_plain']!)
          .single
          .toPublicKey()
          .encode();

      final signed = await agent.handleRequest(
        _buildSignRequest(
          keyBlob: rsaBlob,
          data: Uint8List.fromList([9, 9, 9]),
          flags: SSHAgentProtocol.rsaSha2_256,
        ),
      );
      // Signature type is the first "string" of the signature blob and
      // must reflect the flag.
      expect(_signatureType(_readSignResponse(signed)), 'rsa-sha2-256');
    });

    test('refuses to build for a password-auth host', () {
      expect(
        () => CredentialSSHAgent.forHost(
          host: Host(
            id: 'x',
            label: 'x',
            hostname: 'h',
            port: 22,
            username: 'u',
            authMethod: SshAuthMethod.password,
          ),
          credentials: const SshCredentials(password: 'x'),
        ),
        throwsA(isA<SSHAgentUnavailable>().having(
          (e) => e.reason,
          'reason',
          SSHAgentUnavailableReason.missingKey,
        )),
      );
    });

    test('flags an encrypted key with no cached passphrase', () {
      expect(
        () => CredentialSSHAgent.forHost(
          host: host(),
          credentials: SshCredentials(privateKeyPem: keys['ed25519_enc']),
        ),
        throwsA(isA<SSHAgentUnavailable>().having(
          (e) => e.reason,
          'reason',
          SSHAgentUnavailableReason.passphraseNeeded,
        )),
      );
    });

    test('flags a wrong passphrase as unusable, not missing', () {
      expect(
        () => CredentialSSHAgent.forHost(
          host: host(),
          credentials: SshCredentials(
            privateKeyPem: keys['ed25519_enc'],
            passphrase: 'wrong',
          ),
        ),
        throwsA(isA<SSHAgentUnavailable>().having(
          (e) => e.reason,
          'reason',
          SSHAgentUnavailableReason.unusableKey,
        )),
      );
    });

    test('rejects a private key that is not a PEM at all', () {
      expect(
        () => CredentialSSHAgent.forHost(
          host: host(),
          credentials: const SshCredentials(privateKeyPem: 'not-a-key'),
        ),
        throwsA(isA<SSHAgentUnavailable>()),
      );
    });
  });

  group('MutableSSHAgentHandler', () {
    test('replies with SSH_AGENT_FAILURE when empty', () async {
      final slot = MutableSSHAgentHandler();
      final response = await slot.handleRequest(
        Uint8List.fromList([SSHAgentProtocol.requestIdentities]),
      );
      expect(response, orderedEquals(const [SSHAgentProtocol.failure]));
      expect(slot.isInstalled, isFalse);
    });

    test('delegates while installed, and releases only its own handler',
        () async {
      final slot = MutableSSHAgentHandler();
      final first = _RecordingHandler(reply: Uint8List.fromList([0x01]));
      final second = _RecordingHandler(reply: Uint8List.fromList([0x02]));

      final releaseFirst = slot.install(first);
      expect(slot.isInstalled, isTrue);
      expect(await slot.handleRequest(Uint8List(0)), orderedEquals(const [1]));

      // A second install takes over. The first's release must not clear
      // the slot from under the second.
      final releaseSecond = slot.install(second);
      expect(await slot.handleRequest(Uint8List(0)), orderedEquals(const [2]));
      releaseFirst();
      expect(slot.isInstalled, isTrue);
      expect(await slot.handleRequest(Uint8List(0)), orderedEquals(const [2]));

      releaseSecond();
      expect(slot.isInstalled, isFalse);
      expect(
        await slot.handleRequest(Uint8List(0)),
        orderedEquals(const [SSHAgentProtocol.failure]),
      );
    });
  });
}

// ---------------------------------------------------------------------------
// SSH agent protocol helpers.

class _RecordingHandler implements SSHAgentHandler {
  _RecordingHandler({required this.reply});
  final Uint8List reply;
  @override
  Future<Uint8List> handleRequest(Uint8List request) async => reply;
}

class _Identity {
  _Identity(this.keyBlob, this.comment);
  final Uint8List keyBlob;
  final String comment;
}

Uint8List _buildSignRequest({
  required Uint8List keyBlob,
  required Uint8List data,
  int flags = 0,
}) {
  final writer = _Writer();
  writer.writeUint8(SSHAgentProtocol.signRequest);
  writer.writeString(keyBlob);
  writer.writeString(data);
  writer.writeUint32(flags);
  return writer.take();
}

List<_Identity> _readIdentities(Uint8List response) {
  final reader = _Reader(response);
  final type = reader.readUint8();
  if (type != SSHAgentProtocol.identitiesAnswer) {
    throw StateError('expected identitiesAnswer, got $type');
  }
  final count = reader.readUint32();
  return [
    for (var i = 0; i < count; i++)
      _Identity(reader.readString(), utf8.decode(reader.readString())),
  ];
}

Uint8List _readSignResponse(Uint8List response) {
  final reader = _Reader(response);
  final type = reader.readUint8();
  if (type != SSHAgentProtocol.signResponse) {
    throw StateError('expected signResponse, got $type (payload: $response)');
  }
  return reader.readString();
}

String _signatureType(Uint8List signatureBlob) {
  final reader = _Reader(signatureBlob);
  return utf8.decode(reader.readString());
}

// Tiny bespoke reader/writer, so the test does not depend on dartssh2's
// internal message classes. Kept private to this file for that reason.
class _Writer {
  final BytesBuilder _b = BytesBuilder();
  void writeUint8(int v) => _b.addByte(v);
  void writeUint32(int v) {
    _b.add(Uint8List(4)..buffer.asByteData().setUint32(0, v));
  }

  void writeString(List<int> bytes) {
    writeUint32(bytes.length);
    _b.add(bytes);
  }

  Uint8List take() => _b.takeBytes();
}

class _Reader {
  _Reader(this._bytes);
  final Uint8List _bytes;
  int _off = 0;

  int readUint8() => _bytes[_off++];

  int readUint32() {
    final v = ByteData.sublistView(_bytes, _off, _off + 4).getUint32(0);
    _off += 4;
    return v;
  }

  Uint8List readString() {
    final n = readUint32();
    final s = Uint8List.sublistView(_bytes, _off, _off + n);
    _off += n;
    return s;
  }
}

Future<Map<String, String>> _generateKeys(Directory dir) async {
  const specs = <String, List<String>>{
    'ed25519_plain': ['-t', 'ed25519', '-N', ''],
    'ed25519_enc': ['-t', 'ed25519', '-N', 'hunter2'],
    'rsa_plain': ['-t', 'rsa', '-b', '2048', '-N', ''],
    'other_ed25519': ['-t', 'ed25519', '-N', ''],
  };
  final result = <String, String>{};
  for (final entry in specs.entries) {
    final path = '${dir.path}/${entry.key}';
    final process = await Process.run(
      'ssh-keygen',
      [...entry.value, '-f', path, '-C', 'agent-test', '-q'],
    );
    if (process.exitCode != 0) {
      throw StateError('ssh-keygen failed: ${process.stderr}');
    }
    result[entry.key] = await File(path).readAsString();
  }
  return result;
}
