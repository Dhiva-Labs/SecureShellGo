import 'dart:io';

import 'package:flutter/services.dart';

/// Whether this device can back the app lock at all.
enum AppLockSupport {
  /// There is a credential to check against, and a way to check it.
  available,

  /// The platform can do this, but the user has no screen lock set up. The
  /// setting is offered and refused with an explanation rather than hidden:
  /// "your device has no PIN" is actionable, a missing row is not.
  noDeviceCredential,

  /// Nothing to call on this platform. See [AppLockPlatform.reasonFor].
  unsupportedPlatform,
}

/// How one authentication attempt ended.
enum AppLockOutcome {
  success,

  /// A wrong fingerprint or PIN. The only outcome that counts toward the
  /// cooldown — see [AppLockController].
  failed,

  /// The user dismissed the prompt. Deliberately *not* a failure: backing out
  /// of the sheet is not a guess at the credential, and treating it as one
  /// would let a pocket-tap walk someone into a lockout.
  cancelled,

  /// The platform itself has rate-limited biometrics (Android's
  /// `ERROR_LOCKOUT`). The app's own cooldown stays out of the way here — the
  /// OS is already holding the door.
  lockedOut,

  /// The prompt could not be shown at all.
  unavailable,
}

/// The OS-authentication half of the app lock.
///
/// An interface rather than a bare channel call, for the reason this codebase
/// gives everywhere else (`session_foreground.dart`, `keep_awake.dart`): the
/// interesting logic is *when* to demand authentication and what to do when
/// it fails, and that has to be testable without a device.
abstract class AppLockAuthenticator {
  Future<AppLockSupport> support();

  /// Shows the OS prompt. [reason] is what the sheet tells the user it is
  /// for.
  Future<AppLockOutcome> authenticate({required String reason});

  /// Asks the platform to keep the app's contents out of screenshots and the
  /// recent-apps thumbnail.
  ///
  /// Part of this interface rather than a loose channel call because it is
  /// the same platform capability seen from a different angle, and because it
  /// has to be turned on the moment the *setting* is enabled — not when the
  /// gate goes up. The launcher's thumbnail is captured as the app leaves, so
  /// by the time a lock screen is drawn the picture of the terminal behind it
  /// already exists.
  Future<void> setSecureDisplay(bool enabled);
}

/// What each platform actually got, and why.
///
/// The short version: **Android and Windows are implemented; Linux and macOS
/// report the setting as unavailable.** The long version is worth writing
/// down, because "we ran out of time" and "this cannot be done safely with
/// what we have" are very different answers and only one of them is true
/// here.
///
///  * **Android** — implemented, through `AppLockBridge.kt` on a hand-rolled
///    method channel, matching this project's standing policy of zero
///    third-party native dependencies (see `StorageBridge.kt`). It uses the
///    *framework* `android.hardware.biometrics.BiometricPrompt` rather than
///    `androidx.biometric`, specifically so that no new Gradle dependency is
///    needed: API 30+ gets
///    `setAllowedAuthenticators(BIOMETRIC_STRONG or DEVICE_CREDENTIAL)`, API
///    28–29 gets the deprecated `setDeviceCredentialAllowed(true)`, and API
///    23–27 falls back to `KeyguardManager`'s
///    `createConfirmDeviceCredentialIntent`.
///    So device-credential fallback exists on every level this app supports.
///
///  * **Linux** — *not* implemented, and this is a judgement about
///    correctness rather than effort. The reachable mechanism without a new
///    dependency is polkit via `pkexec`, and polkit answers the wrong
///    question: it authenticates *an administrator* in order to run something
///    as root. Two consequences make it unusable as a personal screen lock.
///    A user who is not in the admin group could never unlock their own app —
///    which would breach the rule that a lock must never permanently lock
///    someone out of their own data — and on a shared machine any *other*
///    admin could unlock it, which is precisely the person a lock is for.
///    Escalating to root to reveal a terminal UI is disproportionate on top
///    of that. The correct API is a PAM conversation, which means hand-rolled
///    `dart:ffi` interop against `libpam` — genuinely possible, but delicate
///    native code on the authentication path is not something to write
///    unverified.
///
///  * **Windows** — implemented, through Windows Hello:
///    `UserConsentVerifier::RequestVerificationForWindowAsync` in C++/WinRT
///    (`windows/runner/windows_hello.cpp`), on the same channel and with the
///    same answers as the Android bridge. Hello is the PIN, fingerprint or
///    face the user signs in to Windows with. See [WindowsHelloAppLock] for
///    how it fails closed, and for why there is no screenshot flag.
///
///  * **macOS** — not implemented: `LAContext` (`LocalAuthentication`) needs
///    Swift in `macos/Runner`, which cannot be built or exercised here. The
///    tractable follow-up — roughly forty lines of native in a runner that
///    already exists — for someone who can build and test on a Mac. Linux
///    needs a real decision about PAM first.
class AppLockPlatform {
  const AppLockPlatform._();

