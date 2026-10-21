import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/known_host.dart';
import 'package:secure_shell_go/screens/backup_screen.dart';
import 'package:secure_shell_go/services/backup_crypto.dart';
import 'package:secure_shell_go/services/backup_service.dart';
import 'package:secure_shell_go/services/bookmark_store.dart';
import 'package:secure_shell_go/services/credential_store.dart';
import 'package:secure_shell_go/services/device_storage.dart';
import 'package:secure_shell_go/services/diagnostics_log.dart';
import 'package:secure_shell_go/services/host_store.dart';
import 'package:secure_shell_go/services/known_hosts_service.dart';
import 'package:secure_shell_go/services/settings_store.dart';
import 'package:secure_shell_go/services/snippet_store.dart';
import 'package:secure_shell_go/services/tunnel_store.dart';

import 'backup_service_test.dart' show FakeSecureStorageBackend;

/// Downloads only — what every existing fake looks like.
class _DownloadsOnly implements DeviceStorage {
  final List<Uint8List> written = [];

  @override
  Future<bool> ensurePermission() async => true;

  @override
  Future<bool> downloadExists(String fileName,
          {String relativeDirectory = ''}) async =>
      false;

  @override
  Future<DownloadWriter> beginDownload(
    String fileName, {
    String? mimeType,
    bool overwrite = false,
    String relativeDirectory = '',
  }) async =>
      _MemoryWriter(written, fileName);

  @override
  Future<bool> openDownload(String uri, {String? mimeType}) async => false;

  @override
  Future<PickedLocalFile?> pickFile() async => null;

  @override
  Future<List<PickedLocalFile>> pickFiles() async => const [];

  @override
  Future<PickedLocalDirectory?> pickDirectory() async => null;

  @override
  Future<PickedTextFile?> pickTextFile({
    int maxBytes = kDefaultPickedTextFileMaxBytes,
  }) async =>
      null;
}

class _MemoryWriter implements DownloadWriter {
  _MemoryWriter(this._into, this._name);

  final List<Uint8List> _into;
  final String _name;
  final _bytes = BytesBuilder();

  @override
  Future<void> add(Uint8List chunk) async => _bytes.add(chunk);

  @override
  Future<SavedDownload> finish() async {
    _into.add(_bytes.takeBytes());
    return SavedDownload(displayName: _name);
  }

  @override
  Future<void> abort() async {}
}

/// Downloads plus "save as".
class _WithSaveAs extends _DownloadsOnly implements DocumentSaver {
  final saved = Completer<({String name, Uint8List bytes, String? mime})>();
  bool cancel = false;

  @override
  Future<SavedDocument?> saveDocument({
    required String suggestedName,
    required Uint8List bytes,
    String? mimeType,
  }) async {
    if (cancel) return null;
    saved.complete((name: suggestedName, bytes: bytes, mime: mimeType));
    return const SavedDocument(
      displayName: 'backup-on-drive.ssgbackup',
      location: 'content://drive/1',
    );
  }
}

