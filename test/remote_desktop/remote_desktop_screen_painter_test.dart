import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/remote_desktop/csrd_tiles.dart';
import 'package:secure_shell_go/services/remote_desktop/remote_input_view.dart';
import 'package:secure_shell_go/widgets/remote_desktop/frame_compositor.dart';
import 'package:secure_shell_go/widgets/remote_desktop/remote_cursor.dart';
import 'package:secure_shell_go/widgets/remote_desktop/remote_screen_painter.dart';

import 'remote_desktop_screen_support.dart';

const _background = Color(0xff123456);

class _Drawn {
  _Drawn(this.source, this.destination, this.quality);
  final Rect source;
  final Rect destination;
  final FilterQuality quality;
}

/// What painting once puts on the canvas: the background fill, and every
/// image drawn, in order.
({int? background, List<_Drawn> images}) _paint(
  RemoteScreenPainter painter,
  Size size,
) {
  final canvas = TestRecordingCanvas();
  painter.paint(canvas, size);
  int? background;
  final images = <_Drawn>[];
  for (final call in canvas.invocations) {
    final name = call.invocation.memberName;
    final args = call.invocation.positionalArguments;
    if (name == #drawRect && background == null) {
      background = (args[1] as Paint).color.toARGB32();
    } else if (name == #drawImageRect) {
      images.add(
        _Drawn(
          args[1] as Rect,
          args[2] as Rect,
          (args[3] as Paint).filterQuality,
        ),
      );
    }
  }
  return (background: background, images: images);
}

Future<FrameCompositor> _compositorWithFrame(
  WidgetTester tester,
  int width,
  int height,
) async {
  final compositor = FrameCompositor(presentation: () async {});
  addTearDown(compositor.dispose);
  await tester.runAsync(
    () => compositor.apply(
      CsrdDecodedFrame(
        seq: 1,
        width: width,
        height: height,
        tiles: [CsrdFillTile(0, 0, width, height, 0xff204060)],
        wireBytes: 1,
      ),
    ),
  );
  return compositor;
}

RemoteScreenPainter _painter({
  required FrameCompositor compositor,
  required RemoteViewport viewport,
  RemoteCursor? cursor,
  double dpr = 1,
}) => RemoteScreenPainter(
  compositor: compositor,
  viewport: viewport,
  cursor: cursor ?? RemoteCursor(),
  background: _background,
  devicePixelRatio: dpr,
  repaint: ChangeNotifier(),
);

