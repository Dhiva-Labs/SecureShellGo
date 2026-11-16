# Client configuration snippets

SecureShell Go's AI Bridge speaks MCP over standard input and output, through
a small launcher program. Any MCP-compatible AI assistant can use it. These
files show how to point a client at the launcher.

| File | Use it for |
| --- | --- |
| `mcp.json` | Clients that read an `mcpServers` object from a JSON file. The most common shape. |
| `vscode-mcp.json` | Editors that read a `servers` object with `"type": "stdio"` (the shape of a VS Code `mcp.json`). |
| `INSTRUCTIONS.md` | Plain-text rules to put in a client's custom instructions or system prompt, for clients that have no skills. Same rules as `../skill/SKILL.md`. |

**For Claude Code, use the plugin in `../plugin/` instead of these snippets.**
It sets up the server entry and the skill. Two ways, both described in
`../plugin/README.md`:

1. **One click.** In SecureShell Go (Linux deb, rpm, Arch package, AppImage
   or archive, or Windows): Settings → AI Bridge → **Connect Claude Code**.
   The button appears only when the app finds a file named `claude` (looking
   runs nothing); it is not available in the snap or the Flatpak. Pressing it runs `claude --version` and `claude
   plugin marketplace list --json` to show the program's path and version
   first; only after you confirm does the app run it to install the plugin and hands it the token on standard input only, and undoes its
   pairing if anything fails.
2. **Three terminal commands.** "Connect an assistant" with the "Claude Code
   plugin" choice shows one block of three commands to paste into a terminal.
   Pasting the third line puts the token in your shell's history file (one
   click does not); delete that line afterwards, or revoke the assistant and
   pair again if the history is shared. `/plugin configure
   secureshellgo@dhiva-labs` does the same but is typed inside a Claude Code
   session, not in a terminal.

Both need the plugin source on GitHub, which works once the release is on the
repository's default branch. **For every other client, this folder is the
third route:** use the snippets here. The skill is in `../skill/`; the plugin
carries a copy of it that must be kept in step with it.

## Steps

1. In SecureShell Go (Linux or Windows), open Settings, AI Bridge, and switch
   on "AI Bridge". It is off by default, and the app explains what it does
   each time you switch it on.
2. Choose "Connect an assistant", name it, and copy the token. It is shown
   once.
3. Paste the snippet into your client's MCP configuration, replace
   `PASTE-TOKEN-HERE` with the token, and, if your install is not the deb,
   rpm, Arch package or Microsoft Store one, replace `secureshellgo-mcp` with the command
   below. (The app's own snippet already has both filled in.) Treat that
   file as a secret: anyone who can read it can read from your shared
   servers, ask for changes where you allowed them, and use that host's
   allowed commands and any approval for a while you gave this assistant,
   while the app is running with the bridge on and unlocked.
   Revoking the assistant in the app stops the token at once.
4. For each server you want the assistant to see, tick it in "Shared hosts"
   (Settings → AI Bridge), or edit it and switch on "Share with AI assistants".
5. Only if you want the assistant to be able to ask for changes: edit the
   server (or use the settings button of its row in "Shared hosts") and
   switch on "Let the assistant request changes". Nothing changes on a server
   without your answer on a card in the app, except commands you put under
   "Allowed commands" for that host and, if you turn on Settings → AI Bridge →
   "Allow for a while", the approvals for a number of minutes you give on a
   card. "Full control terminal" is a separate switch beneath it. All of these
   are off until you switch them on. The card does not alert you, so keep the
   app in view when you expect one; an unanswered card is denied after two
   minutes.

## The launcher command

"Connect an assistant" shows the right command for your install. It is:

| Install | `command` |
| --- | --- |
| deb / PPA, `.rpm`, Arch package | `secureshellgo-mcp` |
| Microsoft Store (MSIX) | `secureshellgo-mcp` |
| Snap | `secureshellgo.mcp` |
| Flatpak | `/var/lib/flatpak/exports/bin/com.dhivalabs.secure_shell_go` (system install) or `/home/<you>/.local/share/flatpak/exports/bin/com.dhivalabs.secure_shell_go` (`--user` install) |
| AppImage | the full path of the `.AppImage` file |
| Linux tarball, Windows zip, or a build from source | the full path of `secureshellgo-mcp` (`secureshellgo-mcp.exe` on Windows) next to the app |

The Flatpak and the AppImage run the launcher instead of the app when
`SSG_BRIDGE_TOKEN` is set and stdin is not a terminal, as it is when a client
starts them. A client that takes arguments can also use `"command":
"flatpak", "args": ["run", "--command=secureshellgo-mcp",
"com.dhivalabs.secure_shell_go"]` for the Flatpak.

The token is passed in the environment variable `SSG_BRIDGE_TOKEN`. If the
app is not running, or the bridge is off, the launcher answers every request
with a plain error saying so. The launcher only carries messages: the app has
to be running for anything to work.

## Limits

- What the assistant reads is sent by the AI client to that client's own
  provider, under that provider's terms. SecureShell Go and Dhiva Labs
  receive nothing, but your AI provider does.
- Blocked paths (`~/.ssh`, `.env` files, key files, shell histories,
  `/etc/shadow`, cloud and registry credential files, and any you add) are a
  default set, not a guarantee. For a hard guarantee, use a server account
  with limited read rights.
- Text on a server (a log line, a file) can contain instructions aimed at the
  assistant. The skill and the instructions file tell it to ignore them, but
  that is not enforced.
- The app never prompts for a bridge call; a server that needs a person to
  sign in fails with "connect to it once in SecureShell Go". Prompts from
  outside the app can still appear: an SSH agent that asks you to confirm or
  touch a key, or your desktop keyring's own unlock dialog.
- Version 1.7.0 can change a server (`run_command`, `write_file`,
  `service_action`, `run_on_hosts`) and open a terminal (`open_terminal`,
  `send_input`, `read_screen`, `close_terminal`), only on hosts where you
  switched that on and with your approval on a card in the app, unless you
  allowed the exact command beforehand or gave an approval for a while. An
  approved terminal can run any command as the account the app signs in as,
  with no further question; the blocked-path list does not apply inside it or
  to commands. What a command or terminal prints is sent to your AI provider.
  The `INSTRUCTIONS.md` rules ask the assistant to say what it will ask for
  first, to ask for one change at a time, to stop if you deny, and never to
  ask you to switch these on; that is advice to a model, and the card is what
  protects you.
