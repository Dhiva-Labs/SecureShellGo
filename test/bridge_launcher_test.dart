import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/bridge/bridge_channel.dart';
import 'package:secure_shell_go/services/bridge/bridge_client_store.dart';
import 'package:secure_shell_go/services/bridge/bridge_locator.dart';
import 'package:secure_shell_go/services/bridge/bridge_tool_types.dart';
import 'package:secure_shell_go/services/bridge/mcp_server.dart';

import 'support/bridge_temp_dir.dart';

final _client = BridgeClient(
  id: 'c1',
  name: 'Desk assistant',
  tokenHash: 'unused',
  createdAt: DateTime.utc(2026),
);

class _Tools implements BridgeToolHost {
  @override
  List<BridgeToolSpec> get tools => const [
    BridgeToolSpec(
      name: 'list_hosts',
      description: 'Lists the shared hosts.',
      inputSchema: {'type': 'object'},
      kind: BridgeToolKind.read,
    ),
  ];

  @override
  Future<BridgeToolResult> call(
    BridgeClient client,
    String name,
    Map<String, Object?> args,
  ) async => BridgeToolResult('hello ${client.name}');
}

/// An [IOSink] whose bytes the test can read back, standing in for stdout
/// and stderr.
///
/// Synchronous, so a byte the launcher has written is in [bytes] as soon as
/// the write returns: a test that waits for output and then acts (stopping
/// the app, say) is not racing an extra hop through the event loop.
class _Capture {
  _Capture() {
    controller.stream.listen(bytes.addAll);
  }

  final controller = StreamController<List<int>>(sync: true);
  final bytes = <int>[];
  late final IOSink sink = IOSink(controller);

  String get text => utf8.decode(bytes);

  List<Map<String, Object?>> get messages => [
    for (final line in const LineSplitter().convert(text))
      jsonDecode(line) as Map<String, Object?>,
  ];
}

String _line(Object message) => '${jsonEncode(message)}\n';

