import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart'
    show
        SSHAgentHandler,
        SSHHostKey,
        SSHIdentity,
        SSHKeyPair,
        SSHKeyPairAgent,
        SSHRawHostKey,
        SSHRawSignature,
        SSHSignature;

import 'windows_agent_pipe.dart';

/// Why the operating system's ssh-agent could not be used.
///
/// Separated by kind because the fixes are unrelated: no agent running is
/// something the user starts, an empty agent is something they `ssh-add` to,
/// and a refusal is the agent declining to sign with the key we named.
enum SshAgentErrorKind {
  /// `SSH_AUTH_SOCK` is unset, or the socket/pipe it names is not there.
  noAgent,

  /// This platform has no OS agent to talk to at all — Android.
  unsupported,

  /// The agent answered, but holds no keys.
  noIdentities,

  /// The agent replied `SSH_AGENT_FAILURE` to a request.
  refused,

  /// The agent sent something that is not a well-formed reply.
  protocol,
}

/// Raised by [SshAgentClient]. [message] is safe to show to a human.
class SshAgentException implements Exception {
  const SshAgentException(this.kind, this.message, {this.details});

  final SshAgentErrorKind kind;
  final String message;

  /// Technical detail for a "show details" affordance. Never contains key
  /// material — see the note on [SshAgentClient].
  final String? details;

  @override
  String toString() => message;
}

/// One identity the agent is holding, as returned by `REQUEST_IDENTITIES`.
///
/// [keyBlob] is the public half only, in SSH wire format (`string algorithm`
/// followed by the algorithm's own fields). It is the handle used to ask for
/// a signature; the private half never leaves the agent.
class SshAgentIdentity {
  const SshAgentIdentity({required this.keyBlob, required this.comment});

  final Uint8List keyBlob;

  /// The agent's own label for the key, e.g. `user@laptop`. Display only.
  final String comment;

  /// The algorithm name from the front of [keyBlob], e.g. `ssh-ed25519`, or
  /// an empty string if the blob is too short to carry one.
  String get keyType {
    final reader = SshAgentReader(keyBlob);
    try {
      return String.fromCharCodes(reader.readString());
    } catch (_) {
      return '';
    }
  }
}

/// Minimal big-endian reader for SSH wire encoding.
///
/// Hand-rolled rather than reaching into dartssh2's `SSHMessageReader`, which
/// is not part of that package's public surface — this file is the only thing
/// in the app that parses agent replies, and it is a few dozen lines.
class SshAgentReader {
  SshAgentReader(this._bytes);

  final Uint8List _bytes;
  int _offset = 0;

  int get remaining => _bytes.length - _offset;

  int readUint8() {
    if (remaining < 1) throw const FormatException('Truncated agent message.');
    return _bytes[_offset++];
  }

  int readUint32() {
    if (remaining < 4) throw const FormatException('Truncated agent message.');
    final value = ByteData.sublistView(_bytes, _offset, _offset + 4)
        .getUint32(0);
    _offset += 4;
    return value;
  }

  /// A length-prefixed byte string.
  Uint8List readString() {
    final length = readUint32();
    if (remaining < length) {
      throw const FormatException('Truncated agent string.');
    }
    final value = Uint8List.sublistView(_bytes, _offset, _offset + length);
    _offset += length;
    return value;
  }
}

/// Minimal big-endian writer for SSH wire encoding.
class SshAgentWriter {
  final BytesBuilder _builder = BytesBuilder(copy: false);

  void writeUint8(int value) => _builder.addByte(value);

  void writeUint32(int value) {
    final data = ByteData(4)..setUint32(0, value);
    _builder.add(data.buffer.asUint8List());
  }

  void writeString(List<int> value) {
    writeUint32(value.length);
    _builder.add(value);
  }

  void writeUtf8(String value) => writeString(value.codeUnits);

  Uint8List takeBytes() => _builder.takeBytes();
}

/// Encoding and decoding for the ssh-agent client protocol.
///
/// Message numbers follow draft-miller-ssh-agent. Only the two requests this
/// app needs are implemented — enumerate keys, and ask for one signature —
/// which is also the smallest surface that can do public-key auth: there is
/// deliberately no add-identity, no remove, and no lock.
///
/// Every method here is a pure byte transform, so the framing is pinned by
/// golden-byte tests rather than by talking to a real agent.
abstract class SshAgentProtocol {
  static const int failure = 5;
  static const int success = 6;
  static const int requestIdentities = 11;
  static const int identitiesAnswer = 12;
  static const int signRequest = 13;
  static const int signResponse = 14;

