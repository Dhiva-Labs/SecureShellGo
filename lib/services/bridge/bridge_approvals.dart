import 'dart:async';
import 'dart:collection';

import 'bridge_client_store.dart';

/// Starts a one-shot timer. Injected so tests can move time by hand instead
/// of sleeping; the app uses [Timer.new].
typedef BridgeTimerFactory =
    Timer Function(Duration delay, void Function() callback);

Timer _realTimer(Duration delay, void Function() callback) =>
    Timer(delay, callback);

/// What the approval card shows: built by the TOOL from the validated
/// arguments, never from the assistant's prose, so the user sees exactly
/// what will happen.
sealed class BridgeChangeSummary {
  const BridgeChangeSummary();
}

/// A command, verbatim, and the bridge names of the hosts it runs on (one
/// for `run_command`, several for `run_on_hosts`).
final class CommandSummary extends BridgeChangeSummary {
  CommandSummary({required this.command, required List<String> hostNames})
    : hostNames = List.unmodifiable(hostNames);

  final String command;
  final List<String> hostNames;
}

/// A file write: the canonical path, the size in bytes, whether it replaces
/// a file, and a preview (the first lines, or a short diff).
final class FileWriteSummary extends BridgeChangeSummary {
  const FileWriteSummary({
    required this.path,
    required this.bytes,
    required this.replacesExisting,
    required this.preview,
    this.previewKind = FileWritePreviewKind.noPreview,
  });

  final String path;
  final int bytes;
  final bool replacesExisting;
  final String preview;

  /// What [preview] is. The preview's own last lines say the same in words.
  final FileWritePreviewKind previewKind;

  /// True when [preview] does not show the whole change: lines left out or
  /// cut, text hidden as a secret, or no preview at all. The card should
  /// say so prominently; the byte count is the full size.
  bool get previewIsPartial =>
      previewKind != FileWritePreviewKind.fullContent &&
      previewKind != FileWritePreviewKind.fullDiff;
}

/// What a [FileWriteSummary.preview] shows.
enum FileWritePreviewKind {
  /// Every byte that will be written (for a replacement whose old content
  /// could not be shown as a diff, the whole new content).
  fullContent,

  /// The start of what will be written, not all of it (or with lines cut,
  /// or with text hidden as a secret).
  partialContent,

  /// Every change to the replaced file; the rest stays as it is.
  fullDiff,

  /// Some of the changes to the replaced file, not all (or with lines cut,
  /// or text hidden as a secret).
  partialDiff,

  /// Nothing of the content is shown.
  noPreview,
}

/// A systemd action on one unit.
final class ServiceActionSummary extends BridgeChangeSummary {
  const ServiceActionSummary({required this.unit, required this.action});

  final String unit;

  /// `start`, `stop`, `restart` or `reload`.
  final String action;
}

/// Opening an interactive terminal the user can see.
final class TerminalSummary extends BridgeChangeSummary {
  const TerminalSummary();
}

/// Opening the server's desktop for the assistant: a viewer the user can
/// watch, through which the assistant sees the screen and uses the mouse
/// and keyboard as whoever is signed in there. Never covered by a
/// time-limited approval, like a terminal.
final class DesktopSummary extends BridgeChangeSummary {
  const DesktopSummary();
}

/// Starting a long-running job (`start_job`): the command verbatim, the
/// folder it starts in as the assistant gave it (null for the home
/// directory), and its short name, if any. The job keeps running on the
/// server after the call, the connection and the app have ended.
final class JobStartSummary extends BridgeChangeSummary {
  const JobStartSummary({required this.command, this.cwd, this.name});

  final String command;
  final String? cwd;
  final String? name;
}

/// One question to the user: may [client] do [summary] on [hostName]?
class BridgeApprovalRequest {
  const BridgeApprovalRequest({
    required this.id,
    required this.client,
    required this.hostId,
    required this.hostName,
    required this.tool,
    required this.summary,
    required this.createdAt,
    required this.expiresAt,
  });

  final String id;
  final BridgeClient client;
  final String hostId;