  /// The sentence Settings shows under a disabled toggle. Phrased as a fact
  /// about the platform, not an apology, and never implies the user has done
  /// something wrong.
  static String reasonFor({
    required bool isLinux,
    required bool isWindows,
    required bool isMacOS,
  }) {
    if (isLinux) {
      return 'Linux has no per-app unlock that SecureShell Go can use '
          'without administrator rights, which would lock out anyone who '
          'does not have them.';
    }
    if (isWindows) {
      return 'Windows Hello is turned off or not supported on this PC.';
    }
    if (isMacOS) {
      return 'Touch ID and password unlock are not available in this build '
          'yet.';
    }
    return 'App lock is not available on this platform.';
  }

  /// [reasonFor] for the platform this build is running on.
  static String get currentReason => reasonFor(
        isLinux: Platform.isLinux,
        isWindows: Platform.isWindows,
        isMacOS: Platform.isMacOS,
      );

  /// What Settings says when the platform can lock the app but the user has
  /// nothing set up to unlock it with ([AppLockSupport.noDeviceCredential]).
  static String setupHintFor({required bool isWindows}) => isWindows
      ? 'Set up Windows Hello (a PIN, fingerprint or face) in Windows '
          'Settings first, then this can be turned on.'
      : 'Set a screen lock (PIN, pattern, password or biometric) on this '
          'device first, then this can be turned on.';

  /// [setupHintFor] for the platform this build is running on.
  static String get currentSetupHint =>
      setupHintFor(isWindows: Platform.isWindows);
}

/// Talks to `AppLockBridge.kt`.
///
/// Every failure mode collapses to something safe: if the channel is missing
/// (desktop, unit tests) or the platform throws, [support] reports
/// [AppLockSupport.unsupportedPlatform] and [authenticate] reports
/// [AppLockOutcome.unavailable]. A broken bridge therefore shows the setting
/// as unavailable — it can never leave a lock screen up with no way past it,
/// which is the one failure this feature must not have.
class MethodChannelAppLock implements AppLockAuthenticator {
  const MethodChannelAppLock();

  static const MethodChannel channel =
      MethodChannel('com.dhivalabs.secure_shell_go/app_lock');

  @override
  Future<AppLockSupport> support() async {
    // Only Android has a bridge listening. Asking anyway would work — the
    // MissingPluginException below catches it — but this keeps the desktop
    // path free of an exception on every settings screen build.
    if (!Platform.isAndroid) return AppLockSupport.unsupportedPlatform;
    try {
      final reply = await channel.invokeMethod<String>('support');
      return switch (reply) {
        'available' => AppLockSupport.available,
        'noDeviceCredential' => AppLockSupport.noDeviceCredential,
        _ => AppLockSupport.unsupportedPlatform,
      };
    } on MissingPluginException {
      return AppLockSupport.unsupportedPlatform;
    } on PlatformException {
      return AppLockSupport.unsupportedPlatform;
    }
  }

  @override
  Future<AppLockOutcome> authenticate({required String reason}) async {
    if (!Platform.isAndroid) return AppLockOutcome.unavailable;
    try {
      final reply = await channel.invokeMethod<String>(
        'authenticate',
        <String, dynamic>{'reason': reason},
      );
      return switch (reply) {
        'success' => AppLockOutcome.success,
        'failed' => AppLockOutcome.failed,
        'cancelled' => AppLockOutcome.cancelled,
        'lockedOut' => AppLockOutcome.lockedOut,
        _ => AppLockOutcome.unavailable,
      };
    } on MissingPluginException {
      return AppLockOutcome.unavailable;
    } on PlatformException {
      return AppLockOutcome.unavailable;
    }
  }

