import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../services/layout_breakpoints.dart';
import '../services/remote_app_history.dart';
import '../services/remote_app_runner.dart';
import '../services/session_controller.dart';
import '../theme.dart';

/// One program the server has installed, as the picker lists it: a [name]
/// for the person and the [command] that starts it.
typedef InstalledRemoteApp = ({String name, String command});

/// The app's theme makes filled buttons as wide as they are allowed to be,
/// which in a row or a wrap is infinitely wide; these sit beside others.
final ButtonStyle _rowButton =
    FilledButton.styleFrom(minimumSize: const Size(0, 48));

/// "Open an app in a window": start one graphical program on [session]'s
/// server and have its window open on this device, with no terminal.
///
/// A dialog where there is room for one, a bottom sheet on a phone. It
/// returns when it is closed; programs started from it carry on, and are
/// listed again the next time it opens (see [RemoteAppRunner.of]).
///
/// The host's X11 forwarding switch does not have to be on: each app asks for
/// X11 on its own channel. When a window cannot be opened — this device has
/// no X server, the server refused it, the SSH connection is not up — the
/// launcher says which in plain words, and offers what the caller wires:
///
///  * [onFixServer] for a refusal: look at the server and fix what can be
///    fixed from here (install `xauth`), or say what an administrator has to
///    change. True when it fixed something; the launcher then runs the
///    program it was asked for again.
///  * [onOfferVirtualDesktop], for every reason there is: the server's own
///    desktop, which needs no X server here. Called after the launcher has
///    closed itself, so it is free to navigate. [listInstalledApps] adds an "Installed apps…" picker; leave it
/// null where the server's applications cannot be listed.
///
/// [runner] and [history] are for tests; the app uses [RemoteAppRunner.of] and
/// [RemoteAppHistory.instance].
Future<void> openRemoteAppLauncher(
  BuildContext context, {
  required SessionController session,
  VoidCallback? onOfferVirtualDesktop,
  Future<bool> Function()? onFixServer,
  Future<List<InstalledRemoteApp>> Function()? listInstalledApps,
  RemoteAppRunner? runner,
  RemoteAppHistory? history,
}) {
  final body = _LauncherBody(
    session: session,
    runner: runner ?? RemoteAppRunner.of(session),
    history: history ?? RemoteAppHistory.instance,
    onOfferVirtualDesktop: onOfferVirtualDesktop,
    onFixServer: onFixServer,
    listInstalledApps: listInstalledApps,
  );
  final size = MediaQuery.sizeOf(context);
  // A phone turned on its side is wide but only a few hundred dp tall, and a
  // dialog with a field and a keyboard in it would have no room: the same
  // test the session screen uses to decide whether two panes fit.
  if (WindowSizeClass.fitsSideBySide(size.width, size.height)) {
    return showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        insetPadding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 640,
            maxHeight: size.height * 0.85,
          ),
          child: body,
        ),
      ),
    );
  }
  final theme = Theme.of(context);
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: theme.colorScheme.surfaceContainerHigh,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: Padding(
        // Lifts the field above the soft keyboard.
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: size.height * 0.9),
          child: body,
        ),
      ),
    ),
  );
}

class _LauncherBody extends StatefulWidget {
  const _LauncherBody({
    required this.session,
    required this.runner,
    required this.history,
    required this.onOfferVirtualDesktop,
    required this.onFixServer,
    required this.listInstalledApps,
  });

  final SessionController session;
  final RemoteAppRunner runner;
  final RemoteAppHistory history;
  final VoidCallback? onOfferVirtualDesktop;
  final Future<bool> Function()? onFixServer;
  final Future<List<InstalledRemoteApp>> Function()? listInstalledApps;

  @override
  State<_LauncherBody> createState() => _LauncherBodyState();
}

class _LauncherBodyState extends State<_LauncherBody> {
  final TextEditingController _command = TextEditingController();
  final FocusNode _commandFocus = FocusNode();

