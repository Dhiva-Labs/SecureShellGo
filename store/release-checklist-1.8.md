# 1.8.0 release checklist: AI access levels, jobs, desktop, the built-in assistant and phone control, what only real installs can prove

1.8.0 adds, to the AI Bridge: one access level per server (Off, Read only,
Ask before each change, Full control); long-running jobs (`start_job` and
friends); a desktop the assistant can see and use (`open_desktop` and the
`desktop_*` tools); a built-in assistant that works on every platform, Android
included, with the user's own API key; and phone control, where a phone
answers the computer's approval cards over SSH. It was built and unit-tested
on Linux, with fakes for the server, the AI service and the SSH hop. Nothing
here has been driven on a real desktop session, against a real AI service, on a
real phone, or over a real SSH hop to an installed package. Tick each box on a
real install and note what you saw where one fails. The 1.6 and 1.7 checklists
(`release-checklist-1.6.md`, `release-checklist-1.7.md`) still apply to
packaging, pairing, the card and the terminal; this one covers what is new.

Everything new is off by default. Every check starts from Settings, AI Bridge
(or, on a phone, the same screen without the computer groups), a host saved
with its AI access set as the check says, and a test server you can break. Use
throwaway keys and accounts: some checks send real content to an AI service.

## 0. Versions, policy, docs

