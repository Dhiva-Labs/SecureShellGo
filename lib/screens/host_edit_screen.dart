import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/host.dart';
import '../services/credential_store.dart';
import '../services/device_storage.dart';
import '../services/host_store.dart';
import '../services/private_key_import.dart';
import '../services/settings_store.dart';
import '../services/ssh_service.dart';
import '../theme.dart';
import '../widgets/error_banner.dart';
import '../widgets/host_key_dialog.dart';
import 'session_screen.dart';

/// Add or edit a saved host.
///
/// Saving writes the [Host] to [hostStore] and its secrets to
/// [credentialStore] — always together, so every saved host has credentials
/// behind it (see `host_list_screen.dart`, which relies on that to connect
/// on a tap without asking again). [host] null means "add"; non-null means
/// "edit", and the form (plus any previously saved credentials) is
/// pre-filled from it.
///
/// Adding also offers "Connect without saving", the one-off path the old
/// Phase 1 connect form provided, for a host you do not want remembered.
class HostEditScreen extends StatefulWidget {
  const HostEditScreen({
    super.key,
    required this.hostStore,
    required this.credentialStore,
    required this.sshService,
    required this.settingsStore,
    this.deviceStorage,
    this.host,
  });

  final HostStore hostStore;
  final CredentialStore credentialStore;
  final SshService sshService;
  final SettingsStore settingsStore;

  /// Backs the "Import key file" picker. Defaults to the real platform
  /// channel; overridable so this screen stays testable without a device.
  final DeviceStorage? deviceStorage;

  /// The host being edited, or null when adding a new one.
  final Host? host;

  bool get isEditing => host != null;

  @override
  State<HostEditScreen> createState() => _HostEditScreenState();
}

class _HostEditScreenState extends State<HostEditScreen> {
  final _formKey = GlobalKey<FormState>();
  final _labelController = TextEditingController();
  final _hostController = TextEditingController();
  final _portController = TextEditingController(text: '22');
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _keyController = TextEditingController();
  final _passphraseController = TextEditingController();
  final _passphraseFocusNode = FocusNode();

  late final DeviceStorage _deviceStorage =
      widget.deviceStorage ?? const MethodChannelDeviceStorage();

  SshAuthMethod _authMethod = SshAuthMethod.password;
  bool _obscurePassword = true;
  bool _saving = false;
  bool _connecting = false;
  bool _loadingCredentials = false;
  bool _importingKey = false;
  String? _error;
  String? _errorDetails;

  @override
  void initState() {
    super.initState();
    final host = widget.host;
    if (host != null) {
      _labelController.text = host.label;
      _hostController.text = host.hostname;
      _portController.text = host.port.toString();
      _usernameController.text = host.username;
      _authMethod = host.authMethod;
      _loadExistingCredentials(host.id);
    }
  }

  Future<void> _loadExistingCredentials(String hostId) async {
    setState(() => _loadingCredentials = true);
    final saved = await widget.credentialStore.load(hostId);
    if (!mounted) return;
    setState(() {
      _loadingCredentials = false;
      if (saved != null) {
        _passwordController.text = saved.password ?? '';
        _keyController.text = saved.privateKeyPem ?? '';
        _passphraseController.text = saved.passphrase ?? '';
      }
    });
  }

  @override
  void dispose() {
    _labelController.dispose();
    _hostController.dispose();
    _portController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _keyController.dispose();
    _passphraseController.dispose();
    _passphraseFocusNode.dispose();
    super.dispose();
  }

  Host _buildHost() {
    final existing = widget.host;
    return Host(
      id: existing?.id ?? widget.hostStore.newId(),
      label: _labelController.text.trim(),
      hostname: _hostController.text.trim(),
      port: int.tryParse(_portController.text.trim()) ?? 22,
      username: _usernameController.text.trim(),
      authMethod: _authMethod,
      lastConnectedAt: existing?.lastConnectedAt,
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

  Future<void> _save() async {
    if (_saving || _connecting) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;

    FocusScope.of(context).unfocus();
    setState(() {
      _saving = true;
      _error = null;
      _errorDetails = null;
    });

    final host = _buildHost();
    try {
      if (widget.isEditing) {
        await widget.hostStore.update(host);
      } else {
        await widget.hostStore.add(host);
      }
      await widget.credentialStore.save(host.id, _buildCredentials());
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Could not save this host.';
        _errorDetails = e.toString();
      });
    }
  }

