import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/mosh/mosh_bootstrap.dart';
import 'package:secure_shell_go/services/mosh/mosh_client.dart';
import 'package:secure_shell_go/services/mosh/mosh_connection.dart';
import 'package:secure_shell_go/services/remote_exec.dart';
import 'package:xterm/core.dart';

/// The Dart Mosh client against a real `mosh-server`, started directly on this
/// machine with no SSH in between: the unit tests only prove the client agrees
/// with itself, and this proves it agrees with the program it has to talk to.
///
/// It runs `mosh-server new`, reads the `MOSH CONNECT <port> <key>` line it
/// prints, connects [MoshClient] over loopback UDP with that port and key, types
/// a command, and checks the output arrives through the state-sync layer.
///
/// Skipped, with the reason, when `mosh-server` is not on the PATH. Set
/// `SSGO_REQUIRE_MOSH_SERVER=1` (CI does) to make that a failure instead.
///
/// `test/mosh_integration_test.dart` is the heavier, opt-in sibling that starts
/// the server over a throwaway `sshd`, as the app does.
void main() {
  final server = _findMoshServer();
  final required = Platform.environment['SSGO_REQUIRE_MOSH_SERVER'] == '1';
  final skip = Platform.isWindows
      ? 'mosh-server does not run on Windows'
      : server != null || required
      ? null
      : 'mosh-server is not installed (it is in the "mosh" package); '
            'live Mosh interop was not checked';

  test(
    'a real mosh-server accepts the client, and typed commands come back as '
    'screen updates',
    () async {
      if (server == null) {
        fail('SSGO_REQUIRE_MOSH_SERVER=1 but mosh-server is not on the PATH');
      }
      final info = await _startServer(server);
      if (info.pid != null) {
        // Backstop in case the orderly shutdown below does not get through.
        addTearDown(() => Process.killPid(info.pid!));
      }

      final screen = _Screen(80, 24);
      final client = MoshClient(
        key: parseMoshKey(info.key),
        address: InternetAddress.loopbackIPv4,
        port: info.port,
        columns: 80,
        rows: 24,
      );
      client.output.listen(screen.terminal.write);
      addTearDown(
        () => client.close().timeout(
          const Duration(seconds: 10),
          onTimeout: () => const MoshExit(clean: false),
        ),
      );

      await client.connect();
      expect(client.isConnected, isTrue);
      expect(client.connection.rejected, 0);
      await screen.waitFor(r'mosh$');

      client.sendInput('echo live-\$((6*7))\r'.codeUnits);
      await screen.waitFor('live-42');
      // The command line as typed and its output, as a terminal shows them.
      expect(screen.text, contains(r'mosh$ echo live-$((6*7))'));
      expect(client.connection.srtt, lessThan(1000));

      // The size reaches the shell, so state flows the other way as well.
      screen.terminal.resize(100, 30);
      client.resize(100, 30);
      client.sendInput('stty size\r'.codeUnits);
      await screen.waitFor('30 100');
    },
    skip: skip,
    timeout: const Timeout(Duration(seconds: 60)),
  );
}

/// The `mosh-server` on the PATH, or null.
String? _findMoshServer() {
  final separator = Platform.isWindows ? ';' : ':';
  for (final dir in (Platform.environment['PATH'] ?? '').split(separator)) {
    if (dir.isEmpty) continue;
    final file = File('$dir/mosh-server');
    if (file.existsSync()) return file.path;
  }
  return null;
}

/// Runs `mosh-server new` as the app's bootstrap command does, minus SSH: it
/// prints the connection line, detaches, and leaves a plain shell with a fixed
/// prompt whatever the developer's own login shell does.
Future<MoshServerInfo> _startServer(String executable) async {
  final result = await Process.run(
    executable,
    [
      'new',
      '-c',
      '256',
      '-l',
      'LANG=C.UTF-8',
      '--',
      'sh',
      '-c',
      r"PS1='mosh$ ' exec sh -i",
    ],
    environment: {'LANG': 'C.UTF-8', 'LC_ALL': 'C.UTF-8'},
  ).timeout(const Duration(seconds: 20));
  return parseMoshServerOutput(
    ExecResult(
      stdout: '${result.stdout}',
      stderr: '${result.stderr}',
      exitCode: result.exitCode,
    ),
  );
}

/// An xterm terminal fed only by Mosh, read back as text.
class _Screen {
  _Screen(int columns, int rows) : terminal = Terminal(maxLines: 1000) {
    terminal.resize(columns, rows);
  }

  final Terminal terminal;

  String get text => [
    for (var i = 0; i < terminal.viewHeight; i++)
      terminal.buffer.lines[terminal.buffer.scrollBack + i]
          .toString()
          .trimRight(),
  ].join('\n');

  Future<void> waitFor(
    String expected, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!text.contains(expected)) {
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('no "$expected" on screen:\n$text', timeout);
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
}
