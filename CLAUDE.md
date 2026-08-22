# ai-max.el — working instructions

Emacs rebuilt on the BEAM, scripted in Scheme, rendered by Phoenix LiveView.
Read `docs/ARCHITECTURE.md` once before making changes. `docs/HANDOFF.html` has the
current state, queue, and landmines (open it in the editor: `C-x C-f`, then
`C-c C-v` to preview).

## The one rule

**Elixir supplies mechanism. Scheme decides policy.**

Before adding Elixir code, ask: *can this be Scheme plus one small primitive?*
Usually yes. Commands, keybindings, modes, hooks, themes, dired, chat, display
rules — all live in `apps/aimax_core/priv/*.scm`. Elixir grows only for NIFs,
sockets, PTYs, parsers, schedulers, and raw buffer mechanics.

## Dev loop

Before an implementation or fix, load `.agents/skills/code-change/SKILL.md`.
That skill defines the durable completion gate for repository changes.
Before an acceptance run or suite change, load
`.agents/skills/acceptance-testing/SKILL.md`.

```sh
bin/test-fast                               # the suite in 4 partitions; all four apps must stay green
mix test                                    # one lane — use it when one readable log matters
mix aimax.restart                           # stop, start, and wait for the daemon
mix aimax.reload apps/aimax_core/priv/packages/foo.scm   # one package, no restart
mix aimax.reload --all                      # every package plus ~/.aimax/init.scm
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:4004/
```

Never `pkill` a daemon: the tree can hold other sessions and other
worktrees, and `mix aimax.restart` stops this one through its own socket.
A restart is required for Elixir code and for `priv/editor.scm`. A package
in `priv/packages/` reloads without one. Browser clients reload
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

## Buffer links

A buffer link is one string that names a buffer. `C-c l` (M-x
`copy-buffer-link`) copies the link for the current buffer and line:

```
http://localhost:4004/b/%2FUsers%2Fsvs%2Fsrc%2Fai-max.el%2FREADME.md?line=42
```

The name is one percent-encoded path segment, so a file buffer keeps the
slashes in its path.

**When the user pastes a link, read the buffer it names.** Open the same
name under `/raw/` and you get the text:

```sh
curl -s http://localhost:4004/raw/%2FUsers%2Fsvs%2Fsrc%2Fai-max.el%2FREADME.md
curl -s http://localhost:4004/raw            # every buffer name, one per line
```

A person who opens the `/b/` link gets the editor, at that buffer and line.
The line rides in the query string because a fragment never reaches the
daemon. Build a link for any buffer with `(buffer-link NAME)`.

## House style

### Scheme catalog metadata

Every LLM that writes Scheme must stamp its public definitions. Set one
`domain!` and one `effects!` scope before `define-command`, `define-mode`,
`public!`, `defcustom`, `defrecipe!`, or `defcomponent` forms.

Before writing or editing a Scheme package, query `apropos` for the existing
API and components. Before choosing or defining UI, read `docs/COMPONENTS.md`.
Reuse a catalogued component when it fits.

```scheme
(domain! 'files)
(effects! '(read))
```

Use one level: `pure`, `read`, `write`, or `destroy`. Add `external`,
`execute`, or `spend` when they apply. Do not use `read` as a fallback.
Use `unknown` when the source does not prove an effect. Use `catalog-meta!`
for a single override in a mixed section. Package and namespace come from the
loader; call `namespace!` only when the public vocabulary differs.

- Write to **ASD-STE100 (Simplified Technical English)**. The rules that
  matter here:
  - One idea per sentence. Maximum 20 words in instructions, 25 in
    descriptions. Maximum 6 sentences per paragraph.
  - Use the active voice. Name the agent: "the setup fn rebuilds the keys",
    not "the keys are rebuilt".
  - Use simple tenses. Do not use the perfect tenses.
  - Use one word for one thing. Do not call it a server here and a
    connection there.
  - Keep technical names and technical verbs: `mcpServers`, GenServer, byte
    offset, connect, publish. These are approved terms.
  - Do not use metaphor, idiom, or literary phrasing. Write "the row shows
    the error", not "the row that went red can say why".
  - Do not remove articles or other words to make a sentence shorter.
  - This applies to replies, commit messages, and comments in code.
- Terse replies: outcome first, bullets, no recaps, no verification narration.
- Test everything, especially the Scheme kernel. Test an interaction
  through `KeyDispatch.handle_key/1` — the same path the GUI uses. Test
  policy in Scheme: put a `deftest` in `priv/tests/*.scm`, where the test
  calls the function and reads the value. `mix test` runs both;
  `M-x run-scheme-tests` runs the Scheme half alone.
- A test names the command, never the key that happens to run it. A
  binding moves; the behaviour is what the test is for.
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
