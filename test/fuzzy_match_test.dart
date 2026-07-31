import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/fuzzy_match.dart';

void main() {
  group('FuzzyMatch.match', () {
    test('matches a subsequence that is not contiguous', () {
      expect(FuzzyMatch.match('ngx', 'nginx-server'), isNotNull);
    });

    test('returns null when a character is missing entirely', () {
      expect(FuzzyMatch.match('xyz', 'nginx-server'), isNull);
    });

    test('returns null when characters are out of order', () {
      expect(FuzzyMatch.match('oh', 'host'), isNull);
    });

    test('is case-insensitive on both sides', () {
      expect(FuzzyMatch.match('HO', 'host'), isNotNull);
      expect(FuzzyMatch.match('ho', 'HOST'), isNotNull);
    });

    test('an empty query matches anything, at the lowest rank', () {
      final match = FuzzyMatch.match('', 'anything');
      expect(match, isNotNull);
      expect(match!.rank, FuzzyMatchRank.scattered);
    });

    test('a match at position zero ranks as prefix', () {
      expect(FuzzyMatch.match('vi', 'Video call')!.rank, FuzzyMatchRank.prefix);
    });

    test('a match starting right after a space ranks as wordBoundary', () {
      expect(
        FuzzyMatch.match('vi', 'Log viewer')!.rank,
        FuzzyMatchRank.wordBoundary,
      );
    });

    test('a match starting mid-word ranks as scattered', () {
      expect(
        FuzzyMatch.match('vi', 'Live view')!.rank,
        FuzzyMatchRank.scattered,
      );
    });

    test('word-boundary characters include -, _, . and @', () {
      expect(FuzzyMatch.match('ho', 'my-host')!.rank, FuzzyMatchRank.wordBoundary);
      expect(FuzzyMatch.match('ho', 'my_host')!.rank, FuzzyMatchRank.wordBoundary);
      expect(FuzzyMatch.match('ho', 'my.host')!.rank, FuzzyMatchRank.wordBoundary);
      expect(FuzzyMatch.match('ho', 'my@host')!.rank, FuzzyMatchRank.wordBoundary);
    });
  });

  group('fuzzySort', () {
    test('ranks prefix above word-boundary above scattered', () {
      final items = ['Live view', 'Video call', 'Log viewer'];
      final sorted = fuzzySort('vi', items, (s) => s);
      expect(sorted, ['Video call', 'Log viewer', 'Live view']);
    });

    test('drops items that do not match at all', () {
      final items = ['Video call', 'Nothing relevant', 'Log viewer'];
      final sorted = fuzzySort('vi', items, (s) => s);
      expect(sorted, ['Video call', 'Log viewer']);
    });

    test('an empty query returns every item in its original order', () {
      final items = ['charlie', 'alpha', 'bravo'];
      final sorted = fuzzySort('', items, (s) => s);
      expect(sorted, ['charlie', 'alpha', 'bravo']);
    });

    test('a real-world example: "nh" ranks "New host" over "Known hosts"', () {
      final items = ['Known hosts', 'New host'];
      final sorted = fuzzySort('nh', items, (s) => s);
      expect(sorted, ['New host', 'Known hosts']);
    });

    test('a tighter match within the same rank beats a looser one', () {
      // Both are prefix matches for "ab"; "ab-c" packs the two letters
      // together (distance 1) while "a---b" spreads them out (distance 4).
      final items = ['a---b', 'ab-c'];
      final sorted = fuzzySort('ab', items, (s) => s);
      expect(sorted, ['ab-c', 'a---b']);
    });

    test('extracts the search text via the provided selector', () {
      final items = [(name: 'alpha', id: 1), (name: 'video', id: 2)];
      final sorted = fuzzySort('vid', items, (item) => item.name);
      expect(sorted.map((i) => i.id), [2]);
    });
  });
}
