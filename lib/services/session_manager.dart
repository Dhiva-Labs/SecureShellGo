import 'dart:async';

import '../models/host.dart';
import 'device_storage.dart';
import 'session_controller.dart';
import 'session_foreground.dart';
import 'sftp_service.dart';
import 'ssh_service.dart';

export 'session_controller.dart'
    show DestinationCredentialResolver, ReconnectSupport;

/// Which view of a session is in front.
///
/// Lives here rather than on the screen because it is per-*session* state: with
/// several sessions open, one can be showing its file browser while another
/// shows its shell, and flipping between them must not reshuffle either.
enum SessionView { terminal, files }

/// Builds the controller for a newly opened session.
///
/// A seam, so a test can hand the manager sessions wired to fakes — a fake
/// transport, a scripted filesystem, a keep-alive timer it drives by hand —
/// without the manager knowing anything about any of that.
typedef SessionControllerFactory = SessionController Function(
  SessionTransport connection,
  RemoteTargetResolver resolveRemoteTarget,
  DestinationCredentialResolver? resolveDestinationCredentials,
);

/// One open session, and the small amount of state that belongs to it rather
/// than to whatever is currently drawing it.
///
/// [view] and [filesBuilt] used to be fields on `_SessionScreenState`. With one
/// session that was the same thing; with several it is not, and a view-held
/// copy would mean switching tabs quietly moved the *other* session's browser
/// back to its terminal.
class ManagedSession {
  ManagedSession._({
    required this.id,
    required this.controller,
    required SessionView view,
  })  : _view = view,
        _filesBuilt = view == SessionView.files;

  /// Unique for the life of the process, and unique *per open* rather than per
  /// host — two sessions on the same machine are two sessions.
  final String id;

  final SessionController controller;

  Host get host => controller.host;

  bool get isClosed => controller.isClosed;

  SessionView get view => _view;
  SessionView _view;

  /// Whether this session's file browser has ever been asked for. It opens a
  /// second SSH channel, so it is not built until it is wanted.
  bool get filesBuilt => _filesBuilt;
  bool _filesBuilt;
}

/// Every session that is open right now, in the order they were opened.
///
/// This is what replaced "the screen owns the one connection". A session's
/// lifetime is no longer a route's lifetime: leaving the sessions screen for
/// the host list — which is how a second session gets started — must not tear
/// down the first, and a running `htop` in one must not notice the user
/// working in another. So ownership lifts one more level, out of the widget
/// tree entirely, to an object built in `main.dart` and passed down. Sessions
/// end when the user closes them, when their transport dies, or when the app
/// does.
///
/// It is also the app's answer to two questions nothing else can answer: which
/// sessions a share can be handed to (what `SessionRegistry` used to do), and
/// which sessions a server-to-server transfer can be pointed at.
///
/// Free of Flutter imports like the rest of `services/`; listeners get a plain
/// broadcast [Stream], and every session's own [SessionController.changes] is
/// folded into it so a view needs one subscription rather than N.
class SessionManager {
  SessionManager({
    SessionForegroundController? foreground,
    SessionControllerFactory? createController,
    DestinationCredentialResolver? resolveDestinationCredentials,
    ReconnectSupport? reconnect,
  })  : _foreground = foreground ?? SessionForegroundController.instance,
        // ignore: prefer_initializing_formals
        _createController = createController,
        // ignore: prefer_initializing_formals
        _resolveDestinationCredentials = resolveDestinationCredentials,
        // ignore: prefer_initializing_formals
        _reconnect = reconnect;

