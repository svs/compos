# Groups

A group is a set of buffers with a name and a remembered layout. Groups
work like the desktops of a tiling window manager. You switch to a group,
the screen shows what you left there, and you switch back.

A group is a convenience for the user and for agents. It is not a security
boundary. When a group is wrong, one command fixes it.

This document is the specification, in this order:

1. The model.
2. The user stories.
3. The rules: membership, verbs, selection, lists, projects, windows,
   the scratch buffer, multi-membership, chats, persistence, the board.
4. Architecture reserved for later.
5. The implementation contract.
6. The acceptance list.

## Model

### Objects

- A **buffer** is global. It exists once. It carries `tags`: a set of
  group IDs, possibly empty.
- A **group** has an opaque ID, a name, one saved layout per frame that
  has shown it, and one scratch buffer of its own. The members of a group
  are the buffers that carry its tag.
- A **frame** has a `destination` slot: a group ID or none. It also has a
  `previous` slot for the toggle.
- A **project** is a root directory derived from a file path. A project
  is not a group. It has no tags, no layout, no ID, and no verbs. The
  editor uses it as a fallback in two places (see Projects).
- A **selection** is a set of buffers or paths marked by the user (see
  Selection).

### The three rules

1. A buffer that is **created** while the frame has an explicit
   destination joins that group.
2. **Showing** an existing buffer never changes a tag.
3. Every list of buffers puts the destination group first.

Membership is decided once, at creation, by one value. Nothing later
revisits it. Junk is removed after the fact with `remove`.

### Resolution order

Wherever the editor needs "the group for X", the order is:

```
user tags of X  ->  project of X  ->  none
```

The second step yields a root for narrowing and window fill. It never
yields a group to switch to.

## User stories

Read each story as a path:

> As a user -> in this situation -> I want this outcome -> the editor
> behaves this way -> I use this command.

Some outcomes are automatic. Then the solution is a rule, not a command.

### As a user working in a group

#### I want to switch to another buffer in this group

- The switcher lists this group's buffers first, in MRU order.
- The project's other open files follow, then everything else.
- `RET` shows the buffer and changes no tag.
- **Command:** `switch-to-buffer`.

#### I want to look at a buffer from outside this group

- I pick it from the project or rest section.
- Showing it changes no tag. The destination does not change.
- The modeline indicator says "mixed" while it is visible.
- When I kill it, the window shows the next buffer of this group.
- **Command:** `switch-to-buffer`, then `RET`.

#### I want that outside buffer in this group

- I pick it and accept with `C-RET` instead of `RET`.
- The buffer is shown and tagged with the destination group.
- A mistake is one `remove` away.
- **Command:** `switch-to-buffer`, then `C-RET`.

#### I want to open a file and have it here

- A file with no buffer joins the destination group when I visit it.
- A file with a live buffer is shown and keeps its tags.
- **Solution:** creation joins, display does not. No command.

#### I want to jump to a definition and have it here

- The jump opens a buffer. The buffer joins the destination group.
- If the target is a live buffer, the jump shows it and changes no tag.
- **Solution:** the same creation rule. No command.

#### I want to clean junk out of this group

- I mark rows in the switcher and run `remove`.
- With no marks, `remove` acts on the current buffer.
- Buffers stay open. Only the tag goes.
- **Commands:** `buffer-select`, then `remove`.

#### I want to switch to another group

- Groups appear in this frame's MRU order, the current group excluded.
- Accepting a group saves this layout and restores that group's layout.
- **Command:** `switch`.

#### I want to go back to the group I just left

- One command flips to the previous group of this frame.
- **Command:** `switch-last`.

#### I want this buffer in another group too

- The tag is added. Existing tags stay.
- I remain in this group.
- **Command:** `add`.

#### I want this buffer out of here and into another group

- All existing tags go. The destination tag is set.
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
- Every marked buffer is tagged. The layout shows them.
- **Commands:** `buffer-select`, then `new`.

#### I want a group from the files in this directory

- In dired I mark files, or leave point on one, and run `new`.
- The files are visited, tagged, and shown.
- **Commands:** dired marks, then `new`.

#### I want to manage this group

- Rename it: `rename`.
- Drop the grouping and keep the buffers: `dissolve`.
- Kill the buffers that belong only to it: `kill`.
- See all groups: `groups`.

### As a user working in a buffer

