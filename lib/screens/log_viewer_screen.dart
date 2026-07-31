import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../services/log_tail.dart';
import '../services/remote_exec.dart';
import '../services/session_controller.dart';
import '../services/settings_store.dart';
import '../theme.dart';

/// A live `tail -F` on one remote file.
///
/// The remote process is owned by [LogTailSession] and dies with this route —
/// see that class's `dispose`, which closes stdin (releasing the command's own
/// watchdog) before closing the channel. Leaving this screen by any means —
/// back, a dropped connection, the app being killed — ends the `tail`.
class LogViewerScreen extends StatefulWidget {
  const LogViewerScreen({
    super.key,
    required this.session,
    required this.path,
    required this.settingsStore,
  });

  final SessionController session;
  final String path;
  final SettingsStore settingsStore;

  @override
  State<LogViewerScreen> createState() => _LogViewerScreenState();
}

class _LogViewerScreenState extends State<LogViewerScreen> {
  final LogBuffer _buffer = LogBuffer();
  final ScrollController _scroll = ScrollController();
  final TextEditingController _filter = TextEditingController();

  LogTailSession? _tail;
  StreamSubscription<String>? _lines;

  String? _error;
  var _connecting = true;

  /// Whether the view sticks to the bottom as lines arrive. Turned off the
  /// moment the user scrolls up — reading something is the clearest possible
  /// signal that they do not want it yanked away.
  var _follow = true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_watchScroll);
    unawaited(_open());
  }

  @override
  void dispose() {
    unawaited(_lines?.cancel());
    // The whole no-orphan guarantee, at the one moment it matters.
    unawaited(_tail?.dispose());
    _scroll.removeListener(_watchScroll);
    _scroll.dispose();
    _filter.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    try {
      final tail = await LogTailSession.open(
        widget.session.connection,
        widget.path,
      );
      if (!mounted) {
        // The user left while the channel was opening; nothing is going to
        // read this, so it must not be left running on the server.
        await tail.dispose();
        return;
      }
      _tail = tail;
      _lines = tail.lines.listen(_onLine);
      tail.start();
      setState(() => _connecting = false);
    } on MonitorFailure catch (e) {
      if (!mounted) return;
      setState(() {
        _connecting = false;
        _error = e.message;
      });
    }
  }

  void _onLine(String line) {
    if (!mounted) return;
    setState(() => _buffer.add(line));
    if (_follow && !_buffer.isPaused) _scheduleScroll();
  }

  /// Scrolls after the frame that will contain the new line has been laid
  /// out — jumping now would target an extent that does not exist yet.
  void _scheduleScroll() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients || !_follow) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  void _watchScroll() {
    if (!_scroll.hasClients) return;
    // A 40px tolerance rather than an exact match: the extent moves as lines
    // land, and demanding equality would drop follow mode on every frame.
    final atBottom =
        _scroll.position.pixels >= _scroll.position.maxScrollExtent - 40;
    if (atBottom != _follow) setState(() => _follow = atBottom);
  }

  void _togglePause() {
    setState(() {
      if (_buffer.isPaused) {
        _buffer.resume();
        if (_follow) _scheduleScroll();
      } else {
        _buffer.pause();
      }
    });
  }

  void _jumpToBottom() {
    setState(() => _follow = true);
    _scheduleScroll();
  }

  @override
  Widget build(BuildContext context) {
    final theme = AppTheme.terminalThemeFor(
      widget.settingsStore.current.colorScheme,
    );
    final visible = _buffer.visible;

    return Scaffold(
      backgroundColor: theme.background,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.path.split('/').last,
              style: const TextStyle(fontSize: 16),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              widget.session.host.displayName,
              style: TextStyle(
                fontSize: 11.5,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: _buffer.isPaused ? 'Resume' : 'Pause',
            icon: Icon(_buffer.isPaused ? Icons.play_arrow : Icons.pause),
            color: _buffer.isPaused ? AppTheme.accent : null,
            onPressed: _error != null ? null : _togglePause,
          ),
          IconButton(
            tooltip: 'Clear the scrollback',
            icon: const Icon(Icons.clear_all),
            onPressed: _buffer.isEmpty
                ? null
                : () => setState(() => _buffer.clear()),
          ),
          IconButton(
            tooltip: 'Copy the visible lines',
            icon: const Icon(Icons.copy_all_outlined),
            onPressed: visible.isEmpty ? null : () => unawaited(_copy(visible)),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            _FilterBar(
              controller: _filter,
              onChanged: (value) => setState(() => _buffer.filter = value),
              matched: visible.length,
              total: _buffer.length,
            ),
            if (_buffer.isPaused)
              _PausedBanner(
                pending: _buffer.pendingCount,
                onResume: _togglePause,
              ),
            Expanded(child: _body(theme, visible)),
          ],
        ),
      ),
      floatingActionButton: _follow || _error != null
          ? null
          : FloatingActionButton.small(
              tooltip: 'Jump to the newest line',
              onPressed: _jumpToBottom,
              child: const Icon(Icons.arrow_downward),
            ),
    );
  }

  Widget _body(TerminalTheme theme, List<LogLine> visible) {
    if (_connecting) {
      return const Center(child: CircularProgressIndicator());
    }
    final error = _error;
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 40, color: AppTheme.danger),
              const SizedBox(height: 12),
              Text(error, textAlign: TextAlign.center),
            ],
          ),
        ),
      );
    }
    if (visible.isEmpty) {
      return Center(
        child: Text(
          _buffer.isEmpty
              ? 'Waiting for output…'
              : 'No lines match “${_buffer.filter}”.',
          style: TextStyle(color: theme.brightBlack),
        ),
      );
    }

    return Scrollbar(
      controller: _scroll,
      child: ListView.builder(
        controller: _scroll,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: visible.length,
        itemBuilder: (context, index) => _Line(
          line: visible[index],
          theme: theme,
        ),
      ),
    );
  }

  Future<void> _copy(List<LogLine> lines) async {
    await Clipboard.setData(
      ClipboardData(text: lines.map((line) => line.text).join('\n')),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Copied ${lines.length} lines')),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.line, required this.theme});

  final LogLine line;
  final TerminalTheme theme;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 1),
      child: SelectableText(
        line.text.isEmpty ? ' ' : line.text,
        style: TextStyle(
          fontFamily: AppTheme.monoFontFamily,
          fontFamilyFallback: AppTheme.monoFontFamilyFallback,
          fontSize: 12.5,
          height: 1.35,
          color: severityColour(line.severity, theme),
        ),
      ),
    );
  }
}

