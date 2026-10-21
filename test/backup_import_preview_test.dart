import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/known_host.dart';
import 'package:secure_shell_go/screens/backup_screen.dart';
import 'package:secure_shell_go/services/backup_payload.dart';
import 'package:secure_shell_go/services/backup_service.dart';

/// The import preview's host-key part: every server a backup would have
/// this device trust is shown with its fingerprint, and nothing is trusted
/// unless "Trust these keys" is ticked.
void main() {
  const contents = BackupContents(
    hosts: 1,
    groups: 0,
    snippets: 0,
    tunnels: 0,
    bookmarks: 0,
    credentials: 0,
    includesCredentials: false,
    hostsNeedingCredentials: 1,
    knownHosts: 3,
    includesKnownHosts: true,
  );
  final fingerprint = 'SHA256:${'Q' * 43}';
  final hostKeys = KnownHostsImport(
    toAdd: [
      KnownHostKey(
        hostname: 'new.example.org',
        port: 2222,
        keyType: 'ssh-ed25519',
        fingerprint: fingerprint,
        addedAt: DateTime.utc(2025),
      ),
    ],
    serversKept: 1,
  );

  Future<ImportChoice?> open(
    WidgetTester tester,
    Future<void> Function() act,
  ) async {
    ImportChoice? choice;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            choice = await showDialog<ImportChoice>(
              context: context,
              builder: (_) => ImportPreviewDialog(
                contents: contents,
                hostKeys: hostKeys,
              ),
            );
          },
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await act();
    await tester.tap(find.text('Merge'));
    await tester.pumpAndSettle();
    return choice;
  }

  testWidgets('lists each new server and fingerprint; trust starts off',
      (tester) async {
    final choice = await open(tester, () async {
      expect(find.textContaining('new.example.org:2222'), findsOneWidget);
      expect(find.textContaining(fingerprint), findsOneWidget);
      expect(find.textContaining('other keys for 1 server'), findsOneWidget);
      final box = tester.widget<CheckboxListTile>(
        find.widgetWithText(CheckboxListTile, 'Trust these keys'),
      );
      expect(box.value, isFalse);
    });
    expect(choice?.mode, ImportMode.merge);
    expect(choice?.trustKnownHosts, isFalse);
  });

  testWidgets('ticked, the import trusts them', (tester) async {
    final choice = await open(tester, () async {
      await tester.tap(find.text('Trust these keys'));
      await tester.pump();
    });
    expect(choice?.trustKnownHosts, isTrue);
  });
}