  List<String> _recent = const [];
  var _launching = false;
  var _checking = false;
  var _fixing = false;

  RemoteAppRunner get _runner => widget.runner;
  String get _hostId => widget.session.host.id;

  @override
  void initState() {
    super.initState();
    _command.addListener(() => setState(() {}));
    unawaited(_loadRecent());
    unawaited(_check());
  }

  @override
  void dispose() {
    _command.dispose();
    _commandFocus.dispose();
    super.dispose();
  }

  Future<void> _loadRecent() async {
    final recent = await widget.history.recent(_hostId);
    if (mounted) setState(() => _recent = recent);
  }

  /// Finds out whether the local X server answers, which only trying says.
  Future<void> _check() async {
    if (_checking) return;
    setState(() => _checking = true);
    try {
      await _runner.probe();
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  /// The server refused X11: fix what can be fixed there, then try the
  /// program again, which is still in the field.
  Future<void> _fixServer() async {
    final fix = widget.onFixServer;
    if (fix == null || _fixing) return;
    setState(() => _fixing = true);
    bool fixed;
    try {
      fixed = await fix();
    } finally {
      if (mounted) setState(() => _fixing = false);
    }
    if (!fixed || !mounted) return;
    _runner.forgetRefusal();
    await _run();
  }

  Future<void> _run() async {
    final text = _command.text.trim();
    if (text.isEmpty ||
        _launching ||
        _runner.availability != RemoteAppAvailability.available) {
      return;
    }
    setState(() => _launching = true);
    RemoteApp? app;
    try {
      app = await _runner.launch(text);
    } on RemoteAppUnavailable {
      // The panel already says why; the runner told it as it found out.
    } finally {
      if (mounted) setState(() => _launching = false);
    }
    if (app == null || app.state is RemoteAppFailed) return;
    // Cleared only for a program that started: one that did not is usually a
    // typo, and wants editing rather than retyping.
    if (mounted) _command.clear();
    await widget.history.record(_hostId, text);
    await _loadRecent();
  }

  Future<void> _pickInstalled() async {
    final list = widget.listInstalledApps;
    if (list == null) return;
    final chosen = await showDialog<InstalledRemoteApp>(
      context: context,
      builder: (context) => _InstalledAppsDialog(load: list),
    );
    if (chosen == null || !mounted) return;
    _command.value = TextEditingValue(
      text: chosen.command,
      selection: TextSelection.collapsed(offset: chosen.command.length),
    );
    _commandFocus.requestFocus();
  }

  Future<void> _forget(String command) async {
    await widget.history.remove(_hostId, command);
    await _loadRecent();
  }

  /// Closes the launcher, then calls [callback]: both buttons that lead away
  /// from here lead somewhere that navigates, and should not do it from under
  /// an open dialog.
  void _leaveFor(VoidCallback callback) {
    Navigator.of(context).pop();
    callback();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return ListenableBuilder(
      listenable: _runner,
      builder: (context, _) {
        final availability = _runner.availability;
        final apps = _runner.apps;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.remoteAppTitle,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ),
                  IconButton(
                    tooltip:
                        MaterialLocalizations.of(context).closeButtonTooltip,
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (availability == RemoteAppAvailability.available)
                      ..._form(context)
                    else
                      _UnavailablePanel(
                        availability: availability,
                        runner: _runner,
                        checking: _checking,
                        onCheckAgain: _check,
                        fixing: _fixing,
                        onFixServer:
                            widget.onFixServer == null ? null : _fixServer,
                        onOfferVirtualDesktop:
                            widget.onOfferVirtualDesktop == null
                                ? null
                                : () => _leaveFor(widget.onOfferVirtualDesktop!),
                      ),
                    if (_showsSecurityNote(availability)) ...[
                      const SizedBox(height: 16),
                      _SecurityNote(runner: _runner),
                    ],
                    if (apps.isNotEmpty) ...[
                      const SizedBox(height: 20),
                      Text(
                        l10n.remoteAppRunningTitle,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 8),
                      for (final app in apps.reversed)
                        _AppTile(app: app, runner: _runner),
                    ],
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// Said once, wherever the person is about to let a server's program draw on
  /// this display — and so not where nothing can: a device with no X server,
  /// or a connection that is down.
  static bool _showsSecurityNote(RemoteAppAvailability availability) =>
      availability != RemoteAppAvailability.unsupportedDevice &&
      availability != RemoteAppAvailability.sshUnavailable;

  List<Widget> _form(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return [
      Text(
        l10n.remoteAppIntro,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: 16),
      TextField(
        controller: _command,
        focusNode: _commandFocus,
        autofocus: true,
        autocorrect: false,
        enableSuggestions: false,
        textInputAction: TextInputAction.go,
        style: const TextStyle(
          fontFamily: AppTheme.monoFontFamily,
          fontFamilyFallback: AppTheme.monoFontFamilyFallback,
        ),
        decoration: InputDecoration(
          labelText: l10n.remoteAppCommandLabel,
          hintText: l10n.remoteAppCommandHint,
          border: const OutlineInputBorder(),
        ),
        onSubmitted: (_) => _run(),
      ),
      const SizedBox(height: 12),
      // A Wrap: with a long translation the two buttons do not fit side by
      // side on a small phone, and the second goes on a line of its own.
      Wrap(
        alignment: widget.listInstalledApps == null
            ? WrapAlignment.end
            : WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        runSpacing: 8,
        children: [
          if (widget.listInstalledApps != null)
            OutlinedButton.icon(
              icon: const Icon(Icons.apps),
              label: Text(l10n.remoteAppInstalledApps),
              onPressed: _pickInstalled,
            ),
          FilledButton.icon(
            style: _rowButton,
            icon: _launching
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.play_arrow),
            label: Text(l10n.remoteAppRun),
            onPressed:
                _command.text.trim().isEmpty || _launching ? null : _run,
          ),
        ],
      ),
      if (_recent.isNotEmpty) ...[
        const SizedBox(height: 16),
        Text(l10n.remoteAppRecent, style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final command in _recent)
              InputChip(
                label: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 260),
                  child: Text(
                    command,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: AppTheme.monoFontFamily,
                      fontFamilyFallback: AppTheme.monoFontFamilyFallback,
                    ),
                  ),
                ),
                tooltip: command,
                deleteButtonTooltipMessage: l10n.remoteAppForgetRecent,
                onPressed: () {
                  _command.value = TextEditingValue(
                    text: command,
                    selection: TextSelection.collapsed(offset: command.length),
                  );
                  _commandFocus.requestFocus();
                },
                onDeleted: () => _forget(command),
              ),
          ],
        ),
      ],
    ];
  }
}

