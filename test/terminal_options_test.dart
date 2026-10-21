import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/app_settings.dart';
import 'package:secure_shell_go/screens/session_screen.dart';
import 'package:secure_shell_go/screens/settings/terminal_section.dart';
import 'package:secure_shell_go/screens/settings_screen.dart';
import 'package:secure_shell_go/screens/terminal_pane.dart';
import 'package:secure_shell_go/services/device_storage.dart';
import 'package:secure_shell_go/services/input_profile.dart';
import 'package:secure_shell_go/services/keep_awake.dart';
import 'package:secure_shell_go/services/known_hosts_service.dart';
import 'package:secure_shell_go/services/session_controller.dart';
import 'package:secure_shell_go/services/session_foreground.dart';
import 'package:secure_shell_go/services/session_manager.dart';
import 'package:secure_shell_go/services/session_recorder.dart';
import 'package:secure_shell_go/services/settings_store.dart';
import 'package:secure_shell_go/services/sftp_service.dart';
import 'package:secure_shell_go/services/ssh_service.dart';
import 'package:secure_shell_go/theme.dart';
import 'package:secure_shell_go/widgets/session_log_actions.dart';
import 'package:secure_shell_go/widgets/terminal_cursor.dart';
import 'package:secure_shell_go/widgets/terminal_find_bar.dart';
import 'package:secure_shell_go/widgets/terminal_fonts.dart';
import 'package:xterm/xterm.dart';

import 'support/fake_transport.dart';

/// A shell the test prints into.
class PrintingShell implements SSHSession {
  final _stdout = StreamController<Uint8List>.broadcast();
  final _done = Completer<void>();

  void print(String text) =>
      _stdout.add(Uint8List.fromList(utf8.encode(text)));

  @override
  Stream<Uint8List> get stdout => _stdout.stream;
  @override
  Stream<Uint8List> get stderr => const Stream.empty();
  @override
  Future<void> get done => _done.future;
  @override
  int? get exitCode => null;

  /// Everything typed into it.
  final typed = StringBuffer();
  @override
  void write(Uint8List data) => typed.write(utf8.decode(data));
  @override
  void close() {}
  @override
  void resizeTerminal(int width, int height, [int? pw, int? ph]) {}
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not faked');
}

class ShellTransport extends FakeTransportBase {
  ShellTransport() : super(host: FakeTransportBase.hostFor(label: 'Alpha'));

  final shell = PrintingShell();

  @override
  Future<SSHSession> startShell({
    required int columns,
    required int rows,
    String terminalType = 'xterm-256color',
  }) async =>
      shell;
}

class StubStorage implements DeviceStorage {
  @override
  Future<bool> ensurePermission() async => true;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not faked');
}

class EmptyFs implements RemoteFileSystem {
  @override
  Future<String> home() async => '/home/dev';
  @override
  Future<String> resolve(String path) async => path;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not faked');
}

class NoopTimer implements Timer {
  @override
  bool get isActive => false;
  @override
  int get tick => 0;
  @override
  void cancel() {}
}

class FakeForegroundChannel implements SessionForegroundChannel {
  @override
  Future<void> start(String label) async {}
  @override
  Future<void> stop() async {}
}

class NoopKeepAwake implements KeepAwakeController {
  @override
  Future<void> setEnabled(bool enabled) async {}
}

/// Android's "save as", answered by the test.
class FakeSaver implements DocumentSaver {
  final saved = <({String name, Uint8List bytes, String? mimeType})>[];
  bool cancel = false;

  @override
  Future<SavedDocument?> saveDocument({
    required String suggestedName,
    required Uint8List bytes,
    String? mimeType,
  }) async {
    if (cancel) return null;
    saved.add((name: suggestedName, bytes: bytes, mimeType: mimeType));
    return SavedDocument(displayName: suggestedName);
  }
}

/// Android's, with a limit small enough for a test to fill.
class SmallDocumentDestination extends DocumentLogDestination {
  SmallDocumentDestination(super.saver);

  @override
  int? get maxBytes => 200;
}

/// Where a test's log goes, saved without asking: a desktop's.
class FakeLogSaver implements SessionLogSaver {
  int saves = 0;

  @override
  bool get asksWhere => false;

  @override
  Future<String?> save() async {
    saves++;
    return 'test.log';
  }
}

SessionController buildSession(SessionTransport transport) =>
    SessionController(
      connection: transport,
      storage: StubStorage(),
      openFileSystem: () async => EmptyFs(),
      keepaliveScheduler: (_, _) => NoopTimer(),
    );

InputProfile profileOf(PointerDeviceKind kind, {bool keyboard = false}) {
  final profile = InputProfile()..notePointer(kind);
  if (keyboard) profile.noteHardwareKey();
  return profile;
}

