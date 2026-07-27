import 'dart:async';

import 'package:flutter/material.dart';

import '../services/device_storage.dart';
import '../services/keep_awake.dart';
import '../services/layout_breakpoints.dart';
import '../services/session_controller.dart';
import '../services/session_foreground.dart';
import '../services/session_registry.dart';
import '../services/settings_store.dart';
import '../services/ssh_service.dart';
import '../services/transfer_queue.dart';
import '../theme.dart';
import '../widgets/transfer_panel.dart';
import 'file_browser_pane.dart';
import 'terminal_pane.dart';

/// Which view of the session is in front.
enum SessionView { terminal, files }

/// A live SSH session, presented as two views on one connection.
///
/// This screen — not the terminal — owns the [SessionController], and so owns
/// the connection's lifetime. It ends when the user disconnects or pops the
/// route; flipping between the shell and the file browser does neither, which
/// is the whole point of the Phase 3 ownership lift.
class SessionScreen extends StatefulWidget {
  // No longer `const`: the foreground-service reference count is shared by the
  // whole process, so its default is a static instance rather than something
  // that can be built at compile time. Nothing constructs this widget in a
  // const context — it is only ever pushed onto a navigator.
  SessionScreen({
    super.key,
    required this.connection,
    required this.settingsStore,
    this.initialView = SessionView.terminal,
    this.initialUploads = const [],
    KeepAwakeController? keepAwake,
    SessionForegroundController? foreground,
    SessionRegistry? registry,
  })  : keepAwake = keepAwake ?? const MethodChannelKeepAwake(),
        foreground = foreground ?? SessionForegroundController.instance,
        registry = registry ?? SessionRegistry.instance;

  final SshConnection connection;
  final SessionView initialView;
  final SettingsStore settingsStore;

  /// Files that came in from the share sheet and are waiting for a directory
  /// — set when this session was opened *by* a share. Non-empty implies the
  /// file browser, since that is where the user picks where they go.
  final List<PickedLocalFile> initialUploads;

  /// Where this session announces itself, so a later share can reuse the
  /// connection instead of authenticating a second time.
  final SessionRegistry registry;

  /// Test seam; production leaves this to the default channel-backed one.
  final KeepAwakeController keepAwake;

