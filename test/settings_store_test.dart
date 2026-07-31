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
      expect(settings.keepScreenAwake, isFalse);
      expect(settings.showHiddenFilesByDefault, isFalse);
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
        keepScreenAwake: true,
        showHiddenFilesByDefault: true,
        collapsedGroups: {'Work', 'Home'},
      );
      final restored = AppSettings.fromJson(settings.toJson());
      expect(restored.terminalFontSize, 20);
      expect(restored.colorScheme, TerminalColorScheme.monokai);
      expect(restored.keepScreenAwake, isTrue);
      expect(restored.showHiddenFilesByDefault, isTrue);
      expect(restored.collapsedGroups, {'Work', 'Home'});
    });

    test('fromJson falls back to defaults for missing fields', () {
      final settings = AppSettings.fromJson(const {});
      expect(settings.terminalFontSize, AppSettings.defaultFontSize);
      expect(settings.colorScheme, TerminalColorScheme.classic);
      expect(settings.collapsedGroups, isEmpty);
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
