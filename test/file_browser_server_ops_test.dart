import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/screens/file_browser_pane.dart';
import 'package:secure_shell_go/services/bookmark_store.dart';
import 'package:secure_shell_go/services/device_storage.dart';
import 'package:secure_shell_go/services/remote_file_ops.dart';
import 'package:secure_shell_go/services/server_side_job.dart';
import 'package:secure_shell_go/services/session_controller.dart';
import 'package:secure_shell_go/services/settings_store.dart';
import 'package:secure_shell_go/services/ssh_service.dart';
import 'package:secure_shell_go/theme.dart';

import 'fake_exec_session.dart';
import 'memory_fs.dart';
import 'support/fake_transport.dart';

const _gnuProbe = 'tool tar gnu\ntool gzip gnu\ntool xz other\ntool zip infozip\n'
    'tool unzip infozip\ntool find gnu\ntool grep gnu\ntool cp gnu\n'
    'tool chown gnu\ntar-gzip\ntar-xz\nend\n';

const _busyboxProbe = 'tool tar busybox\ntool gzip busybox\ntool unzip busybox\n'
    'tool find busybox\ntool grep busybox\ntool cp busybox\n'
    'tool chown busybox\ntar-gzip\nend\n';

/// The script a launch carried: its last argument, unquoted.
String _scriptOf(String launch) {
  const marker = ' ssg-op ';
  final quoted = launch.substring(launch.indexOf(marker) + marker.length);
  expect(quoted.startsWith("'") && quoted.endsWith("'"), isTrue);
  return quoted.substring(1, quoted.length - 1).replaceAll("'\\''", "'");
}

/// A server for the pane: answers the probe, runs every job at once with
/// [jobExit], and keeps what it was asked.
class _Server {
  String probe = _gnuProbe;
  int jobExit = 0;
  String jobLog = '';
  String owner = 'drwxr-xr-x 2 dev staff 4096 Oct 21 10:00 /home/dev/site\n';
  String searchOutput = '';

  late final FakeExecTransport transport = FakeExecTransport(
    host: FakeTransportBase.hostFor(label: 'demo', hostname: 'demo.example.com'),
    respond: (command) {
      if (command.contains('for t in tar gzip')) {
        return FakeExecSession(stdout: probe);
      }
      if (command.contains(' ssg-op ')) {
        return FakeExecSession(
          stdout: '${ServerSideJob.doneMarker} $jobExit\n---\n$jobLog\n',
        );
      }
      if (command.startsWith('ls -ld')) return FakeExecSession(stdout: owner);
      if (command.contains('find ')) {
        return FakeExecSession(stdout: searchOutput, exits: true);
      }
      return FakeExecSession();
    },
  );

  List<String> get launches =>
      transport.commands.where((c) => c.contains(' ssg-op ')).toList();
}

MemoryFs _tree() {
  final fs = MemoryFs();
  fs.directories.addAll([
    '/',
    '/home',
    '/home/dev',
    '/home/dev/site',
    "/home/dev/it's dir",
    '/home/dev/logs',
  ]);
  fs.files.addAll({
    '/home/dev/notes.md': 4,
    '/home/dev/site.tar.gz': 100,
    '/home/dev/site/index.html': 10,
    '/home/dev/logs/app.log': 50,
  });
  return fs;
}

