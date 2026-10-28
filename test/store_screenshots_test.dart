// Store screenshots: the real screens, filled with demo content, rendered at
// the sizes Google Play and the Microsoft Store ask for, with the real Roboto,
// Material Icons and JetBrains Mono fonts.
//
//   STORE_SHOTS=store/graphics/screenshots/1.5 \
//     flutter test test/store_screenshots_test.dart
//   STORE_SHOTS=build/store-shots/de STORE_LOCALE=de \
//     flutter test test/store_screenshots_test.dart
//
// Writes phone/ (1080×1920), tablet7/ (1200×1920), tablet10/ (1600×2560) and
// windows/ (1920×1080) under STORE_SHOTS, as 24-bit PNGs without an alpha
// channel, which is what Play accepts. Every host, path and process in them
// is made up: example.com names, a fictional "inventory-api" project.
//
// Opt-in — skipped in a plain `flutter test`, like the layout sweep.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/l10n/l10n.dart';
import 'package:secure_shell_go/models/app_settings.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/models/remote_entry.dart';
import 'package:secure_shell_go/screens/fleet_run_screen.dart';
import 'package:secure_shell_go/screens/host_edit_screen.dart';
import 'package:secure_shell_go/screens/host_list_screen.dart';
import 'package:secure_shell_go/screens/remote_editor_screen.dart';
import 'package:secure_shell_go/screens/session_screen.dart';
import 'package:secure_shell_go/screens/settings_screen.dart';
import 'package:secure_shell_go/screens/terminal_pane.dart';
import 'package:secure_shell_go/services/credential_store.dart';
import 'package:secure_shell_go/services/device_storage.dart';
import 'package:secure_shell_go/services/host_store.dart';
import 'package:secure_shell_go/services/input_profile.dart';
import 'package:secure_shell_go/services/keep_awake.dart';
import 'package:secure_shell_go/services/known_hosts_service.dart';
import 'package:secure_shell_go/services/session_controller.dart';
import 'package:secure_shell_go/services/session_foreground.dart';
import 'package:secure_shell_go/services/session_manager.dart';
import 'package:secure_shell_go/services/settings_store.dart';
import 'package:secure_shell_go/services/sftp_service.dart';
import 'package:secure_shell_go/services/ssh_service.dart';
import 'package:secure_shell_go/services/terminal_workspace.dart';
import 'package:secure_shell_go/theme.dart';
import 'package:secure_shell_go/widgets/host_advanced_section.dart';
import 'package:secure_shell_go/widgets/terminal_find_bar.dart';
import 'package:secure_shell_go/widgets/terminal_fonts.dart';

import 'fake_exec_session.dart';
import 'support/fake_transport.dart';

final String? _outDir = Platform.environment['STORE_SHOTS'];
final Locale _locale = Locale(Platform.environment['STORE_LOCALE'] ?? 'en');

// ------------------------------------------------------------- the sets

enum _Shot {
  hosts,
  terminal,
  files,
  editor,
  find,
  advanced,
  fleet,
  settings,
  sideBySide,
  workspace,
}

typedef _Set = ({
  String folder,
  Size size,
  double dpr,
  bool mouse,
  List<(String file, _Shot shot, Brightness brightness)> shots,
});

const _dark = Brightness.dark;
const _light = Brightness.light;

/// Logical size × device pixel ratio is the store's pixel size exactly.
const List<_Set> _sets = [
  // Google Play phone: 9:16, 1080×1920.
  (
    folder: 'phone',
    size: Size(432, 768),
    dpr: 2.5,
    mouse: false,
    shots: [
      ('01-hosts', _Shot.hosts, _dark),
      ('02-terminal', _Shot.terminal, _dark),
      ('03-files', _Shot.files, _dark),
      ('04-editor', _Shot.editor, _dark),
      ('05-find', _Shot.find, _dark),
      ('06-mosh', _Shot.advanced, _dark),
      ('07-fleet', _Shot.fleet, _dark),
      ('08-settings', _Shot.settings, _light),
    ],
  ),
  // Google Play 7-inch tablet: 1200×1920.
  (
    folder: 'tablet7',
    size: Size(750, 1200),
    dpr: 1.6,
    mouse: false,
    shots: [
      ('01-session', _Shot.sideBySide, _dark),
      ('02-hosts', _Shot.hosts, _light),
      ('03-editor', _Shot.editor, _dark),
      ('04-fleet', _Shot.fleet, _dark),
    ],
  ),
  // Google Play 10-inch tablet: 1600×2560.
  (
    folder: 'tablet10',
    size: Size(800, 1280),
    dpr: 2,
    mouse: false,
    shots: [
      ('01-session', _Shot.sideBySide, _dark),
      ('02-hosts', _Shot.hosts, _light),
      ('03-editor', _Shot.editor, _dark),
      ('04-find', _Shot.find, _dark),
    ],
  ),
  // Microsoft Store: 16:9, 1920×1080, at Windows' 125% scale.
  (
    folder: 'windows',
    size: Size(1536, 864),
    dpr: 1.25,
    mouse: true,
    shots: [
      ('01-split-panes', _Shot.workspace, _dark),
      ('02-terminal-and-files', _Shot.sideBySide, _dark),
      ('03-hosts', _Shot.hosts, _light),
      ('04-editor', _Shot.editor, _dark),
      ('05-fleet', _Shot.fleet, _dark),
      ('06-advanced', _Shot.advanced, _dark),
    ],
  ),
];

// ------------------------------------------------------------ demo hosts

Host _host(
  String id,
  String label,
  String hostname,
  String user, {
  String? group,
  HostColorLabel? color,
  int port = 22,
  int? hoursAgo,
  HostTransport transport = HostTransport.ssh,
  PersistentSession persistent = PersistentSession.off,
  bool agent = false,
}) =>
    Host(
      id: id,
      label: label,
      hostname: hostname,
      port: port,
      username: user,
      authMethod: SshAuthMethod.privateKey,
      group: group,
      colorLabel: color,
      transport: transport,
      persistentSession: persistent,
      agentForwarding: agent,
      lastConnectedAt: hoursAgo == null
          ? null
          : DateTime(2026, 10, 22, 9, 30).subtract(Duration(hours: hoursAgo)),
    );

