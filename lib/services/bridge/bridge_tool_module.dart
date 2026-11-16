import 'dart:typed_data';

import '../../models/host.dart';
import 'bridge_client_store.dart';
import 'bridge_policy.dart';
import 'bridge_tool_types.dart';
import 'bridge_tools.dart';

/// A group of bridge tools that lives in its own file (jobs, the desktop)
/// and is registered with the tool host in one line:
///
/// ```dart
/// BridgeTools(..., modules: [jobTools, desktopTools])
/// ```
///
/// A module brings two kinds of tool:
///
/// - [changeTools]: anything of kind [BridgeToolKind.change],
///   [BridgeToolKind.terminal] or [BridgeToolKind.desktop] (`start_job`,
///   `open_desktop`). These are ordinary [BridgeChangeTool]s and run through
///   exactly the path `run_command` and `open_terminal` take: policy, plan,
///   card (or a grant, an allowed command, full control), the re-check after
///   a yes, run, redact, audit. A module cannot ask for a card any other
///   way, so it cannot skip one.
/// - [specs] served by [call]: kinds [BridgeToolKind.read],
///   [BridgeToolKind.terminalUse], [BridgeToolKind.desktopUse] and
///   [BridgeToolKind.jobUse] only (`list_jobs`, `stop_job`,
///   `desktop_click`). The tool host refuses to register any other kind
///   here.
///
/// **How [call] must do policy.** Resolve what the call names (a host with
/// [BridgeModuleCall.resolveHost], or the caller's own job or desktop by id,
/// looked up among THAT client's only), then call [BridgeModuleCall.decide]
/// before looking at any other argument, and return
/// [BridgeModuleOutcome.refused] with its refusal when it is not a
/// [BridgeAllow]. The kind is always the spec's own, and bridge off / app
/// locked are filled in by the tool host, so a module cannot decide with
/// the wrong switch. As a backstop the tool host turns any non-refused
/// outcome into an error when the last [BridgeModuleCall.decide] of that
/// call was not a [BridgeAllow], and [BridgeModuleCall.withServer] only runs
/// for a host the last decision allowed.
///
/// **Audit.** A module never writes the activity log. The tool host writes
/// exactly one entry per call, from what [call] returns, with the host from
/// the `host` argument or [BridgeModuleCall.auditHost], the arguments from
/// [auditArgs], and the redacted text. Output text is redacted like every
/// other tool's; an image is passed through as it is.
///
/// **Lifecycle.** The bridge service tells every module when a host
/// changes, when paired clients are removed, and when the bridge goes off,
/// the app locks or the app closes (see [hostsChanged], [clientsChanged],
/// [ended]). A module ends what a host no longer allows (gone, stepped below
/// what the thing needs, or now pointing at another server, see
/// `bridgeSameServer`).
abstract class BridgeToolModule {
  const BridgeToolModule();

  /// Read, terminal-use, desktop-use and job-use tools, served by [call];
  /// see the class comment.
  List<BridgeToolSpec> get specs => const [];

  /// Change, terminal and desktop tools, run by the tool host's own change
  /// path.
  List<BridgeChangeTool> get changeTools => const [];

  /// Whether [name] is one of [specs]. The tool host routes by name from
  /// [specs] at construction; this is for a module's own checks and tests.
  bool handles(String name) => specs.any((s) => s.name == name);

  /// Runs one call of a tool in [specs]. Never throws on purpose: a thrown
  /// [BridgeToolArgs] refusal becomes a refusal, a timeout an error, any
  /// other exception "failed unexpectedly" (never its text).
  Future<BridgeModuleOutcome> call(BridgeModuleCall call) async =>
      BridgeModuleOutcome.refused(BridgeToolRefusals.unknownTool);

  /// The arguments of a [specs] tool as the audit log should record them
  /// (never content, never a secret). The raw arguments by default.
  Map<String, Object?> auditArgs(String tool, Map<String, Object?> args) =>
      args;

  /// Called once by the tool host when it is built, with the way a module
  /// may reach a server for something the USER asked for (see
  /// [BridgeModuleServices]). Nothing an assistant asks for may use it.
  void attach(BridgeModuleServices services) {}

  /// Every saved host after a change (`HostStore.changes`).
  Future<void> hostsChanged(List<Host> hosts) async {}

  /// The paired clients now, by id, with [BridgeClient.builtinId] always in
  /// the set: anything a client outside it started that must not outlive
  /// its pairing ends.
  Future<void> clientsChanged(Set<String> clientIds) async {}

  /// The bridge went off for channel clients ([BridgeModuleEnd.bridgeOff]:
  /// end what channel clients hold, keep the built-in assistant's), the app
  /// locked, or the tool host is being disposed.
  Future<void> ended(BridgeModuleEnd reason) async {}
}

