import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/secure_storage_backend.dart';

void main() {
  group('mapSecureStorageWriteError', () {
    test('a locked/absent Linux keyring names the fix, not just the code',
        () {
      final mapped = mapSecureStorageWriteError(
        PlatformException(code: 'KeyringLocked', message: 'nope'),
      );

      expect(mapped.code, 'KeyringLocked');
      expect(mapped.message, contains('keyring'));
      expect(mapped.message, contains('unlock'));
      // The whole point of this type: never suggest it saved anyway.
      expect(mapped.message, isNot(contains('saved')));
      expect(mapped.toString(), mapped.message);
    });

    test('an unrecognised platform code still refuses, generically', () {
      final mapped = mapSecureStorageWriteError(
        PlatformException(code: 'SomeWeirdError', message: 'boom'),
      );

      expect(mapped.code, 'SomeWeirdError');
      expect(mapped.message, contains('SomeWeirdError'));
      expect(mapped.message, contains('unprotected'));
    });

    test('an empty platform code is reported as null, not an empty string',
        () {
      final mapped = mapSecureStorageWriteError(
        PlatformException(code: '', message: 'boom'),
      );

      expect(mapped.code, isNull);
      expect(mapped.message, isNot(contains('()')));
    });
  });

  group('SecureStorageUnavailableException', () {
    test('toString is the message, for a bare rethrow or a snackbar', () {
      const exception = SecureStorageUnavailableException(
        'could not save this credential',
        code: 'KeyringLocked',
      );
      expect(exception.toString(), 'could not save this credential');
    });
  });

  group('isRunningAsSnap', () {
    test('either snapd variable is enough', () {
      expect(isRunningAsSnap(environment: {'SNAP': '/snap/x/12'}), isTrue);
      expect(isRunningAsSnap(environment: {'SNAP_NAME': 'x'}), isTrue);
    });

    test('an empty value is not a snap', () {
      expect(isRunningAsSnap(environment: {'SNAP': ''}), isFalse);
      expect(isRunningAsSnap(environment: const {}), isFalse);
    });
  });

  group('keyringUnavailableMessage', () {
    test('a snap is told the one command that fixes it', () {
      final message = keyringUnavailableMessage(
        environment: {'SNAP_NAME': 'secureshellgo'},
      );

      expect(message, contains(snapKeyringConnectCommand));
      expect(
        snapKeyringConnectCommand,
        'snap connect secureshellgo:password-manager-service',
      );
      // Pointing a snap user at an installer is the wrong advice: they
      // almost certainly have a keyring, just no interface to it.
      expect(message, isNot(contains('GNOME Keyring')));
    });

    test('every other Linux install keeps the generic advice', () {
      final message = keyringUnavailableMessage(environment: const {});

      expect(message, contains('GNOME Keyring'));
      expect(message, isNot(contains('snap ')));
    });

    test('neither claims a keyring is missing when it may only be locked',
        () {
      // The Linux plugin raises one code for "nothing reachable", "no default
      // collection" and "locked", so any wording that asserts one of the
      // three will be wrong for the other two.
      for (final message in [
        keyringUnavailableMessage(environment: const {}),
        keyringUnavailableMessage(environment: {'SNAP': '/snap/x/12'}),
      ]) {
        expect(message, contains('could not be reached or unlocked'));
        expect(message, isNot(contains('is not installed')));
        expect(message, contains('unprotected'));
      }
    });
  });
}
