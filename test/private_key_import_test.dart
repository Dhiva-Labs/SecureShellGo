import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/private_key_import.dart';

/// Exercises [classifyPrivateKeyPem] against real `ssh-keygen`/`openssl`
/// output, the same way `ssh_service_test.dart` exercises connect-time key
/// parsing — this is deliberately the same parser, just run without ever
/// opening a socket, which is what backs the host-edit screen's
/// "Import key file" picker.
void main() {
  late Directory tempDir;
  late Map<String, String> keys;

  setUpAll(() async {
    tempDir =
        await Directory.systemTemp.createTemp('private_key_import_test');
    keys = await _generateKeys(tempDir);
  });

  tearDownAll(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  group('valid unencrypted keys', () {
    test('OpenSSH ed25519', () {
      final result = classifyPrivateKeyPem(keys['ed25519_plain']!);
      expect(result.status, PrivateKeyImportStatus.valid);
      expect(result.keyType, 'ed25519');
    });

    test('OpenSSH RSA', () {
      final result = classifyPrivateKeyPem(keys['rsa_plain']!);
      expect(result.status, PrivateKeyImportStatus.valid);
      expect(result.keyType, 'RSA');
    });

    test('PKCS#1 RSA PEM — the classic AWS EC2 .pem format', () {
      final result = classifyPrivateKeyPem(keys['rsa_pem']!);
      expect(result.status, PrivateKeyImportStatus.valid);
      expect(result.keyType, 'RSA');
    });

    test('OpenSSH ECDSA', () {
      final result = classifyPrivateKeyPem(keys['ecdsa_plain']!);
      expect(result.status, PrivateKeyImportStatus.valid);
      expect(result.keyType, startsWith('ECDSA'));
    });

    test('legacy "EC PRIVATE KEY" (openssl ecparam)', () {
      final result = classifyPrivateKeyPem(keys['ec_pem']!);
      expect(result.status, PrivateKeyImportStatus.valid);
      expect(result.keyType, startsWith('ECDSA'));
    });

    test('surrounding whitespace does not change the verdict', () {
      final result = classifyPrivateKeyPem('\n\n  ${keys['rsa_pem']}  \n\n');
      expect(result.status, PrivateKeyImportStatus.valid);
    });
  });

  group('passphrase-protected keys', () {
    test('OpenSSH ed25519, encrypted', () {
      final result = classifyPrivateKeyPem(keys['ed25519_enc']!);
      expect(result.status, PrivateKeyImportStatus.passphraseProtected);
      expect(result.keyType, 'OpenSSH key');
    });

    test('PKCS#1 RSA PEM, encrypted — the AWS format with a passphrase', () {
      final result = classifyPrivateKeyPem(keys['rsa_pem_enc']!);
      expect(result.status, PrivateKeyImportStatus.passphraseProtected);
      expect(result.keyType, 'RSA');
    });
  });

  group('rejected input', () {
    test('garbage text', () {
      final result = classifyPrivateKeyPem('not a key at all');
      expect(result.status, PrivateKeyImportStatus.invalid);
      expect(result.message, contains('does not look like a private key'));
    });

    test('an empty file', () {
      final result = classifyPrivateKeyPem('');
      expect(result.status, PrivateKeyImportStatus.invalid);
      expect(result.message, contains('empty'));
    });

    test('a well-formed PEM block that is not a private key', () {
      final result = classifyPrivateKeyPem(
        '-----BEGIN CERTIFICATE-----\nMAAA\n-----END CERTIFICATE-----',
      );
      expect(result.status, PrivateKeyImportStatus.invalid);
      expect(result.message, contains('Unsupported'));
    });

    test('PKCS#8, which dartssh2 does not implement', () {
      final result = classifyPrivateKeyPem(keys['pkcs8']!);
      expect(result.status, PrivateKeyImportStatus.invalid);
      expect(result.message, contains('PKCS#8'));
    });

    test('oversize input is rejected before it is even parsed', () {
      final huge = '-----BEGIN OPENSSH PRIVATE KEY-----\n'
          '${'A' * (kMaxPrivateKeyImportBytes + 1)}\n'
          '-----END OPENSSH PRIVATE KEY-----';
      final result = classifyPrivateKeyPem(huge);
      expect(result.status, PrivateKeyImportStatus.invalid);
      expect(result.message, contains('byte limit'));
    });

    test('a file right at the cap is not treated as oversize', () {
      // Confirms the cap is ">" the limit, not ">=" — the boundary itself is
      // still allowed through to the real parser (and fails there instead,
      // on its own merits, same as any other garbage of a normal size).
      final atCap = 'x' * kMaxPrivateKeyImportBytes;
      final result = classifyPrivateKeyPem(atCap);
      expect(result.status, PrivateKeyImportStatus.invalid);
      expect(result.message, isNot(contains('byte limit')));
    });
  });
}

Future<Map<String, String>> _generateKeys(Directory dir) async {
  final result = <String, String>{};

  const specs = <String, List<String>>{
    'ed25519_plain': ['-t', 'ed25519', '-N', ''],
    'ed25519_enc': ['-t', 'ed25519', '-N', 'hunter2'],
    'rsa_plain': ['-t', 'rsa', '-b', '2048', '-N', ''],
    'rsa_pem': ['-t', 'rsa', '-b', '2048', '-m', 'PEM', '-N', ''],
    'rsa_pem_enc': ['-t', 'rsa', '-b', '2048', '-m', 'PEM', '-N', 'hunter2'],
    'ecdsa_plain': ['-t', 'ecdsa', '-N', ''],
  };
  for (final entry in specs.entries) {
    final path = '${dir.path}/${entry.key}';
    final process = await Process.run(
      'ssh-keygen',
      [...entry.value, '-f', path, '-C', 'test', '-q'],
    );
    if (process.exitCode != 0) {
      throw StateError('ssh-keygen failed: ${process.stderr}');
    }
    result[entry.key] = await File(path).readAsString();
  }

  // A legacy SEC1 "EC PRIVATE KEY", which ssh-keygen cannot emit directly —
  // this is the format `SshService`'s EC branch (and this classifier) reads
  // via dartssh2's `EcKeyPair`.
  final ecPath = '${dir.path}/ec_pem';
  final ecGen = await Process.run(
    'openssl',
    ['ecparam', '-name', 'prime256v1', '-genkey', '-noout', '-out', ecPath],
  );
  if (ecGen.exitCode != 0) {
    throw StateError('openssl ecparam failed: ${ecGen.stderr}');
  }
  result['ec_pem'] = await File(ecPath).readAsString();

  // A PKCS#8 key ("BEGIN PRIVATE KEY"), which dartssh2 does not implement at
  // all — this is the "clear unsupported format" case.
  final pkcs8Path = '${dir.path}/pkcs8';
  final pkcs8Gen = await Process.run(
    'openssl',
    [
      'pkcs8',
      '-topk8',
      '-nocrypt',
      '-in',
      '${dir.path}/rsa_pem',
      '-out',
      pkcs8Path,
    ],
  );
  if (pkcs8Gen.exitCode != 0) {
    throw StateError('openssl pkcs8 failed: ${pkcs8Gen.stderr}');
  }
  result['pkcs8'] = await File(pkcs8Path).readAsString();

  return result;
}