void main() {
  late Directory dir;
  late SettingsStore settings;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('terminal_options_test');
    settings =
        SettingsStore(file: File('${dir.path}/${SettingsStore.fileName}'));
  });

  tearDown(() async {
    SessionLogActions.debugDestination = null;
    settings.dispose();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Future<void> use(
    WidgetTester tester,
    AppSettings Function(AppSettings s) change,
  ) =>
      tester.runAsync(() => settings.update(change));

  /// One terminal pane on its own, its shell open.
  Future<(SessionController, ShellTransport)> pumpPane(
    WidgetTester tester, {
    InputProfile? profile,
    Future<bool> Function(Uri uri)? openLink,
  }) async {
    final transport = ShellTransport();
    final session = buildSession(transport);
    addTearDown(session.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark,
      builder: (context, child) => InputProfileScope(
        profile: profile ?? profileOf(PointerDeviceKind.touch),
        child: child!,
      ),
      home: Scaffold(
        body: StreamBuilder<void>(
          stream: session.changes,
          builder: (context, _) => TerminalPane(
            session: session,
            settingsStore: settings,
            openLink: openLink,
          ),
        ),
      ),
    ));
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
    expect(session.isShellReady, isTrue);
    return (session, transport);
  }

  /// Lets real file I/O started from inside the test's fake clock finish:
  /// each step completes on the real event loop, and its callback runs on
  /// the next pump.
  Future<void> settleIo(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
  }

  Future<void> print(WidgetTester tester, ShellTransport transport,
      String text) async {
    transport.shell.print(text);
    await tester.pump();
    await tester.pump();
  }

  TerminalView view(WidgetTester tester) =>
      tester.widget<TerminalView>(find.byType(TerminalView));

  /// The middle of [cell] on screen.
  Offset centreOf(WidgetTester tester, CellOffset cell) {
    final render =
        tester.state<TerminalViewState>(find.byType(TerminalView)).renderTerminal;
    final topLeft = render.getOffset(cell);
    final size = render.cellSize;
    return render.localToGlobal(
      topLeft + Offset(size.width / 2, size.height / 2),
    );
  }

  group('settings reach the terminal', () {
    testWidgets('cursor shape, live, with xterm\'s own cursor hidden',
        (tester) async {
      await use(tester,
          (s) => s.copyWith(cursorStyle: TerminalCursorStyle.underline));
      await pumpPane(tester);

      final overlay =
          tester.widget<TerminalCursorOverlay>(find.byType(TerminalCursorOverlay));
      expect(overlay.shape, TerminalCursorStyle.underline);
      expect(view(tester).cursorType, TerminalCursorType.underline);
      expect(view(tester).theme.cursor.a, 0);
      expect(overlay.theme.cursor.a, greaterThan(0));

      await use(tester, (s) => s.copyWith(cursorStyle: TerminalCursorStyle.bar));
      await tester.pump();
      expect(
        tester
            .widget<TerminalCursorOverlay>(find.byType(TerminalCursorOverlay))
            .shape,
        TerminalCursorStyle.bar,
      );
      expect(view(tester).cursorType, TerminalCursorType.verticalBar);
    });

    testWidgets('the cursor is drawn on the row the cursor is on',
        (tester) async {
      final (session, transport) = await pumpPane(tester);
      await print(tester, transport, 'one\r\ntwo\r\nthree');
      final state = tester.state<TerminalCursorOverlayState>(
        find.byType(TerminalCursorOverlay),
      );
      final buffer = session.terminal.buffer;
      final rect = state.cursorRect!;
      final cell = centreOf(
        tester,
        CellOffset(buffer.cursorX, buffer.absoluteCursorY),
      );
      final overlayBox = tester.renderObject<RenderBox>(
        find.byType(TerminalCursorOverlay),
      );
      expect(rect.contains(overlayBox.globalToLocal(cell)), isTrue);
      expect(buffer.absoluteCursorY, 2);
    });

    testWidgets('blinking, only while the terminal has the keyboard',
        (tester) async {
      await use(tester, (s) => s.copyWith(cursorBlink: true));
      await pumpPane(tester);
      final state = tester.state<TerminalCursorOverlayState>(
        find.byType(TerminalCursorOverlay),
      );
      expect(state.blinking, isTrue);
      expect(state.blinkOn, isTrue);
      await tester.pump(TerminalCursorOverlay.blinkHalfPeriod);
      expect(state.blinkOn, isFalse);
      await tester.pump(TerminalCursorOverlay.blinkHalfPeriod);
      expect(state.blinkOn, isTrue);

      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      expect(state.blinking, isFalse);
      expect(state.blinkOn, isTrue);

      await use(tester, (s) => s.copyWith(cursorBlink: false));
      await tester.pump();
      expect(state.blinking, isFalse);
    });

    testWidgets('no blinking while the app is in the background',
        (tester) async {
      await use(tester, (s) => s.copyWith(cursorBlink: true));
      await pumpPane(tester);
      final state = tester.state<TerminalCursorOverlayState>(
        find.byType(TerminalCursorOverlay),
      );
      expect(state.blinking, isTrue);
      // On Android the terminal keeps the keyboard's focus while paused.
      for (final away in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(away);
        await tester.pump();
        expect(state.blinking, isFalse, reason: '$away');
        expect(state.blinkOn, isTrue);
      }
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(state.blinking, isTrue);
    });

    testWidgets('a block cursor covers all of a wide character',
        (tester) async {
      final (_, transport) = await pumpPane(tester);
      await print(tester, transport, 'ab');
      final state = tester.state<TerminalCursorOverlayState>(
        find.byType(TerminalCursorOverlay),
      );
      final narrow = state.cursorRect!;
      // Back onto 日, two cells wide.
      await print(tester, transport, '\r日本\r');
      final wide = state.cursorRect!;
      expect(wide.width, moreOrLessEquals(narrow.width * 2));
      expect(wide.height, narrow.height);

      // The character is drawn again inside the block, and only there.
      final paint = tester.renderObject(find.descendant(
        of: find.byType(TerminalCursorOverlay),
        matching: find.byType(CustomPaint),
      ));
      expect(paint, paints..rect(rect: wide)..clipRect(rect: wide)..paragraph());
    });

    testWidgets('a steady cursor runs no timer', (tester) async {
      await pumpPane(tester);
      final state = tester.state<TerminalCursorOverlayState>(
        find.byType(TerminalCursorOverlay),
      );
      expect(state.blinking, isFalse);
    });

    testWidgets('the bundled font, when chosen', (tester) async {
      await pumpPane(tester);
      expect(view(tester).textStyle.fontFamily, AppTheme.monoFontFamily);

      await use(
          tester, (s) => s.copyWith(terminalFont: TerminalFont.jetBrainsMono));
      await tester.pump();
      final style = view(tester).textStyle;
      expect(style.fontFamily, TerminalFonts.jetBrainsMono);
      expect(style.fontFamilyFallback, contains(AppTheme.monoFontFamily));
    });

    testWidgets('the same text style while nothing about it changes',
        (tester) async {
      final (_, transport) = await pumpPane(tester);
      final before = view(tester).textStyle;
      await print(tester, transport, 'output');
      expect(identical(view(tester).textStyle, before), isTrue);
    });

    group('the bell', () {
      late List<String> haptics;
      setUp(() => haptics = []);

      void watchHaptics(WidgetTester tester) {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method.startsWith('HapticFeedback')) {
              haptics.add(call.method);
            }
            return null;
          },
        );
        addTearDown(() => tester.binding.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null));
      }

      Finder flash(Color foreground) => find.byWidgetPredicate(
            (w) =>
                w is ColoredBox &&
                w.color.a > 0 &&
                w.color.a < 0.3 &&
                w.color.r == foreground.r &&
                w.color.g == foreground.g &&
                w.color.b == foreground.b,
          );

      testWidgets('vibrates by default', (tester) async {
        watchHaptics(tester);
        final (_, transport) = await pumpPane(tester);
        await print(tester, transport, '\x07');
        expect(haptics, ['HapticFeedback.vibrate']);
      });

      testWidgets('a burst of bells is one ring', (tester) async {
        watchHaptics(tester);
        final (_, transport) = await pumpPane(tester);
        await print(tester, transport, '\x07' * 20);
        await print(tester, transport, '\x07\x07');
        expect(haptics, hasLength(1));
        await tester.pump(const Duration(milliseconds: 300));
        await print(tester, transport, '\x07');
        expect(haptics, hasLength(2));
      });

      testWidgets('flashes the screen when asked to', (tester) async {
        watchHaptics(tester);
        await use(tester, (s) => s.copyWith(bell: TerminalBell.visual));
        final (_, transport) = await pumpPane(tester);
        final foreground =
            AppTheme.terminalThemeFor(settings.current.colorScheme).foreground;
        expect(flash(foreground), findsNothing);
        await print(tester, transport, '\x07');
        await tester.pump(const Duration(milliseconds: 50));
        expect(flash(foreground), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 300));
        expect(flash(foreground), findsNothing);
        expect(haptics, isEmpty);
      });

      testWidgets('does nothing when off', (tester) async {
        watchHaptics(tester);
        await use(tester, (s) => s.copyWith(bell: TerminalBell.off));
        final (_, transport) = await pumpPane(tester);
        await print(tester, transport, '\x07');
        await tester.pump(const Duration(milliseconds: 50));
        final foreground =
            AppTheme.terminalThemeFor(settings.current.colorScheme).foreground;
        expect(flash(foreground), findsNothing);
        expect(haptics, isEmpty);
      });
    });

    test('scrollback, for each session as it opens', () async {
      var lines = 1000;
      final manager = SessionManager(
        foreground:
            SessionForegroundController(channel: FakeForegroundChannel()),
        scrollbackLines: () => lines,
      );
      final first = manager.open(FakeTransportBase());
      lines = 50000;
      final second = manager.open(FakeTransportBase());
      expect(first.controller.terminal.maxLines, 1000);
      expect(second.controller.terminal.maxLines, 50000);
      expect(buildSession(FakeTransportBase()).terminal.maxLines,
          AppSettings.defaultScrollbackLines);
      await manager.dispose();
    });

    testWidgets('Settings has a switch for blinking', (tester) async {
      var current = const AppSettings();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => SingleChildScrollView(
              child: TerminalOptionsSection(
                settings: current,
                apply: (change) async => setState(() => current = change(current)),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('Blinking cursor'));
      await tester.pump();
      expect(current.cursorBlink, isTrue);
    });
  });

  group('the bundled font', () {
    testWidgets('ships in the app, and its licence is on the licences page',
        (tester) async {
      final regular = await tester.runAsync(
        () => rootBundle.load('assets/fonts/JetBrainsMono-Regular.ttf'),
      );
      final bold = await tester.runAsync(
        () => rootBundle.load('assets/fonts/JetBrainsMono-Bold.ttf'),
      );
      expect(regular!.lengthInBytes, greaterThan(50000));
      expect(bold!.lengthInBytes, greaterThan(50000));

      TerminalFonts.registerLicence();
      TerminalFonts.registerLicence();
      final entries = await tester.runAsync(
        () => LicenseRegistry.licenses
            .where((e) => e.packages.contains(TerminalFonts.jetBrainsMono))
            .toList(),
      );
      expect(entries, hasLength(1));
      final text = entries!.single.paragraphs.map((p) => p.text).join('\n');
      expect(text, contains('SIL OPEN FONT LICENSE Version 1.1'));
      expect(text, contains('The JetBrains Mono Project Authors'));
    });

    testWidgets('the Settings preview is drawn in it, with the cursor chosen',
        (tester) async {
      await tester.runAsync(settings.ensureLoaded);
      tester.view.physicalSize = const Size(800, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: SettingsScreen(
          settingsStore: settings,
          knownHosts: KnownHostsService(file: File('${dir.path}/kh.json')),
        ),
      ));
      await tester.pumpAndSettle();

      RichText preview() => tester.widget<RichText>(find.byWidgetPredicate(
            (w) => w is RichText && w.text.toPlainText().contains('user@host'),
          ));
      expect(preview().text.style?.fontFamily, AppTheme.monoFontFamily);

      Future<void> pick<T>(String item) async {
        await tester.tap(find.byType(DropdownButtonFormField<T>));
        await tester.pumpAndSettle();
        await tester.tap(find.text(item).last);
        await tester.pumpAndSettle();
      }

      await pick<TerminalFont>('JetBrains Mono');
      expect(preview().text.style?.fontFamily, TerminalFonts.jetBrainsMono);

      // The cursor at the end of the prompt follows the shape: a bar is
      // narrow, a block as wide as a character.
      double cursorWidth() => tester
          .getSize(find.descendant(
            of: find.byWidget(preview()),
            matching: find.byType(ColoredBox),
          ))
          .width;
      final block = cursorWidth();
      await pick<TerminalCursorStyle>('Bar');
      expect(cursorWidth(), lessThan(block / 2));
      await settleIo(tester);
    });
  });

  group('zoom', () {
    Future<void> chord(WidgetTester tester, LogicalKeyboardKey key,
        {bool shift = false}) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(key);
      if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
    }

    testWidgets('Ctrl+= / Ctrl+- / Ctrl+0, saved like a pinch',
        (tester) async {
      await pumpPane(
        tester,
        profile: profileOf(PointerDeviceKind.mouse, keyboard: true),
      );
      double size() => view(tester).textStyle.fontSize;
      expect(size(), AppSettings.defaultFontSize);

      await chord(tester, LogicalKeyboardKey.equal);
      await chord(tester, LogicalKeyboardKey.numpadAdd);
      expect(size(), AppSettings.defaultFontSize + 2);
      await settleIo(tester);
      expect(settings.current.terminalFontSize, AppSettings.defaultFontSize + 2);

      await chord(tester, LogicalKeyboardKey.minus);
      expect(size(), AppSettings.defaultFontSize + 1);

      await chord(tester, LogicalKeyboardKey.digit0);
      expect(size(), AppSettings.defaultFontSize);
      await settleIo(tester);
      expect(settings.current.terminalFontSize, AppSettings.defaultFontSize);
    });

    testWidgets('stops at the limits', (tester) async {
      await pumpPane(
        tester,
        profile: profileOf(PointerDeviceKind.mouse, keyboard: true),
      );
      for (var i = 0; i < 30; i++) {
        await chord(tester, LogicalKeyboardKey.equal);
      }
      expect(view(tester).textStyle.fontSize, AppSettings.maxFontSize);
      for (var i = 0; i < 30; i++) {
        await chord(tester, LogicalKeyboardKey.minus);
      }
      expect(view(tester).textStyle.fontSize, AppSettings.minFontSize);
      await settleIo(tester);
    });

    testWidgets('Ctrl+Shift+- is readline\'s undo, not a zoom',
        (tester) async {
      final (_, transport) = await pumpPane(
        tester,
        profile: profileOf(PointerDeviceKind.mouse, keyboard: true),
      );
      await chord(tester, LogicalKeyboardKey.minus, shift: true);
      expect(view(tester).textStyle.fontSize, AppSettings.defaultFontSize);
      // Ctrl+_, which xterm on its own sends nothing for.
      expect(transport.shell.typed.toString(), '\x1f');
    });
  });

  group('find', () {
    testWidgets('Ctrl+Shift+F, Enter, Shift+Enter, Escape', (tester) async {
      final (session, transport) = await pumpPane(
        tester,
        profile: profileOf(PointerDeviceKind.mouse, keyboard: true),
      );
      await print(tester, transport, 'one apple\r\ntwo\r\nApple pie\r\n\$ ');
      final controller = view(tester).controller!;

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      await tester.pump();
      expect(find.byType(TerminalFindBar), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'apple');
      await tester.pump();
      // Searched once typing pauses.
      expect(controller.highlights, isEmpty);
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('2 of 2'), findsOneWidget);
      // Two matches and the current one over the second.
      expect(controller.highlights, hasLength(3));

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(find.text('1 of 2'), findsOneWidget);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(find.text('2 of 2'), findsOneWidget);

      await tester.tap(find.byTooltip('Match case'));
      await tester.pump();
      expect(find.text('1 of 1'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byType(TerminalFindBar), findsNothing);
      expect(controller.highlights, isEmpty);
      expect(session.terminal.buffer.getText(), contains('Apple pie'));
    });

    testWidgets('a match up in the scrollback is scrolled into view',
        (tester) async {
      final (_, transport) = await pumpPane(
        tester,
        profile: profileOf(PointerDeviceKind.mouse, keyboard: true),
      );
      await print(
        tester,
        transport,
        'needle at the top\r\n${[for (var i = 0; i < 200; i++) 'line $i'].join('\r\n')}',
      );
      final scroll = view(tester).scrollController!;
      final bottom = scroll.position.pixels;
      expect(bottom, greaterThan(0));

      expect(TerminalPane.showFind(
        tester.widget<TerminalPane>(find.byType(TerminalPane)).session,
      ), isTrue);
      await tester.pump();
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'needle');
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('1 of 1'), findsOneWidget);
      expect(scroll.position.pixels, 0);
    });

    testWidgets('a regular expression that does not compile says so',
        (tester) async {
      final (session, _) = await pumpPane(tester);
      TerminalPane.showFind(session);
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byTooltip('Regular expression'));
      await tester.enterText(find.byType(TextField), '(oops');
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Invalid pattern'), findsOneWidget);
    });

    testWidgets('a regular expression that never finishes says so',
        (tester) async {
      final (session, transport) = await pumpPane(tester);
      await print(tester, transport, '${'a' * 59}!');
      TerminalPane.showFind(session);
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byTooltip('Regular expression'));
      await tester.enterText(find.byType(TextField), r'^(\w+\s?)+$');
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Searching…'), findsOneWidget);
      // The search runs on its own isolate, on the real clock; frames go on
      // being drawn meanwhile.
      for (var i = 0; i < 10 && find.text('Searching…').evaluate().isNotEmpty;
          i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(find.text('Pattern too slow'), findsOneWidget);
    });
  });

  group('links', () {
    const url = 'https://example.com/docs/page';

    testWidgets('Ctrl+click opens the address under the mouse',
        (tester) async {
      final opened = <Uri>[];
      final (_, transport) = await pumpPane(
        tester,
        profile: profileOf(PointerDeviceKind.mouse, keyboard: true),
        openLink: (uri) async {
          opened.add(uri);
          return true;
        },
      );
      await print(tester, transport, 'see $url.\r\n');
      final at = centreOf(tester, const CellOffset(8, 0));

      // A plain click does not.
      await tester.tapAt(at, kind: PointerDeviceKind.mouse);
      await tester.pump(const Duration(milliseconds: 400));
      expect(opened, isEmpty);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.tapAt(at, kind: PointerDeviceKind.mouse);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump(const Duration(milliseconds: 400));
      expect(opened, [Uri.parse(url)]);
    });

    testWidgets('under mouse reporting, Ctrl+click is the program\'s',
        (tester) async {
      final opened = <Uri>[];
      final (_, transport) = await pumpPane(
        tester,
        profile: profileOf(PointerDeviceKind.mouse, keyboard: true),
        openLink: (uri) async {
          opened.add(uri);
          return true;
        },
      );
      // tmux with `set -g mouse on`.
      await print(tester, transport, 'see $url.\r\n\x1b[?1000h\x1b[?1006h');
      final at = centreOf(tester, const CellOffset(8, 0));

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.tapAt(at, kind: PointerDeviceKind.mouse);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump(const Duration(milliseconds: 400));
      expect(opened, isEmpty);
      // The click went to the program, as a mouse report.
      expect(transport.shell.typed.toString(), contains('\x1b[<'));

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.tapAt(at, kind: PointerDeviceKind.mouse);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump(const Duration(milliseconds: 400));
      expect(opened, [Uri.parse(url)]);
    });

    testWidgets('right-click on an address offers to open or copy it',
        (tester) async {
      final opened = <Uri>[];
      final (_, transport) = await pumpPane(
        tester,
        profile: profileOf(PointerDeviceKind.mouse, keyboard: true),
        openLink: (uri) async {
          opened.add(uri);
          return true;
        },
      );
      await print(tester, transport, '$url\r\n');
      await tester.tapAt(
        centreOf(tester, const CellOffset(3, 0)),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      expect(find.text('Open link'), findsOneWidget);
      expect(find.text('Find…'), findsOneWidget);
      await tester.tap(find.text('Open link'));
      await tester.pumpAndSettle();
      expect(opened, [Uri.parse(url)]);
    });

    testWidgets('a long press on an address opens its menu', (tester) async {
      final opened = <Uri>[];
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));
      final (session, transport) = await pumpPane(
        tester,
        openLink: (uri) async {
          opened.add(uri);
          return true;
        },
      );
      // Wrapped across two rows of the terminal.
      final width = session.terminal.viewWidth;
      final long = 'https://example.com/${'p' * width}';
      await print(tester, transport, '$long\r\n');
      final onSecondRow = centreOf(tester, const CellOffset(2, 1));

      await tester.longPressAt(onSecondRow);
      await tester.pumpAndSettle();
      expect(find.text('Open link'), findsOneWidget);
      expect(find.text('Copy link'), findsOneWidget);
      // The long-press made no text selection behind the menu.
      expect(view(tester).controller!.selection, isNull);

      await tester.tap(find.text('Copy link'));
      await tester.pumpAndSettle();
      expect(copied, long);

      await tester.longPressAt(onSecondRow);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open link'));
      await tester.pumpAndSettle();
      expect(opened, [Uri.parse(long)]);
    });

    testWidgets('a long press elsewhere still selects text', (tester) async {
      final (_, transport) = await pumpPane(tester);
      await print(tester, transport, 'plain words here\r\n');
      await tester.longPressAt(centreOf(tester, const CellOffset(1, 0)));
      await tester.pumpAndSettle();
      expect(find.text('Open link'), findsNothing);
      expect(view(tester).controller!.selection, isNotNull);
    });

    testWidgets('nothing but http and https is offered', (tester) async {
      final (_, transport) = await pumpPane(
        tester,
        openLink: (uri) async => fail('opened $uri'),
      );
      await print(tester, transport, 'file:///etc/passwd\r\n');
      await tester.longPressAt(centreOf(tester, const CellOffset(4, 0)));
      await tester.pumpAndSettle();
      expect(find.text('Open link'), findsNothing);
    });
  });

  group('the session log', () {
    late FakeSaver saver;

    setUp(() {
      saver = FakeSaver();
      SessionLogActions.debugDestination = DocumentLogDestination(saver);
    });

    SessionManager newManager() => SessionManager(
          foreground:
              SessionForegroundController(channel: FakeForegroundChannel()),
          createController: (connection, resolve, resolveCreds) =>
              buildSession(connection),
        );

    Widget screenFor(SessionManager manager) => MaterialApp(
          theme: AppTheme.dark,
          builder: (context, child) => InputProfileScope(
            profile: profileOf(PointerDeviceKind.touch),
            child: child!,
          ),
          home: SessionsScreen(
            sessions: manager,
            settingsStore: settings,
            keepAwake: NoopKeepAwake(),
          ),
        );

    Future<(SessionManager, ShellTransport)> pumpScreen(
        WidgetTester tester) async {
      final transport = ShellTransport();
      final manager = newManager();
      addTearDown(manager.dispose);
      manager.open(transport);
      // A phone, so the terminal has the page to itself.
      tester.view.physicalSize = const Size(412, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(screenFor(manager));
      for (var i = 0; i < 5; i++) {
        await tester.pump();
      }
      return (manager, transport);
    }

    Future<void> menu(WidgetTester tester, String item) async {
      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(item));
      await tester.pumpAndSettle();
    }

    testWidgets('find from the session menu', (tester) async {
      await pumpScreen(tester);
      await menu(tester, 'Find in terminal');
      expect(find.byType(TerminalFindBar), findsOneWidget);
    });

    testWidgets('recorded from the menu, saved as plain text when stopped',
        (tester) async {
      final (_, transport) = await pumpScreen(tester);
      await print(tester, transport, 'before\r\n');

      await menu(tester, 'Record session log…');
      expect(find.text('Record session log'), findsOneWidget);
      await tester.tap(find.text('Start'));
      await tester.pumpAndSettle();
      expect(find.text('REC'), findsOneWidget);

      await print(tester, transport, '\x1b[32mgreen\x1b[0m\r\n\$ ');
      await menu(tester, 'Stop recording and save');
      expect(find.text('REC'), findsNothing);

      final log = utf8.decode(saver.saved.single.bytes);
      expect(saver.saved.single.name, endsWith('.log'));
      expect(saver.saved.single.mimeType, 'text/plain');
      expect(log, startsWith('Session log for dev@example.com, started '));
      expect(log, contains('\ngreen\n\$\n'));
      expect(log, isNot(contains('before')));
      expect(log, isNot(contains('\x1b')));
      expect(log.trimRight(), matches(RegExp(r'Session log ended [\d: -]+$')));
      expect(find.textContaining('Session log saved'), findsOneWidget);
    });

    testWidgets('as received, escapes and all', (tester) async {
      final (_, transport) = await pumpScreen(tester);
      await menu(tester, 'Record session log…');
      await tester.tap(find.text('Plain text'));
      await tester.pump();
      await tester.tap(find.text('Start'));
      await tester.pumpAndSettle();
      await print(tester, transport, '\x1b[32mgreen\x1b[0m\r\n');
      // Stopped from the badge on the terminal this time.
      await tester.tap(find.text('REC'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Stop recording and save'));
      await tester.pumpAndSettle();
      expect(
        utf8.decode(saver.saved.single.bytes),
        contains('\x1b[32mgreen\x1b[0m\r\n'),
      );
    });

    testWidgets('backing out of the picker leaves a way to save it',
        (tester) async {
      final (_, transport) = await pumpScreen(tester);
      await menu(tester, 'Record session log…');
      await tester.tap(find.text('Start'));
      await tester.pumpAndSettle();
      await print(tester, transport, 'kept\r\n');
      saver.cancel = true;
      await menu(tester, 'Stop recording and save');
      expect(saver.saved, isEmpty);
      expect(find.textContaining('was not saved'), findsOneWidget);

      saver.cancel = false;
      await tester.tap(find.text('Save…'));
      await tester.pumpAndSettle();
      expect(utf8.decode(saver.saved.single.bytes), contains('kept'));
    });

    testWidgets('closing the session saves its log first', (tester) async {
      final (manager, transport) = await pumpScreen(tester);
      await menu(tester, 'Record session log…');
      await tester.tap(find.text('Start'));
      await tester.pumpAndSettle();
      await print(tester, transport, 'last words\r\n');

      await tester.tap(find.byTooltip('Disconnect'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Its session log will be saved first'),
          findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Disconnect'));
      await tester.pumpAndSettle();
      expect(utf8.decode(saver.saved.single.bytes), contains('last words'));
      expect(manager.isEmpty, isTrue);
    });

    testWidgets('a log file that cannot be written says so', (tester) async {
      // Opens, and then every write fails: a full disk.
      final full = Link('${dir.path}/full.log');
      await tester.runAsync(() => full.create('/dev/full'));
      SessionLogActions.debugDestination =
          FileLogDestination(choose: (_) async => full.path);
      final (_, transport) = await pumpScreen(tester);
      await menu(tester, 'Record session log…');
      await tester.tap(find.text('Choose file…'));
      await tester.pumpAndSettle();
      expect(find.text('REC'), findsOneWidget);

      await print(tester, transport, 'output\r\n');
      await settleIo(tester);
      await tester.pumpAndSettle();
      expect(find.text('REC'), findsNothing);
      expect(find.textContaining('it could not be written'), findsOneWidget);
    }, skip: !File('/dev/full').existsSync());

    testWidgets('a log that fills up on screen asks where to save it',
        (tester) async {
      SessionLogActions.debugDestination = SmallDocumentDestination(saver);
      final (_, transport) = await pumpScreen(tester);
      await menu(tester, 'Record session log…');
      await tester.tap(find.text('Start'));
      await tester.pumpAndSettle();
      await print(tester, transport, '${'x' * 300}\r\n');
      await tester.pumpAndSettle();
      expect(find.text('REC'), findsNothing);
      expect(saver.saved.single.bytes, hasLength(200));
      expect(find.textContaining('The session log is full'), findsOneWidget);
      expect(find.textContaining('Session log saved'), findsOneWidget);
    });

    testWidgets('a log that fills up off screen is kept, and offered back',
        (tester) async {
      SessionLogActions.debugDestination = SmallDocumentDestination(saver);
      final (manager, transport) = await pumpScreen(tester);
      await menu(tester, 'Record session log…');
      await tester.tap(find.text('Start'));
      await tester.pumpAndSettle();

      // Back to the host list: the session runs on with nothing showing it.
      await tester.pumpWidget(const MaterialApp(home: Scaffold()));
      await print(tester, transport, '${'x' * 300}\r\n');
      final terminal = manager.sessions.single.controller.terminal;
      expect(terminal.isRecording, isFalse);
      final ending = terminal.unannounced.single;
      expect(ending.isSettled, isTrue);
      expect(ending.needsSaving, isTrue);
      expect(saver.saved, isEmpty);

      await tester.pumpWidget(screenFor(manager));
      await tester.pumpAndSettle();
      expect(find.textContaining('The session log is full'), findsOneWidget);
      expect(terminal.unannounced, isEmpty);
      await tester.tap(find.text('Save…'));
      await tester.pumpAndSettle();
      expect(saver.saved.single.bytes, hasLength(200));
      expect(
        utf8.decode(saver.saved.single.bytes),
        startsWith('Session log for dev@example.com'),
      );
    });

    test('one that fills up with nothing on screen is finished and saved',
        () async {
      final manager = newManager();
      addTearDown(manager.dispose);
      final terminal = manager.open(ShellTransport()).controller.terminal;
      final logSaver = FakeLogSaver();
      final sink = MemoryLogSink();
      terminal.startRecording(SessionRecorder(
        sink: sink,
        plainText: false,
        maxBytes: 10,
        saver: logSaver,
      ));
      terminal.write('more than ten bytes');
      final ending = terminal.unannounced.single;
      await ending.settled.timeout(const Duration(seconds: 5));
      expect(logSaver.saves, 1);
      expect(ending.savedAs, 'test.log');
      expect(sink.length, 10);
    });

    test('the app closing finishes a running log, and saves it', () async {
      final manager = newManager();
      final terminal = manager.open(ShellTransport()).controller.terminal;
      final file = File('${dir.path}/closing.log');
      final logSaver = FakeLogSaver();
      terminal.startRecording(
        SessionRecorder(sink: FileLogSink(file), saver: logSaver),
      );
      terminal.write('last words\r\nhalf a li');
      await manager.dispose();
      expect(logSaver.saves, 1);
      final log = await file.readAsString();
      expect(log, startsWith('last words\nhalf a li\n'));
      expect(log.trimRight(), matches(RegExp(r'Session log ended [\d: -]+$')));
    });

    test('.log is added without replacing a file nobody was asked about',
        () async {
      final taken = File('${dir.path}/notes.log')..writeAsStringSync('keep me');
      Future<String> named(String path) =>
          FileLogDestination.withLogExtension('${dir.path}/$path');
      expect(await named('notes'), '${dir.path}/notes (1).log');
      File('${dir.path}/notes (1).log').writeAsStringSync('');
      expect(await named('notes'), '${dir.path}/notes (2).log');
      expect(await named('fresh'), '${dir.path}/fresh.log');
      // An extension the user typed is theirs, replace and all: the dialog
      // asked about that one.
      expect(await named('notes.log'), '${dir.path}/notes.log');

      final sink = await FileLogDestination(
        choose: (_) async => '${dir.path}/notes',
      ).open('suggested.log');
      expect((sink! as FileLogSink).file.path, '${dir.path}/notes (2).log');
      await sink.close();
      expect(taken.readAsStringSync(), 'keep me');
    });
  });
}
