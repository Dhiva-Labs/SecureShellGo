import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/secret_vault.dart';

/// The vault, over a real temp directory and never a real keyring.
///
/// Argon2id costs about a second per derivation by design, so one vault is
/// built in [setUpAll] and its bytes are copied into a fresh file for each
/// test that needs an untouched one. Every test that unlocks pays exactly one
/// derivation, which is also the thing the reuse test is checking.
void main() {
  const passphrase = 'correct horse battery staple';

  late Directory dir;
  late SecretVault vault;
  late Uint8List pristine;

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('ssg_vault_test');
    vault = SecretVault(
      file: File('${dir.path}/${SecretVault.fileName}'),
      useIsolate: false,
    );
    await vault.create(passphrase);
    await vault.write('credentials:host-1', '{"password":"hunter2"}');
    pristine = await File('${dir.path}/${SecretVault.fileName}').readAsBytes();
  });

  tearDownAll(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  /// A private copy of the vault built in [setUpAll], in its own directory.
  Future<(File, SecretVault)> freshCopy() async {
    final copyDir = await Directory.systemTemp.createTemp('ssg_vault_copy');
    addTearDown(() async {
      if (await copyDir.exists()) await copyDir.delete(recursive: true);
    });
    final file = File('${copyDir.path}/${SecretVault.fileName}');
    await file.writeAsBytes(pristine, flush: true);
    return (file, SecretVault(file: file, useIsolate: false));
  }

  group('round trip', () {
    test('a secret written to the vault reads back and then deletes',
        () async {
      expect(vault.isUnlocked, isTrue);
      expect(await vault.read('credentials:host-1'), '{"password":"hunter2"}');

      await vault.write('credentials:host-2', '{"passphrase":"s3cret"}');
      expect(await vault.read('credentials:host-2'), '{"passphrase":"s3cret"}');

      await vault.delete('credentials:host-2');
      expect(await vault.read('credentials:host-2'), isNull);
      // Deleting one entry must not disturb the others: they all share one
      // blob, so a re-seal that dropped the map would look exactly like this
      // until the next read.
      expect(await vault.read('credentials:host-1'), '{"password":"hunter2"}');
    });

    test('the file is not the user-visible plaintext of anything', () async {
      final bytes = await File('${dir.path}/${SecretVault.fileName}')
          .readAsBytes();
      expect(String.fromCharCodes(bytes.sublist(0, 6)), 'SSGVLT');
      expect(String.fromCharCodes(bytes), isNot(contains('hunter2')));
    });
  });

  group('wrong passphrase', () {
    test('is refused, and leaves the vault exactly as it was', () async {
      final (file, copy) = await freshCopy();

      await expectLater(
        copy.unlock('not the passphrase'),
        throwsA(isA<SecretVaultAuthException>()),
      );
      expect(copy.isUnlocked, isFalse);
      // The failure must not have rewritten, truncated or emptied anything —
      // this is the case where a careless "start fresh on error" would throw
      // away every credential the user owns.
      expect(await file.readAsBytes(), pristine);

      await copy.unlock(passphrase);
      expect(await copy.read('credentials:host-1'), '{"password":"hunter2"}');
    });

    test('says so without claiming to know which of the two it was', () async {
      const failure = SecretVaultAuthException();
      expect(failure.message, contains('Wrong passphrase'));
      expect(failure.message, contains('damaged'));
    });
  });

  group('damaged files', () {
    test('a truncated vault is refused and left alone', () async {
      final (file, copy) = await freshCopy();
      final truncated = pristine.sublist(0, 40);
      await file.writeAsBytes(truncated, flush: true);

      await expectLater(
        copy.unlock(passphrase),
        throwsA(isA<SecretVaultFormatException>()),
      );
      expect(await file.readAsBytes(), truncated);
    });

    test('a file that is not a vault at all is refused', () async {
      final (file, copy) = await freshCopy();
      await file.writeAsString('not a vault, just some text in a file');

      await expectLater(
        copy.unlock(passphrase),
        throwsA(isA<SecretVaultFormatException>()),
      );
    });

    test('a flipped bit in the payload fails the tag check', () async {
      final (file, copy) = await freshCopy();
      final tampered = Uint8List.fromList(pristine);
      tampered[tampered.length - 1] ^= 0x01;
      await file.writeAsBytes(tampered, flush: true);

      await expectLater(
        copy.unlock(passphrase),
        throwsA(isA<SecretVaultAuthException>()),
      );
    });

    test('a swapped wrapped key fails too — the header is authenticated',
        () async {
      final (file, copy) = await freshCopy();
      final tampered = Uint8List.fromList(pristine);
      // Byte 12 is the first byte of the wrapped key blob, which sits in the
      // GCM additional authenticated data.
      tampered[12] ^= 0x01;
      await file.writeAsBytes(tampered, flush: true);

      await expectLater(
        copy.unlock(passphrase),
        // The wrapped key has its own tag, and it is checked first.
        throwsA(isA<SecretVaultException>()),
      );
    });
  });

  test('a write that cannot reach the disk leaves the old vault readable',
      () async {
    final (file, copy) = await freshCopy();
    await copy.unlock(passphrase);

    // The temp file the atomic write needs is already a directory, so
    // writing it fails before the rename can happen. Any I/O failure at that
    // point has the same shape: the rename never runs, and the vault on disk
    // is still the previous one.
    final blocker = Directory('${file.path}.tmp');
    await blocker.create();

    await expectLater(
      copy.write('credentials:host-3', '{"password":"new"}'),
      throwsA(isA<FileSystemException>()),
    );
    await blocker.delete();

    final reopened = SecretVault(file: file, useIsolate: false);
    await reopened.unlock(passphrase);
    expect(await reopened.read('credentials:host-1'), '{"password":"hunter2"}');
    // And the write that failed did not half-land in memory either.
    expect(await reopened.read('credentials:host-3'), isNull);
  });

  test('the session key is derived once per unlock, not per operation',
      () async {
    final (_, copy) = await freshCopy();
    expect(copy.keyDerivations, 0);

    await copy.unlock(passphrase);
    expect(copy.keyDerivations, 1);

    await copy.read('credentials:host-1');
    await copy.write('credentials:host-9', 'x');
    await copy.read('credentials:host-9');
    await copy.delete('credentials:host-9');

    // Argon2id at 64 MiB is roughly a second. Re-deriving it on each of
    // those four operations is the difference between a usable app and one
    // that appears to hang every time a host is saved.
    expect(copy.keyDerivations, 1);
  });

  test('locking drops the session key and the decrypted secrets', () async {
    final (_, copy) = await freshCopy();
    await copy.unlock(passphrase);
    copy.lock();

    expect(copy.isUnlocked, isFalse);
    await expectLater(
      copy.read('credentials:host-1'),
      throwsA(isA<SecretVaultLockedException>()),
    );
    await expectLater(
      copy.write('credentials:host-1', 'x'),
      throwsA(isA<SecretVaultLockedException>()),
    );
  });

  test('creating a vault over an existing one is refused', () async {
    final (_, copy) = await freshCopy();
    await expectLater(
      copy.create('a different passphrase'),
      throwsA(isA<SecretVaultStateException>()),
    );
  });
}
