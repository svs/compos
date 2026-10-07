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

- A **buffer** is global. It exists once. It carries `groups`: the one group it is in, or none. A buffer is in one group at a time.
- A **group** has an opaque ID, a name, one saved layout per frame that has shown it, and one scratch buffer of its own. The members of a group are the buffers whose `groups` include it.
- A **frame** has a `destination` slot: a group ID or none. It also has a `previous` slot for the toggle.
- A **project** is a root directory derived from a file path. A project is not a group. It has no members, no layout, no ID, and no verbs. The editor uses it as a fallback in two places (see Projects).
- A **selection** is a set of buffers or paths marked by the user (see Selection).

### The three rules

1. A buffer that is **created** while the frame has an explicit destination joins that group.
2. Shoving it or any selection of buffers / visible buffers to another group is easy
3. When in a group (current_group is set), most actions target the group. Buffers from outside the group may not join by default.

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

### As a user starting with a clean slate

These are the ways I can create my first group when no group exists yet:

#### I want to create an empty new group
- I want to say `group-new`, give it a name and be in a new group with its chat.
- Any files I open should open in this group.
- I can pull other buffers to this group: `group-add`, or `C-t` in the switcher.

#### I want to start a group by opening a buffer/file
- I open a file, chat, or other useful buffer.
- I choose to make it the start of a new group and give the group a unique name.
- The current buffer becomes the first member and the new group becomes current.
- The editor keeps me in the buffer I started from.

Test: `group-new-creates-and-enters-an-empty-work-context`
#### I want to start from a set of buffers

#### selected buffers
  - I select several buffers that belong to the same task.
- I create a new group and give it a unique name.
- All selected buffers become members of the new group.
- The group opens on the buffer that I used to begin the action.
#### visible buffers
- I want to move all visible buffers to a new group.
- I want to add all visible buffers to a new group.

#### 
I want to start from a project or directory

- I choose a project or directory instead of selecting buffers one by one.
- The editor offers the relevant files or buffers as the initial membership.
- I confirm the selection and give the group a unique name.
- The new group opens with a useful starting buffer.

#### I want a completely empty group

- I create a named group without choosing a starting buffer, file, or project.
- The group is created with no members.
- I can add the first buffer later, and that buffer becomes the useful place to start.

#### I want the editor to help me create my first group

- When I have no current group, the editor makes the create-group paths easy to discover.
- It does not silently assign unrelated buffers to the group.
- After creation, the group is current and its membership and name are visible.
- If I cancel naming or selection, no partial or unnamed group remains.

### As a user working in a group

#### I want to switch to another buffer in this group

- The switcher lists this group's buffers first, in MRU order.
- The project's other open files follow, then everything else.
- `RET` shows the buffer and changes no membership.
- `C-u C-x b` shows the chosen buffer in another window and selects it.
- **Command:** `switch-to-buffer`.

#### I want to look at a buffer from outside this group

- I pick it from the project or rest section.
- Showing it adds it to this group (see "A buffer opens in the current group"). A chat of another group does not join.
- When I kill it, the window shows the next buffer of this group.
- **Command:** `switch-to-buffer`, then `RET`.

#### I want that outside buffer in this group

- A plain `RET` already adds it, and the buffer leaves its old group.
- `C-RET` does the opposite: it goes to the buffer's own group (`buffer-context-switch!`).
- A mistake is one `remove-group-from-buffer` away.
- **Command:** `switch-to-buffer`, then `RET`.

#### I want to open a file and have it here

- A file with no buffer joins the destination group when I visit it.
- A file with a live buffer is shown and joins the destination group too.
- **Solution:** creation joins, and a display joins. No command.

#### I want to jump to a definition and have it here

- The jump opens a buffer. The buffer joins the destination group.
- If the target is a live buffer, the jump shows it, and it joins the destination group.
- **Solution:** the same creation rule. No command.

#### I want to clean junk out of this group

- I mark rows in the switcher and run `remove`.
- With no marks, `remove` acts on the current buffer.
- Buffers stay open. Only the membership goes.
- **Commands:** `buffer-select`, then `remove`.

#### I want to switch to another group

- Every group appears, in this frame's MRU order; the group you stand in comes last.
- Moving the highlight previews the whole group: the arrangement you would land in.
- Accepting a group saves this layout and restores that group's layout.
- **Command:** `switch`.

#### I want to go back to the group I just left

- One command flips to the previous group of this frame.
- **Command:** `switch-last`.

#### I want this buffer in another group too

- The buffer joins that group and leaves this one: a buffer is in one group at a time.
- I remain in this group.
- **Command:** `group-add`.

