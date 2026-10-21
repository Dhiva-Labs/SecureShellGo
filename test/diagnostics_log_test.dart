import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/app_settings.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/services/credential_store.dart';
import 'package:secure_shell_go/services/diagnostics_log.dart';
import 'package:secure_shell_go/services/ssh_keygen.dart';

import 'credential_store_test.dart' show FakeSecureStorageBackend;

/// Base64 that looks like key material: random bytes, wrapped like PEM.
String _randomBase64(Random random, int bytes, {int width = 64}) {
  final raw = base64Encode(List<int>.generate(bytes, (_) => random.nextInt(256)));
  final lines = <String>[];
  for (var i = 0; i < raw.length; i += width) {
    lines.add(raw.substring(i, min(i + width, raw.length)));
  }
  return lines.join('\n');
}

void main() {
  final random = Random(7);

  test('the reported version is the one pubspec.yaml builds', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final version =
        RegExp(r'^version:\s*(\S+)', multiLine: true).firstMatch(pubspec)![1];
    expect(DiagnosticsLog.appVersion, version);
  });

  group('SecretScrubber patterns', () {
    final scrubber = SecretScrubber();
    String scrub(String text) => scrubber.scrub(text);

    test('removes a real OpenSSH private key, header to footer', () {
      final pem =
          SshKeygen.generateEd25519(comment: 'me@laptop').privateKeyPem;
      final body = pem.split('\n')[1];
      final out = scrub('Could not parse key:\n$pem\nat line 3');
      expect(out, isNot(contains('PRIVATE KEY')));
      expect(out, isNot(contains(body)));
      expect(out, contains(SecretScrubber.keyRedacted));
      expect(out, startsWith('Could not parse key:'));
      expect(out, endsWith('at line 3'));
    });

    test('removes every common PEM flavour', () {
      for (final label in [
        'RSA PRIVATE KEY',
        'PRIVATE KEY',
        'ENCRYPTED PRIVATE KEY',
        'EC PRIVATE KEY',
        'DSA PRIVATE KEY',
        'OPENSSH PRIVATE KEY',
      ]) {
        final body = _randomBase64(random, 600);
        final pem = '-----BEGIN $label-----\n'
            '${label == 'RSA PRIVATE KEY' ? 'Proc-Type: 4,ENCRYPTED\nDEK-Info: AES-128-CBC,0F2A9C1E44B07D3361A8E9C2D7B11F05\n\n' : ''}'
            '$body\n-----END $label-----\n';
        final out = scrub('key: $pem trailing');
        expect(out, isNot(contains(body.split('\n')[2])), reason: label);
        expect(out, isNot(contains('BEGIN')), reason: label);
        expect(out, contains('trailing'), reason: label);
      }
    });

    test('removes an SSH2 and a PGP private key block', () {
      final body = _randomBase64(random, 400, width: 70);
      final ssh2 = '---- BEGIN SSH2 ENCRYPTED PRIVATE KEY ----\n'
          'Comment: "rsa-key-20240101"\n$body\n'
          '---- END SSH2 ENCRYPTED PRIVATE KEY ----';
      final pgp = '-----BEGIN PGP PRIVATE KEY BLOCK-----\n\n$body\n'
          '-----END PGP PRIVATE KEY BLOCK-----';
      for (final block in [ssh2, pgp]) {
        final out = scrub(block);
        expect(out, SecretScrubber.keyRedacted);
      }
    });

    test('a key cut off before its END line is removed to the end', () {
      final pem =
          SshKeygen.generateEd25519(comment: 'cut').privateKeyPem;
      final cut = pem.substring(0, pem.length ~/ 2);
      final out = scrub('FormatException: $cut');
      expect(out, 'FormatException: ${SecretScrubber.keyRedacted}');
    });

    test('a key printed with escaped line breaks, inside JSON', () {
      final pem =
          SshKeygen.generateEd25519(comment: 'json').privateKeyPem;
      final json = jsonEncode({'privateKeyPem': pem, 'host': 'example.org'});
      final out = scrub('payload $json');
      expect(out, isNot(contains('b3BlbnNzaC1rZXktdjE')));
      expect(out, isNot(contains('PRIVATE KEY')));
      expect(out, contains('example.org'));
    });

    test('a key in a Dart map printout', () {
      final pem =
          SshKeygen.generateEd25519(comment: 'map').privateKeyPem;
      final out = scrub('${{'password': 'hunter2!x', 'privateKeyPem': pem}}');
      expect(out, isNot(contains('hunter2')));
      expect(out, isNot(contains('b3BlbnNzaC1rZXktdjE')));
    });

    test('an OpenSSH key body with no header around it', () {
      final pem =
          SshKeygen.generateEd25519(comment: 'bare').privateKeyPem;
      final body = pem
          .split('\n')
          .where((l) => l.isNotEmpty && !l.startsWith('-----'))
          .join('\n');
      final out = scrub('decoding "$body" failed');
      expect(out, 'decoding "${SecretScrubber.keyRedacted}" failed');
    });

    test('removes a PuTTY key file', () {
      final ppk = 'PuTTY-User-Key-File-3: ssh-ed25519\n'
          'Encryption: aes256-cbc\n'
          'Comment: ed25519-key-20240611\n'
          'Public-Lines: 2\n${_randomBase64(random, 51)}\n'
          'Key-Derivation: Argon2id\nArgon2-Memory: 8192\n'
          'Argon2-Passes: 13\nArgon2-Parallelism: 1\n'
          'Argon2-Salt: 2b3c1a9e7f0d44e1a2b3c4d5e6f70812\n'
          'Private-Lines: 1\n${_randomBase64(random, 48)}\n'
          'Private-MAC: 4a6f3e2d1c0b9a8f7e6d5c4b3a291807f6e5d4c3b2a1908f7e6d5c4b3a291807\n';
      final out = scrub('Unsupported key:\n${ppk}done');
      expect(out, 'Unsupported key:\n${SecretScrubber.keyRedacted}\ndone');
    });

    test('password and passphrase pairs in every common spelling', () {
      final cases = <String, String>{
        'password=Tr0ub4dor&3': 'password=[redacted]',
        'PASSWORD=Tr0ub4dor': 'PASSWORD=[redacted]',
        '"password":"c0rrect horse"': '"password":"[redacted]"',
        '"passphrase": "battery staple"': '"passphrase": "[redacted]"',
        "{'password': 'q1w2e3r4'}": "{'password': '[redacted]'}",
        '{password: two words here, user: root}':
            '{password: [redacted], user: root}',
        'passphrase: hunter2-really': 'passphrase: [redacted]',
        'db_pass=s3cretValue': 'db_pass=[redacted]',
        'userPassword => "abc12345"': 'userPassword => "[redacted]"',
        'client_secret=9f8e7d6c': 'client_secret=[redacted]',
        'aws_secret_access_key = wJalrXUt': 'aws_secret_access_key = [redacted]',
        'api_key: sk_abcdef': 'api_key: [redacted]',
        'X-Auth-Token: abcdef123': 'X-Auth-Token: [redacted]',
        r'{\"password\":\"zxcvbnm1\"}': r'{\"password\":[redacted]}',
        'url?user=bob&password=pa55word&next=/home':
            'url?user=bob&password=[redacted]&next=/home',
        '-passin pass:my-keyfile-pw': '-passin pass:[redacted]',
      };
      cases.forEach((input, expected) {
        expect(scrub(input), expected, reason: input);
      });
    });

    test('command lines that carry a password', () {
      final cases = <String, String>{
        "sshpass -p 'Sup3r S3cret' ssh root@10.0.0.2":
            'sshpass -p [redacted] ssh root@10.0.0.2',
        'sshpass -e -pHunter22 ssh host': 'sshpass -e -p[redacted] ssh host',
        'mysql -u root -pRootPw99 shop': 'mysql -u root -p[redacted] shop',
        'mysql -u root -p shop': 'mysql -u root -p shop',
        'ssh-keygen -p -P oldpass1 -N "new pass 2" -f ~/.ssh/id':
            'ssh-keygen -p -P [redacted] -N [redacted] -f ~/.ssh/id',
        'curl -u alice:wonderland https://x':
            'curl -u alice:[redacted] https://x',
        'echo "hunter2!" | sudo -S apt update':
            'echo [redacted] | sudo -S apt update',
        'tool --password hunter222 --verbose':
            'tool --password [redacted] --verbose',
        'tool --token=abcdef --verbose': 'tool --token=[redacted] --verbose',
        'mysql --password -u root': 'mysql --password -u root',
      };
      cases.forEach((input, expected) {
        expect(scrub(input), expected, reason: input);
      });
    });

    test('credentials in URLs and Authorization headers', () {
      expect(
        scrub('GET https://deploy:gh0st-Writer@git.example.com/repo.git'),
        'GET https://deploy:[redacted]@git.example.com/repo.git',
      );
      expect(
        scrub('postgres://app:p%40ss@db:5432/main'),
        'postgres://app:[redacted]@db:5432/main',
      );
      expect(
        scrub('Authorization: Bearer abc.def.ghi-jkl'),
        'Authorization: Bearer [redacted]',
      );
      expect(
        scrub('authorization=Basic dXNlcjpwYXNz'),
        'authorization=Basic [redacted]',
      );
      expect(scrub('sent bearer 1234567890abcdef'), 'sent bearer [redacted]');
    });

    test('well-known token formats', () {
      final tokens = [
        'ghp_${'aB3' * 12}',
        'github_pat_11ABCDEFG0${'xY9_' * 12}',
        'glpat-${'Zq8' * 8}',
        'xoxb-123456789012-123456789012-${'aBc1' * 6}',
        'AKIAIOSFODNN7EXAMPLE',
        'AIzaSyD${'x1Y' * 11}z',
        'sk_live_${'4eC39HqLyjWDarjtT1zdp7dc'}',
        'sk-ant-api03-${'Q2w3E4r5' * 8}',
        'npm_${'a1B2c3' * 6}',
        'hf_${'Ab12Cd34' * 5}',
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.'
            'eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4ifQ.'
            'SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c',
      ];
      for (final token in tokens) {
        final out = scrub('value [$token] end');
        expect(out, 'value [[redacted]] end', reason: token);
      }
    });

    test('long random base64 and hex runs', () {
      final b64 = base64Encode(List<int>.generate(48, (_) => random.nextInt(256)));
      expect(scrub('seed=$b64.'), isNot(contains(b64)));
      expect(scrub('blob $b64 end'), 'blob [redacted] end');
      const hex = '9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08';
      expect(scrub('hmac $hex'), 'hmac [redacted]');
    });

    test('leaves ordinary diagnostics alone', () {
      const lines = [
        '#0      SftpService._describe (package:secure_shell_go/services/sftp_service.dart:412:7)',
        '#1      _FileBrowserPaneState._refresh.<anonymous closure> (package:secure_shell_go/screens/file_browser_pane.dart:930:22)',
        'SocketException: Connection refused (OS Error: Connection refused, errno = 111), address = 10.0.0.2, port = 22',
        'Host key for example.org:22 is SHA256:47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU',
        'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGq4k3x9Hc0Bq0u1wXy3M4yQb4fYk0vD3qH9b2rKpT7s me@laptop',
        'host id 3f2c8a10-1b2d-4c5e-9f00-112233445566',
        '/data/user/0/com.dhivalabs.secure_shell_go/cache/file_picker/1729000000000/MyFile2.txt',
        '/home/someone/Projects/SecureShellGo2024/build/linux/x64/Release/bundle',
        'Authentication failed for root@example.org (publickey,password)',
        'mkdir -p /srv/www/releases/2024-10-21',
        'ssh -p 2222 deploy@example.org',
        'backup_passphrase.dart:44: passphrase too short',
      ];
      for (final line in lines) {
        expect(scrub(line), line, reason: line);
      }
    });

    test('a key with Windows line endings', () {
      final pem = SshKeygen.generateEd25519(comment: 'crlf')
          .privateKeyPem
          .replaceAll('\n', '\r\n');
      expect(scrub('read: $pem'), 'read: ${SecretScrubber.keyRedacted}\r\n');
    });

    test('several secrets on one line all go', () {
      final out = scrub(
        'retry with password=alpha111 token=beta222 '
        'https://u:gamma333@h/ sshpass -p delta444 ssh h',
      );
      for (final secret in ['alpha111', 'beta222', 'gamma333', 'delta444']) {
        expect(out, isNot(contains(secret)), reason: secret);
      }
    });

    test('a quoted value with escaped quotes inside goes whole', () {
      expect(
        scrub(r'{"password":"say \"hi\" twice","user":"root"}'),
        r'{"password":"[redacted]","user":"root"}',
      );
    });

    test('the forms the first patterns missed', () {
      final cases = <String, String>{
        'SSHPASS=Hunter22 sshpass -e ssh h':
            'SSHPASS=[redacted] sshpass -e ssh h',
        'export MYPASS=Hunter22': 'export MYPASS=[redacted]',
        'MYSQL_PWD=Hunter22 mysql': 'MYSQL_PWD=[redacted] mysql',
        'ssh://u:p@ssw0rd@h.example.org/x':
            'ssh://u:[redacted]@h.example.org/x',
        'https://u:pa/ss@h.example.org/': 'https://u:[redacted]@h.example.org/',
        'rsync -a dir/ root:Hunter22@10.0.0.2:/srv':
            'rsync -a dir/ root:[redacted]@10.0.0.2:/srv',
        "printf '%s\\n' 'Hunter22' | sudo -S true":
            'printf [redacted] | sudo -S true',
        'echo my long pw | sudo -S true': 'echo [redacted] | sudo -S true',
        'sudo -S id <<< Hunter22': 'sudo -S id <<< [redacted]',
        'pw=Hunter22 next': 'pw=[redacted] next',
        'Password for root@h.example.org: Hunter 22':
            'Password for root@h.example.org: [redacted]',
        '[sudo] password for dev: Hunter22':
            '[sudo] password for dev: [redacted]',
        "dev@h's password: Hunter22": "dev@h's password: [redacted]",
      };
      cases.forEach((input, expected) {
        expect(scrub(input), expected, reason: input);
      });
    });

    test('scrubbing twice changes nothing more', () {
      const input = 'password=abc123 Authorization: Bearer x.y.zzzzzzzz '
          'sshpass -p pw ssh h';
      final once = scrub(input);
      expect(scrub(once), once);
    });
  });

  group('SecretScrubber learned secrets', () {
    test('removes a saved password wherever it appears, in any escaping', () {
      final scrubber = SecretScrubber()..learn(r'p@ss:w0rd"!\x');
      const secret = r'p@ss:w0rd"!\x';
      expect(scrubber.scrub('tried $secret twice'), 'tried [redacted] twice');
      expect(
        scrubber.scrub('json ${jsonEncode({'x': secret})}'),
        contains('[redacted]'),
      );
      expect(
        scrubber.scrub('json ${jsonEncode({'x': secret})}'),
        isNot(contains('w0rd')),
      );
      expect(
        scrubber.scrub('url ${Uri.encodeComponent(secret)}'),
        'url [redacted]',
      );
    });

    test('a learned secret full of regex metacharacters is matched literally',
        () {
      final scrubber = SecretScrubber()..learn(r'a.b*c+d?(e)[f]{2}^\$');
      expect(
        scrubber.scrub(r'got a.b*c+d?(e)[f]{2}^\$ back'),
        'got [redacted] back',
      );
      expect(scrubber.scrub('aXbbbcd'), 'aXbbbcd');
    });

    test('catches a password no pattern would recognise', () {
      final scrubber = SecretScrubber()..learn('correct-horse');
      expect(
        scrubber.scrub('Exception: bad input "correct-horse" near x'),
        'Exception: bad input "[redacted]" near x',
      );
    });

    test('a saved key is caught line by line, even in fragments', () {
      final pem =
          SshKeygen.generateEd25519(comment: 'frag').privateKeyPem;
      final scrubber = SecretScrubber()..learn(pem);
      final line = pem.split('\n')[2];
      expect(line.length, greaterThanOrEqualTo(16));
      expect(scrubber.scrub('chunk: [$line]'), 'chunk: [[redacted]]');
    });

    test('a short saved password does not blind the patterns', () {
      // "pass" is inside "password", "sshpass" and "passphrase". Matched
      // anywhere before the patterns, it broke each of them.
      final scrubber = SecretScrubber()..learn('pass');
      for (final input in [
        'password=Hunter22',
        'sshpass -p Hunter22 ssh h',
        '{"passphrase": "Hunter22"}',
      ]) {
        expect(scrubber.scrub(input), isNot(contains('Hunter22')),
            reason: input);
      }
    });

    test('a saved password that is itself a secret name still hides the '
        'value after it', () {
      final scrubber = SecretScrubber()..learn('password');
      expect(scrubber.scrub('password=Hunter22'), isNot(contains('Hunter22')));
    });

    test('a saved password with spaces goes whole, not just its first word',
        () {
      final scrubber = SecretScrubber()..learn('correct horse battery');
      final out = scrubber.scrub('password=correct horse battery staple');
      expect(out, isNot(contains('horse')));
      expect(out, isNot(contains('battery')));
    });

    test('very short secrets are left to the patterns', () {
      final scrubber = SecretScrubber()..learn('abc');
      expect(scrubber.scrub('abc def'), 'abc def');
      expect(scrubber.knownCount, 0);
    });

    test('the longest learned secret wins over one inside it', () {
      final scrubber = SecretScrubber()
        ..learn('hunter')
        ..learn('hunter2000');
      expect(scrubber.scrub('x hunter2000 y'), 'x [redacted] y');
    });

    test('forgetAll stops matching', () {
      final scrubber = SecretScrubber()..learn('longsecret');
      scrubber.forgetAll();
      expect(scrubber.scrub('longsecret'), 'longsecret');
    });
  });

  group('DiagnosticsLog', () {
    late Directory dir;
    late DiagnosticsLog log;

    DiagnosticsLog makeLog({int maxFileBytes = 4096}) => DiagnosticsLog(
          directory: () async => dir,
          maxFileBytes: maxFileBytes,
          clock: () => DateTime.utc(2026, 10, 21, 9, 30),
          describePlatform: () =>
              'Platform: testos\nOperating system: TestOS 1.0\nDart: 3.x',
        );

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('diag_log_test');
      log = makeLog();
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    File current() => File('${dir.path}/${DiagnosticsLog.fileName}');
    File previous() => File('${dir.path}/${DiagnosticsLog.previousFileName}');

    test('starts each file with version, platform and OS', () async {
      await log.setEnabled(true);
      await log.record(StateError('boom'), StackTrace.current);
      final text = await current().readAsString();
      expect(
        text,
        startsWith('SecureShell Go diagnostics log\n'
            'App version: ${DiagnosticsLog.appVersion} (debug build)\n'
            'Platform: testos\nOperating system: TestOS 1.0\n'),
      );
      expect(text, contains('Bad state: boom'));
      expect(text, contains('2026-10-21T09:30:00.000Z'));
    });

    test('writes nothing while the setting is off', () async {
      await log.setEnabled(false);
      await log.record(StateError('off'), StackTrace.current);
      await log.record(Exception('still off'), null);
      expect(await current().exists(), isFalse);
      expect(await previous().exists(), isFalse);
      expect(await log.read(), isEmpty);
    });

    test('writes nothing before the setting is known', () async {
      await log.record(StateError('early'), null);
      expect(await current().exists(), isFalse);
    });

    test('an early error is written once the setting turns out on', () async {
      await log.record(StateError('early bird'), null);
      await log.setEnabled(true);
      expect(await current().readAsString(), contains('early bird'));
    });

    test('an early error is dropped when the setting turns out off',
        () async {
      await log.record(StateError('early bird'), null);
      await log.setEnabled(false);
      await log.setEnabled(true);
      expect(await current().exists(), isFalse);
    });

    test('turning the log off deletes what was kept', () async {
      await log.setEnabled(true);
      await log.record(StateError('kept'), null);
      expect(await current().exists(), isTrue);
      await log.setEnabled(false);
      expect(await current().exists(), isFalse);
    });

    test('follows the saved setting', () async {
      log.applySettings(const AppSettings(diagnosticsLog: false));
      await log.record(StateError('x'), null);
      expect(await current().exists(), isFalse);
      log.applySettings(const AppSettings());
      await log.record(StateError('y'), null);
      expect(await log.read(), contains('Bad state: y'));
    });

    test('rotates at the cap and never keeps more than two files', () async {
      await log.setEnabled(true);
      for (var i = 0; i < 200; i++) {
        await log.record(
          StateError('error number $i ${'x' * 40}'),
          StackTrace.fromString('#0 frame $i\n#1 frame'),
        );
      }
      expect(await current().length(), lessThanOrEqualTo(4096));
      expect(await previous().length(), lessThanOrEqualTo(4096));
      final files = dir.listSync().whereType<File>().toList();
      expect(files, hasLength(2));
      final text = await log.read();
      expect(text, contains('error number 199'));
      expect(text, isNot(contains('error number 0 ')));
      // Each file says what wrote it.
      expect(
        'SecureShell Go diagnostics log'.allMatches(text).length,
        2,
      );
    });

    test('one huge entry is cut to fit rather than overflowing', () async {
      await log.setEnabled(true);
      await log.record(StateError('y' * 100000), null);
      expect(await current().length(), lessThanOrEqualTo(4096));
      expect(await current().readAsString(), contains('Entry cut short'));
    });

    test('a long stack is trimmed', () async {
      final big = makeLog(maxFileBytes: 64 * 1024);
      await big.setEnabled(true);
      final stack = StackTrace.fromString(
        List.generate(200, (i) => '#$i frame$i').join('\n'),
      );
      await big.record(StateError('deep'), stack);
      final text = await current().readAsString();
      expect(text, contains('#59 frame59'));
      expect(text, isNot(contains('#60 frame60')));
      expect(text, contains('(140 more frames)'));
    });

    test('an error repeated back to back is written once, with a count',
        () async {
      await log.setEnabled(true);
      final stack = StackTrace.fromString('#0 build');
      for (var i = 0; i < 5; i++) {
        await log.record(StateError('same'), stack);
      }
      await log.record(StateError('different'), stack);
      final text = await log.read();
      expect('Bad state: same'.allMatches(text).length, 1);
      expect(text, contains('happened 4 more times'));
      expect(text, contains('Bad state: different'));
    });

    test('scrubs before writing', () async {
      await log.setEnabled(true);
      final pem =
          SshKeygen.generateEd25519(comment: 'disk').privateKeyPem;
      await log.record(
        Exception('login failed password=Hunter22 key=$pem'),
        null,
      );
      final raw = await current().readAsString();
      expect(raw, isNot(contains('Hunter22')));
      expect(raw, isNot(contains('b3BlbnNzaC1rZXktdjE')));
    });

    test('learns credential-store contents and keeps them out', () async {
      final backend = FakeSecureStorageBackend();
      final store = CredentialStore(
        backend: log.watchCredentialStorage(backend),
      );
      final pem =
          SshKeygen.generateEd25519(comment: 'store').privateKeyPem;
      await store.save(
        'h1',
        SshCredentials(password: 'plainWord', passphrase: 'k3y-unlock', privateKeyPem: pem),
      );
      await log.setEnabled(true);
      // Neither looks like a secret on its own; only the store knows.
      await log.record(StateError('server said plainWord and k3y-unlock'), null);
      final raw = await current().readAsString();
      expect(raw, isNot(contains('plainWord')));
      expect(raw, isNot(contains('k3y-unlock')));
      // And it passed everything through untouched.
      final loaded = await store.load('h1');
      expect(loaded!.password, 'plainWord');
      expect(loaded.privateKeyPem, pem);
    });

    test('a secret learned after writing is scrubbed from the copy',
        () async {
      await log.setEnabled(true);
      await log.record(StateError('typed letmein99 by mistake'), null);
      expect(await current().readAsString(), contains('letmein99'));
      final backend = FakeSecureStorageBackend();
      await log
          .watchCredentialStorage(backend)
          .write('credentials:h2', jsonEncode({'password': 'letmein99'}));
      expect(await log.read(), isNot(contains('letmein99')));
    });

    test('a secret learned after writing is taken out of the file too',
        () async {
      final log = makeLog()..learnSecret(null);
      await log.setEnabled(true);
      await log.record(StateError('typed letmein99 by mistake'), null);
      expect(await current().readAsString(), contains('letmein99'));

      log.learnSecret('letmein99');
      await log.rescrubFiles();
      final onDisk = await current().readAsString();
      expect(onDisk, isNot(contains('letmein99')));
      expect(onDisk, contains('typed [redacted] by mistake'));
    });

    test('learning schedules that by itself', () async {
      final log = DiagnosticsLog(
        directory: () async => dir,
        rescrubDelay: Duration.zero,
      );
      await log.setEnabled(true);
      await log.record(StateError('the code was 7731-4402-1189'), null);
      log.learnSecret('7731-4402-1189');
      for (var i = 0; i < 50; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        if (!(await current().readAsString()).contains('7731')) break;
      }
      expect(await current().readAsString(), isNot(contains('7731')));
    });

    test('a file from an earlier run is scrubbed when the log turns on',
        () async {
      final earlier = makeLog();
      await earlier.setEnabled(true);
      await earlier.record(StateError('vault pw is OpenSesame42'), null);

      final now = makeLog()..learnSecret('OpenSesame42');
      await now.setEnabled(true);
      expect(await current().readAsString(), isNot(contains('OpenSesame42')));
    });

    test('an enormous error waiting for the setting is cut down first',
        () async {
      final log = makeLog();
      await log.record(StateError('x' * 1000000), null,
          context: 'y' * 1000000);
      expect(log.pendingEntryLengths.single,
          lessThan(3 * DiagnosticsLog.maxEntryChars + 1000));
    });

    test('clear deletes both files', () async {
      final small = makeLog(maxFileBytes: 800);
      await small.setEnabled(true);
      for (var i = 0; i < 20; i++) {
        await small.record(StateError('fill $i ${'z' * 50}'), null);
      }
      expect(await previous().exists(), isTrue);
      expect(await small.sizeInBytes(), greaterThan(0));
      await small.clear();
      expect(await current().exists(), isFalse);
      expect(await previous().exists(), isFalse);
      expect(await small.read(), isEmpty);
    });

    test('a folder that cannot be written does not throw', () async {
      final broken = DiagnosticsLog(
        directory: () async => throw const FileSystemException('nope'),
      );
      await broken.setEnabled(true);
      await expectLater(broken.record(StateError('x'), null), completes);
    });

    test('framework errors reach the log through the installed hook',
        () async {
      final previousHandler = FlutterError.onError;
      final seen = <FlutterErrorDetails>[];
      FlutterError.onError = seen.add;
      final previousPlatform = PlatformDispatcher.instance.onError;
      addTearDown(() {
        FlutterError.onError = previousHandler;
        PlatformDispatcher.instance.onError = previousPlatform;
      });

      await log.setEnabled(true);
      log.installErrorHooks();
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: StateError('layout exploded'),
          library: 'rendering library',
          context: ErrorDescription('during layout'),
        ),
      );
      // The previous handler still ran.
      expect(seen, hasLength(1));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final text = await log.read();
      expect(text, contains('Flutter error (rendering library)'));
      expect(text, contains('during layout'));
      expect(text, contains('layout exploded'));
    });
  });
}
