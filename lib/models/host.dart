import 'host_ai_access.dart';

/// How the user authenticates against a remote host.
enum SshAuthMethod {
  password,
  privateKey,

  /// Sign with a key held by the operating system's ssh-agent. Desktop only —
  /// Android has no agent to talk to — and, unlike the other two, it stores
  /// no secret for the host at all: the private key never leaves the agent.
  /// See `ssh_agent_client.dart`.
  agent;

  String get label => switch (this) {
        SshAuthMethod.password => 'Password',
        SshAuthMethod.privateKey => 'Private key',
        SshAuthMethod.agent => 'OS SSH agent',
      };

  /// True when choosing this method means no password, key or passphrase is
  /// written to the credential store for the host.
  bool get storesNoSecret => this == SshAuthMethod.agent;

  static SshAuthMethod fromName(String? name) => SshAuthMethod.values.firstWhere(
        (m) => m.name == name,
        orElse: () => SshAuthMethod.password,
      );
}

/// A fixed palette of colour tags a saved host can be labelled with, purely
/// for telling servers apart at a glance in the list. Persisted as [name] (a
/// stable string id) rather than a raw ARGB value — same reasoning as
/// [SshAuthMethod] — so the actual swatch (see `theme.dart`'s
/// `AppTheme.hostColorFor`) can be re-tuned later without touching
/// `hosts.json`. `models/` stays free of `Color`, matching the dependency
/// rule that keeps this file Flutter-free.
enum HostColorLabel {
  red,
  orange,
  yellow,
  green,
  teal,
  blue,
  purple,
  pink;

  String get label => switch (this) {
        HostColorLabel.red => 'Red',
        HostColorLabel.orange => 'Orange',
        HostColorLabel.yellow => 'Yellow',
        HostColorLabel.green => 'Green',
        HostColorLabel.teal => 'Teal',
        HostColorLabel.blue => 'Blue',
        HostColorLabel.purple => 'Purple',
        HostColorLabel.pink => 'Pink',
      };

  /// Parses a stored id back into a value. Unlike [SshAuthMethod.fromName],
  /// an unrecognised or absent id reads as "no colour label" rather than
  /// falling back to a default swatch — a host with no tag is a legitimate,
  /// common case here, not a migration gap.
  static HostColorLabel? fromId(String? id) {
    if (id == null) return null;
    for (final value in HostColorLabel.values) {
      if (value.name == id) return value;
    }
    return null;
  }
}

/// What keeps a shell running on the server when the connection to it drops,
/// so a reconnect lands back in the same shell — scrollback, running job and
/// all — rather than a fresh login.
///
/// Off unless chosen, per host: it leaves a tmux or screen session running on
/// the server after the app has gone, which is a decision about that server.
/// Persisted as [name], same reasoning as [SshAuthMethod].
enum PersistentSession {
  off,
  tmux,
  screen;

  String get label => switch (this) {
        PersistentSession.off => 'Off',
        PersistentSession.tmux => 'tmux',
        PersistentSession.screen => 'GNU screen',
      };

  /// Unrecognised or absent reads as [off]: a host saved before this existed
  /// keeps the plain shell it always had.
  static PersistentSession fromName(String? name) =>
      PersistentSession.values.firstWhere(
        (p) => p.name == name,
        orElse: () => PersistentSession.off,
      );
}

/// How the terminal's keystrokes and screen travel to and from the host.
///
/// Only the shell changes with this. Sign-in, files, tunnels and every
/// command the app runs go over SSH either way — Mosh itself starts over SSH.
enum HostTransport {
  ssh,

  /// Mosh's UDP protocol, which survives roaming between networks and long
  /// sleeps that an SSH connection does not. Needs `mosh-server` installed
  /// on the host.
  mosh;

  String get label => switch (this) {
        HostTransport.ssh => 'SSH',
        HostTransport.mosh => 'Mosh',
      };

