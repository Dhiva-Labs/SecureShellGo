import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/server_probe.dart';

/// The disk bar has to read the same as `df` on the same filesystem, because
/// that is what anyone will check it against. `df`'s capacity column is used
/// over used-plus-available, which leaves out the root reserve — dividing by
/// the total instead treats that reserve as free space and reads low.
void main() {
  // Real `df -Pk /` output from the machine this was caught on:
  // 1K-blocks=372755372 used=262952256 avail=90794404 cap=75%
  const observed = DiskUsage(
    mountPoint: '/',
    total: 372755372 * 1024,
    used: 262952256 * 1024,
    available: 90794404 * 1024,
  );

  test('the disk fraction is the ratio df computes its capacity from', () {
    // df prints 75 for this filesystem: POSIX has it round the capacity
    // column *up*, so 74.33 shows as 75. The bar shares df's definition —
    // the remaining point is that rounding rule, not a different sum.
    expect(observed.usedFraction, closeTo(0.7433, 0.0005));
  });

  test('dividing by the total would have read low, which was the bug', () {
    final byTotal = observed.used / observed.total;
    expect(byTotal, closeTo(0.7054, 0.0005),
        reason: 'fixture no longer reproduces the gap');
    // Four points adrift of df — the gap this test exists to keep closed.
    expect((observed.usedFraction! - byTotal) * 100, greaterThan(3.5));
  });

  test('a filesystem with no reserve is unaffected', () {
    const noReserve = DiskUsage(
      mountPoint: '/mnt',
      total: 1000,
      used: 250,
      available: 750,
    );
    expect(noReserve.usedFraction, 0.25);
  });

  test('a filesystem reporting nothing usable reads as unknown', () {
    const empty = DiskUsage(
      mountPoint: '/proc',
      total: 0,
      used: 0,
      available: 0,
    );
    expect(empty.usedFraction, isNull);
  });

  test('memory keeps dividing by the total, which has no reserve', () {
    const memory = MemoryUsage(total: 1000, available: 750);
    expect(memory.usedFraction, 0.25);
  });
}
