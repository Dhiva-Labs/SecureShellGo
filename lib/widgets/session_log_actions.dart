import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart' as file_selector;
import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
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
  /// The right one for this platform; [l10n] words the save dialog.
  factory SessionLogDestination.forPlatform(AppLocalizations l10n) {
    if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      return FileLogDestination(l10n: l10n);
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
  FileLogDestination({
    Future<String?> Function(String suggestedName)? choose,
    AppLocalizations? l10n,
  }) : _choose = choose ??
            _nativeSaveDialog(
              l10n ?? lookupAppLocalizations(const Locale('en')),
            );

  final Future<String?> Function(String suggestedName) _choose;

  static Future<String?> Function(String suggestedName) _nativeSaveDialog(
    AppLocalizations l10n,
  ) =>
      (suggestedName) async {
        final location = await file_selector.getSaveLocation(
          suggestedName: suggestedName,
          confirmButtonText: l10n.sessionLogSaveDialogConfirm,
          canCreateDirectories: true,
          acceptedTypeGroups: [
            file_selector.XTypeGroup(
              label: l10n.sessionLogFileType,
              extensions: const ['log', 'txt'],
            ),
          ],
        );
        return location?.path;
      };

  @override
  bool get choosesFileFirst => true;

  @override
  int? get maxBytes => null;

  @override
  Future<SessionLogSink?> open(String suggestedName) async {
    final path = await _choose(suggestedName);
    if (path == null || path.isEmpty) return null;
    return FileLogSink(File(await withLogExtension(path)));
  }

  /// [path] as chosen, or with `.log` added when it has no extension —
  /// GTK's dialog does not add one the user left off.
  ///
  /// The dialog asked before replacing what the user typed, not the name
  /// with `.log` on the end, so that must not replace anything either: a
  /// name already taken becomes `name (1).log`, and so on.
  @visibleForTesting
  static Future<String> withLogExtension(String path) async {
    if (path.split(Platform.pathSeparator).last.contains('.')) return path;
    var candidate = '$path.log';
    var n = 0;
    // A link to nowhere is taken too: writing to it would create its target.
    while (await FileSystemEntity.type(candidate, followLinks: false) !=
        FileSystemEntityType.notFound) {
      candidate = '$path (${++n}).log';
    }
    return candidate;
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

/// Where a running log is saved at the end, kept with the recorder so that
/// whoever finishes it — the menu, or the session manager when it stopped
/// by itself — saves it the same way.
class _RunningLog implements SessionLogSaver {
  _RunningLog(this.destination, this.sink, this.fileName);

  final SessionLogDestination destination;
  final SessionLogSink sink;
  final String fileName;

  @override
  bool get asksWhere => !destination.choosesFileFirst;

  @override
  Future<String?> save() => destination.save(sink, fileName);
}

/// "Record session log…" and "Stop recording" in the session menu, and what
/// the terminal says when a recording stops by itself.
class SessionLogActions {
  const SessionLogActions._();

  /// Replaces [SessionLogDestination.forPlatform] in tests.
  @visibleForTesting
  static SessionLogDestination? debugDestination;

  static bool isRecording(SessionController session) =>
      session.terminal.isRecording;

  /// Asks how to record, and where on a desktop, then starts.
  static Future<void> start(
    BuildContext context,
    SessionController session,
  ) async {
    final terminal = session.terminal;
    if (terminal.isRecording) return;
    final l10n = context.l10n;
    final destination =
        debugDestination ?? SessionLogDestination.forPlatform(l10n);
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
        SnackBar(content: Text(l10n.sessionLogStartFailed('$e'))),
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
      saver: _RunningLog(destination, sink, fileName),
    );
    terminal.startRecording(recorder);
    _tell(messenger, 
      SnackBar(
        content: Text(
          destination.choosesFileFirst
              ? l10n.sessionLogRecordingTo(
                  sink is FileLogSink
                      ? sink.file.path.split(Platform.pathSeparator).last
                      : fileName,
                )
              : l10n.sessionLogRecordingInMemory,
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

  /// Tells the user about a recording that stopped by itself — full, or
  /// its file could not be written — once the session manager has finished
  /// it (and saved it, where that asks nobody).
  ///
  /// [justNow]: it stopped while this session was on screen, so a log that
  /// has to ask where to go asks straight away. Otherwise it stopped while
  /// the user was elsewhere, and a message offers to save it.
  ///
  /// Nothing is said if [context] has gone by then: the next terminal to
  /// show this session says it instead.
  static Future<void> announce(
    BuildContext context,
    RecordingTerminal terminal,
    SessionLogEnding ending, {
    bool justNow = false,
  }) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final l10n = context.l10n;
    await ending.settled;
    if (!context.mounted || !terminal.announce(ending)) return;
    final recorder = ending.recorder;
    if (recorder.stoppedBy == RecordingStop.failed) {
      _tell(messenger,
        SnackBar(
          content: Text(l10n.sessionLogWriteFailed('${recorder.failure}')),
        ),
      );
      return;
    }
    final saved = ending.savedAs;
    final error = ending.error;
    final log = recorder.saver;
    if (error != null) {
      _tell(messenger,
        SnackBar(content: Text(l10n.sessionLogFullSaveFailed('$error'))),
      );
    } else if (ending.needsSaving && log is _RunningLog) {
      if (justNow) {
        await _save(messenger, l10n, log, full: true);
      } else {
        _tell(messenger,
          SnackBar(
            content: Text(l10n.sessionLogFull),
            duration: const Duration(seconds: 30),
            action: SnackBarAction(
              label: l10n.sessionLogSaveAction,
              onPressed: () => unawaited(_save(messenger, l10n, log)),
            ),
          ),
        );
      }
    } else {
      _tell(messenger,
        SnackBar(
          content: Text(
            saved == null ? l10n.sessionLogFull : l10n.sessionLogFullSaved(saved),
          ),
        ),
      );
    }
  }

  static Future<bool> _finish(
    BuildContext context,
    SessionRecorder recorder,
  ) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final l10n = context.l10n;
    try {
      await recorder.finish(footer: sessionLogFooter(DateTime.now()));
    } catch (e) {
      _tell(messenger,
        SnackBar(content: Text(l10n.sessionLogFinishFailed('$e'))),
      );
      return true;
    }
    final log = recorder.saver;
    if (log is! _RunningLog) return true;
    return _save(messenger, l10n, log);
  }

  /// [full]: the log stopped because it reached its limit, which the
  /// message says first.
  static Future<bool> _save(
    ScaffoldMessengerState? messenger,
    AppLocalizations l10n,
    _RunningLog log, {
    bool full = false,
  }) async {
    String? saved;
    try {
      saved = await log.destination.save(log.sink, log.fileName);
    } on Exception catch (e) {
      _tell(messenger, 
        SnackBar(content: Text(l10n.sessionLogSaveFailed('$e'))),
      );
      return true;
    }
    if (saved == null) {
      // Backed out of the picker. The log is still in memory for as long as
      // this message is up, so it can be saved after all.
      _tell(messenger, 
        SnackBar(
          content: Text(
            full ? l10n.sessionLogFullNotSaved : l10n.sessionLogNotSaved,
          ),
          duration: const Duration(seconds: 8),
          action: SnackBarAction(
            label: l10n.sessionLogSaveAction,
            onPressed: () => unawaited(_save(messenger, l10n, log)),
          ),
        ),
      );
      return false;
    }
    _tell(messenger, 
      SnackBar(
        content: Text(
          full ? l10n.sessionLogFullSaved(saved) : l10n.sessionLogSaved(saved),
        ),
      ),
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
    final l10n = context.l10n;
    return showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(l10n.sessionLogDialogTitle),
          // Scrolls on a small phone with large text rather than overflowing.
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  destination.choosesFileFirst
                      ? l10n.sessionLogDialogBodyFileFirst
                      : l10n.sessionLogDialogBodyFileLater,
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: plainText,
                  onChanged: (value) => setState(() => plainText = value),
                  title: Text(l10n.sessionLogPlainText),
                  subtitle: Text(l10n.sessionLogPlainTextHelp),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(plainText),
              child: Text(
                destination.choosesFileFirst
                    ? l10n.sessionLogChooseFile
                    : l10n.sessionLogStart,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
