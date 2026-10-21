// Screen-size sweep: renders the main screens at phone, tablet and desktop
// sizes (and large text on phones) with the real Roboto and Material Icons
// fonts, records every layout error (overflows, unbounded sizes), and — when
// SCREENSHOT_DIR is set — writes a PNG of each case plus results.txt.
//
//   SCREENSHOT_DIR=/tmp/shots flutter test test/layout_sweep_test.dart
//   LAYOUT_SWEEP=1 LAYOUT_STRICT=1 flutter test test/layout_sweep_test.dart
//
// Opt-in — skipped in a plain `flutter test`, since 45 renders cost about
// half a minute. It reports rather than fails, unless LAYOUT_STRICT=1, so it
// can be run to look at the app before every problem it finds is fixed.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/app_settings.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/models/known_host.dart';
import 'package:secure_shell_go/screens/host_edit_screen.dart';
import 'package:secure_shell_go/screens/host_list_screen.dart';
import 'package:secure_shell_go/screens/known_hosts_screen.dart';
import 'package:secure_shell_go/screens/settings_screen.dart';
import 'package:secure_shell_go/services/credential_store.dart';
import 'package:secure_shell_go/services/host_store.dart';
import 'package:secure_shell_go/services/known_hosts_service.dart';
import 'package:secure_shell_go/services/session_manager.dart';
import 'package:secure_shell_go/services/settings_store.dart';
import 'package:secure_shell_go/services/ssh_service.dart';
import 'package:secure_shell_go/theme.dart';

class _MemoryBackend implements SecureStorageBackend {
  final Map<String, String> data = {};
  @override
  Future<void> write(String key, String value) async => data[key] = value;
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> delete(String key) async => data.remove(key);
}

typedef _Device = ({String name, Size size, double dpr, double text});

const List<_Device> _devices = [
  (name: 'phone-small', size: Size(320, 640), dpr: 2, text: 1.0),
  (name: 'phone-small-bigtext', size: Size(320, 640), dpr: 2, text: 1.5),
  (name: 'phone', size: Size(393, 852), dpr: 2.75, text: 1.0),
  (name: 'phone-bigtext', size: Size(393, 852), dpr: 2.75, text: 1.5),
  (name: 'phone-landscape', size: Size(852, 393), dpr: 2.75, text: 1.0),
  (name: 'tablet-portrait', size: Size(800, 1280), dpr: 2, text: 1.0),
  (name: 'tablet-landscape', size: Size(1280, 800), dpr: 2, text: 1.0),
  (name: 'desktop', size: Size(1366, 768), dpr: 1, text: 1.0),
  (name: 'desktop-large', size: Size(1920, 1080), dpr: 1, text: 1.0),
];

final String? _shotDir = Platform.environment['SCREENSHOT_DIR'];
final bool _strict = Platform.environment['LAYOUT_STRICT'] == '1';
// Opt-in: set LAYOUT_SWEEP=1, SCREENSHOT_DIR or LAYOUT_STRICT=1 to run.
final bool _skip = !(_shotDir != null ||
    Platform.environment['LAYOUT_SWEEP'] == '1' ||
    _strict);
final Map<String, List<String>> _results = {};

Future<void> _loadFonts() async {
  final root = Platform.environment['FLUTTER_ROOT'] ??
      '${Platform.environment['HOME']}/development/flutter';
  final fonts = '$root/bin/cache/artifacts/material_fonts';
  Future<void> load(String family, List<String> files) async {
    final loader = FontLoader(family);
    for (final f in files) {
      final bytes = File('$fonts/$f').readAsBytesSync();
      loader.addFont(Future.value(ByteData.view(bytes.buffer)));
    }
    await loader.load();
  }

  await load('Roboto', [
    'Roboto-Regular.ttf',
    'Roboto-Medium.ttf',
    'Roboto-Bold.ttf',
    'Roboto-Light.ttf',
  ]);
  await load('MaterialIcons', ['MaterialIcons-Regular.otf']);
  // The app's terminal-ish text asks for 'monospace', which the test
  // renderer does not have; without this it draws as blocks.
  const mono = '/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf';
  if (File(mono).existsSync()) {
    final loader = FontLoader('monospace')
      ..addFont(Future.value(
          ByteData.view(File(mono).readAsBytesSync().buffer)));
    await loader.load();
  }
}

