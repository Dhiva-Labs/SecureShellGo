import 'dart:typed_data';

import 'editor_document.dart';
import 'remote_copy.dart';
import 'remote_path.dart';
import 'sftp_service.dart';

/// What "this file has not moved under us" means, in the terms a server will
/// actually answer in.
///
/// Size and modification time, and nothing cleverer. A content hash would be
/// stronger and is deliberately not used, for the same reason
/// `remote_copy.dart` gives for not hashing a transfer: it costs a second
/// full read of the file on every save, and the cheap fields catch every case
/// anyone realistically hits — another editor writing the file, a deploy
/// script replacing it, the user's own second session saving it.
class RemoteFingerprint {
  const RemoteFingerprint({this.size, this.modified});

  const RemoteFingerprint.unknown() : size = null, modified = null;

  final int? size;
  final DateTime? modified;

  /// Whether [other] describes the same file contents this does.
  ///
  /// Only the fields both sides reported are compared. A server that omits
  /// mtime — some do, and some report it only to the second — would otherwise
  /// make every save look like a conflict, which trains the user to click
  /// through the one dialog that exists to stop them losing work. Size alone
  /// still catches the overwhelming majority; an edit that changes a file
  /// without changing its length *and* comes from a server that reports no
  /// mtime is the documented gap.
  bool matches(RemoteFingerprint other) {
    if (size != null && other.size != null && size != other.size) return false;
    final mine = modified;
    final theirs = other.modified;
    if (mine != null && theirs != null && !mine.isAtSameMomentAs(theirs)) {
      return false;
    }
    return true;
  }

  /// True when the server told us nothing to compare against at all. The
  /// editor warns once, on save, rather than pretending the guard is armed.
  bool get isBlind => size == null && modified == null;
}

/// Why a save stopped before writing anything.
enum SaveConflictReason {
  /// The file changed on the server since it was opened.
  changed,

  /// The file is no longer there.
  vanished,
}

/// The save did not happen, and the file on the server is untouched.
class EditorSaveConflict implements Exception {
  const EditorSaveConflict(this.reason, this.message, {this.current});

  final SaveConflictReason reason;
  final String message;

  /// What the server says the file looks like now — carried so "reload
  /// theirs" can pick up from here without a second round trip's worth of
  /// disagreement.
  final RemoteFingerprint? current;

  @override
  String toString() => message;
}

/// A save that failed for a reason other than a conflict.
///
/// Distinct from [SftpFailure] so the editor can say the one thing that
/// matters after a failed write, which is in [originalIntact].
class EditorSaveFailure implements Exception {
  const EditorSaveFailure(
    this.message, {
    this.details,
    this.originalIntact = true,
    this.strandedTemporaryPath,
  });

  final String message;
  final String? details;

  /// True for every failure that happened before the rename. The editor says
  /// so out loud, because "the save failed" and "the save failed and your
  /// file is gone" are not the same news.
  final bool originalIntact;

  /// Set only in the one case where the original had to be removed to make
  /// room for the rename and the rename then failed. The complete new
  /// contents are in this file; naming it is the difference between a
  /// recoverable mess and a lost afternoon.
  final String? strandedTemporaryPath;

  @override
  String toString() => message;
}

/// A file, opened for editing.
class EditorOpenResult {
  const EditorOpenResult({
    required this.text,
    required this.lineEndings,
    required this.hadInvalidUtf8,
    required this.fingerprint,
    this.permissions,
  });

  final String text;
  final LineEndingStyle lineEndings;
  final bool hadInvalidUtf8;

  /// Taken *before* the read, so a file that changes between the stat and the
  /// last byte read is caught by the first save rather than silently baked in
  /// as the new baseline.
  final RemoteFingerprint fingerprint;

  final int? permissions;
}

/// What a completed save did.
class SaveOutcome {
  const SaveOutcome({
    required this.bytesWritten,
    required this.fingerprint,
    this.permissionsRestored = false,
    this.permissionsLost = false,
  });

  final int bytesWritten;

  /// The file as it now stands, to be carried forward as the baseline for the
  /// next save.
  final RemoteFingerprint fingerprint;

  /// The rename dropped the original mode and it was put back.
  final bool permissionsRestored;

  /// The rename dropped the original mode and the server refused to put it
  /// back. Surfaced to the user, because a script that arrives 0644 will not
  /// run.
  final bool permissionsLost;
}

