# term-mode, comint-shell-mode, tail-mode, and scheme-repl-mode

compos offers four interactive process and REPL modes, all running asynchronously without blocking the editor.

## `term-mode` (`M-x term`)

A raw PTY terminal for full-screen CLI tools and interactive logins.

- **Two keyboard states:** landing in the window keeps editor focus; the first key you type hands input to the terminal. Press `C-g` to take editor focus back (`ESC` stays the terminal's). `s-<left>` and `s-<right>` move between windows from either state.
- **Scrollback:** in focus state, `M-v`/`C-v` (or PageUp/PageDown) scroll pages, `M-<` goes to oldest output, `M->` returns to the prompt. While typing, use `S-PageUp`/`S-PageDown`/`S-Home`/`S-End`. `M-<down>` and `M-<up>` scroll it from another window.

## `comint-shell-mode` (`M-x shell`)

A line-oriented shell inside an editable buffer. Press `RET` to send text after the prompt to the shell. Restarting keeps the transcript and starts a fresh shell.

## `tail-mode` (`M-x tail-file`)

Follows a local or `/ssh:` log file live, keeping the newest 512 KB. Press `/` to filter lines by text, `t` to filter lines by a tree-sitter query (for example JSON logs), `\` to clear filters, and `q` to close.

## `scheme-repl-mode` (`M-x repl`)

Live Scheme REPL connected directly to the running editor.

| Key | What it does |
| --- | --- |
| `RET` | Evaluate complete form (indents newline if incomplete); on a past form or value, copies it to the prompt |
| `C-j` | Always insert a newline |
| `M-p` / `M-n` | Walk command history (shared with `M-:` and persisted across restarts) |
| `C-c M-r` | Search history |
| `C-c C-p` / `C-c C-n` | Step up and down transcript entries |
| `C-c C-u` / `C-c M-o` | Clear current prompt / clear transcript |
| `C-c C-z` | Jump back to the previous buffer |

`*1`, `*2`, `*3` hold the last three values, and `*e` holds the last error. Results print as comments so copied transcript regions remain valid Scheme.

See also: [13. EXTEND](../13.%20EXTEND.md).
