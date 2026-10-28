import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/services/diagnostics_log.dart';
import 'package:secure_shell_go/services/known_hosts_service.dart';
import 'package:secure_shell_go/services/login_prompt.dart';
import 'package:secure_shell_go/services/ssh_service.dart';
import 'package:secure_shell_go/widgets/vault_passphrase_dialog.dart';

import 'login_prompt_test.dart' show ScriptedPerson, passwordHost, round;

/// Secrets the credential store never sees are learned where they are
/// typed, so the diagnostics log can keep them out: a password used for one
/// connection and not saved, the answers to a server's hidden prompts, the
/// vault passphrase. (The backup passphrases are checked with the backup
/// screen, in `document_saver_test.dart`.)
void main() {
  final log = DiagnosticsLog.instance;
  bool learned(String secret) =>
      log.scrubber.scrub('x $secret y') == 'x [redacted] y';

  setUp(log.scrubber.forgetAll);
  tearDown(log.scrubber.forgetAll);

  test('a password typed for one connection, never saved', () async {
    final dir = await Directory.systemTemp.createTemp('learning_test');
    addTearDown(() => dir.delete(recursive: true));
    final service = SshService(
      knownHosts: KnownHostsService(file: File('${dir.path}/kh.json')),
    );
    // Nothing listens on port 1: the connect fails, after the start.
    await expectLater(
      service.connect(
        host: const Host(
          id: 'q',
          label: 'quick',
          hostname: '127.0.0.1',
          port: 1,
          username: 'dev',
          authMethod: SshAuthMethod.password,
        ),
        credentials: const SshCredentials(password: 'Typed-Not-Saved-91'),
        verifyHostKey: (_) async => false,
        timeout: const Duration(seconds: 2),
      ),
      throwsA(anything),
    );
    expect(learned('Typed-Not-Saved-91'), isTrue);
  });

  test('hidden login answers, and not the visible ones', () async {
    final person = ScriptedPerson([
      ['Code-778899', 'dev-visible-name'],
    ]);
    final responder = KeyboardInteractiveResponder(
      host: passwordHost,
      ask: person.answer,
    );
    await responder.respond(
      round([('Verification code: ', false), ('Username: ', true)]),
    );
    expect(learned('Code-778899'), isTrue);
    expect(learned('dev-visible-name'), isFalse);
  });

  testWidgets('the vault passphrase', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => showUnlockVaultDialog(context),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Vault Words 4417');
    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();
    expect(learned('Vault Words 4417'), isTrue);
  });
}
