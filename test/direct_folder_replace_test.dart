import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/services/device_storage.dart';
import 'package:secure_shell_go/services/direct_remote_copy.dart';
import 'package:secure_shell_go/services/remote_copy.dart';
import 'package:secure_shell_go/services/session_controller.dart';
import 'package:secure_shell_go/services/sftp_service.dart';
import 'package:secure_shell_go/services/ssh_keygen.dart';
import 'package:secure_shell_go/services/ssh_service.dart';
import 'package:secure_shell_go/services/transfer_queue.dart';

import 'fake_exec_session.dart';
import 'memory_fs.dart';

/// A direct folder copy's `Replace`, against two servers held in memory.
///
/// The source's `sftp put -r` is played by [_SftpPut], which reads the batch
/// this device sends and copies from one [MemoryFs] into the other wherever
/// that batch points — so what is asserted here is where the bytes really
/// went, not what the batch says.
void main() {
  late MemoryFs source;
  late MemoryFs destination;
  late SessionController controller;
  late List<_SftpPut> puts;
  late _PutPlan plan;

  final destKey = _verifiedKey('ssh-ed25519', 'b host key');
  final keyscan = 'b.example ssh-ed25519 ${_blob('b host key')}\n';
  const destHost = Host(
    id: 'dest',
    label: 'B',
    hostname: 'b.example',
    port: 22,
    username: 'root',
    authMethod: SshAuthMethod.privateKey,
  );
  final destCredentials = SshCredentials(
    privateKeyPem:
        SshKeygen.generateEd25519(comment: 'test@example').privateKeyPem,
  );

  /// The folder being replaced on B.
  const oldTree = {
    'file:index.html=4242',
    'dir:old',
    'file:old/stale.txt=7',
  };

  /// The folder coming from A, and what B should hold once it is replaced.
  const siteTree = {
    'file:index.html=100',
    'dir:css',
    'file:css/app.css=300',
  };

  setUp(() {
    source = MemoryFs();
    destination = MemoryFs();
    puts = [];
    plan = const _PutPlan();

    source
      ..directories.addAll(['/srv', '/srv/a', '/srv/a/site', '/srv/a/site/css'])
      ..files['/srv/a/site/index.html'] = 100
      ..files['/srv/a/site/css/app.css'] = 300;
    destination
      ..directories.addAll(['/srv', '/srv/b', '/srv/b/site', '/srv/b/site/old'])
      ..files['/srv/b/site/index.html'] = 4242
      ..files['/srv/b/site/old/stale.txt'] = 7;

    controller = SessionController(
      connection: FakeExecTransport(stdout: keyscan),
      storage: _NoStorage(),
      openFileSystem: () async => source,
      resolveDestinationCredentials: (_) async => destCredentials,
      connectWithAgentForwarding: (_, _) async => FakeExecTransport(
        agentForwarding: true,
        respond: (_) {
          final put = _SftpPut(source, destination, plan);
          puts.add(put);
          return put;
        },
      ),
    );
    addTearDown(controller.dispose);
  });

  Future<RemoteCopyOutcome> replace({
    bool move = false,
    CancelCheck? isCancelled,
  }) =>
      copyRemoteDirectoryDirect(
        source: controller,
        destHost: destHost,
        destCredentials: destCredentials,
        destinationFs: destination,
        sourceDirectory: '/srv/a/site',
        destinationDirectory: '/srv/b/site',
        destinationHostKey: destKey,
        overwrite: true,
        deleteSourceAfterVerify: move,
        isCancelled: isCancelled,
      );

  test('yields exactly the new contents, put into a hidden sibling first',
      () async {
    final outcome = await replace();

    expect(outcome.bytesCopied, 400);
    expect(outcome.destinationPath, '/srv/b/site');
    expect(destination.treeUnder('/srv/b/site'), siteTree);
    expect(destination.leftovers, isEmpty);
    // `put -r` never wrote to the real name: it filled a fresh hidden
    // sibling, which was renamed into place only after the counts matched.
    expect(
      puts.single.putTarget,
      matches(RegExp(r'^/srv/b/\.site\.ssg-part-\d+$')),
    );
    expect(
      destination.renamed,
      [
        matches(RegExp(r'^/srv/b/site -> /srv/b/\.site\.ssg-old-\d+$')),
        matches(RegExp(r'^/srv/b/\.site\.ssg-part-\d+ -> /srv/b/site$')),
      ],
    );
    // A copy, not a move.
    expect(source.treeUnder('/srv/a/site'), siteTree);
  });

  test('a dropped connection mid-put leaves the original folder and no '
      'staging folder', () async {
    plan = const _PutPlan(stopAfter: 1, exitCode: 255);

    await expectLater(
      replace(move: true),
      throwsA(isA<SSHDirectCopyUnavailable>()),
    );

    expect(destination.treeUnder('/srv/b/site'), oldTree);
    expect(destination.leftovers, isEmpty);
    expect(source.treeUnder('/srv/a/site'), siteTree);
  });

  test('a cancel mid-put leaves the original folder and no staging folder',
      () async {
    var cancelled = false;
    // `sftp` stops part way and waits; the cancel is what hangs it up.
    plan = _PutPlan(stopAfter: 1, onStop: () => cancelled = true);

    await expectLater(
      replace(move: true, isCancelled: () => cancelled),
      throwsA(isA<TransferCancelled>()),
    );

    expect(puts.single.wasClosed, isTrue);
    expect(destination.treeUnder('/srv/b/site'), oldTree);
    expect(destination.leftovers, isEmpty);
    expect(source.treeUnder('/srv/a/site'), siteTree);
  });

  test('a put that reports success but is short is not swapped in',
      () async {
    plan = const _PutPlan(stopAfter: 1, exitCode: 0);

    await expectLater(
      replace(move: true),
      throwsA(isA<RemoteCopyFailure>()),
    );

    expect(destination.treeUnder('/srv/b/site'), oldTree);
    expect(destination.leftovers, isEmpty);
    expect(source.treeUnder('/srv/a/site'), siteTree);
  });

  test('if the new copy cannot take the name, the old folder is put back '
      'and a move deletes nothing', () async {
    destination.refuseRename =
        (from, to) => from.contains('.site.ssg-part-') && to == '/srv/b/site';

    await expectLater(
      replace(move: true),
      throwsA(isA<RemoteCopyFailure>()),
    );

    expect(destination.treeUnder('/srv/b/site'), oldTree);
    expect(destination.leftovers, isEmpty);
    expect(source.treeUnder('/srv/a/site'), siteTree);
    expect(source.removed, isEmpty);
  });

  test('a move deletes the source once the new folder is in place',
      () async {
    final outcome = await replace(move: true);

    expect(outcome.sourceDeleted, isTrue);
    expect(destination.treeUnder('/srv/b/site'), siteTree);
    expect(source.directories, {'/srv', '/srv/a'});
    expect(source.files, isEmpty);
  });
}

