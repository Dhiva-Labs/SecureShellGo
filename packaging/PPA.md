# Publishing SecureShell Go to a Launchpad PPA

This document is for whoever holds the Dhiva Labs GPG key and Launchpad
account. It covers everything from creating the PPA to uploading a new
source package. None of these steps can be done by an automated agent —
they need your private GPG key and your Launchpad login.

## 1. One-time account and PPA setup

1. Create a Launchpad account at <https://launchpad.net> if you don't have
   one, and sign the
   [Code of Conduct](https://launchpad.net/codeofconduct) (required before
   you can upload packages).
2. Activate a PPA:
   - If publishing under a `Dhiva Labs` Launchpad team, create the team
     first, then activate the PPA at
     `https://launchpad.net/~dhiva-labs/+activate-ppa`.
   - If publishing under your personal account instead, use
     `https://launchpad.net/~dhivakar1010/+activate-ppa` (adjust the
     commands below to match whichever name you actually use — the
     `dput` target and `add-apt-repository` line both need to agree with
     it).
   - Name the PPA `secureshellgo` so the final install command matches the
     one in `README.md`.
3. Upload your GPG public key to your Launchpad account
   (`Account` → `OpenPGP keys`) and complete the encrypted-email
   confirmation loop Launchpad sends you (decrypt the email it sends with
   `gpg --decrypt` and follow the confirmation link inside).

## 2. Local GPG and dput setup

Find your key ID:

```bash
gpg --list-secret-keys --keyid-format=long
```

Look for the line like `sec   rsa4096/ABCDEF1234567890` — `ABCDEF1234567890`
is `<KEYID>` in the commands below.

Add a stanza to `~/.dput.cf` (create the file if it doesn't exist):

```ini
[dhiva-ppa]
fqdn = ppa.launchpad.net
method = ftp
incoming = ~dhiva-labs/ubuntu/secureshellgo/
login = anonymous
allow_unsigned_uploads = 0
```

Adjust `~dhiva-labs` in `incoming` to match whichever Launchpad name you
actually activated the PPA under in step 1.

## 3. Build and upload the source package

From the repository root (`/home/dhivakar/dhiva-labs/secure_shell_go`):

```bash
debuild -S -sa -k<KEYID>
```

This builds a *source-only* upload (no binaries — Launchpad's own builders
compile the package) and signs both the `.dsc` and `.changes` files with
your key. It produces, one directory up:

```
../secureshellgo_1.2.0-1~noble1_source.changes
../secureshellgo_1.2.0-1~noble1_source.build
../secureshellgo_1.2.0-1~noble1.dsc
../secureshellgo_1.2.0-1~noble1.tar.xz
```

Upload it:

```bash
dput dhiva-ppa ../secureshellgo_1.2.0-1~noble1_source.changes
```

## 4. Wait for the build

Launchpad queues the source package, builds it on its own `amd64` builders,
and publishes the resulting `.deb` if the build succeeds. This typically
takes 15–30 minutes but can be longer under load. Watch progress at:

```
https://launchpad.net/~dhiva-labs/+archive/ubuntu/secureshellgo/+packages
```

(swap in your actual Launchpad name if different). Click through to a build
log if it fails — the most likely failure mode is described below.

### If the Launchpad build fails on network access

Launchpad's build farm has **very restricted network access** — it does not
allow arbitrary outbound HTTPS to fetch a multi-hundred-megabyte Flutter SDK
tarball from `storage.googleapis.com` mid-build, which is exactly what
`debian/rules` currently does (see `override_dh_auto_build`). If the build
log shows the `curl` step failing or timing out, the `3.0 (native)` +
"download Flutter during the build" approach won't work on Launchpad as-is,
and one of these changes is needed instead:

- Switch to source format `3.0 (quilt)` and vendor a pinned Flutter SDK
  tarball as an orig tarball / additional tarball component so the archive
  contains everything the build needs — no network access required during
  the actual build.
- Or don't use a PPA source build at all: ship the Linux desktop build as a
  **snap** (Snapcraft has its own build farm with different network rules
  and Flutter's `snapcraft` extension is designed for exactly this) or as an
  **AppImage** attached to GitHub Releases, and only use the PPA for
  something that doesn't need a large SDK fetch.

Whichever path you take, the `debian/` directory in this repo is otherwise
correct (control metadata, desktop file, icon, wrapper) and only
`override_dh_auto_build`'s Flutter-acquisition strategy would need to
change.

## 5. Once published: user install command

```bash
sudo add-apt-repository ppa:dhiva-labs/secureshellgo
sudo apt update
sudo apt install secureshellgo
```

(again, swap `dhiva-labs` for whatever Launchpad name actually hosts the
PPA).

## 6. Supporting older Ubuntu releases (jammy, focal, ...)

Launchpad builds each distro series from its own changelog entry — a single
upload only targets the series named in the top `debian/changelog` stanza
(currently `noble`). To also publish for `jammy` or `focal`:

1. Add a new changelog entry on top with that series name, e.g.:
   ```
   secureshellgo (1.2.0-1~jammy1) jammy; urgency=medium

     * Release for Ubuntu PPA

    -- Dhiva Labs <dhivakar1010@gmail.com>  <date>
   ```
2. Rebuild and upload again:
   ```bash
   debuild -S -sa -k<KEYID>
   dput dhiva-ppa ../secureshellgo_1.2.0-1~jammy1_source.changes
   ```
3. Repeat per series. Launchpad builds and publishes each one
   independently; users on each release install the same way.

## Local verification

Before uploading anything, sanity-check the packaging locally. The
`debian/` metadata (control, changelog, copyright, rules, desktop file,
icon) has been structurally validated in this repo, but the actual
`dpkg-buildpackage` run has not been executed end-to-end yet — the
Flutter SDK download alone is ~600 MB and the full build takes 10–15
minutes on a fast machine.

```bash
sudo apt install debhelper devscripts dput desktop-file-utils dh-make lintian
dpkg-buildpackage -us -uc -b   # binary-only, local test — do NOT use for the PPA upload
lintian ../secureshellgo_*.deb
```

Do not `sudo dpkg -i` the result as part of verification — install it in a
throwaway VM or container if you want to test it running, to avoid touching
your main system.
