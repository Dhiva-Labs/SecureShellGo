import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../models/host.dart';
import 'ssh_service.dart';

/// Which step of the `ssh-copy-id` contract failed, so the UI can say
/// something more specific than "could not install the key".
enum PublicKeyPushStep {
  /// Connecting to the server (only reachable from [PublicKeyPushService]'s
  /// fresh-credentials entry point; a caller-supplied transport is assumed
  /// already connected).
  connect,

  /// `mkdir -p ~/.ssh && chmod 700 ~/.ssh`.
  prepareDirectory,

  /// The `grep -qxF` / append step.
  appendKey,

  /// `chmod 600 ~/.ssh/authorized_keys`.
  securePermissions,

  /// The final `grep -qxF` that confirms the line actually landed.
  verify,
}

/// A push that failed at one specific, identifiable step.
class PublicKeyPushFailure implements Exception {
  const PublicKeyPushFailure(this.step, this.message, {this.details});

  final PublicKeyPushStep step;

  /// Short, human-readable explanation fit to show in a dialog.
  final String message;

  /// Command stderr, or the underlying error's `toString()`, for a "show
  /// details" affordance. Never the private key — this service never has it.
  final String? details;

  @override
  String toString() => message;
}

/// The exact shell commands the push runs, kept separate from execution so a
/// test can assert them character-for-character without a server.
///
/// This is the security-sensitive part: the public key line is user-visible
/// text (a comment can contain almost anything) and it must never be
/// interpolated straight into a shell string. Every command below carries it
/// only inside a single-quoted shell literal, built by [_singleQuote], never
/// as raw `'...$line...'` string interpolation into the command itself.
class PublicKeyPushCommands {
  const PublicKeyPushCommands._();

  /// `ssh-copy-id`'s own first step: create `~/.ssh` if it is missing and
  /// make sure it is not group/world-readable, whether it was just created or
  /// already there.
  static const String prepareDirectory = 'mkdir -p ~/.ssh && chmod 700 ~/.ssh';

  /// `authorized_keys` must not be group/world-readable either, or `sshd`
  /// refuses to trust it.
  static const String securePermissions = 'chmod 600 ~/.ssh/authorized_keys';

  /// Appends [publicKeyLine] only if it is not already an exact line in the
  /// file (`grep -qxF`, matching `ssh-copy-id`'s own idempotency check) —
  /// running this twice must not duplicate the entry. `2>/dev/null` covers
  /// the first-ever install, where the file does not exist yet and `grep`
  /// would otherwise report an error to stderr for a condition that is not
  /// one.
  static String appendIfMissing(String publicKeyLine) {
    final quoted = _singleQuote(publicKeyLine);
    return 'LINE=$quoted; '
        'grep -qxF "\$LINE" ~/.ssh/authorized_keys 2>/dev/null || '
        'printf \'%s\\n\' "\$LINE" >> ~/.ssh/authorized_keys';
  }

  /// Re-runs the same exact-line check with nothing suppressed, so a missing
  /// file or a missing line both come back as a plain non-zero exit — proof
  /// the line is really there rather than trusting the append step's own
  /// success.
  static String verify(String publicKeyLine) {
    final quoted = _singleQuote(publicKeyLine);
    return 'LINE=$quoted; grep -qxF "\$LINE" ~/.ssh/authorized_keys';
  }

  /// POSIX single-quoting: wrap [value] in single quotes, and turn any
  /// embedded single quote into `'\''` (close the quote, an escaped literal
  /// quote, reopen the quote). This is the only escaping a POSIX shell needs
  /// for an arbitrary byte string — unlike double quotes, nothing inside a
  /// single-quoted string is special except the quote character itself.
  static String _singleQuote(String value) =>
      "'${value.replaceAll("'", "'\\''")}'";
}

/// Installs a public key on a server's `authorized_keys`, following the same
/// contract `ssh-copy-id` does. Never sees the private key: every entry point
/// below takes the already-derived public line (see `ssh_keygen.dart`), and
/// [PublicKeyPushCommands] is the only place that line touches a command
/// string.
class PublicKeyPushService {
  const PublicKeyPushService();

  static const Duration _stepTimeout = Duration(seconds: 20);

  /// Runs the push over an already-authenticated [transport] — the case
  /// where the host edit screen has a live session open for this host and
  /// there is no reason to ask for a password again.
  Future<void> installOverTransport({
    required SessionTransport transport,
    required String publicKeyLine,
  }) async {
    await _run(
      transport,
      PublicKeyPushCommands.prepareDirectory,
      PublicKeyPushStep.prepareDirectory,
      'Could not create or secure ~/.ssh on the server.',
    );
    await _run(
      transport,
      PublicKeyPushCommands.appendIfMissing(publicKeyLine),
      PublicKeyPushStep.appendKey,
      'Could not add the key to ~/.ssh/authorized_keys.',
    );
    await _run(
      transport,
      PublicKeyPushCommands.securePermissions,
      PublicKeyPushStep.securePermissions,
      'Could not set permissions on authorized_keys.',
    );
    await _run(
      transport,
      PublicKeyPushCommands.verify(publicKeyLine),
      PublicKeyPushStep.verify,
      'The key was written but could not be verified afterwards.',
    );
  }

  /// Connects fresh with a password and runs the same steps, for a host with
  /// no live session — password auth regardless of what [host] is normally
  /// configured for, since the whole point is to get a key-based login
  /// working. The connection is always closed afterwards; nothing from it
  /// outlives this call.
  Future<void> installWithPassword({
    required SshService sshService,
    required Host host,
    required String password,
    required String publicKeyLine,
    required HostKeyVerifier verifyHostKey,
    Duration timeout = SshService.defaultTimeout,
  }) async {
    final passwordHost = host.authMethod == SshAuthMethod.password
        ? host
        : host.copyWith(authMethod: SshAuthMethod.password);

    final SshConnection connection;
    try {
      connection = await sshService.connect(
        host: passwordHost,
        credentials: SshCredentials(password: password),
        verifyHostKey: verifyHostKey,
        timeout: timeout,
      );
    } on SshConnectionException catch (e) {
      throw PublicKeyPushFailure(
        PublicKeyPushStep.connect,
        e.message,
        details: e.details,
      );
    }

    try {
      await installOverTransport(
        transport: connection,
        publicKeyLine: publicKeyLine,
      );
    } finally {
      connection.close();
    }
  }

  Future<void> _run(
    SessionTransport transport,
    String command,
    PublicKeyPushStep step,
    String failureMessage,
  ) async {
    try {
      final session = await transport.execute(command);
      // Nothing this service runs reads stdin; closing it up front means a
      // remote shell that happens to wait on EOF cannot hang the push.
      unawaited(session.stdin.close());

      final stderrBytes = BytesBuilder();
      final stderrDone = Completer<void>();
      session.stderr.listen(
        stderrBytes.add,
        onDone: stderrDone.complete,
        cancelOnError: false,
      );
      // stdout is drained rather than read: every command here reports
      // success or failure through its exit code alone.
      unawaited(session.stdout.drain<void>());

      final exitCode = await session.waitForExit(timeout: _stepTimeout);
      if (exitCode != 0) {
        throw PublicKeyPushFailure(
          step,
          failureMessage,
          details: utf8.decode(stderrBytes.toBytes(), allowMalformed: true).trim(),
        );
      }
    } on PublicKeyPushFailure {
      rethrow;
    } catch (e) {
      throw PublicKeyPushFailure(step, failureMessage, details: e.toString());
    }
  }
}
