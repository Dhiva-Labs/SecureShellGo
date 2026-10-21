### Added
- Run a command on many servers at once: pick hosts or whole groups (from the host list's selection bar or a group's menu), type a command or take a snippet, check the list of hosts, then watch each one's output, exit code and running time come in. Copy one host's output or all of it, stop one host or all, and re-run on the hosts that failed.
- Hosts that would need you at sign-in — no saved password, an unsaved key passphrase, a one-time code, or a host key not yet checked — are skipped with the reason instead of waiting on a prompt. A changed host key stops that host.
- File browser: Compress files and folders to .tar.gz or .zip, on the server.
- File browser: Extract .tar, .tar.gz/.tgz, .tar.xz/.txz and .zip into a folder beside the archive. An existing folder is never written into without asking whether to keep or replace its files, and archives with entries that would land outside the folder are refused.
- File browser: Search on the server from the folder on screen, by name or pattern and optionally by what files contain. Tap a result to go to it.
- File browser: Duplicate makes a "name copy" beside the original, with permissions, times and links kept.
- File browser: Change owner and group, optionally for everything inside a folder. Links change themselves, never what they point to.
- The browser asks each server once which tools it has (GNU, BusyBox, BSD) and offers only the actions that will work there — no zip on a box without one, nothing on an SFTP-only account.
- Compress, Extract, Duplicate and Change owner keep running on the server if the app is closed, and can be stopped from the browser while they run.

### Fixed
- Filling in a snippet's blanks no longer trips an error as the dialog closes.
