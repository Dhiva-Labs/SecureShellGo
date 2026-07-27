# SecureShell Go — Architecture

An Android SSH terminal client with an SFTP file browser. Phase 1 covered
connecting, host-key verification and the interactive shell; Phase 2 the saved
host manager and encrypted credentials; Phase 3 the SFTP browser, downloads to
the device's shared Downloads collection, and integrity protection for the
known-hosts store.

Stack: Flutter (Material 3, dark), [`dartssh2`](https://pub.dev/packages/dartssh2)
for the SSH2 protocol, [`xterm`](https://pub.dev/packages/xterm) for terminal
emulation. Both are pure Dart, so there is no native SSH dependency to maintain.
The only native code in the project is one ~250-line Kotlin channel for
MediaStore and the document picker.

---

## Layers

```
lib/
  main.dart                     composition root: builds the services, runs the app
  theme.dart                    Material 3 dark theme + xterm colour palette

  models/                       plain data, no I/O, no Flutter imports
    host.dart                   Host (persistable) + SshCredentials (in-memory only)
    known_host.dart             KnownHostKey — one trusted host key
    remote_entry.dart           RemoteEntry — one row of a remote directory

  services/                     all I/O and protocol work, no Flutter imports
    known_hosts_service.dart    the trusted-key store (sealed JSON on disk)
    known_hosts_integrity.dart  the HMAC envelope + its Keystore-held key
    host_key_policy.dart        the trust decision: first use / match / changed
    ssh_service.dart            connect, authenticate, map errors to human text
    secure_storage_backend.dart the Keystore seam (fake-able in tests)
    credential_store.dart       saved passwords/keys, per host
    host_store.dart             hosts.json
    session_controller.dart     one live session, shared by terminal + browser
    session_keepalive.dart      the 30 s keep-alive schedule for a live session
    session_foreground.dart     refcount + channel for the foreground service
    sftp_service.dart           RemoteFileSystem over dartssh2's SftpClient
    transfer_queue.dart         the download/upload queue and its progress model
    remote_path.dart            POSIX path arithmetic, name sanitising, sizes
    device_storage.dart         Dart half of the MediaStore / picker channel
    private_key_import.dart     classify a picked key file, no socket needed

  screens/
    host_list_screen.dart       home: saved hosts, connect, "browse files"
    host_edit_screen.dart       add/edit a host
    known_hosts_screen.dart     manage trusted host keys
    session_screen.dart         owns the session; hosts the two panes
    terminal_pane.dart          xterm view wired to the SSH shell channel
    file_browser_pane.dart      SFTP directory browser + downloads

  widgets/
    host_key_dialog.dart        the accept/reject host key UI
    terminal_key_bar.dart       Esc/Tab/Ctrl-x/arrows row for soft keyboards
    transfer_panel.dart         transfer summary bar + transfers bottom sheet

android/app/src/main/kotlin/.../StorageBridge.kt
                                MediaStore Downloads writer + SAF file picker
android/app/src/main/kotlin/.../SessionForegroundService.kt
                                the ongoing notification that keeps the
                                process alive while a session is connected
```

The dependency rule is one-directional: `screens` and `widgets` depend on
`services`, `services` depend on `models`, and nothing in `models` or `services`
imports Flutter. That is what lets the whole security core — and now the
session and transfer logic — be unit-tested without a widget tree or a device.
`SessionController` in particular exposes a plain broadcast `Stream` rather than
`ChangeNotifier` precisely to keep that rule.

Services are constructed once in `main.dart` and passed down by constructor.
There is no service locator and no global state.

---

## SSH session lifecycle

```
HostListScreen._connect()  /  HostEditScreen._connectWithoutSaving()
  │
  ├─ SshService.connect(host, credentials, verifyHostKey)
  │    ├─ parse private key (if key auth)      ← fails fast, before any socket
  │    ├─ SSHSocket.connect(host, port)        ← TCP, with timeout
  │    ├─ SSH handshake
  │    │    └─ onVerifyHostKey ──► HostKeyPolicy.evaluate()
  │    │                             └─ may await the user via a dialog
  │    ├─ authenticate (publickey or password)
  │    └─ returns SshConnection { client, socket, host }
  │
  └─ Navigator.push(SessionScreen(connection, initialView))
       │
       ├─ SessionForegroundController.acquire(host)   ← process stays alive
       │
       ├─ SessionController(connection)         ← owns the transport from here
       │    ├─ shell(columns, rows)  → opened once, cached
       │    ├─ sftp()                → opened once, cached (2nd channel, same auth)
       │    ├─ transfers: TransferQueue
       │    ├─ SessionKeepalive      → connection.ping() every 30 s
       │    └─ connection.done ─────► isClosed / closeReason → banner
       │
       ├─ IndexedStack
       │    ├─ TerminalPane(session)      xterm ⇄ shell channel
       │    └─ FileBrowserPane(session)   SFTP listing + downloads
       │
       └─ dispose: release the service, stop keep-alives, cancel transfers,
                   close sftp, close shell, close connection
```

Notes on the parts that are easy to get wrong:

**Ownership.** Phase 1 let `TerminalScreen` own the `SshConnection` and close it
in `dispose()`, which was right while the terminal was the only thing on the
connection and wrong the moment a file browser wanted the *same* authenticated
transport. Ownership now sits in `SessionController`, held by `SessionScreen`:
the session outlives either pane and ends only when the route is popped or the
transport dies. Switching between the shell and the file browser does neither —
`IndexedStack` keeps both panes alive, so a running `htop` survives a trip to
the file list and back. The connect call sites still only have to close the
connection if the widget unmounted before the push happened.

**One connection, two channels.** `SSHClient.sftp()` opens another channel on
the connection that is already authenticated. There is no second login and no
second host-key prompt, which is the entire reason the ownership lift was worth
doing. `SessionController.sftp()` caches the future, so concurrent callers share
one open and the channel count stays at one.

**PTY sizing.** The shell is opened *after* the first `TerminalView` layout
reports the real column/row count (with a 1.5 s fallback to 80×24). Opening it
earlier means the remote shell draws its first prompt at the wrong width.
Subsequent resizes — rotation, keyboard show/hide — flow through
`Terminal.onResize` into `SSHSession.resizeTerminal`, which is what makes
`vim`/`htop`/`less` reflow.

**UTF-8 across packet boundaries.** stdout is decoded through a chunked
`Utf8Decoder`, not `utf8.decode` per chunk. A multi-byte character split across
two SSH packets would otherwise render as garbage — very visible with
box-drawing characters and `tree`/`htop` output.

**The handshake timeout is deliberately long.** `dartssh2` starts its handshake
timer when the client is constructed and cancels it only once the transport is
ready — which is *after* `onVerifyHostKey` returns. Since that callback blocks
on a human comparing a fingerprint, a normal 20 s handshake timeout would kill
the connection under a user doing exactly the careful thing we asked for. So
the handshake budget is `timeout + 5 min`, while the *socket* connect timeout
stays tight (that is the one that catches unreachable hosts) and the auth
timeout stays tight (no human is in that loop). See
`SshService.hostKeyDecisionBudget`.

**Errors.** Every failure path throws `SshConnectionException` carrying a
message written for a human ("Connection refused by … on port 22. Is the SSH
server running?") plus optional raw `details` behind a "show details" toggle.
`HostKeyRejectedException` is a distinct subtype so the UI can say "you
rejected the key" rather than "connection failed".

---

## Surviving the background

Phase 7's problem: the user opens a session, switches to another app to read
the command they meant to paste, and comes back to a dead terminal. Two
different things kill it, and they need two different answers.

**The process gets reclaimed.** A backgrounded Android process is a candidate
for the low-memory killer, and killing it takes the socket, the PTY and
whatever was running in it. The sanctioned answer is a foreground service, so
`SessionScreen` starts one for the lifetime of the session:

```
SessionScreen.initState  → SessionForegroundController.acquire(host.displayName)
                              └─ 0 → 1 edge → channel "start"
                                   └─ MainActivity → SessionForegroundService
                                        ├─ POST_NOTIFICATIONS asked, once
                                        └─ startForeground(…, DATA_SYNC)
SessionScreen.dispose    → release()
session drops in background → release() too, from the changes listener
                              └─ 1 → 0 edge → channel "stop"
```

The count is a reference count rather than a boolean because Flutter runs a new
route's `initState` *before* the old route's `dispose`: with a boolean, pushing
one session over another would stop the service belonging to the live one. The
platform calls are chained onto a single future for the mirror-image reason —
an acquire immediately followed by a release must not arrive as stop-then-start
and strand a notification with no session behind it.

`dataSync` is the foreground service type. `connectedDevice` is for companion
hardware, `mediaPlayback` and `location` would be lies, and `specialUse` needs
a Play Console justification for something an existing type already describes.
The cost is Android 15+'s cumulative six-hour daily budget for `dataSync`,
which is why the service implements `onTimeout` and shuts down cleanly rather
than being killed with a `ForegroundServiceDidNotStopInTimeException`.

The notification is deliberately plain: app icon, the host label, "Connected —
tap to return", `IMPORTANCE_LOW` so it is silent and never a heads-up, and no
action buttons. A "Disconnect" action would have to reach back into the Dart
isolate to tear the session down properly — a whole extra channel direction for
a control that is already one tap away inside the app. Tapping the body uses
the *launcher* intent, not a fresh `MainActivity` intent, because that is what
brings the existing task forward with its navigator stack intact.

`POST_NOTIFICATIONS` is requested at the moment the first session opens, with
no rationale dialog, and at most once per process. A denial is not fatal — the
service still runs and the session still lives; Android just hides the
notification. One wrinkle found on a device rather than in the docs: if the
permission is granted *after* `startForeground` has already run, the platform
does not go back and post the notification it dropped. `MainActivity` therefore
re-issues `startForeground` on the grant, which is what stops the very first
session a user opens from running with no way back into the app.

**The socket idles out.** A NAT mapping or a router state table can expire
under a shell that is sitting at a prompt, and nothing notices until the user
comes back and types. `SessionKeepalive` sends `keepalive@openssh.com` (with
`want_reply`, so the round trip proves the *server* is there) every 30 s for as
long as the session lives, and stops the moment the transport does.

dartssh2's `SSHClient` has a `keepAliveInterval` of its own, and it is switched
off (`keepAliveInterval: null` in `SshService.connect`) in favour of this. Three
reasons: one owner of the schedule rather than two, 30 s instead of 10 s on a
phone radio, and — the one that matters — `SSHKeepAlive` clears its in-flight
flag in a `finally` after an *unbounded* `await ping()`. A ping that never
answers, which is exactly what a silently dropped mapping looks like, latches
that flag and silences keep-alives forever. `SessionKeepalive` races each ping
against a timeout, so the next tick always gets its turn.

The interval is a constant, not a setting: it describes the middleboxes between
the phone and the server, not a preference a user could reason about.

**Nothing else needs to change on pause.** There is no `WidgetsBindingObserver`
anywhere in `lib/` and no lifecycle-driven teardown: `SessionController` owns
the transport, the panes own only their views, and a trip through `onPause`
touches neither. Coming back re-attaches to the same `Terminal` with its
scrollback intact. If the connection *did* die while the app was away,
`connection.done` has already fired, so the returning frame shows the ordinary
"connection closed" banner with the terminal read-only and the extra-key bar
gone — the same state a foreground drop produces.

---

## Host-key trust flow

This is the security core. The model is OpenSSH's, deliberately.

**Identity of a trusted key is `(hostname, port, key type)`** — the same
granularity as a `known_hosts` line. Scoping by key type is not a detail: a
server commonly holds both an ed25519 and an RSA host key, and which one is
presented depends on algorithm negotiation. Keying trust on `(host, port)`
alone would make an ordinary negotiation change look identical to an attack,
and users who are warned wrongly learn to click through warnings.

**The fingerprint is OpenSSH's.** `dartssh2` hands the callback a
`SHA256:<base64>` string, byte for byte what `ssh-keygen -lf` and `ssh-keyscan`
print. That is the whole point — the user can only meaningfully compare it
against something obtained out-of-band if the two strings look the same.

`HostKeyPolicy.evaluate()` has exactly three outcomes:

| Situation | Behaviour |
| --- | --- |
| Fingerprint matches the stored key for this host+port+type | Proceed silently. |
| No key stored for this host+port+type | **Trust on first use.** Neutral dialog showing key type + fingerprint, with a hint on how to verify it from the server console. Accept → persist, then proceed. Reject → abort. If the host is already known under a *different* algorithm, the dialog says so, so this prompt is not mistaken for an alarm. |
| A key **is** stored and differs | **Blocked.** Red dialog naming the machine-in-the-middle risk, showing the previously trusted and newly offered fingerprints side by side. The confirm button stays disabled until the user ticks "I verified this new key with the server owner". Accept → replace the stored key and proceed. Reject → abort. |

Dismissal by any route other than the accept button counts as reject
(`barrierDismissible: false`, and a null dialog result maps to `false`).

**Storage.** `known_hosts.json` in the app's documents directory. Fingerprints
are public data, not secrets, so confidentiality is not the concern here —
**integrity** is. Anyone who can rewrite that file can silence the MITM warning.

Since Phase 3 the file is an authenticated envelope:

```json
{"version": 2, "algorithm": "HmacSHA256", "mac": "<base64>",
 "payload": "{\"version\":1,\"hosts\":{\"<host>:<port>|<keytype>\":{...}}}"}
```

The HMAC key is 32 random bytes minted on first use and held in
`flutter_secure_storage` (Android Keystore / EncryptedSharedPreferences), so it
is not in the file it protects. The body is embedded as an opaque **string**
rather than a nested object on purpose: the bytes that were signed are exactly
the bytes that are verified, with no dependence on key ordering or number
formatting when the JSON is re-encoded. The MAC comparison is constant-time.

Three outcomes on load:

| Situation | Behaviour |
| --- | --- |
| MAC present and correct | Load normally. |
| No MAC, and no key has ever been established on this device | **Legacy migration.** A genuine Phase 1/2 file. Adopt it once, then immediately re-write it sealed. |
| MAC missing after a key exists, MAC wrong, key gone, or the file is unparseable | **Fail closed.** Load as empty, set `integrityFailed`, so every host reads as unknown and the user re-verifies. The host list shows a banner saying so, because a silently emptied trust store looks like a bug rather than a warning. |

That middle row is the one worth being careful about: accepting an unsealed file
unconditionally would let an attacker strip the envelope and downgrade their way
past the check, so it is gated on the device never having written a sealed file
before. Losing the Keystore key (app data cleared) also fails closed — the right
direction, since the alternative is trusting a file nothing can authenticate.

`KnownHostsService`'s public API is unchanged; the key is injected as an
optional `integrityKey:` constructor argument, and omitting it keeps the plain
Phase 1 format (which is what most unit tests use).

---

## SFTP browser and transfers

`SessionController.sftp()` yields a `RemoteFileSystem` — an interface over
`SftpService`, which wraps dartssh2's `SftpClient` so nothing above the service
layer sees `SftpName`, `SftpFileAttrs` or `SftpStatusError`. The interface also
exists so the transfer logic can be tested against a fake.

**Listing.** Starts at the SFTP realpath of `"."` (the user's home). Entries map
to `RemoteEntry` and sort directories-first, then case-insensitively. Symlinks
get their target `stat`ed — capped at 64 per listing, since each costs a round
trip — so a link to a directory navigates instead of trying to download. A
listing that fails with permission-denied leaves the user where they were with
an explanation, rather than on a blank screen.

**Downloads** go to the device's shared Downloads collection so they appear in
the user's file manager:

- API 29+: `MediaStore.Downloads` with `IS_PENDING`, cleared on completion.
  No permission is required — that is the point of scoped storage.
- API 23–28: the public `Download` directory, behind `WRITE_EXTERNAL_STORAGE`
  (declared with `maxSdkVersion="28"` and requested at runtime), then handed to
  the media scanner so it becomes visible.

This is a hand-written Kotlin method channel (`StorageBridge.kt`) rather than a
plugin. The plugins in this space either buffer the whole file in memory or
stage it in app-private storage and copy afterwards; here the SFTP read stream
is written straight into the MediaStore `OutputStream` chunk by chunk, with the
Dart side awaiting each write. That is what makes backpressure reach back to the
SSH channel and keeps memory flat on a multi-gigabyte transfer. It also adds
zero dependencies on a toolchain (AGP 9 / Kotlin 2.3) that has been unkind to
file-picking plugins. The same channel serves `ACTION_OPEN_DOCUMENT` for
uploads, staging the picked document into app cache so Dart can stream it with
plain file I/O.

**The queue** (`TransferQueue`) runs one transfer at a time and publishes the
whole task list after every change. Sequential on purpose: two concurrent SFTP
reads over one SSH connection share a TCP window, so they finish no sooner in
aggregate but make both progress bars crawl. Cancellation sets a flag on the
task's handle; the executor notices between chunks and the partial file is
`abort()`ed, because a truncated file sitting in Downloads looking complete is
worse than no file. A cancelled upload is `remove()`d from the server for the
same reason.

**Names.** Remote file names are attacker-controlled, so
`RemotePath.sanitiseFileName` reduces one to its last path segment, replaces
control characters, drops leading dots and caps the length before it is handed
to MediaStore — `../../evil.sh` saves as `evil.sh`. On a collision the user
picks Replace or Keep both (with "do this for the rest of this batch" when more
than one file is queued); Keep both lets the platform de-duplicate and the
resulting display name is read back rather than assumed.

---

## What later phases plug into

Nothing below requires changing the service layer.

### Phase 8 — clipboard and adaptive layouts

`session_screen.dart` is the file Phase 8 will touch most: it is where the
two panes are laid out, and it now also owns the foreground-service hold
(`_holdsForeground`, released exactly once from either the drop listener or
`dispose`). Splitting the `IndexedStack` into a side-by-side layout on a
tablet, DeX or an unfolded foldable must keep that hold on the *screen*, not
on a pane — two panes of one session are still one session, and the reference
count is there to make a second concurrent `SessionScreen` safe if one ever
appears.

`SessionScreen` is no longer a `const` constructor (its foreground-controller
default is a process-wide instance), which matters only if Phase 8 wants to
build it in a const context.

`terminal_pane.dart` holds the pinch-zoom pointer handling and the extra-key
bar, both of which are size-sensitive; the key bar is the obvious thing to hide
when a hardware keyboard is attached.

### Phase 9 — importing a private key from a file

The AWS EC2 flow: a user downloads `my-server.pem` and wants to pick that file
rather than open it in an editor and paste. "Import key file" in
`host_edit_screen.dart` adds `pickFileContent` to `StorageBridge.kt` — a
second `ACTION_OPEN_DOCUMENT` variant alongside the upload picker's
`pickFile`, reading the chosen document straight into memory as text
(`{name, content}`) rather than staging a copy in app cache, capped at 64 KB
on both the native side and again, independently, in
`private_key_import.dart`'s `classifyPrivateKeyPem` — which then runs the
picked text through the exact `SSHKeyPair.isEncryptedPem` /
`SSHKeyPair.fromPem` calls `SshService._parseIdentities` makes right before a
real connect attempt, so the file is validated without ever opening a socket
and without the key ever touching disk or a log: a key that decodes cleanly
fills the PEM field and names its algorithm in a snackbar, an encrypted key
fills the field and moves focus to the passphrase field, and anything else —
garbage, a non-key PEM block, or a format dartssh2 does not implement
(PKCS#8) — leaves the field untouched and explains why in a dialog naming the
file.

### Still open

Reconnect after a drop, port forwarding (`client.forwardLocal` /
`forwardRemote` are already available), and an agent (`agentHandler` is a
constructor parameter on `SSHClient`).

Remote-side file operations (rename, delete, mkdir, chmod) are the obvious next
thing in the browser. `SftpClient` already exposes `rename`, `remove`, `rmdir`,
`mkdir` and `setStat`; `SftpService` is where to surface them, and the entry
point is the per-entry bottom sheet that already exists in `file_browser_pane`.

---

## Testing

`flutter test` — 193 tests, no device or network server required.

- `test/known_hosts_service_test.dart` — persistence, case-insensitive host
  matching, per-port and per-key-type scoping, replacement, fail-closed on a
  corrupt store.
- `test/known_hosts_integrity_test.dart` — key minting and reuse, seal/open
  round trip, a doctored payload, a foreign key, envelope-stripping as a
  downgrade attack, legacy migration, a lost Keystore key, and the
  no-integrity-key path still writing the Phase 1 format.
- `test/host_key_policy_test.dart` — the full trust matrix: first use accept
  and reject, silent match, key change blocked, rejection leaving the original
  trusted, explicit rotation, survival across a store restart.
- `test/ssh_service_test.dart` — private key parsing against **real
  `ssh-keygen` output** (ed25519, RSA in both OpenSSH and PEM encodings, ECDSA;
  plain and passphrase-protected, plus missing/wrong passphrase), and socket
  error mapping (refused, unresolvable).
- `test/private_key_import_test.dart` — the "Import key file" classifier
  against real `ssh-keygen`/`openssl` output: every valid unencrypted format
  (OpenSSH, PKCS#1 RSA — the AWS EC2 shape, ECDSA, legacy SEC1 EC), OpenSSH and
  PKCS#1 passphrase-protected keys, garbage text, an empty file, a well-formed
  but non-key PEM block, PKCS#8 (unsupported), and the oversize cutoff on both
  sides of its boundary.
- `test/credential_store_test.dart`, `test/host_store_test.dart` — Phase 2
  persistence.
- `test/session_controller_test.dart` — session lifetime (transport drop,
  errored transport, a shell exiting without ending the session, idempotent
  dispose), the keep-alive running for exactly the session's lifetime and
  stopping on a drop as well as on dispose, SFTP opened once and shared, and
  the download/upload executor:
  progress, hostile-name sanitising, deferred size lookup, the overwrite flag,
  and `abort()` on both failure and cancellation.
- `test/session_foreground_test.dart` — the start/stop decision: the 0 → 1 and
  1 → 0 edges, a second session not starting a second service, a route pushed
  over another not stopping the live one, an extra release not driving the
  count negative, a release chasing a slow start rather than overtaking it,
  and a platform refusal not poisoning later calls.
- `test/session_keepalive_test.dart` — one timer at the fixed interval, no
  stacking on a repeat start, one ping per tick, stop cancelling and staying
  stopped, a failing ping not disabling the schedule, a tick landing on an
  unanswered ping being skipped rather than stacked, and the timeout that
  clears a ping which never answers.
- `test/transfer_queue_test.dart` — sequencing, progress publication,
  cancellation of queued and running tasks, failure isolation, aggregate
  progress, `clearFinished`.
- `test/remote_path_test.dart` — path arithmetic (including that an absolute
  path cannot climb above `/`), breadcrumbs, name sanitising and
  de-duplication, size formatting, and `RemoteEntry` sorting/classification.

`session_controller_test` fakes `SessionTransport` and `RemoteFileSystem`,
which is why those interfaces exist: dartssh2's `SSHClient`, `SSHSession` and
`SftpClient` cannot be usefully faked, but the two seams around them can.

Not covered without a live server: the authenticated handshake, the shell
channel, and real SFTP traffic. Not covered without a device: `StorageBridge.kt`
(MediaStore and the document picker). Those need an emulator or a real host —
see "Known gaps" in the handover notes.

---

## Android

- `minSdk = maxOf(flutter.minSdkVersion, 23)` — `flutter_secure_storage` 10.x
  requires 23 for the Keystore/EncryptedSharedPreferences path.
- Permissions: `INTERNET` (outbound TCP), `ACCESS_NETWORK_STATE` (so "no
  network" can be told apart from "host unreachable" in error text),
  `WRITE_EXTERNAL_STORAGE` capped at `maxSdkVersion="28"` for downloads on
  pre-scoped-storage devices only, `FOREGROUND_SERVICE` +
  `FOREGROUND_SERVICE_DATA_SYNC` (the typed permission API 34+ requires to
  match the service's `foregroundServiceType`), and `POST_NOTIFICATIONS`,
  requested at runtime when the first session opens.
- `SessionForegroundService` is declared with
  `foregroundServiceType="dataSync"`, `exported="false"` and
  `stopWithTask="true"` — the session lives in the Flutter engine attached to
  `MainActivity`, so a service surviving a task swipe would be an ongoing
  notification with no connection behind it.
- `MainActivity` registers three channels: `StorageBridge` on
  `…/storage`, the `FLAG_KEEP_SCREEN_ON` toggle on `…/keep_awake`, and
  start/stop for the session service on `…/session_service`. It forwards
  `onActivityResult` / `onRequestPermissionsResult` to `StorageBridge`, and
  handles the `POST_NOTIFICATIONS` result itself. Platform I/O for storage runs
  on a single-thread executor and replies on the main looper, so a slow write
  never blocks the UI thread and chunk ordering is preserved.
- `android:label="SecureShell Go"`.
- `windowSoftInputMode="adjustResize"` (Flutter default) is what lets the
  terminal shrink when the soft keyboard opens, which in turn fires the resize
  that reaches the PTY.
