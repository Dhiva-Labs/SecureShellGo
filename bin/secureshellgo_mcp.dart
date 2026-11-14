// The AI Bridge launcher: what an MCP-compatible AI assistant runs as its
// stdio server. It only carries bytes between the assistant and the running
// app (see `lib/services/bridge/bridge_locator.dart`); the app does all of
// the MCP, every check, and every SSH connection.
//
// Pure Dart and compiled on its own (`dart compile exe`), so it imports only
// files that never reach Flutter.

import 'dart:io';

import 'package:secure_shell_go/services/bridge/bridge_locator.dart';

Future<void> main() async {
  final code = await runBridgeLauncher(
    input: stdin,
    output: stdout,
    errors: stderr,
    bridgeDir: defaultBridgeDirectory(
      environment: Platform.environment,
      isWindows: Platform.isWindows,
      isMacOS: Platform.isMacOS,
    ),
    token: Platform.environment['SSG_BRIDGE_TOKEN'],
  );
  await stdout.flush();
  await stderr.flush();
  exit(code);
}
