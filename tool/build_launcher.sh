#!/bin/sh
# Builds the AI Bridge launcher (bin/secureshellgo_mcp.dart) into one native
# executable: tool/build_launcher.sh <output file>
#
# Every Linux packaging path calls this (the CI build, the snap part,
# debian/rules), so the recipe lives here once. Run it after `flutter pub
# get`: it reads the package map that writes. Why it is not just
# `dart compile exe bin/secureshellgo_mcp.dart`:
#
#  - From inside the app's package that command stops with "'dart compile'
#    does not support build hooks": the app's dependency graph includes
#    packages with build hooks (objective_c, through path_provider), and
#    `dart compile` refuses any package graph that has one.
#  - The launcher imports only dart: libraries, Flutter-free files of this
#    package and pure Dart packages such as crypto (see the comment in the
#    launcher). So it is compiled against a copy of the app's own package
#    map with every package that has a build hook left out. That copy is
#    resolved already, so there is no second `pub get` and no network, which
#    keeps the offline Launchpad build working; a launcher import that did
#    need a hook package would fail the compile here, loudly.
#  - The copy is passed with --packages and the compile runs from outside
#    the package, because the compiler would otherwise find the app's own
#    .dart_tool/package_config.json first.
#
# DART selects the compiler. Unset, it is the Dart SDK inside FLUTTER_ROOT
# when that is set, else `dart` from PATH.
set -eu

[ $# -eq 1 ] || { echo "usage: $0 <output file>" >&2; exit 2; }

root=$(cd "$(dirname "$0")/.." && pwd -P)
case "$1" in
  /*) out=$1 ;;
  *) out=$(pwd -P)/$1 ;;
esac

if [ -z "${DART:-}" ]; then
  if [ -n "${FLUTTER_ROOT:-}" ] && [ -x "$FLUTTER_ROOT/bin/cache/dart-sdk/bin/dart" ]; then
    DART=$FLUTTER_ROOT/bin/cache/dart-sdk/bin/dart
  else
    DART=dart
  fi
fi
command -v "$DART" > /dev/null 2>&1 || { echo "build_launcher: $DART not found" >&2; exit 1; }

app_config=$root/.dart_tool/package_config.json
[ -f "$app_config" ] || {
  echo "build_launcher: $app_config is missing; run flutter pub get first" >&2
  exit 1
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
trap 'exit 1' INT TERM

# Copies the app's package map without the build-hook packages, with every
# rootUri made absolute (the app's map has relative ones, such as "../" for
# the app itself, which would point elsewhere from the new file's folder).
cat > "$work/filter.dart" <<'DART'
import 'dart:convert';
import 'dart:io';

void main(List<String> args) {
  final source = File(args[0]).absolute;
  final config = jsonDecode(source.readAsStringSync()) as Map<String, dynamic>;
  final kept = <Map<String, dynamic>>[];
  for (final package in (config['packages'] as List).cast<Map<String, dynamic>>()) {
    var root = source.uri.resolve(package['rootUri'] as String);
    if (!root.path.endsWith('/')) root = root.replace(path: '${root.path}/');
    if (File.fromUri(root.resolve('hook/build.dart')).existsSync()) {
      stderr.writeln('build_launcher: leaving out ${package['name']} (build hook)');
      continue;
    }
    kept.add({...package, 'rootUri': root.toString()});
  }
  File(args[1]).writeAsStringSync(
      jsonEncode({'configVersion': config['configVersion'], 'packages': kept}));
}
DART

mkdir -p "$(dirname "$out")"
export DART_SUPPRESS_ANALYTICS=true
cd "$work"
"$DART" "$work/filter.dart" "$app_config" "$work/launcher_packages.json"
"$DART" compile exe --packages="$work/launcher_packages.json" \
  -o "$out" "$root/bin/secureshellgo_mcp.dart"
