import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../models/app_settings.dart';
import '../models/remote_entry.dart';
import '../services/editor_document.dart';
import '../services/editor_save.dart';
import '../services/editor_search.dart';
import '../services/remote_path.dart';
import '../services/settings_store.dart';
import '../services/sftp_service.dart';
import '../services/syntax_highlighter.dart';
import '../theme.dart';
import '../widgets/code_editor_field.dart';

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

  String savedText;
  LineEndingStyle lineEndings;
  bool hadInvalidUtf8;
  RemoteFingerprint fingerprint;
  int? permissions;

  SyntaxMode mode;

  /// Set once the user has been told the file was not valid UTF-8, so the
  /// warning interrupts the first save and not every one after it.
  bool lossyAcknowledged = false;

  String get name => RemotePath.basename(path);

  bool get isDirty => controller.text != savedText;

  void dispose() {
    controller.dispose();
    focusNode.dispose();
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
      setState(() => _active = existing);
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

    final picked = await showModalBottomSheet<RemoteEntry>(
      context: context,
      backgroundColor: AppTheme.surface,
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
                      color: textish ? AppTheme.accent : null,
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
      if (tab.lineEndings == LineEndingStyle.mixed)
        'mixed line endings saved as LF',
      if (tab.lineEndings == LineEndingStyle.crlf) 'CRLF kept',
      if (outcome.permissionsLost)
        'the server would not restore the original permissions',
    ];
    final head = 'Saved ${tab.name} '
        '(${RemotePath.formatBytes(outcome.bytesWritten)})';
    return notes.isEmpty ? head : '$head · ${notes.join(' · ')}';
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
    if (_tabs.isEmpty && mounted) Navigator.of(context).pop();
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
      _replaceController.text,
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
      _replaceController.text,
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

  void _snack(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? AppTheme.danger : null,
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
                decoration: const BoxDecoration(
                  color: AppTheme.accent,
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
      PopupMenuButton<String>(
        tooltip: 'More',
        onSelected: (value) {
          switch (value) {
            case 'wrap':
              setState(() => _softWrap = !_softWrap);
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

  Widget _body(_EditorTab? tab, TerminalTheme theme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (tab == null) {
      return const Center(child: Text('Nothing open.'));
    }

    return Column(
      children: [
        if (_tabs.length > 1) _tabStrip(theme),
        if (_findVisible) _findBar(theme),
        if (tab.hadInvalidUtf8) _encodingBanner(tab),
        Expanded(
          child: CodeEditorField(
            // Keyed by path so switching tabs rebuilds the field's scroll
            // state against the right document rather than carrying the
            // previous file's offset into the next one.
            key: ValueKey(tab.path),
            controller: tab.controller,
            focusNode: tab.focusNode,
            theme: theme,
            fontSize: _settings.terminalFontSize,
            softWrap: _softWrap,
          ),
        ),
        _statusBar(tab, theme),
      ],
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
          return InkWell(
            onTap: () => setState(() => _active = i),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: active
                    ? AppTheme.accent.withValues(alpha: 0.14)
                    : Colors.transparent,
                border: Border(
                  bottom: BorderSide(
                    color: active ? AppTheme.accent : Colors.transparent,
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
                      decoration: const BoxDecoration(
                        color: AppTheme.accent,
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
    return Material(
      color: AppTheme.danger.withValues(alpha: 0.14),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Row(
          children: [
            const Icon(Icons.warning_amber_outlined,
                size: 18, color: AppTheme.danger),
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

    return Material(
      color: AppTheme.surface,
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
    return IconButton(
      tooltip: tooltip,
      icon: child,
      isSelected: selected,
      color: selected ? AppTheme.accent : null,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
      onPressed: onPressed,
    );
  }

  Widget _statusBar(_EditorTab tab, TerminalTheme theme) {
    final selection = tab.controller.selection;
    final line = selection.isValid
        ? lineForOffset(tab.controller.text, selection.baseOffset)
        : 1;
    final total = '\n'.allMatches(tab.controller.text).length + 1;

    return Material(
      color: AppTheme.surface,
      child: SizedBox(
        height: 26,
        child: Row(
          children: [
            const SizedBox(width: 10),
            Text(
              'Ln $line of $total',
              style: TextStyle(fontSize: 11, color: theme.brightBlack),
            ),
            const Spacer(),
            Text(
              '${tab.mode.label} · ${tab.lineEndings.label}'
              '${_softWrap ? ' · wrap' : ''}',
              style: TextStyle(fontSize: 11, color: theme.brightBlack),
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
