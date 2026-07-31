import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
// `core.dart`, not `xterm.dart`: the terminal *buffer* is pure Dart and the
// widget that draws it is not, and only the buffer belongs down here. See
// [SessionController.terminal].
import 'package:xterm/core.dart';

import '../models/host.dart';
import '../models/remote_entry.dart';
import 'device_storage.dart';
import 'direct_remote_copy.dart';
import 'download_announcer.dart';
import 'download_plan.dart';
import 'remote_copy.dart';
import 'remote_path.dart';
import 'session_keepalive.dart';
import 'session_reconnect.dart';
import 'sftp_service.dart';
import 'ssh_service.dart';
import 'transfer_queue.dart';

export 'direct_remote_copy.dart'
    show
        DirectCopyUnavailableReason,
        DirectCopyWarning,
        SSHDirectCopyUnavailable;
export 'session_reconnect.dart'
    show ReconnectSupport, ReconnectConnector, ReconnectDelayScheduler;

/// Files waiting for a destination directory on this session.
class PendingUpload {
  const PendingUpload(this.files);

  final List<PickedLocalFile> files;

  int get count => files.length;

  int get totalBytes =>
      files.fold<int>(0, (sum, file) => sum + file.size);
}

/// Finds *another* open session, by its id.
///
/// Supplied by `SessionManager`, which is the only thing that knows what else
/// is open. Resolution happens when a transfer runs rather than when it is
/// queued, so a destination closed in between fails the transfer with an
/// explanation instead of writing into a dead channel — and so a retry, which
/// rebuilds the task from its fields, looks the destination up again.
///
/// It hands back the whole session rather than just its filesystem because the
/// destination has to be *told* when something lands on it: its file browser
/// is a different pane on a different session, with no sight of the queue the
/// transfer is running in.
///
/// Throws [SftpFailure] when there is no such live session.
typedef RemoteTargetResolver = Future<SessionController> Function(
  String sessionId,
);

/// Loads the [SshCredentials] saved for [hostId], or null when nothing is
/// saved (or the store cannot be read).
///
/// Injected as a callback so `SessionController` — and every service below
/// it — stays free of the credential store's dependency chain. The direct
/// copy path calls it once per transfer to pull *just the destination's*
/// key, hand it to a [CredentialSSHAgent] scoped to that transfer, and let
/// it fall out of scope when the exec ends. The same lookup, asked for this
/// session's own host id, is what logs the transfer's second connection in —
/// see [SessionController.openAgentForwardedConnection].
typedef DestinationCredentialResolver = Future<SshCredentials?> Function(
  String hostId,
);

/// Dials a second connection to [host] — one whose channels may carry SSH
/// agent forwarding — using [credentials].
///
/// A callback for the same reason [DestinationCredentialResolver] is: the
/// session stays clear of the SSH service's dependency chain, and the only
/// thing this hands a session is the ability to *open* a connection.
/// `SshService.connect(..., agentForwarding: true)` fits it.
typedef AgentForwardingConnector = Future<SessionTransport> Function(
  Host host,
  SshCredentials credentials,
);

/// What to send to the shell for a host's configured startup command, or
/// null when there is nothing to run. A free function (rather than inline in
/// [SessionController]) so this decision is unit-testable without a real
/// shell channel, which `FakeTransport.startShell` in the test suite cannot
/// open.
String? startupCommandPayload(String? command) {
  final trimmed = command?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  return '$trimmed\n';
}

/// One live authenticated session, shared by every view of it.
///
/// Phase 1 let `TerminalScreen` own the [SshConnection] and close it in
/// `dispose()`. That was fine while the terminal was the only thing on the
/// connection, and wrong the moment a file browser wanted the *same*
/// authenticated transport — `SSHClient.sftp()` opens another channel on it,
/// which is what spares the user a second password and a second host-key
/// prompt. So ownership lifts here: the session outlives any individual view,
/// and dies only when the user leaves the session or the transport does.
///
/// Deliberately free of Flutter imports, like the rest of `services/`:
/// listeners get a plain broadcast [Stream] rather than `ChangeNotifier`, so
/// the state machine is testable without a widget tree.
class SessionController {
  SessionController({
    required SessionTransport connection,
    DeviceStorage? storage,
    Future<RemoteFileSystem> Function()? openFileSystem,
    RemoteTargetResolver? resolveRemoteTarget,
    DestinationCredentialResolver? resolveDestinationCredentials,
    AgentForwardingConnector? connectWithAgentForwarding,
    PeriodicScheduler keepaliveScheduler = Timer.periodic,
    ReconnectSupport? reconnect,
    ReconnectDelayScheduler reconnectScheduler = Timer.new,
  })  : _connection = connection,
        _storage = storage ?? createDefaultDeviceStorage(),
        // ignore: prefer_initializing_formals
        _openFileSystem = openFileSystem,
        // ignore: prefer_initializing_formals
        _resolveRemoteTarget = resolveRemoteTarget,
        // ignore: prefer_initializing_formals
        _resolveDestinationCredentials = resolveDestinationCredentials,
        // ignore: prefer_initializing_formals
        _connectWithAgentForwarding = connectWithAgentForwarding,
        // ignore: prefer_initializing_formals
        _keepaliveScheduler = keepaliveScheduler {
    transfers = TransferQueue(executor: _runTransfer);
    _startKeepalive();
    if (reconnect != null) {
      final reconnector = SessionReconnector(
        host: connection.host,
        support: reconnect,
        adopt: adoptTransport,
        scheduler: reconnectScheduler,
      );
      _reconnector = reconnector;
      // Folded into this session's own change stream, so the banner in the
      // terminal area needs one subscription rather than two — and so a view
      // that predates any of this keeps working unchanged.
      _reconnectChanges = reconnector.changes.listen((_) => _notify());
    }
    _watchTransport();
  }

