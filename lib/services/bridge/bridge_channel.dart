import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'bridge_client_store.dart';
import 'bridge_locator.dart';

/// One verified peer on the local channel: newline-delimited UTF-8 JSON, one
/// message per line, after the handshake. Abstract so the MCP server can be
/// tested over an in-memory pair instead of a socket.
abstract class BridgeConnection {
  /// The paired assistant the handshake proved this peer to be.
  BridgeClient get client;

  /// Incoming lines, without their newline. Ends when the peer closes, or
  /// when the connection is dropped (an oversized or undecodable line).
  Stream<String> get lines;

  /// Sends one message. [line] must not contain a newline — it would split
  /// one message into two on the far side.
  void send(String line);

  Future<void> close();
}

/// Thrown by [BridgeListener.start] when another instance of the app is
/// already listening on the endpoint. Not an error to show as one: the
/// bridge is running, just in the other window.
class BridgeAlreadyRunning implements Exception {
  const BridgeAlreadyRunning();

  @override
  String toString() =>
      'Another SecureShell Go window is already running the AI Bridge.';
}

/// Thrown by [BridgeListener.start] when the endpoint cannot be set up.
class BridgeChannelException implements Exception {
  const BridgeChannelException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// How the listener is reached. [unix] on Linux and macOS; [tcp] on Windows,
/// where Dart cannot use unix sockets. The one seam between the two, so the
/// tcp path is tested on Linux too.
enum BridgeTransportKind { unix, tcp }

/// Unix socket paths are capped by `sun_path` (108 bytes on Linux, 104 on
/// macOS); past this the bind fails, so a long data path falls back to the
/// runtime directory.
const int bridgeMaxSocketPathBytes = 100;

/// Where the unix socket goes: `<bridge dir>/bridge.sock`, or
/// `$XDG_RUNTIME_DIR/secureshellgo-bridge.sock` when that is too long. The
/// runtime directory is per-user and 0700 by the XDG spec, so it keeps the
/// same privacy as the bridge directory. No runtime directory and a long
/// path is an error rather than a fallback to `/tmp`, which is shared.
///
/// Inside a Flatpak (`FLATPAK_ID` set) the fallback is
/// `$XDG_RUNTIME_DIR/app/$FLATPAK_ID/` instead. There `XDG_RUNTIME_DIR`
/// itself is a fresh directory for each sandbox instance, and the launcher
/// runs in an instance of its own (`flatpak run --command=…`), so a socket
/// there could not be reached; the `app/<id>` directory is the one Flatpak
/// shares between all instances of the app. The Flatpak's bridge directory,
/// under `~/.var/app/<id>/data/<id>/`, is usually too long for the socket,
/// so this is the path a Flatpak normally uses.
String bridgeSocketPath(String bridgeDir, Map<String, String> environment) {
  final preferred = '$bridgeDir/bridge.sock';
  if (utf8.encode(preferred).length <= bridgeMaxSocketPathBytes) {
    return preferred;
  }
  var runtime = environment['XDG_RUNTIME_DIR'];
  final flatpakId = environment['FLATPAK_ID'] ?? '';
  if (runtime != null && flatpakId.isNotEmpty) {
    runtime = flatpakId.contains('/') || flatpakId.startsWith('.')
        ? null
        : '$runtime/app/$flatpakId';
  }
  if (runtime != null && runtime.startsWith('/')) {
    final fallback = '$runtime/secureshellgo-bridge.sock';
    if (utf8.encode(fallback).length <= bridgeMaxSocketPathBytes) {
      return fallback;
    }
  }
  throw const BridgeChannelException(
    'The AI Bridge socket path is too long for this system.',
  );
}

/// Accepts launcher connections, checks each handshake, and hands verified
/// ones to [connections].
///
/// Unix kind, one line from the peer:
/// `{"ssg_bridge":1,"token":"…"}`.
///
/// Tcp kind, mutual: the peer sends `{"ssg_bridge":1,"hello":"<nonce>"}`,
/// the listener answers `{"proof":"<hex HMAC-SHA256(secret, nonce)>"}`, and
/// only a peer satisfied with the proof sends
/// `{"ssg_bridge":1,"token":"…","secret":"…"}`. The launcher thereby never
/// sends its token to whatever else may hold a stale port.
///
/// Either way the last reply is `{"ok":true}`, after which every line is
/// MCP, or `{"ok":false,"error":"…"}` and the connection is closed.
///
/// Until the handshake is done the peer is any local process, so it gets
/// little: at most [maxPendingHandshakes] at once, lines of at most
/// [maxHandshakeLineBytes], [handshakeTimeout] for the whole exchange, and
/// a refusal only after [failedHandshakeDelay].
class BridgeListener {
  BridgeListener({
    required this.bridgeDir,
    required this.verify,
    BridgeTransportKind? transport,
    Map<String, String>? environment,
    this.handshakeTimeout = const Duration(seconds: 5),
    this.maxLineBytes = bridgeMaxLineBytes,
    Random? random,
    this.maxPendingHandshakes = 8,
    this.maxHandshakeLineBytes = bridgeMaxHandshakeLineBytes,
    this.failedHandshakeDelay = const Duration(milliseconds: 500),
    this.maxQueuedOutputBytes = 4 * 1024 * 1024,
    Future<ServerSocket> Function(InternetAddress address, int port)? bind,
  }) : _bind = bind ?? ServerSocket.bind,
       transport =
           transport ??
           (Platform.isWindows
               ? BridgeTransportKind.tcp
               : BridgeTransportKind.unix),
       _environment = environment ?? Platform.environment,
       _random = random ?? Random.secure();

