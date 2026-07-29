
import 'dart:io';

import 'package:file_selector/file_selector.dart' as file_selector;
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'remote_path.dart';

/// A file the user picked through the system document UI, staged into
/// app-private cache so it can be read with plain file I/O.
class PickedLocalFile {
  const PickedLocalFile({
    required this.path,
    required this.name,
    required this.size,
  });

  final String path;
  final String name;
  final int size;
}

/// A small file the user picked through the system document UI, read
/// straight into memory as text rather than staged to a path — see
/// [DeviceStorage.pickTextFile].
class PickedTextFile {
  const PickedTextFile({required this.name, required this.content});

  final String name;
  final String content;
}

/// Default cap for [DeviceStorage.pickTextFile]. Chosen for private-key
/// import (a key is at most a couple of KB); pass a different [maxBytes] for
/// other uses.
const int kDefaultPickedTextFileMaxBytes = 64 * 1024;

/// Reads the platform side's list of staged files — the payload behind both a
/// multi-file pick and an incoming share, which are the same thing seen from
/// two directions.
///
/// Deliberately forgiving: a share arrives from an arbitrary other app, and a
/// multi-select can include a document whose provider went away between the
/// pick and the read. One malformed entry costs that entry, not the batch.
List<PickedLocalFile> parseStagedFiles(Object? raw) {
  final Object? list = raw is Map ? raw['files'] : raw;
  if (list is! List) return const [];

  final files = <PickedLocalFile>[];
  for (final item in list) {
    if (item is! Map) continue;
    final path = item['path'];
    if (path is! String || path.isEmpty) continue;
    final rawName = item['name'];
    final name = rawName is String && rawName.trim().isNotEmpty
        ? rawName
        : _basename(path);
    final size = item['size'];
    files.add(
      PickedLocalFile(
        path: path,
        name: name,
        size: size is num ? size.toInt() : 0,
      ),
    );
  }
  return files;
}

String _basename(String path) {
  final index = path.lastIndexOf('/');
  if (index < 0 || index == path.length - 1) return path;
  return path.substring(index + 1);
}

/// Where a finished download ended up.
class SavedDownload {
  const SavedDownload({required this.displayName, this.uri});

  /// The name Android actually gave the file. Not necessarily the name that
  /// was asked for: MediaStore de-duplicates collisions itself.
  final String displayName;

  /// `content://` (API 29+) or `file://` (below) URI of the saved file.
  final String? uri;
}

/// An open download, written chunk by chunk.
abstract class DownloadWriter {
  /// Appends [chunk]. The returned future completes once the platform has
  /// actually written it, which is what keeps SFTP backpressure honest.
  Future<void> add(Uint8List chunk);

  /// Publishes the file and returns where it landed.
  Future<SavedDownload> finish();

  /// Discards the partial file. A cancelled download must not leave a
  /// truncated file in Downloads looking complete.
  Future<void> abort();
}

/// The device-side half of "scp": the shared Downloads collection, and the
/// system file picker.
abstract class DeviceStorage {
  /// Grants whatever is needed to write to Downloads. Always true on API 29+.
  Future<bool> ensurePermission();

  /// Whether a download by this name is already present in
  /// `Download/[relativeDirectory]`.
  Future<bool> downloadExists(String fileName, {String relativeDirectory});

  /// Opens a new download. When [overwrite] is false the platform
  /// de-duplicates and [SavedDownload.displayName] reports the real name.
  ///
  /// [relativeDirectory] nests the file under `Download/`, which is what
  /// keeps a recursive directory download's structure intact. It is sanitised
  /// again on the platform side — no `..`, no absolute paths — because every
  /// segment of it came from a remote listing.
  Future<DownloadWriter> beginDownload(
    String fileName, {
    String? mimeType,
    bool overwrite = false,
    String relativeDirectory = '',
  });

