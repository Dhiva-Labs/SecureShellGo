# Play Console listing copy — SecureShell Go v1.1.0

Sourced from README.md and a read of `lib/` (services: `host_key_policy.dart`,
`known_hosts_integrity.dart`, `credential_store.dart`, `secure_storage_backend.dart`,
`session_keepalive.dart`, `session_foreground.dart`, `private_key_import.dart`,
`download_plan.dart`, `upload_plan.dart`, `clipboard_paste.dart`,
`layout_breakpoints.dart`) and `android/app/src/main/AndroidManifest.xml`, to
make sure every claim below matches something the code actually does. Nothing
here describes a feature that isn't implemented.

---

## App title
*(Play limit: 30 characters)*

```
SecureShell Go
```
14 characters.

---

## Short description
*(Play limit: 80 characters)*

```
SSH terminal & SFTP client with strict host-key verification built in
```
69 characters. Leads with the two things the app is (terminal + SFTP client)
and the one differentiator worth a scarce 80 characters (real host-key
verification, not "trust it and hope"). No repeated keywords, no superlatives.

---

## Full description
*(Play limit: 4000 characters — this is 3782)*

```
SecureShell Go is a fast, security-first SSH terminal and SFTP client for Android. Connect to your Linux servers, run a real interactive shell, and move files — all built around strict host-key verification instead of the "trust it and hope" approach a lot of mobile SSH apps take.

TERMINAL THAT FEELS LIKE A TERMINAL
A full xterm-256color terminal (dartssh2 + xterm) with proper colors, resize handling and scrollback. An extra-keys bar puts Esc, Tab, a sticky Ctrl, arrow keys with long-press repeat, Ctrl+C/D/Z/L/R, and pipe/slash/tilde within thumb reach — every key is a full 48dp touch target with haptic feedback. Pinch to zoom the font size, and pick from five color schemes: Solarized Dark, Monokai, a retro green-phosphor look, black-on-white for daylight reading, or the default. Copy and paste uses the system clipboard, with a long-press selection toolbar, a dedicated Paste key, and a "Paste N lines?" guard so a careless multi-line paste can't flood your shell with commands you didn't mean to run. Connect a hardware keyboard and Ctrl+letter shortcuts pass straight through (Ctrl+C sends SIGINT), with Ctrl+Shift+C/V for copy and paste.

SECURITY THAT DOESN'T CUT CORNERS
Every host key is checked the way OpenSSH checks it: trust-on-first-use, keyed on host, port and key type, with a SHA256 fingerprint shown so you can verify it out-of-band before accepting. If a host key ever changes, the connection is blocked outright with a full-screen warning and an explicit checkbox before you can override it — exactly what you want if that change means a machine-in-the-middle. The trust store behind all of this is sealed with an HMAC whose key lives in the Android Keystore, so a tampered or stripped file fails closed instead of silently letting a bad key through. Passwords, private keys and passphrases are never written in plain text — they live only in Keystore-encrypted secure storage.

CONNECT THE WAY YOU ACTUALLY WORK
Save hosts for one-tap connect, or quick-connect without saving anything. Authenticate with a password or a private key — OpenSSH, PKCS#1 RSA or ECDSA, with passphrase support — and import a .pem file directly, including AWS EC2 keys. Once connected, a quiet foreground service and 30-second keepalives hold your session open while you switch to other apps, and if the server does drop, you get a clean reconnect state instead of a zombie terminal.

FILES, WITHOUT LEAVING YOUR SESSION
The SFTP browser shares the same live SSH session as the terminal, so switching between them never drops your shell. Downloads stream straight into your device's Downloads folder with flat memory usage — multi-gigabyte files are safe — plus progress, cancel, multi-select, and an "Open" action the moment a file lands. Download an entire folder and SecureShell Go walks it, counts and sizes it up front, then recreates its structure under Download/<folder>/. "Upload here" lets you pick any number of files and send them to whatever directory you're looking at, each with its own progress, cancel and retry, and a replace / keep both / skip prompt if a name is already taken. You can also share files into SecureShell Go from any other app's share menu — pick a saved host and folder and they upload, reusing a session you already have open instead of asking you to sign in again. Hidden-files toggle, directories-first sorting, breadcrumbs and pull-to-refresh round it out.

BUILT FOR EVERY SCREEN
Material 3 window-size-class layouts mean a side-by-side terminal and file browser on tablets, Samsung DeX windows and unfolded foldables, and a host grid on wide screens — with live relayout on resize or fold/unfold that never drops your connection. It's just as comfortable on a small phone in portrait or landscape.

Open source under the MIT licence.
```

### Verification notes (why each claim is safe to publish)
- **xterm-256color, colors, resize, scrollback** — `pubspec.yaml` depends on
  `dartssh2` + `xterm`; `lib/theme.dart` defines the `TerminalTheme` used.
- **Extra-keys bar, 48dp targets, haptics** — `lib/widgets/terminal_key_bar.dart`.
- **Five color schemes** — `AppTheme.terminalThemeFor` in `lib/theme.dart`
  switches on `TerminalColorScheme` (`classic`, `solarizedDark`, `monokai`,
  `blackOnWhite`, `retroGreen`) — five, matching the copy exactly.
- **"Paste N lines?" guard** — `lib/services/clipboard_paste.dart`
  (`ClipboardPaste.needsConfirmation`).
- **Hardware keyboard Ctrl passthrough** — README, consistent with the
  terminal pane's key handling.
