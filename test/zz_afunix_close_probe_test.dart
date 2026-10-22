import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Probe only: does a graceful close of an AF_UNIX client, with the server's
/// end still open, take a Windows runner down?
void main() {
  late Directory dir;
  Future<(Socket, Socket, ServerSocket)> pair() async {
    dir = await Directory.systemTemp.createTemp('afunix_close');
    final address =
        InternetAddress('${dir.path}/sock', type: InternetAddressType.unix);
    final server = await ServerSocket.bind(address, 0);
    final accepted = Completer<Socket>();
    server.listen(accepted.complete);
    final client = await Socket.connect(address, 0);
    final peer = await accepted.future;
    return (client, peer, server);
  }

  test('cancel the read, then close, while the peer stays open', () async {
    final (client, peer, server) = await pair();
    final got = Completer<List<int>>();
    final sub = client.listen(got.complete);
    peer.add([1, 2, 3]);
    await peer.flush();
    expect(await got.future, [1, 2, 3]);
    await sub.cancel();
    await client.close();
    print('closed with the peer open');
    await Future<void>.delayed(const Duration(seconds: 2));
    await server.close();
  });

  test('close while still reading, while the peer stays open', () async {
    final (client, peer, server) = await pair();
    final got = Completer<List<int>>();
    client.listen((d) { if (!got.isCompleted) got.complete(d); });
    peer.add([1, 2, 3]);
    await peer.flush();
    expect(await got.future, [1, 2, 3]);
    await client.close();
    print('closed while reading, peer open');
    await Future<void>.delayed(const Duration(seconds: 2));
    await server.close();
  });

  test('close, then delete the folder, while the peer stays open', () async {
    final (client, peer, server) = await pair();
    final got = Completer<List<int>>();
    final sub = client.listen(got.complete);
    peer.add([1, 2, 3]);
    await peer.flush();
    expect(await got.future, [1, 2, 3]);
    await sub.cancel();
    await client.close();
    await server.close();
    await dir.delete(recursive: true);
    print('closed and deleted with the peer open');
    await Future<void>.delayed(const Duration(seconds: 2));
  });
}
