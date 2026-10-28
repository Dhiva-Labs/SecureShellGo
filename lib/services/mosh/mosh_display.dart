import 'mosh_terminal.dart';

/// Draws Mosh screen states into a real terminal — here, xterm's `Terminal` —
/// as the smallest run of escape sequences that turns the last frame drawn
/// into the next. A port of Mosh's `Terminal::Display`
/// (`terminaldisplay.cc`), which is what Mosh's own client draws with.
///
/// It is the server's diff format too, but that is not why it is used here:
/// Mosh's display code has been tuned against real terminals for a decade —
/// it scrolls with real line feeds so lines go into the scrollback, it keeps
/// wrapped lines wrapped for copy and paste, and it never leaves the cursor
/// pending on the last column — and xterm is one of the terminals it was
/// tuned against.
///
/// Every capability Mosh probes terminfo for (ECH, BCE, titles) xterm has.
/// The alternate screen Mosh switches to on start-up is left alone, so that
/// the scrollback keeps what scrolled off.
class MoshDisplay {
  const MoshDisplay();

  /// Sent once before the first frame: application cursor keys, which the
  /// server's terminal translates back when its program wants normal ones.
  static const open = '\x1b[?1h';

  /// Puts every mode Mosh may have changed back as a plain shell expects.
  static const close =
      '\x1b[?1l\x1b[0m\x1b[?25h'
      '\x1b[?1003l\x1b[?1002l\x1b[?1001l\x1b[?1000l'
      '\x1b[?1015l\x1b[?1006l\x1b[?1005l\x1b[?2004l\x1b[?1004l\x1b[?5l';

