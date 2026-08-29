# ONE CHAT — why, what, and how

Rewritten 2026-08-08. Audience: a coding agent (or human) implementing
this with NO prior context on the repo. Read Part 0 and Part 1 fully
before touching code. Nothing is started unless marked LANDED.

## Part 0: How to work in this repo (read first)

- **The one rule: Elixir supplies mechanism, Scheme decides policy.**
  Commands, keybindings, modes, chat behavior live in
  `apps/compos_core/priv/*.scm`. Before adding Elixir, ask whether
  Scheme plus one small primitive does it. Usually yes.
- **The Scheme dialect is NOT Emacs Lisp and NOT R7RS.** Symbols are
  `{:sym, _}` BEAM terms, plists are flat lists, there is no `nil`
  (use `#f`), no dotted pairs. NEVER write a name you haven't
  verified. Verify against the live editor:

  ```sh
  # search the documented public API (name + one-line doc):
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"eval","params":{"code":"(filter (lambda (e) (re-match? \"chat\" (car e))) (public-api))"}}' | nc -U ~/.compos/sock
  # search ALL globals (undocumented internals):
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"eval","params":{"code":"(filter (lambda (n) (re-match? \"^agent-\" n)) (global-names))"}}' | nc -U ~/.compos/sock
  # read any userland function's real source:
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"eval","params":{"code":"(describe-function (quote chat-reset))"}}' | nc -U ~/.compos/sock
  ```

- **Dev loop**:

  ```sh
  mix test                                   # all four apps must stay green
  pkill -f "mix run"; sleep 1
  (mix run --no-halt >> ~/.compos/daemon.log 2>&1 &); sleep 6
  curl -s -o /dev/null -w "%{http_code}\n" http://localhost:4004/
  ```

  A daemon restart is REQUIRED to reload `priv/*.scm`. Editor state
  restores from `~/.compos/desktop.etf`.
- **Tests** drive the editor through `KeyDispatch.handle_key/1` — the
  same path the GUI uses. ACP is tested against `FakeTransport`
  (`apps/compos_core/test/compos/agent_test.exs`) — no adapter binary,
  no network. LLM wire is stubbed via app-env seams
  (`:llm_request_fun`, `:llm_chat_fun`). Keep all three seams working.
- **Known test noise**: 8 compos_core failures were parked untriaged on
  2026-08-07, and the compos_rpc suite flakes in full umbrella runs but
  passes in isolation. FIRST TASK of any session: run
  `mix test apps/compos_core/test`, triage what's red, and only then
  trust green.
- **House style**: terse commits, test everything, verify UI changes in
  a real browser before committing. svs runs MULTIPLE Claude sessions
  in this tree concurrently: `git status` before committing, commit
  only files you changed.
- Reference docs: `ARCHITECTURE.md` (read once), `HANDOFF.html`
  (project state), `CLAUDE.md` (style).

## Part 1: Why this work exists, and how things work today

### The why

compos talks to LLMs in two ways that grew separately:

1. **Direct API calls** ("the api lane"): the editor calls
   Anthropic/OpenAI over HTTP itself, runs its own tool loop, pays per
   token. Cheap, stateless, fully under our control.
2. **Coding agents over ACP** ("the agent lane"): the editor spawns
   `claude-code-acp` or `codex-acp` as a subprocess and speaks the
   Agent Client Protocol to it. Rides a Claude Max / ChatGPT
   subscription, brings the agent's own tools, holds server-side
   conversation state we don't own.

