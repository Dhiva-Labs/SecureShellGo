import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/app_settings.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/screens/host_edit_screen.dart';
import 'package:secure_shell_go/screens/host_list_screen.dart';
import 'package:secure_shell_go/screens/quick_connect_screen.dart';
import 'package:secure_shell_go/services/credential_store.dart';
import 'package:secure_shell_go/services/host_grouping.dart';
import 'package:secure_shell_go/services/host_store.dart';
import 'package:secure_shell_go/services/input_profile.dart';
import 'package:secure_shell_go/services/known_hosts_service.dart';
import 'package:secure_shell_go/services/quick_connect_parser.dart';
import 'package:secure_shell_go/services/session_manager.dart';
import 'package:secure_shell_go/services/settings_store.dart';
import 'package:secure_shell_go/services/ssh_service.dart';
import 'package:secure_shell_go/theme.dart';
import 'package:secure_shell_go/widgets/command_palette.dart';
import 'package:secure_shell_go/widgets/host_list_presentation.dart';

import 'support/settle.dart';

/// The home and host screens' rough edges, each pinned where it was filed:
/// the ⋮ button, a failed connection, quick connect, the host form and the
/// command palette.

class _MemoryBackend implements SecureStorageBackend {
  final Map<String, String> data = {};

  @override
  Future<void> write(String key, String value) async => data[key] = value;

  @override
  Future<String?> read(String key) async => data[key];

  @override
  Future<void> delete(String key) async => data.remove(key);
}

/// Refuses every connection, the way a wrong password does, and counts.
class _RefusingSshService extends SshService {
  _RefusingSshService({required super.knownHosts});

  int attempts = 0;

  @override
  Future<SshConnection> connect({
    required Host host,
    required SshCredentials credentials,
    required HostKeyVerifier verifyHostKey,
    LoginPromptHandler? answerPrompts,
    ServerBannerHandler? onBanner,
    Duration timeout = SshService.defaultTimeout,
    bool agentForwarding = false,
  }) async {
    attempts++;
    throw const SshConnectionException('Authentication failed.');
  }
}

/// A profile that has seen [pointers] and, with [keyboard], a key typed.
InputProfile _profileOf(
  List<PointerDeviceKind> pointers, {
  bool keyboard = false,
}) {
  final profile = InputProfile();
  for (final kind in pointers) {
    profile.notePointer(kind);
  }
  if (keyboard) profile.noteHardwareKey();
  return profile;
}

final _mouse = [PointerDeviceKind.mouse];
final _touch = [PointerDeviceKind.touch];

const _buildBox = Host(
  id: 'h1',
  label: 'Build box',
  hostname: 'build.example.org',
  port: 22,
  username: 'ci',
  authMethod: SshAuthMethod.password,
);

