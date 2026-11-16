import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/bridge/bridge_approvals.dart';
import 'package:secure_shell_go/services/bridge/bridge_client_store.dart';
import 'package:secure_shell_go/widgets/bridge_approval_card.dart';
import 'package:secure_shell_go/widgets/bridge_approval_host.dart';

import 'support/bridge_fake_time.dart';

void main() {
  late FakeTime time;
  late BridgeApprovals approvals;
  late BridgeApprovalHost host;
  late GlobalKey<NavigatorState> navigator;
  late StreamController<bool> lockChanges;
  var locked = false;
  var timedMinutes = 0;
  final outcomes = <String, BridgeApprovalOutcome>{};

  BridgeClient client([String name = 'Desktop assistant']) => BridgeClient(
    id: 'c-$name',
    name: name,
    tokenHash: 'h',
    createdAt: DateTime.utc(2026, 1, 1),
  );

  /// Puts a request in front of the user and records how it ends.
  BridgeApprovalRequest ask(
    BridgeChangeSummary summary, {
    String hostName = 'web-1',
    String? name,
    String tool = 'run_command',
  }) {
    final r = approvals.request(
      client: client(name ?? 'Desktop assistant'),
      hostId: 'h-$hostName',
      hostName: hostName,
      tool: tool,
      summary: summary,
    );
    unawaited(approvals.ask(r).then((o) => outcomes[r.id] = o));
    return r;
  }

  /// One pump runs the stream's microtask (which raises the card); the next
  /// builds it.
  Future<void> pump2(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
  }

  Future<void> advance(WidgetTester tester, Duration d) async {
    time.advance(d);
    await tester.pump(d);
  }

  Future<void> pumpApp(
    WidgetTester tester, {
    Size size = const Size(800, 900),
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: const Scaffold(body: Text('home screen')),
      ),
    );
    host.start();
    await pump2(tester);
  }

  setUp(() {
    time = FakeTime();
    approvals = BridgeApprovals(
      timedApprovalMinutes: () => timedMinutes,
      clock: time.clock,
      timer: time.timer,
    );
    navigator = GlobalKey<NavigatorState>();
    lockChanges = StreamController<bool>.broadcast();
    locked = false;
    timedMinutes = 0;
    outcomes.clear();
    host = BridgeApprovalHost(
      navigatorKey: navigator,
      approvals: approvals,
      isLocked: () => locked,
      lockChanges: lockChanges.stream,
      timedMinutes: () => timedMinutes,
      clock: time.clock,
    );
  });

  tearDown(() async {
    await host.dispose();
    await approvals.dispose();
    await lockChanges.close();
  });

  Finder button(String key) => find.byKey(ValueKey(key));

  bool enabled(WidgetTester tester, String key) =>
      tester.widget<ButtonStyleButton>(button(key)).onPressed != null;

  CommandSummary command(String text, [List<String> hosts = const ['web-1']]) =>
      CommandSummary(command: text, hostNames: hosts);

  group('a command', () {
    testWidgets('names the assistant and host, and shows the command', (
      tester,
    ) async {
      await pumpApp(tester);
      ask(command('systemctl restart nginx'));
      await pump2(tester);
      expect(find.text('Run this command?'), findsOneWidget);
      expect(find.text('Asked by Desktop assistant'), findsOneWidget);
      expect(find.text('On web-1'), findsOneWidget);
      expect(find.textContaining('systemctl restart nginx'), findsOneWidget);
      expect(find.text('Deny'), findsOneWidget);
      expect(find.text('Allow once'), findsOneWidget);
    });

    testWidgets('appears over whatever screen is in front', (tester) async {
      await pumpApp(tester);
      unawaited(
        navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('settings screen')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      ask(command('uptime'));
      await pump2(tester);
      expect(find.text('Run this command?'), findsOneWidget);
      expect(find.text('settings screen'), findsOneWidget);
    });

    testWidgets('lists every host of a command for several, one per line', (
      tester,
    ) async {
      await pumpApp(tester);
      ask(
        command('uptime', ['web-1', 'web-2', 'db']),
        hostName: 'web-1, web-2, db',
      );
      await pump2(tester);
      expect(find.text('Run this command on 3 servers?'), findsOneWidget);
      expect(find.text('On these servers:'), findsOneWidget);
      expect(find.text('• web-1'), findsOneWidget);
      expect(find.text('• web-2'), findsOneWidget);
      expect(find.text('• db'), findsOneWidget);
    });

    testWidgets('shows control characters as visible escapes with a legend', (
      tester,
    ) async {
      await pumpApp(tester);
      ask(command('echo a\n\tb\u001b[0m\u202Ec\u200Bd\u00A0e'));
      await pump2(tester);
      final box = tester.widget<Container>(button('approval-command'));
      expect(box, isNotNull);
      final text = tester
          .widget<SelectableText>(
            find.descendant(
              of: button('approval-command'),
              matching: find.byType(SelectableText),
            ),
          )
          .textSpan!
          .toPlainText();
      expect(text, contains(r'\n'));
      expect(text, contains(r'\t'));
      expect(text, contains(r'\x1b'));
      expect(text, contains('[U+202E]'));
      expect(text, contains('[U+200B]'));
      expect(text, contains('[U+00A0]'));
      expect(text.contains('\u202E'), isFalse);
      expect(text.contains('\u001b'), isFalse);
      expect(button('approval-legend'), findsOneWidget);
      expect(
        find.textContaining('changes the reading direction'),
        findsOneWidget,
      );
    });

    testWidgets('plain commands carry no legend', (tester) async {
      await pumpApp(tester);
      ask(command('ls -la'));
      await pump2(tester);
      expect(button('approval-legend'), findsNothing);
    });

    testWidgets('hostile strings: override, 4096 characters, a control name', (
      tester,
    ) async {
      await pumpApp(tester, size: const Size(320, 568), textScale: 1.5);
      final long = '${'ab\u202E ' * 1000}${'x' * 96}';
      expect(long.length, 4096);
      ask(command(long), name: 'Evil\u202E\u001b[31m assistant ${'N' * 300}');
      await pump2(tester);
      expect(tester.takeException(), isNull);
      final asked = tester.widget<Text>(button('approval-assistant')).data!;
      expect(asked.contains('\u202E'), isFalse);
      expect(asked.contains('\u001b'), isFalse);
      expect(asked, contains('[U+202E]'));
      expect(asked, contains(r'\x1b'));
      expect(asked.length, lessThan(160), reason: 'the name is cut');
      // The buttons stay on screen however long the command is.
      expect(tester.getRect(button('approval-deny')).bottom, lessThan(568));
    });
  });

  group('the Allow buttons', () {
    testWidgets('are disabled for the first second, Deny never is', (
      tester,
    ) async {
      await pumpApp(tester);
      ask(command('uptime'));
      await pump2(tester);
      expect(enabled(tester, 'approval-allow-once'), isFalse);
      expect(enabled(tester, 'approval-deny'), isTrue);
      await advance(tester, const Duration(milliseconds: 900));
      expect(enabled(tester, 'approval-allow-once'), isFalse);
      await advance(tester, const Duration(milliseconds: 200));
      expect(enabled(tester, 'approval-allow-once'), isTrue);
    });

    testWidgets('a tap during the first second approves nothing', (
      tester,
    ) async {
      await pumpApp(tester);
      final r = ask(command('uptime'));
      await pump2(tester);
      await tester.tap(button('approval-allow-once'), warnIfMissed: false);
      await pump2(tester);
      expect(outcomes[r.id], isNull);
      expect(approvals.current, hasLength(1));
    });

    testWidgets('are disabled again for a second when the request changes', (
      tester,
    ) async {
      await pumpApp(tester);
      final first = ask(command('uptime'));
      ask(command('df -h'));
      await pump2(tester);
      await advance(tester, const Duration(seconds: 2));
      expect(enabled(tester, 'approval-allow-once'), isTrue);
      approvals.answer(first.id, BridgeApprovalAnswer.deny);
      await pump2(tester);
      expect(find.textContaining('df -h'), findsOneWidget);
      expect(enabled(tester, 'approval-allow-once'), isFalse);
      await advance(tester, const Duration(seconds: 1, milliseconds: 100));
      expect(enabled(tester, 'approval-allow-once'), isTrue);
    });

    testWidgets('Allow once allows once', (tester) async {
      await pumpApp(tester);
      final r = ask(command('uptime'));
      await pump2(tester);
      await advance(tester, const Duration(seconds: 2));
      await tester.tap(button('approval-allow-once'));
      await pump2(tester);
      expect(outcomes[r.id], BridgeApprovalOutcome.allowedOnce);
      await tester.pumpAndSettle();
      expect(find.text('Run this command?'), findsNothing);
    });

    testWidgets('a second tap does nothing', (tester) async {
      await pumpApp(tester);
      final r = ask(command('uptime'));
      ask(command('df -h'));
      await pump2(tester);
      await advance(tester, const Duration(seconds: 2));
      await tester.tap(button('approval-allow-once'));
      await tester.tap(button('approval-allow-once'), warnIfMissed: false);
      await pump2(tester);
      expect(outcomes[r.id], BridgeApprovalOutcome.allowedOnce);
      expect(outcomes.length, 1, reason: 'the next request is untouched');
    });
  });

  group('keys and the back gesture', () {
    testWidgets('Deny has the focus: Enter denies', (tester) async {
      await pumpApp(tester);
      final r = ask(command('uptime'));
      await pump2(tester);
      await advance(tester, const Duration(seconds: 2));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await pump2(tester);
      expect(outcomes[r.id], BridgeApprovalOutcome.denied);
    });

    testWidgets('Space denies, never allows', (tester) async {
      await pumpApp(tester);
      final r = ask(command('uptime'));
      await pump2(tester);
      await advance(tester, const Duration(seconds: 2));
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await pump2(tester);
      expect(outcomes[r.id], BridgeApprovalOutcome.denied);
    });

    testWidgets('Enter during the first second denies too', (tester) async {
      await pumpApp(tester);
      final r = ask(command('uptime'));
      await pump2(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await pump2(tester);
      expect(outcomes[r.id], BridgeApprovalOutcome.denied);
    });

    testWidgets('Escape denies', (tester) async {
      await pumpApp(tester);
      final r = ask(command('uptime'));
      await pump2(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await pump2(tester);
      expect(outcomes[r.id], BridgeApprovalOutcome.denied);
    });

    testWidgets('the system back gesture denies', (tester) async {
      await pumpApp(tester);
      final r = ask(command('uptime'));
      await pump2(tester);
      await tester.binding.handlePopRoute();
      await pump2(tester);
      expect(outcomes[r.id], BridgeApprovalOutcome.denied);
    });

    testWidgets('a tap outside the card does nothing', (tester) async {
      await pumpApp(tester);
      final r = ask(command('uptime'));
      await pump2(tester);
      await tester.tapAt(const Offset(2, 2));
      await pump2(tester);
      expect(outcomes[r.id], isNull);
      expect(find.text('Run this command?'), findsOneWidget);
    });
  });

  group('the timed button', () {
    testWidgets('is absent while the setting is off', (tester) async {
      await pumpApp(tester);
      ask(command('uptime'));
      await pump2(tester);
      expect(button('approval-allow-for-a-while'), findsNothing);
      expect(button('approval-timed-note'), findsNothing);
    });

    testWidgets('is offered with a line saying what it grants', (tester) async {
      timedMinutes = 15;
      await pumpApp(tester);
      final r = ask(command('uptime'));
      await pump2(tester);
      expect(find.text('Allow for 15 minutes'), findsOneWidget);
      expect(
        tester.widget<Text>(button('approval-timed-note')).data,
        contains('any change this assistant asks for on web-1'),
      );
      expect(enabled(tester, 'approval-allow-for-a-while'), isFalse);
      await advance(tester, const Duration(seconds: 2));
      await tester.tap(button('approval-allow-for-a-while'));
      await pump2(tester);
      expect(
        outcomes[r.id],
        const BridgeApprovalOutcome.allowedForAWhile(Duration(minutes: 15)),
      );
    });

    testWidgets('names every host when the command runs on several', (
      tester,
    ) async {
      timedMinutes = 5;
      await pumpApp(tester);
      ask(command('uptime', ['a', 'b']), hostName: 'a, b');
      await pump2(tester);
      expect(
        tester.widget<Text>(button('approval-timed-note')).data,
        contains('each of the servers listed above'),
      );
    });

    testWidgets('a terminal never offers it', (tester) async {
      timedMinutes = 60;
      await pumpApp(tester);
      ask(const TerminalSummary(), tool: 'open_terminal');
      await pump2(tester);
      expect(button('approval-allow-for-a-while'), findsNothing);
      expect(button('approval-timed-note'), findsNothing);
      expect(find.text('Allow once'), findsOneWidget);
    });
  });

  group('the other kinds', () {
    testWidgets('a new file', (tester) async {
      await pumpApp(tester);
      ask(
        const FileWriteSummary(
          path: '/etc/app/new.conf',
          bytes: 12,
          replacesExisting: false,
          preview: 'listen=80\n',
          previewKind: FileWritePreviewKind.fullContent,
        ),
        tool: 'write_file',
      );
      await pump2(tester);
      expect(find.text('Create this file?'), findsOneWidget);
      expect(find.textContaining('/etc/app/new.conf'), findsOneWidget);
      expect(find.text('Size: 12 bytes'), findsOneWidget);
      expect(find.text('This creates a new file.'), findsOneWidget);
      expect(find.text('What will be written:'), findsOneWidget);
      expect(button('approval-partial-warning'), findsNothing);
      final text = tester
          .widget<SelectableText>(
            find.descendant(
              of: button('approval-preview'),
              matching: find.byType(SelectableText),
            ),
          )
          .textSpan!
          .toPlainText();
      expect(text, contains('listen=80'));
    });

    testWidgets('a replacement shows size in KiB and a diff', (tester) async {
      await pumpApp(tester);
      ask(
        const FileWriteSummary(
          path: '/etc/app/app.conf',
          bytes: 20480,
          replacesExisting: true,
          preview: '-a=1\n+a=2\n',
          previewKind: FileWritePreviewKind.fullDiff,
        ),
        tool: 'write_file',
      );
      await pump2(tester);
      expect(find.text('Replace this file?'), findsOneWidget);
      expect(find.text('Size: 20480 bytes (20 KiB)'), findsOneWidget);
      expect(
        find.text('This replaces a file that already exists.'),
        findsOneWidget,
      );
      expect(find.text('Changes to the existing file:'), findsOneWidget);
      expect(button('approval-partial-warning'), findsNothing);
    });

    for (final entry in {
      FileWritePreviewKind.partialContent: 'This is not the whole file',
      FileWritePreviewKind.partialDiff: 'This is not every change',
      FileWritePreviewKind.noPreview: 'No preview available',
    }.entries) {
      testWidgets('a ${entry.key.name} preview warns: ${entry.value}', (
        tester,
      ) async {
        await pumpApp(tester);
        ask(
          FileWriteSummary(
            path: '/srv/big.txt',
            bytes: 300000,
            replacesExisting: true,
            preview: 'first lines…',
            previewKind: entry.key,
          ),
          tool: 'write_file',
        );
        await pump2(tester);
        expect(button('approval-partial-warning'), findsOneWidget);
        expect(find.text(entry.value), findsOneWidget);
      });
    }

    testWidgets('a hostile path and preview are shown visibly', (tester) async {
      await pumpApp(tester);
      ask(
        const FileWriteSummary(
          path: '/tmp/a\u202Etxt.sh',
          bytes: 5,
          replacesExisting: false,
          preview: 'x\u001b[2J\n',
          previewKind: FileWritePreviewKind.fullContent,
        ),
        tool: 'write_file',
      );
      await pump2(tester);
      expect(find.textContaining('[U+202E]'), findsWidgets);
      expect(button('approval-legend'), findsNWidgets(2));
    });

    testWidgets('a service action in plain words', (tester) async {
      await pumpApp(tester);
      ask(
        const ServiceActionSummary(unit: 'nginx.service', action: 'restart'),
        tool: 'service_action',
      );
      await pump2(tester);
      expect(find.text('Change a service?'), findsOneWidget);
      expect(find.text('Restart the service nginx.service.'), findsOneWidget);
    });

    testWidgets('a terminal has the strong warning, in full', (tester) async {
      await pumpApp(tester);
      ask(const TerminalSummary(), tool: 'open_terminal');
      await pump2(tester);
      expect(find.text('Open a terminal for the assistant?'), findsOneWidget);
      expect(button('approval-terminal-warning'), findsOneWidget);
      final warning = tester
          .widget<Text>(button('approval-terminal-text'))
          .data!;
      for (final part in [
        'live shell as the saved sign-in user on this host',
        'any command, including ones you never see on a card',
        'with no further questions',
        'The blocked-path list does not apply inside a terminal',
        'watch it, take over by typing, or stop it at any time',
      ]) {
        expect(warning, contains(part));
      }
    });
  });

  group('the queue', () {
    testWidgets('shows how many wait, oldest first', (tester) async {
      await pumpApp(tester);
      final first = ask(command('first-cmd'));
      ask(command('second-cmd'));
      ask(command('third-cmd'));
      await pump2(tester);
      expect(find.textContaining('first-cmd'), findsOneWidget);
      expect(find.textContaining('second-cmd'), findsNothing);
      expect(find.text('2 more waiting'), findsOneWidget);
      approvals.answer(first.id, BridgeApprovalAnswer.deny);
      await pump2(tester);
      expect(find.textContaining('second-cmd'), findsOneWidget);
      expect(find.text('1 more waiting'), findsOneWidget);
    });

    testWidgets('one card at a time: a single request shows no count', (
      tester,
    ) async {
      await pumpApp(tester);
      ask(command('uptime'));
      await pump2(tester);
      expect(button('approval-waiting'), findsNothing);
      expect(find.byType(BridgeApprovalCard), findsOneWidget);
    });

    testWidgets('the card goes when its request is withdrawn', (tester) async {
      await pumpApp(tester);
      final r = ask(command('uptime'));
      await pump2(tester);
      approvals.withdraw(r.id);
      await tester.pumpAndSettle();
      expect(find.byType(BridgeApprovalCard), findsNothing);
      expect(outcomes[r.id], BridgeApprovalOutcome.withdrawn);
    });

    testWidgets('the card goes when time runs out', (tester) async {
      await pumpApp(tester);
      final r = ask(command('uptime'));
      await pump2(tester);
      expect(
        find.textContaining('Denied automatically in 2:00'),
        findsOneWidget,
      );
      await advance(tester, const Duration(seconds: 61));
      expect(
        find.textContaining('Denied automatically in 0:59'),
        findsOneWidget,
      );
      await advance(tester, const Duration(seconds: 60));
      await tester.pumpAndSettle();
      expect(find.byType(BridgeApprovalCard), findsNothing);
      expect(outcomes[r.id], BridgeApprovalOutcome.timedOut);
    });
  });

  group('the app lock', () {
    testWidgets('no card while locked', (tester) async {
      locked = true;
      await pumpApp(tester);
      ask(command('uptime'));
      await pump2(tester);
      expect(find.byType(BridgeApprovalCard), findsNothing);
      expect(host.isShowing, isFalse);
    });

    testWidgets('locking removes a card that is up, and its keys with it', (
      tester,
    ) async {
      await pumpApp(tester);
      final r = ask(command('uptime'));
      await pump2(tester);
      expect(find.byType(BridgeApprovalCard), findsOneWidget);
      locked = true;
      lockChanges.add(true);
      await tester.pumpAndSettle();
      expect(find.byType(BridgeApprovalCard), findsNothing);
      // A key press now reaches nothing.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await pump2(tester);
      expect(
        outcomes[r.id],
        isNull,
        reason: 'withdrawing is the service\'s job; the card cannot answer',
      );
    });

    testWidgets('a request still waiting is shown again after unlocking', (
      tester,
    ) async {
      locked = true;
      await pumpApp(tester);
      ask(command('uptime'));
      await pump2(tester);
      locked = false;
      lockChanges.add(false);
      await pump2(tester);
      expect(find.byType(BridgeApprovalCard), findsOneWidget);
    });
  });

  group('layout', () {
    final kinds = <String, BridgeChangeSummary>{
      'command': command('echo ${'long ' * 200}\n${'x' * 300}'),
      'many hosts': command('uptime', List.generate(10, (i) => 'server-$i')),
      'file': FileWriteSummary(
        path: '/very/long/path/${'dir/' * 30}file.conf',
        bytes: 2000000,
        replacesExisting: true,
        preview: '-old\n+new\n',
        previewKind: FileWritePreviewKind.partialDiff,
      ),
      'service': const ServiceActionSummary(
        unit: 'nginx.service',
        action: 'stop',
      ),
      'terminal': const TerminalSummary(),
    };
    for (final size in [const Size(320, 568), const Size(1400, 900)]) {
      for (final entry in kinds.entries) {
        testWidgets('${entry.key} fits ${size.width.toInt()}x'
            '${size.height.toInt()}', (tester) async {
          timedMinutes = 15;
          await pumpApp(tester, size: size, textScale: 1.5);
          ask(
            entry.value,
            hostName: entry.key == 'many hosts'
                ? 'server-0, server-1'
                : 'web-1',
            tool: entry.key == 'terminal' ? 'open_terminal' : 'run_command',
          );
          await pump2(tester);
          expect(tester.takeException(), isNull);
          expect(find.byType(BridgeApprovalCard), findsOneWidget);
          final deny = tester.getRect(button('approval-deny'));
          expect(deny.bottom, lessThanOrEqualTo(size.height));
          expect(deny.left, greaterThanOrEqualTo(0));
        });
      }
    }
  });

  group('attempts to approve without a deliberate act', () {
    testWidgets('a press that started before the card armed does not allow '
        'when released after', (tester) async {
      await pumpApp(tester);
      final r = ask(command('uptime'));
      await pump2(tester);
      final gesture = await tester.startGesture(
        tester.getCenter(button('approval-allow-once')),
      );
      await advance(tester, const Duration(seconds: 2));
      expect(enabled(tester, 'approval-allow-once'), isTrue);
      await gesture.up();
      await pump2(tester);
      expect(outcomes[r.id], isNull);
    });

    testWidgets('a press on an armed Allow whose request is replaced under '
        'the finger allows neither', (tester) async {
      await pumpApp(tester);
      final first = ask(command('uptime'));
      final second = ask(command('uptime'));
      await pump2(tester);
      await advance(tester, const Duration(seconds: 2));
      final gesture = await tester.startGesture(
        tester.getCenter(button('approval-allow-once')),
      );
      // Answered elsewhere (or withdrawn) while the finger is down.
      approvals.withdraw(first.id);
      await pump2(tester);
      await advance(tester, const Duration(seconds: 2));
      await gesture.up();
      await pump2(tester);
      expect(outcomes[first.id], BridgeApprovalOutcome.withdrawn);
      expect(outcomes[second.id], isNull);
      expect(approvals.current.single.id, second.id);
    });

    testWidgets('time running out while the finger is down allows nothing', (
      tester,
    ) async {
      await pumpApp(tester);
      final r = ask(command('uptime'));
      await pump2(tester);
      await advance(tester, const Duration(seconds: 119));
      final gesture = await tester.startGesture(
        tester.getCenter(button('approval-allow-once')),
      );
      await advance(tester, const Duration(seconds: 2));
      await gesture.up();
      await pump2(tester);
      expect(outcomes[r.id], BridgeApprovalOutcome.timedOut);
    });

    testWidgets('Tab then Enter during the first second allows nothing', (
      tester,
    ) async {
      await pumpApp(tester);
      final r = ask(command('uptime'));
      await pump2(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await pump2(tester);
      expect(outcomes[r.id], isNot(BridgeApprovalOutcome.allowedOnce));
    });

    testWidgets('a key held down when the card appears never allows', (
      tester,
    ) async {
      await pumpApp(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
      final r = ask(command('uptime'));
      await pump2(tester);
      for (var i = 0; i < 20; i++) {
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
        await advance(tester, const Duration(milliseconds: 100));
      }
      await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
      await pump2(tester);
      expect(outcomes[r.id], isNot(BridgeApprovalOutcome.allowedOnce));
    });

    testWidgets('after Allow once by keyboard, Enter on the next card does '
        'not allow it', (tester) async {
      await pumpApp(tester);
      final first = ask(command('uptime'));
      final second = ask(command('reboot'));
      await pump2(tester);
      await advance(tester, const Duration(seconds: 2));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await pump2(tester);
      expect(outcomes[first.id], BridgeApprovalOutcome.allowedOnce);
      expect(find.textContaining('reboot'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await pump2(tester);
      await advance(tester, const Duration(seconds: 2));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await pump2(tester);
      expect(outcomes[second.id], isNot(BridgeApprovalOutcome.allowedOnce));
    });

    testWidgets('a double tap answers at most one card with Allow', (
      tester,
    ) async {
      await pumpApp(tester);
      final first = ask(command('uptime'));
      final second = ask(command('uptime'));
      await pump2(tester);
      await advance(tester, const Duration(seconds: 2));
      final at = tester.getCenter(button('approval-allow-once'));
      await tester.tapAt(at);
      await tester.pump(const Duration(milliseconds: 80));
      await tester.pump();
      await tester.tapAt(at);
      await pump2(tester);
      expect(outcomes[first.id], BridgeApprovalOutcome.allowedOnce);
      expect(outcomes[second.id], isNull);
    });

    testWidgets('a rebuild (resize, text size) neither restarts nor shortens '
        'the wait', (tester) async {
      await pumpApp(tester);
      ask(command('uptime'));
      await pump2(tester);
      await advance(tester, const Duration(milliseconds: 600));
      tester.view.physicalSize = const Size(500, 700);
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      await tester.pump();
      expect(enabled(tester, 'approval-allow-once'), isFalse);
      await advance(tester, const Duration(milliseconds: 500));
      expect(enabled(tester, 'approval-allow-once'), isTrue);
    });

    testWidgets('a pop from code (another dialog closing itself) answers '
        'nothing and the card comes back unarmed', (tester) async {
      await pumpApp(tester);
      final r = ask(command('uptime'));
      await pump2(tester);
      await advance(tester, const Duration(seconds: 2));
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(outcomes[r.id], isNull);
      expect(find.byType(BridgeApprovalCard), findsOneWidget);
      expect(enabled(tester, 'approval-allow-once'), isFalse);
    });
  });

  group('what the boxes show', () {
    testWidgets('a combining overlay on a command is marked, with its '
        'legend line', (tester) async {
      await pumpApp(tester);
      ask(command('rm -rf /s̶r̶v̶ ok'));
      await pump2(tester);
      expect(find.textContaining('s[U+0336]r[U+0336]v[U+0336]'), findsOneWidget);
      expect(
        find.textContaining('a mark drawn over or under the character'),
        findsOneWidget,
      );
    });

    testWidgets('the command box is laid out left to right, even in a '
        'right-to-left app', (tester) async {
      await pumpApp(tester);
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          builder: (context, child) =>
              Directionality(textDirection: TextDirection.rtl, child: child!),
          home: const Scaffold(body: Text('home screen')),
        ),
      );
      ask(command('echo אב 1 2 > /tmp/x'));
      await pump2(tester);
      final box = find.byKey(const ValueKey('approval-command'));
      expect(box, findsOneWidget);
      expect(
        Directionality.of(tester.element(find.descendant(
          of: box,
          matching: find.byType(SelectableText),
        ))),
        TextDirection.ltr,
      );
    });

    testWidgets('a command longer than the box shows a scrollbar, and all of '
        'it can be scrolled to', (tester) async {
      await pumpApp(tester);
      final lines = [for (var i = 0; i < 200; i++) 'line-$i'];
      ask(command(lines.join('\n')));
      await pump2(tester);
      final scrollbar = tester.widget<Scrollbar>(
        find.descendant(
          of: find.byKey(const ValueKey('approval-command')),
          matching: find.byType(Scrollbar),
        ),
      );
      expect(scrollbar.thumbVisibility, isTrue);
      final text = tester
          .widget<SelectableText>(
            find.descendant(
              of: find.byKey(const ValueKey('approval-command')),
              matching: find.byType(SelectableText),
            ),
          )
          .textSpan!
          .toPlainText();
      expect(text, contains('line-0'));
      expect(text, contains('line-199'));
      expect(text, isNot(contains('…')));
    });
  });

  group('a partial file preview warns before anything else', () {
    for (final kind in [
      FileWritePreviewKind.partialContent,
      FileWritePreviewKind.partialDiff,
      FileWritePreviewKind.noPreview,
    ]) {
      testWidgets('${kind.name}: the warning is in view at 320x568 with '
          'large text, a long path and the timed button', (tester) async {
        timedMinutes = 15;
        await pumpApp(tester, size: const Size(320, 568), textScale: 1.5);
        ask(
          FileWriteSummary(
            path: '/srv/${'very-long-directory/' * 20}app.conf',
            bytes: 5000000,
            replacesExisting: true,
            preview: kind == FileWritePreviewKind.noPreview ? '' : '+x\n',
            previewKind: kind,
          ),
          name: 'An assistant with a long name ${'x' * 40}',
          tool: 'write_file',
        );
        ask(command('uptime'));
        await pump2(tester);
        final warning = find.byKey(const ValueKey('approval-partial-warning'));
        expect(warning, findsOneWidget);
        final viewport = tester.getRect(
          find
              .descendant(
                of: find.byType(BridgeApprovalCard),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        final rect = tester.getRect(warning);
        expect(rect.top, greaterThanOrEqualTo(viewport.top));
        expect(rect.top + 40, lessThanOrEqualTo(viewport.bottom),
            reason: 'the warning heading must show without scrolling');
      });
    }
  });
}
