# Play Console: foreground service declaration

SecureShell Go 1.5 declares two foreground service types on
`SessionForegroundService` (see `android/app/src/main/AndroidManifest.xml`):
`specialUse` (Android 14+) and `dataSync` (Android 10–13, and the fallback).
Play Console → App content → Foreground service permissions needs an entry
for each.

## specialUse

**Subtype (manifest `PROPERTY_SPECIAL_USE_FGS_SUBTYPE`):**
Keeps a user-opened interactive SSH terminal session connected while the app is in the background

**Description for review:**
SecureShell Go is an SSH client. When the user opens a terminal session to
one of their own servers, the app starts a foreground service with an
ongoing notification naming the server. The service keeps the app's process,
and with it the encrypted SSH connection and the remote shell, alive while
the user switches to another app — for example to copy a command from a
browser, or to leave a long build or a log running. It stops as soon as the
user closes their last session, and the notification returns them to it.

**Why no other type fits:** an interactive terminal is not a data transfer
with an end (`dataSync`), nor media, location, a phone call or a connected
device. The session can sit idle for hours waiting for the user, and
`dataSync` is limited to six hours a day on Android 15, after which Android
stops the service and the user's session is lost without them having done
anything.

**User impact if deferred or interrupted:** the SSH connection is closed and
whatever the user was running in the remote shell without a persistent
session is lost.

**Video:** record: open a host → run `top` → switch to another app → wait →
return via the notification, session still live → close the session, the
notification disappears.

## dataSync

**Description:** the same service on Android 10–13, which have no
`specialUse`: it keeps an SSH session (shell and file transfers the user
started) connected while the app is in the background, and stops when the
last session is closed.
