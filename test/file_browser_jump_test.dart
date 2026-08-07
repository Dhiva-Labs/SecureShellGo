import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/models/remote_entry.dart';
import 'package:secure_shell_go/screens/file_browser_pane.dart';
import 'package:secure_shell_go/services/bookmark_store.dart';
import 'package:secure_shell_go/services/device_storage.dart';
import 'package:secure_shell_go/services/session_controller.dart';
import 'package:secure_shell_go/services/settings_store.dart';
import 'package:secure_shell_go/services/sftp_service.dart';
import 'package:secure_shell_go/services/ssh_service.dart';
import 'package:secure_shell_go/theme.dart';

/// A remote tree with the failure modes a real server has.
///
/// The refusals are copied from what `SftpService` produces against a live
/// OpenSSH box — `list` on a *file* reports "not there any more", which is
/// exactly the misleading answer the location bar has to route around, and a
/// directory this account cannot read reports permission denied.
class JumpFs implements RemoteFileSystem {
  JumpFs() {
    directories.addAll([
      '/',
      '/etc',
      '/etc/nginx',
      '/etc/nginx/sites-available',
      '/home',
      '/home/dev',
      '/home/dev/notes',
      '/root',
    ]);
    put('/etc/hosts', '127.0.0.1 localhost\n');
    put('/etc/nginx/nginx.conf', 'worker_processes 1;\n');
    put('/etc/nginx/sites-available/default', 'server {\n  listen 80;\n}\n');
    put('/home/dev/notes/todo.txt', 'buy milk\n');
  }

  final Set<String> directories = {};
  final Map<String, Uint8List> files = {};

  /// Paths whose *contents* this account may not read, `/root` style.
  final Set<String> unreadable = {'/root'};

  /// Every path handed to [list], so a test can prove a failed jump did not
  /// quietly re-list anything behind the user's back.
  final List<String> listed = [];

  void put(String path, String text) {
    files[path] = Uint8List.fromList(utf8.encode(text));
  }

  @override
  Future<String> home() async => '/home/dev';

  @override
  Future<String> resolve(String path) async => path;

  @override
  Future<List<RemoteEntry>> list(String path) async {
    listed.add(path);
    if (unreadable.contains(path)) {
      throw SftpFailure(
        'Permission denied. Your account cannot read '
        '"${path.split('/').last}" on this server.',
        isPermissionDenied: true,
      );
    }
    if (!directories.contains(path)) {
      throw SftpFailure('"${path.split('/').last}" is not there any more.');
    }
    final rows = <RemoteEntry>[];
    for (final dir in directories) {
      if (dir != '/' && _parentOf(dir) == path) {
        rows.add(RemoteEntry(
          name: dir.split('/').last,
          path: dir,
          kind: RemoteEntryKind.directory,
        ));
      }
    }
    for (final entry in files.entries) {
      if (_parentOf(entry.key) == path) {
        rows.add(RemoteEntry(
          name: entry.key.split('/').last,
          path: entry.key,
          kind: RemoteEntryKind.file,
          size: entry.value.length,
        ));
      }
    }
    rows.sort(RemoteEntry.compare);
    return rows;
  }

  static String _parentOf(String path) {
    final at = path.lastIndexOf('/');
    return at <= 0 ? '/' : path.substring(0, at);
  }

  @override
  Future<bool> isDirectory(String path) async => directories.contains(path);

  @override
  Future<bool> exists(String path) async =>
      directories.contains(path) || files.containsKey(path);

  @override
  Future<int?> sizeOf(String path) async => files[path]?.length;

  @override
  Future<int> download(
    String remotePath, {
    required Future<void> Function(Uint8List chunk) write,
    TransferProgress? onProgress,
    CancelCheck? isCancelled,
  }) async {
    final bytes = files[remotePath];
    if (bytes == null) throw SftpFailure('"$remotePath" is not there.');
    await write(bytes);
    return bytes.length;
  }

  @override
  Future<int> upload(
    String localPath,
    String remotePath, {
    TransferProgress? onProgress,
    CancelCheck? isCancelled,
  }) async =>
      throw UnimplementedError();

  @override
  Future<RemoteFileWriter> openWrite(String remotePath) async =>
      throw UnimplementedError();

  @override
  Future<void> mkdir(String path) async => throw UnimplementedError();

  @override
  Future<void> removeDirectory(String path) async => throw UnimplementedError();

  @override
  Future<void> remove(String path) async => throw UnimplementedError();

