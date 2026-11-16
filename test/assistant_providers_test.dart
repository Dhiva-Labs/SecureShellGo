import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/assistant/anthropic_provider.dart';
import 'package:secure_shell_go/services/assistant/assistant_http.dart';
import 'package:secure_shell_go/services/assistant/assistant_types.dart';
import 'package:secure_shell_go/services/assistant/openai_provider.dart';
import 'package:secure_shell_go/services/bridge/bridge_tool_types.dart';

const _key = 'sk-test-0123456789abcdefSECRETKEY';

const _spec = BridgeToolSpec(
  name: 'list_hosts',
  description: 'Lists hosts.',
  inputSchema: {
    'type': 'object',
    'properties': {
      'filter': {'type': 'string'},
    },
  },
  kind: BridgeToolKind.read,
);

class _Seen {
  _Seen(this.method, this.path, this.headers, this.body);
  final String method;
  final String path;
  final HttpHeaders headers;
  final Object? body;
}

/// A local server whose reply the test decides, recording what it was sent.
class _Server {
  late HttpServer server;
  final List<_Seen> seen = [];
  Future<void> Function(HttpRequest, Object? body)? handler;

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final raw = await utf8.decoder.bind(req).join();
      Object? body;
      try {
        body = jsonDecode(raw);
      } catch (_) {}
      seen.add(_Seen(req.method, req.uri.path, req.headers, body));
      await handler!(req, body);
    });
  }

  String get base => 'http://127.0.0.1:${server.port}';

  Future<void> stop() => server.close(force: true);

  static Future<void> json(
    HttpRequest req,
    Object body, {
    int status = 200,
  }) async {
    req.response.statusCode = status;
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(body));
    await req.response.close();
  }
}

