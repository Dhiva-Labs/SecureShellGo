import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/remote_entry.dart';
import 'package:secure_shell_go/screens/file_browser_pane.dart';
import 'package:secure_shell_go/services/bookmark_store.dart';
import 'package:secure_shell_go/services/device_storage.dart';
import 'package:secure_shell_go/services/remote_entry_actions.dart';
import 'package:secure_shell_go/services/remote_path.dart';
import 'package:secure_shell_go/services/session_controller.dart';
import 'package:secure_shell_go/services/settings_store.dart';
import 'package:secure_shell_go/services/sftp_service.dart';
import 'package:secure_shell_go/theme.dart';

import 'support/fake_transport.dart';

/// A remote tree that behaves the way an OpenSSH server does where it
/// matters to delete, rename, mkdir and chmod.
///
/// `remove` is unlink: it takes a link as the link and refuses a directory.
/// `rename` is `posix-rename`: it replaces whatever is at the target without
/// a word, which is exactly the outcome the browser must never reach — so a
/// test that lets a rename through onto a taken name loses that file here,
/// the same as it would on a real server.
class ActionsFs implements RemoteFileSystem, RemoteFileMetadata {
  ActionsFs() {
    directories.addAll([
      '/',
      '/home',
      '/home/dev',
      '/home/dev/notes',
      '/home/dev/site',
      '/home/dev/site/css',
      '/var',
      '/var/www',
      '/var/www/assets',
    ]);
    files.addAll({
      '/home/dev/todo.txt': 9,
      '/home/dev/notes.md': 4,
      '/home/dev/run.sh': 20,
      '/home/dev/notes/a.txt': 1,
      '/home/dev/site/index.html': 10,
      '/home/dev/site/css/app.css': 10,
      '/var/www/index.html': 10,
      '/var/www/assets/app.js': 20,
    });
    // `www -> /var/www`: the link whose folder must survive a delete.
    symlinks['/home/dev/www'] = '/var/www';
  }

  final Set<String> directories = {};
  final Map<String, int> files = {};
  final Map<String, String> symlinks = {};

  /// Permission bits by path; anything missing has the usual default.
  final Map<String, int> modes = {};

  /// Paths the server refuses to remove, rename into or chmod, as
  /// "permission denied".
  final Set<String> protected = {};

  /// False for a server that leaves the mode out of its replies.
  bool reportsModes = true;

  /// For a Windows or macOS server, where `Notes.txt` *is* `notes.txt`.
  bool caseInsensitive = false;

  final List<String> removed = [];
  final List<String> removedDirectories = [];
  final List<String> made = [];
  final List<(String, String)> renamed = [];
  final List<(String, int)> chmods = [];

  static String _parentOf(String path) {
    final at = path.lastIndexOf('/');
    return at <= 0 ? '/' : path.substring(0, at);
  }

  static String _nameOf(String path) => path.split('/').last;

  String _follow(String path) => symlinks[path] ?? path;

  bool _isThere(String path) {
    final real = _follow(path);
    if (caseInsensitive) {
      final lower = real.toLowerCase();
      return directories.any((d) => d.toLowerCase() == lower) ||
          files.keys.any((f) => f.toLowerCase() == lower);
    }
    return directories.contains(real) || files.containsKey(real);
  }

  int _defaultMode(String path) =>
      symlinks.containsKey(path) ? 0x1FF : (directories.contains(path) ? 0x1ED : 0x1A4);

  SftpFailure _denied(String path) => SftpFailure(
        'Permission denied. Your account cannot read "${_nameOf(path)}" on '
        'this server.',
        isPermissionDenied: true,
      );

  SftpFailure _gone(String path) =>
      SftpFailure('"${_nameOf(path)}" is not there any more.');

  @override
  Future<String> home() async => '/home/dev';

  @override
  Future<String> resolve(String path) async => path;

