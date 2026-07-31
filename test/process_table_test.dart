import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/process_table.dart';
import 'package:secure_shell_go/services/remote_exec.dart';

import 'fake_exec_session.dart';

/// `ps -eo pid,user,pcpu,pmem,comm --sort=-pcpu` on Ubuntu 24.04 — the
/// column widths and alignment are exactly as procps emits them (captured,
/// not hand-drawn), with a server's process names in place of the capture
/// machine's.
const _psColumns = '''
    PID USER     %CPU %MEM COMMAND
  81256 www-data  100  0.0 ps
   4770 www-data  7.2  2.5 nginx
   4049 postgres  5.4  0.8 postgres
   2606 root      5.2  1.3 dockerd
      1 root      0.0  0.0 systemd
''';

/// Verbatim `ps aux`, Ubuntu 24.04. Note the bracketed kernel threads and
/// the command with an argument, both of which have to survive the parse.
const _psAux = '''
USER         PID %CPU %MEM    VSZ   RSS TTY      STAT START   TIME COMMAND
root           1  0.0  0.0  23988 15412 ?        Ss   12:30   0:02 /sbin/init splash
root           2  0.0  0.0      0     0 ?        S    12:30   0:00 [kthreadd]
www-data    1337 15.3  2.1 210000 90000 ?        S    10:00   1:02 nginx: worker process
''';

/// busybox `ps` on Alpine, which ignores `-o` and prints its own format.
const _busyboxPs = '''
PID   USER     TIME  COMMAND
    1 root      0:00 /sbin/init
  842 root      0:12 /usr/sbin/sshd -D
''';

