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
    host_ai_access.dart         HostAiAccess: off / readOnly / askToChange, unknown reads as off
    host_ai_edit.dart           what the user touched in one AI form, so a save writes only that
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
    headless_dialer.dart        the no-prompt SSH dial shared by fleet and the bridge
    allowed_command_check.dart  why an allowed-commands entry is refused (names the reason)
    assistant_drive.dart        who has the keyboard in an assistant's terminal session
    visible_text.dart           makes hidden or look-alike characters visible (the card, the allowed list)
    assistant/                  the built-in assistant: providers, loop, key, settings
      assistant_service.dart      settings + key, builds the provider, creates conversations
      assistant_conversation.dart the tool loop as the built-in client; transcript; 40-call cap
      anthropic_provider.dart     Anthropic Messages API
      openai_provider.dart        any OpenAI-compatible chat completions endpoint
      assistant_http.dart         dart:io HttpClient, https-or-localhost rule, limits
    bridge_remote/              the phone side of phone control
      remote_bridge_controller.dart  one control session as state + actions
      remote_exec_channel.dart    the SSH exec command that starts `secureshellgo-mcp control`
      remote_controller_token_store.dart  the phone's saved token per computer (secure storage)
    bridge/                     the AI Bridge: MCP for local assistants; reads, and changes with permission
      bridge_policy.dart          the one place that allows, refuses or asks (decideBridgeCall)
      bridge_approvals.dart       the cards waiting for a person: caps, timeout, withdrawal
      bridge_grants.dart          timed approvals ("Allow for a while"), memory only
      bridge_change_tools.dart    run_command, write_file, service_action, run_on_hosts
      bridge_terminals.dart       open_terminal, send_input, read_screen, close_terminal
      bridge_paths.dart           the path guard: blocked secret locations
      bridge_redactor.dart        64 KiB cap, private-key blocks, scrub
      bridge_audit.dart           the on-device activity log (audit.log)
      bridge_host_directory.dart  the names an assistant sees for shared hosts
      bridge_client_store.dart    paired assistants: hashed tokens (bridge_clients.json)
      bridge_channel.dart         the local listener, the handshake, one line = one message
      bridge_locator.dart         endpoint.json + the launcher's half of the channel
      bridge_tool_types.dart      BridgeToolHost, BridgeToolSpec, BridgeToolKind
      bridge_tool_module.dart     the seam for tool groups in their own files
      bridge_jobs.dart            start_job and its tools; the server-side job layout; the registry
      bridge_desktops.dart        open_desktop and the desktop_* tools; the assistant desktop's lifecycle
      bridge_control.dart         the phone controller's app side: sessions, actions, sources
      bridge_control_protocol.dart  the phone controller's wire messages (pure Dart)
      bridge_control_launcher.dart  the launcher's `control` mode (first line = token, then relay)
      mcp_server.dart             hand-written JSON-RPC / MCP over a connection
      bridge_tools.dart           the seven read tools and the dispatcher every call goes through
      bridge_connections.dart     SSH transports for tools: open session, or headless dial
      bridge_service.dart         the facade main.dart builds; start/stop, lock, status
      bridge_launcher_locator.dart  the launcher command to show, per install kind
      bridge_cli_connector.dart   finds `claude`, runs the fixed plugin commands (the process seam)
      bridge_plugin_command.dart  the three manual terminal commands for the connect screen

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
    settings/ai_bridge_section.dart  Settings → AI Bridge: switches, blocked paths, paired assistants
    bridge_connect_screen.dart  "Connect an assistant": name, token once, launcher + snippet
    bridge_one_click_screen.dart  "Connect Claude Code": confirm, pair, run `claude`, undo on failure
    bridge_shared_hosts_screen.dart  "Shared hosts": the checklist of hosts an assistant may read
    bridge_audit_screen.dart    "AI Bridge activity": the activity log, newest first, with how each change was allowed
    assistant_chat_screen.dart  the built-in assistant's chat
    assistant_desktop_screen.dart  the viewer of an assistant's desktop (Take over / Stop)
    pair_phone_screen.dart      "Pair a phone": name, token once
    remote_approvals_screen.dart  the phone's "AI approvals" screen for one computer
    settings/assistant_settings_section.dart  Settings → Built-in assistant
    settings/phone_control_section.dart  Settings → Phone control

  widgets/
    host_key_dialog.dart        the accept/reject host key UI
    terminal_key_bar.dart       Esc/Tab/Ctrl-x/arrows row for soft keyboards
    transfer_panel.dart         transfer summary bar + transfers bottom sheet
    code_editor_field.dart      highlighting controller + scroll-synced gutter
    bridge_approval_card.dart   the approval card: what an assistant asks to change, and the answer
    bridge_approval_host.dart   raises that card over whatever screen is in front, one at a time
    host_ai_controls.dart       the per-host "AI access" section
    host_ai_level_picker.dart   the level choice, its ticks, confirmations and summary line
    host_ai_level_chip.dart     the level as a chip (host list, shared hosts)
    assistant_transcript.dart   the chat transcript
    remote_approval_card.dart   the approval card as the phone draws it

bin/
  secureshellgo_mcp.dart        the AI Bridge launcher: a stdio-to-channel pipe, no Flutter

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
| MAC missing after a key exists, MAC wrong, or the file is unparseable | **Fail closed.** Load as empty, set `integrityFailed`, so every host reads as unknown and the user re-verifies. The host list shows a banner saying so, because a silently emptied trust store looks like a bug rather than a warning. |

