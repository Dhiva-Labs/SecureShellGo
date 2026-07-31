import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../models/host.dart';
import '../models/tunnel_profile.dart';
import 'session_keepalive.dart' show PeriodicScheduler;
import 'socks5.dart';
import 'ssh_service.dart';
import 'tunnel_carrier.dart';
import 'tunnel_store.dart';

export 'tunnel_carrier.dart'
    show SshTunnelCarrier, TunnelCarrier, TunnelRemoteListener;

/// Where a tunnel is in its lifecycle.
enum TunnelState {
  stopped,

  /// Acquiring a connection to ride on, or binding the listener.
  starting,

  /// Listening. Note that this says nothing about whether anything is
  /// *using* it — see [TunnelStatus.connections].
  active,

  /// It stopped for a reason worth reading. [TunnelStatus.message] always
  /// says what.
  error,
}

/// What a tunnel is doing right now.
///
/// An immutable snapshot rather than a live object: it crosses into the
/// widget tree, and a counter the UI could watch mutate under it would be a
/// rebuild that never happens (the field changed, the widget did not).
class TunnelStatus {
  const TunnelStatus({
    required this.profileId,
    this.state = TunnelState.stopped,
    this.message,
    this.connections = 0,
    this.totalConnections = 0,
    this.bytesUp = 0,
    this.bytesDown = 0,
    this.boundPort,
    this.dedicated = false,
    this.awaitingSession = false,
  });

  final String profileId;
  final TunnelState state;

  /// The error, or the note about the last connection that failed. Always
  /// phrased for a human — this is what the row shows inline.
  final String? message;

  /// Connections open through this tunnel at this instant.
  final int connections;

  /// Connections it has carried since it was started.
  final int totalConnections;

  /// Bytes sent from this device towards the SSH server, and bytes received
  /// from it. Fixed to the *device*, not to the tunnel's direction, so that
  /// "up" means the same thing on a local forward and a remote one.
  final int bytesUp;
  final int bytesDown;

  /// The port actually bound — locally for a local/dynamic forward, on the
  /// server for a remote one. The only way to find out what a request for
  /// port 0 was answered with.
  final int? boundPort;

  /// True when this tunnel opened its own SSH connection rather than riding
  /// on a session's.
  final bool dedicated;

  /// True when the session carrying this tunnel dropped and the tunnel is
  /// waiting for that session to reconnect so it can start listening again.
  final bool awaitingSession;

  bool get isRunning =>
      state == TunnelState.starting || state == TunnelState.active;
}

/// Opens a dedicated SSH connection for a tunnel.
///
/// Same shape as [ReconnectConnector] in `session_reconnect.dart`, and for
/// the same reason: everything below `services/` stays testable without a
/// socket, and this path cannot quietly acquire the ability to do anything
/// to a connection except open one. The composition root wraps
/// `SshService.connect` — so jump chains, known-hosts checks and TOFU
/// prompts are the ordinary ones, not a second implementation of them.
typedef TunnelConnector = Future<TunnelCarrier> Function({
  required Host host,
  required SshCredentials credentials,
  required HostKeyVerifier verifyHostKey,
});

/// Finds a live session's transport for [hostId], or null when nothing is
/// open on that host. `SessionManager` is the only thing that can answer
/// this, and the runtime deliberately does not know it exists.
typedef SessionCarrierLookup = TunnelCarrier? Function(String hostId);

/// Everything the runtime needs from the rest of the app, and nothing else.
///
/// Bundled for the same reason [ReconnectSupport] is: it travels from
/// `main.dart`, where the stores and the SSH service are built, and four more
/// constructor parameters would be four more things for the next caller to
/// forget.
class TunnelSupport {
  const TunnelSupport({
    required this.lookupHost,
    required this.loadCredentials,
    this.connect,
    this.findSessionCarrier,
    this.sessionChanges,
  });

  /// `HostStore.get` fits this.
  final Future<Host?> Function(String hostId) lookupHost;

  /// `CredentialStore.load` fits this.
  final Future<SshCredentials?> Function(String hostId) loadCredentials;

  /// How a tunnel opens its own connection when no session is up on the
  /// host. Null means it cannot, and a tunnel started with nothing to ride
  /// on says so instead of failing obscurely.
  final TunnelConnector? connect;

  final SessionCarrierLookup? findSessionCarrier;

