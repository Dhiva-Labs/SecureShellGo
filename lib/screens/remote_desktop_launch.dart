import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/l10n.dart';
import '../services/remote_desktop/agent_deployer.dart';
import '../services/remote_desktop/agent_endpoint.dart';
import '../services/remote_desktop/agent_failure.dart';
import '../services/remote_desktop/agent_launcher.dart';
import '../services/remote_desktop/agent_manifest.dart';
import '../services/remote_desktop/agent_probe.dart';
import '../services/remote_desktop/csrd_client.dart';
import '../services/remote_desktop/remote_screen_session.dart';
import '../services/remote_desktop/rfb_mac_opener.dart';
import '../services/remote_desktop/server_setup.dart';
import '../services/remote_desktop/virtual_desktop.dart';
import '../services/session_controller.dart';
import '../services/ssh_service.dart';
import '../services/tunnel_carrier.dart';
import 'remote_app_launcher.dart';
import 'remote_desktop_screen.dart';
import 'server_setup_dialog.dart';
import '../widgets/terminal_fonts.dart';

/// "Remote desktop…" on a session: find out what the server can show, offer
/// that, and open the viewer on the choice.
///
/// Nothing here runs until the person asks. Connecting to a server, a
/// headless one included, uploads, starts and probes nothing: the probe is
/// one exec when this opens, and the agent goes over only once a kind of
/// remote desktop is picked. That is what keeps an SSH session that never
/// opens a remote desktop exactly as light as it was before there was one.
///
/// With [virtualOnly] the chooser is skipped for the virtual-desktop setup,
/// where the server can run one: the way out the app launcher offers when
/// a program's window cannot open on this device.
Future<void> startRemoteDesktop(
  BuildContext context,
  SessionController session, {
  bool virtualOnly = false,
}) async {
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final transport = session.connection;

  final checked = await _whileChecking(context, l10n, () async {
    final probe = await RemoteDesktopProbe.run(transport);
    var running = const <VirtualDesktopRecord>[];
    String? listError;
    if (probe.os == AgentOs.linux) {
      // A list that cannot be read is no reason not to offer the rest, but
      // it is said: a desktop kept running that does not show up looks lost.
      try {
        running = await listVirtualDesktops(transport);
      } catch (e) {
        listError = _describe(e);
      }
    }
    return (probe: probe, running: running, listError: listError);
  });
  if (checked == null || !context.mounted) return;
  final (:probe, :running, :listError) = checked;

  final linux = probe.linux;
  if (virtualOnly &&
      linux != null &&
      (linux.hasXvfb || packageManagerFor(linux.osRelease) != null)) {
    await _startVirtual(context, session, probe);
    return;
  }

  final choice = await showDialog<_Choice>(
    context: context,
    builder: (_) => _Chooser(
      hostName: session.host.displayName,
      probe: probe,
      running: running,
      listError: listError,
      session: session,
    ),
  );
  if (choice == null || !context.mounted) return;
  switch (choice) {
    case _ShowDesktop():
      await openRemoteDesktop(
        context,
        hostName: session.host.displayName,
        opener: _desktopOpener(l10n, session, probe),
      );
    case _NewVirtual():
      await _startVirtual(context, session, probe);
    case _Reattach(:final record):
      await openRemoteDesktop(
        context,
        hostName: session.host.displayName,
        opener: _reattachOpener(l10n, session, record),
      );
    case _MacScreen():
      final carrier = _carrierOf(session);
      await openRemoteDesktop(
        context,
        hostName: session.host.displayName,
        opener: rfbMacOpener(
          run: rfbCommandRunner(transport),
          forwardLocal: carrier.forwardLocal,
          credentials: (kind) => _askVncCredentials(context, kind),
        ),
      );
  }
  messenger?.hideCurrentSnackBar();
}

/// The launcher's "Installed apps…" list: the server's `.desktop` entries,
/// as the app launcher wants them.
Future<List<InstalledRemoteApp>> installedRemoteApps(
  SessionController session,
) async => [
  for (final app in await listDesktopApps(session.connection))
    (name: app.name, command: app.command),
];

// ------------------------------------------------------------- checking