  /// The live transport.
  ///
  /// Mutable behind a getter because a session now *outlives* its transport:
  /// when the network drops and the automatic reconnect succeeds, the tab, the
  /// scrollback, the transfer queue and the id all stay exactly as they were
  /// and only this is replaced. See [adoptTransport].
  SessionTransport get connection => _connection;
  SessionTransport _connection;

  final DeviceStorage _storage;

  /// Test seam. Production leaves this null and opens SFTP on [connection].
  final Future<RemoteFileSystem> Function()? _openFileSystem;

  /// How this session reaches the other open sessions, for server-to-server
  /// transfers. Null when nothing else is open — or in the tests that do not
  /// exercise them — and a copy queued without one fails rather than hangs.
  final RemoteTargetResolver? _resolveRemoteTarget;

  /// How this session pulls the destination host's [SshCredentials] for a
  /// direct transfer. Null when the app has no credential store wired in
  /// (unit tests), and a direct transfer requested without one falls back
  /// to the relay path.
  final DestinationCredentialResolver? _resolveDestinationCredentials;

  /// How this session dials the extra connection a direct transfer runs its
  /// exec on. Null in the same circumstances as
  /// [_resolveDestinationCredentials], and with the same consequence — the
  /// transfer falls back to the relay path rather than failing.
  final AgentForwardingConnector? _connectWithAgentForwarding;

  /// Whether this session can copy files straight to another server.
  bool get canTransferToOtherSessions => _resolveRemoteTarget != null;

  /// The download/upload queue. Its executor is wired to this session, so a
  /// transfer cannot outlive the connection that is carrying it.
  late final TransferQueue transfers;

  /// What has already been said about finished downloads.
  ///
  /// Here rather than in the screen that shows the announcement for the same
  /// reason [pendingUpload] is: it is state about the session's transfers,
  /// and a view is too short-lived a thing to be trusted with it.
  final DownloadAnnouncer _announcer = DownloadAnnouncer();

  /// Keeps the socket from idling out while the app is in the background —
  /// the other half of Phase 7, alongside the foreground service that keeps
  /// the *process* alive. Runs for exactly as long as the transport does.
  ///
  /// Not `final`: [SessionKeepalive.stop] is deliberately permanent, so a
  /// session that reconnects gets a *new* one bound to the new transport
  /// rather than trying to restart a schedule that has already been retired.
  late SessionKeepalive _keepalive;

  /// Kept so the replacement keep-alive built by [adoptTransport] uses the
  /// same (possibly faked) clock the first one did.
  final PeriodicScheduler _keepaliveScheduler;

  /// Rebuilds the transport when it dies unexpectedly, or null when this
  /// session was built without the means to — no credential store and no SSH
  /// service, which is every unit test that does not exercise reconnection.
  SessionReconnector? _reconnector;
  StreamSubscription<void>? _reconnectChanges;

  /// Which transport the watchers below belong to.
  ///
  /// A dead transport's `done` future can complete *after* its replacement has
  /// been adopted — the old socket erroring out while the new one is already
  /// carrying a shell. Without this, that late completion would mark the
  /// freshly reconnected session as closed and start a second reconnect of a
  /// session that is perfectly healthy.
  var _transportGeneration = 0;

  final _changes = StreamController<void>.broadcast();

  /// Directories on *this* server that a transfer running on some *other*
  /// session has just written into.
  ///
  /// Its own stream rather than a flag on [changes] because it carries a
  /// payload (which directory) and because nothing else should have to
  /// re-list on an unrelated notification. The file browser listens and
  /// refreshes when the directory it is showing is named, so a file copied in
  /// from another server appears where it landed instead of leaving the user
  /// looking at a listing that does not contain it.
  final _arrivals = StreamController<String>.broadcast();

  SSHSession? _shell;
  Future<SSHSession>? _shellOpening;
  Future<RemoteFileSystem>? _sftpOpening;
  RemoteFileSystem? _sftp;

  /// The scrollback, cursor and escape-sequence state of this session's shell.
  ///
  /// Here rather than inside the widget that draws it, and that is not a
  /// stylistic choice — it is what Phase 12 cost. Once a session outlives the
  /// screen showing it (leaving for the host list is how a *second* session
  /// gets opened), a `Terminal` owned by a `State` is thrown away every time
  /// the user leaves, taking the scrollback with it and leaving the next view
  /// to re-subscribe to an `SSHSession.stdout` that has already been listened
  /// to — which throws. Found on the emulator by switching tabs after opening
  /// a second session, exactly as described.
  ///
  /// `xterm`'s `Terminal` is pure Dart (`package:xterm/core.dart`), so this
  /// keeps `services/` free of Flutter: the view supplies the font, the theme
  /// and the gestures, and this supplies the bytes.
  late final Terminal terminal = Terminal(
    maxLines: 10000,
    platform: TerminalTargetPlatform.linux,
    onOutput: _sendToShell,
    onResize: _handleTerminalResize,
    onBell: () => onBell?.call(),
  );

  /// Set by the view, since a bell is haptics and a haptic is not a service.
  void Function()? onBell;

  /// Lets the view rewrite a keystroke on the way to the shell.
  ///
  /// Exists for one thing: the extra-key bar's sticky Ctrl. Whether "Ctrl" is
  /// currently armed is a property of a keyboard drawn on a screen, so the
  /// decision stays up there — but every route to the shell (soft keyboard,
  /// hardware keyboard, the bar's own buttons) funnels through [terminal]'s
  /// output callback, so the hook has to be here.
  String Function(String data)? transformInput;

  /// Watches everything this session sends to its shell *as user input*.
  ///
  /// The tap the broadcast-input feature listens on. It sits at the far end of
  /// the funnel described on [transformInput] — soft keyboard, hardware
  /// keyboard, the extra-key bar and paste all arrive here, already rewritten
  /// by [transformInput], as the exact bytes that went down the channel. So a
  /// mirrored keystroke is the same bytes the focused pane sent, sticky-Ctrl
  /// and bracketed paste included, rather than a second guess at what the user
  /// meant.
  ///
  /// A notification, not a filter: it cannot change or suppress what was typed
  /// here, because a broadcast that could swallow the user's own keystroke on
  /// the way past would be a far worse bug than any it prevents.
  ///
  /// Not everything `Terminal` emits is input — see [_absorbingRemoteOutput].
  void Function(String data)? onInputSent;

