import 'dart:async';

import 'package:flutter/material.dart';

import '../models/snippet.dart';
import '../services/session_controller.dart';
import '../services/snippet_placeholders.dart';
import '../services/snippet_store.dart';
import 'snippet_placeholder_dialog.dart';

/// Renders [snippet]'s command (asking for any `{name}` values first) and
/// sends it, plus a trailing newline, to [session]'s shell.
///
/// Pulled out as a free function rather than kept private to the picker
/// sheet below: the command palette (FEATURE 4) fires a snippet at the
/// active session the same way, without going through the picker's own list
/// UI a second time.
Future<void> runSnippetOnSession(
  BuildContext context, {
  required Snippet snippet,
  required SessionController session,
}) async {
  final parsed = parseSnippetCommand(snippet.command);
  var command = snippet.command;

  if (parsed.hasPlaceholders) {
    final values = await showSnippetPlaceholderDialog(
      context,
      snippetName: snippet.name,
      names: parsed.placeholderNames,
    );
    if (values == null) return; // Cancelled.
    command = parsed.render(values);
  }

  // `Terminal.paste` is the same seam the clipboard-paste path already uses
  // (see `terminal_pane.dart`) — it runs the text through
  // `SessionController`'s `onOutput` wiring exactly as if it had been typed,
  // with no change needed to `session_controller.dart` itself.
  session.terminal.paste('$command\n');
}

/// Opens a search-and-pick sheet over every saved snippet and sends the
/// chosen one to [session].
Future<void> showSnippetPicker(
  BuildContext context, {
  required SnippetStore snippetStore,
  required SessionController session,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => _SnippetPickerSheet(
      snippetStore: snippetStore,
      session: session,
    ),
  );
}

class _SnippetPickerSheet extends StatefulWidget {
  const _SnippetPickerSheet({
    required this.snippetStore,
    required this.session,
  });

  final SnippetStore snippetStore;
  final SessionController session;

  @override
  State<_SnippetPickerSheet> createState() => _SnippetPickerSheetState();
}

class _SnippetPickerSheetState extends State<_SnippetPickerSheet> {
  late Future<List<Snippet>> _future;
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _future = widget.snippetStore.all();
    _searchController.addListener(() {
      setState(() => _query = _searchController.text.trim().toLowerCase());
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<Snippet> _filter(List<Snippet> snippets) {
    if (_query.isEmpty) return snippets;
    return snippets
        .where((s) =>
            s.name.toLowerCase().contains(_query) ||
            s.command.toLowerCase().contains(_query) ||
            s.description.toLowerCase().contains(_query))
        .toList();
  }

  Future<void> _run(Snippet snippet) async {
    Navigator.of(context).pop();
    await runSnippetOnSession(context, snippet: snippet, session: widget.session);
  }

  @override
  Widget build(BuildContext context) {
    // Two-thirds of the screen height: enough to browse a long list without
    // covering the terminal it is about to send into entirely.
    final height = MediaQuery.sizeOf(context).height * 0.66;

    return SafeArea(
      child: SizedBox(
        height: height,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: TextField(
                controller: _searchController,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Search snippets',
                  prefixIcon: Icon(Icons.search),
                ),
              ),
            ),
            Expanded(
              child: FutureBuilder<List<Snippet>>(
                future: _future,
                builder: (context, snapshot) {
                  if (!snapshot.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final snippets = _filter(snapshot.data!);
                  if (snippets.isEmpty) {
                    return Center(
                      child: Text(
                        snapshot.data!.isEmpty
                            ? 'No snippets saved yet'
                            : 'No snippets match "$_query"',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    );
                  }
                  return ListView.separated(
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
                        onTap: () => unawaited(_run(snippet)),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
