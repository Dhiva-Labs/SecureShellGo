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

## Submitting to Flathub

Flathub builds from a manifest in its own repository and from published
sources only, so a submission differs from this file in one place: the
`tree` directory source becomes the release tarballs (`type: archive`, one
per architecture with `only-arches`, sha256 from the release) plus
`linux/com.dhivalabs.secure_shell_go.desktop`, `linux/secureshellgo-256.png`
and the metainfo file as `type: file` sources, and the build commands remove
`lib/libdartjni.so` as `tree.sh` and `pack.sh` do. Reviewers will look at
`--socket=x11` next to Wayland (X11 forwarding) and expect `<screenshots>` in
the metainfo file, which has none yet. The submission (a PR to
`flathub/flathub`) needs a Flathub account and is not automated here.