  /// True while remote output is being fed into [terminal].
  ///
  /// `Terminal.onOutput` carries two quite different things: what the user
  /// typed, and the terminal's own *replies* to escape sequences the remote
  /// program sent — device attributes, operating status, cursor position,
  /// size reports. A reply is indistinguishable from a keystroke by the time it
  /// reaches [_sendToShell], and broadcasting one would spray `\x1b[?1;2c`
  /// across three other people's shells the moment anybody started `vim`.
  ///
  /// They are, however, perfectly distinguishable by *when* they happen: a
  /// reply is emitted synchronously from inside `Terminal.write`, while the
  /// parser is running over the remote bytes that asked for it. So every write
  /// is bracketed and the tap stays quiet for its duration — see
  /// [_writeToTerminal].
  var _absorbingRemoteOutput = false;

  /// Completes when a view has laid out and reported the real column/row
  /// count, so the PTY is opened at the right size instead of 80×24 followed
  /// by an immediate resize — the remote shell draws its first prompt at
  /// whatever width it was given.
  final Completer<void> _initialSize = Completer<void>();

  Future<void>? _shellReady;
  final List<StreamSubscription<void>> _shellOutput = [];

  /// True once the shell channel is open and wired to [terminal].
  bool get isShellReady => _shellStarted;
  var _shellStarted = false;

  /// Why the shell could not be opened, or null. The session itself may be
  /// perfectly alive — the file browser still works.
  String? get shellError => _shellError;
  String? _shellError;

  var _closed = false;
  var _disposed = false;
  var _announcedDisconnect = false;
  String? _closeReason;

  /// Whether the shell channel ended in an orderly way while the transport was
  /// still up — which is what `exit` looks like from here. See [_markClosed].
  var _shellExitedCleanly = false;

  Host get host => connection.host;

  /// Fires whenever the session's own state changes (connected → closed).
  /// Transfer progress has its own stream on [transfers].
  Stream<void> get changes => _changes.stream;

  /// Emits a directory on this server each time another session finishes
  /// writing a file into it. See [_arrivals].
  Stream<String> get arrivals => _arrivals.stream;

  /// Announces that something landed in [directory] on this server. Called by
  /// the *source* session's transfer, which is the only thing that knows.
  void reportArrival(String directory) {
    if (_disposed || _arrivals.isClosed) return;
    _arrivals.add(directory);
  }

  /// True once the transport is gone, for any reason.
  bool get isClosed => _closed;

  /// Why the session ended, for the disconnected banner.
  String? get closeReason => _closeReason;

  /// The drop worth telling the user about, exactly once, or null.
  ///
  /// Here rather than on the screen for the same reason [_announcer] is: with
  /// several sessions open, a drop on the one in the background still has to
  /// be announced when the user comes back to it, and it must be announced
  /// once — not on every rebuild while the banner is already up, and not
  /// again by whatever `State` replaces the one that said it.
  String? takeDisconnectAnnouncement() {
    if (!_closed || _announcedDisconnect) return null;
    // Held back while an automatic reconnect is in flight. A red "connection
    // lost" toast on top of a banner already saying "reconnecting…" is two
    // different accounts of the same event, and the announcement is not
    // consumed here — so if the reconnect does give up, it is still waiting
    // to be said, and gets said then.
    if (isReconnecting) return null;
    _announcedDisconnect = true;
    return _closeReason ?? 'Connection closed.';
  }

  /// True once the shell channel has been opened.
  bool get hasShell => _shell != null;

  /// Whether keep-alives are still being sent. Diagnostics and tests.
  bool get isKeepaliveRunning => _keepalive.isRunning;

  // ------------------------------------------------------------- reconnect

  /// True while this session is trying to rebuild its own transport.
  ///
  /// The session is also [isClosed] throughout — it genuinely has no shell
  /// — so views that knew nothing about reconnection keep behaving correctly
  /// (the terminal is read-only, the key bar is gone) while a view that does
  /// know can show why.
  bool get isReconnecting => _reconnector?.isActive ?? false;

  /// What the terminal area should say about the reconnection, or null when
  /// there is nothing to say.
  String? get reconnectMessage => _reconnector?.message;

  /// True once reconnection has been tried and abandoned. Distinguishes "this
  /// session is gone and we did what we could" from "this session is gone".
  bool get reconnectGaveUp => _reconnector?.hasGivenUp ?? false;

  /// How many reconnection attempts have been made. Diagnostics and tests.
  int get reconnectAttempts => _reconnector?.attempts ?? 0;

  /// Stops trying, for good. The Stop button on the reconnecting banner.
  void stopReconnecting() {
    _reconnector?.cancel();
    _notify();
  }

