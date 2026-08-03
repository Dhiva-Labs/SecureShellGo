import 'quick_connect_parser.dart';

/// What a host edit form should put in its Host, Port and Username fields
/// for one piece of typed or pasted text.
class HostFieldEntry {
  const HostFieldEntry({required this.hostname, this.port, this.username});

  final String hostname;

  /// The port found on the end of the input, or null when there was none to
  /// find — in which case the form leaves its Port field alone.
  final int? port;

  /// The `user@` part, when the input carried one. Null otherwise.
  final String? username;

  bool get hasParts => port != null || username != null;
}

/// Splits a pasted `user@host:port` into the fields it belongs in.
///
/// The bug this exists for: pasting `127.0.0.1:22303` left Port sitting at
/// 22 and `127.0.0.1:22303` in Host, and the connect then failed with
/// "Could not find a host called…" — advice about spelling for an address
/// that was spelled correctly. A host field is the natural place to paste an
/// address, so it accepts one.
///
/// Deliberately a thin adapter over [parseQuickConnect] rather than a second
/// parser. The quick-connect bar has advertised `user@host:port` since it
/// existed and already gets the hard parts right — bracketed IPv6, a refusal
/// to guess which colon in a bare IPv6 literal is a separator, port range
/// checks. Two parsers that disagreed about `[::1]:2222` would be a worse
/// bug than the one being fixed here.
///
/// The adaptation is only in what a *field* does with the answer, which is
/// not what a connect bar does with it:
///
///  * Anything the parser refuses is handed back untouched. Quick connect has
///    to say "IPv6 addresses need brackets" because it is about to dial;
///    a form field is not, so `fe80::1` simply stays in Host, unmangled, and
///    a typo like `example.com:ssh` stays visible where the user can fix it
///    instead of being silently rewritten.
///  * A port is only reported when the input actually carried one. The
///    parser's default of 22 must not overwrite a port the user typed into
///    the Port field themselves — hence
///    [QuickConnectTarget.hasExplicitPort].
HostFieldEntry parseHostField(String input) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) return const HostFieldEntry(hostname: '');

  final result = parseQuickConnect(trimmed, defaultUsername: '');
  final target = result.target;
  if (!result.isOk || target == null) return HostFieldEntry(hostname: trimmed);

  return HostFieldEntry(
    hostname: target.hostname,
    port: target.hasExplicitPort ? target.port : null,
    username: target.username.isEmpty ? null : target.username,
  );
}

/// The specific thing wrong with a stored [hostname] that a name lookup just
/// failed on, or null when there is nothing specific to say.
///
/// This is for the records that already exist. A host saved before the field
/// learned to split — the owner has one — fails with "Failed host lookup",
/// and the generic advice ("check the spelling, or use its IP address") is
/// actively misleading when the spelling is fine and it *is* an IP: the
/// address simply has a port stuck on the end of it. Naming that, and saying
/// which field it belongs in, is the difference between a dead end and a
/// thirty-second fix.
String? misplacedHostFieldAdvice(String hostname) {
  final entry = parseHostField(hostname);
  if (!entry.hasParts) return null;
  final port = entry.port;
  if (port != null) {
    return 'This host\'s address has a port on the end of it (:$port). Edit '
        'the host and put "${entry.hostname}" in Host and $port in Port.';
  }
  return 'This host\'s address has a username on the front of it '
      '("${entry.username}@"). Edit the host and put "${entry.hostname}" in '
      'Host and "${entry.username}" in Username.';
}
