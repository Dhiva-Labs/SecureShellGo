import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/services/device_storage.dart';
import 'package:secure_shell_go/services/network_watch.dart';
import 'package:secure_shell_go/services/session_controller.dart';
import 'package:secure_shell_go/services/session_foreground.dart';
import 'package:secure_shell_go/services/session_manager.dart';
import 'package:secure_shell_go/services/ssh_service.dart';
import 'package:secure_shell_go/services/transfer_queue.dart';

import 'memory_fs.dart';
import 'support/fake_transport.dart';
import 'support/link_transport.dart';

/// Network events the test sends, through the same broadcast shape the real
/// watch has — including only being "on" while someone listens.
class FakeNetworkWatch implements NetworkWatch {
  final _events = StreamController<NetworkEvent>.broadcast();

  bool get watching => _events.hasListener;

  void send(NetworkEvent event) => _events.add(event);

  @override
  Stream<NetworkEvent> get events => _events.stream;
}

class RecordingForeground implements SessionForegroundChannel {
  final List<String> started = [];
  var stops = 0;

  @override
  Future<void> start(String label) async => started.add(label);

  @override
  Future<void> stop() async => stops++;
}

class UnusedStorage implements DeviceStorage {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('storage is not exercised in these tests');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('what the platform reports', () {
    test('the first default network is a starting point, not news', () {
      final tracker = DefaultNetworkTracker();
      expect(tracker.available('100'), isNull);
      expect(tracker.available('100'), isNull);
    });

    test('Wi-Fi to mobile data is one change, whatever the order', () {
      final tracker = DefaultNetworkTracker()..available('wifi');
      expect(tracker.available('lte'), NetworkEvent.changed);
      // The Wi-Fi it already moved off going away is not news.
      expect(tracker.lost('wifi'), isNull);
    });

    test('losing the only network, then getting one back', () {
      final tracker = DefaultNetworkTracker()..available('wifi');
      expect(tracker.lost('wifi'), NetworkEvent.lost);
      expect(tracker.available('wifi'), NetworkEvent.available);
    });

    test('desktop interfaces: changed, gone, and back', () {
      final tracker = InterfaceTracker();
      expect(tracker.next('eth0=10.0.0.2'), isNull);
      expect(tracker.next('eth0=10.0.0.2'), isNull);
      expect(tracker.next('wlan0=192.168.1.5'), NetworkEvent.changed);
      expect(tracker.next(''), NetworkEvent.lost);
      expect(tracker.next('wlan0=192.168.1.5'), NetworkEvent.available);
    });

    test('a long gap between ticks is a sleep', () {
      final wake = WakeDetector(period: const Duration(seconds: 15));
      final start = DateTime(2026, 10, 21, 12);
      expect(wake.woke(start), isFalse);
      expect(wake.woke(start.add(const Duration(seconds: 16))), isFalse);
      expect(wake.woke(start.add(const Duration(minutes: 40))), isTrue);
    });

    test('Android events become network events, while someone listens',
        () async {
      final platform = StreamController<dynamic>.broadcast();
      final watch = PlatformNetworkWatch(
        android: true,
        platformEvents: platform.stream,
      );
      final seen = <NetworkEvent>[];
      final sub = watch.events.listen(seen.add);

      platform.add({'event': 'available', 'network': '100'});
      platform.add({'event': 'available', 'network': '101'});
      platform.add({'event': 'lost', 'network': '100'});
      platform.add({'event': 'lost', 'network': '101'});
      platform.add('nonsense');
      await pump();

      expect(seen, [NetworkEvent.changed, NetworkEvent.lost]);
      await sub.cancel();
      expect(platform.hasListener, isFalse,
          reason: 'nothing registered once nobody listens');
    });

    test('Android\'s first report after watching again is a starting point',
        () async {
      final platform = StreamController<dynamic>.broadcast();
      final watch = PlatformNetworkWatch(
        android: true,
        platformEvents: platform.stream,
      );
      var sub = watch.events.listen((_) {});
      platform.add({'event': 'available', 'network': '100'});
      await pump();
      await sub.cancel();

      // The last session closed, and a new one opens on another network.
      // Registering again, Android reports the one that is current now —
      // which is where this watch starts, not a change.
      final seen = <NetworkEvent>[];
      sub = watch.events.listen(seen.add);
      platform.add({'event': 'available', 'network': '101'});
      await pump();
      await sub.cancel();

      expect(seen, isEmpty);
    });

    test('a desktop fingerprint ignores what changes while the network does '
        'not', () {
      String fingerprint(Map<String, List<String>> interfaces) =>
          PlatformNetworkWatch.fingerprintOf([
            for (final MapEntry(:key, :value) in interfaces.entries)
              _Interface(key, value),
          ]);
      final wifi = {
        'wlp0s20f3': [
          '192.168.1.5',
          'fe80::1e4e:5a1f:b67d:ffab',
          '2001:db8:1:2:1e4e:5a1f:b67d:ffab',
          '2001:db8:1:2:9c41:22aa:7e10:3b5d',
        ],
      };
      final start = fingerprint(wifi);

      // A new temporary IPv6 address, the old one retired.
      expect(
        fingerprint({
          'wlp0s20f3': [
            '192.168.1.5',
            '2001:db8:1:2:1e4e:5a1f:b67d:ffab',
            '2001:db8:1:2:4410:8f2e:c1d3:907a',
          ],
        }),
        start,
      );
      // Containers and VMs starting.
      expect(
        fingerprint({
          ...wifi,
          'docker0': ['172.17.0.1'],
          'br-3f2a1b9c0d4e': ['172.18.0.1'],
          'veth1a2b3c4': ['fe80::a8f0:2ff:fe11:1'],
          'virbr0': ['192.168.122.1'],
          'lxdbr0': ['10.162.213.1', 'fd42:f72:6d9:135e::1'],
          'vEthernet (WSL)': ['172.29.48.1'],
        }),
        start,
      );

      // But another network is still another network, and so is a VPN.
      expect(
        fingerprint({
          'wlp0s20f3': ['10.0.0.7', '2001:db8:77:1:1e4e:5a1f:b67d:ffab'],
        }),
        isNot(start),
      );
      expect(fingerprint({...wifi, 'wg0': ['10.8.0.2']}), isNot(start));
      expect(fingerprint({'docker0': ['172.17.0.1']}), isEmpty,
          reason: 'containers alone are no network');
    });

    test('a desktop looks at its interfaces, and its clock', () async {
      final looks = ['eth0=10.0.0.2', 'eth0=10.0.0.2', 'wlan0=192.168.1.5'];
      var now = DateTime(2026, 10, 21, 12);
      final watch = PlatformNetworkWatch(
        android: false,
        interfaces: () async => looks.length > 1 ? looks.removeAt(0) : looks[0],
        clock: () => now,
        pollInterval: const Duration(milliseconds: 5),
      );
      final seen = <NetworkEvent>[];
      final sub = watch.events.listen(seen.add);
      await pump();
      expect(seen, isEmpty, reason: 'the first look is the starting point');

      // The machine sleeps for an hour; on waking, it is on Wi-Fi.
      now = now.add(const Duration(hours: 1));
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await sub.cancel();

      expect(seen, containsAllInOrder([NetworkEvent.woke]));
      expect(seen, contains(NetworkEvent.changed));
    });

    test('only a lost network is not a comeback', () {
      expect(
        NetworkEvent.values.where((e) => !e.isComeback),
        [NetworkEvent.lost],
      );
    });
  });