That middle row is the one worth being careful about: accepting an unsealed file
unconditionally would let an attacker strip the envelope and downgrade their way
past the check, so it is gated on the device never having written a sealed file
before. A file sealed under a key the device no longer has (keyring reset, data
moved from another machine) is not treated as tampering: the code reports it as
`rekeyed`, adopts the contents and re-seals them under the new key, because
whatever can delete the key could equally have read it and forged a seal. See
the comments in `known_hosts_integrity.dart`.

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
  B, over an SSH connection A opened using the forwarded agent. A's `sftp`
  trusts exactly one host key for B: the one this device verified on its own
  live connection to B (`SshConnection.hostKey`). `ssh-keyscan` on A supplies
  the public key, only a line whose SHA256 fingerprint matches is written to
  a `mktemp` known-hosts file, and `sftp` runs under
  `StrictHostKeyChecking=yes` with no global list. A scan showing a different
  key of that type is `hostKeyMismatch` and refuses outright; no key to pin
  falls back to relay. The pin runs before anything below touches B. Overwrite
  clears the destination via `removeRemoteDirectoryTree` on B (through our
  trusted SFTP channel to B, not A's sftp) before `put -r` fills a fresh tree.
  Verification is whole-batch: file count and total bytes on B must match A
  before either the exec's success is trusted or a move deletes the source
  tree. A verified mismatch or a cancel wipes the partial tree on B via
  `removeRemoteDirectoryTree` so nothing left behind looks complete.

**Direct copies are server-side jobs.** Where the app has a
`ServerJobStore` (always, outside unit tests), the direct path does not run
`sftp` inside an exec channel it holds: `server_side_job.dart` launches it
detached on the source (`setsid`, else `nohup`) in
`~/.cache/secureshellgo/jobs/<id>/`, the app hangs up the agent-forwarded
connection as soon as `sftp` has signed in, and follows the job's `exit`
file over the source's ordinary session. Closing the app, a dropped network
or a closed tab (`TransferHandle.isAbandoned`) leaves the job running; only
the user's Cancel stops it. The record survives restarts, and
`SessionManager` picks the job up again once its source and destination are
both open, so the steps that need the app — verifying on the destination,
a replace's swap, a move's delete — still happen, and never before the copy
is verified.

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

## AI Bridge

On Linux and Windows the app can act as a local MCP server, so an AI assistant
on the same computer can **read** from the servers the user shares, by name.
1.6.0 could only read. 1.7.0 adds tools that **change** a server, each only
where the user allowed it for that host and with a person's yes in the app
(the sections "Levels", "Changing, with permission" and "The terminal" below).
The bridge is off by default, and everything new in 1.7.0 is off until the
user switches it on. 1.8.0 adds full control per host, long-running jobs, a
desktop the assistant can see and use, a built-in assistant that works on
every platform, a phone that answers the approval cards, and a seam for tool
groups in their own files (the sections "Jobs", "The assistant desktop", "The
built-in assistant", "Phone control" and "The permission screens" below).

The bridge has two halves since 1.8.0. The **AI tools** (the tool host,
policy, approvals and their cards, timed approvals, the activity log) are
built on every platform, Android included, so the built-in assistant can use
them. The **local channel** (the listener, pairing, the launcher locator, the
CLI connector) exists only where the launcher ships:
`BridgeService.channelSupported` is true only on Linux and Windows, and
`BridgeService.localChannel` is false elsewhere, so no listener is ever
started there whatever the setting says. `main.dart` builds the
`BridgeService` everywhere and hands it to Settings and the host screens, so
the AI section of Settings, the per-host "AI access" controls, the activity
screen and the built-in assistant's chat exist on every platform. The groups
that need the channel (assistants on this computer, Phone control) hide
themselves when `bridge.localChannel` is false; the connect screens and
one-click still get only the channel half (`_channelBridge`).

```
AI client ──stdio──► launcher ──local channel──► app (lib/services/bridge/) ──SSH──► server
 (own process)      (bin/…mcp.dart)             McpServer → tools → policy
```

### Layers

- `bridge_channel.dart` is the transport and nothing else: it accepts a
  connection, runs the handshake (below), asks `BridgeClientStore.verify`
  whether the token is a paired assistant's, and from then on hands lines to
  whoever is listening. It knows no MCP. Until the handshake is done the peer
  is any local process, so it gets little: at most 8 connections in the
  handshake at once (newer ones are dropped on arrival), lines of at most
  4 KiB, 5 seconds for the whole exchange, and a refusal only after half a
  second. After it, a line is capped at 1 MiB, and a peer that lets more
  than 4 MiB of answers pile up unread is dropped.
- `mcp_server.dart` is JSON-RPC 2.0 over those lines: `initialize`, `ping`,
  `tools/list`, `tools/call`. A `BridgeToolResult` may carry an image (a
  desktop screenshot); it is sent as MCP image content (base64 and
  `mimeType`) before the text (`mcpToolResultContent`). It is hand-written because the bridge uses a
  sliver of the protocol and every pub dependency has to be vendored for the
  PPA build. A connection may have 16 requests in flight, and a batch may
  hold 16; past that a request is answered at once with "Too many requests
  in progress". It knows nothing about SSH; the tools come from a
  `BridgeToolHost`.
- `bridge_tools.dart` implements the seven tools (`list_hosts`,
  `server_stats`, `list_services`, `tail_log`, `list_dir`, `read_file`,
  `search_files`; the change and terminal tools are in
  `bridge_change_tools.dart` and `bridge_terminals.dart`, below), reusing
  `ServerProbeCommands`, `SystemdCommands`,
  `LogTailCommands` and SFTP. Arguments are checked against each tool's
  schema (unknown keys refused, strings without NUL or line breaks, numbers
  in range) and everything that reaches a shell is quoted by
  `shell_quote.dart`. The assistant never supplies command text. At most 4
  calls run at once with 32 waiting (a 33rd is refused as busy), and each
  call has 30 seconds, waiting included. Changes have 2 run slots of their
  own, apart from the 4 for reads, so a long command cannot starve reads (and
  the reverse); their queue is 32 as well. `list_hosts` and `server_stats`
  answer in JSON, the others in text; `server_stats` leaves the server's own
  hostname out unless "Show address and username" is on, since it is often
  the address.
- `bridge_connections.dart` gives a tool an SSH transport: the open session's,
  if the user has one (one more channel, no second sign-in), else a headless
  dial (`headless_dialer.dart`, the same no-prompt dial the fleet screens
  use) cached for 60 seconds after its last call, and never reused once the
  host has been edited. No bridge connection carries the user's SSH agent or
  X11 forwarding: every bridge dial strips both from the host
  (`BridgeConnections.withoutForwarding`), and the bridge does not borrow a
  session the user has open when that session or its saved host has agent or
  X11 forwarding on (`mayBorrow`): it dials its own. The reason was shown on
  a real sshd: once a session's shell has asked for forwarding, the server
  keeps the agent socket for every later command on that connection, so an
  exec channel the bridge opened on it could have used the user's agent. Credentials are read with
  `CredentialStore.loadQuiet`, for the host and every jump host, so a bridge
  call never shows a prompt in the app: a sealed vault, a keyring that cannot
  be read, an unsaved password or passphrase, a login question or a host key
  nobody has checked fails with "Ask the user to connect to it once in
  SecureShell Go". A changed host key fails as the alarm it is.
- `bridge_service.dart` is the facade `main.dart` builds. It starts and stops
  the listener as the setting changes (only with `localChannel`), reports
  status to the Settings section, and tears down client and SSH connections
  when the bridge stops. On every platform it applies the reactions that keep
  the tools honest: a lock withdraws every card and ends every grant,
  assistant terminal and module resource; a host stepped down, deleted or
  re-pointed loses its grants, cards and terminals; a revoked client loses
  everything it held. Switching the channel bridge off ends what channel
  clients hold and spares the built-in assistant's.
- `bridge_tool_module.dart` is the seam for tool groups in their own files
  (jobs and the desktop are the first two). A `BridgeToolModule` is registered
  with one entry in `BridgeTools(modules: [...])` in `main.dart`. Its
  `changeTools` (kinds `change`, `terminal`, `desktop`) are ordinary
  `BridgeChangeTool`s and run through the same path as `run_command`, card
  included; its own `specs` may only be `read`, `terminalUse`, `desktopUse` or
  `jobUse` (the tool host refuses anything else at construction), served by
  `call`. A module call gets a `BridgeModuleCall`: host resolution, `decide`
  (the policy with the spec's kind, this client's switch and the lock filled
  in), `withServer` (only for a host the last decision allowed), the abandon
  signal and `auditHost`. The tool host writes the one audit entry and redacts
  the text; an outcome from a module whose last decision was not an allow is
  replaced by a `not_decided` refusal. The bridge service tells modules about
  host and client changes, the channel going off, a lock and shutdown.
- `bridge_launcher_locator.dart` says which launcher command the connect
  screen shows, checked in this order:
  - the snap: `secureshellgo.mcp` (its executable is under `$SNAP`; `SNAP`
    alone is not trusted, since other snaps pass theirs on);
  - the Flatpak (`/.flatpak-info` exists, or `FLATPAK_ID` is set with the
    executable under `/app/`): the host command Flatpak exports for the
    app, `<installation>/exports/bin/<app id>`, the installation read from
    `app-path` in `/.flatpak-info` (`/var/lib/flatpak` when it cannot be);
  - the AppImage (`APPIMAGE` and `APPDIR` set, the executable under
    `$APPDIR`): the `.AppImage` file itself, since the mount point changes
    on every start, with the missing-file warning if it has been moved;
  - the deb, `.rpm` and Arch package (`/opt/secureshellgo/`, with the
    `/usr/bin/secureshellgo-mcp` wrapper) and the MSIX package (under
    `\WindowsApps\`, with an execution alias): `secureshellgo-mcp`;
  - otherwise the full path of `secureshellgo-mcp` (`.exe` on Windows)
    beside the app's executable, with a warning on the screen if that file
    is missing.

  Every command is one word with no arguments, because the plugin's
  `launcher` setting and the snippets' `command` take nothing else. The
  Flatpak's main command and the AppImage's `AppRun` therefore start the
  launcher instead of the app when `SSG_BRIDGE_TOKEN` is set and stdin is not
  a terminal: every assistant starts it that way, and the app never needs the
  variable. (`flatpak run --command=secureshellgo-mcp <app id>` reaches the
  Flatpak's launcher directly, for clients that take arguments.)
- The kit lives outside `lib/`, in `integrations/`: the skill, a plugin
  (`integrations/plugin/`, listed by the `dhiva-labs` marketplace in
  `.claude-plugin/marketplace.json` at the repository root; its `userConfig`
  asks for `bridge_token`, stored as sensitive, and `launcher`, default
  `secureshellgo-mcp`, and passes them to the launcher), and config snippets
  for other clients. None of it is app code and none of it holds a secret.

### The trust boundary

The line that matters is between the assistant and the app. Everything on the
assistant's side, including its arguments, is untrusted input. Everything the
**server** returns is also untrusted: it goes to the assistant as data and is
never interpreted by the app. The app holds the credentials; they are used
inside `SshService` and never appear in a tool's input or output, a locator
file, an audit entry or a message to the client. Hosts are visible only when
the user has given them an AI access level above Off, and they are known by
their label (`label#xxxx` when two share one); a hidden host never causes a
visible one to be renamed. With "Show address and username" off, the address,
port and user name of the host and of every jump host on its way, and IPv4
literals, are also taken out of any error text before it leaves.

### Levels

A host has one of four levels, stored as `aiAccess` in `hosts.json`, and an
order of trust: **off < readOnly < askToChange < fullControl**. In the app
they are one choice, "AI access" (Off, Read only, Ask before each change, Full
control; "The permission screens" below); 1.7.0 had two switches, "Share with
AI assistants" and "Let the assistant request changes", for the middle two.
Anything the file holds that this build does not recognise reads as `off`: a
`hosts.json` from a later version must not hand an assistant more than the
user chose, and 1.6.0 reads `askToChange` (1.7.0 reads `fullControl`) as `off`
the same way. `fullControl` means changes, terminals and desktops run
**without a card** on that host: the user's explicit choice, made through a
confirmation that says so. Three more fields only mean something at
`askToChange`:

- `aiAllowedCommands` ("Allowed commands"): the commands that run without a
  card. At most 50 entries of at most 4096 characters, each trimmed.
- `aiTerminal`: whether the assistant may ask to open a terminal (a card
  every time).
- `aiDesktop` (1.8.0): whether the assistant may ask to open a desktop (a
  card every time).

At `fullControl` both switches are implied on and the list is not consulted.
The getters say it once: `aiMayRequestChanges` (askToChange or fullControl),
`aiFullControl`, `aiMayOpenTerminal` and `aiMayOpenDesktop` (fullControl, or
askToChange with the switch on).

Stepping a host down, or un-sharing it, **leaves the list and switches stored
but inert**, so the user does not lose a list they typed; it shows again when
changes are switched back on, and the confirmation that switching on shows
lists the commands that would come back into force. Backups strip all of them
(`Host.withoutAiGrants`) on export and on import, so a restored backup can hand
an assistant nothing; the timed-approval setting is exported at its default
(off) and an import keeps this device's value.

### One choke point

`bridge_policy.dart` is the only place that decides. `decideBridgeCall` is a
pure function over: is the bridge on, is the app locked, what kind of tool it
is, and the host. It answers allow, refuse (with a stable code and the message
the assistant is given) or **needs approval**. The order is fixed: off, locked
(full control included), then the kind. `bridgeEnabled` is the calling
client's own switch: `AppSettings.bridgeEnabled` for a channel client, the
built-in assistant's setting for `BridgeClient.builtin`
(`BridgeTools.builtinAssistantEnabled`, wired to
`AppSettings.assistantEnabled`). At `fullControl`, `change`, `terminal` and
`desktop` answer `BridgeAllow.fullControl()` and the audit entry records
`approval: full_control`; nothing else differs from `askToChange`. A second
test copies 1.7.0's function and compares it over every input for the levels
and kinds 1.7.0 knew, refusal texts byte for byte.

- `read`: exactly 1.6.0's rule (allowed on a host with access on; unknown and
  hidden hosts get one `host_not_available`). A test copies 1.6.0's function
  and compares the two over every input.
- `change`: no host, or access off: `host_not_available`; read-only:
  `changes_not_allowed`; at `askToChange`, allowed when the plan's one command
  is on the host's allowed list (`matchesAllowedCommand`) or the same assistant
  holds a live timed approval for the host (`hasLiveGrant`), otherwise needs
  approval.
- `terminal` (opening one): as a change up to the read-only step, then the
  host's terminal switch must be on (`terminal_not_allowed`), and the answer
  is **always** needs approval. A grant or an allowed command never opens a
  terminal.
- `terminalUse` (typing into, reading or closing a terminal that was opened
  with a yes): the caller must own a live terminal by that id
  (`terminal_not_available` otherwise, the same for an unknown id and for
  another assistant's, checked before the host so nothing about another
  assistant's terminal shows), and the host must still be the same server and
  still allow a terminal. The answer is allow: there is no card per call.
- `desktop` (opening one): the rule of `terminal`, with the desktop switch
  (`desktop_not_allowed`).
- `desktopUse`, `jobUse`: the rule of `terminalUse` with `ownsLiveDesktop`
  (`desktop_not_available`) or `ownsJob` (`job_not_available`, the job
  started by the CALLING client); a job's host must still let changes be
  requested.

Two choices are deliberate. A host that does not exist and a host with access
off are refused with the **same** code and message, so a call cannot probe for
hidden hosts; and `changes_not_allowed` says no more than that the host is
read-only, which `list_hosts` already shows by listing it. `list_hosts` does
not say which level a host has.

A typed command is **never judged by its text**: no pattern, no "looks safe",
no blocklist. The app cannot tell a harmless command from a harmful one, so a
command is an exact match against the allowed list, or it asks.

"The same server" is one function, `bridgeSameServer`, which the dispatcher,
the bridge service and the terminals share so they cannot drift: the same id,
hostname, port, user name, transport and jump host (re-routing a host through
another jump host can land on a different machine at the same address). A yes,
a timed approval and an open terminal are each for one server in that sense.
The jump host is compared by its id: editing the jump host's own entry (its
address, say) is not seen as a change of the hosts that go through it.

### Clients: assistants, controllers and the built-in assistant

A paired client has a `role` in `bridge_clients.json` (omitted for the
default, so older files read as before): `assistant` calls tools over MCP;
`controller` is a phone remote control (`BridgeClientStore.create(name,
role: BridgeClientRole.controller)`) that can answer cards and never call a
tool. An unknown role reads as `assistant`. `bridgeClientMayCallTools` is
checked three times: the bridge service's token check refuses a controller
token at the handshake as if unknown, `McpServer` refuses a `tools/call` from
one, and `BridgeTools.call` refuses it (`not_an_assistant`) before anything
is looked up.

`BridgeClient.builtin` (id `builtin`, name "Built-in assistant") is the
in-app assistant as the tool host sees it. It is never stored (a stored row
with that id is skipped), has no token (its hash is empty, which no SHA-256
equals), and is not revoked by changes to the paired list. It calls
`BridgeTools.call` directly; its cards, grants, terminals and audit entries
carry its id and name like any client's.

### Changing, with permission

The order of checks for a change, in `BridgeTools._change`, is the contract,
and is chosen so nothing leaks and nothing is asked that need not be:

1. The host name is resolved as for a read.
2. `decideBridgeCall` with no grant and no allowed command. Bridge off, locked,
   an unknown or hidden host, a read-only host and a terminal not switched on
   are all refused **here**, before the arguments are looked at and before any
   card, so an invalid call to a hidden host reads exactly like a valid one and
   the assistant cannot use the user's screen to probe for hosts. (A refusal
   never depends on the two flags, which a test proves.)
3. The tool's plan: the arguments are validated and the card's summary built
   from them. A failure is refused with no card.
4. The hosts and settings are **read again** and the policy asked again, now
   with the live grant and the plan's allowed-command match. The re-read is
   there because planning can take seconds (`write_file` looks at the server)
   and the user may have edited the host, switched the bridge off or taken the
   command off the list meanwhile. The dispatcher also judges the allowed list
   itself, from the summary the card will show: a plan can claim a match only
   for one command on one host, whatever its own flag says. A plan does not get
   to vouch for itself.
5. If the answer is "needs approval": the card, through `BridgeApprovals`,
   outside the run slots and outside the 30 second deadline (waiting for a
   person is not running). Busy, denied, timed out and withdrawn end the call.
6. After a yes, the hosts are read **again** and the policy runs again. The
   card may have waited two minutes; the host must still be the same server
   (`bridgeSameServer`) and still allow this, the bridge must still be on and
   the app unlocked. Only then is a timed approval created, and only when the
   setting (read again) is still above zero, for no longer than it now says.
7. The change runs in one of the 2 change run slots, under its own deadline.

A yes that was then refused or stopped before the change ran is **approved but
not run**: the assistant gets the underlying message, the host-and-lock cases
as ordinary refusals, and the audit entry's `detail` starts
`refused_after_approval: ` so the activity screen can say "Approved, but not
run" and why. `run_on_hosts` follows the same order for every host at once: a
hidden name anywhere fails the whole call with the one `host_not_available`;
the call is allowed without a card only if a live timed approval exists for
**every** host; and the allowed lists never apply to several hosts.

### Approvals and timed approvals

`bridge_approvals.dart` holds the questions waiting for the user, in memory
only. A request carries the assistant, the host's bridge name, the tool, and a
summary the **tool** built from its validated arguments (a command with its
host names, a file write, a service action, a job start with its command,
folder and name, a terminal, a desktop); nothing the assistant wrote in prose
reaches the card. At most 8 requests wait at once and at most 3 from one
assistant, so one assistant cannot crowd another's cards out; a further ask is
refused at once as busy (`approvals_busy`). One call has at most one pending
request. Silence is a no: a request not answered in 120 seconds ends as timed
out, and an answer that arrives after expiry is a timeout, whatever the timer
says. Every request ends exactly once (answered, timed out or withdrawn), and
a late or second answer is ignored. A request is **withdrawn** when its call
is abandoned (the client cancelled, the assistant was revoked, the bridge
switched off) and by the app: every card on a lock, a host's cards when that
host is un-shared, stepped down, deleted or changed to another server
(`HostStore.changes` makes this immediate).

A **timed approval** ("Allow for a while", a button on the card only when
Settings → AI Bridge → "Allow for a while" is 5, 15 or 60 minutes) is a
`BridgeGrant` keyed by assistant and host: that assistant may change that host
without asking until it runs out. It covers every change tool on that host
(not only the command on the card) and a `run_on_hosts` yes makes one per
host. It lives in memory only and is gone on restart, when the bridge is
switched off, when the assistant is revoked, when the host is un-shared,
stepped down, deleted or changed to another server, when the app locks and
when the setting is switched off (choosing another length leaves running ones
as they were granted); "Stop now" in "Approvals in force" ends one. It covers
`start_job` like the other change tools, and **never covers a terminal or a
desktop**: on their cards the button is not offered, and an "allow for a
while" answer counts as once. If the setting was lowered while a card waited,
the grant is for the shorter time.

### The allowed list

`matchesAllowedCommand` is exact string equality between the requested
command, trimmed, and an entry; never a prefix, a pattern or a case fold. It is
used for `run_command` on a single host only; nothing else ever matches, and
the list does nothing while the host is below `askToChange`. The sanitiser
(`Host.sanitizeAiAllowedCommands`, the one rule for reading `hosts.json`, for
`copyWith` and, through `allowed_command_check.dart`, for the editor) drops an
entry **whole**, never cleaning it up (cleaning would store a command other
than the one typed) when it has: any control character (a tab, a line break, a
NUL, DEL, a C1 control; a multi-line entry is several commands), any space
that is not U+0020 (a no-break space looks like a word break and is not one to
a shell), a soft hyphen, line or paragraph separators, bidirectional marks,
embeddings, overrides and isolates, zero-width characters, a byte-order mark
or a lone surrogate. These are the characters that make the stored text read
differently from what runs, on the one path where nobody is asked. It also
drops empty entries, entries over 4096 characters, duplicates, and entries
past the 50th.

The editor (`allowedCommandProblem`) refuses more than the sanitiser: also
anything the card would mark (`visibleText(...).hasSurprises`), so every other
format character, private-use, unassigned and noncharacter code points, and
the combining marks the card shows as stand-ins (below). Those extra checks
are made when an entry is typed, not when `hosts.json` is read: an entry put
into the file by hand that holds only those is kept, and the editor then shows
it with its stand-ins. Every entry is shown in full in the editor and in the
confirmation, never cut, through `visibleLine`.

### The card is the security boundary

The approval card is what a person's yes rests on, so it is built to be read
and hard to hit by mistake (each point has a test):

- **Visible text.** `visible_text.dart` renders the command, the path, the
  assistant's name and the host's name so that every character can be seen:
  a line feed shows as `\n` and a real line break, other control characters
  as `\t`, `\r`, `\x1b`, bidirectional marks, embeddings, overrides and
  isolates as `[U+202E]` and the like, zero-width, other invisible and every
  other format character and non-ordinary spaces as `[U+200B]`, `[U+00A0]`,
  text that is not valid (a lone surrogate, a noncharacter, a private-use or
  unassigned code point) as `[U+D800]`, and a combining mark that could hide
  or change the character before it as `[U+0301]` (every enclosing mark, the
  general combining blocks of accents, overlays and strokes wherever they
  are, any mark on a plain ASCII character, and the third and later marks in
  a row; the marks a script needs on its own letters are drawn as they are).
  A short legend, one line per kind, appears when any was shown. This
  is a picture of the string: what runs is the raw string, and nothing reads
  the picture back. A `\r` that would hide the text before it, or a
  right-to-left override that would reorder the line, cannot hide on the card.
- **Default Deny.** Deny holds the focus, so Enter and Space deny; Escape and
  the back gesture deny; a click beside the card does nothing.
- **A one second lockout.** Both Allow buttons are disabled for one second
  after the card appears and after the request it shows changes, so a key or
  click already on its way cannot approve something not yet read. Once one
  answer is given the card is inert.
- **A card for a terminal says what it allows**, in the product's own words:
  "An approved terminal gives the AI assistant a live shell as the saved
  sign-in user on this host. It can type any command, including ones you never
  see on a card, read any file that user can read, and reach anything this
  host can reach, with no further questions. The blocked-path list does not
  apply inside a terminal. You can watch it, take over by typing, or stop it
  at any time."
- **A file card does not pass a part for the whole.** It shows the canonical
  path, the exact size, whether a file is replaced, and a preview that is
  marked partial (`previewIsPartial`) when lines are left out or cut or text
  was hidden as a secret, or absent. The partial-preview warning is drawn
  first on the card, above who asked and where, so it is in view without
  scrolling; the preview's own last lines say the same in words. The preview,
  and the lines of the old file a diff shows, are read from the server for
  the card only: they are never sent to the assistant, and the audit entry
  holds only the path and the size.
- **The lock.** One card at a time, over whatever screen is in front, with
  "N more waiting". A locked app shows no card: the service withdraws every
  request on a lock and the host removes the dialog rather than covering it (a
  dialog under the lock screen would still take key presses). Nothing is
  queued across a lock.

The card does not ask the window manager for attention (no flash, no sound,
no raise): if the app is in the background the user is **not alerted**, and a
card nobody looks at ends as a denial after 120 seconds. The README says so,
because it decides how the feature can be used.

### Each change tool

All four are `BridgeToolKind.change`, carry `readOnlyHint: false` and
`destructiveHint: true` in `tools/list`, and share these safeguards:

- **One string, shown, matched and run.** For `run_command` and
  `run_on_hosts` the plan holds the trimmed command once. The card shows it,
  the allowed list is matched against it and it is what runs: no step builds a
  different command in between.
- **The account's shell, exactly as given.** The command is wrapped
  (`BridgeChangeCommands.accountShell`) as `exec "${SHELL:-/bin/sh}" -c
  '<command>'`, the way `ssh host 'command'` and "run on many servers" run it,
  inside the same supervised wrapper as every bridge command. It has no stdin
  and no terminal. The wrapper's command line is quoted by `loginShellQuote`
  so that no backslash is ever left inside single quotes: a login shell such
  as fish, which reads `\\` and `\'` inside single quotes as escapes, cannot
  change the command or reopen its quotes. This is checked on sh and bash; fish
  itself has not been run (the release checklist has the check).
- **Output.** `run_command` returns the exit code and each stream redacted and
  cut to its newest 30 KB. `run_on_hosts` returns JSON so one host's output
  can never pass for another's: `{"hosts": [{"host", "exit_code", "stdout",
  "stderr"} or {"host", "error"}]}`, in order, redacted value by value and cut
  until the whole is under 60 KB. It runs at most 3 hosts at a time, each
  under its own 60 seconds, in one run slot.
- **Stopping.** A command that passes its deadline, or whose call is
  abandoned (client cancel, revoke, bridge off), has its process group sent
  TERM and, 3 seconds later, KILL; the channel is closed at once. See
  "Stopping a call".
- **`service_action`** is the fixed template of the services screen
  (`SystemdCommands`) for start, stop and restart, and its sibling for reload,
  on a unit validated by the same rule as the read tools. Nothing can answer a
  password prompt, so a unit needing privilege the account lacks fails with
  the tool's own error.
- **`write_file`** writes UTF-8 text (at most 256 KiB, no NUL) through the
  editor's `saveRemoteText` (temp file, rename, conflict guard). The path
  goes through the same guard as reads: resolved on the server first, then
  checked, with a blocked path refused as `path_not_available` exactly as a
  read of it is; a symlink is followed to the file it points at and that file
  is judged and written. The parent directory must exist and is not created.
  The temporary file's name is `.<name>.ssg-bridge-<ms>-<64 random bits>`:
  the editor opens its temp file without O_EXCL, and what is opened at a name
  that already holds a symlink is whatever the link points at, so the name
  must not be guessable by someone who can write in that directory. For a
  replacement the card shows a diff when the old file is small text (up to 64
  KiB), and the write is **refused** when the server reports neither size nor
  modification time, because the changed-after-the-card check below could not
  hold.
- **Changed after the card.** The replaced file's size and modification time
  are recorded when the card is built, and the write stops with "changed on
  the server after the user was asked" if they differ, or if the path no
  longer resolves to the same regular file; a new file stops if anything
  appeared there. Before the rename a stop leaves the file as it was and
  removes the temporary file on the still-open channel; once the rename has
  begun it runs to its end, and a write that landed is reported as done even
  if the call was cut off in the same instant. The replaced file's mode is
  put back.
- **Timeouts.** A change's deadline is its own (`timeout_seconds`, default
  60, at most 300, for a command; 60 for a service action and for each host
  of `run_on_hosts`; the usual 30 seconds for a file write) and includes
  waiting for a run slot and connecting. A change can therefore time out
  while queued behind others, before it ran.

### The terminal

`bridge_terminals.dart`. `open_terminal(host)` (kind `terminal`) always
needs a card; it opens an interactive shell the user can **see**: a normal
session tab through `SessionManager`, marked as driven by an assistant, with
a banner offering "Take over" and "Stop". It returns a `terminal_id` (128
random bits, grouped so the secret scrubber does not take the id for a key).
`send_input` (at most 4096 characters, written to the PTY exactly as given),
`read_screen` (the screen and scrollback, the last 200 lines at most and 60
KiB, with wrapped rows joined before redaction so a long token is whole for
the scrubber) and `close_terminal` are kind `terminalUse`.

Why it never borrows what the user has open: an assistant's terminal is a
connection of its own, dialled by the same no-prompt dial as other bridge
calls (never a prompt, never a new or changed host key), with agent and X11
forwarding off whatever the host says, without the host's startup command,
without attaching to a persistent tmux or screen session, and never over Mosh.
Each of those is the user's choice for the user's own shell; none may follow
an assistant into a session it types into. Input the assistant writes is not
mirrored into the user's broadcast-input targets.

Who has the keyboard: the assistant **drives** until the user takes over (the
button, or typing into the session: the first keystroke takes it, so two
typists never interleave), after which `send_input` and `read_screen` are
refused and the session is the user's. The state only moves forward. The user
can Stop, which closes the session.

Lifecycle: at most 2 driven terminals at once, all assistants together (a
taken-over one is the user's and no longer counts); one with no input or read
for 10 minutes is closed. The bridge being switched off (first, before the
slower teardown), the app locking, the assistant being revoked, the host being
deleted, un-shared, stepped down, losing its terminal switch or changed to
another server close the driven ones; each call checks again regardless. A
lock, bridge-off or host change that happens while a terminal is still opening
closes it as it lands. A taken-over terminal is the user's and none of this
closes it. Input is audited call by call (scrubbed, cut at 500 characters),
the screen never.

### Jobs

`bridge_jobs.dart`, a `BridgeToolModule` registered in `main.dart`.
`start_job` is its one change tool (kind `change`): it goes through the same
path as `run_command`, so it gets a card, or a live timed approval, or full
control's allow, and the plan never sets `matchesAllowedCommand`, so the
allowed list cannot start a job. `list_jobs`, `job_status` and `job_output`
are `read` specs (they work wherever reading does); `stop_job` and
`remove_job` are `jobUse`, held to the owner rule and to a host that still
lets changes be requested.

On the server, `BridgeJobCommands` is a set of POSIX `/bin/sh` scripts, each
run as the fixed command inside `BridgeCommands.supervised`. Nothing from the
assistant is spliced into a script: the job id (16 characters of `[a-z0-9]`,
made by the app), the command, the folder and a line count arrive as
positional parameters set by one `set --` line whose words are each quoted
with `posixSingleQuote`, and the folder is only ever used as `cd -- "$5"`. A
job lives in `~/.cache/secureshellgo/jobs/<id>/`, created owner-only (umask
077; the command itself runs with the account's own umask), with these files:

- `cmd` (the command as run), `started` (server clock) and `boot` (the boot id
  where Linux has one, so a pid seen after a reboot is never taken for the
  job);
- `pid` (the runner's process id) and `group` (`1` when the runner leads a
  session and process group of its own, `0` when the server has no `setsid`);
- `log` (stdout and stderr together);
- `exit` (`<status> <ended>`, written by the runner through a rename, or by
  `stop_job` as 137 when it had to KILL the runner) and `stopped` (present
  when `stop_job` stopped it).

The runner is a small `sh` that starts the command with the account's own
shell (`"${SHELL:-/bin/sh}" -c`, as `run_command` does), passes TERM and HUP
on to it, waits, and writes `exit`. It is started in the background with stdin
from `/dev/null` and all output to `log`, under `setsid` where there is one,
so the SSH channel holds nothing of it and closes at once, and the end of the
supervised call never reaches the job. Without `setsid` it runs under `nohup`
in the calling shell's group: it still outlives the connection, but a stop
reaches only the runner (which passes TERM on), not what the command started.
The server's files are the truth for state: `running`, `exited`, `unknown`
(its processes are gone without an exit code) or `missing` (its folder was
deleted). `stop_job` sends TERM to the group, KILL three seconds later
(`BridgeCommands.stopGraceSeconds`) if anything is left. `job_output` returns
the last `lines` (default 200, at most 5000) of the newest 64 KiB of the log,
through the redactor like every other output.

The app keeps a small registry, `BridgeJobRegistry`:
`<data>/bridge/bridge_jobs.json` (version 1, written atomically through
`SerialFileWriter`, `chmod 600` where there is one; an unreadable file is set
aside and the registry starts empty). A record holds the job id, the starting
client's id, the server's identity as `bridgeSameServer` compares it (host id,
address, port, user, transport, jump host id), the host's bridge name, the
start time, the name and the command cut to 500 characters. It says whose a
job is and where; it is not the state. It is written **before** the job
starts, so a start cut short by a stop or a dropped connection cannot leave a
job nobody knows about.

Ownership is the registry's `find(clientId, id)`: a job another client started
and an unknown id read alike (`job_not_available`, checked before the host, so
nothing about another client's job shows), and `ownsJob` feeds
`decideBridgeCall`. At most 20 jobs per client per server, ended ones
included, checked at plan time and again by `addIfRoom` at run time, since the
card may have waited. When the bridge service reports host changes,
`retainHosts` forgets the jobs of a deleted or re-pointed host;
`clientsChanged` forgets a removed client's. Forgetting stops nothing on the
server. Stepping a host down below `askToChange` leaves its jobs running;
reads of them still work, `stop_job` and `remove_job` get
`changes_not_allowed`.

What is not there: no screen lists or stops jobs, and phone control does not
stop them (the protocol has a `job` item kind, but no control source is
registered for it in `main.dart`). A job is the user's process on the user's
server; the way to end one the assistant cannot reach is `kill` on the server.

### The assistant desktop

`bridge_desktops.dart` (a `BridgeToolModule`),
`screens/assistant_desktop_screen.dart` and, in
`screens/remote_desktop_launch.dart`, `openSignedInDesktop`. It rides the
remote-desktop stack: the same probe, agent deployment, tunnel and
`RemoteScreenSession` as "Remote desktop… → This desktop", with nobody to ask.

**Opening.** `open_desktop` is kind `desktop`: no timed approval and no
allowed command ever opens one; a card every time at `askToChange` with the
desktop tick, no card at `fullControl`, `desktop_not_allowed` otherwise. Its
plan is refused with `desktop_limit` before any card when the one desktop slot
is taken. The run dials a connection of its own with
`BridgeConnections.dialOwned` (no prompt; agent and X11 forwarding stripped
whatever the host says) and calls `openSignedInDesktop`, which runs
`RemoteDesktopProbe` and refuses, in the chooser's own words, a Mac (its
Screen Sharing needs a typed password), an unsupported system, another user's
desktop and a headless server; then `AgentDeployer` (purpose desktop),
`AgentLauncher.launchDesktop` and the shared `_connect` that opens the agent's
channel through the tunnel. Opening has 180 seconds. `AssistantDesktopLink`
owns that connection and the session for the desktop's life and hangs up on
close.

**Seeing and using.** `desktop_screenshot` encodes the screen the viewer is
drawing, with `dart:ui`, as a PNG scaled so the longest side is at most 1280
pixels (the pointer is not drawn; 20 seconds). `BridgeToolResult` and
`BridgeModuleOutcome` carry optional image content, which `mcp_server.dart`
sends as MCP image content and the built-in assistant's Anthropic provider as
an image block. `desktop_click`, `desktop_move` and `desktop_scroll` take x
and y in screenshot pixels, mapped back to the real screen (`toScreen`), and
are refused when the real screen size changed since the last screenshot, so a
coordinate cannot land elsewhere than meant. `desktop_type` sends key strokes
for a US layout, at most 2000 characters, and refuses the whole text when any
character has no key; `desktop_key` takes a key or combination from a fixed
table (`ctrl`, `alt`, `shift`, `super` plus the listed keys, as evdev codes);
scroll is at most 50 notches. A session the remote side only lets be watched
answers every input tool with an error. All of these are kind `desktopUse`: no
card per call, but each goes through `decideBridgeCall` with `ownsLiveDesktop`
(the caller's own, still the assistant's) and the host still allowing a
desktop.

**The viewer and who has it.** `AssistantDesktopHost` is mounted once from
`main.dart` with the navigator key, like the approval host, and pushes
`AssistantDesktopScreen` the moment a desktop appears, before its first frame:
the user sees what the assistant sees. It uses the same `AssistantDrive` model
as terminals: the assistant drives until the user presses Take over (or Stop,
or leaves the viewer), the state only moves forward, and a taken-over desktop
is the user's, an ordinary remote desktop the assistant can no longer see or
use. A lock makes the viewer give up the keyboard so keys typed at the lock
screen never reach the remote desktop.

**Lifecycle.** At most one (`maxDesktops`), across all clients. Each desktop
tool call restarts a 10-minute idle timer. A desktop the assistant drives ends
on `close_desktop`, Stop, the viewer closing, idle, the remote session ending,
the bridge going off (the built-in assistant's desktop is spared, as it is not
the channel's), a lock, the assistant being revoked, its host being deleted,
un-shared, stepped down, losing the desktop tick or pointing at another
server, and shutdown. `AssistantDesktopEnd` names each, and a call on an ended
desktop gets the matching message under `desktop_not_available`.
`desktop_type`'s arguments are replaced in the audit log by a character count.

**What one yes allows.** The assistant sees whatever the signed-in user's
screen shows (passwords on screen, messages, other windows) and can click and
type anything that user can, until one of the above ends it. That is why it is
off per host by default, needs a card every time, is always on screen, and is
audited call by call. A screenshot cannot be redacted, and it goes to the
assistant's provider as an image.

### Cancellation

`mcp_server.dart` handles `notifications/cancelled` with `params.requestId`
by abandoning that in-flight `tools/call`: its pending card is withdrawn, its
work on the server is stopped as for a revoke (a file write already past the
point of its rename finishes), and **no reply is sent** (the MCP rule for a
cancelled request). Ids are per connection, so one connection can
never cancel another's request, and an unknown or finished id is ignored.

### Stopping a call

Every remote command runs under a small `sh` wrapper
(`BridgeCommands.supervised`): the command runs in its own process group
(`setsid` where there is one), and a watcher waits on the channel's stdin.
When a call passes its deadline (30 seconds for a read, its own for a change),
or is abandoned because its assistant was revoked, the bridge was switched
off or the client cancelled it, the app closes stdin, the group is
sent TERM and, three seconds later, KILL (a command that ignores TERM
is still ended), and the call's SFTP channel is closed. Nothing new is started for
a halted call. An abandoned call is answered with the reason and never with
what it found, even one that finished in the gap; a revoked or switched-off
connection is cut, so nothing more is sent on it at all.

### Why the launcher is a dumb pipe

An MCP client starts a program and talks to it over stdio. That program
(`bin/secureshellgo_mcp.dart`, compiled with `dart compile exe` as
`secureshellgo-mcp`) could have been the server, but then it would need the
credentials, the host list and the policy, and would be a second app to keep
in step and to secure. Instead it reads the locator file, connects, does the
handshake with the token from `SSG_BRIDGE_TOKEN`, and copies bytes both ways.
It has no Flutter import, parses no MCP, and holds nothing worth stealing
except the token the client already gave it. If it cannot reach the app it
answers each request with a plain error and exits when stdin closes, so the
client shows why instead of hanging.

### One-click connect

"Connect Claude Code" (Settings → AI Bridge) does what the manual block of
three terminal commands does, by running the `claude` command itself. It is
the only place the app starts another program for the bridge, so it is kept
small and checked at run time.

- **Finding `claude` runs nothing.** `ClaudeCliConnector.find` is file-system
  checks alone, and is what Settings calls on opening and on "Check again":
  the snap test (then it does not look at all), then `findCandidates`, which
  reads the `PATH` itself (absolute, local entries only; an empty or relative
  entry is skipped, and on Windows so is a network share; with `PATHEXT`
  order and only `.exe`, `.cmd`, `.bat` on Windows) plus `~/.local/bin/claude`
  and `~/.claude/local/claude` (`%USERPROFILE%\.local\bin\claude.exe` on
  Windows), without asking `which`. The button exists when a candidate does.
- **Running it starts when the user presses the button.** The one-click screen
  calls `detect`, which runs each candidate with `--version` (10 s) until one
  answers, then `plugin marketplace list --json` (10 s) so the confirmation
  can show the path, version and where the plugin would come from. Both are
  read-only. Nothing that changes anything runs before the user presses
  Connect on that confirmation.
- **The process seam.** Every process is started through one injected
  `BridgeProcessRunner`, so tests use a fake instead of the real CLI. The
  default runner calls `Process.start` with an argument list (never one
  command string), caps each output stream at 256 KiB, writes stdin and closes
  it at once (a program that asks a question gets end-of-file), and kills it
  on a timeout (10 seconds for `--version`, 90 for each plugin command).
- **Fixed argument lists, checked at run time.** The arguments are the
  constants of the `ClaudeConnectStep` enum (list, add, install, configure,
  verify) and `--version`. `_start` throws unless the list it was given is
  one of those objects. This is a runtime check, not an assert, because it is
  a security property: nothing a caller passes, the token above all, can reach
  a command line (visible to other users in the process list, and
  interpreted by a Windows shell). Only an absolute, local, existing file
  named `claude` (`claude.exe`, `.cmd`, `.bat` on Windows) is run, and
  that is checked again inside `_start`.
- **The token on stdin only.** It is passed as JSON on the stdin of
  `claude plugin configure secureshellgo@dhiva-labs --values-stdin`, with the
  launcher command, and nowhere else: not an argument, not the environment
  (the child gets only `NO_COLOR=1` added), not the screen, clipboard or a log.
  Any text from the program that is kept for the "Technical details" view is
  scrubbed of the token (whole, JSON-escaped and as runs of 8 or more
  characters from either end) and cut to 2 KiB. The screen holds the token
  only as a local of one function and never in state.
- **Strict verify.** The last step is `claude plugin configure ... --json`,
  and "connected" is reported only if its answer lists `bridge_token` as
  configured. A timeout, an error or an answer of another shape is a failure.
  A failed marketplace add alone is not (the install says whether the plugin
  can be had), but a failed install, configure or verify is.
- **A pending pairing, revoke on failure.** The screen creates the pairing
  with `pending: true` (stored as `"pending": true` in `bridge_clients.json`).
  `BridgeClientStore.verify` refuses a pending pairing, so its token cannot
  sign in, even if the plugin already holds it. Only after the connector
  reports success does the screen call `confirm`; a `confirm` that cannot be
  saved counts as a failure. A pairing still pending when the app next starts
  belongs to a setup that never finished, and is removed on the first load.
  On any failure the screen revokes the pairing it just made, so no unused
  token is left, and puts the bridge switch back as it was: if this attempt
  switched it on, it is switched off again, whoever else is paired. The manual
  route stays available from the failure screen. If the revoke, or the switch
  back, cannot be saved, the screen says which (the pairing's name and where to
  remove it, or that the bridge is still on) and does not claim otherwise.
- **The plugin-source check.** Claude Code finds a plugin by the name of its
  marketplace, and anything can be added as `dhiva-labs`; whatever it serves
  receives the token. So the confirmation shows where the marketplace
  points when it is not the published GitHub repository (with a warning,
  and a separate warning when it could not be read). `connect` reads the list
  again and stops before installing or sending anything if the source has
  changed since the confirmation.
- **Why not in the snap or the Flatpak.** A strictly confined snap may not
  start other programs, and a Flatpak cannot start programs on the host
  (only `flatpak-spawn --host` could, through a permission the app does not
  ask for). So `find` and `detect` return "sandboxed" without looking (the
  same tests as the launcher locator: the executable under `$SNAP`;
  `/.flatpak-info`, or `FLATPAK_ID` with the executable under `/app/`) and
  the screen shows a note pointing to "Connect an assistant".
- **Shared hosts.** After success a checklist (`SharedHostsChecklist`, also
  reachable on its own from Settings) lists the saved hosts. It starts from
  each host's current AI access, so nothing is ticked that was not already
  shared, and on Save it writes only the hosts whose tick changed (a newly
  ticked host becomes read-only, an unticked one off; a ticked host keeps the
  level it has), re-reading each host just before writing it. Each row shows
  its level as a chip (Off, Read only, Asks first, Full control), and tapping
  it opens the per-host sheet with the same level picker and confirmations as
  the host edit screen ("The permission screens"). A quick connect is not a
  saved host, so it is not listed.

### The local channel, per platform

- **Linux:** a unix socket at `<data>/bridge/bridge.sock`, in a directory of
  mode 0700, with the socket 0600. The kernel's file permissions are then the
  access control: another local user cannot open it. A path longer than the
  socket-path limit falls back to `$XDG_RUNTIME_DIR/secureshellgo-bridge.sock`
  (per user and 0700 by the XDG spec; never `/tmp`). In a Flatpak, whose
  bridge directory under `~/.var/app/<id>/data/<id>/` is usually past the
  limit, `XDG_RUNTIME_DIR` is private to each sandbox instance and the
  launcher runs in an instance of its own, so the fallback there is
  `$XDG_RUNTIME_DIR/app/$FLATPAK_ID/`, the directory Flatpak shares between
  an app's instances. A stale socket is told
  from a live one by trying to connect, so a second window reports "already
  running" instead of stealing it. The handshake is one line,
  `{"ssg_bridge":1,"token":…}`.
- **Windows:** Dart cannot use unix sockets there, so the app binds a TCP
  port on `127.0.0.1` only, chosen by the system, and writes the port and a
  random 32-byte secret for this launch to `endpoint.json` in the bridge
  folder under `%APPDATA%`, which only the user's account can read. Any local
  process can connect to a loopback port, and after a crash the port in a
  stale `endpoint.json` can belong to anything, so the handshake is mutual:
  the launcher sends a nonce (`{"ssg_bridge":1,"hello":…}`), the app answers
  with `HMAC-SHA256(secret, nonce)`, and only a launcher satisfied with that
  proof sends the token and the secret, which the app checks in constant
  time. A new instance checks a previous `endpoint.json` the same way (a
  live owner must prove it holds the old secret), so a stale port is never
  mistaken for a running window.

Both write `endpoint.json` atomically and remove it on stop.

### The built-in assistant

`lib/services/assistant/`. A chat inside the app, on every platform, that
talks to an AI service with the user's own key and calls the same
`BridgeToolHost.call` a paired assistant's connection does, as
`BridgeClient.builtin`. It adds no policy of its own: levels, cards, timed
approvals, terminals, desktops, jobs and the audit log are the tool host's,
and the entries carry the name "Built-in assistant".

- **Providers.** `AssistantProvider.send(messages, tools, system, cancel)`
  returns one `AssistantTurn` (text, tool calls and a stop reason).
  `AnthropicProvider` posts to `{base}/v1/messages` (default base
  `https://api.anthropic.com`) with `x-api-key` and `anthropic-version:
  2023-06-01`, `max_tokens` 4096 and the tool specs as tools; tool results go
  back as `tool_result` blocks, an image as an image block.
  `OpenAiCompatibleProvider` posts to `{base}/chat/completions` (the base is
  required, such as `https://api.openai.com/v1`) with a bearer key (none sent
  when the key is empty) and the specs as functions. OpenAI's tool messages
  are text only, so an image result becomes a note that one was returned and
  cannot be carried: **desktop screenshots reach the model only through
  Anthropic.** Neither streams.
