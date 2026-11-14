# 1.6.0 release checklist: the AI Bridge, what only real installs can prove

The bridge (a local MCP server in the app plus the `secureshellgo-mcp`
launcher an AI assistant starts) was built and tested on Linux. The
packaging below could not be run there: no snapcraft run, no PPA build farm,
no Windows. Tick each box on a real install before release, and note what you
saw where one fails. Everything is off by default; every check starts with
Settings, AI Bridge, switch on, and one host set to "AI access (read-only)".

## 0. CI builds (first run on GitHub)

- [ ] `Desktop builds`: Linux x64 and arm64 and Windows x64 and arm64 each
      pass "Build the AI Bridge launcher", the architecture assertion (the
      launcher counts), and "Smoke-run the launcher from the archive". The
      Windows steps and the `tool/build_launcher.ps1` script have never run.
- [ ] The Linux tarball and the Windows zip each hold `secureshellgo-mcp`
      (`.exe`) beside the app.
- [ ] The snap jobs (amd64 and arm64) pass "Smoke-run secureshellgo.mcp
      confined": the launcher starts under the `mcp` app's confinement and
      answers with the "not running" error.
- [ ] macOS job unchanged (the bridge is not available on macOS in 1.6.0,
      and no launcher is built there).
- [ ] Version strings bumped to 1.6.0 everywhere they are written by hand
      (`pubspec.yaml` `version:` and `msix_version:`, `snap/snapcraft.yaml`,
      `debian/changelog`, the plugin's `.claude-plugin/plugin.json`
      `version`, already 1.6.0), and `appVersion` in `lib/app_version.dart`
      (what the About box and the bridge's `initialize` report). All of the
      others still say 1.5.0 on this branch.
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
- [ ] The part build found `dart` on PATH (the `override-build` step).
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
      edit after `msix:build`) has never run: see `packaging/MSIX.md`.
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

## 5. A paired assistant, on each platform (snap, deb, Windows zip, MSIX)

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
- [ ] **Snap:** the button is absent and the note pointing to "Connect an
      assistant" is shown.
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
