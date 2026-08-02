import 'dart:async';

import 'package:flutter/material.dart';

import '../models/host.dart';
import '../services/credential_store.dart';
import '../services/device_storage.dart';
import '../services/fleet_push_run_registry.dart';
import '../services/fleet_push_service.dart';
import '../services/remote_path.dart';
import '../services/session_manager.dart';
import '../services/sftp_service.dart';
import '../services/ssh_service.dart';
import '../services/transfer_queue.dart';

/// Picks files, a destination and a collision policy, confirms the exact
/// hosts, then runs and shows the fan-out — reached from the host list's
/// selection-mode app bar (see `host_list_screen.dart`'s "Push file…"
/// action).
///
/// The three steps are one route rather than three, because there is
/// nowhere else for "back" to usefully go from the confirm step, and the
/// running step needs everything the first two collected anyway.
class FleetPushScreen extends StatefulWidget {
  const FleetPushScreen({
    super.key,
    required this.hosts,
    required this.sessions,
    required this.credentialStore,
    required this.sshService,
    this.deviceStorage,
    this.registry,
  });

  /// Fixed for the life of this route — per-host targeting is out of scope,
  /// this is the whole point of a fan-out.
  final List<Host> hosts;

  final SessionManager sessions;
  final CredentialStore credentialStore;
  final SshService sshService;

  /// Test seam; production picks the platform default.
  final DeviceStorage? deviceStorage;

  /// Where the running push is registered so the transfer panel can find its
  /// way back to it after this route is left — see
  /// `widgets/transfer_hub_panel.dart`. Null (tests, and any build without
  /// it wired in) simply means there is no way back once this route is
  /// popped; the push still runs to completion regardless.
  final FleetPushRunRegistry? registry;

  @override
  State<FleetPushScreen> createState() => _FleetPushScreenState();
}

enum _Step { setup, confirm, running }

class _FleetPushScreenState extends State<FleetPushScreen> {
  late final DeviceStorage _storage =
      widget.deviceStorage ?? createDefaultDeviceStorage();

  var _step = _Step.setup;
  final List<PickedLocalFile> _files = [];
  final _destinationController = TextEditingController(text: '~');
  var _policy = FleetOverwritePolicy.overwrite;
  String? _pickError;

  FleetPushService? _service;

  @override
  void dispose() {
    _destinationController.dispose();
    // Deliberately not `_service?.cancel()`: leaving this screen must not
    // stop a push that is still running. Disposal of the service itself is
    // the registry's job once one is registered (see `_startPush`) — the
    // whole point of "reachable again" is that this route going away must
    // not kill the stream a later screen wants to watch. Without a registry
    // (a test, or a build with none wired in) there is nobody else to take
    // it, so it is closed here instead of leaking it.
    if (widget.registry == null) _service?.dispose();
    super.dispose();
  }

  Future<void> _pickFiles() async {
    setState(() => _pickError = null);
    try {
      final picked = await _storage.pickFiles();
      if (!mounted || picked.isEmpty) return;
      setState(() => _files.addAll(picked));
    } on DeviceStorageException catch (e) {
      if (!mounted) return;
      setState(() => _pickError = e.message);
    }
  }

  void _removeFile(PickedLocalFile file) => setState(() => _files.remove(file));

  bool get _canContinue =>
      _files.isNotEmpty && _destinationController.text.trim().isNotEmpty;

  void _goToConfirm() {
    if (!_canContinue) return;
    setState(() => _step = _Step.confirm);
  }

  void _startPush() {
    final request = FleetPushRequest(
      hosts: widget.hosts,
      files: [
        for (final f in _files)
          FleetLocalFile(path: f.path, name: f.name, size: f.size),
      ],
      destinationDirectory: _destinationController.text.trim(),
      overwritePolicy: _policy,
    );
    final service = FleetPushService(
      request: request,
      openSessionLookup: _openSessionFor,
      credentialLookup: widget.credentialStore.load,
      dialer: _dial,
    );
    _service = service;
    widget.registry?.register(service);
    setState(() => _step = _Step.running);
    service.start();
  }

  /// The live session for [hostId], if there is more than one open on it —
  /// legitimate, see `SessionManager.liveForHost` — the first one, same
  /// order the host list's "already connected" dialog offers them in.
  FleetOpenSession? _openSessionFor(String hostId) {
    final live = widget.sessions.liveForHost(hostId);
    if (live.isEmpty) return null;
    return _ManagedSessionUpload(live.first);
  }

  Future<FleetDialedConnection> _dial(
    Host host,
    SshCredentials credentials,
  ) async {
    final connection = await widget.sshService.connect(
      host: host,
      credentials: credentials,
      // A fan-out never pauses for a per-host modal: an unknown or changed
      // host key fails just that host instead of blocking every other one
      // behind a dialog nobody is watching. A new key is only ever trusted
      // through an ordinary, one-at-a-time connect from the host list.
      verifyHostKey: (_) async => false,
    );
    final client = await connection.openSftp();
    return FleetDialedConnection(
      sftp: SftpService(client),
      close: connection.close,
    );
  }