/// Reads [path] into memory for editing, or refuses with a reason.
///
/// The size check happens against the *stat*, before a single byte moves:
/// refusing a 90 MB log only after pulling it over a phone connection would
/// be a strange definition of "refused".
Future<EditorOpenResult> openRemoteText({
  required RemoteFileSystem fs,
  RemoteFileMetadata? metadata,
  required String path,
}) async {
  final name = RemotePath.basename(path);
  final stat = await metadata?.statFile(path);
  final size = stat?.size ?? await fs.sizeOf(path);

  if (size != null && size > editorMaxFileBytes) {
    throw EditorOpenRefused(
      EditorRefusal.tooLarge,
      '"$name" is ${RemotePath.formatBytes(size)}. The editor opens files up '
      'to ${RemotePath.formatBytes(editorMaxFileBytes)} — download it '
      'instead.',
    );
  }

  final buffer = BytesBuilder(copy: false);
  await fs.download(
    path,
    write: (chunk) async {
      buffer.add(chunk);
      // The stat is a claim, not a promise — a file being appended to right
      // now (a live log) will outrun it. Stopping at the cap keeps a runaway
      // read from filling the heap on the way to the refusal below.
      if (buffer.length > editorMaxFileBytes) {
        throw EditorOpenRefused(
          EditorRefusal.tooLarge,
          '"$name" is larger than '
          '${RemotePath.formatBytes(editorMaxFileBytes)} and is still '
          'growing. Download it instead.',
        );
      }
    },
  );

  final bytes = buffer.takeBytes();
  final decoded = decodeEditorText(bytes, name: name);
  return EditorOpenResult(
    text: decoded.text,
    lineEndings: decoded.lineEndings,
    hadInvalidUtf8: decoded.hadInvalidUtf8,
    fingerprint: RemoteFingerprint(
      size: stat?.size ?? bytes.length,
      modified: stat?.modified,
    ),
    permissions: stat?.permissions,
  );
}

/// Writes [text] back to [path] without ever putting the original at risk.
///
/// **The order is the whole feature.** In sequence:
///
///  1. Unless [force], re-stat [path] and compare against [expected]. A file
///     that changed since it was opened throws [EditorSaveConflict] *here* —
///     before anything is opened for writing, so a conflict is guaranteed to
///     have written nothing at all. A file that has vanished throws the same
///     exception with a different reason.
///  2. The new contents go to `.<name>.ssg-edit-<millis>` in the same
///     directory, which is where they have to be: a rename is only atomic
///     within a filesystem, and a temp elsewhere would silently degrade to a
///     copy-then-delete.
///  3. The handle is closed, then the temp file is stat'd and its size
///     checked against what was written. SFTP has no portable fsync — the
///     `fsync@openssh.com` extension is not something dartssh2 exposes — so
///     the close plus a server-side size check is the strongest durability
///     signal available over this protocol, and it is the same one
///     `remote_copy.dart` verifies a transfer with.
///  4. Only then is the temp renamed over the original. A plain rename is
///     tried first, because on every POSIX server it replaces the target
///     atomically and there is never a moment when the file does not exist.
///     Only if that is refused — some SFTP servers implement the letter of
///     the spec, which says rename must fail onto an existing name — is the
///     original removed and the rename retried.
///  5. The mode is put back if the rename did not carry it.
///
/// Any failure before step 4 takes the temp file with it and leaves the
/// original untouched, which is what [RemoteFileWriter.abort] is for.
Future<SaveOutcome> saveRemoteText({
  required RemoteFileSystem fs,
  RemoteFileMetadata? metadata,
  required String path,
  required String text,
  required LineEndingStyle lineEndings,
  required RemoteFingerprint expected,
  int? permissions,
  bool force = false,
  TemporaryNamer? temporaryNamer,
}) async {
  final name = RemotePath.basename(path);
  final directory = RemotePath.parent(path);

  if (!force) {
    final current = await _currentFingerprint(fs, metadata, path);
    if (current == null) {
      throw EditorSaveConflict(
        SaveConflictReason.vanished,
        '"$name" is no longer on the server. Nothing was written.',
      );
    }
    if (!current.matches(expected)) {
      throw EditorSaveConflict(
        SaveConflictReason.changed,
        '"$name" has changed on the server since you opened it. Nothing was '
        'written.',
        current: current,
      );
    }
  }

  final bytes = encodeEditorText(text, lineEndings);
  final temporaryPath = RemotePath.join(
    directory,
    (temporaryNamer ?? _editTemporaryName)(name),
  );

  final writer = await fs.openWrite(temporaryPath);
  // Up to the rename the temp file is ours, and every way out of here — a
  // failed write, a dropped connection, a server that will not verify the
  // size — takes it with us.
  var cleanUpTemporary = true;
  try {
    await writer.add(bytes);
    await writer.close();

    final landed = await fs.sizeOf(temporaryPath);
    if (landed != null && landed != bytes.length) {
      throw EditorSaveFailure(
        'The file did not land completely on the server, so "$name" was left '
        'exactly as it was.',
        details: 'wrote ${bytes.length} bytes, the server reports $landed',
      );
    }

    await _publish(fs, temporaryPath, path, name);
    // Renamed: the temp name no longer refers to anything.
    cleanUpTemporary = false;
  } on EditorSaveFailure catch (e) {
    // The one path that must not clean up: the original has already been
    // removed and the rename failed, so this temp file is the only copy of
    // what the user wrote. Deleting it here — which is what the cleanup
    // below would otherwise do — would turn a recoverable mess into a lost
    // afternoon, and the message we are about to show names this exact path.
    if (e.strandedTemporaryPath != null) cleanUpTemporary = false;
    rethrow;
  } finally {
    if (cleanUpTemporary) await writer.abort();
  }

  var restored = false;
  var lost = false;
  if (permissions != null && metadata != null) {
    final after = await metadata.statFile(path);
    if (after?.permissions != null && after!.permissions != permissions) {
      // The rename carried the temp file's mode, not the original's — so a
      // 0755 script has just become 0644 and will no longer run. Putting it
      // back is not optional.
      final ok = await metadata.setPermissions(path, permissions);
      restored = ok;
      lost = !ok;
    }
  }

  final settled = await _currentFingerprint(fs, metadata, path);
  return SaveOutcome(
    bytesWritten: bytes.length,
    fingerprint: settled ??
        RemoteFingerprint(size: bytes.length, modified: DateTime.now()),
    permissionsRestored: restored,
    permissionsLost: lost,
  );
}

