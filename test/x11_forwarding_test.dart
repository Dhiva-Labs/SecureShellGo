import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart' show SSHSocket;
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/x11_forwarding.dart';

/// The X11 pieces that need no SSH at all: reading `DISPLAY` and
/// Xauthority, and the cookie swap in an X client's first message. The
/// channel side — an `x11` channel from a real dartssh2 client piped to a
/// listening X server — is in `ssh_forwarding_client_test.dart`.
void main() {
  final fake = Uint8List.fromList(List.generate(16, (i) => i + 1));
  final real = XauthEntry(
    family: XauthEntry.familyWild,
    address: Uint8List(0),
    number: '',
    name: x11CookieProtocol,
    data: Uint8List.fromList(List.filled(16, 0xcc)),
  );

  group('rewriteX11Setup', () {
    test('swaps the fake cookie for the real one, little-endian', () {
      final rewrite = rewriteX11Setup(
        _setup(fake, littleEndian: true, extra: [1, 2, 3]),
        fakeCookie: fake,
        realCookie: real,
      )!;
      expect(rewrite.rewritten, _setup(real.data, littleEndian: true));
      expect(rewrite.leftover, [1, 2, 3]);
    });

    test('and big-endian', () {
      final rewrite = rewriteX11Setup(
        _setup(fake, littleEndian: false),
        fakeCookie: fake,
        realCookie: real,
      )!;
      expect(rewrite.rewritten, _setup(real.data, littleEndian: false));
      expect(rewrite.leftover, isEmpty);
    });

    test('keeps the protocol version the client asked for', () {
      final setup = _setup(fake, littleEndian: true, major: 11, minor: 7);
      final rewrite =
          rewriteX11Setup(setup, fakeCookie: fake, realCookie: real)!;
      expect(rewrite.rewritten.sublist(0, 6), setup.sublist(0, 6));
    });

    test('with no real cookie, sends no authorization at all', () {
      // For an X server with access control off — a Windows X server, or
      // one that admits the local user by credentials.
      final rewrite = rewriteX11Setup(
        _setup(fake, littleEndian: true),
        fakeCookie: fake,
        realCookie: null,
      )!;
      expect(rewrite.rewritten, _setup(const [], littleEndian: true, name: ''));
    });

    test('waits for the whole setup however it is split', () {
      final setup = _setup(fake, littleEndian: true);
      for (var cut = 0; cut < setup.length; cut++) {
        expect(
          rewriteX11Setup(setup.sublist(0, cut),
              fakeCookie: fake, realCookie: real),
          isNull,
          reason: 'only $cut of ${setup.length} bytes',
        );
      }
    });

    test('refuses the wrong cookie', () {
      expect(
        () => rewriteX11Setup(
          _setup(List.filled(16, 0), littleEndian: true),
          fakeCookie: fake,
          realCookie: real,
        ),
        throwsA(isA<X11SetupRejected>().having(
            (e) => e.message, 'message', contains('wrong authentication'))),
      );
    });

    test('refuses a right-looking cookie under another protocol', () {
      expect(
        () => rewriteX11Setup(
          _setup(fake, littleEndian: true, name: 'XDM-AUTHORIZATION-1'),
          fakeCookie: fake,
          realCookie: real,
        ),
        throwsA(isA<X11SetupRejected>()),
      );
    });

    test('refuses no cookie', () {
      expect(
        () => rewriteX11Setup(
          _setup(const [], littleEndian: true, name: ''),
          fakeCookie: fake,
          realCookie: real,
        ),
        throwsA(isA<X11SetupRejected>()),
      );
    });

    test('refuses something that is not X11, from the first byte', () {
      expect(
        () => rewriteX11Setup(
          Uint8List.fromList('GET / HTTP/1.1'.codeUnits),
          fakeCookie: fake,
          realCookie: real,
        ),
        throwsA(isA<X11SetupRejected>()),
      );
    });

    test('refuses implausible lengths rather than waiting for them', () {
      final head = Uint8List.fromList(
          [0x6c, 0, 11, 0, 0, 0, 0xff, 0xff, 0x10, 0, 0, 0]);
      expect(
        () => rewriteX11Setup(head, fakeCookie: fake, realCookie: real),
        throwsA(isA<X11SetupRejected>()),
      );
    });
  });

  group('X11Display.parse', () {
    test('the local display', () {
      final d = X11Display.parse(':0')!;
      expect(d.host, isNull);
      expect(d.number, 0);
      expect(d.screen, 0);
      expect(d.isLocal, isTrue);
    });

    test('with a screen, or spelled unix:', () {
      expect(X11Display.parse(':1.2')!.screen, 2);
      expect(X11Display.parse('unix:3')!.host, isNull);
      expect(X11Display.parse('unix:3')!.number, 3);
    });

    test('over TCP', () {
      final d = X11Display.parse('localhost:10.0')!;
      expect(d.host, 'localhost');
      expect(d.number, 10);
      expect(d.isLocal, isTrue);
      expect(X11Display.parse('192.168.1.5:0')!.isLocal, isFalse);
      expect(X11Display.parse('[::1]:4')!.host, '::1');
    });

    test('XQuartz names its socket outright', () {
      final d =
          X11Display.parse('/private/tmp/com.apple.launchd.abc/org.xquartz:0')!;
      expect(d.socketPath, '/private/tmp/com.apple.launchd.abc/org.xquartz');
      expect(d.number, 0);
    });

    test('nonsense is nothing', () {
      expect(X11Display.parse(''), isNull);
      expect(X11Display.parse('wayland-0'), isNull);
      expect(X11Display.parse(':x'), isNull);
      expect(X11Display.parse(':0.y'), isNull);
    });

    test('from the environment', () {
      expect(X11Display.fromEnvironment({'DISPLAY': ':5'})!.number, 5);
      if (!Platform.isWindows) {
        expect(X11Display.fromEnvironment(const {}), isNull);
      }
    });
  });

  group('Xauthority', () {
    final file = _xauthority([
      _Entry(XauthEntry.familyLocal, 'otherbox'.codeUnits, '0', [1]),
      _Entry(XauthEntry.familyLocal, 'mybox'.codeUnits, '1', [2]),
      _Entry(XauthEntry.familyLocal, 'mybox'.codeUnits, '0', [3]),
      _Entry(XauthEntry.familyInternet, [127, 0, 0, 1], '10', [4]),
      _Entry(XauthEntry.familyWild, const [], '', [5], name: 'XDM-AUTHORIZATION-1'),
      _Entry(XauthEntry.familyWild, const [], '', [6]),
    ]);

    test('reads every record', () {
      final entries = parseXauthority(file);
      expect(entries, hasLength(6));
      expect(entries[1].number, '1');
      expect(String.fromCharCodes(entries[1].address), 'mybox');
      expect(entries[4].name, 'XDM-AUTHORIZATION-1');
    });

    test('a damaged tail ends the list without losing the rest', () {
      final cut = file.sublist(0, file.length - 3);
      expect(parseXauthority(cut), hasLength(5));
    });

    XauthEntry? pick(String display) => pickXauthCookie(
          parseXauthority(file),
          X11Display.parse(display)!,
          localHostname: 'MyBox',
        );

    test('the local socket uses this machine\'s record for that display', () {
      expect(pick(':0')!.data, [3]);
      expect(pick(':1')!.data, [2]);
    });

    test('a TCP display uses its address\'s record', () {
      expect(pick('127.0.0.1:10')!.data, [4]);
    });

    test('otherwise the wildcard cookie, never another protocol\'s', () {
      expect(pick(':7')!.data, [6]);
    });

    test('an empty display number matches every display', () {
      // How mutter's Xwayland writes it.
      final entries = parseXauthority(_xauthority([
        _Entry(XauthEntry.familyLocal, 'mybox'.codeUnits, '', [9]),
      ]));
      expect(
        pickXauthCookie(entries, X11Display.parse(':3')!,
                localHostname: 'mybox')!
            .data,
        [9],
      );
    });

    test('loaded from XAUTHORITY, and nothing when there is no file',
        () async {
      final dir = await Directory.systemTemp.createTemp('xauth');
      addTearDown(() => dir.delete(recursive: true));
      final path = '${dir.path}/auth';
      await File(path).writeAsBytes(_xauthority([
        _Entry(XauthEntry.familyWild, const [], '0', [7]),
      ]));
      final found = await loadXauthCookie(X11Display.parse(':0')!,
          environment: {'XAUTHORITY': path});
      expect(found!.data, [7]);
      expect(
        await loadXauthCookie(X11Display.parse(':0')!,
            environment: {'XAUTHORITY': '${dir.path}/missing'}),
        isNull,
      );
    });
  });

  group('X11Forwarder', () {
    test('asks for x11 with the fake cookie, in hex, and the screen', () {
      final forwarder = X11Forwarder(
        display: const X11Display(number: 0, screen: 2),
        fakeCookie: fake,
      );
      expect(forwarder.config.authenticationProtocol, x11CookieProtocol);
      expect(forwarder.config.authenticationCookie,
          '0102030405060708090a0b0c0d0e0f10');
      expect(forwarder.config.screenNumber, 2);
    });

    test('a fresh cookie per connection, sixteen random bytes', () {
      final a = X11Forwarder(display: const X11Display(number: 0));
      final b = X11Forwarder(display: const X11Display(number: 0));
      expect(a.fakeCookie, hasLength(16));
      expect(a.fakeCookie, isNot(b.fakeCookie));
    });

    test('a client that never sends its setup is hung up on', () async {
      final channel = _FakeChannel();
      final forwarder = X11Forwarder(
        display: const X11Display(number: 0),
        fakeCookie: fake,
        realCookie: () async => real,
        connect: () => throw StateError('must not be dialled'),
        setupTimeout: const Duration(milliseconds: 50),
      );
      await forwarder.handle(channel);
      expect(channel.destroyed, isTrue);
      expect(forwarder.lastProblem, contains('in time'));
    });

    test('an X server that is not running is reported, and hung up on',
        () async {
      final channel = _FakeChannel();
      final forwarder = X11Forwarder(
        display: const X11Display(number: 0),
        fakeCookie: fake,
        realCookie: () async => real,
        connect: () => throw const SocketException('Connection refused'),
      );
      final handled = forwarder.handle(channel);
      channel.incoming.add(_setup(fake, littleEndian: true));
      await handled;
      expect(channel.destroyed, isTrue);
      expect(forwarder.lastProblem, contains('Could not reach the X server'));
    });
  });
}

