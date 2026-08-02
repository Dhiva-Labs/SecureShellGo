import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/models/remote_entry.dart';
import 'package:secure_shell_go/screens/fleet_push_screen.dart';
import 'package:secure_shell_go/services/credential_store.dart';
import 'package:secure_shell_go/services/device_storage.dart';
import 'package:secure_shell_go/services/fleet_push_service.dart';
import 'package:secure_shell_go/services/known_hosts_service.dart';
import 'package:secure_shell_go/services/session_manager.dart';
import 'package:secure_shell_go/services/sftp_service.dart';
import 'package:secure_shell_go/services/ssh_service.dart';

/// A minimal in-memory [RemoteFileSystem] — just enough to let a fresh-dial
/// upload run to completion, for [FleetPushResultsScreen]'s own widget test
/// below. `fleet_push_service_test.dart` covers the service's behaviour in
/// depth; this only needs *a* working upload to prove the screen renders
/// live progress.
class _TinyFs implements RemoteFileSystem {
  final Map<String, int> files = {};

  @override
  Future<String> home() async => '/home/dev';
  @override
  Future<String> resolve(String path) async => path;
  @override
  Future<List<RemoteEntry>> list(String path) async => const [];
  @override
  Future<bool> exists(String path) async => files.containsKey(path);
  @override
  Future<int?> sizeOf(String path) async => files[path];
  @override
  Future<void> remove(String path) async => files.remove(path);
  @override
  Future<void> rename(String from, String to) async {
    final size = files.remove(from);
    if (size != null) files[to] = size;
  }
  @override
  Future<void> mkdir(String path) async {}
  @override
  Future<void> removeDirectory(String path) async {}
  @override
  Future<bool> isDirectory(String path) async => false;
  @override
  Future<void> close() async {}
  @override
  Future<int> download(
    String remotePath, {
    required Future<void> Function(Uint8List chunk) write,
    TransferProgress? onProgress,
    CancelCheck? isCancelled,
  }) =>
      throw UnimplementedError();
  @override
  Future<int> upload(
    String localPath,
    String remotePath, {
    TransferProgress? onProgress,
    CancelCheck? isCancelled,
  }) =>
      throw UnimplementedError();
  @override
  Future<RemoteFileWriter> openWrite(String remotePath) async =>
      _TinyWriter(this, remotePath);
}

class _TinyWriter implements RemoteFileWriter {
  _TinyWriter(this._fs, this._path);
  final _TinyFs _fs;
  final String _path;
  var _written = 0;

  @override
  Future<void> add(Uint8List chunk) async => _written += chunk.length;
  @override
  Future<void> close() async => _fs.files[_path] = _written;
  @override
  Future<void> abort() async => _fs.files.remove(_path);
}

/// A [DeviceStorage] that hands back exactly the files it was constructed
/// with; every other member throws or returns an empty answer, since this
/// screen's setup step only ever calls [pickFiles].
class _StubDeviceStorage implements DeviceStorage {
  _StubDeviceStorage(this._files);

  final List<PickedLocalFile> _files;

  @override
  Future<List<PickedLocalFile>> pickFiles() async => _files;

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
  Future<PickedLocalDirectory?> pickDirectory() async => null;

  @override
  Future<PickedTextFile?> pickTextFile({
    int maxBytes = kDefaultPickedTextFileMaxBytes,
  }) async =>
      null;
}

/// A backend with nothing in it — every credential lookup this screen might
/// make during these widget tests reads as "none saved", which is fine: the
/// tests below never get past the confirm step, so nothing actually dials.
class _EmptySecureStorageBackend implements SecureStorageBackend {
  @override
  Future<String?> read(String key) async => null;
  @override
  Future<void> write(String key, String value) async {}
  @override
  Future<void> delete(String key) async {}
}

