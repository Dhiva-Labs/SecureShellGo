import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/app_settings.dart';
import '../../services/assistant/assistant_service.dart';
import '../../services/secure_storage_backend.dart';
import 'settings_section.dart';

/// The built-in assistant's settings: the switch (with its explanation every
/// time it goes on), the provider, address, model and API key, and one line
/// saying whether it is ready.
///
/// Self-contained: it reads and writes settings through [settings] and
/// [apply], and the key only through [service], which keeps it in secure
/// storage. The key is never shown again after it is saved.
class AssistantSettingsSection extends StatefulWidget {
  const AssistantSettingsSection({
    super.key,
    required this.settings,
    required this.apply,
    required this.service,
  });

  final AppSettings settings;
  final SettingsChange apply;
  final AssistantService service;

  @override
  State<AssistantSettingsSection> createState() =>
      _AssistantSettingsSectionState();
}

class _AssistantSettingsSectionState extends State<AssistantSettingsSection> {
  late final TextEditingController _address = TextEditingController(
    text: widget.settings.assistantBaseUrl,
  );
  late final TextEditingController _model = TextEditingController(
    text: widget.settings.assistantModel,
  );
  final TextEditingController _key = TextEditingController();
  final FocusNode _addressFocus = FocusNode();
  final FocusNode _modelFocus = FocusNode();
  StreamSubscription<void>? _serviceWatch;

  /// Saves the address and model shortly after typing stops, so leaving the
  /// screen straight after typing does not lose them.
  Timer? _typing;

  /// The storage's own words when the key could not be saved or removed.
  String? _keyError;
  bool _keyBusy = false;

