import 'dart:typed_data';

import '../remote_path.dart';
import '../sftp_service.dart';
import '../ssh_service.dart';
import 'agent_failure.dart';
import 'agent_manifest.dart';
import 'agent_probe.dart';
import 'agent_shell.dart';

/// What the agent is being deployed for, which decides the flavour.
enum AgentPurpose {
  /// The account's own logged-in desktop.
  desktop,

  /// A throwaway X display on a Linux server. Always the static x11 build:
  /// it runs on any distribution, and it has no backend that could reach
  /// for a real desktop's session bus.
  virtualDesktop,
}

/// An agent binary that is on the server and matched its pinned hash when
/// it was put there.
class DeployedAgent {
  const DeployedAgent({
    required this.binary,
    required this.directory,
    required this.path,
    required this.uploaded,
  });

  final AgentBinary binary;
  AgentOs get os => binary.os;

  /// The content-addressed directory, in the server's own path syntax.
  final String directory;

  /// The binary itself, in the server's own path syntax:
  /// `/home/me/.cache/secureshellgo/agent/<sha256>/crossshell-host` or
  /// `C:\Users\me\AppData\Local\SecureShellGo\agent\<sha256>\crossshell-host.exe`.
  final String path;

  /// False when the server already had it and nothing was sent.
  final bool uploaded;
}

/// Puts the right agent binary on the server, once.
///
/// **Content-addressed.** The binary lives under a directory named for its
/// SHA-256, so two app versions carrying different agents never overwrite
/// each other's, and "is it already there" is a hash comparison rather than
/// a version check: the upload is skipped exactly when the server's copy
/// hashes to the pinned value, and a damaged or tampered copy is replaced.
///
/// **Checked twice.** Once here, before the uploaded file is moved into
/// place — a short or corrupted transfer never becomes the installed agent
/// — and again by the launcher immediately before every run (see
/// `agent_launcher.dart`), because what matters is what is on the disk at
/// the moment it is executed, not what was there when it was copied.
class AgentDeployer {
  AgentDeployer(this.bundle);

  final AgentBundle bundle;

  /// Bytes per `add` to the SFTP writer. dartssh2 pipelines the write
  /// requests inside each one, so this is a progress granularity, not a
  /// round-trip count.
  static const int uploadChunk = 1 << 20;