#### I want this buffer out of here and into another group

- All existing groups go. The destination is the only group.
- Text, point, modified state, and undo survive.
- The frame enters the destination, and the destination shows what moved.
- **Command:** `move`.

#### I want this buffer in the group I am already looking at

- The screen is already the destination's own arrangement when every pane
  shows a member of it, or a buffer that is joining it.
- The move then changes membership alone. No pane moves, no pane closes,
  and the destination keeps the arrangement on screen as its own.
- A pane that carries no context - a popup, a special buffer, a buffer no
  group holds - does not stop this. A pane of another group does.
- **Command:** `move`.

#### I want a fresh, empty group

- The group is created after I accept a unique name.
- `new` never takes the current buffer. With no selection the group starts empty.
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
- No group, in a project: the frame enters a group named for the project root. The project's other ungrouped open buffers join it.
- No group and no project: I name a new group and the buffer seeds it.
- **Command:** `C-RET` in the switcher (`buffer-context-switch!`).

#### I want to change this buffer's groups by hand

- Put it in a group: `group-add` or `group-move`. Both replace its old group. Drop it: `remove-group-from-buffer`.
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

- **Command:** `new`, or `C-RET` in the switcher (`buffer-context-switch!`) on an ungrouped buffer.

#### I want to enter a group

- Groups appear in MRU order.
- **Command:** `switch`.

### As a user working with chats and agents

#### I want a chat for this group

- A chat created in the group joins the group like any buffer.
- The agent's context is the group's members and the current buffer.
- **Solution:** a chat is a buffer. No command.

#### I want the files an agent opens to land here

- A file that an agent opens or edits joins the chat's destination group.
- Every buffer that an agent creates is context-only: a file or a work buffer, in a group or not.
- A context-only buffer keeps text, undo, parser, modified, and save state.
- Context-only buffers stay out of user switchers, the group walk, window filling, and saved layouts.
- The group and its agents can still read, edit, save, and remove these buffers.
- An agent does not put a file or a context-only buffer in the selected window.
  `display-buffer`, `switch-to-buffer!`, and `visit` refuse, also inside `with-frame-windows`.
- When the user asks to see a buffer, the agent shows it in the other window
  (`display-buffer-other-window!`). Who created the buffer does not matter.
- A buffer that a window shows is promoted. A user visit also promotes it and keeps all unsaved state.
- **Solution:** the creation rule and the context-only buffer state. No command.

### As a user returning later or using several frames

#### I want groups to survive a restart

- Names, memberships, layouts, scratch content, and frame slots persist.
- A missing buffer or a malformed layout heals on restore.
- **Solution:** persistence and recovery. No command.

#### I want each frame to keep its own group

- Each frame has its own destination and previous slots.
- Two frames can show two groups, or one group with two layouts.
- **Solution:** per-frame slots. No command.

#### I want a window to show only the work I do in it

- The group a window founds belongs to that window. Another window's rail, tabs and switcher never name it.
- The work of another window is one marked section at the end of the switcher, and picking it goes to that window.
- A window that closes leaves its groups free, and the next window to enter one takes it.
- **Solution:** an owner frame on the group record. No command.

### Safety shared by every story

- Showing a buffer can add it to the current group (see "A buffer opens in the current group"). It never removes a group.
- Switching groups never changes a buffer's groups.
- `group-add` and `group-move` name one destination and replace the old group. `remove-group-from-buffer` drops the group.
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

### Display joins the current group

Showing a buffer that already exists puts it in the current group. This covers `RET` in the switcher, `find-file` on a file with a live buffer, and a jump that lands in a live buffer. See "A buffer opens in the current group" for the rule and its exceptions.

### Agents without a frame

A chat that is not shown on any frame uses the chat's own groups. With several groups, the most recently added one applies. With no group, the buffers the agent creates stay ungrouped.

### No destination

When the frame has no destination, nothing joins anything. Lists and window fill use the project fallback (see Projects).

## Verbs

Every verb that takes buffers acts on the selection. With no selection it acts on the current buffer. A path in the selection is visited first.

