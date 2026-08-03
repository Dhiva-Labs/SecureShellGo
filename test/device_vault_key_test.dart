import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/device_vault_key.dart';
import 'package:secure_shell_go/services/secret_vault.dart';

void main() {
  late Directory dir;
  late File file;
  late DeviceVaultKey key;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ssg_device_key_test');
    file = File('${dir.path}/${DeviceVaultKey.fileName}');
    key = DeviceVaultKey(file: file);
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('writes 256 bits and reads exactly them back', () async {
    final created = await key.create();
    expect(created.length, DeviceVaultKey.keyLength);
    expect(await key.read(), created);
  });

  test('every key is a fresh one', () async {
    final first = await key.create();
    final second = await key.create();
    expect(second, isNot(first));
  });

  test('the file is 0600', () async {
    await key.create();
    expect(file.statSync().mode & 0x1ff, DeviceVaultKey.ownerOnlyMode);
    // And nothing was left behind at the umask's default mode on the way.
    expect(await File('${file.path}.tmp').exists(), isFalse);
  }, skip: Platform.isWindows ? 'POSIX modes only' : null);

  test('a missing or wrong-sized key reads as null, never as a guess',
      () async {
    expect(await key.read(), isNull);
    await file.writeAsBytes(const <int>[1, 2, 3]);
    expect(await key.read(), isNull);
  });

  test('it opens a vault, and the vault holds no plaintext', () async {
    final created = await key.create();
    final vaultFile = File('${dir.path}/${SecretVault.fileName}');
    final vault = SecretVault(file: vaultFile, useIsolate: false);
    await vault.createWithKey(created);
    await vault.write('credentials:host-1', 'hunter2');

    final bytes = await vaultFile.readAsBytes();
    expect(String.fromCharCodes(bytes), isNot(contains('hunter2')));

    final reopened = SecretVault(file: vaultFile, useIsolate: false);
    await reopened.unlockWithKey((await key.read())!);
    expect(await reopened.read('credentials:host-1'), 'hunter2');
    // The whole point of the raw-key path: no Argon2id anywhere in it.
    expect(reopened.keyDerivations, 0);
  });
}
