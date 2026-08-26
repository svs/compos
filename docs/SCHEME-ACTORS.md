# Scheme actors

Scheme has three execution tools. Ordinary editor Scheme remains compatible
with the lane scheduler. Set `AIMAX_SCHEME_EXECUTION=single_actor` to route all
ordinary evaluation through one serial worker. Shared-world tasks provide
cheap parallel work; isolated actors provide private state and mailboxes. Both
are optional in either scheduler mode.

The lane scheduler remains the default during migration. In single-worker
mode, synchronous Scheme such as `wait-until` blocks delivery of callbacks that
also target the main worker. Move that interaction to explicit actors or make
it asynchronous before enabling the mode for the whole editor.

An actor is a supervised BEAM process with a private Scheme environment and a
FIFO mailbox. Its behavior is a Scheme closure:

```scheme
(define counter
  (actor-spawn
    (lambda (state message)
      (if (equal? message 'increment)
          (list (+ state 1) #t)
          (list state state)))
    0))

(actor-send! counter 'increment)
(actor-call counter 'get) ; => 1
(actor-stop! counter)
```

## Shared-world tasks

Use tasks for the agent workflow: concurrent discovery and source reads. A
task is one supervised BEAM process with
its own evaluator stack and local frames, but it points at the already-booted
shared Scheme environment. Spawning it does not copy the Scheme world.

```scheme
(chat-parallel-map
  (lambda (query) (apropos query))
  '("buffer read" "code read" "replace code" "tests"))
```

`chat-parallel-map` is Scheme policy: it starts at most four tasks at once,
waits for that batch, and preserves input order. Lower-level code can use
`task-spawn`, `task-await`, `task-alive?`, `task-ref?`, and `task-cancel!`.
`task-run!` is the non-blocking seam for chat policy: it returns immediately
and later calls its callback with `(OK? VALUE-OR-ERROR)` on the originating
Scheme queue.

The normal LLM tool loop also uses this path without requiring Scheme authors
to call `task-spawn`. When one provider round contains two or more tools and
every tool's primary declared effect is `pure` or `read`, it evaluates up to
four together and preserves result order. A mixed or consequential round is an
ordering barrier and stays on the serial dispatcher. `read-file`,
`describe-function`, `code-outline`, and `code-read` are focused read tools so
agents do not need to hide safe reads inside the conservative `eval-scheme`
tool. A global limit, bounded between four and sixteen by default, applies
across all agents.

Buffers are still the write authorities. Each buffer is a GenServer, so a task
writing buffer A and a task writing buffer B can proceed independently; two
tasks writing buffer A are serialized by A. A buffer process is a lightweight
BEAM process, not a dedicated operating-system thread.

Serialization makes each buffer primitive atomic, not an entire
read/decide/write workflow. Until the Loro-backed provenance layer supplies
versioned operations and conflict semantics, concurrent agents should prefer
exact-match replacements and treat a rejected/stale edit as a reason to read
again. Structural and exact-match replacement helpers submit one
`buffer-replace-range!` message, so readers see the state before or after the
replacement, never its deleted midpoint. The task layer deliberately does not
add a competing transaction model.

`apropos` is safe to run in parallel. Its Scheme rows support literal matching.
OpenAI vectors add semantic recall when an OpenAI key exists. Catalog vectors
persist by content hash under the ai-max home. The cache stores no keys or raw
catalog text. Searches fall back to lexical matching when embeddings fail.
Run `M-x apropos-rebuild-embeddings` to clear and refill the complete cache.

Lane telemetry reports execution duration, queue time, and backlog at
`[:aimax, :lane, :job]`. Shared task telemetry reports duration and status at
`[:aimax, :scheme, :task]`.

Run `M-x telemetry` to open the Scheme-owned event list. `RET` opens every
field for one event; use `g` to refresh, `/` to filter, and `c` to clear the
bounded collector. The collector keeps the newest 1,000 events;
`telemetry-event-limit` controls how many rows the list shows.

The behavior receives `(STATE MESSAGE)` and must return
`(NEW-STATE REPLY)`. `actor-send!` discards the reply; `actor-call` returns it.
Only data crosses a mailbox. Closures cannot be sent, used as initial state, or
returned as replies. Actor references are data, so actors may spawn and return
children.

## Primitive surface

- `(actor-spawn BEHAVIOR STATE)` starts an isolated actor from a snapshot of
  the caller's Scheme environment.
- `(actor-self)` returns the current actor reference, or `#f` outside an actor.
- `(actor-ref? VALUE)` and `(actor-alive? ACTOR)` inspect references.
- `(actor-send! ACTOR MESSAGE)` sends without waiting.
- `(actor-call ACTOR MESSAGE [MS])` sends and waits for a reply.
- `(actor-after! MS ACTOR MESSAGE)` schedules a normal mailbox delivery.
- `(actor-monitor! OBSERVER TARGET TAG)` sends `(down TAG REASON)` to the
  observer if the target stops.
- `(actor-stop! ACTOR)` stops the actor. Actors are temporary supervised
  children; restart policy belongs in Scheme supervisors built from monitors.

## Sharing and isolation

An actor gets a private copy of Scheme bindings at spawn time. Its `set!` and
`define` do not mutate the spawning session. Buffers, processes, LSP clients,
and other editor mechanisms remain shared BEAM services. An actor reads another
actor's information by sending it a message; it reads a buffer by calling the
normal buffer primitives.

In compatibility-lane mode, other lanes may write globals while a snapshot is
being copied, so the initial environment is weakly consistent. Single-worker
mode provides a serialized snapshot. A future immutable base/COW store should
make cheap, point-in-time snapshots available in both modes.

An isolated actor cannot register one of its private closures directly in a
host callback registry. Wrap that interaction in messages to a main-session
handler instead. This makes the ownership boundary visible and prevents a
callback from silently re-entering a private interpreter on an unrelated
worker.

Snapshots currently copy the shared Scheme environment at every spawn. That is
a simple ownership boundary; a future actor pool can amortize it for workloads
such as parallel Scheme tests.

Private actor stores check growth every 100 messages and run reachability GC
when more than 1,000 frames have accumulated beyond the last baseline.

## Throughput and tests

Ordinary single-actor mode is appropriate for hundreds of top-level events per
second when handlers are short. Event bursts are coalesced by Reactor, and each
rule has at most one handler in flight. CPU-heavy or blocking work should be an
explicit actor or an existing asynchronous service.

Actor policy is tested in `priv/tests/actor-test.scm`. The Elixir tests cover
only runtime boundaries. A cold `mix test` mostly pays compilation and
application boot; `M-x run-scheme-tests` uses the already-running editor and
avoids that cost. Concurrent test evaluation requires per-test actor snapshots
and must remain opt-in because existing tests share live editor services.
