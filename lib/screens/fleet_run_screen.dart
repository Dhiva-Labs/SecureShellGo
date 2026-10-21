import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/host.dart';
import '../models/snippet.dart';
import '../services/credential_store.dart';
import '../services/fleet_exec_service.dart';
import '../services/host_grouping.dart';
import '../services/session_manager.dart';
import '../services/snippet_placeholders.dart';
import '../services/snippet_store.dart';
import '../services/ssh_service.dart';
import '../theme.dart';
import '../widgets/snippet_placeholder_dialog.dart';

/// Runs one command on many servers: pick the hosts (or whole groups), write
/// the command or take a snippet, confirm against the exact list of hosts,
/// then watch every host's output and exit status come in.
///
/// Reached from the host list — its selection bar's "Run command…", or a
/// group's own menu — with those hosts already ticked. One route for all
/// three steps, like `FleetPushScreen`: back from the results has nowhere
/// better to go than the list it came from.
class FleetRunScreen extends StatefulWidget {
  const FleetRunScreen({
    super.key,
    required this.hosts,
    required this.initialHostIds,
    required this.sessions,
    required this.credentialStore,
    required this.sshService,
    this.snippetStore,
    this.dialer,
    this.initialCommand = '',
  });

  /// Every saved host, for the picker.
  final List<Host> hosts;

  /// Ticked when the screen opens.
  final Set<String> initialHostIds;

  final SessionManager sessions;
  final CredentialStore credentialStore;
  final SshService sshService;

  /// Offers saved snippets as commands. Null hides the button.
  final SnippetStore? snippetStore;

  /// Test seam; production dials through [sshService].
  final FleetExecDialer? dialer;

  final String initialCommand;

  @override
  State<FleetRunScreen> createState() => _FleetRunScreenState();
}

enum _Step { setup, confirm, results }

class _FleetRunScreenState extends State<FleetRunScreen> {
  var _step = _Step.setup;
  late final Set<String> _selected = {...widget.initialHostIds};
  late final TextEditingController _command =
      TextEditingController(text: widget.initialCommand);
  FleetExecService? _service;

  @override
  void dispose() {
    _command.dispose();
    final service = _service;
    if (service != null) {
      // Left while still going, by choice — see [_confirmLeave]: what has
      // started runs to the end with nobody watching, and is let go of
      // then. Nothing new starts once nobody is here to see it or stop it.
      if (service.isRunning) {
        service.cancelQueued();
        unawaited(service.done.then((_) => service.dispose()));
      } else {
        service.dispose();
      }
    }
    super.dispose();
  }

  List<Host> get _chosen =>
      widget.hosts.where((h) => _selected.contains(h.id)).toList();

  bool get _canContinue =>
      _selected.isNotEmpty && _command.text.trim().isNotEmpty;

  void _start() {
    final service = FleetExecService(
      hosts: _chosen,
      command: _command.text.trim(),
      openTransport: _openTransport,
      credentialLookup: widget.credentialStore.load,
      dialer: widget.dialer ?? _dial,
    );
    _service = service;
    setState(() => _step = _Step.results);
    service.start();
  }

  SessionTransport? _openTransport(String hostId) {
    for (final session in widget.sessions.liveForHost(hostId)) {
      final transport = session.controller.connection;
      if (!transport.isClosed) return transport;
    }
    return null;
  }

