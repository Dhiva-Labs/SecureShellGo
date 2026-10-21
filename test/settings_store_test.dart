import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/app_settings.dart';
import 'package:secure_shell_go/services/settings_store.dart';

void main() {
  late Directory tempDir;
  late File storeFile;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('settings_store_test');
    storeFile = File('${tempDir.path}/settings.json');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  group('AppSettings', () {
    test('defaults match the documented range', () {
      const settings = AppSettings();
      expect(settings.terminalFontSize, AppSettings.defaultFontSize);
      expect(settings.colorScheme, TerminalColorScheme.classic);
      expect(settings.uiStyle, UiStyle.aurora);
      expect(settings.themeBrightness, ThemeBrightness.dark);
      expect(settings.keepScreenAwake, isFalse);
      expect(settings.showHiddenFilesByDefault, isFalse);
      expect(settings.diagnosticsLog, isFalse,
          reason: 'the diagnostics log is opt-in');
    });

    test('clampFontSize keeps values inside min/max', () {
      expect(AppSettings.clampFontSize(1), AppSettings.minFontSize);
      expect(AppSettings.clampFontSize(999), AppSettings.maxFontSize);
      expect(AppSettings.clampFontSize(16), 16);
    });

    test('copyWith clamps an out-of-range font size rather than storing it',
        () {
      const settings = AppSettings();
      expect(
        settings.copyWith(terminalFontSize: 2).terminalFontSize,
        AppSettings.minFontSize,
      );
      expect(
        settings.copyWith(terminalFontSize: 100).terminalFontSize,
        AppSettings.maxFontSize,
      );
    });

    test('copyWith leaves untouched fields alone', () {
      const settings = AppSettings(keepScreenAwake: true);
      final next = settings.copyWith(terminalFontSize: 18);
      expect(next.terminalFontSize, 18);
      expect(next.keepScreenAwake, isTrue);
    });

    test('toJson/fromJson round-trips every field', () {
      const settings = AppSettings(
        terminalFontSize: 20,
        colorScheme: TerminalColorScheme.monokai,
        uiStyle: UiStyle.gcp,
        themeBrightness: ThemeBrightness.light,
        keepScreenAwake: true,
        showHiddenFilesByDefault: true,
        collapsedGroups: {'Work', 'Home'},
      );
      final restored = AppSettings.fromJson(settings.toJson());
      expect(restored.terminalFontSize, 20);
      expect(restored.colorScheme, TerminalColorScheme.monokai);
      expect(restored.uiStyle, UiStyle.gcp);
      expect(restored.themeBrightness, ThemeBrightness.light);
      expect(restored.keepScreenAwake, isTrue);
      expect(restored.showHiddenFilesByDefault, isTrue);
      expect(restored.collapsedGroups, {'Work', 'Home'});
    });

    test('every UiStyle x ThemeBrightness combination round-trips through '
        'JSON by name', () {
      for (final style in UiStyle.values) {
        for (final brightness in ThemeBrightness.values) {
          final settings = AppSettings(
            uiStyle: style,
            themeBrightness: brightness,
          );
          final restored = AppSettings.fromJson(settings.toJson());
          expect(restored.uiStyle, style);
          expect(restored.themeBrightness, brightness);
        }
      }
    });

    test('fromJson falls back to defaults for missing fields', () {
      final settings = AppSettings.fromJson(const {});
      expect(settings.terminalFontSize, AppSettings.defaultFontSize);
      expect(settings.colorScheme, TerminalColorScheme.classic);
      expect(settings.uiStyle, UiStyle.aurora);
      expect(settings.themeBrightness, ThemeBrightness.dark);
      expect(settings.collapsedGroups, isEmpty);
    });

    test('settings.json written before v1.4.0 (no uiStyle/themeBrightness '
        'keys) loads as aurora + dark — today\'s only look — not some other '
        'style the user never chose', () {
      final settings = AppSettings.fromJson(const {
        'version': 1,
        'terminalFontSize': 14.0,
        'colorScheme': 'classic',
        'keepScreenAwake': false,
        'showHiddenFilesByDefault': false,
        'collapsedGroups': ['Work'],
        'appLockEnabled': false,
        'appLockTimeout': 'oneMinute',
      });
      expect(settings.uiStyle, UiStyle.aurora);
      expect(settings.themeBrightness, ThemeBrightness.dark);
      // Confirms this is genuinely a partial-JSON test, not just defaults:
      // every field that *was* present is still honoured.
      expect(settings.collapsedGroups, {'Work'});
    });

    test('fromJson falls back to aurora/dark for unrecognised uiStyle or '
        'themeBrightness ids', () {
      final settings = AppSettings.fromJson(const {
        'uiStyle': 'not-a-real-style',
        'themeBrightness': 'not-a-real-brightness',
      });
      expect(settings.uiStyle, UiStyle.aurora);
      expect(settings.themeBrightness, ThemeBrightness.dark);
    });

    test('settings.json written before v1.3.0 (no collapsedGroups key) '
        'loads with nothing collapsed', () {
      final settings = AppSettings.fromJson(const {
        'version': 1,
        'terminalFontSize': 14.0,
        'colorScheme': 'classic',
        'keepScreenAwake': false,
        'showHiddenFilesByDefault': false,
      });
      expect(settings.collapsedGroups, isEmpty);
    });

    test('copyWith replaces collapsedGroups wholesale, not merged', () {
      const settings = AppSettings(collapsedGroups: {'Work'});
      final next = settings.copyWith(collapsedGroups: {'Home'});
      expect(next.collapsedGroups, {'Home'});
    });

    test('fromJson falls back to classic for an unknown colour scheme name',
        () {
      final settings =
          AppSettings.fromJson(const {'colorScheme': 'not-a-real-scheme'});
      expect(settings.colorScheme, TerminalColorScheme.classic);
    });

    test('fromJson clamps a font size that was persisted out of range', () {
      final settings =
          AppSettings.fromJson(const {'terminalFontSize': 999});
      expect(settings.terminalFontSize, AppSettings.maxFontSize);
    });

    test('every new colour scheme round-trips through JSON by name', () {
      for (final scheme in TerminalColorScheme.values) {
        final settings = AppSettings(colorScheme: scheme);
        final restored = AppSettings.fromJson(settings.toJson());
        expect(restored.colorScheme, scheme);
      }
    });
  });

  group('the 1.5 settings', () {
    test('a settings.json from before 1.5 reads as what the app did then',
        () {
      final restored = AppSettings.fromJson(const {
        'terminalFontSize': 16,
        'colorScheme': 'nord',
      });
      expect(restored.scrollbackLines, 10000);
      expect(restored.cursorStyle, TerminalCursorStyle.block);
      expect(restored.cursorBlink, isFalse);
      expect(restored.bell, TerminalBell.vibrate);
      expect(restored.terminalFont, TerminalFont.system);
      expect(restored.keyBarMode, KeyBarMode.auto);
      expect(restored.diagnosticsLog, isFalse,
          reason: 'the diagnostics log is opt-in');
      expect(restored.localeOverride, isNull);
      expect(restored.editorFontSize, 16,
          reason: 'the editor followed the terminal size until it had one');
    });

    test('every new field round-trips through JSON', () {
      const settings = AppSettings(
        scrollbackLines: 50000,
        cursorStyle: TerminalCursorStyle.bar,
        cursorBlink: true,
        bell: TerminalBell.visual,
        terminalFont: TerminalFont.jetBrainsMono,
        keyBarMode: KeyBarMode.never,
        editorFontSize: 18,
        diagnosticsLog: true,
        localeOverride: 'pt-BR',
      );
      final restored = AppSettings.fromJson(settings.toJson());
      expect(restored.scrollbackLines, 50000);
      expect(restored.cursorStyle, TerminalCursorStyle.bar);
      expect(restored.cursorBlink, isTrue);
      expect(restored.bell, TerminalBell.visual);
      expect(restored.terminalFont, TerminalFont.jetBrainsMono);
      expect(restored.keyBarMode, KeyBarMode.never);
      expect(restored.editorFontSize, 18);
      expect(restored.diagnosticsLog, isTrue);
      expect(restored.localeOverride, 'pt-BR');
    });

    test('out-of-range or unknown values fall back instead of failing', () {
      final restored = AppSettings.fromJson(const {
        'scrollbackLines': 3,
        'cursorStyle': 'blob',
        'bell': 'klaxon',
        'terminalFont': 'comic',
        'keyBarMode': 'sometimes',
        'editorFontSize': 400,
        'localeOverride': ' ',
      });
      expect(restored.scrollbackLines, AppSettings.defaultScrollbackLines);
      expect(restored.cursorStyle, TerminalCursorStyle.block);
      expect(restored.bell, TerminalBell.vibrate);
      expect(restored.terminalFont, TerminalFont.system);
      expect(restored.keyBarMode, KeyBarMode.auto);
      expect(restored.editorFontSize, AppSettings.maxEditorFontSize);
      expect(restored.localeOverride, isNull);
      expect(const AppSettings().copyWith(scrollbackLines: 7).scrollbackLines,
          AppSettings.defaultScrollbackLines);
    });

    test('the language can be set and cleared, and copyWith keeps it', () {
      final set = const AppSettings().withLocaleOverride('ja');
      expect(set.localeOverride, 'ja');
      expect(set.copyWith(cursorBlink: true).localeOverride, 'ja');
      final cleared = set.withLocaleOverride(null);
      expect(cleared.localeOverride, isNull);
      expect(cleared.toJson().containsKey('localeOverride'), isFalse);
      // Clearing it leaves everything else as it was.
      final busy = const AppSettings(
        bell: TerminalBell.off,
        editorFontSize: 20,
        appLockEnabled: true,
      ).withLocaleOverride('de');
      expect(busy.withLocaleOverride(null).toJson(),
          {...busy.toJson()}..remove('localeOverride'));
    });
  });

  group('SettingsStore', () {
    test('a fresh store reads as defaults before and after loading', () {
      final store = SettingsStore(file: storeFile);
      expect(store.current.terminalFontSize, AppSettings.defaultFontSize);
    });

    test('ensureLoaded on a store with no file on disk keeps the defaults',
        () async {
      final store = SettingsStore(file: storeFile);
      await store.ensureLoaded();
      expect(store.current, isA<AppSettings>());
      expect(store.current.colorScheme, TerminalColorScheme.classic);
    });

    test('save persists settings that survive a reload', () async {
      final store = SettingsStore(file: storeFile);
      await store.save(
        const AppSettings(
          terminalFontSize: 18,
          colorScheme: TerminalColorScheme.retroGreen,
          keepScreenAwake: true,
        ),
      );

      final reloaded = SettingsStore(file: storeFile);
      await reloaded.ensureLoaded();
      expect(reloaded.current.terminalFontSize, 18);
      expect(reloaded.current.colorScheme, TerminalColorScheme.retroGreen);
      expect(reloaded.current.keepScreenAwake, isTrue);
    });

    test('a newly added colour scheme and font size survive a reload',
        () async {
      final store = SettingsStore(file: storeFile);
      await store.save(
        const AppSettings(
          terminalFontSize: 16,
          colorScheme: TerminalColorScheme.dracula,
        ),
      );

      final reloaded = SettingsStore(file: storeFile);
      await reloaded.ensureLoaded();
      expect(reloaded.current.terminalFontSize, 16);
      expect(reloaded.current.colorScheme, TerminalColorScheme.dracula);
    });

    test('update applies a partial change on top of the current settings',
        () async {
      final store = SettingsStore(file: storeFile);
      await store.save(const AppSettings(keepScreenAwake: true));

      await store.update((s) => s.copyWith(terminalFontSize: 22));

      expect(store.current.terminalFontSize, 22);
      expect(store.current.keepScreenAwake, isTrue);
    });

    test('changes emits every saved value', () async {
      final store = SettingsStore(file: storeFile);
      final expectation = expectLater(
        store.changes.map((s) => s.terminalFontSize),
        emitsInOrder([14, 20]),
      );

      await store.update((s) => s.copyWith(terminalFontSize: 14));
      await store.update((s) => s.copyWith(terminalFontSize: 20));

      await expectation;
    });

    test('a corrupt store falls back to defaults instead of failing', () async {
      await storeFile.writeAsString('{ not json');
      final store = SettingsStore(file: storeFile);
      await store.ensureLoaded();
      expect(store.current.terminalFontSize, AppSettings.defaultFontSize);
      expect(store.current.diagnosticsLog, isFalse,
          reason: 'an unreadable file must not turn logging on');
    });

    test('concurrent ensureLoaded calls share one load', () async {
      await storeFile.writeAsString(
        jsonEncode(const AppSettings(terminalFontSize: 15).toJson()),
      );
      final store = SettingsStore(file: storeFile);
      await Future.wait([store.ensureLoaded(), store.ensureLoaded()]);
      expect(store.current.terminalFontSize, 15);
    });
  });
}
