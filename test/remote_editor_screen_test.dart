import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/remote_entry.dart';
import 'package:secure_shell_go/screens/remote_editor_screen.dart';
import 'package:secure_shell_go/services/settings_store.dart';
import 'package:secure_shell_go/services/sftp_service.dart';
import 'package:secure_shell_go/theme.dart';

/// A remote filesystem with real contents, stat and chmod.
///
/// Its own copy rather than a shared helper, matching how every other suite
/// here builds the fake it needs (`MemoryFs`, `TreeFs`, `StubFs`): each one
/// answers only the calls its subject makes, so what a screen actually
/// touches is legible from the fake beside it.
class ScreenFs implements RemoteFileSystem, RemoteFileMetadata {
  final Map<String, Uint8List> files = {};
  final Map<String, DateTime> modified = {};
  final Map<String, int> permissions = {};
  final List<String> renamed = [];

  void put(String path, String text, {DateTime? at, int mode = 0x1A4}) {
    files[path] = Uint8List.fromList(utf8.encode(text));
    modified[path] = at ?? DateTime.utc(2026, 7, 31, 12);
    permissions[path] = mode;
  }

  String textAt(String path) => utf8.decode(files[path]!);

  @override
  Future<RemoteFileStat?> statFile(String path) async {
    final bytes = files[path];
    if (bytes == null) return null;
    return RemoteFileStat(
      size: bytes.length,
      modified: modified[path],
      permissions: permissions[path],
    );
  }

  @override
  Future<bool> setPermissions(String path, int mode) async {
    permissions[path] = mode;
    return true;
  }

  @override
  Future<int?> sizeOf(String path) async => files[path]?.length;

  @override
  Future<bool> exists(String path) async => files.containsKey(path);

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
  Future<RemoteFileWriter> openWrite(String remotePath) async =>
      ScreenWriter(this, remotePath);

  @override
  Future<void> remove(String path) async {
    files.remove(path);
    modified.remove(path);
    permissions.remove(path);
  }

  @override
  Future<void> rename(String from, String to) async {
    renamed.add('$from -> $to');
    final bytes = files.remove(from);
    if (bytes != null) files[to] = bytes;
    final when = modified.remove(from);
    if (when != null) modified[to] = when;
    final mode = permissions.remove(from);
    if (mode != null) permissions[to] = mode;
  }

  @override
  Future<List<RemoteEntry>> list(String path) async => [
        for (final entry in files.entries)
          if (_parentOf(entry.key) == path)
            RemoteEntry(
              name: entry.key.substring(entry.key.lastIndexOf('/') + 1),
              path: entry.key,
              kind: RemoteEntryKind.file,
              size: entry.value.length,
            ),
      ];

  static String _parentOf(String path) {
    final at = path.lastIndexOf('/');
    return at <= 0 ? '/' : path.substring(0, at);
  }

  @override
  Future<String> home() async => '/home/dev';

  @override
  Future<String> resolve(String path) async => path;

  @override
  Future<int> upload(
    String localPath,
    String remotePath, {
    TransferProgress? onProgress,
    CancelCheck? isCancelled,
  }) async =>
      throw UnimplementedError();

  @override
  Future<void> mkdir(String path) async => throw UnimplementedError();

  @override
  Future<void> removeDirectory(String path) async => throw UnimplementedError();

  @override
  Future<bool> isDirectory(String path) async => false;

  @override
  Future<void> close() async {}
}

class ScreenWriter implements RemoteFileWriter {
  ScreenWriter(this._fs, this._path);

  final ScreenFs _fs;
  final String _path;
  final BytesBuilder _buffer = BytesBuilder();

  @override
  Future<void> add(Uint8List chunk) async {
    _buffer.add(chunk);
    _fs.files[_path] = Uint8List.fromList(_buffer.toBytes());
    _fs.modified[_path] = DateTime.utc(2030);
    _fs.permissions[_path] = 0x1A4;
  }

  @override
  Future<void> close() async {}

