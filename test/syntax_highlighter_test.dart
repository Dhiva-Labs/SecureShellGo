import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/syntax_token.dart';
import 'package:secure_shell_go/services/syntax_highlighter.dart';

/// The kind covering the first occurrence of [needle] in [text], or null when
/// the tokenizer left it unclassified.
///
/// Assertions read as "in this snippet, `SELECT` is a keyword", which is the
/// question a highlighting bug is actually reported as.
TokenKind? kindOf(SyntaxMode mode, String text, String needle) {
  final at = text.indexOf(needle);
  expect(at, isNonNegative, reason: 'the snippet does not contain "$needle"');
  for (final span in mode.tokenize(text)) {
    if (span.start <= at && at < span.end) return span.kind;
  }
  return null;
}

/// The kind at the occurrence of [needle] starting from [from].
TokenKind? kindOfAt(SyntaxMode mode, String text, String needle, int from) {
  final at = text.indexOf(needle, from);
  expect(at, isNonNegative);
  for (final span in mode.tokenize(text)) {
    if (span.start <= at && at < span.end) return span.kind;
  }
  return null;
}

/// Resolved at group-build time, so it cannot assert — "is this mode
/// registered at all" is covered by its own test below.
SyntaxMode modeById(String id) => syntaxModeById(id);

/// The invariant every consumer of a tokenizer relies on.
///
/// Sorted, non-overlapping, inside the text, never empty, never
/// [TokenKind.plain]. The editor's renderer walks spans against a single
/// moving cursor, so any of these being false shows up as scrambled text
/// rather than as an exception.
void expectWellFormed(List<HighlightSpan> spans, String text) {
  var previousEnd = 0;
  for (final span in spans) {
    expect(span.start, greaterThanOrEqualTo(previousEnd),
        reason: 'spans overlap or are out of order: $span');
    expect(span.end, greaterThan(span.start), reason: 'empty span: $span');
    expect(span.end, lessThanOrEqualTo(text.length),
        reason: 'span past end of text: $span');
    expect(span.kind, isNot(TokenKind.plain),
        reason: 'plain must be absence of a span, not a span');
    previousEnd = span.end;
  }
}

