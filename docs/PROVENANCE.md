# Provenance

Provenance is the default revision and attribution system for ai-max buffers. It records how accepted content came to exist while allowing humans, agents, modes, and processes to work concurrently.

It is not tied to Git, files, celld, or a particular storage engine.

## Goals

Provenance MUST:

- preserve every accepted content state as an addressable revision
- attribute mutations to structured actors
- support optimistic concurrent work without silent overwrite
- preserve stale work as proposals
- work for file and non-file buffers
- survive buffer eviction and daemon restart for durable buffers
- allow deliberate recording opt-out without erasing earlier history
- materialize the latest accepted state into ordinary buffers and files

Provenance does not attempt to infer semantic merge correctness, replace a mode's authoritative external database, or treat operational recovery snapshots as revision history.

## Concepts

### Cell

A cell is the stable unit of acceptance. Initially a buffer MAY map to one cell. Later, syntax-aware modes may split a buffer into stable semantic cells or hunks.

Cell identity survives movement within a file, buffer rename, and path changes. Splitting or joining cells is itself recorded metadata.

### Revision

A revision is immutable and contains:

- revision ID and cell ID
- parent revision ID or IDs
- changeset ID
- resulting content hash
- operations or snapshot reference
- actor context
- intent and optional message
- logical and wall-clock timestamps
- origin and tool metadata
- schema version

The content hash addresses the result; the revision ID addresses the event and its metadata. Equal content produced by different histories may have different revision IDs.

### Ref

A ref is the mutable pointer to a cell's accepted revision. Conditional acceptance updates it only if its current value equals the proposal's expected parent.

### Operation

An operation records an insertion, deletion, replacement, or declared semantic transformation against an exact prior state. Text operations use byte ranges and retain inserted and deleted content or content-addressed references sufficient for inversion and audit.

### Proposal

A proposal is a candidate revision with an expected parent. Failure to accept it does not erase it. A proposal may be rebased, combined, superseded, accepted as a fork, or explicitly discarded.

### Changeset

A changeset groups revisions produced by one intent. It provides atomic acceptance when an edit spans several cells. A changeset carries the initiating actor, intent, and causal links shared by its revisions.

### Materialization

A buffer or file is a projection of accepted refs. Operational snapshots accelerate restoration but are not revisions and cannot replace parentage, attribution, or proposals.
## Actors

### Actor identity

An actor is a structured principal, not a free-form author string. It contains:

- a stable actor ID
- kind: user, agent, mode, process, service, or system
- display name
- identity authority and assurance level
- session ID
- optional agent run, thread, or process instance ID
- optional `on_behalf_of` actor ID
- optional parent actor or causal chain
- tool, command, and source metadata

Stable identity and execution identity are distinct. For example, `agent:codex` identifies the agent principal while a run ID identifies one execution. OS process IDs, buffer names, and display labels are never stable principal IDs.

### Recognition order

Every mutation resolves its actor in this order:

1. an explicit actor attached to the edit transaction
2. the authenticated editor or API session principal
3. the dynamically scoped agent-run actor
4. a registered mode, service, or process principal
5. a structured unknown actor containing the mechanical source

The current process-scoped edit-author mechanism is the seed of this design, but it must carry an actor context rather than only a string.

Manual keyboard input uses the signed-in or locally configured user identity. An agent edit uses the agent run that invoked the editing tool, even though the buffer process mechanically performs the mutation. A formatter or mode-generated edit names that component as actor and may name the initiating user or agent in `on_behalf_of`.

Actor, source, and intent are separate:

- **actor** answers who caused or authored the content change
- **source** answers which path performed it, such as keyboard, command, Scheme API, agent tool, formatter, restore, or external import
- **intent** answers why related changes belong together

### Unknown and unauthenticated actors

Local edits are not rejected merely because identity is unavailable. They receive an explicit unknown, unverified actor with source and session evidence. Remote acceptance SHOULD require an authenticated actor; policy may reject unknown remote actors.

A normal edit MUST NOT use a no-actor sentinel. No-actor mutations are reserved for faithful restore or materialization where no semantic content change occurred.

### Causality

Delegation is preserved. A useful chain is `user -> chat session -> agent run -> editing tool`.

The revision's primary actor is the principal responsible for the proposed content, normally the agent run in this example. The initiating user and mechanical tool remain queryable without falsely attributing generated text directly to the human or to the buffer process.
## Recording lifecycle

A participating buffer is in one of two durable states:

- **recording**: content mutations create Provenance operations and revisions
- **stopped**: mutations may occur but their individual history is intentionally not recorded

Legacy buffers may briefly be uninitialized during migration. New buffers never begin in that state.

| Operation | Recording state | Stopped state |
|---|---|---|
| start | no-op except policy update | bridge any gap, then record |
| stop | flush and stop | no-op |
| checkpoint | close pending changeset | error unless explicitly importing |
| mutation | record and accept | mutate with an attribution gap |
| mode opt-out | flush, record lifecycle event, stop | remain stopped |
| mode opt-in | remain recording | start unless user override is off |

