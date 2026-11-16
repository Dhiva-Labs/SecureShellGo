/// The phone controller's wire protocol: what a paired phone and this
/// computer's AI Bridge say to each other over a control session
/// (`secureshellgo-mcp control`, see `bridge_control.dart` for the app side
/// and `services/bridge_remote/` for the phone side).
///
/// JSON, one message per line, both ways. Every message is an object with a
/// `type`.
///
/// App to phone:
///
/// - `snapshot`: the whole state (lock, the "allow for a while" length,
///   live grants, assistant terminals/desktops/jobs, recent activity). Sent
///   first, and again whenever the state is reset (the app locks or
///   unlocks). Each snapshot replaces everything the phone holds, approvals
///   included; the waiting approvals follow it one `approval` each, then
///   `synced`.
/// - `approval` (one card, already in its visible-safe form),
///   `approval_removed` (answered, timed out or withdrawn), `grants` and
///   `items` (the whole list again), `activity` (one new entry), `state`.
/// - `result`: the answer to one request, matched by its `re`.
/// - `error`: about the session itself (too many phones, a malformed line).
///
/// Phone to app: `answer`, `stop_grant`, `stop_item`, `ping`, each with a
/// `re` the result echoes. Nothing else exists: a phone cannot pair, change
/// a setting or a host's access, or call a tool, because there is no message
/// for it.
///
/// Pure Dart with no `dart:io`, so the launcher, the app and the phone all
/// use the same definitions.
library;

import 'dart:convert';

import '../visible_text.dart';

/// Bumped only for a change the other end could not read.
const int bridgeControlProtocolVersion = 1;

/// The longest line the app takes from a phone. Requests are a few hundred
/// bytes; anything longer is refused with [ControlErrorCode.tooLarge].
const int bridgeControlMaxInboundLineBytes = 64 * 1024;

/// The longest line a phone takes from the app. One approval card with a
/// file preview whose every character needed a stand-in is the largest
/// message, well under this.
const int bridgeControlMaxOutboundLineBytes = 1024 * 1024;

/// Phones that may hold a control session at once.
const int bridgeControlMaxSessions = 2;

/// How many recent activity entries a snapshot carries.
const int bridgeControlActivityLimit = 50;

/// The longest assistant or host name sent, in characters, as on the card.
const int bridgeControlMaxNameChars = 60;

/// The longest request id (`re`) or item id the app accepts.
const int bridgeControlMaxIdChars = 256;

/// Why a request or a session failed.
enum ControlErrorCode {
  /// Not JSON, not an object, or a field of the wrong type.
  malformed('malformed'),

  /// A `type` this protocol does not have.
  unknownType('unknown_type'),

  /// A line past [bridgeControlMaxInboundLineBytes].
  tooLarge('too_large'),

  /// The computer's app is locked: nothing can be done from the phone.
  locked('locked'),

  /// The approval, grant or item is not there (any more): answered,
  /// withdrawn, timed out, stopped, or never existed.
  notFound('not_found'),

  /// Not something the desktop's settings allow (e.g. "allow for a while"
  /// when it is off, or for a length other than the configured one).
  notAllowed('not_allowed'),

  /// [bridgeControlMaxSessions] phones are connected already.
  tooManySessions('too_many_sessions'),

  /// From the launcher: the app is not running, or its AI Bridge is off.
  notRunning('not_running'),

  /// From the launcher: the app refused the phone (not paired, pairing
  /// removed, or Phone control switched off; these read the same).
  refused('refused'),

  /// From the phone's command: no launcher was found on the computer.
  launcherNotFound('launcher_not_found'),

  /// Anything else.
  failed('failed');

  const ControlErrorCode(this.wire);

  final String wire;

  static ControlErrorCode fromWire(Object? value) {
    for (final c in values) {
      if (c.wire == value) return c;
    }
    return failed;
  }
}

/// A phone's answer to a card.
enum ControlAnswer {
  deny('deny'),
  once('once'),

  /// "Allow for N minutes": only when the desktop's setting is not Off,
  /// and only for exactly that many minutes.
  forMinutes('for_minutes');

  const ControlAnswer(this.wire);

  final String wire;

