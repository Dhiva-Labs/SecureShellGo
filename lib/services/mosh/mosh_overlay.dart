import 'dart:math';

import 'mosh_terminal.dart';

/// What Mosh's client draws on top of the server's screen before showing it
/// (`frontend/terminaloverlay.cc`): the bar that says how long the server
/// has been out of touch, and local-echo predictions.

const _never = 1 << 62;

/// The blue bar across the top row, shown once the server has been silent
/// for a while: "mosh: Last contact 12 seconds ago."
class MoshNotificationEngine {
  MoshNotificationEngine(int now)
    : _lastWordFromServer = now,
      _lastAckedState = now;

  int _lastWordFromServer;
  int _lastAckedState;
  String _message = '';
  var _messageIsNetworkError = false;
  var _messageExpiration = _never;

  bool _serverLate(int now) => now - _lastWordFromServer > 6500;
  bool _replyLate(int now) => now - _lastAckedState > 10000;
  bool _needCountup(int now) => _serverLate(now) || _replyLate(now);

  /// True while the bar is showing "Last contact", i.e. the link looks down.
  bool isLate(int now) => _needCountup(now);

  void serverHeard(int timestamp) => _lastWordFromServer = timestamp;
  void serverAcked(int timestamp) => _lastAckedState = timestamp;

  String get message => _message;

  void setMessage(String message, int now, {bool permanent = false}) {
    _message = message;
    _messageExpiration = permanent ? _never : now + 1000;
    _messageIsNetworkError = false;
  }

  void setNetworkError(String error, int now) {
    _message = error;
    _messageIsNetworkError = true;
    _messageExpiration = now + 3000 + 100;
  }

  void clearNetworkError(int now) {
    if (_messageIsNetworkError) {
      _messageExpiration = min(_messageExpiration, now + 1000);
    }
  }

  void adjustMessage(int now) {
    if (now >= _messageExpiration) _message = '';
  }

  /// Milliseconds until the bar next needs redrawing.
  int waitTime(int now) {
    var next = _messageExpiration - now;
    if (_needCountup(now)) {
      // After a minute without contact, tick every three seconds, not every
      // one, to save power.
      next = min(next, now - _lastWordFromServer > 60000 ? 3000 : 1000);
    }
    return next;
  }

  static String _duration(int seconds, String unit) {
    if (seconds < 60) return '$seconds $unit';
    if (seconds < 3600) {
      return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
    }
    return '${seconds ~/ 3600}:'
        '${((seconds ~/ 60) % 60).toString().padLeft(2, '0')}:'
        '${(seconds % 60).toString().padLeft(2, '0')}';
  }

  void apply(MoshFramebuffer fb, int now) {
    final timeExpired = _needCountup(now);
    if (_message.isEmpty && !timeExpired) return;

    if (fb.ds.cursorRow == 0) fb.ds.cursorVisible = false;

    final bar = const MoshRenditions()
        .withForegroundColor(7)
        .withBackgroundColor(4);
    for (var i = 0; i < fb.ds.width; i++) {
      final cell = fb.mutableCell(0, i);
      cell
        ..reset(0)
        ..renditions = bar
        ..append(0x20);
    }

    final sinceHeard = (now - _lastWordFromServer) ~/ 1000;
    final sinceAck = (now - _lastAckedState) ~/ 1000;
    var elapsed = sinceHeard;
    var explanation = 'contact';
    if (_replyLate(now) && !_serverLate(now)) {
      elapsed = sinceAck;
      explanation = 'reply';
    }

    final String text;
    if (_message.isEmpty) {
      text = 'mosh: Last $explanation ${_duration(elapsed, 'seconds')} ago.';
    } else if (!timeExpired) {
      text = 'mosh: $_message';
    } else {
      text =
          'mosh: $_message (${_duration(elapsed, 's')} without '
          '$explanation.)';
    }

    final bold = bar.withAttribute(MoshRenditions.bold, true);
    var col = 0;
    MoshCell? combining = fb.mutableCell(0, 0);
    for (final ch in text.runes) {
      if (col >= fb.ds.width) break;
      final width = moshCharWidth(ch);
      if (width == 1 || width == 2) {
        if (col + width > fb.ds.width) break;
        final cell = fb.mutableCell(0, col);
        cell
          ..reset(0)
          ..renditions = bold
          ..append(ch)
          ..wide = width == 2;
        combining = cell;
        col += width;
      } else if (width == 0 && combining != null) {
        if (combining.isEmpty) {
          combining.fallback = true;
          col++;
        }
        if (!combining.isFull) combining.append(ch);
      }
    }
  }
}

