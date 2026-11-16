import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../bridge/bridge_control_protocol.dart';
import 'remote_exec_channel.dart';

export '../bridge/bridge_control_protocol.dart'
    show
        ControlActivity,
        ControlAnswer,
        ControlApproval,
        ControlApprovalEnd,
        ControlApprovalKind,
        ControlCommand,
        ControlErrorCode,
        ControlFileWrite,
        ControlGrant,
        ControlItem,
        ControlItemKind,
        ControlJobStart,
        ControlPreviewKind,
        ControlService,
        ControlVisibleText;
export 'remote_exec_channel.dart';

/// Where a [RemoteBridgeController] is.
enum RemoteBridgePhase {
  /// Not connected yet.
  idle,

  /// The command is starting and the token is on its way.
  connecting,

  /// Connected; the computer is sending its state.
  syncing,

  /// Up to date; events arrive as they happen.
  live,

  /// Ended, by [RemoteBridgeController.close] or because the session did
  /// ([RemoteBridgeState.error] says why). Reconnecting is a new
  /// controller.
  closed,
}

/// Why a session could not start, or ended.
enum RemoteBridgeErrorKind {
  /// SecureShell Go is not running on the computer, or its AI Bridge is off.
  notRunning,

  /// The computer refused this phone: not paired, its pairing was removed,
  /// or Phone control is off there. These read the same on purpose.
  refused,

  /// No SecureShell Go launcher (1.8.0 or newer) on the computer.
  launcherNotFound,

  /// Two phones are already connected.
  tooManySessions,

  /// The SSH channel ended under the session.
  connectionLost,

  /// The computer sent something this phone cannot read (versions differ).
  protocol,

  /// The command could not be started, or anything else.
  failed,
}

class RemoteBridgeError implements Exception {
  const RemoteBridgeError(this.kind, this.message);

  final RemoteBridgeErrorKind kind;

  /// Plain text from the computer or from here, safe to show as one line.
  final String message;

  @override
  String toString() => 'RemoteBridgeError(${kind.name}: $message)';
}

/// Everything the phone knows about the computer's bridge. Immutable; a
/// new one arrives on [RemoteBridgeController.states] after every change.
class RemoteBridgeState {
  RemoteBridgeState({
    this.phase = RemoteBridgePhase.idle,
    this.locked = false,
    this.timedMinutes = 0,
    this.controllerName = '',
    List<ControlApproval> approvals = const [],
    List<ControlGrant> grants = const [],
    List<ControlItem> items = const [],
    List<ControlActivity> activity = const [],
    this.error,
  }) : approvals = List.unmodifiable(approvals),
       grants = List.unmodifiable(grants),
       items = List.unmodifiable(items),
       activity = List.unmodifiable(activity);

  final RemoteBridgePhase phase;

  /// SecureShell Go is locked on the computer: nothing is listed and every
  /// action is refused until it is unlocked there.
  final bool locked;

  /// The computer's "Allow for a while" length; 0 means it is off, and only
  /// Deny and Allow once may be offered.
  final int timedMinutes;

  /// This phone's name as paired on the computer.
  final String controllerName;

  /// Waiting cards, oldest first (the one to show is [approvals].first).
  final List<ControlApproval> approvals;
  final List<ControlGrant> grants;

  /// Assistant terminals, desktops and jobs.
  final List<ControlItem> items;

  /// Recent activity, newest first.
  final List<ControlActivity> activity;

  /// Set once the session failed or ended for a reason other than [close].
  final RemoteBridgeError? error;

  RemoteBridgeState copyWith({
    RemoteBridgePhase? phase,
    bool? locked,
    int? timedMinutes,
    String? controllerName,
    List<ControlApproval>? approvals,
    List<ControlGrant>? grants,
    List<ControlItem>? items,
    List<ControlActivity>? activity,
    RemoteBridgeError? error,
  }) => RemoteBridgeState(
    phase: phase ?? this.phase,
    locked: locked ?? this.locked,
    timedMinutes: timedMinutes ?? this.timedMinutes,
    controllerName: controllerName ?? this.controllerName,
    approvals: approvals ?? this.approvals,
    grants: grants ?? this.grants,
    items: items ?? this.items,
    activity: activity ?? this.activity,
    error: error ?? this.error,
  );
}

/// How one action went.
class RemoteActionResult {
  const RemoteActionResult.ok({this.outcome}) : code = null, message = null;

