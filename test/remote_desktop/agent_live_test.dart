import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/services/remote_desktop/agent_deployer.dart';
import 'package:secure_shell_go/services/remote_desktop/agent_endpoint.dart';
import 'package:secure_shell_go/services/remote_desktop/agent_failure.dart';
import 'package:secure_shell_go/services/remote_desktop/agent_launcher.dart';
import 'package:secure_shell_go/services/remote_desktop/agent_manifest.dart';
import 'package:secure_shell_go/services/remote_desktop/agent_probe.dart';
import 'package:secure_shell_go/services/remote_desktop/virtual_desktop.dart';
import 'package:secure_shell_go/services/remote_exec.dart';
import 'package:secure_shell_go/services/ssh_service.dart';
import 'package:secure_shell_go/services/tunnel_carrier.dart';

/// Deploy, launch and stop against real servers.
///
/// Opt-in, and never against this machine: the agent's Mutter backend needs
/// no consent, so a real-capture agent here would silently drive the
/// developer's own desktop. Linux runs go to a VM; the Windows run captures
/// a real session, so it starts the synthetic test pattern only and injects
/// nothing.
///
/// ```sh
/// tool/stage_agents.sh                    # or STAGE_AGENTS_OUT=… for a scratch copy
/// SSGO_RD_AGENTS=assets/agents \
/// SSGO_RD_LINUX=ubuntu@10.155.212.110 SSGO_RD_LINUX_KEY=path/to/key \
/// SSGO_RD_WINDOWS=dhiva@192.168.0.129 SSGO_RD_WINDOWS_KEY=~/.ssh/id_ed25519 \
/// SSGO_RD_WINDOWS_FINGERPRINTS=SHA256:…,SHA256:… \
///   flutter test test/remote_desktop/agent_live_test.dart
/// ```
///
/// The Linux VM wants Xvfb and a user with lingering on
/// (`loginctl enable-linger`), and should have no desktop of its own.
void main() {
  final env = Platform.environment;
  final agents = env['SSGO_RD_AGENTS'];
  final noAgents = agents == null ? 'set SSGO_RD_AGENTS to a staged agents folder' : null;
  final linuxSkip = noAgents ?? (env['SSGO_RD_LINUX'] == null ? 'set SSGO_RD_LINUX' : null);
  final windowsSkip =
      noAgents ?? (env['SSGO_RD_WINDOWS'] == null ? 'set SSGO_RD_WINDOWS' : null);
  const timeout = Timeout(Duration(minutes: 3));

  late AgentBundle bundle;
  setUpAll(() {
    if (agents == null) return;
    bundle = AgentBundle(
      manifest: AgentManifest.parse(File('$agents/manifest.json').readAsStringSync()),
      loadBytes: (key) => File('$agents/${key.split('/').last}').readAsBytes(),
    );
  });

  group('Linux VM', () {
    late _Live live;
    setUp(() async {
      if (linuxSkip != null) return;
      live = await _Live.connect(
          env['SSGO_RD_LINUX']!, env['SSGO_RD_LINUX_KEY'], env['SSGO_RD_LINUX_FINGERPRINTS']);
    });
    tearDown(() async {
      if (linuxSkip != null) return;
      live.close();
    });

    test('probe: a headless server with Xvfb', () async {
      final probe = await RemoteDesktopProbe.run(live.connection);
      final linux = probe.linux!;
      printOnFailure('sessions: ${linux.sessions.map((s) => '${s.id}:${s.type}')}');
      expect(probe.os, AgentOs.linux);
      expect(probe.arch, AgentArch.x86_64);
      expect(probe.desktop, isA<Headless>());
      expect(linux.hasXvfb, isTrue);
      expect(linux.hasSystemdRun, isTrue);
      expect(linux.runtimeDir, '/run/user/${linux.uid}');
      // ignore: avoid_print
      print('probe: uid ${linux.uid}, glibc ${linux.glibcVersion}, pipewire '
          '${linux.hasLibPipewire}, linger ${linux.lingering}, tools ${linux.tools}');
    }, skip: linuxSkip, timeout: timeout);

    test('deploy uploads once, then skips; a tampered copy is refused and '
        'replaced', () async {
      await live.sh('rm -rf "\$HOME/.cache/secureshellgo/agent"');
      final probe = await RemoteDesktopProbe.run(live.connection);
      final deployer = AgentDeployer(bundle);
      var progress = 0;
      final first = await deployer.deploy(live.connection, probe,
          purpose: AgentPurpose.virtualDesktop,
          onProgress: (sent, total) => progress = sent);
      expect(first.uploaded, isTrue);
      expect(progress, first.binary.size);
      expect(first.binary.flavour, AgentFlavour.x11);
      final mode = await live.sh('stat -c %a "${first.path}" "${first.directory}"');
      expect(mode.trim().split('\n'), ['700', '700']);

      final second = await deployer.deploy(live.connection, probe,
          purpose: AgentPurpose.virtualDesktop);
      expect(second.uploaded, isFalse);
      expect(second.path, first.path);

      // Tamper with the installed binary: the launcher must refuse it.
      await live.sh('printf x >> "${first.path}"');
      await expectLater(
        const AgentLauncher().launchLinux(live.connection, first,
            options: const AgentLaunchOptions(synthetic: true, notify: false)),
        throwsA(isA<AgentFailure>()
            .having((f) => f.kind, 'kind', AgentFailureKind.hashMismatch)),
      );
      expect(await live.sh('ls "\$XDG_RUNTIME_DIR" | grep -c ssgo-rd- || true'),
          '0\n');
      // And the next deploy notices and replaces it.
      final repaired = await deployer.deploy(live.connection, probe,
          purpose: AgentPurpose.virtualDesktop);
      expect(repaired.uploaded, isTrue);
    }, skip: linuxSkip, timeout: timeout);

    for (final systemd in [true, false]) {
      test('synthetic agent ${systemd ? 'in a systemd unit' : 'with setsid'}: '
          'host.json, channel, stop leaves nothing', () async {
        final probe = await RemoteDesktopProbe.run(live.connection);
        final agent = await AgentDeployer(bundle).deploy(live.connection, probe,
            purpose: AgentPurpose.virtualDesktop);
        final endpoint = await const AgentLauncher().launchDesktop(
          live.connection,
          probe,
          agent,
          options: AgentLaunchOptions(
              synthetic: true, notify: false, clipboard: false, useSystemd: systemd),
        );
        expect(endpoint.unitName != null, systemd);
        expect(endpoint.version, bundle.manifest.engineVersion);
        expect(await live.sh('ls -ld "${endpoint.runtimeDir}" | cut -c1-10'),
            'drwx------\n');
        final channel = await openAgentChannel(live.carrier, endpoint);
        channel.destroy();

        await endpoint.stop();
        await endpoint.stop();
        await live.expectNothingLeft();
        expect(await live.sh('[ -e "${endpoint.runtimeDir}" ] && echo left || echo gone'),
            'gone\n');
      }, skip: linuxSkip, timeout: timeout);
    }

    test('virtual desktop: an app in Xvfb, reached through the channel, and '
        'stop takes everything down', () async {
      final probe = await RemoteDesktopProbe.run(live.connection);
      final agent = await AgentDeployer(bundle).deploy(live.connection, probe,
          purpose: AgentPurpose.virtualDesktop);
      final apps = await listDesktopApps(live.connection);
      // ignore: avoid_print
      print('apps: ${apps.map((a) => '${a.name}=${a.command}').join(', ')}');
      final session = await const VirtualDesktops().start(
        live.connection,
        probe.linux!,
        agent,
        const VirtualDesktopSpec(
          width: 1024,
          height: 768,
          content: VirtualAppContent('display-im6.q16 logo:', label: 'ImageMagick'),
        ),
      );
      expect(session.display, matches(RegExp(r'^:\d+$')));
      expect(session.keepsRunning, isFalse);
      final ps = await live.sh('ps -u "\$(id -u)" -o args= | grep -E "Xvfb|crossshell-host|display-im6" | grep -v grep');
      // ignore: avoid_print
      print('running:\n$ps');
      expect(ps, contains('Xvfb ${session.display}'));
      expect(ps, contains('display-im6'));
      // The agent and the app see only the virtual display and its cookie.
      final agentEnv = await live.sh(
          'tr "\\000" "\\n" < /proc/${session.endpoint.pid}/environ | sort');
      expect(agentEnv, contains('DISPLAY=${session.display}\n'));
      expect(agentEnv, contains('CROSSSHELL_LINUX_BACKEND=x11\n'));
      expect(agentEnv, isNot(contains('DBUS_SESSION_BUS_ADDRESS')));
      expect(agentEnv, isNot(contains('WAYLAND_DISPLAY')));
      final cookie = await live.sh('stat -c %a "${session.endpoint.runtimeDir}/xauth"');
      expect(cookie, '600\n');

      final channel = await openAgentChannel(live.carrier, session.endpoint);
      channel.destroy();

      await session.endpoint.stop();
      await live.expectNothingLeft();
    }, skip: linuxSkip, timeout: timeout);

    test('virtual desktop kept running survives a disconnect, is listed and '
        'stoppable on reconnect', () async {
      final probe = await RemoteDesktopProbe.run(live.connection);
      final agent = await AgentDeployer(bundle).deploy(live.connection, probe,
          purpose: AgentPurpose.virtualDesktop);
      final session = await const VirtualDesktops().start(
        live.connection,
        probe.linux!,
        agent,
        const VirtualDesktopSpec(
          width: 800,
          height: 600,
          content: VirtualAppContent("display-im6.q16 -title 'it'\"'\"'s kept' logo:"),
          keepRunning: true,
        ),
      );
      expect(session.record, isNotNull);
      live.close();

      // Long enough for the agent's 15 s dropped-viewer grace to be moot:
      // nothing connected, and nothing may idle it out either.
      await Future<void>.delayed(const Duration(seconds: 5));
      live = await _Live.connect(
          env['SSGO_RD_LINUX']!, env['SSGO_RD_LINUX_KEY'], env['SSGO_RD_LINUX_FINGERPRINTS']);
      final listed = await listVirtualDesktops(live.connection);
      expect(listed.map((r) => r.id), [session.id]);
      final record = listed.single;
      expect(record.display, session.display);
      expect(record.width, 800);
      expect(record.command, "display-im6.q16 -title 'it'\"'\"'s kept' logo:");

      final endpoint = await const VirtualDesktops().attach(live.connection, record);
      expect(endpoint.port, session.endpoint.port);
      final channel = await openAgentChannel(live.carrier, endpoint);
      channel.destroy();

      await stopVirtualDesktop(live.connection, record.id);
      expect(await listVirtualDesktops(live.connection), isEmpty);
      await live.expectNothingLeft();
    }, skip: linuxSkip, timeout: timeout);

    test('virtual desktop without a user systemd: setsid, and stop kills the '
        'whole process group', () async {
      final probe = await RemoteDesktopProbe.run(live.connection);
      final agent = await AgentDeployer(bundle).deploy(live.connection, probe,
          purpose: AgentPurpose.virtualDesktop);
      const id = 'fa11bacc0ffee000';
      final out = await live.raw(VirtualDesktops.launchCommand(
        agent: agent,
        id: id,
        runtimeDir: VirtualDesktops.runtimeDirFor(probe.linux!, id),
        spec: const VirtualDesktopSpec(
            width: 640,
            height: 480,
            content: VirtualAppContent('display-im6.q16 logo:'),
            keepRunning: true),
        createdAt: DateTime.now(),
        useSystemd: false,
      ));
      expect(out, contains('SSG-MODE pid'));
      expect(out, contains('SSG-READY'));
      expect((await listVirtualDesktops(live.connection)).map((r) => r.id), [id]);
      await stopVirtualDesktop(live.connection, id);
      await live.expectNothingLeft();
      expect(await listVirtualDesktops(live.connection), isEmpty);
    }, skip: linuxSkip, timeout: timeout);

    test('a record whose desktop died is pruned from the list', () async {
      await live.sh('mkdir -p "\$HOME/.cache/secureshellgo/vdesk" && '
          'printf \'{"v":1,"id":"00000000000000aa","unit":"ssgo-vd-00000000000000aa",'
          '"display":":77","width":1,"height":1,"content":"app","command":"x",'
          '"label":"x","runtimeDir":"/run/user/1000/ssgo-vd-00000000000000aa",'
          '"createdAt":"2026-10-27T00:00:00.000Z","agent":"x"}\' '
          '> "\$HOME/.cache/secureshellgo/vdesk/00000000000000aa.json"');
      expect(await listVirtualDesktops(live.connection), isEmpty);
      expect(await live.sh('ls "\$HOME/.cache/secureshellgo/vdesk"'), '');
    }, skip: linuxSkip, timeout: timeout);

    test('a virtual desktop nobody connects to idles out and takes Xvfb with '
        'it', () async {
      final probe = await RemoteDesktopProbe.run(live.connection);
      final agent = await AgentDeployer(bundle).deploy(live.connection, probe,
          purpose: AgentPurpose.virtualDesktop);
      final session = await const VirtualDesktops().start(
        live.connection,
        probe.linux!,
        agent,
        const VirtualDesktopSpec(
            width: 640, height: 480, content: VirtualAppContent('display-im6.q16 logo:')),
      );
      expect(await live.sh('pgrep -u "\$(id -u)" -c Xvfb || true'), '1\n');
      // --exit-when-idle 30 with no viewer ever: the agent leaves at 30 s and
      // the supervisor ends the unit.
      await Future<void>.delayed(const Duration(seconds: 36));
      await live.expectNothingLeft();
      expect(await live.sh('[ -e "${session.endpoint.runtimeDir}" ] && echo left || echo gone'),
          'gone\n');
    }, skip: linuxSkip, timeout: timeout);
  });

  group('Windows laptop', () {
    late _Live live;
    setUp(() async {
      if (windowsSkip != null) return;
      live = await _Live.connect(env['SSGO_RD_WINDOWS']!, env['SSGO_RD_WINDOWS_KEY'],
          env['SSGO_RD_WINDOWS_FINGERPRINTS']);
    });
    tearDown(() async {
      if (windowsSkip != null) return;
      live.close();
    });

    test('probe: Windows 11 Home has no quser; explorer.exe tells', () async {
      final probe = await RemoteDesktopProbe.run(live.connection);
      final windows = probe.windows!;
      // ignore: avoid_print
      print('windows: ${windows.architecture} ${windows.domain}\\${windows.user} '
          '${windows.osVersion} quser ${windows.queryUserAvailable} explorer '
          '${windows.explorerSessions} ${windows.localAppData}');
      expect(probe.guess.family, RemoteOsFamily.windows);
      expect(probe.arch, isNotNull);
      expect(probe.desktop, isA<DesktopAvailable>());
    }, skip: windowsSkip, timeout: timeout);

    test('probe, deploy, interactive launch, host.json, channel, stop with '
        'nothing left', () async {
      final probe = await RemoteDesktopProbe.run(live.connection);
      final windows = probe.windows!;
      // ignore: avoid_print
      print('windows: ${windows.architecture} ${windows.user} ${windows.osVersion} '
          'sessions ${windows.sessions.map((s) => '${s.user}/${s.id}/${s.state}')}');
      expect(probe.os, AgentOs.windows);
      expect(probe.desktop, isA<DesktopAvailable>());

      final deployer = AgentDeployer(bundle);
      final agent = await deployer.deploy(live.connection, probe,
          purpose: AgentPurpose.desktop);
      final again = await deployer.deploy(live.connection, probe,
          purpose: AgentPurpose.desktop);
      expect(again.uploaded, isFalse);

      final endpoint = await const AgentLauncher().launchDesktop(
        live.connection,
        probe,
        agent,
        options: const AgentLaunchOptions(
            synthetic: true, notify: false, clipboard: false),
      );
      // ignore: avoid_print
      print('agent: pid ${endpoint.pid} port ${endpoint.port} in ${endpoint.runtimeDir}');
      final running = await live.raw(
          'tasklist /FI "PID eq ${endpoint.pid}" /FO CSV /NH');
      expect(running, contains('crossshell-host.exe'));
      // ignore: avoid_print
      print('tasklist: ${running.trim()}');
      expect(await live.raw('schtasks /query /FO CSV /NH'),
          isNot(contains('SSGo-RD-')),
          reason: 'the launch deletes its task once host.json is there');

      final channel = await openAgentChannel(live.carrier, endpoint);
      channel.destroy();

      await endpoint.stop();
      await endpoint.stop();
      expect(await live.raw('tasklist /FI "IMAGENAME eq crossshell-host.exe" /FO CSV /NH'),
          isNot(contains('crossshell-host.exe')));
      expect(await live.raw('schtasks /query /FO CSV /NH'), isNot(contains('SSGo-RD-')));
      expect(
          await live.raw('if exist "${endpoint.runtimeDir}" (echo left) else (echo gone)'),
          contains('gone'));
    }, skip: windowsSkip, timeout: timeout);
  });
}

