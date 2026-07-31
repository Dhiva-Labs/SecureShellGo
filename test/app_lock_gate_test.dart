import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/app_settings.dart';
import 'package:secure_shell_go/services/app_lock.dart';
import 'package:secure_shell_go/services/app_lock_controller.dart';
import 'package:secure_shell_go/widgets/app_lock_gate.dart';

class ScriptedAuthenticator implements AppLockAuthenticator {
  ScriptedAuthenticator({this.outcome = AppLockOutcome.cancelled});

  AppLockOutcome outcome;
  int prompts = 0;

  @override
  Future<AppLockSupport> support() async => AppLockSupport.available;

  @override
  Future<AppLockOutcome> authenticate({required String reason}) async {
    prompts++;
    return outcome;
  }

  @override
  Future<void> setSecureDisplay(bool enabled) async {}
}

void main() {
  const enabled = AppSettings(
    appLockEnabled: true,
    appLockTimeout: AppLockTimeout.immediately,
  );

  late ScriptedAuthenticator auth;
  late AppLockController controller;
  late int tapsBehindTheGate;

  setUp(() {
    auth = ScriptedAuthenticator();
    controller = AppLockController(authenticator: auth);
    tapsBehindTheGate = 0;
  });

  tearDown(() => controller.dispose());

  /// The app, with a button standing in for everything the gate has to cover.
  Widget app() => MaterialApp(
        builder: (context, child) => AppLockGate(
          controller: controller,
          child: child ?? const SizedBox.shrink(),
        ),
        home: Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => tapsBehindTheGate++,
              child: const Text('Connect'),
            ),
          ),
        ),
      );

  testWidgets('stays out of the way when the lock is off', (tester) async {
    await controller.start(const AppSettings());
    await tester.pumpWidget(app());
    await tester.pump();

    expect(find.text('SecureShell Go is locked'), findsNothing);
    await tester.tap(find.text('Connect'));
    expect(tapsBehindTheGate, 1);
  });

  testWidgets('covers the app and blocks what is behind it', (tester) async {
    await controller.start(enabled);
    await tester.pumpWidget(app());
    await tester.pump();

    expect(find.text('SecureShell Go is locked'), findsOneWidget);

    // The button is still in the tree — the sessions behind the gate are
    // meant to keep running — but it must not be reachable.
    expect(find.text('Connect'), findsOneWidget);
    await tester.tap(find.text('Connect'), warnIfMissed: false);
    await tester.pump();
    expect(tapsBehindTheGate, 0);
  });

  testWidgets('raises the sheet once, not in a loop', (tester) async {
    // The regression: a dismissed sheet reports `cancelled`, which emits a
    // fresh locked state, which would re-raise the sheet for ever.
    await controller.start(enabled);
    await tester.pumpWidget(app());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(auth.prompts, 1);
    expect(controller.isLocked, isTrue);
  });

  testWidgets('the cover is opaque, not a translucent scrim', (tester) async {
    await controller.start(enabled);
    await tester.pumpWidget(app());
    await tester.pump();

    // A blur or a partial scrim would leave the terminal behind it legible.
    final material = tester.widget<Material>(
      find
          .descendant(
            of: find.byType(AppLockGate),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(material.color, isNotNull);
    expect(material.color!.a, 1.0);
  });

  testWidgets('the back gesture cannot dismiss it', (tester) async {
    await controller.start(enabled);
    await tester.pumpWidget(app());
    await tester.pump();

    // `true` means the gate swallowed the press: it neither popped a route
    // under the cover nor let the app close with a live session behind it.
    // A PopScope would not have done this — above the Navigator there is no
    // ModalRoute for one to register with — so this asserts the real
    // mechanism, WidgetsBindingObserver.didPopRoute.
    expect(await tester.binding.handlePopRoute(), isTrue);
    await tester.pump();
    expect(find.text('SecureShell Go is locked'), findsOneWidget);
    expect(controller.isLocked, isTrue);
  });

  testWidgets('hands the back press back once unlocked', (tester) async {
    // The other half: the gate must not go on eating back presses after it
    // has opened, or the app would become unnavigable.
    await controller.start(const AppSettings());
    await tester.pumpWidget(app());
    await tester.pump();

    expect(await tester.binding.handlePopRoute(), isFalse);
  });

  testWidgets('opens once authentication succeeds', (tester) async {
    await controller.start(enabled);
    await tester.pumpWidget(app());
    await tester.pump();
    expect(find.text('SecureShell Go is locked'), findsOneWidget);

    auth.outcome = AppLockOutcome.success;
    await tester.tap(find.text('Unlock'));
    await tester.pump();
    await tester.pump();

    expect(find.text('SecureShell Go is locked'), findsNothing);
    await tester.tap(find.text('Connect'));
    expect(tapsBehindTheGate, 1);
  });

  testWidgets('shows a countdown instead of a wipe warning', (tester) async {
    auth.outcome = AppLockOutcome.failed;
    await controller.start(enabled);
    await tester.pumpWidget(app());
    await tester.pump();

    for (var i = 0; i < AppLockController.attemptsBeforeCooldown; i++) {
      await controller.authenticate();
    }
    await tester.pump();

    expect(find.textContaining('Too many attempts'), findsOneWidget);
    expect(find.textContaining('Try again in'), findsOneWidget);
    // Nothing anywhere on this screen may threaten the user's data, because
    // nothing is ever deleted for failing to unlock.
    expect(find.textContaining('erase'), findsNothing);
    expect(find.textContaining('wipe'), findsNothing);
    expect(find.textContaining('delete'), findsNothing);
  });
}
