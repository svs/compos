# Provenance on a CRDT

This document plans the move of Provenance onto a CRDT. It modifies
`docs/PROVENANCE.md`, which stays the specification of what Provenance must record.
The two disagree in one place, named below: conditional acceptance.

## Context

Multiplayer is already here. A human types in a buffer while an agent edits the same
buffer through `insert_at` (`agent.ex:419`, `source: {:agent, slug}`). Two actors, one
buffer, concurrent. The network is not the multiplayer problem; it is a later, additive
one.

An agent needs no human affordances: no point, no highlight, no selection, no presence.
It needs two things a single-writer buffer cannot give it. Its edits must be attributed
as its own, and the byte range it computed from a read must survive a human typing above
it before the edit lands.

The current Provenance subsystem records history behind a compare-and-swap on an
expected head. A CRDT merges concurrent work instead of rejecting it, so that layer
does not survive. Rather than run a CRDT beside Provenance, one structure does both.

**What this changes in `docs/PROVENANCE.md`.** Phase 2, "concurrent proposals",
dissolves. Conditional acceptance, stale proposals, rebase, and structured conflicts
answer a question a CRDT does not ask. A proposal remains meaningful only as an agent
edit held for human review, which is policy above the store rather than storage.
Everything else in that document holds: actors, changesets, recording lifecycle, mode
opt-out, gaps, and the invariant that a mode can opt out but a filename convention
cannot.

Loro is the choice. Its `Change` struct is already the Provenance changeset:

```rust
pub struct Change<O = Op> {
    id: ID,                        // PeerID + Counter
    lamport: Lamport,
    deps: Frontiers,               // DAG parents
    timestamp: Timestamp,
    commit_msg: Option<Arc<str>>,  // intent
    ops: RleVec<[O; 1]>,
}
```

Scope is every durable and user buffer: code, writing, morg, chat, scratch, agent
threads.

## The bug this fixes

`state.history` holds up to 500 rope snapshots (`buffer.ex:1409`, `@undo_limit` at
`:56`), pushed by every edit regardless of actor. Undo pops one and swaps the rope
wholesale (`:927`). The stack is a single linear timeline across all actors.

So while an agent edits a buffer you are typing in, you cannot undo your own typing
without first undoing the agent's work. The more an agent writes, the less usable undo
becomes. This is not a future concern.

## Ownership rule

The rope stays as the working representation and the line index. Loro owns history,
undo, cursors, and the wire format.

- **Local edits: the rope leads, Loro follows.** `do_insert` (`buffer.ex:1326`) and
  `do_delete` (`:1379`) already know the exact `(pos, text)` and `(pos, len)`, so they
  apply the rope edit and then call `insert_utf8` / `delete_utf8`. No diff.
- **Remote or imported edits: Loro leads, the rope rebuilds.**
- **Invariant:** `Rope.to_binary(rope) == History.text(history)`, checked by hash
  at the checkpoint boundaries where the buffer already compares hashes.

Loro has no line index. It offers `insert_utf8`, `delete_utf8`, `len_utf8`, `splice`,
`char_at`, and nothing equivalent to `rope_byte_to_line`, `rope_line_to_byte`, or
`rope_line_count` (`rope_nif.ex:10-12`), which the point, the renderer, and every
motion call constantly. ropey answers those in O(log n), so `rope.ex` and
`apps/aimax_core/native/aimax_rope` stay untouched.

## Actors, undo, and cursors

**PeerID is the replica. Origin is the actor.** One `LoroDoc` per buffer, one PeerID.
The existing `source` becomes the Loro origin string: `user`, `agent:codex`, `editor`,
`process`. This is what makes per-actor undo work without a history per actor.

**One `UndoManager` per actor that can undo.** The API is built for this case:

- `add_exclude_origin_prefix(prefix)` keeps an origin out of a manager's stack. The
  human's manager excludes `agent:`, so agent edits never enter human undo. That is
  the fix for the bug above.
