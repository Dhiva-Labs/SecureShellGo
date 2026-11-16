# 1.7.0 release checklist: the AI Bridge can change a server, what only real installs can prove

1.7.0 adds tools that change a server (`run_command`, `write_file`,
`service_action`, `run_on_hosts`) and a terminal (`open_terminal`,
`send_input`, `read_screen`, `close_terminal`), each only with the user's
approval on a card in the app, or under what the user set up beforehand. It was
built and unit-tested on Linux; nothing of it has run on Windows, against a
fish login shell or on a second desktop. Tick each box on a real install and
note what you saw where one fails. The 1.6 checklist (`release-checklist-1.6.md`)
still applies to packaging and pairing; this one covers what is new.
Everything new is off by default: every check starts with Settings, AI Bridge,
switch on, one host shared with "Share with AI assistants", then "Let the
assistant request changes" on that host (and, where it says so, "Allowed
commands" and "Full control terminal"). Use a test server you can break.

## 0. Versions, policy and docs

- [ ] Version strings bumped from 1.6.0 to 1.7.0 everywhere they are written
      by hand: `pubspec.yaml` `version:` (`1.6.0+16`, so `1.7.0+17`) and
      `msix_version:` (`1.6.0.0`, so `1.7.0.0`), `snap/snapcraft.yaml`
      (`'1.6.0'`), `debian/changelog` (a new `1.7.0~noble1` entry above
      `1.6.0~noble1`) and `appVersion` in `lib/app_version.dart`
      (`1.6.0+16`; what the About box and the bridge's `initialize` report).
      The plugin's `integrations/plugin/.claude-plugin/plugin.json`
      `version` is already 1.7.0. The README's "Status and limits" line still
      says "Version 1.5.1": set it to the real release. The release file
      names (rpm, Arch package, AppImage, Flatpak, AUR recipe, MSIX) take
      the version from `pubspec.yaml`.
- [ ] `flutter test` passes on Linux. The 1.7.0 tests are
      `test/bridge_policy_test.dart`, `test/bridge_approvals_test.dart`,
      `test/bridge_grants_test.dart`, `test/bridge_change_tools_test.dart`,
      `test/bridge_change_dispatch_test.dart`, `test/bridge_terminals_test.dart`,
      `test/bridge_approval_card_test.dart`, `test/visible_text_test.dart`,
      `test/assistant_session_test.dart` and `test/bridge_shared_hosts_test.dart`
      (with additions to the other `test/bridge_*` files). They prove the
      logic; the boxes below are what only a real install can show.
- [ ] `docs/changes/ai-bridge-changes.md` is folded into `CHANGELOG.md` under
      `## 1.7.0 - <date>` (its sections `### Added`, `### Security`,
      `### Changed`), the file deleted and its row removed from
      `docs/changes/README.md`.
- [ ] Privacy policy effective date set to the real release date, in both
      `docs/privacy-policy.md` and `docs/privacy-policy/index.html` (it still
      says 14 November 2026, the date it was written for 1.6.0; this branch
      did not change it), the two copies still say the same, and the date
      quoted in `store/play-data-safety.md` matches.
- [ ] `integrations/skill/SKILL.md` and
      `integrations/plugin/skills/secureshellgo/SKILL.md` are identical
      (`diff` them), and `integrations/clients/INSTRUCTIONS.md` carries the same
      rules. `claude plugin validate integrations/plugin --strict` and
      `claude plugin validate . --strict` pass.
- [ ] The translations of the approval card, the per-host warnings and the
      terminal banner (the eight languages other than English in
      `lib/l10n/app_*.arb`) were written by machine. Have a native speaker read them where possible before release,
      above all the card's headings and buttons, the Deny and Allow wording, and
      the terminal and allowed-commands warnings: a warning that reads softer in
      a language than in English is a bug.
- [ ] Microsoft Store listing text (`store/microsoft-store-listing.md`) and the
      snap description say only the generic sentence; the Play listing and the
      data-safety answers are unchanged (the bridge is not on Android).

## 1. The approval card, on each desktop platform (Linux deb or tarball, Windows zip and MSIX; snap, Flatpak and AppImage once each)

Pair an MCP-compatible assistant first (1.6 checklist, section 5).

- [ ] **Approve.** Ask the assistant to run a harmless command
      (`uname -a`). A card appears over whatever screen is open, naming the
      assistant and the server and showing the command; Allow once runs it,
      and the assistant gets the exit code and output. Activity shows one entry
      with "Approved once" and the command, and no output.
- [ ] **Deny.** The assistant gets "The user denied this change"; nothing ran;
      Activity says "Denied". Closing the card (Escape, the window's back
      gesture on a touch screen) denies too.
- [ ] **Time out.** Leave a card alone for 2 minutes: it closes by itself, the
      assistant gets "The user did not answer in time", Activity says "Timed
      out: not answered, so denied".
- [ ] **Hidden characters.** Ask for a command with a line break
      (`echo one` newline `echo two`), one with an escape or carriage return
      (`printf 'a\r'`), and one containing a right-to-left override
      (U+202E) and a no-break space (U+00A0). The card shows `\n`, `\r`,
      `[U+202E]` and `[U+00A0]` visibly with the legend, and the text on the
      card is what ran. Also a command with a combining mark on a plain letter
      (`echo e` followed by U+0301) and one with a private-use character
      (U+E000): the card shows `[U+0301]` and `[U+E000]`, and the legend has
      a line for each kind (the combining-mark line is new).
- [ ] **A long command, a long file.** A `run_command` of several hundred
      characters is shown in full on the card (the box scrolls). A
      `write_file` of a long file shows the "This is not the whole file"
      warning at the very top of the card, in view without scrolling, on a
      small window with large text.
- [ ] **The card does not alert you.** Minimise the app, or put another
      window over it, and have the assistant ask for a change: nothing
      flashes, sounds or comes forward (as the README says). After 2 minutes
      the assistant gets "The user did not answer in time".
- [ ] **Enter does not approve.** With a card open, press Enter and Space: it
      denies (Deny holds the focus). Open another card and press Allow once
      within the first second: the button does nothing yet.
- [ ] **Lock with a card open.** Lock the app: the card disappears, no dialog
      is left under the lock screen taking key presses, the assistant gets the
      "locked" refusal, and unlocking brings no card back.
- [ ] **A queue.** Have the assistant start several calls: cards come one at a
      time with "N more waiting"; a fourth from one assistant is refused as
      "Too many changes are already waiting"; Activity shows "approvals_busy".
- [ ] **Edit the host while a card is open.** Change the host's address, port,
      user name, connection type or jump host in the edit screen and save: the
      card goes away, the assistant gets a refusal (the change is not made),
      and Activity says "Withdrawn while waiting for an answer". A change of
      label, group or colour does not do this. ("Approved, but not run" is the
      case where the yes was given and the host changed in the instant before
      the run; it is covered by tests and is not practical to hit by hand.)
- [ ] **Revoke the assistant with a card open.** The card goes away, the call
      ends, nothing ran.
- [ ] **Bridge off with a card open.** Same.

## 2. Allow for a while, and Allowed commands

- [ ] **Allow for a while.** With Settings → AI Bridge → "Allow for a while"
      off, cards have no third button. Set it to 5 minutes: the button "Allow for 5
      minutes" appears. Press it for one command; a second, different change
      (a `write_file` or `service_action`) on the same host shows no card and
      runs; "Approvals in force" lists it with the time left. A change on
      another host still asks. Press **Stop now**: the next change asks again.
      Activity shows "Approved for a while", then "Allowed: timed approval in
      force".
- [ ] A timed approval ends when the time runs out (use 5 minutes), when the
      app is locked, when the bridge is switched off, when the assistant is
      revoked, when the host is stepped down to read-only, un-shared or
      deleted, when the host is edited to another address or another jump host,
      and when the setting is switched off. Editing only the label keeps it.
      A restart of the app leaves none.
- [ ] A terminal's card never offers "Allow for a while".
- [ ] **Allowed commands.** Add `uptime` to the host's list. The assistant
      asking for exactly `uptime` runs with no card (Activity: "Allowed: command
      on the allowed list"). `uptime ` with trailing spaces also runs
      (trimmed); `uptime -p`, `Uptime` and `uptime; id` each show a card. An
      allowed command asked for through `run_on_hosts` shows a card.
- [ ] The editor refuses an entry with a line break, a tab, a no-break space,
      an override character, a combining mark on a plain letter (`e` and
      U+0301), a private-use character (U+E000) or a format character such as
      U+2061, with the message saying why; a 51st entry and one over 4096
      characters are refused. A long accepted entry is shown in full, never
      cut, in the list and in the confirmation.
- [ ] Stepping the host down to read-only keeps the list stored but a request
      for `uptime` is refused ("This host is read-only"); switching changes
      back on shows the list again in the confirmation. With "Full control
      terminal" stored on, switching changes back on then asks for the
      terminal confirmation as well, and Cancel there leaves changes on and the
      terminal off. With a long list and large text, both confirmations
      scroll and their buttons stay reachable.

## 3. The tools

- [ ] **`service_action`.** Restart a test unit on a systemd server: card
      "Change a service?", then done. On a user account that lacks the
      privilege the tool fails with its error and no prompt appears anywhere.
- [ ] **`write_file`, new file.** Card "Create this file?" with the path, size
      and a preview; the file appears with the exact content. A path in a
      directory that does not exist is refused ("is not a directory; it is not
      created"). A blocked path (`~/.ssh/x`) is refused as "not available"
      with no card.
- [ ] **`write_file`, replace.** Without `if_exists` on an existing file:
      "already exists; nothing was written". With `"replace"`: card "Replace this
      file?" with a diff for a small text file, and with the plain "not the
      whole file" warning for a long one; the file's mode is kept; Activity has
      the path and byte count, not the content.
- [ ] **A file changed after the card.** Open a replace card, edit the file on the
      server (change its size), then Allow once: "changed on the server after the
      user was asked, so nothing was written", and the file is as you left it.
      Do the same for a new file created in the gap.
- [ ] Stop a write: switch the bridge off between Allow and the end of a large
      write; the file is either whole new or untouched, never half.
- [ ] **`run_on_hosts`** on 3 hosts that all allow changes: one card listing
      them all, then a JSON answer with each host's exit code and output in the
      order asked. With one host read-only the whole call is refused
      ("This host is read-only") and no card. With a live timed approval on
      all of them, no card.
- [ ] **A stop.** Start `sleep 300` through `run_command` and revoke the
      assistant (and again with the bridge switched off, and with the client
      cancelling the request): no `sleep` is left on the server
      (`pgrep -a sleep`) within about 3 seconds. A command that runs
      `setsid sleep 300` is NOT stopped; that is the stated limit.
- [ ] A command that runs past `timeout_seconds` is stopped and the assistant
      is told the call took longer than that.
- [ ] **No agent on a bridge connection.** On a host with agent forwarding on
      and a real agent loaded, open a session in the app, then have the assistant
      run `ssh-add -l` and `echo "$SSH_AUTH_SOCK"`: no agent socket is present.
      The same with X11 forwarding on (`echo "$DISPLAY"` is empty).

## 4. The terminal

- [ ] **A card every time**, even with "Allow for a while" on and the host
      having an allowed command: `open_terminal` always asks, and the card
      shows the full-control warning. A host with "Full control terminal" off
      is refused ("has not allowed the AI assistant to open a terminal").
- [ ] **Watch.** The terminal opens as a session tab (not brought to the
      front), with the banner "... is using this terminal. You can watch it."
      `send_input` text shows in the tab as it is typed; `read_screen` returns
      the screen, wrapped lines joined.
- [ ] **Take over** with the button, and again by typing in the tab: the
      banner changes, and `send_input` / `read_screen` are refused with "The
      user took over this terminal". Opening another is not offered by the
      assistant unless you ask it to.
- [ ] **Stop**: the session closes; the assistant gets "The user stopped this
      terminal".
- [ ] **Bridge off** closes it at once; so do locking the app, revoking the
      assistant, editing the host's address, un-sharing or stepping the host
      down and switching its terminal off; a taken-over terminal stays open.
- [ ] A terminal left alone is closed after 10 minutes; a third open is refused
      (limit 2).
- [ ] **No agent in the assistant's terminal.** On a host with agent forwarding
      on, `echo "$SSH_AUTH_SOCK"` and `ssh-add -l` in the assistant's terminal
      show no agent, while the user's own session on the same host still has it.
      The terminal does not run the host's startup command, is not inside
      tmux or screen even if the host is set to persistent sessions, and works
      on a Mosh host (as an SSH terminal).
- [ ] Another paired assistant given the first one's `terminal_id` gets "No
      terminal by that id is open for you", the same as for a made-up id.

## 5. The real sshd and fish

- [ ] The real-server test passes on a machine with `sshd`:
      `SSGO_SSHD=1 flutter test test/bridge_local_sshd_test.dart`.
- [ ] **A host whose login shell is fish.** Run the fish quoting checks on a
      machine that has fish installed: a `run_command` with a backslash, a
      command ending in a backslash and one with single quotes each runs exactly
      as the card showed. (The quoting itself is covered in
      `test/bridge_change_tools_test.dart`, group "review: the command line
      under every login shell": a Dart model of fish's single-quote rules, and
      real runs under `/bin/sh` and bash only; fish has never been run.)
- [ ] A host whose login shell is bash, zsh and dash behaves the same.

## 6. Windows

Nothing of 1.7.0 has run on Windows yet.

- [ ] The loopback channel carries the new tools: pair on Windows, then a
      `run_command` card, a `write_file`, a `service_action` and an
      `open_terminal` complete (zip and MSIX). The handshake is unchanged.
- [ ] The card, the one-second lockout, Escape, the lock and the approval
      queue behave as on Linux (section 1), including with Windows Hello's
      lock.
- [ ] A terminal's session tab, banner, Take over and Stop work.
- [ ] The servers supported for changes are POSIX ones (Linux, BSD, macOS) that
      have `/bin/sh`: the wrapper that stops a command is `sh`. A Windows
      server is not supported, and stopping a process on one is out of scope;
      check that a change aimed at one fails with an error and does nothing
      harmful rather than that it works.
- [ ] Windows Defender Firewall still asks nothing (loopback only).

## 7. Backups, revoke and the activity log

- [ ] Export a backup from a host with changes allowed, an allowed command and
      the terminal on; import it elsewhere: the host arrives with AI access off,
      no allowed commands and no terminal; this device's "Allow for a while"
      is untouched.
- [ ] Activity shows the approval column for every change, and `send_input` entries with the typed text
      (secrets removed) and no screen content. No password, key, output or file
      content is in it. A 1.6.0 `audit.log` still reads.

## 8. Not in 1.7.0

- [ ] The Android build is unchanged: no manifest or Gradle diff since 1.6.0;
      Play listing and data-safety answers unchanged (the bridge is not on
      Android).
- [ ] macOS: no bridge, no launcher, no new settings screen.