  /// The host's name as the assistant knows it (its bridge name).
  final String hostName;
  final String tool;
  final BridgeChangeSummary summary;
  final DateTime createdAt;

  /// When silence becomes a no.
  final DateTime expiresAt;

  @override
  String toString() => 'BridgeApprovalRequest($id, $tool on $hostName)';
}

/// The user's answer on the card.
enum BridgeApprovalAnswer { deny, allowOnce, allowForAWhile }

/// How one [BridgeApprovals.ask] ended.
enum BridgeApprovalOutcomeKind {
  /// Not asked: [BridgeApprovals.maxPending] requests were already waiting,
  /// or [BridgeApprovals.maxPendingPerClient] from the same client.
  busy,
  denied,
  timedOut,

  /// The call was abandoned (cancelled, revoked, bridge off, app locked)
  /// before anyone answered.
  withdrawn,
  allowedOnce,
  allowedForAWhile,
}

class BridgeApprovalOutcome {
  const BridgeApprovalOutcome._(this.kind, [this.grantFor, this.via]);

  static const BridgeApprovalOutcome busy = BridgeApprovalOutcome._(
    BridgeApprovalOutcomeKind.busy,
  );
  static const BridgeApprovalOutcome denied = BridgeApprovalOutcome._(
    BridgeApprovalOutcomeKind.denied,
  );
  static const BridgeApprovalOutcome timedOut = BridgeApprovalOutcome._(
    BridgeApprovalOutcomeKind.timedOut,
  );
  static const BridgeApprovalOutcome withdrawn = BridgeApprovalOutcome._(
    BridgeApprovalOutcomeKind.withdrawn,
  );
  static const BridgeApprovalOutcome allowedOnce = BridgeApprovalOutcome._(
    BridgeApprovalOutcomeKind.allowedOnce,
  );

  /// Allowed, and the same client may change the same host without asking
  /// for [grantFor] (the timed-approval setting when the user answered).
  const BridgeApprovalOutcome.allowedForAWhile(Duration grantFor)
    : this._(BridgeApprovalOutcomeKind.allowedForAWhile, grantFor);

  final BridgeApprovalOutcomeKind kind;

  /// Set only for [BridgeApprovalOutcomeKind.allowedForAWhile].
  final Duration? grantFor;

  /// Where the answer came from when it was not this computer's own card,
  /// e.g. `controller:<phone name>`; null for a tap here, a timeout or a
  /// withdrawal. For the activity log only: not part of [==].
  final String? via;

  /// This outcome, answered through [source].
  BridgeApprovalOutcome _via(String? source) =>
      source == null ? this : BridgeApprovalOutcome._(kind, grantFor, source);

  bool get allowed =>
      kind == BridgeApprovalOutcomeKind.allowedOnce ||
      kind == BridgeApprovalOutcomeKind.allowedForAWhile;

  @override
  bool operator ==(Object other) =>
      other is BridgeApprovalOutcome &&
      other.kind == kind &&
      other.grantFor == grantFor;

  @override
  int get hashCode => Object.hash(kind, grantFor);

  @override
  String toString() =>
      'BridgeApprovalOutcome(${kind.name}'
      '${grantFor == null ? '' : ', $grantFor'})';
}

/// The questions waiting for the user, in memory only.
///
/// Silence is no: a request not answered within [timeout] ends as
/// [BridgeApprovalOutcome.timedOut]. Every request ends exactly once —
/// answered, timed out or withdrawn, whichever comes first — and is then
/// gone: a late or second answer, or an answer for an id that is not
/// waiting, is ignored.
class BridgeApprovals {
  BridgeApprovals({
    required this.timedApprovalMinutes,
    this.timeout = defaultTimeout,
    this.maxPending = defaultMaxPending,
    this.maxPendingPerClient = defaultMaxPendingPerClient,
    DateTime Function()? clock,
    BridgeTimerFactory? timer,
  }) : _clock = clock ?? DateTime.now,
       _timer = timer ?? _realTimer;