final List<Host> _hosts = [
  _host('web1', 'Web frontend 1', 'web-01.example.com', 'deploy',
      group: 'Production', color: HostColorLabel.red, hoursAgo: 0),
  _host('web2', 'Web frontend 2', 'web-02.example.com', 'deploy',
      group: 'Production', color: HostColorLabel.red, hoursAgo: 1),
  _host('db', 'Postgres primary', 'db-1.example.com', 'postgres',
      group: 'Production', color: HostColorLabel.purple, hoursAgo: 26),
  _host('cache', 'Redis cache', 'cache-1.example.com', 'deploy',
      group: 'Production', color: HostColorLabel.purple),
  _host('stage', 'Staging API', 'staging.example.com', 'ubuntu',
      group: 'Staging', color: HostColorLabel.orange, port: 2222, hoursAgo: 3,
      transport: HostTransport.mosh, persistent: PersistentSession.tmux,
      agent: true),
  _host('worker', 'Staging workers', 'workers.staging.example.com', 'ubuntu',
      group: 'Staging', color: HostColorLabel.orange),
  _host('ci', 'Build runner', 'ci.example.org', 'runner',
      group: 'Tools', color: HostColorLabel.blue, hoursAgo: 30),
  _host('grafana', 'Monitoring', 'grafana.example.org', 'ops',
      group: 'Tools', color: HostColorLabel.blue),
  _host('bastion', 'Bastion', 'bastion.example.com', 'ops',
      group: 'Tools', color: HostColorLabel.yellow, hoursAgo: 75),
  _host('pi', 'Raspberry Pi', 'pi.lab.example.net', 'pi',
      color: HostColorLabel.green, hoursAgo: 50),
  _host('nas', 'NAS', 'nas.lab.example.net', 'admin',
      color: HostColorLabel.teal),
];

Host _byId(String id) => _hosts.firstWhere((h) => h.id == id);

// --------------------------------------------------------- demo sessions

/// A shell that says nothing: the screen is written straight into the
/// terminal once it has its size, so htop fills it edge to edge.
class _QuietShell implements SSHSession {
  final _stdout = StreamController<Uint8List>();
  final _done = Completer<void>();

  @override
  Stream<Uint8List> get stdout => _stdout.stream;
  @override
  Stream<Uint8List> get stderr => const Stream.empty();
  @override
  Future<void> get done => _done.future;
  @override
  int? get exitCode => null;
  @override
  void write(Uint8List data) {}
  @override
  void close() {}
  @override
  void resizeTerminal(int width, int height, [int? pw, int? ph]) {}
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not faked');
}

class _ShellTransport extends FakeTransportBase {
  _ShellTransport(Host host) : super(host: host);

  @override
  Future<SSHSession> startShell({
    required int columns,
    required int rows,
    String terminalType = 'xterm-256color',
  }) async =>
      _QuietShell();
}

/// A Python project checked out on the server, for the file browser and the
/// editor.
class _ProjectFs implements RemoteFileSystem {
  static const root = '/home/deploy/inventory-api';

  static const Map<String, String> texts = {
    '$root/app/orders.py': _ordersPy,
    '$root/deploy.sh': _deploySh,
    '$root/config/settings.toml': _settingsToml,
  };

  @override
  Future<String> home() async => root;
  @override
  Future<String> resolve(String path) async => path;
  @override
  Future<List<RemoteEntry>> list(String path) async {
    RemoteEntry dir(String name, DateTime when) => RemoteEntry(
          name: name,
          path: '$path/$name',
          kind: RemoteEntryKind.directory,
          size: 4096,
          modified: when,
          permissions: 0x4000 | 0x1ed,
        );
    RemoteEntry file(String name, int size, DateTime when,
            {bool exec = false}) =>
        RemoteEntry(
          name: name,
          path: '$path/$name',
          kind: RemoteEntryKind.file,
          size: size,
          modified: when,
          permissions: 0x8000 | (exec ? 0x1ed : 0x1a4),
        );
    DateTime at(int day, int hour, int minute) =>
        DateTime(2026, 10, day, hour, minute);
    return [
      dir('.git', at(22, 9, 12)),
      dir('.github', at(3, 16, 40)),
      dir('app', at(22, 9, 12)),
      dir('config', at(20, 11, 5)),
      dir('migrations', at(21, 18, 27)),
      dir('tests', at(22, 9, 12)),
      file('.env.example', 412, at(2, 10, 30)),
      file('.gitignore', 231, at(2, 10, 30)),
      file('Dockerfile', 1187, at(17, 14, 8)),
      file('README.md', 6912, at(20, 11, 5)),
      file('deploy.sh', 1460, at(21, 18, 27), exec: true),
      file('docker-compose.yml', 2114, at(17, 14, 8)),
      file('pyproject.toml', 1893, at(21, 18, 27)),
      file('requirements.lock', 14336, at(21, 18, 27)),
      file('inventory-api-2026.10.21.tar.gz', 48234496, at(21, 18, 30)),
    ];
  }

  @override
  Future<int?> sizeOf(String path) async =>
      utf8.encode(texts[path] ?? '').length;
  @override
  Future<bool> exists(String path) async => true;
  @override
  Future<bool> isDirectory(String path) async => false;
  @override
  Future<int> download(
    String remotePath, {
    required Future<void> Function(Uint8List chunk) write,
    TransferProgress? onProgress,
    CancelCheck? isCancelled,
  }) async {
    final bytes = Uint8List.fromList(utf8.encode(texts[remotePath] ?? ''));
    await write(bytes);
    return bytes.length;
  }

  @override
  Future<void> close() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not faked');
}

class _NoStorage implements DeviceStorage {
  @override
  Future<bool> ensurePermission() async => true;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not faked');
}

class _NoForeground implements SessionForegroundChannel {
  @override
  Future<void> start(String label) async {}
  @override
  Future<void> stop() async {}
}

class _NoKeepAwake implements KeepAwakeController {
  @override
  Future<void> setEnabled(bool enabled) async {}
}

class _InertTimer implements Timer {
  @override
  bool get isActive => false;
  @override
  int get tick => 0;
  @override
  void cancel() {}
}

class _MemoryBackend implements SecureStorageBackend {
  final Map<String, String> data = {};
  @override
  Future<void> write(String key, String value) async => data[key] = value;
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> delete(String key) async => data.remove(key);
}

SessionManager _sessionManager() => SessionManager(
      foreground: SessionForegroundController(channel: _NoForeground()),
      createController: (connection, resolve, resolveCreds) =>
          SessionController(
        connection: connection,
        storage: _NoStorage(),
        openFileSystem: () async => _ProjectFs(),
        resolveRemoteTarget: resolve,
        resolveDestinationCredentials: resolveCreds,
        keepaliveScheduler: (_, _) => _InertTimer(),
      ),
    );

