# Groups

A group is a set of buffers with a name and a remembered layout. Groups work like the desktops of a tiling window manager. You switch to a group, the screen shows what you left there, and you switch back.

A group is a convenience for the user and for agents. It is not a security boundary. When a group is wrong, one command fixes it.

This document is the specification, in this order:

1. The model.
2. The user stories.
3. The rules: membership, verbs, selection, lists, projects, windows, the scratch buffer, multi-membership, chats, persistence, the board.
4. Architecture reserved for later.
5. The implementation contract.
6. The acceptance list.

## Model

### Objects

- A **buffer** is global. It exists once. It carries `groups`: the set of groups it is in, possibly empty.
- A **group** has an opaque ID, a name, one saved layout per frame that has shown it, and one scratch buffer of its own. The members of a group are the buffers whose `groups` include it.
- A **frame** has a `destination` slot: a group ID or none. It also has a `previous` slot for the toggle.
- A **project** is a root directory derived from a file path. A project is not a group. It has no members, no layout, no ID, and no verbs. The editor uses it as a fallback in two places (see Projects).
- A **selection** is a set of buffers or paths marked by the user (see Selection).

### The three rules

1. A buffer that is **created** while the frame has an explicit destination joins that group.
2. **Showing** an existing buffer never changes a buffer's groups.
3. Every list of buffers puts the destination group first.

Membership is decided once, at creation, by one value. Nothing later revisits it. Junk is removed after the fact with `remove`.

### Resolution order

Wherever the editor needs "the group for X", the order is:

```
groups of X  ->  project of X  ->  none
```

The second step yields a root for narrowing and window fill. It never yields a group to switch to. Can be overridden with C-RET as seen later.

## User stories

Read each story as a path:

> As a user -> in this situation -> I want this outcome -> the editor behaves this way -> I use this command.

Some outcomes are automatic. Then the solution is a rule, not a command.

### As a user working in a group

#### I want to switch to another buffer in this group

- The switcher lists this group's buffers first, in MRU order.
- The project's other open files follow, then everything else.
- `RET` shows the buffer and changes no membership.
- **Command:** `switch-to-buffer`.

#### I want to look at a buffer from outside this group

- I pick it from the project or rest section.
- Showing it changes no membership. The destination does not change.
- The modeline indicator says "mixed" while it is visible.
- When I kill it, the window shows the next buffer of this group.
- **Command:** `switch-to-buffer`, then `RET`.

#### I want that outside buffer in this group

- I pick it and accept with `C-RET` instead of `RET`.
- The buffer is shown and added to the destination group.
- A mistake is one `remove` away.
- **Command:** `switch-to-buffer`, then `C-RET`.

#### I want to open a file and have it here

- A file with no buffer joins the destination group when I visit it.
- A file with a live buffer is shown and keeps its groups.
- **Solution:** creation joins, display does not. No command.

#### I want to jump to a definition and have it here

- The jump opens a buffer. The buffer joins the destination group.
- If the target is a live buffer, the jump shows it and changes no membership.
- **Solution:** the same creation rule. No command.

#### I want to clean junk out of this group

- I mark rows in the switcher and run `remove`.
- With no marks, `remove` acts on the current buffer.
- Buffers stay open. Only the membership goes.
- **Commands:** `buffer-select`, then `remove`.

#### I want to switch to another group

- Groups appear in this frame's MRU order, the current group excluded.
- Accepting a group saves this layout and restores that group's layout.
- **Command:** `switch`.

#### I want to go back to the group I just left

- One command flips to the previous group of this frame.
- **Command:** `switch-last`.

#### I want this buffer in another group too

- The group is added. Existing groups stay.
- I remain in this group.
- **Command:** `add`.

#### I want this buffer out of here and into another group

- All existing groups go. The destination is the only group.
- Text, point, modified state, and undo survive.
- **Command:** `move`.

#### I want a fresh group

- The group is created after I accept a unique name.
- The current buffer is its seed. The group opens on that buffer.
- **Command:** `new`.

#### I want a fresh, empty group

- I run `new` from a transient buffer, or with an empty selection.
- The group opens on its scratch buffer.
- **Command:** `new`.

#### I want a group from these buffers

- I mark buffers in any list and run `new`.
- Every marked buffer joins. The layout shows them.
- **Commands:** `buffer-select`, then `new`.

#### I want a group from the files in this directory

