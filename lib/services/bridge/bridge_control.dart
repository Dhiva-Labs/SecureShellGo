import 'dart:async';
import 'dart:convert';

import '../../models/app_settings.dart';
import '../visible_text.dart';
import 'bridge_approvals.dart';
import 'bridge_audit.dart';
import 'bridge_channel.dart';
import 'bridge_client_store.dart';
import 'bridge_control_protocol.dart';
import 'bridge_desktops.dart';
import 'bridge_grants.dart';
import 'bridge_jobs.dart';
import 'bridge_terminals.dart';

/// Something an assistant holds that the user can stop from the phone, as
/// a source of [BridgeControlItem]s: the assistant terminals today
/// ([BridgeTerminalsControlSource]); desktops and jobs implement it in
/// their own modules and are passed to `BridgeService(controlSources:)`.
///
/// [stop] must be exactly what the Stop button in the app does, so the
/// phone never has a path of its own.
abstract interface class BridgeControlSource {
  ControlItemKind get kind;

  /// What is live now.
  List<BridgeControlItem> get current;

  /// Fires after every change of [current].
  Stream<void> get changes;

  /// Stops [id], as the app's own Stop does. False when there is no such
  /// item (already gone).
  Future<bool> stop(String id);
}

/// One item of a [BridgeControlSource], before it is made safe to send.
class BridgeControlItem {
  const BridgeControlItem({
    required this.id,
    required this.clientName,
    required this.hostName,
    required this.state,
    this.label,
    this.startedAt,
  });

  final String id;
  final String clientName;

  /// The host's bridge name; never an address.
  final String hostName;

  /// A short word for the state (`driving`, `takenOver`, `running`).
  final String state;
  final String? label;
  final DateTime? startedAt;
}

/// The assistant terminals as a [BridgeControlSource].
class BridgeTerminalsControlSource implements BridgeControlSource {
  BridgeTerminalsControlSource(this.terminals);

  final BridgeTerminals terminals;

  @override
  ControlItemKind get kind => ControlItemKind.terminal;

  @override
  List<BridgeControlItem> get current => [
    for (final t in terminals.current)
      BridgeControlItem(
        id: t.terminalId,
        clientName: t.clientName,
        hostName: t.hostName,
        state: t.state.name,
        startedAt: t.openedAt,
      ),
  ];

  @override
  Stream<void> get changes => terminals.changes.map((_) {});

  @override
  Future<bool> stop(String id) async {
    if (!terminals.current.any((t) => t.terminalId == id)) return false;
    // The banner's Stop: closes the session, even one taken over.
    await terminals.stop(id);
    return true;
  }
}

/// The assistant desktops as a [BridgeControlSource].
class BridgeDesktopsControlSource implements BridgeControlSource {
  BridgeDesktopsControlSource(this.desktops);

  final BridgeDesktops desktops;

  @override
  ControlItemKind get kind => ControlItemKind.desktop;

  @override
  List<BridgeControlItem> get current => [
    for (final d in desktops.current)
      BridgeControlItem(
        id: d.desktopId,
        clientName: d.clientName,
        hostName: d.hostName,
        state: d.state.name,
        startedAt: d.openedAt,
      ),
  ];

  @override
  Stream<void> get changes => desktops.changes.map((_) {});

  @override
  Future<bool> stop(String id) async {
    if (!desktops.current.any((d) => d.desktopId == id)) return false;
    // The viewer banner's Stop.
    await desktops.stop(id);
    return true;
  }
}

/// The jobs assistants started as a [BridgeControlSource]: every job the
/// app remembers, since whether one still runs is only known by asking its
/// server. So the state word is `registered` and the label says when it
/// started rather than claiming it runs.
class BridgeJobsControlSource implements BridgeControlSource {
  BridgeJobsControlSource(this.jobs);

  final BridgeJobs jobs;

  /// The label is the job's name, or the start of its command, cut here.
  static const int labelChars = 60;

  @override
  ControlItemKind get kind => ControlItemKind.job;

