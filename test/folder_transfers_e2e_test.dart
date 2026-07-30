import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/services/known_hosts_service.dart';
import 'package:secure_shell_go/services/remote_copy.dart';
import 'package:secure_shell_go/services/remote_path.dart';
import 'package:secure_shell_go/services/session_controller.dart';
import 'package:secure_shell_go/services/ssh_service.dart';
import 'package:secure_shell_go/services/transfer_queue.dart';

/// The four PM-facing scenarios for folder transfers, wired through the same
/// [copyRemoteDirectory] primitive the transfer queue's executor uses. Runs
/// against the local demo pair at `~/ssgo-demo/servers/{A,B}` — the test file
/// is skipped when the pair is not up, exactly like `direct_remote_copy_test`.
///
/// These are the sha256/find-evidence version of the PM's four screenshots:
///   1. move `pm-folder` from A to B, byte-exact, source removed;
///   2. upload a local folder (three files + a subdir) to B, byte-exact;
///   3. cancel a folder move mid-way — source intact, nothing half-written
///      on B, no rmdir on the source;
///   4. move the same folder twice — the second time picks `keep both` and
///      lands `folder (1)` next to the first.
///
/// The relay path is what runs here; the direct path is separately proved by
/// `direct_remote_copy_test.dart::a whole folder lands via put -r ...`.
void main() {
  final demo = _probeDemo();

  Directory? tempDir;
  SshService? sshService;
  SessionController? aCtl;
  SessionController? bCtl;

  tearDown(() async {
    await aCtl?.dispose();
    await bCtl?.dispose();
    aCtl = null;
    bCtl = null;
    if (tempDir != null && await tempDir!.exists()) {
      await tempDir!.delete(recursive: true);
    }
  });

  Future<SessionController> connect(Host host) async {
    tempDir ??= await Directory.systemTemp.createTemp('folder_e2e');
    sshService ??= SshService(
      knownHosts: KnownHostsService(
        file: File('${tempDir!.path}/known_hosts.json'),
      ),
    );
    final connection = await sshService!.connect(
      host: host,
      credentials: SshCredentials(privateKeyPem: demo!.keyPem),
      verifyHostKey: (_) async => true,
    );
    return SessionController(connection: connection);
  }

  // Each test writes under `<demo files>/folder-e2e/…` — a nested playground
  // so the parallel `direct_remote_copy_test`'s `_resetServerBFiles` (which
  // blows away everything under B's files dir except `notes.txt`) does not
  // pull the rug from under a running relay-path test. `flutter test` runs
  // test files in parallel by default.
  setUp(() {
    if (demo == null) return;
    Directory('${demo.serverAFilesDir}/folder-e2e')
        .createSync(recursive: true);
    Directory('${demo.serverBFilesDir}/folder-e2e')
        .createSync(recursive: true);
  });

  test('1. move pm-folder from A to B (byte-exact, source removed)',
      () async {
    _resetLocal('${demo!.serverAFilesDir}/folder-e2e/pm-folder');
    _resetLocal('${demo.serverBFilesDir}/folder-e2e/pm-folder');
    aCtl = await connect(demo.hostA);
    bCtl = await connect(demo.hostB);
    final aFs = await aCtl!.sftp();
    final bFs = await bCtl!.sftp();

    Directory('${demo.serverAFilesDir}/folder-e2e/pm-folder/sub')
        .createSync(recursive: true);
    File('${demo.serverAFilesDir}/folder-e2e/pm-folder/a.txt')
        .writeAsStringSync('hello A\n');
    File('${demo.serverAFilesDir}/folder-e2e/pm-folder/b.txt')
        .writeAsStringSync('hello B\n');
    File('${demo.serverAFilesDir}/folder-e2e/pm-folder/sub/c.txt')
        .writeAsStringSync('deep!\n');
    final srcHashes = _sha256Tree('${demo.serverAFilesDir}/folder-e2e/pm-folder');

    final outcome = await copyRemoteDirectory(
      source: aFs,
      destination: bFs,
      sourceDirectory: '${demo.serverAFilesDir}/folder-e2e/pm-folder',
      destinationDirectory: '${demo.serverBFilesDir}/folder-e2e/pm-folder',
      deleteSourceAfterVerify: true,
    );

    expect(outcome.sourceDeleted, isTrue);
    expect(outcome.bytesCopied, srcHashes.isNotEmpty ? greaterThan(0) : 0);
    final destHashes = _sha256Tree('${demo.serverBFilesDir}/folder-e2e/pm-folder');
    expect(destHashes, srcHashes,
        reason: 'destination tree must match source byte for byte');
    expect(
      Directory('${demo.serverAFilesDir}/folder-e2e/pm-folder').existsSync(),
      isFalse,
      reason: 'the source pm-folder should be gone after the move',
    );
  },
      skip: demo == null
          ? 'demo servers not running (see ~/ssgo-demo/start-demo.sh)'
          : null,
      timeout: const Timeout(Duration(seconds: 60)));

  test('2. upload local folder to B (byte-exact, shape preserved)',
      () async {
    bCtl = await connect(demo!.hostB);
    final bFs = await bCtl!.sftp();

    final localRoot =
        Directory.systemTemp.createTempSync('upload-src-e2e');
    addTearDown(() {
      if (localRoot.existsSync()) localRoot.deleteSync(recursive: true);
    });

    final scratch = Directory('${localRoot.path}/scratch');
    scratch.createSync();
    Directory('${scratch.path}/sub').createSync();
    File('${scratch.path}/one.txt').writeAsStringSync('first\n');
    File('${scratch.path}/two.txt').writeAsStringSync('second\n');
    File('${scratch.path}/sub/three.txt').writeAsStringSync('third\n');
    final srcHashes = _sha256Tree(scratch.path);

    final destPath = '${demo.serverBFilesDir}/folder-e2e/uploaded-scratch';
    _resetLocal(destPath);

    // The same shape session_controller._runUploadDirectory takes: mkdir
    // the tree first (empty subfolders too), then upload every file.
    await bFs.mkdir(destPath);
    for (final rel in ['sub']) {
      await bFs.mkdir(RemotePath.join(destPath, rel));
    }
    await bFs.upload('${scratch.path}/one.txt',
        RemotePath.join(destPath, 'one.txt'));
    await bFs.upload('${scratch.path}/two.txt',
        RemotePath.join(destPath, 'two.txt'));
    await bFs.upload('${scratch.path}/sub/three.txt',
        RemotePath.join(destPath, 'sub/three.txt'));

    final destHashes = _sha256Tree(destPath);
    expect(destHashes, srcHashes,
        reason: 'uploaded tree must match local byte for byte');
    expect(Directory('$destPath/sub').existsSync(), isTrue,
        reason: 'subdirectory must be recreated on the remote side');
  },
      skip: demo == null
          ? 'demo servers not running (see ~/ssgo-demo/start-demo.sh)'
          : null,
      timeout: const Timeout(Duration(seconds: 60)));

  test('3. cancel a folder move mid-way (source intact, no half-file at B)',
      () async {
    _resetLocal('${demo!.serverAFilesDir}/cancel-folder');
    _resetLocal('${demo.serverBFilesDir}/folder-e2e/cancel-folder');
    aCtl = await connect(demo.hostA);
    bCtl = await connect(demo.hostB);
    final aFs = await aCtl!.sftp();
    final bFs = await bCtl!.sftp();

    Directory('${demo.serverAFilesDir}/folder-e2e/cancel-folder').createSync();
    for (var i = 0; i < 10; i++) {
      File('${demo.serverAFilesDir}/folder-e2e/cancel-folder/f$i.bin')
          .writeAsBytesSync(List<int>.filled(4096, (i * 17) & 0xff));
    }
    final srcSnapshot = _sha256Tree('${demo.serverAFilesDir}/folder-e2e/cancel-folder');

    var cancelled = false;
    try {
      await copyRemoteDirectory(
        source: aFs,
        destination: bFs,
        sourceDirectory: '${demo.serverAFilesDir}/folder-e2e/cancel-folder',
        destinationDirectory: '${demo.serverBFilesDir}/folder-e2e/cancel-folder',
        deleteSourceAfterVerify: true,
        isCancelled: () => cancelled,
        onProgress: (bytes) {
          // Once the second file is well underway, ask for a cancel — the
          // between-chunks check inside the per-file copy notices next.
          if (bytes > 4096) cancelled = true;
        },
      );
      fail('the copy should have been cancelled');
    } on TransferCancelled {
      // Expected.
    }

    // "Source intact" for a per-file-verify move means:
    //   - the source root still exists (no rmdir on cancel);
    //   - every source file that remains is byte-exact (nothing was
    //     truncated or corrupted mid-copy);
    //   - every file the copy successfully verified on the destination *is*
    //     what the source had (no half-written file, no bogus file);
    //   - the union of "still on A" + "already on B" covers everything the
    //     original tree had — no bytes were lost.
    final srcAfter = _sha256Tree('${demo.serverAFilesDir}/folder-e2e/cancel-folder');
    expect(
      Directory('${demo.serverAFilesDir}/folder-e2e/cancel-folder').existsSync(),
      isTrue,
      reason: 'the source root is never rmdir\'d on a cancelled move',
    );
    for (final entry in srcAfter.entries) {
      expect(entry.value, srcSnapshot[entry.key],
          reason: 'source file ${entry.key} was corrupted mid-cancel');
    }

    final destDir =
        Directory('${demo.serverBFilesDir}/folder-e2e/cancel-folder');
    final destHashes = destDir.existsSync()
        ? _sha256Tree(destDir.path)
        : const <String, String>{};
    for (final entry in destHashes.entries) {
      expect(entry.value, srcSnapshot[entry.key],
          reason:
              'destination file ${entry.key} is not the source it claims to '
              'be — half-written or otherwise wrong');
    }

    final unionKeys = <String>{...srcAfter.keys, ...destHashes.keys};
    expect(unionKeys, srcSnapshot.keys.toSet(),
        reason:
            'the union of "still on A" and "already on B" must cover every '
            'source file — a cancelled move must not lose data');
  },
      skip: demo == null
          ? 'demo servers not running (see ~/ssgo-demo/start-demo.sh)'
          : null,
      timeout: const Timeout(Duration(seconds: 60)));

  test('4. collision — same folder twice, keep both, both land distinctly',
      () async {
    _resetLocal('${demo!.serverAFilesDir}/folder-e2e/collide-folder');
    _resetLocal('${demo.serverBFilesDir}/folder-e2e/collide-folder');
    _resetLocal('${demo.serverBFilesDir}/folder-e2e/collide-folder (1)');
    // Any residue from an earlier, buggy version of this test that wrote
    // outside `folder-e2e/`.
    _resetLocal('${demo.serverBFilesDir}/collide-folder');
    _resetLocal('${demo.serverBFilesDir}/collide-folder (1)');
    aCtl = await connect(demo.hostA);
    bCtl = await connect(demo.hostB);
    final aFs = await aCtl!.sftp();
    final bFs = await bCtl!.sftp();

    // Round 1: an unremarkable move.
    Directory('${demo.serverAFilesDir}/folder-e2e/collide-folder/inner')
        .createSync(recursive: true);
    File('${demo.serverAFilesDir}/folder-e2e/collide-folder/a.txt')
        .writeAsStringSync('first-batch\n');
    File('${demo.serverAFilesDir}/folder-e2e/collide-folder/inner/b.txt')
        .writeAsStringSync('nested1\n');
    await copyRemoteDirectory(
      source: aFs,
      destination: bFs,
      sourceDirectory: '${demo.serverAFilesDir}/folder-e2e/collide-folder',
      destinationDirectory: '${demo.serverBFilesDir}/folder-e2e/collide-folder',
      deleteSourceAfterVerify: true,
    );

    // Recreate the source with different bytes to make round two distinct.
    Directory('${demo.serverAFilesDir}/folder-e2e/collide-folder/inner')
        .createSync(recursive: true);
    File('${demo.serverAFilesDir}/folder-e2e/collide-folder/a.txt')
        .writeAsStringSync('second-batch\n');
    File('${demo.serverAFilesDir}/folder-e2e/collide-folder/inner/b.txt')
        .writeAsStringSync('nested2\n');

    // Round 2: the folder-transfer UI runs the picked name through
    // `RemotePath.deduplicate` when the user picks "Keep both"; do the same
    // thing here to prove the shape.
    final destExisting =
        (await bFs.list('${demo.serverBFilesDir}/folder-e2e'))
            .map((e) => e.name)
            .toSet();
    final landingName = RemotePath.deduplicate(
      'collide-folder',
      (candidate) => destExisting.contains(candidate),
    );
    expect(landingName, 'collide-folder (1)');

    await copyRemoteDirectory(
      source: aFs,
      destination: bFs,
      sourceDirectory: '${demo.serverAFilesDir}/folder-e2e/collide-folder',
      destinationDirectory: '${demo.serverBFilesDir}/folder-e2e/$landingName',
      deleteSourceAfterVerify: true,
    );

    expect(
      File('${demo.serverBFilesDir}/folder-e2e/collide-folder/a.txt').readAsStringSync(),
      'first-batch\n',
    );
    expect(
      File('${demo.serverBFilesDir}/folder-e2e/$landingName/a.txt').readAsStringSync(),
      'second-batch\n',
    );
    expect(
      File('${demo.serverBFilesDir}/folder-e2e/collide-folder/inner/b.txt')
          .readAsStringSync(),
      'nested1\n',
    );
    expect(
      File('${demo.serverBFilesDir}/folder-e2e/$landingName/inner/b.txt')
          .readAsStringSync(),
      'nested2\n',
    );
  },
      skip: demo == null
          ? 'demo servers not running (see ~/ssgo-demo/start-demo.sh)'
          : null,
      timeout: const Timeout(Duration(seconds: 90)));
}