class _Live {
  _Live(this.connection, this.client);

  final SshConnection connection;
  final SSHClient client;
  late final TunnelCarrier carrier = SshTunnelCarrier.borrowed(client);

  /// [fingerprints] are the `SHA256:…` host-key fingerprints to accept;
  /// a DHCP laptop that moved is still the machine whose key we know.
  /// One retry, because the laptop sleeps when idle and the first attempt
  /// may only wake it.
  static Future<_Live> connect(String target, String? keyPath,
      [String? fingerprints]) async {
    try {
      return await _connect(target, keyPath, fingerprints);
    } on SocketException {
      await Future<void>.delayed(const Duration(seconds: 5));
      return _connect(target, keyPath, fingerprints);
    }
  }

  static Future<_Live> _connect(
      String target, String? keyPath, String? fingerprints) async {
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
    final accepted = fingerprints?.split(',').map((f) => f.trim()).toSet();
    final socket = await SSHSocket.connect(hostname, 22,
        timeout: const Duration(seconds: 10));
    final client = SSHClient(
      socket,
      username: user,
      identities: SSHKeyPair.fromPem(key),
      onVerifyHostKey: (type, fingerprint) =>
          accepted == null || accepted.contains(String.fromCharCodes(fingerprint)),
    );
    await client.authenticated;
    return _Live(
      SshConnection(
        client: client,
        socket: socket,
        host: Host(
          id: 'live',
          label: 'live',
          hostname: hostname,
          port: 22,
          username: user,
          authMethod: SshAuthMethod.privateKey,
        ),
      ),
      client,
    );
  }

  /// A POSIX command, through `sh` whatever the login shell.
  Future<String> sh(String script) async =>
      (await RemoteExec.run(connection, 'sh -c ${_q(script)}')).stdout;

  /// A command as the login shell takes it (cmd.exe on Windows).
  Future<String> raw(String command) async =>
      (await RemoteExec.run(connection, command, timeout: const Duration(seconds: 20)))
          .stdout;

  /// No unit, no agent, no Xvfb, no supervisor of ours on the server.
  Future<void> expectNothingLeft() async {
    // A stop returns once systemd has the unit stopping; give the cgroup a
    // moment to empty.
    for (var i = 0; i < 20; i++) {
      final left = await sh(
          'systemctl --user list-units --all --plain --no-legend "ssgo-*" 2>/dev/null; '
          // Bracketed so the pattern does not match this command's own line.
          'pgrep -u "\$(id -u)" -a -f "[c]rossshell-host|[X]vfb|[s]sgo-vd-|[d]isplay-im6" || true');
      if (left.trim().isEmpty) return;
      if (i == 19) fail('left behind on the server:\n$left');
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }

  void close() => client.close();

  static String _q(String s) => "'${s.replaceAll("'", "'\\''")}'";
}
