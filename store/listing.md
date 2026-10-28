# Play Console listing copy — SecureShell Go 1.5.0

Every claim below was checked against the code on `release/1.5.0`: `lib/`,
`android/app/src/main/AndroidManifest.xml`, the Kotlin bridges in
`android/app/src/main/kotlin/com/dhivalabs/secure_shell_go/`, `pubspec.yaml`,
and the per-feature notes in `docs/changes/*.md`. The verification notes say
where each one comes from. This is the Android listing, so features that
exist only on Windows, Linux and macOS (agent sign-in, X11 forwarding,
importing `~/.ssh/config`, uploading whole folders) are left out. They are in
`store/microsoft-store-listing.md`.

---

## App title
*(Play limit: 30 characters)*

```
SecureShell Go
```
14 characters. The same as the launcher label (`android:label` in the
manifest).

---

## Short description
*(Play limit: 80 characters)*

```
SSH and Mosh terminal, SFTP file browser, strict host-key verification
```
70 characters. It names what the app is (terminal and file client, over SSH
or Mosh) and the one thing that sets it apart: host keys are checked the way
OpenSSH checks them. No superlatives, no repeated keywords.

---

## Full description
*(Play limit: 4000 characters. This is 3288.)*

```
SecureShell Go is an SSH terminal and SFTP file client for servers you run. It checks host keys the way OpenSSH does, keeps your sessions connected while you use other apps, and keeps what it stores on your phone. No account, no ads, no analytics.

TERMINAL
• xterm-256color terminal, ten colour schemes, bundled JetBrains Mono font, pinch to zoom
• Extra keys row: Esc, Tab, sticky Ctrl, arrows, Home/End/PgUp/PgDn, ^C ^D ^Z ^L ^R and Paste. It steps aside while a hardware keyboard is typing
• Find in the scrollback, with match case and regular expressions
• Long-press a web address to open or copy it
• Record a session log, as plain text or exactly as received
• A "Paste N lines?" check before a multi-line paste reaches the shell

SESSIONS THAT STAY UP
• A foreground service keeps sessions connected while you are in other apps
• A dead connection is noticed and reconnected, also right after a switch between Wi-Fi and mobile data
• Keep a host's shell in tmux or GNU screen, so a reconnect lands back in the same shell
• Mosh: the app starts mosh-server over SSH and runs the terminal over UDP, through network changes and long sleeps. Nothing extra to install on the phone; the server needs mosh-server and its UDP ports open

SIGN-IN
• Password, private key (OpenSSH or PEM; RSA, ECDSA, ed25519; with passphrase) or keyboard-interactive, for servers that ask for a one-time code
• OpenSSH user certificates
• Generate an ed25519 key and install it on a server
• Jump hosts, each hop checked against its own host key
• A per-host switch for old routers and NAS boxes that only speak legacy algorithms

SECURITY
• Trust on first use, with the SHA256 fingerprint shown. A changed host key blocks the connection unless you acknowledge the change
• Saved passwords and keys are encrypted under an Android Keystore key, never stored in plain text. The trusted-key store is sealed against tampering
• Optional app lock with your fingerprint, face or screen lock
• Encrypted backups (Argon2id, AES-256-GCM), saved wherever you choose

FILES
• SFTP browser on the same connection as the terminal
• Upload, download, whole-folder download, rename, delete, new folder, permissions, change owner, duplicate
• Compress to .tar.gz or .zip and extract archives on the server; search the server by name or content
• Copy between two servers, directly from one to the other or through the phone. Direct copies, compress and extract keep running on the server if the app closes
• Share files into the app from any other app to upload them
• Built-in editor with syntax colouring for 20 languages, find and replace, and a save that checks nobody changed the file first

ACROSS YOUR SERVERS
• Groups, colour tags, search, and quick connect with user@host:port
• Snippets with {placeholders}
• Run a command on many servers at once and see each one's output and exit code; push a file to many servers
• Local, remote and dynamic (SOCKS5) port forwards, on localhost unless you choose otherwise
• Server stats, a live log tail, systemd services and processes

EVERY SCREEN
Phones, tablets, foldables and Samsung DeX. On a foldable the terminal and files split at the hinge. With a mouse or trackpad you get split panes, right-click menus and keyboard shortcuts.

Open source under the MIT licence.
```