void main() {
  late Directory tempDir;
  late SshService sshService;
  late CredentialStore credentialStore;
  late SessionManager sessions;

  Host host(String id, {String label = ''}) => Host(
        id: id,
        label: label,
        hostname: '$id.example.com',
        port: 22,
        username: 'dev',
        authMethod: SshAuthMethod.password,
      );

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('fleet_push_screen_test');
    sshService = SshService(
      knownHosts:
          KnownHostsService(file: File('${tempDir.path}/known_hosts.json')),
    );
    credentialStore = CredentialStore(backend: _EmptySecureStorageBackend());
    sessions = SessionManager();
  });

  tearDown(() async {
    await sessions.dispose();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Widget buildScreen({required List<PickedLocalFile> files}) {
    return MaterialApp(
      home: FleetPushScreen(
        hosts: [host('h1', label: 'Alpha'), host('h2', label: 'Beta')],
        sessions: sessions,
        credentialStore: credentialStore,
        sshService: sshService,
        deviceStorage: _StubDeviceStorage(files),
      ),
    );
  }

  testWidgets('Next is disabled until a file is chosen, and enables once '
      'one is picked', (tester) async {
    await tester.pumpWidget(buildScreen(files: const [
      PickedLocalFile(path: '/tmp/report.pdf', name: 'report.pdf', size: 42),
    ]));
    await tester.pumpAndSettle();

    Finder nextButton() => find.widgetWithText(FilledButton, 'Next');
    expect(tester.widget<FilledButton>(nextButton()).onPressed, isNull);

    await tester.tap(find.text('Choose files…'));
    await tester.pumpAndSettle();

    expect(find.text('report.pdf'), findsOneWidget);
    expect(tester.widget<FilledButton>(nextButton()).onPressed, isNotNull);
  });

  testWidgets('the confirm step names the exact files, hosts and '
      'destination', (tester) async {
    await tester.pumpWidget(buildScreen(files: const [
      PickedLocalFile(path: '/tmp/report.pdf', name: 'report.pdf', size: 42),
    ]));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Choose files…'));
    await tester.pumpAndSettle();
    final nextButton = find.widgetWithText(FilledButton, 'Next');
    await tester.ensureVisible(nextButton);
    await tester.pumpAndSettle();
    await tester.tap(nextButton);
    await tester.pumpAndSettle();

    expect(find.textContaining('Push 1 file to 2 hosts at "~"'), findsOneWidget);
    expect(find.text('•  report.pdf'), findsOneWidget);
    expect(find.text('•  Alpha'), findsOneWidget);
    expect(find.text('•  Beta'), findsOneWidget);
  });

  testWidgets('removing a picked file drops it from the list and can '
      'disable Next again', (tester) async {
    await tester.pumpWidget(buildScreen(files: const [
      PickedLocalFile(path: '/tmp/a.txt', name: 'a.txt', size: 1),
    ]));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Choose files…'));
    await tester.pumpAndSettle();
    expect(find.text('a.txt'), findsOneWidget);

    await tester.tap(find.widgetWithIcon(IconButton, Icons.close));
    await tester.pumpAndSettle();

    expect(find.text('a.txt'), findsNothing);
    expect(
      tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Next')).onPressed,
      isNull,
    );
  });

  group('FleetPushResultsScreen', () {
    testWidgets('shows live per-host progress, then a final summary with a '
        "retry button for the host that failed", (tester) async {
      // The fresh-dial upload path reads the picked file with real `dart:io`
      // (see `FleetPushService._uploadDirectWithTempRename`), and real async
      // work inside a `testWidgets` body — including something as small as
      // `writeAsString` — hangs forever unless it runs inside `runAsync`;
      // `pump`/`pumpAndSettle` alone do not wait it out.
      late File localFile;
      await tester.runAsync(() async {
        localFile = File('${tempDir.path}/a.txt');
        await localFile.writeAsString('abc');
      });

      final fs = _TinyFs();
      final service = FleetPushService(
        request: FleetPushRequest(
          hosts: [host('h1', label: 'Alpha'), host('h2', label: 'Beta')],
          files: [
            FleetLocalFile(path: localFile.path, name: 'a.txt', size: 3),
          ],
          destinationDirectory: '/home/dev',
          overwritePolicy: FleetOverwritePolicy.overwrite,
        ),
        openSessionLookup: (_) => null,
        credentialLookup: (id) async =>
            id == 'h2' ? null : const SshCredentials(password: 'x'),
        dialer: (h, creds) async =>
            FleetDialedConnection(sftp: fs, close: () {}),
      );

      // Built, and so subscribed to `service.changes`, before the service is
      // ever started — this is what makes the assertions below a check of
      // live subscription, not just a snapshot read at construction time.
      await tester.pumpWidget(
        MaterialApp(home: FleetPushResultsScreen(service: service)),
      );

      await tester.runAsync(() async {
        service.start();
        while (service.isRunning) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      });
      await tester.pumpAndSettle();

      // Once in the app bar title, once in the body's own summary line.
      expect(find.text('1 of 2 succeeded'), findsNWidgets(2));
      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('Beta'), findsOneWidget);
      expect(find.text('No saved credentials for this host.'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Retry failed'), findsOneWidget);
    });
  });
}
