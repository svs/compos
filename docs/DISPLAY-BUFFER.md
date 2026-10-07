# Display buffer

Where a buffer goes when a command shows it. The mechanism is Emacs' `display-buffer`, in Scheme, in the display-buffer section of `scheme/packages/window.scm`.

## Which window

Where a buffer lands follows from what you did, not from what the buffer is.

- You found a file, or ran a command that opens one thing: it takes the
  **selected window**. That is `switch-to-buffer!`, verb 1 below.
- You opened a row from a list — dired, ibuffer, a table, a search result:
  it takes the **other window**, the one the list was previewing it in. The
  list keeps its own window until it closes. That is the peek chain
  (docs/PEEK.md) and `show-in-other-work-window!`.
- You opened a row whose detail is its own buffer — a Sentry issue, a
  WhatsApp chat: it takes the list's **detail window**, and every later row
  takes that same window. `display-buffer-detail!`, below.
- A preview lands in the window the pick will land in. Look and open are
  the same window, always.

## One window per mode

A group shows one window per major mode. Every chat is in the chat pane;
every dired listing is in the dired window. A second buffer of a mode takes
the window the first one holds rather than a window of its own, so a group
never shows two chats at once.

Nothing is remembered for this. The mode of what a window already holds is
the memory, so it lapses on its own the moment that window shows something
else. `(window-showing-mode MODE [EXCEPT])` answers the window, the selected
one first — that is what keeps a found file and a command in the window you
are in. `mode-window` is the action that uses it, second in the fallback
chain, after `reuse-window`.

It outranks a target layout. A three-column target with a column free is no
licence to show a second chat: the chat pane takes it and the column stays
free. `layout-target-open!` asks before it grows a pane.

This is also how a list's detail shares the list's window: give the detail
buffer the list's major mode and no other mechanism is needed.
`display-buffer-detail!` below remains for a detail whose mode differs from
its list's.

## The three verbs

1. `switch-to-buffer!` visits a buffer. The buffer joins the group it was launched from first, so the frame never follows it home (docs/groups.md, "A buffer opens in the current group"). With a target layout it reuses an existing view, fills spare capacity, then replaces the selected pane. Without a target it takes the selected window.
2. `display-buffer` shows a buffer somewhere else and selects nothing. A result, a listing, a help page, a shell take their window through it. It returns the window.
3. `pop-to-buffer` is `display-buffer` and then a `select-window!`. A listing you open to work in uses it (`list-mode-show!`).

## The chain

`display-buffer` tries a list of actions in order and stops at the first that answers with a window:

1. the rule for the name in `*display-buffer-alist*`;
2. `*display-buffer-base-action*`, the user's list, empty by default;
3. `*display-buffer-fallback-action*`: `reuse-window`, `mode-window`, `pop-up-window`, `use-some-window`, `same-window`.

The actions:

| action | what it does |
| --- | --- |
| `reuse-window` | a window that shows the buffer already |
| `mode-window` | a work window whose buffer has the same major mode; the selected window first |
| `pop-up-window` | split the largest work window when it is big enough (`split-window-sensibly`), else the selected one |
| `use-some-window` | the least recently used other work window; excludes the float, popups and peeks |
| `same-window` | the selected window (`same` is the same action) |
| `shaped` | the dock or the float, by the buffer's `window-shape` |
| `popper-bottom` | the popup window at the bottom of the frame (popper.scm, docs/POPUPS.md) |

`define-display-action!` adds one. An action is a function of the name and the alist that returns a window or `#f`.

## One buffer, one window

A buffer shows in at most one window of the frame. A display that puts a
buffer in a window takes it away from any other window that had it, and that
window reveals what it showed before — the move `buffer-left` and
`buffer-right` make, done for you. `window-show-buffer!` enforces it, so
every path that gives a window a buffer obeys the same rule.

Two exemptions, both of them arrangement rather than display: a peek is a
look, not a place, and the layout engine is left alone while it arranges
(`*layout-busy*`). One degenerate case remains: when every eligible buffer is
already on screen there is nothing else to reveal, and the other window keeps
what it has. That is the same case `C-x 2` hits with a single buffer.

## Splitting

`split-window-sensibly` is Emacs' rule: a window with `split-height-threshold` rows (80) splits below; else a window with `split-width-threshold` columns (160) splits beside; else the sole work window splits below whatever its size. Two windows side by side on a laptop meet neither threshold, so the next display takes the other window instead of making a third. Both thresholds are `defcustom`s in the `windows` group.

