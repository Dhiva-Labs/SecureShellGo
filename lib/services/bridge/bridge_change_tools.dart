import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../../models/remote_entry.dart';
import '../editor_document.dart';
import '../editor_save.dart';
import '../remote_exec.dart';
import '../sftp_service.dart';
import '../shell_quote.dart';
import '../systemd_units.dart';
import 'bridge_approvals.dart';
import 'bridge_connections.dart';
import 'bridge_paths.dart';
import 'bridge_policy.dart';
import 'bridge_redactor.dart';
import 'bridge_tool_types.dart';
import 'bridge_tools.dart';

/// The commands the change tools run, apart from execution so the quoting
/// can be asserted character for character.
class BridgeChangeCommands {
  const BridgeChangeCommands._();

  /// [command], verbatim, run by the account's own shell — `"$SHELL" -c`,
  /// as `ssh host 'command'` and the app's "run on many servers"
  /// (`FleetExecService.wrap`) run it. The dispatcher runs this under
  /// [BridgeCommands.supervised], whose `/bin/sh` `exec`s the shell in its
  /// place: the shell keeps the process group the supervisor made, so a
  /// stopped call still ends the command and everything it started, and,
  /// as a background job of a non-interactive shell, its stdin is
  /// `/dev/null`. [command] reaches the shell as one single-quoted
  /// argument; nothing is added to it and nothing in it is interpreted
  /// by anything but that shell.
  static String accountShell(String command) =>
      r'exec "${SHELL:-/bin/sh}" -c '
      '${posixSingleQuote(command)}';

  /// The systemd command for [action] on [unit]: the services screen's own
  /// template for start, stop and restart, and its sibling for reload.
  static String serviceAction(String action, String unit) => switch (action) {
    'start' => SystemdCommands.action(ServiceAction.start, unit),
    'stop' => SystemdCommands.action(ServiceAction.stop, unit),
    'restart' => SystemdCommands.action(ServiceAction.restart, unit),
    'reload' => SystemdCommands.reload(unit),
    _ => throw ArgumentError.value(action, 'action'),
  };
}

/// What `run_command` and `run_on_hosts` will run: the command exactly as
/// the card shows it and as it is matched against the allowed list.
class BridgeCommandPlan extends BridgeChangePlan {
  BridgeCommandPlan({
    required this.command,
    required List<String> hostNames,
    super.matchesAllowedCommand,
    super.runTimeout,
  }) : super(
         summary: CommandSummary(command: command, hostNames: hostNames),
       );

  /// The one string that is shown, matched and run.
  final String command;

  @override
  CommandSummary get summary => super.summary as CommandSummary;
}

/// What `write_file` will write, and what the server looked like when the
/// card was built.
class BridgeWritePlan extends BridgeChangePlan {
  BridgeWritePlan({
    required this.path,
    required this.parent,
    required this.content,
    required this.bytes,
    required this.replacesExisting,
    required this.ifExists,
    required String preview,
    required FileWritePreviewKind previewKind,
    this.fingerprint = const RemoteFingerprint.unknown(),
    this.permissions,
  }) : super(
         summary: FileWriteSummary(
           path: path,
           bytes: bytes.length,
           replacesExisting: replacesExisting,
           preview: preview,
           previewKind: previewKind,
         ),
       );

  /// The canonical path written (the guard has passed it).
  final String path;

  /// Its directory, canonical.
  final String parent;
  final String content;
  final Uint8List bytes;
  final bool replacesExisting;
  final String ifExists;

  /// The replaced file's size and modification time when the card was
  /// built; a write finds anything else there and stops.
  final RemoteFingerprint fingerprint;

  /// The replaced file's mode, put back after the rename.
  final int? permissions;

  @override
  FileWriteSummary get summary => super.summary as FileWriteSummary;
}

/// What `service_action` will run.
class BridgeServicePlan extends BridgeChangePlan {
  BridgeServicePlan({required this.unit, required this.action})
    : command = BridgeChangeCommands.serviceAction(action, unit),
      super(
        summary: ServiceActionSummary(unit: unit, action: action),
        runTimeout: BridgeChangeTools.serviceRunTimeout,
      );

  final String unit;
  final String action;
  final String command;
}

/// The AI Bridge's tools that change a server: `run_command`,
/// `write_file`, `service_action` and `run_on_hosts`. All of kind
/// [BridgeToolKind.change]; the dispatcher in `bridge_tools.dart` decides
/// whether each call runs at once (allowed command, live grant), needs the
/// user's yes on a card, or is refused. Nothing here decides that: these
/// only validate, build the card's summary, and do exactly what it says.
class BridgeChangeTools {
  BridgeChangeTools({required this.redactor});