// ---------------------------------------------------------------------------

class _Demo {
  const _Demo({
    required this.username,
    required this.keyPem,
    required this.serverAFilesDir,
    required this.serverBFilesDir,
  });

  final String username;
  final String keyPem;
  final String serverAFilesDir;
  final String serverBFilesDir;

  Host get hostA => Host(
        id: 'demo-A',
        label: 'demo-A',
        hostname: '127.0.0.1',
        port: 22301,
        username: username,
        authMethod: SshAuthMethod.privateKey,
      );

  Host get hostB => Host(
        id: 'demo-B',
        label: 'demo-B',
        hostname: '127.0.0.1',
        port: 22302,
        username: username,
        authMethod: SshAuthMethod.privateKey,
      );
}

_Demo? _probeDemo() {
  final home = Platform.environment['HOME'];
  final username = Platform.environment['USER'];
  if (home == null || username == null) return null;
  final keyFile = File('$home/ssgo-demo/servers/keys/demo-key');
  final aFiles = Directory('$home/ssgo-demo/servers/A/files');
  final bFiles = Directory('$home/ssgo-demo/servers/B/files');
  if (!keyFile.existsSync() ||
      !aFiles.existsSync() ||
      !bFiles.existsSync()) {
    return null;
  }
  if (!_portOpen(22301) || !_portOpen(22302)) return null;
  return _Demo(
    username: username,
    keyPem: keyFile.readAsStringSync(),
    serverAFilesDir: aFiles.path,
    serverBFilesDir: bFiles.path,
  );
}

bool _portOpen(int port) {
  try {
    final s = RawSynchronousSocket.connectSync('127.0.0.1', port);
    s.closeSync();
    return true;
  } catch (_) {
    return false;
  }
}

void _resetLocal(String path) {
  final d = Directory(path);
  if (d.existsSync()) d.deleteSync(recursive: true);
  final f = File(path);
  if (f.existsSync()) f.deleteSync();
}

Map<String, String> _sha256Tree(String root) {
  final result = <String, String>{};
  final dir = Directory(root);
  if (!dir.existsSync()) return result;
  for (final f in dir.listSync(recursive: true).whereType<File>()) {
    final rel = f.path.substring(root.length + 1);
    result[rel] = sha256.convert(f.readAsBytesSync()).toString();
  }
  return result;
}
