import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../models/host.dart';
import '../models/host_ai_access.dart';
import '../models/host_ai_edit.dart';
import '../services/allowed_command_check.dart';
import '../services/visible_text.dart';
import '../theme.dart';

/// The one choice of what AI assistants may do on a host: Off, Read only,
/// Ask before each change, Full control. Each has a line saying what it
/// allows, and below the choice a plain summary of what the current pick means.
///
/// Under "Ask before each change" it also shows the ticks for a terminal and
/// the desktop, and an "Advanced" fold with the allowed commands. Under "Full
/// control" it shows a standing warning.
///
/// It edits a [HostAiEdit] in place (through [HostAiEdit.setLevel] and the
/// flag setters) and tells the parent through [onChanged]; the parent writes
/// with [HostAiEdit.applyTo] against the host as the store holds it at that
/// moment, so only what the user touched here is written. Nothing is saved by
/// the picker itself.
///
/// Raising asks first, in words that say what comes into force: to "Ask
/// before each change" (the stored allowed commands are listed, and a stored
/// terminal or desktop tick is confirmed again), to a terminal or the
/// desktop, and to "Full control". Lowering never asks.
class HostAiLevelPicker extends StatefulWidget {
  const HostAiLevelPicker({
    super.key,
    required this.edit,
    required this.onChanged,
    this.loadStored,
  });

  final HostAiEdit edit;
  final VoidCallback onChanged;

  /// The host as the store holds it now, for listing the commands that would
  /// come into force. Null for a host not saved yet.
  final Future<Host?> Function()? loadStored;

  /// What [level] means in plain words, for the line under the picker.
  static String summary(
    AppLocalizations l10n,
    HostAiAccess level, {
    required bool terminal,
    required bool desktop,
    required int commands,
  }) {
    switch (level) {
      case HostAiAccess.off:
        return l10n.hostAiSummaryOff;
      case HostAiAccess.readOnly:
        return l10n.hostAiSummaryRead;
      case HostAiAccess.fullControl:
        return l10n.hostAiSummaryFull;
      case HostAiAccess.askToChange:
        final flags = terminal && desktop
            ? l10n.hostAiSummaryTermDesk
            : terminal
            ? l10n.hostAiSummaryTerm
            : desktop
            ? l10n.hostAiSummaryDesk
            : l10n.hostAiSummaryNeither;
        return [
          l10n.hostAiSummaryAsk,
          flags,
          if (commands > 0) l10n.hostAiSummaryCommands(commands),
        ].join(' ');
    }
  }

  @override
  State<HostAiLevelPicker> createState() => _HostAiLevelPickerState();
}

class _HostAiLevelPickerState extends State<HostAiLevelPicker> {
  final TextEditingController _field = TextEditingController();
  AllowedCommandProblem? _problem;