- **Every manager must also exclude the `undo` origin.** An undo is itself a change,
  and it carries the `undo` origin. Without the exclusion, one actor's undo lands on the
  other actor's stack, so the other actor's next undo reverses it and restores work that
  was just removed. Phase 0 reproduced this and confirmed the exclusion fixes it.
- **One commit is one undo step.** Phase 3 measured it: three commits give three steps,
  and eleven characters inside one commit give one. So the buffer keeps deciding where a
  step ends, exactly where it used to push a snapshot, and a run of typed characters
  stays one step because nothing commits until the run breaks. `group_start` and
  `group_end` are not needed for this and are not used.
- `set_merge_interval(0)` on every manager, so elapsed time never groups anything on top
  of the buffer's own boundaries.
- `set_max_undo_steps(500)` to match today's `@undo_limit`. The default is 100.
- `undo` is local-only by construction: it reverts the bound peer's operations and
  rebases them over concurrent work, rather than restoring a stale whole-text snapshot.

**A stack belongs to a scope, not to an actor id.** A command the user invoked edits as
`system:editor`, and Emacs undoes it as the user's own work. So the user's scope owns
every kind except the two that act on their own, `agent` and `process`. Agents share one
scope with each other; no caller needs them apart yet.

This retires `state.history`, `snapshot/1`, and the wholesale rope swap at `:927`.

**Stale offsets become Loro cursors.** `LoroText::get_cursor(pos, side)` returns a
position that survives concurrent edits, and `doc.get_cursor_pos(&cursor)` resolves it.
The doctest is exactly the needed semantic: a cursor at 5, insert 5 characters at 0,
the cursor reads 10.

Two uses, neither of them an agent affordance:

- The human's point and mark, which today are moved by hand in `adjust_point_insert`
  and `adjust_ranges` (`buffer.ex:1330-1359`). A cursor does this correctly for any
  number of concurrent actors, and `UndoItemMeta` carries cursors so undo restores the
  right position.
- **Agent edit anchors.** An agent reads a buffer, computes a byte range, and calls
  `insert_at` or `replace_range` some seconds later. If the human typed above that range
  in between, the offset is stale and the edit lands in the wrong place. A cursor pair
  taken at read time makes the range survive. This is the concrete win for agents, and
  it is invisible: no point, no highlight, nothing rendered.

  Phase 4 traced where this is reachable. The text-anchored tools, `buffer-replace!` and
  its family, are already safe: they locate their target by a unique string inside the
  same call, and refuse when it is missing or ambiguous. The hole is `code-outline` to
  `code-replace!`, which addresses a definition by line number across turns, and which
  the system prompt teaches as the way to edit code. `eval-scheme` can reach the raw
  offset primitives directly, which no anchor can close.

## Design

### New crate `apps/aimax_core/native/aimax_loro`

```rust
struct WeaveState {
    doc: LoroDoc,
    text: LoroText,
    undo: HashMap<String, UndoManager>,   // undo scope -> manager
}
struct WeaveRes(Mutex<WeaveState>);
```

Mutable behind a `Mutex`, like `TsRes` in `aimax_ts/src/lib.rs:397`, not like
`RopeRes`, which has immutable-value semantics.

| NIF | Scheduler | Notes |
|---|---|---|
| `history_new(peer)` | DirtyCpu | a new history, for one replica |
| `history_insert(res, pos, bytes)` | normal | `insert_utf8` |
| `history_delete(res, pos, len)` | normal | `delete_utf8` |
| `history_update(res, bytes, by_line)` | DirtyCpu | wholesale swap: desktop restore |
| `history_commit(res, origin, msg, ts)` | normal | closes a change |
| `history_undo(res, actor)` / `history_redo(res, actor)` | normal | per-actor manager |
| `history_cursor(res, pos)` / `history_cursor_pos(res, cursor)` | normal | stable points |
| `history_export_snapshot(res)` / `history_export_updates(res, vv)` | DirtyCpu | disk and wire |
| `history_import(res, bytes)` | DirtyCpu | returns the new text |
| `history_changes(res)` | DirtyCpu | `export_json_in_id_span`, for `buffer-log` |
| `history_text(res)` | DirtyCpu | invariant checks only, not a read path |

