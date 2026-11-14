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

1. **One click.** In SecureShell Go (Linux deb or archive, or Windows):
   Settings → AI Bridge → **Connect Claude Code**. The button appears only when
   the app finds a file named `claude` (looking runs nothing); it is not
   available in the snap. Pressing it runs `claude --version` and `claude
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
   `PASTE-TOKEN-HERE` with the token, and, if your install is not the deb or
   the Microsoft Store one, replace `secureshellgo-mcp` with the command
   below. (The app's own snippet already has both filled in.) Treat that
   file as a secret: anyone who can read it can read from your shared
   servers while the app is running with the bridge on and unlocked.
   Revoking the assistant in the app stops the token at once.
4. For each server you want the assistant to see, tick it in "Shared hosts"
   (Settings → AI Bridge), or edit it and switch on "AI access (read-only)".

## The launcher command

"Connect an assistant" shows the right command for your install. It is:

| Install | `command` |
| --- | --- |
| deb / PPA | `secureshellgo-mcp` |
| Microsoft Store (MSIX) | `secureshellgo-mcp` |
| Snap | `secureshellgo.mcp` |
| Linux tarball, Windows zip, or a build from source | the full path of `secureshellgo-mcp` (`secureshellgo-mcp.exe` on Windows) next to the app |

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
- The bridge can only read. Version 1.6.0 has no tool that changes anything.