  /// Hands a finished download to whatever app can display it, through a
  /// chooser. False when nothing on the device can open it.
  Future<bool> openDownload(String uri, {String? mimeType});

  /// Opens the system document picker. Null if the user backed out.
  Future<PickedLocalFile?> pickFile();

  /// Opens the system document picker for any number of files, staging each
  /// one. Empty if the user backed out.
  Future<List<PickedLocalFile>> pickFiles();

  /// Opens the system document picker and reads the picked file's content
  /// directly into memory as text, instead of staging it to a path the way
  /// [pickFile] does for uploads — meant for something small enough to
  /// belong in a form field, such as an imported private key. Null if the
  /// user backed out. Throws [DeviceStorageException] if the file is larger
  /// than [maxBytes].
  Future<PickedTextFile?> pickTextFile({
    int maxBytes = kDefaultPickedTextFileMaxBytes,
  });
}

/// Raised when the platform side refuses. Carries a message fit for a snackbar.
class DeviceStorageException implements Exception {
  const DeviceStorageException(this.message, {this.details});

  final String message;
  final String? details;

  @override
  String toString() => message;
}

/// The right [DeviceStorage] for the platform this build is running on.
///
/// Android keeps talking to `StorageBridge.kt` over
/// [MethodChannelDeviceStorage]. Linux, Windows and macOS have no such
/// channel — there is no Kotlin side listening on it — so this hands back
/// [DesktopDeviceStorage] instead, which writes straight into the real
/// filesystem: the desktop equivalent of scoped storage's "no permission
/// needed, no destination picker for a download" on Android 29+.
DeviceStorage createDefaultDeviceStorage() {
  if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
    return DesktopDeviceStorage();
  }
  return const MethodChannelDeviceStorage();
}

/// Talks to `StorageBridge.kt` over a method channel.
///
/// See that file for why this is a hand-rolled channel rather than a plugin.
class MethodChannelDeviceStorage implements DeviceStorage {
  const MethodChannelDeviceStorage();

  static const MethodChannel channel =
      MethodChannel('com.dhivalabs.secure_shell_go/storage');

  @override
  Future<bool> ensurePermission() async {
    try {
      return await channel.invokeMethod<bool>('ensurePermission') ?? false;
    } on PlatformException catch (e) {
      throw DeviceStorageException(
        'Could not get permission to save downloads.',
        details: e.message,
      );
    } on MissingPluginException {
      // Desktop/test runs: nothing to grant.
      return false;
    }
  }

