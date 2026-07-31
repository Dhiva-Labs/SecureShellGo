import 'package:flutter/material.dart';

/// Asks for one value per name in [names], in order. Returns a map keyed by
/// name, or null if the user cancelled — the caller (`snippet_picker.dart`)
/// treats null as "do not send anything".
///
/// A blank value is allowed through: a placeholder the user means to leave
/// empty (clearing an optional argument) is their call, not this dialog's.
Future<Map<String, String>?> showSnippetPlaceholderDialog(
  BuildContext context, {
  required String snippetName,
  required List<String> names,
}) {
  final controllers = {for (final name in names) name: TextEditingController()};

  return showDialog<Map<String, String>>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(snippetName),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final name in names) ...[
              TextField(
                controller: controllers[name],
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
            for (final name in names) name: controllers[name]!.text,
          }),
          child: const Text('Send'),
        ),
      ],
    ),
  ).whenComplete(() {
    for (final controller in controllers.values) {
      controller.dispose();
    }
  });
}
