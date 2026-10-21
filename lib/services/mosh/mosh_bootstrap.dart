import 'dart:io';

import '../remote_exec.dart';
import '../shell_quote.dart';
import '../ssh_service.dart';

/// Starting `mosh-server` on the host, over the SSH connection the session
/// already has — exactly what the `mosh` wrapper script does with `ssh`.
///
/// The server prints `MOSH CONNECT <port> <key>`, forks itself into the
/// background, and the exec ends. From then on the terminal is Mosh's UDP
/// protocol; the SSH connection stays for files, tunnels and commands.

/// Why `mosh-server` could not be started.
enum MoshStartFailure {
  /// Not installed, or not on the PATH an SSH command gets.
  notInstalled,

  /// The host has no UTF-8 locale Mosh will accept.
  locale,

  /// It ran but did not print a connection line.
  failed,
}

class MoshStartException implements Exception {
  const MoshStartException(this.kind, this.message, {this.details});

  final MoshStartFailure kind;

  /// One line, fit to show as is.
  final String message;

  /// What the server printed, for the diagnostics log.
  final String? details;

  @override
  String toString() => message;
}

/// What a started `mosh-server` said.
class MoshServerInfo {
  const MoshServerInfo({
    required this.port,
    required this.key,
    this.pid,
    this.sshConnection,
  });

  final int port;

  /// The session key, base64 without padding.
  final String key;

  /// The detached server's process id, when it said, so a session that never
  /// connects can be cleaned up.
  final int? pid;

  /// `$SSH_CONNECTION` as the host saw it: client address and port, then
  /// the server address and port the SSH connection arrived on.
  final String? sshConnection;
}

/// Places `mosh-server` is commonly installed outside the PATH a
/// non-interactive SSH command gets — Homebrew on macOS above all.
const moshServerSearchPath = [
  'mosh-server',
  '/usr/local/bin/mosh-server',
  '/opt/homebrew/bin/mosh-server',
  '/opt/local/bin/mosh-server',
  '/snap/bin/mosh-server',
];

const _connectMarker = 'MOSH SSH_CONNECTION';
const _missingMarker = 'MOSH SERVER NOT FOUND';

/// The command that starts `mosh-server` with [locale] (a `LANG` value),
/// running [command] instead of the login shell when given.
///
/// It runs under `sh` whatever the user's login shell is, so the search and
/// the quoting mean the same thing on bash, zsh, fish and csh. [server]
/// replaces the search with a command of the caller's choosing, as
/// `mosh --server=` does.
String moshServerCommand({
  required String locale,
  String? command,
  String? server,
}) {
  final args = [
    'new',
    '-s',
    '-c',
    '256',
    '-l',
    posixSingleQuote('LANG=$locale'),
    if (command != null) ...['--', 'sh', '-c', posixSingleQuote(command)],
  ].join(' ');
  final launch = server != null
      ? 'exec $server $args'
      : 'for m in ${moshServerSearchPath.join(' ')}; do '
            'if command -v "\$m" >/dev/null 2>&1; then exec "\$m" $args; fi; '
            'done; echo "$_missingMarker"; exit 127';
  final script = 'echo "$_connectMarker \$SSH_CONNECTION"; $launch';
  return 'sh -c ${posixSingleQuote(script)}';
}

/// Reads what `mosh-server new` printed. Throws [MoshStartException] when it
/// did not start.
MoshServerInfo parseMoshServerOutput(ExecResult result) {
  final out = result.stdout;
  final err = result.stderr;
  final connect = RegExp(
    r'MOSH CONNECT (\d+) ([A-Za-z0-9/+]{22})(?![A-Za-z0-9/+])',
  ).firstMatch(out);
  final sshConnection = RegExp(
    '^$_connectMarker (.*)\$',
    multiLine: true,
  ).firstMatch(out)?.group(1)?.trim();
  if (connect != null) {
    final pid = RegExp(r'mosh-server detached, pid = (\d+)').firstMatch(err);
    return MoshServerInfo(
      port: int.parse(connect.group(1)!),
      key: connect.group(2)!,
      pid: pid == null ? null : int.parse(pid.group(1)!),
      sshConnection: sshConnection == null || sshConnection.isEmpty
          ? null
          : sshConnection,
    );
  }

  final details = [
    out.trim(),
    err.trim(),
  ].where((s) => s.isNotEmpty).join('\n');
  if (out.contains(_missingMarker) ||
      (result.exitCode == 127 && err.contains('not found'))) {
    throw MoshStartException(
      MoshStartFailure.notInstalled,
      'mosh-server is not installed on this host.',
      details: details.isEmpty ? null : details,
    );
  }
  if (err.contains('needs a UTF-8 native locale')) {
    throw MoshStartException(
      MoshStartFailure.locale,
      'mosh-server needs a UTF-8 locale, and this host has none it accepts.',
      details: details,
    );
  }
  final lastLine = err
      .split('\n')
      .map((line) => line.trim())
      .lastWhere((line) => line.isNotEmpty, orElse: () => '');
  throw MoshStartException(
    MoshStartFailure.failed,
    lastLine.isEmpty
        ? 'mosh-server did not start'
              '${result.exitCode == null ? '' : ' (exit status ${result.exitCode})'}.'
        : 'mosh-server did not start: $lastLine',
    details: details.isEmpty ? null : details,
  );
}

