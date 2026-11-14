import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/l10n.dart';
import '../services/bridge/bridge_client_store.dart';
import '../services/bridge/bridge_launcher_locator.dart';
import '../services/bridge/bridge_plugin_command.dart';
import '../theme.dart';

/// Which instructions to show once the assistant is paired. The names are
/// only labels for which snippet follows; they are not translated, and
/// naming one is not an endorsement of it.
enum _ClientKind { plugin, config, vscode, other }

/// The environment variable the launcher reads the pairing token from.
const String _tokenVariable = 'SSG_BRIDGE_TOKEN';

/// Pairing a new assistant: its name, how it connects, then the token —
/// shown once, with the instructions for that way of connecting.
class BridgeConnectScreen extends StatefulWidget {
  const BridgeConnectScreen({super.key, required this.clients, this.launcher});

  final BridgeClientStore clients;

  /// The launcher command to show. Found from how this copy of the app is
  /// installed unless a test hands one in.
  final BridgeLauncherCommand? launcher;

  @override
  State<BridgeConnectScreen> createState() => _BridgeConnectScreenState();
}

class _BridgeConnectScreenState extends State<BridgeConnectScreen> {
  final _name = TextEditingController();
  late final BridgeLauncherCommand _launcher =
      widget.launcher ?? locateBridgeLauncher();
  _ClientKind _kind = _ClientKind.plugin;
  bool _busy = false;
  String? _error;

