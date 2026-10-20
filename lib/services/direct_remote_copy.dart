import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dartssh2/dartssh2.dart';

import '../models/host.dart';
import '../models/known_host.dart';
import 'remote_copy.dart';
import 'remote_exec.dart';
import 'server_side_job.dart';
import 'remote_path.dart';
import 'session_controller.dart';
import 'sftp_service.dart';
// Re-exports `ssh_agent_backend.dart`, which is where [CredentialSSHAgent]
// and [MutableSSHAgentHandler] come from.
import 'ssh_service.dart';
import 'transfer_queue.dart';

/// Why the direct A→B path could not run for a particular transfer.
///
/// Each value is a concrete cause the route selector can act on — either by
/// prompting the user (a missing passphrase), by falling back to the relay
/// path silently (destination unreachable from the source, or scp/sftp not
/// installed on the source), or by refusing outright (a mismatched
/// destination host key spotted by ssh-keyscan on the source).
enum DirectCopyUnavailableReason {
  /// The destination is auth'd by password. Agent forwarding has nothing to
  /// sign with, and typing the password blind is not an option we take.
  passwordAuth,

  /// The destination's saved key is encrypted and no cached passphrase is
  /// available. The user has to unlock it (or the caller falls back).
  passphraseNeeded,

  /// No usable private key for the destination in [CredentialStore].
  missingKey,

  /// The source server refused to open a channel to the destination — the
  /// destination port is unreachable, or the destination refused the auth
  /// (which, with agent forwarding, means the source is not being allowed
  /// to reach us to sign).
  noReachability,

  /// The source server has neither `scp` nor `sftp` installed, or exec
  /// itself was refused (a restricted shell, or a firewall's exec-block
  /// account).
  noScpOrSftp,

  /// Agent forwarding was refused by the source SSH server. `sshd` needs
  /// `AllowAgentForwarding yes` and the account has to be allowed to use
  /// it; some hardened boxes disable it wholesale.
  agentRefused,

  /// The second connection the direct path runs its exec on could not be
  /// opened at all — nothing saved for the source host, no connector wired
  /// in, or the dial itself failed. Distinct from [agentRefused]: the source
  /// server never got as far as being asked about forwarding.
  noForwardingConnection,

  /// The destination's host key on the wire does not match what we have
  /// trusted for it on this device. This is a security event, not a
  /// fallback trigger.
  hostKeyMismatch,

  /// The source could not show us the destination's host key — no
  /// `ssh-keyscan` there, the destination unreachable from it, or no key of
  /// the type this device verified — or this device has no verified key for
  /// the destination to compare against. Without one the source's `sftp`
  /// cannot be told which key to accept, so the transfer goes by relay.
  hostKeyUnverifiable,

  /// The exec ran, produced no exit code (dropped channel), or reported
  /// something we cannot classify. Kept separate so the panel can surface
  /// the stderr text instead of a canned message.
  execFailed,
}

/// The direct path cannot run this transfer.
///
/// Distinct from [RemoteCopyFailure] because it is what the route selector
/// uses to decide whether to fall back to the relay path. A relay fallback
/// is the right answer for most subreasons; [DirectCopyUnavailableReason.
/// hostKeyMismatch] is deliberately not — that failure has to surface as a
/// security warning, and a relay from *this* device (which trusts the
/// destination on its own terms) does not reproduce the anomaly.
class SSHDirectCopyUnavailable implements Exception {
  const SSHDirectCopyUnavailable({
    required this.reason,
    this.message,
    this.details,
  });

  final DirectCopyUnavailableReason reason;
  final String? message;
  final String? details;

  @override
  String toString() => message ?? 'Direct transfer is not available.';
}