// ------------------------------------------------------ fleet run demo

const _fleetCommand = 'systemctl is-active nginx && uptime -p';
const _fleetHosts = [
  'web1',
  'web2',
  'stage',
  'worker',
  'ci',
  'grafana',
  'bastion',
  'pi',
];

Future<SessionTransport> _fleetDialer(Host host, SshCredentials _) async {
  if (host.id == 'pi') {
    throw const SshConnectionException('Connection timed out.');
  }
  final (out, code) = switch (host.id) {
    'web1' => ('active\nup 41 days, 3 hours, 12 minutes\n', 0),
    'web2' => ('active\nup 41 days, 2 hours, 58 minutes\n', 0),
    'stage' => ('active\nup 6 days, 22 hours, 4 minutes\n', 0),
    'worker' => ('inactive\n', 3),
    'grafana' => ('active\nup 97 days, 5 hours, 31 minutes\n', 0),
    'bastion' => ('active\nup 203 days, 18 hours, 2 minutes\n', 0),
    _ => ('active\nup 13 days, 7 hours, 40 minutes\n', 0),
  };
  // How long each host takes, so the times shown are not all 0 ms.
  final ms = switch (host.id) {
    'web1' => 640,
    'web2' => 520,
    'stage' => 910,
    'worker' => 580,
    'grafana' => 470,
    'bastion' => 390,
    _ => 730,
  };
  return FakeExecTransport(
    host: host,
    respond: (_) => FakeExecSession(
      stdout: out,
      exitCode: code,
      exits: true,
      exitDelay: Duration(milliseconds: ms),
    ),
  );
}

// ------------------------------------------------------- terminal screens

const _esc = '\x1b';

/// One terminal row, built from coloured runs and cut at [width] so that
/// nothing wraps.
class _Row {
  _Row(this.width);

  final int width;
  final _out = StringBuffer();
  int length = 0;

  void add(String text, [String sgr = '']) {
    if (length >= width) return;
    final fits = text.length <= width - length
        ? text
        : text.substring(0, width - length);
    _out.write(sgr.isEmpty ? '$_esc[0m' : '$_esc[0;${sgr}m');
    _out.write(fits);
    length += fits.length;
  }

  void padTo(int column, [String sgr = '']) {
    if (column > length) add(' ' * (column - length), sgr);
  }

  @override
  String toString() => '$_out$_esc[0m';
}

String _screen(List<_Row> rows) =>
    '$_esc[H$_esc[2J$_esc[3J${rows.join('\r\n')}';

/// An htop-style meter: `label[|||||      23.4%]`.
void _meter(_Row row, String label, int width,
    List<(double, String)> parts, String value) {
  row.add(label, '36');
  row.add('[', '1');
  final inner = width - label.length - 2;
  final cells = List<(String, String)>.filled(inner, (' ', ''));
  var at = 0;
  for (final (fraction, sgr) in parts) {
    final n = (fraction * inner).round();
    for (var i = 0; i < n && at < inner; i++) {
      cells[at++] = ('|', sgr);
    }
  }
  final start = inner - value.length;
  for (var i = 0; i < value.length; i++) {
    cells[start + i] = (value[i], '90');
  }
  var run = StringBuffer();
  var sgr = cells.first.$2;
  for (final (ch, s) in cells) {
    if (s != sgr) {
      row.add(run.toString(), sgr);
      run = StringBuffer();
      sgr = s;
    }
    run.write(ch);
  }
  row.add(run.toString(), sgr);
  row.add(']', '1');
}

/// Black, from the 256-colour palette: the 16-colour "black" is a grey in
/// some schemes, too faint on htop's coloured bars.
const _ink = '38;5;16';

