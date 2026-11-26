# Set up compos

This file is for a person who wants to try compos, and for the AI agent that sets it up. compos ships as one binary, so you build nothing and install no compiler tools. To build from source instead, read [INSTALL.md](INSTALL.md). After setup finishes, read [USER-GUIDE.md](USER-GUIDE.md).

## For the person

1. Install a coding agent if you do not have one yet. For Claude Code on macOS or Linux, open Terminal and run:

   ```sh
   curl -fsSL https://claude.ai/install.sh | bash
   ```

   Then run `claude` and sign in. Codex (`npm install -g @openai/codex`, then `codex login`) and Antigravity (`curl -fsSL https://antigravity.google/cli/install.sh | bash`, then `agy`) also work.

2. Tell the agent:

   > Set up compos for me. Follow SETUP.md in https://github.com/svs/compos

3. The agent asks before it installs software or edits shell files. You type API keys and run logins yourself.

## For the agent

Follow the steps in order. Each step has a check. Stop and tell the person when a check fails. Explain each step in one plain sentence before you run it, because the person may not be a developer.

Rules:

- Ask the person before you install software, change shell startup files, or move files.
- Never read, print, copy into a transcript, or store a secret value or token file.
- Start the daemon in the background. Do not block on it.
- Verify the daemon's own environment through `eval-scheme`. Never assume your shell's `PATH` matches the daemon's `PATH`.

### 1. Audit the shell, Node, and PATH first

Most ACP connector failures come from `PATH` mismatches. Check the machine before you download or start compos.

Why `PATH` breaks ACP connectors:

- The compos daemon inherits `PATH` once at launch. Every ACP adapter starts through `System.find_executable/1` on the daemon's own `PATH`.
- Even when you set an absolute binary path in `agent-connector-command-overrides`, Node-based adapters (`claude-agent-acp`, `codex`) start with `#!/usr/bin/env node` and still look up `node` on the daemon's `PATH`.
- `claude-agent-acp` spawns `claude` as a child process, so `claude` must also be on the daemon's `PATH`.
- Version managers (`asdf`, `mise`, `nvm`, `fnm`, `volta`) configure `PATH` inside shell startup files (`~/.zshrc`, `~/.bashrc`, `~/.profile`). A non-login shell, a GUI launcher, or a LaunchAgent misses those paths.
- `asdf` and `mise` require a reshim after every `npm install -g`. Without a reshim, the shim directory does not contain the new command.
- A project's `.tool-versions` or `mise.toml` can switch Node versions when an agent spawns in that directory, hiding global npm packages installed under a different Node version.
- Native installers place binaries outside standard system directories: `~/.local/bin` and `~/.claude/local` (Claude Code), `~/.antigravity/antigravity/bin` (Antigravity `agy`), `~/.opencode/bin` (OpenCode), `~/.kimi-code/bin` (Kimi), `~/.bun/bin` (Bun), and `/opt/homebrew/bin` or `/home/linuxbrew/.linuxbrew/bin` (Homebrew).
- `M-x restart-daemon` preserves the old daemon's environment. If you change `~/.zshrc` or `~/.bashrc` later, you must stop the daemon and launch it again from a fresh login shell.

Run a quick read-only audit first:

```sh
echo "SHELL=$SHELL"
echo "CURRENT_PATH=$PATH"
"${SHELL:-/bin/sh}" -lc 'echo "LOGIN_PATH=$PATH"; command -v node npm mise asdf nvm fnm volta claude claude-agent-acp codex agy 2>/dev/null || true'
```

Note which version manager controls Node, if any:

| Manager | Shim or bin directory | Trap to handle |
| --- | --- | --- |
| `asdf` | `~/.asdf/shims` | Run `asdf reshim nodejs` after every `npm install -g`. Set a global default Node (`asdf set -u nodejs <ver>` or `~/.tool-versions`) so every directory finds global CLIs. |
| `mise` | `~/.local/share/mise/shims` | Run `mise reshim` after every `npm install -g`. Confirm `~/.local/share/mise/shims` is on the login `PATH`, not only interactive `mise activate`. |
| `nvm` | `$NVM_DIR/versions/node/<ver>/bin` | `nvm` has no static shims and non-interactive shells skip `nvm.sh`. Set `nvm alias default <ver>` and ensure login shells load `nvm.sh` so the default `bin/` is on `PATH`. |
| `fnm` | dynamic per-shell dir | Ensure the login profile runs `eval "$(fnm env)"` and has a default alias (`fnm default <ver>`). |
| `volta` | `~/.volta/bin` | Static shims. Ensure `~/.volta/bin` is on the login `PATH`. |
| Homebrew / system | `/opt/homebrew/bin` or `/usr/local/bin` | Ensure `brew shellenv` runs in the login profile (`~/.zprofile` or `~/.profile`). |

