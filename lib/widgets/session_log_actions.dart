import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart' as file_selector;
import 'package:flutter/material.dart';

import '../services/device_storage.dart';
import '../services/session_controller.dart';
import '../services/session_recorder.dart';

/// Where a session log is written, which differs by platform in when the
/// user is asked.
///
/// A desktop asks first, with the native save dialog, and the log streams
/// into that file for as long as it runs. Android's "save as" only takes a
/// finished file, so the log is kept in memory and the system picker comes up
/// when recording stops.
abstract class SessionLogDestination {
  /// The right one for this platform.
  factory SessionLogDestination.forPlatform() {
    if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      return FileLogDestination();
    }
    final storage = createDefaultDeviceStorage();
    return DocumentLogDestination(
      storage is DocumentSaver ? storage as DocumentSaver : null,
    );
  }

  /// Whether [open] asks where to save, so the start dialog can say so.
  bool get choosesFileFirst;

  /// The most an in-memory log may grow to, or null for no limit.
  int? get maxBytes;

  /// Somewhere to record into, or null when the user backed out.
  Future<SessionLogSink?> open(String suggestedName);

  /// Saves a finished log. Returns what to call it in a message, or null
  /// when the user backed out of choosing where. Throws
  /// [DeviceStorageException] or [FileSystemException] when it could not be
  /// written.
  Future<String?> save(SessionLogSink sink, String suggestedName);
}

/// The desktop's: a file chosen in the native save dialog, written as the
/// session runs.
class FileLogDestination implements SessionLogDestination {
  FileLogDestination({Future<String?> Function(String suggestedName)? choose})
      : _choose = choose ?? _nativeSaveDialog;

  final Future<String?> Function(String suggestedName) _choose;

  static Future<String?> _nativeSaveDialog(String suggestedName) async {
    final location = await file_selector.getSaveLocation(
      suggestedName: suggestedName,
      confirmButtonText: 'Record',
      canCreateDirectories: true,
      acceptedTypeGroups: const [
        file_selector.XTypeGroup(label: 'Logs', extensions: ['log', 'txt']),
      ],
    );
    return location?.path;
  }

  @override
  bool get choosesFileFirst => true;

  @override
  int? get maxBytes => null;

  @override
  Future<SessionLogSink?> open(String suggestedName) async {
    final path = await _choose(suggestedName);
    if (path == null || path.isEmpty) return null;
    // GTK's dialog does not add an extension the user left off.
    final named = path.split(Platform.pathSeparator).last.contains('.')
        ? path
        : '$path.log';
    return FileLogSink(File(named));
  }

  @override
  Future<String?> save(SessionLogSink sink, String suggestedName) async =>
      sink is FileLogSink
          ? sink.file.path.split(Platform.pathSeparator).last
          : suggestedName;
}

/// Android's: kept in memory, then handed to the system "save as" picker —
/// any folder, an SD card, Drive or another document provider.
class DocumentLogDestination implements SessionLogDestination {
  DocumentLogDestination(this.saver);

  /// Null when the storage has no "save as", which only a test build lacks.
  final DocumentSaver? saver;

  /// Comfortably under what the picker's bridge accepts in one go (64 MB),
  /// and as much text as anyone reads back: about 400,000 lines.
  static const int limit = 32 * 1024 * 1024;

  @override
  bool get choosesFileFirst => false;

  @override
  int? get maxBytes => limit;

  @override
  Future<SessionLogSink?> open(String suggestedName) async => MemoryLogSink();

  @override
  Future<String?> save(SessionLogSink sink, String suggestedName) async {
    final saver = this.saver;
    if (saver == null) {
      throw const DeviceStorageException(
        'Choosing where to save is not available here.',
      );
    }
    if (sink is! MemoryLogSink) return suggestedName;
    final saved = await saver.saveDocument(
      suggestedName: suggestedName,
      bytes: sink.takeBytes(),
      mimeType: 'text/plain',
    );
    return saved?.displayName;
  }
}

/// What a running log needs at the end, beside the recorder itself.
class _RunningLog {
  _RunningLog(this.destination, this.sink, this.fileName);

  final SessionLogDestination destination;
  final SessionLogSink sink;
  final String fileName;
}

/// "Record session log…" and "Stop recording" in the session menu, and what
/// the terminal does when a recording stops by itself.
class SessionLogActions {
  const SessionLogActions._();

  /// Replaces [SessionLogDestination.forPlatform] in tests.
  @visibleForTesting
  static SessionLogDestination? debugDestination;

  static final Expando<_RunningLog> _running = Expando();

  static bool isRecording(SessionController session) =>
      session.terminal.isRecording;