/// Runs [work] behind a small modal "Checking…" that Cancel abandons.
/// Returns null when cancelled or failed; a failure is said in a snackbar.
Future<T?> _whileChecking<T>(
  BuildContext context,
  AppLocalizations l10n,
  Future<T> Function() work,
) async {
  final navigator = Navigator.of(context);
  final messenger = ScaffoldMessenger.maybeOf(context);
  var open = true;
  final dialog = showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      content: Row(
        children: [
          const SizedBox.square(
            dimension: 24,
            child: CircularProgressIndicator(strokeWidth: 3),
          ),
          const SizedBox(width: 20),
          Expanded(child: Text(l10n.remoteDesktopLaunchChecking)),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.remoteDesktopCancel),
        ),
      ],
    ),
  ).whenComplete(() => open = false);

  T? result;
  Object? failure;
  try {
    result = await work();
  } catch (e) {
    failure = e;
  }
  if (!open) return null; // Cancelled: whatever came back is not wanted.
  navigator.pop();
  await dialog;
  if (failure != null) {
    messenger?.showSnackBar(
      SnackBar(content: Text(l10n.remoteDesktopLaunchFailed(_describe(failure)))),
    );
    return null;
  }
  return result;
}

String _describe(Object error) {
  if (error is AgentFailure) return error.message;
  final text = error.toString();
  return text.startsWith('Exception: ') ? text.substring(11) : text;
}

// -------------------------------------------------------------- openers

/// Loaded on the first remote desktop and kept: the manifest is a kilobyte,
/// and the agents themselves are only unpacked on the way to a server.
Future<AgentBundle>? _bundle;

Future<AgentBundle> _agentBundle() => _bundle ??= AgentBundle.load(
  loadText: rootBundle.loadString,
  loadBytes: (key) async => (await rootBundle.load(key)).buffer.asUint8List(),
);

TunnelCarrier _carrierOf(SessionController session) {
  final transport = session.connection;
  if (transport is SshConnection) {
    // Borrowed, as tunnels borrow it: closing the viewer must not hang up
    // on the shell.
    return SshTunnelCarrier.borrowed(transport.client);
  }
  throw const AgentFailure(
    AgentFailureKind.transport,
    'This session has no SSH connection to carry a remote desktop.',
  );
}

/// What the agent shows the person at the remote screen: "Your screen is
/// being viewed from …".
String _viewerName() {
  String host;
  try {
    host = Platform.localHostname;
  } catch (_) {
    host = '';
  }
  return host.isEmpty || host == 'localhost'
      ? 'SecureShell Go'
      : 'SecureShell Go on $host';
}

void Function(int, int) _uploadProgress(
  AppLocalizations l10n,
  RemoteScreenProgress progress,
) => (sent, total) => progress(
  l10n.remoteDesktopStatusUploading(total <= 0 ? 100 : sent * 100 ~/ total),
);

/// Opens the channel to a running agent and connects to it. On failure the
/// agent is let go of with [release], so a failed open leaves nothing
/// running that the person did not ask to keep.
Future<RemoteScreenHandle> _connect({
  required AppLocalizations l10n,
  required SessionController session,
  required AgentEndpoint endpoint,
  required RemoteScreenProgress progress,
  required void Function(RemoteScreenSession) attach,
  required Future<void> Function() release,
  String? title,
  bool keepsRunning = false,
}) async {
  try {
    progress(l10n.remoteDesktopConnecting);
    final socket = await openAgentChannel(_carrierOf(session), endpoint);
    final client = CsrdClient(input: socket.stream, output: socket.sink);
    attach(client);
    await client.connect(
      CsrdConnectOptions(token: endpoint.tokenBytes, viewerName: _viewerName()),
    );
    return RemoteScreenHandle(
      session: client,
      release: release,
      title: title,
      keepsRunning: keepsRunning,
    );
  } catch (_) {
    await release();
    rethrow;
  }
}

