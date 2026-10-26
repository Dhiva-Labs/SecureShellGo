import 'dart:io';
import 'dart:ui' as ui;

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/l10n/app_localizations.dart';
import 'package:secure_shell_go/models/app_settings.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/screens/remote_desktop_launch.dart';
import 'package:secure_shell_go/services/input_profile.dart';
import 'package:secure_shell_go/services/remote_exec.dart';
import 'package:secure_shell_go/services/session_controller.dart';
import 'package:secure_shell_go/services/ssh_service.dart';
import 'package:secure_shell_go/theme.dart';
import 'package:secure_shell_go/widgets/terminal_fonts.dart';

/// The whole remote-desktop flow, from the session's "Remote desktop…" to
/// a live remote screen, against real servers, with a screenshot of each
/// step. The real chooser, setup dialog, agent upload, launch, tunnel,
/// protocol, decoder and viewer: only the platform window is missing.
///
/// Opt-in, and never against this machine, for the reason
/// `agent_live_test.dart` gives. The Linux run starts a virtual desktop in
/// a VM; the Windows run shows a real session, so it sends no input.
///
/// ```sh
/// SSGO_RD_DEMO_OUT=/tmp/shots \
/// SSGO_RD_DEMO_LINUX=ubuntu@10.155.212.110 SSGO_RD_DEMO_LINUX_KEY=… \
/// SSGO_RD_DEMO_WINDOWS=dhiva@192.168.0.127 SSGO_RD_DEMO_WINDOWS_KEY=… \
/// SSGO_RD_DEMO_WINDOWS_FINGERPRINT=SHA256:… \
///   flutter test test/remote_desktop/remote_desktop_demo_test.dart
/// ```
void main() {
  final env = Platform.environment;
  final out = env['SSGO_RD_DEMO_OUT'];
  final linux = env['SSGO_RD_DEMO_LINUX'];
  final windows = env['SSGO_RD_DEMO_WINDOWS'];
  final none = out == null ? 'set SSGO_RD_DEMO_OUT' : null;

  setUpAll(_loadFonts);

  testWidgets(
    'Linux VM: a virtual Xfce desktop',
    (tester) async {
      final live = (await tester.runAsync(
        () => _connect(linux!, env['SSGO_RD_DEMO_LINUX_KEY'], label: 'snaptest VM'),
      ))!;
      addTearDown(() => live.client.close());
      final l10n = await _app(tester, live.session);
      debugDisableShadows = false;

      await tester.tap(find.text('Open remote desktop'));
      await _waitFor(tester, find.text(l10n.remoteDesktopLaunchNewVirtual));
      await _shot(tester, out!, '01-linux-chooser');

      await tester.tap(find.text(l10n.remoteDesktopLaunchNewVirtual));
      await _waitFor(tester, find.text(l10n.remoteDesktopVirtualTitle));
      await _settle(tester, const Duration(milliseconds: 400));
      await _shot(tester, out, '02-linux-virtual-setup');

      await tester.tap(find.text(l10n.remoteDesktopVirtualStart));
      await _waitFor(
        tester,
        find.byKey(const ValueKey('remote-viewer')),
        timeout: const Duration(seconds: 60),
      );
      // Xfce takes a few seconds to draw its panel and desktop.
      await _settle(tester, const Duration(seconds: 12));
      await _shot(tester, out, '03-linux-virtual-xfce');

      debugDisableShadows = true;
      await tester.tap(find.byTooltip(l10n.remoteDesktopDisconnect).first);
      await _settle(tester, const Duration(seconds: 3));
      // Not kept: closing the viewer took the X server, Xfce and the agent
      // with it.
      final left = (await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(seconds: 3));
        final r = await RemoteExec.run(
          live.session.connection,
          r'systemctl --user list-units "ssgo-*" --no-legend --plain; pgrep -u "$(id -u)" -x Xvfb || true',
        );
        return r.stdout.trim();
      }))!;
      expect(left, isEmpty, reason: 'left running on the VM: $left');
    },
    skip: none != null || linux == null,
    timeout: const Timeout(Duration(minutes: 4)),
  );

  // A fresh server with nothing graphical on it and a sudo that asks for the
  // password: the app offers to install what it needs, installs it on a
  // click, and goes on to the desktop; then a program that is not there is
  // offered and installed the same way.
  final fresh = env['SSGO_RD_DEMO_FRESH'];
  testWidgets(
    'Fresh server: installs what it needs, then a desktop and a program',
    (tester) async {
      final live = (await tester.runAsync(
        () => _connect(fresh!, env['SSGO_RD_DEMO_FRESH_KEY'], label: 'fresh-server'),
      ))!;
      addTearDown(() => live.client.close());
      final sudo = env['SSGO_RD_DEMO_FRESH_SUDO']!;
      final l10n = await _app(tester, live.session);
      debugDisableShadows = false;

      await tester.tap(find.text('Open remote desktop'));
      await _waitFor(tester, find.text(l10n.remoteDesktopLaunchSetupNeeded));
      await _shot(tester, out!, '08-fresh-chooser');

      await tester.tap(find.text(l10n.remoteDesktopLaunchNewVirtual));
      await _waitFor(tester, find.text(l10n.remoteDesktopSetupPassword));
      await _shot(tester, out, '09-fresh-setup');

      await tester.enterText(find.byType(TextField), sudo);
      await _settle(tester, const Duration(milliseconds: 200));
      await tester.tap(find.text(l10n.remoteDesktopSetupInstall));
      await _settle(tester, const Duration(seconds: 20));
      await _shot(tester, out, '10-fresh-installing');
      // Then the setup dialog for the desktop, with Xfce now there.
      await _waitFor(tester, find.text(l10n.remoteDesktopVirtualSession('Xfce')),
          timeout: const Duration(minutes: 10));
      await _shot(tester, out, '11-fresh-desktop-ready');

      await tester.tap(find.text(l10n.remoteDesktopVirtualStart));
      await _waitFor(tester, find.byKey(const ValueKey('remote-viewer')),
          timeout: const Duration(seconds: 60));
      await _settle(tester, const Duration(seconds: 12));
      await _shot(tester, out, '12-fresh-xfce');
      await tester.tap(find.byTooltip(l10n.remoteDesktopDisconnect).first);
      await _settle(tester, const Duration(seconds: 3));
      // Disconnect may already have left the viewer; if not, leave it.
      final back = find.byType(BackButton);
      if (back.evaluate().isNotEmpty) await tester.tap(back.first);
      await _settle(tester, const Duration(seconds: 1));

      // One program that is not installed: offered, installed, started.
      await tester.tap(find.text('Open remote desktop'));
      await _waitFor(tester, find.text(l10n.remoteDesktopLaunchNewVirtual));
      await tester.tap(find.text(l10n.remoteDesktopLaunchNewVirtual));
      await _waitFor(tester, find.text(l10n.remoteDesktopVirtualOneApp));
      await tester.tap(find.text(l10n.remoteDesktopVirtualOneApp));
      await _settle(tester, const Duration(milliseconds: 300));
      await tester.enterText(find.byType(TextField).last, 'xclock');
      await tester.tap(find.text(l10n.remoteDesktopVirtualStart));
      await _waitFor(tester, find.text(l10n.remoteDesktopVirtualInstallProgram('x11-apps')));
      await _shot(tester, out, '13-fresh-program-missing');
      await tester.tap(find.text(l10n.remoteDesktopVirtualInstallProgram('x11-apps')));
      await _waitFor(tester, find.text(l10n.remoteDesktopSetupPassword));
      await tester.enterText(find.byType(TextField).last, sudo);
      await _settle(tester, const Duration(milliseconds: 200));
      await tester.tap(find.text(l10n.remoteDesktopSetupInstall));
      await _waitFor(tester, find.byKey(const ValueKey('remote-viewer')),
          timeout: const Duration(minutes: 5));
      await _settle(tester, const Duration(seconds: 6));
      await _shot(tester, out, '14-fresh-xclock');
      debugDisableShadows = true;
      await tester.tap(find.byTooltip(l10n.remoteDesktopDisconnect).first);
      await _settle(tester, const Duration(seconds: 3));
    },
    skip: none != null || fresh == null,
    timeout: const Timeout(Duration(minutes: 20)),
  );

  testWidgets(
    'Windows laptop: its real desktop, no input sent',
    (tester) async {
      final live = (await tester.runAsync(
        () => _connect(
          windows!,
          env['SSGO_RD_DEMO_WINDOWS_KEY'],
          label: 'Lenovo laptop',
          fingerprint: env['SSGO_RD_DEMO_WINDOWS_FINGERPRINT'],
        ),
      ))!;
      addTearDown(() => live.client.close());
      final l10n = await _app(tester, live.session);
      debugDisableShadows = false;

      await tester.tap(find.text('Open remote desktop'));
      await _waitFor(
        tester,
        find.text(l10n.remoteDesktopLaunchShowDesktop),
        timeout: const Duration(seconds: 60),
      );
      await _shot(tester, out!, '04-windows-chooser');

      await tester.tap(find.text(l10n.remoteDesktopLaunchShowDesktop));
      await _waitFor(
        tester,
        find.byKey(const ValueKey('remote-viewer')),
        timeout: const Duration(seconds: 90),
      );
      await _settle(tester, const Duration(seconds: 8));
      await _shot(tester, out, '05-windows-desktop');

      debugDisableShadows = true;
      await tester.tap(find.byTooltip(l10n.remoteDesktopDisconnect).first);
      await _settle(tester, const Duration(seconds: 3));
      final left = (await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(seconds: 3));
        final r = await RemoteExec.run(
          live.session.connection,
          'tasklist /fo csv /nh /fi "imagename eq crossshell-host.exe"',
        );
        return r.stdout.trim();
      }))!;
      expect(left, isNot(contains('crossshell-host.exe')),
          reason: 'agent left running on the laptop');
    },
    skip: none != null || windows == null,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}