  /// True while a pick is being confirmed: a second tap meanwhile is ignored,
  /// so two dialogs never stack.
  bool _picking = false;

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
            style: FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.error,
              foregroundColor: theme.colorScheme.onError,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(confirm),
          ),
        ],
      ),
    );
    return result == true;
  }

  static int _rank(HostAiAccess level) => level.index;

  Future<void> _pick(HostAiAccess level) async {
    if (_picking || level == _edit.level) return;
    _picking = true;
    try {
      // The form may have opened at a higher level than the store holds
      // now (lowered elsewhere while it was open). A pick below the form's
      // level but above the stored one still raises what is in force, and
      // saving it would bring the stored ticks and commands back unasked,
      // so it is judged against both.
      Host? stored;
      var storedRead = false;
      final loadStored = widget.loadStored;
      if (loadStored != null && level != HostAiAccess.off) {
        try {
          stored = await loadStored();
        } catch (_) {}
        storedRead = true;
        if (!mounted) return;
      }
      final aboveStored =
          stored != null && _rank(level) > _rank(stored.aiAccess);
      if (_rank(level) < _rank(_edit.level) && !aboveStored) {
        _edit.setLevel(level);
        _changed();
        return;
      }
      switch (level) {
        case HostAiAccess.off:
        case HostAiAccess.readOnly:
          _edit.setLevel(level);
          _changed();
        case HostAiAccess.askToChange:
          await _raiseToAsk(stored: stored, storedRead: storedRead);
        case HostAiAccess.fullControl:
          await _raiseToFull();
      }
    } finally {
      _picking = false;
    }
  }

  Future<void> _raiseToFull() async {
    final l10n = context.l10n;
    final ok = await _confirm(
      title: l10n.hostAiFullConfirmTitle,
      body: [
        Text(l10n.hostAiFullConfirmBody1),
        const SizedBox(height: 8),
        Text(l10n.hostAiFullConfirmBody2),
        const SizedBox(height: 8),
        Text(l10n.hostAiFullConfirmBody3),
      ],
      confirm: l10n.hostAiFullConfirmYes,
    );
    if (!ok || !mounted) return;
    _edit.setLevel(HostAiAccess.fullControl);
    _changed();
  }

  /// [storedRead] says [_pick] already asked [HostAiLevelPicker.loadStored]
  /// (its answer, possibly null, is [stored]), so it is not asked twice.
  Future<void> _raiseToAsk({Host? stored, bool storedRead = false}) async {
    final l10n = context.l10n;
    // The list that would come into force: the stored one, unless this form
    // already edited it.
    var commands = _edit.commands;
    // Likewise the terminal and desktop ticks: stored on but inert while the
    // host was read-only, they come into force with this level, so each is
    // confirmed again with its own warning.
    var terminal = _edit.terminal;
    var desktop = _edit.desktop;
    if (widget.loadStored != null &&
        (!_edit.commandsChosen ||
            !_edit.terminalChosen ||
            !_edit.desktopChosen)) {
      try {
        if (!storedRead) stored = await widget.loadStored!();
        if (stored != null) {
          if (!_edit.commandsChosen) commands = stored.aiAllowedCommands;
          if (!_edit.terminalChosen) terminal = stored.aiTerminal;
          if (!_edit.desktopChosen) desktop = stored.aiDesktop;
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
    if (!_edit.desktopChosen) _edit.desktop = desktop;
    _edit.setLevel(HostAiAccess.askToChange);
    _changed();
    if (terminal) {
      // Cancel here leaves requests on and the terminal off.
      final keep = await _confirmTerminal();
      if (!mounted) return;
      _edit.setTerminal(keep);
      _changed();
    }
    if (desktop) {
      final keep = await _confirmDesktop();
      if (!mounted) return;
      _edit.setDesktop(keep);
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

  Future<bool> _confirmDesktop() {
    final l10n = context.l10n;
    return _confirm(
      title: l10n.hostAiDesktopConfirmTitle,
      body: [
        Text(l10n.hostAiDesktopConfirmBody1),
        const SizedBox(height: 8),
        Text(l10n.hostAiDesktopConfirmBody2),
      ],
      confirm: l10n.hostAiDesktopConfirmYes,
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

  Future<void> _setDesktop(bool on) async {
    if (!on) {
      _edit.setDesktop(false);
      _changed();
      return;
    }
    final ok = await _confirmDesktop();
    if (!ok || !mounted) return;
    _edit.setDesktop(true);
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

  Widget _radio(HostAiAccess level, String title, String help, IconData icon) {
    final scheme = Theme.of(context).colorScheme;
    final selected = _edit.level == level;
    final full = level == HostAiAccess.fullControl;
    return RadioListTile<HostAiAccess>(
      key: ValueKey('ai-level-${level.name}'),
      value: level,
      contentPadding: EdgeInsets.zero,
      secondary: Icon(icon, color: full ? scheme.error : null),
      title: Text(
        title,
        style: full && selected ? TextStyle(color: scheme.error) : null,
      ),
      subtitle: Text(help),
    );
  }

  Widget _warningBox(Key key, String text) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
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
              text,
              key: key,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onErrorContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _commandsEditor() {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(l10n.hostAiCommands, style: theme.textTheme.titleSmall),
        ),
        _warningBox(
          const ValueKey('ai-commands-warning'),
          l10n.hostAiCommandsWarning,
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
        const SizedBox(height: 8),
      ],
    );
  }

  /// The part that only exists under "Ask before each change".
  Widget _askOptions() {
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CheckboxListTile(
            key: const ValueKey('ai-terminal'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: Text(l10n.hostAiMayTerminal),
            subtitle: Text(l10n.hostAiMayTerminalHelp),
            value: _edit.terminal,
            onChanged: (on) => unawaited(_setTerminal(on == true)),
          ),
          CheckboxListTile(
            key: const ValueKey('ai-desktop'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: Text(l10n.hostAiMayDesktop),
            subtitle: Text(l10n.hostAiMayDesktopHelp),
            value: _edit.desktop,
            onChanged: (on) => unawaited(_setDesktop(on == true)),
          ),
          Theme(
            // The fold draws its own rules; the card around it does enough.
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              key: const ValueKey('ai-advanced'),
              tilePadding: EdgeInsets.zero,
              childrenPadding: EdgeInsets.zero,
              expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
              title: Text(l10n.hostAiAdvanced),
              subtitle: Text(l10n.hostAiAdvancedCount(_edit.commands.length)),
              children: [_commandsEditor()],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final level = _edit.level;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        RadioGroup<HostAiAccess>(
          groupValue: level,
          onChanged: (value) {
            if (value != null) unawaited(_pick(value));
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _radio(
                HostAiAccess.off,
                l10n.hostAiLevelOff,
                l10n.hostAiLevelOffHelp,
                Icons.visibility_off_outlined,
              ),
              _radio(
                HostAiAccess.readOnly,
                l10n.hostAiLevelRead,
                l10n.hostAiLevelReadHelp,
                Icons.visibility_outlined,
              ),
              _radio(
                HostAiAccess.askToChange,
                l10n.hostAiLevelAsk,
                l10n.hostAiLevelAskHelp,
                Icons.edit_note_outlined,
              ),
              _radio(
                HostAiAccess.fullControl,
                l10n.hostAiLevelFull,
                l10n.hostAiLevelFullHelp,
                Icons.lock_open_outlined,
              ),
            ],
          ),
        ),
        if (level == HostAiAccess.askToChange) _askOptions(),
        if (level == HostAiAccess.fullControl)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: _warningBox(
              const ValueKey('ai-full-warning'),
              l10n.hostAiFullWarning,
            ),
          ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.info_outline,
                size: 20,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  HostAiLevelPicker.summary(
                    l10n,
                    level,
                    terminal: _edit.terminal,
                    desktop: _edit.desktop,
                    commands: _edit.commands.length,
                  ),
                  key: const ValueKey('ai-summary'),
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
