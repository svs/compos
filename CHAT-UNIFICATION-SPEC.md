# Spec: one chat, one send path (collapse the api/llm fork)

Status: proposed, not started. Written 2026-08-08 for a fresh context.
Prereqs already landed: `693e0d3` (only chat, no `*agent:*` surface),
`e4e23a4` (tool loop serves every provider), `ec8cba3` (backend switch
rebinds RET).

## The problem

A chat has two possible send paths, and they have complementary holes:

| | "api" backend (`chat-send`) | "llm" connector (`agent-send`) |
|---|---|---|
| tools | yes (`llm-tools`, every provider) | **no** (`LLM.request`, plain completion) |
| queue while running | **no** | yes |
| `C-RET` interrupt / revive | **no** | yes |
| block rendering (tool cards) | partial | yes |
| cost tracking | yes | no |
| history | `chat-turns` | its own list in `agent.ex` |

Same engine underneath (`Aimax.Core.LLM`), two wrappers built at
different times. Every feature must be written twice, and the seams leak:
the RET-dead bug (`ec8cba3`), the "not an agent buffer" refusals, the
model label drift, the reset/seed divergence. `chat-send` branching on
`agent-slug` is the smell.

## The target

**Every chat is a thread.** One send path, one history, one set of keys.
The backend (claude-code / codex / api) is a *connector*, nothing more.

- `RET` always → `agent-send` → `agent-send-msg!`. Queue, interrupt,
  revive, block rendering work identically on every backend.
- The `api` choice in `chat-set-backend` attaches the **`llm` connector**
  instead of clearing `agent-slug`. There is no "no backend" state.
- `chat-send`, `chat-send-plain!`, `chat-send-rich!`, `chat-llm`,
  `chat-llm-rich`, and the `agent-slug` branch all die.

## Work

### 1. Teach the in-process llm runtime the tool loop (Elixir)

`agent.ex` `:llm`-type threads call `LLM.request(llm_prompt(history))`
(~line 572). Move them to `LLM.complete_tools/6` with:

- specs: the Scheme registry — the runtime needs the same list
  `chat-llm` built: `(append (llm-tool-specs) (chat-extra-specs buf))`.
  Simplest: Scheme passes the specs + dispatcher closure in the config
  plist at `agent-start!` time (it already passes `presets`).
- dispatcher: `llm-tool-call` (or `chat-tool-dispatch` for buffer-scoped
  read-doc/edit-doc — see §3).
- emit agent events per tool call so the block renderer shows tool cards:
  reuse the ACP event shapes (`type: :tool-call` / `:tool-update`) so
  `agent-handle-event` needs no new branches.
- `:on_usage` → a `model-state`-style event or direct
  `chat-usage-note!`, so cost tracking survives the move.

Permissions: ACP threads gate tool calls through `session/request_permission`.
Decide explicitly — either the llm lane runs ungated (document it), or
emit a `permission` event before dispatching non-read tools. Ungated is
fine to start; the tools are local and the user typed the request.

### 2. Rewire the Scheme side

- `chat-set-backend`: `"api"` → `(chat-attach-agent! buf "llm")`. Drop
  the slug-clearing branch entirely.
- `chat-send`: delete. `chat-mode` binds `RET` to `agent-send` always
  (via `agent-install-keys!`), for every chat.
- Delete `chat-send-plain!` / `chat-send-rich!` / `chat-llm` /
  `chat-llm-rich` once nothing calls them. `chat-preamble` stays — it
  becomes the llm connector's system prompt, passed at attach time.
- History: `chat-turns` is canonical (it already feeds `chat-flatten`
  for `.chat` save and `agent-seed-transcript` for model switches).
  Push turns from `agent-handle-event` for every backend, not just the
  chat path.

### 3. Buffer-scoped tools

`chat-tool-dispatch` scopes `read-doc`/`edit-doc` to the chat's group.
The llm runtime must dispatch through the same closure, so the specs +
dispatcher have to be per-buffer (config plist at attach), not global.

### 4. Migration / restore

- Existing chats with `agent-slug: #f` (api-backed) must attach the llm
  connector on first send or on `chat-mode` setup — no buffer should sit
  in the old no-backend state after restore.
- Desktop restore: unchanged otherwise; the runtime never survives, the
  transcript does, `agent-send` revives.

## Tests to write

1. An api-backed chat runs a tool call end to end (stub `:llm_chat_fun`,
   assert the tool ran and a tool block rendered).
2. `RET` queues while an api-backed chat is running; the queue pops on
   turn end (mirror of the existing ACP steering test).
3. `C-RET` interrupts an api-backed turn.
4. Switching backends mid-conversation keeps `chat-turns` and reseeds the
   new session with the whole chat (existing seed test, both directions).
