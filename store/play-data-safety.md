# Play Console: Data safety form — SecureShell Go 1.5.0

Answers for Play Console → App content → Data safety, question by question,
with the reasoning and the code behind each one. They match
`docs/privacy-policy.md` (effective 21 October 2026), so the form and the
policy say the same thing. Definitions are Google's, from the Play Console
Help article "Provide information for Google Play's Data safety section":

- **Collected** means transmitted off the user's device. Exempt: data
  processed only on the device, and data that is end-to-end encrypted so that
  nobody but the sender and the recipient can read it.
- **Shared** means transferred to a third party. Exempt: transfers the user
  starts and would expect, transfers to service providers, legal requests.

---

## Overview

The app has no server, no account, and no analytics, crash-reporting or
advertising SDK. The only data that leaves the device goes over SSH or Mosh
to servers the user typed in themselves, and Dhiva Labs never receives it.
So the honest answer to the first question is **No**, and the form ends
there.

---

## Question 1: Does your app collect or share any of the required user data types?

**Answer: No.**

Everything the app transmits, and why none of it counts as collected or
shared:

| What leaves the device | Where it goes | Why it is not "collection" or "sharing" |
| --- | --- | --- |
| Terminal input and output, files uploaded and downloaded, directory listings, commands the app runs for the user (stats, services, file actions) | The SSH server the user configured, over SSH | End-to-end encrypted between the app and the user's own server (SSH transport encryption); no intermediary, Dhiva Labs included, can read it. It is also sent only because the user asked, to a machine the user chose. `lib/services/ssh_service.dart` (`SSHSocket.connect(host.hostname, host.port, …)`), `lib/services/sftp_service.dart`. |
| Mosh terminal traffic | The same server, over UDP | Encrypted with AES-128-OCB under a key the server sends over SSH; the destination address is the configured host's. `lib/services/mosh/mosh_connection.dart` (`bindRawMoshSocket`), `lib/services/mosh/mosh_bootstrap.dart` (`moshServerAddress`), `lib/services/mosh/ocb.dart`. |
| The user's saved key, used for signatures only (agent forwarding; direct server-to-server copy) | The user's own server, over SSH | The key itself never leaves the device; the server can only ask for signatures while the user is connected. Opt-in per host (agent forwarding) or per copy (direct transfer, with a warning). `lib/services/direct_remote_copy.dart`, `lib/screens/file_browser_pane.dart` (`_pickRoute`). |
| Port-forward traffic | Wherever the user's tunnel points | User-configured networking, the same as `ssh -L/-R/-D`. `lib/services/tunnel_runtime.dart`. |
| Encrypted backup file (`.ssgbackup`) | Wherever the user saves it, through the system save screen (which may be their own Google Drive or another cloud drive) | User-initiated, to the user's own storage, and encrypted with the user's passphrase (Argon2id + AES-256-GCM). Google's guidance treats a user's upload to their own cloud account as not collected when the app does not itself collect or access the data. The app never uploads it by itself. `lib/services/backup_crypto.dart`, `lib/screens/backup_screen.dart`, `android/app/src/main/kotlin/com/dhivalabs/secure_shell_go/DocumentSaver.kt`. |
| Diagnostics log | Nowhere, unless the user copies it to the clipboard and pastes it somewhere | Off by default, kept on the device, scrubbed of secrets, capped at 2 × 128 KB; the class has no network code. `lib/services/diagnostics_log.dart` (`DiagnosticsLog`, "Never sent anywhere"). |
| Web addresses in the terminal | The user's browser, only when the user taps "Open link" | The app hands the address to the browser and makes no request itself; only `http`/`https` open. `lib/services/terminal_links.dart` (`openableSchemes`), `lib/screens/terminal_pane.dart` (`launchUrl(…, mode: LaunchMode.externalApplication)`). |

