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
#  - The compile runs in a temporary package of its own, not just with
#    --packages: newer Dart SDKs (the snap's Flutter `stable` failed this
#    way while 3.12.2 did not) look for build hooks through the package
#    config nearest to the entry script, whatever --packages says, and the
#    entry script's own folder is inside the app's package. So the entry
#    script is copied to <tmp>/bin/, the filtered map is written as
#    <tmp>/.dart_tool/package_config.json, with a package_graph.json beside
#    it, filtered the same way, and passed with --packages as well. The
#    nearest package config to the working directory and to the entry
#    script is then the filtered one, and nothing in <tmp> names the app's
#    package root except `secure_shell_go` itself (rootUri the repository,
#    packageUri lib/), which the launcher imports and which has no hook.
#    There is no pubspec.yaml in <tmp>, so no workspace is found either.
#
# DART selects the compiler. Unset, it is the Dart SDK inside FLUTTER_ROOT
# when that is set, else `dart` from PATH; when that `dart` is Flutter's
# bin/dart wrapper script (a `flutter` beside it and the SDK in
# bin/cache/dart-sdk), the SDK's own binary is used instead.
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
    # Flutter's bin/dart is a wrapper script that may update or re-run the
    # flutter tool; the SDK binary it ends in does the same compile without
    # it. readlink -f follows a symlinked bin/dart (as a snap or a package
    # manager may install it).
    found=$(command -v dart 2> /dev/null || true)
    if [ -n "$found" ]; then
      real=$(readlink -f "$found" 2> /dev/null || printf '%s' "$found")
      bin=$(dirname "$real")
      if [ -x "$bin/flutter" ] && [ -x "$bin/cache/dart-sdk/bin/dart" ]; then
        DART=$bin/cache/dart-sdk/bin/dart
      fi
    fi
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

# Writes the temporary package's .dart_tool: the app's package map without
# the build-hook packages, with every rootUri made absolute (the app's map
# has relative ones, such as "../" for the app itself, which would point
# elsewhere from the new folder), and the app's package_graph.json, when it
# has one, without those packages and without any edge to them.
cat > "$work/filter.dart" <<'DART'
import 'dart:convert';
import 'dart:io';

void main(List<String> args) {
  final source = File(args[0]).absolute;
  final outDir = args[1];
  final config = jsonDecode(source.readAsStringSync()) as Map<String, dynamic>;
  final kept = <Map<String, dynamic>>[];
  final dropped = <String>{};
  for (final package in (config['packages'] as List).cast<Map<String, dynamic>>()) {
    var root = source.uri.resolve(package['rootUri'] as String);
    if (!root.path.endsWith('/')) root = root.replace(path: '${root.path}/');
    if (File.fromUri(root.resolve('hook/build.dart')).existsSync()) {
      stderr.writeln('build_launcher: leaving out ${package['name']} (build hook)');
      dropped.add(package['name'] as String);
      continue;
    }
    kept.add({...package, 'rootUri': root.toString()});
  }
  File('$outDir/package_config.json').writeAsStringSync(
      jsonEncode({'configVersion': config['configVersion'], 'packages': kept}));

  final graphFile = File.fromUri(source.uri.resolve('package_graph.json'));
  if (!graphFile.existsSync()) return;
  final graph = jsonDecode(graphFile.readAsStringSync()) as Map<String, dynamic>;
  List<dynamic>? without(Object? names) =>
      names is List ? [for (final n in names) if (!dropped.contains(n)) n] : null;
  final packages = [
    for (final p in (graph['packages'] as List).cast<Map<String, dynamic>>())
      if (!dropped.contains(p['name']))
        {
          for (final e in p.entries)
            e.key: (e.key == 'dependencies' || e.key == 'devDependencies')
                ? without(e.value)
                : e.value,
        },
  ];
  File('$outDir/package_graph.json').writeAsStringSync(jsonEncode({
    ...graph,
    'roots': without(graph['roots']) ?? const [],
    'packages': packages,
  }));
}
DART

mkdir -p "$(dirname "$out")"
export DART_SUPPRESS_ANALYTICS=true
cd "$work"
# filter.dart stays outside the temporary package; it imports only dart:.
mkdir -p "$work/pkg/.dart_tool" "$work/pkg/bin"
"$DART" "$work/filter.dart" "$app_config" "$work/pkg/.dart_tool"
cp "$root/bin/secureshellgo_mcp.dart" "$work/pkg/bin/secureshellgo_mcp.dart"
cd "$work/pkg"
"$DART" compile exe --packages="$work/pkg/.dart_tool/package_config.json" \
  -o "$out" "$work/pkg/bin/secureshellgo_mcp.dart"
