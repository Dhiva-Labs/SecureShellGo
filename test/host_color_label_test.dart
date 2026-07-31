import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/theme.dart';

void main() {
  group('HostColorLabel.fromId', () {
    test('parses every value\'s own stored id back to itself', () {
      for (final value in HostColorLabel.values) {
        expect(HostColorLabel.fromId(value.name), value);
      }
    });

    test('null reads as no colour label', () {
      expect(HostColorLabel.fromId(null), isNull);
    });

    test('an unrecognised id reads as no colour label, not a default', () {
      expect(HostColorLabel.fromId('chartreuse'), isNull);
    });

    test('an empty string reads as no colour label', () {
      expect(HostColorLabel.fromId(''), isNull);
    });
  });

  group('AppTheme.hostColorFor', () {
    test('resolves every palette id to a distinct, non-null colour', () {
      final colors = {
        for (final value in HostColorLabel.values)
          value: AppTheme.hostColorFor(value.name),
      };
      for (final color in colors.values) {
        expect(color, isNotNull);
      }
      // Distinct swatches: two different labels reading as the same colour
      // would defeat the point of the palette.
      expect(colors.values.toSet(), hasLength(HostColorLabel.values.length));
    });

    test('null id resolves to null (no dot to draw)', () {
      expect(AppTheme.hostColorFor(null), isNull);
    });

    test('an unrecognised id resolves to null rather than a fallback colour',
        () {
      expect(AppTheme.hostColorFor('not-a-real-id'), isNull);
    });

    test('is stable across calls, matching Host.colorLabel round-tripped '
        'through JSON', () {
      const host = Host(
        id: 'x',
        label: '',
        hostname: 'example.com',
        port: 22,
        username: 'dev',
        authMethod: SshAuthMethod.password,
        colorLabel: HostColorLabel.purple,
      );
      final restored = Host.fromJson(host.toJson());
      expect(
        AppTheme.hostColorFor(restored.colorLabel?.name),
        AppTheme.hostColorFor(HostColorLabel.purple.name),
      );
    });
  });
}
