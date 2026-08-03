import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/host_field_input.dart';

void main() {
  group('a trailing port is moved out of the host field', () {
    test('the paste that started this: an address with a port on it', () {
      final entry = parseHostField('127.0.0.1:22303');
      expect(entry.hostname, '127.0.0.1');
      expect(entry.port, 22303);
    });

    test('a name with a port', () {
      final entry = parseHostField('  example.com:2222  ');
      expect(entry.hostname, 'example.com');
      expect(entry.port, 2222);
    });

    test('a plain host is left exactly as it is', () {
      final entry = parseHostField('example.com');
      expect(entry.hostname, 'example.com');
      expect(entry.port, isNull);
    });
  });

  group('IPv6', () {
    test('bracketed, with a port', () {
      final entry = parseHostField('[::1]:2222');
      expect(entry.hostname, '::1');
      expect(entry.port, 2222);
    });

    test('bracketed, without one', () {
      final entry = parseHostField('[fe80::1]');
      expect(entry.hostname, 'fe80::1');
      expect(entry.port, isNull);
    });

    test('bare, and therefore not taken apart', () {
      // The last colon here is part of the address, not a port separator,
      // and there is no way to tell from the text which was meant.
      for (final address in ['::1', 'fe80::1', '2001:db8::8a2e:370:7334']) {
        final entry = parseHostField(address);
        expect(entry.hostname, address, reason: address);
        expect(entry.port, isNull, reason: address);
      }
    });
  });

  group('what it refuses to rewrite', () {
    test('a port that is not a number, or is out of range', () {
      for (final input in [
        'example.com:',
        'example.com:ssh',
        'example.com:0',
        'example.com:65536',
        'example.com:-1',
      ]) {
        final entry = parseHostField(input);
        expect(entry.hostname, input, reason: input);
        expect(entry.port, isNull, reason: input);
      }
    });

    test('an unterminated or empty bracket', () {
      for (final input in ['[::1', '[]:22', '[::1]x']) {
        final entry = parseHostField(input);
        expect(entry.hostname, input, reason: input);
        expect(entry.port, isNull, reason: input);
      }
    });

    test('an empty field', () {
      expect(parseHostField('   ').hostname, isEmpty);
      expect(parseHostField('   ').port, isNull);
    });
  });

  group('a user@ prefix', () {
    test('is split out, with the port', () {
      final entry = parseHostField('deploy@example.com:2222');
      expect(entry.hostname, 'example.com');
      expect(entry.port, 2222);
      expect(entry.username, 'deploy');
    });

    test('is split out on its own', () {
      final entry = parseHostField('deploy@example.com');
      expect(entry.hostname, 'example.com');
      expect(entry.port, isNull);
      expect(entry.username, 'deploy');
    });

    test('an empty one is left for the user to fix', () {
      expect(parseHostField('@example.com').hostname, '@example.com');
    });
  });

  group('advice for a host record that already has this wrong', () {
    test('names the port and where it belongs', () {
      final advice = misplacedHostFieldAdvice('127.0.0.1:22303');
      expect(advice, isNotNull);
      expect(advice, contains('22303'));
      expect(advice, contains('127.0.0.1'));
      expect(advice, contains('Port'));
      // The advice it replaces was actively wrong for this case.
      expect(advice, isNot(contains('spelling')));
    });

    test('names the username and where it belongs', () {
      final advice = misplacedHostFieldAdvice('deploy@example.com');
      expect(advice, contains('deploy'));
      expect(advice, contains('Username'));
    });

    test('has nothing to say about an ordinary address', () {
      expect(misplacedHostFieldAdvice('example.com'), isNull);
      expect(misplacedHostFieldAdvice('fe80::1'), isNull);
      expect(misplacedHostFieldAdvice('192.168.1.10'), isNull);
    });
  });
}