  /// Builds the controller for a new session, honouring the injected factory
  /// when there is one.
  ///
  /// An instance method rather than the static default it replaced, because
  /// what the default now needs — [_reconnect] — is per-manager state.
  /// Keeping [SessionControllerFactory] at three parameters is deliberate:
  /// it is a test seam with several implementations already written against
  /// it, and a session built through it is a session built with fakes, which
  /// has no business reconnecting to anything.
  SessionController _newController(
    SessionTransport connection,
    RemoteTargetResolver resolveRemoteTarget,
    DestinationCredentialResolver? resolveDestinationCredentials,
  ) {
    final custom = _createController;
    if (custom != null) {
      return custom(
        connection,
        resolveRemoteTarget,
        resolveDestinationCredentials,
      );
    }
    return SessionController(
      connection: connection,
      resolveRemoteTarget: resolveRemoteTarget,
      resolveDestinationCredentials: resolveDestinationCredentials,
      reconnect: _reconnect,
    );
  }

  final SessionForegroundController _foreground;
  final SessionControllerFactory? _createController;

  /// How a session rebuilds its own transport after an unexpected drop. Null
  /// in tests and anywhere the app has no SSH service and credential store to
  /// offer, in which case a dropped session simply stays dropped.
  final ReconnectSupport? _reconnect;

  /// The direct-copy path needs the destination host's key at the moment
  /// the transfer runs; the manager is the one thing above the sessions
  /// that has (or, in tests, does not have) the credential store wired in.
  final DestinationCredentialResolver? _resolveDestinationCredentials;

  final List<ManagedSession> _sessions = [];
  final Map<String, StreamSubscription<void>> _watchers = {};
  final _changes = StreamController<void>.broadcast();

  var _idCounter = 0;
  String? _activeId;

  /// The last label handed to the foreground service, so the notification is
  /// only rewritten when it would actually say something different.
  String? _sentLabel;

  /// Fires whenever the set of sessions changes, one of them changes state, or
  /// a different one is brought to the front.
  Stream<void> get changes => _changes.stream;

  /// Every open session, oldest first — the order the tab strip shows.
  List<ManagedSession> get sessions => List.unmodifiable(_sessions);

  int get length => _sessions.length;

  bool get isEmpty => _sessions.isEmpty;

  bool get isNotEmpty => _sessions.isNotEmpty;

  /// The session the user is looking at, or null when nothing is open.
  ManagedSession? get active => byId(_activeId);

  String? get activeId => _activeId;

  /// How many sessions still have a live transport. What the host list shows,
  /// and the honest count for "you left something connected".
  int get liveCount => _sessions.where((s) => !s.isClosed).length;

  ManagedSession? byId(String? id) {
    if (id == null) return null;
    for (final session in _sessions) {
      if (session.id == id) return session;
    }
    return null;
  }

  /// The live sessions on [hostId]. More than one is legitimate — two shells
  /// on the same box is an ordinary thing to want — so this is a list, and the
  /// caller asks the user what they meant rather than silently reusing.
  List<ManagedSession> liveForHost(String hostId) => _sessions
      .where((s) => s.host.id == hostId && !s.isClosed)
      .toList(growable: false);

  /// Where a server-to-server transfer started on [id] could go: every *other*
  /// session whose transport is still up.
  List<ManagedSession> destinationsFor(String id) => _sessions
      .where((s) => s.id != id && !s.isClosed)
      .toList(growable: false);

  /// Adopts an authenticated [connection] as a new session and brings it to
  /// the front.
  ///
  /// The connection belongs to the manager from here: it is closed when the
  /// session is closed, and not before.
  ManagedSession open(
    SessionTransport connection, {
    SessionView initialView = SessionView.terminal,
    List<PickedLocalFile> uploads = const [],
  }) {
    final id = 'session-${_idCounter++}';
    final controller = _newController(
      connection,
      _resolverFor(id),
      _resolveDestinationCredentials,
    );
    final entry = ManagedSession._(
      id: id,
      controller: controller,
      // A share arrives with files and no directory, and the file browser is
      // where the directory gets picked.
      view: uploads.isEmpty ? initialView : SessionView.files,
    );
    _sessions.add(entry);
    _activeId = id;
    _watchers[id] = controller.changes.listen((_) => _notify());
    if (uploads.isNotEmpty) controller.requestUpload(uploads);

    final label = _foregroundLabel();
    unawaited(_foreground.acquire(label));
    if (_sessions.length == 1) {
      // The 0 → 1 edge: `acquire` has already sent this label.
      _sentLabel = label;
    } else {
      _syncForegroundLabel();
    }

    _notify();
    return entry;
  }

