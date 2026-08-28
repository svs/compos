# Groups

Groups make a large editor feel small again. A group collects the buffers,
layout, and conversations for one piece of work.

The central rule is:

> The visible layout determines the current group. A homogeneous layout has
> an implicit destination. A mixed layout requires an explicit choice.

This README starts with the user model. The implementation contract follows
after the workflows.

## The one-minute model

A buffer can belong to no groups, one group, or several groups. Membership means that the buffer is available when working in that group.

A frame has a derived value named `current-group`. The editor recalculates it whenever a displayed buffer changes.

- If the visible buffers share a group, `current-group` names it.
- If the visible buffers do not share a group, `current-group` is null.
- Transient interface buffers do not take part in this calculation.

A frame can pin this value. A pin keeps `current-group` stable while buffers
and windows change. It does not add foreign buffers to the pinned group.

The result is intentionally simple. A homogeneous frame has somewhere to put new work. A mixed frame does not guess.

Groups do not own files or projects. They are not security boundaries. They organize editor state for people and agents.

## User stories

Read each story as a path:

> **As a user** → **in this situation** → **I want this outcome** →
> **the editor behaves this way** → **I use this command**.

Some outcomes are automatic. In those cases the solution is a rule rather
than another command to remember.

### As a user working in a group

#### I want to switch to another buffer in this group

- Buffers in `current-group` appear first, in buffer MRU order.
- Foreign and ungrouped buffers remain available after them.
- `RET` shows the chosen buffer without changing any membership.
- **Command:** `group-switch-buffer` (`C-x b`).

#### I want to inspect a buffer from outside this group

- I choose the foreign buffer from the ordinary buffer switcher.
- Showing it does not add it to this group or remove it from another group.
- The editor recalculates `current-group` after the buffer is shown.
- **Command:** `group-switch-buffer` (`C-x b`, then `RET`).

#### I want to switch to the chosen buffer's group

- The editor restores that group's layout and then focuses the buffer.
- If the buffer belongs to several groups, I choose one.
- If the buffer is ungrouped, I can start a group with it.
- **Command:** `group-switch-buffer` (`C-x b`, then `C-RET`).

#### I want to switch to another group

- If all visible work belongs to `current-group`, that group is not offered as
  a destination. Other groups appear in group MRU order.
- If the display is mixed, the current buffer's groups appear first, followed
  by unrelated groups in group MRU order.
- Each group's marginalia lists its buffers with project-relative names and `~`.
- Accepting a group restores its last valid homogeneous layout.
- **Command:** `switch-to-group` (`C-x g`).

#### I want this buffer to be available in another group too

- I select one or more buffers before I run the command.
- If I select nothing, the command acts on the current buffer.
- The destination is added without removing their existing memberships.
- A successful add clears the selections.
- I remain in the current visible context.
- **Command:** `buffer-add-to-group`.

#### I want to move this buffer from here to another group

- I choose only the destination group.
- The destination replaces every existing membership.
- The buffer, file, text, point, modified state, and undo history survive.
- **Command:** `buffer-move-to-group`.

#### I want to remove this buffer from this group

- The selector opens for one or many memberships.
- `RET` toggles a pending removal without changing membership.
- I can select the membership again to keep it.
- `C-g` applies all pending removals and closes the selector.
- The buffer is not killed and its file is not changed.
- **Commands:** `buffer-remove-from-group` and `group-remove`.

#### I want a fresh empty group

- The group is created only after I accept a unique name.
- The editor enters its generated default layout.
- **Command:** `group-new`.

#### I want to manage this group

- Rename it without changing its identity: `group-rename`.
- Dissolve it without killing its buffers: `group-dissolve`.
- Kill its buffers under the normal modified-buffer protections: `group-kill`.
- Inspect and manage all groups: `groups`.

### As a user working in a buffer

#### I want this buffer to start a new group

- If it is ungrouped, the action says **Start a group with this buffer**.
- If it belongs to `current-group`, the group switcher can instead offer
  **Move this buffer into a new group**.
- Eligible attached work companions follow the buffer-family policy.
- **Command:** `group-new-with-buffer`.

#### I want to change this buffer's memberships explicitly

- Add another membership: `buffer-add-to-group`.
- Replace all memberships with one destination: `buffer-move-to-group`.
- Remove one named membership: `buffer-remove-from-group`.
- These commands work even when `current-group` is null.

#### I want to create a new ordinary buffer