| Verb | Effect |
|---|---|
| `group-add` G | Put the selection in G. Each buffer leaves the group it was in. Create G when the name is new. Adding a buffer that is in G is a no-op. |
| `group-move` G | Remove the selection from every group, then add it to G. |
| `remove-buffers-from-group` G | Remove the chosen buffers from G. They stay open. |
| `remove-group-from-buffer` B | Remove the chosen groups from B's family. B stays open. |
| `group-switch` G | Save the frame's layout into the outgoing group. Set `previous`. Set `destination` to G. Restore G's layout on this frame. |
| `group-switch-last` | Swap `destination` and `previous`. |
| `buffer-context-switch!` | Read the current buffer's group. None, in a project: enter a group named for the root, and take the project's ungrouped open buffers along. None, no project: prompt for a name and start a group with the buffer. One: switch to it. |
| `group-new` G | Create G with its chat buffer. Add the seed. Save a layout built from the seed. Switch to G. |
| `group-dissolve` G | When G has a live parent (see "The overview"): every member joins the parent, then leaves G, and a frame on G switches to the parent. Else: remove every member from G. Remove the scratch buffer and the record. Frames on G go to `previous`, else none. |
| `group-kill` G | For each member: when it is in another group, remove it from G; else kill it under the normal modified-buffer protection. Then dissolve G. A frame on G follows the buffer its window fell to into that buffer's group, with the group's layout; a buffer in no group leaves the frame in none. `group-after-kill` is `follow` (this) or `stay`. The kill runs `group-kill-hook` last, with `*group-killed*` = `(ID NAME STOOD?)`. |
| `group-rename` G NAME | Change the name. The ID, members, layouts, and MRU do not change. |
| `group-revive` G | Make a killed G again from the graveyard: the record, its meta, layout, noise, chat id, and color. Every member that still exists comes back: a buffer that is open joins; a file that exists on disk is visited into G. A member with neither is missing; the revival says how many. Then switch to G. |

### Command names

One command per verb. The name says which way the verb runs, so `remove-buffers-from-group` and `remove-group-from-buffer` are two commands, not one with an argument. A prefix is not what holds the family together: every command in this file carries the `groups` package and namespace in the catalog, so apropos finds them whatever they are called. A verb that acts on a group reads the row or the marks when it runs in the groups board, and the frame's group elsewhere. No other command changes membership.

| Verb | Command | Stock key |
|---|---|---|
| `add` | `group-add` | `C-c g`, `C-x C-g a`; `C-t` in the switcher; `G` in ibuffer |
| `move` | `group-move` | `C-x C-g m` |
| `remove-buffers` | `remove-buffers-from-group` | `M-x` |
| `remove-group` | `remove-group-from-buffer` | `C-x C-g r` |
| `switch` | `group-switch` | `C-x g`; `RET` in the board |
| `switch-last` | `group-switch-last` | `C-x C-g C-g` |
| `switch-to-buffer-group` | `buffer-context-switch!` | `C-RET` in the switcher |
| `new` | `group-new` | `C-x C-g n`; `C-c C-n` in the group switcher |
| `dissolve` | `group-dissolve` | `x` in the board |
| `kill` | `group-kill` | `K` in the board |
| `rename` | `group-rename` | `r` in the board |
| `revive` | `group-revive` | `M-x` |
| `groups` | `groups` | `C-x C-g l` |
| `members` | `group-members` | `C-x C-g b`; `b` in the board |
| `buffer-select` | `buffer-select`; `SPC` marks in every list | |

The `group-add` prompt names a default: the group the frame stands in, else the group it last stood in. A bare `RET` joins it; a typed name joins that group or founds it; the `New group` row founds one without entering it.

### Kill, follow, revive

A kill is a scene change, not a window repair. The frame leaves G before the members die, so the window falls to the next buffer as any kill does, and the kill repair makes no chat for a group with seconds to live. Then `group-kill-hook` runs, with `*group-killed*` = `(ID NAME STOOD?)`. The default handler, `group-kill-follow!`, follows the buffer the window fell to into that buffer's group and restores the group's layout. `group-after-kill` turns it off (`stay`): the window still falls to the next buffer, and the frame derives its group from what it shows, but no layout is restored. An ungrouped buffer is not a second-class landing: the frame stands in no group and shows it.

The kill buries a tombstone: the name, the record's fields, and each member's name and file. The graveyard keeps the last twenty tombstones and persists with the desktop. `group-revive` (`M-x`) completes over them, newest first, and shows each one's members. A name that an open group already has is refused.

`group-switch` prompts with one container card per group, every group the editor holds. The group you stand in is a card like the others: it goes last in its section and never leads, so the default an empty `RET` takes is still a switch. A card says the group's name and how many buffers it holds. It shows no member chips.