void main() {
  late Directory dir;
  late SettingsStore settings;
  late HostStore hosts;
  late KnownHostsService knownHosts;
  late _RefusingSshService ssh;

  // Built here, outside the test's fake clock: a store made inside a
  // `testWidgets` body chains its writes on that clock, and `runAsync` then
  // waits on them for ever.
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ux_hosts_test');
    settings =
        SettingsStore(file: File('${dir.path}/${SettingsStore.fileName}'));
    hosts = HostStore(file: File('${dir.path}/${HostStore.fileName}'));
    knownHosts = KnownHostsService(
      file: File('${dir.path}/${KnownHostsService.fileName}'),
    );
    ssh = _RefusingSshService(knownHosts: knownHosts);
  });

  tearDown(() async {
    settings.dispose();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  /// The app with [profile] in charge of what counts as touch, mouse and
  /// keyboard, and a navigator a pushed screen can pop back down.
  Widget app({
    required InputProfile profile,
    required Widget home,
    TargetPlatform platform = TargetPlatform.android,
    GlobalKey<NavigatorState>? navigator,
  }) =>
      MaterialApp(
        navigatorKey: navigator,
        theme: AppTheme.dark.copyWith(platform: platform),
        builder: (context, child) =>
            InputProfileScope(profile: profile, child: child!),
        home: home,
      );

  /// Lets the stores' real file work finish. Not pumpAndSettle: the host
  /// list keeps a spinner turning while it has anything to wait on.
  Future<void> settle(WidgetTester tester, {int rounds = 20}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 600));
  }

  Future<SessionManager> pumpHostList(
    WidgetTester tester, {
    required InputProfile profile,
    TargetPlatform platform = TargetPlatform.android,
    CredentialStore? credentials,
  }) async {
    final sessions = SessionManager();
    addTearDown(sessions.dispose);
    await tester.runAsync(() => hosts.add(_buildBox));
    await tester.pumpWidget(app(
      profile: profile,
      platform: platform,
      home: HostListScreen(
        hostStore: hosts,
        credentialStore: credentials ?? CredentialStore(backend: _MemoryBackend()),
        knownHosts: knownHosts,
        sshService: ssh,
        settingsStore: settings,
        sessions: sessions,
      ),
    ));
    await settle(tester);
    return sessions;
  }

  group('the ⋮ on a host', () {
    testWidgets('with a mouse, opens the menu from the button', (tester) async {
      await pumpHostList(
        tester,
        profile: _profileOf(_mouse, keyboard: true),
        platform: TargetPlatform.linux,
      );

      // The card's own, not the app bar's overflow menu.
      final more = find.descendant(
        of: find.byType(Card),
        matching: find.byTooltip('More'),
      );
      final button = tester.getRect(more);
      await tester.tap(more, kind: PointerDeviceKind.mouse);
      await settle(tester);

      // The menu a right-click opens: one line per action, no sheet.
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('Forget host keys'), findsOneWidget);
      expect(find.text('Undoes trust-on-first-use for this server'),
          findsNothing);
      // Dropped from the button, not from wherever the window's edge is.
      final first = tester.getRect(find.text('Select'));
      expect((first.top - button.top).abs(), lessThan(48));
      expect(
        first.left < button.right + 8 && first.right > button.left - 280,
        isTrue,
        reason: 'menu $first, button $button',
      );
    });

    testWidgets('with touch, still opens the sheet', (tester) async {
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await pumpHostList(tester, profile: _profileOf(_touch));

      await tester.tap(find.descendant(
        of: find.byType(ListTile),
        matching: find.byTooltip('More'),
      ));
      await settle(tester);

      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.text('Undoes trust-on-first-use for this server'),
          findsOneWidget);
    });

    group('in the AWS table', () {
      Future<void> pumpTable(
        WidgetTester tester, {
        required InputProfile profile,
        required TargetPlatform platform,
        required void Function(Host host) onHostMenu,
      }) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.themeFor(UiStyle.aws, Brightness.dark)
              .copyWith(platform: platform),
          builder: (context, child) =>
              InputProfileScope(profile: profile, child: child!),
          home: Scaffold(
            body: CustomScrollView(
              slivers: HostListPresentation.buildSectionSlivers(
                sections: HostGrouping.buildSections([_buildBox]),
                style: UiStyle.aws,
                width: 1280,
                searching: false,
                isCollapsed: (_) => false,
                connectingHostId: null,
                actions: HostListActions(
                  onToggleSection: (_) {},
                  onRenameGroup: (_) {},
                  onDeleteGroup: (_) {},
                  onConnect: (_) {},
                  onHostMenu: onHostMenu,
                ),
              ),
            ),
          ),
        ));
        await tester.pumpAndSettle();
      }

      testWidgets('is a 48dp target on touch, all of it live', (tester) async {
        Host? opened;
        await pumpTable(
          tester,
          profile: _profileOf(_touch),
          platform: TargetPlatform.android,
          onHostMenu: (host) => opened = host,
        );

        final more = find.byTooltip('More');
        expect(tester.getSize(more), const Size(48, 48));
        // A fingertip near the corner of the target, well outside where the
        // old 28dp box used to clip it.
        await tester.tapAt(tester.getRect(more).topLeft + const Offset(3, 3));
        await tester.pumpAndSettle();
        expect(opened?.id, 'h1');
      });

      testWidgets('keeps its console density with a mouse', (tester) async {
        await pumpTable(
          tester,
          profile: _profileOf(_mouse, keyboard: true),
          platform: TargetPlatform.linux,
          onHostMenu: (_) {},
        );
        expect(tester.getSize(find.byTooltip('More')), const Size(28, 28));
      });
    });
  });

  group('a connection that fails', () {
    Future<void> failToConnect(WidgetTester tester) async {
      final credentials = CredentialStore(backend: _MemoryBackend());
      await tester.runAsync(
        () => credentials.save('h1', const SshCredentials(password: 'nope')),
      );
      await pumpHostList(
        tester,
        profile: _profileOf(_touch),
        credentials: credentials,
      );
      await tester.tap(find.text('Build box'));
      await settle(tester);
      expect(find.text('Could not connect'), findsOneWidget);
    }

    testWidgets('offers to try again, and does', (tester) async {
      await failToConnect(tester);
      expect(find.text('Try again'), findsOneWidget);
      expect(find.text('Edit host'), findsOneWidget);
      expect(find.text('OK'), findsOneWidget);
      expect(ssh.attempts, 1);

      await tester.tap(find.text('Try again'));
      await settle(tester);
      expect(ssh.attempts, 2);
      expect(find.text('Could not connect'), findsOneWidget);

      await tester.tap(find.text('OK'));
      await settle(tester);
      expect(find.text('Could not connect'), findsNothing);
      expect(ssh.attempts, 2);
    });

    testWidgets('offers to edit the host, and opens its form', (tester) async {
      await failToConnect(tester);

      await tester.tap(find.text('Edit host'));
      await settle(tester, rounds: 40);
      expect(find.text('Could not connect'), findsNothing);
      expect(find.byType(HostEditScreen), findsOneWidget);
      final form = tester.widget<HostEditScreen>(find.byType(HostEditScreen));
      expect(form.host?.id, 'h1');
    });
  });

  group('quick connect', () {
    const target = QuickConnectTarget(
      username: 'ec2-user',
      hostname: '203.0.113.10',
      port: 22,
    );

    testWidgets('the password field has the focus as it opens',
        (tester) async {
      final sessions = SessionManager();
      addTearDown(sessions.dispose);
      await tester.pumpWidget(app(
        profile: _profileOf(_touch),
        home: QuickConnectScreen(
          target: target,
          sshService: ssh,
          sessions: sessions,
          hostStore: hosts,
          credentialStore: CredentialStore(backend: _MemoryBackend()),
        ),
      ));
      await tester.pumpAndSettle();

      final password = tester.widget<EditableText>(find.descendant(
        of: find.widgetWithText(TextFormField, 'Password'),
        matching: find.byType(EditableText),
      ));
      expect(password.focusNode.hasFocus, isTrue);
    });

    group('once connected', () {
      Future<GlobalKey<NavigatorState>> pumpOffer(WidgetTester tester) async {
        final navigator = GlobalKey<NavigatorState>();
        await tester.pumpWidget(app(
          profile: _profileOf(_mouse, keyboard: true),
          platform: TargetPlatform.linux,
          navigator: navigator,
          home: const Scaffold(body: SizedBox.shrink()),
        ));
        unawaited(navigator.currentState!.push(MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            body: QuickConnectSaveOffer(
              host: const Host(
                id: 'quick-1',
                label: '',
                hostname: '203.0.113.10',
                port: 22,
                username: 'ec2-user',
                authMethod: SshAuthMethod.password,
              ),
              credentials: const SshCredentials(password: 'hunter2'),
              hostStore: hosts,
              credentialStore: CredentialStore(backend: _MemoryBackend()),
            ),
          ),
        )));
        await tester.pumpAndSettle();
        return navigator;
      }

      testWidgets('no dialog asks first; saving is on the page',
          (tester) async {
        await pumpOffer(tester);
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.text('Save this server'), findsOneWidget);
      });

      testWidgets('Done has the keyboard, so Enter goes on to the session',
          (tester) async {
        final navigator = await pumpOffer(tester);
        expect(
          Focus.of(tester.element(find.text('Done'))).hasPrimaryFocus,
          isTrue,
        );

        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(find.byType(QuickConnectSaveOffer), findsNothing);
        expect(navigator.currentState!.canPop(), isFalse);
      });
    });
  });

  group('the host form', () {
    /// Pushes the form onto a route, as the host list does: it pops itself
    /// when done, and a navigator with nothing left under it never settles.
    Future<GlobalKey<NavigatorState>> pumpForm(
      WidgetTester tester, {
      required InputProfile profile,
      TargetPlatform platform = TargetPlatform.android,
      Size size = const Size(1000, 3000),
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final sessions = SessionManager();
      addTearDown(sessions.dispose);

      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(app(
        profile: profile,
        platform: platform,
        navigator: navigator,
        home: const Scaffold(body: SizedBox.shrink()),
      ));
      unawaited(navigator.currentState!.push(MaterialPageRoute<bool>(
        builder: (_) => HostEditScreen(
          hostStore: hosts,
          credentialStore: CredentialStore(backend: _MemoryBackend()),
          sshService: ssh,
          settingsStore: settings,
          sessions: sessions,
        ),
      )));
      await tester.pump();
      await settleIo(tester, rounds: 30);
      await tester.pumpAndSettle();
      return navigator;
    }

    EditableText field(WidgetTester tester, String label) =>
        tester.widget<EditableText>(find.descendant(
          of: find.widgetWithText(TextFormField, label),
          matching: find.byType(EditableText),
        ));

    Future<void> fillIn(WidgetTester tester) async {
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Host'), 'example.com');
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Username'), 'root');
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Password'), 'hunter2');
    }

    Future<void> expectSaved(WidgetTester tester) async {
      await settleIo(tester, rounds: 10);
      await checkEventually(tester, () async {
        expect((await hosts.all()).single.hostname, 'example.com');
      });
    }

    testWidgets('with a keyboard, Host has the focus as it opens',
        (tester) async {
      await pumpForm(
        tester,
        profile: _profileOf(_mouse, keyboard: true),
        platform: TargetPlatform.linux,
      );
      expect(field(tester, 'Host').focusNode.hasFocus, isTrue);
    });

    testWidgets('on touch alone, no field takes it', (tester) async {
      await pumpForm(tester, profile: _profileOf(_touch));
      expect(field(tester, 'Host').focusNode.hasFocus, isFalse);
      expect(FocusManager.instance.primaryFocus?.context?.widget,
          isNot(isA<EditableText>()));
    });

    testWidgets('Save is in the app bar', (tester) async {
      await pumpForm(tester, profile: _profileOf(_touch));
      await fillIn(tester);
      await tester.runAsync(() => tester.tap(find.byTooltip('Save host')));
      await tester.pump();
      await expectSaved(tester);
    });

    testWidgets('Ctrl+S saves', (tester) async {
      await pumpForm(
        tester,
        profile: _profileOf(_mouse, keyboard: true),
        platform: TargetPlatform.linux,
      );
      await fillIn(tester);
      await tester.runAsync(() async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      });
      await tester.pump();
      await expectSaved(tester);
    });

    testWidgets('Enter in the last line field submits', (tester) async {
      await pumpForm(tester, profile: _profileOf(_touch));
      await fillIn(tester);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Run after connect (optional)'),
        'uptime',
      );
      await tester.runAsync(
        () => tester.testTextInput.receiveAction(TextInputAction.done),
      );
      await tester.pump();
      await expectSaved(tester);
    });

    testWidgets('an untouched form goes back without asking', (tester) async {
      final navigator = await pumpForm(tester, profile: _profileOf(_touch));
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Discard changes?'), findsNothing);
      expect(find.byType(HostEditScreen), findsNothing);
      expect(navigator.currentState!.canPop(), isFalse);
    });

    testWidgets('a changed form asks before throwing it away',
        (tester) async {
      await pumpForm(tester, profile: _profileOf(_touch));
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Label (optional)'), 'Web');
      await tester.pump();

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Discard changes?'), findsOneWidget);
      expect(find.text('Your changes to this host have not been saved.'),
          findsOneWidget);

      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      expect(find.text('Discard changes?'), findsNothing);
      expect(find.byType(HostEditScreen), findsOneWidget);
      expect(find.text('Web'), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();
      expect(find.byType(HostEditScreen), findsNothing);
      expect(await tester.runAsync(hosts.all), isEmpty);
    });

    testWidgets('a refused save scrolls up to the first field it names',
        (tester) async {
      // A phone on its side: the save buttons are a long way below Host.
      await pumpForm(
        tester,
        profile: _profileOf(_touch),
        size: const Size(800, 420),
      );
      await tester.ensureVisible(find.text('Save host'));
      await tester.pumpAndSettle();
      final scroller = tester.getRect(find.byType(SingleChildScrollView));
      final hostBefore =
          tester.getRect(find.widgetWithText(TextFormField, 'Host'));
      expect(hostBefore.bottom, lessThan(scroller.top),
          reason: 'Host starts scrolled out of view');

      await tester.tap(find.text('Save host'));
      await tester.pumpAndSettle();

      expect(find.text('Required'), findsWidgets);
      final hostAfter =
          tester.getRect(find.widgetWithText(TextFormField, 'Host'));
      expect(hostAfter.top, greaterThanOrEqualTo(scroller.top - 1));
      expect(hostAfter.bottom, lessThanOrEqualTo(scroller.bottom + 1));
      expect(await tester.runAsync(hosts.all), isEmpty);
    });
  });

  group('the command palette', () {
    Future<void> openPalette(
      WidgetTester tester,
      List<PaletteItem> items,
    ) async {
      await tester.pumpWidget(app(
        profile: _profileOf(_mouse, keyboard: true),
        platform: TargetPlatform.linux,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showCommandPalette(context, items: items),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    List<PaletteItem> manyHosts() => [
          for (var i = 0; i < 40; i++)
            PaletteItem(
              kind: PaletteItemKind.host,
              title: 'Host $i',
              subtitle: 'dev@host-$i.example.com',
              onSelect: () {},
            ),
        ];

    void expectInView(WidgetTester tester, String title) {
      final list = tester.getRect(find.byType(ListView));
      final row = tester.getRect(find.text(title));
      expect(row.top, greaterThanOrEqualTo(list.top - 0.5), reason: title);
      expect(row.bottom, lessThanOrEqualTo(list.bottom + 0.5), reason: title);
    }

    testWidgets('the arrow keys keep the highlight in view', (tester) async {
      await openPalette(tester, manyHosts());

      for (var i = 0; i < 25; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expectInView(tester, 'Host 25');

      // Up past the top wraps round to the last row, far out of view.
      for (var i = 0; i < 26; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expectInView(tester, 'Host 39');

      // And down off the end, back to the first.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expectInView(tester, 'Host 0');
    });

    testWidgets('a host is found by its address too, after names',
        (tester) async {
      String? picked;
      await openPalette(tester, [
        PaletteItem(
          kind: PaletteItemKind.host,
          title: 'Alpha',
          subtitle: 'deploy@db-01.example.com',
          onSelect: () => picked = 'Alpha',
        ),
        PaletteItem(
          kind: PaletteItemKind.host,
          title: 'db box',
          subtitle: 'root@10.0.0.9',
          onSelect: () => picked = 'db box',
        ),
        PaletteItem(
          kind: PaletteItemKind.action,
          title: 'Settings',
          onSelect: () => picked = 'Settings',
        ),
      ]);

      await tester.enterText(find.byType(TextField), 'db');
      await tester.pumpAndSettle();
      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('Settings'), findsNothing);
      // The name match first, the address match after it.
      expect(
        tester.getTopLeft(find.text('db box')).dy,
        lessThan(tester.getTopLeft(find.text('Alpha')).dy),
      );

      await tester.enterText(find.byType(TextField), '10.0.0');
      await tester.pumpAndSettle();
      expect(find.text('db box'), findsOneWidget);
      expect(find.text('Alpha'), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(picked, 'db box');
    });
  });
}
