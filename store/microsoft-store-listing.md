# Microsoft Store listing copy — SecureShell Go 1.5.0

The Partner Center Store listing (English) for the first Microsoft Store
release. Every claim was checked against the code on `release/1.5.0`: `lib/`,
`windows/runner/`, `pubspec.yaml` and `docs/changes/*.md`. The verification
notes at the end say where each one comes from. Field limits are from
Microsoft Learn, "Add and edit Store listing info for MSIX app". Microsoft
asks for plain text with no HTML and no URLs in the description; links go in
the support fields.

---

## Product name

```
SecureShell Go
```
Must match the name reserved in Partner Center, and the package's display
name (`msix_config: display_name` in `pubspec.yaml`, still being set up).

---

## Short description
*(Optional. Limit 1000 characters; Microsoft recommends under 270. This is 216.)*

```
An SSH and Mosh terminal with an SFTP file browser, for servers you run. Host keys are checked the way OpenSSH checks them, sign-in can use your SSH agent or Pageant, and there is no account, no ads and no analytics.
```

---

## Description
*(Required. Limit 10,000 characters. This is 5,839.)*

```
SecureShell Go is an SSH terminal and SFTP file client for servers you run. It checks host keys the way OpenSSH does, signs in with your SSH agent or Pageant if you want it to, and keeps what it stores on this PC. There is no account, no advertising and no analytics. The app connects only to the servers you add, and to your own SSH agent or X server when you switch those on.

The same app is on Android, and an encrypted backup made on one can be imported on the other.

TERMINAL
• xterm-256color terminal with ten colour schemes and a bundled JetBrains Mono font
• Ctrl+Shift+C and Ctrl+Shift+V to copy and paste, Ctrl+= and Ctrl+− to zoom, and a right-click menu
• Ctrl+Shift+F searches the whole scrollback, with match case and regular expressions
• Ctrl+click a web address to open it in your browser. Only http and https addresses open
• Record a session log to a file you choose, as plain text or exactly as received
• A "Paste N lines?" check before a multi-line paste reaches the shell
• Split the terminal area into up to four panes, each on a different server. Broadcast input types into every visible pane at once; it is off by default and turns itself off when the split closes

SESSIONS THAT STAY UP
• A dead connection is noticed and reconnected, including after the PC wakes from sleep or moves to another network
• When the shell exits but the connection is fine, Restart opens a new shell in the same tab without signing in again
• Keep a host's shell in tmux or GNU screen, so a reconnect, or reopening the app, lands back in the same shell
• Mosh: the app starts mosh-server over SSH and runs the terminal over UDP, so it carries on through network changes and sleep. No Mosh program is needed on Windows. The server needs mosh-server, a UTF-8 locale and its UDP ports open; otherwise the terminal opens over SSH and says why

SIGN-IN
• Password, private key (OpenSSH or PEM; RSA, ECDSA, ed25519; with passphrase), or keyboard-interactive for servers that ask for a one-time code
• Your SSH agent: the Windows OpenSSH agent, Pageant, or an agent pipe named by SSH_AUTH_SOCK. Pageant is used only when its pipe belongs to your account, the way PuTTY checks. The private key stays in the agent
• FIDO2 security keys such as a YubiKey (sk-ed25519, sk-ecdsa), through the agent
• OpenSSH user certificates, with the key ID, principals, validity and options shown, and a warning for a forced command or an expired certificate
• Generate an ed25519 key and install it on a server
• Jump hosts, each hop checked against its own host key
• Import servers from your .ssh\config file: HostName, User, Port, CertificateFile, ForwardAgent and ForwardX11
• A per-host switch for old routers and NAS boxes that only speak legacy algorithms

FORWARDING
• Agent forwarding, per host, so git and ssh on the server can use your agent's keys without copying them there
• X11 forwarding, per host: graphical programs on the server open their windows on your screen. You need an X server running on Windows, such as VcXsrv or X410. Windows X servers have no restricted mode, so while you are connected the server can see and control every window on that display, as with ssh -Y. Use it only with servers you trust; the host's X11 switch says so
• Local, remote and dynamic (SOCKS5) port forwards with live byte counters, listening on localhost unless you choose otherwise

SECURITY
• Trust on first use, with the SHA256 fingerprint shown. A changed host key blocks the connection unless you acknowledge the change
• Saved passwords and keys are encrypted with Windows Data Protection for your Windows account, never stored in plain text. The trusted-key store is sealed against tampering
• Optional app lock with Windows Hello: your PIN, fingerprint or face. If the Hello prompt cannot be shown, the app stays locked
• Encrypted backups (Argon2id, AES-256-GCM) saved to any folder or cloud drive you pick; saved passwords and trusted host keys are included only if you tick them
• An optional diagnostics log for bug reports, off by default, kept on this PC with secrets removed

FILES
• SFTP browser on the same connection as the terminal
• Upload files and whole folders; download files and folders to your Downloads folder, and open a download with its usual app
• Rename, delete, new folder, permissions, change owner, duplicate
• Compress to .tar.gz or .zip and extract archives on the server; search the server by name or content. Actions the server's tools cannot do are not offered
• Drag a file onto another session's tab to copy it between servers, directly from one to the other or through this PC. Direct copies, compress and extract keep running on the server if the app closes
• Built-in editor with syntax colouring for 20 languages, find and replace, tabs for several files, and a save that checks nobody changed the file first and keeps its permissions

ACROSS YOUR SERVERS
• Groups, colour tags and search, with a Ctrl+K command palette over hosts, snippets and actions
• Quick connect with user@host:port, or paste a whole ssh command
• Snippets with {placeholders}, and a startup command per host
• Run a command on many servers at once and see each one's output, exit code and running time; push a file to many servers
• Server stats, a live log tail with filtering, systemd services and processes

MOUSE, KEYBOARD AND TOUCH
Layouts follow how you use the device rather than its operating system. With a mouse you get split panes, right-click menus and drag and drop; on a Windows tablet used by touch you get larger touch targets and the extra keys row (Esc, Tab, Ctrl, arrows and more) above the on-screen keyboard. Keyboard shortcuts: Ctrl+Shift+T for a new session, Ctrl+Tab between sessions, Ctrl+Shift+E between terminal and files, Ctrl+Shift+Enter for a full-width terminal.

Open source under the MIT licence.
```