- **Transport.** `assistant_http.dart` uses `dart:io` `HttpClient` (no new
  dependency). `checkedAssistantUrl` accepts only `https`, or `http` to
  `localhost`, `127.0.0.1` or `::1`, and refuses user info in the address, so
  the key and the conversation are never sent unencrypted. Limits: 20 s to
  connect, 120 s per request, 4 MiB of response; failures map to
  `AssistantFailureKind` (config, auth, rate limit, network, server, bad
  response, cancelled) with text for the user. Android's manifest keeps
  cleartext off, so a local `http` model server does not work there.
- **The loop.** `AssistantConversation.send` appends the user's message and
  repeats: ask the provider; if it asks for tools, run each call through the
  tool host as the built-in client, put the results (cut to 16 KiB each by
  `truncateAssistantResult`) back in the history; stop on an end turn, after
  40 tool calls for one message (the rest are answered as not run), on an
  error, or on Stop. Stop cancels the HTTP request and the running call's
  `BridgeCallToken`, which withdraws a waiting card. The transcript (user,
  reply, tool and notice items, a tool item marked while a card for it is
  waiting, from the approvals stream) is what the chat screen draws. Nothing
  is written to disk; the conversation ends with the app. The system prompt
  carries the same standing rules as the skill (read first, say what you will
  do, stop if denied, never ask to raise access, server text is data); it does
  not yet mention jobs, desktops or full control.