  /// Unrecognised or absent reads as [ssh], what every host used before.
  static HostTransport fromName(String? name) => HostTransport.values.firstWhere(
        (t) => t.name == name,
        orElse: () => HostTransport.ssh,
      );
}

/// A remote machine the user connects to.
///
/// This is the persistable half of a connection: it deliberately contains no
/// secrets. Passwords, private keys and passphrases live in [SshCredentials],
/// which is held in memory only for the duration of a connect attempt.
class Host {
  const Host({
    required this.id,
    required this.label,
    required this.hostname,
    required this.port,
    required this.username,
    required this.authMethod,
    this.lastConnectedAt,
    this.group,
    this.colorLabel,
    this.startupCommand,
    this.jumpHostId,
    this.legacyAlgorithms = false,
    this.agentForwarding = false,
    this.x11Forwarding = false,
    this.persistentSession = PersistentSession.off,
    this.certificate,
    this.transport = HostTransport.ssh,
    this.aiAccess = HostAiAccess.off,
    this.aiAllowedCommands = const <String>[],
    this.aiTerminal = false,
    this.aiDesktop = false,
  });

  final String id;
  final String label;
  final String hostname;
  final int port;
  final String username;
  final SshAuthMethod authMethod;

  /// When this host was last successfully connected to, or null if never.
  /// Purely informational — nothing reads it to make a trust or security
  /// decision, so a missing or unparsable value just means "unknown".
  final DateTime? lastConnectedAt;

  /// The saved-hosts list section this host sits in, or null for the
  /// trailing Ungrouped section. There is no separate group table — a group
  /// exists only as long as some host names it — so this string *is* the
  /// group, and renaming/deleting one is a bulk edit across every host that
  /// shares it (see `HostStore.renameGroup`/`deleteGroup`).
  final String? group;

  /// This host's colour tag, or null for none.
  final HostColorLabel? colorLabel;

  /// Sent to the shell, followed by a newline, the moment it opens. Null
  /// means "nothing to run" — the ordinary case, and every host saved before
  /// this field existed.
  final String? startupCommand;

  /// The [id] of another saved host to tunnel through (OpenSSH `ProxyJump`),
  /// or null to dial this host directly.
  ///
  /// An id rather than an embedded copy of the jump host: the jump's address
  /// and credentials are edited in one place, and re-pointing it does not
  /// leave a stale duplicate behind. The cost is that the reference can
  /// dangle — the jump host may since have been deleted — and that a chain
  /// can loop back on itself. Neither is checked here, because a model that
  /// only sees itself cannot see the other hosts; both are resolved, and
  /// rejected with a specific message, in `jump_host_chain.dart`.
  final String? jumpHostId;

  /// Whether to also offer the old algorithms this host may need: SHA-1 key
  /// exchange and `ssh-rsa` host-key signatures, and CBC ciphers.
  ///
  /// Off by default and per host, never global. The SSH library stopped
  /// proposing these in 4.0, as OpenSSH did, because SHA-1 signatures are
  /// open to collisions and CBC to plaintext recovery (CVE-2008-5161). An old
  /// router or NAS that speaks nothing newer then fails to connect, and the
  /// error says to turn this on for that one host, so the weakening is a
  /// decision about a server the user knows rather than something every
  /// connection quietly falls back to.
  final bool legacyAlgorithms;

  /// Whether the session's connection forwards this device's SSH agent, so
  /// `git pull` or `ssh` run in the shell can sign with keys that never
  /// leave this device.
  ///
  /// Off by default, per host: for as long as the session lasts, anyone with
  /// root on the server can ask the forwarded agent to sign. Separate from
  /// the one-exec forwarding a direct server-to-server copy sets up for
  /// itself (see `SessionTransport.agentSlot`), which this does not affect.
  final bool agentForwarding;

  /// Whether graphical programs started in the shell open their windows on
  /// this device. Off by default; it needs an X server here to draw them.
  final bool x11Forwarding;

