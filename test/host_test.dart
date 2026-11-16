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

  group('Host.askToChange and its extras', () {
    final changing = host.copyWith(aiAccess: HostAiAccess.askToChange);

    test('askToChange is written as exactly "askToChange" and round-trips',
        () {
      // 1.6.0 reads any value it does not know as off, so this exact text is
      // what keeps a downgrade from handing an assistant anything.
      expect(changing.toJson()['aiAccess'], 'askToChange');
      expect(Host.fromJson(changing.toJson()).aiAccess,
          HostAiAccess.askToChange);
      expect(HostAiAccess.fromJson('askToChange'), HostAiAccess.askToChange);
      expect(HostAiAccess.fromJson('asktochange'), HostAiAccess.off);
      expect(HostAiAccess.fromJson('readWrite'), HostAiAccess.off);
    });

    test('defaults: no allowed commands, no terminal, omitted from JSON', () {
      expect(host.aiAllowedCommands, isEmpty);
      expect(host.aiTerminal, isFalse);
      expect(host.toJson().containsKey('aiAllowedCommands'), isFalse);
      expect(host.toJson().containsKey('aiTerminal'), isFalse);
    });

    test('the helpers are true only for the right access', () {
      for (final access in HostAiAccess.values) {
        final h = host.copyWith(aiAccess: access, aiTerminal: true);
        final changes = access == HostAiAccess.askToChange ||
            access == HostAiAccess.fullControl;
        expect(h.aiMayRequestChanges, changes);
        expect(h.aiMayOpenTerminal, changes);
      }
      expect(changing.aiMayOpenTerminal, isFalse,
          reason: 'terminal is off by default');
      expect(changing.copyWith(aiTerminal: true).aiMayOpenTerminal, isTrue);
    });

    test('both extras round-trip through JSON', () {
      final h = changing.copyWith(
        aiAllowedCommands: ['uptime', 'df -h'],
        aiTerminal: true,
      );
      expect(h.toJson()['aiAllowedCommands'], ['uptime', 'df -h']);
      expect(h.toJson()['aiTerminal'], true);
      final back = Host.fromJson(h.toJson());
      expect(back.aiAllowedCommands, ['uptime', 'df -h']);
      expect(back.aiTerminal, isTrue);
    });

    test('they stay stored when access steps down, and are inert', () {
      final full = changing.copyWith(
        aiAllowedCommands: ['uptime'],
        aiTerminal: true,
      );
      for (final access in [HostAiAccess.readOnly, HostAiAccess.off]) {
        final down = full.copyWith(aiAccess: access);
        expect(down.aiAllowedCommands, ['uptime']);
        expect(down.aiTerminal, isTrue);
        expect(down.aiMayRequestChanges, isFalse);
        expect(down.aiMayOpenTerminal, isFalse);
      }
    });

    test('every rebuilding helper carries both extras', () {
      final full = changing.copyWith(
        aiAllowedCommands: ['uptime'],
        aiTerminal: true,
      );
      for (final h in [
        full.withGroup('g'),
        full.withJumpHost('j'),
        full.withCertificate('cert'),
        full.copyWith(label: 'Other'),
      ]) {
        expect(h.aiAccess, HostAiAccess.askToChange);
        expect(h.aiAllowedCommands, ['uptime']);
        expect(h.aiTerminal, isTrue);
      }
      final bare = full.withoutAiGrants();
      expect(bare.aiAccess, HostAiAccess.off);
      expect(bare.aiAllowedCommands, isEmpty);
      expect(bare.aiTerminal, isFalse);
      expect(bare.label, full.label);
    });

    test('sanitising: trim, drop empty/long/NUL/duplicates, cap at 50', () {
      final long = 'a' * 4097;
      final ok = 'b' * 4096;
      final cleaned = Host.sanitizeAiAllowedCommands([
        '  uptime  ',
        '',
        '   ',
        long,
        ok,
        'has\u0000nul',
        'uptime',
        7,
        null,
        'df -h',
      ]);
      expect(cleaned, ['uptime', ok, 'df -h']);

      final many = Host.sanitizeAiAllowedCommands([
        for (var i = 0; i < 80; i++) 'cmd $i',
      ]);
      expect(many.length, 50);
      expect(many.first, 'cmd 0');
      expect(many.last, 'cmd 49');
    });

    test('sanitising drops entries that would hide what runs', () {
      // Each is dropped whole, never cleaned: stripping would store a
      // command the user did not type.
      final hidden = [
        'ls\nrm -rf ~', // a multi-line entry is several commands
        'ls\rrm -rf ~',
        'ls\trm',
        'echo \u001b[2Jhi', // ESC: terminal control
        'ls\u007f',
        'ls\u0085rm', // NEL (C1)
        'ls\u2028rm', // line separator
        'ls\u2029rm',
        'echo \u202Egnp.exe', // right-to-left override
        'echo \u202Aa', 'echo \u202Ba', 'echo \u202Ca', 'echo \u202Da',
        'echo \u2066a\u2069', 'echo \u2067a', 'echo \u2068a',
        'echo \u200Ea', 'echo \u200Fa', 'echo \u061Ca',
        'rm\u200B -rf', // zero-width space
        'r\u200Cm', 'r\u200Dm', 'r\u2060m', 'r\uFEFFm',
        'rm -rf\u00A0/', // no-break space: reads as a word break
        'rm -rf\u2009/', 'rm -rf\u3000/', 'rm -rf\u202F/', 'r\u00ADm',
        'echo \uD800', // lone high surrogate
        'echo \uDC00x', // lone low surrogate
      ];
      expect(
        Host.sanitizeAiAllowedCommands([...hidden, 'uptime']),
        ['uptime'],
      );
      // Ordinary text, including non-ASCII and a proper surrogate pair, stays.
      final fine = [
        'echo héllo',
        'echo 日本',
        'echo \u{1F600}',
        "awk '{print \$1}'",
      ];
      expect(Host.sanitizeAiAllowedCommands(fine), fine);
      // Surrounding line breaks are only whitespace and are trimmed off.
      expect(Host.sanitizeAiAllowedCommands(['\n uptime \n']), ['uptime']);
    });

    test('copyWith cleans a new list the same way fromJson does', () {
      final raw = ['  uptime ', 'uptime', 'ls\nrm -rf ~', '', 'df -h'];
      final h = host.copyWith(aiAllowedCommands: raw);
      expect(h.aiAllowedCommands, ['uptime', 'df -h']);
      expect(h.aiAllowedCommands, Host.fromJson({
        ...host.toJson(),
        'aiAllowedCommands': raw,
      }).aiAllowedCommands);
      // The stored list is a copy the caller cannot change afterwards.
      final mutable = ['uptime'];
      final kept = host.copyWith(aiAllowedCommands: mutable);
      mutable.add('rm -rf ~');
      expect(kept.aiAllowedCommands, ['uptime']);
      expect(() => kept.aiAllowedCommands.add('x'), throwsUnsupportedError);
    });

    test('fromJson sanitises, and mistyped values read as nothing', () {
      Host read(Map<String, Object?> extra) => Host.fromJson({
            'id': 'x',
            'hostname': 'example.com',
            'username': 'dev',
            ...extra,
          });
      expect(
        read({
          'aiAllowedCommands': [' ls ', 'ls', '']
        }).aiAllowedCommands,
        ['ls'],
      );
      expect(read({'aiAllowedCommands': 'ls'}).aiAllowedCommands, isEmpty);
      expect(read({'aiTerminal': 'true'}).aiTerminal, isFalse);
      expect(read({'aiTerminal': 1}).aiTerminal, isFalse);
      expect(read({'aiTerminal': true}).aiTerminal, isTrue);
    });
  });

  group('Host.fullControl and aiDesktop', () {
    final full = host.copyWith(aiAccess: HostAiAccess.fullControl);

    test('fullControl is written as exactly "fullControl" and round-trips', () {
      expect(full.toJson()['aiAccess'], 'fullControl');
      expect(Host.fromJson(full.toJson()).aiAccess, HostAiAccess.fullControl);
      expect(HostAiAccess.fromJson('fullControl'), HostAiAccess.fullControl);
      expect(HostAiAccess.fromJson('FullControl'), HostAiAccess.off);
      expect(HostAiAccess.fromJson('full_control'), HostAiAccess.off);
    });

    test('a level this build does not know still reads as off', () {
      for (final unknown in ['root', 'superControl', '', 'fullcontrol']) {
        expect(
          Host.fromJson({
            'id': 'x',
            'hostname': 'example.com',
            'username': 'dev',
            'aiAccess': unknown,
            'aiTerminal': true,
            'aiDesktop': true,
          }).aiMayOpenDesktop,
          isFalse,
          reason: unknown,
        );
      }
    });

    test('order of trust: off < readOnly < askToChange < fullControl', () {
      expect(HostAiAccess.values, [
        HostAiAccess.off,
        HostAiAccess.readOnly,
        HostAiAccess.askToChange,
        HostAiAccess.fullControl,
      ]);
    });

    test('full control implies terminal and desktop, whatever is stored', () {
      expect(full.aiTerminal, isFalse);
      expect(full.aiDesktop, isFalse);
      expect(full.aiFullControl, isTrue);
      expect(full.aiMayRequestChanges, isTrue);
      expect(full.aiMayOpenTerminal, isTrue);
      expect(full.aiMayOpenDesktop, isTrue);
    });

    test('the desktop switch counts only under ask to change', () {
      for (final access in HostAiAccess.values) {
        final h = host.copyWith(aiAccess: access, aiDesktop: true);
        expect(
          h.aiMayOpenDesktop,
          access == HostAiAccess.askToChange ||
              access == HostAiAccess.fullControl,
          reason: access.name,
        );
        expect(h.aiFullControl, access == HostAiAccess.fullControl);
      }
      final asking = host.copyWith(aiAccess: HostAiAccess.askToChange);
      expect(asking.aiMayOpenDesktop, isFalse, reason: 'off by default');
      expect(asking.aiMayOpenTerminal, isFalse);
    });

    test('aiDesktop defaults off, is omitted from JSON, and round-trips', () {
      expect(host.aiDesktop, isFalse);
      expect(host.toJson().containsKey('aiDesktop'), isFalse);
      final on = host.copyWith(aiDesktop: true);
      expect(on.toJson()['aiDesktop'], true);
      expect(Host.fromJson(on.toJson()).aiDesktop, isTrue);
      Host read(Object? v) => Host.fromJson({
            'id': 'x',
            'hostname': 'example.com',
            'username': 'dev',
            'aiDesktop': v,
          });
      expect(read('true').aiDesktop, isFalse);
      expect(read(1).aiDesktop, isFalse);
      expect(read(null).aiDesktop, isFalse);
    });

    test('stepping down keeps the switches stored but inert', () {
      final both = full.copyWith(aiTerminal: true, aiDesktop: true);
      for (final access in [HostAiAccess.readOnly, HostAiAccess.off]) {
        final down = both.copyWith(aiAccess: access);
        expect(down.aiDesktop, isTrue);
        expect(down.aiMayOpenDesktop, isFalse);
        expect(down.aiMayOpenTerminal, isFalse);
        expect(down.aiFullControl, isFalse);
      }
    });

    test('withoutAiGrants turns full control and the desktop off', () {
      final bare = full.copyWith(aiDesktop: true).withoutAiGrants();
      expect(bare.aiAccess, HostAiAccess.off);
      expect(bare.aiDesktop, isFalse);
      expect(bare.toJson().containsKey('aiDesktop'), isFalse);
      expect(bare.toJson().containsKey('aiAccess'), isFalse);
    });

    test('every rebuilding helper carries the desktop switch', () {
      final on = full.copyWith(aiDesktop: true);
      for (final h in [
        on.withGroup('g'),
        on.withJumpHost('j'),
        on.withCertificate('cert'),
        on.copyWith(label: 'Other'),
      ]) {
        expect(h.aiAccess, HostAiAccess.fullControl);
        expect(h.aiDesktop, isTrue);
      }
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
      aiAccess: HostAiAccess.askToChange,
      aiAllowedCommands: const ['uptime'],
      aiTerminal: true,
      aiDesktop: true,
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

    test('withoutAiGrants clears only the AI Bridge fields', () {
      final expected = Map<String, dynamic>.of(full.toJson())
        ..removeWhere(
          (k, _) => const {
            'aiAccess',
            'aiAllowedCommands',
            'aiTerminal',
            'aiDesktop',
          }.contains(k),
        );
      expect(full.withoutAiGrants().toJson(), expected);
    });

    test('fromJson(toJson()) loses nothing', () {
      expect(Host.fromJson(full.toJson()).toJson(), full.toJson());
    });
  });
}
