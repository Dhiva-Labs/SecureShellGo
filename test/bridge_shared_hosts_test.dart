import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/models/host_ai_access.dart';
import 'package:secure_shell_go/models/host_ai_edit.dart';
import 'package:secure_shell_go/screens/bridge_shared_hosts_screen.dart';
import 'package:secure_shell_go/services/host_store.dart';

import 'support/bridge_temp_dir.dart';
import 'support/settle.dart';
import 'support/tracked_stores.dart';

Host host(
  String id,
  String label, {
  HostAiAccess access = HostAiAccess.off,
  List<String> commands = const [],
  bool terminal = false,
}) => Host(
  id: id,
  label: label,
  hostname: '$id.example.com',
  port: 22,
  username: 'u',
  authMethod: SshAuthMethod.password,
  aiAccess: access,
  aiAllowedCommands: commands,
  aiTerminal: terminal,
);

void main() {
  group('HostAiEdit', () {
    final stored = host(
      'a',
      'A',
      access: HostAiAccess.askToChange,
      commands: ['uptime'],
      terminal: true,
    );

    test('an untouched edit changes nothing', () {
      final edit = HostAiEdit.of(stored);
      expect(edit.touched, isFalse);
      final other = stored.copyWith(
        aiAccess: HostAiAccess.readOnly,
        aiAllowedCommands: ['df'],
        aiTerminal: false,
      );
      final applied = edit.applyTo(other);
      expect(applied.aiAccess, HostAiAccess.readOnly);
      expect(applied.aiAllowedCommands, ['df']);
      expect(applied.aiTerminal, isFalse);
    });

    test('each setter writes only its own field', () {
      final other = host('a', 'A', access: HostAiAccess.readOnly, commands: ['x']);
      var e = HostAiEdit.of(stored)..setTerminal(false);
      var h = e.applyTo(other);
      expect(h.aiTerminal, isFalse);
      expect(h.aiAccess, HostAiAccess.readOnly);
      expect(h.aiAllowedCommands, ['x']);

      e = HostAiEdit.of(stored)..setCommands(['one', 'one', ' two ']);
      h = e.applyTo(other);
      expect(h.aiAllowedCommands, ['one', 'two'], reason: 'sanitised');
      expect(h.aiAccess, HostAiAccess.readOnly);
      expect(h.aiTerminal, isFalse);

      e = HostAiEdit.of(stored)..setChanges(true);
      h = e.applyTo(other);
      expect(h.aiAccess, HostAiAccess.askToChange);
      expect(h.aiAllowedCommands, ['x']);
    });

    test('changes off steps down to read-only, and never touches an off host',
        () {
      final e = HostAiEdit.of(stored)..setChanges(false);
      expect(e.applyTo(stored).aiAccess, HostAiAccess.readOnly);
      expect(e.applyTo(stored).aiAllowedCommands, ['uptime'],
          reason: 'kept, inert');
      final off = host('a', 'A');
      expect(
        (HostAiEdit.of(stored)..setChanges(true)).applyTo(off).aiAccess,
        HostAiAccess.off,
      );
    });

    test('share on keeps the stored level, or is read-only for an off host',
        () {
      final on = HostAiEdit.of(host('a', 'A'))..setShared(true);
      expect(on.applyTo(host('a', 'A')).aiAccess, HostAiAccess.readOnly);
      expect(on.applyTo(stored).aiAccess, HostAiAccess.askToChange);
      final off = HostAiEdit.of(stored)..setShared(false);
      final h = off.applyTo(stored);
      expect(h.aiAccess, HostAiAccess.off);
      expect(h.aiAllowedCommands, ['uptime']);
      expect(h.aiTerminal, isTrue);
    });
  });

  group('the shared-hosts checklist', () {
    late Directory dir;
    late HostStore store;
    late IoTracker io;

    setUp(() async {
      dir = await bridgeTempDir('shared_hosts_test');
      io = IoTracker();
      store = TrackedHostStore(io, file: File('${dir.path}/hosts.json'));
    });

    /// Until no store call is running and nothing is loading: a fixed number
    /// of event loop turns is too few on a slow CI runner.
    Future<void> settle(WidgetTester tester) => settleWhile(
      tester,
      () =>
          io.busy ||
          find
              .byWidgetPredicate((w) => w is ProgressIndicator)
              .evaluate()
              .isNotEmpty,
    );

    tearDown(() => deleteTempDir(dir));

    Future<void> seed(WidgetTester tester, List<Host> hosts) =>
        tester.runAsync(() async {
          for (final h in hosts) {
            await store.add(h);
          }
        });

    Future<void> pump(
      WidgetTester tester, {
      Size size = const Size(800, 1200),
      double textScale = 1,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = textScale;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(
        MaterialApp(home: BridgeSharedHostsScreen(hostStore: store)),
      );
      await settle(tester);
      await tester.pumpAndSettle();
    }

    Future<List<Host>> read(WidgetTester tester) async {
      late List<Host> hosts;
      await tester.runAsync(() async => hosts = await store.all());
      return hosts;
    }

    testWidgets('shows each shared host\'s level', (tester) async {
      await seed(tester, [
        host('a', 'Alpha', access: HostAiAccess.readOnly),
        host('b', 'Beta', access: HostAiAccess.askToChange),
        host('c', 'Gamma', access: HostAiAccess.askToChange, terminal: true),
        host('d', 'Delta'),
      ]);
      await pump(tester);
      expect(find.text('Read only'), findsOneWidget);
      expect(find.text('Can request changes'), findsOneWidget);
      expect(find.text('Can request changes and a terminal'), findsOneWidget);
      expect(find.byIcon(Icons.tune), findsNWidgets(3));
    });

    testWidgets('Save writes only the hosts whose tick changed',
        (tester) async {
      await seed(tester, [
        host('a', 'Alpha', access: HostAiAccess.readOnly),
        host('b', 'Beta'),
        host('c', 'Gamma'),
      ]);
      await pump(tester);
      // Elsewhere while the list is open: Alpha is un-shared, Gamma shared.
      await tester.runAsync(() async {
        await store.modify('a', (h) => h.copyWith(aiAccess: HostAiAccess.off));
        await store.modify(
          'c',
          (h) => h.copyWith(aiAccess: HostAiAccess.askToChange),
        );
      });
      // The user ticks Beta only.
      await tester.tap(find.text('Beta'));
      await tester.pump();
      await tester.runAsync(() => tester.tap(find.text('Save')));
      await settle(tester);
      await tester.pumpAndSettle();
      final byId = {for (final h in await read(tester)) h.id: h};
      expect(byId['b']!.aiAccess, HostAiAccess.readOnly);
      expect(byId['a']!.aiAccess, HostAiAccess.off,
          reason: 'untouched tick: the open list must not re-share it');
      expect(byId['c']!.aiAccess, HostAiAccess.askToChange,
          reason: 'untouched tick: not lowered or rewritten');
    });

    testWidgets('un-ticking leaves the allowed commands stored', (tester) async {
      await seed(tester, [
        host('a', 'Alpha',
            access: HostAiAccess.askToChange, commands: ['uptime'], terminal: true),
      ]);
      await pump(tester);
      await tester.tap(find.text('Alpha'));
      await tester.pump();
      await tester.runAsync(() => tester.tap(find.text('Save')));
      await settle(tester);
      final a = (await read(tester)).single;
      expect(a.aiAccess, HostAiAccess.off);
      expect(a.aiAllowedCommands, ['uptime']);
      expect(a.aiTerminal, isTrue);
    });

    testWidgets('the per-host sheet writes only what was touched',
        (tester) async {
      await seed(tester, [
        host('a', 'Alpha', access: HostAiAccess.readOnly, commands: ['uptime']),
      ]);
      await pump(tester);
      await tester.tap(find.byIcon(Icons.tune));
      await tester.pumpAndSettle();
      expect(find.text('AI assistant: Alpha'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('ai-changes')));
      await tester.pumpAndSettle();
      expect(find.text('• uptime'), findsOneWidget);
      await tester.tap(find.text('Allow requests'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('ai-terminal')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Allow terminal'));
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => tester.tap(
          find.descendant(
            of: find.byType(BottomSheet),
            matching: find.text('Save'),
          ),
        ),
      );
      await settle(tester);
      await tester.pumpAndSettle();
      final a = (await read(tester)).single;
      expect(a.aiAccess, HostAiAccess.askToChange);
      expect(a.aiTerminal, isTrue);
      expect(a.aiAllowedCommands, ['uptime']);
      expect(find.text('Can request changes and a terminal'), findsOneWidget);
    });

    testWidgets('cancelling the sheet writes nothing', (tester) async {
      await seed(tester, [host('a', 'Alpha', access: HostAiAccess.readOnly)]);
      await pump(tester);
      await tester.tap(find.byIcon(Icons.tune));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('ai-changes')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Allow requests'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect((await read(tester)).single.aiAccess, HostAiAccess.readOnly);
    });

    for (final (size, scale) in [
      (const Size(320, 568), 1.5),
      (const Size(1920, 1080), 1.0),
    ]) {
      testWidgets('fits ${size.width.toInt()} wide', (tester) async {
        await seed(tester, [
          host('a', 'A host with a rather long label ${'x' * 40}',
              access: HostAiAccess.askToChange, terminal: true),
        ]);
        await pump(tester, size: size, textScale: scale);
        expect(tester.takeException(), isNull);
        await tester.scrollUntilVisible(find.byIcon(Icons.tune), 100);
        await tester.tap(find.byIcon(Icons.tune));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  });
}
