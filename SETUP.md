# Set up compos

This file is for a person who wants to try compos, and for the AI agent that sets it up for them. compos ships as one binary, so there is nothing to build and no developer tools to install. To build from source instead, see [INSTALL.md](INSTALL.md).

## For the person

1. Get Claude Code. On macOS or Linux, open the Terminal app and paste:

   ```sh
   curl -fsSL https://claude.ai/install.sh | bash
   ```

   Then type `claude` and sign in. Another coding agent (Codex, Gemini CLI) also works.

2. Say this to the agent:

   > Set up compos for me. Follow SETUP.md in <REPO-URL>.

3. The agent asks before it changes anything on your machine. It never needs your API keys; you type those yourself into `M-x setup` at the end.

## For the agent

Do the steps in order. Each step says how to check it. Stop and tell the person when a check fails. Explain each step in one plain sentence before you run it; the person is not a developer.

Rules:

- Ask the person before you install or move anything.
- Do not read, print, or store a secret value.
- Run the daemon in the background. Do not block on it.

### 1. Get the binary

Find the platform with `uname -sm`. Each release on <REPO-URL>/releases has two binaries:

- `compos-VERSION-macos_arm`: macOS on Apple silicon (`Darwin arm64`).
- `compos-VERSION-linux`: Linux on x86_64.

Other platforms have no binary yet; tell the person and stop. Download the binary of the latest release into `~/.local/bin/compos` and make it executable. On macOS, clear the quarantine flag: `xattr -d com.apple.quarantine ~/.local/bin/compos`. The first run unpacks itself once and is slower.

Check: `~/.local/bin/compos --version` answers.

### 2. Run it

```sh
~/.local/bin/compos   # in the background; it serves http://localhost:4004
```

Open the editor in Chrome: `open -na "Google Chrome" --args --app=http://localhost:4004`. Without Chrome, any browser at that address works.

Check: `http://localhost:4004` answers, and the person sees the editor. The state lives in `~/.compos`.

### 3. Connect the agent to the editor

The editor is an MCP server. For Claude Code:

```sh
claude mcp add --scope user compos -- <MCP-SHIM-PATH>
```

Restart the agent session. Check: the `eval-scheme` tool of the `compos` server answers `(setup-report)`.

### 4. Configure

Follow [INSTALL.md](INSTALL.md) from step 4: the chat connector, secret storage, model presets and the decision model. Those steps run in Scheme through `eval-scheme`, the same for the binary and a source build. Then hand over to the person with `M-x setup`.

Inference is the only thing compos needs. It works with no decision model and no embedding model: `apropos` falls back to plain word matching, and that is enough for the agent to find the editor API. Set up the decision model and embeddings when they are easy to get, but do not let the person stall on them, and do not tell them compos is broken without them.

### 5. Fast model when JEV is not there

JEV is not part of a fresh install. When it is missing, use the fast model of the agent the person already has: Claude Code's Haiku, or Codex's fast model. Put it in the `fast` and `summarize` presets ([INSTALL.md](INSTALL.md) step 6), keep `jev` out of `decide-backends`, and set `command-palette-decide-backend` to `model`. Do not leave a job pointed at JEV.

Check: `(llm-model-for 'fast)` names that model, and the variable `decide-backends` does not name `jev`.

### 6. Chrome extension: do not skip

The extension is what lets compos read and act in the person's own Chrome, with their logins. Install it every time, and do not finish until it is connected. compos copies it to `~/.compos/chrome-extension` at every start. Walk the person through it:

1. Open `chrome://extensions`.
2. Turn on **Developer mode**, top right.
3. **Load unpacked**, and choose `~/.compos/chrome-extension`. In the file picker, Cmd-Shift-G takes a typed path.

Check: `(browser-connected?)` answers `#t`. If it does not, stay on this step. Details: [docs/CHROME_EXTENSION.md](docs/CHROME_EXTENSION.md).
