# SIMPLIFY: one tool, one send path, one runtime, no theater

Written 2026-08-08 for a fresh session with no prior context. Nothing
here is started unless marked LANDED.

## What this project is

**ai-max** is Emacs rebuilt on the BEAM: buffers, windows, keymaps and
modes implemented in Elixir/OTP, *scripted in a small Scheme*, rendered
by Phoenix LiveView in a browser. An umbrella of four apps:

```
apps/aimax_scheme   the interpreter (values are BEAM terms; symbols are {:sym, _})
apps/aimax_core     buffers, editor state, primitives, NIFs, procs, LLM, desktop
  priv/editor.scm   the editor itself: commands, keymaps, modes, chat, groups
  priv/packages/    severable packages: notmuch (mail), org, agent, tools, evil…
apps/aimax_ui       LiveView frontend — a client, no editor logic
apps/aimax_rpc      JSON-RPC over ~/.aimax/sock ("eval is the API")
```

**The one rule: Elixir supplies mechanism, Scheme decides policy.**
Before adding Elixir, ask whether Scheme plus one small primitive does
it. Commands, keybindings, modes, hooks, themes, dired, mail, chat —
all live in `priv/*.scm`. Elixir grows only for NIFs, sockets, PTYs,
parsers, schedulers, and raw buffer mechanics.

Read `ARCHITECTURE.md` once before changing anything. `CLAUDE.md` has
the house style. `HANDOFF.html` has broader project state.

## The part this spec changes: chat and agents

The mental model, because every work item below assumes it:

- **A chat is an ordinary buffer.** No sidebars, no special window. Its
  state lives in **buffer-locals** — which is also how it survives a
  daemon restart (`desktop.ex` persists locals + text; the mode's setup
  fn rebuilds keys, overlays and folds from them).
- **There is only `chat-mode`.** A former separate `agent-mode` was
  deleted (`693e0d3`); it survives as a one-line shim that upgrades old
  restored buffers.
- **A chat may be "backed" by an agent runtime.** If the buffer-local
  `'agent-slug` is set, a GenServer (`Aimax.Core.Agent`) owns a
  subprocess speaking **ACP** (Agent Client Protocol: JSON-RPC 2.0 over
  stdio — `initialize`, `session/new`, `session/prompt`, streaming
  `session/update` notifications, and callbacks like
  `session/request_permission`). Without a slug, the chat talks to the
  HTTP API directly. **That split is the main thing this spec deletes
  (W3).**
- **Events, not frames, are what Scheme sees.** The runtime flattens ACP
  into plists (`chunk`, `tool-call`, `tool-update`, `permission`,
  `turn-end`, `model-state`…) and Scheme renders them into the buffer,
  recording a **block model**: `'agent-blocks` is a list of
  `(start end kind …)` byte ranges saying what each span *is*. The
  LiveView renders blocks as typed DOM (prose, tool cards, permission
  banners). Buffer text stays canonical; blocks are a view over it.
- **The input region** is everything after `'agent-saved-mark` plus the
  `╰─ you ▸` marker. RET sends it; mid-turn sends are queued (muted)
  until the turn ends.
- **Tools.** The LLM tool loop lives in `llm.ex`; tool definitions live
  in the Scheme registry (`packages/tools.scm`, `define-tool!`). ACP
  agents get the same tools through a synthesized MCP server
  (`mcp__aimax__*`) passed in `session/new`.

Vocabulary you will meet in the code:

| term | meaning |
|---|---|
| **connector** | a named backend config (`define-connector!`): cmd, models, env, cwd. `claude-code`, `codex`, `llm` |
| **slug** | a thread id (`a1`); the buffer claiming it is the thread's surface |
| **mark** | `'agent-saved-mark` — end of transcript, start of the input region |
| **block** | `(start end kind …)` — the renderer's map of a byte range |
| **group** | `'group` buffer-local tying work buffers + one chat together |
| **target / action** | embark: the typed thing at point + the verbs for its type |
| **transient** | buffer-local meaning "derived content — desktop saves locals, not text" |

## Dev loop

```sh
mix test                                    # all four apps must stay green
pkill -f "mix run"; sleep 1
(mix run --no-halt >> ~/.aimax/daemon.log 2>&1 &); sleep 6
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:4004/
```