**Pass text as `Binary`, never `String`.** Both existing crates take `text: String`,
which copies the whole buffer into Rust on entry. `ts_state_highlight(res, text)`
(`aimax_ts/src/lib.rs:454`) copies the entire buffer on every highlight and every
structural motion keypress. Fix that in the same pass. It is the reason a NIF
gets called slow.

### Changeset metadata

Origin and message are not interchangeable. **Only the message is durable.** `Change`
carries `commit_msg`; it carries no origin field, and Phase 0 confirmed that origin does
not survive an export and import. Origin is an event-time label that the undo managers
filter on while the history is live.

So every commit sets both:

- `set_next_commit_message(msg)` - the durable record: the actor from `resolve_actor/2`
  (`buffer.ex:1425`), its run id, and the intent
- `set_next_commit_origin(origin)` - the live routing label: `user`, `agent:codex`,
  `editor`, `process`, which is what `add_exclude_origin_prefix` matches
- `set_next_commit_timestamp(ts)`

Loro also merges adjacent changes from one peer within a second, and every local actor
shares this replica's peer id. Phase 2 measured `set_change_merge_interval(0)` and left
the default: Loro keeps changes with different commit messages apart, and two changes
with the same message are one actor doing the same work. Disabling the merge changed no
behaviour and only added change headers.

The buffer, not the library, owns batching. The pending changeset in the buffer process
and its flush boundaries already decide what one change contains.

The existing actor-change flush boundary already sits in the right place: `continues?/4`
(`buffer.ex:1625`) closes a changeset when `pending_actor.id` changes.

### Naming

The structure is `Aimax.Core.BufferHistory`, held as `state.history` and read as
`Buffer.history/1`. `Aimax.Core.BufferHistoryStore` owns the files.

Two cautions. `state.history` meant the undo snapshot stack until Phase 3 deleted it, so
that field name means something else in commits before `502860d`. And
`BufferStore.history` is a different thing again: the cross-process list of recently used
buffer names.

### Persistence

`checkpoint/1` (`buffer.ex:1187`) serializes flattened text today, and
`restored_state/1` (`:1161`) calls `Rope.new(cp[:text])`. Add exported history bytes
beside the text, so history survives eviction while the text keeps its current recovery
path. There is no database. `provenance.sqlite3` and `Aimax.Core.ProvenanceStore` are gone.

The store's last job was the recording policy, which is four fields: whether to record,
which policy said so, the retention, and whether there is a gap. The buffer checkpoint
already carried them, so they are read back from there. Everything else it held was
either dead (proposals, `head_id`, `head_hash`) or a second copy of the buffer's text,
written into a root revision that the weave already holds.

`exqlite` stays in `mix.exs`. Nothing uses it today.

### The metadata plane

Agents need none of this, so it stays out of scope until human peers arrive. At that
point presence, remote cursors, buffer locals, group membership, and the buffer registry
must converge too. Those are map CRDTs, and `delta_crdt` is native Elixir, needs no NIF,
lives in GenServer state, serializes into `desktop.etf` for free, and has 2.4M downloads
behind Horde. Do not reinvent it.

## Alternatives, and why not

Evaluated 2026-08-23.

**A fast VCS, one commit per mutation.** Git's object model is the Provenance data
model: revision is commit, ref update is compare-and-swap, content hash is blob id.
It fails on three counts. Never fork the binary, because yesterday alone produced
79,116 revisions. Every snapshot VCS writes a whole content object per commit, while
the current edit rows store operations and no snapshot, which is why the database is
62 MB rather than ten times that. And it merges nothing, so it does not answer
multiplayer.