  /// Output is redacted per stream here, before it is capped and put
  /// together, so a cut never lands inside a key; the dispatcher redacts
  /// the whole answer again.
  final BridgeRedactor redactor;

  static const int maxCommandChars = 4096;
  static const int defaultTimeoutSeconds = 60;
  static const int maxTimeoutSeconds = 300;
  static const int maxWriteBytes = 256 * 1024;
  static const int minHosts = 2;
  static const int maxHosts = 10;
  static const int hostsAtOnce = 3;

  /// Each stream of `run_command` keeps at most this (its newest part).
  static const int streamBytes = 30 * 1024;

  /// All of `run_on_hosts`' output together stays under this.
  static const int totalBytes = 60 * 1024;

  /// The services screen gives a unit action 45 s; this adds the probe and
  /// connecting.
  static const Duration serviceRunTimeout = Duration(seconds: 60);

  /// The replaced file is shown as a diff only up to this size.
  static const int diffMaxBytes = 64 * 1024;
  static const int previewMaxLines = 60;
  static const int previewHeadLines = 20;
  static const int previewLineChars = 200;
  static const int auditCommandChars = 500;

  static const Set<String> serviceActions = {
    'start',
    'stop',
    'restart',
    'reload',
  };

  List<BridgeChangeTool> build() => [
    runCommand,
    writeFile,
    serviceAction,
    runOnHosts,
  ];

  static const Map<String, Object?> _hostProperty = {
    'type': 'string',
    'minLength': 1,
    'maxLength': BridgeTools.maxHostNameBytes,
    'description': 'A host name exactly as list_hosts returns it.',
  };

  static const Map<String, Object?> _commandProperty = {
    'type': 'string',
    'minLength': 1,
    'maxLength': maxCommandChars,
    'description':
        'The command, run by the account\'s login shell exactly as given '
        '(up to 4096 characters; leading and trailing white space is '
        'dropped; no NUL). It has no stdin and no terminal, so it must not '
        'wait for input; sudo cannot prompt for a password.',
  };

  static const String _askNote =
      ' The user is asked to approve it in SecureShell Go first, unless they '
      'have allowed it beforehand; say what you want to do and why before '
      'calling. If the user denies it, do not retry it or ask for it '
      'another way.';

  // ---------------------------------------------------------------- run_command

  late final BridgeChangeTool runCommand = BridgeChangeTool(
    spec: const BridgeToolSpec(
      name: 'run_command',
      description:
          'Runs one shell command on a server and returns its exit code, '
          'stdout and stderr (redacted and cut to the newest 30 KB each). '
          'The command is stopped after timeout_seconds (default 60, at most '
          '300), connecting included.$_askNote',
      inputSchema: {
        'type': 'object',
        'properties': {
          'host': _hostProperty,
          'command': _commandProperty,
          'timeout_seconds': {
            'type': 'integer',
            'minimum': 1,
            'maximum': maxTimeoutSeconds,
            'default': defaultTimeoutSeconds,
          },
        },
        'required': ['host', 'command'],
        'additionalProperties': false,
      },
      kind: BridgeToolKind.change,
    ),
    arguments: const {'host', 'command', 'timeout_seconds'},
    plan: (args, context) async {
      final command = commandArgument(args);
      final seconds = args.integer(
        'timeout_seconds',
        min: 1,
        max: maxTimeoutSeconds,
        fallback: defaultTimeoutSeconds,
      );
      return BridgeCommandPlan(
        command: command,
        hostNames: [context.hostName],
        matchesAllowedCommand: bridgeCommandIsAllowed(context.host, command),
        runTimeout: Duration(seconds: seconds),
      );
    },
    run: (call, plan) async {
      final p = plan as BridgeCommandPlan;
      final result = await call.exec(
        BridgeChangeCommands.accountShell(p.command),
      );
      return BridgeToolResult(_formatRun(result, streamBytes));
    },
    auditArgs: (args) => {
      'host': args['host'],
      'command': _auditCommand(args['command']),
      if (args['timeout_seconds'] != null)
        'timeout_seconds': args['timeout_seconds'],
    },
  );

  /// The `command` argument as it will be shown, matched and run: trimmed,
  /// 1–[maxCommandChars] characters, no NUL. Line breaks are allowed — a
  /// multi-line command is several commands, and the card shows every line.
  static String commandArgument(BridgeToolArgs args) {
    final value = args['command'];
    if (value == null) BridgeToolArgs.reject('command is required.');
    if (value is! String) BridgeToolArgs.reject('command must be a string.');
    if (value.contains('\u0000')) {
      BridgeToolArgs.reject('command must not contain a NUL.');
    }
    if (value.length > maxCommandChars) {
      BridgeToolArgs.reject(
        'command is longer than $maxCommandChars characters.',
      );
    }
    final command = value.trim();
    if (command.isEmpty) BridgeToolArgs.reject('command must not be empty.');
    if (command.length > maxCommandChars) {
      BridgeToolArgs.reject(
        'command is longer than $maxCommandChars characters.',
      );
    }
    return command;
  }