  @override
  void initState() {
    super.initState();
    _serviceWatch = widget.service.changes.listen((_) {
      if (mounted) setState(() {});
    });
    _addressFocus.addListener(() {
      if (!_addressFocus.hasFocus) unawaited(_commitText());
    });
    _modelFocus.addListener(() {
      if (!_modelFocus.hasFocus) unawaited(_commitText());
    });
    _key.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void didUpdateWidget(AssistantSettingsSection old) {
    super.didUpdateWidget(old);
    // A change made elsewhere (a reload) shows, unless the user is typing.
    if (!_addressFocus.hasFocus &&
        old.settings.assistantBaseUrl != widget.settings.assistantBaseUrl) {
      _address.text = widget.settings.assistantBaseUrl;
    }
    if (!_modelFocus.hasFocus &&
        old.settings.assistantModel != widget.settings.assistantModel) {
      _model.text = widget.settings.assistantModel;
    }
    // Each provider has its own key: a key typed for one is never saved
    // under the other, and an error about the other's key no longer applies.
    if (old.settings.assistantProvider != widget.settings.assistantProvider) {
      _key.clear();
      _keyError = null;
    }
  }

  @override
  void dispose() {
    // Whatever is still unsaved is saved on a best-effort basis: the screen
    // may already be going away.
    if (_typing?.isActive ?? false) {
      unawaited(_commitText().catchError((Object _) {}));
    }
    _typing?.cancel();
    unawaited(_serviceWatch?.cancel());
    _address.dispose();
    _model.dispose();
    _key.dispose();
    _addressFocus.dispose();
    _modelFocus.dispose();
    super.dispose();
  }

  Future<void> _save(AppSettings Function(AppSettings current) change) async {
    final messenger = ScaffoldMessenger.of(context);
    final message = context.l10n.settingsBridgeSaveFailed;
    try {
      await widget.apply(change);
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(message)));
    }
  }

  void _typed(String _) {
    // The line naming where the key goes follows the address as it is typed.
    setState(() {});
    _typing?.cancel();
    _typing = Timer(const Duration(milliseconds: 500), () {
      if (mounted) unawaited(_commitText().catchError((Object _) {}));
    });
  }

  Future<void> _commitText() async {
    _typing?.cancel();
    final address = _address.text.trim();
    final model = _model.text.trim();
    final s = widget.settings;
    if (address == s.assistantBaseUrl && model == s.assistantModel) return;
    await widget.apply(
      (c) => c.copyWith(assistantBaseUrl: address, assistantModel: model),
    );
  }

  Future<void> _setEnabled(bool on) async {
    if (on) {
      final l10n = context.l10n;
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(l10n.assistantEnableTitle),
          content: SingleChildScrollView(child: Text(l10n.assistantEnableBody)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(l10n.assistantEnableConfirm),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    await _save((s) => s.copyWith(assistantEnabled: on));
  }

  Future<void> _saveKey() async {
    final text = _key.text;
    if (text.trim().isEmpty || _keyBusy) return;
    setState(() {
      _keyBusy = true;
      _keyError = null;
    });
    final failed = context.l10n.assistantKeyFailed;
    try {
      await widget.service.setApiKey(text);
      _key.clear();
    } on SecureStorageUnavailableException catch (e) {
      _keyError = e.message;
    } catch (_) {
      _keyError = failed;
    }
    if (mounted) setState(() => _keyBusy = false);
  }

  Future<void> _removeKey() async {
    if (_keyBusy) return;
    setState(() {
      _keyBusy = true;
      _keyError = null;
    });
    final failed = context.l10n.assistantKeyFailed;
    try {
      await widget.service.clearApiKey();
      _key.clear();
    } on SecureStorageUnavailableException catch (e) {
      _keyError = e.message;
    } catch (_) {
      _keyError = failed;
    }
    if (mounted) setState(() => _keyBusy = false);
  }

  String _providerLabel(AssistantProviderKind kind) {
    final l10n = context.l10n;
    return switch (kind) {
      AssistantProviderKind.anthropic => l10n.assistantProviderAnthropic,
      AssistantProviderKind.openAiCompatible => l10n.assistantProviderOpenAi,
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final s = widget.settings;
    final openAi = s.assistantProvider == AssistantProviderKind.openAiCompatible;
    final hasKey = widget.service.hasApiKey;
    final problem = widget.service.configurationProblem;
    final keyHost = AssistantService.keyDestinationHost(
      s.copyWith(assistantBaseUrl: _address.text),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          secondary: const Icon(Icons.smart_toy_outlined),
          title: Text(l10n.assistantSettingsSwitch),
          subtitle: Text(l10n.assistantSettingsSwitchHelp),
          value: s.assistantEnabled,
          onChanged: (on) => unawaited(_setEnabled(on)),
        ),
        if (s.assistantEnabled) ...[
          SettingsChoice<AssistantProviderKind>(
            label: l10n.assistantProviderLabel,
            icon: Icons.cloud_outlined,
            value: s.assistantProvider,
            values: AssistantProviderKind.values,
            labelOf: _providerLabel,
            onChanged: (kind) =>
                unawaited(_save((c) => c.copyWith(assistantProvider: kind))),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              controller: _address,
              focusNode: _addressFocus,
              keyboardType: TextInputType.url,
              autocorrect: false,
              enableSuggestions: false,
              onChanged: _typed,
              onSubmitted: (_) => unawaited(_commitText()),
              decoration: InputDecoration(
                labelText: openAi
                    ? l10n.assistantAddressLabel
                    : l10n.assistantAddressLabelOptional,
                helperText: openAi
                    ? l10n.assistantAddressHelpOpenAi
                    : l10n.assistantAddressHelpAnthropic,
                helperMaxLines: 8,
                prefixIcon: const Icon(Icons.link),
              ),
            ),
          ),
          if (keyHost != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                l10n.assistantKeyDestination(keyHost),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              controller: _model,
              focusNode: _modelFocus,
              autocorrect: false,
              enableSuggestions: false,
              onChanged: _typed,
              onSubmitted: (_) => unawaited(_commitText()),
              decoration: InputDecoration(
                labelText: l10n.assistantModelLabel,
                hintText: l10n.assistantModelHint,
                prefixIcon: const Icon(Icons.memory_outlined),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: TextField(
              controller: _key,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              enableInteractiveSelection: true,
              onSubmitted: (_) => unawaited(_saveKey()),
              decoration: InputDecoration(
                labelText: l10n.assistantKeyLabel,
                helperText: hasKey
                    ? l10n.assistantKeySaved
                    : l10n.assistantKeyNone,
                helperMaxLines: 4,
                errorText: _keyError,
                errorMaxLines: 8,
                prefixIcon: const Icon(Icons.key_outlined),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonal(
                  onPressed: _keyBusy || _key.text.trim().isEmpty
                      ? null
                      : () => unawaited(_saveKey()),
                  child: Text(l10n.assistantKeySave),
                ),
                OutlinedButton(
                  onPressed: _keyBusy || !hasKey
                      ? null
                      : () => unawaited(_removeKey()),
                  child: Text(l10n.assistantKeyRemove),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              l10n.assistantKeyNote,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          ListTile(
            leading: Icon(
              problem == null
                  ? Icons.check_circle_outline
                  : Icons.info_outline,
              color: problem == null ? theme.colorScheme.primary : null,
            ),
            title: Text(problem ?? l10n.assistantStatusReady),
          ),
        ],
      ],
    );
  }
}
