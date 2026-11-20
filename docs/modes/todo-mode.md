# todo-mode and todo-detail-mode

You and every agent share one task list stored in `todos.md` files (`todo-directories`). `todo-mode` is the list view, and `todo-detail-mode` is the per-task page.

## Open

- `C-x t` or `M-x todo` (opens filtered to your current group).
- `C-c t` inside a chat files that conversation as a todo.

## Keys in `todo-mode`

Status tabs (`open`, `inbox`, `waiting`, `closed`, `all`) sit at the top; `<left>`, `<right>`, or `v` switch tabs.

| Key | What it does |
| --- | --- |
| `RET` | Open the task's detail page (`todo-detail-mode`) |
| `c` / `+` | Create a new task / create a sub-task under the task at point |
| `t` | Accept: triage from `inbox`, approve from `review`, or reopen from `done`/`cancelled` |
| `s` | Start task in `doing` and open its agent chat |
| `M-o` | Jump to the task's chat, or assign it to a new chat in a group |
| `d` / `x` / `W` / `i` | Mark `done`, `cancelled`, `waiting`, or send back to `inbox` |
| `N` / `a` | Add a note / open the full action menu (deadline, project, priority, urgent) |
| `SPC` / `*` | Mark task / mark all visible tasks for bulk actions |
| `/` / `\` | Filter by Group, Project, Status tabs or syntax (`p:proj`, `s:state`, `@who`, `#tag`, `!pri`) / clear |
| `<` / `>` | Cycle sections (`none`, `group`, `project`, `status`) / sort (`status`, `urgency`, `deadline`, `created`) |
| `Tab` / `S-Tab` | Fold sub-tasks under a task / fold or unfold all |
| `e` / `k` / `q` | Open `todos.md` file / dismiss page and chat (keeps state) / quit |

## Keys on the task page (`todo-detail-mode`)

Three tabs: **Overview** (`6`), **Children** (`7`), and **Log** (`8`). All list action keys (`t`, `s`, `d`, `x`, `W`, `i`, `N`, `M-o`, `+`) work directly on the page, plus `D` (deadline), `P` (project), `!` (priority), `T` (urgent), `o` (open source link/issue), and `u` (jump up from a child task to its parent).

See also: [chat-mode](chat-mode.md), [09. TODOS + WORKFLOWS](../09.%20TODOS%20+%20WORKFLOWS.md).
