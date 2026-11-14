import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../atomic_file.dart';

// The half of the AI Bridge's local channel that both ends share: where the
// app says it is listening (the locator file), the handshake's wire shape,
// and the launcher's side of it (dial, handshake, then pipe bytes).
//
// Kept free of Flutter and of everything that imports it — `app_data_paths`
// pulls in path_provider — because `bin/secureshellgo_mcp.dart` is compiled
// on its own with `dart compile exe`, and anything it imports must build
// without the Flutter engine.

/// The handshake version both ends speak. Bumped only for a change the other
/// end could not read; the listener refuses anything else by name, so an old
/// launcher against a new app says so instead of hanging.
const int bridgeHandshakeVersion = 1;

/// The longest line either end accepts. One MCP message is one line, and no
/// message this bridge exchanges comes near this; a peer sending more is
/// broken or hostile, and the connection is dropped rather than buffered.
const int bridgeMaxLineBytes = 1024 * 1024;

/// The locator file's name inside the bridge directory.
const String bridgeLocatorFileName = 'endpoint.json';

/// The bridge's own directory inside the app data directory. Holds the
/// socket (POSIX), the locator file and, from P3, the audit log.
String bridgeDirectoryFor(String appDataDir) =>
    '$appDataDir${Platform.pathSeparator}bridge';

/// Where the launcher looks for the bridge directory when it was not told.
///
/// This duplicates, on purpose, what `AppDataPaths.resolveDirectory` gets
/// from path_provider, because the launcher cannot import path_provider (see
/// the file comment). It must stay in step with path_provider's own rules:
///
///  - Linux: `$XDG_DATA_HOME/<app id>`, `~/.local/share` when unset or not
///    absolute; the app id is `APPLICATION_ID` in `linux/CMakeLists.txt`.
///  - Windows: `%APPDATA%\<CompanyName>\<ProductName>`, from the app's
///    `VERSIONINFO` (`windows/runner/Runner.rc`). The launcher is a second
///    exe with its own version info, so these are written down rather than
///    read from the running exe as path_provider does.
///  - macOS: `~/Library/Application Support/<bundle id>`.
///
/// `SSG_BRIDGE_DIR` overrides all of it, for an install that keeps its data
/// somewhere else and for tests. Returns null when the environment gives
/// nothing to build a path from.
String? defaultBridgeDirectory({
  required Map<String, String> environment,
  required bool isWindows,
  required bool isMacOS,
}) {
  final override = environment['SSG_BRIDGE_DIR'];
  if (override != null && override.isNotEmpty) return override;
  if (isWindows) {
    final appData = environment['APPDATA'];
    if (appData == null || appData.isEmpty) return null;
    return '$appData\\$windowsCompanyName\\$windowsProductName\\bridge';
  }
  final home = environment['HOME'];
  if (isMacOS) {
    if (home == null || home.isEmpty) return null;
    return '$home/Library/Application Support/$macosBundleId/bridge';
  }
  var dataHome = environment['XDG_DATA_HOME'];
  if (dataHome == null || !dataHome.startsWith('/')) {
    if (home == null || home.isEmpty) return null;
    dataHome = '$home/.local/share';
  }
  return '$dataHome/$linuxApplicationId/bridge';
}

/// `APPLICATION_ID` in `linux/CMakeLists.txt`.
const String linuxApplicationId = 'com.dhivalabs.secure_shell_go';

/// `CompanyName` and `ProductName` in `windows/runner/Runner.rc`.
const String windowsCompanyName = 'com.dhivalabs';
const String windowsProductName = 'SecureShell Go';

/// `AppDataPaths.macosBundleId`, repeated for the reason above.
const String macosBundleId = 'com.dhivalabs.secureShellGo';

/// Where the app is listening. Written by the app on start, read by the
/// launcher, removed on stop.
sealed class BridgeEndpoint {
  const BridgeEndpoint();

  Map<String, Object?> toJson();

