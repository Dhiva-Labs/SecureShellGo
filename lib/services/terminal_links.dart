import 'package:xterm/core.dart';

import 'terminal_search.dart';

/// A web address found in terminal output.
class TerminalLink {
  const TerminalLink({
    required this.url,
    required this.start,
    required this.end,
  });

  /// The address exactly as printed.
  final String url;

  /// Code-unit offsets into the text it was found in; [end] is exclusive.
  final int start;
  final int end;

  /// What would be opened: [url] parsed, or null if it does not parse as an
  /// address with a host (`https://` on its own, `http://[nonsense`).
  Uri? get uri => TerminalLinks.parse(url);

  @override
  bool operator ==(Object other) =>
      other is TerminalLink &&
      other.url == url &&
      other.start == start &&
      other.end == end;

  @override
  int get hashCode => Object.hash(url, start, end);

  @override
  String toString() => 'TerminalLink($url, $start..$end)';
}

/// A link under a cell, with the cells it covers.
class TerminalLinkHit {
  const TerminalLinkHit(this.uri, this.begin, this.end, {required this.text});

  final Uri uri;

  /// The address as printed, for copying.
  final String text;
  final CellOffset begin;

  /// Exclusive.
  final CellOffset end;
}

/// Finds web addresses in terminal text, and decides which may be opened.
///
/// Only `http` and `https` are looked for, and only they open. A terminal is
/// full of text a server chose — a `file:` link to a script, a custom
/// scheme that starts some other app, `javascript:` — and a tap that does
/// nothing is a far smaller problem than a tap that runs something.
class TerminalLinks {
  const TerminalLinks._();

  static const Set<String> openableSchemes = {'http', 'https'};

  /// A scheme followed by the characters a printed address can contain.
  /// Whitespace, quotes, angle brackets and backticks end one; brackets and
  /// parentheses do not, since real addresses contain them — the trailing
  /// ones are dealt with in [_trim].
  static final RegExp _candidate = RegExp(
    r'''\bhttps?://[^\s"'<>`{}|\\^\x00-\x1f\x7f]+''',
    caseSensitive: false,
  );

  /// Characters that end a sentence more often than an address: `see
  /// https://example.com.` means the address without its full stop.
  static const String _trailing = '.,;:!?*\'"';

  static const Map<String, String> _pairs = {')': '(', ']': '[', '}': '{'};

  /// Every address in [text], in order.
  static List<TerminalLink> find(String text) {
    final links = <TerminalLink>[];
    for (final m in _candidate.allMatches(text)) {
      final url = _trim(m[0]!);
      if (parse(url) == null) continue;
      links.add(TerminalLink(url: url, start: m.start, end: m.start + url.length));
    }
    return links;
  }

  /// The address in [text] covering code unit [index], if any.
  static TerminalLink? at(String text, int index) {
    for (final link in find(text)) {
      if (index >= link.start && index < link.end) return link;
    }
    return null;
  }

  /// The address under [cell] in [buffer], read across wrapped rows, or null.
  static TerminalLinkHit? inBuffer(Buffer buffer, CellOffset cell) {
    if (cell.y < 0 || cell.y >= buffer.height) return null;
    final line = BufferText.lineAt(buffer, cell.y);
    final index = line.indexOf(cell);
    if (index == null) return null;
    final link = at(line.text, index);
    final uri = link?.uri;
    if (link == null || uri == null) return null;
    final cells = line.cellsOf(link.start, link.end);
    return TerminalLinkHit(uri, cells.begin, cells.end, text: link.url);
  }

  /// [url] as something to open, or null when it must not be: anything but
  /// `http`/`https`, no host, or text that does not parse as an address.
  static Uri? parse(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    if (!openableSchemes.contains(uri.scheme.toLowerCase())) return null;
    if (uri.host.isEmpty) return null;
    return uri;
  }

  /// Takes sentence punctuation off the end, and a closing bracket the
  /// address did not open: `(see https://example.com/a)` is the address
  /// without the `)`, but `https://en.wikipedia.org/wiki/Bash_(Unix_shell)`
  /// keeps it.
  static String _trim(String url) {
    var end = url.length;
    while (end > 0) {
      final last = url[end - 1];
      if (_trailing.contains(last)) {
        end--;
        continue;
      }
      final open = _pairs[last];
      if (open != null) {
        final body = url.substring(0, end);
        final opened = open.allMatches(body).length;
        final closed = last.allMatches(body).length;
        if (closed > opened) {
          end--;
          continue;
        }
      }
      break;
    }
    return url.substring(0, end);
  }
}
