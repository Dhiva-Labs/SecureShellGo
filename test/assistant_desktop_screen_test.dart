import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/models/host_ai_access.dart';
import 'package:secure_shell_go/screens/assistant_desktop_screen.dart';
import 'package:secure_shell_go/services/assistant_drive.dart';
import 'package:secure_shell_go/services/bridge/bridge_approvals.dart';
import 'package:secure_shell_go/services/bridge/bridge_client_store.dart';
import 'package:secure_shell_go/services/bridge/bridge_desktops.dart';
import 'package:secure_shell_go/services/bridge/bridge_tools.dart';
import 'package:secure_shell_go/services/remote_desktop/csrd_client.dart';
import 'package:secure_shell_go/widgets/bridge_approval_card.dart';

import 'remote_desktop/remote_desktop_screen_support.dart';
import 'support/bridge_fakes.dart';
import 'support/fake_transport.dart';

// The app side of the assistant's desktop: the link that decodes the
// screen and encodes screenshots with dart:ui, the viewer the user watches
// with its banner, and the approval card. The remote side is the remote
// desktop suite's fake session; no real remote desktop is opened.

class _Transport extends FakeTransportBase {
  var closes = 0;

  @override
  void close() => closes++;
}

class _PlanContext implements BridgePlanContext {
  _PlanContext(this.host);

  @override
  final Host host;

  @override
  BridgeClient get client => testBridgeClient;

  @override
  String get hostName => 'desk';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CallContext implements BridgeCallContext {
  _CallContext(this.host);

  @override
  final Host host;

  @override
  Future<T> bounded<T>(Future<T> work) => work;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Host _host() => bridgeHost(
  'dsk1',
  'desk',
  access: HostAiAccess.askToChange,
).copyWith(aiDesktop: true);

void main() {
  late FakeOpener remote;
  late _Transport transport;
  late List<Host> dialled;

  AssistantDesktopLink? lastLink;

  Future<AssistantDesktopLink> openLink(Host host) async {
    dialled.add(host);
    final link = await AssistantDesktopLink.open(
      dial: () async => transport,
      opener: (t, {required progress, required attach}) =>
          remote.call(progress: progress, attach: attach),
    );
    return lastLink = link;
  }

  setUp(() {
    remote = FakeOpener();
    transport = _Transport();
    dialled = [];
    lastLink = null;
  });

  testWidgets('the link: frames decoded, a scaled PNG screenshot, and close '
      'lets go of everything', (tester) async {
    late AssistantDesktopLink link;
    link = await openLink(_host());
    final session = remote.sessions.single;
    var first = false;
    unawaited(link.firstFrame.then((_) => first = true));
    expect(link.width, 0);
    session.showFrame(width: 800, height: 600);
    await tester.pump();
    await tester.pump();
    expect(first, isTrue);
    expect(link.width, 800);
    expect(link.height, 600);
    expect(link.session, same(session));

    Uint8List? png;
    ui.Image? decoded;
    Uint8List? pixel;
    await tester.runAsync(() async {
      png = await link.capturePng(400, 300);
      final codec = await ui.instantiateImageCodec(png!);
      decoded = (await codec.getNextFrame()).image;
      pixel = (await decoded!.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!.buffer.asUint8List(0, 4);
    });
    expect(png!.sublist(0, 4), [0x89, 0x50, 0x4e, 0x47]);
    expect(decoded!.width, 400);
    expect(decoded!.height, 300);
    // The fake's solid colour, 0xff204060.
    expect(pixel, [0x20, 0x40, 0x60, 0xff]);
    decoded!.dispose();

    await tester.runAsync(link.close);
    expect(session.closeCalls, 1);
    expect(remote.releases, 1);
    expect(transport.closes, 1);
    // Idempotent.
    await tester.runAsync(link.close);
    expect(transport.closes, 1);
  });

  testWidgets('a session that ends before its first frame fails the wait',
      (tester) async {
    late AssistantDesktopLink link;
    link = await openLink(_host());
    Object? error;
    unawaited(link.firstFrame.then((_) {}, onError: (Object e) => error = e));
    var done = false;
    unawaited(link.done.then((_) => done = true));
    remote.sessions.single.endBy(const CsrdCloseReason.local());
    await tester.pump();
    expect(error, isNotNull);
    expect(done, isTrue);
  });

  group('the viewer', () {
    late BridgeDesktops desktops;
    late GlobalKey<NavigatorState> navigator;
    late StreamController<bool> lock;
    late AssistantDesktopHost host;

    Future<String> openDesktop(WidgetTester tester) async {
      final plan = await desktops.openTool.plan(
        BridgeToolArgs(const {'host': 'desk'}, const {'host'}),
        _PlanContext(_host()),
      );
      final result = desktops.openTool.run(_CallContext(_host()), plan);
      await tester.pump();
      remote.sessions.single.showFrame(width: 1600, height: 900);
      await tester.pump();
      await tester.pump();
      final r = await result;
      expect(r.isError, isFalse, reason: r.text);
      await tester.pumpAndSettle();
      return RegExp(r'desktop_id: (\S+)').firstMatch(r.text)!.group(1)!;
    }

    Future<void> pumpApp(WidgetTester tester) async {
      desktops = BridgeDesktops(open: openLink);
      navigator = GlobalKey<NavigatorState>();
      lock = StreamController<bool>.broadcast();
      host = AssistantDesktopHost(
        navigatorKey: navigator,
        desktops: desktops,
        lockChanges: lock.stream,
      )..start();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          home: const Scaffold(body: Text('home')),
        ),
      );
      addTearDown(() async {
        await host.dispose();
        await lock.close();
      });
    }

    testWidgets('opens in front of the user with the banner; Take over hands '
        'it to the user and the assistant loses it', (tester) async {
      await pumpApp(tester);
      final id = await openDesktop(tester);
      expect(dialled.single.id, 'dsk1');
      expect(
        find.text('Test assistant is using this desktop. You can watch it.'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('assistant-desktop-viewer')),
          findsOneWidget);
      // While the assistant has it, the user's pointer does not reach it.
      final ignoring = tester.widget<IgnorePointer>(
        find
            .ancestor(
              of: find.byKey(const ValueKey('assistant-desktop-viewer')),
              matching: find.byType(IgnorePointer),
            )
            .first,
      );
      expect(ignoring.ignoring, isTrue);

      await tester.tap(find.byKey(const ValueKey('assistant-desktop-take-over')));
      await tester.pump();
      expect(desktops.byId(id)!.state, AssistantDriveState.takenOver);
      expect(
        find.text(
          'You took over. Test assistant can no longer see or use this '
          'desktop.',
        ),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('assistant-desktop-stop')), findsNothing);
      final now = tester.widget<IgnorePointer>(
        find
            .ancestor(
              of: find.byKey(const ValueKey('assistant-desktop-viewer')),
              matching: find.byType(IgnorePointer),
            )
            .first,
      );
      expect(now.ignoring, isFalse);
      expect(transport.closes, 0);

      // Leaving the viewer ends it, the user's too, and hangs up.
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      expect(find.text('home'), findsOneWidget);
      expect(desktops.byId(id)!.endedBy, AssistantDesktopEnd.viewerClosed);
      expect(transport.closes, 1);
      expect(remote.releases, 1);
      await desktops.dispose();
    });

    testWidgets('Stop ends it; the banner says so and Close leaves',
        (tester) async {
      await pumpApp(tester);
      final id = await openDesktop(tester);
      await tester.tap(find.byKey(const ValueKey('assistant-desktop-stop')));
      await tester.pump();
      await tester.pump();
      expect(desktops.byId(id)!.endedBy, AssistantDesktopEnd.stoppedByUser);
      expect(
        find.text('The desktop of Test assistant ended: Stopped.'),
        findsOneWidget,
      );
      expect(transport.closes, 1);
      await tester.tap(find.byKey(const ValueKey('assistant-desktop-close')));
      await tester.pumpAndSettle();
      expect(find.text('home'), findsOneWidget);
      expect(lastLink, isNotNull);
      await desktops.dispose();
    });
  });