  static const Duration defaultTimeout = Duration(seconds: 120);
  static const int defaultMaxPending = 8;

  /// `AppSettings.bridgeTimedApprovalMinutes`, read when the user answers:
  /// "allow for a while" is honoured only while it is above 0, otherwise it
  /// counts as "allow once".
  final int Function() timedApprovalMinutes;
  final Duration timeout;
  final int maxPending;

  /// The most requests one paired client may have waiting at once, so one
  /// assistant cannot crowd another's cards out of [maxPending].
  final int maxPendingPerClient;
  static const int defaultMaxPendingPerClient = 3;
  final DateTime Function() _clock;
  final BridgeTimerFactory _timer;

  final LinkedHashMap<String, _Pending> _pending = LinkedHashMap();
  final StreamController<List<BridgeApprovalRequest>> _changes =
      StreamController<List<BridgeApprovalRequest>>.broadcast();
  var _nextId = 0;
  var _disposed = false;

  /// The requests waiting now, oldest first.
  List<BridgeApprovalRequest> get current =>
      List.unmodifiable([for (final p in _pending.values) p.request]);

  /// [current] now, then again on every change. For the UI.
  Stream<List<BridgeApprovalRequest>> get pending =>
      Stream<List<BridgeApprovalRequest>>.multi((sink) {
        sink.add(current);
        final sub = _changes.stream.listen(sink.add, onDone: sink.close);
        sink.onCancel = sub.cancel;
      });

  /// A request for [ask] with a fresh id and the times filled in from this
  /// object's clock.
  BridgeApprovalRequest request({
    required BridgeClient client,
    required String hostId,
    required String hostName,
    required String tool,
    required BridgeChangeSummary summary,
  }) {
    final now = _clock();
    return BridgeApprovalRequest(
      id: 'approval-${++_nextId}-${now.microsecondsSinceEpoch}',
      client: client,
      hostId: hostId,
      hostName: hostName,
      tool: tool,
      summary: summary,
      createdAt: now,
      expiresAt: now.add(timeout),
    );
  }

  /// Puts [r] in front of the user and completes with how it ended. Refused
  /// at once as [BridgeApprovalOutcome.busy] when [maxPending] are already
  /// waiting, or [maxPendingPerClient] from the same client. The wait ends at [BridgeApprovalRequest.expiresAt], and never
  /// later than [timeout] from now.
  ///
  /// Throws [ArgumentError] for an id that is already waiting: one call has
  /// at most one pending request.
  Future<BridgeApprovalOutcome> ask(BridgeApprovalRequest r) {
    if (_disposed) return Future.value(BridgeApprovalOutcome.withdrawn);
    if (_pending.containsKey(r.id)) {
      throw ArgumentError.value(r.id, 'id', 'already waiting');
    }
    final fromClient = _pending.values
        .where((p) => p.request.client.id == r.client.id)
        .length;
    if (_pending.length >= maxPending || fromClient >= maxPendingPerClient) {
      return Future.value(BridgeApprovalOutcome.busy);
    }
    var wait = r.expiresAt.difference(_clock());
    if (wait > timeout) wait = timeout;
    if (wait <= Duration.zero) {
      return Future.value(BridgeApprovalOutcome.timedOut);
    }
    final entry = _Pending(r);
    _pending[r.id] = entry;
    entry.timer = _timer(
      wait,
      () => _finish(r.id, BridgeApprovalOutcome.timedOut),
    );
    _publish();
    return entry.done.future;
  }

  /// The user's answer, from the card here or, with [via] set (e.g.
  /// `controller:<phone name>`), from a paired phone: the same path either
  /// way. Ignored unless [id] is waiting.
  ///
  /// Returns how the request ended, or null when [id] was not waiting
  /// (answered already, withdrawn, timed out, or never asked). A request
  /// whose time ran out just before the answer ends as timed out.
  BridgeApprovalOutcome? answer(
    String id,
    BridgeApprovalAnswer a, {
    String? via,
  }) {
    final entry = _pending[id];
    if (entry == null) return null;
    // The timer may be due but not yet run; the clock is the judge.
    if (!_clock().isBefore(entry.request.expiresAt)) {
      _finish(id, BridgeApprovalOutcome.timedOut);
      return BridgeApprovalOutcome.timedOut;
    }
    _answeringVia = via;
    _lastAnswered = null;
    try {
      _answer(id, entry, a);
    } finally {
      _answeringVia = null;
    }
    return _lastAnswered;
  }

