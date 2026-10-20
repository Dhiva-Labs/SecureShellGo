import 'dart:io';

/// Puts a file in place atomically: [write] fills a temp file beside [file],
/// which is then renamed over it.
///
/// A crash or a full disk halfway through therefore loses the *new* contents
/// rather than the ones already on disk — the failure mode that matters for
/// the two files this app keeps no second copy of, the credential vault and
/// the device key that opens it. The temp file is cleared away on failure
/// rather than left as debris.
///
/// [write] receives the temp file rather than the bytes to put in it because
/// one caller has to `chmod` it between creating it and filling it — see
/// `DeviceVaultKey.create`, where the whole point is that the secret is never
/// on disk at the umask's default mode, not even briefly.
///
/// The temp name is unique per call, so two writes to one file can never
/// fill the same temp; use a [SerialFileWriter] as well so they also land
/// in the order they were asked for.
Future<void> atomicWrite(
  File file,
  Future<void> Function(File temp) write,
) async {
  final temp = File(
    debugAtomicTempPath?.call(file) ??
        '${file.path}.${DateTime.now().microsecondsSinceEpoch}-'
            '${_tempSequence++}.tmp',
  );
  try {
    await write(temp);
    await temp.rename(file.path);
  } catch (_) {
    // The rename never happened, so whatever was there is untouched. Clear
    // the debris if we can and let the caller see the failure.
    try {
      if (await temp.exists()) await temp.delete();
    } catch (_) {
      // Nothing further to try; the file itself is what matters.
    }
    rethrow;
  }
}

var _tempSequence = 0;

/// Test seam: when set, names [atomicWrite]'s temp file for [target] in
/// place of the unique per-call name, so a test can put something in its
/// way and watch the write fail before the rename. Never set in the app.
String Function(File target)? debugAtomicTempPath;

/// Runs one file's writes one at a time, in the order they were asked for.
///
/// Each store rewrites its whole file from memory. Two saves in flight at
/// once — an edit while the unawaited "last connected" stamp from a connect
/// is still writing — could otherwise finish out of order and leave the
/// *older* snapshot on disk, silently undoing the newer change. Queued, each
/// write snapshots memory when its turn comes, so the last one to land is
/// always the latest state.
class SerialFileWriter {
  Future<void> _tail = Future<void>.value();

  /// Queues [write] behind every write already queued. A failed write is
  /// reported to its own caller and does not stop the ones behind it.
  Future<void> run(Future<void> Function() write) {
    final next = _tail.then((_) => write());
    _tail = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }
}

/// Moves a store file that exists but could not be read out of the way, to
/// `<name>.corrupt-<timestamp>` beside it.
///
/// A store that fails to load starts empty, and its next save rewrites the
/// file from that empty start. Without this, whatever was in the unreadable
/// file — every saved host, say — was overwritten by that save; with it, the
/// bytes survive for someone to recover by hand. Best effort throughout: a
/// failure here must not turn a bad load into a crash.
Future<void> setAsideUnreadable(File? file) async {
  if (file == null) return;
  try {
    if (!await file.exists()) return;
    final stamp = DateTime.now()
        .toUtc()
        .toIso8601String()
        .replaceAll(RegExp(r'[^0-9T]'), '');
    await file.rename('${file.path}.corrupt-$stamp');
  } catch (_) {
    // Nothing further to try.
  }
}
