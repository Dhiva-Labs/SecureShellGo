### Added
- A connection that has silently died (no answer to three keep-alives and nothing else heard from the server) is noticed and reconnected, instead of leaving the terminal frozen until the system gives up on it.
- Sessions check their connection straight away when the network changes, when the app comes back on screen and when a computer wakes from sleep, and reconnect over the new network at once.
- A disconnected session always has a Reconnect button, and one that stopped trying because there was no network tries again by itself when the network comes back.
- When the shell exits but the connection is fine, a "Shell ended" strip offers Restart: a new shell in the same tab, with no new login.
- Persistent sessions: a host set to tmux or GNU screen runs its shell inside one, named per tab, so a reconnect — or reopening the app — lands back in the same shell with whatever was running in it. tmux falls back to screen, and either falls back to an ordinary shell with a one-line notice — when it is not installed, and also when it is installed but will not start. The host's startup command is only typed into a new shell, never into one left running.

### Changed
- Transfers cut off by a dropped connection are marked interrupted rather than cancelled, and start again by themselves once the session reconnects — including copies to another server whose session dropped.
- A server closing the connection under a running shell (a reboot, sshd restarting) is reconnected; typing `exit` still ends the session for good.
- On Android 14 and later the background service keeping sessions alive runs as a special-use service, so Android 15's six-hour daily limit no longer stops it; if Android does stop it, it is started again when the app is next on screen.

### Fixed
- A session that had already reconnected once now reconnects again on its next drop, instead of staying disconnected.
- When reconnecting stopped because of a refused login or a changed host key, the strip above the terminal now says so.