// ------------------------------------------------------------------ app

final _boundary = GlobalKey();

/// A desktop with a mouse and a keyboard, as the person at it would have.
final _mouse = InputProfile()
  ..notePointer(PointerDeviceKind.mouse)
  ..noteHardwareKey();

Future<AppLocalizations> _app(WidgetTester tester, SessionController session) async {
  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  late AppLocalizations l10n;
  await tester.pumpWidget(
    RepaintBoundary(
      key: _boundary,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        themeMode: ThemeMode.dark,
        theme: AppTheme.themeFor(UiStyle.aurora, Brightness.light),
        darkTheme: AppTheme.themeFor(UiStyle.aurora, Brightness.dark),
        builder: (context, child) =>
            InputProfileScope(profile: _mouse, child: child!),
        home: Builder(
          builder: (context) {
            l10n = AppLocalizations.of(context)!;
            return Scaffold(
              appBar: AppBar(title: Text(session.host.displayName)),
              body: Center(
                child: FilledButton.icon(
                  icon: const Icon(Icons.desktop_windows_outlined),
                  label: const Text('Open remote desktop'),
                  onPressed: () => startRemoteDesktop(context, session),
                ),
              ),
            );
          },
        ),
      ),
    ),
  );
  await tester.pump();
  return l10n;
}

