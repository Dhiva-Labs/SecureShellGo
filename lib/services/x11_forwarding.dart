import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart' show SSHSocket, SSHX11Config;

import 'tunnel_carrier.dart';

/// X11 forwarding: graphical programs started in the shell open their
/// windows on this device's X server.
///
/// How it works, the way `ssh -X` does it:
///
/// 1. The shell channel asks for `x11-req` with a *fake* cookie — random
///    bytes made up for this connection. The server sets `DISPLAY` for the
///    shell and writes the fake cookie into the user's `.Xauthority` there.
/// 2. An X program on the server connects to that display; sshd opens an
///    `x11` channel back to this app for each connection.
/// 3. The first thing an X client sends is its connection setup, which
///    carries the cookie it found. [rewriteX11Setup] checks it is the fake
///    one and swaps in a cookie the local X server takes (see below).
/// 4. From there the bytes are only piped, both ways, by the same
///    [TunnelConnection] port forwards use.
///
/// Which cookie the local X server is shown decides what the server's
/// programs may do on this display:
///
///  * **Untrusted, as `ssh -X` does.** Where the X server can say so, each
///    forwarded connection gets a cookie of its own from
///    `xauth generate … untrusted` (see [generateUntrustedXauthCookie]). The
///    X server's SECURITY extension then keeps that client to its own
///    windows: it cannot read other windows, watch the keyboard, or send
///    input to them.
///  * **Trusted, as `ssh -Y` does,** where that cannot be had: on Windows,
///    whose X servers (VcXsrv, Xming, X410) have no untrusted mode, and
///    wherever `xauth` is missing or the X server lacks the SECURITY
///    extension (some Xwayland builds). The display's own cookie, read from
///    the local Xauthority — or none, for an X server that does not ask —
///    is presented, and programs on the server can see and control every
///    window on this display while the session is up. The host form says
///    so on Windows; elsewhere [prepare] returns a line saying so, shown at
///    the top of the shell.
///
/// Either way the server only ever holds the fake cookie, and a connection
/// that does not present it is closed before anything is sent to the local
/// X server.
class X11Forwarder {
  X11Forwarder({
    required this.display,
    Uint8List? fakeCookie,
    Future<Socket> Function()? connect,
    Future<XauthEntry?> Function()? realCookie,
    Future<XauthEntry> Function()? untrustedCookie,
    this.setupTimeout = const Duration(seconds: 30),
  })  : fakeCookie = fakeCookie ?? _randomCookie(),
        _connect = connect ?? (() => connectToX11Display(display)),
        _realCookie = realCookie ?? (() => loadXauthCookie(display)),
        _untrustedCookie =
            untrustedCookie ?? (() => generateUntrustedXauthCookie(display));

  /// The display windows are drawn on.
  final X11Display display;

  /// The made-up cookie the server is given. Sixteen random bytes, the
  /// length of a real MIT-MAGIC-COOKIE-1.
  final Uint8List fakeCookie;

  final Future<Socket> Function() _connect;

  /// The display's own cookie: trusted access.
  final Future<XauthEntry?> Function() _realCookie;

  /// A new untrusted cookie, or [X11UntrustedUnavailable].
  final Future<XauthEntry> Function() _untrustedCookie;

  /// How long an X client on the server gets to send its connection setup.
  final Duration setupTimeout;

  final Set<TunnelConnection> _live = {};

  Future<String?>? _prepared;
  bool? _trusted;

  /// Whether forwarded connections get the display's own cookie (`ssh -Y`)
  /// rather than an untrusted one (`ssh -X`). Null until [prepare] has run.
  bool? get trusted => _trusted;

  /// Why the last forwarded connection did not reach the X server, for
  /// diagnostics. Null while every one has.
  String? lastProblem;

  final StreamController<String> _problems =
      StreamController<String>.broadcast();
  String? _lastReported;
  DateTime? _lastReportedAt;

  /// Each [lastProblem] as it happens, for the terminal to show — the way
  /// `ssh` writes "X11 connection rejected because of wrong authentication"
  /// into it. The same problem again within a few seconds is not repeated:
  /// one program opening three connections to a display that is not there
  /// is one line, not three.
  Stream<String> get problems => _problems.stream;