  Future<void> _connectWithoutSaving() async {
    if (_saving || _connecting) return;
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

      setState(() => _connecting = false);
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => SessionScreen(
            connection: connection,
            settingsStore: widget.settingsStore,
          ),
        ),
      );
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

  /// Opens the system file picker, reads whatever comes back as text (never
  /// staging it to disk — see `DeviceStorage.pickTextFile`), and classifies
  /// it through the same parser [SshService] uses at connect time
  /// ([classifyPrivateKeyPem]) before trusting it enough to fill the form.
  Future<void> _importKeyFile() async {
    if (_importingKey) return;
    setState(() => _importingKey = true);

    try {
      final picked = await _deviceStorage.pickTextFile(
        maxBytes: kMaxPrivateKeyImportBytes,
      );
      if (!mounted) return;
      if (picked == null) {
        // User backed out of the picker.
        return;
      }

      final result = classifyPrivateKeyPem(picked.content);
      switch (result.status) {
        case PrivateKeyImportStatus.valid:
          setState(() => _keyController.text = picked.content);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Imported ${picked.name} — ${result.keyType}'),
            ),
          );
          break;
        case PrivateKeyImportStatus.passphraseProtected:
          setState(() => _keyController.text = picked.content);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Imported ${picked.name} — ${result.keyType}, '
                'passphrase required',
              ),
            ),
          );
          FocusScope.of(context).requestFocus(_passphraseFocusNode);
          break;
        case PrivateKeyImportStatus.invalid:
          await _showKeyImportError(picked.name, result.message!);
          break;
      }
    } on DeviceStorageException catch (e) {
      if (!mounted) return;
      await _showKeyImportError(null, e.message);
    } catch (e) {
      if (!mounted) return;
      await _showKeyImportError(null, 'Could not read that file.');
    } finally {
      if (mounted) setState(() => _importingKey = false);
    }
  }

  Future<void> _showKeyImportError(String? fileName, String message) {
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.error_outline, color: AppTheme.danger),
        title: Text(
          fileName == null
              ? 'Could not import key'
              : 'Could not import $fileName',
        ),
        content: Text(message, style: const TextStyle(height: 1.35)),
        actions: [
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
    final theme = Theme.of(context);
    final busy = _saving || _connecting;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isEditing ? 'Edit host' : 'Add host'),
      ),
      body: SafeArea(
        child: AbsorbPointer(
          absorbing: busy,
          // A no-op on a phone (the constraint is already narrower than
          // 600dp); on a tablet or DeX window it keeps the form from
          // stretching edge to edge into unreadably long text fields.
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 600),
              child: Form(
                key: _formKey,
                child: _buildFormFields(theme, busy),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFormFields(ThemeData theme, bool busy) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        TextFormField(
          controller: _labelController,
          decoration: const InputDecoration(
            labelText: 'Label (optional)',
            hintText: 'e.g. Home server',
            prefixIcon: Icon(Icons.label_outline),
          ),
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: 16),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 3,
              child: TextFormField(
                controller: _hostController,
                decoration: const InputDecoration(
                  labelText: 'Host',
                  hintText: 'example.com or 192.168.1.10',
                  prefixIcon: Icon(Icons.dns_outlined),
                ),
                keyboardType: TextInputType.url,
                autocorrect: false,
                enableSuggestions: false,
                textCapitalization: TextCapitalization.none,
                textInputAction: TextInputAction.next,
                validator: (value) =>
                    (value == null || value.trim().isEmpty)
                        ? 'Required'
                        : null,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextFormField(
                controller: _portController,
                decoration: const InputDecoration(labelText: 'Port'),
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                ],
                textInputAction: TextInputAction.next,
                validator: (value) {
                  final port = int.tryParse((value ?? '').trim());
                  if (port == null || port < 1 || port > 65535) {
                    return '1-65535';
                  }
                  return null;
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        TextFormField(
          controller: _usernameController,
          decoration: const InputDecoration(
            labelText: 'Username',
            prefixIcon: Icon(Icons.person_outline),
          ),
          autocorrect: false,
          enableSuggestions: false,
          textCapitalization: TextCapitalization.none,
          textInputAction: TextInputAction.next,
          validator: (value) => (value == null || value.trim().isEmpty)
              ? 'Required'
              : null,
        ),
        const SizedBox(height: 20),
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
        if (_loadingCredentials)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          )
        else if (_authMethod == SshAuthMethod.password)
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
          )
        else ...[
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: _importingKey ? null : _importKeyFile,
              icon: _importingKey
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.file_open_outlined, size: 18),
              label: Text(
                _importingKey ? 'Importing…' : 'Import key file',
              ),
            ),
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
              helperText:
                  'OpenSSH or PEM format: RSA, ECDSA or ed25519. Paste it, '
                  'or import a .pem file above.',
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
              helperText: 'Only if the key is encrypted.',
            ),
          ),
        ],
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.shield_outlined,
              size: 16,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Saved credentials are encrypted on-device with the '
                'Android Keystore, not stored in plain text.',
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
        if (_error != null) ...[
          const SizedBox(height: 16),
          ErrorBanner(message: _error!, details: _errorDetails),
        ],
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: busy ? null : _save,
          icon: _saving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.save_outlined),
          label: Text(_saving ? 'Saving…' : 'Save host'),
        ),
        if (!widget.isEditing) ...[
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: busy ? null : _connectWithoutSaving,
            icon: _connecting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.terminal),
            label: Text(
              _connecting ? 'Connecting…' : 'Connect without saving',
            ),
          ),
        ],
      ],
    );
  }
}