/// Streams one file from [source]'s server to [destHost] with **no** bytes
/// passing through this device.
///
/// **The design constraint.** [destHost]'s private key must never be
/// written to or read by the source. Agent forwarding — the OpenSSH
/// mechanism at the heart of this — is what makes that possible: `sftp` on
/// A sends signing requests back through the exec channel to a
/// [CredentialSSHAgent] living in *this* process, which holds the one key.
///
/// **On a connection of its own.** The exec does not run on [source]'s
/// session connection. `SSHClient.agentHandler` is `final`, dartssh2 puts an
/// `auth-agent-req@openssh.com` on every session channel a client holding one
/// opens, and OpenSSH grants that once per connection — so a session client
/// with a handler would run one exec and fail every stats poll, log tail and
/// service action afterwards. Each transfer therefore dials its own
/// connection to A (see [SessionController.openAgentForwardedConnection]),
/// installs the handler in *its* slot, runs the single exec, and hangs it up.
/// No key touches A even in-memory over the wire, nothing carries over to the
/// next transfer, and the connection the user is typing in never answers an
/// agent request at all.
///
/// **Batch mode.** The source-side `sftp` runs with `-b -` (batch from
/// stdin) and `-o BatchMode=yes -o PasswordAuthentication=no`. Missing
/// forwarding, a wrong key, or any password prompt fails the exec instead
/// of hanging on a TTY that this process cannot see.
///
/// **Host key trust.** A's `sftp` may accept exactly one key for B: the one
/// [destinationHostKey] names, which this device verified on its own live
/// connection to B. `ssh-keyscan` on A fetches B's public keys (fingerprints
/// alone cannot go into a `known_hosts` file); only a line whose SHA256
/// fingerprint matches is written to a `mktemp` file on A, and `sftp` runs
/// under `StrictHostKeyChecking=yes` with that as its only known-hosts
/// source. What keyscan returned is never trusted on its own say-so — a
/// machine in the middle of A→B can answer keyscan too, and gets
/// [DirectCopyUnavailableReason.hostKeyMismatch] for it — and if anything
/// changes between the scan and the transfer, `sftp`'s own strict check
/// refuses. This used to run under `accept-new` with nothing pinned, which
/// trusted whatever answered on A's network.
///
/// **What it costs.** While the exec runs, A holds a forwarded agent that
/// will sign with the destination's key. Anyone with root on A can use it
/// for that window, which is why the route is opt-in in the UI.
///
/// **Verify, then move.** After exec exits 0 we `stat` the destination
/// through our own SFTP session to B (which is separately authenticated on
/// this device and uses our trusted host key) and confirm the size matches
/// the source. The same four-check safety chain the relay uses gates
/// [deleteSourceAfterVerify].
Future<RemoteCopyOutcome> copyRemoteFileDirect({
  required SessionController source,
  required Host destHost,
  required SshCredentials destCredentials,
  required RemoteFileSystem destinationFs,
  required String sourcePath,
  required String destinationPath,
  required VerifiedHostKey? destinationHostKey,
  bool overwrite = false,
  bool deleteSourceAfterVerify = false,
  TransferProgress? onProgress,
  CancelCheck? isCancelled,
  DetachedRun? detached,
}) async {
  if (destHost.authMethod == SshAuthMethod.password) {
    throw const SSHDirectCopyUnavailable(
      reason: DirectCopyUnavailableReason.passwordAuth,
      message:
          'The destination uses password auth; there is no key to forward.',
    );
  }

  // Not needed — and not asked for, so an encrypted key does not prompt —
  // when picking up a job an earlier run of the app already started.
  final resuming = detached?.resuming ?? false;
  final agent = resuming ? null : _agentFor(destHost, destCredentials);

  final directory = RemotePath.parent(destinationPath);
  final finalName = RemotePath.basename(destinationPath);
  final tempName = _defaultTemporaryName(finalName, stamp: detached?.stamp);
  final tempRemotePath = RemotePath.join(directory, tempName);

  if (isCancelled?.call() ?? false) throw const TransferCancelled();

  var published = false;
  var leftRunning = false;

  try {
    final batch = _sftpBatch(
      localSourcePath: sourcePath,
      tempRemotePath: tempRemotePath,
      finalRemotePath: destinationPath,
      overwrite: overwrite,
    );

    final pinned = resuming
        ? null
        : await _pinDestinationKey(source, destHost, destinationHostKey);
    if (isCancelled?.call() ?? false) throw const TransferCancelled();

    final (:exit, stderr: stderrText) = await _runSourceSftp(
      source: source,
      agent: agent,
      destHost: destHost,
      pinned: pinned,
      batch: batch,
      detached: detached,
      isCancelled: isCancelled,
    );

    if (isCancelled?.call() ?? false) {
      await _cleanupTemporary(destinationFs, tempRemotePath);
      throw const TransferCancelled();
    }

    if (exit != 0) {
      await _cleanupTemporary(destinationFs, tempRemotePath);
      throw _classifyFailure(exit ?? -1, stderrText);
    }

    // Verify the landed size using our own trusted SFTP session to B.
    final sourceSize = await source.sftp().then(
          (fs) => fs.sizeOf(sourcePath),
        );
    final landed = await destinationFs.sizeOf(destinationPath);
    if (landed == null) {
      await _cleanupTemporary(destinationFs, tempRemotePath);
      throw const RemoteCopyFailure(
        'The direct copy exited without an error, but the destination server '
        'does not report the file. Nothing was changed there.',
      );
    }
    if (sourceSize != null && landed != sourceSize) {
      // Size mismatch: leave the file in place under the final name — the
      // sftp batch already renamed — and surface it as a copy failure so a
      // move does not delete the source.
      throw RemoteCopyFailure(
        'The copy on the destination server is not the size it should be. '
        'The original was not changed.',
        details: 'source reports $sourceSize bytes, destination reports '
            '$landed',
      );
    }

    published = true;
    onProgress?.call(landed);

    if (deleteSourceAfterVerify) {
      final sourceFs = await source.sftp();
      final remaining = await sourceFs.sizeOf(sourcePath);
      if (remaining != null && remaining != landed) {
        throw RemoteCopyFailure(
          'The original changed while it was being copied, so it was left '
          'where it is. The copy on the destination is what was read.',
          details: 'copied $landed bytes, the source now holds $remaining',
        );
      }
      await sourceFs.remove(sourcePath);
      return RemoteCopyOutcome(
        bytesCopied: landed,
        destinationPath: destinationPath,
        sourceDeleted: true,
      );
    }

    return RemoteCopyOutcome(
      bytesCopied: landed,
      destinationPath: destinationPath,
      sourceDeleted: false,
    );
  } on ServerJobLeftRunning {
    leftRunning = true;
    rethrow;
  } finally {
    // A job left running is still writing the temp; it and its job folder
    // are the next run's to deal with.
    if (detached != null && !leftRunning) {
      unawaited(_cleanupJob(source, detached.jobId));
    }
    // Best-effort cleanup: any exit that did not verify a landed file
    // should leave no temp behind on the destination. `_cleanupTemporary`
    // above handles the known-failure cases; this catches surprise throws
    // between the exec and the rename.
    if (!published && !leftRunning) {
      // The sftp batch removes the temp with `-rm` on the target path, but
      // only reaches that line when the put succeeded. Anything earlier —
      // a network drop mid-put, an exec killed by cancel — leaves the temp.
      unawaited(_cleanupTemporary(destinationFs, tempRemotePath));
    }
  }
}

