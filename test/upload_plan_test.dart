import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/upload_plan.dart';

void main() {
  /// Records what the user was asked, and answers from a script.
  ({
    UploadCollisionPrompt prompt,
    List<String> asked,
    List<bool> offeredApplyToAll,
  }) scripted(List<UploadCollisionResponse?> answers) {
    final asked = <String>[];
    final offered = <bool>[];
    var index = 0;

    Future<UploadCollisionResponse?> prompt(
      String fileName, {
      required bool offerApplyToAll,
    }) async {
      asked.add(fileName);
      offered.add(offerApplyToAll);
      if (index >= answers.length) {
        fail('asked about "$fileName" more times than the script allows');
      }
      return answers[index++];
    }

    return (prompt: prompt, asked: asked, offeredApplyToAll: offered);
  }

  Future<UploadCollisionResponse?> never(
    String fileName, {
    required bool offerApplyToAll,
  }) async =>
      fail('should not have asked about "$fileName"');

  group('no collisions', () {
    test('every file keeps its own name and nothing is asked', () async {
      final plan = await resolveUploadPlan(
        fileNames: ['a.txt', 'b.txt'],
        existingNames: {'other.txt'},
        ask: never,
      );

      expect(plan.cancelled, isFalse);
      expect(plan.skipped, isEmpty);
      expect(plan.uploads.map((u) => u.remoteName), ['a.txt', 'b.txt']);
      expect(plan.uploads.map((u) => u.sourceIndex), [0, 1]);
      expect(plan.uploads.every((u) => !u.overwrite), isTrue);
    });

    test('an empty batch is an empty plan', () async {
      final plan = await resolveUploadPlan(
        fileNames: const [],
        existingNames: const {},
        ask: never,
      );
      expect(plan.isEmpty, isTrue);
      expect(plan.cancelled, isFalse);
    });
  });

  group('one collision', () {
    test('replace keeps the name and flags the overwrite', () async {
      final script = scripted([
        const UploadCollisionResponse(UploadCollisionAction.overwrite),
      ]);

      final plan = await resolveUploadPlan(
        fileNames: ['notes.md'],
        existingNames: {'notes.md'},
        ask: script.prompt,
      );

      expect(script.asked, ['notes.md']);
      // A single-file batch has no "rest of the batch" to apply anything to.
      expect(script.offeredApplyToAll, [false]);
      expect(plan.uploads.single.remoteName, 'notes.md');
      expect(plan.uploads.single.overwrite, isTrue);
    });

    test('keep both de-duplicates the way the download side does', () async {
      final script = scripted([
        const UploadCollisionResponse(UploadCollisionAction.keepBoth),
      ]);

      final plan = await resolveUploadPlan(
        fileNames: ['report.pdf'],
        existingNames: {'report.pdf', 'report (1).pdf'},
        ask: script.prompt,
      );

      expect(plan.uploads.single.remoteName, 'report (2).pdf');
      expect(plan.uploads.single.overwrite, isFalse);
    });

    test('skip leaves the server alone and says so', () async {
      final script = scripted([
        const UploadCollisionResponse(UploadCollisionAction.skip),
      ]);

      final plan = await resolveUploadPlan(
        fileNames: ['a.txt', 'b.txt'],
        existingNames: {'a.txt'},
        ask: script.prompt,
      );

      expect(plan.skipped, ['a.txt']);
      expect(plan.uploads.map((u) => u.remoteName), ['b.txt']);
      expect(plan.uploads.single.sourceIndex, 1);
    });

    test('a dismissed prompt cancels the batch rather than overwriting',
        () async {
      // The important one: a dialog swiped away must never be read as
      // consent to replace someone's file on a server.
      final script = scripted([null]);

      final plan = await resolveUploadPlan(
        fileNames: ['a.txt', 'b.txt'],
        existingNames: {'a.txt'},
        ask: script.prompt,
      );

      expect(plan.cancelled, isTrue);
      expect(plan.uploads, isEmpty);
    });
  });

  group('apply to all', () {
    test('answers every later collision without asking again', () async {
      final script = scripted([
        const UploadCollisionResponse(
          UploadCollisionAction.overwrite,
          applyToAll: true,
        ),
      ]);

      final plan = await resolveUploadPlan(
        fileNames: ['a.txt', 'b.txt', 'c.txt'],
        existingNames: {'a.txt', 'b.txt', 'c.txt'},
        ask: script.prompt,
      );

      expect(script.asked, ['a.txt']);
      expect(script.offeredApplyToAll, [true]);
      expect(plan.uploads.every((u) => u.overwrite), isTrue);
      expect(plan.uploads, hasLength(3));
    });

    test('a sticky "keep both" renames the rest', () async {
      final script = scripted([
        const UploadCollisionResponse(
          UploadCollisionAction.keepBoth,
          applyToAll: true,
        ),
      ]);

      final plan = await resolveUploadPlan(
        fileNames: ['a.txt', 'b.txt'],
        existingNames: {'a.txt', 'b.txt'},
        ask: script.prompt,
      );

      expect(script.asked, ['a.txt']);
      expect(
        plan.uploads.map((u) => u.remoteName),
        ['a (1).txt', 'b (1).txt'],
      );
    });

    test('a sticky "skip" leaves only the files that never collided',
        () async {
      final script = scripted([
        const UploadCollisionResponse(
          UploadCollisionAction.skip,
          applyToAll: true,
        ),
      ]);

      final plan = await resolveUploadPlan(
        fileNames: ['a.txt', 'fresh.txt', 'b.txt'],
        existingNames: {'a.txt', 'b.txt'},
        ask: script.prompt,
      );

      expect(script.asked, ['a.txt']);
      expect(plan.skipped, ['a.txt', 'b.txt']);
      expect(plan.uploads.single.remoteName, 'fresh.txt');
    });

    test('without the tick, every collision is asked about', () async {
      final script = scripted([
        const UploadCollisionResponse(UploadCollisionAction.keepBoth),
        const UploadCollisionResponse(UploadCollisionAction.overwrite),
      ]);

      final plan = await resolveUploadPlan(
        fileNames: ['a.txt', 'b.txt'],
        existingNames: {'a.txt', 'b.txt'},
        ask: script.prompt,
      );

      expect(script.asked, ['a.txt', 'b.txt']);
      expect(plan.uploads[0].remoteName, 'a (1).txt');
      expect(plan.uploads[0].overwrite, isFalse);
      expect(plan.uploads[1].remoteName, 'b.txt');
      expect(plan.uploads[1].overwrite, isTrue);
    });
  });

  group('collisions inside the batch itself', () {
    test('two picked files of the same name do not silently become one',
        () async {
      // Two "photo.jpg" from two folders is the ordinary multi-select, not an
      // exotic case: without claiming names as they are assigned, the second
      // would overwrite the first mid-queue with nothing said.
      final script = scripted([
        const UploadCollisionResponse(UploadCollisionAction.keepBoth),
      ]);

      final plan = await resolveUploadPlan(
        fileNames: ['photo.jpg', 'photo.jpg'],
        existingNames: const {},
        ask: script.prompt,
      );

      expect(script.asked, ['photo.jpg']);
      expect(
        plan.uploads.map((u) => u.remoteName),
        ['photo.jpg', 'photo (1).jpg'],
      );
      expect(plan.uploads.map((u) => u.sourceIndex), [0, 1]);
    });

    test('a name freed by "keep both" is not handed out twice', () async {
      final script = scripted([
        const UploadCollisionResponse(
          UploadCollisionAction.keepBoth,
          applyToAll: true,
        ),
      ]);

      final plan = await resolveUploadPlan(
        fileNames: ['a.txt', 'a.txt', 'a.txt'],
        existingNames: {'a.txt'},
        ask: script.prompt,
      );

      expect(
        plan.uploads.map((u) => u.remoteName),
        ['a (1).txt', 'a (2).txt', 'a (3).txt'],
      );
    });
  });
}