/// A busy web server in htop, sized to the terminal it is drawn in.
String _htop(int cols, int lines) {
  final rows = <_Row>[];
  final wide = cols >= 90;
  final cpus = wide
      ? [23.4, 9.1, 41.7, 12.0, 7.5, 18.9, 3.2, 28.6]
      : [23.4, 41.7, 12.0, 18.9];
  final half = cols ~/ 2;
  final perSide = cpus.length ~/ 2;

  void cpu(_Row row, int i, int width) {
    final pct = cpus[i];
    _meter(row, i.toString().padLeft(3), width, [
      (pct * 0.006, '32'),
      (pct * 0.003, '31'),
      (pct * 0.001, '34'),
    ], '${pct.toStringAsFixed(1)}%');
  }

  final rightText = <List<(String, String)>>[
    wide
        ? [
            ('Tasks: ', '36'),
            ('87', '1'),
            (', ', ''),
            ('214', '1;32'),
            (' thr; ', ''),
            ('3', '1;32'),
            (' running', ''),
          ]
        // Half a phone's terminal is too narrow for the thread count.
        : [
            ('Tasks: ', '36'),
            ('87', '1'),
            ('; ', ''),
            ('3', '1;32'),
            (' running', ''),
          ],
    [
      (wide ? 'Load average: ' : 'Load: ', '36'),
      ('1.42 ', '1'),
      ('1.18 ', '1'),
      ('0.97', ''),
    ],
    [
      ('Uptime: ', '36'),
      ('41 days, 03:12:47', '1'),
    ],
  ];

  for (var line = 0; line < perSide + 3; line++) {
    final row = _Row(cols)..add(' ');
    if (line < perSide) {
      cpu(row, line, half - 2);
    } else if (line == perSide) {
      _meter(row, 'Mem', half - 2, [
        (0.38, '32'),
        (0.06, '34'),
        (0.22, '33'),
      ], '5.92G/15.6G');
    } else if (line == perSide + 1) {
      _meter(row, 'Swp', half - 2, [(0.01, '31')], '12.0M/2.00G');
    }
    row.padTo(half + 1);
    if (line < perSide) {
      cpu(row, line + perSide, cols - half - 2);
    } else {
      for (final (text, sgr) in rightText[line - perSide]) {
        row.add(text, sgr);
      }
    }
    rows.add(row);
  }
  rows.add(_Row(cols));

  final userWidth = wide ? 10 : 9;
  final header = _Row(cols)
    ..add(
      '${'PID'.padLeft(7)} ${'USER'.padRight(userWidth)}'
      '${wide ? '${'PRI'.padLeft(4)}${'NI'.padLeft(4)}${'VIRT'.padLeft(6)}'
          '${'RES'.padLeft(6)}${'SHR'.padLeft(6)} S' : ''}'
      '${'CPU%'.padLeft(6)}${'MEM%'.padLeft(5)}${'TIME+'.padLeft(9)}  Command',
      '$_ink;42',
    );
  header.padTo(cols, '$_ink;42');
  rows.add(header);

  final procs = [
    (2210, 'deploy', 18.6, 4.8, '1:12.09', 'gunicorn', ' app.main:app -w 4'),
    (981, 'postgres', 11.2, 6.4, '12:07.55', 'postgres', ': checkpointer'),
    (1234, 'www-data', 9.3, 2.1, '3:41.22', 'nginx', ': worker process'),
    (2211, 'deploy', 8.8, 4.7, '1:10.44', 'gunicorn', ' app.main:app -w 4'),
    (2212, 'deploy', 6.1, 4.6, '1:02.71', 'gunicorn', ' app.main:app -w 4'),
    (644, 'redis', 2.4, 1.2, '4:51.10', 'redis-server', ' 127.0.0.1:6379'),
    (1876, 'root', 1.1, 0.6, '0:33.18', '/usr/bin/containerd', ''),
    (3150, 'deploy', 0.7, 0.0, '0:00.21', 'htop', ''),
    (733, 'root', 0.3, 0.1, '0:00.88', 'sshd', ': deploy@pts/0'),
    (2213, 'deploy', 0.3, 4.5, '0:58.13', 'gunicorn', ' app.main:app -w 4'),
    (1, 'root', 0.0, 0.1, '0:09.71', '/sbin/init', ''),
    (512, 'root', 0.0, 0.2, '0:02.04', '/lib/systemd/systemd-journald', ''),
    (601, 'root', 0.0, 0.1, '0:01.37', '/lib/systemd/systemd-udevd', ''),
    (812, 'root', 0.0, 0.1, '0:00.52', '/usr/sbin/cron', ' -f'),
    (840, 'syslog', 0.0, 0.1, '0:00.97', '/usr/sbin/rsyslogd', ' -n'),
    (1233, 'root', 0.0, 0.0, '0:00.03', 'nginx', ': master process'),
    (979, 'postgres', 0.0, 1.8, '0:41.30', 'postgres', ': walwriter'),
    (980, 'postgres', 0.0, 0.9, '0:12.44', 'postgres', ': autovacuum launcher'),
    (1590, 'root', 0.0, 0.3, '0:05.81', '/usr/lib/snapd/snapd', ''),
    (2205, 'deploy', 0.0, 0.9, '0:03.12', 'gunicorn', ': master'),
    (707, 'root', 0.0, 0.1, '0:00.44', '/usr/sbin/irqbalance', ' --foreground'),
    (921, 'root', 0.0, 0.2, '0:01.02', '/usr/bin/dockerd', ' -H fd://'),
    (1012, '_chrony', 0.0, 0.0, '0:00.31', '/usr/sbin/chronyd', ' -F 1'),
    (1102, 'root', 0.0, 0.1, '0:00.19', 'sshd', ': /usr/sbin/sshd -D'),
    (1450, 'deploy', 0.0, 0.0, '0:00.09', '-bash', ''),
    (1688, 'daemon', 0.0, 0.0, '0:00.07', '/usr/sbin/atd', ' -f'),
    (1901, 'root', 0.0, 0.0, '0:00.05', '/sbin/agetty', ' -o -p -- \\u tty1'),
    (623, 'systemd+', 0.0, 0.1, '0:00.61', '/lib/systemd/systemd-resolved', ''),
    (690, 'messagebus', 0.0, 0.0, '0:00.40', '@dbus-daemon', ' --system'),
    (1311, 'root', 0.0, 0.2, '0:03.95', '/usr/bin/containerd-shim-runc-v2', ''),
    (1650, 'root', 0.0, 0.1, '0:00.22', '/usr/sbin/ModemManager', ''),
  ];
  // A tall terminal gets the database's client connections and the task
  // workers too.
  final random = math.Random(5);
  final idle = [
    for (var i = 0; i < 60; i++)
      switch (i % 5) {
        0 || 2 => (
            3204 + i * 3,
            'postgres',
            0.0,
            0.3 + random.nextInt(3) / 10,
            '0:0${random.nextInt(8)}.${random.nextInt(90) + 10}',
            'postgres',
            ': inventory inventory 10.0.1.${11 + i % 3}'
                '(${51200 + random.nextInt(9000)}) idle',
          ),
        1 => (
            2400 + i,
            'deploy',
            0.0,
            1.6 + random.nextInt(4) / 10,
            '0:${10 + random.nextInt(40)}.${random.nextInt(90) + 10}',
            'celery',
            ' -A app.tasks worker -c 4',
          ),
        3 => (
            4100 + i * 7,
            'www-data',
            0.0,
            0.2,
            '0:0${random.nextInt(4)}.${random.nextInt(90) + 10}',
            'nginx',
            ': worker process',
          ),
        _ => (
            1700 + i,
            'root',
            0.0,
            0.1,
            '0:00.${random.nextInt(90) + 10}',
            '/usr/bin/containerd-shim-runc-v2',
            ' -namespace moby',
          ),
      },
  ];
  final all = [...procs, ...idle..shuffle(random)];
  String size(double megabytes) => megabytes >= 1000
      ? '${(megabytes / 1024).toStringAsFixed(2)}G'
      : '${megabytes.round()}M';

  final tableRows = lines - rows.length - 1;
  for (var i = 0; i < tableRows && i < all.length; i++) {
    final (pid, user, cpu, mem, time, cmd, args) = all[i];
    final selected = i == 0;
    String c(String normal) => selected ? '$_ink;46' : normal;
    final row = _Row(cols)
      ..add(pid.toString().padLeft(7), c(''))
      ..add(
          ' ${user.length > userWidth ? '${user.substring(0, userWidth - 1)}+' : user.padRight(userWidth)}',
          c(''));
    if (wide) {
      final res = math.max(mem / 100 * 15974, 3.0 + pid % 9);
      final virt = res * 2.2 + 60 + pid % 50;
      row
        ..add('  20   0', c(''))
        ..add(' ${size(virt).padLeft(5)}', c(''))
        ..add(' ${size(res).padLeft(5)}', c(''))
        ..add(' ${size(res * 0.3 + 2).padLeft(5)}', c(''))
        ..add(' ', c(''))
        ..add(i < 3 ? 'R' : 'S', c(i < 3 ? '32' : ''));
    }
    row
      ..add(' ${cpu.toStringAsFixed(1).padLeft(5)}', c(''))
      ..add(' ${mem.toStringAsFixed(1).padLeft(4)}', c(''))
      ..add(' ${time.padLeft(8)}', c(''))
      ..add('  ', c(''))
      ..add(cmd, c(cmd.startsWith('/') ? '' : '1'))
      ..add(args, c(cmd == 'gunicorn' ? '32' : ''));
    if (selected) row.padTo(cols, '$_ink;46');
    rows.add(row);
  }
  while (rows.length < lines - 1) {
    rows.add(_Row(cols));
  }

  final footer = _Row(cols);
  for (final (key, label) in const [
    ('F1', 'Help  '),
    ('F2', 'Setup '),
    ('F3', 'Search'),
    ('F4', 'Filter'),
    ('F5', 'Tree  '),
    ('F6', 'SortBy'),
    ('F7', 'Nice -'),
    ('F8', 'Nice +'),
    ('F9', 'Kill  '),
    ('F10', 'Quit'),
  ]) {
    footer
      ..add(key)
      ..add(label, '$_ink;46');
  }
  footer.padTo(cols, '$_ink;46');
  rows.add(footer);
  return '$_esc[?25l${_screen(rows)}';
}

