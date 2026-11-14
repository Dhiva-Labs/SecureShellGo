import 'dart:convert';

/// Cleans command output before an assistant sees it: private keys out,
/// known secrets out, then a size cap.
///
/// The order is the point. Keys and secrets are removed from the *whole*
/// output first and the cap comes last, so a cut can never land inside a key
/// and leave half of it behind looking like ordinary text, and the scrubber
/// always sees a secret whole.
class BridgeRedactor {
  BridgeRedactor({required this.scrub, this.maxBytes = defaultMaxBytes})
    : assert(maxBytes > 0);

  /// The app passes `DiagnosticsLog.instance.scrub`: every password,
  /// passphrase and token the app has handled this run, plus its patterns
  /// for the common secret shapes.
  final String Function(String) scrub;

  /// The most output, in UTF-8 bytes, an assistant gets from one call (the
  /// truncation note comes on top).
  final int maxBytes;

  static const int defaultMaxBytes = 64 * 1024;

  /// What a private key is replaced with.
  static const String keyMarker = '[private key redacted]';

  /// [output] made fit to hand over. [keepTail] keeps the end rather than
  /// the start when it has to cut, for logs, where the newest lines are the
  /// ones that matter.
  String redact(String output, {bool keepTail = false}) {
    final cleaned = scrub(redactPrivateKeys(output));
    return capUtf8(cleaned, maxBytes, keepTail: keepTail);
  }

  // Labels are a few words around "PRIVATE KEY": OpenSSH, RSA, EC, DSA,
  // ENCRYPTED, PKCS#8's bare form, PGP's "PRIVATE KEY BLOCK". Whitespace
  // between the words may be anything, a line break included, because the
  // output may have been wrapped or reflowed on its way here; and the dash
  // runs are not counted exactly, for the same reason. The closing run stops
  // at five so an END glued to the next BEGIN leaves that BEGIN its dashes.
  static final RegExp _begin = RegExp(
    r'-{2,}[ \t]*BEGIN\s+(?:[A-Z0-9]+\s+){0,4}PRIVATE\s+KEY(?:\s+[A-Z0-9]+){0,2}[ \t]*-{2,5}',
    caseSensitive: false,
  );
  static final RegExp _end = RegExp(
    r'-{2,}[ \t]*END\s+(?:[A-Z0-9]+\s+){0,4}PRIVATE\s+KEY(?:\s+[A-Z0-9]+){0,2}[ \t]*-{2,5}',
    caseSensitive: false,
  );

  // PuTTY's .ppk keeps the private half as base64 lines after a count.
  static final RegExp _puttyPrivate = RegExp(
    r'Private-Lines:[ \t]*(\d+)[^\n]*',
  );

  // A line that could be the inside of a PEM body: base64, or one of the
  // two headers legacy encrypted PEM puts before it, or blank.
  static final RegExp _bodyLine = RegExp(
    r'^[ \t]*(?:[A-Za-z0-9+/=]*|Proc-Type:.*|DEK-Info:.*)[ \t\r]*$',
  );

  // What may sit before an END on its own line and still be key material:
  // base64, whitespace, and the escaped line breaks and quotes of a key
  // printed inside JSON or a quoted string.
  static final RegExp _bodyPrefix = RegExp(r'^(?:[A-Za-z0-9+/=\s"]|\\[nr])*$');

  /// Every PEM private key in [text] replaced by [keyMarker].
  ///
  /// Output that was cut before it reached here (a `read_file` with an
  /// offset, a `tail_log` of the last lines) can hold half a key. A BEGIN
  /// with no END is redacted to the end of the text; an END with no BEGIN
  /// takes the run of key-like lines just above it. Over-redacting a few
  /// lines of a broken key beats handing over the rest of it.
  static String redactPrivateKeys(String text) {
    final hasPem = text.contains(RegExp('PRIVATE', caseSensitive: false));
    final hasPutty = text.contains('Private-Lines:');
    if (!hasPem && !hasPutty) return text;

    var result = text;
    if (hasPem) result = _redactPem(result);
    if (hasPutty) result = _redactPutty(result);
    return result;
  }