/// Waits for [session] to exit, checking [isCancelled] between polls.
///
/// Cancellation closes the exec channel, which is what stops the source's
/// `sftp` — the byte pipe belongs to that process, and there is no other
/// lever on it from here.
Future<int?> _awaitExit(
  SSHSession session, {
  CancelCheck? isCancelled,
}) async {
  final exitFuture = session.done.then<int?>((_) => session.exitCode);
  if (isCancelled == null) return exitFuture;

  // Race the exit against a periodic cancel poll. Timer-based rather than
  // event-based because [TransferHandle] is a flag, not a stream.
  while (true) {
    final winner = await Future.any<Object?>([
      exitFuture,
      Future<Object?>.delayed(const Duration(milliseconds: 200), () => _poll),
    ]);
    if (identical(winner, _poll)) {
      if (isCancelled()) {
        try {
          session.close();
        } catch (_) {
          // Already gone; the exit future will complete of its own accord.
        }
        return exitFuture;
      }
      continue;
    }
    return winner as int?;
  }
}

const Object _poll = Object();

/// Runs a direct copy's source-side `sftp` as a background job on the
/// source server, so it finishes whether or not this app is still there —
/// see `server_side_job.dart`. A copy given none runs it attached to an
/// exec channel, as before.
class DetachedRun {
  const DetachedRun({
    required this.jobId,
    required this.stamp,
    this.resuming = false,
    this.onLaunched,
    this.isAbandoned,
    this.pollInterval = const Duration(seconds: 2),
  });

  final String jobId;

  /// Names the destination temp file or staging folder. Persisted with the
  /// job, so a resumed run finds what the job wrote.
  final int stamp;

  /// The job was started by an earlier run of the app: follow it to the end
  /// and finish the copy, but do not start it again.
  final bool resuming;

  /// Called as soon as the job exists on the source — the point from which
  /// it outlives this app — so the caller can remember it.
  final Future<void> Function()? onLaunched;

  /// Whether a cancel came from the session going away (its tab closed, its
  /// connection dropped) rather than from the user. The job is then left to
  /// finish on its own instead of being stopped.
  final bool Function()? isAbandoned;

  final Duration pollInterval;
}

/// This app stopped following a server-side copy — its session closed or
/// dropped — while the copy carries on on the source. Not a failure: the
/// job is picked up again the next time the source is opened.
class ServerJobLeftRunning implements Exception {
  const ServerJobLeftRunning();

  @override
  String toString() =>
      'Still running on the source server; it will finish there.';
}

CredentialSSHAgent _agentFor(Host destHost, SshCredentials credentials) {
  try {
    return CredentialSSHAgent.forHost(host: destHost, credentials: credentials);
  } on SSHAgentUnavailable catch (e) {
    throw SSHDirectCopyUnavailable(
      reason: switch (e.reason) {
        SSHAgentUnavailableReason.passphraseNeeded =>
          DirectCopyUnavailableReason.passphraseNeeded,
        SSHAgentUnavailableReason.missingKey =>
          DirectCopyUnavailableReason.missingKey,
        SSHAgentUnavailableReason.unusableKey =>
          DirectCopyUnavailableReason.missingKey,
      },
      message: e.message,
    );
  }
}

/// Runs [batch] through `sftp` on the source, attached or as a job, and
/// returns its exit code and what it said. [agent] and [pinned] are null
/// only when resuming a job, which needs neither.
Future<({int? exit, String stderr})> _runSourceSftp({
  required SessionController source,
  required CredentialSSHAgent? agent,
  required Host destHost,
  required List<String>? pinned,
  required String batch,
  required DetachedRun? detached,
  CancelCheck? isCancelled,
}) {
  if (detached != null) {
    return _runDetached(
      source: source,
      agent: agent,
      destHost: destHost,
      pinned: pinned,
      batch: batch,
      run: detached,
      isCancelled: isCancelled,
    );
  }
  return _runAttached(
    source: source,
    agent: agent!,
    command: _sourceSftpCommand(destHost, pinned!),
    batch: batch,
    isCancelled: isCancelled,
  );
}

