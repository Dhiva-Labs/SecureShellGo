import 'dart:convert';

import '../models/known_host.dart';
import 'known_hosts_service.dart';

/// Why the user is being asked about a host key.
enum HostKeyPromptKind {
  /// We have never trusted a key of this type for this host (trust on first
  /// use). Accepting writes the key to the known-hosts store.
  unknown,

  /// We hold a trusted key of this type for this host and the server presented
  /// a *different* one. This is the machine-in-the-middle case and must be
  /// surfaced loudly.
  changed,
}

/// Everything the UI needs to render a host key decision.
class HostKeyPrompt {
  const HostKeyPrompt({
    required this.kind,
    required this.hostname,
    required this.port,
    required this.keyType,
    required this.fingerprint,
    this.previous,
    this.hostHasOtherKeys = false,
  });

  final HostKeyPromptKind kind;
  final String hostname;
  final int port;

  /// Host key algorithm the server negotiated, e.g. `ssh-ed25519`.
  final String keyType;

  /// OpenSSH-style `SHA256:...` fingerprint of the presented key.
  final String fingerprint;

  /// The previously trusted key. Present only when [kind] is
  /// [HostKeyPromptKind.changed].
  final KnownHostKey? previous;

  /// True when the host is already known under a *different* key algorithm.
  /// Not an alarm — servers legitimately hold several host keys — but worth
  /// telling the user so this first-use prompt is not mistaken for one.
  final bool hostHasOtherKeys;

  String get hostLabel => port == 22 ? hostname : '$hostname:$port';
}

/// Asks the user to accept or reject a host key. Returns true to proceed.
typedef HostKeyVerifier = Future<bool> Function(HostKeyPrompt prompt);

/// The host key decision, made the way OpenSSH makes it.
///
/// Kept separate from [SshService] so the security-critical branch — trust on
/// first use vs. silent match vs. blocked key change — can be tested without a
/// live SSH server, and so a later "known hosts" management screen can reuse
/// it.
class HostKeyPolicy {
  const HostKeyPolicy(this.knownHosts);

  final KnownHostsService knownHosts;

  /// Decides whether to proceed with a connection to
  /// [hostname]:[port] that offered a [keyType] key with [fingerprint].
  ///
  /// Returns true to continue the handshake. Prompts through [verify] only
  /// when the key is unknown or has changed; a key that matches what we
  /// already trust is accepted without bothering the user. Accepting through
  /// the prompt persists the key before returning.
  Future<bool> evaluate({
    required String hostname,
    required int port,
    required String keyType,
    required String fingerprint,
    required HostKeyVerifier verify,
  }) async {
    final known = await knownHosts.lookup(hostname, port, keyType);

    if (known != null && known.fingerprint == fingerprint) {
      return true;
    }

    final HostKeyPrompt prompt;
    if (known == null) {
      prompt = HostKeyPrompt(
        kind: HostKeyPromptKind.unknown,
        hostname: hostname,
        port: port,
        keyType: keyType,
        fingerprint: fingerprint,
        hostHasOtherKeys: await knownHosts.isHostKnown(hostname, port),
      );
    } else {
      prompt = HostKeyPrompt(
        kind: HostKeyPromptKind.changed,
        hostname: hostname,
        port: port,
        keyType: keyType,
        fingerprint: fingerprint,
        previous: known,
      );
    }

    final accepted = await verify(prompt);
    if (!accepted) return false;

    await knownHosts.trust(
      KnownHostKey(
        hostname: hostname.trim().toLowerCase(),
        port: port,
        keyType: keyType,
        fingerprint: fingerprint,
        addedAt: DateTime.now(),
      ),
    );
    return true;
  }

  /// Decodes the fingerprint dartssh2 hands to `onVerifyHostKey`.
  ///
  /// It arrives already formatted as `SHA256:<base64>` and UTF-8 encoded —
  /// byte for byte what `ssh-keygen -l` and `ssh-keyscan` print, which is what
  /// makes out-of-band comparison by the user meaningful.
  static String decodeFingerprint(List<int> bytes) =>
      utf8.decode(bytes, allowMalformed: true);
}