---

## What's new in this version
*(Limit 1500 characters.)*

**Leave this field blank for 1.5.0.** Microsoft's guidance is to leave it
empty on an app's first submission, and this is SecureShell Go's first
Microsoft Store release. The text below is for reference only. It is 634
characters, and it is the starting point for the next update's notes.

```
SecureShell Go 1.5.0 is the first release in the Microsoft Store. New in 1.5: Mosh; sign-in with your SSH agent or Pageant, including FIDO2 security keys; SSH certificates; agent and X11 forwarding; keyboard-interactive (two-factor) sign-in; Windows Hello app lock; dead connections noticed and reconnected after sleep or a network change; tmux and screen sessions that survive a reconnect; find in the terminal, Ctrl+click links and session logs; delete, rename, permissions, owner, compress, extract and search in the file browser; commands on many servers at once; backups that can include trusted host keys and save to any folder.
```

---

## Product features
*(Up to 20, each 200 characters or fewer. No bullets of your own: the Store adds them.)*

| # | Feature | Characters |
| --- | --- | --- |
| 1 | SSH terminal (xterm-256color) with ten colour schemes, a bundled JetBrains Mono font, zoom, and find in the scrollback with regular expressions | 143 |
| 2 | Mosh for the terminal: started over SSH, carries on through network changes and sleep. No Mosh program needed on Windows | 120 |
| 3 | Sign in with a password, a private key, a one-time code (keyboard-interactive) or your SSH agent | 96 |
| 4 | Windows OpenSSH agent and Pageant supported, including FIDO2 security keys (sk-ed25519, sk-ecdsa) held in the agent | 115 |
| 5 | OpenSSH user certificates, with principals, validity and options shown | 70 |
| 6 | Host keys checked on first use with the SHA256 fingerprint; a changed key blocks the connection | 95 |
| 7 | Saved passwords and keys encrypted with Windows Data Protection, never in plain text | 84 |
| 8 | Optional app lock with Windows Hello (PIN, fingerprint or face) | 63 |
| 9 | Agent forwarding and X11 forwarding per host (X11 needs an X server such as VcXsrv or X410) | 91 |
| 10 | Local, remote and dynamic (SOCKS5) port forwards, on localhost unless you choose otherwise | 90 |
| 11 | Jump hosts, with every hop's host key checked | 45 |
| 12 | Reconnects by itself after sleep or a network change; keep a host's shell in tmux or GNU screen | 95 |
| 13 | SFTP browser: upload and download files and folders, rename, delete, permissions, change owner, duplicate | 105 |
| 14 | Compress, extract and search on the server; copy files directly between two servers | 83 |
| 15 | Built-in editor with syntax colouring for 20 languages and a save that checks for changes first | 95 |
| 16 | Up to four terminal panes side by side, with optional broadcast input | 69 |
| 17 | Ctrl+K command palette, groups, colour tags and search across saved servers | 75 |
| 18 | Snippets with placeholders; run a command on many servers at once and compare the results | 89 |
| 19 | Server stats, live log tail, systemd services and processes | 59 |
| 20 | Encrypted backups (Argon2id, AES-256-GCM); no account, no ads, no analytics | 75 |