  /// Null for anything that is not a well-formed endpoint: the file may be
  /// half-written by a crashed older build, or not ours at all.
  static BridgeEndpoint? fromJson(Object? json) {
    if (json is! Map) return null;
    switch (json['kind']) {
      case 'unix':
        final path = json['path'];
        if (path is String && path.isNotEmpty) return BridgeUnixEndpoint(path);
      case 'tcp':
        final port = json['port'];
        final secret = json['secret'];
        if (port is int &&
            port > 0 &&
            port < 65536 &&
            secret is String &&
            secret.isNotEmpty) {
          return BridgeTcpEndpoint(port, secret);
        }
    }
    return null;
  }
}

/// A unix-domain socket, on Linux and macOS. The socket's file mode is the
/// access control, so no secret travels with it.
class BridgeUnixEndpoint extends BridgeEndpoint {
  const BridgeUnixEndpoint(this.path);

  final String path;

  @override
  Map<String, Object?> toJson() => {'kind': 'unix', 'path': path};
}

/// A loopback TCP port, on Windows, where Dart has no unix sockets. Any
/// local process can connect to a port, so the per-launch [secret] — which
/// only someone who can read the locator file has — stands in for the file
/// mode a socket would have had.
class BridgeTcpEndpoint extends BridgeEndpoint {
  const BridgeTcpEndpoint(this.port, this.secret);

  final int port;
  final String secret;

  @override
  Map<String, Object?> toJson() => {
    'kind': 'tcp',
    'port': port,
    'secret': secret,
  };
}

/// The locator file, `<bridge dir>/endpoint.json`.
class BridgeLocator {
  BridgeLocator(this.bridgeDir);

  final String bridgeDir;

  File get file =>
      File('$bridgeDir${Platform.pathSeparator}$bridgeLocatorFileName');

  /// Null when there is no file or it does not hold an endpoint — both mean
  /// "the app is not listening" to the launcher.
  Future<BridgeEndpoint?> read() async {
    try {
      return BridgeEndpoint.fromJson(jsonDecode(await file.readAsString()));
    } on IOException {
      return null;
    } on FormatException {
      return null;
    }
  }

  /// Written atomically so the launcher never reads half a file, and
  /// owner-only before the contents go in: on Windows the tcp secret is
  /// the only thing between another local process and the bridge.
  /// (On Windows the file inherits the profile directory's ACL, which is
  /// already private to the user; there is no chmod to call there.)
  Future<void> write(BridgeEndpoint endpoint) async {
    await atomicWrite(file, (temp) async {
      await temp.writeAsString('');
      await restrictToOwner(temp.path, '600');
      await temp.writeAsString(jsonEncode(endpoint.toJson()), flush: true);
    });
  }

  Future<void> remove() async {
    try {
      await file.delete();
    } on IOException {
      // Already gone is what we wanted.
    }
  }
}

/// `chmod` [mode] on POSIX; nothing on Windows. `dart:io` has no chmod, so
/// this shells out, as `DeviceVaultKey` does, and fails loudly when it did
/// not take, because a world-readable socket or secret must not pass for a
/// private one.
Future<void> restrictToOwner(String path, String mode) async {
  if (Platform.isWindows) return;
  final result = await Process.run('chmod', <String>[mode, path]);
  if (result.exitCode != 0) {
    throw FileSystemException('Could not restrict access', path);
  }
}

/// The longest handshake line either end accepts. Handshake lines are a few
/// hundred bytes; the cap is small because they arrive before the peer has
/// proved anything, from any local process.
const int bridgeMaxHandshakeLineBytes = 4096;

/// The handshake line a launcher sends first on the unix kind, and the
/// second line (after the proof) on the tcp kind.
///
/// On the unix kind this is the whole handshake: the socket lives in a 0700
/// directory, so whoever answers on it is the app. On tcp the line carries
/// the [secret] too, and is only sent once the listener has proved it holds
/// that secret (see [bridgeHelloLine]).
String bridgeHandshakeLine({required String token, String? secret}) =>
    jsonEncode({
      'ssg_bridge': bridgeHandshakeVersion,
      'token': token,
      'secret': ?secret,
    });