  /// Signs in with what is saved and nobody to ask. What would have needed
  /// a person — a question at login, a host key not yet trusted — comes
  /// back as [FleetSignInNeedsPerson], so the host is skipped with a reason
  /// rather than reported as broken.
  Future<SessionTransport> _dial(Host host, SshCredentials credentials) async {
    HostKeyPrompt? key;
    LoginPrompt? asked;
    try {
      return await widget.sshService.connect(
        host: host,
        credentials: credentials,
        verifyHostKey: (prompt) async {
          key ??= prompt;
          return false;
        },
        answerPrompts: (prompt) async {
          asked ??= prompt;
          return null;
        },
      );
    } on SshConnectionException {
      final keyPrompt = key;
      if (keyPrompt != null) {
        if (keyPrompt.kind == HostKeyPromptKind.changed) {
          throw SshConnectionException(
            'The host key of ${keyPrompt.hostLabel} has CHANGED since it was '
            'trusted. Not connecting — check it from the host list.',
          );
        }
        throw FleetSignInNeedsPerson(
          'The host key of ${keyPrompt.hostLabel} has not been checked yet. '
          'Connect once from the host list to check and trust it.',
        );
      }
      final prompt = asked;
      if (prompt != null) {
        final who = prompt.jumpHostFor == null
            ? 'It'
            : 'Its jump host "${prompt.host.displayName}"';
        if (prompt.savedPasswordRejected) {
          throw FleetSignInNeedsPerson(
            '$who turned the saved password down and asks for another.',
          );
        }
        final label = prompt.fields.isEmpty ? '' : prompt.fields.first.label;
        throw FleetSignInNeedsPerson(
          label.isEmpty
              ? '$who asks a question at login, which needs you.'
              : '$who asks "$label" at login, which needs you.',
        );
      }
      rethrow;
    }
  }

  Future<void> _pickSnippet() async {
    final store = widget.snippetStore;
    if (store == null) return;
    final snippets = await store.all();
    if (!mounted) return;
    final chosen = await showModalBottomSheet<Snippet>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _SnippetSheet(snippets: snippets),
    );
    if (chosen == null || !mounted) return;
    var command = chosen.command;
    final parsed = parseSnippetCommand(command);
    if (parsed.hasPlaceholders) {
      final values = await showSnippetPlaceholderDialog(
        context,
        snippetName: chosen.name,
        names: parsed.placeholderNames,
        confirmLabel: 'Use',
      );
      if (values == null || !mounted) return;
      command = parsed.render(values);
    }
    setState(() => _command.text = command);
  }

  Future<bool> _confirmRerun(List<FleetExecHostRun> runs) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          'Run again on ${runs.length} host${runs.length == 1 ? '' : 's'}?',
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _CommandBox(command: _service!.command),
              const SizedBox(height: 12),
              for (final run in runs) Text('•  ${run.label}'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Run again'),
          ),
        ],
      ),
    );
    return yes == true;
  }

  /// What leaving does to a run that is still going.
  Future<void> _confirmLeave() async {
    final service = _service!;
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Still running'),
        content: const Text(
          'Leave the command running on the servers where it has started, '
          'or stop it there? Hosts still waiting their turn will not start '
          'once you leave.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Keep watching'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop('stop'),
            child: const Text('Stop and leave'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop('leave'),
            child: const Text('Leave it running'),
          ),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == 'stop') service.cancel();
    if (choice == 'leave') service.cancelQueued();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final running = _step == _Step.results && (_service?.isRunning ?? false);
    return PopScope(
      canPop: !running && _step != _Step.confirm,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_step == _Step.confirm) {
          setState(() => _step = _Step.setup);
        } else {
          unawaited(_confirmLeave());
        }
      },
      child: switch (_step) {
        _Step.setup => _buildSetup(context),
        _Step.confirm => _buildConfirm(context),
        _Step.results => _FleetResults(
            service: _service!,
            onRerun: (runs) async {
              if (await _confirmRerun(runs)) {
                _service!.rerun(runs.map((r) => r.hostId));
              }
            },
          ),
      },
    );
  }

  Widget _buildSetup(BuildContext context) {
    final theme = Theme.of(context);
    final sections = HostGrouping.buildSections(widget.hosts);
    return Scaffold(
      appBar: AppBar(title: const Text('Run command')),
      body: _readable(SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            Text('Command', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('fleetCommand'),
              controller: _command,
              minLines: 2,
              maxLines: 6,
              style: const TextStyle(
                fontFamily: AppTheme.monoFontFamily,
                fontFamilyFallback: AppTheme.monoFontFamilyFallback,
                fontSize: 14,
              ),
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'uptime',
                helperText: 'Runs in each account\'s own shell, with no '
                    'input and no terminal.',
                helperMaxLines: 3,
              ),
              onChanged: (_) => setState(() {}),
            ),
            if (widget.snippetStore != null) ...[
              const SizedBox(height: 8),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: OutlinedButton.icon(
                  onPressed: () => unawaited(_pickSnippet()),
                  icon: const Icon(Icons.bolt_outlined, size: 18),
                  label: const Text('From a snippet…'),
                ),
              ),
            ],
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Hosts · ${_selected.length} chosen',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                TextButton(
                  onPressed: _selected.length == widget.hosts.length
                      ? () => setState(_selected.clear)
                      : () => setState(() =>
                          _selected.addAll(widget.hosts.map((h) => h.id))),
                  child: Text(
                    _selected.length == widget.hosts.length ? 'None' : 'All',
                  ),
                ),
              ],
            ),
            for (final section in sections) ...[
              _GroupRow(
                section: section,
                selected: _selected,
                onToggle: () => setState(() {
                  final all = section.hosts.every((h) => _selected.contains(h.id));
                  for (final host in section.hosts) {
                    all ? _selected.remove(host.id) : _selected.add(host.id);
                  }
                }),
              ),
              for (final host in section.hosts)
                CheckboxListTile(
                  dense: true,
                  contentPadding: const EdgeInsetsDirectional.only(start: 24),
                  value: _selected.contains(host.id),
                  onChanged: (on) => setState(() => on == true
                      ? _selected.add(host.id)
                      : _selected.remove(host.id)),
                  title: Text(
                    host.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    host.target,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _canContinue
                  ? () => setState(() => _step = _Step.confirm)
                  : null,
              child: const Text('Next'),
            ),
          ],
        ),
      )),
    );
  }

  Widget _buildConfirm(BuildContext context) {
    final theme = Theme.of(context);
    final hosts = _chosen;
    final open = hosts.where((h) => _openTransport(h.id) != null).length;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Confirm'),
        leading: IconButton(
          tooltip: 'Back',
          icon: const Icon(Icons.arrow_back),
          onPressed: () => setState(() => _step = _Step.setup),
        ),
      ),
      body: _readable(SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            Text(
              'Run this on ${hosts.length} host${hosts.length == 1 ? '' : 's'}?',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            _CommandBox(command: _command.text.trim()),
            const SizedBox(height: 20),
            Text('Hosts', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            for (final host in hosts)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Text.rich(
                  TextSpan(children: [
                    TextSpan(text: '•  ${host.displayName}  '),
                    TextSpan(
                      text: host.target,
                      style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ]),
                ),
              ),
            const SizedBox(height: 16),
            Text(
              '${open == 0 ? 'Each host gets a connection of its own' : '$open already open; the rest get a connection of their own'}, '
              'three at a time. A host that would need a password typed, a '
              'one-time code or a new host key checked is skipped, and says '
              'why.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 28),
            Row(
              children: [
                OutlinedButton(
                  onPressed: () => setState(() => _step = _Step.setup),
                  child: const Text('Back'),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _start,
                    icon: const Icon(Icons.play_arrow),
                    label: Text('Run on ${hosts.length}'),
                  ),
                ),
              ],
            ),
          ],
        ),
      )),
    );
  }
}