  static ControlAnswer? fromWire(Object? value) {
    for (final a in values) {
      if (a.wire == value) return a;
    }
    return null;
  }
}

/// What a card asks for.
enum ControlApprovalKind {
  command('command'),
  fileWrite('file_write'),
  service('service'),
  terminal('terminal'),
  desktop('desktop'),
  jobStart('job_start'),

  /// A kind this end does not know; the phone shows the tool name only.
  other('other');

  const ControlApprovalKind(this.wire);

  final String wire;

  static ControlApprovalKind fromWire(Object? value) {
    for (final k in values) {
      if (k.wire == value) return k;
    }
    return other;
  }
}

/// What a file write's preview shows (`FileWritePreviewKind`, repeated
/// here because that file cannot be imported without Flutter).
enum ControlPreviewKind {
  fullContent,
  partialContent,
  fullDiff,
  partialDiff,
  noPreview;

  static ControlPreviewKind fromWire(Object? value) {
    for (final k in values) {
      if (k.name == value) return k;
    }
    // Unknown is treated as the most cautious: nothing shown.
    return noPreview;
  }
}

/// Something an assistant holds that the user can stop.
enum ControlItemKind {
  terminal,
  desktop,
  job;

  static ControlItemKind? fromWire(Object? value) {
    for (final k in values) {
      if (k.name == value) return k;
    }
    return null;
  }
}

/// How a card went away.
enum ControlApprovalEnd {
  allowedOnce,
  allowedForAWhile,
  denied,
  timedOut,

  /// Taken back: the assistant cancelled, was disconnected, the host
  /// changed, the bridge went off or the app locked.
  withdrawn;

  static ControlApprovalEnd fromWire(Object? value) {
    for (final e in values) {
      if (e.name == value) return e;
    }
    return withdrawn;
  }
}

/// Thrown by the decoders for a line that is not a valid message.
class ControlProtocolException implements Exception {
  const ControlProtocolException(this.code, this.message, {this.re});

  final ControlErrorCode code;
  final String message;

  /// The request id, when the line had a readable one.
  final String? re;

  @override
  String toString() => 'ControlProtocolException(${code.wire}: $message)';
}

// ------------------------------------------------------------ visible text

/// Text as the desktop card draws it: [visibleText]'s spans, with each
/// hidden character already replaced by a marked stand-in, and the kinds
/// for the card's legend. The phone draws exactly these spans.
///
/// Decoding checks the spans again, so a phone never draws a control or
/// bidirectional character even if the other end sent one: a plain span
/// that is not plain, or a stand-in that is not plain ASCII-like text, is
/// rendered again through [visibleText] in its place. On safe input this
/// changes nothing.
class ControlVisibleText {
  ControlVisibleText(List<VisibleSpan> spans, Set<VisibleKind> kinds)
    : spans = List.unmodifiable(_merged(spans)),
      kinds = Set.unmodifiable(kinds);

  /// Neighbouring spans of the same style joined: drawn the same, and a
  /// run of stand-ins costs one JSON object instead of one each.
  static List<VisibleSpan> _merged(List<VisibleSpan> spans) {
    final out = <VisibleSpan>[];
    for (final s in spans) {
      if (s.text.isEmpty) continue;
      if (out.isNotEmpty && out.last.escape == s.escape) {
        out[out.length - 1] = VisibleSpan(
          out.last.text + s.text,
          escape: s.escape,
        );
      } else {
        out.add(s);
      }
    }
    return out;
  }

  /// [raw] rendered the way the card renders it.
  factory ControlVisibleText.render(String raw, {bool breakLines = true}) {
    final v = visibleText(raw, breakLines: breakLines);
    return ControlVisibleText(v.spans, v.kinds);
  }

  final List<VisibleSpan> spans;
  final Set<VisibleKind> kinds;

  /// The rendering as plain text.
  String get text => spans.map((s) => s.text).join();

  bool get hasEscapes => kinds.isNotEmpty;

  /// Whether the legend is worth showing (more than line breaks).
  bool get hasSurprises => kinds.any((k) => k != VisibleKind.lineBreak);

