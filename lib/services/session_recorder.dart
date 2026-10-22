import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

// `core.dart`, as in session_controller.dart: the terminal buffer is pure
// Dart, and so is everything here.
import 'package:xterm/core.dart';

/// A [Terminal] whose output can be copied, as it arrives, into a
/// [SessionRecorder].
///
/// Every byte the remote shell prints reaches the screen through [write], so
/// that is where a recording listens: the session needs no hook of its own,
/// and what is recorded is exactly what was shown, the session's own notices
/// ("── new shell ──", a reconnect) included.
class RecordingTerminal extends Terminal {
  RecordingTerminal({
    super.maxLines,
    super.platform,
    super.onOutput,
    super.onResize,
    super.onBell,
  });

  SessionRecorder? get recorder => _recorder;
  SessionRecorder? _recorder;

  /// The recording that just started or stopped — stopped here, or by
  /// itself ([SessionRecorder.stoppedBy] says why: it is full, or its file
  /// could not be written; [SessionRecorder.ending] is what became of it).
  Stream<SessionRecorder> get recordingChanges => _recordingChanges.stream;
  final _recordingChanges =
      StreamController<SessionRecorder>.broadcast(sync: true);

  bool get isRecording => _recorder != null;

  /// Recordings that stopped by themselves and have not been told to the
  /// user yet, oldest first: it happened while the session was not on
  /// screen, or before the message could be shown.
  List<SessionLogEnding> get unannounced => List.unmodifiable(_unannounced);
  final List<SessionLogEnding> _unannounced = [];

  /// Takes [ending] off [unannounced], to tell the user about it. False
  /// when something else already has.
  bool announce(SessionLogEnding ending) => _unannounced.remove(ending);

  /// Starts copying output into [recorder]. One recording at a time.
  void startRecording(SessionRecorder recorder) {
    if (_recorder != null) {
      throw StateError('This session is already being recorded.');
    }
    _recorder = recorder;
    recorder._onStopped = () {
      if (identical(_recorder, recorder)) {
        _recorder = null;
        final ending = recorder.ending;
        if (ending != null) _unannounced.add(ending);
        _recordingChanges.add(recorder);
      }
    };
    _recordingChanges.add(recorder);
  }

  /// Stops copying output and hands back the recording, still open, for the
  /// caller to [SessionRecorder.finish] or [SessionRecorder.discard].
  SessionRecorder? stopRecording() {
    final recorder = _recorder;
    if (recorder == null) return null;
    _recorder = null;
    recorder._onStopped = null;
    _recordingChanges.add(recorder);
    return recorder;
  }

  @override
  void write(String data) {
    super.write(data);
    _recorder?.add(data);
  }
}

/// Where a recording's bytes go.
abstract class SessionLogSink {
  /// Takes the next bytes. Synchronous: output keeps arriving whether or
  /// not the disk is quick.
  void add(List<int> bytes);

  /// Everything has been added; flush and close.
  Future<void> close();

  /// Throw away what was written, if anything can be.
  Future<void> discard();

  /// Completes with an error if writing fails later (a full disk, a
  /// removed drive), so the recording can stop and say so.
  Future<void> get failed;
}

/// Keeps the log in memory, for a platform that can only save a finished
/// file — Android's "save as", which writes to wherever the user picks.
class MemoryLogSink implements SessionLogSink {
  final BytesBuilder _bytes = BytesBuilder(copy: false);

  int get length => _bytes.length;

  /// The log so far.
  Uint8List takeBytes() => _bytes.toBytes();

  @override
  void add(List<int> bytes) => _bytes.add(bytes);

  @override
  Future<void> close() async {}

  @override
  Future<void> discard() async => _bytes.clear();

  @override
  Future<void> get failed => Completer<void>().future;
}

/// Writes the log straight into a file as it arrives, for a desktop, where
/// the file is chosen before recording starts: a log of a long session is
/// on disk as it goes, not held until the end.
class FileLogSink implements SessionLogSink {
  FileLogSink(this.file) : _sink = file.openWrite() {
    _sink.done.catchError((Object error) {
      if (!_failed.isCompleted) _failed.completeError(error);
    });
  }

  final File file;
  final IOSink _sink;
  final Completer<void> _failed = Completer<void>();
  bool _closed = false;

  @override
  void add(List<int> bytes) {
    if (_closed || _failed.isCompleted) return;
    _sink.add(bytes);
  }