  /// The binary for [probe]'s server and [purpose], or an [AgentFailure]
  /// saying why there is none. Pure.
  ///
  /// Linux desktop mode prefers the full build whenever it can load there —
  /// PipeWire present, glibc new enough — because that is the only one with
  /// the Mutter and portal backends. An X11 desktop falls back to the x11
  /// build when it cannot (or when this build has no full one for the CPU,
  /// as with ARM64 today); a Wayland desktop has no fallback, since X11
  /// capture under Wayland sees only XWayland windows.
  AgentBinary choose(RemoteDesktopProbe probe, AgentPurpose purpose) {
    if (!bundle.isAvailable) {
      throw const AgentFailure(
          AgentFailureKind.unavailableInBuild, AgentBundle.unavailableMessage);
    }
    final os = probe.os;
    if (os == null) {
      throw AgentFailure(
        AgentFailureKind.unsupportedRemote,
        probe.family == RemoteOsFamily.macos
            ? 'Remote desktop to a Mac is not supported yet.'
            : 'Remote desktop supports Linux and Windows servers only.',
        details: probe.guess.evidence,
      );
    }
    final arch = probe.arch;
    if (arch == null) {
      final machine = probe.linux?.machine ?? probe.windows?.architecture ?? '';
      throw AgentFailure(
        AgentFailureKind.unsupportedRemote,
        'Remote desktop needs a 64-bit x86 or ARM server; this one reports '
        '"$machine".',
      );
    }
    final manifest = bundle.manifest;
    AgentFailure missing(String what) => AgentFailure(
          AgentFailureKind.unavailableInBuild,
          'This build of SecureShell Go has no remote-desktop agent for '
          '$what.',
        );

    if (os == AgentOs.windows) {
      if (purpose == AgentPurpose.virtualDesktop) {
        throw const AgentFailure(AgentFailureKind.unsupportedRemote,
            'Virtual desktops need a Linux server.');
      }
      return manifest.find(AgentOs.windows, arch, AgentFlavour.full) ??
          (throw missing('Windows on ${arch.label}'));
    }

    final linux = probe.linux!;
    final full = manifest.find(AgentOs.linux, arch, AgentFlavour.full);
    final x11 = manifest.find(AgentOs.linux, arch, AgentFlavour.x11);
    if (purpose == AgentPurpose.virtualDesktop) {
      return x11 ?? (throw missing('virtual desktops on ${arch.label} Linux'));
    }

    final desktop = probe.desktop;
    switch (desktop) {
      case DesktopOfAnotherUser(:final users):
        throw AgentFailure(
          AgentFailureKind.desktopOfAnotherUser,
          'The desktop on this server belongs to ${users.join(', ')}. Sign in '
          'over SSH as that account to see it, or start a virtual desktop.',
        );
      case Headless(:final loginScreen):
        throw AgentFailure(
          AgentFailureKind.noDesktop,
          loginScreen
              ? 'Nobody is signed in to the desktop on this server; it is '
                  'showing its login screen. Start a virtual desktop instead.'
              : 'This account has no desktop on this server. Start a virtual '
                  'desktop instead.',
        );
      case DesktopAvailable(:final kind):
        if (full != null && linux.canRunFull(full)) return full;
        if (kind == DesktopKind.x11) {
          return x11 ?? (throw missing('${arch.label} Linux'));
        }
        if (full == null) {
          throw missing('Wayland desktops on ${arch.label} Linux');
        }
        if (!linux.hasLibPipewire) {
          throw const AgentFailure(
            AgentFailureKind.missingTool,
            'Showing a Wayland desktop needs PipeWire (libpipewire-0.3), '
            'which this server does not have.',
          );
        }
        throw AgentFailure(
          AgentFailureKind.unsupportedRemote,
          'This server\'s C library is too old for the remote-desktop agent '
          '(it needs glibc ${full.minGlibc} or newer).',
          details: 'glibc ${linux.glibcVersion ?? 'not found'}',
        );
    }
  }

  /// Chooses, uploads when needed, verifies, and installs the agent.
  ///
  /// [files] is the session's SFTP view of the server; without one, an SFTP
  /// channel is opened for the upload and closed after it. [onProgress] is
  /// told bytes sent out of the binary's size, and never called when the
  /// upload is skipped.
  Future<DeployedAgent> deploy(
    SessionTransport transport,
    RemoteDesktopProbe probe, {
    required AgentPurpose purpose,
    RemoteFileSystem? files,
    void Function(int sent, int total)? onProgress,
  }) async {
    final binary = choose(probe, purpose);
    final layout = binary.os == AgentOs.windows
        ? _WindowsLayout(binary)
        : _LinuxLayout(binary, probe.linux!.home);

    final prepared = await AgentShell.run(transport, layout.prepareCommand(),
        what: 'prepare the remote-desktop agent folder');
    final lines = AgentShell.lines(prepared.stdout);
    if (lines.contains('SSG-NO-HASH-TOOL')) {
      throw const AgentFailure(
        AgentFailureKind.missingTool,
        'This server has no sha256sum, shasum or openssl, so the '
        'remote-desktop agent could not be checked before it runs.',
      );
    }
    if (!lines.contains('SSG-OK')) {
      throw AgentFailure(
        AgentFailureKind.uploadFailed,
        'Could not create the remote-desktop agent folder on the server.',
        details: _detail(prepared.stdout, prepared.stderr),
      );
    }
    final directory = AgentShell.valueAfter(lines, 'SSG-DIR ') ?? layout.directory;
    final path = layout.binaryPath(directory);
    if (AgentShell.valueAfter(lines, 'SSG-HAVE ') == binary.sha256) {
      return DeployedAgent(
          binary: binary, directory: directory, path: path, uploaded: false);
    }

    final bytes = await bundle.bytesOf(binary);
    final partName = '${binary.installedName}.part-${AgentShell.newId()}';
    final sftpPath = layout.sftpPath(directory, partName);
    final ownFiles = files == null;
    final fs = files ?? SftpService(await transport.openSftp());
    try {
      await _upload(fs, sftpPath, bytes, onProgress);
    } finally {
      if (ownFiles) await fs.close();
    }

    final installed = await AgentShell.run(
        transport,
        layout.installCommand(
            directory, partName, bundle.manifest.agents.map((a) => a.sha256)),
        what: 'install the remote-desktop agent', timeout: const Duration(seconds: 30));
    final out = AgentShell.lines(installed.stdout);
    final mismatch = AgentShell.valueAfter(out, 'SSG-MISMATCH');
    if (mismatch != null) {
      throw AgentFailure(
        AgentFailureKind.hashMismatch,
        'The remote-desktop agent did not arrive on the server intact, so it '
        'was deleted and will not be run.',
        details: 'expected ${binary.sha256}, the server has '
            '${mismatch.isEmpty ? 'an unreadable file' : mismatch}',
      );
    }
    if (!out.contains('SSG-INSTALLED')) {
      throw AgentFailure(
        AgentFailureKind.uploadFailed,
        binary.os == AgentOs.windows
            ? 'Could not put the remote-desktop agent in place on the server. '
                'An earlier copy may still be running, or antivirus removed it.'
            : 'Could not put the remote-desktop agent in place on the server.',
        details: _detail(installed.stdout, installed.stderr),
      );
    }
    return DeployedAgent(
        binary: binary, directory: directory, path: path, uploaded: true);
  }

