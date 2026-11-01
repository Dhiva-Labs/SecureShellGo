#!/usr/bin/env bash
# Lays out the installed file tree that the .rpm, Arch package, AppImage and
# Flatpak are built from, from a Linux release tarball (GitHub releases carry
# no .deb; the PPA builds its own from debian/). The layout is the PPA
# package's (debian/rules), so every Linux package installs the same files in
# the same places:
#
#   /opt/secureshellgo/       secure_shell_go, lib/, data/ (the bundle as it is)
#   /usr/bin/secureshellgo    debian/secureshellgo.wrapper
#   /usr/share/applications/com.dhivalabs.secure_shell_go.desktop
#   /usr/share/icons/hicolor/256x256/apps/secureshellgo.png
#   /usr/share/metainfo/com.dhivalabs.secure_shell_go.metainfo.xml
#
# usage: tree.sh <SecureShellGo-linux-<arch>.tar.gz> <root>
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[ $# -eq 2 ] || { echo "usage: $0 <tarball> <root>" >&2; exit 2; }
tarball="$1"
root="$2"
id=com.dhivalabs.secure_shell_go

umask 022
mkdir -p "$root/opt/secureshellgo"
tar -xzf "$tarball" -C "$root/opt/secureshellgo" --strip-components=1 --no-same-owner
for f in secure_shell_go lib/libapp.so lib/libflutter_linux_gtk.so data/icudtl.dat; do
  [ -f "$root/opt/secureshellgo/$f" ] || { echo "$f is not in $tarball" >&2; exit 1; }
done
install -Dm755 "$repo/debian/secureshellgo.wrapper" "$root/usr/bin/secureshellgo"
install -Dm644 "$repo/linux/$id.desktop" "$root/usr/share/applications/$id.desktop"
install -Dm644 "$repo/linux/secureshellgo-256.png" "$root/usr/share/icons/hicolor/256x256/apps/secureshellgo.png"
install -Dm644 "$repo/packaging/flatpak/$id.metainfo.xml" "$root/usr/share/metainfo/$id.metainfo.xml"