  /// Fires whenever the set of sessions — or one session's transport —
  /// changes. `SessionManager.changes` fits this, and it is what makes a
  /// tunnel re-listen after the session carrying it reconnects: adopting a
  /// new transport notifies on exactly this stream. See
  /// [TunnelRuntime._reviewCarriers].
  final Stream<void>? sessionChanges;
}

/// A tunnel could not be started, with a message fit to put in front of a
/// human. Every failure the runtime raises on its own is one of these.
class TunnelException implements Exception {
  const TunnelException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Owns every running tunnel: the listeners, the connections passing through
/// them, and the byte counters.
///
/// **Ownership.** The runtime owns every socket it created — the local
/// [ServerSocket] a local or dynamic forward listens on, every [Socket]
/// accepted or dialled, and every forwarded [SSHSocket] channel — and closes
/// all of them when a tunnel stops. It owns the *connection* underneath only
/// when it opened one itself (a dedicated carrier); a tunnel riding on a
/// live session borrows that session's transport and never closes it. See
/// [TunnelCarrier.release].
class TunnelRuntime {
  TunnelRuntime({
    required this.profiles,
    required TunnelSupport support,
    PeriodicScheduler counterScheduler = Timer.periodic,
    TunnelRetryScheduler retryScheduler = Timer.new,
  })  : _support = support,
        // ignore: prefer_initializing_formals
        _counterScheduler = counterScheduler,
        // ignore: prefer_initializing_formals
        _retryScheduler = retryScheduler {
    _sessionChanges = support.sessionChanges?.listen((_) => _reviewCarriers());
  }

  /// The saved profiles. Held here rather than beside the runtime so that one
  /// object is the whole tunnel subsystem as far as the screens are
  /// concerned, and so a profile edited while its tunnel is running is
  /// picked up on the next start rather than silently ignored.
  final TunnelStore profiles;

  final TunnelSupport _support;
  final PeriodicScheduler _counterScheduler;
  final TunnelRetryScheduler _retryScheduler;

  /// How often the byte counters are published.
  ///
  /// Counters are updated on every chunk and *published* on this schedule.
  /// Emitting per chunk would rebuild the tunnels screen thousands of times
  /// a second under a real transfer, to redraw a number that changes faster
  /// than anyone can read it. State changes — starting, active, a connection
  /// opening or closing, an error — are published immediately regardless.
  static const Duration counterInterval = Duration(milliseconds: 700);

  /// How long a SOCKS5 client has to complete its handshake. A connection
  /// that opens and then says nothing is holding a slot on a listener the
  /// user can see the connection count of.
  static const Duration socksHandshakeTimeout = Duration(seconds: 10);

  /// How long to wait for the local target of a remote forward.
  static const Duration targetConnectTimeout = Duration(seconds: 10);

  /// The ladder for re-dialling a dedicated connection that dropped.
  ///
  /// Short and finite. A tunnel that cannot be carried is a listener that
  /// would otherwise accept connections it can do nothing with, so after
  /// this it stops trying and the row says so — a decision the user can see
  /// beats a retry loop they cannot.
  static const List<Duration> redialBackoff = [
    Duration(seconds: 2),
    Duration(seconds: 6),
    Duration(seconds: 15),
  ];

  final Map<String, _TunnelRecord> _records = {};
  final _changes = StreamController<TunnelStatus>.broadcast();

  StreamSubscription<void>? _sessionChanges;
  Timer? _counterTimer;
  var _disposed = false;

  /// Emits the new status of a tunnel whenever anything about it changes.
  Stream<TunnelStatus> get changes => _changes.stream;

  /// The current status of every tunnel the runtime has touched this run.
  Iterable<TunnelStatus> get statuses =>
      _records.values.map(_snapshot).toList(growable: false);

  /// The status of [profileId] — [TunnelState.stopped] for one that has
  /// never been started, so callers never have to handle null.
  TunnelStatus statusFor(String profileId) {
    final record = _records[profileId];
    return record == null
        ? TunnelStatus(profileId: profileId)
        : _snapshot(record);
  }

  /// How many tunnels are listening right now. What the sessions screen's
  /// indicator counts.
  int get activeCount =>
      _records.values.where((r) => r.state == TunnelState.active).length;

  bool isRunning(String profileId) => statusFor(profileId).isRunning;

