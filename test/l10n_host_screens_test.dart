import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/l10n/l10n.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/screens/host_edit_screen.dart';
import 'package:secure_shell_go/screens/host_list_screen.dart';
import 'package:secure_shell_go/services/credential_store.dart';
import 'package:secure_shell_go/services/host_store.dart';
import 'package:secure_shell_go/services/known_hosts_service.dart';
import 'package:secure_shell_go/services/session_manager.dart';
import 'package:secure_shell_go/services/settings_store.dart';
import 'package:secure_shell_go/services/ssh_service.dart';

class _MemoryBackend implements SecureStorageBackend {
  final Map<String, String> data = {};
  @override
  Future<void> write(String key, String value) async => data[key] = value;
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> delete(String key) async => data.remove(key);
}

/// The host screens with the German translation installed, the way the app
/// installs it: every other widget test finds the English that `context.l10n`
/// falls back to, so this is what shows the screens really read the ARB
/// strings — the Material ones, and the dates, included.
void main() {
  late Directory dir;
  late HostStore hosts;
  late SettingsStore settings;
  late KnownHostsService knownHosts;

  // Outside the test's fake clock, as in device_layouts_test.dart: a store
  // made inside `testWidgets` chains its writes on that clock.
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('l10n_host_screens_test');
    hosts = HostStore(file: File('${dir.path}/${HostStore.fileName}'));
    settings =
        SettingsStore(file: File('${dir.path}/${SettingsStore.fileName}'));
    knownHosts = KnownHostsService(
      file: File('${dir.path}/${KnownHostsService.fileName}'),
    );
  });

  tearDown(() async {
    settings.dispose();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Widget german(Widget home) => MaterialApp(
        locale: const Locale('de'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: home,
      );

  // Not pumpAndSettle: the host list keeps a spinner going while it waits
  // on its stores.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 600));
  }

  testWidgets('the host list is in German', (tester) async {
    // Phone-sized, for the list rows that say "Last connected" in words.
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final now = DateTime.now();
    final sessions = SessionManager();
    addTearDown(sessions.dispose);
    await tester.runAsync(() async {
      await hosts.add(Host(
        id: 'h1',
        label: 'Build box',
        hostname: 'build.example.org',
        port: 22,
        username: 'ci',
        authMethod: SshAuthMethod.password,
        group: 'Produktion',
        lastConnectedAt: now,
      ));
      await hosts.add(Host(
        id: 'h2',
        label: 'NAS',
        hostname: 'nas.local',
        port: 22,
        username: 'admin',
        authMethod: SshAuthMethod.privateKey,
        lastConnectedAt: DateTime(now.year - 1, 7, 26, 9, 30),
      ));
    });

    await tester.pumpWidget(german(HostListScreen(
      hostStore: hosts,
      credentialStore: CredentialStore(backend: _MemoryBackend()),
      knownHosts: knownHosts,
      sshService: SshService(knownHosts: knownHosts),
      settingsStore: settings,
      sessions: sessions,
    )));
    await settle(tester);

    expect(find.text('Hosts suchen'), findsOneWidget);
    expect(
      find.text('Schnellverbindung: user@host oder user@host:port'),
      findsOneWidget,
    );
    expect(find.text('Ohne Gruppe'), findsOneWidget);
    expect(find.byTooltip('Host hinzufügen'), findsOneWidget);
    expect(find.byTooltip('Einstellungen'), findsOneWidget);
    // Dates in German too, from the calendar data the delegates bring.
    expect(find.textContaining('Zuletzt verbunden: heute um '), findsOneWidget);
    expect(
      find.text('Zuletzt verbunden: 26. Juli ${now.year - 1}'),
      findsOneWidget,
    );
    expect(find.text('Search hosts'), findsNothing);

    await tester.longPress(find.text('Build box'));
    await settle(tester);
    expect(find.text('Hostschlüssel vergessen'), findsOneWidget);
    expect(find.text('In Gruppe verschieben…'), findsOneWidget);
    // Delete is Material's own label, in Material's German.
    expect(find.text('Löschen'), findsOneWidget);
    expect(find.text('Forget host keys'), findsNothing);
  });

  // A bare MaterialApp has no calendar data for intl to format dates with,
  // not even English; the list must still show them, in English, rather
  // than throw.
  testWidgets('without the delegates, dates fall back to English',
      (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final now = DateTime.now();
    final sessions = SessionManager();
    addTearDown(sessions.dispose);
    await tester.runAsync(() => hosts.add(Host(
          id: 'h1',
          label: 'NAS',
          hostname: 'nas.local',
          port: 22,
          username: 'admin',
          authMethod: SshAuthMethod.password,
          lastConnectedAt: DateTime(now.year - 1, 7, 26, 9, 30),
        )));

    await tester.pumpWidget(MaterialApp(
      home: HostListScreen(
        hostStore: hosts,
        credentialStore: CredentialStore(backend: _MemoryBackend()),
        knownHosts: knownHosts,
        sshService: SshService(knownHosts: knownHosts),
        settingsStore: settings,
        sessions: sessions,
      ),
    ));
    await settle(tester);

    expect(tester.takeException(), isNull);
    expect(
      find.text('Last connected Jul 26, ${now.year - 1}'),
      findsOneWidget,
    );
  });

  testWidgets('the host form is in German', (tester) async {
    // Tall enough that the whole form is built, buttons included.
    tester.view.physicalSize = const Size(800, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final sessions = SessionManager();
    addTearDown(sessions.dispose);

    await tester.pumpWidget(german(HostEditScreen(
      hostStore: hosts,
      credentialStore: CredentialStore(backend: _MemoryBackend()),
      sshService: SshService(knownHosts: knownHosts),
      settingsStore: settings,
      sessions: sessions,
    )));
    await settle(tester);

    expect(find.text('Host hinzufügen'), findsOneWidget);
    expect(find.text('Bezeichnung (optional)'), findsOneWidget);
    expect(find.text('Benutzername'), findsOneWidget);
    expect(find.text('Über Jump-Host verbinden'), findsOneWidget);
    expect(find.text('Privater Schlüssel'), findsOneWidget);
    expect(find.text('Erweitert'), findsOneWidget);
    expect(find.text('Verbindung, Sitzung und Weiterleitung'), findsOneWidget);
    expect(find.text('Host speichern'), findsOneWidget);
    expect(find.text('Ohne Speichern verbinden'), findsOneWidget);

    // An empty form is refused in German, and nothing is saved.
    await tester.tap(find.text('Speichern & verbinden'));
    await settle(tester);
    expect(find.text('Pflichtfeld'), findsWidgets);
    expect(find.text('Required'), findsNothing);
    expect(await tester.runAsync(hosts.all), isEmpty);
  });
}