  @override
  List<BridgeControlItem> get current => [
    for (final j in jobs.known)
      BridgeControlItem(
        id: j.id,
        clientName: j.clientName ?? 'AI assistant',
        hostName: j.hostName,
        state: 'registered',
        label: _label(j),
        startedAt: j.startedAt,
      ),
  ];

  /// The name when there is one; otherwise the command's first line. The
  /// command was scrubbed when the job was recorded.
  static String _label(BridgeJobRecord j) {
    final name = j.name?.trim();
    if (name != null && name.isNotEmpty) return name;
    final first = j.command.split(RegExp(r'[\r\n]')).first.trim();
    if (first.isEmpty) return 'Job';
    return first.length <= labelChars
        ? first
        : '${first.substring(0, labelChars)}…';
  }

  @override
  Stream<void> get changes => jobs.changes;

  @override
  Future<bool> stop(String id) async {
    if (!jobs.known.any((j) => j.id == id)) return false;
    // The person's Stop, not the assistant's stop_job.
    return jobs.stopByUser(id);
  }
}

/// The app side of the phone controller: one session per connected phone
/// (a [BridgeConnection] whose client is a controller), at most
/// [maxSessions] at once.
///
/// A session gets a snapshot, then events, and may answer cards and stop
/// grants and items. Every action goes through the same call the app's own
/// buttons make ([BridgeApprovals.answer], [BridgeGrants.revoke],
/// [BridgeControlSource.stop]); the tool host's checks after a yes run the
/// same either way. There is no message that pairs, changes a setting or a
/// host's access, or calls a tool.
///
/// While the app is locked a session stays open but sees nothing (an empty
/// snapshot with `locked`) and every action is refused. The bridge service
/// closes sessions when Phone control is switched off, the bridge goes off,
/// or the phone's pairing is removed.
class BridgeControlServer {
  BridgeControlServer({
    required this.approvals,
    required this.grants,
    required this.isAppLocked,
    required this.settings,
    this.audit,
    List<BridgeControlSource> sources = const [],
    this.maxSessions = bridgeControlMaxSessions,
    this.activityLimit = bridgeControlActivityLimit,
    DateTime Function()? clock,
  }) : sources = List.unmodifiable(sources),
       _clock = clock ?? DateTime.now;

  final BridgeApprovals approvals;
  final BridgeGrants grants;
  final bool Function() isAppLocked;

  /// Read per action: Phone control, the "allow for a while" length.
  final AppSettings Function() settings;

  /// For recent activity; none is sent without it.
  final BridgeAuditLog? audit;
  final List<BridgeControlSource> sources;
  final int maxSessions;
  final int activityLimit;
  final DateTime Function() _clock;

  final List<_Session> _sessions = [];
  final _changes = StreamController<List<BridgeClient>>.broadcast();
  bool _disposed = false;
  int? _lastMinutes;

  /// The phones connected now, one entry per session.
  List<BridgeClient> get connected => [for (final s in _sessions) s.client];

  /// [connected] after every change.
  Stream<List<BridgeClient>> get connectedChanges => _changes.stream;

  /// Serves [connection] until it closes. Closed at once, with nothing
  /// sent, unless its client is a paired controller and Phone control is
  /// on; with an error line first when [maxSessions] are already open.
  Future<void> serve(BridgeConnection connection) async {
    if (_disposed ||
        !bridgeClientMayControl(connection.client) ||
        !settings().bridgePhoneControl) {
      await connection.close();
      return;
    }
    if (_sessions.length >= maxSessions) {
      connection.send(
        const ControlError(
          ControlErrorCode.tooManySessions,
          'Two phones are already connected to this computer.',
        ).encode(),
      );
      await connection.close();
      return;
    }
    final session = _Session(this, connection);
    _sessions.add(session);
    _publish();
    try {
      await session.run();
    } finally {
      _sessions.remove(session);
      _publish();
    }
  }

  /// The app locked or unlocked: every session starts over from a fresh
  /// snapshot (empty while locked).
  void lockChanged(bool locked) {
    for (final s in _sessions.toList()) {
      s.resync();
    }
  }

