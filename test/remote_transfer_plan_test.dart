import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/remote_entry.dart';
import 'package:secure_shell_go/services/remote_transfer_plan.dart';
import 'package:secure_shell_go/services/sftp_service.dart';
import 'package:secure_shell_go/services/upload_plan.dart';

/// A destination directory with a scripted listing.
class DestinationFs implements RemoteFileSystem {
  DestinationFs(this.contents, {this.listable = true});

  /// Directory path to the names already in it.
  final Map<String, List<String>> contents;

  /// False for the writable-but-not-readable case, which is a real Unix
  /// permission and the reason the fallback probe exists at all.
  final bool listable;

  final List<String> listed = [];
  final List<String> probed = [];

  @override
  Future<List<RemoteEntry>> list(String path) async {
    listed.add(path);
    if (!listable) {
      throw SftpFailure('Permission denied.', isPermissionDenied: true);
    }
    return [
      for (final name in contents[path] ?? const <String>[])
        RemoteEntry(
          name: name,
          path: '$path/$name',
          kind: RemoteEntryKind.file,
        ),
    ];
  }

  @override
  Future<bool> exists(String path) async {
    probed.add(path);
    final directory = path.substring(0, path.lastIndexOf('/'));
    final name = path.substring(path.lastIndexOf('/') + 1);
    return (contents[directory] ?? const <String>[]).contains(name);
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
  Future<RemoteFileWriter> openWrite(String remotePath) async =>
      throw UnimplementedError('planning never writes');

  @override
  Future<void> remove(String path) async =>
      throw UnimplementedError('planning never deletes');

  @override
  Future<void> rename(String from, String to) async =>
      throw UnimplementedError('planning never renames');

  @override
  Future<void> close() async {}
}

RemoteEntry file(String name, {int size = 100}) => RemoteEntry(
      name: name,
      path: '/srv/a/$name',
      kind: RemoteEntryKind.file,
      size: size,
    );

RemoteEntry directory(String name) => RemoteEntry(
      name: name,
      path: '/srv/a/$name',
      kind: RemoteEntryKind.directory,
    );

RemoteEntry symlink(String name) => RemoteEntry(
      name: name,
      path: '/srv/a/$name',
      kind: RemoteEntryKind.symlink,
    );

void main() {
  /// Records every collision the plan asked about, and answers with a script.
  ({UploadCollisionPrompt ask, List<String> asked}) prompt(
    List<UploadCollisionResponse?> answers,
  ) {
    final asked = <String>[];
    var index = 0;
    return (
      asked: asked,
      ask: (String fileName, {required bool offerApplyToAll}) async {
        asked.add(fileName);
        return index < answers.length ? answers[index++] : null;
      },
    );
  }

  group('names that do not collide', () {
    test('are planned as they are, with nothing asked', () async {
      final destination = DestinationFs({'/srv/b': const ['other.txt']});
      final asker = prompt(const []);

      final plan = await planRemoteTransfer(
        entries: [file('report.pdf'), file('notes.md')],
        destination: destination,
        destinationDirectory: '/srv/b',
        ask: asker.ask,
      );

      expect(asker.asked, isEmpty);
      expect(plan.cancelled, isFalse);
      expect(
        plan.transfers.map((t) => t.remoteName),
        ['report.pdf', 'notes.md'],
      );
      expect(plan.transfers.every((t) => !t.overwrite), isTrue);
      // One listing, not one stat per file.
      expect(destination.listed, ['/srv/b']);
      expect(destination.probed, isEmpty);
    });

    test('index back into the files the plan kept, not the selection',
        () async {
      final destination = DestinationFs({'/srv/b': const []});
      final asker = prompt(const []);

      final plan = await planRemoteTransfer(
        entries: [directory('src'), file('report.pdf')],
        destination: destination,
        destinationDirectory: '/srv/b',
        ask: asker.ask,
      );

      // The directory was dropped, so index 0 is the file — reading the index
      // against the original selection would have queued the folder.
      expect(plan.transfers.single.sourceIndex, 0);
      expect(plan.files[plan.transfers.single.sourceIndex].name, 'report.pdf');
    });
  });

  group('collisions reuse the upload decision', () {
    test('replace marks the transfer as an overwrite', () async {
      final destination = DestinationFs({'/srv/b': const ['report.pdf']});
      final asker = prompt(const [
        UploadCollisionResponse(UploadCollisionAction.overwrite),
      ]);

      final plan = await planRemoteTransfer(
        entries: [file('report.pdf')],
        destination: destination,
        destinationDirectory: '/srv/b',
        ask: asker.ask,
      );

      expect(asker.asked, ['report.pdf']);
      expect(plan.transfers.single.remoteName, 'report.pdf');
      expect(plan.transfers.single.overwrite, isTrue);
    });

    test('keep both renames through the same de-duplication downloads use',
        () async {
      final destination = DestinationFs({
        '/srv/b': const ['report.pdf', 'report (1).pdf'],
      });
      final asker = prompt(const [
        UploadCollisionResponse(UploadCollisionAction.keepBoth),
      ]);

      final plan = await planRemoteTransfer(
        entries: [file('report.pdf')],
        destination: destination,
        destinationDirectory: '/srv/b',
        ask: asker.ask,
      );

      expect(plan.transfers.single.remoteName, 'report (2).pdf');
      expect(plan.transfers.single.overwrite, isFalse);
    });

    test('skip leaves the file out and names it', () async {
      final destination = DestinationFs({'/srv/b': const ['report.pdf']});
      final asker = prompt(const [
        UploadCollisionResponse(UploadCollisionAction.skip),
      ]);

      final plan = await planRemoteTransfer(
        entries: [file('report.pdf'), file('notes.md')],
        destination: destination,
        destinationDirectory: '/srv/b',
        ask: asker.ask,
      );

      expect(plan.skipped, ['report.pdf']);
      expect(plan.transfers.map((t) => t.remoteName), ['notes.md']);
    });

    test('apply to all answers the rest of the batch without asking',
        () async {
      final destination = DestinationFs({
        '/srv/b': const ['a.txt', 'b.txt', 'c.txt'],
      });
      final asker = prompt(const [
        UploadCollisionResponse(
          UploadCollisionAction.overwrite,
          applyToAll: true,
        ),
      ]);

      final plan = await planRemoteTransfer(
        entries: [file('a.txt'), file('b.txt'), file('c.txt')],
        destination: destination,
        destinationDirectory: '/srv/b',
        ask: asker.ask,
      );

      expect(asker.asked, ['a.txt']);
      expect(plan.transfers, hasLength(3));
      expect(plan.transfers.every((t) => t.overwrite), isTrue);
    });

    test('a dismissed prompt cancels the batch rather than overwriting',
        () async {
      final destination = DestinationFs({'/srv/b': const ['report.pdf']});
      final asker = prompt(const [null]);

      final plan = await planRemoteTransfer(
        entries: [file('report.pdf'), file('notes.md')],
        destination: destination,
        destinationDirectory: '/srv/b',
        ask: asker.ask,
      );

      expect(plan.cancelled, isTrue);
      expect(plan.transfers, isEmpty);
    });

    test('two files of the same name cannot collapse into one', () async {
      final destination = DestinationFs({'/srv/b': const []});
      final asker = prompt(const [
        UploadCollisionResponse(UploadCollisionAction.keepBoth),
      ]);

      final plan = await planRemoteTransfer(
        entries: [
          file('photo.jpg'),
          RemoteEntry(
            name: 'photo.jpg',
            path: '/srv/a/holiday/photo.jpg',
            kind: RemoteEntryKind.file,
          ),
        ],
        destination: destination,
        destinationDirectory: '/srv/b',
        ask: asker.ask,
      );

      expect(
        plan.transfers.map((t) => t.remoteName),
        ['photo.jpg', 'photo (1).jpg'],
      );
    });
  });

  group('what cannot go across yet', () {
    test('directories and links are named and left alone', () async {
      final destination = DestinationFs({'/srv/b': const []});
      final asker = prompt(const []);

      final plan = await planRemoteTransfer(
        entries: [
          file('report.pdf'),
          directory('src'),
          symlink('latest'),
        ],
        destination: destination,
        destinationDirectory: '/srv/b',
        ask: asker.ask,
      );

      expect(plan.transfers.map((t) => t.remoteName), ['report.pdf']);
      expect(plan.unsupported, ['src', 'latest']);
    });

    test('a selection of nothing but folders costs no round trips', () async {
      final destination = DestinationFs({'/srv/b': const []});
      final asker = prompt(const []);

      final plan = await planRemoteTransfer(
        entries: [directory('src'), directory('docs')],
        destination: destination,
        destinationDirectory: '/srv/b',
        ask: asker.ask,
      );

      expect(plan.isEmpty, isTrue);
      expect(plan.cancelled, isFalse);
      expect(plan.unsupported, ['src', 'docs']);
      // Nothing to name, so nothing to list.
      expect(destination.listed, isEmpty);
    });
  });

  group('a destination directory that will not list', () {
    test('falls back to probing exactly the names about to be created',
        () async {
      final destination = DestinationFs(
        {'/srv/b': const ['report.pdf']},
        listable: false,
      );
      final asker = prompt(const [
        UploadCollisionResponse(UploadCollisionAction.overwrite),
      ]);

      final plan = await planRemoteTransfer(
        entries: [file('report.pdf'), file('notes.md')],
        destination: destination,
        destinationDirectory: '/srv/b',
        ask: asker.ask,
      );

      expect(
        destination.probed,
        ['/srv/b/report.pdf', '/srv/b/notes.md'],
      );
      expect(asker.asked, ['report.pdf']);
      expect(plan.transfers, hasLength(2));
    });
  });
}
