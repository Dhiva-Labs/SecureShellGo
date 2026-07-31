import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/host.dart';
import '../models/snippet.dart';
import '../services/credential_store.dart';
import '../services/device_storage.dart';
import '../services/host_grouping.dart';
import '../services/host_store.dart';
import '../services/known_hosts_service.dart';
import '../services/layout_breakpoints.dart';
import '../services/quick_connect_parser.dart';
import '../services/session_manager.dart';
import '../services/settings_store.dart';
import '../services/share_intake.dart';
import '../services/snippet_store.dart';
import '../services/ssh_service.dart';
import '../services/terminal_workspace.dart';
import '../theme.dart';
import '../widgets/command_palette.dart';
import '../widgets/host_color_dot.dart';
import '../widgets/host_key_dialog.dart';
import '../widgets/quick_connect_bar.dart';
import '../widgets/snippet_picker.dart' show runSnippetOnSession;
import 'host_edit_screen.dart';
import 'quick_connect_screen.dart';
import 'session_screen.dart';
import 'settings_screen.dart';
import 'share_target_screen.dart';
import 'ssh_config_import_screen.dart';

/// Dropdown-free equivalent of `HostEditScreen`'s `_newGroupSentinel`: a
/// group-picker dialog value meaning "prompt for a new name" rather than a
/// real group. The leading space keeps it out of reach of `.trim()`, so it
/// can never collide with an actual group name (always trimmed — see
/// `HostStore.renameGroup`).
const String _newGroupDialogSentinel = ' new-group';

/// The app's home screen: the list of saved hosts.
///
/// Replaces the Phase 1 [ConnectScreen] entirely. Tapping a host connects
/// immediately using its saved credentials; the FAB and each host's overflow
/// menu cover add/edit/delete and forgetting trusted host keys.
///
/// Since v1.3.0 hosts also render inside collapsible group sections (see
/// `services/host_grouping.dart`), with a simple search field that filters
/// across every group and force-expands whichever ones still have a match.
class HostListScreen extends StatefulWidget {
  const HostListScreen({
    super.key,
    required this.hostStore,
    required this.credentialStore,
    required this.knownHosts,
    required this.sshService,
    required this.settingsStore,
    required this.sessions,
    this.workspace,
    this.shareIntake,
    this.snippetStore,
  });

  final HostStore hostStore;
  final CredentialStore credentialStore;
  final KnownHostsService knownHosts;
  final SshService sshService;
  final SettingsStore settingsStore;

  /// Every open session. Built in `main.dart` and passed down, because a
  /// session outlives the route showing it: leaving the sessions screen for
  /// this list is how a second one gets started.
  final SessionManager sessions;

  /// The desktop pane layout, passed straight through to [SessionsScreen].
  /// Held above this route rather than by it so that leaving the sessions
  /// screen — the very thing this list exists for — does not reset the splits.
  /// Null lets the sessions screen build a route-scoped one; mobile never
  /// reads it either way.
  final TerminalWorkspace? workspace;

  /// Where files shared from other apps arrive. The home screen owns this
  /// because it is the one route that is always on the stack — a share can
  /// land while any screen is in front, or with the app not running at all.
  /// Test seam; production builds the channel-backed default.
  final ShareIntake? shareIntake;

  /// Backs snippet management (Settings) and the lightning-bolt picker on
  /// the sessions screen, plus the command palette's snippet results.
  /// Optional, same reasoning as [shareIntake] — a single store instance is
  /// shared across every screen this one pushes so they never see a stale
  /// in-memory copy of each other's edits.
  final SnippetStore? snippetStore;

  @override
  State<HostListScreen> createState() => _HostListScreenState();
}

class _HostListScreenState extends State<HostListScreen> {
  late Future<List<Host>> _future;

  /// The host currently being connected to, so only its tile shows a
  /// loading state while the rest of the list stays interactive.
  String? _connectingHostId;

  /// Set when the known-hosts store failed its integrity check on load and
  /// was dropped. Re-prompting for every host with no explanation would look
  /// like a bug; this says what actually happened.
  bool _trustStoreReset = false;

  late final ShareIntake _shareIntake = widget.shareIntake ?? ShareIntake();
  late final SnippetStore _snippetStore = widget.snippetStore ?? SnippetStore();

  /// So a second `shareAvailable` — or a cold-start share the warm listener
  /// also hears — cannot stack two pickers for the same files.
  bool _shareTargetOpen = false;

  /// Whether the sessions screen is already on the navigator above this route,
  /// so a second connect adds a tab to it rather than stacking a second copy.
  bool _sessionsOpen = false;

  StreamSubscription<void>? _sessionChanges;

  final _searchController = TextEditingController();

  /// Trimmed live value of [_searchController]. Kept as its own field rather
  /// than re-reading the controller everywhere a rebuild needs it.
  String _query = '';

