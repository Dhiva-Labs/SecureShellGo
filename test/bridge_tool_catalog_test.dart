import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/app_settings.dart';
import 'package:secure_shell_go/services/bridge/bridge_audit.dart';
import 'package:secure_shell_go/services/bridge/bridge_change_tools.dart';
import 'package:secure_shell_go/services/bridge/bridge_connections.dart';
import 'package:secure_shell_go/services/bridge/bridge_desktops.dart';
import 'package:secure_shell_go/services/bridge/bridge_jobs.dart';
import 'package:secure_shell_go/services/bridge/bridge_redactor.dart';
import 'package:secure_shell_go/services/bridge/bridge_tools.dart';

import 'support/bridge_temp_dir.dart';

/// What an MCP client reads from `tools/list`, for every tool the app
/// registers apart from the terminal ones (which need a session manager).
void main() {
  test('tool names are unique and every schema is an object schema', () async {
    final temp = await bridgeTempDir('ssgo-catalog');
    addTearDown(() => deleteTempDir(temp));
    final redactor = BridgeRedactor(scrub: (s) => s);
    final tools = BridgeTools(
      loadHosts: () async => [],
      settings: () => const AppSettings(bridgeEnabled: true),
      isAppLocked: () => false,
      connections: BridgeConnections(
        openTransport: (_) => throw StateError('not used'),
        credentialLookup: (_) async => null,
        dialer: (_, _) async => throw StateError('not used'),
      ),
      redactor: redactor,
      audit: BridgeAuditLog(scrub: (s) => s, directory: temp),
      changeTools: BridgeChangeTools(redactor: redactor).build(),
      modules: [
        BridgeJobs(
          registry: BridgeJobRegistry(file: File('${temp.path}/jobs.json')),
          redactor: redactor,
        ),
        BridgeDesktops(open: (_) => throw StateError('not used')),
      ],
    );
    final specs = tools.tools;
    final names = specs.map((s) => s.name).toList();
    expect(names.toSet(), hasLength(names.length), reason: '$names');
    expect(
      names,
      containsAll(['start_job', 'list_jobs', 'open_desktop', 'run_command']),
    );
    for (final s in specs) {
      final schema = s.inputSchema;
      expect(schema['type'], 'object', reason: s.name);
      expect(schema['properties'], isA<Map>(), reason: s.name);
      final required = schema['required'];
      if (required != null) {
        final props = (schema['properties']! as Map).keys;
        expect(required, isA<List>(), reason: s.name);
        for (final r in required as List) {
          expect(props, contains(r), reason: '${s.name} requires $r');
        }
      }
      expect(s.description.trim(), isNotEmpty, reason: s.name);
      expect(RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(s.name), isTrue);
    }
    expect(
      specs.firstWhere((s) => s.name == 'run_command').description,
      contains('start_job'),
    );
  });
}
