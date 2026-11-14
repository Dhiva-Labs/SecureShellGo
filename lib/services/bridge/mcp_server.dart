import 'dart:async';
import 'dart:convert';

import '../../app_version.dart';
import 'bridge_channel.dart';
import 'bridge_tool_types.dart';

/// The MCP protocol versions this server speaks, oldest first. The bridge
/// only uses tools, whose wire shape is the same in all three, so
/// negotiating any of them costs nothing.
const List<String> mcpSupportedProtocolVersions = [
  '2024-11-05',
  '2025-03-26',
  '2025-06-18',
];

/// JSON-RPC 2.0 error codes, as MCP uses them.
abstract final class JsonRpcError {
  static const int parseError = -32700;
  static const int invalidRequest = -32600;
  static const int methodNotFound = -32601;
  static const int invalidParams = -32602;
  static const int internalError = -32603;
}

/// The JSON-RPC error a request gets when its connection already has
/// [McpServer.maxInFlight] requests running (an implementation-defined
/// server error).
const int mcpBusyCode = -32000;

/// What the assistant is told on `initialize`, before it has seen a tool.
const String mcpServerInstructions =
    'Read-only access to the servers the user has shared from SecureShell '
    'Go. Call list_hosts first and pass one of its host names to the other '
    'tools. No tool can change a server, run a command of your choosing, or '
    'reveal a password or key. Some paths are not available through the '
    'bridge; a path that is refused may be blocked or may not exist, so do '
    'not retry it or look for another route to it.';

/// A hand-written MCP server (JSON-RPC 2.0 over newline-delimited JSON) for
/// one [BridgeConnection] at a time.
///
/// Hand-written rather than a package because the bridge uses a sliver of
/// the protocol — initialize, ping, tools — and a dependency is not worth
/// that (the PPA build vendors every one). It knows nothing about SSH: the
/// tools come from [tools], and refusal, redaction and audit happen there.
class McpServer {
  McpServer({
    required this.tools,
    String? serverVersion,
    this.instructions = mcpServerInstructions,
    this.maxInFlight = 16,
    this.maxBatch = 16,
  }) : serverVersion = serverVersion ?? appDisplayVersion;

  final BridgeToolHost tools;
  final String serverVersion;
  final String instructions;

  /// Requests one connection may have running at once (a batch counts each
  /// entry). Past it, a request is answered at once with
  /// [mcpBusyCode] rather than queued: the tool host already queues calls
  /// across connections, and a peer that keeps sending without waiting for
  /// answers must not grow an unbounded backlog here.
  final int maxInFlight;

  /// The most entries one batch may carry; more is an invalid request.
  final int maxBatch;

  /// Serves [connection] until its peer closes, then closes it. Requests are
  /// handled concurrently — a ping must not wait behind a 30 s tool call —
  /// and replies go out as each finishes, matched by id.
  ///
  /// When the peer closes its side, calls still running are allowed to
  /// finish and answer first: the launcher half-closes when the client's
  /// stdin ends, and the client may still be waiting on those answers.
  Future<void> serve(BridgeConnection connection) async {
    final inFlight = <Future<void>>{};
    var busy = 0;
    await for (final line in connection.lines) {
      if (line.trim().isEmpty) continue;
      final Object? message;
      try {
        message = jsonDecode(line);
      } on FormatException {
        connection.send(_parseError);
        continue;
      }
      // An oversized batch is refused without running anything, so it
      // costs one slot, not one per entry.
      final oversized = message is List && message.length > maxBatch;
      final weight = message is List && !oversized ? message.length : 1;
      if (!oversized && busy + weight > maxInFlight) {
        final reply = _busyReply(message);
        if (reply != null) connection.send(reply);
        continue;
      }
      busy += weight;
      late final Future<void> work;
      work = _handleDecoded(connection, message)
          .then((reply) {
            if (reply != null) connection.send(reply);
          })
          // One failed reply must not end the session or leave `serve`
          // throwing with the connection open.
          .catchError((Object _) {})
          .whenComplete(() {
            busy -= weight;
            inFlight.remove(work);
          });
      inFlight.add(work);
    }
    await Future.wait(inFlight.toList());
    await connection.close();
  }

  /// The at-capacity answer for [message]: [mcpBusyCode] for each request
  /// in it, nothing for notifications. No tool is touched.
  String? _busyReply(Object? message) {
    Map<String, Object?>? busyFor(Object? m) {
      if (m is! Map || m['method'] is! String || !m.containsKey('id')) {
        return null;
      }
      final id = m['id'];
      return _error(
        id is String || id is num ? id : null,
        mcpBusyCode,
        'Too many requests in progress',
      );
    }

    if (message is List) {
      final replies = [for (final m in message) ?busyFor(m)];
      return replies.isEmpty ? null : jsonEncode(replies);
    }
    final reply = busyFor(message);
    return reply == null ? null : jsonEncode(reply);
  }

  static final String _parseError = jsonEncode(
    _error(null, JsonRpcError.parseError, 'Parse error'),
  );

  /// One line in, at most one line out (null for notifications and
  /// responses). Public so the protocol is testable without a connection.
  Future<String?> handleLine(BridgeConnection connection, String line) async {
    final Object? message;
    try {
      message = jsonDecode(line);
    } on FormatException {
      return _parseError;
    }
    return _handleDecoded(connection, message);
  }