void main() {
  group('defaultBridgeDirectory', () {
    test('Linux: XDG_DATA_HOME and the app id', () {
      expect(
        defaultBridgeDirectory(
          environment: const {'XDG_DATA_HOME': '/x/data', 'HOME': '/home/u'},
          isWindows: false,
          isMacOS: false,
        ),
        '/x/data/com.dhivalabs.secure_shell_go/bridge',
      );
    });

    test('Linux: ~/.local/share when XDG_DATA_HOME is unset or relative', () {
      for (final env in [
        const {'HOME': '/home/u'},
        const {'HOME': '/home/u', 'XDG_DATA_HOME': 'rel'},
      ]) {
        expect(
          defaultBridgeDirectory(
            environment: env,
            isWindows: false,
            isMacOS: false,
          ),
          '/home/u/.local/share/com.dhivalabs.secure_shell_go/bridge',
        );
      }
    });

    test('Windows: APPDATA, company and product', () {
      expect(
        defaultBridgeDirectory(
          environment: const {'APPDATA': r'C:\Users\A\AppData\Roaming'},
          isWindows: true,
          isMacOS: false,
        ),
        r'C:\Users\A\AppData\Roaming\com.dhivalabs\SecureShell Go\bridge',
      );
    });

    test('macOS: Application Support and the bundle id', () {
      expect(
        defaultBridgeDirectory(
          environment: const {'HOME': '/Users/a'},
          isWindows: false,
          isMacOS: true,
        ),
        '/Users/a/Library/Application Support/com.dhivalabs.secureShellGo/'
        'bridge',
      );
    });

    test('SSG_BRIDGE_DIR overrides, and nothing to go on is null', () {
      expect(
        defaultBridgeDirectory(
          environment: const {'SSG_BRIDGE_DIR': '/elsewhere', 'HOME': '/h'},
          isWindows: false,
          isMacOS: false,
        ),
        '/elsewhere',
      );
      expect(
        defaultBridgeDirectory(
          environment: const {},
          isWindows: false,
          isMacOS: false,
        ),
        isNull,
      );
      expect(
        defaultBridgeDirectory(
          environment: const {},
          isWindows: true,
          isMacOS: false,
        ),
        isNull,
      );
    });

    test('agrees with the app\'s own constants', () {
      // `AppDataPaths` and `linux/CMakeLists.txt` are the sources of truth.
      expect(
        File('linux/CMakeLists.txt').readAsStringSync(),
        contains('set(APPLICATION_ID "$linuxApplicationId")'),
      );
      final rc = File('windows/runner/Runner.rc').readAsStringSync();
      expect(rc, contains('"CompanyName", "$windowsCompanyName"'));
      expect(rc, contains('"ProductName", "$windowsProductName"'));
      expect(
        File('lib/services/app_data_paths.dart').readAsStringSync(),
        contains("macosBundleId = '$macosBundleId'"),
      );
    });
  });

  group('BridgeEndpoint.fromJson', () {
    test('round-trips both kinds', () {
      for (final e in const <BridgeEndpoint>[
        BridgeUnixEndpoint('/run/x.sock'),
        BridgeTcpEndpoint(4711, 'abc'),
      ]) {
        expect(BridgeEndpoint.fromJson(e.toJson())!.toJson(), e.toJson());
      }
    });

    test('rejects anything else', () {
      for (final j in <Object?>[
        null,
        'x',
        <String, Object?>{},
        {'kind': 'unix'},
        {'kind': 'unix', 'path': ''},
        {'kind': 'tcp', 'port': 0, 'secret': 's'},
        {'kind': 'tcp', 'port': 70000, 'secret': 's'},
        {'kind': 'tcp', 'port': 1, 'secret': ''},
        {'kind': 'pipe', 'path': 'x'},
      ]) {
        expect(BridgeEndpoint.fromJson(j), isNull, reason: '$j');
      }
    });
  });

  group('launcher with no app', () {
    late Directory temp;
    setUp(() async => temp = await bridgeTempDir('ssgl'));
    tearDown(() => deleteTempDir(temp));

    Future<(int, _Capture, _Capture)> run(
      List<String> lines, {
      String? dir,
      String? token = 'tok',
    }) async {
      final out = _Capture();
      final err = _Capture();
      final code = await runBridgeLauncher(
        input: Stream.value(utf8.encode(lines.join())),
        output: out.sink,
        errors: err.sink,
        bridgeDir: dir ?? temp.path,
        token: token,
      );
      await out.sink.flush();
      await err.sink.flush();
      return (code, out, err);
    }

    test('answers every request with -32000 and exits 1', () async {
      final (code, out, err) = await run([
        _line({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize'}),
        _line({'jsonrpc': '2.0', 'method': 'notifications/initialized'}),
        '\n',
        _line({'jsonrpc': '2.0', 'id': 'b', 'method': 'tools/list'}),
      ]);
      expect(code, 1);
      expect(out.messages, [
        {
          'jsonrpc': '2.0',
          'id': 1,
          'error': {'code': -32000, 'message': bridgeNotRunningMessage},
        },
        {
          'jsonrpc': '2.0',
          'id': 'b',
          'error': {'code': -32000, 'message': bridgeNotRunningMessage},
        },
      ]);
      expect(err.text.trim(), bridgeNotRunningMessage);
    });

    test('answers bad JSON with -32700 and a batch with a batch', () async {
      final (_, out, _) = await run([
        '{oops\n',
        _line([
          {'jsonrpc': '2.0', 'id': 1, 'method': 'ping'},
          {'jsonrpc': '2.0', 'method': 'notifications/initialized'},
        ]),
      ]);
      final text = const LineSplitter().convert(out.text);
      expect(jsonDecode(text[0])['error']['code'], -32700);
      expect(jsonDecode(text[1]), [
        {
          'jsonrpc': '2.0',
          'id': 1,
          'error': {'code': -32000, 'message': bridgeNotRunningMessage},
        },
      ]);
    });

    test('a stale tcp port held by an impostor never gets the token', () async {
      final received = <int>[];
      final impostor = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(impostor.close);
      impostor.listen((s) {
        s.listen((bytes) {
          received.addAll(bytes);
          // Plays along as best it can without the secret.
          s.write('{"proof":"${'0' * 64}"}\n{"ok":true}\n');
        }, onError: (Object _) {});
      });
      await BridgeLocator(
        temp.path,
      ).write(BridgeTcpEndpoint(impostor.port, 'real-secret'));
      final (code, out, err) = await run([
        _line({'jsonrpc': '2.0', 'id': 1, 'method': 'ping'}),
      ], token: 'pairing-token');
      expect(code, 1);
      expect(out.messages.single['error'], {
        'code': -32000,
        'message': bridgeNotRunningMessage,
      });
      expect(err.text.trim(), bridgeNotRunningMessage);
      // Let any late bytes reach the impostor before looking.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final sent = utf8.decode(received);
      expect(sent, contains('"hello"'));
      expect(sent, isNot(contains('pairing-token')));
      expect(sent, isNot(contains('real-secret')));
    });

    test(
      'a locator pointing at nothing reads as not running',
      skip: skipUnixSocketOnWindows,
      () async {
        await BridgeLocator(
          temp.path,
        ).write(BridgeUnixEndpoint('${temp.path}/gone.sock'));
        final (code, out, _) = await run([
          _line({'jsonrpc': '2.0', 'id': 1, 'method': 'ping'}),
        ]);
        expect(code, 1);
        expect(out.text, contains(bridgeNotRunningMessage));
      },
    );

    test('a locator pointing at a closed port reads as not running', () async {
      // A port that was ours once and now has nobody on it.
      final gone = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = gone.port;
      await gone.close();
      await BridgeLocator(temp.path).write(BridgeTcpEndpoint(port, 'old'));
      final (code, out, err) = await run([
        _line({'jsonrpc': '2.0', 'id': 1, 'method': 'ping'}),
      ]);
      expect(code, 1);
      expect(out.messages.single['error'], {
        'code': -32000,
        'message': bridgeNotRunningMessage,
      });
      expect(err.text.trim(), bridgeNotRunningMessage);
    });

    test('no bridge directory at all reads as not running', () async {
      final out = _Capture();
      final err = _Capture();
      final code = await runBridgeLauncher(
        input: Stream.value(
          utf8.encode(_line({'jsonrpc': '2.0', 'id': 1, 'method': 'ping'})),
        ),
        output: out.sink,
        errors: err.sink,
        bridgeDir: null,
        token: 'tok',
      );
      await out.sink.flush();
      expect(code, 1);
      expect(out.text, contains(bridgeNotRunningMessage));
    });

    test('says when the token is missing', () async {
      final (code, out, err) = await run([
        _line({'jsonrpc': '2.0', 'id': 1, 'method': 'ping'}),
      ], token: null);
      expect(code, 1);
      expect(err.text, contains('SSG_BRIDGE_TOKEN'));
      expect(out.text, contains('SSG_BRIDGE_TOKEN'));
    });
  });

  test('an app that resets the connection ends the launcher with 1', () async {
    final temp = await bridgeTempDir('ssgr');
    addTearDown(() => deleteTempDir(temp));
    // A stand-in app: proves the secret, accepts the token, then stops
    // reading and closes with the launcher's bytes unread, which resets the
    // connection rather than closing it. Windows does the same when the app
    // quits under a live connection.
    const secret = 'the-secret';
    final app = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(app.close);
    app.listen((s) {
      final lines = StreamIterator(
        utf8.decoder.bind(s).transform(const LineSplitter()),
      );
      () async {
        await lines.moveNext();
        final nonce = (jsonDecode(lines.current) as Map)['hello'] as String;
        s.write('${jsonEncode({'proof': bridgeProof(secret, nonce)})}\n');
        await lines.moveNext();
        s.write('{"ok":true}\n');
        // The iterator is paused now: nothing more is read.
        await Future<void>.delayed(const Duration(milliseconds: 300));
        s.destroy();
      }();
    });
    await BridgeLocator(temp.path).write(BridgeTcpEndpoint(app.port, secret));

    final input = StreamController<List<int>>();
    final out = _Capture();
    final err = _Capture();
    final run = runBridgeLauncher(
      input: input.stream,
      output: out.sink,
      errors: err.sink,
      bridgeDir: temp.path,
      token: 'good',
    );
    final ping = _line({'jsonrpc': '2.0', 'id': 1, 'method': 'ping'});
    input.add(utf8.encode(ping * 2000));
    expect(await run.timeout(const Duration(seconds: 10)), 1);
    expect(err.text, contains('closed'));
    await input.close();
  });

  for (final kind in BridgeTransportKind.values) {
    final skip = kind == BridgeTransportKind.unix
        ? skipUnixSocketOnWindows
        : null;
    group('end to end over ${kind.name}', skip: skip, () {
      late Directory temp;
      late BridgeListener listener;
      late StreamSubscription<BridgeConnection> serving;

      setUp(() async {
        temp = await bridgeTempDir('ssge');
        listener = BridgeListener(
          bridgeDir: '${temp.path}/bridge',
          verify: (t) async => t == 'good' ? _client : null,
          transport: kind,
          environment: const {},
        );
        final server = McpServer(tools: _Tools(), serverVersion: '1.6.0');
        serving = listener.connections.listen(server.serve);
        await listener.start();
      });

      tearDown(() async {
        await serving.cancel();
        await listener.stop();
        await deleteTempDir(temp);
      });

      test('a whole MCP session through the launcher', () async {
        final input = StreamController<List<int>>();
        final out = _Capture();
        final err = _Capture();
        final run = runBridgeLauncher(
          input: input.stream,
          output: out.sink,
          errors: err.sink,
          bridgeDir: '${temp.path}/bridge',
          token: 'good',
        );
        input.add(
          utf8.encode(
            _line({
              'jsonrpc': '2.0',
              'id': 1,
              'method': 'initialize',
              'params': {
                'protocolVersion': '2025-03-26',
                'capabilities': <String, Object?>{},
                'clientInfo': {'name': 'test', 'version': '0'},
              },
            }),
          ),
        );
        // Split one message across two writes: the launcher must not
        // re-frame anything.
        final notif = _line({
          'jsonrpc': '2.0',
          'method': 'notifications/initialized',
        });
        input
          ..add(utf8.encode(notif.substring(0, 10)))
          ..add(utf8.encode(notif.substring(10)))
          ..add(
            utf8.encode(
              _line({'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'}),
            ),
          )
          ..add(
            utf8.encode(
              _line({
                'jsonrpc': '2.0',
                'id': 3,
                'method': 'tools/call',
                'params': {
                  'name': 'list_hosts',
                  'arguments': <String, Object?>{},
                },
              }),
            ),
          );
        await input.close();
        final code = await run.timeout(const Duration(seconds: 10));
        await out.sink.flush();
        expect(code, 0, reason: err.text);

        final byId = {for (final m in out.messages) m['id']: m};
        expect(byId.keys, unorderedEquals([1, 2, 3]));
        final init = byId[1]!['result'] as Map;
        expect(init['protocolVersion'], '2025-03-26');
        expect(init['serverInfo'], {
          'name': 'secureshellgo',
          'version': '1.6.0',
        });
        expect(
          ((byId[2]!['result'] as Map)['tools'] as List).single['name'],
          'list_hosts',
        );
        expect(byId[3]!['result'], {
          'content': [
            {'type': 'text', 'text': 'hello Desk assistant'},
          ],
          'isError': false,
        });
        expect(err.text, isEmpty);
      });

      test('a refused token is relayed to the assistant', () async {
        final out = _Capture();
        final err = _Capture();
        final code = await runBridgeLauncher(
          input: Stream.value(
            utf8.encode(_line({'jsonrpc': '2.0', 'id': 1, 'method': 'ping'})),
          ),
          output: out.sink,
          errors: err.sink,
          bridgeDir: '${temp.path}/bridge',
          token: 'stolen',
        );
        await out.sink.flush();
        expect(code, 1);
        final error = out.messages.single['error'] as Map;
        expect(error['code'], -32000);
        expect(error['message'], contains('not paired'));
        expect(err.text, contains('not paired'));
      });

      test('the app going away ends the launcher with 1', () async {
        final input = StreamController<List<int>>();
        final out = _Capture();
        final err = _Capture();
        final run = runBridgeLauncher(
          input: input.stream,
          output: out.sink,
          errors: err.sink,
          bridgeDir: '${temp.path}/bridge',
          token: 'good',
        );
        input.add(
          utf8.encode(_line({'jsonrpc': '2.0', 'id': 1, 'method': 'ping'})),
        );
        await pumpUntil(() => out.bytes.isNotEmpty);
        await listener.stop();
        expect(await run.timeout(const Duration(seconds: 10)), 1);
        expect(err.text, contains('closed'));
        await input.close();
      });
    });
  }
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