  Map<String, Object?> toJson() => {
    'spans': [
      for (final s in spans) {'t': s.text, if (s.escape) 'e': true},
    ],
    'kinds': [for (final k in kinds) k.name],
  };

  static ControlVisibleText fromJson(Object? json) {
    if (json is! Map) throw const FormatException('visible text');
    final rawSpans = json['spans'];
    final rawKinds = json['kinds'];
    if (rawSpans is! List) throw const FormatException('spans');
    final kinds = <VisibleKind>{};
    if (rawKinds is List) {
      for (final k in rawKinds) {
        for (final v in VisibleKind.values) {
          if (v.name == k) kinds.add(v);
        }
      }
    }
    final spans = <VisibleSpan>[];
    for (final s in rawSpans) {
      if (s is! Map || s['t'] is! String) throw const FormatException('span');
      final text = s['t'] as String;
      final escape = s['e'] == true;
      if (escape) {
        // A stand-in is drawn in the marker style as it is: it must itself
        // be plain, visible text.
        final check = visibleText(text, breakLines: false);
        if (check.hasEscapes) {
          spans.addAll(check.spans);
          kinds.addAll(check.kinds);
        } else {
          spans.add(VisibleSpan(text, escape: true));
        }
      } else {
        final check = visibleText(text);
        if (check.hasSurprises) {
          spans.addAll(check.spans);
          kinds.addAll(check.kinds);
        } else {
          spans.add(VisibleSpan(text));
        }
      }
    }
    return ControlVisibleText(spans, kinds);
  }
}

/// [value] as one safe line; applying it twice changes nothing more, so the
/// phone runs every name it receives through it again.
String controlLine(String value, {int? maxChars}) =>
    visibleLine(value, maxChars: maxChars);

// ------------------------------------------------------------------ models

/// One waiting approval card, as the desktop card shows it.
class ControlApproval {
  ControlApproval({
    required this.id,
    required this.assistant,
    required this.host,
    required this.tool,
    required this.kind,
    required this.remaining,
    required this.timedAllowed,
    this.command,
    this.file,
    this.service,
    this.job,
    DateTime? receivedAt,
  }) : receivedAt = receivedAt ?? DateTime.now();

  final String id;

  /// The assistant's name, one safe line, cut as on the card.
  final String assistant;

  /// The host's name as the assistant knows it (its bridge name), one safe
  /// line. Never an address, port or user name.
  final String host;

  /// The tool's name (e.g. `run_command`).
  final String tool;
  final ControlApprovalKind kind;

  /// Time left when the app sent it. Sent as a span, not a time of day, so
  /// a phone clock that is off does not shorten or lengthen the card.
  final Duration remaining;

  /// When this end received it; with [remaining], gives [expiresAt].
  final DateTime receivedAt;

  /// When silence becomes a no, by this end's clock.
  DateTime get expiresAt => receivedAt.add(remaining);

  /// Whether "Allow for N minutes" may be offered: the desktop's setting is
  /// on and this kind can be covered by it (never a terminal or desktop).
  final bool timedAllowed;

  final ControlCommand? command;
  final ControlFileWrite? file;
  final ControlService? service;
  final ControlJobStart? job;

  Map<String, Object?> toJson() => {
    'id': id,
    'assistant': assistant,
    'host': host,
    'tool': tool,
    'kind': kind.wire,
    'remainingMs': remaining.inMilliseconds,
    'timedAllowed': timedAllowed,
    if (command != null) 'command': command!.toJson(),
    if (file != null) 'file': file!.toJson(),
    if (service != null) 'service': service!.toJson(),
    if (job != null) 'job': job!.toJson(),
  };

  static ControlApproval fromJson(Object? json, {DateTime? receivedAt}) {
    if (json is! Map) throw const FormatException('approval');
    final remainingMs = _int(json, 'remainingMs');
    return ControlApproval(
      id: _id(json, 'id'),
      assistant: controlLine(_str(json, 'assistant')),
      host: controlLine(_str(json, 'host')),
      tool: controlLine(_str(json, 'tool')),
      kind: ControlApprovalKind.fromWire(json['kind']),
      remaining: Duration(milliseconds: remainingMs < 0 ? 0 : remainingMs),
      timedAllowed: json['timedAllowed'] == true,
      command: json['command'] == null
          ? null
          : ControlCommand.fromJson(json['command']),
      file: json['file'] == null ? null : ControlFileWrite.fromJson(json['file']),
      service: json['service'] == null
          ? null
          : ControlService.fromJson(json['service']),
      job: json['job'] == null ? null : ControlJobStart.fromJson(json['job']),
      receivedAt: receivedAt,
    );
  }
}