  @override
  void initState() {
    super.initState();
    _future = widget.hostStore.all();
    unawaited(_checkTrustStore());

    // The "still connected" bar has to follow sessions opening, closing and
    // dropping while this list is in front.
    _sessionChanges = widget.sessions.changes.listen((_) {
      if (mounted) setState(() {});
    });

    _shareIntake.listen(_openShareTarget);
    // The cold-start case: the app was launched *by* a share, so the payload
    // is already waiting on the platform side. Asked for after the first
    // frame, because the answer is a route push.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final files = await _shareIntake.takePending();
      if (files.isNotEmpty) _openShareTarget(files);
    });
  }

  @override
  void dispose() {
    _sessionChanges?.cancel();
    _shareIntake.stop();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _openShareTarget(List<PickedLocalFile> files) async {
    if (!mounted || files.isEmpty || _shareTargetOpen) return;
    _shareTargetOpen = true;
    try {
      final opened = await Navigator.of(context).push<bool>(
        MaterialPageRoute<bool>(
          builder: (_) => ShareTargetScreen(
            files: files,
            hostStore: widget.hostStore,
            credentialStore: widget.credentialStore,
            sshService: widget.sshService,
            settingsStore: widget.settingsStore,
            sessions: widget.sessions,
          ),
        ),
      );
      // The picker only opens (or reuses) the session; showing it is this
      // route's job, since this is the route the sessions screen sits on.
      if (opened == true && mounted) await _showSessions();
    } finally {
      _shareTargetOpen = false;
      if (mounted) _refresh();
    }
  }

  /// Brings the sessions screen up, or does nothing if it is already there.
  ///
  /// Pushed from here rather than owned here: popping it comes back to this
  /// list with every session still connected, which is what makes "open a
  /// second server" possible at all.
  Future<void> _showSessions({bool autoOpenSnippetPicker = false}) async {
    if (_sessionsOpen || widget.sessions.isEmpty) return;
    _sessionsOpen = true;
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => SessionsScreen(
            sessions: widget.sessions,
            settingsStore: widget.settingsStore,
            workspace: widget.workspace,
            // "New session" is a trip back to this list. Popping is exactly
            // that, and it keeps the sessions behind it alive.
            onAddSession: () => Navigator.of(context).pop(),
            snippetStore: _snippetStore,
            autoOpenSnippetPicker: autoOpenSnippetPicker,
          ),
        ),
      );
    } finally {
      _sessionsOpen = false;
      if (mounted) _refresh();
    }
  }

  Future<void> _checkTrustStore() async {
    await widget.knownHosts.ensureLoaded();
    if (!mounted || !widget.knownHosts.integrityFailed) return;
    setState(() => _trustStoreReset = true);
  }

  void _refresh() {
    // Deliberately a block body: with an arrow closure the assignment's value
    // (a Future) becomes the callback's return value, and setState throws
    // "callback argument returned a Future" AFTER running the callback but
    // BEFORE scheduling the rebuild — the field updates, the UI never
    // repaints. Verified live on the emulator via logcat.
    setState(() {
      _future = widget.hostStore.all();
    });
  }

  /// Same gotcha as [_refresh]: the future is created first and only then
  /// assigned inside a block-bodied `setState`, so the assignment itself
  /// never becomes the callback's return value. `RefreshIndicator` needs the
  /// `Future` back so it knows when to stop spinning.
  Future<void> _pullToRefresh() async {
    final future = widget.hostStore.all();
    setState(() {
      _future = future;
    });
    await future;
  }

  Future<void> _addHost() => _editForm();

  Future<void> _editHost(Host host) => _editForm(host: host);

  Future<void> _editForm({Host? host}) async {
    // "Connect without saving" opens a session from inside that form and pops
    // back here; comparing the count is how this route knows to show it,
    // without the form having to reach past itself to a navigator it does not
    // own.
    final before = widget.sessions.length;

    await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => HostEditScreen(
          hostStore: widget.hostStore,
          credentialStore: widget.credentialStore,
          sshService: widget.sshService,
          settingsStore: widget.settingsStore,
          sessions: widget.sessions,
          host: host,
        ),
      ),
    );
    if (!mounted) return;

    // Refresh unconditionally, the same way _connect() does: HostEditScreen
    // already persisted the host itself before popping (see
    // _HostEditScreenState._save), so the list only has to catch up with
    // disk. Gating this on the popped result is what left the list stale —
    // anything that pops the route without echoing `true` (a system back
    // gesture, a future control that calls a bare Navigator.pop()) skipped
    // the refresh even though the host was saved.
    _refresh();
    if (widget.sessions.length > before) await _showSessions();
  }

  Future<void> _connect(
    Host host, {
    SessionView view = SessionView.terminal,
  }) async {
    if (_connectingHostId != null) return;

    // A second session to the same machine is a legitimate thing to want — a
    // build in one shell and a tail in another is the ordinary case — but it
    // is never what a user means by accident, and it costs a second
    // authentication. So it is asked about rather than assumed either way.
    final existing = widget.sessions.liveForHost(host.id);
    if (existing.isNotEmpty) {
      final choice = await _askAboutExistingSession(host, existing.length);
      if (!mounted || choice == null) return;
      if (choice == _ExistingSession.switchToIt) {
        widget.sessions.select(existing.first.id);
        if (view == SessionView.files) {
          widget.sessions.showView(existing.first.id, view);
        }
        await _showSessions();
        return;
      }
    }

    setState(() => _connectingHostId = host.id);

    final credentials = await widget.credentialStore.load(host.id);
    if (!mounted) return;

    if (credentials == null) {
      setState(() => _connectingHostId = null);
      await _showConnectError(
        'No saved credentials for this host.',
        details: 'Edit the host to enter its password or key again.',
        onEdit: () => _editHost(host),
      );
      return;
    }

    try {
      final connection = await widget.sshService.connect(
        host: host,
        credentials: credentials,
        verifyHostKey: (prompt) async {
          if (!mounted) return false;
          return showHostKeyDialog(context, prompt);
        },
      );

      if (!mounted) {
        connection.close();
        return;
      }

      // The handshake (and any host-key prompt) succeeded, so this is a real
      // connection, not just an attempt — record it for "last connected" on
      // the list. Best-effort: a write failure here should not block the
      // session the user is already in.
      unawaited(
        widget.hostStore.update(host.copyWith(lastConnectedAt: DateTime.now())),
      );

      setState(() => _connectingHostId = null);
      // From here the connection belongs to the session manager, which closes
      // it when the user closes that session — not when this route, or the
      // sessions screen, goes away.
      widget.sessions.open(connection, initialView: view);
      await _showSessions();
    } on SshConnectionException catch (e) {
      if (!mounted) return;
      setState(() => _connectingHostId = null);
      await _showConnectError(e.message, details: e.details);
    } catch (e) {
      if (!mounted) return;
      setState(() => _connectingHostId = null);
      await _showConnectError(
        'Something went wrong while connecting.',
        details: e.toString(),
      );
    }
  }

  /// Asks what "connect" means when this host is already open.
  ///
  /// Null is a cancel, and cancel is the barrier-dismiss default: opening a
  /// second authenticated connection to someone's server is not something a
  /// stray tap outside a dialog should do.
  Future<_ExistingSession?> _askAboutExistingSession(Host host, int count) {
    return showDialog<_ExistingSession>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Already connected'),
        content: Text(
          count == 1
              ? 'There is already a session open on ${host.displayName}.'
              : 'There are already $count sessions open on '
                  '${host.displayName}.',
          style: const TextStyle(height: 1.35),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(context).pop(_ExistingSession.openAnother),
            child: const Text('New session'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(context).pop(_ExistingSession.switchToIt),
            child: const Text('Switch to it'),
          ),
        ],
      ),
    );
  }

  Future<void> _showConnectError(
    String message, {
    String? details,
    VoidCallback? onEdit,
  }) {
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.error_outline, color: AppTheme.danger),
        title: const Text('Could not connect'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(message, style: const TextStyle(height: 1.35)),
              if (details != null) ...[
                const SizedBox(height: 12),
                Text(
                  details,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontFamily: AppTheme.monoFontFamily,
                        fontFamilyFallback: AppTheme.monoFontFamilyFallback,
                      ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          if (onEdit != null)
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                onEdit();
              },
              child: const Text('Edit host'),
            ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  /// Puts `user@host` (or `user@host:port` for a non-standard port) on the
  /// clipboard — handy for pasting into a different terminal or a chat when
  /// telling someone else how to reach the same box.
  Future<void> _copyTarget(Host host) async {
    await Clipboard.setData(ClipboardData(text: host.target));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Copied ${host.target}')),
    );
  }

  void _showHostActions(Host host) {
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: const Text('Browse files'),
              subtitle: const Text('Connects straight into the file browser'),
              onTap: () {
                Navigator.of(context).pop();
                _connect(host, view: SessionView.files);
              },
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Edit'),
              onTap: () {
                Navigator.of(context).pop();
                _editHost(host);
              },
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_move_outline),
              title: const Text('Move to group…'),
              subtitle: Text(host.group ?? 'Ungrouped'),
              onTap: () {
                Navigator.of(context).pop();
                unawaited(_reassignGroup(host));
              },
            ),
            ListTile(
              leading: const Icon(Icons.copy_all_outlined),
              title: const Text('Copy user@host'),
              subtitle: Text(host.target),
              onTap: () {
                Navigator.of(context).pop();
                unawaited(_copyTarget(host));
              },
            ),
            ListTile(
              leading: const Icon(Icons.key_off_outlined),
              title: const Text('Forget host keys'),
              subtitle: const Text('Undoes trust-on-first-use for this server'),
              onTap: () {
                Navigator.of(context).pop();
                _forgetHostKeys(host);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: AppTheme.danger),
              title: const Text('Delete', style: TextStyle(color: AppTheme.danger)),
              onTap: () {
                Navigator.of(context).pop();
                _deleteHost(host);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// The group-picker used by the host's own "Move to group…" action. A
  /// [SimpleDialog] rather than a dropdown: this is a one-off pick, not a
  /// form field with a save button, so there is nothing to submit — picking
  /// an option closes the dialog immediately.
  Future<void> _reassignGroup(Host host) async {
    final groupNames = await widget.hostStore.groupNames();
    if (!mounted) return;

    final selected = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('Move "${host.displayName}" to'),
        children: [
          _GroupPickOption(
            label: 'Ungrouped',
            selected: host.group == null,
            // Empty string stands for Ungrouped here — distinct from `null`,
            // which showDialog already uses to mean "dismissed".
            onTap: () => Navigator.of(context).pop(''),
          ),
          for (final name in groupNames)
            _GroupPickOption(
              label: name,
              selected: host.group == name,
              onTap: () => Navigator.of(context).pop(name),
            ),
          _GroupPickOption(
            label: 'New group…',
            selected: false,
            onTap: () => Navigator.of(context).pop(_newGroupDialogSentinel),
          ),
        ],
      ),
    );
    if (selected == null || !mounted) return;

    String? newGroup;
    if (selected == _newGroupDialogSentinel) {
      final created = await _promptGroupName(title: 'New group');
      if (created == null || !mounted) return;
      newGroup = created;
    } else if (selected.isEmpty) {
      newGroup = null;
    } else {
      newGroup = selected;
    }

    if (newGroup == host.group) return;
    await widget.hostStore.update(host.withGroup(newGroup));
    if (!mounted) return;
    _refresh();
  }

  /// Backs both "New group…" (blank [initialName]) and the group header's
  /// "Rename group" (pre-filled). Returns the trimmed name, or null if the
  /// dialog was cancelled or the input was left blank.
  Future<String?> _promptGroupName({
    required String title,
    String initialName = '',
  }) {
    final controller = TextEditingController(text: initialName);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Group name'),
          onSubmitted: (value) {
            final trimmed = value.trim();
            if (trimmed.isNotEmpty) Navigator.of(context).pop(trimmed);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final trimmed = controller.text.trim();
              if (trimmed.isNotEmpty) Navigator.of(context).pop(trimmed);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    ).whenComplete(controller.dispose);
  }

  Future<void> _renameGroup(String name) async {
    final newName = await _promptGroupName(
      title: 'Rename group',
      initialName: name,
    );
    if (newName == null || newName == name || !mounted) return;

    await widget.hostStore.renameGroup(name, newName);
    // Carries the collapsed/expanded state over to the renamed key — without
    // this a rename would silently pop a collapsed section back open, since
    // the new name would not be in the persisted set.
    await _moveCollapsedKey(from: name, to: newName);
    if (!mounted) return;
    _refresh();
  }

  Future<void> _deleteGroup(String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete group?'),
        content: Text(
          'Removes "$name". Its hosts move to Ungrouped — nothing is '
          'deleted.',
          style: const TextStyle(height: 1.35),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await widget.hostStore.deleteGroup(name);
    await _forgetCollapsedKey(name);
    if (!mounted) return;
    _refresh();
  }

  Future<void> _toggleSection(HostSection section) async {
    final key = section.settingsKey;
    final current = widget.settingsStore.current.collapsedGroups;
    final next = {...current};
    if (!next.remove(key)) next.add(key);
    await widget.settingsStore.update((s) => s.copyWith(collapsedGroups: next));
    if (mounted) setState(() {});
  }

  Future<void> _moveCollapsedKey({
    required String from,
    required String to,
  }) async {
    final current = widget.settingsStore.current.collapsedGroups;
    if (!current.contains(from)) return;
    final next = {...current}
      ..remove(from)
      ..add(to);
    await widget.settingsStore.update((s) => s.copyWith(collapsedGroups: next));
  }

  Future<void> _forgetCollapsedKey(String key) async {
    final current = widget.settingsStore.current.collapsedGroups;
    if (!current.contains(key)) return;
    final next = {...current}..remove(key);
    await widget.settingsStore.update((s) => s.copyWith(collapsedGroups: next));
  }

  Future<void> _forgetHostKeys(Host host) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Forget host keys?'),
        content: Text(
          'The next connection to ${host.hostname}:${host.port} will be '
          'treated as first-use again and ask you to verify its key.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Forget'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    await widget.knownHosts.forgetHost(host.hostname, host.port);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Forgot host keys for ${host.displayName}')),
    );
  }

  Future<void> _deleteHost(Host host) async {
    var forgetKeys = false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Delete host?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'This removes "${host.displayName}" and its saved password '
                'or key. This cannot be undone.',
                style: const TextStyle(height: 1.35),
              ),
              CheckboxListTile(
                value: forgetKeys,
                onChanged: (value) =>
                    setDialogState(() => forgetKeys = value ?? false),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text(
                  'Also forget its trusted host key(s)',
                  style: TextStyle(fontSize: 13),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Delete'),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true) return;

    await widget.hostStore.delete(host.id);
    await widget.credentialStore.delete(host.id);
    if (forgetKeys) {
      await widget.knownHosts.forgetHost(host.hostname, host.port);
    }
    if (!mounted) return;
    _refresh();
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SettingsScreen(
          settingsStore: widget.settingsStore,
          knownHosts: widget.knownHosts,
          snippetStore: _snippetStore,
        ),
      ),
    );
  }

  /// Desktop platforms — where `~/.ssh/config` and Ctrl+K both make sense.
  /// Same check `file_browser_pane.dart` uses for its own desktop-only
  /// affordances.
  static bool _isDesktop(BuildContext context) {
    switch (Theme.of(context).platform) {
      case TargetPlatform.linux:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
        return true;
      case TargetPlatform.android:
      case TargetPlatform.iOS:
      case TargetPlatform.fuchsia:
        return false;
    }
  }

  /// FEATURE 2: parses to a target already, so this only has to prompt for
  /// credentials and connect — see `quick_connect_screen.dart`. Mirrors
  /// `_editForm`'s "did a session open while that screen was up" check,
  /// since a quick connection also has no result value worth trusting on its
  /// own (a plain back gesture pops with nothing either).
  Future<void> _quickConnect(QuickConnectTarget target) async {
    final before = widget.sessions.length;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => QuickConnectScreen(
          target: target,
          sshService: widget.sshService,
          sessions: widget.sessions,
          hostStore: widget.hostStore,
          credentialStore: widget.credentialStore,
        ),
      ),
    );
    if (!mounted) return;
    if (widget.sessions.length > before) await _showSessions();
  }

  /// FEATURE 3: the overflow menu's "Import from ~/.ssh/config".
  Future<void> _importSshConfig() async {
    final imported = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => SshConfigImportScreen(hostStore: widget.hostStore),
      ),
    );
    if (!mounted) return;
    if (imported == true) _refresh();
  }

  /// FEATURE 4: Ctrl+K / Cmd+K. Builds the full result set fresh each time
  /// rather than caching it — hosts and snippets can change between two
  /// palette opens, and neither list is ever long enough for that to cost
  /// anything.
  Future<void> _openCommandPalette() async {
    final hosts = await _future;
    final snippets = await _snippetStore.all();
    if (!mounted) return;

    final active = widget.sessions.active;
    final sessionActive = active != null && !active.isClosed;
    final desktop = _isDesktop(context);

    final items = <PaletteItem>[
      for (final host in hosts)
        PaletteItem(
          kind: PaletteItemKind.host,
          title: host.displayName,
          subtitle: host.target,
          onSelect: () => unawaited(_connect(host)),
        ),
      for (final snippet in snippets)
        PaletteItem(
          kind: PaletteItemKind.snippet,
          title: snippet.name,
          subtitle: snippet.command,
          enabled: sessionActive,
          hint: sessionActive ? null : 'Open a session first',
          onSelect: () => _runSnippetFromPalette(snippet),
        ),
      PaletteItem(
        kind: PaletteItemKind.action,
        title: 'New host',
        onSelect: () => unawaited(_addHost()),
      ),
      if (desktop)
        PaletteItem(
          kind: PaletteItemKind.action,
          title: 'Import from ssh config',
          onSelect: () => unawaited(_importSshConfig()),
        ),
      PaletteItem(
        kind: PaletteItemKind.action,
        title: 'Settings',
        onSelect: _openSettings,
      ),
    ];

    if (!mounted) return;
    unawaited(showCommandPalette(context, items: items));
  }

  /// A snippet chosen straight from the palette skips its own list UI (the
  /// palette already was that search-and-pick step) and fires directly at
  /// the active session, the same way `showSnippetPicker`'s list does.
  void _runSnippetFromPalette(Snippet snippet) {
    final active = widget.sessions.active;
    if (active == null || active.isClosed) return;
    unawaited(_showSessions());
    unawaited(
      runSnippetOnSession(context, snippet: snippet, session: active.controller),
    );
  }

  @override
  Widget build(BuildContext context) {
    final desktop = _isDesktop(context);

    // Ctrl+K / Cmd+K (FEATURE 4), wired locally rather than in `main.dart` —
    // `Focus(autofocus: true)` gives the shortcut something focused to
    // bubble up from as soon as this screen appears, before the user has
    // clicked anything.
    return Shortcuts(
      shortcuts: <LogicalKeySet, Intent>{
        LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyK):
            const _OpenPaletteIntent(),
        LogicalKeySet(LogicalKeyboardKey.meta, LogicalKeyboardKey.keyK):
            const _OpenPaletteIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _OpenPaletteIntent: CallbackAction<_OpenPaletteIntent>(
            onInvoke: (intent) {
              unawaited(_openCommandPalette());
              return null;
            },
          ),
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            appBar: AppBar(
              title: const Text('SecureShell Go'),
              actions: [
                if (desktop)
                  PopupMenuButton<_HostListMenuAction>(
                    tooltip: 'More',
                    onSelected: (action) {
                      switch (action) {
                        case _HostListMenuAction.importSshConfig:
                          unawaited(_importSshConfig());
                      }
                    },
                    itemBuilder: (context) => const [
                      PopupMenuItem(
                        value: _HostListMenuAction.importSshConfig,
                        child: Text('Import from ~/.ssh/config'),
                      ),
                    ],
                  ),
                IconButton(
                  tooltip: 'Settings',
                  icon: const Icon(Icons.settings_outlined),
                  onPressed: _openSettings,
                ),
              ],
            ),
            body: SafeArea(
              child: Column(
                children: [
                  if (_trustStoreReset)
                    _TrustStoreResetBanner(
                      onDismiss: () => setState(() => _trustStoreReset = false),
                    ),
                  // Leaving the sessions screen keeps the connections up,
                  // which is what makes opening a second server possible —
                  // and would be an invisible state if this bar did not say
                  // so.
                  if (widget.sessions.isNotEmpty)
                    _OpenSessionsBar(
                      total: widget.sessions.length,
                      live: widget.sessions.liveCount,
                      onResume: () => unawaited(_showSessions()),
                    ),
                  QuickConnectBar(
                    onTarget: (target) => unawaited(_quickConnect(target)),
                  ),
                  _buildSearchField(),
                  Expanded(child: _buildHostList()),
                ],
              ),
            ),
            floatingActionButton: FloatingActionButton(
              onPressed: _addHost,
              tooltip: 'Add host',
              child: const Icon(Icons.add),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSearchField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: TextField(
        controller: _searchController,
        decoration: InputDecoration(
          isDense: true,
          hintText: 'Search hosts',
          prefixIcon: const Icon(Icons.search, size: 20),
          suffixIcon: _query.isEmpty
              ? null
              : IconButton(
                  tooltip: 'Clear',
                  icon: const Icon(Icons.clear, size: 18),
                  onPressed: () {
                    _searchController.clear();
                    setState(() => _query = '');
                  },
                ),
        ),
        onChanged: (value) => setState(() => _query = value),
      ),
    );
  }

  Widget _buildHostList() {
    // Only the widest class gets the grid — a phone in split-screen or a
    // narrow tablet window (medium) still reads better as a single column.
    final width = MediaQuery.sizeOf(context).width;
    final expandedLayout =
        WindowSizeClass.forWidth(width) == WindowSizeClass.expanded;

    return FutureBuilder<List<Host>>(
      future: _future,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final hosts = snapshot.data!;
        final sections = HostGrouping.buildSections(hosts, query: _query);

        // A CustomScrollView with AlwaysScrollableScrollPhysics — rather than
        // gating RefreshIndicator's child on hosts.isEmpty — is what lets
        // pull-to-refresh work even from the empty-state illustration, the
        // same trick file_browser_pane.dart uses for its own empty directory.
        return RefreshIndicator(
          onRefresh: _pullToRefresh,
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              if (hosts.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: _EmptyHostList(onAddHost: _addHost),
                )
              else if (sections.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: _NoSearchResults(query: _query.trim()),
                )
              else
                for (final section in sections)
                  _buildSection(section, expandedLayout: expandedLayout),
            ],
          ),
        );
      },
    );
  }

  /// One group section: its header, and (unless collapsed) its hosts as
  /// either the compact/medium list or the expanded grid. Grouped into a
  /// single [SliverMainAxisGroup] so the pair can carry one bottom margin
  /// without a separate sliver-padding entry per section leaking into the
  /// flat `slivers` list `CustomScrollView` wants.
  Widget _buildSection(HostSection section, {required bool expandedLayout}) {
    // While searching, every section still on screen already matched the
    // query — auto-expanding it is what surfaces the hit without the user
    // having to also go find and tap its (possibly collapsed) header.
    final searching = _query.trim().isNotEmpty;
    final collapsed = !searching &&
        widget.settingsStore.current.collapsedGroups
            .contains(section.settingsKey);

    return SliverPadding(
      padding: const EdgeInsets.only(bottom: 6),
      sliver: SliverMainAxisGroup(
        slivers: [
          SliverToBoxAdapter(
            child: _GroupHeader(
              section: section,
              collapsed: collapsed,
              onToggle: searching ? null : () => _toggleSection(section),
              onRename: section.isUngrouped
                  ? null
                  : () => _renameGroup(section.group!),
              onDelete: section.isUngrouped
                  ? null
                  : () => _deleteGroup(section.group!),
            ),
          ),
          if (!collapsed)
            if (expandedLayout)
              _buildGridSliver(section.hosts)
            else
              _buildListSliver(section.hosts),
        ],
      ),
    );
  }

  /// Compact and medium: the plain one-column list, unchanged in shape from
  /// before Phase 8 — now built per section instead of once for every host.
  Widget _buildListSliver(List<Host> hosts) {
    return SliverList.separated(
      itemCount: hosts.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final host = hosts[index];
        final connecting = _connectingHostId == host.id;
        // ListTile has no onSecondaryTap of its own, so wrap it: on desktop
        // right-click opens the same action sheet long-press opens on touch
        // devices. Behind the tile so the ink and hover effects still come
        // from the tile itself, not a bare GestureDetector — same pattern as
        // file_browser_pane.dart's _EntryTile.
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onSecondaryTap: connecting ? null : () => _showHostActions(host),
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 10,
            ),
            leading: _hostAvatar(host, radius: 22),
            title: Text(
              host.displayName,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 2),
                Text(host.target),
                if (host.lastConnectedAt != null)
                  Text(
                    'Last connected '
                    '${_formatLastConnected(host.lastConnectedAt!)}',
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
            trailing: connecting
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : IconButton(
                    tooltip: 'More',
                    icon: const Icon(Icons.more_vert),
                    onPressed: () => _showHostActions(host),
                  ),
            onTap: connecting ? null : () => _connect(host),
            onLongPress: connecting ? null : () => _showHostActions(host),
          ),
        );
      },
    );
  }

  /// Expanded: a 2-column grid of host cards, same actions as the list —
  /// tap to connect, "more" for the same bottom sheet, long-press (or
  /// right-click on desktop) as a shortcut to it. A wide window has room to
  /// show more hosts at once without the list stretching into an
  /// uncomfortably long single line per row.
  Widget _buildGridSliver(List<Host> hosts) {
    return SliverPadding(
      padding: const EdgeInsets.all(12),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          mainAxisExtent: 104,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final host = hosts[index];
            return _HostCard(
              host: host,
              connecting: _connectingHostId == host.id,
              onTap: () => _connect(host),
              onMore: () => _showHostActions(host),
            );
          },
          childCount: hosts.length,
        ),
      ),
    );
  }
}

