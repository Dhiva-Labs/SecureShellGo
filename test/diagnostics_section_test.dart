import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/app_settings.dart';
import 'package:secure_shell_go/screens/settings/diagnostics_section.dart';
import 'package:secure_shell_go/services/diagnostics_log.dart';

void main() {
  late Directory dir;
  late DiagnosticsLog log;
  String? clipboard;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('diag_section_test');
    log = DiagnosticsLog(directory: () async => dir);
    clipboard = null;
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Future<void> pump(WidgetTester tester, {bool on = true}) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: DiagnosticsSettingsSection(
              settings: AppSettings(diagnosticsLog: on),
              apply: (_) async {},
              log: log,
            ),
          ),
        ),
      ),
    );
  }

  /// Lets real file I/O started from a tap finish, then rebuilds.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      // With a duration, so a route's push animation finishes too.
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('the log\'s actions are there only while it is kept',
      (tester) async {
    await pump(tester, on: false);
    expect(find.text('Copy diagnostics'), findsNothing);
    expect(find.text('Clear diagnostics'), findsNothing);
    await pump(tester);
    expect(find.text('Copy diagnostics'), findsOneWidget);
    expect(find.text('View diagnostics'), findsOneWidget);
    expect(find.text('Clear diagnostics'), findsOneWidget);
  });

  testWidgets('Copy puts the scrubbed log on the clipboard', (tester) async {
    await tester.runAsync(() async {
      await log.setEnabled(true);
      await log.record(StateError('boom password=hunter22'), null);
    });
    await pump(tester);
    await tester.tap(find.text('Copy diagnostics'));
    await settle(tester);
    expect(clipboard, contains('Bad state: boom'));
    expect(clipboard, contains('App version: ${DiagnosticsLog.appVersion}'));
    expect(clipboard, isNot(contains('hunter22')));
    expect(find.textContaining('of diagnostics'), findsOneWidget);
  });

  testWidgets('Copy on an empty log says so and copies nothing',
      (tester) async {
    await pump(tester);
    await tester.tap(find.text('Copy diagnostics'));
    await settle(tester);
    expect(clipboard, isNull);
    expect(find.text('The diagnostics log is empty.'), findsOneWidget);
  });

  testWidgets('Clear deletes the log', (tester) async {
    await tester.runAsync(() async {
      await log.setEnabled(true);
      await log.record(StateError('to be cleared'), null);
    });
    await pump(tester);
    await tester.tap(find.text('Clear diagnostics'));
    await settle(tester);
    expect(find.text('Diagnostics log cleared.'), findsOneWidget);
    final left = await tester.runAsync(log.read);
    expect(left, isEmpty);
  });

  testWidgets('View shows the log, and clears it from there', (tester) async {
    await tester.runAsync(() async {
      await log.setEnabled(true);
      await log.record(StateError('visible in viewer'), null);
    });
    await pump(tester);
    await tester.tap(find.text('View diagnostics'));
    await settle(tester);
    expect(find.text('Diagnostics log'), findsOneWidget);
    expect(find.textContaining('visible in viewer'), findsOneWidget);

    await tester.tap(find.byTooltip('Clear'));
    await settle(tester);
    expect(find.textContaining('visible in viewer'), findsNothing);
    expect(find.text('Nothing has been recorded.'), findsOneWidget);
  });
}
