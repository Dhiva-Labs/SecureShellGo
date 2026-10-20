import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/services/login_prompt.dart';
import 'package:secure_shell_go/widgets/login_prompt_dialog.dart';

const target = Host(
  id: 'h1',
  label: 'Build box',
  hostname: 'build.example.com',
  port: 22,
  username: 'dev',
  authMethod: SshAuthMethod.password,
);

const bastion = Host(
  id: 'j1',
  label: 'Bastion',
  hostname: 'bastion.example.com',
  port: 22,
  username: 'dev',
  authMethod: SshAuthMethod.privateKey,
);

LoginPrompt promptFor(
  List<(String, bool)> fields, {
  Host host = target,
  Host? jumpHostFor,
  String instruction = '',
  bool savedPasswordRejected = false,
  Future<void>? withdrawn,
}) {
  return LoginPrompt(
    host: host,
    jumpHostFor: jumpHostFor,
    savedPasswordRejected: savedPasswordRejected,
    withdrawn: withdrawn ?? Completer<void>().future,
    challenge: LoginChallenge.fromServer(
      name: '',
      instruction: instruction,
      prompts: [for (final (text, echo) in fields) (text: text, echo: echo)],
    ),
  );
}

/// A screen that a [LoginDialogs] can belong to, the way a connect screen's
/// state does.
class TestScreen extends StatefulWidget {
  const TestScreen({super.key});

  @override
  State<TestScreen> createState() => TestScreenState();
}

class TestScreenState extends State<TestScreen> {
  @override
  Widget build(BuildContext context) => const Scaffold(body: SizedBox());
}

Future<TestScreenState> pumpScreen(WidgetTester tester) async {
  await tester.pumpWidget(const MaterialApp(home: TestScreen()));
  return tester.state<TestScreenState>(find.byType(TestScreen));
}

/// Opens [prompt] the way `SshService` would, via [LoginDialogs.answer], and
/// returns the pending answer.
Future<Future<List<String>?>> open(
  WidgetTester tester,
  LoginPrompt prompt, {
  List<ServerBanner> banners = const [],
}) async {
  final screen = await pumpScreen(tester);
  final dialogs = LoginDialogs(screen);
  banners.forEach(dialogs.addBanner);
  final answer = dialogs.answer(prompt);
  await tester.pumpAndSettle();
  return answer;
}

TextField field(WidgetTester tester, int index) =>
    tester.widget<TextField>(find.byType(TextField).at(index));

void main() {
  testWidgets('hidden prompts are hidden, echoed ones are not, and the '
      'answers come back in order', (tester) async {
    final answer = await open(
      tester,
      promptFor([('Username: ', true), ('Verification code: ', false)]),
    );

    expect(find.text('Sign in to Build box'), findsOneWidget);
    expect(find.text('dev@build.example.com'), findsOneWidget);
    expect(field(tester, 0).obscureText, isFalse);
    expect(field(tester, 1).obscureText, isTrue);
    expect(find.text('Username'), findsOneWidget);
    expect(find.text('Verification code'), findsOneWidget);

    await tester.enterText(find.byType(TextField).at(0), 'alice');
    await tester.enterText(find.byType(TextField).at(1), '492039');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(await answer, ['alice', '492039']);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('a hidden answer can be shown on request', (tester) async {
    await open(tester, promptFor([('Verification code: ', false)]));

    expect(field(tester, 0).obscureText, isTrue);
    await tester.tap(find.byTooltip('Show'));
    await tester.pump();
    expect(field(tester, 0).obscureText, isFalse);
  });

  testWidgets('submitting the last field submits the dialog', (tester) async {
    final answer = await open(tester, promptFor([('Token: ', false)]));

    await tester.enterText(find.byType(TextField), '111111');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(await answer, ['111111']);
  });

  testWidgets('Cancel answers null', (tester) async {
    final answer = await open(tester, promptFor([('Token: ', false)]));

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(await answer, isNull);
  });

  testWidgets('a stray tap outside does not cancel', (tester) async {
    await open(tester, promptFor([('Token: ', false)]));

    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
  });

  testWidgets('a jump host\'s prompt says which host is asking and why',
      (tester) async {
    await open(
      tester,
      promptFor(
        [('Verification code: ', false)],
        host: bastion,
        jumpHostFor: target,
      ),
    );

    expect(find.text('Sign in to Bastion'), findsOneWidget);
    expect(find.text('Jump host on the way to Build box'), findsOneWidget);
  });

  testWidgets('shows the instruction, a menu above its question, and why it '
      'is asking for a password', (tester) async {
    await open(
      tester,
      promptFor(
        [
          (
            'Enter a passcode or select one of the following options:\n'
                ' 1. Duo Push to XXX-XXX-1234\n\n'
                'Passcode or option (1-1): ',
            true,
          ),
        ],
        instruction: 'Duo two-factor login for dev',
        savedPasswordRejected: true,
      ),
    );

    expect(find.text('Duo two-factor login for dev'), findsOneWidget);
    expect(find.textContaining(' 1. Duo Push to XXX-XXX-1234'), findsOneWidget);
    expect(find.text('Passcode or option (1-1)'), findsOneWidget);
    expect(
      find.text('The server did not accept the saved password.'),
      findsOneWidget,
    );
  });

  testWidgets('closes itself when the server gives up first', (tester) async {
    final over = Completer<void>();
    final answer = await open(
      tester,
      promptFor([('Token: ', false)], withdrawn: over.future),
    );
    expect(find.byType(AlertDialog), findsOneWidget);

    over.complete();
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(await answer, isNull);
  });

  testWidgets('a screen that has gone away cancels without showing anything',
      (tester) async {
    final screen = await pumpScreen(tester);
    final dialogs = LoginDialogs(screen);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));

    expect(await dialogs.answer(promptFor([('Token: ', false)])), isNull);
  });

  group('banners', () {
    const notice = ServerBanner(
      host: target,
      text: 'Authorised use only.\nActivity is logged.',
    );

    testWidgets('one that arrived before a prompt is shown inside it, and '
        'not again afterwards', (tester) async {
      final screen = await pumpScreen(tester);
      final dialogs = LoginDialogs(screen)..addBanner(notice);

      final answer = dialogs.answer(promptFor([('Token: ', false)]));
      await tester.pumpAndSettle();
      expect(find.text('Message from Build box'), findsOneWidget);
      expect(find.textContaining('Authorised use only.'), findsOneWidget);

      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      await answer;

      final shown = dialogs.showUnseenBanners();
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      await shown;
    });

    testWidgets('one nobody has seen yet gets a sheet once the login is done',
        (tester) async {
      final screen = await pumpScreen(tester);
      final dialogs = LoginDialogs(screen)
        ..addBanner(
          const ServerBanner(
            host: bastion,
            jumpHostFor: target,
            text: 'Bastion: be nice.',
          ),
        )
        ..addBanner(notice);

      var dismissed = false;
      unawaited(dialogs.showUnseenBanners().then((_) => dismissed = true));
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsOneWidget);
      expect(
        find.text('Message from Bastion (jump host for Build box)'),
        findsOneWidget,
      );
      expect(find.text('Message from Build box'), findsOneWidget);
      expect(dismissed, isFalse, reason: 'the session waits for the sheet');

      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      expect(dismissed, isTrue);
    });
  });
}