- [ ] Version strings bumped from 1.7.0 to 1.8.0 everywhere they are written by
      hand: `pubspec.yaml` `version:` and `msix_version:`,
      `snap/snapcraft.yaml`, `debian/changelog` (a new `1.8.0~noble1` entry),
      `appVersion` in `lib/app_version.dart` (what the About box and the
      bridge's `initialize` report), and the README's "Latest release" and
      "Status and limits" lines. The plugin's
      `integrations/plugin/.claude-plugin/plugin.json` `version` is already
      1.8.0. The phone's "launcher not found" message says "older than 1.8.0":
      it is only true once this version is the one released.
- [ ] `docs/changes/*.md` for this release (`ai-access-levels.md`,
      `ai-jobs.md`, `ai-desktop.md`, `ai-built-in-assistant.md`,
      `ai-phone-control.md`, `bridge-stop-status.md`, `bridge-audit-mode.md`)
      folded into `CHANGELOG.md` under `## 1.8.0 - <date>`, the files deleted
      and their rows removed from `docs/changes/README.md`.
- [ ] Privacy policy effective date set to the real release date, in both
      `docs/privacy-policy.md` and `docs/privacy-policy/index.html`, the two
      copies still saying the same thing, and the date quoted in
      `store/play-data-safety.md` matches. The published page
      (`https://dhiva-labs.github.io/SecureShellGo/privacy-policy`) serves the
      version with "The AI Bridge and the built-in assistant".
- [ ] **Play Console, by hand** (`store/play-data-safety.md`, "Left to the
      owner"): Data safety question 1 changed from No to Yes, the four data
      types added (other in-app messages; files and docs; other user-generated
      content; photos), encrypted in transit Yes, the new listing text and
      "What's new" pasted (`store/listing.md`). The 1.7.0 form must not be in
      place when 1.8.0 reaches Android. Play's AI-generated content policy
      read, and a decision made on in-app reporting of offensive AI output.
- [ ] `integrations/skill/SKILL.md` and
      `integrations/plugin/skills/secureshellgo/SKILL.md` are identical
      (`diff` them), `integrations/clients/INSTRUCTIONS.md` carries the same
      rules, and `claude plugin validate integrations/plugin --strict` and
      `claude plugin validate . --strict` pass.
- [ ] The Microsoft listing (`store/microsoft-store-listing.md`) character
      counts are re-checked in Partner Center (the description is 6,985, the
      feature rows at most 200 each), and the package declares outbound
      internet for the built-in assistant's HTTPS requests.
- [ ] `flutter test` passes on Linux, including the 1.8.0 tests
      (`test/assistant_*_test.dart`, `test/bridge_control_*_test.dart`,
      `test/bridge_jobs_test.dart`, `test/bridge_desktops_test.dart`,
      `test/host_ai_controls_test.dart`, `test/phone_control_*_test.dart`). They prove the logic; the boxes below are what
      only a real install can show. The real-sshd tests pass on a machine with
      `sshd`: `SSGO_SSHD=1 flutter test test/bridge_local_sshd_test.dart`, and the same
      for `test/bridge_jobs_sshd_test.dart` (it takes the same switch).

## 1. Access levels, in the screens

- [ ] **The picker.** Edit a host: "AI access" shows Off, Read only, Ask before
      each change, Full control, each with a line saying what it allows, and a
      summary line under the choice. Under Ask: "May ask for a terminal" and
      "May ask for the desktop" (each shows its confirmation, and Cancel
      leaves it off) and "Advanced" holding the allowed commands. "Not saved
      yet" shows until you save, and nothing takes effect before.
- [ ] **Going up and down.** Off to Ask asks, and lists the allowed commands
      that come into force and any terminal or desktop tick that comes back.
      Down never asks. Down and up again keeps the ticks and the commands.
- [ ] **Full control.** Choosing it shows the warning and the confirmation
      ("Give full control"); Cancel has the focus and Enter cancels. The host
      screen then carries the standing full-control warning. Saving it, then
      choosing another level and saving, takes it away.
- [ ] **Shared hosts.** Each row shows the chip (Off, Read only, Asks first,
      Full control); tapping a row opens the sheet with the same picker and
      confirmations; a host edited elsewhere while the sheet is open is not
      overwritten with stale values.
- [ ] **A 1.7.0 `hosts.json`.** Open 1.8.0 on a data folder from 1.7.0 with a
      read-only host, an ask host with allowed commands and a terminal tick:
      the levels read as before, and the terminal tick still means "may ask for
      a terminal". Then open the same folder with 1.7.0 after saving a host as
      Full control: it reads that host as Off.
- [ ] **On the phone.** The same screens, reachable from Settings and the host
      edit screen on a small touch screen, with large text; the picker and the
      two confirmations scroll and their buttons stay reachable.

## 2. Full control, end to end

Use a throwaway server and a paired assistant (or the built-in one).

- [ ] On a host at Full control, `run_command` (`uname -a`), `write_file`,
      `service_action`, `start_job`, `open_terminal` and `open_desktop` each
      run with **no card**. Activity says "Allowed: host set to full control"
      for each.
- [ ] Locking the app with Full control on: every call is refused ("locked"),
      none runs. Switching the bridge off: refused. Setting the host back to
      Ask: the next change shows a card again; a terminal or desktop opened
      under full control is closed when the level drops below it.
- [ ] `run_on_hosts` over two hosts: no card only when **both** are at Full
      control; with one at Ask, a card lists both.
- [ ] Phone control: nothing waits for the phone on a full-control host (no
      card exists), and the phone's activity list shows the calls.
- [ ] The assistant, as the skill tells it to, still says what it will do
      before each change on that host. (This is advice to a model: note what
      the real assistant does.)

## 3. Jobs

- [ ] **Start and follow.** On an Ask host, `start_job` shows the card "Start
      this job?" with the command, the folder and the name; Allow once starts
      it. `list_jobs`, `job_status` and `job_output` show it running, then
      exited with its exit code. `job_output` is redacted (a fake secret in the
      output is hidden) and capped (a job that prints more than 64 KB returns
      only the newest part).
- [ ] **It survives.** Start `sleep 600` and a small dev server. Close the SSH
      connection (switch the bridge off, or kill the app): the process is
      still there on the server (`pgrep -a sleep`), and after restarting the
      app `list_jobs` still lists it (the registry, `bridge_jobs.json`).
- [ ] **Stop.** `stop_job` ends the whole process group (a job that starts a
      child: the child is gone) within about 3 seconds; a job that ignores
      TERM is KILLed. A job that moved itself into another session is not
      stopped (the stated limit).
- [ ] **Remove.** `remove_job` on a running job is refused ("stop_job it
      first"); on an ended one it deletes `~/.cache/secureshellgo/jobs/<id>/`.
      The 21st job on one host is refused ("You already have 20 jobs").
- [ ] **A server without `setsid`** (BusyBox or a minimal container image):
      the job starts and outlives the connection; `stop_job` reaches only the
      main process, as documented. Note how a child behaves.
- [ ] **fish as the login shell.** A job whose command has quotes, a backslash
      and a `$`, on a host whose login shell is fish, runs exactly as the card
      showed, and the job folder and exit file are written.
- [ ] **Allowed commands never start a job.** Put the exact command on the
      host's allowed list: `start_job` of it still shows a card. A timed
      approval (Allow for a while) does let it start without one.
- [ ] **Ownership.** A second paired assistant given the first one's `job_id`
      gets "No job by that id is available to you", the same as for a made-up id.
- [ ] **Stepping down.** Take the host down to Read only: the job keeps running;
      `job_status` and `job_output` still work; `stop_job` and `remove_job` are
      refused as read-only. Deleting the host, or pointing it at another
      address, makes `list_jobs` forget the job; it still runs on the server.
- [ ] The job folder and its files are mode 700 / owner only, and the log
      holds stdout and stderr together. A cwd that does not exist starts
      nothing and says so.

## 4. The assistant's desktop, on real desktops

One per platform; each needs a signed-in desktop on the server, the host at
"May ask for the desktop" (and once at Full control).

- [ ] **GNOME on Wayland.** `open_desktop` shows the card "Open a desktop for
      the assistant?" with its warning; Allow once opens a viewer tab at once;
      a screenshot comes back as an image the assistant can read; the pointer
      is not drawn. Note what the server's own screen asks or shows (a screen
      sharing prompt, the "being viewed" notice) and whether input works at
      all: if the remote side is watch-only the tools must say "only lets this
      desktop be watched".
- [ ] **X11.** The same on an X11 desktop (Xfce or similar).
- [ ] **Windows.** The same on a Windows server, from a Linux or Windows client.
- [ ] **Refusals.** A headless server, a Mac, and a server where another user
      is signed in are each refused with the remote-desktop chooser's own
      words, and no viewer is left open.
- [ ] **Coordinates.** Click a small button near each corner and the middle of
      a desktop larger than 1280 pixels (a 4K screen, and a HiDPI one): the
      click lands on the thing in the screenshot, not near it. Change the
      resolution between two screenshots: the next click is refused with "the
      screen size changed", and works after a new screenshot.
- [ ] **Typing and keys.** `desktop_type` into a text editor: letters, digits,
      punctuation, a newline and a tab arrive as typed; a text with an accented
      letter is refused whole. `desktop_key` with `ctrl+c`, `alt+F4`,
      `ctrl+shift+t`, `super` and `F5` each do what the key does. A scroll of 5
      notches moves a long page.
- [ ] **Not logged.** Type a made-up password: Activity shows only "[N
      characters, not recorded]".
- [ ] **Watching and taking over.** The viewer shows the banner "… is using this
      desktop"; Take over changes it, and further tool calls say "The user took
      over this desktop"; Stop ends it ("The user stopped this desktop"); closing
      the viewer ends it. Locking the app takes the keyboard from the viewer.
- [ ] **Limits and endings.** A second `open_desktop` (even from another
      assistant) is refused without a card ("already open"); after 10 minutes of
      no tool calls it closes; switching the bridge off, revoking the
      assistant, un-sharing the host or removing the desktop tick closes it.
      An assistant still gets the matching message, not a generic error.
- [ ] **No agent, no forwarding.** On a host with agent and X11 forwarding on,
      the desktop's connection carries neither.
- [ ] **A very busy screen.** A video playing or a fast terminal: screenshots
      still return within their 20 seconds and the app stays responsive.

## 5. The built-in assistant, against real services

- [ ] **Anthropic, a real key.** Settings → AI Bridge → Built-in assistant:
      switch on (the explanation shows every time), provider Anthropic, address
      empty, a real model name, the key saved. The chat button appears in the
      host list's app bar. "What is the load on <host>?" runs `list_hosts` and
      `server_stats` and answers; the tool rows show host names and results.
- [ ] **A change, with a card.** Ask for a harmless command on an Ask host: the
      card appears over the chat, Allow once runs it, the chat continues.
      Deny: the assistant stops and asks. Activity names "Built-in assistant".
- [ ] **OpenAI-compatible, a real server.** Provider OpenAI-compatible with
      `https://api.openai.com/v1` (or another hosted service) and a model; the
      same questions work. Then a local server (Ollama or llama.cpp's server
      with an OpenAI-compatible endpoint) at `http://localhost:…/v1` with no
      key: it works on the computer. A remote `http://` address is refused with
      a message that says why.
- [ ] **A desktop through each provider.** With Anthropic, the assistant reads a
      screenshot. With the OpenAI-compatible connection it cannot (the result
      says an image was returned and cannot be carried): the assistant must not
      claim to have seen the screen.
- [ ] **Errors in plain words, the chat stays usable.** A wrong key (401), a rate
      limit (429), no network, a model name that does not exist, and a service
      that returns garbage each end the message with a readable notice.
- [ ] **Stop.** Press Stop during a long answer and during a tool call (a slow
      `run_command`): the request and the command stop, and a waiting card
      disappears. A message that would run more than 40 tool calls stops with
      the notice.
- [ ] **The key.** Saved, it shows "Key saved" and is never shown again. It is
      not in `settings.json`, not in a backup (export one and search it), not in
      `diagnostics.log` with the log on, not in `audit.log`. Remove key empties
      it. On a Linux machine with no keyring, saving says it cannot protect it
      instead of writing it to a file.
- [ ] **Backups.** A backup exported with the assistant on carries no switch, no
      provider, no address, no model, no key; importing one leaves this
      device's values.
- [ ] **Off means off.** Switching the assistant off stops a running chat. The
      AI Bridge switch (for assistants on this computer) does not affect it.
      The app lock refuses its calls.
- [ ] **The system prompt.** It does not yet mention jobs, desktops or full
      control. Read a transcript where the assistant has access to them and
      note anything it does that the skill would forbid (acting on a log line's
      instruction, asking the user to raise a level).

## 6. A real Android phone

- [ ] **Settings are reachable** (Settings → AI Bridge) and show the built-in
      assistant, "What assistants can read", "Approvals", "Shared hosts" and
      "Activity", and do **not** show pairing, the launcher, or Connect Claude
      Code. Phone control's group is absent (it is the computer's setting).
