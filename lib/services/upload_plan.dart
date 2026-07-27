import 'remote_path.dart';

/// What to do about one upload whose name is already taken on the server.
enum UploadCollisionAction {
  /// Replace what is already there.
  overwrite,

  /// Upload alongside it, under `name (1).ext`.
  keepBoth,

  /// Leave the server's copy alone and do not upload this file.
  skip,
}

/// One answer from the user, and whether it stands in for the rest of the
/// batch instead of the next collision asking again.
class UploadCollisionResponse {
  const UploadCollisionResponse(this.action, {this.applyToAll = false});

  final UploadCollisionAction action;
  final bool applyToAll;
}

/// Asks the user about one collision.
///
/// Returning null cancels the whole batch: a dismissed dialog must never be
/// read as consent to overwrite someone's file on a server.
typedef UploadCollisionPrompt = Future<UploadCollisionResponse?> Function(
  String fileName, {
  required bool offerApplyToAll,
});

/// One resolved upload: which picked file it is, what to call it on the
/// server, and whether an existing file of that name is being replaced.
class PlannedUpload {
  const PlannedUpload({
    required this.sourceIndex,
    required this.remoteName,
    required this.overwrite,
  });

  /// Index into the name list handed to [resolveUploadPlan] — an index rather
  /// than the name itself, because two picked files can carry the same name
  /// (two `photo.jpg` from two folders is the ordinary case, not the exotic
  /// one).
  final int sourceIndex;

  /// The name to create on the server. Equal to the source name unless the
  /// user chose "keep both".
  final String remoteName;

  /// True only where the user explicitly chose to replace.
  final bool overwrite;
}

/// The outcome of resolving a batch of uploads against a directory listing.
class UploadPlan {
  const UploadPlan({
    required this.uploads,
    required this.skipped,
    required this.cancelled,
  });

  /// Empty and cancelled — the user backed out of a collision prompt.
  static const UploadPlan cancelledPlan = UploadPlan(
    uploads: <PlannedUpload>[],
    skipped: <String>[],
    cancelled: true,
  );

  final List<PlannedUpload> uploads;

  /// Names the user chose to skip, for the "3 uploaded, 1 skipped" summary.
  final List<String> skipped;

  /// True when the user dismissed a prompt: nothing in [uploads] should run.
  final bool cancelled;

  bool get isEmpty => uploads.isEmpty;
}

/// Decides what each file in a batch should be called on the server, asking
/// the user only about the names that actually collide.
///
/// [existingNames] is the directory's current contents (one listing, not one
/// `stat` per file), which is what lets "keep both" run through the same
/// [RemotePath.deduplicate] the download side uses instead of a second,
/// subtly different implementation. Names claimed earlier in the same batch
/// join that set as they are assigned, so uploading two files called
/// `notes.md` cannot silently collapse into one.
Future<UploadPlan> resolveUploadPlan({
  required List<String> fileNames,
  required Set<String> existingNames,
  required UploadCollisionPrompt ask,
}) async {
  final taken = <String>{...existingNames};
  final uploads = <PlannedUpload>[];
  final skipped = <String>[];

  // Set once the user ticks "do this for the rest", so later collisions in
  // the same batch stop asking.
  UploadCollisionAction? sticky;

  for (var i = 0; i < fileNames.length; i++) {
    final name = fileNames[i];

    if (!taken.contains(name)) {
      taken.add(name);
      uploads.add(
        PlannedUpload(sourceIndex: i, remoteName: name, overwrite: false),
      );
      continue;
    }

    var action = sticky;
    if (action == null) {
      final response = await ask(
        name,
        offerApplyToAll: fileNames.length > 1,
      );
      if (response == null) return UploadPlan.cancelledPlan;
      action = response.action;
      if (response.applyToAll) sticky = action;
    }

    switch (action) {
      case UploadCollisionAction.overwrite:
        // The name stays claimed: a second file of the same name later in the
        // batch is a fresh collision, not a licence to overwrite twice.
        uploads.add(
          PlannedUpload(sourceIndex: i, remoteName: name, overwrite: true),
        );
      case UploadCollisionAction.keepBoth:
        final unique = RemotePath.deduplicate(name, taken.contains);
        taken.add(unique);
        uploads.add(
          PlannedUpload(sourceIndex: i, remoteName: unique, overwrite: false),
        );
      case UploadCollisionAction.skip:
        skipped.add(name);
    }
  }

  return UploadPlan(uploads: uploads, skipped: skipped, cancelled: false);
}
