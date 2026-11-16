import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/bridge/bridge_control_protocol.dart';
import 'package:secure_shell_go/services/visible_text.dart';

void main() {
  final received = DateTime.utc(2026, 11, 17, 12);

  ControlApproval sampleApproval() => ControlApproval(
    id: 'approval-1-1',
    assistant: 'Desk assistant',
    host: 'web',
    tool: 'run_command',
    kind: ControlApprovalKind.command,
    remaining: const Duration(seconds: 90),
    timedAllowed: true,
    command: ControlCommand(
      hosts: ['web'],
      command: ControlVisibleText.render('echo hi\nrm x\u202e'),
    ),
  );

  group('events round-trip', () {
    test('snapshot', () {
      final snapshot = ControlSnapshot(
        state: const ControlState(
          locked: false,
          timedMinutes: 15,
          controller: 'Pixel',
        ),
        grants: [
          ControlGrant(
            id: 'g1',
            assistant: 'Desk assistant',
            host: 'web',
            remaining: const Duration(minutes: 3),
          ),
        ],
        items: [
          ControlItem(
            kind: ControlItemKind.terminal,
            id: 't1',
            assistant: 'Desk assistant',
            host: 'web',
            state: 'driving',
            startedAt: DateTime.utc(2026, 11, 17, 11),
          ),
        ],
        activity: [
          ControlActivity(
            ts: DateTime.utc(2026, 11, 17, 11, 30),
            assistant: 'Desk assistant',
            host: 'web',
            tool: 'run_command',
            outcome: 'ok',
            approval: 'once',
            detail: '',
            args: '{"command":"ls"}',
            via: 'controller:Pixel',
          ),
        ],
      );
      final back =
          ControlEvent.decode(snapshot.encode(), now: received)
              as ControlSnapshot;
      expect(back.state.timedMinutes, 15);
      expect(back.state.controller, 'Pixel');
      expect(back.grants.single.id, 'g1');
      expect(back.grants.single.expiresAt, received.add(const Duration(minutes: 3)));
      expect(back.items.single.kind, ControlItemKind.terminal);
      expect(back.items.single.startedAt, DateTime.utc(2026, 11, 17, 11));
      expect(back.activity.single.via, 'controller:Pixel');
      expect(back.activity.single.args, '{"command":"ls"}');
    });

    test('approval with a command keeps the card rendering', () {
      final event = ControlApprovalAdded(sampleApproval());
      final back =
          ControlEvent.decode(event.encode(), now: received)
              as ControlApprovalAdded;
      final a = back.approval;
      expect(a.kind, ControlApprovalKind.command);
      expect(a.expiresAt, received.add(const Duration(seconds: 90)));
      expect(a.timedAllowed, true);
      final rendered = visibleText('echo hi\nrm x\u202e');
      expect(a.command!.command.text, rendered.text);
      expect(a.command!.command.kinds, rendered.kinds);
      expect(
        a.command!.command.spans.where((s) => s.escape).map((s) => s.text),
        contains('[U+202E]'),
      );
    });

    test('file write, service and job cards', () {
      final file = ControlApproval(
        id: 'a2',
        assistant: 'A',
        host: 'web',
        tool: 'write_file',
        kind: ControlApprovalKind.fileWrite,
        remaining: const Duration(seconds: 5),
        timedAllowed: false,
        file: ControlFileWrite(
          path: ControlVisibleText.render('/etc/x\tconf', breakLines: false),
          bytes: 2048,
          replacesExisting: true,
          previewKind: ControlPreviewKind.partialDiff,
          preview: ControlVisibleText.render('-a\n+b'),
        ),
      );
      final f =
          (ControlEvent.decode(ControlApprovalAdded(file).encode())
                  as ControlApprovalAdded)
              .approval
              .file!;
      expect(f.bytes, 2048);
      expect(f.replacesExisting, true);
      expect(f.previewIsPartial, true);
      expect(f.path.text, r'/etc/x\tconf');
      expect(f.preview.text, visibleText('-a\n+b').text);

      final service = ControlApproval(
        id: 'a3',
        assistant: 'A',
        host: 'web',
        tool: 'service_action',
        kind: ControlApprovalKind.service,
        remaining: Duration.zero,
        timedAllowed: true,
        service: const ControlService(unit: 'nginx.service', action: 'restart'),
      );
      final s =
          (ControlEvent.decode(ControlApprovalAdded(service).encode())
                  as ControlApprovalAdded)
              .approval
              .service!;
      expect(s.unit, 'nginx.service');
      expect(s.action, 'restart');

      final job = ControlApproval(
        id: 'a4',
        assistant: 'A',
        host: 'web',
        tool: 'start_job',
        kind: ControlApprovalKind.jobStart,
        remaining: Duration.zero,
        timedAllowed: true,
        job: ControlJobStart(
          command: ControlVisibleText.render('npm run dev'),
          name: 'dev',
        ),
      );
      final j =
          (ControlEvent.decode(ControlApprovalAdded(job).encode())
                  as ControlApprovalAdded)
              .approval;
      expect(j.kind, ControlApprovalKind.jobStart);
      expect(j.job!.command.text, 'npm run dev');
      expect(j.job!.cwd, isNull);
      expect(j.job!.name, 'dev');
    });

    test('removed, synced, state, grants, items, activity, result, error', () {
      final events = <ControlEvent>[
        const ControlApprovalRemoved('a1', ControlApprovalEnd.timedOut),
        const ControlSynced(),
        const ControlStateChanged(
          ControlState(locked: true, timedMinutes: 0, controller: 'P'),
        ),
        ControlGrantsChanged(const []),
        ControlItemsChanged(const []),
        const ControlResult(
          re: 'r1',
          ok: false,
          code: ControlErrorCode.notFound,
          message: 'gone',
        ),
        const ControlResult(re: 'r2', ok: true, outcome: 'allowedOnce'),
        const ControlError(ControlErrorCode.tooManySessions, 'two already'),
      ];
      final back = [for (final e in events) ControlEvent.decode(e.encode())];
      expect((back[0] as ControlApprovalRemoved).end, ControlApprovalEnd.timedOut);
      expect(back[1], isA<ControlSynced>());
      expect((back[2] as ControlStateChanged).state.locked, true);
      expect((back[3] as ControlGrantsChanged).grants, isEmpty);
      expect((back[4] as ControlItemsChanged).items, isEmpty);
      final failed = back[5] as ControlResult;
      expect(failed.ok, false);
      expect(failed.code, ControlErrorCode.notFound);
      expect((back[6] as ControlResult).outcome, 'allowedOnce');
      expect((back[7] as ControlError).code, ControlErrorCode.tooManySessions);
    });

    test('a snapshot of another protocol version is refused by name', () {
      final line = jsonEncode({
        'type': 'snapshot',
        'v': 99,
        'state': {'locked': false, 'timedMinutes': 0, 'controller': 'P'},
      });
      expect(
        () => ControlEvent.decode(line),
        throwsA(
          isA<ControlProtocolException>().having(
            (e) => e.message,
            'message',
            contains('Update both'),
          ),
        ),
      );
    });

    test('unknown event types and junk are protocol errors', () {
      expect(
        () => ControlEvent.decode('{"type":"surprise"}'),
        throwsA(
          isA<ControlProtocolException>().having(
            (e) => e.code,
            'code',
            ControlErrorCode.unknownType,
          ),
        ),
      );
      expect(
        () => ControlEvent.decode('Welcome to Ubuntu'),
        throwsA(isA<ControlProtocolException>()),
      );
      expect(
        () => ControlEvent.decode('{"type":"approval","approval":{"id":3}}'),
        throwsA(
          isA<ControlProtocolException>().having(
            (e) => e.code,
            'code',
            ControlErrorCode.malformed,
          ),
        ),
      );
    });
  });

  group('the phone never draws a hidden character', () {
    test('a plain span holding control or bidi characters is re-rendered', () {
      final line = jsonEncode({
        'spans': [
          {'t': 'ok \u202e evil \x1b[2J'},
          {'t': '\u200b', 'e': true},
        ],
        'kinds': <String>[],
      });
      final v = ControlVisibleText.fromJson(jsonDecode(line));
      for (final s in v.spans) {
        expect(visibleText(s.text, breakLines: false).hasSurprises, false);
      }
      expect(v.text, contains('[U+202E]'));
      expect(v.text, contains(r'\x1b'));
      expect(v.text, contains('[U+200B]'));
      expect(v.kinds, containsAll([VisibleKind.bidi, VisibleKind.control]));
    });

    test('names are made one safe line on arrival', () {
      final approval = sampleApproval().toJson()
        ..['assistant'] = 'Bad\u202eName\nline'
        ..['host'] = 'web\r';
      final a = ControlApproval.fromJson(approval);
      expect(a.assistant, isNot(contains('\u202e')));
      expect(a.assistant, isNot(contains('\n')));
      expect(a.host, r'web\r');
    });

    test('rendering safe text twice changes nothing', () {
      final once = ControlVisibleText.render('a\tb\u202ec\nd');
      final twice = ControlVisibleText.fromJson(
        jsonDecode(jsonEncode(once.toJson())),
      );
      expect(twice.text, once.text);
      expect(twice.kinds, once.kinds);
      expect([for (final s in twice.spans) s.escape], [
        for (final s in once.spans) s.escape,
      ]);
    });
  });

  group('requests', () {
    test('round-trip', () {
      final requests = <ControlRequest>[
        const ControlAnswerRequest('r1', approvalId: 'a1', answer: ControlAnswer.deny),
        const ControlAnswerRequest(
          'r2',
          approvalId: 'a1',
          answer: ControlAnswer.forMinutes,
          minutes: 15,
        ),
        const ControlStopGrantRequest('r3', grantId: 'g1'),
        const ControlStopItemRequest('r4', kind: ControlItemKind.job, itemId: 'j1'),
        const ControlPingRequest('r5'),
      ];
      final back = [for (final r in requests) ControlRequest.decode(r.encode())];
      expect((back[0] as ControlAnswerRequest).answer, ControlAnswer.deny);
      final timed = back[1] as ControlAnswerRequest;
      expect(timed.answer, ControlAnswer.forMinutes);
      expect(timed.minutes, 15);
      expect((back[2] as ControlStopGrantRequest).grantId, 'g1');
      final stop = back[3] as ControlStopItemRequest;
      expect(stop.kind, ControlItemKind.job);
      expect(stop.itemId, 'j1');
      expect(back[4], isA<ControlPingRequest>());
      expect([for (final r in back) r.re], ['r1', 'r2', 'r3', 'r4', 'r5']);
    });

    test('malformed requests say why, with the re when there is one', () {
      ControlProtocolException rejection(String line) {
        try {
          ControlRequest.decode(line);
        } on ControlProtocolException catch (e) {
          return e;
        }
        fail('accepted: $line');
      }

      expect(rejection('nope').code, ControlErrorCode.malformed);
      expect(rejection('[1]').code, ControlErrorCode.malformed);
      expect(rejection('{"type":"ping"}').re, isNull);
      final noMinutes = rejection(
        '{"type":"answer","re":"r1","approval":"a","answer":"for_minutes"}',
      );
      expect(noMinutes.code, ControlErrorCode.malformed);
      expect(noMinutes.re, 'r1');
      final badAnswer = rejection(
        '{"type":"answer","re":"r2","approval":"a","answer":"always"}',
      );
      expect(badAnswer.re, 'r2');
      final unknown = rejection('{"type":"pair","re":"r3"}');
      expect(unknown.code, ControlErrorCode.unknownType);
      expect(unknown.re, 'r3');
      expect(
        rejection('{"type":"stop_item","re":"r4","kind":"host","id":"x"}').code,
        ControlErrorCode.malformed,
      );
      expect(
        rejection(
          '{"type":"stop_grant","re":"r5","grant":"${'x' * 300}"}',
        ).code,
        ControlErrorCode.malformed,
      );
    });
  });
}
