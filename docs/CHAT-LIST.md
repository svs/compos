# Chat list

The chat list is the mode list of `chat-mode`: `(mode-list "chat-mode")`,
ibuffer over the chats (`scheme/packages/mode-list.scm`). The chats add
only what is theirs, with `mode-list-define!` in `agent-fleet.scm`: the
agents that are no chat buffer, the saved chats under the live ones, the
transcript a filter reads, and the verbs on the chat at point. `M-x
mode-list` lists the buffers of any other mode the same way.

## Two surfaces, one table

`C-x c` is the minibuffer form — a popup under the work with its filter
line already open, its own view buffer ` *chats*`, and nothing kept
after the pick. It is the surface for "switch to that chat, the one
whose name I half remember". `M-x ibuffer-prompt-pretty` is the same form over
the buffers; `C-x b` is a plain completion list.

`C-x C-c` (also `M-x chat-list`) opens the list in a window. It owns the
verbs, the grouping and the folds; the minibuffer form borrows none of
that state, so the sort and folds you set in one stay where you left them.

The window form keeps one view per group, the way `ibuffer` does:
`*chat-list*` in the first group that opens it, `*chat-list*<n>` in the
others. `q`, `RET`, `f`, `<`, `>`, the folds and the card are ibuffer's
own, so the chat list leaves in two presses with a card up, like
`ibuffer`.

`t` turns the sections off and on. Off is the flat list, most recent
first — the chat you half-remember the name of is near the top. `<`
does the same: the sections are the groups, or none.

## One window, a floating card, and the frame comes back

The window form takes one window — the one you called it from — and
previews with the same floating card `ibuffer` floats. One preview
surface for both listings.

A two-pane form was tried and reverted. Covering the frame with a 2/3
list and a 1/3 chat pane meant a chat from one group and a buffer from
another stood side by side in one viewport, and a pane of the list's own
left no neighbour for a card to lie over. It also made previewing move
the frame: the frame derives its group from what it shows, so a pane
holding a chat from elsewhere walked the frame group to group, and one
list per group then answered with a different list than the one on
screen. A card is a copy, never the chat itself in a window, so it moves
no group and the list needs no pin.

Row movement floats the card. A heading is not a chat and an archived row
is a path rather than a buffer, so both leave the card showing what it
last held instead of blanking it. Arriving never lands on a heading:
grouping by group puts one first, so arrival falls through to the first
real row, which is what gives you a preview immediately.

Taking a window is only fair if the frame comes back. The arrangement the
list found is recorded on arrival and restored when the list leaves — by
`q`, and by `RET` too, so the chat you pick lands in the arrangement you
were working in.

The minibuffer form shows no card at the moment. `ibuffer-prompt!` records
the invoking window as `ibuffer-prompt-home-window`, and `listing-preview!`
refuses a list that has one. It used to read the chat into the window it was
invoked from, which took a pane the user had not offered.

`C-x c` used to raise before it drew anything. The prompt view is asked
for the row under the cursor while it is still empty, and a buffer that
has never been displayed has no point yet; asking where that point fell
in the text raised out of the open. `line-index-at` answers for a list
with no point now.

## Listing buffers and floating peek cards

`M-x ibuffer` opens an ordinary listing buffer in the window that invoked
it, reusing a matching one in the current group without selecting another
window that shows it. Different groups get separate listing buffers. The
rows identify buffers. Every listing that draws its rows in a window —
ibuffer and the chat list — previews with the card described below. A row whose buffer is already on screen
gets a card too: highlighting the window that holds it showed nothing new
and reached for a window the list does not own.

`C-x b` is the exception, and not by design: its candidates are a
completion list rather than a drawn table, so there is no window to float
a card beside, and it still reads the buffer into its destination pane.

A card **floats over the frame and disturbs nothing**. The popup splits
the list's own window for itself, and a floating window's split takes no
room: it is drawn absolutely over the frame and its sibling fills the
space, so the list keeps its width and no other window loses its buffer.
Dismissing it deletes that split and the list is whole again.

It was laid over a neighbouring window for a while instead, on the
strength of `window-rects` reporting the list squeezed into a third.
Those are tree numbers, not what is drawn — the price of that reading
was a card that took another buffer's window away.

