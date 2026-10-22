// Screen-size sweep: renders the main screens at phone, tablet and desktop
// sizes (and large text on phones) with the real Roboto and Material Icons
// fonts, records every layout error (overflows, unbounded sizes), and — when
// SCREENSHOT_DIR is set — writes a PNG of each case plus results.txt.
//
// The screens that change with the hands on the device — sessions, the
// editor — render twice: once for touch, once for a mouse and keyboard
// (`input_profile.dart`). Foldables render at a hinge and in tabletop.
//
//   SCREENSHOT_DIR=/tmp/shots flutter test test/layout_sweep_test.dart
//   LAYOUT_SWEEP=1 LAYOUT_STRICT=1 flutter test test/layout_sweep_test.dart
//
// Opt-in — skipped in a plain `flutter test`, since 45 renders cost about
// half a minute. It reports rather than fails, unless LAYOUT_STRICT=1, so it
// can be run to look at the app before every problem it finds is fixed.
//
// English by default. LAYOUT_LOCALE=<language> renders every case in one of
// the app's translations instead — German and Russian run longest, so they
// are the ones to sweep before a release:
//
//   LAYOUT_LOCALE=de LAYOUT_SWEEP=1 LAYOUT_STRICT=1 flutter test test/layout_sweep_test.dart
//
// Results and screenshots then carry the language: `settings @ phone [de]`,
// `settings__phone__de.png`. Only Roboto is loaded, so a zh, ja or ko sweep
// measures its text in a fallback font: worth a look, not a verdict.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dartssh2/dartssh2.dart';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/l10n/l10n.dart';
import 'package:secure_shell_go/models/app_settings.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/models/known_host.dart';
import 'package:secure_shell_go/models/remote_entry.dart';
import 'package:secure_shell_go/models/tunnel_profile.dart';
import 'package:secure_shell_go/screens/backup_screen.dart';
import 'package:secure_shell_go/screens/file_browser_pane.dart';
import 'package:secure_shell_go/screens/fleet_run_screen.dart';
import 'package:secure_shell_go/screens/host_edit_screen.dart';
import 'package:secure_shell_go/screens/host_list_screen.dart';
import 'package:secure_shell_go/screens/known_hosts_screen.dart';
import 'package:secure_shell_go/screens/remote_editor_screen.dart';
import 'package:secure_shell_go/screens/remote_search_screen.dart';
import 'package:secure_shell_go/screens/server_stats_screen.dart';
import 'package:secure_shell_go/screens/session_screen.dart';
import 'package:secure_shell_go/screens/settings_screen.dart';
import 'package:secure_shell_go/screens/snippet_edit_screen.dart';
import 'package:secure_shell_go/screens/snippets_screen.dart';
import 'package:secure_shell_go/screens/terminal_pane.dart';
import 'package:secure_shell_go/screens/tunnel_edit_screen.dart';
import 'package:secure_shell_go/screens/tunnels_screen.dart';
import 'package:secure_shell_go/services/app_lock.dart';
import 'package:secure_shell_go/services/app_lock_controller.dart';
import 'package:secure_shell_go/services/backup_payload.dart';
import 'package:secure_shell_go/services/backup_service.dart';
import 'package:secure_shell_go/services/bookmark_store.dart';
import 'package:secure_shell_go/services/credential_store.dart';
import 'package:secure_shell_go/services/device_storage.dart';
import 'package:secure_shell_go/services/fleet_exec_service.dart';
import 'package:secure_shell_go/services/host_store.dart';
import 'package:secure_shell_go/services/input_profile.dart';
import 'package:secure_shell_go/services/keep_awake.dart';
import 'package:secure_shell_go/services/known_hosts_service.dart';
import 'package:secure_shell_go/services/remote_file_ops.dart';
import 'package:secure_shell_go/services/server_probe.dart';
import 'package:secure_shell_go/services/session_controller.dart';
import 'package:secure_shell_go/services/session_foreground.dart';
import 'package:secure_shell_go/services/session_manager.dart';
import 'package:secure_shell_go/services/session_recorder.dart';
import 'package:secure_shell_go/services/settings_store.dart';
import 'package:secure_shell_go/services/snippet_store.dart';
import 'package:secure_shell_go/services/sftp_service.dart';
import 'package:secure_shell_go/services/ssh_service.dart';
import 'package:secure_shell_go/services/terminal_workspace.dart';
import 'package:secure_shell_go/services/tunnel_runtime.dart';
import 'package:secure_shell_go/services/tunnel_store.dart';
import 'package:secure_shell_go/theme.dart';
import 'package:secure_shell_go/widgets/app_lock_gate.dart';
import 'package:secure_shell_go/widgets/terminal_find_bar.dart';
import 'package:secure_shell_go/widgets/terminal_fonts.dart';
import 'package:xterm/xterm.dart';