  /// Writes what is still buffered and closes the file. Completes with the
  /// error when the file could not be written.
  ///
  /// `close` rather than `flush` and then `close`: once the file has failed,
  /// [IOSink.flush] never completes, and whatever waited on it — the "could
  /// not be written" message — would wait for ever. `close` writes what is
  /// buffered either way.
  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _sink.close();
  }

  @override
  Future<void> discard() async {
    try {
      await close();
    } catch (_) {
      // Removing it is what matters.
    }
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Nothing more to do about a file that cannot be removed.
    }
  }

  @override
  Future<void> get failed => _failed.future;
}

/// Why a recording stopped by itself.
enum RecordingStop { full, failed }

/// What becomes of a finished log, decided when the recording starts.
abstract class SessionLogSaver {
  /// Saving asks the user where — Android's "save as" — so it waits for
  /// someone to be looking. A desktop's file was chosen before recording
  /// started, and finishing it is saving it.
  bool get asksWhere;

  /// Saves the finished log. Returns what to call it in a message, or null
  /// when the user backed out of choosing where. Throws when it could not
  /// be written.
  Future<String?> save();
}

/// A recording that stopped by itself — full, or its file could not be
/// written — and what became of it.
///
/// The session's owner (`SessionManager`) finishes it and, where that asks
/// nobody, saves it, whether or not the session is on screen; whatever
/// shows the session tells the user, then or the next time it is shown
/// ([RecordingTerminal.unannounced]).
class SessionLogEnding {
  SessionLogEnding._(this.recorder);

  final SessionRecorder recorder;

  /// Completes once the log is finished, and saved unless [needsSaving].
  Future<void> get settled => _settled.future;
  final Completer<void> _settled = Completer<void>();

  bool get isSettled => _settled.isCompleted;

  /// What it was saved as.
  String? get savedAs => _savedAs;
  String? _savedAs;

  /// Finished, but saving it asks the user where ([SessionLogSaver.asksWhere]),
  /// which is for whatever shows the session to offer.
  bool get needsSaving => _needsSaving;
  bool _needsSaving = false;

  /// Why it could not be saved.
  Object? get error => _error;
  Object? _error;

  /// Records what became of it. Once.
  void settle({String? savedAs, bool needsSaving = false, Object? error}) {
    if (_settled.isCompleted) return;
    _savedAs = savedAs;
    _needsSaving = needsSaving;
    _error = error;
    _settled.complete();
  }
}

/// One recording of a session's output.
///
/// As received — escape sequences and all, so `cat` on the file replays the
/// colours — or as plain text, with them taken out and carriage returns,
/// backspaces and line erases applied the way the screen applied them, so
/// a progress bar is its last state and a corrected typo reads corrected.
class SessionRecorder {
  SessionRecorder({
    required this.sink,
    this.plainText = true,
    this.maxBytes,
    this.header,
    this.saver,
    DateTime Function() clock = DateTime.now,
  })  : _clock = clock,
        startedAt = clock(),
        _stripper = plainText ? TerminalTextStripper() : null {
    final header = this.header;
    if (header != null) _write('$header\n');
    sink.failed.then((_) {}, onError: (Object error) {
      failure = error;
      _stopBySelf(RecordingStop.failed);
    });
  }

  final SessionLogSink sink;
  final bool plainText;

  /// Stops recording, with [stoppedBy] set to [RecordingStop.full], once
  /// this many bytes are written. Null for no limit.
  final int? maxBytes;

  /// A first line saying what this is a log of.
  final String? header;

  /// Where the finished log goes, for whoever finishes it. Null when the
  /// sink is all there is to it.
  final SessionLogSaver? saver;

  final DateTime Function() _clock;
  final DateTime startedAt;
  final TerminalTextStripper? _stripper;

  int get bytesWritten => _bytesWritten;
  int _bytesWritten = 0;

  /// Set when the recording stopped itself.
  RecordingStop? stoppedBy;

  /// What went wrong, when [stoppedBy] is [RecordingStop.failed].
  Object? failure;

  /// What became of it, once it has stopped by itself.
  SessionLogEnding? get ending => _ending;
  SessionLogEnding? _ending;

  bool _ended = false;
  void Function()? _onStopped;

  /// Takes the next output from the session.
  void add(String data) {
    if (_ended || stoppedBy != null) return;
    final stripper = _stripper;
    _write(stripper == null ? data : stripper.add(data));
  }

  void _write(String text) {
    if (text.isEmpty) return;
    final bytes = utf8.encode(text);
    final limit = maxBytes;
    if (limit != null && _bytesWritten + bytes.length > limit) {
      final room = limit - _bytesWritten;
      if (room > 0) {
        sink.add(_wholeCharacters(bytes, room));
        _bytesWritten = limit;
      }
      _stopBySelf(RecordingStop.full);
      return;
    }
    sink.add(bytes);
    _bytesWritten += bytes.length;
  }

