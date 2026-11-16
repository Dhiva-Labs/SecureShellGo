# Privacy Policy — SecureShell Go

**Effective date:** 14 November 2026
**Applies to:** SecureShell Go 1.5 and later, published by Dhiva Labs, on
Android (Google Play, `com.dhivalabs.secure_shell_go`), Windows (Microsoft
Store and the `.zip` builds on GitHub) and Linux (Snap Store, the Launchpad
PPA and the `.tar.gz` builds on GitHub), and to the unsigned macOS build on
GitHub.

## The short version

SecureShell Go does not collect anything. There is no account, no analytics,
no advertising, no crash reporting, no update check, and no Dhiva Labs server
for your data to be sent to. We do not run one.

The app connects only to the servers you set up yourself, and to things on
your own device that you switch on, such as your SSH agent or X server.

Everything it remembers stays on your device. Passwords and private keys go
into your operating system's protected storage: the Android Keystore, Windows
Data Protection, or your Linux desktop keyring.

A backup or a diagnostics log leaves your device only if you save it or copy
it somewhere yourself.

On Linux and Windows there is an optional AI Bridge, off until you switch it
on. If you do, an AI assistant on your own computer can read from the servers
you choose. If you also allow it, host by host, it can ask to run commands,
write files and open a terminal on your own servers, each time with your
approval in the app, or under settings you chose. The app gives what it reads
and what those commands and the terminal print to that assistant, which sends
it to its own provider. Dhiva Labs receives nothing. See "The AI Bridge" below.

## Who is responsible

Dhiva Labs. Contact: **dhivakar1010@gmail.com**

Source code: <https://github.com/Dhiva-Labs/SecureShellGo>

The app is open source under the MIT licence, so every statement on this page
can be checked against the code.

## What the app is

An SSH terminal and file client. You give it the address, port, user name and
credentials of a server you already have access to. It opens an encrypted SSH
connection to that server, gives you a shell, and lets you edit files and move
them in both directions.

## Information Dhiva Labs collects

**None.**

- No personal information is collected.
- No usage, diagnostic, crash or performance data is sent anywhere.
- The app includes no advertising, analytics, crash-reporting, attribution or
  tracking library: no Firebase, no Google Analytics, no Crashlytics, no
  Sentry.
- No advertising identifier is read, and there are no ads.
- There is no sign-up, sign-in or account with Dhiva Labs.
- The app does not check for updates itself. Updates come through the store
  or package manager you installed it from.
- Nothing is transmitted to Dhiva Labs, because Dhiva Labs runs no service
  for it to be transmitted to.

## Information stored on your device

The app keeps a few small files in its own data folder:

| Platform | Data folder |
| --- | --- |
| Android | The app's private storage, which other apps cannot read |
| Windows | `%APPDATA%\com.dhivalabs\SecureShell Go` in your Windows user profile |
| Linux | `~/.local/share/com.dhivalabs.secure_shell_go`, or the snap's own copy of that folder under `~/snap/secureshellgo/` |
| macOS | `~/Library/Application Support/com.dhivalabs.secureShellGo` |

Those files are:

| File | What is in it |
| --- | --- |
| `hosts.json` | Your saved servers: the name you gave each one, its address, port and user name, the sign-in method, group, colour, jump host, startup command, terminal connection (SSH or Mosh), whether to keep the shell in tmux or screen, the agent forwarding, X11 forwarding and legacy-algorithm switches, an SSH certificate if you added one (certificates are public), whether and how far AI access is on for it, any allowed commands you typed and whether a terminal is allowed (Windows and Linux), and when you last connected. No passwords or private keys. |
| `known_hosts.json` | The host keys you have trusted: server address, port, key type, fingerprint, and when you trusted it. Fingerprints are public information. The file is sealed with an HMAC whose key is kept in protected storage, so tampering is detected. |
| `settings.json` | Your preferences: appearance, terminal and editor options, keyboard, app lock, diagnostics log on or off, and the AI Bridge settings (Windows and Linux). |
| `snippets.json`, `tunnels.json`, `bookmarks.json` | Your command snippets, saved port forwards, and folder bookmarks. |
| `server_jobs.json` | Server-to-server copies that are still running on a server: which servers, which paths, and when they started. An entry is removed once the app has seen the copy finish. |
| `secure_storage_state.json` | Whether a system keyring has ever worked on this device. No secrets. |
| `diagnostics.log` | Only if you turn on the diagnostics log. See below. |
| `bridge_clients.json` | Windows and Linux only, only if you pair an AI assistant: the name you gave each one, a one-way hash of its token (not the token), and when it was paired and last connected. |
| `bridge/` folder | Windows and Linux only, once the AI Bridge has been switched on: `audit.log` and `audit.log.1` (the activity log), and, while the bridge is on, `endpoint.json` saying how the launcher reaches the app, plus the socket `bridge.sock` on Linux. See "The AI Bridge" below. |