A daemon restart is required to reload `priv/*.scm`; browser clients
reload themselves. Editor state is restored from `~/.aimax/desktop.etf`.
Drive the editor headlessly (invaluable for verifying without a browser):

```sh
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"eval","params":{"code":"(buffer-list)"}}' \
  | nc -U ~/.aimax/sock
```

Tests drive the editor through `KeyDispatch.handle_key/1` — the same
path the GUI uses. ACP work is tested against a `FakeTransport`
(`test/aimax/agent_test.exs`), no adapter binary needed.

## The design rules this follows

1. **Unify.** Two implementations of one idea is a bug. Delete the fork,
   don't bridge it.
2. **One universal tool.** `eval-scheme` plus the public API *is* the
   agent's capability surface. Per-domain tools add none — they add
   maintenance. Improve discovery and error feedback instead.
3. **Permissions are theater.** An agent holding an arbitrary-eval tool
   in a local editor is already trusted. Default to allow; confirm only
   irreversible outward-facing acts. The one real threat is prompt
   injection from untrusted content (email bodies), which a per-call
   modal does not solve anyway.
4. The house rule stands: **Elixir supplies mechanism, Scheme decides
   policy.** Before adding Elixir, ask whether Scheme plus one small
   primitive does it.

## Where we are (verified 2026-08-08)

LANDED and green (369 tests, 4 apps):

- `693e0d3` — there is only chat. `(execute "task")` spawns
  `*chat:<slug>*`; the `*agent:*` surface, `agent-mode-setup!` and
  `agent-rename` are gone. `agent-mode` is a one-line shim that upgrades
  legacy restored buffers into `chat-mode`.
- `e4e23a4` — the tool loop serves every provider (openai/openrouter
  translated at the wire in `llm.ex`); the `chat-tools-usable?` gate is
  deleted. Embark: typed targets + per-type action tables, `C-.`, and an
  `act` tool over the same table.
- `0b91e99` — the modeline shows the model the ACP session actually
  runs (`session/new` → `models.currentModelId`); `C-c m` switches in
  place via `session/set_model` when the backend advertises models.
- `d3c64ce` — killing a displayed buffer heals the window tree; mouse
  handlers survive dead buffers. (An Editor crash wipes the keymap:
  "everything is undefined" until a daemon restart.)
- `ec8cba3` — `chat-set-backend api` rebinds RET to `chat-send`.

Facts worth having: 93 `public!`-documented functions; 14 registered
tools; `eval-scheme` evaluates in the live session with the full
namespace (verified: `(length (buffer-list))` → 30).

## W1 — One tool (do this first; it shrinks everything after)

**Keep:** `eval-scheme` (capability), `apropos-api` + `describe-function`
(the manual — what makes one-tool viable), `act` (parity: the same verb
table the keyboard uses).

**Delete:** `notmuch-search`, `read-email-thread`, `notmuch-tag`,
`read-doc`, `edit-doc`. Each is a one-liner over the same substrate. Any
future domain then adds **zero** tools.

**The blocker to fix at the same time — failure must teach.** Observed in
`*messages*`: the model guessed six times in a row before giving up —
`(buffer-insert …)`, `(insert-string …)`, `(buffer-insert! "hello")`,
`(buffer-insert!)`, `(buffer-insert! (current-buffer) "hello")`,
`(buffer-insert! 0 "hello")`. One round-trip each. So:

- On unbound-variable / arity errors, `eval-scheme` returns a
  did-you-mean built from the public registry (edit distance or shared
  prefix), including the signature line:
  `unbound: buffer-insert — did you mean buffer-insert!? (buffer-insert! NAME POS TEXT)`.
- The registry already exists (`public!` + `describe-function`); this is
  a Scheme-side wrapper on the eval-scheme handler, no Elixir.
- Buffer-scoped helpers that `read-doc`/`edit-doc` provided must stay
  reachable as *functions* (they are), so deleting the tools loses
  nothing.

Done when: `(llm-tool-specs)` has 4 entries, and a deliberate typo in
`eval-scheme` returns a suggestion naming the real function.

## W2 — Permissions: allow by default

Today every ACP tool call blocks on a human, which stalls multi-step work
(a mail sweep froze mid-run on `mcp__aimax__notmuch-tag`).

- Default policy: **allow**. Auto-answer `session/request_permission`
  with `allow_always` for everything except the deny-list.
