import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/ssh_keygen.dart';

/// Exercises [SshKeygen] two ways: purely in-process against dartssh2's own
/// parser/signer (the round trip the "Generate new key" action depends on),
/// and against a real `ssh-keygen` binary (proof the PEM this produces is not
/// merely something *we* can read back, but a real openssh-key-v1 file).
void main() {
  group('generateEd25519', () {
    test('the private key parses back through SSHKeyPair.fromPem', () {
      final generated = SshKeygen.generateEd25519(comment: 'secureshellgo@box');

      final pairs = SSHKeyPair.fromPem(generated.privateKeyPem);
      expect(pairs, hasLength(1));
      expect(pairs.single.name, 'ssh-ed25519');
    });

    test('the parsed key signs, and the public half verifies it', () {
      final generated = SshKeygen.generateEd25519(comment: 'secureshellgo@box');
      final pair = SSHKeyPair.fromPem(generated.privateKeyPem).single;

      final message = Uint8List.fromList(utf8.encode('round-trip probe'));
      final signature = pair.sign(message);

      // The concrete ed25519 host-key type isn't re-exported by dartssh2's
      // public surface (only the abstract SSHHostKey/SSHSignature are) — a
      // dynamic call reaches its `verify` without reimporting dartssh2's
      // internals, and without this test re-implementing the crypto dartssh2
      // already has.
      final dynamic publicKey = pair.toPublicKey();
      expect(publicKey.verify(message, signature) as bool, isTrue);

      final tampered = Uint8List.fromList(utf8.encode('round-trip probe!'));
      expect(() => publicKey.verify(tampered, signature), throwsA(anything));
    });

    test('the public line is "ssh-ed25519 <base64> <comment>"', () {
      final generated = SshKeygen.generateEd25519(comment: 'secureshellgo@box');
      final parts = generated.publicKeyLine.split(' ');

      expect(parts, hasLength(3));
      expect(parts[0], 'ssh-ed25519');
      expect(parts[2], 'secureshellgo@box');

      final pair = SSHKeyPair.fromPem(generated.privateKeyPem).single;
      expect(base64.decode(parts[1]), pair.toPublicKey().encode());
    });

    test('two calls never produce the same key', () {
      final a = SshKeygen.generateEd25519(comment: 'x');
      final b = SshKeygen.generateEd25519(comment: 'x');

      expect(a.privateKeyPem, isNot(equals(b.privateKeyPem)));
      expect(a.publicKeyLine, isNot(equals(b.publicKeyLine)));
    });

    test('a real ssh-keygen accepts the PEM and derives the same public key',
        () async {
      final tempDir = await Directory.systemTemp.createTemp('ssh_keygen_test');
      addTearDown(() => tempDir.delete(recursive: true));

      final generated =
          SshKeygen.generateEd25519(comment: 'secureshellgo@interop');
      final keyFile = File('${tempDir.path}/id_ed25519');
      await keyFile.writeAsString(generated.privateKeyPem);
      // ssh-keygen refuses to read a private key with loose permissions.
      await Process.run('chmod', ['600', keyFile.path]);

      final result = await Process.run(
        'ssh-keygen',
        ['-y', '-f', keyFile.path],
      );
      expect(result.exitCode, 0, reason: result.stderr.toString());

      final theirs = (result.stdout as String).trim().split(' ');
      final ours = generated.publicKeyLine.split(' ');
      expect(theirs[0], ours[0]);
      expect(theirs[1], ours[1]); // the exact same base64 key blob
    });
  });

  group('publicLineFromPem', () {
    test('matches what ssh-keygen itself wrote to the .pub file', () async {
      final tempDir = await Directory.systemTemp.createTemp('ssh_keygen_test');
      addTearDown(() => tempDir.delete(recursive: true));

      final keyFile = File('${tempDir.path}/id_ed25519');
      final gen = await Process.run('ssh-keygen', [
        '-t', 'ed25519',
        '-N', '',
        '-C', 'someone@example.com',
        '-f', keyFile.path,
      ]);
      expect(gen.exitCode, 0, reason: gen.stderr.toString());

      final pem = await keyFile.readAsString();
      final line = SshKeygen.publicLineFromPem(
        pem,
        comment: 'someone@example.com',
      );

      final expected = (await File('${keyFile.path}.pub').readAsString()).trim();
      expect(line, expected);
    });

    test('an encrypted key needs its passphrase', () async {
      final tempDir = await Directory.systemTemp.createTemp('ssh_keygen_test');
      addTearDown(() => tempDir.delete(recursive: true));

      final keyFile = File('${tempDir.path}/id_ed25519');
      final gen = await Process.run('ssh-keygen', [
        '-t', 'ed25519',
        '-N', 'sekrit',
        '-C', 'locked@example.com',
        '-f', keyFile.path,
      ]);
      expect(gen.exitCode, 0, reason: gen.stderr.toString());

      final pem = await keyFile.readAsString();

      expect(
        () => SshKeygen.publicLineFromPem(pem, comment: 'locked@example.com'),
        throwsA(isA<SSHKeyDecryptError>()),
      );

      final line = SshKeygen.publicLineFromPem(
        pem,
        passphrase: 'sekrit',
        comment: 'locked@example.com',
      );
      final expected = (await File('${keyFile.path}.pub').readAsString()).trim();
      expect(line, expected);
    });

    test('garbage input is rejected, not silently accepted', () {
      expect(
        () => SshKeygen.publicLineFromPem('not a key', comment: 'x'),
        throwsA(anything),
      );
    });
  });
}