/// How the next `put -r` goes.
class _PutPlan {
  const _PutPlan({this.stopAfter, this.exitCode, this.onStop});

  /// How many files `sftp` writes before it stops; null writes them all and
  /// exits 0.
  final int? stopAfter;

  /// What `sftp` exits with when it stops early. Null leaves it waiting
  /// until the channel is closed, which only a cancel does.
  final int? exitCode;

  /// Called when it stops early.
  final void Function()? onStop;
}

/// The source's `sftp -b -`, as far as the destination can tell.
///
/// Reads the batch from stdin and plays its `lcd` and `put -r` as OpenSSH
/// does: the remote folder is created at exactly the path named — or, if a
/// folder is already there, the source is put inside it — and filled file by
/// file from the source [MemoryFs].
class _SftpPut extends FakeExecSession {
  _SftpPut(this._source, this._destination, this._plan) : super(exits: true);

  final MemoryFs _source;
  final MemoryFs _destination;
  final _PutPlan _plan;
  final _exit = Completer<void>();

  /// The folder `put -r` created and filled.
  String? putTarget;

  late final _BatchSink _stdin = _BatchSink(_run);

  @override
  StreamSink<Uint8List> get stdin => _stdin;

  @override
  Future<void> get done => _exit.future;

  @override
  int? get exitCode => _exitCode;
  int? _exitCode;

  @override
  void close() {
    super.close();
    if (!_exit.isCompleted) _exit.complete();
  }

  void _finish(int code) {
    _exitCode = code;
    if (!_exit.isCompleted) _exit.complete();
  }

  Future<void> _run(String batch) async {
    String? localDirectory;
    for (final line in const LineSplitter().convert(batch)) {
      final lcd = RegExp(r'^lcd "([^"]*)"$').firstMatch(line);
      if (lcd != null) localDirectory = lcd.group(1);
      final put = RegExp(r'^put -r "([^"]*)" "([^"]*)"$').firstMatch(line);
      if (put != null) {
        return _put('$localDirectory/${put.group(1)}', put.group(2)!);
      }
    }
    _finish(1);
  }

  Future<void> _put(String local, String remote) async {
    final target = _destination.directories.contains(remote)
        ? '$remote/${local.substring(local.lastIndexOf('/') + 1)}'
        : remote;
    putTarget = target;
    await _destination.mkdir(target);

    String landing(String path) => '$target${path.substring(local.length)}';
    final directories = _source.directories
        .where((d) => d.startsWith('$local/'))
        .toList()
      ..sort();
    for (final directory in directories) {
      await _destination.mkdir(landing(directory));
    }

    final files = _source.files.keys
        .where((f) => f.startsWith('$local/'))
        .toList()
      ..sort();
    for (var index = 0; index < files.length; index++) {
      if (index == _plan.stopAfter) {
        _plan.onStop?.call();
        final code = _plan.exitCode;
        if (code != null) _finish(code);
        return;
      }
      await Future<void>.delayed(Duration.zero);
      _destination.files[landing(files[index])] = _source.files[files[index]]!;
    }
    _finish(0);
  }
}

/// Collects what is written to `sftp`'s stdin and hands it over on close.
class _BatchSink implements StreamSink<Uint8List> {
  _BatchSink(this._onClose);

  final Future<void> Function(String batch) _onClose;
  final _bytes = BytesBuilder();

  @override
  void add(Uint8List data) => _bytes.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<Uint8List> stream) => stream.forEach(add);

  @override
  Future<void> close() => _onClose(utf8.decode(_bytes.takeBytes()));

  @override
  Future<void> get done => Future.value();
}

/// A stand-in host key blob, base64 as `ssh-keyscan` prints it.
String _blob(String seed) => base64.encode(utf8.encode(seed));

/// What this device would have recorded after verifying [_blob] of [seed].
VerifiedHostKey _verifiedKey(String type, String seed) {
  final digest = sha256.convert(utf8.encode(seed)).bytes;
  return VerifiedHostKey(
    keyType: type,
    fingerprint: 'SHA256:${base64.encode(digest).replaceAll('=', '')}',
  );
}

/// `SessionController` reaches for platform storage in its constructor; none
/// of these tests download anything.
class _NoStorage implements DeviceStorage {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
