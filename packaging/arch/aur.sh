#!/usr/bin/env bash
# Renders the AUR PKGBUILD for one release and proves it builds.
#
# usage: aur.sh <SecureShellGo-linux-x64.tar.gz> <SecureShellGo-linux-arm64.tar.gz> <outdir>
#
# Fills PKGBUILD.in with the version, the release download URL and the
# sha256 of both release tarballs and of the files it takes from the tagged
# tree (LICENSE, launcher, desktop file, icon, metainfo; this checkout's
# copies), then,
# in an archlinux:latest container, generates .SRCINFO, runs makepkg on the
# x86_64 sources (all placed next to the PKGBUILD, so makepkg verifies their
# checksums without downloading), installs the result and runs ldd on every
# ELF file in it. Writes <name>-bin-<version>-aur.tar.gz holding PKGBUILD and
# .SRCINFO, ready to push to the AUR.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
[ $# -eq 3 ] || { echo "usage: $0 <SecureShellGo-linux-x64.tar.gz> <SecureShellGo-linux-arm64.tar.gz> <outdir>" >&2; exit 2; }
tar_x64="$(readlink -f "$1")"; tar_arm64="$(readlink -f "$2")"
mkdir -p "$3"; out="$(cd "$3" && pwd)"
# shellcheck source=/dev/null
. "$here/../linux-distros/distro.conf"
: "${VERSION:?set VERSION}"
tag="${TAG_PREFIX-v}$VERSION"
[ "$(basename "$tar_x64")" = SecureShellGo-linux-x64.tar.gz ] || { echo "unexpected $tar_x64" >&2; exit 1; }
[ "$(basename "$tar_arm64")" = SecureShellGo-linux-arm64.tar.gz ] || { echo "unexpected $tar_arm64" >&2; exit 1; }

sha() { sha256sum "$1" | cut -d' ' -f1; }
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
deps=""; for d in "${ARCH_DEPENDS[@]}"; do deps+="'$d' "; done
optdeps=""; for d in "${ARCH_OPTDEPENDS[@]}"; do optdeps+="'$d' "; done
sed -e "s|@NAME@|$NAME|g" -e "s|@VERSION@|$VERSION|g" \
    -e "s|@SUMMARY@|${SUMMARY//\'/}|g" -e "s|@HOMEPAGE@|$HOMEPAGE|g" \
    -e "s|@LICENSE@|$LICENSE|g" -e "s|@ARCH_DEPENDS@|${deps% }|g" \
    -e "s|@ARCH_OPTDEPENDS@|${optdeps% }|g" \
    -e "s|@GITHUB_REPO@|$GITHUB_REPO|g" -e "s|@TAG@|$tag|g" \
    -e "s|@RELEASE_URL@|https://github.com/$GITHUB_REPO/releases/download/$tag|g" \
    -e "s|@SHA_LICENSE@|$(sha "$repo/LICENSE")|g" \
    -e "s|@SHA_WRAPPER@|$(sha "$repo/debian/secureshellgo.wrapper")|g" \
    -e "s|@SHA_DESKTOP@|$(sha "$repo/linux/com.dhivalabs.secure_shell_go.desktop")|g" \
    -e "s|@SHA_ICON@|$(sha "$repo/linux/secureshellgo-256.png")|g" \
    -e "s|@SHA_METAINFO@|$(sha "$repo/packaging/flatpak/com.dhivalabs.secure_shell_go.metainfo.xml")|g" \
    -e "s|@SHA_X64@|$(sha "$tar_x64")|g" -e "s|@SHA_ARM64@|$(sha "$tar_arm64")|g" \
    "$here/PKGBUILD.in" > "$work/PKGBUILD"
if grep -n '@[A-Z0-9_]*@' "$work/PKGBUILD"; then echo "unfilled placeholder" >&2; exit 1; fi
# The sources makepkg would download, placed where it looks first, under
# the names the PKGBUILD gives them.
cp "$tar_x64" "$work/SecureShellGo-$VERSION-linux-x64.tar.gz"
cp "$repo/LICENSE" "$work/LICENSE"
cp "$repo/debian/secureshellgo.wrapper" "$repo/linux/com.dhivalabs.secure_shell_go.desktop" \
  "$repo/linux/secureshellgo-256.png" "$repo/packaging/flatpak/com.dhivalabs.secure_shell_go.metainfo.xml" "$work/"

# makepkg refuses to run as root, so the work directory goes to a build user
# inside the container and comes back to this user on the way out.
docker run --rm -v "$work:/build" -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
  archlinux:latest bash -euo pipefail -c '
  trap "chown -R \"\$HOST_UID:\$HOST_GID\" /build" EXIT
  pacman -Syu --noconfirm --needed -q base-devel namcap
  useradd -m builder
  chown -R builder /build
  cd /build
  su builder -c "makepkg --printsrcinfo > .SRCINFO"
  su builder -c "makepkg --noconfirm --nodeps -f"
  namcap PKGBUILD
  pacman -U --noconfirm ./*-x86_64.pkg.tar.zst
  pacman -Qlq secureshellgo-bin | grep -x /opt/secureshellgo/secure_shell_go
  [ ! -e /opt/secureshellgo/lib/libdartjni.so ]
  # Every ELF file the package installed finds its libraries (the depends
  # are complete), as in verify.sh.
  missing=0
  for f in $(pacman -Qlq secureshellgo-bin); do
    [ -f "$f" ] && [ "$(head -c 4 "$f" | od -An -tx1 | tr -d " \n")" = 7f454c46 ] || continue
    if LD_LIBRARY_PATH=/opt/secureshellgo/lib ldd "$f" | grep "not found"; then echo "in $f"; missing=1; fi
  done
  [ "$missing" = 0 ]
  cat .SRCINFO
'
tar -C "$work" -czf "$out/$NAME-bin-$VERSION-aur.tar.gz" PKGBUILD .SRCINFO
ls -l "$out/$NAME-bin-$VERSION-aur.tar.gz"
