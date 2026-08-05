/// Parses the quick-connect bar's free-text input into something that can
/// start a connection: `user@host`, `user@host:port`, `host`, `host:port`,
/// and IPv6 in brackets (`[::1]`, `user@[::1]:2222`).
///
/// Kept free of `dart:io` in the parsing itself, like the rest of
/// `services/` — [defaultQuickConnectUsername] is the one function here
/// that touches the platform, and it is a separate call so the parser stays
/// a pure function of its arguments and is unit-testable without a
/// platform channel.
library;

import 'dart:io';

/// One target parsed from the quick-connect bar.
class QuickConnectTarget {
  const QuickConnectTarget({
    required this.username,
    required this.hostname,
    required this.port,
    this.hasExplicitPort = false,
    this.identityFile,
  });

  final String username;
  final String hostname;
  final int port;

  /// The key file named by `-i` when the input was a whole `ssh` command,
  /// exactly as it was written. Null otherwise.
  ///
  /// Not resolved to a path here: it is usually relative to whatever
  /// directory the command was going to be run in, which this app has no way
  /// to know. The screen uses it to say *which* file to import rather than
  /// to open one behind the user's back.
  final String? identityFile;

  /// Whether [port] was in the input or is this parser's default of 22.
  ///
  /// Quick connect does not care — it dials [port] either way. The host edit
  /// form does: it fills its own Port field from a pasted `host:port`, and
  /// must not overwrite a port the user typed there with a 22 that came from
  /// nowhere. See `host_field_input.dart`.
  final bool hasExplicitPort;
}

enum QuickConnectStatus { ok, error }

/// The outcome of [parseQuickConnect] — mirrors the shape of
/// `PrivateKeyImportResult` (`private_key_import.dart`): a status plus
/// whichever of [target]/[message] applies to it.
class QuickConnectParseResult {
  const QuickConnectParseResult._(this.status, {this.target, this.message});

  final QuickConnectStatus status;
  final QuickConnectTarget? target;
  final String? message;

  bool get isOk => status == QuickConnectStatus.ok;

  factory QuickConnectParseResult.ok(QuickConnectTarget target) =>
      QuickConnectParseResult._(QuickConnectStatus.ok, target: target);

  factory QuickConnectParseResult.error(String message) =>
      QuickConnectParseResult._(QuickConnectStatus.error, message: message);
}

/// Parses [input]. [defaultUsername] fills in when there is no `user@`
/// part — the caller decides what that is (see
/// [defaultQuickConnectUsername]) so this function stays pure.
QuickConnectParseResult parseQuickConnect(
  String input, {
  required String defaultUsername,
}) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) {
    return QuickConnectParseResult.error('Enter a host to connect to.');
  }

  // A whole `ssh …` command is the most likely thing to arrive here after
  // `user@host`, because it is what a cloud console hands you to copy — AWS
  // gives you `ssh -i "key.pem" ubuntu@ec2-….amazonaws.com` verbatim.
  // Without this the flags are swallowed into the username and the server
  // rejects an account called `ssh -i "key.pem" ubuntu`.
  final command = _parseSshCommand(trimmed);
  if (command != null) {
    if (command.target == null) {
      return QuickConnectParseResult.error(
        'That ssh command does not name a host to connect to.',
      );
    }
    final inner = parseQuickConnect(
      command.normalizedTarget,
      defaultUsername: command.username ?? defaultUsername,
    );
    if (!inner.isOk) return inner;
    final t = inner.target!;
    return QuickConnectParseResult.ok(
      QuickConnectTarget(
        username: t.username,
        hostname: t.hostname,
        port: t.port,
        hasExplicitPort: t.hasExplicitPort,
        identityFile: command.identityFile,
      ),
    );
  }

  var remainder = trimmed;
  var username = defaultUsername;

  final atIndex = remainder.indexOf('@');
  if (atIndex != -1) {
    final userPart = remainder.substring(0, atIndex).trim();
    if (userPart.isEmpty) {
      return QuickConnectParseResult.error('Username before "@" is empty.');
    }
    username = userPart;
    remainder = remainder.substring(atIndex + 1);
  }

  if (remainder.isEmpty) {
    return QuickConnectParseResult.error('Enter a host to connect to.');
  }

  // Bracketed IPv6: `[::1]` or `[::1]:2222`. Checked before anything else —
  // an address in brackets can contain any number of colons of its own.
  if (remainder.startsWith('[')) {
    final closeIndex = remainder.indexOf(']');
    if (closeIndex == -1) {
      return QuickConnectParseResult.error(
        'Missing closing "]" for an IPv6 address.',
      );
    }
    final hostname = remainder.substring(1, closeIndex);
    if (hostname.isEmpty) {
      return QuickConnectParseResult.error('Empty address inside brackets.');
    }
    final rest = remainder.substring(closeIndex + 1);
    var port = 22;
    var explicit = false;
    if (rest.isNotEmpty) {
      if (!rest.startsWith(':')) {
        return QuickConnectParseResult.error('Unexpected text after "]".');
      }
      final parsedPort = _parsePort(rest.substring(1));
      if (parsedPort == null) {
        return QuickConnectParseResult.error(
          'Port must be a number from 1-65535.',
        );
      }
      port = parsedPort;
      explicit = true;
    }
    return QuickConnectParseResult.ok(
      QuickConnectTarget(
        username: username,
        hostname: hostname,
        port: port,
        hasExplicitPort: explicit,
      ),
    );
  }

  final colonCount = remainder.split(':').length - 1;

  // Bare IPv6 (more than one colon, no brackets) is ambiguous with
  // `host:port` — refuse rather than guess which colon is the port
  // separator.
  if (colonCount > 1) {
    return QuickConnectParseResult.error(
      'IPv6 addresses need brackets, e.g. [::1] or [::1]:2222.',
    );
  }

  if (colonCount == 1) {
    final parts = remainder.split(':');
    final hostname = parts[0];
    if (hostname.isEmpty) {
      return QuickConnectParseResult.error('Enter a host to connect to.');
    }
    final parsedPort = _parsePort(parts[1]);
    if (parsedPort == null) {
      return QuickConnectParseResult.error(
        'Port must be a number from 1-65535.',
      );
    }
    return QuickConnectParseResult.ok(
      QuickConnectTarget(
        username: username,
        hostname: hostname,
        port: parsedPort,
        hasExplicitPort: true,
      ),
    );
  }

  return QuickConnectParseResult.ok(
    QuickConnectTarget(username: username, hostname: remainder, port: 22),
  );
}