  /// Takes over [next] as this session's transport, in place of the one that
  /// died.
  ///
  /// This is what makes a reconnect land in the same tab and the same pane
  /// rather than in a new session beside the corpse of the old one: the id,
  /// the [terminal] with its scrollback, the transfer queue, the pane binding
  /// and every view already built over them are untouched, and only the things
  /// that were tied to the dead socket — shell channel, SFTP channel,
  /// keep-alive — are rebuilt.
  ///
  /// **Scrollback is kept.** The `Terminal` belongs to the session, not to the
  /// transport, so keeping it is the option that requires doing nothing at
  /// all; clearing it would mean reaching in and emptying a buffer that
  /// nothing else has any reason to touch. It is also the more useful of the
  /// two — the command whose output the user was reading when the train went
  /// into a tunnel is still there. A dim rule is written across the buffer so
  /// that the join is visible and nobody mistakes the old output for output of
  /// the new shell.
  Future<void> adoptTransport(SessionTransport next) async {
    if (_disposed) {
      // Nothing left to adopt into; leaving it open would strand a socket.
      next.close();
      return;
    }

    // The old transport is dead, but "dead" is a conclusion drawn from a
    // future completing — the socket underneath may still be half-open.
    _connection.close();

    for (final subscription in _shellOutput) {
      unawaited(subscription.cancel());
    }
    _shellOutput.clear();

    _connection = next;
    _transportGeneration++;

    _shell = null;
    _shellOpening = null;
    _shellReady = null;
    _shellStarted = false;
    _shellError = null;
    _shellExitedCleanly = false;
    // The old channels died with the old transport. Dropping the handles is
    // what makes the file browser's next call open a fresh one rather than
    // write into a closed channel.
    _sftp = null;
    _sftpOpening = null;

    _closed = false;
    _closeReason = null;
    _announcedDisconnect = false;

    _startKeepalive();
    _watchTransport();
    _notify();

    _writeToTerminal(
      '\r\n\x1b[2m── reconnected to ${host.displayName} ──\x1b[0m\r\n',
    );
    await ensureShell();
  }

  void _startKeepalive() {
    _keepalive = SessionKeepalive(
      // Through the field rather than the value it holds today: a reconnect
      // replaces the transport, and a keep-alive still pinging the old one
      // would be pinging a socket nobody is listening on.
      ping: () => _connection.ping(),
      scheduler: _keepaliveScheduler,
    )..start();
  }

  /// Watches the current transport for its death, and classifies it.
  ///
  /// The two branches are not cosmetic — they are what decides whether an
  /// automatic reconnect is appropriate. `done` completing *normally* means
  /// the far end said goodbye in an orderly way: the user typed `exit`, or an
  /// administrator's idle policy closed the session, or the server is going
  /// down. None of those want to be undone by a client that immediately dials
  /// back. `done` completing with an *error* is the transport breaking
  /// underneath a session nobody asked to end — a Wi-Fi handover, a closed
  /// lid, a NAT mapping expiring — which is precisely the case reconnection
  /// exists for.
  void _watchTransport() {
    final generation = _transportGeneration;
    final transport = _connection;
    transport.done.then((_) {
      _markClosed('Connection closed by the remote host.', generation);
    }).catchError((Object error) {
      _markClosed('Connection lost: $error', generation, retryable: true);
    });
  }

  void _markClosed(
    String reason,
    int generation, {
    bool retryable = false,
  }) {
    // A transport that has already been replaced is entitled to finish dying;
    // it just no longer speaks for this session. See [_transportGeneration].
    if (generation != _transportGeneration) return;
    if (_closed) return;
    _closed = true;
    _closeReason = reason;
    // Nothing left to keep alive. Stopping here rather than only in dispose()
    // matters for the background case: a drop that happens while the app is
    // in the background must not leave a timer pinging a dead socket until
    // the user comes back and pops the route.
    _keepalive.stop();
    // Anything still queued is now unrunnable; failing it loudly beats a
    // progress bar that never moves again.
    transfers.cancelAll();

    // A shell that exited cleanly before the transport went is the user
    // leaving — `exit`, `logout`, Ctrl-D — and dialling their server back
    // after they have just said goodbye to it is the one behaviour this
    // feature must never have. It is checked here, on top of the orderly/error
    // split in [_watchTransport], because a server that drops the TCP
    // connection rudely straight after a clean `exit` would otherwise look
    // exactly like a network fault.
    if (retryable && !_disposed && !_shellExitedCleanly) {
      _reconnector?.begin();
    }
    _notify();
  }

  /// Called by the terminal view when the shell channel itself ends, which can
  /// happen (a plain `exit`) while the transport is still perfectly alive.
  void reportShellEnded(String reason) {
    if (_closed) return;
    _closeReason ??= reason;
    _notify();
  }

  void _notify() {
    if (_disposed || _changes.isClosed) return;
    _changes.add(null);
  }

  /// Opens the interactive shell, once. Repeat calls get the same session, so
  /// switching to the file browser and back never restarts the user's shell.
  ///
  /// The size is only honoured on the first call — the PTY is created there,
  /// and every later change flows through [SSHSession.resizeTerminal].
  Future<SSHSession> shell({required int columns, required int rows}) {
    final existing = _shell;
    if (existing != null) return Future<SSHSession>.value(existing);
    return _shellOpening ??= connection
        .startShell(columns: columns, rows: rows)
        .then((session) {
      _shell = session;
      _notify();
      return session;
    }).catchError((Object error) {
      _shellOpening = null;
      throw error;
    });
  }

  /// Opens the shell and wires it to [terminal] — once per session, however
  /// many views come and go.
  ///
  /// Waits for a view to report the real terminal size first, with a 1.5 s
  /// fallback to xterm's 80×24 default if one somehow never does: a slightly
  /// wrong PTY beats a shell that never opens.
  Future<void> ensureShell() => _shellReady ??= _openShell();

  Future<void> _openShell() async {
    await _initialSize.future.timeout(
      const Duration(milliseconds: 1500),
      onTimeout: () {},
    );

    try {
      final session = await shell(
        columns: terminal.viewWidth,
        rows: terminal.viewHeight,
      );

      // Decoding through the chunked converter (rather than utf8.decode per
      // chunk) keeps multi-byte characters intact when they straddle a packet
      // boundary — otherwise box-drawing and emoji output corrupts.
      const decoder = Utf8Decoder(allowMalformed: true);
      _shellOutput.add(
        session.stdout
            .cast<List<int>>()
            .transform(decoder)
            .listen(_writeToTerminal, onError: (Object _) {}),
      );
      _shellOutput.add(
        session.stderr
            .cast<List<int>>()
            .transform(decoder)
            .listen(_writeToTerminal, onError: (Object _) {}),
      );

      unawaited(
        session.done.then((_) {
          // Completing without an error means the channel was closed properly
          // at the far end, which is what a shell that has *exited* does. The
          // exit status may or may not have come with it (servers differ), so
          // the status is used for the message and the orderliness for the
          // decision — see [_markClosed].
          _shellExitedCleanly = true;
          final code = session.exitCode;
          _handleShellEnded(
            code == null
                ? 'Shell session ended.'
                : 'Shell exited with status $code.',
          );
        }).catchError((Object error) {
          _handleShellEnded('Shell session ended: $error');
        }),
      );

      _shellStarted = true;
      _sendStartupCommand();
    } catch (e) {
      _shellError = e.toString();
      _shellStarted = true;
      _writeToTerminal('\r\n\x1b[31mFailed to open a shell: $e\x1b[0m\r\n');
    }
    _notify();
  }

