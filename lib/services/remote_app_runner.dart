import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

import 'remote_desktop/virtual_desktop.dart' show appWindowCommandFor;
import 'remote_exec.dart';
import 'session_controller.dart';
import 'shell_quote.dart';
import 'ssh_certificate.dart';
import 'ssh_forwarding_client.dart' show refusedX11Request;
import 'ssh_service.dart';
import 'x11_forwarding.dart';

/// Whether a session can open a program's window on this device, and if not,
/// why — the reasons the launcher explains and, for every one of them, answers
/// with the virtual desktop instead.
enum RemoteAppAvailability {
  available,

  /// Android and iOS: there is no X server to draw a window on.
  unsupportedDevice,

  /// A desktop, but nothing to draw on: `DISPLAY` is not set, or the X server
  /// it names does not answer. On Windows, no VcXsrv or X410 is running.
  noLocalDisplay,

  /// There is no SSH connection to start anything on: the session is closed,
  /// or only its Mosh terminal is still up.
  sshUnavailable,

  /// The server answered an `x11-req` with a refusal on this connection —
  /// `X11Forwarding no`, no `xauth`, or a certificate without
  /// `permit-X11-forwarding`. Its settings are fixed for the life of the
  /// connection, so asking again would only be refused again.
  serverRefused,
}

/// The reasons a session cannot open a window that can be known without
/// asking the server or the X server, in the order they are worth fixing: a
/// device that cannot do it at all first, since nothing else matters there.
///
/// [supportedPlatform] stands in for [X11Forwarder.isSupportedPlatform] in
/// tests. [RemoteAppRunner.availability] adds the two things only a try can
/// tell: a refusal by the server and an X server that does not answer.
RemoteAppAvailability checkRemoteAppAvailability(
  SessionController session, {
  bool? supportedPlatform,
}) {
  if (!(supportedPlatform ?? X11Forwarder.isSupportedPlatform)) {
    return RemoteAppAvailability.unsupportedDevice;
  }
  final transport = session.connection;
  if (session.isClosed || session.isSshLostUnderMosh || transport.isClosed) {
    return RemoteAppAvailability.sshUnavailable;
  }
  if (transport.x11Forwarder == null) {
    // Every connection on a desktop has one, the host's X11 switch on or
    // off (that only decides the shell's): none means no display here.
    return RemoteAppAvailability.noLocalDisplay;
  }
  return RemoteAppAvailability.available;
}

/// [RemoteAppRunner.launch] was called while the session could not open a
/// window. The launcher does not offer Run then; this is for anything else
/// that calls it.
class RemoteAppUnavailable implements Exception {
  const RemoteAppUnavailable(this.reason);

  final RemoteAppAvailability reason;

  @override
  String toString() => 'Cannot open an app in a window: ${reason.name}.';
}

/// Why an app that never ran or lost its connection did not carry on. What
/// the server or the OS said, where there is anything to add, is in
/// [RemoteAppFailed.detail].
enum RemoteAppFailure {
  /// The server turned down the `x11-req`: the program never ran.
  serverRefused,

  /// The connection went away while the program ran, so what became of it is
  /// not known.
  connectionLost,

  /// The channel could not be opened or the command not started, for a
  /// reason that is the server's own to give.
  couldNotStart,
}

/// Where a [RemoteApp] is in its life.
sealed class RemoteAppState {
  const RemoteAppState();
}

/// The channel is being opened.
final class RemoteAppStarting extends RemoteAppState {
  const RemoteAppStarting();
}

/// The channel is open and the program is on the server.
final class RemoteAppRunning extends RemoteAppState {
  const RemoteAppRunning();
}

/// The program ended and the server said how: an exit [code], or the
/// [signal] that ended it. Neither when the channel simply closed.
/// [stopped] is set when it was this app's Stop that did it.
final class RemoteAppExited extends RemoteAppState {
  const RemoteAppExited({this.code, this.signal, this.stopped = false});

  final int? code;
  final String? signal;
  final bool stopped;
}

/// The program did not run, or the connection to it was lost.
final class RemoteAppFailed extends RemoteAppState {
  const RemoteAppFailed(this.failure, [this.detail]);

  final RemoteAppFailure failure;
  final String? detail;
}

/// The last [capacity] bytes a process wrote to stderr.
///
/// An app that is chatty on stderr (GTK warnings, mostly) must not grow
/// without bound for the life of a session, and what explains a program that
/// would not start is what it said last.
class StderrTail {
  StderrTail({this.capacity = defaultCapacity});

