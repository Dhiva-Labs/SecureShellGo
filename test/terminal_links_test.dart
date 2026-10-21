import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/terminal_links.dart';
import 'package:xterm/xterm.dart';

List<String> urls(String text) =>
    [for (final link in TerminalLinks.find(text)) link.url];

void main() {
  group('finding addresses', () {
    test('a bare address, with its offsets', () {
      final links = TerminalLinks.find('open https://example.com/a?b=1 now');
      expect(links, [
        const TerminalLink(url: 'https://example.com/a?b=1', start: 5, end: 30),
      ]);
      expect(links.single.uri, Uri.parse('https://example.com/a?b=1'));
    });

    test('sentence punctuation after it is not part of it', () {
      expect(urls('See https://example.com.'), ['https://example.com']);
      expect(urls('at https://example.com/x, then'), ['https://example.com/x']);
      expect(urls('really? https://example.com/!?'), ['https://example.com/']);
      expect(urls('docs: https://example.com/a; more'), ['https://example.com/a']);
      expect(urls('"https://example.com/q"'), ['https://example.com/q']);
      expect(urls("'https://example.com/q'"), ['https://example.com/q']);
      expect(urls('<https://example.com/q>'), ['https://example.com/q']);
      expect(urls('**https://example.com/b**'), ['https://example.com/b']);
    });

    test('a closing bracket it did not open is not part of it', () {
      expect(urls('(see https://example.com/a)'), ['https://example.com/a']);
      expect(urls('[https://example.com/a]'), ['https://example.com/a']);
      expect(urls('(https://example.com/a).'), ['https://example.com/a']);
    });

    test('brackets inside it are kept', () {
      expect(
        urls('https://en.wikipedia.org/wiki/Bash_(Unix_shell)'),
        ['https://en.wikipedia.org/wiki/Bash_(Unix_shell)'],
      );
      expect(
        urls('[docs](https://example.com/a_(b))'),
        ['https://example.com/a_(b)'],
      );
      expect(urls('http://[::1]:8080/health'), ['http://[::1]:8080/health']);
    });

    test('several on a line, and the scheme in any case', () {
      expect(
        urls('http://a.example and HTTPS://B.EXAMPLE/x'),
        ['http://a.example', 'HTTPS://B.EXAMPLE/x'],
      );
    });

    test('only http and https', () {
      expect(urls('file:///etc/passwd'), isEmpty);
      expect(urls('javascript:alert(1)'), isEmpty);
      expect(urls('ftp://files.example.com/a'), isEmpty);
      expect(urls('ssh://host.example.com'), isEmpty);
      expect(urls('vscode://open?x=1'), isEmpty);
      expect(urls('mailto:someone@example.com'), isEmpty);
    });

    test('not without a host', () {
      expect(urls('https://'), isEmpty);
      expect(urls('https:///path'), isEmpty);
    });

    test('not glued onto a word', () {
      expect(urls('xhttps://example.com'), isEmpty);
    });

    test('the link under an offset', () {
      const text = 'a https://one.example b https://two.example';
      expect(TerminalLinks.at(text, 5)?.url, 'https://one.example');
      expect(TerminalLinks.at(text, 30)?.url, 'https://two.example');
      expect(TerminalLinks.at(text, 0), isNull);
      expect(TerminalLinks.at(text, 22), isNull);
    });
  });

  group('deciding what may open', () {
    test('http and https with a host', () {
      expect(TerminalLinks.parse('https://example.com'), isNotNull);
      expect(TerminalLinks.parse('http://10.0.0.1:8080/'), isNotNull);
    });

    test('nothing else, however it is spelled', () {
      expect(TerminalLinks.parse('file:///bin/sh'), isNull);
      expect(TerminalLinks.parse('javascript:alert(1)'), isNull);
      expect(TerminalLinks.parse('intent://scan/#Intent;scheme=x;end'), isNull);
      expect(TerminalLinks.parse('data:text/html,<b>x</b>'), isNull);
      expect(TerminalLinks.parse('/usr/bin/env'), isNull);
      expect(TerminalLinks.parse('https://'), isNull);
    });
  });

  group('in the terminal', () {
    Terminal terminalWith(String text, {int columns = 20}) {
      final terminal = Terminal(maxLines: 100);
      terminal.resize(columns, 6);
      terminal.write(text);
      return terminal;
    }

    test('an address wrapped across rows is found whole from either row', () {
      // 37 characters on a 20-column terminal: two rows.
      const url = 'https://example.com/a/long/path/here';
      final terminal = terminalWith('$url\r\n\$ ');
      final fromFirst =
          TerminalLinks.inBuffer(terminal.buffer, const CellOffset(3, 0));
      final fromSecond =
          TerminalLinks.inBuffer(terminal.buffer, const CellOffset(5, 1));
      expect(fromFirst?.text, url);
      expect(fromSecond?.text, url);
      expect(fromSecond?.uri, Uri.parse(url));
      expect(fromSecond?.begin, const CellOffset(0, 0));
      expect(fromSecond?.end, const CellOffset(16, 1));
    });

    test('nothing beside the address, or past the end of the line', () {
      final terminal = terminalWith('go https://a.example. ok');
      final buffer = terminal.buffer;
      expect(TerminalLinks.inBuffer(buffer, const CellOffset(1, 0)), isNull);
      expect(TerminalLinks.inBuffer(buffer, const CellOffset(3, 0))?.text,
          'https://a.example');
      // The full stop after it.
      expect(TerminalLinks.inBuffer(buffer, const CellOffset(20, 0)), isNull);
      expect(TerminalLinks.inBuffer(buffer, const CellOffset(10, 3)), isNull);
      expect(TerminalLinks.inBuffer(buffer, const CellOffset(0, 99)), isNull);
    });

    test('colours around an address do not get into it', () {
      final terminal =
          terminalWith('\x1b[34mhttps://c.example\x1b[0m)', columns: 40);
      expect(
        TerminalLinks.inBuffer(terminal.buffer, const CellOffset(2, 0))?.text,
        'https://c.example',
      );
    });
  });
}
