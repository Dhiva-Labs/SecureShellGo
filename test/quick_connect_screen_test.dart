import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/screens/quick_connect_screen.dart';
import 'package:secure_shell_go/services/credential_store.dart';
import 'package:secure_shell_go/services/device_storage.dart';
import 'package:secure_shell_go/services/host_store.dart';
import 'package:secure_shell_go/services/known_hosts_service.dart';
import 'package:secure_shell_go/services/quick_connect_parser.dart';
import 'package:secure_shell_go/theme.dart';
import 'package:secure_shell_go/services/session_manager.dart';
import 'package:secure_shell_go/services/ssh_service.dart';

/// Hands back exactly one file, regardless of what is asked for — this
/// screen's picker only ever calls [pickTextFile], so everything else either
/// throws or answers empty, the same shape `fleet_push_screen_test.dart`
/// uses for its own stub.
class _StubDeviceStorage implements DeviceStorage {
  _StubDeviceStorage(this._file);

  final PickedTextFile? _file;

  @override
  Future<PickedTextFile?> pickTextFile({
    int maxBytes = kDefaultPickedTextFileMaxBytes,
  }) async =>
      _file;

  @override
  Future<bool> ensurePermission() async => true;

  @override
  Future<bool> downloadExists(
    String fileName, {
    String relativeDirectory = '',
  }) async =>
      false;

  @override
  Future<DownloadWriter> beginDownload(
    String fileName, {
    String? mimeType,
    bool overwrite = false,
    String relativeDirectory = '',
  }) =>
      throw UnimplementedError();

  @override
  Future<bool> openDownload(String uri, {String? mimeType}) async => false;

  @override
  Future<PickedLocalFile?> pickFile() async => null;

  @override
  Future<List<PickedLocalFile>> pickFiles() async => const [];

  @override
  Future<PickedLocalDirectory?> pickDirectory() async => null;
}

/// A backend whose every write throws — the one remaining state in which a
/// credential genuinely cannot be stored anywhere (see
/// `host_edit_screen_test.dart`'s identical `_LockedKeyring`).
class _LockedBackend implements SecureStorageBackend {
  @override
  Future<void> write(String key, String value) async {
    throw const SecureStorageUnavailableException('locked', code: 'Locked');
  }

  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> delete(String key) async {}
}

class _InMemoryBackend implements SecureStorageBackend {
  final Map<String, String> data = {};

  @override
  Future<void> write(String key, String value) async => data[key] = value;

  @override
  Future<String?> read(String key) async => data[key];

  @override
  Future<void> delete(String key) async => data.remove(key);
}