/// Whether to show predictions — Mosh's `--predict`.
enum MoshPredictionMode {
  /// Show them when the link is slow or has glitched: Mosh's default.
  adaptive,
  always,
  never,
}

enum _Validity {
  pending,
  correct,
  correctNoCredit,
  incorrectOrExpired,
  inactive,
}

class _ConditionalOverlay {
  _ConditionalOverlay(this.expirationFrame, this.col, this.tentativeUntilEpoch);

  int expirationFrame;
  int col;
  bool active = false;
  int tentativeUntilEpoch;
  int predictionTime = _never;

  bool tentative(int confirmedEpoch) => tentativeUntilEpoch > confirmedEpoch;

  void reset() {
    expirationFrame = tentativeUntilEpoch = _never;
    active = false;
  }

  void expire(int frame, int now) {
    expirationFrame = frame;
    predictionTime = now;
  }
}

class _CursorMove extends _ConditionalOverlay {
  _CursorMove(int expirationFrame, this.row, int col, int tentative)
    : super(expirationFrame, col, tentative);

  int row;

  _Validity validity(MoshFramebuffer fb, int lateAck) {
    if (!active) return _Validity.inactive;
    if (row >= fb.ds.height || col >= fb.ds.width) {
      return _Validity.incorrectOrExpired;
    }
    if (lateAck >= expirationFrame) {
      return fb.ds.cursorCol == col && fb.ds.cursorRow == row
          ? _Validity.correct
          : _Validity.incorrectOrExpired;
    }
    return _Validity.pending;
  }

  void apply(MoshFramebuffer fb, int confirmedEpoch) {
    if (!active || tentative(confirmedEpoch)) return;
    if (row >= fb.ds.height || col >= fb.ds.width || fb.ds.originMode) return;
    fb.ds.moveRow(row);
    fb.ds.moveCol(col);
  }
}

class _OverlayCell extends _ConditionalOverlay {
  _OverlayCell(super.expirationFrame, super.col, super.tentative);

  MoshCell replacement = MoshCell(0);
  bool unknown = false;

  /// Correct predictions that match what was there before earn no credit.
  final List<MoshCell> originalContents = [];

  @override
  void reset() {
    unknown = false;
    originalContents.clear();
    super.reset();
  }

  void resetWithOrig() {
    if (!active || unknown) {
      reset();
      return;
    }
    originalContents.add(replacement.copy());
    super.reset();
  }

  void apply(MoshFramebuffer fb, int confirmedEpoch, int row, bool flag) {
    if (!active || row >= fb.ds.height || col >= fb.ds.width) return;
    if (tentative(confirmedEpoch)) return;
    if (replacement.isBlank && fb.cell(row, col).isBlank) flag = false;
    if (unknown) {
      if (flag && col != fb.ds.width - 1) {
        final cell = fb.mutableCell(row, col);
        cell.renditions = cell.renditions.withAttribute(
          MoshRenditions.underlined,
          true,
        );
      }
      return;
    }
    if (!fb.cell(row, col).sameAs(replacement)) {
      final cell = fb.mutableCell(row, col);
      cell
        ..contents = replacement.contents
        ..renditions = replacement.renditions
        ..wide = replacement.wide
        ..fallback = replacement.fallback
        ..wrap = replacement.wrap;
      if (flag) {
        cell.renditions = cell.renditions.withAttribute(
          MoshRenditions.underlined,
          true,
        );
      }
    }
  }