### Verification notes

Terminal
- **xterm-256color** — `dartssh2` and `xterm` in `pubspec.yaml`; the PTY is
  requested as `xterm-256color` in `lib/services/ssh_service.dart`.
- **Ten colour schemes** — `TerminalColorScheme` in
  `lib/models/app_settings.dart`: SecureShell Go, Dracula, Solarized Dark,
  Solarized Light, Nord, Gruvbox Dark, Monokai, One Dark, Black on white,
  Retro green. Themes in `AppTheme.terminalThemeFor`, `lib/theme.dart`.
- **Bundled JetBrains Mono** — `pubspec.yaml` `fonts:`;
  `lib/widgets/terminal_fonts.dart` registers its OFL licence.
- **Pinch to zoom** — `lib/screens/terminal_pane.dart`;
  `docs/changes/terminal-options.md` ("as a pinch-zoom is").
- **Extra keys row and its keys; hides while a hardware keyboard types** —
  `lib/widgets/terminal_key_bar.dart` (esc, tab, ^C ^D ^Z ^L ^R, sticky Ctrl,
  Paste, `| / - ~`, arrows, home, end, pgup, pgdn); `KeyBarMode` (Automatic,
  Always, Never) in `app_settings.dart`; `docs/changes/layouts.md`.
- **Find with match case and regex** — `lib/services/terminal_search.dart`,
  `lib/widgets/terminal_find_bar.dart`.
- **Long-press a link to open or copy it** —
  `lib/services/terminal_links.dart` (`openableSchemes = {'http','https'}`),
  `lib/screens/terminal_pane.dart` (`launchUrl`).
- **Session log, plain or raw** — `lib/services/session_recorder.dart`,
  `lib/widgets/session_log_actions.dart` (on Android it is kept in memory, up
  to 32 MB, and saved through the system save screen when stopped).
- **"Paste N lines?"** — `ClipboardPaste.needsConfirmation` in
  `lib/services/clipboard_paste.dart`.

Sessions that stay up
- **Foreground service** — `SessionForegroundService.kt`; manifest types
  `specialUse|dataSync`; `store/play-fgs-declaration.md`.
- **Dead connection noticed and reconnected; network changes** —
  `lib/services/session_keepalive.dart` (30 s keep-alives, three missed with
  nothing else heard means dead), `lib/services/reconnect_policy.dart`,
  `lib/services/network_watch.dart` and `NetworkWatchBridge.kt`
  (`ACCESS_NETWORK_STATE`).
- **tmux or GNU screen** — `Host.persistentSession`,
  `lib/services/persistent_shell.dart`; `docs/changes/terminal-never-dies.md`.
- **Mosh** — `lib/services/mosh/` (pure Dart client, AES-OCB in `ocb.dart`,
  `mosh-server new` started over SSH in `mosh_bootstrap.dart`);
  `docs/changes/mosh.md`. Needs `mosh-server` and open UDP ports on the
  server; otherwise the terminal opens over SSH and says why.

Sign-in
- **Password / private key / keyboard-interactive** — `SshAuthMethod` in
  `lib/models/host.dart`; `lib/services/login_prompt.dart`. Key formats in
  `lib/services/private_key_import.dart`: OpenSSH, PEM PKCS#1 RSA and PEM EC,
  plain or passphrase-protected. PKCS#8 and PuTTY `.ppk` are not supported,
  so the copy says "OpenSSH or PEM" and nothing more.
- **User certificates** — `lib/services/ssh_certificate.dart` (user
  certificates only; host certificates are refused).
- **ed25519 key generation and install** — `lib/services/ssh_keygen.dart`
  (`generateEd25519`), `lib/services/public_key_push.dart` (the `ssh-copy-id`
  steps: create `~/.ssh`, append the key if absent, fix permissions, check).
