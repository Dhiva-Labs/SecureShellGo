import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/models/snippet.dart';
import 'package:secure_shell_go/screens/fleet_run_screen.dart';
import 'package:secure_shell_go/services/credential_store.dart';
import 'package:secure_shell_go/services/fleet_exec_service.dart';
import 'package:secure_shell_go/services/known_hosts_service.dart';
import 'package:secure_shell_go/services/session_manager.dart';
import 'package:secure_shell_go/services/snippet_store.dart';
import 'package:secure_shell_go/services/ssh_service.dart';
import 'package:secure_shell_go/theme.dart';

import 'fake_exec_session.dart';

class _MemoryBackend implements SecureStorageBackend {
  final Map<String, String> data = {};
  @override
  Future<void> write(String key, String value) async => data[key] = value;
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> delete(String key) async => data.remove(key);
}

Host _host(String id, String label, {String? group}) => Host(
      id: id,
      label: label,
      hostname: '$id.example.test',
      port: 22,
      username: 'ops',
      authMethod: SshAuthMethod.password,
      group: group,
    );

final _hosts = [
  _host('web1', 'Web 1', group: 'Production'),
  _host('web2', 'Web 2', group: 'Production'),
  _host('stage', 'Staging', group: 'Staging'),
  _host('pi', 'Raspberry Pi'),
];

/// Stands in for every connection: what each host's command prints and how
/// it exits.
class _Servers {
  final Map<String, (String, String, int)> script = {
    'web1': ('up 3 days\n', '', 0),
    'web2': ('', 'disk full\n', 2),
    'stage': ('up 1 hour\n', '', 0),
    'pi': ('up 9 days\n', '', 0),
  };
  final Map<String, FakeExecTransport> transports = {};
  final List<String> dialled = [];

  Future<SessionTransport> dial(Host host, SshCredentials creds) async {
    dialled.add(host.id);
    return transports.putIfAbsent(
      host.id,
      () => FakeExecTransport(
        host: host,
        respond: (_) {
          final (out, err, code) = script[host.id]!;
          return FakeExecSession(stdout: out, stderrText: err, exitCode: code);
        },
      ),
    );
  }
}

/// An [SshService] whose sign-ins go however the test says — including the
/// questions a real one would have put to a person.
class _ScriptedSsh extends SshService {
  _ScriptedSsh(File knownHosts)
      : super(knownHosts: KnownHostsService(file: knownHosts));

  final Map<String, Future<SshConnection> Function(
    HostKeyVerifier verify,
    LoginPromptHandler? ask,
  )> behaviour = {};

  @override
  Future<SshConnection> connect({
    required Host host,
    required SshCredentials credentials,
    required HostKeyVerifier verifyHostKey,
    LoginPromptHandler? answerPrompts,
    ServerBannerHandler? onBanner,
    Duration timeout = SshService.defaultTimeout,
    bool agentForwarding = false,
  }) =>
      behaviour[host.id]!(verifyHostKey, answerPrompts);
}