/// What X11 forwarding lets the server's program do on this display, in the
/// same terms as the host form's switch: limited access where the display can
/// give it, everything on Windows, and everything wherever it could not be
/// limited — which is said in the warning colour, since it is the case worth
/// stopping for.
class _SecurityNote extends StatelessWidget {
  const _SecurityNote({required this.runner});

  final RemoteAppRunner runner;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final fullAccess = runner.isWindows || runner.trusted == true;
    final text = runner.isWindows
        ? l10n.remoteAppSecurityWindows
        : runner.trusted == true
            ? '${l10n.remoteAppFullAccessWarning} ${l10n.remoteAppSecurityTrustedServers}'
            : l10n.remoteAppSecurityDesktop;
    final color =
        fullAccess ? theme.colorScheme.error : theme.colorScheme.onSurfaceVariant;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          fullAccess ? Icons.warning_amber_rounded : Icons.shield_outlined,
          size: 18,
          color: color,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(color: color, height: 1.35),
          ),
        ),
      ],
    );
  }
}

/// Why no window can be opened, and what can be done about it.
class _UnavailablePanel extends StatelessWidget {
  const _UnavailablePanel({
    required this.availability,
    required this.runner,
    required this.checking,
    required this.onCheckAgain,
    required this.fixing,
    required this.onFixServer,
    required this.onOfferVirtualDesktop,
  });