  /// The first [room] bytes of [bytes], cut back to a character boundary.
  static List<int> _wholeCharacters(Uint8List bytes, int room) {
    var end = room;
    // A UTF-8 continuation byte is 10xxxxxx: step back to the lead byte.
    while (end > 0 && end < bytes.length && (bytes[end] & 0xC0) == 0x80) {
      end--;
    }
    return Uint8List.sublistView(bytes, 0, end);
  }

  void _stopBySelf(RecordingStop why) {
    if (stoppedBy != null || _ended) return;
    stoppedBy = why;
    _ending = SessionLogEnding._(this);
    _onStopped?.call();
  }

  /// Writes what is left — the plain-text line still being typed — and a
  /// last line, and closes the sink.
  Future<void> finish({String? footer}) async {
    if (_ended) return;
    final stripper = _stripper;
    if (stripper != null && stoppedBy == null) _write(stripper.flush());
    if (footer != null && stoppedBy == null) {
      _write('${_bytesWritten == 0 ? '' : '\n'}$footer\n');
    }
    _ended = true;
    await sink.close();
  }

  /// Ends the recording and removes what it wrote.
  Future<void> discard() async {
    _ended = true;
    await sink.discard();
  }

  /// How long it has been running.
  Duration get elapsed => _clock().difference(startedAt);
}

/// Turns terminal output into plain text, a chunk at a time.
///
/// Escape sequences are taken out, wherever a chunk boundary falls inside
/// one. The line being printed is kept as a row of cells with a cursor, so
/// that what the screen did to it, the log does too: a carriage return goes
/// back to the start of the line (and a progress bar's last state is what is
/// left), a backspace steps back, `ESC [ K` erases to the end, and the cursor
/// moves and deletes that line editors use (`ESC [ C`, `D`, `G`, `P`, `@`,
/// `X`) are followed. Lines are written when they end; [flush] writes the
/// unfinished one. Anything that moves to another line (`vim`, `htop`) is
/// beyond a plain-text log, as it is beyond `script`.
class TerminalTextStripper {
  /// The right edge: the cursor goes no further, and printing at the last
  /// column ends the line there, so output with no newlines in it cannot
  /// grow without bound.
  static const int maxLineLength = 16384;

  final List<int> _line = [];
  int _column = 0;

  _State _state = _State.text;
  final StringBuffer _params = StringBuffer();

  /// Plain text for [chunk]: every line it finished.
  String add(String chunk) {
    final out = StringBuffer();
    for (final rune in chunk.runes) {
      _take(rune, out);
    }
    return out.toString();
  }

  /// The unfinished line, if there is one. Resets the stripper.
  String flush() {
    final out = StringBuffer();
    if (_line.isNotEmpty) _endLine(out, newline: false);
    _state = _State.text;
    _params.clear();
    return out.toString();
  }

  void _take(int c, StringBuffer out) {
    switch (_state) {
      case _State.text:
        _text(c, out);
      case _State.escape:
        _escape(c);
      case _State.escapeIntermediate:
        // `ESC ( B` and friends: one more character ends it.
        if (c < 0x20 || c > 0x2F) _state = _State.text;
      case _State.csi:
        if (c >= 0x40 && c <= 0x7E) {
          _state = _State.text;
          _csi(c);
          _params.clear();
        } else if (c >= 0x20 && c <= 0x3F) {
          _params.writeCharCode(c);
        } else if (c == 0x1B) {
          _params.clear();
          _state = _State.escape;
        } else {
          // A control character in the middle: the sequence is broken.
          _params.clear();
          _state = _State.text;
          _text(c, out);
        }
      case _State.string:
        // OSC (titles, hyperlinks, clipboard), DCS, SOS, PM, APC: dropped up
        // to BEL or the string terminator.
        if (c == 0x07 || c == 0x9C) {
          _state = _State.text;
        } else if (c == 0x1B) {
          _state = _State.stringEscape;
        }
      case _State.stringEscape:
        _state = c == 0x5C ? _State.text : _State.string;
    }
  }