  static Future<void> _upload(
    RemoteFileSystem fs,
    String path,
    Uint8List bytes,
    void Function(int sent, int total)? onProgress,
  ) async {
    RemoteFileWriter? writer;
    try {
      writer = await fs.openWrite(path);
      for (var at = 0; at < bytes.length; at += uploadChunk) {
        final end = at + uploadChunk < bytes.length ? at + uploadChunk : bytes.length;
        await writer.add(Uint8List.sublistView(bytes, at, end));
        onProgress?.call(end, bytes.length);
      }
      await writer.close();
    } catch (e) {
      await writer?.abort();
      throw AgentFailure(
        AgentFailureKind.uploadFailed,
        'Could not copy the remote-desktop agent to the server.',
        details: e.toString(),
      );
    }
  }

  static String? _detail(String stdout, String stderr) {
    final text = [stdout.trim(), stderr.trim()].where((s) => s.isNotEmpty).join('\n');
    return text.isEmpty ? null : text;
  }
}

/// Where the agent goes on one OS, and the scripts that put it there.
abstract class _Layout {
  String get directory;
  String binaryPath(String directory);
  String sftpPath(String directory, String name);
  String prepareCommand();
  String installCommand(String directory, String partName, Iterable<String> keep);
}

class _LinuxLayout implements _Layout {
  _LinuxLayout(this.binary, this.home);

  final AgentBinary binary;
  final String home;

  String get _base => RemotePath.join(home, '.cache/secureshellgo');

  @override
  String get directory => RemotePath.join(_base, 'agent/${binary.sha256}');

  @override
  String binaryPath(String directory) =>
      RemotePath.join(directory, binary.installedName);

  @override
  String sftpPath(String directory, String name) => RemotePath.join(directory, name);

  /// Makes the folder (0700, as are the two above it that are ours), and
  /// reports the hash of a copy already there.
  @override
  String prepareCommand() => AgentShell.sh('''
umask 077
d=\$1
mkdir -p "\$d" || exit 1
chmod 700 "\$2" "\$3" "\$d" 2>/dev/null
${AgentShell.shHashFunction}
if ! { ${AgentShell.shHasHashTool}; }; then echo SSG-NO-HASH-TOOL; exit 0; fi
f="\$d/${binary.installedName}"
if [ -f "\$f" ]; then echo "SSG-HAVE \$(ssg_hash "\$f")"; fi
echo SSG-OK''', [directory, _base, RemotePath.join(_base, 'agent')]);