  /// Starts the saved tunnel [profileId].
  ///
  /// [verifyHostKey] is how a host-key prompt reaches the user, and is
  /// supplied by whichever screen the user started the tunnel from. Omitting
  /// it refuses every prompt — see [_refuseHostKey], which is the same
  /// bargain `SessionReconnector` makes for the same reason.
  ///
  /// Never throws: a failure is a status, because that is where the row that
  /// asked for it is going to look.
  Future<void> start(
    String profileId, {
    HostKeyVerifier? verifyHostKey,
  }) async {
    if (_disposed) return;
    final profile = await profiles.get(profileId);
    if (profile == null) return;

    final record = _records.putIfAbsent(
      profileId,
      () => _TunnelRecord(profile),
    );
    if (record.state == TunnelState.starting ||
        record.state == TunnelState.active) {
      return;
    }

    // Picks up an edit made while the tunnel was stopped, and clears both a
    // stale error and the counters from the previous run.
    record.profile = profile;
    record.redialAttempt = 0;
    record.reset();

    final generation = ++record.generation;
    record.state = TunnelState.starting;
    _publish(record);

    try {
      final carrier = await _acquireCarrier(profile, verifyHostKey);
      if (record.generation != generation) {
        // Stopped while the handshake was in flight. A connection we opened
        // for a tunnel that no longer wants it is nobody's.
        if (carrier.isDedicated) carrier.release();
        return;
      }
      record.carrier = carrier;
      await _listen(record, carrier, generation);
    } catch (error) {
      await _failed(record, generation, _describe(error));
    }
  }

  /// Stops a tunnel: closes its listener, every connection through it, and —
  /// only if it opened one — its connection.
  Future<void> stop(String profileId) async {
    final record = _records[profileId];
    if (record == null) return;
    record.generation++;
    record.redialAttempt = 0;
    await _teardown(record);
    record.state = TunnelState.stopped;
    record.message = null;
    record.awaitingSession = false;
    record.boundPort = null;
    _publish(record);
  }