  /// About 8 KB: a few screenfuls of messages.
  static const int defaultCapacity = 8 * 1024;

  final int capacity;
  final List<int> _bytes = [];
  var _truncated = false;

  /// Whether older output was dropped to stay within [capacity].
  bool get truncated => _truncated;

  bool get isEmpty => _bytes.isEmpty;

  void add(List<int> chunk) {
    if (chunk.length >= capacity) {
      _bytes
        ..clear()
        ..addAll(chunk.sublist(chunk.length - capacity));
      _truncated = _truncated || chunk.length > capacity;
    } else {
      _bytes.addAll(chunk);
      final excess = _bytes.length - capacity;
      if (excess > 0) {
        _bytes.removeRange(0, excess);
        _truncated = true;
      }
    }
    if (_truncated) {
      // The cut can fall inside a character; the rest of it is not text.
      var skip = 0;
      while (skip < _bytes.length && skip < 3 && (_bytes[skip] & 0xC0) == 0x80) {
        skip++;
      }
      if (skip > 0) _bytes.removeRange(0, skip);
    }
  }

  /// What was kept, decoded leniently: this is arbitrary output from an
  /// arbitrary server.
  String get text => utf8.decode(_bytes, allowMalformed: true);
}

/// [stderr] without what sshd itself writes there while it sets up the
/// forwarded display rather than anything the program said: the first time
/// an account forwards X11, xauth reports the `.Xauthority` it is about to
/// create. Shown as the app's error output, it read as a failure.
String withoutSshdNotes(String stderr) => stderr.replaceAll(
    RegExp(r'^\S*xauth: +file \S+ does not exist\r?\n?', multiLine: true), '');

/// One program started with "Open an app in a window", and what became of it.
///
/// Created and changed by [RemoteAppRunner] alone; a view reads it and is
/// told by the runner's own notifications that something moved.
class RemoteApp {
  RemoteApp._({
    required this.id,
    required this.command,
    required this.startedAt,
    required SessionTransport transport,
    // A named parameter cannot be private.
    // ignore: prefer_initializing_formals
  }) : _transport = transport;

  /// Unique within the runner, in the order apps were started.
  final int id;

  /// What the person typed, as typed (trimmed).
  final String command;

  final DateTime startedAt;

  /// The connection this ran on. After a reconnect it is a different one, and
  /// the program is gone with the old.
  final SessionTransport _transport;

  RemoteAppState _state = const RemoteAppStarting();

  RemoteAppState get state => _state;

  /// Still starting or running: Stop applies, and the channel is open.
  bool get isActive => _state is RemoteAppStarting || _state is RemoteAppRunning;

  int? _pid;

  /// The server's process id for the shell that runs the program (see
  /// [RemoteAppRunner.wrapCommand]), once it has said. Null before that, and
  /// the reason Stop can only close the channel then.
  int? get pid => _pid;

  final StderrTail _stderr = StderrTail();

  /// The last of what the program wrote to stderr, about 8 KB, without
  /// sshd's own notes about setting up the display (see [withoutSshdNotes]).
  String get stderrTail => withoutSshdNotes(_stderr.text);

  /// Whether [stderrTail] begins part-way into the output.
  bool get stderrTruncated => _stderr.truncated;

  final List<String> _problems = [];

  /// What the X11 forwarder could not do for a program on this connection —
  /// "Could not reach the X server at :0", a wrong cookie — newest last, at
  /// most [RemoteAppRunner.maxProblems]. These are the lines the shell would
  /// have printed into its own terminal.
  List<String> get problems => List.unmodifiable(_problems);

  bool? _trusted;

  /// Whether the server's X clients were let into this display with full
  /// access (`ssh -Y`) rather than limited (`ssh -X`). Null before that was
  /// decided.
  bool? get trusted => _trusted;

  SSHSession? _channel;
  StreamSubscription<String>? _problemsSubscription;
  var _stopping = false;

  /// Whether Stop has been pressed and is still being carried out.
  bool get isStopping => _stopping && isActive;
}

/// Opens the exec channel for an app. A seam, because the transport's own
/// `execute` deliberately takes no X11 request.
typedef RemoteAppChannelOpener = Future<SSHSession> Function(
  SessionTransport transport,
  String command,
  SSHX11Config x11,
);

