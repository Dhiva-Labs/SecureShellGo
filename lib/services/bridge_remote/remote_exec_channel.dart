import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../bridge/bridge_control_protocol.dart';
import '../bridge/bridge_locator.dart' show linuxApplicationId;
import '../bridge/bridge_tools.dart' show BridgeCommands;
import '../shell_quote.dart';
import '../ssh_service.dart';

/// One command running on the computer, with its stdin and stdout: what
/// [RemoteBridgeController] needs from SSH, and all of it, so tests can
/// fake it without a server.
abstract interface class RemoteExecProcess {
  /// The command's standard output. Ends when the channel closes.
  Stream<List<int>> get stdout;

  /// Writes to the command's standard input.
  void write(List<int> bytes);

  /// Ends the command's standard input.
  Future<void> closeInput();

  /// Completes when the command has ended and its channel is closed.
  Future<void> get done;

  /// The exit status once [done]; null when the server sent none.
  int? get exitCode;

  /// Ends the channel now.
  void close();
}

/// Starts [command] on the computer.
typedef RemoteExecStarter = Future<RemoteExecProcess> Function(String command);

/// A [RemoteExecStarter] over an open SSH connection, through the same
/// exec channel every other remote command of the app uses
/// ([SessionTransport.execute]). The connection is the caller's: closing a
/// process never closes it.
RemoteExecStarter remoteExecOver(SessionTransport transport) =>
    (command) async => _SshExecProcess(await transport.execute(command));

class _SshExecProcess implements RemoteExecProcess {
  _SshExecProcess(this._session) {
    // Standard error is not part of the protocol; drained so a chatty
    // command cannot stall the channel's window.
    _session.stderr.listen((_) {}, onError: (Object _) {});
  }

  final SSHSession _session;

  @override
  Stream<List<int>> get stdout => _session.stdout;

  @override
  void write(List<int> bytes) =>
      _session.stdin.add(bytes is Uint8List ? bytes : Uint8List.fromList(bytes));

  @override
  Future<void> closeInput() => _session.stdin.close();

  @override
  Future<void> get done => _session.done;

  @override
  int? get exitCode => _session.exitCode;

  @override
  void close() {
    try {
      _session.close();
    } catch (_) {
      // Already closed.
    }
  }
}

/// Where the launcher may be installed on the computer, tried in this
/// order: on the PATH (a package, or a link to a tarball install), the
/// snap's command (`secureshellgo.mcp`, also by its full path, since a
/// non-interactive SSH shell often has no `/snap/bin` on its PATH), and
/// the tarball's default folder. The Flatpak is tried last.
const List<String> remoteLauncherCandidates = [
  'secureshellgo-mcp',
  'secureshellgo.mcp',
  '/snap/bin/secureshellgo.mcp',
  '/opt/secureshellgo/secureshellgo-mcp',
];

/// The one command the phone runs on the computer: `secureshellgo-mcp
/// control` from the first of [remoteLauncherCandidates] that exists, else
/// the Flatpak's launcher, else one JSON error line
/// ([ControlErrorCode.launcherNotFound]) and exit status 127.
///
/// A POSIX `sh -c` script, quoted as one word for whatever login shell the
/// account has (fish included), so it reads the same everywhere. Nothing
/// in it reads stdin, so the token line reaches the launcher untouched.
String remoteControlCommand() {
  final q = posixSingleQuote;
  final lines = <String>[
    for (final c in remoteLauncherCandidates)
      c.startsWith('/')
          ? 'if [ -x ${q(c)} ]; then exec ${q(c)} control; fi'
          : 'if command -v ${q(c)} >/dev/null 2>&1 </dev/null; then '
                'exec ${q(c)} control; fi',
    'if command -v flatpak >/dev/null 2>&1 </dev/null && '
        'flatpak info ${q(linuxApplicationId)} >/dev/null 2>&1 </dev/null; '
        'then exec flatpak run --command=secureshellgo-mcp '
        '${q(linuxApplicationId)} control; fi',
    'printf "%s\\n" ${q(const ControlError(ControlErrorCode.launcherNotFound, 'SecureShell Go was not found on this computer, or it is older than 1.8.0.').encode())}',
    'exit 127',
  ];
  return 'sh -c ${BridgeCommands.loginShellQuote(lines.join('\n'))}';
}
