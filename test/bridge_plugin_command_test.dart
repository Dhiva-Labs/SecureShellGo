import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/bridge/bridge_plugin_command.dart';

void main() {
  test('a packaged install sends only the token, in three lines', () {
    expect(
      bridgePluginCommands(
        token: 'TOKEN',
        launcher: 'secureshellgo-mcp',
        isWindows: false,
      ),
      'claude plugin marketplace add Dhiva-Labs/SecureShellGo\n'
      'claude plugin install secureshellgo@dhiva-labs\n'
      "printf '%s' '{\"bridge_token\":\"TOKEN\"}' | "
      'claude plugin configure secureshellgo@dhiva-labs --values-stdin',
    );
  });

  test('a launcher path with spaces is sent too (POSIX)', () {
    expect(
      bridgePluginConfigureCommand(
        token: 'TOKEN',
        launcher: '/home/u/SecureShell Go/secureshellgo-mcp',
        isWindows: false,
      ),
      "printf '%s' "
      '\'{"bridge_token":"TOKEN","launcher":"/home/u/SecureShell Go/secureshellgo-mcp"}\''
      ' | claude plugin configure secureshellgo@dhiva-labs --values-stdin',
    );
  });

  test('Windows uses a PowerShell string, backslashes doubled by JSON', () {
    expect(
      bridgePluginConfigureCommand(
        token: 'TOKEN',
        launcher: r'C:\Users\some one\secureshellgo-mcp.exe',
        isWindows: true,
      ),
      '\'{"bridge_token":"TOKEN",'
      r'"launcher":"C:\\Users\\some one\\secureshellgo-mcp.exe"}'
      "' | claude plugin configure secureshellgo@dhiva-labs --values-stdin",
    );
    expect(
      bridgePluginConfigureCommand(
        token: 'TOKEN',
        launcher: 'secureshellgo-mcp',
        isWindows: true,
      ),
      '\'{"bridge_token":"TOKEN"}\' | '
      'claude plugin configure secureshellgo@dhiva-labs --values-stdin',
    );
  });

  test('a single quote in a value is escaped for each shell', () {
    expect(
      bridgePluginConfigureCommand(
        token: "to'ken",
        launcher: 'secureshellgo-mcp',
        isWindows: false,
      ),
      "printf '%s' '{\"bridge_token\":\"to'\\''ken\"}' | "
      'claude plugin configure secureshellgo@dhiva-labs --values-stdin',
    );
    expect(
      bridgePluginConfigureCommand(
        token: "to'ken",
        launcher: 'secureshellgo-mcp',
        isWindows: true,
      ),
      "'{\"bridge_token\":\"to''ken\"}' | "
      'claude plugin configure secureshellgo@dhiva-labs --values-stdin',
    );
  });

  test('the POSIX line hands a real shell the exact JSON', () async {
    final line = bridgePluginConfigureCommand(
      token: "to'ken",
      launcher: "/home/u/Secure Shell's Go/secureshellgo-mcp",
      isWindows: false,
    ).replaceFirst(RegExp(r' \| claude .*$'), ' | cat');
    final result = await Process.run('sh', ['-c', line]);
    expect(
      result.stdout,
      '{"bridge_token":"to\'ken",'
      '"launcher":"/home/u/Secure Shell\'s Go/secureshellgo-mcp"}',
    );
  }, skip: Platform.isWindows);
}