/// A command and the hosts it runs on (one for `run_command`, several for
/// `run_on_hosts`).
class ControlCommand {
  ControlCommand({required List<String> hosts, required this.command})
    : hosts = List.unmodifiable(hosts);

  final List<String> hosts;
  final ControlVisibleText command;

  Map<String, Object?> toJson() => {
    'hosts': hosts,
    'command': command.toJson(),
  };

  static ControlCommand fromJson(Object? json) {
    if (json is! Map || json['hosts'] is! List) {
      throw const FormatException('command');
    }
    return ControlCommand(
      hosts: [
        for (final h in json['hosts'] as List)
          if (h is String) controlLine(h),
      ],
      command: ControlVisibleText.fromJson(json['command']),
    );
  }
}

/// A file write: path, size, whether it replaces a file, and the preview
/// exactly as the card shows it (the tool's own caps already applied).
class ControlFileWrite {
  const ControlFileWrite({
    required this.path,
    required this.bytes,
    required this.replacesExisting,
    required this.previewKind,
    required this.preview,
  });

  final ControlVisibleText path;
  final int bytes;
  final bool replacesExisting;
  final ControlPreviewKind previewKind;
  final ControlVisibleText preview;

  /// The preview is not the whole change; the card warns about it first.
  bool get previewIsPartial =>
      previewKind != ControlPreviewKind.fullContent &&
      previewKind != ControlPreviewKind.fullDiff;

  Map<String, Object?> toJson() => {
    'path': path.toJson(),
    'bytes': bytes,
    'replaces': replacesExisting,
    'previewKind': previewKind.name,
    'preview': preview.toJson(),
  };

  static ControlFileWrite fromJson(Object? json) {
    if (json is! Map) throw const FormatException('file');
    return ControlFileWrite(
      path: ControlVisibleText.fromJson(json['path']),
      bytes: _int(json, 'bytes'),
      replacesExisting: json['replaces'] == true,
      previewKind: ControlPreviewKind.fromWire(json['previewKind']),
      preview: ControlVisibleText.fromJson(json['preview']),
    );
  }
}

/// A systemd action on one unit.
class ControlService {
  const ControlService({required this.unit, required this.action});

  /// One safe line.
  final String unit;

  /// `start`, `stop`, `restart`, `reload`, or something else as one safe
  /// line.
  final String action;

  Map<String, Object?> toJson() => {'unit': unit, 'action': action};

  static ControlService fromJson(Object? json) {
    if (json is! Map) throw const FormatException('service');
    return ControlService(
      unit: controlLine(_str(json, 'unit')),
      action: controlLine(_str(json, 'action')),
    );
  }
}

/// Starting a long-running job: the command, the folder it starts in (null
/// for the home directory) and its short name, if any.
class ControlJobStart {
  const ControlJobStart({required this.command, this.cwd, this.name});

  final ControlVisibleText command;
  final ControlVisibleText? cwd;

  /// One safe line.
  final String? name;

  Map<String, Object?> toJson() => {
    'command': command.toJson(),
    if (cwd != null) 'cwd': cwd!.toJson(),
    'name': ?name,
  };

  static ControlJobStart fromJson(Object? json) {
    if (json is! Map) throw const FormatException('job');
    final name = json['name'];
    return ControlJobStart(
      command: ControlVisibleText.fromJson(json['command']),
      cwd: json['cwd'] == null ? null : ControlVisibleText.fromJson(json['cwd']),
      name: name is String ? controlLine(name) : null,
    );
  }
}

/// One live time-limited approval.
class ControlGrant {
  ControlGrant({
    required this.id,
    required this.assistant,
    required this.host,
    required this.remaining,
    DateTime? receivedAt,
  }) : receivedAt = receivedAt ?? DateTime.now();

