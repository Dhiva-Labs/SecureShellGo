import '../models/remote_entry.dart';
import 'remote_path.dart';
import 'sftp_service.dart';
import 'upload_plan.dart';

/// What a batch of entries will be called on the destination server, and what
/// is being left out.
///
/// A thin wrapper around [UploadPlan] on purpose. "These names are about to be
/// created in that directory; which of them collide, and what should happen to
/// each" is exactly the question the upload side already answers — including
/// apply-to-all, keep-both through [RemotePath.deduplicate], and a dismissed
/// prompt cancelling rather than overwriting. A server-to-server copy differs
/// only in where the bytes come from, which is not something the naming
/// decision has any opinion about, so it reuses that decision whole rather
/// than growing a second one that drifts.
///
/// Directories and files share one plan: a folder called `notes` and a file
/// called `notes` cannot both live in the same directory on POSIX, so the
/// collision universe is a single set. Each [PlannedUpload] in [names] carries
/// a [PlannedUpload.sourceIndex] into [entries], and the caller reads the
/// entry's [RemoteEntry.kind] to decide whether the transfer queue sees a
/// file copy or a recursive folder copy — the naming decision does not care.
class RemoteTransferPlan {
  const RemoteTransferPlan({
    required this.entries,
    required this.names,
    required this.unsupported,
  });

  static const RemoteTransferPlan cancelledPlan = RemoteTransferPlan(
    entries: <RemoteEntry>[],
    names: UploadPlan.cancelledPlan,
    unsupported: <String>[],
  );

  /// The entries the plan is about — files and directories in one list.
  /// [PlannedUpload.sourceIndex] indexes into this list, not into whatever the
  /// user originally selected.
  final List<RemoteEntry> entries;

  /// The naming decision, straight from [resolveUploadPlan] — one decision for
  /// files and directories together, since a name is a name in a POSIX
  /// listing.
  final UploadPlan names;

  /// Selected entries that are not files or directories: symlinks and any
  /// other kind. Symlinks are deliberately not chased across servers — a link
  /// to a directory can loop back into its own tree, and a link to a file
  /// would duplicate bytes at the destination under two names — so they are
  /// named for the snackbar and left alone.
  final List<String> unsupported;

  bool get cancelled => names.cancelled;

  List<PlannedUpload> get transfers => names.uploads;

  List<String> get skipped => names.skipped;

  bool get isEmpty => names.uploads.isEmpty;

  /// The entry a planned transfer refers to. A convenience for callers that
  /// otherwise write `plan.entries[transfer.sourceIndex]` on every line.
  RemoteEntry entryFor(PlannedUpload transfer) => entries[transfer.sourceIndex];
}

/// Decides what a batch of [entries] should be called in [destinationDirectory]
/// on [destination], asking the user only about the names that collide.
///
/// Directories are first-class here — a folder called `Documents` colliding
/// with an existing `Documents` on the far side goes through the same prompt
/// a file collision does, and the caller's choice (replace / keep both / skip)
/// cascades down the whole folder-transfer at execution time. Symlinks and
/// anything else are filtered into [RemoteTransferPlan.unsupported] and left
/// alone.
Future<RemoteTransferPlan> planRemoteTransfer({
  required List<RemoteEntry> entries,
  required RemoteFileSystem destination,
  required String destinationDirectory,
  required UploadCollisionPrompt ask,
}) async {
  final selected = <RemoteEntry>[];
  final unsupported = <String>[];
  for (final entry in entries) {
    if (entry.kind == RemoteEntryKind.file ||
        entry.kind == RemoteEntryKind.directory) {
      selected.add(entry);
    } else {
      unsupported.add(entry.name);
    }
  }

  if (selected.isEmpty) {
    return RemoteTransferPlan(
      entries: const [],
      names: const UploadPlan(
        uploads: <PlannedUpload>[],
        skipped: <String>[],
        cancelled: false,
      ),
      unsupported: unsupported,
    );
  }

  final wanted = selected.map((e) => e.name).toList(growable: false);
  final existing = await remoteNamesIn(
    destination,
    destinationDirectory,
    wanted,
  );

  final names = await resolveUploadPlan(
    fileNames: wanted,
    existingNames: existing,
    ask: ask,
  );

  return RemoteTransferPlan(
    entries: selected,
    names: names,
    unsupported: unsupported,
  );
}

/// The names already in [directory], for a collision decision.
///
/// One listing rather than a `stat` per file, because "keep both" needs to know
/// what `name (1).ext` would hit as well. A directory that will not list —
/// writable but not readable is a real Unix permission — falls back to probing
/// exactly the [candidates] about to be created.
Future<Set<String>> remoteNamesIn(
  RemoteFileSystem fs,
  String directory,
  Iterable<String> candidates,
) async {
  try {
    final entries = await fs.list(directory);
    return entries.map((e) => e.name).toSet();
  } catch (_) {
    final names = <String>{};
    for (final candidate in candidates) {
      if (await fs.exists(RemotePath.join(directory, candidate))) {
        names.add(candidate);
      }
    }
    return names;
  }
}