#### I want to go to this buffer's group

- One tag: the frame switches to it.
- Several tags: I choose one, always.
- No tag: I name a new group and the buffer seeds it.
- **Command:** `switch-to-buffer-group`.

#### I want to change this buffer's tags by hand

- Add one: `add`. Replace all: `move`. Drop one: `remove`.
- These work when the frame has no destination too.

### As a user working with several windows

#### I want this arrangement to become a group

- I mark the visible buffers and run `new`.
- The layout is saved as the group's first layout.
- Existing tags stay.
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
- Nothing is tagged. A project is not a group.
- **Solution:** the project fallback. No command.

#### I want the current buffer to start a group

- **Command:** `new`, or `switch-to-buffer-group` on an untagged buffer.

#### I want to enter a group

- Groups appear in MRU order.
- **Command:** `switch`.

### As a user working with chats and agents

#### I want a chat for this group

- A chat created in the group is tagged like any buffer.
- The agent's context is the group's members and the current buffer.
- **Solution:** a chat is a buffer. No command.

#### I want the files an agent opens to land here

- Files an agent opens or edits from a chat on this frame join the
  destination group.
- Junk is removed with `remove`, the same as for a human.
- **Solution:** the creation rule. No command.

### As a user returning later or using several frames

#### I want groups to survive a restart

- Names, tags, layouts, scratch content, and frame slots persist.
- A missing buffer or a malformed layout heals on restore.
- **Solution:** persistence and recovery. No command.

#### I want each frame to keep its own group

- Each frame has its own destination and previous slots.
- Two frames can show two groups, or one group with two layouts.
- **Solution:** per-frame slots. No command.

### Safety shared by every story

- Showing or switching buffers never changes a tag.
- Switching groups never changes a tag.
- `add` never removes. `move` names one destination. `remove` drops one
  tag.
- No membership verb kills a buffer or changes a file.
- Cancel changes nothing durable.
- A wrong tag costs one command to fix.

## Membership

### Creation joins

A buffer created while frame F has destination A gets tag A. Creation
means:

- `find-file` on a file that has no buffer.
- A jump (xref, LSP, grep, dired) that opens a new buffer.
- A buffer the editor makes: compile output, eval output, help, a chat.
- A file an agent opens or edits from a chat that is shown on F.

There are no exceptions. Cleanup is fast, so a gate at the door is not
needed.

### Display does not join

Showing a buffer that already exists changes no tag. This covers `RET` in
the switcher, `find-file` on a file with a live buffer, and a jump that
lands in a live buffer.

### Agents without a frame

A chat that is not shown on any frame uses the chat's own tags. With
several tags, the most recently added one applies. With no tags, the
buffers the agent creates stay untagged.

### No destination

When the frame has no destination, nothing joins anything. Lists and
window fill use the project fallback (see Projects).

## Verbs

Every verb that takes buffers acts on the selection. With no selection it
acts on the current buffer. A path in the selection is visited first.

| Verb | Effect |
|---|---|
| `add G` | Tag the selection with G. Create G when the name is new. Adding a present tag is a no-op. |
| `move G` | Clear every tag of the selection, then tag with G. |
| `remove G` | Drop tag G from the selection. The buffer stays open. |
| `switch G` | Save the frame's layout into the outgoing group. Set `previous`. Set `destination` to G. Restore G's layout on this frame. |
| `switch-last` | Swap `destination` and `previous`. |
| `switch-to-buffer-group` | Read the current buffer's tags. 0: prompt for a name and run `new`. 1: switch to it. 2 or more: prompt, always. |
| `new G` | Create G with its scratch buffer. Tag the seed. Save a layout built from the seed. Switch to G. |
| `dissolve G` | Drop tag G from every member. Remove the scratch buffer and the record. Frames on G go to `previous`, else none. |
| `kill G` | For each member: when it has another tag, drop tag G; else kill it under the normal modified-buffer protection. Then dissolve G. Frames on G switch to the next group in MRU order, else none. |
| `rename G NAME` | Change the name. The ID, tags, layouts, and MRU do not change. |

### The seed of `new`

- A selection is marked: the seed is the selection.
- No selection: the seed is the current buffer.
- The current buffer is transient: the seed is empty. The group has only
  its scratch buffer.

`switch-to-buffer-group` on an untagged buffer is `new` with that buffer
as the seed.

