# Remote desktop — plan

Status: built and verified end to end on 2026-10-27 (see "Verified" at the end). Target release: **1.6.0**.

- SecureShell Go work is on `feature/remote-desktop`, branched from
  `release/1.5.0`. That release
  ([Dhiva-Labs/SecureShellGo#4](https://github.com/Dhiva-Labs/SecureShellGo/pull/4))
  is still unmerged. It brings dartssh2 4.1 and already ships X11
  forwarding, so the feature has to sit on top of it. Rebase onto `main`
  once 1.5.0 merges.
- CrossShell work is on `feature/ssgo-agent`, branched from CrossShell
  `main`, and will be released as CrossShell engine 0.2.0.

## Goal

From any SecureShell Go client (Android phone or tablet, Linux, Windows,
macOS), on a host you are already connected to over SSH:

1. **Desktop mode.** The host has a logged-in desktop: see it and control
   it, TeamViewer-style.
2. **Headless mode.** The host has no desktop: run its GUI apps anyway,
   either
   - **native windows**: each remote app opens as an ordinary window on
     your own desktop (X11 forwarding), or
   - **virtual desktop**: the app starts a throwaway X display on the
     server and shows it in the same viewer as desktop mode.

All of it rides the SSH connection that is already open. Nothing on the
remote listens beyond 127.0.0.1, nothing is installed system-wide, and SSH
authentication is the only authentication.

## Decisions taken

| Question | Decision |
|---|---|
| What runs on the remote for desktop mode | CrossShell's `crossshell-host` agent, uploaded over SFTP and run per session. Not stock VNC/RDP: GNOME 50 on Wayland only speaks RDP (`grdctl` has no VNC), and Windows has no VNC server. |
| Headless | Both: native windows on Linux clients, virtual desktop on every client. |
| Remote OSes | Linux, Windows, macOS. Phones must work as clients. |

## What works where

Remote side:

| Remote | Desktop mode | Virtual desktop | Native windows |
|---|---|---|---|
| Linux, GNOME on Wayland | Agent with the Mutter backend. No consent prompt; GNOME shows its own screen-share indicator. | Xvfb + agent (X11 backend) | X11 forwarding |
| Linux, any X11 desktop | Agent with the X11 backend | same | same |
| Linux, KDE / wlroots on Wayland | Agent with the portal backend. A consent dialog appears **on the remote screen**, so someone has to be there. | same | same |
| Linux, headless server | — | Xvfb + agent | X11 forwarding |
| Windows 10/11 | Agent (DXGI + SendInput), launched into the logged-in user's interactive session | — | — |
| macOS | VNC backend against the built-in Screen Sharing (Phase 5) | — | — |

Client side:

| Client | Viewer (desktop + virtual) | Native windows |
|---|---|---|
| Android | yes, with trackpad and direct-touch modes | no, so it offers a virtual desktop instead |
| Linux | yes | yes, through the local X server or XWayland |
| Windows | yes | no in v1 (later via VcXsrv, maybe) |
| macOS | yes | later, via XQuartz |

## Architecture

```
SecureShell Go (pure Dart, every platform)
  RemoteDesktopController            one per open remote-desktop view
    AgentDeployer                    probe -> upload (sha256-addressed) -> launch -> read host.json
    SSHClient.forwardLocal           channel to 127.0.0.1:<port> on the remote; no local listener
    CsrdClient                       Dart port of crossshell-proto's wire protocol
    TileDecoder                      Fill | Raw | Deflate (dart:io zlib, in an isolate) | JPEG (ui codec)
    FrameCompositor                  persistent GPU ui.Image; each frame draws prev + dirty tiles -> toImageSync
  RemoteDesktopScreen                fit / 1:1 / pinch-zoom, cursor overlay, input mapping, toolbar
  VirtualDesktopLauncher             Xvfb + app or session + agent, torn down as one unit
  X11ForwardService                  exec with x11-req; onX11Forward -> local X socket, cookie swap

Remote (nothing system-wide)
  Linux    ~/.cache/secureshellgo/agent/<sha256>/crossshell-host
  Windows  %LOCALAPPDATA%\SecureShellGo\agent\<sha256>\crossshell-host.exe
  runtime  a fresh 0700 dir per session holding host.json (port, token, pid)
```

Two notes on the client design:

- **Decoding.** Dart has no native zstd. `dart:io`'s zlib *is* native C,
  which is why Phase 0 adds a deflate tile encoding.
- **Compositing.** Each frame records the previous `ui.Image` plus only
  the changed tiles into a picture and calls `toImageSync`. The
  framebuffer never leaves the GPU and no full-frame copy is made per
  frame.

## Phase 0: CrossShell engine changes (in `~/dhiva-labs/cross_shell`)

1. **`CAP_DEFLATE` (caps bit 0).**
   - It goes in `Hello.caps`, which is unused today: every sender writes
     0.
   - When the viewer sets the bit, the host encodes lossless tiles with
     zlib instead of zstd.
   - `Welcome.caps` echoes the bits the host accepted.
   - CrossShell's own viewer keeps sending 0 and still gets zstd.
2. **Flags for remote-launched agents.**
   - `--runtime-dir <path>`, so a SecureShell Go session never collides
     with an installed CrossShell agent's lock or `host.json`.
   - `--exit-when-idle <secs>`: the agent exits when no viewer has
     connected yet, or after the last viewer leaves. A dropped SSH link
     therefore never leaves an agent behind.
   - Both are additive. CrossShell's defaults don't change.
3. **Connect notification.** On connect, the remote shows a desktop
   notification saying the screen is being viewed from `<viewer_name>`:
   - Linux uses `org.freedesktop.Notifications`, which is pure zbus.
   - Windows uses a toast.
   - It can be turned off with a flag.
4. **Linux build flavours.** The `pipewire` crate links `libpipewire-0.3`
   at load time, so the current binary will not even start on a minimal
   server. Two flavours fix that:
   - `full`: Mutter, portal and X11 backends, glibc 2.31 baseline via
     zigbuild.
   - `x11`: pipewire feature off. x11rb and zbus are pure Rust, so this
     flavour is a **fully static musl** binary that runs on any Linux. It
     is what virtual desktops use.
5. **Artifacts.**
   - Binaries:
     - linux-x86_64 full
     - linux-x86_64 x11 (musl)
     - linux-aarch64 full
     - linux-aarch64 x11 (musl)
     - windows-x64
     - windows-arm64
   - They are published as a CrossShell release.
   - **Test fixtures.** A `crossshell-proto` example writes encoded
     frames plus their expected decoded pixels, as golden fixtures for the
     Dart decoder.

SecureShell Go pins one CrossShell engine version.
`tool/fetch_agents.sh` downloads that release's agent binaries, checks
them against SHA256s committed in the repo, and places them in
`assets/agents/`. That folder is gitignored, and CI runs the same script.
The binaries are only ever uploaded to servers, never executed on the
device.

## Phase 1: Dart protocol and decoder (pure Dart, unit-tested)

All of it lives in `lib/services/remote_desktop/`:

- **`csrd_messages.dart`**
  - Every message in `msg.rs`: encode and decode, plus the
    `MessageReader` framing.
  - Enforces the same limits as Rust: `MAX_PAYLOAD`, the 1 KiB
    pre-auth cap, and `MAX_DIMENSION`.
- **`csrd_tiles.dart`**
  - Decodes the rects of a frame into RGBA tiles.
  - Fill and Raw are decoded inline.
  - Deflate is inflated in an isolate.
  - JPEG goes through `ui.instantiateImageCodec`.
- **`csrd_client.dart`**
  - Handshake: Hello → Welcome or Reject → Start.
  - Frame-ack flow control (`MAX_INFLIGHT_FRAMES` = 2), ping/pong,
    clipboard, notices, display changes.
  - Takes a byte stream and a sink, so tests use in-memory pipes and the
    app uses an SSH forward channel.
- **Tests.** Round-trip every message, plus Rust-generated golden
  fixtures: the Dart decode must equal the Rust encoder's input pixels.

## Phase 2: viewer UI

- **Entry points.** A **Desktop** action on the session screen next to
  Terminal and Files; it reuses the live connection, no second login.
  Also a host-list context action.
- **Desktop input.**
  - Mouse, scroll and keyboard. `HardwareKeyboard` events map to evdev
    codes through a port of `keymap.rs`.
  - `ReleaseAll` is sent on focus loss and on disconnect.
- **Phone and tablet input.**
  - **Trackpad mode** (default):
    - relative cursor
    - tap = left click
    - two-finger tap = right click
    - two-finger drag = scroll
    - pinch = zoom the view
  - **Direct mode**: you click where you touch.
  - The soft keyboard comes with an extra-keys bar adapted from
    `terminal_key_bar.dart`: Ctrl, Alt, Super, Esc, Tab, arrows, F-keys
    and Ctrl+Alt+Del.
- **Toolbar.**
  - display picker
  - quality: Lossless / Balanced / Speed
  - view-only
  - clipboard sync
  - fps and latency readout
  - fullscreen
  - disconnect
- **Android lifecycle.** When backgrounded, stop acking so the host
  pauses, and resume when the app returns. The existing foreground
  service keeps the SSH link alive.

## Phase 3: deploying and launching the agent

### Linux

1. **Probe, in one exec:**
   - `uname -sm`
   - `id -u`
   - `loginctl` sessions for this uid: Type, Active, State, Display
   - `systemctl --user show-environment`
   - graphical processes owned by this uid
   - whether `Xvfb` and `xauth` exist
   - whether `libpipewire-0.3` is present
2. **Classify the host:**
   - this user has a desktop: Wayland-GNOME, X11, or other Wayland
   - only someone else has a desktop: not reachable, and the app says so
   - headless
3. **Upload.**
   - The path is sha256-addressed.
   - The app skips the upload when `sha256sum` on the remote already
     matches.
   - The hash is re-checked before every launch, so a tampered file is
     never run.
4. **Launch.**
   - `systemd-run --user --collect --unit=ssgo-rd-<rand> <agent>
     --runtime-dir $XDG_RUNTIME_DIR/ssgo-rd-<rand> --exit-when-idle 30`.
     The systemd user manager already carries GNOME's `WAYLAND_DISPLAY`,
     `DISPLAY` and D-Bus address.
   - Fallback: take the environment from `/proc/<session leader>/environ`
     (same uid), then `setsid`.
5. **Connect.**
   - Read `host.json` over SFTP.
   - `forwardLocal('127.0.0.1', port)`.
   - Send Hello with the token and `CAP_DEFLATE`.
6. **Teardown.**
   - Normally: `ReleaseAll`, close, `systemctl --user stop
     ssgo-rd-<rand>`.
   - If the link drops, `--exit-when-idle` covers it.

### Windows (OpenSSH server)

1. **Probe.**
   - Architecture via `powershell -NoProfile`.
   - Whether the SSH user has an interactive session, via `query user`.
2. **Upload** to `%LOCALAPPDATA%\SecureShellGo\agent\<sha256>\`.
3. **Launch into the interactive session.** An SSH login runs in a
   non-interactive session that cannot see the desktop, so the agent goes
   in through a run-once interactive task:

   ```
   schtasks /create /tn SSGo-RD-<rand> /tr "<agent> --runtime-dir … --exit-when-idle 30" /sc once /st 00:00 /it /f
   schtasks /run /tn SSGo-RD-<rand>
   schtasks /delete /tn SSGo-RD-<rand> /f
   ```

   `/it` places it in the logged-on user's session.
4. **Known limits.**
   - If nobody is logged on, desktop mode is not available.
   - The lock screen and UAC prompts can't be captured. This is CrossShell's
     open "SYSTEM service" item.

## Phase 4: headless

### 4a. Virtual desktop (Linux remote, any client)

- **Needs Xvfb.** If it is missing, the app shows the exact install
  command for the distro, read from `/etc/os-release`. **Run in
  terminal** opens a terminal tab with the command typed but not sent,
  and you type your own sudo password.
- **Start:**
  - Pick a free display `:N`.
  - Create an xauth cookie.
  - Run `Xvfb :N -screen 0 <w>x<h>x24 -nolisten tcp -auth <file>`, sized
    to the client's viewport.
- **What runs inside it, one of:**
  - a single app: typed, or picked from the remote's
    `/usr/share/applications`
  - a desktop session, when one is installed: xfce4, LXQt, MATE, Openbox
    or IceWM, detected
- **The agent** runs with `CROSSSHELL_LINUX_BACKEND=x11 DISPLAY=:N`, using
  the static x11 flavour.
- **Teardown.** Everything runs in one `systemd-run --user` unit, so
  closing the viewer kills the X server, the apps and the agent together.
  A "Keep running after I disconnect" option, with reattach, is open
  question 4.

### 4b. Native windows (Linux client)

**Mostly done in 1.5.0.** `lib/services/x11_forwarding.dart` already does
everything below except the dedicated action:

- the per-host ForwardX11 switch
- the fake cookie, setup rewrite and per-connection untrusted `xauth`
  cookies
- trusted fallback on Windows, through VcXsrv or X410

What is left for 1.6:

- **"Open an app in a window"**: one exec with `x11`, so no terminal is
  needed. It keeps a list of recent commands and can pick from the
  remote's `.desktop` entries.
- **A virtual-desktop offer** whenever there is no local X server:
  Android, Windows without an X server, or the server refusing
  `x11-req`.

For reference, the original design, now implemented:

- **The action.** "Run an app in a local window" takes a command and keeps
  a recent list.
- **The request.**
  - `execute(cmd, x11: SSHX11Config(...))` with MIT-MAGIC-COOKIE-1 and a
    **random fake cookie**.
  - dartssh2 2.22.4 already supports the `x11` request and `onX11Forward`.
- **Each forwarded X11 channel is handled the way OpenSSH does it:**
  1. Connect to the local X socket from `$DISPLAY`. That is usually
     XWayland at `/tmp/.X11-unix/X0`; the snap has the `x11` plug.
  2. Parse the client's connection-setup packet.
  3. Check that the fake cookie matches.
  4. Swap in the real cookie from `$XAUTHORITY`, or `~/.Xauthority`.
     This needs a parser for the binary Xauthority format.
  5. Pipe both directions.
  6. A wrong cookie closes the channel.
- **Server checks.**
  - `X11Forwarding yes` and `xauth` are required.
  - If the server refuses the request, the app explains why and offers a
    virtual desktop instead.
- **Opt-in per host, with a warning.** Trusted X11 lets the remote app see
  local keystrokes, the same trade-off as `ssh -Y`.
- On Android and Windows clients the action is hidden and only the virtual
  desktop is offered.

## Phase 5: macOS remotes (VNC backend)

- **A second frame source** behind the same viewer: a pure-Dart RFB 3.8
  client.
  - Security types:
    - VNC auth (DES)
    - Apple Remote Desktop, type 30: Diffie-Hellman + AES-128 via
      pointycastle
  - Encodings: Raw, CopyRect, ZRLE (zlib), and the cursor
    pseudo-encoding.
  - Keys go out as X keysyms, mapped from evdev.
- **Connection.** Tunnel to `127.0.0.1:5900` on the Mac.
- **One-time setup.** Screen Sharing has to be enabled once on the Mac
  (System Settings → General → Sharing). The app detects when it is off
  and explains how to turn it on.
- **Side benefit.** It also covers any Linux host that already runs a VNC
  server.

## Security model

- **Authentication.**
  - SSH is the only authentication.
  - The agent's 32-byte token, from a 0700 runtime dir, keeps other local
    users on the remote off the loopback port.
- **No exposed ports.**
  - The agent binds 127.0.0.1 only.
  - The viewer opens no local listening port: it is a direct forward
    channel.
- **Binary integrity.** The uploaded agent is hash-checked before every
  launch, and the hashes are pinned in this repo.
- **People at the remote are told.** A notification appears on connect,
  and GNOME also shows its own screen-share indicator.
- **Input safety.** View-only is a toggle, and every held key and button
  is released on disconnect.
- **Asking first.**
  - The first time on each host, the app explains what it uploads and
    where, then asks.
  - X11 forwarding is opt-in per host.

## Testing, and the isolation rule

**The isolation rule.** Nothing ever captures or injects into a live
desktop without explicit OK. The Mutter API needs no consent, so a leaked
D-Bus address drives the real screen. Linux e2e therefore runs only in
isolated sessions:

- a private `dbus-run-session -- gnome-shell --headless --virtual-monitor`
  for the Mutter path
- Xvfb for the X11 path
- every environment built with `env -i` and an explicit D-Bus address, so
  nothing falls back to the live session bus

The test layers:

- **Exec, SFTP and forward paths:** the local demo sshd (`~/ssgo-demo`,
  ports 22301/22302).
- **Unit tests:**
  - every protocol message
  - golden tile fixtures
  - the X11 setup-packet parser and cookie swap
  - the Xauthority parser
  - the probe and classification parsers
- **Android:** the emulator viewer against an agent running in a headless
  session behind the demo sshd.
- **Windows:** the build laptop (`dhiva@192.168.0.129`), but only with the
  user's OK, because it captures that machine's real session.

## Work breakdown

Each workstream owns its files strictly.

| Stream | Model | Owns |
|---|---|---|
| A. Engine changes, Phase 0 | Opus | `~/dhiva-labs/cross_shell/engine/**` |
| B. Protocol, decoder, client, Phase 1 | Opus | `lib/services/remote_desktop/csrd_*.dart`, `test/remote_desktop/csrd_*` |
| C. Viewer UI and input, Phase 2 | Sonnet | `lib/screens/remote_desktop_screen.dart`, `lib/widgets/remote_desktop/**` |
| D. Agent deploy/launch and virtual desktop, Phases 3 + 4a | Opus | `lib/services/remote_desktop/agent_*.dart`, `virtual_desktop.dart` |
| E. "Open app in a window" + fallback, Phase 4b remainder | Sonnet | `lib/screens/remote_app_launcher.dart` (reuses the 1.5 `x11_forwarding.dart`) |
| F. VNC backend, Phase 5 | Sonnet | `lib/services/remote_desktop/rfb_*.dart` |
| Lead | | Session-screen and host-settings integration, `pubspec`, e2e, docs, release |

**Order.**

1. A and B start together. B needs A only for the golden fixtures, and the
   message spec is already fixed by `msg.rs`.
2. C starts once B's client interface is frozen; it is defined up front.
3. D and E run alongside C.
4. F comes last.

## Answered questions (2026-10-27)

1. **macOS:** there is no Mac. The VNC backend is built and tested
   against a Linux VNC server, and is marked unverified on real macOS.
2. **Windows e2e:** the build laptop (`dhiva@192.168.0.129`) is OK for
   desktop-mode e2e against its real session.
3. **Agent binaries:** they are bundled in the app (`assets/agents/`).
   Nothing is downloaded at runtime.
4. **Persistent virtual desktops:** a user option, "Keep running after I
   disconnect", with a list of running virtual desktops to reattach to
   and stop.

**Linux remote test target:** the LXD VM `snaptest` (Ubuntu 24.04, has
Xvfb and xauth). Captures and input stay inside the VM. A private
headless gnome-shell in that VM covers the Mutter path.

## Verified (2026-10-27)

**Linux VM (headless, `snaptest`).**
- The chooser, the virtual-desktop setup and a live Xfce desktop all worked, both in the Linux build and in the Android release APK on an emulator.
- From the phone, a tap opened a terminal on the remote desktop, and typed text ran there.
- A desktop kept running survived a disconnect and an app reinstall, and was reattached.
- Stopping it left nothing behind.
- A desktop that was not kept was torn down when the viewer closed.

**Windows laptop (real session).**
- The agent was uploaded, launched into the interactive session and streamed the real desktop. This was view-only, with no input sent.
- After stopping, no process and no scheduled task was left.

**Size.**
- All the Dart code adds 0.75 MB.
- The xz-compressed agents add 4.3 MB.
- Nothing extra runs until a remote desktop is opened.

**Not verified.**
- A real Mac, because there isn't one.
- The arm64 agents.
- Smart App Control actually blocking the agent.
- Mutter capture of a real GNOME desktop over SSH. It was not run against this PC, because of the isolation rule.