  /// Signature flags. An RSA key in an agent signs with SHA-1 unless asked
  /// otherwise, and modern OpenSSH servers reject `ssh-rsa` (SHA-1); these
  /// are how `rsa-sha2-256`/`rsa-sha2-512` get requested instead.
  static const int flagRsaSha2_256 = 2;
  static const int flagRsaSha2_512 = 4;

  /// Refuse to buffer a reply larger than this. An agent reply is a handful
  /// of public keys or one signature; anything at this scale is a desync or
  /// a hostile socket, and it must not become an allocation.
  static const int maxFrameLength = 256 * 1024;

  /// Wraps a payload in the 4-byte big-endian length prefix every agent
  /// message travels under.
  static Uint8List frame(Uint8List payload) {
    final writer = SshAgentWriter()..writeString(payload);
    return writer.takeBytes();
  }

  /// `SSH_AGENTC_REQUEST_IDENTITIES` — a bare message number, no fields.
  static Uint8List encodeRequestIdentities() {
    final writer = SshAgentWriter()..writeUint8(requestIdentities);
    return writer.takeBytes();
  }

  /// Reads `SSH_AGENT_IDENTITIES_ANSWER` from an unframed payload.
  static List<SshAgentIdentity> decodeIdentitiesAnswer(Uint8List payload) {
    final reader = SshAgentReader(payload);
    final type = reader.readUint8();
    if (type == failure) {
      throw const SshAgentException(
        SshAgentErrorKind.refused,
        'The SSH agent refused to list its keys.',
      );
    }
    if (type != identitiesAnswer) {
      throw SshAgentException(
        SshAgentErrorKind.protocol,
        'The SSH agent sent an unexpected reply.',
        details: 'Expected message $identitiesAnswer, got $type.',
      );
    }

    final count = reader.readUint32();
    // A corrupt count must not drive a huge loop before the reads fail.
    if (count > 1024) {
      throw const SshAgentException(
        SshAgentErrorKind.protocol,
        'The SSH agent reported an implausible number of keys.',
      );
    }

    final identities = <SshAgentIdentity>[];
    for (var i = 0; i < count; i++) {
      final keyBlob = Uint8List.fromList(reader.readString());
      final comment = String.fromCharCodes(reader.readString());
      identities.add(SshAgentIdentity(keyBlob: keyBlob, comment: comment));
    }
    return identities;
  }

  /// `SSH_AGENTC_SIGN_REQUEST` for [keyBlob] over [data].
  static Uint8List encodeSignRequest({
    required Uint8List keyBlob,
    required Uint8List data,
    int flags = 0,
  }) {
    final writer = SshAgentWriter()
      ..writeUint8(signRequest)
      ..writeString(keyBlob)
      ..writeString(data)
      ..writeUint32(flags);
    return writer.takeBytes();
  }

  /// Reads `SSH_AGENT_SIGN_RESPONSE`, returning the signature blob — itself
  /// SSH-encoded as `string algorithm, string signature`.
  static Uint8List decodeSignResponse(Uint8List payload) {
    final reader = SshAgentReader(payload);
    final type = reader.readUint8();
    if (type == failure) {
      throw const SshAgentException(
        SshAgentErrorKind.refused,
        'The SSH agent refused to sign with that key. It may have been '
        'removed, a confirmation prompt was declined, or a security key was '
        'not touched in time.',
      );
    }
    if (type != signResponse) {
      throw SshAgentException(
        SshAgentErrorKind.protocol,
        'The SSH agent sent an unexpected reply to a signature request.',
        details: 'Expected message $signResponse, got $type.',
      );
    }
    return Uint8List.fromList(reader.readString());
  }

  /// The signature flags to ask for given a public key algorithm name.
  ///
  /// Only RSA needs them, certificate or not; ed25519 and ECDSA — security
  /// key variants included — have exactly one signature algorithm each, and
  /// sending flags for those is meaningless.
  static int flagsForKeyType(String keyType) => isRsaKeyType(keyType)
      ? flagRsaSha2_256
      : 0;

  static bool isRsaKeyType(String keyType) =>
      keyType == 'ssh-rsa' || keyType == 'ssh-rsa-cert-v01@openssh.com';

