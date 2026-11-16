import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/l10n.dart';
import '../services/bridge/bridge_approvals.dart';
import '../services/visible_text.dart';
import '../theme.dart';

/// How long the Allow buttons stay disabled after a card appears, and after
/// the request it shows changes: a key press or click already on its way
/// must not approve something the user has not had time to read.
const Duration bridgeApprovalArmDelay = Duration(seconds: 1);

/// The longest assistant or host name drawn on the card, in characters. The
/// assistant's name is chosen by whoever paired it; it is drawn through
/// [visibleText] and cut here so it cannot crowd out what is being asked.
const int _maxNameChars = 60;

/// The approval card: the one place where an AI assistant's request to
/// change something on a server becomes a decision.
///
/// Everything it says about WHAT will happen is built from the request's
/// summary, which the tool made from its validated arguments; nothing the
/// assistant wrote in prose reaches the card. Even the assistant's name and
/// the host's name go through [visibleText] first.
///
/// Safety properties, each covered by a test:
///
/// - **Deny** has the focus, so Enter and Space deny. Escape and the system
///   back gesture deny too.
/// - Both Allow buttons are disabled for [armDelay] after the card appears
///   (the widget is given a new key per request, so this restarts when the
///   shown request changes).
/// - Once one answer is given the card is inert: a second tap does nothing.
/// - A terminal never offers "Allow for a while".
/// - The card calls [onExpired] when the countdown ends; the service has
///   already denied by then, and the host closes the card.
class BridgeApprovalCard extends StatefulWidget {
  const BridgeApprovalCard({
    super.key,
    required this.request,
    required this.onAnswer,
    this.waiting = 0,
    this.timedMinutes = 0,
    this.onExpired,
    this.clock = DateTime.now,
    this.armDelay = bridgeApprovalArmDelay,
  });

  final BridgeApprovalRequest request;

  /// Called once, with the user's answer.
  final void Function(BridgeApprovalAnswer answer) onAnswer;

  /// How many other requests wait behind this one.
  final int waiting;

  /// `AppSettings.bridgeTimedApprovalMinutes`: the "Allow for N minutes"
  /// button is offered only when this is above 0 and the request is not a
  /// terminal.
  final int timedMinutes;

  /// Called when the countdown reaches zero.
  final VoidCallback? onExpired;

  final DateTime Function() clock;
  final Duration armDelay;

  @override
  State<BridgeApprovalCard> createState() => _BridgeApprovalCardState();
}

class _BridgeApprovalCardState extends State<BridgeApprovalCard> {
  Timer? _arm;
  Timer? _tick;
  bool _armed = false;
  bool _answered = false;
  bool _expired = false;

  @override
  void initState() {
    super.initState();
    _arm = Timer(widget.armDelay, () {
      if (mounted) setState(() => _armed = true);
    });
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
    _onTick(rebuild: false);
  }

  @override
  void dispose() {
    _arm?.cancel();
    _tick?.cancel();
    super.dispose();
  }

  Duration get _remaining {
    final left = widget.request.expiresAt.difference(widget.clock());
    return left.isNegative ? Duration.zero : left;
  }

  void _onTick({bool rebuild = true}) {
    if (!mounted) return;
    if (_remaining == Duration.zero && !_expired) {
      _expired = true;
      _tick?.cancel();
      // Disabled for good: the service has denied, nothing is left to allow.
      if (rebuild) setState(() {});
      widget.onExpired?.call();
      return;
    }
    if (rebuild) setState(() {});
  }

  void _answer(BridgeApprovalAnswer answer) {
    if (_answered || _expired) return;
    final allows = answer != BridgeApprovalAnswer.deny;
    if (allows && !_armed) return;
    setState(() => _answered = true);
    widget.onAnswer(answer);
  }

