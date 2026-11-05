# Install compos

This file is for an AI agent. A person points the agent at this repository and says "install compos". Do the steps in order. Each step says how to check it. Stop and tell the person when a check fails.

Rules for the agent:

- Do not read, print, or store a secret value. The person types each key into `M-x setup`. You only check that a key is there.
- Ask the person before you install software system-wide.
- Run the daemon in the background. Do not block on it.

## 1. Prerequisites

| Tool | Why | Check |
|---|---|---|
| Erlang/OTP and Elixir 1.19 or later | the daemon | `elixir --version` |
| Rust (`cargo`) | the compile builds the MCP shim, `native/compos_mcp_shim` | `cargo --version` |
| Node and `npm` | the agent connectors install with `npm install -g` | `npm --version` |
| git | the clone | `git --version` |
| Google Chrome | the client window | the app opens |
| Python 3.12 (Apple silicon only) | laya, the on-device decision model (step 7) | `python3 --version` |

## 2. Clone, build, run

```sh
git clone <REPO-URL> compos
cd compos
mix deps.get
mix compile
mix run --no-halt   # in the background; it serves http://localhost:4004
open -na "Google Chrome" --args --app=http://localhost:4004
```

Check: `http://localhost:4004` answers, and the person sees the editor. The daemon keeps its state in `~/.compos`. Set `COMPOS_HOME` and `COMPOS_PORT` to run a second daemon beside it.

## 3. Connect the agent to the editor

The editor is an MCP server. Its stdio shim is `apps/compos_core/priv/native/compos-mcp-shim`. The compile in step 2 builds it. For Claude Code:

```sh
claude mcp add --scope user compos -- "$PWD/apps/compos_core/priv/native/compos-mcp-shim"
```

Restart the agent session. Check: the `eval-scheme` tool of the `compos` server answers `(setup-report)`. From here, do every step in Scheme through `eval-scheme`. Do not edit files in `~/.compos` by hand.

## 4. The chat connector

A connector is the agent program that a chat runs, for example Claude Code, Codex, or Gemini.

1. `(setup-inference-scan)` gives one row per connector: `(NAME KIND READY? DETAIL NEXT)`.
2. Ask the person which connector they want.
3. If the row is not ready and NEXT names install steps, run `(setup-install-agent! NAME)`. It runs the `npm install -g` steps in a buffer.
4. If the connector needs a login or a key, tell the person to run `M-x setup` and press the key button on its card. The person signs in or types the key there.
5. `(customize-save! 'setup-default-connector NAME)`

Check: `(setup-complete?)` answers `#t`.

## 5. Secret storage

`(setup-secret-backends)` lists the secret tools on this machine: Doppler, 1Password, GPG, macOS Keychain, Linux Secret Service. Keys are read from the environment first, then the key files in `~/.compos`, then Doppler. Ask the person which tool they use. `M-x setup` stores each key with that tool.

Check: the Secret backends table of `(setup-report)` shows the chosen tool as ready.

## 6. Model presets

Each job uses a named preset. An empty preset uses the session model. The cost of empty presets is high: summaries run all the time, and on the default model they cost much more.

| Preset | Used for |
|---|---|
| `default` | new chats, and every job that names no preset |
| `fast` | short jobs, and the `haiku` backend of the decision model |
| `summarize` | running summaries, code browser summaries, content-scale |
| `coding` | code agents |

Fill all four from the provider of step 4: a large model for `default`, a small model for `fast` and `summarize`, the largest model for `coding`. For Anthropic:

```scheme
(customize-save! 'llm-model-presets
  '((default . "claude-sonnet-5-5") (fast . "claude-haiku-4-5-20251001")
    (summarize . "claude-haiku-4-5-20251001") (coding . "claude-opus-5-5")))
```

Check: `(llm-model-for 'fast)`, `(llm-model-for 'summarize)` and `(llm-model-for 'default)` each give the model you set.

## 7. Decision model

The editor asks the decision model short typed questions: yes or no, pick one, give a score. The shell gate of the agents asks it about each shell command. `decide-backends` lists the backends in the order that they are tried. A fresh install must have one backend that works.

- `laya`: the model on this machine. It needs Apple silicon, a python with the `laya_mlx` package, and a laya checkpoint.
- `haiku`: a hosted model. It needs an Anthropic key, and it uses the `fast` preset.
- `jev`: a user package. A fresh install does not have it. Remove it from the list.

For laya:

1. Install the `laya_mlx` package into a Python 3.12. TODO: the source of the package.
2. Download the checkpoint into the Hugging Face cache: `huggingface-cli download aac6fef/laya-mlx`. A directory in `LAYA_MODEL_DIRS` also works.
3. `(customize-save! 'laya-python "/path/to/python3")`
4. Check: `(laya-available?)` answers `#t`. `M-x laya-server` starts the daemon and says where it stands.

Then set the order, with only the backends that work:

```scheme
(customize-save! 'decide-backends '(laya haiku))
(customize-save! 'decide-default '((fast . laya)))
```

Check: `(decide "The sky is blue." (list 'q (decide-noul "Is the sky blue?")) 'purpose 'fast)` gives `(answers ...)` and no error. The usage part names the backend that answered.

## 8. Hand over to the person

Tell the person to run `M-x setup`. Step one shows the connector cards; the choice from step 4 is marked. Step two opens `M-x onboarding`: a guide chat beside a stage window. Setup also sets the window layout to `columns`.

## 9. Optional

Do these only when the person asks.

- Calendar (macOS): the daemon runs as a background process, and macOS does not ask it for calendar access. `(calendar-agent-install!)` installs a LaunchAgent in the GUI session.
- iMessage (macOS): give compos Full Disk Access in System Settings.
- Mail: install notmuch and set up its profile.
- MCP servers: add each server in `M-x mcp-hub`, with its key in the secret tool.

## Final check

`(setup-report)` shows each row of Inference, Secret backends and Connectors that the person needs as ready. Give the person this report. It holds no secret values.
