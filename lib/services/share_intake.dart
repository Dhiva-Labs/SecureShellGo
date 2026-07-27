import 'package:flutter/services.dart';

import 'device_storage.dart';

/// The Dart half of the share-sheet channel: files another app handed us
/// through its Share menu.
///
/// The payload is the same shape the upload picker produces — the platform
/// side stages each shared document into app cache and reports a path, a name
/// and a size, read here by [parseStagedFiles] — so everything downstream of
/// this point (the collision plan, the queue, progress, cancel) is the
/// ordinary upload path with a different starting point.
///
/// Two arrival cases, one code path. Cold start: the activity was launched
/// *by* the share, so the intent is already waiting before Flutter has drawn
/// anything, and the app asks for it once it is up ([takePending]). Warm: the
/// activity is alive and gets `onNewIntent`, so the platform side calls
/// `shareAvailable` and the app pulls the same way. Staging happens when the
/// files are taken rather than when the intent lands, so sharing a 2 GB video
/// does not stall the launch.
class ShareIntake {
  ShareIntake({MethodChannel? channel}) : _channel = channel ?? defaultChannel;

  static const MethodChannel defaultChannel =
      MethodChannel('com.dhivalabs.secure_shell_go/share');

  final MethodChannel _channel;

  /// Takes whatever share is waiting, staging it. Empty if there is none.
  Future<List<PickedLocalFile>> takePending() async {
    try {
      final result = await _channel.invokeMethod<Object?>('takePendingShare');
      return parseStagedFiles(result);
    } on PlatformException {
      // A share that cannot be staged cannot be uploaded; the caller shows
      // nothing rather than an error about something the user may not
      // remember starting.
      return const [];
    } on MissingPluginException {
      // Desktop and test runs: no share sheet to receive from.
      return const [];
    }
  }

  /// Calls [onFiles] whenever a share arrives while the app is running.
  void listen(void Function(List<PickedLocalFile> files) onFiles) {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'shareAvailable') return null;
      final files = await takePending();
      if (files.isNotEmpty) onFiles(files);
      return null;
    });
  }

  void stop() => _channel.setMethodCallHandler(null);
}
