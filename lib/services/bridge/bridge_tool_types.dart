import 'dart:async';

import 'bridge_client_store.dart';

/// What a bridge tool does to a server, which is what the policy decides on.
///
/// - [read] tools only look, on hosts the user shared.
/// - [change] tools change a server, and only on a host set to "ask to
///   change": each call needs a person's yes in the app, unless the command
///   is on that host's allowed list or a time-limited approval is live.
/// - [terminal] opens an interactive shell; it needs the host's terminal
///   switch on and a yes on every call (no allowed command or time-limited
///   approval ever opens one).
/// - [terminalUse] types into, reads or closes a terminal [terminal] opened:
///   no card per call (that is what the yes to open it allowed), but only
///   by the client that opened it, while it is still the assistant's (not
///   taken over, stopped or closed), and while its host still allows a
///   terminal.
enum BridgeToolKind { read, change, terminal, terminalUse }

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

/// Lets the protocol layer stop one call it started, without knowing how
/// the tool host runs calls. The MCP server makes one per `tools/call` and
/// cancels it on `notifications/cancelled`; the tool host then abandons the
/// call (its pending approval withdrawn, its remote work halted).
class BridgeCallToken {
  final Completer<void> _cancelled = Completer<void>();

  bool get isCancelled => _cancelled.isCompleted;

  /// Completes once, when [cancel] is first called; never errors.
  Future<void> get whenCancelled => _cancelled.future;

  /// Idempotent.
  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }
}

/// The registry the MCP server serves. Kept abstract so the protocol layer
/// can be tested with a fake and the real tools (P4) plug in without the
/// protocol knowing anything about SSH.
abstract class BridgeToolHost {
  List<BridgeToolSpec> get tools;

  /// Runs [name] for [client]. Only called with a [name] that is in
  /// [tools]; argument validation is the host's job, since only it knows
  /// what each argument means.
  ///
  /// [cancel], when given, may be cancelled while the call is in flight; the
  /// host then stops the call as it would on a revoke. What it returns for
  /// a cancelled call is not sent anywhere (the caller drops it), but it
  /// must still return.
  Future<BridgeToolResult> call(
    BridgeClient client,
    String name,
    Map<String, Object?> args, {
    BridgeCallToken? cancel,
  });
}