void main() {
  late Directory temp;
  late _Server server;
  late SessionController session;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('browser_server_ops');
    server = _Server();
  });

  tearDown(() async {
    await session.dispose();
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Future<void> settleIo(WidgetTester tester, {int rounds = 6}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
  }

  Future<void> pumpBrowser(
    WidgetTester tester, {
    SessionTransport? connection,
  }) async {
    final fs = _tree();
    session = SessionController(
      connection: connection ?? server.transport,
      storage: _StubStorage(),
      openFileSystem: () async => fs,
      keepaliveScheduler: (_, _) => _NoopTimer(),
    );
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark,
      home: FileBrowserPane(
        session: session,
        settingsStore: SettingsStore(file: File('${temp.path}/settings.json')),
        bookmarkStore: BookmarkStore(file: File('${temp.path}/bm.json')),
      ),
    ));
    await tester.pumpAndSettle();
    await settleIo(tester);
  }

  Future<void> openSheet(WidgetTester tester, String name) async {
    await tester.longPress(find.text(name));
    await tester.pumpAndSettle();
  }

  Future<void> tapSheetRow(WidgetTester tester, String label) async {
    final row = find.widgetWithText(ListTile, label);
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pumpAndSettle();
  }

  Finder inDialog(Finder finder) =>
      find.descendant(of: find.byType(AlertDialog), matching: finder);

  Future<void> tapDialogButton(WidgetTester tester, String label) async {
    await tester.tap(find.ancestor(
      of: inDialog(find.text(label)),
      matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
    ));
    await tester.pumpAndSettle();
    await settleIo(tester);
  }

  testWidgets('only what the server can do is offered', (tester) async {
    await pumpBrowser(tester);
    await openSheet(tester, 'site.tar.gz');
    for (final row in ['Extract…', 'Compress…', 'Duplicate', 'Change owner…']) {
      expect(find.widgetWithText(ListTile, row), findsOneWidget, reason: row);
    }
    expect(find.text('To tar.gz or zip, on the server'), findsOneWidget);
    expect(find.text('As "site copy.tar.gz"'), findsOneWidget);
  });

  testWidgets('a server with no shell gets none of them', (tester) async {
    await pumpBrowser(
      tester,
      connection: FakeTransportBase(host: FakeTransportBase.hostFor()),
    );
    await openSheet(tester, 'site.tar.gz');
    for (final row in ['Extract…', 'Compress…', 'Duplicate', 'Change owner…']) {
      expect(find.widgetWithText(ListTile, row), findsNothing, reason: row);
    }
    expect(find.byTooltip('Search on the server'), findsNothing);
  });

  testWidgets('compress quotes every name and reports the archive',
      (tester) async {
    await pumpBrowser(tester);
    await openSheet(tester, "it's dir");
    await tapSheetRow(tester, 'Compress…');
    expect(inDialog(find.byType(SegmentedButton<ArchiveFormat>)), findsOneWidget);
    await tapDialogButton(tester, 'Compress');

    final script = _scriptOf(server.launches.single);
    final stamp = RegExp(r'ssg-part-([0-9a-f]+)').firstMatch(script)![1]!;
    final part = ".it's dir.tar.gz.ssg-part-$stamp";
    expect(
      script,
      RemoteFileCommands.compress(
        directory: '/home/dev',
        names: ["it's dir"],
        archiveName: "it's dir.tar.gz",
        partName: part,
        format: ArchiveFormat.tarGz,
        tools: RemoteToolkit.parse(_gnuProbe),
      ),
    );
    expect(find.text("Made it's dir.tar.gz"), findsOneWidget);
  });

  testWidgets('BusyBox has no zip to offer', (tester) async {
    server.probe = _busyboxProbe;
    await pumpBrowser(tester);
    await openSheet(tester, 'notes.md');
    expect(find.text('To tar.gz, on the server'), findsOneWidget);
    await tapSheetRow(tester, 'Compress…');
    expect(find.byType(SegmentedButton<ArchiveFormat>), findsNothing);
    expect(find.text('.tar.gz'), findsOneWidget);
  });

  testWidgets('a refusal is said in the server\'s words', (tester) async {
    server
      ..jobExit = RemoteOpExit.exists
      ..jobLog = "The archive's name is taken.";
    await pumpBrowser(tester);
    await openSheet(tester, 'notes.md');
    await tapSheetRow(tester, 'Compress…');
    await tapDialogButton(tester, 'Compress');
    expect(
      find.text("Compressing notes.md: The archive's name is taken."),
      findsOneWidget,
    );
  });

  testWidgets('extract into a folder that exists asks how first',
      (tester) async {
    await pumpBrowser(tester);
    await openSheet(tester, 'site.tar.gz');
    await tapSheetRow(tester, 'Extract…');
    await tapDialogButton(tester, 'Extract');
    expect(server.launches, isEmpty, reason: 'nothing runs before the choice');
    expect(find.text('That folder is already here. Extract into it anyway?'),
        findsOneWidget);

    await tester.tap(find.text('Replace them with the archive\'s'));
    await tester.pumpAndSettle();
    await tapDialogButton(tester, 'Extract into it');

    expect(
      _scriptOf(server.launches.single),
      RemoteFileCommands.extract(
        archivePath: '/home/dev/site.tar.gz',
        kind: ArchiveKind.tarGz,
        destination: '/home/dev/site',
        mode: ExtractMode.replaceExisting,
        tools: RemoteToolkit.parse(_gnuProbe),
      ),
    );
    expect(find.text('Extracted into site'), findsOneWidget);
  });

  testWidgets('extract into a new folder needs no question', (tester) async {
    await pumpBrowser(tester);
    await openSheet(tester, 'site.tar.gz');
    await tapSheetRow(tester, 'Extract…');
    await tester.enterText(inDialog(find.byType(TextField)), 'site-2026');
    await tapDialogButton(tester, 'Extract');
    final script = _scriptOf(server.launches.single);
    expect(script, contains("t='/home/dev/site-2026'"));
    expect(script, contains('The folder already exists.'));
  });

  testWidgets('change owner starts from whose it is now', (tester) async {
    await pumpBrowser(tester);
    await openSheet(tester, 'site');
    await tapSheetRow(tester, 'Change owner…');
    expect(find.text('Now dev:staff'), findsOneWidget);
    await tester.enterText(
      inDialog(find.widgetWithText(TextField, 'Owner')),
      'www-data',
    );
    await tester.tap(find.text('Everything inside too'));
    await tester.pumpAndSettle();
    await tapDialogButton(tester, 'Change');
    expect(
      _scriptOf(server.launches.single),
      endsWith("chown -h -R -- 'www-data:staff' '/home/dev/site'"),
    );
  });

  testWidgets('change owner refuses a name that could be an option',
      (tester) async {
    await pumpBrowser(tester);
    await openSheet(tester, 'notes.md');
    await tapSheetRow(tester, 'Change owner…');
    await tester.enterText(
      inDialog(find.widgetWithText(TextField, 'Owner')),
      '-R',
    );
    await tapDialogButton(tester, 'Change');
    expect(find.textContaining('not starting with "-"'), findsOneWidget);
    expect(server.launches, isEmpty);
  });

  testWidgets('duplicate a selection from the bar\'s menu', (tester) async {
    await pumpBrowser(tester);
    await openSheet(tester, 'notes.md');
    await tapSheetRow(tester, 'Select');
    await tester.tap(find.byTooltip('More actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Duplicate').last);
    await tester.pumpAndSettle();
    await settleIo(tester);
    expect(
      _scriptOf(server.launches.single),
      contains("cp -a \$T '/home/dev/notes.md' '/home/dev/notes copy.md'"),
    );
  });

  testWidgets('search finds on the server and opens the hit', (tester) async {
    server.searchOutput = 'f 50 /home/dev/logs/app.log\u0000'
        'd 4096 /home/dev/logs\u0000';
    await pumpBrowser(tester);
    await tester.tap(find.byTooltip('Search on the server'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('searchName')), 'app');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Search'));
    await tester.pumpAndSettle();
    await settleIo(tester);
    expect(find.text('2 found'), findsOneWidget);
    expect(find.text('./logs'), findsOneWidget);

    final search = server.transport.commands.last;
    expect(search, contains("-iname '\\''*app*'\\''"));
    expect(search, contains("find '\\''/home/dev'\\''"));

    await tester.tap(find.text('app.log'));
    await tester.pumpAndSettle();
    await settleIo(tester);
    // Back in the browser, in the file's folder, with its actions up.
    expect(find.widgetWithText(ListTile, 'Tail file'), findsOneWidget);
    expect(
      find.descendant(of: find.byType(BottomSheet), matching: find.text('app.log')),
      findsOneWidget,
    );
    expect(find.text('logs'), findsWidgets, reason: 'the path bar is in logs');
  });

  testWidgets('a stopped operation goes away from the strip', (tester) async {
    // A job that does not finish by itself: launched, then running.
    final transport = FakeExecTransport(respond: (command) {
      if (command.contains('for t in tar gzip')) {
        return FakeExecSession(stdout: _gnuProbe);
      }
      if (command.contains(' ssg-op ')) {
        return FakeExecSession(stdout: '${ServerSideJob.startedMarker}\n');
      }
      if (command.contains('kill -0')) {
        return FakeExecSession(stdout: 'RUNNING\n---\n');
      }
      return FakeExecSession();
    });
    await pumpBrowser(tester, connection: transport);
    await openSheet(tester, 'notes.md');
    // Tapped by hand: the strip's spinner never lets pumpAndSettle settle.
    final row = find.widgetWithText(ListTile, 'Duplicate');
    await tester.ensureVisible(row);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(row);
    await tester.pump(const Duration(milliseconds: 300));
    await settleIo(tester);
    expect(find.text('Duplicating notes.md'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Stop'));
    await tester.pump();
    await settleIo(tester, rounds: 20);
    await tester.pump(const Duration(seconds: 2));
    await settleIo(tester);
    expect(find.text('Duplicating notes.md'), findsNothing);
    expect(find.text('Duplicating notes.md: stopped.'), findsOneWidget);
    expect(transport.commands.any((c) => c.contains('kill -s TERM')), isTrue);
  });
}

class _StubStorage implements DeviceStorage {
  @override
  Future<bool> ensurePermission() async => true;

  @override
  Future<bool> downloadExists(
    String fileName, {
    String relativeDirectory = '',
  }) async =>
      false;

  @override
  Future<DownloadWriter> beginDownload(
    String fileName, {
    String? mimeType,
    bool overwrite = false,
    String relativeDirectory = '',
  }) async =>
      throw UnimplementedError();

  @override
  Future<bool> openDownload(String uri, {String? mimeType}) async => false;

  @override
  Future<PickedLocalFile?> pickFile() async => null;

  @override
  Future<List<PickedLocalFile>> pickFiles() async => const [];

  @override
  Future<PickedTextFile?> pickTextFile({
    int maxBytes = kDefaultPickedTextFileMaxBytes,
  }) async =>
      null;

  @override
  Future<PickedLocalDirectory?> pickDirectory() async => null;
}

class _NoopTimer implements Timer {
  var _cancelled = false;

  @override
  bool get isActive => !_cancelled;

  @override
  int get tick => 0;

  @override
  void cancel() => _cancelled = true;
}