  /// `SSH_AGENT_IDENTITIES_ANSWER`, the reply an agent sends — needed here
  /// because this app also *is* an agent, for the server it forwards one to.
  static Uint8List encodeIdentitiesAnswer(List<SshAgentIdentity> identities) {
    final writer = SshAgentWriter()
      ..writeUint8(identitiesAnswer)
      ..writeUint32(identities.length);
    for (final identity in identities) {
      writer
        ..writeString(identity.keyBlob)
        ..writeUtf8(identity.comment);
    }
    return writer.takeBytes();
  }

  /// `SSH_AGENT_SIGN_RESPONSE` around a signature blob.
  static Uint8List encodeSignResponse(Uint8List signature) {
    final writer = SshAgentWriter()
      ..writeUint8(signResponse)
      ..writeString(signature);
    return writer.takeBytes();
  }

  /// `SSH_AGENT_FAILURE`, the answer to anything this app's agent declines.
  static Uint8List encodeFailure() => Uint8List.fromList(const [failure]);
}

/// The `publickey` algorithm name to log in with a key of [keyType] — the
/// type at the front of its blob.
///
/// The same as the key type for everything but RSA, which is offered as
/// `rsa-sha2-256` (RFC 8332) and signed for with
/// [SshAgentProtocol.flagRsaSha2_256], because OpenSSH has refused SHA-1
/// `ssh-rsa` signatures by default since 8.8. Certificates follow suit.
/// Security keys (`sk-ssh-ed25519@openssh.com`,
/// `sk-ecdsa-sha2-nistp256@openssh.com`) and their certificates pass
/// through as they are: the agent and the token do the signing, and the
/// server checks the result.
String agentPublicKeyAlgorithm(String keyType) => switch (keyType) {
      'ssh-rsa' => 'rsa-sha2-256',
      'ssh-rsa-cert-v01@openssh.com' => 'rsa-sha2-256-cert-v01@openssh.com',
      _ => keyType,
    };

/// One key in the operating system's agent, as something dartssh2 can log
/// in with.
///
/// dartssh2 4.1 signs through [SSHIdentity], which may answer with a future;
/// this is the adapter that turns its "sign this challenge" into an agent
/// round trip. The key never leaves the agent — what this holds is the
/// public blob the agent named it by — and that is also how a FIDO2
/// `sk-ed25519` or `sk-ecdsa` key on a hardware token works: the agent asks
/// the token, the token waits for a touch, and the signature comes back the
/// same way any other does.
///
/// [presentedBlob] is what the server is shown, which is the key itself
/// unless a certificate for it was configured: then it is the certificate,
/// and the agent still signs with the plain key, because a certificate
/// signature is an ordinary signature by the certified key.
class SshAgentKeyIdentity implements SSHIdentity {
  SshAgentKeyIdentity(
    this._agent,
    this.key, {
    Uint8List? presentedBlob,
    String? presentedType,
  })  : presentedBlob = presentedBlob ?? key.keyBlob,
        presentedType = presentedType ?? key.keyType;

  final SshAgentClient _agent;

  /// The agent's key that signs.
  final SshAgentIdentity key;

  /// What the server sees: the key's blob, or a certificate's.
  final Uint8List presentedBlob;

  /// The type at the front of [presentedBlob].
  final String presentedType;

  @override
  String get type => agentPublicKeyAlgorithm(presentedType);

  @override
  String? get comment => key.comment.isEmpty ? null : key.comment;

  /// Always ask first. Each probe costs a round trip, but a signature can
  /// cost a confirmation dialog or a touch of a security key, and nobody
  /// should be asked to touch their YubiKey for a key the server was going
  /// to refuse anyway.
  @override
  bool get shouldProbe => true;

  @override
  SSHHostKey toPublicKey() => SSHRawHostKey(presentedBlob);

  @override
  Future<SSHSignature> sign(Uint8List data) async {
    final signature = await _agent.sign(
      keyBlob: key.keyBlob,
      data: data,
      flags: SshAgentProtocol.flagsForKeyType(key.keyType),
    );
    if (SshAgentProtocol.isRsaKeyType(key.keyType)) {
      // An agent too old to know the flag signs with SHA-1 regardless, and
      // the server would refuse that with nothing but "permission denied".
      final algorithm = _signatureAlgorithm(signature);
      if (algorithm != 'rsa-sha2-256') {
        throw SshAgentException(
          SshAgentErrorKind.refused,
          'The SSH agent signed with SHA-1 (ssh-rsa), which servers refuse. '
          'Update the agent, or use an ed25519 key.',
          details: 'Asked for rsa-sha2-256, got "$algorithm".',
        );
      }
    }
    return SSHRawSignature(signature);
  }