  void _report(String problem) {
    lastProblem = problem;
    final now = DateTime.now();
    final last = _lastReportedAt;
    if (problem == _lastReported &&
        last != null &&
        now.difference(last) < const Duration(seconds: 10)) {
      return;
    }
    _lastReported = problem;
    _lastReportedAt = now;
    if (!_problems.isClosed) _problems.add(problem);
  }

  /// Decides, once, whether connections are let in trusted or untrusted,
  /// by trying to make an untrusted cookie. Returns what the person should
  /// be told about it, or null.
  ///
  /// Called as the shell opens, so a display that can only be forwarded
  /// trusted is said so before any program uses it; [handle] calls it too,
  /// for a forwarder used without a shell.
  Future<String?> prepare() => _prepared ??= _decide();

  Future<String?> _decide() async {
    String? why;
    try {
      // Only a probe: each connection gets a cookie of its own, and this
      // one lapses unused after its timeout.
      await _untrustedCookie();
      _trusted = false;
      return null;
    } on X11UntrustedUnavailable catch (e) {
      why = e.reason;
    } catch (e) {
      // A scratch folder that could not be made, say. Never the shell's
      // problem.
      why = '$e';
    }
    _trusted = true;
    if (why == null) return null;
    return 'X11: this display cannot give the server limited access '
        '($why), so programs there get full access instead, as with '
        'ssh -Y: they can see and control every window on this display.';
  }

  bool _requested = false;

  /// Whether [config] has been read: some channel has been, or is about to
  /// be, given the fake cookie. Until then no `x11` channel the server opens
  /// can be one this device asked for.
  bool get requested => _requested;

  /// The `x11-req` for a channel: the shell's, or one app's.
  SSHX11Config get config {
    _requested = true;
    return SSHX11Config(
      authenticationCookie: _hex(fakeCookie),
      screenNumber: display.screen,
    );
  }

  /// Whether this platform can have a local X server to forward to: the
  /// desktop ones. Android has no X server to draw on.
  static bool get isSupportedPlatform =>
      Platform.isLinux || Platform.isWindows || Platform.isMacOS;

  /// Forwards one `x11` channel the server opened, until either side ends.
  Future<void> handle(SSHSocket channel) async {
    final input = StreamIterator(channel.stream);
    try {
      await prepare();
      final setup = await _readSetup(input).timeout(setupTimeout);
      final Socket local;
      try {
        local = await _connect();
      } catch (e) {
        _report('Could not reach the X server at ${display.describe()} '
            'for a program on the server ($e). Is an X server running '
            'here?');
        _destroy(channel);
        await input.cancel();
        return;
      }
      local.add(setup.rewritten);

      final connection = TunnelConnection(
        local: SocketTunnelEndpoint(local),
        remote: _ResumedChannelEndpoint(
          channel,
          _remainder(setup.leftover, input),
        ),
      );
      _live.add(connection);
      await connection.pump(onUp: (_) {}, onDown: (_) {});
      _live.remove(connection);
    } on X11SetupRejected catch (e) {
      _report(e.message);
      _destroy(channel);
      await input.cancel();
    } on X11UntrustedUnavailable catch (e) {
      // Untrusted access worked when the shell opened and not now. Not
      // quietly upgraded to trusted: the person was not told about that.
      _report('Could not make a limited-access X11 cookie for a program '
          'on the server (${e.reason ?? 'xauth failed'}), so it was not '
          'let in.');
      _destroy(channel);
      await input.cancel();
    } on TimeoutException {
      _report('An X11 program on the server did not start its connection '
          'in time.');
      _destroy(channel);
      await input.cancel();
    } catch (e) {
      _report('An X11 connection failed ($e).');
      _destroy(channel);
      await input.cancel();
    }
  }

  /// Ends every forwarded connection; the session they belong to is over.
  void closeAll() {
    for (final connection in _live.toList()) {
      connection.destroy();
    }
    _live.clear();
    unawaited(_problems.close());
  }

  /// Reads the client's setup, checks it presents the fake cookie, and only
  /// then fetches the cookie for the local X server — so a connection that
  /// is not ours costs no `xauth` run.
  Future<X11SetupRewrite> _readSetup(StreamIterator<Uint8List> input) async {
    final head = BytesBuilder(copy: false);
    while (rewriteX11Setup(
          head.toBytes(),
          fakeCookie: fakeCookie,
          localCookie: null,
        ) ==
        null) {
      if (!await input.moveNext()) {
        throw const X11SetupRejected(
          'The X11 client on the server hung up before connecting.',
        );
      }
      head.add(input.current);
    }
    final cookie =
        _trusted == false ? await _untrustedCookie() : await _realCookie();
    return rewriteX11Setup(
      head.toBytes(),
      fakeCookie: fakeCookie,
      localCookie: cookie,
    )!;
  }