- In a homogeneous display, the buffer joins `current-group` before it is
  shown.
- In a mixed display, it starts ungrouped because the editor cannot infer a
  destination.
- The shared creation hook applies this rule to files, Dired, and other new
  work buffers.
- **Command:** `buffer-new`.

### As a user working with several visible windows

#### I want the visible arrangement to become a group

- Every eligible visible work buffer joins the new group.
- The current window tree becomes its first remembered layout.
- Existing memberships remain unless I explicitly move the buffers.
- **Command:** `group-new-from-visible`.

#### I want the current group to follow what is visible

- After a displayed work buffer changes, the editor finds the groups shared by
  all visible work buffers.
- If they share a group, that group becomes `current-group`.
- If they share none, `current-group` becomes null.
- **Solution:** automatic homogeneity recalculation. No command captures or
  clears `current-group` separately.

#### I want this frame to stay in its current group

- Pinning keeps `current-group` stable when a foreign buffer appears or dies.
- Killing a visible buffer chooses a replacement from the pinned group.
- Existing foreign buffers do not gain membership in the pinned group.
- New buffers still join the pinned group through the normal creation rule.
- An explicit group switch moves the pin to the selected group.
- Every rendered name for the pinned group shows the pin icon ``.
- Run the command again to release the pin and derive the visible group.
- **Command:** `group-pin` (`C-x C-g p`).

#### I want the layout remembered when it represents one group

- Homogeneous window changes update that group's remembered layout.
- Mixed layouts, previews, popups, and covering surfaces do not overwrite it.
- **Solution:** automatic homogeneous-layout observation.

### As a user working without a current group

#### I want to return to one of the current buffer's groups

- The current buffer's groups appear first, in group MRU order.
- Accepting one restores its complete layout.
- **Command:** `switch-to-group` (`C-x g`).

#### I want the current buffer to become a new context

- An ungrouped buffer offers **Start a group with this buffer**.
- A grouped buffer keeps its memberships unless I explicitly choose a move.
- **Command:** `group-new-with-buffer`.

#### I want to choose any other group

- Groups unrelated to the current buffer remain available after its own
  groups, in group MRU order.
- **Command:** `switch-to-group` (`C-x g`).

### As a user opening a file

#### I want the file in the context in front of me

- A newly visited file joins `current-group` when one exists.
- Dired and project file commands prefer the source buffer's explicit group.
- `RET` in Dired uses the Dired buffer's group.
- `C-RET` in Dired uses the frame group, then falls back to the Dired group.
- If the file already has a live buffer, showing it does not silently change
  its memberships.
- With no current group, a new file buffer starts ungrouped.
- **Command:** `find-file` (`C-x C-f`).

#### I want the file to start a new group

- The file and group are created or visited only after their prompts succeed.
- The file buffer joins the new group, the group is entered, and the file is
  focused.
- An already live file keeps its other memberships.
- **Command:** `find-file-in-new-group` (`C-x C-g f`).

### As a user working with a group's conversations

#### I want to open or create the primary group chat

- A group may contain zero, one, or many chats, but has at most one primary
  chat.
- Chat ownership does not change work-buffer membership.
- **Command:** `group-chat`.

#### I want to move between work and its companion chat

- Toggle between them: `chat-companion`.
- Ask the companion without leaving the work buffer: `chat-companion-ask`.

### As a user returning later or using several frames

#### I want groups to survive restart

- Stable identity, names, memberships, chats, and valid layouts persist.
- Missing buffers and invalid layouts heal instead of blocking entry.
- **Solution:** automatic persistence and recovery.

#### I want each frame to keep its own context

- Each frame derives `current-group` from its own visible buffers.
- Group MRU and remembered layouts remain frame-local.
- **Solution:** automatic frame-local state.

### Safety shared by every story

- Showing or switching buffers never changes membership implicitly.
- Switching groups never changes membership.
- Adding never removes another membership.
- Move names one destination and replaces every existing membership.
- Removing membership never kills a buffer or changes a file.
- Cancellation restores previews and changes no durable state.
- Partial multi-buffer operations report what changed, what did not, and why.

## Three things that must stay distinct

### What is visible

Windows display buffers. Showing a buffer does not edit its memberships.

The display can change `current-group` because that value is derived from the visible buffers. This is a recalculation, not a membership change.

### Where a buffer is available

A work buffer carries a set of group IDs. Adding or removing one ID changes where that buffer is available.

