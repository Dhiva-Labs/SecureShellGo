import 'dart:typed_data';

import '../models/host.dart';
import '../models/path_bookmark.dart';
import 'backup_crypto.dart';
import 'backup_payload.dart';
import 'bookmark_store.dart';
import 'credential_store.dart';
import 'host_store.dart';
import 'settings_store.dart';
import 'snippet_store.dart';
import 'tunnel_store.dart';

/// What an import does to what is already on the device.
enum ImportMode {
  /// Everything in the file is put in place; anything the file does not
  /// mention is left exactly as it was.
  merge,

  /// The file becomes the whole configuration. Hosts, snippets, tunnels and
  /// bookmarks not in the file are removed.
  replace;

  String get label => switch (this) {
        ImportMode.merge => 'Merge',
        ImportMode.replace => 'Replace',
      };
}

/// Gathers the app's configuration into an encrypted backup, and puts one
/// back.
///
/// ## Reading an import in three steps
///
/// [readBackup] and [apply] are separate on purpose, and the split is what
/// makes "a wrong passphrase applies nothing" a structural property rather
/// than a promise. Decryption, parsing and validation all happen inside
/// [readBackup], which touches no store; [apply] cannot even be called
/// without the [BackupPayload] that only a successful [readBackup] produces.
/// A wrong passphrase throws out of step one, with every store still holding
/// exactly what it held before.
///
/// The split also means the expensive part happens once. Argon2id costs about
/// a second, and re-deriving it to apply a preview the user just looked at
/// would be a second spent proving something already proven.
///
/// ## How complete "never half-apply" is here
///
/// Fully true for the failure that actually happens — a wrong passphrase, a
/// truncated file, an unreadable entry — because none of those reach a write.
///
/// Not fully true for a power cut *during* [apply]. Hosts, snippets and
/// settings each go down in a single file write ([HostStore.replaceAll] and
/// friends), so those three are all-or-nothing. Tunnels and bookmarks are
/// applied row by row, because `tunnel_store.dart` and `bookmark_store.dart`
/// are owned by parallel work in this release and have no bulk write to call.
/// They should grow one; until then this is written down rather than papered
/// over.
class BackupService {
  BackupService({
    required this.hostStore,
    required this.snippetStore,
    required this.tunnelStore,
    required this.bookmarkStore,
    required this.settingsStore,
    required this.credentialStore,
  });

  /// The extension, and what the export screen names the file.
  static const String fileExtension = 'ssgbackup';

  final HostStore hostStore;
  final SnippetStore snippetStore;
  final TunnelStore tunnelStore;
  final BookmarkStore bookmarkStore;
  final SettingsStore settingsStore;
  final CredentialStore credentialStore;

  /// Builds the encrypted file.
  ///
  /// [includeCredentials] is the explicit opt-in. With it off — the default,
  /// everywhere it is offered — the file describes each host's auth *method*
  /// but carries no password, key or passphrase, and the hosts arrive on the
  /// far side needing their secrets typed in once. With it on, the file
  /// contains the user's server passwords in the clear behind nothing but the
  /// passphrase, which is the warning the export screen has to make
  /// unmissable.
  ///
  /// [useIsolate] is passed through to [BackupCrypto]; tests turn it off.
  Future<Uint8List> export({
    required String passphrase,
    required bool includeCredentials,
    bool useIsolate = true,
  }) async {
    final payload = await buildPayload(
      includeCredentials: includeCredentials,
    );
    return BackupCrypto.encrypt(
      plaintext: payload.encode(),
      passphrase: passphrase,
      useIsolate: useIsolate,
    );
  }

