import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/remote_entry.dart';
import 'package:secure_shell_go/services/remote_path.dart';

void main() {
  group('normalize', () {
    test('collapses duplicate separators and dot segments', () {
      expect(RemotePath.normalize('/var//log/./nginx'), '/var/log/nginx');
      expect(RemotePath.normalize('/home/dev/../ops'), '/home/ops');
      expect(RemotePath.normalize('/'), '/');
      expect(RemotePath.normalize(''), '/');
    });

    test('an absolute path can never climb above root', () {
      // A server that returns "../../.." in a listing must not be able to
      // walk the browser out of the filesystem.
      expect(RemotePath.normalize('/../../etc'), '/etc');
      expect(RemotePath.normalize('/..'), '/');
    });
  });

  group('join', () {
    test('appends a name to a directory', () {
      expect(RemotePath.join('/var/log', 'syslog'), '/var/log/syslog');
      expect(RemotePath.join('/var/log/', 'syslog'), '/var/log/syslog');
      expect(RemotePath.join('/', 'etc'), '/etc');
    });

    test('an absolute name wins, like a shell', () {
      expect(RemotePath.join('/var/log', '/etc/passwd'), '/etc/passwd');
    });
  });

  group('parent', () {
    test('walks up one level', () {
      expect(RemotePath.parent('/var/log/nginx'), '/var/log');
      expect(RemotePath.parent('/var'), '/');
    });

    test('root is its own parent, so "up" cannot fall off the top', () {
      expect(RemotePath.parent('/'), '/');
    });
  });

  test('basename takes the last segment', () {
    expect(RemotePath.basename('/var/log/syslog'), 'syslog');
    expect(RemotePath.basename('/'), '/');
    expect(RemotePath.basename('/tmp/'), 'tmp');
  });

  test('breadcrumbs run root-first with cumulative paths', () {
    final crumbs = RemotePath.breadcrumbs('/home/dev/src');
    expect(crumbs.map((c) => c.label), ['/', 'home', 'dev', 'src']);
    expect(crumbs.map((c) => c.path), ['/', '/home', '/home/dev', '/home/dev/src']);

    expect(RemotePath.breadcrumbs('/').map((c) => c.path), ['/']);
  });

  group('sanitiseFileName', () {
    test('strips separators so a hostile name cannot steer the save path', () {
      expect(RemotePath.sanitiseFileName('../../evil.sh'), 'evil.sh');
      expect(RemotePath.sanitiseFileName('/etc/passwd'), 'passwd');
      expect(RemotePath.sanitiseFileName('a/b\\c.txt'), 'b_c.txt');
      expect(RemotePath.sanitiseFileName('reports/'), 'reports');
    });

    test('leading dots go, so a download is never invisible on the device', () {
      expect(RemotePath.sanitiseFileName('.bashrc'), 'bashrc');
    });

    test('an empty or all-junk name still produces something saveable', () {
      expect(RemotePath.sanitiseFileName(''), 'download');
      expect(RemotePath.sanitiseFileName('...'), 'download');
    });

    test('an over-long name is trimmed but keeps its extension', () {
      final name = '${'x' * 400}.tar.gz';
      final safe = RemotePath.sanitiseFileName(name);
      expect(safe.length, lessThanOrEqualTo(200));
      expect(safe.endsWith('.gz'), isTrue);
    });
  });

  group('sanitiseRelativeDirectory', () {
    test('keeps an ordinary nested path intact', () {
      expect(
        RemotePath.sanitiseRelativeDirectory('project/src/util'),
        'project/src/util',
      );
      expect(RemotePath.sanitiseRelativeDirectory('project'), 'project');
    });

    test('a recursive download cannot climb out of its own folder', () {
      // Every segment of this comes from a remote listing, so all of it is
      // the server's to choose.
      expect(RemotePath.sanitiseRelativeDirectory('../../etc'), 'etc');
      expect(RemotePath.sanitiseRelativeDirectory('a/../../b'), 'a/b');
      expect(
        RemotePath.sanitiseRelativeDirectory('/etc/cron.d'),
        'etc/cron.d',
      );
    });

    test('leading slashes, doubles and dot segments collapse', () {
      expect(RemotePath.sanitiseRelativeDirectory('/a//b/./c'), 'a/b/c');
      expect(RemotePath.sanitiseRelativeDirectory('   '), '');
      expect(RemotePath.sanitiseRelativeDirectory(''), '');
      expect(RemotePath.sanitiseRelativeDirectory('.'), '');
      expect(RemotePath.sanitiseRelativeDirectory('...'), '');
    });

    test('separators and control characters inside a name are neutralised', () {
      expect(RemotePath.sanitiseRelativeDirectory('a\\b'), 'a_b');
      expect(RemotePath.sanitiseRelativeDirectory('a\u0001b'), 'a_b');
      expect(RemotePath.sanitiseRelativeDirectory('.hidden/sub'), 'hidden/sub');
    });

    test('depth and length are capped, because MediaStore refuses the insert',
        () {
      final deep = List.filled(40, 'x').join('/');
      expect(
        RemotePath.sanitiseRelativeDirectory(deep).split('/'),
        hasLength(16),
      );

      final long = List.filled(10, 'y' * 60).join('/');
      expect(
        RemotePath.sanitiseRelativeDirectory(long).length,
        lessThanOrEqualTo(180),
      );
    });
  });

  group('deduplicate', () {
    test('leaves a free name alone', () {
      expect(RemotePath.deduplicate('report.pdf', (_) => false), 'report.pdf');
    });

    test('inserts a counter before the extension', () {
      final taken = {'report.pdf'};
      expect(RemotePath.deduplicate('report.pdf', taken.contains), 'report (1).pdf');
    });

    test('skips over names already used', () {
      final taken = {'report.pdf', 'report (1).pdf', 'report (2).pdf'};
      expect(RemotePath.deduplicate('report.pdf', taken.contains), 'report (3).pdf');
    });

    test('handles extensionless names', () {
      final taken = {'Makefile'};
      expect(RemotePath.deduplicate('Makefile', taken.contains), 'Makefile (1)');
    });
  });

  test('formatBytes uses binary units and stays readable', () {
    expect(RemotePath.formatBytes(null), '—');
    expect(RemotePath.formatBytes(0), '0 B');
    expect(RemotePath.formatBytes(1023), '1023 B');
    expect(RemotePath.formatBytes(1024), '1.0 KB');
    expect(RemotePath.formatBytes(1536), '1.5 KB');
    expect(RemotePath.formatBytes(1024 * 1024), '1.0 MB');
    expect(RemotePath.formatBytes(1536 * 1024 * 1024), '1.5 GB');
  });

  group('RemoteEntry', () {
    RemoteEntry entry(String name, RemoteEntryKind kind, {bool? linkDir}) =>
        RemoteEntry(
          name: name,
          path: '/base/$name',
          kind: kind,
          linkTargetIsDirectory: linkDir,
        );

    test('sorts directories first, then case-insensitively by name', () {
      final entries = [
        entry('zebra.txt', RemoteEntryKind.file),
        entry('Alpha', RemoteEntryKind.directory),
        entry('apple.txt', RemoteEntryKind.file),
        entry('beta', RemoteEntryKind.directory),
      ]..sort(RemoteEntry.compare);

      expect(
        entries.map((e) => e.name),
        ['Alpha', 'beta', 'apple.txt', 'zebra.txt'],
      );
    });

    test('a symlink to a directory sorts and behaves like a directory', () {
      final link = entry('bin', RemoteEntryKind.symlink, linkDir: true);
      expect(link.isNavigable, isTrue);
      expect(link.isDownloadable, isFalse);

      final sorted = [entry('a.txt', RemoteEntryKind.file), link]
        ..sort(RemoteEntry.compare);
      expect(sorted.first.name, 'bin');
    });

    test('an unresolved symlink is treated as downloadable, not navigable', () {
      final link = entry('config', RemoteEntryKind.symlink);
      expect(link.isNavigable, isFalse);
      expect(link.isDownloadable, isTrue);
    });

    test('a dot-prefixed name reads as hidden', () {
      expect(entry('.bashrc', RemoteEntryKind.file).isHidden, isTrue);
      expect(entry('bashrc', RemoteEntryKind.file).isHidden, isFalse);
    });
  });
}