  /// See [PersistentSession].
  final PersistentSession persistentSession;

  /// An OpenSSH user certificate — the one line of a `…-cert.pub` file —
  /// presented with this host's key, for servers that trust a certificate
  /// authority rather than each key. Null for none, the ordinary case.
  ///
  /// Kept here, not in the credential store: a certificate is signed, not
  /// secret, and is useless without the private key it certifies.
  final String? certificate;

  /// See [HostTransport].
  final HostTransport transport;

  /// Whether an AI assistant may use this host through the AI Bridge. Off by
  /// default, and never carried by a backup: see `BackupPayload`.
  final HostAiAccess aiAccess;

  /// Commands an assistant may run on this host without asking, matched by
  /// exact text. Meaningful only while [aiAccess] is [HostAiAccess.askToChange]
  /// (see [aiMayRequestChanges]); stepping the host down to read-only or off
  /// leaves the list stored but inert, so switching back on does not lose it.
  /// Never carried by a backup. Build it with [sanitizeAiAllowedCommands].
  final List<String> aiAllowedCommands;

  /// Whether an assistant may ask to open a terminal on this host (a card
  /// every time). Meaningful only while [aiAccess] is
  /// [HostAiAccess.askToChange]; [HostAiAccess.fullControl] implies it on
  /// whatever is stored here. Kept when stepping down, never in a backup.
  final bool aiTerminal;

  /// Whether an assistant may ask to open a desktop on this host (a card
  /// every time). Same rules as [aiTerminal].
  final bool aiDesktop;

  /// True when [aiAccess] is [HostAiAccess.askToChange] or
  /// [HostAiAccess.fullControl]: change tools are not refused outright.
  bool get aiMayRequestChanges =>
      aiAccess == HostAiAccess.askToChange ||
      aiAccess == HostAiAccess.fullControl;

  /// True when [aiAccess] is [HostAiAccess.fullControl]: changes, terminals
  /// and desktops run without a card.
  bool get aiFullControl => aiAccess == HostAiAccess.fullControl;

  /// Full control, or ask-to-change with [aiTerminal] on.
  bool get aiMayOpenTerminal =>
      aiFullControl || (aiAccess == HostAiAccess.askToChange && aiTerminal);

  /// Full control, or ask-to-change with [aiDesktop] on.
  bool get aiMayOpenDesktop =>
      aiFullControl || (aiAccess == HostAiAccess.askToChange && aiDesktop);

  /// Longest allowed-command entry, and the most entries kept.
  static const int maxAiAllowedCommandLength = 4096;
  static const int maxAiAllowedCommands = 50;

  /// The one cleaning rule for an allowed-commands list, used when reading
  /// `hosts.json`, by [copyWith], and available to the editor: each entry
  /// trimmed, empty ones, ones over [maxAiAllowedCommandLength] characters
  /// and ones holding a character that hides what runs (see
  /// [_hidesWhatRuns]) dropped, duplicates dropped (first kept), at most
  /// [maxAiAllowedCommands] entries.
  ///
  /// An entry is dropped whole, never cleaned up: stripping characters would
  /// store a command other than the one the user typed.
  static List<String> sanitizeAiAllowedCommands(Iterable<Object?> raw) {
    final seen = <String>{};
    final out = <String>[];
    for (final item in raw) {
      if (item is! String) continue;
      final command = item.trim();
      if (command.isEmpty ||
          command.length > maxAiAllowedCommandLength ||
          _hidesWhatRuns(command)) {
        continue;
      }
      if (!seen.add(command)) continue;
      out.add(command);
      if (out.length >= maxAiAllowedCommands) break;
    }
    return List<String>.unmodifiable(out);
  }

