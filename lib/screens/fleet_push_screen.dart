import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
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
    // Looked up now, while this route is certainly mounted: the push outlives
    // it (see `dispose`), and its uploads still need their error wording.
    final l10n = context.l10n;
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
      openSessionLookup: (hostId) => _openSessionFor(hostId, l10n),
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
  FleetOpenSession? _openSessionFor(String hostId, AppLocalizations l10n) {
    final live = widget.sessions.liveForHost(hostId);
    if (live.isEmpty) return null;
    return _ManagedSessionUpload(live.first, l10n);
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
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.fleetPushTitle)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            Text(
              l10n.fleetPushHostCount(widget.hosts.length),
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
              label: Text(
                _files.isEmpty
                    ? l10n.fleetPushChooseFiles
                    : l10n.fleetPushAddMoreFiles,
              ),
            ),
            if (_pickError != null) ...[
              const SizedBox(height: 8),
              Text(
                _pickError!,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ],
            if (_files.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(l10n.fleetPushNoFiles),
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
                    tooltip: l10n.fleetPushRemoveFileTooltip,
                    icon: const Icon(Icons.close),
                    onPressed: () => _removeFile(file),
                  ),
                ),
            const SizedBox(height: 20),
            Text(
              l10n.fleetPushDestinationLabel,
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _destinationController,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                hintText: '~',
                helperText: l10n.fleetPushDestinationHelper,
                helperMaxLines: 2,
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 20),
            Text(
              l10n.fleetPushPolicyHeading,
              style: theme.textTheme.titleSmall,
            ),
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
                      title: Text(_policyLabel(context.l10n, policy)),
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _canContinue ? _goToConfirm : null,
              child: Text(l10n.fleetPushNext),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConfirm(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final back = MaterialLocalizations.of(context).backButtonTooltip;
    final destination = _destinationController.text.trim();
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.fleetPushConfirmTitle),
        leading: IconButton(
          tooltip: back,
          icon: const Icon(Icons.arrow_back),
          onPressed: () => setState(() => _step = _Step.setup),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            Text(
              l10n.fleetPushConfirmQuestion(
                _files.length,
                widget.hosts.length,
                destination,
              ),
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 20),
            Text(l10n.fleetPushFilesHeading, style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            for (final file in _files) Text('•  ${file.name}'),
            const SizedBox(height: 20),
            Text(l10n.fleetPushHostsHeading, style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            for (final host in widget.hosts) Text('•  ${host.displayName}'),
            const SizedBox(height: 20),
            Text(
              l10n.fleetPushPolicyLine(_policyLabel(l10n, _policy)),
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 28),
            Row(
              children: [
                OutlinedButton(
                  onPressed: () => setState(() => _step = _Step.setup),
                  child: Text(back),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  onPressed: _startPush,
                  child: Text(l10n.fleetPushStart),
                ),
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
  _ManagedSessionUpload(this._session, this._l10n);

  final ManagedSession _session;

  /// For the error wording of a failed or cancelled upload — taken from the
  /// screen up front, since the push may outlive it.
  final AppLocalizations _l10n;

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
            SftpFailure(current.error ?? _l10n.fleetPushUploadFailed),
          );
        case TransferStatus.cancelled:
          completer.completeError(
            SftpFailure(_l10n.fleetPushUploadCancelled),
          );
        case TransferStatus.queued:
        case TransferStatus.running:
        case TransferStatus.interrupted:
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
    final l10n = context.l10n;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          running ? l10n.fleetPushRunningTitle : _summary(l10n, service),
        ),
        actions: [
          if (running)
            TextButton(
              onPressed: service.cancel,
              child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
            )
          else if (anyFailed)
            TextButton(
              onPressed: service.retryFailedHosts,
              child: Text(l10n.fleetPushRetryFailed),
            )
          else if (registry != null)
            TextButton(
              onPressed: () {
                registry.clear(service);
                Navigator.of(context).maybePop();
              },
              child: Text(l10n.fleetPushDone),
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
                  _summary(l10n, service),
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
    final l10n = context.l10n;
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
          Text(_subtitle(l10n, host)),
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
                file.error == null
                    ? l10n.fleetPushFileFailed(file.name)
                    : l10n.fleetPushFileError(file.name, file.error!),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ),
        ],
      ),
    );
  }

  String _subtitle(AppLocalizations l10n, FleetHostProgress host) {
    final total = host.files.length;
    final done = host.files
        .where((f) =>
            f.status == FleetFileStatus.done ||
            f.status == FleetFileStatus.skipped)
        .length;
    return switch (host.status) {
      FleetHostStatus.queued => l10n.fleetPushStatusWaiting,
      FleetHostStatus.running => l10n.fleetPushStatusProgress(done, total),
      FleetHostStatus.done => l10n.fleetPushStatusDone(total),
      FleetHostStatus.failed => l10n.fleetPushStatusFailed,
      FleetHostStatus.cancelled => l10n.fleetPushStatusCancelled,
    };
  }
}

/// [FleetOverwritePolicy.label] in the screen's language: the enum lives in
/// lib/services and stays English for anything that is not shown.
String _policyLabel(AppLocalizations l10n, FleetOverwritePolicy policy) =>
    switch (policy) {
      FleetOverwritePolicy.overwrite => l10n.fleetPushPolicyOverwrite,
      FleetOverwritePolicy.skipExisting => l10n.fleetPushPolicySkipExisting,
      FleetOverwritePolicy.failOnExisting =>
        l10n.fleetPushPolicyFailOnExisting,
    };

/// [FleetPushService.summary], "6 of 8 succeeded", in the screen's language.
String _summary(AppLocalizations l10n, FleetPushService service) =>
    l10n.fleetPushSummary(service.succeededCount, service.totalCount);