### Passwords, private keys and passphrases

These are stored only for a host you save with them filled in. If you connect
without saving, they are kept in memory for that connection and never
written to disk. They never go into the files listed above.

| Platform | Where saved credentials go |
| --- | --- |
| Android | Encrypted with a key held in the Android Keystore. On most devices that key stays in dedicated security hardware and cannot be exported. |
| Windows | Encrypted with Windows Data Protection (DPAPI), which ties them to your Windows account, in a file in the data folder above. |
| Linux | Your desktop keyring (GNOME Keyring, KWallet or another Secret Service provider), which encrypts them with your login password. |
| Linux without a keyring | If no keyring has ever worked on this computer, the app keeps credentials in an encrypted file (`secrets.ssgvault`, AES-256-GCM) in the data folder, with its key in `device_vault.key` beside it, readable only by your user account. This protects them from other user accounts on the computer, but not from programs running as you. If a keyring has worked here before and is only locked, the app refuses to save and asks you to unlock it instead. |
| macOS | Your login Keychain. |

On Linux the key that seals `known_hosts.json` is also kept in the keyring.
When no keyring can be reached, the app cannot check or seal that file, so it
saves no trusted host keys, asks about each server's key again, and shows a
notice on the host list saying why.

### Diagnostics log

Off unless you turn on **Settings → Keep a diagnostics log**. While it is on,
errors and crashes are written to `diagnostics.log` in the data folder:

- Secrets are removed before anything is written. That includes saved
  credentials, passwords typed without saving, answers to a server's hidden
  login prompts, backup and vault passphrases, and anything that looks like a
  password, private key or token. If the app learns a secret after something
  was written, it removes that secret from the file too.
- Error messages can still contain server names, addresses, user names and
  file paths. Each log starts with the app version and the operating system.
- It is limited to two files of 128 KB each, with the oldest entries dropped
  first.
- It is never sent anywhere. You can view it, copy it to the clipboard, or
  clear it in Settings. It leaves your device only if you paste it
  somewhere, for example into a bug report. Turning the setting off deletes
  it.

### Backups

**Settings → Backup** exports your configuration to one `.ssgbackup` file,
encrypted with a passphrase you choose (at least 12 characters; Argon2id and
AES-256-GCM). It contains your saved hosts and groups, snippets, tunnels,
bookmarks and settings. Two things are included only if you tick them:

- your saved passwords, private keys and passphrases;
- your trusted host keys ("Include trusted host keys").

You decide where the file goes: your Downloads folder, or through the
system's save screen to any folder, an SD card or a cloud drive such as
Google Drive, OneDrive or Dropbox. If you save it to a cloud drive, that
service's own terms apply to the file. The app never uploads a backup by
itself, and nobody can open the file without the passphrase. If you lose the
passphrase, the backup cannot be recovered.

When you import a backup that has host keys in it, you see each new server
and its fingerprint, and they are trusted only if you tick "Trust these
keys". Keys this device already trusts are never replaced by a backup.

A backup never contains AI Bridge settings, AI access, allowed commands, the
terminal switch or paired assistants, and importing one never switches the
AI Bridge on or gives a server AI access.

### Session logs

If you choose **Record session log…** in a session's menu, everything that
session prints is written to a file you choose. On a computer you pick the
file first and it is written as the session runs. On Android the log is held
in memory (up to 32 MB) until you stop it, and then you choose where to save
it. A session log holds whatever the server printed, and it is not scrubbed
the way the diagnostics log is.

### Android: no cloud backup or device transfer

