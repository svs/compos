# Buffer

This document specifies how an compos buffer participates in Provenance. The normative history model is defined in [PROVENANCE.md](PROVENANCE.md).

## Identity

Every buffer has an immutable buffer ID. Its name, path, mode, windows, and process lifetime may change without changing that identity.

A buffer may have a local file path, a remote or virtual origin URI, no external origin at all, durable or session-only persistence, and editable, generated, or read-only content.

A path is a materialization target, not the buffer's history identity. Renaming a buffer or writing it to another path does not fork its Provenance history.

## Default policy

Provenance is on by default for every new and restored buffer. File-backed and non-file buffers follow the same rule.

The default applies to scratch buffers, notes, remote resources, process buffers, generated views, and internal buffers. A mode or buffer creator may opt out when recording would duplicate an authoritative external log, retain sensitive material unnecessarily, or record meaningless generated churn.

Recording policy and retention are separate:

| Property | Values | Default |
|---|---|---|
| recording | on or off | on |
| retention | durable or session | follows buffer persistence |
| policy source | user, mode, creator, or global default | global default |

An ordinary non-file buffer is therefore provenanced and durable when the buffer itself is durable. An ephemeral internal buffer is provenanced in memory for its session unless its mode opts out.

A leading-space name or lack of a file path MUST NOT, by itself, disable Provenance. Buffer creation metadata and mode policy decide persistence and recording explicitly.

## Group

A buffer may stand in a group. Every changeset records the group the buffer
stood in at the time, read from the buffer-local that `groups.scm` sets.

The group is context, not identity. It does not change the buffer's cell, its
history, or its actor. A buffer that moves to another group keeps every
revision it already has, each still naming the group it was written in.

## Effective policy

The effective recording policy is resolved in this order:

1. an explicit user override on the buffer
2. the active mode's declared policy
3. a buffer-creator policy supplied at creation
4. the global default, which is on

A mode declares **inherit**, **on**, or **off**. Mode changes re-evaluate automatic policy. They do not erase history and do not override an explicit user choice.

Modes such as chat-mode SHOULD declare off when their buffer is a projection of an already durable transcript. The policy must be installed before the mode performs initial generated inserts. Provenance being off does not imply confidentiality: ordinary buffer checkpoints, remote services, or the mode's own store may still retain the current content.
## Lifecycle

### Creation

Buffer creation allocates the immutable buffer ID and a Provenance cell ID. Unless the effective policy is off, it creates a root revision containing the initial text.

The root records whether the content came from an empty buffer, a file or remote baseline, a restored checkpoint, generated initial content, or migration. Loading existing content establishes a baseline; it is not attributed as if a user typed the entire file.

### Restoration and activation

Restoring reconnects the buffer to its existing cell and accepted head. Restore operations use no edit actor and MUST NOT generate content revisions.

Before accepting edits, restoration verifies that materialized text matches the accepted head. A mismatch becomes an explicit import revision or an error; it is never silently accepted.

### Mutation

Every content mutation carries an actor context and a mechanical source. The buffer process serializes local mutations and publishes them against the revision the mutation observed.

Local interactive edits may obtain the expected revision inside the serialized call. Agents, background jobs, and remote clients MUST supply the expected revision they read. Stale publication returns a conflict and preserves the proposal.

Point motion, marks, overlays, folds, syntax state, and window state are not content revisions. Buffer-local metadata is recorded only when a schema explicitly declares it semantic.

### Save and materialization

Saving writes the latest accepted text to the materialization target. A save does not create a revision when content has not changed.

External file changes are imported as proposals based on the last materialized revision. They must not overwrite newer accepted state without an explicit conflict decision.

### Rename and path changes

Renaming a buffer, changing its path, or saving it under a new path updates materialization metadata. Immutable buffer and cell IDs remain unchanged.

### Mode changes

A mode change applies automatic policy after the mode is known and before mode-generated content changes. Stopping retains the accepted head. Resuming after unrecorded edits creates the gap revision specified in PROVENANCE.md.

### Kill, eviction, and discard

Before a durable buffer is killed or evicted, pending Provenance operations and the buffer checkpoint are flushed. Restoration recovers both to a mutually consistent accepted revision.

A normal kill does not delete history. Explicit discard may remove session-only history. Deleting durable history is a separate, confirmable operation.
## Buffer-facing API

The buffer layer exposes these conceptual operations:

- `provenance-status`: effective policy, state, retention, cell, accepted head, and pending changes
- `provenance-start`: set an explicit on override and start or resume recording
- `provenance-stop`: set an explicit off override and stop after flushing recorded work
- `provenance-clear-override`: return control to mode, creator, and global policy
- `provenance-checkpoint`: close the current changeset without deleting history
- `provenance-history`: read revisions and lifecycle events
- `provenance-proposals`: read proposals awaiting conflict resolution
- `provenance-apply`: conditionally accept a proposal against an expected head

Start and stop are idempotent. Starting MUST NOT replace the existing base or clear prior changes. Checkpointing MUST NOT delete revisions.

A scoped internal facility may suppress recording for restore or materialization. It must distinguish "do not create an edit" from "an unknown actor made an edit" and must not become an accidental default for ordinary mutations.
## State held by the buffer

The buffer keeps only the Provenance state needed for correct mutation:

- cell ID
- accepted head revision ID and content hash
- recording state and effective policy source
- retention class
- current changeset or transaction ID
- pending operation count
- actor context for the active mutation

Immutable revision history and proposals belong to the Provenance store. Buffer checkpoints persist this linkage, not a private replacement history.

## Invariants

- Every accepted content state has one addressable revision.
- Visible buffer text matches its accepted head after each completed mutation.
- File presence is not required for identity or history.
- Recording is on unless policy explicitly says otherwise.
- Turning recording off never deletes existing history.
- Restarting after unrecorded edits exposes the attribution gap.
- Restore and materialization do not masquerade as authored edits.
- Names, paths, modes, and process IDs are not stable actor or buffer identities.

## Phase 1 implementation state

The live Phase 1 change replaces the optional in-memory epoch with a default-on durable cell for each buffer. The buffer keeps authorship spans and the capped edit log as compatibility views.

A supervised SQLite store owns immutable root, edit, and attribution-gap revisions. The buffer checkpoint carries the accepted head, content hash, recording state, retention, and policy source. Restoration resolves the authoritative head from SQLite and verifies it against the restored text.

The implementation exposes status, history, start, stop, and checkpoint operations to Scheme. `chat-mode` requests mode-policy opt-out during setup. An explicit user policy takes precedence over that request.

The change is not complete until focused tests, restart recovery, and typing-latency checks pass.

## Initial implementation slice

Phase 1 includes:

1. structured actor context with the existing author string as a compatibility view
2. one default-on cell and accepted root revision for every buffer
3. durable status, policy source, retention, accepted head, and content hash
4. exact edit operations and immutable revisions in local SQLite
5. non-destructive start and stop operations
6. explicit attribution-gap snapshots after edits made while recording is off
7. `chat-mode` opt-out with user-policy precedence
8. Scheme status, history, lifecycle, and checkpoint operations
9. eviction and restart recovery checks
10. a sustained-edit latency check

This slice keeps one cell per buffer. It does not implement semantic hunks, multi-cell commits, proposal UI, remote synchronization, or celld.
