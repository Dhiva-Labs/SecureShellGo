/// What an AI assistant connected through the AI Bridge may do on one saved
/// host. Per host and off unless chosen: the bridge never reaches a server
/// the user has not switched on here, whatever the global bridge switch says.
///
/// Persisted as [name], same reasoning as `SshAuthMethod` in `host.dart`.
enum HostAiAccess {
  off,

  /// Read-only tools only: nothing an assistant can call changes the server.
  readOnly,

  /// Read-only tools, plus changes an assistant may ask for. Nothing runs
  /// without a person's yes in the app, except what the user set up on this
  /// host beforehand.
  askToChange,

  /// Changes, terminals and desktops run without a card on this host. The
  /// user's explicit choice, made with a confirmation that says exactly
  /// that. Order of trust: off < readOnly < askToChange < fullControl.
  ///
  /// A build older than 1.8.0 reads this stored value as [off] (see
  /// [fromJson]), so a downgrade fails towards no access.
  fullControl;

  /// Anything unknown or absent is [off]. Failing towards "no access" matters
  /// more here than for any other enum: a `hosts.json` written by a later
  /// version, with a level this build has never heard of, must not hand an
  /// assistant more than the user chose.
  static HostAiAccess fromJson(Object? value) {
    if (value is String) {
      for (final access in HostAiAccess.values) {
        if (access.name == value) return access;
      }
    }
    return HostAiAccess.off;
  }
}
