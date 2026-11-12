# Develop compos

This file is for a person who works on the compos source. To build and run from source the first time, see [INSTALL.md](INSTALL.md). To install the binary, see [SETUP.md](SETUP.md).

## Run from source

```sh
mix deps.get && mix test
mix run --no-halt
open -na "Google Chrome" --args --app=http://localhost:4004
```

The daemon watches `apps/*/lib`, `apps/compos_core/priv`, `scheme/`, and the
config home. When you save a file, the daemon reloads it without a restart.
Browser clients reload themselves through a boot-id check.

Each daemon records its name and URL in `~/.compos/daemons.json`. Run another
daemon with a different home and port, then use `C-x d` to switch the current
browser tab. Set `COMPOS_DAEMON_REGISTRY` when the daemons must share another
registry path.

```sh
COMPOS_HOME=~/.compos-feature COMPOS_PORT=4014 COMPOS_APP_PORT=4015 \
  COMPOS_NAME=feature COMPOS_ACCENT="#3f7cac" mix run --no-halt
```

`COMPOS_ACCENT` adds a persistent colored frame and instance label. Use a
six-digit CSS hex color so each daemon has a stable visual identity.

## Repository layout

```
apps/compos_scheme   the extension language: values are BEAM terms
apps/compos_core     buffers, editor state, primitives, NIFs, procs, LLM
  priv/*.scm        the kernel: editor.scm, dired, themes, init.scm
  native/compos_ts   tree-sitter Rustler NIF
apps/compos_ui       Phoenix LiveView frontend (a client — no editor logic)
scheme/packages      every package: commands, modes, chat
scheme/apps          the apps (ats, spotify, slides, ...): one more place to load and autoload from
apps/compos_rpc      JSON-RPC over ~/.compos/sock ("eval is the API")
```

Your config loads from `~/.compos/ai-config.scm`, then `~/.compos/init.scm`,
then the saved `~/.compos/custom.scm`. All three are optional.

## Philosophy

Emacs has the right model for an agent harness. Buffers hold durable application state. Windows compose views. Named commands give people and agents one semantic action surface. Modes add contextual behavior, and the Lisp runtime keeps the whole environment open to inspection and change.

The missing pieces are modern rendering and concurrency. Compos uses the browser as a renderer without adopting the browser's closed application model. The main window can show a rich application while chat remains beside it. The agent manipulates the same buffers, windows, and commands that the person uses.

Elixir and OTP keep model streams, tools, terminals, and background work from blocking the interface.

This approach also explains why we do not need a large plugin lifecycle framework. JavaScript frameworks such as Cordis must reconstruct dynamic composition above a module graph. Lisp starts with symbols, late binding, live evaluation, and inspectable state. OTP owns the external resources that still
need explicit lifetimes.

Read the longer arguments:

- [The New Browser Was Emacs All Along](docs/EMACS-AS-AGENT-HARNESS.md)
- [Cordis, Lisp, and What JavaScript Has to Rebuild](docs/CORDIS-VS-EMACS.md)

## The one rule

**Elixir supplies mechanism. Scheme decides policy.**

Elixir owns the work that loops over bytes: ropes, tree-sitter, sockets, PTYs, schedulers, the LLM transport. Scheme owns everything a person calls "the editor": commands, keymaps, modes, hooks, themes, dired, org-mode, chat, mail. That is about 117,000 lines of Scheme in `apps/compos_core/priv/*.scm` and `scheme/packages/*.scm`, and more than 1,000 commands. You redefine any of them while the editor runs.

Before we add Elixir code, we ask one question: can this be Scheme plus one small primitive? The answer is usually yes.

Policy is a convenience, not an OS security boundary. The user, their init file, and their agents can invoke the mechanisms exposed to Scheme, including processes and the shell. Permission prompts are useful, replaceable Scheme guardrails; core does not hard-code a weaker mechanism surface for agents.

Use OS accounts, containers, and scoped credentials when isolation is needed.

## Why the BEAM

One GenServer holds each buffer. Agents are supervised processes. A blocking tool call cannot freeze redisplay, because it blocks its own process and nothing else. The core is a headless daemon, so every frontend is a client: the browser, the desktop shell, `nc`, or an agent over JSON-RPC.

Every buffer mutation broadcasts a change event with **provenance** —
`:user`, `:editor`, `:process`, or `{:agent, id}`. Provenance is
load-bearing. Read-only buffers block `:user` edits only, and the reactor ignores agent-sourced edits, so agents do not trigger themselves.

## Drive it from outside

`eval` is the whole API. One round-trip runs any multi-step action:

```sh
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"eval","params":{"code":"(buffer-list)"}}' \
  | nc -U ~/.compos/sock
```

A **buffer link** is one string that names a buffer. `C-c l` copies an
`compos://` link for the current buffer and line. The link includes the daemon's
socket, so it returns to the instance that created it. On macOS, register the
protocol handler once:

```sh
bin/install-compos-url-handler
```

Open the same buffer name under `/raw/` to read its text:

```sh
curl -s http://localhost:4004/raw            # every buffer name, one per line
curl -s http://localhost:4004/raw/%2Ftmp%2Fnotes.md
```

## Extend it

A command is a Scheme definition. Evaluate this with `M-:` and the editor
has it — no restart, no compile step:

```scheme
(domain! 'text)
(effects! '(write))

(define-command "insert-buffer-name" "Insert the name of this buffer"
  (lambda () (insert! (current-buffer))))

(global-set-key "C-c n" "insert-buffer-name")
```

A project can carry live editor policy in `compos.scm` at its Git root. Compos
evaluates it with each buffer opened from that project as the current buffer,
including new chats and other non-file buffers that inherit the project's
directory. It is ordinary Scheme, so it can do anything the editor API allows.
For LLM defaults that new chat buffers should inherit without overriding later
per-buffer choices, use:

```scheme
(project-defaults!
  'llm-connector "codex-app-server"
  'llm-model "gpt-5.6-sol"
  'llm-effort "high")
```

Every public definition carries catalog metadata — a `domain!` and an effects!` scope. `M-x apropos` searches that catalog by words and, when OpenRouter or OpenAI has a key (`apropos-embedding-backends`, chosen in `M-x setup`), by semantic similarity. Literal hits still rank first; catalog vectors are synchronized in the background when public entries
change, cached on disk, and regenerated explicitly with
`M-x apropos-rebuild-embeddings`. Foreground lookup embeds only the query. The Scheme API remains
`(apropos QUERY &rest FILTERS)`.

## Design commitments

1. **Tree-sitter is the sensor.** Buffers are syntax trees. Send the
   function, not the file.
2. **Scheme is the brain.** If an app could plausibly be written in Scheme, it is. Symbols are `{:sym, "name"}`, never atoms — user code must not
   grow the atom table.
3. **RPC first.** The socket predates the UI. Headless is the default, and MCP is a thin layer over the same core.
4. **Display list, not grid.** Frontends render `{text, face}` spans plus embedded components. A grid frontend degrades gracefully.
5. **Everything survives a reload.** A new buffer kind must keep this true.

## Known limitations

- The Scheme has no `define-syntax` and no continuations.
- RPC is newline-delimited and has no auth. Keep it on the local socket.
And probably a thousand more. This is still alpha software.

