# Bug: a handler closure that captures a local never fires in its own eval

Paste this into a new session. Everything below was verified on
`dcdc4e7`, in the test env (`MIX_TEST_PARTITION=1 MIX_ENV=test mix run`).

## Resolution

Fixed on the `codex/beam-scheme` worktree. Before a host primitive or a
shared binding can expose a closure, the evaluator promotes that closure's
reachable local frames into ETS and removes them from the local tier. Later
mutation writes through to ETS, so another worker can invoke the callback
before the registering eval returns.

Reactor now also keeps one monitored task per rule, coalesces events while it
runs, and restores the attempted batch on errors or task death. The regression
coverage is in `on_change_test.exs`, `scheme_gc_test.exs`, and
`single_actor_test.exs`.

## Summary

`(on-change! BUF (lambda ...))` registers a handler. If that lambda
captures a binding local to the eval that registered it, the handler
**never runs for changes made in that same eval**, and the change event is
dropped with nothing said. If the lambda captures only globals, it works.

This is not a test-only problem. Every package registers handlers exactly
the way that breaks.

## Reproduce

All three run one `Session.eval` per numbered block, on a non-`:ui` lane.

**A. Captures a global — works.**

```scheme
;; eval 1
(begin (buffer-create "zz-a") (switch-to-buffer! "zz-a") (define *hits* 0))
;; eval 2
(begin
  (on-change! "zz-a" (lambda (p i d s) (set! *hits* (+ *hits* 1))))
  (buffer-insert! "zz-a" 0 "x")
  (list (wait-until (lambda () (> *hits* 0)) 2000 20) *hits*))
```

→ `(#t 1)`. The handler fires inside the same eval.

**B. Captures an eval-local — never fires.**

```scheme
;; eval 1
(begin (buffer-create "zz-c") (switch-to-buffer! "zz-c") (define *hits* 0))
;; eval 2 — the ONLY difference is the (let ((tag ...)))
(let ((tag "local"))
  (on-change! "zz-c" (lambda (p i d s) (set! *hits* (+ *hits* (string-length tag)))))
  (buffer-insert! "zz-c" 0 "x")
  (list (wait-until (lambda () (> *hits* 0)) 1500 20) *hits*))
```

→ `(#f 0)`, and `*hits*` is still `0` after the eval exits. The event is
gone; the handler never ran and never will for that change.

**C. The real case — `writing.scm`.**

```scheme
(begin (buffer-create "zz-x.md") (delete-other-windows!) (switch-to-buffer! "zz-x.md")
  (run-command "write")                       ;; registers the word-count hook
  (buffer-insert! "zz-x.md" 0 "hello brave new world")
  (buffer-local "zz-x.md" 'modeline-info))
```

→ `"0 words"`, and still `"0 words"` after the eval exits. Split `write`
into its own eval and the same insert gives `"4 words · 1 min"`.

## Root cause

`apps/aimax_scheme/lib/aimax/scheme/env.ex` is a two-tier store, and says
so in its own moduledoc: new frames live in a process-local map during an
eval and are bulk-flushed to the shared ETS table **when the eval exits**.
That is deliberate — frame churn is the interpreter's hot path and an ETS
write copies the term.

The consequence is documented there too: a closure that escapes mid-eval
points at a frame no other process can resolve, and resolving it raises
`"stale environment frame"` (`env.ex:427`). The doc says "the ref heals at
flush", which is true — but by then the event is gone.

The path:

1. `on-change!` (`apps/aimax_core/lib/aimax/core/session.ex:1800`) registers
   the Scheme closure with `Reactor.on_change`, `debounce: 30`.
2. The change fires the rule; `Reactor.handle_info({:fire, id}, …)`
   (`apps/aimax_core/lib/aimax/core/reactor.ex:97`) clears `pending` and runs
   the handler in `Task.Supervisor.start_child(…)`.
3. The handler resolves the closure's frame from another process. The frame
   is still in the registering eval's `local` map, so `env.ex` raises. The
   task crashes. `pending` was already cleared, so the change is lost.

Case A works because the lambda's free variable `*hits*` is a global that
was already flushed by an earlier eval — nothing needs the unflushed frame.

## Why it matters beyond tests

This is the shape every package uses. `writing.scm:167`:

```scheme
(define (writing--ensure-hook! buf)
  (on-change! buf (lambda (p i d s) (writing--update-count! buf))))
```

The lambda captures `buf`, the function's own argument — an eval-local. It
survives in normal use only because `M-x write` and the user's later
typing are different evals. It breaks whenever registration and the event
share one eval:

- a mode setup that edits the buffer it just hooked
- a restore path that installs handlers and then rebuilds state
- an agent tool call that does both in one `eval-scheme`

and it breaks **silently** — no message, no echo, nothing in `*messages*`.
A crash report may reach the logger from the supervised task; nothing
reaches the person.

## Proposed fix

**Flush a closure's frame chain when it ESCAPES, not at eval exit.** The
escape points are few and rare — `on-change!`, `define-command`, a closure
stored in a buffer-local or a handler table — so this does not touch the
hot path the two-tier store exists to protect. The moduledoc already says
the ref heals at flush; this heals it at the moment it can first be
observed.

Alternatives, both weaker:

- **Retry on a stale frame**, the way `Session.apply_reply_callback`
  already does (`session.ex`, 10 × 20ms). It reorders events, guesses a
  timeout, and still drops anything past the window.
- **Document it.** Then every handler must be written to capture only
  globals, which is not how any current package is written.

Either way: **log the dropped callback.** The silence is why this took
four wrong explanations to find. A handler that raises `"stale environment
frame"` should say so.

## Test for it

A Scheme test in `priv/tests/` cannot cover this today — `run-test` is one
eval per test, which is the broken case. Put it in ExUnit beside the other
bridge tests: register a capturing handler and fire it in a single
`Session.eval`, and assert the handler ran. It fails now.

Once fixed, `writing_test.exs` can go to zero: its last remaining test
exists only because of this bug. The Scheme half already covers the
counter (`priv/tests/writing-test.scm`).

## Not verified

- Whether the crashed task's report reaches the logger in dev, and at what
  level. I found no `rescue` around the handler call; the only `rescue` in
  `reactor.ex` is in `group_of/1` and unrelated.
- Whether `define-command` and buffer-local closures fail the same way. The
  mechanism says they should, and `env.ex`'s moduledoc names
  `define-command` explicitly, but I only reproduced `on-change!`.
- Whether anything in the product hits this today. I found the shape
  everywhere and a live failure in none.