**jj.** Not a better store, because jj's store is git. Two ideas are worth stealing:
the operation log, which versions repository state itself, and first-class conflicts.
The working-copy-as-commit model is a cost here, because it snapshots a real directory
on every command.

**yrs, the Yjs port.** Five times the downloads of any alternative and the safest pure
multiplayer bet. It keeps current state plus tombstones, not a change log carrying an
author and a message, so Provenance would need a second store beside it. `y_ex` on hex
wraps it for Elixir and is maintained.

**diamond-types.** The closest match on paper, and not maintained. Real development
ended around October 2024; all of 2025 produced ten commits, and the published crate is
1.0.0 from August 2022, which its own README calls out of date.

**A native BEAM CRDT.** None exists for text. `logoot` is from 2016 and Logoot's
position identifiers grow without bound. `lattice_text` uses the right algorithm family
but was published eleven days ago, in Gleam. The reason is structural: a text CRDT is
fast because it holds run-length-encoded blocks in flat arrays with a B-tree index and
mutates in place, and the BEAM path-copies on every update. It is the same reason this
project already put its rope in Rust.

**Loro.** Chosen. Its `Change` carries actor, parents, clocks, and an intent message,
so the CRDT's own structure answers the Provenance questions. There is no Loro package
on hex, so this NIF is code the project owns.

## Phase 0 results

Run on 2026-08-23, loro 1.13.9, release build with LTO, from
`apps/aimax_core/native/aimax_loro/src/main.rs`. The budget is 7 us, which is the
0.007 ms per keystroke the buffer meets today.

```
loro insert_utf8, one character        median      ropey, same edit
  empty history, append               0.250 us
  343 KB, append                       0.250 us
  343 KB, middle                       0.417 us    0.042 us
  3 MB,   middle                       0.416 us    0.083 us

343 KB history, 200 ops exchanged
  export updates                        11-21 us   294 B on the wire
  import updates                        77-82 us
  to_string                             44-65 us
  cursor resolve                        25-46 us
```

**The gate passes.** A Loro insert costs 0.25 to 0.42 us against a 7 us budget, and it
does not grow with the history: 343 KB and 3 MB cost the same. Loro adds about 0.33 us
on top of the ropey edit that already happens, so a keystroke stays around 0.5 us before
NIF overhead. Two hundred keystrokes compress to 294 bytes on the wire.

Three findings changed the design, and each is folded into the sections above.

1. **Origin is not durable.** It is an event-time label. `commit_msg` is a field of
   `Change` and survived an export and import round trip with the peer id intact. The
   actor goes in the message; the origin only drives undo filtering.
2. **Undo needs its own exclusion.** Reproduced: with two managers and no `undo`
   exclusion, the agent's undo entered the human's stack, and the human's next undo
   restored the agent's text instead of removing the human's own. Adding the exclusion
   to both managers gave clean, symmetric per-actor undo.
3. ~~**Cursor resolution is not free.** At 25 to 46 us it is fifty times a keystroke.~~
   **Wrong, and corrected in Phase 4.** That was one cold call. The median says taking a
   cursor costs 0.17 us and resolving a fresh one costs 0.042 us, at every size
   from 64 KB to 3 MB. The cost tracks the edits made since the cursor was taken, not the
   size of the history: after 2000 edits a resolve costs about 15 us. So a cursor the
   buffer re-takes on every move is free, and only a long-lived anchor ever pays.

The oplog grows about one byte per character, so a 343 KB buffer carries a 353 KB
oplog. Snapshot sizes measured here are not meaningful, because the synthetic seed text
is one line repeated and compresses far better than real source.

## Phases

**Phase 0 - measure first. Done.** See the results above.

**Phase 1 - the crate and the wrapper. Done.** `aimax_loro` is a rustler cdylib and
`Aimax.Core.BufferHistory` wraps it, with 15 tests. Nothing calls it yet. Cursors and versions
cross the boundary as opaque binaries, because `Cursor` and `VersionVector` encode
themselves. `history_register_actor` always excludes the `undo` origin, so the Phase 0 trap
cannot be reintroduced by a caller.

