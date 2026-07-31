import 'dart:convert';
import 'dart:typed_data';

import 'remote_path.dart';

/// The largest file the editor will open.
///
/// Not a guess at what a text file "should" be: it is the point past which
/// holding the whole document as a Dart string, re-tokenising it and handing
/// it to a single `TextField` stops being something a phone can do between
/// frames. A 2 MB config file is already far outside what anyone edits over
/// SSH; the browser's download path is the honest answer above this.
const int editorMaxFileBytes = 2 * 1024 * 1024;

/// How much of a file is examined for the binary check.
///
/// A NUL byte anywhere in the first 8 KB is what `grep`, `git` and `less`
/// all use to decide a file is not text, and for the same reason: every
/// real-world binary format puts something with a zero byte in its header,
/// and no UTF-8 text ever contains one.
const int editorBinarySniffBytes = 8 * 1024;

/// Below this, a plain tap on a file offers Edit rather than Download.
///
/// Distinct from [editorMaxFileBytes] on purpose. The 2 MB figure is "the
/// editor can cope"; this one is "opening it by accident is cheap" — a
/// mistaken tap on a 1.5 MB log should not pull it over a phone connection
/// before the user has said that is what they wanted.
const int editorTapToEditBytes = 1024 * 1024;

/// Why a file cannot be opened in the editor.
enum EditorRefusal { tooLarge, binary }

/// A file the editor declined to open, with the reason already written out.
class EditorOpenRefused implements Exception {
  const EditorOpenRefused(this.reason, this.message);

  final EditorRefusal reason;
  final String message;

  @override
  String toString() => message;
}

/// Which line terminator a file uses.
///
/// Carried from open to save because rewriting a CRLF file with LF endings
/// shows up as every line changed in the user's `git diff` — a whole-file
/// diff caused by an editor is the fastest way to lose someone's trust in
/// one.
enum LineEndingStyle {
  lf,
  crlf,

  /// Both, in the same file. Saved as LF, which is what every tool that
  /// normalises does, and the save confirmation says so rather than letting
  /// the user discover it in a diff.
  mixed;

  String get label => switch (this) {
        LineEndingStyle.lf => 'LF',
        LineEndingStyle.crlf => 'CRLF',
        LineEndingStyle.mixed => 'mixed',
      };
}

/// A remote file's bytes, turned into something editable.
class DecodedText {
  const DecodedText({
    required this.text,
    required this.lineEndings,
    required this.hadInvalidUtf8,
  });

  /// The document, always with `\n` endings whatever the file used. The
  /// editor works in one convention and [encodeEditorText] puts the file's
  /// own back on the way out; a `TextField` holding `\r\n` would otherwise
  /// count the `\r` as a character the user can put their caret after.
  final String text;

  final LineEndingStyle lineEndings;

  /// True when the bytes were not valid UTF-8 and something was replaced.
  ///
  /// Saving is still allowed — refusing would strand a user who genuinely
  /// needs to fix one Latin-1 line in an otherwise fine file — but it is not
  /// allowed *silently*, because the replacement is not reversible: the
  /// original bytes are gone from the moment they were decoded.
  final bool hadInvalidUtf8;
}

/// True when [bytes] look like something other than text.
///
/// Deliberately one rule rather than a heuristic soup: a NUL byte in the
/// first [editorBinarySniffBytes]. Character-frequency guessing gets ELF
/// binaries right and gets minified JavaScript, base64 blobs and CJK text
/// wrong, and being wrong in that direction means refusing to edit a file
/// the user can see is text.
bool looksBinary(Uint8List bytes) {
  final limit = bytes.length < editorBinarySniffBytes
      ? bytes.length
      : editorBinarySniffBytes;
  for (var i = 0; i < limit; i++) {
    if (bytes[i] == 0) return true;
  }
  return false;
}

/// Which terminator [text] uses, judged before any normalisation.
///
/// A lone `\r` (classic Mac OS) counts as neither: files that old are not
/// what this editor is for, and treating one as CRLF would put a `\r` back
/// on every line of a file that never had one.
LineEndingStyle detectLineEndings(String text) {
  var crlf = 0;
  var lf = 0;
  for (var i = 0; i < text.length; i++) {
    if (text.codeUnitAt(i) != 0x0A) continue;
    if (i > 0 && text.codeUnitAt(i - 1) == 0x0D) {
      crlf++;
    } else {
      lf++;
    }
  }
  if (crlf > 0 && lf > 0) return LineEndingStyle.mixed;
  if (crlf > 0) return LineEndingStyle.crlf;
  return LineEndingStyle.lf;
}

