import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/models/host_ai_access.dart';

void main() {
  const host = Host(
    id: 'fixed-id',
    label: 'Home server',
    hostname: 'example.com',
    port: 2222,
    username: 'dev',
    authMethod: SshAuthMethod.privateKey,
    group: 'Work',
    colorLabel: HostColorLabel.blue,
  );

  group('Host.toJson/fromJson', () {
    test('round-trips group and colorLabel', () {
      final restored = Host.fromJson(host.toJson());
      expect(restored.group, 'Work');
      expect(restored.colorLabel, HostColorLabel.blue);
    });

    test('round-trips a host with neither group nor colorLabel', () {
      const bare = Host(
        id: 'x',
        label: '',
        hostname: 'example.com',
        port: 22,
        username: 'dev',
        authMethod: SshAuthMethod.password,
      );
      final restored = Host.fromJson(bare.toJson());
      expect(restored.group, isNull);
      expect(restored.colorLabel, isNull);
      // Neither key should even be written when both are absent — keeps a
      // freshly-saved host's JSON identical to one from before this feature.
      expect(bare.toJson().containsKey('group'), isFalse);
      expect(bare.toJson().containsKey('colorLabel'), isFalse);
    });

    test('a map from before v1.3.0 (no group/colorLabel keys) loads as '
        'Ungrouped with no colour', () {
      final restored = Host.fromJson(const {
        'id': 'legacy',
        'label': '',
        'hostname': 'example.com',
        'port': 22,
        'username': 'dev',
        'authMethod': 'password',
      });
      expect(restored.group, isNull);
      expect(restored.colorLabel, isNull);
    });

    test('a blank group string reads as Ungrouped, not an empty-named group',
        () {
      final restored = Host.fromJson(const {
        'id': 'a',
        'label': '',
        'hostname': 'example.com',
        'port': 22,
        'username': 'dev',
        'authMethod': 'password',
        'group': '   ',
      });
      expect(restored.group, isNull);
    });

    test('an unrecognised colorLabel id loads as no colour', () {
      final restored = Host.fromJson(const {
        'id': 'a',
        'label': '',
        'hostname': 'example.com',
        'port': 22,
        'username': 'dev',
        'authMethod': 'password',
        'colorLabel': 'ultraviolet',
      });
      expect(restored.colorLabel, isNull);
    });
  });

  group('Host.withGroup', () {
    test('changes only the group, leaving every other field untouched', () {
      final moved = host.withGroup('Home');
      expect(moved.group, 'Home');
      expect(moved.id, host.id);
      expect(moved.label, host.label);
      expect(moved.hostname, host.hostname);
      expect(moved.port, host.port);
      expect(moved.username, host.username);
      expect(moved.authMethod, host.authMethod);
      expect(moved.colorLabel, host.colorLabel);
    });

    test('withGroup(null) clears the group, which copyWith cannot do', () {
      expect(host.withGroup(null).group, isNull);
    });
  });

  group('HostColorLabel', () {
    test('every value has a distinct, human-readable label', () {
      final labels = {for (final v in HostColorLabel.values) v.label};
      expect(labels, hasLength(HostColorLabel.values.length));
    });
  });

  group('Host.jumpHostId', () {
    test('round-trips through JSON', () {
      final restored = Host.fromJson(
        host.copyWith(jumpHostId: 'bastion-1').toJson(),
      );
      expect(restored.jumpHostId, 'bastion-1');
    });

    test('is absent from JSON when unset, and reads back as null', () {
      expect(host.toJson().containsKey('jumpHostId'), isFalse);
      expect(Host.fromJson(host.toJson()).jumpHostId, isNull);
    });

    test('a host saved before jump hosts existed reads as direct', () {
      final legacy = {
        'id': 'x',
        'label': 'Old',
        'hostname': 'example.com',
        'port': 22,
        'username': 'dev',
        'authMethod': 'password',
      };
      expect(Host.fromJson(legacy).jumpHostId, isNull);
    });

    test('an empty stored id reads as null, not as an unmatchable id', () {
      final restored = Host.fromJson({
        ...host.toJson(),
        'jumpHostId': '   ',
      });
      expect(restored.jumpHostId, isNull);
    });

    test('withJumpHost(null) clears it, which copyWith cannot do', () {
      final via = host.copyWith(jumpHostId: 'bastion-1');
      expect(via.copyWith(jumpHostId: null).jumpHostId, 'bastion-1');
      expect(via.withJumpHost(null).jumpHostId, isNull);
    });

    // The bug this guards against is a real one: withGroup rebuilds the host
    // field by field, so every field added later has to be added to it too.
    test('survives withGroup, which rebuilds field by field', () {
      final via = host.copyWith(jumpHostId: 'bastion-1');
      expect(via.withGroup('Elsewhere').jumpHostId, 'bastion-1');
      expect(via.withGroup(null).jumpHostId, 'bastion-1');
    });

    test('survives withJumpHost, which rebuilds field by field', () {
      final moved = host.withJumpHost('bastion-1');
      expect(moved.id, host.id);
      expect(moved.label, host.label);
      expect(moved.hostname, host.hostname);
      expect(moved.port, host.port);
      expect(moved.username, host.username);
      expect(moved.authMethod, host.authMethod);
      expect(moved.group, host.group);
      expect(moved.colorLabel, host.colorLabel);
    });
  });

  group('SshAuthMethod.agent', () {
    test('round-trips through JSON', () {
      final restored = Host.fromJson(
        host.copyWith(authMethod: SshAuthMethod.agent).toJson(),
      );
      expect(restored.authMethod, SshAuthMethod.agent);
    });

    test('an unknown method still falls back to password', () {
      expect(SshAuthMethod.fromName('totally-new'), SshAuthMethod.password);
      expect(SshAuthMethod.fromName(null), SshAuthMethod.password);
    });

    // A desktop-saved agent host must parse on a phone rather than throwing,
    // so the connect path can be the thing that explains the problem.
    test('parses on any platform, so a synced host cannot crash the list', () {
      final restored = Host.fromJson({
        'id': 'x',
        'label': 'Desktop box',
        'hostname': 'example.com',
        'port': 22,
        'username': 'dev',
        'authMethod': 'agent',
      });
      expect(restored.authMethod, SshAuthMethod.agent);
    });

    test('is the only method that stores no secret', () {
      final storeless = [
        for (final m in SshAuthMethod.values)
          if (m.storesNoSecret) m,
      ];
      expect(storeless, [SshAuthMethod.agent]);
    });
  });

  group('the 1.5 per-host options', () {
    const all = Host(
      id: 'opts',
      label: 'Build box',
      hostname: 'build.example.com',
      port: 22,
      username: 'ci',
      authMethod: SshAuthMethod.agent,
      agentForwarding: true,
      x11Forwarding: true,
      persistentSession: PersistentSession.tmux,
      certificate: 'ssh-ed25519-cert-v01@openssh.com AAAAC3 ci@build',
      transport: HostTransport.mosh,
    );

    test('a host using none of them saves exactly as before they existed',
        () {
      expect(
        host.toJson().keys,
        isNot(anyOf(
          contains('agentForwarding'),
          contains('x11Forwarding'),
          contains('persistentSession'),
          contains('certificate'),
          contains('transport'),
        )),
      );
    });

    test('a host saved before 1.5 reads as all off, plain SSH', () {
      final restored = Host.fromJson(const {
        'id': 'old',
        'hostname': 'old.example.com',
        'username': 'root',
        'authMethod': 'password',
      });
      expect(restored.agentForwarding, isFalse);
      expect(restored.x11Forwarding, isFalse);
      expect(restored.persistentSession, PersistentSession.off);
      expect(restored.certificate, isNull);
      expect(restored.transport, HostTransport.ssh);
    });

    test('every option round-trips through JSON', () {
      final restored = Host.fromJson(all.toJson());
      expect(restored.agentForwarding, isTrue);
      expect(restored.x11Forwarding, isTrue);
      expect(restored.persistentSession, PersistentSession.tmux);
      expect(restored.certificate, all.certificate);
      expect(restored.transport, HostTransport.mosh);
      for (final p in PersistentSession.values) {
        expect(
          Host.fromJson(all.copyWith(persistentSession: p).toJson())
              .persistentSession,
          p,
        );
      }
    });

    test('unknown or blank stored values fall back to the defaults', () {
      final restored = Host.fromJson({
        ...all.toJson(),
        'persistentSession': 'zellij',
        'transport': 'quic',
        'certificate': '  ',
      });
      expect(restored.persistentSession, PersistentSession.off);
      expect(restored.transport, HostTransport.ssh);
      expect(restored.certificate, isNull);
    });

    test('survive every helper that rebuilds a host field by field', () {
      for (final rebuilt in [
        all.withGroup('Other'),
        all.withJumpHost('jump'),
        all.withCertificate(all.certificate),
        all.copyWith(label: 'Renamed'),
      ]) {
        expect(rebuilt.agentForwarding, isTrue);
        expect(rebuilt.x11Forwarding, isTrue);
        expect(rebuilt.persistentSession, PersistentSession.tmux);
        expect(rebuilt.certificate, all.certificate);
        expect(rebuilt.transport, HostTransport.mosh);
        expect(rebuilt.legacyAlgorithms, all.legacyAlgorithms);
      }
    });

    test('withCertificate(null) removes it, which copyWith cannot do', () {
      expect(all.copyWith(certificate: null).certificate, all.certificate);
      final cleared = all.withCertificate(null);
      expect(cleared.certificate, isNull);
      expect(cleared.toJson().containsKey('certificate'), isFalse);
    });
  });

  group('Host.aiAccess', () {
    test('defaults to off and is omitted from JSON', () {
      expect(host.aiAccess, HostAiAccess.off);
      expect(host.toJson().containsKey('aiAccess'), isFalse);
    });

    test('readOnly round-trips through JSON', () {
      final on = host.copyWith(aiAccess: HostAiAccess.readOnly);
      expect(on.toJson()['aiAccess'], 'readOnly');
      expect(Host.fromJson(on.toJson()).aiAccess, HostAiAccess.readOnly);
    });

    test('absent, unknown or mistyped values read as off', () {
      Host read(Object? value) => Host.fromJson({
        'id': 'x',
        'hostname': 'example.com',
        'username': 'dev',
        'aiAccess': value,
      });
      expect(read(null).aiAccess, HostAiAccess.off);
      expect(read('readWrite').aiAccess, HostAiAccess.off);
      expect(read(true).aiAccess, HostAiAccess.off);
      expect(read(1).aiAccess, HostAiAccess.off);
      expect(HostAiAccess.fromJson('off'), HostAiAccess.off);
      expect(HostAiAccess.fromJson('readOnly'), HostAiAccess.readOnly);
    });

    test('copyWith can switch it off again and keeps other fields', () {
      final on = host.copyWith(aiAccess: HostAiAccess.readOnly);
      final off = on.copyWith(aiAccess: HostAiAccess.off);
      expect(off.aiAccess, HostAiAccess.off);
      expect(off.label, host.label);
      expect(on.copyWith(label: 'Other').aiAccess, HostAiAccess.readOnly);
    });

    test('survives the helpers that rebuild a host field by field', () {
      final on = host.copyWith(aiAccess: HostAiAccess.readOnly);
      expect(on.withGroup(null).aiAccess, HostAiAccess.readOnly);
      expect(on.withJumpHost('j').aiAccess, HostAiAccess.readOnly);
      expect(on.withCertificate('cert').aiAccess, HostAiAccess.readOnly);
    });
  });

  group('helpers that rebuild a Host drop nothing', () {
    // Every field away from its default; expectations come from toJson() so
    // a field added later is covered once it is written there.
    final full = Host(
      id: 'fixed-id',
      label: 'Home server',
      hostname: 'example.com',
      port: 2222,
      username: 'dev',
      authMethod: SshAuthMethod.privateKey,
      lastConnectedAt: DateTime.utc(2026, 1, 2, 3, 4, 5),
      group: 'Work',
      colorLabel: HostColorLabel.blue,
      startupCommand: 'tmux',
      jumpHostId: 'jump',
      legacyAlgorithms: true,
      agentForwarding: true,
      x11Forwarding: true,
      persistentSession: PersistentSession.values.last,
      certificate: 'cert',
      transport: HostTransport.values.last,
      aiAccess: HostAiAccess.readOnly,
    );

    test('the sample sets every field a bare host leaves out', () {
      const bare = Host(
        id: 'fixed-id',
        label: 'Home server',
        hostname: 'example.com',
        port: 2222,
        username: 'dev',
        authMethod: SshAuthMethod.privateKey,
      );
      final bareJson = bare.toJson();
      final fullJson = full.toJson();
      for (final key in bareJson.keys) {
        if (const {'id', 'label', 'hostname', 'port', 'username', 'authMethod'}
            .contains(key)) {
          continue;
        }
        expect(fullJson[key], isNot(equals(bareJson[key])), reason: key);
      }
      expect(fullJson.keys.length, greaterThan(bareJson.keys.length + 10));
    });

    test('copyWith() with no arguments keeps everything', () {
      expect(full.copyWith().toJson(), full.toJson());
    });

    test('withGroup, withJumpHost and withCertificate change only theirs', () {
      expect(
        full.withGroup('Other').toJson(),
        {...full.toJson(), 'group': 'Other'},
      );
      expect(
        full.withGroup(null).toJson(),
        Map<String, dynamic>.of(full.toJson())..remove('group'),
      );
      expect(
        full.withJumpHost('j2').toJson(),
        {...full.toJson(), 'jumpHostId': 'j2'},
      );
      expect(
        full.withJumpHost(null).toJson(),
        Map<String, dynamic>.of(full.toJson())..remove('jumpHostId'),
      );
      expect(
        full.withCertificate('c2').toJson(),
        {...full.toJson(), 'certificate': 'c2'},
      );
      expect(
        full.withCertificate(null).toJson(),
        Map<String, dynamic>.of(full.toJson())..remove('certificate'),
      );
    });

    test('fromJson(toJson()) loses nothing', () {
      expect(Host.fromJson(full.toJson()).toJson(), full.toJson());
    });
  });
}
