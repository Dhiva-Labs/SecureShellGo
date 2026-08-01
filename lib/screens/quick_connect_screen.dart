import 'package:flutter/material.dart';

import '../models/host.dart';
import '../services/credential_store.dart';
import '../services/host_store.dart';
import '../services/quick_connect_parser.dart';
import '../services/session_manager.dart';
import '../services/ssh_service.dart';
import '../theme.dart';
import '../widgets/error_banner.dart';
import '../widgets/host_key_dialog.dart';

/// Prompts for the password/key for a [QuickConnectTarget] parsed by
/// `quick_connect_bar.dart`, then connects — the same shape as
/// `HostEditScreen._connectWithoutSaving`, but for a target that arrived
/// pre-parsed rather than typed field-by-field, and without a "Save host"
/// primary action since quick-connect is unsaved by definition.
///
/// The host built here always gets a `quick-` id and is never written to
/// [hostStore] unless the user explicitly taps "Save this server" after a
/// successful connect.
class QuickConnectScreen extends StatefulWidget {
  const QuickConnectScreen({
    super.key,
    required this.target,
    required this.sshService,
    required this.sessions,
    required this.hostStore,
    required this.credentialStore,
  });

  final QuickConnectTarget target;
  final SshService sshService;
  final SessionManager sessions;
  final HostStore hostStore;
  final CredentialStore credentialStore;

  @override
  State<QuickConnectScreen> createState() => _QuickConnectScreenState();
}

class _QuickConnectScreenState extends State<QuickConnectScreen> {
  final _formKey = GlobalKey<FormState>();
  final _passwordController = TextEditingController();
  final _keyController = TextEditingController();
  final _passphraseController = TextEditingController();

  SshAuthMethod _authMethod = SshAuthMethod.password;
  bool _obscurePassword = true;
  bool _connecting = false;
  String? _error;
  String? _errorDetails;

  /// Set once the connection succeeds — swaps the form for the "Save this
  /// server?" offer. The session itself is already live by then regardless
  /// of what the user picks here.
  Host? _connectedHost;
  SshCredentials? _connectedCredentials;
  bool _saving = false;
  bool _saved = false;

  @override
  void dispose() {
    _passwordController.dispose();
    _keyController.dispose();
    _passphraseController.dispose();
    super.dispose();
  }

  Host _buildHost() {
    // `quick-` marks this id as ephemeral for anything that cares (nothing
    // currently does, beyond the name saying so) — never written to
    // [HostStore] unless the user asks via [_saveHost].
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

  /// Turns the ephemeral host into a saved one — a fresh id, since `quick-`
  /// ones never belong in [HostStore].
  Future<void> _saveHost() async {
    final host = _connectedHost;
    final credentials = _connectedCredentials;
    if (host == null || credentials == null || _saving) return;

    setState(() => _saving = true);
    final saved = host.copyWith(id: widget.hostStore.newId());
    try {
      await widget.hostStore.add(saved);
      await widget.credentialStore.save(saved.id, credentials);
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
    final connected = _connectedHost;
    return Scaffold(
      appBar: AppBar(title: const Text('Quick connect')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: connected == null ? _buildForm() : _buildConnectedOffer(connected),
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

  Widget _buildConnectedOffer(Host host) {
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
            'Connected to ${host.target}',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            _saved
                ? 'Saved to your host list.'
                : 'This session is open. Save this server to connect in one '
                    'tap next time.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
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
