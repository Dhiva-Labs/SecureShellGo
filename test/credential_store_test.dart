import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/services/credential_store.dart';
import 'package:secure_shell_go/services/secure_storage_backend.dart';

/// An in-memory stand-in for the Keystore-backed [SecureStorageBackend], the
/// same way [HostStore]/[KnownHostsService] tests substitute a temp [File]
/// for path_provider.
class FakeSecureStorageBackend implements SecureStorageBackend {
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

/// A backend standing in for a locked/absent Linux keyring: every write
/// fails the way `FlutterSecureStorageBackend.write` does when the platform
/// cannot protect the secret.
class UnavailableSecureStorageBackend implements SecureStorageBackend {
  @override
  Future<void> write(String key, String value) async {
    throw const SecureStorageUnavailableException(
      'No system keyring is available or unlocked.',
      code: 'KeyringLocked',
    );
  }

  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> delete(String key) async {}
}

void main() {
  late FakeSecureStorageBackend backend;
  late CredentialStore store;

  setUp(() {
    backend = FakeSecureStorageBackend();
    store = CredentialStore(backend: backend);
  });

  test('a host with no saved credentials loads as null', () async {
    expect(await store.load('host-1'), isNull);
    expect(await store.has('host-1'), isFalse);
  });

  test('saved password credentials round-trip', () async {
    await store.save('host-1', const SshCredentials(password: 'hunter2'));

    final loaded = await store.load('host-1');
    expect(loaded, isNotNull);
    expect(loaded!.password, 'hunter2');
    expect(loaded.privateKeyPem, isNull);
    expect(loaded.passphrase, isNull);
    expect(await store.has('host-1'), isTrue);
  });

  test('saved private key credentials round-trip, passphrase included',
      () async {
    await store.save(
      'host-1',
      const SshCredentials(
        privateKeyPem: '-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END-----',
        passphrase: 'sekrit',
      ),
    );

    final loaded = await store.load('host-1');
    expect(loaded!.privateKeyPem, contains('BEGIN OPENSSH PRIVATE KEY'));
    expect(loaded.passphrase, 'sekrit');
    expect(loaded.password, isNull);
  });

  test('credentials are namespaced per host id', () async {
    await store.save('host-1', const SshCredentials(password: 'first'));
    await store.save('host-2', const SshCredentials(password: 'second'));

    expect((await store.load('host-1'))?.password, 'first');
    expect((await store.load('host-2'))?.password, 'second');
  });

  test('saving again for the same host replaces the old credentials',
      () async {
    await store.save(
      'host-1',
      const SshCredentials(
        privateKeyPem: 'old-key',
        passphrase: 'old-pass',
      ),
    );
    await store.save('host-1', const SshCredentials(password: 'new-password'));

    final loaded = await store.load('host-1');
    expect(loaded!.password, 'new-password');
    // The switch to password auth must not leave the old key/passphrase
    // sitting around under the same entry.
    expect(loaded.privateKeyPem, isNull);
    expect(loaded.passphrase, isNull);
  });

  test('delete removes the entry', () async {
    await store.save('host-1', const SshCredentials(password: 'hunter2'));
    await store.delete('host-1');

    expect(await store.load('host-1'), isNull);
    expect(await store.has('host-1'), isFalse);
  });

  test('deleting a host with no credentials is a no-op', () async {
    await store.delete('never-saved');
    expect(await store.load('never-saved'), isNull);
  });

  test('a corrupt stored entry fails closed to null', () async {
    backend.data['credentials:host-1'] = '{ not json';
    expect(await store.load('host-1'), isNull);
  });

  test('an entry that decodes to a non-map fails closed to null', () async {
    backend.data['credentials:host-1'] = '"just a string"';
    expect(await store.load('host-1'), isNull);
  });

  test('save never swallows a locked-keyring failure into a silent success',
      () async {
    final store = CredentialStore(backend: UnavailableSecureStorageBackend());

    await expectLater(
      store.save('host-1', const SshCredentials(password: 'hunter2')),
      throwsA(isA<SecureStorageUnavailableException>()),
    );
  });

  group('loadQuiet', () {
    test('reads like load from a backend that never prompts', () async {
      await store.save('host-1', const SshCredentials(password: 'hunter2'));
      final quiet = await store.loadQuiet('host-1');
      expect(quiet?.password, 'hunter2');
      expect(await store.loadQuiet('none'), isNull);
    });

    test('a sealed store throws CredentialsNeedPerson and never prompts',
        () async {
      final sealed = _SealedQuietBackend();
      final quietStore = CredentialStore(backend: sealed);
      await expectLater(
        quietStore.loadQuiet('host-1'),
        throwsA(
          isA<CredentialsNeedPerson>().having(
            (e) => e.kind,
            'kind',
            SecureStorageSealedKind.vault,
          ),
        ),
      );
      expect(sealed.promptingReads, 0);
      // The ordinary load is unchanged: it is the one allowed to prompt.
      await quietStore.load('host-1');
      expect(sealed.promptingReads, 1);
    });

    test('a quiet read that finds a value decodes it', () async {
      final quietStore = CredentialStore(
        backend: _SealedQuietBackend(quietValue: '{"password":"pw"}'),
      );
      expect((await quietStore.loadQuiet('host-1'))?.password, 'pw');
    });
  });
}

/// A backend whose ordinary read stands for one that would prompt.
class _SealedQuietBackend
    implements SecureStorageBackend, QuietSecureStorageRead {
  _SealedQuietBackend({this.quietValue});

  final String? quietValue;
  var promptingReads = 0;

  @override
  Future<String?> read(String key) async {
    promptingReads++;
    return null;
  }

  @override
  Future<String?> readQuiet(String key) async {
    final value = quietValue;
    if (value == null) {
      throw const SecureStorageSealed(SecureStorageSealedKind.vault);
    }
    return value;
  }

  @override
  Future<void> write(String key, String value) async {}

  @override
  Future<void> delete(String key) async {}
}
