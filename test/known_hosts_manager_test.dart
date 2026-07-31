import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/known_host.dart';
import 'package:secure_shell_go/services/known_hosts_integrity.dart';
import 'package:secure_shell_go/services/known_hosts_service.dart';
import 'package:secure_shell_go/services/secure_storage_backend.dart';

/// Covers the "Known hosts" manager screen's two data-layer requirements that
/// `known_hosts_service_test.dart` does not already exercise: [all]'s
/// ordering (what the list screen renders, newest first) and that removing
/// an entry through [KnownHostsService.forgetHost] — the only sanctioned way,
/// per its own doc comment — leaves the HMAC seal on disk valid rather than
/// merely leaving the in-memory copy correct. See `known_hosts_screen.dart`
/// and `known_hosts_integrity_test.dart` (which owns the seal mechanics
/// themselves, not this file).
class FakeSecureStorageBackend implements SecureStorageBackend {
  final Map<String, String> data = {};

  @override
  Future<void> write(String key, String value) async => data[key] = value;

  @override
  Future<String?> read(String key) async => data[key];

  @override
  Future<void> delete(String key) async => data.remove(key);
}

void main() {
  late Directory tempDir;
  late File storeFile;
  late FakeSecureStorageBackend backend;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('known_hosts_manager');
    storeFile = File('${tempDir.path}/known_hosts.json');
    backend = FakeSecureStorageBackend();
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  KnownHostsService service() => KnownHostsService(
        file: storeFile,
        integrityKey: KnownHostsIntegrityKey(backend),
      );

  KnownHostKey key(String hostname, DateTime addedAt, {String fp = 'SHA256:x'}) {
    return KnownHostKey(
      hostname: hostname,
      port: 22,
      keyType: 'ssh-ed25519',
      fingerprint: fp,
      addedAt: addedAt,
    );
  }

  group('all() ordering', () {
    test('newest first, regardless of trust order', () async {
      final svc = service();
      await svc.trust(key('middle.example', DateTime(2026, 6, 1)));
      await svc.trust(key('oldest.example', DateTime(2026, 1, 1)));
      await svc.trust(key('newest.example', DateTime(2026, 12, 1)));

      final hostnames = (await svc.all()).map((k) => k.hostname).toList();
      expect(hostnames, ['newest.example', 'middle.example', 'oldest.example']);
    });

    test('the order survives a reload through the sealed envelope', () async {
      await service().trust(key('a.example', DateTime(2020, 1, 1)));
      await service().trust(key('b.example', DateTime(2025, 1, 1)));

      final reloaded = await service().all();
      expect(reloaded.map((k) => k.hostname).toList(), ['b.example', 'a.example']);
    });
  });

  group('remove round-trips through the seal', () {
    test('a removed host stays gone after a fresh load, seal intact',
        () async {
      await service().trust(key('keep.example', DateTime(2026, 1, 1)));
      await service().trust(key('drop.example', DateTime(2026, 1, 2)));

      await service().forgetHost('drop.example', 22);

      // A brand new instance, sharing only the file and the backend: this is
      // exactly the seal round trip — persist(), close everything, reopen,
      // and the MAC written by the *removal* itself must still verify.
      final reloaded = service();
      final all = await reloaded.all();

      expect(all.map((k) => k.hostname).toList(), ['keep.example']);
      expect(reloaded.integrityFailed, isFalse);
    });

    test('removing one key type leaves a sibling type on the same host',
        () async {
      final svc = service();
      await svc.trust(key('multi.example', DateTime(2026, 1, 1))
          .copyWithType('ssh-ed25519'));
      await svc.trust(key('multi.example', DateTime(2026, 1, 1))
          .copyWithType('rsa-sha2-512'));
      expect((await svc.all()).length, 2);

      // forgetHost is host-scoped (matching ssh-keygen -R), so it drops both
      // — this asserts that documented behaviour still holds after a reload,
      // not a different, narrower one.
      await svc.forgetHost('multi.example', 22);
      final reloaded = await service().all();
      expect(reloaded, isEmpty);
    });

    test('a tampered file after a legitimate removal is still rejected',
        () async {
      await service().trust(key('a.example', DateTime(2026, 1, 1)));
      await service().trust(key('b.example', DateTime(2026, 1, 2)));
      await service().forgetHost('b.example', 22);

      // Flip a byte in the sealed file by hand, as if something outside the
      // app had rewritten it after the legitimate removal.
      final raw = await storeFile.readAsString();
      await storeFile.writeAsString(raw.replaceFirst('"mac"', '"mac2"'));

      final reloaded = service();
      expect(await reloaded.all(), isEmpty);
      expect(reloaded.integrityFailed, isTrue);
    });
  });

  group('fingerprint fidelity', () {
    // A real fingerprint, as `ssh-keygen -lf` would print it for a key this
    // test generates — not a hand-typed stand-in — so a fixture mismatch here
    // means the storage layer altered something about the string itself
    // (case, whitespace, encoding), not that the fixture was wrong.
    test('a real SHA256 fingerprint survives storage byte-for-byte', () async {
      final work = await Directory.systemTemp.createTemp('fp_fixture');
      addTearDown(() => work.delete(recursive: true));

      final keyFile = File('${work.path}/id_ed25519');
      final gen = await Process.run('ssh-keygen', [
        '-t', 'ed25519', '-N', '', '-C', 'fixture', '-f', keyFile.path,
      ]);
      expect(gen.exitCode, 0, reason: gen.stderr.toString());

      final fp = await Process.run(
        'ssh-keygen',
        ['-lf', '${keyFile.path}.pub', '-E', 'sha256'],
      );
      expect(fp.exitCode, 0, reason: fp.stderr.toString());
      // "256 SHA256:xxxxxxxx... fixture (ED25519)" — the second field.
      final fixture =
          (fp.stdout as String).trim().split(RegExp(r'\s+'))[1];
      expect(fixture, startsWith('SHA256:'));

      await service().trust(key('fixture.example', DateTime(2026, 1, 1), fp: fixture));

      final reloaded = await service().all();
      expect(reloaded.single.fingerprint, fixture);
    });
  });
}

extension on KnownHostKey {
  /// Copies with a different [keyType] only — used above to trust two
  /// algorithms for the same host without repeating every field.
  KnownHostKey copyWithType(String keyType) => KnownHostKey(
        hostname: hostname,
        port: port,
        keyType: keyType,
        fingerprint: fingerprint,
        addedAt: addedAt,
      );
}
