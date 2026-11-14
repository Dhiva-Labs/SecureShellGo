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

  static const BridgeRefuse changesNotAvailable = BridgeRefuse(
    'changes_not_available',
    'This version of SecureShell Go only offers read-only tools; '
        'nothing can be changed on a server through the AI Bridge.',
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

/// The one place that decides whether a bridge tool call may run. Pure: it
/// is handed every fact it needs and does no I/O, so the whole decision fits
/// in a table-driven test.
///
/// The order matters and is part of the contract: a switched-off bridge says
/// so before anything else, a locked app says so before revealing anything
/// about tools or hosts, the "no changes" rule comes before the host check so
/// a change tool never learns whether a host exists, and only then is the
/// host looked at.
///
/// [host] is null both when the tool takes no host and when the name did not
/// resolve. When [hostRequired] is false and a host is passed anyway, it is
/// still held to its access setting: a caller that hands one over has a
/// reason to, and a host the user closed must not be reachable sideways.
BridgeDecision decideBridgeCall({
  required bool bridgeEnabled,
  required bool appLocked,
  required Host? host,
  required bool hostRequired,
  required BridgeToolKind kind,
}) {
  if (!bridgeEnabled) return BridgeRefusals.bridgeOff;
  if (appLocked) return BridgeRefusals.appLocked;
  if (kind != BridgeToolKind.read) return BridgeRefusals.changesNotAvailable;
  if (host == null) {
    return hostRequired ? BridgeRefusals.hostNotAvailable : const BridgeAllow();
  }
  if (host.aiAccess == HostAiAccess.off) return BridgeRefusals.hostNotAvailable;
  return const BridgeAllow();
}