  /// `<app data>/bridge`, see `bridgeDirectoryFor`.
  final String bridgeDir;
  final BridgeTransportKind transport;
  final Duration handshakeTimeout;

  /// The cap on one MCP line once the handshake is done.
  final int maxLineBytes;

  /// Connections still in the handshake at once; newer ones are dropped on
  /// arrival. A paired launcher completes its handshake in milliseconds, so
  /// only something hammering the endpoint ever meets this.
  final int maxPendingHandshakes;

  /// The cap on one line before the handshake is done.
  final int maxHandshakeLineBytes;

  /// How long a refused handshake waits before its reply, so guessing
  /// costs time.
  final Duration failedHandshakeDelay;

  /// Outbound bytes a connection may have waiting for the peer to read
  /// before it is dropped: a peer that sends requests and never reads the
  /// answers must not grow the app's memory without bound.
  final int maxQueuedOutputBytes;

  /// Looks a token up among the paired clients (`BridgeClientStore.verify`).
  final Future<BridgeClient?> Function(String token) verify;
  final Map<String, String> _environment;
  final Random _random;

  /// `ServerSocket.bind`, replaceable so a bind that fails (a port the OS
  /// will not give, which Windows can do) can be exercised on any platform.
  final Future<ServerSocket> Function(InternetAddress address, int port)
  _bind;

  final _connections = StreamController<BridgeConnection>.broadcast();
  final Set<_SocketConnection> _open = {};
  ServerSocket? _server;
  StreamSubscription<Socket>? _accepting;
  String? _socketPath;
  String? _secret;

  /// Whether this instance wrote the locator file. A listener whose start
  /// was refused (another window holds the endpoint) must not remove the
  /// file that window wrote when it is stopped.
  bool _ownsLocator = false;

  late final BridgeLocator locator = BridgeLocator(bridgeDir);

  /// Verified connections. A connection that arrives while nobody listens is
  /// closed rather than left hanging.
  Stream<BridgeConnection> get connections => _connections.stream;

  bool get isRunning => _server != null;

  /// What the locator file says while running; null when stopped.
  BridgeEndpoint? get endpoint {
    final server = _server;
    if (server == null) return null;
    return switch (transport) {
      BridgeTransportKind.unix => BridgeUnixEndpoint(_socketPath!),
      BridgeTransportKind.tcp => BridgeTcpEndpoint(server.port, _secret!),
    };
  }