void main() {
  late Directory temp;
  late CredentialStore credentials;
  late SessionManager sessions;
  late _Servers servers;
  late SnippetStore snippets;
  String? clipboard;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('fleet_run');
    credentials = CredentialStore(backend: _MemoryBackend());
    for (final host in _hosts) {
      await credentials.save(host.id, const SshCredentials(password: 'pw'));
    }
    sessions = SessionManager();
    servers = _Servers();
    clipboard = null;
    // Here, not in the test: a store made on the test's fake clock chains
    // its writes on it.
    snippets = SnippetStore(file: File('${temp.path}/snippets.json'));
    await snippets.add(const Snippet(
      id: 's1',
      name: 'Disk use',
      command: 'du -sh {path}',
    ));
  });

  tearDown(() async {
    await sessions.dispose();
    await temp.delete(recursive: true);
  });

  Future<void> pump(
    WidgetTester tester, {
    Set<String> selected = const {'web1', 'web2'},
    SshService? ssh,
    bool useDialer = true,
    SnippetStore? snippets,
  }) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark,
      home: FleetRunScreen(
        hosts: _hosts,
        initialHostIds: selected,
        sessions: sessions,
        credentialStore: credentials,
        sshService: ssh ?? _ScriptedSsh(File('${temp.path}/kh.json')),
        snippetStore: snippets,
        dialer: useDialer ? servers.dial : null,
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// The Next button, scrolled into view: it sits under the host list.
  Future<Finder> next(WidgetTester tester) async {
    final button = find.widgetWithText(FilledButton, 'Next');
    await tester.scrollUntilVisible(button, 200,
        scrollable: find.byType(Scrollable).first);
    await tester.pump();
    return button;
  }

  Future<void> typeAndConfirm(WidgetTester tester, String command) async {
    await tester.enterText(find.byKey(const ValueKey('fleetCommand')), command);
    await tester.pump();
    await tester.tap(await next(tester));
    await tester.pumpAndSettle();
  }

  testWidgets('a group\'s row ticks the whole group', (tester) async {
    await pump(tester, selected: const {});
    expect(find.text('Hosts · 0 chosen'), findsOneWidget);
    await tester.tap(find.text('Production · 2'));
    await tester.pump();
    expect(find.text('Hosts · 2 chosen'), findsOneWidget);
    await tester.tap(find.text('Production · 2'));
    await tester.pump();
    expect(find.text('Hosts · 0 chosen'), findsOneWidget);
  });

  testWidgets('Next needs a command and a host', (tester) async {
    await pump(tester);
    bool enabled(Finder button) =>
        tester.widget<FilledButton>(button).onPressed != null;
    expect(enabled(await next(tester)), isFalse);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 2000));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('fleetCommand')), 'uptime');
    await tester.pump();
    expect(enabled(await next(tester)), isTrue);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 2000));
    await tester.pumpAndSettle();
    await tester.tap(find.text('All'));
    await tester.pump();
    expect(find.text('Hosts · 4 chosen'), findsOneWidget);
    await tester.tap(find.text('None'));
    await tester.pump();
    expect(enabled(await next(tester)), isFalse);
  });

  testWidgets('every host is listed before anything runs', (tester) async {
    await pump(tester, selected: const {'web1', 'web2', 'pi'});
    await typeAndConfirm(tester, 'sudo systemctl restart nginx');
    expect(find.text('Run this on 3 hosts?'), findsOneWidget);
    expect(find.text('sudo systemctl restart nginx'), findsOneWidget);
    for (final label in ['Web 1', 'Web 2', 'Raspberry Pi']) {
      expect(find.textContaining(label), findsOneWidget, reason: label);
    }
    expect(find.textContaining('Staging'), findsNothing);
    expect(servers.dialled, isEmpty);

    await tester.tap(find.text('Back'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('fleetCommand')), findsOneWidget);
  });

  testWidgets('results: badges, output, copy, and a re-run of the failed',
      (tester) async {
    await pump(tester);
    await typeAndConfirm(tester, 'uptime');
    await tester.tap(find.text('Run on 2'));
    await settle(tester);

    expect(find.text('Finished'), findsOneWidget);
    expect(find.text('1 succeeded · 1 failed'), findsOneWidget);
    expect(find.text('exit 0'), findsOneWidget);
    expect(find.text('exit 2'), findsOneWidget);
    expect(
      servers.transports['web1']!.commands.single,
      FleetExecService.wrap('uptime'),
    );

    await tester.tap(find.text('Web 2'));
    await tester.pumpAndSettle();
    expect(find.textContaining('disk full'), findsOneWidget);

    await tester.tap(find.byTooltip('Copy all output'));
    await tester.pumpAndSettle();
    expect(clipboard, contains('== Web 1 (exit 0) =='));
    expect(clipboard, contains('up 3 days'));
    expect(clipboard, contains('== Web 2 (exit 2) =='));

    servers.script['web2'] = ('fixed\n', '', 0);
    await tester.tap(find.text('Re-run 1 failed'));
    await tester.pumpAndSettle();
    expect(find.text('Run again on 1 host?'), findsOneWidget);
    expect(find.text('•  Web 2'), findsOneWidget);
    await tester.tap(find.text('Run again'));
    await settle(tester);
    expect(find.text('2 succeeded'), findsOneWidget);
    expect(servers.transports['web2']!.commands, hasLength(2));
    expect(servers.transports['web1']!.commands, hasLength(1));
  });

  testWidgets('sign-ins that need a person are skipped, and say why',
      (tester) async {
    final ssh = _ScriptedSsh(File('${temp.path}/kh.json'));
    ssh.behaviour['web1'] = (verify, ask) async {
      await verify(const HostKeyPrompt(
        kind: HostKeyPromptKind.unknown,
        hostname: 'web1.example.test',
        port: 22,
        keyType: 'ssh-ed25519',
        fingerprint: 'SHA256:x',
      ));
      throw const HostKeyRejectedException('not trusted');
    };
    ssh.behaviour['web2'] = (verify, ask) async {
      expect(ask, isNotNull, reason: 'the dial listens for questions');
      final answer = await ask!(LoginPrompt(
        host: _hosts[1],
        challenge: const LoginChallenge(fields: [
          LoginPromptField(text: 'Verification code: ', echo: false),
        ]),
        withdrawn: Completer<void>().future,
      ));
      expect(answer, isNull, reason: 'nobody answers');
      throw const SshAuthenticationException('declined');
    };
    ssh.behaviour['stage'] = (verify, ask) async {
      await verify(const HostKeyPrompt(
        kind: HostKeyPromptKind.changed,
        hostname: 'stage.example.test',
        port: 22,
        keyType: 'ssh-ed25519',
        fingerprint: 'SHA256:y',
      ));
      throw const HostKeyRejectedException('changed');
    };
    await credentials.save('pi', const SshCredentials(password: ''));

    await pump(
      tester,
      ssh: ssh,
      useDialer: false,
      selected: const {'web1', 'web2', 'stage', 'pi'},
    );
    await typeAndConfirm(tester, 'uptime');
    await tester.tap(find.text('Run on 4'));
    await settle(tester);

    expect(find.text('1 could not run · 3 skipped'), findsOneWidget);
    expect(find.text('skipped'), findsNWidgets(3));
    expect(find.text('error'), findsOneWidget);
    expect(find.textContaining('has not been checked yet'), findsOneWidget);
    expect(find.textContaining('No saved password'), findsOneWidget);
    expect(find.text('Finished'), findsOneWidget);

    await tester.tap(find.text('Web 2'));
    await tester.pumpAndSettle();
    expect(find.textContaining('asks "Verification code" at login'), findsOneWidget);
    await tester.tap(find.text('Staging'));
    await tester.pumpAndSettle();
    expect(find.textContaining('has CHANGED'), findsOneWidget);
  });

  testWidgets('a snippet fills the command, asking for its blanks',
      (tester) async {
    await pump(tester, snippets: snippets);
    await tester.tap(find.text('From a snippet…'));
    await settle(tester);
    await tester.tap(find.text('Disk use'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '/var/log');
    await tester.tap(find.text('Use'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('fleetCommand')))
          .controller!
          .text,
      'du -sh /var/log',
    );
  });

  testWidgets('leaving while it runs asks what to do', (tester) async {
    // A host that never answers, so the run is still going.
    final hung = Completer<SessionTransport>();
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark,
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => FleetRunScreen(
                hosts: _hosts,
                initialHostIds: const {'web1'},
                sessions: sessions,
                credentialStore: credentials,
                sshService: _ScriptedSsh(File('${temp.path}/kh.json')),
                dialer: (_, _) => hung.future,
                initialCommand: 'sleep 100',
              ),
            )),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(await next(tester));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Run on 1'));
    await settle(tester);
    expect(find.text('Running… 0 of 1'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Still running'), findsOneWidget);
    await tester.tap(find.text('Keep watching'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Running… 0 of 1'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Stop and leave'));
    await tester.pump(const Duration(milliseconds: 500));
    await settle(tester);
    expect(find.text('open'), findsOneWidget);
  });
}
