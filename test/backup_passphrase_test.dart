import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/backup_passphrase.dart';

void main() {
  group('the hard gate', () {
    test('is a minimum length and nothing else', () {
      expect(BackupPassphrase.minLength, greaterThanOrEqualTo(12));
      expect(BackupPassphrase.isAcceptable('short'), isFalse);
      expect(BackupPassphrase.isAcceptable('elevenchars'), isFalse);
      expect(BackupPassphrase.isAcceptable('twelvechars!'), isTrue);
    });

    test('does not demand a digit or a symbol', () {
      // Four unrelated words beat `Password1!` comfortably and would fail a
      // character-class rule, which is exactly why there is not one.
      expect(
        BackupPassphrase.isAcceptable('correct horse battery staple'),
        isTrue,
      );
      expect(
        BackupPassphrase.strengthOf('correct horse battery staple'),
        isNot(PassphraseStrength.tooShort),
      );
    });

    test('an empty passphrase is never acceptable', () {
      expect(BackupPassphrase.isAcceptable(''), isFalse);
      expect(BackupPassphrase.strengthOf(''), PassphraseStrength.tooShort);
    });
  });

  group('strength buckets', () {
    test('too short below the minimum', () {
      expect(BackupPassphrase.strengthOf('abc'), PassphraseStrength.tooShort);
    });

    test('a held-down key is weak however long it is', () {
      expect(
        BackupPassphrase.strengthOf('aaaaaaaaaaaaaaaaaaaaaaaaaaaa'),
        PassphraseStrength.weak,
      );
    });

    test('a long, varied passphrase is strong', () {
      expect(
        BackupPassphrase.strengthOf(r'Tr0ub4dor&3-horse-battery!'),
        PassphraseStrength.strong,
      );
    });

    test('a bare minimum passphrase is weak, not rejected', () {
      final strength = BackupPassphrase.strengthOf('abcdefghijkl');
      expect(strength, PassphraseStrength.weak);
      // Weak is advice. The user is entitled to decide their own trade.
      expect(BackupPassphrase.isAcceptable('abcdefghijkl'), isTrue);
    });

    test('length alone can carry a passphrase upward', () {
      expect(
        BackupPassphrase.strengthOf('abcdefghijklmnop'),
        PassphraseStrength.weak,
      );
      expect(
        BackupPassphrase.strengthOf(
          'the quick brown fox jumps over the lazy dog',
        ),
        PassphraseStrength.fair,
      );
    });

    test('every bucket has a label', () {
      for (final strength in PassphraseStrength.values) {
        expect(strength.label, isNotEmpty);
      }
    });
  });

  group('hints', () {
    test('say what would actually help', () {
      expect(BackupPassphrase.hintFor('abc'), contains('12'));
      expect(
        BackupPassphrase.hintFor('abcdefghijkl'),
        contains('unrelated words'),
      );
      expect(
        BackupPassphrase.hintFor(r'Tr0ub4dor&3-horse-battery!'),
        'Strong.',
      );
    });

    test('never claim an entropy figure they cannot know', () {
      // A confident "78 bits" next to a passphrase the user reuses everywhere
      // would be a lie told with a progress bar.
      for (final candidate in [
        '',
        'abc',
        'abcdefghijkl',
        r'Tr0ub4dor&3-horse-battery!',
      ]) {
        final hint = BackupPassphrase.hintFor(candidate);
        expect(hint, isNot(contains('bits')));
        expect(hint, isNot(contains('%')));
      }
    });
  });
}
