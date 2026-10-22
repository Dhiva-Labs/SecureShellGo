import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;

/// Something that makes a dead link likely, or a retry worthwhile.
///
/// Sessions do not care which network they are on, only that the one they
/// were on may be gone and that there may be one to reconnect over now. So
/// the platform's detail is reduced to these, and `SessionManager` hands
/// every one but [lost] to `SessionController.networkCameBack`.
enum NetworkEvent {
  /// A network came up where there was none.
  available,

  /// The device moved to a different network: Wi-Fi to mobile data, a new
  /// access point, a VPN coming up. A connection made over the old one is
  /// very likely dead, and nothing may say so for minutes.
  changed,

  /// The last network went away. Nothing to do yet — a reconnect attempted
  /// now could only fail — but the next [available] is worth acting on.
  lost,

  /// The app is on screen again after being hidden: back from the
  /// background on a phone, restored on a desktop.
  resumed,

  /// The computer slept and has woken up.
  woke;

  /// Whether sessions should check their links and retry dropped ones.
  bool get isComeback => this != NetworkEvent.lost;
}

/// Watches for [NetworkEvent]s.
///
/// [events] is a broadcast stream that only watches while someone listens:
/// `SessionManager` listens while a session is open and stops when the last
/// one closes, so nothing polls and no callback is registered for an app with
/// nothing to keep alive.
abstract class NetworkWatch {
  Stream<NetworkEvent> get events;

  /// The watch for the platform the app is running on.
  static NetworkWatch forPlatform() => PlatformNetworkWatch();
}

/// Turns Android's "default network is now X" and "network X is gone" into
/// [NetworkEvent]s.
///
/// Android tells a default-network callback about the network that is
/// current the moment it is registered; that first one is a starting point,
/// not news. After it, a different network becoming the default is a change
/// (or, coming from none, an arrival), and losing the current one is a loss.
/// Losing some *other* network — the Wi-Fi the phone already moved off — is
/// not news either.
class DefaultNetworkTracker {
  String? _current;
  var _seen = false;

  NetworkEvent? available(String network) {
    if (!_seen) {
      _seen = true;
      _current = network;
      return null;
    }
    if (_current == network) return null;
    final had = _current;
    _current = network;
    return had == null ? NetworkEvent.available : NetworkEvent.changed;
  }

  NetworkEvent? lost(String network) {
    _seen = true;
    if (_current != network) return null;
    _current = null;
    return NetworkEvent.lost;
  }

  /// Forgets everything, so the next report is a starting point again — as
  /// it is when the callback is registered afresh.
  void reset() {
    _current = null;
    _seen = false;
  }
}

/// Turns successive looks at a desktop's network interfaces into
/// [NetworkEvent]s.
///
/// Desktops get no callback here, so the addresses are compared instead —
/// one `getifaddrs` every [PlatformNetworkWatch.desktopPollInterval], which
/// is as cheap as a look at the system gets. The first look is the starting
/// point. No addresses at all is no network.
class InterfaceTracker {
  String? _last;

  NetworkEvent? next(String fingerprint) {
    final last = _last;
    _last = fingerprint;
    if (last == null || last == fingerprint) return null;
    if (fingerprint.isEmpty) return NetworkEvent.lost;
    if (last.isEmpty) return NetworkEvent.available;
    return NetworkEvent.changed;
  }

  void reset() => _last = null;
}

/// Tells a computer that slept from one that was merely busy.
///
/// A periodic timer runs on the monotonic clock, which stops while the
/// machine sleeps; the wall clock does not. A tick that arrives with far more
/// wall-clock time behind it than the timer's own period means the machine
/// was asleep in between.
class WakeDetector {
  WakeDetector({required this.period, this.slack = const Duration(seconds: 30)});

  final Duration period;
  final Duration slack;
  DateTime? _last;

  bool woke(DateTime now) {
    final last = _last;
    _last = now;
    if (last == null) return false;
    return now.difference(last) > period + slack;
  }

  void reset() => _last = null;
}

/// The real watch: Android's connectivity callback, or on desktops a cheap
/// look at the interfaces and the clock; and on both, the app coming back on
/// screen.
///
/// The Android half is `NetworkWatchBridge.kt`, registered in
/// `MainActivity` — a hand-written channel like the rest of the app's
/// platform code, rather than a plugin.
class PlatformNetworkWatch implements NetworkWatch {
  PlatformNetworkWatch({
    bool? android,
    Stream<dynamic>? platformEvents,
    Future<String> Function()? interfaces,
    DateTime Function()? clock,
    Duration pollInterval = desktopPollInterval,
  })  : _android = android ?? Platform.isAndroid,
        _pollInterval = pollInterval,
        _wake = WakeDetector(period: pollInterval),
        // ignore: prefer_initializing_formals
        _platformEvents = platformEvents,
        _interfaces = interfaces ?? interfaceFingerprint,
        _clock = clock ?? DateTime.now;

