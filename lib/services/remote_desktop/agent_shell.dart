import 'dart:convert';
import 'dart:math';

import '../remote_exec.dart';
import '../shell_quote.dart';
import '../ssh_service.dart';
import 'agent_failure.dart';

/// The pieces every remote-desktop command is built from, kept apart from
/// running them so the exact text can be asserted — and, for the POSIX
/// ones, run through a real `sh` — in tests.
///
/// **POSIX.** Every Linux script goes to the server as
/// `sh -c '<script>'`, with the script through [posixSingleQuote], the way
/// `remote_file_ops.dart` does it: the account's login shell may be bash,
/// zsh or fish, and only `sh` is promised. The scripts never contain a
/// doubled backslash or a backslash before a quote, because fish — alone
/// among those shells — still reads those two escapes inside single quotes
/// and would change the script on its way to `sh`.
///
/// **Windows.** OpenSSH for Windows hands the command line to whichever
/// shell the machine is configured with, `cmd.exe` by default and
/// PowerShell on many machines, and the two quote nothing alike. So every
/// Windows command is `powershell -EncodedCommand <base64>`: the base64
/// alphabet means nothing to either shell, the script arrives byte for byte,
/// and nothing in it needs quoting for the trip.
class AgentShell {
  const AgentShell._();

  /// The line prefix that starts a section of a probe's output, shared with
  /// `server_probe.dart`'s `splitProbeSections`.
  static const String marker = '#=ssg=';

  /// [script] as one `sh -c` command line, with [args] as its `$1`, `$2`…
  ///
  /// Anything that varies — a path, a user's command, an environment value
  /// — goes in [args], never spliced into [script]. Quoting a value inside a
  /// script that is quoted again for the trip nests the escapes, and the
  /// nested form is exactly what fish misreads.
  static String sh(String script, [List<String> args = const []]) {
    final out = StringBuffer('sh -c ${posixSingleQuote(script)}');
    if (args.isNotEmpty) {
      out.write(' ssgo');
      for (final arg in args) {
        out.write(' ${posixSingleQuote(arg)}');
      }
    }
    return out.toString();
  }

  /// [script] as a PowerShell command line that survives `cmd.exe`,
  /// PowerShell and an MSYS bash as the outer shell alike.
  ///
  /// `-EncodedCommand` takes UTF-16LE base64. The prelude switches output to
  /// UTF-8 without a byte-order mark — PowerShell otherwise writes through
  /// the console's OEM code page, which turns any non-ASCII user name in a
  /// path into question marks — and silences progress records, which on a
  /// redirected stdout come out as CLIXML noise on stderr.
  static String powershell(String script) {
    final full = '$powershellPrelude\n$script';
    final units = <int>[];
    for (final unit in full.codeUnits) {
      units
        ..add(unit & 0xff)
        ..add(unit >> 8);
    }
    return 'powershell -NoLogo -NoProfile -NonInteractive '
        '-EncodedCommand ${base64.encode(units)}';
  }

  /// The longest command line `cmd.exe` accepts is 8191 characters; this
  /// leaves headroom for the `cmd /c` OpenSSH wraps it in.
  static const int maxWindowsCommandLength = 8000;

  static const String powershellPrelude =
      r"$ProgressPreference='SilentlyContinue'"
      '\n'
      r'try{[Console]::OutputEncoding=New-Object Text.UTF8Encoding $false}catch{}';

  /// A PowerShell single-quoted string literal: only `'` is special inside
  /// one, and it is doubled.
  static String psQuote(String value) => "'${value.replaceAll("'", "''")}'";

  /// A shell function, `ssg_hash FILE`, printing the file's SHA-256 in
  /// lowercase hex, or nothing when no tool on the server can compute it.
  ///
  /// The tools in the order they are most likely to be there: coreutils and
  /// BusyBox `sha256sum`, Perl's `shasum` (macOS, the BSDs, minimal
  /// images with Perl), OpenSSL, and the BSDs' `sha256`. Every one of them
  /// prints the digest first, so the first 64 characters are the answer.
  static const String shHashFunction = 'ssg_hash() { '
      '{ sha256sum "\$1" 2>/dev/null || shasum -a 256 "\$1" 2>/dev/null || '
      'openssl dgst -sha256 -r "\$1" 2>/dev/null || sha256 -q "\$1" 2>/dev/null; } '
      '| cut -c1-64 | tr A-F a-f; }';

