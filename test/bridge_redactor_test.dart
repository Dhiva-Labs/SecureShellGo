import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/bridge/bridge_redactor.dart';
import 'package:secure_shell_go/services/diagnostics_log.dart';

const _marker = BridgeRedactor.keyMarker;

// Not real keys: the shape is what is being recognised, not the contents.
const _body =
    'b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW\n'
    'QyNTUxOQAAACBQnRzaW5nbGVrZXlib2R5Zm9ydGVzdHNvbmx5bm90YXJlYWxrZXkAAAAA\n'
    'AAECAwQ=';

String _pem(String label, {String body = _body, String eol = '\n'}) =>
    '-----BEGIN $label-----$eol${body.replaceAll('\n', eol)}$eol'
    '-----END $label-----';

String _identity(String s) => s;

void main() {
  final redactor = BridgeRedactor(scrub: _identity);

  group('private keys', () {
    for (final label in [
      'OPENSSH PRIVATE KEY',
      'RSA PRIVATE KEY',
      'EC PRIVATE KEY',
      'DSA PRIVATE KEY',
      'PRIVATE KEY',
      'ENCRYPTED PRIVATE KEY',
      'PGP PRIVATE KEY BLOCK',
    ]) {
      test('$label is redacted', () {
        final out = redactor.redact('before\n${_pem(label)}\nafter');
        expect(out, 'before\n$_marker\nafter');
        expect(out, isNot(contains('b3BlbnNza')));
        expect(out, isNot(contains('AAECAwQ=')));
      });
    }

    test('legacy encrypted PEM with headers is redacted whole', () {
      const key =
          '-----BEGIN RSA PRIVATE KEY-----\n'
          'Proc-Type: 4,ENCRYPTED\n'
          'DEK-Info: AES-128-CBC,0123456789ABCDEF0123456789ABCDEF\n'
          '\n'
          '$_body\n'
          '-----END RSA PRIVATE KEY-----\n';
      final out = redactor.redact('x\n$key');
      expect(out, 'x\n$_marker\n');
    });

    test('public keys and certificates are left alone', () {
      final cert = _pem('CERTIFICATE');
      final pub = _pem('PUBLIC KEY');
      const sshPub = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample dev@box';
      final text = '$cert\n$pub\n$sshPub';
      expect(redactor.redact(text), text);
    });

    test('several blocks are each redacted, text between kept', () {
      final text =
          'a\n${_pem('RSA PRIVATE KEY')}\nmiddle\n'
          '${_pem('OPENSSH PRIVATE KEY')}\n${_pem('CERTIFICATE')}\nz';
      expect(
        redactor.redact(text),
        'a\n$_marker\nmiddle\n$_marker\n${_pem('CERTIFICATE')}\nz',
      );
    });

    test('back-to-back blocks with no gap', () {
      final text = _pem('EC PRIVATE KEY') + _pem('PRIVATE KEY');
      expect(redactor.redact(text), '$_marker$_marker');
    });

    test('CRLF line endings', () {
      final text = 'a\r\n${_pem('PRIVATE KEY', eol: '\r\n')}\r\nb';
      expect(redactor.redact(text), 'a\r\n$_marker\r\nb');
    });

    test('a header wrapped across lines or indented is still caught', () {
      const text =
          'config:\n'
          '  key: |\n'
          '    -----BEGIN OPENSSH\n'
          '    PRIVATE KEY-----\n'
          '    $_body\n'
          '    -----END OPENSSH   PRIVATE\tKEY-----\n'
          'done';
      final out = redactor.redact(text);
      expect(out, isNot(contains('b3BlbnNza')));
      expect(out, contains(_marker));
      expect(out, endsWith('done'));
    });

    test('odd dash counts and lowercase labels', () {
      const text =
          '---BEGIN rsa private key---\n$_body\n---END rsa private key---';
      expect(redactor.redact(text), _marker);
    });

    test('a key printed inside JSON on one line', () {
      final json = jsonEncode({'key': '${_pem('RSA PRIVATE KEY')}\n', 'n': 1});
      final out = redactor.redact(json);
      expect(out, isNot(contains('b3BlbnNza')));
      expect(jsonDecode(out), {'key': '$_marker\n', 'n': 1});
    });

    test('a BEGIN with no END is redacted to the end of the text', () {
      final text =
          'log line\n-----BEGIN OPENSSH PRIVATE KEY-----\n'
          '${_body.split('\n').first}\n';
      expect(redactor.redact(text), 'log line\n$_marker');
    });

    test('an END with no BEGIN takes the key-like lines above it', () {
      final lines = _body.split('\n');
      final text =
          'tail of a file\n${lines[1]}\n${lines[2]}\n'
          '-----END RSA PRIVATE KEY-----\nnext line';
      expect(redactor.redact(text), 'tail of a file\n$_marker\nnext line');
    });

    test('an END with no BEGIN, cut mid-line, still takes the fragment', () {
      final text = 'QyNTUxOQAAACBQnRzaW5nbGVr\n-----END PRIVATE KEY-----';
      expect(redactor.redact(text), _marker);
    });

    test('an orphan END after a whole block does not eat the block marker', () {
      final text =
          '${_pem('PRIVATE KEY')}\nplain words here\n'
          'QUJD\n-----END PRIVATE KEY-----';
      expect(redactor.redact(text), '$_marker\nplain words here\n$_marker');
    });

    test('PuTTY private lines are redacted', () {
      const ppk =
          'PuTTY-User-Key-File-3: ssh-ed25519\n'
          'Encryption: none\n'
          'Public-Lines: 2\n'
          'AAAAC3NzaC1lZDI1NTE5AAAAIPublicPart\n'
          'AAAA\n'
          'Private-Lines: 2\n'
          'AAAAIPrivatePartNumberOneSecret\n'
          'AAAAPrivatePartTwo\n'
          'Private-MAC: 0123abcd\n';
      final out = redactor.redact(ppk);
      expect(out, isNot(contains('PrivatePart')));
      expect(out, contains('PublicPart'));
      expect(out, contains('Private-Lines: $_marker\nPrivate-MAC: 0123abcd'));
    });

    test('text that only says "private key" is left alone', () {
      const text =
          'Load your private key from ~/.ssh before running.\n'
          'BEGIN PRIVATE KEY is how the file starts.';
      expect(redactor.redact(text), text);
    });
  });

  group('cap', () {
    test('short output is untouched', () {
      expect(redactor.redact('hello'), 'hello');
      expect(redactor.redact(''), '');
    });

    test('exactly at the cap is untouched', () {
      final r = BridgeRedactor(scrub: _identity, maxBytes: 10);
      expect(r.redact('0123456789'), '0123456789');
    });

    test('past the cap, cut with a note of what was dropped', () {
      final r = BridgeRedactor(scrub: _identity, maxBytes: 10);
      expect(
        r.redact('0123456789abc'),
        '0123456789\n[output truncated: 3 more bytes]',
      );
    });

    test('keepTail keeps the end', () {
      final r = BridgeRedactor(scrub: _identity, maxBytes: 10);
      expect(
        r.redact('abc0123456789', keepTail: true),
        '[output truncated: 3 earlier bytes]\n0123456789',
      );
    });

    test('the default cap is 64 KiB', () {
      final out = redactor.redact('x' * (64 * 1024 + 5));
      expect(out, startsWith('x' * (64 * 1024)));
      expect(out, endsWith('\n[output truncated: 5 more bytes]'));
    });

    test('never cuts inside a multi-byte character', () {
      // é is 2 bytes, 😀 is 4: try every cap position across them.
      const text = 'aé😀b€c😀😀';
      final total = utf8.encode(text).length;
      for (var cap = 1; cap < total; cap++) {
        for (final tail in [false, true]) {
          final r = BridgeRedactor(scrub: _identity, maxBytes: cap);
          final out = r.redact(text, keepTail: tail);
          expect(out, isNot(contains('�')), reason: 'cap $cap');
          final kept = tail
              ? out.substring(out.indexOf('\n') + 1)
              : out.substring(0, out.lastIndexOf('\n'));
          final keptBytes = utf8.encode(kept).length;
          expect(keptBytes, lessThanOrEqualTo(cap), reason: 'cap $cap');
          expect(
            tail ? text.endsWith(kept) : text.startsWith(kept),
            isTrue,
            reason: 'cap $cap',
          );
          final dropped = int.parse(
            RegExp(r'(\d+)').firstMatch(
              tail ? out : out.substring(out.lastIndexOf('\n')),
            )![1]!,
          );
          expect(dropped + keptBytes, total, reason: 'cap $cap');
        }
      }
    });

    test('a cap that would land inside a key cannot leave half of it', () {
      final key = _pem('OPENSSH PRIVATE KEY');
      final text = '${'a' * 20}\n$key\n${'z' * 2000}';
      // A cap partway through where the key was.
      final r = BridgeRedactor(scrub: _identity, maxBytes: 60);
      for (final tail in [false, true]) {
        final out = r.redact(text, keepTail: tail);
        expect(out, isNot(contains('b3BlbnNza')));
        expect(out, isNot(contains('QyNTUxOQ')));
        expect(out, isNot(contains('BEGIN')));
        expect(out, isNot(contains('END')));
      }
      expect(r.redact(text), startsWith('${'a' * 20}\n$_marker\nzzz'));
    });
  });

  group('scrub', () {
    test('the scrubber runs on the output, after keys, before the cap', () {
      final seen = <String>[];
      final r = BridgeRedactor(
        maxBytes: 30,
        scrub: (s) {
          seen.add(s);
          return s.replaceAll('hunter2hunter2', '[redacted]');
        },
      );
      final text = '${_pem('PRIVATE KEY')}\n${'p' * 20}hunter2hunter2tail';
      final out = r.redact(text);
      expect(seen.single, isNot(contains('BEGIN')));
      // The secret straddles the cap; it was scrubbed whole first.
      expect(seen.single, contains('hunter2hunter2'));
      expect(out, isNot(contains('hunter')));
    });

    test('with the app scrubber, learned secrets are removed', () {
      final scrubber = SecretScrubber()..learn('s3cr3t-passphrase');
      final r = BridgeRedactor(scrub: scrubber.scrub);
      final out = r.redact('export PASS=s3cr3t-passphrase\nok');
      expect(out, isNot(contains('s3cr3t-passphrase')));
      expect(out, endsWith('ok'));
    });
  });

  test('a large output with many keys stays fast', () {
    final chunk = 'line\n${_pem('RSA PRIVATE KEY')}\n';
    final text = chunk * 5000;
    final watch = Stopwatch()..start();
    final out = BridgeRedactor.redactPrivateKeys(text);
    expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    expect(out, ('line\n$_marker\n') * 5000);
  });

  test('an END at the very start of the text does not throw', () {
    for (final text in [
      '-----END RSA PRIVATE KEY-----',
      '-----END RSA PRIVATE KEY-----\nafter',
      '\n-----END PRIVATE KEY-----',
      'AAAA\n-----END PRIVATE KEY-----',
    ]) {
      final out = BridgeRedactor.redactPrivateKeys(text);
      expect(out, contains(_marker), reason: text);
    }
    expect(
      BridgeRedactor.redactPrivateKeys('AAAA\n-----END PRIVATE KEY-----'),
      _marker,
    );
  });

  test('thousands of stray END lines stay fast', () {
    final text = '-----END PRIVATE KEY-----\nxx\n' * 8000;
    final watch = Stopwatch()..start();
    final out = BridgeRedactor.redactPrivateKeys(text);
    expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
    expect(out, contains(_marker));
    expect(out, isNot(contains('PRIVATE KEY-----')));
  });
}
