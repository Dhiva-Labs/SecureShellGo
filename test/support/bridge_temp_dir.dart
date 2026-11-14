import 'dart:io';

import 'package:secure_shell_go/services/bridge/bridge_channel.dart';

export 'temp_dir.dart' show deleteTempDir;

/// A fresh temp directory for a bridge test, with a short path. Delete it
/// with `deleteTempDir`, after stopping whatever the test started in it.
///
/// POSIX: under `/tmp` rather than `Directory.systemTemp`, because a unix
/// socket's path is capped near 100 bytes and `$TMPDIR` can be long.
/// Windows: the system temp directory, as there is no `/tmp`; the bridge
/// listens on tcp there, so the length of the path does not matter.
Future<Directory> bridgeTempDir(String prefix) =>
    (Platform.isWindows ? Directory.systemTemp : Directory('/tmp')).createTemp(
      prefix,
    );

/// The transport the app listens on here: tcp on Windows, unix elsewhere.
/// For tests about the listener rather than about one transport.
///
/// `SSG_TEST_BRIDGE_TCP=1` forces tcp, to run the Windows path on Linux.
final BridgeTransportKind platformBridgeTransport =
    Platform.isWindows || Platform.environment['SSG_TEST_BRIDGE_TCP'] == '1'
    ? BridgeTransportKind.tcp
    : BridgeTransportKind.unix;

/// The skip for a test that needs a unix socket: the app listens on tcp on
/// Windows, and a unix socket served on a Windows runner has taken it down.
final String? skipUnixSocketOnWindows = Platform.isWindows
    ? 'unix socket; the bridge uses tcp on Windows'
    : null;