  Future<void> stopAll() async {
    for (final id in _records.keys.toList(growable: false)) {
      await stop(id);
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _sessionChanges?.cancel();
    _counterTimer?.cancel();
    _counterTimer = null;
    await stopAll();
    await _changes.close();
  }

  // ------------------------------------------------------------- carriers

  /// The connection this tunnel will ride on: a live session's transport
  /// when there is one, otherwise a connection opened for it alone.
  Future<TunnelCarrier> _acquireCarrier(
    TunnelProfile profile,
    HostKeyVerifier? verifyHostKey,
  ) async {
    final host = await _support.lookupHost(profile.hostId);
    if (host == null) {
      throw const TunnelException(
        'This tunnel rides on a saved host that has been deleted. Edit the '
        'tunnel and point it at a host that still exists.',
      );
    }

    // Reusing the session's transport is the whole reason this check comes
    // first: a second SSH connection to a box the user is already on costs
    // another authentication, another entry in the server's auth log, and —
    // for anything behind a jump chain — another trip through every bastion.
    final live = _support.findSessionCarrier?.call(profile.hostId);
    if (live != null && !live.isClosed) return live;

    final connect = _support.connect;
    if (connect == null) {
      throw TunnelException(
        'There is no open session on "${host.displayName}" for this tunnel to '
        'ride on. Connect to it first, then start the tunnel.',
      );
    }

    final credentials = await _support.loadCredentials(host.id);
    if (credentials == null) {
      throw TunnelException(
        'No saved credentials for "${host.displayName}". Open it in the host '
        'editor and save its password or key first.',
      );
    }

    return connect(
      host: host,
      credentials: credentials,
      verifyHostKey: verifyHostKey ?? _refuseHostKey,
    );
  }

  /// The verifier used when a tunnel starts itself — an automatic re-dial
  /// after the connection dropped.
  ///
  /// Refuses, exactly as `SessionReconnector` does. This is not a way around
  /// the TOFU flow, it *is* the flow with the only answer that is honest
  /// when nobody is looking: [HostKeyPolicy] still accepts a key that matches
  /// known-hosts without prompting at all, which is every ordinary re-dial. A
  /// key that has changed, or a host not yet known, reaches the prompt — and
  /// a tunnel must never be the thing that accepts one of those on the user's
  /// behalf.
  static Future<bool> _refuseHostKey(HostKeyPrompt prompt) async => false;

  void _watchCarrier(
    _TunnelRecord record,
    TunnelCarrier carrier,
    int generation,
  ) {
    unawaited(
      carrier.done.then(
        (_) => _carrierLost(record, generation),
        onError: (Object _) => _carrierLost(record, generation),
      ),
    );
  }

  /// The connection underneath a running tunnel died.
  Future<void> _carrierLost(_TunnelRecord record, int generation) async {
    // A carrier that has already been replaced is entitled to finish dying;
    // it just no longer speaks for this tunnel. Same guard, and the same
    // reason, as `SessionController._transportGeneration`.
    if (record.generation != generation) return;
    if (record.state == TunnelState.stopped) return;

    final dedicated = record.carrier?.isDedicated ?? false;
    record.deadCarrier = record.carrier?.identity;
    // Awaited, not fired and forgotten: whatever restarts this tunnel — a
    // re-dial below, or a session handing over a new transport — binds a new
    // listener and installs a new carrier, and a teardown still running at
    // that point would close them instead of the dead ones.
    await _teardown(record);
    if (record.generation != generation) return;

    record.state = TunnelState.error;
    if (dedicated) {
      record.message = 'The connection carrying this tunnel dropped. '
          'Reconnecting…';
      _publish(record);
      _scheduleRedial(record);
    } else {
      // The session owns the reconnect, and it already has a policy, a
      // banner and a Stop button for it. Duplicating that here would mean
      // two ladders dialling the same server; instead the tunnel waits for
      // the session to hand it a transport. See [_reviewCarriers].
      record.awaitingSession = true;
      record.message = 'The session carrying this tunnel dropped. It will '
          'start listening again as soon as that session reconnects.';
      _publish(record);
    }
  }

  /// A session changed. Any tunnel waiting for one to come back gets another
  /// look — this is the far end of `SessionController.adoptTransport`, which
  /// notifies on the stream this is subscribed to as soon as the replacement
  /// transport is in place.
  void _reviewCarriers() {
    if (_disposed) return;
    for (final record in _records.values.toList(growable: false)) {
      if (!record.awaitingSession) continue;
      final fresh = _support.findSessionCarrier?.call(record.profile.hostId);
      if (fresh == null || fresh.isClosed) continue;
      // The same dead transport reported again — the session has not
      // reconnected yet, it has merely changed in some other way.
      if (identical(fresh.identity, record.deadCarrier)) continue;
      record.awaitingSession = false;
      unawaited(_adopt(record, fresh));
    }
  }

  Future<void> _adopt(_TunnelRecord record, TunnelCarrier carrier) async {
    final generation = ++record.generation;
    record.state = TunnelState.starting;
    record.message = null;
    _publish(record);
    try {
      record.carrier = carrier;
      await _listen(record, carrier, generation);
    } catch (error) {
      await _failed(record, generation, _describe(error));
    }
  }

  void _scheduleRedial(_TunnelRecord record) {
    if (record.redialAttempt >= redialBackoff.length) {
      record.state = TunnelState.error;
      record.message = 'The connection carrying this tunnel dropped and could '
          'not be reopened. Start it again to retry.';
      _publish(record);
      return;
    }
    final delay = redialBackoff[record.redialAttempt++];
    record.retryTimer?.cancel();
    record.retryTimer = _retryScheduler(
      delay,
      () => unawaited(_redial(record)),
    );
  }

  Future<void> _redial(_TunnelRecord record) async {
    if (_disposed || record.state == TunnelState.stopped) return;
    final generation = ++record.generation;
    record.state = TunnelState.starting;
    _publish(record);
    try {
      final carrier = await _acquireCarrier(record.profile, null);
      if (record.generation != generation) {
        if (carrier.isDedicated) carrier.release();
        return;
      }
      record.carrier = carrier;
      await _listen(record, carrier, generation);
      record.redialAttempt = 0;
    } catch (error) {
      if (record.generation != generation) return;
      await _teardown(record);
      record.state = TunnelState.error;
      record.message = _describe(error);
      _publish(record);
      _scheduleRedial(record);
    }
  }

  // ------------------------------------------------------------- listening

  /// Binds (or asks the server to bind) and starts accepting.
  Future<void> _listen(
    _TunnelRecord record,
    TunnelCarrier carrier,
    int generation,
  ) async {
    final profile = record.profile;

    switch (profile.type) {
      case TunnelType.local:
        final server = await _bind(profile);
        if (record.generation != generation) {
          await server.close();
          return;
        }
        record.server = server;
        record.boundPort = server.port;
        record.accepts = server.listen(
          (socket) => unawaited(
            _handleLocalConnection(record, carrier, socket, generation),
          ),
          onError: (Object error) =>
              _noteConnectionFailure(record, generation, 'Listener: $error'),
        );

      case TunnelType.dynamic:
        final server = await _bind(profile);
        if (record.generation != generation) {
          await server.close();
          return;
        }
        record.server = server;
        record.boundPort = server.port;
        record.accepts = server.listen(
          (socket) => unawaited(
            _handleSocksConnection(record, carrier, socket, generation),
          ),
          onError: (Object error) =>
              _noteConnectionFailure(record, generation, 'Listener: $error'),
        );

      case TunnelType.remote:
        final listener = await carrier.forwardRemote(
          profile.remoteHost.trim(),
          profile.remotePort,
        );
        if (listener == null) {
          throw TunnelException(
            'The server refused to listen on port ${profile.remotePort}. '
            'Something may already be using it over there, or the server may '
            'have TCP forwarding disabled (AllowTcpForwarding), or it may only '
            'allow loopback binds (GatewayPorts).',
          );
        }
        if (record.generation != generation) {
          listener.close();
          return;
        }
        record.listener = listener;
        record.boundPort = listener.port;
        record.accepts = listener.connections.listen(
          (channel) => unawaited(
            _handleRemoteConnection(record, channel, generation),
          ),
          onError: (Object error) =>
              _noteConnectionFailure(record, generation, 'Listener: $error'),
        );
    }

    _watchCarrier(record, carrier, generation);
    record.state = TunnelState.active;
    record.message = null;
    record.dedicated = carrier.isDedicated;
    _publish(record);
    _ensureCounterTimer();
  }

  Future<ServerSocket> _bind(TunnelProfile profile) async {
    try {
      return await ServerSocket.bind(profile.localHost, profile.localPort);
    } on SocketException catch (e) {
      throw TunnelException(
        describeBindError(e, profile.localHost, profile.localPort),
      );
    }
  }

  // ----------------------------------------------------------- connections

  /// `ssh -L`: something connected to our listener, so ask the server to
  /// open the far end and join the two together.
  Future<void> _handleLocalConnection(
    _TunnelRecord record,
    TunnelCarrier carrier,
    Socket socket,
    int generation,
  ) async {
    final profile = record.profile;
    final SSHSocket channel;
    try {
      channel = await carrier.forwardLocal(
        profile.remoteHost,
        profile.remotePort,
      );
    } catch (_) {
      socket.destroy();
      _noteConnectionFailure(
        record,
        generation,
        'The server could not reach ${profile.remoteHost}:'
        '${profile.remotePort}.',
      );
      return;
    }
    _pump(
      record,
      generation,
      local: SocketTunnelEndpoint(socket),
      remote: ChannelTunnelEndpoint(channel),
    );
  }

  /// `ssh -R`: the server accepted a connection over there and handed it
  /// back, so dial the local target it is meant to reach.
  Future<void> _handleRemoteConnection(
    _TunnelRecord record,
    SSHSocket channel,
    int generation,
  ) async {
    final profile = record.profile;
    final Socket socket;
    try {
      socket = await Socket.connect(
        profile.localHost,
        profile.localPort,
        timeout: targetConnectTimeout,
      );
    } catch (_) {
      channel.destroy();
      _noteConnectionFailure(
        record,
        generation,
        'Nothing on this device answered on ${profile.localHost}:'
        '${profile.localPort}.',
      );
      return;
    }
    _pump(
      record,
      generation,
      local: SocketTunnelEndpoint(socket),
      remote: ChannelTunnelEndpoint(channel),
    );
  }

  /// `ssh -D`: run the SOCKS5 handshake ourselves, then forward wherever the
  /// client asked to go.
  Future<void> _handleSocksConnection(
    _TunnelRecord record,
    TunnelCarrier carrier,
    Socket socket,
    int generation,
  ) async {
    final reader = _HandshakeReader(socket);
    try {
      final head = await reader.read(2).timeout(socksHandshakeTimeout);
      final methods =
          await reader.read(head[1]).timeout(socksHandshakeTimeout);
      final greeting = Socks5Greeting.parse([...head, ...methods]);

      if (!greeting.offersNoAuth) {
        // A complete, legal refusal rather than a dropped connection: the
        // client is told there is no method it can use and closes, instead
        // of retrying against what looks like a flaky proxy.
        await _rejectSocks(
          socket,
          reader,
          socks5MethodSelection(Socks5.methodNone),
        );
        return;
      }
      socket.add(socks5MethodSelection(Socks5.methodNoAuth));

      final requestHead = await reader.read(4).timeout(socksHandshakeTimeout);
      final addressType = requestHead[3];
      if (addressType != Socks5.addressIpv4 &&
          addressType != Socks5.addressDomain &&
          addressType != Socks5.addressIpv6) {
        await _rejectSocks(
          socket,
          reader,
          socks5Reply(Socks5.replyAddressNotSupported),
        );
        return;
      }

      // A domain's length prefix has to be read before the rest of the
      // address can be, which is the one place the wire format is not a
      // fixed size.
      final List<int> address;
      if (addressType == Socks5.addressDomain) {
        final length = await reader.read(1).timeout(socksHandshakeTimeout);
        address = [
          ...length,
          ...await reader.read(length[0]).timeout(socksHandshakeTimeout),
        ];
      } else {
        address = await reader
            .read(socks5AddressLength(addressType, 0))
            .timeout(socksHandshakeTimeout);
      }
      final port = await reader.read(2).timeout(socksHandshakeTimeout);

      final request = Socks5Request.parse(
        [...requestHead, ...address, ...port],
      );
      if (!request.isConnect) {
        await _rejectSocks(
          socket,
          reader,
          socks5Reply(Socks5.replyCommandNotSupported),
        );
        return;
      }

      final SSHSocket channel;
      try {
        channel = await carrier.forwardLocal(request.host, request.port);
      } catch (_) {
        await _rejectSocks(
          socket,
          reader,
          socks5Reply(Socks5.replyHostUnreachable),
        );
        _noteConnectionFailure(
          record,
          generation,
          'The server could not reach ${request.host}:${request.port}.',
        );
        return;
      }

      socket.add(socks5Reply(Socks5.replySucceeded));
      _pump(
        record,
        generation,
        // The reader may be holding bytes the client pipelined behind its
        // CONNECT — an HTTP request sent without waiting for the reply is
        // the common case — so the pump reads from it rather than from the
        // socket, which would drop exactly those bytes.
        local: SocketTunnelEndpoint(socket, input: reader.release()),
        remote: ChannelTunnelEndpoint(channel),
      );
    } on Socks5FormatException {
      // Something that is not a SOCKS5 client. There is no reply that would
      // mean anything to it.
      await reader.dispose();
      socket.destroy();
    } on TimeoutException {
      await reader.dispose();
      socket.destroy();
    } catch (_) {
      await reader.dispose();
      socket.destroy();
    }
  }

  /// Sends a final SOCKS reply and closes, best-effort.
  Future<void> _rejectSocks(
    Socket socket,
    _HandshakeReader reader,
    Uint8List reply,
  ) async {
    try {
      socket.add(reply);
      // Flushed before the destroy so the refusal actually reaches the
      // client rather than dying in this process's buffer.
      await socket.flush();
    } catch (_) {
      // The client hung up first, which is its right.
    }
    await reader.dispose();
    socket.destroy();
  }

  void _pump(
    _TunnelRecord record,
    int generation, {
    required TunnelEndpoint local,
    required TunnelEndpoint remote,
  }) {
    if (record.generation != generation) {
      local.destroy();
      remote.destroy();
      return;
    }
    final connection = TunnelConnection(local: local, remote: remote);
    record.live.add(connection);
    record.totalConnections++;
    _publish(record);

    unawaited(
      connection.pump(
        onUp: (bytes) {
          record.bytesUp += bytes;
          record.countersDirty = true;
        },
        onDown: (bytes) {
          record.bytesDown += bytes;
          record.countersDirty = true;
        },
      ).whenComplete(() {
        record.live.remove(connection);
        _publish(record);
      }),
    );
  }

  /// One connection failed while the tunnel itself is still fine. Recorded as
  /// a note on the row rather than as an error state — the listener is up,
  /// and the next connection may well work.
  void _noteConnectionFailure(
    _TunnelRecord record,
    int generation,
    String message,
  ) {
    if (record.generation != generation) return;
    if (record.state != TunnelState.active) return;
    record.message = 'Last connection failed: $message';
    _publish(record);
  }

  // ---------------------------------------------------------------- state

  Future<void> _failed(
    _TunnelRecord record,
    int generation,
    String message,
  ) async {
    if (record.generation != generation) return;
    await _teardown(record);
    record.state = TunnelState.error;
    record.message = message;
    _publish(record);
  }

  /// Closes everything this tunnel owns. The carrier goes only if it was
  /// ours — see the class doc.
  ///
  /// Every handle is taken off the record *before* the first await. A
  /// teardown that read them afterwards would be reading whatever a restart
  /// had put there in the meantime, and would then close a listener that had
  /// only just come up.
  Future<void> _teardown(_TunnelRecord record) async {
    final accepts = record.accepts;
    final listener = record.listener;
    final server = record.server;
    final carrier = record.carrier;
    final live = record.live.toList(growable: false);

    record.retryTimer?.cancel();
    record.retryTimer = null;
    record.accepts = null;
    record.listener = null;
    record.server = null;
    record.carrier = null;
    record.live.clear();

    for (final connection in live) {
      connection.destroy();
    }
    listener?.close();
    if (carrier != null && carrier.isDedicated) carrier.release();

    await accepts?.cancel();
    try {
      await server?.close();
    } catch (_) {
      // Already closed.
    }
  }

  String _describe(Object error) {
    if (error is TunnelException) return error.message;
    if (error is SshConnectionException) return error.message;
    if (error is SocketException) {
      return error.osError?.message ?? error.message;
    }
    return 'The tunnel could not be started: $error';
  }

  void _ensureCounterTimer() {
    _counterTimer ??= _counterScheduler(counterInterval, (_) => _tick());
  }

  void _tick() {
    var running = false;
    for (final record in _records.values) {
      if (record.state == TunnelState.active ||
          record.state == TunnelState.starting) {
        running = true;
      }
      if (!record.countersDirty) continue;
      record.countersDirty = false;
      _publish(record);
    }
    // Nothing left to count. The timer is rebuilt by the next start.
    if (!running) {
      _counterTimer?.cancel();
      _counterTimer = null;
    }
  }

  TunnelStatus _snapshot(_TunnelRecord record) => TunnelStatus(
        profileId: record.profile.id,
        state: record.state,
        message: record.message,
        connections: record.live.length,
        totalConnections: record.totalConnections,
        bytesUp: record.bytesUp,
        bytesDown: record.bytesDown,
        boundPort: record.boundPort,
        dedicated: record.dedicated,
        awaitingSession: record.awaitingSession,
      );

  void _publish(_TunnelRecord record) {
    if (_changes.isClosed) return;
    _changes.add(_snapshot(record));
  }
}

/// How the runtime waits out a re-dial delay. Injected purely so a test can
/// fire the timer by hand; production passes `Timer.new`, which is exactly
/// this signature.
typedef TunnelRetryScheduler = Timer Function(
  Duration delay,
  void Function() fire,
);

/// The mutable half of a tunnel: everything that changes while it runs.
///
/// Kept out of [TunnelStatus] on purpose — the status is a snapshot the UI
/// holds on to, and these are sockets and counters that must not be reachable
/// from it.
class _TunnelRecord {
  _TunnelRecord(this.profile);

