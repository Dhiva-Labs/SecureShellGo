#!/usr/bin/env bash
# Stage CrossShell's remote-desktop agents into assets/agents/ and rewrite
# assets/agents/manifest.json from them.
#
#   tool/stage_agents.sh [DIR]
#
# DIR is a CrossShell `dist/agents` folder (scripts/build-agents.sh there
# makes one), default ../cross_shell/dist/agents. Every file DIR's
# SHA256SUMS lists is checked against it first, then copied; files that are
# not agents this app knows are skipped with a warning, and agents a build
# leaves out (linux-aarch64 full is built on CI only) are simply absent from
# the manifest — the app then falls back or says that flavour is missing.
#
# The binaries are gitignored and the manifest is committed: the hashes the
# app checks every launch against are reviewed source, not build output.
#
# The engine version comes from CROSSSHELL_ENGINE_VERSION, or else from the
# CrossShell workspace's engine/Cargo.toml beside DIR. For the full Linux
# builds the newest GLIBC_ symbol version they need is read with objdump or
# readelf, so the app can refuse a server whose glibc is older.
#
# STAGE_AGENTS_OUT overrides the output folder (the live tests stage into a
# temporary one).
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
src=${1:-$root/../cross_shell/dist/agents}
out=${STAGE_AGENTS_OUT:-$root/assets/agents}

die() { echo "stage_agents: $*" >&2; exit 1; }

[ -d "$src" ] || die "no agent folder at $src"
[ -f "$src/SHA256SUMS" ] || die "$src has no SHA256SUMS"
src=$(cd "$src" && pwd)

engine=${CROSSSHELL_ENGINE_VERSION:-}
if [ -z "$engine" ]; then
  cargo="$src/../../engine/Cargo.toml"
  [ -f "$cargo" ] || die "set CROSSSHELL_ENGINE_VERSION (no $cargo to read it from)"
  engine=$(sed -n '/^\[workspace.package\]/,/^\[/s/^version *= *"\([^"]*\)".*/\1/p' "$cargo" | head -n 1)
  [ -n "$engine" ] || die "no [workspace.package] version in $cargo"
fi
case "$engine" in *[!0-9A-Za-z.+-]*) die "odd engine version: $engine" ;; esac

(cd "$src" && sha256sum --check --quiet SHA256SUMS) || die "SHA256SUMS does not match $src"

glibc_of() {
  local f=$1 v=
  if command -v objdump > /dev/null; then
    v=$(objdump -T "$f" | grep -o 'GLIBC_[0-9.]*' | sed 's/GLIBC_//' | sort -uV | tail -n 1)
  elif command -v readelf > /dev/null; then
    v=$(readelf -V "$f" | grep -o 'GLIBC_[0-9.]*' | sed 's/GLIBC_//' | sort -uV | tail -n 1)
  else
    die "need objdump or readelf to read the glibc requirement of $f"
  fi
  [ -n "$v" ] || die "no GLIBC_ symbols in $f"
  # Only major.minor matters: glibc never removes a symbol version.
  echo "$v" | cut -d. -f1-2
}

mkdir -p "$out"
entries=()
staged=()
while read -r hash name; do
  name=${name#\*}
  glibc=
  case "$name" in
    crossshell-host-linux-x86_64) os=linux arch=x86_64 flavour=full ;;
    crossshell-host-linux-x86_64-x11) os=linux arch=x86_64 flavour=x11 ;;
    crossshell-host-linux-aarch64) os=linux arch=aarch64 flavour=full ;;
    crossshell-host-linux-aarch64-x11) os=linux arch=aarch64 flavour=x11 ;;
    crossshell-host-windows-x64.exe) os=windows arch=x86_64 flavour=full ;;
    crossshell-host-windows-arm64.exe) os=windows arch=aarch64 flavour=full ;;
    *) echo "stage_agents: skipping $name (not an agent this app knows)" >&2; continue ;;
  esac
  case "$hash" in *[!0-9a-f]* | '') die "bad hash for $name" ;; esac
  [ ${#hash} -eq 64 ] || die "bad hash for $name"
  if [ "$os" = linux ] && [ "$flavour" = full ]; then glibc=$(glibc_of "$src/$name"); fi
  size=$(wc -c < "$src/$name" | tr -d ' ')
  # Gzipped: about 15 MB of agents become about 6 in every install. The
  # manifest keeps the binary's own hash and size, which the app checks
  # after unpacking. -n keeps the output reproducible (no name or time).
  gzip -9n -c "$src/$name" > "$out/$name.gz.tmp"
  mv -f "$out/$name.gz.tmp" "$out/$name.gz"
  staged+=("$name.gz")
  entry=$(printf '    {"file": "%s", "os": "%s", "arch": "%s", "flavour": "%s", "sha256": "%s", "size": %s' \
    "$name" "$os" "$arch" "$flavour" "$hash" "$size")
  [ -n "$glibc" ] && entry="$entry, \"glibc\": \"$glibc\""
  entries+=("$entry}")
  echo "staged $name ($os $arch $flavour${glibc:+, glibc >= $glibc})"
done < "$src/SHA256SUMS"

[ ${#entries[@]} -gt 0 ] || die "SHA256SUMS lists no agents"

# Binaries from an earlier staging that this one does not have.
for f in "$out"/crossshell-host-*; do
  [ -e "$f" ] || continue
  keep=0
  for s in "${staged[@]}"; do [ "$(basename "$f")" = "$s" ] && keep=1; done
  [ $keep = 1 ] || { rm -f "$f"; echo "removed stale $(basename "$f")"; }
done

{
  printf '{\n  "v": 1,\n  "engine": "%s",\n  "agents": [\n' "$engine"
  for i in "${!entries[@]}"; do
    if [ "$i" -lt $((${#entries[@]} - 1)) ]; then printf '%s,\n' "${entries[$i]}"; else printf '%s\n' "${entries[$i]}"; fi
  done
  printf '  ]\n}\n'
} > "$out/manifest.json.tmp"
mv -f "$out/manifest.json.tmp" "$out/manifest.json"
echo "wrote $out/manifest.json (engine $engine, ${#entries[@]} agents)"
