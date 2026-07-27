import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/host_key_policy.dart';
import 'package:secure_shell_go/services/known_hosts_service.dart';

void main() {
  late Directory tempDir;
  late KnownHostsService knownHosts;
  late HostKeyPolicy policy;

  /// Prompts the policy raised, in order.
  late List<HostKeyPrompt> prompts;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('host_key_policy_test');
    knownHosts = KnownHostsService(
      file: File('${tempDir.path}/known_hosts.json'),
    );
    policy = HostKeyPolicy(knownHosts);
    prompts = [];
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  /// A verifier that records what it was asked and answers [answer].
  HostKeyVerifier answering(bool answer) {
    return (prompt) async {
      prompts.add(prompt);
      return answer;
    };
  }

  /// A verifier that fails the test if it is ever called.
  Future<bool> neverPrompts(HostKeyPrompt prompt) async {
    fail('the user should not have been prompted, got ${prompt.kind}');
  }

  Future<bool> evaluate({
    required HostKeyVerifier verify,
    String hostname = 'example.com',
    int port = 22,
    String keyType = 'ssh-ed25519',
    String fingerprint = 'SHA256:ORIGINAL',
  }) {
    return policy.evaluate(
      hostname: hostname,
      port: port,
      keyType: keyType,
      fingerprint: fingerprint,
      verify: verify,
    );
  }

  group('trust on first use', () {
    test('an unknown host prompts, and accepting persists the key', () async {
      expect(await evaluate(verify: answering(true)), isTrue);

      expect(prompts, hasLength(1));
      expect(prompts.single.kind, HostKeyPromptKind.unknown);
      expect(prompts.single.fingerprint, 'SHA256:ORIGINAL');
      expect(prompts.single.previous, isNull);
      expect(prompts.single.hostHasOtherKeys, isFalse);

      final stored = await knownHosts.lookup('example.com', 22, 'ssh-ed25519');
      expect(stored?.fingerprint, 'SHA256:ORIGINAL');
    });

    test('rejecting refuses the connection and stores nothing', () async {
      expect(await evaluate(verify: answering(false)), isFalse);
      expect(prompts.single.kind, HostKeyPromptKind.unknown);
      expect(await knownHosts.lookup('example.com', 22, 'ssh-ed25519'), isNull);
    });

    test('a second key type on a known host is flagged as such', () async {
      await evaluate(verify: answering(true));
      prompts.clear();

      await evaluate(
        verify: answering(true),
        keyType: 'rsa-sha2-512',
        fingerprint: 'SHA256:RSAKEY',
      );

      expect(prompts.single.kind, HostKeyPromptKind.unknown);
      // Not an alarm, but the dialog says "first time with an RSA key".
      expect(prompts.single.hostHasOtherKeys, isTrue);
    });
  });

  group('a matching key', () {
    test('reconnecting does not prompt again', () async {
      await evaluate(verify: answering(true));
      expect(await evaluate(verify: neverPrompts), isTrue);
    });

    test('matching is scoped to the port', () async {
      await evaluate(verify: answering(true));
      prompts.clear();

      // Same fingerprint, different port: still a first-use decision.
      await evaluate(verify: answering(true), port: 2222);
      expect(prompts.single.kind, HostKeyPromptKind.unknown);
    });
  });

  group('a changed key', () {
    setUp(() async {
      await evaluate(verify: answering(true));
      prompts.clear();
    });

    test('is blocked by default and reports both fingerprints', () async {
      expect(
        await evaluate(verify: answering(false), fingerprint: 'SHA256:EVIL'),
        isFalse,
      );

      expect(prompts.single.kind, HostKeyPromptKind.changed);
      expect(prompts.single.fingerprint, 'SHA256:EVIL');
      expect(prompts.single.previous?.fingerprint, 'SHA256:ORIGINAL');
    });

    test('rejecting leaves the original key trusted', () async {
      await evaluate(verify: answering(false), fingerprint: 'SHA256:EVIL');

      final stored = await knownHosts.lookup('example.com', 22, 'ssh-ed25519');
      expect(stored?.fingerprint, 'SHA256:ORIGINAL');

      // And the original still connects without a prompt.
      expect(await evaluate(verify: neverPrompts), isTrue);
    });

    test('explicitly trusting the new key replaces the old one', () async {
      expect(
        await evaluate(verify: answering(true), fingerprint: 'SHA256:ROTATED'),
        isTrue,
      );

      final stored = await knownHosts.lookup('example.com', 22, 'ssh-ed25519');
      expect(stored?.fingerprint, 'SHA256:ROTATED');

      // The rotated key is now the silent one...
      expect(
        await evaluate(verify: neverPrompts, fingerprint: 'SHA256:ROTATED'),
        isTrue,
      );
      // ...and the superseded key now trips the alarm.
      prompts.clear();
      await evaluate(verify: answering(false));
      expect(prompts.single.kind, HostKeyPromptKind.changed);
    });

    test('the decision survives a restart of the store', () async {
      final reloaded = HostKeyPolicy(
        KnownHostsService(file: File('${tempDir.path}/known_hosts.json')),
      );

      final seen = <HostKeyPrompt>[];
      final result = await reloaded.evaluate(
        hostname: 'example.com',
        port: 22,
        keyType: 'ssh-ed25519',
        fingerprint: 'SHA256:EVIL',
        verify: (prompt) async {
          seen.add(prompt);
          return false;
        },
      );

      expect(result, isFalse);
      expect(seen.single.kind, HostKeyPromptKind.changed);
    });
  });

  test('fingerprints decode to the OpenSSH form', () {
    const bytes = [
      83, 72, 65, 50, 53, 54, 58, 97, 98, 99, // "SHA256:abc"
    ];
    expect(HostKeyPolicy.decodeFingerprint(bytes), 'SHA256:abc');
  });
}