Row navigation shows a **Preview** card after a short pause. The card is inset
from the window borders, raised with a soft shadow, and connected by a line
to the source row. It is a read-only presentation copy in the source mode, with rich chat and block
rendering. It does not copy the source's chat runtime. The card is nearly pane
sized and uses normal text size; changing groups in the list does not resize it.

The body starts at the bottom and scrolls with the mouse wheel or trackpad.
Its content cannot take focus, edit, or activate links. The card's control is
`q` to dismiss. Focus stays in the source list. Moving again fills the card
where it already stands rather than splitting for a second one. In `ibuffer` the first
`q` closes the card and a second leaves the list; in the chat list one
`q` does both, because the card is the list's own preview and not a
thing to put away first. Two presses also cost the frame there: the
card's restore put the list back on screen, and the second `q` found
nothing recorded and deleted the window instead of giving the
arrangement back. Dismissing a card suppresses it for that
row until selection changes. `RET` in the source list opens the real buffer.
Closing a picker removes its card too. `C-x o` or `Cmd-RET` while peeking
opens the original buffer in another work window. Showing a peek never animates
the listing. `RET` opens in the selected pane, moving the mode's window there
when necessary; `q` returns to the same-group listing.
In both ibuffer and ichat, `C-x n n` narrows to the group heading at point
or the group containing the selected row. `C-x n w` shows all groups again,
keeping the `/` query. Group scope survives refresh and folding; changing
the grouping clears it. The header names the narrowed group.

## Keyword search

The name filter is not always enough. You remember a word that somebody
said in the chat, not the name of the chat.

A keyword search reads the text of every alive chat. Alive means every
chat that is not archived, awake or asleep. A sleeping chat answers from
its log file, so the search wakes nothing.

The rows narrow to the chats that hold the word, and each row shows the
line that matched.

## The verbs

The chat list is the only list of chats, so the things you do to a chat
are done here. A verb acts on the marked chats, or on the chat at point when none is
marked, and leaves the list standing. `SPC` marks, as in `ibuffer`.

- `s` steers it
- `y` and `d` answer the permission it waits on
- `r` gives it a title
- `k` kills it, as `ibuffer`'s `k` does; `M-x chats-kill-runtime` only
  stops its runtime and keeps the transcript
- `a` archives it: the runtime stops, the buffer goes, the file stays
- `g` draws the list again
- `+` starts a new chat

A verb asks `buffer-known?`, never `buffer-exists?`. Most rows in this
list are chats the editor has put to sleep: the editor knows them, their
locals still answer, and they are still what the row at point names.
`buffer-exists?` says #f for every one of them, and a verb that asked it
answered "no chat here" on nearly every row.

`s` wakes a sleeping chat, because steering one is a message to send it.
`y`, `d` and `chats-kill-runtime` do not: a chat with no runtime is asking nothing and has
nothing to stop, so they say which chat is asleep rather than claiming
there is no chat under the cursor.

## The list is still

Nothing draws the list behind you. A streaming turn fires events many
times a second, and a list that redrew on them would re-sort its rows
and carry the cursor off the chat you were reading. So no event draws
it: the modeline carries the news of a chat that needs you, and `g`
draws the list again when you ask. The table's stamp is off here for
the same reason: a table redraws when the buffer count moves, so a file
opened by a chat you are not even reading rebuilt this list under the
cursor. A draw keeps the row you were on --
it finds that chat again wherever the new order puts it. Closing the
filter is not a move either: the rows widen back under the same cursor.

## The saved chats

The last section holds the newest saved conversations. A chat you
archived is still a chat you switch to, so RET on one reads its file back
and revives it, where you stood when you asked for it.
`chats-archived-limit` bounds that section.

## Grouping

`<` cycles what a section is. `group` is the default, as in `ibuffer`;
`t` turns the sections off for the flat list in most recently used
order. A flat row carries the name of its chat's group in its own column
in the wide layout, so the group reads without the sections; sectioning
by group drops the column rather than say it twice.

- none (MRU) — the group in a column
- group
- state
- model

## A switch is a switch of group

A buffer switch changes the group. You go to where the buffer lives, and
the buffer does not come to where you are. This is the default for `C-x
b`, `C-x c` and their control counterparts. A pick from either chat
surface enters the chat's group. The list itself does not move: it opens
where you called it.

## Switch to the chat where

`M-x chat-where` reads the words first and opens the list already
narrowed to the chats that say them.

## Settings

- `chats-archived-limit`: how many saved chats the last section holds.