  static String _signatureAlgorithm(Uint8List signature) {
    try {
      return String.fromCharCodes(SshAgentReader(signature).readString());
    } on FormatException {
      return '';
    }
  }
}

/// The agent a session forwards to its server, so `git` or `ssh` run in
/// the shell can sign with keys that stay on this device.
///
/// It offers the keys in this device's own SSH agent ([osAgent], desktop
/// only) and the keys the host itself signs in with ([keys], when they are
/// saved in this app — the only keys an Android device has). Nothing else:
/// no other saved host's key is ever reachable through it.
///
/// It answers two requests, listing keys and signing, and refuses the rest
/// with `SSH_AGENT_FAILURE`. A real agent also takes requests to add and
/// remove keys, lock itself, and extensions; passing those through would
/// let anyone with root on the server empty, lock or fill the agent on this
/// device, and nothing a shell needs uses them. OpenSSH's `session-bind`
/// extension is among the refused, which its client treats as an agent that
/// does not support it.
class ForwardedAgent implements SSHAgentHandler {
  ForwardedAgent({this.osAgent, List<SSHKeyPair> keys = const [], String? comment})
      : _keys = keys,
        _comment = comment ?? '',
        _local = keys.isEmpty ? null : SSHKeyPairAgent(keys, comment: comment);

  final SshAgentClient? osAgent;
  final List<SSHKeyPair> _keys;
  final String _comment;
  final SSHKeyPairAgent? _local;

  @override
  Future<Uint8List> handleRequest(Uint8List request) async {
    if (request.isEmpty) return SshAgentProtocol.encodeFailure();
    try {
      switch (request[0]) {
        case SshAgentProtocol.requestIdentities:
          return SshAgentProtocol.encodeIdentitiesAnswer(await _identities());
        case SshAgentProtocol.signRequest:
          return await _sign(request);
        default:
          return SshAgentProtocol.encodeFailure();
      }
    } on FormatException {
      return SshAgentProtocol.encodeFailure();
    } on SshAgentException {
      return SshAgentProtocol.encodeFailure();
    }
  }

  Future<List<SshAgentIdentity>> _identities() async {
    final seen = <String>{};
    final identities = <SshAgentIdentity>[];
    void add(SshAgentIdentity identity) {
      if (seen.add(String.fromCharCodes(identity.keyBlob))) {
        identities.add(identity);
      }
    }

    final os = osAgent;
    if (os != null) {
      try {
        (await os.listIdentities()).forEach(add);
      } on SshAgentException {
        // No agent running, or none holding keys: the forwarded agent is
        // then just this host's own key, or empty, and `ssh-add -l` on the
        // server says so.
      }
    }
    for (final key in _keys) {
      add(SshAgentIdentity(
        keyBlob: key.toPublicKey().encode(),
        comment: _comment,
      ));
    }
    return identities;
  }

  Future<Uint8List> _sign(Uint8List request) async {
    final reader = SshAgentReader(request)..readUint8();
    final keyBlob = reader.readString();
    final data = reader.readString();
    final flags = reader.readUint32();

    final local = _local;
    if (local != null && _holdsLocally(keyBlob)) {
      return local.handleRequest(request);
    }
    final os = osAgent;
    if (os == null) return SshAgentProtocol.encodeFailure();
    final signature = await os.sign(keyBlob: keyBlob, data: data, flags: flags);
    return SshAgentProtocol.encodeSignResponse(signature);
  }

  bool _holdsLocally(Uint8List keyBlob) {
    for (final key in _keys) {
      if (_sameBytes(key.toPublicKey().encode(), keyBlob)) return true;
    }
    return false;
  }