/// Keeps a form a readable width on a desktop window: a checkbox a
/// thousand pixels from its label is easy to miss.
Widget _readable(Widget child) => Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 840),
        child: child,
      ),
    );

class _GroupRow extends StatelessWidget {
  const _GroupRow({
    required this.section,
    required this.selected,
    required this.onToggle,
  });

  final HostSection section;
  final Set<String> selected;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final count = section.hosts.where((h) => selected.contains(h.id)).length;
    return CheckboxListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      tristate: true,
      value: count == 0
          ? false
          : count == section.hosts.length
              ? true
              : null,
      onChanged: (_) => onToggle(),
      title: Text(
        '${section.group ?? 'Ungrouped'} · ${section.hosts.length}',
        style: Theme.of(context)
            .textTheme
            .labelLarge
            ?.copyWith(fontWeight: FontWeight.w700),
      ),
    );
  }
}

class _CommandBox extends StatelessWidget {
  const _CommandBox({required this.command});

  final String command;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: SelectableText(
        command,
        style: const TextStyle(
          fontFamily: AppTheme.monoFontFamily,
          fontFamilyFallback: AppTheme.monoFontFamilyFallback,
          fontSize: 13,
        ),
      ),
    );
  }
}

class _SnippetSheet extends StatelessWidget {
  const _SnippetSheet({required this.snippets});