/// Decodes [bytes] for editing, or refuses with a reason the user can act on.
///
/// [name] only ever appears in the refusal messages.
DecodedText decodeEditorText(Uint8List bytes, {required String name}) {
  if (bytes.length > editorMaxFileBytes) {
    throw EditorOpenRefused(
      EditorRefusal.tooLarge,
      '"$name" is ${RemotePath.formatBytes(bytes.length)}. The editor opens '
      'files up to ${RemotePath.formatBytes(editorMaxFileBytes)} — download '
      'it instead.',
    );
  }
  if (looksBinary(bytes)) {
    throw EditorOpenRefused(
      EditorRefusal.binary,
      '"$name" is not a text file. Editing it here would corrupt it — '
      'download it instead.',
    );
  }

  // Two decodes, not one: `allowMalformed` is what we want to *keep*, and a
  // strict decode is the only way to find out whether it did anything. The
  // alternative — scanning the result for U+FFFD — accuses a file that
  // legitimately contains a replacement character of being broken.
  var invalid = false;
  try {
    utf8.decode(bytes);
  } on FormatException {
    invalid = true;
  }

  final raw = utf8.decode(bytes, allowMalformed: true);
  final endings = detectLineEndings(raw);
  return DecodedText(
    text: endings == LineEndingStyle.lf ? raw : raw.replaceAll('\r\n', '\n'),
    lineEndings: endings,
    hadInvalidUtf8: invalid,
  );
}

/// Puts [style]'s terminators back on and encodes for the wire.
///
/// [LineEndingStyle.mixed] resolves to LF: a file that was already
/// inconsistent has no style to preserve, and picking the one the rest of
/// the world defaults to beats preserving the inconsistency.
Uint8List encodeEditorText(String text, LineEndingStyle style) {
  final normalised = text.replaceAll('\r\n', '\n');
  final out = style == LineEndingStyle.crlf
      ? normalised.replaceAll('\n', '\r\n')
      : normalised;
  return Uint8List.fromList(utf8.encode(out));
}

/// Extensions and bare names that a plain tap should open for editing rather
/// than download.
///
/// Not the same question as "can the editor open this" — the editor will open
/// anything that sniffs as text. This is only about which action a tap picks
/// by default, so it stays a list of things that are text *by name*, and
/// anything not on it falls through to the browser's existing download-on-tap
/// behaviour.
const Set<String> _textishExtensions = {
  '.txt', '.md', '.markdown', '.rst', '.log', '.csv', '.tsv',
  '.json', '.yaml', '.yml', '.toml', '.ini', '.cfg', '.conf', '.properties',
  '.sh', '.bash', '.zsh', '.fish', '.profile', '.bashrc', '.env',
  '.py', '.rb', '.pl', '.lua', '.php', '.tcl',
  '.dart', '.js', '.mjs', '.cjs', '.ts', '.tsx', '.jsx',
  '.c', '.h', '.cc', '.cpp', '.hpp', '.java', '.kt', '.kts', '.go', '.rs',
  '.swift', '.cs', '.scala', '.ex', '.exs', '.erl', '.hs',
  '.html', '.htm', '.xml', '.xhtml', '.svg', '.css', '.scss', '.sass',
  '.less', '.vue', '.sql', '.graphql', '.proto',
  '.service', '.timer', '.socket', '.mount', '.target', '.rules',
  '.gitignore', '.gitattributes', '.gitconfig', '.editorconfig',
  '.patch', '.diff', '.lock', '.list', '.sources', '.repo', '.desktop',
};

/// Bare file names — no extension — that are text on sight.
const Set<String> _textishNames = {
  'dockerfile', 'containerfile', 'makefile', 'gnumakefile', 'rakefile',
  'gemfile', 'procfile', 'vagrantfile', 'jenkinsfile', 'brewfile',
  'cmakelists.txt', 'readme', 'license', 'licence', 'copying', 'authors',
  'changelog', 'notice', 'install', 'todo', 'version',
  'hosts', 'fstab', 'crontab', 'passwd', 'group', 'resolv.conf', 'sudoers',
  'known_hosts', 'authorized_keys', 'config', 'sshd_config', 'ssh_config',
  'nginx.conf', 'httpd.conf', 'apache2.conf', 'my.cnf', 'php.ini',
};

/// Whether [name] reads as a text file from its name alone.
bool isTextishName(String name) {
  final lower = name.toLowerCase();
  if (_textishNames.contains(lower)) return true;
  final ext = RemotePath.extension(lower);
  if (ext.isNotEmpty && _textishExtensions.contains(ext)) return true;
  // Dotfiles with no extension of their own — `.bashrc`, `.vimrc`,
  // `.zprofile`. `RemotePath.extension` reads the whole of `.bashrc` as the
  // extension, so the set above catches some of these already; this covers
  // the rest without enumerating every shell anyone has ever configured.
  if (lower.startsWith('.') && !lower.substring(1).contains('.')) return true;
  // `nginx.conf.bak`, `sshd_config.orig` — the meaningful extension is the
  // one before the editor/backup suffix.
  const backupSuffixes = {'.bak', '.orig', '.old', '.save', '.dpkg-dist'};
  if (backupSuffixes.contains(ext)) {
    return isTextishName(lower.substring(0, lower.length - ext.length));
  }
  return false;
}

/// Whether a plain tap on a file of this name and size should open the editor.
bool tapShouldEdit({required String name, int? size}) {
  if (size != null && size > editorTapToEditBytes) return false;
  return isTextishName(name);
}
