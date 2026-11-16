import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../models/host.dart';
import '../models/host_ai_edit.dart';
import '../services/allowed_command_check.dart';
import '../services/visible_text.dart';
import '../theme.dart';

/// The AI Bridge controls of one host: share it, let the assistant request
/// changes, the commands that run without asking, and the full control
/// terminal. Shared by the host edit screen and the per-host sheet in the
/// shared-hosts checklist.
///
/// It edits a [HostAiEdit] in place and tells the parent through [onChanged];
/// the parent writes with [HostAiEdit.applyTo] against the host as the store
/// holds it at that moment, so only what the user touched here is written.
///
/// Switching on "request changes" or the terminal asks first, in words that
/// say what comes into force (the stored allowed commands are listed).
class HostAiControls extends StatefulWidget {
  const HostAiControls({
    super.key,
    required this.edit,
    required this.onChanged,
    this.showShare = true,
    this.loadStored,
  });

  final HostAiEdit edit;
  final VoidCallback onChanged;

  /// Whether the "Share with AI assistants" switch is part of this view (the
  /// checklist has its own tick, and the sheet leaves it out).
  final bool showShare;

  /// The host as the store holds it now, for listing the commands that would
  /// come into force. Null for a host not saved yet.
  final Future<Host?> Function()? loadStored;

  @override
  State<HostAiControls> createState() => _HostAiControlsState();
}

class _HostAiControlsState extends State<HostAiControls> {
  final TextEditingController _field = TextEditingController();
  AllowedCommandProblem? _problem;

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  HostAiEdit get _edit => widget.edit;

  void _changed() {
    setState(() {});
    widget.onChanged();
  }

