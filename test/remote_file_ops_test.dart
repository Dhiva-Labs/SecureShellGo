import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/remote_file_ops.dart';
import 'package:secure_shell_go/services/server_side_job.dart';

import 'fake_exec_session.dart';

/// Names that are legal on every unix and that each break a command built
/// carelessly: read as an option, split on a space, end a quote early, run
/// a command, or expand as a glob.
const _hostile = [
  '-rf',
  '--help',
  'with space',
  "it's",
  'say "hi"',
  'new\nline',
  '*',
  r'$(touch PWNED1)',
  '`touch PWNED2`',
  ';touch PWNED3;',
  r'back\slash',
  'ünï ✓',
];

const _gnu = RemoteToolkit(
  tools: {
    'tar': ToolFlavour.gnu,
    'gzip': ToolFlavour.gnu,
    'xz': ToolFlavour.other,
    'zip': ToolFlavour.infozip,
    'unzip': ToolFlavour.infozip,
    'find': ToolFlavour.gnu,
    'grep': ToolFlavour.gnu,
    'cp': ToolFlavour.gnu,
    'chown': ToolFlavour.gnu,
  },
  tarGzip: true,
  tarXz: true,
);

/// BusyBox as a small box often has it: tar without gzip or xz built in,
/// so both go through the separate programs.
const _busybox = RemoteToolkit(
  tools: {
    'tar': ToolFlavour.busybox,
    'gzip': ToolFlavour.busybox,
    'xz': ToolFlavour.busybox,
    'unzip': ToolFlavour.busybox,
    'find': ToolFlavour.busybox,
    'grep': ToolFlavour.busybox,
    'cp': ToolFlavour.busybox,
    'chown': ToolFlavour.busybox,
  },
);

final bool _posix = Platform.isLinux || Platform.isMacOS;

bool _onPath(String tool) =>
    _posix && Process.runSync('sh', ['-c', 'command -v $tool']).exitCode == 0;

final bool _hasBusybox = _onPath('busybox');
final bool _hasZip = _onPath('zip') && _onPath('unzip');

