import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/editor_search.dart';

const String sample = '''
server {
  listen 80;
  server_name example.com;
}
''';

void main() {
  group('plain-text find', () {
    test('finds every occurrence', () {
      final hits = findMatches(
        sample,
        const EditorQuery(pattern: 'server'),
      );
      expect(hits.length, 2);
      expect(sample.substring(hits.first.start, hits.first.end), 'server');
    });

    test('is case-insensitive by default and exact when asked', () {
      expect(findMatches('Foo foo FOO', const EditorQuery(pattern: 'foo')),
          hasLength(3));
      expect(
        findMatches(
          'Foo foo FOO',
          const EditorQuery(pattern: 'foo', caseSensitive: true),
        ),
        hasLength(1),
      );
    });

    test('regex metacharacters are literal when regex is off', () {
      // The whole point of the toggle: `a.c` must not match `abc`.
      expect(findMatches('abc a.c', const EditorQuery(pattern: 'a.c')),
          hasLength(1));
      expect(
        findMatches(
          'abc a.c',
          const EditorQuery(pattern: 'a.c', isRegex: true),
        ),
        hasLength(2),
      );
    });

    test('an empty pattern finds nothing rather than everything', () {
      expect(findMatches(sample, const EditorQuery(pattern: '')), isEmpty);
    });
  });

  group('regex find', () {
    test('matches and captures groups', () {
      final hits = findMatches(
        'listen 80; listen 443;',
        const EditorQuery(pattern: r'listen (\d+)', isRegex: true),
      );
      expect(hits, hasLength(2));
      expect(hits.first.groups.single, '80');
      expect(hits.last.groups.single, '443');
    });

    test('^ and \$ anchor per line, not per document', () {
      final hits = findMatches(
        sample,
        const EditorQuery(pattern: r'^\s*listen', isRegex: true),
      );
      expect(hits, hasLength(1));
    });

    test('an invalid regex reports a message instead of throwing', () {
      const query = EditorQuery(pattern: '(unclosed', isRegex: true);
      final compiled = compileQuery(query);
      expect(compiled.isUsable, isFalse);
      expect(compiled.error, isNotNull);
      expect(() => findMatches(sample, query), returnsNormally);
      expect(findMatches(sample, query), isEmpty);
    });

    test('a zero-width pattern terminates instead of spinning', () {
      // `x*` matches the empty string everywhere. A scan that did not advance
      // past an empty match would hang here and take the app with it.
      final hits = findMatches('abc', const EditorQuery(
        pattern: 'x*',
        isRegex: true,
      ));
      expect(hits, isNotEmpty);
      expect(hits.length, lessThanOrEqualTo(4));
    });

    test('the match list is capped rather than unbounded', () {
      final huge = 'a' * (editorMaxMatches + 500);
      final hits =
          findMatches(huge, const EditorQuery(pattern: 'a', isRegex: true));
      expect(hits, hasLength(editorMaxMatches));
    });
  });

  group('replace all', () {
    test('replaces every hit and reports the count', () {
      final result = replaceAll(
        sample,
        const EditorQuery(pattern: 'server'),
        'upstream',
      );
      expect(result.count, 2);
      expect(result.text, contains('upstream {'));
      expect(result.text, contains('upstream_name'));
      expect(result.text, isNot(contains('server')));
    });

    test('reports zero and changes nothing when there is no hit', () {
      final result = replaceAll(
        sample,
        const EditorQuery(pattern: 'nowhere'),
        'x',
      );
      expect(result.count, 0);
      expect(result.text, sample);
    });

    test('a plain-text replacement is literal, dollars and all', () {
      // Someone replacing a price means five dollars, not capture group 5.
      final result = replaceAll(
        'cost is TBD',
        const EditorQuery(pattern: 'TBD'),
        r'$5',
      );
      expect(result.count, 1);
      expect(result.text, r'cost is $5');
    });

    test('a regex replacement expands groups', () {
      final result = replaceAll(
        'listen 80; listen 443;',
        const EditorQuery(pattern: r'listen (\d+)', isRegex: true),
        r'port $1',
      );
      expect(result.count, 2);
      expect(result.text, 'port 80; port 443;');
    });

    test(r'$& is the whole match and $$ is a literal dollar', () {
      final result = replaceAll(
        'abc',
        const EditorQuery(pattern: 'b', isRegex: true),
        r'[$&]$$',
      );
      expect(result.text, r'a[b]$c');
    });

    test('a group that did not participate expands to nothing', () {
      final result = replaceAll(
        'ab',
        const EditorQuery(pattern: '(a)(z)?', isRegex: true),
        r'<$1|$2>',
      );
      expect(result.count, 1);
      expect(result.text, '<a|>b');
    });

    test('replacing with something containing the pattern does not loop', () {
      final result = replaceAll(
        'a a a',
        const EditorQuery(pattern: 'a'),
        'aa',
      );
      expect(result.count, 3);
      expect(result.text, 'aa aa aa');
    });
  });

  group('replace one', () {
    test('replaces the first hit at or after the caret', () {
      final result = replaceOne(
        'one two one two',
        const EditorQuery(pattern: 'one'),
        'ONE',
        from: 4,
      );
      expect(result.count, 1);
      expect(result.text, 'one two ONE two');
    });

    test('wraps to the top rather than stopping at the last hit', () {
      final result = replaceOne(
        'one two',
        const EditorQuery(pattern: 'one'),
        'ONE',
        from: 100,
      );
      expect(result.count, 1);
      expect(result.text, 'ONE two');
    });

    test('leaves the caret just past what it wrote', () {
      final result = replaceOne(
        'abc',
        const EditorQuery(pattern: 'b'),
        'XYZ',
      );
      expect(result.caret, 4);
      expect(result.text, 'aXYZc');
    });

    test('reports zero when nothing matches', () {
      final result = replaceOne(
        'abc',
        const EditorQuery(pattern: 'zzz'),
        'x',
      );
      expect(result.count, 0);
      expect(result.text, 'abc');
    });
  });

  group('match navigation', () {
    test('finds the next match, wrapping at the end', () {
      final hits = findMatches('a-a-a', const EditorQuery(pattern: 'a'));
      expect(matchIndexAtOrAfter(hits, 0), 0);
      expect(matchIndexAtOrAfter(hits, 1), 1);
      expect(matchIndexAtOrAfter(hits, 5), 0);
    });

    test('finds the previous match, wrapping at the start', () {
      final hits = findMatches('a-a-a', const EditorQuery(pattern: 'a'));
      expect(matchIndexBefore(hits, 5), 2);
      expect(matchIndexBefore(hits, 3), 1);
      expect(matchIndexBefore(hits, 0), 2);
    });

    test('reports -1 when there is nothing to navigate', () {
      expect(matchIndexAtOrAfter(const [], 0), -1);
      expect(matchIndexBefore(const [], 0), -1);
    });
  });

  group('go to line', () {
    test('maps a line number to an offset', () {
      expect(offsetForLine(sample, 1), 0);
      expect(offsetForLine(sample, 2), sample.indexOf('  listen'));
      expect(offsetForLine(sample, 3), sample.indexOf('  server_name'));
    });

    test('clamps rather than refusing an out-of-range line', () {
      expect(offsetForLine(sample, 0), 0);
      expect(offsetForLine(sample, -4), 0);
      expect(offsetForLine(sample, 9999), sample.length);
    });

    test('maps an offset back to its line', () {
      expect(lineForOffset(sample, 0), 1);
      expect(lineForOffset(sample, sample.indexOf('listen')), 2);
      expect(lineForOffset(sample, sample.indexOf('server_name')), 3);
      expect(
        lineForOffset(sample, 99999),
        lineForOffset(sample, sample.length),
      );
    });

    test('line and offset round-trip', () {
      for (var line = 1; line <= 5; line++) {
        expect(lineForOffset(sample, offsetForLine(sample, line)), line);
      }
    });
  });
}