  @override
  Widget build(BuildContext context) {
    return switch (_step) {
      _Step.setup => _buildSetup(context),
      _Step.confirm => _buildConfirm(context),
      _Step.running => _buildRunning(context),
    };
  }

  Widget _buildSetup(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Push file…')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            Text(
              'Pushing to ${widget.hosts.length} '
              'host${widget.hosts.length == 1 ? '' : 's'}',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              widget.hosts.map((h) => h.displayName).join(', '),
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            OutlinedButton.icon(
              onPressed: _pickFiles,
              icon: const Icon(Icons.attach_file),
              label: Text(_files.isEmpty ? 'Choose files…' : 'Add more files…'),
            ),
            if (_pickError != null) ...[
              const SizedBox(height: 8),
              Text(
                _pickError!,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ],
            if (_files.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('No files chosen yet.'),
              )
            else
              for (final file in _files)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.insert_drive_file_outlined),
                  title: Text(
                    file.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(RemotePath.formatBytes(file.size)),
                  trailing: IconButton(
                    tooltip: 'Remove',
                    icon: const Icon(Icons.close),
                    onPressed: () => _removeFile(file),
                  ),
                ),
            const SizedBox(height: 20),
            Text('Destination directory', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            TextField(
              controller: _destinationController,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: '~',
                helperText:
                    'The same path on every selected host. "~" resolves to '
                    'each host\'s own home directory.',
                helperMaxLines: 2,
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 20),
            Text('If a file already exists', style: theme.textTheme.titleSmall),
            RadioGroup<FleetOverwritePolicy>(
              groupValue: _policy,
              onChanged: (value) {
                if (value != null) setState(() => _policy = value);
              },
              child: Column(
                children: [
                  for (final policy in FleetOverwritePolicy.values)
                    RadioListTile<FleetOverwritePolicy>(
                      value: policy,
                      title: Text(policy.label),
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _canContinue ? _goToConfirm : null,
              child: const Text('Next'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConfirm(BuildContext context) {
    final theme = Theme.of(context);
    final destination = _destinationController.text.trim();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Confirm push'),
        leading: IconButton(
          tooltip: 'Back',
          icon: const Icon(Icons.arrow_back),
          onPressed: () => setState(() => _step = _Step.setup),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            Text(
              'Push ${_files.length} file${_files.length == 1 ? '' : 's'} to '
              '${widget.hosts.length} '
              'host${widget.hosts.length == 1 ? '' : 's'} at "$destination"?',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 20),
            Text('Files', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            for (final file in _files) Text('•  ${file.name}'),
            const SizedBox(height: 20),
            Text('Hosts', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            for (final host in widget.hosts) Text('•  ${host.displayName}'),
            const SizedBox(height: 20),
            Text(
              'If a file already exists: ${_policy.label}',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 28),
            Row(
              children: [
                OutlinedButton(
                  onPressed: () => setState(() => _step = _Step.setup),
                  child: const Text('Back'),
                ),
                const SizedBox(width: 12),
                FilledButton(onPressed: _startPush, child: const Text('Push')),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // The running step is a thin, self-contained screen of its own — see
  // [FleetPushResultsScreen] — precisely so it can also be reopened straight
  // from the transfer panel while a push someone navigated away from is
  // still going. This route holds onto it too, rather than pushing a second
  // one, so "back" from here behaves exactly as it always has.
  Widget _buildRunning(BuildContext context) =>
      FleetPushResultsScreen(service: _service!, registry: widget.registry);
}

/// Adapts one already-open [ManagedSession] to what [FleetPushService] needs:
/// its SFTP channel, and a way to queue an upload on that session's own
/// `TransferQueue` — the same queue an ordinary upload from the file browser
/// uses, so a fleet push takes its turn behind whatever else that session is
/// transferring and shows up on the same transfer panel.
class _ManagedSessionUpload implements FleetOpenSession {
  _ManagedSessionUpload(this._session);

  final ManagedSession _session;

  @override
  Future<RemoteFileSystem> sftp() => _session.controller.sftp();

  @override
  FleetQueuedUpload queueUpload({
    required FleetLocalFile file,
    required String remotePath,
    required String displayName,
    required void Function(int bytes) onProgress,
  }) {
    final queue = _session.controller.transfers;
    // The lower-level queue call, not `SessionController.queueUpload`: that
    // helper ties the panel's display name to the remote path, and this
    // needs them independent — [remotePath] is always a temporary name
    // `FleetPushService` chose, while [displayName] is the real file name
    // the panel should show while it is in flight.
    final task = queue.enqueueUpload(
      localPath: file.path,
      remotePath: remotePath,
      name: displayName,
      totalBytes: file.size,
    );

    final completer = Completer<void>();
    late final StreamSubscription<List<TransferTask>> subscription;
    subscription = queue.changes.listen((tasks) {
      TransferTask? current;
      for (final candidate in tasks) {
        if (candidate.id == task.id) {
          current = candidate;
          break;
        }
      }
      if (current == null || completer.isCompleted) return;
      onProgress(current.transferredBytes);
      if (!current.status.isFinished) return;

      switch (current.status) {
        case TransferStatus.completed:
          completer.complete();
        case TransferStatus.failed:
          completer.completeError(
            SftpFailure(current.error ?? 'The upload failed.'),
          );
        case TransferStatus.cancelled:
          completer.completeError(const SftpFailure('Cancelled.'));
        case TransferStatus.queued:
        case TransferStatus.running:
          break;
      }
      unawaited(subscription.cancel());
    });

    return FleetQueuedUpload(
      done: completer.future,
      cancel: () => queue.cancel(task.id),
    );
  }
}

/// The live (or just-finished) view of one fan-out push: every host with its
/// state and progress, a per-host error line, retry-failed-only, and a final
/// summary once it stops running.
///
/// Reachable two ways: as the last step of [FleetPushScreen], and pushed on
/// its own straight from the transfer panel's banner (see
/// `widgets/transfer_hub_panel.dart`) for a push whose setup screen has
/// already been left — this is why it takes only a [FleetPushService], never
/// anything [FleetPushScreen] collected to build one.
class FleetPushResultsScreen extends StatefulWidget {
  const FleetPushResultsScreen({super.key, required this.service, this.registry});

  final FleetPushService service;

  /// Cleared (see [FleetPushRunRegistry.clear]) when this screen's own
  /// "Done" is pressed — the acknowledgement that lets the transfer panel's
  /// banner stop pointing here. Null hides that button; a push reached
  /// through [FleetPushScreen] itself has nothing to acknowledge, since
  /// leaving via the ordinary back button already does the equivalent.
  final FleetPushRunRegistry? registry;

  @override
  State<FleetPushResultsScreen> createState() =>
      _FleetPushResultsScreenState();
}

class _FleetPushResultsScreenState extends State<FleetPushResultsScreen> {
  late List<FleetHostProgress> _hostProgress = widget.service.hosts;
  StreamSubscription<List<FleetHostProgress>>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.service.changes.listen((hosts) {
      if (!mounted) return;
      setState(() => _hostProgress = hosts);
    });
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final service = widget.service;
    final running = service.isRunning;
    final anyFailed =
        _hostProgress.any((h) => h.status == FleetHostStatus.failed);
    final registry = widget.registry;

    return Scaffold(
      appBar: AppBar(
        title: Text(running ? 'Pushing…' : service.summary),
        actions: [
          if (running)
            TextButton(onPressed: service.cancel, child: const Text('Cancel'))
          else if (anyFailed)
            TextButton(
              onPressed: service.retryFailedHosts,
              child: const Text('Retry failed'),
            )
          else if (registry != null)
            TextButton(
              onPressed: () {
                registry.clear(service);
                Navigator.of(context).maybePop();
              },
              child: const Text('Done'),
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (!running)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Text(
                  service.summary,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            Expanded(
              child: ListView.separated(
                itemCount: _hostProgress.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) =>
                    _HostProgressTile(host: _hostProgress[index]),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HostProgressTile extends StatelessWidget {
  const _HostProgressTile({required this.host});

  final FleetHostProgress host;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final icon = switch (host.status) {
      FleetHostStatus.queued => Icons.schedule,
      FleetHostStatus.running => Icons.sync,
      FleetHostStatus.done => Icons.check_circle,
      FleetHostStatus.failed => Icons.error,
      FleetHostStatus.cancelled => Icons.cancel,
    };
    final color = switch (host.status) {
      FleetHostStatus.done => theme.colorScheme.primary,
      FleetHostStatus.failed => theme.colorScheme.error,
      _ => theme.colorScheme.onSurfaceVariant,
    };
    final failedFiles =
        host.files.where((f) => f.status == FleetFileStatus.failed).toList();

    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(host.label),
      isThreeLine: host.error != null || failedFiles.isNotEmpty,
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_subtitle(host)),
          if (host.status == FleetHostStatus.running)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: LinearProgressIndicator(minHeight: 3),
            ),
          if (host.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                host.error!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ),
          for (final file in failedFiles)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '${file.name}: ${file.error ?? 'failed'}',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ),
        ],
      ),
    );
  }

  String _subtitle(FleetHostProgress host) {
    final total = host.files.length;
    final done = host.files
        .where((f) =>
            f.status == FleetFileStatus.done ||
            f.status == FleetFileStatus.skipped)
        .length;
    return switch (host.status) {
      FleetHostStatus.queued => 'Waiting…',
      FleetHostStatus.running => '$done of $total files',
      FleetHostStatus.done => total == 1 ? 'Done' : '$total files done',
      FleetHostStatus.failed => 'Failed',
      FleetHostStatus.cancelled => 'Cancelled',
    };
  }
}
