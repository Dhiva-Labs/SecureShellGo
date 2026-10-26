import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'agent_failure.dart';

/// The operating systems the agent is built for.
enum AgentOs { linux, windows }

/// The CPU architectures the agent is built for, named the Linux way.
/// Windows' `x64`/`arm64` map onto these, so one name means one CPU
/// everywhere in this code.
enum AgentArch {
  x86_64,
  aarch64;

  /// From `uname -m`, Windows' `PROCESSOR_ARCHITECTURE`, or .NET's
  /// `OSArchitecture` — every spelling the probes meet. Null for anything the
  /// agent is not built for (32-bit x86 and ARM above all), which is an
  /// unsupported server rather than a guess.
  static AgentArch? parse(String text) {
    switch (text.trim().toLowerCase()) {
      case 'x86_64':
      case 'amd64':
      case 'x64':
        return AgentArch.x86_64;
      case 'aarch64':
      case 'arm64':
      case 'armv8l':
        return AgentArch.aarch64;
    }
    return null;
  }

  String get label => switch (this) {
        AgentArch.x86_64 => 'x86-64',
        AgentArch.aarch64 => 'ARM64',
      };
}

/// Which build of the agent.
///
/// Linux has two because of PipeWire: the [full] build links
/// `libpipewire-0.3` at load time (Mutter and portal capture need it), so it
/// will not even start on a minimal server, while the [x11] build is a
/// static musl binary with only the X11 backend that runs on anything —
/// which is what a virtual desktop wants. Windows has only [full].
enum AgentFlavour { full, x11 }

/// One agent binary listed in `assets/agents/manifest.json`.
class AgentBinary {
  const AgentBinary({
    required this.file,
    required this.os,
    required this.arch,
    required this.flavour,
    required this.sha256,
    required this.size,
    this.minGlibc,
  });

  /// The asset's file name, under [AgentBundle.assetDirectory].
  final String file;
  final AgentOs os;
  final AgentArch arch;
  final AgentFlavour flavour;

  /// Lowercase hex. Pinned in the committed manifest, checked against the
  /// bundled bytes before upload and against the server's copy before every
  /// launch.
  final String sha256;
  final int size;

  /// For a dynamically linked Linux build: the newest glibc symbol version it
  /// needs, as `2.30`. Null for static builds and Windows.
  final String? minGlibc;

  /// Where the build keeps it: gzipped, which takes the bundled agents from
  /// about 15 MB to about 6 on every install, desktop and phone alike, for
  /// people who never open a remote desktop. [sha256] and [size] are still
  /// those of the binary itself, so what is checked is what runs.
  String get assetKey => '${AgentBundle.assetDirectory}$file.gz';

  /// The name the binary is installed under on the server. The flavour is
  /// in the content-addressed directory already, so the name stays plain.
  String get installedName =>
      os == AgentOs.windows ? 'crossshell-host.exe' : 'crossshell-host';
}

/// `assets/agents/manifest.json`, which `tool/stage_agents.sh` writes.
///
/// It is committed while the binaries are not, so the hashes that every
/// launch is checked against are part of the reviewed source rather than
/// whatever happened to be in the build tree.
class AgentManifest {
  const AgentManifest({required this.engineVersion, required this.agents});

  static const AgentManifest empty =
      AgentManifest(engineVersion: null, agents: []);

  /// The CrossShell engine release the binaries come from, or null when the
  /// manifest lists none.
  final String? engineVersion;
  final List<AgentBinary> agents;

  /// Parses the manifest. Entries this version of the app does not
  /// understand — an OS or architecture added later — are skipped rather
  /// than failing the whole file; anything malformed about a known entry,
  /// above all a hash that is not 64 hex digits, is a [FormatException],
  /// because a manifest that pins nothing must not be mistaken for one
  /// that does.
  static AgentManifest parse(String text) {
    final Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException catch (e) {
      throw FormatException('agent manifest is not JSON: ${e.message}');
    }
    if (json is! Map<String, Object?>) {
      throw const FormatException('agent manifest is not a JSON object');
    }
    if (json['v'] != 1) {
      throw FormatException('agent manifest version ${json['v']} is not 1');
    }
    final engine = json['engine'];
    if (engine != null && engine is! String) {
      throw const FormatException('agent manifest "engine" is not a string');
    }
    final list = json['agents'];
    if (list is! List<Object?>) {
      throw const FormatException('agent manifest has no "agents" list');
    }
    final agents = <AgentBinary>[];
    for (final entry in list) {
      if (entry is! Map<String, Object?>) {
        throw const FormatException('agent manifest entry is not an object');
      }
      final os = _enumByName(AgentOs.values, entry['os']);
      final arch = _enumByName(AgentArch.values, entry['arch']);
      final flavour = _enumByName(AgentFlavour.values, entry['flavour']);
      if (os == null || arch == null || flavour == null) continue;
      final file = entry['file'];
      final sha = entry['sha256'];
      final size = entry['size'];
      final glibc = entry['glibc'];
      if (file is! String || !_fileName.hasMatch(file)) {
        throw FormatException('agent manifest file name ${entry['file']}');
      }
      if (sha is! String || !_sha256.hasMatch(sha)) {
        throw FormatException('agent manifest sha256 for $file');
      }
      if (size is! int || size <= 0) {
        throw FormatException('agent manifest size for $file');
      }
      if (glibc != null && (glibc is! String || !_glibc.hasMatch(glibc))) {
        throw FormatException('agent manifest glibc for $file');
      }
      agents.add(AgentBinary(
        file: file,
        os: os,
        arch: arch,
        flavour: flavour,
        sha256: sha,
        size: size,
        minGlibc: glibc as String?,
      ));
    }
    return AgentManifest(engineVersion: engine as String?, agents: agents);
  }

