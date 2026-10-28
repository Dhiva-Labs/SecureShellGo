import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/l10n/l10n.dart';
import 'package:secure_shell_go/models/app_settings.dart';
import 'package:secure_shell_go/screens/settings/language_section.dart';
import 'package:secure_shell_go/screens/settings/editor_section.dart';
import 'package:secure_shell_go/screens/settings_screen.dart';
import 'package:secure_shell_go/services/known_hosts_service.dart';
import 'package:secure_shell_go/services/settings_store.dart';

import 'support/temp_dir.dart';

/// The settings added for 1.5 — terminal options, the extra keys row, the
/// editor's text size and the diagnostics log — each reach the store from
/// the screen.
void main() {
  late Directory dir;
  late SettingsStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('settings_sections_test');
    store = SettingsStore(file: File('${dir.path}/settings.json'));
  });

  tearDown(() async {
    store.dispose();
    await deleteTempDir(dir);
  });

  Future<void> pumpSettings(WidgetTester tester) async {
    await tester.runAsync(store.ensureLoaded);
    // Tall enough to build every section: a ListView makes nothing off
    // screen, and a finder cannot tap what was never built.
    tester.view.physicalSize = const Size(800, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: SettingsScreen(
        settingsStore: store,
        knownHosts: KnownHostsService(file: File('${dir.path}/kh.json')),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> pick<T>(WidgetTester tester, String item) async {
    await tester.tap(find.byType(DropdownButtonFormField<T>));
    await tester.pumpAndSettle();
    await tester.tap(find.text(item).last);
    await tester.pumpAndSettle();
  }

  testWidgets('each new choice is saved', (tester) async {
    await pumpSettings(tester);

    await pick<TerminalFont>(tester, 'JetBrains Mono');
    await pick<TerminalCursorStyle>(tester, 'Bar');
    await pick<TerminalBell>(tester, 'Flash the screen');
    await pick<int>(tester, '50,000 lines');
    await pick<KeyBarMode>(tester, 'Never');
    await tester.tap(find.text('Keep a diagnostics log'));
    await tester.pumpAndSettle();

    final saved = store.current;
    expect(saved.terminalFont, TerminalFont.jetBrainsMono);
    expect(saved.cursorStyle, TerminalCursorStyle.bar);
    expect(saved.bell, TerminalBell.visual);
    expect(saved.scrollbackLines, 50000);
    expect(saved.keyBarMode, KeyBarMode.never);
    expect(saved.diagnosticsLog, isTrue, reason: 'off by default, so on');

    // And it is on disk, not just in memory. The writes run on the real
    // event loop and finish on the test's clock, so both have to turn.
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    await tester.runAsync(() async {
      final reloaded = SettingsStore(file: File('${dir.path}/settings.json'));
      await reloaded.ensureLoaded();
      expect(reloaded.current.toJson(), saved.toJson());
      reloaded.dispose();
    });
  });

  testWidgets('the extra keys row explains the choice made', (tester) async {
    await pumpSettings(tester);
    expect(find.textContaining('Hidden while a hardware keyboard'),
        findsOneWidget);
    await pick<KeyBarMode>(tester, 'Never');
    expect(find.textContaining('need a hardware keyboard'), findsOneWidget);
  });

  testWidgets('the editor text size is saved when the slider is let go',
      (tester) async {
    await pumpSettings(tester);
    final slider = find.descendant(
      of: find.byType(EditorSettingsSection),
      matching: find.byType(Slider),
    );
    final before = store.current.editorFontSize;

    await tester.drag(slider, const Offset(200, 0));
    await tester.pumpAndSettle();

    expect(store.current.editorFontSize, greaterThan(before));
    expect(store.current.terminalFontSize, AppSettings.defaultFontSize,
        reason: 'the terminal keeps its own size');
  });

  testWidgets('a language picked in Settings is saved, and cleared again',
      (tester) async {
    await pumpSettings(tester);
    await pick<String>(tester, '日本語');
    expect(store.current.localeOverride, 'ja');
    await pick<String>(tester, 'Same as this device');
    expect(store.current.localeOverride, isNull);
  });

  testWidgets('the screen speaks the chosen language', (tester) async {
    await tester.pumpWidget(MaterialApp(
      locale: localeForTag('ja'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: LanguageSettingsSection(
          settings: const AppSettings(localeOverride: 'ja'),
          apply: (_) async {},
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('言語'), findsOneWidget);
    expect(find.text('日本語'), findsOneWidget);
  });

  test('every language offered has a translation, and unknown tags follow '
      'the device', () {
    final supported = {
      for (final l in AppLocalizations.supportedLocales) l.languageCode,
    };
    for (final language in appLanguages) {
      expect(supported, contains(language.tag), reason: language.name);
    }
    expect(localeForTag('xx'), isNull);
    expect(localeForTag(null), isNull);
  });
}