**Phase 2 - mirror from the funnel. Done.** `state.history` holds the history, `do_insert`
and `do_delete` mirror into it, `verify_doc` asserts the invariant at every checkpoint
boundary, and `Buffer.history/1` reads it. Undo still runs the old path and its tests are
unchanged. 14 tests in `buffer_history_mirror_test.exs`.

Two corrections to the plan came out of building it.

**The mirror runs after `open_changeset`, never before.** Opening a changeset flushes
the previous actor's work, and a history operation applied before that flush is
committed under the previous actor's name. The symptom was a human's change and an
agent's change collapsing into one change attributed to the human. The ordering is now
load-bearing and commented at both call sites.

**Desktop restore needs no special path.** It replaces text through `delete_range` and
`append` (`desktop.ex:187`), so it already funnels through `do_insert` and `do_delete`.
Only undo swaps the rope wholesale, so `history_update` has exactly one caller.

The invariant check materializes the history's text at every checkpoint, which costs
about 65 us for a 343 KB buffer at a 1.5 second cadence. That is affordable while the
rope is authoritative and worth keeping until the mirror has proven itself.

**Phase 3 - undo moves to Loro. Done.** Undo runs through the asking actor's
`UndoManager`, so it reverts only that actor's operations and rebases them over
everyone else's. `state.history`, `snapshot/1`, and `push_history` are gone. 19 tests in
`buffer_history_mirror_test.exs`.

Less changed than the plan expected. Both Emacs undo-model tests in `editor_test` pass
untouched: a run of undos still walks back, and a command that breaks the run still turns
the next undo into a redo. Only one existing test changed, and it changed for the better,
described below.

Three things had to be worked out while building it.

**The history commit had to come off the provenance flush.** `continues?` is false for
every non-batchable source, so an `:editor` or agent edit opens a changeset per
operation. While the history committed inside `flush_provenance`, a `replace_range`
split into two changes, and its delete and insert became two undo steps. The buffer now
tracks `history_actor`, the actor whose operations sit uncommitted in the history, and
commits on an actor change, at an undo boundary, and at a checkpoint. Provenance keeps
its own schedule.

**Undo applies a change rather than restoring a snapshot.** Comparing the rope's text
with the history's gives one contiguous replacement, which then runs through the same
range adjustment as any other edit. Overlays and the point now move with the text through
an undo instead of going stale for a mode to heal. `overlay_test` asserted the staleness
and now asserts the tracking.

**An undo authors only what it brings back.** Text restored by an undo is stamped with
the actor that asked for it. An undo that only deletes stamps nothing, so surviving spans
keep the authors that wrote them, and `author_test` passes unchanged. The full record
stays in the oplog either way: the original change and the undo are both there with their
own actors.

A checkpoint closes the open undo step, so a typing run crossing the 1.5 second boundary
becomes two steps rather than one. Emacs already caps a run at 20 characters, so this is
a comparable granularity rather than a new kind of split.

**Phase 4 - cursors. Half done, deliberately.**

`Buffer.anchor/2` and `Buffer.anchor_pos/2` turn a byte position into a token that keeps
naming the same place while the text around it changes, and survives a restart. They
reach Scheme as `(buffer-anchor BUF POS)` and `(buffer-anchor-pos BUF ANCHOR)`, base64 so
an anchor travels through a tool call. `code-outline` now anchors every line it reports
and `code--with-node` follows the anchor, which closes a real hole on the historyed
agent path: an agent reads an outline, thinks for a few seconds, and calls
`code-replace!` with a line that a person has meanwhile moved.

**The name check turned out to matter more than the anchor.** Two comments at the top
level change which level tree-sitter folds at, so the outline collapses from two
functions to one module, and a line that named a function now names the whole file.
The anchor still resolves, so position alone is not enough. `code-outline` records the
name it reported for each line, and `code--with-node` refuses when the definition it
finds no longer carries that name. Without the check, `code-replace!` would have
silently replaced the entire file. That failure exists today, before any of this.

