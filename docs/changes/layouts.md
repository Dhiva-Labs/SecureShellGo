### Added
- Screens are laid out for the hands on the device, not its operating system: a tablet in a trackpad cover or a Samsung DeX desk gets split panes, right-click menus and drag-and-drop like a desktop, and a Windows tablet used by touch gets the touch layout. Each gesture goes by the pointer making it: a file drags to another session's tab with a mouse or trackpad, while a finger's long-press on it opens its actions.
- On foldables, a session's terminal and files split at the hinge: one on each side when the device is open like a book, the terminal above the fold and the files below when it stands on a table. A device with two screens puts one on each and nothing under the hinge.
- On tablets, the terminal can take the whole width with one button, and give the files their side back with another.
- Right-click on the terminal for Copy, Paste and Select all, and on a saved host for its actions in a menu beside the pointer. A middle click on the terminal opens no menu.
- Keyboard shortcuts on the sessions screen, from the terminal or the files alike: Ctrl+Shift+T for a new session, Ctrl+Tab and Ctrl+Shift+Tab between sessions (in a split window, to the pane already showing one), Ctrl+Shift+E between terminal and files, Ctrl+Shift+Enter for a full-width terminal. Ctrl+PgUp and Ctrl+PgDn stay with the shell, for vim and emacs. Tooltips name them when a keyboard is in use.

### Changed
- The terminal's and the editor's extra-keys rows follow Settings → Keyboard → Extra keys row: automatically, they hide while a hardware keyboard is typing and come back when the on-screen keyboard opens. Always and Never mean just that. Keys typed while the on-screen keyboard is open never count as a hardware keyboard — terminal keyboards such as Hacker's Keyboard and Unexpected Keyboard send Esc, Tab and Ctrl the way a real one does — and once the on-screen keyboard has been open, the row stays until a key is typed with it put away.
- A Ctrl armed on the terminal's extra-keys row is let go when the row hides, rather than turning the next key typed into a control code with nothing on screen to say so.
- The editor puts the cursor in the file as it opens wherever a hardware keyboard is in use, a keyboard cover on a tablet included, and starts it at the top of the file.
- Once the screen has been touched, buttons, session tabs and their close buttons are at least 48dp, also on a desktop with a touchscreen. The AWS style's compact spacing gives way to these targets on a touch screen, and split-pane headers and the editor's tab strip grow to hold them.
- Terminal and files share the screen only when the window is tall enough as well as wide; a phone on its side shows one at a time.

### Fixed
- The host list is laid out for the screen it is on, without clipped or overflowing rows at phone, tablet and desktop sizes or with large text.
- A long user@host no longer overflows the sessions screen's title on a phone.
- A long host name no longer runs off the edge of the Tunnels screen on a narrow phone with large text.
- On a 320dp phone the sessions screen keeps room for the host's name: snippets, monitoring, new session and disconnect move into a menu.
- The host form no longer runs off the right edge of a narrow window when a jump host or a group has a long name.
- The file browser's path reads "/ home / deploy", without a second slash after the root.
- The extra-keys row's Paste key shows a clipboard icon, where some fonts drew an empty box.
