import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'ssh_service.dart';

/// What a one-shot remote command produced.
///
/// [exitCode] is nullable because a server is not obliged to send an exit
/// status before closing the channel, and several of the probes below are
/// deliberately indifferent to it — see [RemoteExec.run].
class ExecResult {
  const ExecResult({
    required this.stdout,
    required this.stderr,
    required this.exitCode,
  });

  final String stdout;
  final String stderr;
  final int? exitCode;

  bool get succeeded => exitCode == 0;

  /// Whether this looks like the command was refused for lack of privilege,
  /// rather than having failed on its merits.
  ///
  /// Matched on stderr text because that is all there is: a `systemctl stop`
  /// refused by polkit and one that failed because the unit does not exist
  /// both exit non-zero, and the exit code alone cannot tell the user which
  /// of those happened. Deliberately a *hint* — it drives the wording of a
  /// message ("this needs sudo; run it from the terminal") and nothing else.
  /// Nothing in this app escalates privilege, so a false positive costs a
  /// slightly-off sentence and a false negative costs a generic one.
  bool get looksLikePermissionDenied {
    final text = stderr.toLowerCase();
    return text.contains('permission denied') ||
        text.contains('operation not permitted') ||
        text.contains('access denied') ||
        text.contains('must be root') ||
        text.contains('authentication is required') ||
        text.contains('interactive authentication required') ||
        text.contains('are you root');
  }
}

/// Runs single, short-lived commands over a session's existing transport.
///
/// Every monitoring feature in this phase reads the server by opening an exec
/// channel, running something small and POSIX-portable, and reading what came
/// back — so the "open a channel, drain both pipes, wait with a timeout,
/// decode leniently" dance lives here once instead of four times.
///
/// Not for long-running commands. `tail -F` never exits, and waiting for its
/// exit code is exactly the wrong shape; that has its own streaming path in
/// `log_tail.dart`.
class RemoteExec {
  const RemoteExec._();

  /// How long a probe is given before its channel is abandoned.
  ///
  /// Shorter than the stats poll interval so a server that has gone
  /// unresponsive cannot pile one probe on top of the next; a probe that
  /// takes longer than this has failed as far as a 5 s refresh is concerned,
  /// whatever it eventually would have said.
  static const Duration defaultTimeout = Duration(seconds: 10);

  /// Runs [command] and collects everything it produced.
  ///
  /// **A non-zero exit is not an error here.** It is returned in
  /// [ExecResult.exitCode] for the caller to interpret, because the callers
  /// disagree about what it means: the stats probe runs a chain of fallbacks
  /// whose last link failing is routine and whose output is still perfectly
  /// good, while a `systemctl restart` that exits non-zero is a real failure
  /// the user has to be told about. Only a channel that could not be opened
  /// at all, or one that timed out, throws.
  ///
  /// Decoding is `allowMalformed` throughout: this is arbitrary output from
  /// an arbitrary server, and a stray non-UTF-8 byte in a process name must
  /// degrade to a replacement character, never take down the panel.
  static Future<ExecResult> run(
    SessionTransport transport,
    String command, {
    Duration timeout = defaultTimeout,
  }) async {
    final session = await transport.execute(command);
    // Nothing here reads stdin, and a remote command that happens to wait on
    // EOF would otherwise hang until the timeout for no reason.
    unawaited(session.stdin.close());

    final out = BytesBuilder();
    final err = BytesBuilder();
    final outDone = Completer<void>();
    final errDone = Completer<void>();

    void complete(Completer<void> completer) {
      if (!completer.isCompleted) completer.complete();
    }

    session.stdout.listen(
      out.add,
      onDone: () => complete(outDone),
      onError: (Object _) => complete(outDone),
      cancelOnError: false,
    );
    session.stderr.listen(
      err.add,
      onDone: () => complete(errDone),
      onError: (Object _) => complete(errDone),
      cancelOnError: false,
    );

    try {
      final exitCode = await session.waitForExit(timeout: timeout);
      // The exit status can arrive before the last of the output has been
      // delivered. Waiting for both pipes to close — bounded, so a server
      // that never closes them cannot wedge this — is what stops a probe
      // from parsing a truncated `df` and reporting a wrong number.
      await Future.wait([outDone.future, errDone.future])
          .timeout(const Duration(seconds: 2), onTimeout: () => const []);
      return ExecResult(
        stdout: utf8.decode(out.toBytes(), allowMalformed: true),
        stderr: utf8.decode(err.toBytes(), allowMalformed: true),
        exitCode: exitCode,
      );
    } finally {
      // Whatever happened — clean exit, timeout, or a throw on the way
      // through — the channel does not outlive this call.
      try {
        session.close();
      } catch (_) {
        // Already gone.
      }
    }
  }
}

/// Marker for a monitoring command that could not be run or whose output was
/// unusable, carrying wording already fit to put on screen.
///
/// Separate from `SftpFailure` and `SshConnectionException` because none of
/// this is a transfer or a connection problem: the session is fine, one
/// command on it did not work, and the panel wants to say so in one line
/// without implying the session is in trouble.
class MonitorFailure implements Exception {
  const MonitorFailure(
    this.message, {
    this.details,
    this.needsPrivilege = false,
  });

  /// Short, human-readable, safe to show verbatim.
  final String message;

  /// Command stderr, when there is any worth offering behind a "details".
  final String? details;

  /// True when this failed for lack of privilege — the UI says "this needs
  /// sudo; run it from the terminal" rather than offering a retry that would
  /// fail the same way.
  final bool needsPrivilege;

  @override
  String toString() => message;
}

/// Turns a failed [ExecResult] into a [MonitorFailure] with the privilege
/// hint already resolved, so every action path words a refusal the same way.
MonitorFailure monitorFailureFrom(ExecResult result, String whatFailed) {
  final denied = result.looksLikePermissionDenied;
  final stderr = result.stderr.trim();
  return MonitorFailure(
    denied
        ? '$whatFailed — this needs sudo; run it from the terminal.'
        : whatFailed,
    details: stderr.isEmpty ? null : stderr,
    needsPrivilege: denied,
  );
}