  @override
  Future<void> rename(String from, String to) async =>
      throw UnimplementedError();

  @override
  Future<void> close() async {}
}

/// Opens no sockets; the browser pane never asks it for a shell.
class FakeTransport implements SessionTransport {
  final _done = Completer<void>();
  final _agentSlot = MutableSSHAgentHandler();

  @override
  final Host host = Host(
    id: 'h1',
    label: 'demo',
    hostname: 'demo.example.com',
    port: 22,
    username: 'dev',
    authMethod: SshAuthMethod.password,
  );

  var closeCount = 0;

  @override
  Future<void> get done => _done.future;

  @override
  bool get isClosed => closeCount > 0;

  @override
  Future<SSHSession> startShell({
    required int columns,
    required int rows,
    String terminalType = 'xterm-256color',
  }) =>
      throw UnimplementedError();

  @override
  Future<SftpClient> openSftp() => throw UnimplementedError();

  @override
  Future<SSHSession> execute(String command) => throw UnimplementedError();

  @override
  MutableSSHAgentHandler get agentSlot => _agentSlot;

  @override
  Future<void> ping() async {}

  @override
  void close() => closeCount++;
}

class StubStorage implements DeviceStorage {
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

class NoopTimer implements Timer {
  var _cancelled = false;

  @override
  bool get isActive => !_cancelled;

  @override
  int get tick => 0;