  /// Whether any of [shHashFunction]'s tools exists, as a shell condition.
  static const String shHasHashTool =
      'command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 || '
      'command -v openssl >/dev/null 2>&1 || command -v sha256 >/dev/null 2>&1';

  /// A PowerShell function, `SsgHash <path>`, printing a file's SHA-256 in
  /// lowercase hex, or nothing for a file it cannot read. `Get-FileHash` is
  /// in every PowerShell from 4 on, and the agent needs Windows 10, which
  /// ships 5.1 — the same digest `certutil -hashfile` gives, without its
  /// version-dependent output to parse.
  ///
  /// Not a short name: PowerShell resolves aliases before functions, and
  /// the obvious one-letter names are taken — `H` is `Get-History`, which
  /// took the path for a history id and made every upload look corrupt.
  static const String psHashFunction = r'function SsgHash($p){try{(Get-FileHash '
      r"-Algorithm SHA256 -LiteralPath $p -ErrorAction Stop).Hash.ToLower()}catch{''}}";

  /// Makes `XDG_RUNTIME_DIR` point at the user's runtime directory when an
  /// SSH login did not set it — no `pam_systemd`, or a `su` in between.
  /// Without it `systemctl --user` cannot find the user manager at all and
  /// says "Failed to connect to bus", which reads like systemd is missing.
  static const String shRuntimeDir = 'ssg_u=\$(id -u); '
      'if [ -z "\${XDG_RUNTIME_DIR:-}" ] && [ -d "/run/user/\$ssg_u" ] && '
      '[ -O "/run/user/\$ssg_u" ]; then XDG_RUNTIME_DIR="/run/user/\$ssg_u"; '
      'export XDG_RUNTIME_DIR; fi';

  /// Whether this login can start units in the user's systemd manager.
  /// `systemd-run` alone is not enough: a container or a box without
  /// `pam_systemd` has the binary and no manager to talk to.
  static const String shHasUserSystemd =
      'command -v systemd-run >/dev/null 2>&1 && '
      'systemctl --user show-environment >/dev/null 2>&1';

  /// A portable sub-second sleep: GNU and BusyBox `sleep` take fractions,
  /// POSIX only promises whole seconds.
  static const String shShortSleep = 'sleep 0.2 2>/dev/null || sleep 1';

  /// 64 random bits as hex: the per-launch suffix of unit, task and runtime
  /// directory names. Hex only, so it can sit unquoted in a shell word, a
  /// unit name and a Windows path alike.
  static String newId([Random? random]) {
    final r = random ?? Random.secure();
    return List<String>.generate(
      8,
      (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  static final RegExp idPattern = RegExp(r'^[0-9a-f]{16}$');

  /// Runs [command], turning a channel that could not be opened or that
  /// timed out into an [AgentFailure]. The exit code is left to the caller,
  /// as [RemoteExec.run] leaves it: these scripts report through markers.
  static Future<ExecResult> run(
    SessionTransport transport,
    String command, {
    Duration timeout = RemoteExec.defaultTimeout,
    required String what,
  }) async {
    try {
      return await RemoteExec.run(transport, command, timeout: timeout);
    } catch (e) {
      throw AgentFailure(
        AgentFailureKind.transport,
        'Could not $what on the server.',
        details: e.toString(),
      );
    }
  }

  /// The output as lines, with a Windows byte-order mark and carriage
  /// returns gone.
  static List<String> lines(String output) {
    final text = output.startsWith('﻿') ? output.substring(1) : output;
    return const LineSplitter().convert(text);
  }

  /// The first line starting with [prefix], without the prefix, or null.
  static String? valueAfter(List<String> lines, String prefix) {
    for (final line in lines) {
      if (line.startsWith(prefix)) return line.substring(prefix.length).trim();
    }
    return null;
  }

  /// The text between a line equal to [start] and the next line equal to
  /// [end] — how `host.json` is carried out of a launch script — or null.
  static String? between(List<String> lines, String start, String end) {
    final from = lines.indexOf(start);
    if (from < 0) return null;
    final to = lines.indexOf(end, from + 1);
    if (to < 0) return null;
    return lines.sublist(from + 1, to).join('\n');
  }

  /// Everything after a line equal to [start], for log tails.
  static String after(List<String> lines, String start) {
    final from = lines.indexOf(start);
    if (from < 0) return '';
    return lines.sublist(from + 1).join('\n').trim();
  }
}
