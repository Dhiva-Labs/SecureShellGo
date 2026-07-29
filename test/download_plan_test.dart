import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/remote_entry.dart';
import 'package:secure_shell_go/services/download_plan.dart';
import 'package:secure_shell_go/services/sftp_service.dart';

/// A remote filesystem made of a map from directory path to its listing.
///
/// The same seam `session_controller_test` uses, scripted differently: what a
/// recursive walk needs to be tested against is a shape (nesting, links,
/// unreadable corners), not bytes.
class TreeFs implements RemoteFileSystem {
  TreeFs(this.tree, {this.unreadable = const {}});

  final Map<String, List<RemoteEntry>> tree;
  final Set<String> unreadable;

  final List<String> listed = [];

  @override
  Future<List<RemoteEntry>> list(String path) async {
    listed.add(path);
    if (unreadable.contains(path)) {
      throw SftpFailure('Permission denied.', isPermissionDenied: true);
    }
    final entries = tree[path];
    if (entries == null) throw SftpFailure('$path is not there any more.');
    return entries;
  }

  @override
  Future<String> home() async => '/home/dev';

  @override
  Future<String> resolve(String path) async => path;

  @override
  Future<int?> sizeOf(String path) async => 0;

  @override
  Future<int> download(
    String remotePath, {
    required Future<void> Function(Uint8List chunk) write,
    TransferProgress? onProgress,
    CancelCheck? isCancelled,
  }) async =>
      0;

  @override
  Future<int> upload(
    String localPath,
    String remotePath, {
    TransferProgress? onProgress,
    CancelCheck? isCancelled,
  }) async =>
      0;

  @override
  Future<bool> exists(String path) async => tree.containsKey(path);

  // The write half of the interface. A directory *walk* never uses it — this
  // fake exists to describe a shape, not to move bytes — so reaching any of
  // these from a plan test is a bug in the test, and says so.
  @override
  Future<RemoteFileWriter> openWrite(String remotePath) async =>
      throw UnimplementedError('a walk never writes');

  @override
  Future<void> remove(String path) async =>
      throw UnimplementedError('a walk never deletes');

  @override
  Future<void> rename(String from, String to) async =>
      throw UnimplementedError('a walk never renames');

  @override
  Future<void> close() async {}
}

RemoteEntry dir(String path) => RemoteEntry(
      name: path.split('/').last,
      path: path,
      kind: RemoteEntryKind.directory,
    );

RemoteEntry file(String path, {int size = 100}) => RemoteEntry(
      name: path.split('/').last,
      path: path,
      kind: RemoteEntryKind.file,
      size: size,
    );

RemoteEntry link(String path, {bool? toDirectory}) => RemoteEntry(
      name: path.split('/').last,
      path: path,
      kind: RemoteEntryKind.symlink,
      linkTargetIsDirectory: toDirectory,
    );