  static Object? _auditCommand(Object? value) {
    if (value is! String) return value == null ? null : '[not a string]';
    return value.length <= auditCommandChars
        ? value
        : '${value.substring(0, auditCommandChars)}…';
  }

  String _stream(String text, int maxBytes) => BridgeRedactor.capUtf8(
    redactor.redact(text, keepTail: true),
    maxBytes,
    keepTail: true,
  );

  String _formatRun(ExecResult result, int perStream) {
    final out = StringBuffer()
      ..writeln('exit_code: ${result.exitCode ?? 'none (ended by a signal)'}')
      ..writeln('stdout:')
      ..writeln(_stream(result.stdout, perStream))
      ..writeln('stderr:')
      ..write(_stream(result.stderr, perStream));
    return out.toString();
  }

  // ---------------------------------------------------------------- run_on_hosts

  late final BridgeChangeTool runOnHosts = BridgeChangeTool(
    spec: const BridgeToolSpec(
      name: 'run_on_hosts',
      description:
          'Runs one shell command on 2 to 10 servers, at most 3 at a time. '
          'Returns JSON: {"hosts": [{"host", "exit_code" (null when ended by '
          'a signal), "stdout", "stderr"} or {"host", "error"}]}, in the '
          'order given, each stream redacted and cut to its newest part so '
          'that the whole stays under 60 KB. Each server gets 60 seconds. '
          'One approval covers all of them; every host must allow '
          'changes.$_askNote',
      inputSchema: {
        'type': 'object',
        'properties': {
          'hosts': {
            'type': 'array',
            'items': _hostProperty,
            'minItems': minHosts,
            'maxItems': maxHosts,
            'uniqueItems': true,
          },
          'command': _commandProperty,
        },
        'required': ['hosts', 'command'],
        'additionalProperties': false,
      },
      kind: BridgeToolKind.change,
    ),
    arguments: const {'hosts', 'command'},
    hostsAtOnce: hostsAtOnce,
    plan: (args, context) async {
      final names = context.hostNames;
      if (names.length < minHosts || names.length > maxHosts) {
        BridgeToolArgs.reject(
          'hosts must name $minHosts to $maxHosts hosts (use run_command for '
          'one).',
        );
      }
      if (names.toSet().length != names.length) {
        BridgeToolArgs.reject('hosts must not name a host twice.');
      }
      final command = commandArgument(args);
      return BridgeCommandPlan(
        command: command,
        hostNames: names,
        // Allowed-command lists never apply to several hosts.
        matchesAllowedCommand: false,
        runTimeout: const Duration(seconds: defaultTimeoutSeconds),
      );
    },
    run: (call, plan) async {
      final p = plan as BridgeCommandPlan;
      final result = await call.exec(
        BridgeChangeCommands.accountShell(p.command),
      );
      // Structured, so one host's output can never pass for another's.
      return BridgeToolResult(
        jsonEncode({
          'exit_code': result.exitCode,
          'stdout': _stream(result.stdout, streamBytes),
          'stderr': _stream(result.stderr, streamBytes),
        }),
      );
    },
    combine: (outcomes, plan) => BridgeToolResult(
      hostsJson(outcomes, redactor),
      isError: outcomes.every((o) => o.isError),
    ),
    auditArgs: (args) => {
      'hosts': args['hosts'],
      'command': _auditCommand(args['command']),
    },
  );

  /// `run_on_hosts`' answer: `{"hosts": [...]}`, one entry per host in
  /// order, `{"host", "exit_code", "stdout", "stderr"}` for a host that ran
  /// and `{"host", "error"}` for one that did not. The streams arrive
  /// redacted; they and the errors are cut (newest part kept) to a budget
  /// per host that shrinks until the encoded whole is under [totalBytes],
  /// so the JSON is never cut mid-structure.
  static String hostsJson(
    List<BridgeHostOutcome> outcomes,
    BridgeRedactor redactor,
  ) {
    final parsed = <Map<String, Object?>>[];
    for (final o in outcomes) {
      Map<String, Object?>? ran;
      if (!o.isError) {
        try {
          final decoded = jsonDecode(o.text);
          if (decoded is Map<String, Object?>) ran = decoded;
        } on FormatException {
          ran = null;
        }
      }
      parsed.add(
        ran == null
            ? {'host': o.hostName, 'error': redactor.redact(o.text)}
            : {
                'host': o.hostName,
                'exit_code': ran['exit_code'],
                'stdout': '${ran['stdout'] ?? ''}',
                'stderr': '${ran['stderr'] ?? ''}',
              },
      );
    }
    var budget = streamBytes;
    while (true) {
      final encoded = jsonEncode({
        'hosts': [
          for (final e in parsed)
            {
              for (final entry in e.entries)
                entry.key: entry.value is String && entry.key != 'host'
                    ? BridgeRedactor.capUtf8(
                        entry.value! as String,
                        budget,
                        keepTail: true,
                      )
                    : entry.value,
            },
        ],
      });
      if (utf8.encode(encoded).length <= totalBytes || budget <= 64) {
        return encoded;
      }
      budget = budget * 2 ~/ 3;
    }
  }