  _Validity validity(MoshFramebuffer fb, int row, int lateAck) {
    if (!active) return _Validity.inactive;
    if (row >= fb.ds.height || col >= fb.ds.width) {
      return _Validity.incorrectOrExpired;
    }
    final current = fb.cell(row, col);
    if (lateAck < expirationFrame) return _Validity.pending;
    if (unknown) return _Validity.correctNoCredit;
    // Too easy to be right by accident.
    if (replacement.isBlank) return _Validity.correctNoCredit;
    if (current.contentsMatch(replacement)) {
      final wasAlreadyThere = originalContents.any(
        (c) => c.contentsMatch(replacement),
      );
      return wasAlreadyThere ? _Validity.correctNoCredit : _Validity.correct;
    }
    return _Validity.incorrectOrExpired;
  }
}

class _OverlayRow {
  _OverlayRow(this.rowNum);
  int rowNum;
  final List<_OverlayCell> cells = [];
}

/// Mosh's local echo: guesses what typed characters will do to the screen
/// and shows the guess at once, underlined while the link is slow, until the
/// server's own screen confirms or refutes it.
///
/// Guesses are grouped into *epochs*. Anything hard to predict (a control
/// key, an escape sequence, the last column) starts a new, tentative epoch
/// whose guesses stay hidden until one of them is confirmed — so a password
/// prompt, which echoes nothing, shows nothing: the first wrong guess kills
/// the epoch before it was ever displayed.
class MoshPredictionEngine {
  MoshPredictionEngine({this.mode = MoshPredictionMode.adaptive});

  static const _srttTriggerLow = 20;
  static const _srttTriggerHigh = 30;
  static const _flagTriggerLow = 50;
  static const _flagTriggerHigh = 80;
  static const _glitchThreshold = 250;
  static const _glitchRepairCount = 10;
  static const _glitchRepairMinInterval = 150;
  static const _glitchFlagThreshold = 5000;

  MoshPredictionMode mode;

  var _lastByte = 0;
  late final MoshParser _parser = MoshParser(_onAction);
  final _Utf8Stream _utf8 = _Utf8Stream();
  final List<_OverlayRow> _overlays = [];
  final List<_CursorMove> _cursors = [];

  int _localFrameSent = 0;
  int _localFrameLateAcked = 0;
  int _predictionEpoch = 1;
  int _confirmedEpoch = 0;
  bool _flagging = false;
  bool _srttTrigger = false;
  int _glitchTrigger = 0;
  int _lastQuickConfirmation = 0;
  int _sendInterval = 250;
  int _lastHeight = 0;
  int _lastWidth = 0;

  // Context for the parser callback while one byte is being handled.
  MoshFramebuffer? _fb;
  int _now = 0;

  set localFrameSent(int x) => _localFrameSent = x;
  set localFrameLateAcked(int x) => _localFrameLateAcked = x;
  set sendInterval(int x) => _sendInterval = x;

  _CursorMove get _cursor => _cursors.last;

  /// Draws the predictions that should be visible onto [fb].
  void apply(MoshFramebuffer fb) {
    if (mode == MoshPredictionMode.never) return;
    if (!(_srttTrigger ||
        _glitchTrigger > 0 ||
        mode == MoshPredictionMode.always)) {
      return;
    }
    for (final cursor in _cursors) {
      cursor.apply(fb, _confirmedEpoch);
    }
    for (final row in _overlays) {
      for (final cell in row.cells) {
        cell.apply(fb, _confirmedEpoch, row.rowNum, _flagging);
      }
    }
  }

