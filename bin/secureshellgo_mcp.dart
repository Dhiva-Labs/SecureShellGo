// The AI Bridge launcher: what an MCP-compatible AI assistant runs as its
// stdio server. It only carries bytes between the assistant and the running
// app (see `lib/services/bridge/bridge_locator.dart`); the app does all of
// the MCP, every check, and every SSH connection.
//
// `secureshellgo-mcp control` is the same, for a paired phone acting as
// remote control over SSH: the token comes on the first line of stdin, and
// the bytes after it are the control protocol (see
// `lib/services/bridge/bridge_control_launcher.dart`).
//
// Pure Dart and compiled on its own (`dart compile exe`), so it imports only
// files that never reach Flutter.

import 'dart:io';

import 'package:secure_shell_go/services/bridge/bridge_control_launcher.dart';
import 'package:secure_shell_go/services/bridge/bridge_locator.dart';

Future<void> main(List<String> args) async {
  final bridgeDir = defaultBridgeDirectory(
    environment: Platform.environment,
    isWindows: Platform.isWindows,
    isMacOS: Platform.isMacOS,
  );
  final int code;
  if (args.isNotEmpty && args.first == 'control') {
    code = await runBridgeControlLauncher(
      input: stdin,
      output: stdout,
      bridgeDir: bridgeDir,
    );
  } else {
    code = await runBridgeLauncher(
      input: stdin,
      output: stdout,
      errors: stderr,
      bridgeDir: bridgeDir,
      token: Platform.environment['SSG_BRIDGE_TOKEN'],
    );
  }
  await stdout.flush();
  await stderr.flush();
  exit(code);
}
