import 'dart:async';

import 'package:flutter/material.dart';

import '../models/snippet.dart';
import '../services/snippet_store.dart';
import '../theme.dart';
import 'snippet_edit_screen.dart';

/// Lists every saved snippet and lets the user add, edit or delete one.
///
/// Reached from the settings screen — see `settings_screen.dart`. Sending a
/// snippet into a live session is a different flow entirely
/// (`widgets/snippet_picker.dart`, opened from the lightning-bolt icon on
/// the sessions screen's app bar); this screen only manages the saved list.
class SnippetsScreen extends StatefulWidget {
  const SnippetsScreen({super.key, required this.snippetStore});

  final SnippetStore snippetStore;

  @override
  State<SnippetsScreen> createState() => _SnippetsScreenState();
}

class _SnippetsScreenState extends State<SnippetsScreen> {
  late Future<List<Snippet>> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.snippetStore.all();
  }

  void _refresh() {
    setState(() => _future = widget.snippetStore.all());
  }

  Future<void> _addSnippet() => _editSnippet(null);

  Future<void> _editSnippet(Snippet? snippet) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => SnippetEditScreen(
          snippetStore: widget.snippetStore,
          snippet: snippet,
        ),
      ),
    );
    if (!mounted || saved != true) return;
    _refresh();
  }

  Future<void> _deleteSnippet(Snippet snippet) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete snippet?'),
        content: Text('This removes "${snippet.name}". This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.snippetStore.delete(snippet.id);
    if (!mounted) return;
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Snippets')),
      floatingActionButton: FloatingActionButton(
        onPressed: _addSnippet,
        tooltip: 'Add snippet',
        child: const Icon(Icons.add),
      ),
      body: FutureBuilder<List<Snippet>>(
        future: _future,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final snippets = snapshot.data!;
          if (snippets.isEmpty) return _EmptySnippets(onAdd: _addSnippet);
          return ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: snippets.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final snippet = snippets[index];
              return ListTile(
                leading: const Icon(Icons.bolt_outlined),
                title: Text(snippet.name),
                subtitle: Text(
                  snippet.command,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => unawaited(_editSnippet(snippet)),
                trailing: IconButton(
                  tooltip: 'Delete',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => unawaited(_deleteSnippet(snippet)),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _EmptySnippets extends StatelessWidget {
  const _EmptySnippets({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.bolt_outlined,
              size: 64,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
            ),
            const SizedBox(height: 20),
            Text('No snippets yet', style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              'Save a command once and fire it into any session from the '
              'lightning-bolt icon in the terminal.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add),
              label: const Text('Add snippet'),
            ),
          ],
        ),
      ),
    );
  }
}