  /// Opaque; pass it back to stop the grant.
  final String id;
  final String assistant;
  final String host;
  final Duration remaining;
  final DateTime receivedAt;

  DateTime get expiresAt => receivedAt.add(remaining);

  Map<String, Object?> toJson() => {
    'id': id,
    'assistant': assistant,
    'host': host,
    'remainingMs': remaining.inMilliseconds,
  };

  static ControlGrant fromJson(Object? json, {DateTime? receivedAt}) {
    if (json is! Map) throw const FormatException('grant');
    final ms = _int(json, 'remainingMs');
    return ControlGrant(
      id: _id(json, 'id'),
      assistant: controlLine(_str(json, 'assistant')),
      host: controlLine(_str(json, 'host')),
      remaining: Duration(milliseconds: ms < 0 ? 0 : ms),
      receivedAt: receivedAt,
    );
  }
}

/// An assistant terminal, desktop or job the user can stop.
class ControlItem {
  const ControlItem({
    required this.kind,
    required this.id,
    required this.assistant,
    required this.host,
    required this.state,
    this.label,
    this.startedAt,
  });

  final ControlItemKind kind;
  final String id;
  final String assistant;
  final String host;

  /// e.g. `driving`, `takenOver`, `running`; shown as it is.
  final String state;

  /// A name the item has (a job's name), one safe line.
  final String? label;
  final DateTime? startedAt;

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'id': id,
    'assistant': assistant,
    'host': host,
    'state': state,
    'label': ?label,
    if (startedAt != null) 'startedAt': startedAt!.toUtc().toIso8601String(),
  };

  static ControlItem fromJson(Object? json) {
    if (json is! Map) throw const FormatException('item');
    final kind = ControlItemKind.fromWire(json['kind']);
    if (kind == null) throw const FormatException('item kind');
    final label = json['label'];
    final started = json['startedAt'];
    return ControlItem(
      kind: kind,
      id: _id(json, 'id'),
      assistant: controlLine(_str(json, 'assistant')),
      host: controlLine(_str(json, 'host')),
      state: controlLine(_str(json, 'state')),
      label: label is String ? controlLine(label) : null,
      startedAt: started is String ? DateTime.tryParse(started) : null,
    );
  }
}

/// One activity log entry, every text a safe line.
class ControlActivity {
  const ControlActivity({
    required this.ts,
    required this.assistant,
    required this.host,
    required this.tool,
    required this.outcome,
    required this.approval,
    required this.detail,
    required this.args,
    this.via,
  });

  final DateTime ts;
  final String assistant;
  final String? host;
  final String tool;

  /// `ok`, `refused` or `error`.
  final String outcome;

  /// How a change was allowed or why not (the audit log's `approval`).
  final String approval;
  final String detail;

  /// The arguments as recorded (scrubbed and cut short by the log).
  final String args;

  /// Where the card's answer came from, e.g. `controller:<name>`.
  final String? via;

  Map<String, Object?> toJson() => {
    'ts': ts.toUtc().toIso8601String(),
    'assistant': assistant,
    'host': ?host,
    'tool': tool,
    'outcome': outcome,
    'approval': approval,
    'detail': detail,
    'args': args,
    'via': ?via,
  };

  static ControlActivity fromJson(Object? json) {
    if (json is! Map) throw const FormatException('activity');
    final ts = DateTime.tryParse(_str(json, 'ts'));
    if (ts == null) throw const FormatException('ts');
    final host = json['host'];
    final via = json['via'];
    return ControlActivity(
      ts: ts,
      assistant: controlLine(_str(json, 'assistant')),
      host: host is String ? controlLine(host) : null,
      tool: controlLine(_str(json, 'tool')),
      outcome: controlLine(_str(json, 'outcome')),
      approval: controlLine(_str(json, 'approval')),
      detail: controlLine(_str(json, 'detail')),
      args: controlLine(_str(json, 'args')),
      via: via is String ? controlLine(via) : null,
    );
  }
}

/// The session-wide state.
class ControlState {
  const ControlState({
    required this.locked,
    required this.timedMinutes,
    required this.controller,
  });