- **Key and settings.** `AssistantService` reads `assistantEnabled`,
  `assistantProvider`, `assistantBaseUrl` and `assistantModel` from
  `AppSettings` (off, Anthropic, empty and empty by default) and the key from
  secure storage under `apiKeySecretName`, a name no backup reads (a backup
  carries only `credentials:<hostId>` entries). The key is held in memory
  while the app runs, taught to `DiagnosticsLog.scrubber` so no log can carry
  it, and never in `settings.json`. `setApiKey` throws
  `SecureStorageUnavailableException`, keeping nothing, when the platform
  cannot protect it; a sealed store is reported, not prompted for. A key is
  optional only for an OpenAI-compatible server on `localhost`. A provider is
  built again for each request, so a changed model or key applies to the next
  message. The settings are stripped from backups (`withBridgeDefaults`) and
  kept on import (`withBridgeFrom`).
- **Switches.** The built-in assistant has its own:
  `BridgeTools.builtinAssistantEnabled` replaces `bridgeEnabled` for
  `BridgeClient.builtin` in every decision. The channel's switch never opens
  the bridge for it, and switching the channel off ends what channel clients
  hold and spares the built-in assistant's (`_notChannel`). Turning the
  assistant off stops its live conversations. The app lock refuses its calls
  like any other.