/// The `LANG` values to offer `mosh-server`, best first. It only uses them
/// when the host's own locale is not UTF-8; one the host does not have
/// fails, and the next is tried.
List<String> moshLocales([String? deviceLocale]) {
  final out = <String>[];
  final match = RegExp(
    r'^([a-z]{2,3})[-_]([A-Z]{2})',
  ).firstMatch(deviceLocale ?? Platform.localeName);
  if (match != null) out.add('${match.group(1)}_${match.group(2)}.UTF-8');
  for (final fallback in ['C.UTF-8', 'en_US.UTF-8']) {
    if (!out.contains(fallback)) out.add(fallback);
  }
  return out;
}

/// Starts `mosh-server` over [ssh], trying each of [locales] until one is
/// accepted.
Future<MoshServerInfo> startMoshServer(
  SessionTransport ssh, {
  String? command,
  String? server,
  List<String>? locales,
  Duration timeout = const Duration(seconds: 20),
}) async {
  MoshStartException? last;
  for (final locale in locales ?? moshLocales()) {
    final result = await RemoteExec.run(
      ssh,
      moshServerCommand(locale: locale, command: command, server: server),
      timeout: timeout,
    );
    try {
      return parseMoshServerOutput(result);
    } on MoshStartException catch (e) {
      if (e.kind != MoshStartFailure.locale) rethrow;
      last = e;
    }
  }
  throw last!;
}

/// Stops a `mosh-server` nobody connected to. Best effort.
Future<void> stopMoshServer(SessionTransport ssh, int pid) async {
  try {
    await RemoteExec.run(ssh, 'kill $pid', timeout: const Duration(seconds: 5));
  } catch (_) {
    // It times out on its own after a minute without a client anyway.
  }
}

/// Where to send datagrams: the address the SSH connection went to, as far
/// as it can be told.
///
/// `mosh-server -s` listens on the address in `$SSH_CONNECTION` — the one
/// the host saw the SSH connection arrive on. Behind NAT that is a private
/// address this device cannot reach, so the host name is resolved here too
/// and an address of the same family preferred; when the name resolves to
/// the very address the host reported, that one is used.
Future<InternetAddress> moshServerAddress(
  String hostname, {
  String? sshConnection,
  Future<List<InternetAddress>> Function(String host) lookup =
      InternetAddress.lookup,
}) async {
  final literal = _parseAddress(hostname);
  if (literal != null) return literal;

  final fields = sshConnection?.trim().split(RegExp(r'\s+'));
  final reported = fields != null && fields.length >= 3
      ? _parseAddress(fields[2])
      : null;

  List<InternetAddress> candidates;
  try {
    candidates = await lookup(hostname);
  } on SocketException {
    if (reported != null) return reported;
    rethrow;
  }
  if (candidates.isEmpty) {
    if (reported != null) return reported;
    throw SocketException('No address for $hostname');
  }
  if (reported != null) {
    for (final candidate in candidates) {
      if (candidate.address == reported.address) return candidate;
    }
    for (final candidate in candidates) {
      if (candidate.type == reported.type) return candidate;
    }
  }
  return candidates.first;
}

InternetAddress? _parseAddress(String text) {
  var value = text.trim();
  if (value.startsWith('[') && value.endsWith(']')) {
    value = value.substring(1, value.length - 1);
  }
  final zone = value.indexOf('%');
  if (zone >= 0) value = value.substring(0, zone);
  final mapped = RegExp(
    r'^::ffff:(\d+\.\d+\.\d+\.\d+)$',
    caseSensitive: false,
  ).firstMatch(value);
  if (mapped != null) value = mapped.group(1)!;
  return InternetAddress.tryParse(value);
}
