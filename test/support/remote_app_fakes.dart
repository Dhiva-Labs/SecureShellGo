import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/services/device_storage.dart';
import 'package:secure_shell_go/services/session_controller.dart';
import 'package:secure_shell_go/services/ssh_service.dart';
import 'package:secure_shell_go/services/x11_forwarding.dart';

import '../fake_exec_session.dart';
import 'certificate_fixture.dart';
import 'fake_transport.dart';
import 'link_transport.dart';

/// What the "Open an app in a window" suites stand on: a transport that has
/// (or has not) an X11 forwarder, a program on the server that a test
/// drives by hand, and a session over the two.

class RemoteAppUnusedStorage implements DeviceStorage {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('storage is not exercised in these tests');
}

/// A host whose X11 switch is [x11], optionally signing in with a
/// certificate that lacks `permit-X11-forwarding`.
Host remoteAppHost({bool x11 = true, bool certificateWithoutX11 = false}) {
  String? certificate;
  if (certificateWithoutX11) {
    final key = BytesBuilder();
    for (final part in [utf8.encode('ssh-ed25519'), List.filled(32, 9)]) {
      key
        ..add((ByteData(4)..setUint32(0, part.length)).buffer.asUint8List())
        ..add(part);
    }
    certificate = certificateLineFor(
      key.toBytes(),
      extensions: const ['permit-pty'],
    );
  }
  return Host(
    id: 'h1',
    label: 'Test box',
    hostname: 'example.test',
    port: 22,
    username: 'dev',
    authMethod: SshAuthMethod.password,
    x11Forwarding: x11,
    certificate: certificate,
  );
}

/// The fake cookie every forwarder here is made with.
final Uint8List remoteAppFakeCookie =
    Uint8List.fromList(List.generate(16, (i) => i + 1));

/// An [X11Forwarder] that never touches a real X server: its display is
/// `:0`, its cookies are made up, and [untrusted] says whether the display
/// can limit access.
X11Forwarder remoteAppForwarder({bool untrusted = true}) => X11Forwarder(
      display: const X11Display(number: 0),
      fakeCookie: remoteAppFakeCookie,
      connect: () => throw StateError('no X server in this test'),
      realCookie: () async => null,
      untrustedCookie: () async {
        if (!untrusted) throw const X11UntrustedUnavailable('no SECURITY');
        return XauthEntry(
          family: XauthEntry.familyLocal,
          address: Uint8List(0),
          number: '0',
          name: x11CookieProtocol,
          data: Uint8List.fromList(List.filled(16, 9)),
        );
      },
    );

/// A connection with or without X11 forwarding. Its plain `execute` (what
/// `kill` goes through) records the command and answers with an empty
/// session.
class FakeX11Transport extends FakeTransportBase {
  FakeX11Transport({Host? host, this.forwarder})
      : super(host: host ?? remoteAppHost());

  final X11Forwarder? forwarder;

  /// Every command run through [execute], in order.
  final List<String> commands = [];

  @override
  X11Forwarder? get x11Forwarder => forwarder;

  @override
  Future<SSHSession> execute(String command) async {
    commands.add(command);
    return FakeExecSession(exitCode: 0, exits: true);
  }
}

/// A program on the server, as the exec channel carries it: the test pushes
/// its output and decides when and how it ends.
class ScriptedApp extends FakeExecSession {
  ScriptedApp() : super(exits: false);

  final StreamController<Uint8List> _out = StreamController<Uint8List>();
  final StreamController<Uint8List> _err = StreamController<Uint8List>();
  final Completer<void> _closed = Completer<void>();
  int? _code;
  SSHSessionExitSignal? _signal;

  @override
  Stream<Uint8List> get stdout => _out.stream;

  @override
  Stream<Uint8List> get stderr => _err.stream;

  @override
  int? get exitCode => _code;

  @override
  SSHSessionExitSignal? get exitSignal => _signal;

  @override
  Future<void> get done => _closed.future;

  void say(String text) => _out.add(Uint8List.fromList(utf8.encode(text)));

  void complain(List<int> bytes) => _err.add(Uint8List.fromList(bytes));

  /// The program ends: with [code], or by [signal], or (neither) the channel
  /// just closes.
  void end({int? code, String? signal}) {
    _code = code;
    if (signal != null) {
      _signal = SSHSessionExitSignal(
        signalName: signal,
        coreDumped: false,
        errorMessage: '',
        languageTag: '',
      );
    }
    // Not awaited: a controller with no listener only finishes closing once
    // someone listens.
    unawaited(_out.close());
    unawaited(_err.close());
    if (!_closed.isCompleted) _closed.complete();
  }

  @override
  void close() {
    super.close();
    end();
  }
}

/// A session over [transport] that does not start any timers of its own.
SessionController remoteAppSession(SessionTransport transport) =>
    SessionController(
      connection: transport,
      storage: RemoteAppUnusedStorage(),
      keepaliveScheduler: (_, tick) => CrankTimer(tick),
    );

/// The server's side of a forwarded `x11` channel: a stream the test feeds
/// bytes into.
class FakeX11Channel implements SSHSocket {
  final incoming = StreamController<Uint8List>();
  final _outgoing = StreamController<List<int>>();
  var destroyed = false;

  FakeX11Channel() {
    _outgoing.stream.drain<void>();
  }

  @override
  Stream<Uint8List> get stream => incoming.stream;

  @override
  StreamSink<List<int>> get sink => _outgoing.sink;

  @override
  Future<void> get done => Completer<void>().future;

  @override
  Future<void> close() async {}

  @override
  void destroy() => destroyed = true;

  @override
  Future<void> flush() async {}
}
