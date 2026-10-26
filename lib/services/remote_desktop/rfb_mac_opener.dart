/// Opening a VNC screen over the session's SSH connection: a Mac's
/// built-in Screen Sharing, or any VNC server a host already runs.
///
/// Nothing is uploaded or started on the remote. The opener checks what is
/// there with a command or two, opens a `direct-tcpip` channel to the VNC
/// port on the remote's loopback, and runs [RfbClient] over it. There is
/// no local listening port, as for the CrossShell agent.
library;

import 'dart:async';

import 'package:dartssh2/dartssh2.dart' show SSHChannelOpenError, SSHSocket;

import '../remote_exec.dart';
import '../shell_quote.dart';
import '../ssh_service.dart' show SessionTransport;
import 'remote_screen_session.dart';
import 'rfb_client.dart';

export 'rfb_client.dart';

/// Runs one short command on the remote: [RemoteExec.run] on the
/// session's transport, in the app (see [rfbCommandRunner]).
typedef RfbCommandRunner = Future<ExecResult> Function(String command);

/// Opens a channel to [host]:[port] as seen from the remote:
/// `TunnelCarrier.forwardLocal`, in the app.
typedef RfbChannelOpener = Future<SSHSocket> Function(String host, int port);

/// [RemoteExec.run] over [transport], as an [RfbCommandRunner].
RfbCommandRunner rfbCommandRunner(SessionTransport transport) =>
    (command) => RemoteExec.run(transport, command);

/// The VNC port Screen Sharing listens on.
const int rfbDefaultPort = 5900;

/// Why a VNC screen could not be opened. The message is English and fit to
/// show; [kind] is for a screen that words it itself.
class RfbOpenException implements Exception {
  const RfbOpenException(this.kind, this.message);
  final RfbOpenFailure kind;
  final String message;
  @override
  String toString() => message;
}

enum RfbOpenFailure {
  /// The host is not a Mac, so it has no Screen Sharing.
  notMac,

  /// The Mac's Screen Sharing (and Remote Management) is off.
  screenSharingOff,

  /// Nothing listens on the VNC port of a host that is not a Mac.
  noServer,

  /// The SSH server would not open the channel (`AllowTcpForwarding no`,
  /// say), or the command to check could not be run.
  sshRefused,
}

/// Opens a Mac's Screen Sharing.
///
/// Checks that the host is a Mac (`uname -s` is Darwin) and that something
/// listens on [port], then connects. When nothing does, it throws an
/// [RfbOpenException] that says how to turn Screen Sharing on, which is a
/// setting only someone at the Mac (or with admin rights there) can change.
///
/// The Command key goes out as Meta, which is how Screen Sharing reads it.
/// [credentials] is asked for the Mac account's user name and password, or
/// for a VNC password when Screen Sharing has one set and offers nothing
/// else.
RemoteScreenOpener rfbMacOpener({
  required RfbCommandRunner run,
  required RfbChannelOpener forwardLocal,
  required RfbCredentialsCallback credentials,
  int port = rfbDefaultPort,
  bool viewOnly = false,
  RfbTiming timing = const RfbTiming(),
}) {
  return ({required progress, required attach}) async {
    progress('Checking that this is a Mac…');
    final ExecResult uname;
    try {
      uname = await run('uname -s');
    } catch (e) {
      throw RfbOpenException(
        RfbOpenFailure.sshRefused,
        'Could not run a command on the remote to check what it is: $e',
      );
    }
    final system = uname.stdout.trim();
    if (system != 'Darwin') {
      throw RfbOpenException(
        RfbOpenFailure.notMac,
        system.isEmpty
            ? 'This host does not look like a Mac, so there is no Screen '
                  'Sharing to connect to.'
            : 'This host is not a Mac (it reports "$system"), so there is '
                  'no Screen Sharing to connect to.',
      );
    }
    progress('Checking that Screen Sharing is on…');
    if (await rfbPortListening(run, port) == false) {
      throw RfbOpenException(
        RfbOpenFailure.screenSharingOff,
        _screenSharingOff,
      );
    }
    return _open(
      progress: progress,
      attach: attach,
      forwardLocal: forwardLocal,
      credentials: credentials,
      host: '127.0.0.1',
      port: port,
      viewOnly: viewOnly,
      timing: timing,
      commandKey: RfbCommandKey.metaKey,
      unreachable: const RfbOpenException(
        RfbOpenFailure.screenSharingOff,
        _screenSharingOff,
      ),
    );
  };
}

