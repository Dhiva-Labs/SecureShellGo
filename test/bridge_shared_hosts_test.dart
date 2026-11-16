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

    test('the share and change switches never raise a host to full control',
        () {
      final asking = host('a', 'A', access: HostAiAccess.askToChange);
      final full = asking.copyWith(aiAccess: HostAiAccess.fullControl);
      for (final e in [
        HostAiEdit.of(asking)..setShared(true),
        HostAiEdit.of(asking)..setChanges(true),
        HostAiEdit.of(asking)
          ..setShared(true)
          ..setChanges(true),
      ]) {
        expect(e.applyTo(asking).aiAccess, HostAiAccess.askToChange);
      }
      // A full-control host keeps it through "share on" and "changes on",
      // and "changes off" steps it down to read-only.
      expect(
        (HostAiEdit.of(full)..setChanges(true)).applyTo(full).aiAccess,
        HostAiAccess.fullControl,
      );
      expect(
        (HostAiEdit.of(full)..setShared(true)).applyTo(full).aiAccess,
        HostAiAccess.fullControl,
      );
      expect(
        (HostAiEdit.of(full)..setChanges(false)).applyTo(full).aiAccess,
        HostAiAccess.readOnly,
      );
      expect(HostAiEdit.of(full).changes, isTrue);
    });

    test('setLevel sets the level outright and wins over the switches', () {
      final e = HostAiEdit.of(stored)
        ..setChanges(false)
        ..setLevel(HostAiAccess.fullControl);
      expect(e.touched, isTrue);
      expect(e.applyTo(stored).aiAccess, HostAiAccess.fullControl);
      final down = HostAiEdit.of(stored)..setLevel(HostAiAccess.off);
      final h = down.applyTo(stored);
      expect(h.aiAccess, HostAiAccess.off);
      expect(h.aiAllowedCommands, ['uptime'], reason: 'kept, inert');
      expect(h.aiTerminal, isTrue);
    });

    test('the desktop switch writes only itself', () {
      final other = host('a', 'A', access: HostAiAccess.readOnly);
      final e = HostAiEdit.of(stored)..setDesktop(true);
      expect(e.touched, isTrue);
      final h = e.applyTo(other);
      expect(h.aiDesktop, isTrue);
      expect(h.aiAccess, HostAiAccess.readOnly);
      expect(h.aiTerminal, isFalse);
      // Untouched, the stored value wins.
      final kept = HostAiEdit.of(stored).applyTo(other.copyWith(aiDesktop: true));
      expect(kept.aiDesktop, isTrue);
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

    Finder rowOf(String id) => find.byKey(ValueKey('shared-host-$id'));
    Finder tickOf(String id) =>
        find.descendant(of: rowOf(id), matching: find.byType(Checkbox));
    Finder chipOf(String id) =>
        find.byKey(ValueKey('ai-chip-$id'));
    String chipText(WidgetTester tester, String id) => tester
        .widget<Text>(
            find.descendant(of: chipOf(id), matching: find.byType(Text)))
        .data!;

    /// Picks a level in the open sheet; [confirm] answers its confirmation.
    Future<void> pick(
      WidgetTester tester,
      HostAiAccess level, {
      String? confirm,
    }) async {
      final tile = find.byKey(ValueKey('ai-level-${level.name}'));
      await tester.ensureVisible(tile);
      await tester.pumpAndSettle();
      await tester.tap(tile);
      await tester.pumpAndSettle();
      if (confirm != null) {
        await tester.tap(find.text(confirm));
        await tester.pumpAndSettle();
      }
    }

    Future<void> saveSheet(WidgetTester tester) async {
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
    }

    testWidgets('shows each host\'s level as a chip', (tester) async {
      await seed(tester, [
        host('a', 'Alpha', access: HostAiAccess.readOnly),
        host('b', 'Beta', access: HostAiAccess.askToChange),
        host('c', 'Gamma', access: HostAiAccess.askToChange, terminal: true),
        host('d', 'Delta'),
        host('e', 'Epsilon', access: HostAiAccess.fullControl),
      ]);
      await pump(tester);
      expect(chipText(tester, 'a'), 'Read only');
      expect(chipText(tester, 'b'), 'Asks first');
      expect(chipText(tester, 'c'), 'Asks first');
      expect(chipText(tester, 'd'), 'Off');
      expect(chipText(tester, 'e'), 'Full control');
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget,
          reason: 'only full control is drawn differently');
    });

    testWidgets('a full-control host shows as full control, and unticking '
        'it turns it off', (tester) async {
      await seed(tester, [
        host('a', 'Alpha', access: HostAiAccess.fullControl),
      ]);
      await pump(tester);
      expect(chipText(tester, 'a'), 'Full control');
      await tester.tap(find.byType(Checkbox));
      await tester.pump();
      expect(chipText(tester, 'a'), 'Off');
      await tester.runAsync(() => tester.tap(find.text('Save')));
      await settle(tester);
      final hosts = await read(tester);
      expect(hosts.single.aiAccess, HostAiAccess.off);
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
      await tester.tap(tickOf('b'));
      await tester.pump();
      expect(chipText(tester, 'b'), 'Read only');
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
      await tester.tap(tickOf('a'));
      await tester.pump();
      await tester.runAsync(() => tester.tap(find.text('Save')));
      await settle(tester);
      final a = (await read(tester)).single;
      expect(a.aiAccess, HostAiAccess.off);
      expect(a.aiAllowedCommands, ['uptime']);
      expect(a.aiTerminal, isTrue);
    });

    testWidgets('tapping a row opens the sheet with the level picker',
        (tester) async {
      await seed(tester, [host('a', 'Alpha', access: HostAiAccess.readOnly)]);
      await pump(tester);
      await tester.tap(find.text('Alpha'));
      await tester.pumpAndSettle();
      expect(find.text('AI assistant: Alpha'), findsOneWidget);
      for (final level in HostAiAccess.values) {
        expect(find.byKey(ValueKey('ai-level-${level.name}')), findsOneWidget);
      }
      expect(find.text('Not saved yet'), findsNothing,
          reason: 'the sheet has its own Save and says so instead');
    });

    testWidgets('Off and Read only in the sheet are the old tick',
        (tester) async {
      await seed(tester, [host('a', 'Alpha')]);
      await pump(tester);
      expect(tester.widget<Checkbox>(tickOf('a')).value, isFalse);
      await tester.tap(find.text('Alpha'));
      await tester.pumpAndSettle();
      await pick(tester, HostAiAccess.readOnly);
      expect(find.byType(AlertDialog), findsNothing);
      await saveSheet(tester);
      expect((await read(tester)).single.aiAccess, HostAiAccess.readOnly);
      expect(chipText(tester, 'a'), 'Read only');
      expect(tester.widget<Checkbox>(tickOf('a')).value, isTrue);

      await tester.tap(find.text('Alpha'));
      await tester.pumpAndSettle();
      await pick(tester, HostAiAccess.off);
      await saveSheet(tester);
      expect((await read(tester)).single.aiAccess, HostAiAccess.off);
      expect(chipText(tester, 'a'), 'Off');
      expect(tester.widget<Checkbox>(tickOf('a')).value, isFalse);
    });

    testWidgets('the sheet asks before full control, and cancel leaves the '
        'level', (tester) async {
      await seed(tester, [host('a', 'Alpha', access: HostAiAccess.readOnly)]);
      await pump(tester);
      await tester.tap(find.text('Alpha'));
      await tester.pumpAndSettle();
      await pick(tester, HostAiAccess.fullControl);
      expect(find.text('Give full control of this server?'), findsOneWidget);
      await tester.tap(find.descendant(
          of: find.byType(AlertDialog), matching: find.text('Cancel')));
      await tester.pumpAndSettle();
      await saveSheet(tester);
      expect((await read(tester)).single.aiAccess, HostAiAccess.readOnly);

      await tester.tap(find.text('Alpha'));
      await tester.pumpAndSettle();
      await pick(tester, HostAiAccess.fullControl, confirm: 'Give full control');
      await saveSheet(tester);
      expect((await read(tester)).single.aiAccess, HostAiAccess.fullControl);
      expect(chipText(tester, 'a'), 'Full control');
    });

    testWidgets('the per-host sheet writes only what was touched',
        (tester) async {
      await seed(tester, [
        host('a', 'Alpha', access: HostAiAccess.readOnly, commands: ['uptime']),
      ]);
      await pump(tester);
      await tester.tap(find.text('Alpha'));
      await tester.pumpAndSettle();
      expect(find.text('AI assistant: Alpha'), findsOneWidget);
      await pick(tester, HostAiAccess.askToChange);
      expect(find.text('• uptime'), findsOneWidget);
      await tester.tap(find.text('Allow requests'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('ai-terminal')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Allow terminal'));
      await tester.pumpAndSettle();
      await saveSheet(tester);
      final a = (await read(tester)).single;
      expect(a.aiAccess, HostAiAccess.askToChange);
      expect(a.aiTerminal, isTrue);
      expect(a.aiDesktop, isFalse);
      expect(a.aiAllowedCommands, ['uptime']);
      expect(chipText(tester, 'a'), 'Asks first');
    });

    testWidgets('cancelling the sheet writes nothing', (tester) async {
      await seed(tester, [host('a', 'Alpha', access: HostAiAccess.readOnly)]);
      await pump(tester);
      await tester.tap(find.text('Alpha'));
      await tester.pumpAndSettle();
      await pick(tester, HostAiAccess.askToChange, confirm: 'Allow requests');
      await tester.tap(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.text('Cancel'),
        ),
      );
      await tester.pumpAndSettle();
      expect((await read(tester)).single.aiAccess, HostAiAccess.readOnly);
      expect(chipText(tester, 'a'), 'Read only');
    });

    for (final (size, scale) in [
      (const Size(320, 568), 1.5),
      (const Size(360, 740), 1.0),
      (const Size(1920, 1080), 1.0),
    ]) {
      testWidgets('fits ${size.width.toInt()} wide', (tester) async {
        await seed(tester, [
          host('a', 'A host with a rather long label ${'x' * 40}',
              access: HostAiAccess.fullControl, terminal: true),
        ]);
        await pump(tester, size: size, textScale: scale);
        expect(tester.takeException(), isNull);
        await tester.scrollUntilVisible(rowOf('a'), 100);
        await tester.ensureVisible(rowOf('a'));
        await tester.pumpAndSettle();
        await tester.tap(rowOf('a'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await pick(tester, HostAiAccess.readOnly);
        await pick(tester, HostAiAccess.askToChange);
        expect(find.byType(AlertDialog), findsOneWidget);
        await tester.tap(find.descendant(
            of: find.byType(AlertDialog), matching: find.text('Cancel')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  });
}
