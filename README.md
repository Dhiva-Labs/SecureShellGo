# SecureShell Go

A fast, security-first SSH terminal and SFTP client for Android. Connect to your
Linux servers, run a real interactive shell, and transfer files — with strict
host-key verification at the core.

## Features

### Terminal
- Full xterm-256color terminal (powered by `dartssh2` + `xterm`) with colors,
  resize handling, and scrollback
- Extra-keys bar: Esc, Tab, Ctrl (sticky), arrows with long-press repeat,
  `^C ^D ^Z ^L ^R`, pipe/slash/tilde — all 48 dp touch targets with haptics
- Pinch-to-zoom font size, five colour schemes (Solarized Dark, Monokai,
  retro green-phosphor, black-on-white, default)
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
- The trust store is sealed with an HMAC whose key lives in the Android
  Keystore — a tampered or stripped store fails closed and warns you
- Passwords, private keys, and passphrases are stored only in
  Keystore-encrypted secure storage, never in plain text

### Connections
- Saved host manager: one-tap connect, last-connected timestamps,
  quick-connect without saving
- Password and private-key auth (OpenSSH, PKCS#1 RSA, ECDSA; passphrase
  support) — import `.pem` key files directly, including AWS EC2 keys
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
- Command snippets with `{placeholder}` prompts, per-host startup commands,
  and ten terminal colour schemes

### Connections that stay up
- Automatic reconnection with keep-alive: a dropped network or a laptop
  waking from sleep restores the shell in the same tab, and a changed host
  key aborts rather than reconnecting quietly
- **Jump hosts** (`ProxyJump`): reach a server through a bastion, with both
  hops verified against known-hosts independently
- **Tunnel manager**: saved local, remote and dynamic (SOCKS5) port forwards
  with live byte counters, bound to loopback unless you say otherwise
- Generate an ed25519 key in the app and install it on a server, and review
  or forget trusted host keys from Settings

### Editing and monitoring
- **Built-in remote editor**: syntax highlighting for thirteen languages,
  tabs, find and replace, and a save that re-checks the file first and
  publishes through a verified temporary file, keeping the original's
  permissions
- Per-host path bookmarks and one transfer panel across every open session
- Server stats (load, memory, disk, uptime), a live log viewer with filtering
  and severity highlighting, and a systemd service and process manager

### Locked down
- Optional app lock behind your device's own authentication (Android)
- **Encrypted backup**: export hosts, groups, settings, snippets, tunnels and
  bookmarks to one passphrase-protected file — Argon2id and AES-256-GCM, with
  saved passwords included only if you explicitly ask

### Every screen size
- Material 3 window-size-class layouts: side-by-side terminal + file browser
  on tablets, Samsung DeX, and unfolded foldables; host grid on wide screens
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
`.tar.gz` for Linux, `.zip` for Windows, and `.zip` for macOS (containing
the `.app`). They're built by GitHub Actions and haven't seen the testing
the Android app has.

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
`debian/` packaging in this repository. See `packaging/PPA.md` for how the
package itself is built and uploaded.

### Install via snap

SecureShell Go is also published on the Snap Store, which works on Ubuntu
as well as Fedora, Arch, Manjaro, and any other distro with `snapd`:

```bash
sudo snap install secureshellgo
```

See `packaging/SNAP.md` for how the snap itself is built and published.

## Privacy

SecureShell Go collects nothing: no analytics, no ads, no account, and no
Dhiva Labs server for anything to be sent to. Credentials stay on the device
in the Android Keystore, and the only hosts the app connects to are the ones
you configure. Full text: [Privacy policy](docs/privacy-policy.md).

## Build from source

```bash
flutter pub get
flutter build apk --release
```

Release builds are signed with the upload key named in
`android/key.properties`, which is gitignored along with the keystore itself.
Without that file the build still succeeds, falling back to the debug key with
a warning — runnable, but not uploadable to Google Play.

Built with Flutter. No third-party platform plugins for storage, wakelock, or
the foreground service — small, auditable Kotlin channels instead.

## Licence

MIT