The prompt previews the WHOLE group, never one buffer of it. The preview draws the group in the frame: the layout the group saved, else the arrangement arrival would build for it. It draws in every shape `group-switch-style` takes - `"modal"` (the default, a centered panel with the frame around it), `"popup"` (an overlay on the bottom edge), or `"minibuffer"` (the bottom rows) - because a prompt previews into the frame whatever shape it wears, the way the buffer switcher does. The modal's facts panel says what the group holds and the shape it opens in. It lists no members. Pseudo groups (`Last chats`, the `mode:` groups) come after the real groups; an empty one is left out. The preview waits for the highlight to rest (`group-switch-peek-ms`, 120 ms) before it draws, so holding `C-n` moves through the list without a draw per row. A look is not an arrival: it writes no winner entry, moves no MRU, and leaves the frame's own group alone, and the prompt puts the whole arrangement you came from back when it closes.

### The seed of `new`

- A selection is marked: the seed is the selection.
- No selection: the seed is empty.
- The seed spends its marks. A switcher or ibuffer mark dies with its list, but `buffer-select` writes the mark on the buffer, so `new` clears it the way `add` does. An unspent mark would found the next group too.

`C-RET` in the switcher (`buffer-context-switch!`) on an ungrouped buffer still starts a group with that buffer as the seed.

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

The buffer switcher shows three sections. Each section is in MRU order. An empty section and its separator are omitted. Context-only buffers do not appear.

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

In the switcher, `RET` shows the buffer and puts it in the current group. `C-RET` goes to the buffer's own group (`buffer-context-switch!`). `C-t` puts the selection in a group. The same verbs apply to every buffer list.

`ibuffer` is a buffer management list. Context-only buffers do not appear until a user visits them. The current group uses the `in this group` heading. Each other group uses its group name. Other groups sort by name. Ungrouped buffers come last. Empty sections omit their headings. A buffer with many memberships appears once. The current group wins, then the first group by name wins. Rows inside each section sort by buffer name. The order is fetched on open and on `g`. A mark, a flag, or a narrowing redraws the rows the table has, so a row never moves under the cursor.

## Projects

A project is the root directory of a file. The editor derives it from the path. A project acts in two places and nowhere else:

1. The middle section of the buffer switcher.
2. Window fill after `kill-buffer` when the frame has no destination.

Visiting a file never changes the destination. A group made from files inside a project is a plain group; its buffers are in the group and also fall under the root.

## Windows and switching

### Restore

`switch G` restores, per frame: the window tree, the buffer in each window, point and scroll per window, and the selected window. A group with no layout on this frame shows its scratch buffer in one window.

A group is sealed: a restored pane shows a member of G, or G's scratch as a blank pane. A pane that was saved with a foreign buffer keeps its place and shows a member that is not yet visible, else the scratch. A pane whose buffer is gone is filled the same way, so a saved peek heals on the next switch. A layout that tiles the group (`window-layout`) uses visible panes and eligible hidden group work. Unused capacity stays empty; it never imports a foreign buffer or manufactures a scratch pane.

### The overview

When a member is killed, its window stays in the group. The window shows the member it showed before, from its own history, most recent first. A member another window of the frame shows is not shown twice. When the history offers no member, the window uses hidden ordinary group work in MRU order, then an existing group chat or scratch. If the surviving group has no companion, repair creates its chat. A dying group gives up the pane. A buffer from another group never comes in.

### The target layout

The layout chosen at `window-layout` (`C-x l`), or a `window-layout-*` command, is a persistent target. There are five, and each holds a fixed number of panes: `single` one, `two-pane` two, `halves` two, `columns` three, `rows` two. A layout works with one buffer and grows as work opens, up to its capacity. At capacity, a visit replaces the buffer of the selected slot. A passive result opens a new window in the least recently used other pane, and the window that had the pane becomes hidden. Focus changes do not reorder slots. Closing a pane reflows the survivors without reopening hidden work.

Every layout shows a run of the frame's window ring. The ring holds windows, not buffers: the panes, then the hidden windows. A hidden window has no pane, and it keeps its buffer, history, and point. A window joins the ring when it is made, and a smaller layout hides windows instead of deleting them. `layout-forward` moves the run one window forward and `layout-backward` one back (neither has a stock key), so each layout goes on for ever in both directions. A Cmd-arrow that finds no window does the same. A walk takes the order of the ring when it starts: the panes in screen order, then the hidden windows, most recently used first. The hidden windows belong to the group: `switch` saves them with the group's layout and restores them, and the desktop saves them.

Targets belong to the group's saved layout on each frame, and the active target also survives desktop save. A new group starts without inheriting the outgoing target. `window-layout-free` drops the target. See [Display buffer](DISPLAY-BUFFER.md#layout-presets) for eligibility, ordering, replacement, preview, and measured geometry rules.

A tile uses the window that shows each buffer: a pane first, then a hidden window, else a new window. So each pane keeps its own history. A pane that the tile leaves out becomes a hidden window.

