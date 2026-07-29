import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Resolves the on-disk root for this app's plain-JSON stores — `hosts.json`
/// (`HostStore`), `known_hosts.json` (`KnownHostsService`) and
/// `settings.json` (`SettingsStore`) all live directly inside whatever
/// directory this returns, the same way all three already resolve their
/// file via `getApplicationDocumentsDirectory()` today.
///
/// On Android/iOS this is unchanged: `getApplicationDocumentsDirectory()`,
/// the app's private per-app documents directory — there is no user-visible
/// "Documents" folder in the mobile sense to collide with. On desktop,
/// though, "Documents" *is* the user's own visible folder
/// (`~/Documents`, `%USERPROFILE%\Documents`), which is a poor place for an
/// app's config files to turn up unannounced and unnamespaced. This resolves
/// to the platform's real per-app data location instead:
///
///  - **Linux**: `$XDG_DATA_HOME/<app id>` (typically
///    `~/.local/share/com.dhivalabs.secure_shell_go`) —
///    `getApplicationSupportDirectory()` already appends the app id here.
///  - **Windows**: `%APPDATA%\<company>\<product>` (from the exe's
///    `VERSIONINFO`, see `windows/runner/Runner.rc`) —
///    `getApplicationSupportDirectory()` already namespaces this too.
///  - **macOS**: `~/Library/Application Support/<bundle id>` — *unlike*
///    Linux and Windows, path_provider's macOS backend hands back the
///    *shared* `Application Support` root and leaves namespacing to the
///    caller, so [resolve] appends [macosBundleId] itself.
class AppDataPaths {
  const AppDataPaths._();

  /// This app's macOS bundle identifier
  /// (`macos/Runner/Configs/AppInfo.xcconfig`'s `PRODUCT_BUNDLE_IDENTIFIER`).
  /// Appended by hand because, unique among the three desktop platforms,
  /// path_provider's macOS `getApplicationSupportDirectory()` does not
  /// namespace it for you — see the class doc.
  static const String macosBundleId = 'com.dhivalabs.secureShellGo';

  /// The pure decision of which path_provider directory backs the JSON
  /// stores, and what (if anything) needs appending to it. Kept free of
  /// `dart:io`/path_provider so it is unit-testable without a platform
  /// channel; [resolveDirectory] is the thin async wrapper that supplies the
  /// real paths and does the actual directory creation.
  static String resolve({
    required bool isDesktop,
    required bool isMacOS,
    required String documentsPath,
    required String applicationSupportPath,
  }) {
    if (!isDesktop) return documentsPath;
    if (isMacOS) return '$applicationSupportPath/$macosBundleId';
    return applicationSupportPath;
  }

  /// The real, OS-specific directory, created if it does not exist yet —
  /// matching `getApplicationDocumentsDirectory()`'s existing guarantee that
  /// there is somewhere to write into as soon as it returns.
  static Future<Directory> resolveDirectory() async {
    final isDesktop = Platform.isLinux || Platform.isWindows || Platform.isMacOS;
    final String path;
    if (isDesktop) {
      final support = await getApplicationSupportDirectory();
      path = resolve(
        isDesktop: true,
        isMacOS: Platform.isMacOS,
        documentsPath: '',
        applicationSupportPath: support.path,
      );
    } else {
      final documents = await getApplicationDocumentsDirectory();
      path = documents.path;
    }
    final dir = Directory(path);
    await dir.create(recursive: true);
    return dir;
  }
}
