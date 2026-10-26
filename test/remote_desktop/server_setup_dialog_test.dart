import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/l10n/l10n.dart';
import 'package:secure_shell_go/models/app_settings.dart';
import 'package:secure_shell_go/screens/server_setup_dialog.dart';
import 'package:secure_shell_go/services/remote_desktop/server_setup.dart';
import 'package:secure_shell_go/services/ssh_service.dart';
import 'package:secure_shell_go/theme.dart';

import '../support/fake_transport.dart';

class _Transport extends FakeTransportBase {}

class _Backend extends ServerSetupBackend {
  _Backend(this.privilegeIs);

  final Privilege privilegeIs;
  final List<({List<String> packages, Privilege privilege, String? password})> installs = [];

  /// What the next install does: null succeeds.
  SetupFailure? Function(String? password)? outcome;

  @override
  Future<Privilege> privilege(SessionTransport transport) async => privilegeIs;

  @override
  Future<SetupRun> install(
    SessionTransport transport, {
    required PackageManager pm,
    required List<String> packages,
    required Privilege privilege,
    String? password,
  }) async {
    installs.add((packages: packages, privilege: privilege, password: password));
    final lines = StreamController<String>();
    lines.add('Setting up ${packages.first}');
    unawaited(lines.close());
    final failure = outcome?.call(password);
    return SetupRun(
      lines: lines.stream,
      // Ends on the next tick, as a real install does: after the dialog has
      // started waiting on it.
      done: Future<void>.delayed(Duration.zero, () {
        if (failure != null) throw failure;
      }),
    );
  }
}

const _xvfb = SetupItem(title: 'Virtual screen (Xvfb)', detail: 'needed', packages: ['xvfb']);
const _desktop = SetupItem(
    title: 'Xfce desktop', detail: 'optional', packages: ['xfce4', 'dbus-x11'], required: false);

Future<Future<bool>> _open(WidgetTester tester, _Backend backend,
    {List<SetupItem> items = const [_xvfb, _desktop]}) async {
  late Future<bool> result;
  await tester.pumpWidget(MaterialApp(
    // The app's own theme: its filled buttons fill the width, which a dialog
    // must allow for.
    theme: AppTheme.themeFor(UiStyle.aurora, Brightness.dark),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Builder(
      builder: (context) => Scaffold(
        body: TextButton(
          onPressed: () => result = showServerSetup(context,
              transport: _Transport(),
              hostName: 'vps',
              pm: PackageManager.apt,
              items: items,
              backend: backend),
          child: const Text('open'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return Future.value(result);
}

Finder _button(String label) => find.ancestor(
    of: find.text(label), matching: find.bySubtype<ButtonStyleButton>());

bool _enabled(WidgetTester tester, String label) =>
    tester.widget<ButtonStyleButton>(_button(label)).enabled;

void main() {
  testWidgets('root: one click installs, no password asked', (tester) async {
    final backend = _Backend(Privilege.root);
    final result = await _open(tester, backend);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Virtual screen (Xvfb)'), findsOneWidget);
    expect(find.text('Xfce desktop'), findsOneWidget);

    await tester.tap(find.text('Install'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(await result, isTrue);
    expect(backend.installs.single.packages, ['xvfb', 'xfce4', 'dbus-x11']);
    expect(backend.installs.single.password, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the optional desktop can be left out', (tester) async {
    final backend = _Backend(Privilege.sudo);
    final result = await _open(tester, backend);
    await tester.tap(find.text('Xfce desktop'));
    await tester.pump();
    await tester.tap(find.text('Install'));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(await result, isTrue);
    expect(backend.installs.single.packages, ['xvfb']);
  });

  testWidgets('sudo with a password: asked for, wrong once, then right',
      (tester) async {
    final backend = _Backend(Privilege.sudoPassword)
      ..outcome = (pw) => pw == 'right horse'
          ? null
          : const SetupFailure(SetupFailureKind.wrongPassword, 'That password was not accepted.');
    final result = await _open(tester, backend);
    expect(find.byType(TextField), findsOneWidget);
    expect(_enabled(tester, 'Install'), isFalse, reason: 'no password yet');

    await tester.enterText(find.byType(TextField), 'wrong');
    await tester.pump();
    await tester.tap(find.text('Install'));
    await tester.pumpAndSettle();
    expect(find.text('That password was not accepted.'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty,
        reason: 'a rejected password is not left in the field');

    await tester.enterText(find.byType(TextField), 'right horse');
    await tester.pump();
    await tester.tap(find.text('Install'));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(await result, isTrue);
    expect(backend.installs.map((i) => i.password), ['wrong', 'right horse']);
  });

  testWidgets('no sudo: the command for an administrator, and no Install',
      (tester) async {
    final backend = _Backend(Privilege.none);
    final result = await _open(tester, backend, items: const [_xvfb]);
    expect(find.text('sudo apt install xvfb'), findsOneWidget);
    expect(find.text('Install'), findsNothing);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await result, isFalse);
    expect(backend.installs, isEmpty);
  });

  testWidgets('a failed install shows why and offers Retry', (tester) async {
    var tries = 0;
    final backend = _Backend(Privilege.root)
      ..outcome = (_) => tries++ == 0
          ? const SetupFailure(SetupFailureKind.failed, 'The install failed (exit code 100).',
              output: 'E: dpkg was interrupted')
          : null;
    final result = await _open(tester, backend, items: const [_xvfb]);
    await tester.tap(find.text('Install'));
    await tester.pumpAndSettle();
    expect(find.text('The install failed (exit code 100).'), findsOneWidget);
    expect(find.textContaining('dpkg was interrupted'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(await result, isTrue);
    expect(backend.installs, hasLength(2));
  });
}