  TunnelProfile profile;

  TunnelState state = TunnelState.stopped;
  String? message;
  int? boundPort;
  bool dedicated = false;
  bool awaitingSession = false;

  int totalConnections = 0;
  int bytesUp = 0;
  int bytesDown = 0;

  /// Set by the pumps, cleared by the publish tick. See
  /// [TunnelRuntime.counterInterval].
  bool countersDirty = false;

  TunnelCarrier? carrier;

  /// The identity of the carrier that died, so a session that merely changed
  /// is not mistaken for one that reconnected.
  Object? deadCarrier;

  ServerSocket? server;
  TunnelRemoteListener? listener;
  StreamSubscription<void>? accepts;
  final Set<TunnelConnection> live = {};

  int redialAttempt = 0;
  Timer? retryTimer;

  /// Which incarnation of this tunnel is current. Everything asynchronous
  /// captures the value it started with and does nothing if it has moved on.
  int generation = 0;

  void reset() {
    message = null;
    boundPort = null;
    awaitingSession = false;
    deadCarrier = null;
    totalConnections = 0;
    bytesUp = 0;
    bytesDown = 0;
    countersDirty = false;
  }
}

/// Reads exactly-sized pieces off a client socket during the SOCKS5
/// handshake, then hands the rest of the stream over for pumping.
///
/// Hand-rolled because `package:async`'s `StreamQueue` would do this and is
/// not a dependency of this app — one buffered reader is a poor reason to add
/// one. The subtlety it exists for is the handover: the socket's stream can
/// only be listened to once, so the pump cannot simply re-listen, and
/// anything the client pipelined behind its CONNECT has to be replayed ahead
/// of the rest.
class _HandshakeReader {
  _HandshakeReader(Stream<Uint8List> source) {
    _rest = StreamController<Uint8List>(
      // Backpressure survives the handover: pausing the pumped stream pauses
      // the socket underneath it, rather than buffering in here forever.
      onPause: () => _subscription?.pause(),
      onResume: () => _subscription?.resume(),
      onCancel: () => _subscription?.cancel(),
    );
    _subscription = source.listen(_onData, onError: _onError, onDone: _onDone);
  }