/// The desktop signed in on the server. [probe] serves the first open; a
/// reconnect probes again, since whoever is signed in may have changed.
RemoteScreenOpener _desktopOpener(
  AppLocalizations l10n,
  SessionController session,
  RemoteDesktopProbe probe,
) {
  RemoteDesktopProbe? first = probe;
  return ({required progress, required attach}) async {
    final transport = session.connection;
    progress(l10n.remoteDesktopStatusPreparing);
    final bundle = await _agentBundle();
    final current = first ?? await RemoteDesktopProbe.run(transport);
    first = null;
    final agent = await AgentDeployer(bundle).deploy(
      transport,
      current,
      purpose: AgentPurpose.desktop,
      onProgress: _uploadProgress(l10n, progress),
    );
    progress(l10n.remoteDesktopStatusStarting);
    final endpoint = await const AgentLauncher().launchDesktop(
      transport,
      current,
      agent,
    );
    return _connect(
      l10n: l10n,
      session: session,
      endpoint: endpoint,
      progress: progress,
      attach: attach,
      release: endpoint.stop,
    );
  };
}

/// A new virtual desktop. One kept running is started once: Reconnect on
/// the viewer, or a dropped link, comes back to the same desktop instead of
/// starting another beside it.
RemoteScreenOpener _virtualOpener(
  AppLocalizations l10n,
  SessionController session,
  RemoteDesktopProbe probe,
  VirtualDesktopSpec spec,
) {
  VirtualDesktopRecord? kept;
  return ({required progress, required attach}) async {
    final transport = session.connection;
    final record = kept;
    if (record != null) {
      return _reattachOpener(l10n, session, record)(
        progress: progress,
        attach: attach,
      );
    }
    progress(l10n.remoteDesktopStatusPreparing);
    final bundle = await _agentBundle();
    final agent = await AgentDeployer(bundle).deploy(
      transport,
      probe,
      purpose: AgentPurpose.virtualDesktop,
      onProgress: _uploadProgress(l10n, progress),
    );
    progress(l10n.remoteDesktopStatusStartingVirtual);
    final desktop = await const VirtualDesktops().start(
      transport,
      probe.linux!,
      agent,
      spec,
    );
    kept = desktop.record;
    final handle = await _connect(
      l10n: l10n,
      session: session,
      endpoint: desktop.endpoint,
      progress: progress,
      attach: attach,
      // Stopping the endpoint of a virtual desktop stops the desktop, which
      // is right for one that goes with the viewer and wrong for one kept.
      release: desktop.keepsRunning ? () async {} : desktop.endpoint.stop,
      title: l10n.remoteDesktopVirtualScreenTitle(desktop.display),
      keepsRunning: desktop.keepsRunning,
    );
    // A program that gives up a few seconds in would leave the viewer on an
    // empty screen; end it with the program's own words instead.
    unawaited(() async {
      try {
        final failed = await const VirtualDesktops()
            .watchProgram(transport, desktop.endpoint.runtimeDir);
        if (failed == null) return;
        final detail = failed.log.trim();
        await handle.session.close(
          error: [l10n.remoteDesktopProgramStopped(failed.code), detail]
              .where((t) => t.isNotEmpty)
              .join('\n'),
        );
      } catch (_) {
        // Watching is a courtesy; the desktop itself is unaffected.
      }
    }());
    return handle;
  };
}

/// Back to a virtual desktop that was kept running. Leaving only detaches.
RemoteScreenOpener _reattachOpener(
  AppLocalizations l10n,
  SessionController session,
  VirtualDesktopRecord record,
) {
  return ({required progress, required attach}) async {
    progress(l10n.remoteDesktopStatusReattaching);
    final endpoint = await const VirtualDesktops().attach(
      session.connection,
      record,
    );
    return _connect(
      l10n: l10n,
      session: session,
      endpoint: endpoint,
      progress: progress,
      attach: attach,
      release: () async {},
      title: l10n.remoteDesktopVirtualScreenTitle(record.display),
      keepsRunning: true,
    );
  };
}

