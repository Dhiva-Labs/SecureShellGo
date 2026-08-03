import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/screens/host_edit_screen.dart';
import 'package:secure_shell_go/services/composite_secure_storage.dart';
import 'package:secure_shell_go/services/credential_store.dart';
import 'package:secure_shell_go/services/device_vault_key.dart';
import 'package:secure_shell_go/services/host_store.dart';
import 'package:secure_shell_go/services/known_hosts_service.dart';
import 'package:secure_shell_go/services/secret_vault.dart';
import 'package:secure_shell_go/services/session_manager.dart';
import 'package:secure_shell_go/services/settings_store.dart';
import 'package:secure_shell_go/services/ssh_service.dart';
import 'package:secure_shell_go/widgets/error_banner.dart';

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
    if (await dir.exists()) await dir.delete(recursive: true);
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

  /// Lets work that is waiting on the real filesystem finish.
  ///
  /// `testWidgets` runs on a fake clock, so an `await` on a file read
  /// completes only once the real event loop has turned *and* the test's own
  /// microtask queue has been flushed. Neither alone is enough, which is why
  /// this alternates rather than simply waiting.
  Future<void> settleIo(WidgetTester tester, {int rounds = 60}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
  }

  /// Pushes the form onto a route, rather than making it the whole app: the
  /// screen pops itself when it is done, and a navigator with nothing left
  /// under it never settles.
  Future<void> pumpForm(
    WidgetTester tester,
    CredentialStore credentials, {
    Host? host,
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
          ),
        ),
      ),
    );
    // The screen loads its group list, its jump-host candidates and (when
    // editing) the saved credential off disk in initState, and shows a
    // spinner meanwhile — so the disk has to be let go of before anything
    // can settle.
    await tester.pump();
    await settleIo(tester);
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
    await settleIo(tester);
    if (checks != null) await tester.runAsync(checks);
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
}