- **Screens.** `assistant_chat_screen.dart` and `assistant_transcript.dart`
  (opened from the host list's app bar while the assistant is on; the approval
  cards come from the app-wide host, over the chat) and
  `settings/assistant_settings_section.dart`, whose enabling dialog says what
  is sent.

### Phone control

A paired phone can answer the AI Bridge's approval cards, and stop what an
assistant holds open, from anywhere it can reach the computer over SSH. It
adds a second kind of client and a second kind of connection to the channel,
and no way to call a tool.

- **Roles.** `BridgeClientRole` is `assistant` (the default, omitted from
  `bridge_clients.json`) or `controller`, fixed when the client is paired
  ("Pair a phone" calls `BridgeClientStore.create(role: controller)`).
  `bridgeClientMayCallTools` (an assistant, not the built-in client) and
  `bridgeClientMayControl` (a controller, not the built-in client) are the
  only two tests; neither role passes the other's.
- **Handshake routing.** The handshake line may carry `session: "control"`;
  its absence means MCP, as every launcher before 1.8.0 sends.
  `bridge_channel.dart` verifies the token, then requires the client's role to
  fit the session: the wrong pairing for a session reads exactly like an
  unknown token, and any other `session` value is a version mismatch.
  `BridgeService._verifyClient` accepts a controller token only while
  `AppSettings.bridgePhoneControl` is on, so with it off a phone's token reads
  as unknown. `_onConnection` hands a controller's connection to
  `BridgeControlServer.serve`, never to an `McpServer`. A controller's
  `tools/call` is refused three times over (the token check, `McpServer`,
  `BridgeTools.call`).