On Android the app sets `allowBackup="false"` and excludes all of its data from
cloud backup and from device-to-device transfer. Its stored data is not copied
to Google Drive or moved to a new phone. Saved credentials are encrypted with
a Keystore key that cannot leave the phone, so a copy would be useless
anyway. To move to a new device, use an encrypted backup (above) or add your
hosts again.

## Network connections the app makes

The app has no web or HTTP code of its own. On Android, unencrypted (cleartext)
traffic is disabled. These are all the connections it makes:

1. **SSH to the servers you configure**, over TCP (port 22 unless you choose
   another), including any jump host you set. Host names are looked up
   through your device's normal DNS resolver. Everything sent over SSH is
   encrypted by the SSH protocol: what you type, what the server prints,
   files, directory listings, and the commands the app runs on the server for
   you (for example server stats, service lists, file actions, or starting
   tmux, screen or `mosh-server`).
2. **Mosh, over UDP, to the same server.** Only for hosts you set to use
   Mosh. The app starts `mosh-server` over SSH, then sends encrypted UDP
   datagrams (AES-128-OCB, with a key the server gave it over SSH) to that
   server's address, on the port `mosh-server` chose (normally between 60000
   and 61000). It listens for the replies on a local UDP port.
3. **Port forwards (tunnels) you create.** A local or dynamic (SOCKS)
   forward listens for connections on your device, on `127.0.0.1` unless you
   enter a different address. For a remote forward, when the server passes
   a connection back, the app connects to the address and port you entered.
4. **Your local SSH agent** (on computers only, not on Android, if you
   choose agent sign-in or agent forwarding). On Linux and macOS this is
   the socket named by `SSH_AUTH_SOCK`. On Windows it is the pipe named by
   `SSH_AUTH_SOCK` if that is a pipe, otherwise the Windows OpenSSH agent's
   pipe, otherwise Pageant's pipe if it belongs to your account. These
   connections stay on your computer. The private keys stay in the agent; the
   app only asks it for signatures.
5. **Your local X server** (on computers only, not on Android, if you turn
   on X11 forwarding for a host). Graphical programs on the server connect
   through SSH to the X server named by your `DISPLAY` setting. That is
   normally the one on your own computer, and on Windows it is assumed to be on
   `localhost` if `DISPLAY` is not set. On Linux the app runs your local
   `xauth` to give each forwarded program its own cookie where your display
   supports it.

6. **Your own AI assistant, on the same computer** (Windows and Linux only,
   only if you switch on the AI Bridge). A launcher program started by the
   assistant connects to the app over a local channel: on Linux a socket file
   only your user account can open; on Windows a port on `127.0.0.1`, where
   the app first proves it holds a secret written for this launch, and the
   launcher then sends the assistant's token. Nothing listens on your
   network. If you press "Connect Claude Code", the app also runs the
   `claude` program you installed, at your request. See "The AI Bridge"
   below.

Nothing else. In particular:

- **Links in the terminal.** When you click or tap an `http` or `https`
  address in the terminal and choose to open it, it is handed to your web
  browser. The app does not fetch it, and no other kind of link is opened.
- **Opening a downloaded file** hands it to the app your system uses for
  that file type.
- **Noticing network changes.** To reconnect quickly after a network change,
  the Android app asks Android to tell it when the default network changes,
  while a session is open. On computers the app checks the list of local
  network interfaces every so often. Neither sends any traffic.

### When a server can act on your behalf

Some features you switch on let a server you trust use your keys without the
keys leaving your device:

- **Agent forwarding** (per host, off by default). Programs on that server,
  such as `git` or `ssh`, can ask your device to sign with the host's saved
  key, and on a computer also with the keys in your SSH agent, while you are
  connected. Anyone with root on that server can do the same in that time.
- **Direct server-to-server copy.** When you copy between two servers and
  leave "Use direct transfer" ticked (it is ticked whenever the destination
  uses a private key), the source server signs in to the destination itself.
  While it signs in, the app lets it use your saved key for the destination
  through a forwarded agent. The key is never sent to it, and it will accept
  only the destination host key this device already trusts. The copy then runs
  on the source server by itself.
