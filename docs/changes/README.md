# Changes waiting for a release

Several parts of 1.5 are built side by side, on separate branches. If each
added its lines to `CHANGELOG.md`, every merge would conflict there. So each
piece of work writes its own file here instead, and nobody edits
`CHANGELOG.md` until the release, when these files are folded into it under
the new version and deleted.

One file per piece of work, named for it:

| File | Work |
| --- | --- |
| `security.md` | Security fixes merged before 1.5 work began |
| `file-browser.md` | Folder-safe Replace, Delete, Rename, New folder, Permissions |
| `login.md` | Keyboard-interactive (two-factor) login and server banners |
| `transfers.md` | Server-to-server copies that outlive the app |
| `layouts.md` | Host list layout fixes, then device layouts (tablets, foldables, touch and mouse) |
| `editor.md` | The remote file editor |
| `ssh-library.md` | dartssh2 4.1 and the legacy-algorithms switch |
| `foundations.md` | Settings and host options shared by the work below |
| `terminal-never-dies.md` | Dead-link detection, reconnects, persistent sessions |
| `ssh-auth.md` | Agent login, certificates, agent and X11 forwarding |
| `standalone.md` | Diagnostics log, Windows Hello, backups |
| `terminal-options.md` | Terminal search, links, font, cursor, bell, scrollback |
| `remote-ops.md` | Commands on many servers, archive and search actions |
| `mosh.md` | Mosh |
| `localization.md` | Translations |

Write for the people using the app, in the sections `CHANGELOG.md` uses:
`### Added`, `### Changed`, `### Fixed`, `### Security`. One line per change,
saying what it does for them, not how it was built.
