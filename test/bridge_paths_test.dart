import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/bridge/bridge_paths.dart';

void main() {
  final guard = BridgePathGuard(readSensitivePaths: false);

  void blocked(String path, [BridgePathGuard? g]) =>
      expect((g ?? guard).isBlocked(path), isTrue, reason: path);
  void allowed(String path, [BridgePathGuard? g]) =>
      expect((g ?? guard).isBlocked(path), isFalse, reason: path);

  group('built-in list', () {
    test('every built-in pattern blocks a path it names', () {
      for (final path in [
        '/home/u/.ssh/id_ed25519',
        '/home/u/.ssh/authorized_keys',
        '/root/.gnupg/private-keys-v1.d/x.key',
        '/srv/app/.env',
        '/srv/app/.env.production',
        '/etc/shadow',
        '/etc/shadow-',
        '/etc/gshadow',
        '/etc/sudoers',
        '/etc/sudoers.d/90-cloud-init',
        '/etc/ssh/ssh_host_ed25519_key',
        '/etc/ssh/ssh_host_rsa_key',
        '/home/u/backup/id_rsa',
        '/home/u/backup/id_rsa.pub',
        '/tmp/id_ed25519_old',
        '/tmp/id_ecdsa',
        '/tmp/id_dsa',
        '/etc/ssl/private/site.pem',
        '/etc/ssl/private/site.key',
        '/home/u/cert.p12',
        '/home/u/cert.pfx',
        '/home/u/passwords.kdbx',
        '/home/u/.aws/credentials',
        '/home/u/.kube/config',
        '/home/u/.netrc',
        '/var/lib/postgresql/.pgpass',
        '/home/u/.docker/config.json',
        '/home/u/.git-credentials',
        '/proc/1/environ',
        '/proc/self/environ',
        '/proc/1/task/7/environ',
      ]) {
        blocked(path);
      }
    });

    test('ordinary files are allowed', () {
      for (final path in [
        '/',
        '/etc',
        '/etc/passwd',
        '/etc/hosts',
        '/etc/ssh/sshd_config',
        '/etc/ssh/ssh_host_ed25519_key.pub',
        '/var/log/syslog',
        '/home/u',
        '/home/u/notes.txt',
        '/proc/1/status',
        '/proc/cpuinfo',
        '/etc/sudoers.bak.txt.d',
      ]) {
        allowed(path);
      }
    });

    test('names that merely contain a blocked word are allowed', () {
      for (final path in [
        '/srv/app/keynote.txt',
        '/srv/app/monkey',
        '/srv/app/key',
        '/srv/app/x.keys',
        '/srv/app/x.key.txt',
        '/srv/app/x.pem.bak',
        '/srv/app/environment',
        '/srv/app/.envrc',
        '/srv/app/my.env',
        '/srv/app/sshd/notes',
        '/srv/app/.ssh_backup/notes',
        '/srv/app/ssh/config',
        '/srv/app/kube/config',
        '/srv/app/.kube/config.d',
        '/srv/app/shadow',
        '/etc/shadow.md/../motd',
        '/srv/notid_rsa',
        '/home/u/.netrc.example/../x',
      ]) {
        allowed(path);
      }
    });

    test('a blocked directory itself is blocked, not only its files', () {
      blocked('/home/u/.ssh');
      blocked('/home/u/.ssh/');
      blocked('/home/u/.gnupg');
      blocked('/etc/sudoers.d');
      blocked('/etc/sudoers.d/');
    });

    test('anything under a blocked file name is blocked too', () {
      // A directory whose name matches a file pattern is closed with its
      // contents: the guard errs towards refusing.
      blocked('/srv/x.key/inside.txt');
      blocked('/srv/app/.env/inner');
      blocked('/home/u/.ssh/sub/dir/deep/file');
    });

    test('parents of a blocked directory stay open', () {
      allowed('/home/u');
      allowed('/home');
      allowed('/etc/ssh');
    });
  });

  group('normalisation', () {
    test('dot and dot-dot segments cannot sneak past', () {
      blocked('/home/u/./.ssh/id_rsa');
      blocked('/home/u/docs/../.ssh/id_rsa');
      blocked('/home/u/.ssh/../.ssh/config');
      blocked('/tmp/../etc/shadow');
      blocked('/../../../etc/shadow');
      blocked('/etc/./shadow');
      blocked('/etc/x/../shadow');
      // And collapsing out of a blocked directory really leaves it.
      allowed('/home/u/.ssh/../notes.txt');
    });

    test('doubled and trailing slashes do not matter', () {
      blocked('//etc//shadow');
      blocked('/etc/shadow/');
      blocked('/etc/shadow//');
      blocked('///home///u///.ssh///id_rsa');
      allowed('//etc//hosts//');
    });

    test('canonicalSegments', () {
      expect(BridgePathGuard.canonicalSegments('/'), isEmpty);
      expect(BridgePathGuard.canonicalSegments('/a/./b/../c//d/'), [
        'a',
        'c',
        'd',
      ]);
      expect(BridgePathGuard.canonicalSegments('/..'), isEmpty);
      expect(BridgePathGuard.canonicalSegments('a/b'), isNull);
      expect(BridgePathGuard.canonicalSegments(''), isNull);
    });
  });

  group('input that is refused outright', () {
    test('relative paths are blocked, even harmless-looking ones', () {
      blocked('etc/hosts');
      blocked('notes.txt');
      blocked('./notes.txt');
      blocked('../etc/passwd');
      blocked('~/notes.txt');
      blocked('.');
      blocked('');
      blocked(' /etc/hosts');
    });

    test('a NUL character is blocked', () {
      blocked('/srv/app/notes.txt\u0000.key');
      blocked('/home/u/.ssh\u0000/../notes');
      blocked('/etc/hosts\u0000');
    });

    test('very long paths: up to the limit judged, past it refused', () {
      final segment = 'a' * 200;
      var path = '';
      while (path.length + segment.length + 1 <= 4000) {
        path = '$path/$segment';
      }
      allowed(path);
      blocked('$path/.ssh');
      blocked('/${'a' * BridgePathGuard.maxPathBytes}');
    });

    test('the byte limit counts UTF-8 bytes, not characters', () {
      // é is two bytes: 2100 of them are 4201 bytes, 2000 are 4001.
      blocked('/${'é' * 2100}');
      allowed('/${'é' * 2000}');
    });

    test('many segments with many stars do not blow up', () {
      final g = BridgePathGuard(
        readSensitivePaths: false,
        extraPatterns: ['/**/a*a*a*a*a*a*b/**/c/**/d'],
      );
      final path = '/${List.filled(1500, 'a').join('/')}';
      final watch = Stopwatch()..start();
      allowed(path, g);
      blocked('$path/aaaaaaab/c/d', g);
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    });
  });

  group('case and unicode', () {
    test('matching is case-sensitive, as POSIX is', () {
      allowed('/etc/Shadow');
      allowed('/etc/SHADOW');
      allowed('/home/u/.SSH/notes.txt');
      allowed('/home/u/server.KEY');
      allowed('/home/u/ID_RSA');
      blocked('/home/u/.ssh/ID_RSA');
    });

    test('unicode names are matched exactly', () {
      allowed('/home/ü/notes.txt');
      blocked('/home/ü/.ssh/id_rsa');
      blocked('/home/u/clé.pem');
      blocked('/home/u/🔑.key');
      allowed('/home/u/🔑.key.txt');
      // Look-alikes are different files on POSIX, not the blocked one.
      allowed('/home/u/.sѕh/notes.txt'); // Cyrillic s
    });
  });

  group('histories, tokens and other credentials', () {
    test('each added pattern blocks what it names', () {
      for (final path in [
        '/home/u/.bash_history',
        '/root/.zsh_history',
        '/home/u/.sh_history',
        '/home/u/.python_history',
        '/home/u/.mysql_history',
        '/var/lib/postgresql/.psql_history',
        '/home/u/.rediscli_history',
        '/home/u/.npmrc',
        '/srv/app/.npmrc',
        '/home/u/.pypirc',
        '/home/u/.config/gh',
        '/home/u/.config/gh/hosts.yml',
        '/home/u/.config/gcloud/credentials.db',
        '/home/u/.config/gcloud/legacy_credentials/x/adc.json',
        '/home/u/.azure',
        '/home/u/.azure/msal_token_cache.json',
        '/etc/security/opasswd',
        '/home/u/keys/server.ppk',
        '/srv/app/.git/config',
        '/var/www/.htpasswd',
        '/home/u/.my.cnf',
      ]) {
        blocked(path);
      }
    });

    test('near misses stay readable', () {
      for (final path in [
        '/home/u/history.txt',
        '/home/u/.bash_history.d/../notes',
        '/home/u/bash_history',
        '/home/u/.bash_profile',
        '/home/u/.zshrc',
        '/srv/app/.gitignore',
        '/srv/app/.git/HEAD',
        '/srv/app/.git/refs/heads/main',
        '/srv/app/.gitconfig.example',
        '/srv/app/git/config',
        '/home/u/.config/ghostty/config',
        '/home/u/.config/gh-dash/config.yml',
        '/home/u/.config/gcloud-notes.txt',
        '/home/u/azure/readme',
        '/home/u/.azure-pipelines.yml',
        '/srv/app/npmrc.md',
        '/srv/app/.npmrc.example',
        '/srv/app/pypirc.md',
        '/etc/security/limits.conf',
        '/etc/opasswd',
        '/home/u/keys/server.ppk.txt',
        '/var/www/htpasswd.md',
        '/home/u/my.cnf',
        '/etc/mysql/my.cnf',
      ]) {
        allowed(path);
      }
    });

    test('readSensitivePaths opens them like the rest of the list', () {
      final open = BridgePathGuard(readSensitivePaths: true);
      allowed('/home/u/.bash_history', open);
      allowed('/srv/app/.git/config', open);
    });
  });

  group('readSensitivePaths and extras', () {
    test('readSensitivePaths sets the built-in list aside', () {
      final open = BridgePathGuard(readSensitivePaths: true);
      allowed('/etc/shadow', open);
      allowed('/home/u/.ssh/id_rsa', open);
      allowed('/home/u/.ssh', open);
    });

    test('readSensitivePaths still refuses relative or NUL input', () {
      final open = BridgePathGuard(readSensitivePaths: true);
      blocked('etc/shadow', open);
      blocked('/etc/hosts\u0000', open);
    });

    test('extras apply whether or not readSensitivePaths is on', () {
      for (final sensitive in [false, true]) {
        final g = BridgePathGuard(
          readSensitivePaths: sensitive,
          extraPatterns: ['/srv/secrets', '*.sql', '/opt/app/conf/*.yaml'],
        );
        blocked('/srv/secrets', g);
        blocked('/srv/secrets/', g);
        blocked('/srv/secrets/db/password.txt', g);
        blocked('/srv/../srv/secrets/x', g);
        blocked('/var/backups/dump.sql', g);
        blocked('/dump.sql', g);
        blocked('/opt/app/conf/prod.yaml', g);
        allowed('/opt/app/conf/sub/prod.yaml', g);
        allowed('/srv/secrets-public/readme', g);
        allowed('/var/backups/dump.sql.gz', g);
        expect(g.isBlocked('/etc/shadow'), !sensitive);
      }
    });

    test('extra patterns are tidied: blanks ignored, trailing slash, ~/', () {
      final g = BridgePathGuard(
        readSensitivePaths: true,
        extraPatterns: ['', '   ', '/srv/private/', '~/.config/app', ' notes '],
      );
      allowed('/etc/hosts', g);
      allowed('/', g);
      blocked('/srv/private', g);
      blocked('/srv/private/a', g);
      blocked('/home/u/.config/app/token', g);
      blocked('/root/.config/app', g);
      blocked('/home/u/notes', g);
      allowed('/home/u/notes.txt', g);
    });

    test('an extra of / alone does not silently block everything', () {
      final g = BridgePathGuard(readSensitivePaths: true, extraPatterns: ['/']);
      allowed('/etc/hosts', g);
    });

    test('an extra with dot-dot is resolved, not left unmatched', () {
      final g = BridgePathGuard(
        readSensitivePaths: true,
        extraPatterns: ['/srv/app/../secrets/**'],
      );
      blocked('/srv/secrets/x', g);
    });

    test('normalizePattern', () {
      expect(BridgePathGuard.normalizePattern('*.sql'), '/**/*.sql');
      expect(BridgePathGuard.normalizePattern('/a/b'), '/a/b');
      expect(BridgePathGuard.normalizePattern('~/x'), '/**/x');
      expect(BridgePathGuard.normalizePattern('**/x'), '/**/**/x');
      expect(BridgePathGuard.normalizePattern('  '), '');
    });

    test('a leading ** extra matches at the root as well', () {
      final g = BridgePathGuard(
        readSensitivePaths: true,
        extraPatterns: ['**/vault'],
      );
      blocked('/vault', g);
      blocked('/a/b/vault/c', g);
      allowed('/a/b/vaults', g);
    });
  });
}