- **The launcher's control mode.** `secureshellgo-mcp control`
  (`bridge_control_launcher.dart`) reads the token from the first line of
  stdin (at most 4096 bytes), never from argv or the environment, dials the
  app with `session: "control"` and relays bytes both ways. With no app, or a
  refusal, it writes one JSON `error` line (`not_running` or `refused`) and
  exits 1; it exits 0 when the phone closed first. It parses nothing, like the
  MCP mode.
- **The phone's side.** `services/bridge_remote/`. `remoteControlCommand()` is
  one `sh -c` script, quoted with `loginShellQuote` so fish reads it as
  written, that execs the first launcher found of `secureshellgo-mcp`,
  `secureshellgo.mcp`, `/snap/bin/secureshellgo.mcp` and
  `/opt/secureshellgo/secureshellgo-mcp`, then `flatpak run
  --command=secureshellgo-mcp <app id>`, else prints a `launcher_not_found`
  error and exits 127. It reads no stdin, so the token line reaches the
  launcher untouched. `remoteExecOver` runs it on the SSH connection of the
  saved host (`SessionTransport.execute`), dialled with nobody to ask
  (`headlessRemoteLinkOpener`). `RemoteBridgeController` moves through idle,
  connecting, syncing, live and closed, holds a `RemoteBridgeState`
  (approvals, grants, items, activity, lock, the allowed "for a while" length)
  and exposes the actions. `RemoteControllerTokenStore` keeps the token in
  secure storage under `bridge_controller_token:<hostId>`, never in
  `hosts.json` or a backup; a host counts as "my computer" exactly while one
  is saved.
- **The protocol.** `bridge_control_protocol.dart`, pure Dart so launcher, app
  and phone share it: JSON, one message per line, version 1, an inbound line
  at most 64 KiB, an outbound line at most 1 MiB. App to phone: `snapshot`
  (lock, "for a while" minutes, controller name, grants, items, activity of at
  most 50 entries; it replaces everything the phone holds), then one
  `approval` per waiting card and `synced`; afterwards `approval`,
  `approval_removed`, `grants`, `items`, `activity`, `state`, `result`
  (answers one request by its `re`) and `error`. Phone to app: `answer`
  (`deny`, `once` or `for_minutes`), `stop_grant`, `stop_item`, `ping`.
  Nothing else exists, so a phone cannot pair, change a setting or a host's
  access, or call a tool. Every text in an approval (assistant, host, command,
  path, preview, job fields) is made visible-safe on the computer before it is
  sent (`visibleLine`, `ControlVisibleText`), the host as its bridge name,
  never its address or user, so the card cannot hide anything on the phone
  either.
- **The app's side.** `BridgeControlServer` serves at most 2 sessions,
  replying `too_many_sessions` to a third. An action goes through exactly what
  the app's own button calls: `BridgeApprovals.answer` (the audit entry
  records `via: controller:<name>`), `BridgeGrants.revoke`, and
  `BridgeControlSource.stop` for the sources `main.dart` registers, which
  today are the assistant terminals and desktops. The tool host then re-checks
  after a yes as for a tap (same server, still allowed, bridge on, unlocked).
  "Allow for N minutes" is accepted only when `bridgeTimedApprovalMinutes` is
  above 0, only for exactly that length, and never for a terminal or desktop
  (`timedAllowedFor`). While the app is locked a session stays open with an
  empty snapshot flagged `locked`, and every action is refused. Sessions are
  closed when Phone control is switched off, the bridge goes off, or the
  phone's pairing is removed (`closeClientsExcept`).
- **What a controller cannot do.** Call a tool; pair or revoke anything;
  change a setting, a host's level or its allowed commands; see an address or
  a user name; keep a card alive past its 120 seconds; or do anything while
  the app is locked. What it can do is deny, allow once, allow for the
  configured time, and stop an approval, a terminal or a desktop: the same
  things the person at the computer can do from the cards and banners.
