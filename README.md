# SecureShell Go

[![ARM64 builds](https://github.com/Dhiva-Labs/SecureShellGo/actions/workflows/desktop-builds.yml/badge.svg?branch=main)](https://github.com/Dhiva-Labs/SecureShellGo/actions/workflows/desktop-builds.yml)
![Linux x64 | arm64](https://img.shields.io/badge/Linux-x64%20%7C%20arm64-informational?logo=linux&logoColor=white)
![Windows x64 | arm64](https://img.shields.io/badge/Windows-x64%20%7C%20arm64-informational?logo=windows&logoColor=white)

A fast, security-first SSH terminal and SFTP client for Android, Windows and
Linux. Connect to your servers, run a real interactive shell, edit and transfer
files — with strict host-key verification at the core. In English, Simplified
Chinese, Japanese, Brazilian Portuguese, Spanish, Russian, German, Korean and
French.

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
  (Linux, or Windows with an X server such as VcXsrv or X410).
- **Macs** through their built-in Screen Sharing, over the same tunnel.
- Mouse, keyboard and clipboard; on touch screens a trackpad mode and a
  direct mode, and a key bar with Ctrl, Alt, Super and Ctrl+Alt+Del.
- Nothing runs on a server until you open a remote desktop on it. The agents
  add about 4.5 MB to the app, and older ones the app left behind are
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

## Privacy

SecureShell Go collects nothing: no analytics, no ads, no account, no update
check, and no Dhiva Labs server for anything to be sent to. Credentials stay
on the device in the platform's protected storage, and the only hosts the app
connects to are the ones you configure. Full text: [Privacy policy](docs/privacy-policy.md).

## Build from source

```bash
flutter pub get
flutter build apk --release
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

## Licence

MIT
