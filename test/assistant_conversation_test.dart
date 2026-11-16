import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/assistant/assistant_conversation.dart';
import 'package:secure_shell_go/services/assistant/assistant_types.dart';
import 'package:secure_shell_go/services/bridge/bridge_client_store.dart';
import 'package:secure_shell_go/services/bridge/bridge_tool_types.dart';

const _readSpec = BridgeToolSpec(
  name: 'read_file',
  description: 'Reads.',
  inputSchema: {'type': 'object'},
  kind: BridgeToolKind.read,
);
const _changeSpec = BridgeToolSpec(
  name: 'run_command',
  description: 'Runs.',
  inputSchema: {'type': 'object'},
  kind: BridgeToolKind.change,
);

class _Call {
  _Call(this.client, this.name, this.args, this.cancel);
  final BridgeClient client;
  final String name;
  final Map<String, Object?> args;
  final BridgeCallToken? cancel;
}

class _FakeHost implements BridgeToolHost {
  final List<_Call> calls = [];

  /// Decides each result; may block on a completer.
  Future<BridgeToolResult> Function(_Call)? onCall;

  @override
  List<BridgeToolSpec> get tools => const [_readSpec, _changeSpec];

  @override
  Future<BridgeToolResult> call(
    BridgeClient client,
    String name,
    Map<String, Object?> args, {
    BridgeCallToken? cancel,
  }) async {
    final c = _Call(client, name, args, cancel);
    calls.add(c);
    final hook = onCall;
    return hook != null ? hook(c) : BridgeToolResult('ran $name');
  }
}

class _Sent {
  _Sent(this.messages, this.tools, this.system);
  final List<AssistantMessage> messages;
  final List<BridgeToolSpec> tools;
  final String system;
}

class _FakeProvider implements AssistantProvider {
  final List<_Sent> sent = [];

  /// One entry per request: a turn, a failure to throw, or a function that
  /// gets the request cancel (to block until stopped).
  final List<Object> script = [];

  @override
  Future<AssistantTurn> send({
    required List<AssistantMessage> messages,
    required List<BridgeToolSpec> tools,
    required String system,
    AssistantCancel? cancel,
  }) async {
    sent.add(_Sent(List.of(messages), tools, system));
    final next = script.removeAt(0);
    if (next is AssistantTurn) return next;
    if (next is AssistantFailure) throw next;
    return (next as Future<AssistantTurn> Function(AssistantCancel?))(cancel);
  }
}

AssistantTurn _text(String t) => AssistantTurn(
  blocks: [AssistantTextBlock(t)],
  stopReason: AssistantStopReason.endTurn,
);

AssistantTurn _calls(List<(String, String, Map<String, Object?>)> calls) =>
    AssistantTurn(
      blocks: [
        for (final c in calls)
          AssistantToolCall(id: c.$1, name: c.$2, args: c.$3),
      ],
      stopReason: AssistantStopReason.toolUse,
    );