  /// Asks how to record, and where on a desktop, then starts.
  static Future<void> start(
    BuildContext context,
    SessionController session,
  ) async {
    final terminal = session.terminal;
    if (terminal.isRecording) return;
    final destination =
        debugDestination ?? SessionLogDestination.forPlatform();
    final plainText = await _askHow(context, destination);
    if (plainText == null || !context.mounted) return;

    final now = DateTime.now();
    final fileName = sessionLogFileName(session.host.displayName, now);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final SessionLogSink? sink;
    try {
      sink = await destination.open(fileName);
    } on Exception catch (e) {
      _tell(messenger, 
        SnackBar(content: Text('Could not start the session log: $e')),
      );
      return;
    }
    if (sink == null || terminal.isRecording) return;

    final recorder = SessionRecorder(
      sink: sink,
      plainText: plainText,
      maxBytes: destination.maxBytes,
      header: 'Session log for ${session.host.target}, started '
          '${sessionLogTimestamp(now)}',
    );
    _running[recorder] = _RunningLog(destination, sink, fileName);
    terminal.startRecording(recorder);
    _tell(messenger, 
      SnackBar(
        content: Text(
          destination.choosesFileFirst
              ? 'Recording this session to ${sink is FileLogSink ? sink.file.path.split(Platform.pathSeparator).last : fileName}'
              : 'Recording this session. Stop to choose where to save it.',
        ),
      ),
    );
  }

  /// Stops the recording and saves it — on Android, through the picker.
  /// Returns false only when the user backed out of saving.
  static Future<bool> stop(
    BuildContext context,
    SessionController session,
  ) async {
    final recorder = session.terminal.stopRecording();
    if (recorder == null) return true;
    return _finish(context, recorder);
  }

  /// A recording that stopped itself: full, or its file could not be
  /// written. Says so, and offers to save what there is.
  static Future<void> stoppedBySelf(
    BuildContext context,
    SessionRecorder recorder,
  ) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final log = _running[recorder];
    if (log == null) return;
    if (recorder.stoppedBy == RecordingStop.failed) {
      _running[recorder] = null;
      try {
        await recorder.finish();
      } catch (_) {
        // Already failing; the message below is what matters.
      }
      _tell(messenger, 
        SnackBar(
          content: Text(
            'The session log stopped: it could not be written '
            '(${recorder.failure}).',
          ),
        ),
      );
      return;
    }
    if (!context.mounted) return;
    await _finish(
      context,
      recorder,
      reason: 'The session log is full, so recording stopped.',
    );
  }

  static Future<bool> _finish(
    BuildContext context,
    SessionRecorder recorder, {
    String? reason,
  }) async {
    final log = _running[recorder];
    _running[recorder] = null;
    if (log == null) return true;
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await recorder.finish(
        footer: 'Session log ended ${sessionLogTimestamp(DateTime.now())}',
      );
    } catch (e) {
      _tell(messenger, 
        SnackBar(content: Text('Could not finish the session log: $e')),
      );
      return true;
    }
    return _save(messenger, log, reason: reason);
  }

  static Future<bool> _save(
    ScaffoldMessengerState? messenger,
    _RunningLog log, {
    String? reason,
  }) async {
    String? saved;
    try {
      saved = await log.destination.save(log.sink, log.fileName);
    } on Exception catch (e) {
      _tell(messenger, 
        SnackBar(content: Text('Could not save the session log: $e')),
      );
      return true;
    }
    final prefix = reason == null ? '' : '$reason ';
    if (saved == null) {
      // Backed out of the picker. The log is still in memory for as long as
      // this message is up, so it can be saved after all.
      _tell(messenger, 
        SnackBar(
          content: Text('${prefix}The session log was not saved.'),
          duration: const Duration(seconds: 8),
          action: SnackBarAction(
            label: 'Save…',
            onPressed: () => unawaited(_save(messenger, log)),
          ),
        ),
      );
      return false;
    }
    _tell(messenger, 
      SnackBar(content: Text('${prefix}Session log saved: $saved')),
    );
    return true;
  }

  /// Shows [bar] in place of whatever this flow said last: "Recording…" is
  /// out of date the moment the log is saved.
  static void _tell(ScaffoldMessengerState? messenger, SnackBar bar) {
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(bar);
  }

  /// Before a session closes: finishes and saves a running log, so closing
  /// the tab does not throw it away.
  static Future<void> stopBeforeClose(
    BuildContext context,
    SessionController session,
  ) async {
    if (!session.terminal.isRecording) return;
    await stop(context, session);
  }

  /// The start dialog: plain text or as received. Null if cancelled.
  static Future<bool?> _askHow(
    BuildContext context,
    SessionLogDestination destination,
  ) {
    var plainText = true;
    return showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Record session log'),
          // Scrolls on a small phone with large text rather than overflowing.
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Everything this session prints from now on is written to '
                  'a log file. '
                  '${destination.choosesFileFirst ? 'Choose where it goes next.' : 'When you stop, you choose where to save it.'}',
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: plainText,
                  onChanged: (value) => setState(() => plainText = value),
                  title: const Text('Plain text'),
                  subtitle: const Text(
                    'Leave out colours and terminal control codes. Off keeps '
                    'the output exactly as received, for replaying with cat.',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(plainText),
              child: Text(
                destination.choosesFileFirst ? 'Choose file…' : 'Start',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