  static String _clockText(Duration d) {
    final seconds = d.inSeconds + (d.inMilliseconds % 1000 > 0 ? 1 : 0);
    final m = seconds ~/ 60;
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final request = widget.request;
    final summary = request.summary;
    final isDesktop = summary is DesktopSummary;
    // A desktop hands over as much as a terminal does: drawn as loudly, and
    // never allowed for a while.
    final isTerminal = summary is TerminalSummary || isDesktop;
    final canAllow = _armed && !_answered && !_expired;
    final assistant = visibleLine(request.client.name, maxChars: _maxNameChars);
    final host = visibleLine(request.hostName, maxChars: _maxNameChars);
    final timed = widget.timedMinutes > 0 && !isTerminal;

    final title = switch (summary) {
      CommandSummary(:final hostNames) when hostNames.length > 1 =>
        l10n.approvalTitleCommandMany(hostNames.length),
      CommandSummary() => l10n.approvalTitleCommand,
      FileWriteSummary(:final replacesExisting) =>
        replacesExisting
            ? l10n.approvalTitleFileReplace
            : l10n.approvalTitleFileNew,
      ServiceActionSummary() => l10n.approvalTitleService,
      TerminalSummary() => l10n.approvalTitleTerminal,
      DesktopSummary() => l10n.approvalTitleDesktop,
      JobStartSummary() => l10n.approvalTitleJob,
    };

    final warning = _partialWarning(context, summary);
    final body = <Widget>[
      ?warning,
      Text(
        l10n.approvalAskedBy(assistant),
        style: theme.textTheme.bodyLarge,
        key: const ValueKey('approval-assistant'),
      ),
      const SizedBox(height: 4),
      ..._where(context, summary, host),
      const SizedBox(height: 12),
      ..._what(context, summary, host),
    ];

    final minutes = widget.timedMinutes;
    // On a short window the countdown and the note scroll with the rest, so
    // the buttons and the text above them always fit.
    final compact = MediaQuery.sizeOf(context).height < 700;
    final info = <Widget>[
      Padding(
        padding: EdgeInsets.fromLTRB(
          compact ? 0 : 20,
          compact ? 12 : 8,
          compact ? 0 : 20,
          4,
        ),
        child: Text(
          _expired
              ? l10n.approvalExpired
              : l10n.approvalCountdown(_clockText(_remaining)),
          key: const ValueKey('approval-countdown'),
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ),
      if (timed)
        Padding(
          padding: EdgeInsets.fromLTRB(
            compact ? 0 : 20,
            0,
            compact ? 0 : 20,
            4,
          ),
          child: Text(
            _manyHosts(summary)
                ? l10n.approvalAllowForMinutesNoteMany(minutes)
                : l10n.approvalAllowForMinutesNote(minutes, host),
            key: const ValueKey('approval-timed-note'),
            style: theme.textTheme.bodySmall,
          ),
        ),
    ];
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        // The system back gesture or button, or a pop from anywhere: a no.
        if (!didPop) _answer(BridgeApprovalAnswer.deny);
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              _answer(BridgeApprovalAnswer.deny),
        },
        child: Dialog(
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 12,
          ),
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(
              color: isTerminal ? scheme.error : scheme.outlineVariant,
              width: isTerminal ? 2 : 1,
            ),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Semantics(
              scopesRoute: true,
              namesRoute: true,
              label: title,
              explicitChildNodes: true,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          isDesktop
                              ? Icons.desktop_windows_outlined
                              : isTerminal
                              ? Icons.terminal
                              : Icons.admin_panel_settings_outlined,
                          color: isTerminal ? scheme.error : scheme.primary,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            title,
                            key: const ValueKey('approval-title'),
                            style: theme.textTheme.titleLarge,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (widget.waiting > 0)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                      child: Text(
                        l10n.approvalWaitingMore(widget.waiting),
                        key: const ValueKey('approval-waiting'),
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [...body, if (compact) ...info],
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  if (!compact) ...info,
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
                    child: Wrap(
                      alignment: WrapAlignment.end,
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        // Deny leads and holds the focus: Enter and Space
                        // press it, never an Allow.
                        FilledButton(
                          key: const ValueKey('approval-deny'),
                          autofocus: true,
                          style: FilledButton.styleFrom(
                            backgroundColor: scheme.error,
                            foregroundColor: scheme.onError,
                          ),
                          onPressed: _answered || _expired
                              ? null
                              : () => _answer(BridgeApprovalAnswer.deny),
                          child: Text(l10n.approvalDeny),
                        ),
                        OutlinedButton(
                          key: const ValueKey('approval-allow-once'),
                          onPressed: canAllow
                              ? () => _answer(BridgeApprovalAnswer.allowOnce)
                              : null,
                          child: Text(l10n.approvalAllowOnce),
                        ),
                        if (timed)
                          OutlinedButton(
                            key: const ValueKey('approval-allow-for-a-while'),
                            onPressed: canAllow
                                ? () => _answer(
                                    BridgeApprovalAnswer.allowForAWhile,
                                  )
                                : null,
                            child: Text(l10n.approvalAllowForMinutes(minutes)),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  static bool _manyHosts(BridgeChangeSummary s) =>
      s is CommandSummary && s.hostNames.length > 1;

  /// Where it will happen: the host, or every host of a multi-host command.
  List<Widget> _where(
    BuildContext context,
    BridgeChangeSummary summary,
    String host,
  ) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    if (summary is CommandSummary && summary.hostNames.length > 1) {
      return [
        Text(l10n.approvalOnHosts, style: theme.textTheme.bodyLarge),
        for (final name in summary.hostNames)
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 12, top: 2),
            child: Text(
              '• ${visibleLine(name, maxChars: _maxNameChars)}',
              key: const ValueKey('approval-host'),
              style: theme.textTheme.bodyLarge,
            ),
          ),
      ];
    }
    final shown = summary is CommandSummary && summary.hostNames.length == 1
        ? visibleLine(summary.hostNames.single, maxChars: _maxNameChars)
        : host;
    return [
      Text(
        l10n.approvalOnHost(shown),
        key: const ValueKey('approval-host'),
        style: theme.textTheme.bodyLarge,
      ),
    ];
  }

  /// What will happen, from the summary alone.
  List<Widget> _what(
    BuildContext context,
    BridgeChangeSummary summary,
    String host,
  ) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    switch (summary) {
      case CommandSummary(:final command):
        return [
          Text(l10n.approvalCommandLabel, style: theme.textTheme.labelLarge),
          const SizedBox(height: 6),
          _VerbatimBox(
            text: command,
            boxKey: const ValueKey('approval-command'),
          ),
        ];
      case FileWriteSummary():
        return _fileWhat(context, summary);
      case ServiceActionSummary(:final unit, :final action):
        final u = visibleLine(unit, maxChars: 200);
        final sentence = switch (action) {
          'start' => l10n.approvalServiceStart(u),
          'stop' => l10n.approvalServiceStop(u),
          'restart' => l10n.approvalServiceRestart(u),
          'reload' => l10n.approvalServiceReload(u),
          _ => l10n.approvalServiceOther(visibleLine(action, maxChars: 40), u),
        };
        return [
          Text(
            sentence,
            key: const ValueKey('approval-service'),
            style: theme.textTheme.titleMedium,
          ),
        ];
      case JobStartSummary(:final command, :final cwd, :final name):
        // The command exactly as on a run_command card, then where it
        // starts and that it outlives the call.
        return [
          Text(l10n.approvalCommandLabel, style: theme.textTheme.labelLarge),
          const SizedBox(height: 6),
          _VerbatimBox(
            text: command,
            boxKey: const ValueKey('approval-command'),
          ),
          if (cwd != null) ...[
            const SizedBox(height: 8),
            Text(l10n.approvalJobCwdLabel, style: theme.textTheme.labelLarge),
            const SizedBox(height: 4),
            _VerbatimBox(
              text: cwd,
              boxKey: const ValueKey('approval-job-cwd'),
              maxHeight: 96,
              breakLines: false,
            ),
          ],
          if (name != null) ...[
            const SizedBox(height: 8),
            Text(
              l10n.approvalJobName(visibleLine(name, maxChars: _maxNameChars)),
              key: const ValueKey('approval-job-name'),
              style: theme.textTheme.bodyLarge,
            ),
          ],
          const SizedBox(height: 8),
          Text(
            l10n.approvalJobNote,
            key: const ValueKey('approval-job-note'),
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ];
      case DesktopSummary():
        return [
          _FullControlWarning(
            title: l10n.approvalDesktopWarningTitle,
            text: l10n.approvalDesktopWarning,
            titleKey: const ValueKey('approval-desktop-warning'),
            textKey: const ValueKey('approval-desktop-text'),
          ),
        ];
      case TerminalSummary():
        return [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: scheme.errorContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      color: scheme.onErrorContainer,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        l10n.approvalTerminalWarningTitle,
                        key: const ValueKey('approval-terminal-warning'),
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: scheme.onErrorContainer,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  l10n.approvalTerminalWarning,
                  key: const ValueKey('approval-terminal-text'),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onErrorContainer,
                  ),
                ),
              ],
            ),
          ),
        ];
    }
  }

  /// The warning of a file write whose preview is not the whole change, or
  /// null. Drawn first on the card, above who asks and where, so that it is
  /// in view without scrolling even on a small screen with large text.
  Widget? _partialWarning(BuildContext context, BridgeChangeSummary summary) {
    if (summary is! FileWriteSummary || !summary.previewIsPartial) return null;
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (warnTitle, warnBody) = switch (summary.previewKind) {
      FileWritePreviewKind.noPreview => (
        l10n.approvalNoPreviewTitle,
        l10n.approvalNoPreviewBody,
      ),
      FileWritePreviewKind.partialDiff => (
        l10n.approvalPartialDiffTitle,
        l10n.approvalPartialDiffBody,
      ),
      _ => (l10n.approvalPartialContentTitle, l10n.approvalPartialContentBody),
    };
    return Container(
      key: const ValueKey('approval-partial-warning'),
      padding: const EdgeInsets.all(12),
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, color: scheme.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  warnTitle,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: scheme.onErrorContainer,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  warnBody,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onErrorContainer,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _fileWhat(BuildContext context, FileWriteSummary file) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final human = _humanBytes(file.bytes);
    final kind = file.previewKind;
    final isDiff =
        kind == FileWritePreviewKind.fullDiff ||
        kind == FileWritePreviewKind.partialDiff;
    return [
      Text(l10n.approvalFilePath, style: theme.textTheme.labelLarge),
      const SizedBox(height: 4),
      _VerbatimBox(
        text: file.path,
        boxKey: const ValueKey('approval-path'),
        maxHeight: 96,
        breakLines: false,
      ),
      const SizedBox(height: 8),
      Text(
        human == null
            ? l10n.approvalFileSize(file.bytes)
            : l10n.approvalFileSizeHuman(file.bytes, human),
        key: const ValueKey('approval-size'),
        style: theme.textTheme.bodyLarge,
      ),
      const SizedBox(height: 4),
      Text(
        file.replacesExisting
            ? l10n.approvalFileReplaces
            : l10n.approvalFileCreates,
        key: const ValueKey('approval-replaces'),
        style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 12),
      if (kind != FileWritePreviewKind.noPreview) ...[
        Text(
          isDiff ? l10n.approvalPreviewDiff : l10n.approvalPreviewContent,
          style: theme.textTheme.labelLarge,
        ),
        const SizedBox(height: 6),
        _VerbatimBox(
          text: file.preview,
          boxKey: const ValueKey('approval-preview'),
          emptyLabel: l10n.approvalPreviewEmpty,
        ),
      ],
    ];
  }

  /// "12.3 KiB" for sizes of 1 KiB and up, otherwise null (the byte count
  /// says it all).
  static String? _humanBytes(int bytes) {
    if (bytes < 1024) return null;
    const units = ['KiB', 'MiB', 'GiB'];
    var value = bytes / 1024;
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(value >= 10 ? 0 : 1)} ${units[unit]}';
  }
}

