import 'package:flutter/services.dart';

/// Keeps the screen on for the duration of an active SSH session, when the
/// user has opted in via Settings.
///
/// A one-method hand-rolled channel rather than a plugin (e.g. `wakelock_plus`)
/// — the same call `StorageBridge.kt` already made for MediaStore access:
/// this app has stayed at zero third-party native dependencies on a toolchain
/// (AGP 9 / Kotlin 2.3) that has been unkind to plugins in this space, and a
/// single `FLAG_KEEP_SCREEN_ON` toggle is a poor reason to break that streak.
/// See `MainActivity.kt` for the platform side.
abstract class KeepAwakeController {
  Future<void> setEnabled(bool enabled);
}

class MethodChannelKeepAwake implements KeepAwakeController {
  const MethodChannelKeepAwake();

  static const MethodChannel channel =
      MethodChannel('com.dhivalabs.secure_shell_go/keep_awake');

  @override
  Future<void> setEnabled(bool enabled) async {
    try {
      await channel.invokeMethod<void>('setEnabled', <String, dynamic>{
        'enabled': enabled,
      });
    } on MissingPluginException {
      // Desktop/test runs: nothing to set.
    } on PlatformException {
      // Screen timeout is a convenience, not a correctness issue — not worth
      // surfacing a failure over.
    }
  }
}