void main() {
  testWidgets('nothing but the background before the first frame', (
    tester,
  ) async {
    final compositor = FrameCompositor();
    addTearDown(compositor.dispose);
    final painted = _paint(
      _painter(compositor: compositor, viewport: RemoteViewport()),
      const Size(400, 300),
    );
    expect(painted.background, _background.toARGB32());
    expect(painted.images, isEmpty);
  });

  testWidgets('fitted, the screen is scaled into the middle with smooth '
      'resampling', (tester) async {
    final compositor = await _compositorWithFrame(tester, 1920, 1080);
    final viewport = RemoteViewport()
      ..resize(400, 300)
      ..setRemoteSize(1920, 1080);
    final painted = _paint(
      _painter(compositor: compositor, viewport: viewport),
      const Size(400, 300),
    );
    expect(painted.background, _background.toARGB32());
    expect(painted.images, hasLength(1));
    final screen = painted.images.single;
    expect(screen.source, const Rect.fromLTWH(0, 0, 1920, 1080));
    expect(screen.destination.left, closeTo(0, 1e-6));
    expect(screen.destination.top, closeTo(37.5, 1e-6));
    expect(screen.destination.width, closeTo(400, 1e-6));
    expect(screen.destination.height, closeTo(225, 1e-6));
    expect(screen.quality, FilterQuality.medium);
  });

  testWidgets('at one remote pixel to one device pixel there is no '
      'resampling, and the picture sits on the pixel grid', (tester) async {
    final compositor = await _compositorWithFrame(tester, 1000, 800);
    // 3x display: one device pixel is a third of a logical one.
    final viewport = RemoteViewport(devicePixelRatio: 3)
      ..resize(301, 200)
      ..setRemoteSize(1000, 800)
      ..setMode(RemoteViewMode.actual);
    final painted = _paint(
      _painter(compositor: compositor, viewport: viewport, dpr: 3),
      const Size(301, 200),
    );
    final screen = painted.images.single;
    expect(screen.quality, FilterQuality.none);
    expect(screen.destination.width, closeTo(1000 / 3, 1e-6));
    // A whole number of device pixels from the edge.
    final deviceLeft = screen.destination.left * 3;
    final deviceTop = screen.destination.top * 3;
    expect(deviceLeft, closeTo(deviceLeft.roundToDouble(), 1e-6));
    expect(deviceTop, closeTo(deviceTop.roundToDouble(), 1e-6));
  });

  testWidgets('zoomed in, the picture is clipped to the viewer', (
    tester,
  ) async {
    final compositor = await _compositorWithFrame(tester, 800, 600);
    final viewport = RemoteViewport()
      ..resize(400, 300)
      ..setRemoteSize(800, 600)
      ..zoomAt(4, 200, 150);
    final canvas = TestRecordingCanvas();
    _painter(
      compositor: compositor,
      viewport: viewport,
    ).paint(canvas, const Size(400, 300));
    final names = [for (final c in canvas.invocations) c.invocation.memberName];
    expect(names, contains(#clipRect));
    expect(names.indexOf(#clipRect), lessThan(names.indexOf(#drawImageRect)));
    expect(
      names.indexOf(#drawImageRect),
      lessThan(names.lastIndexOf(#restore)),
    );
  });

  group('the cursor', () {
    Future<(FrameCompositor, RemoteCursor)> setup(
      WidgetTester tester,
      int cursorSize,
      int hot,
    ) async {
      final compositor = await _compositorWithFrame(tester, 800, 600);
      final cursor = RemoteCursor();
      addTearDown(cursor.dispose);
      cursor.setShape(
        cursorShape(
          width: cursorSize,
          height: cursorSize,
          hotX: hot,
          hotY: hot,
        ),
      );
      await tester.runAsync(() async {
        for (var i = 0; i < 200 && cursor.image == null; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      });
      cursor.setEchoed(100, 50);
      return (compositor, cursor);
    }

    testWidgets('is drawn so its hot spot is on the pointer, to scale', (
      tester,
    ) async {
      final (compositor, cursor) = await setup(tester, 20, 4);
      // 1:1 on a 1x display, so the scale is exactly 1.
      final viewport = RemoteViewport()
        ..resize(800, 600)
        ..setRemoteSize(800, 600);
      final painted = _paint(
        _painter(compositor: compositor, viewport: viewport, cursor: cursor),
        const Size(800, 600),
      );
      expect(painted.images, hasLength(2));
      final c = painted.images.last;
      expect(c.destination.width, 20);
      // Tip at (100, 50): the picture starts hot spot (4, 4) up and left.
      expect(c.destination.left, closeTo(96, 1e-6));
      expect(c.destination.top, closeTo(46, 1e-6));
      expect(c.quality, FilterQuality.none);
    });

    testWidgets('is not shrunk to a speck when the screen is', (tester) async {
      final (compositor, cursor) = await setup(tester, 20, 0);
      // 800 × 600 into 200 × 150: a quarter. The cursor keeps 0.7.
      final viewport = RemoteViewport()
        ..resize(200, 150)
        ..setRemoteSize(800, 600);
      final painted = _paint(
        _painter(compositor: compositor, viewport: viewport, cursor: cursor),
        const Size(200, 150),
      );
      final c = painted.images.last;
      expect(c.destination.width, closeTo(20 * remoteCursorMinScale, 1e-6));
      // Its tip is still where the pointer is: 100 × 0.25, 50 × 0.25.
      expect(c.destination.left, closeTo(25, 1e-6));
      expect(c.destination.top, closeTo(12.5, 1e-6));
    });

    testWidgets('follows the zoom when that makes it bigger', (tester) async {
      final (compositor, cursor) = await setup(tester, 20, 0);
      final viewport = RemoteViewport()
        ..resize(800, 600)
        ..setRemoteSize(800, 600)
        ..zoomAt(2, 0, 0);
      final painted = _paint(
        _painter(compositor: compositor, viewport: viewport, cursor: cursor),
        const Size(800, 600),
      );
      expect(painted.images.last.destination.width, closeTo(40, 1e-6));
    });

    testWidgets('is not drawn before the agent has said where it is', (
      tester,
    ) async {
      final compositor = await _compositorWithFrame(tester, 800, 600);
      final cursor = RemoteCursor();
      addTearDown(cursor.dispose);
      cursor.setShape(cursorShape(width: 8, height: 8));
      await tester.runAsync(() async {
        for (var i = 0; i < 200 && cursor.image == null; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      });
      final viewport = RemoteViewport()
        ..resize(800, 600)
        ..setRemoteSize(800, 600);
      final painted = _paint(
        _painter(compositor: compositor, viewport: viewport, cursor: cursor),
        const Size(800, 600),
      );
      expect(painted.images, hasLength(1));
    });
  });

  testWidgets('repaints on a frame, the cursor and the signal, and when '
      'its inputs change', (tester) async {
    final compositor = FrameCompositor();
    addTearDown(compositor.dispose);
    final viewport = RemoteViewport();
    final cursor = RemoteCursor();
    addTearDown(cursor.dispose);
    final a = _painter(
      compositor: compositor,
      viewport: viewport,
      cursor: cursor,
    );
    final b = _painter(
      compositor: compositor,
      viewport: viewport,
      cursor: cursor,
    );
    expect(a.shouldRepaint(b), isFalse);
    final c = RemoteScreenPainter(
      compositor: compositor,
      viewport: viewport,
      cursor: cursor,
      background: const Color(0xff000000),
      devicePixelRatio: 1,
      repaint: ChangeNotifier(),
    );
    expect(a.shouldRepaint(c), isTrue);
  });
}