  /// Set only while [answer] runs: where that answer came from, stamped on
  /// the outcome by [_finish], and the outcome it ended with.
  String? _answeringVia;
  BridgeApprovalOutcome? _lastAnswered;

  void _answer(String id, _Pending entry, BridgeApprovalAnswer a) {
    switch (a) {
      case BridgeApprovalAnswer.deny:
        _finish(id, BridgeApprovalOutcome.denied);
      case BridgeApprovalAnswer.allowOnce:
        _finish(id, BridgeApprovalOutcome.allowedOnce);
      case BridgeApprovalAnswer.allowForAWhile:
        final minutes = timedApprovalMinutes();
        // A terminal or a desktop is never covered by a time-limited
        // approval.
        if (minutes <= 0 ||
            entry.request.summary is TerminalSummary ||
            entry.request.summary is DesktopSummary) {
          _finish(id, BridgeApprovalOutcome.allowedOnce);
        } else {
          _finish(
            id,
            BridgeApprovalOutcome.allowedForAWhile(Duration(minutes: minutes)),
          );
        }
    }
  }

  /// The call behind [id] was abandoned. Ignored unless [id] is waiting.
  void withdraw(String id) => _finish(id, BridgeApprovalOutcome.withdrawn);

  /// Every request for the host [hostId] (it was un-shared, stepped down,
  /// deleted, or now points at another server).
  void withdrawHost(String hostId) {
    for (final entry in _pending.values.toList()) {
      if (entry.request.hostId == hostId) withdraw(entry.request.id);
    }
  }

  /// Every request of the paired client [clientId] (it was revoked).
  void withdrawClient(String clientId) {
    for (final entry in _pending.values.toList()) {
      if (entry.request.client.id == clientId) withdraw(entry.request.id);
    }
  }

  /// Every request of a client not in [clientIds].
  void withdrawClientsExcept(Set<String> clientIds) {
    for (final entry in _pending.values.toList()) {
      if (!clientIds.contains(entry.request.client.id)) {
        withdraw(entry.request.id);
      }
    }
  }

  /// Every request (bridge off, app locked).
  void withdrawAll() {
    for (final id in _pending.keys.toList()) {
      withdraw(id);
    }
  }

  void _finish(String id, BridgeApprovalOutcome outcome) {
    final entry = _pending.remove(id);
    if (entry == null) return;
    entry.timer?.cancel();
    final ended = outcome._via(_answeringVia);
    _lastAnswered = ended;
    entry.done.complete(ended);
    if (!_ended.isClosed) _ended.add((request: entry.request, outcome: ended));
    _publish();
  }

  final StreamController<BridgeApprovalEnd> _ended =
      StreamController<BridgeApprovalEnd>.broadcast();

  /// Each request as it ends — answered, timed out or withdrawn — with how.
  /// For a remote controller, which must tell its card why it went away.
  Stream<BridgeApprovalEnd> get ended => _ended.stream;

  void _publish() {
    if (!_changes.isClosed) _changes.add(current);
  }

  /// Withdraws everything and closes [pending].
  Future<void> dispose() async {
    withdrawAll();
    _disposed = true;
    await _changes.close();
    await _ended.close();
  }
}

/// One request that ended, and how ([BridgeApprovals.ended]).
typedef BridgeApprovalEnd = ({
  BridgeApprovalRequest request,
  BridgeApprovalOutcome outcome,
});

class _Pending {
  _Pending(this.request);

  final BridgeApprovalRequest request;
  final Completer<BridgeApprovalOutcome> done =
      Completer<BridgeApprovalOutcome>();
  Timer? timer;
}