  /// Phone control switched off closes every session; a new "allow for a
  /// while" length is sent again with the cards it applies to.
  void settingsChanged(AppSettings s) {
    if (!s.bridgePhoneControl) {
      unawaited(
        closeAll(
          message: 'Phone control was switched off on the computer.',
        ),
      );
      return;
    }
    final minutes = s.bridgeTimedApprovalMinutes;
    final before = _lastMinutes;
    _lastMinutes = minutes;
    if (before != null && before != minutes) {
      for (final session in _sessions.toList()) {
        session.resync();
      }
    }
  }

  /// Closes the sessions of controllers not in [clientIds]: their pairing
  /// was removed, and they lose the session now, not at the next connect.
  void closeClientsExcept(Set<String> clientIds) {
    for (final s in _sessions.toList()) {
      if (!clientIds.contains(s.client.id)) {
        unawaited(
          s.close(message: "This phone's pairing was removed on the computer."),
        );
      }
    }
  }

  /// Closes every session, telling each phone [message] when given.
  Future<void> closeAll({String? message}) async {
    for (final s in _sessions.toList()) {
      await s.close(message: message);
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    await closeAll();
    await _changes.close();
  }

  void _publish() {
    if (!_changes.isClosed) _changes.add(connected);
  }

  // ---------------------------------------------------------- conversions

  ControlState _state(BridgeClient client) => ControlState(
    locked: isAppLocked(),
    timedMinutes: settings().bridgeTimedApprovalMinutes,
    controller: visibleLine(client.name, maxChars: bridgeControlMaxNameChars),
  );

  /// Whether "allow for a while" may be offered for [summary]: exactly what
  /// [BridgeApprovals.answer] would honour.
  static bool timedAllowedFor(BridgeChangeSummary summary, int minutes) =>
      minutes > 0 && summary is! TerminalSummary && summary is! DesktopSummary;

  /// [r] as the desktop card shows it, every text made visible-safe the way
  /// the card makes it.
  static ControlApproval approvalFrom(
    BridgeApprovalRequest r, {
    required int timedMinutes,
    required DateTime now,
  }) {
    String name(String s) =>
        visibleLine(s, maxChars: bridgeControlMaxNameChars);
    final summary = r.summary;
    var kind = ControlApprovalKind.other;
    ControlCommand? command;
    ControlFileWrite? file;
    ControlService? service;
    ControlJobStart? job;
    if (summary is CommandSummary) {
      kind = ControlApprovalKind.command;
      command = ControlCommand(
        hosts: [for (final h in summary.hostNames) name(h)],
        command: ControlVisibleText.render(summary.command),
      );
    } else if (summary is FileWriteSummary) {
      kind = ControlApprovalKind.fileWrite;
      file = ControlFileWrite(
        path: ControlVisibleText.render(summary.path, breakLines: false),
        bytes: summary.bytes,
        replacesExisting: summary.replacesExisting,
        previewKind: ControlPreviewKind.fromWire(summary.previewKind.name),
        preview: ControlVisibleText.render(summary.preview),
      );
    } else if (summary is ServiceActionSummary) {
      kind = ControlApprovalKind.service;
      const known = {'start', 'stop', 'restart', 'reload'};
      service = ControlService(
        unit: visibleLine(summary.unit, maxChars: 200),
        action: known.contains(summary.action)
            ? summary.action
            : visibleLine(summary.action, maxChars: 40),
      );
    } else if (summary is TerminalSummary) {
      kind = ControlApprovalKind.terminal;
    } else if (summary is DesktopSummary) {
      kind = ControlApprovalKind.desktop;
    } else if (summary is JobStartSummary) {
      kind = ControlApprovalKind.jobStart;
      final cwd = summary.cwd;
      final jobName = summary.name;
      job = ControlJobStart(
        command: ControlVisibleText.render(summary.command),
        cwd: cwd == null
            ? null
            : ControlVisibleText.render(cwd, breakLines: false),
        name: jobName == null ? null : name(jobName),
      );
    }
    final left = r.expiresAt.difference(now);
    return ControlApproval(
      id: r.id,
      assistant: name(r.client.name),
      host: name(r.hostName),
      tool: visibleLine(r.tool, maxChars: 100),
      kind: kind,
      remaining: left.isNegative ? Duration.zero : left,
      timedAllowed: timedAllowedFor(summary, timedMinutes),
      command: command,
      file: file,
      service: service,
      job: job,
    );
  }

  /// The opaque id a grant is stopped by.
  static String grantId(BridgeGrant g) =>
      base64Url.encode(utf8.encode('${g.clientId}\n${g.hostId}'));

  List<ControlGrant> _grants() {
    final now = _clock();
    return [
      for (final g in grants.current)
        ControlGrant(
          id: grantId(g),
          assistant: visibleLine(
            g.clientName ?? 'AI assistant',
            maxChars: bridgeControlMaxNameChars,
          ),
          host: visibleLine(
            g.hostName ?? '',
            maxChars: bridgeControlMaxNameChars,
          ),
          remaining: g.remainingAt(now),
        ),
    ];
  }

  List<ControlItem> _items() => [
    for (final source in sources)
      for (final i in source.current)
        ControlItem(
          kind: source.kind,
          id: i.id,
          assistant: visibleLine(
            i.clientName,
            maxChars: bridgeControlMaxNameChars,
          ),
          host: visibleLine(i.hostName, maxChars: bridgeControlMaxNameChars),
          state: visibleLine(i.state, maxChars: 40),
          label: i.label == null
              ? null
              : visibleLine(i.label!, maxChars: bridgeControlMaxNameChars),
          startedAt: i.startedAt,
        ),
  ];

  static ControlActivity activityFrom(BridgeAuditEntry e) => ControlActivity(
    ts: e.ts,
    assistant: visibleLine(e.client, maxChars: bridgeControlMaxNameChars),
    host: e.host == null
        ? null
        : visibleLine(e.host!, maxChars: bridgeControlMaxNameChars),
    tool: visibleLine(e.tool, maxChars: 100),
    outcome: e.outcome.name,
    approval: e.approval.wire,
    detail: visibleLine(e.detail, maxChars: 500),
    args: visibleLine(e.args, maxChars: 500),
    via: e.via == null ? null : visibleLine(e.via!, maxChars: 200),
  );
}

/// One phone's session.
class _Session {
  _Session(this.server, this.connection);

