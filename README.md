# compos

Emacs rebuilt on the BEAM.

Compos is a headless editor daemon in Elixir, scripted in Scheme, rendered
by the browser. The code keeps its working name: the apps, the env vars,
and `~/.compos` all say `compos`.

## Philosophy

Emacs has the right model for an agent harness. Buffers hold durable
application state. Windows compose views. Named commands give people and
agents one semantic action surface. Modes add contextual behavior, and the
Lisp runtime keeps the whole environment open to inspection and change.

The missing pieces are modern rendering and concurrency. Compos uses the
browser as a renderer without adopting the browser's closed application model.
The main window can show a rich application while chat remains beside it. The
agent manipulates the same buffers, windows, and commands that the person uses.
Elixir and OTP keep model streams, tools, terminals, and background work from
blocking the interface.

This approach also explains why we do not need a large plugin lifecycle
framework. JavaScript frameworks such as Cordis must reconstruct dynamic
composition above a module graph. Lisp starts with symbols, late binding, live
evaluation, and inspectable state. OTP owns the external resources that still
need explicit lifetimes.

Read the longer arguments:

- [The New Browser Was Emacs All Along](docs/EMACS-AS-AGENT-HARNESS.md)
- [Cordis, Lisp, and What JavaScript Has to Rebuild](docs/CORDIS-VS-EMACS.md)

## The one rule

**Elixir supplies mechanism. Scheme decides policy.**

Elixir owns the work that loops over bytes: ropes, tree-sitter, sockets,
PTYs, schedulers, the LLM transport. Scheme owns everything a person calls
"the editor": commands, keymaps, modes, hooks, themes, dired, org-mode,
chat, mail. That is 17,000 lines of Scheme in
`apps/compos_core/priv/*.scm`, and 321 commands. You redefine any of them
while the editor runs.

Before we add Elixir code, we ask one question: can this be Scheme plus one
small primitive? The answer is usually yes.

Policy is a convenience, not an OS security boundary. The user, their init
file, and their agents can invoke the mechanisms exposed to Scheme, including
processes and the shell. Permission prompts are useful, replaceable Scheme
guardrails; core does not hard-code a weaker mechanism surface for agents.
Use OS accounts, containers, and scoped credentials when isolation is needed.

## Why the BEAM

One GenServer holds each buffer. Agents are supervised processes. A blocking
tool call cannot freeze redisplay, because it blocks its own process and
nothing else. The core is a headless daemon, so every frontend is a client:
the browser, the desktop shell, `nc`, or an agent over JSON-RPC.

Every buffer mutation broadcasts a change event with **provenance** —
`:user`, `:editor`, `:process`, or `{:agent, id}`. Provenance is
load-bearing. Read-only buffers block `:user` edits only, and the reactor
ignores agent-sourced edits, so agents do not trigger themselves.

## What works

**Editing** — rope buffers, Emacs undo with amalgamation and
redo-after-break, mark and region, kill ring, isearch, completion in the
minibuffer and in the buffer, and per-window points that markers keep
correct across edits.

**Frames and windows** — tiling splits with ratio geometry. Each attached
browser gets its own frame, its own window tree, and its own minibuffer.
Clients reattach by frame id across page reloads and daemon restarts.

**Persistence** — everything survives a restart. `~/.compos/desktop.etf`
holds buffers, window trees, points, and faces. File buffers reopen from
disk. Chat and agent buffers restore their content and their local state.

**Tree-sitter** — a Rustler NIF gives font-lock, structural navigation, and
queries. `M-x ts-install-grammar` fetches a grammar from inside the editor.

**AI** — chat is the one conversation surface. It runs two lanes: a direct
lane over `req_llm` with native tool use, and an ACP lane that drives an
external agent CLI. Permission prompts become minibuffer gates. Tool calls
render as components in the buffer. `M-|` pipes a region through a model.

**Applications, all in userland Scheme** — org-mode, spreadsheets, notmuch
mail, git and diff-mode, project, per-agent git worktrees, an MCP client and
server hub, a GraphQL client, a Spotify remote, a writing workspace, a code
browser, dired, ibuffer, help, and Emacs-style customization.

**Packaging** — `mix release` builds a daemon. `bin/compos` starts it.
`COMPOS_APP_PORT` sets the port.

## Layout

```
apps/compos_scheme   the extension language: values are BEAM terms
apps/compos_core     buffers, editor state, primitives, NIFs, procs, LLM
  priv/*.scm        the editor itself
  native/compos_ts   tree-sitter Rustler NIF
apps/compos_ui       Phoenix LiveView frontend (a client — no editor logic)
apps/compos_rpc      JSON-RPC over ~/.compos/sock ("eval is the API")
```

Your config loads from `~/.compos/ai-config.scm`, then `~/.compos/init.scm`.
Both are optional.

## Run it

```sh
mix deps.get && mix test
mix run --no-halt
open -na "Google Chrome" --args --app=http://localhost:4004
```

The daemon reads `priv/*.scm` at boot, so a restart reloads them. Browser
clients reload themselves through a boot-id check.

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

In the window: `C-x 2/3/o/1/0` splits windows, `C-x C-f` finds a file,
`C-x C-s` saves, `C-x b` switches buffers, `C-k` and `C-y` kill and yank,
`C-/` undoes, `M-x` runs a command, and `M-:` evaluates Scheme.

## Drive it from outside

`eval` is the whole API. One round-trip runs any multi-step action:

```sh
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"eval","params":{"code":"(buffer-list)"}}' \
  | nc -U ~/.compos/sock
```

A **buffer link** is one string that names a buffer. `C-x l` copies an
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

Every public definition carries catalog metadata — a `domain!` and an
`effects!` scope. `M-x apropos` searches that catalog by words and, when an
OpenAI key is configured, by semantic similarity. Literal hits still rank
first; catalog vectors are cached on disk and regenerated with
`M-x apropos-rebuild-embeddings`. The Scheme API remains
`(apropos QUERY &rest FILTERS)`.

## Design commitments

1. **Tree-sitter is the sensor.** Buffers are syntax trees. Send the
   function, not the file.
2. **Scheme is the brain.** If an app could plausibly be written in Scheme,
   it is. Symbols are `{:sym, "name"}`, never atoms — user code must not
   grow the atom table.
3. **RPC first.** The socket predates the UI. Headless is the default, and
   MCP is a thin layer over the same core.
4. **Display list, not grid.** Frontends render `{text, face}` spans plus
   embedded components. A grid frontend degrades gracefully.
5. **Everything survives a reload.** A new buffer kind must keep this true.

## Known limitations

- **Env frames are never collected.** Every closure call adds a frame to the
  interpreter store, so long sessions grow. The fix is a reachability sweep
  or ETS-backed envs.
- The rope has no rebalancing.
- The Scheme has no `define-syntax` and no continuations.
- RPC is newline-delimited and has no auth. Keep it on the local socket.

## Documentation

`docs/` holds the architecture, the roadmap, the component contract, and the
current handoff. Read [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) first.

## License

Compos is free software under the GNU General Public License, version 3 or later.
See [`LICENSE`](LICENSE).
