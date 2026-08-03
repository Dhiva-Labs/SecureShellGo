import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/composite_secure_storage.dart';
import 'package:secure_shell_go/services/device_vault_key.dart';
import 'package:secure_shell_go/services/secret_vault.dart';
import 'package:secure_shell_go/services/secure_storage_backend.dart';

import 'vault_fixture.dart';

/// A keyring that is present and working, over a plain map.
class _FakeKeyring implements SecureStorageBackend {
  final Map<String, String> data = {};

  @override
  Future<void> write(String key, String value) async {
    data[key] = value;
  }

  @override
  Future<String?> read(String key) async => data[key];

  @override
  Future<void> delete(String key) async {
    data.remove(key);
  }
}

/// A keyring that passes the availability probe and then refuses the write.
class _LockedOnWriteKeyring implements SecureStorageBackend {
  _LockedOnWriteKeyring({this.code = 'KeyringLocked'});

  final String code;

  @override
  Future<void> write(String key, String value) async {
    throw SecureStorageUnavailableException('nope', code: code);
  }

  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> delete(String key) async {}
}

void main() {
  const passphrase = 'correct horse battery staple';

  group('the selection rule, without a filesystem', () {
    test('a vault that exists wins, even against a working keyring', () {
      expect(
        CompositeSecureStorageBackend.choose(
          vaultExists: true,
          keyringAvailable: true,
          keyringEverAvailable: true,
        ),
        SecureStorageChoice.vault,
      );
    });

    test('a working keyring wins when there is no vault', () {
      expect(
        CompositeSecureStorageBackend.choose(
          vaultExists: false,
          keyringAvailable: true,
          keyringEverAvailable: false,
        ),
        SecureStorageChoice.keyring,
      );
    });

    test('a keyring that has worked before is never traded for a vault', () {
      expect(
        CompositeSecureStorageBackend.choose(
          vaultExists: false,
          keyringAvailable: false,
          keyringEverAvailable: true,
        ),
        SecureStorageChoice.keyringLocked,
      );
    });

    test('a keyring that has never worked is the only route to a vault', () {
      expect(
        CompositeSecureStorageBackend.choose(
          vaultExists: false,
          keyringAvailable: false,
          keyringEverAvailable: false,
        ),
        SecureStorageChoice.vaultSetupRequired,
      );
    });
  });

  group('over a temp directory', () {
    late Directory dir;
    late _FakeKeyring keyring;
    late bool keyringWorks;
    late SecretVault vault;
    late CompositeSecureStorageBackend backend;

    CompositeSecureStorageBackend build({
      Future<String?> Function()? requestUnlockPassphrase,
    }) {
      vault = SecretVault(
        file: File('${dir.path}/${SecretVault.fileName}'),
        useIsolate: false,
      );
      return CompositeSecureStorageBackend(
        keyring: keyring,
        vault: vault,
        keyringAvailable: () async => keyringWorks,
        deviceKey: DeviceVaultKey(
          file: File('${dir.path}/${DeviceVaultKey.fileName}'),
        ),
        state: SecureStorageState(
          file: File('${dir.path}/${SecureStorageState.fileName}'),
        ),
        requestUnlockPassphrase: requestUnlockPassphrase,
      );
    }

    /// Plants a vault exactly as 1.4.1 left one: format version 1, sealed
    /// with a typed passphrase. Nothing in the app creates these any more, so
    /// a test that wants one has to write it — which is also the honest way
    /// to test that they still open.
    Future<void> plantLegacyVault(Map<String, String> secrets) async {
      await File('${dir.path}/${SecretVault.fileName}').writeAsBytes(
        await buildLegacyVaultFile(passphrase: passphrase, secrets: secrets),
        flush: true,
      );
    }

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('ssg_composite_test');
      keyring = _FakeKeyring();
      keyringWorks = true;
      backend = build();
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('a working keyring takes the write, and no vault file appears',
        () async {
      await backend.write('credentials:host-1', 'secret');

      expect(keyring.data['credentials:host-1'], 'secret');
      expect(await backend.read('credentials:host-1'), 'secret');
      expect(
        await File('${dir.path}/${SecretVault.fileName}').exists(),
        isFalse,
      );
    });

    test('no keyring, and none ever: the write is encrypted, not refused',
        () async {
      keyringWorks = false;

      // Nothing thrown, nothing asked, nothing for a screen to apologise
      // for. This is the whole revision: storing it encrypted is the floor.
      await backend.write('credentials:host-1', 'secret');

      expect(await backend.read('credentials:host-1'), 'secret');
      expect(await vault.isDeviceWrapped(), isTrue);
      // The secret went somewhere, and that somewhere was not the keyring
      // and not a plaintext file.
      expect(keyring.data, isEmpty);
      expect(await backend.resolve(), SecureStorageChoice.vault);
      final vaultBytes =
          await File('${dir.path}/${SecretVault.fileName}').readAsBytes();
      expect(String.fromCharCodes(vaultBytes), isNot(contains('secret')));
    });

    test('a device-encrypted secret round-trips across a restart', () async {
      keyringWorks = false;
      await backend.write('credentials:host-1', 'secret');

      // A fresh launch, with nothing in memory and no way to prompt: the
      // device opens its own vault.
      final restarted = build(
        requestUnlockPassphrase: () async =>
            fail('a device-encrypted vault must never ask for a passphrase'),
      );
      expect(await restarted.read('credentials:host-1'), 'secret');
    });

    test('the device key file is private to its owner', () async {
      keyringWorks = false;
      await backend.write('credentials:host-1', 'secret');

      final keyFile = File('${dir.path}/${DeviceVaultKey.fileName}');
      expect(await keyFile.exists(), isTrue);
      expect(
        keyFile.statSync().mode & 0x1ff,
        DeviceVaultKey.ownerOnlyMode,
        reason: 'the key that opens the vault must be 0600',
      );
    }, skip: Platform.isWindows ? 'POSIX modes only' : null);

    test('a device key that has gone missing fails closed', () async {
      keyringWorks = false;
      await backend.write('credentials:host-1', 'secret');
      await File('${dir.path}/${DeviceVaultKey.fileName}').delete();

      final restarted = build(
        requestUnlockPassphrase: () async =>
            fail('there is no passphrase to ask for in device mode'),
      );
      // Reads as "nothing saved", exactly like an unreachable keyring, and
      // the vault is still on disk with nothing readable in it.
      expect(await restarted.read('credentials:host-1'), isNull);
      final vaultBytes =
          await File('${dir.path}/${SecretVault.fileName}').readAsBytes();
      expect(String.fromCharCodes(vaultBytes), isNot(contains('secret')));
    });

    test('a keyring seen working once is never downgraded to a vault',
        () async {
      // The keyring answers, which is what records the fact.
      await backend.write('credentials:host-1', 'secret');
      keyringWorks = false;

      await expectLater(
        backend.write('credentials:host-2', 'another'),
        throwsA(
          isA<SecureStorageUnavailableException>()
              .having((e) => e.message, 'message', contains('unlock')),
        ),
      );
      // And the automatic device path did not fire either: the only route
      // into a vault is the state where no keyring has ever worked.
      expect(
        await File('${dir.path}/${SecretVault.fileName}').exists(),
        isFalse,
      );
      expect(
        await File('${dir.path}/${DeviceVaultKey.fileName}').exists(),
        isFalse,
      );
    });

    test('the "keyring has worked here" fact survives a restart', () async {
      await backend.write('credentials:host-1', 'secret');
      keyringWorks = false;

      // A second backend over the same directory — a fresh app launch, with
      // nothing remembered in memory.
      final restarted = build();
      expect(await restarted.resolve(), SecureStorageChoice.keyringLocked);
    });

    test('a sealed vault asks for its passphrase before it is read',
        () async {
      keyringWorks = false;
      await plantLegacyVault(const {'credentials:host-1': 'secret'});

      var asked = 0;
      final restarted = build(
        requestUnlockPassphrase: () async {
          asked++;
          return passphrase;
        },
      );

      expect(await restarted.read('credentials:host-1'), 'secret');
      expect(asked, 1);
      // Unlocked for the session now: the second read must not re-prompt,
      // and must not re-derive.
      expect(await restarted.read('credentials:host-1'), 'secret');
      expect(asked, 1);
    });

    test('concurrent reads share one unlock prompt, not one each', () async {
      keyringWorks = false;
      await plantLegacyVault(const {
        'credentials:host-1': 'secret',
        'credentials:host-2': 'other',
      });

      var asked = 0;
      final restarted = build(
        requestUnlockPassphrase: () async {
          asked++;
          return passphrase;
        },
      );

      // What a cold start looks like: the host list resolving several hosts'
      // credentials at once.
      final results = await Future.wait([
        restarted.read('credentials:host-1'),
        restarted.read('credentials:host-2'),
        restarted.read('credentials:host-3'),
      ]);

      expect(results, ['secret', 'other', null]);
      expect(asked, 1);
    });

    test('a keyring that locks mid-write still says "unlock it"', () async {
      // Available on the probe, gone by the write — the race the probe's own
      // doc warns about. The answer must not become "make a vault".
      final backend = CompositeSecureStorageBackend(
        keyring: _LockedOnWriteKeyring(),
        vault: SecretVault(
          file: File('${dir.path}/${SecretVault.fileName}'),
          useIsolate: false,
        ),
        keyringAvailable: () async => true,
        deviceKey: DeviceVaultKey(
          file: File('${dir.path}/${DeviceVaultKey.fileName}'),
        ),
        state: SecureStorageState(
          file: File('${dir.path}/${SecureStorageState.fileName}'),
        ),
      );

      await expectLater(
        backend.write('credentials:host-1', 'secret'),
        throwsA(
          isA<SecureStorageUnavailableException>()
              .having((e) => e.code, 'code', 'KeyringLocked')
              .having((e) => e.message, 'message', contains('unlock')),
        ),
      );
    });

    test('a real libsecret error is passed through as it came', () async {
      final backend = CompositeSecureStorageBackend(
        keyring: _LockedOnWriteKeyring(code: 'Libsecret error'),
        vault: SecretVault(
          file: File('${dir.path}/${SecretVault.fileName}'),
          useIsolate: false,
        ),
        keyringAvailable: () async => true,
        deviceKey: DeviceVaultKey(
          file: File('${dir.path}/${DeviceVaultKey.fileName}'),
        ),
        state: SecureStorageState(
          file: File('${dir.path}/${SecureStorageState.fileName}'),
        ),
      );

      await expectLater(
        backend.write('credentials:host-1', 'secret'),
        throwsA(
          isA<SecureStorageUnavailableException>()
              .having((e) => e.code, 'code', 'Libsecret error')
              .having((e) => e.message, 'message', 'nope'),
        ),
      );
    });

    test('declining the unlock prompt fails closed rather than guessing',
        () async {
      keyringWorks = false;
      await plantLegacyVault(const {'credentials:host-1': 'secret'});

      final restarted = build(requestUnlockPassphrase: () async => null);

      expect(await restarted.read('credentials:host-1'), isNull);
      await expectLater(
        restarted.write('credentials:host-2', 'nope'),
        throwsA(
          isA<SecureStorageUnavailableException>()
              .having((e) => e.message, 'message', contains('locked')),
        ),
      );
    });

    test('a vault stays the store even once a keyring turns up', () async {
      keyringWorks = false;
      await plantLegacyVault(const {'credentials:host-1': 'secret'});
      backend = build(requestUnlockPassphrase: () async => passphrase);

      // The user installs GNOME Keyring. Nothing is migrated — that is
      // deliberate, and switching back would make the saved credential look
      // as though it had vanished.
      keyringWorks = true;
      expect(await backend.resolve(), SecureStorageChoice.vault);
      expect(await backend.read('credentials:host-1'), 'secret');
    });

    test('an unreadable state file is treated as "we have not seen one"',
        () async {
      await File('${dir.path}/${SecureStorageState.fileName}')
          .writeAsString('{ not json');
      keyringWorks = false;

      expect(await build().resolve(), SecureStorageChoice.vaultSetupRequired);
    });

    test('deleting through a keyring-locked backend is a quiet no-op',
        () async {
      keyringWorks = false;
      await expectLater(backend.delete('credentials:host-1'), completes);
    });
  });

  group('SecureStorageState', () {
    test('records the keyring only once and reads it back', () async {
      final dir = await Directory.systemTemp.createTemp('ssg_state_test');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final file = File('${dir.path}/${SecureStorageState.fileName}');

      final state = SecureStorageState(file: file);
      expect(await state.keyringEverAvailable(), isFalse);
      await state.recordKeyringAvailable();

      expect(await SecureStorageState(file: file).keyringEverAvailable(),
          isTrue);
      // It holds a fact about the platform, never a secret.
      final bytes = Uint8List.fromList(await file.readAsBytes());
      expect(String.fromCharCodes(bytes), contains('keyringEverAvailable'));
    });
  });
}
