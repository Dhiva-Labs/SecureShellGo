import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/models/host_ai_access.dart';
import 'package:secure_shell_go/screens/host_edit_screen.dart';
import 'package:secure_shell_go/services/composite_secure_storage.dart';
import 'package:secure_shell_go/services/credential_store.dart';
import 'package:secure_shell_go/services/device_storage.dart';
import 'package:secure_shell_go/services/device_vault_key.dart';
import 'package:secure_shell_go/services/host_store.dart';
import 'package:secure_shell_go/services/known_hosts_service.dart';
import 'package:secure_shell_go/services/secret_vault.dart';
import 'package:secure_shell_go/services/session_manager.dart';
import 'package:secure_shell_go/services/settings_store.dart';
import 'package:secure_shell_go/services/ssh_keygen.dart';
import 'package:secure_shell_go/services/ssh_service.dart';
import 'package:secure_shell_go/widgets/error_banner.dart';

import 'support/certificate_fixture.dart';

import 'support/settle.dart';
import 'support/temp_dir.dart';

/// A keyring that this install has had working before and that is locked
/// right now — the one remaining state in which a credential cannot be
/// stored anywhere. Everything else now encrypts rather than refusing.
class _LockedKeyring implements SecureStorageBackend {
  @override
  Future<void> write(String key, String value) async {
    throw const SecureStorageUnavailableException(
      'locked',
      code: 'KeyringLocked',
    );
  }

  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> delete(String key) async {}
}

/// Counts what reaches secure storage, so "connect without saving" can be
/// held to writing nothing at all rather than merely to looking as if it did.
class _CountingBackend implements SecureStorageBackend {
  final Map<String, String> data = {};
  int writes = 0;
  int deletes = 0;

  @override
  Future<void> write(String key, String value) async {
    writes++;
    data[key] = value;
  }

  @override
  Future<String?> read(String key) async => data[key];

  @override
  Future<void> delete(String key) async {
    deletes++;
    data.remove(key);
  }
}

/// Fails every connection, deterministically, and counts the attempts. The
/// three actions differ in whether they save and whether they dial; both
/// halves have to be observable for that to be testable at all.
class _CountingSshService extends SshService {
  _CountingSshService({required super.knownHosts});

  int attempts = 0;
  Host? lastHost;
  SshCredentials? lastCredentials;

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
    lastHost = host;
    lastCredentials = credentials;
    throw const SshConnectionException('No server here.');
  }
}

