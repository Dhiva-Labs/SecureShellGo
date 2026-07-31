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
    syntax_token.dart           TokenKind + HighlightSpan for the editor

  services/                     all I/O and protocol work, no Flutter imports
    known_hosts_service.dart    the trusted-key store (sealed JSON on disk)
    known_hosts_integrity.dart  the HMAC envelope + its Keystore-held key
    host_key_policy.dart        the trust decision: first use / match / changed
    ssh_service.dart            connect, authenticate, map errors to human text
    secure_storage_backend.dart the Keystore seam (fake-able in tests)
    credential_store.dart       saved passwords/keys, per host
    host_store.dart             hosts.json
    session_controller.dart     one live session, shared by terminal + browser
    session_manager.dart        every open session, and which one is in front
    terminal_workspace.dart     the desktop pane tree: splits, ratios, bindings
    session_keepalive.dart      the 30 s keep-alive schedule for a live session
    session_foreground.dart     refcount + channel for the foreground service
    sftp_service.dart           RemoteFileSystem over dartssh2's SftpClient
    transfer_queue.dart         the download/upload/across queue + progress model
    upload_plan.dart            remote name collisions: the decision, not the UI
    download_plan.dart          walks a remote directory into a download plan
    remote_copy.dart            streams a file from one server to another
    remote_transfer_plan.dart   what a batch is called on the destination server
    remote_path.dart            POSIX path arithmetic, name sanitising, sizes
    device_storage.dart         Dart half of the MediaStore / picker channel
    share_intake.dart           files arriving from other apps' Share menus
    private_key_import.dart     classify a picked key file, no socket needed
    editor_document.dart        binary sniff, UTF-8 decode, line-ending style
    syntax_highlighter.dart     hand-rolled per-language tokenizers, no deps
    editor_search.dart          find/replace: plain and regex, counts, go-to-line
    editor_save.dart            the conflict guard + temp-then-rename save-back

  screens/
    host_list_screen.dart       home: saved hosts, connect, "browse files"
    host_edit_screen.dart       add/edit a host
    known_hosts_screen.dart     manage trusted host keys
    share_target_screen.dart    "upload to…" host picker for an incoming share
    session_screen.dart         owns the session; hosts the two panes
    terminal_pane.dart          xterm view wired to the SSH shell channel
    file_browser_pane.dart      SFTP browser, uploads and downloads
    remote_editor_screen.dart   the tabbed text editor: find, save, conflicts
    workspace_view.dart         draws the pane tree: dividers, headers, focus

  widgets/
    host_key_dialog.dart        the accept/reject host key UI
    terminal_key_bar.dart       Esc/Tab/Ctrl-x/arrows row for soft keyboards
    transfer_panel.dart         transfer summary bar + transfers bottom sheet
    code_editor_field.dart      highlighting controller + scroll-synced gutter

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
  └─ SessionManager.open(connection, initialView)   ← Phase 12: not a route
       │
       ├─ SessionForegroundController.acquire(label)  ← process stays alive
       │
       ├─ SessionController(connection)         ← owns the transport from here
       │    ├─ shell(columns, rows)  → opened once, cached
       │    ├─ sftp()                → opened once, cached (2nd channel, same auth)
       │    ├─ transfers: TransferQueue
       │    ├─ SessionKeepalive      → connection.ping() every 30 s
       │    └─ connection.done ─────► isClosed / closeReason → banner
       │
       └─ SessionsScreen (pushed once, shows them all)
            └─ IndexedStack, one page per session
                 ├─ TerminalPane(session)      xterm ⇄ shell channel
                 └─ FileBrowserPane(session)   SFTP listing + transfers

