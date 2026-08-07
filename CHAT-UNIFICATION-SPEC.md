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

## Known adjacent bugs (fix or note while in here)

- Permission cards sometimes don't render in reset chats — the thread
  reports `needs_attention` with a pending permission but no banner
  appears; `C-c C-y` works blind. Suspect `agent-block-drop-kind!` on
  restore/reset racing the permission event.
- ACP chats re-discover MCP tools via ToolSearch after every reset
  (fresh session + deferred schemas). Cosmetic, noisy.