/// One tappable row in the "Move to group…" dialog.
class _GroupPickOption extends StatelessWidget {
  const _GroupPickOption({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SimpleDialogOption(
      onPressed: onTap,
      child: Row(
        children: [
          SizedBox(
            width: 24,
            child: selected
                ? const Icon(Icons.check, size: 18, color: AppTheme.accent)
                : null,
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(label)),
        ],
      ),
    );
  }
}

/// The header row of one collapsible group section: chevron, name, host
/// count, and — for a named group, never for Ungrouped — the overflow menu
/// that renames or deletes it.
class _GroupHeader extends StatelessWidget {
  const _GroupHeader({
    required this.section,
    required this.collapsed,
    required this.onToggle,
    this.onRename,
    this.onDelete,
  });

  final HostSection section;
  final bool collapsed;
  final VoidCallback? onToggle;
  final VoidCallback? onRename;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = section.group ?? 'Ungrouped';
    final count = section.hosts.length;

    return Material(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
      child: InkWell(
        onTap: onToggle,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 4, 8),
          child: Row(
            children: [
              Icon(
                collapsed ? Icons.chevron_right : Icons.expand_more,
                size: 20,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              Text(
                '$count',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              if (onRename != null || onDelete != null)
                PopupMenuButton<_GroupMenuAction>(
                  tooltip: 'Group actions',
                  icon: const Icon(Icons.more_vert, size: 20),
                  onSelected: (action) => switch (action) {
                    _GroupMenuAction.rename => onRename?.call(),
                    _GroupMenuAction.delete => onDelete?.call(),
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(
                      value: _GroupMenuAction.rename,
                      child: Text('Rename group'),
                    ),
                    PopupMenuItem(
                      value: _GroupMenuAction.delete,
                      child: Text('Delete group'),
                    ),
                  ],
                )
              else
                // Keeps the count aligned across sections regardless of
                // whether this one has an overflow menu.
                const SizedBox(width: 48),
            ],
          ),
        ),
      ),
    );
  }
}