- In dired I mark files, or leave point on one, and run `new`.
- The files are visited, added, and shown.
- **Commands:** dired marks, then `new`.

#### I want to manage this group

- Rename it: `rename`.
- Drop the grouping and keep the buffers: `dissolve`.
- Kill the buffers that belong only to it: `kill`.
- See all groups: `groups`.

### As a user working in a buffer

#### I want to go to this buffer's group

- One group: the frame switches to it.
- Several groups: I choose one, always.
- No group: I name a new group and the buffer seeds it.
- **Command:** `switch-to-buffer-group`.

#### I want to change this buffer's groups by hand

- Add one: `add`. Replace all: `move`. Drop one: `remove`.
- These work when the frame has no destination too.

### As a user working with several windows

#### I want this arrangement to become a group

- I mark the visible buffers and run `new`.
- The layout is saved as the group's first layout.
- Existing groups stay.
- **Commands:** `buffer-select` on each window's buffer, then `new`.

#### I want the layout remembered as I left it

- Every switch saves the outgoing layout, mixed or not.
- A pane whose buffer is gone is dropped on the next restore.
- **Solution:** save on leave. No command.

#### I want to kill a buffer and stay in my group

- The window shows the next buffer of the destination group.
- With none, the window closes. The last window shows the scratch.
- **Solution:** window fill from the group. No command.

### As a user working without a group

#### I want the editor to stay focused on the project

- The switcher lists the current buffer's project files first.
- Killing a buffer fills the window from the same project.
- Nothing joins a group. A project is not a group.
- **Solution:** the project fallback. No command.

#### I want the current buffer to start a group

- **Command:** `new`, or `switch-to-buffer-group` on an ungrouped buffer.

#### I want to enter a group

- Groups appear in MRU order.
- **Command:** `switch`.

### As a user working with chats and agents

#### I want a chat for this group

- A chat created in the group joins the group like any buffer.
- The agent's context is the group's members and the current buffer.
- **Solution:** a chat is a buffer. No command.

#### I want the files an agent opens to land here

- Files an agent opens or edits from a chat on this frame join the destination group.
- Junk is removed with `remove`, the same as for a human.
- **Solution:** the creation rule. No command.

### As a user returning later or using several frames

#### I want groups to survive a restart

- Names, memberships, layouts, scratch content, and frame slots persist.
- A missing buffer or a malformed layout heals on restore.
- **Solution:** persistence and recovery. No command.

#### I want each frame to keep its own group

- Each frame has its own destination and previous slots.
- Two frames can show two groups, or one group with two layouts.
- **Solution:** per-frame slots. No command.

### Safety shared by every story

- Showing or switching buffers never changes a buffer's groups.
- Switching groups never changes a buffer's groups.
- `add` never removes. `move` names one destination. `remove` drops one group.
- No membership verb kills a buffer or changes a file.
- Cancel changes nothing durable.
- A wrong membership costs one command to fix.

## Membership

### Creation joins

A buffer created while frame F has destination A joins A. Creation means:

- `find-file` on a file that has no buffer.
- A jump (xref, LSP, grep, dired) that opens a new buffer.
- A buffer the editor makes: compile output, eval output, help, a chat.
- A file an agent opens or edits from a chat that is shown on F.

There are no exceptions. Cleanup is fast, so a gate at the door is not needed.

### Display does not join

Showing a buffer that already exists changes no membership. This covers `RET` in the switcher, `find-file` on a file with a live buffer, and a jump that lands in a live buffer.

### Agents without a frame

A chat that is not shown on any frame uses the chat's own groups. With several groups, the most recently added one applies. With no group, the buffers the agent creates stay ungrouped.

### No destination

When the frame has no destination, nothing joins anything. Lists and window fill use the project fallback (see Projects).

## Verbs

Every verb that takes buffers acts on the selection. With no selection it acts on the current buffer. A path in the selection is visited first.