- Confirm list (small, irreversible, outward-facing): sending mail,
  permanent deletion, `git push`-class acts. Roughly three verbs.
- Policy lives in Scheme so init.scm can override:
  `(add-permission-policy! (lambda (slug title kind) …))` returning
  `'allow-once | 'allow-always | 'ask | 'reject`. Ship the default
  policy as ordinary Scheme, not Elixir.
- Injection note (document, don't build): email bodies are untrusted
  input. The mitigation is that untrusted content never *initiates*
  actions — it is data in a prompt, and the confirm list catches the
  outward-facing tail.

Done when: an agent turn that tags 20 threads never prompts, and a
send-mail attempt still asks.

## W3 — One send path (the api/llm fork)

A chat still has two send paths with complementary holes:

| | "api" (`chat-send`) | "llm" connector (`agent-send`) |
|---|---|---|
| tools | yes | **no** (plain completion) |
| queue while running | **no** | yes |
| `C-RET` interrupt / revive | **no** | yes |
| tool cards / blocks | partial | yes |
| cost tracking | yes | no |
| history | `chat-turns` | its own list in `agent.ex` |

Same engine (`Aimax.Core.LLM`), two wrappers. The seam leaks: the
RET-dead bug (`ec8cba3`), "not an agent buffer" refusals, model-label
drift. `chat-send` branching on `agent-slug` is the smell.

**Target: every chat is a thread.** `RET` → `agent-send`, always.

1. Teach the in-process llm runtime the tool loop. `agent.ex` `:llm`
   threads call `LLM.request(llm_prompt(history))` (~line 572); move to
   `LLM.complete_tools/6`. Specs + dispatcher come from Scheme in the
   config plist at `agent-start!` (it already passes `presets`), so
   buffer-scoped tools keep their scope. Emit `tool-call` / `tool-update`
   events so the existing renderer shows cards with no new branches.
   `:on_usage` → `chat-usage-note!` so cost survives.
2. `chat-set-backend`: `"api"` → `(chat-attach-agent! buf "llm")`. There
   is no "no backend" state. Existing chats with `agent-slug: #f` attach
   on first send or in `chat-mode` setup.
3. Delete `chat-send`, `chat-send-plain!`, `chat-send-rich!`,
   `chat-llm`, `chat-llm-rich`. `chat-preamble` survives as the llm
   connector's system prompt, passed at attach.
4. `chat-turns` is the only history (already feeds `chat-flatten` for
   `.chat` save and `agent-seed-transcript` for model switches). Push
   turns from `agent-handle-event` for every backend.

Done when: `grep -n "chat-send\b\|chat-llm\b\|chat-send-plain\|chat-send-rich" priv/editor.scm`
is empty.

Tests: an api-backed chat runs a tool end to end; RET queues while
running and pops on turn-end; `C-RET` interrupts; switching backends
keeps `chat-turns` and reseeds with the whole chat; cost lands on
`chat-cost`; no buffer ends with `agent-slug: #f`.

## W4 — One runtime, many backends

Make ACP an implementation, not a privilege. `agent.ex` is ~693 lines:
backend-agnostic already are the status machine, prompt queue, event
batching, mark/append rendering, permission bookkeeping, info/kill.
ACP-specific are `request/notify/respond/send_frame`, `handle_frame`,
`handle_update`, `acp_servers` (~lines 300–560). A second backend already
lives inside as the `{:llm_reply, …}` branch — the hardcoded version of
this abstraction. Precedent exists one level down: `Transport` is already
a behaviour (real stdio vs the test fake).

```elixir
@callback start(config :: map, owner :: pid) :: {:ok, handle} | {:error, term}
@callback prompt(handle, text :: String.t()) :: :ok
@callback cancel(handle) :: :ok
@callback close(handle) :: :ok
@callback set_model(handle, model_id :: String.t()) :: :ok          # optional
@callback respond_permission(handle, id, option :: String.t() | nil) :: :ok  # optional
@callback capabilities() :: [:models | :permissions | :session_modes | :tools | :resume]
```

**The event vocabulary is the real contract**, not the callbacks. It
already exists (ACP shapes flattened by `plist/1`): `chunk`, `thought`,
`tool-call`, `tool-update`, `plan`, `permission`, `user-msg`,
`turn-end`, `error`, `model-state`, `status`. Any backend emitting those
renders with zero Scheme changes.

Implementations: `Backend.ACP` (today's frame code, moved),
`Backend.LLM` (from W3.1), later `Backend.Remote`, `Backend.Stub`
(scripted events, no wire — for tests).

Gentle hooks, both userland:
- `(add-agent-event-hook! 'tool-call fn)` — return `#t` to consume, `#f`
  to fall through to the default renderer.
- `(agent-supports? slug 'permissions)` — Scheme adapts instead of
  guessing (no permission keys where nothing asks; `C-c m` picks
  in-place vs reconnect by `'models`).
- Connectors gain `'backend` (default `acp`), so
  `(define-connector! "llm" '(backend llm))` replaces the `'type llm`
  special case and a user can register a backend from init.scm.

Done when: `grep -n "jsonrpc\|sessionUpdate" lib/aimax/core/agent.ex`
is empty; adding a backend touches one new file plus one
`define-connector!`; a `Backend.Stub` test drives full transcript
rendering with no wire.

## W5 — Agent edits through live buffers (the ACP feature worth having)

We advertise `fs: {readTextFile: false, writeTextFile: false}`
(`agent.ex:146`) and refuse `fs/read_text_file` / `fs/write_text_file`
with `-32601` ("Phase 4"). So every agent edit goes to **disk, behind the
editor's back**: unsaved buffer state is invisible to the agent, and its
writes diverge from what the user sees.

Advertise both and serve them:

- `fs/read_text_file` → `Buffer.text` of the visiting buffer if one
  exists (live, unsaved), else read the file.
- `fs/write_text_file` → `visit` + replace contents, leaving the change
  **undoable, visible, unsaved**. Never touch disk directly.

This is the highest-value ACP feature for this editor and the one thing a
terminal client structurally cannot do. It doubles as an enforcement
chokepoint (refuse writes outside the project/group before the agent
asks).

## W6 — Later, optional

- **Session modes.** `session/new` returns `modes` in the *same* payload
  we already parse `models` from (`e4e23a4`) — we drop it. Wire like
  models: `mode-state` event → locals → modeline → `session/set_mode`.
  Gate on `:session_modes`.
- **`_meta` per connector.** `claude-agent-acp` accepts
  `_meta.claudeCode.options` on `session/new` (`permissionMode`,
  `allowedTools`, `systemPrompt`, `env`). Connectors carry a `'meta`
  plist forwarded verbatim — this is how per-backend customization
  (`/skills`-style behavior, plan mode) belongs in init.scm.
- **`terminal/*`.** We have `Proc`/comint; advertising terminal support
  would run agent shell commands in a visible editor buffer.

Already right, do not touch: handing agents client-defined tools via a
synthesized MCP server (`mcp__aimax__*`) matches the standard pattern
(per-session `mcpServers` in `session/new`, executed back in the editor).

## Landmines (all cost real time this session)

- **The keymap lives only in Editor GenServer state**, bound once at
  Scheme load. Any Editor crash → every key "undefined" until a daemon
  restart. `d3c64ce` removed the known crasher; the durable fix is
  keymap in a crash-surviving ETS table (like `:aimax_commands`) or
  replaying bindings on Editor restart. **Worth doing early.**
- **Shell quoting in Scheme.** Bulk notmuch ops embedded bare parens →
  `/bin/sh` rejected every one while the editor echoed success. Quote
  whole queries as one argument.
- **A raising primitive used to kill the Session** (and cascade into
  app shutdown → 500s). `safe/1` now rescues; keep it that way.
- **Restored threads must clear `'agent-queued`** — it mirrors a runtime
  queue that died with the daemon; stale, it deadlocks RET.
- **Seed context must exclude chrome** (`meta`/`waiting`/`permission`
  blocks) or a revived chat feeds the model its own help banner.
- **Concurrent sessions.** svs runs more than one Claude session in this
  tree. Check `git status` before committing; commit only your files.

## Open bugs

- Permission cards sometimes do not render (thread reports
  `needs_attention` with a pending permission, no banner; `C-c C-y`
  works blind). Suspect `agent-block-drop-kind!` on restore/reset racing
  the permission event. W2 mostly removes the surface.
- ACP chats re-discover MCP tools via ToolSearch after every reset
  (fresh session + deferred schemas). Cosmetic, noisy.
