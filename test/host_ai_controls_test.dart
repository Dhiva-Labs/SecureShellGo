import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/models/host_ai_access.dart';
import 'package:secure_shell_go/models/host_ai_edit.dart';
import 'package:secure_shell_go/widgets/host_ai_controls.dart';
import 'package:secure_shell_go/widgets/host_ai_level_chip.dart';

Host _host(
  HostAiAccess access, {
  bool terminal = false,
  bool desktop = false,
  List<String> commands = const [],
}) => Host(
  id: 'h',
  label: 'Web',
  hostname: 'web.example.com',
  port: 22,
  username: 'dev',
  authMethod: SshAuthMethod.password,
  aiAccess: access,
  aiTerminal: terminal,
  aiDesktop: desktop,
  aiAllowedCommands: commands,
);

void main() {
  late HostAiEdit edit;
  var changes = 0;

  /// The controls alone, scrollable, at a phone's size (360 x 740).
  Future<void> pump(
    WidgetTester tester,
    Host host, {
    Size size = const Size(360, 740),
    double textScale = 1,
    Future<Host?> Function()? loadStored,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    edit = HostAiEdit.of(host);
    changes = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: HostAiControls(
              edit: edit,
              onChanged: () => changes++,
              loadStored: loadStored,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> choose(
    WidgetTester tester,
    HostAiAccess level, {
    String? confirm,
  }) async {
    final tile = find.byKey(ValueKey('ai-level-${level.name}'));
    await tester.ensureVisible(tile);
    await tester.pumpAndSettle();
    await tester.tap(tile);
    await tester.pumpAndSettle();
    if (confirm != null) {
      await tester.tap(find.text(confirm));
      await tester.pumpAndSettle();
    }
  }

  String summary(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(const ValueKey('ai-summary'))).data!;

  group('the level picker', () {
    testWidgets('lists the four levels, each with its line', (tester) async {
      await pump(tester, _host(HostAiAccess.off));
      expect(find.text('AI access'), findsOneWidget);
      for (final text in [
        'Off',
        'Assistants cannot see this server.',
        'Read only',
        'Assistants can look: stats, services, logs, files. '
            'Nothing can be changed.',
        'Ask before each change',
        'Assistants can ask to run commands, write files or manage '
            'services. Each one needs your yes on a card.',
        'Full control',
        'Assistants can change this server, open terminals and its desktop '
            'without asking. Only for servers you would hand over '
            'completely.',
      ]) {
        // The Off line is also the summary while Off is chosen.
        expect(find.text(text), findsWidgets, reason: text);
      }
      expect(tester.takeException(), isNull);
    });

    for (final (level, confirm) in [
      (HostAiAccess.readOnly, null),
      (HostAiAccess.askToChange, 'Allow requests'),
      (HostAiAccess.fullControl, 'Give full control'),
      (HostAiAccess.off, null),
    ]) {
      testWidgets('${level.name} can be chosen', (tester) async {
        await pump(tester, _host(HostAiAccess.off));
        await choose(tester, level, confirm: confirm);
        if (level == HostAiAccess.off) {
          // Off is where it started: choosing it is not a change.
          expect(edit.levelChosen, isFalse);
        } else {
          expect(edit.level, level);
          expect(edit.levelChosen, isTrue);
          expect(changes, greaterThan(0));
        }
      });
    }

    testWidgets('full control: cancel leaves the previous level, and the '
        'grant is not the focused button', (tester) async {
      await pump(tester, _host(HostAiAccess.readOnly));
      await choose(tester, HostAiAccess.fullControl);
      expect(find.text('Give full control of this server?'), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Cancel'))
            .autofocus,
        isTrue,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(edit.level, HostAiAccess.readOnly);
      expect(edit.levelChosen, isFalse);
      expect(find.byKey(const ValueKey('ai-full-warning')), findsNothing);
      expect(changes, 0);
    });

    testWidgets('full control, once given, keeps a standing warning',
        (tester) async {
      await pump(tester, _host(HostAiAccess.readOnly));
      await choose(tester, HostAiAccess.fullControl,
          confirm: 'Give full control');
      expect(find.byKey(const ValueKey('ai-full-warning')), findsOneWidget);
      expect(find.textContaining('To take it back, choose another level'),
          findsOneWidget);
    });

    testWidgets('the summary says what each level means', (tester) async {
      await pump(tester, _host(HostAiAccess.off));
      expect(summary(tester), 'Assistants cannot see this server.');
      await choose(tester, HostAiAccess.readOnly);
      expect(summary(tester),
          'Assistants can read this server. They cannot change anything.');
      await choose(tester, HostAiAccess.askToChange,
          confirm: 'Allow requests');
      expect(
        summary(tester),
        'Assistants can read this server. Changes need your yes each time. '
        'Neither a terminal nor the desktop can be requested.',
      );
      await choose(tester, HostAiAccess.fullControl,
          confirm: 'Give full control');
      expect(
        summary(tester),
        'Assistants can change this server, and open terminals and its '
        'desktop, without asking you. Every command runs as the saved '
        'sign-in user.',
      );
    });

    testWidgets('the summary names the allowed commands that run unasked',
        (tester) async {
      await pump(
        tester,
        _host(HostAiAccess.askToChange, commands: ['uptime', 'df -h']),
      );
      expect(summary(tester), endsWith('2 allowed commands run without asking.'));
      await pump(tester, _host(HostAiAccess.askToChange, commands: ['uptime']));
      expect(summary(tester), endsWith('1 allowed command runs without asking.'));
    });

    testWidgets('the summary for each terminal and desktop combination',
        (tester) async {
      for (final (terminal, desktop, ending) in [
        (false, false, 'Neither a terminal nor the desktop can be requested.'),
        (true, false, 'A terminal can be requested; the desktop cannot.'),
        (false, true, 'The desktop can be requested; a terminal cannot.'),
        (true, true, 'A terminal and the desktop can be requested.'),
      ]) {
        await pump(
          tester,
          _host(HostAiAccess.askToChange, terminal: terminal, desktop: desktop),
        );
        expect(summary(tester), endsWith(ending));
      }
    });

    testWidgets('terminal, desktop and Advanced show only under "Ask before '
        'each change"', (tester) async {
      for (final (level, shown) in [
        (HostAiAccess.off, false),
        (HostAiAccess.readOnly, false),
        (HostAiAccess.askToChange, true),
        (HostAiAccess.fullControl, false),
      ]) {
        await pump(tester, _host(level));
        for (final key in ['ai-terminal', 'ai-desktop', 'ai-advanced']) {
          expect(find.byKey(ValueKey(key)),
              shown ? findsOneWidget : findsNothing,
              reason: '$key under ${level.name}');
        }
      }
    });

    testWidgets('Advanced holds the allowed commands, folded at first',
        (tester) async {
      await pump(
        tester,
        _host(HostAiAccess.askToChange, commands: ['uptime']),
      );
      expect(find.text('Allowed commands: 1'), findsOneWidget);
      expect(find.byKey(const ValueKey('ai-command-field')), findsNothing);
      await tester.ensureVisible(find.byKey(const ValueKey('ai-advanced')));
      await tester.tap(find.text('Advanced'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('ai-command-field')), findsOneWidget);
      expect(find.byKey(const ValueKey('ai-commands-warning')), findsOneWidget);
      expect(find.byKey(const ValueKey('ai-command-uptime')), findsOneWidget);
    });

    testWidgets('a stored terminal is asked again when asking comes back, and '
        'a cancel leaves it off', (tester) async {
      await pump(tester, _host(HostAiAccess.off, terminal: true));
      await choose(tester, HostAiAccess.askToChange,
          confirm: 'Allow requests');
      expect(find.text('Allow a full control terminal?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(edit.level, HostAiAccess.askToChange);
      expect(edit.terminal, isFalse);
      expect(edit.terminalChosen, isTrue);
    });

    for (final lowered in [HostAiAccess.off, HostAiAccess.readOnly]) {
      testWidgets('a form open at full control while the stored level fell to '
          '${lowered.name}: picking Ask confirms, with the stored ticks and '
          'commands', (tester) async {
        final stored = _host(lowered, terminal: true, commands: ['uptime']);
        await pump(
          tester,
          _host(HostAiAccess.fullControl),
          loadStored: () async => stored,
        );
        await choose(tester, HostAiAccess.askToChange);
        expect(find.text('Let the assistant request changes?'), findsOneWidget);
        expect(find.byKey(const ValueKey('ai-confirm-command')), findsOneWidget);
        await tester.tap(find.text('Allow requests'));
        await tester.pumpAndSettle();
        // The stored terminal tick is asked about again, as from Read only.
        expect(find.text('Allow a full control terminal?'), findsOneWidget);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(edit.level, HostAiAccess.askToChange);
        expect(edit.terminal, isFalse);
        expect(edit.commands, ['uptime']);
      });

      testWidgets('the same with the stored level at ${lowered.name}: cancel '
          'leaves the form unchanged', (tester) async {
        await pump(
          tester,
          _host(HostAiAccess.fullControl),
          loadStored: () async => _host(lowered, commands: ['uptime']),
        );
        await choose(tester, HostAiAccess.askToChange);
        expect(find.text('Let the assistant request changes?'), findsOneWidget);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(edit.level, HostAiAccess.fullControl);
        expect(edit.levelChosen, isFalse);
        expect(edit.touched, isFalse);
        expect(changes, 0);
        expect(find.byKey(const ValueKey('ai-full-warning')), findsOneWidget);
      });
    }

    testWidgets('lowering from full control while the store still holds it '
        'asks nothing', (tester) async {
      await pump(
        tester,
        _host(HostAiAccess.fullControl),
        loadStored: () async => _host(HostAiAccess.fullControl),
      );
      await choose(tester, HostAiAccess.askToChange);
      expect(find.byType(AlertDialog), findsNothing);
      expect(edit.level, HostAiAccess.askToChange);
    });

    testWidgets('nothing is written by the picker itself', (tester) async {
      await pump(tester, _host(HostAiAccess.readOnly));
      expect(edit.touched, isFalse);
      await choose(tester, HostAiAccess.off);
      // Only the edit holds the choice: applyTo is the parent's to call.
      expect(edit.applyTo(_host(HostAiAccess.readOnly)).aiAccess,
          HostAiAccess.off);
    });
  });

  group('"Not saved yet"', () {
    testWidgets('shows while the choice differs from the saved one',
        (tester) async {
      await pump(tester, _host(HostAiAccess.readOnly));
      expect(find.text('Not saved yet'), findsNothing);
      await choose(tester, HostAiAccess.off);
      expect(find.text('Not saved yet'), findsOneWidget);
      await choose(tester, HostAiAccess.readOnly);
      expect(find.text('Not saved yet'), findsNothing);
    });

    testWidgets('a ticked flag counts as unsaved too', (tester) async {
      await pump(tester, _host(HostAiAccess.askToChange));
      await tester.ensureVisible(find.byKey(const ValueKey('ai-desktop')));
      await tester.tap(find.byKey(const ValueKey('ai-desktop')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Allow desktop'));
      await tester.pumpAndSettle();
      expect(find.text('Not saved yet'), findsOneWidget);
    });

    testWidgets('can be left out for a view with its own Save',
        (tester) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      edit = HostAiEdit.of(_host(HostAiAccess.readOnly));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: HostAiControls(
                edit: edit,
                showTitle: false,
                showUnsavedHint: false,
                onChanged: () {},
              ),
            ),
          ),
        ),
      );
      await choose(tester, HostAiAccess.off);
      expect(find.text('Not saved yet'), findsNothing);
      expect(find.text('AI access'), findsNothing);
    });
  });

  group('phone width', () {
    for (final level in HostAiAccess.values) {
      testWidgets('360 x 740 fits at ${level.name}, also with large text',
          (tester) async {
        for (final scale in [1.0, 1.5]) {
          await pump(
            tester,
            _host(level, terminal: true, desktop: true, commands: ['x' * 120]),
            textScale: scale,
          );
          expect(tester.takeException(), isNull, reason: 'scale $scale');
          if (level == HostAiAccess.askToChange) {
            await tester.ensureVisible(find.byKey(const ValueKey('ai-advanced')));
            await tester.tap(find.text('Advanced'));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull, reason: 'scale $scale');
          }
        }
      });
    }

    testWidgets('the full control confirmation fits 360 x 740 at 1.5x text',
        (tester) async {
      await pump(tester, _host(HostAiAccess.readOnly), textScale: 1.5);
      await choose(tester, HostAiAccess.fullControl);
      expect(tester.takeException(), isNull);
      for (final label in ['Cancel', 'Give full control']) {
        final r = tester.getRect(find.text(label));
        expect(r.bottom, lessThanOrEqualTo(740), reason: label);
        expect(r.right, lessThanOrEqualTo(360), reason: label);
      }
    });
  });

  group('the level chip', () {
    testWidgets('names each level, and only full control is marked',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                for (final level in HostAiAccess.values)
                  HostAiLevelChip(level: level),
              ],
            ),
          ),
        ),
      );
      for (final text in ['Off', 'Read only', 'Asks first', 'Full control']) {
        expect(find.text(text), findsOneWidget);
      }
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    });
  });
}
