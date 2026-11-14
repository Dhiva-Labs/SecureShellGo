# 1.6.0 release checklist: the AI Bridge, what only real installs can prove

The bridge (a local MCP server in the app plus the `secureshellgo-mcp`
launcher an AI assistant starts) was built and tested on Linux. The
packaging below could not be run there: no snapcraft run, no PPA build farm,
no Windows, no nfpm, appimagetool, docker or flatpak-builder. Tick each box on a real install before release, and note what you
saw where one fails. Everything is off by default; every check starts with
Settings, AI Bridge, switch on, and one host set to "AI access (read-only)".

## 0. CI builds (first run on GitHub)

- [ ] `Desktop builds`: Linux x64 and arm64 and Windows x64 and arm64 each
      pass "Build the AI Bridge launcher", the architecture assertion (the
      launcher counts), and "Smoke-run the launcher from the archive". The
      Windows steps and the `tool/build_launcher.ps1` script have never run.
- [ ] The Linux tarball and the Windows zip each hold `secureshellgo-mcp`
      (`.exe`) beside the app.
- [ ] The snap jobs (amd64 and arm64) get past the part build (it failed on
      the first run of the merge commit, see section 1), then pass the
      architecture assertion and "Smoke-run secureshellgo.mcp
      confined": the launcher starts under the `mcp` app's confinement and
      answers with the "not running" error.
- [ ] `Other distros` (x64 and arm64): `tree.sh` finds `secureshellgo-mcp`
      in the archive and installs `/usr/bin/secureshellgo-mcp`; `pack.sh`
      passes its launcher check; `verify.sh` runs `secureshellgo-mcp` after
      installing the .rpm on Fedora and openSUSE and the Arch package on Arch
      (x64), and the .AppImage file with `SSG_BRIDGE_TOKEN` set on Fedora,
      each ending "exit code 1" with the JSON-RPC error; the arm64 Arch
      static check lists the launcher and its wrapper.
- [ ] `AUR PKGBUILD`: makepkg builds with the new
      `secureshellgo-mcp.wrapper` source and checksum, `pacman -Qlq` lists
      `/opt/secureshellgo/secureshellgo-mcp` and `/usr/bin/secureshellgo-mcp`,
      and the launcher smoke run after install exits 1 with the JSON-RPC
      error (`options=('!strip')` kept it whole).
