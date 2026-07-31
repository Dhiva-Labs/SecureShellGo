import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/screens/log_viewer_screen.dart';
import 'package:secure_shell_go/screens/server_stats_screen.dart';
import 'package:secure_shell_go/screens/services_screen.dart';
import 'package:secure_shell_go/services/server_probe.dart';
import 'package:secure_shell_go/services/session_controller.dart';
import 'package:secure_shell_go/services/settings_store.dart';
import 'package:secure_shell_go/services/systemd_units.dart';

import 'fake_exec_session.dart';

/// A complete Linux transcript, for the screens that just need one to render.
const _fullTranscript = '${ServerProbeCommands.marker}kernel\n'
    'Linux 6.8.0-40-generic\n'
    '${ServerProbeCommands.marker}host\nweb-01\n'
    '${ServerProbeCommands.marker}uptime\n24388.77 278894.06\n'
    '${ServerProbeCommands.marker}load\n0.42 0.31 0.28 1/100 200\n'
    '${ServerProbeCommands.marker}mem\n'
    'MemTotal:       1048576 kB\nMemAvailable:    524288 kB\n'
    '${ServerProbeCommands.marker}disk\n'
    'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
    '/dev/sda1 1000000 400000 600000 40% /\n'
    '${ServerProbeCommands.marker}cpu\n8\n';

/// A BSD-shaped transcript: no /proc and no `free`, so memory is genuinely
/// unavailable and everything else still reads.
const _noMemoryTranscript = '${ServerProbeCommands.marker}kernel\n'
    'Darwin 23.4.0\n'
    '${ServerProbeCommands.marker}uptime\n'
    '14:23  up 10 days,  3:14, 2 users, load averages: 1.20 1.10 1.05\n'
    '${ServerProbeCommands.marker}load\n'
    '14:23  up 10 days,  3:14, 2 users, load averages: 1.20 1.10 1.05\n'
    '${ServerProbeCommands.marker}mem\n'
    '${ServerProbeCommands.marker}disk\n'
    '/dev/disk3s1s1 1000000 400000 600000 40% /\n'
    '${ServerProbeCommands.marker}cpu\n10\n';

SessionController _session(FakeExecTransport transport) {
  return SessionController(
    connection: transport,
    // The keep-alive is irrelevant here and a real periodic timer would
    // outlive the test; this one never fires and is never cancelled by
    // anything but dispose.
    keepaliveScheduler: (_, _) => _InertTimer(),
  );
}

