import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/screens/remote_desktop_screen.dart';
import 'package:secure_shell_go/services/remote_desktop/csrd_client.dart';
import 'package:secure_shell_go/services/remote_desktop/csrd_messages.dart';
import 'package:secure_shell_go/services/remote_desktop/csrd_tiles.dart';
import 'package:secure_shell_go/services/remote_desktop/remote_screen_session.dart';
import 'package:secure_shell_go/theme.dart';

/// A [RemoteScreenSession] that does nothing but write down what it was
/// asked, as short strings, so a test reads like the wire: `move 10,20`,
/// `button 1 down`, `key 30 down`, `scroll 0,120`, `releaseAll`.
///
/// It does not drop input in view-only mode, as the real client does: what
/// is under test is that the screen itself sends nothing then.
class FakeRemoteScreenSession implements RemoteScreenSession {
  FakeRemoteScreenSession({
    this.displays = const [
      CsrdDisplayInfo(
        index: 0,
        name: 'Main',
        x: 0,
        y: 0,
        width: 1600,
        height: 900,
        primary: true,
      ),
    ],
    this.supportsQuality = true,
    this.viewOnlyLocked = false,
    this._viewOnly = false,
    this.rtt,
  }) : display = displays.isEmpty ? null : displays.first.index;

  final log = <String>[];
  final _events = StreamController<CsrdEvent>.broadcast();
  final _done = Completer<CsrdCloseReason>();
  var _state = CsrdClientState.connected;
  bool _viewOnly;

  /// The order of `close` and the opener's release, across a test.
  int closeCalls = 0;

  @override
  List<CsrdDisplayInfo> displays;
  @override
  int? display;
  @override
  CsrdQuality quality = CsrdQuality.balanced;
  @override
  final bool supportsQuality;
  @override
  final bool viewOnlyLocked;
  @override
  Duration? rtt;

  @override
  Stream<CsrdEvent> get events => _events.stream;
  @override
  CsrdClientState get state => _state;
  @override
  Future<CsrdCloseReason> get done => _done.future;

  @override
  bool get viewOnly => _viewOnly;
  @override
  set viewOnly(bool value) {
    log.add('viewOnly $value');
    _viewOnly = value;
  }

  /// Delivers [event] to whoever listens, as the client would.
  void emit(CsrdEvent event) => _events.add(event);

  /// Delivers a frame, a solid colour of the given size.
  void showFrame({
    int seq = 1,
    int width = 800,
    int height = 600,
    int wireBytes = 1000,
  }) {
    emit(
      CsrdFrameEvent(
        CsrdDecodedFrame(
          seq: seq,
          width: width,
          height: height,
          tiles: [CsrdFillTile(0, 0, width, height, 0xff204060)],
          wireBytes: wireBytes,
        ),
      ),
    );
  }

  /// The session ends by itself, as when the remote hangs up.
  void endBy(CsrdCloseReason reason) {
    if (_state == CsrdClientState.closed) return;
    _state = CsrdClientState.closed;
    _events.add(CsrdClosedEvent(reason));
    _events.close();
    _done.complete(reason);
  }

  final acked = <int>[];

  @override
  void selectDisplay(int display, {CsrdQuality? quality, int? maxFps}) {
    log.add('select $display${quality == null ? '' : ' ${quality.name}'}');
    this.display = display;
    if (quality != null) this.quality = quality;
  }

  @override
  void ackFrame(int seq) => acked.add(seq);

  @override
  void pointerMove(int x, int y) => log.add('move $x,$y');

  @override
  void pointerButton(int button, {required bool down}) =>
      log.add('button $button ${down ? 'down' : 'up'}');

  @override
  void scroll(int dx, int dy) => log.add('scroll $dx,$dy');

  @override
  void key(int evdevCode, {required bool down}) =>
      log.add('key $evdevCode ${down ? 'down' : 'up'}');

  @override
  void releaseAll() => log.add('releaseAll');

  @override
  void sendClipboard(String text) => log.add('clipboard $text');

  @override
  Future<CsrdCloseReason> close({String? error}) async {
    closeCalls++;
    log.add('close');
    const reason = CsrdCloseReason.local();
    endBy(reason);
    return reason;
  }

  /// What was sent to the remote since [mark], without the bookkeeping.
  List<String> since(int mark) => log.sublist(mark);
}

/// An opener whose outcome the test decides, and which writes down what the
/// screen does to what it opened.
class FakeOpener {
  FakeOpener({this.progress = const [], this.keepsRunning = false});

  /// Statuses reported on the way, before connecting.
  final List<String> progress;
  final bool keepsRunning;

  final sessions = <FakeRemoteScreenSession>[];

