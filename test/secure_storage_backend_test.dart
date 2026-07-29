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
}
