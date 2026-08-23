# Prompt: move the policy tests to Scheme

Paste everything below into a new session.

---

Continue moving ExUnit tests that test **Scheme policy** into the Scheme
test suite at `apps/aimax_core/priv/tests/*.scm`. Read
`apps/aimax_core/priv/packages/test.scm` first — it is the framework, and
its header explains the shape.

## Why

A policy test does not need a keystroke. Measured on this repo:

| style | per test |
|---|---|
| Scheme, over the socket | 1.7 ms |
| Scheme, through the ExUnit bridge | 3.3 ms |
| ExUnit calling `Session.eval` | 11.5 ms |
| ExUnit driving `KeyDispatch` | 307 ms |

The 180x is **not** Scheme versus Elixir. `group_switch_command_test` is
ordinary ExUnit at 11.5 ms because it calls `Session.eval` instead of
pressing keys. Not driving the UI is worth ~25x; Scheme is worth the
rest, plus no escaping and no string-diff failures.

Wall clock matters more: `mix test` on one Scheme file is 2.85 s, of
which ~2.8 s is compile and app boot. The same tests over the live
socket are 0.017 s. In the editor, `M-x run-scheme-tests` answers in
under a second with no restart.

## The rule that decides what moves

**Policy moves. Mechanism stays.**

Ask what the assertions read. If they read Scheme values —
buffer-locals, catalog entries, group records, keymap rows — it is
policy, and it moves. If they call an Elixir API — `Buffer.replace_range/5`,
`Buffer.undo/1`, `Editor.snapshot/0` — that is mechanism, and it stays in
ExUnit.

`buffer_replace_test` looks movable by every mechanical measure: 7 tests,
eval-heavy, zero `KeyDispatch`. It is not. It drives
`Buffer.replace_range/5` with a `source:` option that has no Scheme
surface. **Eval-heavy is not the same as movable.** Check the assertions,
not the imports.

A test of an interaction keeps driving `KeyDispatch` — that is the same
path the GUI uses, and it is what caught two real bugs in the switcher.
Do not move those.

## The pattern

```scheme
(domain! 'testing)
(effects! '(write))

(deftest 'a-rename-keeps-every-membership
  "the point of the id: a rename does not touch the buffers"
  (lambda ()
    (let ((id (group-record-create! "zztest-carry"))
          (buf "*zztest-carry*"))
      (buffer-create buf)
      (buffer-add-group! buf id)
      (group-rename! id "zztest-carried")
      (check-equal! (buffer-group buf) id "the buffer still holds the same id")
      (buffer-kill! buf)
      (group-record-delete! id))))
```

Checks: `check-equal!`, `check-true!`, `check-false!`, `check-contains!`.
They **record** a failure and return, so one bad assertion still reports
every other assertion in the same test. Each carries a label; the failure
prints both values.

Helpers: `test-buffer!` makes or empties a buffer and gives it text.

## Rules for a converted test

- **Hermetic.** Make what you need, delete it at the end. Tests share one
  live editor — there is no per-test sandbox. Verify: the group count and
  buffer count are the same before and after a full run.
- **Prefix everything `zz`** so a leak is obvious and greppable.
- **Restore any global you touch** (`customize-set!` values especially).
  See `t--cam-reset!` in `code-agent-mode-test.scm`.
- **Keep the test names and the intent** of the ExUnit original. This is
  a move, not a rewrite. If you find a real bug while converting, fix it
  in a separate commit.
- **Delete the ExUnit file** in the same commit (`git rm`).

## Keymaps: assert the map, then run the command

Do not press a key to find out what it does. That checks two facts as one
and takes 300 ms to say so.

```scheme
(check-equal! (global-key-command "C-x b") "group-switch-to-buffer" ...)
(run-command "group-switch-to-buffer")
(check-true! (string? (minibuffer-selected)) ...)
```

Use `global-key-command` (in `keymap-test.scm`) which reads `global-keys`.
**Do not use `key-binding` for this.** It answers what a key means *here*,
and "here" is the window's buffer — not the buffer `with-current-buffer`
names. A test written with `key-binding` reads whatever the editor happens
to show; mine passed until a buffer with a live isearch was on screen and
`C-s` answered `isearch-repeat-forward`.

## Traps found the hard way

- **`nil` is TRUE in this Scheme.** `minibuffer-selected` answers `nil`
  when nothing is selected. Ask `(string? x)`, never `(if x ...)`.
- **Variadic is `&rest`, not the dotted form.** `(define (f . xs) ...)`
  raises "arity mismatch".
- **No `buffer-set-text!`.** Use `test-buffer!`, or delete-range plus
  insert.
- **No hash tables, and `sort` takes no comparator.** Available:
  `assoc`, `member`, `filter`, `fold`, `remove`, `dedupe-names`.
- **`(key-binding "")` answers `prefix`** — an empty sequence is a prefix
  of every key.
- Check a primitive exists before leaning on it:
  `(boundp 'the-name)`.

## Verifying

Fast loop, no boot:

```sh
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"eval","params":{"code":"(begin (load-tests!) (filter (lambda (r) (not (null? (nth 1 r)))) (map (lambda (n) (list n (run-test n))) (test-names))))"}}' | nc -U ~/.aimax/sock
```

Then the bridge, which is what CI runs:

```sh
MIX_TEST_PARTITION=1 mix test apps/aimax_core/test/aimax/scheme_suite_test.exs
```

`Aimax.SchemeSuiteTest` runs one eval per test, so a test that raises
fails alone. It also asserts the canary
(`priv/tests/canary-test.scm`, `zz-canary-always-fails`) loaded, ran, and
came back red — that is what proves a file did not silently fail to load
and take its tests with it. Leave the canary alone.

**Do not claim a conversion works without running it.** I shipped a
`run-scheme-tests` command that called a nonexistent primitive and said it
worked in the commit message. Run it.

Finish with `bin/test-fast` in a worktree at HEAD, not in this tree:
another session edits it, and its uncommitted work adds failures that are
not yours. A clean worktree answers 38-42: four runs across two commits
gave 38, 39, 40 and 42. The count moves between runs, and so do the
names, so diff the failure NAMES against a baseline instead of trusting
the number, and check whether any name sits in a file you touched.

A name that sits in a file you touched is not yet yours. Run that file
alone across three seeds, then run it beside the Scheme suite, then run
the PRE-CHANGE commit twice. `pull adds the current group without
switching context` failed twice at HEAD and in neither of the two runs
before the change, which looked conclusive; it then failed at the
pre-change commit as well. Two runs is not a baseline.

## State at handoff

Commit `e0b5312`. Scheme suite: 214 tests, one red by design.

In Scheme:

| file | tests |
|---|---|
| `graphql-test.scm` | 24 (moved) |
| `apropos-test.scm` | 22 (moved) |
| `code-structure-test.scm` | 13 (moved) |
| `annotate-test.scm` | 12 (moved) |
| `chat-rename-test.scm` | 12 (moved) |
| `code-agent-mode-test.scm` | 11 (moved) |
| `group-records-test.scm` | 11 (moved) |
| `skills-test.scm` | 10 (moved) |
| `groups-test.scm` | 9 |
| `mcp-policy-test.scm` | 4 (moved) |
| `web-browse-test.scm` | 9 (moved) |
| `mode-icon-test.scm` | 8 (moved) |
| `morg-structure-test.scm` | 8 (moved) |
| `chat-heal-test.scm` | 7 (moved) |
| `keymap-test.scm` | 7 |
| `edit-semantics-test.scm` | 6 (moved) |
| `help-page-test.scm` | 5 (moved) |
| `paredit-scan-test.scm` | 5 (moved) |
| `permission-test.scm` | 6 (moved) |
| `sentry-test.scm` | 6 (moved) |
| `marginalia-test.scm` | 5 (moved) |
| `imenu-test.scm` | 4 (moved) |
| `mode-toggle-test.scm` | 4 (moved) |
| `buffer-cache-test.scm` | 3 (moved) |
| `recipes-test.scm` | 2 (moved) |
| `canary-test.scm` | 1, always red |

## What moved, and what could not

179 tests moved. `graphql_test`, `imenu_test`, `buffer_cache_test`,
`code_structure_test` and `chat_heal_test` are gone entirely. Ten more
files keep only what Scheme cannot hold: `apropos_test`, `skills_test`,
`mode_icon_test`, `sentry_test`, `permission_test`, `web_browse_test`,
`chat_rename_test`, `marginalia_project_test`, `annotate_test` and
`group_switch_command_test`.

Three limits decided every split:

- **Scheme cannot remove a directory.** It has `make-directory!`,
  `write-file!` and `delete-file!`, but no `rmdir`. A test that builds a
  fixture tree stays in ExUnit: two in `skills_test`, two in
  `mode_icon_test`.
- **Scheme cannot set an environment variable.** There is `getenv` and no
  `setenv`. This is what holds `keys_test` where it is.
- **Scheme cannot wait for an answer.** There is no poll and no sleep, so
  a test that starts an asynchronous job and waits for it stays in ExUnit:
  the LSP and MCP subprocess tests, and the Substack conversion.
- **A registration is one-way.** `define-command`, `define-list-mode!`,
  `public!`, `define-tool!`, `allow-command-when!` and `catalog-register!`
  all write registries with no removal call. Tests that register clear the
  Scheme half by hand (`*catalog*`, `*catalog-keys*`, `*public-api*`,
  `*public-keys*`, `*list-modes*`, `*mode-setups*`, `*mode-docs*`,
  `*mode-icons*`, `*llm-tools*`, `*command-permission-rules*`). The M-x
  command table is Elixir, and a test command name stays until the next
  restart. A removal primitive would close this.

## Do not run the suite in a session you care about

`mix test` is self-contained: the test env boots its own editor in its own
BEAM, with `home:` and the socket keyed on the checkout and the partition
(`config/config.exs`). It never opens `~/.aimax/sock`. That is the gate.