/// Turns the real event loop and the test's clock together, so timers the
/// client sets (its 2 s ping above all) fire on time against real servers.
Future<void> _settle(WidgetTester tester, Duration total) async {
  const step = Duration(milliseconds: 50);
  for (var t = Duration.zero; t < total; t += step) {
    await tester.runAsync(() => Future<void>.delayed(step));
    await tester.pump(step);
  }
}

Future<void> _waitFor(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final clock = Stopwatch()..start();
  while (finder.evaluate().isEmpty) {
    if (clock.elapsed > timeout) {
      fail('timed out waiting for $finder');
    }
    await _settle(tester, const Duration(milliseconds: 200));
  }
}

Future<void> _shot(WidgetTester tester, String dir, String name) async {
  // Let a dialog that just closed finish fading, so the shot shows the
  // screen rather than the transition.
  await _settle(tester, const Duration(milliseconds: 500));
  final ro = _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await ro.toImage(pixelRatio: 1);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    Directory(dir).createSync(recursive: true);
    await File('$dir/$name.png').writeAsBytes(png!.buffer.asUint8List());
  });
}

// ------------------------------------------------------------ connect

class _Live {
  _Live(this.client, this.session);
  final SSHClient client;
  final SessionController session;
}

Future<_Live> _connect(
  String target,
  String? keyPath, {
  required String label,
  String? fingerprint,
}) async {
  final at = target.indexOf('@');
  final user = target.substring(0, at);
  final hostname = target.substring(at + 1);
  final address = (await InternetAddress.lookup(hostname)).first;
  if (address.isLoopback) {
    throw StateError('never against this machine: $hostname is loopback');
  }
  final home = Platform.environment['HOME']!;
  final key = File((keyPath ?? '~/.ssh/id_ed25519').replaceFirst('~', home))
      .readAsStringSync();
  final socket = await SSHSocket.connect(
    hostname,
    22,
    timeout: const Duration(seconds: 10),
  );
  final client = SSHClient(
    socket,
    username: user,
    identities: SSHKeyPair.fromPem(key),
    onVerifyHostKey: (type, presented) =>
        fingerprint == null || String.fromCharCodes(presented) == fingerprint,
  );
  await client.authenticated;
  final connection = SshConnection(
    client: client,
    socket: socket,
    host: Host(
      id: 'demo-$hostname',
      label: label,
      hostname: hostname,
      port: 22,
      username: user,
      authMethod: SshAuthMethod.privateKey,
    ),
  );
  return _Live(client, SessionController(connection: connection));
}

// -------------------------------------------------------------- fonts

Future<void> _loadFonts() async {
  final root = Platform.environment['FLUTTER_ROOT'] ?? '/snap/flutter/current';
  final candidates = [
    '$root/bin/cache/artifacts/material_fonts',
    '${Platform.environment['HOME']}/snap/flutter/common/flutter/bin/cache/artifacts/material_fonts',
  ];
  final fonts = candidates.firstWhere(
    (d) => Directory(d).existsSync(),
    orElse: () => candidates.first,
  );
  Future<void> load(String family, List<String> paths) async {
    final loader = FontLoader(family);
    for (final path in paths) {
      if (!File(path).existsSync()) continue;
      final bytes = File(path).readAsBytesSync();
      loader.addFont(Future.value(ByteData.view(bytes.buffer)));
    }
    await loader.load();
  }

  await load('Roboto', [
    for (final face in ['Regular', 'Medium', 'Bold', 'Light'])
      '$fonts/Roboto-$face.ttf',
  ]);
  await load('MaterialIcons', ['$fonts/MaterialIcons-Regular.otf']);
  // The key bar and a few labels ask for 'monospace', which the test
  // renderer does not have.
  await load('monospace', ['/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf']);
  await load(TerminalFonts.jetBrainsMono, [
    for (final face in ['Regular', 'Bold']) 'assets/fonts/JetBrainsMono-$face.ttf',
  ]);
}