- [ ] **Per-host access** is in the host edit screen, with the picker working on
      a small screen and with large text, in portrait and landscape and on a
      foldable.
- [ ] **Chat.** Keyboard open and closed, rotation mid-answer, a long
      transcript, copy of a reply, the composer's Send and Stop. The chat
      survives the screen turning off for a minute while an answer is running
      (note what happens), and the app being sent to the background and back.
- [ ] **A card over the chat.** A change on an Ask host raises the card over the
      chat; Deny has the focus; Allow stays dead for a second; the system back
      gesture denies. With the app in the background the card is not seen and
      the change is denied after 2 minutes (as documented).
- [ ] **Key storage.** The key survives an app restart and a reboot, is gone
      after "Remove key" and after uninstalling, and is absent from
      `adb backup`-style extraction (backups are off). The Keystore path works
      on an Android 7 and a current device.
- [ ] **No local `http`.** An `http://` address, including `localhost`, is
      refused or fails with a readable message on Android (cleartext is off).
- [ ] **A real model over mobile data.** A turn completes over Wi-Fi and over
      mobile data, and across a Wi-Fi to mobile switch the error is readable.
- [ ] **AI approvals** from the phone (section 7).
- [ ] The Play Data safety form matches what you saw (the app sends only to the
      address entered; nothing else on the network in a packet capture).