5. Cost tracking still lands on `chat-cost` in the llm lane.
6. No buffer ends up with `agent-slug: #f` after `chat-set-backend api`.

## Definition of done

- `grep -n "chat-send\b\|chat-llm\b\|chat-send-plain\|chat-send-rich"
  priv/editor.scm` returns nothing.
- The `agent-slug` branch in `chat-send` is gone because `chat-send` is
  gone.
- Every chat, whatever the backend: tools, queue, interrupt, revive,
  cost, `.chat` save, whole-chat model switching.

## Phase 2: one runtime, many backends (ACP included)

Phase 1 makes every chat a thread. Phase 2 makes every *backend* a
module behind one behaviour, so ACP is not privileged — it is one
implementation among several.

### Why it's cheap

`agent.ex` is ~693 lines. Backend-agnostic already: the status machine
(`starting/idle/running/needs_attention/dead`), the prompt queue, event
batching to the buffer, mark/append rendering, permission bookkeeping,
info/kill. ACP-specific: `request/notify/respond/send_frame`,
`handle_frame`, `handle_update`, `acp_servers` — roughly lines 300–560.
And a second backend already lives inside (`{:llm_reply, …}`), proving
the runtime does not care where events come from. There is also already
a `Transport` behaviour one level below (stdio vs the test fake), so the
pattern is established.

### The contract

```elixir
@behaviour Aimax.Core.Agent.Backend

@callback start(config :: map, owner :: pid) :: {:ok, handle} | {:error, term}
@callback prompt(handle, text :: String.t()) :: :ok
@callback cancel(handle) :: :ok
@callback close(handle) :: :ok
# optional, guarded by capabilities/0
@callback set_model(handle, model_id :: String.t()) :: :ok
@callback respond_permission(handle, id :: term, option :: String.t() | nil) :: :ok
@callback capabilities() :: [:models | :permissions | :slash_commands | :resume | :tools]
```