Each `code-outline` call replaces the map, because the lines an agent holds come from
the outline it last read.

**The point and mark stay as they are.** `adjust_point_insert` and `adjust_ranges` are
O(1) arithmetic and correct for every edit the buffer applies itself, which is every edit
that exists today. They become wrong only for an edit the buffer did not apply, which
arrives with the transport in Phase 6. Converting them now would churn correct code and
put a NIF call on the point path for no change in behaviour, so it waits for the phase
that needs it.

**Phase 5 - the history becomes durable, and is the only record. Done.**

The database went with it. See "Persistence" above.

`BufferHistoryStore` keeps one log file per buffer under `~/.aimax/history/`, a sequence
of length-prefixed blobs: a snapshot first, updates after. Measured on an 85 KB source
file, a snapshot is 74 KB and 500 typed characters export as 1.2 KB, so appending on
every checkpoint is affordable only in the update form. The log is rewritten as one
snapshot when it outgrows four times the text.

A torn tail is expected rather than exceptional. A crash between the write and the flush
leaves a partial frame, so the reader stops at the first frame it cannot trust and keeps
everything before it: a crash costs the last batch and never the history.

When the text moved while the buffer was away, a file re-read from disk being the usual
case, the history takes the new text as a change by a `system:reload` actor rather than
being discarded.

`flush_provenance` no longer writes revisions. `Buffer.provenance_history/1` is gone and
`Buffer.change_log/1` replaces it, reading the weave. `M-x buffer-log` renders from that,
so the store now keeps only the cell, the actors, and the recording policy.

Four things came out of doing it.

**A change names the end of its parent, not its parent.** Loro's `deps` point at the last
operation of the change they follow, so a reader has to resolve a dependency back to the
change that contains it before it means anything.

**A delete records how many bytes it took, not the text.** The removed text is still in
the history, but reading it back means checking out the version before the delete, which
a list of rows does not do. The log shows the count.

**Adjacent keystrokes are one operation.** The history run-length encodes a run, so five
typed characters are one operation of five bytes rather than five of one. The old revision
rows kept them apart.

**An empty buffer has no root change.** A commit with no operations makes no change, so
the first thing written into an empty buffer is the first change there is.

The atomic lane keeps its promise. An agent edit commits and reaches the log before its
caller hears that it worked, and a save does the same for the typing behind it. A
replacement stays one change and one undo step, because closing between its delete and
its insert would make it two.

**Phase 6 - transport. The receive half is done; the wire is not.**

A buffer can take changes another replica made. `Buffer.merge/2` imports them, the rope
follows through the same path an undo uses, and the point is carried past the edit rather
than moved to it. `Buffer.updates_since/2` exports what a replica at a given version is
missing, and `Buffer.version_token/1` is that version. The bytes are the same in both
directions and the same as the log holds, so a wire and a file carry the history in one
form.

Verified in `buffer_merge_test.exs`: an edit made here and one made there both survive,
both sides finish with the same text, both actors are named in the merged history, typing
continues over an arriving change, and undoing your own work after a merge does not take
back theirs.

**A home is a replica.** The peer id lives in `~/.aimax/peer-id` beside the buffers and
the logs, and everything in that directory belongs to the one writer it names. The
corollary caught the first draft of the test: two buffers in one daemon share that id, so
they are not two replicas, and a history exported from one cannot be merged into the
other. A real peer has its own home.

**The wire is the socket the daemon already listens on.** There is no Loro server: Loro
emits bytes and something moves them, and eval is the API. `Aimax.Core.Peer` sends one
`eval` to another home's socket, locally or over ssh through the same `~/.ssh/config`
remote buffers use. `priv/packages/peers.scm` holds the policy: `peer-pull!`,
`peer-push!`, `peer-sync!`, and `M-x sync-buffer-with-peer`.