  static Stream<Uint8List> _remainder(
    Uint8List leftover,
    StreamIterator<Uint8List> input,
  ) async* {
    try {
      if (leftover.isNotEmpty) yield leftover;
      while (await input.moveNext()) {
        yield input.current;
      }
    } finally {
      await input.cancel();
    }
  }

  static void _destroy(SSHSocket channel) {
    try {
      channel.destroy();
    } catch (_) {
      // Already gone.
    }
  }

  static Uint8List _randomCookie() {
    final random = Random.secure();
    return Uint8List.fromList(List.generate(16, (_) => random.nextInt(256)));
  }

  static String _hex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// A forwarded `x11` channel whose first bytes have already been read: the
/// rest is [input], replayed from where the setup ended.
class _ResumedChannelEndpoint extends ChannelTunnelEndpoint {
  _ResumedChannelEndpoint(super.channel, this.input);

  @override
  final Stream<Uint8List> input;
}

/// An X client's connection setup that did not present the fake cookie, or
/// was not an X11 connection at all.
class X11SetupRejected implements Exception {
  const X11SetupRejected(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The setup message to send to the local X server instead of the one the
/// client sent, and whatever the client sent after it.
class X11SetupRewrite {
  const X11SetupRewrite({required this.rewritten, required this.leftover});

  final Uint8List rewritten;
  final Uint8List leftover;
}

/// An untrusted cookie could not be made for this display. [reason] says
/// why, for the person, or is null where there is no untrusted mode to
/// begin with (Windows) and so nothing to explain beyond what the host form
/// already says.
class X11UntrustedUnavailable implements Exception {
  const X11UntrustedUnavailable(this.reason);

  final String? reason;

  @override
  String toString() => reason ?? 'No untrusted X11 access on this platform.';
}

/// The authorization protocol the fake and the local cookie both use.
const String x11CookieProtocol = 'MIT-MAGIC-COOKIE-1';

/// Rewrites the X11 connection setup at the front of [head]: checks it
/// presents [fakeCookie] and replaces it with [localCookie] — an untrusted
/// one made for this connection, or the display's own — or with no
/// authorization at all when there is none.
///
/// Returns null while [head] is still too short to hold the whole setup.
/// Throws [X11SetupRejected] for anything that is not an X11 setup carrying
/// exactly the fake cookie — OpenSSH's "X11 connection rejected because of
/// wrong authentication".
///
/// The setup, from the X11 protocol's "Connection Setup":
///
/// ```text
/// 1  byte order: 'B' (MSB first) or 'l' (LSB first)
/// 1  unused
/// 2  protocol major version     } in that byte order
/// 2  protocol minor version     }
/// 2  n, length of auth name     }
/// 2  d, length of auth data     }
/// 2  unused
/// n  auth name, padded to 4
/// d  auth data, padded to 4
/// ```
X11SetupRewrite? rewriteX11Setup(
  Uint8List head, {
  required Uint8List fakeCookie,
  required XauthEntry? localCookie,
}) {
  if (head.isEmpty) return null;
  final order = head[0];
  if (order != 0x42 && order != 0x6c) {
    throw const X11SetupRejected(
      'Something other than an X11 client connected to the forwarded '
      'display.',
    );
  }
  if (head.length < 12) return null;

  final endian = order == 0x42 ? Endian.big : Endian.little;
  final header = ByteData.sublistView(head, 0, 12);
  final nameLength = header.getUint16(6, endian);
  final dataLength = header.getUint16(8, endian);
  // Real names and cookies are a few dozen bytes; a client claiming more is
  // not one, and must not make this buffer.
  if (nameLength > 256 || dataLength > 256) {
    throw const X11SetupRejected(
      'X11 connection rejected: its authorization data is malformed.',
    );
  }
  final nameEnd = 12 + nameLength;
  final dataStart = nameEnd + _pad(nameLength);
  final total = dataStart + dataLength + _pad(dataLength);
  if (head.length < total) return null;

  final name = String.fromCharCodes(head.sublist(12, nameEnd));
  final data = head.sublist(dataStart, dataStart + dataLength);
  if (name != x11CookieProtocol || !_constantTimeEquals(data, fakeCookie)) {
    throw const X11SetupRejected(
      'X11 connection rejected because of wrong authentication.',
    );
  }

  final realName = localCookie == null
      ? const <int>[]
      : localCookie.name.codeUnits;
  final realData = localCookie?.data ?? Uint8List(0);
  final out = BytesBuilder(copy: false)..add(head.sublist(0, 6));
  final lengths = ByteData(6)
    ..setUint16(0, realName.length, endian)
    ..setUint16(2, realData.length, endian);
  out
    ..add(lengths.buffer.asUint8List())
    ..add(realName)
    ..add(Uint8List(_pad(realName.length)))
    ..add(realData)
    ..add(Uint8List(_pad(realData.length)));

  return X11SetupRewrite(
    rewritten: out.takeBytes(),
    leftover: Uint8List.fromList(head.sublist(total)),
  );
}

int _pad(int length) => (4 - length % 4) % 4;

bool _constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var difference = 0;
  for (var i = 0; i < a.length; i++) {
    difference |= a[i] ^ b[i];
  }
  return difference == 0;
}

/// Where an X server is, as `DISPLAY` names it.
class X11Display {
  const X11Display({
    this.host,
    required this.number,
    this.screen = 0,
    this.socketPath,
  });