---

## Search terms
*(Up to 7, each 30 characters or fewer. Enter them if Partner Center shows the field for this product.)*

| Term | Characters |
| --- | --- |
| SSH client | 10 |
| SFTP client | 11 |
| SSH terminal | 12 |
| Mosh | 4 |
| port forwarding | 15 |
| SSH agent | 9 |
| server administration | 21 |

No competitor or product names (PuTTY, Termius and so on). Pageant and the
Windows OpenSSH agent are named in the description, where they describe
what the app works with.

---

## Category

- **Category:** Developer tools
- **Subcategory:** Networking
- **Secondary category:** Utilities + tools

An SSH client is a networking tool for developers and system
administrators, and Developer tools → Networking is the closest
subcategory. "Servers" would also fit. Utilities + tools is a secondary
category for people browsing for file transfer and remote-access tools.

---

## System requirements

**Operating system:** Windows 10 or Windows 11. `windows/runner/runner.exe.manifest`
declares only the Windows 10/11 `supportedOS` GUID. Windows Hello uses
`IUserConsentVerifierInterop`, which Windows 10 has, so nothing requires
Windows 11. The MSIX minimum OS version is set in the package config at
packaging time (see "Left to the owner").

**Architecture:** x64. CI also builds a native Arm64 `.zip`
(`.github/workflows/desktop-builds.yml`). The MSIX config in progress names
no architecture, so the `msix` tool would build x64 only. Add an Arm64
package only if one is built and tested.

**Properties → System requirements (hardware checkboxes):** none required.
Keyboard and mouse are recommended, not required: the app has a touch
layout with an extra keys row for Windows tablets (`docs/changes/layouts.md`).

**Additional system requirements → Minimum hardware** (each 200 characters
or fewer, no bullets):

| Item | Characters |
| --- | --- |
| Network access to the SSH servers you want to connect to | 56 |
| Mosh: mosh-server installed on the server, a UTF-8 locale there, and its UDP ports (normally 60000-61000) reachable from this PC | 128 |
| X11 forwarding: an X server for Windows, such as VcXsrv or X410 | 63 |
| SSH agent sign-in: the Windows OpenSSH agent or Pageant, running under your account | 83 |
| App lock: Windows Hello set up (PIN, fingerprint or face) | 57 |

---

## Other Partner Center fields

| Field | Value |
| --- | --- |
| Developed by | Dhiva Labs |
| Copyright and trademark info | Copyright (c) 2026 Dhiva Labs. Open source under the MIT licence. |
| Privacy policy URL | https://dhiva-labs.github.io/SecureShellGo/privacy-policy |
| Website | https://github.com/Dhiva-Labs/SecureShellGo |
| Support contact | dhivakar1010@gmail.com |
| Does the app access, collect or transmit personal information? | No. It collects nothing and has no server; see `docs/privacy-policy.md` and `store/play-data-safety.md`. Give the privacy policy URL anyway: Microsoft may ask for one because of the package's network capabilities. |

---

## Verification notes

Terminal
- **xterm-256color, ten colour schemes, JetBrains Mono** — `lib/services/ssh_service.dart`
  (`terminalType = 'xterm-256color'`); `TerminalColorScheme` in
  `lib/models/app_settings.dart` (SecureShell Go, Dracula, Solarized Dark,
  Solarized Light, Nord, Gruvbox Dark, Monokai, One Dark, Black on white,
  Retro green); `pubspec.yaml` `fonts:`; `lib/widgets/terminal_fonts.dart`.
- **Ctrl+Shift+C/V, Ctrl+=/−/0, right-click menu, Ctrl+Shift+F** —
  `lib/screens/terminal_pane.dart`, `lib/widgets/session_shortcuts.dart`,
  `lib/services/terminal_search.dart`, `lib/widgets/terminal_find_bar.dart`;
  `docs/changes/terminal-options.md`, `docs/changes/layouts.md`.
