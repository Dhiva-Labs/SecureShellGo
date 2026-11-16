import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../../models/host.dart';
import '../../models/remote_entry.dart';
import '../credential_store.dart';
import '../headless_dialer.dart';
import '../sftp_service.dart';
import '../ssh_service.dart';

/// The live session's transport for a host, or null when none is open.
typedef BridgeOpenTransport = SessionTransport? Function(String hostId);

/// Loads what is saved for a host without ever prompting;
/// `CredentialStore.loadQuiet` fits, and throws [CredentialsNeedPerson]
/// when the store needs a person to open it.
typedef BridgeCredentialLookup =
    Future<SshCredentials?> Function(String hostId);

/// Dials and signs in with nobody to ask; `HeadlessDialer.dial` fits.
/// Throws [SignInNeedsPerson] when that is why it could not.
typedef BridgeDialer =
    Future<SessionTransport> Function(Host host, SshCredentials credentials);

/// Opens the file side of a transport for one call.
typedef BridgeFilesOpener =
    Future<BridgeFiles> Function(SessionTransport transport);

/// Why a bridge call could not reach its host, worded for the assistant to
/// pass on as it stands.
class BridgeConnectFailure implements Exception {
  const BridgeConnectFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

/// What a path is, as far as the bridge tools care.
enum BridgeFileType { file, directory, other }

class BridgeFileStat {
  const BridgeFileStat({required this.type, this.size});

  final BridgeFileType type;
  final int? size;
}

/// The SFTP operations the read tools need, and nothing that writes.
///
/// Its own seam rather than [RemoteFileSystem] for two reasons. [realpath]
/// must fail when the server cannot resolve a path — `SftpService.resolve`
/// falls back to the path it was given, which is right for a file browser and
/// wrong for a guard that must judge where a symlink really points. And
/// [read] takes a window, so a slice of a large file is never fetched by
/// downloading the whole of it.
abstract class BridgeFiles {
  /// The server's canonical form of [path], symlinks followed. Throws when
  /// the server will not resolve it.
  Future<String> realpath(String path);

  Future<BridgeFileStat> stat(String path);

  Future<List<RemoteEntry>> list(String path);

  /// At most [length] bytes of [path] from [offset].
  Future<Uint8List> read(
    String path, {
    required int offset,
    required int length,
  });

  Future<void> close();
}

/// What is at a path itself, symlinks not followed (`lstat`).
enum BridgeEntryKind { missing, file, directory, symlink, other }

/// The writes `write_file` needs, kept off [BridgeFiles] so the read tools
/// (and every read fake) never hold a way to write. Only [SftpBridgeFiles]
/// implements it; a change tool checks for it.
abstract class BridgeFileWrites {
  /// What is at [path] itself: a symlink is reported as one, not followed.
  /// [BridgeEntryKind.missing] when nothing is there (or the server will
  /// not say).
  Future<BridgeEntryKind> entryKind(String path);

  /// The editor's seams over the same SFTP channel, so a write uses the
  /// editor's temp-then-rename and conflict guard (`editor_save.dart`).
  RemoteFileSystem get remoteFileSystem;
  RemoteFileMetadata get remoteMetadata;
}

/// [BridgeFiles] over a dartssh2 SFTP channel.
class SftpBridgeFiles implements BridgeFiles, BridgeFileWrites {
  SftpBridgeFiles(this._client) : _service = SftpService(_client);

  final SftpClient _client;
  final SftpService _service;

  static Future<BridgeFiles> open(SessionTransport transport) async =>
      SftpBridgeFiles(await transport.openSftp());

  @override
  Future<String> realpath(String path) => _client.absolute(path);

  @override
  Future<BridgeFileStat> stat(String path) async {
    final attrs = await _client.stat(path);
    return BridgeFileStat(
      type: attrs.isDirectory
          ? BridgeFileType.directory
          : attrs.isFile
          ? BridgeFileType.file
          : BridgeFileType.other,
      size: attrs.size,
    );
  }

  @override
  Future<List<RemoteEntry>> list(String path) => _service.list(path);

  @override
  Future<BridgeEntryKind> entryKind(String path) async {
    final SftpFileAttrs attrs;
    try {
      attrs = await _client.stat(path, followLink: false);
    } catch (_) {
      return BridgeEntryKind.missing;
    }
    if (attrs.isSymbolicLink) return BridgeEntryKind.symlink;
    if (attrs.isDirectory) return BridgeEntryKind.directory;
    if (attrs.isFile) return BridgeEntryKind.file;
    return BridgeEntryKind.other;
  }

  @override
  RemoteFileSystem get remoteFileSystem => _service;

  @override
  RemoteFileMetadata get remoteMetadata => _service;