/// Starts graphical programs on a session's server, one exec channel each,
/// with X11 forwarding asked for on that channel and no terminal.
///
/// **Why a channel per app, and kept open.** sshd ties the forwarded display
/// to the channel that asked for it: it makes `DISPLAY` for that channel, and
/// takes the display away when the channel closes. So the channel is held for
/// as long as the program runs, and Stop closes it after killing the process.
///
/// **Per connection, as for the shell.** Whether this works is decided when
/// the connection is dialled (see [SessionTransport.x11Forwarder]): the app
/// reuses that connection's forwarder, fake cookie and all, so windows reach
/// the local X server exactly as a shell's do, with the same untrusted or
/// trusted access and the same checks on every connection.
///
/// One runner per session ([of]); it ends its apps when the session closes.
class RemoteAppRunner extends ChangeNotifier {
  RemoteAppRunner(
    this.session, {
    bool? isSupportedPlatform,
    bool? isWindows,
    RemoteAppChannelOpener? openChannel,
    Future<void> Function(X11Display display)? reachDisplay,
    DateTime Function()? clock,
    this.stopTimeout = const Duration(seconds: 5),
  })  : _supported = isSupportedPlatform ?? X11Forwarder.isSupportedPlatform,
        isWindows = isWindows ?? Platform.isWindows,
        _openChannel = openChannel ?? _openOnConnection,
        _reachDisplay = reachDisplay ?? _connectAndHangUp,
        _clock = clock ?? DateTime.now {
    _knownTransport = session.connection;
    _sessionChanges = session.changes.listen(
      (_) => _onSessionChanged(),
      onDone: dispose,
    );
  }

  static final Expando<RemoteAppRunner> _runners = Expando<RemoteAppRunner>();

  /// The runner for [session], made on first use. It has to outlive the
  /// launcher, whose dialog is closed while the programs go on.
  static RemoteAppRunner of(SessionController session) =>
      _runners[session] ??= RemoteAppRunner(session);

  final SessionController session;

  /// Whether this is Windows, whose X servers (VcXsrv, X410) are a separate
  /// install and always give a server's programs full access.
  final bool isWindows;

  /// How long Stop waits for the `kill` to come back before closing the
  /// channel anyway.
  final Duration stopTimeout;

  /// How many of the forwarder's problems an app keeps.
  static const int maxProblems = 5;

  final bool _supported;
  final RemoteAppChannelOpener _openChannel;
  final Future<void> Function(X11Display display) _reachDisplay;
  final DateTime Function() _clock;

  final List<RemoteApp> _apps = [];
  var _nextId = 1;
  var _disposed = false;

  late SessionTransport _knownTransport;
  StreamSubscription<void>? _sessionChanges;

  /// The connection the server refused X11 on, and the one whose X server did
  /// not answer, by identity: a reconnect brings a new transport and so a
  /// clean slate, with nothing to reset.
  SessionTransport? _refusedOn;
  SessionTransport? _displayDownOn;
  bool? _trustedOnKnown;
  SessionTransport? _trustedDecidedOn;

  /// Everything started in this session that has not been removed, oldest
  /// first.
  List<RemoteApp> get apps => List.unmodifiable(_apps);

  /// How many are starting or running.
  int get activeCount => _apps.where((a) => a.isActive).length;

  /// Whether the display's X clients get full access, once known — after
  /// [probe] or the first launch.
  bool? get trusted =>
      identical(_trustedDecidedOn, session.connection) ? _trustedOnKnown : null;

  /// Forgets that the server refused X11 on this connection, once something
  /// has been done about it — `xauth` installed there, which sshd looks for
  /// on each request — so the next Run asks again.
  void forgetRefusal() {
    if (_refusedOn == null) return;
    _refusedOn = null;
    notifyListeners();
  }

  /// Whether a window can be opened now, and if not, why.
  RemoteAppAvailability get availability {
    final base = checkRemoteAppAvailability(session, supportedPlatform: _supported);
    if (base != RemoteAppAvailability.available) return base;
    final transport = session.connection;
    if (identical(_refusedOn, transport)) {
      return RemoteAppAvailability.serverRefused;
    }
    if (identical(_displayDownOn, transport)) {
      return RemoteAppAvailability.noLocalDisplay;
    }
    return RemoteAppAvailability.available;
  }

