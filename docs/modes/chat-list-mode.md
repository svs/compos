# chat-list-mode

`chat-list-mode` lists every live and archived chat in compos, ordered by recent activity. Moving down the list previews each chat beside the table without moving your focus.

## Open

- `C-x C-c` or `M-x chat-list`.
- `C-c a a` (`agent-goto-attention`) jumps directly to the first chat waiting on a permission or question.

## Keys

| Key | What it does |
| --- | --- |
| `RET` | Open the chat at point, or restore an archived chat |
| `SPC` / `*` / `u` / `U` | Mark row, mark all shown rows, unmark row, unmark all |
| `/` | Narrow live as you type, or pick a Status tab (`working`, `needs you`, etc.) |
| `f` | Filter every chat by title, state, model, or a word in the transcript |
| `<` / `>` | Cycle grouping sections (`group`, `subject`, `none`) and sort order |
| `s` | Send a steering message to the chat at point or to all marked chats |
| `y` / `d` | Allow or deny a pending permission directly from the list |
| `r` | Rename the chat |
| `t` | Show the todo task that this chat is working on |
| `k` / `a` / `D` | Kill, archive, or delete the chat |
| `+` | Start a new chat |
| `w` | Watch mode: keep the busiest chats at the top and update live |
| `.` | Show or hide internal chats spawned by agents |
| `A` | Toggle showing the 100 newest archived chats alone |
| `g` / `q` | Refresh or quit |

## Tips

- Type `is:needs` in `/` to see only chats waiting on your input or permission.
- Mark multiple worker chats with `SPC` and press `s` to steer all of them with one message.

See also: [chat-mode](chat-mode.md), [todo-mode](todo-mode.md).
