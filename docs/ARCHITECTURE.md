# compos.el architecture

## The one rule

**Elixir supplies mechanism. Scheme decides policy.**

If it loops over bytes, parses, talks to an OS or a network — Elixir primitive.
If it decides what a key means, what a command does, how a buffer is presented —
Scheme, in `priv/*.scm` or your `~/.compos/*.scm`.

Policy is a convenience, not a security boundary. compos runs for a user who
already controls the machine; that user, their init file, and their agents can
invoke the mechanisms Scheme exposes, including processes and the shell. The
permission policy supplies useful defaults, prompts, and auditability, but it
is deliberately replaceable Scheme and must not be duplicated as hard-coded
principal checks in core. OS accounts, containers, and service credentials are
the security boundary when one is required.

Everything below follows from that.

`BEAM-POWER.md` says what "mechanism" means on this runtime: which OTP
patterns are load-bearing here, and the rules a new mechanism must follow.

## Layers

```
apps/compos_scheme    the extension language (no editor knowledge)
apps/compos_core      buffers, editor state, primitives, NIFs, processes
apps/compos_ui        Phoenix LiveView frontend (a client, not the editor)
apps/compos_rpc       JSON-RPC over ~/.compos/sock ("eval is the API")
```

### compos_scheme
R7RS-subset interpreter. Values **are** BEAM terms; closures are Scheme values;
TCO comes from
the BEAM. Symbols are `{:sym, name}` — never atoms (user code must not grow the
atom table). Host primitives are plain Elixir funs, `fun/1` (args) or `fun/2`
(args + interpreter store, for callbacks into Scheme).

Environment frames are reachability-collected. A closure exposed to a host
primitive or shared binding is published immediately, before the primitive can
dispatch it to another worker.

### compos_core
- **Buffer** — one GenServer per buffer: rope, point/mark, buffer-local vars,
  read-only flag, Emacs undo (undos push onto the same history; any other
  command breaks the chain, so undo-after-break = redo; 20-char insert
  amalgamation), per-window points (`win_points`, marker-adjusted with every
  edit; the selected window of the last-active frame is "swapped in" — its
  point IS the buffer point, Emacs-style). Every mutation broadcasts a change
  event **with provenance** (`:user | :editor | :process | {:agent, id}`).
  Provenance is load-bearing: it's how read-only works (only `:user` is
  blocked) and how the reactor avoids agent feedback loops.
- **Editor** — a map of **frames**, one per attached browser: each frame has
  its own window tree (ratio splits), active window, minibuffer
  (` *minibuf-<fid>*` backing buffer), echo, completion popup, viewport rows.
  Shared across frames: keymaps (global + buffer-local), faces, kill ring,
  MRU buffer ring. Window ids are global integers, so a bare id names one
  window anywhere; selecting a foreign window selects its frame. Clients
  attach by frame id (localStorage) and reattach across reloads and daemon
  restarts. Renders a per-frame *display payload*: only the visible slice of
  each window.
- **Frame / Input** — the dispatching frame rides the process dictionary
  (`Frame.current/0`); Input is the serialized input queue (one keystroke =
  one atomic multi-call dispatch), stamping the frame and bumping the frame
  MRU. Async work (timers, agents, RPC eval) falls back to the last-active
  frame; RPC can retarget with `(select-frame! id)`.
- **KeyDispatch** — runs in the *caller's* process (never inside Editor or
  Session), so commands can call both freely. Routes: minibuffer → completion
  popup → buffer keymap; breaks the undo chain for non-undo commands.
- **Session** — owns the Scheme interpreter; loads `priv/*.scm`, then
  `~/.compos/ai-config.scm`, then `~/.compos/init.scm`. All commands are Scheme
  closures in an ETS table. Ordinary evaluation can use compatibility lanes or
  one serial worker (`COMPOS_SCHEME_EXECUTION=single_actor`).
- **SchemeActor** — optional isolated Scheme processes. Each owns a private
  environment and serial mailbox. Only data crosses actor boundaries; buffers
  and other editor mechanisms remain shared services. See
  `docs/SCHEME-ACTORS.md`.
- **SchemeTask** — one-shot Scheme computations in supervised BEAM processes
  over the live shared environment. Explicit Scheme can fan out with task
  primitives; an LLM round automatically runs up to four `pure`/`read` tools
  concurrently. A global admission limit prevents simultaneous agents from
  multiplying that without bound. Tasks do not copy the booted Scheme world.
- **Telemetry** — a bounded core collector for every layer's events in one
  stream: `scheme` (lane jobs, tasks), `live` (the LiveView event, the
  EditorLive refresh split into state read and decorate, the render), and
  `browser` (the round trip of one push, the DOM patch, the paint from Event
  Timing, long tasks). A key or intent push carries a trace id, and the rows
  of one keystroke share it. `telemetry.scm` owns the list mode (`M-x
  telemetry`), filtering, thresholds, and commands.
