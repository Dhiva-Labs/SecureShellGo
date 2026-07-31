import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/log_tail.dart';
import 'package:secure_shell_go/services/remote_exec.dart';
import 'package:secure_shell_go/services/shell_quote.dart';

import 'fake_exec_session.dart';

/// A filename that is legal on every unix and is also, read naively, four
/// shell commands. Every quoting test below uses this one.
const _hostilePath = "/var/log/evil'; touch /tmp/ssg_pwned; echo '.log";

void main() {
  group('posixSingleQuote', () {
    test('a plain value is simply wrapped', () {
      expect(posixSingleQuote('/var/log/syslog'), "'/var/log/syslog'");
    });

    test("an embedded quote becomes '\\''", () {
      expect(posixSingleQuote("o'brien"), "'o'\\''brien'");
    });

    test('shell metacharacters are left literal inside the quotes', () {
      expect(
        posixSingleQuote(r'$HOME `id` $(id) \ ; | & > <'),
        r"'$HOME `id` $(id) \ ; | & > <'",
      );
    });

    test('an empty value is a well-formed empty argument', () {
      expect(posixSingleQuote(''), "''");
    });
  });

  group('posixSingleQuote — run through a real shell', () {
    // The rule is only worth anything if a real POSIX shell agrees with it,
    // so these round-trip arbitrary values through `sh` and compare bytes.
    Future<String> echoBack(String value) async {
      final result = await Process.run(
        'sh',
        ['-c', 'printf %s ${posixSingleQuote(value)}'],
      );
      expect(result.exitCode, 0, reason: result.stderr.toString());
      return result.stdout as String;
    }

    for (final (name, value) in const [
      ('a plain path', '/var/log/syslog'),
      ('a single quote', "o'brien"),
      ('a command substitution', r'$(touch /tmp/ssg_nope)'),
      ('backticks', r'`touch /tmp/ssg_nope`'),
      ('a variable', r'$HOME'),
      ('a semicolon chain', '; rm -rf /'),
      ('newlines', 'one\ntwo'),
      ('the hostile path', _hostilePath),
      ('unicode', 'журнал-日誌.log'),
    ]) {
      test('$name survives the shell byte-for-byte', () async {
        expect(await echoBack(value), value);
      });
    }
  });

  group('LogTailCommands.tail — golden strings', () {
    test('a plain path', () {
      expect(
        LogTailCommands.tail('/var/log/syslog'),
        "tail -n 200 -F '/var/log/syslog' & "
        'p=\$!; cat >/dev/null; kill \$p 2>/dev/null',
      );
    });

    test('a custom history depth', () {
      expect(
        LogTailCommands.tail('/tmp/a.log', lines: 50),
        "tail -n 50 -F '/tmp/a.log' & "
        'p=\$!; cat >/dev/null; kill \$p 2>/dev/null',
      );
    });

    test('a hostile path is one single-quoted literal and nothing else', () {
      expect(
        LogTailCommands.tail(_hostilePath),
        "tail -n 200 -F '/var/log/evil'\\''; touch /tmp/ssg_pwned; echo '\\''.log' & "
        'p=\$!; cat >/dev/null; kill \$p 2>/dev/null',
      );
    });

    test('a path with spaces needs no separate escaping', () {
      expect(
        LogTailCommands.tail('/var/log/my app/out.log'),
        contains("-F '/var/log/my app/out.log'"),
      );
    });

    test('the history depth is clamped, so it can never become a flag', () {
      expect(LogTailCommands.tail('/a', lines: 0), contains('tail -n 1 -F'));
      expect(LogTailCommands.tail('/a', lines: -5), contains('tail -n 1 -F'));
      expect(
        LogTailCommands.tail('/a', lines: 999999),
        contains('tail -n 10000 -F'),
      );
    });

    test('probeReadable quotes the path the same way', () {
      expect(
        LogTailCommands.probeReadable(_hostilePath),
        "test -f '/var/log/evil'\\''; touch /tmp/ssg_pwned; echo '\\''.log' && "
        "test -r '/var/log/evil'\\''; touch /tmp/ssg_pwned; echo '\\''.log'",
      );
    });
  });

  group('LogTailCommands.tail — run for real against a hostile filename', () {
    // The whole security claim, rehearsed end to end: a file whose *name* is
    // a shell injection is tailed successfully, its contents come back, and
    // none of the commands embedded in the name run.
    late Directory dir;
    late File victim;
    late File canary;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('ssg_tail');
      canary = File('${dir.path}/pwned');
      // The same shape as _hostilePath, but with a slash-free payload (a
      // filename cannot contain `/`) and every command below run with its
      // working directory set to the scratch dir — so if the injection *did*
      // fire, it would land here and nowhere near the real filesystem.
      victim = File("${dir.path}/evil'; touch pwned; echo '.log");
      await victim.writeAsString('line one\nline two\nline three\n');
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('the file is read and the embedded commands never run', () async {
      final process = await Process.start(
        'sh',
        ['-c', LogTailCommands.tail(victim.path, lines: 10)],
        workingDirectory: dir.path,
      );
      // Collection starts before the close, in the order the real viewer
      // uses: open, stream for as long as the user is watching, and only
      // then let go. Closing stdin first would race the watchdog's `kill`
      // against tail's own first write and prove nothing about either.
      final outputFuture = process.stdout.transform(utf8.decoder).join();
      await Future<void>.delayed(const Duration(milliseconds: 300));

      // Exactly what LogTailSession.dispose does: close stdin, which is what
      // lets the watchdog's `cat` reach EOF and kill `tail`.
      await process.stdin.close();

      final output = await outputFuture;
      await process.exitCode.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          process.kill(ProcessSignal.sigkill);
          fail('the watchdog did not terminate tail — this is the orphan bug');
        },
      );

      expect(output, contains('line one'));
      expect(output, contains('line three'));
      expect(
        await canary.exists(),
        isFalse,
        reason: 'the filename\'s embedded `touch` must never have run',
      );
    });

    test('probeReadable accepts the hostile name and rejects a directory',
        () async {
      final good = await Process.run(
        'sh',
        ['-c', LogTailCommands.probeReadable(victim.path)],
        workingDirectory: dir.path,
      );
      expect(good.exitCode, 0);

      final directory = await Process.run(
        'sh',
        ['-c', LogTailCommands.probeReadable(dir.path)],
        workingDirectory: dir.path,
      );
      expect(directory.exitCode, isNot(0), reason: 'a directory is not a log');

      final missing = await Process.run(
        'sh',
        ['-c', LogTailCommands.probeReadable('${dir.path}/nope.log')],
        workingDirectory: dir.path,
      );
      expect(missing.exitCode, isNot(0));
      expect(await canary.exists(), isFalse);
    });

    test('the watchdog kills tail even when the file never changes', () async {
      // The case a bare channel-close would miss: `tail -F` on a quiet file
      // never writes, so it never gets SIGPIPE and would sit there forever.
      final quiet = File('${dir.path}/quiet.log');
      await quiet.writeAsString('nothing happens here\n');

      final process = await Process.start(
        'sh',
        ['-c', LogTailCommands.tail(quiet.path, lines: 1)],
        workingDirectory: dir.path,
      );
      // Let tail get as far as following the file before letting go.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await process.stdin.close();

      await process.exitCode.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          process.kill(ProcessSignal.sigkill);
          fail('tail outlived the channel on a quiet file');
        },
      );
    });
  });

  group('classifyLogLine', () {
    for (final line in const [
      '2025-07-31 12:00:00 ERROR something broke',
      'FATAL: cannot bind to port',
      'kernel: [12345.678] CRITICAL thermal event',
      'app.service: PANIC goroutine 1',
      'level=error msg="upstream refused"',
      '[EMERG] out of memory',
    ]) {
      test('error: ${line.substring(0, 20)}…', () {
        expect(classifyLogLine(line), LogSeverity.error);
      });
    }

    for (final line in const [
      '2025-07-31 12:00:00 WARN disk nearly full',
      'WARNING: deprecated option',
      'level=warn msg="retrying"',
    ]) {
      test('warning: ${line.substring(0, 18)}…', () {
        expect(classifyLogLine(line), LogSeverity.warning);
      });
    }

    for (final line in const [
      'INFO starting up',
      'DEBUG cache hit',
      'level=trace span=abc',
      'NOTICE reload complete',
    ]) {
      test('info: $line', () {
        expect(classifyLogLine(line), LogSeverity.info);
      });
    }

    test('a plain line is plain', () {
      expect(
        classifyLogLine('192.168.1.1 - - [31/Jul/2025] "GET / HTTP/1.1" 200'),
        LogSeverity.plain,
      );
    });

    test('the word boundary stops a substring from painting a line red', () {
      // These are the false positives that make a highlight rule untrustworthy.
      expect(classifyLogLine('GET /terror/index.html 200'), LogSeverity.plain);
      expect(classifyLogLine('user warnier logged in'), LogSeverity.plain);
      expect(classifyLogLine('/var/log/errors.log rotated'), LogSeverity.plain);
    });

    test('severity wins over noise on a line carrying both', () {
      expect(
        classifyLogLine('INFO handled request; ERROR in downstream'),
        LogSeverity.error,
      );
      expect(
        classifyLogLine('INFO reload; WARNING config drift'),
        LogSeverity.warning,
      );
    });

    test('matching is case-insensitive', () {
      expect(classifyLogLine('error: lowercase'), LogSeverity.error);
      expect(classifyLogLine('Warning: mixed case'), LogSeverity.warning);
    });

    test('an empty line is plain and does not throw', () {
      expect(classifyLogLine(''), LogSeverity.plain);
    });
  });

  group('LineAssembler', () {
    test('a line split across two chunks is emitted once, whole', () {
      final assembler = LineAssembler();
      expect(assembler.add('hello wo'), isEmpty);
      expect(assembler.add('rld\n'), ['hello world']);
    });

    test('several lines in one chunk all come out', () {
      final assembler = LineAssembler();
      expect(assembler.add('a\nb\nc\n'), ['a', 'b', 'c']);
    });

    test('a trailing fragment is held back until its newline', () {
      final assembler = LineAssembler();
      expect(assembler.add('a\nb\npartial'), ['a', 'b']);
      expect(assembler.add(' more\n'), ['partial more']);
    });

    test('CRLF and bare CR both count as line ends', () {
      final assembler = LineAssembler();
      expect(assembler.add('windows\r\nmac\runix\n'), [
        'windows',
        'mac',
        'unix',
      ]);
    });

    test('flush yields a final line that never got its newline', () {
      final assembler = LineAssembler();
      assembler.add('cut off here');
      expect(assembler.flush(), ['cut off here']);
    });

    test('flush after a clean boundary yields nothing', () {
      final assembler = LineAssembler();
      assembler.add('done\n');
      expect(assembler.flush(), isEmpty);
    });

    test('flush is idempotent', () {
      final assembler = LineAssembler();
      assembler.add('x');
      expect(assembler.flush(), ['x']);
      expect(assembler.flush(), isEmpty);
    });

    test('empty lines are preserved — blank lines separate log records', () {
      final assembler = LineAssembler();
      expect(assembler.add('a\n\nb\n'), ['a', '', 'b']);
    });
  });

  group('LogBuffer — the cap', () {
    test('holds everything up to the cap', () {
      final buffer = LogBuffer(capacity: 10);
      for (var i = 0; i < 10; i++) {
        buffer.add('line $i');
      }
      expect(buffer.length, 10);
    });

    test('drops from the head, never the tail', () {
      // The newest lines are the ones being watched; the oldest are the ones
      // already scrolled past.
      final buffer = LogBuffer(capacity: 3);
      buffer.addAll(['one', 'two', 'three', 'four', 'five']);

      expect(buffer.length, 3);
      expect(
        buffer.lines.map((line) => line.text),
        ['three', 'four', 'five'],
      );
    });

    test('a flood far beyond the cap stays bounded', () {
      final buffer = LogBuffer(capacity: 100);
      for (var i = 0; i < 10000; i++) {
        buffer.add('line $i');
      }
      expect(buffer.length, 100);
      expect(buffer.lines.last.text, 'line 9999');
    });

    test('the default cap is 5000', () {
      expect(LogBuffer.defaultCapacity, 5000);
      expect(LogBuffer().capacity, 5000);
    });
  });

  group('LogBuffer — pause and resume', () {
    test('a paused buffer holds lines back without losing them', () {
      final buffer = LogBuffer();
      buffer.add('before');
      buffer.pause();
      buffer.addAll(['during one', 'during two']);

      expect(buffer.isPaused, isTrue);
      expect(buffer.length, 1, reason: 'the view must not move while paused');
      expect(buffer.pendingCount, 2);
    });

    test('resume releases the held lines in arrival order', () {
      final buffer = LogBuffer();
      buffer.add('before');
      buffer.pause();
      buffer.addAll(['during one', 'during two']);
      buffer.resume();

      expect(buffer.isPaused, isFalse);
      expect(buffer.pendingCount, 0);
      expect(
        buffer.lines.map((line) => line.text),
        ['before', 'during one', 'during two'],
      );
    });

    test('the pending queue is capped too, and drops from the head', () {
      // A viewer paused and forgotten overnight must not take the app down.
      final buffer = LogBuffer(capacity: 5);
      buffer.pause();
      for (var i = 0; i < 100; i++) {
        buffer.add('line $i');
      }

      expect(buffer.pendingCount, 5);
      buffer.resume();
      expect(buffer.lines.last.text, 'line 99');
      expect(buffer.length, 5);
    });

    test('resume with nothing pending is a no-op', () {
      final buffer = LogBuffer();
      buffer.add('a');
      buffer.pause();
      buffer.resume();
      expect(buffer.lines.map((line) => line.text), ['a']);
    });

    test('pause is idempotent', () {
      final buffer = LogBuffer();
      buffer.pause();
      buffer.pause();
      buffer.add('x');
      expect(buffer.pendingCount, 1);
    });
  });

  group('LogBuffer — the filter', () {
    LogBuffer seeded() => LogBuffer()
      ..addAll([
        'INFO starting up',
        'ERROR connection refused',
        'INFO listening on 8080',
        'WARN slow query',
        'ERROR timeout talking to db',
      ]);

    test('with no filter, everything is visible', () {
      expect(seeded().visible, hasLength(5));
    });

    test('only matching lines are visible', () {
      final buffer = seeded()..filter = 'ERROR';
      expect(
        buffer.visible.map((line) => line.text),
        ['ERROR connection refused', 'ERROR timeout talking to db'],
      );
    });

    test('matching is case-insensitive', () {
      final buffer = seeded()..filter = 'error';
      expect(buffer.visible, hasLength(2));
    });

    test('the filter matches anywhere in the line, not just the start', () {
      final buffer = seeded()..filter = 'db';
      expect(buffer.visible.single.text, 'ERROR timeout talking to db');
    });

    test('the unfiltered buffer is kept intact behind the filter', () {
      final buffer = seeded()..filter = 'ERROR';
      expect(buffer.visible, hasLength(2));
      expect(buffer.lines, hasLength(5), reason: 'the filter is a lens');
      expect(buffer.length, 5);
    });

    test('clearing the filter brings the hidden lines straight back', () {
      final buffer = seeded()..filter = 'ERROR';
      buffer.filter = '';
      expect(buffer.visible, hasLength(5));
    });

    test('lines arriving while a filter is set are still stored', () {
      final buffer = seeded()..filter = 'ERROR';
      buffer.add('INFO a new line nobody can see yet');

      expect(buffer.visible, hasLength(2));
      expect(buffer.lines, hasLength(6));

      buffer.filter = '';
      expect(buffer.visible, hasLength(6));
    });

    test('a filter matching nothing shows nothing and does not throw', () {
      final buffer = seeded()..filter = 'no such text anywhere';
      expect(buffer.visible, isEmpty);
    });

    test('the filter is trimmed, so a stray space does not hide everything',
        () {
      final buffer = seeded()..filter = '  ERROR  ';
      expect(buffer.visible, hasLength(2));
    });

    test('a regex metacharacter is matched literally, not as a pattern', () {
      // Plain-text matching has no invalid states — this is why the box is
      // not a regex box.
      final buffer = LogBuffer()..addAll(['a.b', 'axb']);
      buffer.filter = 'a.b';
      expect(buffer.visible.map((line) => line.text), ['a.b']);
    });

    test('severity survives filtering', () {
      final buffer = seeded()..filter = 'ERROR';
      expect(
        buffer.visible.every((line) => line.severity == LogSeverity.error),
        isTrue,
      );
    });
  });

  group('LogBuffer — clear', () {
    test('clear empties the buffer and anything held by a pause', () {
      final buffer = LogBuffer()..addAll(['a', 'b']);
      buffer.pause();
      buffer.add('c');
      buffer.clear();

      expect(buffer.isEmpty, isTrue);
      expect(buffer.pendingCount, 0);
    });

    test('clear does not discard the filter the user typed', () {
      final buffer = LogBuffer()..addAll(['a', 'b']);
      buffer.filter = 'a';
      buffer.clear();
      expect(buffer.filter, 'a');
    });

    test('the buffer is usable again after a clear', () {
      final buffer = LogBuffer()..addAll(['a']);
      buffer.clear();
      buffer.add('b');
      expect(buffer.lines.single.text, 'b');
    });
  });

  group('LogTailSession', () {
    test('the readable probe runs before tail is started', () async {
      final transport = FakeExecTransport(
        respond: (command) => FakeExecSession(stdout: ''),
      );

      final session = await LogTailSession.open(transport, '/var/log/syslog');
      addTearDown(session.dispose);

      expect(transport.commands, [
        LogTailCommands.probeReadable('/var/log/syslog'),
        LogTailCommands.tail('/var/log/syslog'),
      ]);
    });

    test('an unreadable path fails before any tail channel is opened',
        () async {
      final transport = FakeExecTransport(exitCode: 1);

      await expectLater(
        LogTailSession.open(transport, '/etc/shadow'),
        throwsA(
          isA<MonitorFailure>().having(
            (e) => e.message,
            'message',
            contains('/etc/shadow'),
          ),
        ),
      );
      expect(
        transport.commands,
        hasLength(1),
        reason: 'tail must not be started on a path we cannot read',
      );
    });

    test('a permission-denied probe is reported as needing sudo', () async {
      final transport = FakeExecTransport(
        exitCode: 1,
        stderrText: 'sh: /var/log/secure: Permission denied',
      );

      await expectLater(
        LogTailSession.open(transport, '/var/log/secure'),
        throwsA(
          isA<MonitorFailure>()
              .having((e) => e.needsPrivilege, 'needsPrivilege', isTrue),
        ),
      );
    });

    test('whole lines are streamed as they arrive', () async {
      final controller = StreamController<String>();
      final transport = FakeExecTransport(
        respond: (command) => command.startsWith('test -f')
            ? FakeExecSession(stdout: '')
            : FakeExecSession(stdoutStream: controller.stream),
      );

      final session = await LogTailSession.open(transport, '/var/log/app.log');
      addTearDown(session.dispose);

      final received = <String>[];
      session.lines.listen(received.add);
      session.start();

      controller.add('first\nsec');
      await pumpEventQueue();
      expect(received, ['first']);

      controller.add('ond\nthird\n');
      await pumpEventQueue();
      expect(received, ['first', 'second', 'third']);

      await controller.close();
    });

    test('dispose closes stdin before the channel — the no-orphan order',
        () async {
      // This ordering *is* the guarantee: closing stdin is what lets the
      // watchdog's `cat` reach EOF and run its `kill`. Closing the channel
      // without it would leave `tail -F` running on the server.
      late FakeExecSession tailSession;
      final transport = FakeExecTransport(
        respond: (command) {
          if (command.startsWith('test -f')) return FakeExecSession(stdout: '');
          return tailSession = FakeExecSession(stdoutStream: const Stream.empty());
        },
      );

      final session = await LogTailSession.open(transport, '/var/log/app.log');
      session.start();

      expect(tailSession.stdinClosed, isFalse);
      expect(tailSession.wasClosed, isFalse);

      await session.dispose();

      expect(tailSession.stdinClosed, isTrue, reason: 'the kill signal');
      expect(tailSession.wasClosed, isTrue, reason: 'the channel is released');
    });

    test('dispose is idempotent', () async {
      final transport = FakeExecTransport(
        respond: (command) => FakeExecSession(stdout: ''),
      );
      final session = await LogTailSession.open(transport, '/var/log/app.log');
      session.start();

      await session.dispose();
      await session.dispose();
    });

    test('lines arriving after dispose are dropped, not thrown on', () async {
      final controller = StreamController<String>();
      final transport = FakeExecTransport(
        respond: (command) => command.startsWith('test -f')
            ? FakeExecSession(stdout: '')
            : FakeExecSession(stdoutStream: controller.stream),
      );

      final session = await LogTailSession.open(transport, '/var/log/app.log');
      session.start();
      await session.dispose();

      controller.add('late line\n');
      await pumpEventQueue();
      await controller.close();
    });

    test('start before any listener still delivers the -n 200 history',
        () async {
      // The history arrives immediately; a viewer that subscribed after
      // start() would miss it, which is why open() and start() are separate.
      final transport = FakeExecTransport(
        respond: (command) => command.startsWith('test -f')
            ? FakeExecSession(stdout: '')
            : FakeExecSession(stdout: 'old one\nold two\n'),
      );

      final session = await LogTailSession.open(transport, '/var/log/app.log');
      addTearDown(session.dispose);

      final received = <String>[];
      session.lines.listen(received.add);
      session.start();
      await pumpEventQueue();

      expect(received, ['old one', 'old two']);
    });

    test('stderr is folded into the scrollback beside stdout', () async {
      // `tail -F` announces truncation and logrotate on stderr; dropping
      // those would leave the user staring at a stalled pane with no reason.
      final transport = FakeExecTransport(
        respond: (command) => command.startsWith('test -f')
            ? FakeExecSession(stdout: '')
            : FakeExecSession(
                stdout: 'a line\n',
                stderrText: 'tail: /var/log/app.log: file truncated\n',
              ),
      );

      final session = await LogTailSession.open(transport, '/var/log/app.log');
      addTearDown(session.dispose);

      final received = <String>[];
      session.lines.listen(received.add);
      session.start();
      await pumpEventQueue();

      expect(received, contains('a line'));
      expect(received, contains('tail: /var/log/app.log: file truncated'));
    });
  });
}
