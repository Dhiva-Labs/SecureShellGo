# SecureShell Go plugin for Claude Code

Gives Claude Code read-only access to your servers through the SecureShell Go
AI Bridge, and a skill that tells it how to use the bridge safely. The plugin
holds no keys: the app keeps them.

It contains:

- `.claude-plugin/plugin.json`: the manifest, with two settings the install
  asks for: `bridge_token` (the pairing token, stored as a sensitive value)
  and `launcher` (default `secureshellgo-mcp`). The icon is
  `.claude-plugin/icon.png`.
- `.mcp.json`: the MCP server entry. It starts the launcher and passes your
  pairing token in the environment variable `SSG_BRIDGE_TOKEN`.
- `skills/secureshellgo/SKILL.md`: the skill. It is a copy of
  `../skill/SKILL.md`; keep the two identical.

## Before you install

The AI Bridge is on Linux and Windows only, and it is off until you switch it
on. There are three ways to set the plugin up; use the first that fits. Each
needs the plugin source on GitHub, which resolves only once this release is on
the repository's default branch (before that, see "Before this release is
published" below).

### 1. One click, from the app

In SecureShell Go: Settings → AI Bridge → **Connect Claude Code**. The button
appears only when the app finds a file named `claude` on your computer. Looking
runs nothing: opening Settings or pressing "Check again" only checks whether
the file exists on the `PATH`, in `~/.local/bin` or in `~/.claude/local` (on
Windows, the `PATH` and `%USERPROFILE%\.local\bin\claude.exe`). It is not
available in the snap or the Flatpak, whose sandboxes cannot start programs
on your computer; use route 2 there.

When you press the button, the app runs `claude --version` and `claude plugin
marketplace list --json` (10 seconds each) so it can show you the bridge's
usual explanation, the full path and version of the program and, if the plugin
would not come from the published GitHub source, where it would be loaded
from, with a warning. Those two commands change nothing, and Cancel leaves
everything as it was. Only on **Connect** does the app switch the bridge on if
it was off, create a pairing, and run `claude` to add the plugin source if
missing, install the plugin, save the token and launcher command, and check
that the token was saved (90 seconds a step). The token goes to `claude` on its standard input
only, never on a command line, in an environment variable, on screen, in the
clipboard or in a log. The pairing cannot be used until the setup is confirmed, and
one left behind by closing the app part way is removed at the next start. If a
step fails, the pairing is revoked again and the bridge is put back the way it
was (switched off again if this attempt switched it on). Then **Shared hosts** lets you tick which saved hosts the assistant
may read.

### 2. Three commands, by hand

In Settings → AI Bridge → **Connect an assistant**, name it, choose "Claude
Code plugin", and paste the one block of three commands it shows into a
terminal. They are:

```
claude plugin marketplace add Dhiva-Labs/SecureShellGo
claude plugin install secureshellgo@dhiva-labs
<a line that pipes a small JSON object with the token, and the launcher path
 when your install needs one, into: claude plugin configure
 secureshellgo@dhiva-labs --values-stdin>
```

The app writes the third line with your token filled in, in the form your
system's shell takes (bash on Linux, PowerShell on Windows); the token is
shown once.

The trade-off (the app's screen says so under the commands too): pasting the third line **puts the token in your shell's history
file**. One click does not. Afterwards you can delete that line from the
history, or, if the history is shared or synced, revoke the assistant in the
app and pair it again.

Inside a Claude Code session (not in a terminal), `/plugin marketplace add
Dhiva-Labs/SecureShellGo` and `/plugin install secureshellgo@dhiva-labs` do
the first two steps, and `/plugin configure secureshellgo@dhiva-labs` asks for
the token and the launcher. Those slash commands are typed **inside the
assistant's session**, never in a terminal.

### 3. Other clients

Use the config snippets in `../clients/`.

Then, whichever route: tick the hosts the assistant may read under **Shared
hosts** (Settings → AI Bridge, "Shared hosts — N of M"), or edit a server and
switch on "AI access (read-only)". Start a new Claude Code session afterwards.

### Before this release is published

The GitHub route works once this release is on the repository's default
branch. Before that, add the marketplace from a local checkout:
`claude plugin marketplace add ./path/to/SecureShellGo`. (One click only
adds the GitHub source, and says where the plugin comes from if the
`dhiva-labs` marketplace already points elsewhere.)

## Launcher command

"Connect an assistant" in the app shows the command for your install:

| Install | Launcher command |
| --- | --- |
| deb / PPA, `.rpm`, Arch package, Microsoft Store (MSIX) | `secureshellgo-mcp` (the default) |
| Snap | `secureshellgo.mcp` |
| Flatpak | `/var/lib/flatpak/exports/bin/com.dhivalabs.secure_shell_go` (system install) or `/home/<you>/.local/share/flatpak/exports/bin/com.dhivalabs.secure_shell_go` (`--user` install) |
| AppImage | the full path of the `.AppImage` file |
| Linux tarball, Windows zip, or a build from source | the full path of `secureshellgo-mcp` (`secureshellgo-mcp.exe` on Windows) next to the app |

The plugin's `launcher` setting is one command with no arguments. The Flatpak
and the AppImage fit that because they start the launcher instead of the app
when `SSG_BRIDGE_TOKEN` is set and stdin is not a terminal, which is how the
plugin starts them.

## Limits

- What the assistant reads is sent by Claude Code to its own provider.
  SecureShell Go and Dhiva Labs receive nothing, but your AI provider does.
- Blocked paths (`~/.ssh`, `.env` files, key files, shell histories,
  `/etc/shadow`, cloud and registry credentials, and any you add) are a
  default set, not a guarantee. For a hard guarantee, use a server account
  with limited read rights.
- Text on a server can contain instructions aimed at the assistant.
- Version 1.6.0 can only read. Nothing it can call changes a server.

Other MCP-compatible clients: see `../clients/`.