  /// The computer's app is locked: no cards, nothing listed, every action
  /// refused, until it is unlocked there.
  final bool locked;

  /// The desktop's "Allow for a while" length in minutes; 0 is off.
  final int timedMinutes;

  /// This phone's name, as paired on the computer.
  final String controller;

  Map<String, Object?> toJson() => {
    'locked': locked,
    'timedMinutes': timedMinutes,
    'controller': controller,
  };

  static ControlState fromJson(Object? json) {
    if (json is! Map) throw const FormatException('state');
    return ControlState(
      locked: json['locked'] == true,
      timedMinutes: _int(json, 'timedMinutes'),
      controller: controlLine(_str(json, 'controller')),
    );
  }
}

// ------------------------------------------------------------- app → phone

/// A message from the app to the phone.
sealed class ControlEvent {
  const ControlEvent();

  String get type;
  Map<String, Object?> toJsonBody();

  /// One line, without the newline.
  String encode() => jsonEncode({'type': type, ...toJsonBody()});

  /// Throws [ControlProtocolException] for a line that is not a message.
  static ControlEvent decode(String line, {DateTime? now}) {
    final json = _object(line);
    final received = now ?? DateTime.now();
    try {
      switch (json['type']) {
        case 'snapshot':
          final v = json['v'];
          if (v != bridgeControlProtocolVersion) {
            throw ControlProtocolException(
              ControlErrorCode.malformed,
              'This computer speaks control protocol $v; this phone speaks '
              '$bridgeControlProtocolVersion. Update both apps to the same '
              'version.',
            );
          }
          return ControlSnapshot(
            state: ControlState.fromJson(json['state']),
            grants: _list(
              json['grants'],
              (g) => ControlGrant.fromJson(g, receivedAt: received),
            ),
            items: _list(json['items'], ControlItem.fromJson),
            activity: _list(json['activity'], ControlActivity.fromJson),
          );
        case 'approval':
          return ControlApprovalAdded(
            ControlApproval.fromJson(json['approval'], receivedAt: received),
          );
        case 'approval_removed':
          return ControlApprovalRemoved(
            _id(json, 'id'),
            ControlApprovalEnd.fromWire(json['end']),
          );
        case 'synced':
          return const ControlSynced();
        case 'state':
          return ControlStateChanged(ControlState.fromJson(json['state']));
        case 'grants':
          return ControlGrantsChanged(
            _list(
              json['grants'],
              (g) => ControlGrant.fromJson(g, receivedAt: received),
            ),
          );
        case 'items':
          return ControlItemsChanged(_list(json['items'], ControlItem.fromJson));
        case 'activity':
          return ControlActivityAdded(ControlActivity.fromJson(json['entry']));
        case 'result':
          final code = json['code'];
          final message = json['message'];
          final outcome = json['outcome'];
          return ControlResult(
            re: _str(json, 're'),
            ok: json['ok'] == true,
            code: code == null ? null : ControlErrorCode.fromWire(code),
            message: message is String ? controlLine(message) : null,
            outcome: outcome is String ? outcome : null,
          );
        case 'error':
          final message = json['message'];
          return ControlError(
            ControlErrorCode.fromWire(json['code']),
            message is String ? controlLine(message) : '',
          );
      }
    } on FormatException catch (e) {
      throw ControlProtocolException(ControlErrorCode.malformed, e.message);
    } on TypeError {
      throw const ControlProtocolException(
        ControlErrorCode.malformed,
        'A field has the wrong type.',
      );
    }
    throw const ControlProtocolException(
      ControlErrorCode.unknownType,
      'Unknown message type.',
    );
  }
}

/// Everything at once; replaces all the phone holds (see the file comment).
final class ControlSnapshot extends ControlEvent {
  ControlSnapshot({
    required this.state,
    required List<ControlGrant> grants,
    required List<ControlItem> items,
    required List<ControlActivity> activity,
  }) : grants = List.unmodifiable(grants),
       items = List.unmodifiable(items),
       activity = List.unmodifiable(activity);

  final ControlState state;
  final List<ControlGrant> grants;
  final List<ControlItem> items;