The frame has no other layouts. `window-layout-free` releases the target, and a display may split a window again.

`tile-all` opens the context overview. It is available only in a group or project. A group takes priority and supplies all its buffers, including chats. Otherwise, the current project supplies all its open buffers. The overview locks the frame: keys select a tile and do not edit. It saves no group layout and changes no membership by itself.

- Arrow keys select a tile. `m` marks a tile. `q`, `C-g`, and `ESC` quit.
- Quit restores the saved window tree and the saved current group.
- `SPC` or `RET` pops the marked buffers, else the selected one, into a new group. The new group takes the first buffer's short name. Each buffer leaves the origin group when one exists.
- The new group records the origin group as its **parent**. `dissolve` on a group with a live parent merges the members back into the parent and the frame follows. A parent that is gone makes the child an ordinary group.

### Save

`switch` saves the outgoing layout as it is, every time. A layout that shows a foreign buffer is saved with it. Showing a foreign buffer in a work window takes the frame out of G (see "The current group"); that moment saves G's layout as it stands and sets `previous` to G, so a switch from a frame in no group has nothing left to save, and a switch back to G finds the arrangement the reader left.

### A buffer opens in the current group

A buffer opens in the group it was launched from: the group of the window that opened it, else the group the frame stands in (`group-spawn-target`). It joins that group on the way in (`buffer-join-here!`), so the arrangement in front of the reader never changes under them. The frame never follows a buffer home. This covers `switch-to-buffer`, `RET` in the switcher, `find-file` on a file with a live buffer in another group, a browse tab a link opens, and a jump that lands in such a buffer. Nothing floats on a switch. (The ruling of 2026-09-22, which replaces "a foreign buffer switches the group" of 2026-09-19.)

Two buffers cannot join and open where they are instead: a chat, whose group is its identity, and a special view, which holds no membership at all.

An app is not a group. The mail, Substack and LinkedIn apps used to own a named group and pull the frame into that group's saved layout whenever one of their panes was shown. What makes an app's buffers one app is the app id they carry (`app-claim!`, `app-id`, `app-buffers` in `scheme/packages/apps.scm`), not a group, so the app opens wherever the reader already is.

Entering another group is a command of its own: `group-switch`, and `RET` on a row of ibuffer. A list is different in one more way: a row chosen in ibuffer or ichat may still show its buffer in the popup, and dismissing the popup leaves G as it was. A display of a buffer outside G that is not a switch is a display of category `foreign` and takes the window chain (docs/DISPLAY-BUFFER.md); a pane that shows it takes the frame out of G.

To keep a buffer in G, add it: `group-add`.

A pinned frame shows a foreign buffer in the selected window: the pin keeps G through window changes, so nothing floats.

### Window fill