  /// Null for the local Unix socket (`:0`, `unix:0`); otherwise reached
  /// over TCP at port 6000 + [number].
  final String? host;

  final int number;
  final int screen;

  /// A socket named outright, as XQuartz's `DISPLAY` does
  /// (`/private/tmp/com.apple.launchd.…/org.xquartz:0`).
  final String? socketPath;

  /// Reads `DISPLAY`. Null when it is not something this can connect to.
  static X11Display? parse(String value) {
    final text = value.trim();
    final colon = text.lastIndexOf(':');
    if (colon < 0) return null;
    final hostPart = text.substring(0, colon);
    final rest = text.substring(colon + 1);
    final dot = rest.indexOf('.');
    final number = int.tryParse(dot < 0 ? rest : rest.substring(0, dot));
    final screen = dot < 0 ? 0 : int.tryParse(rest.substring(dot + 1));
    if (number == null || number < 0 || screen == null || screen < 0) {
      return null;
    }
    if (hostPart.startsWith('/')) {
      return X11Display(number: number, screen: screen, socketPath: hostPart);
    }
    if (hostPart.isEmpty || hostPart == 'unix') {
      return X11Display(number: number, screen: screen);
    }
    final host = hostPart.startsWith('[') && hostPart.endsWith(']')
        ? hostPart.substring(1, hostPart.length - 1)
        : hostPart;
    return X11Display(host: host, number: number, screen: screen);
  }

  /// This device's display: `DISPLAY` when it is set, or on Windows the
  /// first display of an X server on this machine — what VcXsrv, Xming and
  /// X410 listen on unless told otherwise. Null where there is none to
  /// forward to.
  static X11Display? fromEnvironment([Map<String, String>? environment]) {
    final env = environment ?? Platform.environment;
    final value = env['DISPLAY'];
    if (value != null && value.trim().isNotEmpty) return parse(value);
    if (Platform.isWindows) return const X11Display(host: 'localhost', number: 0);
    return null;
  }

  /// Whether this is a display on this device rather than another machine.
  bool get isLocal =>
      host == null ||
      host == 'localhost' ||
      host == '127.0.0.1' ||
      host == '::1';

