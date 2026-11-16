import '../../models/host.dart';
import '../../models/host_ai_access.dart';
import 'bridge_tool_types.dart';

/// What [decideBridgeCall] says about one tool call.
sealed class BridgeDecision {
  const BridgeDecision();
}

/// The call may run.
final class BridgeAllow extends BridgeDecision {
  const BridgeAllow();

  @override
  bool operator ==(Object other) => other is BridgeAllow;

  @override
  int get hashCode => (BridgeAllow).hashCode;

  @override
  String toString() => 'BridgeAllow()';
}

/// The call is refused. [code] is stable and machine-readable (it goes into
/// the audit log); [message] is what the assistant is told, written so it can
/// pass it on to the user as it stands.
final class BridgeRefuse extends BridgeDecision {
  const BridgeRefuse(this.code, this.message);

  final String code;
  final String message;

  @override
  bool operator ==(Object other) =>
      other is BridgeRefuse && other.code == code && other.message == message;

  @override
  int get hashCode => Object.hash(code, message);

  @override
  String toString() => 'BridgeRefuse($code, $message)';
}

/// The call may run only after a person says yes to it in the app. The
/// dispatcher then asks through `BridgeApprovals`; silence is a no.
final class BridgeNeedsApproval extends BridgeDecision {
  const BridgeNeedsApproval();

  @override
  bool operator ==(Object other) => other is BridgeNeedsApproval;

  @override
  int get hashCode => (BridgeNeedsApproval).hashCode;

  @override
  String toString() => 'BridgeNeedsApproval()';
}

/// The refusals [decideBridgeCall] can give, held in one place so a test can
/// compare against them byte for byte.
class BridgeRefusals {
  const BridgeRefusals._();

  static const BridgeRefuse bridgeOff = BridgeRefuse(
    'bridge_off',
    'The AI Bridge is switched off in SecureShell Go.',
  );

  static const BridgeRefuse appLocked = BridgeRefuse(
    'app_locked',
    'SecureShell Go is locked. Ask the user to unlock it, then try again.',
  );

  /// A change asked of a host the user shared read-only. It says no more
  /// than that the host is read-only, which `list_hosts` already shows by
  /// listing it: nothing about what else is set on it.
  static const BridgeRefuse changesNotAllowed = BridgeRefuse(
    'changes_not_allowed',
    'This host is read-only for the AI assistant: the user has not allowed '
        'changes on it. Do not retry.',
  );

  /// A terminal asked of a host where changes may be requested but the
  /// user has not switched on the assistant's terminal.
  static const BridgeRefuse terminalNotAllowed = BridgeRefuse(
    'terminal_not_allowed',
    'The user has not allowed the AI assistant to open a terminal on this '
        'host. Do not retry.',
  );

  /// A terminal id that names no terminal the caller may use: unknown, one
  /// another paired assistant opened, or one that is no longer the
  /// caller's to use. One refusal for all of these, so an assistant cannot
  /// learn whether another assistant's terminal exists.
  static const BridgeRefuse terminalNotAvailable = BridgeRefuse(
    'terminal_not_available',
    'No terminal by that id is open for you. It may have been closed. '
        'Call open_terminal if you still need one.',
  );

  /// Given both for a name that matches no host and for a host the user has
  /// not opened to the bridge. One refusal for both is the point: if they
  /// differed, an assistant could probe names and learn which servers exist
  /// even though the user chose to hide them.
  static const BridgeRefuse hostNotAvailable = BridgeRefuse(
    'host_not_available',
    'No host by that name is available to the AI Bridge. '
        'Call list_hosts to see the hosts you can use.',
  );
}

/// Whether [a] and [b] are the same host reaching the same server: the same
/// id, address, port, user name, transport, and the same jump host (a host
/// re-routed through another jump host can land on a different machine at
/// the same address). A yes, a time-limited approval or an open terminal
/// given for one is not one for the other. The one rule the dispatcher, the
/// bridge service and the assistant's terminals share, so they cannot drift.
bool bridgeSameServer(Host a, Host b) =>
    a.id == b.id &&
    a.hostname == b.hostname &&
    a.port == b.port &&
    a.username == b.username &&
    a.transport == b.transport &&
    a.jumpHostId == b.jumpHostId;

/// Whether [command] is on [host]'s allowed list: exact string equality
/// between the command, trimmed, and one entry. Never a pattern, never a
/// prefix, never case-folded. False unless the host is set to ask to change
/// (the list is stored but inert otherwise). Only `run_command` on a single
/// host may use this; nothing else ever matches.
bool bridgeCommandIsAllowed(Host host, String command) {
  if (!host.aiMayRequestChanges) return false;
  final wanted = command.trim();
  if (wanted.isEmpty) return false;
  for (final entry in host.aiAllowedCommands) {
    if (entry == wanted) return true;
  }
  return false;
}

