import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/known_host.dart';
import 'package:secure_shell_go/screens/known_hosts_screen.dart';
import 'package:secure_shell_go/services/host_key_policy.dart';
import 'package:secure_shell_go/services/known_hosts_service.dart';
import 'package:secure_shell_go/widgets/host_key_dialog.dart';
import 'package:secure_shell_go/widgets/public_key_dialog.dart';

import 'remote_editor_screen_test.dart' show ScreenFs, chord, conf, pumpEditor;
import 'support/temp_dir.dart';

const String publicKey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDemo dev@laptop';
const String fingerprint = 'SHA256:47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU';

/// A save whose chmod the server refuses, so the file comes back 0644.
class RefusingChmodFs extends ScreenFs {
  @override
  Future<bool> setPermissions(String path, int mode) async => false;
}

void main() {
  late List<String?> clipboard;

  setUp(() {
    clipboard = [];
    // `flutter_test` answers the platform channel with null, so a copy would
    // go nowhere. This records what reaches the clipboard.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard.add((call.arguments as Map)['text'] as String?);
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  /// Opens [open] from a button, the way the app reaches each dialog.
  Future<void> pumpDialog(
    WidgetTester tester,
    Future<void> Function(BuildContext context) open,
  ) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => open(context),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  group('public key dialog', () {
    Future<void> pumpPublicKey(WidgetTester tester) => pumpDialog(
          tester,
          (context) => showGeneratedPublicKeyDialog(context, publicKey),
        );

    testWidgets('the copy button says Copied, then goes back', (tester) async {
      await pumpPublicKey(tester);
      expect(find.text('Copy'), findsOneWidget);
      expect(find.byIcon(Icons.check), findsNothing);

      await tester.tap(find.text('Copy'));
      await tester.pump();

      expect(find.text('Copied'), findsOneWidget);
      expect(find.text('Copy'), findsNothing);
      expect(find.byIcon(Icons.check), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 1900));
      expect(find.text('Copied'), findsOneWidget, reason: 'about two seconds');

      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Copied'), findsNothing);
      expect(find.text('Copy'), findsOneWidget);
      expect(find.byIcon(Icons.check), findsNothing);
    });

    testWidgets('the key reaches the clipboard, with no snackbar behind it',
        (tester) async {
      await pumpPublicKey(tester);

      await tester.tap(find.text('Copy'));
      await tester.pump();

      expect(clipboard, [publicKey]);
      expect(find.byType(SnackBar), findsNothing);
      expect(find.text('Public key copied'), findsNothing);

      await tester.pump(copiedFeedbackDuration);
    });

    testWidgets('a second copy starts the two seconds over', (tester) async {
      await pumpPublicKey(tester);

      await tester.tap(find.text('Copy'));
      await tester.pump(const Duration(milliseconds: 1500));
      await tester.tap(find.text('Copied'));
      await tester.pump(const Duration(milliseconds: 1500));

      expect(find.text('Copied'), findsOneWidget);
      expect(clipboard, [publicKey, publicKey]);

      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Copy'), findsOneWidget);
    });

    testWidgets('closing the dialog mid-feedback leaves nothing running',
        (tester) async {
      await pumpPublicKey(tester);

      await tester.tap(find.text('Copy'));
      await tester.pump();
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      // The test would fail here if the revert timer were still pending.
    });
  });

  group('host key dialog', () {
    const unknown = HostKeyPrompt(
      kind: HostKeyPromptKind.unknown,
      hostname: 'web-01.example.com',
      port: 22,
      keyType: 'ssh-ed25519',
      fingerprint: fingerprint,
    );

    testWidgets('the copy icon turns into a check, then goes back',
        (tester) async {
      await pumpDialog(
        tester,
        (context) => showHostKeyDialog(context, unknown),
      );
      expect(find.byTooltip('Copy'), findsOneWidget);
      expect(find.byIcon(Icons.check), findsNothing);

      await tester.tap(find.byTooltip('Copy'));
      await tester.pump();

      expect(clipboard, [fingerprint]);
      expect(find.byTooltip('Copied'), findsOneWidget);
      expect(find.byTooltip('Copy'), findsNothing);
      expect(find.byIcon(Icons.check), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      expect(find.text('Fingerprint copied'), findsNothing);

      await tester.pump(const Duration(milliseconds: 2100));
      expect(find.byTooltip('Copy'), findsOneWidget);
      expect(find.byIcon(Icons.check), findsNothing);
    });

    testWidgets('tapping the fingerprint box copies it too', (tester) async {
      await pumpDialog(
        tester,
        (context) => showHostKeyDialog(context, unknown),
      );

      // The corner of the box: the text itself is selectable and keeps its
      // own taps.
      await tester.tapAt(
        tester.getTopLeft(find.widgetWithText(InkWell, fingerprint)) +
            const Offset(3, 3),
      );
      await tester.pump();

      expect(clipboard, [fingerprint]);
      expect(find.byIcon(Icons.check), findsOneWidget);

      await tester.pump(copiedFeedbackDuration);
    });

    testWidgets('each fingerprint of a changed key confirms on its own',
        (tester) async {
      const previous = 'SHA256:nThbg6kXUpJWGl7E1IGOCspRomTxdCARLviKw6E5SY8';
      final changed = HostKeyPrompt(
        kind: HostKeyPromptKind.changed,
        hostname: 'web-01.example.com',
        port: 22,
        keyType: 'ssh-ed25519',
        fingerprint: fingerprint,
        previous: KnownHostKey(
          hostname: 'web-01.example.com',
          port: 22,
          keyType: 'ssh-ed25519',
          fingerprint: previous,
          addedAt: DateTime(2026, 9, 1),
        ),
      );
      await pumpDialog(
        tester,
        (context) => showHostKeyDialog(context, changed),
      );
      expect(find.byTooltip('Copy'), findsNWidgets(2));

      await tester.tap(find.byTooltip('Copy').first);
      await tester.pump();

      expect(clipboard, [previous]);
      expect(find.byTooltip('Copied'), findsOneWidget);
      expect(find.byTooltip('Copy'), findsOneWidget,
          reason: 'the other fingerprint was not copied');

      await tester.pump(copiedFeedbackDuration);
    });
  });

  group('known hosts screen', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('ux_copy_feedback_test');
    });

    tearDown(() => deleteTempDir(dir));

    testWidgets('a copy on the list is a snackbar, and the next replaces it',
        (tester) async {
      // Built inside runAsync: a store made in the test's fake-time zone
      // would queue its first write on a microtask that never runs while the
      // test waits on real file I/O.
      late final KnownHostsService knownHosts;
      await tester.runAsync(() async {
        knownHosts = KnownHostsService(file: File('${dir.path}/kh.json'));
        await knownHosts.trust(KnownHostKey(
          hostname: 'web-01.example.com',
          port: 22,
          keyType: 'ssh-ed25519',
          fingerprint: fingerprint,
          addedAt: DateTime(2026, 9, 1),
        ));
        await knownHosts.all();
      });
      await tester.pumpWidget(
        MaterialApp(home: KnownHostsScreen(knownHosts: knownHosts)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text(fingerprint));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(clipboard, [fingerprint]);
      expect(find.text('Fingerprint copied'), findsOneWidget);

      await tester.tap(find.text(fingerprint));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Fingerprint copied'), findsOneWidget);
      expect(clipboard, [fingerprint, fingerprint]);

      // The first message's three seconds are long gone by now. Queued
      // behind it, the second would still be showing. Frame by frame: a
      // snackbar's timer starts and its slide ends only on frames.
      for (var i = 0; i < 50; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('Fingerprint copied'), findsNothing,
          reason: 'the second copy replaced the first, it did not queue');
    });
  });

  group('remote editor', () {
    testWidgets('a plain Ctrl+S shows no snackbar', (tester) async {
      final fs = ScreenFs()..put('/etc/nginx.conf', conf);
      await pumpEditor(tester, fs, ['/etc/nginx.conf'],
          platform: TargetPlatform.linux);

      await tester.enterText(find.byType(TextField).first, 'edited\n');
      await tester.pumpAndSettle();
      expect(find.byTooltip('Save (Ctrl+S)'), findsOneWidget);

      await chord(tester, LogicalKeyboardKey.keyS);

      expect(fs.textAt('/etc/nginx.conf'), 'edited\n');
      expect(find.byTooltip('No changes to save'), findsOneWidget,
          reason: 'the unsaved mark is what says it saved');
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('a save that lost the file mode still says so',
        (tester) async {
      final fs = RefusingChmodFs()
        ..put('/srv/run.sh', '#!/bin/sh\necho old\n', mode: 0x1ED);
      await pumpEditor(tester, fs, ['/srv/run.sh'],
          platform: TargetPlatform.linux);

      await tester.enterText(
        find.byType(TextField).first,
        '#!/bin/sh\necho new\n',
      );
      await tester.pumpAndSettle();
      await chord(tester, LogicalKeyboardKey.keyS);

      expect(fs.textAt('/srv/run.sh'), '#!/bin/sh\necho new\n');
      expect(
        find.textContaining('would not restore the original permissions'),
        findsOneWidget,
      );

      await tester.pumpAndSettle(const Duration(seconds: 5));
    });
  });
}
