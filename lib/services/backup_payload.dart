import 'dart:convert';
import 'dart:typed_data';

import '../models/app_settings.dart';
import '../models/host.dart';
import '../models/path_bookmark.dart';
import '../models/snippet.dart';
import '../models/tunnel_profile.dart';
import 'backup_crypto.dart';

/// What a `.ssgbackup` file actually contains, once decrypted.
///
/// This is the plaintext half of the feature; [BackupCrypto] is the envelope
/// around it. Keeping them apart means the JSON schema can grow without
/// touching a line of cryptography, and the cryptography can be audited
/// without reading any of this.
///
/// ## What is in, and what is deliberately out
///
/// In: saved hosts (which carry their group names — there is no separate
/// group table, see [Host.group]), snippets, tunnel profiles, path bookmarks
/// and app settings. Optionally, and only on an explicit opt-in, the saved
/// passwords/keys/passphrases for those hosts.
///
/// Out, on purpose: **known_hosts**. Host-key trust is a decision the user
/// made on one device about one network path, and copying it to a second
/// device would silently answer a question that device has never asked. A
/// restored install re-verifies host keys on first connect, which is exactly
/// what OpenSSH on a new laptop does. The export UI says so rather than
/// leaving the omission to be discovered.
///
/// Also out: anything about live sessions or running tunnels. A backup
/// describes configuration, not state.
class BackupPayload {
  const BackupPayload({
    required this.hosts,
    required this.snippets,
    required this.tunnels,
    required this.bookmarks,
    required this.settings,
    required this.includesCredentials,
    this.credentials = const <String, SshCredentials>{},
    this.exportedAt,
  });

  /// The schema version of the JSON below, independent of
  /// [BackupCrypto.formatVersion], which versions the encryption envelope.
  /// Two numbers because the two can move independently: a new field here
  /// does not change how the file is sealed, and a cipher change does not
  /// change what the fields mean.
  static const int payloadVersion = 1;

  /// Guards against a passphrase-protected file from some *other* app that
  /// happens to share the format. Belt and braces next to the magic bytes.
  static const String appId = 'secure_shell_go';

  final List<Host> hosts;
  final List<Snippet> snippets;
  final List<TunnelProfile> tunnels;
  final List<PathBookmark> bookmarks;
  final AppSettings settings;

  /// Whether the user opted in to including secrets. Stored explicitly rather
  /// than inferred from `credentials.isNotEmpty`, so that "I asked for
  /// credentials and there were none saved" and "I did not ask" stay
  /// distinguishable in the import preview.
  final bool includesCredentials;

  /// Host id to secrets. Empty unless [includesCredentials].
  final Map<String, SshCredentials> credentials;

  final DateTime? exportedAt;

  /// The group names in use, derived from the hosts. There is no separate
  /// group record to export — a group exists exactly as long as some host
  /// names it (see [Host.group]) — so exporting the hosts *is* exporting the
  /// groups. Surfaced separately only because the import preview counts it as
  /// its own category, which is how users think about it.
  Set<String> get groups => <String>{
        for (final host in hosts)
          if (host.group != null) host.group!,
      };

  /// Hosts that will land needing a password or key typed back in: ones whose
  /// auth method stores a secret, but which have no secret in this file.
  ///
  /// Nothing marks these on the [Host] itself — there is no such field, and
  /// adding a persisted one for a transient condition would be wrong. The app
  /// already handles the state: connecting to a host with nothing in the
  /// credential store shows "No saved credentials for this host" with a way
  /// to edit it. This count exists so the import screen can say up front how
  /// many hosts that will be, instead of letting the user find out one
  /// failed connection at a time.
  int get hostsNeedingCredentials => hosts
      .where((h) => !h.authMethod.storesNoSecret)
      .where((h) => !credentials.containsKey(h.id))
      .length;

  BackupContents get contents => BackupContents(
        hosts: hosts.length,
        groups: groups.length,
        snippets: snippets.length,
        tunnels: tunnels.length,
        bookmarks: bookmarks.length,
        credentials: credentials.length,
        includesCredentials: includesCredentials,
        hostsNeedingCredentials: hostsNeedingCredentials,
        exportedAt: exportedAt,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'app': appId,
        'payloadVersion': payloadVersion,
        if (exportedAt != null) 'exportedAt': exportedAt!.toIso8601String(),
        'includesCredentials': includesCredentials,
        'hosts': [for (final host in hosts) host.toJson()],
        'snippets': [for (final snippet in snippets) snippet.toJson()],
        'tunnels': [for (final tunnel in tunnels) tunnel.toJson()],
        'bookmarks': [for (final bookmark in bookmarks) bookmark.toJson()],
        'settings': settings.toJson(),
        if (includesCredentials)
          'credentials': <String, dynamic>{
            for (final entry in credentials.entries)
              entry.key: _credentialsToJson(entry.value),
          },
      };

  /// UTF-8 JSON, ready to hand to [BackupCrypto.encrypt].
  Uint8List encode() =>
      Uint8List.fromList(utf8.encode(jsonEncode(toJson())));

