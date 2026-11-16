import 'dart:async';
import 'dart:collection';

import 'bridge_approvals.dart' show BridgeTimerFactory;

/// One time-limited approval: [clientId] may make changes on [hostId]
/// without asking until [expiresAt]. Never a terminal.
class BridgeGrant {
  const BridgeGrant({
    required this.clientId,
    required this.hostId,
    required this.grantedAt,
    required this.expiresAt,
    this.clientName,
    this.hostName,
  });

  final String clientId;
  final String hostId;
  final DateTime grantedAt;
  final DateTime expiresAt;

  /// For the list in Settings; not part of the key.
  final String? clientName;
  final String? hostName;

  /// Time left at [now]; zero once expired.
  Duration remainingAt(DateTime now) {
    final left = expiresAt.difference(now);
    return left.isNegative ? Duration.zero : left;
  }

  @override
  String toString() => 'BridgeGrant($clientId → $hostId until $expiresAt)';
}

/// Time-limited approvals, keyed by (client id, host id). In memory only:
/// never persisted, so gone on restart. The bridge service clears them on
/// bridge off, on revoke of the client, on app lock, and the dispatcher
/// drops those of hosts that no longer allow changes.
///
/// A grant is live while the clock is strictly before its expiry: at the
/// expiry instant it is already gone.
class BridgeGrants {
  BridgeGrants({DateTime Function()? clock, BridgeTimerFactory? timer})
    : _clock = clock ?? DateTime.now,
      _timer = timer ?? ((d, f) => Timer(d, f));

  final DateTime Function() _clock;
  final BridgeTimerFactory _timer;
  final LinkedHashMap<(String, String), _Live> _grants = LinkedHashMap();
  final StreamController<List<BridgeGrant>> _changes =
      StreamController<List<BridgeGrant>>.broadcast();
  var _disposed = false;

  /// Live grants now, oldest first.
  List<BridgeGrant> get current {
    _sweep(publish: true);
    return List.unmodifiable([for (final g in _grants.values) g.grant]);
  }

  /// [current] now, then again on every change (granted, revoked,
  /// expired). For the list with remaining time.
  Stream<List<BridgeGrant>> get changes =>
      Stream<List<BridgeGrant>>.multi((sink) {
        sink.add(current);
        final sub = _changes.stream.listen(sink.add, onDone: sink.close);
        sink.onCancel = sub.cancel;
      });

  /// Lets [clientId] change [hostId] without asking for [duration] from
  /// now, replacing any grant it already had there. A non-positive
  /// duration grants nothing.
  BridgeGrant? grant(
    String clientId,
    String hostId,
    Duration duration, {
    String? clientName,
    String? hostName,
  }) {
    if (_disposed || duration <= Duration.zero) return null;
    final now = _clock();
    final grant = BridgeGrant(
      clientId: clientId,
      hostId: hostId,
      grantedAt: now,
      expiresAt: now.add(duration),
      clientName: clientName,
      hostName: hostName,
    );
    final key = (clientId, hostId);
    _grants.remove(key)?.timer.cancel();
    final live = _Live(grant);
    live.timer = _timer(duration, () => _expire(key, live));
    _grants[key] = live;
    _publish();
    return grant;
  }

  /// Whether [clientId] holds a live grant on [hostId].
  bool hasLive(String clientId, String hostId) {
    final live = _grants[(clientId, hostId)];
    if (live == null) return false;
    if (_clock().isBefore(live.grant.expiresAt)) return true;
    _expire((clientId, hostId), live);
    return false;
  }

  void revokeClient(String clientId) =>
      _removeWhere((g) => g.clientId == clientId);

  /// Every grant of a client not in [clientIds] (they were revoked).
  void revokeClientsExcept(Set<String> clientIds) =>
      _removeWhere((g) => !clientIds.contains(g.clientId));

  void revokeHost(String hostId) => _removeWhere((g) => g.hostId == hostId);

  /// Every grant on a host not in [hostIds] (un-shared or stepped down).
  void retainHosts(Set<String> hostIds) =>
      _removeWhere((g) => !hostIds.contains(g.hostId));

  /// One grant, from "Stop now".
  void revoke(String clientId, String hostId) =>
      _removeWhere((g) => g.clientId == clientId && g.hostId == hostId);

  void revokeAll() => _removeWhere((_) => true);

  void _removeWhere(bool Function(BridgeGrant g) test) {
    var changed = false;
    for (final entry in _grants.entries.toList()) {
      if (test(entry.value.grant)) {
        entry.value.timer.cancel();
        _grants.remove(entry.key);
        changed = true;
      }
    }
    if (changed) _publish();
  }

  void _expire((String, String) key, _Live live) {
    if (!identical(_grants[key], live)) return;
    live.timer.cancel();
    _grants.remove(key);
    _publish();
  }

  /// Drops anything the clock has passed whose timer has not run yet.
  void _sweep({required bool publish}) {
    final now = _clock();
    var changed = false;
    for (final entry in _grants.entries.toList()) {
      if (!now.isBefore(entry.value.grant.expiresAt)) {
        entry.value.timer.cancel();
        _grants.remove(entry.key);
        changed = true;
      }
    }
    if (changed && publish) _publish();
  }

  void _publish() {
    if (_changes.isClosed) return;
    _sweep(publish: false);
    _changes.add(List.unmodifiable([for (final g in _grants.values) g.grant]));
  }

  Future<void> dispose() async {
    revokeAll();
    _disposed = true;
    await _changes.close();
  }
}

class _Live {
  _Live(this.grant);

  final BridgeGrant grant;
  late Timer timer;
}