  /// Resolves another session's remote filesystem for a transfer running on
  /// the session identified by [sourceId].
  ///
  /// Deliberately refuses to resolve a session to itself: a same-session copy
  /// is a rename or a `cp`, not a transfer, and routing one through here would
  /// read the file and write it back over its own channel.
  RemoteTargetResolver _resolverFor(String sourceId) {
    return (String targetId) async {
      if (targetId == sourceId) {
        throw const SftpFailure(
          'A file cannot be copied to the session it is already on.',
        );
      }
      final target = byId(targetId);
      if (target == null) {
        throw const SftpFailure(
          'That destination session has been closed. Open it again to finish '
          'this transfer.',
        );
      }
      if (target.isClosed) {
        throw const SftpFailure(
          'The connection to the destination server has dropped. Reconnect to '
          'finish this transfer.',
        );
      }
      return target.controller;
    };
  }

  /// Brings [id] to the front. Unknown ids are ignored.
  void select(String id) {
    if (_activeId == id || byId(id) == null) return;
    _activeId = id;
    _notify();
  }

  /// Switches one session between its shell and its file browser.
  void showView(String id, SessionView view) {
    final session = byId(id);
    if (session == null || session._view == view) return;
    session._view = view;
    if (view == SessionView.files) session._filesBuilt = true;
    _notify();
  }

  /// Notes that a session's file browser is on screen whether it was asked
  /// for or not — the wide layout shows both panes at once, so folding into it
  /// builds the browser without anyone tapping anything.
  void markFilesBuilt(String id) {
    final session = byId(id);
    if (session == null || session._filesBuilt) return;
    session._filesBuilt = true;
    // No notify: this is a consequence of a layout that is already being
    // built, not a state change anything else needs to react to.
  }

  /// Ends one session and disposes it. The others carry on untouched.
  ///
  /// The next session in the strip takes the front, so closing the tab you are
  /// looking at does not dump you on a blank screen.
  Future<void> close(String id) async {
    final index = _sessions.indexWhere((s) => s.id == id);
    if (index < 0) return;

    final entry = _sessions.removeAt(index);
    await _watchers.remove(id)?.cancel();

    if (_activeId == id) {
      _activeId = _sessions.isEmpty
          ? null
          : _sessions[index < _sessions.length ? index : _sessions.length - 1]
              .id;
    }
    _notify();

    // Release before disposing: the count is what keeps the service alive for
    // the *other* sessions, and disposing is the slow part.
    unawaited(_foreground.release());
    _syncForegroundLabel();

    await entry.controller.dispose();
  }

  /// Ends every session — the app shutting down, not a user action.
  Future<void> closeAll() async {
    for (final id in _sessions.map((s) => s.id).toList(growable: false)) {
      await close(id);
    }
  }

  /// What the ongoing notification should say.
  ///
  /// One session is named; several are counted, because naming the first of
  /// four is worse than not naming any — it reads as the only one.
  String _foregroundLabel() {
    if (_sessions.isEmpty) return '';
    if (_sessions.length == 1) return _sessions.single.host.displayName;
    return '${_sessions.length} sessions connected';
  }

  void _syncForegroundLabel() {
    final label = _foregroundLabel();
    if (label.isEmpty) {
      _sentLabel = null;
      return;
    }
    if (label == _sentLabel) return;
    _sentLabel = label;
    unawaited(_foreground.relabel(label));
  }

  void _notify() {
    if (_changes.isClosed) return;
    _changes.add(null);
  }

  Future<void> dispose() async {
    await closeAll();
    await _changes.close();
  }
}