- **TS** — Rustler NIF (`native/compos_ts`): highlight, structural nav, queries.
- **Proc** — PTY processes streaming into buffers (comint).
- **Endpoint** — named long-lived connections to the world outside the
  editor. Two transports (`exec` a subprocess, `tcp` a socket) and five
  framings (line, delimiter, content-length, length, raw) — `length`
  reads a binary length-prefixed protocol, so Elixir does the byte math
  and Scheme receives whole messages. It carries frames and
  holds no protocol: correlation is a serial ask queue with a sentinel, and
  what a frame means is Scheme policy. A connector for a database, a REPL,
  or a line-oriented service is a Scheme package over one endpoint, with no
  new Elixir. LSP and MCP predate it and still hand-roll the same shape.
- **WebServer** — named programmable inbound HTTP listeners. Each agent can
  start and stop its own Bandit server on a configured address and port.
  Elixir owns HTTP transport and parsing. One Scheme handler owns all routes
  and returns the status, headers, and body for each request.
- **BufferView** — the buffer read model. Each buffer publishes one public ETS
  row; every other process reads the row instead of sending the buffer a
  message. A render therefore never queues behind a reparse, a checkpoint, or a
  save in the buffer it draws. The buffer process stays the only writer, and it
  publishes before it announces the change. This process owns the table alone,
  so a buffer crash cannot take the model with it.
- **Reactor** — debounced buffer-change rules (the agent trigger primitive).
- **LLM** — one async primitive; provider routing; key resolution.
- **Desktop** — snapshot/restore of buffers, every frame's window tree
  (with per-window points), faces. v2 format; reads v1 single-tree files.

### compos_ui
Pure view. Receives the display payload, renders spans (font-lock scopes,
region, cursor overlays), pushes keys/geometry/scroll events back. Knows no
editor logic. A TUI or another frontend would consume the same payload.

### compos_rpc
`eval` is the whole API: agents script atomic multi-step actions in one
round-trip. Everything the GUI can do, the socket can do.

## What lives in Scheme today

All of it, and this is the point: commands, keybindings, modes + auto-mode,
hooks, dired (complete), themes, completion sources (capf), display-buffer
rules and popups, quit-window, the chat buffer, LLM pipes, isearch, file
completion. `priv/editor.scm`, `priv/dired.scm`, `priv/themes.scm`.

The rules each subsystem keeps are written down beside it: `docs/groups.md`
(groups and the current group), `docs/LISTS.md` (the list mode, pages, the
telemetry), `docs/BUFFER.md` (buffer state, the text scale), `docs/FACES.md` (faces, defaults, themes),
`docs/FILE-VIEW.md` (file modes, JSON formatting, and browser-native media),
`docs/MARKDOWN.md` (the rendered page, pictures and captions),
`docs/BLOCKS.md` (fenced-block kinds: one registration for paint and runner),
`docs/POPUPS.md` (the floating window), `docs/PEEK.md` (look without keeping),
`docs/EDITING-SURFACE-SPEC.md` (the input surface). When behaviour changes,
the document changes in the same commit.

One hook the editor itself runs: `window-configuration-changed!` (Emacs
`window-configuration-change-hook`). `Compos.Core.Editor` calls it from
its one commit point after every change of a frame's windows or their
buffers, whoever made the change, on that frame, and never on its own
process's time.

## LLM / agents: the plan

Current: `Compos.Core.LLM` — `(llm prompt handler)`, async, supervised, provider
routing by model prefix (`openrouter:` / `openai:` / bare = anthropic), keys
from env → `~/.compos/<provider>-key` → doppler. Everything else (chat buffer,
`M-|` pipes, model menu) is Scheme.

**Backend: adopt `req_llm`.** Hand-rolling providers stops paying as soon as we
want streaming, tool-calls, and usage accounting. `req_llm` is Req-based (we
already depend on Req), covers the providers, and keeps our surface intact:
`Compos.Core.LLM` stays the only Elixir-side LLM module and keeps exposing
`(llm ...)` — swapping the transport underneath changes no Scheme.

**Agents: don't adopt `jido`.** It's a well-built agent framework, but it brings
its own supervision, state, and scheduling model — and we already *are* one:
buffers are processes, the reactor is our trigger system, provenance is our
loop-prevention, human-gates are minibuffer prompts. Wrapping ours in theirs
would duplicate both. Revisit only if we want multi-node agent scheduling.

**Driving external agent CLIs (pi, codex, claude):** two mechanisms, both mostly
built:
1. **PTY/comint** (`Compos.Core.Proc`) — already works for any CLI; output
   streams into a buffer the reactor can watch. Good for chat-shaped tools.
2. **ACP/JSON-RPC over a port** — structured: the editor mediates file reads,
   permission prompts become minibuffer gates, progress becomes buffer updates.
   This is the compos `docs/ACP.md` design and the right home for pi/codex.
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
