import 'dart:async';

import '../models/host.dart';
import 'diagnostics_log.dart';

/// One question in a keyboard-interactive round (RFC 4256 §3.2).
class LoginPromptField {
  const LoginPromptField({required this.text, required this.echo});

  /// The server's question, control characters already stripped — for
  /// example `Verification code: `. Can run to several lines: Duo puts its
  /// whole menu of options into the prompt itself.
  final String text;

  /// Whether what the person types may be shown as they type it. False for
  /// passwords and for most one-time codes.
  final bool echo;

  /// The question proper: the last non-blank line of [text], without its
  /// trailing colon — `Passcode or option (1-3)` out of Duo's whole menu.
  String get label {
    final lines = _lines;
    if (lines.isEmpty) return '';
    final last = lines.last.trim();
    return last.endsWith(':')
        ? last.substring(0, last.length - 1).trimRight()
        : last;
  }

  /// Everything in [text] above [label], or empty when the prompt is a
  /// single line.
  String get preamble {
    final lines = _lines;
    if (lines.length < 2) return '';
    return lines.sublist(0, lines.length - 1).join('\n').trimRight();
  }

  List<String> get _lines {
    final lines = text.split('\n');
    while (lines.isNotEmpty && lines.last.trim().isEmpty) {
      lines.removeLast();
    }
    return lines;
  }
}

/// One keyboard-interactive round, as the server sent it but cleaned up for
/// display.
///
/// A plain-data mirror of dartssh2's `SSHUserInfoRequest`, which that package
/// does not export — so the logic that answers it can be tested by building
/// one of these by hand.
class LoginChallenge {
  const LoginChallenge({
    this.name = '',
    this.instruction = '',
    required this.fields,
  });

  /// Turns raw server text into a challenge. Every string goes through
  /// [cleanServerText], so nothing downstream sees an escape sequence.
  factory LoginChallenge.fromServer({
    required String name,
    required String instruction,
    required List<({String text, bool echo})> prompts,
  }) {
    return LoginChallenge(
      name: cleanServerText(name, maxLength: 200),
      instruction: cleanServerText(instruction, maxLength: 2000),
      fields: [
        for (final prompt in prompts)
          LoginPromptField(
            text: cleanServerText(prompt.text, maxLength: 2000),
            echo: prompt.echo,
          ),
      ],
    );
  }

  /// A short title for the round, e.g. `Password Expired`. Often empty.
  final String name;

  /// Free text to show above the questions. Often empty.
  final String instruction;

  /// The questions themselves. Can be empty, in which case the round is only
  /// carrying [instruction] and needs no answer.
  final List<LoginPromptField> fields;
}

/// Everything the UI needs to put one keyboard-interactive round in front of
/// a person.
class LoginPrompt {
  const LoginPrompt({
    required this.host,
    required this.challenge,
    required this.withdrawn,
    this.jumpHostFor,
    this.savedPasswordRejected = false,
  });

  /// The host doing the asking. On a jump-host connection this is the hop,
  /// not the machine the user set out to reach — see [jumpHostFor].
  final Host host;

  /// When [host] is a jump host, the host this connection is on its way to.
  /// Null for the target itself.
  final Host? jumpHostFor;

  final LoginChallenge challenge;

  /// True when the server has already turned down the saved password once
  /// in this connect, so the dialog can say why it is asking for one.
  final bool savedPasswordRejected;

  /// Completes if the login ends while this prompt is still up — the server
  /// gave up waiting, or the connection dropped. A dialog showing the prompt
  /// should close itself then; an answer would go nowhere.
  final Future<void> withdrawn;

  List<LoginPromptField> get fields => challenge.fields;
}

/// Puts a login prompt in front of a person. Returns one answer per field,
/// in order, or null when they cancelled.
typedef LoginPromptHandler = Future<List<String>?> Function(LoginPrompt prompt);

/// Text a server sent to be shown before login — the SSH banner, usually a
/// legal notice from `/etc/issue.net`.
class ServerBanner {
  const ServerBanner({
    required this.host,
    required this.text,
    this.jumpHostFor,
  });

  /// The host that sent it. A jump host's banner names the jump host.
  final Host host;