  /// Held only here, only in memory, and gone with this screen: the store
  /// keeps its hash and nothing else.
  String? _token;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  /// Asked when leaving with the token on screen: it is shown once, and
  /// nothing can bring it back.
  Future<void> _confirmLeave() async {
    final l10n = context.l10n;
    final leave = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.bridgeConnectLeaveTitle),
        content: Text(l10n.bridgeConnectLeaveBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.bridgeConnectLeaveStay),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.bridgeConnectLeaveConfirm),
          ),
        ],
      ),
    );
    if (leave == true && mounted) Navigator.of(context).pop();
  }

  Future<void> _create() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final name = _name.text.trim().isEmpty
        ? context.l10n.bridgeConnectDefaultName
        : _name.text;
    try {
      final created = await widget.clients.create(name);
      if (!mounted) return;
      setState(() {
        _token = created.token;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = context.l10n.bridgeConnectFailed('$e');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final token = _token;
    return PopScope(
      // Free to leave until there is a token to lose; after that, asked.
      canPop: token == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_confirmLeave());
      },
      child: Scaffold(
        appBar: AppBar(title: Text(l10n.settingsBridgeConnect)),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: token == null
                    ? _form(context)
                    : _result(context, token),
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _form(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    String label(_ClientKind k) => switch (k) {
      _ClientKind.plugin => 'Claude Code plugin',
      _ClientKind.config => l10n.bridgeConnectKindConfig,
      _ClientKind.vscode => 'VS Code',
      _ClientKind.other => l10n.bridgeConnectKindOther,
    };
    String help(_ClientKind k) => switch (k) {
      _ClientKind.plugin => l10n.bridgeConnectKindPluginHelp,
      _ClientKind.config => l10n.bridgeConnectKindConfigHelp,
      _ClientKind.vscode => l10n.bridgeConnectKindVscodeHelp,
      _ClientKind.other => l10n.bridgeConnectKindOtherHelp,
    };
    return [
      Text(l10n.bridgeConnectNameIntro),
      const SizedBox(height: 12),
      TextField(
        controller: _name,
        enabled: !_busy,
        textInputAction: TextInputAction.done,
        decoration: InputDecoration(
          labelText: l10n.bridgeConnectNameLabel,
          hintText: l10n.bridgeConnectNameHint,
          prefixIcon: const Icon(Icons.smart_toy_outlined),
        ),
        onSubmitted: (_) {
          if (!_busy) unawaited(_create());
        },
      ),
      const SizedBox(height: 20),
      Text(l10n.bridgeConnectKindTitle, style: theme.textTheme.labelLarge),
      const SizedBox(height: 4),
      RadioGroup<_ClientKind>(
        groupValue: _kind,
        onChanged: (value) {
          if (value != null && !_busy) setState(() => _kind = value);
        },
        child: Column(
          children: [
            for (final k in _ClientKind.values)
              RadioListTile<_ClientKind>(
                value: k,
                contentPadding: EdgeInsets.zero,
                title: Text(label(k)),
                subtitle: Text(help(k)),
              ),
          ],
        ),
      ),
      if (_error != null) ...[
        const SizedBox(height: 12),
        Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
      ],
      const SizedBox(height: 20),
      FilledButton(
        onPressed: _busy ? null : () => unawaited(_create()),
        child: _busy
            ? const SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Text(l10n.bridgeConnectCreate),
      ),
    ];
  }

  List<Widget> _result(BuildContext context, String token) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final launcher = _launcher.command;
    String json(Map<String, Object?> m) => jsonEncode(m);
    final env = {_tokenVariable: token};

    final steps = <Widget>[
      switch (_kind) {
        _ClientKind.plugin => _Block(
          children: [
            Text(l10n.bridgeConnectPluginCommands),
            _Code(
              bridgePluginCommands(
                token: token,
                launcher: launcher,
                isWindows: Platform.isWindows,
              ),
            ),
            Text(l10n.bridgeConnectPluginHelp),
            Text(
              l10n.bridgeConnectPluginInSession(bridgePluginSessionCommand),
            ),
            Text(
              l10n.bridgeConnectPluginHistoryNote(l10n.bridgeOneClickButton),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        _ClientKind.config => _Block(
          children: [
            Text(l10n.bridgeConnectConfigIntro),
            _Code(
              json({
                'mcpServers': {
                  'secureshellgo': {'command': launcher, 'env': env},
                },
              }),
            ),
          ],
        ),
        _ClientKind.vscode => _Block(
          children: [
            Text(l10n.bridgeConnectVscodeIntro),
            _Code(
              json({
                'servers': {
                  'secureshellgo': {
                    'type': 'stdio',
                    'command': launcher,
                    'env': env,
                  },
                },
              }),
            ),
          ],
        ),
        _ClientKind.other => _Block(
          children: [
            Text(l10n.bridgeConnectOtherIntro(_tokenVariable)),
            _Labelled(l10n.bridgeConnectLauncherLabel, _Code(launcher)),
            _Labelled(l10n.bridgeConnectEnvLabel, const _Code(_tokenVariable)),
          ],
        ),
      },
    ];

    return [
      Card(
        color: theme.colorScheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.warning_amber_outlined,
                color: theme.colorScheme.onErrorContainer,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.bridgeConnectTokenOnceTitle,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: theme.colorScheme.onErrorContainer,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      l10n.bridgeConnectTokenOnceBody,
                      style: TextStyle(
                        color: theme.colorScheme.onErrorContainer,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 16),
      _Labelled(l10n.bridgeConnectTokenLabel, _Code(token)),
      const SizedBox(height: 16),
      ...steps,
      if (!_launcher.exists) ...[
        const SizedBox(height: 16),
        Text(
          l10n.bridgeConnectLauncherMissing,
          style: TextStyle(color: theme.colorScheme.error),
        ),
      ],
      const SizedBox(height: 24),
      FilledButton(
        // The user's own "I have it": no second question.
        onPressed: () => Navigator.of(context).pop(),
        child: Text(l10n.bridgeConnectDone),
      ),
    ];
  }
}

class _Block extends StatelessWidget {
  const _Block({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          children[i],
        ],
      ],
    );
  }
}

class _Labelled extends StatelessWidget {
  const _Labelled(this.label, this.child);

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label, style: theme.textTheme.labelLarge),
        const SizedBox(height: 4),
        child,
      ],
    );
  }
}

/// A monospace snippet the user can select, with a Copy button.
class _Code extends StatelessWidget {
  const _Code(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 0, 10),
              child: SelectableText(
                text,
                style: TextStyle(
                  fontFamily: AppTheme.monoFontFamily,
                  fontFamilyFallback: AppTheme.monoFontFamilyFallback,
                  fontSize: 12.5,
                  height: 1.35,
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: MaterialLocalizations.of(context).copyButtonLabel,
            icon: const Icon(Icons.copy_all_outlined, size: 20),
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(context);
              final copied = l10n.bridgeConnectCopied;
              await Clipboard.setData(ClipboardData(text: text));
              messenger.showSnackBar(SnackBar(content: Text(copied)));
            },
          ),
        ],
      ),
    );
  }
}