  // ---------------------------------------------------------------- service_action

  late final BridgeChangeTool serviceAction = BridgeChangeTool(
    spec: const BridgeToolSpec(
      name: 'service_action',
      description:
          'Starts, stops, restarts or reloads one systemd unit with '
          'systemctl, as the account the user connects as. A unit that needs '
          'more privilege than that fails; nothing can answer a password '
          'prompt.$_askNote',
      inputSchema: {
        'type': 'object',
        'properties': {
          'host': _hostProperty,
          'unit': {
            'type': 'string',
            'minLength': 1,
            'maxLength': 256,
            'pattern': r'^[A-Za-z0-9_.@:\\][A-Za-z0-9_.@:\\-]*$',
            'description': 'A systemd unit name, e.g. nginx.service.',
          },
          'action': {
            'type': 'string',
            'enum': ['start', 'stop', 'restart', 'reload'],
          },
        },
        'required': ['host', 'unit', 'action'],
        'additionalProperties': false,
      },
      kind: BridgeToolKind.change,
    ),
    arguments: const {'host', 'unit', 'action'},
    plan: (args, context) async {
      final unit = args.string('unit', maxBytes: 256)!;
      if (!BridgeTools.isUnitName(unit)) {
        BridgeToolArgs.reject('unit is not a systemd unit name.');
      }
      final action = args.string('action', maxBytes: 16)!;
      if (!serviceActions.contains(action)) {
        BridgeToolArgs.reject(
          'action must be one of start, stop, restart, reload.',
        );
      }
      return BridgeServicePlan(unit: unit, action: action);
    },
    run: (call, plan) async {
      final p = plan as BridgeServicePlan;
      final probe = await call.exec(SystemdCommands.probe);
      if (!probe.succeeded) throw const SystemdUnavailable();
      final result = await call.exec(p.command);
      if (!result.succeeded) {
        final stderr = result.stderr.toLowerCase();
        if (stderr.contains('has not been booted with systemd') ||
            stderr.contains('failed to connect to bus')) {
          throw const SystemdUnavailable();
        }
        throw monitorFailureFrom(result, 'Could not ${p.action} ${p.unit}');
      }
      final said = result.stdout.trim();
      return BridgeToolResult(
        'systemctl ${p.action} ${p.unit}: done.'
        '${said.isEmpty ? '' : '\n$said'}',
      );
    },
  );

  // ---------------------------------------------------------------- write_file

  late final BridgeChangeTool writeFile = BridgeChangeTool(
    spec: const BridgeToolSpec(
      name: 'write_file',
      description:
          'Writes a text file on a server (UTF-8, at most 262144 bytes, no '
          'NUL). The parent directory must exist. With if_exists "fail" (the '
          'default) an existing file is left alone; with "replace" it is '
          'replaced, keeping its mode. A symlink is followed to the file it '
          'points at, and that file is what is written. If the file changes '
          'after the user is asked, nothing is written.$_askNote',
      inputSchema: {
        'type': 'object',
        'properties': {
          'host': _hostProperty,
          'path': {
            'type': 'string',
            'minLength': 1,
            'maxLength': BridgePathGuard.maxPathBytes,
            'description':
                'An absolute path on the server, or one relative to the home '
                'directory (at most 4096 bytes; no line break or NUL).',
          },
          'content': {
            'type': 'string',
            'maxLength': maxWriteBytes,
            'description':
                'The whole new content of the file: text, at most 262144 '
                'bytes as UTF-8, no NUL.',
          },
          'if_exists': {
            'type': 'string',
            'enum': ['fail', 'replace'],
            'default': 'fail',
          },
        },
        'required': ['host', 'path', 'content'],
        'additionalProperties': false,
      },
      kind: BridgeToolKind.change,
    ),
    arguments: const {'host', 'path', 'content', 'if_exists'},
    plan: _planWrite,
    run: _runWrite,
    auditArgs: (args) {
      final content = args['content'];
      return {
        'host': args['host'],
        'path': args['path'],
        'bytes': content is String ? utf8.encode(content).length : null,
        'if_exists': args['if_exists'] ?? 'fail',
      };
    },
  );

