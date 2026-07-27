import 'session_controller.dart';

/// A live session, plus a way back to the screen showing it.
class LiveSession {
  const LiveSession({required this.session, required this.bringToFront});

  final SessionController session;

  /// Pops whatever is stacked above that session's screen, so a share that
  /// reuses an existing connection lands the user on the session they already
  /// had rather than on a second copy of it. Returns false if the screen has
  /// gone away since it registered.
  final bool Function() bringToFront;
}

/// The sessions that are open right now, by host id.
///
/// Exists for one reason: a file shared into the app from somewhere else must
/// reuse the connection the user already has open rather than authenticate a
/// second time — same credentials, same host-key prompt, same foreground
/// service, all for a connection that is already sitting there.
///
/// Process-wide by nature (a share can arrive with any screen in front), so
/// it is a singleton in the same shape as `SessionForegroundController` —
/// `instance` for production, a fresh one for tests. Registration is keyed by
/// host id; unregistering only clears the entry if it is still the one that
/// registered, so a second session pushed over the first and then popped
/// cannot evict the live one.
class SessionRegistry {
  SessionRegistry();

  static final SessionRegistry instance = SessionRegistry();

  final Map<String, LiveSession> _byHost = {};

  int get length => _byHost.length;

  void register(String hostId, LiveSession entry) {
    _byHost[hostId] = entry;
  }

  void unregister(String hostId, SessionController session) {
    final entry = _byHost[hostId];
    if (entry != null && identical(entry.session, session)) {
      _byHost.remove(hostId);
    }
  }

  /// The live session for [hostId], or null. A session whose transport has
  /// since dropped does not count — reusing it would only put the user in
  /// front of a dead connection.
  LiveSession? forHost(String hostId) {
    final entry = _byHost[hostId];
    if (entry == null) return null;
    if (entry.session.isClosed) {
      _byHost.remove(hostId);
      return null;
    }
    return entry;
  }
}