### Atomic operations

- `new` writes the record before it tags the seed.
- `move` resolves the destination before it changes any tag. A failed
  destination changes nothing.
- Cancel before accept changes no record, tag, layout, or MRU.
- Membership verbs preserve text, file, point, modified state, and undo.

## Selection

`buffer-select` toggles a mark on the row at point in any buffer list. The
selection is one set for the whole editor. A mark set in one list shows in
every list.

The selection is a set of buffers or paths. Every membership verb resolves
paths to buffers before it runs. Sources of a selection:

- The buffer switcher and the groups board: rows name buffers.
- Dired: marked files, else the file at point. A directory at point
  seeds its dired buffer, not the tree.
- Grep and xref result lists: rows name paths.

A successful verb clears the selection. A cancel keeps it.

## Lists

Every UI that lists buffers shows three sections. Each section is in MRU
order. An empty section and its separator are omitted.

```
members of the destination group
------ project ------
open files under the current buffer's root, not already listed
------ rest ------
every other buffer
```

- Typing filters all three sections at once.
- The project section follows the current buffer's root. Peek at a file
  in another project and the middle section shows that project.
- With a destination and no project: two sections. With no destination in
  a project: two sections. With neither: one section.

In the switcher, `RET` shows the buffer and changes no tag. `C-RET` shows
the buffer and adds it to the destination group. Both take the selection
when one is marked. The switcher is not a special case; the same sections
and verbs apply to every buffer list.

## Projects

A project is the root directory of a file. The editor derives it from the
path. A project acts in two places and nowhere else:

1. The middle section of every buffer list.
2. Window fill after `kill-buffer` when the frame has no destination.

Visiting a file never changes the destination. A group made from files
inside a project is a plain group; its buffers carry the tag and also fall
under the root.

## Windows and switching

### Restore

`switch G` restores, per frame: the window tree, the buffer in each window,
point and scroll per window, and the selected window. A group with no
layout on this frame shows its scratch buffer in one window.

### Save

`switch` saves the outgoing layout as it is, every time. A layout that
shows a foreign buffer is saved with it. Restore drops a pane whose buffer
is gone, so a saved peek heals on the next switch.

### Window fill

`kill-buffer` fills each affected window in this order:

1. The next MRU member of the frame's destination group.
2. When the frame has no destination: the next MRU open file under the
   current buffer's root.
3. When a destination or a root exists and offers nothing: delete the
   window. The last window shows the group's scratch buffer.
4. When neither a destination nor a root exists: `other-buffer`, as in
   Emacs.

Rule 1 is what returns a peek to the previous state. Nothing else is
needed.

### Frames

The destination is per frame. Two frames can show two groups, or one
group with two layouts. The `previous` slot is per frame.

### Indicator

A frame derives `current-group` from its visible non-transient buffers:
the intersection of their tags. The modeline shows the name, or "mixed".
The indicator decides nothing. It does not gate the layout save, it does
not choose where new work goes, and it is not stored.

### Switch candidates

`switch` completes over groups in frame-local MRU order. The current group
is excluded. Groups with no MRU entry trail in creation order. The last
row is `new`.

### Transient buffers

One predicate, `transient?`, is true for the minibuffer, `*switch*`, the
echo area, previews, and the groups board. Transient buffers are excluded
from the indicator, from the seed of `new`, and from the selection. Every
other buffer is a normal buffer.

## The scratch buffer

Every group has one scratch buffer named `*scratch: NAME*`.

- It always carries the group's tag. `move` and `remove` refuse it.
- `kill-buffer` refuses it while the group exists. The echo area names the
  group.
- `kill G` and `dissolve G` remove it.
- It is the buffer of last resort for window fill inside the group.
- Its content persists with the group. A restored group with a missing
  scratch buffer gets a new empty one.

## Multi-membership

A buffer can carry many tags. No tag is the owner.

- "Exclusive to G" is derived: the tags are exactly `{G}`.
- `add` never removes. `move` names one destination and replaces every
  tag. `remove` drops one tag.
- Three places read tags: list sectioning, window fill, and
  `switch-to-buffer-group`. Layouts store buffer names, not tags.
- The one prompt in the system is `switch-to-buffer-group` with two or
  more tags. It always asks.

A group grows only while it is the destination of some frame, or by an
explicit `add`. A group shrinks only by `remove`, `move`, `kill-buffer`,
`dissolve`, or `kill`.