  final BridgeControlServer server;
  final BridgeConnection connection;
  BridgeClient get client => connection.client;

  final Set<String> _sent = {};
  final List<BridgeAuditEntry> _heldActivity = [];
  final List<StreamSubscription<Object?>> _subs = [];
  final Completer<void> _done = Completer<void>();
  bool _closed = false;

  /// True while a snapshot is being put together: live events wait for it
  /// (the snapshot is built from the state after the wait, so nothing is
  /// lost but activity recorded in that moment).
  bool get _syncing => _syncsQueued > 0;
  int _syncsQueued = 0;
  Future<void> _chain = Future<void>.value();

  bool get _locked => server.isAppLocked();

  Future<void> run() async {
    _subs
      ..add(
        connection.lines.listen(
          _onLine,
          onDone: () => unawaited(close()),
          onError: (Object _) => unawaited(close()),
        ),
      )
      ..add(server.approvals.pending.listen(_onPending))
      ..add(server.approvals.ended.listen(_onEnded))
      ..add(server.grants.changes.skip(1).listen((_) => _sendGrants()))
      ..addAll([
        for (final source in server.sources)
          source.changes.listen((_) => _sendItems()),
      ]);
    final audit = server.audit;
    if (audit != null) _subs.add(audit.entries.listen(_onActivity));
    resync();
    await _done.future;
  }

  void _send(ControlEvent event) {
    if (_closed) return;
    connection.send(event.encode());
  }

  /// A fresh snapshot, then each waiting card, then `synced`. Queued, so
  /// two in quick succession (lock then unlock) arrive in order.
  void resync() {
    // Counted from now, not from when the queued sync starts, so a live
    // event that lands in between is not sent ahead of the snapshot.
    _syncsQueued++;
    _chain = _chain.then((_) => _sync());
  }