  Future<void> start() async {
    if (_server != null) return;
    final dir = Directory(bridgeDir);
    await dir.create(recursive: true);
    await restrictToOwner(dir.path, '700');

    final ServerSocket server;
    switch (transport) {
      case BridgeTransportKind.unix:
        final path = bridgeSocketPath(bridgeDir, _environment);
        await _clearStaleSocket(path);
        try {
          server = await _bind(
            InternetAddress(path, type: InternetAddressType.unix),
            0,
          );
        } on SocketException catch (e) {
          throw BridgeChannelException(
            'The AI Bridge could not listen: ${e.message}',
          );
        }
        // Bound at the umask's mode for a moment; the directory (or the
        // XDG runtime directory) is already 0700, so nobody else can reach
        // it in that window.
        try {
          await restrictToOwner(path, '600');
        } catch (_) {
          await server.close();
          await _deleteQuietly(path);
          rethrow;
        }
        _socketPath = path;
      case BridgeTransportKind.tcp:
        await _refuseIfTcpPeerAlive();
        try {
          server = await _bind(InternetAddress.loopbackIPv4, 0);
        } on SocketException catch (e) {
          throw BridgeChannelException(
            'The AI Bridge could not listen: ${e.message}',
          );
        }
        _secret = bridgeNonce(_random);
    }
    _server = server;
    _accepting = server.listen(_accept);
    try {
      await locator.write(endpoint!);
      _ownsLocator = true;
    } catch (_) {
      await stop();
      rethrow;
    }
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    await _accepting?.cancel();
    _accepting = null;
    await server?.close();
    for (final c in _open.toList()) {
      await c.close();
    }
    _open.clear();
    if (_ownsLocator) {
      _ownsLocator = false;
      await locator.remove();
    }
    final path = _socketPath;
    _socketPath = null;
    _secret = null;
    if (path != null) await _deleteQuietly(path);
  }

  /// A socket file left by a crashed instance refuses connections; one held
  /// by a live instance accepts them. Only the first may be cleared away.
  Future<void> _clearStaleSocket(String path) async {
    if (FileSystemEntity.typeSync(path, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return;
    }
    try {
      final probe = await Socket.connect(
        InternetAddress(path, type: InternetAddressType.unix),
        0,
        timeout: const Duration(seconds: 2),
      );
      probe.destroy();
      throw const BridgeAlreadyRunning();
    } on SocketException {
      await _deleteQuietly(path);
    }
  }

  /// A port, unlike a socket path, can be reused by anything once its owner
  /// dies, so "something accepts on the old port" proves nothing. A live
  /// instance is one that proves it holds the old locator's secret; anything
  /// else is stale. No token is sent either way.
  Future<void> _refuseIfTcpPeerAlive() async {
    final old = await locator.read();
    if (old is! BridgeTcpEndpoint) return;
    if (await bridgeTcpPeerIsLive(old, random: _random)) {
      throw const BridgeAlreadyRunning();
    }
  }

  void _accept(Socket socket) {
    final pending = _open.where((c) => !c._verified).length;
    if (pending >= maxPendingHandshakes) {
      socket.destroy();
      return;
    }
    final connection = _SocketConnection(socket, this);
    _open.add(connection);
    connection._begin();
  }

  void _forget(_SocketConnection c) => _open.remove(c);

  /// The tcp kind's first line: the proof for its nonce, or a refusal
  /// ([_Refusal]).
  Object _answerHello(String line) {
    final json = _decode(line);
    if (json is! Map || !json.containsKey('ssg_bridge')) {
      return const _Refusal('This is not an AI Bridge handshake.');
    }
    if (json['ssg_bridge'] != bridgeHandshakeVersion ||
        !json.containsKey('hello')) {
      return const _Refusal(_versionMismatch);
    }
    final nonce = json['hello'];
    // A real nonce is 43 characters; the bound only stops a peer making the
    // listener hash something large.
    if (nonce is! String || nonce.length < 16 || nonce.length > 256) {
      return const _Refusal('This is not an AI Bridge handshake.');
    }
    return bridgeProof(_secret ?? '', nonce);
  }

  /// The token line's verdict: the client, or a [_Refusal].
  Future<Object> _check(String line) async {
    final json = _decode(line);
    if (json is! Map) {
      return const _Refusal('This is not an AI Bridge handshake.');
    }
    if (transport == BridgeTransportKind.unix) {
      if (!json.containsKey('ssg_bridge')) {
        return const _Refusal('This is not an AI Bridge handshake.');
      }
      if (json['ssg_bridge'] != bridgeHandshakeVersion) {
        return const _Refusal(_versionMismatch);
      }
    } else {
      final version = json['ssg_bridge'];
      if (version != null && version != bridgeHandshakeVersion) {
        return const _Refusal(_versionMismatch);
      }
      final secret = json['secret'];
      // Checked before the token so a process that cannot read the
      // locator file cannot use the listener to test guessed tokens.
      if (secret is! String ||
          !bridgeConstantTimeEquals(secret, _secret ?? '')) {
        return const _Refusal(
          'The AI Bridge address is out of date. Restart the assistant.',
        );
      }
    }
    final token = json['token'];
    if (token is! String || token.isEmpty) {
      return const _Refusal(_notPaired);
    }
    final client = await verify(token);
    return client ?? const _Refusal(_notPaired);
  }

  static Object? _decode(String line) {
    try {
      return jsonDecode(line);
    } on FormatException {
      return null;
    }
  }

  static const String _versionMismatch =
      'This launcher does not match this version of SecureShell Go. '
      'Update both to the same version.';

  static const String _notPaired =
      'This assistant is not paired with SecureShell Go, or its pairing was '
      'removed. Connect it again from Settings, AI Bridge.';
}

class _Refusal {
  const _Refusal(this.message);

