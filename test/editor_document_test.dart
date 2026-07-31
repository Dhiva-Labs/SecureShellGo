import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/editor_document.dart';

Uint8List bytesOf(String text) => Uint8List.fromList(utf8.encode(text));

void main() {
  group('binary sniff', () {
    test('plain text is not binary', () {
      expect(looksBinary(bytesOf('#!/bin/sh\necho hello\n')), isFalse);
    });

    test('a NUL byte anywhere in the first 8 KB is binary', () {
      expect(looksBinary(Uint8List.fromList([0x7F, 0x45, 0x4C, 0x46, 0])),
          isTrue);
      // Right at the edge of the sniff window.
      final atLimit = Uint8List(editorBinarySniffBytes)
        ..fillRange(0, 100, 0x41);
      atLimit[editorBinarySniffBytes - 1] = 0;
      expect(looksBinary(atLimit), isTrue);
    });

    test('a NUL past the sniff window is not looked for', () {
      // The window is the contract, so this documents it rather than pretending
      // the check is exhaustive: a text file with a NUL 9 KB in gets opened.
      final late_ = Uint8List(editorBinarySniffBytes + 200)
        ..fillRange(0, editorBinarySniffBytes + 200, 0x41);
      late_[editorBinarySniffBytes + 100] = 0;
      expect(looksBinary(late_), isFalse);
    });

    test('multi-byte UTF-8 is not mistaken for binary', () {
      expect(looksBinary(bytesOf('héllo — 世界 🎉')), isFalse);
    });

    test('an empty file is not binary', () {
      expect(looksBinary(Uint8List(0)), isFalse);
    });
  });

  group('line endings', () {
    test('detects LF, CRLF and mixed', () {
      expect(detectLineEndings('a\nb\nc'), LineEndingStyle.lf);
      expect(detectLineEndings('a\r\nb\r\nc'), LineEndingStyle.crlf);
      expect(detectLineEndings('a\r\nb\nc'), LineEndingStyle.mixed);
    });

    test('a file with no newline at all reads as LF', () {
      expect(detectLineEndings('one line'), LineEndingStyle.lf);
      expect(detectLineEndings(''), LineEndingStyle.lf);
    });

    test('a lone CR is neither, so nothing is put back on save', () {
      expect(detectLineEndings('a\rb\rc'), LineEndingStyle.lf);
    });

    test('CRLF survives a round trip unchanged', () {
      const original = 'server {\r\n  listen 80;\r\n}\r\n';
      final decoded = decodeEditorText(bytesOf(original), name: 'nginx.conf');
      expect(decoded.lineEndings, LineEndingStyle.crlf);
      // The editor works in LF, so the caret can never land on a stray CR.
      expect(decoded.text, 'server {\n  listen 80;\n}\n');
      expect(
        utf8.decode(encodeEditorText(decoded.text, decoded.lineEndings)),
        original,
      );
    });

    test('LF survives a round trip unchanged', () {
      const original = 'one\ntwo\n';
      final decoded = decodeEditorText(bytesOf(original), name: 'a.txt');
      expect(decoded.lineEndings, LineEndingStyle.lf);
      expect(utf8.decode(encodeEditorText(decoded.text, decoded.lineEndings)),
          original);
    });

    test('mixed normalises to LF, which is what the save note says', () {
      const original = 'one\r\ntwo\nthree\r\n';
      final decoded = decodeEditorText(bytesOf(original), name: 'a.txt');
      expect(decoded.lineEndings, LineEndingStyle.mixed);
      expect(
        utf8.decode(encodeEditorText(decoded.text, decoded.lineEndings)),
        'one\ntwo\nthree\n',
      );
    });

    test('encoding never doubles a CR that is already there', () {
      // The editor holds LF, but a paste could have put a CRLF into the
      // buffer. Encoding to CRLF must not produce `\r\r\n`.
      expect(utf8.decode(encodeEditorText('a\r\nb', LineEndingStyle.crlf)),
          'a\r\nb');
    });
  });

  group('decoding', () {
    test('valid UTF-8 decodes without a warning', () {
      final decoded = decodeEditorText(bytesOf('héllo 世界'), name: 'a.txt');
      expect(decoded.hadInvalidUtf8, isFalse);
      expect(decoded.text, 'héllo 世界');
    });

    test('malformed bytes decode lossily and raise the flag', () {
      // 0xFF is not valid anywhere in UTF-8.
      final decoded = decodeEditorText(
        Uint8List.fromList([0x61, 0xFF, 0x62]),
        name: 'a.txt',
      );
      expect(decoded.hadInvalidUtf8, isTrue);
      expect(decoded.text, contains('�'));
      expect(decoded.text.startsWith('a'), isTrue);
    });

    test('a file that genuinely contains U+FFFD is not accused', () {
      // The reason the check is a strict decode rather than a scan for the
      // replacement character: this file is valid UTF-8 and must not be
      // reported as broken.
      final decoded = decodeEditorText(bytesOf('a � b'), name: 'a.txt');
      expect(decoded.hadInvalidUtf8, isFalse);
    });

    test('a file over the cap is refused, with the reason', () {
      final big = Uint8List(editorMaxFileBytes + 1);
      expect(
        () => decodeEditorText(big, name: 'huge.log'),
        throwsA(isA<EditorOpenRefused>()
            .having((e) => e.reason, 'reason', EditorRefusal.tooLarge)
            .having((e) => e.message, 'message', contains('huge.log'))),
      );
    });

    test('a binary file is refused, with the reason', () {
      expect(
        () => decodeEditorText(
          Uint8List.fromList([0x7F, 0x45, 0x4C, 0x46, 0x00, 0x01]),
          name: 'a.out',
        ),
        throwsA(isA<EditorOpenRefused>()
            .having((e) => e.reason, 'reason', EditorRefusal.binary)
            .having((e) => e.message, 'message', contains('a.out'))),
      );
    });

    test('a file exactly at the cap is allowed', () {
      final atCap = Uint8List(editorMaxFileBytes)
        ..fillRange(0, editorMaxFileBytes, 0x41);
      expect(() => decodeEditorText(atCap, name: 'edge.txt'), returnsNormally);
    });
  });

  group('which files a tap opens for editing', () {
    test('recognises text by extension', () {
      expect(isTextishName('nginx.conf'), isTrue);
      expect(isTextishName('main.dart'), isTrue);
      expect(isTextishName('README.md'), isTrue);
      expect(isTextishName('data.json'), isTrue);
      expect(isTextishName('script.sh'), isTrue);
    });

    test('recognises text by bare name', () {
      expect(isTextishName('Dockerfile'), isTrue);
      expect(isTextishName('Makefile'), isTrue);
      expect(isTextishName('fstab'), isTrue);
      expect(isTextishName('authorized_keys'), isTrue);
    });

    test('recognises a dotfile with no extension of its own', () {
      expect(isTextishName('.bashrc'), isTrue);
      expect(isTextishName('.vimrc'), isTrue);
      expect(isTextishName('.zprofile'), isTrue);
    });

    test('sees through a backup suffix', () {
      expect(isTextishName('nginx.conf.bak'), isTrue);
      expect(isTextishName('sshd_config.orig'), isTrue);
    });

    test('does not claim binaries', () {
      expect(isTextishName('photo.jpg'), isFalse);
      expect(isTextishName('archive.tar.gz'), isFalse);
      expect(isTextishName('app.apk'), isFalse);
      expect(isTextishName('libthing.so'), isFalse);
    });

    test('a large text file still downloads on tap', () {
      // The editor would open it; a tap should not, because the tap was
      // probably meant for the row and not for a megabyte of transfer.
      expect(tapShouldEdit(name: 'huge.log', size: editorTapToEditBytes + 1),
          isFalse);
      expect(tapShouldEdit(name: 'huge.log', size: editorTapToEditBytes),
          isTrue);
    });

    test('an unknown size does not block the tap', () {
      expect(tapShouldEdit(name: 'notes.md', size: null), isTrue);
    });

    test('a binary of any size never taps into the editor', () {
      expect(tapShouldEdit(name: 'photo.jpg', size: 100), isFalse);
    });
  });
}
