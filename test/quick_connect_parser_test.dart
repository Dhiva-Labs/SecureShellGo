import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/quick_connect_parser.dart';

void main() {
  _sshCommandTests();
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

void _sshCommandTests() {
  QuickConnectTarget parse(String input) {
    final r = parseQuickConnect(input, defaultUsername: 'fallback');
    expect(r.isOk, isTrue, reason: 'failed: ${r.message} for "$input"');
    return r.target!;
  }

  group('a pasted ssh command', () {
    test('the AWS console form, quoted key and all', () {
      final t = parse('ssh -i "Master-Mumbai.pem" '
          'ubuntu@ec2-3-111-164-59.ap-south-1.compute.amazonaws.com');
      expect(t.username, 'ubuntu');
      expect(t.hostname, 'ec2-3-111-164-59.ap-south-1.compute.amazonaws.com');
      expect(t.port, 22);
      expect(t.identityFile, 'Master-Mumbai.pem');
    });

    test('an unquoted key path', () {
      final t = parse('ssh -i ~/.ssh/aws.pem ec2-user@10.0.0.4');
      expect(t.username, 'ec2-user');
      expect(t.hostname, '10.0.0.4');
      expect(t.identityFile, '~/.ssh/aws.pem');
    });

    test('a key path containing a space stays one token', () {
      final t = parse('ssh -i "my keys/aws key.pem" ubuntu@example.com');
      expect(t.identityFile, 'my keys/aws key.pem');
      expect(t.hostname, 'example.com');
    });

    test('-p sets the port', () {
      final t = parse('ssh -p 2222 ubuntu@example.com');
      expect(t.port, 2222);
      expect(t.hasExplicitPort, isTrue);
    });

    test('-l supplies the username when the operand has none', () {
      final t = parse('ssh -l ubuntu example.com');
      expect(t.username, 'ubuntu');
      expect(t.hostname, 'example.com');
    });

    test('a user@ on the operand beats -l, as OpenSSH does', () {
      final t = parse('ssh -l ignored ubuntu@example.com');
      expect(t.username, 'ubuntu');
    });

    test('bare switches are skipped without eating the host', () {
      final t = parse('ssh -v -A -T ubuntu@example.com');
      expect(t.hostname, 'example.com');
      expect(t.username, 'ubuntu');
    });

    test('a flag value is never mistaken for the host', () {
      final t = parse('ssh -o StrictHostKeyChecking=no ubuntu@example.com');
      expect(t.hostname, 'example.com');
    });

    test('a trailing remote command is ignored', () {
      final t = parse('ssh ubuntu@example.com sudo reboot');
      expect(t.hostname, 'example.com');
      expect(t.username, 'ubuntu');
    });

    test('an ssh:// operand works', () {
      final t = parse('ssh ssh://ubuntu@example.com:2200');
      expect(t.hostname, 'example.com');
      expect(t.port, 2200);
    });

    test('IPv6 keeps working with -p', () {
      final t = parse('ssh -p 2222 ubuntu@[::1]');
      expect(t.hostname, '::1');
      expect(t.port, 2222);
    });

    test('an ssh command with no host is refused clearly', () {
      final r = parseQuickConnect('ssh -v', defaultUsername: 'fallback');
      expect(r.isOk, isFalse);
      expect(r.message, contains('does not name a host'));
    });

    test('a plain host is still not treated as a command', () {
      final t = parse('ubuntu@example.com');
      expect(t.hostname, 'example.com');
      expect(t.identityFile, isNull);
    });

    test('a host that merely starts with ssh is untouched', () {
      final t = parse('ssh.example.com');
      expect(t.hostname, 'ssh.example.com');
      expect(t.identityFile, isNull);
    });
  });
}