Future<({int? exit, String stderr})> _runAttached({
  required SessionController source,
  required CredentialSSHAgent agent,
  required String command,
  required String batch,
  CancelCheck? isCancelled,
}) async {
  final exec = await _openForwardedExec(source, agent, command);
  try {
    final session = exec.session;
    // Feed the batch script. Close stdin so `sftp -b -` sees EOF.
    session.stdin.add(Uint8List.fromList(utf8.encode(batch)));
    unawaited(session.stdin.close());

    final stderrBytes = <int>[];
    final stderrDone =
        session.stderr.listen(stderrBytes.addAll).asFuture<void>();
    unawaited(session.stdout.drain<void>());

    // Poll for cancellation while the exec runs. sftp on A owns the byte
    // pipe; the only lever we have is to close the channel, which is what
    // `session.close()` does.
    final exit = await _awaitExit(session, isCancelled: isCancelled);
    await stderrDone;
    return (
      exit: exit,
      stderr: utf8.decode(stderrBytes, allowMalformed: true).trim(),
    );
  } finally {
    // Everything after the exec runs on our own trusted SFTP to A and B; no
    // reason to hold a second login on the source open across it.
    exec.close();
  }
}

/// Starts the job (unless resuming), then follows it to its end over the
/// source's ordinary session.
///
/// The agent-forwarded connection is held only until `sftp` has signed in
/// to the destination — the launch script says so, or this app's agent has
/// answered the sign request — so the source can use the destination key
/// for seconds rather than for the length of the transfer.
Future<({int? exit, String stderr})> _runDetached({
  required SessionController source,
  required CredentialSSHAgent? agent,
  required Host destHost,
  required List<String>? pinned,
  required String batch,
  required DetachedRun run,
  CancelCheck? isCancelled,
}) async {
  if (!run.resuming) {
    final signed = Completer<void>();
    final watcher = _SignWatchingAgent(agent!, () {
      if (!signed.isCompleted) signed.complete();
    });
    final exec = await _openForwardedExec(
      source,
      watcher,
      ServerSideJob.launchCommand(
        jobId: run.jobId,
        destHost: destHost,
        pinnedKnownHosts: pinned!,
      ),
    );
    try {
      final session = exec.session;
      session.stdin.add(Uint8List.fromList(utf8.encode(batch)));
      unawaited(session.stdin.close());
      unawaited(session.stdout.drain<void>());
      unawaited(session.stderr.drain<void>());
      // From here the job exists on the source and outlives this app.
      await run.onLaunched?.call();

      await Future.any<void>([
        session.done,
        signed.future.then((_) => Future<void>.delayed(_signInGrace)),
      ]).timeout(const Duration(seconds: 90), onTimeout: () {});
      final launchExit = session.exitCode;
      if (launchExit != null && launchExit != 0) {
        throw SSHDirectCopyUnavailable(
          reason: DirectCopyUnavailableReason.execFailed,
          message: 'The source server could not start the transfer '
              '(exit $launchExit).',
        );
      }
    } finally {
      exec.close();
    }
  }

  while (true) {
    if (isCancelled?.call() ?? false) {
      if (run.isAbandoned?.call() ?? false) throw const ServerJobLeftRunning();
      try {
        await RemoteExec.run(
          source.connection,
          ServerSideJob.cancelCommand(run.jobId),
        );
      } catch (_) {
        // The source is unreachable; nothing more this app can do to stop it.
      }
      throw const TransferCancelled();
    }

    final ServerJobStatus status;
    try {
      final result = await RemoteExec.run(
        source.connection,
        ServerSideJob.statusCommand(run.jobId),
      );
      status = ServerSideJob.parseStatus(result.stdout);
    } catch (_) {
      // This app's session to the source is gone or struggling. The job is
      // not, and it is picked up again the next time the source is opened.
      if (source.connection.isClosed) throw const ServerJobLeftRunning();
      await _waitUnlessCancelled(run.pollInterval, isCancelled);
      continue;
    }

    switch (status.state) {
      case ServerJobState.finished:
        return (exit: status.exitCode, stderr: status.log);
      case ServerJobState.gone:
        return (
          exit: -1,
          stderr: 'The transfer stopped on the source server before it '
              'finished — was the server restarted? ${status.log}'.trim(),
        );
      case ServerJobState.running:
        await _waitUnlessCancelled(run.pollInterval, isCancelled);
    }
  }
}

/// How long after the agent signs before the forwarded connection is let
/// go: the destination's answer to the signature is one round trip away.
const Duration _signInGrace = Duration(seconds: 2);

Future<void> _waitUnlessCancelled(
  Duration total,
  CancelCheck? isCancelled,
) async {
  const step = Duration(milliseconds: 200);
  var waited = Duration.zero;
  while (waited < total) {
    if (isCancelled?.call() ?? false) return;
    await Future<void>.delayed(step);
    waited += step;
  }
}

/// Removes a finished job's folder on the source. Best effort: a leftover
/// is a few bytes under ~/.cache.
Future<void> _cleanupJob(SessionController source, String jobId) async {
  try {
    if (source.connection.isClosed) return;
    await RemoteExec.run(
      source.connection,
      ServerSideJob.cleanupCommand(jobId),
    );
  } catch (_) {
    // See above.
  }
}

/// Passes every request to [_inner] and reports when it has answered a sign
/// request — the moment `sftp` on the source has what it needs to sign in.
class _SignWatchingAgent implements SSHAgentHandler {
  _SignWatchingAgent(this._inner, this._onSigned);

  final SSHAgentHandler _inner;
  final void Function() _onSigned;

  /// SSH_AGENTC_SIGN_REQUEST; the request starts with its message type.
  static const int _signRequest = 13;

