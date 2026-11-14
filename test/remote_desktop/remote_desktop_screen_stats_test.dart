import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/widgets/remote_desktop/remote_stats.dart';

void main() {
  Duration ms(int n) => Duration(milliseconds: n);

  test('counts frames and bytes over the last second', () {
    final m = RemoteStatsMeter();
    for (var i = 0; i < 30; i++) {
      m.addFrame(ms(i * 33), 2048);
    }
    expect(m.fps(ms(990)), 30);
    expect(m.bytesPerSecond(ms(990)), 30 * 2048);
    // The first has aged out a moment later.
    expect(m.fps(ms(1000)), 30 - 1);
  });

  test('an old frame ages out, to the millisecond', () {
    final m = RemoteStatsMeter();
    m.addFrame(ms(0), 1000);
    expect(m.fps(ms(999)), 1);
    expect(m.fps(ms(1000)), 0);
    expect(m.bytesPerSecond(ms(1000)), 0);
  });

  test('silence reads as zero', () {
    final m = RemoteStatsMeter();
    m.addFrame(ms(0), 5000);
    expect(m.fps(const Duration(seconds: 10)), 0);
    expect(m.bytesPerSecond(const Duration(seconds: 10)), 0);
  });

  test('a window of another length scales the rate', () {
    final m = RemoteStatsMeter(window: ms(500));
    m.addFrame(ms(0), 1000);
    m.addFrame(ms(100), 1000);
    // 2000 bytes in half a second.
    expect(m.bytesPerSecond(ms(200)), 4000);
  });

  test('clear forgets everything', () {
    final m = RemoteStatsMeter();
    m.addFrame(ms(0), 100);
    m.clear();
    expect(m.fps(ms(1)), 0);
    expect(m.bytesPerSecond(ms(1)), 0);
  });
}
