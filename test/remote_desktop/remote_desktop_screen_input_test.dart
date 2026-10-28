import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/remote_desktop/csrd_client.dart';
import 'package:secure_shell_go/services/remote_desktop/csrd_keymap.dart';
import 'package:secure_shell_go/services/remote_desktop/csrd_messages.dart';

import 'remote_desktop_screen_support.dart';

/// Pointer, keyboard and touch: what the person does to a running screen,
/// and the calls the session gets for it.
void main() {
  // The remote screen in every test here is 800 × 600, and the pointer
  // events carry no timestamps, so a limited move is held until the timer
  // that sends it has been given time to fire.
  Future<void> flushMoves(WidgetTester tester) =>
      tester.pump(const Duration(milliseconds: 30));

  List<String> only(List<String> log, Pattern prefix) => [
    for (final l in log)
      if (l.startsWith(prefix)) l,
  ];

  group('the keyboard', () {
    testWidgets('keys go down and up, with the evdev codes, and repeats are '
        'left to the remote', (tester) async {
      FakePlatform(tester);
      final session = await openDesktop(
        tester,
        FakeOpener(),
        platform: TargetPlatform.linux,
      );
      final mark = session.log.length;

      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);

      expect(session.since(mark), [
        'key ${CsrdEvdev.keyA} down',
        'key ${CsrdEvdev.keyA} up',
      ]);
    });

    testWidgets('Ctrl+W and Tab go to the remote, not to the app', (
      tester,
    ) async {
      FakePlatform(tester);
      final session = await openDesktop(
        tester,
        FakeOpener(),
        platform: TargetPlatform.linux,
      );
      final mark = session.log.length;
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyW);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyW);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);

      expect(session.since(mark), [
        'key ${CsrdEvdev.keyLeftCtrl} down',
        'key ${CsrdEvdev.keyW} down',
        'key ${CsrdEvdev.keyW} up',
        'key ${CsrdEvdev.keyLeftCtrl} up',
        'key ${CsrdEvdev.keyTab} down',
        'key ${CsrdEvdev.keyTab} up',
      ]);
    });

    testWidgets('a key with no evdev code is dropped', (tester) async {
      FakePlatform(tester);
      final session = await openDesktop(
        tester,
        FakeOpener(),
        platform: TargetPlatform.linux,
      );
      final mark = session.log.length;
      await tester.sendKeyEvent(
        LogicalKeyboardKey.power,
        physicalKey: PhysicalKeyboardKey.power,
      );
      expect(session.since(mark), isEmpty);
    });

    testWidgets('losing focus releases what is held', (tester) async {
      FakePlatform(tester);
      final session = await openDesktop(
        tester,
        FakeOpener(),
        platform: TargetPlatform.linux,
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA);
      final mark = session.log.length;

      FocusManager.instance.primaryFocus!.unfocus();
      await tester.pump();

      expect(session.since(mark), ['releaseAll']);
      // And the keys that come up afterwards are not the remote's business:
      // it was told they were released.
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      expect(session.since(mark), ['releaseAll']);
    });

    testWidgets('the toolbar\'s release-keyboard button hands the keyboard '
        'back and releases keys, and a click takes it again', (tester) async {
      FakePlatform(tester);
      final session = await openDesktop(
        tester,
        FakeOpener(),
        platform: TargetPlatform.linux,
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      final mark = session.log.length;

      await tester.tap(
        find.byTooltip(
          'Stop sending keys to the remote (click the screen to resume)',
        ),
      );
      await tester.pump();
      expect(session.since(mark), ['releaseAll']);

      // Keys now go nowhere near the remote.
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
      expect(session.since(mark), ['releaseAll']);

      // A click on the screen takes the keyboard back.
      await tester.tapAt(
        viewerPoint(tester, 400, 300),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      final after = session.log.length;
      await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
      expect(session.since(after), [
        'key ${CsrdEvdev.keyB} down',
        'key ${CsrdEvdev.keyB} up',
      ]);
    });

    testWidgets('using the toolbar does not take the keyboard away', (
      tester,
    ) async {
      FakePlatform(tester);
      final session = await openDesktop(
        tester,
        FakeOpener(),
        platform: TargetPlatform.linux,
      );
      await tester.tap(find.byTooltip('Actual size (1:1)'));
      await tester.pump();
      final mark = session.log.length;
      await tester.sendKeyEvent(LogicalKeyboardKey.keyQ);
      expect(session.since(mark), [
        'key ${CsrdEvdev.keyQ} down',
        'key ${CsrdEvdev.keyQ} up',
      ]);
    });

    testWidgets('the app leaving the foreground releases what is held', (
      tester,
    ) async {
      FakePlatform(tester);
      final session = await openDesktop(tester, FakeOpener());
      final mark = session.log.length;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(only(session.since(mark), 'releaseAll'), isNotEmpty);

      final back = session.log.length;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      // Coming back needs nothing sent.
      expect(only(session.since(back), 'key'), isEmpty);
    });
  });

  group('view-only', () {
    testWidgets('releases what is held, then sends nothing at all', (
      tester,
    ) async {
      FakePlatform(tester);
      final session = await openDesktop(
        tester,
        FakeOpener(),
        platform: TargetPlatform.linux,
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA);
      final mark = session.log.length;

      await tester.tap(find.byTooltip('View only (send no input)'));
      await tester.pump();
      expect(session.since(mark), ['releaseAll', 'viewOnly true']);
      expect(session.viewOnly, isTrue);

      final quiet = session.log.length;
      // Keys.
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
      // Mouse: move, press, release, wheel.
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: viewerPoint(tester, 100, 100));
      await mouse.moveTo(viewerPoint(tester, 200, 200));
      await mouse.down(viewerPoint(tester, 200, 200));
      await mouse.up();
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: viewerPoint(tester, 200, 200),
          scrollDelta: const Offset(0, 40),
        ),
      );
      // Touch: a tap, and two fingers scrolling.
      await tester.tapAt(viewerPoint(tester, 300, 300));
      final a = await tester.startGesture(
        viewerPoint(tester, 300, 300),
        pointer: 11,
      );
      final b = await tester.startGesture(
        viewerPoint(tester, 400, 300),
        pointer: 12,
      );
      await a.moveBy(const Offset(0, 60));
      await b.moveBy(const Offset(0, 60));
      await a.up();
      await b.up();
      await flushMoves(tester);

      expect(session.since(quiet), isEmpty);
    });

    testWidgets('can be turned off again, and input flows', (tester) async {
      FakePlatform(tester);
      final session = await openDesktop(
        tester,
        FakeOpener(),
        platform: TargetPlatform.linux,
      );
      await tester.tap(find.byTooltip('View only (send no input)'));
      await tester.pump();
      await tester.tap(find.byTooltip('View only (send no input)'));
      await tester.pump();
      expect(session.viewOnly, isFalse);
      final mark = session.log.length;
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      expect(session.since(mark), [
        'key ${CsrdEvdev.keyC} down',
        'key ${CsrdEvdev.keyC} up',
      ]);
    });

    testWidgets('a session started view-only cannot be turned on or off, '
        'and says why', (tester) async {
      FakePlatform(tester);
      final opener = FakeOpener()
        ..makeSession = () =>
            FakeRemoteScreenSession(viewOnly: true, viewOnlyLocked: true);
      final session = await openDesktop(
        tester,
        opener,
        platform: TargetPlatform.linux,
      );
      final reason = 'This session was started view-only and cannot send input';
      // View-only is on, so the button shows its selected icon.
      final button = find.widgetWithIcon(IconButton, Icons.visibility);
      expect(tester.widget<IconButton>(button).onPressed, isNull);
      expect(find.byTooltip(reason), findsOneWidget);
      expect(session.viewOnly, isTrue);
      final mark = session.log.length;
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      expect(session.since(mark), isEmpty);
    });
  });

  group('the mouse', () {
    testWidgets('hovering moves the remote pointer to the pixel under it, '
        'rate limited, and the last position always arrives', (tester) async {
      FakePlatform(tester);
      final session = await openDesktop(
        tester,
        FakeOpener(),
        platform: TargetPlatform.linux,
      );
      final mark = session.log.length;
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: viewerPoint(tester, 10, 10));
      await mouse.moveTo(viewerPoint(tester, 100, 120));
      await mouse.moveTo(viewerPoint(tester, 200, 220));
      await mouse.moveTo(viewerPoint(tester, 300, 320));
      await flushMoves(tester);

      final moves = only(session.since(mark), 'move');
      expect(moves.first, 'move 100,120');
      expect(moves.last, 'move 300,320');
      // Rate limited: the middle one was never needed.
      expect(moves.length, lessThanOrEqualTo(3));
    });

    testWidgets('buttons map to the wire\'s numbers and land where the '
        'pointer is', (tester) async {
      FakePlatform(tester);
      final session = await openDesktop(
        tester,
        FakeOpener(),
        platform: TargetPlatform.linux,
      );
      final at = viewerPoint(tester, 250, 350);
      for (final (flutterButton, wire) in [
        (kPrimaryButton, CsrdButton.left),
        (kSecondaryButton, CsrdButton.right),
        (kMiddleMouseButton, CsrdButton.middle),
        (kBackMouseButton, CsrdButton.back),
        (kForwardMouseButton, CsrdButton.forward),
      ]) {
        final mark = session.log.length;
        final mouse = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
          buttons: flutterButton,
        );
        await mouse.down(at);
        await mouse.up();
        await mouse.removePointer();
        final log = session.since(mark);
        expect(log.contains('button $wire down'), isTrue, reason: '$wire');
        expect(log.last, 'button $wire up', reason: '$wire');
        // The pointer was put on the spot before the press.
        expect(
          log.indexOf('move 250,350'),
          lessThan(log.indexOf('button $wire down')),
        );
      }
    });

    testWidgets('a press in the letterbox is not sent, nor its release', (
      tester,
    ) async {
      FakePlatform(tester);
      final session = await openDesktop(
        tester,
        FakeOpener(),
        platform: TargetPlatform.linux,
      );
      // The picture is 4:3 in a wider viewer: bars at both sides.
      final r = viewerRect(tester);
      final mark = session.log.length;
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.down(Offset(r.left + 5, r.center.dy));
      await mouse.up();
      expect(only(session.since(mark), 'button'), isEmpty);
    });

    testWidgets('a drag that leaves the picture is let go of at its edge', (
      tester,
    ) async {
      FakePlatform(tester);
      final session = await openDesktop(
        tester,
        FakeOpener(),
        platform: TargetPlatform.linux,
      );
      final r = viewerRect(tester);
      final mark = session.log.length;
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.down(viewerPoint(tester, 700, 300));
      await mouse.moveTo(Offset(r.right - 2, r.center.dy));
      await mouse.up();
      final log = session.since(mark);
      expect(log, contains('button ${CsrdButton.left} down'));
      expect(log.last, 'button ${CsrdButton.left} up');
      // The last position before the release is the last pixel of the row.
      expect(only(log, 'move').last, startsWith('move 799,'));
    });

    testWidgets('the wheel scrolls, 120 to a notch of 40 px, down is '
        'negative', (tester) async {
      FakePlatform(tester);
      final session = await openDesktop(
        tester,
        FakeOpener(),
        platform: TargetPlatform.linux,
      );
      final mark = session.log.length;
      final at = viewerPoint(tester, 400, 300);
      await tester.sendEventToBinding(
        PointerScrollEvent(position: at, scrollDelta: const Offset(0, 40)),
      );
      await tester.sendEventToBinding(
        PointerScrollEvent(position: at, scrollDelta: const Offset(40, -80)),
      );
      expect(session.since(mark), ['scroll 0,-120', 'scroll 120,240']);
    });

    testWidgets('a wheel over the letterbox scrolls nothing', (tester) async {
      FakePlatform(tester);
      final session = await openDesktop(
        tester,
        FakeOpener(),
        platform: TargetPlatform.linux,
      );
      final r = viewerRect(tester);
      final mark = session.log.length;
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: Offset(r.left + 5, r.center.dy),
          scrollDelta: const Offset(0, 40),
        ),
      );
      expect(session.since(mark), isEmpty);
    });

    testWidgets('a trackpad pan scrolls, with the fingers\' direction', (
      tester,
    ) async {
      FakePlatform(tester);
      final session = await openDesktop(
        tester,
        FakeOpener(),
        platform: TargetPlatform.linux,
      );
      final mark = session.log.length;
      final pad = TestPointer(7, PointerDeviceKind.trackpad);
      final at = viewerPoint(tester, 400, 300);
      await tester.sendEventToBinding(pad.panZoomStart(at));
      await tester.sendEventToBinding(
        pad.panZoomUpdate(at, pan: const Offset(0, 40)),
      );
      await tester.sendEventToBinding(
        pad.panZoomUpdate(at, pan: const Offset(20, 80)),
      );
      await tester.sendEventToBinding(pad.panZoomEnd());
      // Fingers moved 80 down and 20 right: scrolled up 240, left 60.
      expect(only(session.since(mark), 'scroll'), [
        'scroll 0,120',
        'scroll -60,120',
      ]);
    });

    testWidgets('Ctrl and the wheel zoom the view and scroll nothing', (
      tester,
    ) async {
      FakePlatform(tester);
      final session = await openDesktop(
        tester,
        FakeOpener(),
        platform: TargetPlatform.linux,
      );
      final probe = viewerPoint(tester, 100, 100);
      final before = await _remoteUnder(tester, session, probe);
      expect(before, (100, 100));

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      final mark = session.log.length;
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: viewerRect(tester).center,
          scrollDelta: const Offset(0, -240),
        ),
      );
      await tester.pump();
      expect(only(session.since(mark), 'scroll'), isEmpty);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

      // Zoomed in about the middle: the same spot on screen is now nearer
      // the middle of the remote screen.
      final after = await _remoteUnder(tester, session, probe);
      expect(after.$1, greaterThan(100));
      expect(after.$2, greaterThan(100));
      expect(after.$1, lessThan(400));
    });

    testWidgets('a trackpad pinch zooms the view', (tester) async {
      FakePlatform(tester);
      final session = await openDesktop(
        tester,
        FakeOpener(),
        platform: TargetPlatform.linux,
      );
      final probe = viewerPoint(tester, 100, 100);
      final pad = TestPointer(8, PointerDeviceKind.trackpad);
      final centre = viewerRect(tester).center;
      final mark = session.log.length;
      await tester.sendEventToBinding(pad.panZoomStart(centre));
      await tester.sendEventToBinding(pad.panZoomUpdate(centre, scale: 1.5));
      await tester.sendEventToBinding(pad.panZoomUpdate(centre, scale: 2));
      await tester.sendEventToBinding(pad.panZoomEnd());
      await tester.pump();
      expect(only(session.since(mark), 'scroll'), isEmpty);
      final after = await _remoteUnder(tester, session, probe);
      expect(after.$1, greaterThan(100));
    });

    testWidgets('zoomed in, the pointer at the edge scrolls the picture '
        'along, and the pointer follows what is under it', (tester) async {
      FakePlatform(tester);
      final session = await openDesktop(
        tester,
        FakeOpener(),
        platform: TargetPlatform.linux,
      );
      // Zoom in about the middle with Ctrl and the wheel.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      for (var i = 0; i < 3; i++) {
        await tester.sendEventToBinding(
          PointerScrollEvent(
            position: viewerRect(tester).center,
            scrollDelta: const Offset(0, -240),
          ),
        );
      }
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      final r = viewerRect(tester);
      final edge = Offset(r.right - 4, r.center.dy);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: r.center);
      await mouse.moveTo(edge);
      await tester.pump(const Duration(milliseconds: 30));
      final first = _lastMove(session);
      await tester.pump(const Duration(milliseconds: 400));
      final later = _lastMove(session);
      // What is under the pointer has moved along to the right.
      expect(later.$1, greaterThan(first.$1));
      expect(later.$1, lessThanOrEqualTo(799));

      // Taken off the edge, it stops.
      await mouse.moveTo(r.center);
      await tester.pump(const Duration(milliseconds: 100));
      final settled = _lastMove(session);
      await tester.pump(const Duration(milliseconds: 400));
      expect(_lastMove(session), settled);
      await mouse.removePointer();
    });

    testWidgets('the edge stops scrolling at the end of the picture, and '
        'leaves no timer running', (tester) async {
      FakePlatform(tester);
      final session = await openDesktop(
        tester,
        FakeOpener(),
        platform: TargetPlatform.linux,
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: viewerRect(tester).center,
          scrollDelta: const Offset(0, -240),
        ),
      );
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      final r = viewerRect(tester);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: r.center);
      await mouse.moveTo(Offset(r.right - 2, r.bottom - 2));
      // Long enough to reach the far corner many times over.
      await tester.pump(const Duration(seconds: 10));
      expect(_lastMove(session), (799, 599));
      // No timer is left ticking (the test would fail on one at its end).
      await mouse.removePointer();
    });

    testWidgets('the local pointer is hidden over the picture on a desktop', (
      tester,
    ) async {
      FakePlatform(tester);
      await openDesktop(tester, FakeOpener(), platform: TargetPlatform.linux);
      final region = tester.widget<MouseRegion>(
        find
            .descendant(
              of: find.byKey(const ValueKey('remote-viewer')),
              matching: find.byType(MouseRegion),
            )
            .first,
      );
      expect(region.cursor, SystemMouseCursors.none);
    });

    testWidgets('and left alone in view-only mode, where nothing else moves', (
      tester,
    ) async {
      FakePlatform(tester);
      await openDesktop(tester, FakeOpener(), platform: TargetPlatform.linux);
      await tester.tap(find.byTooltip('View only (send no input)'));
      await tester.pump();
      final region = tester.widget<MouseRegion>(
        find
            .descendant(
              of: find.byKey(const ValueKey('remote-viewer')),
              matching: find.byType(MouseRegion),
            )
            .first,
      );
      expect(region.cursor, isNot(SystemMouseCursors.none));
    });
  });

  group('touch, in trackpad mode', () {
    Future<FakeRemoteScreenSession> open(WidgetTester tester) async {
      FakePlatform(tester);
      final session = await openDesktop(tester, FakeOpener());
      session.emit(const CsrdCursorPosEvent(400, 300));
      await tester.pump();
      return session;
    }

    testWidgets('a tap is a left click at the cursor, wherever it lands', (
      tester,
    ) async {
      final session = await open(tester);
      final mark = session.log.length;
      // Nowhere near the cursor.
      await tester.tapAt(viewerPoint(tester, 40, 40));
      await tester.pump();
      expect(session.since(mark), [
        'move 400,300',
        'button ${CsrdButton.left} down',
        'button ${CsrdButton.left} up',
      ]);
    });

    testWidgets('dragging moves the cursor relatively', (tester) async {
      final session = await open(tester);
      final mark = session.log.length;
      final finger = await tester.startGesture(viewerPoint(tester, 100, 100));
      await finger.moveBy(const Offset(30, 0));
      await finger.moveBy(const Offset(30, 0));
      await finger.moveBy(const Offset(0, 30));
      await finger.up();
      await flushMoves(tester);

      final moves = only(session.since(mark), 'move');
      expect(moves, isNotEmpty);
      final last = moves.last.substring(5).split(',').map(int.parse).toList();
      // It went right and down from where the cursor was, and by more than
      // the fingers did on screen because of the acceleration.
      expect(last[0], greaterThan(400));
      expect(last[1], greaterThan(300));
      expect(only(session.since(mark), 'button'), isEmpty);
    });

    testWidgets('two fingers tapped together are a right click', (
      tester,
    ) async {
      final session = await open(tester);
      final mark = session.log.length;
      final a = await tester.startGesture(
        viewerPoint(tester, 300, 300),
        pointer: 21,
      );
      final b = await tester.startGesture(
        viewerPoint(tester, 380, 300),
        pointer: 22,
      );
      await a.up();
      await b.up();
      await tester.pump();
      expect(session.since(mark), [
        'move 400,300',
        'button ${CsrdButton.right} down',
        'button ${CsrdButton.right} up',
      ]);
    });

    testWidgets('two fingers dragging scroll', (tester) async {
      final session = await open(tester);
      final mark = session.log.length;
      final a = await tester.startGesture(
        viewerPoint(tester, 300, 300),
        pointer: 21,
      );
      final b = await tester.startGesture(
        viewerPoint(tester, 380, 300),
        pointer: 22,
      );
      await a.moveBy(const Offset(0, 40));
      await b.moveBy(const Offset(0, 40));
      await a.up();
      await b.up();
      var total = 0;
      for (final l in only(session.since(mark), 'scroll')) {
        total += int.parse(l.split(',')[1]);
      }
      // 40 px is one notch: 120 units, fingers down so scrolled up.
      expect(total, 120);
      expect(only(session.since(mark), 'button'), isEmpty);
    });

    testWidgets('pinching zooms the view', (tester) async {
      final session = await open(tester);
      final probe = viewerPoint(tester, 100, 100);
      final before = await _remoteUnder(tester, session, probe);
      final centre = viewerRect(tester).center;
      final a = await tester.startGesture(
        centre - const Offset(40, 0),
        pointer: 21,
      );
      final b = await tester.startGesture(
        centre + const Offset(40, 0),
        pointer: 22,
      );
      await a.moveBy(const Offset(-40, 0));
      await b.moveBy(const Offset(40, 0));
      await a.moveBy(const Offset(-40, 0));
      await b.moveBy(const Offset(40, 0));
      await a.up();
      await b.up();
      await tester.pump();
      final after = await _remoteUnder(tester, session, probe);
      expect(after.$1, greaterThan(before.$1));
    });

    testWidgets('holding still then dragging drags with the left button', (
      tester,
    ) async {
      final session = await open(tester);
      final mark = session.log.length;
      final finger = await tester.startGesture(viewerPoint(tester, 100, 100));
      await tester.pump(const Duration(milliseconds: 600));
      await finger.moveBy(const Offset(50, 0));
      await finger.up();
      await flushMoves(tester);
      final log = session.since(mark);
      expect(log.contains('button ${CsrdButton.left} down'), isTrue);
      expect(log.last, 'button ${CsrdButton.left} up');
      expect(
        log.indexOf('button ${CsrdButton.left} down'),
        lessThan(log.indexOf(only(log, 'move').last)),
      );
    });

    testWidgets('the toolbar toggle switches to direct mode and back', (
      tester,
    ) async {
      await open(tester);
      expect(find.byTooltip('Switch to direct touch'), findsOneWidget);
      await tester.tap(find.byTooltip('Switch to direct touch'));
      await tester.pump();
      expect(find.byTooltip('Switch to trackpad mode'), findsOneWidget);
      await tester.tap(find.byTooltip('Switch to trackpad mode'));
      await tester.pump();
      expect(find.byTooltip('Switch to direct touch'), findsOneWidget);
    });
  });

  group('touch, in direct mode', () {
    Future<FakeRemoteScreenSession> open(WidgetTester tester) async {
      FakePlatform(tester);
      final session = await openDesktop(tester, FakeOpener());
      await tester.tap(find.byTooltip('Switch to direct touch'));
      await tester.pump();
      return session;
    }

    testWidgets('a tap clicks where it lands', (tester) async {
      final session = await open(tester);
      final mark = session.log.length;
      await tester.tapAt(viewerPoint(tester, 120, 480));
      await tester.pump();
      expect(session.since(mark), [
        'move 120,480',
        'button ${CsrdButton.left} down',
        'button ${CsrdButton.left} up',
      ]);
    });

    testWidgets('a tap in the letterbox is not sent', (tester) async {
      final session = await open(tester);
      final r = viewerRect(tester);
      final mark = session.log.length;
      await tester.tapAt(Offset(r.left + 5, r.center.dy));
      await tester.pump();
      expect(only(session.since(mark), 'button'), isEmpty);
    });

    testWidgets('a drag presses where it began and follows the finger', (
      tester,
    ) async {
      final session = await open(tester);
      final mark = session.log.length;
      final finger = await tester.startGesture(viewerPoint(tester, 200, 200));
      await finger.moveTo(viewerPoint(tester, 300, 250));
      await finger.moveTo(viewerPoint(tester, 400, 300));
      await finger.up();
      await flushMoves(tester);
      final log = session.since(mark);
      expect(log.first, 'move 200,200');
      expect(log[1], 'button ${CsrdButton.left} down');
      expect(log.last, 'button ${CsrdButton.left} up');
      expect(only(log, 'move').last, 'move 400,300');
    });

    testWidgets('holding still is a right click', (tester) async {
      final session = await open(tester);
      final mark = session.log.length;
      final finger = await tester.startGesture(viewerPoint(tester, 200, 200));
      await tester.pump(const Duration(milliseconds: 600));
      await finger.up();
      await tester.pump();
      expect(session.since(mark), [
        'move 200,200',
        'button ${CsrdButton.right} down',
        'button ${CsrdButton.right} up',
      ]);
    });
  });

  group('typing on the soft keyboard', () {
    Future<FakeRemoteScreenSession> open(WidgetTester tester) async {
      FakePlatform(tester);
      final session = await openDesktop(tester, FakeOpener());
      await tester.tap(find.byTooltip('Show keyboard'));
      await tester.pump();
      return session;
    }

    testWidgets('the button raises the keyboard', (tester) async {
      await open(tester);
      expect(tester.testTextInput.isRegistered, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
    });

    testWidgets('a typed character is its key, shifted for capitals', (
      tester,
    ) async {
      final session = await open(tester);
      final mark = session.log.length;
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '  a',
          selection: TextSelection.collapsed(offset: 3),
        ),
      );
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '  B',
          selection: TextSelection.collapsed(offset: 3),
        ),
      );
      await tester.pump();
      expect(session.since(mark), [
        'key ${CsrdEvdev.keyA} down',
        'key ${CsrdEvdev.keyA} up',
        'key ${CsrdEvdev.keyLeftShift} down',
        'key ${CsrdEvdev.keyB} down',
        'key ${CsrdEvdev.keyB} up',
        'key ${CsrdEvdev.keyLeftShift} up',
      ]);
    });

    testWidgets('Backspace and Enter', (tester) async {
      final session = await open(tester);
      final mark = session.log.length;
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: ' ',
          selection: TextSelection.collapsed(offset: 1),
        ),
      );
      await tester.testTextInput.receiveAction(TextInputAction.newline);
      await tester.pump();
      expect(session.since(mark), [
        'key ${CsrdEvdev.keyBackspace} down',
        'key ${CsrdEvdev.keyBackspace} up',
        'key ${CsrdEvdev.keyEnter} down',
        'key ${CsrdEvdev.keyEnter} up',
      ]);
    });

    testWidgets('pasted text is typed in order', (tester) async {
      final session = await open(tester);
      final mark = session.log.length;
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '  ls\n',
          selection: TextSelection.collapsed(offset: 5),
        ),
      );
      await tester.pump();
      final codes = [
        for (final l in session.since(mark))
          if (l.endsWith('down')) int.parse(l.split(' ')[1]),
      ];
      expect(codes, [CsrdEvdev.keyL, CsrdEvdev.keyS, CsrdEvdev.keyEnter]);
    });

    testWidgets('a character with no key is skipped, and the person is told '
        'once to use Paste to remote', (tester) async {
      final session = await open(tester);
      final mark = session.log.length;
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '  é',
          selection: TextSelection.collapsed(offset: 3),
        ),
      );
      await tester.pump();
      expect(only(session.since(mark), 'key'), isEmpty);
      expect(
        find.text(
          'Some characters cannot be typed from this keyboard. '
          'Use Paste to remote instead.',
        ),
        findsOneWidget,
      );

      // Dismissed and said again: it is not repeated.
      ScaffoldMessenger.of(
        tester.element(find.byType(Scaffold).first),
      ).clearSnackBars();
      await tester.pump();
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '  ü',
          selection: TextSelection.collapsed(offset: 3),
        ),
      );
      await tester.pump();
      expect(find.textContaining('cannot be typed'), findsNothing);
    });

    testWidgets('typing with Ctrl armed sends the combination', (tester) async {
      final session = await open(tester);
      await tester.tap(find.text('Ctrl'));
      await tester.pump();
      final mark = session.log.length;
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '  c',
          selection: TextSelection.collapsed(offset: 3),
        ),
      );
      await tester.pump();
      expect(session.since(mark), [
        'key ${CsrdEvdev.keyLeftCtrl} down',
        'key ${CsrdEvdev.keyC} down',
        'key ${CsrdEvdev.keyC} up',
        'key ${CsrdEvdev.keyLeftCtrl} up',
      ]);
    });

    testWidgets('nothing is typed in view-only mode', (tester) async {
      final session = await open(tester);
      await tester.tap(find.byTooltip('View only (send no input)'));
      await tester.pump();
      final mark = session.log.length;
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '  a',
          selection: TextSelection.collapsed(offset: 3),
        ),
      );
      await tester.pump();
      expect(session.since(mark), isEmpty);
    });
  });

  group('the extra-keys bar', () {
    Future<FakeRemoteScreenSession> open(WidgetTester tester) async {
      FakePlatform(tester);
      // Wide, so the whole row is built: it scrolls, and only builds what
      // is near the screen.
      tester.view
        ..physicalSize = const Size(5400, 2700)
        ..devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      return openDesktop(tester, FakeOpener());
    }

    testWidgets('is there on a touch device, and not on a desktop', (
      tester,
    ) async {
      await open(tester);
      expect(find.text('Ctrl+Alt+Del'), findsOneWidget);
    });

    testWidgets('a desktop can toggle it on and off', (tester) async {
      FakePlatform(tester);
      await openDesktop(tester, FakeOpener(), platform: TargetPlatform.linux);
      expect(find.text('Esc'), findsNothing);
      await tester.tap(find.byTooltip('Show extra keys'));
      await tester.pump();
      expect(find.text('Esc'), findsOneWidget);
      await tester.tap(find.byTooltip('Hide extra keys'));
      await tester.pump();
      expect(find.text('Esc'), findsNothing);
    });

    testWidgets('Esc and Tab are pressed and released', (tester) async {
      final session = await open(tester);
      final mark = session.log.length;
      await tester.tap(find.text('Esc'));
      await tester.tap(find.text('Tab'));
      await tester.pump();
      expect(session.since(mark), [
        'key ${CsrdEvdev.keyEsc} down',
        'key ${CsrdEvdev.keyEsc} up',
        'key ${CsrdEvdev.keyTab} down',
        'key ${CsrdEvdev.keyTab} up',
      ]);
    });

    testWidgets('a modifier waits for the next key and is used up by it', (
      tester,
    ) async {
      final session = await open(tester);
      final mark = session.log.length;
      await tester.tap(find.text('Ctrl'));
      await tester.tap(find.text('Alt'));
      await tester.pump();
      // Nothing is sent just for arming them.
      expect(session.since(mark), isEmpty);
      await tester.tap(find.text('Esc'));
      await tester.pump();
      expect(session.since(mark), [
        'key ${CsrdEvdev.keyLeftCtrl} down',
        'key ${CsrdEvdev.keyLeftAlt} down',
        'key ${CsrdEvdev.keyEsc} down',
        'key ${CsrdEvdev.keyEsc} up',
        'key ${CsrdEvdev.keyLeftAlt} up',
        'key ${CsrdEvdev.keyLeftCtrl} up',
      ]);
      // And the next key goes alone.
      final after = session.log.length;
      await tester.tap(find.text('Tab'));
      await tester.pump();
      expect(session.since(after), [
        'key ${CsrdEvdev.keyTab} down',
        'key ${CsrdEvdev.keyTab} up',
      ]);
    });

    testWidgets('tapping an armed modifier disarms it', (tester) async {
      final session = await open(tester);
      await tester.tap(find.text('Shift'));
      await tester.pump();
      await tester.tap(find.text('Shift'));
      await tester.pump();
      final mark = session.log.length;
      await tester.tap(find.text('Esc'));
      await tester.pump();
      expect(session.since(mark), [
        'key ${CsrdEvdev.keyEsc} down',
        'key ${CsrdEvdev.keyEsc} up',
      ]);
    });

    testWidgets('Super is the Meta key', (tester) async {
      final session = await open(tester);
      await tester.tap(find.text('Super'));
      await tester.tap(find.text('Tab'));
      await tester.pump();
      expect(
        session.log,
        containsAllInOrder([
          'key ${CsrdEvdev.keyLeftMeta} down',
          'key ${CsrdEvdev.keyTab} down',
        ]),
      );
    });

    testWidgets('Ctrl+Alt+Del is one press', (tester) async {
      final session = await open(tester);
      final mark = session.log.length;
      await tester.tap(find.text('Ctrl+Alt+Del'));
      await tester.pump();
      expect(session.since(mark), [
        'key ${CsrdEvdev.keyLeftCtrl} down',
        'key ${CsrdEvdev.keyLeftAlt} down',
        'key ${CsrdEvdev.keyDelete} down',
        'key ${CsrdEvdev.keyDelete} up',
        'key ${CsrdEvdev.keyLeftAlt} up',
        'key ${CsrdEvdev.keyLeftCtrl} up',
      ]);
    });

    testWidgets('F1 to F12 are in a menu', (tester) async {
      final session = await open(tester);
      await tester.tap(find.text('F1–12'));
      await tester.pumpAndSettle();
      for (var i = 1; i <= 12; i++) {
        expect(find.text('F$i'), findsOneWidget);
      }
      final mark = session.log.length;
      await tester.tap(find.text('F5'));
      await tester.pumpAndSettle();
      expect(session.since(mark), [
        'key ${CsrdEvdev.keyF5} down',
        'key ${CsrdEvdev.keyF5} up',
      ]);
    });

    testWidgets('an arrow held down stays down until let go', (tester) async {
      final session = await open(tester);
      final mark = session.log.length;
      final finger = await tester.startGesture(
        tester.getCenter(find.text('▲\uFE0E')),
      );
      await tester.pump(const Duration(milliseconds: 700));
      expect(session.since(mark), ['key ${CsrdEvdev.keyUp} down']);
      await tester.pump(const Duration(seconds: 1));
      expect(session.since(mark), ['key ${CsrdEvdev.keyUp} down']);
      await finger.up();
      await tester.pump();
      expect(session.since(mark), [
        'key ${CsrdEvdev.keyUp} down',
        'key ${CsrdEvdev.keyUp} up',
      ]);
    });

    testWidgets('a tap on an arrow is a press and a release', (tester) async {
      final session = await open(tester);
      final mark = session.log.length;
      await tester.tap(find.text('◀\uFE0E'));
      await tester.pump();
      expect(session.since(mark), [
        'key ${CsrdEvdev.keyLeft} down',
        'key ${CsrdEvdev.keyLeft} up',
      ]);
    });

    testWidgets('nothing is sent in view-only mode', (tester) async {
      final session = await open(tester);
      await tester.tap(find.byTooltip('View only (send no input)'));
      await tester.pump();
      final mark = session.log.length;
      await tester.tap(find.text('Esc'));
      await tester.tap(find.text('Ctrl+Alt+Del'));
      await tester.pump();
      expect(session.since(mark), isEmpty);
    });
  });

  group('hardware keys with the bar\'s modifiers', () {
    testWidgets('an armed Ctrl goes with the next hardware key, once', (
      tester,
    ) async {
      FakePlatform(tester);
      final session = await openDesktop(
        tester,
        FakeOpener(),
        platform: TargetPlatform.linux,
      );
      await tester.tap(find.byTooltip('Show extra keys'));
      await tester.pump();
      await tester.tap(find.text('Ctrl'));
      await tester.pump();
      final mark = session.log.length;
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyC);
      expect(session.since(mark), [
        'key ${CsrdEvdev.keyLeftCtrl} down',
        'key ${CsrdEvdev.keyC} down',
        'key ${CsrdEvdev.keyC} up',
        'key ${CsrdEvdev.keyLeftCtrl} up',
      ]);
      final after = session.log.length;
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      expect(session.since(after), [
        'key ${CsrdEvdev.keyC} down',
        'key ${CsrdEvdev.keyC} up',
      ]);
    });
  });
}

/// The remote pixel under screen point [at]: moves the pointer there and
/// reads the move the session was sent.
Future<(int, int)> _remoteUnder(
  WidgetTester tester,
  FakeRemoteScreenSession session,
  Offset at,
) async {
  final mark = session.log.length;
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: Offset.zero);
  // Park somewhere else first so this is a move even to a repeated spot.
  await mouse.moveTo(viewerRect(tester).topLeft + const Offset(1, 1));
  await mouse.moveTo(at);
  await tester.pump(const Duration(milliseconds: 30));
  await mouse.removePointer();
  final moves = [
    for (final l in session.since(mark))
      if (l.startsWith('move ')) l,
  ];
  final xy = moves.last.substring(5).split(',').map(int.parse).toList();
  return (xy[0], xy[1]);
}

/// The last pointer move the session was sent.
(int, int) _lastMove(FakeRemoteScreenSession session) {
  final move = session.log.lastWhere((l) => l.startsWith('move '));
  final xy = move.substring(5).split(',').map(int.parse).toList();
  return (xy[0], xy[1]);
}
