### Added
- Sign in with your computer's SSH agent (ssh-agent, Pageant or the Windows OpenSSH agent) on Linux and Windows, including FIDO2 security keys such as a YubiKey (`sk-ed25519`, `sk-ecdsa`). The private key never leaves the agent.
- SSH certificates: load a `-cert.pub` file or paste one in the host's sign-in settings, for servers that trust a certificate authority. The host shows the certificate's key ID, the users it is valid for and when it expires, and says clearly when it is for a different key, is a host certificate, or has expired.
- Forward SSH agent, per host: `git` and `ssh` in the shell can use the keys in your computer's agent and the host's own key, without copying them to the server. Stats, logs and other server actions keep working on the same connection.
- Forward X11, per host, on Linux and Windows: graphical programs started on the server open their windows on your screen (needs an X server, such as VcXsrv or X410 on Windows). The server is given a stand-in cookie, never your display's real one.
- Importing from `~/.ssh/config` now brings in `ForwardAgent`, `ForwardX11` and `CertificateFile`, and finds a certificate saved next to an `IdentityFile` the way `ssh` does.

### Changed
- When a server refuses agent or X11 forwarding, the shell still opens, with a line at the top saying what was refused and why it might be.
- On a phone-width window the sign-in choice shows as Password, Private key and Agent, without icons, so all three fit.