  @override
  Future<Uint8List> handleRequest(Uint8List request) async {
    final reply = await _inner.handleRequest(request);
    if (request.isNotEmpty && request.first == _signRequest) _onSigned();
    return reply;
  }
}

/// One transfer's exec on the source, plus the connection it owns.
///
/// The connection exists for this exec and nothing else can reach it, so
/// [close] takes both down together. Idempotent, because the happy path lets
/// go of it as soon as the exec has exited — no reason to hold a second login
/// open through a verification walk — and the caller's `finally` still calls
/// it as a backstop.
class _ForwardedExec {
  _ForwardedExec(this.session, this._transport, this._release);

  final SSHSession session;
  final SessionTransport _transport;
  final void Function() _release;
  var _closed = false;

  void close() {
    if (_closed) return;
    _closed = true;
    _release();
    try {
      _transport.close();
    } catch (_) {
      // Already gone.
    }
  }
}

/// Dials the transfer's own connection to the source, installs [agent] in its
/// agent slot, and starts [command] on it.
///
/// Every failure past the dial takes the connection down with it — a
/// half-built transfer must not leave an extra authenticated session sitting
/// on the source server.
Future<_ForwardedExec> _openForwardedExec(
  SessionController source,
  SSHAgentHandler agent,
  String command,
) async {
  SessionTransport? transport;
  try {
    transport = await source.openAgentForwardedConnection();
  } on SshConnectionException catch (e) {
    throw SSHDirectCopyUnavailable(
      reason: DirectCopyUnavailableReason.noForwardingConnection,
      message: 'Could not open a second connection to the source server for '
          'this transfer. ${e.message}',
      details: e.details,
    );
  }

  final slot = transport?.agentSlot;
  if (transport == null || slot == null) {
    transport?.close();
    throw const SSHDirectCopyUnavailable(
      reason: DirectCopyUnavailableReason.noForwardingConnection,
      message: 'This session cannot open the agent-forwarding connection the '
          'direct path needs — there is no saved credential for the source '
          'server to log it in with.',
    );
  }

  // The release clears the slot only if it still holds this specific agent,
  // so nothing can be unhooked from underneath a transfer that installed
  // after it. Belt and braces on a connection only this transfer can see.
  final release = slot.install(agent);
  try {
    return _ForwardedExec(await transport.execute(command), transport, release);
  } catch (e) {
    release();
    transport.close();
    // The client throws SSHChannelRequestError('Failed to request agent
    // forwarding') when the source's sshd refuses the auth-agent-req.
    final text = e.toString();
    if (text.contains('agent forwarding')) {
      throw const SSHDirectCopyUnavailable(
        reason: DirectCopyUnavailableReason.agentRefused,
        message: 'The source server refused agent forwarding — the direct '
            'path needs `AllowAgentForwarding yes` in its sshd config.',
      );
    }
    throw SSHDirectCopyUnavailable(
      reason: DirectCopyUnavailableReason.execFailed,
      message: 'The source server refused an exec channel: $text',
      details: text,
    );
  }
}

SSHDirectCopyUnavailable _classifyFailure(int exit, String stderr) {
  final lower = stderr.toLowerCase();
  if (lower.contains('command not found') ||
      lower.contains('not found') && lower.contains('sftp') ||
      lower.contains('no such file or directory') && exit == 127) {
    return SSHDirectCopyUnavailable(
      reason: DirectCopyUnavailableReason.noScpOrSftp,
      message: 'The source server does not have `sftp` installed, or it is '
          'not on PATH for this account.',
      details: stderr,
    );
  }
  if (lower.contains('connection refused') ||
      lower.contains('network is unreachable') ||
      lower.contains('no route to host') ||
      lower.contains('name or service not known') ||
      lower.contains('host is unreachable') ||
      lower.contains('could not resolve hostname') ||
      lower.contains('kex_exchange_identification') ||
      lower.contains('connection timed out')) {
    return SSHDirectCopyUnavailable(
      reason: DirectCopyUnavailableReason.noReachability,
      message: 'The source could not reach the destination server.',
      details: stderr,
    );
  }
  if (lower.contains('permission denied') ||
      lower.contains('publickey') && lower.contains('failed')) {
    return SSHDirectCopyUnavailable(
      reason: DirectCopyUnavailableReason.agentRefused,
      message: 'The destination server refused the forwarded key.',
      details: stderr,
    );
  }
  if (lower.contains('host key verification failed') ||
      lower.contains('remote host identification has changed')) {
    return SSHDirectCopyUnavailable(
      reason: DirectCopyUnavailableReason.hostKeyMismatch,
      message: 'The destination presented a different host key than expected. '
          'Direct transfer refused.',
      details: stderr,
    );
  }
  return SSHDirectCopyUnavailable(
    reason: DirectCopyUnavailableReason.execFailed,
    message: 'Direct transfer failed on the source server '
        '(exit $exit)${stderr.isEmpty ? '' : ': $stderr'}',
    details: stderr,
  );
}