- **X11 forwarding.** On Linux, where your display supports it, forwarded
  programs get limited access, like `ssh -X`. On Windows, and on Linux
  displays without that support, the server can see and control every window
  on that display while you are connected, like `ssh -Y`. The app tells you
  when that is the case.

### What the app leaves on your servers

- Direct server-to-server copies, and the file browser's Compress, Extract,
  Duplicate and Change owner actions, run on the server so they can finish
  if the app closes. Each keeps a small working folder in
  `~/.cache/secureshellgo/jobs/` on that server. The app removes the folder
  once it has picked up the result, and clears out finished ones older than
  two days.
- A host set to keep its shell in tmux or GNU screen leaves that session
  running on the server after you disconnect, which is the point of the
  setting.
- Closing a Mosh tab ends its `mosh-server`. A `mosh-server` started for a
  connection that never got through is stopped again.

## The AI Bridge (Windows and Linux only)

It is not available on Android or macOS: those apps never start it, and no
launcher ships with them.

**What it is.** An optional feature that lets an MCP-compatible AI assistant
that you run on your own computer read from your servers, through
SecureShell Go. It is **off by default**. It does nothing until you switch on
**Settings → AI Bridge** (the app explains what it does and asks you to
confirm every time you switch it on), pair an assistant with **Connect an
assistant** (which shows you a token, once), and switch on "Share with AI
assistants" for each server you want it to see. Changing anything on a server
needs more, per server: see "Changes, and the terminal" below.

**What an assistant can do.** On the servers you shared, list them, by name;
read server stats; list services; read the end of a log; list folders; read
text files; and search for files by name. That is all, unless you also allow
changes for a server (see "Changes, and the terminal" below). It is never given passwords, private keys or passphrases.
By default it is not given a server's address, port or user name either
("Show address and username" is off), and those are also removed from the
error messages it gets. Common secret locations (`~/.ssh`, `.env` files, key
files, shell histories, `/etc/shadow`, cloud and package-registry credential
files, and more) are blocked from reading and left out of folder listings,
and you can block more under "Extra blocked paths". Private keys and secrets
the app knows are removed from what it reads, and one call returns at most
64 KiB. While the app is locked, the bridge refuses everything. Switching the
bridge off, or revoking an assistant, stops its calls in progress, and
nothing they found is passed on; a change under way is stopped too, except a
file write that has already begun replacing the file, which is let finish.

**Changes, and the terminal (version 1.7.0).** If you allow it for a server
("Let the assistant request changes", off by default, per server), the
assistant can ask to run one shell command, write one text file, start, stop,
restart or reload a service, or run one command on several servers, as the
sign-in user the app has saved for that server. Each ask shows you a card in
the app with the exact command, or for a file its path, its size and a
preview of the new content or of the changes (the card warns you when the
preview is not the whole change), and you answer Deny, Allow once or, only if
you turned on "Allow for a while" in Settings → AI Bridge, Allow for a number
of minutes. No answer within two minutes is a no; the card does not alert
you, so if the app is in the background you will not see it. Two things you
set up beforehand run without a card: a command you put under "Allowed
commands" for that server, when the assistant asks to run exactly that text
on that server alone, and a time-limited approval you gave on a card, which
lets that assistant make any change on that server, without asking, until it
runs out. If you also switch on "Full control terminal" for a
server, the assistant can ask to open a terminal there, with a card every time
and never a time-limited approval. An approved terminal gives it a live shell
as the saved sign-in user on that server: it can type any command, including
ones you never see on a card, read any file that user can read and reach
anything that server can reach, with no further questions. The blocked-path
list does not apply inside a terminal or to a command. You can watch it, take
over by typing, or stop it at any time. All of this is off until you switch it
on, and the app never gives the assistant your SSH agent or X11 forwarding.

**Signing in.** The bridge signs in to a server with what you saved for it,
without asking you anything: SecureShell Go never shows a prompt for a bridge
call. If a server would need you (a locked vault, a password or passphrase
that is not saved, a question at login, a host key you have not checked yet),
the call fails, and the assistant is told to ask you to connect to it once in
SecureShell Go. Software outside the app can still ask you something while
the bridge signs in: your SSH agent may ask you to confirm a key's use or
touch a hardware key, and your desktop keyring may show its own unlock
dialog.