void main() {
  group('parseProcessList — the -o column form', () {
    test('reads every field off a real listing', () {
      final processes = parseProcessList(_psColumns);
      expect(processes, hasLength(5));

      final first = processes.first;
      expect(first.pid, 81256);
      expect(first.user, 'www-data');
      expect(first.cpuPercent, 100);
      expect(first.memoryPercent, 0.0);
      expect(first.command, 'ps');
    });

    test('fractional percentages parse', () {
      final second = parseProcessList(_psColumns)[1];
      expect(second.cpuPercent, 7.2);
      expect(second.memoryPercent, 2.5);
    });

    test('PID 1 is flagged as init', () {
      final init = parseProcessList(_psColumns).firstWhere((p) => p.pid == 1);
      expect(init.isInit, isTrue);
      expect(parseProcessList(_psColumns).first.isInit, isFalse);
    });
  });

  group('parseProcessList — the ps aux fallback form', () {
    test('the header picks the aux column layout, not the -o one', () {
      // The important case: `ps aux` leads with USER, so reading field 0 as
      // a pid would produce nothing at all. The format is decided from the
      // header rather than from which command was asked for.
      final processes = parseProcessList(_psAux);
      expect(processes, hasLength(3));

      final init = processes.first;
      expect(init.pid, 1);
      expect(init.user, 'root');
      expect(init.cpuPercent, 0.0);
      expect(init.command, '/sbin/init splash');
    });

    test('a command containing spaces is kept whole', () {
      final nginx =
          parseProcessList(_psAux).firstWhere((p) => p.pid == 1337);
      expect(nginx.command, 'nginx: worker process');
      expect(nginx.user, 'www-data');
      expect(nginx.cpuPercent, 15.3);
    });

    test('bracketed kernel threads parse like anything else', () {
      final kthreadd =
          parseProcessList(_psAux).firstWhere((p) => p.pid == 2);
      expect(kthreadd.command, '[kthreadd]');
    });
  });

  group('parseProcessList — never throws', () {
    for (final (name, input) in const [
      ('empty', ''),
      ('whitespace', '  \n \n'),
      ('garbage', 'ps: unrecognized option'),
      ('header only', '    PID USER     %CPU %MEM COMMAND'),
      ('truncated row', '  81256 www-data  10'),
      ('non-numeric pid', '  abc www-data 1.0 1.0 thing'),
      ('an html error page', '<html>502</html>'),
    ]) {
      test('$name yields no processes and does not throw', () {
        late List<RemoteProcess> processes;
        expect(() => processes = parseProcessList(input), returnsNormally);
        expect(processes, isEmpty);
      });
    }

    test('busybox\'s own format yields nothing rather than wrong numbers', () {
      // busybox `ps` has no %CPU or %MEM at all. Reading its TIME column as
      // a CPU percentage would be a confidently wrong number, so the parse
      // declines — and ProcessTableService treats an empty parse as a
      // failure worth falling back from.
      expect(parseProcessList(_busyboxPs), isEmpty);
    });

    test('a good listing with one broken row keeps the good rows', () {
      final processes = parseProcessList(
        '    PID USER     %CPU %MEM COMMAND\n'
        '      1 root      0.0  0.0 systemd\n'
        'garbage row\n'
        '    842 root      1.0  0.5 sshd\n',
      );
      expect(processes.map((p) => p.pid), [1, 842]);
    });
  });

  group('sortProcesses', () {
    List<RemoteProcess> sample() => parseProcessList(_psColumns);

    test('by cpu, descending, is the default view', () {
      final sorted = sortProcesses(sample(), ProcessSort.cpu);
      expect(sorted.first.cpuPercent, 100);
      expect(sorted.last.cpuPercent, 0.0);
    });

    test('by cpu ascending reverses it', () {
      final sorted =
          sortProcesses(sample(), ProcessSort.cpu, descending: false);
      expect(sorted.first.cpuPercent, 0.0);
      expect(sorted.last.cpuPercent, 100);
    });

    test('by memory', () {
      final sorted = sortProcesses(sample(), ProcessSort.memory);
      expect(sorted.first.memoryPercent, 2.5);
    });

    test('by pid ascending', () {
      final sorted =
          sortProcesses(sample(), ProcessSort.pid, descending: false);
      expect(sorted.map((p) => p.pid), [1, 2606, 4049, 4770, 81256]);
    });

    test('by command, case-insensitively', () {
      final sorted =
          sortProcesses(sample(), ProcessSort.command, descending: false);
      expect(sorted.first.command, 'dockerd');
    });

    test('by user', () {
      final sorted =
          sortProcesses(sample(), ProcessSort.user, descending: false);
      expect(sorted.first.user, 'postgres');
      expect(sorted.last.user, 'www-data');
    });

    test('ties break on pid, so a refreshed list does not shimmer', () {
      // Two idle processes at 0.0% must not swap places on every poll.
      final processes = parseProcessList(
        '    PID USER     %CPU %MEM COMMAND\n'
        '      9 root      0.0  0.0 nine\n'
        '      3 root      0.0  0.0 three\n'
        '      7 root      0.0  0.0 seven\n',
      );

      final once = sortProcesses(processes, ProcessSort.cpu);
      final twice = sortProcesses(processes.reversed.toList(), ProcessSort.cpu);
      expect(once.map((p) => p.pid), twice.map((p) => p.pid));
    });

    test('sorting does not mutate the list it was given', () {
      final original = sample();
      final before = original.map((p) => p.pid).toList();
      sortProcesses(original, ProcessSort.pid);
      expect(original.map((p) => p.pid), before);
    });

    test('sorting an empty list is an empty list', () {
      expect(sortProcesses(const [], ProcessSort.cpu), isEmpty);
    });
  });

  group('ProcessCommands', () {
    test('the preferred form is the portable one plus --sort', () {
      expect(
        ProcessCommands.preferred,
        'ps -eo pid,user,pcpu,pmem,comm --sort=-pcpu',
      );
    });

    test('the fallback is bare ps aux', () {
      expect(ProcessCommands.fallback, 'ps aux');
    });

    test('kill sends TERM by default and KILL when forced', () {
      expect(ProcessCommands.kill(1337, force: false), 'kill -TERM 1337');
      expect(ProcessCommands.kill(1337, force: true), 'kill -KILL 1337');
    });

    test('PID 1 is refused outright', () {
      // Killing init takes the whole machine or container down. The UI never
      // offers it; this refuses even if some future caller forgets.
      expect(
        () => ProcessCommands.kill(1, force: false),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('pid 0 and negative pids are refused', () {
      // `kill -TERM 0` signals every process in the group and `-1` signals
      // every process the user can reach. Neither is reachable from here.
      expect(() => ProcessCommands.kill(0, force: false), throwsArgumentError);
      expect(() => ProcessCommands.kill(-1, force: true), throwsArgumentError);
    });
  });

  group('ProcessTableService.list', () {
    test('the preferred command is used when it works', () async {
      final transport = FakeExecTransport(stdout: _psColumns);

      final processes = await const ProcessTableService().list(transport);

      expect(transport.commands, [ProcessCommands.preferred]);
      expect(processes, hasLength(5));
    });

    test('a ps that refuses the flags falls back to ps aux', () async {
      final transport = FakeExecTransport(
        respond: (command) => command == ProcessCommands.preferred
            ? FakeExecSession(
                exitCode: 1,
                stderrText: 'ps: unrecognized option: sort',
              )
            : FakeExecSession(stdout: _psAux),
      );

      final processes = await const ProcessTableService().list(transport);

      expect(transport.commands, [
        ProcessCommands.preferred,
        ProcessCommands.fallback,
      ]);
      expect(processes, hasLength(3));
    });

    test('a ps that succeeds but prints an unreadable format falls back too',
        () async {
      // busybox accepts the flags, ignores them, and prints its own format.
      // Exiting zero is not the same as having answered the question.
      final transport = FakeExecTransport(
        respond: (command) => command == ProcessCommands.preferred
            ? FakeExecSession(stdout: _busyboxPs)
            : FakeExecSession(stdout: _psAux),
      );

      final processes = await const ProcessTableService().list(transport);

      expect(transport.commands, hasLength(2));
      expect(processes, hasLength(3));
    });

    test('both forms failing is a MonitorFailure', () async {
      final transport = FakeExecTransport(
        exitCode: 1,
        stderrText: 'ps: not found',
      );

      await expectLater(
        const ProcessTableService().list(transport),
        throwsA(
          isA<MonitorFailure>()
              .having((e) => e.message, 'message', contains('list processes')),
        ),
      );
    });

    test('a fallback that exits zero with nothing readable still fails',
        () async {
      final transport = FakeExecTransport(stdout: 'total nonsense');

      await expectLater(
        const ProcessTableService().list(transport),
        throwsA(isA<MonitorFailure>()),
      );
    });
  });

  group('ProcessTableService.kill', () {
    test('TERM by default', () async {
      final transport = FakeExecTransport();
      await const ProcessTableService().kill(transport, 1337);
      expect(transport.commands, ['kill -TERM 1337']);
    });

    test('KILL when forced', () async {
      final transport = FakeExecTransport();
      await const ProcessTableService().kill(transport, 1337, force: true);
      expect(transport.commands, ['kill -KILL 1337']);
    });

    test('PID 1 is refused before any command is sent', () async {
      final transport = FakeExecTransport();
      await expectLater(
        const ProcessTableService().kill(transport, 1),
        throwsArgumentError,
      );
      expect(transport.commands, isEmpty);
    });

    test('a permission failure says to use the terminal', () async {
      final transport = FakeExecTransport(
        exitCode: 1,
        stderrText: 'kill: (1337) - Operation not permitted',
      );

      await expectLater(
        const ProcessTableService().kill(transport, 1337),
        throwsA(
          isA<MonitorFailure>()
              .having((e) => e.needsPrivilege, 'needsPrivilege', isTrue)
              .having((e) => e.message, 'message', contains('needs sudo')),
        ),
      );
    });

    test('a plain failure names the pid', () async {
      final transport = FakeExecTransport(
        exitCode: 1,
        stderrText: 'kill: (9999) - No such process',
      );

      await expectLater(
        const ProcessTableService().kill(transport, 9999),
        throwsA(
          isA<MonitorFailure>()
              .having((e) => e.message, 'message', contains('9999')),
        ),
      );
    });
  });
}