One pool answers which buffers may fill a window in this frame: `window-fill-buffers` (`scheme/packages/window.scm`). It is the frame's context, the way a completion source answers a prompt — in a group, the group's members (the switcher's members section reads the same list); out of one, the recency ring — minus every buffer that never fills a window: a hidden name, a context-only buffer, the popup's buffer, or a peek. Every site that fills a window reads the pool and never the ring: the columns of a layout, the window a kill empties, the buffer `q` falls to. A layout that read the ring pulled buffers in from other groups.

`kill-buffer` fills each affected window in this order:

1. The member the window showed before, from the window's own history, most recent first, that no other window of the frame shows; else the group's last chat; else the group's scratch.
2. When the frame has no destination: the next MRU open file under the current buffer's root.
3. When a destination or a root exists and offers nothing: delete the window. The last window shows the group's scratch buffer.
4. When neither a destination nor a root exists: `other-buffer`, as in Emacs.
5. A popup does not count as another window: a window is deleted only when another work window can preserve the frame. A listing under a peek falls to its next buffer; the peek never becomes the only window. A peek is never a fill candidate, and the selection stays in the window that was selected.

Rule 1 is what returns a peek to the previous state. Nothing else is needed.

### Frames

The destination is per frame. Two frames can show two groups, or one group with two layouts. The `previous` slot is per frame.

A frame is a workspace, and a group belongs to one of them. The frame that founds a group keeps it, so another frame's rail, tabs and switcher stay clear of work that was never done there. A group whose frame is gone belongs to no one: the next frame to enter it adopts it, so a closed window strands nothing.

A group of another frame is still reachable. It is the last section of the switcher, marked "in another window", and the board lists every group whatever frame holds it. Picking one goes to the frame that holds it rather than pulling the group into this one: one group stands in one workspace, never two at once. A frame that lives in a browser tab is raised by its tab. Any other client says where the group is and moves nothing yet.

### Indicator

A frame derives `current-group` from its visible non-transient buffers: the intersection of their groups. The modeline shows the name, or "mixed". The indicator decides nothing. It does not gate the layout save, it does not choose where new work goes, and it is not stored.

The active groups are derived the same way: `(active-groups)` answers every group with an open buffer, most recent first. The buffer list decides membership and the MRU only orders it; nothing is stored.

### Switch candidates

`C-x g` lists this frame's groups in MRU order, and the current group
comes last. In a mixed frame the groups of the selected buffer come first.
Groups with no MRU entry trail in creation order. The non-empty pseudo groups
follow, then other frames' groups in a marked section. The new-group action is
`C-c C-n` in the switcher, not a row. Its label says whether it starts empty,
moves the selected buffer, or starts with it. The text you typed to filter
the list names the new group, so a search that finds nothing becomes the
group. With no text, `C-c C-n` asks for a name.

### Candidate preview

Moving the highlight shows the group under it, whole: the layout that group saved, else the arrangement arrival would build for it. The preview never moves the MRU ring, writes no winner entry, leaves the frame's own group alone, and saves no layout. `RET` puts the arrangement you came from back and then switches; `C-g` puts it back and changes nothing. The new-group action previews nothing. A modal prompt covers the windows, so it previews the group in its facts panel instead: what the group holds and the shape it opens in.

### Transient buffers

One predicate, `buffer-special?`, is true for the minibuffer, `*switch*`, the echo area, previews, and the groups board. A floating window is left out too. Transient buffers are excluded from the indicator and from the selection. Every other buffer is a normal buffer.

## The scratch buffer

Every group has one scratch buffer named `*scratch:NAME*`.

- It is in `scratch-mode`, a Morg note: headings fold, code blocks run, and the motions walk headings, siblings, and links.
- `move` and `remove` act on it like any buffer; the group recreates its blank pane when it needs one.
- `kill-buffer` refuses it while the group exists. The echo area names the group.
- `kill G` and `dissolve G` remove it.
- It is the buffer of last resort for window fill inside the group.
- Its content persists with the group. A restored group with a missing scratch buffer gets a new empty one.

## Multi-membership

A buffer is in one group at a time. Joining a group is leaving the old one. A desktop from the days of many memberships keeps the first group each buffer joined.

- `group-add` and `group-move` name one destination and replace the old group. The two removals drop the membership, one from each side.
- Three places read a buffer's group: list sectioning, window fill, and `buffer-context-switch!`. Layouts store buffer names, not groups.
- `buffer-context-switch!` never has two groups to choose from, so it never asks which.

A group grows only while it is the destination of some frame, or by an explicit `group-add`. A group shrinks only by `remove-buffers-from-group`, `remove-group-from-buffer`, `group-move`, `kill-buffer`, `group-dissolve`, or `group-kill`.

## Chats and agents

A chat is a buffer with groups like any other. There is no chat ownership store and no primary chat.

`move` and `remove` act on a chat as its own buffer: the chat leaves alone and no member travels with it. A chat holds one group, so `add` on a chat that has one changes nothing, and `add` on a chat with none makes it a member. A chat that moves keeps its name.

At the start of a turn an agent reads one `context` value:

- files: the members of the chat's group (the destination of the frame that shows the chat; else the chat's groups, see Membership).
- focus: the current buffer of that frame.

Tools an agent calls to list, search, read, or open buffers use the same three sections as the human's lists. The context is what the agent sees first, not what it is forbidden. Group membership never grants a tool permission.

## Pseudo groups

A pseudo group has a name and members, and no record. A function answers the members each time somebody asks, so the membership follows the editor and not the buffer locals.

`Last chats` is the one the editor declares: the chats you used most recently, most recent first. `last-chats-limit` sets how many, and the default is 3.

```scheme
(define-pseudo-group! "Last chats" last-chats)   ; FN answers buffer names, best first
(undefine-pseudo-group! "Last chats")            ; take it away again
```

A pseudo group reads like any other group. It carries a name, a colour and a label, it holds a row on the groups board, and it holds a card in the switcher. `group-buffers`, `group-buffers-mru` and `group-counts` answer for it. The frame enters it, and the members tile as the layout.

The record list never holds one, so save, restore, rename, dissolve and magic grouping never see it. Three rules follow:

- A buffer cannot join one. `group-add` and `group-move` offer the founded groups only, and `group-add-buffers-to!` refuses a pseudo destination.
- A rename and a dissolve refuse, and say so.
- The group keeps no layout and no home directory, because it keeps no record.

