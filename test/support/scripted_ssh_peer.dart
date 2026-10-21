import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
// The connection-layer messages are not part of dartssh2's public surface.
// This file builds the server's half of them, in tests only, so that a
// real SSHClient can be driven through channel opens and requests without
// a server — see [ScriptedSshPeer].
// ignore: implementation_imports
import 'package:dartssh2/src/message/msg_channel.dart';
// ignore: implementation_imports
import 'package:dartssh2/src/message/msg_userauth.dart';
// ignore: implementation_imports
import 'package:dartssh2/src/ssh_message.dart';

/// The server end of a real [SSHClient], at the connection layer.
///
/// No key exchange ever happens: the client's socket is [socket], which
/// never says anything, and everything the server would say is handed to
/// the client through its `@visibleForTesting` [SSHClient.handlePacket].
/// What the client sends is read off its `printTrace`, which names every
/// message on the way out — the transport itself holds those packets back
/// until a key exchange that never comes, which is fine, because nothing
/// is listening.
///
/// It plays OpenSSH where that matters: `auth-agent-req@openssh.com` is
/// granted once per connection and refused after that, and every other
/// request succeeds unless a test says otherwise.
class ScriptedSshPeer {
  /// Pass to the client's `printTrace`.
  void trace(String? line) {
    if (line == null || !line.startsWith('-> ')) return;
    sent.add(line);
    // Replies arrive later, as they would from a network.
    scheduleMicrotask(() => _react(line));
  }

  /// The client's socket: silent, and swallowing what it is sent.
  final SSHSocket socket = _SilentSocket();

  late final SSHClient client;

  /// Every message the client sent, as its trace printed it.
  final List<String> sent = [];

  /// The requests on each session channel, by the server's channel id, in
  /// the order they arrived.
  final Map<int, List<String>> requests = {};

  /// The server's channel id for each of the client's.
  final Map<int, int> _serverIdOf = {};
  final Map<int, int> _clientIdOf = {};
  var _nextServerId = 100;

  var agentGranted = false;
  var refuseAgent = false;

  /// Grant the agent on every channel, as Dropbear does, rather than once
  /// per connection, as OpenSSH does.
  var grantAgentPerChannel = false;
  var refuseX11 = false;

  /// The session channels' request lists, in the order they were opened.
  List<List<String>> get sessionRequests =>
      [for (final id in requests.keys.toList()..sort()) requests[id]!];

  /// Whatever the client sent that named [needle].
  Iterable<String> sentContaining(String needle) =>
      sent.where((line) => line.contains(needle));

  void deliver(SSHMessage message) => client.handlePacket(message.encode());

  /// The login is over, as far as the client is concerned.
  void authenticate() => deliver(SSH_Message_Userauth_Success());

  /// The server opens a channel of [type] towards the client — what sshd
  /// does when something on it uses the forwarded agent or X display.
  /// Returns the server's id for it.
  int openChannel(String type) {
    final id = _nextServerId++;
    deliver(SSH_Message_Channel_Open(
      channelType: type,
      senderChannel: id,
      initialWindowSize: 1 << 20,
      maximumPacketSize: 1 << 15,
      originatorIP: type == 'x11' ? '127.0.0.1' : null,
      originatorPort: type == 'x11' ? 40000 : null,
    ));
    return id;
  }

  /// The client's id for the server's channel [serverId], once the client
  /// has confirmed it.
  int clientIdOf(int serverId) {
    final line = sentContaining(
      'SSH_Message_Channel_Confirmation(recipientChannel: $serverId,',
    ).single;
    return int.parse(RegExp(r'senderChannel: (\d+)').firstMatch(line)!.group(1)!);
  }

  /// Sends [data] to the client on the server's channel [serverId].
  void sendData(int serverId, List<int> data) => deliver(SSH_Message_Channel_Data(
        recipientChannel: clientIdOf(serverId),
        data: Uint8List.fromList(data),
      ));

  void _react(String line) {
    if (line.contains('SSH_Message_Channel_Open(channelType: session,')) {
      final clientId = _field(line, 'senderChannel');
      final serverId = _nextServerId++;
      _serverIdOf[clientId] = serverId;
      _clientIdOf[serverId] = clientId;
      requests[serverId] = [];
      deliver(SSH_Message_Channel_Confirmation(
        recipientChannel: clientId,
        senderChannel: serverId,
        initialWindowSize: 1 << 20,
        maximumPacketSize: 1 << 15,
        data: Uint8List(0),
      ));
      return;
    }
    if (line.contains('SSH_Message_Channel_Request(')) {
      final serverId = _field(line, 'recipientChannel');
      final clientId = _clientIdOf[serverId];
      if (clientId == null) return;
      final type = RegExp(r'requestType: ([^,)]+)').firstMatch(line)!.group(1)!;
      requests[serverId]!.add(type);
      if (!line.contains('wantReply: true')) return;
      final bool ok;
      switch (type) {
        case 'auth-agent-req@openssh.com':
          ok = !refuseAgent && (grantAgentPerChannel || !agentGranted);
          if (ok) agentGranted = true;
        case 'x11-req':
          ok = !refuseX11;
        default:
          ok = true;
      }
      deliver(ok
          ? SSH_Message_Channel_Success(recipientChannel: clientId)
          : SSH_Message_Channel_Failure(recipientChannel: clientId));
    }
  }

  static int _field(String line, String name) =>
      int.parse(RegExp('$name: (\\d+)').firstMatch(line)!.group(1)!);
}

class _SilentSocket implements SSHSocket {
  final _incoming = StreamController<Uint8List>();
  final _outgoing = StreamController<List<int>>();
  final _done = Completer<void>();

  _SilentSocket() {
    _outgoing.stream.drain<void>();
  }

  @override
  Stream<Uint8List> get stream => _incoming.stream;

  @override
  StreamSink<List<int>> get sink => _outgoing.sink;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> close() async {
    if (!_done.isCompleted) _done.complete();
  }

  @override
  void destroy() {
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Future<void> flush() async {}
}
