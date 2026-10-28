import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/l10n/l10n.dart';
import 'package:secure_shell_go/models/app_settings.dart';
import 'package:secure_shell_go/screens/settings_screen.dart';
import 'package:secure_shell_go/services/app_lock.dart';
import 'package:secure_shell_go/services/app_lock_controller.dart';
import 'package:secure_shell_go/services/host_store.dart';
import 'package:secure_shell_go/services/known_hosts_service.dart';
import 'package:secure_shell_go/services/settings_store.dart';
import 'package:secure_shell_go/services/tunnel_runtime.dart';
import 'package:secure_shell_go/services/tunnel_store.dart';

class _Available implements AppLockAuthenticator {
  @override
  Future<AppLockSupport> support() async => AppLockSupport.available;
  @override
  Future<AppLockOutcome> authenticate({required String reason}) async =>
      AppLockOutcome.cancelled;
  @override
  Future<void> setSecureDisplay(bool enabled) async {}
}

/// Settings in French, top to bottom: every row the screen can show, in
/// French, and none of them left in English.
void main() {
  late Directory dir;
  late SettingsStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('settings_l10n_test');
    store = SettingsStore(file: File('${dir.path}/settings.json'));
  });

  tearDown(() async {
    store.dispose();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  testWidgets('Settings speaks French when French is installed',
      (tester) async {
    final hosts = HostStore(file: File('${dir.path}/hosts.json'));
    final tunnels = TunnelRuntime(
      profiles: TunnelStore(file: File('${dir.path}/tunnels.json')),
      support: TunnelSupport(
        lookupHost: hosts.get,
        loadCredentials: (id) async => null,
      ),
    );
    addTearDown(tunnels.dispose);
    // Everything that adds rows switched on, so every row is built.
    await tester.runAsync(() async {
      await store.ensureLoaded();
      await store.save(const AppSettings(
        appLockEnabled: true,
        diagnosticsLog: true,
      ));
    });
    tester.view.physicalSize = const Size(800, 6000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      locale: const Locale('fr'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: SettingsScreen(
        settingsStore: store,
        knownHosts: KnownHostsService(file: File('${dir.path}/kh.json')),
        appLock: AppLockController(authenticator: _Available()),
        tunnels: tunnels,
        hostStore: hosts,
      ),
    ));
    await tester.pumpAndSettle();

    final fr = lookupAppLocalizations(const Locale('fr'));
    // Spelled out once, so a screen that silently fell back to English, or
    // a lost translation, cannot pass by comparing English with English.
    expect(find.text('Paramètres'), findsOneWidget);
    expect(find.text('Hôtes connus'), findsOneWidget);
    expect(find.text(fr.settingsBrightnessSystem), findsOneWidget);
    expect(find.text(fr.settingsLockAfterMinutes(5)), findsOneWidget);
    expect(find.text(fr.settingsAbout('SecureShell Go')), findsOneWidget);
    // Numbers are grouped the French way: 10 000, not 10,000.
    final lines = fr.settingsScrollbackLines(10000);
    expect(find.text(lines), findsOneWidget);
    expect(lines, isNot(contains('10,000')));

    // Nothing on the screen is an English string French says differently.
    Map<String, dynamic> arb(String code) =>
        jsonDecode(File('lib/l10n/app_$code.arb').readAsStringSync())
            as Map<String, dynamic>;
    final en = arb('en');
    final french = arb('fr');
    final englishOnly = {
      for (final key in en.keys)
        if (!key.startsWith('@') &&
            !(en[key] as String).contains('{') &&
            en[key] != french[key])
          en[key] as String,
    };
    final shown = {
      for (final text in tester.widgetList<RichText>(find.byType(RichText)))
        text.text.toPlainText(),
    };
    expect(shown.intersection(englishOnly), isEmpty);

    await tester.tap(find.text(fr.settingsAbout('SecureShell Go')));
    await tester.pumpAndSettle();
    expect(find.text(fr.settingsAboutText), findsOneWidget);
  });
}
