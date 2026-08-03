import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/quick_connect_parser.dart';

void main() {
  const defaultUser = 'root';

  QuickConnectParseResult parse(String input) =>
      parseQuickConnect(input, defaultUsername: defaultUser);

  test('user@host parses with the standard port', () {
    final result = parse('dev@example.com');
    expect(result.isOk, isTrue);
    expect(result.target!.username, 'dev');
    expect(result.target!.hostname, 'example.com');
    expect(result.target!.port, 22);
  });

  test('user@host:port parses the custom port', () {
    final result = parse('dev@example.com:2222');
    expect(result.isOk, isTrue);
    expect(result.target!.username, 'dev');
    expect(result.target!.hostname, 'example.com');
    expect(result.target!.port, 2222);
  });

  test('a bare host falls back to the default username', () {
    final result = parse('example.com');
    expect(result.isOk, isTrue);
    expect(result.target!.username, defaultUser);
    expect(result.target!.hostname, 'example.com');
    expect(result.target!.port, 22);
  });

  test('host:port with no username also uses the default', () {
    final result = parse('example.com:2200');
    expect(result.isOk, isTrue);
    expect(result.target!.username, defaultUser);
    expect(result.target!.hostname, 'example.com');
    expect(result.target!.port, 2200);
  });

  test('bracketed IPv6 with no port defaults to 22', () {
    final result = parse('[::1]');
    expect(result.isOk, isTrue);
    expect(result.target!.hostname, '::1');
    expect(result.target!.port, 22);
  });

  test('bracketed IPv6 with a port parses both', () {
    final result = parse('[::1]:2222');
    expect(result.isOk, isTrue);
    expect(result.target!.hostname, '::1');
    expect(result.target!.port, 2222);
  });

  test('user@ with bracketed IPv6 and a port parses all three parts', () {
    final result = parse('admin@[2001:db8::1]:2200');
    expect(result.isOk, isTrue);
    expect(result.target!.username, 'admin');
    expect(result.target!.hostname, '2001:db8::1');
    expect(result.target!.port, 2200);
  });

  test('bare IPv6 without brackets is rejected with a clear message', () {
    final result = parse('::1');
    expect(result.isOk, isFalse);
    expect(result.message, contains('brackets'));
  });

  test('a longer bare IPv6 address without brackets is also rejected', () {
    final result = parse('2001:db8::1');
    expect(result.isOk, isFalse);
    expect(result.message, contains('brackets'));
  });

  test('empty input is rejected', () {
    final result = parse('');
    expect(result.isOk, isFalse);
    expect(result.message, isNotEmpty);
  });

  test('whitespace-only input is rejected', () {
    final result = parse('   ');
    expect(result.isOk, isFalse);
  });

  test('an empty username before "@" is rejected', () {
    final result = parse('@example.com');
    expect(result.isOk, isFalse);
    expect(result.message, contains('Username'));
  });

  test('a non-numeric port is rejected', () {
    final result = parse('example.com:abc');
    expect(result.isOk, isFalse);
    expect(result.message, contains('Port'));
  });

  test('a port of 0 is rejected', () {
    final result = parse('example.com:0');
    expect(result.isOk, isFalse);
  });

  test('a port above 65535 is rejected', () {
    final result = parse('example.com:70000');
    expect(result.isOk, isFalse);
  });

  test('an unclosed IPv6 bracket is rejected', () {
    final result = parse('[::1');
    expect(result.isOk, isFalse);
    expect(result.message, contains(']'));
  });

  test('empty brackets are rejected', () {
    final result = parse('[]');
    expect(result.isOk, isFalse);
  });

  test('surrounding whitespace in the input is trimmed', () {
    final result = parse('  dev@example.com  ');
    expect(result.isOk, isTrue);
    expect(result.target!.hostname, 'example.com');
  });

  group('whether the port was in the input', () {
    QuickConnectTarget parse(String input) =>
        parseQuickConnect(input, defaultUsername: 'me').target!;

    test('an explicit port is marked as one', () {
      expect(parse('example.com:2222').hasExplicitPort, isTrue);
      expect(parse('[::1]:2222').hasExplicitPort, isTrue);
      // Even when it happens to be the default.
      expect(parse('example.com:22').hasExplicitPort, isTrue);
    });

    test('the default 22 is not', () {
      // The host edit form fills its Port field from this, and must not
      // overwrite a port the user typed with one that came from nowhere.
      expect(parse('example.com').hasExplicitPort, isFalse);
      expect(parse('example.com').port, 22);
      expect(parse('[::1]').hasExplicitPort, isFalse);
    });
  });
}
