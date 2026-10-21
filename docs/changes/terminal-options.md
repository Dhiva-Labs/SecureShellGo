### Added
- Find in the terminal: Ctrl+Shift+F (or "Find in terminal" in the session's ⋮ menu, or the right-click menu) searches the whole scrollback, with long lines the terminal wrapped searched as one line. It shows how many matched, highlights every match, scrolls to the one you are on, and has Match case and regular-expression switches; Enter and Shift+Enter step through matches and Escape closes it.
- Web addresses in the terminal can be opened: Ctrl+click one with a mouse (the address is highlighted while Ctrl is held over it), right-click it, or long-press it on a touch screen for Open link and Copy link. Only http and https addresses open, in the browser; nothing else is ever run.
- Session logs: "Record session log…" in the session's ⋮ menu writes everything the session prints to a file, as plain text (colours and control codes removed) or exactly as received. On a computer you choose the file first and it is written as the session runs; on Android you choose where to save it — any folder, an SD card or a cloud drive — when you stop. A "Recording" badge stays on the terminal while it runs, and closing the session saves the log first.
- Ctrl+= and Ctrl+− make the terminal text larger and smaller, and Ctrl+0 puts it back; the size is kept for the next session, as a pinch-zoom is.
- Blinking cursor, in Settings > Terminal.

### Changed
- Settings > Terminal's options now take effect: the cursor shape, the bell (vibrate, a brief flash of the screen, or nothing) and the font apply straight away to open sessions, and the scrollback length to each session opened after the change.
- JetBrains Mono is bundled with the app, so choosing it gives the same terminal on every device, box-drawing characters included. Its licence (SIL Open Font License 1.1) is on the licences page.
- The Settings preview shows the chosen font and cursor.
- The monitoring menu in a session's toolbar is now the session's ⋮ menu: Find in terminal and the session log, then Server stats, Services & processes and Tail a file. A disconnected session's scrollback can still be searched.

### Fixed
- The block cursor no longer hides the character under it; the character shows through in reverse.
