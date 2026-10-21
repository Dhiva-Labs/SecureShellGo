import 'dart:convert';
import 'dart:typed_data';

// The width table xterm draws with. Mosh's server measures characters with
// its C library's wcwidth(), which nothing on this side can call; the next
// best thing is the table the screen itself uses, so that what this model
// thinks is two cells wide is what xterm draws two cells wide.
// ignore: implementation_imports
import 'package:xterm/src/utils/unicode_v11.dart' show unicodeV11;

import 'mosh_protobuf.dart';

/// Mosh's model of a terminal screen, ported from `src/terminal/` of Mosh
/// 1.4.0 — framebuffer, draw state and the escape-sequence parser.
///
/// **Why a second terminal emulator.** The server never sends the shell's
/// output. It sends the *difference* between two of its own screen states,
/// written as escape sequences that only mean the right thing when applied to
/// an emulator that interprets them exactly as Mosh's does — the same wrap
/// rule, the same idea of where the cursor is after the last column, the
/// same erase colours. And it sends them relative to whichever earlier state
/// it believes the client has, which need not be the newest one, so the
/// client must keep several complete screens and copy them cheaply. xterm's
/// `Terminal` can do neither, so this keeps the screens and xterm only ever
/// draws the result (see `mosh_display.dart`).
///
/// It is deliberately a port, not a reimplementation: names, quirks and
/// order of operations follow the C++ so the two can be read side by side.

/// How many cells [codePoint] occupies: 1, 2, 0 for a combining character,
/// -1 for one that is not printed at all.
int moshCharWidth(int codePoint) {
  if (codePoint == 0) return -1;
  if (_isPrintIso8859_1(codePoint)) return 1;
  if (codePoint < 0x20 || (codePoint >= 0x7f && codePoint < 0xa0)) return -1;
  if (codePoint >= 0xd800 && codePoint <= 0xdfff) return -1;
  if (codePoint > 0x10ffff) return -1;
  return unicodeV11.wcwidth(codePoint);
}

bool _isPrintIso8859_1(int c) =>
    (c <= 0xff && c >= 0xa0) || (c <= 0x7e && c >= 0x20);

/// Colours and attributes of a cell, or of what is about to be printed.
///
/// Colours use Mosh's encoding: 0 is the default, 30–37 / 40–47 the eight
/// ANSI colours, 30+n / 40+n the 256-colour palette entry n, and a value
/// with bit 24 set a 24-bit RGB colour.
class MoshRenditions {
  const MoshRenditions({
    this.foreground = 0,
    this.background = 0,
    this.attributes = 0,
  });

  static const bold = 0;
  static const faint = 1;
  static const italic = 2;
  static const underlined = 3;
  static const blink = 4;
  static const inverse = 5;
  static const invisible = 6;

  static const _trueColorMask = 0x1000000;

  final int foreground;
  final int background;
  final int attributes;

  static int makeTrueColor(int r, int g, int b) =>
      _trueColorMask | ((r & 0xff) << 16) | ((g & 0xff) << 8) | (b & 0xff);

  static bool isTrueColor(int color) => color & _trueColorMask != 0;

  bool attribute(int attr) => attributes & (1 << attr) != 0;

  MoshRenditions withAttribute(int attr, bool value) => MoshRenditions(
    foreground: foreground,
    background: background,
    attributes: value
        ? (attributes | (1 << attr))
        : (attributes & ~(1 << attr)) & 0xff,
  );

  MoshRenditions _with({int? foreground, int? background, int? attributes}) =>
      MoshRenditions(
        foreground: foreground ?? this.foreground,
        background: background ?? this.background,
        attributes: attributes ?? this.attributes,
      );

  /// One SGR parameter outside the 256-colour and RGB forms.
  MoshRenditions withRendition(int num) {
    if (num == 0) return const MoshRenditions();
    if (num == 39) return _with(foreground: 0);
    if (num == 49) return _with(background: 0);
    if (30 <= num && num <= 37) return _with(foreground: num);
    if (40 <= num && num <= 47) return _with(background: num);
    if (90 <= num && num <= 97) return _with(foreground: num - 90 + 38);
    if (100 <= num && num <= 107) return _with(background: num - 100 + 48);
    final value = num < 9;
    switch (num) {
      case 1:
      case 22:
        return withAttribute(bold, value);
      case 3:
      case 23:
        return withAttribute(italic, value);
      case 4:
      case 24:
        return withAttribute(underlined, value);
      case 5:
      case 25:
        return withAttribute(blink, value);
      case 7:
      case 27:
        return withAttribute(inverse, value);
      case 8:
      case 28:
        return withAttribute(invisible, value);
      default:
        return this;
    }
  }

  MoshRenditions withForegroundColor(int num) {
    if (0 <= num && num <= 255) return _with(foreground: 30 + num);
    if (isTrueColor(num)) return _with(foreground: num & 0x1ffffff);
    return this;
  }

  MoshRenditions withBackgroundColor(int num) {
    if (0 <= num && num <= 255) return _with(background: 40 + num);
    if (isTrueColor(num)) return _with(background: num & 0x1ffffff);
    return this;
  }

  /// The SGR sequence that selects exactly these renditions from scratch.
  String sgr() {
    final out = StringBuffer('\x1b[0');
    if (attribute(bold)) out.write(';1');
    if (attribute(italic)) out.write(';3');
    if (attribute(underlined)) out.write(';4');
    if (attribute(blink)) out.write(';5');
    if (attribute(inverse)) out.write(';7');
    if (attribute(invisible)) out.write(';8');
    if (foreground != 0) {
      if (isTrueColor(foreground)) {
        out.write(
          ';38;2;${(foreground >> 16) & 0xff};'
          '${(foreground >> 8) & 0xff};${foreground & 0xff}',
        );
      } else if (foreground > 37) {
        out.write(';38;5;${foreground - 30}');
      } else {
        out.write(';$foreground');
      }
    }
    if (background != 0) {
      if (isTrueColor(background)) {
        out.write(
          ';48;2;${(background >> 16) & 0xff};'
          '${(background >> 8) & 0xff};${background & 0xff}',
        );
      } else if (background > 47) {
        out.write(';48;5;${background - 40}');
      } else {
        out.write(';$background');
      }
    }
    out.write('m');
    return out.toString();
  }

  @override
  bool operator ==(Object other) =>
      other is MoshRenditions &&
      other.attributes == attributes &&
      other.foreground == foreground &&
      other.background == background;

