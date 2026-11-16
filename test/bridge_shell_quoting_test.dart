import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/bridge/bridge_tools.dart';
import 'package:secure_shell_go/services/log_tail.dart';
import 'package:secure_shell_go/services/shell_quote.dart';

import 'support/bridge_fakes.dart';
import 'support/bridge_temp_dir.dart';

/// Which shell parses which layer of a bridge command:
///  - the OUTER line `sh -c '<wrapper>' ssg-bridge '<template>'` is parsed by
///    the account's LOGIN shell (sh, bash, zsh or fish): `loginShellQuote`;
///  - the template is parsed by `/bin/sh -c "$1"` inside the wrapper, so the
///    values quoted inside it use `posixSingleQuote`.
void main() {
  // fish reads \\ and \' inside single quotes as escapes; sh does not. This
  // is a MODEL of fish's lexing for the word forms the app emits, not fish.
  String fishWord(String s) {
    final out = StringBuffer();
    var i = 0;
    while (i < s.length) {
      final c = s[i];
      if (c == "'") {
        i++;
        while (true) {
          if (i >= s.length) throw FormatException('unterminated: $s');
          if (s[i] == r'\' &&
              i + 1 < s.length &&
              (s[i + 1] == r'\' || s[i + 1] == "'")) {
            out.write(s[i + 1]);
            i += 2;
          } else if (s[i] == "'") {
            i++;
            break;
          } else {
            out.write(s[i++]);
          }
        }
      } else if (c == '"') {
        i++;
        while (true) {
          if (i >= s.length) throw FormatException('unterminated: $s');
          if (s[i] == r'\' && i + 1 < s.length && r'\"$'.contains(s[i + 1])) {
            out.write(s[i + 1]);
            i += 2;
          } else if (s[i] == '"') {
            i++;
            break;
          } else {
            out.write(s[i++]);
          }
        }
      } else if (c == r'\' && i + 1 < s.length) {
        out.write(s[i + 1]);
        i += 2;
      } else {
        throw FormatException('unquoted $c in $s');
      }
    }
    return out.toString();
  }

  group('BridgeCommands.loginShellQuote', () {
    final q = BridgeCommands.loginShellQuote;

    test('a value with no backslash is exactly posixSingleQuote', () {
      for (final v in [
        '',
        'plain',
        'a b',
        "it's",
        "'''",
        r'$(x) `y` ; | & *',
        '-n x',
        "line\nbreak",
        'é€😀',
      ]) {
        expect(q(v), posixSingleQuote(v), reason: v);
      }
    });

    test('a backslash is closed out of the single quotes', () {
      expect(q(r'a\b'), r"""'a'"\\"'b'""");
      expect(q(r'\'), r"""''"\\"''""");
      expect(q(r'a\'), r"""'a'"\\"''""");
      expect(q(r'\\'), r"""''"\\"''"\\"''""");
    });

    test('quotes and backslashes mixed', () {
      expect(q(r"\'"), r"""''"\\"''\'''""");
      expect(q(r"'\''"), r"""''\'''"\\"''\'''\'''""");
      expect(q("'''"), r"''\'''\'''\'''");
    });

    test('backslash then newline', () {
      expect(q('a\\\nb'), "'a'\"\\\\\"'\nb'");
    });

    test('no backslash is left inside single quotes', () {
      for (final v in [r'x\', r'\\', "a\\\nb", r"'\''", "'" * 50, r'\' * 50]) {
        final out = q(v);
        // Walk the output the way sh does: inside single quotes, no `\`.
        var inSingle = false;
        var inDouble = false;
        for (var i = 0; i < out.length; i++) {
          final c = out[i];
          if (inSingle) {
            expect(c, isNot(r'\'), reason: out);
            if (c == "'") inSingle = false;
          } else if (inDouble) {
            if (c == r'\') {
              i++;
            } else if (c == '"') {
              inDouble = false;
            }
          } else if (c == "'") {
            inSingle = true;
          } else if (c == '"') {
            inDouble = true;
          } else if (c == r'\') {
            i++;
          }
        }
        expect(inSingle || inDouble, false, reason: out);
      }
    });
  });

  group('the outer command line under fish (MODEL of fish; real fish NOT run)',
      () {
    final hostile = <String>[
      r'echo foo\',
      r'echo \\',
      r"echo 'a'\''b'",
      r"echo \'",
      "it's",
      'a\nb\\\nc',
      r'$(touch pwned); `x`',
      '-n x',
      "'" * 4096,
      r'\' * 4096,
      'tab\there é€😀',
    ];

    test('the model reads the old quoting wrongly: this is the defect', () {
      expect(
        () => fishWord(posixSingleQuote(r'echo foo\')),
        throwsFormatException,
      );
      expect(fishWord(posixSingleQuote(r'a\\b')), r'a\b');
    });

    test('loginShellQuote and the whole supervised line survive it', () {
      final shape = BridgeCommands.supervised('X');
      final prefix = shape.substring(0, shape.length - "'X'".length);
      for (final c in hostile) {
        expect(fishWord(BridgeCommands.loginShellQuote(c)), c, reason: c);
        final line = BridgeCommands.supervised(c);
        expect(line.startsWith(prefix), true);
        expect(fishWord(line.substring(prefix.length)), c, reason: c);
        // Nothing but quoted words: the wrapper decodes to itself too.
        final wrapperWord = prefix
            .substring('sh -c '.length, prefix.length - ' ssg-bridge '.length);
        expect(fishWord(wrapperWord), startsWith('exec 3<&0'));
      }
    });

    test('the fake transport decodes both quoting styles', () {
      for (final c in hostile) {
        expect(unsupervise(BridgeCommands.supervised(c)), c, reason: c);
      }
    });
  });

  group('real shells run the supervised command line', () {
    final skipWin = Platform.isWindows
        ? 'needs /bin/sh, bash and POSIX tools; the remote side is POSIX'
        : null;
    // The login shells to try. fish is run only when it is installed.
    final shells = <String>[
      for (final p in ['/bin/sh', '/usr/bin/bash'])
        if (!Platform.isWindows && File(p).existsSync()) p,
    ];
    String? fishPath;
    if (!Platform.isWindows) {
      final r = Process.runSync('sh', ['-c', 'command -v fish']);
      final p = (r.stdout as String).trim();
      if (r.exitCode == 0 && p.isNotEmpty) fishPath = p;
    }

    late Directory temp;
    late Directory bin;
    late String marker;

    setUp(() async {
      temp = await bridgeTempDir('shellq');
      marker = '${temp.path}/MARKER';
      bin = Directory('${temp.path}/bin')..createSync();
      const stub = r'''#!/bin/sh
n=${0##*/}
case $n in tail) f=$SSG_CAP/tail$1;; *) f=$SSG_CAP/$n;; esac
for a in "$@"; do printf '%s\0' "$a"; done > "$f"
''';
      for (final n in ['find', 'tail', 'journalctl']) {
        final f = File('${bin.path}/$n')..writeAsStringSync(stub);
        Process.runSync('chmod', ['755', f.path]);
      }
    });

    tearDown(() async {
      await deleteTempDir(temp);
    });

    // [run] is the length of the long runs: find and probeReadable carry the
    // value twice in their text, and two 4096-quote runs, once quoted for sh
    // and again for the login shell, pass the 128 KiB limit on one argument.
    List<String> hostile(int run) => [
      r'x\',
      r'\',
      r"a'\''b",
      r"'\''" * 40,
      r'$(touch MARKER)'.replaceAll('MARKER', marker),
      '`touch $marker`',
      '; touch $marker; ',
      "'; touch $marker; '",
      r"x\'; touch " + marker + r"; '",
      'x\\ ; touch $marker #',
      '-n x',
      "'" * run,
      r'\' * run,
    ];

    // Each case: a template, the file the stub (or function) writes, and
    // the arguments that file must hold.
    Map<String, ({String template, Map<String, List<String>> expected})>
    cases(String v) => {
      'journal': (
        template: BridgeCommands.journal(v, 50),
        expected: {
          'journalctl': [
            '--no-pager', '-q', '-o', 'short-iso', '-n', '50', '-u', v,
          ],
        },
      ),
      'tailFile': (
        template: BridgeCommands.tailFile(v, 50),
        expected: {
          'tail-c': ['-c', '${BridgeCommands.tailWindowBytes}', '--', v],
          'tail-n': ['-n', '50'],
        },
      ),
      'findByName dir': (
        template: BridgeCommands.findByName(v, 'x', depth: 3, limit: 5),
        expected: {
          'find': [v, '-maxdepth', '3', '-name', 'x', '-print'],
        },
      ),
      'findByName pattern': (
        template: BridgeCommands.findByName('/d', v, depth: 3, limit: 5),
        expected: {
          'find': ['/d', '-maxdepth', '3', '-name', v, '-print'],
        },
      ),
      'probeReadable': (
        // `test` is a builtin: a function of that name records its words.
        template:
            'test() { for a in "\$@"; do printf "%s\\0" "\$a"; done '
            '>> "\$SSG_CAP/test"; }; ${LogTailCommands.probeReadable(v)}',
        expected: {
          'test': ['-f', v, '-r', v],
        },
      ),
    };

    Future<void> check(String shell) async {
      final names = cases('x').keys.toList();
      for (final name in names) {
        for (final v in hostile(name == 'journal' || name == 'tailFile' ? 4096 : 1024)) {
          final cap = await temp.createTemp('cap');
          final line = BridgeCommands.supervised(cases(v)[name]!.template);
          // stdin stays open until the command ends, as on an ssh channel:
          // closing it is how the app stops a call.
          final proc = await Process.start(
            shell,
            ['-c', line],
            workingDirectory: temp.path,
            environment: {
              'PATH': '${bin.path}:/usr/bin:/bin',
              'SSG_CAP': cap.path,
            },
            includeParentEnvironment: false,
          );
          final stderrText = utf8.decodeStream(proc.stderr);
          unawaited(proc.stdout.drain<void>());
          final code = await proc.exitCode;
          await proc.stdin.close().catchError((Object _) {});
          final r = (exitCode: code, stderr: await stderrText);
          final why = '$shell $name ${v.length > 60 ? v.substring(0, 60) : v}';
          expect(r.exitCode, 0, reason: '$why: ${r.stderr}');
          expect(File(marker).existsSync(), false, reason: why);
          for (final e in cases(v)[name]!.expected.entries) {
            final file = File('${cap.path}/${e.key}');
            expect(file.existsSync(), true, reason: '$why ${e.key}');
            final got = utf8
                .decode(file.readAsBytesSync())
                .split('\u0000')
              ..removeLast();
            expect(got, e.value, reason: '$why ${e.key}');
          }
          // Nothing else was run in the capture directory.
          final extra = cap.listSync().map((f) => f.uri.pathSegments.last);
          expect(
            extra.toSet(),
            cases(v)[name]!.expected.keys.toSet(),
            reason: why,
          );
          await cap.delete(recursive: true);
        }
      }
      expect(temp.listSync().whereType<File>(), isEmpty);
    }

    for (final shell in shells) {
      test('$shell: the inner command gets exactly the value, nothing else '
          'runs', () => check(shell), skip: skipWin);
    }

    test(
      'fish (real) when installed',
      () => check(fishPath!),
      skip: fishPath == null
          ? 'fish is not installed here: real fish was NOT run'
          : skipWin,
    );
  });
}