The same live buffer can appear in several groups. Its text, point, modified
state, and undo history remain shared.

### Which group is current

`current-group` describes the visible frame. It is not a second membership
store and it is not a permanent promise about future windows.

Entering a group restores a homogeneous layout. Showing foreign work can make the frame mixed and clear `current-group`.

## The vocabulary

Use these verbs consistently in commands, prompts, and documentation.

| Verb | Meaning | Changes membership | Changes the visible context |
|---|---|---:|---:|
| **show** | Display a buffer in one window. | No | Maybe, through recalculation |
| **switch group** | Restore another group's layout. | No | Yes |
| **add** | Make a buffer available in another group. | Yes | No |
| **move** | Replace all memberships with one destination. | Yes | No |
| **remove** | Remove one named membership. | Yes | No |
| **new** | Create a group record. | Only when a seed is supplied | Yes when accepted |

Use **add**, **move**, and **remove** for membership changes.

## Everyday workflow

### Work inside one group

When every visible work buffer belongs to one group, `current-group` is set.

- `C-x b` puts buffers from that group first.
- New work buffers join that group.
- Newly visited files join that group.
- The group's remembered layout can update.




### Look at something from outside the group

Use `C-x b` and show the foreign buffer. Showing it never changes membership.

If the resulting layout has no common group, `current-group` becomes null.
This mixed layout is a useful inspection state, not an error.

Press `C-x g` when you want to turn that inspection into a context change. The
current buffer's groups appear before unrelated groups.

### Return to focused work

Press `C-x g` and accept a group. The editor restores that group's last valid
homogeneous layout.

When the frame is already homogeneous, other groups appear in MRU order. The current group is not offered as a destination.

### Start new work from the current buffer

`C-x g` always makes new-context creation discoverable.

- If the current buffer belongs to `current-group`, offer **Move this buffer
  into a new group**.
- Otherwise, offer **Start a new group with this buffer**.

The move form adds the destination first. It then removes only the current
group membership. Other memberships remain intact.

### Start new work from the visible layout

Use **Start a group from visible buffers** when the arrangement itself is the
new context.

The editor adds every eligible visible work buffer to the new group. It saves
the current layout as the new group's first layout. Existing memberships stay
unless the user explicitly chooses a move action.

## Buffer switching: `C-x b`

`C-x b` answers one question: “Which buffer should this window show?”

It does not add, remove, or move membership.

### Candidate order

When `current-group` is set:

1. Current-group buffers in buffer MRU order.
2. Foreign and ungrouped buffers in buffer MRU order.

When `current-group` is null, all buffers use buffer MRU order. Rows show their
memberships or **ungrouped** status.

### Accepting a buffer

`RET` displays the chosen buffer in the selected window. The editor then
recalculates `current-group` from the resulting visible layout.

`C-RET` switches to the chosen buffer's group. It restores that group's layout
and focuses the chosen buffer after restore.

| Candidate | `C-RET` result |
|---|---|
| Buffer in one group | Switch to that group and focus the buffer. |
| Buffer in several groups | Choose one of its groups, then switch and focus. |
| Ungrouped buffer | Offer **Start a new group with this buffer**. |

Candidate actions can offer membership changes, but those actions must name
their effect. Examples are **Add to group** and **Move to group**.

Cancellation restores any previewed buffer, point, scroll, selected window,
and layout.

## Group navigation: `C-x g`

`C-x g` answers: “Which group should these windows become?”

Accepting an ordinary group row never changes membership. It restores that
group and makes the resulting layout homogeneous.

### Candidate order

The order depends on the visible state.

| Visible state | Candidate order |
|---|---|
| Homogeneous group | Other groups by group MRU, then the new-group action. |
| Mixed, current buffer has groups | Current buffer's groups by MRU, the new-group action, then remaining groups by MRU. |
| Mixed, current buffer is ungrouped | **Start a new group with this buffer**, then groups by MRU. |
| No eligible current work buffer | Groups by MRU, then **Start an empty group**. |

Groups without an MRU entry trail in creation order. A dissolved group never
appears.

### Actions on a group row

The default action is always **Switch to this group**.

When the current buffer is eligible, the row can also offer:

- **Add this buffer to the group**.
- **Move this buffer to the group**.
- **Show this group's members**.

These are explicit candidate actions. `RET` on the group row remains a pure
context switch.

### The new-group action

The action label states whether a source membership will be removed.