- [ ] `Flatpak` builds with the separate `secureshellgo-mcp` module
      (`no-debuginfo`, `strip: false`). `Flatpak on Ubuntu`: `ldd` passes on
      `/app/lib/secureshellgo/secureshellgo-mcp`, "Smoke-run the launcher in
      the sandbox" passes for the exported command and for `flatpak run
      --command=secureshellgo-mcp`, and the app's window still comes up
      (its main command is now a script that hands over to the launcher only
      with `SSG_BRIDGE_TOKEN` set and stdin not a terminal).
- [ ] `Store MSIX` (x64 and arm64), first run with `tool\build_msix.ps1`:
      the package is still `build\msix\SecureShellGo-<version>-<arch>.msix`,
      the identity check passes, and "Check the AI Bridge launcher in the
      package" finds `secureshellgo-mcp.exe`, its `Application` and alias,
      and gets the JSON-RPC error from the copy taken out of the package.
- [ ] `Attach release assets`: the asset list is unchanged (the launcher is
      inside each package, not a separate asset).
- [ ] macOS job unchanged (the bridge is not available on macOS in 1.6.0,
      and no launcher is built there).
- [ ] Version strings bumped from 1.5.1 to 1.6.0 everywhere they are
      written by hand: `main` is at 1.5.1, merged into this branch, so
      `pubspec.yaml` `version:` (`1.5.1+15`) and `msix_version:`
      (`1.5.1.0`), `snap/snapcraft.yaml` (`'1.5.1'`), `debian/changelog`
      (a new `1.6.0~noble1` entry above `1.5.1~noble1`) and `appVersion` in
      `lib/app_version.dart` (`1.5.1+15`; what the About box and the
      bridge's `initialize` report). The plugin's
      `.claude-plugin/plugin.json` `version` is already 1.6.0. The release
      file names (rpm, Arch package, AppImage, Flatpak, AUR recipe, MSIX)
      take the version from `pubspec.yaml`.
- [ ] Privacy policy effective date set to the real release date, in both
      `docs/privacy-policy.md` and `docs/privacy-policy/index.html` (it says
      14 November 2026 today, the date it was written), and the date quoted
      in `store/play-data-safety.md` matches.
- [ ] The real-server test passes on a machine with `sshd`:
      `SSGO_SSHD=1 flutter test test/bridge_local_sshd_test.dart`.
- [ ] `claude plugin validate integrations/plugin --strict` and
      `claude plugin validate . --strict` pass, and
      `integrations/skill/SKILL.md` and
      `integrations/plugin/skills/secureshellgo/SKILL.md` are identical.

## 1. Snap (strict confinement)

- [ ] `snapcraft --use-lxd` builds; the snap has `secureshellgo-mcp` at its
      root and `snap run secureshellgo.mcp` exists (`snap info`).
- [ ] The part build found the Dart SDK at
      `$CRAFT_PART_BUILD/flutter-distro/bin/cache/dart-sdk/bin/dart` (the
      `override-build` step prints its version) and `tool/build_launcher.sh`
      compiled with it. The first CI run of the merge failed here with
      "'dart compile' does not support build hooks"; the fix (a temporary
      package of its own) was checked only with Dart 3.12.2.
- [ ] Bridge on in the snapped app. `endpoint.json` exists under
      `~/snap/secureshellgo/current/.local/share/com.dhivalabs.secure_shell_go/bridge/`.
      The app and `secureshellgo.mcp` resolve the same directory
      (`XDG_DATA_HOME` as the extension sets it).
- [ ] `SSG_BRIDGE_TOKEN=<token> snap run secureshellgo.mcp`, then
      `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}` on stdin:
      a JSON-RPC result, not the "not running" error.
- [ ] No AppArmor or seccomp denial in `journalctl -k | grep -i denied` while
      the launcher connects. `snap connections secureshellgo` shows no
      plug the `mcp` app needed beyond the main app's.
- [ ] Long `$HOME`: with a very long user name the socket falls back to
      `$XDG_RUNTIME_DIR/secureshellgo-bridge.sock`; the launcher still
      connects.
- [ ] A paired assistant lists hosts end to end (section 5).

## 2. Debian package (PPA)

- [ ] The Launchpad build (offline) succeeds: the "launcher" step in
      `debian/rules` runs with the vendored SDK, no network.
- [ ] `dpkg -c` shows `/opt/secureshellgo/secureshellgo-mcp` and
      `/usr/bin/secureshellgo-mcp`; `lintian` raises nothing new.
- [ ] The installed launcher is not stripped: run with no app it prints the
      "not running" error, never the Dart VM's usage text ("Usage: dartvm"),
      which is what a stripped `dart compile exe` binary prints. (debian/rules
      skips dh_strip for the whole package; keep it that way.)
- [ ] After `apt install`, `secureshellgo-mcp` on PATH answers the
      `initialize` line as in section 1 while the app runs, and with the
      "not running" error and exit 1 when it does not.
- [ ] A paired assistant lists hosts end to end (section 5).

## 2a. Fedora / openSUSE (.rpm) and Arch (.pkg.tar.zst, AUR)

- [ ] `rpm -qlp` and `pacman -Qlp` (and the AUR package) list
      `/opt/secureshellgo/secureshellgo-mcp` and `/usr/bin/secureshellgo-mcp`.
- [ ] The installed launcher is not stripped: `file` shows the same size as
      in the release tarball, and run with no app it prints the "not
      running" error, never "Usage: dartvm". (nfpm never strips; the AUR
      PKGBUILD keeps `options=('!strip')`.)
- [ ] "Connect an assistant" shows `secureshellgo-mcp`, and that command
      answers `initialize` with a result while the app runs with the bridge
      on, on Fedora, openSUSE Tumbleweed and Arch.
- [ ] "Connect Claude Code" appears when `claude` is installed, and works as
      on the deb (section 5a).
- [ ] A paired assistant lists hosts end to end (section 5).

## 2b. AppImage

- [ ] "Connect an assistant" shows the full path of the `.AppImage` file
      (not a `/tmp/.mount_…` path), and that path, run by an assistant with
      `SSG_BRIDGE_TOKEN` set, connects: `printf '%s\n'
      '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' |
      SSG_BRIDGE_TOKEN=<token> ./SecureShellGo-<version>-x86_64.AppImage`
      gives a JSON-RPC result while the app runs, with FUSE (the normal
      case) and with `APPIMAGE_EXTRACT_AND_RUN=1`.
- [ ] Started from a terminal or the desktop (no `SSG_BRIDGE_TOKEN`, or
      stdin a terminal) the AppImage opens the app as before.
- [ ] Moving the `.AppImage` file changes the command: after a restart from
      the new place the connect screen shows the new path (an assistant set
      up with the old one has to be paired again or edited).
- [ ] "Connect Claude Code" appears when `claude` is installed and saves the
      `.AppImage` path as the plugin's launcher; a new Claude Code session
      lists hosts.

## 2c. Flatpak

- [ ] `flatpak run --command=sh com.dhivalabs.secure_shell_go -c 'ls -l
      /app/bin /app/lib/secureshellgo/secureshellgo-mcp'` shows the launcher,
      the `secureshellgo-mcp` symlink and the `secureshellgo` script, and the
      launcher has the size it has in the release tarball (not stripped).
