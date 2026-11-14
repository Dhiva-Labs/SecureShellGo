import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../services/bridge/bridge_cli_connector.dart';
import '../services/bridge/bridge_client_store.dart';
import '../services/bridge/bridge_launcher_locator.dart';
import '../services/host_store.dart';
import '../theme.dart';
import 'bridge_connect_screen.dart';
import 'bridge_shared_hosts_screen.dart';
import 'settings/settings_section.dart';

enum _Phase { checking, unavailable, confirm, running, failed, hosts, done }

/// How one of the four rows of the setup stands.
enum _StepState { pending, running, done, skipped, failed, notRun }

/// "Connect Claude Code" in one go: the `claude` that was found is asked for
/// its version and plugin source (the first time the app runs it, and only
/// because the user pressed the button), then one confirmation, then the
/// bridge is switched on if needed, the assistant is paired and the `claude`
/// command sets the plugin up, then the user picks the hosts to share.
///
/// The token lives only inside [_pairAndConnect]: it is handed to the
/// connector and dropped, never shown, copied, logged or kept in state.
///
/// Leaving is blocked while the setup runs (no back button, no pop): the
/// connector's steps are bounded by timeouts, and a half-finished setup would
/// leave a pairing nobody can use. Everything else can be left freely.
class BridgeOneClickScreen extends StatefulWidget {
  const BridgeOneClickScreen({
    super.key,
    required this.connector,
    required this.clients,
    required this.hostStore,
    required this.bridgeEnabled,
    required this.apply,
    this.launcher,
  });

  /// Asked once, when the screen opens, which `claude` it is ([detect]); the
  /// answer is what the confirmation shows and what [connect] is run with.
  final ClaudeCliConnector connector;

  final BridgeClientStore clients;
  final HostStore hostStore;

  /// Whether the bridge is on right now.
  final bool Function() bridgeEnabled;

  /// The Settings screen's own save path, which undoes a bridge change it
  /// cannot save and throws.
  final SettingsChange apply;

  /// The launcher command to hand to the plugin. Found from how this copy of
  /// the app is installed unless a test hands one in.
  final BridgeLauncherCommand? launcher;

  @override
  State<BridgeOneClickScreen> createState() => _BridgeOneClickScreenState();
}

class _BridgeOneClickScreenState extends State<BridgeOneClickScreen> {
  _Phase _phase = _Phase.checking;

  /// The `claude` the confirmation shows. Set once, from the one [detect]
  /// this screen runs, and the very instance [connect] is then run with.
  ClaudeCliAvailable? _claude;

  /// Why the found program could not be run, for "Technical details".
  String? _unavailableDetail;

  /// The steps the connector has started so far, for the progress rows.
  final List<ClaudeConnectStep> _ran = [];

  // What the failed view shows.
  bool _saveFailed = false;
  ClaudeConnectFailed? _failure;
  String? _error;
  bool _pairingRemoved = false;
  String? _pairingLeft;
  bool _switchLeftOn = false;

  late final BridgeLauncherCommand _launcher =
      widget.launcher ?? locateBridgeLauncher();

  static const int _groups = 4;

  /// The four things the user sees; the list and add commands are one.
  static int _group(ClaudeConnectStep step) => switch (step) {
    ClaudeConnectStep.marketplaceList || ClaudeConnectStep.marketplaceAdd => 0,
    ClaudeConnectStep.install => 1,
    ClaudeConnectStep.configure => 2,
    ClaudeConnectStep.verify => 3,
  };

  /// How each row stands, from the steps that were started. A row before the
  /// furthest one reached is finished, or skipped when it is the marketplace
  /// and only the list (not the add) ran; with [failedAt], that row failed
  /// and the ones after it never ran.
  static List<_StepState> _states(
    List<ClaudeConnectStep> ran, {
    ClaudeConnectStep? failedAt,
  }) {
    var reached = -1;
    for (final step in ran) {
      if (_group(step) > reached) reached = _group(step);
    }
    if (failedAt != null) reached = _group(failedAt);
    return [
      for (var g = 0; g < _groups; g++)
        if (g < reached)
          g == 0 && !ran.contains(ClaudeConnectStep.marketplaceAdd)
              ? _StepState.skipped
              : _StepState.done
        else if (g == reached)
          failedAt != null ? _StepState.failed : _StepState.running
        else
          failedAt != null ? _StepState.notRun : _StepState.pending,
    ];
  }

  /// [base], or [base] with the first number that no paired assistant has.
  static String _freeName(String base, List<BridgeClient> existing) {
    final taken = {for (final c in existing) c.name};
    if (!taken.contains(base)) return base;
    var n = 2;
    while (taken.contains('$base $n')) {
      n++;
    }
    return '$base $n';
  }

