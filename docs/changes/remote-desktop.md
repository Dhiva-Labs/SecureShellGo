### Added

- Remote desktop: see and control a server's desktop from any device, phones included, over the SSH connection you already have. It works with GNOME on Wayland, X11 desktops and Windows. A small agent is copied to the server for the session and stopped afterwards; it listens on the server's loopback only, so no port is opened and SSH is the only login. The person at the server's screen is told while it is being viewed.
- Virtual desktops on servers with no screen: start a private desktop, such as Xfce, or a single program, and use it in the same viewer. Optionally keep it running after you disconnect and come back to it from Remote desktop later.
- Open an app in a window: run one graphical program on the server and have its window open on your own desktop, without a terminal. Where that cannot work — on a phone, or with no X server on Windows — it offers a virtual desktop instead.
- Show a Mac's screen through its built-in Screen Sharing, over the same SSH connection.
- On touch screens the viewer has a trackpad mode and a direct-touch mode, pinch to zoom, and a key bar with Esc, Tab, Ctrl, Alt, Super, arrows, function keys and Ctrl+Alt+Del. Clipboard text goes both ways.

### Changed

- The app is about 4.5 MB larger, for the remote-desktop agents. Nothing extra runs until a remote desktop is opened, and agents left on a server by an older version of the app are removed when a newer one is installed.