  /// The output that turns a terminal showing [last] into one showing [next].
  /// With [initialized] false nothing is assumed about the terminal and the
  /// whole screen is drawn.
  String newFrame(bool initialized, MoshFramebuffer last, MoshFramebuffer f) {
    final frame = _FrameState(last);

    if (f.bellCount != frame.lastFrame.bellCount) frame.append('\x07');

    if (f.titleInitialized &&
        (!initialized ||
            !_sameCodes(f.iconName, frame.lastFrame.iconName) ||
            !_sameCodes(f.windowTitle, frame.lastFrame.windowTitle))) {
      if (_sameCodes(f.iconName, f.windowTitle)) {
        frame
          ..append('\x1b]0;')
          ..appendCodes(f.windowTitle)
          ..append('\x07');
      } else {
        frame
          ..append('\x1b]1;')
          ..appendCodes(f.iconName)
          ..append('\x07')
          ..append('\x1b]2;')
          ..appendCodes(f.windowTitle)
          ..append('\x07');
      }
    }

    if (!_sameCodes(f.clipboard, frame.lastFrame.clipboard)) {
      frame
        ..append('\x1b]52;c;')
        ..appendCodes(f.clipboard)
        ..append('\x07');
    }

    if (!initialized || f.ds.reverseVideo != frame.lastFrame.ds.reverseVideo) {
      frame.append(f.ds.reverseVideo ? '\x1b[?5h' : '\x1b[?5l');
    }

    if (!initialized ||
        f.ds.width != frame.lastFrame.ds.width ||
        f.ds.height != frame.lastFrame.ds.height) {
      frame
        ..append('\x1b[r')
        ..append('\x1b[0m\x1b[H\x1b[2J');
      initialized = false;
      frame.cursorX = frame.cursorY = 0;
      frame.currentRendition = const MoshRenditions();
    } else {
      frame.cursorX = frame.lastFrame.ds.cursorCol;
      frame.cursorY = frame.lastFrame.ds.cursorRow;
      frame.currentRendition = frame.lastFrame.ds.renditions;
    }

    if (!initialized) {
      frame.cursorVisible = false;
      frame.append('\x1b[?25l');
    }

    var frameY = 0;
    MoshRow? blankRow;
    final rows = List<MoshRow>.of(frame.lastFrame.rows);
    if (frame.lastFrame.ds.width < f.ds.width) {
      for (var i = 0; i < rows.length; i++) {
        final wider = rows[i].copy();
        while (wider.cells.length < f.ds.width) {
          wider.cells.add(MoshCell(f.ds.backgroundRendition));
        }
        rows[i] = wider;
      }
    }
    if (rows.length < f.ds.height) {
      blankRow = MoshRow(f.ds.width, 0);
      while (rows.length < f.ds.height) {
        rows.add(blankRow);
      }
    }

    // Has the display moved up by some number of lines?
    if (initialized) {
      var linesScrolled = 0;
      var scrollHeight = 0;
      for (var row = 0; row < f.ds.height; row++) {
        if (!f.rows[0].sameAs(rows[row])) continue;
        // Row 0 matching itself is no scroll at all.
        if (row == 0) break;
        linesScrolled = row;
        scrollHeight = 1;
        for (
          var regionHeight = 1;
          linesScrolled + regionHeight < f.ds.height;
          regionHeight++
        ) {
          if (f.rows[regionHeight].sameAs(rows[linesScrolled + regionHeight])) {
            scrollHeight = regionHeight + 1;
          } else {
            break;
          }
        }
        break;
      }

      if (scrollHeight > 0) {
        frameY = scrollHeight;
        if (linesScrolled > 0) {
          blankRow ??= MoshRow(f.ds.width, 0);
          frame.updateRendition(const MoshRenditions(), force: true);
          const topMargin = 0;
          final bottomMargin = topMargin + linesScrolled + scrollHeight - 1;
          if (scrollHeight + linesScrolled == f.ds.height &&
              frame.cursorY + 1 == f.ds.height) {
            // Already on the bottom line and scrolling the whole screen: a
            // carriage return and line feeds, which push what scrolls off
            // into the scrollback.
            frame
              ..append('\r')
              ..append('\n' * linesScrolled);
            frame.cursorX = 0;
          } else {
            frame.append('\x1b[${topMargin + 1};${bottomMargin + 1}r');
            frame.cursorX = frame.cursorY = -1;
            frame.appendSilentMove(bottomMargin, 0);
            frame
              ..append('\n' * linesScrolled)
              ..append('\x1b[r');
            frame.cursorX = frame.cursorY = -1;
          }
          for (var i = topMargin; i <= bottomMargin; i++) {
            rows[i] = i + linesScrolled <= bottomMargin
                ? rows[i + linesScrolled]
                : blankRow;
          }
        }
      }
    }

    var wrap = false;
    for (; frameY < f.ds.height; frameY++) {
      wrap = _putRow(initialized, frame, f, frameY, rows[frameY], wrap);
    }

    if (!initialized ||
        f.ds.cursorRow != frame.cursorY ||
        f.ds.cursorCol != frame.cursorX) {
      frame.appendMove(f.ds.cursorRow, f.ds.cursorCol);
    }

    if (!initialized || f.ds.cursorVisible != frame.cursorVisible) {
      frame.append(f.ds.cursorVisible ? '\x1b[?25h' : '\x1b[?25l');
    }

    frame.updateRendition(f.ds.renditions, force: !initialized);

    if (!initialized ||
        f.ds.bracketedPaste != frame.lastFrame.ds.bracketedPaste) {
      frame.append(f.ds.bracketedPaste ? '\x1b[?2004h' : '\x1b[?2004l');
    }

    if (!initialized ||
        f.ds.mouseReportingMode != frame.lastFrame.ds.mouseReportingMode) {
      if (f.ds.mouseReportingMode == MoshMouseReporting.none) {
        frame.append('\x1b[?1003l\x1b[?1002l\x1b[?1001l\x1b[?1000l');
      } else {
        if (frame.lastFrame.ds.mouseReportingMode != MoshMouseReporting.none) {
          frame.append('\x1b[?${frame.lastFrame.ds.mouseReportingMode}l');
        }
        frame.append('\x1b[?${f.ds.mouseReportingMode}h');
      }
    }

    if (!initialized ||
        f.ds.mouseFocusEvent != frame.lastFrame.ds.mouseFocusEvent) {
      frame.append(f.ds.mouseFocusEvent ? '\x1b[?1004h' : '\x1b[?1004l');
    }

    if (!initialized ||
        f.ds.mouseEncodingMode != frame.lastFrame.ds.mouseEncodingMode) {
      if (f.ds.mouseEncodingMode == MoshMouseEncoding.standard) {
        frame.append('\x1b[?1015l\x1b[?1006l\x1b[?1005l');
      } else {
        if (frame.lastFrame.ds.mouseEncodingMode !=
            MoshMouseEncoding.standard) {
          frame.append('\x1b[?${frame.lastFrame.ds.mouseEncodingMode}l');
        }
        frame.append('\x1b[?${f.ds.mouseEncodingMode}h');
      }
    }

    return frame.out.toString();
  }