  @override
  void initState() {
    super.initState();
    unawaited(_check());
  }

  /// Runs the found `claude` for its version and plugin source: the user
  /// asked for this by pressing "Connect Claude Code". Changes nothing.
  Future<void> _check() async {
    ClaudeCliAvailability found;
    try {
      found = await widget.connector.detect();
    } catch (e) {
      found = ClaudeCliFailed('$e');
    }
    if (!mounted) return;
    setState(() {
      if (found is ClaudeCliAvailable) {
        _claude = found;
        _phase = _Phase.confirm;
      } else {
        _phase = _Phase.unavailable;
        _unavailableDetail = found is ClaudeCliFailed ? found.message : null;
      }
    });
  }

  Future<void> _start() async {
    final claude = _claude;
    // Once per screen, and only from the confirmation: a second tap that
    // lands before the rebuild must not pair or run anything again.
    if (_phase != _Phase.confirm || claude == null) return;
    final l10n = context.l10n;
    final baseName = l10n.bridgeOneClickDefaultName;
    setState(() {
      _phase = _Phase.running;
      _ran.clear();
    });

    var switchedOn = false;
    if (!widget.bridgeEnabled()) {
      try {
        await widget.apply((s) => s.copyWith(bridgeEnabled: true));
        switchedOn = true;
      } catch (_) {
        // The Settings screen has put the switch back; nothing else was done.
        if (!mounted) return;
        setState(() {
          _phase = _Phase.failed;
          _saveFailed = true;
        });
        return;
      }
    }

    final result = await _pairAndConnect(claude, baseName);
    final outcome = result.outcome;
    if (outcome is ClaudeConnected) {
      if (mounted) setState(() => _phase = _Phase.hosts);
      return;
    }

    // Runs whether or not this screen is still there: a pairing nobody holds
    // must not outlive the attempt that made it.
    final undone = await _undo(result.client, switchedOn);
    if (!mounted) return;
    setState(() {
      _phase = _Phase.failed;
      _failure = outcome is ClaudeConnectFailed ? outcome : null;
      _error = outcome is ClaudeConnectFailed ? null : result.error;
      _pairingRemoved = result.client != null && undone.removed;
      _pairingLeft = result.client != null && !undone.removed
          ? result.client!.name
          : null;
      _switchLeftOn = undone.switchLeftOn;
    });
  }

  /// Pairs and runs the connector. The token is a local of this function:
  /// nothing it returns or throws can carry it, because the one place that
  /// text from outside is shown first has the token scrubbed out of it.
  ///
  /// The pairing is made pending and confirmed only once Claude Code has
  /// reported it set: until then it cannot sign in, and if the app closes
  /// part way it is removed at the next start.
  Future<
    ({BridgeClient? client, ClaudeConnectOutcome? outcome, String? error})
  >
  _pairAndConnect(ClaudeCliAvailable claude, String baseName) async {
    BridgeClient? client;
    String? token;
    try {
      final existing = await widget.clients.load();
      final created = await widget.clients.create(
        _freeName(baseName, existing),
        pending: true,
      );
      client = created.client;
      token = created.token;
      final outcome = await widget.connector.connect(
        executablePath: claude.executablePath,
        token: token,
        launcherCommand: _launcher.command,
        expectedSource: claude.pluginSource,
        onStep: (step) {
          if (mounted) setState(() => _ran.add(step));
        },
      );
      // A confirmation that cannot be saved is a failure like any other:
      // the pairing would not survive a restart, so it is taken back.
      if (outcome is ClaudeConnected) await widget.clients.confirm(client.id);
      return (client: client, outcome: outcome, error: null);
    } catch (e) {
      var text = '$e';
      if (token != null) text = text.replaceAll(token, '[token]');
      return (client: client, outcome: null, error: text);
    }
  }