  static String _contentArgument(BridgeToolArgs args) {
    final value = args['content'];
    if (value == null) BridgeToolArgs.reject('content is required.');
    if (value is! String) BridgeToolArgs.reject('content must be a string.');
    if (value.contains('\u0000')) {
      BridgeToolArgs.reject(
        'content must be text: it contains a NUL, so it looks binary.',
      );
    }
    return value;
  }

  static String _ifExistsArgument(BridgeToolArgs args) {
    final value = args['if_exists'];
    if (value == null) return 'fail';
    if (value != 'fail' && value != 'replace') {
      BridgeToolArgs.reject('if_exists must be "fail" or "replace".');
    }
    return value as String;
  }

  static Future<BridgeFileWrites> _writes(BridgeCallContext call) async {
    final fs = await call.files();
    if (fs is! BridgeFileWrites) {
      throw const MonitorFailure('This connection cannot write files.');
    }
    return fs as BridgeFileWrites;
  }

  static String _parentOf(String canonical) {
    final i = canonical.lastIndexOf('/');
    return i <= 0 ? '/' : canonical.substring(0, i);
  }

  static String _join(String dir, String name) =>
      dir == '/' ? '/$name' : '$dir/$name';

  /// Where a write to [raw] would land, decided the way a read decides:
  /// resolved on the server, then the guard.
  ///
  /// - An existing path is resolved with symlinks followed, and the file
  ///   it ends at is what is written (and what the guard judged). A link
  ///   is never replaced by a file, and a link into a blocked directory is
  ///   refused exactly as a read of it is.
  /// - A path that does not resolve is a new file: its directory must
  ///   resolve (it is not created), the guard is put to the full new path,
  ///   and nothing at all may be there — a dangling symlink, or anything
  ///   the server would not resolve, is refused as `path_not_available`.
  static Future<({String path, String parent, BridgeEntryKind kind})> _target(
    BridgeCallContext call,
    BridgeFileWrites writes,
    String raw,
  ) async {
    if (raw.startsWith('/') && call.guard.isBlocked(raw)) {
      BridgeToolArgs.refuse(BridgeToolRefusals.pathNotAvailable);
    }
    String? canonical;
    try {
      canonical = await call.guardedPath(raw);
    } on TimeoutException {
      rethrow;
    } catch (_) {
      canonical = null;
    }
    if (canonical != null) {
      final kind = await call.bounded(writes.entryKind(canonical));
      // realpath did not follow it: never write through a link blindly.
      if (kind == BridgeEntryKind.symlink) {
        BridgeToolArgs.refuse(BridgeToolRefusals.pathNotAvailable);
      }
      return (path: canonical, parent: _parentOf(canonical), kind: kind);
    }
    if (raw.endsWith('/')) {
      BridgeToolArgs.reject('path must name a file, not a directory.');
    }
    final i = raw.lastIndexOf('/');
    final name = i < 0 ? raw : raw.substring(i + 1);
    final parentRaw = i < 0 ? '.' : (i == 0 ? '/' : raw.substring(0, i));
    if (name.isEmpty || name == '.' || name == '..') {
      BridgeToolArgs.reject('path must name a file.');
    }
    // Refused the same way when the directory is missing as when blocked.
    final parent = await call.guardedPath(parentRaw);
    final path = _join(parent, name);
    if (call.guard.isBlocked(path)) {
      BridgeToolArgs.refuse(BridgeToolRefusals.pathNotAvailable);
    }
    final kind = await call.bounded(writes.entryKind(path));
    if (kind != BridgeEntryKind.missing) {
      BridgeToolArgs.refuse(BridgeToolRefusals.pathNotAvailable);
    }
    return (path: path, parent: parent, kind: kind);
  }

