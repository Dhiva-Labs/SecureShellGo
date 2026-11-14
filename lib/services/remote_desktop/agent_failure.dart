/// What went wrong getting a remote-desktop agent running, in terms the UI
/// can act on.
///
/// One exception type with a [kind] rather than a hierarchy, because the
/// screens above care about very few distinctions — "this build cannot do
/// it", "this server cannot do it", "install something", "try again" — and a
/// switch over an enum keeps every caller honest about which of those it
/// handles.
enum AgentFailureKind {
  /// This build of the app carries no agent binaries, or none for this
  /// server's OS and CPU.
  unavailableInBuild,

  /// The server runs something the agent does not support (macOS, a BSD, a
  /// 32-bit CPU), or the probe could not tell what it runs.
  unsupportedRemote,

  /// Desktop mode was asked for and this account has no desktop there.
  noDesktop,

  /// Somebody else is logged in to the desktop; this account cannot reach it.
  desktopOfAnotherUser,

  /// A program the server needs is missing. [AgentFailure.installCommand]
  /// says how to get it when the distribution is known.
  missingTool,

  /// The agent could not be copied to the server.
  uploadFailed,

  /// The file on the server is not the agent this build pinned. Never run.
  hashMismatch,

  /// The agent was started and stopped, or could not be started at all.
  launchFailed,

  /// Windows refused to run the agent: Smart App Control, WDAC or AppLocker
  /// blocked an unsigned executable. Not something to retry, and not to be
  /// worked around — signing the agent is the fix.
  blockedByPolicy,

  /// The agent was started but never published its `host.json`.
  launchTimedOut,

  /// `host.json` was there but was not something this app will trust.
  badHostInfo,

  /// The forward channel to the agent's port could not be opened.
  channelFailed,

  /// A virtual desktop that was asked for by id is not running any more.
  notFound,

  /// An exec channel could not be opened, or timed out.
  transport,
}

/// A remote-desktop step failed. [message] is safe to show verbatim;
/// [details] is the remote side's own words (a log tail, stderr) for behind a
/// "details" toggle.
///
/// Nothing here ever carries the agent's token: launch output that is quoted
/// into [details] has had `host.json` cut out of it first.
class AgentFailure implements Exception {
  const AgentFailure(
    this.kind,
    this.message, {
    this.details,
    this.installCommand,
  });

  final AgentFailureKind kind;
  final String message;
  final String? details;

  /// For [AgentFailureKind.missingTool]: the exact command that installs what
  /// is missing on this distribution, for the UI to offer to type into a
  /// terminal. Never run by this app — it needs the user's own `sudo`.
  final String? installCommand;

  @override
  String toString() => details == null ? message : '$message\n$details';
}
