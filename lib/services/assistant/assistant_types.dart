import 'dart:async';
import 'dart:typed_data';

import '../bridge/bridge_tool_types.dart';

/// Who a message in the provider's history is from. Tool results travel as
/// a [user] message holding [AssistantToolResult] blocks, as both supported
/// APIs expect them.
enum AssistantRole { user, assistant }

/// One piece of a message.
sealed class AssistantBlock {
  const AssistantBlock();
}

class AssistantTextBlock extends AssistantBlock {
  const AssistantTextBlock(this.text);
  final String text;
}

/// The model asking for a tool to run.
class AssistantToolCall extends AssistantBlock {
  const AssistantToolCall({
    required this.id,
    required this.name,
    required this.args,
    this.argsError,
  });

  /// The provider's id for the call; the result is sent back under it.
  final String id;
  final String name;
  final Map<String, Object?> args;

  /// Set when the provider sent arguments that are not a JSON object. The
  /// conversation then does not run the tool and tells the model instead.
  final String? argsError;
}

/// What a tool returned, going back to the model.
class AssistantToolResult extends AssistantBlock {
  const AssistantToolResult({
    required this.callId,
    required this.name,
    required this.text,
    this.isError = false,
    this.image,
    this.imageMimeType,
  });

  final String callId;
  final String name;
  final String text;
  final bool isError;
  final Uint8List? image;
  final String? imageMimeType;
}

class AssistantMessage {
  const AssistantMessage(this.role, this.blocks);

  AssistantMessage.userText(String text)
    : role = AssistantRole.user,
      blocks = [AssistantTextBlock(text)];

  final AssistantRole role;
  final List<AssistantBlock> blocks;
}

enum AssistantStopReason {
  /// The model finished its reply.
  endTurn,

  /// The model wants its tool calls run.
  toolUse,

  /// The reply was cut at the length limit.
  maxTokens,
}

/// One reply from a provider.
class AssistantTurn {
  const AssistantTurn({required this.blocks, required this.stopReason});

  /// Text and tool-call blocks, in the order the model produced them.
  final List<AssistantBlock> blocks;
  final AssistantStopReason stopReason;

  List<AssistantToolCall> get toolCalls => [
    for (final b in blocks)
      if (b is AssistantToolCall) b,
  ];

  String get text => [
    for (final b in blocks)
      if (b is AssistantTextBlock && b.text.isNotEmpty) b.text,
  ].join('\n\n');
}

/// Stops a provider request in flight. Separate from [BridgeCallToken] so a
/// request and a tool call can be stopped on their own.
class AssistantCancel {
  final Completer<void> _done = Completer<void>();

  bool get isCancelled => _done.isCompleted;
  Future<void> get whenCancelled => _done.future;

  void cancel() {
    if (!_done.isCompleted) _done.complete();
  }
}

enum AssistantFailureKind {
  /// Not set up (no key, no model, a refused address).
  config,

  /// The service did not accept the key.
  auth,

  /// Too many requests, or no credit left.
  rateLimit,

  /// Could not reach the service, or it did not answer in time.
  network,

  /// The service reported a problem on its side.
  server,

  /// A reply that could not be read, or a request the service refused.
  badResponse,

  /// The user pressed Stop.
  cancelled,
}

/// A provider call that failed. [message] is plain text for the user and
/// never holds the API key or any header.
class AssistantFailure implements Exception {
  const AssistantFailure(this.kind, this.message);

  final AssistantFailureKind kind;
  final String message;

  @override
  String toString() => message;
}

/// What the conversation needs from a model service.
abstract class AssistantProvider {
  /// Sends the whole [messages] history and returns the next reply. Throws
  /// [AssistantFailure], and only that.
  Future<AssistantTurn> send({
    required List<AssistantMessage> messages,
    required List<BridgeToolSpec> tools,
    required String system,
    AssistantCancel? cancel,
  });
}
