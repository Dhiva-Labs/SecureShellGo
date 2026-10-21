import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../models/app_settings.dart';
import '../models/remote_entry.dart';
import '../services/editor_document.dart';
import '../services/editor_indent.dart';
import '../services/editor_save.dart';
import '../services/editor_search.dart';
import '../services/input_profile.dart';
import '../services/layout_breakpoints.dart';
import '../services/remote_path.dart';
import '../services/settings_store.dart';
import '../services/sftp_service.dart';
import '../services/syntax_highlighter.dart';
import '../theme.dart';
import '../widgets/code_editor_field.dart';
import '../widgets/editor_key_bar.dart';

/// What the user chose at the "someone else changed this file" dialog.
enum _ConflictChoice { keepMine, reloadTheirs, saveAsCopy }

/// One file open in the editor.
///
/// Everything about a tab that is *not* the text lives here; the text itself
/// lives in the controller, which is the document model (see
/// [EditorHighlightController]). [savedText] is the only copy of what the
/// server has, and comparing it against the controller is what "dirty" means
/// — a flag set on every keystroke would stay set after an undo back to the
/// original, which is the state users report as "it says unsaved but I put it
/// back".
class _EditorTab {
  _EditorTab({
    required this.path,
    required this.controller,
    required this.savedText,
    required this.lineEndings,
    required this.hadInvalidUtf8,
    required this.fingerprint,
    required this.permissions,
    required this.mode,
  });

  String path;
  final EditorHighlightController controller;
  final FocusNode focusNode = FocusNode();

  /// This tab's own editor, kept alive while other tabs are in front — see
  /// [_RemoteEditorScreenState._body] — and reached through this key by the
  /// key bar.
  final GlobalKey<CodeEditorFieldState> fieldKey =
      GlobalKey<CodeEditorFieldState>();

  /// The field's own undo stack, held here so the Edit menu can undo and redo
  /// without a keyboard — and so each tab keeps its own history.
  final UndoHistoryController undo = UndoHistoryController();

  String savedText;
  LineEndingStyle lineEndings;
  bool hadInvalidUtf8;
  RemoteFingerprint fingerprint;
  int? permissions;

  SyntaxMode mode;

  /// Set once the user has been told the file was not valid UTF-8, so the
  /// warning interrupts the first save and not every one after it.
  bool lossyAcknowledged = false;

  /// Put back on save; see `DecodedText.hasBom`.
  bool hasBom = false;

  /// How this file indents and the language rules for Enter, Tab and
  /// comments — detected when the file is opened.
  EditorLanguage language = EditorLanguage.plain;
  IndentStyle indentStyle = const IndentStyle.spaces(4);

  String get name => RemotePath.basename(path);

  bool get isDirty => controller.text != savedText;

  void dispose() {
    controller.dispose();
    focusNode.dispose();
    undo.dispose();
  }
}

/// The built-in remote text editor.
///
/// Opens over the session's existing SFTP channel — the [RemoteFileSystem] it
/// is handed is the same one the file browser lists with, so opening a file
/// for editing costs no extra connection, no extra credential prompt, and
/// nothing the transfer queue has to know about.
class RemoteEditorScreen extends StatefulWidget {
  const RemoteEditorScreen({
    super.key,
    required this.filesystem,
    required this.settingsStore,
    required this.initialPaths,
    this.metadata,
    this.hostLabel,
  });

  final RemoteFileSystem filesystem;

  /// The stat/chmod half, when the filesystem provides one. Null degrades the
  /// conflict guard to size-only and turns off permission preservation; see
  /// [saveRemoteText].
  final RemoteFileMetadata? metadata;

  final SettingsStore settingsStore;
  final List<String> initialPaths;
  final String? hostLabel;

  @override
  State<RemoteEditorScreen> createState() => _RemoteEditorScreenState();
}

class _RemoteEditorScreenState extends State<RemoteEditorScreen> {
  final List<_EditorTab> _tabs = [];
  int _active = 0;
  bool _loading = true;

  bool _softWrap = false;

  /// "Show whitespace": tints leading tabs, leading spaces and trailing
  /// whitespace apart. See `CodeEditorField.showWhitespace`.
  bool _showWhitespace = false;

  /// The size on screen while a zoom has not reached Settings yet: during a
  /// pinch, and until the save after a keyboard zoom comes back. Null shows
  /// the editor size from Settings, which every zoom is saved to.
  double? _zoomedFontSize;

  double get _editorFontSize =>
      _zoomedFontSize ?? _settings.editorFontSize;

  /// Pointers down on the editor, for a two-finger pinch — hand-rolled with
  /// a `Listener` like the terminal's, so it never fights the field's own
  /// scrolling and selection gestures.
  final Map<int, Offset> _pointers = {};
  double? _pinchStartDistance;
  double? _pinchStartFontSize;

  bool _findVisible = false;
  bool _replaceVisible = false;
  EditorQuery _query = const EditorQuery(pattern: '');
  final TextEditingController _findController = TextEditingController();
  final TextEditingController _replaceController = TextEditingController();
  final FocusNode _findFocus = FocusNode();
  List<SearchMatch> _matches = const [];
  int _currentMatch = -1;

  late AppSettings _settings;
  StreamSubscription<AppSettings>? _settingsChanges;

  _EditorTab? get _tab =>
      _tabs.isEmpty ? null : _tabs[_active.clamp(0, _tabs.length - 1)];

  TerminalTheme get _terminalTheme =>
      AppTheme.terminalThemeFor(_settings.colorScheme);

  @override
  void initState() {
    super.initState();
    _settings = widget.settingsStore.current;
    _settingsChanges = widget.settingsStore.changes.listen((settings) {
      if (!mounted) return;
      setState(() {
        _settings = settings;
        // Settings has caught up with the zoom (or been changed under it);
        // mid-pinch the fingers still win.
        if (_pinchStartDistance == null) _zoomedFontSize = null;
        for (final tab in _tabs) {
          tab.controller.theme = _terminalTheme;
        }
      });
    });
    unawaited(_openInitial());
  }

  @override
  void dispose() {
    _settingsChanges?.cancel();
    for (final tab in _tabs) {
      tab.dispose();
    }
    _findController.dispose();
    _replaceController.dispose();
    _findFocus.dispose();
    super.dispose();
  }

