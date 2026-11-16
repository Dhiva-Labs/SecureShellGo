import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../services/assistant/assistant_conversation.dart';
import '../services/visible_text.dart';
import '../theme.dart';

/// The widest the chat is drawn, so lines stay readable on a wide window.
const double assistantChatMaxWidth = 760;

/// Text from a model or a server, drawn so nothing in it can hide or reorder
/// what the user reads: control, bidirectional and invisible characters are
/// shown as stand-ins (see `visibleText`), exactly as the approval card does.
/// Plain text only: nothing is parsed as markdown and no link is tappable.
class AssistantSafeText extends StatelessWidget {
  const AssistantSafeText(
    this.text, {
    super.key,
    this.style,
    this.mono = false,
    this.softWrap = true,
  });

  final String text;
  final TextStyle? style;
  final bool mono;
  final bool softWrap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    var base = style ?? DefaultTextStyle.of(context).style;
    if (mono) {
      base = base.copyWith(
        fontFamily: AppTheme.monoFontFamily,
        fontFamilyFallback: AppTheme.monoFontFamilyFallback,
        fontSize: 13,
      );
    }
    final marker = base.copyWith(
      color: scheme.onTertiaryContainer,
      backgroundColor: scheme.tertiaryContainer,
      fontWeight: FontWeight.w700,
    );
    final rendered = visibleText(text);
    return SelectableText.rich(
      TextSpan(
        style: base,
        children: [
          for (final span in rendered.spans)
            TextSpan(text: span.text, style: span.escape ? marker : null),
        ],
      ),
    );
  }
}

/// The conversation as a list. The owner passes [controller] so it can keep
/// the newest item in view.
class AssistantTranscriptView extends StatelessWidget {
  const AssistantTranscriptView({
    super.key,
    required this.items,
    required this.controller,
  });

  final List<AssistantTranscriptItem> items;
  final ScrollController controller;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      controller: controller,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      itemCount: items.length,
      itemBuilder: (context, i) {
        final item = items[i];
        return Center(
          key: ValueKey<int>(item.id),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: assistantChatMaxWidth),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: switch (item) {
                AssistantUserItem() => _UserBubble(item.text),
                AssistantReplyItem() => _Reply(item.text),
                AssistantToolItem() => AssistantToolRow(item: item),
                AssistantNoticeItem() => _Notice(item),
              },
            ),
          ),
        );
      },
    );
  }
}

class _UserBubble extends StatelessWidget {
  const _UserBubble(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: AlignmentDirectional.centerEnd,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: (MediaQuery.sizeOf(context).width * 0.85).clamp(
            0,
            assistantChatMaxWidth * 0.85,
          ),
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: AssistantSafeText(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Reply extends StatelessWidget {
  const _Reply(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
        child: AssistantSafeText(text, style: theme.textTheme.bodyMedium),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice(this.item);
  final AssistantNoticeItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = item.isError
        ? theme.colorScheme.error
        : theme.colorScheme.onSurfaceVariant;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(
            item.isError ? Icons.error_outline : Icons.info_outline,
            size: 18,
            color: color,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            visibleText(item.text).text,
            style: theme.textTheme.bodyMedium?.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}

/// One tool call as a compact row: an icon for how it went, "tool on host",
/// the one-line summary, and, when pressed, the full result in a box that
/// scrolls sideways instead of wrapping.
class AssistantToolRow extends StatefulWidget {
  const AssistantToolRow({super.key, required this.item});
  final AssistantToolItem item;

  @override
  State<AssistantToolRow> createState() => _AssistantToolRowState();
}

class _AssistantToolRowState extends State<AssistantToolRow> {
  bool _open = false;

  Widget _statusIcon(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    switch (widget.item.status) {
      case AssistantToolStatus.running:
        return Semantics(
          label: l10n.assistantToolRunning,
          child: const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        );
      case AssistantToolStatus.done:
        return Icon(
          Icons.check_circle_outline,
          size: 20,
          color: scheme.primary,
          semanticLabel: l10n.assistantToolDone,
        );
      case AssistantToolStatus.failed:
        return Icon(
          Icons.error_outline,
          size: 20,
          color: scheme.error,
          semanticLabel: l10n.assistantToolFailed,
        );
      case AssistantToolStatus.stopped:
        return Icon(
          Icons.stop_circle_outlined,
          size: 20,
          color: scheme.onSurfaceVariant,
          semanticLabel: l10n.assistantToolStopped,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final item = widget.item;
    final name = visibleLine(item.name, maxChars: 60);
    final host = visibleLine(item.host, maxChars: 80);
    final title = host.isEmpty ? name : l10n.assistantToolOnHost(name, host);
    final summary = visibleLine(item.summary, maxChars: 300);
    final canOpen = item.detail.isNotEmpty;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: canOpen ? () => setState(() => _open = !_open) : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: _statusIcon(context),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelLarge,
                        ),
                        if (summary.isNotEmpty)
                          Text(
                            summary,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        if (item.awaitingApproval)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.hourglass_top,
                                  size: 14,
                                  color: theme.colorScheme.tertiary,
                                ),
                                const SizedBox(width: 4),
                                Flexible(
                                  child: Text(
                                    l10n.assistantWaitingForYes,
                                    style: theme.textTheme.labelMedium
                                        ?.copyWith(
                                          color: theme.colorScheme.tertiary,
                                          fontWeight: FontWeight.w700,
                                        ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (canOpen)
                    Icon(
                      _open ? Icons.expand_less : Icons.expand_more,
                      semanticLabel: _open
                          ? l10n.assistantToolHideDetail
                          : l10n.assistantToolShowDetail,
                    ),
                ],
              ),
            ),
          ),
          if (_open && canOpen)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 240),
                  child: Scrollbar(
                    child: SingleChildScrollView(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.all(8),
                        child: AssistantSafeText(
                          item.detail,
                          mono: true,
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