String _prompt(String host, String dir) =>
    '$_esc[1;32mdeploy@$host$_esc[0m:$_esc[1;34m$dir$_esc[0m\$ ';

/// The API's recent log, with timeouts for the find bar to land on.
String _logs(int cols, int lines) {
  final random = math.Random(11);
  (String, String) traffic() {
    final order = 1100 + random.nextInt(90);
    final sku = '${'ABC'[random.nextInt(3)]}-${1000 + random.nextInt(3000)}';
    return switch (random.nextInt(16)) {
      0 || 1 => ('INFO', 'GET /orders/$order 200 ${8 + random.nextInt(9)}ms'),
      2 => ('INFO', 'POST /orders 201 ${70 + random.nextInt(40)}ms'),
      3 || 4 => ('INFO', 'GET /health 200 2ms'),
      5 || 6 => ('INFO', 'GET /stock/$sku 200 ${6 + random.nextInt(8)}ms'),
      7 => ('INFO', 'PUT /stock/$sku 204 ${18 + random.nextInt(12)}ms'),
      8 => ('INFO', 'GET /orders?page=${1 + random.nextInt(4)} 200 '
          '${30 + random.nextInt(20)}ms'),
      9 => ('INFO', 'DELETE /cart/${5000 + random.nextInt(900)} 204 6ms'),
      10 => ('WARN', 'slow query orders_by_sku 1.${random.nextInt(9) + 1}s'),
      11 || 12 => ('INFO', 'GET /stock/$sku 304 3ms'),
      _ => ('INFO', 'GET /orders/$order/items 200 ${10 + random.nextInt(9)}ms'),
    };
  }

  // Counted back from the prompt, so the two incidents land on screen
  // whatever its height.
  const incidents = {
    4: [
      ('ERROR', 'smtp timeout sending receipt'),
      ('INFO', 'queued receipt 1184 for retry'),
    ],
    13: [
      ('ERROR', 'payment gateway timeout (30s)'),
      ('INFO', 'retrying payment 7f3c in 2s'),
      ('INFO', 'payment 7f3c confirmed'),
    ],
  };
  final newestFirst = <(String, String)>[];
  while (newestFirst.length < lines - 2) {
    final burst = incidents[newestFirst.length];
    if (burst != null) {
      newestFirst.addAll(burst.reversed);
    } else {
      newestFirst.add(traffic());
    }
  }
  final shown = newestFirst.take(lines - 2).toList().reversed.toList();
  var second = 9 * 3600 + 14 * 60 + 31;
  final times = <int>[];
  for (var i = 0; i < shown.length; i++) {
    times.insert(0, second);
    second -= 1 + random.nextInt(3);
  }
  final body = <String>[
    '${_prompt('web-01', '~/inventory-api')}'
        'docker compose logs --tail ${shown.length} api',
    for (var i = 0; i < shown.length; i++)
      '$_esc[36mapi-1  |$_esc[0m ${_clock(times[i])} '
          '${switch (shown[i].$1) {
        'ERROR' => '$_esc[1;31m',
        'WARN' => '$_esc[33m',
        _ => '$_esc[32m',
      }}${shown[i].$1.padRight(5)}$_esc[0m ${shown[i].$2}',
    _prompt('web-01', '~/inventory-api'),
  ];
  return '$_esc[H$_esc[2J$_esc[3J${body.join('\r\n')}';
}

String _clock(int seconds) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(seconds ~/ 3600)}:${two(seconds ~/ 60 % 60)}:${two(seconds % 60)}';
}

/// A login and a short deploy, for a second terminal beside htop.
String _deploy(int cols, int lines) {
  final p = _prompt('staging', '~/inventory-api');
  final body = <String>[
    'Welcome to Ubuntu 24.04.1 LTS (GNU/Linux 6.8.0-45-generic x86_64)',
    '',
    'Last login: Thu Oct 22 08:57:13 2026 from 203.0.113.24',
    '${p}git pull --ff-only',
    'Updating 4be21d0..a3f9c21',
    'Fast-forward',
    ' app/orders.py                        | 18 $_esc[32m++++++++++++$_esc[31m------$_esc[0m',
    ' migrations/0042_fulfilment_status.py | 31 $_esc[32m+++++++++++++++++++++$_esc[0m',
    ' 2 files changed, 43 insertions(+), 6 deletions(-)',
    '$p./deploy.sh staging',
    '$_esc[1;34m==>$_esc[0;1m Building image inventory-api:2026.10.22-1$_esc[0m',
    ' => [1/6] FROM python:3.12-slim                          0.4s',
    ' => [2/6] COPY requirements.lock .                        0.1s',
    ' => [3/6] RUN pip install -r requirements.lock           21.7s',
    ' => [4/6] COPY app/ ./app/                                0.2s',
    ' => exporting to image                                    1.9s',
    '$_esc[1;34m==>$_esc[0;1m Running migrations$_esc[0m',
    '  Applying orders.0042_fulfilment_status... $_esc[32mOK$_esc[0m',
    '$_esc[1;34m==>$_esc[0;1m Restarting api (2 replicas)$_esc[0m',
    '  api-1 $_esc[32mhealthy$_esc[0m  200 OK in 41 ms',
    '  api-2 $_esc[32mhealthy$_esc[0m  200 OK in 38 ms',
    '$_esc[1;32m==> Deployed 2026.10.22-1 in 1m 52s$_esc[0m',
    '${p}docker compose ps',
    '$_esc[1mNAME       IMAGE                        STATUS$_esc[0m',
    'api-1      inventory-api:2026.10.22-1   Up 38 seconds (healthy)',
    'api-2      inventory-api:2026.10.22-1   Up 31 seconds (healthy)',
    'worker-1   inventory-api:2026.10.22-1   Up 29 seconds',
    'redis-1    redis:7.4-alpine             Up 6 days',
    p,
  ];
  final shown = body.length > lines ? body.sublist(body.length - lines) : body;
  return '$_esc[H$_esc[2J$_esc[3J${shown.join('\r\n')}';
}