  @override
  void cancel() => _cancelled = true;
}

void main() {
  late Directory temp;
  late JumpFs fs;
  late SessionController session;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('browser_jump');
    fs = JumpFs();
    session = SessionController(
      connection: FakeTransport(),
      storage: StubStorage(),
      openFileSystem: () async => fs,
      keepaliveScheduler: (_, _) => NoopTimer(),
    );
  });

  tearDown(() async {
    await session.dispose();
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  /// Lets the bookmark store's real file read finish, which the fake clock a
  /// widget test runs under never would on its own. Same trick as
  /// `host_edit_screen_test.dart`'s `settleIo`, and skipping it leaves a
  /// `setState` landing after the test has torn the pane down.
  Future<void> settleIo(WidgetTester tester, {int rounds = 6}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
  }

  Future<void> pumpBrowser(WidgetTester tester) async {
    // The real app theme, not a bare MaterialApp: this app gives every
    // FilledButton an infinite minimum width, and a default-themed test would
    // not notice a button that cannot survive being put in a Row.
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

  /// Opens the location bar the way a mouse user would.
  Future<void> openLocationBar(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Go to path (Ctrl+L)'));
    await tester.pumpAndSettle();
  }

  Finder pathField() => find.widgetWithText(TextField, 'Go to path');

  testWidgets('the pane opens on the home directory', (tester) async {
    await pumpBrowser(tester);
    expect(find.text('notes'), findsOneWidget);
    expect(find.byTooltip('Go to path (Ctrl+L)'), findsOneWidget);
  });

  testWidgets('jumping to an absolute directory navigates there',
      (tester) async {
    await pumpBrowser(tester);
    await openLocationBar(tester);

    await tester.enterText(pathField(), '/etc/nginx');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    // The listing is /etc/nginx now, and the bar has closed itself.
    expect(find.text('nginx.conf'), findsOneWidget);
    expect(find.text('sites-available'), findsOneWidget);
    expect(pathField(), findsNothing);
    // Breadcrumbs still work and now describe where we landed.
    expect(find.widgetWithText(TextButton, 'nginx'), findsOneWidget);
  });

  testWidgets('a trailing slash is tolerated', (tester) async {
    await pumpBrowser(tester);
    await openLocationBar(tester);

    await tester.enterText(pathField(), '/etc/nginx/');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(find.text('nginx.conf'), findsOneWidget);
    expect(fs.listed.last, '/etc/nginx');
  });

  testWidgets('jumping to a file opens it in the editor', (tester) async {
    await pumpBrowser(tester);
    await openLocationBar(tester);

    await tester.enterText(
      pathField(),
      '/etc/nginx/sites-available/default',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    // The editor is up, on that file, with its contents in the field.
    expect(find.text('demo:/etc/nginx/sites-available/default'),
        findsOneWidget);
    expect(find.byTooltip('Save (Ctrl+S)'), findsNothing);
    expect(find.byTooltip('No changes to save'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField).first).controller!.text,
      'server {\n  listen 80;\n}\n',
    );

    // Closing it leaves the browser among that file's siblings, not back in
    // the home directory it started from.
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('default'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'sites-available'), findsOneWidget);
  });

  testWidgets('~ and ~/… expand against the server home', (tester) async {
    await pumpBrowser(tester);
    await openLocationBar(tester);

    await tester.enterText(pathField(), '~/notes');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(find.text('todo.txt'), findsOneWidget);
    expect(fs.listed.last, '/home/dev/notes');

    await openLocationBar(tester);
    await tester.enterText(pathField(), '~');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(fs.listed.last, '/home/dev');
    expect(find.text('notes'), findsOneWidget);
  });

  testWidgets('a path that is not there reports why and leaves the listing',
      (tester) async {
    await pumpBrowser(tester);
    expect(find.text('notes'), findsOneWidget);
    await openLocationBar(tester);

    fs.listed.clear();
    await tester.enterText(pathField(), '/etc/nginx/nginxx.conf');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(pathField());
    expect(field.decoration?.errorText, '"nginxx.conf" is not there any more.');
    // Still in the home directory, with the same rows on screen, and nothing
    // was re-listed to get back there.
    expect(find.text('notes'), findsOneWidget);
    expect(fs.listed, ['/etc/nginx/nginxx.conf']);
    // The bar stays open so the typo can be fixed in place.
    expect(pathField(), findsOneWidget);
  });

  testWidgets('a directory this account cannot read reports the refusal',
      (tester) async {
    await pumpBrowser(tester);
    await openLocationBar(tester);

    await tester.enterText(pathField(), '/root');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(pathField());
    expect(field.decoration?.errorText, contains('Permission denied'));
    expect(find.text('notes'), findsOneWidget);
  });

  testWidgets('typing again clears the last refusal', (tester) async {
    await pumpBrowser(tester);
    await openLocationBar(tester);

    await tester.enterText(pathField(), '/nope');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(pathField()).decoration?.errorText,
        isNotNull);

    await tester.enterText(pathField(), '/etc');
    await tester.pumpAndSettle();
    expect(
        tester.widget<TextField>(pathField()).decoration?.errorText, isNull);
  });

  testWidgets('Ctrl+L opens the bar and focuses the field', (tester) async {
    await pumpBrowser(tester);
    expect(pathField(), findsNothing);

    // A click anywhere in the pane is what hands it the keyboard — the
    // terminal next door owns it until then. Refresh is the one control here
    // that changes nothing about where the browser is pointing.
    await tester.tap(find.byTooltip('Refresh'));
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(pathField(), findsOneWidget);
    final field = tester.widget<TextField>(pathField());
    expect(field.focusNode?.hasFocus, isTrue);
    // Seeded with where we are, fully selected so typing replaces it.
    expect(field.controller?.text, '/home/dev/');
    expect(field.controller?.selection.textInside('/home/dev/'),
        '/home/dev/');

    // Escape puts the breadcrumbs back.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(pathField(), findsNothing);
    expect(find.byTooltip('Go to path (Ctrl+L)'), findsOneWidget);
  });

  testWidgets('the quick destinations jump in one tap', (tester) async {
    await pumpBrowser(tester);
    await openLocationBar(tester);

    await tester.tap(find.widgetWithText(ActionChip, '/etc'));
    await tester.pumpAndSettle();

    expect(fs.listed.last, '/etc');
    expect(find.text('hosts'), findsOneWidget);
    expect(find.text('nginx'), findsWidgets);
  });

  testWidgets('the path bar survives a phone-width window', (tester) async {
    // The crumbs row grew a fourth button and the location bar is a whole
    // second layout; both have to hold at 360 logical pixels, where an
    // overflow would take the pane's body down with it.
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await pumpBrowser(tester);
    expect(tester.takeException(), isNull);

    await openLocationBar(tester);
    expect(tester.takeException(), isNull);
    expect(pathField(), findsOneWidget);
    expect(find.widgetWithText(ActionChip, '/var/log'), findsOneWidget);

    await tester.enterText(pathField(), '/root');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    // Even with the error text under the field, nothing overflowed.
    expect(tester.takeException(), isNull);
  });

  testWidgets('a relative path resolves against the directory on screen',
      (tester) async {
    await pumpBrowser(tester);
    await openLocationBar(tester);

    await tester.enterText(pathField(), 'notes');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(fs.listed.last, '/home/dev/notes');
    expect(find.text('todo.txt'), findsOneWidget);
  });
}