/// The tcp kind's first line: a fresh nonce for the listener to prove it
/// knows the locator file's secret, before any token is sent.
///
/// A loopback port is not owned the way a socket file is. After a crash,
/// `endpoint.json` can name a port that another process now holds, and
/// sending the pairing token there would hand it over. So the launcher
/// speaks first with nothing worth stealing, and goes on only when the
/// answer is `HMAC-SHA256(secret, nonce)`.
String bridgeHelloLine(String nonce) =>
    jsonEncode({'ssg_bridge': bridgeHandshakeVersion, 'hello': nonce});

/// The proof a listener answers a hello with: lower-case hex
/// HMAC-SHA256, keyed with the UTF-8 of [secret], over the UTF-8 of
/// [nonce].
String bridgeProof(String secret, String nonce) =>
    Hmac(sha256, utf8.encode(secret)).convert(utf8.encode(nonce)).toString();

/// A fresh nonce: 32 bytes from [random], base64url without padding.
String bridgeNonce([Random? random]) {
  final r = random ?? Random.secure();
  return base64Url
      .encode(List<int>.generate(32, (_) => r.nextInt(256)))
      .replaceAll('=', '');
}

/// Compares two strings in time that depends only on their lengths, so a
/// peer cannot learn a secret or proof a byte at a time.
bool bridgeConstantTimeEquals(String a, String b) {
  final x = utf8.encode(a);
  final y = utf8.encode(b);
  var diff = x.length ^ y.length;
  for (var i = 0; i < x.length; i++) {
    diff |= x[i] ^ (i < y.length ? y[i] : 0);
  }
  return diff == 0;
}

/// A failed dial: nothing listening, or the app refused the handshake.
/// [message] is plain text for the user, shown by the launcher as is.
class BridgeDialException implements Exception {
  const BridgeDialException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// What the launcher says when there is nothing to talk to.
const String bridgeNotRunningMessage =
    'SecureShell Go is not running, or its AI Bridge is switched off.';

/// A reply that is not ours: something else holds the endpoint.
const String bridgeMalformedReplyMessage =
    'The AI Bridge sent a malformed reply.';

/// Connected, but no handshake reply within the timeout.
const String bridgeNoAnswerMessage = 'The AI Bridge did not answer in time.';

/// An open, handshaken channel to the app.
class BridgeLink {
  BridgeLink(this.socket, this.rest);

  /// Write side: MCP bytes to the app.
  final Socket socket;

  /// The socket's bytes from just after the handshake reply, including any
  /// that arrived in the same read as the reply.
  final Stream<Uint8List> rest;
}

/// Reads whole handshake lines off a socket by hand, then hands over every
/// byte after the last one read untouched.
///
/// Not a line splitter over the stream: after the handshake the stream
/// carries raw MCP bytes that are piped through as they are, so nothing past
/// the handshake may be decoded or re-framed.
class _HandshakeReader {
  _HandshakeReader(Socket socket) {
    _sub = socket.listen(
      (chunk) {
        if (_released) {
          _rest.add(chunk);
          return;
        }
        _buffer.add(chunk);
        _wake();
      },
      onError: (Object e) {
        if (_released) {
          _rest.addError(e);
        } else {
          _ended = true;
          _wake();
        }
      },
      onDone: () {
        _ended = true;
        if (_released) {
          _rest.close();
        } else {
          _wake();
        }
      },
    );
  }

  late final StreamSubscription<Uint8List> _sub;
  final _buffer = BytesBuilder();
  final _rest = StreamController<Uint8List>();
  Completer<void>? _waiting;
  bool _released = false;
  bool _ended = false;

  void _wake() {
    final w = _waiting;
    _waiting = null;
    w?.complete();
  }