  String describe() {
    if (socketPath != null) return '$socketPath:$number';
    final h = host;
    final where = h == null ? '' : (h.contains(':') ? '[$h]' : h);
    return '$where:$number${screen == 0 ? '' : '.$screen'}';
  }
}

/// Opens a connection to [display]'s X server.
///
/// A local display is tried as the Unix socket `/tmp/.X11-unix/X<n>` (and
/// its abstract-namespace twin, which some X servers on Linux listen on
/// alone), then as TCP 6000 + n on loopback. Windows has no Unix-socket X
/// servers, so there it is TCP only.
Future<Socket> connectToX11Display(X11Display display) async {
  const timeout = Duration(seconds: 5);
  final explicit = display.socketPath;
  if (explicit != null) {
    return Socket.connect(
      InternetAddress(explicit, type: InternetAddressType.unix),
      0,
      timeout: timeout,
    );
  }
  final host = display.host;
  if (host == null && !Platform.isWindows) {
    final path = '/tmp/.X11-unix/X${display.number}';
    for (final candidate in [path, if (Platform.isLinux) '@$path']) {
      try {
        return await Socket.connect(
          InternetAddress(candidate, type: InternetAddressType.unix),
          0,
          timeout: timeout,
        );
      } on SocketException {
        // Try the next.
      }
    }
  }
  return Socket.connect(
    host ?? InternetAddress.loopbackIPv4,
    6000 + display.number,
    timeout: timeout,
  );
}

/// One record of an Xauthority file.
class XauthEntry {
  const XauthEntry({
    required this.family,
    required this.address,
    required this.number,
    required this.name,
    required this.data,
  });

  static const int familyInternet = 0;
  static const int familyInternet6 = 6;
  static const int familyLocal = 256;
  static const int familyWild = 65535;

  final int family;
  final Uint8List address;

  /// The display number as text; empty matches every display.
  final String number;

