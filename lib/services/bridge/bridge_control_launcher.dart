import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'bridge_control_protocol.dart';
import 'bridge_locator.dart';

// The launcher's `control` mode (`secureshellgo-mcp control`): what a paired
// phone runs on this computer over SSH. Like the MCP mode it only carries
// bytes between its stdio and the running app; the app does every check.
//
// Imported by `bin/secureshellgo_mcp.dart`, so, like `bridge_locator.dart`,
// kept free of Flutter and of anything that reaches it.

/// The longest first line (the controller token) read from stdin.
const int bridgeControlMaxTokenLineBytes = 4096;

/// The control mode's whole job, with its streams injected so tests drive
/// it against a real listener without a process.
///
/// The first line of [input] is the controller token (never argv or the
/// environment, where other local users could read it). Then the launcher
/// dials the app announcing a control session, and relays bytes both ways
/// until either side closes: 0 when the phone closed its input first, 1
/// when the app went away first.
///
/// When there is no app to talk to, or the app refuses the phone (not
/// paired, pairing removed, Phone control off), it writes one JSON
/// `error` line ([ControlError]) to [output] and returns 1.
Future<int> runBridgeControlLauncher({
  required Stream<List<int>> input,
  required IOSink output,
  required String? bridgeDir,
  Duration timeout = const Duration(seconds: 5),
}) async {
  final split = _FirstLine(input);
  final token = await split.line;
  Future<int> fail(ControlErrorCode code, String message) async {
    output.writeln(ControlError(code, message).encode());
    await output.flush();
    await split.cancel();
    return 1;
  }

  if (token == null || token.trim().isEmpty) {
    return fail(
      ControlErrorCode.refused,
      'No pairing token was given on the first line.',
    );
  }
  BridgeLink link;
  try {
    if (bridgeDir == null) {
      throw const BridgeDialException(bridgeNotRunningMessage);
    }
    final endpoint = await BridgeLocator(bridgeDir).read();
    if (endpoint == null) {
      throw const BridgeDialException(bridgeNotRunningMessage);
    }
    link = await dialBridge(
      endpoint,
      token: token.trim(),
      timeout: timeout,
      session: bridgeControlSession,
    );
  } on BridgeDialException catch (e) {
    final notThere =
        e.message == bridgeNotRunningMessage ||
        e.message == bridgeNoAnswerMessage ||
        e.message == bridgeMalformedReplyMessage;
    return fail(
      notThere ? ControlErrorCode.notRunning : ControlErrorCode.refused,
      e.message,
    );
  }

  final socket = link.socket;
  // Ends with the app's side, closed or reset, as in the MCP mode.
  final appSideDone = Completer<void>();
  void appSideEnded([Object? _]) {
    if (!appSideDone.isCompleted) appSideDone.complete();
  }

  link.rest.listen(
    output.add,
    onError: appSideEnded,
    onDone: appSideEnded,
    cancelOnError: true,
  );

  var phoneClosed = false;
  unawaited(() async {
    try {
      await socket.addStream(split.rest);
      phoneClosed = true;
      // Half-close: the app sees the end of the phone's input and closes
      // its side, which ends the run.
      await socket.close();
    } catch (_) {
      // The app went away mid-write; [appSideDone] ends with it.
    }
  }());

  await appSideDone.future;
  await output.flush();
  socket.destroy();
  await split.cancel();
  return phoneClosed ? 0 : 1;
}

/// Splits a byte stream into its first line (as text, without the line
/// break) and every byte after it, untouched.
class _FirstLine {
  _FirstLine(Stream<List<int>> input) {
    _sub = input.listen(
      (chunk) {
        if (_lineDone.isCompleted) {
          _rest.add(chunk);
          return;
        }
        final newline = chunk.indexOf(0x0a);
        if (newline < 0) {
          _buffer.add(chunk);
          if (_buffer.length > bridgeControlMaxTokenLineBytes) {
            _finishLine(null);
          }
          return;
        }
        _buffer.add(chunk.sublist(0, newline));
        _finishLine(
          _buffer.length > bridgeControlMaxTokenLineBytes
              ? null
              : _decode(_buffer.takeBytes()),
        );
        if (newline + 1 < chunk.length) {
          _rest.add(Uint8List.fromList(chunk.sublist(newline + 1)));
        }
      },
      onError: (Object e) {
        if (!_lineDone.isCompleted) {
          _finishLine(null);
        } else {
          _rest.addError(e);
        }
      },
      onDone: () {
        if (!_lineDone.isCompleted) {
          // Input ended without a line break: what came is the line.
          _finishLine(
            _buffer.isEmpty ? null : _decode(_buffer.takeBytes()),
          );
        }
        unawaited(_rest.close());
      },
    );
    _rest
      ..onPause = _sub.pause
      ..onResume = _sub.resume;
  }

  late final StreamSubscription<List<int>> _sub;
  final _buffer = BytesBuilder();
  final _lineDone = Completer<String?>();
  final _rest = StreamController<List<int>>();

  /// The first line; null when there was none (empty input, too long, not
  /// UTF-8).
  Future<String?> get line => _lineDone.future;

  /// Everything after the first line.
  Stream<List<int>> get rest => _rest.stream;

  void _finishLine(String? line) {
    if (_lineDone.isCompleted) return;
    var value = line;
    if (value != null && value.endsWith('\r')) {
      value = value.substring(0, value.length - 1);
    }
    _lineDone.complete(value);
  }

  static String? _decode(List<int> bytes) {
    try {
      return const Utf8Decoder().convert(bytes);
    } on FormatException {
      return null;
    }
  }

  Future<void> cancel() => _sub.cancel();
}