  @override
  Future<Uint8List> read(
    String path, {
    required int offset,
    required int length,
  }) async {
    final file = await _client.open(path, mode: SftpFileOpenMode.read);
    try {
      final out = BytesBuilder(copy: false);
      // dartssh2 stops at [length] or at the end of the file, whichever is
      // first, so nothing past the window is ever requested.
      await for (final chunk in file.read(offset: offset, length: length)) {
        out.add(chunk);
        if (out.length >= length) break;
      }
      final bytes = out.takeBytes();
      return bytes.length > length
          ? Uint8List.sublistView(bytes, 0, length)
          : bytes;
    } finally {
      try {
        await file.close();
      } catch (_) {
        // Channel already gone.
      }
    }
  }

  @override
  Future<void> close() async {
    try {
      await _client.close();
    } catch (_) {
      // Already gone.
    }
  }
}

/// One call's hold on a host's connection. [release] must be called once the
/// call is done; it never closes a session's own transport.
class BridgeLease {
  BridgeLease._(this.transport, this._openFiles, this._onRelease);

  final SessionTransport transport;
  final BridgeFilesOpener _openFiles;
  final void Function() _onRelease;
  Future<BridgeFiles>? _files;
  var _released = false;

  /// An SFTP channel for this call, opened on first use and closed by
  /// [release]. A channel of the call's own, even on a session's transport,
  /// so nothing the bridge does can disturb the file browser's.
  Future<BridgeFiles> files() => _files ??= _openFiles(transport);

  Future<void> release() async {
    if (_released) return;
    _released = true;
    final files = _files;
    if (files != null) {
      try {
        await (await files).close();
      } catch (_) {
        // Never opened, or already gone.
      }
    }
    _onRelease();
  }
}

class _Cached {
  _Cached(this.host, this.transport);

  final Host host;
  final SessionTransport transport;
  var leases = 0;
  var stale = false;
  Timer? idle;
}

/// Where a bridge call gets its connection to a host.
///
/// A host with a session open in the app is read over that session's
/// transport — one more channel, no second sign-in, the way a fleet run does
/// it. Any other host is dialled with [HeadlessDialer]'s rules and the
/// connection kept for [idleTimeout] after its last call, so an assistant
/// asking three questions in a row signs in once rather than three times.
class BridgeConnections {
  BridgeConnections({
    required this.openTransport,
    required this.credentialLookup,
    required this.dialer,
    BridgeFilesOpener? openFiles,
    this.idleTimeout = const Duration(seconds: 60),
  }) : _openFiles = openFiles ?? SftpBridgeFiles.open;

  final BridgeOpenTransport openTransport;
  final BridgeCredentialLookup credentialLookup;
  final BridgeDialer dialer;
  final Duration idleTimeout;
  final BridgeFilesOpener _openFiles;

  final Map<String, _Cached> _cached = {};
  final Map<String, Future<_Cached>> _dialing = {};

  /// Bumped by [closeAll], so a dial that was in flight when the bridge was
  /// switched off hangs up as soon as it lands instead of being cached.
  var _generation = 0;

  /// Dialled connections currently held, for tests and the settings screen.
  int get cachedCount => _cached.length;

  /// [host] as every bridge dial hands it to the dialer: with its agent and
  /// X11 forwarding off. Those are the user's choice for the user's own
  /// shell; nothing the bridge opens may carry the user's SSH agent (every
  /// other server it can sign in to) or X11 windows. Jump hops need nothing
  /// here: `SshService` never forwards on a hop, whatever the hop's own
  /// settings say.
  static Host withoutForwarding(Host host) =>
      host.agentForwarding || host.x11Forwarding
      ? host.copyWith(agentForwarding: false, x11Forwarding: false)
      : host;

  /// Whether a session's open transport may be borrowed for a bridge call.
  /// Not when the host forwards the agent or X11: OpenSSH keeps a
  /// connection's agent socket for the whole connection once its shell has
  /// asked for forwarding, so an exec channel the bridge opened on it would
  /// get `SSH_AUTH_SOCK` too (proven in `bridge_local_sshd_test.dart`). The
  /// bridge dials its own connection, without forwarding, instead.
  static bool mayBorrow(SessionTransport open, Host host) =>
      !open.isClosed &&
      !host.agentForwarding &&
      !host.x11Forwarding &&
      !open.host.agentForwarding &&
      !open.host.x11Forwarding;

  /// A lease on [host]'s connection. Throws [BridgeConnectFailure].
  Future<BridgeLease> acquire(Host host) async {
    final open = openTransport(host.id);
    if (open != null && mayBorrow(open, host)) {
      return BridgeLease._(open, _openFiles, () {});
    }

    var entry = _cached[host.id];
    if (entry != null &&
        (entry.transport.isClosed || entry.stale || entry.host != host)) {
      // Dropped underneath us, or the host was edited since: never reuse a
      // connection to an address the user has changed.
      _forget(entry);
      entry = null;
    }
    // A block body on purpose: `remove` returns this very future, and a
    // `whenComplete` callback's future is awaited — it would wait on itself.
    entry ??= await (_dialing[host.id] ??= _dial(host).whenComplete(() {
      _dialing.remove(host.id);
    }));
    // Looked at again after the wait: [closeAll] may have run, or the
    // connection dropped, between the dial landing and this caller resuming.
    // A lease is only ever handed out on a connection that is still cached
    // and open.
    if (entry.stale ||
        entry.transport.isClosed ||
        !identical(_cached[host.id], entry)) {
      if (identical(_cached[host.id], entry)) _forget(entry);
      throw const BridgeConnectFailure(
        'The connection to this host was closed. Try again.',
      );
    }

    entry.leases++;
    entry.idle?.cancel();
    entry.idle = null;
    return BridgeLease._(entry.transport, _openFiles, () => _release(entry!));
  }