Lifecycle transitions are durable metadata events containing actor, reason, policy source, and timestamp.

### Start

Interactive start records an explicit user on override. Automatic mode or creator starts do not create a user override.

If current content matches the accepted head, recording resumes directly. If content changed while stopped, start first creates an opaque gap revision:

- parent: the last accepted head
- result: a snapshot of current content
- actor: the actor starting recording
- source: untracked-interval import
- metadata: stop event, start event, prior and current hashes
- attribution status: incomplete

The gap preserves continuity without inventing authorship for unrecorded edits. Starting is idempotent. It never resets the base, discards operations, or deletes history.

### Stop

Stopping first commits or flushes every operation already observed while recording. It then records a lifecycle event and disables recording for subsequent mutations.

Stopping retains the accepted head, proposals, actors, and all history. It is idempotent and is not a deletion or privacy-erasure operation.

### Checkpoint

Checkpoint closes the current open changeset and advances its revision boundary. With no pending operations it is a no-op.

Checkpoint may be explicit and SHOULD also occur at transaction boundaries, actor changes, saves, mode changes, stop, eviction, and daemon shutdown. Typing may be coalesced within a short command or undo group, but the durable operation journal must permit crash recovery.

Checkpoint never clears immutable history. Compaction may replace old operation payloads with verified snapshots only when revision identity, hashes, attribution, and parentage remain intact.

### Delete and forget

History deletion is separate from stop and requires an explicit target and policy decision. Durable deletion SHOULD leave a tombstone when synchronization or references make silent disappearance unsafe.

Session-retained Provenance may be discarded with its buffer session. Durable history survives ordinary kill, close, eviction, and restart.
## Mutation transactions

Every semantic edit runs in a mutation transaction containing:

- actor context
- intent or command identity
- expected buffer version and cell head
- one or more operations
- optional multi-cell changeset ID
- recording decision captured at transaction start

The recording decision cannot change halfway through a transaction. Mode hooks triggered by an edit inherit its causal context unless they open a separately identified transformation.

The buffer validates geometry and current state. The Provenance store atomically records operations and advances refs before the new accepted state is externally acknowledged. Buffer text, accepted head, and durable journal must not report contradictory success.

## Conditional acceptance and conflicts

Acceptance is compare-and-swap against the proposal's expected revision.

On success:

1. validate the proposal and actor policy
2. write immutable revision and operation records
3. atomically advance all affected refs
4. update buffer materializations
5. notify subscribers

On a stale expected revision, return a structured conflict containing the expected head, actual head, and preserved proposal ID. Do not silently rebase or overwrite.

Rebase creates a new proposal with causal links to the original. Combining proposals creates a changeset that cites every input. Rejection and discard are explicit events.

Local interactive edits may read and accept within the buffer's serialized call. Agents and external clients must use the snapshot revision they were given.
## Non-file buffers

Provenance attaches to buffer identity, not filesystem presence.

- scratch and note buffers receive normal durable history when the buffer is durable
- REPL and process buffers default to session retention; their modes may opt out of noisy output while retaining user-authored input elsewhere
- generated lists and dashboards may opt out because their source data is authoritative
- chat-mode may opt out because the transcript store already owns history
- remote resource buffers use their origin URI as metadata, not as identity
- read-only buffers may still have a root revision and imported external revisions

A mode opt-out is a deliberate product decision, not an inference from "non-file."
## Persistence model

The first backend is a supervised local SQLite store. Celld is deferred.

Phase 1 persists:

- one cell row per stable buffer ID
- the accepted revision ID and content hash
- recording state, policy source, retention, and gap state
- immutable root, edit, and attribution-gap revisions
- structured actors and exact edit operations
- lifecycle events
- stale proposals created by failed expected-head acceptance

The store uses WAL mode and serializes mutations through one GenServer. Each accepted edit updates the immutable revision history and mutable accepted head in one SQLite transaction.

Buffer checkpoints contain a copy of the accepted head and content hash. On activation, the buffer reads the authoritative cell from SQLite and compares its hash with restored text. A mismatch while recording creates an explicit recovery snapshot. A mismatch while stopped remains an attribution gap until recording resumes.

Large content objects, replay beyond the stored snapshots and operations, multi-cell transactions, and content-addressed external storage are later phases.
## Backend contract

A backend provides, at minimum:

- read a cell and accepted head
- read revision content and metadata
- begin and commit a mutation transaction
- conditionally accept one or more proposals against expected refs
- append and close changesets
- list history, actors, proposals, and lifecycle events
- rebase, combine, reject, or discard a proposal
- subscribe to accepted ref updates
- create and verify snapshots
- apply retention and deletion policy

Backend errors distinguish stale revision, invalid operation, actor-policy rejection, storage failure, corruption, and unavailable content.
## Mode and API contract

Modes declare a recording policy and retention preference; they do not directly delete history. Policy installation must happen before initial generated mutations.