  group('the session manager', () {
    late FakeNetworkWatch network;
    late RecordingForeground channel;
    late SessionForegroundController foreground;
    late List<CrankTimer> keepalives;
    late ManualScheduler reconnects;
    late Map<String, MemoryFs> filesystems;
    late Dialer dialer;

    SessionManager build() {
      return SessionManager(
        foreground: foreground,
        network: network,
        createController: (connection, resolve, resolveCreds) {
          final fs = filesystems.putIfAbsent(connection.host.id, MemoryFs.new);
          return SessionController(
            connection: connection,
            storage: UnusedStorage(),
            openFileSystem: () async => fs,
            resolveRemoteTarget: resolve,
            keepaliveScheduler: (_, tick) {
              final timer = CrankTimer(tick);
              keepalives.add(timer);
              return timer;
            },
            reconnect: ReconnectSupport(
              loadCredentials: (_) async => const SshCredentials(),
              connect: dialer.connect,
            ),
            reconnectScheduler: reconnects.schedule,
          );
        },
      );
    }

    LinkTransport on(String hostId, {String label = 'Box'}) => LinkTransport(
          host: FakeTransportBase.hostFor(id: hostId, label: label),
        );

    setUp(() {
      network = FakeNetworkWatch();
      channel = RecordingForeground();
      foreground = SessionForegroundController(channel: channel);
      keepalives = [];
      reconnects = ManualScheduler();
      filesystems = {};
      dialer = Dialer(const SshConnectionException('No route to host.'));
    });

    test('watches the network only while a session is open', () async {
      final manager = build();
      addTearDown(manager.dispose);
      expect(network.watching, isFalse);

      final session = manager.open(on('h1'));
      expect(network.watching, isTrue);

      await manager.close(session.id);
      expect(network.watching, isFalse);
    });

    test('a network change checks every live link', () async {
      final manager = build();
      addTearDown(manager.dispose);
      final healthy = on('h1');
      final silent = on('h2');
      final a = manager.open(healthy);
      final b = manager.open(silent);
      await pump();

      silent.answering = false;
      network.send(NetworkEvent.changed);
      await pump();

      expect(healthy.pingCount, 2, reason: 'one at open, one probe');
      expect(a.isClosed, isFalse);
      expect(b.isClosed, isTrue, reason: 'its link died with the old network');
      expect(b.controller.isReconnecting, isTrue);
    });

    test('losing the network does nothing yet', () async {
      final manager = build();
      addTearDown(manager.dispose);
      final transport = on('h1');
      manager.open(transport);
      await pump();

      network.send(NetworkEvent.lost);
      await pump();

      expect(transport.pingCount, 1);
    });

    test('the network coming back retries a dropped session now', () async {
      final manager = build();
      addTearDown(manager.dispose);
      final transport = on('h1');
      final session = manager.open(transport);
      transport.drop(const SocketException('Network is unreachable'));
      await pump();
      dialer.next = on('h1');

      network.send(NetworkEvent.available);
      await pump();

      expect(dialer.calls, 1);
      expect(session.isClosed, isFalse);
    });

    test('coming back on screen restarts a service Android stopped',
        () async {
      final manager = build();
      addTearDown(manager.dispose);
      manager.open(on('h1', label: 'Alpha'));
      await pump();
      expect(channel.started, ['Alpha']);

      foreground.platformStopped();
      network.send(NetworkEvent.resumed);
      await pump();

      expect(channel.started, ['Alpha', 'Alpha']);

      network.send(NetworkEvent.resumed);
      await pump();
      expect(channel.started, hasLength(2), reason: 'only once per stop');
    });

    test('each tab on a host gets its own persistent session', () async {
      final manager = build();
      addTearDown(manager.dispose);

      final first = manager.open(on('h1', label: 'Box'));
      final second = manager.open(on('h1', label: 'Box'));
      final other = manager.open(on('h2', label: 'Other'));

      expect(first.controller.persistentName, 'ssg-box-1_');
      expect(second.controller.persistentName, 'ssg-box-2_');
      expect(other.controller.persistentName, 'ssg-other-1_');

      // The first tab's slot is free again once it closes, so the next tab
      // goes back to the shell it left running.
      await manager.close(first.id);
      final third = manager.open(on('h1', label: 'Box'));
      expect(third.controller.persistentName, 'ssg-box-1_');
    });

    group('a copy to a session that dropped', () {
      Future<
          ({
            SessionManager manager,
            ManagedSession source,
            ManagedSession target,
            TransferTask task,
          })> copyToDropped() async {
        final manager = build();
        final source = manager.open(on('h1', label: 'Alpha'));
        final targetTransport = on('h2', label: 'Beta');
        final target = manager.open(targetTransport);
        filesystems['h1']!.files['/srv/a.txt'] = 1000;

        targetTransport.drop(const SocketException('Connection reset'));
        await pump();
        expect(target.controller.isReconnecting, isTrue);

        final task = source.controller.transfers.enqueueRemoteCopy(
          remotePath: '/srv/a.txt',
          destinationSessionId: target.id,
          destinationPath: '/srv/b/a.txt',
          name: 'a.txt',
        );
        await pump();
        return (
          manager: manager,
          source: source,
          target: target,
          task: task,
        );
      }

      test('waits for it, and finishes once it is back', () async {
        final copy = await copyToDropped();
        addTearDown(copy.manager.dispose);

        expect(copy.task.status, TransferStatus.interrupted);
        expect(copy.task.error, contains('Beta'));

        dialer.next = on('h2', label: 'Beta');
        await reconnects.fire();
        await pump();
        if (!copy.task.status.isFinished) {
          await copy.source.controller.transfers.changes
              .firstWhere((_) => copy.task.status.isFinished)
              .timeout(const Duration(seconds: 5));
        }

        expect(copy.task.status, TransferStatus.completed);
        expect(filesystems['h2']!.files['/srv/b/a.txt'], 1000);
      });

      test('fails once that session is closed for good', () async {
        final copy = await copyToDropped();
        addTearDown(copy.manager.dispose);

        await copy.manager.close(copy.target.id);

        expect(copy.task.status, TransferStatus.failed);
        expect(copy.task.error, contains('closed'));
      });
    });
  });