/// [text] verbatim: monospace, selectable, scrollable, every hidden
/// character shown as a marked stand-in, with the legend when any is there.
///
/// Always laid out left to right, so the paragraph direction never comes
/// from the locale or the text; and its scrollbar always shows when there is
/// more than fits, so the user can tell the box goes on.
class _VerbatimBox extends StatefulWidget {
  const _VerbatimBox({
    required this.text,
    required this.boxKey,
    this.maxHeight = 220,
    this.breakLines = true,
    this.emptyLabel,
  });

  final String text;
  final Key boxKey;
  final double maxHeight;
  final bool breakLines;
  final String? emptyLabel;

  @override
  State<_VerbatimBox> createState() => _VerbatimBoxState();
}

class _VerbatimBoxState extends State<_VerbatimBox> {
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final text = widget.text;
    final emptyLabel = widget.emptyLabel;
    final rendered = visibleText(text, breakLines: widget.breakLines);
    final mono = TextStyle(
      fontFamily: AppTheme.monoFontFamily,
      fontFamilyFallback: AppTheme.monoFontFamilyFallback,
      fontSize: 13,
      color: scheme.onSurface,
    );
    final marker = mono.copyWith(
      color: scheme.onTertiaryContainer,
      backgroundColor: scheme.tertiaryContainer,
      fontWeight: FontWeight.w700,
    );
    final children = <Widget>[
      Directionality(
        textDirection: TextDirection.ltr,
        child: Container(
          key: widget.boxKey,
          constraints: BoxConstraints(maxHeight: widget.maxHeight),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Scrollbar(
            controller: _scroll,
            thumbVisibility: true,
            child: SingleChildScrollView(
              controller: _scroll,
              padding: const EdgeInsets.all(10),
              child: SizedBox(
                width: double.infinity,
                child: text.isEmpty && emptyLabel != null
                    ? Text(
                        emptyLabel,
                        style: mono.copyWith(fontStyle: FontStyle.italic),
                      )
                    : SelectableText.rich(
                        TextSpan(
                          style: mono,
                          children: [
                            for (final span in rendered.spans)
                              TextSpan(
                                text: span.text,
                                style: span.escape ? marker : null,
                              ),
                          ],
                        ),
                      ),
              ),
            ),
          ),
        ),
      ),
    ];
    if (rendered.hasEscapes) {
      children
        ..add(const SizedBox(height: 8))
        ..add(_Legend(kinds: rendered.kinds));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }
}

