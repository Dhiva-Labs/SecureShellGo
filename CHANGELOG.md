# Changelog

Releases before 1.4.5 are described on the
[Releases](https://github.com/Dhiva-Labs/SecureShellGo/releases) page.

## 1.4.5 - 2026-10-16

### Added
- Linux arm64 and Windows arm64 builds: `SecureShellGo-linux-arm64.tar.gz` and `SecureShellGo-windows-arm64.zip`, built natively on ARM64 runners and started once there to check that they run.
- An arm64 snap next to the amd64 one. CI builds both, installs each under confinement and starts it on its own architecture.

### Changed
- `jni` (a transitive dependency of the Android secure-storage plugin) is locked at 1.0.3, which compiles on Linux arm64.
- `debian/rules` no longer hard-codes the x64 Flutter bundle folder. The PPA package is still amd64 only.
- CI runs the tests on Linux x64 and arm64 and on Windows x64 and arm64. Four test files that assume Linux (POSIX paths and file modes, the Linux "connection refused" text, a UTF-8 shell) are skipped on Windows.

No application code changed since 1.4.4.