  group('the foreground service stopped by Android', () {
    test('is started again only while sessions hold it', () async {
      final channel = RecordingForeground();
      final foreground = SessionForegroundController(channel: channel);

      foreground.platformStopped();
      await foreground.reassert();
      expect(channel.started, isEmpty, reason: 'nothing holds it');

      await foreground.acquire('Alpha');
      await foreground.relabel('2 sessions connected');
      foreground.platformStopped();
      expect(foreground.stoppedByPlatform, isTrue);
      await foreground.reassert();

      expect(channel.started, ['Alpha', '2 sessions connected',
          '2 sessions connected']);
      expect(foreground.stoppedByPlatform, isFalse);

      await foreground.release();
      foreground.platformStopped();
      await foreground.reassert();
      expect(channel.started, hasLength(3));
    });
  });

  test('a host keeps persistent sessions off unless asked', () {
    expect(FakeTransportBase.defaultHost.persistentSession,
        PersistentSession.off);
  });
}

/// A network interface with the given addresses, for the fingerprint.
class _Interface implements NetworkInterface {
  _Interface(this.name, List<String> addresses)
      : addresses = [for (final a in addresses) InternetAddress(a)];

  @override
  final String name;

  @override
  final List<InternetAddress> addresses;

  @override
  int get index => 0;
}