/// Builds the sftp batch script. `-put -rename` handles the "publish only
/// after the whole file is on B" pattern the relay path already uses.
///
/// On [overwrite], `-rm` deletes the final target first — dash-prefixed so
/// the batch continues even when nothing was there to remove, which is
/// nearly always the case.
String _sftpBatch({
  required String localSourcePath,
  required String tempRemotePath,
  required String finalRemotePath,
  required bool overwrite,
}) {
  final buf = StringBuffer();
  buf.writeln('progress');
  buf.writeln('put ${_sftpQuote(localSourcePath)} '
      '${_sftpQuote(tempRemotePath)}');
  if (overwrite) {
    // Dash prefix: keep going even if the final path isn't there. Silences
    // the "no such file" the second copy of this batch would trip on.
    buf.writeln('-rm ${_sftpQuote(finalRemotePath)}');
  }
  buf.writeln('rename ${_sftpQuote(tempRemotePath)} '
      '${_sftpQuote(finalRemotePath)}');
  buf.writeln('bye');
  return buf.toString();
}

/// Removes [path] on the destination, ignoring failures.
///
/// A temp file left behind on B is not a security issue — it is named
/// `.<orig>.ssg-part-<millis>` and unmistakably ours — but a directory
/// full of them is clutter, and this is the one lever the direct path has
/// against it. Uses our own trusted SFTP to B, not the source-side sftp.
Future<void> _cleanupTemporary(RemoteFileSystem fs, String path) async {
  try {
    await fs.remove(path);
  } catch (_) {
    // Already gone, or never got there.
  }
}

/// A stable temporary path on the source. Only the source sees it; the
/// destination temp is named by `_defaultTemporaryName` below.
/// The `known_hosts` lines in [keyscanOutput] whose key is exactly [trusted].
///
/// [keyscanOutput] is `ssh-keyscan`'s stdout, run on the source: one
/// `<host> <key-type> <base64-blob>` line per key, plus `#` comments. Each
/// blob is fingerprinted here the way OpenSSH and dartssh2 do it — SHA256,
/// unpadded base64 — and compared with what this device verified.
///
/// [sameTypeMismatch] is set when the scan offered a key of [trusted]'s type
/// that is *not* it: the destination as seen from the source is presenting a
/// different key from the one it presents to us. Lines for other key types
/// are ignored either way; a server holding several host keys is ordinary.
({List<String> lines, bool sameTypeMismatch}) pinKnownHostsLines(
  String keyscanOutput,
  VerifiedHostKey trusted,
) {
  final lines = <String>[];
  var mismatch = false;
  for (final raw in const LineSplitter().convert(keyscanOutput)) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final fields = line.split(RegExp(r'\s+'));
    if (fields.length < 3) continue;
    if (KnownHostKey.canonicalKeyType(fields[1]) != trusted.keyType) continue;
    final Uint8List blob;
    try {
      blob = base64.decode(base64.normalize(fields[2]));
    } on FormatException {
      continue;
    }
    final digest = base64.encode(sha256.convert(blob).bytes).replaceAll('=', '');
    if ('SHA256:$digest' == trusted.fingerprint) {
      // Host, type and blob only: a trailing comment has no business in a
      // file `sftp` reads as trust.
      lines.add('${fields[0]} ${fields[1]} ${fields[2]}');
    } else {
      mismatch = true;
    }
  }
  return (lines: lines, sameTypeMismatch: mismatch);
}

/// Fetches the destination's key as the source sees it and keeps only the
/// line that matches [verified]. See "Host key trust" on
/// [copyRemoteFileDirect].
///
/// Runs on the source's ordinary session connection, not the transfer's
/// agent-forwarded one: OpenSSH grants agent forwarding once per connection,
/// and the `sftp` exec needs that grant.
Future<List<String>> _pinDestinationKey(
  SessionController source,
  Host destHost,
  VerifiedHostKey? verified,
) async {
  if (verified == null) {
    throw const SSHDirectCopyUnavailable(
      reason: DirectCopyUnavailableReason.hostKeyUnverifiable,
      message: 'This device has no verified host key for the destination '
          'to pin the transfer to.',
    );
  }

  final ExecResult scan;
  try {
    scan = await RemoteExec.run(
      source.connection,
      'ssh-keyscan -T 10 -p ${destHost.port} '
      '${_shellQuote(destHost.hostname)} 2>/dev/null',
      timeout: const Duration(seconds: 20),
    );
  } catch (e) {
    throw SSHDirectCopyUnavailable(
      reason: DirectCopyUnavailableReason.hostKeyUnverifiable,
      message: 'Could not check the destination\'s host key from the '
          'source server.',
      details: e.toString(),
    );
  }

  final pin = pinKnownHostsLines(scan.stdout, verified);
  if (pin.lines.isNotEmpty) return pin.lines;
  if (pin.sameTypeMismatch) {
    throw SSHDirectCopyUnavailable(
      reason: DirectCopyUnavailableReason.hostKeyMismatch,
      message: 'The source server sees a different host key for '
          '"${destHost.displayName}" than this device trusts '
          '(${verified.fingerprint}). Something between the two servers may '
          'be intercepting the connection, so nothing was transferred.',
    );
  }
  throw const SSHDirectCopyUnavailable(
    reason: DirectCopyUnavailableReason.hostKeyUnverifiable,
    message: 'The source server could not show the destination\'s host key '
        '(no ssh-keyscan there, or the destination is unreachable from it).',
  );
}