/// Severity to a colour out of the user's own terminal palette.
///
/// Out of [TerminalTheme] rather than a fixed set, for the reason
/// `AppTheme.syntaxStyleFor` gives: this sits one route away from the
/// terminal, and a Solarized Light user should not get a near-black log
/// viewer next to their cream shell. `brightBlack` is every palette's dimmed
/// tone, which is what INFO/DEBUG want.
Color severityColour(LogSeverity severity, TerminalTheme theme) {
  return switch (severity) {
    LogSeverity.error => theme.red,
    LogSeverity.warning => theme.yellow,
    LogSeverity.info => theme.brightBlack,
    LogSeverity.plain => theme.foreground,
  };
}

class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.controller,
    required this.onChanged,
    required this.matched,
    required this.total,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final int matched;
  final int total;

  @override
  Widget build(BuildContext context) {
    final filtering = controller.text.trim().isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          isDense: true,
          prefixIcon: const Icon(Icons.filter_alt_outlined, size: 18),
          prefixIconConstraints:
              const BoxConstraints(minWidth: 38, minHeight: 32),
          hintText: 'Filter lines…',
          hintStyle: const TextStyle(fontSize: 13),
          // The counter doubles as the reassurance that a filter hiding
          // everything has not lost anything.
          suffixText: filtering ? '$matched / $total' : '$total lines',
          suffixStyle: TextStyle(
            fontSize: 11.5,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
        ),
      ),
    );
  }
}

class _PausedBanner extends StatelessWidget {
  const _PausedBanner({required this.pending, required this.onResume});

  final int pending;
  final VoidCallback onResume;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: AppTheme.accent.withValues(alpha: 0.15),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          const Icon(Icons.pause_circle_outline, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              pending == 0
                  ? 'Paused'
                  : pending == 1
                      ? 'Paused — 1 new line'
                      : 'Paused — $pending new lines',
              style: const TextStyle(fontSize: 12.5),
            ),
          ),
          TextButton(onPressed: onResume, child: const Text('Resume')),
        ],
      ),
    );
  }
}

/// Asks for a path, then opens the viewer on it.
///
/// The prompt exists because the terminal pane has no file listing to pick
/// from; the browser's own entry menu calls [openLogViewer] straight.
Future<void> promptAndTailFile(
  BuildContext context, {
  required SessionController session,
  required SettingsStore settingsStore,
}) async {
  final controller = TextEditingController(text: '/var/log/');
  final path = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Tail a file'),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: 'Path on the server',
          hintText: '/var/log/syslog',
        ),
        onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.of(context).pop(controller.text.trim()),
          child: const Text('Tail'),
        ),
      ],
    ),
  );
  controller.dispose();

  if (path == null || path.isEmpty || !context.mounted) return;
  await openLogViewer(
    context,
    session: session,
    path: path,
    settingsStore: settingsStore,
  );
}

/// Pushes the viewer for [path].
Future<void> openLogViewer(
  BuildContext context, {
  required SessionController session,
  required String path,
  required SettingsStore settingsStore,
}) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (context) => LogViewerScreen(
        session: session,
        path: path,
        settingsStore: settingsStore,
      ),
    ),
  );
}
