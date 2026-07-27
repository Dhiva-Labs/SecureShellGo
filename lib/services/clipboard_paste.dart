/// Pure helpers for deciding how a clipboard paste into the terminal should
/// be handled.
///
/// Kept free of Flutter imports, like the rest of `services/` — the actual
/// `Clipboard.getData` call and the confirmation sheet live in
/// `terminal_pane.dart`, but the "is this actually a multi-line paste"
/// question is plain string logic and is worth unit-testing without a
/// widget tree.
class ClipboardPaste {
  const ClipboardPaste._();

  /// The number of lines in [text].
  ///
  /// `\r\n` and a lone `\r` both count as one line break, so a clip copied on
  /// any platform is counted the same way. A single trailing line break does
  /// not count as an extra (empty) line — copying "ls\n" and pasting it is
  /// one command, not two — which is what makes [needsConfirmation] key off
  /// this rather than a raw `\n` count.
  static int lineCount(String text) {
    if (text.isEmpty) return 0;
    final normalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final lines = normalized.split('\n');
    if (lines.length > 1 && lines.last.isEmpty) lines.removeLast();
    return lines.isEmpty ? 1 : lines.length;
  }

  /// Whether pasting [text] straight into the shell deserves a "Paste N
  /// lines?" confirmation first, rather than running silently. A single line
  /// — even one that ends with a newline, which sends one command — is not
  /// a surprise; two or more distinct lines can each be its own command, and
  /// running several unseen commands in a row is the footgun this guards.
  static bool needsConfirmation(String text) => lineCount(text) > 1;
}
