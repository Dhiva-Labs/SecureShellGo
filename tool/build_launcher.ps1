# Builds the AI Bridge launcher (bin\secureshellgo_mcp.dart) into one native
# executable: tool\build_launcher.ps1 <output file>
#
# The Windows twin of tool/build_launcher.sh; read the comment there for why
# the launcher is compiled against a copy of the app's package map without
# the build-hook packages, in a temporary package of its own (entry script
# and .dart_tool\package_config.json both there), instead of with a plain
# `dart compile exe`. Run it after `flutter pub get`.
#
# DART selects the compiler. Unset, it is the Dart SDK inside FLUTTER_ROOT
# when that is set, else `dart` from PATH; when that is Flutter's
# bin\dart(.bat) wrapper, the SDK's own dart.exe beside it is used instead.
param([Parameter(Mandatory = $true)][string]$Output)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$out = [IO.Path]::GetFullPath($Output, (Get-Location).Path)

$dart = 'dart'
if ($env:DART) {
  $dart = $env:DART
} elseif ($env:FLUTTER_ROOT -and (Test-Path -LiteralPath (Join-Path $env:FLUTTER_ROOT 'bin\cache\dart-sdk\bin\dart.exe'))) {
  $dart = Join-Path $env:FLUTTER_ROOT 'bin\cache\dart-sdk\bin\dart.exe'
} else {
  $found = Get-Command dart -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($found) {
    $bin = Split-Path -Parent $found.Source
    $sdkDart = Join-Path $bin 'cache\dart-sdk\bin\dart.exe'
    $isWrapper = (Test-Path -LiteralPath (Join-Path $bin 'flutter.bat')) -or (Test-Path -LiteralPath (Join-Path $bin 'flutter'))
    if ($isWrapper -and (Test-Path -LiteralPath $sdkDart)) { $dart = $sdkDart }
  }
}
if (-not (Get-Command $dart -ErrorAction SilentlyContinue)) {
  throw "build_launcher: $dart not found"
}

$appConfig = Join-Path $root '.dart_tool\package_config.json'
if (-not (Test-Path -LiteralPath $appConfig)) {
  throw "build_launcher: $appConfig is missing; run flutter pub get first"
}

$work = Join-Path ([IO.Path]::GetTempPath()) ("ssg-launcher-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
try {
  # rootUris are made absolute: the app's map has relative ones, such as
  # "../" for the app itself, which would point elsewhere from $work.
  $base = [Uri]$appConfig
  $source = Get-Content -Raw -LiteralPath $appConfig | ConvertFrom-Json
  $kept = @()
  foreach ($package in $source.packages) {
    $packageRoot = [Uri]::new($base, [string]$package.rootUri)
    if (-not $packageRoot.AbsoluteUri.EndsWith('/')) { $packageRoot = [Uri]($packageRoot.AbsoluteUri + '/') }
    if (Test-Path -LiteralPath ([Uri]::new($packageRoot, 'hook/build.dart')).LocalPath) {
      Write-Host "build_launcher: leaving out $($package.name) (build hook)"
      continue
    }
    $package.rootUri = $packageRoot.AbsoluteUri
    $kept += $package
  }
  # The temporary package: newer Dart SDKs look for build hooks through the
  # package config nearest to the entry script, whatever --packages says,
  # so both live here (see tool/build_launcher.sh). No pubspec.yaml.
  $pkg = Join-Path $work 'pkg'
  $toolDir = Join-Path $pkg '.dart_tool'
  New-Item -ItemType Directory -Force -Path $toolDir, (Join-Path $pkg 'bin') | Out-Null
  $utf8 = New-Object Text.UTF8Encoding($false)   # no BOM: Dart rejects one
  $config = [ordered]@{
    configVersion = $source.configVersion
    packages = $kept
  } | ConvertTo-Json -Depth 5
  $configPath = Join-Path $toolDir 'package_config.json'
  [IO.File]::WriteAllText($configPath, $config, $utf8)

  # The app's package graph, without the left-out packages or edges to them.
  $graphPath = Join-Path $root '.dart_tool\package_graph.json'
  if (Test-Path -LiteralPath $graphPath) {
    $dropped = @($source.packages | Where-Object { $kept.name -notcontains $_.name } | ForEach-Object name)
    $graph = Get-Content -Raw -LiteralPath $graphPath | ConvertFrom-Json
    $graph.packages = @($graph.packages | Where-Object { $dropped -notcontains $_.name } | ForEach-Object {
      foreach ($key in 'dependencies', 'devDependencies') {
        if ($_.PSObject.Properties[$key]) { $_.$key = @($_.$key | Where-Object { $dropped -notcontains $_ }) }
      }
      $_
    })
    $graph.roots = @($graph.roots | Where-Object { $dropped -notcontains $_ })
    [IO.File]::WriteAllText((Join-Path $toolDir 'package_graph.json'), ($graph | ConvertTo-Json -Depth 6), $utf8)
  }
  $entry = Join-Path $pkg 'bin\secureshellgo_mcp.dart'
  Copy-Item -LiteralPath (Join-Path $root 'bin\secureshellgo_mcp.dart') -Destination $entry

  New-Item -ItemType Directory -Force -Path (Split-Path $out) | Out-Null
  $env:DART_SUPPRESS_ANALYTICS = 'true'
  Push-Location $pkg
  try {
    & $dart compile exe "--packages=$configPath" -o $out $entry
    if ($LASTEXITCODE -ne 0) { throw "dart compile exe failed with exit code $LASTEXITCODE" }
  } finally { Pop-Location }
} finally {
  Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