`M-x run-scheme-tests` runs the same files against YOUR daemon, and it is
not free. Ten of the sixteen files move a window, open the switcher,
display a list buffer, or write a file. Three leave a name in the M-x
table until the next restart, because the Elixir command table has no
removal call. Worst: `web-browse-test.scm` and `sentry-test.scm` install a
stub into `*web-fetch*` and `*sentry-transport*` and restore it at the
end. A check that FAILS still restores. A test that RAISES does not, and
your real browsing stays stubbed with nothing on screen to say why.

Use the live loop while writing a test, on a session you can restart. Use
`mix test` to believe the answer.

## What a live test still owes you

`M-x run-scheme-tests` runs against the person's own daemon. A test that
touches a global must put it back, and that now includes their files and
their window: `web-browse-test.scm` saves the visited-URL file and the
current buffer before it browses. A test that seems to need a fixture on
disk probably needs a seam instead — `sentry-test.scm` and
`web-browse-test.scm` both replace one Scheme variable and reach nothing.

## The two red tests are gone, and so is the backfill

The first pass left two tests in ExUnit because they were red: the
bundled backfill and the frozen Luna count. `ffbdb8a` answered them by
deleting the Luna backfill — the artifact guessed domain and effects for
496 entries, the effects feed the permission policy, and the artifact was
stale. `metadata-source` now has two values, "declared" and "unknown".

`9effeee` then moved both tests, rewritten against that reality:
`an-entry-declares-its-metadata-or-admits-it-does-not-know` holds the two
values, and `unstamped-bundled-declarations-do-not-multiply` freezes the
unstamped count at 587. **Lower that number, never raise it.** A new
declaration stamps itself.

`98dd0c8` fixed a real bug the move surfaced: `catalog-register!`
appended the caller's meta plist after the keys it computed from it, so
an entry carried `domain` twice — once as a string and once as a symbol.
`plist-get` reads the first, so a reader saw the right value and a walker
saw both. `no-entry-carries-the-same-key-twice` holds that line.

## The queue

Every remaining file was read by what its assertions read, not by how
much `Session.eval` it calls. Eval density lies: `chrome_test` is 32
eval-heavy tests and none of them move, because they assert on frames a
stub socket process received.

What is left is the long tail: two or three each in `code_mode`,
`grammar`, `mcp_hub`, `writing`, `occur_ts`, `fold_tag`, `feeds`,
`scheme_ide`, `sockets`, `core` and `daemon`. Roughly 25 tests.

`code_mode_test` has four that read Scheme values, but three of them run
`M-x code-mode` first, which joins a group, opens a chat and loads the
coding presets. In a live editor that is a lot of state to put back, and
one test alone does not earn a file. Take it with the long tail.

`mcp_test` is done: 4 of 16 moved. The other twelve need the fake server
in `test/support`, or catch a raise, or run the tool loop in Elixir.
`mcp-call!` and `mcp-tools` connect and wait inside Scheme, so they read
as movable — they are not, because the command they register is a path
into the test tree, and `priv/tests` must not reach there.

A file's setup can be more destructive than any of its tests.
`group_switch_command_test` wiped `*group-records*` before every test, so
moving it as written would have deleted the person's groups on the first
`M-x run-scheme-tests`. Read the setup before you read the assertions,
and prefer a delta over a clean slate.

Blocked on a seam, not on judgement. Three small additions unlock 28
tests:

- **`setenv`** unlocks `keys_test` (14). The whole key chain is Scheme
  behind it.
- **`delete-directory!`** unlocks the four fixture tests still held in
  `skills_test` and `mode_icon_test`.
- **A Scheme-visible LLM stub seam** unlocks `chat_compact_test` (12).
  It is pure policy otherwise, but the model is stubbed with
  `Application.put_env(:aimax_core, :llm_request_fun, ...)`, which Scheme
  cannot reach. `sentry-test.scm` shows the shape a Scheme seam should
  take.

Confirmed staying:

| file | why |
|---|---|
| `editor_test` | 127 of 148 drive `KeyDispatch`, which is the point of it |
| `chrome_test` | a stub socket process and the frames it receives |
| `spotify_test` | the same wire, plus keys |
| `chat_agent_test` | an Elixir Transport behaviour |
| `author_test` | `Buffer` provenance calls |
| `lsp_conn_test`, `lsp_primitives_test` | a fake server, polled |
| `overlay_test`, `buffer_replace_test` | `Buffer` range mechanics |
| `usage_shape_test` | `LLM.usage_strings/2` |
| `session_safe_test` | proves the Session survives a bad eval |
| the `aimax_scheme` suites | 76 tests of the interpreter, which is mechanism |

## Also open, unrelated to this task

- Reloading `groups.scm` wipes every group record — line 20 is a plain
  `(define *group-records* '())`, and `persist-global!` only restores at
  restart. This breaks "everything survives a reload".
- `revert-buffer`, `kill-buffer` and `save-buffer` have no
  modified-buffer or changed-on-disk guard. The user wants to revisit
  this using provenance.
