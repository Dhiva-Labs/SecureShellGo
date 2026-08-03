import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/backup_crypto.dart';
import 'package:secure_shell_go/services/secret_vault.dart';

import 'vault_fixture.dart';

/// A key that is not the device's, for the wrong-key cases.
final Uint8List otherKey =
    Uint8List.fromList(List<int>.generate(32, (i) => 255 - i));

void main() {
  late Directory dir;
  late File file;
  late SecretVault vault;
  late Uint8List pristine;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ssg_vault_test');
    file = File('${dir.path}/${SecretVault.fileName}');
    vault = SecretVault(file: file, useIsolate: false);
    await vault.createWithKey(deviceKey);
    await vault.write('credentials:host-1', '{"password":"hunter2"}');
    pristine = await file.readAsBytes();
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  /// A second instance over the same bytes — what the next app launch sees.
  SecretVault reopen() => SecretVault(file: file, useIsolate: false);

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

    test('a device-sealed vault reopens with the same 32 bytes', () async {
      final copy = reopen();
      await copy.unlockWithKey(deviceKey);
      expect(await copy.read('credentials:host-1'), '{"password":"hunter2"}');
    });

    test('the file is not the user-visible plaintext of anything', () async {
      expect(String.fromCharCodes(pristine.sublist(0, 6)), 'SSGVLT');
      expect(String.fromCharCodes(pristine), isNot(contains('hunter2')));
    });

    test('a fresh nonce per write, which is what makes one key safe',
        () async {
      // Mode 1 has no wrapped key, so the nonce sits at a fixed offset.
      Uint8List nonceOf(Uint8List bytes) => bytes.sublist(14, 26);
      final first = nonceOf(pristine);
      await vault.write('credentials:host-2', 'x');
      final second = nonceOf(await file.readAsBytes());
      expect(second, isNot(first));
    });
  });

  group('the wrong key', () {
    test('is refused, and leaves the vault exactly as it was', () async {
      final copy = reopen();

      await expectLater(
        copy.unlockWithKey(otherKey),
        throwsA(isA<SecretVaultAuthException>()),
      );
      expect(copy.isUnlocked, isFalse);
      // The failure must not have rewritten, truncated or emptied anything —
      // this is the case where a careless "start fresh on error" would throw
      // away every credential the user owns.
      expect(await file.readAsBytes(), pristine);

      await copy.unlockWithKey(deviceKey);
      expect(await copy.read('credentials:host-1'), '{"password":"hunter2"}');
    });

    test('says so without claiming to know which of the two it was', () {
      const failure = SecretVaultAuthException();
      expect(failure.message, contains('Wrong passphrase'));
      expect(failure.message, contains('damaged'));
    });

    test('a key that is not 32 bytes is refused before anything is read',
        () async {
      await expectLater(
        reopen().unlockWithKey(Uint8List(16)),
        throwsA(isA<SecretVaultFormatException>()),
      );
    });
  });

  group('damaged files', () {
    test('a truncated vault is refused and left alone', () async {
      final truncated = pristine.sublist(0, 20);
      await file.writeAsBytes(truncated, flush: true);

      await expectLater(
        reopen().unlockWithKey(deviceKey),
        throwsA(isA<SecretVaultFormatException>()),
      );
      expect(await file.readAsBytes(), truncated);
    });

    test('a file that is not a vault at all is refused', () async {
      await file.writeAsString('not a vault, just some text in a file');

      await expectLater(
        reopen().unlockWithKey(deviceKey),
        throwsA(isA<SecretVaultFormatException>()),
      );
    });

    test('a flipped bit in the payload fails the tag check', () async {
      final tampered = Uint8List.fromList(pristine);
      tampered[tampered.length - 1] ^= 0x01;
      await file.writeAsBytes(tampered, flush: true);

      await expectLater(
        reopen().unlockWithKey(deviceKey),
        throwsA(isA<SecretVaultAuthException>()),
      );
    });

    test('a vault from a newer format version says so rather than guessing',
        () async {
      final tampered = Uint8List.fromList(pristine);
      tampered[7] = SecretVault.formatVersion + 1;
      await file.writeAsBytes(tampered, flush: true);

      await expectLater(
        reopen().unlockWithKey(deviceKey),
        throwsA(
          isA<SecretVaultFormatException>()
              .having((e) => e.message, 'message', contains('newer version')),
        ),
      );
    });
  });

  group('the key-wrap mode byte', () {
    test('is covered by the tag, so claiming a different one is refused',
        () async {
      // Sealed as mode 1 and then relabelled mode 0 on disk. The parser is
      // happy to read it — a mode-0 file is a legitimate shape — so this is
      // the AAD doing the work and nothing else.
      final wrapped = await BackupCrypto.encrypt(
        plaintext: deviceKey,
        passphrase: 'correct horse battery staple',
        useIsolate: false,
      );
      final sealed = buildVaultFile(
        version: 2,
        // What the tag is computed over…
        wrapMode: SecretVault.wrapModeDeviceKey,
        wrappedKey: wrapped,
        key: deviceKey,
        nonce: BackupCrypto.randomBytes(SecretVault.nonceLength),
        secrets: const {'credentials:host-1': 'hunter2'},
      );
      // …and what the file then claims. Byte 8 is the mode.
      sealed[8] = SecretVault.wrapModePassphrase;
      await file.writeAsBytes(sealed, flush: true);

      await expectLater(
        reopen().unlock('correct horse battery staple'),
        throwsA(isA<SecretVaultAuthException>()),
      );
    });

    test('an empty wrapped-key slot is legal only for a device key', () async {
      final nonce = BackupCrypto.randomBytes(SecretVault.nonceLength);
      // Mode 1 with nothing in the slot: the ordinary device vault.
      await file.writeAsBytes(
        buildVaultFile(
          version: 2,
          wrapMode: SecretVault.wrapModeDeviceKey,
          wrappedKey: Uint8List(0),
          key: deviceKey,
          nonce: nonce,
          secrets: const {'credentials:host-1': 'hunter2'},
        ),
        flush: true,
      );
      final ok = reopen();
      await ok.unlockWithKey(deviceKey);
      expect(await ok.read('credentials:host-1'), 'hunter2');

      // Mode 0 with nothing in the slot: there is no passphrase container to
      // unwrap, so this is a damaged file rather than an empty one.
      await file.writeAsBytes(
        buildVaultFile(
          version: 2,
          wrapMode: SecretVault.wrapModePassphrase,
          wrappedKey: Uint8List(0),
          key: deviceKey,
          nonce: nonce,
        ),
        flush: true,
      );
      await expectLater(
        reopen().unlock('anything'),
        throwsA(isA<SecretVaultFormatException>()),
      );

      // And the reverse: a device vault has nothing to put in the slot.
      await file.writeAsBytes(
        buildVaultFile(
          version: 2,
          wrapMode: SecretVault.wrapModeDeviceKey,
          wrappedKey: Uint8List(64),
          key: deviceKey,
          nonce: nonce,
        ),
        flush: true,
      );
      await expectLater(
        reopen().unlockWithKey(deviceKey),
        throwsA(isA<SecretVaultFormatException>()),
      );
    });

    test('an unrecognised mode is refused rather than assumed', () async {
      final tampered = Uint8List.fromList(pristine);
      tampered[8] = 7;
      await file.writeAsBytes(tampered, flush: true);

      await expectLater(
        reopen().unlockWithKey(deviceKey),
        throwsA(isA<SecretVaultFormatException>()),
      );
    });
  });

  group('a vault written by 1.4.1', () {
    const passphrase = 'correct horse battery staple';

    Future<void> writeLegacyVault() async => file.writeAsBytes(
          await buildLegacyVaultFile(
            passphrase: passphrase,
            secrets: const {'credentials:host-1': '{"password":"hunter2"}'},
          ),
          flush: true,
        );

    test('still opens, and its secrets are still there', () async {
      await writeLegacyVault();

      final copy = reopen();
      await copy.unlock(passphrase);
      expect(await copy.read('credentials:host-1'), '{"password":"hunter2"}');
    });

    test('a wrong passphrase is refused and the file is left alone', () async {
      await writeLegacyVault();
      final before = await file.readAsBytes();

      final copy = reopen();
      await expectLater(
        copy.unlock('not the passphrase'),
        throwsA(isA<SecretVaultAuthException>()),
      );
      expect(await file.readAsBytes(), before);
    });

    test('a swapped wrapped key fails too — the header is authenticated',
        () async {
      await writeLegacyVault();
      final tampered = Uint8List.fromList(await file.readAsBytes());
      // Byte 12 is the first byte of the wrapped key blob in format 1, which
      // sits in the GCM additional authenticated data.
      tampered[12] ^= 0x01;
      await file.writeAsBytes(tampered, flush: true);

      await expectLater(
        reopen().unlock(passphrase),
        // The wrapped key has its own tag, and it is checked first.
        throwsA(isA<SecretVaultException>()),
      );
    });

    test('the session key is derived once per unlock, not per operation',
        () async {
      await writeLegacyVault();
      final copy = reopen();
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

    test('a device key sitting beside it is not tried against it', () async {
      await writeLegacyVault();
      await expectLater(
        reopen().unlockWithKey(deviceKey),
        throwsA(isA<SecretVaultAuthException>()),
      );
    });
  });

  test('the device path never runs Argon2id, not once', () async {
    // The measured reason this mode exists. 64 MiB of memory-hard derivation
    // protects low-entropy human input; there is none here, and the cost
    // would land on first save and on every app start.
    expect(vault.keyDerivations, 0);

    final copy = reopen();
    await copy.unlockWithKey(deviceKey);
    await copy.write('credentials:host-2', 'x');
    expect(copy.keyDerivations, 0);
  });

  test('a write that cannot reach the disk leaves the old vault readable',
      () async {
    // The temp file the atomic write needs is already a directory, so
    // writing it fails before the rename can happen. Any I/O failure at that
    // point has the same shape: the rename never runs, and the vault on disk
    // is still the previous one.
    final blocker = Directory('${file.path}.tmp');
    await blocker.create();

    await expectLater(
      vault.write('credentials:host-3', '{"password":"new"}'),
      throwsA(isA<FileSystemException>()),
    );
    await blocker.delete();

    final reopened = reopen();
    await reopened.unlockWithKey(deviceKey);
    expect(await reopened.read('credentials:host-1'), '{"password":"hunter2"}');
    // And the write that failed did not half-land in memory either.
    expect(await reopened.read('credentials:host-3'), isNull);
  });

  test('locking drops the session key and the decrypted secrets', () async {
    vault.lock();

    expect(vault.isUnlocked, isFalse);
    await expectLater(
      vault.read('credentials:host-1'),
      throwsA(isA<SecretVaultLockedException>()),
    );
    await expectLater(
      vault.write('credentials:host-1', 'x'),
      throwsA(isA<SecretVaultLockedException>()),
    );
    // The caller's own copy of the key is untouched by that.
    expect(deviceKey[0], 1);
  });

  test('creating a vault over an existing one is refused', () async {
    await expectLater(
      reopen().createWithKey(otherKey),
      throwsA(isA<SecretVaultStateException>()),
    );
  });

  group('isDeviceWrapped', () {
    test('reads the mode off disk, and says nothing when there is no vault',
        () async {
      expect(await vault.isDeviceWrapped(), isTrue);
      await file.delete();
      expect(await reopen().isDeviceWrapped(), isNull);
    });
  });
}
