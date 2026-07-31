import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../models/host.dart';
import '../models/remote_entry.dart';
import 'remote_copy.dart';
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

/// A non-fatal caveat on a completed direct copy, worth surfacing in the UI.
///
/// Used today for the fallback host-key mode: when we cannot verify the
/// destination's host key from the source (ssh-keyscan is missing on A, or
/// we have no stored fingerprint on this device yet), we still allow the
/// transfer under `StrictHostKeyChecking=accept-new` — but the panel says
/// so, because a "check happened" that in fact did not is worse than a
/// warning the user can act on.
enum DirectCopyWarning { hostKeyCheckRelaxed }

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
/// **Host key trust.** We defer to the source's OpenSSH client for the
/// verification of B's key. `StrictHostKeyChecking=accept-new` accepts a
/// first-seen key and stores it in a per-transfer temporary
/// `UserKnownHostsFile` on A (`/tmp/ssg-<uuid>`), which is then removed.
/// A stronger check — pinning B's fingerprint from our own
/// `KnownHostsService` and running under `StrictHostKeyChecking=yes` — is a
/// known gap; see the report.
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
  bool overwrite = false,
  bool deleteSourceAfterVerify = false,
  TransferProgress? onProgress,
  CancelCheck? isCancelled,
  Set<DirectCopyWarning>? warnings,
}) async {
  if (destHost.authMethod == SshAuthMethod.password) {
    throw const SSHDirectCopyUnavailable(
      reason: DirectCopyUnavailableReason.passwordAuth,
      message:
          'The destination uses password auth; there is no key to forward.',
    );
  }

  final CredentialSSHAgent agent;
  try {
    agent = CredentialSSHAgent.forHost(
      host: destHost,
      credentials: destCredentials,
    );
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

  final directory = RemotePath.parent(destinationPath);
  final finalName = RemotePath.basename(destinationPath);
  final tempName = _defaultTemporaryName(finalName);
  final tempRemotePath = RemotePath.join(directory, tempName);

  if (isCancelled?.call() ?? false) throw const TransferCancelled();

  _ForwardedExec? exec;
  var published = false;

  try {
    final batch = _sftpBatch(
      localSourcePath: sourcePath,
      tempRemotePath: tempRemotePath,
      finalRemotePath: destinationPath,
      overwrite: overwrite,
    );

    final targetUser = destHost.username;
    final targetHost = destHost.hostname;
    final port = destHost.port;

    // The source-side sftp command line. `-b -` reads the batch from
    // stdin; `-q` silences the banner; the -o flags refuse to fall through
    // to a password prompt if the forwarded key does not authenticate.
    // `StrictHostKeyChecking=accept-new` with a per-transfer known_hosts
    // file at least stops the standard sshd from refusing on a first-seen
    // host key and stops residue accumulating on the source machine.
    final knownHostsPath = _tempKnownHostsPath();
    final command = [
      'sh',
      '-c',
      _shellQuote(
        'touch ${_shellQuote(knownHostsPath)} && '
        'chmod 600 ${_shellQuote(knownHostsPath)} && '
        'sftp '
        '-b - '
        '-P $port '
        '-o BatchMode=yes '
        '-o PasswordAuthentication=no '
        '-o KbdInteractiveAuthentication=no '
        '-o ForwardAgent=yes '
        '-o StrictHostKeyChecking=accept-new '
        '-o UserKnownHostsFile=${_shellQuote(knownHostsPath)} '
        '${_shellQuote('$targetUser@$targetHost')}; '
        'rc=\$?; rm -f ${_shellQuote(knownHostsPath)}; exit \$rc',
      ),
    ].join(' ');

    warnings?.add(DirectCopyWarning.hostKeyCheckRelaxed);

    exec = await _openForwardedExec(source, agent, command);
    final session = exec.session;

    // Feed the batch script. Close stdin so `sftp -b -` sees EOF.
    session.stdin.add(Uint8List.fromList(utf8.encode(batch)));
    unawaited(session.stdin.close());

    final stderrBytes = <int>[];
    final stderrDone =
        session.stderr.listen(stderrBytes.addAll).asFuture<void>();
    // stdout carries only the sftp banner (silenced by `-q`) — drain to
    // avoid backing up.
    unawaited(session.stdout.drain<void>());

    // Poll for cancellation while the exec runs. sftp on A owns the byte
    // pipe; the only lever we have is to close the channel, which is what
    // `session.close()` does.
    final exit = await _awaitExit(
      session,
      isCancelled: isCancelled,
    );
    await stderrDone;
    final stderrText = utf8.decode(stderrBytes, allowMalformed: true).trim();
    // The exec is over; everything below runs on our own trusted SFTP to A
    // and B. Hang up the transfer's connection now rather than holding a
    // second login on the source open across the verification.
    exec.close();

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
  } finally {
    // Idempotent: the happy path already hung up as soon as the exec ended.
    exec?.close();
    // Best-effort cleanup: any exit that did not verify a landed file
    // should leave no temp behind on the destination. `_cleanupTemporary`
    // above handles the known-failure cases; this catches surprise throws
    // between the exec and the rename.
    if (!published) {
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
  CredentialSSHAgent agent,
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
String _tempKnownHostsPath() {
  final stamp = DateTime.now().microsecondsSinceEpoch;
  return '/tmp/ssg-kh-$stamp';
}

/// `notes.md` → `.notes.md.ssg-part-1738000000000`, matching relay.
String _defaultTemporaryName(String finalName) {
  final stamp = DateTime.now().millisecondsSinceEpoch;
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
/// remote directory at that exact path (it does not append `basename(local)`).
/// So the caller passes the final desired path — including any
/// [RemotePath.deduplicate] renaming for keep-both — and we ensure the parent
/// exists via our trusted SFTP to B (so a nested destination like
/// `/srv/team/uploads/Documents` does not fail on a missing `/srv/team`),
/// clear an overwrite target via [removeRemoteDirectoryTree], then let the
/// source-side `sftp` create it fresh.
///
/// **Verification.** After the exec exits cleanly we walk the destination
/// tree over our own SFTP session to B (through [_directoryFileCount] and
/// [_directoryTotalSize]) and confirm both the file count and the summed
/// bytes match what the source reports for its side. That is the safety chain
/// [copyRemoteDirectory] runs per-file, applied to the whole batch here —
/// the direct path has no per-file receipts to check.
///
/// **Move semantics.** [deleteSourceAfterVerify] deletes the source tree only
/// after both counts on B match A. Any failure leaves the source untouched
/// and, when possible, the destination alone — a botched replace does not
/// take the pre-existing tree with it, since the tree was already gone before
/// `put -r` began.
Future<RemoteCopyOutcome> copyRemoteDirectoryDirect({
  required SessionController source,
  required Host destHost,
  required SshCredentials destCredentials,
  required RemoteFileSystem destinationFs,
  required String sourceDirectory,
  required String destinationDirectory,
  bool overwrite = false,
  bool deleteSourceAfterVerify = false,
  TransferProgress? onProgress,
  CancelCheck? isCancelled,
  Set<DirectCopyWarning>? warnings,
}) async {
  if (destHost.authMethod == SshAuthMethod.password) {
    throw const SSHDirectCopyUnavailable(
      reason: DirectCopyUnavailableReason.passwordAuth,
      message:
          'The destination uses password auth; there is no key to forward.',
    );
  }

  final CredentialSSHAgent agent;
  try {
    agent = CredentialSSHAgent.forHost(
      host: destHost,
      credentials: destCredentials,
    );
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

  if (isCancelled?.call() ?? false) throw const TransferCancelled();

  // Prepare the destination shape via our own trusted SFTP to B:
  // - clear an overwrite target so `put -r` gets a fresh mkdir
  // - ensure the destination's parent exists so put -r does not fail
  //   on a missing intermediate directory
  if (overwrite) {
    await removeRemoteDirectoryTree(destinationFs, destinationDirectory);
  }
  final destParent = RemotePath.parent(destinationDirectory);
  try {
    await destinationFs.mkdir(destParent);
  } catch (_) {
    // Already there is the common case; a real failure will surface on the
    // put itself.
  }

  final sourceParent = RemotePath.parent(sourceDirectory);
  final sourceName = RemotePath.basename(sourceDirectory);

  _ForwardedExec? exec;
  var published = false;

  try {
    // The sftp batch: cd to the source parent so `put -r <name> <dest>`
    // works even when the source has spaces (a bare absolute path with
    // spaces sometimes trips up older sftp batch parsers). This mirrors
    // what an interactive user would do.
    final batch = _sftpDirectoryBatch(
      localSourceParent: sourceParent,
      localSourceName: sourceName,
      remoteDestination: destinationDirectory,
    );

    final targetUser = destHost.username;
    final targetHost = destHost.hostname;
    final port = destHost.port;

    final knownHostsPath = _tempKnownHostsPath();
    final command = [
      'sh',
      '-c',
      _shellQuote(
        'touch ${_shellQuote(knownHostsPath)} && '
        'chmod 600 ${_shellQuote(knownHostsPath)} && '
        'sftp '
        '-b - '
        '-P $port '
        '-o BatchMode=yes '
        '-o PasswordAuthentication=no '
        '-o KbdInteractiveAuthentication=no '
        '-o ForwardAgent=yes '
        '-o StrictHostKeyChecking=accept-new '
        '-o UserKnownHostsFile=${_shellQuote(knownHostsPath)} '
        '${_shellQuote('$targetUser@$targetHost')}; '
        'rc=\$?; rm -f ${_shellQuote(knownHostsPath)}; exit \$rc',
      ),
    ].join(' ');

    warnings?.add(DirectCopyWarning.hostKeyCheckRelaxed);

    exec = await _openForwardedExec(source, agent, command);
    final session = exec.session;

    session.stdin.add(Uint8List.fromList(utf8.encode(batch)));
    unawaited(session.stdin.close());

    final stderrBytes = <int>[];
    final stderrDone =
        session.stderr.listen(stderrBytes.addAll).asFuture<void>();
    unawaited(session.stdout.drain<void>());

    final exit = await _awaitExit(session, isCancelled: isCancelled);
    await stderrDone;
    final stderrText = utf8.decode(stderrBytes, allowMalformed: true).trim();
    // Nothing below needs the source-side `sftp` any more; the walk that
    // verifies the tree runs over our own trusted SFTP sessions.
    exec.close();

    if (isCancelled?.call() ?? false) {
      // A cancel mid-put leaves whatever partial tree A had time to write.
      // Blow it away so a subsequent retry lands in a fresh directory.
      await removeRemoteDirectoryTree(destinationFs, destinationDirectory);
      throw const TransferCancelled();
    }

    if (exit != 0) {
      await removeRemoteDirectoryTree(destinationFs, destinationDirectory);
      throw _classifyFailure(exit ?? -1, stderrText);
    }

    // Whole-batch verification: file counts and byte totals on both sides
    // must line up. There is no per-file receipt on the direct path; this
    // is the safety chain of copyRemoteFile, applied at the batch level.
    final sourceSftp = await source.sftp();
    final destCount = await _directoryFileCount(destinationFs, destinationDirectory);
    final sourceCount = await _directoryFileCount(sourceSftp, sourceDirectory);
    if (destCount != sourceCount) {
      throw RemoteCopyFailure(
        'The copy on the destination server has a different number of files '
        'than the source. The original was not changed.',
        details: 'source has $sourceCount files, destination has $destCount',
      );
    }
    final destBytes =
        await _directoryTotalSize(destinationFs, destinationDirectory);
    final sourceBytes = await _directoryTotalSize(sourceSftp, sourceDirectory);
    if (destBytes != sourceBytes) {
      throw RemoteCopyFailure(
        'The copy on the destination server is a different size than the '
        'source. The original was not changed.',
        details:
            'source is $sourceBytes bytes, destination is $destBytes bytes',
      );
    }

    published = true;
    onProgress?.call(destBytes);

    if (deleteSourceAfterVerify) {
      // Both counts already checked; nothing left to compare. Blow the
      // source tree away via our own trusted SFTP to A.
      await removeRemoteDirectoryTree(sourceSftp, sourceDirectory);
      return RemoteCopyOutcome(
        bytesCopied: destBytes,
        destinationPath: destinationDirectory,
        sourceDeleted: true,
      );
    }

    return RemoteCopyOutcome(
      bytesCopied: destBytes,
      destinationPath: destinationDirectory,
      sourceDeleted: false,
    );
  } finally {
    // Idempotent: the happy path already hung up as soon as the exec ended.
    exec?.close();
    if (!published) {
      // The verify block already cleaned up on the failure paths it can
      // classify; this catches surprise throws between exec and verify.
      unawaited(removeRemoteDirectoryTree(destinationFs, destinationDirectory));
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

/// Walks [root] on [fs] and returns the number of plain files under it.
///
/// Symlinks and anything non-file are not counted, matching what
/// [copyRemoteDirectory] moves — so a verify against a source tree containing
/// symlinks does not flag them as missing on B.
Future<int> _directoryFileCount(RemoteFileSystem fs, String root) async {
  var count = 0;
  final pending = <String>[root];
  for (var index = 0; index < pending.length; index++) {
    final List<RemoteEntry> entries;
    try {
      entries = await fs.list(pending[index]);
    } catch (_) {
      continue;
    }
    for (final entry in entries) {
      if (entry.kind == RemoteEntryKind.file) {
        count++;
      } else if (entry.kind == RemoteEntryKind.directory) {
        pending.add(RemotePath.join(pending[index], entry.name));
      }
    }
  }
  return count;
}

/// Walks [root] on [fs] and returns the sum of file sizes under it. Files
/// whose size the server does not report contribute zero, so this is a
/// comparison against the source computed the same way.
Future<int> _directoryTotalSize(RemoteFileSystem fs, String root) async {
  var total = 0;
  final pending = <String>[root];
  for (var index = 0; index < pending.length; index++) {
    final List<RemoteEntry> entries;
    try {
      entries = await fs.list(pending[index]);
    } catch (_) {
      continue;
    }
    for (final entry in entries) {
      if (entry.kind == RemoteEntryKind.file) {
        total += entry.size ?? 0;
      } else if (entry.kind == RemoteEntryKind.directory) {
        pending.add(RemotePath.join(pending[index], entry.name));
      }
    }
  }
  return total;
}
