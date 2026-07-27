import 'dart:async';

import 'package:flutter/material.dart';

import '../models/host.dart';
import '../services/credential_store.dart';
import '../services/device_storage.dart';
import '../services/host_store.dart';
import '../services/remote_path.dart';
import '../services/session_registry.dart';
import '../services/settings_store.dart';
import '../services/ssh_service.dart';
import '../theme.dart';
import '../widgets/host_key_dialog.dart';
import 'host_edit_screen.dart';
import 'session_screen.dart';

/// Where a file shared from another app is going.
///
/// This is the screen that makes "put this on my server" a two-tap operation
/// from anywhere on the phone: share into SecureShell Go, pick the host, and
/// land in that host's file browser with the files waiting to be dropped into
/// whichever directory the user browses to.
///
/// A host that is already connected is reused rather than dialled again —
/// same credentials, same host-key check, same foreground service, all
/// already paid for. A host that is not gets the ordinary connect path,
/// host-key verification included: a share is not a reason to trust a key
/// that has not been verified.
class ShareTargetScreen extends StatefulWidget {
  const ShareTargetScreen({
    super.key,
    required this.files,
    required this.hostStore,
    required this.credentialStore,
    required this.sshService,
    required this.settingsStore,
    this.registry,
  });

  final List<PickedLocalFile> files;
  final HostStore hostStore;
  final CredentialStore credentialStore;
  final SshService sshService;
  final SettingsStore settingsStore;

  /// Test seam; production uses the process-wide registry.
  final SessionRegistry? registry;

  @override
  State<ShareTargetScreen> createState() => _ShareTargetScreenState();
}

class _ShareTargetScreenState extends State<ShareTargetScreen> {
  late final SessionRegistry _registry =
      widget.registry ?? SessionRegistry.instance;
  late Future<List<Host>> _hosts;

  String? _connectingHostId;

  @override
  void initState() {
    super.initState();
    _hosts = widget.hostStore.all();
  }

  int get _totalBytes =>
      widget.files.fold<int>(0, (sum, file) => sum + file.size);

  Future<void> _sendTo(Host host) async {
    if (_connectingHostId != null) return;

    final live = _registry.forHost(host.id);
    if (live != null) {
      // The session is already open somewhere below this route: hand it the
      // files and take the user back to it, rather than opening a second
      // connection to the same machine.
      live.session.requestUpload(widget.files);
      if (live.bringToFront()) return;
    }

    setState(() {
      _connectingHostId = host.id;
    });

    final credentials = await widget.credentialStore.load(host.id);
    if (!mounted) return;
    if (credentials == null) {
      setState(() {
        _connectingHostId = null;
      });
      await _showError(
        'No saved credentials for ${host.displayName}.',
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

      unawaited(
        widget.hostStore.update(host.copyWith(lastConnectedAt: DateTime.now())),
      );
      setState(() {
        _connectingHostId = null;
      });

      // pushReplacement: once the session is up, this picker has done its job
      // and should not be sitting behind it for a back gesture to land on.
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => SessionScreen(
            connection: connection,
            settingsStore: widget.settingsStore,
            initialView: SessionView.files,
            initialUploads: widget.files,
          ),
        ),
      );
    } on SshConnectionException catch (e) {
      if (!mounted) return;
      setState(() {
        _connectingHostId = null;
      });
      await _showError(e.message, details: e.details);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _connectingHostId = null;
      });
      await _showError(
        'Something went wrong while connecting.',
        details: e.toString(),
      );
    }
  }

  Future<void> _editHost(Host host) async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => HostEditScreen(
          hostStore: widget.hostStore,
          credentialStore: widget.credentialStore,
          sshService: widget.sshService,
          settingsStore: widget.settingsStore,
          host: host,
        ),
      ),
    );
    if (!mounted) return;
    final hosts = widget.hostStore.all();
    setState(() {
      _hosts = hosts;
    });
  }

  Future<void> _showError(
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Upload to…'),
      ),
      body: SafeArea(
        child: Column(
          children: [
            _SharedFilesSummary(files: widget.files, totalBytes: _totalBytes),
            const Divider(height: 1),
            Expanded(child: _buildHosts()),
          ],
        ),
      ),
    );
  }

  Widget _buildHosts() {
    return FutureBuilder<List<Host>>(
      future: _hosts,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final hosts = snapshot.data!;
        if (hosts.isEmpty) return const _NoHosts();

        return ListView.separated(
          itemCount: hosts.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final host = hosts[index];
            final connecting = _connectingHostId == host.id;
            final live = _registry.forHost(host.id) != null;

            return ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 8,
              ),
              leading: CircleAvatar(
                radius: 20,
                backgroundColor: AppTheme.surface,
                child: Icon(
                  host.authMethod == SshAuthMethod.password
                      ? Icons.password
                      : Icons.key,
                  size: 20,
                ),
              ),
              title: Text(
                host.displayName,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                live ? '${host.target}  ·  already connected' : host.target,
                style: TextStyle(
                  fontSize: 12.5,
                  color: live
                      ? AppTheme.accent
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              trailing: connecting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.chevron_right),
              onTap: connecting ? null : () => unawaited(_sendTo(host)),
            );
          },
        );
      },
    );
  }
}

/// What is being uploaded, above the list of where it could go.
class _SharedFilesSummary extends StatelessWidget {
  const _SharedFilesSummary({required this.files, required this.totalBytes});

  final List<PickedLocalFile> files;
  final int totalBytes;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final names = files.take(3).map((f) => f.name).join(', ');
    final more = files.length - 3;

    return Container(
      width: double.infinity,
      color: AppTheme.surface,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.ios_share, size: 20, color: AppTheme.accent),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  files.length == 1
                      ? '1 file  ·  ${RemotePath.formatBytes(totalBytes)}'
                      : '${files.length} files  ·  '
                          '${RemotePath.formatBytes(totalBytes)}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 3),
                Text(
                  more > 0 ? '$names and $more more' : names,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 6),
                Text(
                  'Pick a server, then choose the folder to put them in.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _NoHosts extends StatelessWidget {
  const _NoHosts();

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
              size: 64,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
            ),
            const SizedBox(height: 18),
            Text('No saved hosts yet', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'Add a server in SecureShell Go first — then sharing a file to '
              'it takes two taps.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Back'),
            ),
          ],
        ),
      ),
    );
  }
}