  const RemoteActionResult.failed(ControlErrorCode this.code, this.message)
    : outcome = null;

  /// Null when it worked.
  final ControlErrorCode? code;
  final String? message;

  /// For an answer: how the card ended.
  final ControlApprovalEnd? outcome;

  bool get ok => code == null;

  @override
  String toString() => ok
      ? 'RemoteActionResult.ok(${outcome?.name ?? ''})'
      : 'RemoteActionResult.failed(${code!.wire}: $message)';
}

/// The phone side of "Remote approvals": runs `secureshellgo-mcp control`
/// on the user's computer over an SSH exec channel ([exec]), sends the
/// controller [token] as its first line of stdin, and turns what comes back
/// into [RemoteBridgeState]s.
///
/// ```dart
/// final remote = RemoteBridgeController(
///   exec: remoteExecOver(connection),   // an open SessionTransport
///   token: token,                      // from RemoteControllerTokenStore
/// );
/// remote.states.listen(render);
/// await remote.connect();               // throws RemoteBridgeError
/// await remote.answer(card.id, ControlAnswer.once);
/// ```
///
/// No Flutter; one controller is one session. Reconnecting (after
/// [RemoteBridgePhase.closed]) is the caller's business: make a new one.
class RemoteBridgeController {
  RemoteBridgeController({
    required this.exec,
    required String token,
    String? command,
    this.requestTimeout = const Duration(seconds: 20),
    this.connectTimeout = const Duration(seconds: 30),
    this.activityLimit = 200,
    DateTime Function()? clock,
  })
    // ignore: prefer_initializing_formals
    : _token = token,
      command = command ?? remoteControlCommand(),
      _clock = clock ?? DateTime.now;

  final RemoteExecStarter exec;
  final String _token;

  /// What runs on the computer; [remoteControlCommand] unless a test says.
  final String command;

  /// How long an action waits for the computer's answer.
  final Duration requestTimeout;

  /// How long [connect] waits for the first full state.
  final Duration connectTimeout;

  /// How many activity entries are kept.
  final int activityLimit;
  final DateTime Function() _clock;

  RemoteBridgeState _state = RemoteBridgeState();
  final _states = StreamController<RemoteBridgeState>.broadcast();
  RemoteExecProcess? _process;
  StreamSubscription<List<int>>? _out;
  final _buffer = BytesBuilder(copy: false);
  final Map<String, Completer<RemoteActionResult>> _waiting = {};
  Completer<void>? _connected;
  var _nextRe = 0;
  var _heardFromApp = false;

  RemoteBridgeState get state => _state;

  /// Every new [state], from the next change on.
  Stream<RemoteBridgeState> get states => _states.stream;

  bool get isLive => _state.phase == RemoteBridgePhase.live;

  /// Starts the command and waits for the computer's full state. Throws
  /// [RemoteBridgeError] when the session cannot start; [state] then holds
  /// the same error, with [RemoteBridgePhase.closed].
  Future<void> connect() async {
    if (_state.phase != RemoteBridgePhase.idle) {
      throw StateError('connect() is called once per controller.');
    }
    final connected = _connected = Completer<void>();
    _set(_state.copyWith(phase: RemoteBridgePhase.connecting));
    final RemoteExecProcess process;
    try {
      process = await exec(command);
    } catch (e) {
      _end(
        const RemoteBridgeError(
          RemoteBridgeErrorKind.failed,
          'Could not run the command on the computer.',
        ),
      );
      throw _state.error!;
    }
    if (_state.phase == RemoteBridgePhase.closed) {
      process.close();
      throw _state.error ?? _closedError;
    }
    _process = process;
    _out = process.stdout.listen(
      _onBytes,
      onError: (Object _) => _onChannelEnd(),
      onDone: _onChannelEnd,
      cancelOnError: true,
    );
    try {
      // The token goes on stdin, never on the command line, where other
      // users of the computer could read it.
      process.write(utf8.encode('$_token\n'));
    } catch (_) {
      _onChannelEnd();
    }
    try {
      await connected.future.timeout(connectTimeout);
    } on TimeoutException {
      _end(
        const RemoteBridgeError(
          RemoteBridgeErrorKind.notRunning,
          'The computer did not answer in time.',
        ),
      );
      throw _state.error!;
    }
  }

  static const _closedError = RemoteBridgeError(
    RemoteBridgeErrorKind.connectionLost,
    'The session was closed.',
  );