- **Ctrl+click links, http/https only** — `lib/services/terminal_links.dart`
  (`openableSchemes`); `launchUrl(…, mode: LaunchMode.externalApplication)` in
  `lib/screens/terminal_pane.dart`.
- **Session log to a chosen file, plain or raw** —
  `lib/services/session_recorder.dart` (`FileLogSink`),
  `lib/widgets/session_log_actions.dart`.
- **"Paste N lines?"** — `lib/services/clipboard_paste.dart`.
- **Up to four panes; broadcast input off by default and turning itself off**
  — `lib/services/terminal_workspace.dart` (`paneLimit = 4`),
  `lib/services/broadcast_input.dart`. Panes are offered once a mouse or
  trackpad has been used (`lib/services/input_profile.dart`).

Sessions
- **Dead link, sleep/wake and network-change reconnects** —
  `lib/services/session_keepalive.dart`, `lib/services/reconnect_policy.dart`,
  `lib/services/network_watch.dart` (`WakeDetector`, a poll of the local
  network interfaces on desktops).
- **Restart after the shell exits** — `docs/changes/terminal-never-dies.md`,
  `lib/services/session_controller.dart`.
- **tmux / GNU screen** — `Host.persistentSession`,
  `lib/services/persistent_shell.dart`.
- **Mosh, no local mosh needed, fallback to SSH** — `lib/services/mosh/`
  (pure Dart client and AES-OCB in `ocb.dart`), `mosh_bootstrap.dart`;
  `docs/changes/mosh.md`.

