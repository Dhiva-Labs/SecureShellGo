import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../app_data_paths.dart';
import '../atomic_file.dart';
import 'bridge_locator.dart' show restrictToOwner;
import 'bridge_redactor.dart';

/// How one bridge call ended.
enum BridgeAuditOutcome {
  ok,
  refused,
  error;

  static BridgeAuditOutcome? fromJson(Object? value) {
    for (final outcome in values) {
      if (outcome.name == value) return outcome;
    }
    return null;
  }
}

/// How a call that changes a server was allowed, or why it was not. Every
/// read is [none]; so is a change refused before anyone was asked, and so is
/// every line written before 1.7.0 (it has no `approval` field).
enum BridgeAuditApproval {
  /// Nobody was asked: a read, or a call refused before a card.
  none('none'),

  /// The exact command was on the host's allowed list.
  allowedCommand('allowed_command'),

  /// A time-limited approval was live.
  grant('grant'),

  /// The user allowed this one call.
  once('once'),

  /// The user allowed it, and the same assistant may change the same host
  /// without asking for a while.
  forAWhile('for_a_while'),
  denied('denied'),
  timedOut('timed_out'),

  /// The call was cancelled or stopped while the card was waiting.
  withdrawn('withdrawn');

  const BridgeAuditApproval(this.wire);

  /// The value written to the log.
  final String wire;

  /// Absent or unrecognised reads as [none], so a line is never dropped for
  /// this field alone.
  static BridgeAuditApproval fromJson(Object? value) {
    for (final approval in values) {
      if (approval.wire == value) return approval;
    }
    return none;
  }
}

/// One line of the activity log: who asked, for what, and how it ended.
/// Never what came back: output can hold anything the server had, and the log
/// is kept for longer and shown more freely than the output ever was.
class BridgeAuditEntry {
  const BridgeAuditEntry({
    required this.ts,
    required this.client,
    required this.host,
    required this.tool,
    required this.args,
    required this.outcome,
    required this.detail,
    required this.ms,
    this.approval = BridgeAuditApproval.none,
  });

  final DateTime ts;

  /// The paired assistant's name, as the user gave it.
  final String client;

  /// The bridge name of the host, or null for a tool that takes none.
  final String? host;
  final String tool;

  /// The arguments as JSON, scrubbed and cut short.
  final String args;
  final BridgeAuditOutcome outcome;

  /// The refusal code, the error message, or a short note; scrubbed.
  final String detail;
  final int ms;

  /// How a change was allowed, or why not; [BridgeAuditApproval.none] for
  /// a read.
  final BridgeAuditApproval approval;

  Map<String, Object?> toJson() => {
    'ts': ts.toUtc().toIso8601String(),
    'client': client,
    if (host != null) 'host': host,
    'tool': tool,
    'args': args,
    'outcome': outcome.name,
    'detail': detail,
    'ms': ms,
    'approval': approval.wire,
  };

  /// Null for anything that is not a whole, well-formed entry, which is how a
  /// line cut short by a crash is passed over rather than failing the read.
  static BridgeAuditEntry? tryParse(String line) {
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, Object?>) return null;
    final ts = decoded['ts'];
    final client = decoded['client'];
    final host = decoded['host'];
    final tool = decoded['tool'];
    final args = decoded['args'];
    final outcome = BridgeAuditOutcome.fromJson(decoded['outcome']);
    final detail = decoded['detail'];
    final ms = decoded['ms'];
    if (ts is! String ||
        client is! String ||
        (host != null && host is! String) ||
        tool is! String ||
        args is! String ||
        outcome == null ||
        detail is! String ||
        ms is! int) {
      return null;
    }
    final time = DateTime.tryParse(ts);
    if (time == null) return null;
    return BridgeAuditEntry(
      ts: time,
      client: client,
      host: host as String?,
      tool: tool,
      args: args,
      outcome: outcome,
      detail: detail,
      ms: ms,
      approval: BridgeAuditApproval.fromJson(decoded['approval']),
    );
  }

  @override
  String toString() => 'BridgeAuditEntry(${toJson()})';
}

