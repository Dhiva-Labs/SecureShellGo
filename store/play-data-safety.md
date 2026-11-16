# Play Console: Data safety form — SecureShell Go 1.8.0

Answers for Play Console → App content → Data safety, question by question,
with the reasoning and the code behind each one. They match
`docs/privacy-policy.md` (effective 17 November 2026), so the form and the
policy say the same thing. Definitions are Google's, from the Play Console
Help article "Provide information for Google Play's Data safety section":

- **Collected** means transmitted off the user's device. Exempt: data
  processed only on the device, and data that is end-to-end encrypted so that
  nobody but the sender and the recipient can read it.
- **Shared** means transferred to a third party. Exempt: transfers the user
  starts and would expect, transfers to service providers, legal requests.

---

## Overview

Up to 1.7.0 the app had no server, no account, and no analytics,
crash-reporting or advertising SDK, and the only data that left the device
went over SSH or Mosh to servers the user typed in themselves. The honest
answer to the first question was **No**, and the form ended there.

**1.8.0 changes that for Android.** The app now has an optional, off-by-default
built-in assistant: a chat that sends what the user types, what the assistant
reads from the user's servers and what its tools return to an AI service the
user chose, with the user's own API key, directly from the phone. That is user
content leaving the device for a third party, so the honest answer to the
first question is now **Yes**, and the form no longer ends there. Dhiva Labs
still receives nothing, collects nothing and runs no server. The sections
below say exactly what to declare. **Everything marked "Re-declare by hand"
must be changed in the Play Console by the owner: Play takes no file for this
form, and the answers in the console today are the 1.7.0 ones.**

---

## The AI features on Android (1.8.0)

What exists on Android now, and what still does not:

- **Built-in assistant** (new, Settings → AI Bridge → Built-in assistant). Off
  by default, and it never starts a request until the user switches it on,
  confirms the explanation, chooses a provider, enters a model and saves a
  key. `lib/services/assistant/`, `AppSettings.assistantEnabled`.