  @override
  int get hashCode => Object.hash(foreground, background, attributes);
}

/// One character cell: a grapheme (a base character and any combining
/// characters after it), its renditions, and whether it is the left half of a
/// wide character.
class MoshCell {
  MoshCell(int background)
    : contents = '',
      renditions = MoshRenditions(background: background);

  MoshCell._copy(MoshCell other)
    : contents = other.contents,
      renditions = other.renditions,
      wide = other.wide,
      fallback = other.fallback,
      wrap = other.wrap;

  String contents;
  MoshRenditions renditions;
  bool wide = false;

  /// The grapheme starts with a combining character, which is drawn on a
  /// no-break space.
  bool fallback = false;

  /// Set on a row's last cell when the text carries on into the next row.
  bool wrap = false;

  MoshCell copy() => MoshCell._copy(this);

  void reset(int background) {
    contents = '';
    renditions = MoshRenditions(background: background);
    wide = false;
    fallback = false;
    wrap = false;
  }

  bool get isEmpty => contents.isEmpty;

  /// Mosh caps a cell at 32 bytes of combining characters.
  bool get isFull => utf8.encode(contents).length >= 32;

  void clear() => contents = '';

  bool get isBlank => contents.isEmpty || contents == ' ' || contents == ' ';

  bool contentsMatch(MoshCell other) =>
      (isBlank && other.isBlank) || contents == other.contents;

  void append(int codePoint) => contents += String.fromCharCode(codePoint);

  int get width => wide ? 2 : 1;

  void printGrapheme(StringBuffer out) {
    if (contents.isEmpty) {
      out.write(' ');
      return;
    }
    if (fallback) out.write(' ');
    out.write(contents);
  }

  /// Cell equality as Mosh defines it.
  bool sameAs(MoshCell other) =>
      contents == other.contents &&
      fallback == other.fallback &&
      wide == other.wide &&
      renditions == other.renditions &&
      wrap == other.wrap;
}

var _genCounter = 0;

/// One row of cells. Rows are shared between screen states and copied on
/// first write (see [MoshFramebuffer.mutableRow]), which is what makes
/// keeping a dozen screen states cheap; [gen] tells a row that was merely
/// moved (scrolled) from one that was rewritten with the same text.
class MoshRow {
  MoshRow(int width, int background)
    : cells = List<MoshCell>.generate(width, (_) => MoshCell(background)),
      gen = _genCounter++;

  MoshRow._copy(MoshRow other, this.owner)
    : cells = [for (final cell in other.cells) cell.copy()],
      gen = other.gen;

  final List<MoshCell> cells;
  int gen;

  /// The framebuffer allowed to change this row in place, or null when it may
  /// be shared.
  Object? owner;

  /// A private copy, same [gen], owned by nobody.
  MoshRow copy() => MoshRow._copy(this, null);

  void insertCell(int col, int background) {
    cells.insert(col, MoshCell(background));
    cells.removeLast();
  }

  void deleteCell(int col, int background) {
    cells.add(MoshCell(background));
    cells.removeAt(col);
  }

  void reset(int background) {
    gen = _genCounter++;
    for (final cell in cells) {
      cell.reset(background);
    }
  }

  bool get wrap => cells.last.wrap;
  set wrap(bool value) => cells.last.wrap = value;

  /// Row equality as Mosh defines it: same origin and same cells.
  bool sameAs(MoshRow other) {
    if (identical(this, other)) return true;
    if (gen != other.gen || cells.length != other.cells.length) return false;
    for (var i = 0; i < cells.length; i++) {
      if (!cells[i].sameAs(other.cells[i])) return false;
    }
    return true;
  }
}

class _SavedCursor {
  var cursorCol = 0;
  var cursorRow = 0;
  var renditions = const MoshRenditions();
  var autoWrapMode = true;
  var originMode = false;

  _SavedCursor copy() => _SavedCursor()
    ..cursorCol = cursorCol
    ..cursorRow = cursorRow
    ..renditions = renditions
    ..autoWrapMode = autoWrapMode
    ..originMode = originMode;
}

/// Mouse reporting modes, by their DEC private mode numbers.
abstract final class MoshMouseReporting {
  static const none = 0;
  static const x10 = 9;
  static const vt220 = 1000;
  static const vt220Highlight = 1001;
  static const buttonEvent = 1002;
  static const anyEvent = 1003;
}

/// Mouse report encodings, by their DEC private mode numbers.
abstract final class MoshMouseEncoding {
  static const standard = 0;
  static const utf8 = 1005;
  static const sgr = 1006;
  static const urxvt = 1015;
}

/// Cursor, margins, modes and pen — everything about the screen that is not
/// the cells.
class MoshDrawState {
  MoshDrawState(this._width, this._height)
    : _tabs = List<bool>.filled(_width, false),
      _scrollingRegionBottom = _height - 1 {
    _reinitializeTabs(0);
  }

  MoshDrawState._copy(MoshDrawState o)
    : _width = o._width,
      _height = o._height,
      _cursorCol = o._cursorCol,
      _cursorRow = o._cursorRow,
      _combiningCharCol = o._combiningCharCol,
      _combiningCharRow = o._combiningCharRow,
      _defaultTabs = o._defaultTabs,
      _tabs = List<bool>.of(o._tabs),
      _scrollingRegionTop = o._scrollingRegionTop,
      _scrollingRegionBottom = o._scrollingRegionBottom,
      renditions = o.renditions,
      _save = o._save.copy(),
      nextPrintWillWrap = o.nextPrintWillWrap,
      originMode = o.originMode,
      autoWrapMode = o.autoWrapMode,
      insertMode = o.insertMode,
      cursorVisible = o.cursorVisible,
      reverseVideo = o.reverseVideo,
      bracketedPaste = o.bracketedPaste,
      mouseReportingMode = o.mouseReportingMode,
      mouseFocusEvent = o.mouseFocusEvent,
      mouseAlternateScroll = o.mouseAlternateScroll,
      mouseEncodingMode = o.mouseEncodingMode,
      applicationModeCursorKeys = o.applicationModeCursorKeys;

  int _width;
  int _height;
  int _cursorCol = 0;
  int _cursorRow = 0;
  int _combiningCharCol = 0;
  int _combiningCharRow = 0;
  bool _defaultTabs = true;
  List<bool> _tabs;
  int _scrollingRegionTop = 0;
  int _scrollingRegionBottom;
  MoshRenditions renditions = const MoshRenditions();
  _SavedCursor _save = _SavedCursor();