  @override
  Future<List<RemoteEntry>> list(String path) async {
    final real = _follow(path);
    if (protected.contains(real)) throw _denied(path);
    if (!directories.contains(real)) throw _gone(path);

    final rows = <RemoteEntry>[];
    void add(String child, RemoteEntryKind kind, int typeBits,
        {int? size, bool? linkToDirectory}) {
      rows.add(RemoteEntry(
        name: _nameOf(child),
        path: RemotePath.join(path, _nameOf(child)),
        kind: kind,
        size: size,
        // The whole mode word, file-type bits and all, the way
        // `SftpService.list` reports it.
        permissions: reportsModes
            ? typeBits | (modes[child] ?? _defaultMode(child))
            : null,
        linkTargetIsDirectory: linkToDirectory,
      ));
    }

    for (final dir in directories) {
      if (dir != '/' && _parentOf(dir) == real) {
        add(dir, RemoteEntryKind.directory, 0x4000);
      }
    }
    for (final file in files.entries) {
      if (_parentOf(file.key) == real) {
        add(file.key, RemoteEntryKind.file, 0x8000, size: file.value);
      }
    }
    for (final link in symlinks.entries) {
      if (_parentOf(link.key) == real) {
        add(link.key, RemoteEntryKind.symlink, 0xA000,
            linkToDirectory: directories.contains(link.value));
      }
    }
    rows.sort(RemoteEntry.compare);
    return rows;
  }

  @override
  Future<bool> isDirectory(String path) async =>
      directories.contains(_follow(path));

  /// A stat, so it follows links: one that points nowhere is not there.
  @override
  Future<bool> exists(String path) async => _isThere(path);

  @override
  Future<int?> sizeOf(String path) async => files[_follow(path)];

  @override
  Future<void> remove(String path) async {
    if (protected.contains(path)) throw _denied(path);
    if (symlinks.remove(path) != null || files.remove(path) != null) {
      removed.add(path);
      return;
    }
    if (directories.contains(path)) {
      throw const SftpFailure('The server refused: Failure');
    }
    throw _gone(path);
  }

  @override
  Future<void> removeDirectory(String path) async {
    if (protected.contains(path)) throw _denied(path);
    if (!directories.contains(path)) {
      throw const SftpFailure('The server refused: Failure');
    }
    final occupied = directories.any((d) => d != path && _parentOf(d) == path) ||
        files.keys.any((f) => _parentOf(f) == path) ||
        symlinks.keys.any((l) => _parentOf(l) == path);
    if (occupied) throw const SftpFailure('The server refused: Failure');
    directories.remove(path);
    removedDirectories.add(path);
  }

  @override
  Future<void> rename(String from, String to) async {
    if (protected.contains(from)) throw _denied(from);
    if (!directories.contains(from) &&
        !files.containsKey(from) &&
        !symlinks.containsKey(from)) {
      throw _gone(from);
    }
    renamed.add((from, to));
    // posix-rename: whatever was at [to] is simply gone.
    files.remove(to);
    symlinks.remove(to);

    String moved(String path) =>
        path == from ? to : '$to${path.substring(from.length)}';
    bool under(String path) => path == from || path.startsWith('$from/');

    for (final dir in directories.where(under).toList()) {
      directories
        ..remove(dir)
        ..add(moved(dir));
    }
    for (final file in files.keys.where(under).toList()) {
      files[moved(file)] = files.remove(file)!;
    }
    for (final link in symlinks.keys.where(under).toList()) {
      symlinks[moved(link)] = symlinks.remove(link)!;
    }
  }

  @override
  Future<void> mkdir(String path) async {
    final parent = _parentOf(path);
    if (protected.contains(parent)) throw _denied(path);
    if (_isThere(path) || symlinks.containsKey(path)) {
      throw const SftpFailure('The server refused: Failure');
    }
    if (!directories.contains(parent)) throw _gone(parent);
    directories.add(path);
    made.add(path);
  }