SessionManager.close(id): release the service, stop keep-alives, cancel
transfers, close sftp, close shell, close connection. Popping the screen does
none of that — see Phase 12.
```

Notes on the parts that are easy to get wrong:

**Ownership.** Phase 1 let `TerminalScreen` own the `SshConnection` and close it
in `dispose()`, which was right while the terminal was the only thing on the
connection and wrong the moment a file browser wanted the *same* authenticated
transport. Ownership sits in `SessionController`, and since Phase 12 that
controller is held by `SessionManager` rather than by a route: the session
outlives either pane *and* the screen showing it, and ends only when the user
closes that session or the transport dies. Switching between the shell and the
file browser does neither, and nor does switching between sessions —
`IndexedStack` keeps every pane of every session alive, so a running `htop`
survives a trip to the file list, to another server, and back.

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

## Moving files in both directions (Phase 10)

Phase 3 could upload. Nobody could find it: one `upload_file` icon in a row of
icons, one file at a time. Phase 10 is mostly about making the *other*
direction as obvious as tapping a file is, and the shape of the work follows
from that — every piece below is a discoverability fix with a small amount of
capability behind it.

**"Upload here" is the browser's primary action.** An extended FAB inside
`FileBrowserPane`, labelled rather than iconic, naming the destination in its
tooltip and in the snackbar it produces ("Uploading 3 files to /srv/www").
The FAB lives on a `Scaffold` *inside the pane*, not around the whole screen:
in the side-by-side tablet layout the browser is one half of a `Row`, and a
button anchored to the window would float over the terminal. The transfer
summary bar is that Scaffold's `bottomNavigationBar`, so the FAB sits above it
by construction and can never cover it, and the list carries 88 px of bottom
padding so the last row is never the one hiding underneath. The icon in the
action bar stays for the muscle memory of anyone who found it.

**Uploads are multi-file.** `pickFiles` adds `EXTRA_ALLOW_MULTIPLE` to the
same `ACTION_OPEN_DOCUMENT` intent and stages the lot; the single-file
`pickFile` is untouched, because private-key import and other callers have no
use for a list.

**Collisions are decided, then executed.** `upload_plan.dart` holds the
decision as a pure function: given the names being uploaded, the names already
in the directory (one listing, not one `stat` per file) and a prompt callback,
it returns what each file should be called and whether it replaces anything.
Keeping it out of the widget is what makes "apply to all", "keep both" and
"skip" testable, and it lets `RemotePath.deduplicate` — written for downloads
in Phase 3 — serve the upload side unchanged rather than growing a second,
subtly different implementation. Names claimed earlier in a batch join the
taken set as they are assigned, so two files called `photo.jpg` cannot
silently collapse into one. A dismissed prompt cancels the batch: it is never
read as consent to overwrite someone's file on a server.

**The share sheet is the discoverability win.** `ACTION_SEND` and
`ACTION_SEND_MULTIPLE` for `*/*` put SecureShell Go in every other app's Share
menu, which is the shortest path from "this file" to "on my server". The
platform side records the intent's URIs and stages them only when Dart asks
(`takePendingShare`), so sharing a 2 GB video does not stall a cold start.
Cold start and warm arrival are the same code path — the app pulls, rather
than being pushed a payload — with `onNewIntent` merely nudging it to pull.

`ShareTargetScreen` then asks *where*: a saved host, then the ordinary file
browser to choose the directory, with the files held on the
`SessionController` (`pendingUpload`) rather than published as an event, since
the browser pane may not exist yet when the share lands. A host that is
already connected is reused through `SessionRegistry` — same credentials, same
host-key check, same foreground service — and `bringToFront` pops the picker
off rather than stacking a second session on the same machine. A host that is
not connected gets the normal connect path, host-key verification included: a
share is not a reason to trust a key that has not been verified.

This is why `MainActivity` is `singleTask` with the app's own task affinity.
Under the template's `singleTop` + `taskAffinity=""`, a share (which always
carries `FLAG_ACTIVITY_NEW_TASK`) started a *second* activity in a second
task: two Flutter engines, two isolates, and so two of everything the app
treats as process-wide — including the registry a share looks in and the
foreground-service reference count. Observed on the emulator before the fix.

**Downloads say where they went.** A finished download's `content://` URI now
rides along on the task, so both the completion snackbar and the transfer
panel can offer "Open" — an `ACTION_VIEW` chooser, with the read grant riding
on the intent because this app inserted the MediaStore row and can pass access
to whatever the user picks. The Downloads folder is still the only
destination; there is no picker to get wrong.

**Directories download whole.** `download_plan.dart` walks the tree first and
hands back a plan — file count, total size, what it skipped — so the confirm
dialog can say "412 files, 1.8 GB" about the one thing in this browser whose
size is invisible from the row that was tapped, and so the walk can be
cancelled while it is still only round trips. Symlinks are not followed in
either direction: a link to a directory can point back up its own tree
(`ln -s .. loop`) and turn the walk into an infinite one, and a link to a file
would fetch the same bytes twice; they are counted so the dialog can say what
was left out. A directory that will not list is recorded and stepped over
rather than failing the whole download. Each planned file carries the
subdirectory it belongs in, which `StorageBridge.beginDownload` turns into
MediaStore's `RELATIVE_PATH` — sanitised on both sides, since every segment of
it came out of a remote listing.

**Failures are retryable.** `TransferQueue.retry` re-queues a failed transfer
as a fresh task and drops the row it failed on. Only failures: a cancelled
transfer is a decision the user made, not something to offer to undo behind a
button marked "retry".

One trap this theme sets, caught on the emulator twice now: `AppTheme.dark`
gives `FilledButton` a `minimumSize` of `Size.fromHeight(48)`, whose width is
`double.infinity`, so that a button on its own in a column fills it. Put one of
those in a `Row` without overriding `minimumSize` and it demands infinite
width — layout throws, and because the failure is inside a `Scaffold` slot the
*whole* screen renders as an app bar over a blank page with nothing on the
device to say why. Every `FilledButton` in a `Row` in this app passes its own
`minimumSize` for that reason.

Two smaller things the emulator caught, both worth keeping in mind when
touching this area: the summary bar used to call every finished transfer
"saved to Downloads", which is the opposite of what an upload did; and
completion snackbars are now raised when the queue goes quiet rather than per
file, because a recursive folder download finishes hundreds of times and
hundreds of queued snackbars take minutes to drain past a user who has moved
on. The browser refreshes its listing on the same "queue is quiet" signal, so
an upload appears where it landed without costing a listing per file.

---

## Several sessions at once, and files between them (Phase 12)

### Where a session lives

Phase 3 lifted ownership of the connection out of the terminal and into a
`SessionController` held by `SessionScreen`. Phase 12 lifts it once more, out
of the widget tree entirely and into `SessionManager`, built in `main.dart` and
passed down like every other service.

The reason is the same shape as last time. As long as a route owned the
session, the only way to reach the host list — which is where a *second*
session comes from — was to tear the first one down. So:

```
main.dart
  └─ SessionManager                    the sessions, in the order they opened
       ├─ ManagedSession               id, SessionController, view, filesBuilt
       ├─ ManagedSession
       └─ …
            each: shell, SFTP channel, TransferQueue, keep-alive,
                  one foreground-service hold

HostListScreen  ──push──►  SessionsScreen        (pop leaves them all running)
       ▲                        │
       └────── "New session" ───┘
```

`SessionsScreen` owns nothing but the view. Popping it returns to the host
list with every session still connected; the list says so in a bar that leads
back. Closing a *tab* is what ends a session, and closing the last one releases
the foreground hold and pops the screen. This is the one behavioural change to
an existing flow: the back gesture used to disconnect and now does not. The
app-bar power button still does, which is the control that always meant it.

**Every session is in the widget tree at once**, inside an `IndexedStack`. That
is not an optimisation, it is the requirement: a `htop` in the session behind
this one keeps running and keeps redrawing into its own `Terminal`, because its
`TerminalPane` was never disposed. Each child is a `_SessionPage` keyed by
session id, which is where that session's pane `GlobalKey`s, terminal focus
node and announcement subscriptions live — a widget per session rather than a
map of per-session state on the screen.

Two consequences of "all of them are live" that had to be handled explicitly:

- **Focus.** Every `TerminalView` is focusable, so without care the keystroke
  after a tab switch goes to a terminal the user cannot see. Inactive pages are
  wrapped in `ExcludeFocus`, `TerminalPane` takes its `FocusNode` from the page
  above it, and `autofocus` is true only for the session in front. Coming to
  the front re-requests focus in a post-frame callback, because `ExcludeFocus`
  only stops excluding as part of the build that is already running.
- **Per-session state.** `view`, `filesBuilt` and the "have we announced this
  drop yet" flag were fields on `_SessionScreenState`. With one session that
  was the same thing; with several it is not — a screen-held copy means
  switching tabs reshuffles the *other* session's panes. `view` and
  `filesBuilt` moved to `ManagedSession`; the disconnect announcement moved to
  `SessionController.takeDisconnectAnnouncement`, alongside the download
  announcer and for the same reason.

**The foreground service** already reference-counted, which is what made this
cheap: the manager acquires per session and releases per close, so the 0 → 1
and 1 → 0 edges land exactly once. What it could not do was *say* how many —
`acquire` only labels on the 0 → 1 edge, deliberately, so a second session
cannot rename a notification out from under the first. `relabel` is the
explicit version, and the manager calls it when the count changes: one session
is named, several are counted ("2 sessions connected"), and closing back down
to one names the survivor. A session whose transport has dropped keeps its hold
until its tab is closed — it is still a tab with a banner on it, and the
process has to live long enough for the user to see that.

**Connecting to a host that is already open asks.** A second session to the
same machine is legitimate (a build in one shell, a `tail -f` in another) but
never accidental, and it costs a second authentication, so the host list offers
*Switch to it* / *New session* / *Cancel* — with cancel as the dismiss default.
Sessions are identified per open, not per host, so two on one machine are two
independent entries everywhere.

`SessionRegistry` is gone. It existed to answer "is this host already open, and
how do I get back to it" for the share sheet; the manager answers that and more
(`liveForHost`, `select`), so keeping a second, partial list of the same thing
would only be somewhere for the two to disagree.

### Server to server

Moving a file between two connected machines used to mean downloading it and
uploading it again, which needs device storage for something the device has no
use for. `remote_copy.dart` streams it instead:

```
source SFTP read stream ──chunk──► RemoteFileWriter.add ──► destination SFTP
        ▲                                                        │
        └──────────── await, so the read pauses ◄────────────────┘
```

**Backpressure** is the same chain the MediaStore download path uses.
`RemoteFileSystem.download` awaits its `write` callback before pulling the next
chunk; that callback is the destination's `RemoteFileWriter.add`, which
completes when the destination acknowledges. A slow destination pauses the
source's stream, which stops draining the SSH window, which stops the source
sending. The high-water mark is the source's read-ahead (`chunkSize` ×
`maxPendingRequests`) plus one chunk in flight — flat, whatever the file size.
Reusing `download` rather than writing a second read loop is deliberate: there
is one chunked-read implementation in this app and it is the one that has been
run against real servers.

**Nothing appears under the final name until it is complete.** The bytes go to
`.<name>.ssg-part-<millis>` in the destination directory and are renamed into
place at the end. That gives three things at once: a cancelled copy cannot
leave a truncated file looking real, a cancelled *replace* cannot destroy the
file it was replacing (a straight truncating write would have), and "is it
finished" has a single answer to check.

**A move is a copy, then a delete, and the delete waits.** Deleting the only
remaining copy of something is the one operation here that cannot be walked
back, so `deleteSourceAfterVerify` removes nothing until all four hold: every
chunk write was acknowledged; the destination handle closed cleanly; a fresh
`stat` of the destination *under its final name* reports exactly the bytes that
were streamed; and a fresh `stat` of the source still reports that same number,
so a file that grew underneath the copy is not deleted on a stale read. Any of
those failing leaves both files and says why — two files and a message beats
none and a message. A content hash of both ends would be stronger and is not
done: it needs a second full read of both files, and hashing remotely means
running a command on the shell channel, which a file transfer should not
quietly do on someone's server.

**Which queue.** The transfer goes on the *source* session's `TransferQueue`,
as a third `TransferDirection.serverToServer`. That is the session the user
started it from and the one whose channel does the reading, so it takes its
turn behind that session's other transfers instead of competing with them. The
destination is carried as a *session id*, not an object, and resolved when the
transfer runs: a retry rebuilds the task from its fields, and a destination
closed in the meantime fails the transfer with something worth reading rather
than writing into a dead channel. Both sessions stay usable throughout — SFTP
requests multiplex, so browsing either end while bytes move is ordinary.

The destination's file browser has no sight of the source's queue, so it is
told: `SessionController.reportArrival` emits the directory that was written
into, and a browser showing that directory re-lists. Same idea as the "queue
went quiet" refresh uploads use, from the one angle that signal cannot reach.

**Collisions reuse `upload_plan.dart` whole.** "These names are about to be
created in that directory; which collide and what happens to each" is exactly
the question the upload side already answers, including apply-to-all, keep-both
through `RemotePath.deduplicate`, and a dismissed prompt cancelling rather than
overwriting. `remote_transfer_plan.dart` is a thin wrapper that filters the
selection and hands the names over.

**Directories are first-class since Phase 12.5.** `remote_transfer_plan.dart`
no longer filters them into `unsupported`: a folder in a selection goes through
the same [UploadPlan] the file collision path uses, so a `Documents/` folder
on both ends gets the same replace/keep-both/skip prompt a file collision
does, and the answer cascades to every file inside. There are two executors
below that plan:

- **Relay** (`copyRemoteDirectory` in `remote_copy.dart`): walks the source
  tree over the source's SFTP channel, mkdir's the shape on the destination
  (empty subdirectories included), then copies each file through
  `copyRemoteFile` — one at a time, so the SSH window is not shared between
  concurrent reads and so a cancel or a per-file failure aborts the whole
  batch with the source untouched. On a top-level `replace`, the destination
  tree is torn down via `removeRemoteDirectoryTree` before the mkdir + copies
  run. Move semantics: each per-file copy runs with `deleteSourceAfterVerify`
  and its four-check safety chain, and after every file has left, the source's
  subdirectories are rmdir'd bottom-up. A cancel or failure mid-batch never
  runs the rmdir loop, so a partial move is visible on both sides rather than
  under a half-empty tree.

- **Direct** (`copyRemoteDirectoryDirect` in `direct_remote_copy.dart`): the
  source-side `sftp` batch runs `put -r SRC DST` in one exec channel. From A's
  perspective SRC is on its own filesystem, so `put` reads it locally; DST is
  B, over an SSH connection A opened using the forwarded agent. Overwrite
  clears the destination via `removeRemoteDirectoryTree` on B (through our
  trusted SFTP channel to B, not A's sftp) before `put -r` fills a fresh tree.
  Verification is whole-batch: file count and total bytes on B must match A
  before either the exec's success is trusted or a move deletes the source
  tree. A verified mismatch or a cancel wipes the partial tree on B via
  `removeRemoteDirectoryTree` so nothing left behind looks complete.

The download side keeps its own `download_plan.dart` — its `relativeDirectory`
is sanitised for MediaStore, which replaces `:*?"<>|`, strips leading dots and
caps segments at 80 characters. That is all correct for Android and all wrong
for a POSIX destination (`.git` would silently become `git`), which is why the
S2S folder path does not go through the download planner.

**Drag-and-drop across tabs is a second entry point, not a second path.** The
file browser's rows are `LongPressDraggable<TabDropPayload>` on desktop
platforms, each tab in `SessionTabStrip` is a `DragTarget<TabDropPayload>`, and
an accepted drop hands off to the same `sendEntriesToSession` function that
the per-entry "Copy to another server…" action sheet calls. That function is a
top-level in `file_browser_pane.dart` precisely so both callers can reach it —
the state-owned `_sendToServer` becomes a thin wrapper that picks the
destination first and then calls the same function. The bytes still move
through `queueRemoteCopy` on the source session's queue, `remote_copy.dart`
still runs, and every promise `remote_copy.dart` makes about backpressure,
staging under `.<name>.ssg-part-<millis>`, and the four-check
`deleteSourceAfterVerify` chain holds unchanged.

The payload is a public `TabDropPayload{sourceSessionId, entries,
sourceDirectory}`. Public because `session_screen.dart`'s tab target must
know its shape at compile time — a `DragTarget<TabDropPayload>` silently
refuses payloads of any other type (a footgun `session_manager_test.dart` has
learned to expect: no callback fires and no error is logged, the drop just
does not land). Same-session drops are refused earlier still, in
`onWillAcceptWithDetails`, so a tab under its own file never highlights and
releasing on it counts as a cancel. Drag is desktop-only on purpose: on
Android and iOS a long-press on a row is what opens the action sheet, which
is the only path into multi-select on a touch device, and a
`LongPressDraggable` there would swallow the gesture. The per-entry sheet's
"Copy to another server…" row is what those users have and always did.

If the drag starts while a selection is active, the payload carries every
selected file — non-selected rows keep their old long-press-to-toggle
behaviour, so entering and adjusting the selection still works during a
drag-heavy workflow. The selection is cleared on `onDragCompleted`, not on
cancel: a drag ended over empty space is the user changing their mind, not
their commit to send.

---

## The split workspace, on desktop only (Phase 13)

Several sessions have been open at once since Phase 12; Phase 13 is about
seeing more than one of them at a time. On Linux, Windows and macOS the
terminal area splits into up to four panes, each showing one open session.
Android and iOS are untouched — `SessionsScreen` gates on the platform (the
same `Theme.of(context).platform` switch `FileBrowserPane` uses for
drag-and-drop) and the phone build never so much as reads the workspace.

```
TerminalWorkspace                      pure Dart, built in main.dart
  root: WorkspaceNode                  sealed: WorkspacePane | WorkspaceSplit
    WorkspacePane   { id, sessionId? } one rectangle, at most one session
    WorkspaceSplit  { id, axis,        two children and the divider between
                      first, second,   them; `ratio` is first's share
                      ratio }
  focusedPaneId                        exactly one, always a live pane
  syncSessions(ids, activeId)          ← SessionManager changes
  visibleSessionIds / visibleSessions()  ┐ the broadcast seam
  writeToVisibleSessions(data)           ┘
```

**Why a controller rather than widget state.** The interesting part of a split
view is tree arithmetic — splicing a split in above the pane being split so
nothing already on screen jumps to a different corner, collapsing a split back
into its surviving child when one side closes, keeping the focus on a pane
that still exists after either. None of that needs a widget tree to be true,
so none of it is in one. It is built in `main.dart` next to `SessionManager`
and for the same reason: going back to the host list to open another server
tears the sessions screen down, and coming back has to find the splits, the
dividers and the bindings where they were left.

**A session is bound to at most one pane.** Two panes on one session would be
two `TerminalView`s over one `Terminal`, each reporting its own column count
into the same `onResize` — the PTY would be resized twice a frame to two
different sizes. So `showSession` *swaps*: putting B into the pane showing A
gives A's pane whatever B's pane was showing. Dragging one onto the other
therefore trades places, which is what the gesture looks like it should do.

**Panes are layout, sessions are sessions.** Closing a pane does not close
anything: the session keeps running, keeps its transfers, and is one click
away in the tab strip. Closing a *tab* empties whichever pane was showing it
rather than rearranging the tree, because the layout is the user's.

**Everything stays in the tree.** A session with no pane of its own is still
built and still laid out at the workspace's full size — it is merely never
painted (`Visibility` with `maintainSize`). That is the same bargain the
phone layout's `IndexedStack` makes, and it is what keeps a background `htop`
running at a width it will not have to reflow from. The screen holds one
`GlobalKey` per session so moving one between panes reparents its page
instead of resetting its file browser and re-opening its SFTP channel.

**The broadcast seam.** "Type once, send to every visible pane" is not built
yet and has no UI. What is built is the pair of questions it needs answered —
which shells is the user looking at, and put this in all of them — because
both belong to whatever owns the layout. `WorkspaceSession` is deliberately
two members wide (`id`, `writeInput`): the workspace holds session *ids*, and
a resolver injected in `main.dart` turns one into a `LiveWorkspaceSession`
over the real `SessionController`. `writeInput` goes through
`Terminal.textInput`, the same door the extra-key bar and the soft keyboard
use, so a broadcast write is indistinguishable from typing.

---

## What later phases plug into

Nothing below requires changing the service layer.

### Phase 8 — clipboard and adaptive layouts

`session_screen.dart` is the file Phase 8 touched most: it is where the two
panes are laid out. Splitting the `IndexedStack` into a side-by-side layout on
a tablet, DeX or an unfolded foldable had to keep the foreground hold on the
*session*, not on a pane — two panes of one session are still one session, and
the reference count was there to make several concurrent sessions safe if they
ever appeared. Phase 12 is when they did, and the hold moved off the screen
entirely and onto `SessionManager`.

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

Remote-side file operations (rename, delete, chmod) are the obvious next
thing in the browser. `RemoteFileSystem` gained `remove` and `rename` in Phase
12 for the server-to-server path — and `mkdir`, `removeDirectory` and
`isDirectory` in Phase 12.5 for the recursive folder copy — so most of it is
already there and tested; `SftpClient` also exposes `setStat`, and the entry
point is the per-entry bottom sheet that already exists in `file_browser_pane`.

The **local-folder upload path** for Android is a documented gap: desktop
uses `file_selector`'s `getDirectoryPath()` via `DesktopDeviceStorage`, but
`StorageBridge.kt` does not yet handle `ACTION_OPEN_DOCUMENT_TREE` and resolve
a SAF tree URI into a path the `readLocalDirectoryTree` walker can traverse.
The browser hides the "Upload folder" entry on Android rather than showing a
picker that would fail.

---

## Testing

`flutter test` — no device or network server required.

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
- `test/session_manager_test.dart` — the multi-session lifecycle: opening,
  switching, closing, and what each of those must *not* touch. A second
  session to the same host being its own thing; the view each session is
  showing staying its own; the foreground count and the notification label
  across open/close, including a dropped session keeping its hold until its
  tab closes and the last close stopping the service; transfer queues being
  per session; and the destination resolver refusing a session that is
  closed, dropped, unknown, or itself.
- `test/remote_copy_test.dart` — the server-to-server stream against a fake
  source and sink: bytes across, progress, and the read side never getting
  more than one chunk ahead of the write side (the whole flat-memory story in
  one assertion). Then everything about not lying: nothing under the final
  name until the rename, a cancel mid-stream leaving no file and no deleted
  original, a cancelled *replace* leaving the file it was replacing intact, a
  refused write taking its partial with it, and a short write caught by the
  size check before any rename. Then move-after-verify: deleted only on a
  confirmed size, and kept when the destination reports the wrong size,
  reports nothing at all, or the source changed underneath the copy.
- `test/remote_transfer_plan_test.dart` — that the destination's collisions
  are the upload decision and not a second one: replace, keep both (through
  the same de-duplication), skip, apply-to-all, a dismissed prompt cancelling
  the batch, two files of one name in a batch, a directory that will not list
  falling back to probing, and directories/links being named and left out.
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
- `test/terminal_workspace_test.dart` — the pane tree with no widgets in
  sight: splitting in place and nesting, the four-pane cap, a sibling taking
  over the space when a pane closes, the last pane refusing to, the focus
  always landing on a pane that exists, divider ratios clamped away from both
  ends and unmoved by a collapse elsewhere, one session never in two panes
  (and the swap that keeps it that way), `syncSessions` emptying a pane whose
  session closed and putting a newly opened one in the focused pane, and the
  broadcast seam — reading order, empty panes and dead bindings skipped,
  `skipFocused`, and a workspace with no resolver answering honestly.
- `test/workspace_view_test.dart` — the pane chrome: no header, divider or
  focus border while there is one pane; exactly one pane outlined once split;
  a click anywhere in a pane taking the focus; the pane menu splitting and
  closing, and greying "Split right" out at the cap; the header picker
  swapping two visible sessions; the divider dragging, and refusing to drag a
  pane shut; and the empty pane offering every open session.
- `test/session_workspace_test.dart` — the screen around it: Android getting
  the tabbed layout with no split control and a workspace that was never told
  anything, desktop adopting the front session, every session built whether or
  not it has a pane, the app-bar split putting two servers on screen at once,
  a session opened while split landing in the focused pane, closing a pane
  leaving both sessions connected, and the app bar following the focused pane.
- `test/transfer_queue_test.dart` — sequencing, progress publication,
  cancellation of queued and running tasks, failure isolation, aggregate
  progress, `clearFinished`, and retry (a failed download re-queued with its
  save name, overwrite flag and relative directory intact, an upload retry
  keeping its staged source, and completed/cancelled/unknown tasks refusing).
- `test/upload_plan_test.dart` — the remote-collision decision: no collision
  asking nothing, replace/keep both/skip, a dismissed prompt cancelling the
  batch rather than overwriting, "apply to all" for each of the three
  choices, and collisions *within* a batch (two picked `photo.jpg`, and a
  name freed by "keep both" not being handed out twice).
- `test/download_plan_test.dart` — the recursive walk against a scripted
  tree: every file found and totalled, the subdirectory structure mirrored
  under the folder name, a symlink loop (`ln -s ..`) not followed and never
  even listed, a link to a file skipped rather than fetched twice,
  cancellation throwing instead of returning a partial plan, an unreadable
  subdirectory recorded rather than fatal, hostile names unable to steer a
  file out of its folder, and the file/depth caps.
- `test/share_intake_test.dart` — the share payload: a batch of staged files,
  a bare list, null and malformed shapes, one unusable entry costing only
  itself, name and size fallbacks, and the channel round trip for both the
  cold-start pull and the warm `shareAvailable` nudge.
- `test/remote_path_test.dart` — path arithmetic (including that an absolute
  path cannot climb above `/`), breadcrumbs, name sanitising and
  de-duplication, relative-directory sanitising for a recursive download's
  MediaStore path (no `..`, no absolute paths, depth and length caps), size
  formatting, and `RemoteEntry` sorting/classification.

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
- `MainActivity` registers four channels: `StorageBridge` on `…/storage`, the
  share intake on `…/share`, the `FLAG_KEEP_SCREEN_ON` toggle on
  `…/keep_awake`, and start/stop for the session service on
  `…/session_service`. It forwards `onActivityResult` /
  `onRequestPermissionsResult` to `StorageBridge`, hands `onNewIntent` to it
  so a share arriving at a running app is recorded (then nudges Dart), and
  handles the `POST_NOTIFICATIONS` result itself. Platform I/O for storage
  runs on a single-thread executor and replies on the main looper, so a slow
  write never blocks the UI thread and chunk ordering is preserved.
- `launchMode="singleTask"` with the app's own task affinity, so a share and
  the launcher land in the same activity — see Phase 10 above for what the
  template's `singleTop` + `taskAffinity=""` did instead.
- Two `<intent-filter>`s for `ACTION_SEND` and `ACTION_SEND_MULTIPLE` on
  `*/*`, which is what puts the app in other apps' Share menus.
- `StorageBridge`'s method surface: `ensurePermission`, `downloadExists`,
  `beginDownload` / `writeChunk` / `finishDownload` / `abortDownload`,
  `openDownload`, `pickFile`, `pickFiles`, `pickFileContent`, and
  `takePendingShare` on the share channel. `downloadExists` and
  `beginDownload` take a `relativePath` under `Download/`; picks and shares
  stage into a per-batch cache directory (`uploads/b<timestamp>-<n>/<i>/`),
  swept by age rather than cleared wholesale, since clearing would delete the
  file an upload queued a minute ago is still streaming.
- `android:label="SecureShell Go"`.
- `windowSoftInputMode="adjustResize"` (Flutter default) is what lets the
  terminal shrink when the soft keyboard opens, which in turn fires the resize
  that reaches the PTY.
