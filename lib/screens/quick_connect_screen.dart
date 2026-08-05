import 'package:flutter/material.dart';

import '../models/host.dart';
import '../services/credential_store.dart';
import '../services/device_storage.dart';
import '../services/host_store.dart';
import '../services/quick_connect_parser.dart';
import '../services/session_manager.dart';
import '../services/ssh_service.dart';
import '../theme.dart';
import '../widgets/error_banner.dart';
import '../widgets/host_key_dialog.dart';
import '../widgets/import_key_file_button.dart';
import '../widgets/inline_hint.dart';

/// Prompts for the password/key for a [QuickConnectTarget] parsed by
/// `quick_connect_bar.dart`, then connects — the same shape as
/// `HostEditScreen._connectWithoutSaving`, but for a target that arrived
/// pre-parsed rather than typed field-by-field, and asked whether to keep it
/// only after it works (see [QuickConnectSaveOffer]) rather than up front.
///
/// The host built here always gets a `quick-` id and is never written to
/// [hostStore] unless the user agrees, after connecting, to save it.
class QuickConnectScreen extends StatefulWidget {
  const QuickConnectScreen({
    super.key,
    required this.target,
    required this.sshService,
    required this.sessions,
    required this.hostStore,
    required this.credentialStore,
    this.deviceStorage,
  });

  final QuickConnectTarget target;
  final SshService sshService;
  final SessionManager sessions;
  final HostStore hostStore;
  final CredentialStore credentialStore;

  /// Backs the "Import key file" picker. Defaults to the real platform
  /// channel; overridable so this screen stays testable without a device —
  /// the same seam `host_edit_screen.dart` takes for the same reason.
  final DeviceStorage? deviceStorage;

  @override
  State<QuickConnectScreen> createState() => _QuickConnectScreenState();
}

class _QuickConnectScreenState extends State<QuickConnectScreen> {
  final _formKey = GlobalKey<FormState>();
  final _passwordController = TextEditingController();
  final _keyController = TextEditingController();
  final _passphraseController = TextEditingController();
  final _passphraseFocusNode = FocusNode();

  late final DeviceStorage _deviceStorage =
      widget.deviceStorage ?? createDefaultDeviceStorage();

  SshAuthMethod _authMethod = SshAuthMethod.password;
  bool _obscurePassword = true;
  bool _connecting = false;
  String? _error;
  String? _errorDetails;

  /// Set once the connection succeeds — swaps the form for the "Save this
  /// server?" offer ([QuickConnectSaveOffer]). The session itself is already
  /// live by then regardless of what the user picks there.
  Host? _connectedHost;
  SshCredentials? _connectedCredentials;

  @override
  void dispose() {
    _passwordController.dispose();
    _keyController.dispose();
    _passphraseController.dispose();
    _passphraseFocusNode.dispose();
    super.dispose();
  }

  Host _buildHost() {
    // `quick-` marks this id as ephemeral for anything that cares (nothing
    // currently does, beyond the name saying so) — never written to
    // [HostStore] unless the user agrees via [QuickConnectSaveOffer].
    return Host(
      id: 'quick-${DateTime.now().microsecondsSinceEpoch}',
      label: '',
      hostname: widget.target.hostname,
      port: widget.target.port,
      username: widget.target.username,
      authMethod: _authMethod,
    );
  }

  SshCredentials _buildCredentials() {
    return SshCredentials(
      password:
          _authMethod == SshAuthMethod.password ? _passwordController.text : null,
      privateKeyPem:
          _authMethod == SshAuthMethod.privateKey ? _keyController.text : null,
      passphrase: _authMethod == SshAuthMethod.privateKey
          ? _passphraseController.text
          : null,
    );
  }