**Connect Claude Code starts another program on your computer.** On Windows
and Linux, not in the snap (which cannot start other programs, and where the
app does not even look), the app can run the `claude` command-line program you
have installed. It does so in two steps, and only at your request.

- *Looking, which runs nothing.* Opening Settings, or pressing "Check again",
  never runs a program. The app only checks whether a file named `claude`
  exists on your `PATH`, in `~/.local/bin` or in `~/.claude/local` (on
  Windows: on the `PATH` with its executable extensions, and
  `%USERPROFILE%\.local\bin\claude.exe`).
- *Showing you what it found, which changes nothing.* When you press
  **Connect Claude Code**, the app runs that program with `--version` and
  with `plugin marketplace list --json` (10 seconds each) so it can show you
  its full path, its version and where its plugin would be loaded from (a
  warning if that is not the published SecureShell Go plugin on GitHub). If a
  found file does not answer the version check, the next one is tried. This
  happens before the confirmation, and Cancel then leaves everything as it was.
- *Setting up, only after you press **Connect** on the confirmation.* The app
  runs, in order: `plugin marketplace list --json`; `plugin marketplace add
  Dhiva-Labs/SecureShellGo` only if that source is not already there; `plugin
  install secureshellgo@dhiva-labs`; `plugin configure
  secureshellgo@dhiva-labs --values-stdin`; and `plugin configure
  secureshellgo@dhiva-labs --json` to check the token was saved (90 seconds
  each). It runs only a local file named `claude`, with these fixed arguments.

The pairing token is handed to that program on its standard input, in the
`--values-stdin` step only: not on the command line, in an environment
variable, on screen, on the clipboard or in a log. That program is yours, not
ours: what it does with the token afterwards (it keeps it in its own plugin
settings), and what it contacts to install the plugin (the plugin comes from
GitHub), is governed by its own terms and privacy policy. If a step fails, the
app revokes the pairing it just made. Until the setup is confirmed that
pairing cannot be used, and one left behind because the app was closed
part way is removed the next time the app starts. **Nothing is sent to Dhiva Labs.** The
manual route (pasting commands into a terminal) never has the app run
anything; there the token lands in your shell's history file until you delete
that line.

On Linux the app also runs the system's `chmod` on its own bridge files, to
make them readable only by your user account: the file of paired assistants,
the connection file and socket, and a newly created activity log.

**What leaves your device, and to whom.** The app gives the result of each
call, which now includes the output of a command and, for a terminal, the text
on its screen (with private keys and the secrets the app knows removed), only
to the AI client you paired, on the same computer, through the
launcher program that client starts. Nothing listens on your network. That
client then sends what it received to its own provider, under that
provider's terms and privacy policy, as part of your conversation. **Dhiva
Labs receives nothing**: there is no Dhiva Labs server involved, and the app
itself connects only to the servers you configured and to the launcher on
your computer. But your AI provider does receive what the assistant reads,
including what its commands and terminal print, so share only servers and
files you are happy to send there. Error messages go to the assistant too.
The preview on a file card, including the lines of the existing file that a
diff shows, is read from your server to show it to you; it is not sent to
the assistant. What you approve is sent from the app to your server over SSH,
like anything else you send there.

**Limits you should know.**

- The blocked-path list is a default set, not a guarantee that no secret on
  a server can be read; for a hard guarantee, use a server account with
  limited read rights.
- Text on a server, such as a log line, a file, a command's output or a
  terminal screen, can contain instructions aimed at the assistant. Read the
  card before you allow anything.
- A command on the allowed list and a time-limited approval run without
  asking you, as you set them up. An approved terminal can do anything the
  sign-in user can, and what its screen shows is sent to your AI provider; only
  private keys and secrets the app knows are removed from it, so a key can still
  be read in pieces or encoded.
- The approval card does not alert you or bring the app forward. With the
  app in the background a card goes unseen and is denied after two minutes.
- The token is stored in the assistant's configuration on your computer.
  Anyone who has it can, while the app is running with the bridge on and
  unlocked, read from the servers you shared, ask for changes where you
  allowed them, and use those servers' allowed commands and any time-limited
  approval you gave that assistant. Revoking the assistant stops the token at
  once.