Future<void> _startVirtual(
  BuildContext context,
  SessionController session,
  RemoteDesktopProbe probe,
) async {
  final l10n = context.l10n;
  var current = probe;
  final linux = current.linux!;
  if (!linux.hasXvfb) {
    final pm = packageManagerFor(linux.osRelease);
    if (pm == null) return;
    final installed = await showServerSetup(
      context,
      transport: session.connection,
      hostName: session.host.displayName,
      pm: pm,
      items: [
        SetupItem(
          title: l10n.remoteDesktopSetupXvfb,
          detail: l10n.remoteDesktopSetupXvfbDetail,
          packages: SetupPackages.xvfb(pm),
        ),
        // Offered, ticked, when there is no desktop to run: an empty screen
        // is rarely what was wanted. It can be unticked.
        if (linux.virtualSessions.isEmpty)
          SetupItem(
            title: l10n.remoteDesktopSetupDesktop,
            detail: l10n.remoteDesktopSetupDesktopDetail,
            packages: SetupPackages.desktop(pm),
            required: false,
          ),
      ],
    );
    if (!installed || !context.mounted) return;
    // Look again: what is installed now decides what the setup offers.
    final again = await _whileChecking(
        context, l10n, () => RemoteDesktopProbe.run(session.connection));
    if (again == null || !context.mounted) return;
    current = again;
  }
  final spec = await showDialog<VirtualDesktopSpec>(
    context: context,
    builder: (_) => _VirtualDesktopDialog(session: session, probe: current),
  );
  if (spec == null || !context.mounted) return;
  await openRemoteDesktop(
    context,
    hostName: session.host.displayName,
    opener: _virtualOpener(l10n, session, current, spec),
  );
}

Future<({String? username, String password})?> _askVncCredentials(
  BuildContext context,
  RfbAuthKind kind,
) async {
  if (!context.mounted) return null;
  return showDialog<({String? username, String password})>(
    context: context,
    builder: (_) => _VncCredentialsDialog(kind: kind),
  );
}

// -------------------------------------------------------------- chooser

sealed class _Choice {
  const _Choice();
}

final class _ShowDesktop extends _Choice {
  const _ShowDesktop();
}

final class _NewVirtual extends _Choice {
  const _NewVirtual();
}

final class _Reattach extends _Choice {
  const _Reattach(this.record);
  final VirtualDesktopRecord record;
}

final class _MacScreen extends _Choice {
  const _MacScreen();
}

/// What this server can show, each with why not when it cannot: a choice
/// that is greyed out with its reason says more than one that is missing.
class _Chooser extends StatefulWidget {
  const _Chooser({
    required this.hostName,
    required this.probe,
    required this.running,
    required this.session,
    this.listError,
  });

  final String hostName;
  final RemoteDesktopProbe probe;
  final List<VirtualDesktopRecord> running;

  /// Why the running virtual desktops could not be listed, if they could not.
  final String? listError;
  final SessionController session;

  @override
  State<_Chooser> createState() => _ChooserState();
}

class _ChooserState extends State<_Chooser> {
  late final List<VirtualDesktopRecord> _running = [...widget.running];
  final Set<String> _stopping = {};

