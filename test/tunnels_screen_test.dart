import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/models/tunnel_profile.dart';
import 'package:secure_shell_go/screens/tunnels_screen.dart';
import 'package:secure_shell_go/services/host_store.dart';
import 'package:secure_shell_go/services/tunnel_runtime.dart';
import 'package:secure_shell_go/services/tunnel_store.dart';

/// Both stores are warmed inside [WidgetTester.runAsync] before the screen is
/// built. Once loaded they answer from memory, so everything the widgets
/// await afterwards resolves in microtasks — which is what a `testWidgets`
/// fake clock can actually run.
void main() {
  late Directory tempDir;
  late TunnelStore tunnelStore;
  late HostStore hostStore;
  late TunnelRuntime runtime;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('tunnels_screen_test');
    tunnelStore = TunnelStore(file: File('${tempDir.path}/tunnels.json'));
    hostStore = HostStore(file: File('${tempDir.path}/hosts.json'));
    runtime = TunnelRuntime(
      profiles: tunnelStore,
      support: TunnelSupport(
        lookupHost: hostStore.get,
        loadCredentials: (id) async => null,
      ),
    );
  });

  tearDown(() async {
    await runtime.dispose();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  const savedHost = Host(
    id: 'host-1',
    label: 'Bastion',
    hostname: 'bastion.example.com',
    port: 22,
    username: 'ops',
    authMethod: SshAuthMethod.password,
  );

  const healthy = TunnelProfile(
    id: 'tunnel-1',
    name: 'Postgres',
    hostId: 'host-1',
    type: TunnelType.local,
    localPort: 15432,
    remoteHost: 'db.internal',
    remotePort: 5432,
  );

  const orphan = TunnelProfile(
    id: 'tunnel-2',
    name: 'Old proxy',
    hostId: 'host-gone',
    type: TunnelType.dynamic,
    localPort: 1080,
  );

  Future<void> show(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: TunnelsScreen(tunnels: runtime, hostStore: hostStore),
      ),
    );
    await tester.pump();
  }

  testWidgets('lists tunnels under the host that carries them',
      (tester) async {
    await tester.runAsync(() async {
      await hostStore.add(savedHost);
      await tunnelStore.add(healthy);
    });

    await show(tester);

    expect(find.text('BASTION'), findsOneWidget);
    expect(find.text('Postgres'), findsOneWidget);
    expect(find.text('127.0.0.1:15432 → db.internal:5432'), findsOneWidget);
    expect(find.text('Stopped'), findsOneWidget);
    // The type badge, the way ssh spells it.
    expect(find.text('L'), findsOneWidget);
  });

  testWidgets('a tunnel whose host was deleted renders broken, not crashed',
      (tester) async {
    await tester.runAsync(() async {
      await hostStore.add(savedHost);
      await tunnelStore.add(healthy);
      await tunnelStore.add(orphan);
    });

    await show(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('Old proxy'), findsOneWidget);
    expect(find.text('MISSING HOST'), findsOneWidget);
    expect(
      find.textContaining('The saved host this tunnel rides on has been '
          'deleted'),
      findsOneWidget,
    );

    // Its switch is dead: there is nothing for it to start.
    final switches = tester.widgetList<Switch>(find.byType(Switch)).toList();
    expect(switches, hasLength(2));
    expect(switches.first.onChanged, isNotNull);
    expect(switches.last.onChanged, isNull);
  });

  testWidgets('a tunnel with nothing to ride on fails inline, on its own row',
      (tester) async {
    await tester.runAsync(() async {
      await hostStore.add(savedHost);
      await tunnelStore.add(healthy);
    });
    await show(tester);

    await tester.tap(find.byType(Switch));
    await tester.pump();
    await tester.pump();

    expect(
      find.textContaining('no open session on "Bastion"'),
      findsOneWidget,
    );
    expect(runtime.statusFor('tunnel-1').state, TunnelState.error);
    // The row is still there and still offers its switch.
    expect(find.text('Postgres'), findsOneWidget);
  });

  testWidgets('says so when there is nothing saved yet', (tester) async {
    await tester.runAsync(() async {
      await tunnelStore.ensureLoaded();
      await hostStore.ensureLoaded();
    });

    await show(tester);

    expect(find.text('No tunnels yet'), findsOneWidget);
  });
}