  /// Newest first.
  final List<ControlActivity> activity;

  @override
  String get type => 'snapshot';

  @override
  Map<String, Object?> toJsonBody() => {
    'v': bridgeControlProtocolVersion,
    'state': state.toJson(),
    'grants': [for (final g in grants) g.toJson()],
    'items': [for (final i in items) i.toJson()],
    'activity': [for (final a in activity) a.toJson()],
  };
}

final class ControlApprovalAdded extends ControlEvent {
  const ControlApprovalAdded(this.approval);

  final ControlApproval approval;

  @override
  String get type => 'approval';

  @override
  Map<String, Object?> toJsonBody() => {'approval': approval.toJson()};
}

final class ControlApprovalRemoved extends ControlEvent {
  const ControlApprovalRemoved(this.id, this.end);

  final String id;
  final ControlApprovalEnd end;

  @override
  String get type => 'approval_removed';

  @override
  Map<String, Object?> toJsonBody() => {'id': id, 'end': end.name};
}

/// Every approval waiting at the last snapshot has been sent.
final class ControlSynced extends ControlEvent {
  const ControlSynced();

  @override
  String get type => 'synced';

  @override
  Map<String, Object?> toJsonBody() => const {};
}

final class ControlStateChanged extends ControlEvent {
  const ControlStateChanged(this.state);

  final ControlState state;

  @override
  String get type => 'state';

  @override
  Map<String, Object?> toJsonBody() => {'state': state.toJson()};
}

final class ControlGrantsChanged extends ControlEvent {
  ControlGrantsChanged(List<ControlGrant> grants)
    : grants = List.unmodifiable(grants);

  final List<ControlGrant> grants;

  @override
  String get type => 'grants';

  @override
  Map<String, Object?> toJsonBody() => {
    'grants': [for (final g in grants) g.toJson()],
  };
}

final class ControlItemsChanged extends ControlEvent {
  ControlItemsChanged(List<ControlItem> items)
    : items = List.unmodifiable(items);

  final List<ControlItem> items;

  @override
  String get type => 'items';

  @override
  Map<String, Object?> toJsonBody() => {
    'items': [for (final i in items) i.toJson()],
  };
}

final class ControlActivityAdded extends ControlEvent {
  const ControlActivityAdded(this.entry);

  final ControlActivity entry;

  @override
  String get type => 'activity';

  @override
  Map<String, Object?> toJsonBody() => {'entry': entry.toJson()};
}

/// The answer to one request.
final class ControlResult extends ControlEvent {
  const ControlResult({
    required this.re,
    required this.ok,
    this.code,
    this.message,
    this.outcome,
  });

  final String re;
  final bool ok;

  /// Set when not [ok].
  final ControlErrorCode? code;
  final String? message;

  /// For an answer: how the card ended (a [ControlApprovalEnd] name).
  final String? outcome;

  @override
  String get type => 'result';

  @override
  Map<String, Object?> toJsonBody() => {
    're': re,
    'ok': ok,
    if (code != null) 'code': code!.wire,
    'message': ?message,
    'outcome': ?outcome,
  };
}

/// About the session, not one request. The launcher's own failures (app
/// not running, refused) arrive this way too, as its only line.
final class ControlError extends ControlEvent {
  const ControlError(this.code, this.message);

  final ControlErrorCode code;
  final String message;

  @override
  String get type => 'error';

  @override
  Map<String, Object?> toJsonBody() => {'code': code.wire, 'message': message};
}

// ------------------------------------------------------------- phone → app

/// A request from the phone. [re] is echoed in the [ControlResult].
sealed class ControlRequest {
  const ControlRequest(this.re);

  final String re;

  String get type;
  Map<String, Object?> toJsonBody();

  String encode() => jsonEncode({'type': type, 're': re, ...toJsonBody()});