## 7. Phone control, over a real SSH hop

Computer: Settings → AI Bridge on, Phone control on, "Pair a phone", token
copied. Phone: the computer saved as a host; the host's menu action "AI
approvals on this computer"; the token pasted. Do each on a computer with each
install, the phone reaching it through a real `sshd` (not loopback on the same
machine).

- [ ] **deb or PPA.** The launcher is found (`secureshellgo-mcp` on the PATH of
      a **non-interactive** SSH command), the screen shows "connected", and a
      card the assistant raises appears on the phone exactly as on the computer.
- [ ] **snap.** The command finds `secureshellgo.mcp` or `/snap/bin/secureshellgo.mcp`
      although a non-interactive SSH shell often has no `/snap/bin` on its PATH,
      and the launcher, running under snap confinement and not inside a desktop
      session, can reach the app's socket. Note any confinement denial.
- [ ] **Flatpak.** The `flatpak run --command=secureshellgo-mcp …` route is found
      over SSH, and reaches the running app's socket from a fresh sandbox
      instance (the shared `XDG_RUNTIME_DIR/app/<id>` path).
- [ ] **Windows computer.** The phone's `sh -c` command needs an SSH login shell
      that can run it; note what Windows OpenSSH's default shell (cmd or
      PowerShell) does, and whether `secureshellgo-mcp.exe` is found at all. If
      it fails, the message must say so in words the user can act on, and the
      docs must say Windows computers are not supported yet.
- [ ] **Tarball, AppImage.** The launcher is not found; the screen says it was not
      found or is older than 1.8.0, not a generic failure.
- [ ] **fish as the computer's login shell.** The same connects (the command is
      quoted for it).
- [ ] **The environment.** With no `DISPLAY`, no `XDG_RUNTIME_DIR` in the SSH
      environment and the app on a different login session: the launcher still
      finds the app's socket (the bridge folder is under the data folder, with
      the runtime-folder fallback only when its path is too long). Note any
      case that fails over SSH but works in a terminal on the machine.