  /// The next line, decoded as JSON; null for one that is not JSON.
  /// Throws [BridgeDialException]: not running when the peer hangs up, no
  /// answer on [timeout], malformed past the handshake line cap.
  Future<Object?> nextJson(Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      final bytes = _buffer.toBytes();
      final newline = bytes.indexOf(0x0a);
      if (newline >= 0) {
        _buffer
          ..clear()
          ..add(Uint8List.sublistView(bytes, newline + 1));
        try {
          return jsonDecode(
            utf8.decode(Uint8List.sublistView(bytes, 0, newline)),
          );
        } on FormatException {
          return null;
        }
      }
      if (bytes.length > bridgeMaxHandshakeLineBytes) {
        throw const BridgeDialException(bridgeMalformedReplyMessage);
      }
      if (_ended) throw const BridgeDialException(bridgeNotRunningMessage);
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) {
        throw const BridgeDialException(bridgeNoAnswerMessage);
      }
      final w = _waiting = Completer<void>();
      await w.future.timeout(left, onTimeout: () {});
    }
  }

  /// Everything after the last line read, then the rest of the socket.
  Stream<Uint8List> release() {
    _released = true;
    if (_buffer.isNotEmpty) _rest.add(_buffer.takeBytes());
    if (_ended) _rest.close();
    _rest
      ..onPause = _sub.pause
      ..onResume = _sub.resume
      ..onCancel = _sub.cancel;
    return _rest.stream;
  }

  Future<void> cancel() => _sub.cancel();
}

Future<Socket> _connect(BridgeEndpoint endpoint, Duration timeout) async {
  final Socket socket;
  try {
    socket = switch (endpoint) {
      BridgeUnixEndpoint(:final path) => await Socket.connect(
        InternetAddress(path, type: InternetAddressType.unix),
        0,
        timeout: timeout,
      ),
      BridgeTcpEndpoint(:final port) => await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: timeout,
      ),
    };
  } on SocketException {
    throw const BridgeDialException(bridgeNotRunningMessage);
  }
  // A write to a peer that has already hung up (a stale port answering and
  // closing, say) fails on `done`, which nobody awaits: left alone it is an
  // uncaught error that kills the launcher with a stack trace instead of
  // the readable "not running" reply. The read side reports the hang-up.
  unawaited(socket.done.then<void>((_) {}, onError: (Object _) {}));
  return socket;
}

void _sendLine(Socket socket, String line) {
  socket.add(utf8.encode(line));
  socket.add(const [0x0a]);
}

/// Sends a hello and checks the answer proves [secret]. False for any
/// answer that does not: the peer is not the app that wrote the locator.
Future<bool> _exchangeProof(
  Socket socket,
  _HandshakeReader reader,
  String secret,
  Duration timeout,
  Random? random,
) async {
  final nonce = bridgeNonce(random);
  _sendLine(socket, bridgeHelloLine(nonce));
  final Object? answer;
  try {
    answer = await reader.nextJson(timeout);
  } on BridgeDialException {
    return false;
  }
  final proof = answer is Map ? answer['proof'] : null;
  return proof is String &&
      bridgeConstantTimeEquals(proof, bridgeProof(secret, nonce));
}

/// Whether a listener that proves it holds [endpoint]'s secret answers on
/// its port. Sends no token. The listener's "is another window already
/// running the bridge" check for the tcp kind.
Future<bool> bridgeTcpPeerIsLive(
  BridgeTcpEndpoint endpoint, {
  Duration timeout = const Duration(seconds: 2),
  Random? random,
}) async {
  final Socket socket;
  try {
    socket = await _connect(endpoint, timeout);
  } on BridgeDialException {
    return false;
  }
  final reader = _HandshakeReader(socket);
  try {
    return await _exchangeProof(
      socket,
      reader,
      endpoint.secret,
      timeout,
      random,
    );
  } finally {
    await reader.cancel();
    socket.destroy();
  }
}

/// Connects to [endpoint] and performs the handshake with [token].
///
/// On tcp the listener must first prove it holds the locator's secret; a
/// peer that cannot is reported as not running and never sees the token.
///
/// Throws [BridgeDialException] with a message fit for the user: not
/// running when nothing (of ours) answers, the app's own reason when it
/// refuses.
Future<BridgeLink> dialBridge(
  BridgeEndpoint endpoint, {
  required String token,
  Duration timeout = const Duration(seconds: 5),
  Random? random,
}) async {
  final socket = await _connect(endpoint, timeout);
  final reader = _HandshakeReader(socket);
  try {
    switch (endpoint) {
      case BridgeTcpEndpoint(:final secret):
        if (!await _exchangeProof(socket, reader, secret, timeout, random)) {
          throw const BridgeDialException(bridgeNotRunningMessage);
        }
        _sendLine(socket, bridgeHandshakeLine(token: token, secret: secret));
      case BridgeUnixEndpoint():
        _sendLine(socket, bridgeHandshakeLine(token: token));
    }
    final reply = await reader.nextJson(timeout);
    if (reply is Map && reply['ok'] == true) {
      return BridgeLink(socket, reader.release());
    }
    final error = reply is Map ? reply['error'] : null;
    throw BridgeDialException(
      error is String && error.isNotEmpty ? error : bridgeMalformedReplyMessage,
    );
  } catch (_) {
    await reader.cancel();
    socket.destroy();
    rethrow;
  }
}