  @override
  Future<void> abort() async {
    _fs.files.remove(_path);
  }
}

/// Pumps the editor behind a route, so its own `pop` has somewhere to go.
///
/// [platform] rides in on the theme because that is where the screen reads it
/// from — the field only takes the keyboard on its own where there is a
/// physical one.
Future<void> pumpEditor(
  WidgetTester tester,
  ScreenFs fs,
  List<String> paths, {
  TargetPlatform platform = TargetPlatform.android,
}) async {
  final settings = SettingsStore(file: File('/nonexistent/settings.json'));
  await tester.pumpWidget(MaterialApp(
    theme: AppTheme.dark.copyWith(platform: platform),
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () => openRemoteEditor(
            context,
            filesystem: fs,
            settingsStore: settings,
            paths: paths,
            hostLabel: 'demo',
          ),
          child: const Text('open editor'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open editor'));
  await tester.pumpAndSettle();
}

const String conf = 'server {\n  listen 80;\n}\n';

/// Holds a modifier down across [key].
Future<void> chord(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool shift = false,
}) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(key);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pumpAndSettle();
  await settleUndo(tester);
}

/// Lets the undo stack's throttled push land.
///
/// `EditableText` pushes a new undo entry through a 500ms throttle, and a
/// bare timer does not schedule a frame — so `pumpAndSettle` returns before
/// it fires and the edit that just happened is not yet undoable. Every test
/// that expects an undo to have something to undo has to wait this out.
Future<void> settleUndo(WidgetTester tester) =>
    tester.pump(const Duration(milliseconds: 600));

TextField fieldOf(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField).first);