  Future<bool> _confirm({
    required String title,
    required List<Widget> body,
    required String confirm,
    bool destructive = true,
  }) async {
    final theme = Theme.of(context);
    final cancel = MaterialLocalizations.of(context).cancelButtonLabel;
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        // The title scrolls with the text, so on a small screen with large
        // text the buttons keep their room and the whole list is reachable.
        scrollable: true,
        title: Text(title),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: body,
        ),
        actions: [
          // Cancel holds the focus: Enter leaves it off.
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(cancel),
          ),
          FilledButton(
            style: destructive
                ? FilledButton.styleFrom(
                    backgroundColor: theme.colorScheme.error,
                  )
                : null,
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(confirm),
          ),
        ],
      ),
    );
    return result == true;
  }

  Future<void> _setChanges(bool on) async {
    if (!on) {
      _edit.setChanges(false);
      _changed();
      return;
    }
    final l10n = context.l10n;
    // The list that would come into force: the stored one, unless this form
    // already edited it.
    var commands = _edit.commands;
    // Likewise the terminal switch: stored on but inert while the host was
    // read-only, it comes into force with this switch, so it is confirmed
    // again with its own warning.
    var terminal = _edit.terminal;
    if (widget.loadStored != null &&
        (!_edit.commandsChosen || !_edit.terminalChosen)) {
      try {
        final stored = await widget.loadStored!();
        if (stored != null) {
          if (!_edit.commandsChosen) commands = stored.aiAllowedCommands;
          if (!_edit.terminalChosen) terminal = stored.aiTerminal;
        }
      } catch (_) {}
    }
    if (!mounted) return;
    final ok = await _confirm(
      title: l10n.hostAiChangesConfirmTitle,
      body: [
        Text(l10n.hostAiChangesConfirmBody),
        if (commands.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            l10n.hostAiChangesConfirmList,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          for (final command in commands)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                '• ${visibleLine(command)}',
                key: const ValueKey('ai-confirm-command'),
                style: _mono(13),
              ),
            ),
        ],
      ],
      confirm: l10n.hostAiChangesConfirmYes,
    );
    if (!ok || !mounted) return;
    if (!_edit.commandsChosen) _edit.commands = List<String>.of(commands);
    if (!_edit.terminalChosen) _edit.terminal = terminal;
    _edit.setChanges(true);
    _changed();
    if (terminal) {
      // Cancel here leaves requests on and the terminal off.
      final keep = await _confirmTerminal();
      if (!mounted) return;
      _edit.setTerminal(keep);
      _changed();
    }
  }

  Future<bool> _confirmTerminal() {
    final l10n = context.l10n;
    return _confirm(
      title: l10n.hostAiTerminalConfirmTitle,
      body: [
        Text(l10n.hostAiTerminalConfirmBody1),
        const SizedBox(height: 8),
        Text(l10n.hostAiTerminalConfirmBody2),
      ],
      confirm: l10n.hostAiTerminalConfirmYes,
    );
  }

  Future<void> _setTerminal(bool on) async {
    if (!on) {
      _edit.setTerminal(false);
      _changed();
      return;
    }
    final ok = await _confirmTerminal();
    if (!ok || !mounted) return;
    _edit.setTerminal(true);
    _changed();
  }

  void _add() {
    final text = _field.text;
    final problem = allowedCommandProblem(text, _edit.commands);
    if (problem != null) {
      setState(() => _problem = problem);
      return;
    }
    _edit.setCommands([..._edit.commands, text.trim()]);
    _field.clear();
    _problem = null;
    _changed();
  }

  void _remove(String command) {
    _edit.setCommands([
      for (final c in _edit.commands)
        if (c != command) c,
    ]);
    _changed();
  }

  TextStyle _mono(double size) => TextStyle(
    fontFamily: AppTheme.monoFontFamily,
    fontFamilyFallback: AppTheme.monoFontFamilyFallback,
    fontSize: size,
  );

  String _problemText(AllowedCommandProblem problem) {
    final l10n = context.l10n;
    return switch (problem) {
      AllowedCommandProblem.empty => l10n.hostAiCommandEmpty,
      AllowedCommandProblem.lineBreak => l10n.hostAiCommandLineBreak,
      AllowedCommandProblem.hiddenCharacter => l10n.hostAiCommandHidden,
      AllowedCommandProblem.tooLong => l10n.hostAiCommandTooLong(
        Host.maxAiAllowedCommandLength,
      ),
      AllowedCommandProblem.duplicate => l10n.hostAiCommandDuplicate,
      AllowedCommandProblem.listFull => l10n.hostAiCommandListFull(
        Host.maxAiAllowedCommands,
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final shared = _edit.shared;
    final changes = shared && _edit.changes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.showShare)
          SwitchListTile(
            key: const ValueKey('ai-share'),
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.hub_outlined),
            title: Text(l10n.hostAiShare),
            subtitle: Text(l10n.hostAiShareHelp),
            value: shared,
            onChanged: (on) {
              _edit.setShared(on);
              _changed();
            },
          ),
        if (shared)
          SwitchListTile(
            key: const ValueKey('ai-changes'),
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.edit_note_outlined),
            title: Text(l10n.hostAiChanges),
            subtitle: Text(l10n.hostAiChangesHelp),
            value: changes,
            onChanged: (on) => unawaited(_setChanges(on)),
          ),
        if (changes) ...[
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 4),
            child: Text(l10n.hostAiCommands, style: theme.textTheme.titleSmall),
          ),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: scheme.errorContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  size: 20,
                  color: scheme.onErrorContainer,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.hostAiCommandsWarning,
                    key: const ValueKey('ai-commands-warning'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onErrorContainer,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (_edit.commands.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                l10n.hostAiCommandsNone,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            )
          else
            for (final command in _edit.commands)
              ListTile(
                key: ValueKey('ai-command-$command'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                // In full, never cut: each of these runs without asking, so
                // the user must be able to read every character of it.
                title: Text(visibleLine(command), style: _mono(13)),
                trailing: IconButton(
                  tooltip: l10n.hostAiCommandRemove,
                  icon: const Icon(Icons.close),
                  onPressed: () => _remove(command),
                ),
              ),
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('ai-command-field'),
            controller: _field,
            keyboardType: TextInputType.multiline,
            minLines: 1,
            maxLines: 3,
            autocorrect: false,
            enableSuggestions: false,
            style: _mono(13),
            decoration: InputDecoration(
              labelText: l10n.hostAiCommandField,
              errorText: _problem == null ? null : _problemText(_problem!),
              errorMaxLines: 4,
              suffixIcon: IconButton(
                key: const ValueKey('ai-command-add'),
                tooltip: l10n.hostAiCommandAdd,
                icon: const Icon(Icons.add),
                onPressed: _add,
              ),
            ),
            onChanged: (_) {
              if (_problem != null) setState(() => _problem = null);
            },
          ),
          SwitchListTile(
            key: const ValueKey('ai-terminal'),
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.terminal),
            title: Text(l10n.hostAiTerminal),
            subtitle: Text(l10n.hostAiTerminalHelp),
            value: _edit.terminal,
            onChanged: (on) => unawaited(_setTerminal(on)),
          ),
        ],
      ],
    );
  }
}