void main() {
  group('ServerStatsScreen', () {
    testWidgets('renders every metric it could read', (tester) async {
      final transport = FakeExecTransport(stdout: _fullTranscript);
      final session = _session(transport);
      addTearDown(session.dispose);

      await tester.pumpWidget(
        MaterialApp(home: ServerStatsScreen(session: session)),
      );
      await tester.pump();

      expect(find.text('Linux 6.8.0-40-generic'), findsOneWidget);
      expect(find.text('web-01'), findsOneWidget);
      expect(find.text('8'), findsOneWidget);
      expect(find.text('0.42'), findsOneWidget);
      // 6h 46m out of 24388 s.
      expect(find.text('6h 46m'), findsOneWidget);

      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    });

    testWidgets('an unreadable metric says so without failing the panel',
        (tester) async {
      final transport = FakeExecTransport(stdout: _noMemoryTranscript);
      final session = _session(transport);
      addTearDown(session.dispose);

      await tester.pumpWidget(
        MaterialApp(home: ServerStatsScreen(session: session)),
      );
      await tester.pump();

      // The one thing this server cannot answer is named, and only that one.
      expect(find.text('Could not read memory on this server.'), findsOneWidget);
      // Everything else still came through.
      expect(find.text('Darwin 23.4.0'), findsOneWidget);
      expect(find.text('1.20'), findsOneWidget);
      expect(find.text('10'), findsOneWidget);

      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    });

    testWidgets('probes immediately on open rather than after an interval',
        (tester) async {
      final transport = FakeExecTransport(stdout: _fullTranscript);
      final session = _session(transport);
      addTearDown(session.dispose);

      await tester.pumpWidget(
        MaterialApp(home: ServerStatsScreen(session: session)),
      );
      await tester.pump();

      expect(transport.commands, hasLength(1));
      expect(transport.commands.single, ServerProbeCommands.probe);

      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    });

    testWidgets('polls on the interval while it is on screen', (tester) async {
      final transport = FakeExecTransport(stdout: _fullTranscript);
      final session = _session(transport);
      addTearDown(session.dispose);

      await tester.pumpWidget(
        MaterialApp(home: ServerStatsScreen(session: session)),
      );
      await tester.pump();
      expect(transport.commands, hasLength(1));

      await tester.pump(ServerStatsPoller.defaultInterval);
      await tester.pump();
      expect(transport.commands, hasLength(2));

      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    });

    testWidgets('leaving the screen stops the polling and leaks no timer',
        (tester) async {
      // The rule from the brief, at the level the user experiences it: a
      // server nobody is looking at is never contacted. If the poller's
      // timer survived the route, `pump`ing fake time forward would fire it
      // — and the test framework would also fail the test for a pending
      // timer, which is the leak check coming free.
      final transport = FakeExecTransport(stdout: _fullTranscript);
      final session = _session(transport);
      addTearDown(session.dispose);

      await tester.pumpWidget(
        MaterialApp(home: ServerStatsScreen(session: session)),
      );
      await tester.pump();
      final whileVisible = transport.commands.length;
      expect(whileVisible, greaterThan(0));

      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pump(const Duration(minutes: 2));

      expect(
        transport.commands,
        hasLength(whileVisible),
        reason: 'nothing may be probed after the view is gone',
      );
    });

    testWidgets('the manual refresh takes an extra reading', (tester) async {
      final transport = FakeExecTransport(stdout: _fullTranscript);
      final session = _session(transport);
      addTearDown(session.dispose);

      await tester.pumpWidget(
        MaterialApp(home: ServerStatsScreen(session: session)),
      );
      await tester.pump();
      expect(transport.commands, hasLength(1));

      await tester.tap(find.byTooltip('Refresh now'));
      await tester.pump();
      await tester.pump();

      expect(transport.commands, hasLength(2));

      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    });

    testWidgets('a server that answers nothing shows a whole-panel message',
        (tester) async {
      final transport = FakeExecTransport(stdout: '');
      final session = _session(transport);
      addTearDown(session.dispose);

      await tester.pumpWidget(
        MaterialApp(home: ServerStatsScreen(session: session)),
      );
      await tester.pump();

      expect(
        find.textContaining('did not answer any of the status commands'),
        findsOneWidget,
      );

      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    });
  });

  group('formatUptime', () {
    test('days and hours', () {
      expect(formatUptime(const Duration(days: 10, hours: 3)), '10d 3h');
    });
    test('days alone when the hours are zero', () {
      expect(formatUptime(const Duration(days: 2)), '2d');
    });
    test('hours and minutes', () {
      expect(formatUptime(const Duration(hours: 6, minutes: 46)), '6h 46m');
    });
    test('minutes alone', () {
      expect(formatUptime(const Duration(minutes: 45)), '45m');
    });
    test('a freshly booted server', () {
      expect(formatUptime(const Duration(seconds: 20)), 'less than a minute');
    });
    test('zero does not render as an empty string', () {
      expect(formatUptime(Duration.zero), isNotEmpty);
    });
  });

  group('LogViewerScreen', () {
    /// Builds the viewer over a transport whose tail channel is driven by
    /// [lines], so the test controls exactly when output arrives.
    Future<FakeExecSession> pumpViewer(
      WidgetTester tester,
      StreamController<String> lines, {
      required SessionController session,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: LogViewerScreen(
            session: session,
            path: '/var/log/app.log',
            settingsStore: SettingsStore(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      return _lastTailSession!;
    }

    testWidgets('streams lines into the scrollback', (tester) async {
      final lines = StreamController<String>();
      final session = _session(_tailTransport(lines));
      addTearDown(session.dispose);

      await pumpViewer(tester, lines, session: session);

      lines.add('INFO first line\nERROR second line\n');
      await tester.pump();
      await tester.pump();

      expect(find.text('INFO first line'), findsOneWidget);
      expect(find.text('ERROR second line'), findsOneWidget);

      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    });

    testWidgets('pause holds new lines back and counts them', (tester) async {
      final lines = StreamController<String>();
      final session = _session(_tailTransport(lines));
      addTearDown(session.dispose);

      await pumpViewer(tester, lines, session: session);

      lines.add('before\n');
      await tester.pump();
      await tester.pump();
      expect(find.text('before'), findsOneWidget);

      await tester.tap(find.byTooltip('Pause'));
      await tester.pump();

      lines.add('during one\nduring two\n');
      await tester.pump();
      await tester.pump();

      expect(find.text('during one'), findsNothing);
      expect(find.text('Paused — 2 new lines'), findsOneWidget);

      await tester.tap(find.byTooltip('Resume'));
      await tester.pump();
      await tester.pump();

      expect(find.text('during one'), findsOneWidget);
      expect(find.text('during two'), findsOneWidget);

      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    });

    testWidgets('the filter hides non-matching lines but keeps them',
        (tester) async {
      final lines = StreamController<String>();
      final session = _session(_tailTransport(lines));
      addTearDown(session.dispose);

      await pumpViewer(tester, lines, session: session);

      lines.add('INFO ok\nERROR broken\n');
      await tester.pump();
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'ERROR');
      await tester.pump();

      expect(find.text('ERROR broken'), findsOneWidget);
      expect(find.text('INFO ok'), findsNothing);

      // Clearing brings it straight back — the filter was a lens, not a
      // deletion.
      await tester.enterText(find.byType(TextField), '');
      await tester.pump();
      expect(find.text('INFO ok'), findsOneWidget);

      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    });

    testWidgets('leaving the viewer kills the remote tail', (tester) async {
      // The no-orphan guarantee, at the level the user causes it: pressing
      // back must close stdin (releasing the command's watchdog) and then
      // the channel.
      final lines = StreamController<String>();
      final session = _session(_tailTransport(lines));
      addTearDown(session.dispose);

      final tailSession = await pumpViewer(tester, lines, session: session);
      expect(tailSession.stdinClosed, isFalse);
      expect(tailSession.wasClosed, isFalse);

      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pump();

      expect(tailSession.stdinClosed, isTrue);
      expect(tailSession.wasClosed, isTrue);

    });

    testWidgets('an unreadable path fails with a sentence, not a blank pane',
        (tester) async {
      final transport = FakeExecTransport(exitCode: 1);
      final session = _session(transport);
      addTearDown(session.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: LogViewerScreen(
            session: session,
            path: '/etc/shadow',
            settingsStore: SettingsStore(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.textContaining('/etc/shadow'), findsWidgets);
      expect(
        transport.commands,
        hasLength(1),
        reason: 'tail is never started on a path we cannot read',
      );

      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    });
  });

  group('ServicesScreen', () {
    testWidgets('a server without systemd says so calmly', (tester) async {
      final transport = FakeExecTransport(exitCode: 1);
      final session = _session(transport);
      addTearDown(session.dispose);

      await tester.pumpWidget(
        MaterialApp(home: ServicesScreen(session: session)),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text(SystemdUnavailable.message), findsOneWidget);
      expect(
        transport.commands,
        [SystemdCommands.probe],
        reason: 'no init.d fallback is attempted',
      );

      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    });

    testWidgets('services are listed with their state', (tester) async {
      final transport = FakeExecTransport(
        respond: (command) => command == SystemdCommands.probe
            ? FakeExecSession(stdout: '')
            : FakeExecSession(
                stdout: 'nginx.service loaded active running Web server\n'
                    'cron.service loaded failed failed Scheduler\n',
              ),
      );
      final session = _session(transport);
      addTearDown(session.dispose);

      await tester.pumpWidget(
        MaterialApp(home: ServicesScreen(session: session)),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('nginx'), findsOneWidget);
      expect(find.text('cron'), findsOneWidget);
      expect(find.textContaining('active · running'), findsOneWidget);
      expect(find.textContaining('failed · failed'), findsOneWidget);

      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    });

    testWidgets('a service action is confirmed by name and can be cancelled',
        (tester) async {
      // Nothing may reach systemctl without the user having read the
      // service's name and the sudo warning.
      final transport = FakeExecTransport(
        respond: (command) => command == SystemdCommands.probe
            ? FakeExecSession(stdout: '')
            : FakeExecSession(
                stdout: 'nginx.service loaded active running Web server\n',
              ),
      );
      final session = _session(transport);
      addTearDown(session.dispose);

      await tester.pumpWidget(
        MaterialApp(home: ServicesScreen(session: session)),
      );
      await tester.pump();
      await tester.pump();

      final commandsBefore = transport.commands.length;

      await tester.tap(find.byTooltip('Actions for nginx'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Stop'));
      await tester.pumpAndSettle();

      expect(find.text('Stop nginx?'), findsOneWidget);
      expect(find.textContaining('may need sudo'), findsOneWidget);
      expect(find.textContaining('systemctl stop nginx.service'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(
        transport.commands,
        hasLength(commandsBefore),
        reason: 'a cancelled confirmation must send nothing',
      );

      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    });
  });
}

/// The tail channel handed out by the most recent [_tailTransport], so a test
/// can assert on the close that kills the remote process.
FakeExecSession? _lastTailSession;

/// A transport whose readable-probe succeeds and whose tail channel is fed
/// by [lines].
FakeExecTransport _tailTransport(StreamController<String> lines) {
  _lastTailSession = null;
  return FakeExecTransport(
    respond: (command) {
      if (command.startsWith('test -f')) return FakeExecSession(stdout: '');
      return _lastTailSession = FakeExecSession(stdoutStream: lines.stream);
    },
  );
}

/// A timer that never fires and never needs to — the keep-alive is not what
/// any of these tests are about, and a real one would outlive them.
class _InertTimer implements Timer {
  var _active = true;

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;
}