## Chats and agents

A chat is a buffer with tags like any other. There is no chat ownership
store and no primary chat.

At the start of a turn an agent reads one `context` value:

- files: the members of the chat's group (the destination of the frame
  that shows the chat; else the chat's tags, see Membership).
- focus: the current buffer of that frame.

Tools an agent calls to list, search, read, or open buffers use the same
three sections as the human's lists. The context is what the agent sees
first, not what it is forbidden. Group membership never grants a tool
permission.

## Persistence

`desktop.etf` stores, per group: ID, name, tags of its members, per-frame
layouts, and scratch content. Per frame: `destination` and `previous`.

Restore heals: it drops panes whose buffers are gone, deduplicates tags,
rejects a malformed layout, recreates a missing scratch buffer, and
isolates a failure to one group. Restore never resurrects a killed buffer.

Rename and restart never change a group's ID.

## The groups board

`groups` opens a list buffer with one row per group: name, member count,
modified count, and the frames that show it. Row verbs: switch, rename,
dissolve, kill, members. `members` opens the switcher on that group's
members with the selection model of Selection. Refreshing the board
changes no tag, layout, MRU, or destination.

## Architecture reserved for later

These are not in this specification. The design leaves room for them.

- **Transient layouts.** A frame holds a base layout and, optionally, one
  transient layout on top. Save-on-leave saves the base. Leaving the
  transient restores the base. A future `tile-all` grid is a transient
  layout.
- **Landing.** `switch G` may take an optional landing layout to show
  instead of the saved one, without saving it.
- **Narrow.** A hard scope on top of the soft sections is parked.

## Implementation contract

### Records

- Every group has one immutable opaque ID and one durable record.
- Names are unique after trimming and are mutable.
- A record survives with no members. `dissolve` and `kill` retire it.
- Code uses the ID for tags, MRU, layouts, and frame slots. Names are
  for display and completion.

### Tags

- A buffer stores a set of valid group IDs in a buffer-local.
- Membership derives from that buffer-local. No second roster is
  authoritative.
- Killing a buffer removes it from every group with no extra work.
- Adding a present tag and removing an absent tag are successful no-ops.

### Frame slots

- `destination` and `previous` are per-frame state. Only `switch`,
  `switch-last`, `new`, `dissolve`, and `kill` write them.
- A frame with no destination is the plain editor plus the project
  fallback.

### Layouts

- One saved layout per (group, frame). `switch` writes it on leave and
  reads it on enter.
- Restore validates every pane. A pane whose buffer is dead is dropped. A
  group with no valid pane shows its scratch buffer.
- One `switch` records one frame-local MRU entry.

## Acceptance list

Tests name commands, never keys. A test that needs a binding binds its own
dummy key to its own dummy command.

1. Creation joins with a destination set: file, jump, editor-made buffer,
   agent-made buffer.
2. Creation with no destination stays untagged.
3. Showing a live buffer changes no tag: switcher, `find-file`, jump.
4. `C-RET` semantics in the switcher: show plus add, on one buffer and on a
   selection.
5. `add`, `move`, `remove` on one buffer, on a selection, on a dired
   selection, on a path selection.
6. `new` with a selection seed, a current-buffer seed, and an empty seed.
7. `switch-to-buffer-group` with 0, 1, and many tags; the many case
   prompts.
8. `switch` saves the outgoing layout as it is and restores tree,
   buffers, point, scroll, and selected window.
9. A saved layout with a dead buffer restores without that pane.
10. Window fill order: group member, project file, delete window, scratch
    as last window, `other-buffer` with no context.
11. Three-section lists: all combinations of destination and project
    present or absent; filter across sections; project section follows
    the current buffer.
12. `dissolve` drops tags and keeps buffers; frames go to `previous`.
13. `kill` drops the tag on shared buffers, kills exclusive ones, honours
    modified protection, switches frames to the next group.
14. Scratch buffer refuses `kill-buffer`, `move`, `remove`; goes with
    `kill` and `dissolve`; persists content.
15. Per-frame destination and `previous`; two frames on one group with
    two layouts.
16. Persistence: groups, tags, layouts, scratch, frame slots survive a
    restart; malformed state isolates to one group.
17. Agent context: files and focus from the chat's frame, else from the
    chat's tags.
