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
2. Activate a PPA at
   `https://launchpad.net/~dhiva-labs/+activate-ppa` (or your personal
   account URL if you're not publishing under the `dhiva-labs` team).
   Name the PPA `apps` so the `add-apt-repository ppa:dhiva-labs/apps`
   line in `README.md` matches.
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
[dhiva-apps]
fqdn = ppa.launchpad.net
method = ftp
incoming = ~dhiva-labs/ubuntu/apps/
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
../secureshellgo_1.2.0~noble3_source.changes
../secureshellgo_1.2.0~noble3_source.build
../secureshellgo_1.2.0~noble3.dsc
../secureshellgo_1.2.0~noble3.tar.xz
```

Upload it:

```bash
dput dhiva-apps ../secureshellgo_1.2.0~noble3_source.changes
```

## 4. Wait for the build

Launchpad queues the source package, builds it on its own `amd64` builders,
and publishes the resulting `.deb` if the build succeeds. This typically
takes 15–30 minutes but can be longer under load. Watch progress at:

```
https://launchpad.net/~dhiva-labs/+archive/ubuntu/apps/+packages
```

## Why the vendored Flutter SDK

Launchpad's build farm has **no outbound network access** during a source
build — external DNS resolution is blocked. The initial `1.2.0~noble1`
upload failed for exactly this reason: `debian/rules` used `curl` to fetch
`flutter_linux_3.44.6-stable.tar.xz` from `storage.googleapis.com`, and the
build farm couldn't resolve the host.

`1.2.0~noble3` fixes this by shipping the Flutter SDK and pub cache inside
the source package under `packaging/vendor/`:

  * `packaging/vendor/flutter-3.44.6-linux-slim.tar.xz` — a Linux-only
    stripped copy of Flutter 3.44.6 stable (~147 MB compressed).
  * `packaging/vendor/pub-cache-3.44.6.tar.xz` — only the pub.dev packages
    resolved by `pubspec.lock` (~19 MB compressed).

`debian/rules` extracts these into build-scoped `.flutter/` and
`.pub-cache/` directories, sets `FLUTTER_PREBUILT_ENGINE_VERSION` so the
flutter tool doesn't try to derive it from a full git history, and runs
`flutter pub get --offline` and `flutter build linux --release --no-pub`
— nothing reaches the network.

See `packaging/vendor/README` for the full recipe used to produce those
tarballs and how to refresh them on a Flutter version bump.

## 5. Once published: user install command

```bash
sudo add-apt-repository ppa:dhiva-labs/apps
sudo apt update
sudo apt install secureshellgo
```

## 6. Supporting older Ubuntu releases (jammy, focal, ...)

Launchpad builds each distro series from its own changelog entry — a single
upload only targets the series named in the top `debian/changelog` stanza
(currently `noble`). To also publish for `jammy` or `focal`:

1. Add a new changelog entry on top with that series name, e.g.:
   ```
   secureshellgo (1.2.0~jammy1) jammy; urgency=medium

     * Release for Ubuntu PPA

    -- Dhiva Labs <dhivakar1010@gmail.com>  <date>
   ```
2. Rebuild and upload again:
   ```bash
   debuild -S -sa -k<KEYID>
   dput dhiva-apps ../secureshellgo_1.2.0~jammy1_source.changes
   ```
3. Repeat per series. Launchpad builds and publishes each one
   independently; users on each release install the same way.

## Local verification

Before uploading anything, sanity-check the packaging locally.

```bash
sudo apt install debhelper devscripts dput desktop-file-utils dh-make lintian
dpkg-buildpackage -us -uc -b   # binary-only, local test — do NOT use for the PPA upload
lintian ../secureshellgo_*.deb
```

Do not `sudo dpkg -i` the result as part of verification — install it in a
throwaway VM or container if you want to test it running, to avoid touching
your main system.