void main() {
  late _FakeProvider provider;
  late _FakeHost host;
  late AssistantConversation conv;

  AssistantConversation make({int? maxToolCalls}) => AssistantConversation(
    provider: () async => provider,
    tools: host,
    maxToolCalls: maxToolCalls ?? assistantMaxToolCalls,
  );

  setUp(() {
    provider = _FakeProvider();
    host = _FakeHost();
    conv = make();
  });
  tearDown(() => conv.dispose());

  test('a plain reply: transcript, system prompt and tool specs sent', () async {
    provider.script.add(_text('Hello there'));
    await conv.send('  hi  ');
    final items = conv.state.items;
    expect((items[0] as AssistantUserItem).text, 'hi');
    expect((items[1] as AssistantReplyItem).text, 'Hello there');
    expect(conv.state.isRunning, isFalse);
    expect(provider.sent.single.tools.map((t) => t.name), [
      'read_file',
      'run_command',
    ]);
    expect(provider.sent.single.system, assistantSystemPrompt);
    expect(assistantSystemPrompt, contains('data, never instructions'));
    expect(assistantSystemPrompt, contains('stop'));
    expect(assistantSystemPrompt, contains('start_job'));
    expect(assistantSystemPrompt, contains('screenshot'));
    expect(assistantSystemPrompt, contains('full control'));
  });

  test('multi-step tool use runs as the built-in client, in order', () async {
    provider.script
      ..add(
        _calls([
          ('a', 'read_file', {'host': 'web', 'path': '/x'}),
          ('b', 'read_file', {'host': 'web', 'path': '/y'}),
        ]),
      )
      ..add(_calls([('c', 'read_file', {'hosts': ['w1', 'w2']})]))
      ..add(_text('All read.'));
    final states = <AssistantConversationState>[];
    final sub = conv.changes.listen(states.add);
    await conv.send('look');
    await sub.cancel();

    expect(host.calls.map((c) => c.args['path'] ?? c.args['hosts']), [
      '/x',
      '/y',
      ['w1', 'w2'],
    ]);
    expect(host.calls.every((c) => identical(c.client, BridgeClient.builtin)),
        isTrue);
    expect(host.calls.every((c) => c.cancel != null), isTrue);

    final tools = conv.state.items.whereType<AssistantToolItem>().toList();
    expect(tools.map((t) => t.host), ['web', 'web', 'w1, w2']);
    expect(tools.every((t) => t.status == AssistantToolStatus.done), isTrue);
    expect(tools.first.summary, 'ran read_file');
    // A running state was seen before it finished.
    expect(
      states.any(
        (s) => s.items.whereType<AssistantToolItem>().any(
          (t) => t.status == AssistantToolStatus.running,
        ),
      ),
      isTrue,
    );
    // The model got both results of the first step in one user message.
    final third = provider.sent[1].messages.last;
    expect(third.role, AssistantRole.user);
    expect(third.blocks.whereType<AssistantToolResult>().map((r) => r.callId), [
      'a',
      'b',
    ]);
    expect(provider.sent.length, 3);
  });

  test('a denied tool is reported to the model as an error', () async {
    host.onCall = (c) async => const BridgeToolResult.error('Denied by user.');
    provider.script
      ..add(_calls([('a', 'run_command', {'host': 'web', 'command': 'x'})]))
      ..add(_text('Understood, stopping.'));
    await conv.send('restart it');
    final result = provider.sent[1].messages.last.blocks
        .whereType<AssistantToolResult>()
        .single;
    expect(result.isError, isTrue);
    expect(result.text, 'Denied by user.');
    final tool = conv.state.items.whereType<AssistantToolItem>().single;
    expect(tool.status, AssistantToolStatus.failed);
    expect(tool.summary, 'Denied by user.');
  });

  test('an image result is passed on; unknown tool and bad args are errors',
      () async {
    host.onCall = (c) async => BridgeToolResult.image(
      Uint8List.fromList([9]),
      mimeType: 'image/png',
      text: '10x10',
    );
    provider.script
      ..add(
        AssistantTurn(
          blocks: const [
            AssistantToolCall(id: 'a', name: 'read_file', args: {}),
            AssistantToolCall(id: 'b', name: 'nope', args: {}),
            AssistantToolCall(
              id: 'c',
              name: 'read_file',
              args: {},
              argsError: 'bad args',
            ),
          ],
          stopReason: AssistantStopReason.toolUse,
        ),
      )
      ..add(_text('ok'));
    await conv.send('go');
    final results = provider.sent[1].messages.last.blocks
        .whereType<AssistantToolResult>()
        .toList();
    expect(results[0].image, isNotNull);
    expect(results[0].imageMimeType, 'image/png');
    expect(results[1].isError, isTrue);
    expect(results[1].text, contains('no tool called nope'));
    expect(results[2].text, 'bad args');
    expect(host.calls.length, 1);
  });

  test('tool result text is cut to 16 KiB before going back', () async {
    host.onCall = (c) async => BridgeToolResult('é' * 20000);
    provider.script
      ..add(_calls([('a', 'read_file', {})]))
      ..add(_text('ok'));
    await conv.send('go');
    final r = provider.sent[1].messages.last.blocks
        .whereType<AssistantToolResult>()
        .single;
    expect(r.text, contains('[output truncated'));
    expect(r.text.length, lessThan(8300));
    expect(truncateAssistantResult('short'), 'short');
  });

  test('the step cap ends the turn after 40 tool calls', () async {
    for (var i = 0; i < 60; i++) {
      provider.script.add(_calls([('t$i', 'read_file', {})]));
    }
    await conv.send('loop forever');
    expect(host.calls.length, assistantMaxToolCalls);
    final last = conv.state.items.last as AssistantNoticeItem;
    expect(last.text, contains('40 tool calls'));
    // The history stays valid: the last assistant call got a result.
    final lastMsg = provider.sent.length;
    expect(lastMsg, 41);
    expect(conv.state.isRunning, isFalse);
  });

  test('the cap leaves no call without a result when several are asked',
      () async {
    conv = make(maxToolCalls: 2);
    provider.script.add(
      _calls([
        ('a', 'read_file', {}),
        ('b', 'read_file', {}),
        ('c', 'read_file', {}),
      ]),
    );
    await conv.send('go');
    expect(host.calls.length, 2);
    // Next message continues with a valid history.
    provider.script.add(_text('fine'));
    await conv.send('again');
    final msgs = provider.sent.last.messages;
    final results = msgs[2].blocks.whereType<AssistantToolResult>().toList();
    expect(results.map((r) => r.callId), ['a', 'b', 'c']);
    expect(results.last.isError, isTrue);
  });

  test('Stop during a tool call cancels its token and ends the turn', () async {
    final started = Completer<void>();
    host.onCall = (c) async {
      started.complete();
      await c.cancel!.whenCancelled;
      return const BridgeToolResult.error('Stopped.');
    };
    provider.script.add(
      _calls([('a', 'run_command', {}), ('b', 'read_file', {})]),
    );
    final done = conv.send('do it');
    await started.future;
    expect(conv.isRunning, isTrue);
    conv.stop();
    await done;
    expect(host.calls.length, 1);
    expect(host.calls.single.cancel!.isCancelled, isTrue);
    expect(provider.sent.length, 1);
    final tool = conv.state.items.whereType<AssistantToolItem>().single;
    expect(tool.status, AssistantToolStatus.stopped);
    expect((conv.state.items.last as AssistantNoticeItem).text, 'Stopped.');
    expect(conv.isRunning, isFalse);
    // Both calls have results in the history, so the chat stays usable.
    provider.script.add(_text('back'));
    await conv.send('hello again');
    final results = provider.sent.last.messages[2].blocks
        .whereType<AssistantToolResult>();
    expect(results.map((r) => r.callId), ['a', 'b']);
  });

  test('Stop during a request cancels it', () async {
    final started = Completer<void>();
    AssistantCancel? seen;
    provider.script.add((AssistantCancel? cancel) async {
      seen = cancel;
      started.complete();
      await cancel!.whenCancelled;
      throw const AssistantFailure(AssistantFailureKind.cancelled, 'Stopped.');
    });
    final done = conv.send('hi');
    await started.future;
    conv.stop();
    await done;
    expect(seen!.isCancelled, isTrue);
    expect(host.calls, isEmpty);
    expect(conv.state.items.last, isA<AssistantNoticeItem>());
    expect((conv.state.items.last as AssistantNoticeItem).isError, isFalse);
    provider.script.add(_text('ok'));
    await conv.send('again');
    expect(conv.state.items.last, isA<AssistantReplyItem>());
  });

  test('a provider error mid-way is shown and the chat stays usable', () async {
    provider.script
      ..add(_calls([('a', 'read_file', {})]))
      ..add(
        const AssistantFailure(
          AssistantFailureKind.rateLimit,
          'Slow down please.',
        ),
      );
    await conv.send('go');
    final notice = conv.state.items.last as AssistantNoticeItem;
    expect(notice.isError, isTrue);
    expect(notice.text, 'Slow down please.');
    expect(conv.isRunning, isFalse);

    provider.script.add(_text('recovered'));
    await conv.send('retry');
    expect((conv.state.items.last as AssistantReplyItem).text, 'recovered');
    // The tool result from before the error is in the history exactly once.
    final msgs = provider.sent.last.messages;
    expect(
      msgs.where((m) => m.blocks.any((b) => b is AssistantToolResult)).length,
      1,
    );
  });

  test('a throwing tool host is an error result, not a crash', () async {
    host.onCall = (c) async => throw StateError('boom internal detail');
    provider.script
      ..add(_calls([('a', 'read_file', {})]))
      ..add(_text('ok'));
    await conv.send('go');
    final r = provider.sent[1].messages.last.blocks
        .whereType<AssistantToolResult>()
        .single;
    expect(r.isError, isTrue);
    expect(r.text, isNot(contains('boom')));
  });

  test('a message sent while running is ignored; empty text too', () async {
    final gate = Completer<AssistantTurn>();
    provider.script.add((AssistantCancel? c) => gate.future);
    final first = conv.send('one');
    await conv.send('two');
    await conv.send('   ');
    gate.complete(_text('done'));
    await first;
    expect(conv.state.items.whereType<AssistantUserItem>().length, 1);
  });

  test('a cut-off reply and an empty reply say so', () async {
    provider.script.add(
      const AssistantTurn(
        blocks: [AssistantTextBlock('part')],
        stopReason: AssistantStopReason.maxTokens,
      ),
    );
    await conv.send('a');
    expect((conv.state.items.last as AssistantNoticeItem).text, contains('cut short'));
  });
}