| State | Label | Result |
|---|---|---|
| Current buffer is a member of `current-group` | Move this buffer into a new group | Add destination, remove `current-group`, enter destination. |
| Current buffer is foreign or `current-group` is null | Start a new group with this buffer | Add destination, preserve existing memberships, enter destination. |
| No eligible current buffer | Start an empty group | Create and enter an empty group. |

Creation happens only after the name is accepted. Cancellation creates no
record and changes no membership.

## New buffers and files

New work uses `current-group` directly. A shared creation hook applies the
rule, so commands do not repeat the homogeneity calculation.

| State at creation | Result |
|---|---|
| `current-group` is set | Create the buffer as a member of that group. |
| `current-group` is null | Create the buffer ungrouped. |
| An explicit new-group command runs | Create the buffer in the new group and enter it. |

The command assigns membership before it displays a newly created buffer.
This keeps a homogeneous frame homogeneous.

Showing an already live buffer is different. Its existing memberships remain
unchanged, and the visible frame recalculates normally.

### Find a file here: `C-x C-f`

If visiting the file creates a new editor buffer, that buffer joins
`current-group` when one exists. With no `current-group`, it starts ungrouped.

If the file already has a live buffer, `C-x C-f` only shows it. The command
does not add another membership silently.

A failed or cancelled visit changes no membership.

### Find a file in a new group: `C-x C-g f`

`C-x C-g f` is the direct counterpart to `C-x C-f`.

1. Choose a file.
2. Name the new group.
3. Create the group only after both choices succeed.
4. Add the file buffer and eligible attached work companions.
5. Enter the new group and focus the file.

The group-name prompt can suggest the project name or file name. A duplicate
name must be rejected or explicitly entered as an existing group.

An already live file keeps its other memberships. This command does not
silently remove a source membership.

## Buffer families and companions

Some work buffers have explicitly attached work buffers. A document scratch
buffer is the main example. Together they form a buffer family.

A family relation must be explicit and inspectable. Sharing a window, project,
mode, or group does not make two buffers a family.

Starting or moving a context from one buffer includes its eligible family:

- Add every live family member to the destination first.
- Remove every other membership from each family member.
- Report the complete family before confirmation when it contains several
  buffers.

Group chats are not work-buffer companions for this operation. A chat belongs
to one group and stays with that group. The destination can create or select
its own chat.

Transient previews, minibuffers, boards, and infrastructure buffers never join
a family automatically.

## Membership operations

### Add a buffer to a group

`buffer-add-to-group` makes selected buffers available in the destination. It
keeps all existing memberships and does not enter the destination. With no
selection, it acts on the current buffer.

Running it twice is a successful no-op.

### Move a buffer to a group

`buffer-move-to-group` requires one destination.

The operation resolves the destination before it changes membership. A failed
destination leaves every existing membership untouched.

### Remove a buffer from a group

`buffer-remove-from-group` and `group-remove` open the same staged selector.
They never kill the buffer or change a file.

When a removed buffer remains visible, the editor recalculates
`current-group`. A group command may replace it with another member when the
operation promises to preserve a homogeneous layout.

## Command naming

Canonical commands are named after the object they change.

### Group commands

| Command | Meaning |
|---|---|
| `switch-to-group` | Restore another group. |
| `group-new` | Create and enter an empty group. |
| `group-new-with-buffer` | Create and enter a group with the current buffer family. |
| `group-new-from-visible` | Create and enter a group from eligible visible buffers. |
| `group-rename` | Rename a group without changing identity. |
| `group-dissolve` | Remove a group record and its memberships without killing work. |
| `group-kill` | Kill members under the standard buffer-kill policy. |
| `group-chat` | Open or create the group's primary chat. |
| `group-pin` | Keep the frame in one group until the command releases it. |

### Buffer commands

| Command | Meaning |
|---|---|
| `buffer-add-to-group` | Add one or more memberships. |
| `buffer-move-to-group` | Replace all memberships with one destination. |
| `buffer-remove-from-group` | Toggle pending removals; `C-g` applies and exits. |
| `buffer-new` | Create work in `current-group`, or ungrouped when it is null. |

Compatibility aliases can retain `group-switch` during migration.

## Projects

A project finds files and supplies useful annotations. It is not a group.

- One group can span several projects.
- One project can contribute buffers to several groups.
- Entering a project does not create a group.
- A project name can be the suggested name for a new group.
- Project membership never grants group membership by itself.

## Chats and agents