  bool nextPrintWillWrap = false;
  bool originMode = false;
  bool autoWrapMode = true;
  bool insertMode = false;
  bool cursorVisible = true;
  bool reverseVideo = false;
  bool bracketedPaste = false;
  int mouseReportingMode = MoshMouseReporting.none;
  bool mouseFocusEvent = false;
  bool mouseAlternateScroll = false;
  int mouseEncodingMode = MoshMouseEncoding.standard;
  bool applicationModeCursorKeys = false;

  MoshDrawState copy() => MoshDrawState._copy(this);

  int get width => _width;
  int get height => _height;
  int get cursorCol => _cursorCol;
  int get cursorRow => _cursorRow;
  int get combiningCharCol => _combiningCharCol;
  int get combiningCharRow => _combiningCharRow;
  int get scrollingRegionTop => _scrollingRegionTop;
  int get scrollingRegionBottom => _scrollingRegionBottom;
  int get backgroundRendition => renditions.background;

  void _reinitializeTabs(int start) {
    for (var i = start; i < _tabs.length; i++) {
      _tabs[i] = i % 8 == 0;
    }
  }

  void _newGrapheme() {
    _combiningCharCol = _cursorCol;
    _combiningCharRow = _cursorRow;
  }

  void _snapCursorToBorder() {
    if (_cursorRow < limitTop) _cursorRow = limitTop;
    if (_cursorRow > limitBottom) _cursorRow = limitBottom;
    if (_cursorCol < 0) _cursorCol = 0;
    if (_cursorCol >= _width) _cursorCol = _width - 1;
  }

  void moveRow(int n, {bool relative = false}) {
    if (relative) {
      _cursorRow += n;
    } else {
      _cursorRow = n + limitTop;
    }
    _snapCursorToBorder();
    _newGrapheme();
    nextPrintWillWrap = false;
  }

  void moveCol(int n, {bool relative = false, bool implicit = false}) {
    if (implicit) _newGrapheme();
    if (relative) {
      _cursorCol += n;
    } else {
      _cursorCol = n;
    }
    if (implicit) nextPrintWillWrap = _cursorCol >= _width;
    _snapCursorToBorder();
    if (!implicit) {
      _newGrapheme();
      nextPrintWillWrap = false;
    }
  }

  void setTab() => _tabs[_cursorCol] = true;
  void clearTab(int col) => _tabs[col] = false;
  void clearDefaultTabs() => _defaultTabs = false;

  int nextTab(int count) {
    if (count >= 0) {
      for (var i = _cursorCol + 1; i < _width; i++) {
        if (_tabs[i] && --count == 0) return i;
      }
      return -1;
    }
    for (var i = _cursorCol - 1; i > 0; i--) {
      if (_tabs[i] && ++count == 0) return i;
    }
    return 0;
  }

  void setScrollingRegion(int top, int bottom) {
    if (_height < 1) return;
    _scrollingRegionTop = top;
    _scrollingRegionBottom = bottom;
    if (_scrollingRegionTop < 0) _scrollingRegionTop = 0;
    if (_scrollingRegionBottom >= _height) _scrollingRegionBottom = _height - 1;
    if (_scrollingRegionBottom < _scrollingRegionTop) {
      _scrollingRegionBottom = _scrollingRegionTop;
    }
    if (originMode) {
      _snapCursorToBorder();
      _newGrapheme();
    }
  }

  int get limitTop => originMode ? _scrollingRegionTop : 0;
  int get limitBottom => originMode ? _scrollingRegionBottom : _height - 1;

  void setForegroundColor(int x) =>
      renditions = renditions.withForegroundColor(x);
  void setBackgroundColor(int x) =>
      renditions = renditions.withBackgroundColor(x);
  void addRendition(int x) => renditions = renditions.withRendition(x);

  void saveCursor() {
    _save
      ..cursorCol = _cursorCol
      ..cursorRow = _cursorRow
      ..renditions = renditions
      ..autoWrapMode = autoWrapMode
      ..originMode = originMode;
  }

  void restoreCursor() {
    _cursorCol = _save.cursorCol;
    _cursorRow = _save.cursorRow;
    renditions = _save.renditions;
    autoWrapMode = _save.autoWrapMode;
    originMode = _save.originMode;
    _snapCursorToBorder();
    _newGrapheme();
  }

  void clearSavedCursor() => _save = _SavedCursor();

  void resize(int width, int height) {
    if (_width != width || _height != height) {
      _scrollingRegionTop = 0;
      _scrollingRegionBottom = height - 1;
    }
    final oldWidth = _width;
    if (_tabs.length != width) {
      _tabs = width < _tabs.length
          ? _tabs.sublist(0, width)
          : [..._tabs, ...List<bool>.filled(width - _tabs.length, false)];
    }
    if (_defaultTabs) _reinitializeTabs(oldWidth.clamp(0, width));
    _width = width;
    _height = height;
    _snapCursorToBorder();
    if (_combiningCharCol >= _width || _combiningCharRow >= _height) {
      _combiningCharCol = _combiningCharRow = -1;
    }
  }

  /// Equality over what affects the display, as Mosh's `DrawState::operator==`.
  bool sameAs(MoshDrawState x) =>
      _width == x._width &&
      _height == x._height &&
      _cursorCol == x._cursorCol &&
      _cursorRow == x._cursorRow &&
      cursorVisible == x.cursorVisible &&
      reverseVideo == x.reverseVideo &&
      renditions == x.renditions &&
      bracketedPaste == x.bracketedPaste &&
      mouseReportingMode == x.mouseReportingMode &&
      mouseFocusEvent == x.mouseFocusEvent &&
      mouseAlternateScroll == x.mouseAlternateScroll &&
      mouseEncodingMode == x.mouseEncodingMode;
}

/// A whole screen: rows of cells, the draw state, and the window title,
/// clipboard and bell count that ride along with it.
class MoshFramebuffer {
  MoshFramebuffer(int width, int height)
    : assert(width > 0 && height > 0),
      ds = MoshDrawState(width, height) {
    final blank = MoshRow(width, 0);
    rows = List<MoshRow>.filled(height, blank, growable: true);
  }

  MoshFramebuffer._shared(MoshFramebuffer other)
    : rows = List<MoshRow>.of(other.rows),
      iconName = List<int>.of(other.iconName),
      windowTitle = List<int>.of(other.windowTitle),
      clipboard = List<int>.of(other.clipboard),
      bellCount = other.bellCount,
      titleInitialized = other.titleInitialized,
      ds = other.ds.copy();

