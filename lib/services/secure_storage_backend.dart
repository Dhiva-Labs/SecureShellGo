import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Thin seam over the secure-storage backend.
///
/// Everything that needs the platform's protected store talks to this
/// instead of `FlutterSecureStorage` directly, so tests can substitute an
/// in-memory fake instead of the real backend (which needs a platform
/// channel and does not run under plain `flutter test`) — the same reason
/// `KnownHostsService` and `HostStore` take an injectable `File` instead of
/// resolving one themselves.
///
/// [write] is the one method a caller must not treat as "fire and forget":
/// on every platform this project ships to, the backend is something that
/// can be locked, missing or refused (see [FlutterSecureStorageBackend]'s
/// doc for the Linux case this project treats as a certainty rather than a
/// hypothetical), and there is no plaintext fallback anywhere in this class
/// or its callers — a write that cannot be protected throws
/// [SecureStorageUnavailableException] instead of silently succeeding
/// unprotected. [read] and [delete] fail closed instead (return null / do
/// nothing), matching how every other store in this app already treats "the
/// key/file could not be read" the same as "there is nothing there" —
/// see `KnownHostsService` and `HostStore`.
abstract class SecureStorageBackend {
  Future<void> write(String key, String value);
  Future<String?> read(String key);
  Future<void> delete(String key);
}

/// What the user can actually *do* about a failed write, so a screen can
/// offer a button instead of only an apology.
///
/// This exists because the original failure was a dead end: "no keyring"
/// with nowhere to go left the user unable to save a credential at all, on
/// every snap install and every desktop with no Secret Service daemon
/// running. Which remedy applies is a decision only
/// `CompositeSecureStorageBackend` can make — see its selection rule — so it
/// travels on the exception rather than being re-derived by each screen.
enum SecureStorageRemedy {
  /// Nothing specific to offer: show the message and stop.
  none,

  /// No OS keyring has ever worked on this install and no vault exists yet.
  /// The caller may offer to set an app passphrase and keep secrets in the
  /// passphrase vault instead.
  offerVault,

  /// A passphrase vault exists but is sealed for this session. The caller
  /// should ask for its passphrase, not offer to make a new one.
  unlockVault,

  /// The OS keyring has worked on this install before, so it is installed
  /// and merely locked right now. The fix is to unlock it. Deliberately
  /// *not* [offerVault]: see `CompositeSecureStorageBackend` for why a
  /// working keyring is never quietly traded for a vault.
  unlockKeyring,
}

/// Thrown by [FlutterSecureStorageBackend.write] when the platform could not
/// protect the secret — a locked or absent Linux keyring being the case this
/// project treats as certain rather than hypothetical: a headless box, a
/// session with no Secret Service provider running, or a login keyring the
/// desktop environment never unlocked.
///
/// There is deliberately no plaintext-fallback path anywhere near this type:
/// its entire purpose is to make that failure loud instead of quiet. Callers
/// should show [message] to the user rather than swallow this, and offer
/// whatever [remedy] names.
class SecureStorageUnavailableException implements Exception {
  const SecureStorageUnavailableException(
    this.message, {
    this.code,
    this.remedy = SecureStorageRemedy.none,
  });

  /// A message fit for a dialog: what happened, and — where known — what to
  /// do about it.
  final String message;

  /// The platform's error code (e.g. `KeyringLocked` on Linux), when the
  /// platform reported one. Null otherwise.
  final String? code;

  /// The way forward this failure leaves open, if any.
  final SecureStorageRemedy remedy;

  @override
  String toString() => message;
}

/// The exact command a snap user has to run. snapd does not auto-connect
/// `password-manager-service` for anything but brand-store snaps, so a
/// freshly installed snap has the interface declared and unconnected, and
/// every keyring call fails until this is run once.
const String snapKeyringConnectCommand =
    'snap connect secureshellgo:password-manager-service';

/// Whether this process is running from inside a snap package.
///
/// snapd sets `SNAP` (the mount point of the squashfs) and `SNAP_NAME` for
/// everything it launches; either being present is enough, and neither is
/// set for a deb, a tarball or a `flutter run` build. [environment] is for
/// tests — nothing else should pass it, since [Platform.environment] is the
/// only honest answer at runtime.
bool isRunningAsSnap({Map<String, String>? environment}) {
  final env = environment ?? Platform.environment;
  return (env['SNAP'] ?? '').isNotEmpty || (env['SNAP_NAME'] ?? '').isNotEmpty;
}