  /// Puts bytes on the screen, with the input tap held shut for the duration.
  ///
  /// Every write into [terminal] that did not come from the user goes through
  /// here. `Terminal.write` runs the escape-sequence parser synchronously, and
  /// a parser that meets a query — `CSI c`, `CSI 6n` — answers it by
  /// calling straight back out through `onOutput`, the callback keystrokes
  /// use too.
  /// Bracketing the write is what lets [_sendToShell] tell the two apart. See
  /// [_absorbingRemoteOutput].
  void _writeToTerminal(String data) {
    _absorbingRemoteOutput = true;
    try {
      terminal.write(data);
    } finally {
      _absorbingRemoteOutput = false;
    }
  }

  /// Drops the local handle on a shell channel that has ended, so every later
  /// write and resize is a plain no-op instead of something that throws and
  /// relies on being caught.
  void _handleShellEnded(String reason) {
    _shell = null;
    reportShellEnded(reason);
  }

  /// Runs [Host.startupCommand] once, as if the user had typed it and
  /// pressed Enter. Best-effort: a shell that closes before this reaches it
  /// is not worth surfacing, same as any other keystroke sent to a dead
  /// channel.
  void _sendStartupCommand() {
    final payload = startupCommandPayload(host.startupCommand);
    final shell = _shell;
    if (payload == null || shell == null) return;
    try {
      shell.write(Uint8List.fromList(utf8.encode(payload)));
    } catch (_) {
      // Channel closed before this could run.
    }
  }

  void _sendToShell(String data) {
    final shell = _shell;
    if (shell == null || _closed) return;
    final payload = transformInput?.call(data) ?? data;
    try {
      shell.write(Uint8List.fromList(utf8.encode(payload)));
    } catch (_) {
      // Keystroke arrived after the channel closed; the disconnect banner is
      // already on its way.
    }
    // Announced after the local write, never instead of it: this session is
    // the one the user is typing in and it gets its keystroke whatever any
    // listener does with the news. Terminal replies to escape queries are not
    // news — see [_absorbingRemoteOutput].
    if (!_absorbingRemoteOutput) onInputSent?.call(payload);
  }

  void _handleTerminalResize(int width, int height, int pixelWidth,
      int pixelHeight) {
    if (!_initialSize.isCompleted) _initialSize.complete();
    if (_closed) return;
    try {
      // Propagate SIGWINCH so full-screen programs (vim, htop, less) reflow.
      _shell?.resizeTerminal(width, height, pixelWidth, pixelHeight);
    } catch (_) {
      // The channel can close between the layout pass and this call; a resize
      // on a dead session is not worth surfacing.
    }
  }

  /// Opens the SFTP subsystem, once, on the connection that is already
  /// authenticated. No second login, no second host-key prompt.
  Future<RemoteFileSystem> sftp() {
    final existing = _sftp;
    if (existing != null) return Future<RemoteFileSystem>.value(existing);
    if (_closed) {
      return Future<RemoteFileSystem>.error(
        const SftpFailure('The session has ended. Reconnect to browse files.'),
      );
    }
    final open = _openFileSystem ??
        () => connection.openSftp().then<RemoteFileSystem>(SftpService.new);
    return _sftpOpening ??= open().then((service) {
      _sftp = service;
      return service;
    }).catchError((Object error) {
      _sftpOpening = null;
      throw error is SftpFailure
          ? error
          : SftpFailure(
              'The server refused an SFTP session. It may have the sftp '
              'subsystem disabled.',
              details: error.toString(),
            );
    });
  }

  /// Dials a second, short-lived connection to *this session's own* server,
  /// to carry the one agent-forwarded exec a direct A→B copy runs on.
  ///
  /// **Why not this session's connection.** dartssh2 puts an
  /// `auth-agent-req@openssh.com` on every session channel opened by a client
  /// that was built with an agent handler, and throws when the server says
  /// no; OpenSSH says yes exactly once per connection. A session whose client
  /// carried a handler would therefore run one exec and then fail every stats
  /// poll, log tail, service action and key push for the rest of its life —
  /// so the handler cannot live here, and [SSHClient.agentHandler] is `final`,
  /// so it cannot be attached for the transfer and detached afterwards
  /// either. One extra login per transfer buys all of those back, and it
  /// narrows what the source server can ask this device to sign to exactly
  /// the connection doing the transfer: nothing on the session the user is
  /// typing in will answer an agent request at all.
  ///
  /// Null when this session has no way to dial one — no connector wired in,
  /// or nothing saved for this host — so the caller can fall back to the
  /// relay path instead of failing the transfer.
  ///
  /// The caller owns what comes back and must close it.
  Future<SessionTransport?> openAgentForwardedConnection() async {
    final dial = _connectWithAgentForwarding;
    final resolve = _resolveDestinationCredentials;
    if (dial == null || resolve == null) return null;
    final credentials = await resolve(host.id);
    if (credentials == null) return null;
    return dial(host, credentials);
  }

  // -------------------------------------------------------------- transfers

  /// Whether Downloads is writable, prompting for the legacy permission on
  /// API < 29 where scoped storage does not apply.
  Future<bool> ensureDownloadPermission() => _storage.ensurePermission();