  group('the approval card', () {
    BridgeApprovalRequest request() => BridgeApprovalRequest(
      id: 'a1',
      client: testBridgeClient,
      hostId: 'dsk1',
      hostName: 'desk',
      tool: 'open_desktop',
      summary: const DesktopSummary(),
      createdAt: DateTime.now(),
      expiresAt: DateTime.now().add(const Duration(minutes: 2)),
    );

    testWidgets('asks to open a desktop: who, where, the warning, and never '
        '"for a while"', (tester) async {
      BridgeApprovalAnswer? answer;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BridgeApprovalCard(
              request: request(),
              timedMinutes: 15,
              armDelay: Duration.zero,
              onAnswer: (a) => answer = a,
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 10));
      expect(find.text('Open a desktop for the assistant?'), findsOneWidget);
      expect(find.text('Asked by Test assistant'), findsOneWidget);
      expect(find.byKey(const ValueKey('approval-host')), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('approval-host')))
            .data,
        contains('desk'),
      );
      expect(
        find.byKey(const ValueKey('approval-desktop-warning')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('approval-desktop-text')))
            .data,
        allOf(
          contains('screen'),
          contains('mouse'),
          contains('type'),
          contains('signed in'),
        ),
      );
      expect(
        find.byKey(const ValueKey('approval-allow-for-a-while')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('approval-timed-note')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('approval-allow-once')));
      expect(answer, BridgeApprovalAnswer.allowOnce);
      // Let the card's own timers go.
      await tester.pumpWidget(const SizedBox());
    });

    test('"allow for a while" on a desktop card is only once', () async {
      final approvals = BridgeApprovals(timedApprovalMinutes: () => 15);
      final r = approvals.request(
        client: testBridgeClient,
        hostId: 'dsk1',
        hostName: 'desk',
        tool: 'open_desktop',
        summary: const DesktopSummary(),
      );
      final outcome = approvals.ask(r);
      approvals.answer(r.id, BridgeApprovalAnswer.allowForAWhile);
      expect(await outcome, BridgeApprovalOutcome.allowedOnce);
      await approvals.dispose();
    });
  });
}