/// The "the keyring did not answer" message, with the *actionable* half
/// chosen for where this build is actually running.
///
/// Telling a snap user to "install GNOME Keyring" is worse than useless:
/// they almost certainly have one running, and the real reason the write
/// failed is that the snap's interface to it is not connected. So the snap
/// case names the one command that fixes it, and every other Linux install
/// keeps the generic advice.
///
/// Neither half claims no keyring is *installed*. The Linux plugin raises
/// one code, `KeyringLocked`, for three different situations — no Secret
/// Service provider reachable at all, a provider running with no collection
/// aliased "default", and a default collection that simply would not
/// unlock — and nothing on the Dart side can tell them apart. "Could not be
/// reached or unlocked" is the strongest claim that is true in all three.
String keyringUnavailableMessage({Map<String, String>? environment}) {
  if (isRunningAsSnap(environment: environment)) {
    return 'Your system keyring could not be reached or unlocked. This snap '
        'has not been granted access to it — snapd does not connect that '
        'interface automatically. Run:\n\n'
        '    $snapKeyringConnectCommand\n\n'
        'then try again. SecureShell Go will not store this credential '
        'unprotected.';
  }
  return 'Your system keyring could not be reached or unlocked. It may not '
      'be running, or it may be locked — start or unlock a Secret Service '
      'provider (GNOME Keyring, KWallet) and try again. SecureShell Go will '
      'not store this credential unprotected.';
}

/// Maps a [PlatformException] thrown by the `flutter_secure_storage` write
/// path to a [SecureStorageUnavailableException] with a message fit to show
/// the user. A free function rather than a method so it is unit-testable
/// without a platform channel: constructing a [PlatformException] by hand and
/// checking the mapped message needs no plugin binding at all.
SecureStorageUnavailableException mapSecureStorageWriteError(
  PlatformException e, {
  Map<String, String>? environment,
}) {
  if (e.code == 'KeyringLocked') {
    return SecureStorageUnavailableException(
      keyringUnavailableMessage(environment: environment),
      code: e.code,
    );
  }
  return SecureStorageUnavailableException(
    'The system secure-storage service refused to save this credential'
    '${e.code.isEmpty ? '' : ' (${e.code})'}. SecureShell Go will not save '
    'it unprotected.',
    code: e.code.isEmpty ? null : e.code,
  );
}

/// Production backend.
///
/// What actually protects the secret is platform-specific:
///  - **Android**: Keystore-backed `EncryptedSharedPreferences`.
///  - **Linux**: the Secret Service API (`libsecret`) — in practice
///    GNOME Keyring or KWallet — which is itself encrypted at rest with a
///    key derived from the user's login password. If no Secret Service
///    provider is reachable or the default collection cannot be unlocked,
///    the platform plugin throws `PlatformException(code: 'KeyringLocked')`
///    (see `flutter_secure_storage_linux`'s `Secret.hpp::warmupKeyring`);
///    [write] turns that into [SecureStorageUnavailableException] rather
///    than falling back to an unprotected file — there is no such fallback
///    to fall back to.
///  - **Windows**: DPAPI, via the Credential Manager (`CredWrite`/`CredRead`),
///    keyed to the logged-in user.
///  - **macOS**: the login Keychain, scoped to this app's own default
///    keychain-access group (no shared `keychain-access-groups` entitlement
///    is configured, because nothing here ever sets `kSecAttrAccessGroup`).
class FlutterSecureStorageBackend implements SecureStorageBackend {
  FlutterSecureStorageBackend() : _storage = const FlutterSecureStorage();

  /// A key that is vanishingly unlikely to have ever been written, used by
  /// [isAvailable] to force the platform to reach the keyring/keychain
  /// without disturbing anything a caller actually saved.
  static const String _probeKey = '.secure_storage_availability_probe';

  final FlutterSecureStorage _storage;

  @override
  Future<void> write(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
    } on PlatformException catch (e) {
      throw mapSecureStorageWriteError(e);
    }
  }

  @override
  Future<String?> read(String key) async {
    try {
      return await _storage.read(key: key);
    } on PlatformException {
      // A secret that cannot be read is, to every caller in this app,
      // indistinguishable from one that was never saved — every store here
      // already fails closed on that (KnownHostsService, HostStore):
      // re-prompting the user is the safe direction, not guessing at a
      // value that might not be what they last saved.
      return null;
    }
  }

  @override
  Future<void> delete(String key) async {
    try {
      await _storage.delete(key: key);
    } on PlatformException {
      // Best-effort: nothing to clean up if the store cannot be reached.
    }
  }

  /// Best-effort, non-destructive check for whether this platform's secure
  /// storage can protect a secret right now, without writing one — meant for
  /// a settings/host-editor screen to show a warning up front rather than
  /// only learning about a locked keyring when [write] throws.
  ///
  /// Not authoritative: the keyring can lock between this call and the next
  /// [write]. [write]'s success, or the [SecureStorageUnavailableException]
  /// it throws, is the only source of truth.
  Future<bool> isAvailable() async {
    try {
      // Reading a key that (almost certainly) does not exist still forces
      // the platform to reach the keyring/keychain — on Linux in
      // particular, `getItem` calls `warmupKeyring()` regardless of whether
      // the key is present, so a locked or missing collection surfaces here
      // without this method ever writing anything.
      await _storage.read(key: _probeKey);
      return true;
    } on PlatformException {
      return false;
    }
  }
}