  /// chmod, hash, and only then rename over the installed name — so the
  /// installed name only ever holds a file that matched.
  ///
  /// Then agents this build does not carry, [keep] being the hashes it does,
  /// are deleted: an upgrade of the app would otherwise leave every earlier
  /// agent on the server, a few megabytes each. Only the hash-named folders
  /// are touched, and not the other flavour's, which this build also
  /// carries — desktop mode and virtual desktops would otherwise delete each
  /// other's agent and upload it again every time. An agent still running
  /// from a deleted folder carries on: the file goes when the process does.
  @override
  String installCommand(
          String directory, String partName, Iterable<String> keep) =>
      AgentShell.sh('''
d=\$1
p="\$d/\$2"
shift 2
keep=" \$* "
${AgentShell.shHashFunction}
chmod 700 "\$p" || { rm -f "\$p"; exit 1; }
h=\$(ssg_hash "\$p")
if [ "\$h" != ${binary.sha256} ]; then rm -f "\$p"; echo "SSG-MISMATCH \$h"; exit 1; fi
mv -f "\$p" "\$d/${binary.installedName}" || { rm -f "\$p"; exit 1; }
for o in "\${d%/*}"/*; do
  n=\${o##*/}
  case "\$keep" in *" \$n "*) continue ;; esac
  [ \${#n} -eq 64 ] || continue
  case "\$n" in *[!0-9a-f]*) continue ;; esac
  rm -rf "\$o"
done 2>/dev/null
echo SSG-INSTALLED''', [directory, partName, ...keep]);
}

class _WindowsLayout implements _Layout {
  _WindowsLayout(this.binary);

  final AgentBinary binary;

  /// Not known until the server says what `%LOCALAPPDATA%` is; the prepare
  /// script reports it as `SSG-DIR`.
  @override
  String get directory => '';

  @override
  String binaryPath(String directory) => '$directory\\${binary.installedName}';

  @override
  String sftpPath(String directory, String name) =>
      windowsPathToSftp('$directory\\$name');

  String get _relative => 'SecureShellGo\\agent\\${binary.sha256}';

  @override
  String prepareCommand() => AgentShell.powershell('''
${AgentShell.psHashFunction}
\$d=Join-Path \$env:LOCALAPPDATA ${AgentShell.psQuote(_relative)}
New-Item -ItemType Directory -Force -Path \$d|Out-Null
if(-not(Test-Path -LiteralPath \$d)){exit 1}
\$f=Join-Path \$d ${AgentShell.psQuote(binary.installedName)}
if(Test-Path -LiteralPath \$f){'SSG-HAVE '+(SsgHash \$f)}
'SSG-DIR '+\$d
'SSG-OK\'''');

  /// As on Linux: install only a file that matched, then delete agents this
  /// build does not carry. One still running is locked and stays, quietly.
  @override
  String installCommand(
          String directory, String partName, Iterable<String> keep) =>
      AgentShell.powershell('''
${AgentShell.psHashFunction}
\$d=${AgentShell.psQuote(directory)}
\$p=Join-Path \$d ${AgentShell.psQuote(partName)}
\$h=SsgHash \$p
if(\$h -ne '${binary.sha256}'){Remove-Item -LiteralPath \$p -Force -ErrorAction SilentlyContinue;"SSG-MISMATCH \$h";exit 1}
try{Move-Item -LiteralPath \$p -Destination (Join-Path \$d ${AgentShell.psQuote(binary.installedName)}) -Force -ErrorAction Stop}catch{Remove-Item -LiteralPath \$p -Force -ErrorAction SilentlyContinue;'SSG-MV-FAILED '+\$_.Exception.Message;exit 1}
\$k=@(${keep.map((h) => "'$h'").join(',')})
Get-ChildItem -LiteralPath (Split-Path \$d) -Directory -ErrorAction SilentlyContinue|?{\$_.Name -match '^[0-9a-f]{64}\$' -and \$k -notcontains \$_.Name}|Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
'SSG-INSTALLED\'''');
}

/// `C:\Users\me\x` as OpenSSH for Windows' SFTP server spells it:
/// `/C:/Users/me/x`. Anything that is not a drive path — a UNC
/// `%LOCALAPPDATA%`, which roaming setups produce — cannot be reached that
/// way and is refused rather than guessed at.
String windowsPathToSftp(String path) {
  final match = RegExp(r'^([A-Za-z]):[\\/](.*)$').firstMatch(path);
  if (match == null) {
    throw AgentFailure(
      AgentFailureKind.uploadFailed,
      'The Windows folder for the remote-desktop agent is not on a local '
      'drive, so it cannot be copied there over SFTP.',
      details: path,
    );
  }
  return '/${match.group(1)!.toUpperCase()}:/${match.group(2)!.replaceAll('\\', '/')}';
}