- [ ] "Connect an assistant" shows the exported command: for a `--user`
      install `~/.local/share/flatpak/exports/bin/com.dhivalabs.secure_shell_go`
      written out in full, for a system install
      `/var/lib/flatpak/exports/bin/com.dhivalabs.secure_shell_go`; the file
      exists on the host.
- [ ] With the app running and the bridge on, that command with
      `SSG_BRIDGE_TOKEN=<token>` and the `initialize` line piped in gives a
      JSON-RPC result (the token reaches the sandbox; `flatpak run` passes
      the variable on), and so does `flatpak run
      --command=secureshellgo-mcp com.dhivalabs.secure_shell_go`.
- [ ] The socket: `endpoint.json` is in
      `~/.var/app/com.dhivalabs.secure_shell_go/data/com.dhivalabs.secure_shell_go/bridge/`
      and names `/run/user/<uid>/app/com.dhivalabs.secure_shell_go/secureshellgo-bridge.sock`
      (the bridge directory is past the socket-path limit for most user
      names). The launcher, in its own sandbox instance, reaches it; a
      socket directly under `/run/user/<uid>` would not have been.
- [ ] Started from the desktop or with `flatpak run
      com.dhivalabs.secure_shell_go` from a terminal, the app opens as
      before.
- [ ] "Connect Claude Code" is absent and the note ("One-click connect is
      not available in the snap or the Flatpak…") points to "Connect an
      assistant"; the plugin's three-line block works with the exported
      command as the launcher.
- [ ] A paired assistant lists hosts end to end (section 5).

## 3. Windows zip

- [ ] Unzipped on a clean machine, `secureshellgo-mcp.exe` next to the app
      answers `initialize` while the app runs (TCP loopback plus the secret
      in `%APPDATA%\com.dhivalabs\SecureShell Go\bridge\endpoint.json`).
- [ ] Windows Defender Firewall asks nothing (loopback only).
- [ ] **A second process cannot bind the bridge's port.** With the bridge
      on, take the port from `endpoint.json` and try to bind it from another
      process (for example PowerShell:
      `[System.Net.Sockets.TcpListener]::new([ipaddress]'127.0.0.1', <port>).Start()`,
      and again with `ExclusiveAddressUse = $false` and
      `ReuseAddress` set). Every attempt must fail. If one succeeds, a local
      program could share the live port, relay the app's proof and read the
      token, which crosses that connection in clear: the known limit in
      `ARCHITECTURE.md` (AI Bridge, Threat model) is then real, and the bind
      must be made exclusive before release.
- [ ] Note, not a blocker: a local program that keeps 8 connections open in
      the handshake can hold the launcher out (it learns nothing). Confirm
      the launcher reports "did not answer in time" or "not running" in
      that case rather than hanging.

## 4. Windows MSIX

- [ ] `tool\build_msix.ps1` (x64 and arm64) ends with a package; the
      generated `AppxManifest.xml` has the second `Application` and the
      alias; the package holds `secureshellgo-mcp.exe`. This path (manifest
      edit after `msix:build`) has never run: see `packaging/MSIX.md`. The
      Store workflow (`.github/workflows/store-msix.yml`) now builds the
      Partner Center package through this script, so its artifact is the
      package to test here.
- [ ] Install; `secureshellgo-mcp` in a new terminal resolves to
      `%LOCALAPPDATA%\Microsoft\WindowsApps\secureshellgo-mcp.exe`.
- [ ] The alias does not add a second Start menu entry or tile.
- [ ] The launcher started by the alias sees the **same redirected AppData
      as the app**: with the packaged app running and the bridge on, the
      alias answers `initialize` with a result. If it says "not running", the
      alias process is not seeing the package's AppData; see the last section
      of `packaging/MSIX.md`.
- [ ] stdin and stdout work through the alias (the line goes in, the reply
      comes out; no console window flashes or swallows output), both typed
      in a terminal and when an assistant that is not itself packaged starts
      `secureshellgo-mcp` with pipes.
- [ ] Windows App Certification Kit passes on the package, including the
      second executable and the alias.
- [ ] Partner Center accepts the alias name.

## 5. A paired assistant, on each platform (snap, deb, rpm, Arch, AppImage, Flatpak, Windows zip, MSIX)

- [ ] Pair an MCP-compatible AI assistant ("Connect an assistant" gives the
      command and the token); it starts the launcher and the tool list shows.
- [ ] `list_hosts` lists exactly the hosts with AI access on, and no others.
- [ ] A read tool (`server_stats`, `list_dir`) on one such host returns
      output; a host with AI access off is refused with the same message as
      a host that does not exist.
- [ ] End to end: pair → `list_hosts` → read a log (`tail_log` with a
      `unit` and with a `path`) → `read_file` past 64 KiB with
      `next_offset` → `search_files` with `max_depth`.
- [ ] Switch the bridge off **mid-call** (a slow `search_files` from `/`
      with `max_depth` 8 works): the assistant gets "The AI Bridge was
      switched off; the call was stopped." and no partial output, its
      connection ends, and no `find` is left running on the server
      (`pgrep -a find`). Repeat with revoking the assistant instead.
- [ ] Locking the app refuses the next call with the "locked" message.
- [ ] A blocked path (`~/.ssh`) and a missing path give the same refusal;
      `list_dir ~` does not show `.ssh`, `.bash_history` or `.env`.
- [ ] No prompt appears in the app for a bridge call: a host with an
      unchecked host key, and one whose key passphrase is not saved, each
      fail with "connect to it once in SecureShell Go". With "Show address
      and username" off, the error text has no hostname, port or user name.
- [ ] Importing a backup leaves this device's bridge settings as they were,
      and every imported host has AI access off.
- [ ] The assistant's activity appears in Activity; no password, key or
      output text is in it.

## 5a. One-click connect ("Connect Claude Code") and the manual block

Needs the `claude` command installed, and the plugin source on GitHub's
default branch (it resolves only once 1.6.0 is merged there; before that, use
a local `dhiva-labs` marketplace and expect the confirmation to name the
folder and warn). None of the Windows items has been run on Windows yet.

- [ ] **Opening Settings starts no process.** With `ps -ef --forest` (Linux) or
      Process Explorer (Windows) open beside the app, open Settings, AI Bridge,
      and press "Check again": no `claude` (or other) child process starts.
      Only pressing "Connect Claude Code" starts `claude --version` and
      `claude plugin marketplace list --json`, and Cancel then changes nothing.
- [ ] **Quitting during one-click.** Start "Connect Claude Code", press
      Connect, and quit the app while the steps run (the screen blocks leaving,
      so close the window or kill the app). After restarting, Paired
      assistants has no new entry (a pairing made by one-click is stored as
      pending, cannot sign in, and is removed on the first load after start).
      Before quitting, a client given the token cannot connect.
- [ ] **deb install, Linux.** Settings, AI Bridge: "Connect Claude Code"
      appears. The confirmation shows the bridge's explanation, the full path
      of `claude` (`command -v claude`) and its version, and no
      source warning on the published source.
- [ ] After Connect, with the bridge off beforehand: the bridge is on, one
      new assistant ("Claude Code") is under Paired assistants, "Shared
      hosts" opens with nothing ticked that was not shared before, and a
      **new** Claude Code session lists the ticked hosts with `list_hosts`.
- [ ] **Cancel** on the confirmation changes nothing: bridge switch, paired
      assistants and `claude plugin marketplace list` as before.
- [ ] **A failure leaves no assistant behind.** Make a step fail (go offline
      so the plugin install cannot reach GitHub, or put a stub named `claude`
      first on the `PATH` that exits 1 for `configure`). The failure screen
      says the pairing was removed, Paired assistants has no new entry, and
      the bridge is off again if it was off before. The manual route is still
      offered.
- [ ] A `dhiva-labs` marketplace added from a local folder first: the
      confirmation names that folder and shows the warning.
- [ ] **Windows install (zip and MSIX).** The button appears with `claude.exe`
      from `%USERPROFILE%\.local\bin`, and the same checks as the deb pass.
- [ ] **Windows with a `claude.cmd` shim** (an npm global install): found,
      confirmed and run through the shell; a shim in a folder whose path holds
      `(`, `)`, `&`, `%` or `@` (for example `Program Files (x86)`) is
      refused, with the manual route as the fallback. No console window is
      left open, and a UNC path in `PATH` is never run.
- [ ] **Snap and Flatpak:** the button is absent and the note pointing to
      "Connect an assistant" is shown.
- [ ] **The token is not visible while it runs.** During the install and
      configure steps (run the flow with a slow network, or a stub `claude`
      that sleeps), `ps -ef | grep claude` on Linux and Process Explorer
      (command line column) on Windows show only the fixed arguments, never
      the token. Search the diagnostics log (Settings, Diagnostics, on) for
      the token: absent. It is also absent from the clipboard.
- [ ] **The manual three-line block** from "Connect an assistant", "Claude
      Code plugin", works pasted whole into bash (Linux) and into PowerShell
      (Windows): the plugin installs, `claude plugin configure
      secureshellgo@dhiva-labs --json` lists `bridge_token` as configured,
      and a new session lists hosts. The screen says to type
      `/plugin configure ...` inside a session, not in a terminal. Note the
      token is in the shell's history file afterwards.
- [ ] **A change that cannot be saved is undone.** Make the app's data folder
      read-only (`chmod -R a-w` on Linux; the folder's read-only attribute and
      deny-write rights on Windows). Try to revoke an assistant: the app says
      the pairing could not be removed and still works. Try to un-share a host
      (Shared hosts, or the host's "AI access (read-only)" switch): the app
      says the change was not saved. Restore write access and restart: the
      assistant and the host are as the app showed after each attempt.
- [ ] The activity log file (`bridge/audit.log`) is owner-only on Linux
      (`stat -c %a` gives 600).

## 6. Not in 1.6.0

- [ ] The Android build is unchanged: no manifest or Gradle diff since 1.5.x.