void main() {
  testWidgets('opens a file and shows it with line numbers', (tester) async {
    final fs = ScreenFs()..put('/etc/nginx.conf', conf);
    await pumpEditor(tester, fs, ['/etc/nginx.conf']);

    expect(find.text('nginx.conf'), findsOneWidget);
    expect(find.text('demo:/etc/nginx.conf'), findsOneWidget);
    // Four lines, so a gutter numbered 1..4.
    expect(find.text('1'), findsOneWidget);
    expect(find.text('4'), findsOneWidget);
    // The mode was picked from the file name.
    expect(find.textContaining('nginx / Apache conf'), findsOneWidget);
    expect(find.textContaining('LF'), findsOneWidget);
  });

  testWidgets('refuses a binary file instead of opening it', (tester) async {
    final fs = ScreenFs();
    fs.files['/bin/thing'] =
        Uint8List.fromList([0x7F, 0x45, 0x4C, 0x46, 0, 1, 2, 3]);
    fs.modified['/bin/thing'] = DateTime.utc(2026);

    await pumpEditor(tester, fs, ['/bin/thing']);

    expect(find.textContaining('is not a text file'), findsOneWidget);
    // Nothing opened, so the editor took itself back off the stack.
    expect(find.text('open editor'), findsOneWidget);
  });

  testWidgets('typing marks the file dirty and enables save', (tester) async {
    final fs = ScreenFs()..put('/etc/nginx.conf', conf);
    await pumpEditor(tester, fs, ['/etc/nginx.conf']);

    expect(find.byTooltip('No changes to save'), findsOneWidget);
    expect(find.byTooltip('Save (Ctrl+S)'), findsNothing);

    await tester.enterText(find.byType(TextField).first, 'server {\n}\n');
    await tester.pumpAndSettle();

    expect(find.byTooltip('Save (Ctrl+S)'), findsOneWidget);
    expect(find.byTooltip('No changes to save'), findsNothing);
  });

  testWidgets('saving writes back through the temp-rename path',
      (tester) async {
    final fs = ScreenFs()..put('/etc/nginx.conf', conf);
    await pumpEditor(tester, fs, ['/etc/nginx.conf']);

    await tester.enterText(
      find.byType(TextField).first,
      'server {\n  listen 443;\n}\n',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Save (Ctrl+S)'));
    await tester.pumpAndSettle();

    expect(fs.textAt('/etc/nginx.conf'), 'server {\n  listen 443;\n}\n');
    expect(fs.renamed, hasLength(1));
    expect(fs.renamed.single, contains('.ssg-edit-'));
    expect(fs.renamed.single, endsWith('-> /etc/nginx.conf'));
    expect(find.textContaining('Saved nginx.conf'), findsOneWidget);
    // Saved, so the dirty indicator is gone.
    expect(find.byTooltip('No changes to save'), findsOneWidget);
  });

  testWidgets('a file changed on the server stops the save and asks',
      (tester) async {
    final fs = ScreenFs()..put('/etc/nginx.conf', conf);
    await pumpEditor(tester, fs, ['/etc/nginx.conf']);

    await tester.enterText(find.byType(TextField).first, 'mine\n');
    await tester.pumpAndSettle();

    // Somebody else wrote to it while it sat open.
    fs.put('/etc/nginx.conf', 'theirs\n', at: DateTime.utc(2026, 7, 31, 13));

    await tester.tap(find.byTooltip('Save (Ctrl+S)'));
    await tester.pumpAndSettle();

    expect(find.text('Changed on the server'), findsOneWidget);
    expect(fs.textAt('/etc/nginx.conf'), 'theirs\n',
        reason: 'nothing was written while the dialog is up');
    expect(fs.renamed, isEmpty);

    // "Keep mine" is what it takes to go through with it.
    await tester.tap(find.text('Keep mine'));
    await tester.pumpAndSettle();
    expect(fs.textAt('/etc/nginx.conf'), 'mine\n');
  });

  testWidgets('reload theirs throws away the local edit', (tester) async {
    final fs = ScreenFs()..put('/etc/nginx.conf', conf);
    await pumpEditor(tester, fs, ['/etc/nginx.conf']);

    await tester.enterText(find.byType(TextField).first, 'mine\n');
    await tester.pumpAndSettle();
    fs.put('/etc/nginx.conf', 'theirs\n', at: DateTime.utc(2026, 7, 31, 13));

    await tester.tap(find.byTooltip('Save (Ctrl+S)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reload theirs'));
    await tester.pumpAndSettle();

    expect(fs.textAt('/etc/nginx.conf'), 'theirs\n');
    expect(find.textContaining('Reloaded nginx.conf'), findsOneWidget);
    expect(find.byTooltip('No changes to save'), findsOneWidget);
  });

  testWidgets('leaving with unsaved changes asks first', (tester) async {
    final fs = ScreenFs()..put('/etc/nginx.conf', conf);
    await pumpEditor(tester, fs, ['/etc/nginx.conf']);

    await tester.enterText(find.byType(TextField).first, 'changed\n');
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();

    expect(find.text('Unsaved changes'), findsOneWidget);

    // Keep editing: still here, still dirty, nothing written.
    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();
    expect(find.text('nginx.conf'), findsOneWidget);
    expect(fs.textAt('/etc/nginx.conf'), conf);

    // Discard: gone, and still nothing written.
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    expect(find.text('open editor'), findsOneWidget);
    expect(fs.textAt('/etc/nginx.conf'), conf);
  });

  testWidgets('leaving without changes does not ask', (tester) async {
    final fs = ScreenFs()..put('/etc/nginx.conf', conf);
    await pumpEditor(tester, fs, ['/etc/nginx.conf']);

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('open editor'), findsOneWidget);
  });

  testWidgets('the find bar counts hits and steps through them',
      (tester) async {
    final fs = ScreenFs()..put('/etc/nginx.conf', conf);
    await pumpEditor(tester, fs, ['/etc/nginx.conf']);

    await tester.tap(find.byTooltip('Find (Ctrl+F)'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Find'), 'e');
    await tester.pumpAndSettle();

    // Two in `server`, one in `listen`.
    expect(find.text('1 of 3'), findsOneWidget);

    await tester.tap(find.byTooltip('Next'));
    await tester.pumpAndSettle();
    expect(find.text('2 of 3'), findsOneWidget);

    await tester.tap(find.byTooltip('Previous'));
    await tester.pumpAndSettle();
    expect(find.text('1 of 3'), findsOneWidget);
  });

  testWidgets('an invalid regex is reported under the field, not thrown',
      (tester) async {
    final fs = ScreenFs()..put('/etc/nginx.conf', conf);
    await pumpEditor(tester, fs, ['/etc/nginx.conf']);

    await tester.tap(find.byTooltip('Find (Ctrl+F)'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Regular expression'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Find'), '(unclosed');
    await tester.pumpAndSettle();

    // The pattern cannot compile, so it matches nothing — and says why under
    // the box instead of throwing out of the keystroke that typed it.
    expect(tester.takeException(), isNull);
    final field = tester.widget<TextField>(
      find.widgetWithText(TextField, 'Find'),
    );
    expect(field.decoration?.errorText, isNotNull);

    // Closing the bracket makes it a working search again.
    await tester.enterText(
      find.widgetWithText(TextField, 'Find'),
      'listen|server',
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final fixed = tester.widget<TextField>(
      find.widgetWithText(TextField, 'Find'),
    );
    expect(fixed.decoration?.errorText, isNull);
  });

  testWidgets('a non-UTF-8 file warns on screen and before it saves',
      (tester) async {
    final fs = ScreenFs();
    fs.files['/etc/latin.txt'] = Uint8List.fromList([0x61, 0xFF, 0x62, 0x0A]);
    fs.modified['/etc/latin.txt'] = DateTime.utc(2026, 7, 31, 12);
    fs.permissions['/etc/latin.txt'] = 0x1A4;

    await pumpEditor(tester, fs, ['/etc/latin.txt']);
    expect(find.textContaining('not valid UTF-8'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'clean\n');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Save (Ctrl+S)'));
    await tester.pumpAndSettle();

    expect(find.text('Not valid UTF-8'), findsOneWidget);
    // Backing out of the warning writes nothing.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(fs.files['/etc/latin.txt'], hasLength(4));

    await tester.tap(find.byTooltip('Save (Ctrl+S)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save anyway'));
    await tester.pumpAndSettle();
    expect(utf8.decode(fs.files['/etc/latin.txt']!), 'clean\n');
  });

  testWidgets('CRLF is preserved across a save', (tester) async {
    final fs = ScreenFs()..put('/etc/dos.conf', 'a\r\nb\r\n');
    await pumpEditor(tester, fs, ['/etc/dos.conf']);

    expect(find.textContaining('CRLF'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'a\nb\nc\n');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Save (Ctrl+S)'));
    await tester.pumpAndSettle();

    expect(fs.textAt('/etc/dos.conf'), 'a\r\nb\r\nc\r\n');
  });

  testWidgets('several files open as tabs', (tester) async {
    final fs = ScreenFs()
      ..put('/etc/nginx.conf', conf)
      ..put('/etc/hosts', '127.0.0.1 localhost\n');

    await pumpEditor(tester, fs, ['/etc/nginx.conf', '/etc/hosts']);

    // A strip appears once there is more than one, with both names on it.
    expect(find.text('nginx.conf'), findsWidgets);
    expect(find.text('hosts'), findsOneWidget);

    await tester.tap(find.text('hosts'));
    await tester.pumpAndSettle();
    expect(find.text('demo:/etc/hosts'), findsOneWidget);
  });

  testWidgets('closing a dirty tab asks before discarding it', (tester) async {
    final fs = ScreenFs()
      ..put('/etc/nginx.conf', conf)
      ..put('/etc/hosts', '127.0.0.1 localhost\n');

    await pumpEditor(tester, fs, ['/etc/nginx.conf', '/etc/hosts']);
    await tester.enterText(find.byType(TextField).first, 'edited\n');
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Close nginx.conf'));
    await tester.pumpAndSettle();

    expect(find.text('Unsaved changes'), findsOneWidget);
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();

    expect(fs.textAt('/etc/nginx.conf'), conf);
    expect(find.text('demo:/etc/hosts'), findsOneWidget);
  });

  testWidgets('an executable script keeps its mode through the editor',
      (tester) async {
    final fs = ScreenFs()
      ..put('/srv/run.sh', '#!/bin/sh\necho old\n', mode: 0x1ED);

    await pumpEditor(tester, fs, ['/srv/run.sh']);
    await tester.enterText(
      find.byType(TextField).first,
      '#!/bin/sh\necho new\n',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Save (Ctrl+S)'));
    await tester.pumpAndSettle();

    expect(fs.textAt('/srv/run.sh'), '#!/bin/sh\necho new\n');
    expect(fs.permissions['/srv/run.sh'], 0x1ED,
        reason: 'a 0644 script would no longer run');
  });

  testWidgets('the syntax mode can be overridden by hand', (tester) async {
    final fs = ScreenFs()..put('/etc/mystery', 'SELECT 1;\n');
    await pumpEditor(tester, fs, ['/etc/mystery']);

    // The status bar is the assertion target throughout: it is where the
    // active mode is actually reported, and matching on the bare label would
    // just as happily find the menu row that was tapped.
    expect(find.text('Plain text · LF'), findsOneWidget);

    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    // The mode list runs past the bottom of the menu on a short viewport.
    await tester.ensureVisible(find.text('SQL').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('SQL').last);
    await tester.pumpAndSettle();

    expect(find.text('SQL · LF'), findsOneWidget);
    expect(find.text('Plain text · LF'), findsNothing);
  });

  // ------------------------------------------------ selection and clipboard

  group('editing actions', () {
    final clipboard = <String, String?>{};

    setUp(() {
      clipboard.clear();
      // `flutter_test` answers the platform channel with null, so a copy
      // would go nowhere and a paste would come back empty. This is the
      // smallest thing that behaves like a clipboard.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        switch (call.method) {
          case 'Clipboard.setData':
            clipboard['text'] = (call.arguments as Map)['text'] as String?;
            return null;
          case 'Clipboard.getData':
            return <String, dynamic>{'text': clipboard['text']};
        }
        return null;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    Future<void> pickFromEditMenu(WidgetTester tester, String label) async {
      await tester.tap(find.byTooltip('Edit'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      await settleUndo(tester);
    }

    testWidgets('the field takes the keyboard on a desktop', (tester) async {
      final fs = ScreenFs()..put('/etc/nginx.conf', conf);
      await pumpEditor(tester, fs, ['/etc/nginx.conf'],
          platform: TargetPlatform.linux);

      // Without this, Ctrl+A on a freshly opened file does nothing at all
      // until the user thinks to click into the text first.
      expect(fieldOf(tester).focusNode?.hasFocus, isTrue);
    });

    testWidgets('on a phone it waits to be tapped', (tester) async {
      final fs = ScreenFs()..put('/etc/nginx.conf', conf);
      await pumpEditor(tester, fs, ['/etc/nginx.conf']);

      // No soft keyboard thrown up over a file the user may only be reading.
      expect(fieldOf(tester).focusNode?.hasFocus, isFalse);
    });

    testWidgets('Ctrl+A, C, X and V already work in the field',
        (tester) async {
      final fs = ScreenFs()..put('/etc/nginx.conf', conf);
      await pumpEditor(tester, fs, ['/etc/nginx.conf'],
          platform: TargetPlatform.linux);

      await chord(tester, LogicalKeyboardKey.keyA);
      expect(fieldOf(tester).controller?.selection,
          const TextSelection(baseOffset: 0, extentOffset: 24));

      await chord(tester, LogicalKeyboardKey.keyC);
      expect(clipboard['text'], conf);

      await chord(tester, LogicalKeyboardKey.keyX);
      expect(fieldOf(tester).controller?.text, isEmpty);

      await chord(tester, LogicalKeyboardKey.keyV);
      expect(fieldOf(tester).controller?.text, conf);
    });

    testWidgets('Ctrl+Z and Ctrl+Shift+Z step the undo history',
        (tester) async {
      final fs = ScreenFs()..put('/etc/nginx.conf', conf);
      await pumpEditor(tester, fs, ['/etc/nginx.conf'],
          platform: TargetPlatform.linux);
      // The file as opened is the first entry on the stack, and it lands
      // through the same throttle as everything after it — type inside that
      // window and the two edits coalesce into one.
      await settleUndo(tester);

      await tester.enterText(find.byType(TextField).first, 'rewritten\n');
      await tester.pumpAndSettle();
      await settleUndo(tester);

      await chord(tester, LogicalKeyboardKey.keyZ);
      expect(fieldOf(tester).controller?.text, conf);

      await chord(tester, LogicalKeyboardKey.keyZ, shift: true);
      expect(fieldOf(tester).controller?.text, 'rewritten\n');
    });

    testWidgets('the screen shortcuts do not swallow the editing ones',
        (tester) async {
      final fs = ScreenFs()..put('/etc/nginx.conf', conf);
      await pumpEditor(tester, fs, ['/etc/nginx.conf'],
          platform: TargetPlatform.linux);

      // The bindings the screen owns still fire...
      await chord(tester, LogicalKeyboardKey.keyF);
      expect(find.widgetWithText(TextField, 'Find'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, 'Find'), findsNothing);

      // ...and nothing they bind collides with select-all.
      await chord(tester, LogicalKeyboardKey.keyA);
      expect(fieldOf(tester).controller?.selection.isCollapsed, isFalse);
    });

    testWidgets('Select all, Copy and Paste run from the Edit menu',
        (tester) async {
      final fs = ScreenFs()..put('/etc/nginx.conf', conf);
      await pumpEditor(tester, fs, ['/etc/nginx.conf']);

      await pickFromEditMenu(tester, 'Select all');
      expect(fieldOf(tester).controller?.selection,
          const TextSelection(baseOffset: 0, extentOffset: 24));

      await pickFromEditMenu(tester, 'Copy');
      expect(clipboard['text'], conf);

      // Paste over the whole selection replaces it — and the caret lands
      // after what was pasted, not back at the top.
      await pickFromEditMenu(tester, 'Select all');
      await pickFromEditMenu(tester, 'Paste');
      expect(fieldOf(tester).controller?.text, conf);
      expect(fieldOf(tester).controller?.selection.baseOffset, conf.length);
    });

    testWidgets('Cut from the Edit menu takes the text with it',
        (tester) async {
      final fs = ScreenFs()..put('/etc/nginx.conf', conf);
      await pumpEditor(tester, fs, ['/etc/nginx.conf']);

      await pickFromEditMenu(tester, 'Select all');
      await pickFromEditMenu(tester, 'Cut');

      expect(clipboard['text'], conf);
      expect(fieldOf(tester).controller?.text, isEmpty);
      // Cut is an edit, so the file is now dirty.
      expect(find.byTooltip('Save (Ctrl+S)'), findsOneWidget);
    });

    testWidgets('Copy with nothing selected says so instead of copying',
        (tester) async {
      final fs = ScreenFs()..put('/etc/nginx.conf', conf);
      await pumpEditor(tester, fs, ['/etc/nginx.conf']);

      await pickFromEditMenu(tester, 'Copy');
      expect(find.text('Select some text first.'), findsOneWidget);
      expect(clipboard['text'], isNull);
    });

    testWidgets('Undo and Redo run from the Edit menu', (tester) async {
      final fs = ScreenFs()..put('/etc/nginx.conf', conf);
      await pumpEditor(tester, fs, ['/etc/nginx.conf'],
          platform: TargetPlatform.linux);
      await settleUndo(tester);

      await tester.enterText(find.byType(TextField).first, 'rewritten\n');
      await tester.pumpAndSettle();
      await settleUndo(tester);

      await pickFromEditMenu(tester, 'Undo');
      expect(fieldOf(tester).controller?.text, conf);

      await pickFromEditMenu(tester, 'Redo');
      expect(fieldOf(tester).controller?.text, 'rewritten\n');
    });

    testWidgets('Undo is greyed out until there is something to undo',
        (tester) async {
      final fs = ScreenFs()..put('/etc/nginx.conf', conf);
      await pumpEditor(tester, fs, ['/etc/nginx.conf'],
          platform: TargetPlatform.linux);
      await settleUndo(tester);

      await tester.tap(find.byTooltip('Edit'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<PopupMenuItem<String>>(
              find.widgetWithText(PopupMenuItem<String>, 'Undo'),
            )
            .enabled,
        isFalse,
      );
      await tester.tap(find.text('Select all'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, 'rewritten\n');
      await tester.pumpAndSettle();
      await settleUndo(tester);

      await tester.tap(find.byTooltip('Edit'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<PopupMenuItem<String>>(
              find.widgetWithText(PopupMenuItem<String>, 'Undo'),
            )
            .enabled,
        isTrue,
      );
    });

    testWidgets('the Edit menu writes the chord beside every action',
        (tester) async {
      final fs = ScreenFs()..put('/etc/nginx.conf', conf);
      await pumpEditor(tester, fs, ['/etc/nginx.conf'],
          platform: TargetPlatform.linux);

      await tester.tap(find.byTooltip('Edit'));
      await tester.pumpAndSettle();

      for (final hint in [
        'Ctrl+A',
        'Ctrl+X',
        'Ctrl+C',
        'Ctrl+V',
        'Ctrl+Z',
        'Ctrl+Shift+Z',
      ]) {
        expect(find.text(hint), findsOneWidget, reason: 'missing $hint');
      }
    });

    testWidgets('the shortcut sheet lists every binding the screen has',
        (tester) async {
      final fs = ScreenFs()..put('/etc/nginx.conf', conf);
      await pumpEditor(tester, fs, ['/etc/nginx.conf'],
          platform: TargetPlatform.linux);

      await pickFromEditMenu(tester, 'Keyboard shortcuts…');

      expect(find.text('Keyboard shortcuts'), findsOneWidget);
      for (final row in [
        'Save',
        'Find',
        'Replace',
        'Go to line',
        'Close the find bar',
        'Select all',
        'Copy',
        'Cut',
        'Paste',
        'Undo',
        'Redo',
      ]) {
        expect(find.text(row), findsOneWidget, reason: 'missing $row');
      }
      expect(find.text('Ctrl+S'), findsOneWidget);
      expect(find.text('Ctrl+G'), findsOneWidget);
      expect(find.text('Esc'), findsOneWidget);
      // One screen: nothing had to scroll to be found.
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Keyboard shortcuts'), findsNothing);
    });

    testWidgets('the app bar survives a phone-width window', (tester) async {
      // Four actions and a two-line title on the narrowest screen this ships
      // to. An overflow here is invisible in release and takes the body down
      // with it, so it is worth a test of its own.
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final fs = ScreenFs()..put('/etc/nginx/sites-available/default', conf);
      await pumpEditor(tester, fs, ['/etc/nginx/sites-available/default']);

      expect(tester.takeException(), isNull);
      expect(find.byTooltip('Edit'), findsOneWidget);

      await tester.tap(find.byTooltip('Edit'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Select all'), findsOneWidget);
    });

    testWidgets('on macOS the chords are written with Command',
        (tester) async {
      final fs = ScreenFs()..put('/etc/nginx.conf', conf);
      await pumpEditor(tester, fs, ['/etc/nginx.conf'],
          platform: TargetPlatform.macOS);

      await pickFromEditMenu(tester, 'Keyboard shortcuts…');
      expect(find.text('⌘S'), findsOneWidget);
      expect(find.text('⇧⌘Z'), findsOneWidget);
      expect(find.text('Ctrl+S'), findsNothing);
    });
  });
}
