# keys-mode and messages-mode

Two diagnostic modes help you understand and customize what compos does on every keystroke and every background event.

## `keys-mode` (`C-h B` or `M-x keys`)

Shows every active keybinding for the buffer you came from, ordered from nearest keymap to global. Shadowed keys and your personal overrides are marked clearly.

| Key | What it does |
| --- | --- |
| `RET` | Describe the key and its command |
| `b` | Rebind the row's command to a new key (saved to `~/.compos/custom.scm`) |
| `d` / `x` | Flag a key / unbind the flagged keys (`u` and `U` take flags back) |
| `+` | Bind a command that currently has no key |
| `r` | Revert one of your personal key edits |
| `f` | Filter the list by keymap |
| `/` / `g` / `q` | Search, refresh, or quit |

## `messages-mode` (`C-h e` or `M-x view-messages`)

Displays `*Messages*`, newest entry first, showing the source buffer, mode, and color-coded severity (error red, warning amber, debug grey, info accent).

| Key | What it does |
| --- | --- |
| `l` | Filter by severity level |
| `G` | Filter by group |
| `P` | Filter by project |
| `/` / `\` | Filter all visible text / pop the newest filter |
| `w` | Show active message watches |
| `q` | Close the popup or window |

Run `M-x messages-clear` to empty the log.

See also: [12. CUSTOMIZE](../12.%20CUSTOMIZE.md), [16. TROUBLESHOOTING](../16.%20TROUBLESHOOTING.md).
