# ai-max.el — working instructions

Emacs rebuilt on the BEAM, scripted in Scheme, rendered by Phoenix LiveView.
Read `ARCHITECTURE.md` once before making changes. `HANDOFF.html` has the
current state, queue, and landmines (open it in the editor: `C-x C-f`, then
`C-c C-v` to preview).

## The one rule

**Elixir supplies mechanism. Scheme decides policy.**

Before adding Elixir code, ask: *can this be Scheme plus one small primitive?*
Usually yes. Commands, keybindings, modes, hooks, themes, dired, chat, display
rules — all live in `apps/aimax_core/priv/*.scm`. Elixir grows only for NIFs,
sockets, PTYs, parsers, schedulers, and raw buffer mechanics.

## Dev loop

```sh
mix test                                    # all four apps must stay green
pkill -f "mix run"; sleep 1
(mix run --no-halt >> ~/.aimax/daemon.log 2>&1 &); sleep 6
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:4004/
```

A daemon restart is required to reload `priv/*.scm`. Browser clients reload
themselves (boot-id). Editor state (buffers, windows, theme) is restored from
`~/.aimax/desktop.etf`. **Rule: everything survives a reload** — file buffers
reopen via `(visit)`; non-file buffers (chat, agent threads, scratch) persist
content+point+locals, and the mode setup fn rebuilds keys/overlays/folds from
locals on restore. New buffer kinds must keep this true.

**Rule: every chat buffer-local belongs to exactly one of the three lists**
in `editor.scm` — `chat-identity-locals` (who the chat is: survives reset,
restart, save), `chat-conversation-locals` (what was said: survives restart
and save, cleared by reset), `chat-runtime-locals` (mirrors a live runtime:
always stale after a restart, meaningless after a reset — cleared by both).
Add yours in the same commit that introduces it. Reset, restore, and save
all read these lists; a local in none of them is the reset/restore bug
class growing a new head.

Drive the editor headlessly:

```sh
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"eval","params":{"code":"(buffer-list)"}}' \
  | nc -U ~/.aimax/sock
```

## House style

- Terse replies: outcome first, bullets, no recaps, no verification narration.
- Test everything, especially the Scheme kernel; drive tests through
  `KeyDispatch.handle_key/1` — the same path the GUI uses.
- Verify UI changes in a real browser, screenshot, then commit.
- Use subagents for verification sweeps to keep context clean.
- Emacs is the reference: copy its semantics unless there's a reason not to.

## Layout

```
apps/aimax_scheme   interpreter (values are BEAM terms; symbols are {:sym, _})
apps/aimax_core     buffers, editor state, primitives, NIF, procs, LLM, desktop
  priv/*.scm        the editor itself: commands, keymaps, modes, dired, themes
  native/aimax_ts   tree-sitter Rustler NIF
apps/aimax_ui       LiveView frontend (a client — no editor logic)
apps/aimax_rpc      JSON-RPC over ~/.aimax/sock ("eval is the API")
```

User config: `~/.aimax/ai-config.scm` then `~/.aimax/init.scm`, both optional.