import 'fake_exec_session.dart';
import 'support/fake_transport.dart';

class _MemoryBackend implements SecureStorageBackend {
  final Map<String, String> data = {};
  @override
  Future<void> write(String key, String value) async => data[key] = value;
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> delete(String key) async => data.remove(key);
}

// ------------------------------------------------- a session to look at

/// A shell with something in it: a login banner and a directory listing,
/// so a screenshot shows a terminal rather than a black rectangle.
class _DemoShell implements SSHSession {
  _DemoShell() {
    _stdout.add(Uint8List.fromList(utf8.encode(
          'Welcome to Ubuntu 24.04.1 LTS (GNU/Linux 6.8.0-45-generic x86_64)\r\n'
          '\r\n'
          'Last login: Tue Oct 20 09:12:44 2026 from 10.0.0.12\r\n'
          'deploy@web-01:~\$ ls -la\r\n'
          'total 40\r\n'
          'drwxr-x--- 6 deploy deploy 4096 Oct 20 09:10 .\r\n'
          'drwxr-xr-x 4 root   root   4096 Sep  2 11:30 ..\r\n'
          '-rw-r--r-- 1 deploy deploy  807 Sep  2 11:30 .profile\r\n'
          'drwx------ 2 deploy deploy 4096 Sep  2 11:31 .ssh\r\n'
          'drwxr-xr-x 8 deploy deploy 4096 Oct 19 17:02 app\r\n'
          '-rwxr-xr-x 1 deploy deploy 1203 Oct 18 08:44 deploy.sh\r\n'
          'deploy@web-01:~\$ ',
        )));
  }

  // Single-subscription, so the banner waits for the session to listen.
  final _stdout = StreamController<Uint8List>();
  final _done = Completer<void>();

  @override
  Stream<Uint8List> get stdout => _stdout.stream;
  @override
  Stream<Uint8List> get stderr => const Stream.empty();
  @override
  Future<void> get done => _done.future;
  @override
  int? get exitCode => null;
  @override
  void write(Uint8List data) {}
  @override
  void close() {}
  @override
  void resizeTerminal(int width, int height, [int? pw, int? ph]) {}
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not faked');
}

class _DemoTransport extends FakeTransportBase {
  _DemoTransport(Host host) : super(host: host);

  @override
  Future<SSHSession> startShell({
    required int columns,
    required int rows,
    String terminalType = 'xterm-256color',
  }) async =>
      _DemoShell();
}

/// A home directory with the usual clutter, for the file browser, and two
/// files with text in them, for the editor.
class _DemoFs implements RemoteFileSystem {
  static final Map<String, String> texts = {
    '/home/deploy/deploy.sh': '#!/usr/bin/env bash\n'
        'set -euo pipefail\n\n'
        'cd /home/deploy/app\n'
        'git pull --ff-only\n'
        'docker compose up -d --build\n',
    '/home/deploy/app/main.py': 'import os\n\n\n'
        'def main():\n'
        '    port = int(os.environ.get("PORT", "8080"))\n'
        '    for attempt in range(3):\n'
        '        if serve(port):\n'
        '            break\n'
        '    else:\n'
        '        raise SystemExit("could not bind")\n',
  };

  @override
  Future<String> home() async => '/home/deploy';
  @override
  Future<String> resolve(String path) async => path;
  @override
  Future<List<RemoteEntry>> list(String path) async {
    final when = DateTime(2026, 10, 19, 17, 2);
    RemoteEntry dir(String name) => RemoteEntry(
          name: name,
          path: '$path/$name',
          kind: RemoteEntryKind.directory,
          size: 4096,
          modified: when,
        );
    RemoteEntry file(String name, int size) => RemoteEntry(
          name: name,
          path: '$path/$name',
          kind: RemoteEntryKind.file,
          size: size,
          modified: when,
        );
    return [
      dir('.ssh'),
      dir('app'),
      dir('backups'),
      dir('logs'),
      file('.profile', 807),
      file('deploy.sh', 1203),
      file('docker-compose.yml', 2210),
      file('README.md', 5120),
      file('nightly-database-export-2026-10-19-full-with-attachments.tar.gz',
          734003200),
    ];
  }

