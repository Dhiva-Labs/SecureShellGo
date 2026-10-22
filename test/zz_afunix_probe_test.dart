import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Probe only: which AF_UNIX step takes a Windows runner down.
void main() {
  Future<(Directory, InternetAddress)> place() async {
    final dir = await Directory.systemTemp.createTemp('afunix_probe');
    return (dir, InternetAddress('${dir.path}/sock', type: InternetAddressType.unix));
  }

  test('bind only', () async {
    final (dir, address) = await place();
    final server = await ServerSocket.bind(address, 0);
    await server.close();
    print('bound and closed ${address.address}');
  });

  test('bind and connect, no data', () async {
    final (dir, address) = await place();
    final server = await ServerSocket.bind(address, 0);
    final accepted = server.first;
    final client = await Socket.connect(address, 0);
    final peer = await accepted;
    print('connected');
    client.destroy();
    peer.destroy();
    await server.close();
  });

  test('bind, connect and exchange bytes, both ends closed', () async {
    final (dir, address) = await place();
    final server = await ServerSocket.bind(address, 0);
    server.listen((peer) {
      peer.listen((data) {
        peer.add(data);
      }, onDone: peer.destroy);
    });
    final client = await Socket.connect(address, 0);
    final reply = client.first;
    client.add([1, 2, 3]);
    await client.flush();
    expect(await reply, [1, 2, 3]);
    client.destroy();
    await server.close();
    print('exchanged');
  });

  test('as the agent test does: server end left open, folder deleted', () async {
    final (dir, address) = await place();
    final server = await ServerSocket.bind(address, 0);
    server.listen((peer) {
      peer.listen((data) async {
        peer.add(data);
        await peer.flush();
      });
    });
    final client = await Socket.connect(address, 0);
    final reply = client.first;
    client.add([1, 2, 3]);
    await client.flush();
    expect(await reply, [1, 2, 3]);
    client.destroy();
    await server.close();
    await dir.delete(recursive: true);
    print('exchanged and deleted');
  });
}
