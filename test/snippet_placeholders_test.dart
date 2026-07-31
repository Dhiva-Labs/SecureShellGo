import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/snippet_placeholders.dart';

void main() {
  test('a command with no braces has no placeholders', () {
    final parsed = parseSnippetCommand('echo hello');
    expect(parsed.hasPlaceholders, isFalse);
    expect(parsed.placeholderNames, isEmpty);
    expect(parsed.render(const {}), 'echo hello');
  });

  test('a single placeholder is found and rendered', () {
    final parsed = parseSnippetCommand('tail -f /var/log/{app}.log');
    expect(parsed.placeholderNames, ['app']);
    expect(
      parsed.render(const {'app': 'nginx'}),
      'tail -f /var/log/nginx.log',
    );
  });

  test('multiple distinct placeholders keep their order', () {
    final parsed = parseSnippetCommand('scp {file} user@{host}:/tmp');
    expect(parsed.placeholderNames, ['file', 'host']);
    expect(
      parsed.render(const {'file': 'notes.txt', 'host': 'example.com'}),
      'scp notes.txt user@example.com:/tmp',
    );
  });

  test('a repeated placeholder is asked for once but substituted everywhere',
      () {
    final parsed = parseSnippetCommand('echo {name} && echo {name} again');
    expect(parsed.placeholderNames, ['name']);
    expect(
      parsed.render(const {'name': 'hi'}),
      'echo hi && echo hi again',
    );
  });

  test('leading/trailing whitespace inside braces is trimmed from the name',
      () {
    final parsed = parseSnippetCommand('echo { name }');
    expect(parsed.placeholderNames, ['name']);
    expect(parsed.render(const {'name': 'x'}), 'echo x');
  });

  test('{{ and }} escape a literal brace and are not placeholders', () {
    final parsed = parseSnippetCommand("awk '{{print \$1}}'");
    expect(parsed.hasPlaceholders, isFalse);
    expect(parsed.render(const {}), "awk '{print \$1}'");
  });

  test('a mix of escaped braces and a real placeholder both work', () {
    final parsed = parseSnippetCommand('for i in {{1..5}}; do echo {msg}; done');
    expect(parsed.placeholderNames, ['msg']);
    expect(
      parsed.render(const {'msg': 'hi'}),
      'for i in {1..5}; do echo hi; done',
    );
  });

  test('an empty pair of braces is left as literal text, not a placeholder',
      () {
    final parsed = parseSnippetCommand('echo {}');
    expect(parsed.hasPlaceholders, isFalse);
    expect(parsed.render(const {}), 'echo {}');
  });

  test('an unterminated brace is kept as literal text', () {
    final parsed = parseSnippetCommand('echo {oops');
    expect(parsed.hasPlaceholders, isFalse);
    expect(parsed.render(const {}), 'echo {oops');
  });

  test('a value missing from the map renders as empty rather than throwing',
      () {
    final parsed = parseSnippetCommand('echo {name}');
    expect(parsed.render(const {}), 'echo ');
  });

  test('an empty command parses to nothing', () {
    final parsed = parseSnippetCommand('');
    expect(parsed.placeholderNames, isEmpty);
    expect(parsed.render(const {}), '');
  });

  test('a lone closing brace outside a placeholder is literal', () {
    final parsed = parseSnippetCommand(r'echo $1}');
    expect(parsed.hasPlaceholders, isFalse);
    expect(parsed.render(const {}), r'echo $1}');
  });
}
