import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/remote_entry.dart';
import 'package:secure_shell_go/models/snippet.dart';
import 'package:secure_shell_go/screens/file_browser_pane.dart';
import 'package:secure_shell_go/services/bookmark_store.dart';
import 'package:secure_shell_go/services/session_controller.dart';
import 'package:secure_shell_go/services/settings_store.dart';
import 'package:secure_shell_go/services/snippet_store.dart';
import 'package:secure_shell_go/services/transfer_hub.dart';
import 'package:secure_shell_go/services/transfer_queue.dart';
import 'package:secure_shell_go/theme.dart';
import 'package:secure_shell_go/widgets/snippet_picker.dart';
import 'package:secure_shell_go/widgets/transfer_hub_panel.dart';
import 'package:secure_shell_go/widgets/transfer_panel.dart';

import 'file_browser_actions_test.dart'
    show ActionsFs, FakeTransport, NoopTimer, StubStorage;

/// [ActionsFs] whose listings can be held back, one folder at a time, so a
/// test can look at the browser while a folder is still on its way.
class GatedFs extends ActionsFs {
  final Map<String, Completer<void>> gates = {};

  @override
  Future<List<RemoteEntry>> list(String path) async {
    final gate = gates[path];
    if (gate != null) await gate.future;
    return super.list(path);
  }
}

/// A snippet store with a fixed list and no file behind it.
class FixedSnippets extends SnippetStore {
  FixedSnippets(this.items);

  final List<Snippet> items;

