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

## Text scale

1. The buffer's text scale is the `text-scale` buffer-local: a step on the 1.2 ladder (Emacs `text-scale-mode-step`), 0 for normal. It rides the checkpoint, so it survives a restart and a wake.
2. The remap and the window style derive from it. `text-scale-sync!` writes them again from the local; a mode that restores a remap it saved before the scale was set (writing-mode, the preview rows) calls it after the restore.
3. Text and rich-chat windows multiply their text sizes by the factor; a rendered page (an iframe) zooms by it.
4. The application scale is separate: the `ui` face's zoom, a saved setting (`ui-scale`).
5. The chords: Cmd-= / Cmd-- / Cmd-0 scale the application; Cmd-Shift-= / Cmd-Shift-- / Cmd-Shift-0 scale one buffer. macOS reports a Cmd chord with the unshifted character, so the client reads a shifted Cmd chord from the physical key (`e.code`). Tests name the commands, never the chords.

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

### Following the file

A buffer follows its file when something outside the editor writes it: git, another session, a formatter. `autorevert.scm` implements it, frame-local and on by default.

**The buffer is the text.** A file that moved is not an authority that overwrites the buffer, it is one more writer whose change has to land beside the buffer's own work. Every mechanism here follows from that.

**The mark, never the modified flag.** A buffer records the text it last agreed with its file on. Inside compos a buffer is where code is written and saving is a separate decision, so buffers carry live unsaved work for hours; and the flag is the very thing that is wrong in this case, because a write behind the editor's back leaves a buffer reading unmodified while its text differs. The mark is taken when the buffer is created, which is `*buffer-created-hooks*` and not `find-file-hook`, because the visit hooks are run by the commands and not by `find-file` or `buffer-save!`, so an agent or a script never reaches them. It moves forward on any file event that finds buffer and file equal, which is also how a save is noticed. A buffer with no mark is left alone: there is no common text to describe either side's change against.

**A file that moved is merged, not applied.** Three texts: the mark, the buffer now, and the file now. Both sides are diffed against the mark, so both changes are described in the same line coordinates. The file's hunks that fall on lines the buffer left alone are applied, translated by how far the buffer's own hunks have moved those lines. A hunk that falls where the buffer also changed is left, and the buffer keeps its version, because the buffer is the one being worked in. After a merge the mark becomes the file's text, which is what the next merge measures against. Only a buffer that still holds its mark exactly takes the file wholesale, and only then is it marked saved.

**A revert writes only the lines that changed.** Replacing the whole text makes one delete and one insert, so the weave credits every byte of the file to whoever reverted: measured on a five line file, attribution went from the 23 bytes actually typed to all 40, including the line git wrote and three lines nobody in the editor had touched. The revert is a line diff applied as one `buffer-replace-range!` per hunk, authored `disk`, so an untouched line is not written and keeps its author. Spans are lines and `line-start-position` converts them to byte offsets, so no byte arithmetic on strings is done. If the hunks ever fail to reproduce the file, the whole text goes in as a fallback, which costs only the attribution.

Every revert is logged, naming the file and how many changes it took.

**A save merges first.** Following a file can always be too late: a buffer can sleep through the change, its directory can go unwatched, an event can be missed. The save is where being wrong costs something, and it is one comparison rather than a subscription. `before-save-hook` compares the file to the mark, merges whatever the file did since this buffer read it, and lets the save proceed. Only a line both sides changed stops the save, because only there does the editor have no answer; `save-buffer-anyway` writes over the file. This is the case where a buffer woke holding text older than the file and a save from it silently put the old text back.

**Watching.** Every open file buffer is watched. A repository is watched deep, and one watch covers every file in it. A file outside a repository is watched through its own directory, and shallow, because a deep watch on a home directory is a recursive fsevents loop. A buffer remembers the root it was watched under, since the watcher can answer with a different name than the one asked for, and that is the name a file event arrives under.

### Rename and path changes

Renaming a buffer, changing its path, or saving it under a new path updates materialization metadata. Immutable buffer and cell IDs remain unchanged.

### Mode changes

A mode change applies automatic policy after the mode is known and before mode-generated content changes. Stopping retains the accepted head. Resuming after unrecorded edits creates the gap revision specified in PROVENANCE.md.

### Kill, eviction, and discard

Before a durable buffer is killed or evicted, pending Provenance operations and the buffer checkpoint are flushed. Restoration recovers both to a mutually consistent accepted revision.

A normal kill does not delete history. Explicit discard may remove session-only history. Deleting durable history is a separate, confirmable operation.
## Buffer-facing API

The buffer layer exposes these conceptual operations:

- `line-at-point`: atomically read the 1-based line number and text at point
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
