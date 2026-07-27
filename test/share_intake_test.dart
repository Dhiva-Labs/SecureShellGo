import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/device_storage.dart';
import 'package:secure_shell_go/services/share_intake.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('parsing what the platform sends', () {
    test('reads a batch of staged files', () {
      final files = parseStagedFiles(<String, Object?>{
        'files': [
          {'path': '/cache/uploads/b1/0/a.txt', 'name': 'a.txt', 'size': 12},
          {'path': '/cache/uploads/b1/1/b.bin', 'name': 'b.bin', 'size': 4096},
        ],
      });

      expect(files, hasLength(2));
      expect(files.first.path, '/cache/uploads/b1/0/a.txt');
      expect(files.first.name, 'a.txt');
      expect(files.first.size, 12);
      expect(files.last.size, 4096);
    });

    test('accepts a bare list as well as the wrapped map', () {
      final files = parseStagedFiles([
        {'path': '/cache/x/a.txt', 'name': 'a.txt', 'size': 1},
      ]);
      expect(files.single.name, 'a.txt');
    });

    test('null, the wrong shape and an empty batch all read as nothing', () {
      expect(parseStagedFiles(null), isEmpty);
      expect(parseStagedFiles('a string'), isEmpty);
      expect(parseStagedFiles(<String, Object?>{'files': 'nope'}), isEmpty);
      expect(parseStagedFiles(<String, Object?>{'files': []}), isEmpty);
    });

    test('one unusable entry costs that entry, not the whole share', () {
      // A share comes from an arbitrary other app: a provider that has gone
      // away should not take the other four files down with it.
      final files = parseStagedFiles(<String, Object?>{
        'files': [
          {'path': '/cache/x/good.txt', 'name': 'good.txt', 'size': 3},
          {'name': 'no-path.txt', 'size': 3},
          {'path': '', 'name': 'empty-path.txt'},
          'not even a map',
          {'path': '/cache/x/also-good.txt', 'name': 'also-good.txt'},
        ],
      });

      expect(
        files.map((f) => f.name),
        ['good.txt', 'also-good.txt'],
      );
    });

    test('a missing name falls back to the staged file name', () {
      final files = parseStagedFiles(<String, Object?>{
        'files': [
          {'path': '/cache/uploads/b1/0/photo.jpg'},
          {'path': '/cache/uploads/b1/1/x.bin', 'name': '   '},
        ],
      });

      expect(files.map((f) => f.name), ['photo.jpg', 'x.bin']);
    });

    test('a missing or non-numeric size reads as zero rather than throwing',
        () {
      final files = parseStagedFiles(<String, Object?>{
        'files': [
          {'path': '/cache/x/a.txt', 'name': 'a.txt'},
          {'path': '/cache/x/b.txt', 'name': 'b.txt', 'size': 'huge'},
          {'path': '/cache/x/c.txt', 'name': 'c.txt', 'size': 12.9},
        ],
      });

      expect(files.map((f) => f.size), [0, 0, 12]);
    });
  });

  group('taking a pending share', () {
    late List<MethodCall> calls;

    void answerWith(Object? Function() reply) {
      calls = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ShareIntake.defaultChannel, (call) async {
        calls.add(call);
        return reply();
      });
    }

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ShareIntake.defaultChannel, null);
    });

    test('asks the platform once and parses the answer', () async {
      answerWith(() => <String, Object?>{
            'files': [
              {'path': '/cache/x/a.txt', 'name': 'a.txt', 'size': 5},
            ],
          });

      final files = await ShareIntake().takePending();

      expect(calls.map((c) => c.method), ['takePendingShare']);
      expect(files.single.name, 'a.txt');
    });

    test('no share waiting is an empty list, not an error', () async {
      answerWith(() => null);
      expect(await ShareIntake().takePending(), isEmpty);
    });

    test('a platform failure is swallowed rather than shown', () async {
      // The user may not even remember starting this; an error dialog about
      // a share that could not be staged is noise.
      answerWith(() => throw PlatformException(code: 'pick_failed'));
      expect(await ShareIntake().takePending(), isEmpty);
    });

    test('a share arriving while the app runs is pulled and handed over',
        () async {
      answerWith(() => <String, Object?>{
            'files': [
              {'path': '/cache/x/warm.txt', 'name': 'warm.txt', 'size': 1},
            ],
          });

      final intake = ShareIntake();
      addTearDown(intake.stop);
      final received = <List<PickedLocalFile>>[];
      intake.listen(received.add);

      // What MainActivity.onNewIntent does: nudge, do not push the payload.
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        ShareIntake.defaultChannel.name,
        ShareIntake.defaultChannel.codec
            .encodeMethodCall(const MethodCall('shareAvailable')),
        null,
      );

      expect(received.single.single.name, 'warm.txt');
      expect(calls.map((c) => c.method), ['takePendingShare']);
    });

    test('a nudge with nothing behind it notifies nobody', () async {
      answerWith(() => null);

      final intake = ShareIntake();
      addTearDown(intake.stop);
      var called = 0;
      intake.listen((_) => called++);

      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        ShareIntake.defaultChannel.name,
        ShareIntake.defaultChannel.codec
            .encodeMethodCall(const MethodCall('shareAvailable')),
        null,
      );

      expect(called, 0);
    });
  });
}
