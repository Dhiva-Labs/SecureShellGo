import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/l10n.dart';
import '../services/remote_desktop/server_setup.dart';
import '../services/ssh_service.dart';
import '../widgets/terminal_fonts.dart';

/// One thing the server needs, as the person is shown it.
class SetupItem {
  const SetupItem({
    required this.title,
    required this.detail,
    required this.packages,
    this.required = true,
  });

  final String title;
  final String detail;
  final List<String> packages;

  /// False for something offered but not needed, which gets a checkbox.
  final bool required;
}

/// How the dialog reaches the server: the real install, or a test's fake.
class ServerSetupBackend {
  const ServerSetupBackend();

  Future<Privilege> privilege(SessionTransport transport) =>
      probePrivilege(transport);

  Future<SetupRun> install(
    SessionTransport transport, {
    required PackageManager pm,
    required List<String> packages,
    required Privilege privilege,
    String? password,
  }) =>
      runInstall(transport,
          pm: pm, packages: packages, privilege: privilege, password: password);
}

/// Asks to install [items] on the server and, on a click, installs them.
///
/// Returns true once they are installed, false when the person closed it
/// first. It finds out on its own whether this account is root, has sudo
/// without a password, or needs its password typed — and asks only in the
/// last case — or cannot install at all, when it shows the command for
/// someone who can.
Future<bool> showServerSetup(
  BuildContext context, {
  required SessionTransport transport,
  required String hostName,
  required PackageManager pm,
  required List<SetupItem> items,
  ServerSetupBackend backend = const ServerSetupBackend(),
}) async {
  final installed = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _ServerSetupDialog(
      transport: transport,
      hostName: hostName,
      pm: pm,
      items: items,
      backend: backend,
    ),
  );
  return installed ?? false;
}

enum _Stage { checking, ready, installing, done, failed }

class _ServerSetupDialog extends StatefulWidget {
  const _ServerSetupDialog({
    required this.transport,
    required this.hostName,
    required this.pm,
    required this.items,
    required this.backend,
  });

  final SessionTransport transport;
  final String hostName;
  final PackageManager pm;
  final List<SetupItem> items;
  final ServerSetupBackend backend;

  @override
  State<_ServerSetupDialog> createState() => _ServerSetupDialogState();
}