  /// [availability], after finding out whether the local X server answers —
  /// which nothing else can say: `DISPLAY` is set on a desktop whose X server
  /// has gone, and on Windows the display is assumed. Also decides, ahead of
  /// the first launch, whether programs get limited or full access.
  ///
  /// Connects to the X server and hangs up without a word, which it ignores.
  Future<RemoteAppAvailability> probe() async {
    final reason = availability;
    if (reason != RemoteAppAvailability.available &&
        reason != RemoteAppAvailability.noLocalDisplay) {
      return reason;
    }
    final transport = session.connection;
    final forwarder = transport.x11Forwarder;
    if (forwarder == null) return reason;
    try {
      await _reachDisplay(forwarder.display);
    } catch (_) {
      if (_disposed) return reason;
      _displayDownOn = transport;
      notifyListeners();
      return availability;
    }
    if (_disposed) return reason;
    if (identical(_displayDownOn, transport)) _displayDownOn = null;
    await _decideTrust(transport, forwarder);
    if (!_disposed) notifyListeners();
    return availability;
  }

  Future<void> _decideTrust(
    SessionTransport transport,
    X11Forwarder forwarder,
  ) async {
    try {
      await forwarder.prepare();
    } catch (_) {
      // Decided as trusted by the forwarder itself; nothing to add.
    }
    _trustedDecidedOn = transport;
    _trustedOnKnown = forwarder.trusted;
  }

  /// Whether the certificate this host signs in with lacks
  /// `permit-X11-forwarding` — the commonest reason sshd refuses the request,
  /// since it checks that before its own settings.
  bool get certificateBlocksX11 {
    final text = session.host.certificate;
    if (text == null || text.trim().isEmpty) return false;
    try {
      return !SshCertificate.parse(text).permitsX11Forwarding;
    } on SshCertificateException {
      return false;
    }
  }

  /// The remote command for [command]: a shell that prints its own process id
  /// and then becomes the shell that runs [command].
  ///
  /// [command] is a shell command line — `FOO=1 app`, `xterm -e htop`, a
  /// pipeline — so it is handed to a second `sh -c` as an argument rather than
  /// spliced into the first, and quoted once, with [posixSingleQuote], for
  /// whatever login shell the account has (bash, zsh and fish all read it the
  /// same). `exec` keeps the pid that was printed.
  ///
  /// That pid is the program's own only where the shell runs the last command
  /// in place, as bash does; dash, which is `sh` on Debian and Ubuntu, forks
  /// it instead. So the pid is of the shell *around* the program, and Stop
  /// takes the shell's children with it (see [killCommand]).
  static String wrapCommand(String command) {
    return 'sh -c ${posixSingleQuote(r'echo $$; exec sh -c "$1"')} sh '
        '${posixSingleQuote(command)}';
  }

  /// The command that ends the app whose process id is [pid]: the children of
  /// the shell that runs it first, since once the shell is gone they are no
  /// longer found by it, then the shell itself. The program is one of those
  /// children wherever the shell does not run it in place. [pid] is a number
  /// the server printed and only ever digits here.
  static String killCommand(int pid) =>
      'pkill -P $pid 2>/dev/null; kill $pid 2>/dev/null';

  /// Starts [command] on the server and returns once the channel is open, or
  /// has failed to open: whichever it is, the returned app says so and keeps
  /// changing as the program runs.
  ///
  /// Throws [RemoteAppUnavailable] when [availability] is not
  /// [RemoteAppAvailability.available], and [ArgumentError] for an empty
  /// command.
  Future<RemoteApp> launch(String command) async {
    final text = command.trim();
    if (text.isEmpty) throw ArgumentError.value(command, 'command', 'is empty');
    final reason = availability;
    if (reason != RemoteAppAvailability.available) {
      throw RemoteAppUnavailable(reason);
    }
    final transport = session.connection;
    final forwarder = transport.x11Forwarder!;
    final app = RemoteApp._(
      id: _nextId++,
      command: text,
      startedAt: _clock(),
      transport: transport,
    );
    _apps.add(app);
    notifyListeners();

    // Before the channel, as the shell does it: whether the display can only
    // be forwarded with full access is known, and said, before any program
    // there uses it.
    await _decideTrust(transport, forwarder);
    app._trusted = forwarder.trusted;

    final SSHSession channel;
    try {
      channel = await _openChannel(
          transport, wrapCommand(appWindowCommandFor(text)), forwarder.config);
    } on SSHChannelRequestError catch (e) {
      if (e.message.toLowerCase().contains(refusedX11Request)) {
        _refusedOn = transport;
        _end(app, const RemoteAppFailed(RemoteAppFailure.serverRefused));
      } else {
        _end(app, RemoteAppFailed(RemoteAppFailure.couldNotStart, e.message));
      }
      return app;
    } catch (e) {
      _end(app, RemoteAppFailed(RemoteAppFailure.couldNotStart, '$e'));
      return app;
    }

    if (_disposed || !app.isActive) {
      // The session ended while the channel was opening.
      _closeChannel(channel);
      if (app.isActive) _end(app, const RemoteAppFailed(RemoteAppFailure.connectionLost));
      return app;
    }
    _attach(app, channel, forwarder);
    return app;
  }