  void _killEpoch(int epoch, MoshFramebuffer fb) {
    _cursors.removeWhere((c) => c.tentative(epoch - 1));
    _cursors.add(
      _CursorMove(
        _localFrameSent + 1,
        fb.ds.cursorRow,
        fb.ds.cursorCol,
        _predictionEpoch,
      )..active = true,
    );
    for (final row in _overlays) {
      for (final cell in row.cells) {
        if (cell.tentative(epoch - 1)) cell.reset();
      }
    }
    _becomeTentative();
  }

  void reset() {
    _cursors.clear();
    _overlays.clear();
    _becomeTentative();
  }

  void _initCursor(MoshFramebuffer fb) {
    if (_cursors.isEmpty) {
      _cursors.add(
        _CursorMove(
          _localFrameSent + 1,
          fb.ds.cursorRow,
          fb.ds.cursorCol,
          _predictionEpoch,
        )..active = true,
      );
    } else if (_cursor.tentativeUntilEpoch != _predictionEpoch) {
      _cursors.add(
        _CursorMove(
          _localFrameSent + 1,
          _cursor.row,
          _cursor.col,
          _predictionEpoch,
        )..active = true,
      );
    }
  }

  /// Checks every outstanding prediction against the server's newest screen.
  void cull(MoshFramebuffer fb, int now) {
    if (mode == MoshPredictionMode.never) return;
    if (_lastHeight != fb.ds.height || _lastWidth != fb.ds.width) {
      _lastHeight = fb.ds.height;
      _lastWidth = fb.ds.width;
      reset();
    }

    if (_sendInterval > _srttTriggerHigh) {
      _srttTrigger = true;
    } else if (_srttTrigger && _sendInterval <= _srttTriggerLow && !_active) {
      _srttTrigger = false;
    }
    if (_sendInterval > _flagTriggerHigh) {
      _flagging = true;
    } else if (_sendInterval <= _flagTriggerLow) {
      _flagging = false;
    }
    if (_glitchTrigger > _glitchRepairCount) _flagging = true;

    for (final row in List<_OverlayRow>.of(_overlays)) {
      if (row.rowNum < 0 || row.rowNum >= fb.ds.height) {
        _overlays.remove(row);
        continue;
      }
      for (var j = 0; j < row.cells.length; j++) {
        final cell = row.cells[j];
        switch (cell.validity(fb, row.rowNum, _localFrameLateAcked)) {
          case _Validity.incorrectOrExpired:
            if (cell.tentative(_confirmedEpoch)) {
              _killEpoch(cell.tentativeUntilEpoch, fb);
            } else {
              reset();
              return;
            }
          case _Validity.correct:
            if (cell.tentativeUntilEpoch > _confirmedEpoch) {
              _confirmedEpoch = cell.tentativeUntilEpoch;
            }
            // Quick confirmations slowly cure the glitch trigger.
            if (now - cell.predictionTime < _glitchThreshold &&
                _glitchTrigger > 0 &&
                now - _glitchRepairMinInterval >= _lastQuickConfirmation) {
              _glitchTrigger--;
              _lastQuickConfirmation = now;
            }
            // Match the rest of the row to the renditions that came back.
            final actual = fb.cell(row.rowNum, cell.col).renditions;
            for (var k = j; k < row.cells.length; k++) {
              row.cells[k].replacement.renditions = actual;
            }
            cell.reset();
          case _Validity.correctNoCredit:
            cell.reset();
          case _Validity.pending:
            // A prediction outstanding a long time shows predictions even
            // on a fast link.
            if (now - cell.predictionTime >= _glitchFlagThreshold) {
              _glitchTrigger = _glitchRepairCount * 2;
            } else if (now - cell.predictionTime >= _glitchThreshold &&
                _glitchTrigger < _glitchRepairCount) {
              _glitchTrigger = _glitchRepairCount;
            }
          case _Validity.inactive:
            break;
        }
      }
    }

    if (_cursors.isNotEmpty &&
        _cursor.validity(fb, _localFrameLateAcked) ==
            _Validity.incorrectOrExpired) {
      reset();
      return;
    }
    _cursors.removeWhere(
      (c) => c.validity(fb, _localFrameLateAcked) != _Validity.pending,
    );
  }

