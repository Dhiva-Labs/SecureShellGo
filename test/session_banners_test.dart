import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/services/device_storage.dart';
import 'package:secure_shell_go/services/session_controller.dart';
import 'package:secure_shell_go/services/session_foreground.dart';
import 'package:secure_shell_go/services/session_manager.dart';
import 'package:secure_shell_go/services/ssh_service.dart';
import 'package:secure_shell_go/widgets/session_banners.dart';

import 'support/link_transport.dart';

class SilentForeground implements SessionForegroundChannel {
  @override
  Future<void> start(String label) async {}

  @override
  Future<void> stop() async {}
}

class UnusedStorage implements DeviceStorage {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('storage is not exercised in these tests');
}

void main() {
  late Dialer dialer;
  late ManualScheduler reconnects;
  var closedTabs = 0;

  ({SessionManager manager, ManagedSession entry, LinkTransport transport})
      open({bool reconnect = true}) {
    final manager = SessionManager(
      foreground: SessionForegroundController(channel: SilentForeground()),
      createController: (connection, resolve, resolveCreds) =>
          SessionController(
        connection: connection,
        storage: UnusedStorage(),
        keepaliveScheduler: (_, tick) => CrankTimer(tick),
        reconnect: reconnect
            ? ReconnectSupport(
                loadCredentials: (_) async => const SshCredentials(),
                connect: dialer.connect,
              )
            : null,
        reconnectScheduler: reconnects.schedule,
      ),
    );
    addTearDown(manager.dispose);
    final transport = LinkTransport();
    final entry = manager.open(transport);
    entry.controller.terminal.resize(100, 30);
    return (manager: manager, entry: entry, transport: transport);
  }

  Future<void> show(WidgetTester tester, ManagedSession entry) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StreamBuilder<void>(
            stream: entry.controller.changes,
            builder: (context, _) => SessionBanners(
              session: entry,
              onCloseTab: () => closedTabs++,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
  }

  /// Waits for [work], pumping: under the widget tester's clock, async work
  /// that hops more than once only moves when the test pumps.
  Future<void> drive(WidgetTester tester, Future<void> work) async {
    var done = false;
    unawaited(work.whenComplete(() => done = true));
    for (var i = 0; i < 50 && !done; i++) {
      await tester.pump();
    }
    expect(done, isTrue, reason: 'the work never finished');
  }

  setUp(() {
    dialer = Dialer(LinkTransport(name: 'second'));
    reconnects = ManualScheduler();
    closedTabs = 0;
  });

  testWidgets('a healthy session shows nothing', (tester) async {
    final session = open();
    await show(tester, session.entry);
    await settle(tester);

    expect(find.byType(TextButton), findsNothing);
  });

  testWidgets('a stopped reconnect offers Reconnect, and it reconnects',
      (tester) async {
    final session = open();
    await show(tester, session.entry);
    session.transport.drop(const SocketException('Connection reset'));
    await settle(tester);
    expect(find.text('Stop'), findsOneWidget);

    await tester.tap(find.text('Stop'));
    await settle(tester);
    expect(find.text('Reconnect'), findsOneWidget);
    expect(find.text('Close'), findsOneWidget);

    await tester.tap(find.text('Reconnect'));
    await settle(tester);

    expect(dialer.calls, 1);
    expect(session.entry.isClosed, isFalse);
    expect(find.text('Reconnect'), findsNothing);
  });

  testWidgets('a reconnect that gave up says why, and still offers Reconnect',
      (tester) async {
    final session = open();
    dialer.next =
        const SshAuthenticationException('Authentication failed for "dev".');
    await show(tester, session.entry);
    session.transport.drop(const SocketException('Connection reset'));
    await settle(tester);
    reconnects.fireNow();
    await settle(tester);

    expect(find.textContaining('Authentication failed'), findsOneWidget);
    expect(find.text('Reconnect'), findsOneWidget);
  });

  testWidgets('no Reconnect without the means to reconnect', (tester) async {
    final session = open(reconnect: false);
    await show(tester, session.entry);
    session.transport.drop(const SocketException('Connection reset'));
    await settle(tester);

    expect(find.text('Reconnect'), findsNothing);
    await tester.tap(find.text('Close'));
    expect(closedTabs, 1);
  });

  testWidgets('a shell that ends offers Restart, which opens a new one',
      (tester) async {
    final session = open();
    await show(tester, session.entry);
    await drive(tester, session.entry.controller.ensureShell());
    await settle(tester);

    session.transport.shells.single.exit();
    await settle(tester);

    expect(find.text('Shell ended — Shell exited with status 0.'),
        findsOneWidget);
    expect(find.text('Restart'), findsOneWidget);

    await tester.tap(find.text('Restart'));
    await settle(tester);

    expect(session.transport.shells, hasLength(2));
    expect(find.text('Restart'), findsNothing);
    expect(session.entry.isClosed, isFalse);
  });

  testWidgets('the banners fit a narrow phone', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final session = open();
    await show(tester, session.entry);
    session.transport.drop(const SocketException('Connection reset'));
    await settle(tester);
    await tester.tap(find.text('Stop'));
    await settle(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('Reconnect'), findsOneWidget);
  });
}
