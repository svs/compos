# Scheme threading

compos evaluates Scheme in BEAM processes. The processes share one live Scheme
world unless code starts an isolated actor. Buffers remain independent state
owners.

This document separates the current runtime from the intended incremental
library model.

## Runtime model

The runtime has these execution paths:

| Path | State | Ordering | Use |
| --- | --- | --- | --- |
| Ordinary evaluation | Shared Scheme world | Serial for one lane or worker | Keys, commands, callbacks, and writes |
| `SchemeTask` | Shared Scheme world | Independent one-shot process | Concurrent reads and explicit parallel work |
| `SchemeActor` | Private Scheme environment | Serial mailbox | Isolated long-lived state and supervision |
| Buffer process | One buffer | Serial mailbox | Text, point, locals, provenance, and edits |

`COMPOS_SCHEME_EXECUTION=single_actor` routes ordinary Scheme evaluation through
one serial worker. Compatibility mode routes ordinary evaluation through serial
lanes. Shared-world tasks and isolated actors remain available in both modes.

A lane is an ordering queue. A lane is not a transaction, an ownership
boundary, or a separate Scheme world.

## Ordinary user actions

Keys and normal commands execute in order on the UI path. This keeps editing
deterministic. Agent read tasks use separate Scheme processes, so they do not
need the UI evaluator.

A slow command still blocks its own ordinary execution worker. The command can
use `task-run!`, `task-spawn`, or an asynchronous service when it must return
control before the work finishes.

Synchronous waits require care in single-worker mode. A wait cannot hold the
worker that must deliver its callback.

## Concurrent agent reads

One LLM response can request several tools. This response and its tool calls
form one tool round.

The tool dispatcher runs a round concurrently when all calls declare `pure` or
`read` as their primary effect. It runs at most four calls from that round at
once. It preserves the provider's result order.

A mixed, unknown, or consequential round stays serial. This rule creates an
ordering barrier around writes.

MCP tools use the standard `annotations.readOnlyHint` value. A true hint maps
to `(read external)`. A missing or false hint stays `(unknown external)`.
Trusted config can add `'read-only #t` to one MCP server spec. The setting
marks every tool as read-only. A `'tool-effects` plist can declare exceptions.

The compos MCP proxy emits `readOnlyHint` from each Scheme tool's effects.
External agents such as Codex can therefore read the same declaration.
The proxy starts consecutive read-only calls together. An unknown or write
call waits for earlier reads and blocks later reads until it finishes.
Read-only handlers use shared-world `SchemeTask` processes inside the daemon.

The runtime also applies one global admission limit across agents. The default
is at least four and at most sixteen active Scheme reads. Extra work waits in a
queue. Four agents therefore cannot create an unbounded number of evaluators.

`chat-parallel-map` supplies the same four-way policy to Scheme code. Lower
level code can use these functions:

- `task-spawn`
- `task-run!`
- `task-await`
- `task-alive?`
- `task-cancel!`

A task has its own evaluator stack and local frames. It points at the booted
shared environment. It does not copy that environment.

## Scheme processes

At idle, the intended shared-world configuration has one long-lived ordinary
mutation worker and no permanent read pool. A read call starts a temporary
supervised `SchemeTask`.

The normal process count is:

- One long-lived ordinary Scheme worker.
- Zero permanent shared-world read workers.
- Up to four temporary reads for one agent tool round.
- Up to the global configured limit across all agents.
- One short-lived apropos warm-up task in the current transitional design.

Each buffer also has a BEAM process. A buffer process is not a Scheme evaluator
and is not an operating-system thread.

## Shared environment

The interpreter stores the global frame and published closure frames in ETS.
Each binding has its own ETS row. Every shared-world evaluator uses the same
table.

New call frames and `let` frames stay in a process-local map during an
evaluation. The evaluator publishes reachable frames before it exposes a
closure to another process. Closures capture frame references, not copies.

Shared reads use a per-evaluation cache. Another process can publish a new
value while an evaluation still holds the previous value. The next
`Scheme.exec` boundary clears that cache. `with-scheme-lock` also clears cached
reads after it acquires the lock.

## State safety

Each buffer serializes its own operations. Two writes to one buffer cannot run
at the same time. Writes to different buffers can proceed independently.

One buffer primitive is atomic. A longer read, decide, and write sequence is
not atomic. Exact and structural replacements use one
`buffer-replace-range!` message. Readers see the text before or after the
replacement, not a deleted midpoint.

Shared Scheme globals do not receive automatic transaction semantics. Two
processes can lose a read-modify-write update:

```scheme
(define counter 0)
(set! counter (+ counter 1))
```

Two evaluators can both read `0` and both write `1`. Keep mutable global state
small. Put editor state in buffers or explicit actors. Use a narrow serialized
writer when a global invariant spans several operations.

The editable race diagram is in
[`boards/scheme-threading-lost-update.tldr`](../boards/scheme-threading-lost-update.tldr).

The planned Loro provenance layer will add versioned buffer operations,
anchors, authorship, and conflict handling. The task layer does not invent a
second buffer transaction model before that layer lands.

## Isolated actors

An actor owns a private Scheme environment and a FIFO mailbox. Only data crosses
the mailbox. Actor `set!` and `define` calls do not change the shared Scheme
world.

Use actors for private long-lived state, supervision, timers, and message
protocols. Do not create one actor per buffer. Buffers already own their state.

Actor spawn currently copies the shared Scheme environment. This makes actors
more expensive than shared-world tasks. See [SCHEME-ACTORS.md](SCHEME-ACTORS.md)
for the complete actor API and its current limits.

## Definitions and discovery

The interpreter already supports direct definition lookup:

- `global-names` returns every global binding.
- `boundp` tests an exact global name.
- `symbol-value` reads an exact global value.
- `public-api` returns documented supported functions.
- `public-entry` reads one documented function.

Apropos adds semantic discovery. It searches function documentation,
signatures, commands, keys, settings, components, recipes, package metadata,
domains, and effects.

Literal search stays in Scheme. OpenAI embeddings add semantic results when a
key exists. Catalog vectors persist by content hash in the compos home. API or
cache failures leave the literal result path unchanged.

The current implementation derives normalized apropos rows from several
registries. It caches the rows by catalog generation. The first caller after a
catalog change builds them under one Scheme lock. Concurrent callers reuse the
published result. A short boot task warms this cache.

This rebuild and warm-up are transitional. They do not match the intended
incremental library model.

## Incremental library loading

The target boot loads only the interpreter kernel, package loader, editor core,
and discovery registry. `init.scm` selects the other libraries.

Each library load must perform one package transaction:

1. The loader establishes the package, namespace, origin, domain, and effects.
2. `define` publishes callable bindings to the interpreter.
3. `public!`, `define-command`, and related forms publish normalized discovery
   records.
4. The loader records every owned binding and discovery record in a package
   manifest.
5. A successful load atomically publishes the completed manifest.
6. Reload replaces the old manifest with the new manifest.
7. Unload removes only records and bindings owned by that manifest.

Apropos then queries the records for loaded libraries directly. Library loading
updates discovery data. A later search does not rebuild the Scheme world or a
global search index.

The full registry scan remains useful for validation and recovery. It must not
be the normal load or search path.

This model gives these properties:

- Boot cost follows the selected core.
- Library load cost follows that library.
- New definitions appear in apropos when the load commits.
- Reload does not leave duplicate records.
- Unload removes the library cleanly.
- Agents discover only the currently loaded environment.

## Telemetry

Lane events record duration, queue time, backlog, owner, and status. Scheme task
events record duration, status, and the logical job label.

Run `M-x telemetry` to open the Scheme telemetry buffer. Use these keys:

- `RET` opens the full event details.
- `g` refreshes the list.
- `/` filters the list.
- `c` clears collected events.
- `q` closes the telemetry buffer.

The collector keeps the newest 1,000 events. `telemetry-event-limit` controls
the displayed row count.

## Source map

| File | Responsibility |
| --- | --- |
| `apps/compos_core/lib/compos/core/lane.ex` | Ordinary queues, routing, timeouts, and lane telemetry |
| `apps/compos_core/lib/compos/core/session.ex` | Scheme entry points, primitives, roots, and GC timer |
| `apps/compos_core/lib/compos/core/scheme_task.ex` | Shared-world one-shot processes |
| `apps/compos_core/lib/compos/core/scheme_read_limiter.ex` | Global read admission limit |
| `apps/compos_core/lib/compos/core/scheme_actor.ex` | Private Scheme actors and mailboxes |
| `apps/compos_core/lib/compos/core/llm.ex` | Effect-aware tool-round dispatch |
| `apps/compos_scheme/lib/compos/scheme.ex` | The `Scheme.exec` boundary |
| `apps/compos_scheme/lib/compos/scheme/env.ex` | Local frames, shared ETS rows, caches, publication, and GC coordination |
| `apps/compos_core/priv/packages/tools.scm` | Tool effects and apropos policy |
| `apps/compos_core/priv/packages/telemetry.scm` | Telemetry user interface |
