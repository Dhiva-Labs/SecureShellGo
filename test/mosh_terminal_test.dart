import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/mosh/mosh_display.dart';
import 'package:secure_shell_go/services/mosh/mosh_protobuf.dart';
import 'package:secure_shell_go/services/mosh/mosh_terminal.dart';
import 'package:xterm/core.dart';

/// The port of Mosh's terminal: how escape sequences change a framebuffer,
/// and how the display turns one framebuffer into another.
void main() {
  MoshFramebuffer screen(int width, int height, [String input = '']) {
    final fb = MoshFramebuffer(width, height);
    MoshEmulator(fb).writeString(input);
    return fb;
  }

  String rowText(MoshFramebuffer fb, int y) => fb.rows[y].cells
      .map((c) => c.contents.isEmpty ? ' ' : c.contents)
      .join()
      .trimRight();

  ({int row, int col}) cursor(MoshFramebuffer fb) =>
      (row: fb.ds.cursorRow, col: fb.ds.cursorCol);

  group('emulator', () {
    test('text wraps at the margin, marking the row as wrapped', () {
      final fb = screen(5, 3, 'abcdefg');
      expect(rowText(fb, 0), 'abcde');
      expect(fb.rows[0].wrap, isTrue);
      expect(rowText(fb, 1), 'fg');
      expect(cursor(fb), (row: 1, col: 2));
    });

    test('after the last column the cursor waits there, and a CR or a '
        'backspace cancels the wrap', () {
      final fb = screen(5, 3, 'abcde');
      expect(cursor(fb), (row: 0, col: 4));
      expect(fb.ds.nextPrintWillWrap, isTrue);
      MoshEmulator(fb).writeString('\bX');
      expect(rowText(fb, 0), 'abcXe');
      expect(rowText(fb, 1), '');
    });

    test('a wide character takes two cells, and wraps rather than split', () {
      final fb = screen(5, 2, 'abcd漢');
      expect(rowText(fb, 0), 'abcd');
      expect(fb.rows[0].wrap, isFalse);
      expect(fb.rows[1].cells[0].contents, '漢');
      expect(fb.rows[1].cells[0].wide, isTrue);
      expect(cursor(fb), (row: 1, col: 2));
    });

    test('combining characters join the cell before them', () {
      final fb = screen(10, 2, 'éx\r\ń');
      expect(fb.rows[0].cells[0].contents, 'é');
      expect(fb.rows[0].cells[1].contents, 'x');
      expect(fb.rows[1].cells[0].contents, '́');
      expect(fb.rows[1].cells[0].fallback, isTrue);
    });

    test('cursor movement is clamped to the screen', () {
      final fb = screen(10, 5, '\x1b[3;4H');
      expect(cursor(fb), (row: 2, col: 3));
      MoshEmulator(fb).writeString('\x1b[99B\x1b[99C');
      expect(cursor(fb), (row: 4, col: 9));
      MoshEmulator(fb).writeString('\x1b[2A\x1b[3D');
      expect(cursor(fb), (row: 2, col: 6));
      MoshEmulator(fb).writeString('\x1b[H');
      expect(cursor(fb), (row: 0, col: 0));
    });

    test('erasing keeps the current background, as Mosh assumes BCE', () {
      final fb = screen(10, 3, 'abcdefghij\x1b[1;3H\x1b[44m\x1b[3X');
      expect(rowText(fb, 0), 'ab   fghij');
      expect(fb.rows[0].cells[2].renditions.background, 44);
      MoshEmulator(fb).writeString('\x1b[1;8H\x1b[K');
      expect(rowText(fb, 0), 'ab   fg');
      expect(fb.rows[0].cells[9].renditions.background, 44);
      MoshEmulator(fb).writeString('\x1b[1;2H\x1b[1K');
      expect(rowText(fb, 0), '     fg');
      MoshEmulator(fb).writeString('\x1b[2J');
      expect([rowText(fb, 0), rowText(fb, 1)], ['', '']);
    });

    test('a scrolling region scrolls only itself', () {
      final fb = screen(5, 5, 'a\r\nb\r\nc\r\nd\r\ne');
      MoshEmulator(fb).writeString('\x1b[2;4r\x1b[4;1H\nX');
      expect(
        [for (var y = 0; y < 5; y++) rowText(fb, y)],
        ['a', 'c', 'd', 'X', 'e'],
      );
      // Reverse index at the top of the region scrolls it down.
      MoshEmulator(fb).writeString('\x1b[2;1H\x1bMY');
      expect(
        [for (var y = 0; y < 5; y++) rowText(fb, y)],
        ['a', 'Y', 'c', 'd', 'e'],
      );
    });

    test('insert and delete lines and characters', () {
      final fb = screen(5, 4, 'a\r\nb\r\nc\r\nd');
      MoshEmulator(fb).writeString('\x1b[2;1H\x1b[L');
      expect([for (var y = 0; y < 4; y++) rowText(fb, y)], ['a', '', 'b', 'c']);
      MoshEmulator(fb).writeString('\x1b[1;1H\x1b[2M');
      expect([for (var y = 0; y < 4; y++) rowText(fb, y)], ['b', 'c', '', '']);
      MoshEmulator(fb).writeString('\x1b[4;1Hwxyz\x1b[4;2H\x1b[2P');
      expect(rowText(fb, 3), 'wz');
      MoshEmulator(fb).writeString('\x1b[4;1H\x1b[2@');
      expect(rowText(fb, 3), '  wz');
    });

    test('colours, as Mosh encodes and re-emits them', () {
      final fb = screen(
        10,
        1,
        '\x1b[1;4;31;42ma\x1b[0;95mb\x1b[38;5;200;48;5;17mc\x1b[38;2;1;2;3md',
      );
      final cells = fb.rows[0].cells;
      expect(cells[0].renditions.sgr(), '\x1b[0;1;4;31;42m');
      expect(cells[1].renditions.sgr(), '\x1b[0;38;5;13m');
      expect(cells[2].renditions.sgr(), '\x1b[0;38;5;200;48;5;17m');
      expect(cells[3].renditions.sgr(), '\x1b[0;38;2;1;2;3;48;5;17m');
    });

    test('titles, modes, bell and the clipboard', () {
      final fb = screen(
        10,
        2,
        '\x1b]0;both\x07\x1b[?25l\x1b[?2004h\x1b[?1002h\x1b[?1006h\x07'
        '\x1b]52;c;aGk=\x07',
      );
      expect(String.fromCharCodes(fb.windowTitle), 'both');
      expect(String.fromCharCodes(fb.iconName), 'both');
      expect(fb.ds.cursorVisible, isFalse);
      expect(fb.ds.bracketedPaste, isTrue);
      expect(fb.ds.mouseReportingMode, 1002);
      expect(fb.ds.mouseEncodingMode, 1006);
      expect(fb.bellCount, 1);
      expect(String.fromCharCodes(fb.clipboard), 'aGk=');
      MoshEmulator(fb).writeString('\x1b]2;title only\x1b\\\x1b[?1002l');
      expect(String.fromCharCodes(fb.windowTitle), 'title only');
      expect(String.fromCharCodes(fb.iconName), 'both');
      expect(fb.ds.mouseReportingMode, 0);
    });

    test('a copy shares rows until one side writes', () {
      final original = screen(5, 2, 'ab\r\ncd');
      final copy = original.copy();
      expect(identical(copy.rows[0], original.rows[0]), isTrue);
      MoshEmulator(copy).writeString('\x1b[1;1HX');
      expect(rowText(copy, 0), 'Xb');
      expect(rowText(original, 0), 'ab');
      MoshEmulator(original).writeString('\x1b[2;1HY');
      expect(rowText(original, 1), 'Yd');
      expect(rowText(copy, 1), 'cd');
      expect(identical(copy.rows[1], original.rows[1]), isFalse);
    });

    test('a host message applies bytes, resize and echo ack', () {
      final state = MoshTerminalState(10, 3);
      state.applyDiff(
        HostMessageCodec.encode([
          const HostInstruction(resize: (width: 12, height: 4)),
          HostInstruction(hostBytes: Uint8List.fromList(utf8.encode('héllo'))),
          const HostInstruction(echoAck: 7),
        ]),
      );
      expect(state.fb.ds.width, 12);
      expect(state.fb.ds.height, 4);
      expect(rowText(state.fb, 0), 'héllo');
      expect(state.echoAck, 7);
    });
  });

  group('display', () {
    const display = MoshDisplay();

    /// What Mosh checks in verbose mode: applying a frame's diff to the old
    /// screen yields the new one.
    void expectRoundTrip(
      MoshFramebuffer from,
      MoshFramebuffer to, {
      bool initialized = true,
    }) {
      final diff = display.newFrame(initialized, from, to);
      // The terminal as the last frame left it: every frame ends with an
      // explicit cursor move, so it never starts one waiting to wrap.
      final applied = from.copy()..ds.nextPrintWillWrap = false;
      MoshEmulator(applied).writeString(diff);
      for (var y = 0; y < to.ds.height; y++) {
        for (var x = 0; x < to.ds.width; x++) {
          // A cell under the right half of a wide character is never drawn
          // — Mosh's display steps over it, as a terminal does.
          if (x > 0 && to.rows[y].cells[x - 1].wide) continue;
          // Nor can a wide character in the last column be; it is drawn as
          // a blank (see MoshDisplay).
          MoshCell visible(MoshCell c) => c.wide && x == to.ds.width - 1
              ? (c.copy()
                  ..contents = ' '
                  ..wide = false)
              : c;
          final want = visible(to.rows[y].cells[x]);
          final got = visible(applied.rows[y].cells[x]);
          expect(
            (got.contents.isEmpty ? ' ' : got.contents, got.renditions),
            (want.contents.isEmpty ? ' ' : want.contents, want.renditions),
            reason: 'cell ($y, $x) after ${jsonEncode(diff)}',
          );
        }
      }
      expect(cursor(applied), cursor(to), reason: jsonEncode(diff));
      expect(applied.ds.cursorVisible, to.ds.cursorVisible);
    }

    test('identical screens need no output', () {
      final fb = screen(10, 3, 'hello');
      expect(display.newFrame(true, fb, fb.copy()), isEmpty);
    });

    test('a first frame draws everything from a cleared screen', () {
      final fb = screen(10, 3, '\x1b[1mhi\x1b[0m\r\nthere\x1b[?25l');
      final diff = display.newFrame(false, MoshFramebuffer(10, 3), fb);
      expect(diff, startsWith('\x1b[?5l\x1b[r\x1b[0m\x1b[H\x1b[2J'));
      expectRoundTrip(MoshFramebuffer(10, 3), fb, initialized: false);
    });

    test('scrolling the whole screen at the bottom is CR and line feeds', () {
      final before = screen(10, 4, '1\r\n2\r\n3\r\n4');
      final after = before.copy();
      MoshEmulator(after).writeString('\r\n5\r\n6');
      final diff = display.newFrame(true, before, after);
      expect(diff, startsWith('\x1b[0m\r\n\n'));
      expectRoundTrip(before, after);
    });

    test('a random walk of edits always round-trips', () {
      for (final seed in [7, 8, 9]) {
        final random = Random(seed);
        String randomEdit() {
          final parts = <String>[];
          for (var i = random.nextInt(6); i >= 0; i--) {
            switch (random.nextInt(18)) {
              case 14:
                parts.add('\t');
              case 15:
                parts.add('\x1b[4hq\x1b[4l');
              case 16:
                parts.add('\x1b7\x1b[5;5Hz\x1b8');
              case 17:
                parts.add('\x1bD\x1bM\x1bE');
              case 0:
                parts.add(
                  '\x1b[${random.nextInt(9) + 1};${random.nextInt(14) + 1}H',
                );
              case 1:
                parts.add(
                  String.fromCharCodes(
                    List.generate(
                      random.nextInt(20),
                      (_) => 0x61 + random.nextInt(26),
                    ),
                  ),
                );
              case 2:
                parts.add('\r\n');
              case 3:
                parts.add(
                  '\x1b[${[0, 1, 4, 7, 31, 42, 93, 104][random.nextInt(8)]}m',
                );
              case 4:
                parts.add('\x1b[${random.nextInt(3)}K');
              case 5:
                parts.add('\x1b[${random.nextInt(4) + 1}X');
              case 6:
                parts.add('漢字');
              case 7:
                parts.add('é');
              case 8:
                parts.add('\x1b[38;5;${random.nextInt(256)}m');
              case 9:
                parts.add('\x1b[${random.nextInt(3) + 1}M');
              case 10:
                parts.add('\x1b[${random.nextInt(3) + 1}L');
              case 11:
                parts.add('\x1b[?25${random.nextBool() ? 'h' : 'l'}');
              case 12:
                parts.add('\x1b[2;7r\x1b[7;1H\n\n\x1b[r');
              case 13:
                parts.add('\x1b[0J');
            }
          }
          return parts.join();
        }

        var current = screen(14, 9);
        for (var step = 0; step < 600; step++) {
          final next = current.copy();
          MoshEmulator(next).writeString(randomEdit());
          expectRoundTrip(current, next);
          current = next;
        }
      }
    });

    test('what xterm shows is what the framebuffer holds', () {
      final fb = screen(
        12,
        4,
        'plain\r\n\x1b[1;31mred\x1b[0m 漢字\r\nabcdefghijklmno\x1b[2;3H',
      );
      final terminal = Terminal()..resize(12, 4);
      terminal.write(display.newFrame(false, MoshFramebuffer(12, 4), fb));
      String xtermRow(int y) => terminal.buffer.lines[y].toString().trimRight();
      expect(xtermRow(0), rowText(fb, 0));
      expect(xtermRow(1), 'red 漢字');
      expect(xtermRow(2), 'abcdefghijkl');
      expect(xtermRow(3), 'mno');
      expect(terminal.buffer.cursorY, 1);
      expect(terminal.buffer.cursorX, 2);
    });
  });
}