Backends send the owner `{:agent_event, event}` — and **the event
vocabulary is the real contract**, not the callbacks. It already exists
(ACP's shapes, flattened into plists by `plist/1`): `chunk`, `thought`,
`tool-call`, `tool-update`, `plan`, `permission`, `user-msg`,
`turn-end`, `error`, `model-state`, `status`. Any backend that emits
those renders correctly with zero Scheme changes — that is the whole
trick.

Implementations:

- `Backend.ACP` — today's frame code, moved wholesale. Capabilities:
  `[:models, :permissions, :slash_commands, :resume, :tools]`.
- `Backend.LLM` — the in-process tool loop from Phase 1 §1, emitting
  `tool-call`/`tool-update` around each dispatch. Capabilities:
  `[:models, :tools]` (add `:permissions` if §1 gates).
- future: `Backend.Remote` (an agent over ssh/socket), `Backend.Replay`
  (a `.chat` file as a fake backend, for tests/demos).

### The gentle hooks

Two layers, both userland:

1. **Event hooks (Scheme).** `agent-handle-event` becomes hook-driven:
   `(add-agent-event-hook! 'tool-call fn)` where `fn` returns `#t` to
   consume the event or `#f` to fall through to the default renderer.
   That is how a package customizes without forking the renderer —
   e.g. mail-specific rendering for `notmuch-tag` tool cards, or
   auto-approving read-only tools.
2. **Capability queries.** `(agent-supports? slug 'permissions)` so
   Scheme adapts instead of guessing: no permission keys advertised on a
   backend that never asks, `C-c m` picks in-place vs reconnect by
   `'models`, slash-command passthrough only where `'slash_commands`.

Connectors already carry per-backend config (`define-connector!` in
init.scm); add `'backend` to the plist (default `acp`), so
`(define-connector! "llm" '(backend llm))` replaces the current
`'type llm` special case, and a user can register a backend module from
config without touching core.

### Ordering

Phase 1 first (it deletes the fork and gives `Backend.LLM` its tool
loop). Phase 2 is then mostly moving code: extract `Backend.ACP`, define
the behaviour, route `handle_info({:agent_event, e})` generically, and
delete the `:llm`-type branches. Tests barely change — the FakeTransport
tests exercise `Backend.ACP`; add one `Backend.Stub` that emits a scripted
event list to prove the runtime is backend-blind.

### Definition of done (phase 2)

- `agent.ex` contains no JSON-RPC: `grep -n "jsonrpc\|sessionUpdate"
  lib/aimax/core/agent.ex` returns nothing.
- Adding a backend touches one new file plus one `define-connector!`.
- A `Backend.Stub` test drives the full transcript rendering (chunks,
  tool cards, folds, turn-end) with no wire at all.

## Phase 3: use what ACP actually offers the client

Research notes (svs, 2026-08-08; reading `claude-agent-acp` and the bb
client). ACP gives the *client* four levers. We currently use one and a
half. Each maps onto a Phase 2 capability, so they land as backend
features, not special cases.

### 3a. Client fs capabilities — agent edits through live buffers

We advertise `fs: {readTextFile: false, writeTextFile: false}`
(`agent.ex:146`) and refuse `fs/read_text_file` / `fs/write_text_file`
with `-32601` ("Phase 4"). So every agent edit goes to **disk**, behind
the editor's back: unsaved buffer state is invisible to the agent, and
its writes silently diverge from what the user is looking at.

Flip it on and the agent's file tools become *our* buffer ops:

- `fs/read_text_file` → `Buffer.text` of the visiting buffer if one
  exists (the live, unsaved content), else read the file.
- `fs/write_text_file` → `visit` + replace buffer contents, leaving the
  change **undoable, visible, and unsaved** — the user reviews and saves,
  or `C-/` reverts. Never touch disk directly.

This is the single highest-value ACP feature for this editor: it is
exactly the "everything is a live buffer" thesis, and no terminal-based
client can do it. bb does the same trick for the same reason (it
advertises fs, then enforces write roots on that path).

It also becomes an **enforcement chokepoint**: writes outside the
project/group can be refused with a JSON-RPC error before the agent ever
asks permission.

### 3b. Permission policy in Scheme (not "ask the human every time")

There is no upfront permission model in ACP: the agent asks per call via
`session/request_permission` with a menu (`allow_once`, `allow_always`,
`reject_once`, `reject_always`), and **the client's policy is whatever it
answers**. Today we always block on a human — which is why a mail triage
turn stalls on `mcp__aimax__notmuch-tag` mid-sweep.

Add a userland policy hook, consulted before the permission event is
rendered:

```scheme
(add-permission-policy!
  (lambda (slug title kind)
    (cond ((equal? kind "read") 'allow-once)      ; reads never block
          ((string-prefix? "mcp__aimax__" title) 'allow-always)
          (else #f))))                            ; #f = ask the user
```

Returning `#f` falls through to today's interactive banner. Defaults ship
conservative (reads auto-allowed, everything else asks); the user's own
rules live in init.scm. This is precisely bb's `handlePermissionRequest`,
in Scheme instead of TypeScript.

### 3c. Session modes

Agents advertise modes at `session/new` (`modes.currentModeId` +
`availableModes`; claude-code offers `default` / `plan` / `acceptEdits` /
`bypassPermissions`) and the client switches with `session/set_mode`.
We parse `models` from that same payload already (`e4e23a4`) and drop
`modes` on the floor.

Wire it exactly like models: a `mode-state` event → `'agent-modes` /
`'agent-mode` locals → modeline segment → `C-c ,` (or a `mode` action in
the embark table) → `session/set_mode`. Gate on capability
`:session_modes`. Plan mode is the natural default for a mail/triage
chat; `acceptEdits` for a coding thread.

### 3d. `_meta` — the per-connector escape hatch

`claude-agent-acp` accepts `_meta.claudeCode.options` on `session/new`:
`permissionMode`, `allowedTools` / `disallowedTools`, `systemPrompt`,
`env`, and more. That is the answer to "little customisations per ACP
backend" (and to making `/skills`-style behavior configurable per
backend): connectors carry a `'meta` plist, forwarded verbatim.

```scheme
(define-connector! "claude-code-plan"
  '(cmd "claude-code-acp"
    meta (claudeCode (options (permissionMode "plan")))))
```

Keep it verbatim and un-validated — it is adapter-specific by design,
and Scheme is where adapter-specific policy belongs.

### 3e. `terminal/*` — agent shells in comint buffers

bb declines terminal support because it has nowhere to put a shell. We
have `Proc` and comint buffers. Advertising `terminal: true` would let an
agent's shell commands run in a **visible editor shell buffer** the user
can watch, scroll, and interrupt. Lower priority than 3a, same shape:
client capability → our surface becomes the agent's tool.

### What we already do right

Handing the agent client-defined tools via a synthesized MCP server
(`mcp__aimax__*`) is exactly bb's `tool-proxy-mcp` pattern — per-session
`mcpServers` in `session/new`, tools executed back in the editor. That
part of the architecture needs no change.

## Known adjacent bugs (fix or note while in here)

- Permission cards sometimes don't render in reset chats — the thread
  reports `needs_attention` with a pending permission but no banner
  appears; `C-c C-y` works blind. Suspect `agent-block-drop-kind!` on
  restore/reset racing the permission event.
- ACP chats re-discover MCP tools via ToolSearch after every reset
  (fresh session + deferred schemas). Cosmetic, noisy.
