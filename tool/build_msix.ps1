# Builds the Microsoft Store package, with the AI Bridge launcher inside it
# and an app execution alias for it: tool\build_msix.ps1 [-Arch x64|arm64]
#
# `dart run msix:create` alone would ship a package without the launcher's
# alias. The msix package can only alias the main executable (its manifest
# generator writes the alias with the app's own `Executable`), so this
# runs the package's documented manual route instead: `msix:build`, edit the
# generated AppxManifest.xml, `msix:pack`. See packaging/MSIX.md.
#
# Needs PowerShell 7 (build_launcher.ps1 does) and a machine of the target
# architecture: neither `flutter build windows` nor `dart compile exe`
# cross-compiles, so -Arch arm64 only works on a Windows arm64 machine.
param([ValidateSet('x64', 'arm64')][string]$Arch = 'x64')
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

# PowerShell before 7.3 ignores the preference above, so every native step
# is checked here as well.
function Invoke-Step([string]$What, [scriptblock]$Step) {
  & $Step
  if ($LASTEXITCODE -ne 0) { throw "$What failed with exit code $LASTEXITCODE" }
}

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location $root
$release = Join-Path $root "build\windows\$Arch\runner\Release"
$aliasExe = 'secureshellgo-mcp.exe'

Invoke-Step 'flutter build windows' { flutter build windows --release }
# Without this, a build for the other architecture would leave $release
# holding only the launcher, and msix:build would accept it (it only looks
# for "an .exe") and pack a package without the app.
if (-not (Test-Path -LiteralPath (Join-Path $release 'secure_shell_go.exe'))) {
  throw "no secure_shell_go.exe in $release; build on a $Arch machine"
}
& (Join-Path $PSScriptRoot 'build_launcher.ps1') (Join-Path $release $aliasExe)

# Not rebuilt by msix:build (flutter already did it above), so the launcher
# stays in the folder msix:pack packs.
Invoke-Step 'msix:build' { dart run msix:build --build-windows false --architecture $Arch }

$manifestPath = Join-Path $release 'AppxManifest.xml'
$manifest = [IO.File]::ReadAllText($manifestPath)
if ($manifest.Contains($aliasExe)) { throw "$manifestPath already mentions $aliasExe" }
if (-not $manifest.Contains('</Applications>')) { throw "no </Applications> in $manifestPath" }

# A second, hidden application whose only job is the alias: AppListEntry
# none keeps it out of the Start menu, and the alias runs the console
# launcher inside the package, so it sees the same redirected AppData as the
# app. The logo files are the ones msix:build already wrote.
$launcherApp = @"
      <Application Id="SecureShellGoMcp" Executable="$aliasExe" EntryPoint="Windows.FullTrustApplication">
        <uap:VisualElements BackgroundColor="transparent" DisplayName="SecureShell Go AI Bridge" Square150x150Logo="Images\Square150x150Logo.png" Square44x44Logo="Images\Square44x44Logo.png" Description="Connects an AI assistant to SecureShell Go" AppListEntry="none" />
        <Extensions>
          <uap3:Extension Category="windows.appExecutionAlias" Executable="$aliasExe" EntryPoint="Windows.FullTrustApplication">
            <uap3:AppExecutionAlias>
              <desktop:ExecutionAlias Alias="$aliasExe" />
            </uap3:AppExecutionAlias>
          </uap3:Extension>
        </Extensions>
      </Application>
    </Applications>
"@
$manifest = $manifest.Replace('</Applications>', $launcherApp)
$null = [xml]$manifest   # well-formedness check before it is packed
[IO.File]::WriteAllText($manifestPath, $manifest, (New-Object Text.UTF8Encoding($false)))

Invoke-Step 'msix:pack' { dart run msix:pack --architecture $Arch }
