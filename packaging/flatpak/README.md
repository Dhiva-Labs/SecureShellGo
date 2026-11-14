# Flatpak

`com.dhivalabs.secure_shell_go.yml` packages the same files as the `.rpm`,
the Arch package and the AppImage: the installed tree that
`packaging/linux-distros/tree.sh` lays out from the release tarball. It does
not rebuild the app inside the sandbox; GTK 3 and libsecret come from the
GNOME 51 runtime.

## How CI builds it

The `flatpak` job in `.github/workflows/desktop-builds.yml` runs on x86_64
and aarch64 in the `ghcr.io/flathub-infra/flatpak-github-actions:gnome-51`
image. It unpacks the tree the `distros` job made into
`packaging/flatpak/tree/` (git-ignored) and builds the manifest and the
bundle `secureshellgo-<version>-<arch>.flatpak`. The `flatpak-run` job then
installs the bundle on a plain Ubuntu runner, with the runtime from Flathub
as a user would, checks every ELF file with `ldd` inside the sandbox, and
starts the app under Xvfb until its window and its data folder (in
`~/.var/app/com.dhivalabs.secure_shell_go`) appear
(`packaging/linux-distros/smoke.sh`, the same check as for the other
formats). The builder image is not used for that run: GTK gets no GL context
under its Xvfb, so Flutter never draws a first frame there.

Install a bundle with (the GNOME 51 runtime comes from Flathub):

```sh
flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install --user ./secureshellgo-<version>-x86_64.flatpak
flatpak run com.dhivalabs.secure_shell_go
```

The bundles are not signed and do not update themselves.

## What the sandbox allows

| Permission | Why |
|---|---|
| `--share=network` | SSH, SFTP, Mosh and port forwards |
| `--talk-name=org.freedesktop.secrets` | saved passwords, keys and passphrases go to the desktop's Secret Service (GNOME Keyring, KWallet, KeePassXC) |
| `--socket=ssh-auth` | keys held in your SSH agent |
| `--filesystem=~/.ssh:ro` | "Import from ~/.ssh/config" reads that file and what it includes |
| `--filesystem=xdg-download` | SFTP downloads go straight into Downloads |
| `--socket=wayland`, `--socket=x11` | the window; X11 also for "Open an app in a window" (X11 forwarding), which draws the server's programs on the local X server (Xwayland on a Wayland desktop) |

Uploads and "save as" go through the desktop's file chooser portal, so they
reach any folder you pick without a wider grant.

X11 forwarding asks the local X server for an untrusted cookie with `xauth`.
Where the sandbox has no `xauth`, the app falls back to the trusted mode (as
`ssh -Y` does) and says so at the top of the shell.

## The AI Bridge launcher

The tree holds the launcher, `secureshellgo-mcp`, beside the app. The
manifest installs it from a module of its own, `secureshellgo-mcp`, with
`build-options: { no-debuginfo: true, strip: false }`: flatpak-builder's
default debuginfo step strips every ELF file a module installs, and stripping
a `dart compile exe` binary cuts off the program appended to it (what is left
only prints the Dart VM's usage). The app module keeps the default. The
launcher ends up at `/app/lib/secureshellgo/secureshellgo-mcp`, with
`/app/bin/secureshellgo-mcp` linking to it.

An AI assistant runs on the host, so it needs a host command. The app shows
the one Flatpak exports for every installed app,
`<installation>/exports/bin/com.dhivalabs.secure_shell_go`
(`/var/lib/flatpak/...` for a system install, `~/.local/share/flatpak/...`
for `--user`; the app reads which from `/.flatpak-info`). That runs the app's
main command, `/app/bin/secureshellgo`, a script that starts the launcher
instead of the app when `SSG_BRIDGE_TOKEN` is set and stdin is not a
terminal, which is how every assistant starts it (`flatpak run` passes the
variable into the sandbox). This keeps it one command with no arguments,
which is all the Claude Code plugin's `launcher` setting takes. A client that
takes arguments can instead run `flatpak run --command=secureshellgo-mcp
com.dhivalabs.secure_shell_go`.

The launcher runs in a new sandbox instance of the same app. It finds the
app's `endpoint.json` because both resolve the same data directory
(`XDG_DATA_HOME` is `~/.var/app/com.dhivalabs.secure_shell_go/data` in every
instance). The socket is not placed in the plain `XDG_RUNTIME_DIR`, which
Flatpak makes private to each instance: the bridge directory under
`~/.var/app/…` is usually past the socket-path limit, and the fallback inside
a Flatpak is `$XDG_RUNTIME_DIR/app/com.dhivalabs.secure_shell_go/`, which
Flatpak shares between all instances of the app (and with the host).

"Connect Claude Code" is not offered: a Flatpak cannot start the host's
`claude` program. The app shows a note pointing to "Connect an assistant"
instead, as in the snap.

CI (`flatpak-run`) runs `ldd` on the launcher inside the sandbox and starts
it both ways, with the app not running: each must answer one `initialize`
request with a JSON-RPC error and exit 1.

## Submitting to Flathub

Flathub builds from a manifest in its own repository and from published
sources only, so a submission differs from this file in one place: the
`tree` directory source becomes the release tarballs (`type: archive`, one
per architecture with `only-arches`, sha256 from the release) plus
`linux/com.dhivalabs.secure_shell_go.desktop`, `linux/secureshellgo-256.png`
and the metainfo file as `type: file` sources, and the build commands remove
`lib/libdartjni.so` as `tree.sh` and `pack.sh` do. The launcher module then
takes `secureshellgo-mcp` from the same archive, still with
`no-debuginfo: true`. Reviewers will look at
`--socket=x11` next to Wayland (X11 forwarding) and expect `<screenshots>` in
the metainfo file, which has none yet. The submission (a PR to
`flathub/flathub`) needs a Flathub account and is not automated here.
