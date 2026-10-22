import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/sftp_service.dart';

/// [SftpService.upload] against an in-memory SFTP server.
///
/// Replacing a file used to open the target itself with truncate, so the
/// file being replaced was gone before a byte arrived: a dropped connection
/// left half a file, and a cancel — which then removed the partial upload —
/// left nothing at all.
void main() {
  late Directory tempDir;
  late File local;
  late _FakeSftpClient server;
  late SftpService sftp;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sftp_upload_test');
    local = File('${tempDir.path}/deploy.sh');
    await local.writeAsString('#!/bin/sh\necho new\n');
    server = _FakeSftpClient();
    server.files['/srv/deploy.sh'] = Uint8List.fromList('old'.codeUnits);
    server.modes['/srv/deploy.sh'] = 0x1ed; // 0755
    sftp = SftpService(server);
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  String contents(String path) => String.fromCharCodes(server.files[path]!);

  test('a replace is written beside the file and renamed over it', () async {
    await sftp.upload(local.path, '/srv/deploy.sh');

    expect(contents('/srv/deploy.sh'), '#!/bin/sh\necho new\n');
    expect(server.opened.single, isNot('/srv/deploy.sh'),
        reason: 'the target itself is never opened for writing');
    expect(server.opened.single, startsWith('/srv/.deploy.sh.ssg-part-'));
    expect(server.files.keys, ['/srv/deploy.sh'], reason: 'no temp left');
  });

  test('the replaced file keeps its permissions', () async {
    await sftp.upload(local.path, '/srv/deploy.sh');
    expect(server.modes['/srv/deploy.sh'], 0x1ed);
  });

  test('a cancelled replace leaves the original exactly as it was', () async {
    await sftp.upload(local.path, '/srv/deploy.sh', isCancelled: () => true);

    expect(contents('/srv/deploy.sh'), 'old');
    expect(server.files.keys, ['/srv/deploy.sh']);
  });

  test('an upload that did not fully land never touches the original',
      () async {
    server.dropWritesAfter = 4;
    await expectLater(
      sftp.upload(local.path, '/srv/deploy.sh'),
      throwsA(isA<SftpFailure>()),
    );
    expect(contents('/srv/deploy.sh'), 'old');
    expect(server.files.keys, ['/srv/deploy.sh']);
  });

  test('a server that will not rename onto a name gets remove, then rename',
      () async {
    server.renameRefusesExisting = true;
    await sftp.upload(local.path, '/srv/deploy.sh');
    expect(contents('/srv/deploy.sh'), '#!/bin/sh\necho new\n');
    expect(server.files.keys, ['/srv/deploy.sh']);
  });

  test('a new file lands under its name', () async {
    await sftp.upload(local.path, '/srv/fresh.sh');
    expect(contents('/srv/fresh.sh'), '#!/bin/sh\necho new\n');
  });
}

class _FakeSftpClient implements SftpClient {
  final Map<String, Uint8List> files = {};
  final Map<String, int> modes = {};
  final List<String> opened = [];

  /// Bytes past this offset are silently lost, the way a write the server
  /// never acknowledged is.
  int? dropWritesAfter;

  /// SSH_FXP_RENAME without `posix-rename`: refuses an existing target.
  bool renameRefusesExisting = false;

  @override
  Future<SftpFile> open(
    String path, {
    SftpFileOpenMode mode = SftpFileOpenMode.read,
  }) async {
    opened.add(path);
    files[path] = Uint8List(0);
    return _FakeSftpFile(this, path);
  }

  @override
  Future<SftpFileAttrs> stat(String path, {bool followLink = true}) async {
    final data = files[path];
    if (data == null) throw SftpStatusError(2, 'No such file');
    final mode = modes[path];
    return SftpFileAttrs(
      size: data.length,
      mode: mode == null ? null : SftpFileMode.value(0x8000 | mode),
    );
  }

  @override
  Future<void> setStat(String path, SftpFileAttrs attrs) async {
    final mode = attrs.mode;
    if (mode != null) modes[path] = mode.value & 0xFFF;
  }

  @override
  Future<void> rename(String oldPath, String newPath) async {
    if (renameRefusesExisting && files.containsKey(newPath)) {
      throw SftpStatusError(4, 'Failure');
    }
    files[newPath] = files.remove(oldPath)!;
    final mode = modes.remove(oldPath);
    if (mode != null) {
      modes[newPath] = mode;
    } else {
      modes.remove(newPath);
    }
  }

  @override
  Future<void> remove(String filename) async {
    if (files.remove(filename) == null) {
      throw SftpStatusError(2, 'No such file');
    }
    modes.remove(filename);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _FakeSftpFile implements SftpFile {
  _FakeSftpFile(this._server, this._path);

  final _FakeSftpClient _server;
  final String _path;

  @override
  Future<void> writeBytes(
    Uint8List data, {
    int offset = 0,
    int chunkSize = 0,
    int maxPendingRequests = 0,
  }) async {
    final limit = _server.dropWritesAfter;
    final kept = limit == null || offset + data.length <= limit
        ? data
        : data.sublist(0, (limit - offset).clamp(0, data.length));
    final current = _server.files[_path]!;
    final grown = Uint8List(offset + kept.length)
      ..setAll(0, current.take(offset))
      ..setAll(offset, kept);
    _server.files[_path] = grown;
  }

  @override
  Future<void> close() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