  /// True when [command] holds a character that makes the stored text read
  /// differently from what runs, on a path where nobody is asked: any C0 or
  /// C1 control (NUL, tab, and line breaks included: a multi-line entry is
  /// several commands), DEL, every space other than U+0020 (a no-break space
  /// looks like a word break and is not one to a shell), the soft hyphen,
  /// the Unicode line and paragraph separators, bidirectional marks,
  /// embeddings, overrides and isolates, zero-width characters and the
  /// byte-order mark, and a lone surrogate. Checked after trimming, so only
  /// what sits inside the command counts.
  static bool _hidesWhatRuns(String command) {
    final units = command.codeUnits;
    for (var i = 0; i < units.length; i++) {
      final c = units[i];
      if (c < 0x20 || (c >= 0x7F && c <= 0x9F)) return true;
      if (c == 0x00A0 || // no-break space: looks like a space, is not one
          c == 0x00AD || // soft hyphen
          c == 0x061C || // Arabic letter mark
          c == 0x1680 ||
          c == 0x180E ||
          (c >= 0x2000 && c <= 0x200A) || // other Unicode spaces
          (c >= 0x200B && c <= 0x200F) || // zero-width, LRM, RLM
          c == 0x202F ||
          c == 0x205F ||
          c == 0x3000 ||
          (c >= 0x2028 && c <= 0x202E) || // separators, embeddings, overrides
          (c >= 0x2060 && c <= 0x2069) || // word joiner .. isolates
          c == 0xFEFF) {
        return true;
      }
      if (c >= 0xD800 && c <= 0xDBFF) {
        final next = i + 1 < units.length ? units[i + 1] : 0;
        if (next < 0xDC00 || next > 0xDFFF) return true;
        i++;
      } else if (c >= 0xDC00 && c <= 0xDFFF) {
        return true;
      }
    }
    return false;
  }

  /// `user@host` or `user@host:port` when the port is non-standard.
  String get target =>
      port == 22 ? '$username@$hostname' : '$username@$hostname:$port';

  /// What to show in an app bar: the user-given label, falling back to target.
  String get displayName => label.trim().isEmpty ? target : label.trim();

  Host copyWith({
    String? id,
    String? label,
    String? hostname,
    int? port,
    String? username,
    SshAuthMethod? authMethod,
    DateTime? lastConnectedAt,
    String? group,
    HostColorLabel? colorLabel,
    String? startupCommand,
    String? jumpHostId,
    bool? legacyAlgorithms,
    bool? agentForwarding,
    bool? x11Forwarding,
    PersistentSession? persistentSession,
    String? certificate,
    HostTransport? transport,
    HostAiAccess? aiAccess,
    List<String>? aiAllowedCommands,
    bool? aiTerminal,
    bool? aiDesktop,
  }) {
    return Host(
      id: id ?? this.id,
      label: label ?? this.label,
      hostname: hostname ?? this.hostname,
      port: port ?? this.port,
      username: username ?? this.username,
      authMethod: authMethod ?? this.authMethod,
      lastConnectedAt: lastConnectedAt ?? this.lastConnectedAt,
      group: group ?? this.group,
      colorLabel: colorLabel ?? this.colorLabel,
      startupCommand: startupCommand ?? this.startupCommand,
      jumpHostId: jumpHostId ?? this.jumpHostId,
      legacyAlgorithms: legacyAlgorithms ?? this.legacyAlgorithms,
      agentForwarding: agentForwarding ?? this.agentForwarding,
      x11Forwarding: x11Forwarding ?? this.x11Forwarding,
      persistentSession: persistentSession ?? this.persistentSession,
      certificate: certificate ?? this.certificate,
      transport: transport ?? this.transport,
      aiAccess: aiAccess ?? this.aiAccess,
      // A new list is cleaned here, so every write path that goes through
      // copyWith stores only what fromJson would read back.
      aiAllowedCommands: aiAllowedCommands == null
          ? this.aiAllowedCommands
          : sanitizeAiAllowedCommands(aiAllowedCommands),
      aiTerminal: aiTerminal ?? this.aiTerminal,
      aiDesktop: aiDesktop ?? this.aiDesktop,
    );
  }