  /// Whether a download of [fileName] would collide with an existing file.
  Future<bool> downloadWouldCollide(String fileName) =>
      _storage.downloadExists(RemotePath.sanitiseFileName(fileName));

  /// Queues [entry] for download. [overwrite] replaces a colliding file;
  /// otherwise the platform de-duplicates to `name (1).ext`.
  TransferTask queueDownload(RemoteEntry entry, {bool overwrite = false}) {
    return transfers.enqueueDownload(
      remotePath: entry.path,
      name: entry.name,
      saveAsName: RemotePath.sanitiseFileName(entry.name),
      overwrite: overwrite,
      totalBytes: entry.size,
    );
  }

  /// Queues one file of a recursive directory download, which unlike a
  /// single-file download carries the subdirectory it belongs in.
  TransferTask queuePlannedDownload(PlannedDownload planned) {
    return transfers.enqueueDownload(
      remotePath: planned.remotePath,
      name: planned.fileName,
      saveAsName: planned.fileName,
      totalBytes: planned.size,
      relativeDirectory: planned.relativeDirectory,
    );
  }

  /// Queues an upload of a locally staged file into [remoteDirectory],
  /// optionally under a different name — which is how "keep both" lands a
  /// second `notes.md` as `notes (1).md` instead of over the first.
  TransferTask queueUpload(
    PickedLocalFile file,
    String remoteDirectory, {
    String? asName,
  }) {
    final name = asName ?? file.name;
    return transfers.enqueueUpload(
      localPath: file.path,
      remotePath: RemotePath.join(remoteDirectory, name),
      name: name,
      totalBytes: file.size,
    );
  }

  /// Queues a recursive upload of the local directory [pickedPath] into
  /// [remoteDirectory] on this session, published as [asName] over there.
  ///
  /// One task per top-level folder — the executor walks the local tree and
  /// streams every file under it under one row on the transfer panel, rather
  /// than exploding a `Documents/` upload into 300 queue entries.
  TransferTask queueUploadDirectory({
    required String pickedPath,
    required String pickedName,
    required String remoteDirectory,
    String? asName,
    bool overwrite = false,
    int? totalBytes,
  }) {
    final landingName = asName ?? pickedName;
    return transfers.enqueueUploadDirectory(
      localPath: pickedPath,
      remotePath: RemotePath.join(remoteDirectory, landingName),
      name: landingName,
      overwrite: overwrite,
      totalBytes: totalBytes,
    );
  }

  /// Queues a copy of [remotePath] straight into another open session, named
  /// [asName] in [remoteDirectory] over there.
  ///
  /// [moveSource] makes it a move: the file here is deleted, but only once the
  /// write over there has been verified — see [copyRemoteFile].
  ///
  /// [route] picks between the relay path (bytes through this app; always
  /// available) and the direct path (bytes source→destination on the
  /// network between them). Direct silently falls back to relay when the
  /// direct path is unavailable — see [_runRemoteCopy].
  TransferTask queueRemoteCopy({
    required String remotePath,
    required String name,
    required String destinationSessionId,
    required String destinationLabel,
    required String remoteDirectory,
    String? asName,
    bool overwrite = false,
    bool moveSource = false,
    int? totalBytes,
    TransferRoute route = TransferRoute.relay,
  }) {
    final landingName = asName ?? name;
    return transfers.enqueueRemoteCopy(
      remotePath: remotePath,
      name: landingName,
      destinationSessionId: destinationSessionId,
      destinationLabel: destinationLabel,
      destinationPath: RemotePath.join(remoteDirectory, landingName),
      overwrite: overwrite,
      moveSource: moveSource,
      totalBytes: totalBytes,
      route: route,
    );
  }

  /// Queues a recursive copy of the directory at [remotePath] straight into
  /// another open session, landing as [asName] under [remoteDirectory] over
  /// there.
  ///
  /// One task per top-level folder — the executor picks between
  /// [copyRemoteDirectory] (relay) and [copyRemoteDirectoryDirect] (direct)
  /// the same way a file S2S copy does, and the panel shows folder progress
  /// in aggregate.
  TransferTask queueRemoteCopyDirectory({
    required String remotePath,
    required String name,
    required String destinationSessionId,
    required String destinationLabel,
    required String remoteDirectory,
    String? asName,
    bool overwrite = false,
    bool moveSource = false,
    int? totalBytes,
    TransferRoute route = TransferRoute.relay,
  }) {
    final landingName = asName ?? name;
    return transfers.enqueueRemoteCopy(
      remotePath: remotePath,
      name: landingName,
      destinationSessionId: destinationSessionId,
      destinationLabel: destinationLabel,
      destinationPath: RemotePath.join(remoteDirectory, landingName),
      overwrite: overwrite,
      moveSource: moveSource,
      totalBytes: totalBytes,
      route: route,
      isDirectoryTransfer: true,
    );
  }

  /// The finished downloads that have not been announced to the user yet,
  /// given the queue's latest [tasks]. Empty when there is nothing new to
  /// say, or when the queue is still busy and the batch is not complete.
  ///
  /// Consuming: each task comes back from here exactly once, however many
  /// views ask and however often the queue republishes the same list.
  List<TransferTask> takeDownloadAnnouncement(List<TransferTask> tasks) =>
      _announcer.take(tasks, queueBusy: transfers.hasActive);

  // ------------------------------------------------------- shared-in uploads

  /// Files handed to this session from outside the browser — the share sheet,
  /// so far — waiting for the user to pick a destination directory.
  ///
  /// Held as state rather than published as an event because the file browser
  /// may not exist yet when the request arrives (a share can land on a
  /// session showing the terminal, or on one that is still connecting); a
  /// pane that builds later has to be able to find the request, not miss it.
  PendingUpload? get pendingUpload => _pendingUpload;
  PendingUpload? _pendingUpload;

