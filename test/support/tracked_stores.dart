import 'dart:async';

import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/services/bridge/bridge_audit.dart';
import 'package:secure_shell_go/services/bridge/bridge_client_store.dart';
import 'package:secure_shell_go/services/host_store.dart';

/// Counts the store calls still running, so a widget test can wait until a
/// screen's file work has really finished instead of for a number of event
/// loop turns (which is too few on a slow CI runner).
class IoTracker {
  int _inFlight = 0;

  /// True while any tracked call has not completed.
  bool get busy => _inFlight > 0;

  Future<T> track<T>(Future<T> Function() op) async {
    _inFlight++;
    try {
      return await op();
    } finally {
      _inFlight--;
    }
  }
}

/// A real [HostStore] whose calls are counted by [io].
class TrackedHostStore extends HostStore {
  TrackedHostStore(this.io, {super.file});

  final IoTracker io;

  @override
  Future<void> ensureLoaded() => io.track(super.ensureLoaded);

  @override
  Future<List<Host>> all() => io.track(super.all);

  @override
  Future<Host?> get(String id) => io.track(() => super.get(id));

  @override
  Future<void> add(Host host) => io.track(() => super.add(host));

  @override
  Future<void> update(Host host) => io.track(() => super.update(host));

  @override
  Future<void> modify(String id, Host Function(Host current) change) =>
      io.track(() => super.modify(id, change));

  @override
  Future<void> delete(String id) => io.track(() => super.delete(id));

  @override
  Future<void> replaceAll(Iterable<Host> hosts) =>
      io.track(() => super.replaceAll(hosts));

  @override
  Future<List<String>> groupNames() => io.track(super.groupNames);
}

/// A real [BridgeClientStore] whose calls are counted by [io].
class TrackedClientStore extends BridgeClientStore {
  TrackedClientStore(this.io, {super.file});

  final IoTracker io;

  @override
  Future<List<BridgeClient>> load() => io.track(super.load);

  @override
  Future<({BridgeClient client, String token})> create(
    String name, {
    bool pending = false,
  }) => io.track(() => super.create(name, pending: pending));

  @override
  Future<void> confirm(String id) => io.track(() => super.confirm(id));

  @override
  Future<BridgeClient?> verify(String token) =>
      io.track(() => super.verify(token));

  @override
  Future<void> revoke(String id) => io.track(() => super.revoke(id));
}

/// A real [BridgeAuditLog] whose reads and clears are counted by [io].
/// (Writes are left alone: the screens never write.)
class TrackedAuditLog extends BridgeAuditLog {
  TrackedAuditLog(this.io, {required super.scrub, super.directory});

  final IoTracker io;

  @override
  Future<List<BridgeAuditEntry>> recent({int limit = 200}) =>
      io.track(() => super.recent(limit: limit));

  @override
  Future<bool> clear() => io.track(super.clear);
}