  Future<BridgeChangePlan> _planWrite(
    BridgeToolArgs args,
    BridgePlanContext context,
  ) async {
    final raw = args.path('path');
    final content = _contentArgument(args);
    final ifExists = _ifExistsArgument(args);
    final bytes = Uint8List.fromList(utf8.encode(content));
    if (bytes.length > maxWriteBytes) {
      BridgeToolArgs.reject('content is longer than $maxWriteBytes bytes.');
    }
    return context.withServer((call) async {
      final writes = await _writes(call);
      final target = await _target(call, writes, raw);
      final path = target.path;
      switch (target.kind) {
        case BridgeEntryKind.directory:
          throw MonitorFailure('$path is a directory.');
        case BridgeEntryKind.other:
        case BridgeEntryKind.symlink:
          throw MonitorFailure('$path is not a regular file.');
        case BridgeEntryKind.missing:
          final parentKind = await call.bounded(
            writes.entryKind(target.parent),
          );
          if (parentKind != BridgeEntryKind.directory) {
            throw MonitorFailure(
              '${target.parent} is not a directory; it is not created.',
            );
          }
          final shown = _shown(_headPreview(content, 'New file'), content);
          return BridgeWritePlan(
            path: path,
            parent: target.parent,
            content: content,
            bytes: bytes,
            replacesExisting: false,
            ifExists: ifExists,
            preview: shown.text,
            previewKind: shown.kind,
          );
        case BridgeEntryKind.file:
          break;
      }
      if (ifExists != 'replace') {
        throw MonitorFailure(
          '$path already exists; nothing was written. Pass if_exists '
          '"replace" to replace it.',
        );
      }
      final stat = await call.bounded(writes.remoteMetadata.statFile(path));
      if (stat == null) {
        throw MonitorFailure('$path could not be examined on the server.');
      }
      if (stat.size == null && stat.modified == null) {
        // Nothing to compare at write time: "changed after you were asked,
        // nothing is written" could not hold, so a replacement is not made.
        throw MonitorFailure(
          'The server reports neither the size nor the modification time of '
          '$path, so a replacement could not be checked against a change '
          'after the user is asked. Nothing was written.',
        );
      }
      String? old;
      final size = stat.size;
      if (size != null && size <= diffMaxBytes) {
        final fs = await call.files();
        final window = await call.bounded(
          fs.read(path, offset: 0, length: diffMaxBytes + 1),
        );
        if (window.length <= diffMaxBytes && !looksBinary(window)) {
          old = utf8.decode(window, allowMalformed: true);
        }
      }
      final rawPreview = old == null
          ? _headPreview(
              content,
              'Replaces a file of ${size ?? 'unknown'} bytes (no diff: it is '
              '${size != null && size > diffMaxBytes ? 'too large' : 'not text'}'
              '). New content',
            )
          : _diffPreview(path, _safe(old), _safe(content));
      final shown = _shown(
        rawPreview,
        content,
        diff: old != null,
        oldShown: old != null,
        alsoRedacted: old != null && _safe(old) != old,
      );
      return BridgeWritePlan(
        path: path,
        parent: target.parent,
        content: content,
        bytes: bytes,
        replacesExisting: true,
        ifExists: ifExists,
        preview: shown.text,
        previewKind: shown.kind,
        fingerprint: RemoteFingerprint(
          size: stat.size,
          modified: stat.modified,
        ),
        permissions: stat.permissions,
      );
    });
  }

  /// Through the redactor, never capped by it past the preview's own bound.
  String _safe(String text) => redactor.redact(text);

  /// [preview] made safe, and ended by lines that say what it is, so the
  /// card can never pass a part for the whole: the card's own byte count is
  /// the full size. A line cut at [previewLineChars] and text the redactor
  /// hid are said as well. [diff] is a diff of the replaced file;
  /// [oldShown] is false when the file it replaces could not be shown.
  ///
  /// The kind returned says the same as those lines, for the card to show
  /// prominently: partial when lines are left out or cut, or text is hidden.
  ({String text, FileWritePreviewKind kind}) _shown(
    String preview,
    String content, {
    bool diff = false,
    bool oldShown = true,
    bool alsoRedacted = false,
  }) {
    final safe = _safe(preview);
    final cut = preview
        .split('\n')
        .any((l) => l.length > previewLineChars && l.endsWith('…'));
    final more = diff
        ? preview.contains('more diff lines]')
        : const LineSplitter().convert(content).length > previewHeadLines;
    final out = StringBuffer(safe);
    if (!safe.endsWith('\n')) out.writeln();
    final hidden = safe != preview || alsoRedacted;
    final partial = more || cut || hidden;
    final kind = diff
        ? (partial
              ? FileWritePreviewKind.partialDiff
              : FileWritePreviewKind.fullDiff)
        : (partial
              ? FileWritePreviewKind.partialContent
              : FileWritePreviewKind.fullContent);
    if (hidden) {
      out.writeln('[Some text above is hidden: it looks like a secret.]');
    }
    if (cut) {
      out.writeln('[Long lines are cut at $previewLineChars characters.]');
    }
    if (partial) {
      out.write(
        diff
            ? '[This diff is NOT complete: more changes follow than are '
                  'shown.]'
            : '[This preview is NOT the whole file: more will be written '
                  'than is shown (see the byte count).]',
      );
    } else if (diff) {
      out.write(
        '[This diff shows every change; the rest of the file stays as it '
        'is.]',
      );
    } else {
      out.write(
        oldShown
            ? '[This preview shows everything that will be written.]'
            : '[This preview shows everything that will be written; the '
                  'file it replaces is not shown.]',
      );
    }
    return (text: out.toString(), kind: kind);
  }

