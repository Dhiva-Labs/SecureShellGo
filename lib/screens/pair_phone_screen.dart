import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/l10n.dart';
import '../services/bridge/bridge_client_store.dart';
import '../theme.dart';

/// Pairing a phone: its name, then the token, shown once, with the three
/// things to do on the phone.
///
/// A phone's pairing is a [BridgeClientRole.controller]: it can answer
/// approval cards and stop things, and can never call a tool.
class PairPhoneScreen extends StatefulWidget {
  const PairPhoneScreen({super.key, required this.clients});

  final BridgeClientStore clients;

  @override
  State<PairPhoneScreen> createState() => _PairPhoneScreenState();
}

class _PairPhoneScreenState extends State<PairPhoneScreen> {
  final _name = TextEditingController();
  bool _busy = false;
  String? _error;

  /// Held only here, only in memory, and gone with this screen: the store
  /// keeps its hash and nothing else.
  String? _token;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  /// Asked when leaving with the token on screen: it is shown once, and
  /// nothing can bring it back.
  Future<void> _confirmLeave() async {
    final l10n = context.l10n;
    final leave = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.bridgeConnectLeaveTitle),
        content: Text(l10n.pairPhoneLeaveBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.bridgeConnectLeaveStay),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.bridgeConnectLeaveConfirm),
          ),
        ],
      ),
    );
    if (leave == true && mounted) Navigator.of(context).pop();
  }

  Future<void> _create() async {
    final l10n = context.l10n;
    setState(() {
      _busy = true;
      _error = null;
    });
    final name = _name.text.trim().isEmpty
        ? l10n.pairPhoneDefaultName
        : _name.text;
    try {
      final created = await widget.clients.create(
        name,
        role: BridgeClientRole.controller,
      );
      if (!mounted) return;
      setState(() {
        _token = created.token;
        _busy = false;
      });
    } catch (e) {
      // The store keeps nothing it could not write, so nothing is paired.
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = l10n.bridgeConnectFailed('$e');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final token = _token;
    return PopScope(
      canPop: token == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_confirmLeave());
      },
      child: Scaffold(
        appBar: AppBar(title: Text(l10n.pairPhoneTitle)),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: token == null
                    ? _form(context)
                    : _result(context, token),
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _form(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return [
      Text(l10n.pairPhoneNameIntro),
      const SizedBox(height: 12),
      TextField(
        key: const ValueKey('pair-phone-name'),
        controller: _name,
        enabled: !_busy,
        textInputAction: TextInputAction.done,
        decoration: InputDecoration(
          labelText: l10n.pairPhoneNameLabel,
          hintText: l10n.pairPhoneNameHint,
          prefixIcon: const Icon(Icons.phone_android),
        ),
        onSubmitted: (_) {
          if (!_busy) unawaited(_create());
        },
      ),
      if (_error != null) ...[
        const SizedBox(height: 12),
        Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
      ],
      const SizedBox(height: 20),
      FilledButton(
        key: const ValueKey('pair-phone-create'),
        onPressed: _busy ? null : () => unawaited(_create()),
        child: _busy
            ? const SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Text(l10n.pairPhoneCreate),
      ),
    ];
  }

  List<Widget> _result(BuildContext context, String token) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    Widget step(int n, String text) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 11,
            backgroundColor: theme.colorScheme.primaryContainer,
            child: Text(
              '$n',
              style: TextStyle(
                fontSize: 12,
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(text)),
        ],
      ),
    );
    return [
      Card(
        color: theme.colorScheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.warning_amber_outlined,
                color: theme.colorScheme.onErrorContainer,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.bridgeConnectTokenOnceTitle,
                      key: const ValueKey('pair-phone-once'),
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: theme.colorScheme.onErrorContainer,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      l10n.pairPhoneTokenOnceBody,
                      style: TextStyle(
                        color: theme.colorScheme.onErrorContainer,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 16),
      Text(l10n.bridgeConnectTokenLabel, style: theme.textTheme.labelLarge),
      const SizedBox(height: 4),
      _TokenBox(token),
      const SizedBox(height: 20),
      Text(l10n.pairPhoneStepsTitle, style: theme.textTheme.titleSmall),
      const SizedBox(height: 8),
      step(1, l10n.pairPhoneStep1),
      step(2, l10n.pairPhoneStep2),
      step(3, l10n.pairPhoneStep3),
      const SizedBox(height: 16),
      FilledButton(
        key: const ValueKey('pair-phone-done'),
        // The user's own "I have it": no second question.
        onPressed: () => Navigator.of(context).pop(),
        child: Text(l10n.bridgeConnectDone),
      ),
    ];
  }
}

/// The token in a monospace box the user can select, with a Copy button.
class _TokenBox extends StatelessWidget {
  const _TokenBox(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 0, 10),
              child: SelectableText(
                text,
                key: const ValueKey('pair-phone-token'),
                style: TextStyle(
                  fontFamily: AppTheme.monoFontFamily,
                  fontFamilyFallback: AppTheme.monoFontFamilyFallback,
                  fontSize: 12.5,
                  height: 1.35,
                ),
              ),
            ),
          ),
          IconButton(
            key: const ValueKey('pair-phone-copy'),
            tooltip: MaterialLocalizations.of(context).copyButtonLabel,
            icon: const Icon(Icons.copy_all_outlined, size: 20),
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(context);
              final copied = l10n.bridgeConnectCopied;
              await Clipboard.setData(ClipboardData(text: text));
              messenger.showSnackBar(SnackBar(content: Text(copied)));
            },
          ),
        ],
      ),
    );
  }
}