/// The bridge's activity log: append-only JSON lines in
/// `<appdata>/bridge/audit.log`, rotated to `audit.log.1` past
/// [rotateBytes], so it never holds more than about twice that.
///
/// A write that fails is never thrown at the caller. The caller is in the
/// middle of answering an assistant, and a full disk or a permissions slip on
/// the log must not turn a finished, harmless read into an error the
/// assistant retries. Instead [record] returns false and [lastWriteError]
/// says why, so the bridge screen can tell the user their activity log has a
/// gap — which is the person who can do something about it.
class BridgeAuditLog {
  BridgeAuditLog({
    required this.scrub,
    this.directory,
    this.rotateBytes = defaultRotateBytes,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// Applied to arguments and details before they are written (the app
  /// passes `DiagnosticsLog.instance.scrub`).
  final String Function(String) scrub;
  final int rotateBytes;
  final DateTime Function() _clock;

  /// Where the log lives; null means `<appdata>/bridge`, found on first use.
  final Directory? directory;
  Directory? _resolved;

  static const int defaultRotateBytes = 512 * 1024;
  static const String fileName = 'audit.log';

  /// Longest `args` kept, in characters.
  static const int maxArgsChars = 500;

  /// Longest `detail`, client, host or tool name kept, in characters. These
  /// are short by nature; the cap only stops an odd one from bloating every
  /// line.
  static const int maxFieldChars = 500;

  final SerialFileWriter _writer = SerialFileWriter();
  final StreamController<BridgeAuditEntry> _entries =
      StreamController<BridgeAuditEntry>.broadcast();

  final StreamController<String?> _writeErrors =
      StreamController<String?>.broadcast();

  String? _lastWriteError;

  /// Why the most recent write failed, or null when it succeeded.
  String? get lastWriteError => _lastWriteError;

  /// [lastWriteError] each time it changes, so a screen can show or drop its
  /// warning the moment the log starts or stops failing.
  Stream<String?> get writeErrors => _writeErrors.stream;

  void _setWriteError(String? error) {
    if (error == _lastWriteError) return;
    _lastWriteError = error;
    if (!_writeErrors.isClosed) _writeErrors.add(error);
  }

  /// Each entry once its write has been attempted, written to disk or not, so
  /// a screen that is open sees activity even while the file cannot be
  /// written. By the time an entry arrives, [lastWriteError] is up to date.
  Stream<BridgeAuditEntry> get entries => _entries.stream;

  Future<Directory> _resolveDirectory() async {
    final known = directory ?? _resolved;
    if (known != null) return known;
    final root = await AppDataPaths.resolveDirectory();
    return _resolved = Directory('${root.path}/bridge');
  }

  /// Appends one entry. True when it reached the disk.
  Future<bool> record({
    required String client,
    required String? host,
    required String tool,
    required Map<String, Object?> args,
    required BridgeAuditOutcome outcome,
    String detail = '',
    required int ms,
    BridgeAuditApproval approval = BridgeAuditApproval.none,
  }) async {
    final BridgeAuditEntry entry;
    try {
      entry = BridgeAuditEntry(
        ts: _clock().toUtc(),
        client: _clip(client, maxFieldChars),
        host: host == null ? null : _clip(host, maxFieldChars),
        tool: _clip(tool, maxFieldChars),
        // Keys out before the cap, as for output: a cut through a key
        // would leave a fragment no pattern recognises.
        args: _clip(
          scrub(BridgeRedactor.redactPrivateKeys(_encodeArgs(args))),
          maxArgsChars,
        ),
        outcome: outcome,
        detail: _clip(scrub(detail), maxFieldChars),
        ms: ms < 0 ? 0 : ms,
        approval: approval,
      );
    } catch (e) {
      // A scrubber that throws is a bug elsewhere; it still must not reach
      // the tool call.
      _setWriteError('Could not prepare the activity entry: $e');
      return false;
    }

    var written = true;
    try {
      await _writer.run(() => _append(entry));
      _setWriteError(null);
    } catch (e) {
      _setWriteError('Could not write the activity log: $e');
      written = false;
    }
    if (!_entries.isClosed) _entries.add(entry);
    return written;
  }

  Future<void> _append(BridgeAuditEntry entry) async {
    final dir = await _resolveDirectory();
    await dir.create(recursive: true);
    final file = File('${dir.path}/$fileName');
    final line = '${jsonEncode(entry.toJson())}\n';
    final lineBytes = utf8.encode(line);

    var size = 0;
    var exists = await file.exists();
    if (exists) size = await file.length();
    if (size > 0 && size + lineBytes.length > rotateBytes) {
      await file.rename('${file.path}.1');
      // A log written by an earlier version may have been created with the
      // default mode; whatever it is, the rotated copy ends up owner-only.
      await _ownerOnly('${file.path}.1');
      size = 0;
      exists = false;
    }
    if (!exists) {
      // Owner-only before anything goes in, and only here, so a chmod is not
      // spawned on every append.
      await file.create();
      await _ownerOnly(file.path);
    }

    final handle = await file.open(mode: FileMode.append);
    try {
      // A crash in the middle of an earlier write can leave a last line with
      // no line break. Start on a fresh line so this entry is not glued onto
      // it and lost along with it.
      if (size > 0) {
        await handle.setPosition(size - 1);
        final last = await handle.read(1);
        await handle.setPosition(size);
        if (last.isNotEmpty && last[0] != 0x0A) {
          await handle.writeFrom(const [0x0A]);
        }
      }
      await handle.writeFrom(lineBytes);
      await handle.flush();
    } finally {
      await handle.close();
    }
  }

  /// `chmod 600` on POSIX, best effort: the folder is already owner-only, so
  /// a chmod that fails costs the log's second lock, not an entry.
  static Future<void> _ownerOnly(String path) async {
    try {
      await restrictToOwner(path, '600');
    } catch (_) {}
  }

  /// The newest [limit] entries, newest first, from both the current file
  /// and the rotated one. Lines that do not parse are skipped. Read errors
  /// give what could be read, or an empty list.
  Future<List<BridgeAuditEntry>> recent({int limit = 200}) async {
    if (limit <= 0) return const [];
    // Queued behind writes, so a read never sees a rotation half done.
    final newestFirst = <BridgeAuditEntry>[];
    try {
      await _writer.run(() async {
        final dir = await _resolveDirectory();
        for (final name in [fileName, '$fileName.1']) {
          if (newestFirst.length >= limit) break;
          final lines = await _readLines(File('${dir.path}/$name'));
          for (final line in lines.reversed) {
            final entry = BridgeAuditEntry.tryParse(line);
            if (entry == null) continue;
            newestFirst.add(entry);
            if (newestFirst.length >= limit) break;
          }
        }
      });
    } catch (_) {
      // Whatever was gathered before the failure is still worth showing.
    }
    return newestFirst;
  }

  static Future<List<String>> _readLines(File file) async {
    try {
      if (!await file.exists()) return const [];
      final bytes = await file.readAsBytes();
      // A torn multi-byte character at the end of a cut-off line must not
      // cost the lines before it.
      final text = utf8.decode(bytes, allowMalformed: true);
      return [
        for (final line in const LineSplitter().convert(text))
          if (line.trim().isNotEmpty) line,
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Deletes the log and its rotated copy. True when both are gone.
  Future<bool> clear() async {
    try {
      await _writer.run(() async {
        final dir = await _resolveDirectory();
        for (final name in [fileName, '$fileName.1']) {
          final file = File('${dir.path}/$name');
          if (await file.exists()) await file.delete();
        }
      });
      return true;
    } catch (e) {
      _setWriteError('Could not clear the activity log: $e');
      return false;
    }
  }

  Future<void> dispose() async {
    await _entries.close();
    await _writeErrors.close();
  }

  static String _encodeArgs(Map<String, Object?> args) {
    try {
      return jsonEncode(args);
    } catch (_) {
      // Something that is not JSON reached the arguments; record that it
      // happened rather than nothing at all.
      return jsonEncode({for (final e in args.entries) e.key: '${e.value}'});
    }
  }

  /// [text] cut to [max] UTF-16 units, without splitting a surrogate pair,
  /// with an ellipsis when cut.
  static String _clip(String text, int max) {
    if (text.length <= max) return text;
    var cut = max - 1;
    final unit = text.codeUnitAt(cut - 1);
    if (unit >= 0xD800 && unit <= 0xDBFF) cut--;
    return '${text.substring(0, cut)}…';
  }
}