void main() {
  late Directory dir;
  late HostStore hosts;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('quick_connect_screen_test');
    hosts = HostStore(file: File('${dir.path}/${HostStore.fileName}'));
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  const target = QuickConnectTarget(
    username: 'ec2-user',
    hostname: '203.0.113.10',
    port: 22,
  );

  Future<void> pumpScreen(
    WidgetTester tester, {
    required CredentialStore credentialStore,
    DeviceStorage? deviceStorage,
  }) async {
    tester.view.physicalSize = const Size(1000, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: QuickConnectScreen(
          target: target,
          sshService: SshService(
            knownHosts: KnownHostsService(
              file: File('${dir.path}/${KnownHostsService.fileName}'),
            ),
          ),
          sessions: SessionManager(),
          hostStore: hosts,
          credentialStore: credentialStore,
          deviceStorage: deviceStorage,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('importing a key file', () {
    testWidgets('a valid PKCS#1 key fills the private key field',
        (tester) async {
      final key = await withRealIo(
        tester,
        () => _makeRsaPem(dir, encrypted: false),
      );

      await pumpScreen(
        tester,
        credentialStore: CredentialStore(backend: _InMemoryBackend()),
        deviceStorage: _StubDeviceStorage(
          PickedTextFile(name: 'ec2-key.pem', content: key),
        ),
      );

      await tester.tap(find.text('Private key'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Import key file'));
      await tester.pumpAndSettle();

      final field = tester.widget<TextFormField>(
        find.widgetWithText(TextFormField, 'Private key (PEM)'),
      );
      expect(field.controller!.text, key);
      expect(find.textContaining('Imported ec2-key.pem'), findsOneWidget);
    });

    testWidgets('an unsupported PKCS#8 file explains how to fix it',
        (tester) async {
      final pkcs8 = await withRealIo(
        tester,
        () => _makePkcs8Pem(dir),
      );

      await pumpScreen(
        tester,
        credentialStore: CredentialStore(backend: _InMemoryBackend()),
        deviceStorage: _StubDeviceStorage(
          PickedTextFile(name: 'aws-key.pem', content: pkcs8),
        ),
      );

      await tester.tap(find.text('Private key'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Import key file'));
      // Not pumpAndSettle: the failure is reported in a SnackBar, which keeps
      // scheduling frames for its whole display duration, so nothing ever
      // settles. Pump far enough for it to appear and no further.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 750));

      expect(find.text('Could not import aws-key.pem'), findsOneWidget);
      // Names the exact fix, not just "unsupported" — this is the one thing
      // an AWS user hits right after this feature ships.
      expect(
        find.textContaining('ssh-keygen -p -m PEM -f'),
        findsOneWidget,
      );

      final field = tester.widget<TextFormField>(
        find.widgetWithText(TextFormField, 'Private key (PEM)'),
      );
      expect(field.controller!.text, isEmpty);
    });
  });


  /// Real file I/O does not complete under the widget tester's fake clock, so
  /// every tap that saves — and every assertion that reads the stores back —
  /// has to run on the real event loop. Same reasoning as
  /// `host_edit_screen_test.dart`, which hit this first.
  Future<void> settleIo(WidgetTester tester, {int rounds = 40}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
  }

  Future<void> tapAndRun(
    WidgetTester tester,
    String label, {
    Future<void> Function()? checks,
  }) async {
    await tester.runAsync(() => tester.tap(find.text(label)));
    await tester.pump();
    await settleIo(tester);
    if (checks != null) await tester.runAsync(checks);
    await tester.pump();
  }

  group('the save offer', () {
    Host connectedHost({String id = 'quick-1'}) => Host(
          id: id,
          label: '',
          hostname: target.hostname,
          port: target.port,
          username: target.username,
          authMethod: SshAuthMethod.password,
        );

    const credentials = SshCredentials(password: 'hunter2');

    Future<void> pumpOffer(
      WidgetTester tester, {
      required CredentialStore credentialStore,
      Host? host,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: QuickConnectSaveOffer(
              host: host ?? connectedHost(),
              credentials: credentials,
              hostStore: hosts,
              credentialStore: credentialStore,
            ),
          ),
        ),
      );
    }

    testWidgets('the form shows no save prompt before a connection',
        (tester) async {
      await pumpScreen(
        tester,
        credentialStore: CredentialStore(backend: _InMemoryBackend()),
      );

      expect(find.text('Save this server?'), findsNothing);
      expect(find.text('Save this server'), findsNothing);
      expect(find.text('Not now'), findsNothing);
    });

    testWidgets('a dialog asks to save right after the offer appears',
        (tester) async {
      await pumpOffer(
        tester,
        credentialStore: CredentialStore(backend: _InMemoryBackend()),
      );
      await tester.pump();

      expect(find.text('Save this server?'), findsOneWidget);
      expect(find.text('Save host'), findsOneWidget);
      expect(find.text('Not now'), findsOneWidget);
    });

    testWidgets('declining saves nothing and does not ask again',
        (tester) async {
      await pumpOffer(
        tester,
        credentialStore: CredentialStore(backend: _InMemoryBackend()),
      );
      await tester.pump();

      await tapAndRun(tester, 'Not now', checks: () async {
        expect(await hosts.all(), isEmpty);
      });

      expect(find.text('Save this server?'), findsNothing);

      // Rebuilding the same widget instance (e.g. a parent redraw) must not
      // re-open the dialog — it already got its answer.
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Save this server?'), findsNothing);
    });

    testWidgets(
        'accepting creates exactly one host with a non-quick id and one '
        'credential entry', (tester) async {
      final credentialStore = CredentialStore(backend: _InMemoryBackend());
      await pumpOffer(tester, credentialStore: credentialStore);
      await tester.pump();

      await tapAndRun(tester, 'Save host', checks: () async {
        final saved = await hosts.all();
        expect(saved, hasLength(1));
        expect(saved.single.id, isNot(startsWith('quick-')));
        expect(saved.single.hostname, target.hostname);

        final loaded = await credentialStore.load(saved.single.id);
        expect(loaded?.password, 'hunter2');
      });

      expect(find.text('Saved to your host list.'), findsOneWidget);
    });

    testWidgets('a credential-save failure still leaves the host saved',
        (tester) async {
      final credentialStore = CredentialStore(backend: _LockedBackend());
      await pumpOffer(tester, credentialStore: credentialStore);
      await tester.pump();

      await tapAndRun(tester, 'Save host', checks: () async {
        expect(await hosts.all(), hasLength(1));
      });

      // Reported calmly, not as a failure: no SnackBar, just an inline line.
      expect(find.textContaining('Host saved, but its password was not'),
          findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
    });
  });
}

Future<T> withRealIo<T>(
  WidgetTester tester,
  Future<T> Function() body,
) async {
  late T result;
  await tester.runAsync(() async {
    result = await body();
  });
  return result;
}

Future<String> _makeRsaPem(Directory dir, {required bool encrypted}) async {
  final path = '${dir.path}/rsa_pem_${DateTime.now().microsecondsSinceEpoch}';
  final process = await Process.run('ssh-keygen', [
    '-t',
    'rsa',
    '-b',
    '2048',
    '-m',
    'PEM',
    '-N',
    encrypted ? 'hunter2' : '',
    '-f',
    path,
    '-C',
    'test',
    '-q',
  ]);
  if (process.exitCode != 0) {
    throw StateError('ssh-keygen failed: ${process.stderr}');
  }
  return File(path).readAsString();
}

Future<String> _makePkcs8Pem(Directory dir) async {
  final rsaPath =
      '${dir.path}/rsa_src_${DateTime.now().microsecondsSinceEpoch}';
  final gen = await Process.run('ssh-keygen', [
    '-t',
    'rsa',
    '-b',
    '2048',
    '-m',
    'PEM',
    '-N',
    '',
    '-f',
    rsaPath,
    '-C',
    'test',
    '-q',
  ]);
  if (gen.exitCode != 0) {
    throw StateError('ssh-keygen failed: ${gen.stderr}');
  }
  final pkcs8Path = '$rsaPath.pkcs8';
  final convert = await Process.run('openssl', [
    'pkcs8',
    '-topk8',
    '-nocrypt',
    '-in',
    rsaPath,
    '-out',
    pkcs8Path,
  ]);
  if (convert.exitCode != 0) {
    throw StateError('openssl pkcs8 failed: ${convert.stderr}');
  }
  return File(pkcs8Path).readAsString();
}
