import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/remote_desktop/csrd_client.dart';
import 'package:secure_shell_go/services/remote_desktop/csrd_keymap.dart';
import 'package:secure_shell_go/services/remote_desktop/csrd_messages.dart';

import 'remote_desktop_screen_support.dart';

const _twoDisplays = [
  CsrdDisplayInfo(
    index: 0,
    name: 'Left',
    x: 0,
    y: 0,
    width: 1920,
    height: 1080,
    primary: true,
  ),
  CsrdDisplayInfo(
    index: 3,
    name: '',
    x: 1920,
    y: 0,
    width: 1280,
    height: 1024,
    primary: false,
  ),
];

void main() {
  group('quality', () {
    testWidgets('is offered when the session supports it, and picks '
        'through selectDisplay', (tester) async {
      FakePlatform(tester);
      final session = await openDesktop(tester, FakeOpener());
      await tester.tap(find.byTooltip('Quality'));
      await tester.pumpAndSettle();
      expect(find.text('Lossless'), findsOneWidget);
      expect(find.text('Balanced'), findsOneWidget);
      expect(find.text('Speed'), findsOneWidget);

      final mark = session.log.length;
      await tester.tap(find.text('Lossless'));
      await tester.pumpAndSettle();
      // The display being shown, with the new quality.
      expect(session.since(mark), ['select 0 lossless']);
      expect(session.quality, CsrdQuality.lossless);
    });

    testWidgets('is hidden when the session has no such knob', (tester) async {
      FakePlatform(tester);
      final opener = FakeOpener()
        ..makeSession = () => FakeRemoteScreenSession(supportsQuality: false);
      await openDesktop(tester, opener);
      expect(find.byTooltip('Quality'), findsNothing);
    });
  });

  group('displays', () {
    testWidgets('one display needs no picker', (tester) async {
      FakePlatform(tester);
      await openDesktop(tester, FakeOpener());
      expect(find.byTooltip('Display'), findsNothing);
    });

    testWidgets('several are listed by name and size, and one is picked', (
      tester,
    ) async {
      FakePlatform(tester);
      final opener = FakeOpener()
        ..makeSession = () => FakeRemoteScreenSession(displays: _twoDisplays);
      final session = await openDesktop(tester, opener);
      await tester.tap(find.byTooltip('Display'));
      await tester.pumpAndSettle();
      expect(find.text('Left (1920×1080)'), findsOneWidget);
      // A display with no name is numbered, from one.
      expect(find.text('Display 4 (1280×1024)'), findsOneWidget);

      final mark = session.log.length;
      await tester.tap(find.text('Display 4 (1280×1024)'));
      await tester.pumpAndSettle();
      // By the agent's index for it, not its place in the list.
      expect(session.since(mark), ['select 3']);
    });

    testWidgets('a second display appearing adds the picker', (tester) async {
      FakePlatform(tester);
      final session = await openDesktop(tester, FakeOpener());
      expect(find.byTooltip('Display'), findsNothing);
      session.displays = _twoDisplays;
      session.emit(CsrdDisplaysEvent(_twoDisplays));
      await tester.pump();
      await tester.pump();
      expect(find.byTooltip('Display'), findsOneWidget);
    });

    testWidgets('switching forgets the pointer position: it follows what '
        'the agent says on the new screen', (tester) async {
      FakePlatform(tester);
      final opener = FakeOpener()
        ..makeSession = () => FakeRemoteScreenSession(displays: _twoDisplays);
      final session = await openDesktop(tester, opener);
      session.emit(const CsrdCursorPosEvent(100, 100));
      await tester.pump();
      await tester.tap(find.byTooltip('Display'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Display 4 (1280×1024)'));
      await tester.pumpAndSettle();
      // A new size of screen: the frame says so.
      session.showFrame(seq: 2, width: 1280, height: 1024);
      await settleFrames(tester);
      session.emit(const CsrdCursorPosEvent(640, 512));
      await tester.pump();
      final mark = session.log.length;
      await tester.tapAt(viewerRect(tester).center);
      await tester.pump();
      expect(session.since(mark).first, 'move 640,512');
    });
  });

  group('the clipboard', () {
    testWidgets('what the remote copies lands on this device, by default', (
      tester,
    ) async {
      final platform = FakePlatform(tester);
      final session = await openDesktop(tester, FakeOpener());
      session.emit(const CsrdClipboardEvent('from the server'));
      await tester.pump();
      expect(platform.clipboard, 'from the server');
    });

    testWidgets('and not once sync is turned off', (tester) async {
      final platform = FakePlatform(tester);
      final session = await openDesktop(tester, FakeOpener());
      await tester.tap(
        find.byTooltip('Clipboard sync (remote to this device)'),
      );
      await tester.pump();
      session.emit(const CsrdClipboardEvent('secret'));
      await tester.pump();
      expect(platform.clipboard, isNull);

      await tester.tap(
        find.byTooltip('Clipboard sync (remote to this device)'),
      );
      await tester.pump();
      session.emit(const CsrdClipboardEvent('fine'));
      await tester.pump();
      expect(platform.clipboard, 'fine');
    });

    testWidgets('Paste to remote sends the text, then Ctrl+V', (tester) async {
      final platform = FakePlatform(tester)..clipboard = 'hello world';
      final session = await openDesktop(tester, FakeOpener());
      final mark = session.log.length;

      await tester.tap(find.byTooltip('Paste to remote'));
      await tester.pump();
      await tester.pump();
      // The text first; the paste waits for the agent to have set it.
      expect(session.since(mark), ['clipboard hello world']);
      await tester.pump(const Duration(milliseconds: 200));
      expect(session.since(mark), [
        'clipboard hello world',
        'key ${CsrdEvdev.keyLeftCtrl} down',
        'key ${CsrdEvdev.keyV} down',
        'key ${CsrdEvdev.keyV} up',
        'key ${CsrdEvdev.keyLeftCtrl} up',
      ]);
      // The local clipboard is left as it was.
      expect(platform.clipboard, 'hello world');
    });

    testWidgets('an empty clipboard says so and sends nothing', (tester) async {
      FakePlatform(tester);
      final session = await openDesktop(tester, FakeOpener());
      final mark = session.log.length;
      await tester.tap(find.byTooltip('Paste to remote'));
      await tester.pump();
      await tester.pump();
      expect(find.text('The clipboard is empty.'), findsOneWidget);
      expect(session.since(mark), isEmpty);
    });

    testWidgets('Paste to remote is off in view-only mode', (tester) async {
      final platform = FakePlatform(tester)..clipboard = 'text';
      final session = await openDesktop(tester, FakeOpener());
      await tester.tap(find.byTooltip('View only (send no input)'));
      await tester.pump();
      final mark = session.log.length;
      await tester.tap(find.byTooltip('Paste to remote'), warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 300));
      expect(session.since(mark), isEmpty);
      expect(platform.clipboard, 'text');
    });

    testWidgets('the snackbar action for untypable text pastes too', (
      tester,
    ) async {
      FakePlatform(tester).clipboard = 'café';
      final session = await openDesktop(tester, FakeOpener());
      await tester.tap(find.byTooltip('Show keyboard'));
      await tester.pump();
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '  é',
          selection: TextSelection.collapsed(offset: 3),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      final mark = session.log.length;
      await tester.tap(find.widgetWithText(SnackBarAction, 'Paste to remote'));
      await tester.pump();
      await tester.pump();
      expect(session.since(mark).first, 'clipboard café');
      // Let the paste's short wait run out.
      await tester.pump(const Duration(milliseconds: 300));
    });
  });

  group('the view', () {
    testWidgets('fit and 1:1 swap, and 1:1 shows less of the screen', (
      tester,
    ) async {
      FakePlatform(tester);
      // Bigger than the 2400 device pixels the test viewer is wide, so that
      // one pixel to one shows only part of it.
      final session = await openDesktop(
        tester,
        FakeOpener(),
        width: 4000,
        height: 2250,
      );
      expect(find.byTooltip('Actual size (1:1)'), findsOneWidget);
      session.emit(const CsrdCursorPosEvent(2000, 1125));
      await tester.pump();

      final mouseAt = viewerRect(tester).topLeft + const Offset(2, 2);
      Future<String> remoteAtCorner() async {
        final mark = session.log.length;
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: viewerRect(tester).center);
        await mouse.moveTo(mouseAt);
        await tester.pump(const Duration(milliseconds: 30));
        await mouse.removePointer();
        return session.since(mark).where((l) => l.startsWith('move')).last;
      }

      // Fitted, the corner of the viewer is near the corner of the screen.
      final fitted = await remoteAtCorner();
      final fx = int.parse(fitted.substring(5).split(',')[0]);
      expect(fx, lessThan(20));

      // The mouse moved the cursor itself; once that has been quiet for a
      // moment the agent's word on where it is counts again, and 1:1 opens
      // on it.
      await tester.pump(const Duration(milliseconds: 400));
      session.emit(const CsrdCursorPosEvent(2000, 1125));
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byTooltip('Actual size (1:1)'));
      await tester.pump();
      expect(find.byTooltip('Fit to window'), findsOneWidget);
      // 1:1 on a 3x display: the corner of the viewer is a long way in,
      // around the middle of the screen (the cursor was in the middle).
      final actual = await remoteAtCorner();
      final ax = int.parse(actual.substring(5).split(',')[0]);
      expect(ax, greaterThan(300));

      await tester.tap(find.byTooltip('Fit to window'));
      await tester.pump();
      expect(find.byTooltip('Actual size (1:1)'), findsOneWidget);
      expect(await remoteAtCorner(), fitted);
    });
  });

  group('focus mode', () {
    testWidgets('hides the title bar and toolbar, and a button brings them '
        'back', (tester) async {
      FakePlatform(tester);
      await openDesktop(tester, FakeOpener());
      expect(find.byType(AppBar), findsOneWidget);
      expect(find.byTooltip('Quality'), findsOneWidget);
      final before = viewerRect(tester);

      await tester.tap(find.byTooltip('Focus mode'));
      await tester.pump();
      expect(find.byType(AppBar), findsNothing);
      expect(find.byTooltip('Quality'), findsNothing);
      // The screen has the whole display.
      expect(viewerRect(tester).height, greaterThan(before.height));

      await tester.tap(find.byTooltip('Show controls'));
      await tester.pump();
      expect(find.byType(AppBar), findsOneWidget);
      expect(find.byTooltip('Quality'), findsOneWidget);
    });

    testWidgets('on Android it also hides the system bars, and restores '
        'them', (tester) async {
      final platform = FakePlatform(tester);
      await openDesktop(tester, FakeOpener());
      await tester.tap(find.byTooltip('Focus mode'));
      await tester.pump();
      expect(platform.uiModes, ['SystemUiMode.immersiveSticky']);
      await tester.tap(find.byTooltip('Show controls'));
      await tester.pump();
      expect(platform.uiModes.last, 'SystemUiMode.edgeToEdge');
    });

    testWidgets('leaving the screen in focus mode restores the system bars', (
      tester,
    ) async {
      final platform = FakePlatform(tester);
      await openDesktop(tester, FakeOpener());
      await tester.tap(find.byTooltip('Focus mode'));
      await tester.pump();
      // Back, which Android gives even with the bars hidden.
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      navigator.pop();
      await settleRoute(tester);
      expect(platform.uiModes.last, 'SystemUiMode.edgeToEdge');
    });

    testWidgets('a desktop leaves the system bars alone', (tester) async {
      final platform = FakePlatform(tester);
      await openDesktop(tester, FakeOpener(), platform: TargetPlatform.linux);
      await tester.tap(find.byTooltip('Focus mode'));
      await tester.pump();
      expect(platform.uiModes, isEmpty);
    });

    testWidgets('holding Esc brings the controls back, and Esc still goes '
        'to the remote', (tester) async {
      FakePlatform(tester);
      final session = await openDesktop(
        tester,
        FakeOpener(),
        platform: TargetPlatform.linux,
      );
      await tester.tap(find.byTooltip('Focus mode'));
      await tester.pump();
      expect(find.byType(AppBar), findsNothing);
      final mark = session.log.length;

      await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(AppBar), findsNothing);
      await tester.pump(const Duration(milliseconds: 800));
      expect(find.byType(AppBar), findsOneWidget);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
      expect(session.since(mark), [
        'key ${CsrdEvdev.keyEsc} down',
        'key ${CsrdEvdev.keyEsc} up',
      ]);
    });

    testWidgets('a tap of Esc does not leave focus mode', (tester) async {
      FakePlatform(tester);
      await openDesktop(tester, FakeOpener(), platform: TargetPlatform.linux);
      await tester.tap(find.byTooltip('Focus mode'));
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(seconds: 2));
      expect(find.byType(AppBar), findsNothing);
    });
  });

  group('notices', () {
    testWidgets('show as a banner that can be dismissed', (tester) async {
      FakePlatform(tester);
      final session = await openDesktop(tester, FakeOpener());
      session.emit(
        const CsrdNoticeEvent(CsrdNoticeLevel.warn, 'Capture is slow'),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('Capture is slow'), findsOneWidget);
      await tester.tap(find.byTooltip('Dismiss'));
      await tester.pump();
      expect(find.text('Capture is slow'), findsNothing);
    });

    testWidgets('an empty one clears the last, and a new one replaces it', (
      tester,
    ) async {
      FakePlatform(tester);
      final session = await openDesktop(tester, FakeOpener());
      session.emit(const CsrdNoticeEvent(CsrdNoticeLevel.info, 'First'));
      await tester.pump();
      await tester.pump();
      session.emit(const CsrdNoticeEvent(CsrdNoticeLevel.error, 'Second'));
      await tester.pump();
      await tester.pump();
      expect(find.text('First'), findsNothing);
      expect(find.text('Second'), findsOneWidget);
      session.emit(const CsrdNoticeEvent(CsrdNoticeLevel.info, ''));
      await tester.pump();
      await tester.pump();
      expect(find.text('Second'), findsNothing);
      expect(find.byTooltip('Dismiss'), findsNothing);
    });

    testWidgets('a notice does not outlive the session it came from', (
      tester,
    ) async {
      FakePlatform(tester);
      final opener = FakeOpener();
      final session = await openDesktop(tester, opener);
      session.emit(const CsrdNoticeEvent(CsrdNoticeLevel.error, 'Gone soon'));
      await tester.pump();
      await tester.pump();
      session.endBy(const CsrdCloseReason.peer());
      await tester.pump();
      await tester.pump();
      await tester.tap(find.text('Reconnect'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Gone soon'), findsNothing);
    });
  });

  group('the view model of the toolbar', () {
    testWidgets('the key bar toggle follows the device: shown on touch, '
        'hidden on a desktop', (tester) async {
      FakePlatform(tester);
      await openDesktop(tester, FakeOpener());
      expect(find.byTooltip('Hide extra keys'), findsOneWidget);
    });

    testWidgets('the touch-mode toggle is only for touch devices', (
      tester,
    ) async {
      FakePlatform(tester);
      await openDesktop(tester, FakeOpener(), platform: TargetPlatform.linux);
      expect(find.byTooltip('Switch to direct touch'), findsNothing);
      expect(find.byTooltip('Switch to trackpad mode'), findsNothing);
    });

    testWidgets('the release-keyboard button is only for keyboards', (
      tester,
    ) async {
      FakePlatform(tester);
      await openDesktop(tester, FakeOpener());
      expect(
        find.byTooltip(
          'Stop sending keys to the remote (click the screen to resume)',
        ),
        findsNothing,
      );
    });

    testWidgets('each toolbar button has a 48 dp target', (tester) async {
      FakePlatform(tester);
      await openDesktop(tester, FakeOpener());
      for (final tip in [
        'View only (send no input)',
        'Paste to remote',
        'Actual size (1:1)',
        'Hide extra keys',
        'Switch to direct touch',
        'Quality',
        'Show keyboard',
      ]) {
        final size = tester.getSize(find.byTooltip(tip));
        expect(size.width, greaterThanOrEqualTo(48), reason: tip);
        expect(size.height, greaterThanOrEqualTo(48), reason: tip);
      }
    });
  });
}