class _ServerSetupDialogState extends State<_ServerSetupDialog> {
  final _password = TextEditingController();
  late final Set<SetupItem> _chosen = {...widget.items};
  _Stage _stage = _Stage.checking;
  Privilege? _privilege;
  String? _error;
  String? _errorOutput;
  bool _passwordWrong = false;
  final List<String> _lines = [];
  SetupRun? _run;
  StreamSubscription<String>? _output;
  final _clock = Stopwatch();
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    unawaited(_check());
  }

  @override
  void dispose() {
    _tick?.cancel();
    unawaited(_output?.cancel());
    _password.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    try {
      final privilege = await widget.backend.privilege(widget.transport);
      if (!mounted) return;
      setState(() {
        _privilege = privilege;
        _stage = _Stage.ready;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        // Asking is cheap and harmless; the install itself will say if sudo
        // wants a password after all.
        _privilege = Privilege.sudoPassword;
        _stage = _Stage.ready;
      });
    }
  }

  List<String> get _packages => [
        for (final item in widget.items)
          if (_chosen.contains(item)) ...item.packages,
      ];

  bool get _needsPassword => _privilege == Privilege.sudoPassword;

  bool get _canInstall =>
      _privilege != Privilege.none &&
      _packages.isNotEmpty &&
      (!_needsPassword || _password.text.isNotEmpty);

  Future<void> _install() async {
    if (!_canInstall) return;
    setState(() {
      _stage = _Stage.installing;
      _error = null;
      _errorOutput = null;
      _passwordWrong = false;
      _lines.clear();
    });
    _clock
      ..reset()
      ..start();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    try {
      final run = await widget.backend.install(
        widget.transport,
        pm: widget.pm,
        packages: _packages,
        privilege: _privilege!,
        password: _needsPassword ? _password.text : null,
      );
      _run = run;
      _output = run.lines.listen((line) {
        if (!mounted) return;
        setState(() {
          _lines.add(line);
          if (_lines.length > 200) _lines.removeAt(0);
        });
      });
      await run.done;
      if (!mounted) return;
      setState(() => _stage = _Stage.done);
      // A moment to read "Installed", then on to what it was for.
      await Future<void>.delayed(const Duration(milliseconds: 900));
      if (mounted) Navigator.of(context).pop(true);
    } on SetupFailure catch (f) {
      if (!mounted) return;
      setState(() {
        _stage = f.kind == SetupFailureKind.wrongPassword
            ? _Stage.ready
            : _Stage.failed;
        _passwordWrong = f.kind == SetupFailureKind.wrongPassword;
        if (f.kind == SetupFailureKind.noSudo) _privilege = Privilege.none;
        _error = f.message;
        _errorOutput = f.output;
      });
      if (_passwordWrong) _password.clear();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.failed;
        _error = e.toString();
      });
    } finally {
      _tick?.cancel();
      _clock.stop();
    }
  }

  void _close() {
    // Closing mid-install only stops watching it; it finishes on its own.
    _run?.cancel();
    Navigator.of(context).pop(false);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final busy = _stage == _Stage.installing || _stage == _Stage.checking;

    final body = <Widget>[];
    switch (_stage) {
      case _Stage.checking:
        body.add(_Busy(text: l10n.remoteDesktopSetupChecking));
      case _Stage.ready || _Stage.failed:
        body.add(Text(l10n.remoteDesktopSetupIntro(widget.hostName)));
        body.add(const SizedBox(height: 8));
        for (final item in widget.items) {
          body.add(
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _chosen.contains(item),
              onChanged: item.required || _privilege == Privilege.none
                  ? null
                  : (on) => setState(() =>
                      on == true ? _chosen.add(item) : _chosen.remove(item)),
              title: Text(item.title),
              subtitle: Text(item.detail),
            ),
          );
        }
        if (_privilege == Privilege.none) {
          body
            ..add(const SizedBox(height: 8))
            ..add(Text(l10n.remoteDesktopSetupNoSudo))
            ..add(const SizedBox(height: 6))
            ..add(_Command(command: installCommandLine(widget.pm, _packages)));
        } else if (_needsPassword) {
          body
            ..add(const SizedBox(height: 8))
            ..add(
              TextField(
                controller: _password,
                obscureText: true,
                autofocus: true,
                enableSuggestions: false,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: l10n.remoteDesktopSetupPassword,
                  helperText: l10n.remoteDesktopSetupPasswordHint,
                  helperMaxLines: 3,
                  errorText: _passwordWrong ? _error : null,
                  errorMaxLines: 3,
                ),
                onChanged: (_) => setState(() => _passwordWrong = false),
                onSubmitted: (_) => unawaited(_install()),
              ),
            );
        }
        if (_stage == _Stage.failed && _error != null) {
          body
            ..add(const SizedBox(height: 12))
            ..add(Text(
              _error!,
              style: TextStyle(color: theme.colorScheme.error),
            ));
          if (_errorOutput case final out? when out.isNotEmpty) {
            body
              ..add(const SizedBox(height: 6))
              ..add(_Log(lines: out.split('\n')));
          }
        }
      case _Stage.installing:
        body
          ..add(_Busy(
            text: l10n.remoteDesktopSetupInstalling(
              _clock.elapsed.inSeconds ~/ 60,
              (_clock.elapsed.inSeconds % 60).toString().padLeft(2, '0'),
            ),
          ))
          ..add(const SizedBox(height: 12))
          ..add(_Log(lines: _lines));
      case _Stage.done:
        body.add(
          Row(
            children: [
              Icon(Icons.check_circle, color: theme.colorScheme.primary),
              const SizedBox(width: 12),
              Expanded(child: Text(l10n.remoteDesktopSetupDone)),
            ],
          ),
        );
    }

    final buttonStyle = FilledButton.styleFrom(minimumSize: const Size(0, 48));
    return AlertDialog(
      title: Text(l10n.remoteDesktopSetupTitle),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: body,
          ),
        ),
      ),
      actions: [
        if (_stage != _Stage.done)
          TextButton(
            onPressed: _close,
            child: Text(_stage == _Stage.installing
                ? l10n.remoteDesktopSetupHide
                : l10n.remoteDesktopCancel),
          ),
        if (_stage == _Stage.ready || _stage == _Stage.failed)
          if (_privilege != Privilege.none)
            FilledButton(
              style: buttonStyle,
              onPressed: busy || !_canInstall ? null : () => unawaited(_install()),
              child: Text(_stage == _Stage.failed
                  ? l10n.remoteDesktopRetry
                  : l10n.remoteDesktopSetupInstall),
            ),
      ],
    );
  }
}

class _Busy extends StatelessWidget {
  const _Busy({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          const SizedBox.square(
            dimension: 22,
            child: CircularProgressIndicator(strokeWidth: 3),
          ),
          const SizedBox(width: 16),
          Expanded(child: Text(text)),
        ],
      );
}

/// The install's own output, newest at the bottom, in the terminal's face.
class _Log extends StatelessWidget {
  const _Log({required this.lines});

  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shown = lines.length > 8 ? lines.sublist(lines.length - 8) : lines;
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 72),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        shown.join('\n'),
        maxLines: 8,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(fontFamily: TerminalFonts.jetBrainsMono),
      ),
    );
  }
}

class _Command extends StatelessWidget {
  const _Command({required this.command});

  final String command;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Container(
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
              style: theme.textTheme.bodyMedium?.copyWith(fontFamily: TerminalFonts.jetBrainsMono),
            ),
          ),
          IconButton(
            tooltip: l10n.remoteDesktopLaunchCopy,
            icon: const Icon(Icons.copy_outlined, size: 20),
            onPressed: () => Clipboard.setData(ClipboardData(text: command)),
          ),
        ],
      ),
    );
  }
}