- [ ] **Cards.** A command, a file write (new and replace), a service change, a
      job start, a terminal and a desktop each show on the phone with the same
      text as the computer, hidden characters made visible (`\n`, `[U+202E]`),
      the host's bridge name and never its address or user. Deny, Allow once and
      (with "Allow for a while" on at the computer) Allow for N minutes work and
      each runs the same checks as a tap on the computer; a terminal or desktop
      card never offers the timed button. Activity on the computer records the
      answer as from the phone, with its name.
- [ ] **Answered twice.** Answer on the phone and on the computer at nearly the
      same time: exactly one wins, the other is told it is gone.
- [ ] **Stopping.** The live timed approvals can be stopped from the phone; an
      assistant terminal and an assistant desktop can be stopped from the phone
      (the banner on the computer says so). Jobs cannot (no source is wired).
- [ ] **Refusals read like an unknown pairing.** With Phone control off at the
      computer, a revoked pairing, a wrong token and an assistant's token all
      get the same "refused" message on the phone.
- [ ] **Endings.** Switching Phone control off, switching the AI Bridge off, and
      removing the phone's pairing each end a live session at once with a
      message. Locking the app on the computer empties the phone's screen and
      refuses its taps; unlocking brings the state back. Closing the app on the
      computer says it is not running.
- [ ] **Only while the screen is open.** Leave the "AI approvals" screen (or lock
      the phone): the session ends, nothing on the phone listens, a card raised
      meanwhile is denied after 2 minutes, and reopening the screen shows the
      state again. Note what happens when the phone is locked with the screen up.
- [ ] **Two phones, then a third.** Two connect; the third is told "two phones are
      already connected".
- [ ] **A dropped link.** Turn the phone's network off and on: the screen says the
      connection was lost and Reconnect works; a card that waited meanwhile is
      shown again or says it is gone.
- [ ] **No tool.** The phone's token, put in an MCP client's `SSG_BRIDGE_TOKEN`,
      is refused; an assistant's token given to `secureshellgo-mcp control` is
      refused.
- [ ] **Token handling.** The token is not in the SSH command line (`ps` on the
      computer while connected), not in the phone's `hosts.json` or a backup, and
      is gone after "Remove token" or deleting the host.

## 8. Translations

The text new in 1.8.0 in the eight languages other than English
(`lib/l10n/app_*.arb`) was written by machine and has not been read by native
speakers. Have each read, where possible, before release:

- [ ] The level names and their lines (Off, Read only, Ask before each change,
      Full control), above all **Full control**'s warning and its "Give full
      control" button: a warning that reads softer in a language than in English
      is a bug. The chip names (Asks first, Full control).
- [ ] The job card ("Start this job?" and its note that it keeps running) and
      the desktop card and warning.
- [ ] The built-in assistant's enabling explanation and the key note ("not in
      backups"), and the tool-row words (Running, Done, Failed, Stopped).
- [ ] The phone-control texts (enabling, pairing steps, remote approvals,
      errors) once they are final.
- [ ] Long German, Russian and Portuguese strings do not clip on a small phone.

## 9. Privacy and backups, together

- [ ] Export a backup with a full-control host, a desktop tick, allowed commands,
      the assistant on with a key, Phone control on and a phone paired: import it
      elsewhere. The host arrives Off with nothing ticked and no commands, the
      assistant off with no key, Phone control off, no pairings, no jobs, and this
      device's own settings untouched.
- [ ] A packet capture while the built-in assistant answers one message shows
      traffic only to the configured address (and SSH to the servers); with the
      assistant off, nothing to it.
- [ ] `audit.log` has `approval: full_control` where expected, a `via` on a card
      answered from a phone, no desktop typing, no output and no screenshots, and
      a 1.7.0 `audit.log` still reads.

## 10. Unchanged, and not in 1.8.0

- [ ] The 1.7.0 behaviour of Off, Read only and Ask is unchanged, refusal texts
      included: re-run sections 1 to 4 of `release-checklist-1.7.md` on one install.
- [ ] No Android manifest or Gradle change (no new permission) other than the
      version; macOS has no launcher, pairing or phone-control computer side.
- [ ] Known and documented, not fixed: no screen lists or stops jobs; the phone
      cannot stop jobs; screenshots work only through Anthropic; a local `http`
      model server does not work on Android; the card does not alert the user.
