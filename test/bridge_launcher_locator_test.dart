import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/bridge/bridge_launcher_locator.dart';

void main() {
  BridgeLauncherCommand locate({
    Map<String, String> env = const {},
    bool windows = false,
    String exe = '/home/u/app/secureshellgo',
    Set<String> files = const {},
    Map<String, String> contents = const {},
  }) => locateBridgeLauncher(
    environment: env,
    isWindows: windows,
    resolvedExecutable: exe,
    fileExists: files.contains,
    readFile: (path) => contents[path],
  );

  // What Flatpak writes at the root of the sandbox, cut to the lines read.
  String flatpakInfo(String appPath) =>
      '[Application]\n'
      'name=com.dhivalabs.secure_shell_go\n'
      'runtime=runtime/org.gnome.Platform/x86_64/51\n'
      '\n'
      '[Instance]\n'
      'instance-id=1234567890\n'
      'app-path=$appPath\n'
      'branch=master\n';
  const flatpakExe = '/app/lib/secureshellgo/secure_shell_go';

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

  group('Flatpak', () {
    test('a user install names the user installation\'s exported command', () {
      final r = locate(
        env: {'FLATPAK_ID': 'com.dhivalabs.secure_shell_go'},
        exe: flatpakExe,
        files: {'/.flatpak-info'},
        contents: {
          '/.flatpak-info': flatpakInfo(
            '/home/u/.local/share/flatpak/app/com.dhivalabs.secure_shell_go/'
            'x86_64/master/0123abcd/files',
          ),
        },
      );
      expect(
        r.command,
        '/home/u/.local/share/flatpak/exports/bin/com.dhivalabs.secure_shell_go',
      );
      expect(r.exists, isTrue);
    });

    test('a system install names the system installation', () {
      final r = locate(
        exe: flatpakExe,
        files: {'/.flatpak-info'},
        contents: {
          '/.flatpak-info': flatpakInfo(
            '/var/lib/flatpak/app/com.dhivalabs.secure_shell_go/'
            'aarch64/master/0123abcd/files',
          ),
        },
      );
      expect(
        r.command,
        '/var/lib/flatpak/exports/bin/com.dhivalabs.secure_shell_go',
      );
    });

    test('an unreadable /.flatpak-info falls back to the system path', () {
      final r = locate(
        env: {'FLATPAK_ID': 'com.dhivalabs.secure_shell_go'},
        exe: flatpakExe,
        files: {'/.flatpak-info'},
      );
      expect(
        r.command,
        '/var/lib/flatpak/exports/bin/com.dhivalabs.secure_shell_go',
      );
      expect(r.exists, isTrue);
    });

    test('FLATPAK_ID with the executable under /app is a Flatpak', () {
      final r = locate(
        env: {'FLATPAK_ID': 'com.dhivalabs.secure_shell_go'},
        exe: flatpakExe,
      );
      expect(
        r.command,
        '/var/lib/flatpak/exports/bin/com.dhivalabs.secure_shell_go',
      );
    });

    test('a FLATPAK_ID passed on by another Flatpak is not this one', () {
      final r = locate(
        env: {'FLATPAK_ID': 'org.gnome.Terminal'},
        exe: '/home/u/app/secureshellgo',
        files: {'/home/u/app/secureshellgo-mcp'},
      );
      expect(r.command, '/home/u/app/secureshellgo-mcp');
    });

    test('an app id holding a slash is never put in the path', () {
      for (final id in ['../../tmp/x', '..', '']) {
        expect(
          flatpakExportedCommand(appId: id),
          '/var/lib/flatpak/exports/bin/com.dhivalabs.secure_shell_go',
        );
      }
    });
  });

  group('AppImage', () {
    test('names the .AppImage file, whose mount point changes', () {
      final r = locate(
        env: {
          'APPIMAGE': '/home/u/Apps/SecureShellGo-1.6.0-x86_64.AppImage',
          'APPDIR': '/tmp/.mount_SecureXYZ123',
        },
        exe: '/tmp/.mount_SecureXYZ123/opt/secureshellgo/secure_shell_go',
        files: {'/home/u/Apps/SecureShellGo-1.6.0-x86_64.AppImage'},
      );
      expect(r.command, '/home/u/Apps/SecureShellGo-1.6.0-x86_64.AppImage');
      expect(r.exists, isTrue);
    });

    test('a moved or deleted AppImage is reported missing', () {
      final r = locate(
        env: {
          'APPIMAGE': '/home/u/Apps/SecureShellGo.AppImage',
          'APPDIR': '/tmp/.mount_SecureXYZ123',
        },
        exe: '/tmp/.mount_SecureXYZ123/opt/secureshellgo/secure_shell_go',
      );
      expect(r.command, '/home/u/Apps/SecureShellGo.AppImage');
      expect(r.exists, isFalse);
    });

    test('APPIMAGE passed on by another AppImage is not this one', () {
      final r = locate(
        env: {
          'APPIMAGE': '/home/u/Apps/Editor.AppImage',
          'APPDIR': '/tmp/.mount_EditorABC',
        },
        exe: '/opt/secureshellgo/secure_shell_go',
      );
      expect(r.command, 'secureshellgo-mcp');
    });

    test('an extracted AppImage gives the launcher beside the app', () {
      final r = locate(
        exe: '/home/u/squashfs-root/opt/secureshellgo/secure_shell_go',
        files: {'/home/u/squashfs-root/opt/secureshellgo/secureshellgo-mcp'},
      );
      expect(
        r.command,
        '/home/u/squashfs-root/opt/secureshellgo/secureshellgo-mcp',
      );
      expect(r.exists, isTrue);
    });
  });

  test('the rpm and Arch package use the bare command', () {
    final r = locate(exe: '/opt/secureshellgo/secure_shell_go');
    expect(r.command, 'secureshellgo-mcp');
    expect(r.exists, isTrue);
  });

  test('Windows never takes the Flatpak or AppImage route', () {
    final r = locate(
      windows: true,
      env: {'FLATPAK_ID': 'x', 'APPIMAGE': '/a', 'APPDIR': r'D:\tools'},
      exe: r'D:\tools\secureshellgo.exe',
      files: {'/.flatpak-info'},
    );
    expect(r.command, r'D:\tools\secureshellgo-mcp.exe');
  });
}