The exchange is two questions and two answers, and both sides ask, so neither leads:

```
what do you have?        (buffer-version-token BUF)
what am I missing?       (buffer-updates-since BUF TOKEN)
here is what you missed  (buffer-merge! BUF UPDATES)
```

Verified between two real daemons, `AIMAX_HOME=/tmp/peer-a` and `/tmp/peer-b`, each with
its own home, socket and peer id. Both held "base". A appended " FROM-A" and B inserted
"FROM-B " with neither having seen the other, so A read "base FROM-A" and B read
"FROM-B base". One `peer-sync!` from B, and both read "FROM-B base FROM-A". A's history
then carried two changes under two different peer ids, which is what proves the work came
from two replicas rather than one.

Nothing polls. A sync happens when somebody asks for one, because deciding when is a
policy question nobody has answered. The topology question the plan deferred is now
narrower than it was: peers reach each other directly, and a relay is only needed for a
replica that is never online at the same time as the others.

Two Loro capabilities are still not exposed, and the wire wants both. `subscribe`
delivers a change event, which would replace the text diff `apply_history_text` does to
work out what arrived. `checkout` reads the text at any past version, which is what
`M-x buffer-log` needs to show a state rather than a list.

## Risks

- **Undo semantics changed in Phase 3, deliberately.** Human undo skips agent edits, and
  overlays now track through an undo. The Emacs undo and redo model survived unchanged.
- **Divergence.** Two representations can disagree. The hash check at checkpoint
  boundaries is the detector; rebuild the rope from the doc to fix it. Log rather than
  crash, matching `flush_provenance` (`buffer.ex:1714`).
- **Peer identity under one PeerID.** Resolved in Phase 0. All local actors share the
  replica's PeerID and are distinguished by origin, and origin exclusion gives clean
  symmetric per-actor undo once every manager also excludes `undo`. The fallback, one
  document per actor synced in-process, is not needed.
- **Memory is doubled and half is invisible to the BEAM.** A `ResourceArc` drops when
  the last term is collected, not when the buffer process dies. Check against the
  eviction path in `buffer_store.ex:147`.
- **Import panics.** The first time the daemon decodes bytes it did not write. Rustler
  turns a panic into an Elixir exception rather than killing the VM, but the doc is then
  suspect. Guard and fuzz the import path.
- **Loro 1.x churns.** Pin the exact version. No `rustler_precompiled` here, so every
  developer builds it. There is no Loro package on hex; this NIF is code you own.
- **Migration.** `provenance.sqlite3` holds 79,116 revisions and 62 MB after about a
  day. Decide whether to import or start a new epoch before more accrues.
- Adjacent bug found while reading: `buffer_group/1` (`buffer.ex:1678`) reads
  `state.locals["group"]`, but `priv/packages/groups.scm:11` says work buffers moved to
  `'group-ids`. Changeset context records the wrong group today. Separate fix.

## Verification

- `mix test` and `bin/test-fast`, all four apps green.
- **The undo test that matters:** an agent inserts into a buffer, the human types, the
  human undoes. Assert the human's text is reverted and the agent's text is untouched.
  This test fails against the current code.
- Invariant test: after a scripted sequence of user edits, agent edits, undo, and redo,
  assert `Rope.to_binary(rope) == History.text(history)`.
- Cursor test: place a point, have an agent insert above it, assert the point moved by
  the inserted byte count without a manual adjustment.
- Stale-anchor test: an agent takes a cursor pair over a range, the human inserts above
  it, the agent's `replace_range` lands on the intended text and not on a shifted offset.
- Convergence test: two docs edit the same buffer, exchange updates both ways, and
  converge to the same text and the same frontier.
- Restart test: edit, `mix aimax.restart`, confirm the text and the history return.
  Editor state must survive a reload, per the project rule.
- Drive real keystrokes through `KeyDispatch.handle_key/1`, not the buffer API.
- Verify a code buffer, a morg buffer, and a chat buffer in a browser, then screenshot.