  /// Each call to the opener, in order, as a log with `release`s.
  final events = <String>[];
  var calls = 0;

  /// Outcomes for the next calls, front first. An [Exception] is thrown, a
  /// [Completer] is waited on and then the open succeeds, anything else
  /// (including an empty list) succeeds at once.
  final outcomes = <Object>[];

  /// What the next session is made like.
  FakeRemoteScreenSession Function() makeSession = FakeRemoteScreenSession.new;

  Future<RemoteScreenHandle> call({
    required RemoteScreenProgress progress,
    required void Function(RemoteScreenSession session) attach,
  }) async {
    calls++;
    events.add('open');
    final outcome = outcomes.isEmpty ? null : outcomes.removeAt(0);
    for (final status in this.progress) {
      progress(status);
    }
    if (outcome is Exception) throw outcome;
    final session = makeSession();
    sessions.add(session);
    attach(session);
    if (outcome is Completer<void>) await outcome.future;
    final n = sessions.length;
    return RemoteScreenHandle(
      session: session,
      keepsRunning: keepsRunning,
      title: keepsRunning ? 'Virtual desktop :3' : null,
      release: () async {
        // How many `close`s the session had been given when this was
        // released: the screen closes first, then releases.
        events.add('release $n after-close=${session.closeCalls}');
      },
    );
  }

  int get releases => events.where((e) => e.startsWith('release')).length;
}

/// Installs handlers for the platform calls the screen makes, and records
/// them. Haptics are swallowed; the clipboard is a variable.
class FakePlatform {
  FakePlatform(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        switch (call.method) {
          case 'Clipboard.setData':
            clipboard = (call.arguments as Map)['text'] as String?;
            return null;
          case 'Clipboard.getData':
            return clipboard == null
                ? null
                : <String, dynamic>{'text': clipboard};
          case 'SystemChrome.setEnabledSystemUIMode':
            uiModes.add(call.arguments as String);
            return null;
          case 'HapticFeedback.vibrate':
            haptics++;
            return null;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
  }

  String? clipboard;
  final uiModes = <String>[];
  var haptics = 0;
}

/// A host page with a button that opens the remote desktop, the way the
/// lead's entry point does, so the route can be popped.
Future<void> pumpHost(
  WidgetTester tester,
  FakeOpener opener, {
  TargetPlatform platform = TargetPlatform.android,
  String hostName = 'build-box',
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.dark.copyWith(platform: platform),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => openRemoteDesktop(
                context,
                hostName: hostName,
                opener: opener.call,
              ),
              child: const Text('Open desktop'),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Opens the screen from [pumpHost] and waits for the opener to finish.
Future<FakeRemoteScreenSession> openDesktop(
  WidgetTester tester,
  FakeOpener opener, {
  TargetPlatform platform = TargetPlatform.android,
  bool frame = true,
  int width = 800,
  int height = 600,
}) async {
  await pumpHost(tester, opener, platform: platform);
  await tester.tap(find.text('Open desktop'));
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  final session = opener.sessions.last;
  if (frame) {
    session.showFrame(width: width, height: height);
    await settleFrames(tester);
  }
  return session;
}

/// Lets frames be composited and presented: microtasks, then a frame.
Future<void> settleFrames(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

/// The viewer's rectangle on screen.
Rect viewerRect(WidgetTester tester) =>
    tester.getRect(find.byKey(const ValueKey('remote-viewer')));

/// Where, on the viewer, the middle of remote pixel ([x], [y]) is when the
/// screen of [width] × [height] is fitted, as `RemoteViewport` places it: the
/// biggest scale that fits, centred. The middle, so that rounding either way
/// still lands in the same pixel.
Offset viewerPoint(
  WidgetTester tester,
  double x,
  double y, {
  int width = 800,
  int height = 600,
}) {
  final r = viewerRect(tester);
  final scale = [
    r.width / width,
    r.height / height,
  ].reduce((a, b) => a < b ? a : b);
  return Offset(
    r.center.dx + (x + 0.5 - width / 2) * scale,
    r.center.dy + (y + 0.5 - height / 2) * scale,
  );
}

CsrdCursorShape cursorShape({
  int width = 2,
  int height = 2,
  int hotX = 0,
  int hotY = 0,
  List<int>? rgba,
}) => CsrdCursorShape(
  width: width,
  height: height,
  hotX: hotX,
  hotY: hotY,
  rgba: Uint8List.fromList(rgba ?? List.filled(width * height * 4, 255)),
);

/// Lets the route finish going and the cleanup that follows it finish too.
Future<void> settleRoute(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// The back button, then enough time for the route to be gone.
Future<void> leaveScreen(WidgetTester tester) async {
  await tester.pageBack();
  await settleRoute(tester);
}
