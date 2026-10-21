### Added
- Allow legacy algorithms, a per-host switch for old routers and NAS boxes that only speak SHA-1 key exchange, `ssh-rsa` signatures or CBC ciphers. The connection error says when a host needs it.

### Changed
- Updated the SSH library (dartssh2 4.1). Weak algorithms are no longer offered unless a host has the switch above turned on.
