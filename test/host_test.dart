import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/host.dart';

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
}
