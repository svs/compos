# ai-max.el

**Scheme is the brain. The BEAM is the muscle.**

The [aimax](../aimax) Work OS vision, rebuilt on Elixir/OTP: a programmable
workspace where AI agents are first-class citizens — buffers as processes,
Scheme as the extension language, everything driveable over RPC.

Why BEAM: everything aimax's Rust core fought for by hand (snapshot-actor,
action queues, never-block-the-main-thread, thread-per-PTY-reader) is the
BEAM's native model. Buffers are GenServers, agents are supervised processes,
a blocking tool call cannot freeze the UI, and client-server is the default —
the core is a headless daemon; every frontend (LiveView desktop shell,
browser, TUI, MCP agent, `nc`) is just another client.

## Layout

    apps/aimax_scheme   the extension language: a Scheme whose values are BEAM terms
    apps/aimax_core     buffers (rope + change events), reactor (reactive rules),
                        session (the interp wired to editor primitives), tree-sitter (stub)
    apps/aimax_rpc      JSON-RPC 2.0 over Unix socket — "eval is the API"

## Try it

    mix deps.get && mix test        # 75 tests
    mix run --no-halt               # core + rpc (~/.aimax/sock) + window (http://localhost:4004)
    open -na "Google Chrome" --args --app=http://localhost:4004   # app-mode window

In the window: type, `C-x 2/3/o/1/0` tiling splits, `C-x C-f` find-file,
`C-x C-s` save, `C-x b` buffers, `C-k`/`C-y` kill/yank, `C-/` undo,
`M-x` commands, `M-:` eval Scheme. All of it defined in
`apps/aimax_core/priv/editor.scm` — redefine live via `M-:` or RPC.

    echo '{"jsonrpc":"2.0","id":1,"method":"eval","params":{"code":"(begin (buffer-create \"*x*\") (buffer-append! \"*x*\" \"hi\") (buffer-text \"*x*\"))"}}' | nc -U ~/.aimax/sock

From Scheme (via RPC, `Session.eval/1`, or eventually `M-:`): `buffer-create`,
`buffer-append!`, `buffer-text`, `find-file`, `eval-region`, `eval-buffer`,
`(message ...)` → `*messages*` (the echo area is a *view* of that buffer).

Reactive rules (the orchestrator trigger primitive, Elixir API for now):

```elixir
Aimax.Core.Reactor.on_change("*prod-log*", {:contains, "ERROR"},
  fn changes -> spawn_triage_agent(changes) end,
  debounce: 500)
```

Rules ignore agent-sourced edits by default (provenance-based loop prevention);
`{:ts_query, ...}` matchers arrive with the tree-sitter NIF.

## Design commitments (from ../aimax/docs + this port's decisions)

1. **Tree-sitter is the sensor** — buffers are syntax trees; zero-leak context
   (send the function, not the file); ts-query filters at ingestion.
2. **Scheme is the brain** — dired must be writable in userland Scheme.
   Symbols are `{:sym, "name"}`, never atoms.
3. **RPC-first** — the socket predates the UI; headless is the default, MCP is
   a thin layer over the same core; human-gates before destructive agent tools.
4. **Display list, not grid** — frontends render `{text, face}` spans plus
   embedded components (checkbox, chart, button). Excellent formatting via
   HTML/CSS (Phoenix LiveView + desktop shell); grid frontends degrade
   gracefully.

## Roadmap

- [x] Scheme kernel (reader, TCO evaluator, closures/set!, prelude, host interop)
- [x] Buffers, change events with provenance, debounced reactor, session, RPC eval
- [ ] Tree-sitter Rustler NIF (`Aimax.Core.TreeSitter` has the plan) + `{:ts_query, ...}` matchers
- [ ] `watch-file` / tail ingestion + filter chains
- [ ] Scheme surface: `define-command`, keymaps, hooks, `on-buffer-change`, fs primitives (dired bar)
- [ ] Agent runtime: `define-agent`, streaming LLM client, `->`/`parallel`/`human-gate` flows
- [ ] MCP server over the RPC core; ACP client for external agents
- [ ] LiveView frontend: display-list redisplay, minibuffer, echo area, geometry queries
- [ ] Undo (persistent ropes make this cheap), marks, text properties

## Known limitations (deliberate, tracked)

- **Env frames are never GC'd** — every closure call adds a frame to the
  interpreter's store; long-lived sessions grow. Fix: reachability sweep or
  ETS-backed envs. Fine for now, wrong forever.
- Rope has no rebalancing or line index yet; byte offsets only.
- No macros (`define-syntax`), no continuations — decide before the Scheme
  surface grows users.
- RPC is newline-delimited: multi-line payloads must be JSON-encoded (fine),
  and there's no auth (localhost socket only until there is).