void main() {
  tearDownAll(() async {
    for (final bin in _busyboxBinPaths.values) {
      if (Directory(bin).existsSync()) await Directory(bin).delete(recursive: true);
    }
  });

  group('probe', () {
    test('reads tools, flavours and what tar can do', () {
      final kit = RemoteToolkit.parse(
        'tool tar busybox\n'
        'tool gzip busybox\n'
        'tool find gnu\n'
        'tool grep bsd\n'
        'tool unzip infozip\n'
        'tool bogus gnu\n'
        'tar-gzip\n'
        'end\n',
      );
      expect(kit.flavourOf('tar'), ToolFlavour.busybox);
      expect(kit.flavourOf('find'), ToolFlavour.gnu);
      expect(kit.has('bogus'), isFalse);
      expect(kit.tarGzip, isTrue);
      expect(kit.tarXz, isFalse);
      expect(kit.findPrintf, isTrue);
      expect(kit.grepNulNames, isFalse, reason: "BSD grep's -Z decompresses");
      expect(kit.compressFormats, [ArchiveFormat.tarGz]);
      expect(kit.canExtract(ArchiveKind.zip), isTrue);
      expect(kit.canExtract(ArchiveKind.tarXz), isFalse,
          reason: 'no -J in tar and no xz to pipe through');
      expect(kit.canDuplicate, isFalse);
    });

    test('tar-gzip means nothing without a tar', () {
      expect(RemoteToolkit.parse('tar-gzip\ntar-xz\n').tarGzip, isFalse);
    });

    test('a server that cannot run it can do none of it', () async {
      final transport = FakeExecTransport()..failWith = StateError('no exec');
      final kit = await RemoteToolkit.probe(transport);
      expect(kit.tools, isEmpty);
      expect(kit.compressFormats, isEmpty);
      expect(kit.canSearch, isFalse);
    });

    test('against this machine\'s own tools', () async {
      final result = await Process.run('sh', ['-c', RemoteToolkit.probeCommand]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final kit = RemoteToolkit.parse(result.stdout as String);
      expect(kit.has('tar'), isTrue);
      final version = Process.runSync('tar', ['--version']).stdout as String;
      if (version.contains('GNU')) {
        expect(kit.flavourOf('tar'), ToolFlavour.gnu);
        expect(kit.tarGzip, isTrue);
        expect(kit.tarXz, isTrue);
      }
      if (_hasZip) expect(kit.flavourOf('zip'), ToolFlavour.infozip);
    }, skip: !_posix);

    test('against a BusyBox userland', () async {
      final bin = await _busyboxBin();
      final result = await Process.run(
        'busybox',
        ['sh', '-c', RemoteToolkit.probeCommand],
        environment: {'PATH': bin},
      );
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final kit = RemoteToolkit.parse(result.stdout as String);
      for (final tool in ['tar', 'gzip', 'xz', 'unzip', 'find', 'grep', 'cp', 'chown']) {
        expect(kit.flavourOf(tool), ToolFlavour.busybox, reason: tool);
      }
      expect(kit.has('zip'), isFalse, reason: 'BusyBox has no zip applet');
      expect(kit.compressFormats, [ArchiveFormat.tarGz]);
      expect(kit.findPrintf, isFalse);
      expect(kit.grepNulNames, isFalse);
      // This BusyBox was built with both; the pipe fallback is exercised
      // below with a toolkit that says otherwise.
      expect(kit.tarGzip, isTrue);
      expect(kit.tarXz, isTrue);
    }, skip: !_hasBusybox);
  });

  group('archive names', () {
    test('kinds by suffix, case-blind', () {
      expect(ArchiveKind.of('site.tar.gz'), ArchiveKind.tarGz);
      expect(ArchiveKind.of('SITE.TGZ'), ArchiveKind.tarGz);
      expect(ArchiveKind.of('a.tar.xz'), ArchiveKind.tarXz);
      expect(ArchiveKind.of('a.txz'), ArchiveKind.tarXz);
      expect(ArchiveKind.of('a.tar'), ArchiveKind.tar);
      expect(ArchiveKind.of('a.zip'), ArchiveKind.zip);
      expect(ArchiveKind.of('a.gz'), isNull);
      expect(ArchiveKind.of('.zip'), isNull);
      expect(ArchiveKind.stem('site.tar.gz'), 'site');
      expect(ArchiveKind.stem('backup.2026.zip'), 'backup.2026');
    });

    test('copy names keep the extension last and skip what is taken', () {
      final taken = {'report copy.pdf', 'report copy 2.pdf'};
      expect(
        RemoteFileCommands.copyName('report.pdf', taken.contains),
        'report copy 3.pdf',
      );
      expect(RemoteFileCommands.copyName('site.tar.gz', (_) => false),
          'site copy.tar.gz');
      expect(RemoteFileCommands.copyName('.bashrc', (_) => false),
          '.bashrc copy');
      expect(
        RemoteFileCommands.copyName('v1.2', (_) => false, isDirectory: true),
        'v1.2 copy',
      );
    });
  });

  group('owner names', () {
    test('what may be an owner or a group', () {
      expect(RemoteFileCommands.ownerProblem(''), isNull);
      expect(RemoteFileCommands.ownerProblem('www-data'), isNull);
      expect(RemoteFileCommands.ownerProblem('1000'), isNull);
      expect(RemoteFileCommands.ownerProblem(r'HOST$'), isNull);
      expect(RemoteFileCommands.ownerProblem('jo@corp.example'), isNull);
      expect(RemoteFileCommands.ownerProblem('-R'), isNotNull);
      expect(RemoteFileCommands.ownerProblem('root:wheel'), isNotNull);
      expect(RemoteFileCommands.ownerProblem('a b'), isNotNull);
      expect(RemoteFileCommands.ownerProblem("x';id;'"), isNotNull);
      expect(RemoteFileCommands.ownerProblem('a' * 65), isNotNull);
    });

    test('owner:group, owner, or :group', () {
      expect(RemoteFileCommands.ownerSpec('www', 'web'), 'www:web');
      expect(RemoteFileCommands.ownerSpec('www', ''), 'www');
      expect(RemoteFileCommands.ownerSpec('', 'web'), ':web');
      expect(RemoteFileCommands.ownerSpec(' ', ' '), isNull);
    });

    test('reads ls -ld', () {
      expect(
        RemoteFileCommands.parseOwner(
          'drwxr-x--- 2 www-data adm 4096 Oct 21 10:00 /var/log/a b\n',
        ),
        (owner: 'www-data', group: 'adm'),
      );
      expect(RemoteFileCommands.parseOwner(''), isNull);
    });
  });

  group('command strings', () {
    test('compress, GNU tar.gz', () {
      final script = RemoteFileCommands.compress(
        directory: '/srv/a b',
        names: ['-rf', "it's"],
        archiveName: 'out.tar.gz',
        partName: '.out.tar.gz.ssg-part-1',
        format: ArchiveFormat.tarGz,
        tools: _gnu,
      );
      expect(script, '''
d="\$1"
cd '/srv/a b' || exit 71
if [ -e './out.tar.gz' ] || [ -L './out.tar.gz' ]; then echo "The archive's name is taken." >&2; exit 17; fi
if tar -czf './.out.tar.gz.ssg-part-1' './-rf' './it'\\''s'; then :; else s=\$?; rm -f './.out.tar.gz.ssg-part-1'; exit \$s; fi
if [ -e './out.tar.gz' ] || [ -L './out.tar.gz' ]; then rm -f './.out.tar.gz.ssg-part-1'; echo "The archive's name is taken." >&2; exit 17; fi
if [ -d "\$d" ]; then :; else rm -f './.out.tar.gz.ssg-part-1'; exit 143; fi
mv -f './.out.tar.gz.ssg-part-1' './out.tar.gz\'''');
    });

    test('compress through gzip when tar has no -z', () {
      final script = RemoteFileCommands.compress(
        directory: '/srv',
        names: ['site'],
        archiveName: 'site.tar.gz',
        partName: '.p',
        format: ArchiveFormat.tarGz,
        tools: _busybox,
      );
      expect(
        script,
        contains(
          "if { tar -cf - './site'; echo \$? > \"\$d/st\"; } | gzip -c > './.p'"
          ' && [ "\$(cat "\$d/st")" = 0 ]; then',
        ),
      );
    });

    test('zip keeps links as links', () {
      final script = RemoteFileCommands.compress(
        directory: '/srv',
        names: ['site'],
        archiveName: 'site.zip',
        partName: '.p',
        format: ArchiveFormat.zip,
        tools: _gnu,
      );
      expect(script, contains("zip -q -r -y './.p' './site'"));
    });

    test('a member must be a single name', () {
      expect(
        () => RemoteFileCommands.compress(
          directory: '/srv',
          names: ['../etc'],
          archiveName: 'x.tar.gz',
          partName: '.p',
          format: ArchiveFormat.tarGz,
          tools: _gnu,
        ),
        throwsArgumentError,
      );
    });

    test('extract lists first, mode letter first, keeps through -k', () {
      final script = RemoteFileCommands.extract(
        archivePath: '/srv/x.tar.xz',
        kind: ArchiveKind.tarXz,
        destination: '/srv/x',
        mode: ExtractMode.keepExisting,
        tools: _gnu,
      );
      expect(script, contains("a='/srv/x.tar.xz'"));
      expect(script,
          contains('if { tar -tJf "\$a"; } > "\$d/list" 2> "\$d/lerr"; then'));
      expect(script, contains('if { tar -xJf "\$a" -k -C "\$t"; } 2> "\$d/err"'));
    });

    test('extract through xz when tar has no -J', () {
      final script = RemoteFileCommands.extract(
        archivePath: '/srv/x.txz',
        kind: ArchiveKind.tarXz,
        destination: '/srv/x',
        mode: ExtractMode.newFolder,
        tools: _busybox,
      );
      expect(
        script,
        contains('{ xz -dc < "\$a"; echo \$? > "\$d/st"; } | tar -xf - -C "\$t"'
            ' && [ "\$(cat "\$d/st")" = 0 ]'),
      );
      expect(script, contains('exit 17'));
    });

    test('zip extract never answers a prompt it cannot see', () {
      String unpack(ExtractMode mode) => RemoteFileCommands.extract(
            archivePath: '/srv/x.zip',
            kind: ArchiveKind.zip,
            destination: '/srv/x',
            mode: mode,
            tools: _gnu,
          );
      expect(unpack(ExtractMode.newFolder), contains('unzip -q -n "\$a" -d "\$t"'));
      expect(unpack(ExtractMode.keepExisting), contains('unzip -q -n'));
      expect(unpack(ExtractMode.replaceExisting), contains('unzip -q -o'));
      expect(unpack(ExtractMode.newFolder), contains('unzip -Z1 "\$a"'));
      expect(
        RemoteFileCommands.extract(
          archivePath: '/srv/x.zip',
          kind: ArchiveKind.zip,
          destination: '/srv/x',
          mode: ExtractMode.newFolder,
          tools: _busybox,
        ),
        contains('unzip -l "\$a"'),
      );
    });

    test('duplicate', () {
      expect(
        RemoteFileCommands.duplicate(
          source: "/srv/it's",
          destination: "/srv/it's copy",
          tools: _gnu,
        ),
        endsWith("cp -a '/srv/it'\\''s' '/srv/it'\\''s copy'"),
      );
      expect(
        RemoteFileCommands.duplicate(
          source: '/a',
          destination: '/b',
          tools: const RemoteToolkit(tools: {'cp': ToolFlavour.bsd}),
        ),
        endsWith("cp -pPR '/a' '/b'"),
      );
    });

    test('change owner', () {
      expect(
        RemoteFileCommands.changeOwner(
          paths: ['/srv/-x', '/srv/a b'],
          owner: 'www-data',
          group: 'web',
          recursive: true,
        ),
        endsWith("chown -h -R -- 'www-data:web' '/srv/-x' '/srv/a b'"),
      );
      expect(
        RemoteFileCommands.changeOwner(
          paths: ['/srv/x'],
          owner: '',
          group: 'web',
          recursive: false,
        ),
        endsWith("chown -h -- ':web' '/srv/x'"),
      );
    });

    test('a relative path cannot be read as an option', () {
      expect(RemoteFileCommands.ownerOf('-la'), "ls -ld './-la'");
      expect(RemoteFileCommands.ownerOf('/x'), "ls -ld '/x'");
    });

    test('search, GNU: -printf, and grep -lZ for contents', () {
      final byName = RemoteFileCommands.search(
        directory: '/srv',
        pattern: 'log',
        tools: _gnu,
      );
      expect(byName, startsWith("sh -c '"));
      expect(
        byName,
        contains("find '\\''/srv'\\'' -mindepth 1 -iname '\\''*log*'\\'' "
            "-printf '\\''%y %s %p\\0'\\''"),
      );
      final byText = RemoteFileCommands.search(
        directory: '/srv',
        pattern: '*.conf',
        contains: 'Listen',
        matchCase: true,
        tools: _gnu,
      );
      expect(byText, contains('-type f -name'));
      expect(byText, contains("'\\''*.conf'\\''"));
      expect(byText, contains('grep -l -Z -I -F -e'));
      expect(byText, isNot(contains(' -i ')));
    });

    test('search, BusyBox: no -printf, a shell per batch', () {
      final command = RemoteFileCommands.search(
        directory: '/srv',
        pattern: 'x',
        contains: 'y',
        tools: _busybox,
      );
      expect(command, isNot(contains('-printf')));
      expect(command, isNot(contains('-Z')));
      expect(command, contains('-exec sh -c'));
      expect(command, contains('grep -q -F -i -e'));
    });

    test('the search carries its own reaper', () {
      final command = RemoteFileCommands.search(
        directory: '/srv',
        pattern: 'x',
        tools: _gnu,
      );
      expect(command, contains('exec 3<&0'));
      expect(command, contains('cat <&3'));
      expect(command, contains(r'kill $p'));
    });
  });

  group('search output', () {
    test('records split anywhere, even inside a character', () {
      final parser = RemoteSearchParser();
      final bytes = utf8.encode('f 12 /srv/ünï\u0000d - /srv/a b\u0000/srv/grep hit\u0000');
      final hits = <RemoteSearchHit>[];
      for (var i = 0; i < bytes.length; i += 3) {
        hits.addAll(parser.add(bytes.sublist(i, (i + 3).clamp(0, bytes.length))));
      }
      expect(hits.map((h) => h.path), ['/srv/ünï', '/srv/a b', '/srv/grep hit']);
      expect(hits[0].size, 12);
      expect(hits[0].isDirectory, isFalse);
      expect(hits[1].isDirectory, isTrue);
      expect(hits[1].size, isNull);
      expect(hits[2].isDirectory, isFalse);
    });

    test('a name with a newline is one hit', () {
      final hits = RemoteSearchParser().add(utf8.encode('f 1 /srv/new\nline\u0000'));
      expect(hits.single.path, '/srv/new\nline');
      expect(hits.single.name, 'new\nline');
    });

    test('nonsense is dropped', () {
      expect(RemoteSearchParser.parseRecord('garbage'), isNull);
      expect(RemoteSearchParser.parseRecord('f 1 relative'), isNull);
    });

    test('stops at the limit and closes stdin first', () async {
      final records = List.generate(5, (i) => 'f 1 /srv/$i\u0000').join();
      final transport = FakeExecTransport(stdout: records);
      final search = await RemoteSearch.start(transport, 'find', limit: 3);
      final hits = <RemoteSearchHit>[];
      search.hits.listen(hits.addAll);
      final end = await search.done;
      await pumpEventQueue();
      expect(hits, hasLength(3));
      expect(end.limited, isTrue);
      expect(transport.sessions.single.stdinClosed, isTrue);
      expect(transport.sessions.single.wasClosed, isTrue);
    });

    test('counts the folders find could not read', () async {
      final transport = FakeExecTransport(
        stdout: 'f 1 /srv/a\u0000',
        stderrText: "find: '/srv/x': Permission denied\n"
            "find: '/srv/y': Permission denied\n",
        exitCode: 1,
      );
      final search = await RemoteSearch.start(transport, 'find');
      search.hits.listen((_) {});
      final end = await search.done;
      expect(end.count, 1);
      expect(end.unreadableFolders, 2);
      expect(end.exitCode, 1);
    });
  });

  group('against a real shell', () {
    for (final (label, kit, busybox) in [
      ('GNU', _gnu, false),
      ('BusyBox, no gzip or xz inside tar', _busybox, true),
      (
        'BusyBox with them',
        RemoteToolkit(
          tools: _busybox.tools,
          tarGzip: true,
          tarXz: true,
        ),
        true,
      ),
    ]) {
      group(label, () {
        late _Box box;
        setUp(() async => box = await _Box.create(busybox: busybox));
        tearDown(() => box.dispose());

        test('tar.gz round trip of hostile names, nothing runs', () async {
          await box.seed();
          final made = await box.run(RemoteFileCommands.compress(
            directory: box.src,
            names: _hostile,
            archiveName: 'all.tar.gz',
            partName: '.all.tar.gz.ssg-part-1',
            format: ArchiveFormat.tarGz,
            tools: kit,
          ));
          expect(made.exitCode, 0, reason: '${made.stderr}');
          expect(File('${box.src}/all.tar.gz').existsSync(), isTrue);
          expect(File('${box.src}/.all.tar.gz.ssg-part-1').existsSync(), isFalse);

          final out = await box.run(RemoteFileCommands.extract(
            archivePath: '${box.src}/all.tar.gz',
            kind: ArchiveKind.tarGz,
            destination: '${box.root}/out',
            mode: ExtractMode.newFolder,
            tools: kit,
          ));
          expect(out.exitCode, 0, reason: '${out.stderr}');
          for (final name in _hostile) {
            expect(
              File('${box.root}/out/$name/inside').readAsStringSync(),
              name,
              reason: name,
            );
          }
          box.expectNothingRan();
        });

        test('tar.xz and plain tar extract', () async {
          await box.seed();
          await Process.run('tar', ['-cJf', '${box.root}/x.tar.xz', '-C', box.src, '.']);
          await Process.run('tar', ['-cf', '${box.root}/x.tar', '-C', box.src, '.']);
          for (final (archive, kind) in [
            ('x.tar.xz', ArchiveKind.tarXz),
            ('x.tar', ArchiveKind.tar),
          ]) {
            final dest = '${box.root}/${archive}_out';
            final result = await box.run(RemoteFileCommands.extract(
              archivePath: '${box.root}/$archive',
              kind: kind,
              destination: dest,
              mode: ExtractMode.newFolder,
              tools: kit,
            ));
            expect(result.exitCode, 0, reason: '$archive: ${result.stderr}');
            expect(File('$dest/-rf/inside').readAsStringSync(), '-rf');
          }
        });

        test('a damaged archive is unreadable, not half-extracted', () async {
          File('${box.root}/bad.tar.gz').writeAsBytesSync(
            [0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 3, 1, 2, 3, 4, 5],
          );
          final result = await box.run(RemoteFileCommands.extract(
            archivePath: '${box.root}/bad.tar.gz',
            kind: ArchiveKind.tarGz,
            destination: '${box.root}/bad',
            mode: ExtractMode.newFolder,
            tools: kit,
          ));
          expect(result.exitCode, RemoteOpExit.unreadableArchive);
          expect(Directory('${box.root}/bad').existsSync(), isFalse);
        });

        test('an archive that climbs out with .. is refused', () async {
          Directory('${box.root}/evil/inner').createSync(recursive: true);
          File('${box.root}/evil/escaped').writeAsStringSync('x');
          // GNU tar keeps a `..` member it was given on the command line
          // when told -P; the archive then holds `inner/../escaped`.
          final made = await Process.run(
            'tar',
            ['-czPf', '${box.root}/evil.tar.gz', 'inner/../escaped'],
            workingDirectory: '${box.root}/evil',
          );
          expect(made.exitCode, 0, reason: '${made.stderr}');
          final result = await box.run(RemoteFileCommands.extract(
            archivePath: '${box.root}/evil.tar.gz',
            kind: ArchiveKind.tarGz,
            destination: '${box.root}/evil_out',
            mode: ExtractMode.newFolder,
            tools: kit,
          ));
          // GNU tar lists the member as it is; BusyBox's lists it with the
          // `inner/../` stripped and says so on stderr. Either way, and
          // through a pipe from gzip as much as through tar's own -z, it
          // is refused before anything is written.
          expect(result.exitCode, RemoteOpExit.unsafeArchive,
              reason: '${result.stderr}');
          expect(Directory('${box.root}/evil_out').existsSync(), isFalse);
          expect(File('${box.root}/escaped').existsSync(), isFalse);
        });

        test('extract refuses a folder that exists unless told how', () async {
          await box.seed();
          await Process.run('tar', ['-czf', '${box.root}/x.tar.gz', '-C', box.src, './-rf']);
          final dest = '${box.root}/dest';
          Directory('$dest/-rf').createSync(recursive: true);
          File('$dest/-rf/inside').writeAsStringSync('mine');
          String script(ExtractMode mode) => RemoteFileCommands.extract(
                archivePath: '${box.root}/x.tar.gz',
                kind: ArchiveKind.tarGz,
                destination: dest,
                mode: mode,
                tools: kit,
              );

          final refused = await box.run(script(ExtractMode.newFolder));
          expect(refused.exitCode, RemoteOpExit.exists);
          expect(File('$dest/-rf/inside').readAsStringSync(), 'mine');

          final kept = await box.run(script(ExtractMode.keepExisting));
          expect(kept.exitCode, 0, reason: '${kept.stderr}');
          expect(File('$dest/-rf/inside').readAsStringSync(), 'mine');

          final replaced = await box.run(script(ExtractMode.replaceExisting));
          expect(replaced.exitCode, 0, reason: '${replaced.stderr}');
          expect(File('$dest/-rf/inside').readAsStringSync(), '-rf');
        });

        test('compress refuses a name that is taken', () async {
          await box.seed();
          File('${box.src}/taken.tar.gz').writeAsStringSync('keep me');
          final result = await box.run(RemoteFileCommands.compress(
            directory: box.src,
            names: ['-rf'],
            archiveName: 'taken.tar.gz',
            partName: '.taken.part',
            format: ArchiveFormat.tarGz,
            tools: kit,
          ));
          expect(result.exitCode, RemoteOpExit.exists);
          expect(File('${box.src}/taken.tar.gz').readAsStringSync(), 'keep me');
        });

        test('zip round trip', () async {
          await box.seed();
          // Made by the zip script for GNU, or Info-ZIP's zip directly for
          // BusyBox, which cannot make one; unpacked by the toolkit's unzip.
          final archive = '${box.root}/all.zip';
          await Process.run('zip', ['-q', '-r', '-y', archive, '.'],
              workingDirectory: box.src);
          final result = await box.run(RemoteFileCommands.extract(
            archivePath: archive,
            kind: ArchiveKind.zip,
            destination: '${box.root}/unzipped',
            mode: ExtractMode.newFolder,
            tools: kit,
          ));
          expect(result.exitCode, 0, reason: '${result.stderr}');
          expect(File('${box.root}/unzipped/it\'s/inside').readAsStringSync(), "it's");
          expect(File('${box.root}/unzipped/-rf/inside').readAsStringSync(), '-rf');
          box.expectNothingRan();
        }, skip: !_hasZip);

        test('duplicate keeps everything and will not overwrite', () async {
          await box.seed();
          for (final name in ['-rf', "it's", 'new\nline']) {
            final result = await box.run(RemoteFileCommands.duplicate(
              source: '${box.src}/$name',
              destination: '${box.src}/$name copy',
              tools: kit,
            ));
            expect(result.exitCode, 0, reason: '$name: ${result.stderr}');
            expect(File('${box.src}/$name copy/inside').readAsStringSync(), name);
          }
          final again = await box.run(RemoteFileCommands.duplicate(
            source: '${box.src}/-rf',
            destination: '${box.src}/-rf copy',
            tools: kit,
          ));
          expect(again.exitCode, RemoteOpExit.exists);
          expect(Directory('${box.src}/-rf copy/-rf').existsSync(), isFalse,
              reason: 'cp must not have copied into the existing copy');
          box.expectNothingRan();
        });

        test('change owner to who it already is, recursively', () async {
          await box.seed();
          final me = (Process.runSync('id', ['-un']).stdout as String).trim();
          final group = (Process.runSync('id', ['-gn']).stdout as String).trim();
          final result = await box.run(RemoteFileCommands.changeOwner(
            paths: ['${box.src}/-rf', '${box.src}/with space'],
            owner: me,
            group: group,
            recursive: true,
          ));
          expect(result.exitCode, 0, reason: '${result.stderr}');
          final ls = await box.shell(RemoteFileCommands.ownerOf('${box.src}/-rf'));
          expect(RemoteFileCommands.parseOwner(ls.stdout as String)?.owner, me);
        });

        test('search by name and by contents finds hostile names', () async {
          await box.seed();
          Future<List<RemoteSearchHit>> search(String pattern,
              {String? contains, bool matchCase = false}) async {
            final process = await box.start(RemoteFileCommands.search(
              directory: box.src,
              pattern: pattern,
              contains: contains,
              matchCase: matchCase,
              tools: kit,
            ));
            final parser = RemoteSearchParser();
            final hits = <RemoteSearchHit>[];
            final err = StringBuffer();
            process.stderr.transform(utf8.decoder).listen(err.write);
            await process.stdout.forEach((c) => hits.addAll(parser.add(c)));
            // GNU grep -l exits 1 for a batch with no match, and find
            // passes that on: a status, not a failure.
            expect(await process.exitCode, lessThanOrEqualTo(1),
                reason: '$err');
            expect('$err', isEmpty);
            await process.stdin.close();
            return hits;
          }

          final quote = await search("'");
          expect(quote.map((h) => h.name), contains("it's"));
          expect(quote.firstWhere((h) => h.name == "it's").isDirectory, isTrue);

          final star = await search('[*]');
          expect(star.map((h) => h.name).toSet(), {'*'},
              reason: 'a glob is used as one, and matched literally here');

          final newline = await search('new');
          expect(newline.map((h) => h.name), contains('new\nline'));

          final insideCase = await search('INSIDE');
          expect(insideCase.where((h) => h.name == 'inside'), hasLength(_hostile.length));
          expect(await search('INSIDE', matchCase: true), isEmpty);

          final byText = await search('inside', contains: r'$(touch');
          expect(byText.map((h) => h.path),
              [r'%/$(touch PWNED1)/inside'.replaceFirst('%', box.src)]);
          expect(byText.single.isDirectory, isFalse);
          box.expectNothingRan();
        });

        test('closing stdin stops a search that is still going', () async {
          // A `find` that never finishes on its own.
          final shim = Directory('${box.root}/shim')..createSync();
          File('${shim.path}/find')
            ..writeAsStringSync('#!/bin/sh\nexec sleep 30\n')
            ..createSync();
          await Process.run('chmod', ['+x', '${shim.path}/find']);
          final process = await box.start(
            RemoteFileCommands.search(directory: box.src, pattern: 'x', tools: kit),
            pathPrefix: shim.path,
          );
          unawaited(process.stdout.drain<void>());
          unawaited(process.stderr.drain<void>());
          await Future<void>.delayed(const Duration(milliseconds: 300));
          await process.stdin.close();
          final code = await process.exitCode.timeout(const Duration(seconds: 5));
          expect(code, isNot(0));
        });
      }, skip: busybox && !_hasBusybox ? 'no busybox here' : !_posix);
    }
  });

  group('server-side job launcher, for real', () {
    late Directory home;
    setUp(() async => home = await Directory.systemTemp.createTemp('ssg_job'));
    tearDown(() => home.delete(recursive: true));

    Future<ProcessResult> sh(String command) => Process.run(
          'sh',
          ['-c', command],
          environment: {'HOME': home.path},
        );

    test('a quick script reports straight back, and is cleaned up', () async {
      final id = ServerSideJob.newId();
      final result = await sh(ServerSideJob.launchScriptCommand(
        jobId: id,
        script: 'd="\$1"\necho "it\'s \$d" >&2\nexit 3',
      ));
      final status = ServerSideJob.parseLaunch(result.stdout as String)!;
      expect(status.state, ServerJobState.finished);
      expect(status.exitCode, 3);
      expect(status.log, contains("it's ${home.path}/.cache/secureshellgo/jobs/$id"));
      expect(File('${home.path}/.cache/secureshellgo/jobs/$id/op').existsSync(), isTrue);
      await sh(ServerSideJob.cleanupCommand(id));
      expect(Directory('${home.path}/.cache/secureshellgo/jobs/$id').existsSync(), isFalse);
    });

    test('a long one keeps running detached, and stops when cancelled', () async {
      final id = ServerSideJob.newId();
      final launch = await sh(ServerSideJob.launchScriptCommand(
        jobId: id,
        script: 'sleep 30',
      ));
      expect(ServerSideJob.parseLaunch(launch.stdout as String)!.state,
          ServerJobState.running);
      final running = await sh(ServerSideJob.statusCommand(id));
      expect(ServerSideJob.parseStatus(running.stdout as String).state,
          ServerJobState.running);
      final pid = File('${home.path}/.cache/secureshellgo/jobs/$id/pid')
          .readAsStringSync()
          .trim();
      await sh(ServerSideJob.cancelCommand(id));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(Process.runSync('kill', ['-0', pid]).exitCode, isNot(0),
          reason: 'the job is still alive');
    });

    test('the script runs under the account\'s umask, not 077', () async {
      final result = await sh('umask 022; ${ServerSideJob.launchScriptCommand(
        jobId: ServerSideJob.newId(),
        script: 'umask',
      )}');
      final status = ServerSideJob.parseLaunch(result.stdout as String)!;
      expect(status.state, ServerJobState.finished);
      expect(status.log, '0022');
    });

    group('on a server without setsid', () {
      // This machine's own tools less setsid, so the job lands in the
      // launcher's process group, as under macOS or FreeBSD. Not BusyBox:
      // its shell finds its own setsid applet whatever PATH says.
      late String bin;
      setUp(() async => bin = await _systemBinWithout(const {'setsid'}));

      Future<ProcessResult> bb(String command, {String? pathPrefix}) =>
          Process.run(
            '/bin/sh',
            ['-c', command],
            environment: {
              'HOME': home.path,
              'PATH': pathPrefix == null ? bin : '$pathPrefix:$bin',
            },
          );

      Future<void> waitFor(File file) async {
        for (var i = 0; i < 100 && !file.existsSync(); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(file.existsSync(), isTrue, reason: '${file.path} never came');
      }

      test('cancel stops what the script started, not only the script',
          () async {
        final id = ServerSideJob.newId();
        final child = File('${home.path}/child');
        final launch = await bb(ServerSideJob.launchScriptCommand(
          jobId: id,
          script: r'sleep 60 & echo $! > "$HOME/child"; wait',
        ));
        expect(ServerSideJob.parseLaunch(launch.stdout as String)!.state,
            ServerJobState.running);
        await waitFor(child);
        final pid = child.readAsStringSync().trim();
        addTearDown(() => Process.runSync('kill', [pid]));
        await bb(ServerSideJob.cancelCommand(id));
        var alive = true;
        for (var i = 0; i < 50 && alive; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          alive = Process.runSync('kill', ['-0', pid]).exitCode == 0;
        }
        expect(alive, isFalse, reason: 'a grandchild of the job lived on');
      });

      test('a stopped zip puts no part file back after the tidy-up',
          () async {
        // A zip that writes a temp file and renames it to the name it was
        // given when done — Info-ZIP's way — and tidies up on TERM.
        final shim = Directory('${home.path}/shim')..createSync();
        File('${shim.path}/zip').writeAsStringSync(
          '#!/bin/sh\n'
          "trap 'rm -f ./zi.tmp; exit 143' TERM\n"
          ': > ./zi.tmp\n'
          r'sleep 2 & wait $!' '\n'
          r'mv ./zi.tmp "$4"' '\n',
        );
        await Process.run('chmod', ['+x', '${shim.path}/zip']);
        final src = Directory('${home.path}/src')..createSync();
        File('${src.path}/a').writeAsStringSync('a');
        final id = ServerSideJob.newId();
        final launch = await bb(
          ServerSideJob.launchScriptCommand(
            jobId: id,
            script: RemoteFileCommands.compress(
              directory: src.path,
              names: ['a'],
              archiveName: 'a.zip',
              partName: '.a.zip.ssg-part-1',
              format: ArchiveFormat.zip,
              tools: _gnu,
            ),
          ),
          pathPrefix: shim.path,
        );
        expect(ServerSideJob.parseLaunch(launch.stdout as String)!.state,
            ServerJobState.running);
        await waitFor(File('${src.path}/zi.tmp'));
        await bb(ServerSideJob.cancelCommand(id));
        await bb(RemoteFileCommands.removeFile('${src.path}/.a.zip.ssg-part-1'));
        await Future<void>.delayed(const Duration(milliseconds: 2500));
        expect(src.listSync().map((e) => e.path.split('/').last), ['a']);
      });
    }, skip: !Directory('/usr/bin').existsSync());

    test('old finished operations are swept, copies are not', () async {
      final jobs = Directory('${home.path}/.cache/secureshellgo/jobs')
        ..createSync(recursive: true);
      Directory makeJob(String name, {required bool op}) {
        final dir = Directory('${jobs.path}/$name')..createSync();
        File('${dir.path}/exit').writeAsStringSync('0\n');
        if (op) File('${dir.path}/op').writeAsStringSync('');
        Process.runSync('touch', ['-d', '2020-01-01', dir.path]);
        return dir;
      }

      final oldOp = makeJob('a' * 32, op: true);
      final oldCopy = makeJob('b' * 32, op: false);
      await sh(ServerSideJob.launchScriptCommand(
        jobId: ServerSideJob.newId(),
        script: 'exit 0',
      ));
      expect(oldOp.existsSync(), isFalse);
      expect(oldCopy.existsSync(), isTrue);
    });
  }, skip: !_posix);

  group('ServerOperation', () {
    test('follows a job until it finishes, then cleans up', () async {
      var polls = 0;
      final transport = FakeExecTransport(respond: (command) {
        if (command.contains('ssg-op')) {
          return FakeExecSession(stdout: '${ServerSideJob.startedMarker}\n');
        }
        if (command.contains('RUNNING')) {
          polls++;
          return FakeExecSession(
            stdout: polls < 3 ? 'RUNNING\n---\n' : 'EXIT 0\n---\ndone\n',
          );
        }
        return FakeExecSession();
      });
      final op = ServerOperation(
        transport: () => transport,
        script: 'true',
        pollEvery: const Duration(milliseconds: 5),
      );
      final outcome = await op.run();
      await pumpEventQueue();
      expect(outcome.state, ServerOpState.succeeded);
      expect(outcome.log, 'done');
      expect(polls, 3);
      expect(transport.commands.last, contains('rm -rf'));
    });

    test('a refusal comes back with its exit code', () async {
      final transport = FakeExecTransport(
        stdout: '${ServerSideJob.doneMarker} 17\n---\nThe archive\'s name is taken.\n',
      );
      final outcome = await ServerOperation(
        transport: () => transport,
        script: 'x',
      ).run();
      expect(outcome.state, ServerOpState.failed);
      expect(outcome.exitCode, RemoteOpExit.exists);
      expect(outcome.log, contains('taken'));
    });

    test('cancel kills the job and tidies up after it', () async {
      final transport = FakeExecTransport(respond: (command) {
        if (command.contains('ssg-op')) {
          return FakeExecSession(stdout: '${ServerSideJob.startedMarker}\n');
        }
        return FakeExecSession(stdout: 'RUNNING\n---\n');
      });
      final op = ServerOperation(
        transport: () => transport,
        script: 'sleep 100',
        afterCancel: "rm -f '/srv/.part'",
        pollEvery: const Duration(seconds: 30),
      );
      final running = op.run();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      op.cancel();
      final outcome = await running.timeout(const Duration(seconds: 2));
      expect(outcome.state, ServerOpState.cancelled);
      expect(transport.commands.any((c) => c.contains('kill -s TERM')), isTrue);
      expect(transport.commands.last, "rm -f '/srv/.part'");
    });

    test('a launch the server did not understand is a failure', () async {
      final transport = FakeExecTransport(stdout: '', stderrText: 'sh: not found', exitCode: 127);
      final outcome = await ServerOperation(transport: () => transport, script: 'x').run();
      expect(outcome.state, ServerOpState.failed);
      expect(outcome.log, 'sh: not found');
    });
  });
}

/// A temporary tree to run the scripts in, with a canary directory as the
/// working directory so any `touch PWNED` that did run would land in it.
class _Box {
  _Box._(this.root, this.busyboxBin);

  static Future<_Box> create({required bool busybox}) async {
    final root = await Directory.systemTemp.createTemp('ssg_ops');
    return _Box._(root.path, busybox ? await _busyboxBin() : null);
  }

  final String root;
  final String? busyboxBin;
  var _jobs = 0;

  String get src => '$root/src';

  /// One folder per hostile name, each with a file `inside` holding the
  /// name.
  Future<void> seed() async {
    for (final name in _hostile) {
      final dir = Directory('$src/$name')..createSync(recursive: true);
      File('${dir.path}/inside').writeAsStringSync(name);
    }
  }

  Map<String, String> _env(String? pathPrefix) {
    final bin = busyboxBin;
    final base = bin ?? Platform.environment['PATH']!;
    return {'PATH': pathPrefix == null ? base : '$pathPrefix:$base'};
  }

  /// Runs an operation script as the job launcher would: `sh run <job>`.
  Future<ProcessResult> run(String script) async {
    final job = Directory('$root/job${_jobs++}')..createSync();
    final file = File('${job.path}/run')..writeAsStringSync('$script\n');
    final canary = Directory('$root/canary')..createSync(recursive: true);
    return busyboxBin == null
        ? Process.run('sh', [file.path, job.path], workingDirectory: canary.path)
        : Process.run('busybox', ['sh', file.path, job.path],
            environment: _env(null), workingDirectory: canary.path);
  }

  /// Runs an exec command as the login shell would: `sh -c <command>`.
  Future<ProcessResult> shell(String command) => busyboxBin == null
      ? Process.run('sh', ['-c', command])
      : Process.run('busybox', ['sh', '-c', command], environment: _env(null));

  Future<Process> start(String command, {String? pathPrefix}) {
    final canary = Directory('$root/canary')..createSync(recursive: true);
    return busyboxBin == null
        ? Process.start('sh', ['-c', command],
            workingDirectory: canary.path,
            environment: pathPrefix == null ? null : _env(pathPrefix))
        : Process.start('busybox', ['sh', '-c', command],
            environment: _env(pathPrefix), workingDirectory: canary.path);
  }

  void expectNothingRan() {
    final stray = Directory(root)
        .listSync(recursive: true)
        .where((e) => e.path.split('/').last.startsWith('PWNED'))
        .toList();
    expect(stray, isEmpty);
  }

  Future<void> dispose() => Directory(root).delete(recursive: true);
}

final Map<String, String> _busyboxBinPaths = {};

/// A directory of links to everything in `/usr/bin` but [without], for a
/// PATH on which those few are missing.
Future<String> _systemBinWithout(Set<String> without) async {
  final key = 'system:${(without.toList()..sort()).join(',')}';
  final existing = _busyboxBinPaths[key];
  if (existing != null && Directory(existing).existsSync()) return existing;
  final dir = await Directory.systemTemp.createTemp('ssg_bin');
  for (final entry in Directory('/usr/bin').listSync()) {
    final name = entry.path.split('/').last;
    if (without.contains(name)) continue;
    Link('${dir.path}/$name').createSync(entry.path);
  }
  return _busyboxBinPaths[key] = dir.path;
}

/// A directory of links to every BusyBox applet — a BusyBox userland, as
/// on Alpine or a NAS, for a PATH with nothing else on it.
Future<String> _busyboxBin() async {
  const key = 'busybox';
  final existing = _busyboxBinPaths[key];
  if (existing != null && Directory(existing).existsSync()) return existing;
  final dir = await Directory.systemTemp.createTemp('ssg_busybox');
  final busybox = (Process.runSync('sh', ['-c', 'command -v busybox']).stdout
          as String)
      .trim();
  final list = Process.runSync(busybox, ['--list']).stdout as String;
  for (final applet in const LineSplitter().convert(list)) {
    if (applet.isEmpty || applet.contains('/')) continue;
    Link('${dir.path}/$applet').createSync(busybox);
  }
  return _busyboxBinPaths[key] = dir.path;
}