  @override
  Future<List<Snippet>> all() async => items;
}

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('ux_files');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  SessionController sessionOn(ActionsFs fs) => SessionController(
        connection: FakeTransport(),
        storage: StubStorage(),
        openFileSystem: () async => fs,
        keepaliveScheduler: (_, _) => NoopTimer(),
      );

  /// See `file_browser_jump_test.dart`: lets the bookmark store's real file
  /// read finish under the widget test's fake clock.
  Future<void> settleIo(WidgetTester tester, {int rounds = 6}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
  }

  Widget browserApp(SessionController session) => MaterialApp(
        theme: AppTheme.dark,
        home: FileBrowserPane(
          session: session,
          settingsStore: SettingsStore(file: File('${temp.path}/settings.json')),
          bookmarkStore: BookmarkStore(file: File('${temp.path}/bm.json')),
        ),
      );

  Future<void> pumpBrowser(
    WidgetTester tester,
    SessionController session,
  ) async {
    await tester.pumpWidget(browserApp(session));
    await tester.pumpAndSettle();
    await settleIo(tester);
  }

  /// A view tall enough that the action sheet builds every row, so its rows
  /// can be read off and compared with the menu's.
  void tallView(WidgetTester tester) {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Finder menuItems() => find.byWidgetPredicate((w) => w is PopupMenuItem);

  List<String> menuLabels(WidgetTester tester) => tester
      .widgetList<Text>(
        find.descendant(of: menuItems(), matching: find.byType(Text)),
      )
      .map((text) => text.data!)
      .toList();

  /// The sheet's action rows, under the row naming the file.
  List<String> sheetLabels(WidgetTester tester) => tester
      .widgetList<ListTile>(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.byType(ListTile),
        ),
      )
      .skip(1)
      .map((tile) => (tile.title! as Text).data!)
      .toList();

  Future<void> rightClick(WidgetTester tester, Offset at) async {
    await tester.tapAt(
      at,
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
  }

  // ------------------------------------------------- right-click on a row

  group('a row\'s actions', () {
    late ActionsFs fs;
    late SessionController session;

    setUp(() {
      fs = ActionsFs();
      session = sessionOn(fs);
    });

    tearDown(() => session.dispose());

    testWidgets('a right-click opens a menu at the pointer, not the sheet',
        (tester) async {
      await pumpBrowser(tester, session);
      // On the name itself, nearer the left edge than the right, so the menu
      // grows rightwards from the pointer.
      final at = tester.getTopLeft(find.text('todo.txt')) + const Offset(20, 8);
      await rightClick(tester, at);

      expect(find.byType(BottomSheet), findsNothing);
      expect(menuItems(), findsWidgets);
      expect(find.text('Rename…'), findsOneWidget);
      // At the pointer, not risen from the bottom of the window: growing
      // rightwards from it, and level with it — the menu is moved up as far
      // as it must be to stay on screen, and no further.
      final first = tester.getRect(menuItems().first);
      final last = tester.getRect(menuItems().last);
      expect((first.left - at.dx).abs(), lessThan(8));
      expect(first.top, lessThanOrEqualTo(at.dy));
      expect(last.bottom, greaterThanOrEqualTo(at.dy));
    });

    testWidgets('a pick from the menu runs that action', (tester) async {
      await pumpBrowser(tester, session);
      await rightClick(tester, tester.getCenter(find.text('todo.txt')));

      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(menuItems(), findsNothing);
      expect(find.text('Delete "todo.txt"?'), findsOneWidget);
    });

    testWidgets('a long-press still opens the sheet', (tester) async {
      await pumpBrowser(tester, session);
      await tester.longPress(find.text('todo.txt'));
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsOneWidget);
      expect(menuItems(), findsNothing);
    });

    testWidgets('the menu and the sheet offer the same actions, in order',
        (tester) async {
      tallView(tester);
      await pumpBrowser(tester, session);

      for (final name in ['todo.txt', 'site', 'www']) {
        await rightClick(tester, tester.getCenter(find.text(name)));
        final inMenu = menuLabels(tester);
        Navigator.of(tester.element(menuItems().first)).pop();
        await tester.pumpAndSettle();

        await tester.longPress(find.text(name));
        await tester.pumpAndSettle();
        final inSheet = sheetLabels(tester);
        Navigator.of(tester.element(find.byType(BottomSheet))).pop();
        await tester.pumpAndSettle();

        expect(inMenu, isNotEmpty, reason: name);
        expect(inMenu, inSheet, reason: name);
      }
    });
  });

  // ------------------------------------------------- changing folders

  group('changing folders', () {
    late GatedFs fs;
    late SessionController session;

    setUp(() {
      fs = GatedFs();
      session = sessionOn(fs);
    });

    tearDown(() async {
      for (final gate in fs.gates.values) {
        if (!gate.isCompleted) gate.complete();
      }
      await session.dispose();
    });

    testWidgets('the first listing shows the full spinner', (tester) async {
      final home = fs.gates['/home/dev'] = Completer<void>();
      await tester.pumpWidget(browserApp(session));
      await tester.pump();
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      home.complete();
      await tester.pumpAndSettle();
      await settleIo(tester);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('todo.txt'), findsOneWidget);
    });

    testWidgets('the folder being left stays up under the thin progress line',
        (tester) async {
      await pumpBrowser(tester, session);
      final notes = fs.gates['/home/dev/notes'] = Completer<void>();

      await tester.tap(find.text('notes'));
      await tester.pump();
      await tester.pump();

      expect(find.text('todo.txt'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);

      notes.complete();
      await tester.pumpAndSettle();

      expect(find.text('a.txt'), findsOneWidget);
      expect(find.text('todo.txt'), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsNothing);
    });

    testWidgets('a slow folder does not land over one opened after it',
        (tester) async {
      await pumpBrowser(tester, session);
      final notes = fs.gates['/home/dev/notes'] = Completer<void>();

      await tester.tap(find.text('notes'));
      await tester.pump();
      // Still on screen, so still clickable.
      await tester.tap(find.text('site'));
      await tester.pump();
      await tester.pump();

      expect(find.text('index.html'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);

      notes.complete();
      await tester.pumpAndSettle();

      expect(find.text('index.html'), findsOneWidget);
      expect(find.text('a.txt'), findsNothing);
    });

    testWidgets('a folder that will not open says why, over the old listing',
        (tester) async {
      fs.protected.add('/home/dev/notes');
      await pumpBrowser(tester, session);

      await tester.tap(find.text('notes'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Permission denied'), findsOneWidget);
      expect(find.text('todo.txt'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
    });
  });

  // ------------------------------------------------- cancel all

  group('Cancel all', () {
    late Completer<void> gate;

    setUp(() => gate = Completer<void>());

    tearDown(() {
      if (!gate.isCompleted) gate.complete();
    });

    TransferQueue heldQueue() =>
        TransferQueue(executor: (task, handle) async => gate.future);

    void enqueue(TransferQueue queue, String name) => queue.enqueueDownload(
          remotePath: '/srv/$name',
          name: name,
          // A known size, so the row's progress bar is determinate and the
          // test can settle.
          totalBytes: 100,
        );

    Future<void> open(
      WidgetTester tester,
      Future<void> Function(BuildContext context) show,
    ) async {
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => unawaited(show(context)),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    Finder inDialog(Finder finder) =>
        find.descendant(of: find.byType(AlertDialog), matching: finder);

    bool allCancelled(TransferQueue queue) =>
        queue.tasks.every((t) => t.status == TransferStatus.cancelled);

    testWidgets('asks first when it would stop two or more', (tester) async {
      final queue = heldQueue();
      enqueue(queue, 'a.iso');
      enqueue(queue, 'b.iso');
      await open(tester, (context) => showTransfersSheet(context, queue));

      await tester.tap(find.text('Cancel all'));
      await tester.pumpAndSettle();

      expect(find.text('Cancel 2 transfers?'), findsOneWidget);
      expect(
        find.text("A cancelled transfer stops where it is and can't be "
            'resumed.'),
        findsOneWidget,
      );

      await tester.tap(inDialog(find.text('Keep going')));
      await tester.pumpAndSettle();
      expect(queue.tasks.every((t) => t.status.isActive), isTrue);

      await tester.tap(find.text('Cancel all'));
      await tester.pumpAndSettle();
      await tester.tap(inDialog(find.text('Cancel all')));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(allCancelled(queue), isTrue);
    });

    testWidgets('stops a single transfer without asking', (tester) async {
      final queue = heldQueue();
      enqueue(queue, 'a.iso');
      await open(tester, (context) => showTransfersSheet(context, queue));

      await tester.tap(find.text('Cancel all'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(allCancelled(queue), isTrue);
    });

    testWidgets('the all-sessions panel asks the same', (tester) async {
      final sessionsChanged = StreamController<void>.broadcast();
      addTearDown(sessionsChanged.close);
      final alpha = heldQueue();
      final beta = heldQueue();
      final hub = TransferHub(
        sessionsChanged: sessionsChanged.stream,
        sources: () => [
          TransferQueueSource(
              sessionId: 's1', sessionLabel: 'Box A', queue: alpha),
          TransferQueueSource(
              sessionId: 's2', sessionLabel: 'Box B', queue: beta),
        ],
      );
      addTearDown(hub.dispose);
      enqueue(alpha, 'a.iso');
      enqueue(beta, 'b.iso');
      await open(tester, (context) => showTransferHubSheet(context, hub));

      await tester.tap(find.text('Cancel all'));
      await tester.pumpAndSettle();
      expect(find.text('Cancel 2 transfers?'), findsOneWidget);

      await tester.tap(inDialog(find.text('Keep going')));
      await tester.pumpAndSettle();
      expect(allCancelled(alpha) || allCancelled(beta), isFalse);

      await tester.tap(find.text('Cancel all'));
      await tester.pumpAndSettle();
      await tester.tap(inDialog(find.text('Cancel all')));
      await tester.pumpAndSettle();

      expect(allCancelled(alpha), isTrue);
      expect(allCancelled(beta), isTrue);
    });
  });

  // ------------------------------------------------- snippet picker

  group('the snippet picker', () {
    late SessionController session;
    late List<String> sent;

    setUp(() {
      session = sessionOn(ActionsFs());
      sent = [];
      // Straight off the terminal, before anything would go to a shell.
      session.terminal.onOutput = sent.add;
    });

    tearDown(() => session.dispose());

    final snippets = FixedSnippets(const [
      Snippet(id: '1', name: 'Tail log', command: 'tail -f /var/log/app.log'),
      Snippet(id: '2', name: 'Disk usage', command: 'df -h'),
    ]);

    Future<void> openPicker(WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => unawaited(showSnippetPicker(
                  context,
                  snippetStore: snippets,
                  session: session,
                )),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('Enter in the search box runs the only match',
        (tester) async {
      await openPicker(tester);
      await tester.enterText(find.byType(TextField), 'disk');
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await tester.pumpAndSettle();

      expect(sent, ['df -h\n']);
      expect(find.byType(TextField), findsNothing,
          reason: 'the picker closes once the snippet is sent');
    });

    testWidgets('Enter runs the top one of several matches', (tester) async {
      await openPicker(tester);
      await tester.enterText(find.byType(TextField), 'a');
      await tester.pump();
      expect(find.text('Tail log'), findsOneWidget);
      expect(find.text('Disk usage'), findsOneWidget);

      await tester.testTextInput.receiveAction(TextInputAction.go);
      await tester.pumpAndSettle();

      expect(sent, ['tail -f /var/log/app.log\n']);
    });

    testWidgets('Enter with nothing matching sends nothing', (tester) async {
      await openPicker(tester);
      await tester.enterText(find.byType(TextField), 'reboot');
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await tester.pumpAndSettle();

      expect(sent, isEmpty);
      expect(find.byType(TextField), findsOneWidget);
    });
  });
}