  late final StreamController<Uint8List> _rest;
  StreamSubscription<Uint8List>? _subscription;

  /// Only ever holds a handshake's worth — see [Socks5.maxRequestBytes] —
  /// plus whatever the client pipelined behind it.
  List<int> _buffer = [];

  Completer<void>? _waiting;
  Object? _error;
  var _done = false;
  var _relaying = false;

  void _onData(Uint8List chunk) {
    if (_relaying) {
      _rest.add(chunk);
      return;
    }
    _buffer.addAll(chunk);
    _wake();
  }

  void _onError(Object error) {
    if (_relaying) {
      _rest.addError(error);
      return;
    }
    _error = error;
    _wake();
  }

  void _onDone() {
    _done = true;
    if (_relaying) {
      unawaited(_rest.close());
      return;
    }
    _wake();
  }

  void _wake() {
    final waiting = _waiting;
    _waiting = null;
    if (waiting != null && !waiting.isCompleted) waiting.complete();
  }

  /// Exactly [count] bytes, waiting for them to arrive.
  Future<Uint8List> read(int count) async {
    while (_buffer.length < count) {
      final error = _error;
      if (error != null) throw Socks5FormatException('$error');
      if (_done) {
        throw const Socks5FormatException(
          'The client closed before it said where it wanted to go.',
        );
      }
      await (_waiting = Completer<void>()).future;
    }
    final out = Uint8List.fromList(_buffer.sublist(0, count));
    _buffer = _buffer.sublist(count);
    return out;
  }

