
import 'package:flutter/services.dart';

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
