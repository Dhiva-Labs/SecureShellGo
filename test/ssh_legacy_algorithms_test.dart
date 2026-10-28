import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/services/ssh_service.dart';

/// dartssh2 4.0 stopped proposing SHA-1 key exchange, `ssh-rsa` host-key
/// signatures and CBC ciphers. An old router or NAS that speaks nothing else
/// fails to connect, and the per-host "Allow legacy algorithms" switch is
/// the way back — never a silent, global fallback.
void main() {
  Host host({bool legacy = false}) => Host(
        id: 'nas',
        label: 'Old NAS',
        hostname: 'nas.local',
        port: 22,
        username: 'admin',
        authMethod: SshAuthMethod.password,
        legacyAlgorithms: legacy,
      );

  group('which algorithms a host is offered', () {
    test('by default, exactly the library\'s modern set', () {
      final offered = sshAlgorithmsFor(host());
      const defaults = SSHAlgorithms();
      expect(offered.kex, defaults.kex);
      expect(offered.hostkey, defaults.hostkey);
      expect(offered.cipher, defaults.cipher);
      expect(offered.mac, defaults.mac);
      expect(offered.hostkey, isNot(contains(SSHHostkeyType.rsaSha1)));
      expect(offered.cipher, isNot(contains(SSHCipherType.aes128cbc)));
    });

    test('with the switch on, the legacy ones come after the modern ones',
        () {
      final offered = sshAlgorithmsFor(host(legacy: true));
      const defaults = SSHAlgorithms();
      // Modern first, so a server that speaks anything newer still gets it.
      expect(offered.kex.take(defaults.kex.length), defaults.kex);
      expect(offered.hostkey.take(defaults.hostkey.length), defaults.hostkey);
      expect(offered.cipher.take(defaults.cipher.length), defaults.cipher);
      expect(offered.kex, containsAll([SSHKexType.dh14Sha1, SSHKexType.dhGexSha1]));
      expect(offered.hostkey.last, SSHHostkeyType.rsaSha1);
      expect(offered.cipher, containsAll([SSHCipherType.aes128cbc, SSHCipherType.aes256cbc]));
    });
  });

  group('recognising a failed negotiation', () {
    test('our side noticing it, as the client reports it', () {
      final raw = StateError('No matching key exchange algorithm');
      expect(isAlgorithmNegotiationFailure(raw), isTrue);
      // What `client.authenticated` actually throws: the transport closed
      // during the handshake, with the cause wrapped twice.
      final wrapped = SSHAuthAbortError(
        'Connection closed before authentication',
        SSHInternalError(raw),
      );
      expect(isAlgorithmNegotiationFailure(wrapped), isTrue);
    });

    test('the server noticing it first', () {
      final disconnect =
          SSHDisconnectError(3, 'no matching host key type found');
      expect(isAlgorithmNegotiationFailure(disconnect), isTrue);
      expect(
        isAlgorithmNegotiationFailure(
          SSHAuthAbortError('Connection closed before authentication',
              disconnect),
        ),
        isTrue,
      );
    });

    test('other failures are not mistaken for it', () {
      expect(isAlgorithmNegotiationFailure(SSHDisconnectError(11, 'bye')),
          isFalse);
      expect(isAlgorithmNegotiationFailure(SSHAuthFailError('denied')),
          isFalse);
      expect(isAlgorithmNegotiationFailure(StateError('something else')),
          isFalse);
    });
  });

  test('the message points at the switch, or past it when it is on', () {
    expect(describeNegotiationFailure(host()),
        contains('turn on "Allow legacy algorithms"'));
    final on = describeNegotiationFailure(host(legacy: true));
    expect(on, contains('even with legacy algorithms allowed'));
    expect(on, isNot(contains('turn on')));
  });

  test('the switch is saved only when on, and read back', () {
    expect(host().toJson().containsKey('legacyAlgorithms'), isFalse,
        reason: 'hosts saved before it existed must read the same');
    final json = host(legacy: true).toJson();
    expect(json['legacyAlgorithms'], isTrue);
    expect(Host.fromJson(json).legacyAlgorithms, isTrue);
    expect(Host.fromJson(host().toJson()).legacyAlgorithms, isFalse);
    // And the helpers that rebuild a host keep it.
    expect(host(legacy: true).withGroup('x').legacyAlgorithms, isTrue);
    expect(host(legacy: true).withJumpHost(null).legacyAlgorithms, isTrue);
  });

  test('the connection notes when the server last sent anything', () async {
    final inbound = StreamController<Uint8List>();
    var now = DateTime(2026, 10, 21, 10);
    final socket = InboundWatchSocket(_FakeSocket(inbound.stream),
        clock: () => now);
    final received = <int>[];
    socket.stream.listen(received.addAll);

    expect(socket.lastInboundAt, isNull);
    inbound.add(Uint8List.fromList([1, 2, 3]));
    await Future<void>.delayed(Duration.zero);
    expect(socket.lastInboundAt, DateTime(2026, 10, 21, 10));
    expect(received, [1, 2, 3], reason: 'the bytes pass through untouched');

    now = DateTime(2026, 10, 21, 10, 5);
    inbound.add(Uint8List.fromList([4]));
    await Future<void>.delayed(Duration.zero);
    expect(socket.lastInboundAt, DateTime(2026, 10, 21, 10, 5));
    await inbound.close();
  });
}

class _FakeSocket implements SSHSocket {
  _FakeSocket(this.stream);

  @override
  final Stream<Uint8List> stream;

  @override
  StreamSink<List<int>> get sink => StreamController<List<int>>().sink;

  @override
  Future<void> get done => Completer<void>().future;

  @override
  Future<void> close() async {}

  @override
  void destroy() {}

  @override
  Future<void> flush() async {}
}
