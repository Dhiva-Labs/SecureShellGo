import 'dart:convert';
import 'dart:io';

import '../bridge/bridge_tool_types.dart';
import 'assistant_http.dart';
import 'assistant_types.dart';

/// Any OpenAI-compatible chat completions endpoint
/// (`POST {base}/chat/completions`), without streaming. [baseUrl] is
/// required, e.g. `https://api.openai.com/v1`.
class OpenAiCompatibleProvider implements AssistantProvider {
  OpenAiCompatibleProvider({
    required this.apiKey,
    required this.model,
    required this.baseUrl,
    AssistantHttpClientFactory? httpClientFactory,
    this.limits = const AssistantHttpLimits(),
  }) : _clientFactory = httpClientFactory ?? HttpClient.new;

  final String apiKey;
  final String model;
  final String baseUrl;
  final AssistantHttpLimits limits;
  final AssistantHttpClientFactory _clientFactory;

  @override
  Future<AssistantTurn> send({
    required List<AssistantMessage> messages,
    required List<BridgeToolSpec> tools,
    required String system,
    AssistantCancel? cancel,
  }) async {
    if (baseUrl.trim().isEmpty) {
      throw const AssistantFailure(
        AssistantFailureKind.config,
        'Enter the address of the AI service in the assistant settings '
        '(for example https://api.openai.com/v1).',
      );
    }
    final url = checkedAssistantUrl(
      '${baseUrl.trim().replaceFirst(RegExp(r'/+$'), '')}/chat/completions',
      what: 'AI service',
    );
    final response = await assistantPostJson(
      url,
      {
        // A local server may need no key; the header is sent only with one.
        if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
        'content-type': 'application/json',
      },
      buildBody(messages: messages, tools: tools, system: system),
      clientFactory: _clientFactory,
      limits: limits,
      cancel: cancel,
    );
    if (response.status < 200 || response.status >= 300) {
      throw assistantFailureForStatus(
        response.status,
        scrubServiceText(serviceErrorMessage(response.body), apiKey),
      );
    }
    return parseReply(response.body);
  }

  /// The request body. Public for the tests that pin its shape.
  Map<String, Object?> buildBody({
    required List<AssistantMessage> messages,
    required List<BridgeToolSpec> tools,
    required String system,
  }) => {
    'model': model,
    'messages': [
      {'role': 'system', 'content': system},
      for (final m in messages) ..._message(m),
    ],
    if (tools.isNotEmpty)
      'tools': [
        for (final t in tools)
          {
            'type': 'function',
            'function': {
              'name': t.name,
              'description': t.description,
              'parameters': t.inputSchema,
            },
          },
      ],
  };

  static List<Map<String, Object?>> _message(AssistantMessage m) {
    if (m.role == AssistantRole.assistant) {
      final text = [
        for (final b in m.blocks)
          if (b is AssistantTextBlock && b.text.isNotEmpty) b.text,
      ].join('\n\n');
      final calls = [
        for (final b in m.blocks)
          if (b is AssistantToolCall)
            {
              'id': b.id,
              'type': 'function',
              'function': {'name': b.name, 'arguments': jsonEncode(b.args)},
            },
      ];
      return [
        {
          'role': 'assistant',
          'content': text.isEmpty ? null : text,
          if (calls.isNotEmpty) 'tool_calls': calls,
        },
      ];
    }
    // A user message: text, and tool results, each of which is its own
    // `tool` message here. Tool messages are text-only, so an image becomes
    // a short note.
    final out = <Map<String, Object?>>[];
    final text = <String>[];
    for (final b in m.blocks) {
      switch (b) {
        case AssistantTextBlock():
          text.add(b.text);
        case AssistantToolResult():
          final note = b.image == null
              ? ''
              : '[An image (${b.imageMimeType ?? 'image'}, '
                    '${b.image!.length} bytes) was returned; this connection '
                    'cannot carry images.]';
          final content = [b.text, note].where((s) => s.isNotEmpty).join('\n');
          out.add({
            'role': 'tool',
            'tool_call_id': b.callId,
            'content': content.isEmpty ? '(no output)' : content,
          });
        case AssistantToolCall():
          break;
      }
    }
    // Tool messages must directly follow the assistant's tool_calls.
    if (text.isNotEmpty) out.add({'role': 'user', 'content': text.join('\n\n')});
    return out;
  }

  static AssistantTurn parseReply(String body) {
    try {
      final decoded = jsonDecode(body);
      final choices = decoded is Map ? decoded['choices'] : null;
      if (choices is! List || choices.isEmpty || choices.first is! Map) {
        throw unreadableReply;
      }
      final choice = choices.first as Map;
      final message = choice['message'];
      if (message is! Map) throw unreadableReply;
      final blocks = <AssistantBlock>[];
      final content = message['content'];
      if (content is String && content.isNotEmpty) {
        blocks.add(AssistantTextBlock(content));
      }
      final calls = message['tool_calls'];
      if (calls is List) {
        for (final raw in calls) {
          if (raw is! Map || raw['function'] is! Map) throw unreadableReply;
          final fn = raw['function'] as Map;
          final id = raw['id'];
          final name = fn['name'];
          if (id is! String || name is! String) throw unreadableReply;
          blocks.add(_call(id, name, fn['arguments']));
        }
      }
      final hasCalls = blocks.any((b) => b is AssistantToolCall);
      final stop = hasCalls
          ? AssistantStopReason.toolUse
          : choice['finish_reason'] == 'length'
          ? AssistantStopReason.maxTokens
          : AssistantStopReason.endTurn;
      return AssistantTurn(blocks: blocks, stopReason: stop);
    } on AssistantFailure {
      rethrow;
    } catch (_) {
      throw unreadableReply;
    }
  }

  static AssistantToolCall _call(String id, String name, Object? arguments) {
    Object? parsed;
    if (arguments is String) {
      if (arguments.trim().isEmpty) {
        parsed = const <String, Object?>{};
      } else {
        try {
          parsed = jsonDecode(arguments);
        } catch (_) {
          parsed = null;
        }
      }
    } else if (arguments is Map) {
      parsed = arguments;
    }
    if (parsed is Map) {
      return AssistantToolCall(
        id: id,
        name: name,
        args: Map<String, Object?>.from(parsed),
      );
    }
    return AssistantToolCall(
      id: id,
      name: name,
      args: const {},
      argsError: 'The tool arguments were not a valid JSON object.',
    );
  }
}