- **Jump hosts** — `lib/services/jump_host_chain.dart` (up to 8 hops); each
  hop is host-key checked in `lib/services/ssh_service.dart`.
- **Legacy algorithms switch** — `Host.legacyAlgorithms`,
  `lib/widgets/host_advanced_section.dart` ("Allow legacy algorithms");
  `docs/changes/ssh-library.md`.

Security
- **TOFU, SHA256 fingerprint, changed key blocks until acknowledged** —
  `lib/services/host_key_policy.dart`, `lib/widgets/host_key_dialog.dart`
  ("Trust new key" needs the acknowledgement ticked).
- **Credentials encrypted under a Keystore key** —
  `lib/services/credential_store.dart`,
  `lib/services/secure_storage_backend.dart` (`flutter_secure_storage` 10:
  AES-GCM, with the key wrapped by an Android Keystore RSA key).
- **Trusted-key store sealed** — `lib/services/known_hosts_integrity.dart`
  (HMAC-SHA256; the key is in secure storage; a bad seal fails closed).
- **App lock** — `AppLockBridge.kt` (BiometricPrompt with
  `BIOMETRIC_STRONG or DEVICE_CREDENTIAL`), `USE_BIOMETRIC` in the manifest,
  `lib/services/app_lock_controller.dart`.
- **Encrypted backups saved anywhere** — `lib/services/backup_crypto.dart`
  (Argon2id m=64 MiB, t=3, p=1; AES-256-GCM), `lib/screens/backup_screen.dart`
  ("Save to…", "Save to Downloads"), `DocumentSaver.kt`.
- **No account, ads or analytics** — no such dependency in `pubspec.yaml`;
  no HTTP code in `lib/`.

Files
- **SFTP on the same connection** — `lib/screens/file_browser_pane.dart`,
  `lib/services/sftp_service.dart`.
- **Upload, download, folder download, rename, delete, new folder,
  permissions, change owner, duplicate** — `lib/screens/file_browser_pane.dart`,
  `lib/services/remote_file_ops.dart`, `lib/services/download_plan.dart`.
- **Compress (.tar.gz, .zip), extract (.tar, .tar.gz/.tgz, .tar.xz/.txz,
  .zip), search** — `lib/services/remote_file_ops.dart`,
  `lib/screens/remote_search_screen.dart`.
  Actions the server's tools cannot do are hidden.
- **Server-to-server copy, direct or relayed; keeps running on the server**
  — `lib/services/direct_remote_copy.dart`, `lib/services/remote_copy.dart`,
  `lib/services/server_side_job.dart`.
- **Share into the app** — `SEND`/`SEND_MULTIPLE` intent filters in the
  manifest, `lib/services/share_intake.dart`,
  `lib/screens/share_target_screen.dart`.
- **Editor: 20 languages, find and replace, conflict-checked save** —
  `syntaxModes` in `lib/services/syntax_highlighter.dart` (Shell, YAML, JSON,
  Dart, Python, JavaScript/TypeScript, C/C++, Go, Rust, Java, Kotlin, Ruby,
  PHP, HTML/XML, CSS, Markdown, INI/TOML, SQL, Dockerfile, nginx/Apache conf),
  `lib/services/editor_search.dart`, `lib/services/editor_save.dart` (checks
  size and modification time, writes a temporary file, verifies it, renames
  it into place, keeps permissions).

Across your servers
- **Groups, colour tags, search, quick connect** —
  `lib/services/host_grouping.dart`, `lib/widgets/host_color_dot.dart`,
  `lib/services/quick_connect_parser.dart`.
- **Snippets with `{placeholders}`** — `lib/services/snippet_placeholders.dart`.
- **Run a command on many servers; push a file to many** —
  `lib/services/fleet_exec_service.dart`, `lib/screens/fleet_run_screen.dart`,
  `lib/services/fleet_push_service.dart`. Not limited to desktop.
