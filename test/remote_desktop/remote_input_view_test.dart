import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/remote_desktop/remote_input_view.dart';

/// 1920 × 1080 in a 400 × 300 viewer: scale 0.2083, so the picture is 400
/// wide and 225 tall, with 37.5 of letterbox above and below.
RemoteViewport fitted({double dpr = 1}) => RemoteViewport(devicePixelRatio: dpr)
  ..resize(400, 300)
  ..setRemoteSize(1920, 1080);

void main() {
  group('fit', () {
    test('scales the screen to the viewer and centres it', () {
      final v = fitted();
      expect(v.scale, closeTo(400 / 1920, 1e-9));
      final r = v.imageRect;
      expect(r.left, closeTo(0, 1e-9));
      expect(r.top, closeTo(37.5, 1e-9));
      expect(r.width, closeTo(400, 1e-9));
      expect(r.height, closeTo(225, 1e-9));
      expect(v.canPan, isFalse);
    });

    test('maps the middle, the corners and the letterbox', () {
      final v = fitted();
      expect(v.remoteFromView(200, 150), (960, 540));
      expect(v.remoteFromView(0, 37.5), (0, 0));
      expect(v.remoteFromView(399.99, 262.4), (1919, 1079));
      // In the bars above and below: outside.
      expect(v.remoteFromView(200, 37.49), isNull);
      expect(v.remoteFromView(200, 10), isNull);
      expect(v.remoteFromView(200, 262.5), isNull);
      expect(v.remoteFromView(200, 290), isNull);
      // Beside the viewer, and exactly on the far edge, which is the first
      // pixel past the screen.
      expect(v.remoteFromView(-0.01, 150), isNull);
      expect(v.remoteFromView(400, 150), isNull);
    });

    test('clamping moves an outside point to the nearest pixel', () {
      final v = fitted();
      expect(v.remoteFromView(200, 0, clamp: true), (960, 0));
      expect(v.remoteFromView(200, 299, clamp: true), (960, 1079));
      expect(v.remoteFromView(-50, 150, clamp: true), (0, 540));
      expect(v.remoteFromView(500, 400, clamp: true), (1919, 1079));
    });

    test('a tall screen is letterboxed at the sides', () {
      final v = RemoteViewport()
        ..resize(400, 300)
        ..setRemoteSize(600, 1200);
      // Scale 0.25: 150 × 300, centred with 125 either side.
      expect(v.scale, 0.25);
      expect(v.imageRect.left, closeTo(125, 1e-9));
      expect(v.remoteFromView(100, 150), isNull);
      expect(v.remoteFromView(125, 150), (0, 600));
      expect(v.remoteFromView(274.9, 150), (599, 600));
      expect(v.remoteFromView(275, 150), isNull);
    });

    test('nothing maps before the viewer and the remote have sizes', () {
      expect(RemoteViewport().remoteFromView(1, 1), isNull);
      final v = RemoteViewport()..resize(400, 300);
      expect(v.isReady, isFalse);
      expect(v.remoteFromView(1, 1), isNull);
    });

    test('the view and the remote map back and forth', () {
      final v = fitted();
      final (x, y) = v.viewFromRemote(960, 540);
      expect(x, closeTo(200, 1e-9));
      expect(y, closeTo(150, 1e-9));
      expect(v.remoteExactFromView(x, y).$1, closeTo(960, 1e-9));
    });
  });

  group('zoom', () {
    test('keeps the point under the pinch where it is', () {
      final v = fitted();
      // Pinch at the top-left corner of the picture. Four times as tall as
      // the viewer would leave a gap above it, so the picture is held to the
      // viewer's top, and that corner is what shows there.
      v.zoomAt(4, 0, 37.5);
      expect(v.scale, closeTo(4 * 400 / 1920, 1e-9));
      expect(v.remoteFromView(0, 0), (0, 0));
      expect(v.canPan, isTrue);
      // A point in the middle of the picture stays under the fingers.
      final v2 = fitted();
      final before = v2.remoteExactFromView(300, 200);
      v2.zoomAt(2, 300, 200);
      final after = v2.remoteExactFromView(300, 200);
      expect(after.$1, closeTo(before.$1, 1e-6));
      expect(after.$2, closeTo(before.$2, 1e-6));
    });

    test('cannot go below fit or past 8 device pixels per remote pixel', () {
      final v = fitted(dpr: 2);
      v.zoomAt(0.1, 200, 150);
      expect(v.scale, closeTo(v.fitScale, 1e-9));
      v.zoomAt(1000, 200, 150);
      expect(v.scale, closeTo(8 / 2, 1e-9));
    });

    test('ignores nonsense factors', () {
      final v = fitted();
      v.zoomAt(0, 100, 100);
      v.zoomAt(-2, 100, 100);
      v.zoomAt(double.nan, 100, 100);
      v.zoomAt(double.infinity, 100, 100);
      expect(v.scale, closeTo(v.fitScale, 1e-9));
    });

    test('panning stops at the picture\'s edges', () {
      final v = fitted()..zoomAt(4, 200, 150);
      v.panBy(1e6, 1e6);
      var r = v.imageRect;
      expect(r.left, closeTo(0, 1e-6));
      expect(r.top, closeTo(0, 1e-6));
      v.panBy(-1e6, -1e6);
      r = v.imageRect;
      expect(r.left + r.width, closeTo(400, 1e-6));
      expect(r.top + r.height, closeTo(300, 1e-6));
    });

    test('zooming back out recentres the picture', () {
      final v = fitted()..zoomAt(4, 0, 37.5);
      v.zoomAt(0.25, 0, 37.5);
      expect(v.scale, closeTo(v.fitScale, 1e-9));
      expect(v.imageRect.top, closeTo(37.5, 1e-6));
    });

    test('mapping at the zoomed edges still lands inside the screen', () {
      final v = fitted()..zoomAt(4, 200, 150);
      v.panBy(1e6, 1e6);
      expect(v.remoteFromView(0, 0), (0, 0));
      v.panBy(-1e6, -1e6);
      expect(v.remoteFromView(399.9, 299.9), (1919, 1079));
    });
  });

  group('actual size', () {
    test('is one remote pixel per device pixel', () {
      final v = fitted(dpr: 2)..setMode(RemoteViewMode.actual);
      expect(v.scale, 0.5);
      expect(v.canPan, isTrue);
      expect(v.mode, RemoteViewMode.actual);
      // Centred on the middle of the screen.
      expect(v.remoteFromView(200, 150), (960, 540));
    });

    test('can start on a given remote point', () {
      final v = fitted(dpr: 1)
        ..setMode(RemoteViewMode.actual, focusX: 100, focusY: 100);
      // Clamped so the picture does not leave the viewer: the top-left
      // 400 × 300 of the screen shows.
      expect(v.remoteFromView(0, 0), (0, 0));
      expect(v.remoteFromView(399, 299), (399, 299));
      v.setMode(RemoteViewMode.actual, focusX: 1000, focusY: 500);
      expect(v.remoteFromView(200, 150), (1000, 500));
    });

    test('a screen smaller than the viewer is centred, and not shrunk', () {
      final v = RemoteViewport()
        ..resize(400, 300)
        ..setRemoteSize(200, 100)
        ..setMode(RemoteViewMode.actual);
      expect(v.scale, 1);
      expect(v.imageRect.left, 100);
      expect(v.imageRect.top, 100);
      expect(v.canPan, isFalse);
      expect(v.remoteFromView(99, 150), isNull);
      expect(v.remoteFromView(100, 100), (0, 0));
    });

    test('can be zoomed out as far as fit', () {
      final v = fitted(dpr: 1)..setMode(RemoteViewMode.actual);
      v.zoomAt(0.01, 200, 150);
      expect(v.scale, closeTo(v.fitScale, 1e-9));
    });

    test('going back to fit undoes the zoom', () {
      final v = fitted()
        ..zoomAt(5, 10, 50)
        ..setMode(RemoteViewMode.fit);
      expect(v.scale, closeTo(v.fitScale, 1e-9));
      expect(v.imageRect.left, closeTo(0, 1e-9));
    });
  });

  group('the viewer and the remote change size', () {
    test('resizing keeps the middle of what is showing', () {
      final v = fitted()..zoomAt(4, 200, 150);
      v.panBy(-300, -100);
      final middle = v.remoteExactFromView(200, 150);
      v.resize(600, 300);
      final after = v.remoteExactFromView(300, 150);
      expect(after.$1, closeTo(middle.$1, 1e-6));
      expect(after.$2, closeTo(middle.$2, 1e-6));
    });

    test('a new remote size starts the view again', () {
      final v = fitted()..zoomAt(4, 0, 37.5);
      v.setRemoteSize(1280, 720);
      expect(v.scale, closeTo(400 / 1280, 1e-9));
      expect(v.remoteFromView(200, 150), (640, 360));
    });

    test('the same size again changes nothing', () {
      final v = fitted()..zoomAt(4, 0, 37.5);
      final scale = v.scale;
      v.setRemoteSize(1920, 1080);
      expect(v.scale, scale);
    });
  });

  group('ensureVisible', () {
    test('pans just far enough to bring a point in with its margin', () {
      final v = fitted()..zoomAt(4, 0, 37.5);
      // The top left is showing; the point 1000 px along is not.
      final (vx, _) = v.viewFromRemote(1000, 100);
      expect(vx, greaterThan(400));
      v.ensureVisible(1000, 100, margin: 24);
      final (nx, ny) = v.viewFromRemote(1000, 100);
      expect(nx, closeTo(400 - 24, 1e-6));
      expect(ny, inInclusiveRange(24, 276));
    });

    test('leaves a visible point alone', () {
      final v = fitted()..zoomAt(4, 0, 37.5);
      final before = v.imageRect;
      v.ensureVisible(50, 50, margin: 24);
      expect(v.imageRect, before);
    });
  });
}