  Future<_Cached> _dial(Host host) async {
    final transport = await _connect(host, _generation);
    final entry = _Cached(host, transport);
    final previous = _cached[host.id];
    if (previous != null) _forget(previous);
    _cached[host.id] = entry;
    return entry;
  }

  /// A connection to [host] that belongs to the caller: never cached, never
  /// shared with another call, never a session's transport. Dialled by the
  /// same rules as [acquire]'s (saved sign-in read quietly, no prompt of any
  /// kind, a new or changed host key refused), and hung up at once if the
  /// bridge is switched off while it dials. The caller closes it; the
  /// assistant's terminal hands it to `SessionManager.open`, which closes
  /// it with the session. Throws [BridgeConnectFailure].
  ///
  /// The host's own agent and X11 forwarding are left off ([_connect] does
  /// it for every dial): a terminal an assistant drives must never carry the
  /// user's SSH agent or X11 windows.
  Future<SessionTransport> dialOwned(Host host) =>
      _connect(withoutForwarding(host), _generation);

  /// Signs in to [host] with nobody to ask; [generation] is [_generation]
  /// when the dial began.
  Future<SessionTransport> _connect(Host host, int generation) async {
    final SshCredentials? saved;
    try {
      saved = await credentialLookup(host.id);
    } on CredentialsNeedPerson catch (e) {
      throw BridgeConnectFailure('$e ${_connectOnce(host)}');
    } catch (_) {
      throw BridgeConnectFailure(
        'The saved sign-in for this host could not be read. '
        '${_connectOnce(host)}',
      );
    }
    // Switched off while the credentials were being read: nothing is dialled
    // for a bridge that is no longer on.
    if (generation != _generation) {
      throw const BridgeConnectFailure('The AI Bridge was switched off.');
    }
    final problem = HeadlessDialer.signInProblem(host, saved);
    if (problem != null) {
      throw BridgeConnectFailure('$problem ${_connectOnce(host)}');
    }
    final SessionTransport transport;
    try {
      // The one place a bridge dial reaches the dialer: forwarding off,
      // whichever bridge code path asked.
      transport = await dialer(
        withoutForwarding(host),
        saved ?? const SshCredentials(),
      );
    } on SignInNeedsPerson catch (e) {
      throw BridgeConnectFailure('${e.reason} ${_connectOnce(host)}');
    } on CredentialsNeedPerson catch (e) {
      // A jump host's saved sign-in, read the same quiet way.
      throw BridgeConnectFailure('$e ${_connectOnce(host)}');
    } on SshConnectionException catch (e) {
      throw BridgeConnectFailure(e.message);
    } catch (_) {
      // Not the exception's text: it can carry the address.
      throw const BridgeConnectFailure('Could not connect to this host.');
    }
    if (generation != _generation) {
      _hangUp(transport);
      throw const BridgeConnectFailure('The AI Bridge was switched off.');
    }
    return transport;
  }

  static String _connectOnce(Host host) =>
      'Signing in to this host needs a person. Ask the user to connect to it '
      'once in SecureShell Go, then try again.';

  void _release(_Cached entry) {
    entry.leases--;
    if (entry.leases > 0) return;
    if (entry.stale || !identical(_cached[entry.host.id], entry)) {
      _hangUp(entry.transport);
      return;
    }
    entry.idle = Timer(idleTimeout, () {
      if (entry.leases > 0) return;
      if (identical(_cached[entry.host.id], entry)) {
        _cached.remove(entry.host.id);
      }
      _hangUp(entry.transport);
    });
  }

  /// Drops [entry] from the cache; hung up now if idle, else when its last
  /// lease is released.
  void _forget(_Cached entry) {
    entry.stale = true;
    entry.idle?.cancel();
    if (identical(_cached[entry.host.id], entry)) {
      _cached.remove(entry.host.id);
    }
    if (entry.leases <= 0) _hangUp(entry.transport);
  }

  static void _hangUp(SessionTransport transport) {
    try {
      transport.close();
    } catch (_) {
      // Already gone.
    }
  }

  /// Hangs up every dialled connection at once, calls in flight included —
  /// the bridge was switched off, and nothing it opened may outlive that.
  /// Sessions the user opened are not touched.
  Future<void> closeAll() async {
    _generation++;
    for (final entry in _cached.values.toList()) {
      entry.idle?.cancel();
      entry.stale = true;
      _hangUp(entry.transport);
    }
    _cached.clear();
  }
}
