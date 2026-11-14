import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/bridge/bridge_audit.dart';

void main() {
  late Directory tempDir;
  late Directory bridgeDir;
  late File logFile;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('bridge_audit_test');
    bridgeDir = Directory('${tempDir.path}/bridge');
    logFile = File('${bridgeDir.path}/audit.log');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  var tick = 0;
  BridgeAuditLog makeLog({
    int rotateBytes = BridgeAuditLog.defaultRotateBytes,
    String Function(String)? scrub,
  }) => BridgeAuditLog(
    directory: bridgeDir,
    rotateBytes: rotateBytes,
    scrub: scrub ?? (s) => s.replaceAll('hunter2', '[redacted]'),
    clock: () => DateTime.utc(2026, 11, 14, 12, 0, tick++),
  );

  Future<bool> recordOne(
    BridgeAuditLog log, {
    String tool = 'read_file',
    Map<String, Object?> args = const {'path': '/etc/hosts'},
    BridgeAuditOutcome outcome = BridgeAuditOutcome.ok,
    String detail = '',
  }) => log.record(
    client: 'Desk assistant',
    host: 'web',
    tool: tool,
    args: args,
    outcome: outcome,
    detail: detail,
    ms: 12,
  );

  test('an entry is one JSON line with the agreed fields', () async {
    final log = makeLog();
    expect(await recordOne(log), isTrue);
    expect(log.lastWriteError, isNull);
    final lines = await logFile.readAsLines();
    expect(lines, hasLength(1));
    expect(jsonDecode(lines.single), {
      'ts': '2026-11-14T12:00:00.000Z',
      'client': 'Desk assistant',
      'host': 'web',
      'tool': 'read_file',
      'args': '{"path":"/etc/hosts"}',
      'outcome': 'ok',
      'detail': '',
      'ms': 12,
    });
  });

  test('entries are appended, and recent gives them newest first', () async {
    final log = makeLog();
    await recordOne(log, tool: 'a');
    await recordOne(log, tool: 'b', outcome: BridgeAuditOutcome.refused);
    await recordOne(log, tool: 'c', outcome: BridgeAuditOutcome.error);
    final recent = await log.recent();
    expect(recent.map((e) => e.tool), ['c', 'b', 'a']);
    expect(recent.map((e) => e.outcome), [
      BridgeAuditOutcome.error,
      BridgeAuditOutcome.refused,
      BridgeAuditOutcome.ok,
    ]);
    expect((await log.recent(limit: 2)).map((e) => e.tool), ['c', 'b']);
    expect(await log.recent(limit: 0), isEmpty);
  });

  test('a host-less tool leaves host out', () async {
    final log = makeLog();
    await log.record(
      client: 'x',
      host: null,
      tool: 'list_hosts',
      args: const {},
      outcome: BridgeAuditOutcome.ok,
      ms: 1,
    );
    final json = jsonDecode((await logFile.readAsLines()).single) as Map;
    expect(json.containsKey('host'), isFalse);
    expect((await log.recent()).single.host, isNull);
  });

  test('args and detail are scrubbed; args are capped at 500 chars', () async {
    final log = makeLog();
    await recordOne(
      log,
      args: {'path': '/srv/hunter2/${'x' * 2000}'},
      detail: 'failed with hunter2',
    );
    final entry = (await log.recent()).single;
    expect(entry.args, isNot(contains('hunter2')));
    expect(entry.args.length, lessThanOrEqualTo(BridgeAuditLog.maxArgsChars));
    expect(entry.args, endsWith('…'));
    expect(entry.detail, 'failed with [redacted]');
    expect(await logFile.readAsString(), isNot(contains('hunter2')));
  });

  test('a private key in the arguments is redacted before the cap', () async {
    final log = makeLog(scrub: (s) => s);
    const key =
        '-----BEGIN OPENSSH PRIVATE KEY-----\n'
        'b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW\n'
        'QyNTUxOQAAACBQnRzaW5nbGVrZXlib2R5Zm9ydGVzdHNvbmx5bm90YXJlYWxrZXkAAAAA\n'
        '-----END OPENSSH PRIVATE KEY-----\n';
    // Padding puts the key across the 500-character cut, where capping
    // first would have left the BEGIN line and part of the body behind.
    await recordOne(log, args: {'pad': 'x' * 450, 'value': key});
    final entry = (await log.recent()).single;
    expect(entry.args, contains('[private key redacted]'));
    expect(entry.args, isNot(contains('BEGIN')));
    expect(entry.args, isNot(contains('b3BlbnNza')));
    expect(await logFile.readAsString(), isNot(contains('b3BlbnNza')));
  });

  test('capping never splits a surrogate pair', () async {
    final log = makeLog();
    // Line the emoji up across the cut for both parities.
    for (final pad in [0, 1, 2, 3]) {
      await recordOne(log, args: {'p': '${'a' * pad}${'😀' * 400}'});
    }
    for (final entry in await log.recent()) {
      final units = entry.args.codeUnits;
      for (var i = 0; i < units.length; i++) {
        final u = units[i];
        if (u >= 0xD800 && u <= 0xDBFF) {
          expect(i + 1 < units.length, isTrue);
          expect(units[i + 1], inInclusiveRange(0xDC00, 0xDFFF));
        }
      }
    }
  });

  test('the file never holds output: only what is passed is written', () async {
    final log = makeLog();
    await recordOne(log, detail: 'read 120 bytes');
    final text = await logFile.readAsString();
    expect(text.trim().split('\n'), hasLength(1));
  });

  test('a half-written last line is skipped when reading', () async {
    final log = makeLog();
    await recordOne(log, tool: 'first');
    await recordOne(log, tool: 'second');
    // A crash part way through the next write.
    await logFile.writeAsString(
      '{"ts":"2026-11-14T12:00:09Z","cli',
      mode: FileMode.append,
    );
    final recent = await log.recent();
    expect(recent.map((e) => e.tool), ['second', 'first']);
  });

  test('the next write after a torn line starts on its own line', () async {
    final log = makeLog();
    await recordOne(log, tool: 'first');
    await logFile.writeAsString(
      '{"ts":"2026-11-14T12:00:09Z","cli',
      mode: FileMode.append,
    );
    await recordOne(log, tool: 'after');
    final recent = await log.recent();
    expect(recent.map((e) => e.tool), ['after', 'first']);
  });

  test(
    'garbage, wrong shapes and a torn UTF-8 byte are all passed over',
    () async {
      await bridgeDir.create(recursive: true);
      final good = jsonEncode({
        'ts': '2026-11-14T12:00:00.000Z',
        'client': 'c',
        'tool': 'ok_tool',
        'args': '{}',
        'outcome': 'ok',
        'detail': '',
        'ms': 1,
      });
      final bytes = <int>[
        ...utf8.encode('not json at all\n'),
        ...utf8.encode('[1,2,3]\n'),
        ...utf8.encode(
          '{"ts":"x","client":"c","tool":"t","args":"{}",'
          '"outcome":"ok","detail":"","ms":1}\n',
        ),
        ...utf8.encode(
          '{"ts":"2026-11-14T12:00:00Z","client":"c","tool":"t",'
          '"args":"{}","outcome":"maybe","detail":"","ms":1}\n',
        ),
        ...utf8.encode(
          '{"ts":"2026-11-14T12:00:00Z","client":5,"tool":"t",'
          '"args":"{}","outcome":"ok","detail":"","ms":1}\n',
        ),
        ...utf8.encode('\n   \n'),
        ...utf8.encode('$good\n'),
        ...utf8.encode('{"tool":"caf'),
        0xC3, // first byte of é, the rest never written
      ];
      await logFile.writeAsBytes(bytes);
      final log = makeLog();
      final recent = await log.recent();
      expect(recent.map((e) => e.tool), ['ok_tool']);
    },
  );

  test('rotation moves the file to .1 and keeps only one old file', () async {
    final log = makeLog(rotateBytes: 600);
    for (var i = 0; i < 20; i++) {
      await recordOne(log, tool: 'call$i');
    }
    final rotated = File('${logFile.path}.1');
    expect(await rotated.exists(), isTrue);
    expect(await File('${logFile.path}.2').exists(), isFalse);
    expect(await logFile.length(), lessThanOrEqualTo(600));
    expect(await rotated.length(), lessThanOrEqualTo(600));
    final recent = await log.recent(limit: 100);
    // Newest first, continuous across the two files, oldest lost.
    expect(recent.first.tool, 'call19');
    final numbers = [for (final e in recent) int.parse(e.tool.substring(4))];
    for (var i = 1; i < numbers.length; i++) {
      expect(numbers[i], numbers[i - 1] - 1);
    }
    expect(numbers.last, greaterThan(0));
  });

  test(
    'a write failure returns false and sets lastWriteError, no throw',
    () async {
      // A plain file where the bridge directory should be.
      await File(bridgeDir.path).writeAsString('in the way');
      final log = makeLog();
      final seen = <BridgeAuditEntry>[];
      final sub = log.entries.listen(seen.add);
      expect(await recordOne(log), isFalse);
      expect(log.lastWriteError, isNotNull);
      await Future<void>.delayed(Duration.zero);
      // The open screen still hears about the call.
      expect(seen, hasLength(1));
      expect(await log.recent(), isEmpty);
      await sub.cancel();

      // And once the obstacle is gone the log works and the error clears.
      await File(bridgeDir.path).delete();
      expect(await recordOne(log), isTrue);
      expect(log.lastWriteError, isNull);
    },
  );

  test(
    'writeErrors reports each change, and an entry arrives after its status',
    () async {
      await File(bridgeDir.path).writeAsString('in the way');
      final log = makeLog();
      final events = <String>[];
      final errors = log.writeErrors.listen(
        (e) => events.add(e == null ? 'ok' : 'error'),
      );
      final sub = log.entries.listen((_) {
        events.add('entry:${log.lastWriteError == null ? 'ok' : 'error'}');
      });
      await recordOne(log);
      await recordOne(log);
      await File(bridgeDir.path).delete();
      await recordOne(log);
      await Future<void>.delayed(Duration.zero);
      // The second failure is not a change, so it is not repeated; each
      // entry is seen with the status of its own write.
      expect(events, [
        'error',
        'entry:error',
        'entry:error',
        'ok',
        'entry:ok',
      ]);
      await errors.cancel();
      await sub.cancel();
    },
  );

  test('a failed clear is reported on writeErrors', () async {
    final log = makeLog();
    expect(await recordOne(log), isTrue);
    final error = log.writeErrors.first;
    // A directory that cannot be changed: the delete fails.
    await Process.run('chmod', ['555', bridgeDir.path]);
    try {
      final probe = File('${bridgeDir.path}/probe');
      try {
        await probe.create();
        await probe.delete();
        // Running as a user the mode does not bind (root): nothing to test.
        return;
      } on FileSystemException {
        // Read-only, as intended.
      }
      expect(await log.clear(), isFalse);
      expect(await error, contains('Could not clear'));
      expect(log.lastWriteError, isNotNull);
    } finally {
      await Process.run('chmod', ['755', bridgeDir.path]);
    }
  }, skip: Platform.isWindows);

  test('a scrubber that throws does not reach the caller', () async {
    final log = makeLog(scrub: (_) => throw StateError('boom'));
    expect(await recordOne(log), isFalse);
    expect(log.lastWriteError, contains('boom'));
  });

  test('arguments that are not JSON are still recorded', () async {
    final log = makeLog();
    expect(await recordOne(log, args: {'when': DateTime.utc(2026)}), isTrue);
    expect((await log.recent()).single.args, contains('2026'));
  });

  test('entries stream emits each recorded entry', () async {
    final log = makeLog();
    final next = log.entries.first;
    await recordOne(log, tool: 'streamed');
    expect((await next).tool, 'streamed');
    await log.dispose();
    // After dispose, recording still works and does not throw.
    expect(await recordOne(log), isTrue);
  });

  test('concurrent records all land, each on its own line', () async {
    final log = makeLog(rotateBytes: 1 << 20);
    await Future.wait([
      for (var i = 0; i < 50; i++) recordOne(log, tool: 't$i'),
    ]);
    final lines = await logFile.readAsLines();
    expect(lines, hasLength(50));
    for (final line in lines) {
      expect(BridgeAuditEntry.tryParse(line), isNotNull);
    }
  });

  test('clear removes both files', () async {
    final log = makeLog(rotateBytes: 400);
    for (var i = 0; i < 10; i++) {
      await recordOne(log);
    }
    expect(await File('${logFile.path}.1').exists(), isTrue);
    expect(await log.clear(), isTrue);
    expect(await logFile.exists(), isFalse);
    expect(await File('${logFile.path}.1').exists(), isFalse);
    expect(await log.recent(), isEmpty);
    expect(await recordOne(log), isTrue);
    expect(await log.recent(), hasLength(1));
  });

  test('recent with no file yet is empty', () async {
    expect(await makeLog().recent(), isEmpty);
  });

  test('a negative duration is stored as zero', () async {
    final log = makeLog();
    await log.record(
      client: 'c',
      host: 'h',
      tool: 't',
      args: const {},
      outcome: BridgeAuditOutcome.ok,
      ms: -5,
    );
    expect((await log.recent()).single.ms, 0);
  });

  test('the entry round-trips through toJson and tryParse', () {
    final entry = BridgeAuditEntry(
      ts: DateTime.utc(2026, 1, 2, 3, 4, 5),
      client: 'c',
      host: 'h',
      tool: 't',
      args: '{}',
      outcome: BridgeAuditOutcome.refused,
      detail: 'host_not_available',
      ms: 7,
    );
    final back = BridgeAuditEntry.tryParse(jsonEncode(entry.toJson()))!;
    expect(back.toJson(), entry.toJson());
  });

  test(
    'the log and its rotated copy are owner-only on POSIX',
    () async {
      final log = makeLog(rotateBytes: 300);
      await recordOne(log);
      expect(logFile.statSync().mode & 0x1ff, 0x180); // 0600

      // Rotate, with the old file as loose as an older version left it.
      await Process.run('chmod', ['644', logFile.path]);
      for (var i = 0; i < 5; i++) {
        await recordOne(log);
      }
      final rotated = File('${logFile.path}.1');
      expect(rotated.existsSync(), isTrue);
      expect(rotated.statSync().mode & 0x1ff, 0x180);
      expect(logFile.statSync().mode & 0x1ff, 0x180);
    },
    skip: Platform.isWindows,
  );
}
