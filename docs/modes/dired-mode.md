# Dired and wdired-mode

`Dired` displays a directory as a uniform list table showing file name, size, modified time, permissions, and Git status. It works on both local directories and remote `/ssh:user@host:/path` directories.

## Open

- `C-x d` or `C-x C-d` (`dired`): prompt for a directory.
- `C-x p d` or `s-E` (`project-dired`): open the Git project root.

## Keys

| Key | What it does |
| --- | --- |
| `RET` | Open file in the other window (directory opens in place) |
| `M-RET` | Open file beside the listing and move focus there |
| `^` | Go to the parent directory |
| `SPC` or `m` | Mark the row at point |
| `d` / `D` | Flag for trash (`d`) or permanent deletion (`D`) |
| `x` | Execute trash/delete on flagged or marked files |
| `R` / `C` / `+` | Rename/move, copy, or create a directory (offers another visible Dired window as target) |
| `/` / `\` | Narrow live (matches name, mode, perms, size, date) or pick tabs; `\` widens by one |
| `.` | Show or hide dotfiles |
| `s` / `S` / `G` | Change sort column, reverse sort, or toggle directories first |
| `*` prefix | Bulk marks: `* s` all, `* /` dirs, `* *` executables, `* @` links, `* .` by extension, `* !` unmark all |
| `% m` / `% d` / `% R` | Mark, flag, or rename by regular expression |
| `t` / `~` | Toggle marks / flag backup files |
| `!` | Run a shell command on the marked files |
| `C-x C-q` | Enter `wdired-mode` to edit filenames directly as text |
| `g` / `q` | Refresh or go back through directory history |

## Editable Dired (`wdired-mode`)

Press `C-x C-q` in Dired to turn filenames into ordinary editable text (so search-and-replace or multi-line edits work on names). Press `C-c C-c` to commit all renames, or `C-c C-k` to cancel.

See also: [ibuffer-mode](ibuffer-mode.md), [04. EVERYDAY EDITING](../04.%20EVERYDAY%20EDITING.md).
