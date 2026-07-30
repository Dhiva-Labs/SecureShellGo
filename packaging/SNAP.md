# Publishing SecureShell Go to the Snap Store

This document is for whoever holds (or will create) the Snap Store / Ubuntu
One account for Dhiva Labs. Registering a name and uploading a release both
need an interactive login — no automated agent can complete those steps.

## 1. Install snapcraft

```bash
sudo snap install snapcraft --classic
```

Already present on this machine (version 9.0.1) if you're reading this from
the same environment the packaging was built in.

## 2. One-time: register the snap name

```bash
snapcraft register secureshellgo
```

This prompts for your Ubuntu SSO / Snap Store account credentials (creating
one first at <https://login.ubuntu.com> if you don't have one) and reserves
the name globally on the Snap Store.

**If the name is taken:** register `secure-shell-go` instead, then update
`snap/snapcraft.yaml`'s top-level `name:` field to match (the `title:`,
which is what's actually displayed as "SecureShell Go" in the Snap Store
and app grid, does not need to change), and update the install command in
`README.md`'s "Install via snap" section and the command below in step 6.

## 3. One-time: log in

```bash
snapcraft login
```

Also Ubuntu SSO; this one may send a confirmation email the first time.

## 4. Build the snap

From the repository root (`/home/dhivakar/dhiva-labs/secure_shell_go`):

```bash
snapcraft --destructive-mode
```

This builds directly on the host — see "Local verification" below for what
this actually requires and why `--use-lxd` was needed here instead. It
produces `secureshellgo_1.2.0_amd64.snap` in the repo root.

## 5. Upload and release

```bash
snapcraft upload --release=stable ./secureshellgo_1.2.0_amd64.snap
```

This uploads the snap and releases it directly to the `stable` channel. If
you'd rather soak it first, drop `--release=stable` and promote manually
after testing:

```bash
snapcraft upload ./secureshellgo_1.2.0_amd64.snap
snapcraft release secureshellgo <revision> stable
```

(`snapcraft status secureshellgo` shows the revision number once the upload
finishes processing.)

## 6. Once published: user install command

```bash
sudo snap install secureshellgo
```

This works out of the box on Ubuntu, and on Fedora, Arch, Manjaro, and any
other distro with `snapd` installed — unlike the `.deb` (Launchpad PPA)
track, which is Ubuntu/`apt`-only.

## Local verification

The `snap/snapcraft.yaml` here has been structurally reviewed and follows
the current core22 + `flutter` plugin conventions, but an end-to-end
`snapcraft` run has NOT been executed in this environment yet — the
first-run build (SDK snap install + Flutter git clone + full C++ engine
compile) takes 20–40 minutes and needs a human to type a sudo password
(see below). The first real signal comes from your build. Two things
worth knowing when you run it:

### `--destructive-mode` needs a build-time snap install, which needs root

`snap/snapcraft.yaml` uses the `gnome` extension (see the comment block at
the top of that file for why, and why the "flutter-stable" extension named
in the Snap Store's own Flutter-application docs no longer exists on
current snapcraft). That extension's build step needs the
`gnome-42-2204-sdk` snap installed on the *build* machine. `snapcraft
--destructive-mode` shells out to `snap install gnome-42-2204-sdk` itself,
and plain `snap install` always needs root — there's no unprivileged path
around it, and no automated agent can type a sudo password. On a machine
where you (a human, with sudo) run the build interactively, this is a
non-issue: sudo will simply prompt you once.

If you hit `Error installing snap 'gnome-42-2204-sdk'` running
`--destructive-mode` non-interactively, either:

- Pre-install it yourself first: `sudo snap install gnome-42-2204-sdk`,
  then re-run `snapcraft --destructive-mode`; or
- Use `snapcraft --use-lxd` instead (see below) — inside the LXD container,
  snapcraft's build steps run as the container's own root, so no host sudo
  prompt is needed at all. This is what was actually used to produce the
  verified build referenced below.

### Recommended build command

```bash
snapcraft --use-lxd
```

`--use-lxd` launches a throwaway LXD container (this machine already has
LXD initialized and the user in the `lxd` group), and inside it:
installs build-packages via apt, clones the Flutter SDK from
`https://github.com/flutter/flutter.git` (the `flutter` craft-parts
plugin's own mechanism — not the `storage.googleapis.com` tarball the
PPA build uses, so this route isn't affected by whatever is blocking
Launchpad's builders), runs `flutter build linux --release`, then stages
the GTK3/libsecret/OpenSSL runtime libraries and assembles the `.snap`.

Expect the first run to take a while (shallow Flutter SDK clone plus a
full C++ engine/runner compile) — the resulting instance is reused on
subsequent runs unless you pass `--debug` cleanup flags or destroy it
manually, so later rebuilds are much faster.

To test-install the result without publishing anything:

```bash
snap install --dangerous ./secureshellgo_1.2.0_amd64.snap
secureshellgo &   # or launch "SecureShell Go" from the app grid
sudo snap remove secureshellgo   # clean up afterwards
```

`--dangerous` is required for a locally-built, unsigned `.snap`; it's not
needed once the snap is installed normally from the Store.