  /// Throws [ControlProtocolException] (with [ControlProtocolException.re]
  /// when the line had one) for a line that is not a request.
  static ControlRequest decode(String line) {
    final json = _object(line);
    final reValue = json['re'];
    final re =
        reValue is String &&
            reValue.isNotEmpty &&
            reValue.length <= bridgeControlMaxIdChars
        ? reValue
        : null;
    if (re == null) {
      throw const ControlProtocolException(
        ControlErrorCode.malformed,
        'Every request needs an "re".',
      );
    }
    ControlProtocolException bad(String message) =>
        ControlProtocolException(ControlErrorCode.malformed, message, re: re);
    String id(String key) {
      final v = json[key];
      if (v is! String || v.isEmpty || v.length > bridgeControlMaxIdChars) {
        throw bad('"$key" is missing or not valid.');
      }
      return v;
    }

    switch (json['type']) {
      case 'answer':
        final answer = ControlAnswer.fromWire(json['answer']);
        if (answer == null) throw bad('"answer" is not valid.');
        final minutes = json['minutes'];
        if (answer == ControlAnswer.forMinutes && minutes is! int) {
          throw bad('"minutes" is missing.');
        }
        return ControlAnswerRequest(
          re,
          approvalId: id('approval'),
          answer: answer,
          minutes: minutes is int ? minutes : null,
        );
      case 'stop_grant':
        return ControlStopGrantRequest(re, grantId: id('grant'));
      case 'stop_item':
        final kind = ControlItemKind.fromWire(json['kind']);
        if (kind == null) throw bad('"kind" is not valid.');
        return ControlStopItemRequest(re, kind: kind, itemId: id('id'));
      case 'ping':
        return ControlPingRequest(re);
    }
    throw ControlProtocolException(
      ControlErrorCode.unknownType,
      'Unknown request type.',
      re: re,
    );
  }
}

final class ControlAnswerRequest extends ControlRequest {
  const ControlAnswerRequest(
    super.re, {
    required this.approvalId,
    required this.answer,
    this.minutes,
  });

  final String approvalId;
  final ControlAnswer answer;

  /// For [ControlAnswer.forMinutes]: must equal the desktop's setting.
  final int? minutes;

  @override
  String get type => 'answer';

  @override
  Map<String, Object?> toJsonBody() => {
    'approval': approvalId,
    'answer': answer.wire,
    'minutes': ?minutes,
  };
}

final class ControlStopGrantRequest extends ControlRequest {
  const ControlStopGrantRequest(super.re, {required this.grantId});

  final String grantId;

  @override
  String get type => 'stop_grant';

  @override
  Map<String, Object?> toJsonBody() => {'grant': grantId};
}

final class ControlStopItemRequest extends ControlRequest {
  const ControlStopItemRequest(
    super.re, {
    required this.kind,
    required this.itemId,
  });

  final ControlItemKind kind;
  final String itemId;

  @override
  String get type => 'stop_item';

  @override
  Map<String, Object?> toJsonBody() => {'kind': kind.name, 'id': itemId};
}

final class ControlPingRequest extends ControlRequest {
  const ControlPingRequest(super.re);

  @override
  String get type => 'ping';

  @override
  Map<String, Object?> toJsonBody() => const {};
}

// ----------------------------------------------------------------- helpers

Map<String, Object?> _object(String line) {
  final Object? json;
  try {
    json = jsonDecode(line);
  } on FormatException {
    throw const ControlProtocolException(
      ControlErrorCode.malformed,
      'Not JSON.',
    );
  }
  if (json is! Map<String, Object?>) {
    throw const ControlProtocolException(
      ControlErrorCode.malformed,
      'Not a JSON object.',
    );
  }
  return json;
}

String _str(Map<dynamic, dynamic> json, String key) {
  final v = json[key];
  if (v is! String) throw FormatException('"$key" is not text.');
  return v;
}

String _id(Map<dynamic, dynamic> json, String key) {
  final v = _str(json, key);
  if (v.isEmpty || v.length > bridgeControlMaxIdChars) {
    throw FormatException('"$key" is not a valid id.');
  }
  return v;
}

int _int(Map<dynamic, dynamic> json, String key) {
  final v = json[key];
  if (v is! int) throw FormatException('"$key" is not a whole number.');
  return v;
}

List<T> _list<T>(Object? json, T Function(Object? item) parse) {
  if (json == null) return const [];
  if (json is! List) throw const FormatException('Not a list.');
  return [for (final item in json) parse(item)];
}