Check: you know the user's login shell, Node manager, and where `node` and `npm prefix -g` live.

### 2. Get the binary and start the daemon with the right PATH

Find the platform with `uname -sm`. Each release at `https://github.com/svs/compos/releases` ships three binaries:

- `compos-VERSION-macos_arm`: macOS on Apple silicon (`Darwin arm64`).
- `compos-VERSION-linux`: Linux on x86_64 (`Linux x86_64`).
- `compos-VERSION-linux_arm`: Linux on arm64 (`Linux aarch64`).

Other platforms have no binary yet; tell the person and stop. Ask the person, then download the latest release binary into `~/.local/bin/compos` and make it executable:

```sh
mkdir -p ~/.local/bin ~/.local/state/compos
chmod +x ~/.local/bin/compos
xattr -d com.apple.quarantine ~/.local/bin/compos   # macOS only
```

The first run unpacks itself once and takes longer.

Check: `~/.local/bin/compos --version` answers.

Start the daemon in the background through the user's login shell so it inherits the full `PATH` (including Homebrew, `~/.local/bin`, `~/.antigravity/antigravity/bin`, and version-manager shims):

```sh
nohup "${SHELL:-/bin/zsh}" -lc 'ulimit -n 65536 2>/dev/null || ulimit -n 10240 2>/dev/null; exec ~/.local/bin/compos' >> ~/.local/state/compos/daemon.log 2>&1 </dev/null &
```

Wait until the HTTP server and Unix socket come up:

```sh
until [ -S ~/.local/state/compos/sock ] && curl -sf -o /dev/null http://localhost:4004/; do sleep 1; done
```

Open the editor in Chrome:

- macOS: `open -na "Google Chrome" --args --app=http://localhost:4004`
- Linux: `google-chrome --app=http://localhost:4004 &`

Without Chrome, any browser at `http://localhost:4004` works.

Where compos keeps its files:

- Config and packages: `~/.compos` (`init.scm`, `custom.scm`, `ai-config.scm`, `packages/`, `chrome-extension/`).
- Runtime state and sockets: `~/.local/state/compos` (`sock`, `sock-mcp`, `desktop.etf`, `daemon.log`, `daemons.json`).
- Cache: `~/.cache/compos` (`codex-home/`, `dsh-home/`, `model-catalog.scm`).

Check: `http://localhost:4004` responds with HTTP 200, `~/.local/state/compos/sock` exists, and the person sees the editor.

### 3. Connect your agent to the editor over MCP

The daemon exposes an MCP server on `~/.local/state/compos/sock-mcp` through a bundled stdio shim (`compos-mcp-shim`). Ask the running daemon for the exact shim path (this works for both the release binary and a source build):

```sh
SHIM=$(printf '%s
' '{"jsonrpc":"2.0","id":1,"method":"eval","params":{"code":"(priv-path \"native/compos-mcp-shim\")"}}' \
  | nc -U ~/.local/state/compos/sock \
  | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["result"].strip("\""))')
echo "$SHIM"
```

Register `compos` with the agent you are running inside:

- Claude Code: `claude mcp add --scope user compos -- "$SHIM"`
- Codex: `codex mcp add compos -- "$SHIM"`
- Antigravity or other MCP clients: add a stdio server named `compos` with command `"$SHIM"` and empty args.

Restart the agent session so it loads the new MCP server.

Check: the `eval-scheme` tool of the `compos` server answers `(setup-report)`. From here, do every editor configuration step in Scheme through `eval-scheme`. Do not edit `~/.compos/custom.scm` by hand.

### 4. Install and verify ACP connectors (Claude Code, Codex, Antigravity)

Ask the person which agent connectors they want to use:

- `claude-code` (Claude Code subscription)
- `codex-app-server` (ChatGPT / Codex subscription; do not use the deprecated `codex-acp`)
- `antigravity` (Google AI plan through `agy`)
- Or another connector (`opencode`, `opencode-go`, `gemini`, `kimi`, `api`, `gemini-nano`)

First, inspect the daemon's own `PATH` from inside compos:

```scheme
(getenv "PATH")
```