/// The JSON-RPC error code the launcher answers with when it has no app to
/// pass a request to (an implementation-defined server error).
const int bridgeUnavailableCode = -32000;

/// The launcher's whole job, with its streams injected so the end-to-end
/// test can drive it against a real listener without spawning a process.
///
/// Connected: stdin goes to the channel and the channel to stdout byte for
/// byte — the app speaks MCP, the launcher only carries it. Returns 0 when
/// the client closes stdin and the app has finished answering, 1 when the
/// app goes away first.
///
/// Not connected: every request on stdin is answered with
/// [bridgeUnavailableCode] and the reason, so the assistant shows the user
/// something readable instead of "server failed to start"; the reason goes
/// to stderr too; returns 1 once stdin closes.
Future<int> runBridgeLauncher({
  required Stream<List<int>> input,
  required IOSink output,
  required IOSink errors,
  required String? bridgeDir,
  required String? token,
  Duration timeout = const Duration(seconds: 5),
}) async {
  BridgeLink link;
  try {
    if (bridgeDir == null) {
      throw const BridgeDialException(bridgeNotRunningMessage);
    }
    if (token == null || token.isEmpty) {
      throw const BridgeDialException(
        'SSG_BRIDGE_TOKEN is not set. Connect this assistant again from '
        'SecureShell Go: Settings, AI Bridge.',
      );
    }
    final endpoint = await BridgeLocator(bridgeDir).read();
    if (endpoint == null) {
      throw const BridgeDialException(bridgeNotRunningMessage);
    }
    link = await dialBridge(endpoint, token: token, timeout: timeout);
  } on BridgeDialException catch (e) {
    errors.writeln(e.message);
    await _answerUnavailable(input, output, e.message);
    return 1;
  }

  final socket = link.socket;
  final toClient = link.rest
      .listen(output.add, onError: (Object _) {}, cancelOnError: false)
      .asFuture<void>();

  var clientClosed = false;
  unawaited(() async {
    try {
      await socket.addStream(input);
      clientClosed = true;
      // Half-close: the app sees end of input, answers anything still in
      // flight, then closes its side, which ends [toClient].
      await socket.close();
    } catch (_) {
      // The app went away mid-write; [toClient] ends with it.
    }
  }());

  // Either way the run ends when the app's side does: after the client's
  // end of input has been answered, or when the app quits underneath it.
  await toClient;
  await output.flush();
  if (!clientClosed) {
    errors.writeln('SecureShell Go closed the AI Bridge connection.');
    socket.destroy();
    return 1;
  }
  socket.destroy();
  return 0;
}

Future<void> _answerUnavailable(
  Stream<List<int>> input,
  IOSink output,
  String message,
) async {
  Map<String, Object?> errorFor(Object? id) => {
    'jsonrpc': '2.0',
    'id': id,
    'error': {'code': bridgeUnavailableCode, 'message': message},
  };

  await for (final line
      in input.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.trim().isEmpty) continue;
    Object? message;
    try {
      message = jsonDecode(line);
    } on FormatException {
      output.writeln(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': null,
          'error': {'code': -32700, 'message': 'Parse error'},
        }),
      );
      continue;
    }
    final batch = message is List ? message : [message];
    final replies = [
      for (final m in batch)
        // A notification (no id) gets no reply, as anywhere in JSON-RPC.
        if (m is Map && m.containsKey('id') && m['method'] is String)
          errorFor(m['id']),
    ];
    if (replies.isEmpty) continue;
    output.writeln(jsonEncode(message is List ? replies : replies.single));
    await output.flush();
  }
}