/// Step 4. Returns normally once the temp is safely under the final name.
Future<void> _publish(
  RemoteFileSystem fs,
  String temporaryPath,
  String path,
  String name,
) async {
  try {
    await fs.rename(temporaryPath, path);
    return;
  } catch (_) {
    // Fall through: this server will not rename onto a name that exists.
  }

  // The only destructive step in the whole sequence, and it happens only
  // after the replacement has been written *and* size-checked, so the window
  // where the file does not exist is one round trip wide and the contents
  // that would fill it are already on the server.
  try {
    await fs.remove(path);
  } catch (e) {
    throw EditorSaveFailure(
      'The server would not let "$name" be replaced, so it was left exactly '
      'as it was.',
      details: e.toString(),
    );
  }

  try {
    await fs.rename(temporaryPath, path);
  } catch (e) {
    throw EditorSaveFailure(
      'The server removed the old "$name" but would not put the new one in '
      'its place. Everything you wrote is in "$temporaryPath" — rename it '
      'back from the file browser.',
      details: e.toString(),
      originalIntact: false,
      strandedTemporaryPath: temporaryPath,
    );
  }
}

/// The file as the server has it now, or null when it is not there.
Future<RemoteFingerprint?> _currentFingerprint(
  RemoteFileSystem fs,
  RemoteFileMetadata? metadata,
  String path,
) async {
  if (metadata != null) {
    final stat = await metadata.statFile(path);
    if (stat == null) return null;
    return RemoteFingerprint(size: stat.size, modified: stat.modified);
  }
  // No metadata seam: size is all there is, and `sizeOf` cannot tell
  // "missing" from "the server declined to say". `exists` settles that.
  if (!await fs.exists(path)) return null;
  return RemoteFingerprint(size: await fs.sizeOf(path));
}

/// `nginx.conf` → `.nginx.conf.ssg-edit-1738000000000`.
///
/// Hidden and app-stamped, exactly like `remote_copy.dart`'s `.ssg-part-`
/// names and for the same reasons: it does not clutter a directory somebody
/// is looking at mid-save, and anything left behind by a process that died
/// is identifiable rather than mysterious. A different marker from the
/// transfer path so the two are told apart in a `ls -a` after a crash.
String _editTemporaryName(String finalName) {
  final stamp = DateTime.now().millisecondsSinceEpoch;
  final suffix = '.ssg-edit-$stamp';
  // POSIX allows 255 bytes per name; leave room for the marker rather than
  // letting the server reject the open.
  final head = finalName.length > 200 ? finalName.substring(0, 200) : finalName;
  return '.$head$suffix';
}