  /// Parses what [BackupCrypto.decrypt] handed back.
  ///
  /// Strict on purpose, and this is the one place where this app is stricter
  /// than its own stores. `HostStore` and friends skip a malformed entry and
  /// carry on, because losing one row beats bricking the app on a file the
  /// user cannot repair. An import is the opposite situation: the file is
  /// authenticated (a wrong byte would have failed the tag), the user is
  /// standing right there, and quietly dropping three of their forty hosts
  /// during a restore is far worse than refusing and saying why.
  static BackupPayload decode(Uint8List plaintext) {
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(plaintext));
    } catch (_) {
      throw const BackupFormatException(
        'This backup could not be read. It may have been written by a '
        'different program.',
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw const BackupFormatException('This backup is not in a known shape.');
    }
    if (decoded['app'] != appId) {
      throw const BackupFormatException(
        'This backup was not written by SecureShell Go.',
      );
    }
    final version = (decoded['payloadVersion'] as num?)?.toInt() ?? 0;
    if (version > payloadVersion) {
      throw BackupFormatException.versionTooNew(version);
    }
    if (version < 1) {
      throw const BackupFormatException(
        'This backup does not say which version it is.',
      );
    }

    final includesCredentials =
        decoded['includesCredentials'] as bool? ?? false;
    return BackupPayload(
      hosts: _list(decoded['hosts'], 'hosts', Host.fromJson),
      snippets: _list(decoded['snippets'], 'snippets', Snippet.fromJson),
      tunnels: _list(decoded['tunnels'], 'tunnels', TunnelProfile.fromJson),
      bookmarks:
          _list(decoded['bookmarks'], 'bookmarks', PathBookmark.fromJson),
      settings: switch (decoded['settings']) {
        final Map<String, dynamic> json => AppSettings.fromJson(json),
        // Absent settings are not an error — a backup is still useful without
        // them, and AppSettings' own defaults are the sane fallback.
        _ => const AppSettings(),
      },
      includesCredentials: includesCredentials,
      credentials:
          includesCredentials ? _credentials(decoded['credentials']) : const {},
      exportedAt: switch (decoded['exportedAt']) {
        final String iso => DateTime.tryParse(iso),
        _ => null,
      },
    );
  }

  static List<T> _list<T>(
    Object? raw,
    String label,
    T Function(Map<String, dynamic>) parse,
  ) {
    // A missing list reads as empty: a backup with no snippets in it is a
    // perfectly ordinary backup, not a damaged one.
    if (raw == null) return <T>[];
    if (raw is! List) {
      throw BackupFormatException('This backup\'s $label are not readable.');
    }
    final out = <T>[];
    for (final entry in raw) {
      if (entry is! Map<String, dynamic>) {
        throw BackupFormatException('This backup\'s $label are not readable.');
      }
      try {
        out.add(parse(entry));
      } catch (_) {
        // A row missing its id, or with a type where a string belongs. See
        // the class doc for why this refuses rather than skipping.
        throw BackupFormatException(
          'This backup contains a $label entry SecureShell Go cannot read, '
          'so nothing has been imported.',
        );
      }
    }
    return out;
  }

  static Map<String, SshCredentials> _credentials(Object? raw) {
    if (raw == null) return const <String, SshCredentials>{};
    if (raw is! Map) {
      throw const BackupFormatException(
        'This backup\'s saved credentials are not readable.',
      );
    }
    final out = <String, SshCredentials>{};
    for (final entry in raw.entries) {
      final value = entry.value;
      if (value is! Map<String, dynamic>) {
        throw const BackupFormatException(
          'This backup\'s saved credentials are not readable.',
        );
      }
      out['${entry.key}'] = SshCredentials(
        password: value['password'] as String?,
        privateKeyPem: value['privateKeyPem'] as String?,
        passphrase: value['passphrase'] as String?,
      );
    }
    return out;
  }

  static Map<String, dynamic> _credentialsToJson(SshCredentials credentials) =>
      <String, dynamic>{
        if (credentials.password != null) 'password': credentials.password,
        if (credentials.privateKeyPem != null)
          'privateKeyPem': credentials.privateKeyPem,
        if (credentials.passphrase != null)
          'passphrase': credentials.passphrase,
      };
}

/// Per-category counts, for the "here is what is in this file" preview the
/// import flow shows before anything is written.
class BackupContents {
  const BackupContents({
    required this.hosts,
    required this.groups,
    required this.snippets,
    required this.tunnels,
    required this.bookmarks,
    required this.credentials,
    required this.includesCredentials,
    required this.hostsNeedingCredentials,
    this.exportedAt,
  });

  final int hosts;
  final int groups;
  final int snippets;
  final int tunnels;
  final int bookmarks;
  final int credentials;
  final bool includesCredentials;
  final int hostsNeedingCredentials;
  final DateTime? exportedAt;

  /// True when there is nothing at all to import — worth telling the user
  /// before they pick merge or replace, since "replace" with an empty file
  /// would otherwise be an alarmingly effective way to erase everything.
  bool get isEmpty =>
      hosts == 0 && snippets == 0 && tunnels == 0 && bookmarks == 0;
}
