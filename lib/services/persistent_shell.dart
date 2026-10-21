/// The commands that put a session's shell inside tmux or GNU screen, so a
/// reconnect lands back in the same shell — see [PersistentSession].
///
/// Pure string building, kept apart from the session so every command the
/// app will run on a server can be read, and tested, in one place.
///
/// **Why everything goes through `sh -c`.** The server runs an exec request
/// with the user's own login shell, and that is not always a POSIX one: a
/// fish or tcsh user would get a syntax error from `if …; then …; fi`. A plain
/// `exec sh -c '…'` means the same thing to all of them, so the real script
/// is handed to `sh` in one quoted argument. The script stays on one line,
/// with no `!` and no backslash inside the quotes, which are the three things
/// the non-POSIX shells read differently.
///
/// Every name that goes into a command — and the script itself, for the
/// outer layer — is quoted with [posixSingleQuote].
library;

import '../models/host.dart';
import 'shell_quote.dart';

/// The tmux or screen session name for a session tab: `ssg-<host>-<slot>_`.
///
/// [slot] is the lowest number not taken by another open tab on the same
/// host, so two tabs never share a shell, a reconnect finds the same one, and
/// the first tab opened after the app was closed goes back to the shell the
/// last first tab left running. Only letters, digits and dashes survive from
/// the host's name — tmux turns `.` and `:` into something else, and a name
/// that needs quoting is a name nobody can type at `tmux attach -t`.
///
/// The `_` at the end is what keeps tab 1 out of tab 10's shell. GNU screen
/// looks a name up as the *start* of a session name, with no way to ask for
/// an exact match: `ssg-box-1` finds `ssg-box-10` when only that is running,
/// and `screen -dRR` would take it over. No generated name has a `_`
/// anywhere but at its end, so none is the start of another, and every
/// lookup — screen's attach and the probe's alike — finds only its own.
String persistentSessionName(Host host, int slot) {
  final slug = host.displayName
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  final short = slug.length > 24 ? slug.substring(0, 24) : slug;
  final trimmed = short.replaceAll(RegExp(r'-+$'), '');
  return 'ssg-${trimmed.isEmpty ? 'host' : trimmed}-${slot}_';
}

/// What the one-line notices printed by [persistentShellCommand] say, so a
/// test can look for them.
const persistentScreenFallbackNotice =
    'SecureShell Go: tmux is not installed on this server, so this session '
    'runs in GNU screen instead.';
const persistentPlainFallbackNotice =
    'SecureShell Go: neither tmux nor screen is installed on this server, so '
    'this shell will not survive a disconnect.';
const persistentScreenMissingNotice =
    'SecureShell Go: GNU screen is not installed on this server, so this '
    'shell will not survive a disconnect.';
const persistentTmuxFailedNotice =
    'SecureShell Go: tmux exited with an error, so this shell will not '
    'survive a disconnect.';
const persistentScreenFailedNotice =
    'SecureShell Go: GNU screen exited with an error, so this shell will not '
    'survive a disconnect.';

/// The command that runs in place of the login shell for [kind], attaching
/// to [name] when it is already running and starting it when not — or null
/// for [PersistentSession.off], which keeps the ordinary shell.
///
/// tmux: `tmux new -A -s name`; when tmux is missing, GNU screen; when that
/// is missing too, the login shell, after one line saying why.
/// screen: `screen -dRR name` (reattach here, detaching it anywhere else,
/// or start it); when screen is missing, the login shell and the line.
///
/// tmux and screen are run, not `exec`ed, so that one which is there but
/// fails — a tmux whose server speaks another protocol version, a screen
/// that cannot open the terminal — still leaves a shell: the login shell,
/// after a line saying so. Otherwise the session would show "Shell ended",
/// and Restart would run the same failing command again. One that ends
/// well — a detach, the last window closed — ends the channel as before.
String? persistentShellCommand(PersistentSession kind, String name) {
  final quoted = posixSingleQuote(name);
  const has = 'command -v';
  const quiet = '>/dev/null 2>&1';
  final tmux = 'tmux new -A -s $quoted && exit';
  final screen = 'screen -dRR $quoted && exit';
  const plain = r'exec "${SHELL:-/bin/sh}" -l';
  String say(String notice) => 'echo ${posixSingleQuote(notice)}';

  final String script;
  switch (kind) {
    case PersistentSession.off:
      return null;
    case PersistentSession.tmux:
      script = 'if $has tmux $quiet; then $tmux; '
          '${say(persistentTmuxFailedNotice)}; $plain; fi; '
          'if $has screen $quiet; then '
          '${say(persistentScreenFallbackNotice)}; $screen; '
          '${say(persistentScreenFailedNotice)}; $plain; fi; '
          '${say(persistentPlainFallbackNotice)}; $plain';
    case PersistentSession.screen:
      script = 'if $has screen $quiet; then $screen; '
          '${say(persistentScreenFailedNotice)}; $plain; fi; '
          '${say(persistentScreenMissingNotice)}; $plain';
  }
  return 'exec sh -c ${posixSingleQuote(script)}';
}

/// A quick look, before the shell is opened, at whether [name] is already
/// running on the server: prints `attach` when it is and `new` when it is
/// not (including when neither tool is installed, since the shell that
/// opens then is a new one).
///
/// It decides one thing — whether the host's startup command is typed into
/// the shell. Typed into a new shell it does what it always did; typed into
/// one that was left running it would land in whatever is on screen there,
/// an editor included.
String? persistentProbeCommand(PersistentSession kind, String name) {
  final quoted = posixSingleQuote(name);
  // tmux matches a bare target against the start of session names too; `=`
  // asks for this name and no other. (`new -A -s`, which attaches, already
  // looks up names exactly.) screen has no such way to ask, and relies on
  // the names themselves: see [persistentSessionName].
  final exactly = posixSingleQuote('=$name');
  const quiet = '>/dev/null 2>&1';
  final String script;
  switch (kind) {
    case PersistentSession.off:
      return null;
    case PersistentSession.tmux:
      script = 'if command -v tmux $quiet; then '
          'if tmux has-session -t $exactly $quiet; then echo attach; '
          'else echo new; fi; '
          'elif command -v screen $quiet; then '
          'if screen -S $quoted -X select . $quiet; then echo attach; '
          'else echo new; fi; '
          'else echo new; fi';
    case PersistentSession.screen:
      script = 'if command -v screen $quiet && '
          'screen -S $quoted -X select . $quiet; then echo attach; '
          'else echo new; fi';
  }
  return 'sh -c ${posixSingleQuote(script)}';
}

/// Reads [persistentProbeCommand]'s answer: true when the shell about to
/// open is a new one, false when it is one left running, and null when the
/// probe said nothing usable — which is treated as "left running", because
/// not typing a startup command is the mistake that costs nothing.
bool? persistentProbeSaysNew(String stdout) {
  final answer = stdout.trim().split('\n').last.trim();
  if (answer == 'new') return true;
  if (answer == 'attach') return false;
  return null;
}