  late List<MoshRow> rows;
  List<int> iconName = [];
  List<int> windowTitle = [];
  List<int> clipboard = [];
  int bellCount = 0;
  bool titleInitialized = false;
  MoshDrawState ds;

  /// Which rows this framebuffer may change in place: those whose
  /// [MoshRow.owner] is this token. A copy gives both sides new tokens, so
  /// neither writes into a row the other can see.
  Object _token = Object();

  /// An independent copy that shares every row until one side writes to it.
  MoshFramebuffer copy() {
    final copy = MoshFramebuffer._shared(this);
    _token = Object();
    return copy;
  }

  MoshRow _newRow() => MoshRow(ds.width, ds.backgroundRendition);

  MoshRow row(int row) => rows[row == -1 ? ds.cursorRow : row];

  MoshCell cell([int row = -1, int col = -1]) {
    if (row == -1) row = ds.cursorRow;
    if (col == -1) col = ds.cursorCol;
    return rows[row].cells[col];
  }

  MoshRow mutableRow(int row) {
    if (row == -1) row = ds.cursorRow;
    final current = rows[row];
    if (identical(current.owner, _token)) return current;
    return rows[row] = MoshRow._copy(current, _token);
  }

  MoshCell mutableCell([int row = -1, int col = -1]) {
    if (row == -1) row = ds.cursorRow;
    if (col == -1) col = ds.cursorCol;
    return mutableRow(row).cells[col];
  }

  void scroll(int n) {
    if (n >= 0) {
      deleteLine(ds.scrollingRegionTop, n);
    } else {
      insertLine(ds.scrollingRegionTop, -n);
    }
  }

  void moveRowsAutoscroll(int n) {
    if (ds.cursorRow < ds.scrollingRegionTop ||
        ds.cursorRow > ds.scrollingRegionBottom) {
      ds.moveRow(n, relative: true);
      return;
    }
    if (ds.cursorRow + n > ds.scrollingRegionBottom) {
      final scrollBy = ds.cursorRow + n - ds.scrollingRegionBottom;
      scroll(scrollBy);
      ds.moveRow(-scrollBy, relative: true);
    } else if (ds.cursorRow + n < ds.scrollingRegionTop) {
      final scrollBy = ds.cursorRow + n - ds.scrollingRegionTop;
      scroll(scrollBy);
      ds.moveRow(-scrollBy, relative: true);
    }
    ds.moveRow(n, relative: true);
  }

  /// Null when a resize has left the remembered cell off the screen.
  MoshCell? combiningCell() {
    if (ds.combiningCharCol < 0 ||
        ds.combiningCharRow < 0 ||
        ds.combiningCharCol >= ds.width ||
        ds.combiningCharRow >= ds.height) {
      return null;
    }
    return mutableCell(ds.combiningCharRow, ds.combiningCharCol);
  }

  void applyRenditionsToCell(MoshCell cell) => cell.renditions = ds.renditions;

  void insertLine(int beforeRow, int count) {
    if (beforeRow < ds.scrollingRegionTop ||
        beforeRow > ds.scrollingRegionBottom + 1) {
      return;
    }
    var n = ds.scrollingRegionBottom + 1 - beforeRow;
    if (count < n) n = count;
    if (n <= 0) return;
    final start = ds.scrollingRegionBottom + 1 - n;
    rows.removeRange(start, start + n);
    final blank = _newRow();
    rows.insertAll(beforeRow, List<MoshRow>.filled(n, blank));
  }

  void deleteLine(int row, int count) {
    if (row < ds.scrollingRegionTop || row > ds.scrollingRegionBottom) return;
    var n = ds.scrollingRegionBottom + 1 - row;
    if (count < n) n = count;
    if (n <= 0) return;
    rows.removeRange(row, row + n);
    final blank = _newRow();
    rows.insertAll(
      ds.scrollingRegionBottom + 1 - n,
      List<MoshRow>.filled(n, blank),
    );
  }

  void insertCell(int row, int col) =>
      mutableRow(row).insertCell(col, ds.backgroundRendition);

  void deleteCell(int row, int col) =>
      mutableRow(row).deleteCell(col, ds.backgroundRendition);

  void reset() {
    final width = ds.width, height = ds.height;
    ds = MoshDrawState(width, height);
    rows = List<MoshRow>.filled(height, _newRow(), growable: true);
    windowTitle = [];
    clipboard = [];
    // The bell count survives, as in Mosh.
  }

  void softReset() {
    ds
      ..insertMode = false
      ..originMode = false
      ..cursorVisible = true
      ..applicationModeCursorKeys = false
      ..setScrollingRegion(0, ds.height - 1)
      ..addRendition(0)
      ..clearSavedCursor();
  }

  void prefixWindowTitle(List<int> prefix) {
    if (_sameList(iconName, windowTitle)) {
      iconName = [...prefix, ...iconName];
    }
    windowTitle = [...prefix, ...windowTitle];
  }

  void resize(int width, int height) {
    assert(width > 0 && height > 0);
    final oldHeight = ds.height;
    final oldWidth = ds.width;
    ds.resize(width, height);
    final blank = _newRow();
    if (oldHeight != height) {
      if (height < rows.length) {
        rows.removeRange(height, rows.length);
      } else {
        rows.addAll(List<MoshRow>.filled(height - rows.length, blank));
      }
    }
    if (oldWidth == width) return;
    for (var i = 0; i < rows.length && !identical(rows[i], blank); i++) {
      final copy = MoshRow._copy(rows[i], _token)..wrap = false;
      if (width < copy.cells.length) {
        copy.cells.removeRange(width, copy.cells.length);
      } else {
        for (var c = copy.cells.length; c < width; c++) {
          copy.cells.add(MoshCell(ds.backgroundRendition));
        }
      }
      rows[i] = copy;
    }
  }

  void resetCell(MoshCell cell) => cell.reset(ds.backgroundRendition);
  void resetRow(MoshRow row) => row.reset(ds.backgroundRendition);
  void ringBell() => bellCount++;

  /// Framebuffer equality as Mosh defines it.
  bool sameAs(MoshFramebuffer x) {
    if (rows.length != x.rows.length) return false;
    for (var i = 0; i < rows.length; i++) {
      if (!rows[i].sameAs(x.rows[i])) return false;
    }
    return _sameList(windowTitle, x.windowTitle) &&
        _sameList(clipboard, x.clipboard) &&
        bellCount == x.bellCount &&
        ds.sameAs(x.ds);
  }
}

