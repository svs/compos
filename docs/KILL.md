# Killing buffers

This document defines what `buffer-kill!` and buffer-kill commands must do.
The rules apply to every frame unless a command states a narrower policy.

## Goals

A kill must leave no window on a dead buffer. A kill should not create duplicate
windows for a surviving buffer. The editor should change the layout when that
change can prevent a duplicate. The editor must always keep one live window in
each frame.

Killing a buffer destroys editor state. It is not the same as hiding a window,
burying a buffer, closing a popup, or making a live buffer dormant.

## The operation

A complete kill has these phases:

1. The command decides which buffers it may kill.
2. The command handles unsaved files and attached processes.
3. Package policy records any state that it needs from the live buffer.
4. The core releases every window that shows the buffer.
5. The core closes buffer-owned runtime state and destroys the buffer.
6. Package policy repairs any surviving scoped views.

The core window release is mandatory. Package repair can narrow replacement
choices, but it cannot leave a window on the dead buffer.

## One buffer

`kill-buffer` defaults to the current buffer. The prompt can select another
buffer. When a file buffer has unsaved text, the high-level kill asks before
discarding it.

`kill-buffer-confirm!` is the shared named-buffer API for that policy. If the
buffer owns a running process, it stops that process before killing. The
low-level `buffer-kill!` operation only kills the buffer and deliberately does
not confirm or stop processes.

Killing an unknown buffer reports `not_found`. Killing a dormant known buffer
forgets its saved identity without changing a layout.

## Several buffers

Batch commands must define their own confirmation boundary. They must inspect
all targets before the first destructive action when partial completion is not
acceptable.

Project and group kill commands protect modified file buffers. They ask for the
required decision and report buffers that remain. List commands may kill only
the marked or current rows that still exist.

Each successful member kill uses the same window rules as a single-buffer kill.
The next member observes the layout produced by the previous member.

## Window and layout policy

The core applies these rules to each frame:

1. If the frame does not show the buffer, its layout does not change.
2. If other windows survive, remove every window that shows the killed buffer.
3. Collapse each empty split by promoting its surviving sibling subtree.
4. If the active window is removed, select the first surviving leaf.
5. Preserve the window IDs, points, and scroll state of surviving leaves.
6. Drop the saved window point for every removed leaf.

These rules prefer a layout change over a replacement that duplicates a visible
buffer. They also avoid choosing an unrelated buffer only to preserve a split.

If every leaf in a frame shows the killed buffer, the frame cannot remove every
leaf. The core keeps the active leaf, or the first leaf when none is active. It
removes the duplicate leaves and gives the kept leaf a live fallback buffer.

The fallback order is:

1. The most recent live buffer that no frame currently shows.
2. The most recent live buffer.
3. `*scratch*`.

The first choice avoids a duplicate across frames. The second choice permits a
duplicate only when the frame needs a live sole window. The final choice creates
`*scratch*` when required.

## Important layouts

| Before the kill | Result |
|---|---|
| One leaf shows the victim | Keep one leaf and show the fallback. |
| One victim leaf and one survivor leaf | Remove the victim leaf. |
| Several victim leaves and one survivor subtree | Remove all victim leaves. |
| Every leaf shows the victim | Keep one leaf, then show the fallback. |
| No leaf shows the victim | Keep the layout unchanged. |
| Several frames show the victim | Apply the rules independently to each frame. |

Split removal preserves the structure inside the surviving subtree. The removed
split ratio has no meaning after its branch disappears.

## Groups and scoped views

A grouped frame must not replace a killed member with a foreign MRU buffer.
Group repair may choose a hidden live member from that frame's current group.
If no hidden member exists, it may use another group member or the group chat.

A pinned group uses this final fallback order:

1. A live hidden member of the pinned group.
2. A live visible member of the pinned group.
3. The pinned group's primary chat.

The group chat is a total scoped fallback. Group repair creates it when every
other member is dead. A global MRU buffer or `*scratch*` must not remain visible
in the pinned frame after repair.

The general layout rule still applies when another group window already
survives. In that case, removing the victim window is a valid group repair. A
pinned group keeps its `current-group` value throughout the kill.

Other packages can use `buffer-kill-repair`. The policy callback inspects the
live buffer before the core kill and returns a repair thunk. The Scheme wrapper
runs the thunk after destruction. The thunk must tolerate removed windows and
frames.

## Last-buffer rules

Every editor has a live landing buffer. The core does not kill `*scratch*` when
it is the final live buffer. Before killing the final non-scratch buffer, the
core creates `*scratch*` and uses it as the fallback.

Desktop restore must not resurrect a killed buffer. A saved layout that names a
dead buffer uses the separate restore repair policy.

## Buffer-owned state

The kill closes an attached LLM session. It discards the buffer text, undo
history, locals, overlays, per-window points, and stored identity. File contents
on disk do not change unless a command saved them before the kill.

The buffer name becomes available for later creation. Recreating that name makes
a new buffer and does not restore the killed identity.

## Required tests

Tests must cover these cases:

- A displayed victim never remains in `window-list`.
- A victim beside a survivor removes its leaf.
- Duplicate victim leaves collapse to one fallback leaf.
- A sole victim leaf receives a live fallback.
- A non-visible kill leaves every layout unchanged.
- A grouped frame never shows a foreign replacement.
- A pinned group keeps its frame context.
- An empty pinned group lands on its live group chat.
- Killing the final non-scratch buffer lands on `*scratch*`.
- Killing the final `*scratch*` is a no-op.
- A stale click during a kill cannot crash the editor.