  void _text(int c, StringBuffer out) {
    switch (c) {
      case 0x1B:
        _state = _State.escape;
      case 0x9B:
        _state = _State.csi;
      case 0x90 || 0x98 || 0x9D || 0x9E || 0x9F:
        _state = _State.string;
      case 0x0A:
        _endLine(out, newline: true);
      case 0x0D:
        _column = 0;
      case 0x08:
        if (_column > 0) _column--;
      default:
        // Every other C0 and C1 control (the bell, shift-in/out, NUL) and
        // DEL: nothing a reader of the log would want. Tabs are kept.
        if (c != 0x09 &&
            (c < 0x20 || c == 0x7F || (c >= 0x80 && c < 0xA0))) {
          return;
        }
        _put(c);
        if (_column >= maxLineLength) _endLine(out, newline: true);
    }
  }

  void _escape(int c) {
    if (c == 0x5B) {
      _state = _State.csi;
    } else if (c == 0x5D || c == 0x50 || c == 0x58 || c == 0x5E || c == 0x5F) {
      _state = _State.string;
    } else if (c >= 0x20 && c <= 0x2F) {
      _state = _State.escapeIntermediate;
    } else {
      // A two-character sequence: save/restore cursor, keypad modes, index.
      _state = _State.text;
    }
  }

  void _csi(int command) {
    final raw = _params.toString();
    // Private sequences (`ESC [ ? 25 l`, `ESC [ > c`) never touch the text.
    if (raw.isNotEmpty && '<=>?'.contains(raw[0])) return;
    final first = int.tryParse(raw.split(';').first) ?? 0;
    // A terminal clamps a count to its screen; this one to the longest line
    // it keeps, or `ESC [ 2000000000 C` would pad a line out to gigabytes.
    final n = first < 1
        ? 1
        : first > maxLineLength
            ? maxLineLength
            : first;
    switch (String.fromCharCode(command)) {
      case 'K':
        switch (first) {
          case 0:
            if (_column < _line.length) _line.length = _column;
          case 1:
            for (var i = 0; i < _column && i < _line.length; i++) {
              _line[i] = 0x20;
            }
          case 2:
            _line.clear();
        }
      case 'C':
        _column = _clampColumn(_column + n);
      case 'D':
        _column = _column > n ? _column - n : 0;
      case 'G':
        _column = _clampColumn(n - 1);
      case 'P':
        if (_column < _line.length) {
          final end = _column + n < _line.length ? _column + n : _line.length;
          _line.removeRange(_column, end);
        }
      case '@':
        if (_column < _line.length) {
          _line.insertAll(_column, List<int>.filled(n, 0x20));
          // What is pushed past the right edge is gone, as on a screen.
          if (_line.length > maxLineLength) _line.length = maxLineLength;
        }
      case 'X':
        for (var i = _column; i < _column + n && i < _line.length; i++) {
          _line[i] = 0x20;
        }
    }
  }

  /// The last column a line has: the cursor goes no further right.
  static int _clampColumn(int column) =>
      column < maxLineLength ? column : maxLineLength - 1;

  void _put(int c) {
    while (_line.length < _column) {
      _line.add(0x20);
    }
    if (_column < _line.length) {
      _line[_column] = c;
    } else {
      _line.add(c);
    }
    _column++;
  }

  void _endLine(StringBuffer out, {required bool newline}) {
    var end = _line.length;
    while (end > 0 && _line[end - 1] == 0x20) {
      end--;
    }
    out.write(String.fromCharCodes(_line, 0, end));
    if (newline) out.write('\n');
    _line.clear();
    _column = 0;
  }
}

enum _State { text, escape, escapeIntermediate, csi, string, stringEscape }

/// A file name for a log of [label] started at [when]: the label with
/// anything a file system might refuse replaced, and the time to the second.
String sessionLogFileName(String label, DateTime when) {
  var safe = label
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f\s]+'), '-')
      .replaceAll(RegExp(r'-{2,}'), '-')
      .replaceAll(RegExp(r'^[-.]+|[-.]+$'), '');
  if (safe.isEmpty) safe = 'session';
  if (safe.length > 60) safe = safe.substring(0, 60);
  String two(int n) => n.toString().padLeft(2, '0');
  final stamp = '${when.year}-${two(when.month)}-${two(when.day)}_'
      '${two(when.hour)}-${two(when.minute)}-${two(when.second)}';
  return '$safe-$stamp.log';
}

/// A log's last line.
String sessionLogFooter(DateTime when) =>
    'Session log ended ${sessionLogTimestamp(when)}';

/// "2026-10-21 14:03:22", for a log's first and last lines.
String sessionLogTimestamp(DateTime when) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${when.year}-${two(when.month)}-${two(when.day)} '
      '${two(when.hour)}:${two(when.minute)}:${two(when.second)}';
}