- **Per-server AI access** (the "AI access" section of a host, and "Shared
  hosts"): which servers the assistant may reach, and at what level. Local to
  the device.
- **Remote approvals** (the "AI approvals on this computer" action in a host's menu): the
  phone signs in to the user's own computer over SSH and shows its approval
  cards. No new destination: it is an SSH connection to a server the user
  saved.
- **Still not on Android:** pairing an assistant program that runs on the
  phone (there is none; the local channel and the launcher exist on Linux and
  Windows only, `BridgeService.channelSupported`).

The 1.6.0 and 1.7.0 text of this file said the bridge's code never runs on
Android and that `main.dart` constructs no bridge. That is **no longer true**:
`main.dart` builds the tool host everywhere, so the built-in assistant can use
it, with the local channel off. Nothing was added to the Android manifest: no
new permission (`INTERNET` was already declared), and cleartext traffic stays
disabled (`android:usesCleartextTraffic="false"`), so the assistant can only
reach `https` addresses on Android. The privacy policy covers all of this in
"The AI Bridge and the built-in assistant".

---

## Question 1: Does your app collect or share any of the required user data types?

**Answer: Yes (changed in 1.8.0; it was No). Re-declare by hand.**

Reason, in one paragraph: with the built-in assistant on, the app transmits
user content (typed messages, content of the user's servers that the
assistant reads, results of its tools, and, for a desktop, screenshots) off
the device to a third party the user chose, at the user's direction. That
transfer is **not** end-to-end encrypted to the recipient (TLS ends at the AI
service, which reads it), so Google's end-to-end exemption does not apply to
it, and it is not on-device processing. Nothing goes to Dhiva Labs and Dhiva
Labs collects nothing: the "collection" is the app sending the user's own
content to the user's own choice of service, and the form must say so under
"Data types" (below) rather than staying silent. The user-initiated,
user-expected nature of the transfer is why it is declared as **not shared**.

Everything else the app transmits, and why none of it counts as collected or
shared (unchanged from 1.7.0):

| What leaves the device | Where it goes | Why it is not "collection" or "sharing" |
| --- | --- | --- |
| Terminal input and output, files uploaded and downloaded, directory listings, commands the app runs for the user (stats, services, file actions) | The SSH server the user configured, over SSH | End-to-end encrypted between the app and the user's own server (SSH transport encryption); no intermediary, Dhiva Labs included, can read it. It is also sent only because the user asked, to a machine the user chose. `lib/services/ssh_service.dart` (`SSHSocket.connect(host.hostname, host.port, …)`), `lib/services/sftp_service.dart`. |
| Mosh terminal traffic | The same server, over UDP | Encrypted with AES-128-OCB under a key the server sends over SSH; the destination address is the configured host's. `lib/services/mosh/mosh_connection.dart` (`bindRawMoshSocket`), `lib/services/mosh/mosh_bootstrap.dart` (`moshServerAddress`), `lib/services/mosh/ocb.dart`. |
| The user's saved key, used for signatures only (agent forwarding; direct server-to-server copy) | The user's own server, over SSH | The key itself never leaves the device; the server can only ask for signatures while the user is connected. Opt-in per host (agent forwarding) or per copy (direct transfer, with a warning). `lib/services/direct_remote_copy.dart`, `lib/screens/file_browser_pane.dart` (`_pickRoute`). |
| Port-forward traffic | Wherever the user's tunnel points | User-configured networking, the same as `ssh -L/-R/-D`. `lib/services/tunnel_runtime.dart`. |
| Encrypted backup file (`.ssgbackup`) | Wherever the user saves it, through the system save screen (which may be their own Google Drive or another cloud drive) | User-initiated, to the user's own storage, and encrypted with the user's passphrase (Argon2id + AES-256-GCM). Google's guidance treats a user's upload to their own cloud account as not collected when the app does not itself collect or access the data. The app never uploads it by itself. `lib/services/backup_crypto.dart`, `lib/screens/backup_screen.dart`, `android/app/src/main/kotlin/com/dhivalabs/secure_shell_go/DocumentSaver.kt`. |
| Diagnostics log | Nowhere, unless the user copies it to the clipboard and pastes it somewhere | Off by default, kept on the device, scrubbed of secrets, capped at 2 × 128 KB; the class has no network code. `lib/services/diagnostics_log.dart` (`DiagnosticsLog`, "Never sent anywhere"). |
| Web addresses in the terminal | The user's browser, only when the user taps "Open link" | The app hands the address to the browser and makes no request itself; only `http`/`https` open. `lib/services/terminal_links.dart` (`openableSchemes`), `lib/screens/terminal_pane.dart` (`launchUrl(…, mode: LaunchMode.externalApplication)`). |
| Approval cards of the user's own computer (Remote approvals) | The user's own computer, over SSH | An SSH exec channel to a host the user saved; the cards are the computer's own data shown to its owner, and nothing goes anywhere else. `lib/services/bridge_remote/`. |

**What 1.8.0 adds, and why it IS declared** (only when the user switches on the
built-in assistant, saves a key and sends a message):

| What leaves the device | Where it goes | Why it is declared |
| --- | --- | --- |
| What the user types in the chat, and the conversation so far | The AI service the user configured (Anthropic's `api.anthropic.com` by default, or the https address the user entered for an OpenAI-compatible service), over HTTPS, from the phone | Transmitted off the device to a third party; TLS only, so not end-to-end. User-initiated. `lib/services/assistant/assistant_http.dart`, `anthropic_provider.dart`, `openai_provider.dart`. |
| What the assistant's tools return: what it read from the user's servers (stats, service lists, log lines, folder listings, text files), what commands and jobs printed, what a terminal screen showed, each result cut to 16 KiB and with private keys and known secrets removed from text | Same | Same. `assistant_conversation.dart` (`truncateAssistantResult`). Arbitrary content: it can include anything the user's servers hold. |
| Screenshots of a server's desktop (only if the user allowed a desktop for that server and the provider is Anthropic) | Same | Same; the OpenAI-compatible connection carries no images. `bridge_desktops.dart`. |
| The user's API key | Same, in the request header, as authentication | A credential the user supplies for their own provider, sent only to that provider. It is not one of Play's data types; it is never written to a log, a backup or settings. |

The conversation is kept in memory only and is gone when the app closes: the
app writes none of it to disk. What the AI service keeps is its own business
under its own terms. The transfer needs the `INTERNET` permission the app
already has; cleartext is disabled, so only `https` is possible on Android.

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

The assistant uses `dart:io`'s `HttpClient` directly (no new dependency;
`pubspec.yaml` is unchanged by it, and `grep -rn "package:http" lib` still
finds nothing). It sends nothing anywhere except the configured address.

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

**Store listing result for 1.8.0 (Re-declare by hand):** the listing will no
longer say "No data collected". It will show the data types below as
collected, optional, not shared with third parties (user-initiated). The
Android store listing text (`store/listing.md`) says in its own words that
what the assistant reads goes to the AI service the user chose, not to Dhiva
Labs. Do not publish 1.8.0 on Android with the 1.7.0 form still in place.

---

## Question 2: Is all of the user data collected by your app encrypted in transit?

Play Console asks this only after a **Yes** to question 1. From 1.8.0 the
answer to question 1 is Yes, so this question **does** appear. The answer is
**Yes**: everything the app transmits is encrypted in transit.

- SSH encrypts everything on the SSH connection, including SFTP.
- Mosh datagrams are AES-128-OCB encrypted (`lib/services/mosh/ocb.dart`).
- The only HTTP requests are the built-in assistant's, to the address the
  user configured, over HTTPS (1.8.0). Cleartext traffic is disabled
  (`android:usesCleartextTraffic="false"` in `AndroidManifest.xml`), so an
  `http` address cannot be reached on Android.
- The only unencrypted traffic the app can carry is port-forward traffic
  between the device and a target the user named, as with `ssh -L/-R`. It is
  the user's own traffic and not data the app collects.

---

## Question 3: Do you provide a way for users to request that their data is deleted?

Asked only after a **Yes** to question 1, so from 1.8.0 it appears. Dhiva Labs
holds no data and has no account system, so there is nothing for it to delete
on request: answer the way the form allows for an app that does not store the
data it transmits (the data goes to a third party the user chose; their
deletion rights are with that service). Do **not** claim a deletion channel Dhiva
Labs does not have. On the device, the user deletes data directly:

- Deleting a saved host deletes its stored credentials
  (`lib/screens/host_list_screen.dart`, `credentialStore.delete(host.id)`).
- Trusted host keys can be forgotten from the host's menu or Settings →
  Known hosts (`lib/screens/known_hosts_screen.dart`).
- The diagnostics log is cleared from Settings, or deleted by turning it off
  (`lib/screens/settings/diagnostics_section.dart`).
- Uninstalling removes everything, including the Keystore key.
- The assistant's API key is removed from Settings → AI Bridge → Built-in
  assistant → Remove key. Its conversation is never stored.

There are no accounts, so Play's account-deletion URL requirement does not
apply.

---

## Questions 4 and 5: Data types, and for each one: collected or shared, ephemeral, required or optional, purposes

**Re-declare by hand, from 1.8.0.** Declare the types the built-in assistant's
traffic can carry. The content is whatever the user's servers hold and the
user types, so no list can be complete; these are the types the assistant
sends as a matter of course:

| Data type (Play's name) | What it is here | Collected | Shared | Ephemeral | Required or optional | Purpose |
| --- | --- | --- | --- | --- | --- | --- |
| Messages → **Other in-app messages** | What the user types to the assistant | Yes | No | Yes | Optional | App functionality |
| Files and docs → **Files and docs** | Text files the assistant reads from the user's servers | Yes | No | Yes | Optional | App functionality |
| App activity → **Other user-generated content** | Log lines, command and job output, terminal screens, service lists and stats returned by tools | Yes | No | Yes | Optional | App functionality |
| Photos and videos → **Photos** | Screenshots of a server's desktop, only if the user allowed a desktop and the provider is Anthropic | Yes | No | Yes | Optional | App functionality |

- **Collected: Yes** for each, because the app transmits it off the device.
  **Shared: No**, on Play's exemption for a transfer the user starts and
  would expect, to a service the user chose and configured. Read Google's
  current wording of that exemption in the Help article when you fill the form,
  and if there is any doubt choose **Shared: Yes** with the purpose "App
  functionality"; that is the safe direction.
- **Processed ephemerally: Yes.** The app keeps no copy: the conversation is in
  memory only. (What the AI service does with it is the service's own.)
- **Required or optional: Optional.** Off by default; the user chooses to use
  it, and can leave it off or remove the key.
- **Purpose: App functionality.** Nothing is used for analytics, advertising,
  personalisation, fraud prevention or any purpose of Dhiva Labs.
- Types that a user's content may also contain (user names, email addresses,
  other personal info in a log) are covered by the same transfer. The form
  cannot name them all; the privacy policy says the content is arbitrary.
- The old table of candidates for the first answer (personal info, files, app
  activity, app info and performance, device IDs) still applies to the rest of
  the app: those remain not collected, apart from the rows above. Advertising
  ID: not read.

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
  serves the 1.8.0 version before submitting (see "Re-declare by hand").
- **Re-declare by hand in the Play Console before 1.8.0 reaches Android:**
  1. Data safety → question 1: change **No** to **Yes**.
  2. Add the four data types in "Questions 4 and 5": collected, not shared,
     ephemeral, optional, App functionality.
  3. Encrypted in transit: **Yes**. Deletion request: as above.
  4. Check the privacy policy URL serves the version that has the 1.8.0
     "The AI Bridge and the built-in assistant" section (set its effective
     date at release; the file in this repository holds the date for the
     previous release).
  5. Re-read Google Play's AI-generated content policy: an app that lets
     users chat with an AI may be asked for an in-app way to report offensive
     AI output. The app has none today; decide before submitting whether it
     applies (the content comes from the user's own provider and servers).
  6. App content declarations that may now be asked about: the app does not
     use the user's data for ads, and the built-in assistant is off until the
     user turns it on.
- Re-check the form if a later version adds anything that sends data
  anywhere other than the user's own servers and the AI service the user
  chose.