- On Windows the launcher reaches the app over a port on `127.0.0.1`. The app
  must first prove it holds a secret written for this launch in your
  profile; only then does the launcher send the token, unencrypted, over
  that local connection. Programs running under your own account can read
  the token anyway.

**Where it is stored, and how to delete it.**

- **Paired assistants** are in `bridge_clients.json` in the data folder: the
  name you gave each one, a one-way hash of its token (never the token), when
  it was paired and when it last connected. Revoke an assistant under
  Settings → AI Bridge → Paired assistants and its entry is deleted and its
  token stops working.
- **The activity log** is `audit.log` (and one older file, `audit.log.1`) in
  the `bridge` folder of the data folder. Each entry has the time, the
  assistant's name, the server name it asked for, the tool, the arguments
  (with private keys and known secrets removed, cut to 500 characters; for a
  command, the command; for a file write, the path and size, never the
  contents; for a terminal, the text the assistant typed), the outcome (OK,
  refused or error) with the refusal code or error message (which can quote a
  short error the server gave), how long it took
  and, for a change, how it was allowed (an allowed command, a time-limited
  approval, once, for a while, or denied, timed out or withdrawn). It never
  holds what was read, what a command or a terminal printed, or file contents. The file is created so that only your user
  account can read it. It keeps about 512 KB plus
  the older file, and the oldest entries are dropped. Open it under Settings
  → AI Bridge → Activity; Clear deletes both files. It is never sent
  anywhere.
