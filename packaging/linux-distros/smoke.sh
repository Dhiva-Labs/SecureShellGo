#!/usr/bin/env bash
# Starts SecureShell Go and waits for its window and for the data folder the
# Dart start-up code creates. The native runner shows the window only after
# Flutter has drawn its first frame, so the window plus the folder prove the
# AOT snapshot runs; the same check desktop-builds.yml runs on the tarball.
#
#   smoke.sh <command...>
#
# Needs a display and a session bus (xvfb-run -a dbus-run-session -- ...).
# The window is looked up with xdotool (only a mapped window counts).
# SMOKE_DATA_DIR overrides where the data folder is expected (a Flatpak keeps
# it under ~/.var/app/<id>).
set -u

data="${SMOKE_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/com.dhivalabs.secure_shell_go}"
log="$(mktemp)"
"$@" > "$log" 2>&1 &
pid=$!

window_up() {
  xdotool search --onlyvisible --name '^SecureShell Go$' > /dev/null 2>&1
}

for i in $(seq 1 90); do
  if window_up && [ -d "$data" ]; then
    echo "window is up and $data exists after ${i}s"
    sleep 5
    kill -0 "$pid" 2> /dev/null || { echo "$1 died after showing its window"; cat "$log"; exit 1; }
    kill "$pid"
    cat "$log"
    exit 0
  fi
  kill -0 "$pid" 2> /dev/null || { echo "$1 exited early"; cat "$log"; exit 1; }
  sleep 1
done
echo "no window and data folder after 90s"
ls -R "$HOME" 2> /dev/null | head -50
cat "$log"
kill "$pid" 2> /dev/null
exit 1
