import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
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

    final failed = context.l10n.snippetsSaveFailed;
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
        _error = failed;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    String? required(String? value) =>
        (value == null || value.trim().isEmpty) ? l10n.snippetsRequired : null;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.isEditing ? l10n.snippetsEditTitle : l10n.snippetsAdd,
        ),
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
                      decoration: InputDecoration(
                        labelText: l10n.snippetsName,
                        hintText: l10n.snippetsNameHint,
                        prefixIcon: const Icon(Icons.label_outline),
                      ),
                      textInputAction: TextInputAction.next,
                      validator: required,
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
                      decoration: InputDecoration(
                        labelText: l10n.snippetsCommand,
                        alignLabelWithHint: true,
                        hintText: 'tail -f /var/log/{app}.log',
                        helperText:
                            l10n.snippetsCommandHelp('{name}', '{{', '}}'),
                        helperMaxLines: 8,
                      ),
                      validator: required,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _descriptionController,
                      decoration: InputDecoration(
                        labelText: l10n.snippetsDescription,
                        prefixIcon: const Icon(Icons.notes_outlined),
                      ),
                      textInputAction: TextInputAction.done,
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 16),
                      Text(
                        _error!,
                        style: TextStyle(color: theme.colorScheme.error),
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
                      label: Text(
                        _saving ? l10n.snippetsSaving : l10n.snippetsSave,
                      ),
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
