# Privacy Policy — SecureShell Go

**Effective date:** 28 July 2026
**Applies to:** SecureShell Go for Android (`com.dhivalabs.secure_shell_go`),
published by Dhiva Labs.

## The short version

SecureShell Go does not collect anything. There is no account to create, no
analytics, no advertising, no crash reporting, and no Dhiva Labs server for
your data to be sent to — we do not operate one. The only computers this app
talks to are the SSH servers whose addresses you type in yourself.

Everything the app remembers stays in its private storage on your phone, and
your passwords and private keys are held in the Android Keystore.

## Who is responsible

Dhiva Labs — contact: **dhivakar1010@gmail.com**
Source code: <https://github.com/Dhiva-Labs/SecureShellGo>

The app is open source under the MIT licence. Every claim on this page can be
checked against the code.

## What the app is

An SSH terminal and SFTP file client. You give it the address, port, username
and credentials of a server you already have access to; it opens an encrypted
SSH connection to that server, gives you a shell, and lets you move files in
both directions.

## Information Dhiva Labs collects

**None.**

- No personal information is collected.
- No usage, diagnostic or performance data is collected.
- No advertising or analytics SDK is included in the app. There is no
  Firebase, no Google Analytics, no Crashlytics, no Sentry, no attribution or
  tracking library of any kind.
- No advertising identifier is read.
- There are no ads.
- There is no sign-up, sign-in or account.
- Nothing is ever transmitted to Dhiva Labs, because there is nothing for it
  to be transmitted to. Dhiva Labs runs no backend service for this app.

## Information stored on your device

All of the following is written only to storage that belongs to the app and
that Android keeps private to it. None of it is transmitted anywhere.

| What | Where | Notes |
| --- | --- | --- |
| Saved hosts — the label you gave a server, its hostname, port, username, which authentication method it uses, and when you last connected | `hosts.json` in the app's private files directory | Contains no secrets. |
| Passwords, private keys and key passphrases, for hosts you chose to save | Android Keystore–backed encrypted storage | See below. |
| Trusted host keys — the SSH fingerprints of servers you have accepted | `known_hosts.json` in the app's private files directory | Fingerprints are public information, the same values `ssh-keygen -lf` prints. The file is sealed with an HMAC whose key is in the Keystore, so tampering with it is detected. |
| Preferences — terminal font size, colour scheme, keep-screen-awake, show hidden files | `settings.json` in the app's private files directory | Contains no secrets. |

**About credentials.** A password, private key or passphrase is written to
storage only when you save a host with it filled in. If you use the
"connect without saving" path, the credential is held in memory for that
connection and never written to disk. Saved credentials go through Android's
encrypted storage, which encrypts them with a key generated inside the Android
Keystore — on most devices that key is held in dedicated security hardware and
cannot be exported from the device at all.

**Backups are turned off.** The app sets `allowBackup="false"` and excludes
itself from device-to-device transfer, so none of the above is copied into
Google Drive backups or moved to a new phone. That is deliberate: an SSH
credential store should not leave the device it was created on. Moving to a
new phone means adding your hosts again and re-verifying their host keys.

## Where your data goes

The app makes exactly one kind of outbound network connection: an SSH
connection to a host you configured. There is no other network code in it.

Over that connection, and only to that server:

- what you type in the terminal, and what the server prints back;
- files you upload, and the directory listings and files you download.

That is the ordinary operation of an SSH client, it goes to a machine you
chose, and it is encrypted by the SSH protocol. Dhiva Labs has no visibility
into it.

Before the first connection to a new server, the app shows you that server's
key fingerprint and asks you to accept it. If the fingerprint later changes,
the connection is blocked and you are warned, because that is what a
machine-in-the-middle attack looks like.

## Files on your device

- **Downloads** you pull from a server are written to your device's shared
  Downloads folder, so they appear in your file manager like any other
  download.
- **Uploads** read only the specific files you pick in the system file
  picker, or that you send to the app through another app's Share menu. The
  app has no general access to your storage and does not browse or index it.
- Files arriving through the Share menu are copied into the app's own cache
  first so they can be streamed to the server; those copies are deleted
  automatically as they age out.

## Permissions the app requests, and why

| Permission | Why |
| --- | --- |
| `INTERNET` | To open the SSH connection. Without it the app cannot do anything. |
| `FOREGROUND_SERVICE` and `FOREGROUND_SERVICE_DATA_SYNC` | While a session is open, the app runs a foreground service with an ongoing notification so Android does not shut the process down — which would drop your connection and kill whatever was running in it — while you are in another app. |
| `POST_NOTIFICATIONS` | To show that ongoing "connected" notification. Asked for the first time you open a session, never at launch. Declining it is fine: the notification is hidden and the session still works. |
| `WRITE_EXTERNAL_STORAGE`, capped at Android 9 | Only on Android 9 and older, and only to save downloads into the public Downloads folder. On Android 10 and newer the app requests no storage permission at all. |
| `ACCESS_LOCAL_NETWORK` | Granted automatically by Android 16 to apps that use the network, so that connections to servers on your own home or office network keep working. It is not declared by the app. |

## Third-party software

The app is built with Flutter and uses these open-source libraries:
`dartssh2` (the SSH protocol), `xterm` (terminal emulation),
`flutter_secure_storage` (Keystore access), `path_provider`, and `crypto`.

None of them collects data, contacts a remote service of its own, or is a
tracking or advertising SDK.

## Children

SecureShell Go is a system-administration tool. It is not directed at
children and collects no data from anyone, including children.

## Your control over your data

- Delete a saved host from the host list and its stored credentials are
  deleted with it.
- Forget a trusted host key from the host list menu or the Known Hosts
  screen — the equivalent of `ssh-keygen -R`.
- Uninstalling the app removes everything it stored, including the Keystore
  key that protects your saved credentials.

Since nothing is collected or transmitted, there is nothing held elsewhere for
you to request, correct or have erased.

## Security

- Credentials are stored using Android Keystore–backed encryption, never in
  plain text.
- Host keys are verified on the OpenSSH trust-on-first-use model, and a
  changed key blocks the connection rather than warning and continuing.
- The trusted-key store is integrity-protected; if it cannot be verified the
  app treats every host as unknown and tells you, rather than failing
  silently.
- The app makes no unencrypted HTTP requests. Cleartext traffic is disabled.

No system is perfect, and this policy does not promise otherwise. If you find
a security problem, please report it at
<https://github.com/Dhiva-Labs/SecureShellGo/issues> or by email to
dhivakar1010@gmail.com.

## Changes to this policy

If this policy changes, the new version will be published at this address and
the effective date at the top will change. Because the app collects nothing,
any change that made it collect something would be a significant one, and it
would be described here.

## Contact

**dhivakar1010@gmail.com** — <https://github.com/Dhiva-Labs/SecureShellGo>