## Layout presets

An explicitly chosen layout is a **target**. It remains selected as buffers
open and panes close. Choosing it with one buffer works: that buffer occupies
the whole frame until there is another buffer to show.

| Target | Capacity | Arrangement |
| --- | --- | --- |
| `two-pane` | 2 | first pane 2/3, companion 1/3 |
| `columns` | 3 | equal columns |
| `halves`, `rows` | 2 | apply the chosen layout as work opens |
| `single` | 1 | one window |
| `free` | sensible splitting | no target |

Pane order is stable across focus changes. Main layouts retain their logical
main pane even when it is physically on the right or bottom. Changing to a
smaller target keeps the first slots and ensures the focused buffer remains
visible; surplus buffers remain open in the group.

Explicit layout selection and preview use one order: existing pane buffers
first, then the group's other eligible buffers in MRU order, with ordinary
work before companions. The picker captures this order once; highlighting
another layout or accepting it distributes the same sequence over its slots.
Existing panes keep their buffers, including Dired, other special lists,
visible non-members. A layout change never
substitutes hidden work for an already occupied slot. The float and popup
windows are excluded from the base arrangement.

Only hidden fillers are subject to eligibility: no peeks, floating buffers,
special buffers, context-only buffers or foreign group members. Existing
group chats and scratch buffers are eligible fillers. Fixed targets cap the
sequence at their capacity. With no group, flexible layouts use visible panes
and fixed layouts fill from the eligible global MRU. Missing capacity creates
no placeholder buffer. Preserving an already displayed non-member does not
change its membership or import other foreign buffers.

`C-x 2` and `C-x 3` put an eligible buffer not already visible into the new
pane, using the same sealed group pool. Focus stays in the original pane.
Only when there is no other candidate does the split show the same buffer.
Low-level `split-window!` retains its duplicate-view mechanism for callers
that deliberately construct a layout.

| Action under a target | Result |
| --- | --- |
| New chat (`C-c n`) | replace the selected pane in place; keep geometry and its previous buffer in pane history |
| Visit an already visible buffer | select its existing pane |
| Open a new member below capacity | append a slot, reflow, select it |
| Open a member at capacity | replace the selected slot |
| Display an ordinary result | fill capacity, else put a new window in the least recently used other pane, which becomes hidden; preserve focus |
| Close a pane | reflow surviving slots; do not pull hidden work back in |
| Kill a buffer | refill from eligible pane history, then hidden group work, then existing group companions |
| Quit a displayed result | restore the borrowed pane or remove the pane created for it |
| Cancel a layout preview | restore the original tree, focus, and ordering cache |
| Switch groups | save and restore that group's target and tree on this frame |

Group kill repair retains its final chat/scratch fallback and creates the surviving group’s chat when no companion remains. No foreign buffer
is eligible to refill a sealed group's pane. Background buffer contexts do
not open or rearrange visible panes. Mode-entry layouts and automatic
relayout hooks defer to an explicitly selected target.

Relayout preserves each view's point and buffer history. The active target is saved with the desktop even without
switching groups. `window-layout-free` releases the target. A layout holds a fixed number of panes, so work past that number does not add a pane. It takes a pane, and the window that had the pane becomes hidden. The hidden windows make the window ring with the panes, and `layout-forward` and `layout-backward` reach them. `quit-window` in the new window gives the pane back to the hidden window.

The measured regression journeys are in `scheme/packages/layout-policy-test.scm`,
with a disposable-frame runner and keyboard-path test in
`test/compos/layout_policy_test.exs`. That runner still reads the old
`priv/tests` path. Each journey records normalized
`(buffer x y width height)` rectangles after each transition. For example:

| Rows journey | Geometry `(y, height)` in slot order |
| --- | --- |
| A, choose rows | A `(0, 1)` |
| open B | A `(0, 1/2)`, B `(1/2, 1/2)` |
| open C | A `(0, 1/3)`, B `(1/3, 1/3)`, C `(2/3, 1/3)` |
| close B's pane | A `(0, 1/2)`, C `(1/2, 1/2)` |
| reopen B | A `(0, 1/3)`, C `(1/3, 1/3)`, B `(2/3, 1/3)` |

## Rules