  void requestUpload(List<PickedLocalFile> files) {
    if (files.isEmpty) return;
    _pendingUpload = PendingUpload(files);
    _notify();
  }

  void clearPendingUpload() {
    if (_pendingUpload == null) return;
    _pendingUpload = null;
    _notify();
  }

  Future<void> _runTransfer(TransferTask task, TransferHandle handle) async {
    if (_closed) {
      throw const SftpFailure('The session has ended. Reconnect to transfer.');
    }
    final sftp = await this.sftp();
    handle.throwIfCancelled();

    switch (task.direction) {
      case TransferDirection.download:
        await _runDownload(sftp, task, handle);
      case TransferDirection.upload:
        if (task.isDirectoryTransfer) {
          await _runUploadDirectory(sftp, task, handle);
        } else {
          await _runUpload(sftp, task, handle);
        }
      case TransferDirection.serverToServer:
        await _runRemoteCopy(sftp, task, handle);
    }
  }

  Future<void> _runDownload(
    RemoteFileSystem sftp,
    TransferTask task,
    TransferHandle handle,
  ) async {
    if (task.totalBytes == null) {
      handle.setTotal(await sftp.sizeOf(task.remotePath));
    }
    handle.throwIfCancelled();

    final fileName = task.saveAsName ?? RemotePath.sanitiseFileName(task.name);
    final directory = task.relativeDirectory;
    final writer = await _storage.beginDownload(
      fileName,
      mimeType: SftpService.mimeTypeFor(fileName),
      overwrite: task.overwrite,
      relativeDirectory: directory,
    );

    var completed = false;
    try {
      await sftp.download(
        task.remotePath,
        write: writer.add,
        onProgress: handle.report,
        isCancelled: () => handle.isCancelled,
      );
      handle.throwIfCancelled();
      final saved = await writer.finish();
      completed = true;
      handle.setDestination(
        directory.isEmpty
            ? 'Downloads/${saved.displayName}'
            : 'Downloads/$directory/${saved.displayName}',
        uri: saved.uri,
      );
    } finally {
      if (!completed) {
        await writer.abort();
      }
    }
  }

  Future<void> _runUpload(
    RemoteFileSystem sftp,
    TransferTask task,
    TransferHandle handle,
  ) async {
    await sftp.upload(
      task.localPath!,
      task.remotePath,
      onProgress: handle.report,
      isCancelled: () => handle.isCancelled,
    );
    handle.throwIfCancelled();
    handle.setDestination(task.remotePath);
  }

  /// Recursive upload of one local directory into [task.remotePath] on the
  /// server this session is connected to.
  ///
  /// The walk happens *inside* the task rather than before it so the total
  /// size can be reported once (via [TransferHandle.setTotal]) and a cancel
  /// in the middle of a long walk still stops the transfer, rather than
  /// leaving a half-walked plan queued behind a "cannot cancel" row.
  ///
  /// Empty subdirectories on the source are mkdir'd on the destination so
  /// the shape of the tree is preserved — a `logs/` folder with nothing in
  /// it still lands.
  Future<void> _runUploadDirectory(
    RemoteFileSystem sftp,
    TransferTask task,
    TransferHandle handle,
  ) async {
    final localRoot = task.localPath!;
    final remoteRoot = task.remotePath;
    final tree = await readLocalDirectoryTree(localRoot);
    handle.setTotal(tree.totalBytes);
    handle.throwIfCancelled();

    if (task.overwrite) {
      // A top-level `Replace` at the collision prompt licenses the wipe. The
      // destination directory is torn down and rebuilt fresh, so nothing
      // inside can collide with anything already there.
      await removeRemoteDirectoryTree(sftp, remoteRoot);
      handle.throwIfCancelled();
    }
    try {
      await sftp.mkdir(remoteRoot);
    } on SftpFailure {
      // Already exists (nothing to overwrite) — proceed and let the writes
      // fail loudly if it turns out we cannot use it.
    }

    // Every subdirectory first, breadth-first order preserved by the walk,
    // so empty folders survive and a per-file mkdir never races with an
    // uncreated parent.
    for (final relative in tree.directories) {
      handle.throwIfCancelled();
      final path = RemotePath.join(remoteRoot, relative);
      try {
        await sftp.mkdir(path);
      } on SftpFailure {
        // Already there is fine; a real failure surfaces on the file write.
      }
    }

    var bytesMoved = 0;
    for (final file in tree.files) {
      handle.throwIfCancelled();
      final remotePath = RemotePath.join(remoteRoot, file.relativePath);
      final moved = await sftp.upload(
        file.absolutePath,
        remotePath,
        onProgress: (bytes) => handle.report(bytesMoved + bytes),
        isCancelled: () => handle.isCancelled,
      );
      bytesMoved += moved;
      handle.report(bytesMoved);
      handle.throwIfCancelled();
    }
    handle.setDestination(remoteRoot);
  }

