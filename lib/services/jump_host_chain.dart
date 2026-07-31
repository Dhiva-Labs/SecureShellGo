import '../models/host.dart';

/// Why a jump-host chain could not be resolved.
///
/// The kinds exist so the connect path can say which of four quite different
/// things went wrong before a single packet is sent — a dangling reference is
/// a bookkeeping problem the user fixes in the editor, a loop is a mistake
/// they have to break, and neither is "the server is down".
enum JumpHostChainError {
  /// A host names itself as its own jump host.
  selfReference,

  /// The chain loops: A via B via A.
  cycle,

  /// A `jumpHostId` points at a host that is no longer saved.
  missing,

  /// The chain is longer than [JumpHostChain.maxDepth].
  tooDeep,
}

/// Raised when a host's jump-host chain cannot be turned into a dial plan.
///
/// Always thrown *before* any network I/O happens, so catching this is how the
/// connect path knows nothing needs tearing down.
class JumpHostChainException implements Exception {
  const JumpHostChainException(this.kind, this.message);

  final JumpHostChainError kind;

  /// Human-readable and safe to put straight in the error banner.
  final String message;

  @override
  String toString() => message;
}

/// Turns a host's `jumpHostId` links into the ordered list of hops to dial.
///
/// Pure resolution — it opens nothing and knows nothing about sockets — so
/// the loop detection that keeps a misconfigured chain from recursing forever
/// can be tested directly. [SshService] calls this first and dials the result
/// in order.
class JumpHostChain {
  /// Ceiling on hops, guarding against a chain that is technically acyclic
  /// but absurd. OpenSSH imposes no such limit; we do, because every hop is a
  /// full handshake the user waits through, and eight is far past any real
  /// bastion topology.
  ///
  /// Note this is a *belt and braces* limit: [resolve] already refuses a
  /// repeated host, so a genuine loop is caught by identity, not by running
  /// into this bound.
  static const int maxDepth = 8;

  /// The hops needed to reach [host], in the order they must be dialled.
  ///
  /// Empty for a direct connection. For "A via B via C" this returns
  /// `[C, B]` — the far end of the chain first, because C is the only hop
  /// reachable from this device; B is reached through C, and A through B.
  /// [host] itself is never included.
  ///
  /// Throws [JumpHostChainException] for a self-reference, a loop, a jump
  /// host that no longer exists, or a chain past [maxDepth].
  static Future<List<Host>> resolve({
    required Host host,
    required Future<Host?> Function(String id) lookup,
  }) async {
    // Links followed so far, starting with the target. Membership is what
    // makes a loop detectable: any host reached twice closes one.
    final visited = <String>{host.id};
    final links = <Host>[];

    var current = host;
    while (current.jumpHostId != null) {
      final nextId = current.jumpHostId!;

      if (nextId == current.id) {
        throw JumpHostChainException(
          JumpHostChainError.selfReference,
          '"${current.displayName}" is set to connect via itself. Edit it and '
          'choose a different jump host, or connect directly.',
        );
      }

      if (!visited.add(nextId)) {
        throw JumpHostChainException(
          JumpHostChainError.cycle,
          'The jump hosts for "${host.displayName}" form a loop '
          '(${_describeLoop(host, links, nextId)}). Edit one of them to break '
          'it.',
        );
      }

      if (links.length >= maxDepth) {
        throw JumpHostChainException(
          JumpHostChainError.tooDeep,
          'The jump-host chain for "${host.displayName}" is more than '
          '$maxDepth hops long. Shorten it.',
        );
      }

      final next = await lookup(nextId);
      if (next == null) {
        throw JumpHostChainException(
          JumpHostChainError.missing,
          'The jump host saved for "${current.displayName}" no longer exists. '
          'Edit "${current.displayName}" and pick another one, or connect '
          'directly.',
        );
      }

      links.add(next);
      current = next;
    }

    // [links] runs target-outwards (the target's own jump first); dialling
    // has to run the other way, from the hop this device can actually reach.
    return links.reversed.toList(growable: false);
  }

  /// `A -> B -> A`, for the loop message. Best-effort readability only.
  static String _describeLoop(Host host, List<Host> links, String repeatedId) {
    final walked = <Host>[host, ...links];
    var repeated = '...';
    for (final candidate in walked) {
      if (candidate.id == repeatedId) {
        repeated = candidate.displayName;
        break;
      }
    }
    final names = [for (final h in walked) h.displayName].join(' -> ');
    return '$names -> $repeated';
  }
}