void main() {
  group('DesktopDeviceStorage.saveDocument', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('save_as_test');
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    DesktopDeviceStorage storageChoosing(String? path) => DesktopDeviceStorage(
          downloadsDirectoryResolver: () async => dir,
          chooseSaveLocation: (_) async => path,
        );

    test('writes the bytes where the user chose', () async {
      final target = '${dir.path}/nested-name.ssgbackup';
      final saved = await storageChoosing(target).saveDocument(
        suggestedName: 'secureshellgo-2026-10-21.ssgbackup',
        bytes: Uint8List.fromList([1, 2, 3]),
      );
      expect(saved!.displayName, 'nested-name.ssgbackup');
      expect(saved.location, target);
      expect(await File(target).readAsBytes(), [1, 2, 3]);
    });

    test('puts back an extension the user did not type', () async {
      final saved = await storageChoosing('${dir.path}/mine').saveDocument(
        suggestedName: 'secureshellgo-2026-10-21.ssgbackup',
        bytes: Uint8List.fromList([9]),
      );
      expect(saved!.displayName, 'mine.ssgbackup');
      expect(await File('${dir.path}/mine.ssgbackup').exists(), isTrue);
    });

    test('an extension put back never lands on a file already there',
        () async {
      // The dialog asked about replacing "mine" — which does not exist —
      // not "mine.ssgbackup", which does.
      final existing = File('${dir.path}/mine.ssgbackup');
      await existing.writeAsBytes([7, 7, 7]);
      final saved = await storageChoosing('${dir.path}/mine').saveDocument(
        suggestedName: 'secureshellgo-2026-10-21.ssgbackup',
        bytes: Uint8List.fromList([9]),
      );
      expect(await existing.readAsBytes(), [7, 7, 7]);
      expect(saved!.displayName, 'mine (1).ssgbackup');
      expect(await File('${dir.path}/mine (1).ssgbackup').readAsBytes(), [9]);
    });

    test('a name chosen in full replaces as the dialog agreed', () async {
      final existing = File('${dir.path}/mine.ssgbackup');
      await existing.writeAsBytes([7, 7, 7]);
      final saved = await storageChoosing(existing.path).saveDocument(
        suggestedName: 'secureshellgo-2026-10-21.ssgbackup',
        bytes: Uint8List.fromList([9]),
      );
      expect(saved!.displayName, 'mine.ssgbackup');
      expect(await existing.readAsBytes(), [9]);
    });

    test('backing out saves nothing', () async {
      final saved = await storageChoosing(null).saveDocument(
        suggestedName: 'x.ssgbackup',
        bytes: Uint8List.fromList([9]),
      );
      expect(saved, isNull);
      expect(dir.listSync(), isEmpty);
    });

    test('replaces a file that was there', () async {
      final target = File('${dir.path}/old.ssgbackup');
      await target.writeAsBytes([0, 0, 0, 0, 0, 0]);
      await storageChoosing(target.path).saveDocument(
        suggestedName: 'x.ssgbackup',
        bytes: Uint8List.fromList([5, 5]),
      );
      expect(await target.readAsBytes(), [5, 5]);
      expect(dir.listSync(), hasLength(1));
    });

    test('a place that cannot be written is reported, not thrown raw',
        () async {
      await expectLater(
        storageChoosing('${dir.path}/missing/folder/x.ssgbackup').saveDocument(
          suggestedName: 'x.ssgbackup',
          bytes: Uint8List.fromList([1]),
        ),
        throwsA(isA<DeviceStorageException>()),
      );
    });
  });

  group('MethodChannelDeviceStorage.saveDocument', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannelDeviceStorage.channel;

    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('sends the name, type and bytes, and reads back where it went',
        () async {
      MethodCall? seen;
      messenger.setMockMethodCallHandler(channel, (call) async {
        seen = call;
        return {'displayName': 'b (1).ssgbackup', 'uri': 'content://x/1'};
      });
      final saved = await const MethodChannelDeviceStorage().saveDocument(
        suggestedName: 'b.ssgbackup',
        bytes: Uint8List.fromList([7, 8]),
        mimeType: 'application/octet-stream',
      );
      expect(seen!.method, 'saveDocument');
      expect(seen!.arguments['fileName'], 'b.ssgbackup');
      expect(seen!.arguments['mimeType'], 'application/octet-stream');
      expect(seen!.arguments['bytes'], [7, 8]);
      expect(saved!.displayName, 'b (1).ssgbackup');
      expect(saved.location, 'content://x/1');
    });

    test('a cancelled picker is null', () async {
      messenger.setMockMethodCallHandler(channel, (call) async => null);
      expect(
        await const MethodChannelDeviceStorage().saveDocument(
          suggestedName: 'b.ssgbackup',
          bytes: Uint8List(1),
        ),
        isNull,
      );
    });

    test('a platform failure becomes a message for the user', () async {
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => throw PlatformException(code: 'no_picker'),
      );
      await expectLater(
        const MethodChannelDeviceStorage().saveDocument(
          suggestedName: 'b.ssgbackup',
          bytes: Uint8List(1),
        ),
        throwsA(
          isA<DeviceStorageException>().having(
            (e) => e.message,
            'message',
            'No app on this device can save files.',
          ),
        ),
      );
    });
  });

  group('BackupScreen', () {
    late Directory dir;
    late BackupService service;
    late KnownHostsService knownHosts;

    Future<void> build(WidgetTester tester, DeviceStorage storage) async {
      await tester.runAsync(() async {
        dir = await Directory.systemTemp.createTemp('backup_screen_test');
        knownHosts = KnownHostsService(file: File('${dir.path}/kh.json'));
        await knownHosts.trust(
          KnownHostKey(
            hostname: 'a.example.org',
            port: 22,
            keyType: 'ssh-ed25519',
            fingerprint: 'SHA256:${'A' * 43}',
            addedAt: DateTime.utc(2025),
          ),
        );
        service = BackupService(
          hostStore: HostStore(file: File('${dir.path}/hosts.json')),
          snippetStore: SnippetStore(file: File('${dir.path}/s.json')),
          tunnelStore: TunnelStore(file: File('${dir.path}/t.json')),
          bookmarkStore: BookmarkStore(file: File('${dir.path}/b.json')),
          settingsStore: SettingsStore(file: File('${dir.path}/set.json')),
          credentialStore:
              CredentialStore(backend: FakeSecureStorageBackend()),
          knownHosts: knownHosts,
        );
      });
      addTearDown(() async {
        await tester.runAsync(() async {
          if (await dir.exists()) await dir.delete(recursive: true);
        });
      });
      await tester.pumpWidget(
        MaterialApp(
          home: BackupScreen(
            key: ObjectKey(storage),
            service: service,
            deviceStorage: storage,
          ),
        ),
      );
    }

    testWidgets('offers Save to… only when the storage can ask where',
        (tester) async {
      await build(tester, _DownloadsOnly());
      expect(find.text('Save to…'), findsNothing);
      expect(find.text('Export to a file'), findsOneWidget);

      await build(tester, _WithSaveAs());
      expect(find.text('Save to…'), findsOneWidget);
      expect(find.text('Save to Downloads'), findsOneWidget);
    });

    testWidgets('Save to… writes an encrypted backup with host keys',
        (tester) async {
      final storage = _WithSaveAs();
      await build(tester, storage);

      await tester.tap(find.text('Save to…'));
      await tester.pumpAndSettle();
      expect(find.text('Include trusted host keys'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextField, 'Passphrase'),
        'a very good passphrase',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Confirm passphrase'),
        'a very good passphrase',
      );
      await tester.tap(find.text('Include trusted host keys'));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Export'));
      await tester.pump();

      // The key derivation runs in a real isolate; its result comes back
      // through the test's fake clock, so both have to be turned.
      for (var i = 0; i < 300 && !storage.saved.isCompleted; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump();
      }
      final saved = await storage.saved.future;
      await tester.pump();
      await tester.pump();
      expect(saved.name, endsWith('.ssgbackup'));
      expect(
        find.text('Saved backup-on-drive.ssgbackup.', skipOffstage: false),
        findsOneWidget,
      );
      expect(storage.written, isEmpty);

      final plain = await tester.runAsync(
        () => BackupCrypto.decrypt(
          file: saved.bytes,
          passphrase: 'a very good passphrase',
          useIsolate: false,
        ),
      );
      final json = jsonDecode(utf8.decode(plain!)) as Map<String, dynamic>;
      expect(json['includesKnownHosts'], isTrue);
      expect((json['knownHosts'] as List).single['hostname'], 'a.example.org');
      // And the passphrase can never reach the diagnostics log.
      expect(
        DiagnosticsLog.instance.scrubber.scrub('[a very good passphrase]'),
        '[[redacted]]',
      );
      DiagnosticsLog.instance.scrubber.forgetAll();
    });
  });
}
