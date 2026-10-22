# Privacy Policy — SecureShell Go

**Effective date:** 21 October 2026
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
| `hosts.json` | Your saved servers: the name you gave each one, its address, port and user name, the sign-in method, group, colour, jump host, startup command, terminal connection (SSH or Mosh), whether to keep the shell in tmux or screen, the agent forwarding, X11 forwarding and legacy-algorithm switches, an SSH certificate if you added one (certificates are public), and when you last connected. No passwords or private keys. |
| `known_hosts.json` | The host keys you have trusted: server address, port, key type, fingerprint, and when you trusted it. Fingerprints are public information. The file is sealed with an HMAC whose key is kept in protected storage, so tampering is detected. |
| `settings.json` | Your preferences: appearance, terminal and editor options, keyboard, app lock, diagnostics log on or off. |
| `snippets.json`, `tunnels.json`, `bookmarks.json` | Your command snippets, saved port forwards, and folder bookmarks. |
| `server_jobs.json` | Server-to-server copies that are still running on a server: which servers, which paths, and when they started. An entry is removed once the app has seen the copy finish. |
| `secure_storage_state.json` | Whether a system keyring has ever worked on this device. No secrets. |
| `diagnostics.log` | Only if you turn on the diagnostics log. See below. |

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