- **Limits.** The phone's command is a POSIX `sh` script, so the computer's
  SSH login shell must run it; it has not been run on a Windows computer. A
  launcher in a folder of its own (an unpacked tarball elsewhere, an AppImage)
  is not found. A session lives only while the phone's "AI approvals" screen
  is open (the screen's own help says so): nothing on the phone listens in the
  background, so a card raised meanwhile is answered by nobody and ends as a
  denial after 120 seconds. Jobs are not a control source yet.

### The permission screens

One model under the screens: a host's `aiAccess` and, beneath `askToChange`,
`aiTerminal`, `aiDesktop` and the allowed commands.

- **`HostAiEdit`** (pure Dart) is what a form or sheet did, with a `*Chosen`
  flag per field. `applyTo(stored)` starts from the host as the store holds it
  **at save time** and changes only the fields the user touched in this form,
  so a form opened earlier cannot undo an edit made since, or raise what an
  assistant may do by writing stale values back.
- **`HostAiControls`** is the "AI access" section, shared by the host edit
  screen and the per-server sheet of the shared-hosts list. It shows
  `HostAiLevelPicker`, which owns the choice and its confirmations, and a "Not
  saved yet" hint while the form differs from what is saved.
- **`HostAiLevelPicker`**: Off, Read only, Ask before each change, Full
  control, each with a line saying what it allows. Under Ask: "May ask for a
  terminal" and "May ask for the desktop" (each confirms, and says a card is
  still needed every time), and the allowed commands list folded under
  "Advanced". A summary line is composed from the level, the two ticks and the
  command count ("Assistants can read this server. Changes need your yes each
  time."). Full control shows a standing warning and a confirmation whose
  Cancel button holds the focus; going up to Ask lists the commands and any
  tick that come back into force; going down never asks. Nothing takes effect
  until the host is saved.
- **`HostAiLevelChip`** shows the level on the shared-hosts rows (Off, Read
  only, Asks first, Full control). `list_hosts` still does not tell an
  assistant its level.
- **Settings → AI Bridge** is grouped, each group with a line: Assistants on
  this computer (switch, address, connect, paired assistants; only with the
  local channel), Built-in assistant, Phone control (only with the local
  channel), What assistants can read (blocked paths, sensitive paths),
  Approvals ("Allow for a while", approvals in force), Shared hosts and
  Activity.

### The path guard

`BridgePathGuard` (`bridge_paths.dart`) blocks reads of common secret
locations: `~/.ssh`, `~/.gnupg`, `.env` files, `/etc/shadow` and friends,
`/etc/sudoers`, SSH host keys, key and certificate files (`id_*`, `*.pem`,
`*.key`, `*.p12`, `*.pfx`, `*.ppk`), password databases, shell and client
histories, `.npmrc`, `.pypirc`, `.git/config`, `.git-credentials`, `.netrc`,
`.pgpass`, `.my.cnf`, `.htpasswd`, cloud and container credentials (`.aws`,
`.kube`, `.docker`, `gh`, `gcloud`, `.azure`, `.vault-token`) and process
environments under `/proc`. The full list is `builtInPatterns`, and the app
shows it under "View built-in blocked paths". The user can add patterns
under "Extra blocked paths", and can set the built-ins aside with "Read
sensitive paths"; their own patterns apply either way.

The order matters. The guard is given a path only **after the server has
canonicalised it** (SFTP `realpath`), because a name checked before is not the
file that is opened: a symlink named `notes.txt` can point at
`~/.ssh/id_ed25519`. An absolute path is also checked as asked, for a server
whose `realpath` does not follow links. The guard normalises `.`, `..` and
`//` itself, and a path is blocked when it or any directory above it
matches, so listing `~/.ssh` is refused as well as reading inside it.

A blocked path leaves no trace. Asking for one gives the same refusal
(`path_not_available`) as a path the server cannot resolve, and `list_dir`
and `search_files` drop blocked entries from their results without a count
or a note. It is a default set. It cannot know that a file called
`deploy-notes.txt` contains a password, and the README says so.

### Redaction

Output passes `redact` in this order: private-key blocks (PEM, and the
private lines of a PuTTY key) are replaced with `[private key redacted]`
across the **whole** output, then the app's diagnostics `scrub` removes
known secrets and common secret shapes, and only then is the result capped at
64 KiB (cut on a UTF-8 boundary, with a marker saying how much was dropped; a
log keeps its tail, a file its head). The cap comes last on purpose: cutting
first could land inside a key and leave half of it behind as
ordinary-looking text, and the scrubber should always see a secret whole. A
key cut off by the caller's own `offset` or a log tail is handled too: a
BEGIN with no END is redacted to the end, and an END with no BEGIN takes the
key-like lines above it. If redaction itself fails, nothing is returned. The
redactor is a second line behind the path guard, not a replacement for it.
The reads are bounded before that, too: `tail_log` on a file reads only its
last 256 KiB, `read_file` fetches only the window asked for, and
`search_files` runs `find -maxdepth` under `timeout 20` where the server has
it.

### Audit log

`bridge_audit.dart` appends one JSON line per call to
`<data>/bridge/audit.log`: time, assistant, host name as asked, tool,
arguments (private keys and secrets removed, cut to 500 characters), outcome
(`ok`, `refused` or `error`), detail (the refusal code or the error message,
scrubbed), milliseconds and, since 1.7.0, `approval`: how a change was allowed
or why not (`none`, `allowed_command`, `grant`, `full_control`, `once`,
`for_a_while`, `denied`, `timed_out`, `withdrawn`) and, since 1.8.0, `via`:
where a card's answer came from when it was not this computer
(`controller:<phone name>`; absent on older lines and local answers). A line
from 1.6.0, with no such field, reads as `none` and is kept. A call the user
approved but that was then refused or stopped before it ran is recorded as
refused or error with its `approval` as given (`once` or `for_a_while`) and a
`detail` that starts `refused_after_approval: `: approved, but not run.
`write_file` records the path, the byte count and `if_exists`, **never the
content**; `run_command` and `run_on_hosts` record the command, cut to 500
characters; `send_input` records its arguments, the terminal id and the text
typed, scrubbed and cut to 500 characters together; `read_screen` records
nothing of the screen; `desktop_type` records only the desktop id and `[N
characters, not recorded]`, since what is typed on a desktop may be a password
(the desktop module's `auditArgs` hook); `start_job` records the command (cut
to 500), name and folder. It records refusals and errors too, and **never the
output**: the log lasts longer than the output and is shown more freely. (An
error's message is the `detail`, and some quote a short error the server
printed, such as a failed `systemctl`'s stderr, scrubbed and cut to 500
characters.) The file is created owner-only (`chmod 600` on POSIX, best
effort) and so is the rotated copy. It rotates at 512 KiB to `audit.log.1`,
keeping one older file. The "Activity" screen ("AI Bridge activity") reads
both; "Clear" deletes both. A write that fails never fails the call; the
screen says the log has a gap.

### Stores that agree with their files

`BridgeClientStore.create`, `confirm` and `revoke`, and `HostStore.add` and
`update`, write the file and, when the write fails, put the in-memory state
back as it was and rethrow. What the app shows and, above all, what the bridge
uses (which tokens sign in, which hosts an assistant may read) therefore
never differs from what is stored: a change that held only until the next
start, such as a host taken out of AI access that would come back at restart,
or a revoked token that is revived, cannot happen silently. A revoke that
cannot be saved leaves the pairing in place and the Settings screen says the
pairing still works. The host store's rollback covers every host save in the app
(an edit, a quick-connect save, the checklist), not only AI access.

### Backups, and the lock

Backups never carry the bridge. An exported host has `aiAccess` off (and no
allowed commands and no terminal or desktop switch) and the exported settings
carry the bridge fields at their defaults; on import every host arrives with
access off, no allowed commands and the terminal and desktop switches off,
whatever the file says, so restoring an old backup on a new machine cannot
hand an assistant a server. Importing keeps **this device's** bridge settings
(`withBridgeFrom`): a backup can neither switch the bridge on nor weaken its
blocked paths. `bridge_clients.json` is not part of a backup, so tokens (or
their hashes) are never exported, and neither are `bridge_jobs.json`, the
built-in assistant's switch and service settings (stripped like the other
bridge fields), its API key (a secure-storage entry no backup reads), the
phone pairings or a phone's saved controller token.

While the app is locked, `decideBridgeCall` refuses everything, `list_hosts`
included, so a client that is already connected gets nothing until the user
unlocks the app. A lock also withdraws every waiting card, ends every timed
approval and closes every terminal an assistant drives.

The consent dialog ("Turn on the AI Bridge?") is shown every time the bridge
is switched on, not only the first time: pairing does not need the bridge on,
so a paired assistant does not mean the explanation was ever read.

### Threat model

- **Another process of the same user.** Not defended against, and said so.
  It can read the token from the client's config, the locator file, or the app
  itself. The bridge's protections are about what an assistant can do, not
  about hiding it from the user's own account. This is the same stance as the
  Linux credential file.
- **Another local user.** On Linux the socket and its directory are not
  openable. On Windows the locator file sits in the user's profile, so the
  secret and port are hidden, and the handshake needs both the secret and a
  valid token, which the app stores only as a SHA-256 hash.
- **A malicious or compromised server.** Its output is data. It can try to
  steer the assistant (prompt injection); the skill and the instructions tell
  the assistant to treat it as data, but that is advice to a model and not
  enforcement. What stops damage is that every change needs a person's yes on
  a card showing exactly what will run (or something the user set up
  beforehand), and that the guard, the cap and the audit log bound what can
  be read. The skill also tells the assistant never to act on text a server
  returned, and never to ask the user to loosen a setting.
  A malicious server cannot reach another host through the bridge, as each
  tool call names one host.
- **A leaked client config.** It holds the token. Whoever has it can read
  from the shared servers, only while the app is running with the bridge on
  and unlocked, and never anything the policy refuses. In 1.7.0 it can also
  *ask* for changes where the user allowed them: each still needs a card
  (and the user can see which assistant asked), except an exact allowed
  command and a live timed approval, which are the two ways around a card
  that the user chose.
- **An assistant, or text that steers it, trying to get changes through.**
  Rephrasing, splitting a command, another tool, another host: each is a new
  card, and the card shows the exact command (for a file, its path, size and a
  preview marked when partial), so the user decides on what runs. The things that skip a card are the user's own settings: an
  allowed command is an exact string, and a timed approval is per assistant
  and host and ends at the clock, on revoke, on a lock and on a host change.
  The skill tells the assistant not to ask for either.
