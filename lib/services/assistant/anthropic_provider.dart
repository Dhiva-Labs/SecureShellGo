import 'dart:convert';
import 'dart:io';

import '../bridge/bridge_tool_types.dart';
import 'assistant_http.dart';
import 'assistant_types.dart';

/// Anthropic's Messages API (`POST {base}/v1/messages`), without streaming.
class AnthropicProvider implements AssistantProvider {
  AnthropicProvider({
    required this.apiKey,
    required this.model,
    this.baseUrl = defaultBaseUrl,
    this.maxTokens = 4096,
    AssistantHttpClientFactory? httpClientFactory,
    this.limits = const AssistantHttpLimits(),
  }) : _clientFactory = httpClientFactory ?? HttpClient.new;

  static const String defaultBaseUrl = 'https://api.anthropic.com';
  static const String apiVersion = '2023-06-01';

  final String apiKey;
  final String model;
  final String baseUrl;
  final int maxTokens;
  final AssistantHttpLimits limits;
  final AssistantHttpClientFactory _clientFactory;

  @override
  Future<AssistantTurn> send({
    required List<AssistantMessage> messages,
    required List<BridgeToolSpec> tools,
    required String system,
    AssistantCancel? cancel,
  }) async {
    final base = baseUrl.trim().isEmpty ? defaultBaseUrl : baseUrl.trim();
    final url = checkedAssistantUrl(
      '${base.replaceFirst(RegExp(r'/+$'), '')}/v1/messages',
      what: 'Anthropic',
    );
    final response = await assistantPostJson(
      url,
      {
        'x-api-key': apiKey,
        'anthropic-version': apiVersion,
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
    'max_tokens': maxTokens,
    'system': system,
    'messages': [
      for (final m in messages)
        if (m.blocks.isNotEmpty) _message(m),
    ],
    'tools': [
      for (final t in tools)
        {
          'name': t.name,
          'description': t.description,
          'input_schema': t.inputSchema,
        },
    ],
  };

  static Map<String, Object?> _message(AssistantMessage m) => {
    'role': m.role == AssistantRole.user ? 'user' : 'assistant',
    'content': [
      for (final b in m.blocks)
        switch (b) {
          AssistantTextBlock() => {
            'type': 'text',
            // The API refuses an empty text block.
            'text': b.text.isEmpty ? '(empty)' : b.text,
          },
          AssistantToolCall() => {
            'type': 'tool_use',
            'id': b.id,
            'name': b.name,
            'input': b.args,
          },
          AssistantToolResult() => {
            'type': 'tool_result',
            'tool_use_id': b.callId,
            'content': [
              if (b.image != null)
                {
                  'type': 'image',
                  'source': {
                    'type': 'base64',
                    'media_type': b.imageMimeType ?? 'image/png',
                    'data': base64Encode(b.image!),
                  },
                },
              if (b.text.isNotEmpty || b.image == null)
                {
                  'type': 'text',
                  'text': b.text.isEmpty ? '(no output)' : b.text,
                },
            ],
            'is_error': b.isError,
          },
        },
    ],
  };

  static AssistantTurn parseReply(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map || decoded['content'] is! List) {
        throw unreadableReply;
      }
      final blocks = <AssistantBlock>[];
      for (final raw in decoded['content'] as List) {
        if (raw is! Map) continue;
        switch (raw['type']) {
          case 'text':
            final text = raw['text'];
            if (text is String) blocks.add(AssistantTextBlock(text));
          case 'tool_use':
            final id = raw['id'];
            final name = raw['name'];
            final input = raw['input'];
            if (id is! String || name is! String) throw unreadableReply;
            blocks.add(
              AssistantToolCall(
                id: id,
                name: name,
                args: input is Map
                    ? Map<String, Object?>.from(input)
                    : const {},
                argsError: input is Map || input == null
                    ? null
                    : 'The tool arguments were not a JSON object.',
              ),
            );
        }
      }
      final stop = switch (decoded['stop_reason']) {
        'tool_use' => AssistantStopReason.toolUse,
        'max_tokens' => AssistantStopReason.maxTokens,
        _ => AssistantStopReason.endTurn,
      };
      return AssistantTurn(blocks: blocks, stopReason: stop);
    } on AssistantFailure {
      rethrow;
    } catch (_) {
      throw unreadableReply;
    }
  }
}
