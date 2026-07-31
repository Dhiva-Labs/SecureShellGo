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
  });

  final String username;
  final String hostname;
  final int port;
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
    }
    return QuickConnectParseResult.ok(
      QuickConnectTarget(username: username, hostname: hostname, port: port),
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