- **While the bridge is on**, the `bridge` folder also holds `endpoint.json`,
  which tells the launcher how to reach the app (on Windows, a port and the
  secret for this launch), and on Linux the socket `bridge.sock` (or
  `secureshellgo-bridge.sock` in your private runtime folder when the data
  folder's path is too long). Both are removed when the bridge stops.
- **Your bridge choices** are in `settings.json`, and whether each server has
  AI access, its allowed commands and its terminal switch are in `hosts.json`.
  Turning a server back to read-only or un-sharing it keeps its allowed
  commands and terminal switch stored but unused, so they are there if you
  switch changes on again. To remove them, take the commands off the host's
  "Allowed commands" list and switch "Full control terminal" off while
  changes are on, or delete the host.
- **Time-limited approvals** are kept in memory only, never written to a file.
  They end when their time does, on "Stop now", when you switch "Allow for a
  while" off, when the bridge is switched off, the assistant is revoked, the
  app locks or restarts, or the server is deleted, un-shared, stepped down or
  changed to point elsewhere. Cards waiting for an answer are also in memory
  only.
- **Backups** never contain AI access, allowed commands, terminal switches,
  bridge settings or paired assistants. A server imported from a backup always
  has AI access off, no allowed commands and the terminal switch off, and
  importing a backup keeps this device's own bridge settings, "Allow for a
  while" included.
- Turning the bridge off stops it listening at once. Deleting the data folder
  removes all of the above.

## Files on your device

- **Downloads** from a server go to the shared Downloads collection on
  Android, so they appear in your file manager, and to your Downloads folder
  on a computer.
- **Uploads** read only the files you pick in the system file picker, or
  (on Android) the files you send to the app from another app's Share menu.
  The app does not browse or index your storage. Shared files are first
  copied into the app's cache so they can be streamed to the server. Those
  copies are deleted the next time you share or pick files once they are six
  hours old, and Android may clear them sooner.
- **On a computer,** the app reads `~/.ssh/config` only when you choose
  to import from it. It reads the server entries and any certificate file
  they name, never your private key files. Private key files are read only
  when you pick one.
- **The clipboard** is read only when you paste, and written only when you
  copy.

## Android permissions, and why

| Permission | Why |
| --- | --- |
| `INTERNET` | To open SSH (and Mosh) connections to your servers. |
| `ACCESS_NETWORK_STATE` | To be told when the default network changes (Wi-Fi to mobile data, a new access point), so an open session reconnects over the new network straight away. Used only while a session is open. Granted at install, with no prompt. |
| `FOREGROUND_SERVICE` | While a session is open, the app runs a foreground service with an ongoing notification ("Connected — tap to return", with the host's name). This stops Android from closing the app, and with it your connection and whatever is running in it, while you use other apps. The service stops when you close your last session. |
| `FOREGROUND_SERVICE_SPECIAL_USE` | The type of that service on Android 14 and later: keeping an interactive terminal session connected, which has no fixed end. |
| `FOREGROUND_SERVICE_DATA_SYNC` | The type of the same service on Android 10 to 13, and on Android 14 and later if Android refuses the special-use type. |
| `POST_NOTIFICATIONS` | To show that ongoing notification. Asked for the first time you open a session, never at launch. If you decline, the notification is hidden and the session still works. |
| `USE_BIOMETRIC` | For the optional app lock. Android shows its own fingerprint, face or screen-lock prompt, and the app learns only whether you passed. The app never sees or stores fingerprint or face data. Granted at install, with no prompt. |
| `WRITE_EXTERNAL_STORAGE`, Android 9 and older only | To save downloads into the shared Downloads folder on those versions. Android 10 and newer need no storage permission for this, and the app does not ask for one. |

While the app lock is on, the app also tells Android to keep its screen out
of screenshots and out of the recent-apps preview.

## Windows, Linux and macOS

- **App lock on Windows** uses Windows Hello (your PIN, fingerprint or face).
  Windows shows the prompt, and the app learns only whether you passed. App
  lock is not available on Linux or macOS.
- **The AI Bridge** is available on Windows and Linux only. The macOS app
  never starts it.
- **The Linux snap** reaches your keyring through the
  `password-manager-service` interface, which snapd does not connect
  automatically (`sudo snap connect secureshellgo:password-manager-service`).
  Until it is connected, the snap cannot see a keyring, and it uses the
  encrypted file described above for credentials.

## Third-party software

The app is built with Flutter and uses these open-source libraries: `dartssh2`
(SSH), `xterm` (terminal emulation), `flutter_secure_storage` (the platform's
protected storage), `path_provider`, `file_selector` (file dialogs),
`url_launcher` (handing links to your browser), `crypto`, `pointycastle` and
`pinenacl` (cryptography), and `ffi` (Windows system calls). None of them
collects data, contacts a service of its own, or is an advertising or
tracking library.

## Children

SecureShell Go is a system-administration tool. It is not directed at
children, and it collects no data from anyone, including children.

## Your control over your data

- **Delete a saved host** and its stored credentials are deleted with it.
- **Forget a trusted host key** from the host's menu or Settings → Known
  hosts, the equivalent of `ssh-keygen -R`.
- **Diagnostics log:** clear it in Settings, or turn it off to delete it.
- **AI Bridge:** switch it off in Settings → AI Bridge, revoke any paired
  assistant under Paired assistants, and clear the log under Activity.
  Switch off "Share with AI assistants" on a server to take that server away
  from every assistant, or switch off "Let the assistant request changes" to
  make it read-only again.
- **Uninstall.** On Android, uninstalling removes everything the app stored,
  including the Keystore key. On a computer, uninstalling removes the
  program. Delete the data folder listed above to remove its data as well.
  On Linux, saved credentials in your keyring are in an item labelled
  `com.dhivalabs.secure_shell_go/FlutterSecureStorage`, which you can delete
  with your keyring manager.
- Backups, downloads and session logs are ordinary files in the places you
  chose. Delete them as you would any other file.

Nothing is collected or transmitted to Dhiva Labs, so we hold nothing for you
to request, correct or have erased.

## Security

- Credentials are never stored in plain text. See the tables above for what
  protects them on each platform.
- Host keys are checked the way OpenSSH checks them: you are shown the
  fingerprint before you trust a new server, and a changed key blocks the
  connection instead of warning and carrying on.
- The trusted-key store is integrity-protected. If it cannot be verified, the
  app treats every host as unknown and tells you, instead of failing
  silently.
- Weak SSH algorithms are offered only to hosts where you turn on "Allow
  legacy algorithms".

No system is perfect, and this policy does not promise otherwise. If you find
a security problem, please report it at
<https://github.com/Dhiva-Labs/SecureShellGo/issues> or by email to
dhivakar1010@gmail.com.

## Changes to this policy

If this policy changes, the new version will be published at this address,
and the effective date at the top will change. Because the app collects
nothing, a change that made it collect something would be a significant one,
and this page would say so.

## Contact

**dhivakar1010@gmail.com** — <https://github.com/Dhiva-Labs/SecureShellGo>
