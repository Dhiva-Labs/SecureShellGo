import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../models/host.dart';
import '../models/host_ai_edit.dart';
import 'host_ai_level_picker.dart';

/// The "AI access" section of one host: a title, the level picker
/// ([HostAiLevelPicker]) and, when the form holds a choice that is not saved
/// yet, a small "Not saved yet" hint beside the title. Shared by the host edit
/// screen and the per-host sheet in the shared-hosts list.
///
/// It edits a [HostAiEdit] in place and tells the parent through [onChanged];
/// the parent writes with [HostAiEdit.applyTo] against the host as the store
/// holds it at that moment. Nothing is saved here, which the hint says.
class HostAiControls extends StatefulWidget {
  const HostAiControls({
    super.key,
    required this.edit,
    required this.onChanged,
    this.loadStored,
    this.showTitle = true,
    this.showUnsavedHint = true,
  });

  final HostAiEdit edit;
  final VoidCallback onChanged;

  /// The host as the store holds it now, for listing the commands that would
  /// come into force. Null for a host not saved yet.
  final Future<Host?> Function()? loadStored;

  /// Whether the "AI access" title is part of this view (a sheet has its own
  /// title).
  final bool showTitle;

  /// Whether to say "Not saved yet" while the choice differs from the saved
  /// one. A view that saves on its own button turns it off.
  final bool showUnsavedHint;

  @override
  State<HostAiControls> createState() => _HostAiControlsState();
}

class _HostAiControlsState extends State<HostAiControls> {
  /// What the controls showed when this edit was opened: a new [HostAiEdit]
  /// (after a save the screen starts a fresh one on the saved host) restarts
  /// the comparison.
  late Object _saved = widget.edit.signature;

  @override
  void didUpdateWidget(HostAiControls old) {
    super.didUpdateWidget(old);
    if (!identical(old.edit, widget.edit)) _saved = widget.edit.signature;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final unsaved = widget.showUnsavedHint && widget.edit.signature != _saved;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.showTitle || unsaved)
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 4),
            child: Row(
              children: [
                Expanded(
                  child: widget.showTitle
                      ? Text(
                          l10n.hostAiSectionTitle,
                          style: theme.textTheme.titleMedium,
                        )
                      : const SizedBox.shrink(),
                ),
                if (unsaved)
                  Text(
                    l10n.hostAiUnsaved,
                    key: const ValueKey('ai-unsaved'),
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.tertiary,
                    ),
                  ),
              ],
            ),
          ),
        HostAiLevelPicker(
          edit: widget.edit,
          // Redraws the hint too, whether or not the parent rebuilds.
          onChanged: () {
            setState(() {});
            widget.onChanged();
          },
          loadStored: widget.loadStored,
        ),
      ],
    );
  }
}