Sign-in
- **Password / key / keyboard-interactive / agent** — `SshAuthMethod` in
  `lib/models/host.dart`, `lib/services/login_prompt.dart`,
  `lib/services/private_key_import.dart` (OpenSSH, PEM PKCS#1 RSA and EC; no
  PKCS#8, no PuTTY `.ppk`).
- **Windows agents, order and Pageant owner check** —
  `openWindowsAgent` in `lib/services/ssh_agent_client.dart`
  (`SSH_AUTH_SOCK` if it names a pipe, then `\\.\pipe\openssh-ssh-agent`, then
  Pageant), `lib/services/windows_agent_pipe.dart` (`PageantPipe.find`).
- **FIDO2 `sk-` keys via the agent** — `docs/changes/ssh-auth.md`,
  `lib/services/ssh_agent_client.dart` (`sk-ed25519`/`sk-ecdsa` signing
  through the agent).
- **User certificates and their warnings** — `lib/services/ssh_certificate.dart`,
  `lib/widgets/host_certificate_field.dart`.
- **ed25519 generation and install** — `lib/services/ssh_keygen.dart`,
  `lib/services/public_key_push.dart`.
- **Jump hosts** — `lib/services/jump_host_chain.dart`,
  `lib/services/ssh_service.dart`.
- **Import from `.ssh\config`** — `lib/screens/ssh_config_import_screen.dart`
  (`HOME` or `USERPROFILE` + `/.ssh/config`), `lib/services/ssh_config_parser.dart`.
  ProxyJump is read but not applied, so the copy does not list it.
- **Legacy algorithms** — `Host.legacyAlgorithms`,
  `lib/widgets/host_advanced_section.dart`.

Forwarding
- **Agent forwarding** — `lib/widgets/host_advanced_section.dart` ("Forward
  SSH agent": on a computer, the agent's keys and the host's own key).
- **X11 on Windows, always full trust** — `lib/services/x11_forwarding.dart`
  (`DISPLAY` defaults to `localhost:0` on Windows; TCP 6000 + n;
  `X11UntrustedUnavailable` on Windows); `docs/changes/ssh-auth.md`.
- **Port forwards, byte counters, localhost default** —
  `lib/services/tunnel_runtime.dart`, `lib/services/socks5.dart` (CONNECT
  only), `lib/screens/tunnels_screen.dart`, `TunnelProfile.loopback` in
  `lib/models/tunnel_profile.dart`.

Security
- **TOFU, SHA256, changed key blocks** — `lib/services/host_key_policy.dart`,
  `lib/widgets/host_key_dialog.dart`.
- **Windows Data Protection** — `lib/services/secure_storage_backend.dart`
  (`FlutterSecureStorageBackend`); `flutter_secure_storage_windows` 4.2.2 in
  `pubspec.lock` encrypts with DPAPI (`CryptProtectData`) into
  `flutter_secure_storage.dat` in the app's data folder.
- **Trusted-key store sealed** — `lib/services/known_hosts_integrity.dart`.
- **Windows Hello app lock, stays locked if the prompt fails** —
  `windows/runner/windows_hello.cpp`, `WindowsHelloAppLock` in
  `lib/services/app_lock.dart`; `docs/changes/standalone.md`.
- **Backups** — `lib/services/backup_crypto.dart` (Argon2id 64 MiB/3/1,
  AES-256-GCM), `lib/services/backup_payload.dart` (opt-in credentials,
  separate opt-in host keys), `lib/screens/backup_screen.dart` ("Save to…").
  The format has no platform field, so a backup from Android imports on
  Windows and the other way round (`lib/services/backup_service.dart`).
- **Diagnostics log** — `lib/services/diagnostics_log.dart`.
- **No account, ads or analytics; only your servers and local agent/X
  server** — `pubspec.yaml`; network calls in `lib/` are only
  `SSHSocket.connect`, Mosh's `RawDatagramSocket`, tunnel sockets, and the
  local agent pipe/socket and X server connections.

Files
- **Folder upload (desktop only), downloads to Downloads, open with the
  default app** — `lib/screens/file_browser_pane.dart`,
  `lib/services/device_storage.dart` (`DesktopDeviceStorage`,
  `getDownloadsDirectory`), `lib/services/windows_shell_open.dart`
  (`ShellExecuteW`, not `cmd`).
- **File actions, compress/extract/search, hidden when unsupported** —
  `lib/services/remote_file_ops.dart`, `lib/screens/remote_search_screen.dart`;
  `docs/changes/remote-ops.md`, `docs/changes/file-browser.md`.
- **Drag to another session's tab; direct or relayed copy; keeps running**
  — `docs/changes/layouts.md`; `lib/services/direct_remote_copy.dart`,
  `lib/services/remote_copy.dart`, `lib/services/server_side_job.dart`.
- **Editor** — `syntaxModes` in `lib/services/syntax_highlighter.dart` (20
  languages plus plain text), `lib/services/editor_search.dart`,
  `lib/services/editor_save.dart`.

Across your servers
- **Ctrl+K palette** — `lib/widgets/command_palette.dart` (opened from the
  host list).
- **Quick connect including a pasted `ssh` command** —
  `lib/services/quick_connect_parser.dart`.
- **Snippets, startup command** — `lib/services/snippet_placeholders.dart`,
  `Host.startupCommand`.
- **Commands on many servers, push to many** —
  `lib/services/fleet_exec_service.dart`, `lib/services/fleet_push_service.dart`.
- **Stats, log tail, services, processes** — `lib/services/server_probe.dart`,
  `lib/services/log_tail.dart`, `lib/services/systemd_units.dart`,
  `lib/services/process_table.dart`.

Mouse, keyboard and touch
- `lib/services/input_profile.dart`, `lib/widgets/session_shortcuts.dart`,
  `lib/widgets/terminal_key_bar.dart`; `docs/changes/layouts.md`.

### Deliberately not claimed

- "Keep screen awake": the setting is shown on Windows but only Android acts
  on it.
- Dropping files from Explorer into the app (not implemented), resuming an
  interrupted transfer part-way (it restarts from the beginning), PuTTY
  `.ppk` keys, ProxyJump from `ssh_config`, auto-starting tunnels,
  translations.
- Anything about how a Windows X server, agent or Hello behaves beyond what
  the app does with them.

---

## Left to the owner

- Reserve the name and fill `msix_config` (`identity_name`, `publisher`) in
  `pubspec.yaml` from Partner Center, and set the minimum Windows version
  there. Another piece of work is setting up that config now.
- Check the package capabilities. The app needs outbound TCP (SSH), UDP
  (Mosh), listening sockets on localhost (port forwards), and connections to
  localhost:6000 or more (X11). It also needs the named pipes of the Windows
  OpenSSH agent and Pageant. Run the Windows App Certification Kit on the
  package (`store/release-checklist-1.5.md`).
- Screenshots: at least one is required, and four or more are recommended.
  None of the ones in `store/graphics/screenshots/` are from Windows.
- Age rating questionnaire (IARC).
- Localization: this copy is US English only.
