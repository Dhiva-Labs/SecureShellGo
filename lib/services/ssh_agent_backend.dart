import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../models/host.dart';

/// Why an agent handler could not be built from a saved credential.
enum SSHAgentUnavailableReason {
  /// The saved host uses password auth, so there is no key to forward, or the
  /// credential holds no key at all.
  missingKey,

  /// The saved key is encrypted and no cached passphrase is available; the
  /// caller has to prompt (or fall back).
  passphraseNeeded,

  /// The PEM cannot be parsed, or dartssh2 does not support that format.
  unusableKey,
}

/// Raised when [CredentialSSHAgent.forHost] cannot build a working handler
/// from the credential it was given.
///
/// Distinct from the transfer's own failure types on purpose: the caller can
/// choose to prompt for the missing passphrase, fall back to the relay path,
/// or refuse — without those decisions being tangled up with "the write on B
/// went wrong".
class SSHAgentUnavailable implements Exception {
  const SSHAgentUnavailable(this.reason, {this.message});

  final SSHAgentUnavailableReason reason;
  final String? message;

  @override
  String toString() =>
      message ?? 'The destination credential cannot be forwarded.';
}

/// An SSH agent-forwarding backend that holds exactly one identity: the
/// private key for a single destination [Host].
///
/// **Design constraint.** In a direct server-to-server copy A→B, the
/// destination's private key must never touch A. Agent forwarding is
/// OpenSSH's answer to that: `scp` or `sftp` on A asks the local agent for
/// a signature, the request is forwarded back through the source SSH
/// channel to *this* agent (which lives in the app's process on the user's
/// device), and the signature returns the same way. The key stays here.
///
/// **Why one key rather than the whole [CredentialStore].** Handing a
/// source server every credential we know would let a compromised — or
/// merely curious — remote `ssh-add -L` enumerate every host on the
/// device. So this is per-transfer and per-host: the caller loads exactly
/// the one credential a specific transfer needs and hands it here.
///
/// **What it does.** All the actual signing lives in dartssh2's
/// [SSHKeyPairAgent]. That already knows how to sign for ed25519, RSA
/// (with rsa-sha2-256/512 selection) and ECDSA; wrapping it costs a
/// scoping guarantee and nothing else.
class CredentialSSHAgent implements SSHAgentHandler {
  CredentialSSHAgent._({required this.host, required SSHKeyPairAgent delegate})
      // ignore: prefer_initializing_formals
      : _delegate = delegate;

  final Host host;
  final SSHKeyPairAgent _delegate;

  /// Builds a handler for [host] from [credentials]. Throws
  /// [SSHAgentUnavailable] when there is no usable key — the caller has to
  /// prompt, or fall back to the relay path — never returning something that
  /// silently refuses every sign request.
  static CredentialSSHAgent forHost({
    required Host host,
    required SshCredentials credentials,
  }) {
    if (host.authMethod != SshAuthMethod.privateKey) {
      throw const SSHAgentUnavailable(
        SSHAgentUnavailableReason.missingKey,
        message: 'Only key-authenticated destinations can be forwarded — a '
            'password on the destination is not something an agent can sign.',
      );
    }

    final pem = credentials.privateKeyPem?.trim();
    if (pem == null || pem.isEmpty) {
      throw const SSHAgentUnavailable(
        SSHAgentUnavailableReason.missingKey,
        message: 'No private key saved for the destination host.',
      );
    }

    final passphrase = (credentials.passphrase?.isEmpty ?? true)
        ? null
        : credentials.passphrase;

    bool encrypted;
    try {
      encrypted = SSHKeyPair.isEncryptedPem(pem);
    } on UnsupportedError catch (e) {
      throw SSHAgentUnavailable(
        SSHAgentUnavailableReason.unusableKey,
        message: 'The destination private key is in a format that cannot be '
            'forwarded (${e.message}).',
      );
    } catch (e) {
      throw SSHAgentUnavailable(
        SSHAgentUnavailableReason.unusableKey,
        message: 'The destination private key could not be read: $e',
      );
    }

    if (encrypted && passphrase == null) {
      throw const SSHAgentUnavailable(
        SSHAgentUnavailableReason.passphraseNeeded,
        message: 'The destination key is passphrase-protected and no cached '
            'passphrase is available.',
      );
    }

    final List<SSHKeyPair> pairs;
    try {
      pairs = SSHKeyPair.fromPem(pem, passphrase);
    } catch (e) {
      throw SSHAgentUnavailable(
        SSHAgentUnavailableReason.unusableKey,
        message: encrypted
            ? 'The destination key could not be decrypted with the cached '
                'passphrase.'
            : 'The destination key could not be decoded.',
      );
    }

    if (pairs.isEmpty) {
      throw const SSHAgentUnavailable(
        SSHAgentUnavailableReason.missingKey,
        message: 'No usable key was found in the destination credential.',
      );
    }

    return CredentialSSHAgent._(
      host: host,
      // The comment travels in the agent's identity list; naming the target
      // host makes an `ssh-add -L` executed by A show *why* this identity was
      // offered, and stops it looking like an unrelated leak from the user's
      // real agent.
      delegate: SSHKeyPairAgent(pairs, comment: 'ssgo:${host.displayName}'),
    );
  }

  @override
  Future<Uint8List> handleRequest(Uint8List request) =>
      _delegate.handleRequest(request);
}

/// A swappable [SSHAgentHandler] that starts empty.
///
/// [SSHClient.agentHandler] is `final` — it is set once at construction and
/// cannot change afterwards. To let a session that was opened *without*
/// agent forwarding grow one for the duration of a single direct transfer,
/// we install *this* handler at construction time and swap the underlying
/// delegate in and out per-transfer through [install].
///
/// Empty state (no delegate) replies to every request with a well-formed
/// `SSH_AGENT_FAILURE`. That is what OpenSSH clients read as "no identities
/// available", which is exactly what it is — and it beats tearing the
/// channel down, which would leak that "no agent is installed right now" as
/// distinguishable from "the agent has no key for this signature".
class MutableSSHAgentHandler implements SSHAgentHandler {
  SSHAgentHandler? _current;

  /// True while a delegate is installed. Diagnostics only.
  bool get isInstalled => _current != null;

  /// Plugs [handler] in and returns a release function.
  ///
  /// The release only clears the slot if it still holds exactly [handler],
  /// so a second [install] that lands before an earlier release runs is
  /// never silently unhooked by the earlier one's cleanup — the transfer
  /// currently holding the slot always wins.
  void Function() install(SSHAgentHandler handler) {
    _current = handler;
    return () {
      if (identical(_current, handler)) _current = null;
    };
  }

  @override
  Future<Uint8List> handleRequest(Uint8List request) async {
    final current = _current;
    if (current == null) {
      // SSH agent protocol: one byte payload, [SSH_AGENT_FAILURE]. The
      // enclosing SSHAgentChannel prepends the 4-byte length prefix.
      return Uint8List.fromList(const [SSHAgentProtocol.failure]);
    }
    return current.handleRequest(request);
  }
}