bool _sameList(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

enum _State {
  ground,
  escape,
  escapeIntermediate,
  csiEntry,
  csiParam,
  csiIntermediate,
  csiIgnore,
  dcsEntry,
  dcsParam,
  dcsIntermediate,
  dcsPassthrough,
  dcsIgnore,
  oscString,
  sosPmApcString,
}

/// What [MoshParser] reports for each character.
enum MoshAction {
  ignore,
  print,
  execute,
  clear,
  collect,
  param,
  escDispatch,
  csiDispatch,
  hook,
  put,
  unhook,
  oscStart,
  oscPut,
  oscEnd,
}

/// Mosh's VT500-series parser (Paul Williams' state machine, as
/// `parserstate.cc` has it): turns characters into actions without acting
/// on them. The emulator acts on what it reports; so does local-echo
/// prediction, on what the user types.
class MoshParser {
  MoshParser(this._onAction);

  final void Function(MoshAction action, int ch) _onAction;
  var _state = _State.ground;

  void input(int ch) {
    var (action, next) = _anywhere(ch);
    if (next == null) {
      (action, next) = _stateRule(_state, ch >= 0xa0 ? 0x41 : ch);
    }
    if (next != null) _onAction(_exitAction(_state), ch);
    _onAction(action, ch);
    if (next != null) {
      _onAction(_enterAction(next), ch);
      _state = next;
    }
  }

  static (MoshAction, _State?) _anywhere(int ch) {
    if (ch == 0x18 ||
        ch == 0x1a ||
        (0x80 <= ch && ch <= 0x8f) ||
        (0x91 <= ch && ch <= 0x97) ||
        ch == 0x99 ||
        ch == 0x9a) {
      return (MoshAction.execute, _State.ground);
    }
    if (ch == 0x9c) return (MoshAction.ignore, _State.ground);
    if (ch == 0x1b) return (MoshAction.ignore, _State.escape);
    if (ch == 0x98 || ch == 0x9e || ch == 0x9f) {
      return (MoshAction.ignore, _State.sosPmApcString);
    }
    if (ch == 0x90) return (MoshAction.ignore, _State.dcsEntry);
    if (ch == 0x9d) return (MoshAction.ignore, _State.oscString);
    if (ch == 0x9b) return (MoshAction.ignore, _State.csiEntry);
    return (MoshAction.ignore, null);
  }

  static bool _c0Prime(int ch) =>
      ch <= 0x17 || ch == 0x19 || (0x1c <= ch && ch <= 0x1f);

  static (MoshAction, _State?) _stateRule(_State state, int ch) {
    switch (state) {
      case _State.ground:
        if (_c0Prime(ch)) return (MoshAction.execute, null);
        if ((0x20 <= ch && ch <= 0x7f) || (0xa0 <= ch && ch <= 0xff)) {
          return (MoshAction.print, null);
        }
        return (MoshAction.ignore, null);
      case _State.escape:
        if (_c0Prime(ch)) return (MoshAction.execute, null);
        if (0x20 <= ch && ch <= 0x2f) {
          return (MoshAction.collect, _State.escapeIntermediate);
        }
        if ((0x30 <= ch && ch <= 0x4f) ||
            (0x51 <= ch && ch <= 0x57) ||
            ch == 0x59 ||
            ch == 0x5a ||
            ch == 0x5c ||
            (0x60 <= ch && ch <= 0x7e)) {
          return (MoshAction.escDispatch, _State.ground);
        }
        if (ch == 0x5b) return (MoshAction.ignore, _State.csiEntry);
        if (ch == 0x5d) return (MoshAction.ignore, _State.oscString);
        if (ch == 0x50) return (MoshAction.ignore, _State.dcsEntry);
        if (ch == 0x58 || ch == 0x5e || ch == 0x5f) {
          return (MoshAction.ignore, _State.sosPmApcString);
        }
        return (MoshAction.ignore, null);
      case _State.escapeIntermediate:
        if (_c0Prime(ch)) return (MoshAction.execute, null);
        if (0x20 <= ch && ch <= 0x2f) return (MoshAction.collect, null);
        if (0x30 <= ch && ch <= 0x7e) {
          return (MoshAction.escDispatch, _State.ground);
        }
        return (MoshAction.ignore, null);
      case _State.csiEntry:
        if (_c0Prime(ch)) return (MoshAction.execute, null);
        if (0x40 <= ch && ch <= 0x7e) {
          return (MoshAction.csiDispatch, _State.ground);
        }
        if ((0x30 <= ch && ch <= 0x39) || ch == 0x3b) {
          return (MoshAction.param, _State.csiParam);
        }
        if (0x3c <= ch && ch <= 0x3f) {
          return (MoshAction.collect, _State.csiParam);
        }
        if (ch == 0x3a) return (MoshAction.ignore, _State.csiIgnore);
        if (0x20 <= ch && ch <= 0x2f) {
          return (MoshAction.collect, _State.csiIntermediate);
        }
        return (MoshAction.ignore, null);
      case _State.csiParam:
        if (_c0Prime(ch)) return (MoshAction.execute, null);
        if ((0x30 <= ch && ch <= 0x39) || ch == 0x3b) {
          return (MoshAction.param, null);
        }
        if (ch == 0x3a || (0x3c <= ch && ch <= 0x3f)) {
          return (MoshAction.ignore, _State.csiIgnore);
        }
        if (0x20 <= ch && ch <= 0x2f) {
          return (MoshAction.collect, _State.csiIntermediate);
        }
        if (0x40 <= ch && ch <= 0x7e) {
          return (MoshAction.csiDispatch, _State.ground);
        }
        return (MoshAction.ignore, null);
      case _State.csiIntermediate:
        if (_c0Prime(ch)) return (MoshAction.execute, null);
        if (0x20 <= ch && ch <= 0x2f) return (MoshAction.collect, null);
        if (0x40 <= ch && ch <= 0x7e) {
          return (MoshAction.csiDispatch, _State.ground);
        }
        if (0x30 <= ch && ch <= 0x3f) {
          return (MoshAction.ignore, _State.csiIgnore);
        }
        return (MoshAction.ignore, null);
      case _State.csiIgnore:
        if (_c0Prime(ch)) return (MoshAction.execute, null);
        if (0x40 <= ch && ch <= 0x7e) return (MoshAction.ignore, _State.ground);
        return (MoshAction.ignore, null);
      case _State.dcsEntry:
        if (0x20 <= ch && ch <= 0x2f) {
          return (MoshAction.collect, _State.dcsIntermediate);
        }
        if (ch == 0x3a) return (MoshAction.ignore, _State.dcsIgnore);
        if ((0x30 <= ch && ch <= 0x39) || ch == 0x3b) {
          return (MoshAction.param, _State.dcsParam);
        }
        if (0x3c <= ch && ch <= 0x3f) {
          return (MoshAction.collect, _State.dcsParam);
        }
        if (0x40 <= ch && ch <= 0x7e) {
          return (MoshAction.ignore, _State.dcsPassthrough);
        }
        return (MoshAction.ignore, null);
      case _State.dcsParam:
        if ((0x30 <= ch && ch <= 0x39) || ch == 0x3b) {
          return (MoshAction.param, null);
        }
        if (ch == 0x3a || (0x3c <= ch && ch <= 0x3f)) {
          return (MoshAction.ignore, _State.dcsIgnore);
        }
        if (0x20 <= ch && ch <= 0x2f) {
          return (MoshAction.collect, _State.dcsIntermediate);
        }
        if (0x40 <= ch && ch <= 0x7e) {
          return (MoshAction.ignore, _State.dcsPassthrough);
        }
        return (MoshAction.ignore, null);
      case _State.dcsIntermediate:
        if (0x20 <= ch && ch <= 0x2f) return (MoshAction.collect, null);
        if (0x40 <= ch && ch <= 0x7e) {
          return (MoshAction.ignore, _State.dcsPassthrough);
        }
        if (0x30 <= ch && ch <= 0x3f) {
          return (MoshAction.ignore, _State.dcsIgnore);
        }
        return (MoshAction.ignore, null);
      case _State.dcsPassthrough:
        if (_c0Prime(ch) || (0x20 <= ch && ch <= 0x7e)) {
          return (MoshAction.put, null);
        }
        if (ch == 0x9c) return (MoshAction.ignore, _State.ground);
        return (MoshAction.ignore, null);
      case _State.dcsIgnore:
        if (ch == 0x9c) return (MoshAction.ignore, _State.ground);
        return (MoshAction.ignore, null);
      case _State.oscString:
        if (0x20 <= ch && ch <= 0x7f) return (MoshAction.oscPut, null);
        if (ch == 0x9c || ch == 0x07) return (MoshAction.ignore, _State.ground);
        return (MoshAction.ignore, null);
      case _State.sosPmApcString:
        if (ch == 0x9c) return (MoshAction.ignore, _State.ground);
        return (MoshAction.ignore, null);
    }
  }

  static MoshAction _enterAction(_State state) => switch (state) {
    _State.escape || _State.csiEntry || _State.dcsEntry => MoshAction.clear,
    _State.dcsPassthrough => MoshAction.hook,
    _State.oscString => MoshAction.oscStart,
    _ => MoshAction.ignore,
  };

  static MoshAction _exitAction(_State state) => switch (state) {
    _State.dcsPassthrough => MoshAction.unhook,
    _State.oscString => MoshAction.oscEnd,
    _ => MoshAction.ignore,
  };
}

/// Mosh's dispatcher, applying what [MoshParser] reports to a
/// [MoshFramebuffer]. Answers to queries (device attributes, cursor
/// position) are dropped: the server never interrogates its client.
class MoshEmulator {
  MoshEmulator(this.fb);

  MoshFramebuffer fb;

  late final MoshParser _parser = MoshParser(_act);
  final StringBuffer _params = StringBuffer();
  List<int>? _parsedParams;
  final List<int> _dispatchChars = [];
  final List<int> _oscString = [];

  static const _paramMax = 65535;
  static const _maximumClipboardSize = 16 * 1024;

  /// Applies UTF-8 [bytes]; malformed sequences become U+FFFD, as Mosh's
  /// parser makes them.
  void writeBytes(List<int> bytes) {
    for (final rune in utf8.decode(bytes, allowMalformed: true).runes) {
      input(rune);
    }
  }

  void writeString(String text) {
    for (final rune in text.runes) {
      input(rune);
    }
  }

  void input(int ch) => _parser.input(ch);

  void _act(MoshAction action, int ch) {
    switch (action) {
      case MoshAction.ignore:
      case MoshAction.hook:
      case MoshAction.put:
      case MoshAction.unhook:
        return;
      case MoshAction.print:
        _print(ch);
      case MoshAction.execute:
        _dispatchControl(ch);
      case MoshAction.clear:
        _params.clear();
        _parsedParams = null;
        _dispatchChars.clear();
      case MoshAction.collect:
        _collect(ch);
      case MoshAction.param:
        if (_params.length < 100) _params.writeCharCode(ch);
        _parsedParams = null;
      case MoshAction.escDispatch:
        if (_dispatchChars.isEmpty && 0x40 <= ch && ch <= 0x5f) {
          // ESC-encoded C1 control.
          _dispatchControl(ch + 0x40);
        } else {
          _collect(ch);
          _dispatchEscape(String.fromCharCodes(_dispatchChars));
        }
      case MoshAction.csiDispatch:
        _collect(ch);
        _dispatchCsi(String.fromCharCodes(_dispatchChars));
      case MoshAction.oscStart:
        _oscString.clear();
      case MoshAction.oscPut:
        if (_oscString.length < _maximumClipboardSize) _oscString.add(ch);
      case MoshAction.oscEnd:
        _oscDispatch();
    }
  }

  void _collect(int ch) {
    if (_dispatchChars.length < 8 && ch <= 255) _dispatchChars.add(ch);
  }

  List<int> _paramList() {
    final parsed = _parsedParams;
    if (parsed != null) return parsed;
    final out = <int>[];
    for (final segment in _params.toString().split(';')) {
      final match = RegExp(r'^[0-9]+').stringMatch(segment);
      if (match == null) {
        out.add(-1);
        continue;
      }
      final value = int.tryParse(match);
      out.add(value == null || value > _paramMax ? -1 : value);
    }
    return _parsedParams = out;
  }

  int _param(int n, int defaultValue) {
    final params = _paramList();
    var value = n < params.length ? params[n] : defaultValue;
    if (value < 1) value = defaultValue;
    return value;
  }

  int get _paramCount => _paramList().length;

  // ------------------------------------------------------------- printing

  void _print(int ch) {
    final width = moshCharWidth(ch);
    MoshCell? thisCell = fb.mutableCell();
    switch (width) {
      case 1:
      case 2:
        if (fb.ds.autoWrapMode && fb.ds.nextPrintWillWrap) {
          fb.mutableRow(-1).wrap = true;
          fb.ds.moveCol(0);
          fb.moveRowsAutoscroll(1);
          thisCell = null;
        } else if (fb.ds.autoWrapMode &&
            width == 2 &&
            fb.ds.cursorCol == fb.ds.width - 1) {
          // No room for a wide character: wrap it, even without the flag.
          fb.resetCell(thisCell);
          fb.mutableRow(-1).wrap = false;
          fb.ds.moveCol(0);
          fb.moveRowsAutoscroll(1);
          thisCell = null;
        }
        if (fb.ds.insertMode) {
          for (var i = 0; i < width; i++) {
            fb.insertCell(fb.ds.cursorRow, fb.ds.cursorCol);
          }
          thisCell = null;
        }
        thisCell ??= fb.mutableCell();
        fb.resetCell(thisCell);
        thisCell
          ..append(ch)
          ..wide = width == 2;
        fb.applyRenditionsToCell(thisCell);
        if (width == 2 && fb.ds.cursorCol + 1 < fb.ds.width) {
          fb.resetCell(fb.mutableCell(fb.ds.cursorRow, fb.ds.cursorCol + 1));
        }
        fb.ds.moveCol(width, relative: true, implicit: true);
      case 0:
        final combining = fb.combiningCell();
        if (combining == null) break;
        if (combining.isEmpty) {
          combining.fallback = true;
          fb.ds.moveCol(1, relative: true, implicit: true);
        }
        if (!combining.isFull) combining.append(ch);
      default:
        break;
    }
  }

  // ------------------------------------------------------------- dispatch

  void _dispatchControl(int ch) {
    // HT preserves the wrap state; every other control clears it.
    if (ch != 0x09) fb.ds.nextPrintWillWrap = false;
    switch (ch) {
      case 0x0a:
      case 0x84:
      case 0x0b:
      case 0x0c:
        fb.moveRowsAutoscroll(1);
      case 0x0d:
        fb.ds.moveCol(0);
      case 0x08:
        fb.ds.moveCol(-1, relative: true);
      case 0x8d:
        fb.moveRowsAutoscroll(-1);
      case 0x85:
        fb.ds.moveCol(0);
        fb.moveRowsAutoscroll(1);
      case 0x09:
        _horizontalTab(1);
      case 0x88:
        fb.ds.setTab();
      case 0x07:
        fb.ringBell();
    }
  }

  void _horizontalTab(int count) {
    var col = fb.ds.nextTab(count);
    if (col == -1) col = fb.ds.width - 1;
    final wrap = fb.ds.nextPrintWillWrap;
    fb.ds.moveCol(col);
    fb.ds.nextPrintWillWrap = wrap;
  }

  void _dispatchEscape(String key) {
    const known = {'#8', '7', '8', 'c'};
    fb.ds.nextPrintWillWrap = false;
    if (!known.contains(key)) return;
    switch (key) {
      case '#8':
        for (var y = 0; y < fb.ds.height; y++) {
          for (var x = 0; x < fb.ds.width; x++) {
            final cell = fb.mutableCell(y, x);
            fb.resetCell(cell);
            cell.append(0x45);
          }
        }
      case '7':
        fb.ds.saveCursor();
      case '8':
        fb.ds.restoreCursor();
      case 'c':
        fb.reset();
    }
  }

  static const _keepsWrapState = {'I', 'Z', 'g', '?h', '?l', 'm'};
  static const _csiKnown = {
    'K',
    'J',
    'A',
    'B',
    'C',
    'D',
    'H',
    'f',
    'c',
    '>c',
    'I',
    'Z',
    'g',
    '?h',
    '?l',
    'h',
    'l',
    'r',
    'm',
    'n',
    'L',
    'M',
    '@',
    'P',
    'd',
    'G',
    '`',
    'X',
    '!p',
    'S',
    'T',
  };

  void _dispatchCsi(String key) {
    if (!_csiKnown.contains(key) || !_keepsWrapState.contains(key)) {
      fb.ds.nextPrintWillWrap = false;
    }
    switch (key) {
      case 'K':
        _eraseInLine();
      case 'J':
        _eraseInDisplay();
      case 'A':
        fb.ds.moveRow(-_param(0, 1), relative: true);
      case 'B':
        fb.ds.moveRow(_param(0, 1), relative: true);
      case 'C':
        fb.ds.moveCol(_param(0, 1), relative: true);
      case 'D':
        fb.ds.moveCol(-_param(0, 1), relative: true);
      case 'H':
      case 'f':
        fb.ds.moveRow(_param(0, 1) - 1);
        fb.ds.moveCol(_param(1, 1) - 1);
      case 'I':
      case 'Z':
        var param = _param(0, 1);
        if (key == 'Z') param = -param;
        if (param != 0) _horizontalTab(param);
      case 'g':
        switch (_param(0, 0)) {
          case 0:
            fb.ds.clearTab(fb.ds.cursorCol);
          case 3:
            fb.ds.clearDefaultTabs();
            for (var x = 0; x < fb.ds.width; x++) {
              fb.ds.clearTab(x);
            }
        }
      case '?h':
      case '?l':
        _setDecModes(key == '?h');
      case 'h':
      case 'l':
        for (var i = 0; i < _paramCount; i++) {
          if (_param(i, 0) == 4) fb.ds.insertMode = key == 'h';
        }
      case 'r':
        final top = _param(0, 1);
        final bottom = _param(1, fb.ds.height);
        if (bottom <= top || top > fb.ds.height || (top == 0 && bottom == 1)) {
          return;
        }
        fb.ds.setScrollingRegion(top - 1, bottom - 1);
        fb.ds.moveRow(0);
        fb.ds.moveCol(0);
      case 'm':
        _selectGraphicRendition();
      case 'L':
        fb.insertLine(fb.ds.cursorRow, _param(0, 1));
        fb.ds.moveCol(0);
      case 'M':
        fb.deleteLine(fb.ds.cursorRow, _param(0, 1));
        fb.ds.moveCol(0);
      case '@':
        final cells = _param(0, 1);
        for (var i = 0; i < cells; i++) {
          fb.insertCell(fb.ds.cursorRow, fb.ds.cursorCol);
        }
      case 'P':
        final cells = _param(0, 1);
        for (var i = 0; i < cells; i++) {
          fb.deleteCell(fb.ds.cursorRow, fb.ds.cursorCol);
        }
      case 'd':
        fb.ds.moveRow(_param(0, 1) - 1);
      case 'G':
      case '`':
        fb.ds.moveCol(_param(0, 1) - 1);
      case 'X':
        final num = _param(0, 1);
        var limit = fb.ds.cursorCol + num - 1;
        if (limit >= fb.ds.width) limit = fb.ds.width - 1;
        _clearLine(-1, fb.ds.cursorCol, limit);
      case '!p':
        fb.softReset();
      case 'S':
        fb.scroll(_param(0, 1));
      case 'T':
        fb.scroll(-_param(0, 1));
      default:
        // 'c', '>c' and 'n' are queries; there is nobody to answer.
        break;
    }
  }

  void _clearLine(int row, int start, int end) {
    for (var col = start; col <= end; col++) {
      fb.resetCell(fb.mutableCell(row, col));
    }
  }

  void _eraseInLine() {
    switch (_param(0, 0)) {
      case 0:
        _clearLine(-1, fb.ds.cursorCol, fb.ds.width - 1);
      case 1:
        _clearLine(-1, 0, fb.ds.cursorCol);
      case 2:
        fb.resetRow(fb.mutableRow(-1));
    }
  }

  void _eraseInDisplay() {
    switch (_param(0, 0)) {
      case 0:
        _clearLine(-1, fb.ds.cursorCol, fb.ds.width - 1);
        for (var y = fb.ds.cursorRow + 1; y < fb.ds.height; y++) {
          fb.resetRow(fb.mutableRow(y));
        }
      case 1:
        for (var y = 0; y < fb.ds.cursorRow; y++) {
          fb.resetRow(fb.mutableRow(y));
        }
        _clearLine(-1, 0, fb.ds.cursorCol);
      case 2:
        for (var y = 0; y < fb.ds.height; y++) {
          fb.resetRow(fb.mutableRow(y));
        }
    }
  }

  void _setDecModes(bool value) {
    for (var i = 0; i < _paramCount; i++) {
      final param = _param(i, 0);
      if (param == 9 || (param >= 1000 && param <= 1003)) {
        fb.ds.mouseReportingMode = value ? param : MoshMouseReporting.none;
      } else if (param == 1005 || param == 1006 || param == 1015) {
        fb.ds.mouseEncodingMode = value ? param : MoshMouseEncoding.standard;
      } else {
        switch (param) {
          case 1:
            fb.ds.applicationModeCursorKeys = value;
          case 3:
            // 80/132 columns: ignored, but the screen is cleared.
            fb.ds.moveRow(0);
            fb.ds.moveCol(0);
            for (var y = 0; y < fb.ds.height; y++) {
              fb.resetRow(fb.mutableRow(y));
            }
          case 5:
            fb.ds.reverseVideo = value;
          case 6:
            fb.ds.moveRow(0);
            fb.ds.moveCol(0);
            fb.ds.originMode = value;
          case 7:
            fb.ds.autoWrapMode = value;
          case 25:
            fb.ds.cursorVisible = value;
          case 1004:
            fb.ds.mouseFocusEvent = value;
          case 1007:
            fb.ds.mouseAlternateScroll = value;
          case 2004:
            fb.ds.bracketedPaste = value;
        }
      }
    }
  }

  void _selectGraphicRendition() {
    final count = _paramCount;
    for (var i = 0; i < count; i++) {
      final rendition = _param(i, 0);
      if ((rendition == 38 || rendition == 48) &&
          count - i >= 3 &&
          _param(i + 1, -1) == 5) {
        final color = _param(i + 2, 0);
        if (rendition == 38) {
          fb.ds.setForegroundColor(color);
        } else {
          fb.ds.setBackgroundColor(color);
        }
        i += 2;
        continue;
      }
      if ((rendition == 38 || rendition == 48) &&
          count - i >= 5 &&
          _param(i + 1, -1) == 2) {
        final color = MoshRenditions.makeTrueColor(
          _param(i + 2, 0),
          _param(i + 3, 0),
          _param(i + 4, 0),
        );
        if (rendition == 38) {
          fb.ds.setForegroundColor(color);
        } else {
          fb.ds.setBackgroundColor(color);
        }
        i += 4;
        continue;
      }
      fb.ds.addRendition(rendition);
    }
  }

  void _oscDispatch() {
    final s = _oscString;
    if (s.length >= 5 &&
        s[0] == 0x35 &&
        s[1] == 0x32 &&
        s[2] == 0x3b &&
        s[3] == 0x63 &&
        s[4] == 0x3b) {
      fb.clipboard = s.sublist(5);
      return;
    }
    if (s.isEmpty) return;
    var command = -1;
    var offset = 0;
    if (s[0] == 0x3b) {
      command = 0;
      offset = 1;
    } else if (s.length >= 2 && s[1] == 0x3b) {
      command = s[0] - 0x30;
      offset = 2;
    }
    final setIcon = command == 0 || command == 1;
    final setTitle = command == 0 || command == 2;
    if (!setIcon && !setTitle) return;
    fb.titleInitialized = true;
    final end = s.length < 256 ? s.length : 256;
    final title = offset <= end ? s.sublist(offset, end) : <int>[];
    if (setIcon) fb.iconName = List<int>.of(title);
    if (setTitle) fb.windowTitle = List<int>.of(title);
  }
}

/// The client's copy of one of the server's states: Mosh's
/// `Terminal::Complete`, minus the parts only a server needs.
class MoshTerminalState {
  MoshTerminalState(int width, int height)
    : fb = MoshFramebuffer(width, height);

  MoshTerminalState._(this.fb, this.echoAck);

  MoshFramebuffer fb;

  /// See [HostInstruction.echoAck].
  int echoAck = 0;

  MoshTerminalState copy() => MoshTerminalState._(fb.copy(), echoAck);

  /// Applies a `HostBuffers.HostMessage` from the server.
  void applyDiff(Uint8List diff) {
    for (final instruction in HostMessageCodec.decode(diff)) {
      final hostBytes = instruction.hostBytes;
      final resize = instruction.resize;
      final echoAck = instruction.echoAck;
      if (hostBytes != null) {
        MoshEmulator(fb).writeBytes(hostBytes);
      } else if (resize != null) {
        if (resize.width > 0 && resize.height > 0) {
          fb.resize(resize.width, resize.height);
        }
      } else if (echoAck != null) {
        if (compareUint64(echoAck, this.echoAck) >= 0) this.echoAck = echoAck;
      }
    }
  }
}
