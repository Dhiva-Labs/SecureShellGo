import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/remote_desktop/agent_failure.dart';
import 'package:secure_shell_go/services/remote_desktop/agent_manifest.dart';

import 'agent_test_support.dart';

const _sha = '17e23984cce59f4de79f130742dd268c375701745163fad6b0ceaebf2cfba0cb';

void main() {
  group('manifest', () {
    test('parses what tool/stage_agents.sh writes', () {
      final manifest = AgentManifest.parse('''
{
  "v": 1,
  "engine": "0.2.0",
  "agents": [
    {"file": "crossshell-host-linux-x86_64", "os": "linux", "arch": "x86_64", "flavour": "full", "sha256": "$_sha", "size": 4831768, "glibc": "2.30"},
    {"file": "crossshell-host-linux-aarch64-x11", "os": "linux", "arch": "aarch64", "flavour": "x11", "sha256": "$_sha", "size": 3468216},
    {"file": "crossshell-host-windows-x64.exe", "os": "windows", "arch": "x86_64", "flavour": "full", "sha256": "$_sha", "size": 1612288}
  ]
}''');
      expect(manifest.engineVersion, '0.2.0');
      expect(manifest.agents, hasLength(3));
      final full = manifest.find(AgentOs.linux, AgentArch.x86_64, AgentFlavour.full)!;
      expect(full.minGlibc, '2.30');
      expect(full.assetKey, 'assets/agents/crossshell-host-linux-x86_64.gz');
      expect(full.installedName, 'crossshell-host');
      final windows = manifest.find(AgentOs.windows, AgentArch.x86_64, AgentFlavour.full)!;
      expect(windows.installedName, 'crossshell-host.exe');
      // linux-aarch64 full is built on CI only; its absence is just absence.
      expect(manifest.find(AgentOs.linux, AgentArch.aarch64, AgentFlavour.full), isNull);
    });

    test('the committed manifest parses', () {
      final file = File('assets/agents/manifest.json');
      final manifest = AgentManifest.parse(file.readAsStringSync());
      for (final agent in manifest.agents) {
        expect(agent.sha256, matches(RegExp(r'^[0-9a-f]{64}$')));
      }
    });

    test('an entry for an OS this app does not know is skipped', () {
      final manifest = AgentManifest.parse('{"v":1,"engine":"0.3.0","agents":['
          '{"file":"crossshell-host-macos","os":"macos","arch":"aarch64","flavour":"full","sha256":"$_sha","size":1}]}');
      expect(manifest.agents, isEmpty);
    });

    test('a known entry that pins nothing is an error, not an empty bundle', () {
      for (final bad in [
        '"sha256":"nothex","size":1',
        '"sha256":"${_sha.toUpperCase()}","size":1',
        '"sha256":"$_sha","size":0',
        '"sha256":"$_sha","size":"1"',
      ]) {
        expect(
          () => AgentManifest.parse('{"v":1,"engine":"x","agents":[{"file":"a",'
              '"os":"linux","arch":"x86_64","flavour":"x11",$bad}]}'),
          throwsFormatException,
          reason: bad,
        );
      }
      expect(
        () => AgentManifest.parse('{"v":1,"engine":"x","agents":[{"file":"../a",'
            '"os":"linux","arch":"x86_64","flavour":"x11","sha256":"$_sha","size":1}]}'),
        throwsFormatException,
      );
      expect(() => AgentManifest.parse('{"v":2,"agents":[]}'), throwsFormatException);
      expect(() => AgentManifest.parse('[]'), throwsFormatException);
    });

    test('architectures in every spelling the probes meet', () {
      expect(AgentArch.parse('x86_64'), AgentArch.x86_64);
      expect(AgentArch.parse('AMD64'), AgentArch.x86_64);
      expect(AgentArch.parse('X64'), AgentArch.x86_64);
      expect(AgentArch.parse('aarch64'), AgentArch.aarch64);
      expect(AgentArch.parse('Arm64'), AgentArch.aarch64);
      expect(AgentArch.parse('armv7l'), isNull);
      expect(AgentArch.parse('i686'), isNull);
      expect(AgentArch.parse('X86'), isNull);
    });
  });

  group('bundle', () {
    test('a build without a manifest says remote desktop is unavailable', () async {
      final bundle = await AgentBundle.load(
        loadText: (_) async => throw StateError('no asset'),
        loadBytes: (_) async => throw StateError('no asset'),
      );
      expect(bundle.isAvailable, isFalse);
    });

    test('a listed binary the build left out is unavailableInBuild', () async {
      final bytes = bytesOf('agent');
      final binary = binaryFor(bytes);
      final bundle = AgentBundle(
        manifest: AgentManifest(engineVersion: '0.2.0', agents: [binary]),
        loadBytes: (_) async => throw StateError('Unable to load asset'),
      );
      expect(bundle.isAvailable, isTrue);
      await expectLater(
        bundle.bytesOf(binary),
        throwsA(isA<AgentFailure>()
            .having((f) => f.kind, 'kind', AgentFailureKind.unavailableInBuild)
            .having((f) => f.message, 'message', AgentBundle.unavailableMessage)),
      );
    });

    test('bytes that do not hash to the pin are refused', () async {
      final binary = binaryFor(bytesOf('the agent'));
      final bundle = AgentBundle(
        manifest: AgentManifest(engineVersion: '0.2.0', agents: [binary]),
        loadBytes: (_) async =>
            Uint8List.fromList(gzip.encode(bytesOf('something else'))),
      );
      await expectLater(
        bundle.bytesOf(binary),
        throwsA(isA<AgentFailure>()
            .having((f) => f.kind, 'kind', AgentFailureKind.hashMismatch)),
      );
    });

    test('an asset that does not unpack is refused like a wrong hash', () async {
      final binary = binaryFor(bytesOf('the agent'));
      final bundle = AgentBundle(
        manifest: AgentManifest(engineVersion: '0.2.0', agents: [binary]),
        loadBytes: (_) async => bytesOf('not gzip at all'),
      );
      await expectLater(
        bundle.bytesOf(binary),
        throwsA(isA<AgentFailure>()
            .having((f) => f.kind, 'kind', AgentFailureKind.hashMismatch)),
      );
    });

    test('the right bytes come back', () async {
      final bytes = bytesOf('the agent');
      final binary = binaryFor(bytes);
      final bundle = bundleOf({binary: bytes});
      expect(await bundle.bytesOf(binary), Uint8List.fromList(bytes));
    });
  });
}
