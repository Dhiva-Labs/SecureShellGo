import 'package:dartssh2/dartssh2.dart';

import '../models/host.dart';
import 'ssh_service.dart';

/// Thrown by [HeadlessDialer.dial] when the host cannot be signed in to
/// without a person: it asked a question nobody saved an answer to, or its
/// host key has not been checked yet. Callers report the host as skipped
/// (a fleet run) or tell the user to connect once in the app (the AI
/// Bridge), rather than as broken.
class SignInNeedsPerson implements Exception {
  const SignInNeedsPerson(this.reason);

  final String reason;

  @override
  String toString() => reason;
}

/// Signs in to a saved host with what is saved and nobody to ask.
///
/// Lifted out of the fleet run and fleet push screens, which each had a copy,
/// once the AI Bridge needed the same rule: no dialog, no question, and never
/// a host key trusted without a person comparing it. What would have needed
/// a person comes back as [SignInNeedsPerson]; a *changed* host key is a
/// plain [SshConnectionException], because it is an alarm and not a chore.
class HeadlessDialer {
  const HeadlessDialer(this.sshService);

  final SshService sshService;

  /// Dials [host] with [credentials]. Throws [SignInNeedsPerson] when the
  /// sign-in stopped at something only a person can answer, and
  /// [SshConnectionException] for everything else.
  Future<SshConnection> dial(Host host, SshCredentials credentials) async {
    HostKeyPrompt? key;
    LoginPrompt? asked;
    try {
      return await sshService.connect(
        host: host,
        credentials: credentials,
        // An unknown or changed host key fails the dial instead of waiting
        // on a dialog nobody is watching. A new key is only ever trusted
        // through an ordinary, one-at-a-time connect from the host list.
        verifyHostKey: (prompt) async {
          key ??= prompt;
          return false;
        },
        // Given, rather than left null, only so the question can be named
        // in the message; it is never answered.
        answerPrompts: (prompt) async {
          asked ??= prompt;
          return null;
        },
      );
    } on SshConnectionException {
      final keyPrompt = key;
      if (keyPrompt != null) {
        if (keyPrompt.kind == HostKeyPromptKind.changed) {
          throw SshConnectionException(
            'The host key of ${keyPrompt.hostLabel} has CHANGED since it was '
            'trusted. Not connecting — check it from the host list.',
          );
        }
        throw SignInNeedsPerson(
          'The host key of ${keyPrompt.hostLabel} has not been checked yet. '
          'Connect once from the host list to check and trust it.',
        );
      }
      final prompt = asked;
      if (prompt != null) {
        final who = prompt.jumpHostFor == null
            ? 'It'
            : 'Its jump host "${prompt.host.displayName}"';
        if (prompt.savedPasswordRejected) {
          throw SignInNeedsPerson(
            '$who turned the saved password down and asks for another.',
          );
        }
        final label = prompt.fields.isEmpty ? '' : prompt.fields.first.label;
        throw SignInNeedsPerson(
          label.isEmpty
              ? '$who asks a question at login, which needs you.'
              : '$who asks "$label" at login, which needs you.',
        );
      }
      rethrow;
    }
  }

  /// Why [host] cannot be signed in to without a person, from what is
  /// saved for it — or null when it can be tried.
  ///
  /// Only what can be told before dialling: a one-time code or an
  /// untrusted host key turns up during the sign-in, and [dial] reports
  /// those as [SignInNeedsPerson].
  static String? signInProblem(Host host, SshCredentials? saved) {
    switch (host.authMethod) {
      case SshAuthMethod.agent:
        return null;
      case SshAuthMethod.password:
        if (saved?.password?.isNotEmpty ?? false) return null;
        return 'No saved password. Connect once from the host list and '
            'save it to include this host.';
      case SshAuthMethod.privateKey:
        final pem = saved?.privateKeyPem?.trim() ?? '';
        if (pem.isEmpty) {
          return 'No saved private key. Edit the host to add one.';
        }
        final passphrase = saved?.passphrase ?? '';
        if (passphrase.isEmpty) {
          try {
            if (SSHKeyPair.isEncryptedPem(pem)) {
              return 'The key\'s passphrase is not saved, and nobody is asked '
                  'for it here.';
            }
          } catch (_) {
            // Unreadable: the dial says so properly.
          }
        }
        return null;
    }
  }
}
