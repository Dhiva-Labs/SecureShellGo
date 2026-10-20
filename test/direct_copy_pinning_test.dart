import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/direct_remote_copy.dart';
import 'package:secure_shell_go/services/ssh_service.dart';

/// [pinKnownHostsLines] decides which of `ssh-keyscan`'s lines the source's
/// `sftp` may trust for the destination. Everything else in the direct path
/// is plumbing around this one comparison.
void main() {
  String blob(String seed) => base64.encode(utf8.encode(seed));

  VerifiedHostKey verified(String type, String seed) => VerifiedHostKey(
        keyType: type,
        fingerprint: 'SHA256:'
            '${base64.encode(sha256.convert(utf8.encode(seed)).bytes).replaceAll('=', '')}',
      );

  test('keeps the one line whose key this device verified', () {
    final pin = pinKnownHostsLines(
      '# b.example:22 SSH-2.0-OpenSSH_9.6\n'
      'b.example ssh-ed25519 ${blob('real')}\n'
      'b.example ecdsa-sha2-nistp256 ${blob('other type')}\n',
      verified('ssh-ed25519', 'real'),
    );
    expect(pin.lines, ['b.example ssh-ed25519 ${blob('real')}']);
    expect(pin.sameTypeMismatch, isFalse);
  });

  test('a different key of the verified type is a mismatch', () {
    final pin = pinKnownHostsLines(
      'b.example ssh-ed25519 ${blob('impostor')}\n',
      verified('ssh-ed25519', 'real'),
    );
    expect(pin.lines, isEmpty);
    expect(pin.sameTypeMismatch, isTrue);
  });

  test('keys of other types are neither pinned nor a mismatch', () {
    final pin = pinKnownHostsLines(
      'b.example ecdsa-sha2-nistp256 ${blob('real')}\n',
      verified('ssh-ed25519', 'real'),
    );
    expect(pin.lines, isEmpty);
    expect(pin.sameTypeMismatch, isFalse);
  });

  test('an RSA key matches whichever algorithm this device negotiated', () {
    // keyscan prints `ssh-rsa`; the handshake may have said rsa-sha2-512.
    // VerifiedHostKey always holds the canonical type.
    final pin = pinKnownHostsLines(
      '[b.example]:2222 ssh-rsa ${blob('rsa key')}\n',
      verified('ssh-rsa', 'rsa key'),
    );
    expect(pin.lines, ['[b.example]:2222 ssh-rsa ${blob('rsa key')}']);
  });

  test('a trailing comment is not carried into the trust file', () {
    final pin = pinKnownHostsLines(
      'b.example ssh-ed25519 ${blob('real')} injected; rm -rf ~\n',
      verified('ssh-ed25519', 'real'),
    );
    expect(pin.lines, ['b.example ssh-ed25519 ${blob('real')}']);
  });

  test('garbage and empty output pin nothing', () {
    for (final output in ['', '\n\n', 'not a key line', 'h t !!notbase64!!']) {
      final pin = pinKnownHostsLines(output, verified('ssh-ed25519', 'real'));
      expect(pin.lines, isEmpty, reason: output);
    }
  });
}
