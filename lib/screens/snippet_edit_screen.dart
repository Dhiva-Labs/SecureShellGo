import 'package:flutter/material.dart';

import '../models/snippet.dart';
import '../services/snippet_store.dart';
import '../theme.dart';

/// Add or edit a saved snippet. [snippet] null means "add".
class SnippetEditScreen extends StatefulWidget {
  const SnippetEditScreen({
    super.key,
    required this.snippetStore,
    this.snippet,
  });

  final SnippetStore snippetStore;
  final Snippet? snippet;

  bool get isEditing => snippet != null;

  @override
  State<SnippetEditScreen> createState() => _SnippetEditScreenState();
}

class _SnippetEditScreenState extends State<SnippetEditScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _commandController = TextEditingController();
  final _descriptionController = TextEditingController();

  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final snippet = widget.snippet;
    if (snippet != null) {
      _nameController.text = snippet.name;
      _commandController.text = snippet.command;
      _descriptionController.text = snippet.description;
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _commandController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;

    FocusScope.of(context).unfocus();
    setState(() {
      _saving = true;
      _error = null;
    });

    final existing = widget.snippet;
    final snippet = Snippet(
      id: existing?.id ?? widget.snippetStore.newId(),
      name: _nameController.text.trim(),
      command: _commandController.text.trim(),
      description: _descriptionController.text.trim(),
    );

    try {
      if (widget.isEditing) {
        await widget.snippetStore.update(snippet);
      } else {
        await widget.snippetStore.add(snippet);
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Could not save this snippet.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isEditing ? 'Edit snippet' : 'Add snippet'),
      ),
      body: SafeArea(
        child: AbsorbPointer(
          absorbing: _saving,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 600),
              child: Form(
                key: _formKey,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                  children: [
                    TextFormField(
                      controller: _nameController,
                      decoration: const InputDecoration(
                        labelText: 'Name',
                        hintText: 'e.g. Tail app log',
                        prefixIcon: Icon(Icons.label_outline),
                      ),
                      textInputAction: TextInputAction.next,
                      validator: (value) =>
                          (value == null || value.trim().isEmpty)
                              ? 'Required'
                              : null,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _commandController,
                      minLines: 2,
                      maxLines: 6,
                      style: const TextStyle(
                        fontFamily: AppTheme.monoFontFamily,
                        fontFamilyFallback: AppTheme.monoFontFamilyFallback,
                        fontSize: 13,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'Command',
                        alignLabelWithHint: true,
                        hintText: 'tail -f /var/log/{app}.log',
                        helperText:
                            'Wrap a name in braces — {name} — to ask for it '
                            'each time this runs. Use {{ and }} for a '
                            'literal brace.',
                      ),
                      validator: (value) =>
                          (value == null || value.trim().isEmpty)
                              ? 'Required'
                              : null,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _descriptionController,
                      decoration: const InputDecoration(
                        labelText: 'Description (optional)',
                        prefixIcon: Icon(Icons.notes_outlined),
                      ),
                      textInputAction: TextInputAction.done,
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 16),
                      Text(
                        _error!,
                        style: const TextStyle(color: AppTheme.danger),
                      ),
                    ],
                    const SizedBox(height: 24),
                    FilledButton.icon(
                      onPressed: _saving ? null : _save,
                      icon: _saving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.save_outlined),
                      label: Text(_saving ? 'Saving…' : 'Save snippet'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