  final String message;
}

Future<void> _deleteQuietly(String path) async {
  try {
    await File(path).delete();
  } on IOException {
    // Gone already.
  }
}

/// Where a connection is in the handshake.
enum _Stage { hello, token, verifying, open }

/// A socket through the handshake and after it.
class _SocketConnection implements BridgeConnection {
  _SocketConnection(this._socket, this._listener)
    : _stage = _listener.transport == BridgeTransportKind.tcp
          ? _Stage.hello
          : _Stage.token {
    // Every outbound byte goes through [_out], so what the peer has not yet
    // taken can be counted: the socket pauses this stream while the OS
    // buffer is full, and the bytes wait in [_out] until it resumes.
    _outDone = _socket
        .addStream(
          _out.stream.map((chunk) {
            _queued -= chunk.length;
            return chunk;
          }),
        )
        // Not catchError: the socket's future has its own type at run time,
        // and a handler that returns nothing is refused for it, which turned
        // a peer that left early into an uncaught error.
        .then<void>((_) {}, onError: (Object _) {});
  }

  final Socket _socket;
  final BridgeListener _listener;
  final _lines = StreamController<String>();
  final _out = StreamController<List<int>>();
  late final Future<void> _outDone;
  final _pending = BytesBuilder(copy: false);
  StreamSubscription<Uint8List>? _sub;
  Timer? _deadline;
  BridgeClient? _client;
  _Stage _stage;
  int _queued = 0;
  bool _refusing = false;
  bool _closed = false;

  /// Past the handshake: counted against the listener's connections, not
  /// its pending handshakes.
  bool get _verified => _client != null;

  @override
  BridgeClient get client => _client!;

  @override
  Stream<String> get lines => _lines.stream;

  /// The small handshake cap until the token has been accepted, including
  /// while it is being looked up: only an open connection may send big lines.
  int get _lineCap => _stage == _Stage.open
      ? _listener.maxLineBytes
      : _listener.maxHandshakeLineBytes;

  void _begin() {
    _deadline = Timer(_listener.handshakeTimeout, () {
      _refuse('The AI Bridge handshake timed out.');
    });
    _sub = _socket.listen(
      _onBytes,
      onError: (Object _) => close(),
      onDone: () {
        // The peer half-closed: whatever it already sent has been split
        // into lines; a trailing line without a newline is still a line.
        if (_pending.length > 0 && !_closed && !_refusing) {
          _onLine(_pending.takeBytes());
        }
        if (_client == null) {
          if (!_refusing) close();
        } else {
          unawaited(_lines.close());
        }
      },
    );
  }