/// Opens a VNC server the host already runs, on [host]:[port] as seen
/// from the remote: a Linux desktop with x11vnc, TigerVNC or
/// gnome-remote-desktop's VNC, say.
///
/// With [run], it first checks that something listens there (only for a
/// loopback [host], the only kind the check can see), so the screen can
/// say "nothing is listening" before trying.
RemoteScreenOpener rfbOpener({
  required RfbChannelOpener forwardLocal,
  required RfbCredentialsCallback credentials,
  String host = '127.0.0.1',
  int port = rfbDefaultPort,
  RfbCommandRunner? run,
  bool viewOnly = false,
  RfbCommandKey commandKey = RfbCommandKey.superKey,
  RfbTiming timing = const RfbTiming(),
}) {
  final unreachable = RfbOpenException(
    RfbOpenFailure.noServer,
    'Nothing is listening on $host:$port on the remote. Start a VNC '
    'server there first.',
  );
  return ({required progress, required attach}) async {
    if (run != null && (host == '127.0.0.1' || host == 'localhost')) {
      progress('Checking for a VNC server…');
      if (await rfbPortListening(run, port) == false) throw unreachable;
    }
    return _open(
      progress: progress,
      attach: attach,
      forwardLocal: forwardLocal,
      credentials: credentials,
      host: host,
      port: port,
      viewOnly: viewOnly,
      timing: timing,
      commandKey: commandKey,
      unreachable: unreachable,
    );
  };
}

const _sshOpenConnectFailed = 2;

const _screenSharingOff =
    'Screen Sharing is not turned on on this Mac. On the Mac, open System '
    'Settings → General → Sharing and turn on Screen Sharing (or Remote '
    'Management), then try again.';

/// Whether something listens on TCP [port] on the remote's loopback: true
/// or false when a check could tell, null when none could run.
///
/// Tried in turn, each only if the one before could not say:
/// - `nc -z`, which connects and hangs up. It is the only check that sees
///   macOS's Screen Sharing reliably: launchd holds that socket, and a
///   non-root `lsof` does not show sockets of root's processes.
/// - `lsof`, for a server run by the same account.
/// - `netstat -an` and `ss -ltn`, which list every socket on macOS and
///   Linux respectively, for a host without nc.
///
/// The script runs under `sh -c`, whatever the login shell (zsh on a Mac).
Future<bool?> rfbPortListening(RfbCommandRunner run, int port) async {
  final ExecResult result;
  try {
    result = await run(rfbPortCheckCommand(port));
  } catch (_) {
    return null;
  }
  final out = result.stdout;
  if (out.contains('ssg-listening')) return true;
  if (out.contains('ssg-closed')) return false;
  return null;
}

/// The command behind [rfbPortListening], exposed for tests that run it
/// through a real `sh`.
String rfbPortCheckCommand(int port) {
  final p = '$port';
  final script = [
    'have() { command -v "\$1" >/dev/null 2>&1; }',
    'checked=',
    'if have nc; then checked=1',
    '  nc -z -w 2 127.0.0.1 $p >/dev/null 2>&1 && { echo ssg-listening; exit 0; }',
    'fi',
    'if have lsof; then',
    '  lsof -nP -iTCP:$p -sTCP:LISTEN >/dev/null 2>&1 && { echo ssg-listening; exit 0; }',
    'fi',
    'if have netstat; then checked=1',
    '  netstat -an 2>/dev/null | grep -Eq "[.:]$p[[:space:]].*LISTEN" && { echo ssg-listening; exit 0; }',
    'fi',
    'if have ss; then checked=1',
    '  ss -ltn 2>/dev/null | grep -Eq "[.:]$p[[:space:]]" && { echo ssg-listening; exit 0; }',
    'fi',
    'if [ -n "\$checked" ]; then echo ssg-closed; else echo ssg-unknown; fi',
  ].join('\n');
  return 'sh -c ${posixSingleQuote(script)}';
}

Future<RemoteScreenHandle> _open({
  required RemoteScreenProgress progress,
  required void Function(RemoteScreenSession session) attach,
  required RfbChannelOpener forwardLocal,
  required RfbCredentialsCallback credentials,
  required String host,
  required int port,
  required bool viewOnly,
  required RfbTiming timing,
  required RfbCommandKey commandKey,
  required RfbOpenException unreachable,
}) async {
  progress('Connecting to the VNC server…');
  final SSHSocket socket;
  try {
    socket = await forwardLocal(host, port);
  } catch (e) {
    // A refused connect over there comes back as a channel-open failure
    // with reason 2, SSH_OPEN_CONNECT_FAILED (RFC 4254 § 5.1); reason 1,
    // administratively prohibited, is `AllowTcpForwarding no`.
    if (e is SSHChannelOpenError && e.code == _sshOpenConnectFailed) {
      throw unreachable;
    }
    throw RfbOpenException(
      RfbOpenFailure.sshRefused,
      'The SSH server would not open a channel to $host:$port: $e',
    );
  }
  final client = RfbClient(
    input: socket.stream,
    output: socket.sink,
    timing: timing,
    commandKey: commandKey,
  );
  attach(client);
  try {
    await client.connect(credentials: credentials, viewOnly: viewOnly);
  } catch (_) {
    socket.destroy();
    rethrow;
  }
  var released = false;
  return RemoteScreenHandle(
    session: client,
    release: () async {
      if (released) return;
      released = true;
      await client.close();
      socket.destroy();
    },
  );
}