  Future<void> _stop(VirtualDesktopRecord record) async {
    setState(() => _stopping.add(record.id));
    try {
      await stopVirtualDesktop(widget.session.connection, record.id);
      if (mounted) setState(() => _running.remove(record));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(_describe(e))),
      );
    } finally {
      if (mounted) setState(() => _stopping.remove(record.id));
    }
  }

  void _choose(_Choice choice) => Navigator.of(context).pop(choice);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final probe = widget.probe;
    final linux = probe.linux;
    final children = <Widget>[];

    if (probe.family == RemoteOsFamily.macos) {
      children.add(
        ListTile(
          leading: const Icon(Icons.laptop_mac_outlined),
          title: Text(l10n.remoteDesktopLaunchMac),
          subtitle: Text(l10n.remoteDesktopLaunchMacHint),
          onTap: () => _choose(const _MacScreen()),
        ),
      );
    } else if (!probe.isSupported) {
      children.add(
        ListTile(
          leading: const Icon(Icons.block),
          title: Text(l10n.remoteDesktopLaunchUnsupported),
        ),
      );
    } else {
      final desktop = probe.desktop;
      final why = switch (desktop) {
        DesktopAvailable() => null,
        DesktopOfAnotherUser(:final users) => l10n.remoteDesktopLaunchOtherUser(
          users.join(', '),
        ),
        Headless() => l10n.remoteDesktopLaunchNoDesktop,
      };
      children.add(
        ListTile(
          leading: Icon(
            probe.os == AgentOs.windows
                ? Icons.desktop_windows_outlined
                : Icons.monitor_outlined,
          ),
          title: Text(l10n.remoteDesktopLaunchShowDesktop),
          subtitle: Text(why ?? l10n.remoteDesktopLaunchShowDesktopHint),
          enabled: why == null,
          onTap: why == null ? () => _choose(const _ShowDesktop()) : null,
        ),
      );

      if (linux != null) {
        final support = VirtualDesktopSupport.of(linux);
        // What is missing, the app installs on a click where it knows the
        // server's package manager; only elsewhere is the person handed a
        // command.
        final installable = packageManagerFor(linux.osRelease) != null;
        final available = support.hasXvfb || installable;
        children.add(
          ListTile(
            leading: const Icon(Icons.add_to_queue_outlined),
            title: Text(l10n.remoteDesktopLaunchNewVirtual),
            subtitle: Text(
              support.hasXvfb
                  ? l10n.remoteDesktopLaunchNewVirtualHint
                  : installable
                      ? l10n.remoteDesktopLaunchSetupNeeded
                      : l10n.remoteDesktopLaunchNeedsXvfb,
            ),
            enabled: available,
            onTap: available ? () => _choose(const _NewVirtual()) : null,
          ),
        );
        final install = support.xvfbInstall;
        if (!available && install != null) {
          children.add(_CommandLine(command: install.command));
        }
        final listError = widget.listError;
        if (listError != null) {
          children.add(
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                l10n.remoteDesktopLaunchListFailed(listError),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          );
        }
        if (_running.isNotEmpty) {
          children.add(
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text(
                l10n.remoteDesktopLaunchRunning,
                style: theme.textTheme.titleSmall,
              ),
            ),
          );
          for (final record in _running) {
            final stopping = _stopping.contains(record.id);
            children.add(
              ListTile(
                leading: const Icon(Icons.layers_outlined),
                title: Text(
                  l10n.remoteDesktopLaunchRunningItem(
                    record.label,
                    record.display,
                    record.width,
                    record.height,
                  ),
                ),
                onTap: stopping ? null : () => _choose(_Reattach(record)),
                trailing: stopping
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : TextButton(
                        onPressed: () => _stop(record),
                        child: Text(l10n.remoteDesktopLaunchStop),
                      ),
              ),
            );
          }
        }
      }
    }

    if (probe.isSupported) {
      children.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Text(
            l10n.remoteDesktopLaunchHelperNote,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }

    return AlertDialog(
      title: Text(l10n.remoteDesktopLaunchTitle(widget.hostName)),
      contentPadding: const EdgeInsets.only(top: 12, bottom: 8),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: children),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.remoteDesktopCancel),
        ),
      ],
    );
  }
}

/// A command to run on the server, shown to be copied rather than run: the
/// app never types a sudo password for anyone.
class _CommandLine extends StatelessWidget {
  const _CommandLine({required this.command});

  final String command;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        padding: const EdgeInsets.only(left: 12),
        child: Row(
          children: [
            Expanded(
              child: SelectableText(
                command,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontFamily: TerminalFonts.jetBrainsMono,
                ),
              ),
            ),
            IconButton(
              tooltip: l10n.remoteDesktopLaunchCopy,
              icon: const Icon(Icons.copy_outlined, size: 20),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: command));
                if (!context.mounted) return;
                ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                  SnackBar(content: Text(l10n.remoteDesktopLaunchCopied)),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------ virtual desktop

/// The sizes offered besides this window's own: common ones a desktop
/// session lays out well in.
const List<(int, int)> _presetSizes = [
  (1280, 720),
  (1600, 900),
  (1920, 1080),
  (2560, 1440),
];

/// This window in physical pixels, rounded down to a multiple of 8 and
/// kept within what the agent and a desktop session handle sensibly. On a
/// phone in portrait it is turned landscape: desktops are laid out for it.
(int, int) _fitSize(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  final ratio = MediaQuery.devicePixelRatioOf(context);
  var w = (size.width * ratio).floor();
  var h = (size.height * ratio).floor();
  if (h > w) (w, h) = (h, w);
  w = (w.clamp(640, 3840) ~/ 8) * 8;
  h = (h.clamp(480, 2160) ~/ 8) * 8;
  return (w, h);
}

class _VirtualDesktopDialog extends StatefulWidget {
  const _VirtualDesktopDialog({required this.session, required this.probe});