void main() {
  late Directory dir;
  late HostStore hosts;
  late SettingsStore settings;
  late _CountingSshService ssh;
  late SessionManager sessions;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ssg_host_edit_test');
    hosts = HostStore(file: File('${dir.path}/${HostStore.fileName}'));
    settings =
        SettingsStore(file: File('${dir.path}/${SettingsStore.fileName}'));
    ssh = _CountingSshService(
      knownHosts: KnownHostsService(
        file: File('${dir.path}/${KnownHostsService.fileName}'),
      ),
    );
    sessions = SessionManager();
  });

  tearDown(() async {
    settings.dispose();
    await deleteTempDir(dir);
  });

  CompositeSecureStorageBackend backendWith({
    required SecureStorageBackend keyring,
    required bool keyringAvailable,
  }) {
    return CompositeSecureStorageBackend(
      keyring: keyring,
      vault: SecretVault(
        file: File('${dir.path}/${SecretVault.fileName}'),
        useIsolate: false,
      ),
      keyringAvailable: () async => keyringAvailable,
      deviceKey: DeviceVaultKey(
        file: File('${dir.path}/${DeviceVaultKey.fileName}'),
      ),
      state: SecureStorageState(
        file: File('${dir.path}/${SecureStorageState.fileName}'),
      ),
    );
  }

  /// The ordinary case: no keyring on this machine, so credentials are
  /// device-encrypted without anybody being asked.
  CredentialStore noKeyringStore() => CredentialStore(
        backend: backendWith(
          keyring: _LockedKeyring(),
          keyringAvailable: false,
        ),
      );

  /// Pushes the form onto a route, rather than making it the whole app: the
  /// screen pops itself when it is done, and a navigator with nothing left
  /// under it never settles.
  Future<void> pumpForm(
    WidgetTester tester,
    CredentialStore credentials, {
    Host? host,
    DeviceStorage? deviceStorage,
    bool aiBridge = false,
  }) async {
    // Tall enough that the whole form, buttons included, is built — a
    // `ListView` does not create what is off screen, and a finder cannot tap
    // what was never built.
    tester.view.physicalSize = const Size(1000, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: const Scaffold(body: SizedBox.shrink()),
      ),
    );
    unawaited(
      navigator.currentState!.push(
        MaterialPageRoute<bool>(
          builder: (_) => HostEditScreen(
            hostStore: hosts,
            credentialStore: credentials,
            sshService: ssh,
            settingsStore: settings,
            sessions: sessions,
            host: host,
            deviceStorage: deviceStorage,
            aiBridgeAvailable: aiBridge,
          ),
        ),
      ),
    );
    // The screen loads its group list, its jump-host candidates and (when
    // editing) the saved credential off disk in initState, and shows a
    // spinner meanwhile — so the disk has to be let go of before anything
    // can settle.
    await tester.pump();
    await settleIo(tester, rounds: 60);
    await tester.pumpAndSettle();
  }

  Future<void> fillIn(
    WidgetTester tester, {
    String host = 'example.com',
    String username = 'root',
    String password = 'hunter2',
  }) async {
    await tester.enterText(find.widgetWithText(TextFormField, 'Host'), host);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Username'),
      username,
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Password'),
      password,
    );
  }

  /// Taps [label], lets the work behind it finish, then runs [checks] where
  /// the stores can be read back. See [settleIo].
  Future<void> tapAndRun(
    WidgetTester tester,
    String label, {
    Future<void> Function()? checks,
  }) async {
    // The tap itself goes through `runAsync` so that the handler it starts
    // runs on the real event loop: the save path shells out to `chmod` for
    // the device key file, and a fake clock never lets a subprocess finish.
    await tester.runAsync(() => tester.tap(find.text(label)));
    await tester.pump();
    await settleIo(tester, rounds: 60);
    if (checks != null) {
      // The save encrypts and shells out to `chmod`, which on a busy
      // machine outlasts any fixed wait. A failure says what the screen
      // said: a save that threw shows its cause in the error banner.
      await checkEventually(tester, checks, describe: () {
        final banners = [
          for (final e in find.byType(ErrorBanner).evaluate())
            '${(e.widget as ErrorBanner).message} '
                '${(e.widget as ErrorBanner).details ?? ''}',
        ];
        final notices = [
          for (final e in find.textContaining('Host saved, but').evaluate())
            (e.widget as Text).data ?? '',
        ];
        return 'On screen — banners: $banners; notices: $notices';
      });
    }
    await tester.pump();
  }

  /// Same reasoning, for a test that has to put something on disk before the
  /// form opens.
  Future<T> withRealIo<T>(
    WidgetTester tester,
    Future<T> Function() body,
  ) async {
    late T result;
    await tester.runAsync(() async {
      result = await body();
    });
    return result;
  }

  group('the three actions', () {
    testWidgets('"Save host" saves and does not dial', (tester) async {
      final credentials = noKeyringStore();
      await pumpForm(tester, credentials);
      await fillIn(tester);
      await tapAndRun(tester, 'Save host', checks: () async {
        final saved = (await hosts.all()).single;
        expect(saved.hostname, 'example.com');
        expect((await credentials.load(saved.id))?.password, 'hunter2');
      });

      expect(ssh.attempts, 0);
      expect(find.byType(ErrorBanner), findsNothing);
    });

    testWidgets('"Save & connect" saves and then dials', (tester) async {
      final credentials = noKeyringStore();
      await pumpForm(tester, credentials);
      await fillIn(tester);
      await tapAndRun(tester, 'Save & connect', checks: () async {
        final saved = (await hosts.all()).single;
        expect((await credentials.load(saved.id))?.password, 'hunter2');
      });

      await settleUntil(
        tester,
        () => ssh.attempts == 1 && find.byType(ErrorBanner).evaluate().isNotEmpty,
      );
      expect(ssh.attempts, 1);
      // The connection failed, which is a real error and shown as one — but
      // the host is saved regardless, which is the point of the ordering.
      expect(find.byType(ErrorBanner), findsOneWidget);
    });

    testWidgets('"Connect without saving" writes absolutely nothing',
        (tester) async {
      final backend = _CountingBackend();
      await pumpForm(tester, CredentialStore(backend: backend));
      await fillIn(tester);
      await tapAndRun(tester, 'Connect without saving', checks: () async {
        expect(await hosts.all(), isEmpty);
        expect(
          await File('${dir.path}/${SecretVault.fileName}').exists(),
          isFalse,
        );
        expect(
          await File('${dir.path}/${DeviceVaultKey.fileName}').exists(),
          isFalse,
        );
      });

      expect(ssh.attempts, 1);
      expect(ssh.lastCredentials?.password, 'hunter2');
      expect(backend.writes, 0);
      expect(backend.deletes, 0);
    });

    testWidgets('connecting without saving leaves an edited host untouched',
        (tester) async {
      final original = Host(
        id: hosts.newId(),
        label: 'Original',
        hostname: 'example.com',
        port: 22,
        username: 'root',
        authMethod: SshAuthMethod.password,
      );
      final before = await withRealIo(tester, () async {
        await hosts.add(original);
        return File('${dir.path}/${HostStore.fileName}').readAsString();
      });

      final backend = _CountingBackend();
      await pumpForm(tester, CredentialStore(backend: backend), host: original);
      await fillIn(tester, host: 'somewhere-else.example');
      await tapAndRun(tester, 'Connect without saving', checks: () async {
        expect(
          await File('${dir.path}/${HostStore.fileName}').readAsString(),
          before,
        );
      });

      // The edit reached the connection and nothing else.
      expect(ssh.lastHost?.hostname, 'somewhere-else.example');
      expect(backend.writes, 0);
    });

    testWidgets('editing offers "Save changes", not "Save host"',
        (tester) async {
      final original = Host(
        id: hosts.newId(),
        label: 'Original',
        hostname: 'example.com',
        port: 22,
        username: 'root',
        authMethod: SshAuthMethod.password,
      );
      await withRealIo(tester, () => hosts.add(original));
      await pumpForm(tester, noKeyringStore(), host: original);

      expect(find.text('Save changes'), findsOneWidget);
      expect(find.text('Save host'), findsNothing);
      expect(find.text('Save & connect'), findsOneWidget);
      expect(find.text('Connect without saving'), findsOneWidget);
    });

    for (final action in [
      'Save host',
      'Save & connect',
      'Connect without saving',
    ]) {
      testWidgets('"$action" refuses an invalid port the same way',
          (tester) async {
        await pumpForm(tester, noKeyringStore());
        await fillIn(tester);
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Port'),
          '70000',
        );
        await tapAndRun(tester, action, checks: () async {
          expect(await hosts.all(), isEmpty);
        });

        expect(find.text('1-65535'), findsOneWidget);
        expect(ssh.attempts, 0);
      });
    }
  });

  group('a save that worked never reads as a failure', () {
    testWidgets('a host that saved is never shown as an error', (tester) async {
      // The keyring has worked here before and is locked now, so the password
      // genuinely cannot go anywhere. The host still saved, and that is what
      // the screen has to read as.
      await withRealIo(
        tester,
        () => SecureStorageState(
          file: File('${dir.path}/${SecureStorageState.fileName}'),
        ).recordKeyringAvailable(),
      );

      await pumpForm(tester, noKeyringStore());
      await fillIn(tester);
      await tapAndRun(tester, 'Save host', checks: () async {
        expect(await hosts.all(), hasLength(1));
      });
      // The host lands first; the word on its password follows.
      await settleUntil(
        tester,
        () => find
            .textContaining('Host saved, but its password was not')
            .evaluate()
            .isNotEmpty,
      );

      expect(find.byType(ErrorBanner), findsNothing);
      expect(
        find.textContaining('Host saved, but its password was not'),
        findsOneWidget,
      );
      // And the backend's own wording is carried through rather than
      // replaced: it is the only copy that can name the fix (on a snap, the
      // exact `snap connect` command).
      expect(find.textContaining('unlock it'), findsOneWidget);
    });

    testWidgets('with no keyring the password is encrypted, not dropped',
        (tester) async {
      final credentials = noKeyringStore();
      await pumpForm(tester, credentials);
      await fillIn(tester);
      await tapAndRun(tester, 'Save host', checks: () async {
        final saved = (await hosts.all()).single;
        expect((await credentials.load(saved.id))?.password, 'hunter2');
        // Device-encrypted, and nothing was asked for: a vault and the key
        // that opens it, both of which appeared on their own.
        final vault = SecretVault(
          file: File('${dir.path}/${SecretVault.fileName}'),
          useIsolate: false,
        );
        expect(await vault.isDeviceWrapped(), isTrue);
        expect(
          await File('${dir.path}/${DeviceVaultKey.fileName}').exists(),
          isTrue,
        );
      });

      expect(find.byType(ErrorBanner), findsNothing);
      // Nothing to explain on this screen: it saved, and it kept the password.
      expect(find.textContaining('Host saved, but'), findsNothing);
    });

    testWidgets('a host with nothing to remember stores nothing, quietly',
        (tester) async {
      // Agent auth is the form's own "remember nothing" case: it carries no
      // secret of its own, so there is nothing for the protection machinery
      // to do and nothing for it to say.
      final agentHost = Host(
        id: hosts.newId(),
        label: 'Agent',
        hostname: 'example.com',
        port: 22,
        username: 'root',
        authMethod: SshAuthMethod.agent,
      );
      await withRealIo(tester, () => hosts.add(agentHost));
      await pumpForm(tester, noKeyringStore(), host: agentHost);
      await tapAndRun(tester, 'Save changes', checks: () async {
        expect(await hosts.all(), hasLength(1));
        // Nothing was stored, so nothing had to be protected — no vault
        // appeared for a host that had no secret to put in one.
        expect(
          await File('${dir.path}/${SecretVault.fileName}').exists(),
          isFalse,
        );
      });

      expect(find.byType(ErrorBanner), findsNothing);
      expect(find.textContaining('Host saved, but'), findsNothing);
    });
  });

  group('a pasted address lands in the right fields', () {
    Future<void> expectSaved(
      WidgetTester tester,
      String typed, {
      required String hostname,
      required int port,
    }) async {
      await pumpForm(tester, noKeyringStore());
      await fillIn(tester, host: typed);
      await tapAndRun(tester, 'Save host', checks: () async {
        final saved = (await hosts.all()).single;
        expect(saved.hostname, hostname);
        expect(saved.port, port);
      });
    }

    testWidgets('the paste that started this', (tester) async {
      await expectSaved(
        tester,
        '127.0.0.1:22303',
        hostname: '127.0.0.1',
        port: 22303,
      );
    });

    testWidgets('a name with a port', (tester) async {
      await expectSaved(
        tester,
        'example.com:2222',
        hostname: 'example.com',
        port: 2222,
      );
    });

    testWidgets('a bracketed IPv6 address with a port', (tester) async {
      await expectSaved(tester, '[::1]:2222', hostname: '::1', port: 2222);
    });

    testWidgets('a bare IPv6 address is left alone', (tester) async {
      await expectSaved(tester, 'fe80::1', hostname: 'fe80::1', port: 22);
    });

    testWidgets('a plain hostname is left alone', (tester) async {
      await expectSaved(
        tester,
        'example.com',
        hostname: 'example.com',
        port: 22,
      );
    });

    testWidgets('a user@ prefix fills an empty Username field', (tester) async {
      await pumpForm(tester, noKeyringStore());
      // The Username field is never touched here: a paste fills an empty one,
      // and beats a default, but never something the user typed.
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Host'),
        'deploy@example.com:2222',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Password'),
        'hunter2',
      );
      await tapAndRun(tester, 'Save host', checks: () async {
        final saved = (await hosts.all()).single;
        expect(saved.hostname, 'example.com');
        expect(saved.port, 2222);
        expect(saved.username, 'deploy');
      });
    });

    testWidgets('connecting without saving parses identically',
        (tester) async {
      await pumpForm(tester, CredentialStore(backend: _CountingBackend()));
      await fillIn(tester, host: '127.0.0.1:22303');
      await tapAndRun(tester, 'Connect without saving');

      expect(ssh.lastHost?.hostname, '127.0.0.1');
      expect(ssh.lastHost?.port, 22303);
    });
  });

  group('the Advanced section', () {
    testWidgets('a new host starts folded, with every option off',
        (tester) async {
      await pumpForm(tester, noKeyringStore());

      expect(find.text('Advanced'), findsOneWidget);
      expect(find.text('Connection, session and forwarding'), findsOneWidget);
      expect(find.text('Forward SSH agent'), findsNothing,
          reason: 'folded away until asked for');

      await tester.tap(find.text('Advanced'));
      await tester.pumpAndSettle();
      for (final title in [
        'Forward SSH agent',
        'Forward X11',
        'Allow legacy algorithms',
      ]) {
        final tile = tester.widget<SwitchListTile>(
          find.widgetWithText(SwitchListTile, title),
        );
        expect(tile.value, isFalse, reason: title);
      }
    });

    // A desktop: on Android the X11 row is off and disabled.
    testWidgets('its choices are saved with the host',
        variant: TargetPlatformVariant.only(TargetPlatform.linux),
        (tester) async {
      await pumpForm(tester, noKeyringStore());
      await fillIn(tester);
      await tester.tap(find.text('Advanced'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Mosh'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<PersistentSession>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('tmux').last);
      await tester.pumpAndSettle();
      for (final title in [
        'Forward SSH agent',
        'Forward X11',
        'Allow legacy algorithms',
      ]) {
        await tester.tap(find.text(title));
        await tester.pumpAndSettle();
      }
      expect(
        find.text('Mosh · tmux · agent forwarding · X11 · legacy algorithms'),
        findsOneWidget,
        reason: 'the folded header says what is changed',
      );

      await tapAndRun(tester, 'Save host', checks: () async {
        final saved = (await hosts.all()).single;
        expect(saved.transport, HostTransport.mosh);
        expect(saved.persistentSession, PersistentSession.tmux);
        expect(saved.agentForwarding, isTrue);
        expect(saved.x11Forwarding, isTrue);
        expect(saved.legacyAlgorithms, isTrue);
      });
    });

    testWidgets('a host using it opens unfolded, and an edit keeps all of it',
        (tester) async {
      final original = Host(
        id: hosts.newId(),
        label: 'Build box',
        hostname: 'build.example.com',
        port: 22,
        username: 'ci',
        authMethod: SshAuthMethod.password,
        agentForwarding: true,
        persistentSession: PersistentSession.screen,
        certificate: 'ssh-ed25519-cert-v01@openssh.com AAAA ci@build',
      );
      await withRealIo(tester, () => hosts.add(original));
      await pumpForm(tester, noKeyringStore(), host: original);

      expect(find.text('Forward SSH agent'), findsOneWidget,
          reason: 'something in it is set, so it is shown');
      expect(find.text('GNU screen · agent forwarding'), findsOneWidget);

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Build box'),
        'Build box 2',
      );
      // Nothing saved for it yet, and a password host needs one to save.
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Password'),
        'hunter2',
      );
      await tapAndRun(tester, 'Save changes', checks: () async {
        final saved = (await hosts.all()).single;
        expect(saved.label, 'Build box 2');
        expect(saved.agentForwarding, isTrue);
        expect(saved.persistentSession, PersistentSession.screen);
        expect(saved.transport, HostTransport.ssh);
        expect(saved.certificate, original.certificate,
            reason: 'nothing on this form shows it, and saving must keep it');
      });
    });

    testWidgets('an edit keeps the host\'s AI Bridge access', (tester) async {
      final original = Host(
        id: hosts.newId(),
        label: 'Web',
        hostname: 'web.example.com',
        port: 22,
        username: 'dev',
        authMethod: SshAuthMethod.password,
        aiAccess: HostAiAccess.readOnly,
      );
      await withRealIo(tester, () => hosts.add(original));
      await pumpForm(tester, noKeyringStore(), host: original);

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Web'),
        'Web 2',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Password'),
        'hunter2',
      );
      await tapAndRun(tester, 'Save changes', checks: () async {
        final saved = (await hosts.all()).single;
        expect(saved.label, 'Web 2');
        expect(saved.aiAccess, HostAiAccess.readOnly,
            reason: 'renaming a host must not change what an assistant '
                'may reach');
      });
    });

    testWidgets('an edit keeps change access, allowed commands and terminal',
        (tester) async {
      final original = Host(
        id: hosts.newId(),
        label: 'Web',
        hostname: 'web.example.com',
        port: 22,
        username: 'dev',
        authMethod: SshAuthMethod.password,
        aiAccess: HostAiAccess.askToChange,
        aiAllowedCommands: const ['uptime', 'df -h'],
        aiTerminal: true,
      );
      await withRealIo(tester, () => hosts.add(original));
      await pumpForm(tester, noKeyringStore(), host: original, aiBridge: true);

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Web'),
        'Web 2',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Password'),
        'hunter2',
      );
      await tapAndRun(tester, 'Save changes', checks: () async {
        final saved = (await hosts.all()).single;
        expect(saved.label, 'Web 2');
        expect(saved.aiAccess, HostAiAccess.askToChange);
        expect(saved.aiAllowedCommands, ['uptime', 'df -h']);
        expect(saved.aiTerminal, isTrue);
      });
    });

    testWidgets('the AI access switch is not there without the bridge',
        (tester) async {
      await pumpForm(tester, noKeyringStore());
      expect(find.text('Share with AI assistants'), findsNothing);
    });

    testWidgets(
        'a new host starts with AI access off, and the switch turns it on',
        (tester) async {
      await pumpForm(tester, noKeyringStore(), aiBridge: true);
      expect(
        tester
            .widget<SwitchListTile>(
                find.widgetWithText(SwitchListTile, 'Share with AI assistants'))
            .value,
        isFalse,
      );
      await fillIn(tester);
      await tester.tap(find.text('Share with AI assistants'));
      await tester.pump();
      await tapAndRun(tester, 'Save host', checks: () async {
        expect((await hosts.all()).single.aiAccess, HostAiAccess.readOnly);
      });
    });

    testWidgets('an unchanged switch saves off', (tester) async {
      await pumpForm(tester, noKeyringStore(), aiBridge: true);
      await fillIn(tester);
      await tapAndRun(tester, 'Save host', checks: () async {
        expect((await hosts.all()).single.aiAccess, HostAiAccess.off);
      });
    });

    testWidgets('the switch shows a host\'s access and turns it off',
        (tester) async {
      final original = Host(
        id: hosts.newId(),
        label: 'Web',
        hostname: 'web.example.com',
        port: 22,
        username: 'dev',
        authMethod: SshAuthMethod.password,
        aiAccess: HostAiAccess.readOnly,
      );
      await withRealIo(tester, () => hosts.add(original));
      await pumpForm(tester, noKeyringStore(), host: original, aiBridge: true);
      expect(
        tester
            .widget<SwitchListTile>(
                find.widgetWithText(SwitchListTile, 'Share with AI assistants'))
            .value,
        isTrue,
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Password'),
        'hunter2',
      );
      await tester.tap(find.text('Share with AI assistants'));
      await tester.pump();
      await tapAndRun(tester, 'Save changes', checks: () async {
        expect((await hosts.all()).single.aiAccess, HostAiAccess.off);
      });
    });

    Host changingHost() => Host(
          id: hosts.newId(),
          label: 'Web',
          hostname: 'web.example.com',
          port: 22,
          username: 'dev',
          authMethod: SshAuthMethod.password,
          aiAccess: HostAiAccess.askToChange,
          aiAllowedCommands: const ['uptime'],
          aiTerminal: true,
        );

    for (final down in [HostAiAccess.off, HostAiAccess.readOnly]) {
      testWidgets(
          'access stepped down to ${down.name} while the form is open '
          'stays down after an unrelated edit', (tester) async {
        final original = changingHost();
        await withRealIo(tester, () => hosts.add(original));
        await pumpForm(tester, noKeyringStore(),
            host: original, aiBridge: true);
        // Elsewhere (the shared-hosts list, an approval card) the user steps
        // the host down while this form still holds the old copy.
        await withRealIo(
          tester,
          () => hosts.modify(original.id, (h) => h.copyWith(aiAccess: down)),
        );

        await tester.enterText(
          find.widgetWithText(TextFormField, 'Web'),
          'Web 2',
        );
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Password'),
          'hunter2',
        );
        await tapAndRun(tester, 'Save changes', checks: () async {
          final saved = (await hosts.all()).single;
          expect(saved.label, 'Web 2');
          expect(saved.aiAccess, down,
              reason: 'a stale form must not raise access back up');
          expect(saved.aiAllowedCommands, ['uptime'],
              reason: 'stored but inert, as stepping down leaves it');
          expect(saved.aiTerminal, isTrue);
        });
      });
    }

    testWidgets('switching off then on again keeps change access',
        (tester) async {
      final original = changingHost();
      await withRealIo(tester, () => hosts.add(original));
      await pumpForm(tester, noKeyringStore(), host: original, aiBridge: true);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Password'),
        'hunter2',
      );
      await tester.tap(find.text('Share with AI assistants'));
      await tester.pump();
      await tester.tap(find.text('Share with AI assistants'));
      await tester.pump();
      await tapAndRun(tester, 'Save changes', checks: () async {
        final saved = (await hosts.all()).single;
        expect(saved.aiAccess, HostAiAccess.askToChange);
        expect(saved.aiAllowedCommands, ['uptime']);
      });
    });

    testWidgets('switching on a host turned off elsewhere gives read-only',
        (tester) async {
      final original = changingHost().copyWith(aiAccess: HostAiAccess.off);
      await withRealIo(tester, () => hosts.add(original));
      await pumpForm(tester, noKeyringStore(), host: original, aiBridge: true);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Password'),
        'hunter2',
      );
      await tester.tap(find.text('Share with AI assistants'));
      await tester.pump();
      await tapAndRun(tester, 'Save changes', checks: () async {
        final saved = (await hosts.all()).single;
        expect(saved.aiAccess, HostAiAccess.readOnly,
            reason: 'the plain switch never turns change access on');
        expect(saved.aiMayRequestChanges, isFalse);
      });
    });
  });

  group('AI assistant change controls', () {
    Host readOnlyHost({List<String> commands = const []}) => Host(
          id: hosts.newId(),
          label: 'Web',
          hostname: 'web.example.com',
          port: 22,
          username: 'dev',
          authMethod: SshAuthMethod.password,
          aiAccess: HostAiAccess.readOnly,
          aiAllowedCommands: commands,
        );

    Future<void> pumpEdit(WidgetTester tester, Host host) async {
      await withRealIo(tester, () => hosts.add(host));
      await pumpForm(tester, noKeyringStore(), host: host, aiBridge: true);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Password'),
        'hunter2',
      );
    }

    testWidgets('the change switch is off, and hides what depends on it',
        (tester) async {
      await pumpEdit(tester, readOnlyHost());
      expect(
        tester
            .widget<SwitchListTile>(find.byKey(const ValueKey('ai-changes')))
            .value,
        isFalse,
      );
      expect(find.text('Allowed commands'), findsNothing);
      expect(find.text('Full control terminal'), findsNothing);
    });

    testWidgets('turning changes on asks first and lists the stored commands',
        (tester) async {
      final host = readOnlyHost(commands: ['uptime', 'df -h']);
      await pumpEdit(tester, host);
      await tester.tap(find.byKey(const ValueKey('ai-changes')));
      await tester.pumpAndSettle();
      expect(find.text('Let the assistant request changes?'), findsOneWidget);
      expect(find.textContaining('still needs your approval'), findsOneWidget);
      expect(find.text('• uptime'), findsOneWidget);
      expect(find.text('• df -h'), findsOneWidget);
      await tester.tap(find.text('Allow requests'));
      await tester.pumpAndSettle();
      expect(find.text('Allowed commands'), findsOneWidget);
      await tapAndRun(tester, 'Save changes', checks: () async {
        final saved = (await hosts.all()).single;
        expect(saved.aiAccess, HostAiAccess.askToChange);
        expect(saved.aiAllowedCommands, ['uptime', 'df -h']);
        expect(saved.aiTerminal, isFalse);
      });
    });

    testWidgets('the confirmation lists the STORED commands, not the form\'s',
        (tester) async {
      final host = readOnlyHost(commands: ['uptime']);
      await pumpEdit(tester, host);
      await withRealIo(
        tester,
        () => hosts.modify(
          host.id,
          (h) => h.copyWith(aiAllowedCommands: ['uptime', 'reboot']),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('ai-changes')));
      await tester.pumpAndSettle();
      expect(find.text('• reboot'), findsOneWidget);
      await tester.tap(find.text('Allow requests'));
      await tester.pumpAndSettle();
      await tapAndRun(tester, 'Save changes', checks: () async {
        expect((await hosts.all()).single.aiAllowedCommands,
            ['uptime', 'reboot']);
      });
    });

    testWidgets('cancelling the confirmation changes nothing', (tester) async {
      await pumpEdit(tester, readOnlyHost(commands: ['uptime']));
      await tester.tap(find.byKey(const ValueKey('ai-changes')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SwitchListTile>(find.byKey(const ValueKey('ai-changes')))
            .value,
        isFalse,
      );
      await tapAndRun(tester, 'Save changes', checks: () async {
        final saved = (await hosts.all()).single;
        expect(saved.aiAccess, HostAiAccess.readOnly);
        expect(saved.aiAllowedCommands, ['uptime']);
      });
    });

    for (final accept in [false, true]) {
      testWidgets('a terminal stored on while read-only is confirmed again '
          'when changes are turned on (${accept ? 'accepted' : 'cancelled'})',
          (tester) async {
        final host = readOnlyHost().copyWith(aiTerminal: true);
        await pumpEdit(tester, host);
        await tester.tap(find.byKey(const ValueKey('ai-changes')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Allow requests'));
        await tester.pumpAndSettle();
        // The terminal's own confirmation, with its full warning.
        expect(find.text('Allow a full control terminal?'), findsOneWidget);
        expect(find.textContaining('no further questions'), findsOneWidget);
        await tester.tap(find.text(accept ? 'Allow terminal' : 'Cancel'));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<SwitchListTile>(find.byKey(const ValueKey('ai-terminal')))
              .value,
          accept,
        );
        await tapAndRun(tester, 'Save changes', checks: () async {
          final saved = (await hosts.all()).single;
          expect(saved.aiAccess, HostAiAccess.askToChange);
          expect(saved.aiTerminal, accept);
        });
      });
    }

    Future<void> turnChangesOn(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('ai-changes')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Allow requests'));
      await tester.pumpAndSettle();
    }

    testWidgets('adds an allowed command, shown and saved exactly',
        (tester) async {
      await pumpEdit(tester, readOnlyHost());
      await turnChangesOn(tester);
      expect(find.byKey(const ValueKey('ai-commands-warning')), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('ai-command-field')),
        '  systemctl status nginx  ',
      );
      await tester.tap(find.byKey(const ValueKey('ai-command-add')));
      await tester.pump();
      expect(find.text('systemctl status nginx'), findsOneWidget);
      await tapAndRun(tester, 'Save changes', checks: () async {
        final saved = (await hosts.all()).single;
        expect(saved.aiAllowedCommands, ['systemctl status nginx']);
        expect(saved.aiAccess, HostAiAccess.askToChange);
      });
    });

    final refused = <String, (String, String)>{
      'a line break': ('uptime\nreboot', 'cannot contain a line break'),
      'a control character': ('echo \u001b[31m', 'hidden or control character'),
      'a right-to-left override': ('ls \u202Etxt.exe', 'hidden or control'),
      'a no-break space': ('ls\u00A0-l', 'not a normal space'),
      'a zero-width space': ('ls\u200B', 'hidden or control'),
      'nothing': ('   ', 'Type a command first'),
      'too many characters': ('x' * 4097, 'longer than 4096'),
    };
    for (final entry in refused.entries) {
      testWidgets('refuses ${entry.key} and says why', (tester) async {
        await pumpEdit(tester, readOnlyHost());
        await turnChangesOn(tester);
        await tester.enterText(
          find.byKey(const ValueKey('ai-command-field')),
          entry.value.$1,
        );
        await tester.tap(find.byKey(const ValueKey('ai-command-add')));
        await tester.pump();
        expect(find.textContaining(entry.value.$2), findsOneWidget);
        await tapAndRun(tester, 'Save changes', checks: () async {
          expect((await hosts.all()).single.aiAllowedCommands, isEmpty);
        });
      });
    }

    testWidgets('refuses a duplicate', (tester) async {
      await pumpEdit(tester, readOnlyHost(commands: ['uptime']));
      await turnChangesOn(tester);
      await tester.enterText(
        find.byKey(const ValueKey('ai-command-field')),
        'uptime',
      );
      await tester.tap(find.byKey(const ValueKey('ai-command-add')));
      await tester.pump();
      expect(find.text('Already on the list.'), findsOneWidget);
    });

    testWidgets('a long allowed command is listed in full, never cut',
        (tester) async {
      final long = 'echo ${List.generate(800, (i) => 'w$i').join(' ')}';
      await pumpEdit(tester, readOnlyHost(commands: [long]));
      await turnChangesOn(tester);
      final text = tester.widget<Text>(find.descendant(
        of: find.byKey(ValueKey('ai-command-$long')),
        matching: find.byType(Text),
      ).first);
      expect(text.data, long);
      expect(text.maxLines, isNull);
      expect(text.overflow, isNot(TextOverflow.ellipsis));
    });

    for (final size in [const Size(320, 568), const Size(1920, 1080)]) {
      testWidgets('50 stored commands of 4096 characters: the confirmation '
          'lists every one and its buttons stay reachable at '
          '${size.width.toInt()}x${size.height.toInt()}, text 1.5x',
          (tester) async {
        final commands = [
          for (var i = 0; i < 50; i++)
            'c$i ${'x' * 60} ${List.filled(900, 'word').join(' ')}'
                .substring(0, 4096),
        ];
        await pumpEdit(tester, readOnlyHost(commands: commands));
        tester.view.physicalSize = size;
        tester.platformDispatcher.textScaleFactorTestValue = 1.5;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(const ValueKey('ai-changes')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('ai-changes')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byKey(const ValueKey('ai-confirm-command')),
            findsNWidgets(50));
        for (final label in ['Cancel', 'Allow requests']) {
          final r = tester.getRect(find.text(label));
          expect(r.bottom, lessThanOrEqualTo(size.height), reason: label);
          expect(r.right, lessThanOrEqualTo(size.width), reason: label);
        }
        await tester.tap(find.text('Allow requests'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byKey(const ValueKey('ai-terminal')), findsOneWidget);
      });
    }

    testWidgets('removes an allowed command', (tester) async {
      await pumpEdit(tester, readOnlyHost(commands: ['uptime', 'df -h']));
      await turnChangesOn(tester);
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('ai-command-uptime')),
          matching: find.byIcon(Icons.close),
        ),
      );
      await tester.pump();
      await tapAndRun(tester, 'Save changes', checks: () async {
        expect((await hosts.all()).single.aiAllowedCommands, ['df -h']);
      });
    });

    testWidgets('the terminal switch asks, with the warning, and writes only '
        'itself', (tester) async {
      await pumpEdit(tester, readOnlyHost(commands: ['uptime']));
      await turnChangesOn(tester);
      await tester.tap(find.byKey(const ValueKey('ai-terminal')));
      await tester.pumpAndSettle();
      expect(find.text('Allow a full control terminal?'), findsOneWidget);
      expect(find.textContaining('live shell'), findsOneWidget);
      expect(find.textContaining('blocked-path list does not apply'),
          findsOneWidget);
      await tester.tap(find.text('Allow terminal'));
      await tester.pumpAndSettle();
      await tapAndRun(tester, 'Save changes', checks: () async {
        final saved = (await hosts.all()).single;
        expect(saved.aiTerminal, isTrue);
        expect(saved.aiAllowedCommands, ['uptime']);
      });
    });

    testWidgets('cancelling the terminal confirmation leaves it off',
        (tester) async {
      await pumpEdit(tester, readOnlyHost());
      await turnChangesOn(tester);
      await tester.tap(find.byKey(const ValueKey('ai-terminal')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tapAndRun(tester, 'Save changes', checks: () async {
        expect((await hosts.all()).single.aiTerminal, isFalse);
      });
    });

    testWidgets('a stale form writes only the field the user changed',
        (tester) async {
      final host = readOnlyHost(commands: ['uptime']).copyWith(
        aiAccess: HostAiAccess.askToChange,
      );
      await pumpEdit(tester, host);
      // Elsewhere: the list is edited, the terminal allowed, and the host
      // stepped down to read-only.
      await withRealIo(
        tester,
        () => hosts.modify(
          host.id,
          (h) => h.copyWith(
            aiAllowedCommands: ['uptime', 'df -h'],
            aiTerminal: true,
            aiAccess: HostAiAccess.readOnly,
          ),
        ),
      );
      // In this form only the label changes.
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Web'),
        'Web 2',
      );
      await tapAndRun(tester, 'Save changes', checks: () async {
        final saved = (await hosts.all()).single;
        expect(saved.label, 'Web 2');
        expect(saved.aiAccess, HostAiAccess.readOnly,
            reason: 'a stale form must not raise access');
        expect(saved.aiAllowedCommands, ['uptime', 'df -h']);
        expect(saved.aiTerminal, isTrue);
      });
    });

    testWidgets('a stale form that changes one command list keeps the '
        'stored access and terminal', (tester) async {
      final host = readOnlyHost(commands: ['uptime']).copyWith(
        aiAccess: HostAiAccess.askToChange,
      );
      await pumpEdit(tester, host);
      await withRealIo(
        tester,
        () => hosts.modify(host.id, (h) => h.copyWith(aiTerminal: true)),
      );
      await tester.enterText(
        find.byKey(const ValueKey('ai-command-field')),
        'df -h',
      );
      await tester.tap(find.byKey(const ValueKey('ai-command-add')));
      await tester.pump();
      await tapAndRun(tester, 'Save changes', checks: () async {
        final saved = (await hosts.all()).single;
        expect(saved.aiAllowedCommands, ['uptime', 'df -h']);
        expect(saved.aiTerminal, isTrue);
        expect(saved.aiAccess, HostAiAccess.askToChange);
      });
    });

    testWidgets('narrow, large text: the controls fit without overflow',
        (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pumpEdit(
        tester,
        readOnlyHost(commands: ['x' * 120]).copyWith(
          aiAccess: HostAiAccess.askToChange,
        ),
      );
      tester.view.physicalSize = const Size(320, 3000);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('the certificate', () {
    late String publicBlobBase64;

    /// A key host, with a freshly generated key in the form.
    Future<Uint8List> fillKeyHost(WidgetTester tester) async {
      final generated = SshKeygen.generateEd25519(comment: 'me@laptop');
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Host'), 'example.com');
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Username'), 'dev');
      await tester.tap(find.text('Private key'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Private key (PEM)'),
        generated.privateKeyPem,
      );
      await tester.pumpAndSettle();
      publicBlobBase64 = generated.publicKeyLine.split(' ')[1];
      return base64.decode(publicBlobBase64);
    }

    Uint8List otherKey() => base64.decode(SshKeygen.generateEd25519(
          comment: 'other',
        ).publicKeyLine.split(' ')[1]);

    Future<void> paste(WidgetTester tester, String text) async {
      await tester.tap(find.text('Paste certificate'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        text,
      );
      await tester.tap(find.text('Use'));
      await tester.pumpAndSettle();
    }

    testWidgets('a key host offers to load or paste one', (tester) async {
      await pumpForm(tester, noKeyringStore());
      await fillKeyHost(tester);
      expect(find.text('Load certificate'), findsOneWidget);
      expect(find.text('Paste certificate'), findsOneWidget);
    });

    testWidgets('pasted for this key: its details are shown and it saves',
        (tester) async {
      await pumpForm(tester, noKeyringStore());
      final key = await fillKeyHost(tester);
      final line = certificateLineFor(
        key,
        principals: ['dev', 'deploy'],
        validAfter: DateTime.now().subtract(const Duration(days: 1)),
        validBefore: DateTime.now().add(const Duration(days: 30, hours: 1)),
      );
      await paste(tester, line);

      expect(find.text('Certificate · ED25519'), findsOneWidget);
      expect(find.textContaining('alice@example'), findsOneWidget);
      expect(find.textContaining('dev, deploy'), findsOneWidget);
      expect(find.text('Valid, expires in 30 days.'), findsOneWidget);
      expect(find.text('Remove'), findsOneWidget);

      await tapAndRun(tester, 'Save host', checks: () async {
        expect((await hosts.all()).single.certificate, line);
      });
    });

    testWidgets('one issued for another key stops the save, and says why',
        (tester) async {
      await pumpForm(tester, noKeyringStore());
      await fillKeyHost(tester);
      await paste(tester, certificateLineFor(otherKey()));

      expect(find.textContaining('issued for a different key'), findsOneWidget);
      await tapAndRun(tester, 'Save host', checks: () async {
        expect(await hosts.all(), isEmpty);
      });
    });

    testWidgets('an expired one is flagged but still saves', (tester) async {
      await pumpForm(tester, noKeyringStore());
      final key = await fillKeyHost(tester);
      await paste(
        tester,
        certificateLineFor(
          key,
          validAfter: DateTime.utc(2020),
          validBefore: DateTime.utc(2020, 1, 2),
        ),
      );
      expect(find.textContaining('Expired on 2020-01-02'), findsOneWidget);
      await tapAndRun(tester, 'Save host', checks: () async {
        expect((await hosts.all()).single.certificate, isNotNull);
      });
    });

    testWidgets('it warns when it does not name the user', (tester) async {
      await pumpForm(tester, noKeyringStore());
      final key = await fillKeyHost(tester);
      await paste(tester, certificateLineFor(key, principals: ['root']));
      expect(find.textContaining('does not name the user "dev"'), findsOneWidget);
    });

    testWidgets('Remove takes it off the host', (tester) async {
      await pumpForm(tester, noKeyringStore());
      final key = await fillKeyHost(tester);
      await paste(tester, certificateLineFor(key));
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      expect(find.text('Paste certificate'), findsOneWidget);
      await tapAndRun(tester, 'Save host', checks: () async {
        expect((await hosts.all()).single.certificate, isNull);
      });
    });

    testWidgets('the paste dialog explains what was pasted instead',
        (tester) async {
      await pumpForm(tester, noKeyringStore());
      await fillKeyHost(tester);
      await paste(tester, 'ssh-ed25519 $publicBlobBase64 me@laptop');
      expect(find.textContaining('public key, not a certificate'),
          findsOneWidget);
      expect(find.byType(AlertDialog), findsOneWidget,
          reason: 'it stays open for another try');
    });

    testWidgets('loaded from a file through the picker', (tester) async {
      final picker = _PickingStorage();
      await pumpForm(tester, noKeyringStore(), deviceStorage: picker);
      final key = await fillKeyHost(tester);
      picker.next = PickedTextFile(
        name: 'id_ed25519-cert.pub',
        content: '${certificateLineFor(key, keyId: 'from-file')}\n',
      );
      await tester.tap(find.text('Load certificate'));
      await tester.pumpAndSettle();
      expect(find.textContaining('from-file'), findsOneWidget);
      expect(picker.maxBytes, lessThanOrEqualTo(16 * 1024));
    });

    testWidgets('a picked file that is not one is explained', (tester) async {
      final picker = _PickingStorage();
      await pumpForm(tester, noKeyringStore(), deviceStorage: picker);
      await fillKeyHost(tester);
      picker.next = PickedTextFile(
        name: 'host-cert.pub',
        content: certificateLineFor(otherKey(), host: true),
      );
      await tester.tap(find.text('Load certificate'));
      await tester.pumpAndSettle();
      expect(find.text('Could not import host-cert.pub'), findsOneWidget);
      expect(find.textContaining('host certificate'), findsOneWidget);
    });
  });

  group('the OS agent', () {
    testWidgets('is offered on a desktop, with the certificate row',
        variant: TargetPlatformVariant.only(TargetPlatform.linux),
        (tester) async {
      await pumpForm(tester, noKeyringStore());
      await tester.tap(find.text('OS SSH agent'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Pageant'), findsOneWidget);
      expect(find.text('Paste certificate'), findsOneWidget);
    });

    testWidgets('is not offered on Android, which has none', (tester) async {
      await pumpForm(tester, noKeyringStore());
      expect(find.text('OS SSH agent'), findsNothing);
    });

    testWidgets('the three choices fit a narrow desktop window',
        variant: TargetPlatformVariant.only(TargetPlatform.linux),
        (tester) async {
      await pumpForm(tester, noKeyringStore());
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      for (final scale in [1.0, 1.5]) {
        tester.view.physicalSize = const Size(320, 3000);
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        final errors = <FlutterErrorDetails>[];
        final previous = FlutterError.onError;
        FlutterError.onError = errors.add;
        await tester.pumpAndSettle();
        FlutterError.onError = previous;
        // Only the sign-in choice is this test's business; other rows of
        // the form are swept by layout_sweep_test.dart.
        expect(
          errors.where((e) => e.toString().contains('SegmentedButton')),
          isEmpty,
          reason: 'text scale $scale',
        );
      }
      await tester.tap(find.text('Agent'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Pageant'), findsOneWidget);
    });
  });

  group('forwarding rows', () {
    testWidgets('on Android, X11 is off and disabled, with the reason',
        (tester) async {
      await pumpForm(tester, noKeyringStore());
      await tester.tap(find.text('Advanced'));
      await tester.pumpAndSettle();
      final tile = tester.widget<SwitchListTile>(
        find.widgetWithText(SwitchListTile, 'Forward X11'),
      );
      expect(tile.onChanged, isNull);
      expect(tile.value, isFalse);
      expect(find.textContaining('no X server'), findsOneWidget);
      expect(find.textContaining('this host\'s own key'), findsOneWidget,
          reason: 'with no OS agent, that is what forwarding offers');
    });

    testWidgets('on Windows, the X11 row names an X server to run',
        variant: TargetPlatformVariant.only(TargetPlatform.windows),
        (tester) async {
      await pumpForm(tester, noKeyringStore());
      await tester.tap(find.text('Advanced'));
      await tester.pumpAndSettle();
      expect(find.textContaining('VcXsrv'), findsOneWidget);
      expect(find.textContaining('computer\'s SSH agent'), findsOneWidget);
    });
  });
}

/// A file picker that hands back whatever the test put in [next].
class _PickingStorage implements DeviceStorage {
  PickedTextFile? next;
  int? maxBytes;

  @override
  Future<PickedTextFile?> pickTextFile({
    int maxBytes = kDefaultPickedTextFileMaxBytes,
  }) async {
    this.maxBytes = maxBytes;
    return next;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