  Future<String?> _handleDecoded(
    BridgeConnection connection,
    Object? message,
  ) async {
    if (message is List) {
      // JSON-RPC batches: 2025-03-26 allows them; later versions drop them,
      // but answering one costs less than explaining why not.
      if (message.isEmpty) {
        return jsonEncode(
          _error(null, JsonRpcError.invalidRequest, 'Empty batch'),
        );
      }
      if (message.length > maxBatch) {
        return jsonEncode(
          _error(null, JsonRpcError.invalidRequest, 'Batch too large'),
        );
      }
      final replies = <Map<String, Object?>>[];
      for (final m in await Future.wait(
        message.map((m) => _handle(connection, m)),
      )) {
        if (m != null) replies.add(m);
      }
      return replies.isEmpty ? null : jsonEncode(replies);
    }
    final reply = await _handle(connection, message);
    return reply == null ? null : jsonEncode(reply);
  }

  Future<Map<String, Object?>?> _handle(
    BridgeConnection connection,
    Object? message,
  ) async {
    if (message is! Map) {
      return _error(null, JsonRpcError.invalidRequest, 'Invalid request');
    }
    final hasId = message.containsKey('id');
    final id = message['id'];
    final method = message['method'];
    if (method == null &&
        (message.containsKey('result') || message.containsKey('error'))) {
      // A response to a request we never send; nothing to answer.
      return null;
    }
    if (message['jsonrpc'] != '2.0' ||
        method is! String ||
        (hasId && id is! String && id is! num)) {
      return _error(
        id is String || id is num ? id : null,
        JsonRpcError.invalidRequest,
        'Invalid request',
      );
    }
    final params = message['params'];
    if (params != null && params is! Map) {
      return hasId
          ? _error(id, JsonRpcError.invalidParams, 'params must be an object')
          : null;
    }

    if (!hasId) {
      // Notifications — `notifications/initialized`, `notifications/
      // cancelled` and anything else — get no reply, by JSON-RPC's rules,
      // even when unknown. A cancelled call is left to finish: every tool
      // is read-only and bounded by its own timeout, and its late reply is
      // one the client is required to ignore.
      return null;
    }

    try {
      final result = switch (method) {
        'initialize' => _initialize(params as Map?),
        'ping' => <String, Object?>{},
        'tools/list' => _listTools(),
        'tools/call' => await _callTool(connection, params as Map?),
        _ => throw _RpcFailure(JsonRpcError.methodNotFound, 'Method not found'),
      };
      return {'jsonrpc': '2.0', 'id': id, 'result': result};
    } on _RpcFailure catch (e) {
      return _error(id, e.code, e.message);
    } catch (_) {
      // A bug in a handler: answer, so the client is not left waiting, and
      // keep the exception text out of the reply.
      return _error(id, JsonRpcError.internalError, 'Internal error');
    }
  }

  Map<String, Object?> _initialize(Map? params) {
    final requested = params?['protocolVersion'];
    if (requested is! String) {
      throw _RpcFailure(
        JsonRpcError.invalidParams,
        'protocolVersion is required',
      );
    }
    // The client's own version when we speak it; otherwise our newest, and
    // the client decides whether it can live with that (the spec's rule).
    final version = mcpSupportedProtocolVersions.contains(requested)
        ? requested
        : mcpSupportedProtocolVersions.last;
    return {
      'protocolVersion': version,
      'capabilities': {'tools': <String, Object?>{}},
      'serverInfo': {'name': 'secureshellgo', 'version': serverVersion},
      'instructions': instructions,
    };
  }

  Map<String, Object?> _listTools() => {
    'tools': [
      for (final t in tools.tools)
        {
          'name': t.name,
          'description': t.description,
          'inputSchema': t.inputSchema,
          if (t.kind == BridgeToolKind.read)
            'annotations': {'readOnlyHint': true},
        },
    ],
  };

  Future<Map<String, Object?>> _callTool(
    BridgeConnection connection,
    Map? params,
  ) async {
    final name = params?['name'];
    if (name is! String) {
      throw _RpcFailure(JsonRpcError.invalidParams, 'name is required');
    }
    final arguments = params?['arguments'];
    if (arguments != null && arguments is! Map) {
      throw _RpcFailure(
        JsonRpcError.invalidParams,
        'arguments must be an object',
      );
    }
    if (!tools.tools.any((t) => t.name == name)) {
      throw _RpcFailure(JsonRpcError.invalidParams, 'Unknown tool: $name');
    }
    BridgeToolResult result;
    try {
      result = await tools.call(
        connection.client,
        name,
        arguments == null
            ? <String, Object?>{}
            : Map<String, Object?>.from(arguments),
      );
    } catch (_) {
      // The tool host reports its own failures as results; reaching here
      // is a bug. The exception text stays out of the reply because it
      // could carry whatever the failing code was holding.
      result = BridgeToolResult.error('$name failed unexpectedly.');
    }
    return {
      'content': [
        {'type': 'text', 'text': result.text},
      ],
      'isError': result.isError,
    };
  }

  static Map<String, Object?> _error(Object? id, int code, String message) => {
    'jsonrpc': '2.0',
    'id': id,
    'error': {'code': code, 'message': message},
  };
}

class _RpcFailure implements Exception {
  _RpcFailure(this.code, this.message);

  final int code;
  final String message;
}