  @override
  Future<RemoteFileStat?> statFile(String path) async {
    final real = _follow(path);
    if (!directories.contains(real) && !files.containsKey(real)) return null;
    return RemoteFileStat(
      size: files[real],
      permissions: reportsModes ? (modes[real] ?? _defaultMode(real)) : null,
    );
  }

  @override
  Future<bool> setPermissions(String path, int permissions) async {
    if (protected.contains(path)) return false;
    chmods.add((path, permissions));
    modes[_follow(path)] = permissions;
    return true;
  }

  @override
  Future<int> download(
    String remotePath, {
    required Future<void> Function(Uint8List chunk) write,
    TransferProgress? onProgress,
    CancelCheck? isCancelled,
  }) async =>
      throw UnimplementedError();

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
  Future<void> close() async {}
}

/// Opens no sockets; the browser pane never asks it for a shell.
class FakeTransport extends FakeTransportBase {
  FakeTransport()
      : super(
          host: FakeTransportBase.hostFor(
            label: 'demo',
            hostname: 'demo.example.com',
          ),
        );
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

RemoteEntry entryAt(ActionsFs fs, String path) {
  final kind = fs.symlinks.containsKey(path)
      ? RemoteEntryKind.symlink
      : fs.directories.contains(path)
          ? RemoteEntryKind.directory
          : RemoteEntryKind.file;
  return RemoteEntry(name: path.split('/').last, path: path, kind: kind);
}

void main() {
  group('deleteRemoteEntry', () {
    test('a link to a folder goes as the link; the folder stays whole',
        () async {
      final fs = ActionsFs();

      final failure = await deleteRemoteEntry(fs, entryAt(fs, '/home/dev/www'));

      expect(failure, isNull);
      expect(fs.removed, ['/home/dev/www']);
      expect(fs.removedDirectories, isEmpty);
      expect(fs.directories, containsAll(['/var/www', '/var/www/assets']));
      expect(fs.files.keys,
          containsAll(['/var/www/index.html', '/var/www/assets/app.js']));
    });

    test('a folder goes with everything under it', () async {
      final fs = ActionsFs();

      final failure =
          await deleteRemoteEntry(fs, entryAt(fs, '/home/dev/site'));

      expect(failure, isNull);
      expect(fs.directories.where((d) => d.startsWith('/home/dev/site')),
          isEmpty);
      expect(fs.files.keys.where((f) => f.startsWith('/home/dev/site')),
          isEmpty);
    });

    test('a folder that will not empty names the refusal that stopped it',
        () async {
      final fs = ActionsFs()..protected.add('/home/dev/site/css/app.css');

      final failure =
          await deleteRemoteEntry(fs, entryAt(fs, '/home/dev/site'));

      expect(failure, isNotNull);
      expect(failure!.message, startsWith('Some of "site" could not be deleted'));
      // The permission refusal on the file in the way, not the folder's own
      // "not empty", which says nothing about why.
      expect(failure.message, contains('"app.css"'));
      expect(failure.isPermissionDenied, isTrue);
      // Everything that could go went.
      expect(fs.files.containsKey('/home/dev/site/index.html'), isFalse);
      expect(fs.directories, contains('/home/dev/site'));
    });
  });

  group('remoteNameTaken', () {
    test('a link that points nowhere still holds its name', () async {
      final fs = ActionsFs()..symlinks['/home/dev/old'] = '/nowhere';

      expect(await fs.exists('/home/dev/old'), isFalse,
          reason: 'a stat follows the link, so it alone would miss this');
      expect(await remoteNameTaken(fs, '/home/dev', 'old'), isTrue);
      expect(await remoteNameTaken(fs, '/home/dev', 'new'), isFalse);
    });

    test('a name the server counts as the same one is taken', () async {
      final fs = ActionsFs()..caseInsensitive = true;

      expect(
        await remoteNameTaken(fs, '/home/dev', 'TODO.txt', renaming: 'run.sh'),
        isTrue,
      );
    });

    test('changing only the case of a name is not a clash with itself',
        () async {
      final fs = ActionsFs()..caseInsensitive = true;

      expect(
        await remoteNameTaken(fs, '/home/dev', 'Todo.txt',
            renaming: 'todo.txt'),
        isFalse,
      );
    });
  });

  group('the browser', () {
    late Directory temp;
    late ActionsFs fs;
    late SessionController session;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('browser_actions');
      fs = ActionsFs();
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

    Future<void> pumpBrowser(WidgetTester tester) async {
      // The real app theme: it gives every FilledButton an infinite minimum
      // width, which a default-themed test would never trip over.
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

    /// Taps a row of the action sheet, scrolling to it first: the sheet is
    /// taller than the test window once a file has all its rows.
    Future<void> tapSheetRow(WidgetTester tester, String label) async {
      final row = find.widgetWithText(ListTile, label);
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      await tester.tap(row);
      await tester.pumpAndSettle();
    }

    Finder inDialog(Finder finder) =>
        find.descendant(of: find.byType(AlertDialog), matching: finder);

    Finder dialogButton(String label) => find.ancestor(
          of: inDialog(find.text(label)),
          matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
        );

    TextField nameField(WidgetTester tester) =>
        tester.widget<TextField>(inDialog(find.byType(TextField)));

    List<bool?> boxes(WidgetTester tester) => tester
        .widgetList<Checkbox>(find.byType(Checkbox))
        .map((box) => box.value)
        .toList();

    // ---------------------------------------------------------------- delete

    testWidgets('Delete names the file, then removes it', (tester) async {
      await pumpBrowser(tester);
      await openSheet(tester, 'todo.txt');
      await tapSheetRow(tester, 'Delete');

      expect(find.text('Delete "todo.txt"?'), findsOneWidget);
      await tester.tap(dialogButton('Delete'));
      await tester.pumpAndSettle();

      expect(fs.removed, ['/home/dev/todo.txt']);
      expect(find.text('todo.txt'), findsNothing,
          reason: 'the listing is redrawn once the server has answered');
      expect(find.text('Deleted todo.txt'), findsOneWidget);
    });

    testWidgets('cancelling the confirm deletes nothing', (tester) async {
      await pumpBrowser(tester);
      await openSheet(tester, 'todo.txt');
      await tapSheetRow(tester, 'Delete');

      await tester.tap(dialogButton('Cancel'));
      await tester.pumpAndSettle();

      expect(fs.removed, isEmpty);
      expect(fs.files.containsKey('/home/dev/todo.txt'), isTrue);
      expect(find.text('todo.txt'), findsOneWidget);
    });

    testWidgets('a folder delete says it is recursive and takes the tree',
        (tester) async {
      await pumpBrowser(tester);
      await openSheet(tester, 'site');
      expect(find.text('With everything inside it'), findsOneWidget);
      await tapSheetRow(tester, 'Delete folder');

      expect(find.text('Delete folder "site"?'), findsOneWidget);
      expect(find.textContaining('Everything inside it is deleted too'),
          findsOneWidget);
      await tester.tap(dialogButton('Delete'));
      await tester.pumpAndSettle();

      expect(fs.directories.where((d) => d.startsWith('/home/dev/site')),
          isEmpty);
      expect(fs.files.keys.where((f) => f.startsWith('/home/dev/site')),
          isEmpty);
      expect(find.text('site'), findsNothing);
    });

    testWidgets('a symlinked folder is deleted as the link', (tester) async {
      await pumpBrowser(tester);
      await openSheet(tester, 'www');
      expect(find.text('Removes the link, not what it points to'),
          findsOneWidget);
      // chmod follows a link, so the sheet does not offer it on one.
      expect(find.text('Permissions…'), findsNothing);
      await tapSheetRow(tester, 'Delete');

      expect(find.text('Delete link "www"?'), findsOneWidget);
      expect(find.textContaining('The folder it points to'), findsOneWidget);
      expect(find.textContaining('Everything inside it'), findsNothing);
      await tester.tap(dialogButton('Delete'));
      await tester.pumpAndSettle();

      expect(fs.removed, ['/home/dev/www']);
      expect(fs.removedDirectories, isEmpty);
      expect(fs.directories, containsAll(['/var/www', '/var/www/assets']));
      expect(fs.files.keys,
          containsAll(['/var/www/index.html', '/var/www/assets/app.js']));
      expect(find.text('www'), findsNothing);
    });

    testWidgets('a refused delete says why, in the server\'s words',
        (tester) async {
      fs.protected.add('/home/dev/todo.txt');
      await pumpBrowser(tester);
      await openSheet(tester, 'todo.txt');
      await tapSheetRow(tester, 'Delete');
      await tester.tap(dialogButton('Delete'));
      await tester.pumpAndSettle();

      expect(
        find.text('Permission denied. Your account cannot read "todo.txt" on '
            'this server.'),
        findsOneWidget,
      );
      expect(find.text('todo.txt'), findsOneWidget);
    });

    testWidgets('a selection is deleted together, after one confirm',
        (tester) async {
      await pumpBrowser(tester);
      await openSheet(tester, 'todo.txt');
      await tapSheetRow(tester, 'Select');
      await tester.tap(find.text('notes.md'));
      await tester.pumpAndSettle();
      expect(find.text('2 selected'), findsOneWidget);

      await tester.tap(find.byTooltip('Delete selected (Del)'));
      await tester.pumpAndSettle();

      expect(find.text('Delete 2 items?'), findsOneWidget);
      expect(inDialog(find.text('notes.md')), findsOneWidget);
      expect(inDialog(find.text('todo.txt')), findsOneWidget);
      await tester.tap(dialogButton('Delete'));
      await tester.pumpAndSettle();

      expect(fs.removed, unorderedEquals(
          ['/home/dev/notes.md', '/home/dev/todo.txt']));
      expect(find.text('Deleted 2 items'), findsOneWidget);
      expect(find.text('2 selected'), findsNothing);
      expect(find.text('run.sh'), findsOneWidget);
    });

    testWidgets('a long selection is summarised, not listed in full',
        (tester) async {
      for (var i = 0; i < 6; i++) {
        fs.files['/home/dev/log$i.txt'] = 1;
      }
      await pumpBrowser(tester);
      // The first file row: the rest of this listing is below the fold.
      await openSheet(tester, 'log0.txt');
      await tapSheetRow(tester, 'Select');
      await tester.tap(find.widgetWithText(TextButton, 'All'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Delete selected (Del)'));
      await tester.pumpAndSettle();

      expect(find.text('Delete 9 items?'), findsOneWidget);
      expect(inDialog(find.text('and 4 more')), findsOneWidget);
      await tester.tap(dialogButton('Delete'));
      await tester.pumpAndSettle();
      expect(fs.removed, hasLength(9));
    });

    // ---------------------------------------------------------------- rename

    testWidgets('Rename renames in place, extension kept out of the way',
        (tester) async {
      await pumpBrowser(tester);
      await openSheet(tester, 'todo.txt');
      await tapSheetRow(tester, 'Rename…');

      final controller = nameField(tester).controller!;
      expect(controller.text, 'todo.txt');
      expect(controller.selection.textInside(controller.text), 'todo');

      await tester.enterText(inDialog(find.byType(TextField)), 'done.txt');
      await tester.tap(dialogButton('Rename'));
      await tester.pumpAndSettle();

      expect(fs.renamed, [('/home/dev/todo.txt', '/home/dev/done.txt')]);
      expect(find.text('done.txt'), findsOneWidget);
      expect(find.text('todo.txt'), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('Rename refuses a name that is already taken', (tester) async {
      await pumpBrowser(tester);
      await openSheet(tester, 'todo.txt');
      await tapSheetRow(tester, 'Rename…');

      await tester.enterText(inDialog(find.byType(TextField)), 'notes.md');
      await tester.tap(dialogButton('Rename'));
      await tester.pumpAndSettle();

      // Still open, saying why, with nothing sent to the server — whose
      // posix-rename would have replaced notes.md without a word.
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(nameField(tester).decoration?.errorText,
          contains('"notes.md" already exists here'));
      expect(fs.renamed, isEmpty);
      expect(fs.files['/home/dev/notes.md'], 4);

      // Editing clears the refusal so the field can be fixed in place.
      await tester.enterText(inDialog(find.byType(TextField)), 'notes2.md');
      await tester.pump();
      expect(nameField(tester).decoration?.errorText, isNull);
    });

    testWidgets('Rename refuses what cannot be a name', (tester) async {
      await pumpBrowser(tester);
      await openSheet(tester, 'todo.txt');
      await tapSheetRow(tester, 'Rename…');

      for (final bad in ['', '   ', 'a/b', '.', '..']) {
        await tester.enterText(inDialog(find.byType(TextField)), bad);
        await tester.tap(dialogButton('Rename'));
        await tester.pumpAndSettle();
        expect(nameField(tester).decoration?.errorText, isNotNull,
            reason: '"$bad" must be refused');
      }
      expect(fs.renamed, isEmpty);
    });

    // ------------------------------------------------------------ new folder

    testWidgets('New folder makes one in the directory on screen',
        (tester) async {
      await pumpBrowser(tester);
      await tester.tap(find.byTooltip('New folder'));
      await tester.pumpAndSettle();

      await tester.enterText(inDialog(find.byType(TextField)), 'logs');
      await tester.tap(dialogButton('Create'));
      await tester.pumpAndSettle();

      expect(fs.made, ['/home/dev/logs']);
      expect(find.text('logs'), findsOneWidget);
      expect(find.text('Created folder logs'), findsOneWidget);
    });

    testWidgets('New folder refuses a taken name and what cannot be a name',
        (tester) async {
      await pumpBrowser(tester);
      await tester.tap(find.byTooltip('New folder'));
      await tester.pumpAndSettle();

      await tester.enterText(inDialog(find.byType(TextField)), 'notes');
      await tester.tap(dialogButton('Create'));
      await tester.pumpAndSettle();
      expect(nameField(tester).decoration?.errorText,
          '"notes" already exists here.');

      await tester.enterText(inDialog(find.byType(TextField)), '..');
      await tester.tap(dialogButton('Create'));
      await tester.pumpAndSettle();
      expect(nameField(tester).decoration?.errorText, contains('reserved'));

      await tester.enterText(inDialog(find.byType(TextField)), 'a/b');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(nameField(tester).decoration?.errorText, contains('"/"'));

      expect(fs.made, isEmpty);
    });

    // ----------------------------------------------------------- permissions

    testWidgets('Permissions shows the mode both ways and applies a change',
        (tester) async {
      await pumpBrowser(tester);
      await openSheet(tester, 'run.sh');
      expect(find.text('Now 644'), findsOneWidget);
      await tapSheetRow(tester, 'Permissions…');

      // Owner, group, others; read, write, execute.
      expect(nameField(tester).controller!.text, '644');
      expect(boxes(tester),
          [true, true, false, true, false, false, true, false, false]);

      // Ticking owner-execute rewrites the digits...
      await tester.tap(find.byType(Checkbox).at(2));
      await tester.pump();
      expect(nameField(tester).controller!.text, '744');

      // ...and typing the digits re-ticks the grid.
      await tester.enterText(inDialog(find.byType(TextField)), '750');
      await tester.pump();
      expect(boxes(tester),
          [true, true, true, true, false, true, false, false, false]);

      await tester.tap(dialogButton('Apply'));
      await tester.pumpAndSettle();

      expect(fs.chmods, [('/home/dev/run.sh', 0x1E8)]);
      expect(find.text('run.sh is now 750'), findsOneWidget);
    });

    testWidgets('Apply waits for digits that make a mode', (tester) async {
      await pumpBrowser(tester);
      await openSheet(tester, 'run.sh');
      await tapSheetRow(tester, 'Permissions…');

      await tester.enterText(inDialog(find.byType(TextField)), '75');
      await tester.pump();
      expect(nameField(tester).decoration?.errorText, isNotNull);
      expect(
        tester.widget<ButtonStyleButton>(dialogButton('Apply')).onPressed,
        isNull,
      );
    });

    testWidgets('setuid survives a change made in the grid', (tester) async {
      fs.modes['/home/dev/run.sh'] = 0x9ED; // 04755
      await pumpBrowser(tester);
      await openSheet(tester, 'run.sh');
      await tapSheetRow(tester, 'Permissions…');

      expect(nameField(tester).controller!.text, '4755');
      await tester.tap(find.byType(Checkbox).at(8)); // others: execute
      await tester.pump();
      expect(nameField(tester).controller!.text, '4754');
    });

    testWidgets('Permissions is not offered when the server reports no mode',
        (tester) async {
      fs.reportsModes = false;
      await pumpBrowser(tester);
      await openSheet(tester, 'run.sh');

      expect(find.text('Rename…'), findsOneWidget);
      expect(find.text('Permissions…'), findsNothing);
    });

    // -------------------------------------------------------------- keyboard

    testWidgets('F2 and Delete act on the row that has the keyboard',
        (tester) async {
      await pumpBrowser(tester);
      await openSheet(tester, 'todo.txt');
      // The sheet names the keys on desktop.
      expect(find.text('F2'), findsOneWidget);
      expect(find.text('Del'), findsOneWidget);
      Navigator.of(tester.element(find.text('F2'))).pop();
      await tester.pumpAndSettle();

      Focus.of(tester.element(find.text('todo.txt'))).requestFocus();
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.f2);
      await tester.pumpAndSettle();
      expect(nameField(tester).controller!.text, 'todo.txt');
      await tester.tap(dialogButton('Cancel'));
      await tester.pumpAndSettle();

      Focus.of(tester.element(find.text('todo.txt'))).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pumpAndSettle();
      expect(find.text('Delete "todo.txt"?'), findsOneWidget);
      await tester.tap(dialogButton('Delete'));
      await tester.pumpAndSettle();
      expect(fs.removed, ['/home/dev/todo.txt']);
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets('Delete acts on the selection, never inside the path field',
        (tester) async {
      await pumpBrowser(tester);
      await openSheet(tester, 'notes.md');
      await tapSheetRow(tester, 'Select');
      // Clicking into the pane is what hands it the keyboard.
      await tester.tap(find.text('1 selected'));
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pumpAndSettle();
      expect(find.text('Delete "notes.md"?'), findsOneWidget);
      await tester.tap(dialogButton('Cancel'));
      await tester.pumpAndSettle();
      expect(fs.removed, isEmpty);

      // With the path field open, Delete is the field's.
      await tester.tap(find.byTooltip('Go to path (Ctrl+L)'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(fs.removed, isEmpty);
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    // ---------------------------------------------------------------- layout

    testWidgets('the new controls survive a phone-width window',
        (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await pumpBrowser(tester);
      expect(find.byTooltip('New folder'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await openSheet(tester, 'run.sh');
      expect(tester.takeException(), isNull);
      await tapSheetRow(tester, 'Permissions…');
      expect(tester.takeException(), isNull);
      await tester.tap(dialogButton('Cancel'));
      await tester.pumpAndSettle();

      await openSheet(tester, 'run.sh');
      await tapSheetRow(tester, 'Select');
      expect(find.byTooltip('Delete selected (Del)'), findsOneWidget);
      expect(find.byTooltip('Download'), findsOneWidget,
          reason: 'at this width the button keeps only its icon');
      expect(tester.takeException(), isNull);
    });
  });
}
