# SecureShell Go

[![ARM64 builds](https://github.com/Dhiva-Labs/SecureShellGo/actions/workflows/desktop-builds.yml/badge.svg?branch=main)](https://github.com/Dhiva-Labs/SecureShellGo/actions/workflows/desktop-builds.yml)
![Linux x64 | arm64](https://img.shields.io/badge/Linux-x64%20%7C%20arm64-informational?logo=linux&logoColor=white)
![Windows x64 | arm64](https://img.shields.io/badge/Windows-x64%20%7C%20arm64-informational?logo=windows&logoColor=white)
![Linux: deb | rpm | Arch | AppImage | Flatpak | Snap](https://img.shields.io/badge/Linux-deb%20%7C%20rpm%20%7C%20Arch%20%7C%20AppImage%20%7C%20Flatpak%20%7C%20Snap-informational?logo=linux&logoColor=white)

A security-first SSH terminal and SFTP client written in Flutter, for Android,
Windows and Linux (a macOS build is attached to releases too). Connect to your
servers, run a real interactive shell, edit and transfer files, with strict
host-key verification at the core. The interface is translated into English,
Simplified Chinese, Japanese, Brazilian Portuguese, Spanish, Russian, German,
Korean and French.

Latest release: **1.7.0**. Install options for each platform are
[below](#install): release downloads (APK, Linux, Windows, macOS), the Ubuntu
PPA (`ppa:dhiva-labs/apps`) and the Snap Store (`sudo snap install secureshellgo`).

## Engineering highlights

- **Mosh client written from scratch in Dart**, with no native Mosh code. It
  covers the State Synchronization Protocol with Mosh's own timing
  ([`mosh_transport.dart`](lib/services/mosh/mosh_transport.dart)), fragment
  reassembly ([`mosh_fragment.dart`](lib/services/mosh/mosh_fragment.dart)), a
  protobuf codec ([`mosh_protobuf.dart`](lib/services/mosh/mosh_protobuf.dart)),
  local echo prediction ([`mosh_overlay.dart`](lib/services/mosh/mosh_overlay.dart))
  and the SSH bootstrap ([`mosh_bootstrap.dart`](lib/services/mosh/mosh_bootstrap.dart)).
  Tests: [`mosh_wire_test.dart`](test/mosh_wire_test.dart),
  [`mosh_transport_test.dart`](test/mosh_transport_test.dart),
  [`mosh_prediction_test.dart`](test/mosh_prediction_test.dart),
  [`mosh_integration_test.dart`](test/mosh_integration_test.dart).
- **AES-OCB (RFC 7253) implemented over pointycastle's AES block cipher**, the
  authenticated cipher Mosh seals every datagram with
  ([`ocb.dart`](lib/services/mosh/ocb.dart)). It supports every key, nonce and
  tag size in the RFC, and
  [`mosh_ocb_test.dart`](test/mosh_ocb_test.dart) runs the RFC's Appendix A
  sample results.
- **Tamper-evident known_hosts store.** The trusted-keys file is wrapped in an
  HMAC envelope keyed from platform secure storage, verified in constant time,
  with four verdicts (verified, legacy-migrated, re-keyed, tampered) and a
  fail-closed path that empties the trust list and warns
  ([`known_hosts_integrity.dart`](lib/services/known_hosts_integrity.dart),
  [`known_hosts_integrity_test.dart`](test/known_hosts_integrity_test.dart)).
  The design is written up in [ARCHITECTURE.md](ARCHITECTURE.md).
- **Host-key policy keyed like OpenSSH** on (host, port, key type), with a
  changed key blocking the connection until explicitly overridden
  ([`host_key_policy_test.dart`](test/host_key_policy_test.dart),
  [`known_hosts_service_test.dart`](test/known_hosts_service_test.dart)).
- **Encrypted backups** with Argon2id and AES-256-GCM
  ([`backup_crypto.dart`](lib/services/backup_crypto.dart),
  [`backup_crypto_test.dart`](test/backup_crypto_test.dart)).
- **Remote desktop over the existing SSH connection**, using a small agent
  copied to the server for the session
  ([`lib/services/remote_desktop/`](lib/services/remote_desktop)).

## Status and limits

- Version 1.7.0. The Android app is in testing and is distributed as an APK on
  the Releases page; it is not on Google Play. The Windows and Linux builds are
  built and started in CI, but haven't had the testing the Android app has.
- Windows builds are zip downloads from Releases. Microsoft Store packaging
  exists in the repo ([`store-msix.yml`](.github/workflows/store-msix.yml),
  [store listing draft](store/microsoft-store-listing.md)); this README does not
  claim a Store listing.
- macOS builds are unsigned (see below). iOS is not supported.
- The security code has not had an independent audit. The Mosh client was
  written from the protocol and the Mosh source, and has not been run against
  every server version.

**Documentation:** step-by-step guides at [learn.dhivalabs.com](https://learn.dhivalabs.com/apps/secureshellgo/): [install](https://learn.dhivalabs.com/apps/secureshellgo/install) · [beginner guide](https://learn.dhivalabs.com/apps/secureshellgo/getting-started) · [troubleshooting](https://learn.dhivalabs.com/apps/secureshellgo/faq). New to the topic? Try the [Networking and SSH](https://learn.dhivalabs.com/tracks/networking/) and [Security and safe habits](https://learn.dhivalabs.com/tracks/security/) learning tracks.

## Features

### Terminal
- Full xterm-256color terminal (powered by `dartssh2` + `xterm`) with colors,
  resize handling, and scrollback
- Extra-keys bar: Esc, Tab, Ctrl (sticky), arrows with long-press repeat,
  `^C ^D ^Z ^L ^R`, pipe/slash/tilde — all 48 dp touch targets with haptics
- Pinch or Ctrl+= / Ctrl+− to zoom, ten colour schemes, the bundled
  JetBrains Mono font, and a choice of cursor shape, blinking and bell
- **Find** across the whole scrollback (case and regex), clickable links
  (Ctrl+click, or long-press on touch), and a session log you can save to a
  file
- Copy & paste with the system clipboard: long-press selection toolbar,
  dedicated Paste key, and a "Paste N lines?" guard against accidental
  multi-line command floods
- Hardware keyboard support: Ctrl+letters pass through (Ctrl+C is SIGINT),
  Ctrl+Shift+C / Ctrl+Shift+V for copy/paste

### Security
- **Trust-on-first-use host-key verification**, keyed on
  `(host, port, key type)` exactly like OpenSSH `known_hosts`
- SHA256 fingerprints shown for out-of-band verification before you accept
- A changed host key **blocks the connection** with a full-screen warning and
  requires an explicit, checkbox-gated override
- The trust store is sealed with an HMAC whose key lives in the platform's
  protected storage — a tampered or stripped store fails closed and warns you
- Passwords, private keys and passphrases are stored only in the Android
  Keystore, Windows Data Protection or the Linux desktop keyring — never in
  plain text

### Connections
- Saved host manager: one-tap connect, last-connected timestamps,
  quick-connect without saving
- Password and private-key auth (OpenSSH, PKCS#1 RSA, ECDSA; passphrase
  support) — import `.pem` key files directly, including AWS EC2 keys
- Two-factor (keyboard-interactive) logins; sign in with ssh-agent, Pageant
  or the Windows OpenSSH agent, security keys (`sk-ed25519`) included; and
  OpenSSH user certificates
- Per host: agent forwarding, X11 forwarding (desktop), and an "Allow legacy
  algorithms" switch for old routers and NAS boxes
- **Mosh**, built in: the terminal survives roaming between networks and long
  sleeps, while files and tunnels stay on SSH
- Sessions survive app switching: a quiet foreground service plus 30-second
  keepalives hold the connection while you use other apps
- Clean reconnect states when a server drops — never a zombie terminal

### Files (SFTP)
- Remote file browser sharing the live SSH session with the terminal —
  switching views never drops your shell
- Downloads stream straight into the device's Downloads collection with flat
  memory usage (multi-gigabyte safe), progress, cancel, and multi-select —
  with "Open" the moment one lands
- Download a whole folder: the tree is walked, counted and sized before
  anything moves, then saved under `Download/<folder>/` with its structure
  intact
- **Upload here**: pick any number of files and they land in the directory
  you are looking at, with per-file progress, cancel and retry, and a
  replace / keep both / skip prompt when a name is already taken
- **Share to SecureShell Go**: send files from any app's Share menu, pick a
  saved host and a folder, and they upload — reusing a session you already
  have open instead of asking you to sign in again
- Rename, delete, new folder, permissions, change owner, duplicate,
  compress and extract archives, and search on the server
- **Direct server-to-server copies** that run on the source server and finish
  even if the app is closed
- Hidden-files toggle, dirs-first sorting, breadcrumbs, pull-to-refresh

### Desktop workspace
- Split the terminal area into up to four resizable panes, each showing a
  different server, with the tab strip holding whatever is not on screen
- **Broadcast input**: type once and every visible pane's shell receives it,
  behind a loud red indicator and off by default
- Organise saved servers into collapsible groups with colour tags, and search
  across all of them
- **Ctrl+K command palette** over hosts, snippets and actions; quick-connect
  bar for `user@host:port`; import servers from `~/.ssh/config`
- Command snippets with `{placeholder}` prompts and per-host startup commands
- **Run a command on many servers** at once, with live per-host output, exit
  codes, Stop, and re-run on the ones that failed

### Look and feel
- Four UI styles — the app's own look, plus AWS-, Google Cloud- and
  Azure-inspired palettes — each with a light and dark half, switched live
  from Settings with no restart
- On desktop, each style also lays the saved-hosts list out its own way: a
  console-style table, an airy card grid, or a flat accented list; phones
  always keep the simple layout and pick up only the palette
- Select multiple saved hosts and **push a file to all of them at once**,
  with bounded concurrency, a per-host pass/fail result, and retry for just
  the ones that failed

### Connections that stay up
- Automatic reconnection: a link that stops answering is noticed, and a
  network change, waking from sleep or returning to the app restores the
  session in the same tab, resuming interrupted transfers; a changed host key
  aborts rather than reconnecting quietly
- Optionally keep each shell in **tmux or screen** on the server, so a
  reconnect lands back in the same shell, running job and all
- **Jump hosts** (`ProxyJump`): reach a server through a bastion, with both
  hops verified against known-hosts independently
- **Tunnel manager**: saved local, remote and dynamic (SOCKS5) port forwards
  with live byte counters, bound to loopback unless you say otherwise
- Generate an ed25519 key in the app and install it on a server, and review
  or forget trusted host keys from Settings

### Editing and monitoring
- **Built-in remote editor** that edits code like an IDE: detected tabs or
  spaces, Tab/Shift+Tab, auto-indent (Python-aware), comment and move-line
  shortcuts, visible whitespace, per-file undo, and a key bar on touch
  screens; syntax highlighting for twenty languages, find and replace, and a
  save that never changes bytes you did not edit (BOM and line endings kept)
  and publishes through a verified temporary file, keeping permissions
- Per-host path bookmarks and one transfer panel across every open session
- Server stats (load, memory, disk, uptime), a live log viewer with filtering
  and severity highlighting, and a systemd service and process manager

### Remote desktop and graphical apps
- **See and control a server's desktop**, TeamViewer-style, from any device,
  phones included: GNOME on Wayland, X11 desktops and Windows. The app copies
  a small agent over the SSH connection you already have, starts it for the
  session and stops it after; it listens on the server's loopback only and
  is reached through the SSH tunnel, so no port is opened and SSH is the only
  login. The person at the screen is told while it is being viewed.
- **Virtual desktops on headless servers**: start a private screen (Xvfb)
  running a desktop such as Xfce, or a single program, and use it from the
  same viewer. Optionally keep it running after you disconnect and come back
  to it later.
- **Open an app in a window**: run one graphical program on the server and
  have its window open on this device's own desktop, through X11 forwarding
  (Linux, or Windows with an X server such as VcXsrv or X410). No host
  setting to turn on first, and a server missing `xauth` gets it installed
  in one click.
- **Macs** through their built-in Screen Sharing, over the same tunnel.
- Mouse, keyboard and clipboard; on touch screens a trackpad mode and a
  direct mode, and a key bar with Ctrl, Alt, Super and Ctrl+Alt+Del.
- Nothing runs on a server until you open a remote desktop on it. The agents
  add about 5.7 MB to the app, and older ones the app left behind are
  removed from servers when a newer one is installed.

### Locked down
- Optional app lock behind your device's own authentication (Android) or
  Windows Hello
- An opt-in diagnostics log for bug reports, kept on the device with
  passwords and keys removed
- **Encrypted backup**: export hosts, groups, settings, snippets, tunnels and
  bookmarks to one passphrase-protected file — Argon2id and AES-256-GCM, with
  saved passwords and trusted host keys included only if you ask — and save
  it anywhere, cloud drives included

### Every screen size
- Material 3 window-size-class layouts: side-by-side terminal + file browser
  on tablets, Samsung DeX, and unfolded foldables (split at the hinge, or
  above and below in tabletop posture); host grid on wide screens
- Laid out for the input in use: touch, mouse or hardware keyboard — the
  extra keys row hides while you type on a keyboard
- Live relayout on window resize and fold/unfold — the session stays connected
  through transitions
- Comfortable on small phones (320 dp) in portrait and landscape

## Install

Download the latest APK from the
[Releases](https://github.com/Dhiva-Labs/SecureShellGo/releases) page and
install it (Android 7.0+).

### Desktop (Linux, Windows, macOS)

Tagged releases also attach desktop builds on the same
[Releases](https://github.com/Dhiva-Labs/SecureShellGo/releases) page:

| Platform | Asset |
|---|---|
| Linux x64 | `SecureShellGo-linux-x64.tar.gz` |
| Linux arm64 | `SecureShellGo-linux-arm64.tar.gz` |
| Windows x64 | `SecureShellGo-windows-x64.zip` |
| Windows arm64 | `SecureShellGo-windows-arm64.zip` |
| macOS | `SecureShellGo-macos.zip` (containing the `.app`) |

The arm64 builds are native builds for ARM64 Linux and Windows on ARM. The
Linux and Windows builds are made by GitHub Actions on a runner of their own
architecture and started once there to check that they run, but they haven't
seen the testing the Android app has.

macOS builds are unsigned — there's no Apple Developer ID behind this
project — so Gatekeeper will refuse to open the app and call it an
"unidentified developer." Right-click the `.app`, choose **Open**, and
confirm once; after that it launches normally.

### Fedora, openSUSE, Arch, AppImage and Flatpak

Releases from 1.5.1 on also carry these, for x64 (`x86_64`) and arm64
(`aarch64`), all holding the same build as the `linux` archives:

| Distribution | Asset | Install |
|---|---|---|
| Fedora, RHEL | `secureshellgo-<version>-1.x86_64.rpm` | `sudo dnf install ./secureshellgo-<version>-1.x86_64.rpm` |
| openSUSE | the same `.rpm` | `sudo zypper install --allow-unsigned-rpm ./secureshellgo-<version>-1.x86_64.rpm` |
| Arch, Manjaro, EndeavourOS | `secureshellgo-<version>-1-x86_64.pkg.tar.zst` | `sudo pacman -U ./secureshellgo-<version>-1-x86_64.pkg.tar.zst` |
| Any Linux with GTK 3 | `SecureShellGo-<version>-x86_64.AppImage` | `chmod +x SecureShellGo-<version>-x86_64.AppImage && ./SecureShellGo-<version>-x86_64.AppImage` |
| Any Linux with Flatpak | `secureshellgo-<version>-x86_64.flatpak` | `flatpak install --user ./secureshellgo-<version>-x86_64.flatpak` (the GNOME runtime comes from Flathub) |

Replace `x86_64` with `aarch64` on ARM64. The `.rpm` and the Arch package
install the same files as the PPA's `.deb` (`/opt/secureshellgo`, started as
`secureshellgo`, with the AI Bridge launcher as `secureshellgo-mcp`) and
recommend a Secret Service provider the way it does. The
`.rpm` is not signed, hence `--allow-unsigned-rpm` on openSUSE; check the
files against the release page. The builds are made on Ubuntu 24.04 (glibc
2.39), so use a current distribution: Fedora 40 or later, openSUSE
Tumbleweed or current Arch, not RHEL 9 or openSUSE Leap 15; dnf and zypper
refuse the `.rpm` where its glibc is too old. Each release also carries
`secureshellgo-bin-<version>-aur.tar.gz`, the recipe for an AUR
`secureshellgo-bin` package, which is not on the AUR yet. What the Flatpak's
sandbox allows is in [packaging/flatpak/README.md](packaging/flatpak/README.md).

### Install on Ubuntu

SecureShell Go is also published as a native `.deb` package via a Launchpad
PPA:

```bash
sudo add-apt-repository ppa:dhiva-labs/apps
sudo apt update
sudo apt install secureshellgo
```

This tracks the same releases as the desktop `.tar.gz` above, built from the
`debian/` packaging in this repository. The PPA package is amd64 only for now;
on ARM64 use the `linux-arm64` archive above. See `packaging/PPA.md` for how
the package itself is built and uploaded.

### Install via snap

SecureShell Go is also published on the Snap Store, which works on Ubuntu
as well as Fedora, Arch, Manjaro, and any other distro with `snapd`:

```bash
sudo snap install secureshellgo
```

See `packaging/SNAP.md` for how the snap itself is built and published. CI
builds it for amd64 and arm64; the Store listing gets the arm64 build once it
is uploaded.

### Saving passwords and keys on Linux

Credentials are handed to the desktop's own encrypted store (the Secret
Service API — GNOME Keyring or KWallet) and never written anywhere in
plaintext. A keyring this install has used before that is now locked makes
saving fail with a prompt to unlock it, rather than silently downgrading. For
the strongest protection, have one installed and unlocked:

```bash
sudo apt install gnome-keyring
```

The PPA package pulls this in on its own. If you installed a downloaded
`.deb` with `dpkg -i`, it did not — `dpkg` ignores `Recommends`, so
install the file with `apt` instead and the dependency comes along:

```bash
sudo apt install ./secureshellgo_*.deb
```

Snap users need to grant access to the keyring once, because snapd does
not connect this interface automatically:

```bash
sudo snap connect secureshellgo:password-manager-service
```

On a machine that has never had a keyring — a headless box or a minimal
window manager — the app encrypts credentials into its own private file
instead, with a key kept beside it that only your user account can read.
That protects them from other users, not from programs running as you, so
install a keyring where you can.

## AI Bridge (Linux and Windows)

An optional bridge that lets an MCP-compatible AI assistant on your computer
look at your servers by name and, only on servers where you allow it and
with your approval, change them, without ever being given a password, key or
passphrase. It is **off by default**, and it is not available on Android or
macOS.

Set it up:

1. Settings → AI Bridge: switch on **AI Bridge**. The app explains what it
   does and asks you to confirm, every time you switch it on. (The one-click
   route below does this for you, with the same explanation.)
2. Connect an assistant. Three routes; use the first that fits.
   - **One click, for Claude Code (Linux deb, rpm, Arch package, AppImage or
     archive, and Windows).**
     **Connect Claude Code** appears in Settings → AI Bridge only when the
     app finds a file named `claude` on your computer. Finding it runs
     nothing: opening Settings or pressing "Check again" only checks whether
     the file exists on your `PATH`, in `~/.local/bin` or in `~/.claude/local`
     (on Windows, the `PATH` and `%USERPROFILE%\.local\bin\claude.exe`). It is not
     available in the snap or the Flatpak, whose sandboxes cannot start
     programs on your computer (the app does not look there at all); snap and
     Flatpak users take a route below. When you press
     the button, the app runs `claude --version` and `claude plugin
     marketplace list --json` (10 seconds each) to show you the same
     explanation as when switching the bridge on, the full path and version
     of the program and, if the plugin would not come from the published
     GitHub source, where it would be loaded from, with a warning. Those two
     read-only commands change nothing, and Cancel leaves everything as it
     was. Only on **Connect** does anything
     change: the app switches the bridge on if it was off, creates a pairing,
     and runs `claude` to add the plugin source if missing, install the
     plugin, save the token and launcher command, and check that the token
     was saved (90 seconds a step). The token goes to
     `claude` on its standard input only: not on the command line, in an
     environment variable, on screen, in the clipboard or in a log. The
     pairing cannot be used until Claude Code has confirmed the setup, and one
     left behind because the app was closed part way is removed the next time
     the app starts. If any step fails, the pairing it just created is revoked
     and the bridge is put back the way it was before (switched off again if
     this attempt switched it on); if either cannot be saved, the screen says
     so. Afterwards a checklist, **Shared hosts**, lets you
     tick which saved hosts the assistant may read (nothing is ticked that was
     not already shared). The GitHub plugin source only resolves once this
     release is on the default branch of the repository.
   - **Claude Code plugin, by hand.** **Connect an assistant**: name it, choose
     "Claude Code plugin" and paste the one block of three terminal commands it
     shows (add the plugin source, install the plugin, and a third line that
     pipes a small JSON object holding the token, and the launcher path when
     the install needs one, into `claude plugin configure
     secureshellgo@dhiva-labs --values-stdin`). The token is shown once.
     Pasting the third line **puts the token in your shell's history file**
     (the screen says so under the commands); one-click does not. Afterwards you can delete that line from the history,
     or, if the history is shared or synced, revoke the assistant and pair it
     again. (`/plugin configure secureshellgo@dhiva-labs` does the same but is
     typed **inside a Claude Code session, not in a terminal**.)
   - **A config file, for any other client.** Choose the config, VS Code or
     "Other" kind in **Connect an assistant** and paste the snippet. The token
     goes in the environment variable `SSG_BRIDGE_TOKEN`. Ready-made snippets,
     an agent skill and the plugin are in [`integrations/`](integrations/).
3. Choose which servers it may see: tick them in **Shared hosts**
   (Settings → AI Bridge, "Shared hosts — N of M", also shown at the end of
   one-click), or edit a server and switch on **Share with AI assistants**.
   Servers without it are invisible to the assistant. A quick connect that was
   not saved cannot be shared.

The launcher command the app shows depends on how you installed it:

| Install | Launcher command |
| --- | --- |
| deb / PPA, `.rpm`, Arch package, Microsoft Store | `secureshellgo-mcp` |
| Snap | `secureshellgo.mcp` |
| Flatpak | the command Flatpak exports for the app: `/var/lib/flatpak/exports/bin/com.dhivalabs.secure_shell_go` for a system install, `~/.local/share/flatpak/exports/bin/com.dhivalabs.secure_shell_go` (written out in full) for `flatpak install --user` |
| AppImage | the full path of the `.AppImage` file itself |
| Linux tarball, Windows zip | the full path of `secureshellgo-mcp` (`.exe` on Windows) next to the app |

The Flatpak and the AppImage start the launcher instead of the app when they
are run with `SSG_BRIDGE_TOKEN` set and stdin not a terminal, which is how
an assistant starts them, so a single command with no arguments works there
too. `flatpak run --command=secureshellgo-mcp com.dhivalabs.secure_shell_go`
also starts the Flatpak's launcher, for a client that takes arguments. Move
the `.AppImage` file and the command changes with it: pair the assistant
again, or edit its launcher command.

It can list those servers, read server stats, list services, read the end of
a log, list folders, read text files and search for files by name. That is all
it can do on a server you only shared. By default it does not
see a server's address, port or user name (**Show address and username** is
off). Common secret locations (`~/.ssh`, `.env` files, key files, shell
histories, `/etc/shadow`, cloud and registry credential files) are blocked
and simply left out of listings; you can add more under **Extra blocked
paths**. Output is capped at 64 KiB a call with private keys removed, and
every call goes in **Activity**, a log on your computer you can read and
clear. While the app is locked it refuses everything. Switching the bridge
off, or revoking an assistant under **Paired assistants**, stops its calls in
progress on the server.

### Changing a server, with your permission (1.7.0)

1.7.0 adds tools that change a server: `run_command` (one shell command),
`write_file` (one text file), `service_action` (start, stop, restart or reload
a systemd unit) and `run_on_hosts` (one command on 2 to 10 servers), and a
terminal (`open_terminal`, `send_input`, `read_screen`, `close_terminal`).
**All of it is off.** A server you shared stays read-only until you switch on,
for that server, in its edit screen or with the settings button on its row in
**Shared hosts**:

- **Let the assistant request changes.** Off by default. With it on, the
  assistant can ask; nothing happens until you answer, except the two things
  you can set up beforehand (allowed commands and "Allow for a while", below).
  Switching it on asks you to confirm and lists any allowed commands that
  will come into force.
- **Allowed commands**, beneath it: commands that run on that server
  **without asking you**, when the assistant asks `run_command` for exactly
  that text on that one server (compared character for character after
  trimming white space at the ends: nothing partial, no patterns, never for
  `run_on_hosts`). Add only commands you always want run. Each is shown in
  full. An entry is refused if it holds a line break, a control character, a
  space that is not a plain space, a character that changes the reading
  direction, an invisible or other format character, a private-use or
  unassigned code point, or a combining mark that can hide or change the
  character before it (any on a plain ASCII character, the general accent,
  overlay and enclosing marks wherever they are, and a third mark in a row),
  because the text you see might not be what runs. At most 50, each at most
  4096 characters.
- **Full control terminal**, beneath it, off by default. Switching it on asks
  you to confirm. See below.

Turning a server back to read-only, or un-sharing it, keeps the list and the
terminal switch stored but inert. Switching changes on again brings them back
into force, so the confirmation lists the commands again, and if the terminal
switch was on you are asked to confirm the terminal again too (Cancel leaves
it off).

**How an approval looks.** A card appears over whatever you are doing in
SecureShell Go, one at a time, with how many are waiting. It says which
assistant asked, for which server, and what will happen: "Run this command?",
"Create this file?", "Replace this file?", "Change a service?" or "Open a
terminal for the assistant?". The command is shown in full, exactly as the
shell will receive it, with line breaks, control characters, characters that
change the reading direction, invisible and other format characters,
look-alike spaces, private-use and unassigned code points and combining marks
that could hide a character made visible (`\n`, `\x1b`, `[U+202E]`,
`[U+0301]`) and explained in a legend under it. The same string is shown,
matched against the allowed list and run. For a file it shows the path, the
size, whether it replaces a file and a preview or a diff; when the preview is
not the whole change, a warning at the top of the card says so. The buttons
are **Deny**, **Allow once** and, only if you turned it on, **Allow for N
minutes**. Deny has the focus, so Enter and Space deny; the Allow buttons stay
disabled for a second after a card appears; Escape or Back denies; a click
beside the card does nothing. Not answering for 2 minutes is a no. Locking
the app takes waiting cards away (they count as withdrawn), and a locked app
shows no card and refuses.

**The card does not alert you.** It does not flash the window, make a sound
or ask for attention. If SecureShell Go is minimised or behind other windows
when an assistant asks, you will not see the card, and after 2 minutes the
change is denied. Keep the app in view while you expect a change.

**Allow for a while.** Settings → AI Bridge → **Allow for a while** is Off, 5,
15 or 60 minutes (off by default). Only when it is on does the card offer the
extra button. Pressing it lets that assistant make any change on that server
with any of the four change tools, not just the one on the card, without
asking you again until the time runs out (for `run_on_hosts`, only when it
holds one for every server named). It is kept in memory only, and ends when
the time does, when you press **Stop now** under **Approvals in force**, when
you switch **Allow for a while** off, when the bridge is switched off, the
assistant is revoked, the app locks, the app restarts, or the server is
deleted, un-shared, stepped down or edited so that it points elsewhere (its
address, port, user name, connection type, or which jump host it goes
through). Choosing a different length leaves approvals already given as they
are. It never covers a terminal.

**The terminal.** With **Full control terminal** on for a server, the
assistant can ask to open a terminal there. You get a card every time, and
it says: "An approved terminal gives the AI assistant a live shell as the
saved sign-in user on this host. It can type any command, including ones you
never see on a card, read any file that user can read, and reach anything this
host can reach, with no further questions. The blocked-path list does not
apply inside a terminal. You can watch it, take over by typing, or stop it at
any time." It is the one way an assistant can do what none of the other
tools allow: interactive programs, any command without a card for each, and
any file the sign-in user can read. It opens as a session tab with a banner
(**Take over**, **Stop**); typing in it, or **Take over**, gives you the
keyboard, after which the assistant can no longer type or read and the
session stays open as yours. At most 2 assistant terminals are open at once,
and one with no input or reads for 10 minutes is closed. Stop, closing its
tab, switching the bridge off, a lock, revoking the assistant, or deleting
the server, un-sharing it, stepping it down, switching its terminal off or
pointing it elsewhere closes one the assistant still drives (one you took
over stays open, except that Stop and closing its tab close it too);
so does the connection dropping or its shell exiting. It uses a connection
of its own that never carries your SSH agent or X11 windows, it is always the
plain login shell (no tmux or screen session, so it cannot attach to one you
left running, and never Mosh), and the server's startup command is not typed
into it. Everything the assistant types is in **Activity** (secrets removed,
cut to 500 characters); what the screen showed is not.

Every change is recorded in **Activity** with how it was allowed (an allowed
command, a timed approval, once, for a while, denied, timed out, withdrawn),
and a change you approved that was then refused before it ran says "Approved,
but not run". File contents and output are never recorded (an error message
can quote a short error the server gave). Backups never carry any of these
settings: an imported server has all of them off.

No connection the bridge makes carries your SSH agent or X11 forwarding. A
bridge call uses the session you already have open to that server only when
neither that session nor the server forwards the agent or X11; otherwise it
signs in on a connection of its own.

The app never prompts for a bridge call: a server that needs a person to sign
in (a locked vault, an unsaved passphrase, a login question, an unchecked
host key) fails with a message asking you to connect to it once in the app.
Prompts from outside the app can still appear: an SSH agent that asks you to
confirm or touch a key, or your desktop keyring's own unlock dialog.

A pairing or an AI-access change that cannot be written to disk is undone
and reported, so what the app shows always matches what is stored; a revoke
that cannot be saved says the pairing still works.

Backups never carry AI access or bridge settings: an imported server always
has AI access off (and no allowed commands and no terminal), and importing
keeps this computer's own bridge settings.

Limits, plainly:

- **What the assistant reads is sent by your AI client to its own provider.**
  SecureShell Go and Dhiva Labs receive nothing, but your AI provider does.
- **The blocked-path list is a default set, not a guarantee** that no secret
  on a server can be read. For a hard guarantee, use a server account with
  limited read rights.
- **Text on a server can contain instructions aimed at the assistant**, in a
  log line, a file, a command's output or a terminal screen. Treat what an
  assistant does after reading untrusted text with care: the card is what
  stops a change you did not intend, so read it.
- **Allowed commands and "Allow for a while" skip the card.** That is what
  they are for. Use them only for commands and servers you are sure of.
- **An approved terminal can do anything the sign-in user can**, with no
  further question, and the blocked-path list does not apply inside it (or to
  commands). What the assistant's screen shows is sent to your AI provider;
  only private-key blocks and secrets the app knows are removed from it, so a
  key can still be read in pieces or encoded.
- **The approval card does not alert you.** If the app is in the background
  you will not notice it, and it is denied after 2 minutes.
- **A stopped command is stopped, with caveats.** Its process group gets TERM,
  then KILL 3 seconds later (on a server without `setsid`, only its main
  process), but a program that moved itself into a session of its own
  survives. A change can time out while waiting for a free slot, after you
  approved it.
- **A replaced file keeps its permissions and nothing else** (owner, access
  lists and other hard links are not kept), and a change to a file made in the
  same second with the same size after you were asked is not noticed.
- **Changes need `/bin/sh` on the server.** Nothing of 1.7.0 has run on
  Windows yet. Commands are quoted so that fish as a login shell reads them as
  written, but that has not been run against a real fish. The bridge is not
  on macOS or Android.
- **The translations of the new 1.7.0 text were machine-written** and have
  not been read by native speakers; the English text is the reference.
- **The token in the assistant's configuration is a key to your shared
  servers** while the app runs with the bridge on and unlocked: whoever has it
  can read, ask for changes, and use the allowed commands and any approval
  for a while you gave that assistant. Revoke the assistant if it leaks.

How it is built: [ARCHITECTURE.md](ARCHITECTURE.md#ai-bridge).

## Privacy

SecureShell Go collects nothing: no analytics, no ads, no account, no update
check, and no Dhiva Labs server for anything to be sent to. Credentials stay
on the device in the platform's protected storage, and the only hosts the app
connects to are the ones you configure. The optional AI Bridge (Linux and
Windows) gives what an assistant reads, and what its commands and terminal
print, to that assistant on your computer, which sends it to its own
provider; Dhiva Labs receives nothing. If you press
**Connect Claude Code**, the app runs the `claude` program you installed, at
your request, and hands it the pairing token; nothing goes to Dhiva Labs. Full text: [Privacy policy](docs/privacy-policy.md).

## Build from source

```bash
flutter pub get
flutter build apk --release
```

Run the checks CI runs (Flutter 3.44.6 is what the workflows pin):

```bash
flutter analyze
flutter test
```

Remote desktop carries CrossShell's agents in `assets/agents/`, packed and
committed, with their hashes pinned in `assets/agents/manifest.json`. To move to
a new [CrossShell](https://github.com/Dhiva-Labs/CrossShell) release, download
its `crossshell-host-*` assets and `crossshell-host-SHA256SUMS` (renamed to
`SHA256SUMS`) into one folder and stage them; every file is checked against the
sums first:

```bash
tool/stage_agents.sh path/to/that/folder
```

Release builds are signed with the upload key named in
`android/key.properties`, which is gitignored along with the keystore itself.
Without that file the build still succeeds, falling back to the debug key with
a warning — runnable, but not uploadable to Google Play.

Built with Flutter. No third-party platform plugins for storage, wakelock, or
the foreground service — small, auditable Kotlin channels instead.

## Sponsors

Dhiva Labs is an independent, self-funded lab. [Sponsorships](https://github.com/sponsors/Dhiva-Labs) help bring this project and the rest of Dhiva Labs to every platform, iPhone and Mac included.

[![Sponsor Dhiva Labs](https://img.shields.io/badge/Sponsor-Dhiva%20Labs-ea4aaa?logo=githubsponsors&logoColor=white)](https://github.com/sponsors/Dhiva-Labs)

Monthly sponsors at $10 and up are listed here:

<!-- sponsors -->
*Be the first: [sponsor Dhiva Labs](https://github.com/sponsors/Dhiva-Labs).*
<!-- sponsors -->

## Licence

MIT