`(add-display-rule! PATTERN ACTION [PARAMS])` puts a rule in front. PATTERN is a substring of the buffer name, `(category KIND)` for a kind of display the caller names in the alist, or a procedure of NAME and ALIST (Emacs `display-buffer-alist`). ACTION is one action name or a list of them. A rule's actions come before the base action and the fallback, so a rule that names `same-window` never splits.

The callers pass an alist, a plist:

- `'category KIND`: the kind of display. A peek passes `preview`, a list's row detail passes `detail`. The stock rule `((category preview) (reuse-window mode-window use-some-window pop-up-window))` is last in the alist, so a rule for a name wins over it.
- A display of a buffer from outside the frame's group that names no category is a display of category `foreign` (`display-foreign?`, answered by groups.scm). The stock rule sends it through the window chain (docs/groups.md). `switch-to-buffer!` obeys this rule (Emacs `switch-to-buffer-obey-display-actions`); a mechanism that fills a window it chose calls `switch-to-buffer-here!`. To split a new window for foreign buffers instead: `(add-display-rule! '(category foreign) 'pop-up-window)`.
- `'inhibit-same-window #t`: keep the selected window out of the chain. `display-buffer-other-window!` is `display-buffer` with this set.

## Previews are a rule

A peek (docs/PEEK.md) is a display of category `preview`. By the stock rule it goes through the window chain: dired and the browser show a file beside the listing without keeping it, in a window that is not the reader's. A popup rule does not take a look (docs/POPUPS.md). The next peek takes the same window, and dismissing the peek puts the window back. Point stays in the listing.

## Details are a rule and a memory

A table whose rows are each their own buffer — Sentry issues, WhatsApp
chats, MCP servers — opens them all into ONE window. `(display-buffer-detail!
NAME [OWNER])` (`packages/detail.scm`) is how: the first row picks a window
through the chain as category `detail`, and the window is remembered against
the list, so every row after it retakes that window. Without the memory each
row is a new buffer name, `reuse-window` never matches, and the layout grows
a pane per row.

This is the one place a window is remembered rather than chosen at display
time, and it lapses on its own: when the window goes, when it holds the list
itself, or when the list asks from it.

A detail is not a peek. It is kept, it is writable, and it stays when the
list goes. The list owns it (`buffer-child!`, `packages/dismiss.scm`), so `q` on the
list takes the detail with it, and the details of one list are siblings:
`C-\`` in the detail window walks them, most recent first, the way it walks
chats in a chat pane.

When the chain has nowhere to put the first row — one window, or a target
layout that refuses this buffer a slot and never splits on its own — the
detail splits a window rather than go without one. That is what a special,
foreign buffer like `*mail*` hits under a target.

## Keeping one

A list that rewrites ONE detail buffer per row — notmuch's `*mail*` — keeps a
row with `M-RET` (`detail-keep`). The buffer takes a name of its own
(`*mail: Your Sunday afternoon trip with Uber*`), and that frees the name the
app writes to, so the next row renders into a fresh buffer with nothing to
overwrite. Renaming is the whole mechanism: no app needs a flag for it.

A kept detail stops being the list's child, so the list's `q` leaves it alone,
and it stays in the walk, so `C-\`` still reaches it. It does not get a pane
of its own — that is how a layout starts growing a pane per row again.

`(detail-name! MODE FN)` is how a mode says what to call what it keeps; FN
takes the buffer and answers a name. Without a rule the buffer's own name
takes a number, as `rename-uniquely` does.

Tests: `scheme/packages/detail-test.scm`, run by the package suite (`--include packages`).

## quit-window

A display notes what it did to a window: `window` when it made the window, `other` when it took a window that showed another buffer. `q` (`quit-window`) undoes that first, then kills the listing: the window the display made goes, or the buffer the display replaced comes back. `window-quit-restore!` does the undo alone.

Tests: `scheme/packages/display-buffer-test.scm`, run by the package suite (`--include packages`).

Cmd-Shift-arrows run the `window-*` commands, which swap the active window
with its neighbor. The `buffer-*` commands move the active view onto the
neighboring pane's history and show the source pane's previous group buffer.
Cmd-Ctrl-left and Cmd-Ctrl-right run `buffer-left` and `buffer-right`;
`(buffer-default-keybindings)` binds all four to other arrows.
List modes may specify `'special #f` for persistent app buffers such as
WhatsApp; generated lists otherwise keep the special default.