  /// Answers card [approvalId]. [ControlAnswer.forMinutes] asks for the
  /// computer's own length ([RemoteBridgeState.timedMinutes]); it is
  /// refused here, without asking, when that is off.
  Future<RemoteActionResult> answer(String approvalId, ControlAnswer answer) {
    final minutes = _state.timedMinutes;
    if (answer == ControlAnswer.forMinutes && minutes <= 0) {
      return Future.value(
        const RemoteActionResult.failed(
          ControlErrorCode.notAllowed,
          '"Allow for a while" is off on the computer.',
        ),
      );
    }
    return _request(
      (re) => ControlAnswerRequest(
        re,
        approvalId: approvalId,
        answer: answer,
        minutes: answer == ControlAnswer.forMinutes ? minutes : null,
      ),
    );
  }

  /// Ends a time-limited approval now.
  Future<RemoteActionResult> stopGrant(String grantId) =>
      _request((re) => ControlStopGrantRequest(re, grantId: grantId));

  /// Stops an assistant terminal, desktop or job, as its Stop button on the
  /// computer does.
  Future<RemoteActionResult> stopItem(ControlItemKind kind, String id) =>
      _request((re) => ControlStopItemRequest(re, kind: kind, itemId: id));

  /// Checks the session is still alive.
  Future<RemoteActionResult> ping() => _request(ControlPingRequest.new);

  Future<RemoteActionResult> _request(
    ControlRequest Function(String re) build,
  ) async {
    final process = _process;
    if (process == null ||
        (_state.phase != RemoteBridgePhase.live &&
            _state.phase != RemoteBridgePhase.syncing)) {
      return const RemoteActionResult.failed(
        ControlErrorCode.failed,
        'Not connected to the computer.',
      );
    }
    final re = 'r${++_nextRe}';
    final done = _waiting[re] = Completer<RemoteActionResult>();
    try {
      process.write(utf8.encode('${build(re).encode()}\n'));
    } catch (_) {
      _waiting.remove(re);
      return const RemoteActionResult.failed(
        ControlErrorCode.failed,
        'Not connected to the computer.',
      );
    }
    try {
      return await done.future.timeout(requestTimeout);
    } on TimeoutException {
      _waiting.remove(re);
      return const RemoteActionResult.failed(
        ControlErrorCode.failed,
        'The computer did not answer in time.',
      );
    }
  }

  /// Ends the session: the computer sees the phone leave.
  Future<void> close() async {
    if (_state.phase == RemoteBridgePhase.closed) return;
    final process = _process;
    _end(null);
    if (process != null) {
      try {
        await process.closeInput();
      } catch (_) {}
      process.close();
    }
  }

  // ------------------------------------------------------------ incoming

  void _onBytes(List<int> chunk) {
    var start = 0;
    while (true) {
      final newline = chunk.indexOf(0x0a, start);
      if (newline < 0) break;
      _buffer.add(chunk.sublist(start, newline));
      final bytes = _buffer.takeBytes();
      start = newline + 1;
      _onLine(bytes);
      if (_state.phase == RemoteBridgePhase.closed) return;
    }
    if (start < chunk.length) _buffer.add(chunk.sublist(start));
    if (_buffer.length > bridgeControlMaxOutboundLineBytes) {
      _fail(
        const RemoteBridgeError(
          RemoteBridgeErrorKind.protocol,
          'The computer sent a message that is too long.',
        ),
      );
    }
  }

  void _onLine(List<int> bytes) {
    if (bytes.length > bridgeControlMaxOutboundLineBytes) {
      _fail(
        const RemoteBridgeError(
          RemoteBridgeErrorKind.protocol,
          'The computer sent a message that is too long.',
        ),
      );
      return;
    }
    final String line;
    try {
      line = utf8.decode(bytes).trimRight();
    } on FormatException {
      return;
    }
    if (line.isEmpty) return;
    final ControlEvent event;
    try {
      event = ControlEvent.decode(line, now: _clock());
    } on ControlProtocolException catch (e) {
      // Before the first message a login banner or a shell's chatter may
      // come first; after it, an unknown message is from a newer computer
      // and is skipped. A snapshot this phone cannot read ends it.
      if (_heardFromApp && line.contains('"snapshot"')) {
        _fail(RemoteBridgeError(RemoteBridgeErrorKind.protocol, e.message));
      }
      return;
    }
    _heardFromApp = true;
    _onEvent(event);
  }

