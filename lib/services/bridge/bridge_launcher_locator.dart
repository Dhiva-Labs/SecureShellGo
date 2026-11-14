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

/// The file Flatpak puts at the root of every sandbox. Nothing outside a
/// sandbox has it, which makes it the reliable test; it also names the
/// installation the app was started from (see [flatpakExportedCommand]).
const String flatpakInfoPath = '/.flatpak-info';

/// Whether this copy of the app runs inside a Flatpak sandbox.
///
/// [flatpakInfoPath] decides it. `FLATPAK_ID` counts too, but only with the
/// executable under `/app/`, where a Flatpak mounts its files: like `SNAP`,
/// the variable can be passed on to a program started from another Flatpak.
bool runsInFlatpak({
  required Map<String, String> environment,
  required String resolvedExecutable,
  required bool Function(String path) pathExists,
}) {
  if (pathExists(flatpakInfoPath)) return true;
  final id = environment['FLATPAK_ID'] ?? '';
  return id.isNotEmpty && resolvedExecutable.startsWith('/app/');
}

/// Whether this copy of the app is the AppImage: the AppImage runtime sets
/// `APPIMAGE` (the .AppImage file) and `APPDIR` (where it is mounted, a new
/// place on every start), and ours runs from under that mount. Both
/// variables are passed on to whatever an AppImage starts, hence the check
/// on the executable.
bool runsFromAppImage({
  required Map<String, String> environment,
  required String resolvedExecutable,
}) {
  final image = environment['APPIMAGE'] ?? '';
  final dir = environment['APPDIR'] ?? '';
  return image.startsWith('/') &&
      dir.isNotEmpty &&
      resolvedExecutable.startsWith('$dir/');
}

/// The host command that runs the Flatpak's main command:
/// `<installation>/exports/bin/<app id>`, the script Flatpak exports for
/// every installed app. The installation (`/var/lib/flatpak` for a system
/// install, `~/.local/share/flatpak` for `--user`, or another one) is read
/// from `app-path` in [info], the contents of [flatpakInfoPath]; the system
/// installation is assumed when that cannot be read.
///
/// One command with no arguments, because that is all the plugin's
/// `launcher` option and the assistants' `command` field take. The main
/// command (`packaging/flatpak/com.dhivalabs.secure_shell_go.yml`) starts
/// the launcher instead of the app when `SSG_BRIDGE_TOKEN` is set and stdin
/// is not a terminal, which is how every assistant starts it.
String flatpakExportedCommand({String? info, String? appId}) {
  String? name;
  String? appPath;
  var section = '';
  for (final raw in (info ?? '').split('\n')) {
    final line = raw.trim();
    if (line.startsWith('[') && line.endsWith(']')) {
      section = line;
      continue;
    }
    final eq = line.indexOf('=');
    if (eq <= 0) continue;
    final key = line.substring(0, eq).trim();
    final value = line.substring(eq + 1).trim();
    if (section == '[Application]' && key == 'name') name = value;
    if (section == '[Instance]' && key == 'app-path') appPath = value;
  }
  bool plainName(String? v) =>
      v != null && v.isNotEmpty && !v.startsWith('.') && !v.contains('/');
  final id =
      [name, appId].firstWhere(plainName, orElse: () => null) ??
      linuxFlatpakAppId;
  var installation = '/var/lib/flatpak';
  final marker = '/app/$id/';
  final cut = appPath?.indexOf(marker) ?? -1;
  if (appPath != null && appPath.startsWith('/') && cut > 0) {
    installation = appPath.substring(0, cut);
  }
  return '$installation/exports/bin/$id';
}

/// The Flatpak's application ID, `id:` in
/// `packaging/flatpak/com.dhivalabs.secure_shell_go.yml`.
const String linuxFlatpakAppId = 'com.dhivalabs.secure_shell_go';

/// Works out the launcher command for how this copy of the app is installed.
///
/// - Snap: `secureshellgo.mcp`, the snap's second app (the sandbox cannot be
///   reached by a path under `/snap`, which changes with every revision).
/// - Flatpak: the app's exported command on the host (see
///   [flatpakExportedCommand]); `flatpak run
///   --command=secureshellgo-mcp com.dhivalabs.secure_shell_go` reaches the
///   same launcher, but needs arguments.
/// - AppImage: the .AppImage file itself (`$APPIMAGE`). Its mount point
///   changes on every start, so nothing inside it has a lasting path; the
///   AppImage's `AppRun` starts the launcher instead of the app when
///   `SSG_BRIDGE_TOKEN` is set and stdin is not a terminal
///   (`packaging/linux-distros/distro.conf`).
/// - The .deb, .rpm and Arch package (`/opt/secureshellgo`) and the MSIX
///   package (an executable under `\WindowsApps\`, whose folder is versioned
///   and locked): the bare `secureshellgo-mcp`, which the package puts on the
///   PATH.
/// - Anything else (a zip, a tarball, a build from source): the full path of
///   the launcher beside the app's own executable.
///
/// Everything it reads is a parameter, so it can be tested for every install
/// kind from one machine. [fileExists] also answers for [flatpakInfoPath],
/// and [readFile] reads it.
BridgeLauncherCommand locateBridgeLauncher({
  Map<String, String>? environment,
  bool? isWindows,
  String? resolvedExecutable,
  bool Function(String path)? fileExists,
  String? Function(String path)? readFile,
}) {
  final env = environment ?? Platform.environment;
  final windows = isWindows ?? Platform.isWindows;
  final executable = resolvedExecutable ?? Platform.resolvedExecutable;
  final exists = fileExists ?? (path) => File(path).existsSync();
  final read = readFile ?? _readOrNull;

  if (runsFromSnap(environment: env, resolvedExecutable: executable)) {
    return const BridgeLauncherCommand(
      command: 'secureshellgo.mcp',
      exists: true,
    );
  }
  if (!windows) {
    if (runsInFlatpak(
      environment: env,
      resolvedExecutable: executable,
      pathExists: exists,
    )) {
      return BridgeLauncherCommand(
        command: flatpakExportedCommand(
          info: read(flatpakInfoPath),
          appId: env['FLATPAK_ID'],
        ),
        // A host path, which the sandbox cannot look at.
        exists: true,
      );
    }
    if (runsFromAppImage(environment: env, resolvedExecutable: executable)) {
      final image = env['APPIMAGE']!;
      return BridgeLauncherCommand(command: image, exists: exists(image));
    }
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

String? _readOrNull(String path) {
  try {
    return File(path).readAsStringSync();
  } on FileSystemException {
    return null;
  }
}
