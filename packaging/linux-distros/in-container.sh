#!/usr/bin/env bash
# Runs inside a distribution container started by verify.sh.
# MODE: rpm (Fedora) | rpm-suse (openSUSE) | pacman (Arch) | appimage (Fedora)
# FILE: the package to install, under /pkgs.
set -euo pipefail
# shellcheck source=/dev/null
. /linux-distros/distro.conf

# Tools for the checks below, plus the display and GL stack when there is a
# GUI smoke test, per distribution.
# SMOKE_SCRIPT (the repository's own smoke test) looks for the window with
# xdotool, which all three distributions package under that name.
extra=(); [ -z "${SMOKE_SCRIPT:-}" ] || extra=(xdotool)
case "$MODE" in
  rpm|appimage)
    pkgs=(); [ -z "${GUI_CMD:-}" ] || pkgs=(xorg-x11-server-Xvfb xorg-x11-xauth mesa-dri-drivers dbus-daemon "${extra[@]}")
    dnf -y -q install file findutils which procps-ng "${pkgs[@]}"
    ;;
  rpm-suse)
    # xvfb-run needs awk; dbus-run-session is not in dbus-1 there but in
    # dbus-1-daemon.
    pkgs=(); [ -z "${GUI_CMD:-}" ] || pkgs=(xvfb-run gawk Mesa-dri dbus-1 dbus-1-daemon "${extra[@]}")
    zypper -n -q --gpg-auto-import-keys refresh
    zypper -n -q install file findutils which procps "${pkgs[@]}"
    ;;
  pacman)
    pkgs=(); [ -z "${GUI_CMD:-}" ] || pkgs=(xorg-server-xvfb xorg-xauth mesa dbus "${extra[@]}")
    pacman -Syu --noconfirm --needed -q file findutils which procps-ng "${pkgs[@]}"
    ;;
esac

# What the package declares, for the log: dependencies and weak dependencies.
case "$MODE" in
  rpm|rpm-suse) rpm -qip "$FILE"; echo "Requires:"; rpm -qpR "$FILE"; echo "Recommends:"; rpm -qp --recommends "$FILE" ;;
  pacman) pacman -Qip "$FILE" ;;
esac

case "$MODE" in
  rpm)      dnf -y install "$FILE"; files() { rpm -ql "$NAME"; } ;;
  rpm-suse) zypper -n install --allow-unsigned-rpm "$FILE"; files() { rpm -ql "$NAME"; } ;;
  pacman)   pacman -U --noconfirm "$FILE"; files() { pacman -Qlq "$NAME"; } ;;
  appimage)
    # The libraries an AppImage expects from the host: GTK 3 and friends, and
    # the EGL/GLES libraries Flutter's engine opens at run time (every
    # desktop has them; the minimal container does not).
    dnf -y -q install gtk3 libglvnd-egl libglvnd-gles
    cp "$FILE" /tmp/app.AppImage
    chmod +x /tmp/app.AppImage
    (cd /tmp && /tmp/app.AppImage --appimage-extract > /dev/null)
    files() { find /tmp/squashfs-root -type f; }
    ;;
  *) echo "unknown MODE $MODE" >&2; exit 2 ;;
esac

# Every ELF file the package installed must find all of its libraries. The
# package's own library directories go on LD_LIBRARY_PATH, as the app's
# RPATH/$ORIGIN would supply them at run time, so only libraries missing
# from the distribution are reported.
mapfile -t elfs < <(files | while IFS= read -r f; do
  [ -f "$f" ] && [ ! -L "$f" ] || continue
  [ "$(head -c 4 "$f" | od -An -tx1 | tr -d ' \n')" = 7f454c46 ] && echo "$f"
done)
libdirs="$(for f in "${elfs[@]}"; do case "$f" in *.so|*.so.*) dirname "$f" ;; esac; done | sort -u | paste -sd:)"
missing=0
for f in "${elfs[@]}"; do
  if LD_LIBRARY_PATH="$libdirs" ldd "$f" 2>&1 | grep 'not found' > /dev/null; then
    echo "missing libraries for $f:"
    LD_LIBRARY_PATH="$libdirs" ldd "$f" | grep 'not found'
    missing=1
  fi
done
echo "${#elfs[@]} ELF files checked with ldd"
[ "$missing" = 0 ] || exit 1

# Smoke test. CLI tools: SMOKE_CMD must exit 0. GUI apps: SMOKE_SCRIPT (from
# the repository, given the command to start) must pass under Xvfb, or
# without one, GUI_CMD must still be running after SMOKE_SECONDS with no
# loader errors.
if [ "$MODE" = appimage ]; then
  export APPIMAGE_EXTRACT_AND_RUN=1
  cmd_prefix=/tmp/app.AppImage
else
  cmd_prefix=
fi
if [ -n "${SMOKE_CMD:-}" ]; then
  if [ -n "$cmd_prefix" ]; then
    # SMOKE_CMD's first word is the installed command; the AppImage replaces it.
    read -r -a words <<< "$SMOKE_CMD"
    "$cmd_prefix" "${words[@]:1}"
  else
    bash -c "$SMOKE_CMD"
  fi
fi
if [ -n "${GUI_CMD:-}" ] && [ -n "${SMOKE_SCRIPT:-}" ]; then
  if [ -n "$cmd_prefix" ]; then gui=("$cmd_prefix"); else read -r -a gui <<< "$GUI_CMD"; fi
  export HOME=/tmp/smoke-home
  mkdir -p "$HOME"
  xvfb-run -a -s '-screen 0 1280x800x24' dbus-run-session -- bash "/src/$SMOKE_SCRIPT" "${gui[@]}"
elif [ -n "${GUI_CMD:-}" ]; then
  if [ -n "$cmd_prefix" ]; then gui=("$cmd_prefix"); else read -r -a gui <<< "$GUI_CMD"; fi
  cat > /tmp/smoke.sh <<'EOS'
log=/tmp/smoke.log
"$@" > "$log" 2>&1 &
pid=$!
secs="${SMOKE_SECONDS:-20}"
for _ in $(seq 1 "$secs"); do
  kill -0 "$pid" 2> /dev/null || break
  sleep 1
done
if kill -0 "$pid" 2> /dev/null; then
  echo "still running after ${secs}s"
  kill "$pid"
  ok=1
else
  wait "$pid" && rc=0 || rc=$?
  echo "exited early with status $rc"
  ok=0
fi
cat "$log"
if grep -E 'error while loading shared libraries|cannot open shared object|undefined symbol' "$log"; then ok=0; fi
[ "$ok" = 1 ]
EOS
  export HOME=/tmp/smoke-home SMOKE_SECONDS
  mkdir -p "$HOME"
  xvfb-run -a -s '-screen 0 1280x800x24' dbus-run-session -- bash /tmp/smoke.sh "${gui[@]}"
fi
echo "$MODE: OK"