A group can contain no chats, one chat, or several chats. Each chat belongs to
at most one group. One chat can be the primary chat.

`group-chat` opens the primary chat. If none exists, it selects another chat
in the group or creates one.

Each agent turn reads current group membership. Membership changes affect
future turns. Running work remains attached to its stable group ID.

Group membership never grants tool permission.

## Layouts

A group remembers the most recent valid homogeneous layout for each frame.
The snapshot includes splits, ratios, buffers, point, and scroll state.

### When a layout can be saved

The editor can save a group layout only when `current-group` is set. Mixed
layouts do not belong to any one group and must not overwrite a snapshot.

Transient prompts and covering surfaces do not become remembered work.

### Entering a group

Group entry performs one context operation:

1. Save the outgoing layout when it has a valid `current-group`.
2. Restore the destination's remembered layout.
3. Heal dead or missing buffers.
4. Replace or remove panes whose buffers are no longer members.
5. Recalculate `current-group` from the restored display.
6. Record one group MRU entry and one layout-undo entry.

If no valid layout exists, the editor builds a default layout from recent
members and the group's companion policy.

### Default layout

1. Use the most recent work member as the main pane.
2. Show it full-frame when it is the only work member.
3. Show the primary chat beside work only when companion noise is `loud`.
4. Otherwise use another recent work member when a second pane is useful.
5. Show the primary chat full-frame when no work member exists.
6. Use a neutral fallback when the group is empty.

## Companion noise

| Value | Default-layout behavior |
|---|---|
| `off` | Do not show a chat. |
| `quiet` | Keep the primary chat available but hidden. |
| `loud` | Show the primary chat beside work when possible. |

Changing noise does not destroy a manual layout. It affects the next default
layout construction.

## The groups board

The board manages durable groups. It does not replace `C-x g` for quick
navigation.

Each row shows:

- Group name and color.
- Live work-member count.
- Primary-chat and companion-noise state.
- Recent members.
- Modified-work status.
- Optional purpose metadata.

The board supports switch, rename, describe, noise, dissolve, kill, and
membership actions. Marked actions use compatible marked rows as one set.

Expanding or refreshing the board never changes membership, group MRU,
layouts, or `current-group`.

## Rename, dissolve, and kill

### Rename

Rename changes only the display name. The stable group ID, memberships,
layouts, chats, agents, and MRU identity remain unchanged.

### Dissolve

Dissolve removes the group ID from live work members and clears chat ownership.
It retires the group record. Buffers and files survive.

### Kill

Kill uses the standard buffer-kill policy for each member. Modified work keeps
its normal protections. Partial completion reports every survivor.

## Persistence and multiple frames

Group records, names, memberships, chats, layouts, and frame state survive a
restart. Rendered rows and live tasks do not become identity state.

Each frame calculates its own `current-group` from its own visible buffers.
Two frames can display the same group with independent layouts.

Work-buffer memberships are shared because the buffers are shared. A
membership change becomes visible to every frame on its next calculation.

Group identity uses an opaque ID. Rename and restart never change that ID.

## What happens in every important case

| Case | Result |
|---|---|
| All visible work shares one group | Set `current-group` to that group. |
| Visible work has no common group | Set `current-group` to null. |
| Visible work shares several groups | Keep the existing common group; otherwise choose the most recent common group. |
| Only transient interface buffers are visible | Ignore them for homogeneity. |
| New buffer with `current-group` | Add it to that group before display. |
| New buffer without `current-group` | Create it ungrouped. |
| Existing foreign buffer is shown | Preserve membership and recalculate the frame. |
| Ungrouped buffer is current in a mixed frame | Put **Start a new group with this buffer** first in `C-x g`. |
| Grouped foreign buffer is current in a mixed frame | Put its groups first in `C-x g`. |
| Current buffer belongs to several groups | Order its destination groups by group MRU. |
| Current member starts a new group | Replace its memberships with the new group, then enter it. |
| Foreign member starts a new group | Add the new group and preserve all existing memberships. |
| Current group has no other work after a move | Keep the group record and chats. |
| A visible membership is removed | Recalculate `current-group`; replace the buffer only when the command promises homogeneous repair. |
| A group has no live members | Keep its record until explicit dissolve, kill, or cleanup. |
| A saved layout names dead buffers | Replace or collapse invalid panes. |
| No saved pane names a live member | Build and save the default layout. |
| A group name matches a buffer name | Keep typed group and buffer candidates distinct. |
| A file disappears from disk | Keep membership and report the file error separately. |
| Creation is cancelled | Create no group and change no membership. |
| A move fails while adding the destination | Remove no source membership. |
| A preview candidate dies | Cancel to a live fallback. |
| Two frames save one group | The last completed valid snapshot wins. |
| Two users of one process create the same name | Produce one group or report a conflict. |