- **A confusing card.** Control characters, a carriage return, bidirectional
  overrides, invisible and other format characters, look-alike spaces,
  private-use and unassigned code points and combining marks that could hide
  a character are drawn visibly (`visible_text.dart`), the card defaults to
  Deny and its Allow buttons wake after a second. A very long file preview can
  still hide that more is written than shown; a warning at the top of the card
  says so when it is partial, and the card gives the exact size. Revoking the
  assistant in Settings invalidates the token at once and stops its calls in
  progress; the activity log shows what was asked for.
- **The AI provider.** Out of scope for the app by construction: whatever an
  assistant reads is sent to a provider the user chose. For an assistant on
  the computer, its client sends it to the client's own provider. For the
  built-in assistant, the app sends it itself, from the device straight to the
  address the user configured, over https (or to `localhost`), with the user's
  key; nothing passes through Dhiva Labs. The privacy policy says this
  plainly. A model address the user types is the user's trust: the app only
  checks the scheme. - **Full control.** A host at `fullControl` removes the
  card, which is the control everything above rests on. It is the user's
  explicit choice, behind a confirmation that says so, off by default, never
  in a backup, and recorded in the audit log as `full_control`; the app lock
  and the bridge switch still refuse everything. A mistaken or misled
  assistant (a prompt injection in a log line) can do anything the sign-in
  user can on that host, with no check but its own care. The skill and the
  instructions say so, and ask it to behave as if a card were there. - **A
  job.** It outlives the call, the connection and the app, is the user's
  process on the user's server, and its log holds whatever the command
  printed. It is started with a card (or full control or a timed approval,
  never an allowed command). Only the starting client can read or stop it;
  nothing in the app lists or stops jobs, and a stopped host's jobs keep
  running. - **A desktop.** One yes shows the assistant everything on the
  signed-in user's screen and lets it act as that user, until Take over, Stop,
  idle, or one of the lifecycle ends. See "The assistant desktop". A
  screenshot goes to the provider as an image and cannot be redacted; what is
  typed is never logged. - **A lost phone.** Its controller token can answer
  the user's cards while Phone control is on, and reaches the computer only
  through the phone's own SSH login; it can never call a tool. Removing its
  pairing (or switching Phone control off) ends the session at once. The token
  on the phone is in secure storage, never in a backup.
- **A planted `claude` on the user's `PATH`.** One-click runs the first
  `claude` that answers `--version`, and hands it the token. A program
  planted earlier on the user's `PATH` would be run and would receive it.
  The confirmation shows the full path and version before anything runs, and
  the user's `PATH` is the user's own trust: this is the same stance as for
  any command typed in a terminal. A file not named `claude`, a relative
  path and a network share are never run. A marketplace named `dhiva-labs`
  that points somewhere else is shown and warned about for the same reason.
- **Windows `.cmd` shims.** A `claude.cmd` or `.bat` must be started through
  the shell. Its path is the one string on that command line that is not a
  constant, so a path with a character `cmd.exe` interprets (quotes,
  `& | < > ^ % !`, `, ; =`, and `( ) @`, which also makes it drop the
  quotes round a path with a space) is refused rather than escaped; a
  `Program Files (x86)` shim is therefore not run, and the manual route is
  the fallback.
- **A timeout ends the program, not what it started.** On timeout the
  connector kills the process it started (on Windows through a shim, that is
  the shell). Anything that process had already started, such as a child or a
  clone, is not tracked and may run on; the connector only stops waiting for
  its pipes after two seconds.
- **What an approved terminal allows that nothing else does.** A live shell
  as the saved sign-in user, on a host the user chose, with any command typed
  with no further card until the user takes over, stops it or it idles out.
  The blocked-path list does **not** apply inside it: it guards the bridge's
  own file tools, and a shell can `cat` anything the account can read.
  `read_screen` removes only private-key blocks and the secrets the app knows,
  so a key can still be read in pieces or encoded, and anything else on the
  screen goes to the assistant and from there to its provider. The same is
  true of `run_command`, a command with a card: the path guard judges paths
  the read tools are given, never a command's text. That is why the terminal
  is a separate per-host switch, with its own warning, a card every time (never
  a timed approval or an allowed command), visible in the app and audited call
  by call.
- **Prompts outside the app.** The app never prompts for a bridge call, but
  it cannot stop other software from doing so: an SSH agent may ask the user
  to confirm a signature or touch a hardware key, and a desktop keyring may
  show its own unlock dialog when the saved sign-in is read.

#### Known limits

- **Windows, the token on the wire.** The proof step keeps the launcher from
  sending its token to whatever holds a stale port after a crash. After the
  proof, the token (and the secret) cross the loopback connection in clear.
  If another local program could share the app's live port, it could relay
  the proof and read the token. Whether the Windows bind is exclusive
  (`SO_EXCLUSIVEADDRUSE`) is not verified; `store/release-checklist-1.6.md`
  has the check.
- **Windows, availability.** Any local program can connect to the port.
  One that keeps 8 handshakes open, reconnecting as each times out, can keep
  a real launcher out. It learns nothing and can read nothing; it only
  denies service. (On Linux only the user's own account can connect.)
- **One-click on Windows has never run on Windows.** The `.cmd` shim
  handling, the refusal of paths with shell characters, the drive-letter and
  network-share checks, and `PATHEXT` ordering are written from the
  documentation and unit-tested with a fake runner on Linux. The release
  checklist has the checks to make on a real install.
- **The manual route and shell history.** The third pasted command puts the
  token in the shell's history file. One-click avoids it; the connect screen
  carries a one-line note saying so under the commands, and the docs tell the
  user to delete the line, or revoke and pair again if the history is shared.
- **Resolve, then read.** A path is resolved and checked, then read, in two
  steps. Something that can write on the server could swap a symlink in
  between. Exploiting that already needs write access on the server, which
  is more than the bridge would give it.
- **A stop does not reach a process that left its group.** TERM then KILL goes
  to the command's process group. A program that moved itself into a session of
  its own (`setsid`) survives a stop, and so does a job a command started
  that finished before the stop. The stop is of what the command still holds.
  On a server with no `setsid` the command is not put in a group of its own,
  and only its main process is signalled.
- **The card does not alert the user.** No window attention, no sound. With
  the app in the background a card goes unseen and ends as a denial after
  120 seconds.
- **A jump host's own edits are not a change of server.** `bridgeSameServer`
  compares the jump host's id; editing the jump host's entry keeps the timed
  approvals, waiting cards and terminals of the hosts behind it.
- **Same-size, same-second file changes defeat the changed-file check.**
  `write_file` compares the replaced file's size and modification time with
  what the card was built from. A change that keeps both (the same number of
  bytes within the same second, on a server whose times are whole seconds)
  is not noticed.
- **A replacement keeps the mode and nothing else.** It is a temp file and a
  rename, so the file's owner, its access lists and extended attributes are
  those of a new file, and other hard links to the old file keep the old
  content. If the server will not restore the mode, the result says so.
- **A change can time out while queued.** The deadline includes waiting for
  one of the 2 change slots and connecting; a command can be stopped before it
  ever ran, and one that was stopped may have done part of its work.
- **Login shells that are not POSIX.** The command line is built so that no
  backslash is inside single quotes, which is correct for fish, but only sh and
  bash were run; fish itself was not (`store/release-checklist-1.7.md` has the
  check).
- **Nothing of 1.7.0 or 1.8.0 has run on Windows yet.** The loopback channel
  carrying the new tools, the card, the terminal session and the stop on a
  server are written from the code and tested on Linux; the release checklist
  lists what to check on a real install. The commands and the stop wrapper run
  on the *server*, so they need a POSIX `sh` there; a Windows server is not
  supported for changes, and process stop on one is out of scope.
- **macOS and Android have no local channel.**
  `BridgeService.channelSupported` is true only on Linux and Windows, so no
  paired assistant can reach those apps and no phone controls them; the AI
  tools, the per-host levels, the cards and the built-in assistant do run
  there. - **Desktop screenshots need Anthropic.** The OpenAI-compatible
  connection carries text only, so the model is told an image came back and
  cannot see it. A local `http` model server does not work on Android
  (cleartext is off, and `localhost` is the phone). - **The built-in
  assistant's prompt predates the new tools.** It states the standing rules
  but does not yet mention jobs, desktops or full control, and a long request
  can fail if the system pauses the app in the background. - **Phone control
  on Windows is unproven.** The phone's command is a POSIX `sh` script; a
  Windows computer needs an SSH login shell that can run it. The launcher
  search finds the package installs and the snap and Flatpak, not a tarball or
  AppImage kept elsewhere. - **Jobs are not stoppable from the phone or from
  any screen.** The protocol has the item kind; no source is registered.
- **The translations of the new 1.7.0 text** (the eight languages other than
  English) were written by machine and have not been read by native speakers.
- **Empty-looking folders.** A directory that holds only blocked entries
  lists as `[empty]`, and a search through it finds nothing. That is the
  price of leaving no trace.

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


## Remote desktop

The design and its reasons are in [`docs/REMOTE_DESKTOP_PLAN.md`](docs/REMOTE_DESKTOP_PLAN.md); this is where the
pieces live.

```
screens/remote_desktop_launch.dart   "Remote desktop…": probe, chooser, virtual-desktop
                                     setup, and the openers that tie the layers below
screens/remote_desktop_screen.dart   the viewer: states, toolbar, input, Reconnect
screens/remote_app_launcher.dart     "Open an app in a window" (X11 forwarding)
widgets/remote_desktop/              compositor (GPU framebuffer), painter, cursor,
                                     input controller, key bar, soft keyboard
services/remote_desktop/
  remote_screen_session.dart         the one interface the viewer draws from
  csrd_*.dart                        CrossShell agent protocol, tiles, client, keymap
  rfb_*.dart                         VNC client for Macs (Screen Sharing)
  agent_*.dart                       probe, bundled-agent manifest, deploy, launch
  virtual_desktop.dart               Xvfb desktops, kept or torn down with the viewer
  remote_input*.dart                 pure input logic: scroll, moves, touch, text
services/remote_app_runner.dart      one exec with x11-req per program
```

The agent is CrossShell's `crossshell-host`, bundled xz-compressed under
`assets/agents/` with its hashes pinned in the committed `manifest.json`. It
is uploaded to a sha256-named folder on the server, checked again before
every launch, started in the user's session (`systemd-run --user` on Linux,
a run-once interactive task on Windows) on 127.0.0.1 only, and reached
through a `direct-tcpip` channel: no listening port anywhere, SSH the only
authentication, the agent's token a second lock against other local users.

Nothing of this runs until a remote desktop is opened: no probe at connect,
no upload, no background work.

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
