import 'dart:convert';

import '../shell_quote.dart';
import 'bridge_launcher_locator.dart';

/// The Claude Code plugin's two install commands. Fixed text: not translated.
const String bridgePluginMarketplaceCommand =
    'claude plugin marketplace add Dhiva-Labs/SecureShellGo';
const String bridgePluginInstallCommand =
    'claude plugin install secureshellgo@dhiva-labs';

/// The same change as [bridgePluginConfigureCommand] makes, but typed inside
/// a Claude Code session rather than in a terminal.
const String bridgePluginSessionCommand =
    '/plugin configure secureshellgo@dhiva-labs';

/// PowerShell single-quoting: a quote inside is doubled.
String _powershellSingleQuote(String value) =>
    "'${value.replaceAll("'", "''")}'";

/// The shell command that sets the plugin's options without a prompt: the
/// JSON goes in on stdin, so the token never lands in the process list.
/// [launcher] is included only when it is not the plugin's own default.
String bridgePluginConfigureCommand({
  required String token,
  required String launcher,
  required bool isWindows,
}) {
  final values = jsonEncode({
    'bridge_token': token,
    if (launcher != BridgeLauncherCommand.defaultCommand) 'launcher': launcher,
  });
  final printer = isWindows
      ? _powershellSingleQuote(values)
      : "printf '%s' ${posixSingleQuote(values)}";
  return '$printer | claude plugin configure secureshellgo@dhiva-labs '
      '--values-stdin';
}

/// The three commands, one per line, that install the plugin and give it its
/// token (and launcher) from one paste into a terminal.
String bridgePluginCommands({
  required String token,
  required String launcher,
  required bool isWindows,
}) => [
  bridgePluginMarketplaceCommand,
  bridgePluginInstallCommand,
  bridgePluginConfigureCommand(
    token: token,
    launcher: launcher,
    isWindows: isWindows,
  ),
].join('\n');
