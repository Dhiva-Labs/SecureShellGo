/// This build's version, exactly as `pubspec.yaml` has it: `name+build`.
///
/// The app has no plugin that reads its version at run time, so it is
/// written down here, once, for everything that shows or reports it — the
/// About box and the diagnostics log. `diagnostics_log_test.dart` fails the
/// build when this and `pubspec.yaml` drift apart, so a release bump that
/// forgets this file cannot ship.
const String appVersion = '1.5.0+13';

/// [appVersion] as people read it, without the build number.
String get appDisplayVersion => appVersion.split('+').first;