  static const EventChannel channel =
      EventChannel('com.dhivalabs.secure_shell_go/network');

  /// How often a desktop looks at its interfaces and its clock.
  static const Duration desktopPollInterval = Duration(seconds: 15);

  final bool _android;
  final Stream<dynamic>? _platformEvents;
  final Future<String> Function() _interfaces;
  final DateTime Function() _clock;
  final Duration _pollInterval;

  late final StreamController<NetworkEvent> _events =
      StreamController<NetworkEvent>.broadcast(
    onListen: _start,
    onCancel: _stop,
  );

  final _tracker = DefaultNetworkTracker();
  final _interfaceTracker = InterfaceTracker();
  final WakeDetector _wake;

  AppLifecycleListener? _lifecycle;
  StreamSubscription<dynamic>? _platform;
  Timer? _poll;
  var _polling = false;

  @override
  Stream<NetworkEvent> get events => _events.stream;

  void _start() {
    // `onShow`, not `onResume`: a desktop window regaining focus, or a phone
    // returning from a system picker, is not the app coming back from
    // anywhere a link could have died in.
    _lifecycle = AppLifecycleListener(onShow: () => _emit(NetworkEvent.resumed));
    if (_android) {
      final stream = _platformEvents ?? channel.receiveBroadcastStream();
      _platform = stream.listen(
        _onPlatformEvent,
        // A device without the bridge (an old build, a test) simply has no
        // network events; the keep-alives still find dead links.
        onError: (Object _) {},
      );
    } else {
      unawaited(_look());
      _poll = Timer.periodic(_pollInterval, (_) => unawaited(_look()));
    }
  }

  void _stop() {
    _lifecycle?.dispose();
    _lifecycle = null;
    unawaited(_platform?.cancel());
    _platform = null;
    _poll?.cancel();
    _poll = null;
    _tracker.reset();
    _interfaceTracker.reset();
    _wake.reset();
  }

  void _onPlatformEvent(dynamic raw) {
    if (raw is! Map) return;
    final network = '${raw['network']}';
    final event = switch (raw['event']) {
      'available' => _tracker.available(network),
      'lost' => _tracker.lost(network),
      _ => null,
    };
    if (event != null) _emit(event);
  }

  Future<void> _look() async {
    if (_polling) return;
    _polling = true;
    try {
      final woke = _wake.woke(_clock());
      String fingerprint;
      try {
        fingerprint = await _interfaces();
      } catch (_) {
        fingerprint = '';
      }
      final change = _interfaceTracker.next(fingerprint);
      if (change != null) _emit(change);
      if (woke) _emit(NetworkEvent.woke);
    } finally {
      _polling = false;
    }
  }

  void _emit(NetworkEvent event) {
    if (_events.isClosed || !_events.hasListener) return;
    _events.add(event);
  }

  /// The addresses that say which network this machine is on, sorted, as
  /// one string. See [fingerprintOf].
  static Future<String> interfaceFingerprint() async =>
      fingerprintOf(await NetworkInterface.list());

  /// [interfaceFingerprint] of [interfaces].
  ///
  /// Leaves out what changes while the network does not, because every
  /// change here is a [NetworkEvent.changed] — which checks every link and
  /// gives a reconnect that ran out of time a fresh schedule:
  ///
  /// - loopback and link-local addresses;
  /// - the bridges of containers and virtual machines on this computer
  ///   ([_localBridge]), which come and go as containers start and stop;
  /// - an IPv6 address past its /64 prefix. Temporary (privacy) addresses
  ///   are replaced every day or so within the same prefix; the prefix is
  ///   what changes with the network.
  @visibleForTesting
  static String fingerprintOf(Iterable<NetworkInterface> interfaces) {
    final entries = <String>{
      for (final interface in interfaces)
        if (!_localBridge.hasMatch(interface.name))
          for (final address in interface.addresses)
            if (!address.isLoopback && !address.isLinkLocal)
              '${interface.name}=${_networkPart(address)}',
    };
    return (entries.toList()..sort()).join(',');
  }

  /// Interfaces that only reach containers and virtual machines on this
  /// computer: Docker's, Podman's, Kubernetes CNI's, libvirt's, LXC's and
  /// LXD's, Incus's, VirtualBox's and VMware's host-only ones on Linux, and
  /// WSL's and Hyper-V's Default Switch on Windows. A VPN is not one of
  /// them: one coming up is a change of network.
  static final RegExp _localBridge = RegExp(
    r'^(docker\d|br-[0-9a-f]{12}$|veth|cni\d|flannel\.|cali[0-9a-f]|podman\d|'
    r'virbr\d|lxcbr\d|lxdbr\d|incusbr\d|vboxnet\d|vmnet\d|'
    r'vEthernet \((WSL|Default Switch))',
  );

  static String _networkPart(InternetAddress address) {
    if (address.type != InternetAddressType.IPv6) return address.address;
    final prefix = address.rawAddress.take(8);
    return '${prefix.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}'
        '::/64';
  }
}