void main() {
  group('a nested tree', () {
    late TreeFs fs;

    setUp(() {
      fs = TreeFs({
        '/home/dev/project': [
          dir('/home/dev/project/src'),
          dir('/home/dev/project/docs'),
          file('/home/dev/project/README.md', size: 500),
        ],
        '/home/dev/project/src': [
          file('/home/dev/project/src/main.dart', size: 1000),
          dir('/home/dev/project/src/util'),
        ],
        '/home/dev/project/src/util': [
          file('/home/dev/project/src/util/paths.dart', size: 250),
        ],
        '/home/dev/project/docs': [
          file('/home/dev/project/docs/guide.md', size: 750),
        ],
      });
    });

    test('finds every file and totals what the listings reported', () async {
      final plan = await planDirectoryDownload(fs, '/home/dev/project');

      expect(plan.fileCount, 4);
      expect(plan.totalBytes, 2500);
      expect(plan.rootName, 'project');
      expect(plan.truncated, isFalse);
      expect(plan.unreadable, isEmpty);
    });

    test('mirrors the subdirectory structure under the folder name', () async {
      final plan = await planDirectoryDownload(fs, '/home/dev/project');
      final destinations = plan.files.map((f) => f.destination).toSet();

      expect(destinations, {
        'Downloads/project/README.md',
        'Downloads/project/src/main.dart',
        'Downloads/project/src/util/paths.dart',
        'Downloads/project/docs/guide.md',
      });
    });

    test('carries the remote path and size of each file through', () async {
      final plan = await planDirectoryDownload(fs, '/home/dev/project');
      final main = plan.files.firstWhere((f) => f.fileName == 'main.dart');

      expect(main.remotePath, '/home/dev/project/src/main.dart');
      expect(main.relativeDirectory, 'project/src');
      expect(main.size, 1000);
    });

    test('an empty directory plans nothing rather than failing', () async {
      final empty = TreeFs({'/home/dev/empty': const []});
      final plan = await planDirectoryDownload(empty, '/home/dev/empty');

      expect(plan.isEmpty, isTrue);
      expect(plan.totalBytes, 0);
    });
  });

  group('symlinks', () {
    test('a link that points back up its own tree cannot loop the walk',
        () async {
      // `ln -s .. loop` inside a directory is the classic way to make a
      // naive recursive copy run until it fills the disk.
      final fs = TreeFs({
        '/data': [
          file('/data/a.txt'),
          link('/data/loop', toDirectory: true),
        ],
        '/data/loop': [
          file('/data/loop/a.txt'),
          link('/data/loop/loop', toDirectory: true),
        ],
      });

      final plan = await planDirectoryDownload(fs, '/data');

      expect(plan.fileCount, 1);
      expect(plan.skippedLinks, 1);
      // The link's target was never even listed, so no round trip was spent
      // on it.
      expect(fs.listed, ['/data']);
    });

    test('a link to a file is skipped rather than downloaded twice', () async {
      final fs = TreeFs({
        '/data': [
          file('/data/real.log'),
          link('/data/latest.log', toDirectory: false),
        ],
      });

      final plan = await planDirectoryDownload(fs, '/data');

      expect(plan.files.map((f) => f.fileName), ['real.log']);
      expect(plan.skippedLinks, 1);
    });
  });

  group('cancellation', () {
    test('stops the walk and refuses to hand back a partial plan', () async {
      final fs = TreeFs({
        '/data': [dir('/data/one'), dir('/data/two')],
        '/data/one': [file('/data/one/a.txt')],
        '/data/two': [file('/data/two/b.txt')],
      });

      var cancelled = false;
      await expectLater(
        planDirectoryDownload(
          fs,
          '/data',
          isCancelled: () {
            // Let the root listing happen, then pull the plug — a plan that
            // stopped early must not be mistaken for the whole tree.
            final stop = cancelled;
            cancelled = true;
            return stop;
          },
        ),
        throwsA(isA<DirectoryWalkCancelled>()),
      );

      expect(fs.listed, ['/data']);
    });

    test('a cancel before the first listing does no work at all', () async {
      final fs = TreeFs({'/data': [file('/data/a.txt')]});

      await expectLater(
        planDirectoryDownload(fs, '/data', isCancelled: () => true),
        throwsA(isA<DirectoryWalkCancelled>()),
      );
      expect(fs.listed, isEmpty);
    });
  });

  group('awkward trees', () {
    test('an unreadable subdirectory is recorded, not fatal', () async {
      final fs = TreeFs(
        {
          '/data': [dir('/data/secret'), file('/data/a.txt')],
          '/data/secret': [file('/data/secret/b.txt')],
        },
        unreadable: {'/data/secret'},
      );

      final plan = await planDirectoryDownload(fs, '/data');

      expect(plan.files.map((f) => f.fileName), ['a.txt']);
      expect(plan.unreadable, ['/data/secret']);
    });

    test('a hostile name cannot steer the file out of its folder', () async {
      final fs = TreeFs({
        '/data': [
          dir('/data/../etc'),
          file('/data/../../evil.sh'),
        ],
        '/data/../etc': [file('/data/../etc/passwd')],
      });

      final plan = await planDirectoryDownload(fs, '/data');

      for (final planned in plan.files) {
        expect(planned.fileName, isNot(contains('/')));
        expect(planned.relativeDirectory, isNot(contains('..')));
        expect(planned.destination, startsWith('Downloads/data'));
      }
    });

    test('the file cap stops a runaway tree and says the plan is partial',
        () async {
      final fs = TreeFs({
        '/data': [for (var i = 0; i < 10; i++) file('/data/f$i.txt')],
      });

      final plan = await planDirectoryDownload(fs, '/data', maxFiles: 4);

      expect(plan.fileCount, 4);
      expect(plan.truncated, isTrue);
    });

    test('the depth cap stops descending but keeps what it already found',
        () async {
      final fs = TreeFs({
        '/data': [file('/data/a.txt'), dir('/data/deep')],
        '/data/deep': [file('/data/deep/b.txt')],
      });

      final plan = await planDirectoryDownload(fs, '/data', maxDepth: 0);

      expect(plan.files.map((f) => f.fileName), ['a.txt']);
      expect(plan.truncated, isTrue);
      expect(fs.listed, ['/data']);
    });

    test('a directory whose own name is junk still lands somewhere sane',
        () async {
      final fs = TreeFs({
        '/...': [file('/.../a.txt')],
      });

      final plan = await planDirectoryDownload(fs, '/...');

      expect(plan.rootName, 'download');
      expect(plan.files.single.destination, 'Downloads/download/a.txt');
    });
  });
}