  static String _clipLine(String line) => line.length <= previewLineChars
      ? line
      : '${line.substring(0, previewLineChars)}…';

  static String _headPreview(String content, String title) {
    final lines = const LineSplitter().convert(content);
    final out = StringBuffer('$title, first lines:\n');
    for (final l in lines.take(previewHeadLines)) {
      out.writeln(_clipLine(l));
    }
    if (lines.length > previewHeadLines) {
      out.writeln('[${lines.length - previewHeadLines} more lines]');
    }
    if (lines.isEmpty) out.writeln('[empty]');
    return out.toString();
  }

  /// A unified-style diff of one hunk: the common head and tail are left
  /// out (two lines of context kept), the rest shown as removed and added.
  /// At most [previewMaxLines] lines.
  static String _diffPreview(String path, String old, String now) {
    final a = const LineSplitter().convert(old);
    final b = const LineSplitter().convert(now);
    if (old == now) return 'No change: the new content is identical.\n';
    var head = 0;
    while (head < a.length && head < b.length && a[head] == b[head]) {
      head++;
    }
    if (head == a.length && head == b.length) {
      // Every line equal, the text not: only the breaks between them differ.
      return '--- $path (now)\n+++ $path (new)\n'
          'Only line breaks differ (CRLF or LF, or a final line break): no '
          'line of text changes.\n';
    }
    var tail = 0;
    while (tail < a.length - head &&
        tail < b.length - head &&
        a[a.length - 1 - tail] == b[b.length - 1 - tail]) {
      tail++;
    }
    const context = 2;
    final from = head - context < 0 ? 0 : head - context;
    final aEnd = a.length - tail;
    final bEnd = b.length - tail;
    final aCtxEnd = aEnd + context > a.length ? a.length : aEnd + context;
    final bCtxEnd = bEnd + context > b.length ? b.length : bEnd + context;
    final lines = <String>[
      '--- $path (now)',
      '+++ $path (new)',
      '@@ -${from + 1},${aCtxEnd - from} +${from + 1},${bCtxEnd - from} @@',
      for (var i = from; i < head; i++) ' ${_clipLine(a[i])}',
      for (var i = head; i < aEnd; i++) '-${_clipLine(a[i])}',
      for (var i = head; i < bEnd; i++) '+${_clipLine(b[i])}',
      for (var i = aEnd; i < aCtxEnd; i++) ' ${_clipLine(a[i])}',
    ];
    final out = StringBuffer();
    for (final l in lines.take(previewMaxLines)) {
      out.writeln(l);
    }
    if (lines.length > previewMaxLines) {
      out.writeln('[${lines.length - previewMaxLines} more diff lines]');
    }
    return out.toString();
  }

  static final Random _random = Random.secure();

