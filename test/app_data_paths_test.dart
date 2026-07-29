import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/services/app_data_paths.dart';

void main() {
  group('AppDataPaths.resolve', () {
    test('Android/iOS keeps the private documents directory', () {
      expect(
        AppDataPaths.resolve(
          isDesktop: false,
          isMacOS: false,
          documentsPath: '/data/user/0/com.dhivalabs.secure_shell_go/files',
          applicationSupportPath: 'unused',
        ),
        '/data/user/0/com.dhivalabs.secure_shell_go/files',
      );
    });

    test('Linux uses application support as-is (already app-namespaced)', () {
      expect(
        AppDataPaths.resolve(
          isDesktop: true,
          isMacOS: false,
          documentsPath: '/home/alex/Documents',
          applicationSupportPath:
              '/home/alex/.local/share/com.dhivalabs.secure_shell_go',
        ),
        '/home/alex/.local/share/com.dhivalabs.secure_shell_go',
      );
    });

    test('Windows uses application support as-is (already app-namespaced)', () {
      expect(
        AppDataPaths.resolve(
          isDesktop: true,
          isMacOS: false,
          documentsPath: r'C:\Users\Alex\Documents',
          applicationSupportPath:
              r'C:\Users\Alex\AppData\Roaming\com.dhivalabs\SecureShell Go',
        ),
        r'C:\Users\Alex\AppData\Roaming\com.dhivalabs\SecureShell Go',
      );
    });

    test('macOS appends the bundle id to the shared support root', () {
      expect(
        AppDataPaths.resolve(
          isDesktop: true,
          isMacOS: true,
          documentsPath: '/Users/alex/Documents',
          applicationSupportPath: '/Users/alex/Library/Application Support',
        ),
        '/Users/alex/Library/Application Support/'
        '${AppDataPaths.macosBundleId}',
      );
    });

    test('never mixes documents into a desktop result', () {
      // Regression guard: it would be easy to accidentally fall through to
      // documentsPath on a platform branch that forgot to handle isMacOS.
      final result = AppDataPaths.resolve(
        isDesktop: true,
        isMacOS: false,
        documentsPath: '/should/not/appear',
        applicationSupportPath: '/support/path',
      );
      expect(result, isNot(contains('should/not/appear')));
    });
  });
}
