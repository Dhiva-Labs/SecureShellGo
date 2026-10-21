import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/ssh_certificate.dart';

/// Certificates as `ssh-keygen -s` writes them.
///
/// Generated per run by the real tool, as `ssh_service_test.dart` does its
/// keys, so these hold against OpenSSH's own output rather than against a
/// hand-built blob that agrees with the parser by construction.
void main() {
  late Directory dir;
  String read(String name) => File('${dir.path}/$name').readAsStringSync();
  Uint8List blobOf(String pubFile) =>
      base64.decode(read(pubFile).trim().split(' ')[1]);

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('ssh_certificate_test');
    Future<void> run(List<String> args) async {
      final result = await Process.run('ssh-keygen', args);
      if (result.exitCode != 0) {
        throw StateError('ssh-keygen ${args.join(' ')}: ${result.stderr}');
      }
    }

    String at(String name) => '${dir.path}/$name';
    Future<void> key(String name, String type) => run([
          '-q', '-t', type, if (type == 'rsa') ...['-b', '2048'], '-N', '',
          '-C', name, '-f', at(name),
        ]);
    await key('ca', 'ed25519');
    await key('user', 'ed25519');
    await key('other', 'ed25519');
    await key('rsa', 'rsa');
    await key('ecdsa', 'ecdsa');
    // Each certificate signs its own copy of the key, so the -cert.pub
    // files do not overwrite one another.
    for (final copy in ['user-forever', 'user-expired', 'user-host']) {
      File(at('$copy.pub')).writeAsStringSync(read('user.pub'));
    }
    await run(['-q', '-s', at('ca'), '-I', 'alice@example', '-n',
      'dev,deploy', '-V', '20250101Z:20350101Z', '-O', 'no-port-forwarding',
      '-O', 'force-command=/bin/true', at('user.pub')]);
    await run(['-q', '-s', at('ca'), '-I', 'forever', '-V', 'always:forever',
      at('user-forever.pub')]);
    await run(['-q', '-s', at('ca'), '-I', 'old', '-n', 'dev', '-V',
      '20200101Z:20200102Z', at('user-expired.pub')]);
    await run(['-q', '-s', at('ca'), '-h', '-I', 'a-server', '-n',
      'host.example', at('user-host.pub')]);
    await run(['-q', '-s', at('ca'), '-I', 'rsa-id', '-n', 'dev',
      at('rsa.pub')]);
    await run(['-q', '-s', at('ca'), '-I', 'ecdsa-id', '-n', 'dev',
      at('ecdsa.pub')]);
  });

  tearDownAll(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  group('reading what ssh-keygen wrote', () {
    test('an ed25519 user certificate', () {
      final cert = SshCertificate.parse(read('user-cert.pub'));
      expect(cert.type, 'ssh-ed25519-cert-v01@openssh.com');
      expect(cert.keyType, 'ssh-ed25519');
      expect(cert.keyTypeLabel, 'ED25519');
      expect(cert.publicKeyAlgorithm, 'ssh-ed25519-cert-v01@openssh.com');
      expect(cert.isUserCertificate, isTrue);
      expect(cert.keyId, 'alice@example');
      expect(cert.principals, ['dev', 'deploy']);
      expect(cert.validAfter, DateTime.utc(2025));
      expect(cert.validBefore, DateTime.utc(2035));
      expect(cert.criticalOptions, ['force-command']);
      expect(cert.extensions, contains('permit-pty'));
      expect(cert.extensions, isNot(contains('permit-port-forwarding')));
      expect(cert.signingKeyType, 'ssh-ed25519');
      expect(cert.signingKeyBlob, blobOf('ca.pub'));
    });

    test('the certified key is the plain key it was made from', () {
      final cert = SshCertificate.parse(read('user-cert.pub'));
      expect(cert.publicKeyBlob, blobOf('user.pub'));
      expect(cert.certifies(blobOf('user.pub')), isTrue);
      expect(cert.certifies(blobOf('other.pub')), isFalse);
    });

    test('fingerprints match ssh-keygen -l', () async {
      final cert = SshCertificate.parse(read('user-cert.pub'));
      final listed = await Process.run(
        'ssh-keygen',
        ['-l', '-f', '${dir.path}/user.pub'],
      );
      expect('${listed.stdout}', contains(cert.publicKeyFingerprint));
      final ca = await Process.run('ssh-keygen', ['-l', '-f', '${dir.path}/ca.pub']);
      expect('${ca.stdout}', contains(cert.signingKeyFingerprint));
    });

    test('an RSA certificate is presented as rsa-sha2-256-cert', () {
      final cert = SshCertificate.parse(read('rsa-cert.pub'));
      expect(cert.keyType, 'ssh-rsa');
      expect(cert.publicKeyAlgorithm, 'rsa-sha2-256-cert-v01@openssh.com');
      expect(cert.certifies(blobOf('rsa.pub')), isTrue);
    });

    test('an ECDSA certificate', () {
      final cert = SshCertificate.parse(read('ecdsa-cert.pub'));
      expect(cert.keyType, 'ecdsa-sha2-nistp256');
      expect(cert.keyTypeLabel, 'ECDSA P-256');
      expect(cert.certifies(blobOf('ecdsa.pub')), isTrue);
    });

    test('"always" and "forever" read as no limit', () {
      final cert = SshCertificate.parse(read('user-forever-cert.pub'));
      expect(cert.validAfter, isNull);
      expect(cert.validBefore, isNull);
      expect(cert.principals, isEmpty);
      expect(cert.validityAt(DateTime(1990)), SshCertificateValidity.valid);
      expect(cert.validityAt(DateTime(2999)), SshCertificateValidity.valid);
    });

    test('the line survives a round trip, comment and all', () {
      final text = read('user-cert.pub');
      final cert = SshCertificate.parse(text);
      expect(cert.line, text.trim());
      expect(SshCertificate.parse(cert.line).blob, cert.blob);
    });

    test('pasted with blank lines and a comment line around it', () {
      final cert = SshCertificate.parse(
        '\n# from the CA\n  ${read('user-cert.pub').trim()}  \n\n',
      );
      expect(cert.keyId, 'alice@example');
    });
  });

  group('validity', () {
    late SshCertificate cert;
    setUp(() => cert = SshCertificate.parse(read('user-cert.pub')));

    test('before, during and after', () {
      expect(cert.validityAt(DateTime.utc(2024, 12, 31)),
          SshCertificateValidity.notYetValid);
      expect(cert.validityAt(DateTime.utc(2030)), SshCertificateValidity.valid);
      expect(cert.validityAt(DateTime.utc(2035, 1, 2)),
          SshCertificateValidity.expired);
    });

    test('says when it expired, and what to do', () {
      final expired = SshCertificate.parse(read('user-expired-cert.pub'));
      final problem = expired.validityProblemAt(DateTime.utc(2026));
      expect(problem, contains('expired on 2020-01-02'));
      expect(problem, contains('renewed'));
      expect(cert.validityProblemAt(DateTime.utc(2030)), isNull);
    });

    test('says when it starts', () {
      final problem = cert.validityProblemAt(DateTime.utc(2024));
      expect(problem, contains('not valid until 2025-01-01'));
    });
  });

  group('matching the key', () {
    late SshCertificate cert;
    setUp(() => cert = SshCertificate.parse(read('user-cert.pub')));

    test('the right key matches', () {
      expect(cert.mismatchWith(blobOf('user.pub')), isNull);
    });

    test('another key of the same type is named by fingerprint', () {
      final problem = cert.mismatchWith(blobOf('other.pub'));
      expect(problem, contains('different key'));
      expect(problem, contains(cert.publicKeyFingerprint));
      expect(problem, contains(sshKeyFingerprint(blobOf('other.pub'))));
    });

    test('a key of another type says both types', () {
      expect(
        cert.mismatchWith(blobOf('rsa.pub')),
        'This certificate is for an ED25519 key, but this host signs in '
        'with an RSA key.',
      );
    });

    test('an RSA modulus with a spare leading zero is the same key', () {
      final rsa = blobOf('rsa.pub');
      final fields = _fields(rsa);
      final padded = _blob([fields[0], fields[1], [0, ...fields[2]]]);
      expect(samePublicKey(rsa, padded), isTrue);
      expect(samePublicKey(rsa, blobOf('ecdsa.pub')), isFalse);
    });
  });

  group('what it is instead', () {
    Matcher refused(String message) => throwsA(
          isA<SshCertificateException>()
              .having((e) => e.message, 'message', contains(message)),
        );

    test('a plain public key', () {
      expect(() => SshCertificate.parse(read('user.pub')),
          refused('public key, not a certificate'));
    });

    test('a private key', () {
      expect(() => SshCertificate.parse(read('user')),
          refused('private key, not a certificate'));
    });

    test('a host certificate', () {
      expect(() => SshCertificate.parse(read('user-host-cert.pub')),
          refused('host certificate'));
    });

    test('a truncated line', () {
      final line = read('user-cert.pub').trim().split(' ');
      final cut = base64.encode(base64.decode(line[1]).sublist(0, 120));
      expect(() => SshCertificate.parse('${line[0]} $cut'), refused('damaged'));
    });

    test('a declared type that the blob contradicts', () {
      final line = read('user-cert.pub').trim().split(' ');
      expect(
        () => SshCertificate.parse(
            'ecdsa-sha2-nistp256-cert-v01@openssh.com ${line[1]}'),
        refused('damaged'),
      );
    });

    test('not base64', () {
      expect(
        () => SshCertificate.parse(
            'ssh-ed25519-cert-v01@openssh.com not*base64'),
        refused('damaged'),
      );
    });

    test('DSA', () {
      expect(() => SshCertificate.parse('ssh-dss-cert-v01@openssh.com AAAA'),
          refused('DSA'));
    });

    test('nothing, or anything else', () {
      expect(() => SshCertificate.parse('  \n'), refused('empty'));
      expect(() => SshCertificate.parse('hello world'),
          refused('does not look like an SSH certificate'));
      expect(SshCertificate.tryParse('hello world'), isNull);
      expect(SshCertificate.tryParse(null), isNull);
    });
  });

  group('signing in with it', () {
    test('presents the certificate, signs with the key', () {
      final cert = SshCertificate.parse(read('user-cert.pub'));
      final key = SSHKeyPair.fromPem(read('user')).single;
      final identity = certificateIdentity(cert, key);
      expect(identity.type, 'ssh-ed25519-cert-v01@openssh.com');
      expect(identity.toPublicKey().encode(), cert.blob);
      final signature = identity.sign(Uint8List.fromList([1, 2, 3]));
      expect(SSHSignature.getType((signature as SSHSignature).encode()),
          'ssh-ed25519');
    });

    test('an RSA certificate signs with SHA-256', () {
      final cert = SshCertificate.parse(read('rsa-cert.pub'));
      final key = SSHKeyPair.fromPem(read('rsa')).single;
      final identity = certificateIdentity(cert, key);
      expect(identity.type, 'rsa-sha2-256-cert-v01@openssh.com');
      final signature = identity.sign(Uint8List.fromList([1])) as SSHSignature;
      expect(SSHSignature.getType(signature.encode()), 'rsa-sha2-256');
    });
  });

  group('publicKeyBlobOfPem', () {
    test('reads an encrypted OpenSSH key\'s public half without the passphrase',
        () async {
      final path = '${dir.path}/locked';
      await Process.run('ssh-keygen',
          ['-q', '-t', 'ed25519', '-N', 'secret', '-f', path]);
      expect(publicKeyBlobOfPem(File(path).readAsStringSync()),
          blobOf('locked.pub'));
    });

    test('a PEM key, and nothing for text that is not one', () async {
      final path = '${dir.path}/pem-rsa';
      await Process.run('ssh-keygen',
          ['-q', '-t', 'rsa', '-b', '2048', '-m', 'PEM', '-N', '', '-f', path]);
      final blob = publicKeyBlobOfPem(File(path).readAsStringSync());
      expect(samePublicKey(blob!, blobOf('pem-rsa.pub')), isTrue);
      expect(publicKeyBlobOfPem('not a key'), isNull);
      expect(publicKeyBlobOfPem(''), isNull);
    });
  });

  test('times are written in UTC', () {
    expect(formatCertificateTime(DateTime.utc(2026, 3, 4, 5, 6)),
        '2026-03-04 05:06 UTC');
  });
}

List<List<int>> _fields(Uint8List blob) {
  final fields = <List<int>>[];
  var offset = 0;
  while (offset < blob.length) {
    final length = ByteData.sublistView(blob, offset, offset + 4).getUint32(0);
    fields.add(blob.sublist(offset + 4, offset + 4 + length));
    offset += 4 + length;
  }
  return fields;
}

Uint8List _blob(List<List<int>> fields) {
  final out = BytesBuilder();
  for (final field in fields) {
    out
      ..add((ByteData(4)..setUint32(0, field.length)).buffer.asUint8List())
      ..add(field);
  }
  return out.toBytes();
}
