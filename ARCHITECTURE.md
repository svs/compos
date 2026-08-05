# ai-max.el architecture

## The one rule

**Elixir supplies mechanism. Scheme decides policy.**

If it loops over bytes, parses, talks to an OS or a network — Elixir primitive.
If it decides what a key means, what a command does, how a buffer is presented —
Scheme, in `priv/*.scm` or your `~/.aimax/*.scm`.

Everything below follows from that.

## Layers

```
apps/aimax_scheme    the extension language (no editor knowledge)
apps/aimax_core      buffers, editor state, primitives, NIFs, processes
apps/aimax_ui        Phoenix LiveView frontend (a client, not the editor)
apps/aimax_rpc       JSON-RPC over ~/.aimax/sock ("eval is the API")
```

### aimax_scheme
R7RS-subset interpreter. Values **are** BEAM terms; closures are funs; TCO from
the BEAM. Symbols are `{:sym, name}` — never atoms (user code must not grow the
atom table). Host primitives are plain Elixir funs, `fun/1` (args) or `fun/2`
(args + interpreter store, for callbacks into Scheme).

Known debt: env frames are never collected — long sessions grow.

### aimax_core
- **Buffer** — one GenServer per buffer: rope, point/mark, buffer-local vars,
  read-only flag, Emacs undo (undos push onto the same history; any other
  command breaks the chain, so undo-after-break = redo; 20-char insert
  amalgamation). Every mutation broadcasts a change event **with provenance**
  (`:user | :editor | :process | {:agent, id}`). Provenance is load-bearing:
  it's how read-only works (only `:user` is blocked) and how the reactor avoids
  agent feedback loops.
- **Editor** — window tree (ratio splits), active window, keymaps (global +
  buffer-local), minibuffer state, completion popup state, faces, kill ring,
  MRU buffer ring, viewport rows. Renders a *display payload*: only the visible
  slice of each window.
- **KeyDispatch** — runs in the *caller's* process (never inside Editor or
  Session), so commands can call both freely. Routes: minibuffer → completion
  popup → buffer keymap; breaks the undo chain for non-undo commands.
- **Session** — owns the Scheme interpreter; loads `priv/*.scm`, then
  `~/.aimax/ai-config.scm`, then `~/.aimax/init.scm`. All commands are Scheme
  closures in an ETS table.
- **TS** — Rustler NIF (`native/aimax_ts`): highlight, structural nav, queries.
- **Proc** — PTY processes streaming into buffers (comint).
- **Reactor** — debounced buffer-change rules (the agent trigger primitive).
- **LLM** — one async primitive; provider routing; key resolution.
- **Desktop** — snapshot/restore of buffers, window tree, faces.

### aimax_ui
Pure view. Receives the display payload, renders spans (font-lock scopes,
region, cursor overlays), pushes keys/geometry/scroll events back. Knows no
editor logic. A TUI or another frontend would consume the same payload.

### aimax_rpc
`eval` is the whole API: agents script atomic multi-step actions in one
round-trip. Everything the GUI can do, the socket can do.

## What lives in Scheme today

All of it, and this is the point: commands, keybindings, modes + auto-mode,
hooks, dired (complete), themes, completion sources (capf), display-buffer
rules and popups, quit-window, the chat buffer, LLM pipes, isearch, file
completion. `priv/editor.scm`, `priv/dired.scm`, `priv/themes.scm`.

## LLM / agents: the plan

Current: `Aimax.Core.LLM` — `(llm prompt handler)`, async, supervised, provider
routing by model prefix (`openrouter:` / `openai:` / bare = anthropic), keys
from env → `~/.aimax/<provider>-key` → doppler. Everything else (chat buffer,
`M-|` pipes, model menu) is Scheme.

**Backend: adopt `req_llm`.** Hand-rolling providers stops paying as soon as we
want streaming, tool-calls, and usage accounting. `req_llm` is Req-based (we
already depend on Req), covers the providers, and keeps our surface intact:
`Aimax.Core.LLM` stays the only Elixir-side LLM module and keeps exposing
`(llm ...)` — swapping the transport underneath changes no Scheme.

**Agents: don't adopt `jido`.** It's a well-built agent framework, but it brings
its own supervision, state, and scheduling model — and we already *are* one:
buffers are processes, the reactor is our trigger system, provenance is our
loop-prevention, human-gates are minibuffer prompts. Wrapping ours in theirs
would duplicate both. Revisit only if we want multi-node agent scheduling.

**Driving external agent CLIs (pi, codex, claude):** two mechanisms, both mostly
built:
1. **PTY/comint** (`Aimax.Core.Proc`) — already works for any CLI; output
   streams into a buffer the reactor can watch. Good for chat-shaped tools.
2. **ACP/JSON-RPC over a port** — structured: the editor mediates file reads,
   permission prompts become minibuffer gates, progress becomes buffer updates.
   This is the aimax `docs/ACP.md` design and the right home for pi/codex.
   Needs: a `Port`-based JSON-RPC client primitive (~100 lines Elixir), then the
   session/permission/tool-dispatch logic in Scheme — `acp.scm` next to
   `dired.scm`.

Inverse direction: **MCP server** over the existing RPC core, so external agents
drive *us* — tools = the semantic layer (`buffer-read`, `ts-query`,
`semantic-replace`), with `eval` gated behind confirmation.

## Ordering principle

Anything an app could plausibly be — mail, agents, LSP UI, dired — is Scheme.
Elixir grows only when Scheme physically can't do it: a NIF, a socket, a PTY, a
parser, a scheduler.