The frame holds a pseudo group while every pane shows a member of it. The members carry no mark, so the derivation in `group-current-recalculate!` cannot see the group; `group-pseudo-here?` keeps it instead. A pane that shows anything else takes the frame back to the group the visible buffers do mark.

### Mode groups

Every major mode that two or more buffers share is a pseudo group too, named for the mode: `mode: org` holds the org buffers, most recent first. Nobody declares them. `mode-groups-refresh!` reads the modes in one batch and runs only when the buffer list has moved since the last read, so a group appears when the second buffer opens and goes when the last but one closes. `mode-groups-min` sets the threshold (0 turns them off), and `mode-groups-exclude` names modes that never become a group — `fundamental-mode` by default.

### Going to a buffer's group

`M-x buffer-goto-group` stands in a group that holds the current buffer and focuses the buffer there. It offers the buffer's own group first, then every pseudo group that holds it now — `Last chats`, its mode group. With one choice it goes straight there; with more it asks. `(buffer-goto-group-ids B)` lists the choices, and `(buffer-goto-group! B G)` goes.

## Persistence

`desktop.etf` stores, per group: ID, name, its members, per-frame layouts, and scratch content. Per frame: `destination` and `previous`.

Restore heals: it drops panes whose buffers are gone, deduplicates memberships, rejects a malformed layout, recreates a missing scratch buffer, and isolates a failure to one group. Restore never resurrects a killed buffer.

Rename and restart never change a group's ID.

## The groups board

`groups` opens a list buffer with one row per group: name, member count, modified count, and the frames that show it. Row verbs: switch, rename, dissolve, kill, members. `members` opens the switcher on that group's members with the selection model of Selection. Refreshing the board changes no membership, layout, MRU, or destination.

## Architecture reserved for later

These are not in this specification. The design leaves room for them.

- **Transient layouts.** A frame holds a base layout and, optionally, one transient layout on top. Save-on-leave saves the base. Leaving the transient restores the base. The general mechanism is `transient-frame-enter!` / `transient-frame-exit!` (layouts.scm): a mode records the arrangement and group it found, by name, and leaving puts them back exactly. The chat list and the `ibuffer` window form use it. `tile-all` still carries its own base save and restore and could move onto it.
- **Landing.** `switch G` may take an optional landing layout to show instead of the saved one, without saving it.
- **Narrow.** A hard scope on top of the soft sections is parked.

## Implementation contract

### Records

- Every group has one immutable opaque ID and one durable record.
- Names are unique after trimming and are mutable.
- A record survives with no members. `dissolve` and `kill` retire it.
- A record made by an overview pop-out stores the parent group's ID. The reference is weak: a retired parent makes the child ordinary.
- Code uses the ID for membership, MRU, layouts, and frame slots. Names are for display and completion.

### Membership storage

- A buffer stores a set of valid group IDs in a buffer-local.
- Membership derives from that buffer-local. No second roster is authoritative.
- Killing a buffer removes it from every group with no extra work.
- Adding a present membership and removing an absent one are successful no-ops.

### Frame slots

- A group record stores the frame that owns it, under the `frame` setting. `group-here?` answers for the selected frame, `group-elsewhere-frame` names the other live frame that holds a group, and `group-ids-mru` answers this frame's groups where `group-ids-mru-all` answers every one.
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
6. A pane that shows an ungrouped buffer leaves the group; killing that buffer drops the window onto its next buffer, and the frame is back in that buffer's group with no command involved. A switch never makes such a pane out of a buffer that can join: the buffer joins the group first (see "A buffer opens in the current group"). A switch to an ungrouped buffer, or to a chat of another group, makes one. A layout, a swap, or a restore can still put one in a pane.

### Layouts

- One saved layout per (group, frame). `switch` writes it on leave and reads it on enter.
- Restore validates every pane. A pane whose buffer is dead is dropped. A group with no valid pane shows its scratch buffer.
- One `switch` records one frame-local MRU entry.

## Acceptance list

Tests name commands, never keys. A test that needs a binding binds its own dummy key to its own dummy command.