// ------------------------------------------------------------ demo files

const _ordersPy = '''"""Order endpoints for the inventory API."""
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from app.db import get_session
from app.models import Order, OrderStatus
from app.schemas import OrderIn

router = APIRouter(prefix="/orders", tags=["orders"])
MAX_ITEMS = 50


@router.get("/{order_id}")
def read_order(order_id: int, db: Session = Depends(get_session)):
    order = db.get(Order, order_id)
    if order is None:
        raise HTTPException(404, "order not found")
    return order


@router.post("/", status_code=201)
def create_order(payload: OrderIn, db: Session = Depends(get_session)):
    if len(payload.items) > MAX_ITEMS:
        raise HTTPException(422, f"at most {MAX_ITEMS} items per order")
    order = Order(
        customer_id=payload.customer_id,
        status=OrderStatus.PENDING,
        created_at=datetime.now(timezone.utc),
    )
    for item in payload.items:
        # Reserve stock now; payment confirms it later.
        order.add_item(item.sku, quantity=item.quantity)
    db.add(order)
    db.commit()
    return order


@router.post("/{order_id}/cancel")
def cancel_order(order_id: int, db: Session = Depends(get_session)):
    order = read_order(order_id, db)
    if order.status is OrderStatus.SHIPPED:
        raise HTTPException(409, "already shipped")
    order.status = OrderStatus.CANCELLED
    db.commit()
    return {"id": order.id, "status": order.status.value}
''';

const _deploySh = '''#!/usr/bin/env bash
set -euo pipefail

ENVIRONMENT=\${1:?usage: deploy.sh <environment>}
TAG=\$(date +%Y.%m.%d)-\$(git rev-list --count HEAD)

echo "==> Building image inventory-api:\$TAG"
docker build -t "inventory-api:\$TAG" .

echo "==> Running migrations"
docker compose run --rm api alembic upgrade head

echo "==> Restarting api"
docker compose up -d --no-deps api
''';

const _settingsToml = '''[server]
host = "0.0.0.0"
port = 8080
workers = 4

[database]
url = "postgresql://inventory@db-1.example.com/inventory"
pool_size = 10
''';

// ---------------------------------------------------------------- fonts

Future<void> _loadFonts() async {
  final root = Platform.environment['FLUTTER_ROOT'] ??
      '${Platform.environment['HOME']}/development/flutter';
  final fonts = '$root/bin/cache/artifacts/material_fonts';
  Future<void> load(String family, List<String> paths) async {
    final loader = FontLoader(family);
    for (final path in paths) {
      final bytes = File(path).readAsBytesSync();
      loader.addFont(Future.value(ByteData.view(bytes.buffer)));
    }
    await loader.load();
  }

  await load('Roboto', [
    for (final face in ['Regular', 'Medium', 'Bold', 'Light'])
      '$fonts/Roboto-$face.ttf',
  ]);
  await load('MaterialIcons', ['$fonts/MaterialIcons-Regular.otf']);
  await load(TerminalFonts.jetBrainsMono, [
    for (final face in ['Regular', 'Bold']) 'assets/fonts/JetBrainsMono-$face.ttf',
  ]);
  // The editor and a few labels ask for 'monospace', which the test
  // renderer does not have.
  const mono = '/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf';
  if (File(mono).existsSync()) await load('monospace', [mono]);
  // Material asks for Segoe UI on Windows. It cannot be shipped here, so
  // the Windows set stands in Noto Sans, the nearest open humanist sans.
  const noto = '/usr/share/fonts/truetype/noto';
  if (File('$noto/NotoSans-Regular.ttf').existsSync()) {
    await load('Segoe UI', [
      '$noto/NotoSans-Regular.ttf',
      '$noto/NotoSans-Bold.ttf',
    ]);
  }
  // Chinese, Japanese and Korean, which Roboto does not cover; see
  // [_theme]. Noto's collection opens on its Japanese face, which also has
  // Hangul; Chinese gets Droid's Simplified forms.
  const notoCjk = '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc';
  const droid = '/usr/share/fonts/truetype/droid/DroidSansFallbackFull.ttf';
  if (File(notoCjk).existsSync()) await load(_cjkFont, [notoCjk]);
  if (File(droid).existsSync()) await load(_chineseFont, [droid]);
}

const _cjkFont = 'StoreShotsCJK';
const _chineseFont = 'StoreShotsChinese';

/// The app's theme, plus a fallback font for the CJK languages: the test
/// renderer only falls back to fonts a style names, unlike a device.
ThemeData _theme(Brightness brightness) {
  final theme = AppTheme.themeFor(UiStyle.aurora, brightness);
  final fallback = switch (_locale.languageCode) {
    'zh' => [_chineseFont],
    'ja' || 'ko' => [_cjkFont],
    _ => null,
  };
  if (fallback == null) return theme;
  return theme.copyWith(
    textTheme: theme.textTheme.apply(fontFamilyFallback: fallback),
    primaryTextTheme:
        theme.primaryTextTheme.apply(fontFamilyFallback: fallback),
  );
}

// ------------------------------------------------------------ PNG writer