Confirm that the daemon's `PATH` contains the directories for `node` (if installing `claude-code` or `codex-app-server`) and any native CLI directory (`~/.local/bin`, `~/.antigravity/antigravity/bin`, etc.). If the daemon's `PATH` is missing required directories, fix the user's login shell profile first (after asking the user), then stop the old daemon cleanly and start a fresh one through `"$SHELL" -lc` as in step 2.

#### Node-based CLIs (`claude-agent-acp` and `codex`)

Always run `npm install -g` inside the user's login shell so it targets the same Node installation that the daemon sees:

1. Check `"$SHELL" -lc 'which node && node -v && npm prefix -g'`. If Node is missing, ask the user before installing Node (for example via `mise use -g node@lts`, `asdf`, or Homebrew `brew install node`).
2. After every `npm install -g`:
   - If using `asdf`: run `asdf reshim nodejs`.
   - If using `mise`: run `mise reshim`.
   - Confirm `$(npm prefix -g)/bin` (or the manager's shim directory) is in the daemon's `(getenv "PATH")`.
3. Warning for `asdf` and `mise` users: if a project folder contains `.tool-versions` or `mise.toml` with a different Node version, spawning `codex` or `claude-agent-acp` in that folder can fail because the global package is absent in that Node version. Fix this by either installing the CLI in that Node version too, setting a consistent global default, or pinning a standalone Node bin directory before shims when appropriate.

#### A. Claude Code (`claude-code`)

Claude Code requires two programs: the `claude` CLI and the `@agentclientprotocol/claude-agent-acp` adapter.

1. Install what is missing (ask the user first):

   ```sh
   "${SHELL:-/bin/zsh}" -lc '
     command -v claude >/dev/null || curl -fsSL https://claude.ai/install.sh | bash
     command -v claude-agent-acp >/dev/null || npm install -g --no-audit --no-fund @agentclientprotocol/claude-agent-acp
     command -v asdf >/dev/null && asdf reshim nodejs || true
     command -v mise >/dev/null && mise reshim || true
   '
   ```

2. Ask the person to sign in from a terminal if `claude auth status` reports not logged in:

   ```sh
   claude
   ```

3. Verify from the running daemon via `eval-scheme`:

   ```scheme
   (list (executable-find "claude") (executable-find "claude-agent-acp"))
   ```

   Also verify that both `node` and `claude` appear on `(getenv "PATH")`, not only in `setup-extra-program-dirs`. If the daemon started before `~/.local/bin` or Node was on `PATH`, restart the daemon from a fresh login shell.

#### B. Codex (`codex-app-server`)

Use the `codex-app-server` connector. Do not use `codex-acp` (deprecated).

1. Install `codex` if missing (ask the user first):

   ```sh
   "${SHELL:-/bin/zsh}" -lc '
     command -v codex >/dev/null || npm install -g @openai/codex
     command -v asdf >/dev/null && asdf reshim nodejs || true
     command -v mise >/dev/null && mise reshim || true
   '
   ```

2. Ask the person to sign in with their ChatGPT account:

   ```sh
   codex login
   ```

   `codex-app-server` uses the ChatGPT subscription login, not `OPENAI_API_KEY`. compos strips `OPENAI_API_KEY` and `OPENAI_BASE_URL` from Codex subprocesses on purpose.

3. Handle the sanitized `CODEX_HOME` trap: compos runs Codex with `CODEX_HOME` set to `(codex-home)` (default `~/.cache/compos/codex-home`) so personal skills and config do not leak into editor chats. compos copies `~/.codex/auth.json` once when `auth.json` is absent in `(codex-home)`. If the user signed in *after* compos first ran Codex, or if the token expired and Codex returns `401 Unauthorized`, ask the user to sign in directly to compos's Codex home:

   ```sh
   CODEX_HOME="$HOME/.cache/compos/codex-home" codex login
   ```

   (Use the exact path returned by `(codex-home)` if `COMPOS_HOME` or `COMPOS_CACHE_DIR` is custom.) Never read or print `auth.json`.

4. Verify from the running daemon via `eval-scheme`:

   ```scheme
   (list (executable-find "codex") (codex-home))
   ```

#### C. Antigravity (`antigravity` / `agy`)

Antigravity ships its own ACP server inside the `agy` CLI.

1. Install `agy` if missing (ask the user first):

   ```sh
   curl -fsSL https://antigravity.google/cli/install.sh | bash
   ```

   The installer writes `~/.antigravity/antigravity/bin/agy` and appends that directory to the user's shell rc file.

2. Ask the person to run `agy` in a terminal to complete Google AI sign-in.

3. Make sure the daemon can find `agy`. Because `~/.antigravity/antigravity/bin` is not in compos's built-in `setup-extra-program-dirs` and an already-running daemon does not reload `~/.zshrc`, do one of two things:
   - Preferred: stop the daemon and start it from a fresh login shell so `(getenv "PATH")` includes `~/.antigravity/antigravity/bin`.
   - Or pin the full command in `agent-connector-command-overrides` (keep all flags intact so `agy` connects to compos's MCP server without built-in tools or default rules):

     ```scheme
     (customize-save! 'agent-connector-command-overrides
       (cons (list "antigravity"
                   (string-append (getenv "HOME")
                     "/.antigravity/antigravity/bin/agy acp --process-per-session --agent compos --include-default-customizations=false"))
             (filter (lambda (e) (not (equal? (car e) "antigravity")))
                     agent-connector-command-overrides)))
     ```

4. Confirm the compos agent profile exists (`~/.gemini/config/agents/compos.md`). compos writes it at boot; verify and recreate it if missing:

   ```scheme
   (antigravity-agent-ensure!)
   (file-exists? antigravity-agent-file)
   ```

#### D. Other connectors

| Connector | Install | Sign-in or key |
| --- | --- | --- |
| `opencode` / `opencode-go` | Install `opencode` (`~/.opencode/bin/opencode`) | `opencode auth login` |
| `gemini` | `npm install -g @google/gemini-cli` (reshim if on `asdf`/`mise`) | `gemini` or `GEMINI_API_KEY` in `M-x setup` |
| `kimi` | `curl -fsSL https://code.kimi.com/kimi-code/install.sh | bash` | `kimi login` |
| `api` | No program needed | Add an Anthropic, OpenAI, OpenRouter, or DeepSeek key in `M-x setup` |
| `gemini-nano` | Chrome Prompt API | No key needed; requires a supported Chrome build |

#### E. Mandatory end-to-end test (do not trust scan alone)

`(setup-inference-scan)` only checks whether an executable or key exists. It does not prove that the daemon's `PATH` reaches `node` or `claude`, or that the user is signed in.

For every connector the user wants, run a real live test from `eval-scheme` (or tell the user to open `M-x llm-connectors` and press `t` on the row):

```scheme
(llm-connectors-test! "claude-code")
```

Wait a few seconds, then read back the test result:

```scheme
(llm-connectors-test-result "claude-code")
```

The connector is ready only when `status` is `ok` and `reply` holds real text.

When the preferred connector passes, make it the default for new chats:

```scheme
(setup-use-connector! "claude-code")
```

`(setup-use-connector! NAME)` updates `setup-default-connector`, `*default-connector*`, and `llm-default-bundle` together.

Check: `(llm-connectors-test-result NAME)` shows `status ok`, and `(setup-chosen-connector)` returns `NAME`.

### 5. Secret storage

`(setup-secret-backends)` lists the secret tools on this machine (Doppler, 1Password, GPG, macOS Keychain, Linux Secret Service) without reading any value. compos reads keys from the environment first, then key files in `~/.compos`, then Doppler. Ask the person which tool they use. Tell them to enter API keys only inside `M-x setup`.

Check: the Secret backends table in `(setup-report)` shows the chosen tool as ready.

### 6. Model presets and fast model without JEV

Each background job uses a named model preset (`default`, `fast`, `summarize`, `coding`). An empty preset falls back to the main session model, which makes summaries slow and expensive.

Inference alone is enough for compos to work. A decision model and embeddings are optional: without embeddings, `apropos` falls back to plain word matching, which works well. Do not stall the user on them.

JEV is not part of a fresh install. When JEV is absent:

1. Put the fast model of the provider the user already has (for example Claude Haiku, Codex's fast model, or Gemini Flash) into the `fast` and `summarize` roles of `llm-model-presets`.
2. Remove `jev` from `decide-backends`.
3. Set `command-palette-decide-backend` to `'model`.

Example for Anthropic:

```scheme
(customize-save! 'llm-model-presets
  '((default . "claude-sonnet-5-5")
    (fast . "claude-haiku-4-5-20251001")
    (summarize . "claude-haiku-4-5-20251001")
    (coding . "claude-opus-5-5")))
(customize-save! 'decide-backends (filter (lambda (b) (not (eq? b 'jev))) decide-backends))
(customize-save! 'command-palette-decide-backend 'model)
```

Check: `(llm-model-for 'fast)` names the fast model, and `decide-backends` does not contain `jev`.

### 7. Chrome extension: do not skip

The Chrome extension lets compos read and act inside the user's own Chrome with their active logins. compos copies the extension to `~/.compos/chrome-extension` on every start. Do not finish setup until it connects.

Walk the person through loading it:

1. Open `chrome://extensions` in Chrome.
2. Turn on **Developer mode** at the top right.
3. Click **Load unpacked** and choose `~/.compos/chrome-extension`. On macOS, press Cmd-Shift-G in the file picker to type the path.

Check: `(browser-connected?)` returns `#t`. If it returns `#f`, stay on this step and check [docs/FURTHER READING/CHROME_EXTENSION.md](<docs/FURTHER READING/CHROME_EXTENSION.md>).

### 8. Suggest a starter pack of packages

compos ships core features built in, while mail, web browsing, Google Workspace, calendar, feeds, and other apps ship as packages in the [compos-dev](https://github.com/compos-dev) GitHub organization. Do not install all packages, and do not leave the user with none.

1. Read the available packages: call `(packages-fetch-sources! K)` to fetch the catalog; K gets the rows (each row is a plist with `name`, `repo`, and `description`).
2. Ask the person what they want to use compos for: mail, web browsing, calendar and meetings, notes and tasks, coding, or messaging.
3. Recommend a short starter pack with one line per package explaining why it fits, and note external requirements (such as `notmuch` for mail or a Google account for Google Workspace).
4. Install only the packages the person accepts with `(package-install! NAME)`. That call clones the package, loads it, and adds its `use-package` line to `~/.compos/init.scm`.

Check: `(package-installed)` lists every package the person accepted. Tell them they can manage packages later in `M-x packages`.

### 9. Communications setup (email, Telegram, WhatsApp, iMessage)

Communications are one of compos's highest-value workflows, and each channel has its own setup trade-offs. Ask the person which channels they want to connect and never install a third-party messaging bridge without explaining its risks first.

#### Email (start here)

Offer the simplest path that fits the user's provider:

- **Gmail / Google Workspace (fastest, no local sync):** create a Desktop app OAuth client in a Google Cloud project belonging to the account's own organization (a client from another org's Internal project fails with `Error 403: org_internal`), save it to `~/.compos/google-client.json`, and run `M-x google-connect`. Add `(gmail "you@example.com")` to `notmuch-mailboxes` and `"gmail:you@example.com"` to `mail-feed-profiles` so `M-x mail` reads and sends directly over the Gmail API.
- **Gmail / Google Workspace (offline fast search):** install `notmuch` and `lieer` (`gmi`) instead of IMAP so multi-labeled messages download once and labels stay in two-way sync. Configure one notmuch profile per account (`~/.config/notmuch/PROFILE/config`) and route sends through `gmi send -t -C FOLDER` in `notmuch-send-routes`.
- **Other IMAP providers:** install `notmuch`, `mbsync`, and `msmtp`.

#### Telegram

Explain the two separate paths:

- **Talk to your compos agents from your phone (official, zero ToS risk):** install the `telegram` package, create a bot with `@BotFather`, store `TELEGRAM_BOT_TOKEN` through `M-x setup`, add the user's numeric Telegram ID to `telegram-allowed-users`, and enable `telegram-enabled`.
- **Read and reply to personal Telegram chats inside compos:** install `telegram-app` (`M-x telegram`), run its MTProto bridge (`bridge/bridge.py`) with official `api_id` and `api_hash` from `my.telegram.org`, and set `telegram-bridge-url` and `TELEGRAM_BRIDGE_TOKEN`.

#### WhatsApp (warn about unofficial CLIs, ToS, and legality first)

WhatsApp has no official personal-account API or CLI. Before connecting WhatsApp, clearly explain the choices and let the user decide:

- **Unofficial Linked Devices bridges (`whatsmeow`-based bridges such as `whatsapp-mcp` or `wacli`, Baileys Node bridges, or `mautrix-whatsapp`):** link via QR code and expose an MCP server that compos connects to in `~/.compos/ai-config.scm` (`(mcp-register! 'whatsapp ...)`). **Warn the user:** automated personal-account access violates WhatsApp's Terms of Service and can cause logouts, rate limits, or account bans (especially on bulk or rapid automated replies). Syncing third-party messages locally or sending transcripts to external LLM providers can also raise workplace, NDA, or privacy/compliance issues.
- **Official WhatsApp Business Cloud API:** Meta-sanctioned for registered business numbers, but does not access personal chat history.
- **Read-only via Chrome extension:** avoids running an unofficial protocol client by reading WhatsApp Web through the user's signed-in Chrome tab.

Never install a WhatsApp bridge silently, and keep outbound sends behind explicit human approval. Remember that compos marks chats woken by external `whatsapp:` or `mail:` events as `untrusted?` so agents stop and ask before sending, spending, or destroying.

#### iMessage and SMS (macOS only)

If the user is on macOS and wants iMessage/SMS (plus `M-x otp` for two-factor codes): add `(require 'imessage)` to `~/.compos/init.scm`, tell the user to grant Full Disk Access to compos (or its launching terminal) in System Settings -> Privacy & Security, and enable Text Message Forwarding on their iPhone for SMS.

Details for all channels: [docs/modes/notmuch-mode.md](docs/modes/notmuch-mode.md), [docs/modes/whatsapp-mode.md](docs/modes/whatsapp-mode.md), [docs/modes/telegram-mode.md](docs/modes/telegram-mode.md), [docs/modes/imessage-mode.md](docs/modes/imessage-mode.md), [docs/modes/irc-mode.md](docs/modes/irc-mode.md).

### 10. Final check and handover

Run `(setup-report)` and show the secret-free summary to the person. Confirm that their chosen connector passed `(llm-connectors-test! NAME)`, the Chrome extension is connected, and the starter pack is installed.

Then hand over:

- Tell them to run `M-x setup` if they still need to enter any API keys.
- Tell them to press `C-h t` for the interactive tutorial, or run `M-x onboarding` for a guided live walkthrough.
- Point them to [USER-GUIDE.md](USER-GUIDE.md) for everyday usage and shortcuts.

## Troubleshooting ACP connectors

| Symptom | Cause | Fix |
| --- | --- | --- |
| `agent adapter not found: claude-agent-acp` or `codex` or `agy` | Binary is not on the daemon's `PATH`, or `asdf`/`mise` was not reshimmed. | Run `asdf reshim nodejs` or `mise reshim`. Verify `(getenv "PATH")` in the daemon. Restart the daemon from a fresh login shell, or set `agent-connector-command-overrides`. |
| `env: node: No such file or directory` | Even with an absolute path to `claude-agent-acp` or `codex`, `node` is missing from the daemon's `PATH`. | Ensure the Node bin or shim dir is set in the login shell profile (`~/.zprofile`, `~/.zshrc`, `~/.bash_profile`) and relaunch the daemon via `"$SHELL" -lc`. |
| `claude-agent-acp` exits immediately or cannot find `claude` | `claude` CLI is not installed or `~/.local/bin` / `~/.claude/local` is not on daemon `PATH`. | Install `claude`, check `claude auth status`, and ensure `~/.local/bin` is on the daemon's `PATH`. |
| Codex fails with `401 Unauthorized` after `codex login` | compos's sanitized `(codex-home)` holds no `auth.json` or holds an expired copy. | Ask the user to run `CODEX_HOME="<path from (codex-home)>" codex login`. |
| Codex or Claude works in `~` but fails in a project directory | Project has `.tool-versions` or `mise.toml` pointing to a Node version that lacks the global npm package. | Install the CLI under that Node version too (then reshim), or pin a consistent global Node version. |
| `agy` fails or tries to run built-in shell tools | `~/.gemini/config/agents/compos.md` is missing, or override dropped the required flags. | Run `(antigravity-agent-ensure!)` and keep `--process-per-session --agent compos --include-default-customizations=false` on the command. |
| `M-x restart-daemon` did not pick up `PATH` changes | `restart-daemon` spawns the new process inside the old daemon's environment. | Stop the daemon and launch it again from a fresh login shell (`"$SHELL" -lc`). |
| `(setup-inference-scan)` shows ready, but chats fail | Scan checks file presence, not login or runtime execution. | Run `(llm-connectors-test! NAME)` (or `t` in `M-x llm-connectors`) and read the exact error in `(llm-connectors-test-result NAME)` or `C-h e` (`*Messages*`). |

## The command palette

Type a plain-English request in the command palette (`s-p` or `s-k`), for example "split this window vertically", and press `RET`. The palette picks the matching command, runs it, and remembers the phrase so future runs do not need a model call.

`command-palette-decide-backend` chooses what picks: `'jev`, `'model`, or `'local`. With `'local`, a small local model (`qwen3:4b` via `llama-server` on port 8089 or Ollama on 11434; configured with `do-backend` and `do-endpoint`) reads the command catalog and replies with one command name. The editor validates the reply against the live catalog before running it.