  final SessionController session;
  final RemoteDesktopProbe probe;

  @override
  State<_VirtualDesktopDialog> createState() => _VirtualDesktopDialogState();
}

class _VirtualDesktopDialogState extends State<_VirtualDesktopDialog> {
  /// Looked at again after the app installs something, so what it offers
  /// follows what is there.
  late LinuxProbe _linux = widget.probe.linux!;
  late VirtualDesktopSupport _support = VirtualDesktopSupport.of(_linux);
  final _command = TextEditingController();

  /// The desktop session to run, or null for one program.
  late VirtualSessionKind? _session = _support.sessions.firstOrNull;
  (int, int)? _size;
  bool _keep = false;
  String? _commandError;
  bool _loadingApps = false;

  /// Checking for, or installing, something on the server.
  bool _busy = false;

  /// The program typed is not on the server, and the package that has it,
  /// where the server could say.
  ({String program, String? package})? _missing;

  PackageManager? get _pm => packageManagerFor(_linux.osRelease);

  Future<void> _reprobe() async {
    try {
      final again = await RemoteDesktopProbe.run(widget.session.connection);
      final linux = again.linux;
      if (!mounted || linux == null) return;
      setState(() {
        _linux = linux;
        _support = VirtualDesktopSupport.of(linux);
        _session = _support.sessions.firstOrNull ?? _session;
      });
    } catch (_) {
      // What was offered before still stands.
    }
  }