  /// Never throws; ends its own count synchronously after the last send.
  Future<void> _sync() async {
    try {
      if (_closed) return;
      final locked = _locked;
      var activity = const <ControlActivity>[];
      var recent = const <BridgeAuditEntry>[];
      final audit = server.audit;
      if (!locked && audit != null) {
        // Anything recorded before this point is on disk, so the read has
        // it; what is recorded while the read runs is held, and sent after
        // the snapshot unless the read had it.
        _heldActivity.clear();
        recent = await audit.recent(limit: server.activityLimit);
        activity = [for (final e in recent) BridgeControlServer.activityFrom(e)];
      }
      if (_closed) return;
      // Read again after the wait: the lock may have come down meanwhile.
      final lockedNow = _locked;
      _sent.clear();
      _send(
        ControlSnapshot(
          state: server._state(client),
          grants: lockedNow ? const [] : server._grants(),
          items: lockedNow ? const [] : server._items(),
          activity: lockedNow ? const [] : activity,
        ),
      );
      if (!lockedNow) {
        for (final r in server.approvals.current) {
          _sendApproval(r);
        }
      }
      final held = List.of(_heldActivity);
      _heldActivity.clear();
      if (!lockedNow) {
        String key(BridgeAuditEntry e) =>
            '${e.ts.microsecondsSinceEpoch}|${e.client}|${e.tool}|${e.args}';
        final known = {for (final e in recent) key(e)};
        for (final e in held) {
          if (known.add(key(e))) {
            _send(ControlActivityAdded(BridgeControlServer.activityFrom(e)));
          }
        }
      }
      _send(const ControlSynced());
    } catch (_) {
      // A failed snapshot leaves the phone waiting for `synced`; the next
      // reset (or reconnect) tries again.
    } finally {
      _syncsQueued--;
    }
  }

  void _sendApproval(BridgeApprovalRequest r) {
    if (!_sent.add(r.id)) return;
    _send(
      ControlApprovalAdded(
        BridgeControlServer.approvalFrom(
          r,
          timedMinutes: server.settings().bridgeTimedApprovalMinutes,
          now: server._clock(),
        ),
      ),
    );
  }

  void _onPending(List<BridgeApprovalRequest> list) {
    if (_syncing || _locked) return;
    for (final r in list) {
      _sendApproval(r);
    }
  }

  void _onEnded(BridgeApprovalEnd end) {
    if (!_sent.remove(end.request.id)) return;
    _send(ControlApprovalRemoved(end.request.id, _endOf(end.outcome)));
  }

  static ControlApprovalEnd _endOf(BridgeApprovalOutcome o) =>
      switch (o.kind) {
        BridgeApprovalOutcomeKind.allowedOnce => ControlApprovalEnd.allowedOnce,
        BridgeApprovalOutcomeKind.allowedForAWhile =>
          ControlApprovalEnd.allowedForAWhile,
        BridgeApprovalOutcomeKind.denied => ControlApprovalEnd.denied,
        BridgeApprovalOutcomeKind.timedOut => ControlApprovalEnd.timedOut,
        BridgeApprovalOutcomeKind.withdrawn ||
        BridgeApprovalOutcomeKind.busy => ControlApprovalEnd.withdrawn,
      };

  void _sendGrants() {
    if (_syncing || _locked) return;
    _send(ControlGrantsChanged(server._grants()));
  }

  void _sendItems() {
    if (_syncing || _locked) return;
    _send(ControlItemsChanged(server._items()));
  }

  void _onActivity(BridgeAuditEntry e) {
    if (_locked) return;
    if (_syncing) {
      if (_heldActivity.length < 1000) _heldActivity.add(e);
      return;
    }
    _send(ControlActivityAdded(BridgeControlServer.activityFrom(e)));
  }

  // ------------------------------------------------------------- requests

  void _reply(
    String re, {
    ControlErrorCode? code,
    String? message,
    String? outcome,
  }) {
    _send(
      ControlResult(
        re: re,
        ok: code == null,
        code: code,
        message: message,
        outcome: outcome,
      ),
    );
  }

