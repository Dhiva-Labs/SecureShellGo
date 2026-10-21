# 1.5.0 release checklist — what only real devices can prove

Everything below was built and unit/widget-tested on Linux, but could not be
run here: this machine has no Android SDK, no Windows SDK, no foldable, no
security key and no real network to roam across. Tick each box on real
hardware before the build goes to a store. Where a box fails, note what you
saw — the line it came from is the place to start.

## 0. Builds that have never been compiled

- [ ] **Android (Kotlin):** `flutter build appbundle --release` with
      `android/key.properties` in place. New Kotlin since 1.4.5:
      `NetworkWatchBridge.kt` (network changes), `DocumentSaver.kt` (Save to…),
      the foreground service's `specialUse` type and `onTimeout`.
- [ ] **Windows (C++):** `flutter build windows --release`. New C++:
      `windows/runner/windows_hello.{h,cpp}`. If it fails on exceptions, the
      runner's `_HAS_EXCEPTIONS=0` meets the C++/WinRT headers; it needs
      `UserConsentVerifierInterop.h` from a Windows 11 SDK.
- [ ] **Windows (Dart FFI):** `lib/services/windows_agent_pipe.dart` (Pageant
      pipe owner check) has never run on Windows.
- [ ] **MSIX:** package and run the Windows App Certification Kit on it.

## 1. Android phone

Connection that never dies:
- [ ] The foreground service starts as `specialUse` on Android 14/15; the
      ongoing notification shows; declining notifications still works.
- [ ] Wi-Fi → mobile data handover mid-session: the session reconnects by
      itself, and an upload in progress resumes.
- [ ] Airplane mode on for a minute, then off: the session comes back
      without touching anything.
- [ ] 6 hours in the background with a session open: still alive, or
      reconnects the moment the app is opened.
- [ ] On a device that applies the `dataSync` fallback: the FGS timeout
      notifies the app and the service restarts when the app is next opened.
- [ ] A host with "Keep the shell running" = tmux: drop the network, come
      back — the same shell, with its scrollback and running job.

Mosh:
- [ ] A Mosh host over Wi-Fi, then switch to mobile data: the terminal keeps
      working without a reconnect.
- [ ] Lock the phone for an hour, unlock: the Mosh terminal is still there.
- [ ] On a slow link (or with packet loss): typed characters show before the
      echo; a password prompt shows nothing typed.
- [ ] A server behind NAT: Mosh's UDP ports (60000–61000) must be forwarded;
      without them the terminal falls back to SSH and says why.

Editor and touch:
- [ ] Typing in the editor through the on-screen keyboard, including a
      predictive keyboard and a CJK input method (composition is left alone).
- [ ] The editor key bar: Tab, outdent, brackets auto-closing, undo/redo.
- [ ] Pinch-zoom in the terminal and the editor.
- [ ] A link in the terminal: long-press → Open link / Copy link.
- [ ] Bell set to Vibrate and to Flash the screen.
- [ ] Blinking cursor while the keyboard is composing.

Files and backups:
- [ ] Session log: start, stop, and the save picker appears; the file opens.
- [ ] Backup → Save to… → Google Drive, and → Files. The saved backup
      imports again on a clean install.
- [ ] Rotate the phone while the save screen is open, then cancel: no empty
      `.ssgbackup` is left behind.
- [ ] Share a file into the app from another app; it uploads.

## 2. Android tablet, foldable, DeX

- [ ] Foldable: half-open (book posture) splits terminal and files at the
      hinge; tabletop posture puts the terminal above and files below; fully
      open behaves as one screen. Check the hinge values the device reports.
- [ ] Samsung DeX with a mouse: the split workspace appears; right-click
      menus work; Ctrl+Tab and Ctrl+Shift+T work and the shell does not see
      them.
- [ ] Tablet with a keyboard cover: its keys count as a hardware keyboard
      (the extra keys row hides while typing on it); a keyboard toolbar
      strip on screen is not mistaken for the on-screen keyboard.
- [ ] The full-width terminal toggle on a tablet.

## 3. Windows

- [ ] Windows Hello app lock: the prompt opens in front of the window;
      Cancel stays locked; PIN unlocks; on a PC without Hello the settings
      say to set it up; minimising past the timeout locks.
- [ ] Sign-in with the Windows OpenSSH agent and with Pageant; a non-pipe
      `SSH_AUTH_SOCK` (e.g. a msys2 socket file) is skipped, not written to.
- [ ] X11 forwarding with VcXsrv or X410: `xeyes` opens. The X11 row says
      the server can see and control windows on that display.
- [ ] Ctrl+click on a link opens the browser.
- [ ] Session log save dialog; Backup "Save to…" with an existing file name
      (saves as "name (1)").
- [ ] JetBrains Mono renders in the terminal; zoom with Ctrl+= / Ctrl+−.
- [ ] Touch screen and the touch keyboard: the extra keys row behaves.
- [ ] Sleep and wake the PC with a session open: it reconnects.

## 4. Linux desktop

- [ ] X11 forwarding on an Xorg display with the SECURITY extension:
      untrusted forwarding works (`xeyes`), and the warning appears where it
      cannot.
- [ ] The snap starts, connects, and saves a host with the keyring locked
      and unlocked.

## 5. Real servers

- [ ] Agent sign-in with a YubiKey `sk-ed25519` key, including not touching
      the key in time.
- [ ] A user-CA certificate on OpenSSH 9; the host form shows its principals,
      validity and any force-command.
- [ ] Agent forwarding: `ssh-add -l` on the server lists the keys; the stats
      view and log tail keep working afterwards.
- [ ] Commands on many servers against real OpenSSH hosts: an open session's
      connection is reused; a 2FA host and an unchecked-key host are skipped
      with the reason; Stop ends a long-running command.
- [ ] The same Stop against a Dropbear box.
- [ ] Every file action on a GNU server and on a BusyBox box: compress,
      extract into a new and an existing folder, search, duplicate, chown as
      root and as a normal user. Extracted files keep normal permissions.
- [ ] Close the app in the middle of a compress: the job finishes on the
      server and the app picks it up next time.
- [ ] A macOS or FreeBSD server (bsdtar, BSD find/grep/cp) — never run yet.
- [ ] An old router/NAS with "Allow legacy algorithms".
- [ ] A jump host.
- [ ] Search over 50,000 lines of scrollback stays responsive.

## 6. Store consoles

Google Play:
- [ ] Upload signing key created and `android/key.properties` filled in
      (never committed).
- [ ] Foreground service declarations: `specialUse` (text in
      `store/play-fgs-declaration.md`) and `dataSync`.
- [ ] Data safety form (`store/play-data-safety.md`), content rating,
      target audience, privacy policy URL.
- [ ] Listing (`store/listing.md`) and phone/tablet screenshots in 9:16.
- [ ] Internal testing track first, then production.

Microsoft Store:
- [ ] Partner Center identity (name, publisher) in the MSIX config.
- [ ] Listing (`store/microsoft-store-listing.md`) and screenshots.
- [ ] Windows App Certification Kit passes; submit.
