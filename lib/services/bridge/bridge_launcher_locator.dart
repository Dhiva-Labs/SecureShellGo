import 'dart:io';

/// The command an assistant's configuration should run to reach the AI
/// Bridge, and whether it can be sure that command exists.
class BridgeLauncherCommand {
  const BridgeLauncherCommand({required this.command, required this.exists});

  /// What to put in the assistant's `command` field: a bare name that is on
  /// the PATH for this install kind, or a full path.
  final String command;

  /// False only when the command is a full path to a file that is not there,
  /// so the screen can say the launcher is missing from this install. Bare
  /// names are installed by the package, so nothing is checked for them.
  final bool exists;

  /// The command a package puts on the PATH; used when the full path is not
  /// the one to show.
  static const String defaultCommand = 'secureshellgo-mcp';
}

/// Whether this copy of the app is the snap.
///
/// `SNAP` alone is not enough: a snap that starts other programs (a terminal
/// or an editor installed as a snap) passes its own `SNAP` on, and a copy of
/// this app started from there is not the snap. Ours runs from under that
/// mount point.
bool runsFromSnap({
  required Map<String, String> environment,
  required String resolvedExecutable,
}) {
  final snap = environment['SNAP'] ?? '';
  return snap.isNotEmpty && resolvedExecutable.startsWith('$snap/');
}

/// Works out the launcher command for how this copy of the app is installed.
///
/// - Snap: `secureshellgo.mcp`, the snap's second app (the sandbox cannot be
///   reached by a path under `/snap`, which changes with every revision).
/// - The .deb (`/opt/secureshellgo`) and the MSIX package (an executable
///   under `\WindowsApps\`, whose folder is versioned and locked): the bare
///   `secureshellgo-mcp`, which the package puts on the PATH.
/// - Anything else (a zip, a tarball, a build from source): the full path of
///   the launcher beside the app's own executable.
///
/// Everything it reads is a parameter, so it can be tested for every install
/// kind from one machine.
BridgeLauncherCommand locateBridgeLauncher({
  Map<String, String>? environment,
  bool? isWindows,
  String? resolvedExecutable,
  bool Function(String path)? fileExists,
}) {
  final env = environment ?? Platform.environment;
  final windows = isWindows ?? Platform.isWindows;
  final executable = resolvedExecutable ?? Platform.resolvedExecutable;
  final exists = fileExists ?? (path) => File(path).existsSync();

  if (runsFromSnap(environment: env, resolvedExecutable: executable)) {
    return const BridgeLauncherCommand(
      command: 'secureshellgo.mcp',
      exists: true,
    );
  }
  if (windows) {
    if (executable.toLowerCase().contains(r'\windowsapps\')) {
      return const BridgeLauncherCommand(
        command: BridgeLauncherCommand.defaultCommand,
        exists: true,
      );
    }
  } else if (executable.startsWith('/opt/secureshellgo/')) {
    return const BridgeLauncherCommand(
      command: BridgeLauncherCommand.defaultCommand,
      exists: true,
    );
  }

  final separator = windows ? r'\' : '/';
  final cut = executable.lastIndexOf(separator);
  final dir = cut < 0 ? '' : executable.substring(0, cut + 1);
  final path =
      '$dir${BridgeLauncherCommand.defaultCommand}${windows ? '.exe' : ''}';
  return BridgeLauncherCommand(command: path, exists: exists(path));
}