  final String name;
  final Uint8List data;
}

/// Reads an Xauthority file: records of a big-endian `family` and four
/// length-prefixed fields (address, display number, auth name, auth data).
/// A damaged tail ends the list rather than failing it.
List<XauthEntry> parseXauthority(Uint8List bytes) {
  final entries = <XauthEntry>[];
  var offset = 0;
  Uint8List? field() {
    if (offset + 2 > bytes.length) return null;
    final length = (bytes[offset] << 8) | bytes[offset + 1];
    offset += 2;
    if (offset + length > bytes.length) return null;
    final value = Uint8List.sublistView(bytes, offset, offset + length);
    offset += length;
    return value;
  }

  while (offset + 2 <= bytes.length) {
    final family = (bytes[offset] << 8) | bytes[offset + 1];
    offset += 2;
    final address = field();
    final number = field();
    final name = field();
    final data = field();
    if (address == null || number == null || name == null || data == null) {
      break;
    }
    entries.add(XauthEntry(
      family: family,
      address: Uint8List.fromList(address),
      number: String.fromCharCodes(number),
      name: String.fromCharCodes(name),
      data: Uint8List.fromList(data),
    ));
  }
  return entries;
}

/// The cookie for [display] among [entries], the way Xlib picks one: the
/// first MIT-MAGIC-COOKIE-1 record for that display number (or for every
/// display) whose address is this machine — by name for the local socket,
/// or any address under the wildcard family.
XauthEntry? pickXauthCookie(
  List<XauthEntry> entries,
  X11Display display, {
  required String localHostname,
}) {
  bool numberMatches(XauthEntry e) =>
      e.number.isEmpty || e.number == '${display.number}';
  bool addressMatches(XauthEntry e) {
    switch (e.family) {
      case XauthEntry.familyWild:
        return true;
      case XauthEntry.familyLocal:
        return display.isLocal &&
            String.fromCharCodes(e.address).toLowerCase() ==
                localHostname.toLowerCase();
      case XauthEntry.familyInternet:
      case XauthEntry.familyInternet6:
        final host = display.host;
        if (host == null) return false;
        final literal = InternetAddress.tryParse(
          host == 'localhost' ? '127.0.0.1' : host,
        );
        return literal != null && _sameBytes(literal.rawAddress, e.address);
      default:
        return false;
    }
  }

  for (final entry in entries) {
    if (entry.name == x11CookieProtocol &&
        numberMatches(entry) &&
        addressMatches(entry)) {
      return entry;
    }
  }
  return null;
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// The real cookie for [display] from this device's Xauthority
/// (`XAUTHORITY`, or `.Xauthority` in the home directory), or null when
/// there is no file or no matching record — an X server that wants no
/// cookie then gets none.
Future<XauthEntry?> loadXauthCookie(
  X11Display display, {
  Map<String, String>? environment,
}) async {
  final env = environment ?? Platform.environment;
  final home = env['HOME'] ?? env['USERPROFILE'];
  final path = env['XAUTHORITY'] ??
      (home == null ? null : '$home${Platform.pathSeparator}.Xauthority');
  if (path == null) return null;
  try {
    final file = File(path);
    if (!await file.exists()) return null;
    return pickXauthCookie(
      parseXauthority(await file.readAsBytes()),
      display,
      localHostname: Platform.localHostname,
    );
  } on FileSystemException {
    return null;
  }
}

/// How long an untrusted cookie lives on with no client using it. Each
/// forwarded connection gets its own a moment before connecting, and the X
/// server keeps it while that client is connected, so this only needs to
/// cover the gap — and it is what OpenSSH's `xauth` default is.
const Duration untrustedCookieTimeout = Duration(seconds: 60);

/// Where `xauth` may be: on the PATH, and where Linux distributions and
/// XQuartz put it, for an app started without a login shell's PATH.
const List<String> xauthExecutables = [
  'xauth',
  '/usr/bin/xauth',
  '/usr/X11R6/bin/xauth',
  '/opt/X11/bin/xauth',
];

/// A new untrusted cookie for [display], the way `ssh -X` gets one, read
/// back from a scratch file:
///
/// ```text
/// xauth -f SCRATCH generate DISPLAY MIT-MAGIC-COOKIE-1 untrusted timeout N
/// ```
///
/// The X server makes the cookie through its SECURITY extension and marks
/// whoever presents it as untrusted. The scratch file is in a new private
/// folder, deleted before this returns, so the user's own Xauthority is
/// never touched.
///
/// Throws [X11UntrustedUnavailable] when it cannot be had: always on
/// Windows, and elsewhere when `xauth` is not installed, the X server does
/// not answer, or it has no SECURITY extension. [executables] are tried in
/// order until one runs; tests point it at a stand-in.
Future<XauthEntry> generateUntrustedXauthCookie(
  X11Display display, {
  Duration timeout = untrustedCookieTimeout,
  List<String> executables = xauthExecutables,
}) async {
  if (Platform.isWindows) throw const X11UntrustedUnavailable(null);
  final dir = await Directory.systemTemp.createTemp('ssgo-xauth-');
  try {
    final path = '${dir.path}${Platform.pathSeparator}xauthority';
    final arguments = [
      '-f',
      path,
      'generate',
      display.describe(),
      x11CookieProtocol,
      'untrusted',
      'timeout',
      '${timeout.inSeconds}',
    ];
    final (exitCode, stderr) = await _runXauth(executables, arguments);
    if (exitCode != 0) {
      throw X11UntrustedUnavailable(_xauthComplaint(stderr) ??
          'xauth could not make one, exit code $exitCode');
    }
    final file = File(path);
    if (await file.exists()) {
      for (final entry in parseXauthority(await file.readAsBytes())) {
        if (entry.name == x11CookieProtocol && entry.data.isNotEmpty) {
          return entry;
        }
      }
    }
    throw const X11UntrustedUnavailable('xauth made no cookie');
  } finally {
    try {
      await dir.delete(recursive: true);
    } catch (_) {
      // Already gone.
    }
  }
}

/// Runs the first of [executables] that exists with [arguments]: its exit
/// code and what it wrote to stderr.
Future<(int, String)> _runXauth(
  List<String> executables,
  List<String> arguments,
) async {
  for (final executable in executables) {
    final Process process;
    try {
      process = await Process.start(executable, arguments);
    } on ProcessException {
      continue;
    }
    final stderr = process.stderr
        .transform(const SystemEncoding().decoder)
        .join();
    unawaited(process.stdout.drain<void>());
    final int? exitCode = await process.exitCode
        .then<int?>((code) => code)
        .timeout(const Duration(seconds: 10), onTimeout: () {
      process.kill();
      return null;
    });
    if (exitCode == null) {
      throw const X11UntrustedUnavailable('xauth did not finish; the X '
          'server may not be answering');
    }
    return (exitCode, await stderr);
  }
  throw const X11UntrustedUnavailable('xauth is not installed');
}

/// The line of `xauth`'s stderr that says what went wrong, without its
/// `xauth: (argv):1:` prefix, or null. The notice that the scratch file
/// does not exist yet is not a complaint.
String? _xauthComplaint(String stderr) {
  for (final raw in stderr.split('\n').reversed) {
    var line = raw.trim();
    if (line.isEmpty || line.contains('does not exist')) continue;
    line = line.replaceFirst(RegExp(r'^xauth:\s*(\(argv\):\d+:\s*)?'), '');
    return 'xauth: ${line.trim()}';
  }
  return null;
}