Public commands provide status, start, stop, checkpoint, clear override, history, and proposal resolution. `M-x buffer-log` (`C-x v l`) shows the accepted revisions of the current buffer, oldest first, with the recording state and the policy that set it in the header. `RET` describes one revision: its actor, source, operation, and hash. The Scheme history primitive omits the snapshot payload and reports its size, so a large file does not cross into Scheme on every redraw. Programmatic mutation APIs accept actor context, expected revision, intent, and changeset.

Compatibility callers that supply only an author string are wrapped as unverified legacy actors until migrated.

## Security and privacy

Provenance may retain deleted text, prompts, generated output, and secrets. User-visible status must make recording and retention clear.

Stopping prevents future mutation history but does not erase previous revisions, current buffer checkpoints, external transcript stores, backups, or synchronized replicas. A separate forget workflow must enumerate what will be removed.

Actor metadata stores stable internal IDs and minimal display information. Authentication tokens and secret credentials must never enter revision metadata.

## Invariants

- Revisions and actor records are immutable.
- Accepted refs advance atomically from an expected parent.
- Stale work remains addressable until policy removes it.
- Every accepted content hash is reproducible from a verified snapshot and subsequent operations.
- Recording gaps are visible and never receive fabricated fine-grained attribution.
- Actor, source, intent, and on-behalf-of identity remain distinct.
- A mode can opt out; a filename convention cannot.
- Start, stop, checkpoint, save, restore, and kill have non-destructive, idempotent semantics where specified.
- Operational snapshots do not define VCS history.
- The storage backend does not define revision meaning.

## Phase 1 implementation status

The live implementation now provides:

1. structured actor contexts with derived author strings for compatibility
2. a stable cell and root revision for every buffer
3. default-on recording with explicit mode policy
4. accepted head and hash linkage in buffer checkpoints
5. immutable revisions, lifecycle events, and stale proposals in SQLite
6. idempotent, non-destructive start and stop operations
7. explicit gap snapshots for stopped intervals
8. Scheme status, history, start, stop, and checkpoint operations
9. `chat-mode` opt-out with explicit user-policy precedence
10. focused tests for roots, actors, gaps, mode policy, and eviction recovery
11. `M-x buffer-log` (`C-x v l`), the list of one buffer's accepted revisions

Compilation, the focused tests, and eviction recovery pass. Existing persisted
in-memory epochs are not imported.

Phase 1 is not complete. Three gaps remain:

- **Every keystroke writes to SQLite.** `log_provenance/5` flattens the whole
  buffer, hashes it with SHA-256, and calls one global GenServer that runs a
  `BEGIN IMMEDIATE` transaction. This happens inside the buffer's own call, so
  the cost lands on the typing path. The build plan names batching and
  transaction boundaries as the way to keep recording off that path. Neither
  exists yet, and no latency measurement gates the work. A measurement taken
  against an on-disk WAL database gives 0.35 ms for one keystroke in a 343 KB
  buffer, against 0.007 ms with recording stopped. That is 50 times the cost,
  and it grows with the size of the buffer, because each keystroke flattens
  and hashes the whole text. It is not yet perceptible. It becomes perceptible
  in a large buffer, and every buffer shares the one store process.
- **A stale head crashes the buffer.** `log_provenance/5` raises on
  `{:stale_revision, conflict}`. The specification asks for a structured
  conflict that preserves the proposal. A raise kills the buffer process and
  loses its state.
- **Checkpoint records an event, not a boundary.** The store writes a
  `checkpoint` lifecycle row. It does not close a changeset, because Phase 1
  has no changeset table. The name promises more than the operation does.
## Build plan

Provenance should be built, but the specification is a destination rather than one release.

### Phase 1: durable provenance kernel

Build structured actor context, one cell per buffer, default-on and mode opt-out policy, SQLite-backed revisions, checkpoint linkage, lifecycle events, non-destructive start and stop, attribution-gap recovery, and history/status inspection.

This phase proves the two uncertain assumptions: that actor context can propagate reliably through every mutation path, and that durable recording can stay off the interactive typing latency path through batching and transaction boundaries.

### Phase 2: concurrent proposals

Add expected-head acceptance for agent and external edits, durable stale proposals, conflict inspection, rebase, combination, and explicit rejection. Local keyboard editing continues through the serialized buffer path.

### Phase 3: semantic cells and changesets

Introduce stable hunk or syntax-node cells only after one-cell-per-buffer history is useful. Add atomic multi-cell changesets and materialization mapping as real workloads require them.

### Deferred

Remote replication, distributed ownership, celld, cross-repository exchange, garbage collection across replicas, and a Git replacement workflow are explicitly deferred.

### Evaluation gates

Continue beyond Phase 1 only if:

- actor identity is correct across user, agent, mode, and process edits
- restart and eviction recover a hash-consistent accepted head
- recording overhead does not make ordinary editing perceptibly worse
- mode opt-out prevents high-volume generated buffers from polluting history
- history answers useful questions that authorship spans and undo cannot answer

If these gates fail, keep structured attribution and lifecycle policy but do not expand into a new VCS.