  /// Takes back what a failed attempt did: the pairing it made, and the
  /// bridge switch if this attempt turned it on (the user had it off, so it
  /// goes back off, whoever else is paired). Says what could not be taken
  /// back.
  Future<({bool removed, bool switchLeftOn})> _undo(
    BridgeClient? client,
    bool switchedOn,
  ) async {
    var removed = false;
    if (client != null) {
      try {
        await widget.clients.revoke(client.id);
        removed = true;
      } catch (_) {}
    }
    var switchLeftOn = false;
    if (switchedOn) {
      try {
        await widget.apply((s) => s.copyWith(bridgeEnabled: false));
      } catch (_) {
        switchLeftOn = true;
      }
    }
    return (removed: removed, switchLeftOn: switchLeftOn);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final running = _phase == _Phase.running;
    return PopScope(
      canPop: !running,
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: !running,
          title: Text(
            _phase == _Phase.hosts
                ? l10n.bridgeHostsTitle
                : l10n.bridgeOneClickTitle,
          ),
        ),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: switch (_phase) {
                _Phase.checking => _checking(context),
                _Phase.unavailable => _unavailable(context),
                _Phase.confirm => _confirm(context, _claude!),
                _Phase.running => _progress(context),
                _Phase.failed => _failed(context),
                _Phase.hosts => SharedHostsChecklist(
                  hostStore: widget.hostStore,
                  onSaved: () => setState(() => _phase = _Phase.done),
                  onSkip: () => setState(() => _phase = _Phase.done),
                ),
                _Phase.done => _done(context),
              },
            ),
          ),
        ),
      ),
    );
  }

  TextStyle _mono(BuildContext context) => TextStyle(
    fontFamily: AppTheme.monoFontFamily,
    fontFamilyFallback: AppTheme.monoFontFamilyFallback,
    fontSize: 12.5,
    height: 1.35,
  );

  Widget _checking(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const LinearProgressIndicator(),
        const SizedBox(height: 16),
        Text(
          context.l10n.bridgeOneClickChecking,
          style: theme.textTheme.titleMedium,
        ),
      ],
    );
  }

  /// The program was there but did not answer: nothing was changed, and the
  /// manual way is offered.
  Widget _unavailable(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final detail = _unavailableDetail;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          l10n.bridgeOneClickFailedTitle,
          style: theme.textTheme.titleMedium?.copyWith(
            color: theme.colorScheme.error,
          ),
        ),
        const SizedBox(height: 8),
        Text(l10n.bridgeOneClickCannotRun),
        if (detail != null && detail.isNotEmpty) ...[
          const SizedBox(height: 8),
          _technical(context, [SelectableText(detail, style: _mono(context))]),
        ],
        const SizedBox(height: 16),
        _closeOrManual(context),
      ],
    );
  }

  Widget _confirm(BuildContext context, ClaudeCliAvailable claude) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          l10n.settingsBridgeEnableTitle,
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(l10n.settingsBridgeEnableBody),
        if (!widget.bridgeEnabled()) ...[
          const SizedBox(height: 8),
          Text(l10n.bridgeOneClickWillTurnOn),
        ],
        const SizedBox(height: 16),
        Text(l10n.bridgeOneClickRunIntro),
        const SizedBox(height: 8),
        DecoratedBox(
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: SelectableText(claude.executablePath, style: _mono(context)),
          ),
        ),
        const SizedBox(height: 8),
        Text(l10n.bridgeOneClickVersion(claude.version)),
        ..._sourceNote(context, claude.pluginSource),
        const SizedBox(height: 24),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: 8,
          runSpacing: 8,
          children: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
            ),
            FilledButton(
              onPressed: () => unawaited(_start()),
              child: Text(l10n.bridgeOneClickConfirm),
            ),
          ],
        ),
      ],
    );
  }

  /// Where the plugin comes from, when that is not the published one: said
  /// plainly, because the pairing goes to whatever that source installs.
  List<Widget> _sourceNote(BuildContext context, ClaudePluginSource source) {
    final l10n = context.l10n;
    final color = Theme.of(context).colorScheme.error;
    return switch (source) {
      ClaudePluginSourceOfficial() => const [],
      ClaudePluginSourceOther(:final description) => [
        const SizedBox(height: 12),
        SelectableText(l10n.bridgeOneClickSourceOther(description)),
        const SizedBox(height: 4),
        Text(
          l10n.bridgeOneClickSourceOtherWarning,
          style: TextStyle(color: color),
        ),
      ],
      ClaudePluginSourceUnknown() => [
        const SizedBox(height: 12),
        Text(l10n.bridgeOneClickSourceUnknown, style: TextStyle(color: color)),
      ],
    };
  }

  String _stepName(BuildContext context, int group) {
    final l10n = context.l10n;
    return switch (group) {
      0 => l10n.bridgeOneClickStepMarketplace,
      1 => l10n.bridgeOneClickStepInstall,
      2 => l10n.bridgeOneClickStepConfigure,
      _ => l10n.bridgeOneClickStepVerify,
    };
  }

  Widget _progress(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final states = _states(_ran);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const LinearProgressIndicator(),
        const SizedBox(height: 16),
        Text(l10n.bridgeOneClickRunning, style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(l10n.bridgeOneClickRunningHelp),
        const SizedBox(height: 16),
        for (var g = 0; g < _groups; g++) _stepRow(context, g, states[g]),
      ],
    );
  }

  Widget _stepRow(BuildContext context, int group, _StepState state) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final Widget icon = switch (state) {
      _StepState.running => const Padding(
        padding: EdgeInsets.all(2),
        child: SizedBox.square(
          dimension: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
      _StepState.pending => Icon(
        Icons.more_horiz,
        size: 20,
        color: scheme.onSurfaceVariant,
      ),
      _StepState.done => Icon(Icons.check, size: 20, color: scheme.primary),
      _StepState.skipped => Icon(
        Icons.redo,
        size: 20,
        color: scheme.onSurfaceVariant,
      ),
      _StepState.failed => Icon(Icons.close, size: 20, color: scheme.error),
      _StepState.notRun => Icon(
        Icons.remove,
        size: 20,
        color: scheme.onSurfaceVariant,
      ),
    };
    final name = _stepName(context, group);
    return Padding(
      key: ValueKey('bridge-step-$group-${state.name}'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox.square(dimension: 20, child: Center(child: icon)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: state == _StepState.running
                      ? const TextStyle(fontWeight: FontWeight.w600)
                      : null,
                ),
                if (state == _StepState.skipped)
                  Text(
                    context.l10n.bridgeOneClickStepSkipped,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _failureSentence(BuildContext context, ClaudeConnectStep step) {
    final l10n = context.l10n;
    return switch (step) {
      // Only stops here when the source differs from the one confirmed.
      ClaudeConnectStep.marketplaceList => l10n.bridgeOneClickFailedSource,
      ClaudeConnectStep.marketplaceAdd => l10n.bridgeOneClickFailedMarketplace,
      ClaudeConnectStep.install => l10n.bridgeOneClickFailedInstall,
      ClaudeConnectStep.configure => l10n.bridgeOneClickFailedConfigure,
      ClaudeConnectStep.verify => l10n.bridgeOneClickFailedVerify,
    };
  }

  Widget _technical(BuildContext context, List<Widget> children) {
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: Text(context.l10n.bridgeOneClickTechnical),
      expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }

  Widget _closeOrManual(BuildContext context) {
    return Wrap(
      alignment: WrapAlignment.end,
      spacing: 8,
      runSpacing: 8,
      children: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).closeButtonLabel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pushReplacement(
            MaterialPageRoute<void>(
              builder: (_) => BridgeConnectScreen(
                clients: widget.clients,
                launcher: widget.launcher,
              ),
            ),
          ),
          child: Text(context.l10n.settingsBridgeConnect),
        ),
      ],
    );
  }

  Widget _failed(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final failure = _failure;
    final error = _error;
    final left = _pairingLeft;
    final states = failure == null
        ? const <_StepState>[]
        : _states([
            for (final run in failure.steps) run.step,
          ], failedAt: failure.step);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          l10n.bridgeOneClickFailedTitle,
          style: theme.textTheme.titleMedium?.copyWith(
            color: theme.colorScheme.error,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          _saveFailed
              ? l10n.settingsBridgeSaveFailed
              : failure != null
              ? _failureSentence(context, failure.step)
              : l10n.bridgeOneClickFailedOther,
        ),
        if (failure != null) ...[
          const SizedBox(height: 12),
          for (var g = 0; g < _groups; g++) _stepRow(context, g, states[g]),
        ],
        if (_pairingRemoved) ...[
          const SizedBox(height: 12),
          Text(l10n.bridgeOneClickCleanedUp),
        ],
        if (left != null) ...[
          const SizedBox(height: 12),
          Text(
            l10n.bridgeOneClickCleanupFailed(left, l10n.settingsBridgePaired),
            style: TextStyle(color: theme.colorScheme.error),
          ),
        ],
        if (_switchLeftOn) ...[
          const SizedBox(height: 12),
          Text(
            l10n.bridgeOneClickSwitchOffFailed,
            style: TextStyle(color: theme.colorScheme.error),
          ),
        ],
        if (failure != null) ...[
          const SizedBox(height: 8),
          _technical(context, [
            SelectableText(failure.message, style: _mono(context)),
            for (final run in failure.steps) ...[
              const SizedBox(height: 12),
              SelectableText(
                [
                  run.command.join(' '),
                  if (run.timedOut)
                    'timed out'
                  else if (run.exitCode != null)
                    'exit ${run.exitCode}',
                  if (run.output.isNotEmpty) run.output,
                ].join('\n'),
                style: _mono(context),
              ),
            ],
          ]),
        ] else if (error != null && error.isNotEmpty) ...[
          const SizedBox(height: 8),
          _technical(context, [SelectableText(error, style: _mono(context))]),
        ],
        const SizedBox(height: 16),
        _closeOrManual(context),
      ],
    );
  }

  Widget _done(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Icon(
          Icons.check_circle_outline,
          size: 40,
          color: theme.colorScheme.primary,
        ),
        const SizedBox(height: 12),
        Text(
          l10n.bridgeOneClickDoneTitle,
          style: theme.textTheme.titleMedium,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(l10n.bridgeOneClickDoneBody, textAlign: TextAlign.center),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.bridgeConnectDone),
        ),
      ],
    );
  }
}