  void _onLine(String line) {
    if (_closed) return;
    // Bytes, not characters: a cheap check first, the exact one only for a
    // line long enough to matter.
    if (line.length > bridgeControlMaxInboundLineBytes ~/ 4 &&
        utf8.encode(line).length > bridgeControlMaxInboundLineBytes) {
      _send(
        const ControlError(
          ControlErrorCode.tooLarge,
          'That message is too long; it was ignored.',
        ),
      );
      return;
    }
    final ControlRequest request;
    try {
      request = ControlRequest.decode(line);
    } on ControlProtocolException catch (e) {
      final re = e.re;
      if (re != null) {
        _reply(re, code: e.code, message: e.message);
      } else {
        _send(ControlError(e.code, e.message));
      }
      return;
    }
    unawaited(_handle(request));
  }

  Future<void> _handle(ControlRequest request) async {
    final re = request.re;
    if (request is ControlPingRequest) {
      _reply(re);
      return;
    }
    if (_locked) {
      _reply(
        re,
        code: ControlErrorCode.locked,
        message: 'SecureShell Go is locked on the computer.',
      );
      return;
    }
    switch (request) {
      case ControlAnswerRequest():
        _answer(request);
      case ControlStopGrantRequest(:final grantId):
        BridgeGrant? match;
        for (final g in server.grants.current) {
          if (BridgeControlServer.grantId(g) == grantId) match = g;
        }
        if (match == null) {
          _reply(
            re,
            code: ControlErrorCode.notFound,
            message: 'That approval has already ended.',
          );
          return;
        }
        server.grants.revoke(match.clientId, match.hostId);
        _reply(re);
      case ControlStopItemRequest(:final kind, :final itemId):
        var stopped = false;
        for (final source in server.sources) {
          if (source.kind != kind) continue;
          try {
            if (await source.stop(itemId)) stopped = true;
          } catch (_) {
            // Reported as not stopped below.
          }
        }
        if (stopped) {
          _reply(re);
        } else {
          _reply(
            re,
            code: ControlErrorCode.notFound,
            message: 'That has already ended.',
          );
        }
      case ControlPingRequest():
        _reply(re);
    }
  }

  void _answer(ControlAnswerRequest request) {
    final re = request.re;
    BridgeApprovalRequest? waiting;
    for (final r in server.approvals.current) {
      if (r.id == request.approvalId) waiting = r;
    }
    const gone =
        'This request is no longer waiting: it was answered, withdrawn or '
        'timed out.';
    if (waiting == null) {
      _reply(re, code: ControlErrorCode.notFound, message: gone);
      return;
    }
    final BridgeApprovalAnswer answer;
    switch (request.answer) {
      case ControlAnswer.deny:
        answer = BridgeApprovalAnswer.deny;
      case ControlAnswer.once:
        answer = BridgeApprovalAnswer.allowOnce;
      case ControlAnswer.forMinutes:
        final minutes = server.settings().bridgeTimedApprovalMinutes;
        if (!BridgeControlServer.timedAllowedFor(waiting.summary, minutes) ||
            request.minutes != minutes) {
          _reply(
            re,
            code: ControlErrorCode.notAllowed,
            message: minutes <= 0
                ? '"Allow for a while" is off on the computer.'
                : 'This can only be allowed once, or for $minutes minutes.',
          );
          return;
        }
        answer = BridgeApprovalAnswer.allowForAWhile;
    }
    final outcome = server.approvals.answer(
      waiting.id,
      answer,
      via: 'controller:${client.name}',
    );
    if (outcome == null) {
      _reply(re, code: ControlErrorCode.notFound, message: gone);
      return;
    }
    final end = _endOf(outcome);
    if (end == ControlApprovalEnd.timedOut) {
      _reply(
        re,
        code: ControlErrorCode.notFound,
        message: 'This request timed out before the answer arrived.',
        outcome: end.name,
      );
      return;
    }
    _reply(re, outcome: end.name);
  }

  Future<void> close({String? message}) async {
    if (_closed) return;
    if (message != null) {
      _send(ControlError(ControlErrorCode.refused, message));
    }
    _closed = true;
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    _subs.clear();
    try {
      await connection.close();
    } catch (_) {
      // Already gone.
    }
    if (!_done.isCompleted) _done.complete();
  }
}