  /// The binary for exactly this combination, or null. No fallback between
  /// flavours here: which flavour can stand in for which depends on what the
  /// server's desktop is, and that is the deployer's call.
  AgentBinary? find(AgentOs os, AgentArch arch, AgentFlavour flavour) {
    for (final agent in agents) {
      if (agent.os == os && agent.arch == arch && agent.flavour == flavour) {
        return agent;
      }
    }
    return null;
  }

  static final RegExp _sha256 = RegExp(r'^[0-9a-f]{64}$');
  static final RegExp _fileName = RegExp(r'^[A-Za-z0-9._-]+$');
  static final RegExp _glibc = RegExp(r'^\d+\.\d+$');

  static T? _enumByName<T extends Enum>(List<T> values, Object? name) {
    for (final value in values) {
      if (value.name == name) return value;
    }
    return null;
  }
}

/// Reads one bundled asset's bytes. Production passes
/// `(key) async => (await rootBundle.load(key)).buffer.asUint8List()`;
/// injected so that nothing under `services/` imports Flutter.
typedef AgentAssetLoader = Future<Uint8List> Function(String assetKey);

/// Reads one bundled asset as text — `rootBundle.loadString` in production.
typedef AgentAssetTextLoader = Future<String> Function(String assetKey);

/// The agents this build carries: the manifest plus a way to read the bytes.
class AgentBundle {
  AgentBundle({required this.manifest, required AgentAssetLoader loadBytes})
      : _loadBytes = loadBytes; // ignore: prefer_initializing_formals

  static const String assetDirectory = 'assets/agents/';
  static const String manifestKey = '${assetDirectory}manifest.json';

  /// The wording for a build without agents, kept in one place because it is
  /// what a user of a source build without `tool/stage_agents.sh` sees.
  static const String unavailableMessage =
      'Remote desktop is not available in this build of SecureShell Go: it '
      'was built without the remote-desktop agent.';

  final AgentManifest manifest;
  final AgentAssetLoader _loadBytes;

  /// Loads the manifest. A missing or unreadable manifest is an empty bundle
  /// rather than an error, so the app starts and remote desktop says it is
  /// unavailable — the shape of a build made without the agents.
  static Future<AgentBundle> load({
    required AgentAssetTextLoader loadText,
    required AgentAssetLoader loadBytes,
  }) async {
    AgentManifest manifest;
    try {
      manifest = AgentManifest.parse(await loadText(manifestKey));
    } catch (_) {
      manifest = AgentManifest.empty;
    }
    return AgentBundle(manifest: manifest, loadBytes: loadBytes);
  }

  /// False when the manifest lists no agents at all. Binaries the manifest
  /// lists but the build left out are only found when [bytesOf] reads them.
  bool get isAvailable => manifest.agents.isNotEmpty;

  /// The binary's bytes, checked against the manifest.
  ///
  /// A listed binary that is not in the build — the manifest is committed
  /// and the binaries are not, so a plain `flutter build` has exactly this
  /// shape — is [AgentFailureKind.unavailableInBuild]. Bytes that do not
  /// hash to the pinned value are refused outright: whatever they are, they
  /// are not what this source tree reviewed.
  Future<Uint8List> bytesOf(AgentBinary binary) async {
    final Uint8List packed;
    try {
      packed = await _loadBytes(binary.assetKey);
    } catch (e) {
      throw AgentFailure(
        AgentFailureKind.unavailableInBuild,
        unavailableMessage,
        details: '${binary.file} is listed in the manifest but is not in '
            'this build ($e)',
      );
    }
    // Unpacked only here, on the way to a server, so nothing is held in
    // memory until a remote desktop is actually opened. A file that does
    // not unpack is as wrong as one that does not hash.
    Uint8List bytes;
    try {
      bytes = Uint8List.fromList(gzip.decode(packed));
    } on FormatException {
      bytes = Uint8List(0);
    }
    final digest = sha256.convert(bytes).toString();
    if (bytes.length != binary.size || digest != binary.sha256) {
      throw AgentFailure(
        AgentFailureKind.hashMismatch,
        'The remote-desktop agent bundled in this build does not match the '
        'one it was built to carry, so it will not be used.',
        details: '${binary.file}: expected ${binary.sha256} '
            '(${binary.size} bytes), found $digest (${bytes.length} bytes)',
      );
    }
    return bytes;
  }
}
