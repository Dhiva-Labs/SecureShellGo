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
Future<void> atomicWrite(
  File file,
  Future<void> Function(File temp) write,
) async {
  final temp = File('${file.path}.tmp');
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
