import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/layout_breakpoints.dart';

void main() {
  group('WindowSizeClass.forWidth', () {
    test('a small phone is compact', () {
      expect(WindowSizeClass.forWidth(320), WindowSizeClass.compact);
    });

    test('just under the medium breakpoint is still compact', () {
      expect(WindowSizeClass.forWidth(599.9), WindowSizeClass.compact);
    });

    test('the medium breakpoint itself is medium', () {
      expect(WindowSizeClass.forWidth(600), WindowSizeClass.medium);
    });

    test('a tablet-ish width in between is medium', () {
      expect(WindowSizeClass.forWidth(720), WindowSizeClass.medium);
    });

    test('just under the expanded breakpoint is still medium', () {
      expect(WindowSizeClass.forWidth(839.9), WindowSizeClass.medium);
    });

    test('the expanded breakpoint itself is expanded', () {
      expect(WindowSizeClass.forWidth(840), WindowSizeClass.expanded);
    });

    test('a DeX-shaped window is expanded', () {
      expect(WindowSizeClass.forWidth(1280), WindowSizeClass.expanded);
    });
  });

  group('isCompact / isAtLeastMedium', () {
    test('compact is compact and not at-least-medium', () {
      expect(WindowSizeClass.compact.isCompact, isTrue);
      expect(WindowSizeClass.compact.isAtLeastMedium, isFalse);
    });

    test('medium is at-least-medium and not compact', () {
      expect(WindowSizeClass.medium.isCompact, isFalse);
      expect(WindowSizeClass.medium.isAtLeastMedium, isTrue);
    });

    test('expanded is at-least-medium and not compact', () {
      expect(WindowSizeClass.expanded.isCompact, isFalse);
      expect(WindowSizeClass.expanded.isAtLeastMedium, isTrue);
    });
  });
}