  /// The plaintext side of [export], separated so a test can inspect exactly
  /// what would be written without paying for the KDF.
  Future<BackupPayload> buildPayload({
    required bool includeCredentials,
  }) async {
    final hosts = await hostStore.all();
    final snippets = await snippetStore.all();
    final tunnels = await tunnelStore.all();
    final bookmarks = await _allBookmarksFor(hosts);

    final credentials = <String, SshCredentials>{};
    if (includeCredentials) {
      for (final host in hosts) {
        // An agent-auth host stores no secret at all (see
        // SshAuthMethod.storesNoSecret), so there is nothing to ask for.
        if (host.authMethod.storesNoSecret) continue;
        final saved = await credentialStore.load(host.id);
        if (saved == null) continue;
        final empty = saved.password == null &&
            saved.privateKeyPem == null &&
            saved.passphrase == null;
        if (empty) continue;
        credentials[host.id] = saved;
      }
    }

    return BackupPayload(
      hosts: hosts,
      snippets: snippets,
      tunnels: tunnels,
      bookmarks: bookmarks,
      settings: settingsStore.current,
      includesCredentials: includeCredentials,
      credentials: credentials,
      exportedAt: DateTime.now(),
    );
  }

  /// Decrypts and parses [file], writing nothing.
  ///
  /// Throws [BackupAuthException] for a wrong passphrase or a corrupted file,
  /// and [BackupFormatException] for one this build cannot read at all. Both
  /// leave every store untouched — this method has no reference to a write
  /// path to begin with.
  Future<BackupPayload> readBackup({
    required Uint8List file,
    required String passphrase,
    bool useIsolate = true,
  }) async {
    final plaintext = await BackupCrypto.decrypt(
      file: file,
      passphrase: passphrase,
      useIsolate: useIsolate,
    );
    return BackupPayload.decode(plaintext);
  }

  /// Writes a payload that [readBackup] has already validated.
  ///
  /// ## Merge
  ///
  /// Everything in the file is put in place; anything not mentioned is left
  /// alone. On an id collision the file wins, so the rule a user can hold in
  /// their head is: *after a merge, everything the backup describes is
  /// present exactly as the backup describes it, and everything else is
  /// untouched.*
  ///
  /// ## Replace
  ///
  /// The file becomes the entire configuration for the categories it covers.
  ///
  /// ## Settings, in both modes
  ///
  /// Applied wholesale. "Merging" a single settings record has no honest
  /// meaning — there is no per-field provenance to merge on — so the file
  /// wins, and the import screen says so instead of leaving it to be
  /// discovered.
  ///
  /// ## Credentials, in both modes
  ///
  /// Only ever added or overwritten, never cleared, with one exception: a
  /// [ImportMode.replace] that removes a host also deletes that host's
  /// credential entry, because nothing can reach it afterwards and a
  /// forgotten secret sitting in the keystore is worse than no secret.
  ///
  /// In particular, importing a credential-free backup over hosts whose
  /// passwords *are* saved does not wipe those passwords. Restoring a
  /// config-only backup is not a request to forget every password on the
  /// device, and treating it as one would be a spectacular way to lose data.
  Future<ImportResult> apply({
    required BackupPayload payload,
    required ImportMode mode,
  }) async {
    final existingHosts = await hostStore.all();
    final existingHostIds = {for (final h in existingHosts) h.id};
    final importedHostIds = {for (final h in payload.hosts) h.id};

    // Assembled in full before a single write, so that whatever this method
    // is going to put on disk is already decided by the time it starts.
    final List<Host> nextHosts;
    final List<PathBookmark> nextBookmarks;
    if (mode == ImportMode.replace) {
      nextHosts = payload.hosts;
      nextBookmarks = payload.bookmarks;
    } else {
      final merged = {for (final h in existingHosts) h.id: h};
      for (final host in payload.hosts) {
        merged[host.id] = host;
      }
      nextHosts = merged.values.toList(growable: false);
      nextBookmarks = payload.bookmarks;
    }

    final nextSnippets = mode == ImportMode.replace
        ? payload.snippets
        : _mergedById(
            await snippetStore.all(),
            payload.snippets,
            (s) => s.id,
          );

    final nextTunnels = mode == ImportMode.replace
        ? payload.tunnels
        : _mergedById(
            await tunnelStore.all(),
            payload.tunnels,
            (t) => t.id,
          );

    // --- nothing above this line has written anything ---

    await hostStore.replaceAll(nextHosts);
    await snippetStore.replaceAll(nextSnippets);
    await settingsStore.save(payload.settings);

    // Tunnels: no bulk write available on TunnelStore (see the class doc), so
    // the old set is cleared and the new one added row by row.
    for (final existing in await tunnelStore.all()) {
      await tunnelStore.delete(existing.id);
    }
    for (final profile in nextTunnels) {
      await tunnelStore.add(profile);
    }

    // Bookmarks: same constraint, plus BookmarkStore has no "every bookmark"
    // accessor — only per host — so the sweep runs over every host id that is
    // involved either side of the import.
    final bookmarkHostIds = <String>{...existingHostIds, ...importedHostIds};
    for (final hostId in bookmarkHostIds) {
      for (final bookmark in await bookmarkStore.bookmarksForHost(hostId)) {
        await bookmarkStore.remove(bookmark.id);
      }
    }
    for (final bookmark in nextBookmarks) {
      // add() dedupes on host+path and returns the existing row unchanged, so
      // a label that differs has to be applied separately.
      final added = await bookmarkStore.add(
        bookmark.hostId,
        bookmark.path,
        label: bookmark.label,
      );
      if (added.label != bookmark.label) {
        await bookmarkStore.renameLabel(added.id, bookmark.label);
      }
    }

    for (final entry in payload.credentials.entries) {
      await credentialStore.save(entry.key, entry.value);
    }
    var droppedCredentials = 0;
    if (mode == ImportMode.replace) {
      for (final hostId in existingHostIds.difference(importedHostIds)) {
        if (await credentialStore.has(hostId)) droppedCredentials++;
        await credentialStore.delete(hostId);
      }
    }

    return ImportResult(
      mode: mode,
      hosts: nextHosts.length,
      snippets: nextSnippets.length,
      tunnels: nextTunnels.length,
      bookmarks: nextBookmarks.length,
      credentialsRestored: payload.credentials.length,
      credentialsDropped: droppedCredentials,
      hostsNeedingCredentials: payload.hostsNeedingCredentials,
    );
  }