  @override
  Future<int?> sizeOf(String path) async => utf8.encode(texts[path] ?? '').length;
  @override
  Future<bool> exists(String path) async => true;
  @override
  Future<bool> isDirectory(String path) async => false;
  @override
  Future<int> download(
    String remotePath, {
    required Future<void> Function(Uint8List chunk) write,
    TransferProgress? onProgress,
    CancelCheck? isCancelled,
  }) async {
    final bytes = Uint8List.fromList(utf8.encode(texts[remotePath] ?? ''));
    await write(bytes);
    return bytes.length;
  }

  @override
  Future<void> close() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not faked');
}

/// A device that can lock the app, and a finger that keeps missing — so the
/// lock screen shows how many tries are left.
class _MissingFinger implements AppLockAuthenticator {
  @override
  Future<AppLockSupport> support() async => AppLockSupport.available;
  @override
  Future<AppLockOutcome> authenticate({required String reason}) async =>
      AppLockOutcome.failed;
  @override
  Future<void> setSecureDisplay(bool enabled) async {}
}

class _NoStorage implements DeviceStorage {
  @override
  Future<bool> ensurePermission() async => true;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not faked');
}

class _NoForeground implements SessionForegroundChannel {
  @override
  Future<void> start(String label) async {}
  @override
  Future<void> stop() async {}
}

class _NoKeepAwake implements KeepAwakeController {
  @override
  Future<void> setEnabled(bool enabled) async {}
}

class _InertTimer implements Timer {
  @override
  bool get isActive => false;
  @override
  int get tick => 0;
  @override
  void cancel() {}
}

const Host _web = Host(
  id: 'web',
  label: 'Production web',
  hostname: 'web-01.example.com',
  port: 22,
  username: 'deploy',
  authMethod: SshAuthMethod.privateKey,
);

const Host _db = Host(
  id: 'db',
  label: 'Production database (primary, eu-west-1)',
  hostname: 'db-primary.internal.example.com',
  port: 22,
  username: 'postgres',
  authMethod: SshAuthMethod.password,
);

SessionManager _demoSessions() => SessionManager(
      foreground: SessionForegroundController(channel: _NoForeground()),
      createController: (connection, resolve, resolveCreds) =>
          SessionController(
        connection: connection,
        storage: _NoStorage(),
        openFileSystem: () async => _DemoFs(),
        resolveRemoteTarget: resolve,
        resolveDestinationCredentials: resolveCreds,
        keepaliveScheduler: (_, _) => _InertTimer(),
      ),
    );

/// A Linux box's probe transcript, for the stats screen.
const _statsTranscript = '${ServerProbeCommands.marker}kernel\n'
    'Linux 6.8.0-45-generic\n'
    '${ServerProbeCommands.marker}host\nweb-01\n'
    '${ServerProbeCommands.marker}uptime\n1903388.77 7278894.06\n'
    '${ServerProbeCommands.marker}load\n0.42 0.31 0.28 1/100 200\n'
    '${ServerProbeCommands.marker}mem\n'
    'MemTotal:       16384000 kB\nMemAvailable:    5242880 kB\n'
    '${ServerProbeCommands.marker}disk\n'
    'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
    '/dev/nvme0n1p2 487652512 401234567 61234567 87% /\n'
    '${ServerProbeCommands.marker}cpu\n8\n';

// ------------------------------------------------------ the hands in use

/// Who is holding the device, as the sweep renders it.
enum _Hands {
  touch,
  mouse;

  InputProfile profile() => switch (this) {
        _Hands.touch => InputProfile()..notePointer(PointerDeviceKind.touch),
        _Hands.mouse => InputProfile()
          ..notePointer(PointerDeviceKind.mouse)
          ..noteHardwareKey(),
      };
}

typedef _Device = ({String name, Size size, double dpr, double text});

/// A foldable, and the hinge or fold across it.
typedef _Foldable = ({
  String name,
  Size size,
  double dpr,
  ui.DisplayFeature feature,
});

const List<_Foldable> _foldables = [
  // Unfolded inner screen, half open like a book: a vertical fold.
  (
    name: 'fold-book',
    size: Size(884, 1104),
    dpr: 2.5,
    feature: ui.DisplayFeature(
      bounds: Rect.fromLTWH(442, 0, 0, 1104),
      type: ui.DisplayFeatureType.fold,
      state: ui.DisplayFeatureState.postureHalfOpened,
    ),
  ),
  // The same, landscape on a table: the fold runs across.
  (
    name: 'fold-tabletop',
    size: Size(1104, 884),
    dpr: 2.5,
    feature: ui.DisplayFeature(
      bounds: Rect.fromLTWH(0, 442, 1104, 0),
      type: ui.DisplayFeatureType.fold,
      state: ui.DisplayFeatureState.postureHalfOpened,
    ),
  ),
  // A flip phone stood on its hinge.
  (
    name: 'flip-tabletop',
    size: Size(412, 915),
    dpr: 2.625,
    feature: ui.DisplayFeature(
      bounds: Rect.fromLTWH(0, 457, 412, 0),
      type: ui.DisplayFeatureType.fold,
      state: ui.DisplayFeatureState.postureHalfOpened,
    ),
  ),
  // Two screens spanned, with a real hinge between them.
  (
    name: 'dual-screen',
    size: Size(1114, 720),
    dpr: 2.5,
    feature: ui.DisplayFeature(
      bounds: Rect.fromLTWH(540, 0, 34, 720),
      type: ui.DisplayFeatureType.hinge,
      state: ui.DisplayFeatureState.postureFlat,
    ),
  ),
];