void main() {
  late Directory dir;
  late HostStore hosts;
  late SettingsStore settings;
  late KnownHostsService knownHosts;
  late SshService ssh;
  late SessionManager sessions;
  late CredentialStore credentials;

  setUpAll(_loadFonts);

  tearDownAll(() async {
    final out = _shotDir;
    final lines = <String>[];
    _results.forEach((k, v) {
      lines.add('${v.isEmpty ? 'OK  ' : 'FAIL'} $k');
      for (final e in v.toSet()) {
        lines.add('       $e');
      }
    });
    // ignore: avoid_print
    print(lines.join('\n'));
    if (out != null) {
      await File('$out/results.txt').writeAsString('${lines.join('\n')}\n');
    }
  });

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ssg_layout_sweep');
    hosts = HostStore(file: File('${dir.path}/${HostStore.fileName}'));
    settings =
        SettingsStore(file: File('${dir.path}/${SettingsStore.fileName}'));
    knownHosts = KnownHostsService(
      file: File('${dir.path}/${KnownHostsService.fileName}'),
    );
    ssh = SshService(knownHosts: knownHosts);
    sessions = SessionManager();
    credentials = CredentialStore(backend: _MemoryBackend());
  });

  tearDown(() async {
    settings.dispose();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Future<void> settleIo(WidgetTester tester, {int rounds = 40}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
  }

  Future<void> seedHosts() async {
    final now = DateTime(2026, 10, 20, 9, 30);
    final seed = [
      ('Production web', 'web-01.example.com', 'deploy', 'Production',
          HostColorLabel.red),
      ('Production database (primary, eu-west-1)',
          'db-primary.internal.example.com', 'postgres', 'Production',
          HostColorLabel.red),
      ('Staging', 'staging.example.com', 'ubuntu', 'Staging',
          HostColorLabel.orange),
      ('Raspberry Pi', '192.168.1.42', 'pi', 'Home', HostColorLabel.green),
      ('NAS', 'nas.local', 'admin', 'Home', null),
      ('Build box', 'build.example.org', 'ci', null, null),
    ];
    for (var i = 0; i < seed.length; i++) {
      final (label, hostname, user, group, color) = seed[i];
      await hosts.add(Host(
        id: 'h$i',
        label: label,
        hostname: hostname,
        port: i == 2 ? 2222 : 22,
        username: user,
        authMethod:
            i.isEven ? SshAuthMethod.privateKey : SshAuthMethod.password,
        group: group,
        colorLabel: color,
        lastConnectedAt: i < 3 ? now.subtract(Duration(hours: i * 7)) : null,
      ));
    }
  }

  /// Renders [build] on [device], records layout errors, writes a PNG.
  Future<void> render(
    WidgetTester tester,
    String screen,
    _Device device,
    Widget Function() build, {
    bool push = false,
  }) async {
    final key = '$screen @ ${device.name}';
    final errors = _results.putIfAbsent(key, () => []);
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      errors.add(details.exceptionAsString().split('\n').first);
    };
    try {
      tester.view.physicalSize = device.size * device.dpr;
      tester.view.devicePixelRatio = device.dpr;
      tester.platformDispatcher.textScaleFactorTestValue = device.text;

      final boundary = GlobalKey();
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          navigatorKey: navigator,
          debugShowCheckedModeBanner: false,
          themeMode: ThemeMode.dark,
          theme: AppTheme.themeFor(UiStyle.aurora, Brightness.light),
          darkTheme: AppTheme.themeFor(UiStyle.aurora, Brightness.dark),
          home: push ? const Scaffold(body: SizedBox.shrink()) : build(),
        ),
      ));
      if (push) {
        unawaited(navigator.currentState!
            .push(MaterialPageRoute<void>(builder: (_) => build())));
      }
      await tester.pump();
      await settleIo(tester);
      await tester.pump(const Duration(milliseconds: 600));

      final out = _shotDir;
      if (out != null) {
        final ro = boundary.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final ui.Image image = await ro.toImage(pixelRatio: device.dpr);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('$out/${screen}__${device.name}.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
        });
      }
      // Unmount inside the guarded window, so dispose-time errors count too.
      await tester.pumpWidget(const SizedBox.shrink());
      await settleIo(tester, rounds: 5);
    } finally {
      FlutterError.onError = previous;
      tester.view.reset();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    }
    if (_strict) expect(errors, isEmpty, reason: key);
  }

  for (final device in _devices) {
    group(device.name, () {
      testWidgets('host list, populated', skip: _skip, (tester) async {
        await tester.runAsync(seedHosts);
        await render(
          tester,
          'host_list',
          device,
          () => HostListScreen(
            hostStore: hosts,
            credentialStore: credentials,
            knownHosts: knownHosts,
            sshService: ssh,
            settingsStore: settings,
            sessions: sessions,
          ),
        );
      });

      testWidgets('host list, empty', skip: _skip, (tester) async {
        await render(
          tester,
          'host_list_empty',
          device,
          () => HostListScreen(
            hostStore: hosts,
            credentialStore: credentials,
            knownHosts: knownHosts,
            sshService: ssh,
            settingsStore: settings,
            sessions: sessions,
          ),
        );
      });

      testWidgets('add host form', skip: _skip, (tester) async {
        await render(
          tester,
          'host_edit',
          device,
          push: true,
          () => HostEditScreen(
            hostStore: hosts,
            credentialStore: credentials,
            sshService: ssh,
            settingsStore: settings,
            sessions: sessions,
          ),
        );
      });

      testWidgets('edit host form, Advanced open', skip: _skip,
          (tester) async {
        // Something in it set, so it opens unfolded: the widest it gets.
        const host = Host(
          id: 'adv',
          label: 'Build box',
          hostname: 'build.example.com',
          port: 22,
          username: 'ci',
          authMethod: SshAuthMethod.password,
          transport: HostTransport.mosh,
          persistentSession: PersistentSession.screen,
          agentForwarding: true,
        );
        await render(
          tester,
          'host_edit_advanced',
          device,
          push: true,
          () => HostEditScreen(
            hostStore: hosts,
            credentialStore: credentials,
            sshService: ssh,
            settingsStore: settings,
            sessions: sessions,
            host: host,
          ),
        );
      });

      testWidgets('settings', skip: _skip, (tester) async {
        await render(
          tester,
          'settings',
          device,
          push: true,
          () => SettingsScreen(
            settingsStore: settings,
            knownHosts: knownHosts,
            hostStore: hosts,
          ),
        );
      });

      testWidgets('known hosts', skip: _skip, (tester) async {
        await tester.runAsync(() async {
          for (final (h, t, fp) in [
            ('web-01.example.com', 'ssh-ed25519',
                'SHA256:47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU'),
            ('db-primary.internal.example.com', 'ssh-rsa',
                'SHA256:nThbg6kXUpJWGl7E1IGOCspRomTxdCARLviKw6E5SY8'),
          ]) {
            await knownHosts.trust(KnownHostKey(
              hostname: h,
              port: 22,
              keyType: t,
              fingerprint: fp,
              addedAt: DateTime(2026, 9, 1),
            ));
          }
        });
        await render(
          tester,
          'known_hosts',
          device,
          push: true,
          () => KnownHostsScreen(knownHosts: knownHosts),
        );
      });
    });
  }
}
