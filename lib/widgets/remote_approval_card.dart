import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../services/bridge_remote/remote_bridge_controller.dart';
import '../services/visible_text.dart';
import '../theme.dart';
import 'bridge_approval_card.dart' show bridgeApprovalArmDelay;

/// One approval card of the computer, drawn on the phone.
///
/// The same visual language as the computer's card (`BridgeApprovalCard`):
/// what is asked in a monospace box, hidden characters shown as marked
/// stand-ins with the legend, a red frame for a terminal or a desktop, Deny
/// first, and Allow disabled for [armDelay] after the card appears so a tap
/// already on its way cannot approve something not yet read.
///
/// The text comes as `ControlVisibleText` spans the computer already made
/// safe (and the protocol decoder checked again); they are drawn as they are,
/// never run through `visibleText` a second time.
///
/// Unlike the computer's card this one is part of a list, not a dialog: the
/// answer travels to the computer and can fail ([onAnswer] returns how it
/// went). A failed answer is said under the buttons; the card is only done
/// once the computer sends it away.
class RemoteApprovalCard extends StatefulWidget {
  const RemoteApprovalCard({
    super.key,
    required this.approval,
    required this.onAnswer,
    this.timedMinutes = 0,
    this.clock = DateTime.now,
    this.armDelay = bridgeApprovalArmDelay,
  });

  final ControlApproval approval;

  /// Sends the answer to the computer and says how it went.
  final Future<RemoteActionResult> Function(ControlAnswer answer) onAnswer;

  /// The computer's "Allow for a while" length; 0 is off. "Allow for N
  /// minutes" is offered only when this is above 0 and the card itself says
  /// it may be (a terminal or a desktop never can).
  final int timedMinutes;

  final DateTime Function() clock;
  final Duration armDelay;

  @override
  State<RemoteApprovalCard> createState() => _RemoteApprovalCardState();
}

class _RemoteApprovalCardState extends State<RemoteApprovalCard> {
  Timer? _arm;
  Timer? _tick;
  bool _armed = false;

  /// An answer is on its way or was accepted: nothing more to tap.
  bool _busy = false;

  /// The computer refused the answer, and said so.
  RemoteActionResult? _failure;

  @override
  void initState() {
    super.initState();
    _arm = Timer(widget.armDelay, () {
      if (mounted) setState(() => _armed = true);
    });
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _arm?.cancel();
    _tick?.cancel();
    super.dispose();
  }

  Duration get _remaining {
    final left = widget.approval.expiresAt.difference(widget.clock());
    return left.isNegative ? Duration.zero : left;
  }

  bool get _expired => _remaining == Duration.zero;

  Future<void> _answer(ControlAnswer answer) async {
    if (_busy || _expired) return;
    if (answer != ControlAnswer.deny && !_armed) return;
    setState(() {
      _busy = true;
      _failure = null;
    });
    RemoteActionResult result;
    try {
      result = await widget.onAnswer(answer);
    } catch (_) {
      result = const RemoteActionResult.failed(ControlErrorCode.failed, '');
    }
    if (!mounted) return;
    setState(() {
      if (result.ok) return;
      _failure = result;
      // A card that is gone cannot be answered again; any other failure
      // leaves the buttons to try once more.
      _busy = result.code == ControlErrorCode.notFound;
    });
  }

