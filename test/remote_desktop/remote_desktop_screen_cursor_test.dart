import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/remote_desktop/csrd_client.dart';
import 'package:secure_shell_go/services/remote_desktop/csrd_messages.dart';
import 'package:secure_shell_go/theme.dart';
import 'package:secure_shell_go/widgets/remote_desktop/remote_cursor.dart';

import 'remote_desktop_screen_support.dart';

/// Pixels of [image] as straight RGBA.
Future<Uint8List> straightPixels(ui.Image image) async =>
    (await image.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    ))!.buffer.asUint8List();

/// Waits, on the real event loop, for [cursor] to have a picture.
Future<void> decoded(WidgetTester tester, RemoteCursor cursor) async {
  await tester.runAsync(() async {
    for (var i = 0; i < 200 && cursor.image == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  });
}

void main() {
  group('premultiplyRgba', () {
    test('scales colour by alpha, rounding to nearest', () {
      final out = premultiplyRgba(
        Uint8List.fromList([
          255, 128, 0, 255, //
          255, 128, 0, 128,
          255, 255, 255, 0,
          200, 100, 50, 1,
        ]),
        4,
      );
      expect(out.sublist(0, 4), [255, 128, 0, 255]);
      expect(out.sublist(4, 8), [128, 64, 0, 128]);
      expect(out.sublist(8, 12), [0, 0, 0, 0]);
      expect(out.sublist(12, 16), [1, 0, 0, 1]);
    });

    test('reads only as many pixels as asked', () {
      final out = premultiplyRgba(Uint8List.fromList(List.filled(40, 255)), 2);
      expect(out, hasLength(8));
    });
  });

  group('RemoteCursor', () {
    testWidgets('a shape becomes a picture of the same colours, soft edges '
        'included', (tester) async {
      final cursor = RemoteCursor();
      addTearDown(cursor.dispose);
      cursor.setShape(
        cursorShape(
          width: 2,
          height: 1,
          rgba: [
            255, 0, 0, 255, // opaque red
            0, 128, 255, 128, // half-transparent blue-green
          ],
        ),
      );
      await decoded(tester, cursor);
      final image = cursor.image!;
      expect((image.width, image.height), (2, 1));
      final px = await tester.runAsync(() => straightPixels(image));
      expect(px!.sublist(0, 4), [255, 0, 0, 255]);
      // Straight in, straight out: not darkened by the alpha twice.
      expect((px[4] - 0).abs(), lessThanOrEqualTo(2));
      expect((px[5] - 128).abs(), lessThanOrEqualTo(3));
      expect((px[6] - 255).abs(), lessThanOrEqualTo(3));
      expect(px[7], 128);
    });

    testWidgets('the hot spot is held inside the picture', (tester) async {
      final cursor = RemoteCursor();
      addTearDown(cursor.dispose);
      cursor.setShape(cursorShape(width: 4, height: 3, hotX: 60000, hotY: 9));
      await decoded(tester, cursor);
      expect((cursor.hotX, cursor.hotY), (3, 2));
    });

    testWidgets('an empty shape hides the cursor', (tester) async {
      final cursor = RemoteCursor();
      addTearDown(cursor.dispose);
      cursor.setShape(cursorShape());
      await decoded(tester, cursor);
      expect(cursor.image, isNotNull);
      cursor.setShape(cursorShape(width: 0, height: 0, rgba: []));
      expect(cursor.image, isNull);
    });

    testWidgets('a shape whose bytes do not add up is ignored, as is a '
        'giant one', (tester) async {
      final cursor = RemoteCursor();
      addTearDown(cursor.dispose);
      cursor.setShape(
        CsrdCursorShape(
          width: 4,
          height: 4,
          hotX: 0,
          hotY: 0,
          rgba: Uint8List(10),
        ),
      );
      cursor.setShape(
        CsrdCursorShape(
          width: 40000,
          height: 40000,
          hotX: 0,
          hotY: 0,
          rgba: Uint8List(16),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      expect(cursor.image, isNull);
    });

    testWidgets('a replaced picture is let go of, and a stale decode never '
        'lands', (tester) async {
      final cursor = RemoteCursor();
      addTearDown(cursor.dispose);
      cursor.setShape(cursorShape(width: 3, height: 3, hotX: 1, hotY: 1));
      await decoded(tester, cursor);
      final first = cursor.image!;
      // Two shapes in quick succession: only the second may show.
      cursor.setShape(cursorShape(width: 5, height: 5, hotX: 2, hotY: 2));
      cursor.setShape(cursorShape(width: 7, height: 7, hotX: 3, hotY: 3));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      expect(cursor.image!.width, 7);
      expect((cursor.hotX, cursor.hotY), (3, 3));
      expect(first.debugDisposed, isTrue);
    });

    testWidgets('disposing disposes the picture, and a late decode is '
        'dropped', (tester) async {
      final cursor = RemoteCursor();
      cursor.setShape(cursorShape(width: 3, height: 3));
      await decoded(tester, cursor);
      final image = cursor.image!;
      cursor.setShape(cursorShape(width: 9, height: 9));
      cursor.dispose();
      expect(image.debugDisposed, isTrue);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      expect(tester.takeException(), isNull);
    });

    test('the agent places it until the person is moving it', () {
      final cursor = RemoteCursor();
      addTearDown(cursor.dispose);
      expect(cursor.hasPosition, isFalse);
      cursor.setEchoed(10, 20);
      expect((cursor.x, cursor.y, cursor.hasPosition), (10, 20, true));

      cursor.setLocal(30.5, 40.5);
      expect((cursor.x, cursor.y, cursor.isLocal), (30.5, 40.5, true));
      // The agent's answer to an earlier move arrives late: ignored.
      cursor.setEchoed(11, 21);
      expect((cursor.x, cursor.y), (30.5, 40.5));

      cursor.releaseLocal();
      cursor.setEchoed(11, 21);
      expect((cursor.x, cursor.y), (11, 21));
    });

    test('forgetting the position waits for the agent', () {
      final cursor = RemoteCursor();
      addTearDown(cursor.dispose);
      cursor.setLocal(5, 5);
      cursor.clearPosition();
      expect(cursor.hasPosition, isFalse);
      expect(cursor.isLocal, isFalse);
      cursor.setEchoed(1, 2);
      expect((cursor.x, cursor.y), (1, 2));
    });

    test('listeners hear only about real changes', () {
      final cursor = RemoteCursor();
      addTearDown(cursor.dispose);
      var heard = 0;
      cursor.addListener(() => heard++);
      cursor.setEchoed(1, 1);
      cursor.setEchoed(1, 1);
      cursor.setEchoed(2, 1);
      expect(heard, 2);
    });
  });

  testWidgets('the cursor is drawn on screen over the picture', (tester) async {
    FakePlatform(tester);
    final session = await openDesktop(
      tester,
      FakeOpener(),
      width: 800,
      height: 600,
    );
    // A 6 × 6 pure red cursor whose tip is its top-left corner.
    session.emit(
      CsrdCursorShapeEvent(
        cursorShape(
          width: 6,
          height: 6,
          rgba: List.generate(36 * 4, (i) => const [255, 0, 0, 255][i % 4]),
        ),
      ),
    );
    session.emit(const CsrdCursorPosEvent(400, 300));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    await tester.pump();

    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find
          .descendant(
            of: find.byKey(const ValueKey('remote-viewer')),
            matching: find.byType(RepaintBoundary),
          )
          .first,
    );
    final image = (await tester.runAsync(() => boundary.toImage()))!;
    final px = await tester.runAsync(() => straightPixels(image));
    int at(num x, num y) => (y.toInt() * image.width + x.toInt()) * 4;

    // The viewer is 800 × 492 logical and the screen is fitted into it at
    // 0.82, so the cursor's tip sits at the middle of the viewer.
    final middleX = image.width / 2;
    final middleY = image.height / 2;
    final tip = at(middleX + 3, middleY + 3);
    expect(px![tip], 255);
    expect(px[tip + 1], 0);
    expect(px[tip + 2], 0);
    // Away from the cursor it is the screen's fill: 0x204060.
    final away = at(middleX - 60, middleY);
    expect([px[away], px[away + 1], px[away + 2]], [0x20, 0x40, 0x60]);
    // And the letterbox beside the 4:3 picture is the theme's background,
    // not part of the remote screen.
    final bar = at(4, middleY);
    final background = AppTheme.dark.scaffoldBackgroundColor;
    expect(
      [px[bar], px[bar + 1], px[bar + 2]],
      [
        (background.r * 255).round(),
        (background.g * 255).round(),
        (background.b * 255).round(),
      ],
    );
  });
}
