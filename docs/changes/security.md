### Security
- On Android, the app lock stays shut when the device cannot show its unlock prompt, instead of letting the app open.
- On Windows, opening a downloaded file no longer goes through `cmd`, so a crafted file name cannot run a command.
- An RSA host key is recognised as the same key whichever signature algorithm the server uses with it, instead of being treated as a new or changed key.
- A direct server-to-server copy only goes ahead when the destination presents the host key this device already trusts.
- A locked system keyring no longer wipes the list of trusted host keys.
- Saved hosts, settings and trusted keys are written atomically and in order. A file that cannot be read is set aside, not overwritten.
- Replacing a file on upload writes the new copy first and swaps it in, so a failed upload no longer leaves the old file destroyed.
- A backup that demands an unreasonable amount of key-derivation work is refused instead of freezing the app.
