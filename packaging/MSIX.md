# Microsoft Store package and the AI Bridge launcher

The Windows package ships a second program, `secureshellgo-mcp.exe`, next to
`secure_shell_go.exe`. An MCP-compatible AI assistant starts it as its stdio
server; it carries bytes to the running app (see `bin/secureshellgo_mcp.dart`).
This note is about how an assistant gets to run it inside an MSIX.

## What the `msix` package can do

Checked in `msix` 3.18.0 (the version `pubspec.lock` pins), `lib/src/appx_manifest.dart`:

- `msix_config: execution_alias` exists, but it writes
  `<uap3:Extension Category="windows.appExecutionAlias" Executable="…">` with
  `Executable` set to the **main application's** executable, the one it found
  in the Release folder (`secure_shell_go.exe`). There is no setting for
  another executable, and the manifest is generated whole: no field takes
  custom XML.
- So `execution_alias: secureshellgo-mcp` would make that command start the
  **GUI app**, which is a GUI-subsystem program with no stdio. That is wrong
  for an assistant, so `msix_config` does not set it.
- `makeappx pack /d <Release folder>` packs the whole folder, so the launcher
  exe is in the package as soon as it is in
  `build\windows\<arch>\runner\Release\`. `msix:build` and `msix:create`
  only delete the files they generated themselves (manifest, `.pri`, VC++
  runtime DLLs, `Images`, `*.msix`), never other files.

## What is implemented

The package documents a manual route for features it does not support:
`dart run msix:build`, edit the files in the build folder, `dart run msix:pack`.
`tool/build_msix.ps1 [-Arch x64|arm64]` does exactly that:

1. `flutter build windows --release`
2. `tool\build_launcher.ps1` compiles the launcher into the Release folder
   as `secureshellgo-mcp.exe`.
3. `msix:build --build-windows false` generates `AppxManifest.xml`.
4. The script adds a second, hidden `<Application Id="SecureShellGoMcp"
   Executable="secureshellgo-mcp.exe">` (`AppListEntry="none"`, so no Start
   menu entry) carrying the `windows.appExecutionAlias` extension with alias
   `secureshellgo-mcp.exe`, checks the XML still parses, and writes it back.
5. `msix:pack` makes the package.

Run it in PowerShell 7 on a machine of the target architecture: neither
`flutter build windows` nor `dart compile exe` cross-compiles, so
`-Arch arm64` needs a Windows arm64 machine (the script stops if the Release
folder has no `secure_shell_go.exe`). The launcher build reads
`.dart_tool\package_config.json`, which `flutter build windows` writes.

After install the command is `secureshellgo-mcp` (the alias lives in
`%LOCALAPPDATA%\Microsoft\WindowsApps`, which is on the user's PATH). It runs
**inside the package**, so it sees the same redirected AppData as the app,
which matters: the app's `bridge\endpoint.json` is written to the package's
private AppData, not the real `%APPDATA%`.

The same alias mechanism (a second hidden `Application` for a console exe) is
what other Store packages use for command-line tools. It has **not** been run
on Windows from this repository: see `store/release-checklist-1.6.md`.

## If the alias does not work

Without the alias the launcher is still in the package, at
`C:\Program Files\WindowsApps\<package full name>\secureshellgo-mcp.exe`. That
folder name carries the version and changes on every update, and a process
started from it by full path runs **without** package identity, so it would
read the real `%APPDATA%` and not find the app's redirected one. Using it
would need the launcher to also look in
`%LOCALAPPDATA%\Packages\<package family name>\LocalCache\Roaming\…\bridge`.
That is launcher code (`lib/services/bridge/bridge_locator.dart`) and is not
done; the alias route avoids the problem.

## Notes

- The alias name `secureshellgo-mcp.exe` must be unique among Store packages
  that declare aliases; Partner Center reports a clash at submission.
- The Windows `.zip` (not MSIX) holds the same launcher; there it is started
  by full path and needs no alias, because the app and the launcher share the
  real `%APPDATA%`.
