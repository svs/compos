# Prompt: move the policy tests to Scheme

Paste everything below into a new session.

---

Continue moving ExUnit tests that test **Scheme policy** into the Scheme
test suite at `apps/compos_core/priv/tests/*.scm`. Read
`apps/compos_core/priv/packages/test.scm` first — it is the framework, and
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

**Policy moves. Mechanism stays. Behaviour is policy; dispatch is not.**

Do not split a package by how its ExUnit file was written. paredit and
morg were first split at "does this test press a key", which left 37 and
24 tests behind. That was the wrong axis: every paredit behaviour and
every morg behaviour is a NAMED COMMAND, so a Scheme test sets a buffer
and a point, runs the command, and reads the text. Pressing the key
checked the same thing and paid the dispatch path to say so.

What a key test still earns: that the key REACHES the command through
prefixes, local versus global maps, remaps and minor-mode precedence;
self-insert interleaved with a mode; undo batching; and anything hung off
the key path rather than the command path. show-paren is the clean
example — it does not fire on `run-command`, so Scheme cannot see it, and
those two tests belong in ExUnit. That is a handful per keymap, not one
per behaviour.

A keymap is data. `*paredit-keys*` is a table of (KEY COMMAND FALLBACK),
so ONE test reads it and asserts every key names a live command.

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
(check-equal! (global-key-command "C-x b") "group-switch-buffer" ...)
(run-command "group-switch-buffer")
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
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"eval","params":{"code":"(begin (load-tests!) (filter (lambda (r) (not (null? (nth 1 r)))) (map (lambda (n) (list n (run-test n))) (test-names))))"}}' | nc -U ~/.compos/sock
```

Then the bridge, which is what CI runs:

```sh
MIX_TEST_PARTITION=1 mix test apps/compos_core/test/compos/scheme_suite_test.exs
```

`Compos.SchemeSuiteTest` runs one eval per test, so a test that raises
fails alone. It also asserts the canary
(`priv/tests/canary-test.scm`, `zz-canary-always-fails`) loaded, ran, and
came back red — that is what proves a file did not silently fail to load
and take its tests with it. Leave the canary alone.

**Do not claim a conversion works without running it.** I shipped a
`run-scheme-tests` command that called a nonexistent primitive and said it
worked in the commit message. Run it.

Finish with `bin/test-fast` in a worktree at HEAD, not in this tree:
another session edits it, and its uncommitted work adds failures that are
not yours. A clean worktree answers 35-42, and the floor keeps dropping as
key-driven tests become Scheme tests: 38, 39, 40 and 42 before the
paredit and morg redo, 39 and 35 after it. The count moves between runs, and so do the
names, so diff the failure NAMES against a baseline instead of trusting
the number, and check whether any name sits in a file you touched.

A name that sits in a file you touched is not yet yours. Run that file
alone across three seeds, then run it beside the Scheme suite, then run
the PRE-CHANGE commit twice. `pull adds the current group without
switching context` failed twice at HEAD and in neither of the two runs
before the change, which looked conclusive; it then failed at the
pre-change commit as well. Two runs is not a baseline.

## State at handoff

Commit `bd3a259`. Scheme suite: 398 tests, one red by design. Full suite
in a clean worktree: 36 and 30 failures over two runs, inside the 35-42
band, with the Scheme suite green in both.

ExUnit files fully retired: `graphql`, `imenu`, `buffer_cache`,
`code_structure`, `chat_heal`, `notmuch`, `code_mode`, `paredit`.

What is left in ExUnit, and why each one is there:

| file | left | why |
|---|---|---|
| `chrome` | 28 | a stub socket process and the frames it receives — not read yet |
| `mcp` | 7 | 6 drive the Elixir client API; 1 waits on the closure bug |
| `morg` | 2 | set-mode! has no teardown, so markdown-mode is unbuilt |
| `annotate` | 1 | SchemeAPI.block_click, the entry a browser click arrives on |
| `writing` | 1 | the Reactor delivers the word count; the counter itself is Scheme |
| `group_switch_command` | 1 | red in every baseline: marked pull joins no group |
| `marginalia_project` | 1 | red in every baseline: the modal switcher's narrowing |
| `author` | 20 | provenance is being rewritten on a CRDT — see below |
| `editor`, `evil`, … | | the interaction suite and the Elixir APIs |

**`author` was skipped deliberately.** `docs/PROVENANCE-CRDT.md` says the
current subsystem "does not survive" the move to Loro. Five of its tests
cover `buffer-author-fold` and `Buffer.id` — the changeset layer being
retired — and seven test span arithmetic a CRDT does natively. The four
already moved (`author-line-runs`, `lines-mine?`, `buffer-authors`,
`with-edit-author`) are the durable contract, and now pin what the
rewrite must keep satisfying.

## What moved, and what could not

242 tests moved. `graphql_test`, `imenu_test`, `buffer_cache_test`,
`code_structure_test`, `chat_heal_test`, `feeds_test`, `skills_test` and
`mode_icon_test` are gone entirely. Eleven more files keep only what
Scheme cannot hold: `apropos_test`, `sentry_test`, `permission_test`,
`web_browse_test`, `chat_rename_test`, `marginalia_project_test`,
`annotate_test`, `group_switch_command_test`, `occur_ts_test`,
`grammar_test` and `scheme_ide_test`.

The last three name the axis better than any rule does. `occur_ts_test`
keeps one test, and it is the key path: `M-s t` through the prefix, and
the query read before any list exists. `grammar_test` keeps the three
that call the Rust side. `scheme_ide_test` keeps four, and every one
reads render state — the echo area and the completion dropdown, which
Scheme cannot see.

Three limits decided every split:

- ~~Scheme cannot remove a directory.~~ **Wrong, and it was wrong when
  first written.** `shell-command->string` is a primitive, so a test can
  run `rm -rf` and `chmod +x` like any other. Both are verified. A test
  can therefore BUILD ITS OWN FIXTURE — write the stub, make it
  executable, point the package's Scheme seam at it, delete it after.
  That is how `notmuch_test` already works in ExUnit, and its seam
  (`notmuch-program`) is Scheme. Prefer a path under `(compos-home)`: the
  suite runs in a live editor, and `rm -rf` from a test wants a short
  leash. The four directory tests in `skills_test` and `mode_icon_test`
  moved on this, and each one builds and removes its own fixture.
- **Scheme cannot set an environment variable.** There is `getenv` and no
  `setenv`. This is what holds `keys_test` where it is.
- ~~Scheme cannot wait for an answer.~~ **Fixed.** `(wait-until PRED
  &optional TIMEOUT-MS INTERVAL-MS)` polls and answers #t, or #f at the
  deadline. It blocks its lane, the way `mcp-call!` does, and caps itself
  at 10s so a runaway predicate stays inside Lane's 30s timeout.

  **It cannot wait for work that needs its own lane.** lsp.scm delivers
  its events on `:ui`, so waiting there for a connection to reach "ready"
  blocks the transition it waits for and times out every time — the same
  server polled from outside an eval is ready in two seconds. A debounce,
  a buffer another process writes, or an MCP reply are all fine: they
  complete elsewhere. Check where the work finishes before reaching for
  it.

  It unlocks about 11 tests, not the 36 first claimed here. That count
  scanned each test BODY for a fixture path, and in the LSP, MCP and
  watch files the fixture lives in the setup helper — those tests need
  `wait-until` AND the fixture path AND a removable temp directory, so
  waiting was never their binding constraint. **Read the helper, not only
  the test.** None of the 11 have been moved yet.
- **Helper names are global across test files.** load-tests! reads the
  directory in order, so a `(define (t--foo ...))` in two files takes the
  definition of whichever loaded last. Two morg files both defined
  `t--morg!` with different arities and five tests died with "arity
  mismatch" naming neither file. The bridge now fails on any name defined
  twice. Prefer one test file per package.
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
(`config/config.exs`). It never opens `~/.compos/sock`. That is the gate.

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

`feeds`, `occur_ts`, `grammar` and `scheme_ide` are done. What is left of
the long tail is thinner than the first count: two or three each in
`code_mode`, `mcp_hub`, `writing`, `sockets`, `core` and `daemon`.

Three of those were read again and answered no. `fold_tag_test` drives
`Buffer.set_hidden/3`, `clear_hidden` and `render_snapshot` — tagged
folds are buffer mechanics, and every assertion reads a range list off
the snapshot. `sockets_test` names `Daemon` and `Proc` directly. Most of
`writing_test` is chords: Shift-arrows, Alt-arrows and the selection
keys, which is the key path doing exactly what a key test is for. Two
tests there do move (`count-words`, and the locals `writing-mode` sets),
and one test does not earn a file — take them with the tail.

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

Blocked on a seam, not on judgement:

- **The fake servers are in the wrong tree.** `test/support/fake_lsp_server.exs`
  and `fake_mcp_server.exs` are why 12-15 tests cannot move: `priv/tests`
  must not reach into the Elixir test tree, and a release ships no
  `test/`. Moving them under `priv/`, with `delete-directory!` beside
  them for the temp project, is the largest single unlock left — bigger
  than any primitive. `lsp_scheme_test` is the shape of it: five tests
  that need `wait-until` AND the fixture path AND a directory they can
  remove.
- **`setenv`** unlocks `keys_test` (14). The whole key chain is Scheme
  behind it.
- ~~`delete-directory!`~~ is not needed: `shell-command->string` already
  runs `rm -rf`. The four tests in `skills_test` and `mode_icon_test` are
  movable today.
- **A Scheme-visible LLM stub seam** unlocks `chat_compact_test` (12).
  It is pure policy otherwise, but the model is stubbed with
  `Application.put_env(:compos_core, :llm_request_fun, ...)`, which Scheme
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
| the `compos_scheme` suites | 76 tests of the interpreter, which is mechanism |

## Also open, unrelated to this task

- Reloading `groups.scm` wipes every group record — line 20 is a plain
  `(define *group-records* '())`, and `persist-global!` only restores at
  restart. This breaks "everything survives a reload".
- `revert-buffer`, `kill-buffer` and `save-buffer` have no
  modified-buffer or changed-on-disk guard. The user wants to revisit
  this using provenance.