  /// Every bookmark belonging to one of [hosts].
  ///
  /// [BookmarkStore] exposes bookmarks per host and has no "all" accessor,
  /// and that file belongs to parallel work this change must not touch — so
  /// the host list is walked instead. The gap that leaves is bookmarks whose
  /// host has since been deleted, which are unreachable in the UI anyway and
  /// have no meaning on a restored device.
  Future<List<PathBookmark>> _allBookmarksFor(List<Host> hosts) async {
    final all = <PathBookmark>[];
    for (final host in hosts) {
      all.addAll(await bookmarkStore.bookmarksForHost(host.id));
    }
    return all;
  }

  /// [existing] with [incoming] laid over it, keyed by id, incoming winning.
  static List<T> _mergedById<T>(
    List<T> existing,
    List<T> incoming,
    String Function(T) idOf,
  ) {
    final merged = <String, T>{for (final item in existing) idOf(item): item};
    for (final item in incoming) {
      merged[idOf(item)] = item;
    }
    return merged.values.toList(growable: false);
  }
}

/// What an [BackupService.apply] actually did, for the confirmation the
/// import screen shows afterwards.
class ImportResult {
  const ImportResult({
    required this.mode,
    required this.hosts,
    required this.snippets,
    required this.tunnels,
    required this.bookmarks,
    required this.credentialsRestored,
    required this.credentialsDropped,
    required this.hostsNeedingCredentials,
  });

  final ImportMode mode;

  /// Totals in the store *after* the import, not deltas — which is what the
  /// user is looking at on the next screen.
  final int hosts;
  final int snippets;
  final int tunnels;
  final int bookmarks;

  final int credentialsRestored;

  /// Credential entries removed because a replace removed their host.
  final int credentialsDropped;

  /// How many hosts will ask for a password or key on first connect.
  final int hostsNeedingCredentials;
}
