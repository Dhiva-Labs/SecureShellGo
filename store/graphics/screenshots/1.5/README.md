# Store screenshots, 1.5

These are rendered from the app's real screens by
`test/store_screenshots_test.dart`, with made-up demo content: `example.com`
hosts, a fictional `inventory-api` project, htop and a log on a made-up
web server. They contain no real hostnames, accounts or personal data.
They replace the July 2026 sets in `../phone`, `../tablet7` and
`../tablet10`, which predate 1.5.

Every file is a 24-bit PNG with no alpha channel, at the exact size the store
asks for. Play rejects screenshots that have an alpha channel.

## Regenerate

From the repository root:

```bash
STORE_SHOTS=store/graphics/screenshots/1.5 flutter test test/store_screenshots_test.dart
```

For a translated set, add `STORE_LOCALE` with one of the app's language tags
(`de`, `es`, `fr`, `ja`, `ko`, `pt`, `ru`, `zh`) and write it to a folder of
its own:

```bash
STORE_SHOTS=build/store-shots/de STORE_LOCALE=de flutter test test/store_screenshots_test.dart
```

A screen shows in the chosen language only once its strings are translated
on the branch you render from. Without `STORE_SHOTS` the test is skipped, so
a plain `flutter test` does not run it.

The harness needs these fonts on the machine. Ubuntu's `fonts-dejavu-core`,
`fonts-noto-core`, `fonts-noto-cjk` and `fonts-droid-fallback` packages
provide them.

- Roboto and Material Icons, from Flutter's own cache.
- JetBrains Mono, from `assets/fonts`.
- DejaVu Sans Mono, for the editor.
- Noto Sans, used in place of Segoe UI in the Windows set. Segoe UI cannot
  be bundled here, and Noto Sans is the closest open font to it.
- Noto Sans CJK and Droid Sans Fallback, for `ja`, `ko` and `zh`.

## Which slot each image is for

Upload each set in file-name order. All are in the dark theme except where
noted.

### Google Play, phone (1080 × 1920)

| File | Shows |
|------|-------|
| `phone/01-hosts.png` | Saved hosts in groups, with colour tags and quick connect |
| `phone/02-terminal.png` | htop in a session, three sessions in tabs, the extra-keys row |
| `phone/03-files.png` | SFTP browser in a project folder |
| `phone/04-editor.png` | The editor on a Python file, three files open |
| `phone/05-find.png` | Find in the scrollback, matches highlighted in a log |
| `phone/06-mosh.png` | A host's Advanced options: Mosh, tmux, agent forwarding |
| `phone/07-fleet.png` | One command run on eight servers, with output and exit codes |
| `phone/08-settings.png` | Settings: UI style, brightness, language (light theme) |

### Google Play, 7-inch tablet (1200 × 1920)

| File | Shows |
|------|-------|
| `tablet7/01-session.png` | Terminal and files side by side |
| `tablet7/02-hosts.png` | Host grid (light theme) |
| `tablet7/03-editor.png` | Editor with the open-files list beside it |
| `tablet7/04-fleet.png` | Command on many servers, results |

### Google Play, 10-inch tablet (1600 × 2560)

| File | Shows |
|------|-------|
| `tablet10/01-session.png` | Terminal and files side by side |
| `tablet10/02-hosts.png` | Host grid (light theme) |
| `tablet10/03-editor.png` | Editor with the open-files list beside it |
| `tablet10/04-find.png` | Find in the scrollback, beside the files |

### Microsoft Store, desktop (1920 × 1080)

These render as Windows, with a mouse and keyboard, at 125% scaling.

| File | Shows |
|------|-------|
| `windows/01-split-panes.png` | Two sessions in split panes: htop and a deploy |
| `windows/02-terminal-and-files.png` | Terminal and SFTP browser side by side |
| `windows/03-hosts.png` | Host grid with groups (light theme) |
| `windows/04-editor.png` | The editor on a Python file |
| `windows/05-fleet.png` | Command on many servers, results |
| `windows/06-advanced.png` | Advanced host options on Windows: Mosh, tmux, agent and X11 forwarding |