  final List<Snippet> snippets;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: snippets.isEmpty
          ? const Padding(
              padding: EdgeInsets.all(24),
              child: Text('No snippets saved yet. Add them in Settings.'),
            )
          : ListView(
              shrinkWrap: true,
              children: [
                for (final snippet in snippets)
                  ListTile(
                    title: Text(snippet.name),
                    subtitle: Text(
                      snippet.command,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: AppTheme.monoFontFamily,
                        fontFamilyFallback: AppTheme.monoFontFamilyFallback,
                        fontSize: 12,
                      ),
                    ),
                    onTap: () => Navigator.of(context).pop(snippet),
                  ),
              ],
            ),
    );
  }
}

/// The live results: every host with its state, exit badge and output.
class _FleetResults extends StatefulWidget {
  const _FleetResults({required this.service, required this.onRerun});

  final FleetExecService service;
  final Future<void> Function(List<FleetExecHostRun> runs) onRerun;

  @override
  State<_FleetResults> createState() => _FleetResultsState();
}

class _FleetResultsState extends State<_FleetResults> {
  StreamSubscription<List<FleetExecHostRun>>? _sub;
  final Set<String> _expanded = {};

  @override
  void initState() {
    super.initState();
    final hosts = widget.service.hosts;
    if (hosts.length == 1) _expanded.add(hosts.single.hostId);
    _sub = widget.service.changes.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  Future<void> _copy(String text, String what) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('Copied $what')));
  }

  String _allOutput() {
    final buffer = StringBuffer();
    for (final run in widget.service.hosts) {
      buffer
        ..writeln('== ${run.label} (${_badge(run)}) ==')
        ..write(run.output);
      if (run.message != null) buffer.writeln(run.message);
      if (!run.output.endsWith('\n') && run.output.isNotEmpty) buffer.writeln();
      buffer.writeln();
    }
    return buffer.toString();
  }

  @override
  Widget build(BuildContext context) {
    final service = widget.service;
    final running = service.isRunning;
    final failed = service.failedHosts;
    final hosts = service.hosts;
    final done = hosts.where((r) => r.status.isFinished).length;
    return Scaffold(
      appBar: AppBar(
        title: Text(running ? 'Running… $done of ${hosts.length}' : 'Finished'),
        actions: [
          IconButton(
            tooltip: 'Copy all output',
            icon: const Icon(Icons.copy_all_outlined),
            onPressed: () => unawaited(_copy(_allOutput(), 'all output')),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _CommandBox(command: service.command),
                  const SizedBox(height: 8),
                  // In the body, not the app bar: on a narrow phone with
                  // large text the app bar has no room left for its title.
                  Wrap(
                    spacing: 12,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        service.summary,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      if (running)
                        OutlinedButton.icon(
                          onPressed: service.cancel,
                          icon: const Icon(Icons.stop, size: 18),
                          label: const Text('Stop all'),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(0, 40),
                          ),
                        )
                      else if (failed.isNotEmpty)
                        OutlinedButton.icon(
                          onPressed: () => unawaited(widget.onRerun(failed)),
                          icon: const Icon(Icons.replay, size: 18),
                          label: Text('Re-run ${failed.length} failed'),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(0, 40),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            if (running) const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.only(bottom: 24),
                itemCount: hosts.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final run = hosts[index];
                  return _HostRunTile(
                    run: run,
                    expanded: _expanded.contains(run.hostId),
                    onToggle: () => setState(() {
                      if (!_expanded.remove(run.hostId)) _expanded.add(run.hostId);
                    }),
                    onStop: () => service.cancelHost(run.hostId),
                    onCopy: () => unawaited(
                      _copy(run.output, 'the output of ${run.label}'),
                    ),
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

String _badge(FleetExecHostRun run) => switch (run.status) {
      FleetExecStatus.queued => 'waiting',
      FleetExecStatus.connecting => 'connecting',
      FleetExecStatus.running => 'running',
      FleetExecStatus.succeeded => 'exit 0',
      FleetExecStatus.failed =>
        run.exitCode != null ? 'exit ${run.exitCode}' : (run.exitSignal ?? 'failed'),
      FleetExecStatus.error => 'error',
      FleetExecStatus.skipped => 'skipped',
      FleetExecStatus.cancelled => 'stopped',
    };

String _formatDuration(Duration d) {
  if (d.inMilliseconds < 1000) return '${d.inMilliseconds} ms';
  if (d.inSeconds < 60) {
    return '${(d.inMilliseconds / 1000).toStringAsFixed(1)} s';
  }
  final minutes = d.inMinutes;
  final seconds = d.inSeconds % 60;
  return '${minutes}m ${seconds.toString().padLeft(2, '0')}s';
}

class _HostRunTile extends StatelessWidget {
  const _HostRunTile({
    required this.run,
    required this.expanded,
    required this.onToggle,
    required this.onStop,
    required this.onCopy,
  });

  final FleetExecHostRun run;
  final bool expanded;
  final VoidCallback onToggle;
  final VoidCallback onStop;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (Color badgeColor, Color onBadge) = switch (run.status) {
      FleetExecStatus.succeeded => (AppTheme.accent, Colors.black),
      FleetExecStatus.failed || FleetExecStatus.error => (scheme.error, scheme.onError),
      FleetExecStatus.skipped => (scheme.tertiaryContainer, scheme.onTertiaryContainer),
      _ => (scheme.surfaceContainerHighest, scheme.onSurfaceVariant),
    };
    final busy = run.status == FleetExecStatus.connecting ||
        run.status == FleetExecStatus.running;
    final duration = run.duration;
    final subtitle = [
      if (run.usedOpenSession) 'open session',
      if (duration != null) _formatDuration(duration),
      if (run.message != null) run.message!,
    ].join(' · ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          onTap: onToggle,
          leading: busy
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: Padding(
                    padding: EdgeInsets.all(3),
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : Icon(
                  expanded ? Icons.expand_more : Icons.chevron_right,
                  color: scheme.onSurfaceVariant,
                ),
          title: Text(run.label, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: subtitle.isEmpty
              ? null
              : Text(
                  subtitle,
                  maxLines: expanded ? 4 : 1,
                  overflow: TextOverflow.ellipsis,
                ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (busy)
                IconButton(
                  tooltip: 'Stop on ${run.label}',
                  icon: const Icon(Icons.stop_circle_outlined),
                  onPressed: onStop,
                ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: badgeColor,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  _badge(run),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: onBadge,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (expanded)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: _OutputView(run: run, onCopy: onCopy),
          ),
      ],
    );
  }
}

class _OutputView extends StatelessWidget {
  const _OutputView({required this.run, required this.onCopy});

  final FleetExecHostRun run;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const mono = TextStyle(
      fontFamily: AppTheme.monoFontFamily,
      fontFamilyFallback: AppTheme.monoFontFamilyFallback,
      fontSize: 12.5,
      height: 1.35,
      color: Color(0xFFE6EDF3),
    );
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.terminalBackground,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 320),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
              child: run.hasOutput
                  ? SelectableText.rich(
                      TextSpan(
                        style: mono,
                        children: [
                          if (run.truncated)
                            const TextSpan(
                              text: '… earlier output not kept …\n',
                              style: TextStyle(color: Color(0xFF8B949E)),
                            ),
                          for (final chunk in run.chunks)
                            TextSpan(
                              text: chunk.text,
                              style: chunk.isError
                                  ? const TextStyle(color: Color(0xFFFF7B72))
                                  : null,
                            ),
                        ],
                      ),
                    )
                  : Text(
                      run.status.isFinished ? 'No output.' : 'Waiting for output…',
                      style: mono.copyWith(color: const Color(0xFF8B949E)),
                    ),
            ),
          ),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: TextButton.icon(
              onPressed: run.hasOutput ? onCopy : null,
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('Copy'),
              style: TextButton.styleFrom(
                foregroundColor: theme.colorScheme.primary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