  @override
  Future<bool> downloadExists(
    String fileName, {
    String relativeDirectory = '',
  }) async {
    try {
      return await channel.invokeMethod<bool>(
            'downloadExists',
            <String, dynamic>{
              'fileName': fileName,
              'relativePath': relativeDirectory,
            },
          ) ??
          false;
    } on PlatformException {
      // Not being able to tell just means we skip the overwrite prompt and
      // let the platform de-duplicate.
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<DownloadWriter> beginDownload(
    String fileName, {
    String? mimeType,
    bool overwrite = false,
    String relativeDirectory = '',
  }) async {
    try {
      final result = await channel.invokeMapMethod<String, dynamic>(
        'beginDownload',
        <String, dynamic>{
          'fileName': fileName,
          'mimeType': mimeType,
          'overwrite': overwrite,
          'relativePath': relativeDirectory,
        },
      );
      final id = result?['id'] as int?;
      if (id == null) {
        throw const DeviceStorageException('Could not open the file to save.');
      }
      return _ChannelDownloadWriter(id, result?['displayName'] as String? ?? fileName);
    } on PlatformException catch (e) {
      throw DeviceStorageException(
        'Could not save to Downloads.',
        details: e.message,
      );
    } on MissingPluginException {
      throw const DeviceStorageException(
        'Saving files is only available on the Android build.',
      );
    }
  }

  @override
  Future<bool> openDownload(String uri, {String? mimeType}) async {
    try {
      return await channel.invokeMethod<bool>(
            'openDownload',
            <String, dynamic>{'uri': uri, 'mimeType': mimeType},
          ) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<PickedLocalFile?> pickFile() async {
    try {
      final result =
          await channel.invokeMapMethod<String, dynamic>('pickFile');
      if (result == null) return null;
      return PickedLocalFile(
        path: result['path'] as String,
        name: result['name'] as String? ?? 'upload',
        size: (result['size'] as num?)?.toInt() ?? 0,
      );
    } on PlatformException catch (e) {
      throw DeviceStorageException(
        'Could not open the file picker.',
        details: e.message,
      );
    } on MissingPluginException {
      throw const DeviceStorageException(
        'Picking files is only available on the Android build.',
      );
    }
  }

  @override
  Future<List<PickedLocalFile>> pickFiles() async {
    try {
      final result = await channel.invokeMethod<Object?>('pickFiles');
      return parseStagedFiles(result);
    } on PlatformException catch (e) {
      throw DeviceStorageException(
        'Could not open the file picker.',
        details: e.message,
      );
    } on MissingPluginException {
      throw const DeviceStorageException(
        'Picking files is only available on the Android build.',
      );
    }
  }

  @override
  Future<PickedTextFile?> pickTextFile({
    int maxBytes = kDefaultPickedTextFileMaxBytes,
  }) async {
    try {
      final result = await channel.invokeMapMethod<String, dynamic>(
        'pickFileContent',
        <String, dynamic>{'maxBytes': maxBytes},
      );
      if (result == null) return null;
      return PickedTextFile(
        name: result['name'] as String? ?? 'key',
        content: result['content'] as String? ?? '',
      );
    } on PlatformException catch (e) {
      if (e.code == 'too_large') {
        throw DeviceStorageException(
          e.message ?? 'That file is too large to be a private key.',
        );
      }
      throw DeviceStorageException(
        'Could not open the file picker.',
        details: e.message,
      );
    } on MissingPluginException {
      throw const DeviceStorageException(
        'Picking files is only available on the Android build.',
      );
    }
  }
}

class _ChannelDownloadWriter implements DownloadWriter {
  _ChannelDownloadWriter(this._id, this._displayName);

  final int _id;
  final String _displayName;
  var _closed = false;

  @override
  Future<void> add(Uint8List chunk) async {
    if (_closed) return;
    try {
      await MethodChannelDeviceStorage.channel.invokeMethod<void>(
        'writeChunk',
        <String, dynamic>{'id': _id, 'bytes': chunk},
      );
    } on PlatformException catch (e) {
      throw DeviceStorageException(
        'Writing to Downloads failed. The device may be out of space.',
        details: e.message,
      );
    }
  }

  @override
  Future<SavedDownload> finish() async {
    if (_closed) return SavedDownload(displayName: _displayName);
    _closed = true;
    try {
      final result = await MethodChannelDeviceStorage.channel
          .invokeMapMethod<String, dynamic>(
        'finishDownload',
        <String, dynamic>{'id': _id},
      );
      return SavedDownload(
        displayName: result?['displayName'] as String? ?? _displayName,
        uri: result?['uri'] as String?,
      );
    } on PlatformException catch (e) {
      throw DeviceStorageException(
        'Could not finish saving the download.',
        details: e.message,
      );
    }
  }

  @override
  Future<void> abort() async {
    if (_closed) return;
    _closed = true;
    try {
      await MethodChannelDeviceStorage.channel.invokeMethod<void>(
        'abortDownload',
        <String, dynamic>{'id': _id},
      );
    } catch (_) {
      // Already cleaning up after a failure; nothing useful to add.
    }
  }
}

/// Desktop implementation of [DeviceStorage].
///
/// Downloads go straight into the user's real Downloads folder
/// (`path_provider`'s `getDownloadsDirectory()`) with plain `dart:io` file
/// writes — there is no scoped-storage layer to ask, so this *is* the
/// desktop equivalent of MediaStore. Uploads and the private-key file picker
/// go through the system file picker via `file_selector`: a genuine plugin
/// rather than hand-rolled platform code, which for this one case is the
/// right side of the trade `StorageBridge.kt`'s doc argues for elsewhere in
/// this project — a native Open dialog would otherwise need writing three
/// times over (GTK, IFileDialog, NSOpenPanel) for something the Flutter team
/// already maintains.
///
/// There is no permission step ([ensurePermission] is a no-op returning
/// true — nothing to grant) and no MediaStore-style de-duplication service
/// to ask, so a same-name collision is decided here with the same
/// [RemotePath.deduplicate] the Android/MediaStore path already uses, and
/// reported back the same way: through [SavedDownload.displayName].
class DesktopDeviceStorage implements DeviceStorage {
  /// [downloadsDirectoryResolver] overrides where downloads are written;
  /// tests use a temp directory so they do not need the path_provider
  /// plugin (which needs a platform channel and does not run under plain
  /// `flutter test`) — the same reason `HostStore`/`SettingsStore` take an
  /// injectable `File` instead of resolving one themselves.
  DesktopDeviceStorage({
    Future<Directory?> Function()? downloadsDirectoryResolver,
  }) : _downloadsDirectoryResolver =
            downloadsDirectoryResolver ?? getDownloadsDirectory;

  final Future<Directory?> Function() _downloadsDirectoryResolver;

  @override
  Future<bool> ensurePermission() async => true;

  @override
  Future<bool> downloadExists(
    String fileName, {
    String relativeDirectory = '',
  }) async {
    final file = await _targetFile(fileName, relativeDirectory);
    return file.exists();
  }

  @override
  Future<DownloadWriter> beginDownload(
    String fileName, {
    String? mimeType,
    bool overwrite = false,
    String relativeDirectory = '',
  }) async {
    final Directory dir;
    try {
      dir = await _resolveDirectory(relativeDirectory);
      await dir.create(recursive: true);
    } on FileSystemException catch (e) {
      throw DeviceStorageException(
        'Could not create the Downloads folder.',
        details: e.message,
      );
    }

    final safeName = RemotePath.sanitiseFileName(fileName);
    final displayName = overwrite
        ? safeName
        : RemotePath.deduplicate(
            safeName,
            (candidate) => File('${dir.path}/$candidate').existsSync(),
          );

    final file = File('${dir.path}/$displayName');
    try {
      final raf = await file.open(mode: FileMode.write);
      return _FileDownloadWriter(
        file: file,
        raf: raf,
        displayName: displayName,
      );
    } on FileSystemException catch (e) {
      throw DeviceStorageException(
        'Could not save to Downloads.',
        details: e.message,
      );
    }
  }

  @override
  Future<bool> openDownload(String uri, {String? mimeType}) async {
    final path = filePathFromUri(uri);
    if (path == null) return false;
    try {
      final ProcessResult result;
      if (Platform.isLinux) {
        result = await Process.run('xdg-open', <String>[path]);
      } else if (Platform.isMacOS) {
        result = await Process.run('open', <String>[path]);
      } else if (Platform.isWindows) {
        // Empty title argument: `start`'s first quoted argument is a window
        // title, not the target, when more than one argument follows it.
        result = await Process.run(
          'cmd',
          <String>['/c', 'start', '', path],
        );
      } else {
        return false;
      }
      return result.exitCode == 0;
    } on ProcessException {
      return false;
    }
  }

  @override
  Future<PickedLocalFile?> pickFile() async {
    final picked = await file_selector.openFile();
    if (picked == null) return null;
    return _toPickedLocalFile(picked);
  }

  @override
  Future<List<PickedLocalFile>> pickFiles() async {
    final picked = await file_selector.openFiles();
    final files = <PickedLocalFile>[];
    for (final file in picked) {
      files.add(await _toPickedLocalFile(file));
    }
    return files;
  }

  @override
  Future<PickedTextFile?> pickTextFile({
    int maxBytes = kDefaultPickedTextFileMaxBytes,
  }) async {
    final picked = await file_selector.openFile();
    if (picked == null) return null;

    final size = await picked.length();
    if (size > maxBytes) {
      throw const DeviceStorageException(
        'That file is too large to be a private key.',
      );
    }
    final content = await picked.readAsString();
    return PickedTextFile(name: picked.name, content: content);
  }

  Future<PickedLocalFile> _toPickedLocalFile(file_selector.XFile file) async {
    var size = 0;
    try {
      size = await file.length();
    } catch (_) {
      // Only used for progress display on the upload path; a file whose
      // length cannot be reported still uploads, just without a percentage.
    }
    return PickedLocalFile(path: file.path, name: file.name, size: size);
  }

  Future<Directory> _resolveDirectory(String relativeDirectory) async {
    final downloads = await _downloadsDirectoryResolver();
    if (downloads == null) {
      throw const DeviceStorageException(
        'Could not find a Downloads folder on this system.',
      );
    }
    final safeRelative =
        RemotePath.sanitiseRelativeDirectory(relativeDirectory);
    if (safeRelative.isEmpty) return downloads;
    return Directory('${downloads.path}/$safeRelative');
  }

  Future<File> _targetFile(String fileName, String relativeDirectory) async {
    final dir = await _resolveDirectory(relativeDirectory);
    return File('${dir.path}/${RemotePath.sanitiseFileName(fileName)}');
  }
}

/// `file://...` → a plain filesystem path; anything else (an unrecognised or
/// missing scheme) → null, since [DesktopDeviceStorage.openDownload] has
/// nothing sensible to hand to `xdg-open`/`open`/`start` in that case.
String? filePathFromUri(String uri) {
  final parsed = Uri.tryParse(uri);
  if (parsed == null) return null;
  if (parsed.scheme == 'file') return parsed.toFilePath();
  return null;
}

/// Writes a download straight to disk with `dart:io`.
///
/// Uses a [RandomAccessFile] rather than [File.openWrite]'s [IOSink] so that
/// [add] can `await` each chunk's actual write — an [IOSink] would instead
/// buffer internally and return immediately, which would let a fast SFTP
/// stream race ahead of a slow disk and hold the whole file in memory. That
/// awaited backpressure is the same reason `StorageBridge.kt` awaits every
/// MediaStore chunk write on the Android side of this interface.
class _FileDownloadWriter implements DownloadWriter {
  _FileDownloadWriter({
    required this.file,
    required RandomAccessFile this._raf,
    required this.displayName,
  });

  final File file;
  final String displayName;
  RandomAccessFile? _raf;
  var _closed = false;

  @override
  Future<void> add(Uint8List chunk) async {
    if (_closed) return;
    final raf = _raf;
    if (raf == null) return;
    try {
      _raf = await raf.writeFrom(chunk);
    } on FileSystemException catch (e) {
      throw DeviceStorageException(
        'Writing to Downloads failed. The device may be out of space.',
        details: e.message,
      );
    }
  }

  @override
  Future<SavedDownload> finish() async {
    if (_closed) return SavedDownload(displayName: displayName);
    _closed = true;
    final raf = _raf;
    _raf = null;
    try {
      await raf?.close();
    } on FileSystemException {
      // Nothing left to do if the close itself fails; the file is as
      // complete as it is ever going to get.
    }
    return SavedDownload(displayName: displayName, uri: file.uri.toString());
  }

  @override
  Future<void> abort() async {
    if (_closed) return;
    _closed = true;
    final raf = _raf;
    _raf = null;
    try {
      await raf?.close();
    } catch (_) {
      // Already cleaning up after a failure; nothing useful to add below.
    }
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Best-effort: a cancelled download must not look complete, but if
      // even the delete fails there is nothing more this can do.
    }
  }
}