  Future<bool> _install(List<SetupItem> items) async {
    final pm = _pm;
    final packages = items.any((i) => i.packages.isNotEmpty);
    if (pm == null && packages) return false;
    setState(() => _busy = true);
    try {
      return await showServerSetup(
        context,
        transport: widget.session.connection,
        hostName: widget.session.host.displayName,
        // Not used when nothing is to be installed from packages.
        pm: pm ?? PackageManager.apt,
        items: items,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _installDesktop() async {
    final pm = _pm;
    if (pm == null) return;
    final l10n = context.l10n;
    final installed = await _install([
      SetupItem(
        title: l10n.remoteDesktopSetupDesktop,
        detail: l10n.remoteDesktopSetupDesktopDetail,
        packages: SetupPackages.desktop(pm),
      ),
    ]);
    if (installed && mounted) {
      setState(() => _busy = true);
      await _reprobe();
      if (mounted) setState(() => _busy = false);
    }
  }

  /// The app typed or picked, when it is one that needs extra options to
  /// start as root and this account is root: the note under the field says
  /// what is added.
  String? get _rootProgram {
    if (_linux.uid != 0) return null;
    final program = programOf(_command.text);
    if (program == null || rootArgumentsFor(program) == null) return null;
    return program.split('/').last;
  }

  Future<void> _allowKeepRunning() async {
    final l10n = context.l10n;
    final allowed = await _install([
      SetupItem(
        title: l10n.remoteDesktopSetupLinger,
        detail: l10n.remoteDesktopSetupLingerDetail,
        steps: const [SetupStep.keepRunning],
      ),
    ]);
    if (allowed && mounted) {
      setState(() => _busy = true);
      await _reprobe();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _installProgram(List<(int, int)> sizes) async {
    final missing = _missing;
    final package = missing?.package;
    if (missing == null || package == null) return;
    final l10n = context.l10n;
    final installed = await _install([
      SetupItem(
        title: missing.program,
        detail: l10n.remoteDesktopSetupProgramDetail(package),
        packages: [package],
      ),
    ]);
    if (installed && mounted) {
      setState(() => _missing = null);
      await _start(sizes);
    }
  }

  @override
  void dispose() {
    _command.dispose();
    super.dispose();
  }

  Future<void> _pickApp() async {
    setState(() => _loadingApps = true);
    List<InstalledRemoteApp> apps;
    try {
      apps = await installedRemoteApps(widget.session);
    } catch (_) {
      apps = const [];
    }
    if (!mounted) return;
    setState(() => _loadingApps = false);
    final l10n = context.l10n;
    final picked = await showDialog<InstalledRemoteApp>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(l10n.remoteAppInstalledTitle),
        children: [
          if (apps.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(l10n.remoteAppInstalledEmpty),
            ),
          for (final app in apps)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(app),
              child: Text(app.name),
            ),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _command.text = picked.command;
      _commandError = null;
      _missing = null;
    });
  }

  Future<void> _start(List<(int, int)> sizes) async {
    if (_busy) return;
    final session = _session;
    final VirtualDesktopContent content;
    if (session != null) {
      content = VirtualSessionContent(session);
    } else {
      final command = _command.text.trim();
      if (command.isEmpty) {
        setState(
          () => _commandError = context.l10n.remoteDesktopVirtualNeedsCommand,
        );
        return;
      }
      // A program that is not there would only open an empty screen; say so
      // here, and offer to install it, before anything starts.
      final program = programOf(command);
      if (program != null) {
        setState(() => _busy = true);
        final transport = widget.session.connection;
        var exists = true;
        String? package;
        try {
          exists = await programExists(transport, program);
          if (!exists && _pm == PackageManager.apt) {
            package = await packageForProgram(transport, program);
          }
        } catch (_) {
          // Could not check: let the start say what happens.
        }
        if (!mounted) return;
        setState(() {
          _busy = false;
          _missing = exists ? null : (program: program, package: package);
        });
        if (!exists) return;
      }
      final extra = _linux.uid == 0 && program != null && !command.contains('--no-sandbox')
          ? rootArgumentsFor(program)
          : null;
      content = VirtualAppContent(extra == null ? command : '$command $extra',
          label: program?.split('/').last);
    }
    final (w, h) = _size ?? sizes.first;
    Navigator.of(context).pop(
      VirtualDesktopSpec(
        width: w,
        height: h,
        content: content,
        keepRunning: _keep,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final fit = _fitSize(context);
    final sizes = [
      fit,
      for (final s in _presetSizes)
        if (s != fit) s,
    ];
    final size = _size ?? fit;

    return AlertDialog(
      title: Text(l10n.remoteDesktopVirtualTitle),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.remoteDesktopVirtualWhat, style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
              if (_support.sessions.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    l10n.remoteDesktopVirtualNoSessions,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              // A headless server rarely has a desktop, and one program on
              // an empty screen is seldom what was wanted: offer to install
              // one.
              if (_support.sessions.isEmpty && _pm != null) ...[
                FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
                  onPressed: _busy ? null : () => unawaited(_installDesktop()),
                  icon: const Icon(Icons.download_outlined),
                  label: Text(l10n.remoteDesktopVirtualInstallDesktopButton),
                ),
                const SizedBox(height: 8),
              ],
              RadioGroup<VirtualSessionKind?>(
                groupValue: _session,
                onChanged: (value) => setState(() => _session = value),
                child: Column(
                  children: [
                    for (final kind in _support.sessions)
                      RadioListTile<VirtualSessionKind?>(
                        contentPadding: EdgeInsets.zero,
                        value: kind,
                        title: Text(l10n.remoteDesktopVirtualSession(kind.label)),
                      ),
                    RadioListTile<VirtualSessionKind?>(
                      contentPadding: EdgeInsets.zero,
                      value: null,
                      title: Text(l10n.remoteDesktopVirtualOneApp),
                    ),
                  ],
                ),
              ),
              if (_session == null) ...[
                // Picking from what the server has comes first: most people
                // know the app they want, not the command that starts it.
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: FilledButton.tonalIcon(
                    style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
                    onPressed: _loadingApps || _busy ? null : _pickApp,
                    icon: _loadingApps
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.apps_outlined),
                    label: Text(l10n.remoteAppInstalledApps),
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _command,
                  decoration: InputDecoration(
                    labelText: l10n.remoteDesktopVirtualOrType,
                    hintText: l10n.remoteAppCommandHint,
                    errorText: _commandError,
                  ),
                  onChanged: (_) => setState(() {
                    _commandError = null;
                    _missing = null;
                  }),
                  onSubmitted: (_) => unawaited(_start(sizes)),
                ),
                if (_rootProgram case final program?) ...[
                  const SizedBox(height: 6),
                  Text(
                    l10n.remoteDesktopVirtualRootNote(program),
                    style: theme.textTheme.bodySmall,
                  ),
                ],
                if (_missing case final missing?) ...[
                  const SizedBox(height: 8),
                  Text(
                    l10n.remoteDesktopVirtualProgramMissing(missing.program),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                  if (missing.package case final package?) ...[
                    const SizedBox(height: 6),
                    FilledButton.tonalIcon(
                      style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
                      onPressed:
                          _busy ? null : () => unawaited(_installProgram(sizes)),
                      icon: const Icon(Icons.download_outlined),
                      label: Text(l10n.remoteDesktopVirtualInstallProgram(package)),
                    ),
                  ],
                ],
              ],
              const SizedBox(height: 12),
              DropdownButtonFormField<(int, int)>(
                initialValue: size,
                decoration: InputDecoration(labelText: l10n.remoteDesktopVirtualSize),
                items: [
                  for (final s in sizes)
                    DropdownMenuItem(
                      value: s,
                      child: Text(
                        s == fit
                            ? l10n.remoteDesktopVirtualSizeFit(s.$1, s.$2)
                            : '${s.$1}×${s.$2}',
                      ),
                    ),
                ],
                onChanged: (value) => setState(() => _size = value),
              ),
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _keep,
                onChanged: (value) => setState(() => _keep = value ?? false),
                title: Text(l10n.remoteDesktopVirtualKeep),
                subtitle: Text(l10n.remoteDesktopVirtualKeepHint),
              ),
              if (_keep && _support.keepRunningNeedsLinger) ...[
                Text(
                  l10n.remoteDesktopVirtualLingerAsk,
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 6),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: FilledButton.tonal(
                    style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
                    onPressed: _busy ? null : () => unawaited(_allowKeepRunning()),
                    child: Text(l10n.remoteDesktopVirtualLingerAllow),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.remoteDesktopCancel),
        ),
        FilledButton(
          // The theme's buttons fill the width, which a dialog's action row
          // has no room for; the app's other dialogs say the same.
          style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
          onPressed: _busy ? null : () => unawaited(_start(sizes)),
          child: _busy
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(l10n.remoteDesktopVirtualStart),
        ),
      ],
    );
  }
}

// ------------------------------------------------------------ VNC login

class _VncCredentialsDialog extends StatefulWidget {
  const _VncCredentialsDialog({required this.kind});

  final RfbAuthKind kind;

  @override
  State<_VncCredentialsDialog> createState() => _VncCredentialsDialogState();
}

class _VncCredentialsDialogState extends State<_VncCredentialsDialog> {
  final _user = TextEditingController();
  final _password = TextEditingController();

  bool get _needsUser => widget.kind == RfbAuthKind.appleAccount;

  @override
  void dispose() {
    _user.dispose();
    _password.dispose();
    super.dispose();
  }

  void _submit() {
    Navigator.of(context).pop((
      username: _needsUser ? _user.text : null,
      password: _password.text,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.remoteDesktopVncTitle),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _needsUser
                  ? l10n.remoteDesktopVncAccountHint
                  : l10n.remoteDesktopVncPasswordHint,
            ),
            if (_needsUser)
              TextField(
                controller: _user,
                autofocus: true,
                autocorrect: false,
                decoration: InputDecoration(labelText: l10n.remoteDesktopVncUser),
              ),
            TextField(
              controller: _password,
              autofocus: !_needsUser,
              obscureText: true,
              decoration: InputDecoration(labelText: l10n.remoteDesktopVncPassword),
              onSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.remoteDesktopCancel),
        ),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
          onPressed: _submit,
          child: Text(l10n.remoteDesktopVncSignIn),
        ),
      ],
    );
  }
}
