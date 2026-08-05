import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/host.dart';
import '../services/credential_store.dart';
import '../services/device_storage.dart';
import '../services/host_field_input.dart';
import '../services/host_store.dart';
import '../services/public_key_push.dart';
import '../services/session_manager.dart';
import '../services/settings_store.dart';
import '../services/ssh_keygen.dart';
import '../services/ssh_service.dart';
import '../theme.dart';
import '../widgets/error_banner.dart';
import '../widgets/host_color_dot.dart';
import '../widgets/host_key_dialog.dart';
import '../widgets/import_key_file_button.dart';
import '../widgets/inline_hint.dart';
import '../widgets/public_key_dialog.dart';

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
  final _hostFocusNode = FocusNode();
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
  bool _generatingKey = false;
  bool _installingKey = false;
  String? _error;
  String? _errorDetails;

  /// One neutral line about the credential, shown when the host saved and its
  /// password did not. Deliberately not [_error]: the host is in the list,
  /// the thing the user came here to do worked, and a red banner over a
  /// success is what this screen used to get wrong.
  String? _credentialNotice;

  /// Every group name currently in use, for the group dropdown. Loaded async
  /// (unlike the host fields above, which come straight off [widget.host])
  /// because it has to ask [HostStore] across every saved host, not just
  /// this one.
  List<String> _groupNames = const [];
  bool _loadingGroups = true;
  String? _selectedGroup;

  /// Bumped every time the "New group…" prompt closes, to force the group
  /// dropdown's internal FormFieldState to be rebuilt from [_selectedGroup].
  /// See [_pickGroup] for why cancelling needs that as much as creating does.
  int _groupFieldEpoch = 0;
  HostColorLabel? _selectedColorLabel;

  /// Every other saved host, as jump-host candidates. Loaded for the same
  /// reason [_groupNames] is — it is a question about the whole store, not
  /// about this host.
  List<Host> _jumpCandidates = const [];
  bool _loadingJumpCandidates = true;
  String? _jumpHostId;

  @override
  void initState() {
    super.initState();
    final host = widget.host;
    // Pasting `example.com:2022` into the Host field is a normal thing to do
    // and used to leave Port on 22, silently connecting somewhere else. The
    // split happens as soon as the field is left, so the user sees the port
    // land where they expect it rather than only finding out at connect time.
    _hostFocusNode.addListener(() {
      if (!_hostFocusNode.hasFocus) _splitHostAndPort();
    });
    if (host != null) {
      _labelController.text = host.label;
      _hostController.text = host.hostname;
      _portController.text = host.port.toString();
      _usernameController.text = host.username;
      _authMethod = host.authMethod;
      _selectedGroup = host.group;
      _selectedColorLabel = host.colorLabel;
      _startupCommandController.text = host.startupCommand ?? '';
      _jumpHostId = host.jumpHostId;
      _loadExistingCredentials(host.id);
    }
    unawaited(_loadGroupNames());
    unawaited(_loadJumpCandidates());
  }

  Future<void> _loadGroupNames() async {
    final names = await widget.hostStore.groupNames();
    if (!mounted) return;
    setState(() {
      _groupNames = names;
      _loadingGroups = false;
    });
  }

  Future<void> _loadJumpCandidates() async {
    final hosts = await widget.hostStore.all();
    if (!mounted) return;
    setState(() {
      // A host may never be its own jump host. Excluding it from the list is
      // the first of the two guards; `JumpHostChain` catches the rest — a
      // loop through a third host, and a reference left dangling by a
      // deletion — at connect time, where the whole chain is visible.
      final selfId = widget.host?.id ?? _savedHostId;
      _jumpCandidates = [
        for (final host in hosts)
          if (host.id != selfId) host,
      ];
      _loadingJumpCandidates = false;
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
    _hostFocusNode.dispose();
    _portController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _keyController.dispose();
    _passphraseController.dispose();
    _passphraseFocusNode.dispose();
    _startupCommandController.dispose();
    super.dispose();
  }

  /// Moves a pasted `user@host:port` into the fields it belongs in. A no-op
  /// for anything that is only a host, including a bare IPv6 address — see
  /// [parseHostField], which owns the rule and shares it with the
  /// quick-connect bar.
  void _splitHostAndPort() {
    final entry = parseHostField(_hostController.text);
    if (entry.hostname == _hostController.text && !entry.hasParts) return;
    setState(() {
      _hostController.text = entry.hostname;
      final port = entry.port;
      if (port != null) _portController.text = port.toString();
      // Only into an empty Username field: a paste is more specific than a
      // default, but not more specific than something the user typed.
      final username = entry.username;
      if (username != null && _usernameController.text.trim().isEmpty) {
        _usernameController.text = username;
      }
    });
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
      jumpHostId: _jumpHostId,
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

  /// The tidy-up and validation all three actions run first, so none of them
  /// can act on a form the others would have refused. False means the form is
  /// not fit to act on and the caller stops.
  bool _prepare() {
    if (_saving || _connecting) return false;
    // Before validation, so a pasted `host:2022` is already two fields by the
    // time the Port validator looks at it.
    _splitHostAndPort();
    if (!(_formKey.currentState?.validate() ?? false)) return false;
    FocusScope.of(context).unfocus();
    setState(() {
      _error = null;
      _errorDetails = null;
      _credentialNotice = null;
    });
    return true;
  }

  /// Writes the host and its credential, and returns the host that was
  /// written — or null when the host record itself could not be, which is
  /// the only genuine failure here and the only one that sets [_error].
  ///
  /// A credential that could not be kept is not one: the host is in the list
  /// either way, and [_credentialNotice] says the rest calmly.
  Future<Host?> _persistHost() async {
    final host = _buildHost();
    try {
      if (widget.isEditing || _savedHostId != null) {
        await widget.hostStore.update(host);
      } else {
        await widget.hostStore.add(host);
      }
      _savedHostId = host.id;
      if (host.authMethod.storesNoSecret) {
        // Agent auth keeps nothing of its own to save, and the delete matters
        // rather than being tidiness: switching a host that used to hold a
        // password over to the agent must not leave that password sitting in
        // secure storage for a method that will never read it.
        await widget.credentialStore.delete(host.id);
      } else {
        await widget.credentialStore.save(host.id, _buildCredentials());
      }
      return host;
    } on SecureStorageUnavailableException catch (e) {
      // Only the secret could not be protected, and an install with no
      // keyring at all no longer gets here — it encrypts the credential and
      // succeeds (see `composite_secure_storage.dart`). What is left is a
      // store that exists and is shut: a keyring this machine has and has
      // locked, or a 1.4.1 vault whose prompt was cancelled. Either way the
      // host is saved, so this is one calm line and not a red banner.
      //
      // The message comes through verbatim because the backend composed it
      // knowing things this screen does not — a snap install gets the exact
      // `snap connect` command that fixes it, and re-writing that here as
      // "your keyring is locked" is how a user loses the one line that would
      // have helped.
      if (mounted) {
        setState(() {
          _credentialNotice = 'Host saved, but its password was not: '
              '${e.message}';
        });
      }
      return host;
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Could not save this host.';
          _errorDetails = e.toString();
        });
      }
      return null;
    }
  }

  Future<void> _save() async {
    if (!_prepare()) return;
    setState(() => _saving = true);
    final host = await _persistHost();
    if (!mounted) return;
    setState(() => _saving = false);
    // Staying put when there is a line to read: the host is saved either way,
    // and popping would take the explanation with it.
    if (host == null || _credentialNotice != null) return;
    Navigator.of(context).pop(true);
  }

  Future<void> _saveAndConnect() async {
    if (!_prepare()) return;
    setState(() => _saving = true);
    final host = await _persistHost();
    if (!mounted) return;
    if (host == null) {
      setState(() => _saving = false);
      return;
    }
    setState(() {
      _saving = false;
      _connecting = true;
    });
    await _openSession(host, _buildCredentials());
  }

  /// Connects on the values currently in the form and persists none of them.
  ///
  /// Nothing at all is written on this route: no host record, no credential,
  /// and therefore nothing that could make the app decide how to protect
  /// one — no keyring write, no vault, no notice. On an existing host it
  /// means "try these edits without committing them", and the saved record is
  /// left exactly as it was. The password lives in memory for as long as the
  /// session does and goes no further.
  Future<void> _connectWithoutSaving() async {
    if (!_prepare()) return;
    setState(() => _connecting = true);
    await _openSession(_buildHost(), _buildCredentials());
  }

  Future<void> _openSession(Host host, SshCredentials credentials) async {
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
      if (mounted) Navigator.of(context).pop(true);
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

  /// Fills the key field with a freshly generated ed25519 key and shows its
  /// public half in a copyable dialog. The private half goes nowhere but this
  /// field — the same one the paste/import flow already fills, saved the
  /// same way through [CredentialStore] when the host is saved.
  Future<void> _generateKey() async {
    if (_generatingKey) return;
    setState(() => _generatingKey = true);
    try {
      final hostLabel = _hostController.text.trim();
      final generated = SshKeygen.generateEd25519(
        comment: 'secureshellgo@${hostLabel.isEmpty ? 'host' : hostLabel}',
      );
      if (!mounted) return;
      setState(() {
        _keyController.text = generated.privateKeyPem;
        _passphraseController.clear();
      });
      await showGeneratedPublicKeyDialog(context, generated.publicKeyLine);
    } finally {
      if (mounted) setState(() => _generatingKey = false);
    }
  }

  /// Pushes the current key field's public half to this server's
  /// `authorized_keys`, over a live session for this host if one is open, or
  /// a fresh password-authenticated connection otherwise. See
  /// `public_key_push.dart` — only the public line is ever built into a
  /// command here.
  Future<void> _installPublicKey() async {
    if (_installingKey) return;

    final pem = _keyController.text.trim();
    if (pem.isEmpty) {
      await _showKeyImportError(null, 'Generate or paste a private key first.');
      return;
    }

    final String publicKeyLine;
    try {
      publicKeyLine = SshKeygen.publicLineFromPem(
        pem,
        passphrase:
            _passphraseController.text.isEmpty ? null : _passphraseController.text,
        comment: 'secureshellgo@${_hostController.text.trim()}',
      );
    } catch (_) {
      await _showKeyImportError(
        null,
        'Could not read this private key (check the passphrase if it has '
        'one).',
      );
      return;
    }

    final host = _buildHost();
    final live = widget.sessions.liveForHost(host.id);

    setState(() => _installingKey = true);
    try {
      if (live.isNotEmpty) {
        await const PublicKeyPushService().installOverTransport(
          transport: live.first.controller.connection,
          publicKeyLine: publicKeyLine,
        );
      } else {
        if (!mounted) return;
        final password = await promptForPushPassword(context, host.target);
        if (password == null || password.isEmpty) return;
        if (!mounted) return;
        await const PublicKeyPushService().installWithPassword(
          sshService: widget.sshService,
          host: host,
          password: password,
          publicKeyLine: publicKeyLine,
          verifyHostKey: (prompt) async {
            if (!mounted) return false;
            return showHostKeyDialog(context, prompt);
          },
        );
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Public key installed on the server')),
      );
    } on PublicKeyPushFailure catch (e) {
      if (!mounted) return;
      await _showKeyImportError(null, e.message);
    } catch (_) {
      if (!mounted) return;
      await _showKeyImportError(null, 'Could not install the key on the server.');
    } finally {
      if (mounted) setState(() => _installingKey = false);
    }
  }

  /// Thin alias kept so the "Install public key" error paths above read the
  /// same as they always did — the dialog itself now lives in
  /// `import_key_file_button.dart`, shared with [ImportKeyFileButton]'s own
  /// rejections.
  Future<void> _showKeyImportError(String? fileName, String message) =>
      showKeyFileErrorDialog(context, fileName, message);

  /// Asks for a new group's name; null means the dialog was cancelled. Only
  /// trims and checks non-blank here — [_pickGroup] is the one that decides
  /// what to do with the result, so this stays reusable if group creation is
  /// ever offered from somewhere other than the dropdown.
  Future<String?> _promptNewGroupName() {
    return showDialog<String>(
      context: context,
      builder: (context) => const _NewGroupDialog(),
    );
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
    if (!mounted) return;
    setState(() {
      // Bumped whether or not a name came back. The dropdown has already
      // taken the sentinel as its own value by the time this runs, so a
      // cancel that left [_selectedGroup] untouched would otherwise leave
      // the field reading "New group…" as though it were the chosen group —
      // and, once a real group existed under that value, trip
      // DropdownButtonFormField's one-matching-item assertion.
      _groupFieldEpoch++;
      if (created == null) return;
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
      key: ValueKey('$_groupFieldEpoch:${_selectedGroup ?? ''}'),
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

  Widget _buildJumpHostField() {
    final selected = _jumpHostId;
    // A saved jumpHostId whose host has since been deleted still has to
    // appear as an item, or DropdownButtonFormField's one-matching-item
    // assertion trips before the user ever gets the chance to fix it. It is
    // shown as missing rather than silently reset to "Direct connection",
    // which would hide a real misconfiguration.
    final dangling = selected != null &&
        !_jumpCandidates.any((host) => host.id == selected);

    return DropdownButtonFormField<String?>(
      key: ValueKey(selected),
      initialValue: selected,
      decoration: const InputDecoration(
        labelText: 'Connect via jump host',
        prefixIcon: Icon(Icons.alt_route),
      ),
      items: [
        const DropdownMenuItem<String?>(
          value: null,
          child: Text('Direct connection'),
        ),
        for (final host in _jumpCandidates)
          DropdownMenuItem<String?>(
            value: host.id,
            child: Text(host.displayName),
          ),
        if (dangling)
          DropdownMenuItem<String?>(
            value: selected,
            child: const Text('(deleted host)'),
          ),
      ],
      onChanged: _loadingJumpCandidates
          ? null
          : (value) => setState(() => _jumpHostId = value),
    );
  }

  /// The auth methods offered for this host.
  ///
  /// The OS agent is never offered as a *new* choice yet: the agent client
  /// (`ssh_agent_client.dart`) is complete, but dartssh2's synchronous
  /// `SSHKeyPair.sign` cannot be satisfied by a socket round-trip, so a
  /// host configured this way could not connect in this build — see
  /// `_prepareIdentities` in `ssh_service.dart`. The segment still renders
  /// when the host already uses it, so such a host (saved by a future
  /// build, or this one before the option was withdrawn) can be changed to
  /// something workable instead of tripping SegmentedButton's assertion
  /// that the selected value is one of the segments.
  List<SshAuthMethod> get _offeredAuthMethods => [
        SshAuthMethod.password,
        SshAuthMethod.privateKey,
        if (_authMethod == SshAuthMethod.agent) SshAuthMethod.agent,
      ];

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
                focusNode: _hostFocusNode,
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
        const SizedBox(height: 16),
        _buildJumpHostField(),
        const SizedBox(height: 20),
        SegmentedButton<SshAuthMethod>(
          segments: [
            for (final method in _offeredAuthMethods)
              ButtonSegment(
                value: method,
                icon: Icon(switch (method) {
                  SshAuthMethod.password => Icons.password,
                  SshAuthMethod.privateKey => Icons.key,
                  SshAuthMethod.agent => Icons.badge_outlined,
                }),
                label: Text(method.label),
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
        // Explicit rather than folded into the trailing `else`, which stays
        // the private-key branch: agent auth has no field to show, because
        // there is deliberately nothing about it to store.
        else if (_authMethod == SshAuthMethod.agent)
          const InlineHint(
            icon: Icons.info_outline,
            text: 'Signing is done by the operating system\'s SSH agent. No '
                'password or key is saved for this host, and the private key '
                'never leaves the agent.',
          )
        else ...[
          ImportKeyFileButton(
            deviceStorage: _deviceStorage,
            onImported: (fileName, content, keyType) =>
                setState(() => _keyController.text = content),
            onPassphraseNeeded: () =>
                FocusScope.of(context).requestFocus(_passphraseFocusNode),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: _generatingKey ? null : _generateKey,
              icon: _generatingKey
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.vpn_key_outlined, size: 18),
              label: Text(
                _generatingKey ? 'Generating…' : 'Generate new key',
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
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: _installingKey ? null : _installPublicKey,
              icon: _installingKey
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.cloud_upload_outlined, size: 18),
              label: Text(
                _installingKey ? 'Installing…' : 'Install public key on server…',
              ),
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
        const InlineHint(
          icon: Icons.shield_outlined,
          text: 'Saved credentials are encrypted on-device by your '
              "system's secure storage, not stored in plain text.",
        ),
        if (_credentialNotice != null) ...[
          const SizedBox(height: 12),
          InlineHint(icon: Icons.info_outline, text: _credentialNotice!),
        ],
        if (_error != null) ...[
          const SizedBox(height: 16),
          ErrorBanner(message: _error!, details: _errorDetails),
        ],
        const SizedBox(height: 24),
        // Two equal-weight buttons side by side, and a quiet third below.
        // Saving is what this screen is for, so it is never the one folded
        // away into a menu — "Save & connect" leads only because it saves
        // too and is the commoner intent.
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: busy ? null : _saveAndConnect,
                icon: _saving || _connecting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.play_arrow),
                label: const Text('Save & connect'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed: busy ? null : _save,
                icon: const Icon(Icons.save_outlined),
                label: Text(
                  widget.isEditing ? 'Save changes' : 'Save host',
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Center(
          child: TextButton.icon(
            onPressed: busy ? null : _connectWithoutSaving,
            icon: const Icon(Icons.terminal, size: 18),
            label: const Text('Connect without saving'),
          ),
        ),
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

/// The "New group" prompt, as a widget that owns its own controller.
///
/// The controller cannot be created by the caller and disposed from
/// `showDialog(...).whenComplete(...)`: that future completes the moment the
/// route is popped, while the dialog is still on screen animating out and its
/// `TextField` is still reading the controller — which threw "A
/// TextEditingController was used after being disposed" and took the whole
/// screen down with it. Owning the controller here ties its life to the
/// dialog's own element instead of to the route's future.
class _NewGroupDialog extends StatefulWidget {
  const _NewGroupDialog();

  @override
  State<_NewGroupDialog> createState() => _NewGroupDialogState();
}

class _NewGroupDialogState extends State<_NewGroupDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit(String value) {
    final trimmed = value.trim();
    if (trimmed.isNotEmpty) Navigator.of(context).pop(trimmed);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New group'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        textCapitalization: TextCapitalization.words,
        decoration: const InputDecoration(labelText: 'Group name'),
        onSubmitted: _submit,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => _submit(_controller.text),
          child: const Text('Create'),
        ),
      ],
    );
  }
}
