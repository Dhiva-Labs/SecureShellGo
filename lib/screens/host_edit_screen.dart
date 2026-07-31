import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/host.dart';
import '../services/credential_store.dart';
import '../services/device_storage.dart';
import '../services/host_store.dart';
import '../services/private_key_import.dart';
import '../services/session_manager.dart';
import '../services/settings_store.dart';
import '../services/ssh_service.dart';
import '../theme.dart';
import '../widgets/error_banner.dart';
import '../widgets/host_color_dot.dart';
import '../widgets/host_key_dialog.dart';

/// Dropdown value for "New group…". Every real group name is the trimmed
/// result of a user-typed name (see `_promptNewGroupName` and
/// `HostStore.renameGroup`), so the untrimmed leading space here guarantees
/// this sentinel can never collide with one.
const String _newGroupSentinel = ' new-group';

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
    required this.sessions,
    this.deviceStorage,
    this.host,
  });

  final HostStore hostStore;
  final CredentialStore credentialStore;
  final SshService sshService;
  final SettingsStore settingsStore;

  /// Where "Connect without saving" hands its connection. The session shows up
  /// as another tab on the sessions screen like any other.
  final SessionManager sessions;

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
  final _startupCommandController = TextEditingController();

  late final DeviceStorage _deviceStorage =
      widget.deviceStorage ?? createDefaultDeviceStorage();

  /// The id of the host row this screen has already written, when adding.
  ///
  /// [_save] is retryable: saving the host succeeds, then the credential
  /// write can still fail (a locked keyring). Without remembering what was
  /// created, [_buildHost] would mint a fresh id on the next attempt and
  /// `add` a *second* copy of the same server — which is exactly what
  /// happened before this existed.
  String? _savedHostId;

  SshAuthMethod _authMethod = SshAuthMethod.password;
  bool _obscurePassword = true;
  bool _saving = false;
  bool _connecting = false;
  bool _loadingCredentials = false;
  bool _importingKey = false;
  String? _error;
  String? _errorDetails;

  /// Every group name currently in use, for the group dropdown. Loaded async
  /// (unlike the host fields above, which come straight off [widget.host])
  /// because it has to ask [HostStore] across every saved host, not just
  /// this one.
  List<String> _groupNames = const [];
  bool _loadingGroups = true;
  String? _selectedGroup;
  HostColorLabel? _selectedColorLabel;

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
      _selectedGroup = host.group;
      _selectedColorLabel = host.colorLabel;
      _startupCommandController.text = host.startupCommand ?? '';
      _loadExistingCredentials(host.id);
    }
    unawaited(_loadGroupNames());
  }

  Future<void> _loadGroupNames() async {
    final names = await widget.hostStore.groupNames();
    if (!mounted) return;
    setState(() {
      _groupNames = names;
      _loadingGroups = false;
    });
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
    _startupCommandController.dispose();
    super.dispose();
  }

  Host _buildHost() {
    final existing = widget.host;
    final startupCommand = _startupCommandController.text.trim();
    return Host(
      id: existing?.id ?? _savedHostId ?? widget.hostStore.newId(),
      label: _labelController.text.trim(),
      hostname: _hostController.text.trim(),
      port: int.tryParse(_portController.text.trim()) ?? 22,
      username: _usernameController.text.trim(),
      authMethod: _authMethod,
      lastConnectedAt: existing?.lastConnectedAt,
      group: _selectedGroup,
      colorLabel: _selectedColorLabel,
      startupCommand: startupCommand.isEmpty ? null : startupCommand,
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
      if (widget.isEditing || _savedHostId != null) {
        await widget.hostStore.update(host);
      } else {
        await widget.hostStore.add(host);
      }
      _savedHostId = host.id;
      await widget.credentialStore.save(host.id, _buildCredentials());
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on SecureStorageUnavailableException catch (e) {
      // The host itself is already saved by this point — only the secret
      // could not be protected. "Could not save this host" would send the
      // user looking for a host that is in fact sitting in the list, and
      // there is deliberately no plaintext fallback to have used instead.
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Saved the host, but not the password or key.';
        _errorDetails = e.message;
      });
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
      widget.sessions.open(connection);
      // Popping rather than pushing the sessions screen from here: the host
      // list below owns that route, and stacking a second copy of it over this
      // form is how a back gesture ends up somewhere nobody expects.
      if (mounted) Navigator.of(context).pop();
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

  /// Asks for a new group's name; null means the dialog was cancelled. Only
  /// trims and checks non-blank here — [_pickGroup] is the one that decides
  /// what to do with the result, so this stays reusable if group creation is
  /// ever offered from somewhere other than the dropdown.
  Future<String?> _promptNewGroupName() {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New group'),
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
            child: const Text('Create'),
          ),
        ],
      ),
    ).whenComplete(controller.dispose);
  }

  /// Handles every selection the group dropdown can produce, including
  /// intercepting [_newGroupSentinel] to prompt for a name instead of
  /// assigning that placeholder itself as the group.
  Future<void> _pickGroup(String? value) async {
    if (value != _newGroupSentinel) {
      setState(() => _selectedGroup = value);
      return;
    }
    final created = await _promptNewGroupName();
    if (created == null || !mounted) return;
    setState(() {
      _selectedGroup = created;
      if (!_groupNames.contains(created)) {
        _groupNames = [..._groupNames, created]
          ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      }
    });
  }

  Widget _buildGroupField() {
    // The current selection has to be in `items` even before _groupNames
    // finishes loading (editing a host whose group is not yet in that list)
    // or DropdownButtonFormField's one-matching-item assertion trips.
    final names = <String>{
      ..._groupNames,
      ?_selectedGroup,
    }.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    return DropdownButtonFormField<String?>(
      // Remounts the field's internal FormFieldState whenever the selection
      // changes for a reason other than the user picking straight off this
      // widget — namely _pickGroup landing on a freshly created name after
      // intercepting _newGroupSentinel. DropdownButtonFormField otherwise
      // only reads its value once, at construction (`initialValue`).
      key: ValueKey(_selectedGroup),
      initialValue: _selectedGroup,
      decoration: const InputDecoration(
        labelText: 'Group (optional)',
        prefixIcon: Icon(Icons.folder_outlined),
      ),
      items: [
        const DropdownMenuItem<String?>(value: null, child: Text('No group')),
        for (final name in names)
          DropdownMenuItem<String?>(value: name, child: Text(name)),
        const DropdownMenuItem<String?>(
          value: _newGroupSentinel,
          child: Text('New group…'),
        ),
      ],
      onChanged: _loadingGroups
          ? null
          : (value) => unawaited(_pickGroup(value)),
    );
  }

  Widget _buildColorField(ThemeData theme) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 14),
          child: Text('Colour tag', style: theme.textTheme.bodyLarge),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _ColorOption(
                colorLabel: null,
                selected: _selectedColorLabel == null,
                onTap: () => setState(() => _selectedColorLabel = null),
              ),
              for (final option in HostColorLabel.values)
                _ColorOption(
                  colorLabel: option,
                  selected: _selectedColorLabel == option,
                  onTap: () => setState(() => _selectedColorLabel = option),
                ),
            ],
          ),
        ),
      ],
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
        _buildGroupField(),
        const SizedBox(height: 16),
        _buildColorField(theme),
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
        const SizedBox(height: 20),
        TextFormField(
          controller: _startupCommandController,
          decoration: const InputDecoration(
            labelText: 'Run after connect (optional)',
            hintText: 'cd /var/www && ls',
            prefixIcon: Icon(Icons.play_arrow_outlined),
            helperText:
                'Runs once, automatically, right when the shell opens — '
                'as if typed and Enter pressed.',
          ),
          autocorrect: false,
          enableSuggestions: false,
          textInputAction: TextInputAction.done,
          style: const TextStyle(
            fontFamily: AppTheme.monoFontFamily,
            fontFamilyFallback: AppTheme.monoFontFamilyFallback,
            fontSize: 13,
          ),
        ),
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
                'Saved credentials are encrypted on-device by your '
                "system's secure storage, not stored in plain text.",
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

/// One tappable dot in the colour-tag row, including the leading "no
/// colour" option ([colorLabel] null).
class _ColorOption extends StatelessWidget {
  const _ColorOption({
    required this.colorLabel,
    required this.selected,
    required this.onTap,
  });

  final HostColorLabel? colorLabel;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: colorLabel?.label ?? 'No colour',
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: HostColorDot(
            colorLabel: colorLabel,
            size: 22,
            selected: selected,
          ),
        ),
      ),
    );
  }
}