  void _onBytes(Uint8List chunk) {
    if (_closed || _refusing) return;
    var start = 0;
    while (true) {
      final newline = chunk.indexOf(0x0a, start);
      if (newline < 0) break;
      _pending.add(Uint8List.sublistView(chunk, start, newline));
      if (_pending.length > _lineCap) {
        _drop();
        return;
      }
      _onLine(_pending.takeBytes());
      if (_closed || _refusing) return;
      start = newline + 1;
    }
    if (start < chunk.length) {
      _pending.add(Uint8List.sublistView(chunk, start));
      if (_pending.length > _lineCap) _drop();
    }
  }

  void _onLine(Uint8List bytes) {
    String line;
    try {
      line = utf8.decode(bytes);
    } on FormatException {
      _drop();
      return;
    }
    if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
    switch (_stage) {
      case _Stage.hello:
        final answer = _listener._answerHello(line);
        if (answer is _Refusal) {
          _refuse(answer.message);
        } else {
          _stage = _Stage.token;
          send(jsonEncode({'proof': answer}));
        }
      case _Stage.token:
        _stage = _Stage.verifying;
        _handshake(line);
      case _Stage.verifying:
      case _Stage.open:
        // Lines that arrive while the token is still being verified wait
        // in the controller; they are only seen once the connection is
        // handed out, and are discarded with it on a refusal.
        _lines.add(line);
    }
  }

  Future<void> _handshake(String line) async {
    Object verdict;
    try {
      verdict = await _listener._check(line);
    } catch (_) {
      // The client store failed (disk error, say). Refuse without its text,
      // rather than leave an unhandled error in the app's zone.
      verdict = const _Refusal(
        'The AI Bridge could not check this assistant. Try again.',
      );
    }
    if (_closed || _refusing) return;
    if (verdict is! BridgeClient) {
      _refuse((verdict as _Refusal).message);
      return;
    }
    _deadline?.cancel();
    _client = verdict;
    _stage = _Stage.open;
    send(jsonEncode({'ok': true}));
    final out = _listener._connections;
    if (!out.hasListener || out.isClosed) {
      await close();
      return;
    }
    out.add(this);
  }

  /// Refuses after [BridgeListener.failedHandshakeDelay]. Input is ignored
  /// meanwhile; the connection still counts as a pending handshake, so a
  /// peer cannot open more while it waits.
  Future<void> _refuse(String message) async {
    if (_closed || _refusing) return;
    _refusing = true;
    _deadline?.cancel();
    await Future<void>.delayed(_listener.failedHandshakeDelay);
    if (_closed) return;
    _refusing = false;
    send(jsonEncode({'ok': false, 'error': message}));
    await close();
  }

  /// A line past the cap, not UTF-8, or a peer not reading its replies: no
  /// reply, since there is nobody sensible to reply to, just gone.
  void _drop() {
    if (_closed) return;
    _closed = true;
    _deadline?.cancel();
    _sub?.cancel();
    _socket.destroy();
    unawaited(_out.close());
    unawaited(_lines.close());
    _listener._forget(this);
  }

  @override
  void send(String line) {
    if (line.contains('\n')) {
      throw ArgumentError.value(line, 'line', 'must not contain a newline');
    }
    if (_closed) return;
    final bytes = utf8.encode('$line\n');
    _queued += bytes.length;
    if (_queued > _listener.maxQueuedOutputBytes) {
      _drop();
      return;
    }
    _out.add(bytes);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _deadline?.cancel();
    _listener._forget(this);
    try {
      // One bound over both: draining waits forever on a peer that has
      // stopped reading, which would hang the listener's stop().
      await (() async {
        await _out.close();
        await _outDone;
        await _socket.close();
      })().timeout(const Duration(seconds: 2));
    } catch (_) {
      // Peer already gone, or not reading; destroyed below either way.
    }
    await _sub?.cancel();
    _socket.destroy();
    // Not awaited: a lines stream nobody listened to never reports done.
    unawaited(_lines.close());
  }
}
