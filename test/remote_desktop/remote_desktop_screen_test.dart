import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/remote_desktop/csrd_client.dart';

import 'remote_desktop_screen_support.dart';

/// The screen's life: opening, failing, running, ending, leaving. What the
/// person does to a running screen is in `remote_desktop_screen_input_test`
/// and `remote_desktop_screen_toolbar_test`.
void main() {
  testWidgets('opening shows progress and a Cancel; connecting shows the '
      'viewer', (tester) async {
    FakePlatform(tester);
    final gate = Completer<void>();
    final opener = FakeOpener(progress: ['Uploading the agent…'])
      ..outcomes.add(gate);
    await pumpHost(tester, opener);
    await tester.tap(find.text('Open desktop'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('build-box'), findsOneWidget);
    expect(find.text('Uploading the agent…'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    expect(find.byKey(const ValueKey('remote-viewer')), findsNothing);

    gate.complete();
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('remote-viewer')), findsOneWidget);
    expect(find.text('Cancel'), findsNothing);
  });

  testWidgets('before any progress it says it is connecting', (tester) async {
    FakePlatform(tester);
    final opener = FakeOpener()..outcomes.add(Completer<void>());
    await pumpHost(tester, opener);
    await tester.tap(find.text('Open desktop'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Connecting…'), findsOneWidget);
  });

  testWidgets('a waiting event is shown inline while opening', (tester) async {
    FakePlatform(tester);
    final gate = Completer<void>();
    final opener = FakeOpener()..outcomes.add(gate);
    await pumpHost(tester, opener);
    await tester.tap(find.text('Open desktop'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('consent dialog'), findsNothing);

    opener.sessions.single.emit(const CsrdWaitingEvent('waiting'));
    await tester.pump();
    expect(find.textContaining('consent dialog'), findsOneWidget);
    gate.complete();
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('consent dialog'), findsNothing);
  });

  testWidgets('attach happens before the opener finishes connecting, so no '
      'event is missed', (tester) async {
    FakePlatform(tester);
    final gate = Completer<void>();
    final opener = FakeOpener()..outcomes.add(gate);
    await pumpHost(tester, opener);
    await tester.tap(find.text('Open desktop'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // The first frame arrives while the opener is still working.
    final session = opener.sessions.single;
    session.showFrame(seq: 7);
    await settleFrames(tester);
    gate.complete();
    await tester.pump();
    await tester.pump();
    await settleFrames(tester);
    expect(session.acked, [7]);
  });

  testWidgets('a failure shows the error and Retry opens again', (
    tester,
  ) async {
    FakePlatform(tester);
    final opener = FakeOpener()..outcomes.add(Exception('no desktop to share'));
    await pumpHost(tester, opener);
    await tester.tap(find.text('Open desktop'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('The remote desktop could not be opened'), findsOneWidget);
    expect(find.text('no desktop to share'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(opener.calls, 1);

    await tester.tap(find.text('Retry'));
    await tester.pump();
    await tester.pump();
    expect(opener.calls, 2);
    expect(find.byKey(const ValueKey('remote-viewer')), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets('a connect failure from the client reads as its reason', (
    tester,
  ) async {
    FakePlatform(tester);
    final opener = FakeOpener()
      ..outcomes.add(
        const CsrdConnectException(
          CsrdCloseReason.error('the remote side rejected the connection'),
        ),
      );
    await pumpHost(tester, opener);
    await tester.tap(find.text('Open desktop'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      find.text('the remote side rejected the connection'),
      findsOneWidget,
    );
  });

  testWidgets('opening, connected, closed, reconnect', (tester) async {
    FakePlatform(tester);
    final opener = FakeOpener();
    final first = await openDesktop(tester, opener);
    expect(find.byKey(const ValueKey('remote-viewer')), findsOneWidget);

    first.endBy(
      const CsrdCloseReason.error('the remote side stopped responding'),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const ValueKey('remote-viewer')), findsNothing);
    expect(find.text('The remote desktop session ended'), findsOneWidget);
    expect(find.text('the remote side stopped responding'), findsOneWidget);
    expect(find.text('Reconnect'), findsOneWidget);
    // The remote is let go of as soon as the session is over, not later.
    expect(opener.releases, 1);

    await tester.tap(find.text('Reconnect'));
    await tester.pump();
    await tester.pump();
    expect(opener.calls, 2);
    expect(opener.sessions, hasLength(2));
    expect(find.byKey(const ValueKey('remote-viewer')), findsOneWidget);
    expect(find.text('Reconnect'), findsNothing);

    // The old session is not driven again; the new one is.
    opener.sessions.last.showFrame(seq: 1);
    await settleFrames(tester);
    expect(opener.sessions.last.acked, [1]);
    expect(first.acked, [1]);
  });

  testWidgets('the remote hanging up says so', (tester) async {
    FakePlatform(tester);
    final opener = FakeOpener();
    final session = await openDesktop(tester, opener);
    session.endBy(const CsrdCloseReason.peer());
    await tester.pump();
    await tester.pump();
    expect(find.text('the remote side closed the connection'), findsOneWidget);
  });

  testWidgets('a session that ended while it was still opening goes straight '
      'to closed', (tester) async {
    FakePlatform(tester);
    final gate = Completer<void>();
    final opener = FakeOpener()..outcomes.add(gate);
    await pumpHost(tester, opener);
    await tester.tap(find.text('Open desktop'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    opener.sessions.single.endBy(const CsrdCloseReason.peer());
    await tester.pump();
    expect(find.text('Cancel'), findsOneWidget);
    gate.complete();
    await tester.pump();
    await tester.pump();
    expect(find.text('Reconnect'), findsOneWidget);
    expect(opener.releases, 1);
  });

  testWidgets('leaving closes the session, then releases, exactly once', (
    tester,
  ) async {
    FakePlatform(tester);
    final opener = FakeOpener();
    final session = await openDesktop(tester, opener);
    expect(opener.releases, 0);

    await leaveScreen(tester);

    expect(find.byKey(const ValueKey('remote-viewer')), findsNothing);
    expect(session.closeCalls, 1);
    expect(opener.releases, 1);
    // The session was closed before the remote was let go of.
    expect(opener.events.last, 'release 1 after-close=1');
    // Held input was let go of on the way out.
    expect(session.log, contains('releaseAll'));
    expect(
      session.log.indexOf('releaseAll'),
      lessThan(session.log.indexOf('close')),
    );
  });

  testWidgets('the Disconnect button leaves too', (tester) async {
    FakePlatform(tester);
    final opener = FakeOpener();
    await openDesktop(tester, opener);
    await tester.tap(find.byTooltip('Disconnect'));
    await settleRoute(tester);
    expect(find.text('Open desktop'), findsOneWidget);
    expect(opener.releases, 1);
  });

  testWidgets('leaving after the session ended releases only once', (
    tester,
  ) async {
    FakePlatform(tester);
    final opener = FakeOpener();
    final session = await openDesktop(tester, opener);
    session.endBy(const CsrdCloseReason.peer());
    await tester.pump();
    await tester.pump();
    await leaveScreen(tester);
    expect(opener.releases, 1);
  });

  testWidgets('a virtual desktop that keeps running says so on the way out, '
      'and its title is the screen\'s', (tester) async {
    FakePlatform(tester);
    final opener = FakeOpener(keepsRunning: true);
    await openDesktop(tester, opener);
    expect(find.text('Virtual desktop :3'), findsOneWidget);
    expect(find.text('build-box'), findsNothing);

    await leaveScreen(tester);
    expect(
      find.text('The virtual desktop keeps running on the server.'),
      findsOneWidget,
    );
    expect(opener.releases, 1);
  });

  testWidgets('an ordinary desktop leaves without that snackbar', (
    tester,
  ) async {
    FakePlatform(tester);
    final opener = FakeOpener();
    await openDesktop(tester, opener);
    await leaveScreen(tester);
    expect(find.textContaining('keeps running'), findsNothing);
  });

  testWidgets('cancelling while opening leaves, and what the opener starts '
      'afterwards is closed and released', (tester) async {
    FakePlatform(tester);
    final gate = Completer<void>();
    final opener = FakeOpener()..outcomes.add(gate);
    await pumpHost(tester, opener);
    await tester.tap(find.text('Open desktop'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.text('Cancel'));
    await settleRoute(tester);
    expect(find.text('Open desktop'), findsOneWidget);
    expect(opener.releases, 0);

    // The opener finishes after the screen has gone.
    gate.complete();
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(opener.sessions.single.closeCalls, 1);
    expect(opener.releases, 1);
  });

  testWidgets('the opener failing after the screen left is not shown', (
    tester,
  ) async {
    FakePlatform(tester);
    final opener = FakeOpener();
    // A fake whose failure comes late: the gate completes with an error.
    final gate = Completer<void>();
    opener.outcomes.add(gate);
    await pumpHost(tester, opener);
    await tester.tap(find.text('Open desktop'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Cancel'));
    await settleRoute(tester);

    gate.completeError(Exception('too late'));
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('too late'), findsNothing);
  });

  testWidgets('the screen has one title bar title and a stats readout', (
    tester,
  ) async {
    FakePlatform(tester);
    final opener = FakeOpener();
    final session = await openDesktop(tester, opener);
    session.rtt = const Duration(milliseconds: 42);
    session.showFrame(seq: 2, wireBytes: 2048);
    await settleFrames(tester);
    await tester.pump(const Duration(seconds: 1));
    // One frame in the last second, 2 KB of it (the first frame's bytes
    // have aged out), 42 ms round trip.
    expect(find.textContaining('fps'), findsOneWidget);
    expect(find.textContaining('42 ms'), findsOneWidget);
  });

  testWidgets('the stats readout leaves out an unmeasured round trip', (
    tester,
  ) async {
    FakePlatform(tester);
    final opener = FakeOpener();
    await openDesktop(tester, opener);
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining(' fps · '), findsOneWidget);
    expect(find.textContaining(' ms · '), findsNothing);
  });
}