  static String _redactPem(String text) {
    final out = StringBuffer();
    var cursor = 0;
    // The next BEGIN and END are searched for once and kept until the cursor
    // passes them. Searching afresh each turn rescans the whole rest of the
    // text for a marker that is not there, which made a few thousand stray
    // ENDs cost seconds.
    Match? begin, end;
    var beginFrom = -1, endFrom = -1;
    Match? nextBegin(int from) {
      if (beginFrom < 0 || (begin != null && begin!.start < from)) {
        begin = _begin.allMatches(text, from).firstOrNull;
        beginFrom = from;
      }
      return begin;
    }

    Match? nextEnd(int from) {
      if (endFrom < 0 || (end != null && end!.start < from)) {
        end = _end.allMatches(text, from).firstOrNull;
        endFrom = from;
      }
      return end;
    }

    while (cursor < text.length) {
      final begin = nextBegin(cursor);
      final end = nextEnd(cursor);
      if (begin == null && end == null) break;

      if (end != null && (begin == null || end.start < begin.start)) {
        // An END with no BEGIN before it.
        final from = _orphanBodyStart(text, cursor, end.start);
        out
          ..write(text.substring(cursor, from))
          ..write(keyMarker);
        cursor = end.end;
        continue;
      }

      out
        ..write(text.substring(cursor, begin!.start))
        ..write(keyMarker);
      final close = nextEnd(begin.end);
      if (close == null) {
        cursor = text.length;
        break;
      }
      cursor = close.end;
    }
    if (cursor < text.length) out.write(text.substring(cursor));
    return out.toString();
  }

  /// Where the body of a key whose BEGIN is missing starts, looking back from
  /// [endStart] but never before [floor] (text already handled).
  static int _orphanBodyStart(String text, int floor, int endStart) {
    // lastIndexOf rejects a negative start, so an END at index 0 (or a
    // line of one character) must not be asked for "before position 0".
    var lineStart = endStart == 0
        ? 0
        : text.lastIndexOf('\n', endStart - 1) + 1;
    if (lineStart < floor) lineStart = floor;
    // Text before the END on its own line: take it only if it could be key.
    final prefix = text.substring(lineStart, endStart);
    if (!_bodyPrefix.hasMatch(prefix)) return endStart;
    var start = lineStart;
    while (start > floor) {
      final prevEnd = start - 1; // the '\n' ending the line above
      var prevStart = prevEnd == 0
          ? 0
          : text.lastIndexOf('\n', prevEnd - 1) + 1;
      if (prevStart < floor) prevStart = floor;
      final line = text.substring(prevStart, prevEnd);
      if (!_bodyLine.hasMatch(line)) break;
      start = prevStart;
    }
    return start;
  }

  static String _redactPutty(String text) {
    final out = StringBuffer();
    var cursor = 0;
    for (final m in _puttyPrivate.allMatches(text)) {
      if (m.start < cursor) continue;
      final count = int.tryParse(m[1]!) ?? 0;
      out
        ..write(text.substring(cursor, m.start))
        ..write('Private-Lines: $keyMarker');
      // [pos] sits on the line break ending the count line; walk past
      // [count] more lines. A count larger than what follows takes the rest.
      var pos = m.end;
      for (var i = 0; i < count && pos < text.length; i++) {
        final nl = text.indexOf('\n', pos + 1);
        pos = nl < 0 ? text.length : nl;
      }
      cursor = pos;
    }
    out.write(text.substring(cursor));
    return out.toString();
  }

  /// [text] cut to at most [maxBytes] UTF-8 bytes, on a character boundary,
  /// with a note saying how much was dropped. Untouched when it fits.
  static String capUtf8(String text, int maxBytes, {bool keepTail = false}) {
    // Every UTF-16 unit is at most three bytes, so short text cannot be over.
    if (text.length * 3 <= maxBytes) return text;
    final bytes = utf8.encode(text);
    if (bytes.length <= maxBytes) return text;
    bool continuation(int i) => (bytes[i] & 0xC0) == 0x80;

    if (keepTail) {
      var start = bytes.length - maxBytes;
      while (start < bytes.length && continuation(start)) {
        start++;
      }
      final kept = utf8.decode(bytes.sublist(start));
      return '[output truncated: $start earlier bytes]\n$kept';
    }
    var cut = maxBytes;
    while (cut > 0 && continuation(cut)) {
      cut--;
    }
    final kept = utf8.decode(bytes.sublist(0, cut));
    return '$kept\n[output truncated: ${bytes.length - cut} more bytes]';
  }
}
