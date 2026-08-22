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

Finish with `bin/test-fast` and compare the failure count to the baseline
below. It moves between runs — a good part of this suite is timing flake —
so treat anything inside 43-53 as unchanged, and investigate outside it.

## State at handoff

Commit `6c26c88`. Suite: 45 failures, inside the 43-53 band. Scheme suite: 115 tests, one
red by design.

In Scheme:

| file | tests |
|---|---|
| `apropos-test.scm` | 19 (moved) |
| `graphql-test.scm` | 24 (moved) |
| `code-structure-test.scm` | 13 (moved) |
| `skills-test.scm` | 10 (moved) |
| `code-agent-mode-test.scm` | 11 (moved) |
| `groups-test.scm` | 9 |
| `mode-icon-test.scm` | 8 (moved) |
| `keymap-test.scm` | 7 |
| `edit-semantics-test.scm` | 6 (moved) |
| `imenu-test.scm` | 4 (moved) |
| `buffer-cache-test.scm` | 3 (moved) |
| `canary-test.scm` | 1, always red |

## What the last pass moved, and what it left

81 tests moved. `graphql_test`, `imenu_test`, `buffer_cache_test` and
`code_structure_test` are gone entirely. `apropos_test`, `skills_test` and
`mode_icon_test` keep only what Scheme cannot hold.

Three limits decided every split:

- **Scheme cannot remove a directory.** It has `make-directory!`,
  `write-file!` and `delete-file!`, but no `rmdir`. A test that builds a
  fixture tree stays in ExUnit: two in `skills_test`, two in
  `mode_icon_test`.
- **Scheme cannot set an environment variable.** There is `getenv` and no
  `setenv`. This is what holds `keys_test` where it is.
- **A registration is one-way.** `define-command`, `define-list-mode!`,
  `public!` and `catalog-register!` all write registries with no removal
  call. Tests that register clear the Scheme half by hand
  (`*catalog*`, `*catalog-keys*`, `*public-api*`, `*public-keys*`,
  `*list-modes*`, `*mode-setups*`, `*mode-docs*`, `*mode-icons*`). The M-x
  command table is Elixir, and a test command name stays until the next
  restart. A removal primitive would close this.

## The queue

| file | tests | verdict |
|---|---|---|
| `keys_test` | 14 | needs a `setenv` primitive first |
| `mcp_test` | 16 | 4 movable; the rest drive a real subprocess |
| `lsp_primitives_test` | 5 | drives a fake server and polls it — stays |
| `overlay_test` | 6 | `Buffer.set_overlays/2` is mechanism — stays |
| `usage_shape_test` | 8 | `LLM.usage_strings/2` is Elixir — stays |
| `session_safe_test` | 2 | proves the Session survives a bad eval — stays |
| `buffer_replace_test` | 7 | mechanism — stays |

`mcp_test` has four tests that need no subprocess: the ACP translation,
the system note, the quiet failure on an unknown preset, and
`chat-tool-list`. The rest connect to `test/support/fake_mcp_server.exs`
and wait for the handshake, which Scheme has no way to poll.

**A `setenv` primitive would unlock `keys_test`.** It is one primitive,
and the whole key chain is Scheme policy behind it.

## One thing to know about the live editor

`M-x run-scheme-tests` runs against a daemon that hot-reloaded packages.
The reload path stamps `origin "user"`, so the Luna backfill does not
apply to a reloaded package, and its catalog entry can read different
effects than a fresh boot gives. `notmuch-trash` shows this: `("write")`
in a long-lived daemon, `("destroy")` on a fresh boot. CI boots fresh.
Restart before trusting a catalog failure in the live editor.

## Also open, unrelated to this task

- Reloading `groups.scm` wipes every group record — line 20 is a plain
  `(define *group-records* '())`, and `persist-global!` only restores at
  restart. This breaks "everything survives a reload".
- `revert-buffer`, `kill-buffer` and `save-buffer` have no
  modified-buffer or changed-on-disk guard. The user wants to revisit
  this using provenance.