A previous round of work merged the *surfaces* (commit 693e0d3: "there
is only chat" — one `chat-mode`, one buffer kind). But underneath
there are still two of everything: two send paths, two history stores,
two tool stories, two permission stories. Every seam is a place real
bugs happened: RET left bound to the wrong command after a backend
switch, resets leaving stale locals that deadlock input, modelines
naming models the session isn't running, tools silently absent on one
lane, agents freezing forever waiting for a human to approve a tool
call.

**The goal state:** there is ONE chat. A chat is a buffer holding a
conversation. Every chat has a *backend*: either the direct API (via
the `req_llm` library) or an ACP agent (claude-code, codex). The user
switches a chat's backend at any moment and the conversation just
continues. compos — not the backend — decides which tools (MCP servers)
each chat sees and which actions need human approval; the default
posture is "approve for me" (auto-answer everything except a short
deny-list). Chats reset cleanly, save to files, and restore across
daemon restarts, identically on every backend.

### What a chat is, physically

A chat is an ordinary buffer in `chat-mode`. No sidebars, no special
windows. ALL state lives in **buffer-locals**, because
`desktop.ex` persists buffer text + locals across restarts and the
mode's setup function rebuilds derived state (keys, overlays, folds)
from locals. "Which locals exist" IS the question "what survives a
restart".

**What the user sees**: a transcript above ONE chat box — the
LiveView input row (`ag-inputrow` in
`apps/compos_ui/lib/compos/ui/editor_live.ex:460`: "YOU … RET sends ·
C-RET interrupts"). There is no in-transcript prompt line; the box is
the only input surface.

**How that is represented**: the box is a *view over the buffer's
tail*. The buffer stores pending input as ordinary text after the
transcript, separated by an internal marker string
(`*chat-input-marker*`, `"\n╰─ you ▸ "`, editor.scm:1439):

```
[help/meta card][transcript ......... mark][marker][pending input]
                                                    ↑ rendered as the chat box
```

The renderer slices everything after `mark + 'agent-marker-bytes` into
the box (`ag_input`, editor_live.ex:676) and never shows the marker
glyph itself (user cards strip the prefix, editor_live.ex:630). The
marker text is visible only in the plain-view toggle (C-c C-v). This
representation is deliberate, not legacy — because the input IS buffer
text, all editing commands, point movement, and desktop persistence of
half-typed input work for free. Do not "fix" it by moving input out of
the buffer; do keep the marker out of anything a user or model sees
(seeds, `.chat` files, rendered cards).

- `'agent-saved-mark` — byte position where the transcript ends.
  Output inserts AT the mark; the marker and pending input slide
  right. Appends always land after every recorded range so stored
  offsets never shift.
- Mid-turn sends stay in the input region, tracked as byte lengths in
  `'agent-queued`, rendered muted inside the same box until their turn
  starts.
- `'agent-blocks` — the **block model**: newest-first list of
  `(start end kind meta…)` byte ranges saying what each span IS
  ("user" "prose" "thought" "tool" "plan" "permission" "waiting"
  "meta"). The LiveView renders blocks as typed DOM (prose, tool
  cards, permission banners). Buffer text stays canonical; blocks are
  a view.
- `'chat-turns` — the **conversation**: list of `(role text)`. This,
  NOT buffer text, is what is replayed to models, flattened to files,
  and used to seed new sessions (buffer text also contains help
  banners and tool cards which must never reach a model).

### What happens on RET today (the fork this spec deletes)

`chat-send` (priv/editor.scm:1277) branches:

- `'agent-slug` set → delegate to `agent-send`
  (priv/packages/agent.scm:499): the thread lane. A GenServer
  (`Compos.Core.Agent`, one per slug) owns the turn: prompt queue,
  streaming events, permissions, revive-on-dead.
- else → `chat-send-rich!` (editor.scm:1557): the api lane, inline in
  Scheme: push turn onto `'chat-turns`, call the Elixir tool loop
  (`Compos.Core.LLM.complete_tools`), render the reply in a callback.

Capability holes, all real:

| capability | api lane | "llm" connector (thread) | ACP thread |
|---|---|---|---|
| tools | yes | **no** | yes (agent's own + ours via MCP) |
| streaming | **no** | **no** | codex yes; claude-code sends whole messages |
| queue prompts mid-turn | **no** | yes | yes |
| C-RET interrupt / revive | **no** | yes | yes |
| cost tracking | yes | no | n/a (subscription) |
| history | `'chat-turns` | private list in agent.ex | server-side session |

The middle column, the "llm" connector, is a third thing: a thread
whose backend is an in-process API call (`agent.ex` `llm?` branch,
lines 101–116, 261–280, 567–580). It exists so api chats could get
queue/interrupt, but never got tools or streaming. It is the
half-built version of what W3 builds properly, and W3 deletes it.

### The Elixir pieces (where everything lives)

- **`apps/compos_core/lib/compos/core/agent.ex`** (~690 lines) — one
  GenServer per thread. Backend-agnostic machinery: status machine
  (`:starting → :idle → :running → :needs_attention → :dead`), prompt
  queue (`prompt_queue`, `pop_prompt_queue`), ordered event pipeline
  (events are Scheme plists like `(type chunk text "…")`; batched;
  adjacent chunks coalesced; delivered via `agent-on-event!` through
  `Session.apply_callback` from a Task so Session→Agent calls can't
  deadlock; lines 629–683), output mark (`append_at_mark`,
  `adjust_mark`), permission bookkeeping (`pending_permission`,
  `respond_permission`). Entangled ACP-specific code: JSON-RPC framing
  (300–350), `handle_frame`/`handle_update` (353–515), `acp_servers`
  config translation (539–563), the `initialize`→`session/new`
  handshake (140–150, 359–394).
- **`apps/compos_core/lib/compos/core/agent/transport.ex`** — a
  behaviour (real stdio Port vs test fake). Precedent for W2's seam.
  Note: the Port deletes `CLAUDECODE` from the child env (the adapter
  refuses to nest inside a Claude Code shell).
- **`apps/compos_core/lib/compos/core/llm.ex`** (~460 lines) — the
  direct-API engine. Hand-rolled Anthropic HTTP + an
  OpenAI-compatibility translation, the tool_use loop
  (`complete_tools/6`, `tool_loop`, max 25 rounds), prompt-cache
  breakpoints (`cache_last`, `cache_last_tool` — the api lane's
  economics: the whole transcript is re-sent every turn, the cached
  prefix bills at ~10%), usage → `Compos.Core.LLMDb` cost ledger. Tool
  *definitions* live in Scheme; llm.ex converts specs to JSON
  (`tool_json`) and dispatches calls back (`Session.call_fn` for
  Scheme tools; `MCP.call_qualified` in Elixir for `mcp__*` tools so a
  slow fetch never blocks a keystroke).
- **`apps/compos_core/lib/compos/core/mcp.ex` + `mcp/conn.ex`** — MCP
  *client*: stdio/http servers, tools bridged into the registry as
  `mcp__<server>__<tool>`.
- **`apps/compos_core/priv/compos-mcp-proxy.exs`** — the editor as an
  MCP *server*: stdio bridge to the daemon socket exposing the
  `define-tool!` registry (base64 payloads both ways). ACP agents get
  compos's tools by receiving this proxy as an entry in `mcpServers`.
- **`apps/compos_core/lib/compos/core/desktop.ex`** — persistence:
  file buffers save `{path, point, locals}`; non-file buffers save
  `{name, content, point, locals}` (`savable_locals` filters
  non-serializable values, e.g. closures drop out). Restore lays
  content + locals down FIRST, then `set-mode!`, so the mode setup fn
  rebuilds keys/overlays/folds from the locals it finds.

### The Scheme pieces

- **`priv/editor.scm`** — chat-mode (1139–1192), the fork
  (`chat-send` 1277), the api lane (`chat-send-plain!` 1414,
  rich transcript helpers 1431–1580: `chat-render!`, `chat-turns`,
  `chat-tool-dispatch`, `chat-send-rich!`), `chat-attach-agent!`
  (1296), `chat-task-init!` (1329), `chat-flatten` (1344),
  `chat-reset` (1360), `chat-set-backend` (1386), `chat-set-model`
  (1601), `chat-preamble` (1219 — the per-send system prompt; a
  grouped chat points the model at the group's live buffers,
  pull-context via tools).
- **`priv/packages/agent.scm`** — the thread lane: event renderer
  (`agent-handle-event` 215–325) recording blocks/folds/overlays;
  permission answering (327–369; option matching by kind
  exact-then-prefix; "approving is invisible, denying is recorded" —
  bb's rule, adopted); revive/reconnect/seed (376–497:
  `agent-revive!`, `agent-reconnect!`, `agent-seed-transcript`,
  foreign-model drop); send/interrupt (499–539); **connectors**
  (541–628): `define-connector!` registry —
  `claude-code` (cmd `claude-code-acp`, model via env pair
  `ANTHROPIC_MODEL` + `CLAUDE_CODE_SUBAGENT_MODEL`),
  `codex` (cmd `codex-acp`, model via TOML-quoted `-c model="…"`
  flag), `llm` (`'type llm` — the in-process special case);
  `agent-resolve-config` (596–624) which also injects `'mcp-servers`
  from presets; the `*chats*` fleet (720–964).
- **`priv/packages/mcp.scm`** — server registry (`mcp-register!`),
  presets (`define-preset!`, `'chat-presets` buffer-local,
  `chat-extra-tool-specs` pulls bridged specs at send time), and the
  ACP translation (`mcp-acp-server(s)`, `presets-acp-servers` — compos
  proxy always + preset servers; `"@VAR"` env values resolve to keys
  Elixir-side so config files stay secret-free).
- **`priv/packages/tools.scm`** — `define-tool!` registry, the 14
  current tools, `*llm-system*` (the standing system prompt),
  the MCP proxy surface (`mcp-proxy-tools-json`, `mcp-proxy-call`).

### ACP in one paragraph, and our current posture

ACP = JSON-RPC 2.0 over the agent subprocess's stdio, newline-framed.
The client (us) sends `initialize` (capability negotiation), then
`session/new` with `cwd` and `mcpServers` (the ONLY first-class way to
hand an agent extra tools), then `session/prompt` per turn. The agent
streams `session/update` notifications (message/thought chunks,
tool_call / tool_call_update, plan) and calls BACK into the client:
`session/request_permission` (options like allow-once / allow-always /
reject-once) and, if the client advertised the capabilities,
`fs/read_text_file`, `fs/write_text_file`, `terminal/*`. **The
protocol has NO upfront permission policy — the client's answers ARE
the policy.** Clients can also switch "session modes"
(`session/set_mode`; claude-code advertises
default/plan/acceptEdits/bypassPermissions) and pass adapter-specific
config in `_meta` (claude-code accepts `_meta.claudeCode.options`:
`permissionMode`, `allowedTools`/`disallowedTools`, `systemPrompt`,
`settingSources`, …).

Our posture today: we send `mcpServers`; we advertise
`fs: {readTextFile: false, writeTextFile: false}` and refuse `fs/*`
with -32601 (agent.ex:457–459) — this is DELIBERATE and stays: fs/*
means files, and agents that want live editor state read it through
the `mcp__compos__` tools (eval-scheme → `buffer-text` etc.), not
through a filesystem shim; we parse `models` from the session/new
result but DROP `modes` (same payload); we send no `_meta`; every
permission request blocks until a human presses `C-c C-y`.

### The observed bugs/frictions each work item answers

1. Agents freeze on permissions — unattended work impossible (a real
   mail sweep froze mid-run). → W5
2. Which lane a chat is on silently changes what works (table above).
   → W2/W3
3. Seam bugs: RET left bound to `agent-send` after switching back to
   api ("not an agent buffer"; hand-fixed in ec8cba3) — the class
   survives while lanes rebind keys. → W3/W7
4. Reset/restore each keep their own list of locals to clear; a missed
   one (`'agent-queued`) deadlocked RET on restored chats. → W8
5. Modeline drift: fixed for models (0b91e99) by trusting the
   adapter's report; `modes` still dropped. → W4/W7
6. Loading a preset on a live ACP chat silently does nothing
   (`mcpServers` is session-scoped). → W6
7. claude-code loads the user's own `~/.claude` config (its own MCP
   servers + permission settings) — compos is NOT actually in control
   of the agent's tool surface. → W4
8. llm.ex hand-rolls provider translation/tool-calling and lacks
   streaming; `req_llm` provides all of it maintained (HANDOFF #43,
   user-requested). → W3

## Part 2: Target design

### Principles

1. **The transcript is the truth.** `'chat-turns` is the conversation;
   backends execute turns against it. What a backend can't carry
   across (server-side session state) is rebuilt by seeding from the
   transcript. This makes switching *possible*.
2. **One send path.** RET always goes through the thread runtime; the
   runtime always has a backend; "api" is just another connector. This
   makes switching *transparent* (no rebinding, no capability cliffs).
3. **compos owns tools and permissions, identically on both lanes.**
   Presets decide tools; ONE Scheme policy function decides
   permissions; backends are configured and answered accordingly.
4. **Events are the contract.** The runtime emits plist events; Scheme
   renders them. Any backend emitting the vocabulary gets the full UI
   free. Backends differ in capabilities, declared not guessed.
5. Elixir supplies mechanism, Scheme decides policy.

### The picture, after

```
            chat-mode buffer  ('chat-turns = truth, blocks = view, locals = state)
                   │ RET → agent-send, always
            Compos.Core.Agent (per-thread GenServer: status, queue, events, mark)
                   │ Backend behaviour
      ┌────────────┴────────────┐
 Backend.ReqLLM            Backend.ACP
 req_llm library:          subprocess adapter (claude-code-acp, codex-acp)
 streams, tool loop,       session/new: mcpServers + _meta (client control)
 usage events              session modes; live editor state via mcp__compos__
      │                         │
      └──────── same tool registry (define-tool! + MCP bridge) ────────┘
             same permission policy (*permission-policy*, Scheme)
```

## Part 3: Work items

Order: W1 → W2 → W3 → W5 → W4 → W6 → W7 → W8 → W9 — except W8's
locals partition, which may land any time early (everything after gets
safer). Each item: why → where → steps → done-when. Do them as
separate commits; keep `mix test` green between items.

### W1 — One tool

**Why**: the agent's capability surface should be `eval-scheme` plus a
discoverable public API, not per-domain tools. What makes one-tool
viable is error feedback: the observed failure mode is a model
guessing `buffer-insert`, `insert-string`, … six round-trips in a row.

**Where**: `priv/packages/tools.scm` (registry, all tools);
`priv/packages/notmuch.scm` (the three mail tools);
`public!` registry in `priv/editor.scm:15`.

**Steps**:
1. Delete tools `notmuch-search`, `read-email-thread`, `notmuch-tag`,
   `read-doc`, `edit-doc` (keep the underlying *functions* callable —
   they already are).
2. Wrap the `eval-scheme` tool handler: on an error mentioning
   `unbound variable: X` (or an arity error), compute nearest
   candidates from `(public-api)` names (shared prefix or edit
   distance ≤2), and return
   `unbound: X — did you mean Y? (signature-from-doc)` alongside the
   error. Pure Scheme; no Elixir.
3. Keep: `eval-scheme`, `apropos-api`, `describe-function`, `act`.

**Done when**: `(llm-tool-specs)` has 4 entries; evaluating
`(buffer-insert "x")` through the tool returns a message naming
`buffer-insert!` with its doc line; `mix test` green.

### W2 — The backend seam

**Why**: agent.ex already contains two backends (ACP frames + the
`llm?` branch) interleaved with generic thread machinery. Backends
must sit behind a small seam to be interchangeable. Transport is the
precedent one level down.

**Where**: `agent.ex`; new files
`lib/compos/core/agent/backend.ex`,
`lib/compos/core/agent/backend/acp.ex`,
`lib/compos/core/agent/backend/stub.ex`; connectors in
`priv/packages/agent.scm:541–628`.

**Steps**:
1. Define the behaviour:

   ```elixir
   defmodule Compos.Core.Agent.Backend do
     @callback start(config :: map, owner :: pid) :: {:ok, handle :: term} | {:error, term}
     @callback prompt(handle, text :: String.t(), context :: map) :: :ok
     @callback cancel(handle) :: :ok
     @callback close(handle) :: :ok
     @callback set_model(handle, model_id :: String.t()) :: :ok | {:error, :unsupported}
     @callback respond_permission(handle, id :: term, option :: String.t() | nil) :: :ok
     @callback capabilities() :: [:models | :streaming | :session_modes | :resume]
   end
   ```

   Backends send the owner `{:backend_event, plist}` messages; the
   Agent GenServer keeps the queue/coalesce/batch pipeline exactly as
   is. The `context` map on prompt carries `turns` (from Scheme),
   `system`, `tools` (specs), `dispatcher` — ACP ignores most of it.
2. Move lines 300–563 of agent.ex (framing, handle_frame,
   handle_update, acp_servers, initialize/session-new handshake) into
   `Backend.ACP` verbatim — refactor, do not redesign. Transport
   stays beneath it unchanged (FakeTransport keeps working).
3. Add `Backend.Stub`: config carries a script of events to emit per
   prompt. No wire. This is the test backend for everything above the
   seam.
4. Connector plists gain `'backend` (default `"acp"`). Config
   resolution (`agent-resolve-config`, agent.scm:596) passes it
   through; agent.ex picks the module. Do NOT yet delete the `llm?`
   branch — that is W3 step 3 (keep the tree green between items).
5. **The event vocabulary is the contract** — do not change existing
   plists: `chunk thought tool-call tool-update plan permission
   user-msg turn-end error model-state status dead`. W3/W4 add
   `usage` and `mode-state`.

**Done when**: `grep -n "jsonrpc\|sessionUpdate" lib/compos/core/agent.ex`
is empty; agent_test passes unmodified (FakeTransport now under
Backend.ACP); a new Backend.Stub test drives chunks + a tool card + a
permission round-trip into a real buffer with no wire.

### W3 — The ReqLLM lane; delete the fork

**Why**: (a) the api lane deserves queue/interrupt/revive and the llm
connector deserves tools/streaming — both close by making the direct
lane a real backend; (b) `req_llm` (hex package) replaces ~460
hand-rolled lines with a maintained library that adds streaming; (c)
with both lanes behind the seam, the RET fork — the root of the
seam-bug class — can be deleted.

**Where**: `llm.ex`; new `lib/compos/core/agent/backend/req_llm.ex`;
the fork in `priv/editor.scm` (chat-send 1277, chat-send-plain! 1414,
rich helpers 1431–1580); `chat-set-backend` 1386; `agent.ex` llm?
remnants.

**Steps**:
1. **Port llm.ex's wire to req_llm.** Read the req_llm docs on hexdocs
   FIRST — do not guess its API. Preserve the public surfaces
   unchanged: `(llm …)`, `(llm-tools …)`, `(set-llm-model! …)` with
   its `provider:model` routing, `LLM.complete_tools/6`, and the
   `:llm_request_fun`/`:llm_chat_fun` test seams. Two things MUST
   survive the port, verified at the wire (inspect the request req_llm
   builds in a test): the prompt-cache breakpoints (`cache_last`
   semantics — last message block + last tool + system get
   `cache_control`) and usage flowing to `LLMDb.record`.
2. **`Backend.ReqLLM`**: on `prompt`, run the tool loop in a
   supervised Task. History comes from `context.turns` — agent.ex
   keeps NO private history (delete the `history` field). Specs +
   dispatcher come from `context` (Scheme passes registry + the
   chat's preset tools, so buffer scoping is preserved). Emit:
   streaming deltas → `chunk` events; around each tool dispatch →
   `tool-call` / `tool-update` (the renderer then shows cards with
   zero new branches); a final `usage` event
   `(type usage input N output N cost F)`; then `turn-end`. The
   dispatcher must consult the permission policy (W5) before running
   any tool.
3. **Delete the fork.** In Scheme: `chat-mode` setup (or first send)
   attaches a backend to any chat without one — default connector
   `"api"` = `(define-connector! "api" '(backend req-llm))`; RET
   binds `agent-send` for every chat; delete `chat-send`,
   `chat-send-plain!`, `chat-send-rich!`, `chat-llm`,
   `chat-llm-rich`; `chat-set-backend`'s "api" arm becomes
   `(chat-attach-agent! buf "api")` (no key rebinding anywhere). In
   Elixir: delete the `llm?` branch (agent.ex 101–116, 261–280,
   567–580, `llm_prompt`). `chat-preamble` becomes the api
   connector's system prompt, rebuilt per send (pull-context must
   stay fresh — pass it in `context.system` at prompt time, not at
   session start). Scheme's event handler pushes `'chat-turns` for
   user-msg and final assistant text on EVERY backend (this replaces
   the api lane's manual turn pushing, and gives ACP chats real turns
   for flatten/seed).
4. Cost: the `usage` event handler calls the existing
   `chat-usage-note!`. ACP backends emit no usage; their modeline
   keeps `connector · model`.

**Done when**:
`grep -n "chat-send\b\|chat-llm\b\|chat-send-plain\|chat-send-rich" priv/editor.scm`
is empty and `grep -n "llm_reply\|llm?" lib/compos/core/agent.ex` is
empty; a test drives an api chat through: streamed reply renders
incrementally, a tool runs showing a card, RET mid-turn queues and
pops on turn-end, C-RET cancels, cost lands on `'chat-cost`; no chat
exists without `'agent-slug` after first send.

### W5 — Permissions: one policy, three modalities

(Ordered before W4 because it unblocks real agent work immediately;
only its `auto` modality needs W4.)

**Why**: today a human must approve every ACP tool call (unattended
work impossible), while api-lane tools run with no gate at all. Both
wrong, opposite directions. Threat model (stands from the previous
spec): an agent holding eval-scheme in a local editor is already
trusted; per-call modals are theater EXCEPT for irreversible,
outward-facing acts — send mail, permanent deletion, push/publish.

**Where**: `priv/packages/agent.scm` 327–369 (answering machinery
exists); `agent.ex` `pending_permission`; `Backend.ReqLLM` dispatcher
(W3); new Scheme: policy fn + modality plumbing.

**Steps**:
1. Buffer-local `'chat-permission-mode` ∈ `ask | approve | auto`,
   default `approve`. A command `chat-set-permission-mode` (C-c p)
   cycles it; modeline shows it.
2. One policy function, userland, override in init.scm:

   ```scheme
   (set! *permission-policy*
     (lambda (buf title kind raw)   ; -> 'allow | 'allow-always | 'ask | 'reject
       …))
   ```

   Ship a default: deny-list match (verb-shaped patterns over the
   tool name/title: send/mail, delete/trash-permanent, push/publish)
   → `'ask`; everything else → `'allow-always` in approve/auto modes,
   `'ask` in ask mode.
3. Wire the ACP side: when a `permission` event arrives, Scheme (the
   event handler, not Elixir) consults mode + policy. `'allow-always`
   → answer immediately via the existing
   `agent-answer-permission!` machinery, render NOTHING (approvals
   invisible, denials leave a line — already the adopted rule);
   `'ask` → today's banner flow.
4. Wire the direct lane: `Backend.ReqLLM`'s dispatcher asks policy
   BEFORE each tool call (route through Scheme via the dispatcher it
   was handed). Verdict `'ask` → emit the same `permission` event,
   pause the loop on a promise, resume via the same
   `respond_permission` path. One banner, one keybinding set, both
   lanes.
5. `auto` = approve + push permissiveness backend-side (W4: session
   mode acceptEdits/bypassPermissions and/or `_meta permissionMode`).
   The deny-list must NOT rely on the backend asking — it also holds
   at our own chokepoints (our MCP proxy tools and the direct-lane
   dispatcher; every deny-listed verb reaches the world through one of
   those).
6. Robustness (bb's model, studied): resolution is idempotent (CAS on
   rpc_id — a second answer is a no-op, not an error); turn-end /
   reset / kill auto-resolve pending requests as `cancelled`;
   non-interactive chats (background `(execute …)`) in ask-mode
   auto-deny after a timeout with a transcript line so headless work
   never hangs.

**Done when**: in approve mode a 20-tool-call agent turn completes
with zero prompts and a send-mail attempt still banners — on BOTH
lanes (Stub test + ReqLLM test); double-answering is a no-op; killing
a chat with a pending permission resolves it cancelled; ask mode still
behaves exactly as today.

### W4 — The ACP lane: actually take control

**Why**: ACP's whole design is that the client's behavior is the
policy — and we exercise one lever of three that matter here.
Concretely: claude-code loads the user's `~/.claude` settings (own MCP
servers, own permission config) unless told otherwise, so compos does
not control the agent's tool surface today.

**Where**: `Backend.ACP` (post-W2); `initialize` params
(clientCapabilities); session/new result handling;
`agent-resolve-config` / connectors (agent.scm); `'meta` forwarding;
buffer primitives for fs.

**Steps**:
1. **Session modes**: session/new's result carries `modes` next to the
   `models` we already parse (agent.ex:373–390 pre-move) — stop
   dropping it. Emit
   `(type mode-state current ID available ((id name)…))`; store
   `'agent-mode-state`; add `(agent-set-mode! slug id)` →
   `session/set_mode`; handle the `current_mode_update` session/update
   kind. Gate on `capabilities()` including `:session_modes`.
2. **`_meta` passthrough**: connector plists may carry `'meta`,
   forwarded VERBATIM as `_meta` in session/new (plist→JSON with the
   existing conventions). Ship the claude-code connector with
   `settingSources: []` inside `_meta.claudeCode.options` so the
   adapter loads NO user-level config — compos's mcpServers and answers
   are the only sources. (This is also the documented hook for
   per-connector permissionMode / allowedTools / systemPrompt from
   init.scm.) Verify against claude-agent-acp's README/source for the
   exact option names before wiring.
**Explicit non-goal — fs/* stays refused.** An earlier draft proposed
serving `fs/read_text_file`/`fs/write_text_file` from live buffers.
Rejected: fs/* means files; agents that want live editor state already
have it through the `mcp__compos__` tools (eval-scheme, `buffer-text`,
the whole registry). Keep advertising `fs: false` and answering -32601
so adapters use their own file access. Do not build a filesystem shim
over buffers.

**Done when**: FakeTransport test asserts session/new carries
mcpServers + `_meta` with `settingSources: []` for claude-code;
mode-state renders and `agent-set-mode!` emits session/set_mode;
initialize still advertises `fs: false` and fs/* frames still answer
-32601.

### W6 — MCPs: presets are the single source of truth

**Why**: `'chat-presets` already drives both lanes, but ACP
`mcpServers` is fixed at session/new — loading a preset
mid-conversation silently does nothing until some later reconnect.
Silent no-ops read as broken features.

**Where**: `priv/packages/mcp.scm` (`llm-set-preset` /
`llm-unset-preset`); reconnect machinery in agent.scm.

**Steps**: on preset change in a chat whose backend is a live ACP
session: set `'chat-mcp-dirty`, message the user, and offer
"reconnect now?" in the prompt; either way the next send reattaches
(kill + attach same connector/model, seeded — the normal reconnect
path) with the new server list, then clears the flag. Api lane:
nothing to do (specs are read fresh at send time already).

**Done when**: load-preset on a live ACP chat → next send's
session/new (FakeTransport) contains the new server; the conversation
survives (seed prompt contains prior turns); unload removes tools on
both lanes; no path silently ignores a preset change.

### W7 — Transparent backend switching

**Why**: "transparent" must be testable. Definition: **the buffer, its
group, `'chat-turns`, presets, permission mode, cost history, and
keybindings survive every switch; the user just keeps typing.** After
W3, keybindings are free (RET is agent-send everywhere — the ec8cba3
class is structurally gone).

**Where**: `chat-set-backend` (editor.scm:1386), `chat-set-model`
(1601), `agent-reconnect!`/`agent-revive!` (agent.scm 376–436).

**Steps**: consolidate to one switch function with two mechanisms:

| situation | mechanism |
|---|---|
| live session + backend advertises `:models` + target in its list | `set_model` in place — server-side context survives |
| anything else (lane/connector change, dead session, model not takeable) | `close` handle → attach new backend → seed |

Seeding stays as-is: `'agent-seed-context` iff turns non-empty; first
prompt carries the flattened transcript (chrome — meta/waiting/
permission blocks — excluded; `agent-seed-transcript` does this).
Foreign-model drop on revive stays. Modeline: always resolved truth —
`connector · model` from `model-state` events; `api · model · $cost`
on the direct lane.

**Done when**: a scripted test (Stub + FakeTransport + ReqLLM stub)
runs api→codex→claude-code→api on ONE chat: turns/presets/mode/cost
all survive, each hop's first outbound prompt contains the earlier
turns, `agent-slug` stays stable, and the modeline label matches the
running backend at every step.

### W8 — Reset without bugs

**Why**: the reset/restore bug class (stale `'agent-queued`
deadlocking RET; stale banners; help-banner-in-seed) has ONE cause:
which locals mean what is implicit, and reset/restore/save each keep
their own partial list.

**Where**: `chat-reset` (editor.scm:1360 — note its inline local
list), desktop restore path (`chat-mode` setup fn, editor.scm:1139),
save (`chat-flatten` 1344).

**Steps**:
1. Define the partition ONCE in Scheme, next to chat-mode:

   ```scheme
   ;; who the chat is — survives reset, restart, and save
   (define chat-identity-locals
     '(group agent-connector agent-model chat-presets chat-permission-mode))
   ;; what was said — survives restart and save; cleared by reset
   (define chat-conversation-locals
     '(chat-turns agent-blocks agent-overlays agent-folds
       chat-cost chat-last-usage agent-saved-mark agent-marker-bytes))
   ;; process state — mirrors a live runtime; ALWAYS stale after a
   ;; restart, meaningless after reset: cleared by both
   (define chat-runtime-locals
     '(agent-slug agent-queued agent-waiting chat-waiting
       agent-cancelling agent-seed-context agent-tool-bodies
       agent-models agent-mode-state chat-mcp-dirty))
   ```

2. `chat-reset` := resolve pending permission as cancelled FIRST
   (this ordering is likely the fix for the blind-permission-card
   race — see Open bugs), close the handle (must never error: live,
   dead, or absent backend), clear conversation + runtime lists,
   rebuild the surface (`group-chat-init!`), keep identity; same
   backend reattaches lazily on next send. Idempotent.
3. Restore (chat-mode setup): clear `chat-runtime-locals` wholesale —
   generalizing the agent-queued fix to the class, permanently.
4. **Standing rule (add to CLAUDE.md):** any new chat buffer-local
   MUST be added to exactly one of the three lists in the same
   commit.

**Done when**: extend `chat_reset_test.exs`: reset on each of {api
chat, live ACP chat, dead ACP chat, chat with queued prompts, chat
with pending permission, freshly-restored chat} leaves the identical
clean state, zero errors; reset∘reset = reset; `grep -rn "agent-queued"
priv/` shows only the partition definition and the queue machinery —
no other site enumerates chat locals.

### W9 — Save and restore

**Why**: chats survive restarts (desktop) and save to `.chat` files —
but a saved file loses its identity (backend/model/presets), so an
opened `.chat` is text, not a conversation that can continue where it
ran.

**Where**: `chat-flatten` + the C-x C-s conversion path
(editor.scm:639–652, 1344); `.chat` auto-mode (editor.scm:191);
chat-mode setup.

**Steps**:
1. Desktop: nothing to build beyond W8 (text+point+locals persist;
   setup rebuilds; runtime locals cleared).
2. `.chat` files: keep the `### You / ### Assistant` body; PREPEND one
   optional header line on save:

   ```
   #+chat: (connector "codex" model "gpt-5.5" presets (dev) permission-mode approve)
   ```

   On visit + chat-mode: if line 1 matches `#+chat:`, parse the plist
   into identity locals, rebuild `'chat-turns` from the markers, set
   `'agent-seed-context`, and exclude the header line from the
   transcript/seed. Headerless files keep today's behavior exactly.

**Done when**: save → daemon restart → visit the `.chat` → RET: the
outbound prompt (FakeTransport) contains the file's turns and the
session uses the connector named in the header; a desktop-restored ACP
chat revives on RET with no stale queue/waiting/permission artifacts.

## Part 4: Landmines (every one cost real time; re-read before each item)

- **The keymap lives only in Editor GenServer state**, bound at Scheme
  load. ANY Editor crash → every key "undefined" until daemon restart.
  Durable fix (ETS like `:compos_commands`, or replay on restart) is
  worth doing early — this work exercises Editor hard.
- **claude-code-acp 0.4.5 does NOT stream** (whole-message chunks);
  codex-acp streams token deltas. The renderer must assume neither.
- **Adapter quirks**: subagents 404 without
  `CLAUDE_CODE_SUBAGENT_MODEL`; codex's model flag must be TOML-quoted
  (`-c model="…"`); adapters silently ignore foreign model ids (hence
  the drop-on-revive rule); the Port env must delete `CLAUDECODE` or
  the adapter refuses to nest.
- **Duplicate plist keys resolve first-wins on BOTH sides** of the
  Scheme/Elixir boundary (plist_to_map reverses before Map.new). Per-
  call opts ride in FRONT of connector config for exactly this reason.
- **Session wraps all Scheme evaluation in catch :exit** — a primitive
  hitting a dead GenServer must never crash the single writer. When
  you add primitives (fs serving, policy calls), keep this true.
- **Killed buffers ghost back empty if a window still shows them**;
  pre-d3c64ce, rendering such a window CRASHED Editor (see keymap
  landmine). Kill now heals windows — keep it true.
- **Seed context must exclude chrome** (meta/waiting/permission
  blocks) or a revived chat feeds the model its own help banner.
- **Byte offsets, not chars**: marks/blocks/folds are byte ranges;
  cuts must be whole-line or validated — a mid-UTF-8 cut poisons the
  JSON encoder.
- **Shell quoting in Scheme**: pass whole queries as ONE argument;
  bare parens made /bin/sh reject every command while the editor
  echoed success.
- **Concurrent sessions**: svs runs multiple Claude sessions in this
  tree. `git status` before committing; commit only your files.

## Part 5: Open bugs to fold in

- Permission cards sometimes don't render (status `needs_attention`,
  pending permission exists, no banner; C-c C-y works blind). Suspect
  `agent-block-drop-kind!` racing the permission event around
  reset/restore. W8's ordering (resolve pending BEFORE clearing
  blocks) is the likely fix; verify while there.
- ACP chats re-discover MCP tools via ToolSearch after every reset
  (fresh session, deferred schemas). Cosmetic. A resume story (ACP
  `session/load`, `capabilities :resume`) would remove it — follow-up,
  NOT this spec.
- 8 untriaged compos_core failures parked 2026-08-07 — triage before
  starting, or green means nothing.