/// What the tool host gives a module for actions the user takes themselves
/// (the Stop of a job from the app or the phone). These do NOT go through
/// the assistant policy: the person is acting, not the assistant, as with
/// the Stop button on an assistant terminal. The module must never reach
/// this from an assistant's call; that goes through [BridgeModuleCall].
abstract interface class BridgeModuleServices {
  /// Whether the app is locked now. A user-side action must not run then.
  bool get isAppLocked;

  /// Every saved host, read now.
  Future<List<Host>> hosts();

  /// Runs [body] with a server context for [host], the same connection
  /// cache and deadline a tool call gets, but with no policy decision.
  Future<T> withServerAsUser<T>(
    Host host,
    Future<T> Function(BridgeCallContext call) body, {
    Duration? timeout,
  });
}

/// Why [BridgeToolModule.ended] was called.
enum BridgeModuleEnd {
  /// The channel bridge was switched off: what clients on the local channel
  /// hold ends; the built-in assistant's ([BridgeClient.builtin]) does not.
  bridgeOff,

  /// The built-in assistant ([BridgeClient.builtin]) was switched off: what
  /// it holds ends; what clients on the local channel hold does not.
  builtinOff,

  /// The app locked: everything interactive ends (a job on a server is not
  /// interactive and may keep running; that is the jobs module's call).
  appLocked,

  /// The app is closing.
  disposed,
}

/// What one module call is handed by the tool host. Its only route to the
/// policy, the hosts and a server.
abstract interface class BridgeModuleCall {
  /// Who is calling: a paired assistant or [BridgeClient.builtin]. Never a
  /// controller (the tool host refuses those before any module runs).
  BridgeClient get client;

  /// The tool being called, one of the module's [BridgeToolModule.specs].
  BridgeToolSpec get spec;

  /// The arguments as sent. Validate with [args] before use.
  Map<String, Object?> get rawArgs;

  /// [rawArgs] checked against [allowed]: an unknown argument refuses the
  /// call as `invalid_arguments`, as do the typed getters on bad input.
  BridgeToolArgs args(Set<String> allowed);

  /// Every saved host, read now.
  Future<List<Host>> hosts();

  /// The host [name] names as the assistant sees it (its bridge name), or
  /// null for no such host or an unusable name. Says nothing about access:
  /// [decide] does.
  Future<Host?> resolveHost(Object? name);

  /// [decideBridgeCall] for this call, with the spec's kind, this client's
  /// on/off switch and the lock state filled in. Records the audit approval
  /// for a full-control allow. Call it before looking at other arguments,
  /// and again after anything that can wait (the host may have changed).
  BridgeDecision decide({
    required Host? host,
    bool hostRequired = true,
    bool ownsLiveTerminal = false,
    bool ownsLiveDesktop = false,
    bool ownsJob = false,
  });

  /// Runs [body] with a server context for [host] (exec under the call's
  /// deadline, SFTP, the path guard), halted when the call is cancelled or
  /// its client revoked. Throws [StateError] unless the last [decide] was a
  /// [BridgeAllow] for that same server.
  Future<T> withServer<T>(
    Host host,
    Future<T> Function(BridgeCallContext call) body, {
    Duration? timeout,
  });

  /// The host name the audit entry shows when the call has no `host`
  /// argument (a job id's host). Set it only once the thing the id names is
  /// known to be the caller's.
  set auditHost(String? name);

  /// True once the call is cancelled, its client revoked or the bridge
  /// switched off.
  bool get isAbandoned;

  /// Completes with the reason when the call is abandoned.
  Future<String> get abandoned;
}

/// How a module call ended, before redaction and audit.
class BridgeModuleOutcome {
  const BridgeModuleOutcome.ok(this.text)
    : refusal = null,
      isError = false,
      image = null,
      imageMimeType = null;

  const BridgeModuleOutcome.error(this.text)
    : refusal = null,
      isError = true,
      image = null,
      imageMimeType = null;

  BridgeModuleOutcome.refused(BridgeRefuse this.refusal)
    : text = refusal.message,
      isError = true,
      image = null,
      imageMimeType = null;

  /// An image (a screenshot) with [text] beside it.
  const BridgeModuleOutcome.image(
    Uint8List this.image, {
    required String this.imageMimeType,
    this.text = '',
  }) : refusal = null,
       isError = false;

  /// [result] as an outcome: ok, error or image, as it says.
  factory BridgeModuleOutcome.fromResult(BridgeToolResult result) {
    final image = result.image;
    if (image != null && !result.isError) {
      return BridgeModuleOutcome.image(
        image,
        imageMimeType: result.imageMimeType!,
        text: result.text,
      );
    }
    return result.isError
        ? BridgeModuleOutcome.error(result.text)
        : BridgeModuleOutcome.ok(result.text);
  }

  final String text;
  final bool isError;

  /// Set for a refusal; its code goes to the audit log.
  final BridgeRefuse? refusal;
  final Uint8List? image;
  final String? imageMimeType;
}
