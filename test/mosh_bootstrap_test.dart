import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/mosh/mosh_bootstrap.dart';
import 'package:secure_shell_go/services/mosh/mosh_shell.dart';
import 'package:secure_shell_go/services/remote_exec.dart';

/// Starting `mosh-server` and finding it again over UDP.
void main() {
  ExecResult result(String stdout, [String stderr = '', int? exitCode = 0]) =>
      ExecResult(stdout: stdout, stderr: stderr, exitCode: exitCode);

  group('reading what mosh-server said', () {
    test('a started server: port, key, pid and where SSH arrived', () {
      final info = parseMoshServerOutput(
        result(
          'MOSH SSH_CONNECTION 10.0.0.5 51234 192.168.1.20 22\n'
              '\r\nMOSH CONNECT 60004 r9psjw/tvBdRXWy9Y7w9sw\r\n',
          '\nmosh-server (mosh 1.4.0) [build mosh 1.4.0]\n'
              '[mosh-server detached, pid = 4242]\n',
        ),
      );
      expect(info.port, 60004);
      expect(info.key, 'r9psjw/tvBdRXWy9Y7w9sw');
      expect(info.pid, 4242);
      expect(info.sshConnection, '10.0.0.5 51234 192.168.1.20 22');
    });

    test('noise from login scripts around it does not matter', () {
      final info = parseMoshServerOutput(
        result(
          'Welcome!\nMOSH SSH_CONNECTION \nMOSH CONNECT 60001 '
          'AAAAAAAAAAAAAAAAAAAAAA\nbye\n',
        ),
      );
      expect(info.port, 60001);
      expect(info.pid, isNull);
      expect(info.sshConnection, isNull);
    });

    test('not installed', () {
      expect(
        () => parseMoshServerOutput(
          result('MOSH SSH_CONNECTION x\nMOSH SERVER NOT FOUND\n', '', 127),
        ),
        throwsA(
          isA<MoshStartException>()
              .having((e) => e.kind, 'kind', MoshStartFailure.notInstalled)
              .having(
                (e) => e.message,
                'message',
                'mosh-server is not installed on this host.',
              ),
        ),
      );
      expect(
        () => parseMoshServerOutput(
          result('', 'sh: 1: exec: /opt/mosh-server: not found\n', 127),
        ),
        throwsA(
          isA<MoshStartException>().having(
            (e) => e.kind,
            'kind',
            MoshStartFailure.notInstalled,
          ),
        ),
      );
    });

    test('no UTF-8 locale', () {
      expect(
        () => parseMoshServerOutput(
          result(
            '',
            'mosh-server needs a UTF-8 native locale to run.\n\n'
                'Unfortunately, the local environment ([no charset variables]) '
                'specifies\nthe character set "US-ASCII",\n',
            1,
          ),
        ),
        throwsA(
          isA<MoshStartException>().having(
            (e) => e.kind,
            'kind',
            MoshStartFailure.locale,
          ),
        ),
      );
    });

    test('anything else quotes the last thing it said', () {
      expect(
        () => parseMoshServerOutput(
          result(
            '',
            'Error binding to IP 1.2.3.4: bind: Cannot assign requested address\n'
                'Network exception: bind: Address already in use\n',
            1,
          ),
        ),
        throwsA(
          isA<MoshStartException>()
              .having((e) => e.kind, 'kind', MoshStartFailure.failed)
              .having(
                (e) => e.message,
                'message',
                'mosh-server did not start: Network exception: bind: '
                    'Address already in use',
              ),
        ),
      );
      expect(
        () => parseMoshServerOutput(result('', '', 3)),
        throwsA(
          isA<MoshStartException>().having(
            (e) => e.message,
            'message',
            'mosh-server did not start (exit status 3).',
          ),
        ),
      );
    });
  });

  group('the command', () {
    final skip = Platform.isWindows ? 'needs a POSIX sh' : null;
    late Directory dir;

    setUp(() {
      if (skip != null) return;
      dir = Directory.systemTemp.createTempSync('ssgo-mosh-cmd');
      addTearDown(() => dir.deleteSync(recursive: true));
    });

    Future<ProcessResult> runUnderSh(String command, {String? path}) =>
        Process.run(
          '/bin/sh',
          ['-c', command],
          environment: {
            'PATH': path ?? '${dir.path}:/usr/bin:/bin',
            'SSH_CONNECTION': '10.0.0.5 51234 192.168.1.20 22',
          },
          includeParentEnvironment: false,
        );

    test(
      'runs mosh-server with Mosh\'s own arguments, quoting intact',
      () async {
        final fake = File('${dir.path}/mosh-server')
          ..writeAsStringSync(
            '#!/bin/sh\nfor a in "\$@"; do echo "[\$a]"; done\n',
          );
        await Process.run('chmod', ['+x', fake.path]);

        final out = await runUnderSh(
          moshServerCommand(
            locale: 'en_GB.UTF-8',
            command: r"""exec sh -c 'echo "it'\''s $HOME"'""",
          ),
        );
        expect(out.exitCode, 0);
        expect('${out.stdout}'.split('\n'), [
          'MOSH SSH_CONNECTION 10.0.0.5 51234 192.168.1.20 22',
          '[new]',
          '[-s]',
          '[-c]',
          '[256]',
          '[-l]',
          '[LANG=en_GB.UTF-8]',
          '[--]',
          '[sh]',
          '[-c]',
          r"""[exec sh -c 'echo "it'\''s $HOME"']""",
          '',
        ]);
      },
      skip: skip,
    );

    test(
      'says so when mosh-server is nowhere to be found',
      () async {
        // A PATH with nothing on it but sh.
        Link('${dir.path}/sh').createSync('/bin/sh');
        final out = await runUnderSh(
          moshServerCommand(locale: 'C.UTF-8'),
          path: dir.path,
        );
        expect(out.exitCode, 127);
        expect(out.stdout, contains('MOSH SERVER NOT FOUND'));
      },
      skip:
          skip ??
          (moshServerSearchPath.any(
                (p) => p.startsWith('/') && File(p).existsSync(),
              )
              ? 'mosh-server is installed here'
              : null),
    );

    test('a server command of the caller\'s choosing is used as is', () {
      expect(
        moshServerCommand(
          locale: 'C.UTF-8',
          server: '/opt/mosh/bin/mosh-server',
        ),
        contains('exec /opt/mosh/bin/mosh-server new -s -c 256'),
      );
    });
  });

  test('locales: the device\'s first, then C.UTF-8, then en_US', () {
    expect(moshLocales('de_DE'), ['de_DE.UTF-8', 'C.UTF-8', 'en_US.UTF-8']);
    expect(moshLocales('pt-BR'), ['pt_BR.UTF-8', 'C.UTF-8', 'en_US.UTF-8']);
    expect(moshLocales('en_US.UTF-8'), ['en_US.UTF-8', 'C.UTF-8']);
    expect(moshLocales('C'), ['C.UTF-8', 'en_US.UTF-8']);
  });

  group('the UDP address', () {
    Future<List<InternetAddress>> Function(String) resolvesTo(
      List<String> addresses,
    ) =>
        (_) async => [for (final a in addresses) InternetAddress(a)];

    test('an address typed in is used as is', () async {
      expect((await moshServerAddress('192.0.2.7')).address, '192.0.2.7');
      expect((await moshServerAddress('[2001:db8::1]')).address, '2001:db8::1');
    });

    test(
      'the address the host saw SSH arrive on, when the name has it',
      () async {
        final address = await moshServerAddress(
          'box.example',
          sshConnection: '10.0.0.5 51234 2001:db8::7 22',
          lookup: resolvesTo(['192.0.2.7', '2001:db8::7']),
        );
        expect(address.address, '2001:db8::7');
      },
    );

    test('behind NAT, the name\'s own address of the same family', () async {
      final address = await moshServerAddress(
        'box.example',
        sshConnection: '10.0.0.5 51234 192.168.1.20 22',
        lookup: resolvesTo(['2001:db8::7', '198.51.100.9']),
      );
      expect(address.address, '198.51.100.9');
    });

    test('a name this device cannot resolve falls back to what the host '
        'reported', () async {
      final address = await moshServerAddress(
        'internal.lan',
        sshConnection: '10.0.0.5 51234 ::ffff:10.1.2.3 22',
        lookup: (_) async => throw const SocketException('no such host'),
      );
      expect(address.address, '10.1.2.3');
      expect(address.type, InternetAddressType.IPv4);
    });
  });

  test('the fallback notice is one line saying why', () {
    expect(
      moshFallbackNotice(
        const MoshStartException(
          MoshStartFailure.notInstalled,
          'mosh-server is not installed on this host.',
        ),
      ),
      'mosh-server is not installed on this host. Using SSH for this '
      'terminal.',
    );
    expect(
      moshFallbackNotice(const MoshUnreachableException('No reply over UDP')),
      'No reply over UDP. Using SSH for this terminal.',
    );
  });
}
