# compos.el - working instructions

Emacs rebuilt on the BEAM, scripted in Scheme, rendered by Phoenix LiveView.
Read `docs/ARCHITECTURE.md` once before making changes. `docs/SIMPLIFY-AUDIT.md`
holds the current state and the queue; `docs/KNOWN-FAILURES.md` the tests that
were already red.

## The one rule

**Elixir supplies mechanism. Scheme decides policy.**

Before adding Elixir code, ask: *can this be Scheme plus one small primitive?*
Usually yes. Commands, keybindings, modes, hooks, themes, dired, chat, display
rules - all live in `scheme/packages/*.scm`; the kernel is
`apps/compos_core/priv/editor.scm`. Elixir grows only for NIFs,
sockets, PTYs, parsers, schedulers, and raw buffer mechanics.

## Dev loop

Before an implementation or fix, load `apps/compos_core/priv/skills/code-change/SKILL.md`.
That skill defines the durable completion gate for repository changes.
Before an RL benchmark run or benchmark harness change, load
`apps/compos_core/priv/skills/chat-rl/SKILL.md`.

```sh
bin/test-fast                               # the suite in 4 partitions; all four apps must stay green
mix test                                    # one lane - use it when one readable log matters
SCHEME_TESTS=keymap mix test apps/compos_core/test/compos/scheme_suite_test.exs   # one kernel test file (priv/tests)
SCHEME_TESTS=morg mix test --include packages apps/compos_core/test/compos/package_suite_test.exs   # a package's tests
mix compos.reload scheme/packages/foo.scm   # a file outside the watched roots
bin/docs                                    # regenerate docs/manual from the live registries (howto.scm)
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:4004/
```

**Do not restart to see a change.** `Compos.Core.Hotload` watches `apps/*/lib`,
`apps/compos_core/priv`, `scheme/`, and the config home. Saving a `.scm` reloads only the
top-level forms whose text changed, then re-runs mode setup on the buffers
wearing a mode the reload redefined. Saving an `.ex` compiles in a child
`mix compile` and swaps the changed modules into the VM with no gap; a compile
error changes nothing. The echo area states the result.
`M-x reload-file` is the same reload, asked for by name.

A restart is still required for four changes: a new dependency, a change to
a supervision tree, a NIF rebuild, and a change that moves registrations
between tables or renames a door (a hot reload leaves the old table half
full). Keep the old door name as a one-line alias: packages outside the repo
name it at load, and a failed load stops the user init there. Use
`M-x restart-daemon`, which saves the desktop first. Never `pkill` a daemon:
the tree can hold other sessions and other worktrees.

Every save reaches the running daemon. Do not save a guessed fix into a tree
whose daemon a person is using; after a revert, restart instead of trusting
the reload. After a Scheme change, check that the live daemon holds it:
`(boundp 'new-fn)`, `(key-binding KEYS)` in a buffer of the mode.

Two hot-reload rules for Elixir: a field added to the state of a long-lived
GenServer must be read with `Map.get/3` and written with `Map.put/3`, because
the running process holds the old shape and `%{m | k: v}` raises. A Scheme
file that captures a primitive before shadowing it uses `alias-once!`, so a
whole-file re-eval does not capture the wrapper (see `editor.scm`).

Browser clients reload themselves (boot-id). Editor state (buffers, windows, theme) is restored from
`~/.compos/desktop.etf`. **Rule: everything survives a reload** - file buffers
reopen via `(visit)`; non-file buffers (chat, agent threads, scratch) persist
content+point+locals, and the mode setup fn rebuilds keys/overlays/folds from
locals on restore. New buffer kinds must keep this true.

**Rule: every chat buffer-local belongs to exactly one of the three lists**
in `scheme/packages/chat-mode.scm` - `chat-identity-locals` (who the chat is: survives reset,
restart, save), `chat-conversation-locals` (what was said: survives restart
and save, cleared by reset), `chat-runtime-locals` (mirrors a live runtime:
always stale after a restart, meaningless after a reset - cleared by both).
Add yours in the same commit that introduces it. Reset, restore, and save
all read these lists; a local in none of them is the reset/restore bug
class growing a new head.

Drive the editor headlessly:

```sh
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"eval","params":{"code":"(buffer-list)"}}' \
  | nc -U ~/.compos/sock
```

The socket of a daemon a person uses is for reading. Never `(load ...)` a
test file, `(run-test ...)`, or create, rename, or kill buffers, groups, or
windows there. Run a Scheme test through its ExUnit wrapper (`mix test
apps/compos_core/test/compos/NAME_scheme_test.exs`). When a change needs a
whole daemon (windows, groups, restore), boot an isolated one with its own
`COMPOS_HOME`, `COMPOS_PORT`, and `COMPOS_APP_PORT` (both ports must move),
drive that, then shut it down.

## Buffer links

A buffer link is one string that names a buffer. `C-c l` (M-x
`copy-buffer-link`) copies the link for the current buffer and line:

```
http://localhost:4004/b/%2FUsers%2Fsvs%2Fsrc%2Fcompos.el%2FREADME.md?line=42
```

The name is one percent-encoded path segment, so a file buffer keeps the
slashes in its path.

**When the user pastes a link, read the buffer it names.** Open the same
name under `/raw/` and you get the text:

```sh
curl -s http://localhost:4004/raw/%2FUsers%2Fsvs%2Fsrc%2Fcompos.el%2FREADME.md
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
- Plain ASCII in replies, commits, comments, and docs: `-` or `--`, straight
  quotes, `->`, `...`. No em dash, en dash, curly quote, arrow, or ellipsis
  character. In prose docs one paragraph is one line; a newline ends a
  paragraph, nothing else.
- Names: take the Emacs name for anything Emacs already named, spelled the
  Scheme way (`?` not `-p`, `!` for mutation). A name we invent says the verb
  and its direction (`remove-group-from-buffer`, `remove-buffers-from-group`),
  with no package prefix: the loader stamps the package and `apropos` finds
  it. Before inventing a name, ask what Emacs calls the concept.
- Unify. Two implementations of one idea is a bug, not a tradeoff. Before
  adding a tool, a mode, or a second send path, check whether an existing
  mechanism plus one small primitive does it. Explain a structural change
  before building it.
- Move policy outward: Elixir constants become Scheme, package constants
  become `defcustom`. Every surface ships one opinionated default, and the
  setting is what makes it overridable; a setting is not a reason to hedge.
- The browser is the only client. Do not propose a native renderer or shell
  logic; UI work goes in the LiveView client.
- All client JS lives in `.js` files (`apps/compos_ui/priv/static`, or beside
  its package in `scheme/packages`), never in `~s` strings or Scheme string
  literals. Values the server supplies go as data attributes or a JSON config
  element, never spliced into code.
- Measure before styling. A face renders as a `.f-NAME` class fed by
  `--NAME-ATTR` custom properties; read the resolved value and the contrast
  in the browser before changing a face, size, or layout.
- Terse replies: outcome first, bullets, no recaps, no verification narration.
- Test everything, especially the Scheme kernel. Test an interaction
  through `KeyDispatch.handle_key/1` - the same path the GUI uses. Test
  policy in Scheme: put a `deftest` where the test calls the function and
  reads the value. A package's tests live beside it, as in Emacs:
  `scheme/packages/NAME-test.scm`; the kernel's live in `priv/tests`.
  `mix test` runs the kernel's; the package tests run apart
  (`--include packages`, or `M-x run-package-tests`).
  `M-x run-scheme-tests` runs the kernel's Scheme tests alone.
- A test names the command, never the key that happens to run it. A
  binding moves; the behaviour is what the test is for. **Never assert a
  production binding at all** - not `C-x b` names the switcher, not the
  Emacs core keys, not a mode's chord table. A binding is a preference,
  and a test that names one goes red the day somebody moves it, reporting
  a broken editor when the editor is fine. Test that BINDING WORKS with
  keys you bind yourself: `priv/tests/keymap-test.scm` binds dummy keys
  under `<f9>` to its own dummy commands and presses those.
- While working, run only the focused test file for the change. The full
  sweep runs once, before the commit. Run a suite once and `tee` its log to a
  file, then grep the file; do not re-run a suite to see a summary again.
- Verify UI changes in a real browser, screenshot, then commit.
- Use subagents for verification sweeps to keep context clean.
- Emacs is the reference: copy its semantics unless there's a reason not to.
- When the user names an Emacs feature, implement its shared mechanism. Do not imitate only the named key sequence.

### Rulings

- The point belongs to the user. No hook, draw, popup, restore, or process
  calls `goto-char!` or `list-goto-index!`; a draw restores the row by key,
  and a buffer opened again is where it was (`docs/LISTS.md`, "Point").
- A mode belongs to the user. A default mode is what a new buffer starts in.
  Guard with `(unless (buffer-local BUF 'mode-name) ...)`; never re-set a mode
  the buffer already has, for minor modes and presentation locals too.
- Groups never leak. A buffer of group A never appears in a frame standing in
  group B, and an agent in group A opens its buffers in group A
  (`docs/groups.md`).
- An agent opens a file only when the user asks, in the other window:
  `(get-other-window)` never answers the active window and grows the layout
  below the target capacity.
- Every write goes through `write-file!` or `buffer-save!`, and both consult
  `write-check!`. Add a rule with `defwrite-rule!`, never a new write path
  (`docs/BUFFER.md`, "Following the file").
- The Scheme lanes (`:ui`, per buffer, per connection, task) stay. They keep
  a key fast while agents and sockets run; do not collapse policy into one
  serial process.

## Layout

```
apps/compos_scheme   interpreter (values are BEAM terms; symbols are {:sym, _})
apps/compos_core     buffers, editor state, primitives, NIF, procs, LLM, desktop
  priv/*.scm        the kernel: editor.scm, dired, themes, transient, init.scm
scheme/packages      every package: commands, modes, apps, chat, groups, dired verbs
  native/compos_ts   tree-sitter Rustler NIF
apps/compos_ui       LiveView frontend (a client - no editor logic)
apps/compos_rpc      JSON-RPC over ~/.compos/sock ("eval is the API")
```

`docs/SCHEME-GOTCHAS.md` lists the builtins whose behaviour a reader would
guess wrong. Read it before writing Scheme that walks JSON or scans text.

Boot order is explicit: `editor.scm`, the small stdlib files, then stock
`priv/init.scm`, which lists every bundled package in dependency order. After
stock boot, user config runs as `~/.compos/ai-config.scm`, `~/.compos/init.scm`,
then saved `~/.compos/custom.scm`. `(load NAME)` searches `load-path`: priv, its
packages, the project's `scheme/packages`, the config home, and its
packages. User-installed packages load only when the user init names them
with `(load "name.scm")`.
