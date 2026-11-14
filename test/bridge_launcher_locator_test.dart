import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/bridge/bridge_launcher_locator.dart';

void main() {
  BridgeLauncherCommand locate({
    Map<String, String> env = const {},
    bool windows = false,
    String exe = '/home/u/app/secureshellgo',
    Set<String> files = const {},
  }) => locateBridgeLauncher(
    environment: env,
    isWindows: windows,
    resolvedExecutable: exe,
    fileExists: files.contains,
  );

  test('a snap uses the snap app name', () {
    final r = locate(
      env: {'SNAP': '/snap/secureshellgo/12'},
      exe: '/snap/secureshellgo/12/secureshellgo',
    );
    expect(r.command, 'secureshellgo.mcp');
    expect(r.exists, isTrue);
  });

  test('an empty SNAP variable is not a snap', () {
    expect(locate(env: {'SNAP': ''}).command, '/home/u/app/secureshellgo-mcp');
  });

  test('a SNAP passed on by another snap is not this snap', () {
    // Started from the terminal of an editor installed as a snap.
    final r = locate(
      env: {'SNAP': '/snap/code/180', 'SNAP_NAME': 'code'},
      exe: '/home/u/app/secureshellgo',
      files: {'/home/u/app/secureshellgo-mcp'},
    );
    expect(r.command, '/home/u/app/secureshellgo-mcp');
    expect(r.exists, isTrue);
  });

  test('paths with spaces are kept whole', () {
    final linux = locate(
      exe: '/home/u/My Apps/SecureShell Go/secureshellgo',
      files: {'/home/u/My Apps/SecureShell Go/secureshellgo-mcp'},
    );
    expect(linux.command, '/home/u/My Apps/SecureShell Go/secureshellgo-mcp');
    expect(linux.exists, isTrue);

    final windows = locate(
      windows: true,
      exe: r'C:\Program Files\SecureShell Go\secureshellgo.exe',
    );
    expect(
      windows.command,
      r'C:\Program Files\SecureShell Go\secureshellgo-mcp.exe',
    );
    expect(windows.exists, isFalse);
  });

  test('the deb uses the bare command', () {
    final r = locate(exe: '/opt/secureshellgo/secureshellgo');
    expect(r.command, 'secureshellgo-mcp');
    expect(r.exists, isTrue);
  });

  test('an MSIX package uses the bare command', () {
    final r = locate(
      windows: true,
      exe:
          r'C:\Program Files\WindowsApps\DhivaLabs.SecureShellGo_1.6.0_x64\secureshellgo.exe',
    );
    expect(r.command, 'secureshellgo-mcp');
    expect(r.exists, isTrue);
  });

  test('a portable Linux build gives the full path, and whether it exists', () {
    final missing = locate();
    expect(missing.command, '/home/u/app/secureshellgo-mcp');
    expect(missing.exists, isFalse);
    final there = locate(files: {'/home/u/app/secureshellgo-mcp'});
    expect(there.exists, isTrue);
  });

  test('a portable Windows build gives the .exe beside the app', () {
    final r = locate(
      windows: true,
      exe: r'D:\tools\ssg\secureshellgo.exe',
      files: {r'D:\tools\ssg\secureshellgo-mcp.exe'},
    );
    expect(r.command, r'D:\tools\ssg\secureshellgo-mcp.exe');
    expect(r.exists, isTrue);
  });

  test('a path under /opt/secureshellgo-other is not the deb', () {
    expect(
      locate(exe: '/opt/secureshellgo-other/x').command,
      '/opt/secureshellgo-other/secureshellgo-mcp',
    );
  });
}
