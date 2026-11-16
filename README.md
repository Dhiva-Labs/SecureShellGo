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

Latest release: **1.8.0**. Install options for each platform are
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

- Version 1.8.0. The Android app is in testing and is distributed as an APK on
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

### AI assistants, only where you allow it
- **Let an AI assistant look at your servers, and, if you choose, work on
  them.** Each server has one level: off, read only, ask before each change,
  or full control. Changes, long-running jobs, terminals and a server's
  desktop each need your yes on a card in the app, unless you gave that
  server full control. Off by default. See [AI Bridge and the built-in
  assistant](#ai-bridge-and-the-built-in-assistant).
- **A built-in assistant on every platform, Android included**, that uses
  your own API key (Anthropic, or any service that speaks the OpenAI chat
  format).
- **Answer the approval cards from your phone**, away from the desk.

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

## AI Bridge and the built-in assistant

Optional. Lets an AI assistant look at your servers by name and, only on
servers where you allow it, work on them, without ever being given a password,
key or passphrase. **Everything here is off by default**, and nothing happens
until you switch it on. There are three parts, and they work on different
platforms:

| Part | What it is | Where |
| --- | --- | --- |
| **Assistants on this computer** | An MCP-compatible assistant you run on the computer (Claude Code, an editor's AI, any MCP client) reaches your servers through this app, via the `secureshellgo-mcp` launcher. You pair it with a token. | Linux and Windows (the app and the launcher). Not Android, not macOS. |
| **Built-in assistant** | A chat inside the app that uses your own API key and the same tools, levels, cards and activity log. | Every platform, Android and macOS included. |
| **Phone control** | Your phone shows the computer's approval cards and lets you answer them, and stop what an assistant holds open. | The computer needs the Linux or Windows app, and an SSH login from the phone. The phone can be any platform. |

The per-server access level (below), the approval cards, "Allow for a while"
and the activity log are the same for all three, and exist on every platform.

### Access levels, per server

Edit a server and choose one level under **AI access**, or tap its row in
Settings → AI Bridge → **Shared hosts** to set it in a small sheet. The list
shows each server's level as a chip. Nothing takes effect until you save the
host.

| Level | What an assistant can do there |
| --- | --- |
| **Off** (the default) | Nothing. The server is invisible to it. |
| **Read only** | Look: stats, services, logs, folders, files, search by name. Change nothing. |
| **Ask before each change** | Ask to run commands, write files, manage services and start jobs. **Each one needs your yes on a card.** Beneath it: tick **May ask for a terminal** and **May ask for the desktop** (each still needs a card every time), and, under **Advanced**, list commands that run without asking. |
| **Full control** | Change the server, open terminals and the desktop **without asking you**. No card appears. |

A line under the choice says in plain words what your pick means. Choosing
**Full control** shows a warning that says there will be no cards and how to
take it back (choose another level and save), and you must press **Give full
control**; Cancel is the button that has the focus. Going up to **Ask before
each change** asks again and lists the commands that will run without asking.
Going down never asks. A server at full control needs no allowed-commands list
and no ticks: terminal and desktop are on. The audit log records "Allowed: host
set to full control" for each call let through that way. An app lock and a
switched-off bridge still refuse everything, full control included.

### Assistants on this computer (Linux and Windows)

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
3. Choose what it may do on each server: open **Shared hosts** (Settings → AI
   Bridge, "Shared hosts — N of M", also shown at the end of one-click) and
   tap a server, or edit the server and use **AI access** (see "Access levels"
   above). Servers left at **Off** are invisible to the assistant. The tick
   in the one-click checklist shares a server read only. A quick connect that
   was not saved cannot be shared.

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

### What an assistant can do on a server

**Looking** needs a level of Read only or higher. It can list the servers it
may use, read server stats, list services, read the end of a log, list
folders, read text files and search for files by name. By default it does not
see a server's address, port or user name (**Show address and username** is
off). Common secret locations (`~/.ssh`, `.env` files, key files, shell
histories, `/etc/shadow`, cloud and registry credential files) are blocked and
simply left out of listings; you can add more under **Extra blocked paths**.
Output is capped at 64 KiB a call with private keys removed, and every call
goes in **Activity**, a log on your computer you can read and clear.

**Changing** needs **Ask before each change** or **Full control**:

- `run_command` runs one shell command, `write_file` writes one text file,
  `service_action` starts, stops, restarts or reloads a systemd unit, and
  `run_on_hosts` runs one command on 2 to 10 servers.
- `start_job` starts a long-running command (see "Jobs" below).
- A terminal (`open_terminal`, `send_input`, `read_screen`, `close_terminal`)
  needs **May ask for a terminal**, or full control.
- A desktop (`open_desktop` and the `desktop_*` tools) needs **May ask for the
  desktop**, or full control.

**All of it is off.** A server you shared stays read-only until you choose a
level above Read only for it. At **Ask before each change**:

- Nothing happens until you answer, except the two things you can set up
  beforehand (allowed commands and "Allow for a while", below).
- **Allowed commands**, under **Advanced**: commands that run on that server
  **without asking you**, when the assistant asks `run_command` for exactly
  that text on that one server (compared character for character after
  trimming white space at the ends: nothing partial, no patterns, never for
  `run_on_hosts`, never for a job). Add only commands you always want run.
  Each is shown in full. An entry is refused if it holds a line break, a
  control character, a space that is not a plain space, a character that
  changes the reading direction, an invisible or other format character, a
  private-use or unassigned code point, or a combining mark that can hide or
  change the character before it (any on a plain ASCII character, the general
  accent, overlay and enclosing marks wherever they are, and a third mark in
  a row), because the text you see might not be what runs. At most 50, each
  at most 4096 characters.
- **May ask for a terminal** and **May ask for the desktop**: off by default.
  Ticking one asks you to confirm.

Taking a server down a level, or to Off, keeps the list and the ticks stored
but unused. Going back up brings them back into force, so the confirmation
lists the commands again, and any terminal or desktop tick that comes back is
asked about again (Cancel leaves it off).

**How an approval looks.** A card appears over whatever you are doing in
SecureShell Go, one at a time, with how many are waiting. It says which
assistant asked, for which server, and what will happen: "Run this command?",
"Create this file?", "Replace this file?", "Change a service?", "Start this
job?", "Open a terminal for the assistant?" or "Open a desktop for the
assistant?". The command is shown in full, exactly as the
shell will receive it, with line breaks, control characters, characters that
change the reading direction, invisible and other format characters,
look-alike spaces, private-use and unassigned code points and combining marks
that could hide a character made visible (`\n`, `\x1b`, `[U+202E]`,
`[U+0301]`) and explained in a legend under it. The same string is shown,
matched against the allowed list and run. For a file it shows the path, the
size, whether it replaces a file and a preview or a diff; when the preview is
not the whole change, a warning at the top of the card says so. For a job it
shows the command, the folder and the name, and says the job keeps running on
the server after the connection and the app close. The same card also appears
over the built-in assistant's chat, and on your phone when Phone control is on. The buttons
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
with any of the change tools (including `start_job`), not just the one on the card, without
asking you again until the time runs out (for `run_on_hosts`, only when it
holds one for every server named). It is kept in memory only, and ends when
the time does, when you press **Stop now** under **Approvals in force**, when
you switch **Allow for a while** off, when the bridge is switched off, the
assistant is revoked, the app locks, the app restarts, or the server is
deleted, un-shared, stepped down or edited so that it points elsewhere (its
address, port, user name, connection type, or which jump host it goes
through). Choosing a different length leaves approvals already given as they
are. It never covers a terminal or a desktop.

**The terminal.** With **May ask for a terminal** ticked for a server, the
assistant can ask to open a terminal there. You get a card every time (on a
full-control server, none), and it says: "An approved terminal gives the AI assistant a live shell as the
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

**Full control.** A server at **Full control** lets assistants change it, open
terminals and open its desktop **with no card and no yes from you**. It exists
for a server you would hand over completely, such as a throwaway test machine.
What stops a mistake there is the assistant's own care and your choice of
server; nothing in the app does. Every command still runs as the saved sign-in
user, every call is in **Activity** ("Allowed: host set to full control"), and
you can still watch and Stop a terminal or desktop, and stop a job on the
server. Phone control and "Allow for a while" have nothing to answer for such
a server. The built-in assistant and paired assistants are treated the same.

**Jobs.** `start_job` runs a command that must outlive the call: a dev server,
a build, a watcher. It runs detached on the server with the account's login
shell, no input and no terminal, writes its output to a log, and keeps going
after the call, the connection and the app have closed. Starting one shows a
card with the command, the folder and the name (none at full control, or while
a timed approval is in force; an allowed command never starts a job). The
assistant follows its own jobs with `list_jobs`, `job_status` and `job_output`
(the newest 64 KB of the log, with secrets hidden like other output), stops
one with `stop_job` (TERM to the job's whole process group, KILL 3 seconds
later if anything is left) and deletes an ended one with `remove_job`. It
only ever sees and controls the jobs it started, at most 20 per server. On the
server a job lives in `~/.cache/secureshellgo/jobs/<id>/`, readable only by
your account (its command, log, process id and exit status). The app
remembers which assistant started which job in `bridge_jobs.json` in its
bridge folder, which is never part of a backup. Taking a server below **Ask
before each change** leaves its jobs running (they are your server's
processes); the assistant can still read them while reading is allowed but
can no longer stop or remove them. Deleting a server, pointing it elsewhere or
removing a paired assistant makes the app forget those jobs; they keep running
on the server until they end or you stop them there. **There is no screen in
the app that lists or stops a job**: use `kill` on the server, or ask the
assistant. Jobs need `/bin/sh` on the server. Without `setsid` the stop
reaches only the job's main process.

**The desktop.** With **May ask for the desktop** ticked, or full control, an
assistant can ask to see and use the screen of whoever is signed in on that
server (`open_desktop`). It is opened the way **Remote desktop → This
desktop** opens it, over a connection of its own that never carries your SSH
agent or X11 forwarding, so it works where that does: GNOME on Wayland, X11
desktops and Windows; not a Mac, not a headless server, not another user's
desktop. It opens in a viewer you watch live, with a banner (**Take over**,
**Stop**). The card says: it can see the screen and use the mouse and
keyboard as the signed-in user, and may see passwords and messages shown
there. Once open, the assistant takes screenshots (PNG, scaled to at most
1280 pixels on the longest side, the mouse pointer not drawn), clicks, moves
the mouse, scrolls, types text (US keyboard characters, up to 2000 per call)
and presses keys from a fixed list such as Enter, Tab, Escape, Ctrl+C and
Alt+F4, with no further card. Coordinates are screenshot pixels, mapped back to
the real screen. "Allow for a while" never covers a desktop. **One assistant
desktop is open at a time**, across all assistants. It closes when you take
over, press Stop or close the viewer, after 10 minutes without use, when the
server's access drops below the desktop or points at another machine, when the
assistant is disconnected, when the bridge is switched off, or when the app
locks. What the assistant types is never written to **Activity**, only how
many characters it was, since it may be a password. A screenshot goes to the
assistant, and from there to its provider as an image.

Every change is recorded in **Activity** with how it was allowed (an allowed
command, a timed approval, full control, once, for a while, denied, timed out,
withdrawn, and, when you answered on your phone, which phone),
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
has AI access off (and no allowed commands, no terminal or desktop tick), and
importing keeps this computer's own bridge settings. The built-in assistant's
switch and service settings, the API key, the phone pairings and the phone's
saved token are never in a backup either.

### The built-in assistant (every platform)

A chat inside the app, for people who do not run an assistant on their
computer, or who are on a phone. It talks to an AI service with **your own API
key** and uses the same tools, access levels, approval cards, "Allow for a
while" and activity log as an assistant you pair. It appears in the activity
log as "Built-in assistant". It is off until you switch it on.

Set it up:

1. Settings → AI Bridge → **Built-in assistant**: switch on **Use the
   built-in assistant**. The app explains that what you type, what the
   assistant reads from your servers and what its tools return are sent to the
   AI service you choose, and asks you to confirm every time you switch it on.
2. Choose the **Provider**: **Anthropic**, or **OpenAI-compatible** (any
   service that speaks the OpenAI chat completions format, including a model
   server on your own computer). Enter the **Model** name from your provider.
   For OpenAI-compatible, enter the **Address**, such as
   `https://api.openai.com/v1`; for Anthropic, leave it empty to use
   Anthropic's own address.
3. Paste your **API key** and press **Save key**. It is stored on this device
   in the system's protected storage, like saved passwords. It is never shown
   again, never in `settings.json`, never in a backup, never in a log or the
   activity log. A model server on this computer may need no key.
4. Choose what it may reach: it only reaches servers you gave AI access, at the
   level you chose for each (see "Access levels"). The chat says so when no
   server has any.
5. Open the chat from the **Assistant** button in the app bar of the host list
   (it shows only while the assistant is on). **New chat** starts over;
   **Stop** ends the request and the tool it is running.

How it behaves, plainly:

- It only talks to an `https` address, or to a server on this computer
  (`localhost`); anything else is refused with a message, so your key and the
  conversation are never sent unencrypted. **On Android a local model server
  does not work**: the app does not allow unencrypted traffic, and `localhost`
  would be the phone itself. Use an `https` address.
- A message may start at most 40 tool calls; then it stops and says so. What a
  tool returns is cut to 16 KiB before it is sent to the service.
- A change still needs your yes on a card, shown over the chat, unless the
  server is at full control. Keep the app in the foreground while it works:
  there is no notification, and a request that Android or the system pauses
  in the background can fail.
- The conversation is kept in memory only. Nothing you or the assistant say is
  written to disk, and it is gone when the app closes.
- The built-in assistant has its own switch. The AI Bridge switch on this page
  is for assistants on this computer and does not turn it on or off; the app
  lock and a server's level apply to it as to any other.
- **Desktop screenshots only work with Anthropic.** The OpenAI-compatible
  connection carries text only, so the assistant is told an image came back
  and cannot see it; it can open and click a desktop but not look at it.
- The replies are not streamed: the answer appears when it is complete. A
  request waits up to 120 seconds, and Anthropic replies are capped at 4096
  tokens.

### Phone control

Your phone can answer the computer's approval cards for you, away from the
desk. Both sides are off by default. The computer needs the Linux or Windows
app with the AI Bridge on (that is where the assistants run). The phone is any
device with the app, and logs in to the computer over SSH like any server.

On the computer:

1. Settings → AI Bridge: switch on **AI Bridge**, then, under **Phone
   control**, switch on **Answer approval cards from your phone** (the app
   explains what a paired phone can see and do, every time you switch it on).
2. Press **Pair a phone**, give it a name and copy the token. It is shown once.

On the phone:

1. Save the computer as a host (its address, and a user name and sign-in that
   work over SSH). Phone control logs in with what is saved, with nobody to
   ask, so a host that needs a typed password or code every time does not work.
2. Open the host's menu and choose **AI approvals on this computer**. The
   first time, paste the token. It is kept in the phone's protected storage,
   never in a backup, and it goes to the computer on the first line of a
   command's input, never on a command line or in the environment.
3. The **AI approvals** screen shows each waiting card exactly as the
   computer does (hidden and look-alike characters made visible the same way,
   the host's name as the assistant knows it, never its address or user name).
   You can **Deny**, **Allow once**, or **Allow for N minutes** when "Allow for
   a while" is on at the computer (never for a terminal or a desktop). It also
   lists the live timed approvals, the assistants' terminals and desktops, and
   recent activity, and can stop an approval, a terminal or a desktop. The
   computer runs exactly the same checks after your answer as after a tap on
   its own card, and records in **Activity** that it came from a phone, and
   which one.

It only works while that screen is open on the phone: leave it and nothing is
listening, so a card that waits two minutes is denied. How it works: the phone
runs `secureshellgo-mcp control` on the computer over an SSH command. It looks
for the launcher on the `PATH`, as the snap's `secureshellgo.mcp`, in
`/opt/secureshellgo/`, or as the Flatpak's launcher, and says so if it finds
none or finds a version older than 1.8.0. A launcher in a folder of its own (a
tarball unpacked elsewhere, an AppImage) is not found. The launcher only
carries messages; the app on the computer decides everything.

What a phone can and cannot do: it can answer cards and stop approvals,
terminals and desktops. It can never call a tool, pair anything, change a
setting or a server's access level: its pairing is a different kind from an
assistant's, and neither can act as the other. With **Phone control** off, a
phone is refused exactly like an unknown pairing. Removing a phone's pairing,
switching Phone control off or switching the AI Bridge off ends a connected
phone's session at once. While the app on the computer is locked, a connected
phone sees nothing and can do nothing. At most two phones are connected at
once. A card that waits 2 minutes is denied whether or not the phone saw it.
Phone pairings and the phone's saved token are never part of a backup. **Not
tested on a Windows computer**: the phone's command is a POSIX `sh` script, so
the computer's SSH login shell must be able to run it.

Limits, plainly:

- **What the assistant reads is sent to an AI provider.** For an assistant
  you pair, your AI client sends it to its own provider. For the built-in
  assistant, this app sends what you type, what it reads from your servers,
  what its tools return and, for a desktop, screenshots, straight from your
  device to the service you configured, with your key. SecureShell Go and
  Dhiva Labs receive nothing, but your AI provider does.
- **The blocked-path list is a default set, not a guarantee** that no secret
  on a server can be read. For a hard guarantee, use a server account with
  limited read rights.
- **Text on a server can contain instructions aimed at the assistant**, in a
  log line, a file, a command's output or a terminal screen. Treat what an
  assistant does after reading untrusted text with care: the card is what
  stops a change you did not intend, so read it.
- **Allowed commands, "Allow for a while" and Full control skip the card.**
  That is what they are for. Use them only for commands and servers you are
  sure of. At full control the assistant's own care is the only check, and a
  prompt-injected or mistaken assistant can do anything the sign-in user can.
- **An approved terminal or desktop can do anything the sign-in user can**,
  with no further question, and the blocked-path list does not apply inside
  it, to commands or to jobs. A desktop also shows everything on the screen. What the assistant's screen shows is sent to your AI provider;
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
- **A job outlives everything.** It keeps running on the server after the
  assistant, the connection and the app are gone, and the app has no screen
  to list or stop jobs. Its log may hold anything the command printed.
- **Changes and jobs need `/bin/sh` on the server.** Nothing new in 1.8.0
  has run on Windows yet, and a Windows server is not supported for changes.
  Commands are quoted so that fish as a login shell reads them as written, but
  that has not been run against a real fish.
- **Platforms.** Pairing an assistant needs the local channel, which exists
  only on Linux and Windows. The built-in assistant, per-host access, the
  cards and the activity log work on every platform. A local model server
  does not work on Android. The assistant desktop has not been run on Windows
  or against every desktop; the checklist for 1.8.0 lists what is unproven.
- **The translations of the new 1.7.0 and 1.8.0 text were machine-written**
  and have not been read by native speakers; the English text is the
  reference.
- **The token in the assistant's configuration is a key to your shared
  servers** while the app runs with the bridge on and unlocked: whoever has it
  can read, ask for changes, use the allowed commands and any approval for a
  while you gave that assistant, and, on a full-control server, change it at
  will. Revoke the assistant if it leaks. A phone's token can answer your
  approval cards while Phone control is on: revoke it from Settings if the
  phone is lost.

How it is built: [ARCHITECTURE.md](ARCHITECTURE.md#ai-bridge).

## Privacy

SecureShell Go collects nothing: no analytics, no ads, no account, no update
check, and no Dhiva Labs server for anything to be sent to. Credentials stay
on the device in the platform's protected storage, and the only hosts the app
connects to are the ones you configure. The optional AI features give what an
assistant reads, and what its commands, terminal, jobs and desktop show, to
that assistant: on Linux and Windows, an assistant on your computer, which
sends it to its own provider; in the built-in assistant (any platform), this
app sends it straight to the AI service you configured, with your own key.
Dhiva Labs receives nothing. If you press
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