| Verb | Effect |
|---|---|
| `add G` | Add the selection to G. Create G when the name is new. Adding a buffer that is in G is a no-op. |
| `move G` | Remove the selection from every group, then add it to G. |
| `remove G` | Remove the selection from G. The buffer stays open. |
| `switch G` | Save the frame's layout into the outgoing group. Set `previous`. Set `destination` to G. Restore G's layout on this frame. |
| `switch-last` | Swap `destination` and `previous`. |
| `switch-to-buffer-group` | Read the current buffer's groups. 0: prompt for a name and run `new`. 1: switch to it. 2 or more: prompt, always. |
| `new G` | Create G with its scratch buffer. Add the seed. Save a layout built from the seed. Switch to G. |
| `dissolve G` | Remove every member from G. Remove the scratch buffer and the record. Frames on G go to `previous`, else none. |
| `kill G` | For each member: when it is in another group, remove it from G; else kill it under the normal modified-buffer protection. Then dissolve G. A frame on G follows the buffer its window fell to into that buffer's group, with the group's layout; a buffer in no group leaves the frame in none. `group-after-kill` is `follow` (this) or `stay`. The kill runs `group-kill-hook` last, with `*group-killed*` = `(ID NAME STOOD?)`. |
| `rename G NAME` | Change the name. The ID, members, layouts, and MRU do not change. |
| `revive G` | Make a killed G again from the graveyard: the record, its meta, layout, noise, chat id, and color. Every member that still exists comes back: a buffer that is open joins; a file that exists on disk is visited into G. A member with neither is missing; the revival says how many. Then switch to G. |

### Kill, follow, revive

A kill is a scene change, not a window repair. The frame leaves G before the members die, so the window falls to the next buffer as any kill does, and the kill repair makes no chat for a group with seconds to live. Then `group-kill-hook` runs, with `*group-killed*` = `(ID NAME STOOD?)`. The default handler, `group-kill-follow!`, follows the buffer the window fell to into that buffer's group and restores the group's layout. `group-after-kill` turns it off (`stay`): the window still falls to the next buffer, and the frame derives its group from what it shows, but no layout is restored. An ungrouped buffer is not a second-class landing: the frame stands in no group and shows it.

The kill buries a tombstone: the name, the record's fields, and each member's name and file. The graveyard keeps the last twenty tombstones and persists with the desktop. `group-revive` (`M-x`) completes over them, newest first, and shows each one's members. A name that an open group already has is refused. The switcher's preview waits for the highlight to rest (`group-switch-peek-ms`, 120 ms) before it draws a group, so holding `C-n` moves through the list without a draw per row.

### The seed of `new`

- A selection is marked: the seed is the selection.
- No selection: the seed is the current buffer.
- The current buffer is transient: the seed is empty. The group has only its scratch buffer.

`switch-to-buffer-group` on an ungrouped buffer is `new` with that buffer as the seed.

### Atomic operations

- `new` writes the record before it adds the seed.
- `move` resolves the destination before it changes any membership. A failed destination changes nothing.
- Cancel before accept changes no record, membership, layout, or MRU.
- Membership verbs preserve text, file, point, modified state, and undo.

## Selection

`buffer-select` toggles a mark on the row at point in any buffer list. The selection is one set for the whole editor. A mark set in one list shows in every list.

The selection is a set of buffers or paths. Every membership verb resolves paths to buffers before it runs. Sources of a selection:

- The buffer switcher and the groups board: rows name buffers.
- Dired: marked files, else the file at point. A directory at point seeds its dired buffer, not the tree.
- Grep and xref result lists: rows name paths.

A successful verb clears the selection. A cancel keeps it.

## Lists

Every UI that lists buffers shows three sections. Each section is in MRU order. An empty section and its separator are omitted.

```
members of the destination group
------ project ------
open files under the current buffer's root, not already listed
------ rest ------
every other buffer
```

- Typing filters all three sections at once.
- The project section follows the current buffer's root. Peek at a file in another project and the middle section shows that project.
- With a destination and no project: two sections. With no destination in a project: two sections. With neither: one section.

In the switcher, `RET` shows the buffer and changes no membership. `C-RET` shows the buffer and adds it to the destination group. Both take the selection when one is marked. The switcher is not a special case; the same sections and verbs apply to every buffer list.

`ibuffer` is a buffer list too: the members of the frame's group lead the table, in their MRU order, and the rest follow in theirs. The order is fetched on open and on `g`. A mark, a flag, or a narrowing redraws the rows the table has, so a row never moves under the cursor. (A row's preview makes that buffer the most recent; a table that refetched on every mark moved the row you marked.)

## Projects

A project is the root directory of a file. The editor derives it from the path. A project acts in two places and nowhere else:

1. The middle section of every buffer list.
2. Window fill after `kill-buffer` when the frame has no destination.

Visiting a file never changes the destination. A group made from files inside a project is a plain group; its buffers are in the group and also fall under the root.

