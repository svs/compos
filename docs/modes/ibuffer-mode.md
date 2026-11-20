# ibuffer-mode and groups-mode

`ibuffer-mode` manages open buffers across compos, and `groups-mode` manages task groups. Both share the standard list-mode keys.

## `ibuffer-mode` (`C-x C-b`)

Switch tabs across the top (`all`, `group`, `window`) with `<left>` and `<right>`.

| Key | What it does |
| --- | --- |
| `RET` | Enter the buffer's group and focus the buffer |
| `SPC` / `*` / `u` / `U` | Mark row, mark all shown, unmark row, clear all marks |
| `k` | Kill the buffer immediately |
| `d`, then `x` | Flag buffers for killing and execute |
| `G` / `K` | Put marked buffers in a group / kill the group at point |
| `<` / `>` | Cycle grouping (`group`, `mode`, `directory`) and sort order (`name`, `recency`) |
| `Tab` / `S-Tab` | Fold section at point / fold all sections |
| `f` / `\` | Narrow by name, mode, or path / widen by one |
| `/` prefix | Emacs ibuffer filters: `/ m` mode, `/ n` name, `/ f` filename, `/ F` dir, `/ .` ext, `/ c` contents, `/ !` negate, `/ |` or, `/ p` pop, `/ /` clear all |
| `C-.` | Open contextual verbs (move here, add to group, save) |
| `g` / `q` | Refresh or quit |

## `groups-mode` (`M-x groups`)

Lists every buffer group with its member count, companion noise setting, and description.

| Key | What it does |
| --- | --- |
| `RET` | Switch to the group and restore its window layout |
| `SPC` / `*` | Mark groups for bulk actions |
| `d` | Generate a description of the group with the LLM |
| `n` | Cycle companion noise level |
| `x` | Dissolve the group |
| `K` | Kill all buffers in the group |
| `/` / `\` | Narrow or widen |
| `g` / `q` | Refresh or quit |

See also: [dired-mode](dired-mode.md), [03. BUFFERS, PANES, WINDOWS](../03.%20BUFFERS,%20PANES,%20WINDOWS.md).