  Future<void> _connect() async {
    if (_connecting) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;

    FocusScope.of(context).unfocus();
    setState(() {
      _connecting = true;
      _error = null;
      _errorDetails = null;
    });

    final host = _buildHost();
    final credentials = _buildCredentials();

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

      widget.sessions.open(connection);
      setState(() {
        _connecting = false;
        _connectedHost = host;
        _connectedCredentials = credentials;
      });
    } on SshConnectionException catch (e) {
      if (!mounted) return;
      setState(() {
        _connecting = false;
        _error = e.message;
        _errorDetails = e.details;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _connecting = false;
        _error = 'Something went wrong while connecting.';
        _errorDetails = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final host = _connectedHost;
    final credentials = _connectedCredentials;
    return Scaffold(
      appBar: AppBar(title: const Text('Quick connect')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: host == null || credentials == null
                ? _buildForm()
                : QuickConnectSaveOffer(
                    host: host,
                    credentials: credentials,
                    hostStore: widget.hostStore,
                    credentialStore: widget.credentialStore,
                  ),
          ),
        ),
      ),
    );
  }

  Widget _buildForm() {
    return AbsorbPointer(
      absorbing: _connecting,
      child: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.dns_outlined),
              title: Text(
                '${widget.target.username}@${widget.target.hostname}'
                ':${widget.target.port}',
              ),
              subtitle: const Text('Not saved — connecting once'),
            ),
            const SizedBox(height: 12),
            SegmentedButton<SshAuthMethod>(
              segments: const [
                ButtonSegment(
                  value: SshAuthMethod.password,
                  icon: Icon(Icons.password),
                  label: Text('Password'),
                ),
                ButtonSegment(
                  value: SshAuthMethod.privateKey,
                  icon: Icon(Icons.key),
                  label: Text('Private key'),
                ),
              ],
              selected: {_authMethod},
              onSelectionChanged: (selection) =>
                  setState(() => _authMethod = selection.first),
            ),
            const SizedBox(height: 16),
            if (_authMethod == SshAuthMethod.password)
              TextFormField(
                controller: _passwordController,
                obscureText: _obscurePassword,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: 'Password',
                  prefixIcon: const Icon(Icons.lock_outline),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscurePassword
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                    ),
                    onPressed: () => setState(
                      () => _obscurePassword = !_obscurePassword,
                    ),
                  ),
                ),
                validator: (value) => (value == null || value.isEmpty)
                    ? 'Required'
                    : null,
                onFieldSubmitted: (_) => _connect(),
              )
            else ...[
              ImportKeyFileButton(
                deviceStorage: _deviceStorage,
                onImported: (fileName, content, keyType) =>
                    setState(() => _keyController.text = content),
                onPassphraseNeeded: () => FocusScope.of(context)
                    .requestFocus(_passphraseFocusNode),
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _keyController,
                minLines: 5,
                maxLines: 10,
                autocorrect: false,
                enableSuggestions: false,
                style: const TextStyle(
                  fontFamily: AppTheme.monoFontFamily,
                  fontFamilyFallback: AppTheme.monoFontFamilyFallback,
                  fontSize: 12,
                ),
                decoration: const InputDecoration(
                  labelText: 'Private key (PEM)',
                  alignLabelWithHint: true,
                  hintText: '-----BEGIN OPENSSH PRIVATE KEY-----\n...',
                  helperText: 'OpenSSH or PEM format: RSA, ECDSA or '
                      'ed25519. Paste it, or import a .pem file above.',
                ),
                validator: (value) {
                  final text = (value ?? '').trim();
                  if (text.isEmpty) return 'Required';
                  if (!text.contains('BEGIN') || !text.contains('END')) {
                    return 'Paste the whole key, including BEGIN/END lines';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _passphraseController,
                focusNode: _passphraseFocusNode,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  labelText: 'Key passphrase (optional)',
                  prefixIcon: Icon(Icons.lock_outline),
                ),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 16),
              ErrorBanner(message: _error!, details: _errorDetails),
            ],
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _connecting ? null : _connect,
              icon: _connecting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.terminal),
              label: Text(_connecting ? 'Connecting…' : 'Connect'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown in place of the form once a quick connection succeeds. The session
/// is already open by then (see [_QuickConnectScreenState._connect], which
/// calls `sessions.open` before ever setting the state that swaps this
/// widget in) — nothing in here can delay or block it; this only decides
/// whether the host that got the user in is worth remembering.
///
/// A dialog offering to save opens itself once, right after this first
/// builds — "ask", per the report this screen exists to fix, rather than
/// leaving a button for the user to notice on their own. Declining is just
/// closing that dialog: no further prompting, and "Save this server" below
/// stays available for anyone who changes their mind without reconnecting.
class QuickConnectSaveOffer extends StatefulWidget {
  const QuickConnectSaveOffer({
    super.key,
    required this.host,
    required this.credentials,
    required this.hostStore,
    required this.credentialStore,
  });

  /// The ephemeral (`quick-`) host the connection was made to.
  final Host host;

  /// Exactly what authenticated it — including an imported private key and
  /// its passphrase, since `_buildCredentials` reads straight off the form's
  /// controllers regardless of whether the key was pasted or imported.
  final SshCredentials credentials;

  final HostStore hostStore;
  final CredentialStore credentialStore;

  @override
  State<QuickConnectSaveOffer> createState() => _QuickConnectSaveOfferState();
}

class _QuickConnectSaveOfferState extends State<QuickConnectSaveOffer> {
  bool _saving = false;
  bool _saved = false;
  bool _offered = false;

  /// One neutral line shown when the host saved but its secret did not —
  /// the same rule `host_edit_screen.dart`'s `_credentialNotice` follows: a
  /// host save that worked never reads as a failure.
  String? _credentialNotice;

  @override
  void initState() {
    super.initState();
    // Post-frame: showDialog needs this widget's own route already settled
    // in the Navigator, which build() has not necessarily finished yet.
    WidgetsBinding.instance.addPostFrameCallback((_) => _offerToSave());
  }

  Future<void> _offerToSave() async {
    if (_offered || !mounted) return;
    _offered = true;
    final save = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.bookmark_add_outlined),
        title: const Text('Save this server?'),
        content: Text(
          'Connect to ${widget.host.target} in one tap next time, instead '
          'of entering these details again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Save host'),
          ),
        ],
      ),
    );
    if (save == true && mounted) await _saveHost();
  }

  /// Turns the ephemeral host into a saved one — a fresh id, since `quick-`
  /// ones never belong in [HostStore]. The one save path, reached from
  /// either the dialog's "Save host" or the inline button below.
  Future<void> _saveHost() async {
    if (_saving || _saved) return;
    setState(() {
      _saving = true;
      _credentialNotice = null;
    });
    final saved = widget.host.copyWith(id: widget.hostStore.newId());
    try {
      await widget.hostStore.add(saved);
      // The host is in the list from here on — a credential problem below is
      // reported calmly rather than making a host save that worked look like
      // one that did not.
      try {
        await widget.credentialStore.save(saved.id, widget.credentials);
      } on SecureStorageUnavailableException catch (e) {
        if (!mounted) return;
        setState(() {
          _saving = false;
          _saved = true;
          _credentialNotice = 'Host saved, but its password was not: '
              '${e.message}';
        });
        return;
      }
      if (!mounted) return;
      setState(() {
        _saving = false;
        _saved = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save this host: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle_outline,
              color: theme.colorScheme.primary, size: 48),
          const SizedBox(height: 16),
          Text(
            'Connected to ${widget.host.target}',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            _saved
                ? 'Saved to your host list.'
                : 'This session is open. Save this server to connect in one '
                    'tap next time.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium,
          ),
          if (_credentialNotice != null) ...[
            const SizedBox(height: 12),
            InlineHint(icon: Icons.info_outline, text: _credentialNotice!),
          ],
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Done'),
              ),
              const SizedBox(width: 12),
              if (!_saved)
                FilledButton.icon(
                  // The app theme gives every FilledButton
                  // `Size.fromHeight(48)` — an infinite minimum width — so
                  // that buttons stacked in a column fill it. In a Row that
                  // is an infinite width constraint and layout fails for the
                  // whole subtree, which shows up as a page that renders its
                  // app bar and nothing else. Same override as
                  // `remote_directory_picker.dart` and `_SelectionBar` in
                  // `file_browser_pane.dart`.
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 44),
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                  ),
                  onPressed: _saving ? null : _saveHost,
                  icon: _saving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.bookmark_add_outlined),
                  label: Text(_saving ? 'Saving…' : 'Save this server'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