void main() {
  late _Server srv;
  setUp(() async {
    srv = _Server();
    await srv.start();
  });
  tearDown(() => srv.stop());

  AnthropicProvider anthropic({AssistantHttpLimits? limits, String? base}) =>
      AnthropicProvider(
        apiKey: _key,
        model: 'claude-test',
        baseUrl: base ?? srv.base,
        limits: limits ?? const AssistantHttpLimits(),
      );

  OpenAiCompatibleProvider openai({
    AssistantHttpLimits? limits,
    String? base,
  }) => OpenAiCompatibleProvider(
    apiKey: _key,
    model: 'gpt-test',
    baseUrl: base ?? '${srv.base}/v1',
    limits: limits ?? const AssistantHttpLimits(),
  );

  Future<AssistantTurn> askAnthropic(
    AnthropicProvider p, {
    AssistantCancel? cancel,
  }) => p.send(
    messages: [AssistantMessage.userText('hi')],
    tools: const [_spec],
    system: 'SYS',
    cancel: cancel,
  );

  Future<AssistantTurn> askOpenAi(
    OpenAiCompatibleProvider p, {
    AssistantCancel? cancel,
  }) => p.send(
    messages: [AssistantMessage.userText('hi')],
    tools: const [_spec],
    system: 'SYS',
    cancel: cancel,
  );

  Future<AssistantFailure> failureOf(Future<Object?> f) async {
    try {
      await f;
    } on AssistantFailure catch (e) {
      return e;
    }
    fail('expected an AssistantFailure');
  }

  group('Anthropic', () {
    test('request shape is exact', () async {
      srv.handler = (req, _) => _Server.json(req, {
        'content': [
          {'type': 'text', 'text': 'hello'},
        ],
        'stop_reason': 'end_turn',
      });
      final turn = await askAnthropic(anthropic());
      expect(turn.text, 'hello');
      expect(turn.stopReason, AssistantStopReason.endTurn);
      final r = srv.seen.single;
      expect(r.method, 'POST');
      expect(r.path, '/v1/messages');
      expect(r.headers.value('x-api-key'), _key);
      expect(r.headers.value('anthropic-version'), '2023-06-01');
      expect(r.headers.contentType?.mimeType, 'application/json');
      expect(r.body, {
        'model': 'claude-test',
        'max_tokens': 4096,
        'system': 'SYS',
        'messages': [
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': 'hi'},
            ],
          },
        ],
        'tools': [
          {
            'name': 'list_hosts',
            'description': 'Lists hosts.',
            'input_schema': _spec.inputSchema,
          },
        ],
      });
    });

    test('tool call round trip, with an image result', () async {
      var n = 0;
      srv.handler = (req, _) {
        n++;
        if (n == 1) {
          return _Server.json(req, {
            'content': [
              {'type': 'text', 'text': 'Looking.'},
              {
                'type': 'tool_use',
                'id': 'toolu_1',
                'name': 'list_hosts',
                'input': {'filter': 'web'},
              },
            ],
            'stop_reason': 'tool_use',
          });
        }
        return _Server.json(req, {
          'content': [
            {'type': 'text', 'text': 'Done.'},
          ],
          'stop_reason': 'end_turn',
        });
      };
      final p = anthropic();
      final first = await askAnthropic(p);
      expect(first.stopReason, AssistantStopReason.toolUse);
      final call = first.toolCalls.single;
      expect(call.id, 'toolu_1');
      expect(call.args, {'filter': 'web'});

      final second = await p.send(
        messages: [
          AssistantMessage.userText('hi'),
          AssistantMessage(AssistantRole.assistant, first.blocks),
          AssistantMessage(AssistantRole.user, [
            AssistantToolResult(
              callId: 'toolu_1',
              name: 'list_hosts',
              text: 'screen 10x10',
              image: Uint8List.fromList([1, 2, 3]),
              imageMimeType: 'image/png',
            ),
            const AssistantToolResult(
              callId: 'toolu_2',
              name: 'x',
              text: 'denied',
              isError: true,
            ),
          ]),
        ],
        tools: const [_spec],
        system: 'SYS',
      );
      expect(second.text, 'Done.');
      final messages = (srv.seen.last.body as Map)['messages'] as List;
      expect(messages[1], {
        'role': 'assistant',
        'content': [
          {'type': 'text', 'text': 'Looking.'},
          {
            'type': 'tool_use',
            'id': 'toolu_1',
            'name': 'list_hosts',
            'input': {'filter': 'web'},
          },
        ],
      });
      expect(messages[2], {
        'role': 'user',
        'content': [
          {
            'type': 'tool_result',
            'tool_use_id': 'toolu_1',
            'content': [
              {
                'type': 'image',
                'source': {
                  'type': 'base64',
                  'media_type': 'image/png',
                  'data': base64Encode([1, 2, 3]),
                },
              },
              {'type': 'text', 'text': 'screen 10x10'},
            ],
            'is_error': false,
          },
          {
            'type': 'tool_result',
            'tool_use_id': 'toolu_2',
            'content': [
              {'type': 'text', 'text': 'denied'},
            ],
            'is_error': true,
          },
        ],
      });
    });

    test('max_tokens maps and the default base is Anthropic', () async {
      srv.handler = (req, _) => _Server.json(req, {
        'content': [
          {'type': 'text', 'text': 'cut'},
        ],
        'stop_reason': 'max_tokens',
      });
      final turn = await askAnthropic(anthropic());
      expect(turn.stopReason, AssistantStopReason.maxTokens);
      expect(AnthropicProvider.defaultBaseUrl, 'https://api.anthropic.com');
    });

    test('error mapping', () async {
      Future<AssistantFailure> with_(int status, [Object? body]) {
        srv.handler = (req, _) =>
            _Server.json(req, body ?? {'error': {'message': 'm'}}, status: status);
        return failureOf(askAnthropic(anthropic()));
      }

      expect((await with_(401)).kind, AssistantFailureKind.auth);
      expect((await with_(403)).kind, AssistantFailureKind.auth);
      expect((await with_(429)).kind, AssistantFailureKind.rateLimit);
      expect((await with_(500)).kind, AssistantFailureKind.server);
      expect((await with_(529)).kind, AssistantFailureKind.server);
      final bad = await with_(400, {
        'error': {'message': 'model: nope'},
      });
      expect(bad.kind, AssistantFailureKind.badResponse);
      expect(bad.message, contains('model: nope'));
    });

    test('garbage 200 is a bad response', () async {
      srv.handler = (req, _) async {
        req.response.write('<html>nope</html>');
        await req.response.close();
      };
      expect(
        (await failureOf(askAnthropic(anthropic()))).kind,
        AssistantFailureKind.badResponse,
      );
      srv.handler = (req, _) => _Server.json(req, {'content': 'x'});
      expect(
        (await failureOf(askAnthropic(anthropic()))).kind,
        AssistantFailureKind.badResponse,
      );
    });

    test('an error body that echoes headers shows neither key nor header',
        () async {
      srv.handler = (req, _) {
        final echoed = {
          'x-api-key': req.headers.value('x-api-key'),
          'authorization': 'Bearer ${req.headers.value('x-api-key')}',
        };
        return _Server.json(req, {
          'error': {'message': 'bad request, headers were ${jsonEncode(echoed)}'},
        }, status: 400);
      };
      final e = await failureOf(askAnthropic(anthropic()));
      expect(e.message, isNot(contains(_key)));
      expect(e.message, isNot(contains('SECRETKEY')));
      expect(e.message.toLowerCase(), isNot(contains('bearer sk')));
      expect(e.toString(), isNot(contains('SECRETKEY')));
    });

    test('a 429 that echoes the key is clean too', () async {
      srv.handler = (req, _) => _Server.json(req, {
        'error': {'message': 'slow down $_key'},
      }, status: 429);
      final e = await failureOf(askAnthropic(anthropic()));
      expect(e.message, isNot(contains('SECRETKEY')));
    });

    test('times out when the server never answers', () async {
      final hold = Completer<void>();
      srv.handler = (req, _) => hold.future;
      final e = await failureOf(
        askAnthropic(
          anthropic(
            limits: const AssistantHttpLimits(
              requestTimeout: Duration(milliseconds: 300),
            ),
          ),
        ),
      );
      hold.complete();
      expect(e.kind, AssistantFailureKind.network);
      expect(e.message, contains('did not answer in time'));
    });

    test('cancel aborts the request', () async {
      final arrived = Completer<void>();
      final hold = Completer<void>();
      srv.handler = (req, _) {
        arrived.complete();
        return hold.future;
      };
      final cancel = AssistantCancel();
      final future = failureOf(askAnthropic(anthropic(), cancel: cancel));
      await arrived.future;
      cancel.cancel();
      final e = await future;
      hold.complete();
      expect(e.kind, AssistantFailureKind.cancelled);
    });

    test('already-cancelled never reaches the server', () async {
      srv.handler = (req, _) => _Server.json(req, {});
      final cancel = AssistantCancel()..cancel();
      final e = await failureOf(askAnthropic(anthropic(), cancel: cancel));
      expect(e.kind, AssistantFailureKind.cancelled);
      expect(srv.seen, isEmpty);
    });

    test('a reply over the size cap is refused', () async {
      srv.handler = (req, _) async {
        req.response.write('x' * 5000);
        await req.response.close();
      };
      final e = await failureOf(
        askAnthropic(
          anthropic(limits: const AssistantHttpLimits(maxResponseBytes: 1000)),
        ),
      );
      expect(e.kind, AssistantFailureKind.badResponse);
      expect(e.message, contains('too large'));
    });

    test('the default cap is 4 MiB, timeouts 20 s and 120 s', () {
      const l = AssistantHttpLimits();
      expect(l.maxResponseBytes, 4 * 1024 * 1024);
      expect(l.connectTimeout, const Duration(seconds: 20));
      expect(l.requestTimeout, const Duration(seconds: 120));
    });
  });

  group('OpenAI-compatible', () {
    test('request shape is exact', () async {
      srv.handler = (req, _) => _Server.json(req, {
        'choices': [
          {
            'message': {'role': 'assistant', 'content': 'hello'},
            'finish_reason': 'stop',
          },
        ],
      });
      final turn = await askOpenAi(openai());
      expect(turn.text, 'hello');
      final r = srv.seen.single;
      expect(r.path, '/v1/chat/completions');
      expect(r.headers.value('authorization'), 'Bearer $_key');
      expect(r.body, {
        'model': 'gpt-test',
        'messages': [
          {'role': 'system', 'content': 'SYS'},
          {'role': 'user', 'content': 'hi'},
        ],
        'tools': [
          {
            'type': 'function',
            'function': {
              'name': 'list_hosts',
              'description': 'Lists hosts.',
              'parameters': _spec.inputSchema,
            },
          },
        ],
      });
    });

    test('tool call round trip; image becomes a text note', () async {
      srv.handler = (req, _) => _Server.json(req, {
        'choices': [
          {
            'message': {
              'role': 'assistant',
              'content': null,
              'tool_calls': [
                {
                  'id': 'call_1',
                  'type': 'function',
                  'function': {
                    'name': 'list_hosts',
                    'arguments': '{"filter":"web"}',
                  },
                },
              ],
            },
            'finish_reason': 'tool_calls',
          },
        ],
      });
      final p = openai();
      final first = await askOpenAi(p);
      expect(first.stopReason, AssistantStopReason.toolUse);
      expect(first.toolCalls.single.args, {'filter': 'web'});

      await p.send(
        messages: [
          AssistantMessage.userText('hi'),
          AssistantMessage(AssistantRole.assistant, first.blocks),
          AssistantMessage(AssistantRole.user, [
            AssistantToolResult(
              callId: 'call_1',
              name: 'list_hosts',
              text: 'ok',
              image: Uint8List.fromList([1, 2]),
              imageMimeType: 'image/png',
            ),
          ]),
        ],
        tools: const [_spec],
        system: 'SYS',
      );
      final messages = (srv.seen.last.body as Map)['messages'] as List;
      expect(messages[2], {
        'role': 'assistant',
        'content': null,
        'tool_calls': [
          {
            'id': 'call_1',
            'type': 'function',
            'function': {'name': 'list_hosts', 'arguments': '{"filter":"web"}'},
          },
        ],
      });
      final tool = messages[3] as Map;
      expect(tool['role'], 'tool');
      expect(tool['tool_call_id'], 'call_1');
      expect(tool['content'], startsWith('ok\n[An image'));
      expect(jsonEncode(messages), isNot(contains('base64')));
    });

    test('arguments that are not JSON become a tool-call error', () async {
      srv.handler = (req, _) => _Server.json(req, {
        'choices': [
          {
            'message': {
              'content': null,
              'tool_calls': [
                {
                  'id': 'c',
                  'type': 'function',
                  'function': {'name': 'list_hosts', 'arguments': '{oops'},
                },
              ],
            },
            'finish_reason': 'tool_calls',
          },
        ],
      });
      final turn = await askOpenAi(openai());
      expect(turn.toolCalls.single.argsError, isNotNull);
    });

    test('error mapping and a clean message', () async {
      Future<AssistantFailure> with_(int status) {
        srv.handler = (req, _) => _Server.json(req, {
          'error': {
            'message':
                'Incorrect key. Authorization: Bearer ${req.headers.value('authorization')}',
          },
        }, status: status);
        return failureOf(askOpenAi(openai()));
      }

      expect((await with_(401)).kind, AssistantFailureKind.auth);
      expect((await with_(429)).kind, AssistantFailureKind.rateLimit);
      expect((await with_(500)).kind, AssistantFailureKind.server);
      final bad = await with_(404);
      expect(bad.kind, AssistantFailureKind.badResponse);
      for (final status in [401, 404, 429, 500]) {
        final e = await with_(status);
        expect(e.message, isNot(contains('SECRETKEY')));
        expect(e.message, isNot(contains(_key)));
      }
    });

    test('garbage and empty choices are bad responses', () async {
      srv.handler = (req, _) async {
        req.response.write('not json');
        await req.response.close();
      };
      expect(
        (await failureOf(askOpenAi(openai()))).kind,
        AssistantFailureKind.badResponse,
      );
      srv.handler = (req, _) => _Server.json(req, {'choices': []});
      expect(
        (await failureOf(askOpenAi(openai()))).kind,
        AssistantFailureKind.badResponse,
      );
    });

    test('timeout, cancel and size cap', () async {
      final hold = Completer<void>();
      srv.handler = (req, _) => hold.future;
      var e = await failureOf(
        askOpenAi(
          openai(
            limits: const AssistantHttpLimits(
              requestTimeout: Duration(milliseconds: 300),
            ),
          ),
        ),
      );
      expect(e.kind, AssistantFailureKind.network);

      final cancel = AssistantCancel();
      final f = failureOf(askOpenAi(openai(), cancel: cancel));
      while (srv.seen.length < 2) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      cancel.cancel();
      e = await f;
      expect(e.kind, AssistantFailureKind.cancelled);
      hold.complete();

      srv.handler = (req, _) async {
        req.response.write('y' * 5000);
        await req.response.close();
      };
      e = await failureOf(
        askOpenAi(
          openai(limits: const AssistantHttpLimits(maxResponseBytes: 1000)),
        ),
      );
      expect(e.message, contains('too large'));
    });

    test('a base address is required', () async {
      final e = await failureOf(askOpenAi(openai(base: '')));
      expect(e.kind, AssistantFailureKind.config);
    });

    test('no key means no Authorization header (local server)', () async {
      srv.handler = (req, _) => _Server.json(req, {
        'choices': [
          {
            'message': {'content': 'ok'},
            'finish_reason': 'stop',
          },
        ],
      });
      final p = OpenAiCompatibleProvider(
        apiKey: '',
        model: 'm',
        baseUrl: '${srv.base}/v1/',
      );
      await askOpenAi(p);
      expect(srv.seen.single.headers.value('authorization'), isNull);
      expect(srv.seen.single.path, '/v1/chat/completions');
    });
  });

  group('the http rule', () {
    test('localhost, 127.0.0.1 and [::1] may use http', () {
      for (final u in [
        'http://localhost:11434/v1',
        'http://127.0.0.1:8080/v1',
        'http://[::1]:8080/v1',
        'https://api.openai.com/v1',
      ]) {
        expect(checkedAssistantUrl(u, what: 'x').toString(), isNotEmpty);
      }
    });

    test('other http addresses are refused with a clear message', () async {
      for (final base in [
        'http://example.com/v1',
        'http://192.168.1.5:8080/v1',
        'http://localhost.evil.com/v1',
        'ftp://example.com',
      ]) {
        final e = await failureOf(askOpenAi(openai(base: base)));
        expect(e.kind, AssistantFailureKind.config, reason: base);
        expect(e.message, anyOf(contains('not encrypted'), contains('https')));
      }
      final e = await failureOf(
        askAnthropic(anthropic(base: 'http://api.anthropic.com')),
      );
      expect(e.message, contains('not encrypted'));
      expect(srv.seen, isEmpty);
    });

    test('an address with a password in it is refused', () {
      expect(
        () => checkedAssistantUrl('https://u:p@example.com', what: 'x'),
        throwsA(isA<AssistantFailure>()),
      );
    });
  });
}