  /// This host with everything the AI Bridge grants put back to its default:
  /// access off, no allowed commands, no terminal, no desktop. What a backup
  /// does to every host it exports or imports.
  Host withoutAiGrants() => copyWith(
        aiAccess: HostAiAccess.off,
        aiAllowedCommands: const <String>[],
        aiTerminal: false,
        aiDesktop: false,
      );

  /// Re-points (or clears, with null) the jump host.
  ///
  /// Separate from [copyWith] for the same reason [withGroup] is: `??` can
  /// only move a field away from null, and "Direct connection" — the default
  /// every host starts at — is exactly the value that has to be settable
  /// again once a jump host has been chosen.
  Host withJumpHost(String? jumpHostId) => Host(
        id: id,
        label: label,
        hostname: hostname,
        port: port,
        username: username,
        authMethod: authMethod,
        lastConnectedAt: lastConnectedAt,
        group: group,
        colorLabel: colorLabel,
        startupCommand: startupCommand,
        jumpHostId: jumpHostId,
        legacyAlgorithms: legacyAlgorithms,
        agentForwarding: agentForwarding,
        x11Forwarding: x11Forwarding,
        persistentSession: persistentSession,
        certificate: certificate,
        transport: transport,
        aiAccess: aiAccess,
        aiAllowedCommands: aiAllowedCommands,
        aiTerminal: aiTerminal,
        aiDesktop: aiDesktop,
      );

  /// Reassigns this host's group, [group] null meaning Ungrouped.
  ///
  /// Not folded into [copyWith]: that helper's `??` merge can only ever move
  /// a field away from null, never back to it, which is exactly what moving
  /// a host to Ungrouped (or the group-delete bulk edit in
  /// `HostStore.deleteGroup`) needs to do.
  Host withGroup(String? group) => Host(
        id: id,
        label: label,
        hostname: hostname,
        port: port,
        username: username,
        authMethod: authMethod,
        lastConnectedAt: lastConnectedAt,
        group: group,
        colorLabel: colorLabel,
        startupCommand: startupCommand,
        jumpHostId: jumpHostId,
        legacyAlgorithms: legacyAlgorithms,
        agentForwarding: agentForwarding,
        x11Forwarding: x11Forwarding,
        persistentSession: persistentSession,
        certificate: certificate,
        transport: transport,
        aiAccess: aiAccess,
        aiAllowedCommands: aiAllowedCommands,
        aiTerminal: aiTerminal,
        aiDesktop: aiDesktop,
      );

  /// Sets (or removes, with null) the certificate. Its own helper for the
  /// reason [withGroup] is one: [copyWith] cannot set a field back to null.
  Host withCertificate(String? certificate) => Host(
        id: id,
        label: label,
        hostname: hostname,
        port: port,
        username: username,
        authMethod: authMethod,
        lastConnectedAt: lastConnectedAt,
        group: group,
        colorLabel: colorLabel,
        startupCommand: startupCommand,
        jumpHostId: jumpHostId,
        legacyAlgorithms: legacyAlgorithms,
        agentForwarding: agentForwarding,
        x11Forwarding: x11Forwarding,
        persistentSession: persistentSession,
        certificate: certificate,
        transport: transport,
        aiAccess: aiAccess,
        aiAllowedCommands: aiAllowedCommands,
        aiTerminal: aiTerminal,
        aiDesktop: aiDesktop,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'hostname': hostname,
        'port': port,
        'username': username,
        'authMethod': authMethod.name,
        if (lastConnectedAt != null)
          'lastConnectedAt': lastConnectedAt!.toIso8601String(),
        if (group != null) 'group': group,
        if (colorLabel != null) 'colorLabel': colorLabel!.name,
        if (startupCommand != null) 'startupCommand': startupCommand,
        if (jumpHostId != null) 'jumpHostId': jumpHostId,
        if (legacyAlgorithms) 'legacyAlgorithms': true,
        // Each written only when it differs from the default, so a host that
        // uses none of them saves exactly as it did before they existed.
        if (agentForwarding) 'agentForwarding': true,
        if (x11Forwarding) 'x11Forwarding': true,
        if (persistentSession != PersistentSession.off)
          'persistentSession': persistentSession.name,
        if (certificate != null) 'certificate': certificate,
        if (transport != HostTransport.ssh) 'transport': transport.name,
        if (aiAccess != HostAiAccess.off) 'aiAccess': aiAccess.name,
        if (aiAllowedCommands.isNotEmpty) 'aiAllowedCommands': aiAllowedCommands,
        if (aiTerminal) 'aiTerminal': true,
        if (aiDesktop) 'aiDesktop': true,
      };