  static String _clockText(Duration d) {
    final seconds = d.inSeconds + (d.inMilliseconds % 1000 > 0 ? 1 : 0);
    final m = seconds ~/ 60;
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  String _failureText(RemoteActionResult failure) {
    final l10n = context.l10n;
    return switch (failure.code) {
      ControlErrorCode.notFound => l10n.remoteAnswerGone,
      ControlErrorCode.locked => l10n.remoteLockedShort,
      _ =>
        (failure.message ?? '').isEmpty
            ? l10n.remoteActionFailedNoDetail
            : l10n.remoteActionFailed(failure.message!),
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final a = widget.approval;
    final isDesktop = a.kind == ControlApprovalKind.desktop;
    final isTerminal = a.kind == ControlApprovalKind.terminal || isDesktop;
    // A card this version cannot draw is never allowed from here: what it
    // asks for cannot be read.
    final unreadable = a.kind == ControlApprovalKind.other;
    final expired = _expired;
    final canAllow = _armed && !_busy && !expired && !unreadable;
    final canDeny = !_busy && !expired;
    final minutes = widget.timedMinutes;
    final timed = a.timedAllowed && minutes > 0 && !unreadable;
    final many = a.command != null && a.command!.hosts.length > 1;

    final title = switch (a.kind) {
      ControlApprovalKind.command when many => l10n.approvalTitleCommandMany(
        a.command!.hosts.length,
      ),
      ControlApprovalKind.command => l10n.approvalTitleCommand,
      ControlApprovalKind.fileWrite =>
        (a.file?.replacesExisting ?? false)
            ? l10n.approvalTitleFileReplace
            : l10n.approvalTitleFileNew,
      ControlApprovalKind.service => l10n.approvalTitleService,
      ControlApprovalKind.terminal => l10n.approvalTitleTerminal,
      ControlApprovalKind.desktop => l10n.approvalTitleDesktop,
      ControlApprovalKind.jobStart => l10n.approvalTitleJob,
      ControlApprovalKind.other => l10n.remoteApprovalOtherTitle,
    };

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: isTerminal ? scheme.error : scheme.outlineVariant,
          width: isTerminal ? 2 : 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
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
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    key: const ValueKey('approval-title'),
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _PartialWarning(file: a.file),
            Text(
              l10n.approvalAskedBy(a.assistant),
              key: const ValueKey('approval-assistant'),
              style: theme.textTheme.bodyLarge,
            ),
            const SizedBox(height: 4),
            ..._where(context, a, many),
            const SizedBox(height: 10),
            ..._what(context, a),
            const SizedBox(height: 10),
            Text(
              expired
                  ? l10n.approvalExpired
                  : l10n.approvalCountdown(_clockText(_remaining)),
              key: const ValueKey('approval-countdown'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            if (timed) ...[
              const SizedBox(height: 4),
              Text(
                many
                    ? l10n.approvalAllowForMinutesNoteMany(minutes)
                    : l10n.approvalAllowForMinutesNote(minutes, a.host),
                key: const ValueKey('approval-timed-note'),
                style: theme.textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 10),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(
                  key: const ValueKey('approval-deny'),
                  style: FilledButton.styleFrom(
                    backgroundColor: scheme.error,
                    foregroundColor: scheme.onError,
                  ),
                  onPressed: canDeny ? () => unawaited(_answer(ControlAnswer.deny)) : null,
                  child: Text(l10n.approvalDeny),
                ),
                if (!unreadable)
                  OutlinedButton(
                    key: const ValueKey('approval-allow-once'),
                    onPressed: canAllow
                        ? () => unawaited(_answer(ControlAnswer.once))
                        : null,
                    child: Text(l10n.approvalAllowOnce),
                  ),
                if (timed)
                  OutlinedButton(
                    key: const ValueKey('approval-allow-for-a-while'),
                    onPressed: canAllow
                        ? () => unawaited(_answer(ControlAnswer.forMinutes))
                        : null,
                    child: Text(l10n.approvalAllowForMinutes(minutes)),
                  ),
              ],
            ),
            if (_failure != null) ...[
              const SizedBox(height: 8),
              Text(
                _failureText(_failure!),
                key: const ValueKey('approval-failure'),
                style: TextStyle(color: scheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Where it will happen.
  List<Widget> _where(BuildContext context, ControlApproval a, bool many) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    if (many) {
      return [
        Text(l10n.approvalOnHosts, style: theme.textTheme.bodyLarge),
        for (final name in a.command!.hosts)
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 12, top: 2),
            child: Text(
              '• $name',
              key: const ValueKey('approval-host'),
              style: theme.textTheme.bodyLarge,
            ),
          ),
      ];
    }
    final hosts = a.command?.hosts;
    final shown = hosts != null && hosts.length == 1 ? hosts.single : a.host;
    return [
      Text(
        l10n.approvalOnHost(shown),
        key: const ValueKey('approval-host'),
        style: theme.textTheme.bodyLarge,
      ),
    ];
  }

  /// What will happen.
  List<Widget> _what(BuildContext context, ControlApproval a) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    switch (a.kind) {
      case ControlApprovalKind.command:
        final c = a.command;
        if (c == null) return [_unreadable(context, a)];
        return [
          Text(l10n.approvalCommandLabel, style: theme.textTheme.labelLarge),
          const SizedBox(height: 6),
          _SpanBox(text: c.command, boxKey: const ValueKey('approval-command')),
        ];
      case ControlApprovalKind.fileWrite:
        final f = a.file;
        if (f == null) return [_unreadable(context, a)];
        return _fileWhat(context, f);
      case ControlApprovalKind.service:
        final s = a.service;
        if (s == null) return [_unreadable(context, a)];
        final sentence = switch (s.action) {
          'start' => l10n.approvalServiceStart(s.unit),
          'stop' => l10n.approvalServiceStop(s.unit),
          'restart' => l10n.approvalServiceRestart(s.unit),
          'reload' => l10n.approvalServiceReload(s.unit),
          _ => l10n.approvalServiceOther(s.action, s.unit),
        };
        return [
          Text(
            sentence,
            key: const ValueKey('approval-service'),
            style: theme.textTheme.titleMedium,
          ),
        ];
      case ControlApprovalKind.jobStart:
        final j = a.job;
        if (j == null) return [_unreadable(context, a)];
        return [
          Text(l10n.approvalCommandLabel, style: theme.textTheme.labelLarge),
          const SizedBox(height: 6),
          _SpanBox(text: j.command, boxKey: const ValueKey('approval-command')),
          if (j.cwd != null) ...[
            const SizedBox(height: 8),
            Text(l10n.approvalJobCwdLabel, style: theme.textTheme.labelLarge),
            const SizedBox(height: 4),
            _SpanBox(
              text: j.cwd!,
              boxKey: const ValueKey('approval-job-cwd'),
              maxHeight: 96,
            ),
          ],
          if (j.name != null) ...[
            const SizedBox(height: 8),
            Text(
              l10n.approvalJobName(j.name!),
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
      case ControlApprovalKind.terminal:
        return [
          _RedWarning(
            title: l10n.approvalTerminalWarningTitle,
            text: l10n.approvalTerminalWarning,
            titleKey: const ValueKey('approval-terminal-warning'),
            textKey: const ValueKey('approval-terminal-text'),
          ),
        ];
      case ControlApprovalKind.desktop:
        return [
          _RedWarning(
            title: l10n.approvalDesktopWarningTitle,
            text: l10n.approvalDesktopWarning,
            titleKey: const ValueKey('approval-desktop-warning'),
            textKey: const ValueKey('approval-desktop-text'),
          ),
        ];
      case ControlApprovalKind.other:
        return [_unreadable(context, a)];
    }
  }

  /// A card whose details are missing or of a kind this version does not
  /// know: the tool's name and a pointer to the computer, and no Allow.
  Widget _unreadable(BuildContext context, ControlApproval a) {
    final l10n = context.l10n;
    return Text(
      l10n.remoteApprovalOtherBody(a.tool),
      key: const ValueKey('approval-unreadable'),
      style: Theme.of(context).textTheme.bodyMedium,
    );
  }

  List<Widget> _fileWhat(BuildContext context, ControlFileWrite file) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final human = _humanBytes(file.bytes);
    final kind = file.previewKind;
    final isDiff =
        kind == ControlPreviewKind.fullDiff ||
        kind == ControlPreviewKind.partialDiff;
    return [
      Text(l10n.approvalFilePath, style: theme.textTheme.labelLarge),
      const SizedBox(height: 4),
      _SpanBox(
        text: file.path,
        boxKey: const ValueKey('approval-path'),
        maxHeight: 96,
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
      if (kind != ControlPreviewKind.noPreview) ...[
        const SizedBox(height: 10),
        Text(
          isDiff ? l10n.approvalPreviewDiff : l10n.approvalPreviewContent,
          style: theme.textTheme.labelLarge,
        ),
        const SizedBox(height: 6),
        _SpanBox(
          text: file.preview,
          boxKey: const ValueKey('approval-preview'),
          emptyLabel: l10n.approvalPreviewEmpty,
        ),
      ],
    ];
  }

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

/// The warning of a file write whose preview is not the whole change, drawn
/// first so it is in view before anything else.
class _PartialWarning extends StatelessWidget {
  const _PartialWarning({required this.file});

  final ControlFileWrite? file;

  @override
  Widget build(BuildContext context) {
    final f = file;
    if (f == null || !f.previewIsPartial) return const SizedBox.shrink();
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (warnTitle, warnBody) = switch (f.previewKind) {
      ControlPreviewKind.noPreview => (
        l10n.approvalNoPreviewTitle,
        l10n.approvalNoPreviewBody,
      ),
      ControlPreviewKind.partialDiff => (
        l10n.approvalPartialDiffTitle,
        l10n.approvalPartialDiffBody,
      ),
      _ => (l10n.approvalPartialContentTitle, l10n.approvalPartialContentBody),
    };
    return Container(
      key: const ValueKey('approval-partial-warning'),
      padding: const EdgeInsets.all(12),
      margin: const EdgeInsets.only(bottom: 10),
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
}

/// The red box that says, before Allow, how much one yes hands over.
class _RedWarning extends StatelessWidget {
  const _RedWarning({
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
                  style: theme.textTheme.titleSmall?.copyWith(
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

/// [text]'s spans verbatim: monospace, selectable, scrollable, every hidden
/// character shown as the marked stand-in it arrived as, with the legend
/// when any is there. Always laid out left to right.
class _SpanBox extends StatefulWidget {
  const _SpanBox({
    required this.text,
    required this.boxKey,
    this.maxHeight = 200,
    this.emptyLabel,
  });

  final ControlVisibleText text;
  final Key boxKey;
  final double maxHeight;
  final String? emptyLabel;

  @override
  State<_SpanBox> createState() => _SpanBoxState();
}

class _SpanBoxState extends State<_SpanBox> {
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
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
                  child: text.spans.isEmpty && emptyLabel != null
                      ? Text(
                          emptyLabel,
                          style: mono.copyWith(fontStyle: FontStyle.italic),
                        )
                      : SelectableText.rich(
                          TextSpan(
                            style: mono,
                            children: [
                              for (final span in text.spans)
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
        if (text.hasEscapes) ...[
          const SizedBox(height: 8),
          _Legend(kinds: text.kinds),
        ],
      ],
    );
  }
}

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