## Implementation contract

The friendly rules above are normative. This section states the required
state and transaction boundaries.

### Identity and records

- Every group has one immutable opaque ID.
- Every live group has one durable record.
- Names are unique after trimming and remain mutable.
- A record survives when the group has no live members.
- Records store name, metadata, layouts, noise, color, and primary chat ID.
- Code uses the group ID for membership, MRU, layouts, agents, and frame state.

### Work membership

- A work buffer stores a unique set of zero or more valid group IDs.
- Membership derives from buffer-local state. No second roster is authoritative.
- Killing a work buffer removes it from derived membership automatically.
- Adding an existing membership is a successful no-op.
- Removing an absent membership is a successful no-op.

### Chat ownership

- A chat stores zero or one owning group ID.
- A chat cannot be shared across groups.
- Killing a chat does not kill the group record or work members.
- Losing the primary chat selects another group chat or clears the primary.

### Homogeneity calculation

The calculation considers visible group-bearing buffers and ignores declared
transient interface buffers.

1. Find the intersection of valid memberships across eligible visible buffers.
2. Set `current-group` to null when the intersection is empty.
3. Use the previous `current-group` when it remains in the intersection.
4. Otherwise use the most recent group in the intersection.
5. Refresh the frame's group presentation after the result changes.

### Atomic operations

- Group creation writes the record before adding membership.
- Move resolves every destination before replacing any membership.
- A failed destination preserves all existing memberships.
- Cancellation before acceptance changes no record, membership, layout, or MRU.
- Membership operations preserve text, files, modified state, point, and undo.

### Layout safety

- Only a frame with a non-null `current-group` can save a group snapshot.
- A mixed display never overwrites a group snapshot.
- Preview never saves a snapshot or updates durable MRU.
- Restore replaces or removes every pane outside the destination group.
- Restore never resurrects a killed buffer.
- One group switch creates one group-MRU entry and one layout-undo entry.

### Recovery

Restore must tolerate records before buffers and buffers before records. It
must deduplicate memberships, reject malformed layouts, normalize unknown
noise to `quiet`, and isolate failures to one group.

Legacy name-based membership migrates once to stable IDs. Repeating migration
must be safe.

## Acceptance checklist

At minimum, tests cover:

1. Homogeneous, mixed, ungrouped, and multiply shared visible layouts.
2. Recalculation after every buffer-display and membership change.
3. New-buffer placement with set and null `current-group`, including direct,
   file, and Dired creation paths.
4. `C-x C-f` for new, live, failed, and cancelled file visits.
5. `C-x C-g f` for new files, live files, duplicate names, and cancellation.
6. `C-x b` ordering, foreign display, preview, and cancellation.
7. `RET` display and `C-RET` context switching for one, many, and no groups.
8. `C-x g` ordering for homogeneous, mixed, ungrouped, and multi-group buffers.
9. Pure group-row acceptance versus explicit add and move actions.
10. New groups from empty state, one buffer family, and visible buffers.
11. Add, move, and remove for one buffer.
12. Failed moves with no membership change.
13. Buffer-family operations with missing and incompatible companions.
14. Layout save, restore, healing, default construction, and undo.
15. Rename, dissolve, kill, modified work, and partial completion.
16. Zero, one, and many chats, including primary-chat replacement.
17. Restart, legacy migration, malformed state, and two frames.

Key-driven tests dispatch the real keys through the editor key dispatcher.
Policy tests inspect memberships, records, frame state, layouts, MRU, and
buffer state directly.

## Final invariants

1. Visible homogeneity is the only source of `current-group`.
2. Showing a buffer never edits membership.
3. A group switch never edits membership.
4. Add never removes a membership.
5. Move names one destination and replaces existing memberships.
6. Remove never kills a buffer or file.
7. New work joins `current-group` only when that value is set.
8. Mixed work never receives an inferred destination.
9. Mixed layouts never overwrite remembered group layouts.
10. Chats remain single-group-owned.
11. Group identity survives rename and restart.
12. Cancellation leaves durable state unchanged.
