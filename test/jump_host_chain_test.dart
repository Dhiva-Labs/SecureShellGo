import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/services/jump_host_chain.dart';

Host _host(String id, {String? via, String? label}) => Host(
      id: id,
      label: label ?? id,
      hostname: '$id.example.com',
      port: 22,
      username: 'dev',
      authMethod: SshAuthMethod.password,
      jumpHostId: via,
    );

/// Stands in for `HostStore.get`, counting lookups so a runaway walk shows up
/// as a count rather than as a hung test.
class _Store {
  _Store(List<Host> hosts)
      : _byId = {for (final host in hosts) host.id: host};

  final Map<String, Host> _byId;
  int lookups = 0;

  Future<Host?> get(String id) async {
    lookups++;
    return _byId[id];
  }
}

void main() {
  group('JumpHostChain.resolve', () {
    test('a host with no jump host needs no hops', () async {
      final store = _Store([_host('a')]);
      final hops = await JumpHostChain.resolve(
        host: _host('a'),
        lookup: store.get,
      );
      expect(hops, isEmpty);
      expect(store.lookups, 0);
    });

    test('a single jump host resolves to that one hop', () async {
      final store = _Store([_host('b')]);
      final hops = await JumpHostChain.resolve(
        host: _host('a', via: 'b'),
        lookup: store.get,
      );
      expect([for (final h in hops) h.id], ['b']);
    });

    // A via B via C: C is the only hop this device can dial, so it has to
    // come first and the target is never in the list.
    test('a chain comes back in dial order, farthest hop first', () async {
      final store = _Store([_host('b', via: 'c'), _host('c')]);
      final hops = await JumpHostChain.resolve(
        host: _host('a', via: 'b'),
        lookup: store.get,
      );
      expect([for (final h in hops) h.id], ['c', 'b']);
    });

    test('a four-host chain keeps the same ordering', () async {
      final store = _Store([
        _host('b', via: 'c'),
        _host('c', via: 'd'),
        _host('d'),
      ]);
      final hops = await JumpHostChain.resolve(
        host: _host('a', via: 'b'),
        lookup: store.get,
      );
      expect([for (final h in hops) h.id], ['d', 'c', 'b']);
    });

    test('a host that jumps via itself is rejected by name', () async {
      final store = _Store([]);
      await expectLater(
        JumpHostChain.resolve(
          host: _host('a', via: 'a', label: 'Bastion'),
          lookup: store.get,
        ),
        throwsA(
          isA<JumpHostChainException>()
              .having((e) => e.kind, 'kind',
                  JumpHostChainError.selfReference)
              .having((e) => e.message, 'message', contains('via itself'))
              .having((e) => e.message, 'message', contains('Bastion')),
        ),
      );
      // Rejected on the link itself, without ever asking the store.
      expect(store.lookups, 0);
    });

    test('a two-host loop is rejected rather than recursing', () async {
      final store = _Store([_host('b', via: 'a')]);
      await expectLater(
        JumpHostChain.resolve(
          host: _host('a', via: 'b'),
          lookup: store.get,
        ),
        throwsA(
          isA<JumpHostChainException>()
              .having((e) => e.kind, 'kind', JumpHostChainError.cycle)
              .having((e) => e.message, 'message', contains('loop')),
        ),
      );
      // The walk stopped as soon as a host repeated, so it cannot have
      // spun: one lookup for b, then the loop is seen on the link back.
      expect(store.lookups, lessThan(4));
    });

    test('a three-host loop is rejected too', () async {
      final store = _Store([
        _host('b', via: 'c'),
        _host('c', via: 'a'),
      ]);
      await expectLater(
        JumpHostChain.resolve(
          host: _host('a', via: 'b'),
          lookup: store.get,
        ),
        throwsA(isA<JumpHostChainException>()
            .having((e) => e.kind, 'kind', JumpHostChainError.cycle)),
      );
      expect(store.lookups, lessThan(6));
    });

    test('a loop that does not include the target is still caught', () async {
      // a -> b -> c -> b. The target is never revisited, so only tracking
      // "did we come back to the start" would miss this one.
      final store = _Store([
        _host('b', via: 'c'),
        _host('c', via: 'b'),
      ]);
      await expectLater(
        JumpHostChain.resolve(
          host: _host('a', via: 'b'),
          lookup: store.get,
        ),
        throwsA(isA<JumpHostChainException>()
            .having((e) => e.kind, 'kind', JumpHostChainError.cycle)),
      );
    });

    test('a jump host that no longer exists names the host to edit', () async {
      final store = _Store([]);
      await expectLater(
        JumpHostChain.resolve(
          host: _host('a', via: 'gone', label: 'Prod DB'),
          lookup: store.get,
        ),
        throwsA(
          isA<JumpHostChainException>()
              .having((e) => e.kind, 'kind', JumpHostChainError.missing)
              .having((e) => e.message, 'message', contains('Prod DB'))
              .having((e) => e.message, 'message', contains('no longer')),
        ),
      );
    });

    test('a dangling reference midway names the hop that holds it', () async {
      final store = _Store([_host('b', via: 'gone', label: 'Bastion')]);
      await expectLater(
        JumpHostChain.resolve(
          host: _host('a', via: 'b'),
          lookup: store.get,
        ),
        throwsA(
          isA<JumpHostChainException>()
              .having((e) => e.kind, 'kind', JumpHostChainError.missing)
              .having((e) => e.message, 'message', contains('Bastion')),
        ),
      );
    });

    test('an over-long acyclic chain is refused', () async {
      // A straight line of distinct hosts, longer than the cap: no host ever
      // repeats, so only the depth limit can stop this one.
      final hosts = <Host>[
        for (var i = 0; i < JumpHostChain.maxDepth + 3; i++)
          _host('h$i', via: 'h${i + 1}'),
      ];
      final store = _Store(hosts);
      await expectLater(
        JumpHostChain.resolve(host: hosts.first, lookup: store.get),
        throwsA(isA<JumpHostChainException>()
            .having((e) => e.kind, 'kind', JumpHostChainError.tooDeep)),
      );
    });

    test('a chain exactly at the cap still resolves', () async {
      final hosts = <Host>[
        for (var i = 0; i < JumpHostChain.maxDepth; i++)
          _host('h$i', via: 'h${i + 1}'),
        _host('h${JumpHostChain.maxDepth}'),
      ];
      final store = _Store(hosts);
      final hops = await JumpHostChain.resolve(
        host: hosts.first,
        lookup: store.get,
      );
      expect(hops, hasLength(JumpHostChain.maxDepth));
      expect(hops.first.id, 'h${JumpHostChain.maxDepth}');
    });
  });
}