/// The command run on the source for one direct transfer.
///
/// `-b -` reads the batch from stdin. The `-o` flags refuse to fall through
/// to a password prompt if the forwarded key does not authenticate, and
/// confine host-key trust to [pinnedKnownHosts], written to a `mktemp` file
/// (mode 0600, unpredictable name) that the trap removes however `sftp`
/// exits. `GlobalKnownHostsFile=/dev/null` keeps the source's system-wide
/// list from vouching for a key this device never verified. No
/// `ForwardAgent`: `sftp` would ignore it, and the destination has no use
/// for the agent anyway.
String _sourceSftpCommand(Host destHost, List<String> pinnedKnownHosts) {
  final lines = pinnedKnownHosts.map(_shellQuote).join(' ');
  return [
    'sh',
    '-c',
    _shellQuote(
      'kh=\$(mktemp) || exit 70; '
      'trap \'rm -f "\$kh"\' EXIT; '
      'printf \'%s\\n\' $lines > "\$kh" || exit 70; '
      'sftp '
      '-b - '
      '-P ${destHost.port} '
      '-o BatchMode=yes '
      '-o PasswordAuthentication=no '
      '-o KbdInteractiveAuthentication=no '
      '-o StrictHostKeyChecking=yes '
      '-o UserKnownHostsFile="\$kh" '
      '-o GlobalKnownHostsFile=/dev/null '
      '${_shellQuote('${destHost.username}@${destHost.hostname}')}',
    ),
  ].join(' ');
}

/// `notes.md` → `.notes.md.ssg-part-1738000000000`, matching relay.
String _defaultTemporaryName(String finalName, {int? stamp}) {
  stamp ??= DateTime.now().millisecondsSinceEpoch;
  final head = finalName.length > 200 ? finalName.substring(0, 200) : finalName;
  return '.$head.ssg-part-$stamp';
}

/// POSIX single-quote around anything given to `sh -c`.
String _shellQuote(String s) => "'${s.replaceAll("'", "'\"'\"'")}'";

/// sftp's batch parser handles double quotes for paths with spaces; a
/// backslash escapes internal quotes.
String _sftpQuote(String s) => '"${s.replaceAll('"', r'\"')}"';