## Windows and switching

### Restore

`switch G` restores, per frame: the window tree, the buffer in each window, point and scroll per window, and the selected window. A group with no layout on this frame shows its scratch buffer in one window.

### Save

`switch` saves the outgoing layout as it is, every time. A layout that shows a foreign buffer is saved with it. Restore drops a pane whose buffer is gone, so a saved peek heals on the next switch.

### Window fill

`kill-buffer` fills each affected window in this order:

1. The next MRU member of the frame's destination group.
2. When the frame has no destination: the next MRU open file under the current buffer's root.
3. When a destination or a root exists and offers nothing: delete the window. The last window shows the group's scratch buffer.
4. When neither a destination nor a root exists: `other-buffer`, as in Emacs.
5. A popup does not count as another window: a window is deleted only when another work window can preserve the frame. A listing under a peek falls to its next buffer; the peek never becomes the only window. A peek is never a fill candidate, and the selection stays in the window that was selected.

Rule 1 is what returns a peek to the previous state. Nothing else is needed.

### Frames

The destination is per frame. Two frames can show two groups, or one group with two layouts. The `previous` slot is per frame.

### Indicator

A frame derives `current-group` from its visible non-transient buffers: the intersection of their groups. The modeline shows the name, or "mixed". The indicator decides nothing. It does not gate the layout save, it does not choose where new work goes, and it is not stored.

The active groups are derived the same way: `(active-groups)` answers every group with an open buffer, most recent first. The buffer list decides membership and the MRU only orders it; nothing is stored.

### Switch candidates

`switch` completes over groups in frame-local MRU order. The current group is excluded. Groups with no MRU entry trail in creation order. The last row is `new`.

### Candidate preview

Moving the highlight shows the group under it: its most recent member, in the window the prompt came from. The preview never moves the MRU ring and it saves no layout. `RET` puts that window back and then switches; `C-g` puts it back and changes nothing. The `new` row previews nothing.

### Transient buffers

One predicate, `transient?`, is true for the minibuffer, `*switch*`, the echo area, previews, and the groups board. Transient buffers are excluded from the indicator, from the seed of `new`, and from the selection. Every other buffer is a normal buffer.

## The scratch buffer

Every group has one scratch buffer named `*scratch: NAME*`.

- It is always in the group. `move` and `remove` refuse it.
- `kill-buffer` refuses it while the group exists. The echo area names the group.
- `kill G` and `dissolve G` remove it.
- It is the buffer of last resort for window fill inside the group.
- Its content persists with the group. A restored group with a missing scratch buffer gets a new empty one.

## Multi-membership

A buffer can be in many groups. No group is the owner.

- "Exclusive to G" is derived: the groups are exactly `{G}`.
- `add` never removes. `move` names one destination and replaces every group. `remove` drops one group.
- Three places read a buffer's groups: list sectioning, window fill, and `switch-to-buffer-group`. Layouts store buffer names, not groups.
- The one prompt in the system is `switch-to-buffer-group` with two or more groups. It always asks.

A group grows only while it is the destination of some frame, or by an explicit `add`. A group shrinks only by `remove`, `move`, `kill-buffer`, `dissolve`, or `kill`.

## Chats and agents

A chat is a buffer with groups like any other. There is no chat ownership store and no primary chat.

At the start of a turn an agent reads one `context` value:

- files: the members of the chat's group (the destination of the frame that shows the chat; else the chat's groups, see Membership).
- focus: the current buffer of that frame.

Tools an agent calls to list, search, read, or open buffers use the same three sections as the human's lists. The context is what the agent sees first, not what it is forbidden. Group membership never grants a tool permission.

## Persistence

`desktop.etf` stores, per group: ID, name, its members, per-frame layouts, and scratch content. Per frame: `destination` and `previous`.

Restore heals: it drops panes whose buffers are gone, deduplicates memberships, rejects a malformed layout, recreates a missing scratch buffer, and isolates a failure to one group. Restore never resurrects a killed buffer.

Rename and restart never change a group's ID.

## The groups board

`groups` opens a list buffer with one row per group: name, member count, modified count, and the frames that show it. Row verbs: switch, rename, dissolve, kill, members. `members` opens the switcher on that group's members with the selection model of Selection. Refreshing the board changes no membership, layout, MRU, or destination.

## Architecture reserved for later

These are not in this specification. The design leaves room for them.