/// An X11 connection setup presenting [cookie] under [name].
Uint8List _setup(
  List<int> cookie, {
  required bool littleEndian,
  String name = x11CookieProtocol,
  int major = 11,
  int minor = 0,
  List<int> extra = const [],
}) {
  final endian = littleEndian ? Endian.little : Endian.big;
  final header = ByteData(12)
    ..setUint8(0, littleEndian ? 0x6c : 0x42)
    ..setUint16(2, major, endian)
    ..setUint16(4, minor, endian)
    ..setUint16(6, name.length, endian)
    ..setUint16(8, cookie.length, endian);
  int pad(int n) => (4 - n % 4) % 4;
  return (BytesBuilder()
        ..add(header.buffer.asUint8List())
        ..add(name.codeUnits)
        ..add(List.filled(pad(name.length), 0))
        ..add(cookie)
        ..add(List.filled(pad(cookie.length), 0))
        ..add(extra))
      .toBytes();
}

class _Entry {
  _Entry(this.family, this.address, this.number, this.data,
      {this.name = x11CookieProtocol});
  final int family;
  final List<int> address;
  final String number;
  final String name;
  final List<int> data;
}

Uint8List _xauthority(List<_Entry> entries) {
  final out = BytesBuilder();
  void field(List<int> bytes) => out
    ..add([bytes.length >> 8, bytes.length & 0xff])
    ..add(bytes);
  for (final e in entries) {
    out.add([e.family >> 8, e.family & 0xff]);
    field(e.address);
    field(e.number.codeUnits);
    field(e.name.codeUnits);
    field(e.data);
  }
  return out.toBytes();
}

class _FakeChannel implements SSHSocket {
  final incoming = StreamController<Uint8List>();
  final _outgoing = StreamController<List<int>>();
  var destroyed = false;

  _FakeChannel() {
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
