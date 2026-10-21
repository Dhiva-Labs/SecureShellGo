import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/session_recorder.dart';

String strip(List<String> chunks, {bool flush = true}) {
  final stripper = TerminalTextStripper();
  final out = StringBuffer();
  for (final chunk in chunks) {
    out.write(stripper.add(chunk));
  }
  if (flush) out.write(stripper.flush());
  return out.toString();
}

void main() {
  group('plain text', () {
    test('colours and styles are taken out', () {
      expect(
        strip(['\x1b[1;31merror\x1b[0m: \x1b[38;5;208mdisk\x1b[m full\r\n']),
        'error: disk full\n',
      );
    });

    test('a sequence split between chunks is still taken out whole', () {
      expect(strip(['ok \x1b[3', '2mgreen\x1b', '[0m\r', '\n']), 'ok green\n');
    });

    test('titles, hyperlinks and other strings are dropped', () {
      expect(
        strip([
          '\x1b]0;deploy@web: ~\x07',
          '\x1b]8;;https://example.com\x1b\\link\x1b]8;;\x1b\\',
          '\x1bPq#0;2;0;0;0\x1b\\',
          ' done\r\n',
        ]),
        'link done\n',
      );
    });

    test('mode switches and charset designations leave nothing', () {
      expect(
        strip(['\x1b[?2004h\x1b(B\x1b)0\x1b=\x1b7ready\x1b8\x1b[?25l\r\n']),
        'ready\n',
      );
    });

    test('a progress bar is its last state', () {
      expect(
        strip(['  0%\r', ' 50%\r', '100% done\r\n']),
        '100% done\n',
      );
      expect(
        strip(['downloading 10%', '\r\x1b[K', 'downloaded\r\n']),
        'downloaded\n',
      );
    });

    test('backspacing over a typo reads as the correction', () {
      // What a shell echoes for "lx", Backspace, "s".
      expect(strip(['l', 'x', '\b \b', 's', '\r\n']), 'ls\n');
      expect(strip(['abc\b\x1b[K\r\n']), 'ab\n');
    });

    test('line-editor moves and deletes are followed', () {
      // Cursor back two, delete one: "abcd" becomes "abd".
      expect(strip(['abcd\x1b[2D\x1b[P\r\n']), 'abd\n');
      // Insert a blank, then type into it.
      expect(strip(['ac\x1b[D\x1b[@b\r\n']), 'abc\n');
      // Absolute column, erase characters.
      expect(strip(['hello\x1b[2G\x1b[3X\r\n']), 'h   o\n');
      // Cursor forward over blanks.
      expect(strip(['a\x1b[3Cb\r\n']), 'a   b\n');
    });

    test('the bell and other controls are dropped; tabs are kept', () {
      expect(strip(['a\x07b\x00c\x0ed\x7f\te\r\n']), 'abcd\te\n');
    });

    test('8-bit CSI is understood too', () {
      expect(strip(['\u009b31mred\u009b0m\r\n']), 'red\n');
    });

    test('the unfinished line is written on flush, without a newline', () {
      final stripper = TerminalTextStripper();
      expect(stripper.add('one\r\ntwo\r\ndeploy@web:~\$ '), 'one\ntwo\n');
      expect(stripper.flush(), 'deploy@web:~\$');
      expect(stripper.flush(), '');
    });

    test('a line with no end is written once it is very long', () {
      final stripper = TerminalTextStripper();
      final out =
          stripper.add('x' * (TerminalTextStripper.maxLineLength + 10));
      expect(out, '${'x' * TerminalTextStripper.maxLineLength}\n');
      expect(stripper.flush(), 'x' * 10);
    });

    test('wide and astral characters pass through', () {
      expect(strip(['日本語 🙂 ok\r\n']), '日本語 🙂 ok\n');
    });
  });

  group('the recorder', () {
    test('as received keeps every byte, header and footer around it', () async {
      final sink = MemoryLogSink();
      final recorder = SessionRecorder(
        sink: sink,
        plainText: false,
        header: 'Session log for dev@example.com',
      );
      recorder.add('\x1b[32mok\x1b[0m\r\n');
      recorder.add('\$ ');
      await recorder.finish(footer: 'Session log ended');
      expect(
        utf8.decode(sink.takeBytes()),
        'Session log for dev@example.com\n'
        '\x1b[32mok\x1b[0m\r\n\$ \n'
        'Session log ended\n',
      );
    });

    test('plain text writes the unfinished line at the end', () async {
      final sink = MemoryLogSink();
      final recorder = SessionRecorder(sink: sink);
      recorder.add('\x1b[1mwelcome\x1b[0m\r\nprompt\$ ');
      await recorder.finish();
      expect(utf8.decode(sink.takeBytes()), 'welcome\nprompt\$');
    });

    test('stops itself when full, on a character boundary', () async {
      final sink = MemoryLogSink();
      final recorder =
          SessionRecorder(sink: sink, plainText: false, maxBytes: 10);
      recorder.add('abcdefgh');
      expect(recorder.stoppedBy, isNull);
      // "é" is two bytes: only one byte of room is left after "ab".
      recorder.add('éé');
      expect(recorder.stoppedBy, RecordingStop.full);
      expect(recorder.bytesWritten, 10);
      recorder.add('more');
      await recorder.finish(footer: 'not written when full');
      expect(utf8.decode(sink.takeBytes()), 'abcdefghé');
    });

    test('discard throws the log away', () async {
      final sink = MemoryLogSink();
      final recorder = SessionRecorder(sink: sink, plainText: false);
      recorder.add('secret');
      await recorder.discard();
      expect(sink.length, 0);
      recorder.add('after');
      expect(sink.length, 0);
    });
  });

  group('a recording terminal', () {
    test('copies what is written while recording, and only then', () async {
      final terminal = RecordingTerminal(maxLines: 100);
      final changes = <SessionRecorder>[];
      terminal.recordingChanges.listen(changes.add);
      terminal.write('before\r\n');

      final sink = MemoryLogSink();
      final recorder = SessionRecorder(sink: sink, plainText: false);
      terminal.startRecording(recorder);
      expect(terminal.isRecording, isTrue);
      terminal.write('during\r\n');
      expect(terminal.stopRecording(), same(recorder));
      terminal.write('after\r\n');
      await recorder.finish();

      expect(utf8.decode(sink.takeBytes()), 'during\r\n');
      expect(terminal.isRecording, isFalse);
      expect(changes, [recorder, recorder]);
      // And the screen got all of it.
      expect(terminal.buffer.getText(), contains('after'));
    });

    test('one recording at a time', () {
      final terminal = RecordingTerminal();
      terminal.startRecording(SessionRecorder(sink: MemoryLogSink()));
      expect(
        () => terminal.startRecording(SessionRecorder(sink: MemoryLogSink())),
        throwsStateError,
      );
    });

    test('a full recording takes itself off and says so', () {
      final terminal = RecordingTerminal();
      final changes = <SessionRecorder>[];
      terminal.recordingChanges.listen(changes.add);
      final recorder = SessionRecorder(
        sink: MemoryLogSink(),
        plainText: false,
        maxBytes: 4,
      );
      terminal.startRecording(recorder);
      terminal.write('12345');
      expect(terminal.isRecording, isFalse);
      expect(changes.last.stoppedBy, RecordingStop.full);
      expect(terminal.stopRecording(), isNull);
    });
  });

  group('a log file', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('ssg_log'));
    tearDown(() async => dir.delete(recursive: true));

    test('is written as the session runs', () async {
      final file = File('${dir.path}/session.log');
      final recorder = SessionRecorder(sink: FileLogSink(file));
      recorder.add('\x1b[31mone\x1b[0m\r\ntwo\r\n');
      await recorder.finish(footer: 'end');
      expect(await file.readAsString(), 'one\ntwo\n\nend\n');
    });

    test('a discarded one is removed', () async {
      final file = File('${dir.path}/gone.log');
      final recorder = SessionRecorder(sink: FileLogSink(file));
      recorder.add('x\r\n');
      await recorder.discard();
      expect(await file.exists(), isFalse);
    });

    test('a file that cannot be written stops the recording', () async {
      final terminal = RecordingTerminal();
      final stopped = terminal.recordingChanges
          .firstWhere((r) => r.stoppedBy != null);
      final recorder = SessionRecorder(
        sink: FileLogSink(File('${dir.path}/no/such/dir/x.log')),
      );
      terminal.startRecording(recorder);
      terminal.write('x\r\n');
      final why = await stopped.timeout(const Duration(seconds: 5));
      expect(why.stoppedBy, RecordingStop.failed);
      expect(why.failure, isA<FileSystemException>());
      expect(terminal.isRecording, isFalse);
    });
  });

  group('naming', () {
    test('a file name from the host and the time', () {
      final when = DateTime(2026, 10, 21, 9, 5, 7);
      expect(sessionLogFileName('web-01', when), 'web-01-2026-10-21_09-05-07.log');
      expect(
        sessionLogFileName('Production DB: eu/west*1', when),
        'Production-DB-eu-west-1-2026-10-21_09-05-07.log',
      );
      expect(sessionLogFileName('...', when), 'session-2026-10-21_09-05-07.log');
      expect(sessionLogTimestamp(when), '2026-10-21 09:05:07');
    });
  });
}