/// The one place that decides whether a bridge tool call may run. Pure: it
/// is handed every fact it needs and does no I/O, so the whole decision fits
/// in a table-driven test.
///
/// The order matters and is part of the contract: a switched-off bridge says
/// so before anything else, a locked app says so before revealing anything
/// about tools or hosts, and only then is the host looked at.
///
/// For [BridgeToolKind.read], the rule is exactly 1.6.0's. [host] is null
/// both when the tool takes no host and when the name did not resolve. When
/// [hostRequired] is false and a host is passed anyway, it is still held to
/// its access setting: a caller that hands one over has a reason to, and a
/// host the user closed must not be reachable sideways. [hasLiveGrant] and
/// [matchesAllowedCommand] play no part.
///
/// For [BridgeToolKind.change]: no host, or a host with access off, gets the
/// same `host_not_available` as a read (whatever [hostRequired] says: a
/// change always names a host); a read-only host gets `changes_not_allowed`;
/// a host set to ask to change is allowed when [matchesAllowedCommand] or
/// [hasLiveGrant], and otherwise needs approval.
///
/// For [BridgeToolKind.terminal]: as for a change up to the read-only step,
/// then the host's terminal switch must be on, and the answer is always
/// [BridgeNeedsApproval]: [hasLiveGrant] and [matchesAllowedCommand] never
/// open a terminal.
///
/// For [BridgeToolKind.terminalUse] (typing into, reading or closing a
/// terminal already opened with a yes): [ownsLiveTerminal] says whether the
/// terminal id the call names is one the CALLING client opened and that is
/// still the assistant's to use (open, not taken over by the user, not
/// stopped or closed); [host] is that terminal's host as it is now, or null
/// when it is gone or now points at another server. Bridge off and locked
/// come first, as always; then a terminal the caller does not own gets
/// `terminal_not_available`, the same for an unknown id and for another
/// client's (checked before the host, so nothing about another client's
/// terminal can show); then the host is held to the same steps as opening a
/// terminal, except that the answer is [BridgeAllow]: no card per call.
/// [hasLiveGrant], [matchesAllowedCommand] and [hostRequired] play no part.
/// For every other kind [ownsLiveTerminal] plays no part.
///
/// A refusal never depends on [hasLiveGrant] or [matchesAllowedCommand], so
/// a caller may ask once with both false to learn whether the call is
/// refused before it has validated the arguments.
BridgeDecision decideBridgeCall({
  required bool bridgeEnabled,
  required bool appLocked,
  required Host? host,
  required bool hostRequired,
  required BridgeToolKind kind,
  required bool hasLiveGrant,
  required bool matchesAllowedCommand,
  required bool ownsLiveTerminal,
}) {
  if (!bridgeEnabled) return BridgeRefusals.bridgeOff;
  if (appLocked) return BridgeRefusals.appLocked;
  switch (kind) {
    case BridgeToolKind.read:
      if (host == null) {
        return hostRequired
            ? BridgeRefusals.hostNotAvailable
            : const BridgeAllow();
      }
      if (host.aiAccess == HostAiAccess.off) {
        return BridgeRefusals.hostNotAvailable;
      }
      return const BridgeAllow();
    case BridgeToolKind.change:
    case BridgeToolKind.terminal:
      if (host == null || host.aiAccess == HostAiAccess.off) {
        return BridgeRefusals.hostNotAvailable;
      }
      if (!host.aiMayRequestChanges) return BridgeRefusals.changesNotAllowed;
      if (kind == BridgeToolKind.terminal) {
        if (!host.aiMayOpenTerminal) return BridgeRefusals.terminalNotAllowed;
        return const BridgeNeedsApproval();
      }
      if (matchesAllowedCommand || hasLiveGrant) return const BridgeAllow();
      return const BridgeNeedsApproval();
    case BridgeToolKind.terminalUse:
      if (!ownsLiveTerminal) return BridgeRefusals.terminalNotAvailable;
      if (host == null || host.aiAccess == HostAiAccess.off) {
        return BridgeRefusals.hostNotAvailable;
      }
      if (!host.aiMayRequestChanges) return BridgeRefusals.changesNotAllowed;
      if (!host.aiMayOpenTerminal) return BridgeRefusals.terminalNotAllowed;
      return const BridgeAllow();
  }
}
