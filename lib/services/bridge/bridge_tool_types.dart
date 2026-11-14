import 'bridge_client_store.dart';

/// What a bridge tool does to a server, which is what the policy decides on.
///
/// 1.6.0 ships only [read] tools; [change] exists so the rule that refuses
/// changes (`bridge_policy.dart`) is already in place, and tested, before
/// any tool that could change a server is written.
enum BridgeToolKind { read, change }

/// One tool as the MCP layer advertises it in `tools/list`.
///
/// Plain data: the MCP server turns it into the wire shape, and the tool
/// host (`bridge_tools.dart`) owns what calling it actually does.
class BridgeToolSpec {
  const BridgeToolSpec({
    required this.name,
    required this.description,
    required this.inputSchema,
    required this.kind,
  });

  final String name;
  final String description;

  /// A JSON Schema object (`{"type": "object", ...}`), sent as-is.
  final Map<String, Object?> inputSchema;

  final BridgeToolKind kind;
}

/// What a tool call produced: the text the assistant sees, and whether it is
/// a failure the assistant should read as one (MCP's `isError`).
///
/// A refusal or a failed command is a result with [isError] set, not a
/// JSON-RPC error: the protocol reserves its errors for malformed calls, and
/// a result is what the assistant can read and act on.
class BridgeToolResult {
  const BridgeToolResult(this.text, {this.isError = false});

  const BridgeToolResult.error(this.text) : isError = true;

  final String text;
  final bool isError;
}

/// The registry the MCP server serves. Kept abstract so the protocol layer
/// can be tested with a fake and the real tools (P4) plug in without the
/// protocol knowing anything about SSH.
abstract class BridgeToolHost {
  List<BridgeToolSpec> get tools;

  /// Runs [name] for [client]. Only called with a [name] that is in
  /// [tools]; argument validation is the host's job, since only it knows
  /// what each argument means.
  Future<BridgeToolResult> call(
    BridgeClient client,
    String name,
    Map<String, Object?> args,
  );
}