  /// Streams one file from this session's server straight to another open
  /// session's, and — for a move — deletes it here once that is verified.
  ///
  /// The destination is resolved *now* rather than when the transfer was
  /// queued: the user may have closed that session while this one sat in the
  /// queue behind three other files, and a retry rebuilds the task from its
  /// fields with no live object to hold on to.
  ///
  /// **Route selection.** [TransferTask.route] is the user's request. Relay
  /// runs the copy through this device (see [copyRemoteFile]) and always
  /// works between two sessions we already have live channels on. Direct
  /// opens an exec on the source and runs `sftp` there, forwarding the
  /// destination's key through the source's agent slot (see
  /// [copyRemoteFileDirect]); on any recoverable failure — the destination
  /// is unreachable from the source, the source has no `sftp`, agent
  /// forwarding was refused, no cached passphrase — we fall back to relay
  /// and record why. An unrecoverable failure — the destination's host key
  /// on the wire is not the one we trust — refuses without falling back,
  /// because a relay from *this* device would not reproduce the anomaly and
  /// so cannot be a valid answer to it.
  Future<void> _runRemoteCopy(
    RemoteFileSystem sftp,
    TransferTask task,
    TransferHandle handle,
  ) async {
    final destinationId = task.destinationSessionId;
    final destinationPath = task.destinationPath;
    final resolve = _resolveRemoteTarget;
    if (destinationId == null || destinationPath == null || resolve == null) {
      throw const SftpFailure(
        'That transfer has no destination server to go to.',
      );
    }

    final target = await resolve(destinationId);
    final destination = await target.sftp();
    handle.throwIfCancelled();

    if (task.totalBytes == null && !task.isDirectoryTransfer) {
      handle.setTotal(await sftp.sizeOf(task.remotePath));
      handle.throwIfCancelled();
    }

    RemoteCopyOutcome? outcome;
    String? fallbackReason;

    if (task.route == TransferRoute.direct) {
      final resolveCreds = _resolveDestinationCredentials;
      if (resolveCreds == null) {
        fallbackReason =
            'no destination-credential resolver on this session';
      } else {
        final destCreds = await resolveCreds(target.host.id);
        handle.throwIfCancelled();
        if (destCreds == null) {
          fallbackReason = 'no saved credentials for the destination host';
        } else {
          try {
            handle.setRouteUsed(TransferRoute.direct);
            outcome = task.isDirectoryTransfer
                ? await copyRemoteDirectoryDirect(
                    source: this,
                    destHost: target.host,
                    destCredentials: destCreds,
                    destinationFs: destination,
                    sourceDirectory: task.remotePath,
                    destinationDirectory: destinationPath,
                    overwrite: task.overwrite,
                    deleteSourceAfterVerify: task.moveSource,
                    onProgress: handle.report,
                    isCancelled: () => handle.isCancelled,
                  )
                : await copyRemoteFileDirect(
                    source: this,
                    destHost: target.host,
                    destCredentials: destCreds,
                    destinationFs: destination,
                    sourcePath: task.remotePath,
                    destinationPath: destinationPath,
                    overwrite: task.overwrite,
                    deleteSourceAfterVerify: task.moveSource,
                    onProgress: handle.report,
                    isCancelled: () => handle.isCancelled,
                  );
          } on SSHDirectCopyUnavailable catch (e) {
            if (e.reason == DirectCopyUnavailableReason.hostKeyMismatch) {
              // Refuse: a relay from this device cannot honestly answer a
              // MITM-shaped signal seen on A→B, so surface it instead of
              // silently paving over it.
              rethrow;
            }
            fallbackReason = e.message ?? e.reason.name;
          }
        }
      }
    }

    outcome ??= await () async {
      handle.setRouteUsed(
        TransferRoute.relay,
        fallbackReason: fallbackReason,
      );
      return task.isDirectoryTransfer
          ? copyRemoteDirectory(
              source: sftp,
              destination: destination,
              sourceDirectory: task.remotePath,
              destinationDirectory: destinationPath,
              overwrite: task.overwrite,
              deleteSourceAfterVerify: task.moveSource,
              onProgress: handle.report,
              isCancelled: () => handle.isCancelled,
            )
          : copyRemoteFile(
              source: sftp,
              destination: destination,
              sourcePath: task.remotePath,
              destinationPath: destinationPath,
              overwrite: task.overwrite,
              deleteSourceAfterVerify: task.moveSource,
              onProgress: handle.report,
              isCancelled: () => handle.isCancelled,
            );
    }();
    handle.throwIfCancelled();

    // The file — or the folder — is over there now, and the browser over
    // there has no way of knowing that from its own queue.
    target.reportArrival(
      task.isDirectoryTransfer
          ? outcome.destinationPath
          : RemotePath.parent(outcome.destinationPath),
    );

    final label = task.destinationLabel;
    handle.setDestination(
      label == null || label.isEmpty
          ? outcome.destinationPath
          : '$label:${outcome.destinationPath}',
    );
  }

  /// Opens the system picker and stages the chosen file locally.
  Future<PickedLocalFile?> pickLocalFile() => _storage.pickFile();

  /// Opens the system picker for any number of files, staging each one.
  Future<List<PickedLocalFile>> pickLocalFiles() => _storage.pickFiles();

  /// Opens the system folder picker. Null on cancel or when the platform has
  /// no folder picker wired up (Android SAF is a documented gap — see the
  /// handover report).
  Future<PickedLocalDirectory?> pickLocalDirectory() =>
      _storage.pickDirectory();

  /// Hands a finished download to whatever app can display it. False when
  /// nothing on the device can, or when the transfer has no URI to open —
  /// an upload, or a download that never finished.
  Future<bool> openDownload(TransferTask task) async {
    final uri = task.destinationUri;
    if (uri == null || uri.isEmpty) return false;
    return _storage.openDownload(
      uri,
      mimeType: SftpService.mimeTypeFor(task.saveAsName ?? task.name),
    );
  }

  // ----------------------------------------------------------------- teardown

  /// Ends the session: cancels transfers, closes the SFTP and shell channels,
  /// then the transport. Idempotent.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;

    // First, and before anything else can complete: closing the tab is the
    // user saying they are done with this server, and a reconnect that
    // outlived it would dial back — and, worse, hand a live transport to
    // [adoptTransport] on a session that no longer exists.
    await _reconnectChanges?.cancel();
    await _reconnector?.dispose();

    _keepalive.stop();
    transfers.cancelAll();
    await transfers.dispose();

    for (final subscription in _shellOutput) {
      unawaited(subscription.cancel());
    }
    _shellOutput.clear();

    final sftp = _sftp;
    _sftp = null;
    _sftpOpening = null;
    if (sftp != null) {
      try {
        await sftp.close();
      } catch (_) {
        // Already gone.
      }
    }

    try {
      _shell?.close();
    } catch (_) {
      // Already gone.
    }
    _shell = null;
    _shellOpening = null;

    connection.close();
    _closed = true;
    await _arrivals.close();
    await _changes.close();
  }
}
