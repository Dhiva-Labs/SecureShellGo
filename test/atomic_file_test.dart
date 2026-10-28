import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/atomic_file.dart';

void main() {
  late Directory tempDir;
  late File file;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('atomic_file_test');
    file = File('${tempDir.path}/store.json');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  group('atomicWrite', () {
    test('a failed write leaves the old contents and no debris', () async {
      await file.writeAsString('old');
      await expectLater(
        atomicWrite(file, (temp) async {
          await temp.writeAsString('half');
          throw const FileSystemException('disk full');
        }),
        throwsA(isA<FileSystemException>()),
      );
      expect(await file.readAsString(), 'old');
      expect(tempDir.listSync(), hasLength(1));
    });

    test('two writes in flight never share a temp file', () async {
      // Under a fixed `.tmp` name the second write truncated the first's
      // temp mid-fill and one rename then failed with the temp gone.
      final first = Completer<void>();
      final temps = <String>[];
      final a = atomicWrite(file, (temp) async {
        temps.add(temp.path);
        await temp.writeAsString('a');
        await first.future;
      });
      final b = atomicWrite(file, (temp) async {
        temps.add(temp.path);
        await temp.writeAsString('b');
      });
      await b;
      first.complete();
      await a;
      expect(temps.toSet(), hasLength(2));
    });
  });

  group('SerialFileWriter', () {
    test('runs writes one at a time, in the order asked', () async {
      final writer = SerialFileWriter();
      final log = <String>[];
      final slow = Completer<void>();

      final first = writer.run(() async {
        log.add('first starts');
        await slow.future;
        log.add('first ends');
      });
      final second = writer.run(() async => log.add('second'));

      await Future<void>.delayed(Duration.zero);
      expect(log, ['first starts'], reason: 'second waits its turn');
      slow.complete();
      await Future.wait([first, second]);
      expect(log, ['first starts', 'first ends', 'second']);
    });

    test('a failed write is reported and does not block the next', () async {
      final writer = SerialFileWriter();
      final failed = writer.run(() async => throw StateError('boom'));
      final next = writer.run(() async {});
      await expectLater(failed, throwsStateError);
      await expectLater(next, completes);
    });
  });

  group('setAsideUnreadable', () {
    test('moves the file beside itself, contents intact', () async {
      await file.writeAsString('unreadable but precious');
      await setAsideUnreadable(file);

      expect(await file.exists(), isFalse);
      final aside = tempDir.listSync().whereType<File>().single;
      expect(aside.parent.path, tempDir.path);
      expect(aside.uri.pathSegments.last, startsWith('store.json.corrupt-'));
      expect(await aside.readAsString(), 'unreadable but precious');
    });

    test('is a no-op for a missing file or none at all', () async {
      await setAsideUnreadable(file);
      await setAsideUnreadable(null);
      expect(tempDir.listSync(), isEmpty);
    });
  });
}