/// Copies one whole directory from [source]'s server to [destHost] via
/// `sftp put -r`, running on the source and pointed at the destination — the
/// bytes never touch this device.
///
/// **Why `put -r` at all.** The relay path (`copyRemoteDirectory`) does its
/// own tree walk here in Dart, one file at a time; the direct path cannot
/// afford that — every listing costs a round trip on the destination that the
/// source could have done locally. `sftp -b -` on A already knows how to
/// recurse, and does so in one exec channel, so the batch is
/// `put -r SRC DST` and nothing else. From A's perspective the source is on its own
/// filesystem, so `put` reads from local disk; the "remote" for that `put`
/// is B, over an SSH connection A opened using the forwarded agent.
///
/// **Destination naming.** `sftp put -r local remote` in OpenSSH creates the
/// remote directory at that exact path (it does not append `basename(local)`)
/// as long as nothing is there yet. So the caller passes the final desired
/// path — including any [RemotePath.deduplicate] renaming for keep-both — and
/// we ensure the parent exists via our trusted SFTP to B (so a nested
/// destination like `/srv/team/uploads/Documents` does not fail on a missing
/// `/srv/team`), then let the source-side `sftp` create it fresh.
///
/// **Replace.** An overwrite does not clear the target first. `put -r` writes
/// into a hidden sibling that does not exist yet (see
/// [StagedDirectoryReplace]), the verification below runs against that, and
/// only then is it swapped in for the folder it replaces. A cancel, a failed
/// exec or a mismatched count removes the staging folder and leaves the
/// original exactly as it was.
///
/// **Verification.** After the exec exits cleanly we walk the destination
/// tree over our own SFTP session to B (through [measureRemoteTree]) and
/// confirm both the file count and the summed bytes match what the source
/// reports for its side. That is the safety chain [copyRemoteDirectory] runs
/// per-file, applied to the whole batch here — the direct path has no
/// per-file receipts to check.
///
/// **Move semantics.** [deleteSourceAfterVerify] deletes the source tree only
/// after both counts on B match A, and for a replace only after the swap. Any
/// failure before then leaves the source untouched, and the destination as
/// it was.
Future<RemoteCopyOutcome> copyRemoteDirectoryDirect({
  required SessionController source,
  required Host destHost,
  required SshCredentials destCredentials,
  required RemoteFileSystem destinationFs,
  required String sourceDirectory,
  required String destinationDirectory,
  required VerifiedHostKey? destinationHostKey,
  bool overwrite = false,
  bool deleteSourceAfterVerify = false,
  TransferProgress? onProgress,
  CancelCheck? isCancelled,
  DetachedRun? detached,
}) async {
  if (destHost.authMethod == SshAuthMethod.password) {
    throw const SSHDirectCopyUnavailable(
      reason: DirectCopyUnavailableReason.passwordAuth,
      message:
          'The destination uses password auth; there is no key to forward.',
    );
  }

  final resuming = detached?.resuming ?? false;
  final agent = resuming ? null : _agentFor(destHost, destCredentials);

  if (isCancelled?.call() ?? false) throw const TransferCancelled();

  // Before anything below touches the destination: a host-key refusal must
  // arrive before any write to B, the parent mkdir included.
  final pinned = resuming
      ? null
      : await _pinDestinationKey(source, destHost, destinationHostKey);
  if (isCancelled?.call() ?? false) throw const TransferCancelled();

  final replace = overwrite
      ? StagedDirectoryReplace(
          destinationFs,
          destinationDirectory,
          stamp: detached?.stamp,
        )
      : null;
  // Where `put -r` writes: beside the folder a replace is for, or straight
  // into a free name. Either way nothing is there yet, which is what makes
  // `put -r` create it rather than nest the source inside it.
  final root = replace?.staging ?? destinationDirectory;

  // Ensure the destination's parent exists via our own trusted SFTP to B,
  // so put -r does not fail on a missing intermediate directory.
  final destParent = RemotePath.parent(destinationDirectory);
  try {
    await destinationFs.mkdir(destParent);
  } catch (_) {
    // Already there is the common case; a real failure will surface on the
    // put itself.
  }

  final sourceParent = RemotePath.parent(sourceDirectory);
  final sourceName = RemotePath.basename(sourceDirectory);

  // Until the tree is verified — and, for a replace, until the swap takes
  // charge of it — every exit takes what `put -r` wrote with it.
  var discardRoot = true;
  var leftRunning = false;

  try {
    // The sftp batch: cd to the source parent so `put -r <name> <dest>`
    // works even when the source has spaces (a bare absolute path with
    // spaces sometimes trips up older sftp batch parsers). This mirrors
    // what an interactive user would do.
    final batch = _sftpDirectoryBatch(
      localSourceParent: sourceParent,
      localSourceName: sourceName,
      remoteDestination: root,
    );

    final (:exit, stderr: stderrText) = await _runSourceSftp(
      source: source,
      agent: agent,
      destHost: destHost,
      pinned: pinned,
      batch: batch,
      detached: detached,
      isCancelled: isCancelled,
    );

    // A cancel or a failure mid-put leaves whatever partial tree A had time
    // to write; the `finally` below removes it, so a retry lands fresh.
    if (isCancelled?.call() ?? false) throw const TransferCancelled();
    if (exit != 0) throw _classifyFailure(exit ?? -1, stderrText);

    // Whole-batch verification: file counts and byte totals on both sides
    // must line up. There is no per-file receipt on the direct path; this
    // is the safety chain of copyRemoteFile, applied at the batch level.
    final sourceSftp = await source.sftp();
    final landed = await measureRemoteTree(destinationFs, root);
    final original = await measureRemoteTree(sourceSftp, sourceDirectory);
    if (landed.files != original.files) {
      throw RemoteCopyFailure(
        'The copy on the destination server has a different number of files '
        'than the source. The original was not changed.',
        details: 'source has ${original.files} files, destination has '
            '${landed.files}',
      );
    }
    if (landed.bytes != original.bytes) {
      throw RemoteCopyFailure(
        'The copy on the destination server is a different size than the '
        'source. The original was not changed.',
        details: 'source is ${original.bytes} bytes, destination is '
            '${landed.bytes} bytes',
      );
    }

    if (replace != null) {
      // The last point a cancel can stop the replace.
      if (isCancelled?.call() ?? false) throw const TransferCancelled();
    }
    // Verified. From here the tree is the user's — or, for a replace, the
    // swap's to deal with, failure included.
    discardRoot = false;
    await replace?.swapIn();
    onProgress?.call(landed.bytes);

    if (deleteSourceAfterVerify) {
      // Both counts already checked; nothing left to compare. Blow the
      // source tree away via our own trusted SFTP to A.
      await removeRemoteDirectoryTree(sourceSftp, sourceDirectory);
      return RemoteCopyOutcome(
        bytesCopied: landed.bytes,
        destinationPath: destinationDirectory,
        sourceDeleted: true,
      );
    }

    return RemoteCopyOutcome(
      bytesCopied: landed.bytes,
      destinationPath: destinationDirectory,
      sourceDeleted: false,
    );
  } on ServerJobLeftRunning {
    leftRunning = true;
    rethrow;
  } finally {
    if (detached != null && !leftRunning) {
      unawaited(_cleanupJob(source, detached.jobId));
    }
    // Awaited, so a transfer reported as failed or cancelled has already
    // taken its partial tree with it. For a replace that tree is the
    // staging folder; the folder it was to replace was never touched. A job
    // left running is still writing it.
    if (discardRoot && !leftRunning) {
      await removeRemoteDirectoryTree(destinationFs, root);
    }
  }
}

/// `progress; cd <parent>; put -r <name> <dest>; bye` — the smallest batch
/// that gets `put -r` to name the destination exactly rather than nest a
/// `basename(local)` under it.
String _sftpDirectoryBatch({
  required String localSourceParent,
  required String localSourceName,
  required String remoteDestination,
}) {
  final buf = StringBuffer()
    ..writeln('progress')
    ..writeln('lcd ${_sftpQuote(localSourceParent)}')
    ..writeln('put -r ${_sftpQuote(localSourceName)} '
        '${_sftpQuote(remoteDestination)}')
    ..writeln('bye');
  return buf.toString();
}