  _OverlayRow _rowFor(int rowNum, int numCols) {
    for (final row in _overlays) {
      if (row.rowNum == rowNum) return row;
    }
    final row = _OverlayRow(rowNum);
    for (var i = 0; i < numCols; i++) {
      row.cells.add(_OverlayCell(0, i, _predictionEpoch));
    }
    _overlays.add(row);
    return row;
  }

  /// One byte the user typed, against the screen as last shown.
  void newUserByte(int byte, MoshFramebuffer fb, int now) {
    if (mode == MoshPredictionMode.never) return;
    cull(fb, now);

    // An application-mode cursor key predicts like a normal one.
    if (_lastByte == 0x1b && byte == 0x4f) byte = 0x5b;
    _lastByte = byte;

    _fb = fb;
    _now = now;
    try {
      for (final ch in _utf8.add(byte)) {
        _parser.input(ch);
      }
    } finally {
      _fb = null;
    }
  }

  void _onAction(MoshAction action, int ch) {
    final fb = _fb!;
    final now = _now;
    switch (action) {
      case MoshAction.print:
        _initCursor(fb);
        if (ch == 0x7f) {
          _predictBackspace(fb, now);
        } else if (ch < 0x20 || moshCharWidth(ch) != 1) {
          _becomeTentative();
        } else {
          _predictCharacter(ch, fb, now);
        }
      case MoshAction.execute:
        _becomeTentative();
        if (ch == 0x0d) _newlineCarriageReturn(fb);
      case MoshAction.escDispatch:
        _becomeTentative();
      case MoshAction.csiDispatch:
        if (ch == 0x43) {
          // Right arrow.
          _initCursor(fb);
          if (_cursor.col < fb.ds.width - 1) {
            _cursor.col++;
            _cursor.expire(_localFrameSent + 1, now);
          }
        } else if (ch == 0x44) {
          // Left arrow.
          _initCursor(fb);
          if (_cursor.col > 0) {
            _cursor.col--;
            _cursor.expire(_localFrameSent + 1, now);
          }
        } else {
          _becomeTentative();
        }
      default:
        break;
    }
  }

  void _predictBackspace(MoshFramebuffer fb, int now) {
    final row = _rowFor(_cursor.row, fb.ds.width);
    if (_cursor.col <= 0) return;
    _cursor.col--;
    _cursor.expire(_localFrameSent + 1, now);
    for (var i = _cursor.col; i < fb.ds.width; i++) {
      final cell = row.cells[i];
      cell
        ..resetWithOrig()
        ..active = true
        ..tentativeUntilEpoch = _predictionEpoch
        ..expire(_localFrameSent + 1, now);
      cell.originalContents.add(fb.cell(_cursor.row, i).copy());
      if (i + 2 < fb.ds.width) {
        final next = row.cells[i + 1];
        if (next.active) {
          if (next.unknown) {
            cell.unknown = true;
          } else {
            cell
              ..unknown = false
              ..replacement = next.replacement.copy();
          }
        } else {
          cell
            ..unknown = false
            ..replacement = fb.cell(_cursor.row, i + 1).copy();
        }
      } else {
        cell.unknown = true;
      }
    }
  }