  factory Host.fromJson(Map<String, dynamic> json) {
    final rawGroup = json['group'] as String?;
    return Host(
      id: json['id'] as String,
      label: (json['label'] as String?) ?? '',
      hostname: json['hostname'] as String,
      port: (json['port'] as num?)?.toInt() ?? 22,
      username: json['username'] as String,
      authMethod: SshAuthMethod.fromName(json['authMethod'] as String?),
      // Absent on every host saved before Phase 4 — that just reads as
      // "never" rather than failing the whole entry.
      lastConnectedAt: switch (json['lastConnectedAt']) {
        final String iso => DateTime.tryParse(iso),
        _ => null,
      },
      // Absent on every host saved before v1.3.0 — reads as Ungrouped/no
      // colour rather than failing the entry, same as lastConnectedAt above.
      group: (rawGroup == null || rawGroup.trim().isEmpty) ? null : rawGroup,
      colorLabel: HostColorLabel.fromId(json['colorLabel'] as String?),
      // Absent on every host saved before this field existed — that just
      // reads as "nothing to run", the same as a host where the field was
      // left blank.
      startupCommand: json['startupCommand'] as String?,
      // Absent on every host saved before jump hosts existed, which reads as
      // a direct connection. An empty string is treated the same way rather
      // than becoming an id that can never match a host.
      jumpHostId: switch (json['jumpHostId']) {
        final String id when id.trim().isNotEmpty => id,
        _ => null,
      },
      // Absent on every host saved before this existed: the modern defaults.
      legacyAlgorithms: json['legacyAlgorithms'] == true,
      // Absent on every host saved before 1.5: all off, plain SSH — what
      // every connection did until then.
      agentForwarding: json['agentForwarding'] == true,
      x11Forwarding: json['x11Forwarding'] == true,
      persistentSession: PersistentSession.fromName(
        json['persistentSession'] as String?,
      ),
      // Blank reads as none, like jumpHostId: it could never be presented.
      certificate: switch (json['certificate']) {
        final String cert when cert.trim().isNotEmpty => cert,
        _ => null,
      },
      transport: HostTransport.fromName(json['transport'] as String?),
      // Absent before 1.6, and anything unrecognised: no AI access.
      aiAccess: HostAiAccess.fromJson(json['aiAccess']),
      // Absent before 1.7, and anything malformed: nothing allowed.
      aiAllowedCommands: switch (json['aiAllowedCommands']) {
        final List<dynamic> list => sanitizeAiAllowedCommands(list),
        _ => const <String>[],
      },
      aiTerminal: json['aiTerminal'] == true,
      // Absent before 1.8: no desktop.
      aiDesktop: json['aiDesktop'] == true,
    );
  }
}

/// Secrets used for a single connect attempt. Never persisted in Phase 1.
class SshCredentials {
  const SshCredentials({
    this.password,
    this.privateKeyPem,
    this.passphrase,
  });

  final String? password;
  final String? privateKeyPem;
  final String? passphrase;
}