1. Creation joins with a destination set: file, jump, editor-made buffer, agent-made buffer.
2. Creation with no destination stays ungrouped.
3. Showing a live buffer changes no membership: switcher, `find-file`, jump.
4. `C-RET` semantics in the switcher: go to the buffer's own group.
5. `group-add`, `group-move`, `remove-group-from-buffer` on one buffer, on a selection, on a dired selection, on a path selection.
6. `new` with a selection seed and with an empty seed; the current buffer is never the seed.
7. `buffer-context-switch!` with no group (in a project, and not) and with one group.
8. `switch` saves the outgoing layout as it is and restores tree, buffers, point, scroll, and selected window.
9. A saved layout with a dead buffer restores without that pane.
10. Window fill order: group member, project file, delete window, scratch as last window, `other-buffer` with no context.
11. Three-section lists: all combinations of destination and project present or absent; filter across sections; project section follows the current buffer.
12. `dissolve` drops memberships and keeps buffers; frames go to `previous`. With a live parent, the members join the parent and the frame switches to it.
13. `kill` drops the membership on shared buffers, kills exclusive ones, honours modified protection, switches frames to the next group.
14. Scratch buffer refuses `kill-buffer`; `move` and `remove` act on it; goes with `kill` and `dissolve`; persists content.
15. Per-frame destination and `previous`; two frames on one group with two layouts.
16. Persistence: groups, memberships, layouts, scratch, frame slots survive a restart; malformed state isolates to one group.
17. Agent context: files and focus from the chat's frame, else from the chat's groups.
18. The current group derives from the work windows: two windows in one group put the frame in it; a window on an ungrouped buffer takes it out.
19. A float over the group changes nothing: open, and closed again, the frame's group is the same.

19b. A chat never floats. A chat belongs to exactly one group, so a switch to a chat outside this frame's group enters the chat's group first and opens the chat as an ordinary buffer there. The panes stay sealed: the frame follows the chat home instead of the chat hanging over another group's windows.
20. A kill from outside any command (the Elixir path) that drops a window onto a group's buffer puts the frame back in that group.
21. `ibuffer` lists the frame's group first, and a mark does not reorder the rows.
22. A layout fills its panes from the pool: in a group, three columns come from the members and never from another group; a peek and a floating buffer fill no window.

## Application entry destinations

`scene-open!` accepts an optional destination group. Omission keeps the scene's named group behavior.
An empty string uses the current group. If the frame has no group, the scene stays ungrouped and omits its group companion.
The entry selects the destination before it creates panes. Mode hooks do not select the destination.

WhatsApp exposes this choice as `whatsapp-group`, `"*WhatsApp*"` by default. The command never passes an empty string: an empty value names the group `whatsapp`.

```scheme
(customize-set! 'whatsapp-group "*WhatsApp*")  ; the default group
(customize-set! 'whatsapp-group "whatsapp")    ; use this named group
(run-command "whatsapp")
```

WhatsApp reuses its existing scene layout. Its buffers join the destination without losing existing memberships.

## Same-mode window preference

A window automatically prefers its current work buffer's major mode.
Help keeps the underlying buffer's preference from window history.
Other temporary surfaces can opt in through the `window-preference-cover` buffer local.
Listings keep their own mode preference.
Opening another buffer of that mode reuses the window, including in a free layout.
Explicit display rules and other-window constraints still control display requests.

`` C-` `` (`group-next-mode-buffer`) walks the group's open buffers of the current buffer's major mode.
Cycling stays in the selected window. Other modes stay out of the cycle.
`M-x window-mode-preference` overrides the preference for routing; an empty answer restores automatic selection.
An ordinary work buffer of another mode changes the automatic preference.

Scheme callers can inspect `(window-preferred-mode WIN)` and
`(window-prefers-buffer? WIN BUF)`. The latter includes derived modes.
Automatic preferences use existing window history and require no separate persisted state.
Explicit cycle overrides retain their existing runtime-only lifetime.

### Consolidate a mode

`M-x mode-consolidate` gathers open buffers of the window's preferred mode into its history.
It operates within the current group and frame. Ungrouped work gathers only ungrouped buffers.
The destination contains only matching buffers, including hidden buffers.
Its other buffers leave its history.
The destination stays selected in its pane. No new visible windows are created.
Other visible windows drop matching entries and reveal their next unrelated buffer.
A window with no remaining buffer closes, reducing the visible layout. No buffer is killed.
Matching destination history keeps its order; additional buffers follow in most-recent order.
The command is also available as `(mode-consolidate!)` in Scheme.

`(window-hidden-list)` lists the hidden windows of the selected frame as `(WIN BUFFER)` pairs, most recently used first.
`(layout-hidden-windows)` keeps the ones that this frame's group may show.
`(window-hidden-delete! WIN)` deletes one. `layout-forward` and `layout-backward` bring a hidden window into a pane.

Quitting a listing restores only its own window history. If that history is empty,
the window closes instead of refilling from group recency or another window's buffers.
The last window stays visible when it has no predecessor; quitting reports that condition.

The group switcher puts the current group last in homogeneous and mixed layouts.
The remaining groups preserve MRU order.