// ------------------------------------------------- lane D fixtures

const _gnuProbe = 'tool tar gnu\ntool gzip gnu\ntool xz other\ntool zip infozip\n'
    'tool unzip infozip\ntool find gnu\ntool grep gnu\ntool cp gnu\n'
    'tool chown gnu\ntar-gzip\ntar-xz\nend\n';

const _searchRecords = 'd 4096 /home/deploy/logs\u0000'
    'f 1048576 /home/deploy/logs/app.log\u0000'
    'f 52428800 /home/deploy/logs/app.log.1\u0000'
    'f 2210 /home/deploy/app/config/logging.yml\u0000'
    'l 12 /home/deploy/current-log\u0000'
    'f 734003200 /home/deploy/backups/nightly-database-export-2026-10-19-full-with-attachments.log\u0000';

/// Six hosts, six outcomes: a run that worked, one that failed with
/// stderr, one that could not connect, and sign-ins that need a person.
Future<SessionTransport> _demoFleetDialer(Host host, SshCredentials _) async {
  switch (host.id) {
    case 'h4':
      throw const FleetSignInNeedsPerson(
        'It asks "Verification code" at login, which needs you.',
      );
    case 'h3':
      throw const SshConnectionException('Connection refused by host.');
  }
  final (out, err, code) = switch (host.id) {
    'h2' => ('', "df: /: No such file or directory\nuptime: can't read utmp\n", 1),
    _ => (
        ' 17:02:11 up 41 days,  3:12,  2 users,  load average: 0.08, 0.12, 0.09\n'
            '/dev/sda1        79G   31G   45G  41% /\n',
        '',
        0,
      ),
  };
  return FakeExecTransport(
    host: host,
    respond: (_) => FakeExecSession(stdout: out, stderrText: err, exitCode: code),
  );
}

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

