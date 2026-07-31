import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'ssh_service.dart';

/// A listening socket the *server* opened on our behalf (`tcpip-forward`).
abstract class TunnelRemoteListener {
  /// The port the server actually bound. Asking for 0 means "choose one",
  /// and this is how the user finds out which one it chose.
  int get port;

  /// One [SSHSocket] per connection the server accepted over there.
  Stream<SSHSocket> get connections;

  void close();
}

/// The forwarding primitives a tunnel needs from a live SSH connection, and
/// nothing else.
///
/// An interface rather than an [SSHClient] for the reason every other seam in
/// `services/` is one: dartssh2's client cannot be faked usefully, and a
/// tunnel's interesting behaviour — half-close, byte counting, what happens
/// when the transport dies underneath it — is all on this side of it. See
/// `test/tunnel_runtime_test.dart`, which runs whole forwards over loopback
/// with no SSH server anywhere.
///
/// A carrier is either *borrowed* from a live session or *dedicated* to the
/// tunnel that opened it, and that distinction decides exactly one thing:
/// who is allowed to close the connection. See [release].
abstract class TunnelCarrier {
  /// Stands for the underlying transport, so the runtime can tell a
  /// reconnected session's *new* transport from the dead one it is replacing
  /// without holding a reference to either. Compared with [identical].
  Object get identity;

  bool get isClosed;

  /// Completes when this carrier's connection goes away, for any reason.
  Future<void> get done;

  /// True when this connection was opened for the tunnel and belongs to it.
  bool get isDedicated;

  /// Opens a `direct-tcpip` channel from the server to [host]:[port].
  Future<SSHSocket> forwardLocal(String host, int port);

  /// Asks the server to listen on [host]:[port] and hand back what it
  /// accepts. Null when the server refused — a port already in use over
  /// there, or `AllowTcpForwarding no`.
  Future<TunnelRemoteListener?> forwardRemote(String host, int port);

  /// Closes the connection, but only when this carrier owns it. A borrowed
  /// carrier's [release] is a no-op: the session owns that transport, its
  /// shell is very likely sitting on the other end of it, and stopping a
  /// tunnel is not permission to hang up on the user's terminal.
  void release();
}

/// A [TunnelCarrier] over a real dartssh2 client.
class SshTunnelCarrier implements TunnelCarrier {
  /// Rides on a connection that belongs to somebody else — a live session's
  /// transport, which is what the user gets when a tunnel is started for a
  /// host they are already connected to. No second authentication, no second
  /// host-key prompt, and the forward dies with the session.
  SshTunnelCarrier.borrowed(SSHClient client)
      : _client = client,
        _owned = null;

  /// Rides on a connection opened for this tunnel alone, which the tunnel is
  /// then responsible for closing.
  SshTunnelCarrier.dedicated(SshConnection connection)
      : _client = connection.client,
        _owned = connection;

  final SSHClient _client;
  final SshConnection? _owned;

  @override
  Object get identity => _client;

  @override
  bool get isClosed => _client.isClosed;

  @override
  Future<void> get done => _client.done;

  @override
  bool get isDedicated => _owned != null;

  @override
  Future<SSHSocket> forwardLocal(String host, int port) =>
      _client.forwardLocal(host, port);

  @override
  Future<TunnelRemoteListener?> forwardRemote(String host, int port) async {
    final forward = await _client.forwardRemote(host: host, port: port);
    if (forward == null) return null;
    return _SshRemoteListener(forward);
  }

  @override
  void release() {
    // Closes the SSH client, its socket and any jump chain behind it — see
    // [SshConnection.close].
    _owned?.close();
  }
}

class _SshRemoteListener implements TunnelRemoteListener {
  _SshRemoteListener(this._forward);

  final SSHRemoteForward _forward;

  @override
  int get port => _forward.port;

  @override
  Stream<SSHSocket> get connections => _forward.connections;

  @override
  void close() {
    try {
      _forward.close();
    } catch (_) {
      // The connection is already gone, which is the usual way a remote
      // forward ends; there is nothing left to cancel over there.
    }
  }
}

/// One end of a tunnelled connection: bytes in, bytes out, and — the part
/// that matters — a way to say "nothing more from me" without killing the
/// direction still carrying replies.
abstract class TunnelEndpoint {
  Stream<Uint8List> get input;

