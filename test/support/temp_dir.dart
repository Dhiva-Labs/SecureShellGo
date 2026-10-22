import 'dart:io';

/// Deletes a test's temporary directory.
///
/// A store saves without being awaited, so its write can still have a file
/// open as the test ends. Linux deletes it anyway; Windows refuses ("being
/// used by another process"), which failed tests that had passed. This
/// retries for up to a second, then leaves the directory for the system's
/// temp cleanup rather than fail over it.
Future<void> deleteTempDir(Directory dir) async {
  for (var attempt = 0;; attempt++) {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
      return;
    } on FileSystemException {
      if (attempt >= 20) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
}