void main() {
  group('mode selection', () {
    test('picks a mode from the extension', () {
      expect(modeForFileName('main.dart').id, 'dart');
      expect(modeForFileName('deploy.sh').id, 'shell');
      expect(modeForFileName('docker-compose.yml').id, 'yaml');
      expect(modeForFileName('tsconfig.json').id, 'json');
      expect(modeForFileName('app.tsx').id, 'javascript');
      expect(modeForFileName('index.html').id, 'html');
      expect(modeForFileName('site.css').id, 'css');
      expect(modeForFileName('README.md').id, 'markdown');
      expect(modeForFileName('settings.toml').id, 'ini');
      expect(modeForFileName('schema.sql').id, 'sql');
    });

    test('picks a mode from a bare name with no extension', () {
      expect(modeForFileName('Dockerfile').id, 'dockerfile');
      expect(modeForFileName('dockerfile').id, 'dockerfile');
      expect(modeForFileName('Containerfile').id, 'dockerfile');
      expect(modeForFileName('nginx.conf').id, 'nginx');
      expect(modeForFileName('sshd_config').id, 'nginx');
      expect(modeForFileName('.bashrc').id, 'shell');
    });

    test('a suffixed name still finds its language', () {
      expect(modeForFileName('Dockerfile.prod').id, 'dockerfile');
      expect(modeForFileName('nginx.conf.bak').id, 'nginx');
    });

    test('anything unrecognised is plain text, not a guess', () {
      expect(modeForFileName('core.dump').id, 'plain');
      expect(modeForFileName('noextension').id, 'plain');
    });

    test('every registered mode round-trips through its id', () {
      for (final mode in syntaxModes) {
        expect(syntaxModeById(mode.id).id, mode.id);
      }
      expect(syntaxModeById('no-such-mode').id, 'plain');
      expect(syntaxModeById(null).id, 'plain');
    });
  });

  group('shell', () {
    final mode = modeById('shell');

    test('classifies a representative script', () {
      const src = '''
#!/bin/bash
# back up the database
set -euo pipefail
NAME="backup-\$(date +%F)"
for f in /var/log/*.log; do
  echo "archiving \$f" >> "\$NAME.txt"
done
''';
      expect(kindOf(mode, src, '#!/bin/bash'), TokenKind.meta);
      expect(kindOf(mode, src, '# back up'), TokenKind.comment);
      expect(kindOf(mode, src, 'set'), TokenKind.builtin);
      expect(kindOf(mode, src, '-euo'), TokenKind.attribute);
      expect(kindOf(mode, src, 'NAME='), TokenKind.meta);
      expect(kindOf(mode, src, 'for'), TokenKind.keyword);
      expect(kindOf(mode, src, 'done'), TokenKind.keyword);
      expect(kindOf(mode, src, 'echo'), TokenKind.builtin);
      expectWellFormed(mode.tokenize(src), src);
    });

    test(r'a variable inside a double-quoted string is picked out', () {
      const src = r'echo "home is $HOME today"';
      expect(kindOf(mode, src, r'$HOME'), TokenKind.builtin);
      expect(kindOf(mode, src, 'home is'), TokenKind.string);
      expect(kindOf(mode, src, ' today'), TokenKind.string);
      expectWellFormed(mode.tokenize(src), src);
    });

    test(r'single quotes take no interpolation, which is the point', () {
      const src = r"echo 'home is $HOME'";
      expect(kindOf(mode, src, r'$HOME'), TokenKind.string);
    });

    test('an unterminated quote colours to end of line and stops there', () {
      const src = "echo 'never closed\nls -la";
      expect(kindOf(mode, src, 'never closed'), TokenKind.string);
      // The next line has recovered — an unterminated single-line string does
      // not swallow the rest of the file.
      expect(kindOfAt(mode, src, '-la', 0), TokenKind.attribute);
    });
  });

  group('yaml', () {
    final mode = modeById('yaml');

    test('classifies keys, values and comments', () {
      const src = '''
# a compose file
version: "3.8"
services:
  web:
    image: nginx:1.25
    ports:
      - 8080:80
    environment:
      DEBUG: true
''';
      expect(kindOf(mode, src, '# a compose'), TokenKind.comment);
      expect(kindOf(mode, src, 'version'), TokenKind.meta);
      expect(kindOf(mode, src, '"3.8"'), TokenKind.string);
      expect(kindOf(mode, src, 'services'), TokenKind.meta);
      expect(kindOf(mode, src, 'true'), TokenKind.builtin);
      expectWellFormed(mode.tokenize(src), src);
    });

    test('a colon inside a URL does not end the key', () {
      const src = 'homepage: https://example.com/x';
      expect(kindOf(mode, src, 'homepage'), TokenKind.meta);
      // `https` must not have been taken as a second key.
      expect(kindOf(mode, src, 'https'), isNot(TokenKind.meta));
    });

    test('anchors and aliases read as references', () {
      const src = 'base: &defaults\nuse: *defaults';
      expect(kindOf(mode, src, '&defaults'), TokenKind.attribute);
      expect(kindOf(mode, src, '*defaults'), TokenKind.attribute);
    });
  });

  group('json', () {
    final mode = modeById('json');

    test('a key is distinguished from a string value', () {
      const src = '{"name": "secure_shell_go", "version": 3, "ok": true}';
      expect(kindOf(mode, src, '"name"'), TokenKind.meta);
      expect(kindOf(mode, src, '"secure_shell_go"'), TokenKind.string);
      expect(kindOf(mode, src, '3'), TokenKind.number);
      expect(kindOf(mode, src, 'true'), TokenKind.builtin);
      expectWellFormed(mode.tokenize(src), src);
    });

    test('comments are highlighted, because real json files have them', () {
      const src = '{\n  // the port to bind\n  "port": 8080\n}';
      expect(kindOf(mode, src, '// the port'), TokenKind.comment);
    });

    test('a block comment carries across lines and then releases', () {
      const src = '{\n/* one\n   two */ "a": 1\n}';
      expect(kindOf(mode, src, 'two'), TokenKind.comment);
      expect(kindOf(mode, src, '"a"'), TokenKind.meta);
    });
  });

  group('dart', () {
    final mode = modeById('dart');

    test('classifies a representative snippet', () {
      const src = '''
// a comment
import 'dart:async';

class Widget {
  final int count = 42;
  String get name => 'hello';
}
''';
      expect(kindOf(mode, src, '// a comment'), TokenKind.comment);
      expect(kindOf(mode, src, 'import'), TokenKind.keyword);
      expect(kindOf(mode, src, "'dart:async'"), TokenKind.string);
      expect(kindOf(mode, src, 'class'), TokenKind.keyword);
      expect(kindOf(mode, src, 'Widget'), TokenKind.builtin);
      expect(kindOf(mode, src, '42'), TokenKind.number);
      expect(kindOf(mode, src, 'String'), TokenKind.builtin);
      expectWellFormed(mode.tokenize(src), src);
    });

    test('a block comment spans lines and then releases', () {
      const src = 'var a = 1;\n/* still\n  going */\nvar b = 2;';
      expect(kindOf(mode, src, 'still'), TokenKind.comment);
      expect(kindOf(mode, src, 'going'), TokenKind.comment);
      expect(kindOfAt(mode, src, 'var', src.indexOf('going')),
          TokenKind.keyword);
    });

    test('a raw string is one token, body and all', () {
      const src = r"final p = r'C:\no\escapes';";
      expect(kindOf(mode, src, "r'C:"), TokenKind.string);
      expect(kindOf(mode, src, 'escapes'), TokenKind.string);
    });

    test('an annotation reads as metadata', () {
      const src = '@override\nvoid go() {}';
      expect(kindOf(mode, src, '@override'), TokenKind.meta);
    });
  });

  group('python', () {
    final mode = modeById('python');

    test('classifies a representative snippet', () {
      const src = '''
# tidy up
import os

@decorator
def main(argv):
    """A docstring
    over two lines."""
    if len(argv) > 1:
        print(f"got {argv[1]}")
    return None
''';
      expect(kindOf(mode, src, '# tidy up'), TokenKind.comment);
      expect(kindOf(mode, src, 'import'), TokenKind.keyword);
      expect(kindOf(mode, src, '@decorator'), TokenKind.meta);
      expect(kindOf(mode, src, 'def'), TokenKind.keyword);
      expect(kindOf(mode, src, 'A docstring'), TokenKind.string);
      expect(kindOf(mode, src, 'over two lines'), TokenKind.string);
      expect(kindOf(mode, src, 'print'), TokenKind.builtin);
      expect(kindOf(mode, src, 'None'), TokenKind.builtin);
      expectWellFormed(mode.tokenize(src), src);
    });

    test('an f-string prefix is part of the string', () {
      const src = 'x = f"value {y}"';
      expect(kindOf(mode, src, 'f"value'), TokenKind.string);
    });

    test('python has no block comment, so /* is not one', () {
      const src = 'a = b /* 2';
      expect(kindOf(mode, src, '/*'), isNot(TokenKind.comment));
    });
  });

  group('javascript / typescript', () {
    final mode = modeById('javascript');

    test('classifies a representative snippet', () {
      const src = '''
// entry point
import { readFile } from 'fs';

export async function main(): Promise<void> {
  const n: number = 3;
  console.log(`n is \${n}`);
}
''';
      expect(kindOf(mode, src, '// entry point'), TokenKind.comment);
      expect(kindOf(mode, src, 'import'), TokenKind.keyword);
      expect(kindOf(mode, src, "'fs'"), TokenKind.string);
      expect(kindOf(mode, src, 'async'), TokenKind.keyword);
      expect(kindOf(mode, src, 'Promise'), TokenKind.builtin);
      expect(kindOf(mode, src, '3'), TokenKind.number);
      expect(kindOf(mode, src, 'console'), TokenKind.builtin);
      expectWellFormed(mode.tokenize(src), src);
    });

    test('a template literal runs across lines', () {
      const src = 'const s = `line one\nline two`;\nconst t = 1;';
      expect(kindOf(mode, src, 'line one'), TokenKind.string);
      expect(kindOf(mode, src, 'line two'), TokenKind.string);
      expect(kindOfAt(mode, src, 'const', src.indexOf('line two')),
          TokenKind.keyword);
    });
  });

  group('html / xml', () {
    final mode = modeById('html');

    test('classifies tags, attributes and values', () {
      const src = '<a href="/x" class="btn">Go &amp; see</a>';
      expect(kindOf(mode, src, '<a'), TokenKind.meta);
      expect(kindOf(mode, src, 'href'), TokenKind.attribute);
      expect(kindOf(mode, src, '"/x"'), TokenKind.string);
      expect(kindOf(mode, src, '&amp;'), TokenKind.builtin);
      expect(kindOf(mode, src, '</a>'), TokenKind.meta);
      expectWellFormed(mode.tokenize(src), src);
    });

    test('a comment spans lines and then releases', () {
      const src = '<!-- hidden\n  still hidden -->\n<p>shown</p>';
      expect(kindOf(mode, src, 'still hidden'), TokenKind.comment);
      expect(kindOf(mode, src, '<p'), TokenKind.meta);
    });

    test('an unclosed tag does not run away', () {
      const src = '<div class="x\n<p>after</p>';
      expectWellFormed(mode.tokenize(src), src);
      expect(kindOf(mode, src, '<p'), TokenKind.meta);
    });
  });

  group('css', () {
    final mode = modeById('css');

    test('classifies selectors, properties and values', () {
      const src = '''
/* layout */
@media screen {
  .btn:hover {
    color: #ff8800;
    margin: 0 auto;
  }
}
''';
      expect(kindOf(mode, src, '/* layout */'), TokenKind.comment);
      expect(kindOf(mode, src, '@media'), TokenKind.keyword);
      expect(kindOf(mode, src, '.btn'), TokenKind.meta);
      expect(kindOf(mode, src, 'color'), TokenKind.attribute);
      expect(kindOf(mode, src, '#ff8800'), TokenKind.number);
      expectWellFormed(mode.tokenize(src), src);
    });
  });

  group('markdown', () {
    final mode = modeById('markdown');

    test('classifies headings, code and links', () {
      const src = '''
# Title

Some **bold** text and `inline code`.

- a bullet
- [a link](https://example.com)

```dart
var x = 1;
```

After the fence.
''';
      expect(kindOf(mode, src, '# Title'), TokenKind.heading);
      expect(kindOf(mode, src, '**bold**'), TokenKind.keyword);
      expect(kindOf(mode, src, '`inline code`'), TokenKind.string);
      expect(kindOf(mode, src, '[a link]'), TokenKind.attribute);
      expect(kindOf(mode, src, '(https://example.com)'), TokenKind.meta);
      expect(kindOf(mode, src, 'var x = 1;'), TokenKind.string);
      // The fence closed, so ordinary prose is prose again.
      expect(kindOf(mode, src, 'After the fence'), isNull);
      expectWellFormed(mode.tokenize(src), src);
    });
  });

  group('ini / toml', () {
    final mode = modeById('ini');

    test('classifies sections, keys and values', () {
      const src = '''
; a unit file
[Service]
ExecStart=/usr/bin/thing --flag
Restart=always
Enabled=true
''';
      expect(kindOf(mode, src, '; a unit file'), TokenKind.comment);
      expect(kindOf(mode, src, '[Service]'), TokenKind.heading);
      expect(kindOf(mode, src, 'ExecStart'), TokenKind.meta);
      expect(kindOf(mode, src, 'true'), TokenKind.builtin);
      expectWellFormed(mode.tokenize(src), src);
    });
  });

  group('sql', () {
    final mode = modeById('sql');

    test('keywords match without regard to case', () {
      const src = "select id from users where name = 'o''brien' limit 10;";
      expect(kindOf(mode, src, 'select'), TokenKind.keyword);
      expect(kindOf(mode, src, 'from'), TokenKind.keyword);
      expect(kindOf(mode, src, 'limit'), TokenKind.keyword);
      expect(kindOf(mode, src, '10'), TokenKind.number);
      expectWellFormed(mode.tokenize(src), src);
    });

    test('a doubled quote escapes rather than closing the string', () {
      const src = "SELECT 'o''brien' AS name;";
      // If `''` had closed and reopened, `AS` would fall inside a string.
      expect(kindOf(mode, src, 'AS'), TokenKind.keyword);
      expect(kindOf(mode, src, "'o''brien'"), TokenKind.string);
    });

    test('a double-quoted identifier is a name, not a string', () {
      const src = 'SELECT "user id" FROM t;';
      expect(kindOf(mode, src, '"user id"'), TokenKind.meta);
    });

    test('-- starts a comment', () {
      const src = '-- drop it\nDROP TABLE t;';
      expect(kindOf(mode, src, '-- drop it'), TokenKind.comment);
      expect(kindOf(mode, src, 'DROP'), TokenKind.keyword);
    });
  });

  group('dockerfile', () {
    final mode = modeById('dockerfile');

    test('classifies instructions, flags and variables', () {
      const src = r'''
# build it
FROM debian:bookworm AS build
ARG VERSION=1.2.0
COPY --chown=app:app . /srv
RUN echo "building $VERSION"
''';
      expect(kindOf(mode, src, '# build it'), TokenKind.comment);
      expect(kindOf(mode, src, 'FROM'), TokenKind.keyword);
      expect(kindOf(mode, src, 'COPY'), TokenKind.keyword);
      expect(kindOf(mode, src, '--chown'), TokenKind.attribute);
      expect(kindOf(mode, src, 'VERSION='), TokenKind.meta);
      expect(kindOf(mode, src, r'$VERSION'), TokenKind.builtin);
      expectWellFormed(mode.tokenize(src), src);
    });
  });

  group('nginx / apache conf', () {
    final mode = modeById('nginx');

    test('classifies directives, blocks and variables', () {
      const src = r'''
# the site
server {
    listen 443 ssl;
    server_name example.com;
    location /api {
        proxy_pass http://backend;
        proxy_set_header Host $host;
    }
}
''';
      expect(kindOf(mode, src, '# the site'), TokenKind.comment);
      expect(kindOf(mode, src, 'server {'), TokenKind.keyword);
      expect(kindOf(mode, src, 'listen'), TokenKind.meta);
      expect(kindOf(mode, src, '443'), TokenKind.number);
      expect(kindOf(mode, src, r'$host'), TokenKind.builtin);
      expectWellFormed(mode.tokenize(src), src);
    });

    test('an apache section tag is recognised too', () {
      const src = '<Directory /srv/www>\n    Require all granted\n</Directory>';
      expect(kindOf(mode, src, '<Directory'), TokenKind.keyword);
      expect(kindOf(mode, src, 'Require'), TokenKind.meta);
    });
  });

  group('plain text', () {
    test('classifies nothing at all', () {
      const src = 'just some words\nand more of them';
      expect(plainTextMode.tokenize(src), isEmpty);
    });
  });

  group('never throws', () {
    test('every mode survives structurally hostile input', () {
      // The shapes that break a naive scanner: unterminated everything,
      // delimiters in the wrong order, a lone backslash at end of line.
      final nasties = <String>[
        '',
        '\n',
        '"',
        "'",
        '`',
        '/*',
        '*/',
        '<!--',
        '"""',
        "'''",
        r'\',
        r'"\',
        r'$',
        r'${',
        r'$(',
        '[',
        '#',
        '<',
        '</',
        '<a href="',
        '{',
        '0x',
        '1e',
        '1e+',
        '.',
        '--',
        'a' * 5000,
        '\u{1F600}\u{1F600}',
        '"\u{1F600}',
        '\uD800',
        '\uDFFF',
        'k: \uD800',
      ];
      for (final mode in syntaxModes) {
        for (final nasty in nasties) {
          expect(
            () => mode.tokenize(nasty),
            returnsNormally,
            reason: '${mode.id} threw on ${jsonEncode(nasty)}',
          );
          expectWellFormed(mode.tokenize(nasty), nasty);
        }
      }
    });

    test('every mode survives random bytes, decoded the way a file is', () {
      // Seeded so a failure is reproducible; the point is breadth, not
      // secrecy. The bytes go through the same lossy UTF-8 decode the editor
      // uses on a file it has decided is text, so the strings under test are
      // exactly the shapes a real malformed file produces — replacement
      // characters, stray surrogates and all.
      final random = Random(20250731);
      for (var round = 0; round < 300; round++) {
        final length = random.nextInt(400);
        final bytes = Uint8List.fromList(
          List<int>.generate(length, (_) => random.nextInt(256)),
        );
        final text = utf8.decode(bytes, allowMalformed: true);
        for (final mode in syntaxModes) {
          late List<HighlightSpan> spans;
          expect(
            () => spans = mode.tokenize(text),
            returnsNormally,
            reason: '${mode.id} threw on round $round',
          );
          expectWellFormed(spans, text);
        }
      }
    });

    test('a mode that throws internally degrades to no highlighting', () {
      // The guarantee is enforced in `SyntaxMode.tokenizeLine`, not in each
      // scanner, so a mode written later cannot opt out of it. This proves
      // the wrapper, which is the part every future mode inherits.
      const mode = _ExplodingMode();
      expect(() => mode.tokenize('anything at all'), returnsNormally);
      expect(mode.tokenize('anything at all'), isEmpty);
      expect(mode.tokenizeLine('x', 0).nextState, 0);
    });
  });

  group('span caps', () {
    test('a pathological single line stays bounded', () {
      // One minified line: the cap keeps the span count off the frame budget
      // without the line disappearing.
      final src = List.filled(20000, '"a",').join();
      final mode = modeById('json');
      final spans = mode.tokenize(src);
      expect(spans.length, lessThanOrEqualTo(2000));
      expectWellFormed(spans, src);
    });
  });
}

/// A mode whose scanner always throws, to prove the wrapper catches it.
class _ExplodingMode extends SyntaxMode {
  const _ExplodingMode();

  @override
  String get id => 'exploding';

  @override
  String get label => 'Exploding';

  @override
  LineTokens scanLine(String line, int state) =>
      throw StateError('scanner bug');
}