- **Port forwards on localhost by default** — `lib/services/tunnel_runtime.dart`,
  `lib/services/socks5.dart`, `TunnelProfile.loopback = '127.0.0.1'` in
  `lib/models/tunnel_profile.dart`.
- **Stats, log tail, services and processes** —
  `lib/services/server_probe.dart`, `lib/services/log_tail.dart`,
  `lib/services/systemd_units.dart`, `lib/services/process_table.dart`.

Every screen
- **Hinge split** — `lib/services/display_hinge.dart`,
  `lib/widgets/hinge_split.dart`.
- **Split panes, right-click, shortcuts with a mouse or trackpad** —
  `lib/services/input_profile.dart`, `lib/services/terminal_workspace.dart`
  (up to 4 panes), `lib/widgets/session_shortcuts.dart`;
  `docs/changes/layouts.md`.

**Android version:** `minSdk = maxOf(flutter.minSdkVersion, 23)` in
`android/app/build.gradle.kts`. With the Flutter SDK on the build machine
(3.44.6, whose default is 24) that is **Android 7.0**, not the 6.0 the 1.1.0
listing implied. Play shows the real minimum from the bundle, so the copy
does not state it.

### Deliberately not claimed

- Anything that exists only on computers: agent sign-in, FIDO2 keys, X11
  forwarding, `~/.ssh/config` import, folder upload, Windows Hello.
- "Resumes transfers": an interrupted transfer starts again by itself after
  a reconnect, but from the beginning (`transfer_queue.dart`
  `resumeInterrupted`).
- Customisable extra keys (the row is fixed; only when it shows can be set),
  PuTTY or PKCS#8 keys, auto-starting tunnels, configurable keep-alive
  interval.
- Translations: the committed branch is English only.
- Any performance or security superlative, and anything about server-side
  software the app does not control.

---

## What's new in 1.5.0
*(Play limit: 500 characters. This is 479.)*

```
1.5.0: Mosh. Two-factor (keyboard-interactive) sign-in, SSH certificates and agent forwarding. Dead connections are noticed and reconnected, and a host's shell can live in tmux or screen. Find in the terminal, open links, record session logs. Delete, rename, permissions, owner, compress, extract and search in the file browser. Run a command on many servers. Editor indentation and 7 more languages. Foldables split at the hinge. Backups can include host keys and save anywhere.
```

Sources, one per item: `docs/changes/mosh.md`; `login.md` (keyboard-interactive);
`ssh-auth.md` (certificates, agent forwarding); `terminal-never-dies.md`
(dead-link detection, tmux/screen); `terminal-options.md` (find, links,
session logs); `file-browser.md` and `remote-ops.md` (file actions, commands
on many servers); `editor.md` (indentation, seven new languages: C/C++, Go,
Rust, Java, Kotlin, Ruby, PHP); `layouts.md` (hinge split); `standalone.md`
(backups with host keys, "Save to…").

---

## Category & tags

**Category: Tools**

SecureShell Go is a technical utility (SSH client and file transfer) for
developers and sysadmins. Tools is where Android's other terminal and
remote-access apps are listed, so it is where its audience looks.

**Tags:** pick from Play Console's own list at submission time. The closest
matches to what the app does are anything Play has for remote access,
terminal or developer tools, and file management. Avoid "cloud", "VPN",
"backup" or "network scanner": none of them describes the app.

---

## Left to the owner

- Pick the tags from the live list; Play's taxonomy changes.
- Screenshots: the phone, 7-inch and 10-inch folders in
  `store/graphics/screenshots/`. They were taken in July 2026, before 1.5,
  so they need retaking.
- Data safety: answers in `store/play-data-safety.md`.
- Foreground service declaration: `store/play-fgs-declaration.md`.
- Privacy policy URL:
  `https://dhiva-labs.github.io/SecureShellGo/privacy-policy`.
- Contact email: dhivakar1010@gmail.com.
- Content rating questionnaire and target audience.
- Localization: this copy is US English only.