int? _parsePort(String text) {
  final port = int.tryParse(text.trim());
  if (port == null || port < 1 || port > 65535) return null;
  return port;
}

/// The username to prefill when the quick-connect bar's input has no
/// `user@` part. Reads the OS login name (`$USER` on Linux/macOS, `$USERNAME`
/// on Windows) and falls back to `root` — the common default for the
/// headless boxes this app connects to — when neither is set, which is the
/// ordinary case on Android/iOS.
String defaultQuickConnectUsername() {
  final env = Platform.environment;
  final name = env['USER'] ?? env['USERNAME'];
  if (name == null || name.trim().isEmpty) return 'root';
  return name.trim();
}

/// The parts of an `ssh …` command line this app can act on.
class _SshCommand {
  const _SshCommand({
    this.target,
    this.identityFile,
    this.port,
    this.username,
  });

  /// The `[user@]host` operand.
  final String? target;
  final String? identityFile;
  final int? port;

  /// From `-l`, which loses to a `user@` on the operand itself — that is
  /// what OpenSSH does too.
  final String? username;

  /// The command rewritten in the plain form the rest of this parser reads,
  /// so all of its validation and its IPv6 handling still apply.
  String get normalizedTarget {
    var host = target!;
    if (port == null) return host;
    // A bare IPv6 operand has to be bracketed before a port can be appended
    // to it, or the colons become ambiguous.
    final at = host.lastIndexOf('@');
    final userPart = at == -1 ? '' : host.substring(0, at + 1);
    var hostPart = at == -1 ? host : host.substring(at + 1);
    if (hostPart.contains(':') && !hostPart.startsWith('[')) {
      hostPart = '[$hostPart]';
    }
    return '$userPart$hostPart:$port';
  }
}

/// Recognises a pasted `ssh …` command, or returns null when [input] is not
/// one and should be read as a plain `user@host`.
///
/// Only the flags that change where or as whom we connect are honoured;
/// anything else OpenSSH accepts is skipped rather than refused, because a
/// command that fails to parse here would otherwise be reported as a bad
/// hostname. Flags that take a value are listed explicitly so their value is
/// not mistaken for the host operand.
_SshCommand? _parseSshCommand(String input) {
  final tokens = _tokenize(input);
  if (tokens.length < 2 || tokens.first.toLowerCase() != 'ssh') return null;

  const takesValue = {
    '-b', '-c', '-D', '-E', '-e', '-F', '-I', '-J', '-L', '-l', '-m',
    '-O', '-o', '-p', '-Q', '-R', '-S', '-W', '-w', '-i',
  };

  String? target;
  String? identityFile;
  int? port;
  String? username;

  for (var i = 1; i < tokens.length; i++) {
    final token = tokens[i];
    if (token.startsWith('-') && token.length > 1) {
      final value = i + 1 < tokens.length ? tokens[i + 1] : null;
      if (takesValue.contains(token)) {
        if (value == null) break;
        switch (token) {
          case '-i':
            identityFile = value;
          case '-p':
            port = _parsePort(value);
          case '-l':
            username = value;
        }
        i++;
      }
      // Anything else is a bare switch (-v, -A, -T, …) and needs no value.
      continue;
    }
    // The first non-flag operand is the destination; whatever follows it is
    // a remote command, which this app does not run from here.
    target = token;
    break;
  }

  if (target == null) return const _SshCommand();
  // `ssh://user@host:port` is also legal and carries its own port.
  if (target.startsWith('ssh://')) {
    target = target.substring('ssh://'.length);
  }
  return _SshCommand(
    target: target,
    identityFile: identityFile,
    port: port,
    username: username,
  );
}

/// Splits a command line on whitespace, keeping quoted runs together — a key
/// file with a space in its name arrives quoted, and AWS quotes it anyway.
List<String> _tokenize(String input) {
  final tokens = <String>[];
  final buffer = StringBuffer();
  String? quote;
  var pending = false;

  for (final rune in input.runes) {
    final char = String.fromCharCode(rune);
    if (quote != null) {
      if (char == quote) {
        quote = null;
      } else {
        buffer.write(char);
      }
      continue;
    }
    if (char == '"' || char == "'") {
      quote = char;
      pending = true;
      continue;
    }
    if (char.trim().isEmpty) {
      if (buffer.isNotEmpty || pending) {
        tokens.add(buffer.toString());
        buffer.clear();
        pending = false;
      }
      continue;
    }
    buffer.write(char);
  }
  if (buffer.isNotEmpty || pending) tokens.add(buffer.toString());
  return tokens;
}