What stays on the device (not collected, by Google's on-device exemption):
saved hosts, trusted host keys, settings, snippets, tunnels, bookmarks
(`hosts.json`, `known_hosts.json`, `settings.json`, `snippets.json`,
`tunnels.json`, `bookmarks.json`, `server_jobs.json` in the app's private
storage, see `lib/services/app_data_paths.dart`), and saved passwords,
private keys and passphrases (Android Keystore-backed
`flutter_secure_storage`, see `lib/services/credential_store.dart` and
`lib/services/secure_storage_backend.dart`). Android backup and
device-to-device transfer are off: `android:allowBackup="false"` and
`res/xml/data_extraction_rules.xml` exclude every domain.

SDKs: Google asks for data sent by libraries too. The app's dependencies
(`pubspec.yaml`) are `dartssh2`, `xterm`, `flutter_secure_storage`,
`path_provider`, `crypto`, `pinenacl`, `pointycastle`, `file_selector`,
`url_launcher` and `ffi`. None of them sends data anywhere. There is no
Firebase, Google Play Services, analytics, crash-reporting or ads SDK.
`package:http` appears in `pubspec.lock` only as a transitive dependency of
`file_selector_platform_interface`, and nothing in `lib/` imports it (`grep
-rn "package:http" lib` finds nothing). The plugins' own library manifests
declare no permissions (checked in the pub cache), so the merged manifest
should list only the app's. Confirm with the release bundle's merged
manifest before submitting.

Advertising ID: not read. No ads.

**Store listing result:** "No data collected" and "No data shared with third
parties".

---

## Question 2: Is all of the user data collected by your app encrypted in transit?

Play Console asks this only after a **Yes** to question 1, so with the
answer above it does not appear. If it does appear (see "If a reviewer
disagrees" below), the answer is **Yes**:

- SSH encrypts everything on the SSH connection, including SFTP.
- Mosh datagrams are AES-128-OCB encrypted (`lib/services/mosh/ocb.dart`).
- The app makes no HTTP requests. Cleartext traffic is disabled
  (`android:usesCleartextTraffic="false"` in `AndroidManifest.xml`).
- The only unencrypted traffic the app can carry is port-forward traffic
  between the device and a target the user named, as with `ssh -L/-R`. It is
  the user's own traffic and not data the app collects.

---

## Question 3: Do you provide a way for users to request that their data is deleted?

Asked only after a **Yes** to question 1. If it appears, answer **"No"** if
the form allows it with the explanation, or pick the option for apps that
hold no user data off the device. Dhiva Labs holds no data to delete. On the
device, the user deletes data directly:

- Deleting a saved host deletes its stored credentials
  (`lib/screens/host_list_screen.dart`, `credentialStore.delete(host.id)`).
- Trusted host keys can be forgotten from the host's menu or Settings →
  Known hosts (`lib/screens/known_hosts_screen.dart`).
- The diagnostics log is cleared from Settings, or deleted by turning it off
  (`lib/screens/settings/diagnostics_section.dart`).
- Uninstalling removes everything, including the Keystore key.

There are no accounts, so Play's account-deletion URL requirement does not
apply.

---

## Questions 4 and 5: Data types, and for each one: collected or shared, ephemeral, required or optional, purposes

Not asked after a **No** to question 1. None of Play's data types is
collected or shared. The table under question 1 covers each candidate:
personal info (user names, server addresses), files and docs, app activity
(commands typed), app info and performance (diagnostics log), and device or
other IDs (none read).

---

## Security practices badges

- **Independent security review:** No. The app has not had a
  MASA/independent security review.
- **Families policy:** Not applicable. The app is not directed at children,
  so the target audience in App content → Target audience should not include
  children.

---

## If a reviewer disagrees

If Play review takes the view that sending files and commands to the user's
own SSH server is collection, the closest truthful declaration is below.
Use it only if asked. The exemptions above are the reasoning to reply
with first.

- Data types: **Files and docs**; **App activity → Other user-generated
  content** (commands typed in the terminal).
- Collected: Yes. Shared: No.
- Processed ephemerally: Yes. The app keeps no copy of them; it streams them
  to the server the user chose.
- Required or optional: Optional. Users choose whether to use those
  features.
- Purpose: **App functionality**.
- Encrypted in transit: Yes.
- Deletion: Dhiva Labs holds none of it; it is on the user's own server.

---

## Left to the owner

- Submit the form in Play Console. Play does not take a file for this.
- Privacy policy URL: `https://dhiva-labs.github.io/SecureShellGo/privacy-policy`
  (the GitHub Pages copy in `docs/privacy-policy/index.html`). Check that it
  serves the 21 October 2026 version before submitting.
- Re-check the form if a later version adds anything that sends data
  anywhere other than the user's own servers.
