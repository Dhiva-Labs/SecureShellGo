import 'package:flutter/material.dart';

/// Asks for one value per name in [names], in order. Returns a map keyed by
/// name, or null if the user cancelled — the caller (`snippet_picker.dart`)
/// treats null as "do not send anything".
///
/// A blank value is allowed through: a placeholder the user means to leave
/// empty (clearing an optional argument) is their call, not this dialog's.
///
/// [confirmLabel] names what happens next: the terminal sends the command,
/// a fleet run only fills it in.
Future<Map<String, String>?> showSnippetPlaceholderDialog(
  BuildContext context, {
  required String snippetName,
  required List<String> names,
  String confirmLabel = 'Send',
}) {
  return showDialog<Map<String, String>>(
    context: context,
    builder: (context) => _PlaceholderDialog(
      snippetName: snippetName,
      names: names,
      confirmLabel: confirmLabel,
    ),
  );
}

/// Owns its text controllers, so they live exactly as long as the fields:
/// the dialog's closing animation still draws them after its future has
/// completed, and disposing them then tripped "used after being disposed".
class _PlaceholderDialog extends StatefulWidget {
  const _PlaceholderDialog({
    required this.snippetName,
    required this.names,
    required this.confirmLabel,
  });

  final String snippetName;
  final List<String> names;
  final String confirmLabel;

  @override
  State<_PlaceholderDialog> createState() => _PlaceholderDialogState();
}

class _PlaceholderDialogState extends State<_PlaceholderDialog> {
  late final Map<String, TextEditingController> _controllers = {
    for (final name in widget.names) name: TextEditingController(),
  };

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final names = widget.names;
    return AlertDialog(
      title: Text(widget.snippetName),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final name in names) ...[
              TextField(
                controller: _controllers[name],
                autofocus: name == names.first,
                decoration: InputDecoration(labelText: name),
              ),
              const SizedBox(height: 8),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop({
            for (final name in names) name: _controllers[name]!.text,
          }),
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