enum _GroupMenuAction { rename, delete }

/// One host, as a card in the expanded grid — the same information and
/// actions as a list row, laid out for a fixed-size grid cell instead of a
/// full-width tile.
class _HostCard extends StatelessWidget {
  const _HostCard({
    required this.host,
    required this.connecting,
    required this.onTap,
    required this.onMore,
  });

  final Host host;
  final bool connecting;
  final VoidCallback onTap;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Same desktop right-click affordance as the list tile — see
    // _buildListSliver — wrapped around the Card rather than the InkWell so
    // the card's own ink and hover effects are untouched.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onSecondaryTap: connecting ? null : onMore,
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: connecting ? null : onTap,
          onLongPress: connecting ? null : onMore,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _hostAvatar(host, radius: 18),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        host.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        host.target,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                      if (host.lastConnectedAt != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            _formatLastConnected(host.lastConnectedAt!),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                connecting
                    ? const Padding(
                        padding: EdgeInsets.all(8),
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : IconButton(
                        tooltip: 'More',
                        icon: const Icon(Icons.more_vert, size: 20),
                        onPressed: onMore,
                        visualDensity: VisualDensity.compact,
                      ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// What "connect" should mean when the host is already open.
enum _ExistingSession { switchToIt, openAnother }

/// The overflow menu's one entry today (FEATURE 3). An enum rather than a
/// bare callback so `PopupMenuButton`'s `onSelected` stays a plain switch —
/// the shape every other `PopupMenuButton` in Flutter code tends to take.
enum _HostListMenuAction { importSshConfig }

/// Ctrl+K / Cmd+K — see the `Shortcuts`/`Actions` pair in `build()`.
class _OpenPaletteIntent extends Intent {
  const _OpenPaletteIntent();
}

/// The way back to sessions that are still connected behind this list.
class _OpenSessionsBar extends StatelessWidget {
  const _OpenSessionsBar({
    required this.total,
    required this.live,
    required this.onResume,
  });

  final int total;
  final int live;
  final VoidCallback onResume;

  @override
  Widget build(BuildContext context) {
    // A tab whose transport has dropped is still a tab, and saying "2
    // connected" when one of them is dead would be the sort of small lie that
    // costs a user a command.
    final dropped = total - live;
    final label = live == 0
        ? '$total session${total == 1 ? '' : 's'} · disconnected'
        : '$live session${live == 1 ? '' : 's'} connected'
            '${dropped > 0 ? ' · $dropped dropped' : ''}';

    return Material(
      color: AppTheme.accent.withValues(alpha: 0.12),
      child: InkWell(
        onTap: onResume,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
          child: Row(
            children: [
              Icon(
                Icons.terminal,
                size: 18,
                color: live == 0 ? AppTheme.danger : AppTheme.accent,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              TextButton(onPressed: onResume, child: const Text('Resume')),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shown when known_hosts.json failed its HMAC check and was dropped.
class _TrustStoreResetBanner extends StatelessWidget {
  const _TrustStoreResetBanner({required this.onDismiss});

  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.danger.withValues(alpha: 0.15),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.gpp_maybe, color: AppTheme.danger, size: 20),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                'The trusted host-key store failed its integrity check and '
                'was reset. Every server will ask you to verify its key '
                'again — compare each fingerprint against the server itself.',
                style: TextStyle(fontSize: 12.5, height: 1.35),
              ),
            ),
            IconButton(
              tooltip: 'Dismiss',
              icon: const Icon(Icons.close, size: 18),
              onPressed: onDismiss,
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyHostList extends StatelessWidget {
  const _EmptyHostList({required this.onAddHost});

  final VoidCallback onAddHost;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.dns_outlined,
              size: 72,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
            ),
            const SizedBox(height: 20),
            Text('No saved hosts yet', style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              'Add a server to connect to it in one tap next time. '
              'Passwords and keys are stored encrypted on this device.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onAddHost,
              icon: const Icon(Icons.add),
              label: const Text('Add host'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown instead of [_EmptyHostList] when there are saved hosts but none of
/// them match the search field.
class _NoSearchResults extends StatelessWidget {
  const _NoSearchResults({required this.query});

  final String query;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.search_off,
              size: 56,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
            ),
            const SizedBox(height: 16),
            Text('No hosts match "$query"', style: theme.textTheme.titleMedium),
          ],
        ),
      ),
    );
  }
}

/// The leading avatar for a host tile or card: the auth-method icon, plus a
/// small badge in the corner for [Host.colorLabel] when it has one. A
/// top-level function (not a method on either call site) since both
/// `_buildListSliver`'s `ListTile.leading` and `_HostCard` need the exact
/// same thing.
Widget _hostAvatar(Host host, {required double radius}) {
  final avatar = CircleAvatar(
    radius: radius,
    backgroundColor: AppTheme.surface,
    child: Icon(
      host.authMethod == SshAuthMethod.password ? Icons.password : Icons.key,
      size: radius,
    ),
  );

  if (host.colorLabel == null) return avatar;

  return Stack(
    clipBehavior: Clip.none,
    children: [
      avatar,
      Positioned(
        right: -1,
        bottom: -1,
        // The backdrop is what keeps the badge legible against an avatar
        // background close to it in hue — without it a red tag on top of
        // the (also warm) default avatar background nearly disappears.
        child: Container(
          padding: const EdgeInsets.all(2),
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: AppTheme.terminalBackground,
          ),
          child: HostColorDot(colorLabel: host.colorLabel, size: radius * 0.64),
        ),
      ),
    ],
  );
}

/// `today at 14:32`, `26 Jul at 14:32` this year, `26 Jul 2024` before that —
/// the same progressive-detail rule the file browser's timestamps use.
String _formatLastConnected(DateTime time) {
  final local = time.toLocal();
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final now = DateTime.now();
  final hh = local.hour.toString().padLeft(2, '0');
  final mm = local.minute.toString().padLeft(2, '0');

  if (local.year == now.year && local.month == now.month && local.day == now.day) {
    return 'today at $hh:$mm';
  }
  if (local.year == now.year) {
    return '${local.day} ${months[local.month - 1]} at $hh:$mm';
  }
  return '${local.day} ${months[local.month - 1]} ${local.year}';
}