/// Encodes RGBA pixels as a 24-bit RGB PNG — Play rejects screenshots with
/// an alpha channel — choosing the filter row by row, as optimisers do.
Uint8List _encodePng(Uint8List rgba, int width, int height) {
  final stride = width * 3;
  final raw = BytesBuilder(copy: false);
  var previous = Uint8List(stride);
  final current = Uint8List(stride);
  final candidates = List.generate(5, (_) => Uint8List(stride + 1));
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final i = (y * width + x) * 4;
      current[x * 3] = rgba[i];
      current[x * 3 + 1] = rgba[i + 1];
      current[x * 3 + 2] = rgba[i + 2];
    }
    var best = 0;
    var bestScore = 1 << 62;
    for (var filter = 0; filter < 5; filter++) {
      final out = candidates[filter];
      out[0] = filter;
      var score = 0;
      for (var i = 0; i < stride; i++) {
        final a = i >= 3 ? current[i - 3] : 0;
        final b = previous[i];
        final c = i >= 3 ? previous[i - 3] : 0;
        final predicted = switch (filter) {
          0 => 0,
          1 => a,
          2 => b,
          3 => (a + b) >> 1,
          _ => _paeth(a, b, c),
        };
        final v = (current[i] - predicted) & 0xff;
        out[i + 1] = v;
        score += v < 128 ? v : 256 - v;
      }
      if (score < bestScore) {
        bestScore = score;
        best = filter;
      }
    }
    raw.add(Uint8List.fromList(candidates[best]));
    previous = Uint8List.fromList(current);
  }
  final compressed = ZLibEncoder(level: 9).convert(raw.takeBytes());

  final png = BytesBuilder();
  png.add(const [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  void chunk(String type, List<int> data) {
    final body = [...ascii.encode(type), ...data];
    png.add(_u32(data.length));
    png.add(body);
    png.add(_u32(_crc32(body)));
  }

  chunk('IHDR', [..._u32(width), ..._u32(height), 8, 2, 0, 0, 0]);
  chunk('IDAT', compressed);
  chunk('IEND', const []);
  return png.takeBytes();
}

int _paeth(int a, int b, int c) {
  final p = a + b - c;
  final pa = (p - a).abs();
  final pb = (p - b).abs();
  final pc = (p - c).abs();
  if (pa <= pb && pa <= pc) return a;
  return pb <= pc ? b : c;
}

List<int> _u32(int v) => [v >> 24 & 0xff, v >> 16 & 0xff, v >> 8 & 0xff, v & 0xff];

final List<int> _crcTable = List.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = c & 1 != 0 ? 0xedb88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

int _crc32(List<int> bytes) {
  var c = 0xffffffff;
  for (final b in bytes) {
    c = _crcTable[(c ^ b) & 0xff] ^ (c >> 8);
  }
  return c ^ 0xffffffff;
}

// ------------------------------------------------------------------ tests

void main() {
  late Directory dir;
  late HostStore hosts;
  late SettingsStore settings;
  late KnownHostsService knownHosts;
  late SshService ssh;
  late CredentialStore credentials;

  setUpAll(_loadFonts);

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ssg_store_shots');
    hosts = HostStore(file: File('${dir.path}/${HostStore.fileName}'));
    settings =
        SettingsStore(file: File('${dir.path}/${SettingsStore.fileName}'));
    knownHosts = KnownHostsService(
      file: File('${dir.path}/${KnownHostsService.fileName}'),
    );
    ssh = SshService(knownHosts: knownHosts);
    credentials = CredentialStore(backend: _MemoryBackend());
  });

  tearDown(() async {
    settings.dispose();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Future<void> settleIo(WidgetTester tester, {int rounds = 40}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
  }

  Future<void> seed(WidgetTester tester, Brightness brightness) =>
      tester.runAsync(() async {
        await settings.update((s) => s.copyWith(
              terminalFont: TerminalFont.jetBrainsMono,
              themeBrightness: brightness == Brightness.dark
                  ? ThemeBrightness.dark
                  : ThemeBrightness.light,
            ));
        for (final host in _hosts) {
          await hosts.add(host);
          await credentials.save(
              host.id, const SshCredentials(privateKeyPem: 'demo key'));
        }
      });

  Future<void> render(
    WidgetTester tester,
    _Set set,
    String file,
    Brightness brightness,
    Widget Function() build, {
    required bool push,
    Future<void> Function(WidgetTester tester)? after,
  }) async {
    final profile = InputProfile();
    if (set.mouse) {
      profile
        ..notePointer(PointerDeviceKind.mouse)
        ..noteHardwareKey();
    } else {
      profile.notePointer(PointerDeviceKind.touch);
    }

    final boundary = GlobalKey();
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(RepaintBoundary(
      key: boundary,
      child: MaterialApp(
        navigatorKey: navigator,
        debugShowCheckedModeBanner: false,
        locale: _locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        themeMode:
            brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
        theme: _theme(Brightness.light),
        darkTheme: _theme(Brightness.dark),
        builder: (context, child) =>
            InputProfileScope(profile: profile, child: child!),
        home: push ? const Scaffold(body: SizedBox.shrink()) : build(),
      ),
    ));
    if (push) {
      unawaited(navigator.currentState!
          .push(MaterialPageRoute<void>(builder: (_) => build())));
    }
    await tester.pump();
    await settleIo(tester);
    await tester.pump(const Duration(milliseconds: 600));
    if (after != null) {
      await after(tester);
      await settleIo(tester, rounds: 10);
      await tester.pump(const Duration(milliseconds: 600));
    }

    final ro =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await ro.toImage(pixelRatio: set.dpr);
      expect(
        Size(image.width.toDouble(), image.height.toDouble()),
        set.size * set.dpr,
        reason: 'the store wants these exact pixel sizes',
      );
      final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final png = _encodePng(
          rgba!.buffer.asUint8List(), image.width, image.height);
      final out = Directory('${_outDir!}/${set.folder}')
        ..createSync(recursive: true);
      await File('${out.path}/$file.png').writeAsBytes(png);
      image.dispose();
    });
    await tester.pumpWidget(const SizedBox.shrink());
    await settleIo(tester, rounds: 5);
  }

  /// Renders [build] at [set]'s size and writes `<folder>/<file>.png`.
  Future<void> shoot(
    WidgetTester tester,
    _Set set,
    String file,
    Brightness brightness,
    Widget Function() build, {
    bool push = false,
    Future<void> Function(WidgetTester tester)? after,
  }) async {
    tester.view.physicalSize = set.size * set.dpr;
    tester.view.devicePixelRatio = set.dpr;
    addTearDown(tester.view.reset);
    // Real shadows rather than the test renderer's solid outlines; the
    // binding wants the flag back by the end of the test.
    debugDisableShadows = false;
    try {
      await render(tester, set, file, brightness, build,
          push: push, after: after);
    } finally {
      debugDisableShadows = true;
    }
  }

  /// Three sessions open, on web-01, the database and staging; web-01 in
  /// front showing [view], its terminal drawn by [screen] once it knows its
  /// size. [split] puts staging in a second pane; [findBar] searches web-01.
  Future<void> shootSessions(
    WidgetTester tester,
    _Set set,
    String file,
    Brightness brightness, {
    SessionView view = SessionView.terminal,
    required String Function(int cols, int rows) screen,
    bool split = false,
    bool findBar = false,
  }) async {
    final manager = _sessionManager();
    final workspace = TerminalWorkspace();
    addTearDown(() async {
      await workspace.dispose();
      await manager.dispose();
    });
    final web = manager.open(_ShellTransport(_byId('web1')), initialView: view);
    final db = manager.open(_ShellTransport(_byId('db')));
    final stage = manager.open(_ShellTransport(_byId('stage')));
    manager.select(web.id);

    void paint(SessionController session, String Function(int, int) draw) {
      final t = session.terminal;
      t.write(draw(t.viewWidth, t.viewHeight));
    }

    await shoot(
      tester,
      set,
      file,
      brightness,
      () => SessionsScreen(
        sessions: manager,
        settingsStore: settings,
        workspace: workspace,
        keepAwake: _NoKeepAwake(),
      ),
      after: (tester) async {
        if (split) {
          workspace.splitFocused(WorkspaceAxis.row);
          await tester.pump();
          final right = workspace.panes.last;
          workspace.showSession(stage.id, inPaneId: right.id);
          workspace.focusPane(workspace.panes.first.id);
          await settleIo(tester, rounds: 10);
          await tester.pump(const Duration(milliseconds: 300));
          paint(stage.controller, _deploy);
        }
        paint(web.controller, screen);
        paint(db.controller, _logs);
        if (!split) paint(stage.controller, _deploy);
        await tester.pump();
        if (findBar) {
          TerminalPane.showFind(web.controller);
          await tester.pump();
          await tester.pump();
          await tester.enterText(
            find.descendant(
              of: find.byType(TerminalFindBar),
              matching: find.byType(TextField),
            ),
            'timeout',
          );
          await tester.pump();
        }
      },
    );
  }

  Future<void> run(WidgetTester tester, _Set set, String file, _Shot shot,
      Brightness brightness) async {
    await seed(tester, brightness);
    final sessions = _sessionManager();
    addTearDown(sessions.dispose);
    switch (shot) {
      case _Shot.hosts:
        await shoot(
          tester,
          set,
          file,
          brightness,
          () => HostListScreen(
            hostStore: hosts,
            credentialStore: credentials,
            knownHosts: knownHosts,
            sshService: ssh,
            settingsStore: settings,
            sessions: sessions,
          ),
        );
      case _Shot.terminal:
        await shootSessions(tester, set, file, brightness, screen: _htop);
      case _Shot.find:
        await shootSessions(tester, set, file, brightness,
            screen: _logs, findBar: true);
      case _Shot.files:
        await shootSessions(tester, set, file, brightness,
            screen: _htop, view: SessionView.files);
      case _Shot.sideBySide:
        await shootSessions(tester, set, file, brightness, screen: _htop);
      case _Shot.workspace:
        await shootSessions(tester, set, file, brightness,
            screen: _htop, split: true);
      case _Shot.editor:
        await shoot(
          tester,
          set,
          file,
          brightness,
          push: true,
          () => RemoteEditorScreen(
            filesystem: _ProjectFs(),
            settingsStore: settings,
            initialPaths: const [
              '${_ProjectFs.root}/app/orders.py',
              '${_ProjectFs.root}/deploy.sh',
              '${_ProjectFs.root}/config/settings.toml',
            ],
            hostLabel: 'web-01',
          ),
        );
      case _Shot.advanced:
        await shoot(
          tester,
          set,
          file,
          brightness,
          push: true,
          () => HostEditScreen(
            hostStore: hosts,
            credentialStore: credentials,
            sshService: ssh,
            settingsStore: settings,
            sessions: sessions,
            host: _byId('stage'),
          ),
          after: (tester) async {
            final section = find.byType(HostAdvancedSection);
            await tester.scrollUntilVisible(section, 300,
                scrollable: find.byType(Scrollable).first);
            await tester.pumpAndSettle();
            await Scrollable.ensureVisible(tester.element(section));
            await tester.pumpAndSettle();
          },
        );
      case _Shot.fleet:
        final saved = _hosts.where((h) => _fleetHosts.contains(h.id)).toList();
        await shoot(
          tester,
          set,
          file,
          brightness,
          push: true,
          () => FleetRunScreen(
            hosts: _hosts,
            initialHostIds: saved.map((h) => h.id).toSet(),
            sessions: sessions,
            credentialStore: credentials,
            sshService: ssh,
            dialer: _fleetDialer,
            initialCommand: _fleetCommand,
          ),
          after: (tester) async {
            // Next, then Run: the one enabled filled button on each step,
            // found without its label so a translated set finds it too.
            final filled = find.byWidgetPredicate(
                (w) => w is FilledButton && w.onPressed != null);
            for (var step = 0; step < 2; step++) {
              for (var i = 0; i < 20 && filled.evaluate().isEmpty; i++) {
                await tester.drag(
                    find.byType(Scrollable).first, const Offset(0, -300));
                await tester.pump();
              }
              await tester.ensureVisible(filled.last);
              await tester.pumpAndSettle();
              await tester.tap(filled.last);
              // The run's spinners never settle while it waits on the hosts.
              await tester.pump(const Duration(milliseconds: 400));
            }
            // The run times each host by the wall clock, so let the fake
            // one keep pace with it.
            for (var i = 0; i < 120; i++) {
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 10)),
              );
              await tester.pump(const Duration(milliseconds: 10));
            }
            await tester.tap(find.text('Web frontend 1'));
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 400));
          },
        );
      case _Shot.settings:
        await shoot(
          tester,
          set,
          file,
          brightness,
          push: true,
          () => SettingsScreen(
            settingsStore: settings,
            knownHosts: knownHosts,
            hostStore: hosts,
          ),
        );
    }
  }

  for (final set in _sets) {
    group(set.folder, () {
      for (final (file, shot, brightness) in set.shots) {
        testWidgets(
          file,
          skip: _outDir == null,
          // The Windows set renders as Windows: desktop-only rows (X11, the
          // OS agent) say what they do there instead of being greyed out.
          variant: TargetPlatformVariant.only(
              set.mouse ? TargetPlatform.windows : TargetPlatform.android),
          (tester) async {
            await run(tester, set, file, shot, brightness);
          },
        );
      }
    });
  }
}
