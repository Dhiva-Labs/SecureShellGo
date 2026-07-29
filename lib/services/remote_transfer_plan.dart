import '../models/remote_entry.dart';
import 'remote_path.dart';
import 'sftp_service.dart';
import 'upload_plan.dart';

/// What a batch of files will be called on the destination server, and what is
/// being left out.
///
/// A thin wrapper around [UploadPlan] on purpose. "These names are about to be
/// created in that directory; which of them collide, and what should happen to
/// each" is exactly the question the upload side already answers — including
/// apply-to-all, keep-both through [RemotePath.deduplicate], and a dismissed
/// prompt cancelling rather than overwriting. A server-to-server copy differs
/// only in where the bytes come from, which is not something the naming
/// decision has any opinion about, so it reuses that decision whole rather
/// than growing a second one that drifts.
class RemoteTransferPlan {
  const RemoteTransferPlan({
    required this.files,
    required this.names,
    required this.unsupported,
  });

  static const RemoteTransferPlan cancelledPlan = RemoteTransferPlan(
    files: <RemoteEntry>[],
    names: UploadPlan.cancelledPlan,
    unsupported: <String>[],
  );

  /// The entries the plan is about — [PlannedUpload.sourceIndex] indexes into
  /// this list, not into whatever the user originally selected.
  final List<RemoteEntry> files;

  /// The naming decision, straight from [resolveUploadPlan].
  final UploadPlan names;

  /// Selected entries that are not plain files: directories, symlinks and
  /// anything else. Recursive server-to-server copying is not implemented, so
  /// these are named and left alone rather than half-copied.
  final List<String> unsupported;

  bool get cancelled => names.cancelled;

  List<PlannedUpload> get transfers => names.uploads;

  List<String> get skipped => names.skipped;

  bool get isEmpty => names.uploads.isEmpty;
}

/// Decides what a batch of [entries] should be called in [destinationDirectory]
/// on [destination], asking the user only about the names that collide.
///
/// Directories and symlinks are filtered out first: a recursive copy needs
/// `mkdir` on the far side and a collision decision per directory as well as
/// per file, neither of which exists yet — see the note in ARCHITECTURE.md.
Future<RemoteTransferPlan> planRemoteTransfer({
  required List<RemoteEntry> entries,
  required RemoteFileSystem destination,
  required String destinationDirectory,
  required UploadCollisionPrompt ask,
}) async {
  final files = <RemoteEntry>[];
  final unsupported = <String>[];
  for (final entry in entries) {
    if (entry.kind == RemoteEntryKind.file) {
      files.add(entry);
    } else {
      unsupported.add(entry.name);
    }
  }

  if (files.isEmpty) {
    return RemoteTransferPlan(
      files: const [],
      names: const UploadPlan(
        uploads: <PlannedUpload>[],
        skipped: <String>[],
        cancelled: false,
      ),
      unsupported: unsupported,
    );
  }

  final wanted = files.map((e) => e.name).toList(growable: false);
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
    files: files,
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