  /// The rest of the client's bytes, anything already buffered first.
  Stream<Uint8List> release() {
    _relaying = true;
    if (_buffer.isNotEmpty) {
      _rest.add(Uint8List.fromList(_buffer));
      _buffer = [];
    }
    if (_error != null) _rest.addError(_error!);
    if (_done) unawaited(_rest.close());
    return _rest.stream;
  }

  /// Abandons the socket without ever handing it on.
  Future<void> dispose() async {
    final subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();
    // Never awaited: `StreamController.close()` hands back `done`, and on a
    // single-subscription controller nobody ever listened to — which is
    // exactly this case, since the handshake failed before [release] — that
    // future does not complete. Awaiting it hangs the refusal we are in the
    // middle of sending.
    if (!_rest.isClosed) unawaited(_rest.close());
  }
}

/// Turns a failed [ServerSocket.bind] into something worth reading.
///
/// A pure function of the exception so the three cases that actually happen —
/// the port is taken, the port is privileged, the address is not on this
/// device — can be tested without arranging each one. The OS error codes are
/// checked alongside the message text because the text is localised on
/// Windows and the codes are not.
String describeBindError(SocketException error, String host, int port) {
  final code = error.osError?.errorCode;
  final text = (error.osError?.message ?? error.message).toLowerCase();

  // EADDRINUSE: 98 on Linux, 48 on macOS, 10048 on Windows. The "shared
  // flag" wording is dart:io's own: it intercepts the collision before the
  // OS error reaches us and reports it as an API misuse, with no [OSError]
  // attached at all — so the phrase is the only thing left to match on.
  if (code == 98 ||
      code == 48 ||
      code == 10048 ||
      text.contains('address already in use') ||
      text.contains('shared flag') ||
      text.contains('normally permitted')) {
    return 'Port $port is already in use on $host. Something else is '
        'listening there — choose another port, or stop whatever has it.';
  }

  // EACCES: 13 everywhere but Windows, where it is WSAEACCES 10013.
  if (code == 13 || code == 10013 || text.contains('permission denied')) {
    return port < TunnelProfile.privilegedPortCeiling
        ? 'Port $port is privileged: ports below '
            '${TunnelProfile.privilegedPortCeiling} need administrator rights '
            'to listen on. Choose a port above that.'
        : 'This device refused to let the app listen on $host:$port.';
  }

  // EADDRNOTAVAIL: 99 on Linux, 49 on macOS, 10049 on Windows.
  if (code == 99 ||
      code == 49 ||
      code == 10049 ||
      text.contains('cannot assign requested address')) {
    return 'No network interface on this device has the address $host, so '
        'nothing can listen there. 127.0.0.1 always works.';
  }

  return 'Could not listen on $host:$port. '
      '${error.osError?.message ?? error.message}';
}
