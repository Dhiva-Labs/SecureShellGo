import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:secure_shell_go/services/remote_desktop/agent_manifest.dart';
import 'package:secure_shell_go/services/sftp_service.dart';

import '../fake_exec_session.dart';
import '../support/fake_transport.dart';

/// A transport whose execs run through this machine's own `sh`, the way a
/// login shell on a server would run them.
///
/// Only ever handed scripts that touch a temporary directory — deploy and
/// stop scripts, and launch scripts pointed at a *fake* agent (a shell
/// script). The real agent never runs on this machine: it would find the
/// developer's live desktop session.
class LocalShellTransport extends FakeTransportBase {
  LocalShellTransport({this.environment});

  final Map<String, String>? environment;
  final List<String> commands = [];

  @override
  Future<SSHSession> execute(String command) async {
    commands.add(command);
    final result = await Process.run(
      'sh',
      ['-c', command],
      environment: environment,
      includeParentEnvironment: environment == null,
    );
    return FakeExecSession(
      stdout: result.stdout as String,
      stderrText: result.stderr as String,
      exitCode: result.exitCode,
    );
  }
}

/// The write half of a [RemoteFileSystem] over the local disk.
class LocalFiles implements RemoteFileSystem {
  final List<String> opened = [];

  @override
  Future<RemoteFileWriter> openWrite(String remotePath) async {
    opened.add(remotePath);
    return _LocalWriter(File(remotePath).openSync(mode: FileMode.write), remotePath);
  }

  @override
  Future<void> close() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _LocalWriter implements RemoteFileWriter {
  _LocalWriter(this._file, this._path);

  final RandomAccessFile _file;
  final String _path;

  @override
  Future<void> add(Uint8List chunk) async => _file.writeFromSync(chunk);

  @override
  Future<void> close() async => _file.closeSync();

  @override
  Future<void> abort() async {
    _file.closeSync();
    File(_path).deleteSync();
  }
}

/// A [RemoteFileSystem] whose writes always fail, for the upload error path.
class FailingFiles implements RemoteFileSystem {
  @override
  Future<RemoteFileWriter> openWrite(String remotePath) async =>
      throw const SftpFailure('Permission denied.');

  @override
  Future<void> close() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// A bundle built in memory: [binaries] maps a manifest entry to its bytes.
AgentBundle bundleOf(Map<AgentBinary, Uint8List> binaries,
    {String engine = '0.2.0'}) {
  final byKey = {for (final e in binaries.entries) e.key.assetKey: e.value};
  return AgentBundle(
    manifest: AgentManifest(engineVersion: engine, agents: binaries.keys.toList()),
    loadBytes: (key) async =>
        byKey[key] ?? (throw StateError('no asset $key')),
  );
}

/// A manifest entry for [bytes].
AgentBinary binaryFor(
  Uint8List bytes, {
  AgentOs os = AgentOs.linux,
  AgentArch arch = AgentArch.x86_64,
  AgentFlavour flavour = AgentFlavour.x11,
  String? file,
  String? minGlibc,
}) =>
    AgentBinary(
      file: file ??
          'crossshell-host-${os.name}-${arch.name}-${flavour.name}'
              '${os == AgentOs.windows ? '.exe' : ''}',
      os: os,
      arch: arch,
      flavour: flavour,
      sha256: sha256.convert(bytes).toString(),
      size: bytes.length,
      minGlibc: minGlibc,
    );

Uint8List bytesOf(String text) => Uint8List.fromList(utf8.encode(text));

/// A stand-in agent: a shell script that takes the real agent's flags,
/// writes a `host.json` into `--runtime-dir` the way the agent does, and
/// then sleeps until killed. No capture, no network, no desktop. It stays a
/// shell (no `exec`) so its command line keeps `--runtime-dir`, which is
/// what the stop scripts check before they kill a pid.
String fakeAgentScript({String token = 'ab', int port = 47999}) => '''#!/bin/sh
rt=
while [ \$# -gt 0 ]; do
  case "\$1" in
    --runtime-dir) rt=\$2; shift ;;
  esac
  shift
done
mkdir -p "\$rt"
echo "fake agent started" > "\$rt/host.log"
printf '{"v":1,"port":$port,"token":"%s","pid":%d,"ver":"0.2.0"}' "${token * 32}" \$\$ > "\$rt/host.json.tmp"
mv "\$rt/host.json.tmp" "\$rt/host.json"
while :; do sleep 1; done
''';