- **Transient layouts.** A frame holds a base layout and, optionally, one transient layout on top. Save-on-leave saves the base. Leaving the transient restores the base. A future `tile-all` grid is a transient layout.
- **Landing.** `switch G` may take an optional landing layout to show instead of the saved one, without saving it.
- **Narrow.** A hard scope on top of the soft sections is parked.

## Implementation contract

### Records

- Every group has one immutable opaque ID and one durable record.
- Names are unique after trimming and are mutable.
- A record survives with no members. `dissolve` and `kill` retire it.
- Code uses the ID for membership, MRU, layouts, and frame slots. Names are for display and completion.

### Membership storage

- A buffer stores a set of valid group IDs in a buffer-local.
- Membership derives from that buffer-local. No second roster is authoritative.
- Killing a buffer removes it from every group with no extra work.
- Adding a present membership and removing an absent one are successful no-ops.

### Frame slots

- `previous` and `pinned` are per-frame state. `switch`, `switch-last`, `new`, `dissolve`, `kill`, and `group-pin` write them.
- `destination` (the current group) is derived. The stored frame-local is the last answer of the derivation, not a standing context. See "The current group".
- A frame with no destination is the plain editor plus the project fallback.

### The current group

The frame stands in the group its windows show. The rules:

1. The current group is the group every work window's buffer shares. A window whose buffer is in no group makes the answer "no group". A window whose buffer is transient (a listing, a prompt) says nothing.
2. A popup window says nothing. A listing, the messages buffer, or the telemetry floating over the group's panes is a visit, not a place. Opening and closing a popup changes no group.
3. When several groups are shared by every window, the frame keeps its current one if it is among them, else the most recent of them.
4. A pinned frame keeps its pinned group through every window change.
5. The derivation runs after every change of the frame's windows or their buffers, whoever made the change. The editor calls `window-configuration-changed!` (Emacs `window-configuration-change-hook`) from its one commit point; a command, a kill that drops a window onto its next buffer, and an agent all reach it. The window commands also run it before they return, so their modeline is right at once.
6. A visit to an ungrouped buffer in a work window leaves the group; killing that buffer drops the window onto its next buffer, and the frame is back in that buffer's group with no command involved.

### Layouts

- One saved layout per (group, frame). `switch` writes it on leave and reads it on enter.
- Restore validates every pane. A pane whose buffer is dead is dropped. A group with no valid pane shows its scratch buffer.
- One `switch` records one frame-local MRU entry.

## Acceptance list

Tests name commands, never keys. A test that needs a binding binds its own dummy key to its own dummy command.

1. Creation joins with a destination set: file, jump, editor-made buffer, agent-made buffer.
2. Creation with no destination stays ungrouped.
3. Showing a live buffer changes no membership: switcher, `find-file`, jump.
4. `C-RET` semantics in the switcher: show plus add, on one buffer and on a selection.
5. `add`, `move`, `remove` on one buffer, on a selection, on a dired selection, on a path selection.
6. `new` with a selection seed, a current-buffer seed, and an empty seed.
7. `switch-to-buffer-group` with 0, 1, and many groups; the many case prompts.
8. `switch` saves the outgoing layout as it is and restores tree, buffers, point, scroll, and selected window.
9. A saved layout with a dead buffer restores without that pane.
10. Window fill order: group member, project file, delete window, scratch as last window, `other-buffer` with no context.
11. Three-section lists: all combinations of destination and project present or absent; filter across sections; project section follows the current buffer.
12. `dissolve` drops memberships and keeps buffers; frames go to `previous`.
13. `kill` drops the membership on shared buffers, kills exclusive ones, honours modified protection, switches frames to the next group.
14. Scratch buffer refuses `kill-buffer`, `move`, `remove`; goes with `kill` and `dissolve`; persists content.
15. Per-frame destination and `previous`; two frames on one group with two layouts.
16. Persistence: groups, memberships, layouts, scratch, frame slots survive a restart; malformed state isolates to one group.
17. Agent context: files and focus from the chat's frame, else from the chat's groups.
18. The current group derives from the work windows: two windows in one group put the frame in it; a window on an ungrouped buffer takes it out.
19. A popup over the group changes nothing: open, and closed again, the frame's group is the same.
20. A kill from outside any command (the Elixir path) that drops a window onto a group's buffer puts the frame back in that group.
21. `ibuffer` lists the frame's group first, and a mark does not reorder the rows.
