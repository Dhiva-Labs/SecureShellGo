import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/l10n/l10n.dart';
import 'package:secure_shell_go/models/app_settings.dart';
import 'package:secure_shell_go/screens/remote_app_launcher.dart';
import 'package:secure_shell_go/services/remote_app_history.dart';
import 'package:secure_shell_go/services/remote_app_runner.dart';
import 'package:secure_shell_go/services/session_controller.dart';
import 'package:secure_shell_go/services/ssh_service.dart';
import 'package:secure_shell_go/services/x11_forwarding.dart';
import 'package:secure_shell_go/theme.dart';

import 'support/remote_app_fakes.dart';
import 'support/settle.dart';
import 'support/temp_dir.dart';

/// A history that stays in memory, so these tests do not wait on real files.
class _MemoryHistory extends RemoteAppHistory {
  final Map<String, List<String>> data = {};

  @override
  Future<List<String>> recent(String hostId) async =>
      List.of(data[hostId] ?? const <String>[]);

  @override
  Future<void> record(String hostId, String command) async {
    final list = data.putIfAbsent(hostId, () => []);
    list
      ..remove(command.trim())
      ..insert(0, command.trim());
  }

  @override
  Future<void> remove(String hostId, String command) async {
    data[hostId]?.remove(command);
  }
}

class _Fixture {
  _Fixture({
    bool hostX11 = true,
    bool hasForwarder = true,
    bool certificateWithoutX11 = false,
    bool supported = true,
    bool windows = false,
    bool untrusted = true,
    Future<void> Function(X11Display)? reachDisplay,
    this.open,
    RemoteAppHistory? history,
  }) : history = history ?? _MemoryHistory() {
    transport = FakeX11Transport(
      host: remoteAppHost(
        x11: hostX11,
        certificateWithoutX11: certificateWithoutX11,
      ),
      forwarder:
          hasForwarder ? remoteAppForwarder(untrusted: untrusted) : null,
    );
    session = remoteAppSession(transport);
    runner = RemoteAppRunner(
      session,
      isSupportedPlatform: supported,
      isWindows: windows,
      reachDisplay: reachDisplay ?? (_) async {},
      stopTimeout: const Duration(seconds: 1),
      openChannel: (t, command, x11) async {
        final custom = open;
        if (custom != null) return custom(t, command, x11);
        final app = ScriptedApp();
        programs.add(app);
        opened.add(command);
        return app;
      },
    );
    addTearDown(() async {
      runner.dispose();
      await session.dispose();
    });
  }

  late final FakeX11Transport transport;
  late final SessionController session;
  late final RemoteAppRunner runner;
  final RemoteAppHistory history;
  final Future<SSHSession> Function(
    SessionTransport,
    String,
    SSHX11Config,
  )? open;
  final List<ScriptedApp> programs = [];
  final List<String> opened = [];

  var virtualDesktops = 0;
  var enabledX11 = 0;
}

const _phone = Size(400, 800);
const _desktop = Size(1100, 900);