  final RemoteAppAvailability availability;
  final RemoteAppRunner runner;
  final bool checking;
  final VoidCallback onCheckAgain;
  final bool fixing;
  final VoidCallback? onFixServer;
  final VoidCallback? onOfferVirtualDesktop;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final explanation = switch (availability) {
      RemoteAppAvailability.available => '',
      RemoteAppAvailability.unsupportedDevice =>
        l10n.remoteAppUnavailableUnsupported,
      RemoteAppAvailability.noLocalDisplay => runner.isWindows
          ? l10n.remoteAppUnavailableNoDisplayWindows
          : l10n.remoteAppUnavailableNoDisplay,
      RemoteAppAvailability.sshUnavailable => l10n.remoteAppUnavailableSsh,
      RemoteAppAvailability.serverRefused => runner.certificateBlocksX11
          ? l10n.remoteAppUnavailableRefusedCertificate
          : l10n.remoteAppUnavailableRefused,
    };
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline, color: theme.colorScheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  l10n.remoteAppUnavailableTitle,
                  style: theme.textTheme.titleSmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(explanation, style: const TextStyle(height: 1.4)),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (availability == RemoteAppAvailability.serverRefused &&
                  !runner.certificateBlocksX11 &&
                  onFixServer != null)
                FilledButton(
                  style: _rowButton,
                  onPressed: fixing ? null : onFixServer,
                  child: Text(l10n.remoteAppFixServer),
                ),
              if (availability == RemoteAppAvailability.noLocalDisplay)
                OutlinedButton(
                  onPressed: checking ? null : onCheckAgain,
                  child: Text(l10n.remoteAppCheckAgain),
                ),
              if (onOfferVirtualDesktop != null)
                FilledButton.tonal(
                  style: _rowButton,
                  onPressed: onOfferVirtualDesktop,
                  child: Text(l10n.remoteAppVirtualDesktop),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One program started from here: what it is, how it is doing, what it said on
/// stderr, and Stop (or, once it has ended, a way to clear it away).
class _AppTile extends StatelessWidget {
  const _AppTile({required this.app, required this.runner});

  final RemoteApp app;
  final RemoteAppRunner runner;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final state = app.state;
    final failed = state is RemoteAppFailed ||
        (state is RemoteAppExited &&
            !state.stopped &&
            (state.code ?? 0) != 0);
    final time = MaterialLocalizations.of(context)
        .formatTimeOfDay(TimeOfDay.fromDateTime(app.startedAt));
    final stateColor = failed
        ? theme.colorScheme.error
        : app.isActive
            ? theme.colorScheme.primary
            : theme.colorScheme.onSurfaceVariant;
    final stderr = app.stderrTail;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        app.command,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: AppTheme.monoFontFamily,
                          fontFamilyFallback: AppTheme.monoFontFamilyFallback,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text.rich(
                        TextSpan(children: [
                          TextSpan(
                            text: _stateText(l10n, app),
                            style: TextStyle(
                              color: stateColor,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          TextSpan(text: '  ·  ${l10n.remoteAppStartedAt(time)}'),
                        ]),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (app.isActive)
                  FilledButton.tonal(
                    style: _rowButton,
                    onPressed:
                        app.isStopping ? null : () => runner.stop(app),
                    child: Text(l10n.remoteAppStop),
                  )
                else
                  IconButton(
                    tooltip: l10n.remoteAppRemove,
                    icon: const Icon(Icons.close),
                    onPressed: () => runner.remove(app),
                  ),
              ],
            ),
            if (app.isActive && app.trusted == true && !runner.isWindows) ...[
              const SizedBox(height: 6),
              Text(
                l10n.remoteAppFullAccessWarning,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            for (final problem in app.problems) ...[
              const SizedBox(height: 6),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    size: 16,
                    color: theme.colorScheme.error,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(problem, style: theme.textTheme.bodySmall),
                  ),
                ],
              ),
            ],
            if (stderr.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                l10n.remoteAppErrorOutput,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 4),
              Container(
                constraints: const BoxConstraints(maxHeight: 112),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  borderRadius: BorderRadius.circular(6),
                ),
                // Reversed, so the newest lines — the ones that say why — are
                // the ones in view.
                child: SingleChildScrollView(
                  reverse: true,
                  child: SelectableText(
                    '${app.stderrTruncated ? '…\n' : ''}${stderr.trimRight()}',
                    style: const TextStyle(
                      fontFamily: AppTheme.monoFontFamily,
                      fontFamilyFallback: AppTheme.monoFontFamilyFallback,
                      fontSize: 12,
                      height: 1.3,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _stateText(AppLocalizations l10n, RemoteApp app) {
    return switch (app.state) {
      RemoteAppStarting() => l10n.remoteAppStateStarting,
      RemoteAppRunning() =>
        app.isStopping ? l10n.remoteAppStateStopping : l10n.remoteAppStateRunning,
      RemoteAppExited(:final stopped, :final code, :final signal) => stopped
          ? l10n.remoteAppStateStopped
          : code != null
              ? l10n.remoteAppStateExited(code)
              : signal != null
                  ? l10n.remoteAppStateSignal(signal)
                  : l10n.remoteAppStateEnded,
      RemoteAppFailed(:final failure, :final detail) => switch (failure) {
          RemoteAppFailure.serverRefused => l10n.remoteAppStateRefused,
          RemoteAppFailure.connectionLost => l10n.remoteAppStateLost,
          RemoteAppFailure.couldNotStart =>
            l10n.remoteAppStateFailed(detail?.trim() ?? '').trim(),
        },
    };
  }
}

/// The server's list of installed applications, searchable. Pops the one
/// chosen; the caller puts its command in the field and leaves running it to
/// the person.
class _InstalledAppsDialog extends StatefulWidget {
  const _InstalledAppsDialog({required this.load});

  final Future<List<InstalledRemoteApp>> Function() load;

  @override
  State<_InstalledAppsDialog> createState() => _InstalledAppsDialogState();
}

class _InstalledAppsDialogState extends State<_InstalledAppsDialog> {
  List<InstalledRemoteApp>? _apps;
  Object? _error;
  var _query = '';

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final apps = await widget.load();
      if (mounted) setState(() => _apps = apps);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final apps = _apps;
    final needle = _query.trim().toLowerCase();
    final shown = apps == null
        ? const <InstalledRemoteApp>[]
        : [
            for (final app in apps)
              if (needle.isEmpty ||
                  app.name.toLowerCase().contains(needle) ||
                  app.command.toLowerCase().contains(needle))
                app,
          ];
    return AlertDialog(
      title: Text(l10n.remoteAppInstalledTitle),
      content: SizedBox(
        width: 480,
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              autofocus: true,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: l10n.remoteAppInstalledSearch,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (value) => setState(() => _query = value),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _error != null
                  ? Text(l10n.remoteAppInstalledFailed('$_error'))
                  : apps == null
                      ? const Center(child: CircularProgressIndicator())
                      : apps.isEmpty
                          ? Text(l10n.remoteAppInstalledEmpty)
                          : ListView.builder(
                              itemCount: shown.length,
                              itemBuilder: (context, index) {
                                final app = shown[index];
                                return ListTile(
                                  dense: true,
                                  title: Text(app.name),
                                  subtitle: Text(
                                    app.command,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontFamily: AppTheme.monoFontFamily,
                                      fontFamilyFallback:
                                          AppTheme.monoFontFamilyFallback,
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                  onTap: () => Navigator.of(context).pop(app),
                                );
                              },
                            ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
      ],
    );
  }
}
