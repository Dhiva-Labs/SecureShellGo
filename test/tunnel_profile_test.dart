import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/tunnel_profile.dart';

void main() {
  TunnelProfile profile({
    TunnelType type = TunnelType.local,
    String localHost = TunnelProfile.loopback,
    int localPort = 8080,
    String remoteHost = 'db.internal',
    int remotePort = 5432,
  }) {
    return TunnelProfile(
      id: 'tunnel-1',
      name: 'Postgres',
      hostId: 'host-1',
      type: type,
      localHost: localHost,
      localPort: localPort,
      remoteHost: remoteHost,
      remotePort: remotePort,
    );
  }

  group('TunnelType', () {
    test('an unknown stored id reads as a local forward', () {
      expect(TunnelType.fromName('sideways'), TunnelType.local);
      expect(TunnelType.fromName(null), TunnelType.local);
    });

    test('every type round-trips through its stored name', () {
      for (final type in TunnelType.values) {
        expect(TunnelType.fromName(type.name), type);
      }
    });
  });

  group('JSON', () {
    test('round-trips every field', () {
      final original = profile(type: TunnelType.remote);
      final restored = TunnelProfile.fromJson(original.toJson());

      expect(restored.id, original.id);
      expect(restored.name, original.name);
      expect(restored.hostId, original.hostId);
      expect(restored.type, TunnelType.remote);
      expect(restored.localHost, original.localHost);
      expect(restored.localPort, original.localPort);
      expect(restored.remoteHost, original.remoteHost);
      expect(restored.remotePort, original.remotePort);
    });

    test('a blank bind address reads as loopback, never as everything', () {
      final restored = TunnelProfile.fromJson({
        'id': 'tunnel-1',
        'name': 'Postgres',
        'hostId': 'host-1',
        'type': 'local',
        'localHost': '   ',
        'localPort': 8080,
      });
      expect(restored.localHost, TunnelProfile.loopback);
    });

    test('a dynamic forward keeps the destination it is not using', () {
      // Switching a profile's type in the editor and switching it back must
      // not lose what the user had already typed.
      final restored = TunnelProfile.fromJson(
        profile(type: TunnelType.dynamic).toJson(),
      );
      expect(restored.remoteHost, 'db.internal');
      expect(restored.remotePort, 5432);
    });
  });

  group('display', () {
    test('the port summary reads in the direction bytes travel', () {
      expect(profile().portSummary, '127.0.0.1:8080 → db.internal:5432');
      expect(
        profile(type: TunnelType.remote).portSummary,
        'db.internal:5432 → 127.0.0.1:8080',
      );
      expect(
        profile(type: TunnelType.dynamic).portSummary,
        'SOCKS5 on 127.0.0.1:8080',
      );
    });

    test('a remote forward with no bind address shows a wildcard', () {
      expect(
        profile(type: TunnelType.remote, remoteHost: '').portSummary,
        '*:5432 → 127.0.0.1:8080',
      );
    });

    test('an unnamed tunnel falls back to what it does', () {
      const unnamed = TunnelProfile(
        id: 'tunnel-1',
        name: '  ',
        hostId: 'host-1',
        type: TunnelType.dynamic,
        localPort: 1080,
      );
      expect(unnamed.displayName, 'SOCKS5 on 127.0.0.1:1080');
    });
  });

  group('warnings', () {
    test('binding anything but loopback is flagged', () {
      expect(profile().bindsAllInterfaces, isFalse);
      expect(
        profile(localHost: TunnelProfile.anyInterface).bindsAllInterfaces,
        isTrue,
      );
    });

    test('a remote forward does not listen here, so it is never flagged', () {
      // The local address of a remote forward is a destination it dials, not
      // an interface it binds.
      expect(
        profile(type: TunnelType.remote, localHost: TunnelProfile.anyInterface)
            .bindsAllInterfaces,
        isFalse,
      );
    });

    test('the privileged port checked is the one being listened on', () {
      expect(profile(localPort: 80).usesPrivilegedPort, isTrue);
      expect(profile(localPort: 8080).usesPrivilegedPort, isFalse);
      // A remote forward listens over there, on the remote port.
      expect(
        profile(type: TunnelType.remote, localPort: 80, remotePort: 9000)
            .usesPrivilegedPort,
        isFalse,
      );
      expect(
        profile(type: TunnelType.remote, localPort: 8080, remotePort: 443)
            .usesPrivilegedPort,
        isTrue,
      );
    });
  });

  group('validateTunnelPort', () {
    test('accepts a real port', () {
      expect(validateTunnelPort('8080'), isNull);
      expect(validateTunnelPort(' 22 '), isNull);
      expect(validateTunnelPort('65535'), isNull);
    });

    test('rejects blanks, words and out-of-range numbers', () {
      expect(validateTunnelPort(''), isNotNull);
      expect(validateTunnelPort(null), isNotNull);
      expect(validateTunnelPort('http'), isNotNull);
      expect(validateTunnelPort('65536'), isNotNull);
      expect(validateTunnelPort('-1'), isNotNull);
    });

    test('port 0 is only allowed where the far side may choose one', () {
      expect(validateTunnelPort('0'), isNotNull);
      expect(validateTunnelPort('0', allowEphemeral: true), isNull);
    });
  });
}