  bool _putRow(
    bool initialized,
    _FrameState frame,
    MoshFramebuffer f,
    int frameY,
    MoshRow oldRow,
    bool wrap,
  ) {
    var frameX = 0;
    final row = f.rows[frameY];
    final cells = row.cells;
    final oldCells = oldRow.cells;

    // Forced to write the first column because the last row wrapped into it.
    if (wrap) {
      final cell = cells[0];
      frame.updateRendition(cell.renditions);
      frame.appendCell(cell);
      frameX += cell.width;
      frame.cursorX += cell.width;
    }

    if (initialized && identical(row, oldRow)) return false;

    final wrapThis = row.wrap;
    final rowWidth = f.ds.width;
    var clearCount = 0;
    var wroteLastCell = false;
    var blankRenditions = const MoshRenditions();

    while (frameX < rowWidth) {
      final cell = cells[frameX];

      if (initialized &&
          clearCount == 0 &&
          frameX < oldCells.length &&
          cell.sameAs(oldCells[frameX])) {
        frameX += cell.width;
        continue;
      }

      if (cell.isEmpty) {
        if (clearCount == 0) blankRenditions = cell.renditions;
        if (cell.renditions == blankRenditions) {
          clearCount++;
          frameX++;
          continue;
        }
      }

      if (clearCount > 0) {
        frame.appendSilentMove(frameY, frameX - clearCount);
        frame.updateRendition(blankRenditions);
        if (clearCount > 4) {
          frame.append('\x1b[${clearCount}X');
        } else {
          frame.append(' ' * clearCount);
          frame.cursorX = frameX;
        }
        clearCount = 0;
        if (cell.isEmpty) {
          blankRenditions = cell.renditions;
          clearCount = 1;
          frameX++;
          continue;
        }
      }

      final cellWidth = cell.width;
      // About to print the last character of a wrapping row: position
      // explicitly, since the terminal's cursor may be pending on the
      // column past the end.
      if (wrapThis && frameX + cellWidth >= rowWidth) {
        frame.cursorX = frame.cursorY = -1;
      }
      frame.appendSilentMove(frameY, frameX);
      frame.updateRendition(cell.renditions);
      if (cell.wide && frameX + 1 >= rowWidth) {
        // Inserted cells can push a wide character into the last column,
        // where no terminal can draw it: Mosh's display would wrap it onto
        // the next row. A blank keeps every other cell in place.
        frame.append(' ');
        frameX++;
        frame.cursorX++;
      } else {
        frame.appendCell(cell);
        frameX += cellWidth;
        frame.cursorX += cellWidth;
      }
      if (frameX >= rowWidth) wroteLastCell = true;
    }

    if (clearCount > 0) {
      frame.appendSilentMove(frameY, frameX - clearCount);
      frame.updateRendition(blankRenditions);
      if (!wrapThis) {
        frame.append('\x1b[K');
      } else {
        frame.append(' ' * clearCount);
        frame.cursorX = frameX;
        wroteLastCell = true;
      }
    }

    if (wroteLastCell && frameY == f.ds.height - 1) {
      // The terminal's cursor now waits on the last column, not one past it
      // as the count above has it, and a backspace from there lands one
      // column short. Mosh moves relatively from here; position absolutely
      // instead. (Only this drawing side differs from Mosh: what the server
      // sends is applied exactly as Mosh applies it.)
      frame.cursorX = frame.cursorY = -1;
    }
    if (!(wroteLastCell && frameY < f.ds.height - 1)) return false;

    // Let the terminal's own cursor wrap where the text wrapped, so a
    // word-select or copy joins the two rows.
    if (wrapThis) {
      frame.cursorX = 0;
      frame.cursorY++;
      return true;
    }
    frame.append('\r\n');
    frame.cursorX = 0;
    frame.cursorY++;
    return false;
  }

  static bool _sameCodes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

class _FrameState {
  _FrameState(this.lastFrame) : cursorVisible = lastFrame.ds.cursorVisible;

  final MoshFramebuffer lastFrame;
  final out = StringBuffer();
  var cursorX = 0;
  var cursorY = 0;
  var currentRendition = const MoshRenditions();
  bool cursorVisible;

  void append(String s) => out.write(s);

  void appendCodes(List<int> codes) => out.write(String.fromCharCodes(codes));

  void appendCell(MoshCell cell) => cell.printGrapheme(out);

  void appendSilentMove(int y, int x) {
    if (cursorX == x && cursorY == y) return;
    // Hide the cursor while it travels.
    if (cursorVisible) {
      append('\x1b[?25l');
      cursorVisible = false;
    }
    appendMove(y, x);
  }

  void appendMove(int y, int x) {
    final lastX = cursorX;
    final lastY = cursorY;
    cursorX = x;
    cursorY = y;
    if (lastX != -1 && lastY != -1) {
      if (x == 0 && y - lastY >= 0 && y - lastY < 5) {
        if (lastX != 0) append('\r');
        append('\n' * (y - lastY));
        return;
      }
      if (y == lastY && x - lastX < 0 && x - lastX > -5) {
        append('\b' * (lastX - x));
        return;
      }
    }
    append('\x1b[${y + 1};${x + 1}H');
  }

  void updateRendition(MoshRenditions r, {bool force = false}) {
    if (force || currentRendition != r) {
      append(r.sgr());
      currentRendition = r;
    }
  }
}
