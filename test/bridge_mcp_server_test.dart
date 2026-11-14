import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/app_version.dart';
import 'package:secure_shell_go/services/bridge/bridge_channel.dart';
import 'package:secure_shell_go/services/bridge/bridge_client_store.dart';
import 'package:secure_shell_go/services/bridge/bridge_tool_types.dart';
import 'package:secure_shell_go/services/bridge/mcp_server.dart';

final _client = BridgeClient(
  id: 'c1',
  name: 'Desk assistant',
  tokenHash: 'unused',
  createdAt: DateTime.utc(2026),
);

class _FakeConnection implements BridgeConnection {
  final incoming = StreamController<String>();
  final sent = <String>[];
  bool closed = false;

  @override
  BridgeClient get client => _client;

  @override
  Stream<String> get lines => incoming.stream;

  @override
  void send(String line) {
    expect(line, isNot(contains('\n')));
    sent.add(line);
  }

  @override
  Future<void> close() async => closed = true;
}

class _FakeTools implements BridgeToolHost {
  final calls = <(BridgeClient, String, Map<String, Object?>)>[];
  Completer<void>? gate;

  @override
  List<BridgeToolSpec> get tools => const [
    BridgeToolSpec(
      name: 'list_hosts',
      description: 'Lists the shared hosts.',
      inputSchema: {'type': 'object', 'properties': <String, Object?>{}},
      kind: BridgeToolKind.read,
    ),
    BridgeToolSpec(
      name: 'restart_service',
      description: 'Not in 1.6.0; here to test the annotation.',
      inputSchema: {'type': 'object'},
      kind: BridgeToolKind.change,
    ),
    BridgeToolSpec(
      name: 'explode',
      description: 'Throws.',
      inputSchema: {'type': 'object'},
      kind: BridgeToolKind.read,
    ),
  ];

  @override
  Future<BridgeToolResult> call(
    BridgeClient client,
    String name,
    Map<String, Object?> args,
  ) async {
    calls.add((client, name, args));
    await gate?.future;
    if (name == 'explode') throw StateError('secret detail');
    if (args['fail'] == true) return const BridgeToolResult.error('refused');
    return BridgeToolResult('ran $name');
  }
}

class _ThrowingList implements BridgeToolHost {
  @override
  List<BridgeToolSpec> get tools => throw StateError('boom');

  @override
  Future<BridgeToolResult> call(
    BridgeClient c,
    String n,
    Map<String, Object?> a,
  ) => throw UnimplementedError();
}