  Future<void> _openInitial() async {
    for (final path in widget.initialPaths) {
      await _openPath(path, activate: false);
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      _active = 0;
    });
    if (_tabs.isEmpty && mounted) Navigator.of(context).pop();
  }

  // ------------------------------------------------------------- open a file

  Future<void> _openPath(String path, {bool activate = true}) async {
    final existing = _tabs.indexWhere((t) => t.path == path);
    if (existing >= 0) {
      _activate(existing);
      return;
    }

    try {
      final opened = await openRemoteText(
        fs: widget.filesystem,
        metadata: widget.metadata,
        path: path,
      );
      if (!mounted) return;
      final mode = modeForFileName(RemotePath.basename(path));
      final tab = _EditorTab(
        path: path,
        controller: EditorHighlightController(
          text: opened.text,
          mode: mode,
          theme: _terminalTheme,
        ),
        savedText: opened.text,
        lineEndings: opened.lineEndings,
        hadInvalidUtf8: opened.hadInvalidUtf8,
        fingerprint: opened.fingerprint,
        permissions: opened.permissions,
        mode: mode,
      );
      tab
        ..hasBom = opened.hasBom
        ..language = EditorLanguage.forFile(path, mode.id)
        ..indentStyle = detectIndentStyle(
          opened.text,
          EditorLanguage.forFile(path, mode.id),
        );
      // Rebuilds the title's dirty dot and the find bar's counts as the user
      // types; the field repaints itself from the same controller.
      tab.controller.addListener(_onActiveTextChanged);
      setState(() {
        _tabs.add(tab);
        if (activate) _active = _tabs.length - 1;
      });
    } on EditorOpenRefused catch (e) {
      if (mounted) _snack(e.message, isError: true);
    } on SftpFailure catch (e) {
      if (mounted) _snack(e.message, isError: true);
    } catch (e) {
      if (mounted) {
        _snack('Could not open ${RemotePath.basename(path)}.', isError: true);
      }
    }
  }

  /// The active tab's text as of the last notification.
  ///
  /// A [TextEditingController] notifies for selection and composing changes
  /// too — and [EditorHighlightController.setMatches] notifies as well.
  /// Without something to tell those apart from a real edit, recomputing the
  /// find results here would notify, which would recompute, which would
  /// notify: the find bar would spin the isolate the moment it was opened.
  String? _lastKnownText;

  void _onActiveTextChanged() {
    if (!mounted) return;
    final text = _tab?.controller.text;
    final edited = text != _lastKnownText;
    _lastKnownText = text;
    if (_findVisible && edited) {
      _recomputeMatches();
    } else {
      setState(() {});
    }
  }

  /// Offers the other text files in this file's directory, so a second tab
  /// does not mean going back to the browser and forward again.
  Future<void> _openAnother() async {
    final tab = _tab;
    if (tab == null) return;
    final directory = RemotePath.parent(tab.path);

    final List<RemoteEntry> entries;
    try {
      entries = await widget.filesystem.list(directory);
    } on SftpFailure catch (e) {
      if (mounted) _snack(e.message, isError: true);
      return;
    }
    if (!mounted) return;

    final candidates = entries
        .where((e) => e.kind == RemoteEntryKind.file)
        .where((e) => !_tabs.any((t) => t.path == e.path))
        .toList(growable: false);

    if (candidates.isEmpty) {
      _snack('Nothing else in $directory to open.');
      return;
    }

    final theme = Theme.of(context);
    final picked = await showModalBottomSheet<RemoteEntry>(
      context: context,
      backgroundColor: theme.colorScheme.surfaceContainerHigh,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text('Open another file'),
              subtitle: Text(directory),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: candidates.length,
                itemBuilder: (context, i) {
                  final entry = candidates[i];
                  // Everything is listed, not just the names that look like
                  // text: the sniff on open is the real gate, and hiding a
                  // file here would leave a user unable to open something
                  // this list simply failed to recognise.
                  final textish = tapShouldEdit(
                    name: entry.name,
                    size: entry.size,
                  );
                  return ListTile(
                    dense: true,
                    leading: Icon(
                      textish
                          ? Icons.description_outlined
                          : Icons.insert_drive_file_outlined,
                      size: 18,
                      color: textish ? theme.colorScheme.primary : null,
                    ),
                    title: Text(
                      entry.name,
                      style: const TextStyle(fontSize: 13),
                    ),
                    subtitle: Text(RemotePath.formatBytes(entry.size)),
                    onTap: () => Navigator.of(context).pop(entry),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    await _openPath(picked.path);
  }

  // ------------------------------------------------------------------ saving

  Future<void> _save({bool force = false, _EditorTab? target}) async {
    final tab = target ?? _tab;
    if (tab == null) return;
    // Ctrl+S on a file nobody edited must not rewrite it.
    if (!force && !tab.isDirty) return;

    // Mixed line endings have no style to keep; ask which one to write,
    // before writing, rather than reporting afterwards which one was used.
    if (tab.lineEndings == LineEndingStyle.mixed) {
      final chosen = await _askLineEndings(tab);
      if (!mounted || chosen == null) return;
      setState(() => tab.lineEndings = chosen);
    }

    if (tab.hadInvalidUtf8 && !tab.lossyAcknowledged) {
      final go = await _warnAboutLossyEncoding(tab);
      if (!mounted || go != true) return;
      tab.lossyAcknowledged = true;
    }

    final text = tab.controller.text;
    try {
      final outcome = await saveRemoteText(
        fs: widget.filesystem,
        metadata: widget.metadata,
        path: tab.path,
        text: text,
        lineEndings: tab.lineEndings,
        expected: tab.fingerprint,
        permissions: tab.permissions,
        hasBom: tab.hasBom,
        force: force,
      );
      if (!mounted) return;
      setState(() {
        tab.savedText = text;
        tab.fingerprint = outcome.fingerprint;
      });
      _snack(_savedMessage(tab, outcome));
    } on EditorSaveConflict catch (e) {
      if (!mounted) return;
      await _resolveConflict(tab, e);
    } on EditorSaveFailure catch (e) {
      if (!mounted) return;
      await _reportSaveFailure(e);
    } on SftpFailure catch (e) {
      if (mounted) _snack(e.message, isError: true);
    }
  }

  String _savedMessage(_EditorTab tab, SaveOutcome outcome) {
    final notes = <String>[
      if (tab.lineEndings == LineEndingStyle.crlf) 'CRLF kept',
      if (tab.hasBom) 'BOM kept',
      if (outcome.permissionsLost)
        'the server would not restore the original permissions',
    ];
    final head = 'Saved ${tab.name} '
        '(${RemotePath.formatBytes(outcome.bytesWritten)})';
    return notes.isEmpty ? head : '$head · ${notes.join(' · ')}';
  }

  Future<LineEndingStyle?> _askLineEndings(_EditorTab tab) {
    return showDialog<LineEndingStyle>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Mixed line endings'),
        content: Text(
          '"${tab.name}" uses both LF (Linux, macOS) and CRLF (Windows) line '
          'endings. A save has to write one of them for every line — which '
          'should it be?',
          style: const TextStyle(height: 1.35),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(LineEndingStyle.crlf),
            child: const Text('CRLF (Windows)'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(LineEndingStyle.lf),
            child: const Text('LF (Linux)'),
          ),
        ],
      ),
    );
  }

  /// Which indentation new lines and Tab use. Changes nothing already in
  /// the file — converting existing indentation would rewrite every line,
  /// which is exactly what this editor promises not to do behind anyone's
  /// back.
  Future<void> _pickIndent(_EditorTab tab) async {
    const options = <IndentStyle>[
      IndentStyle.spaces(2),
      IndentStyle.spaces(4),
      IndentStyle.spaces(8),
      IndentStyle.tabs(),
    ];
    final picked = await showDialog<IndentStyle>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Indentation'),
        children: [
          for (final option in options)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(option),
              child: Row(
                children: [
                  Icon(
                    option.useTabs == tab.indentStyle.useTabs &&
                            (option.useTabs ||
                                option.size == tab.indentStyle.size)
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: 18,
                  ),
                  const SizedBox(width: 12),
                  Text(option.useTabs ? 'Tabs' : '${option.size} spaces'),
                ],
              ),
            ),
          if (tab.language.requiresTabs)
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 8, 24, 0),
              child: Text(
                'Makefile recipes must start with a tab.',
                style: TextStyle(fontSize: 12),
              ),
            ),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => tab.indentStyle = picked.useTabs
        ? IndentStyle.tabs(tab.indentStyle.size)
        : picked);
  }

  Future<bool?> _warnAboutLossyEncoding(_EditorTab tab) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Not valid UTF-8'),
        content: Text(
          '"${tab.name}" contains bytes that are not valid UTF-8. They were '
          'replaced with \u{FFFD} when it was opened, and saving will write '
          'those replacements back — the original bytes cannot be recovered '
          'from what is on screen.\n\nSave anyway?',
          style: const TextStyle(height: 1.35),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Save anyway'),
          ),
        ],
      ),
    );
  }

  Future<void> _resolveConflict(
    _EditorTab tab,
    EditorSaveConflict conflict,
  ) async {
    final choice = await showDialog<_ConflictChoice>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          conflict.reason == SaveConflictReason.vanished
              ? 'File is gone'
              : 'Changed on the server',
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(conflict.message, style: const TextStyle(height: 1.35)),
            const SizedBox(height: 10),
            Text(
              conflict.reason == SaveConflictReason.vanished
                  ? 'Writing it again would recreate it.'
                  : 'Someone — or something — wrote to it while you had it '
                      'open. Nothing has been written yet.',
              style: TextStyle(
                fontSize: 12.5,
                height: 1.3,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.of(context).pop(_ConflictChoice.saveAsCopy),
            child: const Text('Save as copy'),
          ),
          if (conflict.reason != SaveConflictReason.vanished)
            TextButton(
              onPressed: () =>
                  Navigator.of(context).pop(_ConflictChoice.reloadTheirs),
              child: const Text('Reload theirs'),
            ),
          FilledButton(
            onPressed: () =>
                Navigator.of(context).pop(_ConflictChoice.keepMine),
            child: const Text('Keep mine'),
          ),
        ],
      ),
    );
    if (!mounted || choice == null) return;

    switch (choice) {
      case _ConflictChoice.keepMine:
        await _save(force: true, target: tab);
      case _ConflictChoice.reloadTheirs:
        await _reload(tab);
      case _ConflictChoice.saveAsCopy:
        await _saveAsCopy(tab);
    }
  }

  Future<void> _reload(_EditorTab tab) async {
    try {
      final opened = await openRemoteText(
        fs: widget.filesystem,
        metadata: widget.metadata,
        path: tab.path,
      );
      if (!mounted) return;
      setState(() {
        tab.controller.text = opened.text;
        tab.savedText = opened.text;
        tab.lineEndings = opened.lineEndings;
        tab.hadInvalidUtf8 = opened.hadInvalidUtf8;
        tab.hasBom = opened.hasBom;
        tab.indentStyle = detectIndentStyle(opened.text, tab.language);
        tab.lossyAcknowledged = false;
        tab.fingerprint = opened.fingerprint;
        tab.permissions = opened.permissions;
      });
      _snack('Reloaded ${tab.name} from the server.');
    } on EditorOpenRefused catch (e) {
      if (mounted) _snack(e.message, isError: true);
    } on SftpFailure catch (e) {
      if (mounted) _snack(e.message, isError: true);
    }
  }

  Future<void> _saveAsCopy(_EditorTab tab) async {
    final directory = RemotePath.parent(tab.path);
    final suggested = RemotePath.deduplicate(tab.name, (_) => false);
    final name = await _askForName(
      title: 'Save as copy',
      subtitle: 'A new file in $directory',
      initial: suggested,
    );
    if (!mounted || name == null || name.trim().isEmpty) return;

    final target = RemotePath.join(directory, name.trim());
    final text = tab.controller.text;
    try {
      final outcome = await saveRemoteText(
        fs: widget.filesystem,
        metadata: widget.metadata,
        path: target,
        text: text,
        lineEndings: tab.lineEndings,
        // A copy has no history to be in conflict with, and the name is one
        // the user just chose — the guard has nothing to compare against, so
        // it is skipped rather than fabricated.
        expected: const RemoteFingerprint.unknown(),
        permissions: tab.permissions,
        hasBom: tab.hasBom,
        force: true,
      );
      if (!mounted) return;
      setState(() {
        // The tab follows the copy: the next Ctrl+S must not go back to the
        // file the user just chose not to overwrite.
        tab.path = target;
        tab.savedText = text;
        tab.fingerprint = outcome.fingerprint;
        tab.mode = modeForFileName(RemotePath.basename(target));
        tab.controller.mode = tab.mode;
      });
      _snack('Saved as $target');
    } on EditorSaveFailure catch (e) {
      if (mounted) await _reportSaveFailure(e);
    } on SftpFailure catch (e) {
      if (mounted) _snack(e.message, isError: true);
    }
  }

  Future<void> _reportSaveFailure(EditorSaveFailure failure) {
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          failure.originalIntact ? 'Could not save' : 'Save left a copy behind',
        ),
        content: Text(failure.message, style: const TextStyle(height: 1.35)),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<String?> _askForName({
    required String title,
    required String subtitle,
    required String initial,
  }) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(subtitle, style: const TextStyle(fontSize: 12.5, height: 1.3)),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'File name'),
              onSubmitted: (v) => Navigator.of(context).pop(v),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    ).whenComplete(controller.dispose);
  }

  // ------------------------------------------------------------ closing tabs

  Future<void> _closeTab(int index) async {
    final tab = _tabs[index];
    if (tab.isDirty) {
      final choice = await _askAboutUnsaved([tab]);
      if (!mounted || choice == null) return;
      if (choice) {
        await _save(target: tab);
        if (!mounted || tab.isDirty) return;
      }
    }
    setState(() {
      _tabs.removeAt(index);
      tab.controller.removeListener(_onActiveTextChanged);
      tab.dispose();
      if (_active >= _tabs.length) _active = _tabs.length - 1;
      if (_active < 0) _active = 0;
    });
    if (_tabs.isEmpty && mounted) {
      Navigator.of(context).pop();
    } else {
      _focusActiveAfterFrame();
    }
  }

  /// True to save first, false to discard, null to stay put.
  Future<bool?> _askAboutUnsaved(List<_EditorTab> dirty) {
    final names = dirty.map((t) => t.name).join(', ');
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          dirty.length == 1
              ? 'Unsaved changes'
              : '${dirty.length} unsaved files',
        ),
        content: Text(
          dirty.length == 1
              ? '"$names" has changes that are not on the server.'
              : 'These have changes that are not on the server: $names.',
          style: const TextStyle(height: 1.35),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Keep editing'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Discard'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _handleBack() async {
    final dirty = _tabs.where((t) => t.isDirty).toList(growable: false);
    if (dirty.isEmpty) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    final choice = await _askAboutUnsaved(dirty);
    if (!mounted || choice == null) return;
    if (choice) {
      for (final tab in dirty) {
        await _save(target: tab);
        if (!mounted) return;
      }
      // A save that hit a conflict the user backed out of leaves the tab
      // dirty; leaving the screen anyway would throw away exactly the work
      // the dialog was protecting.
      if (_tabs.any((t) => t.isDirty)) return;
    }
    if (mounted) Navigator.of(context).pop();
  }

  // ------------------------------------------------------------ find/replace

  void _showFind({required bool replace}) {
    setState(() {
      _findVisible = true;
      _replaceVisible = replace;
    });
    _recomputeMatches();
    _findFocus.requestFocus();
  }

  void _hideFind() {
    setState(() {
      _findVisible = false;
      _replaceVisible = false;
      _matches = const [];
      _currentMatch = -1;
    });
    _tab?.controller.clearMatches();
    _tab?.focusNode.requestFocus();
  }

  void _recomputeMatches() {
    final tab = _tab;
    if (tab == null) return;
    final matches = findMatches(tab.controller.text, _query);
    setState(() {
      _matches = matches;
      if (matches.isEmpty) {
        _currentMatch = -1;
      } else if (_currentMatch >= matches.length || _currentMatch < 0) {
        _currentMatch = matchIndexAtOrAfter(
          matches,
          tab.controller.selection.isValid
              ? tab.controller.selection.baseOffset
              : 0,
        );
      }
    });
    tab.controller.setMatches(matches, current: _currentMatch);
  }

  void _stepMatch(int delta) {
    final tab = _tab;
    if (tab == null || _matches.isEmpty) return;
    final next = delta > 0
        ? (_currentMatch + 1) % _matches.length
        : (_currentMatch - 1 + _matches.length) % _matches.length;
    setState(() => _currentMatch = next);
    tab.controller.setMatches(_matches, current: next);
    final match = _matches[next];
    tab.controller.selection = TextSelection(
      baseOffset: match.start,
      extentOffset: match.end,
    );
    tab.focusNode.requestFocus();
  }

  Future<void> _replaceCurrent() async {
    final tab = _tab;
    if (tab == null || _query.isEmpty) return;
    final from = tab.controller.selection.isValid
        ? tab.controller.selection.start
        : 0;
    final result = replaceOne(
      tab.controller.text,
      _query,
      _lfOnly(_replaceController.text),
      from: from,
    );
    if (result.count == 0) {
      _snack('Nothing to replace.');
      return;
    }
    tab.controller.value = TextEditingValue(
      text: result.text,
      selection: TextSelection.collapsed(offset: result.caret),
    );
    _recomputeMatches();
  }

  Future<void> _replaceEverything() async {
    final tab = _tab;
    if (tab == null || _query.isEmpty) return;
    final result = replaceAll(
      tab.controller.text,
      _query,
      _lfOnly(_replaceController.text),
    );
    if (result.count == 0) {
      _snack('Nothing to replace.');
      return;
    }
    tab.controller.value = TextEditingValue(
      text: result.text,
      selection: TextSelection.collapsed(offset: result.caret),
    );
    _recomputeMatches();
    _snack('Replaced ${result.count} '
        'occurrence${result.count == 1 ? '' : 's'}.');
  }

  Future<void> _goToLine() async {
    final tab = _tab;
    if (tab == null) return;
    final total = '\n'.allMatches(tab.controller.text).length + 1;
    final controller = TextEditingController();
    final line = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Go to line'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(labelText: 'Line (1 to $total)'),
          onSubmitted: (v) => Navigator.of(context).pop(int.tryParse(v)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(context).pop(int.tryParse(controller.text)),
            child: const Text('Go'),
          ),
        ],
      ),
    ).whenComplete(controller.dispose);
    if (!mounted || line == null) return;

    final offset = offsetForLine(tab.controller.text, line);
    tab.controller.selection = TextSelection.collapsed(offset: offset);
    tab.focusNode.requestFocus();
  }

  // ------------------------------------------------------------ edit actions

  /// Select all, cut, copy, paste and undo/redo, driven from the Edit menu.
  ///
  /// Every one of these is already bound to its usual chord by Flutter's own
  /// text-editing shortcuts, and the field is a real `TextField`, so the
  /// keyboard path needs nothing from this screen. These exist because a menu
  /// is the only way to reach them on a touch build — and because a menu row
  /// with the chord written next to it is how a desktop user finds out the
  /// chord exists at all.
  ///
  /// They run against the controller rather than dispatching the framework's
  /// intents: the controller *is* the document (see
  /// [EditorHighlightController]), so this is the same edit the keyboard
  /// makes, and it lands on the same undo stack.
  void _selectAll() {
    final tab = _tab;
    if (tab == null) return;
    tab.controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: tab.controller.text.length,
    );
    tab.focusNode.requestFocus();
  }

  Future<void> _copySelection({required bool cut}) async {
    final tab = _tab;
    if (tab == null) return;
    final text = tab.controller.text;
    final selection = tab.controller.selection;
    if (!selection.isValid || selection.isCollapsed) {
      _snack('Select some text first.');
      return;
    }

    await Clipboard.setData(
      ClipboardData(text: selection.textInside(text)),
    );
    if (!mounted) return;

    if (cut) {
      final at = selection.start;
      tab.controller.value = TextEditingValue(
        text: selection.textBefore(text) + selection.textAfter(text),
        selection: TextSelection.collapsed(offset: at),
      );
    }
    tab.focusNode.requestFocus();
  }

  Future<void> _paste() async {
    final tab = _tab;
    if (tab == null) return;
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final raw = data?.text;
    final clip = raw == null ? null : _lfOnly(raw);
    if (!mounted) return;
    if (clip == null || clip.isEmpty) {
      _snack('There is nothing on the clipboard.');
      return;
    }

    final text = tab.controller.text;
    // An untouched tab has no selection at all yet; treat that as "at the
    // end" rather than dropping the paste on the floor.
    final selection = tab.controller.selection.isValid
        ? tab.controller.selection
        : TextSelection.collapsed(offset: text.length);
    final before = selection.textBefore(text);
    tab.controller.value = TextEditingValue(
      text: before + clip + selection.textAfter(text),
      selection: TextSelection.collapsed(offset: before.length + clip.length),
    );
    tab.focusNode.requestFocus();
  }

  /// Text going into the document from outside the keyboard — the menu's
  /// Paste, the replace field — with Windows line breaks made `\n`, like the
  /// field's input formatter does for what is typed and pasted into it. The
  /// buffer is LF-only; a stray `\r\n` here would save as `\r\r\n`.
  static String _lfOnly(String text) =>
      text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

  /// Moves the caret one step, for the key bar's arrows. Up and down keep
  /// the column where the next line is long enough.
  void _moveCaret(_EditorTab tab, AxisDirection direction) {
    final text = tab.controller.text;
    final selection = tab.controller.selection;
    final at = selection.isValid ? selection.extentOffset : text.length;
    int target;
    switch (direction) {
      case AxisDirection.left:
        target = at - 1;
      case AxisDirection.right:
        target = at + 1;
      case AxisDirection.up:
      case AxisDirection.down:
        final lineStart = at == 0 ? 0 : text.lastIndexOf('\n', at - 1) + 1;
        final column = at - lineStart;
        if (direction == AxisDirection.up) {
          if (lineStart == 0) {
            target = 0;
          } else {
            final prevStart = lineStart == 1
                ? 0
                : text.lastIndexOf('\n', lineStart - 2) + 1;
            final prevLength = lineStart - 1 - prevStart;
            target = prevStart + (column < prevLength ? column : prevLength);
          }
        } else {
          final lineEnd = text.indexOf('\n', at);
          if (lineEnd < 0) {
            target = text.length;
          } else {
            final nextStart = lineEnd + 1;
            var nextEnd = text.indexOf('\n', nextStart);
            if (nextEnd < 0) nextEnd = text.length;
            final nextLength = nextEnd - nextStart;
            target = nextStart + (column < nextLength ? column : nextLength);
          }
        }
    }
    tab.controller.selection =
        TextSelection.collapsed(offset: target.clamp(0, text.length));
    tab.focusNode.requestFocus();
  }

  void _zoom(double delta) =>
      _setFontSize(AppSettings.clampEditorFontSize(_editorFontSize + delta));

  void _resetZoom() => _setFontSize(AppSettings.defaultFontSize);

  void _setFontSize(double size) {
    setState(() => _zoomedFontSize = size);
    _saveFontSize(size);
  }

  /// Saves a zoom as the editor's size, so the next file opens at it too.
  void _saveFontSize(double size) {
    // `SettingsStore.update` does not swallow I/O failures; the size is on
    // screen either way, so a full disk must not become an unhandled error.
    unawaited(
      widget.settingsStore
          .update((s) => s.copyWith(editorFontSize: size))
          .catchError((Object _) {}),
    );
  }

  void _onPointerDown(PointerDownEvent event) {
    _pointers[event.pointer] = event.position;
    if (_pointers.length == 2) {
      final points = _pointers.values.toList();
      _pinchStartDistance = (points[0] - points[1]).distance;
      _pinchStartFontSize = _editorFontSize;
    }
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (!_pointers.containsKey(event.pointer)) return;
    _pointers[event.pointer] = event.position;
    final start = _pinchStartDistance;
    final startSize = _pinchStartFontSize;
    if (_pointers.length != 2 || start == null || startSize == null) return;
    if (start < 1) return;
    final points = _pointers.values.toList();
    final scale = (points[0] - points[1]).distance / start;
    final size =
        AppSettings.clampEditorFontSize(startSize * scale).roundToDouble();
    if (size != _editorFontSize) setState(() => _zoomedFontSize = size);
  }

  void _onPointerUp(PointerEvent event) {
    _pointers.remove(event.pointer);
    if (_pointers.length < 2 && _pinchStartDistance != null) {
      _pinchStartDistance = null;
      _pinchStartFontSize = null;
      // Saved once, when the fingers lift, not on every frame of the pinch.
      final pinched = _zoomedFontSize;
      if (pinched != null) _saveFontSize(pinched);
    }
  }

  void _undo() {
    final tab = _tab;
    if (tab == null) return;
    tab.undo.undo();
    tab.focusNode.requestFocus();
  }

  void _redo() {
    final tab = _tab;
    if (tab == null) return;
    tab.undo.redo();
    tab.focusNode.requestFocus();
  }

  /// Whether this platform spells the editing chords with Command.
  bool get _isMac => Theme.of(context).platform == TargetPlatform.macOS;

  /// Where a hardware keyboard is the way in, so the field can take focus
  /// the moment a file opens — a desktop, and equally a tablet in a keyboard
  /// cover or a DeX desk once a key has been typed on it. See
  /// `input_profile.dart`; with nothing seen yet it is the platform, read
  /// through the theme so a test can pick one by handing it a theme.
  bool get _hasKeyboard => InputProfile.of(context).keyboard;

  /// `Ctrl+S` / `⌘S`, for the menu hints and the shortcut sheet.
  String _chord(String key, {bool shift = false}) {
    if (_isMac) return '${shift ? '⇧' : ''}⌘$key';
    return 'Ctrl+${shift ? 'Shift+' : ''}$key';
  }

  Future<void> _showShortcuts() {
    final theme = Theme.of(context);
    final rows = <(String, String)>[
      ('Save', _chord('S')),
      ('Find', _chord('F')),
      ('Replace', _chord('H')),
      ('Go to line', _chord('G')),
      ('Close the find bar', 'Esc'),
      ('Select all', _chord('A')),
      ('Copy', _chord('C')),
      ('Cut', _chord('X')),
      ('Paste', _chord('V')),
      ('Undo', _chord('Z')),
      ('Redo', _chord('Z', shift: true)),
      ('Indent / outdent', 'Tab / Shift+Tab'),
      ('Indent / outdent line', '${_chord(']')} / ${_chord('[')}'),
      ('Comment line', _chord('/')),
      ('Move line', 'Alt+↑ / Alt+↓'),
      ('Duplicate line', 'Shift+Alt+↓'),
      ('Zoom in / out', '${_chord('=')} / ${_chord('-')}'),
    ];

    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Keyboard shortcuts'),
        // Scrollable as a floor, not as a feature: eleven rows fit a laptop
        // without moving, and a short window gets a scroll instead of an
        // overflow.
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (label, keys) in rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          label,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          keys,
                          style: TextStyle(
                            fontFamily: AppTheme.monoFontFamily,
                            fontFamilyFallback: AppTheme.monoFontFamilyFallback,
                            fontSize: 12,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _snack(String message, {bool isError = false}) {
    final theme = Theme.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? theme.colorScheme.error : null,
      ),
    );
  }

  // ------------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final tab = _tab;
    final theme = _terminalTheme;

    return PopScope(
      // Never pops on its own: an unsaved file has to be asked about first,
      // and the answer arrives asynchronously.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_handleBack());
      },
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.keyS, control: true):
              () => unawaited(_save()),
          const SingleActivator(LogicalKeyboardKey.keyS, meta: true):
              () => unawaited(_save()),
          const SingleActivator(LogicalKeyboardKey.keyF, control: true):
              () => _showFind(replace: false),
          const SingleActivator(LogicalKeyboardKey.keyF, meta: true):
              () => _showFind(replace: false),
          const SingleActivator(LogicalKeyboardKey.keyH, control: true):
              () => _showFind(replace: true),
          const SingleActivator(LogicalKeyboardKey.keyH, meta: true):
              () => _showFind(replace: true),
          const SingleActivator(LogicalKeyboardKey.keyG, control: true):
              () => unawaited(_goToLine()),
          const SingleActivator(LogicalKeyboardKey.keyG, meta: true):
              () => unawaited(_goToLine()),
          const SingleActivator(LogicalKeyboardKey.escape): _hideFind,
          for (final meta in const [false, true]) ...{
            SingleActivator(LogicalKeyboardKey.equal,
                control: !meta, meta: meta): () => _zoom(1),
            SingleActivator(LogicalKeyboardKey.numpadAdd,
                control: !meta, meta: meta): () => _zoom(1),
            SingleActivator(LogicalKeyboardKey.minus,
                control: !meta, meta: meta): () => _zoom(-1),
            SingleActivator(LogicalKeyboardKey.numpadSubtract,
                control: !meta, meta: meta): () => _zoom(-1),
            SingleActivator(LogicalKeyboardKey.digit0,
                control: !meta, meta: meta): _resetZoom,
          },
        },
        child: Scaffold(
          backgroundColor: theme.background,
          appBar: AppBar(
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              tooltip: 'Back',
              onPressed: () => unawaited(_handleBack()),
            ),
            title: _title(tab),
            actions: _actions(tab),
          ),
          body: _body(tab, theme),
        ),
      ),
    );
  }

  Widget _title(_EditorTab? tab) {
    if (tab == null) return const Text('Editor');
    final host = widget.hostLabel;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                tab.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 16),
              ),
            ),
            // The dirty indicator. A dot rather than an asterisk in the name:
            // it does not change the width of the title as you type, so the
            // file name stops jittering on every first keystroke.
            if (tab.isDirty) ...[
              const SizedBox(width: 8),
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary,
                  shape: BoxShape.circle,
                ),
              ),
            ],
          ],
        ),
        Text(
          host == null ? tab.path : '$host:${tab.path}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 11,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  List<Widget> _actions(_EditorTab? tab) {
    if (tab == null) return const [];
    return [
      IconButton(
        tooltip: 'Find (Ctrl+F)',
        icon: const Icon(Icons.search, size: 20),
        onPressed: () => _showFind(replace: false),
      ),
      IconButton(
        tooltip: tab.isDirty ? 'Save (Ctrl+S)' : 'No changes to save',
        icon: const Icon(Icons.save_outlined, size: 20),
        onPressed: tab.isDirty ? () => unawaited(_save()) : null,
      ),
      _editMenu(tab),
      PopupMenuButton<String>(
        tooltip: 'More',
        onSelected: (value) {
          switch (value) {
            case 'wrap':
              setState(() => _softWrap = !_softWrap);
            case 'whitespace':
              setState(() => _showWhitespace = !_showWhitespace);
            case 'indent':
              unawaited(_pickIndent(tab));
            case 'goto':
              unawaited(_goToLine());
            case 'replace':
              _showFind(replace: true);
            case 'reload':
              unawaited(_reload(tab));
            case 'copy':
              unawaited(_saveAsCopy(tab));
            case 'open':
              unawaited(_openAnother());
            default:
              // A syntax mode. Held on the tab as well as the controller so
              // the menu's check mark and the colours cannot disagree.
              setState(() {
                tab.mode = syntaxModeById(value);
                tab.controller.mode = tab.mode;
                tab.language = EditorLanguage.forFile(tab.path, tab.mode.id);
              });
          }
        },
        itemBuilder: (context) => [
          PopupMenuItem(
            value: 'wrap',
            child: Row(
              children: [
                Icon(
                  _softWrap ? Icons.check_box : Icons.check_box_outline_blank,
                  size: 18,
                ),
                const SizedBox(width: 10),
                const Text('Soft wrap'),
              ],
            ),
          ),
          PopupMenuItem(
            value: 'whitespace',
            child: Row(
              children: [
                Icon(
                  _showWhitespace
                      ? Icons.check_box
                      : Icons.check_box_outline_blank,
                  size: 18,
                ),
                const SizedBox(width: 10),
                const Text('Show whitespace'),
              ],
            ),
          ),
          PopupMenuItem(
            value: 'indent',
            child: Text('Indentation: ${tab.indentStyle.label}…'),
          ),
          const PopupMenuItem(value: 'goto', child: Text('Go to line…')),
          const PopupMenuItem(value: 'replace', child: Text('Replace…')),
          const PopupMenuItem(value: 'open', child: Text('Open another file…')),
          const PopupMenuItem(
            value: 'reload',
            child: Text('Reload from server'),
          ),
          const PopupMenuItem(value: 'copy', child: Text('Save as copy…')),
          const PopupMenuDivider(),
          for (final mode in syntaxModes)
            PopupMenuItem(
              value: mode.id,
              child: Row(
                children: [
                  Icon(
                    identical(mode, tab.mode)
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: 16,
                  ),
                  const SizedBox(width: 10),
                  // Flexible, not bare: a popup menu is 256 logical pixels
                  // wide and "JavaScript / TypeScript" does not fit beside a
                  // radio button in it.
                  Flexible(
                    child: Text(mode.label, overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
            ),
        ],
      ),
    ];
  }

  /// The editing actions, written out with the chord that already runs them.
  ///
  /// Not decoration: on a touch build this menu is the only way to select all,
  /// cut, copy, paste or undo at all, and on a desktop it is where a user who
  /// does not know the chord finds it.
  Widget _editMenu(_EditorTab tab) {
    return PopupMenuButton<String>(
      tooltip: 'Edit',
      icon: const Icon(Icons.edit_outlined, size: 20),
      onSelected: (value) {
        switch (value) {
          case 'selectAll':
            _selectAll();
          case 'cut':
            unawaited(_copySelection(cut: true));
          case 'copy':
            unawaited(_copySelection(cut: false));
          case 'paste':
            unawaited(_paste());
          case 'undo':
            _undo();
          case 'redo':
            _redo();
          case 'shortcuts':
            unawaited(_showShortcuts());
        }
      },
      // Read when the menu opens, not when the bar was built: the undo stack
      // pushes through a throttle, so an app bar rebuilt on the keystroke
      // still thinks there is nothing to undo half a second later.
      itemBuilder: (context) => [
        _editItem('selectAll', 'Select all', Icons.select_all, _chord('A')),
        _editItem('cut', 'Cut', Icons.content_cut, _chord('X')),
        _editItem('copy', 'Copy', Icons.content_copy, _chord('C')),
        _editItem('paste', 'Paste', Icons.content_paste, _chord('V')),
        const PopupMenuDivider(),
        _editItem(
          'undo',
          'Undo',
          Icons.undo,
          _chord('Z'),
          enabled: tab.undo.value.canUndo,
        ),
        _editItem(
          'redo',
          'Redo',
          Icons.redo,
          _chord('Z', shift: true),
          enabled: tab.undo.value.canRedo,
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'shortcuts',
          child: Text('Keyboard shortcuts…'),
        ),
      ],
    );
  }

  PopupMenuItem<String> _editItem(
    String value,
    String label,
    IconData icon,
    String chord, {
    bool enabled = true,
  }) {
    final theme = Theme.of(context);
    return PopupMenuItem<String>(
      value: value,
      enabled: enabled,
      child: Row(
        children: [
          Icon(icon, size: 17),
          const SizedBox(width: 10),
          Expanded(child: Text(label, overflow: TextOverflow.ellipsis)),
          const SizedBox(width: 8),
          Text(
            chord,
            style: TextStyle(
              fontFamily: AppTheme.monoFontFamily,
              fontFamilyFallback: AppTheme.monoFontFamilyFallback,
              fontSize: 11,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _body(_EditorTab? tab, TerminalTheme theme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (tab == null) {
      return const Center(child: Text('Nothing open.'));
    }

    // Wide enough for a list beside the text: open files move from the tab
    // strip to a side panel, where long names fit.
    final sidePanel = _tabs.length > 1 &&
        WindowSizeClass.forWidth(MediaQuery.sizeOf(context).width)
            .isAtLeastMedium;
    final active = _active.clamp(0, _tabs.length - 1);

    // One live editor per tab rather than one rebuilt per switch: the undo
    // history lives inside the field, so rebuilding it for the next file
    // threw away the last one's — and its scroll position with it.
    final editors = IndexedStack(
      index: active,
      children: [
        for (final t in _tabs)
          CodeEditorField(
            key: t.fieldKey,
            controller: t.controller,
            focusNode: t.focusNode,
            undoController: t.undo,
            // The field has to *hold* the keyboard for Ctrl+A, Ctrl+S and
            // the rest to reach it. Only with a hardware keyboard: doing it on
            // a phone would open the soft keyboard over the file the moment
            // it appeared, before the user has decided to change anything.
            autofocus: _hasKeyboard && identical(t, tab),
            theme: theme,
            fontSize: _editorFontSize,
            softWrap: _softWrap,
            indentStyle: t.indentStyle,
            language: t.language,
            showWhitespace: _showWhitespace,
          ),
      ],
    );

    return Column(
      children: [
        if (_tabs.length > 1 && !sidePanel) _tabStrip(theme),
        if (_findVisible) _findBar(theme),
        if (tab.hadInvalidUtf8) _encodingBanner(tab),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (sidePanel) _openFilesPanel(theme),
              Expanded(
                child: Listener(
                  onPointerDown: _onPointerDown,
                  onPointerMove: _onPointerMove,
                  onPointerUp: _onPointerUp,
                  onPointerCancel: _onPointerUp,
                  child: editors,
                ),
              ),
            ],
          ),
        ),
        // Settings' "Extra keys row", same as the terminal's: automatically,
        // gone while a hardware keyboard types and back with the soft one.
        if (InputProfile.of(context).showsKeyBar(_settings.keyBarMode))
          EditorKeyBar(
            theme: theme,
            onIndent: () => tab.fieldKey.currentState?.indentSelection(),
            onOutdent: () => tab.fieldKey.currentState?.outdentSelection(),
            onType: (text) => tab.fieldKey.currentState?.typeText(text),
            onArrow: (direction) => _moveCaret(tab, direction),
            onUndo: _undo,
            onRedo: _redo,
          ),
        _statusBar(tab, theme),
      ],
    );
  }

  void _activate(int index) {
    setState(() => _active = index);
    _focusActiveAfterFrame();
  }

  /// Hands the keyboard to the file now in front, where a hardware keyboard
  /// is typing.
  ///
  /// After the frame, not now: until the stack rebuilds, that field is still
  /// a hidden child, which `IndexedStack` wraps in an `ExcludeFocus` — a
  /// request made before then is refused, and the keyboard went nowhere.
  void _focusActiveAfterFrame() {
    if (!_hasKeyboard) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _tabs.isEmpty) return;
      _tabs[_active.clamp(0, _tabs.length - 1)].focusNode.requestFocus();
    });
  }

  Widget _openFilesPanel(TerminalTheme theme) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: 210,
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        border: Border(right: BorderSide(color: colorScheme.outlineVariant)),
      ),
      child: ListView.builder(
        itemCount: _tabs.length,
        itemBuilder: (context, i) {
          final t = _tabs[i];
          final isActive = i == _active;
          return Material(
            color: isActive
                ? colorScheme.primary.withValues(alpha: 0.14)
                : Colors.transparent,
            child: InkWell(
              onTap: () => _activate(i),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            t.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight:
                                  isActive ? FontWeight.w600 : FontWeight.w400,
                              color: isActive
                                  ? theme.foreground
                                  : theme.brightBlack,
                            ),
                          ),
                          Text(
                            RemotePath.parent(t.path),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: theme.brightBlack,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (t.isDirty)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            color: colorScheme.primary,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 15),
                      tooltip: 'Close ${t.name}',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => unawaited(_closeTab(i)),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _tabStrip(TerminalTheme theme) {
    return SizedBox(
      height: 38,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: _tabs.length,
        itemBuilder: (context, i) {
          final tab = _tabs[i];
          final active = i == _active;
          final colorScheme = Theme.of(context).colorScheme;
          return InkWell(
            onTap: () => _activate(i),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: active
                    ? colorScheme.primary.withValues(alpha: 0.14)
                    : Colors.transparent,
                border: Border(
                  bottom: BorderSide(
                    color: active ? colorScheme.primary : Colors.transparent,
                    width: 2,
                  ),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    tab.name,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: active ? theme.foreground : theme.brightBlack,
                    ),
                  ),
                  if (tab.isDirty) ...[
                    const SizedBox(width: 6),
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: colorScheme.primary,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ],
                  const SizedBox(width: 4),
                  IconButton(
                    icon: const Icon(Icons.close, size: 14),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 24,
                      minHeight: 24,
                    ),
                    tooltip: 'Close ${tab.name}',
                    onPressed: () => unawaited(_closeTab(i)),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _encodingBanner(_EditorTab tab) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.error.withValues(alpha: 0.14),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Row(
          children: [
            Icon(Icons.warning_amber_outlined,
                size: 18, color: theme.colorScheme.error),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                'This file is not valid UTF-8. Saving will normalise it.',
                style: TextStyle(fontSize: 12.5, height: 1.3),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _findBar(TerminalTheme theme) {
    final compiled = compileQuery(_query);
    final error = compiled.error;
    final countLabel = _query.isEmpty
        ? ''
        : _matches.isEmpty
            ? 'none'
            : '${_currentMatch + 1} of ${_matches.length}'
                '${_matches.length >= editorMaxMatches ? '+' : ''}';

    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Everything but the field is fixed-width and compact, and the
            // field takes what is left. Five default-sized `IconButton`s are
            // 240 logical pixels of the 360 a phone has, which overflows the
            // row before a single character can be typed into it.
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _findController,
                    focusNode: _findFocus,
                    style: const TextStyle(fontSize: 13),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: 'Find',
                      errorText: error,
                      errorStyle: const TextStyle(fontSize: 11),
                      suffixText: countLabel,
                      suffixStyle: const TextStyle(fontSize: 11),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                    ),
                    onChanged: (value) {
                      setState(() {
                        _query = _query.copyWith(pattern: value);
                        _currentMatch = -1;
                      });
                      _recomputeMatches();
                    },
                    onSubmitted: (_) => _stepMatch(1),
                  ),
                ),
                _compact(
                  tooltip: 'Match case',
                  selected: _query.caseSensitive,
                  child: const Text('Aa', style: TextStyle(fontSize: 12)),
                  onPressed: () {
                    setState(() {
                      _query = _query.copyWith(
                        caseSensitive: !_query.caseSensitive,
                      );
                    });
                    _recomputeMatches();
                  },
                ),
                _compact(
                  tooltip: 'Regular expression',
                  selected: _query.isRegex,
                  child: const Text('.*', style: TextStyle(fontSize: 12)),
                  onPressed: () {
                    setState(() {
                      _query = _query.copyWith(isRegex: !_query.isRegex);
                    });
                    _recomputeMatches();
                  },
                ),
                _compact(
                  tooltip: 'Previous',
                  child: const Icon(Icons.keyboard_arrow_up, size: 18),
                  onPressed: _matches.isEmpty ? null : () => _stepMatch(-1),
                ),
                _compact(
                  tooltip: 'Next',
                  child: const Icon(Icons.keyboard_arrow_down, size: 18),
                  onPressed: _matches.isEmpty ? null : () => _stepMatch(1),
                ),
                _compact(
                  tooltip: 'Close',
                  child: const Icon(Icons.close, size: 16),
                  onPressed: _hideFind,
                ),
              ],
            ),
            if (_replaceVisible) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _replaceController,
                      style: const TextStyle(fontSize: 13),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: _query.isRegex
                            ? r'Replace with (use $1 for a group)'
                            : 'Replace with',
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  TextButton(
                    onPressed: _matches.isEmpty
                        ? null
                        : () => unawaited(_replaceCurrent()),
                    child: const Text('Replace'),
                  ),
                  TextButton(
                    onPressed: _matches.isEmpty
                        ? null
                        : () => unawaited(_replaceEverything()),
                    child: const Text('All'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// A find-bar button sized for a phone rather than for a thumb: the bar has
  /// five of them and a text field, and the field is the part that has to
  /// stay usable.
  Widget _compact({
    required String tooltip,
    required Widget child,
    required VoidCallback? onPressed,
    bool selected = false,
  }) {
    final theme = Theme.of(context);
    return IconButton(
      tooltip: tooltip,
      icon: child,
      isSelected: selected,
      color: selected ? theme.colorScheme.primary : null,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
      onPressed: onPressed,
    );
  }

  Widget _statusBar(_EditorTab tab, TerminalTheme theme) {
    final text = tab.controller.text;
    final selection = tab.controller.selection;
    final caret = selection.isValid
        ? selection.extentOffset.clamp(0, text.length)
        : 0;
    final line = lineForOffset(text, caret);
    final column = visualColumn(text, caret, tab.indentStyle.size) + 1;
    // Only where it breaks something: Python raises TabError on it, YAML
    // refuses tabs outright, and a Makefile recipe needs exactly a tab.
    final checkIndent = tab.language.indentAfterColon ||
        tab.language.requiresTabs;
    final mixed = checkIndent && hasMixedIndentation(text);

    final colorScheme = Theme.of(context).colorScheme;
    final dim = TextStyle(fontSize: 11, color: theme.brightBlack);
    return Material(
      color: colorScheme.surfaceContainerHigh,
      child: SizedBox(
        height: 26,
        child: Row(
          children: [
            const SizedBox(width: 10),
            Text('Ln $line, Col $column', style: dim),
            const Spacer(),
            if (mixed)
              Tooltip(
                message: 'This file mixes tabs and spaces in its indentation. '
                    'Turn on Show whitespace to see where.',
                child: Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Icon(
                    Icons.warning_amber_rounded,
                    size: 15,
                    color: colorScheme.error,
                  ),
                ),
              ),
            InkWell(
              onTap: () => unawaited(_pickIndent(tab)),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Text(tab.indentStyle.label, style: dim),
              ),
            ),
            Flexible(
              child: Text(
                '· ${tab.mode.label} · ${tab.lineEndings.label} · '
                '${tab.hasBom ? 'UTF-8 BOM' : 'UTF-8'}'
                '${_softWrap ? ' · wrap' : ''}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: dim,
              ),
            ),
            const SizedBox(width: 10),
          ],
        ),
      ),
    );
  }
}

/// Opens [paths] in the editor, over the session's existing SFTP channel.
///
/// The one way in. Both of the browser's entry points — the action sheet's
/// "Edit" row and a tap on a file that reads as text — come through here, so
/// the refusal rules and the metadata probe cannot drift apart between them.
Future<void> openRemoteEditor(
  BuildContext context, {
  required RemoteFileSystem filesystem,
  required SettingsStore settingsStore,
  required List<String> paths,
  String? hostLabel,
}) {
  // The stat/chmod half is optional on the interface but present on the real
  // service; probing for it here keeps every fake in the test tree working,
  // with a conflict guard that falls back to size alone.
  final metadata = filesystem is RemoteFileMetadata
      ? filesystem as RemoteFileMetadata
      : null;
  return Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (context) => RemoteEditorScreen(
        filesystem: filesystem,
        metadata: metadata,
        settingsStore: settingsStore,
        initialPaths: paths,
        hostLabel: hostLabel,
      ),
    ),
  );
}
