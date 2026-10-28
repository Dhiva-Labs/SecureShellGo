import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/services/ssh_config_parser.dart';

void main() {
  test('HostName, User, Port and IdentityFile all apply to their block', () {
    final result = SshConfigParser.parse('''
Host myserver
  HostName example.com
  User dev
  Port 2222
  IdentityFile ~/.ssh/id_ed25519
''');
    expect(result.entries, hasLength(1));
    final entry = result.entries.single;
    expect(entry.alias, 'myserver');
    expect(entry.hostname, 'example.com');
    expect(entry.user, 'dev');
    expect(entry.port, 2222);
    expect(entry.identityFile, '~/.ssh/id_ed25519');
  });

  test('a Host with no HostName falls back to the alias itself', () {
    final result = SshConfigParser.parse('Host example.com\n  User dev\n');
    expect(result.entries.single.hostname, 'example.com');
  });

  test('a Host with no Port defaults to 22', () {
    final result = SshConfigParser.parse('Host box\n  HostName 10.0.0.5\n');
    expect(result.entries.single.port, 22);
  });

  test('keywords are case-insensitive', () {
    final result = SshConfigParser.parse('''
host myserver
  hostname example.com
  USER dev
  pOrT 2200
''');
    final entry = result.entries.single;
    expect(entry.hostname, 'example.com');
    expect(entry.user, 'dev');
    expect(entry.port, 2200);
  });

  test('"=" and whitespace separators both work, with ragged spacing', () {
    final result = SshConfigParser.parse('''
Host   myserver
  HostName=example.com
  User    =    dev
  Port\t2222
''');
    final entry = result.entries.single;
    expect(entry.hostname, 'example.com');
    expect(entry.user, 'dev');
    expect(entry.port, 2222);
  });

  test('full-line comments and blank lines are ignored', () {
    final result = SshConfigParser.parse('''
# a top-of-file comment
Host myserver
  # a comment inside the block

  HostName example.com
''');
    expect(result.entries, hasLength(1));
    expect(result.entries.single.hostname, 'example.com');
  });

  test('a quoted value may contain spaces', () {
    final result = SshConfigParser.parse('''
Host "my server"
  HostName example.com
''');
    expect(result.entries.single.alias, 'my server');
  });

  test('multiple aliases on one Host line each get their own entry', () {
    final result = SshConfigParser.parse('''
Host foo bar
  HostName example.com
  Port 2200
''');
    expect(result.entries.map((e) => e.alias), ['foo', 'bar']);
    expect(result.entries.every((e) => e.hostname == 'example.com'), isTrue);
    expect(result.entries.every((e) => e.port == 2200), isTrue);
  });

  test('a wildcard Host pattern is skipped, with a warning', () {
    final result = SshConfigParser.parse('''
Host *.example.com
  User ignored

Host real
  HostName example.com
''');
    expect(result.entries, hasLength(1));
    expect(result.entries.single.alias, 'real');
    expect(result.warnings, isNotEmpty);
    expect(result.warnings.single, contains('*.example.com'));
  });

  test('a bare "Host *" block is skipped entirely and its directives with it',
      () {
    final result = SshConfigParser.parse('''
Host *
  ServerAliveInterval 60

Host real
  HostName example.com
''');
    expect(result.entries, hasLength(1));
    expect(result.entries.single.alias, 'real');
  });

  test('ProxyJump is captured on the entry, not folded into anything else',
      () {
    final result = SshConfigParser.parse('''
Host internal
  HostName 10.0.0.9
  ProxyJump bastion.example.com
''');
    expect(result.entries.single.proxyJump, 'bastion.example.com');
  });

  test('unsupported directives are ignored without raising an error', () {
    final result = SshConfigParser.parse('''
Host myserver
  HostName example.com
  Compression yes
  ServerAliveInterval 60
''');
    expect(result.entries.single.hostname, 'example.com');
  });

  test('a Match block ends the Host above it, and its directives go nowhere',
      () {
    final result = SshConfigParser.parse('''
Host build
  HostName build.example.com
  User dev

Match host build exec "test -n \$VPN"
  ForwardAgent yes
  ForwardX11 yes
  User root
  Port 2200
  IdentityFile ~/.ssh/vpn_key

Host other
  ForwardAgent yes
''');
    final build = result.entries.firstWhere((e) => e.alias == 'build');
    expect(build.forwardAgent, isFalse,
        reason: 'ForwardAgent under Match is conditional, not the host\'s');
    expect(build.forwardX11, isFalse);
    expect(build.user, 'dev');
    expect(build.port, 22);
    expect(build.identityFile, isNull);
    // The next Host starts a block of its own as usual.
    expect(result.entries.firstWhere((e) => e.alias == 'other').forwardAgent,
        isTrue);
    expect(result.entries, hasLength(2));
    expect(result.warnings.single, contains('Match'));
  });

  test('a directive before any Host block is ignored', () {
    final result = SshConfigParser.parse('''
HostName orphan.example.com

Host myserver
  HostName example.com
''');
    expect(result.entries, hasLength(1));
    expect(result.entries.single.hostname, 'example.com');
  });

  test('Include reads through the callback and merges its entries', () {
    final result = SshConfigParser.parse(
      '''
Host outer
  HostName outer.example.com

Include conf.d/extra

Host after
  HostName after.example.com
''',
      readInclude: (path) {
        expect(path, 'conf.d/extra');
        return '''
Host included
  HostName included.example.com
''';
      },
    );
    expect(
      result.entries.map((e) => e.alias),
      ['outer', 'included', 'after'],
    );
  });

  test('a missing Include target is skipped with a warning, not an error',
      () {
    final result = SshConfigParser.parse(
      '''
Host myserver
  HostName example.com

Include missing.conf
''',
      readInclude: (path) => null,
    );
    expect(result.entries, hasLength(1));
    expect(result.warnings.single, contains('missing.conf'));
  });

  test('Include with no readInclude callback is skipped, not a crash', () {
    final result = SshConfigParser.parse('''
Host myserver
  HostName example.com

Include conf.d/extra
''');
    expect(result.entries, hasLength(1));
    expect(result.warnings, isNotEmpty);
  });

  test('an Include found inside an included file is not itself followed',
      () {
    final result = SshConfigParser.parse(
      '''
Host outer
  HostName outer.example.com

Include level1.conf
''',
      readInclude: (path) {
        if (path == 'level1.conf') {
          return '''
Host fromLevel1
  HostName one.example.com

Include level2.conf
''';
        }
        fail('level2.conf must not be read — Include is one level deep');
      },
    );
    expect(result.entries.map((e) => e.alias), ['outer', 'fromLevel1']);
  });

  test('the full fixture parses every directive at once', () {
    const fixture = '''
# Personal ssh config
Host home
  HostName 192.168.1.10
  User    pi
  Port=2222
  IdentityFile ~/.ssh/id_home

Host   bastion  jump-box
  HostName bastion.example.com
  User admin

Host internal
  HostName 10.0.0.20
  ProxyJump bastion.example.com
  # trailing comment inside the block

# a wildcard block that must be skipped entirely
Host *.internal.example.com
  User should-not-appear

Include extras.conf
''';

    final result = SshConfigParser.parse(
      fixture,
      readInclude: (path) {
        expect(path, 'extras.conf');
        return '''
Host fromInclude
  HostName included.example.com
  User dev
''';
      },
    );

    final byAlias = {for (final e in result.entries) e.alias: e};

    expect(byAlias.keys, {
      'home',
      'bastion',
      'jump-box',
      'internal',
      'fromInclude',
    });

    expect(byAlias['home']!.hostname, '192.168.1.10');
    expect(byAlias['home']!.user, 'pi');
    expect(byAlias['home']!.port, 2222);
    expect(byAlias['home']!.identityFile, '~/.ssh/id_home');

    expect(byAlias['bastion']!.hostname, 'bastion.example.com');
    expect(byAlias['jump-box']!.hostname, 'bastion.example.com');
    expect(byAlias['bastion']!.user, 'admin');

    expect(byAlias['internal']!.proxyJump, 'bastion.example.com');

    expect(byAlias['fromInclude']!.hostname, 'included.example.com');

    expect(
      result.warnings.any((w) => w.contains('*.internal.example.com')),
      isTrue,
    );
  });

  group('forwarding and certificates', () {
    test('ForwardAgent, ForwardX11 and CertificateFile are read', () {
      final entry = SshConfigParser.parse('''
Host build
  HostName build.example.com
  ForwardAgent yes
  ForwardX11 yes
  CertificateFile ~/.ssh/id_ed25519-cert.pub
''').entries.single;
      expect(entry.forwardAgent, isTrue);
      expect(entry.forwardX11, isTrue);
      expect(entry.certificateFile, '~/.ssh/id_ed25519-cert.pub');
    });

    test('all off unless asked for', () {
      final entry = SshConfigParser.parse('Host plain\n').entries.single;
      expect(entry.forwardAgent, isFalse);
      expect(entry.forwardX11, isFalse);
      expect(entry.certificateFile, isNull);
    });

    test('ForwardAgent names an agent socket, or says no', () {
      final entries = SshConfigParser.parse('''
Host a
  ForwardAgent ~/.1password/agent.sock
Host b
  ForwardAgent no
Host c
  ForwardAgent=Yes
  ForwardX11 no
''').entries;
      expect(entries.map((e) => e.forwardAgent), [true, false, true]);
      expect(entries.last.forwardX11, isFalse);
    });

    test('the first of several CertificateFile lines is the one kept', () {
      final entry = SshConfigParser.parse('''
Host ca
  CertificateFile ~/.ssh/first-cert.pub
  CertificateFile ~/.ssh/second-cert.pub
''').entries.single;
      expect(entry.certificateFile, '~/.ssh/first-cert.pub');
    });

    test('toHost carries them onto the saved host', () {
      final entry = SshConfigParser.parse('''
Host build
  HostName build.example.com
  Port 2200
  IdentityFile ~/.ssh/id_ed25519
  ForwardAgent yes
  ForwardX11 yes
''').entries.single;
      final host = entry.toHost(
        id: 'h1',
        username: 'dev',
        certificate: 'ssh-ed25519-cert-v01@openssh.com AAAA',
      );
      expect(host.label, 'build');
      expect(host.hostname, 'build.example.com');
      expect(host.port, 2200);
      expect(host.username, 'dev');
      expect(host.authMethod, SshAuthMethod.privateKey);
      expect(host.agentForwarding, isTrue);
      expect(host.x11Forwarding, isTrue);
      expect(host.certificate, 'ssh-ed25519-cert-v01@openssh.com AAAA');
    });

    test('a host with no key file still signs in with a password', () {
      final host = SshConfigParser.parse('Host p\n').entries.single.toHost(
            id: 'h2',
            username: 'dev',
          );
      expect(host.authMethod, SshAuthMethod.password);
      expect(host.certificate, isNull);
    });
  });
}