/// LAYOUT_LOCALE, if set: the translation every case renders in.
final Locale? _locale = () {
  final tag = Platform.environment['LAYOUT_LOCALE'];
  if (tag == null || tag.isEmpty) return null;
  final locale = Locale(tag);
  if (!AppLocalizations.supportedLocales.contains(locale)) {
    throw ArgumentError('LAYOUT_LOCALE=$tag: the app has no such translation '
        '(${AppLocalizations.supportedLocales.join(', ')})');
  }
  return locale;
}();
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
  // The terminal's bundled typeface, from the app's own assets.
  final bundled = FontLoader(TerminalFonts.jetBrainsMono);
  for (final face in ['Regular', 'Bold']) {
    final bytes = File('assets/fonts/JetBrainsMono-$face.ttf').readAsBytesSync();
    bundled.addFont(Future.value(ByteData.view(bytes.buffer)));
  }
  await bundled.load();
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
  late TunnelStore tunnelStore;

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
    // Here, not in the test: a store made on the test's fake clock chains
    // its writes on it, and `runAsync` would wait on them for ever.
    tunnelStore = TunnelStore(file: File('${dir.path}/tunnels.json'));
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
    _Hands? hands,
    List<ui.DisplayFeature> features = const [],
    Future<void> Function(WidgetTester tester)? after,
  }) async {
    final language = _locale?.languageCode;
    final key = '$screen @ ${device.name}'
        '${language == null ? '' : ' [$language]'}';
    final errors = _results.putIfAbsent(key, () => []);
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      errors.add(details.exceptionAsString().split('\n').first);
    };
    try {
      tester.view.physicalSize = device.size * device.dpr;
      tester.view.devicePixelRatio = device.dpr;
      tester.view.displayFeatures = features;
      tester.platformDispatcher.textScaleFactorTestValue = device.text;

      final boundary = GlobalKey();
      final navigator = GlobalKey<NavigatorState>();
      final profile = hands?.profile();
      await tester.pumpWidget(RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          navigatorKey: navigator,
          debugShowCheckedModeBanner: false,
          locale: _locale,
          localizationsDelegates:
              _locale == null ? null : AppLocalizations.localizationsDelegates,
          supportedLocales: _locale == null
              ? const [Locale('en', 'US')]
              : AppLocalizations.supportedLocales,
          themeMode: ThemeMode.dark,
          theme: AppTheme.themeFor(UiStyle.aurora, Brightness.light),
          darkTheme: AppTheme.themeFor(UiStyle.aurora, Brightness.dark),
          builder: profile == null
              ? null
              : (context, child) =>
                  InputProfileScope(profile: profile, child: child!),
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
      if (after != null) {
        await after(tester);
        await settleIo(tester, rounds: 10);
        await tester.pump(const Duration(milliseconds: 600));
      }

      final out = _shotDir;
      if (out != null) {
        final ro = boundary.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final ui.Image image = await ro.toImage(pixelRatio: device.dpr);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('$out/${screen}__${device.name}'
                  '${language == null ? '' : '__$language'}.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
        });
      }
      // Unmount inside the guarded window, so dispose-time errors count too.
      await tester.pumpWidget(const SizedBox.shrink());
      await settleIo(tester, rounds: 5);
    } finally {
      FlutterError.onError = previous;
      tester.view.resetDisplayFeatures();
      tester.view.reset();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    }
    if (_strict) expect(errors, isEmpty, reason: key);
  }

  /// Two sessions open — so the tab strip shows — on the sessions screen,
  /// the first in front showing [view].
  Future<void> renderSessions(
    WidgetTester tester,
    String screen,
    _Device device, {
    required _Hands hands,
    SessionView view = SessionView.terminal,
    List<ui.DisplayFeature> features = const [],
    Future<void> Function(WidgetTester tester)? after,
  }) async {
    final manager = _demoSessions();
    final workspace = TerminalWorkspace();
    addTearDown(() async {
      await workspace.dispose();
      await manager.dispose();
    });
    final web = manager.open(_DemoTransport(_web), initialView: view);
    manager.open(_DemoTransport(_db));
    manager.select(web.id);
    await render(
      tester,
      screen,
      device,
      hands: hands,
      features: features,
      after: after,
      () => SessionsScreen(
        sessions: manager,
        settingsStore: settings,
        workspace: workspace,
        keepAwake: _NoKeepAwake(),
      ),
    );
  }

  /// Three saved tunnels, one of them on a host since deleted.
  Future<TunnelRuntime> seedTunnels(WidgetTester tester) async {
    final store = tunnelStore;
    final runtime = TunnelRuntime(
      profiles: store,
      support: TunnelSupport(
        lookupHost: hosts.get,
        loadCredentials: (id) async => null,
      ),
    );
    addTearDown(runtime.dispose);
    await tester.runAsync(() async {
      await hosts.add(_web);
      await hosts.add(_db);
      await store.add(const TunnelProfile(
        id: 't1',
        name: 'Postgres (primary)',
        hostId: 'db',
        type: TunnelType.local,
        localPort: 15432,
        remoteHost: 'db-primary.internal.example.com',
        remotePort: 5432,
      ));
      await store.add(const TunnelProfile(
        id: 't2',
        name: 'Grafana',
        hostId: 'web',
        type: TunnelType.local,
        localPort: 3000,
        remoteHost: 'localhost',
        remotePort: 3000,
      ));
      await store.add(const TunnelProfile(
        id: 't3',
        name: 'SOCKS proxy through the old bastion',
        hostId: 'gone',
        type: TunnelType.dynamic,
        localPort: 1080,
      ));
    });
    return runtime;
  }

  /// Everything a backup could hold, on the sweep's own stores.
  BackupService backupService() => BackupService(
        hostStore: hosts,
        snippetStore: SnippetStore(file: File('${dir.path}/snippets.json')),
        tunnelStore: tunnelStore,
        bookmarkStore: BookmarkStore(file: File('${dir.path}/bm.json')),
        settingsStore: settings,
        credentialStore: credentials,
        knownHosts: knownHosts,
      );

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

      // Tall, so that the whole form is built: a ListView makes only what is
      // on screen, and the jump host field, with every saved host's name in
      // it, is below the fold of every phone.
      testWidgets('add host form, whole length', skip: _skip, (tester) async {
        await tester.runAsync(seedHosts);
        await render(
          tester,
          'host_edit_whole',
          (
            name: device.name,
            size: Size(device.size.width, 2400),
            dpr: device.dpr,
            text: device.text,
          ),
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

      for (final hands in _Hands.values) {
        testWidgets('sessions, ${hands.name}', skip: _skip, (tester) async {
          await renderSessions(tester, 'sessions_${hands.name}', device,
              hands: hands);
        });

        testWidgets('editor, ${hands.name}', skip: _skip, (tester) async {
          await render(
            tester,
            'editor_${hands.name}',
            device,
            push: true,
            hands: hands,
            () => RemoteEditorScreen(
              filesystem: _DemoFs(),
              settingsStore: settings,
              initialPaths: const [
                '/home/deploy/app/main.py',
                '/home/deploy/deploy.sh',
              ],
              hostLabel: 'web-01',
            ),
          );
        });
      }

      // The find bar open over the terminal, a session log being recorded,
      // and the bundled font with an underline cursor — which xterm itself
      // would draw on the wrong row.
      testWidgets('terminal find and log', skip: _skip, (tester) async {
        await tester.runAsync(() => settings.update((s) => s.copyWith(
              terminalFont: TerminalFont.jetBrainsMono,
              cursorStyle: TerminalCursorStyle.underline,
            )));
        await renderSessions(
          tester,
          'terminal_find',
          device,
          hands: _Hands.touch,
          after: (tester) async {
            final session = tester
                .widget<TerminalPane>(find.byType(TerminalPane).first)
                .session;
            session.terminal
                .startRecording(SessionRecorder(sink: MemoryLogSink()));
            TerminalPane.showFind(session);
            await tester.pump();
            await tester.pump();
            await tester.enterText(
              find.descendant(
                of: find.byType(TerminalFindBar),
                matching: find.byType(TextField),
              ),
              'deploy',
            );
            await tester.pump();
          },
        );
      });

      // The bar that slides in over the key bar while text is selected: three
      // buttons and a caption, which a small phone with large text — or a
      // language with longer words — has no room to label in full.
      testWidgets('terminal selection', skip: _skip, (tester) async {
        await renderSessions(
          tester,
          'terminal_selection',
          device,
          hands: _Hands.touch,
          after: (tester) async {
            final pane =
                tester.widget<TerminalPane>(find.byType(TerminalPane).first);
            final buffer = pane.session.terminal.buffer;
            tester
                .widget<TerminalView>(find.byType(TerminalView).first)
                .controller!
                .setSelection(
                  buffer.createAnchor(0, buffer.height - 1),
                  buffer.createAnchor(4, buffer.height - 1),
                );
            await tester.pump();
          },
        );
      });

      // The file browser on its own page: on a phone it takes turns with the
      // terminal, so the sessions renders above only show it from a tablet up.
      testWidgets('session files', skip: _skip, (tester) async {
        await renderSessions(tester, 'session_files', device,
            hands: _Hands.touch, view: SessionView.files);
      });

      testWidgets('server stats', skip: _skip, (tester) async {
        final session = SessionController(
          connection: FakeExecTransport(stdout: _statsTranscript, host: _web),
          keepaliveScheduler: (_, _) => _InertTimer(),
        );
        addTearDown(session.dispose);
        await render(
          tester,
          'server_stats',
          device,
          push: true,
          () => ServerStatsScreen(session: session),
        );
      });

      testWidgets('tunnels', skip: _skip, (tester) async {
        final runtime = await seedTunnels(tester);
        await render(
          tester,
          'tunnels',
          device,
          push: true,
          () => TunnelsScreen(tunnels: runtime, hostStore: hosts),
        );
      });

      // Tall, like the host form: every section built, with every optional
      // row there is — app lock and its timeouts, tunnels, backup and the
      // diagnostics log's buttons.
      testWidgets('settings, whole length', skip: _skip, (tester) async {
        final runtime = await seedTunnels(tester);
        final lock = AppLockController(authenticator: _MissingFinger());
        addTearDown(lock.dispose);
        await tester.runAsync(() => settings.update((s) => s.copyWith(
              appLockEnabled: true,
              diagnosticsLog: true,
            )));
        await render(
          tester,
          'settings_whole',
          (
            name: device.name,
            size: Size(device.size.width, 6000),
            dpr: device.dpr,
            text: device.text,
          ),
          push: true,
          () => SettingsScreen(
            settingsStore: settings,
            knownHosts: knownHosts,
            hostStore: hosts,
            tunnels: runtime,
            appLock: lock,
            backupService: backupService(),
          ),
        );
      });

      testWidgets('backup', skip: _skip, (tester) async {
        await render(
          tester,
          'backup',
          device,
          push: true,
          () => BackupScreen(
            service: backupService(),
            deviceStorage: _NoStorage(),
          ),
        );
      });

      // The export dialog at its fullest: a passphrase too short, so the
      // hint and the strength show, and passwords included, so the warning
      // does too.
      testWidgets('backup export dialog', skip: _skip, (tester) async {
        await render(
          tester,
          'backup_export',
          device,
          push: true,
          () => BackupScreen(
            service: backupService(),
            deviceStorage: _NoStorage(),
          ),
          after: (tester) async {
            await tester.tap(find.byIcon(Icons.upload_file_outlined));
            await tester.pumpAndSettle();
            await tester.enterText(find.byType(TextField).first, 'abc');
            final include = find.byType(Checkbox).first;
            await tester.ensureVisible(include);
            await tester.pumpAndSettle();
            await tester.tap(include);
            await tester.pumpAndSettle();
          },
        );
      });

      testWidgets('backup import preview', skip: _skip, (tester) async {
        await render(
          tester,
          'backup_import',
          device,
          push: true,
          () => const Scaffold(),
          after: (tester) async {
            unawaited(showDialog<void>(
              context: tester.element(find.byType(Scaffold).last),
              builder: (_) => ImportPreviewDialog(
                contents: const BackupContents(
                  hosts: 6,
                  groups: 3,
                  snippets: 4,
                  tunnels: 3,
                  bookmarks: 5,
                  credentials: 0,
                  includesCredentials: false,
                  hostsNeedingCredentials: 6,
                  knownHosts: 3,
                  includesKnownHosts: true,
                ),
                hostKeys: KnownHostsImport(
                  toAdd: [
                    KnownHostKey(
                      hostname: 'db-primary.internal.example.com',
                      port: 2222,
                      keyType: 'ssh-ed25519',
                      fingerprint:
                          'SHA256:47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU',
                      addedAt: DateTime(2026, 9, 1),
                    ),
                  ],
                  serversKept: 1,
                ),
              ),
            ));
            await tester.pumpAndSettle();
          },
        );
      });

      testWidgets('snippets, empty', skip: _skip, (tester) async {
        await render(
          tester,
          'snippets_empty',
          device,
          push: true,
          () => SnippetsScreen(
            snippetStore: SnippetStore(file: File('${dir.path}/sn.json')),
          ),
        );
      });

      testWidgets('snippet form', skip: _skip, (tester) async {
        await render(
          tester,
          'snippet_edit',
          device,
          push: true,
          () => SnippetEditScreen(
            snippetStore: SnippetStore(file: File('${dir.path}/sn.json')),
          ),
        );
      });

      // Each type changes the form's shape. The remote one listens on a
      // privileged port and the SOCKS one on every interface, so both
      // warnings show.
      for (final (name, profile) in [
        ('tunnel_edit', null),
        (
          'tunnel_edit_remote',
          const TunnelProfile(
            id: 'r',
            name: 'Webhook back to my laptop',
            hostId: 'web',
            type: TunnelType.remote,
            localPort: 8080,
            remotePort: 80,
          ),
        ),
        (
          'tunnel_edit_socks',
          const TunnelProfile(
            id: 's',
            name: '',
            hostId: 'db',
            type: TunnelType.dynamic,
            localHost: TunnelProfile.anyInterface,
            localPort: 1080,
          ),
        ),
      ]) {
        testWidgets(name.replaceAll('_', ' '), skip: _skip, (tester) async {
          await render(
            tester,
            name,
            device,
            push: true,
            () => TunnelEditScreen(
              tunnelStore: tunnelStore,
              hosts: [_web, _db],
              profile: profile,
            ),
          );
        });
      }

      // A wrong finger once, so the tries left show under the button.
      testWidgets('app lock', skip: _skip, (tester) async {
        final lock = AppLockController(authenticator: _MissingFinger());
        addTearDown(lock.dispose);
        await tester.runAsync(() => lock.start(const AppSettings(
              appLockEnabled: true,
              appLockTimeout: AppLockTimeout.immediately,
            )));
        await render(
          tester,
          'app_lock',
          device,
          () => AppLockGate(controller: lock, child: const Scaffold()),
        );
      });

      // Lane D: a command on many servers, and the browser's server-side
      // file actions.
      for (final step in const ['setup', 'confirm', 'results']) {
        testWidgets('fleet run, $step', skip: _skip, (tester) async {
          final saved = await tester.runAsync(() async {
            await seedHosts();
            // h5 has nothing saved, so it is skipped before any dial.
            for (final id in ['h0', 'h2', 'h4']) {
              await credentials.save(
                  id, const SshCredentials(privateKeyPem: 'demo key'));
            }
            for (final id in ['h1', 'h3']) {
              await credentials.save(id, const SshCredentials(password: 'pw'));
            }
            return hosts.all();
          });
          await render(
            tester,
            'fleet_run_$step',
            device,
            push: true,
            () => FleetRunScreen(
              hosts: saved!,
              initialHostIds: {for (final h in saved) h.id},
              sessions: sessions,
              credentialStore: credentials,
              sshService: ssh,
              dialer: _demoFleetDialer,
              initialCommand: 'uptime && df -h / | tail -n 1',
            ),
            after: step == 'setup'
                ? null
                : (tester) async {
                    final next = find.widgetWithText(FilledButton, 'Next');
                    await tester.scrollUntilVisible(next, 300,
                        scrollable: find.byType(Scrollable).first);
                    await tester.tap(next);
                    await tester.pumpAndSettle();
                    if (step == 'confirm') return;
                    await tester.tap(find.textContaining('Run on '));
                    await settleIo(tester);
                    await tester.tap(find.text('Staging'));
                    await tester.pumpAndSettle();
                  },
          );
        });
      }

      testWidgets('search on server', skip: _skip, (tester) async {
        await render(
          tester,
          'remote_search',
          device,
          push: true,
          () => RemoteSearchScreen(
            transport: () => FakeExecTransport(stdout: _searchRecords, host: _web),
            directory: '/home/deploy',
            toolkit: RemoteToolkit.parse(_gnuProbe),
          ),
          after: (tester) async {
            await tester.enterText(
                find.byKey(const ValueKey('searchName')), 'log');
            await tester.pump();
            await tester.tap(find.widgetWithText(FilledButton, 'Search'));
            await settleIo(tester);
          },
        );
      });

      for (final (name, row, tap) in const [
        ('file_actions', 'deploy.sh', null),
        ('compress_dialog', 'app', 'Compress…'),
        ('extract_dialog',
            'nightly-database-export-2026-10-19-full-with-attachments.tar.gz',
            'Extract…'),
        ('owner_dialog', 'app', 'Change owner…'),
      ]) {
        testWidgets(name.replaceAll('_', ' '), skip: _skip, (tester) async {
          final session = SessionController(
            connection: FakeExecTransport(
              host: _web,
              respond: (command) => FakeExecSession(
                stdout: command.contains('for t in tar gzip')
                    ? _gnuProbe
                    : 'drwxr-xr-x 9 deploy www-data 4096 Oct 19 17:02 x\n',
              ),
            ),
            storage: _NoStorage(),
            openFileSystem: () async => _DemoFs(),
            keepaliveScheduler: (_, _) => _InertTimer(),
          );
          addTearDown(session.dispose);
          await render(
            tester,
            name,
            device,
            () => FileBrowserPane(
              session: session,
              settingsStore: settings,
              bookmarkStore: BookmarkStore(file: File('${dir.path}/bm.json')),
            ),
            after: (tester) async {
              // The archive is the last row, below the fold on a phone.
              final listing = find
                  .ancestor(
                    of: find.text('deploy.sh'),
                    matching: find.byType(Scrollable),
                  )
                  .first;
              await tester.scrollUntilVisible(find.text(row), 200,
                  scrollable: listing);
              await tester.pumpAndSettle();
              await tester.longPress(find.text(row));
              await tester.pumpAndSettle();
              if (tap == null) return;
              final tile = find.widgetWithText(ListTile, tap);
              await tester.scrollUntilVisible(tile, 200,
                  scrollable: find.descendant(
                    of: find.byType(BottomSheet),
                    matching: find.byType(Scrollable),
                  ));
              await tester.tap(tile);
              await settleIo(tester);
              if (name == 'extract_dialog') {
                await tester.tap(find.widgetWithText(FilledButton, 'Extract'));
                await settleIo(tester);
              }
            },
          );
        });
      }
    });
  }

  group('foldables', () {
    for (final fold in _foldables) {
      final device = (
        name: fold.name,
        size: fold.size,
        dpr: fold.dpr,
        text: 1.0,
      );
      for (final hands in _Hands.values) {
        testWidgets('sessions at ${fold.name}, ${hands.name}', skip: _skip,
            (tester) async {
          await renderSessions(tester, 'sessions_${hands.name}', device,
              hands: hands, features: [fold.feature]);
        });
      }

      testWidgets('editor at ${fold.name}', skip: _skip, (tester) async {
        await render(
          tester,
          'editor_touch',
          device,
          push: true,
          hands: _Hands.touch,
          features: [fold.feature],
          () => RemoteEditorScreen(
            filesystem: _DemoFs(),
            settingsStore: settings,
            initialPaths: const ['/home/deploy/app/main.py'],
            hostLabel: 'web-01',
          ),
        );
      });
    }
  });
}