  void _attach(RemoteApp app, SSHSession channel, X11Forwarder forwarder) {
    app._channel = channel;
    app._state = const RemoteAppRunning();
    notifyListeners();

    // Nothing is fed to the program, and one that waits for the end of its
    // input would otherwise wait for good.
    try {
      unawaited(channel.stdin.close().catchError((Object _) {}));
    } catch (_) {
      // Already closed.
    }

    final scanner = _PidScanner();
    final stdoutDone = Completer<void>();
    final stderrDone = Completer<void>();
    channel.stdout.listen(
      (chunk) {
        if (scanner.finished) return;
        final pid = scanner.feed(chunk);
        if (pid != null) {
          app._pid = pid;
          _notifyNow();
        }
      },
      onDone: () => _complete(stdoutDone),
      onError: (Object _) => _complete(stdoutDone),
    );
    channel.stderr.listen(
      (chunk) {
        app._stderr.add(chunk);
        _notifyThrottled();
      },
      onDone: () => _complete(stderrDone),
      onError: (Object _) => _complete(stderrDone),
    );
    app._problemsSubscription = forwarder.problems.listen((problem) {
      if (app._problems.isNotEmpty && app._problems.last == problem) return;
      app._problems.add(problem);
      if (app._problems.length > maxProblems) app._problems.removeAt(0);
      _notifyNow();
    });

    channel.done.then<void>((_) async {
      // The channel is closed, but output sent before that can still be on its
      // way; the last of stderr is what says why a program would not start.
      await Future.wait([stdoutDone.future, stderrDone.future])
          .timeout(const Duration(seconds: 1), onTimeout: () => const []);
      _onChannelDone(app, channel);
    }, onError: (Object error) {
      if (app.isActive) {
        _end(app, RemoteAppFailed(RemoteAppFailure.connectionLost, '$error'));
      }
    });
  }

  void _onChannelDone(RemoteApp app, SSHSession channel) {
    if (!app.isActive) return;
    final code = channel.exitCode;
    final signal = channel.exitSignal?.signalName;
    if (app._stopping) {
      _end(app, RemoteAppExited(code: code, signal: signal, stopped: true));
    } else if (code == null &&
        signal == null &&
        (_disposed ||
            app._transport.isClosed ||
            !identical(session.connection, app._transport) ||
            session.isClosed)) {
      _end(app, const RemoteAppFailed(RemoteAppFailure.connectionLost));
    } else {
      _end(app, RemoteAppExited(code: code, signal: signal));
    }
  }

  /// Ends [app] in [state], once, and lets go of what it was holding.
  void _end(RemoteApp app, RemoteAppState state) {
    if (!app.isActive) return;
    app._state = state;
    unawaited(app._problemsSubscription?.cancel());
    app._problemsSubscription = null;
    if (!_disposed) notifyListeners();
  }

  /// Ends the app on the server and closes its channel, which takes its
  /// display with it.
  ///
  /// The process is killed first, by a separate exec: closing the channel
  /// alone leaves a program that does not notice its X connection going.
  /// Before the server has said the pid there is nothing to kill, and the
  /// channel is only closed.
  Future<void> stop(RemoteApp app) async {
    if (!app.isActive || app._stopping) return;
    app._stopping = true;
    notifyListeners();
    final pid = app._pid;
    final transport = app._transport;
    if (pid != null &&
        !transport.isClosed &&
        identical(transport, session.connection)) {
      try {
        await RemoteExec.run(transport, killCommand(pid), timeout: stopTimeout);
      } catch (_) {
        // The connection went, or the server would not run it: the channel
        // is closed below either way, and that ends the program's display.
      }
    }
    final channel = app._channel;
    if (channel != null) _closeChannel(channel);
    _end(app, const RemoteAppExited(stopped: true));
  }

