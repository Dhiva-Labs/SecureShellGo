import 'package:flutter/material.dart';

import '../services/quick_connect_parser.dart';

/// A compact `user@host` field on the host list screen for connecting
/// somewhere without saving it first.
///
/// Purely a text field plus a parse-on-submit: it knows nothing about
/// [QuickConnectTarget]'s destination or how a connection actually gets
/// made — that is `host_list_screen.dart`'s job (see `_quickConnect`),
/// mirroring how this bar leaves an ephemeral host to whatever screen
/// prompts for its credentials.
class QuickConnectBar extends StatefulWidget {
  const QuickConnectBar({super.key, required this.onTarget});

  /// Called with a target once the input parses cleanly. Never called for
  /// bad input — that shows inline instead.
  final void Function(QuickConnectTarget target) onTarget;

  @override
  State<QuickConnectBar> createState() => _QuickConnectBarState();
}

class _QuickConnectBarState extends State<QuickConnectBar> {
  final _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text;
    if (text.trim().isEmpty) {
      setState(() => _error = null);
      return;
    }
    final result = parseQuickConnect(
      text,
      defaultUsername: defaultQuickConnectUsername(),
    );
    if (!result.isOk) {
      setState(() => _error = result.message);
      return;
    }
    setState(() => _error = null);
    _controller.clear();
    widget.onTarget(result.target!);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: TextField(
        controller: _controller,
        autocorrect: false,
        enableSuggestions: false,
        textCapitalization: TextCapitalization.none,
        textInputAction: TextInputAction.go,
        decoration: InputDecoration(
          isDense: true,
          hintText: 'Quick connect: user@host or user@host:port',
          prefixIcon: const Icon(Icons.bolt_outlined),
          errorText: _error,
          suffixIcon: IconButton(
            tooltip: 'Connect',
            icon: const Icon(Icons.arrow_forward),
            onPressed: _submit,
          ),
        ),
        onSubmitted: (_) => _submit(),
      ),
    );
  }
}