  /// Holds the app in the foreground for as long as this session is live, so
  /// Android does not reclaim the process while the user is in another app.
  /// Process-wide by nature, hence a singleton default rather than something
  /// threaded down from `main.dart`.
  final SessionForegroundController foreground;

  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen> {
  late final SessionController _session;
  late SessionView _view;
  StreamSubscription<void>? _sessionChanges;

  /// The file browser opens an extra SSH channel, so it is not built until the
  /// user actually asks for it.
  late bool _filesBuilt;

  /// So the disconnect snackbar fires once, right when the session actually
  /// drops, rather than on every later rebuild while [_DisconnectedBanner] is
  /// already showing.
  bool _announcedDisconnect = false;

  /// Whether this route currently owns a share of the foreground service, so
  /// the release is exactly-once however we get here — a drop noticed in
  /// `_handleSessionChange`, or an ordinary `dispose`.
  bool _holdsForeground = false;

  /// Stable identities for the two panes, so that going from the compact
  /// `IndexedStack` to the medium/expanded side-by-side `Row` (and back, on a
  /// fold or a DeX window resize) moves the *same* `TerminalPane` /
  /// `FileBrowserPane` element instead of destroying and recreating it.
  /// `TerminalPane`'s `Terminal` — scrollback, cursor, the lot — lives
  /// inside its `State`, created once in `initState`; only a `GlobalKey` lets
  /// Flutter reparent that `State` across a structural change in the same
  /// build rather than tearing it down. Without this, folding or resizing
  /// into a wide window would silently drop the running session's scrollback
  /// and open a second SFTP channel.
  final GlobalKey _terminalPaneKey = GlobalKey();
  final GlobalKey _fileBrowserPaneKey = GlobalKey();

  /// Ids of the downloads already counted, so the "saved — Open" snackbar
  /// sees each file once rather than on every later queue publication.
  final Set<String> _announcedDownloads = {};

  /// Downloads that finished but have not been announced yet, because the
  /// queue was still busy.
  final List<TransferTask> _finishedDownloads = [];

  StreamSubscription<List<TransferTask>>? _transferChanges;

  @override
  void initState() {
    super.initState();
    _session = SessionController(connection: widget.connection);
    _view = widget.initialView;
    if (widget.initialUploads.isNotEmpty) {
      _view = SessionView.files;
      _session.requestUpload(widget.initialUploads);
    }
    _filesBuilt = _view == SessionView.files;
    _sessionChanges = _session.changes.listen(_handleSessionChange);
    _transferChanges = _session.transfers.changes.listen(_handleTransfers);

    widget.registry.register(
      _session.host.id,
      LiveSession(session: _session, bringToFront: _bringToFront),
    );

    _holdsForeground = true;
    unawaited(widget.foreground.acquire(_session.host.displayName));

    if (widget.settingsStore.current.keepScreenAwake) {
      unawaited(widget.keepAwake.setEnabled(true));
    }
  }

  /// Pops whatever the share flow stacked on top of this session, so a file
  /// shared into a host that is already open lands on the session the user
  /// already had.
  bool _bringToFront() {
    if (!mounted) return false;
    final route = ModalRoute.of(context);
    if (route == null) return false;
    Navigator.of(context).popUntil((candidate) => candidate == route);
    return true;
  }

  void _handleSessionChange(void _) {
    // The transport can drop while this route is off-screen or already gone;
    // the service must still be released, so that happens before the
    // mounted-only UI work below.
    if (_session.isClosed) _releaseForeground();
    if (!mounted) return;
    setState(() {
      // A share can arrive on a session showing the terminal; the file
      // browser is where the destination gets chosen, so go there.
      if (_session.pendingUpload != null) {
        _view = SessionView.files;
        _filesBuilt = true;
      }
    });
    if (_session.isClosed && !_announcedDisconnect) {
      _announcedDisconnect = true;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_session.closeReason ?? 'Connection closed.'),
          backgroundColor: AppTheme.danger,
        ),
      );
    }
  }

  /// Announces finished downloads, with a way straight to the file.
  ///
  /// Downloads land in the shared Downloads collection, which is the right
  /// default and also completely invisible from inside this app — so the
  /// moment one finishes is the moment to offer "Open", rather than leaving
  /// the user to go and find a file manager.
  ///
  /// Announced when the queue goes quiet rather than per file: a recursive
  /// folder download finishes four hundred times, and four hundred queued
  /// snackbars would take minutes to drain past a user who has moved on.
  void _handleTransfers(List<TransferTask> tasks) {
    if (!mounted) return;

    for (final task in tasks) {
      if (task.status != TransferStatus.completed) continue;
      if (task.direction != TransferDirection.download) continue;
      if (!_announcedDownloads.add(task.id)) continue;
      _finishedDownloads.add(task);
    }
    if (_finishedDownloads.isEmpty || _session.transfers.hasActive) return;

    final batch = List<TransferTask>.of(_finishedDownloads);
    _finishedDownloads.clear();

    final single = batch.length == 1 ? batch.single : null;
    final uri = single?.destinationUri;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          single != null
              ? 'Saved ${single.destination ?? single.name}'
              : '${batch.length} files saved to Downloads',
        ),
        action: single != null && uri != null && uri.isNotEmpty
            ? SnackBarAction(
                label: 'Open',
                onPressed: () => unawaited(_openDownload(single)),
              )
            // A batch has no single file to open, so the useful action is the
            // list of what landed — every row there has its own "Open".
            : SnackBarAction(
                label: 'Show',
                onPressed: () => unawaited(
                  showTransfersSheet(
                    context,
                    _session.transfers,
                    onOpen: _session.openDownload,
                  ),
                ),
              ),
      ),
    );
  }

  Future<void> _openDownload(TransferTask task) async {
    final messenger = ScaffoldMessenger.of(context);
    final opened = await _session.openDownload(task);
    if (!opened) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('No app on this device can open that file.'),
        ),
      );
    }
  }

  /// Idempotent — the session can close *and* the route can be popped, and
  /// only one of those should decrement the count.
  void _releaseForeground() {
    if (!_holdsForeground) return;
    _holdsForeground = false;
    unawaited(widget.foreground.release());
  }

  @override
  void dispose() {
    widget.registry.unregister(_session.host.id, _session);
    _sessionChanges?.cancel();
    _transferChanges?.cancel();
    _releaseForeground();
    unawaited(widget.keepAwake.setEnabled(false));
    unawaited(_session.dispose());
    super.dispose();
  }

  void _show(SessionView view) {
    if (_view == view) return;
    // Drop the soft keyboard on the way out of the terminal, or the file list
    // opens behind it.
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _view = view;
      if (view == SessionView.files) _filesBuilt = true;
    });
  }

  Future<void> _confirmLeave() async {
    if (_session.isClosed) {
      if (mounted) Navigator.of(context).pop();
      return;
    }

    final transfers = _session.transfers.activeCount;
    final shouldClose = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Disconnect?'),
        content: Text(
          transfers > 0
              ? 'Close the session on ${_session.host.displayName}? '
                  '$transfers transfer${transfers == 1 ? '' : 's'} '
                  '${transfers == 1 ? 'is' : 'are'} still running and will be '
                  'cancelled.'
              : 'Close the session on ${_session.host.displayName}?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Stay'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Disconnect'),
          ),
        ],
      ),
    );

    if (shouldClose == true && mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final host = _session.host;
    final closed = _session.isClosed;

    // Material 3 window size classes (see `layout_breakpoints.dart`), read
    // from `MediaQuery` rather than the platform/device — a Chromebook, a
    // DeX window and an unfolded foldable are all just "wide" by width, and
    // a physical tablet in split-screen is not. Medium and expanded get the
    // same side-by-side treatment; only compact keeps the toggle.
    final wide = WindowSizeClass.forWidth(
      MediaQuery.sizeOf(context).width,
    ).isAtLeastMedium;

    // Once the layout has gone wide, the file browser pane is live and its
    // SFTP channel open; folding back to compact should not throw that away
    // and re-show the "not built yet" placeholder in the IndexedStack branch.
    // A plain field write (no `setState`) is safe here — this build is
    // already running because `MediaQuery` changed, and it only affects what
    // *this* build constructs.
    if (wide) _filesBuilt = true;

    return PopScope(
      canPop: closed,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_confirmLeave());
      },
      child: Scaffold(
        appBar: AppBar(
          titleSpacing: 0,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(host.displayName, style: const TextStyle(fontSize: 16)),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.circle,
                    size: 8,
                    color: closed ? AppTheme.danger : AppTheme.accent,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    closed ? 'disconnected' : host.target,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ],
          ),
          actions: [
            _TransferAction(
              queue: _session.transfers,
              onTap: () => showTransfersSheet(
                context,
                _session.transfers,
                onOpen: _session.openDownload,
              ),
            ),
            // Both panes are already on screen side by side in the wide
            // layout, so a toggle between them means nothing there.
            if (!wide)
              IconButton(
                tooltip: _view == SessionView.terminal
                    ? 'Browse files'
                    : 'Back to terminal',
                icon: Icon(
                  _view == SessionView.terminal
                      ? Icons.folder_outlined
                      : Icons.terminal,
                ),
                onPressed: () => _show(
                  _view == SessionView.terminal
                      ? SessionView.files
                      : SessionView.terminal,
                ),
              ),
            IconButton(
              tooltip: closed ? 'Back' : 'Disconnect',
              icon: Icon(
                closed ? Icons.arrow_back : Icons.power_settings_new,
              ),
              color: closed ? null : AppTheme.danger,
              onPressed: _confirmLeave,
            ),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: [
              if (closed) _DisconnectedBanner(message: _session.closeReason),
              Expanded(
                child: wide ? _buildWide() : _buildCompact(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _terminalPane() {
    return TerminalPane(
      key: _terminalPaneKey,
      session: _session,
      settingsStore: widget.settingsStore,
    );
  }

  Widget _fileBrowserPane() {
    return FileBrowserPane(
      key: _fileBrowserPaneKey,
      session: _session,
      initialShowHidden: widget.settingsStore.current.showHiddenFilesByDefault,
    );
  }

  /// Phones: one pane at a time behind the app-bar toggle, exactly as
  /// before Phase 8.
  Widget _buildCompact() {
    return IndexedStack(
      index: _view == SessionView.terminal ? 0 : 1,
      sizing: StackFit.expand,
      children: [
        _terminalPane(),
        if (_filesBuilt) _fileBrowserPane() else const SizedBox.shrink(),
      ],
    );
  }

  /// Tablets, DeX and unfolded foldables: both panes live at once, sharing
  /// the one `SessionController` — the file browser opening its SFTP channel
  /// here is deliberate, not lazy, since there is no "ask for it" tap in this
  /// layout for it to wait on.
  Widget _buildWide() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(flex: 3, child: _terminalPane()),
        const VerticalDivider(width: 1),
        Expanded(flex: 2, child: _fileBrowserPane()),
      ],
    );
  }
}

/// App-bar transfer button, with a count badge while anything is moving.
class _TransferAction extends StatelessWidget {
  const _TransferAction({required this.queue, required this.onTap});

  final TransferQueue queue;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TransferQueueBuilder(
      queue: queue,
      builder: (context, tasks) {
        if (tasks.isEmpty) return const SizedBox.shrink();
        final active = tasks.where((t) => t.status.isActive).length;
        final failed = tasks.any((t) => t.status == TransferStatus.failed);

        return IconButton(
          tooltip: 'Transfers',
          onPressed: onTap,
          icon: Badge(
            isLabelVisible: active > 0 || failed,
            backgroundColor: failed && active == 0 ? AppTheme.danger : null,
            label: active > 0 ? Text('$active') : null,
            child: const Icon(Icons.swap_vert),
          ),
        );
      },
    );
  }
}

class _DisconnectedBanner extends StatelessWidget {
  const _DisconnectedBanner({this.message});

  final String? message;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.danger.withValues(alpha: 0.15),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Row(
          children: [
            const Icon(Icons.link_off, color: AppTheme.danger, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message ?? 'Connection closed.',
                style: const TextStyle(fontSize: 13, height: 1.3),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Back'),
            ),
          ],
        ),
      ),
    );
  }
}
