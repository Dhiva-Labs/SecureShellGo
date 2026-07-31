/// Pure fuzzy-subsequence matching for the command palette.
///
/// A query matches [text] when every (case-folded) character of the query
/// appears in [text] in the same order, not necessarily contiguous — so
/// `ngx` matches `nginx-server`. [FuzzyMatch.rank] then grades *how* it
/// matched, because "matches at all" is a different question from "should
/// this be the top result":
///
///  - [FuzzyMatchRank.prefix] — the query is literally how [text] starts.
///  - [FuzzyMatchRank.wordBoundary] — the match starts right at a word
///    boundary (after a space, `-`, `_`, `.`, `@` or `/`).
///  - [FuzzyMatchRank.scattered] — matched, but not at the front of a word.
///
/// Within the same rank, a tighter match (matched characters closer
/// together) beats one spread thinly across a long string.
///
/// Free of Flutter imports, like the rest of `services/` — `command_palette
/// .dart` is the widget that uses this to order what it shows.
library;

enum FuzzyMatchRank { prefix, wordBoundary, scattered }

class FuzzyMatch implements Comparable<FuzzyMatch> {
  const FuzzyMatch._(this.rank, this.distance);

  final FuzzyMatchRank rank;

  /// Index of the last matched character minus the first — how spread out
  /// the match was. Smaller wins within the same [rank].
  final int distance;

  @override
  int compareTo(FuzzyMatch other) {
    final rankCompare = rank.index.compareTo(other.rank.index);
    if (rankCompare != 0) return rankCompare;
    return distance.compareTo(other.distance);
  }

  static const Set<String> _wordBoundaryChars = {' ', '-', '_', '.', '@', '/'};

  /// Attempts to match [query] against [text]; null when [query]'s
  /// characters do not all appear, in order, somewhere in [text]. An empty
  /// query matches everything, at the lowest rank, so an unfiltered list
  /// keeps its original order.
  static FuzzyMatch? match(String query, String text) {
    if (query.isEmpty) return const FuzzyMatch._(FuzzyMatchRank.scattered, 0);

    final q = query.toLowerCase();
    final t = text.toLowerCase();

    var qi = 0;
    int? first;
    var last = 0;
    for (var ti = 0; ti < t.length && qi < q.length; ti++) {
      if (t[ti] == q[qi]) {
        first ??= ti;
        last = ti;
        qi++;
      }
    }
    if (qi < q.length) return null;

    final start = first!;
    final distance = last - start;
    if (start == 0) return FuzzyMatch._(FuzzyMatchRank.prefix, distance);
    if (_wordBoundaryChars.contains(t[start - 1])) {
      return FuzzyMatch._(FuzzyMatchRank.wordBoundary, distance);
    }
    return FuzzyMatch._(FuzzyMatchRank.scattered, distance);
  }
}

/// Ranks every item in [items] against [query], keeping only the ones that
/// match, best match first (ties keep [items]'s original relative order,
/// since [List.sort] on this platform is not guaranteed stable — see the
/// index tie-break below).
List<T> fuzzySort<T>(
  String query,
  List<T> items,
  String Function(T item) textOf,
) {
  final scored = <(int, FuzzyMatch, T)>[];
  for (var i = 0; i < items.length; i++) {
    final match = FuzzyMatch.match(query, textOf(items[i]));
    if (match != null) scored.add((i, match, items[i]));
  }
  scored.sort((a, b) {
    final byMatch = a.$2.compareTo(b.$2);
    if (byMatch != 0) return byMatch;
    return a.$1.compareTo(b.$1);
  });
  return [for (final entry in scored) entry.$3];
}