  static bool _sameBytes(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// One open connection to an agent, request/response oriented.
///
/// An interface rather than a concrete socket so the protocol and the seam
/// above it can be tested against a fake agent — no `SSH_AUTH_SOCK`, no
/// `ssh-add`, and no dependence on what the developer's own agent happens to
/// be holding.
abstract class SshAgentConnection {
  /// Sends one request payload (unframed) and returns the reply payload
  /// (also unframed). Implementations add and strip the length prefix.
  Future<Uint8List> request(Uint8List payload);

  Future<void> close();
}

/// Opens a connection to the platform's agent.
typedef SshAgentConnector = Future<SshAgentConnection> Function();

/// Talks to the operating system's ssh-agent.
///
/// **The private key never leaves the agent.** This client sends two kinds of
/// request — "what keys do you have" and "sign these bytes with that key" —
/// and receives public key blobs and signatures. There is no code path here
/// that asks for, receives, or stores private key material, and nothing this
/// class handles is ever written to the credential store or to a log. The
/// `details` on a thrown [SshAgentException] carry message numbers and
/// lengths only, never blob contents.
class SshAgentClient {
  SshAgentClient({SshAgentConnector? connector, this.timeout = _defaultTimeout})
      : _connector = connector ?? defaultConnector;

  final SshAgentConnector _connector;

  /// How long to wait for one agent reply.
  ///
  /// Generous on purpose: a key held in a hardware token makes the agent
  /// block until the user physically touches it, and timing that out would
  /// break exactly the setup with the best security properties.
  final Duration timeout;

  static const Duration _defaultTimeout = Duration(seconds: 60);

  /// The keys the agent is holding.
  ///
  /// Throws [SshAgentException] with [SshAgentErrorKind.noAgent] when there
  /// is no agent to talk to, or [SshAgentErrorKind.noIdentities] when it is
  /// running but empty — the two cases have completely different fixes.
  Future<List<SshAgentIdentity>> listIdentities() async {
    final connection = await _connector();
    try {
      final reply = await connection
          .request(SshAgentProtocol.encodeRequestIdentities())
          .timeout(timeout);
      final identities = SshAgentProtocol.decodeIdentitiesAnswer(reply);
      if (identities.isEmpty) {
        throw const SshAgentException(
          SshAgentErrorKind.noIdentities,
          'The SSH agent is running but holds no keys. Add one with '
          '`ssh-add` and try again.',
        );
      }
      return identities;
    } on TimeoutException catch (e) {
      throw SshAgentException(
        SshAgentErrorKind.protocol,
        'The SSH agent did not respond.',
        details: e.toString(),
      );
    } on FormatException catch (e) {
      // A short read off the wire, not a caller mistake — surfaced as the
      // protocol failure it is rather than escaping as a parse error.
      throw SshAgentException(
        SshAgentErrorKind.protocol,
        'The SSH agent sent a truncated reply.',
        details: e.toString(),
      );
    } finally {
      await connection.close();
    }
  }

  /// Asks the agent to sign [data] with the key identified by [keyBlob].
  ///
  /// Returns the signature blob (`string algorithm, string signature`).
  Future<Uint8List> sign({
    required Uint8List keyBlob,
    required Uint8List data,
    int flags = 0,
  }) async {
    final connection = await _connector();
    try {
      final reply = await connection
          .request(SshAgentProtocol.encodeSignRequest(
            keyBlob: keyBlob,
            data: data,
            flags: flags,
          ))
          .timeout(timeout);
      return SshAgentProtocol.decodeSignResponse(reply);
    } on TimeoutException catch (e) {
      throw SshAgentException(
        SshAgentErrorKind.protocol,
        'The SSH agent did not respond to a signature request.',
        details: e.toString(),
      );
    } on FormatException catch (e) {
      throw SshAgentException(
        SshAgentErrorKind.protocol,
        'The SSH agent sent a truncated signature reply.',
        details: e.toString(),
      );
    } finally {
      await connection.close();
    }
  }

  /// True where an OS agent can exist at all. Android has none, so the auth
  /// method is hidden there rather than offered and then failed.
  static bool get isSupportedPlatform =>
      Platform.isLinux || Platform.isMacOS || Platform.isWindows;

  /// Opens the platform's agent: the `SSH_AUTH_SOCK` unix socket on
  /// Linux/macOS, the OpenSSH named pipe on Windows.
  static Future<SshAgentConnection> defaultConnector() async {
    if (Platform.isAndroid || Platform.isIOS) {
      throw const SshAgentException(
        SshAgentErrorKind.unsupported,
        'No SSH agent found. This device has no SSH agent — use a password '
        'or a private key for this host instead.',
      );
    }

    if (Platform.isWindows) {
      return openWindowsAgent(
        environment: Platform.environment,
        openPipe: _openPipe,
        findPageant: PageantPipe.find,
      );
    }
    return _openUnixSocket();
  }

  static Future<SshAgentConnection> _openUnixSocket() async {
    final path = Platform.environment['SSH_AUTH_SOCK'];
    if (path == null || path.isEmpty) {
      throw const SshAgentException(
        SshAgentErrorKind.noAgent,
        'No SSH agent found. SSH_AUTH_SOCK is not set — start an agent with '
        '`ssh-agent` and add a key with `ssh-add`.',
      );
    }

    try {
      final socket = await Socket.connect(
        InternetAddress(path, type: InternetAddressType.unix),
        0,
        timeout: const Duration(seconds: 5),
      );
      return StreamAgentConnection(socket, socket);
    } on SocketException catch (e) {
      throw SshAgentException(
        SshAgentErrorKind.noAgent,
        'No SSH agent found at $path. The agent may have stopped since this '
        'session started.',
        details: e.toString(),
      );
    }
  }

  /// The Windows OpenSSH agent's pipe.
  static const String openSshAgentPipe = r'\\.\pipe\openssh-ssh-agent';

  /// Whether [path] names a pipe (`\\.\pipe\…`) rather than a file.
  static bool isWindowsPipePath(String path) {
    const prefix = r'\\.\pipe\';
    return path.length > prefix.length &&
        path.substring(0, prefix.length).toLowerCase() == prefix &&
        !path.substring(prefix.length).contains(r'\');
  }

  /// Windows: an agent listens on a named pipe rather than a socket.
  ///
  /// Tried in order: `SSH_AUTH_SOCK` when it names a pipe (any agent the
  /// user points it at), the Windows OpenSSH agent's own pipe, then Pageant
  /// ([findPageant], which only answers with a pipe this user owns — see
  /// `PageantPipe`). An `SSH_AUTH_SOCK` that is not a `\\.\pipe\` path —
  /// a Git Bash or Cygwin socket file, say — is not something this can talk
  /// to, and is passed over rather than opened: opening it as a file would
  /// create it, or append agent requests to whatever it is, and stop the
  /// search there.
  ///
  /// Public, with the opening passed in, so a test can check the order and
  /// what is skipped without Windows.
  static Future<SshAgentConnection> openWindowsAgent({
    required Map<String, String> environment,
    required Future<SshAgentConnection> Function(String path) openPipe,
    required Future<SshAgentConnection?> Function() findPageant,
  }) async {
    final configured = environment['SSH_AUTH_SOCK'];
    final notAPipe = configured != null &&
        configured.isNotEmpty &&
        !isWindowsPipePath(configured);
    final candidates = <String>[
      if (configured != null && isWindowsPipePath(configured)) configured,
      openSshAgentPipe,
    ];
    Object? lastError;
    for (final path in candidates) {
      try {
        return await openPipe(path);
      } catch (e) {
        lastError = e;
      }
    }
    final pageant = await findPageant();
    if (pageant != null) return pageant;
    throw SshAgentException(
      SshAgentErrorKind.noAgent,
      'No SSH agent found. Start the OpenSSH Authentication Agent service '
      'or Pageant, and add a key.',
      details: [
        if (notAPipe)
          'SSH_AUTH_SOCK ($configured) is not a named pipe, so it was not '
              'used.',
        if (lastError != null) '$lastError',
      ].join(' '),
    );
  }

  /// Opens a named pipe for the agent protocol.
  ///
  /// `dart:io` has no named-pipe client, but a pipe has a filesystem-style
  /// path and `File.open` goes through `CreateFile`, which is the documented
  /// way to open one. The pipe is byte-mode, so ordinary reads and writes are
  /// the correct framing. Only ever called with a `\\.\pipe\` path: a
  /// pipe cannot be created by opening it, so a missing one fails here
  /// rather than leaving a file behind.
  ///
  /// Caveat, stated plainly: this path could not be exercised on the machine
  /// this was written on. Every failure mode routes to the same clear
  /// [SshAgentErrorKind.noAgent] message as a missing agent, and the reads
  /// are bounded by [timeout], so the worst case is "agent auth is not
  /// available on Windows" rather than a hang or a crash.
  static Future<SshAgentConnection> _openPipe(String path) async {
    final handle = await File(path).open(mode: FileMode.append);
    return _RandomAccessAgentConnection(handle);
  }
}

/// Agent connection over a duplex byte stream (the unix socket case).
///
/// Owns the reassembly: a reply can arrive split across reads, so bytes are
/// buffered until a whole length-prefixed frame is present.
///
/// Public rather than private so a test can point it at a socket pair it
/// controls and feed a reply in pieces — reassembly is the one part of this
/// file that a well-behaved local agent will almost never exercise, which is
/// exactly why it needs a test that does.
class StreamAgentConnection implements SshAgentConnection {
  StreamAgentConnection(this._sink, Stream<Uint8List> incoming) {
    _subscription = incoming.listen(
      _onData,
      onError: _onError,
      onDone: _onDone,
    );
  }

  final IOSink _sink;
  late final StreamSubscription<Uint8List> _subscription;

  final BytesBuilder _buffer = BytesBuilder(copy: false);
  Completer<Uint8List>? _pending;
  bool _closed = false;

  void _onData(Uint8List chunk) {
    _buffer.add(chunk);
    _deliver();
  }

  void _deliver() {
    final pending = _pending;
    if (pending == null || pending.isCompleted) return;

    final bytes = _buffer.toBytes();
    if (bytes.length < 4) return;

    final length = ByteData.sublistView(bytes, 0, 4).getUint32(0);
    if (length == 0 || length > SshAgentProtocol.maxFrameLength) {
      _pending = null;
      pending.completeError(
        SshAgentException(
          SshAgentErrorKind.protocol,
          'The SSH agent sent a malformed reply.',
          details: 'Frame length $length.',
        ),
      );
      return;
    }
    if (bytes.length < 4 + length) return;

    final payload = Uint8List.sublistView(bytes, 4, 4 + length);
    // Keep anything past this frame; a well-behaved agent sends exactly one
    // reply per request, but trailing bytes must not be silently dropped.
    _buffer
      ..clear()
      ..add(Uint8List.sublistView(bytes, 4 + length));
    _pending = null;
    pending.complete(Uint8List.fromList(payload));
  }

  void _onError(Object error) {
    final pending = _pending;
    _pending = null;
    pending?.completeError(
      SshAgentException(
        SshAgentErrorKind.protocol,
        'The connection to the SSH agent failed.',
        details: error.toString(),
      ),
    );
  }

  void _onDone() {
    final pending = _pending;
    _pending = null;
    pending?.completeError(
      const SshAgentException(
        SshAgentErrorKind.protocol,
        'The SSH agent closed the connection before replying.',
      ),
    );
  }

  @override
  Future<Uint8List> request(Uint8List payload) async {
    if (_closed) {
      throw const SshAgentException(
        SshAgentErrorKind.protocol,
        'The connection to the SSH agent is closed.',
      );
    }
    final completer = Completer<Uint8List>();
    _pending = completer;
    _sink.add(SshAgentProtocol.frame(payload));
    await _sink.flush();
    // A reply may already be buffered if it raced the flush.
    _deliver();
    return completer.future;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _subscription.cancel();
    try {
      await _sink.close();
    } catch (_) {
      // Already gone.
    }
  }
}

/// Agent connection over a [RandomAccessFile] (the Windows named-pipe case).
class _RandomAccessAgentConnection implements SshAgentConnection {
  _RandomAccessAgentConnection(this._handle);

  final RandomAccessFile _handle;
  bool _closed = false;

  @override
  Future<Uint8List> request(Uint8List payload) async {
    if (_closed) {
      throw const SshAgentException(
        SshAgentErrorKind.protocol,
        'The connection to the SSH agent is closed.',
      );
    }
    await _handle.writeFrom(SshAgentProtocol.frame(payload));
    await _handle.flush();

    final header = await _readExactly(4);
    final length = ByteData.sublistView(header, 0, 4).getUint32(0);
    if (length == 0 || length > SshAgentProtocol.maxFrameLength) {
      throw SshAgentException(
        SshAgentErrorKind.protocol,
        'The SSH agent sent a malformed reply.',
        details: 'Frame length $length.',
      );
    }
    return _readExactly(length);
  }

  Future<Uint8List> _readExactly(int count) async {
    final out = BytesBuilder(copy: false);
    var left = count;
    while (left > 0) {
      final chunk = await _handle.read(left);
      if (chunk.isEmpty) {
        throw const SshAgentException(
          SshAgentErrorKind.protocol,
          'The SSH agent closed the pipe before replying.',
        );
      }
      out.add(chunk);
      left -= chunk.length;
    }
    return out.takeBytes();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _handle.close();
    } catch (_) {
      // Already gone.
    }
  }
}