  /// Writes [data] through, respecting the sink's own backpressure. A stream
  /// rather than per-chunk `add` calls on purpose: `IOSink.addStream` pauses
  /// its source when the far side is not keeping up, which is what stops a
  /// fast local client from queueing an entire file in this process's heap
  /// while the SSH channel's window is closed.
  Future<void> addStream(Stream<List<int>> data);

  /// Half-close: sends EOF and leaves [input] alive.
  Future<void> closeOutput();

  void destroy();
}

/// A tunnel endpoint over a local TCP socket.
class SocketTunnelEndpoint implements TunnelEndpoint {
  /// [input] overrides where the incoming bytes are read from. The SOCKS5
  /// proxy needs it: by the time the destination is known, the handshake
  /// reader has already taken the socket's stream and may be holding bytes
  /// the client pipelined behind its `CONNECT`.
  SocketTunnelEndpoint(Socket socket, {Stream<Uint8List>? input})
      : _socket = socket,
        _input = input ?? socket;

  final Socket _socket;
  final Stream<Uint8List> _input;

  @override
  Stream<Uint8List> get input => _input;

  @override
  Future<void> addStream(Stream<List<int>> data) async {
    await _socket.addStream(data);
  }

  @override
  Future<void> closeOutput() async {
    // `Socket.close()` shuts down the outgoing half and sends FIN; the
    // incoming half keeps delivering until the peer does the same.
    await _socket.close();
  }

  @override
  void destroy() {
    try {
      _socket.destroy();
    } catch (_) {
      // Already gone.
    }
  }
}

/// A tunnel endpoint over a forwarded SSH channel.
class ChannelTunnelEndpoint implements TunnelEndpoint {
  ChannelTunnelEndpoint(this.channel);

  final SSHSocket channel;

  @override
  Stream<Uint8List> get input => channel.stream;

  @override
  Future<void> addStream(Stream<List<int>> data) async {
    await channel.sink.addStream(data);
  }

  @override
  Future<void> closeOutput() async {
    // Closing the sink sends channel EOF, which is the SSH equivalent of a
    // FIN: the far end may still write back, and does, for the whole of an
    // HTTP response to a request that ended with a shutdown.
    await channel.sink.close();
  }

  @override
  void destroy() {
    try {
      channel.destroy();
    } catch (_) {
      // Already gone.
    }
  }
}

/// One live connection inside a tunnel, and the pump moving its bytes.
class TunnelConnection {
  TunnelConnection({required this.local, required this.remote});

  final TunnelEndpoint local;
  final TunnelEndpoint remote;

  /// Runs both directions until each has ended, then tears the pair down.
  ///
  /// [onUp] and [onDown] are handed byte *counts* and never the bytes. That
  /// is the whole of this app's forwarded-payload policy: the runtime keeps
  /// totals so the UI can show throughput, and nothing anywhere in the
  /// tunnel path is in a position to log, buffer or inspect what a tunnel
  /// carries.
  Future<void> pump({
    required void Function(int bytes) onUp,
    required void Function(int bytes) onDown,
  }) async {
    await Future.wait([
      _relay(local, remote, onUp),
      _relay(remote, local, onDown),
    ]);
    destroy();
  }

  void destroy() {
    local.destroy();
    remote.destroy();
  }

  /// Moves everything [from] produces into [to], then propagates EOF.
  ///
  /// The two calls in [pump] are deliberately independent: each finishes when
  /// *its* source ends, and closes only the output it was writing to. A pump
  /// that tore both directions down on the first EOF would truncate every
  /// protocol whose client shuts down its write side and then reads the
  /// answer — which is most of them, and all of `nc -N`, `git`, and an HTTP
  /// request without keep-alive.
  static Future<void> _relay(
    TunnelEndpoint from,
    TunnelEndpoint to,
    void Function(int bytes) count,
  ) async {
    try {
      await to.addStream(
        from.input.map((chunk) {
          count(chunk.length);
          return chunk;
        }),
      );
    } catch (_) {
      // A reset, or a channel torn down mid-stream. One connection inside a
      // tunnel failing is not the tunnel failing — the listener is still up
      // and the next connection is unaffected — so this is not surfaced.
    }
    try {
      await to.closeOutput();
    } catch (_) {
      // The far end has already closed; the EOF has nowhere to go.
    }
  }
}