  /// Stops everything still running.
  Future<void> stopAll() =>
      Future.wait([for (final app in apps) stop(app)]).then<void>((_) {});

  /// Drops an app that has ended from the list.
  void remove(RemoteApp app) {
    if (app.isActive) return;
    if (_apps.remove(app)) notifyListeners();
  }

  /// Drops every app that has ended.
  void clearFinished() {
    final before = _apps.length;
    _apps.removeWhere((a) => !a.isActive);
    if (_apps.length != before) notifyListeners();
  }

  void _onSessionChanged() {
    if (_disposed) return;
    final transport = session.connection;
    if (!identical(transport, _knownTransport)) {
      // A reconnect: the old connection's programs went with it.
      _knownTransport = transport;
      _endAll(const RemoteAppFailed(RemoteAppFailure.connectionLost));
    } else if (session.isClosed) {
      _endAll(const RemoteAppFailed(RemoteAppFailure.connectionLost));
    }
    // The session reports every little thing (a transfer's progress, a
    // terminal title); only what the launcher shows is passed on.
    final now = availability;
    if (now != _lastAvailability) {
      _lastAvailability = now;
      notifyListeners();
    }
  }

  RemoteAppAvailability? _lastAvailability;

  void _endAll(RemoteAppFailed state) {
    for (final app in _apps) {
      if (!app.isActive) continue;
      final channel = app._channel;
      _end(app, state);
      if (channel != null) _closeChannel(channel);
    }
  }

  /// Ends every app and lets go of the session. Called when the session is
  /// disposed, and safe to call again.
  ///
  /// No `kill` is sent: the connection is closing with the session, and the
  /// forwarded display goes with its channels.
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_sessionChanges?.cancel());
    _sessionChanges = null;
    _throttle?.cancel();
    _endAll(const RemoteAppFailed(RemoteAppFailure.connectionLost));
    super.dispose();
  }

  static void _closeChannel(SSHSession channel) {
    try {
      channel.close();
    } catch (_) {
      // Already gone.
    }
  }

  static void _complete(Completer<void> completer) {
    if (!completer.isCompleted) completer.complete();
  }

  // -------------------------------------------------------------- notifying

  Timer? _throttle;
  DateTime? _lastThrottled;

  void _notifyNow() {
    if (!_disposed) notifyListeners();
  }

  /// For stderr, which a program can write in a flood: the first chunk is
  /// shown at once, and the rest at most every [_throttleEvery].
  void _notifyThrottled() {
    if (_disposed || _throttle != null) return;
    final now = _clock();
    final last = _lastThrottled;
    if (last == null || now.difference(last) >= _throttleEvery) {
      _lastThrottled = now;
      notifyListeners();
      return;
    }
    _throttle = Timer(_throttleEvery, () {
      _throttle = null;
      _lastThrottled = _clock();
      _notifyNow();
    });
  }

  static const Duration _throttleEvery = Duration(milliseconds: 150);

  // ------------------------------------------------------------ real wiring

  /// The exec with `x11-req` on a real connection. dartssh2 throws
  /// [SSHChannelRequestError] ("Failed to request x11 forwarding") when the
  /// server says no — before the command is sent, so nothing has run.
  static Future<SSHSession> _openOnConnection(
    SessionTransport transport,
    String command,
    SSHX11Config x11,
  ) {
    if (transport is SshConnection) {
      return transport.client.execute(command, x11: x11);
    }
    throw UnsupportedError('This connection cannot forward X11.');
  }

  static Future<void> _connectAndHangUp(X11Display display) async {
    final socket = await connectToX11Display(display);
    socket.destroy();
  }
}

/// Finds the process id the wrapper prints before the program's own output
/// begins: the first line of stdout that is only digits, among the first few.
class _PidScanner {
  static const int _maxLines = 4;
  static const int _maxLineLength = 64;

  final List<int> _line = [];
  var _lines = 0;
  var finished = false;

  int? feed(List<int> chunk) {
    for (final byte in chunk) {
      if (byte != 0x0a) {
        if (_line.length < _maxLineLength) _line.add(byte);
        continue;
      }
      final text = latin1.decode(_line).trim();
      _line.clear();
      _lines++;
      final pid = RegExp(r'^\d{1,10}$').hasMatch(text) ? int.parse(text) : null;
      if (pid != null && pid > 0) {
        finished = true;
        return pid;
      }
      if (_lines >= _maxLines) {
        finished = true;
        return null;
      }
    }
    return null;
  }
}