  /// When [host] is a jump host, the host the connection is on its way to.
  final Host? jumpHostFor;

  /// Already cleaned with [cleanServerText]; never empty.
  final String text;
}

/// Receives each banner as the server sends it.
typedef ServerBannerHandler = void Function(ServerBanner banner);

/// Answers one host's keyboard-interactive rounds for one login attempt.
///
/// Holds no timers and no sockets: `SshService` feeds it challenges and reads
/// back what happened, which is what lets the rules below be tested against
/// a scripted person rather than a server.
///
/// The rules, in order:
///
///  1. A round with no questions is answered at once with nothing. Servers
///     use these to pass along text, and blocking on them would only stall
///     the login.
///  2. The first round that is a single hidden question that reads like a
///     password prompt is answered with the saved password, once. That is
///     what makes a password host work on a server that only offers
///     keyboard-interactive — FreeBSD's default, and any sshd with
///     `PasswordAuthentication no` in front of PAM. A second password
///     question in the same login is never auto-answered: it is a retry,
///     or the "current password" of an expiry change, and either way a
///     person should see it.
///  3. Anything else goes to [ask]. With no [ask] there is nobody to answer,
///     so the round is declined and [unansweredPrompt] records what was
///     asked, for an error message that says so rather than a generic
///     "authentication failed".
class KeyboardInteractiveResponder {
  KeyboardInteractiveResponder({
    required this.host,
    this.jumpHostFor,
    String? savedPassword,
    this.ask,
    this.savedPasswordRejected = false,
    Future<void>? withdrawn,
  })  : _savedPassword = savedPasswordRejected ||
                savedPassword == null ||
                savedPassword.isEmpty
            ? null
            : savedPassword,
        _withdrawn = withdrawn ?? Completer<void>().future;

  final Host host;
  final Host? jumpHostFor;

  /// The person, or null when there is none — a reconnect, a background
  /// transfer.
  final LoginPromptHandler? ask;

  /// Set on a second attempt after the server turned the saved password
  /// down. The saved password is then never offered again.
  final bool savedPasswordRejected;

  final String? _savedPassword;
  final Future<void> _withdrawn;

  var _savedPasswordSent = false;

  /// True while the most recent thing sent to the server was the saved
  /// password, with no round since. If the login fails in that state, the
  /// saved password is what the server refused.
  bool get lastAnswerWasSavedPassword => _lastAnswerWasSavedPassword;
  var _lastAnswerWasSavedPassword = false;

  /// True once a person has answered at least one round.
  bool get personAnswered => _personAnswered;
  var _personAnswered = false;

  /// True when the person cancelled a prompt.
  bool get cancelled => _cancelled;
  var _cancelled = false;

  /// The question that needed a person when there was none, or null.
  LoginPromptField? get unansweredPrompt => _unansweredPrompt;
  LoginPromptField? _unansweredPrompt;

  /// Text the server passed along in rounds that asked nothing. Kept for the
  /// error message if the login then fails — "Login request denied" from
  /// Duo arrives exactly this way.
  List<String> get notices => List.unmodifiable(_notices);
  final _notices = <String>[];

  /// Answers one round. Null means "decline": dartssh2 then moves on to its
  /// next method, which for keyboard-interactive is the last one, so the
  /// login fails and the flags above say why.
  Future<List<String>?> respond(LoginChallenge challenge) async {
    _lastAnswerWasSavedPassword = false;

    if (challenge.fields.isEmpty) {
      final text = [challenge.name, challenge.instruction]
          .where((part) => part.isNotEmpty)
          .join('\n');
      if (text.isNotEmpty) _notices.add(text);
      return const [];
    }

    final saved = _savedPassword;
    if (saved != null &&
        !_savedPasswordSent &&
        challenge.fields.length == 1 &&
        !challenge.fields.single.echo &&
        looksLikePasswordPrompt(challenge.fields.single.text)) {
      _savedPasswordSent = true;
      _lastAnswerWasSavedPassword = true;
      return [saved];
    }

    final ask = this.ask;
    if (ask == null) {
      _unansweredPrompt ??= challenge.fields.first;
      return null;
    }

    final answers = await ask(
      LoginPrompt(
        host: host,
        jumpHostFor: jumpHostFor,
        challenge: challenge,
        savedPasswordRejected: savedPasswordRejected,
        withdrawn: _withdrawn,
      ),
    );
    if (answers == null) {
      _cancelled = true;
      return null;
    }
    if (answers.length != challenge.fields.length) {
      // dartssh2 would throw on the mismatch anyway; failing here names the
      // actual mistake.
      throw ArgumentError(
        'Expected ${challenge.fields.length} answers, got ${answers.length}.',
      );
    }
    _personAnswered = true;
    // Hidden answers are passwords and one-time codes, typed here and saved
    // nowhere: the diagnostics log learns them, so an error that echoes one
    // cannot keep it.
    for (var i = 0; i < answers.length; i++) {
      if (!challenge.fields[i].echo) {
        DiagnosticsLog.instance.learnSecret(answers[i]);
      }
    }
    return answers;
  }

