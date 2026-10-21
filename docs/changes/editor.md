### Added
- The remote editor indents like a code editor. Tab and Shift+Tab indent and outdent, Enter keeps the indentation and goes a level deeper after a Python colon or an opening bracket, and each file's own style (tabs or 2, 4 or 8 spaces) is detected and shown in the status bar, where it can be changed.
- Line and comment shortcuts: toggle comment (Ctrl+/), move line (Alt+↑/↓), duplicate line (Shift+Alt+↑/↓), indent and outdent line (Ctrl+] and Ctrl+[).
- Show whitespace, and a warning when a Python, YAML or Makefile file mixes tabs and spaces.
- On phones and tablets, a row of keys over the keyboard with Tab, outdent, arrows, brackets and symbols, plus undo and redo.
- Zoom with a pinch or Ctrl + and Ctrl −. The editor keeps its own text size, also set in Settings.
- With several files open on a wide screen, they are listed in a side panel.
- Syntax colouring for C and C++, Go, Rust, Java, Kotlin, Ruby and PHP.

### Changed
- Each open file keeps its own undo history when switching between them.

### Fixed
- Saving no longer changes bytes nobody edited: a UTF-8 byte-order mark is kept, Ctrl+S on an unchanged file writes nothing, and a file mixing Windows and Linux line endings asks which to keep before saving.
- Tabs are drawn as wide as their tab stop instead of one character.
- With wrapping off, long lines no longer wrap, and line numbers stay beside their lines with large system text and in long files.
