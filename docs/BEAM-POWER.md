# What the BEAM buys us

Read `ARCHITECTURE.md` first. That document says what the parts are. This one
says why they are shaped that way, and what the shape asks of you when you add
a part.

The one rule of this repository is that Elixir supplies mechanism and Scheme
decides policy. This document is about the other half of that sentence: what
"mechanism" means on this runtime, and which patterns are load-bearing.

## An editor is a fleet, not a program

Count what runs at once in one daemon. Every open buffer. Every agent thread
and its subprocess. Every LSP connection, MCP connection, PTY, endpoint,
database connection and inbound HTTP listener. Every browser client. The file
watcher, the checkpointer, the provenance weave, the scheme lanes.

Each of those is long-lived, independent, and able to fail on its own. On most
runtimes you write an event loop and hope nothing blocks it. Emacs does that,
and one slow thing stops the world. Here we do not have to.

Four properties do the work.

**A process per real thing.** A buffer is a process. So is an agent, a
terminal, an LSP connection. `Aimax.Core.Application` gives each kind its own
`Registry` and its own `DynamicSupervisor`. The registry is the name service,
so `Buffer.exists?/1` is an ETS read and not a message. The supervisor is the
failure boundary.

**Preemptive scheduling.** The BEAM interrupts a process that runs too long.
This is why `Aimax.Core.Lane` works: a Scheme evaluation that takes ten seconds
holds its own lane, and a keystroke on the `:ui` lane still runs. No cooperative
yield is needed, and none is possible to forget.

**Isolation.** A crash takes one process. A buffer is `restart: :temporary`
because a restarted buffer would come back empty, so it stays dead loudly
instead. That is a decision the runtime lets us make per part.

**Shared nothing, plus ETS where sharing pays.** Processes copy messages, so
nothing is silently shared. ETS is the deliberate exception: one writer, many
concurrent lock-free readers.

## The rules that follow

These are not style preferences. Each one exists because breaking it produced a
bug in this repository.

### Never call out of a process while it holds state others need

`Aimax.Core.Editor` is one process holding every frame. It used to call each
visible buffer from inside its own `handle_call` to build a render. One buffer
busy with a reparse, a checkpoint or a save then stalled every frame of every
client, because the Editor was still holding the editor while it waited.

The call was correct. The place was wrong. If your process is a lock that other
work needs, do not put a message send inside its critical section. Read from a
read model, or return the inputs and let the caller do the fetching.

### Writes go to the process, reads go to a read model

`Aimax.Core.BufferView` is the worked example. Each buffer publishes one public
ETS row. Every reader takes the row instead of sending a message. The buffer
process is still the only writer, so there is exactly one place where state
changes.

This is the standard BEAM trade, and it is worth stating plainly: it does not
make a read cheaper. An ETS read copies the term, the same as a reply does. It
removes the **queue**. A reader can no longer wait behind whatever the owner is
doing. That is a tail-latency fix, and tail latency is what a person feels as
"the editor froze".

Use it when reads outnumber writes and a stalled read is visible to a person.
Do not use it for state with one reader.

### Publish before you announce

A subscriber wakes on a change event and goes straight to the read model. So
the row must be written before the event is sent. `Buffer.broadcast/5` publishes
first for this reason.

Reverse the order and you get a bug that heals only on the next edit: the
client paints one edit behind, and no further event arrives to correct it.

### Derive in the reader, not in the writer

A row holds the per-tag overlay and fold maps, not the flattened lists. An edit
adjusts every range, so a writer that flattened would pay a concat and a sort on
every keystroke, to produce a shape only a render wants.

Put the cheap authoritative form in the row. Let each reader derive what it
needs, in its own process, where the cost is concurrent.

The same rule governs text. The row carries the rope handle, which is an
immutable Rustler resource, and carries the flattened binary only when the
writer already had one. A reader that wants bytes flattens them itself.

### The process that owns hot ETS must not run risky code

An ETS table dies with its owner. `Aimax.Core.BufferView` therefore creates the
table and does nothing else: it holds no buffer state and runs no buffer code.
On restart it re-adopts every live buffer and asks each for its row, so the
model heals instead of waiting for the next edit.

`Aimax.Core.SchemeTables` is the same answer for the Scheme world.
`Aimax.Core.Session` loads the stdlib, reloads files, rebinds primitives and
sweeps frames, and it used to own all three of the Scheme tables as well. One
crash there took every registered command and the whole environment with it,
and every lane worker holding the published handle then read a dead table id.

The two named tables are created once by the owner. Session empties and
refills them, so their identity is stable across a restart. The environment
table has to be created where `Scheme.new` runs, so Session names the owner
its heir: the table transfers instead of dying, in-flight lane work finishes
against it, and the owner drops it once the new Session has published its
replacement.

### Know which lane you are on

`Aimax.Core.Lane` routes Scheme by owner: `:ui` for keystrokes, a group, agent
or connection lane for everything else. A callback that fires from a connection
process must move to a lane before it evaluates Scheme. Callbacks that must
reach the display take the `:ui` lane.

If you add a mechanism that calls back into Scheme, decide its lane and write
the decision in the module doc.

### Supervise every task, and let timeouts belong to the caller

Background work goes through `Task.Supervisor` under
`Aimax.Core.TaskSupervisor`. An unsupervised `Task.async` inside a GenServer
links to it, so the task's crash becomes the GenServer's crash.

A `GenServer.call` timeout is the caller's statement about how long it is
willing to wait. Set it deliberately. `Lane.run` gives an evaluation 30
seconds, so anything that can block inside one must give up sooner and say so.

### A cast to a process that is not up is dropped silently

Child order in `Aimax.Core.Application` is real, and the comments there say
why. If your mechanism registers a handler by cast during boot, it must start
before the thing that casts to it.

## Adding a mechanism

A new mechanism module (`Endpoint`, `DB`, `WebServer` are the recent ones) is
usually the same shape:

1. A `Registry` for names and a `DynamicSupervisor` for lifetimes, in
   `Aimax.Core.Application`.
2. One process per live connection, holding only that connection's state.
3. A thin `Aimax.Core.<Thing>` module: start, stop, list, detail.
4. Primitives in `Aimax.Core.SchemeAPI` that carry values and no policy.
5. A Scheme package that owns the registry of specs, the commands, the display
   and every decision.

Before you write it, answer three questions in the module doc: what fails, what
that failure should take down with it, and which lane its callbacks run on.

## What this design still owes

Named so a contributor can pick one up, not as a warning.

- `Aimax.Core.Editor` is one global process for every frame. Frames are already
  independent. They could be processes, with the shared parts (keymaps, faces,
  kill ring) in ETS.
- Tree-sitter shares the buffer mailbox. `ts_node` is asked once per keypress
  and carries a 30 second timeout, in the process that also serves `:insert`,
  so a reparse of a large file sits in front of typing.

  The fix is a process per buffer that owns the parser, takes edits as casts
  and publishes spans into the read model. It is NOT a task: `TsRes` is a
  `Mutex<TsState>`, so a task parsing in parallel would hold that mutex and
  block the buffer's next `ts_state_edit` **inside the NIF**, which is worse
  than waiting in a mailbox. Whatever owns the parser must be the only thing
  that touches it. The hard part is keeping the tree in step with the rope
  through undo, which swaps a whole rope underneath it.
- The top-level supervisor is `:one_for_one`, and the child list documents a
  dependency order. `:rest_for_one` for the tail looks like the answer and is
  not: `Desktop.init` sends itself `:restore`, so a Session crash would
  re-restore the whole desktop over live buffers. Start order already comes
  from the list. Anything done here has to leave Desktop out.