/// The red box that says, before Allow, how much one yes hands over (the
/// desktop's; the terminal draws its own the same way).
class _FullControlWarning extends StatelessWidget {
  const _FullControlWarning({
    required this.title,
    required this.text,
    required this.titleKey,
    required this.textKey,
  });

  final String title;
  final String text;
  final Key titleKey;
  final Key textKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: scheme.onErrorContainer),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  key: titleKey,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: scheme.onErrorContainer,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            text,
            key: textKey,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onErrorContainer,
            ),
          ),
        ],
      ),
    );
  }
}

/// The small legend under text that had hidden characters.
class _Legend extends StatelessWidget {
  const _Legend({required this.kinds});

  final Set<VisibleKind> kinds;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final lines = <String>[
      if (kinds.contains(VisibleKind.lineBreak)) l10n.approvalLegendLineBreak,
      if (kinds.contains(VisibleKind.control)) l10n.approvalLegendControl,
      if (kinds.contains(VisibleKind.bidi)) l10n.approvalLegendBidi,
      if (kinds.contains(VisibleKind.invisible)) l10n.approvalLegendInvisible,
      if (kinds.contains(VisibleKind.space)) l10n.approvalLegendSpace,
      if (kinds.contains(VisibleKind.invalid)) l10n.approvalLegendInvalid,
      if (kinds.contains(VisibleKind.combining)) l10n.approvalLegendCombining,
    ];
    return Column(
      key: const ValueKey('approval-legend'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.approvalLegendTitle,
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        for (final line in lines)
          Text(
            line,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }
}