  void _onEvent(ControlEvent event) {
    switch (event) {
      case ControlSnapshot():
        _set(
          _state.copyWith(
            phase: RemoteBridgePhase.syncing,
            locked: event.state.locked,
            timedMinutes: event.state.timedMinutes,
            controllerName: event.state.controller,
            approvals: const [],
            grants: event.grants,
            items: event.items,
            activity: event.activity.take(activityLimit).toList(),
          ),
        );
      case ControlApprovalAdded(:final approval):
        _set(
          _state.copyWith(
            approvals: [
              for (final a in _state.approvals)
                if (a.id != approval.id) a,
              approval,
            ],
          ),
        );
      case ControlApprovalRemoved(:final id):
        _set(
          _state.copyWith(
            approvals: [
              for (final a in _state.approvals)
                if (a.id != id) a,
            ],
          ),
        );
      case ControlSynced():
        _set(_state.copyWith(phase: RemoteBridgePhase.live));
        final c = _connected;
        if (c != null && !c.isCompleted) c.complete();
      case ControlStateChanged(:final state):
        _set(
          _state.copyWith(
            locked: state.locked,
            timedMinutes: state.timedMinutes,
            controllerName: state.controller,
          ),
        );
      case ControlGrantsChanged(:final grants):
        _set(_state.copyWith(grants: grants));
      case ControlItemsChanged(:final items):
        _set(_state.copyWith(items: items));
      case ControlActivityAdded(:final entry):
        _set(
          _state.copyWith(
            activity: [entry, ..._state.activity].take(activityLimit).toList(),
          ),
        );
      case ControlResult():
        final done = _waiting.remove(event.re);
        if (done == null || done.isCompleted) return;
        if (event.ok) {
          done.complete(
            RemoteActionResult.ok(
              outcome: event.outcome == null
                  ? null
                  : ControlApprovalEnd.fromWire(event.outcome),
            ),
          );
        } else {
          done.complete(
            RemoteActionResult.failed(
              event.code ?? ControlErrorCode.failed,
              event.message ?? '',
            ),
          );
        }
      case ControlError(:final code, :final message):
        final kind = switch (code) {
          ControlErrorCode.notRunning => RemoteBridgeErrorKind.notRunning,
          ControlErrorCode.refused => RemoteBridgeErrorKind.refused,
          ControlErrorCode.launcherNotFound =>
            RemoteBridgeErrorKind.launcherNotFound,
          ControlErrorCode.tooManySessions =>
            RemoteBridgeErrorKind.tooManySessions,
          _ => null,
        };
        // A complaint about one line (too long, malformed) is not the end
        // of the session; these are, and the channel closes right after.
        if (kind != null) _fail(RemoteBridgeError(kind, message));
    }
  }

  void _onChannelEnd() {
    if (_state.phase == RemoteBridgePhase.closed) return;
    final code = _process?.exitCode;
    _fail(
      _heardFromApp
          ? const RemoteBridgeError(
              RemoteBridgeErrorKind.connectionLost,
              'The connection to the computer ended.',
            )
          : code == 127
          ? const RemoteBridgeError(
              RemoteBridgeErrorKind.launcherNotFound,
              'SecureShell Go was not found on this computer.',
            )
          : const RemoteBridgeError(
              RemoteBridgeErrorKind.failed,
              'The computer ended the command without an answer.',
            ),
    );
  }

  /// Ends the session with [error], closing the channel.
  void _fail(RemoteBridgeError error) {
    if (_state.phase == RemoteBridgePhase.closed) return;
    final process = _process;
    _end(error);
    process?.close();
  }

  void _end(RemoteBridgeError? error) {
    if (_state.phase == RemoteBridgePhase.closed) return;
    unawaited(_out?.cancel());
    _out = null;
    _process = null;
    _set(_state.copyWith(phase: RemoteBridgePhase.closed, error: error));
    for (final done in _waiting.values) {
      if (!done.isCompleted) {
        done.complete(
          const RemoteActionResult.failed(
            ControlErrorCode.failed,
            'The connection to the computer ended.',
          ),
        );
      }
    }
    _waiting.clear();
    final c = _connected;
    if (c != null && !c.isCompleted) {
      c.completeError(error ?? _closedError);
      // connect() rethrows from [state]; nobody else awaits this.
      unawaited(c.future.catchError((Object _) {}));
    }
    unawaited(_states.close());
  }

  void _set(RemoteBridgeState next) {
    _state = next;
    if (!_states.isClosed) _states.add(next);
  }
}
