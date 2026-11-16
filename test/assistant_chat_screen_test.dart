import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/models/host_ai_access.dart';
import 'package:secure_shell_go/screens/assistant_chat_screen.dart';
import 'package:secure_shell_go/screens/host_list_screen.dart';
import 'package:secure_shell_go/services/assistant/assistant_conversation.dart';
import 'package:secure_shell_go/services/credential_store.dart';
import 'package:secure_shell_go/services/host_store.dart';
import 'package:secure_shell_go/services/known_hosts_service.dart';
import 'package:secure_shell_go/services/session_manager.dart';
import 'package:secure_shell_go/services/settings_store.dart';
import 'package:secure_shell_go/services/ssh_service.dart';

import 'support/assistant_fakes.dart';

const _shared = Host(
  id: 'h1',
  label: 'Build box',
  hostname: 'build.example.org',
  port: 22,
  username: 'ci',
  authMethod: SshAuthMethod.password,
  aiAccess: HostAiAccess.readOnly,
);

class _MemoryBackend implements SecureStorageBackend {
  final Map<String, String> data = {};
  @override
  Future<void> write(String key, String value) async => data[key] = value;
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> delete(String key) async => data.remove(key);
}

void main() {
  late FakeAssistantService service;

  setUp(() => service = FakeAssistantService());

  Future<FakeConversation> pump(
    WidgetTester tester, {
    Size size = const Size(800, 900),
    FakeHostList? hosts,
    Future<void> Function()? onOpenSharedHosts,
    VoidCallback? onOpenSettings,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: AssistantChatScreen(
          service: service,
          hostStore: hosts ?? FakeHostList([_shared]),
          onOpenSettings: onOpenSettings,
          onOpenSharedHosts: onOpenSharedHosts,
        ),
      ),
    );
    await tester.pumpAndSettle();
    // Starting a chat is async; let it finish.
    for (var i = 0; i < 3; i++) {
      await tester.pump();
    }
    if (service.enabled && service.problem == null) {
      expect(service.created, isNotEmpty);
    }
    return service.created.isEmpty ? FakeConversation() : service.created.last;
  }

  testWidgets('empty chat says what it can do and where it reaches', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('Ask about your servers'), findsWidgets);
    expect(find.textContaining('only reaches servers you shared'),
        findsOneWidget);
    expect(find.text('Send'), findsOneWidget);
    // Servers are shared, so no hint.
    expect(find.text('Shared hosts'), findsNothing);
  });

  testWidgets('sending shows the message; running shows Stop, and Stop stops', (
    tester,
  ) async {
    final conversation = await pump(tester);
    await tester.enterText(find.byType(TextField), 'check disk space');
    await tester.tap(find.text('Send'));
    await tester.pump();
    expect(conversation.sent, ['check disk space']);
    expect(find.text('check disk space'), findsOneWidget);
    expect(find.text('Stop'), findsOneWidget);
    expect(find.text('Send'), findsNothing);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );

    await tester.tap(find.text('Stop'));
    await tester.pump();
    expect(conversation.stops, 1);

    conversation.show([
      const AssistantUserItem(1, 'check disk space'),
      const AssistantReplyItem(2, 'Plenty free.'),
    ]);
    await tester.pump();
    expect(find.text('Plenty free.'), findsOneWidget);
    expect(find.text('Send'), findsOneWidget);
  });

  testWidgets('a tool row expands to its result and marks a waiting card', (
    tester,
  ) async {
    final conversation = await pump(tester);
    conversation.show([
      const AssistantToolItem(
        id: 1,
        name: 'run_command',
        host: 'Build box',
        status: AssistantToolStatus.running,
        awaitingApproval: true,
        summary: 'df -h',
      ),
      const AssistantToolItem(
        id: 2,
        name: 'read_file',
        host: 'Build box',
        status: AssistantToolStatus.done,
        summary: 'first line',
        detail: 'line one\nname\u202Egnp.txt\nline three',
      ),
      const AssistantToolItem(
        id: 3,
        name: 'tail_log',
        host: 'Build box',
        status: AssistantToolStatus.failed,
        summary: 'no such file',
      ),
    ], running: true);
    await tester.pump();

    expect(find.text('run_command on Build box'), findsOneWidget);
    expect(find.text('Waiting for your yes'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.textContaining('line three'), findsNothing);

    await tester.tap(find.text('read_file on Build box'));
    await tester.pump();
    final detail = find.byWidgetPredicate(
      (w) =>
          w is SelectableText &&
          (w.textSpan?.toPlainText().contains('line three') ?? false),
    );
    expect(detail, findsOneWidget);
    final shown = tester.widget<SelectableText>(detail).textSpan!.toPlainText();
    expect(shown.contains('\u202E'), isFalse, reason: 'bidi control is shown');
    expect(shown, contains('[U+202E]'));
    expect(
      find.descendant(
        of: find.byType(SingleChildScrollView),
        matching: detail,
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('read_file on Build box'));
    await tester.pump();
    expect(detail, findsNothing);
  });

  testWidgets('an error notice is drawn in the error colour', (tester) async {
    final conversation = await pump(tester);
    conversation.show([
      const AssistantNoticeItem(1, 'The service did not accept the key.',
          isError: true),
      const AssistantNoticeItem(2, 'Stopped.'),
    ]);
    await tester.pump();
    final theme = Theme.of(tester.element(find.byType(Scaffold)));
    final error = tester.widget<Text>(
      find.text('The service did not accept the key.'),
    );
    expect(error.style?.color, theme.colorScheme.error);
    final plain = tester.widget<Text>(find.text('Stopped.'));
    expect(plain.style?.color, isNot(theme.colorScheme.error));
  });

  testWidgets('assistant text is plain: no links, controls shown', (
    tester,
  ) async {
    final conversation = await pump(tester);
    conversation.show([
      const AssistantReplyItem(1, 'See **bold** https://example.com\x1b[2J'),
    ]);
    await tester.pump();
    final reply = tester.widget<SelectableText>(find.byType(SelectableText));
    final text = reply.textSpan!.toPlainText();
    expect(text, contains('**bold** https://example.com'));
    expect(text, contains(r'\x1b'));
    expect(text.contains('\x1b'), isFalse);
    var tappable = false;
    reply.textSpan!.visitChildren((s) {
      if (s is TextSpan && s.recognizer != null) tappable = true;
      return true;
    });
    expect(tappable, isFalse);
  });

  testWidgets('New chat ends this conversation and starts another', (
    tester,
  ) async {
    final first = await pump(tester);
    first.show([const AssistantUserItem(1, 'hello')]);
    await tester.pump();
    expect(find.text('hello'), findsOneWidget);
    await tester.tap(find.byTooltip('New chat'));
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
    expect(first.disposed, isTrue);
    expect(service.created, hasLength(2));
    expect(find.text('hello'), findsNothing);
  });

  testWidgets('leaving the screen ends the conversation', (tester) async {
    final conversation = await pump(tester);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    expect(conversation.disposed, isTrue);
  });

  testWidgets('off: shows the problem and a way to settings, no composer', (
    tester,
  ) async {
    service.enabled = false;
    var opened = 0;
    await pump(tester, onOpenSettings: () => opened++);
    expect(find.textContaining('switched off'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(service.created, isEmpty);
    await tester.tap(find.text('Open settings'));
    expect(opened, 1);
  });

  testWidgets('not configured: shows the service problem, no composer', (
    tester,
  ) async {
    service.problem = 'Enter the model name in the assistant settings.';
    await pump(tester, onOpenSettings: () {});
    expect(find.text('Enter the model name in the assistant settings.'),
        findsOneWidget);
    expect(find.byType(TextField), findsNothing);

    // Once fixed, the chat appears without leaving the screen.
    service.problem = null;
    service.changed();
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    expect(service.created, hasLength(1));
  });

  testWidgets('no shared server: hint with a button to Shared hosts', (
    tester,
  ) async {
    final hosts = FakeHostList([
      const Host(
        id: 'h2',
        label: 'Closed',
        hostname: 'x',
        port: 22,
        username: 'u',
        authMethod: SshAuthMethod.password,
      ),
    ]);
    var opened = 0;
    await pump(
      tester,
      hosts: hosts,
      onOpenSharedHosts: () async {
        opened++;
        hosts.hosts = [_shared];
      },
    );
    expect(find.textContaining('No server has AI access yet'), findsOneWidget);
    await tester.tap(find.text('Shared hosts'));
    await tester.pumpAndSettle();
    expect(opened, 1);
    expect(find.textContaining('No server has AI access yet'), findsNothing,
        reason: 'looked again after coming back');
  });

  testWidgets('follows the newest item unless scrolled up', (tester) async {
    final conversation = await pump(tester, size: const Size(360, 740));
    List<AssistantTranscriptItem> many(int n) => [
      for (var i = 1; i <= n; i++) AssistantReplyItem(i, 'line $i\n\n\n'),
    ];
    conversation.show(many(30));
    await tester.pump();
    await tester.pump();
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first);
    expect(scroll.position.extentAfter, 0);

    scroll.position.jumpTo(0);
    await tester.pump();
    conversation.show(many(31));
    await tester.pump();
    await tester.pump();
    expect(scroll.position.pixels, 0, reason: 'user scrolled up: stay put');
  });

  for (final size in [const Size(360, 740), const Size(1400, 900)]) {
    testWidgets('no overflow at ${size.width.toInt()}x${size.height.toInt()}', (
      tester,
    ) async {
      final conversation = await pump(tester, size: size);
      // One expanded tool row on its own, then the whole mix.
      conversation.show([
        AssistantToolItem(
          id: 2,
          name: 'run_command_with_a_long_name',
          host: 'a-host-with-a-rather-long-name.example.org',
          status: AssistantToolStatus.running,
          awaitingApproval: true,
          summary: 'x' * 400,
          detail: 'y' * 400,
        ),
      ]);
      await tester.pump();
      await tester.tap(find.textContaining('run_command_with_a_long_name'));
      await tester.pump();
      expect(find.textContaining('y' * 50), findsOneWidget);
      conversation.show([
        AssistantUserItem(1, 'a very long question ' * 12),
        AssistantToolItem(
          id: 2,
          name: 'run_command_with_a_long_name',
          host: 'a-host-with-a-rather-long-name.example.org',
          status: AssistantToolStatus.running,
          awaitingApproval: true,
          summary: 'x' * 400,
          detail: 'y' * 400,
        ),
        AssistantReplyItem(3, 'word ' * 200),
        AssistantNoticeItem(4, 'Something went wrong. ' * 8, isError: true),
      ], running: true);
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  }

  group('entry point', () {
    late Directory dir;
    late SettingsStore settings;
    late HostStore hosts;
    late KnownHostsService knownHosts;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('assistant_entry_test');
      settings = SettingsStore(
        file: File('${dir.path}/${SettingsStore.fileName}'),
      );
      hosts = HostStore(file: File('${dir.path}/${HostStore.fileName}'));
      knownHosts = KnownHostsService(
        file: File('${dir.path}/${KnownHostsService.fileName}'),
      );
    });

    tearDown(() async {
      settings.dispose();
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump();
      }
      await tester.pump(const Duration(milliseconds: 600));
    }

    testWidgets('the app bar shows it only while the assistant is on', (
      tester,
    ) async {
      await tester.runAsync(settings.ensureLoaded);
      final sessions = SessionManager();
      addTearDown(sessions.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: HostListScreen(
            hostStore: hosts,
            credentialStore: CredentialStore(backend: _MemoryBackend()),
            knownHosts: knownHosts,
            sshService: SshService(knownHosts: knownHosts),
            settingsStore: settings,
            sessions: sessions,
            assistant: service,
          ),
        ),
      );
      await settle(tester);
      expect(find.byTooltip('Assistant'), findsNothing);

      await tester.runAsync(
        () => settings.update((s) => s.copyWith(assistantEnabled: true)),
      );
      await settle(tester);
      expect(find.byTooltip('Assistant'), findsOneWidget);

      await tester.tap(find.byTooltip('Assistant'));
      await tester.pumpAndSettle();
      expect(find.byType(AssistantChatScreen), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => settings.update((s) => s.copyWith(assistantEnabled: false)),
      );
      await settle(tester);
      expect(find.byTooltip('Assistant'), findsNothing);
    });

    testWidgets('no assistant given: no entry', (tester) async {
      final sessions = SessionManager();
      addTearDown(sessions.dispose);
      await tester.runAsync(
        () => settings.update((s) => s.copyWith(assistantEnabled: true)),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: HostListScreen(
            hostStore: hosts,
            credentialStore: CredentialStore(backend: _MemoryBackend()),
            knownHosts: knownHosts,
            sshService: SshService(knownHosts: knownHosts),
            settingsStore: settings,
            sessions: sessions,
          ),
        ),
      );
      await settle(tester);
      expect(find.byTooltip('Assistant'), findsNothing);
    });
  });
}