- **TOFU host-key verification, SHA256 fingerprint, blocked-and-checkbox on
  change** — `lib/services/host_key_policy.dart` (`HostKeyPolicy.evaluate`,
  `HostKeyPromptKind.changed`) and `HostKeyPolicy.decodeFingerprint` (SHA256
  format, byte-for-byte what `ssh-keygen -l` prints).
- **HMAC-sealed trust store, Keystore-backed key, fail-closed on tamper** —
  `lib/services/known_hosts_integrity.dart` (`KnownHostsIntegrityKey`,
  `KnownHostsEnvelope`, `IntegrityVerdict.tampered`).
- **Keystore-encrypted credentials, never plain text** —
  `lib/services/credential_store.dart` +
  `lib/services/secure_storage_backend.dart`
  (`FlutterSecureStorageBackend` wraps `flutter_secure_storage`, i.e. Android
  Keystore-backed `EncryptedSharedPreferences`).
- **Password / private-key auth, OpenSSH / PKCS#1 RSA / ECDSA, passphrase,
  .pem / AWS import** — `lib/services/private_key_import.dart`
  (`classifyPrivateKeyPem`, explicitly documents PKCS#1 RSA as "what
  `ssh-keygen -m PEM` and AWS EC2 both produce").
- **Foreground service + 30s keepalives** —
  `lib/services/session_keepalive.dart` (`interval = Duration(seconds: 30)`)
  and `lib/services/session_foreground.dart`
  (`SessionForegroundController`); manifest declares
  `FOREGROUND_SERVICE` / `FOREGROUND_SERVICE_DATA_SYNC`.
- **SFTP browser shares the live session** —
  `lib/screens/file_browser_pane.dart` + `lib/services/sftp_service.dart`
  reuse the connection from `session_controller.dart`.
- **Streaming downloads, flat memory, folder download with counted/sized
  plan** — `lib/services/download_plan.dart`
  (`DirectoryDownloadPlan`, walked/counted/sized before any transfer).
- **"Upload here", multi-file, collision prompt** —
  `lib/services/upload_plan.dart` (`UploadCollisionAction`,
  `UploadCollisionResponse`).
- **Share-sheet upload target reusing an open session** —
  `lib/screens/share_target_screen.dart`, `lib/services/share_intake.dart`,
  manifest `SEND` / `SEND_MULTIPLE` intent filters, `singleTask` launch mode
  (documented in the manifest specifically to make this work).
- **Adaptive phone/tablet/DeX/fold layouts** —
  `lib/services/layout_breakpoints.dart` (`WindowSizeClass`, Material 3
  compact/medium/expanded thresholds).
- **Android 6.0+** — `android/app/build.gradle.kts`:
  `minSdk = maxOf(flutter.minSdkVersion, 23)` (API 23 = Android 6.0).

Deliberately **not** claimed: "no root required" (true — nothing in the
manifest, Kotlin bridges or Dart code touches root — but it's not a concern
users of an SSH client are worried about, so asserting it would read as an
odd, slightly defensive claim rather than a benefit); any performance
superlative ("fastest", "best"); any claim about server-side software this
app doesn't control.

---

## What's new in 1.1.0
*(Play limit: 500 characters — this is 406)*

```
1.1.0 makes moving files a first-class flow: an "Upload here" button to send multiple files at once, each with its own progress, cancel and retry; a replace / keep both / skip prompt on name collisions; whole-folder downloads that rebuild the server's structure locally; an "Open" action the moment a download finishes; and a share-sheet target so you can send files into SecureShell Go from any other app.
```

Matches the actual 1.1.0 diff (`git show 396d335`, "Make moving files between
phone and server a first-class flow"): multi-file upload with per-file
progress/cancel/retry, collision prompts with apply-to-all, share-sheet
intake (`SEND`/`SEND_MULTIPLE`), recursive folder download, and "Open" on
finished downloads. 1.0.0 (`b8a4c00`) already had the terminal, SFTP browser,
and single-file transfer; this release is specifically the transfer-UX pass.

---

## Category & tags

**Category: Tools**

Rationale: SecureShell Go is a technical utility (SSH client + file
transfer) aimed at developers/sysadmins, not a consumer app in
Productivity, Communication, or Business. "Tools" is where Android's other
terminal and remote-access apps (Termux, JuiceSSH, Termius) are listed, so
it's also where the app's actual audience will look for it.

**Suggested tags** (pick from Play Console's own tag list at publish time —
these are the closest matches to what the app does):
- Developer tools / Productivity (secondary tag, if Play offers a second slot)
- Anything Play's taxonomy has for "remote access" or "file manager" — the
  app is both, so whichever of the two Play distinguishes is fair to add

Avoid: "cloud", "backup", "VPN", "network scanner" — none of those describe
what the app does, and adding them would be keyword stuffing, not tagging.

---

## Left to the PM

- Play Console tag picker is a closed taxonomy that changes over time — pick
  the actual tags from the live list at submission time rather than trusting
  a name guessed here.
- Content rating questionnaire, target audience, data-safety form (the app
  transmits SSH/SFTP credentials only to the server the user configures, and
  stores them locally via Android Keystore — no analytics/tracking SDKs are
  in `pubspec.yaml` to declare, but that's a data-safety-form judgment call,
  not a copy one).
- Contact email / privacy policy URL for the listing.
- Localization — this copy is US English only.