  @override
  Future<void> setSecureDisplay(bool enabled) async {
    if (!Platform.isAndroid) return;
    try {
      await channel.invokeMethod<void>(
        'setSecure',
        <String, dynamic>{'enabled': enabled},
      );
    } on MissingPluginException {
      // Desktop and unit-test runs: no window flag to set.
    } on PlatformException {
      // Failing to set FLAG_SECURE costs a thumbnail in the app switcher, not
      // the lock itself. Not worth interrupting the user over.
    }
  }
}

/// Windows Hello, through `windows/runner/windows_hello.cpp`.
///
/// The same channel, methods and answers as [MethodChannelAppLock] — the
/// runner registers its own handler on that channel name — but the failures
/// fold the other way where it matters:
///
///  * [support] that cannot reach the runner reports
///    [AppLockSupport.unsupportedPlatform], so a build without the native
///    half simply never offers the lock.
///  * [authenticate] that throws — anything at all, not only a
///    [PlatformException] — or answers something unknown, reports
///    [AppLockOutcome.cancelled]: the gate stays up with Unlock live. Once
///    Hello has said it is set up, nothing here may answer
///    [AppLockOutcome.unavailable], which opens the gate — the same rule
///    `AppLockBridge.kt` follows, and the reason the controller's fail-open
///    path is for *no credential*, not for *the prompt broke*. Only the
///    runner answers `unavailable`, and only when Hello itself reports it is
///    not set up or is switched off by policy. A gate stuck shut by a
///    persistently broken prompt clears at the next launch, where [support]
///    is asked again.
class WindowsHelloAppLock implements AppLockAuthenticator {
  const WindowsHelloAppLock({
    MethodChannel channel = MethodChannelAppLock.channel,
  })  :
        // ignore: prefer_initializing_formals
        _channel = channel;

  final MethodChannel _channel;

  @override
  Future<AppLockSupport> support() async {
    try {
      final reply = await _channel.invokeMethod<String>('support');
      return switch (reply) {
        'available' => AppLockSupport.available,
        'noDeviceCredential' => AppLockSupport.noDeviceCredential,
        _ => AppLockSupport.unsupportedPlatform,
      };
    } on MissingPluginException {
      return AppLockSupport.unsupportedPlatform;
    } on PlatformException {
      return AppLockSupport.unsupportedPlatform;
    }
  }

  @override
  Future<AppLockOutcome> authenticate({required String reason}) async {
    try {
      final reply = await _channel.invokeMethod<String>(
        'authenticate',
        <String, dynamic>{'reason': reason},
      );
      return switch (reply) {
        'success' => AppLockOutcome.success,
        'failed' => AppLockOutcome.failed,
        'lockedOut' => AppLockOutcome.lockedOut,
        'unavailable' => AppLockOutcome.unavailable,
        _ => AppLockOutcome.cancelled,
      };
    } on MissingPluginException {
      return AppLockOutcome.cancelled;
    } on PlatformException {
      return AppLockOutcome.cancelled;
    } catch (_) {
      // Anything else — a reply of the wrong type is a TypeError, not a
      // PlatformException — must not reach the controller either, which
      // treats an authenticator that throws as one that cannot run and
      // opens the gate.
      return AppLockOutcome.cancelled;
    }
  }

  /// Nothing to do on Windows, on purpose. Android needs the flag because
  /// its recent-apps thumbnail is a snapshot taken as the app leaves, before
  /// the lock screen exists. Taskbar and Alt+Tab previews are live, so they
  /// show the lock screen as soon as it is up. Blocking capture instead
  /// (`WDA_EXCLUDEFROMCAPTURE`) would black the window out of every screen
  /// share for anyone with the lock on — a high price for no gain.
  @override
  Future<void> setSecureDisplay(bool enabled) async {}
}

/// The authenticator for the platform this build is running on.
AppLockAuthenticator createDefaultAppLockAuthenticator() => Platform.isWindows
    ? const WindowsHelloAppLock()
    : const MethodChannelAppLock();