Future<void> _pumpLauncher(
  WidgetTester tester,
  _Fixture f, {
  Size size = _desktop,
  bool offerVirtualDesktop = true,
  bool offerEnableX11 = true,
  Future<List<InstalledRemoteApp>> Function()? listInstalledApps,
  Locale? locale,
  ThemeData? theme,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => openRemoteAppLauncher(
                context,
                session: f.session,
                runner: f.runner,
                history: f.history,
                onOfferVirtualDesktop:
                    offerVirtualDesktop ? () => f.virtualDesktops++ : null,
                onEnableX11: offerEnableX11 ? () => f.enabledX11++ : null,
                listInstalledApps: listInstalledApps,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Finder get _commandField => find.byType(TextField);

bool _enabled(WidgetTester tester, String label) => tester
    .widget<ButtonStyleButton>(find.ancestor(
      of: find.text(label),
      matching: find.bySubtype<ButtonStyleButton>(),
    ))
    .enabled;

Future<void> _runCommand(WidgetTester tester, String command) async {
  await tester.enterText(_commandField, command);
  await tester.pump();
  // By its icon, so this works in every language.
  await tester.tap(find.byIcon(Icons.play_arrow));
  await tester.pumpAndSettle();
}

void main() {
  // The app's own themes make filled buttons as wide as they may be, which
  // in a row of buttons is infinitely wide: the default theme the other
  // tests use cannot show that.
  for (final style in UiStyle.values) {
    testWidgets('lays out under the app\'s ${style.name} theme', (tester) async {
      final f = _Fixture();
      await _pumpLauncher(
        tester,
        f,
        theme: AppTheme.themeFor(style, Brightness.dark),
      );
      await _runCommand(tester, 'xclock');
      expect(tester.takeException(), isNull);
      expect(find.text('xclock'), findsWidgets);

      await _pumpLauncher(
        tester,
        _Fixture(hostX11: false, hasForwarder: false),
        theme: AppTheme.themeFor(style, Brightness.dark),
      );
      expect(tester.takeException(), isNull);
    });
  }

  group('where it opens', () {
    testWidgets('as a dialog on a wide screen', (tester) async {
      await _pumpLauncher(tester, _Fixture());
      expect(find.byType(Dialog), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('Open an app in a window'), findsOneWidget);
    });

    testWidgets('as a bottom sheet on a phone', (tester) async {
      await _pumpLauncher(tester, _Fixture(), size: _phone);
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.byType(Dialog), findsNothing);
      expect(find.text('Open an app in a window'), findsOneWidget);
    });

    testWidgets('as a sheet on a phone turned on its side', (tester) async {
      await _pumpLauncher(tester, _Fixture(), size: const Size(800, 380));
      expect(find.byType(BottomSheet), findsOneWidget);
    });

    testWidgets('the close button closes it', (tester) async {
      await _pumpLauncher(tester, _Fixture());
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(find.text('Open an app in a window'), findsNothing);
    });
  });

  group('running an app', () {
    testWidgets('Run waits for a command', (tester) async {
      await _pumpLauncher(tester, _Fixture());
      expect(_enabled(tester, 'Run'), isFalse);
      await tester.enterText(_commandField, '   ');
      await tester.pump();
      expect(_enabled(tester, 'Run'), isFalse);
      await tester.enterText(_commandField, 'xeyes');
      await tester.pump();
      expect(_enabled(tester, 'Run'), isTrue);
    });

    testWidgets('starts the command, lists it running, and clears the field',
        (tester) async {
      final f = _Fixture();
      await _pumpLauncher(tester, f);

      await _runCommand(tester, 'xeyes -geometry 200x200');

      expect(f.opened, [RemoteAppRunner.wrapCommand('xeyes -geometry 200x200')]);
      expect(find.text('Apps from this session'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(Card),
          matching: find.text('xeyes -geometry 200x200'),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('Running', findRichText: true), findsOneWidget);
      expect(find.text('Stop'), findsOneWidget);
      expect(tester.widget<TextField>(_commandField).controller!.text, '');
    });

    testWidgets('Enter in the field runs it too', (tester) async {
      final f = _Fixture();
      await _pumpLauncher(tester, f);
      await tester.enterText(_commandField, 'gedit');
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await tester.pumpAndSettle();
      expect(f.opened, hasLength(1));
    });

    testWidgets('adds the command to this host\'s recents', (tester) async {
      final f = _Fixture();
      await _pumpLauncher(tester, f);
      expect(find.text('Recent'), findsNothing);

      await _runCommand(tester, 'gedit');
      await _runCommand(tester, 'xeyes');

      expect(find.text('Recent'), findsOneWidget);
      // Newest first.
      final gedit = tester.getTopLeft(find.widgetWithText(InputChip, 'gedit'));
      final xeyes = tester.getTopLeft(find.widgetWithText(InputChip, 'xeyes'));
      expect(xeyes.dx, lessThan(gedit.dx));
      expect((f.history as _MemoryHistory).data['h1'], ['xeyes', 'gedit']);
    });

    testWidgets('a recent command is offered again, and fills the field',
        (tester) async {
      final f = _Fixture();
      await (f.history).record('h1', 'firefox');
      await _pumpLauncher(tester, f);

      await tester.tap(find.widgetWithText(InputChip, 'firefox'));
      await tester.pump();
      expect(tester.widget<TextField>(_commandField).controller!.text,
          'firefox');
      expect(_enabled(tester, 'Run'), isTrue);
    });

    testWidgets('a recent command can be forgotten', (tester) async {
      final f = _Fixture();
      await f.history.record('h1', 'firefox');
      await f.history.record('h1', 'gedit');
      await _pumpLauncher(tester, f);

      await tester.tap(find.descendant(
        of: find.widgetWithText(InputChip, 'firefox'),
        matching: find.byTooltip('Forget this command'),
      ));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(InputChip, 'firefox'), findsNothing);
      expect(find.widgetWithText(InputChip, 'gedit'), findsOneWidget);
      expect((f.history as _MemoryHistory).data['h1'], ['gedit']);
    });

    testWidgets('a command that did not start stays in the field and out of recents',
        (tester) async {
      final f = _Fixture(
        open: (_, _, _) async => throw StateError('no channel'),
      );
      await _pumpLauncher(tester, f);

      await _runCommand(tester, 'gedit');

      expect(tester.widget<TextField>(_commandField).controller!.text, 'gedit');
      expect(find.text('Recent'), findsNothing);
      expect(find.textContaining('Could not start', findRichText: true),
          findsOneWidget);
      expect(find.textContaining('no channel', findRichText: true),
          findsOneWidget);
    });

    testWidgets('the real history file records it too', (tester) async {
      final dir = Directory.systemTemp.createTempSync('launcher_history');
      addTearDown(() => deleteTempDir(dir));
      final file = File('${dir.path}/${RemoteAppHistory.fileName}');
      final f = _Fixture(history: RemoteAppHistory(file: file));
      await _pumpLauncher(tester, f);

      await _runCommand(tester, 'gedit');
      await checkEventually(tester, () async {
        expect(jsonDecode(await file.readAsString())['hosts']['h1'], ['gedit']);
      });
    });

    testWidgets('the apps are still listed when it is opened again',
        (tester) async {
      final f = _Fixture();
      await _pumpLauncher(tester, f);
      await _runCommand(tester, 'xeyes');
      await tester.tap(find.byIcon(Icons.close).first);
      await tester.pumpAndSettle();
      expect(find.text('Open an app in a window'), findsNothing);

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('xeyes'), findsWidgets);
      expect(find.text('Stop'), findsOneWidget);
    });
  });

  group('the apps from this session', () {
    testWidgets('Stop kills the program and says Stopped', (tester) async {
      final f = _Fixture();
      await _pumpLauncher(tester, f);
      await _runCommand(tester, 'xeyes');
      f.programs.single.say('4242\n');
      await tester.pump();

      await tester.tap(find.text('Stop'));
      await tester.pumpAndSettle();

      expect(f.transport.commands.single, contains('kill 4242'));
      expect(f.programs.single.wasClosed, isTrue);
      expect(find.text('Stop'), findsNothing);
      expect(find.textContaining('Stopped', findRichText: true), findsOneWidget);
    });

    testWidgets('an app that ended shows how, and can be removed',
        (tester) async {
      final f = _Fixture();
      await _pumpLauncher(tester, f);
      await _runCommand(tester, 'false');

      f.programs.single.end(code: 3);
      await tester.pumpAndSettle();

      expect(find.textContaining('Exited with code 3', findRichText: true),
          findsOneWidget);
      expect(find.text('Stop'), findsNothing);

      await tester.tap(find.byTooltip('Remove from the list'));
      await tester.pumpAndSettle();
      expect(find.text('Apps from this session'), findsNothing);
    });

    testWidgets('other ways an app can end are put in words', (tester) async {
      final f = _Fixture();
      await _pumpLauncher(tester, f);
      await _runCommand(tester, 'a');
      await _runCommand(tester, 'b');
      await _runCommand(tester, 'c');

      f.programs[0].end(code: 0);
      f.programs[1].end(signal: 'SEGV');
      f.programs[2].end();
      await tester.pumpAndSettle();

      expect(find.textContaining('Exited with code 0', findRichText: true),
          findsOneWidget);
      expect(find.textContaining('Ended by signal SEGV', findRichText: true),
          findsOneWidget);
      expect(find.textContaining('Ended', findRichText: true), findsWidgets);
    });

    testWidgets('shows what the program wrote to stderr', (tester) async {
      final f = _Fixture();
      await _pumpLauncher(tester, f);
      await _runCommand(tester, 'nope');

      f.programs.single.complain(utf8.encode('sh: 1: nope: not found\n'));
      f.programs.single.end(code: 127);
      await tester.pumpAndSettle();

      expect(find.text('Error output'), findsOneWidget);
      expect(find.textContaining('nope: not found'), findsOneWidget);
      expect(find.textContaining('Exited with code 127', findRichText: true),
          findsOneWidget);
    });

    testWidgets('shows what the X11 forwarder could not do', (tester) async {
      final f = _Fixture();
      await _pumpLauncher(tester, f);
      await _runCommand(tester, 'xeyes');

      final channel = FakeX11Channel();
      final handled = f.transport.forwarder!.handle(channel);
      channel.incoming.add(Uint8List.fromList([0]));
      await tester.runAsync(() => handled);
      await tester.pumpAndSettle();

      expect(find.textContaining('Something other than an X11 client'),
          findsOneWidget);
    });

    testWidgets('warns on the app when the display could not limit it',
        (tester) async {
      final f = _Fixture(untrusted: false);
      await _pumpLauncher(tester, f);
      await _runCommand(tester, 'xeyes');

      expect(
        find.text('This display cannot give the server limited access, so '
            'this app can see and control every window on it.'),
        findsWidgets,
      );
    });

    testWidgets('a lost connection is said, not guessed at', (tester) async {
      final f = _Fixture();
      await _pumpLauncher(tester, f);
      await _runCommand(tester, 'xeyes');

      f.transport.drop();
      await tester.pumpAndSettle();

      expect(find.textContaining('Connection lost', findRichText: true),
          findsOneWidget);
    });
  });

  group('when it cannot open a window', () {
    Future<void> expectNoForm(WidgetTester tester) async {
      expect(find.text("An app can't open in a window right now"),
          findsOneWidget);
      expect(_commandField, findsNothing);
      expect(find.text('Run'), findsNothing);
    }

    testWidgets('X11 forwarding off for the host', (tester) async {
      final f = _Fixture(hostX11: false, hasForwarder: false);
      await _pumpLauncher(tester, f);

      await expectNoForm(tester);
      expect(find.textContaining('X11 forwarding is off for this host'),
          findsOneWidget);
      expect(find.text('Turn on X11 forwarding for this host'), findsOneWidget);
      expect(find.text('Open a virtual desktop instead'), findsOneWidget);
      expect(find.text('Check again'), findsNothing);
    });

    testWidgets('Turn on X11 forwarding closes the launcher, then asks for it',
        (tester) async {
      final f = _Fixture(hostX11: false, hasForwarder: false);
      await _pumpLauncher(tester, f);

      await tester.tap(find.text('Turn on X11 forwarding for this host'));
      await tester.pumpAndSettle();

      expect(f.enabledX11, 1);
      expect(f.virtualDesktops, 0);
      expect(find.text('Open an app in a window'), findsNothing);
    });

    testWidgets('no host switch to offer when nothing is wired to it',
        (tester) async {
      final f = _Fixture(hostX11: false, hasForwarder: false);
      await _pumpLauncher(tester, f,
          offerEnableX11: false, offerVirtualDesktop: false);
      await expectNoForm(tester);
      expect(find.text('Turn on X11 forwarding for this host'), findsNothing);
      expect(find.text('Open a virtual desktop instead'), findsNothing);
    });

    testWidgets('Open a virtual desktop instead closes it, then offers one',
        (tester) async {
      final f = _Fixture(hostX11: false, hasForwarder: false);
      await _pumpLauncher(tester, f);

      await tester.tap(find.text('Open a virtual desktop instead'));
      await tester.pumpAndSettle();

      expect(f.virtualDesktops, 1);
      expect(f.enabledX11, 0);
      expect(find.text('Open an app in a window'), findsNothing);
    });

    testWidgets('no X display on this device', (tester) async {
      final f = _Fixture(hasForwarder: false);
      await _pumpLauncher(tester, f);

      await expectNoForm(tester);
      expect(find.textContaining('DISPLAY is not set'), findsOneWidget);
      expect(find.textContaining('VcXsrv'), findsNothing);
      expect(find.text('Check again'), findsOneWidget);
      expect(find.text('Open a virtual desktop instead'), findsOneWidget);
      expect(find.text('Turn on X11 forwarding for this host'), findsNothing);
    });

    testWidgets('on Windows it says to install an X server', (tester) async {
      final f = _Fixture(
        windows: true,
        reachDisplay: (_) async =>
            throw const SocketException('Connection refused'),
      );
      await _pumpLauncher(tester, f);

      await expectNoForm(tester);
      expect(find.textContaining('VcXsrv or X410'), findsOneWidget);
      expect(find.text('Check again'), findsOneWidget);
      expect(find.text('Open a virtual desktop instead'), findsOneWidget);
    });

    testWidgets('Check again finds an X server that has started',
        (tester) async {
      var up = false;
      final f = _Fixture(
        windows: true,
        reachDisplay: (_) async {
          if (!up) throw const SocketException('Connection refused');
        },
      );
      await _pumpLauncher(tester, f);
      expect(find.text('Check again'), findsOneWidget);

      up = true;
      await tester.tap(find.text('Check again'));
      await tester.pumpAndSettle();

      expect(_commandField, findsOneWidget);
      expect(find.text('Check again'), findsNothing);
    });

    testWidgets('a device with no X server at all', (tester) async {
      final f = _Fixture(supported: false, hasForwarder: false);
      await _pumpLauncher(tester, f);

      await expectNoForm(tester);
      expect(find.textContaining('no X server to draw'), findsOneWidget);
      expect(find.text('Open a virtual desktop instead'), findsOneWidget);
      expect(find.text('Check again'), findsNothing);
      expect(find.text('Turn on X11 forwarding for this host'), findsNothing);
    });

    testWidgets('SSH not up', (tester) async {
      final f = _Fixture();
      f.transport.close();
      await _pumpLauncher(tester, f);

      await expectNoForm(tester);
      expect(find.textContaining("SSH connection to the server isn't available"),
          findsOneWidget);
      expect(find.text('Open a virtual desktop instead'), findsOneWidget);
    });

    testWidgets('the server refusing X11, with the sshd_config hint',
        (tester) async {
      final f = _Fixture(
        open: (_, _, _) async =>
            throw SSHChannelRequestError('Failed to request x11 forwarding'),
      );
      await _pumpLauncher(tester, f);
      expect(_commandField, findsOneWidget);

      await _runCommand(tester, 'xeyes');

      await expectNoForm(tester);
      expect(find.textContaining('X11Forwarding no'), findsOneWidget);
      expect(find.textContaining('xauth'), findsOneWidget);
      expect(find.textContaining('permit-X11-forwarding'), findsNothing);
      expect(find.text('Open a virtual desktop instead'), findsOneWidget);
      // The refused attempt is listed against its command, in words.
      expect(find.textContaining('Refused by the server', findRichText: true),
          findsOneWidget);
      expect(
        find.descendant(of: find.byType(Card), matching: find.text('xeyes')),
        findsOneWidget,
      );
    });

    testWidgets('the server refusing X11 for a certificate that forbids it',
        (tester) async {
      final f = _Fixture(
        certificateWithoutX11: true,
        open: (_, _, _) async =>
            throw SSHChannelRequestError('Failed to request x11 forwarding'),
      );
      await _pumpLauncher(tester, f);
      await _runCommand(tester, 'xeyes');

      expect(find.textContaining('permit-X11-forwarding'), findsOneWidget);
      expect(find.textContaining('ask its CA'), findsOneWidget);
      expect(find.text('Open a virtual desktop instead'), findsOneWidget);
    });

    testWidgets('the virtual desktop is offered after a refusal too',
        (tester) async {
      final f = _Fixture(
        open: (_, _, _) async =>
            throw SSHChannelRequestError('Failed to request x11 forwarding'),
      );
      await _pumpLauncher(tester, f);
      await _runCommand(tester, 'xeyes');

      await tester.tap(find.text('Open a virtual desktop instead'));
      await tester.pumpAndSettle();
      expect(f.virtualDesktops, 1);
    });
  });

  group('the security note', () {
    testWidgets('on Linux says limited access, as ssh -X', (tester) async {
      await _pumpLauncher(tester, _Fixture());
      expect(find.textContaining('limited access to this display, as with ssh -X'),
          findsOneWidget);
      expect(find.textContaining('Only open apps from servers you trust'),
          findsOneWidget);
    });

    testWidgets('on Windows says the server can see and control every window',
        (tester) async {
      await _pumpLauncher(tester, _Fixture(windows: true));
      expect(
        find.textContaining('programs on the server can see and control every '
            'window on this display'),
        findsOneWidget,
      );
      expect(find.textContaining('as with ssh -X'), findsNothing);
    });

    testWidgets('where the display cannot limit it, says so first',
        (tester) async {
      await _pumpLauncher(tester, _Fixture(untrusted: false));
      expect(find.textContaining('This display cannot give the server limited '
          'access'), findsOneWidget);
    });

    testWidgets('is said once, not once per app', (tester) async {
      final f = _Fixture();
      await _pumpLauncher(tester, f);
      await _runCommand(tester, 'a');
      await _runCommand(tester, 'b');
      expect(find.textContaining('Only open apps from servers you trust'),
          findsOneWidget);
    });

    testWidgets('is not shown where nothing can be opened at all',
        (tester) async {
      await _pumpLauncher(tester, _Fixture(supported: false, hasForwarder: false));
      expect(find.textContaining('Only open apps from servers you trust'),
          findsNothing);
    });
  });

  group('installed apps', () {
    testWidgets('no button unless the caller can list them', (tester) async {
      await _pumpLauncher(tester, _Fixture());
      expect(find.text('Installed apps…'), findsNothing);
    });

    testWidgets('pick one and its command is in the field, not yet run',
        (tester) async {
      final f = _Fixture();
      await _pumpLauncher(
        tester,
        f,
        listInstalledApps: () async => [
          (name: 'Text Editor', command: 'gnome-text-editor %U'),
          (name: 'Firefox', command: 'firefox'),
        ],
      );

      await tester.tap(find.text('Installed apps…'));
      await tester.pumpAndSettle();
      expect(find.text('Apps on the server'), findsOneWidget);
      expect(find.text('Text Editor'), findsOneWidget);
      expect(find.text('Firefox'), findsOneWidget);

      await tester.enterText(find.widgetWithIcon(TextField, Icons.search), 'fire');
      await tester.pump();
      expect(find.text('Text Editor'), findsNothing);

      await tester.tap(find.text('Firefox'));
      await tester.pumpAndSettle();

      expect(find.text('Apps on the server'), findsNothing);
      expect(tester.widget<TextField>(_commandField).controller!.text,
          'firefox');
      expect(f.opened, isEmpty);
    });

    testWidgets('says so when there are none', (tester) async {
      await _pumpLauncher(tester, _Fixture(),
          listInstalledApps: () async => []);
      await tester.tap(find.text('Installed apps…'));
      await tester.pumpAndSettle();
      expect(find.text('No applications were found on the server.'),
          findsOneWidget);
    });

    testWidgets('says so when listing them fails', (tester) async {
      await _pumpLauncher(tester, _Fixture(),
          listInstalledApps: () async => throw StateError('no desktop files'));
      await tester.tap(find.text('Installed apps…'));
      await tester.pumpAndSettle();
      expect(find.textContaining("Could not read the server's list"),
          findsOneWidget);
      expect(find.textContaining('no desktop files'), findsOneWidget);
    });
  });

  // Translations run longer than English; every state is drawn at phone and
  // desktop widths in every language, and a RenderFlex overflow or any other
  // exception fails the test.
  group('fits every language', () {
    final sizes = {
      'a small phone': const Size(320, 640),
      'a phone': _phone,
      'a desktop': _desktop,
    };
    final states = <String, _Fixture Function()>{
      'with apps': () => _Fixture(untrusted: false),
      'with the host switch off': () =>
          _Fixture(hostX11: false, hasForwarder: false),
      'with no display': () => _Fixture(hasForwarder: false),
      'with no display on Windows': () => _Fixture(
            windows: true,
            reachDisplay: (_) async => throw const SocketException('down'),
          ),
      'on a device without X': () =>
          _Fixture(supported: false, hasForwarder: false),
      'with SSH down': () => _Fixture()..transport.close(),
      'after a refusal': () => _Fixture(
            certificateWithoutX11: true,
            open: (_, _, _) async =>
                throw SSHChannelRequestError('Failed to request x11 forwarding'),
          ),
    };
    for (final locale in AppLocalizations.supportedLocales) {
      for (final MapEntry(key: sizeName, value: size) in sizes.entries) {
        for (final MapEntry(key: stateName, value: make) in states.entries) {
          testWidgets('$locale on $sizeName $stateName', (tester) async {
            final f = make();
            await f.history.record('h1', 'a-rather-long-command --with=several --flags');
            await _pumpLauncher(
              tester,
              f,
              size: size,
              locale: locale,
              listInstalledApps: () async => [],
            );
            if (stateName == 'with apps' || stateName == 'after a refusal') {
              await _runCommand(
                tester,
                'firefox --new-window https://example.com/a/very/long/address/indeed',
              );
              if (stateName == 'with apps') {
                f.programs.single.complain(
                    utf8.encode('(firefox:1): Gtk-WARNING **: cannot open display\n' * 12));
                await tester.pumpAndSettle();
              }
            }
            expect(tester.takeException(), isNull);
          });
        }
      }
    }
  });
}