  void _predictCharacter(int ch, MoshFramebuffer fb, int now) {
    final row = _rowFor(_cursor.row, fb.ds.width);
    // The last column is tricky: emacs shows a wrap mark, a shell just
    // prints there.
    if (_cursor.col + 1 >= fb.ds.width) _becomeTentative();

    // Insert, shifting the rest of the row right.
    for (var i = fb.ds.width - 1; i > _cursor.col; i--) {
      final cell = row.cells[i];
      cell
        ..resetWithOrig()
        ..active = true
        ..tentativeUntilEpoch = _predictionEpoch
        ..expire(_localFrameSent + 1, now);
      cell.originalContents.add(fb.cell(_cursor.row, i).copy());
      final prev = row.cells[i - 1];
      if (i == fb.ds.width - 1) {
        cell.unknown = true;
      } else if (prev.active) {
        if (prev.unknown) {
          cell.unknown = true;
        } else {
          cell
            ..unknown = false
            ..replacement = prev.replacement.copy();
        }
      } else {
        cell
          ..unknown = false
          ..replacement = fb.cell(_cursor.row, i - 1).copy();
      }
    }

    final cell = row.cells[_cursor.col];
    cell
      ..resetWithOrig()
      ..active = true
      ..tentativeUntilEpoch = _predictionEpoch
      ..expire(_localFrameSent + 1, now);
    var renditions = fb.ds.renditions;
    // Match the character to the left.
    if (_cursor.col > 0) {
      final prev = row.cells[_cursor.col - 1];
      renditions = prev.active && !prev.unknown
          ? prev.replacement.renditions
          : fb.cell(_cursor.row, _cursor.col - 1).renditions;
    }
    cell.replacement = MoshCell(0)
      ..renditions = renditions
      ..append(ch);
    cell.originalContents.add(fb.cell(_cursor.row, _cursor.col).copy());

    _cursor.expire(_localFrameSent + 1, now);
    if (_cursor.col < fb.ds.width - 1) {
      _cursor.col++;
    } else {
      _becomeTentative();
      _newlineCarriageReturn(fb);
    }
  }

  void _newlineCarriageReturn(MoshFramebuffer fb) {
    _initCursor(fb);
    _cursor.col = 0;
    if (_cursor.row == fb.ds.height - 1) {
      // Scrolling is not predicted; the last row is predicted blank.
      final row = _rowFor(_cursor.row, fb.ds.width);
      for (final cell in row.cells) {
        cell
          ..active = true
          ..tentativeUntilEpoch = _predictionEpoch
          ..expire(_localFrameSent + 1, _now)
          ..replacement.clear();
      }
    } else {
      _cursor.row++;
    }
  }

  void _becomeTentative() => _predictionEpoch++;

  bool get _active =>
      _cursors.isNotEmpty ||
      _overlays.any((row) => row.cells.any((cell) => cell.active));

  /// While predictions are outstanding and the timing triggers have not all
  /// fired, check again every 50 ms.
  int get waitTime =>
      !(_glitchTrigger > 0 && _flagging) && _active ? 50 : 1 << 30;
}

/// Decodes UTF-8 a byte at a time, as the user types it.
class _Utf8Stream {
  final List<int> _pending = [];
  var _needed = 0;

  Iterable<int> add(int byte) sync* {
    if (_pending.isEmpty) {
      if (byte < 0x80) {
        yield byte;
        return;
      }
      if (byte >= 0xc2 && byte <= 0xdf) {
        _needed = 1;
      } else if (byte >= 0xe0 && byte <= 0xef) {
        _needed = 2;
      } else if (byte >= 0xf0 && byte <= 0xf4) {
        _needed = 3;
      } else {
        yield 0xfffd;
        return;
      }
      _pending.add(byte);
      return;
    }
    if (byte & 0xc0 != 0x80) {
      // A sequence cut short: replace it, and start again with this byte.
      _pending.clear();
      yield 0xfffd;
      yield* add(byte);
      return;
    }
    _pending.add(byte);
    if (_pending.length < _needed + 1) return;
    var cp = _pending.first & (0x7f >> (_needed + 1));
    for (final b in _pending.skip(1)) {
      cp = (cp << 6) | (b & 0x3f);
    }
    _pending.clear();
    yield cp;
  }
}
