# Changelog

Releases before 1.4.5 are described on the
[Releases](https://github.com/Dhiva-Labs/SecureShellGo/releases) page.

## 1.7.0 - 2026-11-16

The AI Bridge can now change a server, with your permission: every change needs your yes on a card in the app, except what you set up beforehand.

### Added
- Four tools that change a server, for an AI assistant you paired: `run_command` (one shell command, run by the account's own shell, up to 4096 characters, 60 seconds unless it asks for up to 300), `write_file` (one text file, up to 256 KiB, new or replacing), `service_action` (start, stop, restart or reload one systemd unit) and `run_on_hosts` (one command on 2 to 10 servers, at most 3 at a time, 60 seconds each).
- A terminal an assistant can ask for: `open_terminal`, `send_input`, `read_screen` and `close_terminal`. It opens as a session tab you can watch, with a banner offering **Take over** and **Stop**. At most 2 are open at once, and one with no input or reads for 10 minutes is closed.
- New per-server switches. **Share with AI assistants** (as before: read-only), and beneath it **Let the assistant request changes**, with **Allowed commands** and **Full control terminal** beneath that. All are off. They are in the host's edit screen and, as a settings button, on each row of **Shared hosts**, which also shows each server's level ("Read only", "Can request changes", "Can request changes and a terminal"). Switching on changes, or the terminal, asks you to confirm first.
- The approval card, shown over whatever you are doing, one at a time: "Run this command?", "Create this file?", "Replace this file?", "Change a service?" or "Open a terminal for the assistant?". It shows which assistant asked, for which server, the command in full exactly as the shell will receive it, or the path, size, whether a file is replaced, and a preview or a diff, with a countdown. When a file's preview is not the whole change, a warning at the top of the card says so. Buttons: **Deny**, **Allow once**, and **Allow for N minutes** when you turned that on.
- **Allowed commands**: commands that run on that server without a card when the assistant asks `run_command` for exactly that text on that server alone. No patterns, no partial matches, never for `run_on_hosts`; up to 50 per server, each shown in full. An entry is refused when you add it if it holds a line break, a control character, a space that is not a plain space, a character that changes the reading direction, an invisible or other format character, a private-use or unassigned code point, or a combining mark that can hide or change the character before it.
- **Allow for a while** (Settings → AI Bridge; Off, 5, 15 or 60 minutes; off by default): adds a button to cards that lets that assistant make any change on that server, with any of the four change tools, without asking again until the time runs out. **Approvals in force** lists them with the time left and a **Stop now** each.
- The activity log records how each change was allowed (allowed command, timed approval, once, for a while, denied, timed out, withdrawn), and says "Approved, but not run" with the reason for a change you allowed that was then refused or stopped before it ran. For a terminal it records what the assistant typed.
- An assistant that cancels a request gets no reply; its card is taken away and its work on the server stopped (a file write that has already begun replacing the file finishes).

### Security
- Nothing changes a server without a person's yes in the app, except what you chose beforehand: a command on that server's **Allowed commands** list (an exact match of the text) or a time-limited approval you gave on a card. A command's text is never judged: there is no "looks safe".
- Silence is a no: a card not answered in 2 minutes is denied. The card does not alert you or bring the app forward, so with the app in the background you will not see it and it is denied. A locked app shows no card and refuses; it does not queue. At most 8 cards wait at once and at most 3 from one assistant; more are refused straight away.
- The card shows control characters, right-to-left and other direction overrides, invisible and other format characters, look-alike spaces, private-use and unassigned code points, and combining marks that could hide a character, as marked stand-ins with a legend, so the text you read is the text that runs. Deny has the focus (Enter and Space deny), Escape or Back denies, and the Allow buttons are disabled for the first second after a card appears or changes.
- What you approve is what runs: the same text is shown, matched against the allowed list and run. A file is written to a temporary file with a random name and then renamed, and if the file changed on the server after you were asked, nothing is written. Before the rename a stopped write leaves the file as it was.
- After you answer, the app checks again: the server must still be the same one (address, port, user name, connection type and which jump host it goes through), still allow this, and the bridge must still be on and the app unlocked. If you edited the server while the card was open, the change is not made, and the activity log says "Approved, but not run". Editing any of those also takes away that server's waiting cards, its timed approvals and its terminal.
- Timed approvals are kept in memory only. They end when the time does, on **Stop now**, when you switch the bridge off, revoke the assistant, lock the app or restart it, and when the server is deleted, un-shared, stepped down to read-only or edited to point elsewhere. They never cover a terminal. Switching **Allow for a while** off ends them all.
- A terminal always needs a card, every time. An approved terminal gives the assistant a live shell as the saved sign-in user on that server. It can type any command, including ones you never see on a card, read any file that user can read, and reach anything that server can reach, with no further questions. The blocked-path list does not apply inside a terminal, or to commands. You can watch it, take over by typing, or stop it at any time. It opens its own connection that never carries your SSH agent or X11 windows, runs no startup command, does not attach to tmux or screen and never uses Mosh. Switching the bridge off, locking the app, revoking the assistant, or deleting the server, un-sharing it, stepping it down, switching its terminal off or pointing it elsewhere closes one the assistant still drives.
- No bridge connection ever carries your SSH agent or X11 forwarding, and the bridge no longer borrows a session you have open when that session or its saved host uses either; it opens its own connection. This closes a gap: once a session has asked for forwarding, the server keeps the agent for every later command on that connection.
- A stopped command's process group gets TERM, then KILL 3 seconds later. Changes have 2 run slots of their own, separate from the 4 for reads.
- Backups never carry allowed commands, the terminal switch or the **Allow for a while** setting. An imported server arrives with AI access off, no allowed commands and the terminal off, and importing keeps this device's own setting.
- What a command or a terminal prints is sent by your AI client to its own provider, like anything else the assistant reads. A file write's preview is shown to you on the card only and is not sent to the assistant. SecureShell Go and Dhiva Labs receive nothing. **Limits:**
  - The approval card does not alert you: with the app in the background it goes unseen and is denied after 2 minutes.
  - `read_screen` removes only private-key blocks and secrets the app knows. A key can still be read in pieces or encoded, and anything else on the screen goes to the assistant.
  - A program that moved itself into a session of its own (`setsid`) survives a stop. On a server without `setsid`, only the command's main process is stopped.
  - A replaced file keeps its permissions and nothing else: its owner, access lists and other hard links are not kept.
  - A file changed in the same second with the same size after you were asked is not noticed, and the change is made.
  - A change can time out while waiting for a free slot, before it ran, and a stopped command may have done part of its work.
  - A replacement is refused when the server reports neither the file's size nor its time.
  - Editing a jump host's own entry is not treated as a change of the servers behind it.
  - Allowed commands and timed approvals skip the card; that is what they are for.
  - Text on a server, in a command's output or on a terminal screen can contain instructions aimed at the assistant; the card is what stops a change you did not intend.
  - Commands are quoted for a fish login shell, but that has not been run against a real fish; nothing of this has been run on Windows yet; and a server needs `/bin/sh` for changes. The AI Bridge is not on macOS or Android.
  - The translations of the new text were written by machine and have not been read by native speakers.

### Changed
- The assistant's skill, plugin and instructions say how to ask: read first, say what and why before asking, one change at a time, stop if denied, and never ask you to switch on Allowed commands, Allow for a while or the terminal.
- "AI access (read-only)" is now called **Share with AI assistants**.
- Turning a server back to read-only, or un-sharing it, keeps its allowed commands and terminal switch stored but unused; they return when you allow changes again, and switching changes back on lists those commands and asks again about the terminal.
- The bridge-on explanation now says what can be allowed and that a terminal is a live shell.

## 1.6.0 - 2026-11-16

The AI Bridge: let an AI assistant read from the servers you choose, read-only, without ever giving it a password or key.

### Security
- The assistant never receives passwords, private keys or passphrases. By default it does not see a server's address, port or user name either ("Show address and username" is off), and those are removed from the error messages it gets.
- A bridge call never shows a prompt in the app. If a server needs a person to sign in (a locked vault, an unsaved password or passphrase, a login question, or a host key you have not checked), the call fails and asks you to connect to it once in SecureShell Go. A changed host key fails too, with a warning to check it. Prompts from outside the app can still appear: an SSH agent asking you to confirm or touch a key, or your desktop keyring's own unlock dialog.
- Common secret locations are blocked from reading by default: `~/.ssh`, `~/.gnupg`, `.env` files, key and certificate files, shell histories, `/etc/shadow`, `.npmrc`, `.pypirc`, `.git/config`, cloud CLI and container credentials, and more. Blocked entries are left out of folder listings and searches without a trace. You can add your own under "Extra blocked paths", and they stay blocked even with "Read sensitive paths" on. This is a default set, not a guarantee that no secret on a server can be read; for that, use a server account with limited read rights.
- Output is capped at 64 KiB per call, and private keys and secrets the app knows are removed from it.
- Each call has 30 seconds. A call that runs out of time, or that is cut off because you revoked the assistant or switched the bridge off, has its command on the server stopped and returns nothing it found.
- A server you have not switched AI access on for looks the same as one that does not exist.
- The bridge refuses everything while the app is locked.
- Backups never carry AI access, bridge settings or paired assistants. An imported server always arrives with AI access off, and importing keeps this device's own bridge settings.
- What an assistant reads is sent by that AI client to its own provider. SecureShell Go and Dhiva Labs receive nothing, but your AI provider does. Text on a server, such as a log line, can contain instructions aimed at the assistant.
- The app and the launcher talk over a local channel. On Linux it is a socket file only your user account can open. On Windows it is a port on `127.0.0.1` that a connection can use only with a secret kept in your user profile, together with a valid token.
- "Connect Claude Code" starts the `claude` program you installed, only after you confirm and showing its full path and version first. The token goes to it on its standard input only: never on the command line, in an environment variable, on screen, in the clipboard or in a log. Only a local file named `claude` is run, never one on a network share, and if the plugin's source changes between your confirmation and the run, it stops before anything is sent. It is not available in the snap or the Flatpak, which cannot start programs on your computer. If the plugin would not come from the published GitHub source, the confirmation says where it would come from and warns you.
- A pairing made by "Connect Claude Code" cannot be used until the setup is confirmed, and one left behind because the app was closed part way is removed the next time the app starts. A failed attempt revokes the pairing it just created, so no unused token is left, and puts the bridge back the way it was (switched off again if it switched it on). It reports success only when Claude Code confirms the token is saved, and says so if it could not undo something.
- A change to a paired assistant or to a server's AI access that cannot be written to disk is undone and reported, so what the app shows always matches what is stored. A revoke that cannot be saved says the pairing still works.
- The manual route puts the token in your shell's history file when you paste its third command, and the screen says so under the commands; "Connect Claude Code" does not. Delete that history line afterwards, or revoke the assistant and pair again if the history is shared.
- The activity log file is created so that only your user account can read it.
- An AI Bridge read on a server whose login shell is fish cannot be made to run text the app did not intend through a file name, folder or pattern that contains a backslash. Commands are quoted so that no login shell (fish included) reads a backslash as anything but a backslash.

### Added
- AI Bridge, on Linux and Windows: let an MCP-compatible AI assistant on your computer read from your servers, by name, without ever being given a password or key. It is off by default. Switch on "AI Bridge" in Settings (the app explains what it does each time you switch it on), pair an assistant under "Connect an assistant" to get a token and a ready-made config snippet, then switch on "AI access (read-only)" for each server you want it to see.
- An assistant can list the servers you shared, read server stats, list services, read the end of a log, list folders, read text files in parts and search for files by name. It cannot run commands, write files or change anything.
- "Connect an assistant" names the assistant and shows its launcher command, config snippet and token (shown once). "Paired assistants" lists them, and you can revoke one at any time.
- "Activity" shows every call an assistant made: the server, the tool, the arguments and how it ended (never what it read). You can clear it.
- A launcher program, `secureshellgo-mcp`, that MCP clients start. It only passes messages to the app, so the app has to be running. The deb, rpm, Arch package and Microsoft Store install put it on the PATH as `secureshellgo-mcp`; on the snap it is `secureshellgo.mcp`. The Flatpak is started through the command Flatpak exports for it, and the AppImage through the `.AppImage` file itself: both start the launcher instead of the app when an assistant runs them. "Connect an assistant" shows the right command.
- A plugin (`secureshellgo`) in this repository's plugin marketplace (`dhiva-labs`) that sets up the server entry and the skill and asks for the token.
- An agent skill, config snippets for common client shapes and plain-text instructions, in the `integrations/` folder of the source.
- "Connect Claude Code", in Settings under AI Bridge, sets Claude Code up in one step on Linux (deb, rpm, Arch package, AppImage and archive) and Windows. It appears only when the app finds the `claude` program on your computer, and it is not available in the snap or the Flatpak. You first see the same explanation as when switching the bridge on, plus the path and version of the program that will be run; Cancel changes nothing. If a step fails, the pairing it made is removed again and nothing is left behind.
- "Shared hosts" is a checklist of your saved hosts: tick the ones an assistant may read. It opens at the end of "Connect Claude Code" and from Settings → AI Bridge ("Shared hosts — N of M"); the per-host "AI access (read-only)" switch is still there. Nothing is ticked that was not already shared, and a quick connect that was not saved cannot be shared.
- The manual "Claude Code plugin" choice in "Connect an assistant" shows one block of three terminal commands (add the plugin source, install the plugin, give it the token), and says that `/plugin configure secureshellgo@dhiva-labs` is typed inside a Claude Code session, not in a terminal.

### Changed
- The AI Bridge is not available on Android or macOS.

### Fixed
- A backup no longer resets "Copy on select" to off when you restore it.
- Importing a backup no longer resets the app's language to the system default.
- An assistant that disconnects before the app has answered it no longer leaves an error behind in the app.

## 1.5.1 - 2026-11-03

Smoother copy and paste in the terminal, less in the way across the app, and trusted server keys that are no longer lost or flagged without cause.

### Added
- Copy on select (Settings › Terminal): text selected with a mouse goes straight to the clipboard. Off by default.
- On Linux a middle click pastes, as in other terminals: the terminal's own selection when there is one, the clipboard otherwise.
- A button to jump back to the latest output after scrolling up through the history.
- A paste of several lines shows the lines before they run. With a keyboard it is a dialog that Enter confirms and Escape cancels.
- The host form saves with Ctrl+S (⌘S on a Mac), has Save at the top, asks before throwing away changes and scrolls to the first field that needs fixing.
- A failed connection offers Try again and Edit host.
- The command palette also finds hosts by their address, and keeps the highlighted row in view.
- Enter in the snippet picker's search runs the top match.
- Ctrl+Shift+W closes the session in front, asking first as the Disconnect button does. Ctrl+Shift+N and Ctrl+Shift+P move between the panes of a split. On a Mac, ⌘ works in place of Ctrl for these and the other Ctrl+Shift shortcuts.
- Enter or Space dismisses a server's login banner.

### Changed
- Selecting text with a mouse no longer brings up the Copy bar, which used to shrink the terminal and move the text being selected. Right-click, Ctrl+Shift+C and copy-on-select copy instead, and the selection stays highlighted after a copy.
- On touch, the Copy bar floats over the terminal instead of resizing it, and moves to the top when the selection is near the bottom.
- "Copied" and "Clipboard is empty" are a small note over the terminal instead of a snackbar across the bottom of the window.
- Right-clicking a file opens a menu at the pointer instead of a sheet from the bottom; the host ⋮ button does the same with a mouse. Touch keeps the sheets.
- Snackbars replace each other instead of queueing, and the ones that only repeated what is on screen are gone: "Downloading…", "Queued", a plain editor save.
- Copy buttons in the host key and public key dialogs show "Copied" themselves, instead of a snackbar hidden behind the dialog.
- Cancel all asks first when it would stop more than one transfer.
- Opening a folder keeps the current listing on screen while the next one loads, instead of a full-screen spinner.
- Quick connect focuses the password field and no longer opens a "Save this server?" dialog by itself; Save stays on the page.
- The host ⋮ button is a full 48dp target on touch in every list style.
- A dropped connection on screen is told by its banner alone; the red snackbar is kept for a session in the background.
- With one session open there is a single Transfers button instead of two that showed the same thing.

### Fixed
- Trusted server keys are kept when the system keyring loses the key that protects them — after a keyring reset, a new login password, or the app's data moving to another computer — instead of the app warning that they failed an integrity check and asking about every server again.
- On a computer with no keyring, including the Snap Store app before it is allowed to reach one, trusted server keys are remembered between launches instead of every server asking again each time.
- Two copies of the app started together no longer leave the trusted server keys in a state the next launch cannot check.
- When the saved server keys really cannot be checked, the app says so once, calmly, and keeps the old file aside, instead of the same red warning on every launch.
- Closing the last session from its banner ("Shell ended", "Connection lost") left an empty window with no way back. It now asks first when transfers would be lost, and returns to the host list.

## 1.5.0 - 2026-10-28

A major update: remote desktop and virtual desktops, an IDE-like file editor, Mosh, sign-in with agents, security keys and certificates, agent and X11 forwarding, a terminal that survives network changes and sleep, commands on many servers, new file actions, Windows Hello, translations into eight languages, and layouts for tablets, foldables, touch and mouse.

### Security
- On Android, the app lock stays shut when the device cannot show its unlock prompt, instead of letting the app open.
- On Windows, opening a downloaded file no longer goes through `cmd`, so a crafted file name cannot run a command.
- An RSA host key is recognised as the same key whichever signature algorithm the server uses with it, instead of being treated as a new or changed key.
- A direct server-to-server copy only goes ahead when the destination presents the host key this device already trusts.
- A locked system keyring no longer wipes the list of trusted host keys.
- Saved hosts, settings and trusted keys are written atomically and in order. A file that cannot be read is set aside, not overwritten.
- Replacing a file on upload writes the new copy first and swaps it in, so a failed upload no longer leaves the old file destroyed.
- A backup that demands an unreasonable amount of key-derivation work is refused instead of freezing the app.

### Added
- Remote desktop: see and control a server's desktop from any device, phones included, over the SSH connection you already have. It works with GNOME on Wayland, X11 desktops and Windows. A small agent is copied to the server for the session and stopped afterwards; it listens on the server's loopback only, so no port is opened and SSH is the only login. The person at the server's screen is told while it is being viewed.
- Virtual desktops on servers with no screen: start a private desktop, such as Xfce, or a single program, and use it in the same viewer. Optionally keep it running after you disconnect and come back to it from Remote desktop later.
- Open an app in a window: run one graphical program on the server and have its window open on your own desktop, without a terminal and without turning on the host's X11 switch first. A server that turns it down for want of `xauth` gets it installed in one click, and the program starts. Where that cannot work — on a phone, or with no X server on Windows — it offers a virtual desktop instead.
- Show a Mac's screen through its built-in Screen Sharing, over the same SSH connection.
- On touch screens the viewer has a trackpad mode and a direct-touch mode, pinch to zoom, and a key bar with Esc, Tab, Ctrl, Alt, Super, arrows, function keys and Ctrl+Alt+Del. Clipboard text goes both ways.
- When a server is missing what a virtual desktop needs (the virtual screen, a desktop, or a program you typed), the app offers to install it and does, asking for your sudo password only if the server wants it. It is used for that install and not saved.
- VS Code, VSCodium, Cursor and Chromium-based browsers open in a virtual desktop, as root too: the app adds the options they need there and says so.
- The remote editor indents like a code editor. Tab and Shift+Tab indent and outdent, Enter keeps the indentation and goes a level deeper after a Python colon or an opening bracket, and each file's own style (tabs or 2, 4 or 8 spaces) is detected and shown in the status bar, where it can be changed.
- Line and comment shortcuts: toggle comment (Ctrl+/), move line (Alt+↑/↓), duplicate line (Shift+Alt+↑/↓), indent and outdent line (Ctrl+] and Ctrl+[).
- Show whitespace, and a warning when a Python, YAML or Makefile file mixes tabs and spaces.
- On phones and tablets, a row of keys over the keyboard with Tab, outdent, arrows, brackets and symbols, plus undo and redo.
- Zoom with a pinch or Ctrl + and Ctrl −. The editor keeps its own text size, also set in Settings.
- With several files open on a wide screen, they are listed in a side panel.
- Syntax colouring for C and C++, Go, Rust, Java, Kotlin, Ruby and PHP.
- A connection that has silently died (no answer to three keep-alives and nothing else heard from the server) is noticed and reconnected, instead of leaving the terminal frozen until the system gives up on it.
- Sessions check their connection straight away when the network changes, when the app comes back on screen and when a computer wakes from sleep, and reconnect over the new network at once.
- A disconnected session always has a Reconnect button, and one that stopped trying because there was no network tries again by itself when the network comes back.
- When the shell exits but the connection is fine, a "Shell ended" strip offers Restart: a new shell in the same tab, with no new login.
- Persistent sessions: a host set to tmux or GNU screen runs its shell inside one, named per tab (`ssg-<host>-<tab>_`, as `tmux ls` and `screen -ls` show it), so a reconnect — or reopening the app — lands back in the same shell with whatever was running in it. tmux falls back to screen, and either falls back to an ordinary shell with a one-line notice — when it is not installed, and also when it is installed but will not start. The host's startup command is only typed into a new shell, never into one left running.
- Mosh: a host whose terminal connection is set to Mosh (Advanced in the host editor) now gets its terminal over Mosh. The app starts `mosh-server` over the SSH connection it already has, then talks to it over UDP — no `mosh` program needed on the device. Sign-in, files, tunnels and server commands stay on SSH.
- A Mosh terminal carries on through what drops SSH: switching between Wi-Fi and mobile data, a new address, a phone or laptop asleep for hours. It picks up where the server is when the network comes back, with nothing to reconnect.
- When the server has been out of touch for a few seconds, a bar across the top of a Mosh terminal says how long ("mosh: Last contact 12 seconds ago."), and goes once it catches up.
- On a slow connection, what you type appears straight away, underlined until the server confirms it (Mosh's local echo). It only switches on when the link is slow, and never shows at a password prompt.
- If SSH drops while a Mosh terminal is open, the terminal keeps working; files and tunnels reconnect in the background, and the strip above the terminal says so. If reconnecting SSH gives up or is stopped, the strip says that too and offers Reconnect, and SSH is tried again by itself when the network comes back. Typing `exit` in the terminal meanwhile ends the session; nothing starts it again unless you press Reconnect.
- Where Mosh cannot be used — `mosh-server` not installed, no UTF-8 locale on the host, or UDP blocked by a firewall — the terminal opens over SSH instead, with one line saying why. A `mosh-server` started for a connection that never got through is stopped again.
- `mosh-server` is found in Homebrew and other common install locations as well as on the PATH.
- Hosts set to keep their shell in tmux or screen run it under Mosh too, so a Mosh terminal can also be re-attached after the app closes. If tmux or screen will not start there, the terminal falls back to an ordinary shell with a one-line notice, as it does over SSH.
- A Mosh terminal keeps a scrollback of what scrolled past while you watched. Mosh sends screens rather than every line of output, so a burst that flashed by between two screens is not in it.
- Closing a Mosh tab ends the session on the server, as Mosh's own Ctrl-^ . does. If the goodbye cannot get through over UDP, `mosh-server` is stopped over SSH instead, so neither it nor the shell under it is left running.
- Agent and X11 forwarding reach SSH terminals only; Mosh cannot carry them, so a Mosh terminal has neither.
- Sign in with your computer's SSH agent (ssh-agent, Pageant or the Windows OpenSSH agent) on Linux and Windows, including FIDO2 security keys such as a YubiKey (`sk-ed25519`, `sk-ecdsa`). The private key never leaves the agent. On Windows, `SSH_AUTH_SOCK` is used only when it names a pipe, and Pageant's pipe only when it belongs to you, as PuTTY checks, so another account on the same PC cannot stand in for your agent.
- SSH certificates: load a `-cert.pub` file or paste one in the host's sign-in settings, for servers that trust a certificate authority. The host shows the certificate's key ID, the users it is valid for, when it is valid, its critical options and what it permits, and says clearly when it is for a different key, is a host certificate, has expired or is not valid yet. It warns when the certificate forces a command (the server runs that instead of a shell), only works from certain addresses, carries an option OpenSSH does not know, or names no users, which a server trusting its CA through `TrustedUserCAKeys` refuses.
- Forward SSH agent, per host: `git` and `ssh` in the shell can use the keys in your computer's agent and the host's own key, without copying them to the server. Stats, logs and other server actions keep working on the same connection.
- Forward X11, per host, on Linux and Windows: graphical programs started on the server open their windows on your screen (needs an X server, such as VcXsrv or X410 on Windows). Only for servers you trust. On Linux they get limited access, as with `ssh -X`: each program is let in with a cookie of its own that keeps it away from your other windows. Where the display cannot do that, the server can see and control every window on this display while you are connected, as with `ssh -Y`: always on Windows, whose X servers have no limited mode (the host's X11 switch says so), and on a Linux display without `xauth` or the X SECURITY extension (the terminal says so when the shell opens).
- Importing from `~/.ssh/config` now brings in `ForwardAgent`, `ForwardX11` and `CertificateFile`, and finds a certificate saved next to an `IdentityFile` the way `ssh` does. Settings under a `Match` line are conditional, so they are skipped with a note rather than applied to the `Host` above them.
- Allow legacy algorithms, a per-host switch for old routers and NAS boxes that only speak SHA-1 key exchange, `ssh-rsa` signatures or CBC ciphers. The connection error says when a host needs it.
- Keyboard-interactive login, so servers that ask for a one-time code or other prompts (two-factor authentication) can be signed in to.
- The server's login banner is shown when it sends one.
- Find in the terminal: Ctrl+Shift+F (or "Find in terminal" in the session's ⋮ menu, or the right-click menu) searches the whole scrollback, with long lines the terminal wrapped searched as one line. It shows how many matched, highlights every match, scrolls to the one you are on, and has Match case and regular-expression switches; Enter and Shift+Enter step through matches and Escape closes it. It searches once you pause typing, and stays quick over a long scrollback. A regular expression that would take too long (some can run for minutes) is stopped after two seconds with "Pattern too slow", and the terminal keeps working meanwhile.
- Web addresses in the terminal can be opened: Ctrl+click one with a mouse (the address is highlighted while Ctrl is held over it), right-click it, or long-press it on a touch screen for Open link and Copy link. Only http and https addresses open, in the browser; nothing else is ever run. While a program is using the mouse (tmux or vim with mouse mode on), Ctrl+click goes to the program and Ctrl+Shift+click opens the link.
- Session logs: "Record session log…" in the session's ⋮ menu writes everything the session prints to a file, as plain text (colours and control codes removed) or exactly as received. On a computer you choose the file first and it is written as the session runs; on Android you choose where to save it — any folder, an SD card or a cloud drive — when you stop. A "Recording" badge stays on the terminal while it runs, and closing the session saves the log first. If the log fills up (on Android, at 32 MB) or its file cannot be written, recording stops and says so — also when it happens while you are elsewhere in the app, in which case you are told, and on Android offered to save the log, when you come back to the session. Closing the app finishes and keeps a log being written to a file. A name typed without an extension gets ".log", and becomes "name (1).log" rather than replace a file the save dialog did not ask about.
- Ctrl+= and Ctrl+− make the terminal text larger and smaller, and Ctrl+0 puts it back; the size is kept for the next session, as a pinch-zoom is.
- Blinking cursor, in Settings > Terminal.
- Delete, Rename, New folder and Permissions (chmod) in the file browser.
- Run a command on many servers at once: pick hosts or whole groups (from the host list's selection bar or a group's menu), type a command or take a snippet, check the list of hosts, then watch each one's output, exit code and running time come in. Copy one host's output or all of it, stop one host or all, and re-run on the hosts that failed. Leaving while it runs lets the commands already started finish; hosts still waiting their turn are not started.
- Hosts that would need you at sign-in — no saved password, an unsaved key passphrase, a one-time code, or a host key not yet checked — are skipped with the reason instead of waiting on a prompt. A changed host key stops that host.
- File browser: Compress files and folders to .tar.gz or .zip, on the server.
- File browser: Extract .tar, .tar.gz/.tgz, .tar.xz/.txz and .zip into a folder beside the archive. An existing folder is never written into without asking whether to keep or replace its files, and archives with entries that would land outside the folder are refused, links pointing outside it included. A folder that already holds such a link is not extracted into. Extracted files get the account's usual permissions.
- File browser: Search on the server from the folder on screen, by name or pattern and optionally by what files contain. Tap a result to go to it.
- File browser: Duplicate makes a "name copy" beside the original, with permissions, times and links kept.
- File browser: Change owner and group, optionally for everything inside a folder. Links change themselves, never what they point to.
- The browser asks each server once which tools it has (GNU, BusyBox, BSD) and offers only the actions that will work there — no zip on a box without one, nothing on an SFTP-only account.
- Compress, Extract, Duplicate and Change owner keep running on the server if the app is closed, and can be stopped from the browser while they run, on servers without `setsid` (macOS, FreeBSD) too.
- A direct server-to-server copy now runs on the source server itself and finishes even if the app is closed, the phone sleeps or the network drops. The app picks the result up the next time both servers are open.
- A diagnostics log for bug reports, off unless you turn on "Keep a diagnostics log" in Settings. Errors and crashes are then recorded on this device with secrets removed before anything is written: your saved credentials, passwords typed for a connection without saving them, answers to a server's hidden login prompts, and the vault and backup passphrases, wherever they turn up, as well as anything shaped like a password, private key or token. A secret the app learns after something was written is removed from the log on disk too. Copy it to the clipboard, view it, or clear it from Settings. It never leaves the device unless you paste it somewhere, stays small, and turning it off deletes it.
- App lock on Windows, unlocked with Windows Hello (your PIN, fingerprint or face). If the Hello prompt cannot be shown, the app stays locked.
- Backups can include your trusted host keys, if you tick "Include trusted host keys" when exporting, so a restored device recognises your servers without asking again. On import you see each new server and its key fingerprint, and they are trusted only if you tick "Trust these keys" (it starts off). Servers this device already knows keep exactly the keys it trusts: a backup can neither replace them nor add another key type for them.
- "Save to…" for backups: save to any folder, or to a cloud drive such as Google Drive, OneDrive or Dropbox, through the system's save screen. "Save to Downloads" is still there. On a computer, a name typed without `.ssgbackup` gets it added, and if that name is already taken the backup is saved beside it as `name (1).ssgbackup` instead of replacing a file you were not asked about. On Android, a save that fails, or is cut off by the app being closed or rotated with the save screen open, leaves no empty file behind; a file you chose to replace is never deleted.
- Screens are laid out for the hands on the device, not its operating system: a tablet in a trackpad cover or a Samsung DeX desk gets split panes, right-click menus and drag-and-drop like a desktop, and a Windows tablet used by touch gets the touch layout. Each gesture goes by the pointer making it: a file drags to another session's tab with a mouse or trackpad, while a finger's long-press on it opens its actions.
- On foldables, a session's terminal and files split at the hinge: one on each side when the device is open like a book, the terminal above the fold and the files below when it stands on a table. A device with two screens puts one on each and nothing under the hinge.
- On tablets, the terminal can take the whole width with one button, and give the files their side back with another.
- Right-click on the terminal for Copy, Paste and Select all, and on a saved host for its actions in a menu beside the pointer. A middle click on the terminal opens no menu.
- Keyboard shortcuts on the sessions screen, from the terminal or the files alike: Ctrl+Shift+T for a new session, Ctrl+Tab and Ctrl+Shift+Tab between sessions (in a split window, to the pane already showing one), Ctrl+Shift+E between terminal and files, Ctrl+Shift+Enter for a full-width terminal. Ctrl+PgUp and Ctrl+PgDn stay with the shell, for vim and emacs. Tooltips name them when a keyboard is in use.
- The app speaks Simplified Chinese, Japanese, Brazilian Portuguese, Spanish, Russian, German, Korean and French as well as English. It follows the device's language, or the one picked in Settings > Appearance > Language.

### Changed
- The app is about 5.7 MB larger, for the remote-desktop agents. Nothing extra runs until a remote desktop is opened, and agents left on a server by an older version of the app are removed when a newer one is installed.
- Each open file keeps its own undo history when switching between them.
- Transfers cut off by a dropped connection are marked interrupted rather than cancelled, and start again by themselves once the session reconnects — including copies to another server whose session dropped.
- A server closing the connection under a running shell (a reboot, sshd restarting) is reconnected; typing `exit` still ends the session for good.
- On Android 14 and later the background service keeping sessions alive runs as a special-use service, so Android 15's six-hour daily limit no longer stops it; if Android does stop it, it is started again when the app is next on screen.
- When a server refuses agent or X11 forwarding, the shell still opens, with a line at the top saying what was refused and why it might be — including a sign-in certificate that does not permit it (no `permit-agent-forwarding` or `permit-X11-forwarding`).
- A graphical program on the server that cannot reach your X server (none running, or the connection was turned away) is reported in the terminal as it happens, instead of only failing on the server.
- On a phone-width window the sign-in choice shows as Password, Private key and Agent, without icons, so all three fit.
- Updated the SSH library (dartssh2 4.1). Weak algorithms are no longer offered unless a host has the switch above turned on.
- Settings > Terminal's options now take effect: the cursor shape, the bell (vibrate, a brief flash of the screen, or nothing; a burst of bells rings once) and the font apply straight away to open sessions, and the scrollback length to each session opened after the change.
- JetBrains Mono is bundled with the app, so choosing it gives the same terminal on every device, box-drawing characters included. Its licence (SIL Open Font License 1.1) is on the licences page.
- The Settings preview shows the chosen font and cursor.
- The monitoring menu in a session's toolbar is now the session's ⋮ menu: Find in terminal and the session log, then Server stats, Services & processes and Tail a file. A disconnected session's scrollback can still be searched.
- Direct transfer is ticked by default whenever it can be used.
- The terminal's and the editor's extra-keys rows follow Settings → Keyboard → Extra keys row: automatically, they hide while a hardware keyboard is typing and come back when the on-screen keyboard opens. Always and Never mean just that. Keys typed while the on-screen keyboard is open never count as a hardware keyboard — terminal keyboards such as Hacker's Keyboard and Unexpected Keyboard send Esc, Tab and Ctrl the way a real one does — and once the on-screen keyboard has been open, the row stays until a key is typed with it put away.
- A Ctrl armed on the terminal's extra-keys row is let go when the row hides, rather than turning the next key typed into a control code with nothing on screen to say so.
- The editor puts the cursor in the file as it opens wherever a hardware keyboard is in use, a keyboard cover on a tablet included, and starts it at the top of the file.
- Once the screen has been touched, buttons, session tabs and their close buttons are at least 48dp, also on a desktop with a touchscreen. The AWS style's compact spacing gives way to these targets on a touch screen, and split-pane headers and the editor's tab strip grow to hold them.
- Terminal and files share the screen only when the window is tall enough as well as wide; a phone on its side shows one at a time.

### Fixed
- Saving no longer changes bytes nobody edited: a UTF-8 byte-order mark is kept, Ctrl+S on an unchanged file writes nothing, and a file mixing Windows and Linux line endings asks which to keep before saving.
- Tabs are drawn as wide as their tab stop instead of one character.
- With wrapping off, long lines no longer wrap, and line numbers stay beside their lines with large system text and in long files.
- A session that had already reconnected once now reconnects again on its next drop, instead of staying disconnected.
- When reconnecting stopped because of a refused login or a changed host key, the strip above the terminal now says so.
- The block cursor no longer hides the character under it; the character shows through in reverse, and the cursor covers both halves of a wide (CJK) character.
- Ctrl+Shift+− (Ctrl+_, undo in bash and Emacs) reaches the shell; it used to send nothing.
- Replacing a folder on upload uploads and checks the new one before the old one is removed. A failed upload no longer leaves the folder gone.
- Filling in a snippet's blanks no longer trips an error as the dialog closes.
- A server-to-server copy that finished at the moment the app checked on it could be reported as lost.
- The host list is laid out for the screen it is on, without clipped or overflowing rows at phone, tablet and desktop sizes or with large text.
- A long user@host no longer overflows the sessions screen's title on a phone.
- A long host name no longer runs off the edge of the Tunnels screen on a narrow phone with large text.
- On a 320dp phone the sessions screen keeps room for the host's name: snippets, monitoring, new session and disconnect move into a menu.
- The host form no longer runs off the right edge of a narrow window when a jump host or a group has a long name.
- The file browser's path reads "/ home / deploy", without a second slash after the root.
- The extra-keys row's Paste key shows a clipboard icon, where some fonts drew an empty box.
## 1.4.5 - 2026-10-16

### Added
- Linux arm64 and Windows arm64 builds: `SecureShellGo-linux-arm64.tar.gz` and `SecureShellGo-windows-arm64.zip`, built natively on ARM64 runners and started once there to check that they run.
- An arm64 snap next to the amd64 one. CI builds both, installs each under confinement and starts it on its own architecture.

### Changed
- `jni` (a transitive dependency of the Android secure-storage plugin) is locked at 1.0.3, which compiles on Linux arm64.
- `debian/rules` no longer hard-codes the x64 Flutter bundle folder. The PPA package is still amd64 only.
- CI runs the tests on Linux x64 and arm64 and on Windows x64 and arm64. Four test files that assume Linux (POSIX paths and file modes, the Linux "connection refused" text, a UTF-8 shell) are skipped on Windows.

No application code changed since 1.4.4.