  /// Whether [prompt] reads like a request for the account password, and not
  /// for a one-time code, a new password, or a confirmation.
  ///
  /// Deliberately narrow. A false negative costs one dialog; a false
  /// positive sends the saved password somewhere it was not asked for — Duo's
  /// `Passcode or option (1-3):` must not match, and neither may pam_oath's
  /// `One-time password (OATH) for 'dev':`. The handful of translations are
  /// the ones PAM ships, since sshd can inherit the system locale.
  static bool looksLikePasswordPrompt(String prompt) {
    // `dev@codeserver's password:` is a password prompt; the account and
    // host it names are not the words being looked for.
    final lower = prompt.toLowerCase().replaceAll(_accountAtHost, ' ');
    if (!_passwordWords.hasMatch(lower)) return false;
    return !_notTheCurrentPassword.hasMatch(lower);
  }

  static final _accountAtHost = RegExp(r'\S*@\S*');

  static final _passwordWords = RegExp(
    r'password|passwort|mot de passe|contraseña|senha|пароль|密码|パスワード',
  );

  static final _notTheCurrentPassword = RegExp(
    r'\bnew\b|\bretype\b|\bre-enter\b|\bagain\b|\bconfirm|\bverify\b'
    r'|one[- ]time|\botp\b|\btoken\b|\bcode\b',
  );
}

/// Makes text from a server safe to put on screen: plain text, nothing that
/// can move a cursor, change a colour, or reorder what is displayed.
///
/// Removes ANSI escape sequences whole (not just their ESC byte, which would
/// leave `[31m` litter behind), every other C0 and C1 control except newline
/// and tab, and the Unicode bidirectional overrides a hostile server could
/// use to make a prompt read differently from what it says. Line endings are
/// normalised, trailing blank lines dropped, and anything past [maxLength]
/// cut off — a banner is free text from a machine the user has not yet
/// logged in to.
String cleanServerText(String raw, {int maxLength = 8000}) {
  var text = raw
      .replaceAll(_ansiSequence, '')
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAll(_unprintable, '');
  // Trailing whitespace on each line, then blank lines at either end.
  text = text.split('\n').map((line) => line.trimRight()).join('\n');
  text = text.replaceAll(RegExp(r'^\n+|\n+$'), '');
  if (text.length > maxLength) {
    // Never cut between the two halves of a surrogate pair.
    var end = maxLength;
    final last = text.codeUnitAt(end - 1);
    if (last >= 0xD800 && last <= 0xDBFF) end--;
    text = '${text.substring(0, end).trimRight()}…';
  }
  return text;
}

/// CSI (`ESC [ … final`), OSC (`ESC ] … BEL` or `ESC ] … ESC \`), and the
/// two-byte escapes. The 8-bit CSI (U+009B) is covered by [_unprintable].
final _ansiSequence = RegExp(
  r'\x1B\[[0-?]*[ -/]*[@-~]'
  r'|\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)?'
  r'|\x1B[@-_]',
);

final _unprintable = RegExp(
  r'[\u0000-\u0008\u000B-\u001F\u007F-\u009F'
  r'\u200E\u200F\u202A-\u202E\u2066-\u2069]',
);
