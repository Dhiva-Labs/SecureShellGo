import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/syntax_token.dart';
import 'package:secure_shell_go/services/editor_indent.dart';
import 'package:secure_shell_go/services/syntax_highlighter.dart';

/// The languages added with the editor overhaul: picked from the file name,
/// coloured, and given the indentation rules a programmer expects.
void main() {
  Set<String> kindsOf(String code, String file, TokenKind kind) {
    final mode = modeForFileName(file);
    return {
      for (final span in mode.tokenize(code))
        if (span.kind == kind) code.substring(span.start, span.end),
    };
  }

  test('each is picked from its file name', () {
    expect(modeForFileName('main.c').id, 'c');
    expect(modeForFileName('engine.cpp').id, 'c');
    expect(modeForFileName('server.go').id, 'go');
    expect(modeForFileName('lib.rs').id, 'rust');
    expect(modeForFileName('App.java').id, 'java');
    expect(modeForFileName('build.gradle.kts').id, 'kotlin');
    expect(modeForFileName('deploy.rb').id, 'ruby');
    expect(modeForFileName('Gemfile').id, 'ruby');
    expect(modeForFileName('index.php').id, 'php');
    // Groovy is not Kotlin; better uncoloured than mislabelled.
    expect(modeForFileName('Jenkinsfile').id, 'plain');
  });

  test('keywords and comments are coloured', () {
    expect(kindsOf('func main() { return } // done', 'a.go', TokenKind.keyword),
        containsAll(['func', 'return']));
    expect(kindsOf('fn main() { let x = 1; }', 'a.rs', TokenKind.keyword),
        containsAll(['fn', 'let']));
    expect(kindsOf('def hi\n  puts "x" # say\nend', 'a.rb', TokenKind.keyword),
        containsAll(['def', 'end']));
    expect(kindsOf('int main() { /* x */ return 0; }', 'a.c',
        TokenKind.comment), contains('/* x */'));
  });

  test('Go indents with tabs; C, Java and Rust with four spaces', () {
    expect(EditorLanguage.forFile('main.go', 'go').defaultIndent.useTabs,
        isTrue);
    for (final (file, id) in [('a.c', 'c'), ('A.java', 'java'), ('a.rs', 'rust')]) {
      final language = EditorLanguage.forFile(file, id);
      expect(language.defaultIndent, const IndentStyle.spaces(4), reason: id);
      expect(language.bracketIndent, isTrue, reason: id);
      expect(language.lineComment, '//', reason: id);
    }
    expect(EditorLanguage.forFile('a.rb', 'ruby').lineComment, '#');
  });
}
