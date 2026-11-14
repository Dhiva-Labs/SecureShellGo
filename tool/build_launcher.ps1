# Builds the AI Bridge launcher (bin\secureshellgo_mcp.dart) into one native
# executable: tool\build_launcher.ps1 <output file>
#
# The Windows twin of tool/build_launcher.sh; read the comment there for why
# the launcher is compiled against a copy of the app's package map without
# the build-hook packages, from outside the package, instead of with a plain
# `dart compile exe`. Run it after `flutter pub get`.
param([Parameter(Mandatory = $true)][string]$Output)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$out = [IO.Path]::GetFullPath($Output, (Get-Location).Path)

$dart = 'dart'
if ($env:DART) { $dart = $env:DART }

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
  $config = [ordered]@{
    configVersion = $source.configVersion
    packages = $kept
  } | ConvertTo-Json -Depth 5
  $configPath = Join-Path $work 'launcher_packages.json'
  # No BOM: the Dart package-config reader rejects one.
  [IO.File]::WriteAllText($configPath, $config, (New-Object Text.UTF8Encoding($false)))

  New-Item -ItemType Directory -Force -Path (Split-Path $out) | Out-Null
  $env:DART_SUPPRESS_ANALYTICS = 'true'
  Push-Location $work
  try {
    & $dart compile exe "--packages=$configPath" -o $out (Join-Path $root 'bin\secureshellgo_mcp.dart')
    if ($LASTEXITCODE -ne 0) { throw "dart compile exe failed with exit code $LASTEXITCODE" }
  } finally { Pop-Location }
} finally {
  Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