void main() {
  late _FakeTools tools;
  late McpServer server;
  late _FakeConnection conn;

  setUp(() {
    tools = _FakeTools();
    server = McpServer(tools: tools, serverVersion: '9.9.9');
    conn = _FakeConnection();
  });

  Future<Map<String, Object?>?> rpc(Object message) async {
    final reply = await server.handleLine(conn, jsonEncode(message));
    return reply == null ? null : jsonDecode(reply) as Map<String, Object?>;
  }

  Map<String, Object?> request(Object id, String method, [Object? params]) => {
    'jsonrpc': '2.0',
    'id': id,
    'method': method,
    'params': ?params,
  };

  group('initialize', () {
    for (final version in mcpSupportedProtocolVersions) {
      test('answers with the client\'s version $version', () async {
        final reply = await rpc(
          request(1, 'initialize', {
            'protocolVersion': version,
            'capabilities': <String, Object?>{},
            'clientInfo': {'name': 'x', 'version': '1'},
          }),
        );
        final result = reply!['result'] as Map;
        expect(reply['id'], 1);
        expect(result['protocolVersion'], version);
      });
    }

    test('answers with the newest version for one it does not know', () async {
      final reply = await rpc(
        request(1, 'initialize', {'protocolVersion': '2099-01-01'}),
      );
      expect((reply!['result'] as Map)['protocolVersion'], '2025-06-18');
    });

    test('carries capabilities, server info and instructions', () async {
      final reply = await rpc(
        request('a', 'initialize', {'protocolVersion': '2025-06-18'}),
      );
      expect(reply!['jsonrpc'], '2.0');
      expect(reply['id'], 'a');
      final result = reply['result'] as Map;
      expect(result['capabilities'], {'tools': <String, Object?>{}});
      expect(result['serverInfo'], {
        'name': 'secureshellgo',
        'version': '9.9.9',
      });
      expect(result['instructions'], isA<String>());
      expect(result['instructions'], contains('list_hosts'));
    });

    test('defaults the server version to the app version', () async {
      final reply = await McpServer(tools: tools).handleLine(
        conn,
        jsonEncode(request(1, 'initialize', {'protocolVersion': '2025-06-18'})),
      );
      expect(reply, contains('"version":"$appDisplayVersion"'));
    });

    test('a missing protocolVersion is bad params', () async {
      final reply = await rpc(request(1, 'initialize', <String, Object?>{}));
      expect((reply!['error'] as Map)['code'], -32602);
    });
  });

  test('notifications/initialized gets no reply', () async {
    expect(
      await rpc({'jsonrpc': '2.0', 'method': 'notifications/initialized'}),
      isNull,
    );
  });

  test('an unknown notification gets no reply either', () async {
    expect(await rpc({'jsonrpc': '2.0', 'method': 'no/such'}), isNull);
  });

  test('ping answers an empty result', () async {
    expect(await rpc(request(7, 'ping')), {
      'jsonrpc': '2.0',
      'id': 7,
      'result': <String, Object?>{},
    });
  });

  test('tools/list lists every tool, read-only ones annotated', () async {
    final reply = await rpc(request(2, 'tools/list'));
    final list = (reply!['result'] as Map)['tools'] as List;
    expect(list, hasLength(3));
    expect(list[0], {
      'name': 'list_hosts',
      'description': 'Lists the shared hosts.',
      'inputSchema': {'type': 'object', 'properties': <String, Object?>{}},
      'annotations': {'readOnlyHint': true},
    });
    expect((list[1] as Map).containsKey('annotations'), isFalse);
  });

  test('tools/list ignores a cursor (one page)', () async {
    final reply = await rpc(request(2, 'tools/list', {'cursor': 'x'}));
    expect((reply!['result'] as Map)['tools'], hasLength(3));
  });

  group('tools/call', () {
    test('runs the tool for the connection\'s client', () async {
      final reply = await rpc(
        request(3, 'tools/call', {
          'name': 'list_hosts',
          'arguments': {'a': 1},
        }),
      );
      expect(reply!['result'], {
        'content': [
          {'type': 'text', 'text': 'ran list_hosts'},
        ],
        'isError': false,
      });
      expect(tools.calls.single.$1.id, 'c1');
      expect(tools.calls.single.$3, {'a': 1});
    });

    test('missing arguments are an empty map', () async {
      await rpc(request(3, 'tools/call', {'name': 'list_hosts'}));
      expect(tools.calls.single.$3, isEmpty);
    });

    test('a tool error is a result with isError, not an RPC error', () async {
      final reply = await rpc(
        request(3, 'tools/call', {
          'name': 'list_hosts',
          'arguments': {'fail': true},
        }),
      );
      final result = reply!['result'] as Map;
      expect(result['isError'], true);
      expect((result['content'] as List).single['text'], 'refused');
    });

    test('a throwing tool is an error result without the exception', () async {
      final reply = await rpc(request(3, 'tools/call', {'name': 'explode'}));
      final result = reply!['result'] as Map;
      expect(result['isError'], true);
      expect(jsonEncode(result), isNot(contains('secret detail')));
    });

    test('an unknown tool is -32602 and is never called', () async {
      final reply = await rpc(request(3, 'tools/call', {'name': 'rm_rf'}));
      expect((reply!['error'] as Map)['code'], -32602);
      expect((reply['error'] as Map)['message'], contains('rm_rf'));
      expect(tools.calls, isEmpty);
    });

    test('bad params are -32602', () async {
      for (final params in [
        <String, Object?>{},
        {'name': 5},
        {'name': 'list_hosts', 'arguments': 'x'},
        {'name': 'list_hosts', 'arguments': []},
      ]) {
        final reply = await rpc(request(3, 'tools/call', params));
        expect((reply!['error'] as Map)['code'], -32602, reason: '$params');
      }
      expect(tools.calls, isEmpty);
    });
  });

  group('errors', () {
    test('bad JSON is -32700 with a null id', () async {
      final reply = jsonDecode((await server.handleLine(conn, '{nope'))!);
      expect(reply['id'], isNull);
      expect(reply['error']['code'], -32700);
    });

    test('an unknown method is -32601', () async {
      final reply = await rpc(request(4, 'resources/list'));
      expect(reply!['id'], 4);
      expect((reply['error'] as Map)['code'], -32601);
    });

    test('params that are not an object are -32602', () async {
      final reply = await rpc(request(4, 'ping', [1, 2]));
      expect((reply!['error'] as Map)['code'], -32602);
    });

    test('a malformed request is -32600', () async {
      for (final m in <Object>[
        5,
        'x',
        {'id': 1, 'method': 'ping'}, // no jsonrpc
        {'jsonrpc': '1.0', 'id': 1, 'method': 'ping'},
        {'jsonrpc': '2.0', 'id': 1, 'method': 3},
        {'jsonrpc': '2.0', 'id': true, 'method': 'ping'},
      ]) {
        final reply = await rpc(m);
        expect((reply!['error'] as Map)['code'], -32600, reason: '$m');
      }
    });

    test('a response sent to us is ignored', () async {
      expect(await rpc({'jsonrpc': '2.0', 'id': 1, 'result': {}}), isNull);
    });
  });

  test('a handler that blows up is -32603 without its text', () async {
    final broken = McpServer(tools: _ThrowingList(), serverVersion: '1');
    final reply =
        jsonDecode(
              (await broken.handleLine(
                conn,
                jsonEncode(request(1, 'tools/list')),
              ))!,
            )
            as Map<String, Object?>;
    expect((reply['error'] as Map)['code'], -32603);
    expect(jsonEncode(reply), isNot(contains('boom')));
  });

  group('batches', () {
    test('answers each request and skips notifications', () async {
      final reply =
          jsonDecode(
                (await server.handleLine(
                  conn,
                  jsonEncode([
                    request(1, 'ping'),
                    {'jsonrpc': '2.0', 'method': 'notifications/initialized'},
                    request(2, 'nope'),
                  ]),
                ))!,
              )
              as List;
      expect(reply, hasLength(2));
      expect(reply[0]['id'], 1);
      expect(reply[1]['error']['code'], -32601);
    });

    test('an all-notification batch gets no reply', () async {
      expect(
        await server.handleLine(
          conn,
          jsonEncode([
            {'jsonrpc': '2.0', 'method': 'notifications/initialized'},
          ]),
        ),
        isNull,
      );
    });

    test('an empty batch is -32600', () async {
      final reply = jsonDecode((await server.handleLine(conn, '[]'))!);
      expect(reply['error']['code'], -32600);
    });

    test('a batch of more than 16 is -32600 and runs nothing', () async {
      final batch = [
        for (var i = 0; i < 17; i++)
          request(i, 'tools/call', {'name': 'list_hosts'}),
      ];
      final reply = jsonDecode(
        (await server.handleLine(conn, jsonEncode(batch)))!,
      );
      expect(reply['error']['code'], -32600);
      expect(tools.calls, isEmpty);
      // Sixteen is still fine.
      final ok =
          jsonDecode(
                (await server.handleLine(
                  conn,
                  jsonEncode(batch.take(16).toList()),
                ))!,
              )
              as List;
      expect(ok, hasLength(16));
    });
  });

  group('serve', () {
    test('a ping is not held up by a slow tool call', () async {
      tools.gate = Completer<void>();
      final done = server.serve(conn);
      conn.incoming
        ..add(jsonEncode(request(1, 'tools/call', {'name': 'list_hosts'})))
        ..add(jsonEncode(request(2, 'ping')));
      await pumpUntil(() => conn.sent.isNotEmpty);
      expect(jsonDecode(conn.sent.single)['id'], 2);
      tools.gate!.complete();
      await pumpUntil(() => conn.sent.length == 2);
      expect(jsonDecode(conn.sent.last)['id'], 1);
      await conn.incoming.close();
      await done;
      expect(conn.closed, isTrue);
    });

    test(
      'answers calls still running when the peer closes, then closes',
      () async {
        tools.gate = Completer<void>();
        final done = server.serve(conn);
        conn.incoming
          ..add(jsonEncode(request(1, 'tools/call', {'name': 'list_hosts'})))
          ..add('   ')
          ..add(jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/x'}));
        await conn.incoming.close();
        await pumpUntil(() => tools.calls.isNotEmpty);
        expect(conn.closed, isFalse);
        tools.gate!.complete();
        await done;
        expect(conn.sent, hasLength(1));
        expect(conn.closed, isTrue);
      },
    );

    Map<String, Object?> sentWithId(Object id) => conn.sent
        .map((l) => jsonDecode(l))
        .whereType<Map<String, Object?>>()
        .singleWhere((m) => m['id'] == id);

    test(
      'past 16 requests in flight, more are answered -32000 at once',
      () async {
        tools.gate = Completer<void>();
        final done = server.serve(conn);
        for (var i = 0; i < 16; i++) {
          conn.incoming.add(
            jsonEncode(request(i, 'tools/call', {'name': 'list_hosts'})),
          );
        }
        await pumpUntil(() => tools.calls.length == 16);
        conn.incoming
          ..add(
            jsonEncode(request('over', 'tools/call', {'name': 'list_hosts'})),
          )
          ..add(jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/x'}))
          ..add('{bad json');
        await pumpUntil(() => conn.sent.length == 2);
        final over = sentWithId('over');
        expect(over['error'], {
          'code': -32000,
          'message': 'Too many requests in progress',
        });
        expect(jsonDecode(conn.sent.last)['error']['code'], -32700);
        expect(tools.calls, hasLength(16));

        // Answers free the slots again.
        tools.gate!.complete();
        await pumpUntil(() => conn.sent.length == 18);
        conn.incoming.add(jsonEncode(request('after', 'ping')));
        await pumpUntil(() => conn.sent.length == 19);
        expect(sentWithId('after')['result'], <String, Object?>{});
        await conn.incoming.close();
        await done;
      },
    );

    test('a batch counts each entry against the 16', () async {
      tools.gate = Completer<void>();
      final done = server.serve(conn);
      for (var i = 0; i < 10; i++) {
        conn.incoming.add(
          jsonEncode(request(i, 'tools/call', {'name': 'list_hosts'})),
        );
      }
      await pumpUntil(() => tools.calls.length == 10);
      conn.incoming.add(
        jsonEncode([
          for (var i = 100; i < 107; i++) request(i, 'ping'),
          {'jsonrpc': '2.0', 'method': 'notifications/x'},
        ]),
      );
      await pumpUntil(() => conn.sent.isNotEmpty);
      final replies = jsonDecode(conn.sent.single) as List;
      expect(replies, hasLength(7));
      for (final r in replies) {
        expect(r['error']['code'], -32000);
      }
      // A batch that fits still runs.
      conn.incoming.add(
        jsonEncode([for (var i = 200; i < 206; i++) request(i, 'ping')]),
      );
      await pumpUntil(() => conn.sent.length == 2);
      expect((jsonDecode(conn.sent.last) as List).first['result'], isNotNull);
      tools.gate!.complete();
      await conn.incoming.close();
      await done;
    });
  });
}

Future<void> pumpUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition never became true');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