  /// `.<name>.ssg-bridge-<ms>-<64 random bits>`. The editor's temp file is
  /// opened without O_EXCL, and what is opened at a name that already holds
  /// a symlink is whatever the link points at (and the rename would then put
  /// the link itself in the file's place), so the name must not be
  /// guessable by someone who can write in the directory. The name's own
  /// part is cut to 150 UTF-8 bytes so the whole stays under a server's 255.
  static String _temporaryName(String finalName) {
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final nonce = [
      for (var i = 0; i < 8; i++)
        _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();
    var head = finalName;
    while (utf8.encode(head).length > 150) {
      head = head.substring(0, head.length - 1);
    }
    return '.$head.ssg-bridge-$stamp-$nonce';
  }

  static Future<BridgeToolResult> _runWrite(
    BridgeCallContext call,
    BridgeChangePlan plan,
  ) {
    final p = plan as BridgeWritePlan;
    return call.commit(
      () => _write(call, p),
      ifStopped:
          'Nothing was written: ${p.path} on the server is as it was'
          '${p.replacesExisting ? '' : ' (not created)'}.',
    );
  }

  /// The write, inside the call's commit: a stop before the rename leaves
  /// the file as it was (the temporary file removed on the still-open
  /// channel) and is reported as such; once the rename has begun it runs to
  /// its end, and a write that landed is reported as done.
  static Future<BridgeToolResult> _write(
    BridgeCallContext call,
    BridgeWritePlan p,
  ) async {
    final path = p.path;
    const changed =
        'changed on the server after the user was asked, so nothing was '
        'written. Read it again before asking for another change.';
    final BridgeFileWrites writes;
    try {
      writes = await _writes(call);
      // Still the place the card named, still allowed by the guard.
      if (p.replacesExisting) {
        String? again;
        try {
          again = await call.guardedPath(path);
        } on TimeoutException {
          rethrow;
        } catch (_) {
          again = null;
        }
        final kind = again == null
            ? BridgeEntryKind.missing
            : await call.bounded(writes.entryKind(path));
        if (again != path || kind != BridgeEntryKind.file) {
          throw MonitorFailure('$path $changed');
        }
      } else {
        final parent = await call.guardedPath(p.parent);
        if (parent != p.parent || call.guard.isBlocked(path)) {
          BridgeToolArgs.refuse(BridgeToolRefusals.pathNotAvailable);
        }
        final kind = await call.bounded(writes.entryKind(path));
        if (kind != BridgeEntryKind.missing) {
          throw MonitorFailure(
            '$path was created on the server after the user was asked, so '
            'nothing was written.',
          );
        }
      }
    } on TimeoutException {
      if (call.isStopped) throw const BridgeStoppedBeforeChange();
      rethrow;
    }

    final fs = _StoppableFiles(writes.remoteFileSystem, call);
    final SaveOutcome saved;
    try {
      saved = await saveRemoteText(
        fs: fs,
        metadata: writes.remoteMetadata,
        path: path,
        text: p.content,
        // LF: the text is written exactly as given, `\r` and all.
        lineEndings: LineEndingStyle.lf,
        expected: p.fingerprint,
        permissions: p.replacesExisting ? p.permissions : null,
        // A new file has no baseline; it was checked to be absent above.
        force: !p.replacesExisting,
        temporaryNamer: _temporaryName,
      );
    } on EditorSaveConflict {
      throw MonitorFailure('$path $changed');
    } on EditorSaveFailure catch (e) {
      throw MonitorFailure(e.message, details: e.details);
    } catch (_) {
      // Before the rename, a stop (or a failure while stopped) has left the
      // original as it was; the temporary file was removed on the way out.
      if (!fs.pastNoReturn && call.isStopped) {
        throw const BridgeStoppedBeforeChange();
      }
      rethrow;
    }
    final out = StringBuffer(
      'Wrote ${saved.bytesWritten} bytes to $path '
      '(${p.replacesExisting ? 'replaced the existing file' : 'new file'}).',
    );
    if (saved.permissionsLost) {
      out.write(' The server would not restore the file\'s mode.');
    }
    return BridgeToolResult(out.toString());
  }
}

/// The editor's filesystem, for one write: up to the rename (the point of
/// no return) every step first checks whether the call was stopped, and
/// gives up if so, which makes `saveRemoteText` remove its temporary file.
/// From the rename on, nothing is checked: the change is let finish.
class _StoppableFiles implements RemoteFileSystem {
  _StoppableFiles(this._inner, this._call);

  final RemoteFileSystem _inner;
  final BridgeCallContext _call;

  /// True once the rename onto the real name has been asked for.
  var pastNoReturn = false;

  void _check() {
    if (!pastNoReturn && _call.isStopped) {
      throw const BridgeStoppedBeforeChange();
    }
  }

  @override
  Future<RemoteFileWriter> openWrite(String remotePath) async {
    _check();
    return _StoppableWriter(await _inner.openWrite(remotePath), this);
  }

  @override
  Future<int?> sizeOf(String path) async {
    _check();
    return _inner.sizeOf(path);
  }

  @override
  Future<void> rename(String from, String to) {
    _check();
    pastNoReturn = true;
    return _inner.rename(from, to);
  }

  @override
  Future<void> remove(String path) => _inner.remove(path);

  @override
  Future<bool> exists(String path) => _inner.exists(path);

  @override
  Future<String> home() => _inner.home();

  @override
  Future<String> resolve(String path) => _inner.resolve(path);

  @override
  Future<List<RemoteEntry>> list(String path) => _inner.list(path);

  @override
  Future<int> download(
    String remotePath, {
    required Future<void> Function(Uint8List chunk) write,
    TransferProgress? onProgress,
    CancelCheck? isCancelled,
  }) => throw UnsupportedError('not used by a write');

  @override
  Future<int> upload(
    String localPath,
    String remotePath, {
    TransferProgress? onProgress,
    CancelCheck? isCancelled,
  }) => throw UnsupportedError('not used by a write');

  @override
  Future<void> mkdir(String path) =>
      throw UnsupportedError('not used by a write');

  @override
  Future<void> removeDirectory(String path) =>
      throw UnsupportedError('not used by a write');

  @override
  Future<bool> isDirectory(String path) => _inner.isDirectory(path);

  @override
  Future<void> close() async {}
}

class _StoppableWriter implements RemoteFileWriter {
  _StoppableWriter(this._inner, this._files);

  final RemoteFileWriter _inner;
  final _StoppableFiles _files;

  @override
  Future<void> add(Uint8List chunk) {
    _files._check();
    return _inner.add(chunk);
  }

  @override
  Future<void> close() {
    _files._check();
    return _inner.close();
  }

  @override
  Future<void> abort() => _inner.abort();
}
